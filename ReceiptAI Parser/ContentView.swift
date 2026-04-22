//
//  ContentView.swift
//  ReceiptAI Parser
//
//  Root screen: receipt capture, processing indicator, persisted transaction list (`@Query`),
//  preview sheet, and global error alert bound to `ReceiptFlowViewModel.state`.
//
//  Layout is intentionally split into small private subviews (`DashboardSummaryCard`, `TransactionRowCard`)
//  to keep `body` readable for portfolio reviewers.
//

import SwiftData
import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    /// Live list from SwiftData; sorted newest-first by `createdAt`.
    @Query(sort: \ExpenseTransaction.createdAt, order: .reverse) private var transactions: [ExpenseTransaction]
    @StateObject private var viewModel = ReceiptFlowViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                // Decorative background only; content remains readable in light/dark mode.
                LinearGradient(
                    colors: [Color.blue.opacity(0.12), Color.indigo.opacity(0.08), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        DashboardSummaryCard(
                            transactionsCount: transactions.count,
                            totalAmount: transactions.reduce(0) { $0 + $1.amount },
                            // If no rows yet, default symbol matches primary market demo (UA).
                            mainCurrencySymbol: transactions.first?.currency.symbol ?? "₴"
                        )

                        ReceiptCaptureView { image in
                            Task {
                                await viewModel.processReceiptImage(image)
                            }
                        }

                        if case .processing = viewModel.state {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .controlSize(.regular)
                                Text("Processing receipt...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(14)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }

                        if transactions.isEmpty {
                            ContentUnavailableView(
                                "No transactions yet",
                                systemImage: "doc.text.viewfinder",
                                description: Text("Add your first receipt to create an expense.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        } else {
                            VStack(spacing: 10) {
                                ForEach(transactions) { item in
                                    TransactionRowCard(item: item)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Receipt to Expense")
            .sheet(isPresented: $viewModel.isPreviewPresented) {
                ReceiptPreviewView(viewModel: viewModel, modelContext: modelContext)
            }
            // `Binding` bridges optional-ish alert presentation to `FlowState.failed`.
            .alert("Error", isPresented: Binding(
                get: {
                    if case .failed = viewModel.state { return true }
                    return false
                },
                set: { isShown in
                    if !isShown {
                        viewModel.resetError()
                    }
                })
            ) {
                Button("OK", role: .cancel) {
                    viewModel.resetError()
                }
            } message: {
                if case .failed(let message) = viewModel.state {
                    Text(message)
                } else {
                    Text("An unknown error occurred.")
                }
            }
        }
    }
}

// MARK: - Dashboard summary

/// Two-column summary: count of rows + naive sum of `amount` using the first row’s currency symbol.
/// Note: mixed-currency portfolios would need conversion; this demo assumes one primary currency.
private struct DashboardSummaryCard: View {
    let transactionsCount: Int
    let totalAmount: Double
    let mainCurrencySymbol: String

    var body: some View {
        HStack(spacing: 12) {
            summaryChip(
                title: "Transactions",
                value: "\(transactionsCount)",
                icon: "list.bullet.clipboard"
            )
            summaryChip(
                title: "Total",
                // `String(format:)` avoids Swift `String` interpolation limitations with `FormatStyle`.
                value: String(format: "%.2f %@", totalAmount, mainCurrencySymbol),
                icon: "creditcard"
            )
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func summaryChip(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Transaction row

/// Read-only card mirroring the most important `ExpenseTransaction` fields.
private struct TransactionRowCard: View {
    let item: ExpenseTransaction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.shopName)
                    .font(.headline)
                Spacer()
                Text("\(item.amount, format: .number.precision(.fractionLength(2))) \(item.currency.symbol)")
                    .font(.headline)
            }

            HStack {
                Label(item.category.rawValue, systemImage: "tag")
                Spacer()
                Label(item.date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    ContentView()
}
