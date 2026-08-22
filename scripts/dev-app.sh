#!/usr/bin/env bash
set -euo pipefail

# Dev launcher for the satori Tauri application on macOS.
#
# Runs the app the way the release does — a real .app bundle with the
# original icon.icns — so macOS renders the Dock icon with the standard
# rounded mask, identical to the release app. Like mimi-r's dev-app.sh, this
# builds a RELEASE binary (the Tauri dev-mode runtime icon override, which
# replaces the Dock icon with an unmasked square in debug builds, does not
# run in release). See docs/decisions/0014-development-app-shell.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

export CARGO_HOME="${CARGO_HOME:-$PROJECT_DIR/.cargo-home}"
export npm_config_cache="${npm_config_cache:-$PROJECT_DIR/.npm-cache}"

# Stop any previous dev instance.
pkill -f "satori-dev.app/Contents/MacOS/satori" 2>/dev/null || true
pkill -f "target/debug/satori" 2>/dev/null || true

# Build the latest frontend. The development-only `tauri://` handler reads
# these files from disk, so CSS/TypeScript changes do not have to be embedded
# into (and therefore do not change) the signed native binary.
npm run build

APP="$PROJECT_DIR/src-tauri/target/release/satori-dev.app"
STAMP="$PROJECT_DIR/src-tauri/target/release/satori-dev.native.sha256"

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

# Hash only inputs that affect the native shell. `dist/` is deliberately not
# included: it is served from disk by the feature-gated development protocol.
NATIVE_INPUTS=(
  "$SCRIPT_DIR/dev-app.sh"
  "$PROJECT_DIR/src-tauri/Cargo.toml"
  "$PROJECT_DIR/src-tauri/Cargo.lock"
  "$PROJECT_DIR/src-tauri/build.rs"
  "$PROJECT_DIR/src-tauri/tauri.conf.json"
  "$PROJECT_DIR/src-tauri/icons/icon.icns"
)
while IFS= read -r path; do
  NATIVE_INPUTS+=("$path")
done < <(find "$PROJECT_DIR/src-tauri/src" "$PROJECT_DIR/src-tauri/capabilities" -type f | LC_ALL=C sort)
NATIVE_HASH="$({
  for path in "${NATIVE_INPUTS[@]}"; do
    shasum -a 256 "$path"
  done
} | shasum -a 256 | awk '{print $1}')"
BUILD_FINGERPRINT="$NATIVE_HASH:$IDENTITY:$PROJECT_DIR:$(rustc --version):$(cargo --version)"

NEEDS_NATIVE_BUILD=1
if [[ -x "$APP/Contents/MacOS/satori" && -f "$STAMP" ]] \
  && [[ "$(<"$STAMP")" == "$BUILD_FINGERPRINT" ]] \
  && codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1; then
  NEEDS_NATIVE_BUILD=0
fi

if (( NEEDS_NATIVE_BUILD == 1 )); then
  # Keep release/custom-protocol behavior so the Dock icon comes from the
  # signed bundle. `dev-live` swaps only the embedded asset handler.
  cargo build --release --features tauri/custom-protocol,dev-live --manifest-path src-tauri/Cargo.toml

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

  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
  printf '%s\n' "$BUILD_FINGERPRINT" > "$STAMP"
  printf '%s\n' 'rebuilt signed native shell; frontend assets will be loaded from dist/'
else
  printf '%s\n' 'reusing signed native shell; frontend-only changes keep the same CDHash'
fi

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
  printf '%s\n' '         Frontend-only changes reuse this signed shell and keep Keychain authorization stable.' >&2
  printf '%s\n' '         Rust/config/signing changes still change the CDHash; each saved profile may then require one authorization on its first explicit AI use.' >&2
  printf '%s\n' '         An Apple Development identity with a Team ID also removes that native-rebuild limitation.' >&2
fi

echo "launching $APP"
open "$APP"
