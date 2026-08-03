# Product brief

## Goal

Build a Mac learning workspace that helps the user understand difficult material while reading PDFs. It should retain progress and useful learning context without making manual note-taking the main workflow.

## Initial learning plan

**Computer Self-Study** contains three independent but related course workspaces:

1. Advanced Programming
2. Software Engineering
3. Operating Systems

Each workspace owns its PDF(s), reading position, editable learning directory, related sources and code references, and AI conversations. The top-level plan can later support cross-course search.

## MVP

- Import a local PDF and classify text, scanned, and mixed pages.
- Extract or OCR the table of contents into an editable learning directory.
- Render the PDF and reliably restore the last reading position.
- Explain a page or selected passage using AI, citing the source page.
- Attach related URLs, files, and code references to a course or directory item.
- Search inside the current project before optionally searching the web.

## Non-goals for the MVP

- Mobile or browser clients
- Mandatory note-taking, spaced-repetition system, or social features
- Automatic execution of untrusted code
- Cloud file hosting or account synchronization

## Source handling

PDFs may be text-native, scanned, or mixed at page level. Text-native pages use PDF text extraction. Pages without dependable text use OCR and retain page-image coordinates. AI responses must identify whether an assertion comes from the current PDF, an attached source, web search, or model inference.
