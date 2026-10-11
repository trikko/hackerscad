#!/bin/sh
# hackerscad.app/Contents/MacOS/hackerscad: GTK and gid look for their
# libraries and data inside the bundle.
here="$(cd "$(dirname "$0")/.." && pwd)"
export GID_LIBRARY_PATH="$here/Frameworks"
export XDG_DATA_DIRS="$here/Resources/share"
export GSETTINGS_SCHEMA_DIR="$here/Resources/share/glib-2.0/schemas"
exec "$here/Resources/bin/hackerscad" "$@"
