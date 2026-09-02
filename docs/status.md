# Current status

Updated: 2026-09-02

## Product

Satori is a local-first macOS and Windows PDF learning workspace. Reading stays central: the learner opens or drags in a local book, returns to the previous page, and explicitly asks for help with the current page or a selected region. It is not a general chat or note-taking product. Version 3.4.4 is the signed-updater bootstrap release: it replaces the browser-first download handoff with an explicit in-app check, release-note review, download, framework signature verification, installation, and platform-accurate restart flow without changing reading, AI, or local data formats.

## Current implementation

- Stack: Tauri 2, Vite, TypeScript, PDF.js, Rust, and local JSON persistence. The removed Swift app is available only at tag `legacy-swift`.
- Platforms: the base Tauri configuration keeps the macOS `.app` target. A Windows-only overlay adds current-user NSIS packaging for x64 and ARM64, with local state under application LocalAppData and a transparent multi-resolution ICO shared by the app, installer, and uninstaller. CI installs each candidate, checks exact `Satori` identity in executable metadata, HKCU uninstall data, Start menu, and Desktop shortcuts, then requires the application, install directory, uninstall entry, and shortcuts to be absent after uninstall.
- Process integrity: Satori allows one process to own its data directory. A secondary launch restores, shows, and focuses the existing window, while a process-lifetime lock is acquired before the renderer can load so two writers cannot race the shared Store.
- Reader: single/spread layouts, per-book page and zoom restoration, outline navigation, text and scanned-page rendering, and explicitly triggered VLM outline recovery for scanned books. Initial opening now preflights PDF completeness, shows byte/page/render progress, supports cancellation and stall recovery, batches page metadata, bounds canvas memory, and records interrupted opens as retryable bookshelf errors. Ctrl+wheel is reserved for zoom, same-page render/layout callbacks do not inflate reading activity, and normal window/menu exits flush the latest debounced page and zoom snapshot before terminating.
- Home: a restrained monochrome editorial layout containing the current book, 52-week activity grid, bookshelf, and recent Q&A. Each bookshelf row has a visible removal action whose confirmation states that the disk PDF is preserved. Removing a non-current book now refreshes every open bookshelf surface, while removing the current book opens the first remaining book or returns to the empty home view. Book covers are sharp typographic covers rather than PDF thumbnails; labels describe questions and answers without claiming the learner understood them.
- Brand treatment: in-page product-name decoration has been removed so the reading content stays primary. The app name appears as `Satori` only where system context requires it; the home settings entry now uses a quieter, clearer labeled icon.
- Updates: the official Tauri updater checks one fixed HTTPS `latest.json` after launch and offers a manual recheck in settings. It displays the version and Release notes before any download, shows real byte progress or an indeterminate state, exposes installation only after framework signature verification, and never downloads or installs in the background. Installation first flushes the latest reading position and fails closed if persistence fails. macOS waits for an explicit “重启并完成”; Windows exits after the explicit install action and hands control to a visible `basicUi` installer. GitHub Releases appears only as error recovery.
- Import: the native window accepts one dropped PDF at a time and shares the same import, preflight, progress, cancellation, recovery, and persistence path as the file picker.
- Teacher: startup, importing, reading, and library management have no AI or secure-credential-store side effects. Credential checking begins only after an explicit question, page explanation, region action, or outline-recognition action whose page range is disclosed first; missing configuration opens settings, request failures have actionable Windows/provider guidance and explicit retry, and page images are ephemeral.
- History: completed Q&A is stored locally per book, can reopen the source page, and sends only bounded recent text for follow-ups.
- AI services: multiple named Model Studio, OpenAI, or custom OpenAI-compatible visual profiles. The active profile is explicit and never silently replaced.
- Credentials: API keys live only in macOS Keychain or the current Windows user's Credential Manager with non-roaming `CRED_PERSIST_LOCAL_MACHINE` persistence. They remain bound to profile, normalized endpoint, and auth scope; the renderer receives existence status, never secret data. Windows Store and credential-scope sidecars now use native overwrite-capable atomic replacement, so repeated saves do not fail after the first file exists.
- Safety: Rust resolves persisted profiles for AI commands, rejects insecure or overridden endpoints again before every save, disables redirects, sends `store: false` remotely, and does not read a key when auth is disabled. Normal questions send only the current page; adjacent pages require an explicit previous/next-page request. PDF.js is pinned to the patched 6.2.108 release; reopening a missing book fails closed instead of guessing a same-named path, and Tauri capabilities are least privilege.

## Version and installation

- Current source version: `3.4.4`. This bootstrap release provides macOS 14+ Apple silicon and Windows 11 x64 and ARM64 downloads plus a Tauri updater artifact/signature for each architecture and one static `latest.json`. Installations on 3.4.3 or earlier must install 3.4.4 manually once.
- The downloadable bundle has a stable local signature and hardened-runtime flag, but no Apple Team ID or notarization; Gatekeeper assessment rejects it, so the documented Control-click opening step remains required.
- The macOS bundle declares macOS 14 as its minimum system version. Release packaging verifies the bundle signature, hardened runtime, version, archive integrity, and SHA-256 before publication.
- The Windows workflow remains non-publishing when run alone, but the explicit updater release workflow can reuse it. Native x64 and ARM64 runners build unsigned current-user NSIS packages plus updater signatures, extract each installer, verify a unique payload and expected PE architecture, install it, check application and shortcut identity, uninstall it completely, and record separate SHA-256 manifests before publication. The publishing workflow independently verifies all three updater signatures against the embedded public key before making the Release public.

