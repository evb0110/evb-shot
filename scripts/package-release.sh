#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$version" ]]; then
    printf 'Release tag must match Info.plist: v%s\n' "$version" >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
    printf 'The current release target is Apple Silicon (arm64).\n' >&2
    exit 1
fi
bash scripts/build-app.sh
app="$PWD/dist/EVB Shot.app"
codesign --verify --strict "$app"
# The public prototype uses an ad-hoc signature. Local Developer ID builds can
# opt into notarization using an existing notarytool keychain profile.
if [[ -n "${EVBSHOT_NOTARY_PROFILE:-}" ]]; then
    mkdir -p .devkit/notarization
    ditto -c -k --sequesterRsrc --keepParent "$app" .devkit/notarization/submit.zip
    xcrun notarytool submit .devkit/notarization/submit.zip --keychain-profile "$EVBSHOT_NOTARY_PROFILE" --wait --timeout 10m
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute "$app"
fi
mkdir -p dist/release
archive="$PWD/dist/release/EVB-Shot-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
export EVBSHOT_RELEASE_VERSION="$version"
python3 - <<'PY'
import json, os, platform, subprocess
from pathlib import Path
receipt = {'product': 'EVB Shot', 'version': os.environ['EVBSHOT_RELEASE_VERSION'],
           'commit': subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(),
           'architecture': platform.machine(), 'minimumMacOS': '15.0',
           'notarized': bool(os.environ.get('EVBSHOT_NOTARY_PROFILE'))}
Path('dist/release/build-receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
PY
cd dist/release
shasum -a 256 EVB-Shot-macOS-arm64.zip build-receipt.json > SHA256SUMS
