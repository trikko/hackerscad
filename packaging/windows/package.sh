#!/bin/sh
# Builds dist/hackerscad-<version>-windows-x86_64.zip: the executables, the
# native DLL, every DLL they need and the GTK data (schemas, icons, pixbuf
# loaders, GtkSourceView styles, fontconfig). Runs in an MSYS2 CLANG64 shell,
# or on Linux after tools/setup-win-cross.sh (then it can be tried with
# Wine: wine dist/hackerscad/bin/hackerscad.exe).
set -e
root="$(cd "$(dirname "$0")/../.." && pwd)"
version="${VERSION:-nightly}"
cd "$root"

case "$(uname -s)" in
MINGW*|MSYS*|CLANG*)
    sys="${MINGW_PREFIX:-/clang64}"
    readobj=llvm-readobj
    ldcbin=ldc2
    build() { dub build -b release --compiler=ldc2 "$@"; }
    ;;
*)
    sys="$root/build/win/msys/clang64"
    tc="$(ls -d "$root"/build/win/llvm-mingw-*/ | head -1)"
    readobj="${tc}bin/llvm-readobj"
    ldc="$(ls -d "$root"/build/win/ldc2-*-linux-x86_64/ | head -1)bin/ldc2"
    ldcbin="$ldc"
    build() { dub build -b release --compiler="$ldc" --arch=x86_64-windows-msvc "$@"; }
    ;;
esac

build
build :gui

out="$root/dist/hackerscad"
rm -rf "$out"
mkdir -p "$out/bin" "$out/share/hackerscad" "$out/lib/gdk-pixbuf-2.0" "$out/etc"
cp bin/hcad.exe bin/hackerscad.exe build/win/native/hcad_native.dll "$out/bin/"
# Microsoft's C runtime of the D programs: a fresh Windows may lack it
case "$(uname -s)" in
MINGW*|MSYS*|CLANG*) cp "$(cygpath -u "$SYSTEMROOT")/System32/vcruntime140.dll" "$out/bin/" ;;
*) cp "$root/build/win/vcruntime/vcruntime140.dll" "$out/bin/" ;;
esac
# hackerscad.exe at the top: starts bin\hackerscad.exe, with the logo as its icon
"$ldcbin" -betterC -O -release -boundscheck=off -mtriple=x86_64-windows-msvc -of="$out/hackerscad.exe" -od=build/win/native \
    packaging/windows/launcher.d -L"$root/build/win/native/hackerscad.res" \
    -L/SUBSYSTEM:WINDOWS -L/ENTRY:start -L/NODEFAULTLIB -L kernel32.lib -L user32.lib

# GTK data
mkdir -p "$out/share/glib-2.0" "$out/share/icons"
cp -r "$sys/share/glib-2.0/schemas" "$out/share/glib-2.0/"
glib-compile-schemas "$out/share/glib-2.0/schemas"
cp -r "$sys/share/icons/Adwaita" "$sys/share/icons/hicolor" "$out/share/icons/"
cp -r "$sys/share/gtksourceview-5" "$out/share/"
cp -r "$sys/lib/gdk-pixbuf-2.0/2.10.0" "$out/lib/gdk-pixbuf-2.0/"
rm -f "$out"/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.dll.a
# fontconfig, which Pango lays text out with (see hcadFonts in gui/app.d),
# and Adwaita Sans and Mono, the fonts hackerscad has on Linux
cp -r "$sys/etc/fonts" "$out/etc/"
cp packaging/windows/fonts-windows.conf "$out/etc/fonts/conf.d/45-hackerscad-windows.conf"
adwaita=51.0
mkdir -p "$root/build/win/dl" "$out/share/fonts/adwaita"
[ -f "$root/build/win/dl/adwaita-fonts-$adwaita.tar.xz" ] || curl -fsSL -o "$root/build/win/dl/adwaita-fonts-$adwaita.tar.xz" \
    "https://download.gnome.org/sources/adwaita-fonts/${adwaita%.*}/adwaita-fonts-$adwaita.tar.xz"
tar -xJf "$root/build/win/dl/adwaita-fonts-$adwaita.tar.xz" -C "$out/share/fonts/adwaita" --strip-components=2 \
    --wildcards "adwaita-fonts-$adwaita/sans/*.ttf" "adwaita-fonts-$adwaita/mono/*.ttf"
