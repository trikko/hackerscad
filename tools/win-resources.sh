#!/bin/sh
# The Windows resources of hackerscad.exe (the logo as its icon), into
# build/win/native/hackerscad.res. Called by dub before building for Windows.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/win/native"
mkdir -p "$out"
res="$out/hackerscad.res"
svg="$root/data/logo/it.andreafontana.hackerscad.gui.svg"
[ -f "$res" ] && ! [ "$svg" -nt "$res" ] && exit 0
case "$(uname -s)" in
MINGW*|MSYS*|CLANG*) windres=windres ;;
*) tc="$(ls -d "$root"/build/win/llvm-mingw-*/ | head -1)"; windres="$tc/bin/x86_64-w64-mingw32-windres" ;;
esac
for s in 16 24 32 48 64 128 256; do
    rsvg-convert -w $s -h $s "$svg" -o "$out/icon-$s.png"
done
# ImageMagick 7 is magick, 6 (Ubuntu) is convert
im="$(command -v magick || command -v convert)"
"$im" "$out"/icon-16.png "$out"/icon-24.png "$out"/icon-32.png "$out"/icon-48.png \
    "$out"/icon-64.png "$out"/icon-128.png "$out"/icon-256.png "$out/hackerscad.ico"
rm -f "$out"/icon-*.png
printf '1 ICON "hackerscad.ico"\n' > "$out/hackerscad.rc"
(cd "$out" && "$windres" -O res -i hackerscad.rc -o hackerscad.res)
