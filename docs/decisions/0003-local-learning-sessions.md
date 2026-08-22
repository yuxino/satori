# 0003: Keep per-document learning sessions locally

## Status

Accepted in principle. The Swift-era storage shape was replaced by the Tauri store in [0010](0010-tauri-rewrite.md); local per-book history, bounded follow-ups, ephemeral images, and provider `store: false` remain active.

## Context

A replaceable single answer cannot support real study: the learner loses earlier explanations, cannot make meaningful follow-up references, and cannot return to the source page that prompted an answer. Provider-side response storage would conflict with Satori's local-first product direction and make learning history dependent on one API.

## Decision

Persist completed learning turns in a separate local JSON archive keyed by Satori's stable document ID. Each turn stores the question, answer, page index, source labels, citations, attachment count, timestamp, and whether generation completed or was stopped. Images themselves remain ephemeral. For follow-up requests, send only the latest six textual turns, with per-field length limits, before the current PDF page and question. Continue sending `store: false` to Model Studio.

## Consequences

- Each book has a durable, provider-independent learning record.
- Follow-up questions work without uploading the entire history or retaining it on the provider.
- Session persistence can evolve independently from course/PDF metadata and frequent reading-position saves.
- The local archive contains AI conversations and therefore must remain in Application Support, never in Git.
- A future export or sync feature must be an explicit product and privacy decision.
