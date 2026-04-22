//
//  ReceiptAI_ParserApp.swift
//  ReceiptAI Parser
//
//  Created by Mykhailo Kravchuk on 20/04/2026.
//

// MARK: - Overview
/// Entry point of the iOS application.
/// - Configures **SwiftData** (`ModelContainer`) so `ExpenseTransaction` records persist on disk.
/// - Injects that container into the SwiftUI environment via `.modelContainer`, making `ModelContext`
///   available to views such as `ContentView` and `ReceiptPreviewView`.

import SwiftData
import SwiftUI

@main
struct ReceiptAI_ParserApp: App {
    /// Shared SwiftData container created once at launch.
    /// - **Happy path:** SQLite-backed store under Application Support (`ReceiptAIParserStore/receiptai.store`).
    /// - **Fallback:** If creating the on-disk store fails (permissions, corrupted file, etc.), an
    ///   **in-memory** container is used so the app still runs; data will not survive app restart in that case.
    private static var sharedModelContainer: ModelContainer = {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeDirectoryURL = appSupportURL.appendingPathComponent("ReceiptAIParserStore", isDirectory: true)

        do {
            // SwiftData/Core Data expect the parent directory to exist before opening a store URL.
            try fileManager.createDirectory(at: storeDirectoryURL, withIntermediateDirectories: true)
            let storeURL = storeDirectoryURL.appendingPathComponent("receiptai.store")
            let configuration = ModelConfiguration(url: storeURL)
            return try ModelContainer(for: ExpenseTransaction.self, configurations: configuration)
        } catch {
            // Last-resort path: keep the UI alive rather than crashing on store creation.
            let memoryConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: ExpenseTransaction.self, configurations: memoryConfiguration)
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(Self.sharedModelContainer)
    }
}
