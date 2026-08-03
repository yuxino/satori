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

- Native Satori.app package and ad-hoc local signing script
- Three course workspaces and seeded learning directories
- Local JSON persistence in Application Support
- PDF import, text/scanned/mixed classification, and PDFKit reader
- Persisted page-based reading position
- Always-visible current/total page indicator with previous, next, and direct page jump controls
- Per-course PDF menu for switching, replacing, or removing an incorrect import without deleting the original file
- User-only local Model Studio API-key settings with the supported China (Beijing) shared endpoint built in; no repository key path or Host field
- A visible AI assistant boundary that labels its current response source
- Current-page text and scanned-page images are connected to the Model Studio compatible Responses API with `store: false`
- The saved model preference defaults to `qwen3.8-max`, with `qwen3.7-plus` and `qwen3.7-flash` available as balanced and efficient choices
- Optional per-question web search with returned URL citations
- Enter-to-send learning composer with Shift+Enter line breaks, one-click quick prompts, and a cancellable streaming answer card
- Up to four removable local image attachments per question, resized and JPEG-compressed on device before the request and not persisted
- Per-document learning sessions persisted locally with page links, copy/retry/delete actions, stopped-answer retention, and confirmed history clearing
- Structured Markdown rendering for headings, paragraphs, ordered/unordered lists, quotes, inline formatting, links, and copyable code blocks
- Follow-up questions include at most the latest six local text turns while Model Studio response storage remains disabled

The supplied PDFs were imported for local verification: `lang.pdf` and `software.pdf` classify as scanned; `system.pdf` classifies as text.

## Next milestone

Add OCR-based editable table-of-contents extraction and source/URL/code attachments, then connect learning-directory items to pages and conversations.

## Open questions

- Which minimum macOS version should Satori support?
- Should web search be available from the first interactive build or follow the PDF reading loop?
- Which course should become the first end-to-end import fixture?
