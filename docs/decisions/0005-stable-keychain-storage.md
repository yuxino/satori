# ADR 0005: Persist the Qwen key in macOS Keychain

## Status

Accepted; development-signing behavior amended by ADR 0012

## Context

ADR 0004 temporarily moved the API key to an Application Support file after an ad-hoc build blocked on an old legacy-keychain item and lacked entitlements for the data-protection keychain. The project requirement is stricter: API credentials belong in the operating system credential store, and a saved connection must survive application restarts and rebuilds.

## Decision

Package Satori with the installed stable local signing identity when available. Store the Qwen key under the new versioned service `com.yuxino.satori.qwen.v2` in the macOS file-based keychain. Create its access control with `SecAccessCreate` and a nil trusted list, which trusts only the calling Satori application. Keep every blocking keychain operation off the main thread.

Treat the ADR 0004 file as migration input only. Write its value to the new keychain item, read it back, compare it in memory, and delete the file only after verification. Do not query or delete the older unversioned keychain item that previously blocked Security Server.

## Consequences

- A saved key survives normal restarts and rebuilds signed by the same local identity.
- The transitional plaintext file is removed after a successful verified migration.
- Source builds without a stable identity can still be packaged ad hoc, but rebuilding such an app may require reconnecting Qwen because its code identity changes.
- A future Developer ID or App Store build should migrate to the data-protection keychain with Apple-authorized entitlements.
