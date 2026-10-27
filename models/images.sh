#!/bin/bash
# The home page's pictures, made again from the models beside this script with hcad:
#   models/images.sh            the renders and the viewer's STL files, into img/
#   models/images.sh --shot     also the screenshot of the application, half light half dark
#                               (needs hackerscad and mutter: a headless Wayland session)
# HCAD and HACKERSCAD name the programs when they are not in the PATH.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
img="$here/../img"
hcad="${HCAD:-hcad}"
mkdir -p "$img"

render() { "$hcad" render "$here/$1" "${@:3}" -o "$img/$2"; }

# the battery holder of "Checked like code": its picture, and its two parts for the 3D viewer
render batteries.hcad batteries.png
render batteries.hcad holder.stl --part holder --tolerance 0.05
render batteries.hcad cell.stl --part cell --tolerance 0.05

# the wall hook an agent made, in the agents section
render hook.hcad hook.png

# one object per library
for n in hardware threads gears hinges snaps enclosures joints molds flex; do
    render "lib/$n.hcad" "lib-$n.png"
done

[ "${1:-}" = "--shot" ] || exit 0

# the hero: Carlo open in the application, a light and a dark screenshot joined along a diagonal
app="${HACKERSCAD:-hackerscad}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for theme in light dark; do
    cat > "$tmp/shot.sh" <<EOF
#!/bin/bash
d=site-shot-$theme
mutter --headless --wayland --no-x11 --virtual-monitor 1440x900 --wayland-display=\$d >/dev/null 2>&1 &
m=\$!
for i in \$(seq 50); do [ -S "\$XDG_RUNTIME_DIR/\$d" ] && break; sleep 0.2; done
mkdir -p "$tmp/config-$theme"
WAYLAND_DISPLAY=\$d GDK_BACKEND=wayland XDG_CONFIG_HOME="$tmp/config-$theme" timeout 120 "$app" \
    --copy="$here/carlo.hcad" --theme=$theme --name=hackerscad --size=1440x880 --screenshot="$tmp/$theme.png"
kill \$m
EOF
    chmod +x "$tmp/shot.sh"
    (cd /tmp && dbus-run-session -- "$tmp/shot.sh" >/dev/null 2>&1)
done
python3 - "$tmp/light.png" "$tmp/dark.png" "$img/app-split.png" <<'EOF'
import sys
from PIL import Image, ImageDraw
light, dark = (Image.open(p).convert('RGB') for p in sys.argv[1:3])
w, h = light.size
top, bottom = int(w * 0.60), int(w * 0.42)   # where the diagonal meets the top and the bottom
mask = Image.new('L', (w, h), 0)
ImageDraw.Draw(mask).polygon([(top, 0), (w, 0), (w, h), (bottom, h)], fill=255)
out = Image.composite(dark, light, mask)
ImageDraw.Draw(out).line([(top, 0), (bottom, h)], fill=(15, 195, 242), width=10)
out.save(sys.argv[3])
EOF
