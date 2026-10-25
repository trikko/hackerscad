/// Logs and crash reports, in a folder of their own: on Windows the window's
/// messages go to a log there (a windowed program has no console, and they
/// went nowhere), and when the program crashes a report is written there
/// (with a minidump on Windows), which the next start points to.
module hackerscad.gui.crashlog;

import std.file : exists, mkdirRecurse;
import std.path : buildPath;

/// Where the logs and reports go: %LOCALAPPDATA%\hackerscad\logs on Windows,
/// ~/Library/Logs/hackerscad on macOS, $XDG_STATE_HOME/hackerscad (by default
/// ~/.local/state/hackerscad) elsewhere.
string logDir()
{
    import std.process : environment;
    version (Windows)
        return buildPath(environment.get("LOCALAPPDATA", environment.get("TEMP", ".")), "hackerscad", "logs");
    else version (OSX)
        return buildPath(environment.get("HOME", "."), "Library", "Logs", "hackerscad");
    else
    {
        auto state = environment.get("XDG_STATE_HOME");
        return state.length ? buildPath(state, "hackerscad")
            : buildPath(environment.get("HOME", "."), ".local", "state", "hackerscad");
    }
}

/// The program's messages, when no one sees them (Windows started without a
/// terminal); the previous run's kept as hackerscad.1.log.
string logFile() => buildPath(logDir(), "hackerscad.log");

private __gshared string header;    /// the first lines of a report: version and system

/// Gets ready to write reports, at the very start: `about` is what they begin
/// with (the version, the system). Exceptions in GTK's callbacks, which gid
/// keeps from stopping the program, are logged with their stack instead of
/// their message alone.
void startCrashReports(string about)
{
    import gid.gid : setCallbackExceptionHandler;
    header = about;
    try
        mkdirRecurse(logDir());
    catch (Exception)
    {
    }
    setCallbackExceptionHandler(&logCallbackException);
    version (Windows)
        startNativeReports();
}

/// stdout and stderr into the log file, the previous log kept (Windows, no terminal).
void logToFile()
{
    import std.file : rename;
    import std.stdio : stdout, stderr;
    try
    {
        if (exists(logFile()))
            rename(logFile(), buildPath(logDir(), "hackerscad.1.log"));
    }
    catch (Exception)
    {
    }
    try
    {
        stderr.reopen(logFile(), "w");
        stdout.reopen(logFile(), "a");
        stderr.writeln(header);
        stderr.flush();
    }
    catch (Exception)
    {
        stdout.reopen("NUL", "w");
        stderr.reopen("NUL", "w");
    }
}

/// A crash in D (a Throwable that reached the top): its report written, and its path given.
string reportCrash(Throwable t) nothrow
{
    import std.datetime.systime : Clock;
    import std.file : write;
    import std.format : format;
    try
    {
        auto now = Clock.currTime();
        auto path = buildPath(logDir(), format("crash-%04d%02d%02d-%02d%02d%02d.txt", now.year, now.month, now.day,
            now.hour, now.minute, now.second));
        write(path, format("%s\n%s\n\n%s\n", header, now.toISOExtString(), t));
        return path;
    }
    catch (Throwable)
        return null;
}

/// The newest report written since the previous start, once: null when there is none.
string pendingReport()
{
    import std.algorithm : filter, maxElement;
    import std.array : array;
    import std.file : dirEntries, SpanMode, timeLastModified, write;
    try
    {
        auto seen = buildPath(logDir(), ".reported");
        immutable since = exists(seen) ? timeLastModified(seen) : typeof(timeLastModified(seen)).min;
        auto fresh = dirEntries(logDir(), "crash-*.txt", SpanMode.shallow)
            .filter!(e => e.timeLastModified > since).array;
        write(seen, "");
        if (fresh.length == 0)
            return null;
        return fresh.maxElement!(e => e.timeLastModified).name;
    }
    catch (Exception)
        return null;
}

/// gid's handler for exceptions in callbacks, with the stack (gid's own gives the message alone)
private void logCallbackException(Exception e, imported!"gid.gid".GidCallbackExceptionInfo info) nothrow
{
    import std.stdio : stderr;
    try
    {
        stderr.writeln("exception in a callback: ", e);
        stderr.flush();
    }
    catch (Exception)
    {
    }
}

