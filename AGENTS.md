# Satori project guidance

## Product intent

Satori is a local-first macOS learning workspace. Its primary job is to help a learner understand PDF-based material. It is not a note-taking product first.

## Persistent project memory

- Read `docs/brief.md`, `docs/status.md`, and relevant files in `docs/decisions/` before significant work.
- Update `docs/status.md` at the end of each meaningful implementation session.
- Record durable architectural choices in a numbered file under `docs/decisions/`.
- Keep this file short and limited to stable working rules.

## Scope and privacy

- Build for macOS only unless the user explicitly expands scope.
- Keep study files, reading position, project structure, and learning history local by default.
- Do not add source PDFs to Git. Store file bookmarks or local references instead.
- Treat OpenAI as an on-demand reasoning/search service, not as file hosting.
- Store a user-supplied OpenAI API key in macOS Keychain. Do not add plaintext key files or environment-variable fallbacks.

## Engineering rules

- Follow the established `mimi`/`kiri` pattern: native Swift Package Manager app, SwiftUI, PDFKit, and local JSON persistence before introducing third-party dependencies or an Xcode project.
- Add tests for new persistence and parsing behavior; visually check material UI changes.
- Make small, focused commits. Do not stage unrelated files.