## Verification baseline

- Frontend: 64 Node tests cover updater success/failure, known and unknown totals, repeated actions, cancellation/retry, persistence-checkpoint failure, release metadata/checksum validation, and platform installation semantics; strict TypeScript checking and the Vite production build pass, and `npm audit` reports no known vulnerabilities. PDF.js remains a separate reader-only chunk.
- Rust: all 43 remaining native tests pass after removing the obsolete custom GitHub release checker; `cargo fmt --check`, release and `dev-live` checks, and Clippy with warnings denied pass. The official updater/process plugins compile with the least-privilege capability set.
- Real app: the stable signed development shell rebuilt, passed its designated-requirement check, and launched the native `Satori` window. It immediately entered existing reading state, so QA stopped without opening settings, books, AI actions, or credentials; updater UI interaction is not claimed from that launch.
- Windows historical baseline: hosted run `33309980178` passed frontend and Rust checks, exact installer naming, unique NSIS payload extraction, PE architecture checks, current-user install identity, shortcuts, uninstall, and artifact upload for x64 and ARM64 at `b4bc922555f138eed45e4a23e667d1bd755949e8`. Windows 11 25H2 ARM64 UTM run `307e21ee-ce24-4a2e-96db-8a7da4d872c8` installed and launched that exact ARM64 candidate, opened the synthetic three-page PDF, navigated pages, zoomed, selected a region, persisted page and Q&A state across two restarts, and passed taskbar, maximize, normal-close, and Alt+F4 interaction checks. Those bytes predate 3.4.3 and are comparison evidence only. Each 3.4.4 Windows asset must still come from the exact final main SHA and pass independent installer, payload, architecture, identity, full-uninstall, updater-signature, and SHA-256 checks; x64-on-x64 manual interaction is not inferred from ARM64 or hosted CI.

## Repository hygiene

- `docs/plans/` is reserved for unfinished implementation work and is currently empty. Implemented plans remain recoverable from Git history.
- `docs/decisions/` contains current constraints plus superseded records that explain public-version migration. ADR 0019 governs signed in-app updates and marks the older manual update/promotion boundaries as historical.
- Operational details for the stable development shell now live in ADR 0014 instead of an implemented task plan.
- Legacy Swift `Info.plist` / `.icns`, the copied public asset README, and the unused browser-preview script were removed. The current Tauri icon source and required macOS bundle sizes remain tracked.
- Tauri capability schemas generated for desktop, macOS, and Windows are tracked. Their JSON content currently matches, so a Windows build no longer dirties the source tree by introducing `windows-schema.json`.
- The 3.4.2 cleanup removed an unreachable pre-home empty-state stylesheet, consolidated release-version display logic, and merged the update-copy checks into the existing platform test surface without reducing behavioral coverage.
- The 3.4.3 audit removed a superseded PDF-loading wrapper and its dead export, deleted an unreferenced 1,443,308-byte Windows icon source, and stopped embedding 2,074,834 bytes of production source maps. The existing loading behavior tests now exercise the live monitor directly; all 47 frontend behavior tests remain. Release builds also use one codegen unit because the measured binary reduction is material and does not weaken runtime or diagnostic coverage.

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
- Update checks use only the fixed HTTPS updater manifest and embedded public key. Never enable insecure transport, accept an unsigned artifact, expose installation before the official plugin resolves signature verification, rotate the key without an old-key bridge release, or use Releases as the normal download path.
- Windows local state belongs in application LocalAppData, while credentials belong only in Windows Credential Manager with local-machine persistence. Do not add plaintext, environment-variable, roaming, renderer-visible, or cross-platform credential fallbacks.
- Windows file replacement must preserve overwrite semantics for both Store JSON and credential-scope markers; do not restore direct `std::fs::rename` over an existing destination.
- Windows packaging is current-user NSIS and remains manual/non-publishing when run alone. Keep x64 and ARM64 installers, updater signatures, and SHA-256 manifests separate. Publishing requires the explicit updater release workflow, exact filename/count checks, extraction, a unique application payload, matching PE architecture, product identity, hosted install/full-uninstall verification, complete `latest.json`, and explicit disclosure of Authenticode and native-acceptance boundaries.
- Store corruption or a newer schema must surface an error, never reset to a default provider or overwrite data.
- Normal window, taskbar, Alt+F4, and app-menu exits must checkpoint the latest page and zoom, cancel pending debounce timers, and await the final atomic Store save before process termination.
- Do not restore plaintext API-key files, allow-all Keychain ACLs, renderer secrets, automatic AI requests, or legacy Swift packaging resources.

## Next work

1. Exercise the complete updater flow from an isolated older updater-capable build to the exact 3.4.4 bytes on macOS and both Windows architectures without touching a real bookshelf or credentials; separately complete x64 manual interaction acceptance on x64 Windows 11.
2. Add an explicit “relink moved PDF” flow that preserves the existing book ID and learning history; missing stored paths currently fail closed and require the learner to choose the file again.
3. Extend AI acceptance beyond the one configured provider and synthetic PDF used here to Model Studio, OpenAI, and a local OpenAI-compatible visual service with representative learning material, then address extreme-page thumbnail and initial page-sizing memory costs.
