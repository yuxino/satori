# 0001: Build a local-first macOS app

## Status

Accepted - 2026-08-03

## Context

The user studies primarily through local PDFs, wants reading progress and learning context retained, and only needs a computer client. Some source PDFs are scans while others contain selectable text.

## Decision

Build a native macOS app as a Swift Package, following the same toolchain pattern as the user's `mimi` and `kiri` apps. Use SwiftUI, PDFKit, and a versioned local JSON store. Keep PDFs at their existing local paths and store security-scoped bookmarks or local file references rather than copying books into the repository. Persist projects, reading state, source links, and AI conversation metadata locally. Use OpenAI only for on-demand explanations and search, with the API key stored in macOS Keychain.

## Consequences

- The app builds with Swift Package Manager and macOS Command Line Tools; a full Xcode installation is not required for this project.
- PDF viewing and local persistence work without an account or network connection.
- OCR and AI features can be introduced independently.
- Cross-device sync and other platforms are deliberately deferred.
