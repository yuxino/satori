#!/usr/bin/env bash
set -euo pipefail

# Dev launcher for the satori Tauri application on macOS.
#
# Runs the app the way the release does — a real .app bundle with the
# original icon.icns — so macOS renders the Dock icon with the standard
# rounded mask, identical to the release app. Like mimi-r's dev-app.sh, this
# builds a RELEASE binary (the Tauri dev-mode runtime icon override, which
# replaces the Dock icon with an unmasked square in debug builds, does not
# run in release). See docs/plans/2026-08-16-tauri-dock-icon-design.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

export CARGO_HOME="${CARGO_HOME:-$PROJECT_DIR/.cargo-home}"
export npm_config_cache="${npm_config_cache:-$PROJECT_DIR/.npm-cache}"

# Stop any previous dev instance.
pkill -f "satori-dev.app/Contents/MacOS/satori" 2>/dev/null || true
pkill -f "target/debug/satori" 2>/dev/null || true

# Build the frontend (a release binary loads the bundled dist/, not vite).
npm run build

# Build the release binary the way `tauri build` does. The custom-protocol
# feature is what flips Tauri's `cfg(dev)` off: without it, Tauri treats even
# a release build as dev and replaces the Dock icon at runtime with an
# unmasked square (the launch icon is correct, then it flips square once the
# app runs).
cargo build --release --features tauri/custom-protocol --manifest-path src-tauri/Cargo.toml

# Assemble the .app wrapper around the release binary.
APP="$PROJECT_DIR/src-tauri/target/release/satori-dev.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJECT_DIR/src-tauri/target/release/satori" "$APP/Contents/MacOS/satori"
cp "$PROJECT_DIR/src-tauri/icons/icon.icns" "$APP/Contents/Resources/icon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>satori dev</string>
  <key>CFBundleIdentifier</key>
  <string>com.yuxino.satori</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.education</string>
  <key>CFBundleVersion</key>
  <string>dev</string>
  <key>CFBundleExecutable</key>
  <string>satori</string>
  <key>CFBundleDisplayName</key>
  <string>satori dev</string>
  <key>LSRequiresCarbon</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>icon.icns</string>
  <key>CSResourcesFileMapped</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleShortVersionString</key>
  <string>3.0.0-dev</string>
</dict>
</plist>
PLIST

# Prefer an Apple-issued development identity. macOS can bind Keychain access
# to its stable Team ID across rebuilds. Developer ID identities are never
# selected automatically: development must not silently use a release key.
# A self-signed certificate has no Team ID, so modern Keychain partition checks
# fall back to the binary's changing CDHash.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
APPLE_DEVELOPMENT_IDENTITIES="$(awk '/"Apple Development:/ {print $2}' <<<"$IDENTITIES")"
APPLE_DEVELOPMENT_COUNT="$(awk '/"Apple Development:/ {count++} END {print count + 0}' <<<"$IDENTITIES")"
LOCAL_IDENTITIES="$(awk '/"mimi Local Development"/ {print $2}' <<<"$IDENTITIES")"
LOCAL_IDENTITY_COUNT="$(awk '/"mimi Local Development"/ {count++} END {print count + 0}' <<<"$IDENTITIES")"
SIGNING_KIND="explicit"
if [[ -n "${SATORI_CODESIGN_IDENTITY:-}" ]]; then
  IDENTITY="$SATORI_CODESIGN_IDENTITY"
elif (( APPLE_DEVELOPMENT_COUNT > 1 )); then
  printf '%s\n' 'error: multiple Apple Development identities found; set SATORI_CODESIGN_IDENTITY to the intended certificate hash.' >&2
  printf '%s\n' "$APPLE_DEVELOPMENT_IDENTITIES" >&2
  exit 1
elif (( APPLE_DEVELOPMENT_COUNT == 1 )); then
  IDENTITY="$APPLE_DEVELOPMENT_IDENTITIES"
  SIGNING_KIND="apple-team"
elif (( LOCAL_IDENTITY_COUNT > 1 )); then
  printf '%s\n' 'error: multiple local development identities found; set SATORI_CODESIGN_IDENTITY to the intended certificate hash.' >&2
  printf '%s\n' "$LOCAL_IDENTITIES" >&2
  exit 1
elif (( LOCAL_IDENTITY_COUNT == 1 )); then
  IDENTITY="$LOCAL_IDENTITIES"
  SIGNING_KIND="local"
else
  IDENTITY="-"
  SIGNING_KIND="adhoc"
fi

codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

SIGNATURE_INFO="$(codesign -d --verbose=4 "$APP" 2>&1)"
BUNDLE_IDENTIFIER="$(sed -n 's/^Identifier=//p' <<<"$SIGNATURE_INFO")"
TEAM_IDENTIFIER="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNATURE_INFO")"
AUTHORITY="$(sed -n 's/^Authority=//p' <<<"$SIGNATURE_INFO" | head -1)"

if [[ "$BUNDLE_IDENTIFIER" != "com.yuxino.satori" ]]; then
  printf 'error: unexpected signed bundle identifier: %s\n' "$BUNDLE_IDENTIFIER" >&2
  exit 1
fi

if [[ "$SIGNING_KIND" == "apple-team" && ( -z "$TEAM_IDENTIFIER" || "$TEAM_IDENTIFIER" == "not set" ) ]]; then
  printf 'error: selected Apple signing identity produced no Team ID\n' >&2
  exit 1
fi

if [[ -n "$TEAM_IDENTIFIER" && "$TEAM_IDENTIFIER" != "not set" ]]; then
  printf 'signed with %s (Team ID: %s); changing to this signing team may require one final authorization for existing credentials\n' "${AUTHORITY:-$IDENTITY}" "$TEAM_IDENTIFIER"
else
  printf '%s\n' 'warning: this build has no Apple Team ID; opening the app and viewing connection status stay silent.' >&2
  printf '%s\n' '         Any frontend or Rust rebuild changes the CDHash, so each saved profile may require authorization on its first explicit AI use.' >&2
  printf '%s\n' '         Install an Apple Development certificate, or set SATORI_CODESIGN_IDENTITY to an Apple identity with a Team ID, to eliminate rebuild prompts.' >&2
fi

echo "launching $APP"
open "$APP"
