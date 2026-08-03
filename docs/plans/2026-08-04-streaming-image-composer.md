# Streaming Image Composer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Satori's learning composer send with Enter, attach local images, stream Qwen answers, and expose clear in-progress and cancellation states.

**Architecture:** Extend `QwenLearningAssistant` with an SSE-backed `streamExplain` path while keeping the existing complete-response method. Add user-selected JPEG data after the current PDF context in the same Responses API request, then let SwiftUI consume incremental `LearningResponse` values in one answer card.

**Tech Stack:** Swift 6, SwiftUI, AppKit, UniformTypeIdentifiers, Foundation URLSession AsyncBytes, Alibaba Cloud Model Studio Responses API

---

### Task 1: Specify streaming and multi-image requests

**Files:**
- Modify: `tests/SatoriCoreTests/main.swift`
- Modify: `Sources/SatoriCore/LearningAssistant.swift`

**Step 1:** Add a fixture stream that emits two `response.output_text.delta` events and one `response.completed` event.

**Step 2:** Assert that the streaming request contains `stream: true`, one user image attachment in addition to page context, and the configured model/search flags.

**Step 3:** Run `swift run satori-core-tests` and confirm compilation or assertions fail before implementation.

### Task 2: Implement the SSE learning stream

**Files:**
- Modify: `Sources/SatoriCore/LearningAssistant.swift`
- Test: `tests/SatoriCoreTests/main.swift`

**Step 1:** Add `additionalImagesJPEG` to `QwenLearningAssistant` and encode each image as an `input_image` data URL.

**Step 2:** Add `stream` to the Responses request and an `AssistantTransport.stream` requirement that yields SSE JSON payloads.

**Step 3:** Implement URLSession byte streaming, delta aggregation, completion/citation parsing, cancellation, and readable errors.

**Step 4:** Run `swift run satori-core-tests` and confirm all request and response assertions pass.

### Task 3: Add local image attachments

**Files:**
- Create: `Sources/SatoriApp/LearningImageAttachment.swift`
- Modify: `Sources/SatoriApp/Views/LearningInspector.swift`

**Step 1:** Load security-scoped image URLs, resize locally to a 1600-pixel longest edge, encode JPEG, and cap each question at four images.

**Step 2:** Add a native multi-image file importer and horizontal removable thumbnail strip.

**Step 3:** Pass copied JPEG data to the assistant and clear pending attachments only after submission starts.

### Task 4: Rebuild composer interaction

**Files:**
- Modify: `Sources/SatoriApp/Views/LearningInspector.swift`

**Step 1:** Handle Enter as send and Shift+Enter as newline.

**Step 2:** Make quick prompts send immediately and retain the submitted question above the answer.

**Step 3:** Show an immediate progress state, append streamed text, turn Send into Stop while active, and cancel work when requested or the view disappears.

### Task 5: Document, verify, and publish

**Files:**
- Modify: `README.md`
- Modify: `docs/status.md`

**Step 1:** Document keyboard sending, temporary image attachments, streaming, and privacy behavior.

**Step 2:** Run core checks, debug and release builds, and package the app.

**Step 3:** Open Satori and visually verify the empty, attachment, streaming-ready, and cancellation controls without exposing a real API key.

**Step 4:** Review the diff, commit the focused change, fast-forward `main`, and push GitHub.
