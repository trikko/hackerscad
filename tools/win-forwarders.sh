#!/bin/sh
# gid (0.9.13) loads only the first library of a pair such as
# ["gobject-2.0_0", "glib-2.0_0"] and looks every symbol up in it: on Linux
# dlsym also searches its dependencies, on Windows GetProcAddress does not,
# so the glib, cairo and harfbuzz functions stay unresolved. gid tries the
# name without "lib" first: a forwarding DLL with that name exports the
# symbols of both libraries and forwards them to the real DLLs.
# Usage: win-forwarders.sh BIN_DIR OUT_DIR  (BIN_DIR holds the real DLLs)
set -e
bin="$1"; out="$2"
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)" in
MINGW*|MSYS*|CLANG*) cc=clang; readobj=llvm-readobj ;;
*) tc="$(ls -d "$root"/build/win/llvm-mingw-*/ | head -1)"
   cc="$tc/bin/x86_64-w64-mingw32-clang"; readobj="$tc/bin/llvm-readobj" ;;
esac
mkdir -p "$out"
forward() {   # forward NAME DLL...
    name="$1"; shift
    def="$out/$name.def"
    echo "LIBRARY $name.dll" > "$def"
    echo "EXPORTS" >> "$def"
    for dll in "$@"; do
        "$readobj" --coff-exports "$bin/$dll" | sed -n 's/^ *Name: //p' | grep -v '^$' |
            while read -r sym; do echo "    $sym = $dll.$sym"; done
    done | sort -u -t= -k1,1 >> "$def"
    echo 'int __stdcall DllMain(void *h, unsigned r, void *p) { return 1; }' > "$out/empty.c"
    "$cc" -shared -nostdlib -o "$out/$name.dll" "$out/empty.c" "$def" -Wl,--entry,DllMain
}
forward gobject-2.0-0 libgobject-2.0-0.dll libglib-2.0-0.dll
forward cairo-gobject-2 libcairo-gobject-2.dll libcairo-2.dll
forward harfbuzz-gobject-0 libharfbuzz-gobject-0.dll libharfbuzz-0.dll
rm -f "$out"/*.def "$out/empty.c"
