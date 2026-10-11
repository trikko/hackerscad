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
exec "$here/Resources/bin/hackerscad" "$@"
