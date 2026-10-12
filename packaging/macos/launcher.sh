#!/bin/sh
# hackerscad.app/Contents/MacOS/hackerscad: GTK and gid look for their
# libraries and data inside the bundle.
here="$(cd "$(dirname "$0")/.." && pwd)"
export GID_LIBRARY_PATH="$here/Frameworks"
export XDG_DATA_DIRS="$here/Resources/share"
export GSETTINGS_SCHEMA_DIR="$here/Resources/share/glib-2.0/schemas"
# GTK's GL renderers leave part of the window undrawn on macOS (the bottom
# of the 3D view, a corner of the console): compose it with cairo. The 3D
# view itself still draws with OpenGL.
export GSK_RENDERER="${GSK_RENDERER:-cairo}"
# with cairo, text laid out by CoreText loses the top of its letters in
# entries and labels: lay it out with fontconfig, configured from the bundle
export PANGOCAIRO_BACKEND="${PANGOCAIRO_BACKEND:-fc}"
export FONTCONFIG_FILE="${FONTCONFIG_FILE:-$here/Resources/etc/fonts/fonts.conf}"
export FONTCONFIG_PATH="${FONTCONFIG_PATH:-$here/Resources/etc/fonts}"   # where its conf.d is
exec "$here/Resources/bin/hackerscad" "$@"
