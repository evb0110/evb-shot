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
# SwiftPM links a binary framework but does not embed it in our hand-built app.
framework="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$framework" ]] || { printf 'Missing resolved Sparkle framework: %s\n' "$framework" >&2; exit 1; }
mkdir -p "$app_path/Contents/Frameworks"
ditto "$framework" "$app_path/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app_path/Contents/Resources/Sparkle-LICENSE.txt"
signing_identity="${EVBSHOT_SIGN_IDENTITY:--}"
signing_options=(--force)
if [[ -n "${EVBSHOT_SIGN_KEYCHAIN:-}" ]]; then signing_options+=(--keychain "$EVBSHOT_SIGN_KEYCHAIN"); fi
sparkle="$app_path/Contents/Frameworks/Sparkle.framework"
# Sign inside out, including Sparkle's standalone helper. Developer ID builds
# must give the framework the host's identity for hardened library validation.
for component in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle/Versions/B/XPCServices/Downloader.xpc" "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle"; do
    if [[ "$signing_identity" == "-" ]]; then
        codesign "${signing_options[@]}" --sign - "$component"
    else
        codesign "${signing_options[@]}" --options runtime --timestamp --sign "$signing_identity" "$component"
    fi
done
if [[ "$signing_identity" == "-" ]]; then
    codesign "${signing_options[@]}" --sign - --entitlements Resources/EVBShot.entitlements "$app_path"
else
    codesign "${signing_options[@]}" --options runtime --timestamp --entitlements Resources/EVBShot.entitlements --sign "$signing_identity" "$app_path"
fi
codesign --verify --deep --strict "$app_path"
printf '%s\n' "$app_path"
