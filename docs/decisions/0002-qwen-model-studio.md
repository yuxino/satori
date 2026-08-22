# 0002: Use Qwen through Alibaba Cloud Model Studio

## Status

Superseded by [0011](0011-multi-provider-profiles.md). Model Studio remains a built-in preset and the legacy default, but is no longer the only provider.

## Context

Satori needs one affordable model path that can understand extracted PDF text, inspect scanned page images, and optionally search the web. A ChatGPT Plus subscription does not provide OpenAI API credits, so the original OpenAI-only integration did not fit the user's account setup.

## Decision

Use Alibaba Cloud Model Studio's OpenAI-compatible Responses API. Default to `qwen3.7-max-2026-06-08`, the strongest listed Qwen3.7 snapshot with visual understanding, while allowing the user to select `qwen3.7-plus` or `qwen3.7-flash` when balancing quality, latency, and cost. Satori targets the China (Beijing) region and internally uses Alibaba's supported shared endpoint, `https://dashscope.aliyuncs.com/compatible-mode/v1`, so the user supplies only the API Key. Store the key in macOS Keychain and the model ID as a local preference. Older installations that stored the pre-release `qwen3.8-max` label migrate automatically.

## Consequences

- Text and scanned PDFs keep one learning flow, while the model quality tier remains configurable.
- Satori does not need an Alibaba SDK or a second search provider.
- The user needs a China (Beijing) Model Studio API Key rather than an OpenAI API account.
- The settings UI stays simple, while the assistant initializer retains endpoint injection for tests and a future migration to workspace-specific domains.
- A future provider switch should add a provider abstraction only when a second provider is actually required.
