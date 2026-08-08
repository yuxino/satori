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
- OCR verification correction: when Qwen OCR repairs a suspicious text layer, the repaired text now travels with the rendered page image too; the model can cross-check terminology instead of trusting the repair alone.
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
- Real-time fact boundary: explicit phrases such as “今日金价 / 实时汇率 / 天气预报 / 最新新闻” now take the same one-turn web path, while ordinary textbook questions about a price formula remain PDF-local.
- Deterministic page-count questions now resolve from the PDF/章节导航 locally, so “这一章有多少页” does not spend a Qwen request or wait for a first token.
- Reading-first subtraction pass: the reading sidebar no longer surfaces due-review counts, the streak/badge wall, or page-completion percentages; it shows the books in each reading space instead. The composer no longer carries a permanent “运行代码” button. Review data and the secondary run space remain intact, but comprehension is now the primary visible action.
- Product-language subtraction: the visible shell now says “阅读空间 / 书 / 打开就开始理解” instead of presenting a course plan or task setup; the existing course-shaped archive remains compatible underneath.
- Product-language refinement: the secondary history space now says “回看” instead of “笔记”; saved Q&A remains available by page without asking the reader to organize notes.
- Selection context alignment: “接上文” now sends the previous page together with the selected passage's current page; when a user is already drafting a question, the visible context picker switches to that page range instead of keeping the broader scope hidden.
- Natural-language scope inference: the default context is now “智能范围”—ordinary questions stay on the current page, while “这一章/第六章/这一节/整本书/上一页” requests expand to the smallest matching range. The explicit context picker still overrides inference, and the rules are covered by core tests.
- Chapter-scope orientation: the explicit “章节” context now follows the current top-level chapter by default; a selected section remains intentional until the reader leaves its parent chapter, so moving through a chapter cannot silently shrink a chapter question to whichever subsection happens to be on screen.
- Natural-language bridge refinement: expressions such as “接着前面的内容”“这一页和前面有什么关系”“怎么衔接” now include the adjacent previous page automatically, matching how a student actually asks while moving through a chapter.
- Forward-reading bridge: “下一页讲什么 / 然后呢 / 往下讲” now includes the current page and the next page automatically, and clamps cleanly at the end of a book.
- Conversational scope continuity: terse follow-ups such as “有多少页”“有什么值得看” inherit the most recent meaningful chapter/range scope, so a student can ask naturally after a chapter overview without being told the current page is the whole chapter.
- Scope freshness guard: those terse follow-ups inherit the previous range only while the current page remains inside it; after jumping to another chapter, “有多少页” follows the new reading position instead of stale history.
- Freshness scope continuity: book/chapter questions such as “有没有过时的内容”“现在还适用吗” now keep the right book-level or recent chapter range while the one-turn web check supplies current evidence.
- Confusing-textbook response: when a reader says the material is complex, verbose, or poorly connected, the default assistant prompt now asks for a candid reframe into主线、因果/步骤和可暂时跳过的细节 instead of repeating the textbook order.
- Rapid-reading map: book/chapter overview questions now ask the assistant to identify the core problem, concept progression, read-first/skip-first details, and hands-on experiments instead of producing a page-by-page or table-of-contents summary.
- Compact follow-ups: “简化 / 字太多 / 一句话 / 三句话 / 更简单” now lower the model's output budget, so a reader's request for less does not still return the full explanation template.
- One-glance compression: the existing answer overflow menu now offers “压缩成短版”, reusing the same page/selection and prior answer to produce at most three short points without adding another visible toolbar control.
- Selection-first answers: selected passages now default to a one-sentence summary plus at most three key points; explicit “完整代码 / 逐行 / 深入推导” requests retain the larger response budget for deliberate deep dives.
- Scanned visual continuity: short page bridges may use Qwen OCR for accuracy but still carry up to two original page images when a PDF has no reliable text layer or OCR misses; chapter routes likewise keep at most two representative images, preserving diagrams/code without making native-text maps heavier.
- Scanned region understanding: scanned/mixed PDFs now expose a temporary “框选理解” action; dragging over a diagram, formula, or code block crops that region into the next question while keeping the original PDF page as surrounding evidence. The crop is memory-only and text PDFs keep their native selection path.
- Quick-start alignment: the empty reading panel now asks “它在解决什么问题？” instead of “作者为什么要这样讲？”, keeping the first-click path grounded in the page rather than unsupported author-intent guesses.
- Textbook correctness checks: “有没有错 / 对不对 / 靠谱吗” now separate page evidence, OCR/layout suspicion, and genuinely unanswerable claims before calling textbook content wrong.
- Real system.pdf boundary fixture: the sixth chapter is verified as PDF pages 183–228 (46 pages); chapter-scope tests now use that actual outline instead of the earlier truncated 183–225 range.
- Selection prompt de-duplication: when a reader already has a draft question, selection actions now add only the intent; the bounded selected passage is sent once as structured context instead of being duplicated in the editable prompt.
- Historical retry re-anchoring: retrying an old answer now rejects a saved page range that no longer contains its target page, re-infers the current chapter when possible, and otherwise uses the target page instead of resurrecting stale context.
- Reading speed-bump replies: terse interruptions such as “这啥意思 / 这是什么” now use a compact request instruction and a smaller output budget, while explicit “详细展开” requests keep the full answer path.
- Controlled experiments: the secondary experiment space and answer-code runner now offer only Python/C/C++ pure-computation snippets, reject file/network/process APIs, and use macOS's no-network profile when launching an allowed experiment; blocked code stays copyable instead of running.
- Interactive-code guard: textbook examples that call `scanf`, `cin`, `input()` and similar stdin APIs are now blocked with an explicit “需要交互输入” explanation instead of launching a process that waits until timeout inside the reading flow.
- Natural run intent: after selecting recognizable C/C++/Python code, a short “运行/执行/跑一下” request now opens the safe experiment space with the code prefilled and source-page label; it never auto-runs and still requires an explicit Run click.
- Real-PDF feedback refinement: book-level questions such as “这本书难吗？” now use whole-book context, colloquial freshness questions such as “过时了么” now trigger one-turn web verification, and a numbered chapter's first page offers “看本章路线” before detail questions without treating front matter as a chapter.
- Reading-map labels: when an answer used an exact top-level chapter range, its history chip now names the chapter as well as the page range (for example “第六章 · 第 183–228 页”), while temporary two-page bridges remain plain page ranges.
- Verification friction pass: “验证一下” now shows an explicit, skippable state; moving to another page cancels the old verification, and selection/quick actions start a normal reading question instead of being misread as the user's answer. Closing the understanding panel also stops any running micro-experiment.
- Verification intent guard: the verification banner now requires an explicit “回答” tap before a composer message is judged as the reader's answer; a normal follow-up question can continue directly without being silently graded.
- Flow subtraction: the “先讲主线/看本章路线” entry now appears only when opening a book or entering a new chapter; ordinary page turns stay visually quiet while selection and manual questions remain available.
- Figure-aware PDF evidence: when a current page or a short page bridge depends on a numbered figure/table, Satori now sends up to two corresponding page images alongside the text layer; a figure referenced at the previous page's tail can be picked up from the next page, while long chapter maps remain text-only for speed.
- Colloquial page bridges: “刚才/上面/前文/上一段” now resolve to the previous-page bridge, so natural questions like “这一页和刚才讲的有什么关系” keep the adjacent reading context.
- Selection flow fix: the custom selection highlight is now display-only and passes mouse input back to PDFKit, so a reader can immediately replace a previous selection by dragging again.
- Reading orientation: the PDF toolbar now shows the current top-level chapter together with its section, keeping a reader oriented inside a long book while moving page by page.
- Fast chapter maps: “看本章路线” now samples chapter boundaries, representative pages, and recursive section anchors within a bounded budget instead of sending every paragraph from a long chapter, keeping the first reading map aligned with flow.
- Historical selection recovery: returning to an old Q&A now restores the selected passage's vertical anchor and chooses the nearest same-page text match, instead of always selecting the first repeated phrase.
- History jump continuity: clicking a historical Q&A's page anchor now restores its PDF selection as well as changing pages; old records still fall back safely without treating legacy viewport offsets as exact.
- Scanned-PDF navigation: when a scanned book has no native PDF outline, Satori now OCRs a bounded front-matter window, reads two-column tables of contents in column order, corrects the printed-page/PDF-page offset from the first real chapter heading, caches the result by file signature, and uses the recovered chapter map for navigation without sending the whole book to Qwen.
- Chapter-language alignment: “第六章” and “第6章” now resolve to the same recovered chapter, so Chinese-numbered questions keep their chapter-wide context on scanned books too.
- Scanned-page reading: local Vision OCR now detects actual two-column layouts instead of blindly splitting every page, keeps single-column body text in order, repairs long-but-damaged text layers, and keeps the scanned page image beside OCR text so Qwen can verify the result.
- OCR/code safety: when scanned OCR reaches code, formulas, numbers, or symbols, the request now explicitly treats the page image as the original evidence and tells Qwen to resolve OCR conflicts from the image.
- OCR reconstruction guard: selected-passage requests now forbid “大致如下” code/formula completions unless every token is visible in the supplied page image; incomplete OCR is reported as uncertainty with a concrete missing-page cue instead of being silently repaired from general knowledge.
- Figure look-ahead: when a current page names a numbered figure/table, a single-page question can also carry the immediately following page image because textbook figures often begin across the page break; the request labels the adjacent page as visual evidence without widening the text scope.
- Scanned-book orientation: OCR table-of-contents entries now retain first-level sections and their printed-page mapping, so scanned books can show the same chapter + section breadcrumb as native-outline PDFs.
- Printed-page clarity: scanned books now show PDF page and textbook page together in the reading bar and TOC, so a printed citation such as “书内第 25 页” no longer gets confused with PDF 第 30 页.

The supplied PDFs were imported for local verification: `lang.pdf` and `software.pdf` classify as scanned; `system.pdf` classifies as text.

## Next milestone

Finish the unlocked end-to-end `system.pdf` reading pass: real answer, “验证一下” follow-up, return to the anchored passage, and a page transition. Measure first-token latency only after the Keychain connection is healthy; the current investigation found that the earlier apparent PDF delay was actually a blocked Keychain read. Validate the opt-in micro experiments on concepts that genuinely benefit from manipulation; keep them short and safe, and do not turn the reader into a general code execution surface. OCR-based editable table-of-contents extraction remains useful for scanned PDFs without outlines (`lang.pdf`, `software.pdf`), but it follows the comprehension loop rather than leading it.

## Open questions

- Which minimum macOS version should Satori support?
- Should web search be available from the first interactive build or follow the PDF reading loop?
- Which course should become the first end-to-end import fixture?
