# Reading loop repair: real chapter start and fixed-input experiments

## Evidence

The real `system.pdf` outline puts cover, foreword, contents, and the exam
outline ahead of `第一章 操作系统概论`; selecting the first top-level outline
item therefore cannot identify the first useful reading page. The real
`lang.pdf` session also follows a natural path from explaining a scanned C
example to asking for complete code and then wanting to run it. Blocking every
`scanf`/`input()` example breaks that loop even when the reader only needs one
known sample input.

## Design

`ReadingChapterSelector` identifies numbered chapters (`第 N 章` or
`Chapter N`) and uses them as the front-matter boundary. Books without numbered
chapters retain their first top-level reading-directory item as a fallback.

`CodeRunner` accepts an optional bounded fixed-input payload. It is passed via a
pipe, written once, and closed immediately. The existing language checks,
temporary directory, no-network/restricted sandbox, output cap, and timeout
remain in force. The answer code block and the secondary experiment space
expose the same small fixed-input field; they never open a persistent terminal.

## Verification

Core checks cover noisy front matter, the `system.pdf`-shaped chapter list,
interactive-code gating, and a real C multiplication run with `3 4` producing
`12`. The release app is built and signed after the core checks. Desktop click
verification remains a separate gate because the Mac is currently locked.
