/* hackerscad.exe, at the top of the Windows folder: starts bin\hscad-gui.exe
 * with the same arguments, so users need not look for it. When the machine's
 * OpenGL is too old for GTK (virtual machines often offer only Windows'
 * OpenGL 1.1) and Mesa's software OpenGL is there (bin\mesa), it asks the
 * application to use that one (HCAD_GL=software, see gui/app.d).
 * Built with -betterC by packaging/windows/package.sh. */
module launcher;

import core.sys.windows.windows;

extern (Windows) const(char)* glGetString(uint name) nothrow @nogc;
enum uint GL_RENDERER = 0x1F01, GL_VERSION = 0x1F02;

/// Whether the system's OpenGL can run GTK: version 3.2 at least, and not
/// Windows' own software one ("GDI Generic").
bool hardwareGl() nothrow @nogc
{
    bool ok;
    auto w = CreateWindowExW(0, "STATIC"w.ptr, ""w.ptr, WS_POPUP, 0, 0, 1, 1, null, null, null, null);
    auto dc = w ? GetDC(w) : null;
    if (dc)
    {
        PIXELFORMATDESCRIPTOR pfd = void;
        zero(pfd);
        pfd.nSize = pfd.sizeof;
        pfd.nVersion = 1;
        pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
        pfd.iPixelType = PFD_TYPE_RGBA;
        pfd.cColorBits = 32;
        immutable format = ChoosePixelFormat(dc, &pfd);
        auto gl = format && SetPixelFormat(dc, format, &pfd) ? wglCreateContext(dc) : null;
        if (gl && wglMakeCurrent(dc, gl))
        {
            // "4.6.0 NVIDIA 555.85": major and minor are the first numbers
            int[2] v;
            size_t k;
            for (auto p = glGetString(GL_VERSION); p && *p && k < 2; p++)
                if (*p >= '0' && *p <= '9')
                    v[k] = v[k] * 10 + (*p - '0');
                else if (*p == '.')
                    k++;
                else
                    break;
            ok = (v[0] > 3 || (v[0] == 3 && v[1] >= 2)) && !contains(glGetString(GL_RENDERER), "GDI Generic");
            wglMakeCurrent(null, null);
        }
        if (gl)
            wglDeleteContext(gl);
        ReleaseDC(w, dc);
    }
    if (w)
        DestroyWindow(w);
    return ok;
}

/// Zero bytes: with -betterC there is no runtime holding the structures'
/// default values.
void zero(T)(ref T x) nothrow @nogc
{
    (cast(ubyte*) &x)[0 .. T.sizeof] = 0;
}

bool contains(const(char)* s, string what) nothrow @nogc
{
    for (; s && *s; s++)
    {
        size_t i;
        while (i < what.length && s[i] == what[i])
            i++;
        if (i == what.length)
            return true;
    }
    return false;
}

/// Appends the zero-terminated `s` to `buf` at `n`, within its length.
void append(wchar[] buf, ref size_t n, const(wchar)* s) nothrow @nogc
{
    for (; s && *s && n + 1 < buf.length; s++)
        buf[n++] = *s;
    buf[n] = 0;
}

__gshared wchar[32_768] line;   // the longest command line Windows takes

extern (Windows) int wWinMain(HINSTANCE, HINSTANCE, LPWSTR args, int)
{
    wchar[MAX_PATH + 32] dir, exe, mesa;
    auto n = GetModuleFileNameW(null, dir.ptr, MAX_PATH);
    while (n > 0 && dir[n - 1] != '\\')
        n--;
    dir[n] = 0;
    size_t e, m;
    append(exe, e, dir.ptr);
    append(exe, e, "bin\\hscad-gui.exe"w.ptr);
    append(mesa, m, dir.ptr);
    append(mesa, m, "bin\\mesa\\opengl32.dll"w.ptr);

    if (GetEnvironmentVariableW("HCAD_GL"w.ptr, null, 0) == 0
        && GetFileAttributesW(mesa.ptr) != INVALID_FILE_ATTRIBUTES && !hardwareGl())
        SetEnvironmentVariableW("HCAD_GL"w.ptr, "software"w.ptr);

    size_t l;
    append(line, l, "\""w.ptr);
    append(line, l, exe.ptr);
    append(line, l, "\" "w.ptr);
    append(line, l, args);
    STARTUPINFOW si = void;
    zero(si);
    si.cb = si.sizeof;
    PROCESS_INFORMATION pi = void;
    zero(pi);
    if (!CreateProcessW(exe.ptr, line.ptr, null, null, FALSE, 0, null, null, &si, &pi))
    {
        MessageBoxW(null, "bin\\hscad-gui.exe could not be started."w.ptr, "hackerscad"w.ptr, MB_ICONERROR);
        return 1;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
}
