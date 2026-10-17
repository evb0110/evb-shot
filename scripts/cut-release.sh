#!/bin/bash
# Cut the next patch by default. The existing tag pipeline checks, packages,
# signs the update feed, verifies uploaded bytes, and only then publishes.
set -euo pipefail
cd "$(dirname "$0")/.."
level="${1:-patch}"
[[ "$level" == patch || "$level" == minor || "$level" == major ]] || { printf 'Expected patch, minor, or major\n' >&2; exit 1; }
[[ "$(git branch --show-current)" == main && -z "$(git status --porcelain)" ]] || { printf 'Release from a clean main checkout.\n' >&2; exit 1; }
git fetch origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { printf 'Update main before cutting a release.\n' >&2; exit 1; }
next=$(python3 scripts/bump-version.py "$level" --dry-run)
if git show-ref --verify --quiet "refs/tags/v$next"; then
    printf 'Version tag v%s already exists; leave history unchanged.\n' "$next" >&2; exit 1
fi
ci-wait "$(git rev-parse HEAD)"
version=$(python3 scripts/bump-version.py "$level")
git add Resources/Info.plist
git commit -m "Release EVB Shot $version"
git-publish --branch main
ci-wait "$(git rev-parse HEAD)"
git tag -a "v$version" -m "EVB Shot $version"
git push origin "refs/tags/v$version"
printf 'Release pipeline started: https://github.com/evb0110/evb-shot/actions/workflows/release.yml\n'
ci-wait -w Release "$(git rev-parse HEAD)"
gh release view "v$version" --json url,isDraft,publishedAt
