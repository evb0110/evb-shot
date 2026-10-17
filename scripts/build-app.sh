#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export LIBPNG_PREFIX="${LIBPNG_PREFIX:-$PWD/.devkit/dependencies/libpng/install}"
if [[ ! -f "$LIBPNG_PREFIX/lib/libpng16.a" ]]; then bash scripts/build-libpng.sh "$LIBPNG_PREFIX"; fi
swift build -c release -j 2
bin_path="$(swift build -c release --show-bin-path)"
app_path="$PWD/dist/EVB Shot.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/EVBShot" "$app_path/Contents/MacOS/EVBShot"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp LICENSE "$app_path/Contents/Resources/LICENSE.txt"
cp Resources/libpng-LICENSE.txt "$app_path/Contents/Resources/libpng-LICENSE.txt"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
signing_identity="${EVBSHOT_SIGN_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
    codesign --force --sign - --entitlements Resources/EVBShot.entitlements "$app_path"
else
    codesign --force --options runtime --timestamp --entitlements Resources/EVBShot.entitlements --sign "$signing_identity" "$app_path"
fi
codesign --verify --strict "$app_path"
printf '%s\n' "$app_path"
