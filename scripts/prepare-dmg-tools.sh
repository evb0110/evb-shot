#!/bin/bash
# A separate build-only environment; never install into the system Python.
set -euo pipefail
cd "$(dirname "$0")/.."
tools="$PWD/.devkit/dependencies/dmgbuild"
if [[ ! -x "$tools/bin/python" ]]; then python3 -m venv "$tools"; fi
"$tools/bin/python" -m pip --disable-pip-version-check install --require-hashes -r scripts/dmg-requirements.txt
