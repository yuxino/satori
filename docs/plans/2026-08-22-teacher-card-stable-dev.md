# Teacher Card and Stable Development Shell Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the question card visually compact and keep the signed development shell stable across frontend-only rebuilds so Keychain authorization is not repeated.

**Architecture:** A `dev-live` Cargo feature replaces Tauri's embedded asset handler with a traversal-safe handler rooted at `dist/`. The development launcher fingerprints only native inputs plus the signing identity, rebuilding the signed app only when that fingerprint changes; production builds keep embedded assets.

**Tech Stack:** Tauri 2, Rust, TypeScript/Vite, CSS, macOS codesign and Keychain.

---

### Task 1: Secure development asset path resolution

**Files:**
- Modify: `src-tauri/Cargo.toml`
- Modify: `src-tauri/src/lib.rs`

**Steps:**

1. Add failing Rust tests for `/`, `/assets/app.js`, `/../store.json`, and `/%2e%2e/store.json`.
2. Run `cargo test --manifest-path src-tauri/Cargo.toml dev_asset` and confirm the helper is missing.
3. Add a `dev-live` feature, safe path resolver, MIME mapping, no-store response, and feature-gated `tauri://` protocol registration.
4. Run the targeted tests and full Rust tests.

### Task 2: Reuse the signed native development shell

**Files:**
- Modify: `scripts/dev-app.sh`
- Modify: `.agents/skills/satori-dev-launch/SKILL.md`
- Modify: `docs/decisions/0012-development-keychain-authorization.md`

**Steps:**

1. Build the frontend on every launch.
2. Hash native source/config/icon/script inputs together with the selected signing identity.
3. Rebuild with `tauri/custom-protocol,dev-live`, assemble, and sign only when the hash changed or signature verification fails.
4. Reuse the existing `.app` otherwise and print whether the native identity was preserved.
5. Run `bash -n scripts/dev-app.sh` and launch twice around a frontend-only edit; confirm the CDHash is unchanged.

### Task 3: Compact page-note question card

**Files:**
- Modify: `src/styles.css`

**Steps:**

1. Change the card to a slightly wider but shorter page-note composition.
2. Use sans-serif 14px answer copy with 1.65 line height and tighter Markdown rhythm.
3. Reduce action and composer visual weight while keeping 32px minimum controls and visible focus states.
4. Run `npm run build`, launch with the project development command, and inspect the same saved answer at normal and minimum window sizes.

### Task 4: Verification and project memory

**Files:**
- Modify: `docs/status.md`

**Steps:**

1. Run `cargo test`, `cargo clippy --all-targets -- -D warnings`, targeted rustfmt check, `npm run build`, `bash -n`, and `git diff --check`.
2. Inspect macOS security logs for new XARA prompts after the frontend-only second launch.
3. Record the verified behavior and the remaining native-rebuild limitation in `docs/status.md`.
4. Commit focused code and documentation changes.
