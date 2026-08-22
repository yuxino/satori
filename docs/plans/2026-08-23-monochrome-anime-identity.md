# Monochrome Anime Identity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Ship Satori 3.2.0 with a black-and-white interface, a restrained anime identity, a Kiri-inspired Satori mascot icon, and a cleaned production codebase.

**Architecture:** Preserve all existing product behavior and local data flows. Replace visual tokens and generated icon assets, then use reference searches plus compiler/linter checks to remove only proven dead code before producing the release bundle.

**Tech Stack:** TypeScript DOM UI, CSS, Vite, Tauri 2, Rust, macOS icon bundles.

---

### Task 1: Install the new icon identity

**Files:**
- Replace: `Resources/Assets/satori-icon.png`
- Regenerate: `src-tauri/icons/`

1. Generate a 1:1 Satori mascot master using the local Kiri icon as style reference and the current Satori mascot as identity reference.
2. Inspect the 1024px master and confirm no text, violet, pink, or copied Kiri decorations.
3. Replace the requested project icon master and run `npx tauri icon Resources/Assets/satori-icon.png`.
4. Inspect 128px and 512px outputs for small-size readability.

### Task 2: Apply the monochrome design system

**Files:**
- Modify: `src/styles.css`
- Modify: `src/main.ts`

1. Rename legacy lavender tokens to semantic accent tokens.
2. Replace blue-gray palettes with black, white, neutral gray, and a minimal warm-gold focus accent.
3. Convert generated book covers and activity levels to grayscale.
4. Reduce decorative shadows and keep focus, success, warning, and danger states accessible.
5. Build and launch with `npm run app`; inspect home, reader, question panel, and settings.

### Task 3: Remove proven dead code

**Files:**
- Inspect: `src/*.ts`, `src/styles.css`, `index.html`, `src-tauri/src/*.rs`

1. Run TypeScript unused-symbol checks and Rust Clippy.
2. Extract CSS class/id selectors and search their DOM/static references.
3. For every deletion candidate, confirm its definition is the only reference before removal.
4. Run `npx tsc --noEmit`, `npm run build`, `cargo check`, and `cargo test`.

### Task 4: Prepare and publish 3.2.0

**Files:**
- Modify: `package.json`, `package-lock.json`, `src-tauri/Cargo.toml`, `src-tauri/Cargo.lock`, `src-tauri/tauri.conf.json`
- Modify: `README.md`, `README_ZH.md`, `README_JA.md`
- Create: `docs/releases/v3.2.0.md`
- Modify: `docs/status.md`

1. Bump every package/app version to `3.2.0`.
2. Update all three README files with aligned product copy and the new shared icon asset.
3. Write release notes including macOS architecture, notarization status, and SHA-256.
4. Run the full verification suite and `npx tauri build`.
5. Verify the zipped app after extraction, then fast-forward `main`, push `main` and `v3.2.0`, and create the GitHub Release.
