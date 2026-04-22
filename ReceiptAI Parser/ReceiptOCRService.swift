//
//  ReceiptOCRService.swift
//  ReceiptAI Parser
//
//  On-device text recognition using Apple **Vision** (`VNRecognizeTextRequest`).
//  Output is plain string + average confidence; that text is passed to Gemini alongside the image.
//
//  Design notes:
//  - Runs **off the main thread** inside Vision’s completion handler; the public API is `async` via
//    `withCheckedThrowingContinuation` so callers (`ReceiptFlowViewModel`) can `await` cleanly.
//  - `recognitionLanguages` biases the recognizer toward Ukrainian / English / Polish receipts.
//

import Foundation
import UIKit
import Vision

// MARK: - OCR result

/// Aggregated output of a single OCR pass over a receipt image.
struct OCRResult {
    /// All recognized lines joined with newlines (same order Vision returns observations).
    let text: String
    /// Mean of per-line `VNRecognizedText` confidence scores in `0...1`.
    let averageConfidence: Double
}

// MARK: - Errors

enum ReceiptOCRError: LocalizedError {
    case invalidImage
    case noTextRecognized

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Could not process the receipt image."
        case .noTextRecognized:
            return "No text was recognized on the receipt."
        }
    }
}

// MARK: - Protocol (testability)

/// Abstraction over Vision so tests can inject a fake OCR implementation if needed.
protocol ReceiptOCRServicing {
    func recognizeText(from image: UIImage) async throws -> OCRResult
}

// MARK: - Vision implementation

final class ReceiptOCRService: ReceiptOCRServicing {
    /// Performs OCR on `image` and returns concatenated text + confidence.
    /// - Throws: `ReceiptOCRError.invalidImage` if `cgImage` is missing (rare for `UIImage` from camera/photos).
    /// - Throws: `ReceiptOCRError.noTextRecognized` if Vision yields no usable string content.
    func recognizeText(from image: UIImage) async throws -> OCRResult {
        guard let cgImage = image.cgImage else {
            throw ReceiptOCRError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(throwing: ReceiptOCRError.noTextRecognized)
                    return
                }

                // Each observation may have multiple string hypotheses; we take the best one per box.
                let candidates = observations.compactMap { $0.topCandidates(1).first }
                let textLines = candidates.map(\.string)
                let fullText = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

                guard !fullText.isEmpty else {
                    continuation.resume(throwing: ReceiptOCRError.noTextRecognized)
                    return
                }

                let confidence = candidates.isEmpty
                    ? 0
                    : Double(candidates.reduce(Float(0)) { $0 + $1.confidence }) / Double(candidates.count)

                continuation.resume(
                    returning: OCRResult(
                        text: fullText,
                        averageConfidence: confidence
                    )
                )
            }

            // `.accurate` trades speed for better results on small print / thermal receipts.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["uk-UA", "en-US", "pl-PL"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
