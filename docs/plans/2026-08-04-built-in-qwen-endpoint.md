# Built-in Qwen Endpoint Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove API Host configuration from Satori and use Alibaba Cloud Model Studio's supported shared China (Beijing) OpenAI-compatible endpoint internally.

**Architecture:** Keep the endpoint in `QwenLearningAssistant` as the default transport destination so app configuration contains only the secret API key and the selected model. Preserve endpoint injection in the assistant initializer for deterministic tests and future provider work, while deleting the obsolete saved-host preference during configuration changes.

**Tech Stack:** Swift 6, SwiftUI, Foundation URLSession, Security/Keychain, Swift Package Manager

---

### Task 1: Make the Beijing endpoint the core default

**Files:**
- Modify: `Sources/SatoriCore/LearningAssistant.swift`
- Modify: `tests/SatoriCoreTests/main.swift`

**Step 1:** Add the official shared Beijing base URL as `QwenLearningAssistant.defaultAPIHost` and make `apiHost` an optional initializer argument with that default.

**Step 2:** Update the fixture transport to verify that the default request reaches the shared Beijing Responses endpoint while retaining one explicit endpoint-injection check.

**Step 3:** Run `swift run satori-core-tests` and confirm the request contract still passes.

### Task 2: Remove API Host from app configuration

**Files:**
- Modify: `Sources/SatoriApp/QwenConfigurationStore.swift`
- Modify: `Sources/SatoriApp/Views/LearningInspector.swift`

**Step 1:** Remove `apiHost` from `QwenConfiguration`, stop reading and validating a saved host, and change `save` to accept only API key and model ID.

**Step 2:** Remove the obsolete `qwen-api-host` preference on save and removal so older local installations migrate cleanly.

**Step 3:** Construct `QwenLearningAssistant` without passing a host so it uses the built-in endpoint.

### Task 3: Simplify settings and project memory

**Files:**
- Modify: `Sources/SatoriApp/Views/QwenSettingsView.swift`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/status.md`
- Modify: `docs/decisions/0002-qwen-model-studio.md`

**Step 1:** Delete the Host input and explain that Satori has the Beijing endpoint built in.

**Step 2:** Update the README, current status, architectural decision, and working rules so future sessions do not reintroduce user-managed Host configuration.

### Task 4: Verify and publish

**Files:**
- Verify: all modified files

**Step 1:** Run core checks and debug/release builds.

**Step 2:** Package and open the app, then visually verify that settings show only API Key and model selection.

**Step 3:** Review the diff, commit the focused change, and push the branch.
