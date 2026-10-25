/// Windows: the empty part of the header bar is the window's caption for
/// Windows, so that dragging it is Windows' own move, with Snap Assist and the
/// snap layouts, and a double click maximizes. GTK moves a window with a
/// header bar of its own by itself (gdk/win32 calls SetWindowPos at every
/// motion of the pointer): Windows never learns the window is being dragged,
/// and offers none of that.
module hackerscad.gui.winsnap;

version (Windows):

import core.sys.windows.windows;

import gtk.window : Window;

/// Puts the hit test before GTK's: where GTK answers "client area" and
/// `isCaption` says the point (in the window's coordinates, GTK's logical
/// pixels) is the empty part of the header bar, Windows is told "caption".
/// Called once the window is realized (it needs its native window).
void captionHitTest(Window window, bool delegate(double x, double y) isCaption)
{
    toplevel = window;
    alias GetHandle = extern (C) void* function(void*) nothrow @nogc;
    auto gtk = GetModuleHandleW("libgtk-4-1.dll"w.ptr);
    auto getHandle = gtk is null ? null : cast(GetHandle) GetProcAddress(gtk, "gdk_win32_surface_get_handle");
    auto surface = window.getSurface();
    if (getHandle is null || surface is null)
        return;
    auto hwnd = cast(HWND) getHandle(surface._cPtr);
    if (hwnd is null || gtkProc !is null)
        return;
    caption = isCaption;
    scaleOf = () => surface.getScaleFactor();
    gtkProc = cast(WNDPROC) SetWindowLongPtrW(hwnd, GWLP_WNDPROC, cast(LONG_PTR) &hitTestFirst);
    // resizable and maximizable for Windows, which snaps only such windows: GTK takes these styles away from a
    // window with its own header bar. Given once, not at each drag (added as a drag began, the window showed
    // moved by the frame's width for the first pixel of the drag); and only once the window is shown and in
    // place: GTK sets the styles as it shows it, working out its position and size from them, and given
    // before, the window ended out of the screen
    window.connectMap(() {
        import glib.global : idleAdd;
        import glib.types : PRIORITY_DEFAULT_IDLE;
        idleAdd(PRIORITY_DEFAULT_IDLE, () {
            if (!framed)
            {
                framed = true;
                SetWindowLongPtrW(hwnd, GWL_STYLE, GetWindowLongPtrW(hwnd, GWL_STYLE) | frameStyles);
                frameChanged(hwnd);
                nativeShadow(hwnd);
            }
            return false;
        });
    });
}

private __gshared WNDPROC gtkProc;
private __gshared Window toplevel;
/// not in druntime: WINDOWPOS' flag of a window minimized, maximized or restored
private enum SWP_STATECHANGED = 0x8000;

/// the styles Windows snaps a window by, kept on it once given
enum frameStyles = WS_THICKFRAME | WS_MAXIMIZEBOX;
private __gshared bool framed;
/// Windows moves or sizes the window itself (its loop, between WM_ENTERSIZEMOVE and WM_EXITSIZEMOVE)
private __gshared bool systemSizing;
private __gshared bool delegate(double, double) caption;
private __gshared int delegate() scaleOf;

/// Windows' own shadow and, on Windows 11, its round corners, in place of GTK's (taken away on Windows, see
/// app.d): the frame extended by a pixel into the window, which GTK covers, makes DWM draw the shadow
private void nativeShadow(HWND hwnd) nothrow
{
    static struct Margins
    {
        int left, right, top, bottom;
    }
    alias Extend = extern (Windows) int function(HWND, const(Margins)*) nothrow @nogc;
    alias SetAttribute = extern (Windows) int function(HWND, DWORD, const(void)*, DWORD) nothrow @nogc;
    auto dwm = LoadLibraryW("dwmapi.dll"w.ptr);
    if (dwm is null)
        return;
    if (auto extend = cast(Extend) GetProcAddress(dwm, "DwmExtendFrameIntoClientArea"))
    {
        immutable m = Margins(0, 0, 0, 1);
        extend(hwnd, &m);
    }
    // DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND: ignored before Windows 11
    if (auto set = cast(SetAttribute) GetProcAddress(dwm, "DwmSetWindowAttribute"))
    {
        immutable int round = 2;
        set(hwnd, 33, &round, round.sizeof);
    }
}

/// How far in from the window's edges a press resizes it, in pixels at the window's DPI
private int resizeBorder(HWND hwnd) nothrow
{
    alias GetDpi = extern (Windows) UINT function(HWND) nothrow @nogc;
    static GetDpi getDpi;
    static bool looked;
    if (!looked)
    {
        looked = true;
        getDpi = cast(GetDpi) GetProcAddress(GetModuleHandleW("user32.dll"w.ptr), "GetDpiForWindow");
    }
    immutable dpi = getDpi is null ? 96 : getDpi(hwnd);
    return MulDiv(6, dpi, 96);
}

