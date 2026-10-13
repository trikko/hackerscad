#!/bin/sh
# Runs inside the AppImage container: builds a clean copy of /src and packs
# it with linuxdeploy (and its GTK plugin) into /dist.
set -e
version="${VERSION:-$(sed -n 's/.*appVersion = "\(.*\)";/\1/p' /src/source/hackerscad/about.d)}"

# a clean copy: the host's build/ holds objects for another system (the CI
# builds them in this same image: KEEP_NATIVE=1 keeps the shim)
mkdir -p /work
cd /src
tar --exclude=./build --exclude=./bin --exclude=./dist --exclude=./.dub -cf - . | tar -xf - -C /work
if [ -n "${KEEP_NATIVE:-}" ] && [ -d build/native ]; then
    mkdir -p /work/build
    cp -a build/native /work/build/
fi
cd /work
dub build -b release --compiler=ldc2
dub build -b release --compiler=ldc2 :gui

app=/work/AppDir
mkdir -p "$app/usr/bin" "$app/usr/share/hackerscad" "$app/usr/share/applications" \
    "$app/usr/share/icons/hicolor/scalable/apps" "$app/usr/share/mime/packages" "$app/apprun-hooks"
cp bin/hcad bin/hackerscad "$app/usr/bin/"
cp -r data/icons data/language-specs "$app/usr/share/hackerscad/"
cp -r examples docs LICENSE MODEL-EXCEPTION.md "$app/usr/share/hackerscad/"
cp packaging/linux/it.andreafontana.hackerscad.gui.desktop "$app/usr/share/applications/"
cp packaging/linux/hcad-mime.xml "$app/usr/share/mime/packages/hackerscad.xml"
cp data/logo/it.andreafontana.hackerscad.gui.svg "$app/usr/share/icons/hicolor/scalable/apps/"
# GtkSourceView's own languages and styles (hcad.lang builds on def.lang)
cp -r /usr/share/gtksourceview-5 "$app/usr/share/"
# the icons GTK draws its buttons with (symbolic, SVG)
mkdir -p "$app/usr/share/icons"
cp -r /usr/share/icons/Adwaita "$app/usr/share/icons/"
# gid opens GTK with dlopen: name the libraries, linuxdeploy follows their dependencies
export DEPLOY_GTK_VERSION=4
lib=/usr/lib/x86_64-linux-gnu
linuxdeploy --appdir "$app" \
    --executable "$app/usr/bin/hackerscad" --executable "$app/usr/bin/hcad" \
    --library $lib/libgtk-4.so.1 --library $lib/libadwaita-1.so.0 --library $lib/libgtksourceview-5.so.0 \
    --desktop-file "$app/usr/share/applications/it.andreafontana.hackerscad.gui.desktop" \
    --icon-file "$app/usr/share/icons/hicolor/scalable/apps/it.andreafontana.hackerscad.gui.svg" \
    --plugin gtk
# our hook after the GTK plugin's, and our AppRun: it also starts the command line tool
cp packaging/linux/apprun-hook.sh "$app/apprun-hooks/zz-hackerscad.sh"
cp packaging/linux/AppRun "$app/AppRun"
ARCH=x86_64 appimagetool "$app" "/dist/hackerscad-$version-x86_64.AppImage"
