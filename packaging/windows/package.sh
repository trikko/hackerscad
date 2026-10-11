#!/bin/sh
# Builds dist/hackerscad-<version>-windows-x86_64.zip: the executables, the
# native DLL, every DLL they need and the GTK data (schemas, icons, pixbuf
# loaders, GtkSourceView styles, fontconfig). Runs in an MSYS2 CLANG64 shell,
# or on Linux after tools/setup-win-cross.sh (then it can be tried with
# Wine: wine dist/hackerscad/bin/hscad-gui.exe).
set -e
root="$(cd "$(dirname "$0")/../.." && pwd)"
version="${VERSION:-$(sed -n 's/.*appVersion = "\(.*\)";/\1/p' "$root/source/hackerscad/about.d")}"
cd "$root"

case "$(uname -s)" in
MINGW*|MSYS*|CLANG*)
    sys="${MINGW_PREFIX:-/clang64}"
    readobj=llvm-readobj
    build() { dub build -b release --compiler=ldc2 "$@"; }
    ;;
*)
    sys="$root/build/win/msys/clang64"
    readobj="$(ls -d "$root"/build/win/llvm-mingw-*/ | head -1)bin/llvm-readobj"
    ldc="$(ls -d "$root"/build/win/ldc2-*-linux-x86_64/ | head -1)bin/ldc2"
    build() { dub build -b release --compiler="$ldc" --arch=x86_64-windows-msvc "$@"; }
    ;;
esac

build
build :gui

out="$root/dist/hackerscad"
rm -rf "$out"
mkdir -p "$out/bin" "$out/share/hackerscad" "$out/lib/gdk-pixbuf-2.0" "$out/etc"
cp bin/hscad.exe bin/hscad-gui.exe build/win/native/hcad_native.dll "$out/bin/"
sh tools/win-forwarders.sh "$sys/bin" "$out/bin"

# GTK data
mkdir -p "$out/share/glib-2.0" "$out/share/icons"
cp -r "$sys/share/glib-2.0/schemas" "$out/share/glib-2.0/"
glib-compile-schemas "$out/share/glib-2.0/schemas"
cp -r "$sys/share/icons/Adwaita" "$sys/share/icons/hicolor" "$out/share/icons/"
cp -r "$sys/share/gtksourceview-5" "$out/share/"
cp -r "$sys/lib/gdk-pixbuf-2.0/2.10.0" "$out/lib/gdk-pixbuf-2.0/"
rm -f "$out"/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.dll.a
# fontconfig: Pango uses it under Wine (on Windows it uses DirectWrite)
cp -r "$sys/etc/fonts" "$out/etc/"
if ! [ -f "$out/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" ]; then
    echo "missing loaders.cache: run gdk-pixbuf-query-loaders --update-cache" >&2
    exit 1
fi

# every DLL the executables, GTK (opened at run time) and the pixbuf loaders
# import, followed recursively; system DLLs are not in $sys/bin
seeds="$out/bin/hscad.exe $out/bin/hscad-gui.exe $out/bin/hcad_native.dll $out/bin/gobject-2.0-0.dll
    $out/bin/cairo-gobject-2.dll $out/bin/harfbuzz-gobject-0.dll
    $sys/bin/libgtk-4-1.dll $sys/bin/libadwaita-1-0.dll $sys/bin/libgtksourceview-5-0.dll
    $(ls "$out"/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.dll)"
todo="$seeds"
while [ -n "$todo" ]; do
    next=""
    for f in $todo; do
        for dll in $("$readobj" --coff-imports "$f" | sed -n 's/^ *Name: \(.*\.dll\)$/\1/p' | sort -u); do
            if [ -f "$sys/bin/$dll" ] && ! [ -f "$out/bin/$dll" ]; then
                cp "$sys/bin/$dll" "$out/bin/"
                next="$next $out/bin/$dll"
            fi
        done
    done
    todo="$next"
done
for dll in libgtk-4-1.dll libadwaita-1-0.dll libgtksourceview-5-0.dll; do
    [ -f "$out/bin/$dll" ] || cp "$sys/bin/$dll" "$out/bin/"
done

# hackerscad's own data, examples and documentation
cp -r data/icons data/language-specs "$out/share/hackerscad/"
cp -r examples docs "$out/share/hackerscad/"

cd "$root/dist"
rm -f "hackerscad-$version-windows-x86_64.zip"
if command -v zip >/dev/null; then
    zip -qr "hackerscad-$version-windows-x86_64.zip" hackerscad
else
    bsdtar -a -cf "hackerscad-$version-windows-x86_64.zip" hackerscad
fi
echo "dist/hackerscad-$version-windows-x86_64.zip"
