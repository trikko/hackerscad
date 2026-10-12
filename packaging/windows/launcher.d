/* hackerscad.exe, at the top of the Windows folder: starts bin\hscad-gui.exe
 * with the same arguments, so users need not look for it in bin (the program
 * has to stay next to its DLLs, and a shortcut would break when the folder is
 * moved). Built with -betterC by packaging/windows/package.sh. */
module launcher;

import core.sys.windows.windows;

/// Zero bytes: with -betterC there is no runtime holding the structures'
/// default values.
void zero(T)(ref T x) nothrow @nogc
{
    (cast(ubyte*) &x)[0 .. T.sizeof] = 0;
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
    wchar[MAX_PATH + 32] dir, exe;
    auto n = GetModuleFileNameW(null, dir.ptr, MAX_PATH);
    while (n > 0 && dir[n - 1] != '\\')
        n--;
    dir[n] = 0;
    size_t e;
    append(exe, e, dir.ptr);
    append(exe, e, "bin\\hscad-gui.exe"w.ptr);
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
