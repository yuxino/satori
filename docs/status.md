# Current status

Updated: 2026-08-30

## Product

Satori is a local-first macOS and Windows PDF learning workspace. Reading stays central: the learner opens a local book, returns to the previous page, and explicitly asks for help with the current page or a selected region. It is not a general chat or note-taking product. The published download remains macOS-only; Windows source and packaging support are not yet native acceptance evidence.

## Current implementation

- Stack: Tauri 2, Vite, TypeScript, PDF.js, Rust, and local JSON persistence. The removed Swift app is available only at tag `legacy-swift`.
- Platforms: the base Tauri configuration keeps the macOS `.app` target. A Windows-only overlay adds current-user NSIS packaging for x64 and ARM64, with local state under application LocalAppData and a separate multi-resolution ICO.
- Reader: single/spread layouts, per-book page and zoom restoration, outline navigation, text and scanned-page rendering, and explicitly triggered VLM outline recovery for scanned books.
- Home: a restrained monochrome editorial layout containing the current book, 52-week activity grid, bookshelf, and recent Q&A. Book covers are sharp typographic covers rather than PDF thumbnails; labels describe questions and answers without claiming the learner understood them.
- Brand treatment: in-page product-name decoration has been removed so the reading content stays primary. The app name appears as `Satori` only where system context requires it; the home settings entry now uses a quieter, clearer labeled icon.
- Updates: the app checks GitHub Releases once after launch and offers a manual recheck in the settings header. A newer stable Release adds a quiet dot to the home settings button; settings distinguish a matching platform package from a Release that has no applicable installer and open only the official Releases page. Satori does not claim to install an update in place.
- Teacher: opening the page-side entry has no AI or secure-credential-store side effects. A request starts only after an explicit question, page explanation, region action, or outline-recognition action whose page range is disclosed first; page images are ephemeral.
- History: completed Q&A is stored locally per book, can reopen the source page, and sends only bounded recent text for follow-ups.
- AI services: multiple named Model Studio, OpenAI, or custom OpenAI-compatible visual profiles. The active profile is explicit and never silently replaced.
- Credentials: API keys live only in macOS Keychain or the current Windows user's Credential Manager with non-roaming `CRED_PERSIST_LOCAL_MACHINE` persistence. They remain bound to profile, normalized endpoint, and auth scope; the renderer receives existence status, never secret data.
- Safety: Rust resolves persisted profiles for AI commands, rejects insecure or overridden endpoints again before every save, disables redirects, sends `store: false` remotely, and does not read a key when auth is disabled. Normal questions send only the current page; adjacent pages require an explicit previous/next-page request. PDF.js is pinned to the patched 6.2.108 release; reopening a missing book fails closed instead of guessing a same-named path, and Tauri capabilities are least privilege.

## Version and installation

- Current source and published release version: `3.3.2`. The published asset is still Apple silicon only and contains the patched PDF.js, explicit page-transmission, request-safety, provider-validation, and capability hardening work described here.
- The downloadable bundle has a stable local signature and hardened-runtime flag, but no Apple Team ID or notarization; Gatekeeper assessment rejects it, so the documented Control-click opening step remains required.
- The `3.3.2` bundle declares macOS 14 as its minimum system version. The exact built payload was installed at `/Applications/Satori.app` and launched successfully.
- The manual Windows workflow targets native x64 and ARM64 runners, builds current-user NSIS packages, extracts each installer, and verifies that its payload matches the expected PE architecture. These artifacts are unsigned development packages, are not published in GitHub Releases, and still require native installation and interaction acceptance.

## Verification baseline

- Frontend: 24 Node tests, strict TypeScript unused-symbol checking, and the Vite production build pass; `npm audit` reports no known vulnerabilities. PDF.js loads as a separate reader-only chunk instead of delaying the home screen.
- Rust: the full test suite passes; `cargo fmt --check`, release and `dev-live` checks, and Clippy with warnings denied pass.
- Real app: the locally signed release app reports `v3.3.2`, uses the macOS 14 minimum-version metadata, opens its 1100 × 800 native window from `/Applications/Satori.app`, and remains running without a new crash report.
- Windows: configuration, credential, path, update-matching, and packaging checks are covered in source. Manual hosted x64/ARM64 build evidence is retained with the delivered artifacts; Windows 11 ARM64 install/launch/UI/uninstall acceptance remains pending until the reserved native slot is available.

## Repository hygiene

- `docs/plans/` is reserved for unfinished implementation work and is currently empty. Implemented plans remain recoverable from Git history.
- `docs/decisions/` contains only accepted constraints that still govern the Tauri application. Superseded Swift-era records were deleted and remain recoverable from Git history; ADR 0015 records the current manual-update boundary.
- Operational details for the stable development shell now live in ADR 0014 instead of an implemented task plan.
- Legacy Swift `Info.plist` / `.icns`, the copied public asset README, and the unused browser-preview script were removed. The current Tauri icon source and required macOS bundle sizes remain tracked.

## Durable constraints and pitfalls

- Run frontend builds before Rust checks; Vite rebuilds assets embedded by Tauri.
- On macOS, use `npm run app` for development viewing. Plain `tauri dev` changes the app identity and Dock icon behavior there; Windows development uses the Tauri source workflow instead.
- The real development app fails closed when no stable code-signing identity exists; ad-hoc signing is not a supported fallback because it changes macOS authorization identity after native rebuilds.
- A self-signed identity has no Apple Team ID. Native rebuilds may require one authorization per saved profile on its first explicit AI use; startup and status inspection must remain interaction-free.
- AI IPC accepts profile IDs only. Rust loads the trusted profile and verifies the credential scope before sending a request.
- Fixed-name PDF.js WASM decoders belong in `public/`; Vite-hashed imports break JBIG2/JPEG2000/ICC decoding.
- Opening a PDF must never trigger scanned-outline recovery. The directory action must disclose both bounded stages—including the exact page ranges and image counts for directory extraction and chapter-location sampling—and wait for an explicit click.
- Switching books invalidates any in-flight explanation. Late chunks and completed answers must never appear in, or be saved against, a different book.
- Removing a book must use separate accessible controls and an explicit destructive confirmation that names the local reading data and Q&A being removed.
- Update checks use only the fixed GitHub API endpoint and the build version; download actions may open only the exact official Releases URL. Do not imply in-place installation until signed updater artifacts and a durable release pipeline exist.
- Windows local state belongs in application LocalAppData, while credentials belong only in Windows Credential Manager with local-machine persistence. Do not add plaintext, environment-variable, roaming, renderer-visible, or cross-platform credential fallbacks.
- Windows packaging is manual-only, current-user NSIS. x64 and ARM64 workflow artifacts must remain separate, unsigned, and unpublished until each installer payload architecture is verified and native acceptance is complete.
- Store corruption or a newer schema must surface an error, never reset to a default provider or overwrite data.
- Do not restore plaintext API-key files, allow-all Keychain ACLs, renderer secrets, automatic AI requests, or legacy Swift packaging resources.

## Next work

1. Use the verified ARM64 development artifact to complete the Windows 11 ARM64 install/launch/PDF/interaction/persistence/taskbar/exit/uninstall checklist without a real API Key.
2. Add an explicit “relink moved PDF” flow that preserves the existing book ID and learning history; missing stored paths currently fail closed and require the learner to choose the file again.
3. Validate one real page question with Model Studio, OpenAI, and a local OpenAI-compatible visual service, then address extreme-page thumbnail and initial page-sizing memory costs from representative PDFs.
