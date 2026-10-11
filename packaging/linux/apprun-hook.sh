# AppRun hook, after the GTK plugin's: GtkSourceView's languages and styles
# and the Adwaita icons from the AppImage. libadwaita draws its own style and
# follows the system's dark mode, so the plugin's GTK_THEME is dropped (it
# breaks both), and GTK 4 picks Wayland or X11 by itself.
export XDG_DATA_DIRS="$APPDIR/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
unset GTK_THEME
if [ "${GDK_BACKEND:-}" = "x11" ] && [ -z "${HCAD_GDK_BACKEND:-}" ]; then
    unset GDK_BACKEND
fi
