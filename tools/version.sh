#!/bin/sh
# Writes the version the program shows (hcad --version, the About window) in
# build/gen/version.txt: a release's number when the commit built is tagged
# vX.Y.Z (or $VERSION, as the packaging scripts give it), else the commit and
# its date, 1d217d1-2026-10-20; "nightly" without git (a copy of the
# sources), as the packages of untagged commits are named. The file is
# rewritten only when it changes, so that it does not rebuild the program
# each time. Run by dub before a build.
# No set -e: the sh of macOS (bash 3.2) stops at a failing git inside a
# function even where || allows it, and git fails as expected (no tag).
cd "$(dirname "$0")/.." || exit 1
mkdir -p build/gen || exit 1
version="$VERSION"
if [ -z "$version" ]; then
    tag="$(git -c safe.directory='*' describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null)"
    if [ -n "$tag" ]; then
        version="${tag#v}"
    else
        version="$(git -c safe.directory='*' show -s --format='%h-%cs' HEAD 2>/dev/null)"
    fi
fi
[ -n "$version" ] || version=nightly
printf '%s' "$version" > build/gen/version.txt.new || exit 1
if cmp -s build/gen/version.txt.new build/gen/version.txt; then
    rm build/gen/version.txt.new
else
    mv build/gen/version.txt.new build/gen/version.txt
fi
exit 0
