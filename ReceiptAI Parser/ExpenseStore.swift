//
//  ExpenseStore.swift
//  ReceiptAI Parser
//
//  Thin persistence layer over SwiftData’s `ModelContext`.
//  Isolating `insert` + `save` here keeps `ReceiptFlowViewModel` focused on flow / UI state.
//

import Foundation
import SwiftData

struct ExpenseStore {
    /// Creates and inserts an `ExpenseTransaction`, then commits the context.
    /// - Parameters:
    ///   - shopName, amount, date, currency, category: user-confirmed values from preview.
    ///   - receiptImageData: binary snapshot of the receipt (typically JPEG from the flow).
    ///   - context: SwiftData context from the view hierarchy (`@Environment(\.modelContext)`).
    /// - Throws: Any SwiftData error from `save()` (disk full, validation, etc.).
    func saveTransaction(
        shopName: String,
        amount: Double,
        date: Date,
        currency: Currency,
        category: ExpenseCategory,
        receiptImageData: Data,
        in context: ModelContext
    ) throws {
        let transaction = ExpenseTransaction(
            shopName: shopName,
            amount: amount,
            date: date,
            currency: currency,
            category: category,
            receiptImageData: receiptImageData
        )
        context.insert(transaction)
        try context.save()
    }
}
