#!/usr/bin/env python3
"""Verify the shipped DMG and update ZIP, including Gatekeeper and stapled tickets."""
import hashlib
import json
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

TEAM = 'ZQ9333Y386'


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        print(result.stdout, end='')
        print(result.stderr, end='', file=sys.stderr)
        result.check_returncode()
    return result.stdout


def signed(target):
    run('codesign', '--verify', '--deep', '--strict', str(target))
    metadata = subprocess.run(['codesign', '-d', '--verbose=4', str(target)],
                              text=True, capture_output=True, check=True).stderr
    assert f'TeamIdentifier={TEAM}' in metadata and 'Authority=Developer ID Application:' in metadata
    if target.suffix == '.app':
        assert 'runtime' in metadata, 'App must enable hardened runtime'
        run('spctl', '--assess', '--type', 'execute', '--verbose=4', str(target))
    else:
        run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', str(target))
    run('xcrun', 'stapler', 'validate', str(target))


def manifest(root):
    result = {}
    for path in root.rglob('*'):
        name = str(path.relative_to(root))
        if path.is_symlink():
            result[name] = ('link', str(path.readlink()))
        elif path.is_file():
            with path.open('rb') as stream:
                result[name] = ('file', hashlib.file_digest(stream, 'sha256').hexdigest(), path.stat().st_mode & 0o777)
    return result


def verify(folder):
    folder = folder.resolve()
    run('bash', 'scripts/prepare-dmg-tools.sh')
    expected = {'EVB-Shot-macOS-arm64.dmg', 'EVB-Shot-macOS-arm64.zip', 'build-receipt.json', 'appcast.xml'}
    checks = {}
    for line in (folder / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        assert name in expected and name not in checks, 'Unexpected or duplicate checksum'
        with (folder / name).open('rb') as stream:
            assert hashlib.file_digest(stream, 'sha256').hexdigest() == digest, name
        checks[name] = digest
    assert set(checks) == expected, 'Every public artifact must have a checksum'
    receipt = json.loads((folder / 'build-receipt.json').read_text())
    assert receipt['product'] == 'EVB Shot' and receipt['architecture'] == 'arm64'
    assert receipt['minimumMacOS'] == '15.0' and receipt['signingTeamID'] == TEAM
    assert receipt['notarized'] is True and receipt['dmgNotarized'] is True
    run('python3', 'scripts/verify-update-feed.py', str(folder))
    run('swift', 'scripts/verify-update-signature.swift', str(folder), 'Resources/Info.plist')
    Path('.devkit').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='verify-release-', dir='.devkit') as directory:
        stage = Path(directory).resolve()
        run('ditto', '-x', '-k', str(folder / 'EVB-Shot-macOS-arm64.zip'), str(stage / 'zip'))
        app = stage / 'zip/EVB Shot.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier'] == 'com.evb.shot'
        assert info['CFBundleShortVersionString'] == receipt['version']
        assert run('lipo', '-archs', str(app / 'Contents/MacOS/EVBShot')).strip() == 'arm64'
        signed(app)
        dmg = folder / 'EVB-Shot-macOS-arm64.dmg'
        signed(dmg)
        run('hdiutil', 'verify', str(dmg))
        mount = stage / 'mounted'
        mount.mkdir()
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(dmg))
        try:
            run('.devkit/dependencies/dmgbuild/bin/python', 'scripts/verify-dmg-layout.py', str(mount))
            assert (mount / 'Applications').is_symlink() and str((mount / 'Applications').readlink()) == '/Applications'
            installed = mount / 'EVB Shot.app'
            signed(installed)
            assert manifest(app) == manifest(installed), 'DMG and update ZIP must contain the identical signed, stapled app'
        finally:
            run('hdiutil', 'detach', str(mount))
    print(f'PASS notarized Developer ID app and DMG, Gatekeeper, identical ZIP/DMG app, checksums and signed updates: {receipt["version"]}')


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
