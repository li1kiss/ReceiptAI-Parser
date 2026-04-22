//
//  ExpenseTransaction.swift
//  ReceiptAI Parser
//
//  SwiftData `@Model` for a persisted expense row.
//  Currency and category are stored as **strings** (`currencyCode`, `categoryRawValue`) because
//  SwiftData persists primitive-friendly fields; computed properties bridge back to typed enums.
//

import Foundation
import SwiftData

@Model
final class ExpenseTransaction {
    var shopName: String
    var amount: Double
    var date: Date
    /// Persisted `Currency.rawValue` (e.g. `"UAH"`).
    var currencyCode: String
    /// Persisted `ExpenseCategory.rawValue` (e.g. `"Groceries"`).
    var categoryRawValue: String
    /// JPEG (or other) bytes of the receipt image for display / export.
    var receiptImageData: Data
    /// Timestamp when the row was inserted; used for default sorting in `ContentView`’s `@Query`.
    var createdAt: Date

    init(
        shopName: String,
        amount: Double,
        date: Date,
        currency: Currency,
        category: ExpenseCategory,
        receiptImageData: Data,
        createdAt: Date = .now
    ) {
        self.shopName = shopName
        self.amount = amount
        self.date = date
        self.currencyCode = currency.rawValue
        self.categoryRawValue = category.rawValue
        self.receiptImageData = receiptImageData
        self.createdAt = createdAt
    }

    /// Typed currency; falls back to **UAH** if stored code is unknown (e.g. after a schema experiment).
    var currency: Currency {
        Currency(rawValue: currencyCode) ?? .uah
    }

    /// Typed category; falls back to **Other** if label changed between app versions.
    var category: ExpenseCategory {
        ExpenseCategory(rawValue: categoryRawValue) ?? .other
    }
}
