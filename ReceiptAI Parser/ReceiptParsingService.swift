//
//  ReceiptParsingService.swift
//  ReceiptAI Parser
//
//  **Local (regex / heuristic) receipt parser** — useful for unit tests and offline experiments.
//  The production app flow uses **Gemini only** (`AIReceiptParsingService`); this type is **not** wired
//  into the main parsing path anymore, but it documents how rule-based extraction works.
//
//  Strategy overview:
//  1. Split OCR text into lines; guess merchant from early non-noise lines.
//  2. Prefer amounts on “total” lines (multilingual keywords).
//  3. Otherwise scan whole text with amount regexes and pick the **largest plausible** candidate.
//  4. Date / currency / category use lightweight pattern + keyword rules.
//

import Foundation

// MARK: - Errors

enum ReceiptParsingError: LocalizedError {
    case amountNotFound

    var errorDescription: String? {
        switch self {
        case .amountNotFound:
            return "Could not find an amount on the receipt."
        }
    }
}

// MARK: - Protocol

/// Shared contract with `AIReceiptParsingService` so the flow view model can swap implementations in tests.
protocol ReceiptParsingServicing {
    func parse(text: String, imageData: Data, confidence: Double) async throws -> ParsedReceiptData
}

// MARK: - Local parser

struct ReceiptParsingService: ReceiptParsingServicing {
    /// Regex patterns for monetary amounts; capture group **1** is the numeric portion.
    private let amountPatterns: [String] = [
        // Labels like “total / всього / сума …” then a number (supports thousand separators).
        #"(?i)(?:до\s*оплати|сума|разом|всього|total)\s*[:\-]?\s*([0-9]{1,3}(?:[ \.,][0-9]{3})*(?:[.,][0-9]{2})?)"#,
        // Number immediately before a currency symbol / code.
        #"([0-9]{1,3}(?:[ \.,][0-9]{3})*(?:[.,][0-9]{2}))\s*(?:₴|UAH|USD|EUR|PLN|\$|€|zł)"#,
        // Currency symbol / code before the number.
        #"(?:₴|UAH|USD|EUR|PLN|\$|€|zł)\s*([0-9]{1,3}(?:[ \.,][0-9]{3})*(?:[.,][0-9]{2})?)"#
    ]

    /// Date substrings to extract before parsing with `DateFormatter`.
    private let datePatterns: [String] = [
        #"(\d{2}\.\d{2}\.\d{4})"#,
        #"(\d{2}/\d{2}/\d{4})"#,
        #"(\d{4}-\d{2}-\d{2})"#,
        #"(\d{2}\.\d{2}\.\d{2})"#
    ]

    /// Entry point: builds a `ParsedReceiptData` tagged as `.localFallback` for traceability.
    func parse(text: String, imageData: Data, confidence: Double) async throws -> ParsedReceiptData {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let shopName = parseShopName(from: lines)
        let amount = try parseAmount(from: text)
        let date = parseDate(from: text) ?? .now
        let currency = parseCurrency(from: text) ?? .uah
        let category = detectCategory(from: text, shopName: shopName)

        return ParsedReceiptData(
            shopName: shopName,
            amount: amount,
            date: date,
            currency: currency,
            category: category,
            receiptImageData: imageData,
            rawText: text,
            confidence: confidence,
            parsingSource: .localFallback,
            parsingNote: "Used local parser (regex / heuristics)."
        )
    }

    // MARK: Merchant

    /// Inspects the first few lines and returns the first string that looks like a merchant name.
    /// Filters obvious fiscal / hardware boilerplate (“PARAGON”, “TERMINAL”, …).
    func parseShopName(from lines: [String]) -> String {
        for line in lines.prefix(6) {
            let cleaned = line
                .replacingOccurrences(of: #"[^A-Za-zА-Яа-яЇїІіЄєҐґ0-9\-\s]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if isLikelyMerchantName(cleaned) {
                return cleaned
            }
        }
        return "Unknown store"
    }

    // MARK: Amount

    func parseAmount(from text: String) throws -> Double {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)

        // 1) Highest priority: line containing total / paid amount hints (multilingual).
        let totalHints = ["total", "всього", "разом", "до оплати", "suma", "kwota", "naleznosc"]
        for line in lines {
            let lower = line.lowercased()
            guard totalHints.contains(where: { lower.contains($0) }) else { continue }
            if let amount = strongestAmount(in: line) {
                return amount
            }
        }

