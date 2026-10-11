#!/bin/sh
# The Windows resources of hscad-gui.exe (the logo as its icon), into
# build/win/native/hscad-gui.res. Called by dub before building for Windows.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/win/native"
mkdir -p "$out"
res="$out/hscad-gui.res"
svg="$root/data/logo/it.andreafontana.hackerscad.gui.svg"
[ -f "$res" ] && ! [ "$svg" -nt "$res" ] && exit 0
case "$(uname -s)" in
MINGW*|MSYS*|CLANG*) windres=windres ;;
*) tc="$(ls -d "$root"/build/win/llvm-mingw-*/ | head -1)"; windres="$tc/bin/x86_64-w64-mingw32-windres" ;;
esac
for s in 16 24 32 48 64 128 256; do
    rsvg-convert -w $s -h $s "$svg" -o "$out/icon-$s.png"
done
magick "$out"/icon-16.png "$out"/icon-24.png "$out"/icon-32.png "$out"/icon-48.png \
    "$out"/icon-64.png "$out"/icon-128.png "$out"/icon-256.png "$out/hscad-gui.ico"
rm -f "$out"/icon-*.png
printf '1 ICON "hscad-gui.ico"\n' > "$out/hscad-gui.rc"
(cd "$out" && "$windres" -O res -i hscad-gui.rc -o hscad-gui.res)
