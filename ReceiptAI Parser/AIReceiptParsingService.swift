//
//  AIReceiptParsingService.swift
//  ReceiptAI Parser
//
//  **Production receipt parsing via Google Gemini** (`generateContent` REST API).
//
//  Pipeline:
//  1. Validate config (enabled + non-empty API key from `GeminiInfo.plist` / fallback).
//  2. Optionally call **ListModels** to pick a model id that supports `generateContent` (avoids 404 on typos).
//  3. POST multimodal payload: **JPEG image (base64)** + **OCR plain text** + strict JSON system prompt.
//  4. Decode model JSON into `AIParsedReceiptPayload`, then map into `ParsedReceiptData`.
//
//  Important: there is **no fallback** to `ReceiptParsingService` — failures surface as thrown errors.
//

import Foundation

// MARK: - Debug logging

#if DEBUG
private func aiDebugLog(_ message: String) {
    print("[AIReceiptParsing] \(message)")
}
#else
private func aiDebugLog(_ message: String) {}
#endif

// MARK: - Embedded API configuration

/// Fallback when **GeminiAPIKey** / **GeminiModel** are missing or empty in root `GeminiInfo.plist`.
enum EmbeddedGeminiConfig {
    static let isAIEnabled = true
    static let apiKey = ""
    static let model = "gemini-2.0-flash"
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
}

/// Runtime copy of Gemini settings (allows tests to inject `configurationProvider`).
struct AIParserConfiguration {
    var isEnabled: Bool
    var apiKey: String
    var model: String
    var endpoint: URL

    /// Reads **GeminiAPIKey** and **GeminiModel** from the merged Info plist (see root `GeminiInfo.plist`), then falls back to `EmbeddedGeminiConfig`.
    static func embedded() -> AIParserConfiguration {
        let plistKey = Bundle.main.object(forInfoDictionaryKey: "GeminiAPIKey") as? String
        let plistModel = Bundle.main.object(forInfoDictionaryKey: "GeminiModel") as? String

        let trimmedPlistKey = plistKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedPlistModel = plistModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let apiKey = trimmedPlistKey.isEmpty
            ? EmbeddedGeminiConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedPlistKey
        let model = trimmedPlistModel.isEmpty ? EmbeddedGeminiConfig.model : trimmedPlistModel

        return AIParserConfiguration(
            isEnabled: EmbeddedGeminiConfig.isAIEnabled,
            apiKey: apiKey,
            model: model,
            endpoint: EmbeddedGeminiConfig.endpoint
        )
    }
}

// MARK: - Errors

/// Typed failures for the Gemini-only parsing path (localized for `Alert` / debugging).
enum AIReceiptParsingError: LocalizedError {
    /// AI disabled or API key missing in `EmbeddedGeminiConfig`.
    case parsingNotConfigured
    /// HTTP success but JSON shape unexpected, empty candidates, or non-JSON model text.
    case invalidResponse
    /// Non-2xx HTTP from `generateContent` or `models` list endpoint.
    case httpError(Int, String)
    /// Model JSON missing a **positive amount** or a valid **yyyy-MM-dd** date string.
    case incompleteAIResult

    var errorDescription: String? {
        switch self {
        case .parsingNotConfigured:
            return "Receipt parsing requires Gemini: set GeminiAPIKey in GeminiInfo.plist next to the Xcode project (see README), or EmbeddedGeminiConfig.apiKey for quick local tests."
        case .invalidResponse:
            return "The model returned an invalid response."
        case .httpError(let status, let body):
            return "Gemini API error (\(status)): \(body)"
        case .incompleteAIResult:
            return "The model response did not include a valid amount and/or date (yyyy-MM-dd)."
        }
    }
}

// MARK: - Gemini REST DTOs (partial)

/// Subset of `generateContent` JSON: we only need the first candidate’s text parts.
private struct GeminiGenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}

/// Subset of `models.list` JSON for capability filtering.
private struct GeminiListModelsResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let supportedGenerationMethods: [String]?
    }
    let models: [Model]?
}

/// Strict JSON object we ask the model to emit (snake_case keys match decoding keys below).
private struct AIParsedReceiptPayload: Decodable {
    let shopName: String?
    let amount: Double?
    let dateIso: String?
    let currency: String?
    let category: String?
}

// MARK: - AIReceiptParsingService

struct AIReceiptParsingService: ReceiptParsingServicing {
    private let session: URLSession
    /// Allows unit tests to stub configuration without touching `UserDefaults` / globals.
    private let configurationProvider: () -> AIParserConfiguration

    init(
        session: URLSession = .shared,
        configurationProvider: @escaping () -> AIParserConfiguration = { AIParserConfiguration.embedded() }
    ) {
        self.session = session
        self.configurationProvider = configurationProvider
    }

