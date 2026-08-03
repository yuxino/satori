# Current status

## Project state

The first runnable macOS build is complete. It is a Swift Package app that builds with the same Command Line Tools workflow as `mimi` and `kiri`.

## Confirmed decisions

- Name: `satori`
- Platform: macOS only
- Product focus: PDF understanding rather than compulsory note-taking
- Initial plan: Advanced Programming, Software Engineering, and Operating Systems
- Storage: local-first; OpenAI is used on demand for reasoning and search
- Toolchain: native Swift Package Manager app, following the user's `mimi` and `kiri` projects

## Completed in the first build

- Native Satori.app package and ad-hoc local signing script
- Three course workspaces and seeded learning directories
- Local JSON persistence in Application Support
- PDF import, text/scanned/mixed classification, and PDFKit reader
- Persisted page-based reading position
- Always-visible current/total page indicator with previous, next, and direct page jump controls
- Per-course PDF menu for switching, replacing, or removing an incorrect import without deleting the original file
- Keychain-only OpenAI API-key settings screen; no plaintext key path
- A visible AI assistant boundary that labels its current response source

The supplied PDFs were imported for local verification: `lang.pdf` and `software.pdf` classify as scanned; `system.pdf` classifies as text.

## Next milestone

Connect the assistant boundary to the OpenAI Responses API after the user supplies an API key, then add OCR-based editable table-of-contents extraction and source/URL/code attachments.

## Open questions

- Which minimum macOS version should Satori support?
- Should web search be available from the first interactive build or follow the PDF reading loop?
- Which course should become the first end-to-end import fixture?
