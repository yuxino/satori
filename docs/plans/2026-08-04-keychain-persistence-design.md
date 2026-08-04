# Stable Qwen credential persistence

## Problem

Satori currently writes the Qwen API key to a permission-restricted Application Support file because the ad-hoc build could not use the data-protection keychain. That violates the project's secure-storage rule and makes the connection state depend on a transitional file path.

## Design

Package Satori with the existing stable local code-signing identity when it is available. Store the key in a new, Satori-specific item in the macOS file-based keychain. Create the item with a `SecAccess` object whose trusted application list contains only the calling Satori app. Keep all blocking keychain calls on background tasks, as they already are in the settings and request flows.

The current `~/Library/Application Support/satori/qwen-api-key` file becomes migration input only. On the first read, Satori checks the new keychain item. If it is absent, Satori reads the transitional file, writes the value to the new keychain item, reads it back, compares it in memory, and only then deletes the file. A failed write or verification leaves the file untouched and reports the connection as unavailable rather than losing the credential. The older legacy-keychain service is not queried or deleted because it previously blocked inside macOS Security Server.

## Verification

Package with the stable identity and verify its designated requirement. Launch Satori to migrate the existing credential without printing it. Confirm only that the transitional file disappears, the UI reports a connected state, and the settings field contains masked text. Repackage the app, restart it, and confirm the connection remains present. Run the existing core checks and scan Git changes for credential material before committing.