version (Windows)
{
    import core.sys.windows.windows;

    /// The report's file, without its extension (.txt, .dmp), made ready before a crash: when one comes,
    /// nothing is worked out that might fail
    private __gshared wchar[512] nativeBase;
    private __gshared char[1024] headerText;
    private __gshared size_t headerLength;

    /// A native crash (in GTK, OpenCascade, a driver, or a D Error crossing C code): its report and a
    /// minidump written, then Windows does what it does with a crash
    private void startNativeReports()
    {
        import std.utf : toUTF16;
        auto base = toUTF16(buildPath(logDir(), "crash-native"));
        if (base.length + 32 >= nativeBase.length)
            return;
        nativeBase[0 .. base.length] = base[];
        nativeBase[base.length] = 0;
        headerLength = header.length < headerText.length ? header.length : headerText.length;
        headerText[0 .. headerLength] = header[0 .. headerLength];
        SetUnhandledExceptionFilter(&nativeCrash);
    }

    private extern (Windows) LONG nativeCrash(EXCEPTION_POINTERS* info) nothrow @nogc
    {
        import core.stdc.stdio : snprintf;
        import core.stdc.wchar_ : wcslen;
        // the files: crash-native-<time>.txt and .dmp
        SYSTEMTIME t;
        GetLocalTime(&t);
        wchar[600] path;
        immutable n = wcslen(nativeBase.ptr);
        path[0 .. n] = nativeBase[0 .. n];
        char[24] stamp;
        immutable s = snprintf(stamp.ptr, stamp.length, "-%04d%02d%02d-%02d%02d%02d", t.wYear, t.wMonth, t.wDay,
            t.wHour, t.wMinute, t.wSecond);
        foreach (i; 0 .. s)
            path[n + i] = stamp[i];
        auto end = n + s;
        // what crashed: the code, the address, and the module it lies in with the offset
        auto record = info.ExceptionRecord;
        auto address = record.ExceptionAddress;
        HMODULE module_;
        wchar[260] moduleName = 0;
        size_t offset;
        if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            cast(const(wchar)*) address, &module_))
        {
            GetModuleFileNameW(module_, moduleName.ptr, cast(DWORD) moduleName.length);
            offset = cast(size_t) address - cast(size_t) module_;
        }
        char[260] moduleUtf8 = 0;
        WideCharToMultiByte(CP_UTF8, 0, moduleName.ptr, -1, moduleUtf8.ptr, cast(int) moduleUtf8.length, null, null);
        char[1800] text;
        immutable len = snprintf(text.ptr, text.length,
            "%.*s\nnative crash: exception 0x%08X at %p, in %s + 0x%zx\n%s\n",
            cast(int) headerLength, headerText.ptr, record.ExceptionCode, address, moduleUtf8.ptr, offset,
            record.ExceptionCode == 0xC0000005 ? "(an access violation: memory read or written where it may not be)".ptr
                : "".ptr);
        writeFile(path.ptr, end, ".txt", text.ptr, len < text.length ? len : text.length - 1);
        // the minidump, with dbghelp (in every Windows)
        alias WriteDump = extern (Windows) BOOL function(HANDLE, DWORD, HANDLE, int, void*, void*, void*) nothrow @nogc;
        static struct ExceptionInfo
        {
        align(4):
            DWORD threadId;
            EXCEPTION_POINTERS* pointers;
            BOOL clientPointers;
        }
        if (auto dbghelp = LoadLibraryW("dbghelp.dll"w.ptr))
            if (auto writeDump = cast(WriteDump) GetProcAddress(dbghelp, "MiniDumpWriteDump"))
            {
                copyExtension(path.ptr, end, ".dmp");
                auto file = CreateFileW(path.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
                if (file != INVALID_HANDLE_VALUE)
                {
                    auto e = ExceptionInfo(GetCurrentThreadId(), info, FALSE);
                    // MiniDumpWithThreadInfo | MiniDumpWithIndirectlyReferencedMemory: small, with the stacks
                    writeDump(GetCurrentProcess(), GetCurrentProcessId(), file, 0x1000 | 0x40, &e, null, null);
                    CloseHandle(file);
                }
            }
        return EXCEPTION_CONTINUE_SEARCH;
    }

    private void copyExtension(wchar* path, size_t end, string extension) nothrow @nogc
    {
        foreach (i, c; extension)
            path[end + i] = c;
        path[end + extension.length] = 0;
    }

    private void writeFile(wchar* path, size_t end, string extension, const(char)* text, size_t length) nothrow @nogc
    {
        copyExtension(path, end, extension);
        auto file = CreateFileW(path, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        if (file == INVALID_HANDLE_VALUE)
            return;
        DWORD written;
        WriteFile(file, text, cast(DWORD) length, &written, null);
        CloseHandle(file);
    }
}
