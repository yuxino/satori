# Scanned evidence recovery repair

## Real-reading evidence

- In `lang.pdf` page 54, the reader can frame one of several code examples and the first answer uses the intended crop. The saved anchor, however, was calculated from `PDFView` coordinates and later restored as if it were a `PDFPage` rectangle. Zooming, scrolling, resizing, or reopening could therefore move the crop to unrelated code or blank space.
- In `software.pdf`, chapter OCR continues after the reading panel is already interactive. A natural first question such as “这一章讲什么” can arrive while `chapters` is empty and silently fall back to the current page. “这一章有多少页” could even be answered as one page.
- On the visible chapter-opening page of `software.pdf`, searching “数据流图” reported that the whole book did not contain it even though the phrase appears twice on the page. A real-page probe showed that Vision's 1400px fast mode returned mostly garbled characters, while accurate mode found the phrase in about half a second at 1000px.

Both failures are dangerous because the UI still looks fluent while the model is grounded in the wrong evidence.

## Considered designs

1. **Central page-space anchor conversion plus deferred chapter questions (chosen).** Normalize only after the drag rectangle has been converted into PDF-page coordinates. Reuse the inverse conversion for every restored crop. Hold chapter-dependent composer questions while outline recovery is running, then send once when the range is known.
2. Patch only the two arithmetic expressions in `PDFReaderView`. This is smaller but leaves duplicate coordinate math and makes another capture/restore mismatch likely.
3. Persist every cropped JPEG. This would make restoration visually stable but increases archive size, retains user page images unnecessarily, and still leaves chapter scope races unresolved.

## Behaviour after the repair

- The initial crop and every restored crop are generated from the same normalized page anchor.
- Page bounds with non-zero origins and partially outside selections round-trip safely.
- Chapter wording in intelligent mode, or an explicit chapter scope, waits while scanned outline recovery is active.
- If no chapter boundary can be resolved, Satori asks the reader to select a multi-page range instead of pretending the request was about one page.
- Deterministic page-count answers refuse to call an unresolved chapter “one page.”
- Scanned-text search uses a compact accurate OCR pass and can keep a typical whole textbook's page text in its bounded memory cache. It no longer trades away Chinese recall for a fast but misleading negative.

## Verification

- Core round-trip checks cover offset PDF page bounds, clipping, persistence, chapter-intent detection, and the no-single-page fallback.
- Release build and packaged-app signing must pass.
- Reopen the real page-54 crop in `lang.pdf` and compare the attachment preview before and after restart.
- Search “数据流图” from the real `software.pdf` chapter opener and verify that the current page is found instead of reporting a whole-book miss.
