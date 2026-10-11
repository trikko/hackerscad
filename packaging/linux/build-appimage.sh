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
"$engine" run --rm -e VERSION -v "$root:/src:ro" -v "$root/dist:/dist" "$image" sh /src/packaging/linux/appimage-inside.sh
