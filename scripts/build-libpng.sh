#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
dependency_prefix="${1:-$PWD/.devkit/dependencies/libpng/install}"
dependency_root="$PWD/.devkit/dependencies/libpng"
mkdir -p "$dependency_root"
archive_path="$dependency_root/libpng-1.6.59.tar.xz"
source_path="$dependency_root/libpng-1.6.59"
if [[ ! -f "$archive_path" ]]; then
    curl --fail --location --silent --show-error 'https://downloads.sourceforge.net/project/libpng/libpng16/1.6.59/libpng-1.6.59.tar.xz' --output "$archive_path"
fi
printf '%s  %s\n' 'd80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389' "$archive_path" | shasum -a 256 --check
if [[ ! -d "$source_path" ]]; then tar -xJf "$archive_path" -C "$dependency_root"; fi
cd "$source_path"
MACOSX_DEPLOYMENT_TARGET=15.0 CFLAGS='-O2 -mmacosx-version-min=15.0' ./configure --prefix="$dependency_prefix" --disable-shared --enable-static
make -j2
make install
