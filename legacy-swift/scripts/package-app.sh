#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir="$project_root/dist/Satori.app"
contents_dir="$app_dir/Contents"

cd "$project_root"
swift build -c release --product satori

if [ -e "$app_dir" ]; then
    rm -rf -- "$app_dir"
fi
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$project_root/.build/release/satori" "$contents_dir/MacOS/satori"
cp "$project_root/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_root/Resources/satori.icns" "$contents_dir/Resources/satori.icns"
chmod 755 "$contents_dir/MacOS/satori"

plutil -lint "$contents_dir/Info.plist" >/dev/null
signing_identity=${SATORI_CODESIGN_IDENTITY:-}
if [ -z "$signing_identity" ]; then
    available_identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
    case "$available_identities" in
        *'"mimi Local Development"'*) signing_identity="mimi Local Development" ;;
    esac
fi
if [ -z "$signing_identity" ]; then
    signing_identity="-"
fi
codesign --force --deep --timestamp=none --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
