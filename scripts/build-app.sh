#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release -j 2
bin_path="$(swift build -c release --show-bin-path)"
app_path="$PWD/dist/EVBShot.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/EVBShot" "$app_path/Contents/MacOS/EVBShot"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
signing_identity="${EVBSHOT_SIGN_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
    codesign --force --sign - --entitlements Resources/EVBShot.entitlements "$app_path"
else
    codesign --force --options runtime --timestamp --entitlements Resources/EVBShot.entitlements --sign "$signing_identity" "$app_path"
fi
codesign --verify --strict "$app_path"
printf '%s\n' "$app_path"
