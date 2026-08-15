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

# Sign with a local identity when available so keychain grants survive
# rebuilds; ad-hoc otherwise.
if IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/1\)/ {print $2; exit}')" && [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi

echo "launching $APP"
open "$APP"
