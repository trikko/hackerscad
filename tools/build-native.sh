#!/bin/sh
# Builds the native kernels into build/native and build/manifold. Called by
# dub as a preBuildCommand; each step is skipped when already up to date.
set -e

MANIFOLD_REF=v3.5.4     # pinned Manifold release; bump deliberately

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/native"
tag='Signature: 8a477f597d28d172789f06886806bc55\n# hackerscad build output\n'

mkdir -p "$out"
[ -f "$root/build/CACHEDIR.TAG" ] || printf "$tag" > "$root/build/CACHEDIR.TAG"

target="${1:-native}"

# --- Manifold sources (pinned) ------------------------------------------------
msrc="$root/third_party/manifold"
if ! [ -d "$msrc" ]; then
    git clone --depth 1 --branch "$MANIFOLD_REF" https://github.com/elalish/manifold.git "$msrc"
fi
have="$(git -C "$msrc" describe --tags --exact-match 2>/dev/null || echo unknown)"
if [ "$have" != "$MANIFOLD_REF" ]; then
    echo "warning: third_party/manifold is at $have, expected $MANIFOLD_REF" >&2
fi

if [ "$target" = windows ]; then
    # Windows: hcad_native.dll instead of static libraries
    sh "$root/tools/build-native-win.sh"
else
# --- OpenCascade shim -------------------------------------------------------
src="$root/source/hackerscad/kernel/occt"
lib="$out/libhcad_occt.a"
# OpenCascade headers: $OCCT_INCLUDE, or where Linux distributions, Homebrew
# and MSYS2 put them
occt_inc="${OCCT_INCLUDE:-}"
if [ -z "$occt_inc" ]; then
    for d in /usr/include/opencascade /usr/local/include/opencascade /opt/homebrew/include/opencascade \
             "${MINGW_PREFIX:-/ucrt64}/include/opencascade"; do
        if [ -f "$d/Standard.hxx" ]; then occt_inc="$d"; break; fi
    done
fi
if ! [ -f "$lib" ] || [ "$src/shim.cpp" -nt "$lib" ] || [ "$src/shim.h" -nt "$lib" ]; then
    ${CXX:-g++} -std=c++17 -O2 -fPIC -I"$occt_inc" -c "$src/shim.cpp" -o "$out/shim.o"
    ar rcs "$lib" "$out/shim.o"
fi

# --- Manifold ---------------------------------------------------------------
mbuild="$root/build/manifold"
if ! [ -f "$mbuild/bindings/c/libmanifoldc.a" ]; then
    cmake -S "$msrc" -B "$mbuild" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DMANIFOLD_TEST=OFF -DMANIFOLD_PAR=ON -DMANIFOLD_CBIND=ON -DMANIFOLD_USE_BUILTIN_CLIPPER2=ON \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    ninja -C "$mbuild"
fi
fi

# D declarations generated from manifoldc.h with ImportC, so they always
# match the pinned header.
di="$out/import/hackerscad/kernel/manifold/c.di"
header="$msrc/bindings/c/include/manifold/manifoldc.h"
if ! [ -f "$di" ] || [ "$header" -nt "$di" ]; then
    dmd="$(command -v dmd || command -v ldmd2)"
    mkdir -p "$(dirname "$di")" "$out/cstub"
    # minimal libc headers: the real ones drag in macros D cannot express
    # (long long: on Windows long is 32 bits)
    printf '#pragma once\ntypedef unsigned long long size_t;\n' > "$out/cstub/stddef.h"
    printf '#pragma once\ntypedef int int32_t;\ntypedef unsigned int uint32_t;\ntypedef long long int64_t;\ntypedef unsigned long long uint64_t;\ntypedef unsigned char uint8_t;\n' > "$out/cstub/stdint.h"
    printf '#include <manifold/manifoldc.h>\n' > "$out/manifoldc.c"
    "$dmd" -c -o- -P-nostdinc -P-I"$out/cstub" -P-I"$msrc/bindings/c/include" "$out/manifoldc.c" -Hf="$out/manifoldc.di"
    # the .di generator drops opaque struct typedefs: declare them again
    opaque="$(sed -nE 's/^typedef struct (\w+) \1;$/extern (C) struct \1;/p' "$msrc/bindings/c/include/manifold/types.h")"
    { echo "module hackerscad.kernel.manifold.c;"; echo "$opaque"; cat "$out/manifoldc.di"; } > "$di"
fi
