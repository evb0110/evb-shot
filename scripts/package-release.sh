#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$version" ]]; then
    printf 'Release tag must match Info.plist: v%s\n' "$version" >&2
    exit 1
fi
[[ "$(uname -m)" == arm64 ]] || { printf 'The release target is Apple Silicon (arm64).\n' >&2; exit 1; }
[[ -n "${EVBSHOT_SIGN_IDENTITY:-}" && "$EVBSHOT_SIGN_IDENTITY" != - ]] || { printf 'Release packaging requires a Developer ID identity.\n' >&2; exit 1; }
python3 - <<'PY'
import sys
sys.path.insert(0, 'scripts')
from importlib import import_module
import_module('notarize-artifact').credentials()
PY
bash scripts/build-app.sh
app="$PWD/dist/EVB Shot.app"
mkdir -p .devkit/notarization dist/release
python3 - <<'PY'
from pathlib import Path
for name in ['appcast.xml', 'EVB-Shot-macOS-arm64.md', 'EVB-Shot-macOS-arm64.zip', 'EVB-Shot-macOS-arm64.dmg', 'build-receipt.json', 'SHA256SUMS']:
    Path('dist/release', name).unlink(missing_ok=True)
PY
# Staple the final app before either distribution container is made. Do not
# re-sign it afterwards: the ticket is bound to this exact code signature.
ditto -c -k --sequesterRsrc --keepParent "$app" .devkit/notarization/submit.zip
python3 scripts/notarize-artifact.py .devkit/notarization/submit.zip .devkit/notarization/app.json
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"
archive="$PWD/dist/release/EVB-Shot-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"

# Generate the one-item Sparkle feed from a ZIP-only staging directory.
bash scripts/generate-update-feed.sh
python3 - "$app" <<'PY'
import subprocess, sys, tempfile
from pathlib import Path
with tempfile.TemporaryDirectory(prefix='dmg-content-', dir='.devkit') as directory:
    stage = Path(directory)
    subprocess.run(['ditto', sys.argv[1], str(stage / 'EVB Shot.app')], check=True)
    (stage / 'Applications').symlink_to('/Applications')
    subprocess.run(['hdiutil', 'create', '-volname', 'EVB Shot', '-srcfolder', str(stage),
                    '-fs', 'APFS', '-format', 'ULFO', '-ov', 'dist/release/EVB-Shot-macOS-arm64.dmg'], check=True)
PY
dmg="$PWD/dist/release/EVB-Shot-macOS-arm64.dmg"
signing_options=(--timestamp)
if [[ -n "${EVBSHOT_SIGN_KEYCHAIN:-}" ]]; then signing_options+=(--keychain "$EVBSHOT_SIGN_KEYCHAIN"); fi
codesign "${signing_options[@]}" --sign "$EVBSHOT_SIGN_IDENTITY" "$dmg"
python3 scripts/notarize-artifact.py "$dmg" .devkit/notarization/dmg.json
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
export EVBSHOT_RELEASE_VERSION="$version"
python3 - <<'PY'
import json, os, platform, subprocess
from pathlib import Path
receipt = {'product': 'EVB Shot', 'version': os.environ['EVBSHOT_RELEASE_VERSION'],
           'commit': subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(),
           'architecture': platform.machine(), 'minimumMacOS': '15.0',
           'signingTeamID': 'ZQ9333Y386', 'notarized': True, 'dmgNotarized': True}
Path('dist/release/build-receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
PY
(cd dist/release && shasum -a 256 EVB-Shot-macOS-arm64.dmg EVB-Shot-macOS-arm64.zip build-receipt.json appcast.xml > SHA256SUMS)
python3 scripts/verify-release.py dist/release