tar -xJf "$root/build/win/dl/adwaita-fonts-$adwaita.tar.xz" -O "adwaita-fonts-$adwaita/LICENSE" > "$out/share/fonts/adwaita/LICENSE"
if ! [ -f "$out/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" ]; then
    echo "missing loaders.cache: run gdk-pixbuf-query-loaders --update-cache" >&2
    exit 1
fi

# the libraries gid opens at run time (not imported by the executables): GTK
# and the others, and every library of a pair gid opens both of
gidlibs="libgtk-4-1.dll libadwaita-1-0.dll libgtksourceview-5-0.dll libgobject-2.0-0.dll libglib-2.0-0.dll
    libcairo-gobject-2.dll libcairo-2.dll libharfbuzz-gobject-0.dll libharfbuzz-0.dll"
# every DLL the executables, those libraries and the pixbuf loaders import,
# followed recursively; system DLLs are not in $sys/bin
seeds="$out/bin/hcad.exe $out/bin/hackerscad.exe $out/bin/hcad_native.dll
    $(for dll in $gidlibs; do printf '%s ' "$sys/bin/$dll"; done)
    $(ls "$out"/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.dll)"
# OpenCascade's DLLs from our build (packaging/windows/build-occt.sh) when there is one, else MSYS2's
occtbin="$root/build/win/occt/bin"
dllfrom() { if [ -f "$occtbin/$1" ]; then echo "$occtbin/$1"; elif [ -f "$sys/bin/$1" ]; then echo "$sys/bin/$1"; fi; }
todo="$seeds"
while [ -n "$todo" ]; do
    next=""
    for f in $todo; do
        for dll in $("$readobj" --coff-imports "$f" | sed -n 's/^ *Name: \(.*\.dll\)$/\1/p' | sort -u); do
            # never Mesa's opengl32.dll next to the program: it would replace
            # the graphics card's OpenGL for everyone
            case "$dll" in [Oo][Pp][Ee][Nn][Gg][Ll]32.[Dd][Ll][Ll]) continue ;; esac
            from="$(dllfrom "$dll")"
            if [ -n "$from" ] && ! [ -f "$out/bin/$dll" ]; then
                cp "$from" "$out/bin/"
                next="$next $out/bin/$dll"
            fi
        done
    done
    todo="$next"
done
for dll in $gidlibs; do
    [ -f "$out/bin/$dll" ] || cp "$sys/bin/$dll" "$out/bin/"
done

# Mesa's software OpenGL, for machines whose OpenGL is too old for GTK (see
# hcadSoftwareGl in gui/app.d), in a zip of its own (few need it, it weighs
# 180 MB): unzipped into the same folder, it lands in bin\mesa with what only
# it needs, never next to the program, where it would replace the graphics
# card's OpenGL. Its name has no version, so that the program's help can name it;
# it is made again with each package, from the same MSYS2 whose DLLs it shares
mesa="$root/dist/mesa/hackerscad/bin/mesa"
rm -rf "$root/dist/mesa"
mkdir -p "$mesa"
cp "$sys/bin/opengl32.dll" "$sys/bin/libgallium_wgl.dll" "$mesa/"
todo="$mesa/opengl32.dll $mesa/libgallium_wgl.dll"
while [ -n "$todo" ]; do
    next=""
    for f in $todo; do
        for dll in $("$readobj" --coff-imports "$f" | sed -n 's/^ *Name: \(.*\.dll\)$/\1/p' | sort -u); do
            if [ -f "$sys/bin/$dll" ] && ! [ -f "$out/bin/$dll" ] && ! [ -f "$mesa/$dll" ]; then
                cp "$sys/bin/$dll" "$mesa/"
                next="$next $mesa/$dll"
            fi
        done
    done
    todo="$next"
done

# hackerscad's own data, examples and documentation
cp -r data/icons data/language-specs "$out/share/hackerscad/"
cp -r examples docs "$out/share/hackerscad/"
cp LICENSE MODEL-EXCEPTION.md "$out/"

pack() {   # pack ZIP DIR: the hackerscad folder inside DIR
    rm -f "$root/dist/$1"
    if command -v zip >/dev/null; then
        (cd "$2" && zip -qr "$root/dist/$1" hackerscad)
    else
        (cd "$2" && bsdtar -a -cf "$root/dist/$1" hackerscad)
    fi
    echo "dist/$1"
}
pack "hackerscad-$version-windows-x86_64.zip" "$root/dist"
pack "hackerscad-windows-mesa.zip" "$root/dist/mesa"
