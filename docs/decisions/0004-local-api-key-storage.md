# ADR 0004: Store the Qwen key in a user-only local file

## Status

Superseded by ADR 0005

## Context

Satori is currently packaged with an ad-hoc development signature. The legacy macOS keychain can block indefinitely while decrypting an item, and the data-protection keychain rejects writes from this build because it has no Apple-issued keychain access-group entitlement. Either behavior makes the learning UI unusable.

## Decision

Store the Qwen API key at `~/Library/Application Support/satori/qwen-api-key`. Set the containing directory to POSIX mode `700` and the key file to mode `600`. Never copy the key into the repository, logs, screenshots, learning-session archive, or provider request history. Keep the provider host built into the application.

All reads and writes remain off the main UI path. When Satori gains a stable Developer ID or App Store signature, migrate the value into the data-protection keychain and delete the local file only after a verified write and read.

## Consequences

- The current development build starts and saves settings reliably.
- Other macOS users cannot read the key through normal file permissions.
- Processes already running as the same macOS user can read the file, so this is weaker than a properly entitled data-protection keychain.
- The previous legacy-keychain item is intentionally left untouched; the user must paste the key once into the new settings flow.
