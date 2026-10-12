#!/bin/bash
# Used by the CI: starts the application on the startup example and, once it
# is drawn, captures the whole screen.
# Usage: tests/screenshot.sh <name> <hackerscad command…>
#   -> window-<name>.png (from hackerscad) and screen-<name>.png (from the OS)
name=$1
shift
rm -f "window-$name.png" "screen-$name.png"
work="$(mktemp -d)"

# On Windows the runner's console would cover our window
case "$(uname -s)" in Linux|Darwin) ;; *) powershell -NoProfile -Command "(New-Object -ComObject Shell.Application).MinimizeAll()"; sleep 1 ;; esac

HCAD_SCREENSHOT_WAIT=4 "$@" --screenshot="$PWD/window-$name.png" "$work/new.hcad" &
pid=$!

# hackerscad saves its screenshot after the first evaluation, then stays open for 4 more seconds
# (not until the process ends: on Windows it may start another and exit)
for i in $(seq 1 300); do
    [ -f "window-$name.png" ] && break
    sleep 0.2
done

if [ -f "window-$name.png" ]; then
    sleep 1
    case "$(uname -s)" in
        Linux)  import -window root "screen-$name.png" ;;
        # macOS: GTK may still be drawing a second after the first frame
        Darwin) sleep 2; screencapture -x "screen-$name.png" ;;
        *)      powershell -NoProfile -Command "
                    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
                    \$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                    \$img = New-Object System.Drawing.Bitmap \$b.Width, \$b.Height
                    [System.Drawing.Graphics]::FromImage(\$img).CopyFromScreen(\$b.Location, [System.Drawing.Point]::Empty, \$b.Size)
                    \$img.Save('screen-$name.png')" ;;
    esac
fi
wait $pid
