# Configurable Qwen Model Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Use `qwen3.8-max` by default and persist a user-selectable Qwen quality tier with the existing Model Studio connection.

**Architecture:** Pass the model ID into `QwenLearningAssistant` instead of hard-coding it. Store the non-secret model ID in `UserDefaults`, defaulting old installations to `qwen3.8-max`, while keeping the API key in Keychain.

**Tech Stack:** Swift 6, SwiftUI, Foundation UserDefaults, macOS Keychain, Alibaba Cloud Model Studio Responses API

---

### Task 1: Make the request model configurable

**Files:**
- Modify: `Sources/SatoriCore/LearningAssistant.swift`
- Modify: `tests/SatoriCoreTests/main.swift`

**Step 1:** Update the fixture to expect `qwen3.8-max` and a second custom model ID.

**Step 2:** Run `swift run satori-core-tests` and confirm the hard-coded model assertion fails.

**Step 3:** Add a model ID parameter and use it when encoding the Responses request.

**Step 4:** Run `swift run satori-core-tests` and confirm `Satori core checks passed`.

### Task 2: Persist model selection

**Files:**
- Modify: `Sources/SatoriApp/QwenConfigurationStore.swift`
- Modify: `Sources/SatoriApp/Views/QwenSettingsView.swift`
- Modify: `Sources/SatoriApp/Views/LearningInspector.swift`

**Step 1:** Add the model ID to `QwenConfiguration` and save it in `UserDefaults`.

**Step 2:** Default missing settings to `qwen3.8-max` so existing users migrate automatically.

**Step 3:** Add a quality picker for Max, Plus, and Flash to the settings form.

**Step 4:** Pass the saved model ID to the learning assistant and run `swift build`.

### Task 3: Document and verify

**Files:**
- Modify: `README.md`
- Modify: `docs/status.md`
- Modify: `docs/decisions/0002-qwen-model-studio.md`

**Step 1:** Document the new default and the configurable quality tiers.

**Step 2:** Run core checks, release build, and package the app.

**Step 3:** Open Settings and visually verify the model picker and connection fields.

**Step 4:** Commit the focused change and push main.
