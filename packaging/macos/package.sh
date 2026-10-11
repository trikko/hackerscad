#!/bin/sh
# Builds dist/hackerscad-<version>-macos-<arch>.zip with hackerscad.app,
# from Homebrew's libraries: dylibbundler copies the libraries the
# executables and GTK need into the bundle, and the launcher points gid and
# GTK at them.
set -e
root="$(cd "$(dirname "$0")/../.." && pwd)"
brew="$(brew --prefix)"
version="${VERSION:-$(sed -n 's/.*appVersion = "\(.*\)";/\1/p' "$root/source/hackerscad/about.d")}"
arch="$(uname -m)"
cd "$root"
dub build -b release --compiler=ldc2
dub build -b release --compiler=ldc2 :gui

app="$root/dist/hackerscad.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" "$app/Contents/Frameworks" \
    "$app/Contents/Resources/share/hackerscad"
cp bin/hscad bin/hscad-gui "$app/Contents/Resources/bin/"

# GTK is opened at run time: bundle it together with the executables
for lib in libgtk-4.1.dylib libadwaita-1.0.dylib libgtksourceview-5.0.dylib; do
    cp "$brew/lib/$lib" "$app/Contents/Frameworks/"
done
dylibbundler -of -cd -b -p @executable_path/../../Frameworks/ -d "$app/Contents/Frameworks/" \
    -x "$app/Contents/Resources/bin/hscad" -x "$app/Contents/Resources/bin/hscad-gui" \
    -x "$app/Contents/Frameworks/libgtk-4.1.dylib" -x "$app/Contents/Frameworks/libadwaita-1.0.dylib" \
    -x "$app/Contents/Frameworks/libgtksourceview-5.0.dylib"

# GTK runtime data
share="$app/Contents/Resources/share"
mkdir -p "$share/glib-2.0" "$share/icons"
cp -r "$brew/share/glib-2.0/schemas" "$share/glib-2.0/"
glib-compile-schemas "$share/glib-2.0/schemas"
cp -r "$brew/share/icons/Adwaita" "$brew/share/icons/hicolor" "$share/icons/"
cp -r "$brew/share/gtksourceview-5" "$share/"
cp -r data/icons data/language-specs examples docs LICENSE MODEL-EXCEPTION.md "$share/hackerscad/"

cp packaging/macos/Info.plist "$app/Contents/"
sed -i '' "s/@VERSION@/$version/" "$app/Contents/Info.plist"
cp packaging/macos/launcher.sh "$app/Contents/MacOS/hackerscad"
chmod +x "$app/Contents/MacOS/hackerscad"
rsvg-convert -w 1024 -h 1024 data/logo/it.andreafontana.hackerscad.gui.svg -o /tmp/hcad-icon.png
mkdir -p /tmp/hcad.iconset
for s in 16 32 128 256 512; do
    sips -z $s $s /tmp/hcad-icon.png --out /tmp/hcad.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s * 2)) $((s * 2)) /tmp/hcad-icon.png --out /tmp/hcad.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns /tmp/hcad.iconset -o "$app/Contents/Resources/hackerscad.icns"

# install_name_tool invalidated the signatures: sign again (ad hoc)
find "$app" -type f \( -name '*.dylib' -o -perm -u+x \) -exec codesign --force -s - {} \; 2>/dev/null || true
codesign --force -s - "$app"

cd "$root/dist"
rm -f "hackerscad-$version-macos-$arch.zip"
ditto -c -k --keepParent hackerscad.app "hackerscad-$version-macos-$arch.zip"
echo "dist/hackerscad-$version-macos-$arch.zip"
