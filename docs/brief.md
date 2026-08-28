# Product brief

## Goal

Build a local-first Mac reading workspace that helps the learner understand difficult PDF material without turning study into note management. The page stays central; explanations appear only when explicitly requested.

## Current product

- Open local text, scanned, or mixed PDFs without copying them into the repository or cloud storage.
- Render pages with PDF.js and restore each book's page, zoom, spread mode, and recovered outline. For a scanned book without a directory, send only the bounded page sets disclosed by the directory action after the learner chooses it.
- Use the visible page or a selected region as ephemeral visual evidence for an explanation.
- Keep the bookshelf, reading activity, and per-book Q&A history in local Application Support storage.
- Configure multiple named visual AI services while keeping every API key in macOS Keychain.
- Keep the teacher entry side-effect free: opening it does not read a key, render evidence, or contact a provider.

## Non-goals for the MVP

- Mobile or browser clients
- Mandatory note-taking, spaced-repetition system, or social features
- Automatic execution of untrusted code
- Cloud file hosting or account synchronization
- A general AI chat dashboard detached from the current book

## Evidence and privacy

The page is the evidence. Satori renders bounded page images locally and sends them only after an explicit question, region action, or outline-recognition action whose page range is disclosed first. A normal question sends only the current page; adjacent pages are included only when the learner explicitly asks about the previous or next page. Selected-region images and provider request context are not persisted; remote requests disable provider-side response storage where supported.
