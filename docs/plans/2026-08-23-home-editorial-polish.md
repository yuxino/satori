# Home Editorial Polish Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Remove the token-like “悟” branding and make the home screen denser, clearer, and editorial without changing learning or AI behavior.

**Architecture:** Keep the existing DOM-based home renderer and local data flow. Simplify its brand and featured-book markup in `src/main.ts`, then replace only the home-specific layout rules and tokens in `src/styles.css`; preserve the activity grid and typographic-cover generators.

**Tech Stack:** TypeScript, DOM APIs, CSS, Vite, Tauri 2.

---

### Task 1: Simplify the home information structure

**Files:**
- Modify: `src/main.ts:193-430`

1. Remove the `.home-logo` element and keep a wordmark plus a short descriptor.
2. Merge the rhythm summary into `.home-continue-copy` and remove the dedicated aside.
3. Give the activity metadata and section headings concise copy that works with sparse data.
4. Run `npx tsc --noEmit`; expect no diagnostics.

### Task 2: Rebuild the home visual hierarchy

**Files:**
- Modify: `src/styles.css:1-45`
- Modify: `src/styles.css:198-700`
- Modify: `src/styles.css:2730-2772`

1. Tighten the neutral color tokens and increase muted-text contrast.
2. Reduce masthead, featured stage, and activity-grid vertical space.
3. Convert the featured stage to a two-column editorial layout.
4. Pull the library/traces grid upward and refine list hover/focus states.
5. Update narrow- and low-window rules without hiding key actions.

### Task 3: Verify behavior and visuals

**Files:**
- Modify: `docs/status.md`

1. Run `npm run build`; expect TypeScript and Vite success.
2. Run `cargo test --manifest-path src-tauri/Cargo.toml`; expect all Rust tests to pass.
3. Run `npm run app` and inspect the home at default size and 720×520.
4. Confirm the home and settings views do not trigger Keychain authorization merely by opening.
5. Update `docs/status.md` with the final visual result and verification.
6. Run `git diff --check`, then commit the focused change.
