# Qwen Provider Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Satori's OpenAI-only assistant with Alibaba Cloud Model Studio Qwen while preserving scanned-page understanding and opt-in web search.

**Architecture:** Keep the existing Responses-shaped boundary, rename it to a provider-neutral transport, and target the user-supplied Model Studio API Host with `qwen3.7-plus`. Store the API key in Keychain and the non-secret host in local preferences.

**Tech Stack:** Swift 6, SwiftUI, Foundation URLSession, macOS Security/Keychain, Alibaba Cloud Model Studio OpenAI-compatible Responses API

---

### Task 1: Lock the Qwen request contract with fixtures

**Files:**
- Modify: `tests/SatoriCoreTests/main.swift`
- Modify: `Sources/SatoriCore/LearningAssistant.swift`

**Step 1:** Change the fixture to create `QwenLearningAssistant` with an API Host.

**Step 2:** Assert the request URL ends in `/compatible-mode/v1/responses`, uses Bearer authentication, selects `qwen3.7-plus`, sends `store: false`, and adds `web_search` only when requested.

**Step 3:** Run `swift run satori-core-tests` and confirm the renamed implementation is initially missing.

**Step 4:** Implement the minimal Qwen request/response types and provider-neutral transport.

**Step 5:** Run `swift run satori-core-tests` and confirm `Satori core checks passed`.

### Task 2: Add secure Qwen configuration

**Files:**
- Rename: `Sources/SatoriApp/OpenAIKeyStore.swift` to `Sources/SatoriApp/QwenConfigurationStore.swift`
- Rename: `Sources/SatoriApp/Views/OpenAISettingsView.swift` to `Sources/SatoriApp/Views/QwenSettingsView.swift`
- Modify: `Sources/SatoriApp/SatoriApp.swift`

**Step 1:** Store the Qwen API key under a new Keychain account and the API Host in `UserDefaults`.

**Step 2:** Validate that the host is an HTTPS URL before saving.

**Step 3:** Replace the settings form with fields for the API Key and the API Host shown by Model Studio.

**Step 4:** Update the Settings scene and build with `swift build`.

### Task 3: Route the learning panel through Qwen

**Files:**
- Modify: `Sources/SatoriApp/Views/LearningInspector.swift`

**Step 1:** Replace OpenAI configuration checks and labels with Qwen/Model Studio wording.

**Step 2:** Construct `QwenLearningAssistant` using the saved key and host.

**Step 3:** Keep the existing text and scanned-page extraction paths and opt-in web toggle.

**Step 4:** Run `swift run satori-core-tests` and `swift build -c release`.

### Task 4: Update durable project memory and verify the app

**Files:**
- Modify: `AGENTS.md`
- Modify: `README.md`
- Modify: `docs/status.md`
- Modify: `docs/decisions/0001-local-first-macos.md`

**Step 1:** Replace OpenAI-specific product and privacy guidance with Model Studio/Qwen guidance.

**Step 2:** Document API Key plus API Host setup and scanned-page/web-search support.

**Step 3:** Run `swift run satori-core-tests`, `swift build`, and `scripts/package-app.sh`.

**Step 4:** Launch the packaged app and visually verify settings and the learning panel.

**Step 5:** Commit the focused provider migration and push the branch.
