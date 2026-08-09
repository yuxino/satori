# Reading loop repair: grounded regions, same-page chapters, and fixed-input experiments

## Evidence

The real `system.pdf` outline puts cover, foreword, contents, and the exam
outline ahead of `第一章 操作系统概论`; selecting the first top-level outline
item therefore cannot identify the first useful reading page. The real
`lang.pdf` session also follows a natural path from explaining a scanned C
example to asking for complete code and then wanting to run it. Blocking every
`scanf`/`input()` example breaks that loop even when the reader only needs one
known sample input.

Two more failures appeared in the next student pass:

- `lang.pdf` PDF page 54 contains two unrelated code objects. A scanned-page
  crop was previously sent as an anonymous temporary image, so a follow-up
  such as “完整代码” could drift between them.
- `system.pdf` PDF page 66 contains two outline sections at different vertical
  positions. The outline destination points both land at the page top, so a
  page-only TOC jump cannot move between them when the page is already open.

The next live `system.pdf` pass exposed a higher-risk comprehension failure.
The student correctly chose disk plus random access for direct student-record
lookup, but the feedback then claimed that every disk structure in figure 6-3
supports random access. The source table says linked structure supports only
sequential access. The same answer also silently collapsed the two-page
188–189 evidence window that generated the scenario to page 189 while grading
the student.

## Design

`ReadingChapterSelector` identifies numbered chapters (`第 N 章` or
`Chapter N`) and uses them as the front-matter boundary. Books without numbered
chapters retain their first top-level reading-directory item as a fallback.

`CodeRunner` accepts an optional bounded fixed-input payload. It is passed via a
pipe, written once, and closed immediately. The existing language checks,
temporary directory, no-network/restricted sandbox, output cap, and timeout
remain in force. The answer code block and the secondary experiment space
expose the same small fixed-input field; they never open a persistent terminal.

`ReadingRegionAnchor` stores a normalized top-left page rectangle with the
learning turn. Follow-ups reattach the same crop, the request labels it as the
single priority object, and reopening a session re-renders it from the PDF
instead of persisting a large image. `BookChapter` now carries a normalized
title offset. Native PDF outlines prefer text-layer geometry; scanned outlines
carry a bounded Vision-OCR line offset when available. TOC clicks post a
page-plus-offset jump even when the page number does not change.

Verification prompts now retain their exact `LearningContextScope` until the
reader explicitly enters answer mode. That scope is used for extraction,
shown in the composer, carried by the active streaming card, and persisted on
the completed turn. Stopped or stale verification requests cannot leave an
answer state behind. Verification-response instructions require the model to
evaluate only what the student actually said, use minimal supporting evidence,
and inspect supplied figure/table/formula images item by item rather than
generalizing across unseen cells.

## Verification

Core checks cover noisy front matter, the `system.pdf`-shaped chapter list,
interactive-code gating, and a real C multiplication run with `3 4` producing
`12`, plus region persistence and same-page chapter ordering. Real local checks
still keep `lang.pdf`'s code bridge pages `[54, 55, 53]` and scanned search
wraparound. The release app is built after the core checks. With the Mac
unlocked, desktop verification also covered the repaired `software.pdf` TOC
boundary, the Qwen connection smoke test, a chapter route, a constrained
concept follow-up, a selected-passage micro experiment, and a two-page
“接上文” bridge. The next student-pass check covered the explicit
“验证一下” follow-up and return-to-anchor behavior. The final desktop pass
kept both the prompt and student answer on PDF pages 188–189, produced a short
grounded permission-classification judgment without unrelated claims, cleared
a stopped verification without leaving a false quiz banner, and restored the
exact highlighted sentence on PDF page 188 through “返回”.