        // 2) Otherwise: take the largest plausible amount among all regex matches (heuristic: “total” is often largest).
        var candidates: [Double] = []
        for pattern in amountPatterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                !text.isEmpty
            else { continue }

            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let raw = String(text[range])
                if let value = normalizeAmount(raw), value > 0 {
                    candidates.append(value)
                }
            }
        }

        if let best = candidates.max() {
            return best
        }

        throw ReceiptParsingError.amountNotFound
    }

    // MARK: Date

    func parseDate(from text: String) -> Date? {
        for pattern in datePatterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let range = Range(match.range(at: 1), in: text)
            else { continue }

            let raw = String(text[range])
            if let date = dateFrom(rawDate: raw) {
                return date
            }
        }
        return nil
    }

    // MARK: Currency

    func parseCurrency(from text: String) -> Currency? {
        let uppercased = text.uppercased()
        if uppercased.contains("₴") || uppercased.contains("UAH") { return .uah }
        if uppercased.contains("$") || uppercased.contains("USD") { return .usd }
        if uppercased.contains("€") || uppercased.contains("EUR") { return .eur }
        if uppercased.contains("ZŁ") || uppercased.contains("PLN") { return .pln }
        return nil
    }

    // MARK: Category

    /// Keyword-based bucket guess. Lists mix English + regional terms so typical UA/PL receipts still match.
    func detectCategory(from text: String, shopName: String) -> ExpenseCategory {
        let lower = (text + " " + shopName).lowercased()
        let mappings: [(ExpenseCategory, [String])] = [
            (.groceries, ["сільпо", "silpo", "атб", "atb", "novus", "metro", "продукт", "маркет"]),
            (.transport, ["uber", "bolt", "таксі", "taxi", "ukrzaliz", "автобус", "пальне"]),
            (.dining, ["кафе", "ресторан", "coffee", "pizza", "sushi", "макдональдс"]),
            (.utilities, ["обленерго", "газ", "water", "комун", "електро", "internet"]),
            (.healthcare, ["аптека", "меди", "doctor", "лікар", "pharmacy"]),
            (.shopping, ["zara", "h&m", "reserved", "одяг", "взуття", "shop"]),
            (.entertainment, ["кіно", "cinema", "театр", "concert", "bar", "паб"])
        ]

        for (category, keywords) in mappings {
            if keywords.contains(where: { lower.contains($0) }) {
                return category
            }
        }
        return .other
    }

    // MARK: - Private helpers

    /// Normalizes European-style decimals (`1.234,56` vs `12.50`) into a `Double`-friendly string.
    private func normalizeAmount(_ value: String) -> Double? {
        let stripped = value
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")

        let pieces = stripped.split(separator: ".")
        if pieces.count > 2 {
            let integer = pieces.dropLast().joined()
            let decimal = pieces.last ?? ""
            return Double("\(integer).\(decimal)")
        }
        return Double(stripped)
    }

    /// Extracts all plausible currency-like numbers on a single line and returns the largest.
    private func strongestAmount(in text: String) -> Double? {
        let pattern = #"([0-9]{1,3}(?:[ \.,][0-9]{3})*(?:[.,][0-9]{2}))"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern)
        else {
            return nil
        }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let values = matches.compactMap { match -> Double? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return normalizeAmount(String(text[range]))
        }
        return values.max()
    }

    private func isLikelyMerchantName(_ candidate: String) -> Bool {
        if candidate.count < 3 { return false }
        if candidate.range(of: #"^[0-9\s\-]+$"#, options: .regularExpression) != nil { return false }
        let lowered = candidate.lowercased()
        if lowered.contains("receipt")
            || lowered.contains("paragon")
            || lowered.contains("fiskalny")
            || lowered.contains("nip")
            || lowered.contains("kasa")
            || lowered.contains("terminal")
        {
            return false
        }
        let lettersCount = candidate.filter { $0.isLetter }.count
        let digitsCount = candidate.filter { $0.isNumber }.count
        return lettersCount >= 3 && lettersCount >= digitsCount
    }

    private func dateFrom(rawDate: String) -> Date? {
        let formats = ["dd.MM.yyyy", "dd/MM/yyyy", "yyyy-MM-dd", "dd.MM.yy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: rawDate) {
                return date
            }
        }
        return nil
    }
}
