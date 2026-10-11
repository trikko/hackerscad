#!/bin/sh
# Builds dist/hackerscad-<version>-x86_64.AppImage in the Ubuntu 24.04
# container (packaging/linux/Containerfile), so it runs on distributions with
# glibc 2.39 or newer. Needs podman (or docker: ENGINE=docker).
set -e
root="$(cd "$(dirname "$0")/../.." && pwd)"
engine="${ENGINE:-podman}"
image=hackerscad-appimage
# the CI builds the image beforehand, with a cache of its layers
[ -n "${SKIP_IMAGE_BUILD:-}" ] || "$engine" build -t "$image" -f "$root/packaging/linux/Containerfile" "$root/packaging/linux"
mkdir -p "$root/dist"
# DUB_CACHE: a directory kept between builds for dub's packages and objects
cache=""
[ -z "${DUB_CACHE:-}" ] || { mkdir -p "$DUB_CACHE"; cache="-v $DUB_CACHE:/root/.dub"; }
"$engine" run --rm -e VERSION -e KEEP_NATIVE $cache -v "$root:/src:ro" -v "$root/dist:/dist" "$image" \
    sh /src/packaging/linux/appimage-inside.sh
