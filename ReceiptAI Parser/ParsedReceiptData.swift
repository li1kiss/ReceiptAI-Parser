//
//  ParsedReceiptData.swift
//  ReceiptAI Parser
//
//  Domain model representing the **result of parsing** a receipt before the user confirms save.
//  It bridges OCR + AI output into editable fields on `ReceiptPreviewView`.
//

import Foundation

// MARK: - Parsing source

/// Indicates whether structured fields came from **Gemini** or a **local** parser (e.g. unit tests / legacy).
/// The app’s production path uses Gemini only; `localFallback` remains for tooling and tests.
enum ParsingSource: String {
    case aiGemini = "AI (Gemini)"
    case localFallback = "Local fallback"
}

// MARK: - Parsed receipt draft

/// In-memory snapshot produced after OCR (and, in production, after the Gemini API returns JSON).
/// - `receiptImageData`: JPEG bytes used for API multimodal input and later persisted on `ExpenseTransaction`.
/// - `rawText`: full OCR text; useful for debugging and optional future features (search, re-parse).
/// - `confidence`: average Vision OCR confidence (0…1), shown in the preview as a quality hint.
/// - `parsingNote`: optional human-readable explanation (errors, fallbacks, etc.).
struct ParsedReceiptData: Identifiable {
    let id = UUID()
    var shopName: String
    var amount: Double
    var date: Date
    var currency: Currency
    var category: ExpenseCategory
    var receiptImageData: Data
    var rawText: String
    var confidence: Double
    var parsingSource: ParsingSource
    var parsingNote: String?
}
