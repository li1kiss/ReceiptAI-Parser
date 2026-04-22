//
//  ReceiptDomainModels.swift
//  ReceiptAI Parser
//
//  Shared enums used across parsing, preview, and persistence layers.
//  Keeping currency/category definitions here avoids circular dependencies between UI and services.
//

import Foundation

// MARK: - Currency

/// Supported ISO-style currency codes for expenses.
/// `rawValue` is persisted in SwiftData (`ExpenseTransaction.currencyCode`) and shown in pickers.
enum Currency: String, CaseIterable, Codable, Identifiable {
    case uah = "UAH"
    case usd = "USD"
    case eur = "EUR"
    case pln = "PLN"

    var id: String { rawValue }

    /// Display symbol used in list rows and summary cards (not localized; sufficient for portfolio demo).
    var symbol: String {
        switch self {
        case .uah: return "₴"
        case .usd: return "$"
        case .eur: return "€"
        case .pln: return "zł"
        }
    }
}

// MARK: - Expense category

/// High-level spending bucket; `rawValue` is user-facing English label and stored in SwiftData.
/// Gemini is instructed to return matching **snake_case-ish** API strings which `AIReceiptParsingService`
/// maps back to these cases.
enum ExpenseCategory: String, CaseIterable, Codable, Identifiable {
    case groceries = "Groceries"
    case transport = "Transport"
    case dining = "Dining"
    case utilities = "Utilities"
    case entertainment = "Entertainment"
    case healthcare = "Healthcare"
    case shopping = "Shopping"
    case other = "Other"

    var id: String { rawValue }
}
