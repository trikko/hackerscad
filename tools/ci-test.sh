#!/bin/sh
# Runs the tests as the Linux CI does, before a push: in the CI's container
# (Ubuntu 24.04, OpenCascade built from source, ldc2), on a copy of the
# working tree with its uncommitted changes. The container's OpenCascade is
# another build than the system's, and a result near a tolerance can come
# out otherwise there: what passes here may fail there.
# Usage: tools/ci-test.sh [--fast]   (--fast: HCAD_TESTS=fast, no examples)
# Needs podman (or docker: ENGINE=docker). The image is the CI's, from GHCR
# under the hash of packaging/linux/Containerfile, else built here once (most
# of an hour). The copy, its objects and dub's packages stay in
# ~/.cache/hackerscad-ci, so later runs build only what changed. IMAGE= runs
# another image (an older one already here).
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
engine="${ENGINE:-podman}"
fast=""
[ "${1:-}" = --fast ] && fast=1
image="${IMAGE:-ghcr.io/trikko/hackerscad-env:$(sha256sum "$root/packaging/linux/Containerfile" | cut -c1-16)}"
if [ -z "$("$engine" images -q "$image" 2>/dev/null)" ]; then
    "$engine" pull -q "$image" || "$engine" build -t "$image" -f "$root/packaging/linux/Containerfile" "$root/packaging/linux"
fi
cache="${XDG_CACHE_HOME:-$HOME/.cache}/hackerscad-ci"
mkdir -p "$cache/src" "$cache/dub"
# the working tree as it is, without what is built here (objects for this
# system) or kept aside; the copy's own build/ stays, for the next run
rsync -a --delete --exclude=/build --exclude=/bin --exclude=/dist --exclude=/.dub --exclude=/.claude \
    "$root/" "$cache/src/"
"$engine" run --rm -e HCAD_TESTS="${fast:+fast}" -v "$cache/src:/src" -v "$cache/dub:/root/.dub" -w /src "$image" sh -c '
    git config --global --add safe.directory "*"
    dub test :core --compiler=ldc2 || exit 1
    [ -n "$HCAD_TESTS" ] && exit 0
    dub build --compiler=ldc2 || exit 1
    for f in examples/*.hcad; do bin/hcad check "$f" > /dev/null || { echo "examples: $f fails"; exit 1; }; done
    echo "examples: all pass"'
