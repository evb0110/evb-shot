#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-sparkle-tools.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
python3 - "$version" <<'PY'
import os, shutil, subprocess, sys, tempfile
from pathlib import Path
generator = Path('.devkit/dependencies/sparkle/bin/generate_appcast').resolve()
# Only the update ZIP is input, even when the release also contains a DMG or
# a previous appcast. Never let the generator choose between duplicate builds.
with tempfile.TemporaryDirectory(prefix='sparkle-feed-', dir='.devkit') as directory:
    stage = Path(directory).resolve()
    shutil.copy2('dist/release/EVB-Shot-macOS-arm64.zip', stage / 'EVB-Shot-macOS-arm64.zip')
    shutil.copy2('docs/release-notes.md', stage / 'EVB-Shot-macOS-arm64.md')
    seed = os.environ.get('SPARKLE_PRIVATE_KEY', '').encode()
    if not seed:
        # Use the utility which owns the existing local Keychain access.
        key = stage / 'key'
        subprocess.run(['.devkit/dependencies/sparkle/bin/generate_keys', '--account', 'com.evb.shot.updates', '-x', str(key)], check=True, stdout=subprocess.DEVNULL)
        key.chmod(0o600)
        seed = key.read_bytes()
        key.unlink()
    subprocess.run([str(generator), '--ed-key-file', '-', '--download-url-prefix',
                    f'https://github.com/evb0110/evb-shot/releases/download/v{sys.argv[1]}/',
                    '--link', 'https://evb-shot.vercel.app', '--maximum-deltas', '0',
                    '--embed-release-notes', str(stage)], input=seed, check=True)
    shutil.copy2(stage / 'appcast.xml', 'dist/release/appcast.xml')
PY
python3 scripts/verify-update-feed.py dist/release
swift scripts/verify-update-signature.swift dist/release Resources/Info.plist
