//
//  ReceiptPreviewView.swift
//  ReceiptAI Parser
//
//  Modal “human in the loop” step after OCR + AI parsing.
//  Users can correct merchant, amount, date, currency, and category before persisting via `ExpenseStore`.
//
//  The sheet is presented from `ContentView` while `ReceiptFlowViewModel.isPreviewPresented` is true.
//

import SwiftData
import SwiftUI

struct ReceiptPreviewView: View {
    @ObservedObject var viewModel: ReceiptFlowViewModel
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let imageData = viewModel.draft?.receiptImageData,
                   let image = UIImage(data: imageData) {
                    Section("Receipt") {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            }
                    }
                }

                Section("Expense details") {
                    TextField("Merchant", text: $viewModel.shopName)
                        .textInputAutocapitalization(.words)
                    TextField("Amount", text: $viewModel.amountText)
                        .keyboardType(.decimalPad)

                    DatePicker("Date", selection: $viewModel.transactionDate, displayedComponents: .date)

                    Picker("Currency", selection: $viewModel.selectedCurrency) {
                        ForEach(Currency.allCases) { currency in
                            Text("\(currency.symbol) \(currency.rawValue)").tag(currency)
                        }
                    }

                    Picker("Category", selection: $viewModel.selectedCategory) {
                        ForEach(ExpenseCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                }

                if let confidence = viewModel.draft?.confidence {
                    Section("Recognition quality") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: confidence)
                            Text("Confidence: \(Int(confidence * 100))%")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let draft = viewModel.draft {
                    Section("Parsing source") {
                        Text(draft.parsingSource.rawValue)
                            .font(.subheadline)
                        if let note = draft.parsingNote, !note.isEmpty {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [Color.blue.opacity(0.10), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .navigationTitle("Review receipt")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        // Explicit flag keeps VM state consistent if dismiss is triggered programmatically.
                        viewModel.isPreviewPresented = false
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save transaction") {
                        Task {
                            await viewModel.saveTransaction(in: modelContext)
                            if case .success = viewModel.state {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!viewModel.canSave)
                }
            }
        }
    }
}
