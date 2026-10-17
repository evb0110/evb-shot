#!/usr/bin/env python3
"""Increment the public version and monotonic Sparkle build number together."""
import argparse
import plistlib
import re
from pathlib import Path

def bump(path, level='patch', write=True):
    original = path.read_text()
    info = plistlib.loads(original.encode())
    version = info['CFBundleShortVersionString']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Expected a stable three-component version')
    parts = list(map(int, version.split('.')))
    index = {'major': 0, 'minor': 1, 'patch': 2}[level]
    parts[index] += 1
    for i in range(index + 1, 3):
        parts[i] = 0
    next_version = '.'.join(map(str, parts))
    build = str(int(info['CFBundleVersion']) + 1)
    for key, value in [('CFBundleShortVersionString', next_version), ('CFBundleVersion', build)]:
        original, count = re.subn(r'(<key>' + key + r'</key>\s*<string>)[^<]+(</string>)', lambda m: m[1] + value + m[2], original)
        if count != 1:
            raise ValueError(f'Expected one {key}')
    if write:
        path.write_text(original)
    return next_version

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('level', choices=['patch', 'minor', 'major'], nargs='?', default='patch')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    print(bump(Path(__file__).resolve().parents[1] / 'Resources/Info.plist', args.level, write=not args.dry_run))
