#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-sparkle-tools.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
generator="$PWD/.devkit/dependencies/sparkle/bin/generate_appcast"
arguments=(--download-url-prefix "https://github.com/evb0110/evb-shot/releases/download/v$version/" --link https://evb-shot.vercel.app --maximum-deltas 0 --embed-release-notes)
cp docs/release-notes.md dist/release/EVB-Shot-macOS-arm64.md
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    # stdin keeps the signing seed out of process arguments and logs.
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$generator" --ed-key-file - "${arguments[@]}" "$PWD/dist/release"
else
    # Use the key owner utility's Keychain access, rather than a separate
    # per-tool macOS access prompt in generate_appcast. The scoped seed is
    # passed over stdin and the private transfer file is removed on every exit.
    python3 - "$generator" "${arguments[@]}" "$PWD/dist/release" <<'PY'
import subprocess, sys, tempfile
from pathlib import Path
with tempfile.TemporaryDirectory(prefix='sparkle-signing-', dir='.devkit') as directory:
    key = Path(directory) / 'key'
    subprocess.run(['.devkit/dependencies/sparkle/bin/generate_keys', '--account', 'com.evb.shot.updates', '-x', str(key)], check=True, stdout=subprocess.DEVNULL)
    key.chmod(0o600)
    subprocess.run([sys.argv[1], '--ed-key-file', '-', *sys.argv[2:]], input=key.read_bytes(), check=True)
PY
fi
python3 scripts/verify-update-feed.py dist/release
swift scripts/verify-update-signature.swift dist/release Resources/Info.plist
