#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD/.devkit/dependencies/sparkle"
mkdir -p "$root"
archive="$root/Sparkle-2.10.0.tar.xz"
if [[ ! -f "$archive" ]]; then
    curl --fail --location --silent --show-error 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz' --output "$archive"
fi
printf '%s  %s\n' c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c "$archive" | shasum -a 256 --check
if [[ ! -x "$root/bin/generate_appcast" ]]; then tar -xJf "$archive" -C "$root"; fi