/// The frame worked out again at once, after its styles changed: until then Windows takes the frame of the
/// new styles to be there, and the window's content showed moved by its width until the next move
private void frameChanged(HWND hwnd) nothrow
{
    SetWindowPos(hwnd, null, 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

private extern (Windows) LRESULT hitTestFirst(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow
{
    if (msg == WM_ENTERSIZEMOVE)
        systemSizing = true;
    else if (msg == WM_EXITSIZEMOVE)
        systemSizing = false;
    // GTK's own changes of the window, told apart by their flags (also while Windows moves the window, when
    // they came too and the window slid away): not Windows' moves and snaps, its maximizing and restoring, nor
    // what another process asks (Win+arrows, from the shell)
    if (msg == WM_WINDOWPOSCHANGING && framed && !IsZoomed(hwnd) && !IsIconic(hwnd) && !InSendMessage())
    {
        auto pos = cast(WINDOWPOS*) lParam;
        // GTK, seeing the frame's styles back on the window, takes them away again (they come back, below) and
        // moves and shrinks the window as if the frame were gone: then lays it out at its size again, and so
        // on, the window going down and right by the frame at every turn. Only the frame is worked out again
        // (Windows never moves a window that way): the client area stays, and GTK does not lay it out again
        if ((pos.flags & SWP_FRAMECHANGED) && !(pos.flags & SWP_STATECHANGED))
            pos.flags |= SWP_NOMOVE | SWP_NOSIZE;
        // GTK sizing the window (a size, not a position: Windows' snaps give both; and not while Windows itself
        // sizes it from an edge) works the size out from its content with AdjustWindowRectEx, adding a frame
        // that is not there (the client area is all of the window, below): the window grew by it. That frame
        // is taken off again
        else if ((pos.flags & SWP_NOMOVE) && !(pos.flags & (SWP_NOSIZE | SWP_STATECHANGED)) && !systemSizing)
        {
            RECT f;
            AdjustWindowRectEx(&f, cast(DWORD) GetWindowLongPtrW(hwnd, GWL_STYLE), FALSE,
                cast(DWORD) GetWindowLongPtrW(hwnd, GWL_EXSTYLE));
            pos.cx -= f.right - f.left;
            pos.cy -= f.bottom - f.top;
        }
    }
    // the styles kept: GTK sets them anew (maximized, restored), and would take them away
    if (msg == WM_STYLECHANGING && wParam == cast(WPARAM) GWL_STYLE && framed)
        (cast(STYLESTRUCT*) lParam).styleNew |= frameStyles;
    // the frame those styles bring stays invisible: the client area is all of the window, as GTK draws it
    else if (msg == WM_NCCALCSIZE && wParam && framed)
    {
        if (IsZoomed(hwnd))
        {
            // maximized: the client area is the monitor's work area (the screen less the taskbar), whatever
            // rectangle Windows and GTK gave the window (Windows lets a resizable window's frame out of the
            // screen, GTK makes room for the frame it supposes)
            auto r = &(cast(NCCALCSIZE_PARAMS*) lParam).rgrc[0];
            MONITORINFO mi;
            mi.cbSize = MONITORINFO.sizeof;
            if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi))
                IntersectRect(r, r, &mi.rcWork);
        }
        return 0;
    }
    // a double click on the caption: maximized or back through GTK, as its header bar does, so that GTK knows
    // the window's state (Windows would maximize it behind GTK's back)
    else if (msg == WM_NCLBUTTONDBLCLK && wParam == HTCAPTION)
    {
        try
        {
            if (toplevel.isMaximized())
                toplevel.unmaximize();
            else
                toplevel.maximize();
        }
        catch (Exception)
        {
        }
        return 0;
    }
    auto answer = CallWindowProcW(gtkProc, hwnd, msg, wParam, lParam);
    if (msg != WM_NCHITTEST || answer != HTCLIENT)
        return answer;
    // the point, from screen pixels to the window's client pixels, then GTK's logical ones
    POINT p = POINT(cast(short) LOWORD(lParam), cast(short) HIWORD(lParam));
    if (!ScreenToClient(hwnd, &p))
        return answer;
    // near the edges, Windows resizes the window (GTK did it in the margin of its shadow, gone on Windows)
    if (framed && !IsZoomed(hwnd))
    {
        RECT c;
        GetClientRect(hwnd, &c);
        immutable b = resizeBorder(hwnd);
        immutable left = p.x < b, right = p.x >= c.right - b, top = p.y < b, bottom = p.y >= c.bottom - b;
        if (top)
            return left ? HTTOPLEFT : right ? HTTOPRIGHT : HTTOP;
        if (bottom)
            return left ? HTBOTTOMLEFT : right ? HTBOTTOMRIGHT : HTBOTTOM;
        if (left)
            return HTLEFT;
        if (right)
            return HTRIGHT;
    }
    try
    {
        immutable scale = scaleOf();
        if (caption(p.x / cast(double) scale, p.y / cast(double) scale))
            return HTCAPTION;
    }
    catch (Exception)
    {
    }
    return answer;
}
