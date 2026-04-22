//
//  AIReceiptParsingServiceTests.swift
//  ReceiptAI ParserTests
//
//  Uses a custom URLProtocol so tests never hit the real Gemini API.
//

import XCTest
@testable import ReceiptAI_Parser

final class AIReceiptParsingServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testParse_throwsWhenAPIKeyMissing() async throws {
        let session = makeMockSession()
        let service = AIReceiptParsingService(session: session) {
            AIParserConfiguration(isEnabled: true, apiKey: "", model: "gemini-2.0-flash", endpoint: EmbeddedGeminiConfig.endpoint)
        }

        do {
            _ = try await service.parse(text: "x", imageData: Data([0xFF, 0xD8, 0xFF]), confidence: 0.9)
            XCTFail("expected error")
        } catch AIReceiptParsingError.parsingNotConfigured {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testParse_mapsSuccessfulGeminiJSON() async throws {
        let listJSON = """
        {"models":[{"name":"models/gemini-2.0-flash","supportedGenerationMethods":["generateContent"]}]}
        """
        let generateJSON = """
        {"candidates":[{"content":{"parts":[{"text":"{\\"shopName\\":\\"Test Shop\\",\\"amount\\":42.5,\\"dateIso\\":\\"2026-04-20\\",\\"currency\\":\\"UAH\\",\\"category\\":\\"groceries\\"}"}]}}]}
        """

        MockURLProtocol.handler = { request in
            let absolute = request.url?.absoluteString ?? ""
            if absolute.contains("generateContent") {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(generateJSON.utf8))
            }
            // List models: GET …/v1beta/models?key=…
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(listJSON.utf8))
        }

        let session = makeMockSession()
        let service = AIReceiptParsingService(session: session) {
            AIParserConfiguration(isEnabled: true, apiKey: "test-key", model: "gemini-2.0-flash", endpoint: EmbeddedGeminiConfig.endpoint)
        }

        let jpegStub = Data([0xFF, 0xD8, 0xFF, 0xDB])
        let result = try await service.parse(text: "dummy ocr", imageData: jpegStub, confidence: 0.88)

        XCTAssertEqual(result.shopName, "Test Shop")
        XCTAssertEqual(result.amount, 42.5, accuracy: 0.001)
        XCTAssertEqual(result.currency, .uah)
        XCTAssertEqual(result.category, .groceries)
        XCTAssertEqual(result.parsingSource, .aiGemini)
        XCTAssertEqual(result.confidence, 0.88, accuracy: 0.001)
        XCTAssertEqual(result.receiptImageData, jpegStub)
        XCTAssertEqual(result.rawText, "dummy ocr")

        let day = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: result.date)
        XCTAssertEqual(day.year, 2026)
        XCTAssertEqual(day.month, 4)
        XCTAssertEqual(day.day, 20)
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

// MARK: - Mock URL loading

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
