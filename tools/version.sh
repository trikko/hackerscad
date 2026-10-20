#!/bin/sh
# Writes the version the program shows (hcad --version, the About window) in
# build/gen/version.txt: a release's number when the commit built is tagged
# vX.Y.Z (or $VERSION, as the packaging scripts give it), else the commit and
# its date, 1d217d1-2026-10-20; empty without git, and the program shows
# appVersion. The file is rewritten only when it changes, so that it does not
# rebuild the program each time. Run by dub before a build.
set -e
cd "$(dirname "$0")/.."
mkdir -p build/gen
git() { command git -c safe.directory='*' "$@" 2>/dev/null; }
version="$VERSION"
if [ -z "$version" ]; then
    tag="$(git describe --tags --exact-match --match 'v[0-9]*' HEAD || true)"
    if [ -n "$tag" ]; then
        version="${tag#v}"
    else
        version="$(git show -s --format='%h-%cs' HEAD || true)"
    fi
fi
printf '%s' "$version" > build/gen/version.txt.new
if cmp -s build/gen/version.txt.new build/gen/version.txt; then
    rm build/gen/version.txt.new
else
    mv build/gen/version.txt.new build/gen/version.txt
fi
