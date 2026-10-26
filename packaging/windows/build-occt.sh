#!/bin/bash
# Builds OpenCascade into build/win/occt for Windows, cross-compiled on Linux
# with llvm-mingw, instead of MSYS2's: the version macOS and Linux build, from
# the same sources and options. MSYS2's package carries a patch from Debian
# that, on 7.9.3, removes each boundary edge twice in BRepFill_Filling's
# WireFromList, so every fill() crashed on Windows. Only the modules
# hackerscad links; freetype is MSYS2's.
# Usage: packaging/windows/build-occt.sh   (after tools/setup-win-cross.sh;
# needs cmake and ninja)
set -e
cd "$(dirname "$0")/../.."
version=7.9.3
win="$PWD/build/win"
prefix="$win/occt"
work="$win/occt-src"
tc="$(ls -d "$win"/llvm-mingw-*/ | head -1)"
sys="$win/msys/clang64"
mkdir -p "$work"
[ -f "$work/OCCT-${version//./_}/CMakeLists.txt" ] || curl -fsSL \
    "https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V${version//./_}.tar.gz" | tar xz -C "$work"
cmake -S "$work/OCCT-${version//./_}" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="${tc}bin/x86_64-w64-mingw32-clang" -DCMAKE_CXX_COMPILER="${tc}bin/x86_64-w64-mingw32-clang++" \
    -DCMAKE_RC_COMPILER="${tc}bin/x86_64-w64-mingw32-windres" \
    -DCMAKE_FIND_ROOT_PATH="$sys" -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DINSTALL_DIR="$prefix" -DCMAKE_INSTALL_PREFIX="$prefix" -DINSTALL_DIR_LAYOUT=Unix \
    -DBUILD_LIBRARY_TYPE=Shared \
    -DCMAKE_C_FLAGS=-ffp-contract=off -DCMAKE_CXX_FLAGS=-ffp-contract=off \
    -DBUILD_RELEASE_DISABLE_EXCEPTIONS=OFF \
    -DBUILD_MODULE_ApplicationFramework=OFF -DBUILD_MODULE_Draw=OFF -DBUILD_MODULE_DETools=OFF \
    -DBUILD_DOC_Overview=OFF -DUSE_TK=OFF -DUSE_TBB=OFF -DUSE_VTK=OFF -DUSE_FREEIMAGE=OFF \
    -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_D3D=OFF \
    -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF -DUSE_FREETYPE=ON -D3RDPARTY_FREETYPE_DIR="$sys" \
    -D3RDPARTY_FREETYPE_INCLUDE_DIR_freetype2="$sys/include/freetype2" \
    -D3RDPARTY_FREETYPE_INCLUDE_DIR_ft2build="$sys/include/freetype2" \
    -D3RDPARTY_FREETYPE_LIBRARY="$sys/lib/libfreetype.dll.a" -D3RDPARTY_FREETYPE_LIBRARY_DIR="$sys/lib" \
    -D3RDPARTY_FREETYPE_DLL="$sys/bin/libfreetype-6.dll" -D3RDPARTY_FREETYPE_DLL_DIR="$sys/bin"
cmake --build "$work/build" --parallel "$(nproc)" --target install
rm -rf "$work"