    /// Orchestrates model resolution + `generateContent` + mapping into `ParsedReceiptData`.
    /// - Parameters:
    ///   - text: OCR output (also embedded in the prompt as plain text for redundancy with the image).
    ///   - imageData: JPEG bytes sent as `inlineData` (Gemini sees pixels the OCR might misread).
    ///   - confidence: passed through to `ParsedReceiptData` for UI quality display (not sent to API).
    func parse(text: String, imageData: Data, confidence: Double) async throws -> ParsedReceiptData {
        let config = configurationProvider()
        aiDebugLog(
            "parse start: aiEnabled=\(config.isEnabled) keyPresent=\(!config.apiKey.isEmpty) keyLen=\(config.apiKey.count) model=\(config.model) endpoint=\(config.endpoint.absoluteString) ocrLen=\(text.count) imageBytes=\(imageData.count)"
        )
        guard config.isEnabled, !config.apiKey.isEmpty else {
            if !config.isEnabled {
                aiDebugLog("parse aborted: AI disabled in EmbeddedGeminiConfig.isAIEnabled")
            } else {
                aiDebugLog("parse aborted: GeminiAPIKey is empty (plist + fallback)")
            }
            throw AIReceiptParsingError.parsingNotConfigured
        }

        let model = try await resolveModel(configuration: config)
        aiDebugLog("selected model for generateContent: \(model)")
        let payload = try await askAIToExtract(
            text: text,
            imageData: imageData,
            model: model,
            configuration: config
        )
        aiDebugLog("AI OK: payload shop=\(payload.shopName ?? "nil") amount=\(payload.amount.map { String($0) } ?? "nil") dateIso=\(payload.dateIso ?? "nil") currency=\(payload.currency ?? "nil") category=\(payload.category ?? "nil")")
        return try buildParsedData(from: payload, sourceText: text, imageData: imageData, confidence: confidence)
    }

    // MARK: generateContent

