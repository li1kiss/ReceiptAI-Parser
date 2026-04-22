//
//  ReceiptFlowViewModel.swift
//  ReceiptAI Parser
//
//  **Orchestrates the receipt → expense user journey** on the main actor:
//  camera / gallery image → OCR (`ReceiptOCRServicing`) → structured parse (`ReceiptParsingServicing`,
//  implemented by `AIReceiptParsingService` in production) → preview sheet → SwiftData save (`ExpenseStore`).
//
//  State machine (`FlowState`) drives UI affordances: spinner while `.processing`, alert on `.failed`, etc.
//

import Foundation
import SwiftData
import UIKit
internal import Combine

// MARK: - ReceiptFlowViewModel

@MainActor
final class ReceiptFlowViewModel: ObservableObject {
    /// High-level async steps for the receipt capture flow.
    enum FlowState: Equatable {
        case idle
        case processing
        case preview
        case saving
        case success
        case failed(String)
    }

    @Published private(set) var state: FlowState = .idle
    /// Last successful parse output; drives `ReceiptPreviewView` bindings until save or cancel.
    @Published var draft: ParsedReceiptData?
    @Published var shopName: String = ""
    @Published var amountText: String = ""
    @Published var transactionDate: Date = .now
    @Published var selectedCurrency: Currency = .uah
    @Published var selectedCategory: ExpenseCategory = .other
    /// When `true`, `ContentView` presents `ReceiptPreviewView` as a sheet.
    @Published var isPreviewPresented = false

    private let ocrService: ReceiptOCRServicing
    private let parsingService: ReceiptParsingServicing
    private let expenseStore: ExpenseStore

    init(
        ocrService: ReceiptOCRServicing = ReceiptOCRService(),
        parsingService: ReceiptParsingServicing = AIReceiptParsingService(),
        expenseStore: ExpenseStore = ExpenseStore()
    ) {
        self.ocrService = ocrService
        self.parsingService = parsingService
        self.expenseStore = expenseStore
    }

    /// Save button enabled when merchant non-empty and amount parses to a positive number.
    var canSave: Bool {
        guard let amount = parsedAmount else { return false }
        return !shopName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && amount > 0
    }

    // MARK: - Public actions

    /// Full async pipeline for a new `UIImage` from camera or photo picker.
    func processReceiptImage(_ image: UIImage) async {
        state = .processing

        do {
            let ocr = try await ocrService.recognizeText(from: image)
            let imageData = image.jpegData(compressionQuality: 0.85) ?? Data()
            let parsed = try await parsingService.parse(
                text: ocr.text,
                imageData: imageData,
                confidence: ocr.averageConfidence
            )

            applyDraft(parsed)
            state = .preview
            isPreviewPresented = true
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Persists the edited preview fields into SwiftData via `ExpenseStore`.
    func saveTransaction(in context: ModelContext) async {
        guard canSave, let draft else {
            state = .failed("Check the fields before saving.")
            return
        }

        guard let amount = parsedAmount else {
            state = .failed("Amount must be a valid number.")
            return
        }

        state = .saving

        do {
            try expenseStore.saveTransaction(
                shopName: shopName.trimmingCharacters(in: .whitespacesAndNewlines),
                amount: amount,
                date: transactionDate,
                currency: selectedCurrency,
                category: selectedCategory,
                receiptImageData: draft.receiptImageData,
                in: context
            )
            state = .success
            isPreviewPresented = false
            clearDraft()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Clears `.failed` back to `.idle` after the user dismisses an error alert.
    func resetError() {
        if case .failed = state {
            state = .idle
        }
    }

    // MARK: - Private helpers

    /// Copies parsed model output into `@Published` fields editable in the preview form.
    private func applyDraft(_ draft: ParsedReceiptData) {
        self.draft = draft
        self.shopName = draft.shopName
        self.amountText = String(format: "%.2f", draft.amount)
        self.transactionDate = draft.date
        self.selectedCurrency = draft.currency
        self.selectedCategory = draft.category
    }

    /// Resets transient editor state after a successful save (draft becomes nil).
    private func clearDraft() {
        draft = nil
        shopName = ""
        amountText = ""
        transactionDate = .now
        selectedCurrency = .uah
        selectedCategory = .other
    }

    /// Accepts both `12.34` and `12,34` decimal styles from manual edits.
    private var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "."))
    }
}
