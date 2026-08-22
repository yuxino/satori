# Current status

Updated: 2026-08-23

## Product

Satori is a local-first macOS PDF learning workspace. Reading stays central: the learner opens a local book, returns to the previous page, and explicitly asks for help with the current page or a selected region. It is not a general chat or note-taking product.

## Current implementation

- Stack: Tauri 2, Vite, TypeScript, PDF.js, Rust, and local JSON persistence. The removed Swift app is available only at tag `legacy-swift`.
- Reader: single/spread layouts, per-book page and zoom restoration, outline navigation, text and scanned-page rendering, and VLM-based outline recovery.
- Home: a monochrome `READING PASS` containing the current book, 52-week activity grid, bookshelf, and recent understandings. Book covers are sharp typographic covers rather than PDF thumbnails.
- Teacher: opening the page-side entry has no AI or Keychain side effects. A request starts only after an explicit question, page explanation, or region action; page images are ephemeral.
- History: completed Q&A is stored locally per book, can reopen the source page, and sends only bounded recent text for follow-ups.
- AI services: multiple named Model Studio, OpenAI, or custom OpenAI-compatible visual profiles. The active profile is explicit and never silently replaced.
- Credentials: API keys live only in macOS Keychain and are bound to profile, normalized endpoint, and auth scope. The renderer receives existence status, never secret data.
- Safety: Rust resolves persisted profiles for AI commands, rejects insecure custom endpoints, disables redirects, sends `store: false` remotely, and does not read a key when auth is disabled.

## Version and installation

- Latest published release: `v3.2.0` on `main`.
- The current refinement branch adds the reading-pass home and revised Satori mascot border; it has been built and installed locally at `/Applications/Satori.app` but is not a new public release yet.
- The previous local application bundle is kept as a timestamped backup in `/Applications`.

## Verification baseline

- Frontend: strict TypeScript unused-symbol check and Vite production build pass.
- Rust: 26 tests pass; `cargo fmt --check` and Clippy with warnings denied pass.
- Real app: the installed `.app` opens the home and settings screens without SecurityAgent/XARA activity.

## Repository hygiene

- `docs/plans/` keeps only the active product, Dock-icon, and reading-pass designs; implemented or superseded task plans were removed and remain recoverable from Git history.
- Legacy Swift `Info.plist` / `.icns`, the copied public asset README, and the unused browser-preview script were removed. The current Tauri icon source and required macOS bundle sizes remain tracked.
- Swift-era ADRs are retained as history only when their status explicitly names the current superseding decision.

## Durable constraints and pitfalls

- Run frontend builds before Rust checks; Vite rebuilds assets embedded by Tauri.
- Use `npm run app` for development viewing. Plain `tauri dev` changes the app identity and Dock icon behavior.
- A self-signed identity has no Apple Team ID. Native rebuilds may require one authorization per saved profile on its first explicit AI use; startup and status inspection must remain interaction-free.
- AI IPC accepts profile IDs only. Rust loads the trusted profile and verifies the credential scope before sending a request.
- Fixed-name PDF.js WASM decoders belong in `public/`; Vite-hashed imports break JBIG2/JPEG2000/ICC decoding.
- Store corruption or a newer schema must surface an error, never reset to a default provider or overwrite data.
- Do not restore plaintext API-key files, allow-all Keychain ACLs, renderer secrets, automatic AI requests, or legacy Swift packaging resources.

## Next work

1. Validate one real page question with Model Studio, OpenAI, and a local OpenAI-compatible visual service.
2. Install an Apple Development identity with a Team ID to eliminate the remaining native-rebuild authorization limitation.
3. Publish the current icon and reading-pass refinements as the next patch release after visual approval.