    /// Builds JSON body, POSTs to `:generateContent`, extracts JSON text from candidate parts.
    private func askAIToExtract(
        text: String,
        imageData: Data,
        model: String,
        configuration: AIParserConfiguration
    ) async throws -> AIParsedReceiptPayload {
        let requestURL = try makeGeminiURL(configuration: configuration, model: model)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // System instruction: force single JSON object, no markdown fences, stable categories.
        let systemPrompt = """
        You are a receipt extraction engine.
        Return STRICT JSON only with keys:
        shopName (string),
        amount (number),
        dateIso (string in yyyy-MM-dd),
        currency (one of UAH,USD,EUR,PLN),
        category (one of groceries,transport,dining,utilities,entertainment,healthcare,shopping,other).
        If unsure, pick best guess. Never return markdown.
        """

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": [
                [
                    "parts": [
                        [
                            "inlineData": [
                                "mimeType": "image/jpeg",
                                "data": imageData.base64EncodedString()
                            ]
                        ],
                        ["text": "Receipt OCR text:\n\(text)"]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0,
                "responseMimeType": "application/json"
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            aiDebugLog("generateContent: response is not HTTPURLResponse")
            throw AIReceiptParsingError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            aiDebugLog("generateContent HTTP \(httpResponse.statusCode): \(body.prefix(500))")
            throw AIReceiptParsingError.httpError(httpResponse.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
        let content = decoded.candidates?
            .first?
            .content?
            .parts?
            .compactMap(\.text)
            .joined(separator: "\n")

        guard let content, !content.isEmpty else {
            aiDebugLog("generateContent: empty candidates/parts text; raw=\(String(data: data, encoding: .utf8)?.prefix(400) ?? "nil")")
            throw AIReceiptParsingError.invalidResponse
        }

        aiDebugLog("generateContent raw text (prefix): \(content.prefix(300))")
        let jsonData = try extractJSONData(from: content)
        return try JSONDecoder().decode(AIParsedReceiptPayload.self, from: jsonData)
    }

    // MARK: URL construction

    private func makeGeminiURL(configuration: AIParserConfiguration) throws -> URL {
        try makeGeminiURL(configuration: configuration, model: configuration.model)
    }

    /// `POST {endpoint}/models/{model}:generateContent?key=API_KEY`
    private func makeGeminiURL(configuration: AIParserConfiguration, model: String) throws -> URL {
        let base = configuration.endpoint.absoluteString.hasSuffix("/")
            ? String(configuration.endpoint.absoluteString.dropLast())
            : configuration.endpoint.absoluteString
        let normalizedModel = model.replacingOccurrences(of: "models/", with: "")
        let full = "\(base)/models/\(normalizedModel):generateContent"

        guard var components = URLComponents(string: full) else {
            throw AIReceiptParsingError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]

        guard let url = components.url else {
            throw AIReceiptParsingError.invalidResponse
        }
        return url
    }

    // MARK: Model resolution

    /// Picks a concrete model id:
    /// - If **ListModels** succeeds and contains `EmbeddedGeminiConfig.model`, use it.
    /// - Else pick the first entry from a **preferred** list that exists in the account.
    /// - Else use the first `generateContent`-capable model returned by Google.
    /// - If listing fails entirely, fall back to the configured string (may 404, but avoids blocking).
    private func resolveModel(configuration: AIParserConfiguration) async throws -> String {
        let configured = configuration.model.replacingOccurrences(of: "models/", with: "")

        if let available = try? await fetchAvailableGenerateModels(configuration: configuration), !available.isEmpty {
            aiDebugLog("ListModels OK: found \(available.count) models with generateContent; configured=\(configured)")
            if available.contains(configured) {
                return configured
            }

            let preferred = [
                "gemini-2.0-flash",
                "gemini-2.0-flash-lite",
                "gemini-1.5-flash-latest",
                "gemini-1.5-pro-latest",
                "gemini-1.5-flash",
                "gemini-1.5-pro"
            ]
            if let best = preferred.first(where: { available.contains($0) }) {
                aiDebugLog("ListModels: configured not in list, picked preferred: \(best)")
                return best
            }
            aiDebugLog("ListModels: picked first available: \(available[0])")
            return available[0]
        }

        aiDebugLog("ListModels: failed or empty — using configured model: \(configured)")
        return configured
    }

    /// Calls `GET {endpoint}/models?key=...` and filters to models advertising `generateContent`.
    private func fetchAvailableGenerateModels(configuration: AIParserConfiguration) async throws -> [String] {
        let base = configuration.endpoint.absoluteString.hasSuffix("/")
            ? String(configuration.endpoint.absoluteString.dropLast())
            : configuration.endpoint.absoluteString

        guard var components = URLComponents(string: "\(base)/models") else {
            throw AIReceiptParsingError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]

        guard let url = components.url else {
            throw AIReceiptParsingError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            aiDebugLog("ListModels HTTP \(status): \(body.prefix(400))")
            throw AIReceiptParsingError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(GeminiListModelsResponse.self, from: data)
        let models = decoded.models ?? []
        return models
            .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
            .map { $0.name.replacingOccurrences(of: "models/", with: "") }
    }

    // MARK: JSON extraction

    /// Models sometimes wrap JSON in extra prose; try whole string first, then substring between `{`…`}`.
    private func extractJSONData(from content: String) throws -> Data {
        if let directData = content.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: directData)) != nil {
            return directData
        }

        guard
            let start = content.firstIndex(of: "{"),
            let end = content.lastIndex(of: "}")
        else {
            throw AIReceiptParsingError.invalidResponse
        }

        let jsonString = String(content[start...end])
        guard let data = jsonString.data(using: .utf8) else {
            throw AIReceiptParsingError.invalidResponse
        }
        return data
    }

    // MARK: Mapping to domain

    /// Converts decoded AI payload into `ParsedReceiptData` with strict validation on amount + date.
    private func buildParsedData(
        from payload: AIParsedReceiptPayload,
        sourceText: String,
        imageData: Data,
        confidence: Double
    ) throws -> ParsedReceiptData {
        guard let amount = payload.amount, amount > 0 else {
            throw AIReceiptParsingError.incompleteAIResult
        }
        let trimmedDateIso = (payload.dateIso ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDateIso.isEmpty, let date = mapDate(trimmedDateIso) else {
            throw AIReceiptParsingError.incompleteAIResult
        }

        let currency = Currency(rawValue: (payload.currency ?? "").uppercased()) ?? .uah
        let category = mapCategory(payload.category) ?? .other
        let shopName = resolvedMerchantName(from: payload.shopName)

        return ParsedReceiptData(
            shopName: shopName,
            amount: amount,
            date: date,
            currency: currency,
            category: category,
            receiptImageData: imageData,
            rawText: sourceText,
            confidence: confidence,
            parsingSource: .aiGemini,
            parsingNote: nil
        )
    }

    /// Empty / whitespace shop name becomes a neutral label (user can edit in preview).
    private func resolvedMerchantName(from raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown merchant" : trimmed
    }

    /// Parses ISO calendar dates with a fixed POSIX locale (avoids device-locale ambiguity).
    private func mapDate(_ dateIso: String?) -> Date? {
        guard let dateIso else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateIso)
    }

    /// Maps API’s lowercase English category token into our `ExpenseCategory` enum.
    private func mapCategory(_ raw: String?) -> ExpenseCategory? {
        switch (raw ?? "").lowercased() {
        case "groceries": return .groceries
        case "transport": return .transport
        case "dining": return .dining
        case "utilities": return .utilities
        case "entertainment": return .entertainment
        case "healthcare": return .healthcare
        case "shopping": return .shopping
        case "other": return .other
        default: return nil
        }
    }
}
