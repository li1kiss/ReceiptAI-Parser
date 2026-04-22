# ReceiptAI Parser

A small **iOS** app (SwiftUI + SwiftData) that scans a receipt with the camera or photo library, runs **on-device OCR** (Vision), sends the image + text to **Google Gemini**, and saves an editable expense.

## Requirements

- **Xcode** 16+ (project uses Swift 6–style defaults)
- **iOS** 17.6+ simulator or device
- A **Google AI Studio** API key ([get a key](https://aistudio.google.com/))

## Setup (first run)

1. Open `GeminiInfo.plist` in the project root (next to `ReceiptAI Parser.xcodeproj`).
2. Paste your API key into **GeminiAPIKey** (between `<string>` and `</string>`).
3. Optionally change **GeminiModel** (default is `gemini-2.0-flash`).
4. Build and run the **ReceiptAI Parser** scheme.

Do not commit a real key if the repo is public.

## How it works (short)

1. User picks an image → **Vision** reads text.
2. **Gemini** `generateContent` returns strict JSON (shop, amount, date, currency, category).
3. User can edit fields → row is stored with **SwiftData**.

## Tests

**Product → Test** (`Cmd + U`). Tests use a fake HTTP stack (no real Gemini calls).
