#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/verify-landing.py
project=evb-shot
scope=eugenes-projects-23020cc6
vercel project inspect "$project" --scope "$scope"
stage=$(mktemp -d "${TMPDIR:-$PWD/.devkit}/evb-shot-landing.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp landing/index.html landing/style.css landing/icon.svg landing/editor.png landing/robots.txt landing/sitemap.xml landing/vercel.json "$stage/"
cp -R landing/fonts "$stage/fonts"
mkdir -p "$stage/.vercel"
cp landing/.vercel/project.json "$stage/.vercel/project.json"
export GIT_CEILING_DIRECTORIES="$stage"
vercel deploy --cwd "$stage" --project "$project" --scope "$scope" --prod --yes
