# Multi-provider Settings Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add multiple secure AI provider profiles and replace the Alibaba-only settings modal with a polished, accessible macOS-style connection manager.

**Architecture:** Persist only non-secret `AIProfile` records in the local store, keep one active profile ID, and store each profile secret under its stable ID in macOS Keychain. Route all current visual workflows through one OpenAI-compatible Rust client with provider-specific request options and a profile-based frontend API.

**Tech Stack:** Tauri 2, Rust, reqwest, keyring, TypeScript, Vite, CSS, PDF.js.

---

### Task 1: Add the profile schema and legacy migration

**Files:**
- Modify: `src-tauri/src/store.rs`
- Modify: `src/api.ts`

**Steps:**

1. Add a failing Rust test that deserializes the old `{ "settings": { "model_id": "qwen-vl-max" } }` shape and expects one active Model Studio profile with that model.
2. Run `cargo test --manifest-path src-tauri/Cargo.toml store::tests` and confirm it fails.
3. Add `AIProviderKind`, `AIProfile`, the new `Settings`, and normalization after load.
4. Add matching TypeScript types and a safe `emptyStore()` default.
5. Run the Rust test and `npm run build`.

### Task 2: Make Keychain storage profile-scoped

**Files:**
- Modify: `src-tauri/src/keychain.rs`
- Modify: `src-tauri/src/lib.rs`
- Modify: `src/api.ts`

**Steps:**

1. Add pure tests for accepted/rejected profile IDs and the deterministic Keychain account name.
2. Implement `credential_status`, `save_profile_api_key`, and `delete_profile_api_key` commands.
3. Migrate the old Qwen v3/v2 entries only when reading the fixed default Model Studio profile.
4. Remove the development plaintext key read/write path and old commands.
5. Expose only status/save/delete wrappers to TypeScript; never expose a saved key value.
6. Run Rust tests and the frontend build.

### Task 3: Generalize the visual AI client

**Files:**
- Modify: `src-tauri/src/qwen.rs`
- Modify: `src-tauri/src/lib.rs`
- Modify: `src/api.ts`

**Steps:**

1. Add failing unit tests for URL normalization, HTTP(S) validation, provider-specific token/store fields, SSE parsing, error-body parsing, and non-stream text extraction.
2. Replace fixed base URL/model/key parameters with a validated `AIProfile` and a Rust-side Keychain lookup.
3. Keep Chat Completions image parts, use `store: false` for every remote connection, and select the token-limit field by provider kind.
4. Rename stream events to `ai://chunk` and make errors provider-neutral.
5. Add a minimal `test_ai_profile` command that sends no book image.
6. Update all frontend command wrappers.
7. Run focused Rust tests, `cargo test`, and `npm run build`.

### Task 4: Route every learning workflow through the active profile

**Files:**
- Modify: `src/main.ts`

**Steps:**

1. Add helpers to resolve the active profile and refresh its credential status.
2. Remove the global plaintext `apiKey` state.
3. Update page questions, region questions, follow-ups, outline extraction, and title location to pass the active profile.
4. Open settings with an actionable message when no usable profile exists.
5. Make `persist()` surface failures to settings operations instead of always swallowing them.
6. Run `npm run build`.

### Task 5: Build the multi-profile settings sheet

**Files:**
- Create: `src/settings.ts`
- Modify: `src/main.ts`
- Modify: `src/styles.css`

**Steps:**

1. Create a profile settings controller with master-detail rendering, drafts, provider presets, validation, save/test/activate/delete actions, and credential replacement/removal.
2. Replace `openSettings()` with the controller and make repeated opens idempotent.
3. Add dialog semantics, focus trapping/restoration, Esc handling, status live regions, button loading states, and destructive confirmations.
4. Add semantic color/focus tokens, responsive settings layout, dark mode colors, and reduced-motion handling.
5. Keep the existing paper-and-lavender Satori visual language while reducing pills and shadow weight inside settings.
6. Run `npm run build`.

### Task 6: Verify and document

**Files:**
- Create: `docs/decisions/0011-multi-provider-profiles.md`
- Modify: `AGENTS.md`
- Modify: `docs/status.md`

**Steps:**

1. Run `cargo fmt --manifest-path src-tauri/Cargo.toml -- --check`, `cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings`, `cargo test --manifest-path src-tauri/Cargo.toml`, and `npm run build`.
2. Launch the packaged app through `scripts/dev-app.sh`.
3. Inspect the settings sheet in light and dark appearance, plus a narrow window; verify initial, saved, testing, error, and add-profile states without exposing secrets.
4. Record the durable architecture and the superseded Alibaba-only constraint in ADR 0011 and `AGENTS.md`.
5. Update `docs/status.md` with the completed feature, migration behavior, verification commands, and any remaining live-provider validation gap.
6. Commit focused implementation and documentation changes.
