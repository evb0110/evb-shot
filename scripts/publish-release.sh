#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${RELEASE_TAG:?Set RELEASE_TAG to the version tag}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
[[ "$tag" == "v$version" ]] || { printf 'Tag must match Info.plist: v%s\n' "$version" >&2; exit 1; }
revision=$(git rev-parse HEAD)
mkdir -p .devkit
state="$PWD/.devkit/release-state.json"
if ! gh release view "$tag" --json isDraft,targetCommitish > "$state"; then
    gh release create "$tag" --draft --verify-tag --target "$revision" --title "EVB Shot $version" --notes-file docs/release-notes.md
    gh release view "$tag" --json isDraft,targetCommitish > "$state"
fi
python3 - "$state" "$revision" <<'PY'
import json,sys
with open(sys.argv[1]) as stream: state=json.load(stream)
if not state['isDraft']: raise SystemExit('Release is already public; published artifacts will not be replaced.')
if state['targetCommitish'] != sys.argv[2]: raise SystemExit('Existing draft targets a different commit; leave it unchanged.')
PY
python3 scripts/verify-update-feed.py dist/release
gh release upload "$tag" dist/release/EVB-Shot-macOS-arm64.zip dist/release/build-receipt.json dist/release/SHA256SUMS dist/release/appcast.xml --clobber
# Verify the downloaded bytes before making the release or latest link public.
verification=$(mktemp -d "$PWD/.devkit/release-upload.XXXXXX")
gh release download "$tag" --dir "$verification" --pattern EVB-Shot-macOS-arm64.zip --pattern build-receipt.json --pattern SHA256SUMS --pattern appcast.xml
cmp dist/release/SHA256SUMS "$verification/SHA256SUMS"
(cd "$verification" && shasum -a 256 --check SHA256SUMS)
python3 scripts/verify-update-feed.py "$verification"
swift scripts/verify-update-signature.swift "$verification" Resources/Info.plist
gh release edit "$tag" --draft=false --latest
