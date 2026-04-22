//
//  ReceiptParsingServiceTests.swift
//  ReceiptAI ParserTests
//
//  Unit tests for **local** `ReceiptParsingService` regex/heuristics.
//  These validate edge cases independent of network / Gemini quotas; they remain valuable even though
//  the production app uses API-only parsing (`AIReceiptParsingService`).
//

import XCTest
@testable import ReceiptAI_Parser

final class ReceiptParsingServiceTests: XCTestCase {
    private var service: ReceiptParsingService!

    override func setUp() {
        super.setUp()
        service = ReceiptParsingService()
    }

    /// Amounts with spaced thousands + comma decimals should normalize to a `Double`.
    func testParseAmount_SpacedThousandsFormat() throws {
        let text = "Total: 1 234,50 ₴"
        let amount = try service.parseAmount(from: text)
        XCTAssertEqual(amount, 1234.50, accuracy: 0.001)
    }

    func testParseCurrency_USD() {
        let text = "TOTAL $19.99"
        XCTAssertEqual(service.parseCurrency(from: text), .usd)
    }

    func testParseDate_DotFormat() {
        let text = "Date: 21.04.2026"
        let date = service.parseDate(from: text)
        XCTAssertNotNil(date)
    }

    func testDetectCategory_GroceriesByKeyword() {
        let category = service.detectCategory(
            from: "SILPO grocery market",
            shopName: "Silpo"
        )
        XCTAssertEqual(category, .groceries)
    }

    /// When a “TOTAL …” line exists, its amount should win over intermediate line items.
    func testParseAmount_PrefersTotalLine() throws {
        let text = """
        Item A 5.20 PLN
        Item B 9.78 PLN
        TOTAL PLN 14.98
        """
        let amount = try service.parseAmount(from: text)
        XCTAssertEqual(amount, 14.98, accuracy: 0.001)
    }

    /// Merchant guesser should skip purely numeric header lines and obvious fiscal boilerplate.
    func testParseShopName_SkipsNumericLine() {
        let lines = [
            "1229",
            "BIEDRONKA NR 1234",
            "PARAGON FISKALNY"
        ]
        XCTAssertEqual(service.parseShopName(from: lines), "BIEDRONKA NR 1234")
    }
}
