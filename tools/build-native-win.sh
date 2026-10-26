#!/bin/sh
# Cross-builds the native kernels for Windows (x86_64, UCRT) on Linux, into
# build/win/native: hcad_native.dll holds the OpenCascade shim behind its C
# interface, so the D code (LDC, windows-msvc) links to it
# with no C++ ABI in between. Needs the toolchain and the MSYS2 CLANG64
# libraries that tools/setup-win-cross.sh puts in build/win; in an MSYS2
# CLANG64 shell it uses the system's compiler and libraries instead.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
win="$root/build/win"
out="$win/native"
case "$(uname -s)" in
MINGW*|MSYS*|CLANG*)
    # natively, in an MSYS2 CLANG64 shell
    sys="${MINGW_PREFIX:-/clang64}"
    cc=clang; cxx=clang++; rc=windres; cross=""
    ;;
*)
    # from Linux: llvm-mingw and the MSYS2 packages unpacked in build/win
    tc="$(ls -d "$win"/llvm-mingw-*/ | head -1)"
    sys="$win/msys/clang64"
    cc="$tc/bin/x86_64-w64-mingw32-clang"; cxx="$tc/bin/x86_64-w64-mingw32-clang++"
    rc="$tc/bin/x86_64-w64-mingw32-windres"; cross="-DCMAKE_SYSTEM_NAME=Windows"
    ;;
esac
mkdir -p "$out"
# OpenCascade: ours (packaging/windows/build-occt.sh) when built, else MSYS2's
occt_inc="$sys/include/opencascade" occt_lib="$sys/lib"
if [ -f "$win/occt/include/opencascade/Standard.hxx" ]; then
    occt_inc="$win/occt/include/opencascade" occt_lib="$win/occt/lib"
fi

# --- the DLL ---------------------------------------------------------------
src="$root/source/hackerscad/kernel/occt"
dll="$out/hcad_native.dll"
# rebuilt when the shim's content, its options or the OpenCascade it builds on change (see build-native.sh)
flags="-std=c++17 -O2 -ffp-contract=off -D_USE_MATH_DEFINES"
sum="$( (cat "$src/shim.cpp" "$src/shim.h"; echo "$flags $occt_inc") | cksum | cut -d' ' -f1)"
if ! [ -f "$dll" ] || [ "$(cat "$dll.stamp" 2>/dev/null)" != "$sum" ]; then
    "$cxx" $flags -I"$occt_inc" -c "$src/shim.cpp" -o "$out/shim.o"
    occt="TKernel TKMath TKG2d TKG3d TKGeomBase TKGeomAlgo TKBRep TKTopAlgo TKPrim TKBO TKBool TKFillet \
        TKOffset TKFeat TKShHealing TKMesh TKV3d TKService TKXSBase TKDE TKDESTEP TKHLR"
    "$cxx" -shared -o "$dll" "$out/shim.o" \
        -L"$occt_lib" $(for l in $occt; do printf -- '-l%s ' "$l"; done) \
        -Wl,--export-all-symbols -Wl,--out-implib,"$out/hcad_native.lib"
    echo "$sum" > "$dll.stamp"
fi
