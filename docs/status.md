# Current status

## Project state

The first runnable macOS build is complete. It is a Swift Package app that builds with the same Command Line Tools workflow as `mimi` and `kiri`.

## Confirmed decisions

- Name: `satori`
- Platform: macOS only
- Product focus: PDF understanding rather than compulsory note-taking
- Initial plan: Advanced Programming, Software Engineering, and Operating Systems
- Storage: local-first; Alibaba Cloud Model Studio Qwen is used on demand for reasoning and search
- Toolchain: native Swift Package Manager app, following the user's `mimi` and `kiri` projects

## Completed in the first build

- Native Satori.app package with stable local signing when a local identity is available
- Three course workspaces and seeded learning directories
- Local JSON persistence in Application Support
- PDF import, text/scanned/mixed classification, and PDFKit reader
- Persisted page-based reading position
- Always-visible current/total page indicator with previous, next, and direct page jump controls
- Per-course PDF menu for switching, replacing, or removing an incorrect import without deleting the original file
- Keychain-only Model Studio API-key settings with verified migration from the transitional local file; the supported China (Beijing) shared endpoint is built in
- A visible AI assistant boundary that labels its current response source
- Current-page text and scanned-page images are connected to the Model Studio compatible Responses API with `store: false`
- The saved model preference defaults to `qwen3.8-max`, with `qwen3.7-plus` and `qwen3.7-flash` available as balanced and efficient choices
- Optional per-question web search with returned URL citations
- Enter-to-send learning composer with Shift+Enter line breaks, one-click quick prompts, and a cancellable streaming answer card
- Up to four removable local image attachments per question, resized and JPEG-compressed on device before the request and not persisted
- Per-document learning sessions persisted locally with page links, copy/retry/delete actions, stopped-answer retention, and confirmed history clearing
- Structured Markdown rendering for headings, paragraphs, ordered/unordered lists, quotes, inline formatting, links, and copyable code blocks
- Follow-up questions include at most the latest six local text turns while Model Studio response storage remains disabled
- Reading-bar chapter navigator: the current section/chapter is always visible; ⌘T (or the reading-bar button) opens a TOC drawer that lists chapters and subsections with outline-depth indentation, auto-scrolls to and highlights the current position, and jumps on click. Page ranges are hierarchy-aware (a chapter spans its own start to the next same-level entry, so 第一章 = the whole chapter while 第一节 = just that section); sources prefer the PDF's own outline, falling back to linked course-directory items, and the outline extraction is reused for directory page linking and the question-context chapter picker
- Themed PDF selection: the default system-blue highlight is overlaid with the lavender accent, and the floating 理解 / 接上文 / 举例 / 试试看 / 复制 bar is restyled as a compact rounded capsule (primary action filled, secondary actions borderless with lavender hover) to match the app theme in both light and dark mode
- AI answers render flat on the paper surface (no card bubble, no gold emphasis); page extraction is parallelized (4-way for chapter/multi-page, 3-way for whole-book), with stronger Qwen OCR reserved for the nearby reading pages and a 40-page local-OCR budget for the rest, while pasted/imported images are compressed on background tasks so large attachments don't block the UI
- OCR resilience: a text layer that looks long enough but contains common damage markers now triggers visual verification; page questions send the usable text together with the rendered page image, while clean text pages stay text-only and fast.
- Flow-protected reading mode is available from the reading bar or ⌘⇧F; it temporarily hides course chrome and the learning inspector without losing the current document or page position. Manual questions now default to an intelligent context scope: ordinary questions use the current page, while natural chapter/book/adjacent-page wording can expand it; chapter/range/whole-document/none remain available as explicit overrides.
- Selection-first understanding is now the primary reading loop: selecting text exposes 理解 / 接上文 / 举例 / 试试看 / 复制, the first four actions send an intent-aware question against the selected passage plus its current page, and the inspector keeps a visible source anchor with a one-click return to the original page. Code execution remains available from the secondary run space instead of competing with comprehension at the moment of selection.
- Real-PDF reading pass hardening: a previous-page selection no longer hides the current-page entry; old anchors collapse to a low-interference “上次卡在第 N 页” cue; active answers label their target page and the composer reports the request's actual scope; completed answers remain discoverable when the reader crosses a page boundary.
- Selection anchors now carry document identity, a capped normalized passage, and a page offset through the reader → assistant route. Returning from a historical answer or reopening a document can restore the actual PDF text selection, not only the page. Legacy turn archives normalize invalid page, attachment, and selection-offset values on decode.
- The secondary answer menu now calls the opt-in comprehension check “验证一下”: it asks for a small situation first, so reading can stay comprehension-first instead of turning every page into a quiz.
- Request feedback now separates “连接本机 Qwen 配置 / 读取 PDF / 等待首段回答 / 正在输出”, so a slow step is visible instead of looking like a frozen reader.
- Page, multi-page, and whole-document extraction now use a small in-memory cache keyed by the PDF file signature, context scope, and model; repeated follow-ups on the same page no longer reopen and re-read the document.
- Background Qwen configuration reads share one in-flight operation, avoid prompting from the reading loop, and fail fast after 8 seconds if macOS Keychain Services is unresponsive. Settings keeps the explicit interactive save/recovery path, and API keys remain Keychain-only.
- The page-entry “先讲主线” prompt now asks only about evidence from the current page; “接上文” is the explicit two-page bridge. Whole-book context puts the current page ±2 pages first, then PDF-outline/均匀采样的结构代表页, before filling the remaining input budget with the rest of the book, so late-book questions do not silently receive only the opening pages.
- Explicit external-information requests such as “找资料、查最新、给来源/链接、有没有过时” now auto-enable web search for that one turn and expose the search/source state; ordinary PDF understanding does not silently leave the local reading flow.
- Deterministic page-count questions now resolve from the PDF/章节导航 locally, so “这一章有多少页” does not spend a Qwen request or wait for a first token.
- Reading-first subtraction pass: the course sidebar no longer surfaces due-review counts or the streak/badge wall, and the composer no longer carries a permanent “运行代码” button. Review data and the secondary run space remain intact, but comprehension is now the primary visible action.
- Selection context alignment: “接上文” now sends the previous page together with the selected passage's current page; when a user is already drafting a question, the visible context picker switches to that page range instead of keeping the broader scope hidden.
- Natural-language scope inference: the default context is now “智能范围”—ordinary questions stay on the current page, while “这一章/第六章/这一节/整本书/上一页” requests expand to the smallest matching range. The explicit context picker still overrides inference, and the rules are covered by core tests.
- Conversational scope continuity: terse follow-ups such as “有多少页”“有什么值得看” inherit the most recent meaningful chapter/range scope, so a student can ask naturally after a chapter overview without being told the current page is the whole chapter.
- Real-PDF feedback refinement: book-level questions such as “这本书难吗？” now use whole-book context, colloquial freshness questions such as “过时了么” now trigger one-turn web verification, and a top-level chapter's first page offers “看本章路线” before detail questions.

The supplied PDFs were imported for local verification: `lang.pdf` and `software.pdf` classify as scanned; `system.pdf` classifies as text.

## Next milestone

Finish the unlocked end-to-end `system.pdf` reading pass: real answer, “验证一下” follow-up, return to the anchored passage, and a page transition. Measure first-token latency only after the Keychain connection is healthy; the current investigation found that the earlier apparent PDF delay was actually a blocked Keychain read. Validate the opt-in micro experiments on concepts that genuinely benefit from manipulation; keep them short and safe, and do not turn the reader into a general code execution surface. OCR-based editable table-of-contents extraction remains useful for scanned PDFs without outlines (`lang.pdf`, `software.pdf`), but it follows the comprehension loop rather than leading it.

## Open questions

- Which minimum macOS version should Satori support?
- Should web search be available from the first interactive build or follow the PDF reading loop?
- Which course should become the first end-to-end import fixture?
