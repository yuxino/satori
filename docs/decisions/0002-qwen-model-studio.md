# 0002: Use Qwen through Alibaba Cloud Model Studio

## Status

Accepted - 2026-08-04

## Context

Satori needs one affordable model path that can understand extracted PDF text, inspect scanned page images, and optionally search the web. A ChatGPT Plus subscription does not provide OpenAI API credits, so the original OpenAI-only integration did not fit the user's account setup.

## Decision

Use Alibaba Cloud Model Studio's OpenAI-compatible Responses API. Default to `qwen3.8-max`, the current high-capability multimodal model, while allowing the user to select `qwen3.7-plus` or `qwen3.7-flash` when balancing quality, latency, and cost. Ask the user for the API Key and API Host shown by Model Studio because the host varies by region, workspace, and billing plan. Store the key in macOS Keychain and the non-secret host and model ID as local preferences.

## Consequences

- Text and scanned PDFs keep one learning flow, while the model quality tier remains configurable.
- Satori does not need an Alibaba SDK or a second search provider.
- The user needs a paid Model Studio account rather than an OpenAI API account.
- A future provider switch should add a provider abstraction only when a second provider is actually required.
