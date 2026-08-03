# Local Learning Sessions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Turn the PDF assistant into a persistent, multi-turn learning record with readable Markdown, local context memory, and useful per-answer actions.

**Architecture:** Store completed turns in a separate local JSON archive keyed by `StudyDocument.id`. Parse model Markdown into typed blocks in SatoriCore, render those blocks with native SwiftUI, and send at most the latest six local question/answer pairs as Responses API context while retaining `store: false`.

**Tech Stack:** Swift 6, SwiftUI, Foundation Codable/AttributedString, AppKit pasteboard, URLSession, Swift Package Manager

---

### Task 1: Define and test learning records

**Files:**
- Create: `Sources/SatoriCore/LearningSession.swift`
- Create: `Sources/SatoriCore/LearningSessionStore.swift`
- Modify: `tests/SatoriCoreTests/main.swift`

**Step 1:** Add failing tests for saving turns under two document IDs, reloading them, replacing one document's turns, and clearing only that document.

**Step 2:** Add Codable models for a learning turn, completion state, citations, and an archive of document sessions.

**Step 3:** Implement atomic JSON persistence under Application Support and rerun the core checks.

### Task 2: Parse learning Markdown

**Files:**
- Create: `Sources/SatoriCore/LearningMarkdownParser.swift`
- Modify: `tests/SatoriCoreTests/main.swift`

**Step 1:** Add a fixture containing bold section labels, paragraphs, bullets, a quote, numbered steps, inline code, and a fenced code block.

**Step 2:** Assert typed block order and that structural marker characters are not part of heading/list content.

**Step 3:** Implement the line-oriented parser and rerun tests.

### Task 3: Add bounded local conversation context

**Files:**
- Modify: `Sources/SatoriCore/LearningAssistant.swift`
- Modify: `tests/SatoriCoreTests/main.swift`

**Step 1:** Add a fixture expecting one prior user/assistant pair before the current page message.

**Step 2:** Add `LearningConversationContext` to the assistant and encode the latest six turns with bounded text lengths.

**Step 3:** Verify streaming, images, search, and non-streaming behavior still pass.

### Task 4: Render real learning documents

**Files:**
- Create: `Sources/SatoriApp/Views/LearningMarkdownView.swift`
- Modify: `Sources/SatoriApp/Views/LearningInspector.swift`
- Modify: `Sources/SatoriApp/Views/CourseOverview.swift`

**Step 1:** Render headings, paragraphs, lists, quotes, dividers, and scrollable code blocks with inline Markdown styling.

**Step 2:** Replace the single response state with a chronological list of persisted turns plus one streaming draft.

**Step 3:** Add copy, retry, delete, page navigation, and confirmed clear-history actions.

**Step 4:** Load the current document's history on appearance, persist completed/stopped turns, and send the latest local context for follow-up questions.

### Task 5: Record architecture and verify product flow

**Files:**
- Create: `docs/decisions/0003-local-learning-sessions.md`
- Modify: `README.md`
- Modify: `docs/status.md`
- Modify: `AGENTS.md`

**Step 1:** Record why sessions are local, separate from plan data, bounded for cloud requests, and independent of provider storage.

**Step 2:** Run core tests, debug/release builds, package and sign the app.

**Step 3:** Open the app and inspect the complete learning flow at normal and narrow panel widths without sending user data.

**Step 4:** Review for plaintext keys or PDF artifacts, commit, fast-forward `main`, and push GitHub.
