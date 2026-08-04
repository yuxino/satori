# Qwen Keychain Persistence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Persist the Qwen API key in macOS Keychain across Satori restarts and rebuilds while safely migrating the existing protected local file.

**Architecture:** Give packaged builds a stable local signing identity and store the key in a new legacy macOS keychain item restricted to the calling Satori app. Treat the current Application Support key file as a one-time migration source and delete it only after a verified keychain round trip.

**Tech Stack:** Swift 6, Security.framework, SwiftUI, macOS code signing, Swift Package Manager

---

### Task 1: Stable local signing

**Files:**
- Modify: `scripts/package-app.sh`

**Step 1:** Resolve `SATORI_CODESIGN_IDENTITY` or the installed `mimi Local Development` identity, falling back to ad-hoc signing only when neither exists.

**Step 2:** Package the app and inspect `codesign -dvv` plus the designated requirement.

**Step 3:** Repackage and confirm the signing identity and requirement remain stable.

### Task 2: Satori-only keychain item

**Files:**
- Modify: `Sources/SatoriApp/QwenConfigurationStore.swift`
- Modify: `Sources/SatoriApp/Views/QwenSettingsView.swift`
- Modify: `Sources/SatoriApp/Views/LearningInspector.swift`

**Step 1:** Replace normal file reads and writes with `SecItemCopyMatching`, `SecItemUpdate`, and `SecItemAdd` for a new versioned service name.

**Step 2:** Use `SecAccessCreate` with a nil trusted list so only the calling Satori app is trusted for the item.

**Step 3:** Keep reads, saves, and deletes on the existing detached background tasks and return clear localized errors.

### Task 3: Verified migration

**Files:**
- Modify: `Sources/SatoriApp/QwenConfigurationStore.swift`

**Step 1:** If the new keychain item is absent, read the transitional Application Support key file without logging it.

**Step 2:** Write the value to Keychain and immediately read it back.

**Step 3:** Delete the transitional file only when the round trip matches exactly; leave it untouched on any failure.

### Task 4: Documentation and end-to-end verification

**Files:**
- Modify: `AGENTS.md`
- Modify: `README.md`
- Modify: `docs/status.md`
- Create: `docs/decisions/0005-stable-keychain-storage.md`

**Step 1:** Restore the Keychain-only storage rule and record that ADR 0005 supersedes ADR 0004.

**Step 2:** Run `swift run satori-core-tests`, `swift build`, and `scripts/package-app.sh`.

**Step 3:** Launch Satori and confirm migration using file existence, masked UI state, and connected-state checks without outputting the key.

**Step 4:** Repackage and restart Satori, repeat the connected-state check, scan the diff for credentials, commit, and push `main`.
