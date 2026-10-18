#!/bin/bash
# Use the same Developer ID and App Store Connect credentials as the EVB siblings.
# Codesign uses an isolated keychain, leaving existing signing identities alone.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CSC_LINK:?Missing Developer ID certificate}"
: "${CSC_KEY_PASSWORD:?Missing certificate password}"
: "${APPLE_API_KEY_CONTENT:?Missing notarization private key}"
: "${APPLE_API_KEY_ID:?Missing notarization key ID}"
: "${APPLE_API_ISSUER:?Missing notarization issuer}"
mkdir -p .devkit
original_umask=$(umask)
umask 077
signing_dir=$(mktemp -d "$PWD/.devkit/release-signing.XXXXXX")
keychain="$signing_dir/signing.keychain-db"
cleanup() {
    local exit_code=$?
    if [[ -f "$keychain" ]]; then security delete-keychain "$keychain" || exit_code=1; fi
    python3 - "$signing_dir" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
    exit "$exit_code"
}
trap cleanup EXIT
python3 - "$signing_dir" <<'PY'
import base64, os, sys
from pathlib import Path
root = Path(sys.argv[1])
(root / 'certificate.p12').write_bytes(base64.b64decode(os.environ['CSC_LINK'], validate=True))
(root / 'notary.p8').write_text(os.environ['APPLE_API_KEY_CONTENT'])
PY
keychain_password="$(uuidgen)-$(uuidgen)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/certificate.p12" -k "$keychain" -P "$CSC_KEY_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
export EVBSHOT_SIGN_IDENTITY
EVBSHOT_SIGN_IDENTITY=$(security find-identity -v -p codesigning "$keychain" | python3 -c '
import re, sys
identities = re.findall(r"([A-F0-9]{40}) \"Developer ID Application: [^\"]+ \(ZQ9333Y386\)\"", sys.stdin.read())
if len(identities) != 1: raise SystemExit("Expected one EVB Developer ID identity")
print(identities[0])')
export EVBSHOT_SIGN_KEYCHAIN="$keychain"
export APPLE_API_KEY="$signing_dir/notary.p8"
unset CSC_LINK CSC_KEY_PASSWORD APPLE_API_KEY_CONTENT keychain_password
# Keep private transfer files at 0600, while app contents retain normal public
# read/execute permissions instead of inheriting the signing setup's umask.
umask "$original_umask"
bash scripts/package-release.sh
