#!/bin/bash
# Builds OpenCascade into build/occt for macOS, instead of Homebrew's: a
# version of our choosing, and without fused multiply-adds. clang fuses
# a * b + c into one instruction on Apple Silicon (-ffp-contract=on), which
# rounds otherwise than x86 does, and OCCT 7.9.3's mesher then loops for
# ever on some faces (BRepMesh_Delaun::frontierAdjust, on a fillet's long
# cylinder beside a B-spline one). Only the modules hackerscad links.
# Usage: packaging/macos/build-occt.sh   (Homebrew's cmake and freetype)
set -e
cd "$(dirname "$0")/../.."
version=7.9.3
prefix="$PWD/build/occt"
work="$PWD/build/occt-src"
brew="$(brew --prefix)"
mkdir -p "$work"
[ -f "$work/OCCT-${version//./_}/CMakeLists.txt" ] || curl -fsSL \
    "https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V${version//./_}.tar.gz" | tar xz -C "$work"
cmake -S "$work/OCCT-${version//./_}" -B "$work/build" -DCMAKE_BUILD_TYPE=Release \
    -DINSTALL_DIR="$prefix" -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_C_FLAGS=-ffp-contract=off -DCMAKE_CXX_FLAGS=-ffp-contract=off \
    -DBUILD_RELEASE_DISABLE_EXCEPTIONS=OFF \
    -DBUILD_MODULE_ApplicationFramework=OFF -DBUILD_MODULE_Draw=OFF -DBUILD_MODULE_DETools=OFF \
    -DBUILD_DOC_Overview=OFF -DUSE_TK=OFF -DUSE_TBB=OFF -DUSE_VTK=OFF -DUSE_FREEIMAGE=OFF \
    -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF -DUSE_FREETYPE=ON -D3RDPARTY_FREETYPE_DIR="$brew/opt/freetype"
cmake --build "$work/build" --parallel "$(sysctl -n hw.ncpu)" --target install
rm -rf "$work"
