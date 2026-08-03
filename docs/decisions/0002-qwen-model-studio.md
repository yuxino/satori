# 0002: Use Qwen through Alibaba Cloud Model Studio

## Status

Accepted - 2026-08-04

## Context

Satori needs one affordable model path that can understand extracted PDF text, inspect scanned page images, and optionally search the web. A ChatGPT Plus subscription does not provide OpenAI API credits, so the original OpenAI-only integration did not fit the user's account setup.

## Decision

Use Alibaba Cloud Model Studio's OpenAI-compatible Responses API with `qwen3.7-plus`. The model accepts text and image input and supports the built-in `web_search` tool. Ask the user for the API Key and API Host shown by Model Studio because the host varies by region, workspace, and billing plan. Store the key in macOS Keychain and the non-secret host as a local preference.

## Consequences

- Text and scanned PDFs keep one learning flow and one model.
- Satori does not need an Alibaba SDK or a second search provider.
- The user needs a paid Model Studio account rather than an OpenAI API account.
- A future provider switch should add a provider abstraction only when a second provider is actually required.
