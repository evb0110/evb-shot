#!/usr/bin/env python3
"""Submit a signed app ZIP or DMG and require Apple's Accepted result."""
import json
import os
import subprocess
import sys
from pathlib import Path


def credentials():
    profile = os.environ.get('EVBSHOT_NOTARY_PROFILE')
    if profile:
        return ['--keychain-profile', profile]
    names = ['APPLE_API_KEY', 'APPLE_API_KEY_ID', 'APPLE_API_ISSUER']
    if not all(os.environ.get(name) for name in names):
        raise SystemExit('Notarization requires a Keychain profile or complete APPLE_API_* credentials')
    return ['--key', os.environ[names[0]], '--key-id', os.environ[names[1]], '--issuer', os.environ[names[2]]]


def notarize(artifact, receipt):
    auth = credentials()
    result = subprocess.run(['xcrun', 'notarytool', 'submit', str(artifact), *auth,
                             '--wait', '--timeout', '20m', '--output-format', 'json'],
                            capture_output=True, text=True)
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    try:
        submission = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise SystemExit('Notarization did not return a submission receipt; see ' + str(receipt))
    if result.returncode or submission.get('status') != 'Accepted':
        if submission.get('id'):
            subprocess.run(['xcrun', 'notarytool', 'log', submission['id'], *auth,
                            str(receipt.with_suffix('.issues.json'))], check=False)
        raise SystemExit('Notarization was not accepted; see ' + str(receipt))
    print(f'PASS Apple notarization: {artifact.name}, submission {submission["id"]}')


if __name__ == '__main__':
    notarize(Path(sys.argv[1]), Path(sys.argv[2]))
