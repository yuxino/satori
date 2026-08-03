# Satori Bootstrap Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create the first runnable macOS shell for a local-first PDF understanding workspace.

**Architecture:** A native SwiftUI app owns local learning-plan data through SwiftData. PDFKit renders PDFs and supplies page coordinates for restoring reading position. AI and OCR are isolated behind protocols so the app shell remains usable before API configuration.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, PDFKit, XCTest, macOS Keychain.

---

### Task 1: Create the macOS app target

**Files:**
- Create: `Satori.xcodeproj`
- Create: `Satori/SatoriApp.swift`
- Create: `Satori/ContentView.swift`
- Create: `SatoriTests/SatoriTests.swift`

**Step 1:** Create a macOS SwiftUI app named Satori with a SwiftData model container.

**Step 2:** Build the app with `xcodebuild` and verify that it exits successfully.

**Step 3:** Launch the app and visually verify that the empty learning-plan screen appears.

**Step 4:** Commit the runnable shell with message `feat: add satori macOS app shell`.

### Task 2: Add learning-plan persistence

**Files:**
- Create: `Satori/Models/LearningPlan.swift`
- Create: `Satori/Models/CourseWorkspace.swift`
- Create: `SatoriTests/LearningPlanTests.swift`
- Modify: `Satori/SatoriApp.swift`

**Step 1:** Write a failing test that saves and reloads a plan with three course workspaces.

**Step 2:** Run the test and verify failure because models do not exist.

**Step 3:** Implement the minimal SwiftData models and include them in the model container.

**Step 4:** Run the test and verify it passes.

**Step 5:** Commit with message `feat: persist learning plans and courses`.

### Task 3: Build the three-course library view

**Files:**
- Create: `Satori/Views/PlanSidebar.swift`
- Create: `Satori/Views/CourseOverview.swift`
- Modify: `Satori/ContentView.swift`
- Test: `SatoriTests/SatoriTests.swift`

**Step 1:** Add a seed-only preview with Advanced Programming, Software Engineering, and Operating Systems.

**Step 2:** Implement a navigation split view that selects a course and displays its empty source area.

**Step 3:** Launch the app and visually check sidebar selection and empty-state copy.

**Step 4:** Commit with message `feat: add course workspace navigation`.

### Task 4: Add local PDF references and reading state

**Files:**
- Create: `Satori/Models/StudyDocument.swift`
- Create: `Satori/Models/ReadingPosition.swift`
- Create: `Satori/Services/DocumentBookmarkStore.swift`
- Create: `SatoriTests/ReadingPositionTests.swift`

**Step 1:** Write a failing test for persisting a document identifier, current page index, normalized page offset, and last-opened timestamp.

**Step 2:** Implement the models and the security-scoped bookmark boundary.

**Step 3:** Run the persistence tests and verify they pass.

**Step 4:** Commit with message `feat: store local documents and reading progress`.

### Task 5: Add a PDFKit reading screen

**Files:**
- Create: `Satori/Views/PDFReaderView.swift`
- Modify: `Satori/Views/CourseOverview.swift`
- Modify: `Satori/Models/ReadingPosition.swift`
- Test: `SatoriTests/ReadingPositionTests.swift`

**Step 1:** Add a failing test for converting page navigation into stored reading state.

**Step 2:** Wrap PDFKit in SwiftUI, restore the saved page and offset, and save progress after navigation.

**Step 3:** Manually import `lang.pdf`, close the app on a later page, reopen it, and verify position restoration.

**Step 4:** Commit with message `feat: restore PDF reading position`.

### Task 6: Establish AI service boundaries

**Files:**
- Create: `Satori/Services/LearningAssistant.swift`
- Create: `Satori/Services/OpenAIKeyStore.swift`
- Create: `SatoriTests/LearningAssistantTests.swift`
- Modify: `docs/status.md`

**Step 1:** Write tests for a mock learning assistant that labels source types in its responses.

**Step 2:** Implement protocols and a Keychain-backed key store, without shipping a network call yet.

**Step 3:** Run the tests and verify that the app has no plaintext API-key path.

**Step 4:** Commit with message `feat: add local AI service boundary`.
