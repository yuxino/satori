# Current status

Updated: 2026-08-26

## Product

Satori is a local-first macOS PDF learning workspace. Reading stays central: the learner opens a local book, returns to the previous page, and explicitly asks for help with the current page or a selected region. It is not a general chat or note-taking product.

## Current implementation

- Stack: Tauri 2, Vite, TypeScript, PDF.js, Rust, and local JSON persistence. The removed Swift app is available only at tag `legacy-swift`.
- Reader: single/spread layouts, per-book page and zoom restoration, outline navigation, text and scanned-page rendering, and VLM-based outline recovery.
- Home: a restrained monochrome editorial layout containing the current book, 52-week activity grid, bookshelf, and recent Q&A. Book covers are sharp typographic covers rather than PDF thumbnails; labels describe questions and answers without claiming the learner understood them.
- Brand treatment: in-page product-name decoration has been removed so the reading content stays primary. The app name appears as `Satori` only where system context requires it; the home settings entry now uses a quieter, clearer labeled icon.
- Teacher: opening the page-side entry has no AI or Keychain side effects. A request starts only after an explicit question, page explanation, or region action; page images are ephemeral.
- History: completed Q&A is stored locally per book, can reopen the source page, and sends only bounded recent text for follow-ups.
- AI services: multiple named Model Studio, OpenAI, or custom OpenAI-compatible visual profiles. The active profile is explicit and never silently replaced.
- Credentials: API keys live only in macOS Keychain and are bound to profile, normalized endpoint, and auth scope. The renderer receives existence status, never secret data.
- Safety: Rust resolves persisted profiles for AI commands, rejects insecure custom endpoints, disables redirects, sends `store: false` remotely, and does not read a key when auth is disabled.

## Version and installation

- Current release: `v3.3.1`, a maintenance release that removes completed plans and superseded Swift-era decisions, keeping current constraints in ADRs 0010–0014.
- The signed release bundle is built for Apple silicon and published through GitHub Releases; the same build is installed locally at `/Applications/Satori.app`.
- The previous local application bundle is kept as a timestamped backup in `/Applications`.

## Verification baseline

- Frontend: strict TypeScript unused-symbol check and Vite production build pass.
- Rust: 26 tests pass; `cargo fmt --check` and Clippy with warnings denied pass.
- Real app: the installed `.app` opens the home and settings screens without SecurityAgent/XARA activity.

## Repository hygiene

- `docs/plans/` is reserved for unfinished work and is currently empty. Implemented plans were removed and remain recoverable from Git history.
- `docs/decisions/` contains only accepted constraints that still govern the Tauri application. Superseded Swift-era records were deleted and remain recoverable from Git history.
- Operational details for the stable development shell now live in ADR 0014 instead of an implemented task plan.
- Legacy Swift `Info.plist` / `.icns`, the copied public asset README, and the unused browser-preview script were removed. The current Tauri icon source and required macOS bundle sizes remain tracked.

## Durable constraints and pitfalls

- Run frontend builds before Rust checks; Vite rebuilds assets embedded by Tauri.
- Use `npm run app` for development viewing. Plain `tauri dev` changes the app identity and Dock icon behavior.
- The real development app fails closed when no stable code-signing identity exists; ad-hoc signing is not a supported fallback because it changes macOS authorization identity after native rebuilds.
- A self-signed identity has no Apple Team ID. Native rebuilds may require one authorization per saved profile on its first explicit AI use; startup and status inspection must remain interaction-free.
- AI IPC accepts profile IDs only. Rust loads the trusted profile and verifies the credential scope before sending a request.
- Fixed-name PDF.js WASM decoders belong in `public/`; Vite-hashed imports break JBIG2/JPEG2000/ICC decoding.
- Store corruption or a newer schema must surface an error, never reset to a default provider or overwrite data.
- Do not restore plaintext API-key files, allow-all Keychain ACLs, renderer secrets, automatic AI requests, or legacy Swift packaging resources.

## Next work

1. Validate one real page question with Model Studio, OpenAI, and a local OpenAI-compatible visual service.
2. Install an Apple Development identity with a Team ID to eliminate the remaining native-rebuild authorization limitation.
3. Continue refining the reading and explanation flow from real study sessions; keep the home visually quiet.
