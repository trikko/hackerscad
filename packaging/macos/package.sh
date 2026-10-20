#!/bin/sh
# Builds dist/hackerscad-<version>-macos-<arch>.zip with hackerscad.app,
# from Homebrew's libraries: dylibbundler copies the libraries the
# executables and GTK need into the bundle, and the launcher points gid and
# GTK at them. Needs the Homebrew formulae installed by the CI (see
# .github/workflows/build.yml), adwaita-icon-theme included.
set -e
root="$(cd "$(dirname "$0")/../.." && pwd)"
brew="$(brew --prefix)"
version="${VERSION:-nightly}"
arch="$(uname -m)"
cd "$root"
dub build -b release --compiler=ldc2
dub build -b release --compiler=ldc2 :gui

app="$root/dist/hackerscad.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" "$app/Contents/Frameworks" \
    "$app/Contents/Resources/share/hackerscad"
cp bin/hcad bin/hackerscad "$app/Contents/Resources/bin/"

# gid opens GTK and the libraries below it at run time (they are not linked
# to the executables): bundle them, and what they need, with dylibbundler
fw="$app/Contents/Frameworks"
gidlibs="libgtk-4.1.dylib libadwaita-1.0.dylib libgtksourceview-5.0.dylib libgobject-2.0.0.dylib
    libglib-2.0.0.dylib libgio-2.0.0.dylib libgmodule-2.0.0.dylib libgraphene-1.0.0.dylib
    libpango-1.0.0.dylib libpangocairo-1.0.0.dylib libcairo.2.dylib libcairo-gobject.2.dylib
    libharfbuzz.0.dylib libharfbuzz-gobject.0.dylib libgdk_pixbuf-2.0.0.dylib"
for lib in $gidlibs; do
    cp "$brew/lib/$lib" "$fw/"
    chmod u+w "$fw/$lib"
done
dylibbundler -of -cd -b -p @executable_path/../../Frameworks/ -d "$fw/" \
    -x "$app/Contents/Resources/bin/hcad" -x "$app/Contents/Resources/bin/hackerscad" \
    $(for lib in $gidlibs; do printf -- '-x %s ' "$fw/$lib"; done)

# WORKAROUND (gid 0.9.13, library loading): gid looks the functions of a
# pair of libraries (gobject and glib,
# cairo-gobject and cairo, harfbuzz-gobject and harfbuzz) up in the first one
# only, and dlsym on macOS does not search its dependencies. The first one
# becomes a library re-exporting both; the real one is renamed. The other
# libraries load it under the old name and still find every symbol. When
# gid's version changes (the "known bugs" unittest in lang/tests.d fails),
# check whether it looks symbols up in every library; if so, this can go.
echo > /tmp/hcad-empty.c
reexport() {   # reexport FIRST SECOND
    real="${1%.dylib}.real.dylib"
    mv "$fw/$1" "$fw/$real"
    install_name_tool -id "@executable_path/../../Frameworks/$real" "$fw/$real"
    cc -dynamiclib /tmp/hcad-empty.c -o "$fw/$1" -install_name "@executable_path/../../Frameworks/$1" \
        -Wl,-reexport_library,"$fw/$real" -Wl,-reexport_library,"$fw/$2"
}
reexport libgobject-2.0.0.dylib libglib-2.0.0.dylib
reexport libcairo-gobject.2.dylib libcairo.2.dylib
reexport libharfbuzz-gobject.0.dylib libharfbuzz.0.dylib

# GTK runtime data
share="$app/Contents/Resources/share"
mkdir -p "$share/glib-2.0" "$share/icons"
cp -r "$brew/share/glib-2.0/schemas" "$share/glib-2.0/"
glib-compile-schemas "$share/glib-2.0/schemas"
cp -r "$brew/share/icons/Adwaita" "$brew/share/icons/hicolor" "$share/icons/"
cp -r "$brew/share/gtksourceview-5" "$share/"
# fontconfig's configuration (the launcher points Pango at it): -L copies the
# files conf.d links to, which live elsewhere in Homebrew
mkdir -p "$app/Contents/Resources/etc"
cp -RL "$brew/etc/fonts" "$app/Contents/Resources/etc/"
fonts="$app/Contents/Resources/etc/fonts"
# conf.d from the bundle, not from Homebrew's prefix; and the Mac's own fonts
sed -i '' "s|<include ignore_missing=\"yes\">$brew/etc/fonts/conf.d</include>|<include ignore_missing=\"yes\" prefix=\"relative\">conf.d</include>|" "$fonts/fonts.conf"
cp packaging/macos/fonts-macos.conf "$fonts/conf.d/45-hackerscad-macos.conf"
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
