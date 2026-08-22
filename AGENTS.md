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
- Treat configured AI services as on-demand page-understanding providers, not as file hosting.
- Support multiple local provider profiles. Keep non-secret endpoints and model IDs in local JSON, but store every user-supplied API key only in macOS Keychain. Never write a key into the repository, local JSON, logs, screenshots, environment variables, or WebView state.
- Keep the active profile and model configurable and persisted locally. A configured model must support scanned-page image input; never silently fall back to another provider.
- Treat user-selected question images as ephemeral request context: resize locally, send only on submission, and do not persist them without an explicit product decision.
- Keep per-document learning sessions in local Application Support storage; send only bounded recent text turns for follow-ups and keep provider response storage disabled.

## Engineering rules

- Follow the Satori 3.0 stack: Tauri 2, TypeScript/Vite, PDF.js, Rust, and local JSON persistence. Keep dependencies small and justify new ones.
- The legacy Swift app exists only in tag `legacy-swift`; do not restore its source or packaging resources to the working tree.
- Run frontend builds before Rust checks because Vite rebuilds assets embedded by Tauri.
- Add tests for new persistence and parsing behavior; visually check material UI changes.
- Make small, focused commits. Do not stage unrelated files.
