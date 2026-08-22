# Product UI Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Rebuild Satori's home, reader chrome, and AI conversation into one coherent, quiet study-room experience.

**Architecture:** Keep the existing Tauri and DOM-based TypeScript architecture. Restructure the generated markup in `src/main.ts`, then implement one shared editorial design system in `src/styles.css` without changing persistence, PDF rendering, or provider security boundaries.

**Tech Stack:** Tauri 2, TypeScript, DOM APIs, CSS, PDF.js

---

### Task 1: Rebuild the home information architecture

**Files:**
- Modify: `src/main.ts`
- Modify: `src/styles.css`

**Steps:**

1. Replace the dashboard header and activity-first layout with a masthead and a recent-book hero.
2. Add a compact natural-language study summary and four-week rhythm strip.
3. Replace book cards with accessible shelf rows.
4. Render recent Q&A as “最近弄懂的” entries with answer excerpts.
5. Verify TypeScript builds and empty/populated states remain functional.

### Task 2: Unify the reader chrome

**Files:**
- Modify: `src/main.ts`
- Modify: `src/styles.css`

**Steps:**

1. Group bottom controls into semantic rail sections.
2. Change clickable page and zoom labels to buttons while preserving existing behavior.
3. Restyle the thumbnail strip, book menu, TOC drawer, and ask bookmark to use the shared system.
4. Verify page navigation, page jump, zoom, spread mode, book switching, and home return.

### Task 3: Redesign the learning conversation

**Files:**
- Modify: `src/main.ts`
- Modify: `src/styles.css`

**Steps:**

1. Add a named header and current-page context without triggering any request.
2. Turn the initial prompt into one concise invitation plus three explicit, optional starting questions.
3. Restyle questions, answers, history, follow-ups, loading, errors, and the sticky composer.
4. Preserve the rule that opening the panel is side-effect free.

### Task 4: Verify the full experience

**Files:**
- Modify: `docs/status.md`

**Steps:**

1. Run `npm run build` and `git diff --check`.
2. Launch through `npm run app` so the signed development shell is reused.
3. Visually inspect the populated home, reader, initial ask state, and a saved answer without sending user material externally.
4. Check keyboard focus and the minimum supported window size.
5. Record the delivered behavior and remaining risks in `docs/status.md`.

