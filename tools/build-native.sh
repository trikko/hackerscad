#!/bin/sh
# Builds the native kernel (the OpenCascade shim) into build/native. Called
# by dub as a preBuildCommand; skipped when already up to date.
set -e

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/native"
tag='Signature: 8a477f597d28d172789f06886806bc55\n# hackerscad build output\n'

mkdir -p "$out"
[ -f "$root/build/CACHEDIR.TAG" ] || printf "$tag" > "$root/build/CACHEDIR.TAG"

target="${1:-native}"

# The content of a step's inputs: a step runs again when it changes, not when
# a file is newer (files restored from a CI cache are older than a checkout).
stamp() { cat "$@" | cksum | cut -d' ' -f1; }

if [ "$target" = windows ]; then
    # Windows: hcad_native.dll instead of static libraries
    sh "$root/tools/build-native-win.sh"
else
# --- OpenCascade shim -------------------------------------------------------
src="$root/source/hackerscad/kernel/occt"
lib="$out/libhcad_occt.a"
# OpenCascade headers: $OCCT_INCLUDE, or ours (packaging/macos/build-occt.sh), or
# where Linux distributions, Homebrew and MSYS2 put them
occt_inc="${OCCT_INCLUDE:-}"
if [ -z "$occt_inc" ]; then
    for d in "$root/build/occt/include/opencascade" /usr/include/opencascade /usr/local/include/opencascade \
             /opt/homebrew/include/opencascade \
             "${MINGW_PREFIX:-/ucrt64}/include/opencascade"; do
        if [ -f "$d/Standard.hxx" ]; then occt_inc="$d"; break; fi
    done
fi
# no fused multiply-adds (clang makes them on Apple Silicon, and on ARM by default): they round otherwise
# than x86, and on macOS a knurl's direct build came out broken, falling back on a boolean twenty times slower
flags="-std=c++17 -O2 -ffp-contract=off -fPIC"
sum="$( (cat "$src/shim.cpp" "$src/shim.h"; echo "$flags") | cksum | cut -d' ' -f1)"
if ! [ -f "$lib" ] || [ "$(cat "$lib.stamp" 2>/dev/null)" != "$sum" ]; then
    ${CXX:-g++} $flags -I"$occt_inc" -c "$src/shim.cpp" -o "$out/shim.o"
    rm -f "$lib"
    ar rcs "$lib" "$out/shim.o"
    echo "$sum" > "$lib.stamp"
fi

fi
