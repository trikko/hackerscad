/// Model Context Protocol server over stdio (`hcad mcp`): lets AI agents
/// read the reference, evaluate and render models, export them and drive an
/// open hackerscad window.
module hackerscad.tool.mcp;

import hackerscad.about : appVersion;
import hackerscad.examples : examples;
import std.algorithm : map, canFind, startsWith;
import std.array : array, join;
import std.base64 : Base64;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, read, remove, tempDir;
import std.format : format;
import std.json;
import std.path : buildPath;
import std.stdio : stdin, stdout, stderr;
import std.string : strip;
import core.atomic : atomicLoad, atomicOp;

import hackerscad.render.raster : View;
import hackerscad.tool.docs : agentsText, docsStamp, reference, skillText, summaryText;
import hackerscad.tool.runner;
import hackerscad.tool.guiclient;
import hackerscad.kernel.cache : CachingKernel;
import hackerscad.kernel.occt.backend : OcctKernel;

enum serverVersion = appVersion;

enum instructions = "hackerscad is a parametric CAD for code-defined models (.hcad, a sandboxed subset of D). "
    ~ "Call hcad_docs first (its rules avoid most mistakes), then iterate with hcad_render (it returns "
    ~ "dimensions, problems and pictures) until the model matches the request, then hcad_export. If the user "
    ~ "has hackerscad open, hcad_gui_* tools show your work in their window: change its code with "
    ~ "hcad_gui_edit, never by writing its file; with several windows, ask which one (never assume the most "
    ~ "recent). To show an example in a window of its own, hcad_gui_launch it with code (or copy: a file), not "
    ~ "path: a window of no file, which a Save cannot overwrite. From a photo or a real object, your first "
    ~ "reply is the questions, before any code or hcad_gui_new/edit, even when told to make it; estimate only "
    ~ "if the user says so. Ask instead of guessing when it changes the result: the sizes of a real part to copy or build onto (say exactly what to measure), a font that cannot "
    ~ "be recognised (offer a similar installed one or tracing it as a sketch), the process or printer for "
    ~ "fits. To remodel a mesh or STEP, no questions: its sizes are there; hcad_docs topic remodel gives the "
    ~ "method. For an outline given by its dimensions, prefer a constrained sketch. To ask or to show where, "
    ~ "frame the view on it, then mark it with hcad_gui_annotate in a colour that stands out; read the user's "
    ~ "marks in hcad_gui_state when they say \"here\"; clear yours when done (the view is locked meanwhile).";

/// Runs the server until stdin closes. Models are evaluated in a worker
/// process (`hcad mcp --worker`): a cancelled or timed out evaluation, or one
/// that crashes the kernel, kills the worker and gives all its memory back,
/// and the next evaluation starts a new one.
void serve()
{
    version (Posix)
    {
        // a dead worker must not take the server down while we write to it
        import core.sys.posix.signal : signal, SIGPIPE, SIG_IGN;
        signal(SIGPIPE, SIG_IGN);
    }
    import std.process : environment;
    auto worker = new Worker;
    recordExe();
    // started again by an older server whose program was rebuilt or updated:
    // the client is told the tools may have changed, and gets the answer to
    // the message that server had just read
    auto replay = environment.get("HCAD_MCP_REPLAY");
    if (environment.get("HCAD_MCP_RESTARTED"))
    {
        environment.remove("HCAD_MCP_RESTARTED");
        environment.remove("HCAD_MCP_REPLAY");
        sendLine(`{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}`);
    }
    version (Posix)
    {
        // unbuffered, so that a new program started in place reads what this one did not
        import core.stdc.stdio : setvbuf, _IONBF;
        setvbuf(stdin.getFP, null, _IONBF, 0);
    }
    if (replay.length)
        process(replay, worker);
    foreach (line; stdin.byLineCopy)
    {
        if (exeUpdated() && worker.idle && atomicLoad(guiCalls) == 0)
            restart(line, worker);
        process(line, worker);
    }
    // stdin closed: the answers on their way are sent first (a client may
    // close its end and read on), for two minutes at most; then out without
    // the runtime tearing down the threads, which crashed with a GUI call
    // still running in one
    import core.thread : Thread;
    import core.time : MonoTime, minutes, msecs;
    immutable until = MonoTime.currTime + 2.minutes;
    while ((!worker.idle || atomicLoad(guiCalls) > 0) && MonoTime.currTime < until)
        Thread.sleep(50.msecs);
    worker.stop();
    stdout.flush();
    import core.stdc.stdlib : _Exit;
    _Exit(0);
}

/// The executable, as it was when the server started.
private __gshared string exePath;
private __gshared long exeStamp;

private void recordExe()
{
    import std.file : thisExePath;
    exePath = thisExePath;
    exeStamp = exeTime();
}

private long exeTime()
{
    import std.file : timeLastModified;
    try
        return timeLastModified(exePath).stdTime;
    catch (Exception)
        return 0;
}

/// The program on disk is not the one running: rebuilt or updated.
private bool exeUpdated() => exePath.length && exeStamp && exeTime() != exeStamp;

/// Runs the new program in place of this one, with the same stdin and
/// stdout; it answers `line` first. Only POSIX can replace a process.
private void restart(string line, Worker worker)
{
    version (Posix)
    {
        import core.sys.posix.unistd : execv;
        import std.process : environment;
        import std.string : toStringz;
        worker.stop();
        environment["HCAD_MCP_RESTARTED"] = "1";
        environment["HCAD_MCP_REPLAY"] = line;
        stdout.flush();
        const(char)*[3] argv = [exePath.toStringz, "mcp".toStringz, null];
        execv(argv[0], argv.ptr);
        // could not: keep serving with this program
        environment.remove("HCAD_MCP_RESTARTED");
        environment.remove("HCAD_MCP_REPLAY");
        exeStamp = exeTime();
    }
}

private shared int guiCalls;    // GUI tool calls still running in the background

private void process(string line, Worker worker)
{
    {
        if (line.strip.length == 0)
            return;
        JSONValue msg;
        try
            msg = parseJSON(line);
        catch (JSONException)
        {
            send(errorResponse(JSONValue(null), -32700, "parse error"));
            return;
        }
        immutable method = "method" in msg && msg["method"].type == JSONType.string ? msg["method"].str : "";
        auto params = "params" in msg ? msg["params"] : JSONValue(null);
        if (method == "notifications/cancelled" && params.type == JSONType.object && "requestId" in params)
            worker.cancel(params["requestId"]);
        else if (method == "tools/call" && "id" in msg && params.type == JSONType.object && "name" in params
            && evaluates(params["name"].str))
            worker.start(msg["id"], line);
        else if (method == "tools/call")
            background(msg);    // the GUI tools can wait for the window
        else
        {
            auto response = handle(msg);
            if (response.type != JSONType.null_)
                send(response);
        }
    }
}

/// The worker process: evaluates the tool calls the server forwards, one at a
/// time, and exits as soon as the server goes away, even in the middle of an
/// evaluation.
void serveWorker()
{
    import core.sync.condition : Condition;
    import core.sync.mutex : Mutex;
    import core.thread : Thread;

    limitMemory(memoryLimit());

    auto lock = new Mutex;
    auto ready = new Condition(lock);
    string[] queue;
    auto reader = new Thread({
        foreach (line; stdin.byLineCopy)
            synchronized (lock)
            {
                queue ~= line;
                ready.notify();
            }
        // the server closed the pipe (it exited, crashed or was killed):
        // leave now, without waiting for the evaluation or the runtime
        import core.stdc.stdlib : _Exit;
        _Exit(0);
    });
    reader.isDaemon = true;
    reader.start();

    while (true)
    {
        string line;
        synchronized (lock)
        {
            while (queue.length == 0)
                ready.wait();
            line = queue[0];
            queue = queue[1 .. $];
        }
        JSONValue response;
        try
            response = handle(parseJSON(line));
        catch (JSONException)
            response = errorResponse(JSONValue(null), -32700, "parse error");
        if (response.type != JSONType.null_)
            send(response);
        releaseMemory();
    }
}

/// Handles one JSON-RPC message; returns null for notifications.
JSONValue handle(JSONValue msg)
{
    auto id = "id" in msg ? msg["id"] : JSONValue(null);
    immutable isNotification = ("id" in msg) is null;
    auto method = "method" in msg ? msg["method"].str : "";
    auto params = "params" in msg ? msg["params"] : JSONValue((JSONValue[string]).init);

    try
    {
        switch (method)
        {
        case "initialize":
            {
                auto requested = "protocolVersion" in params ? params["protocolVersion"].str : "2025-06-18";
                JSONValue r = ["protocolVersion": requested];
                // the tools change when the program is rebuilt or updated (see restart)
                r["capabilities"] = ["tools": JSONValue(["listChanged": true])];
                r["serverInfo"] = ["name": "hackerscad", "version": serverVersion];
                r["instructions"] = instructions;
                return result(id, r);
            }
        case "notifications/initialized", "notifications/cancelled":
            return JSONValue(null);
        case "ping":
            return result(id, JSONValue((JSONValue[string]).init));
        case "tools/list":
            return result(id, JSONValue(["tools": JSONValue(toolList())]));
        case "tools/call":
            return result(id, callTool(params["name"].str, "arguments" in params ? params["arguments"] : JSONValue(null)));
        default:
            if (isNotification)
                return JSONValue(null);
            return errorResponse(id, -32601, "method not found: " ~ method);
        }
    }
    catch (Exception e)
        return errorResponse(id, -32603, e.msg);
}

private:

void send(JSONValue v)
{
    sendLine(v.toString(JSONOptions.doNotEscapeSlashes));
}

void sendLine(string line)
{
    synchronized
    {
        stdout.writeln(line);
        stdout.flush();
    }
}

JSONValue toolError(string message)
{
    JSONValue r = ["content": [JSONValue(["type": "text", "text": message])]];
    r["isError"] = true;
    return r;
}

/// Tools that evaluate a model, in the worker process.
bool evaluates(string tool) =>
    ["hcad_check", "hcad_render", "hcad_export", "hcad_drawing", "hcad_measure", "hcad_features", "hcad_section",
        "hcad_compare", "hcad_scan", "hcad_diff", "hcad_fit", "hcad_match", "hcad_lines", "hcad_literals"].canFind(tool);

void background(JSONValue msg)
{
    import core.thread : Thread;
    atomicOp!"+="(guiCalls, 1);
    auto t = new Thread({
        scope (exit)
            atomicOp!"-="(guiCalls, 1);
        auto response = handle(msg);
        if (response.type != JSONType.null_)
            send(response);
    });
    t.isDaemon = true;
    t.start();
}

// ---------------------------------------------------------------- worker process

/// The worker process seen from the server: forwards evaluations to it one at
/// a time, and kills it when an evaluation is cancelled or takes too long.
final class Worker
{
    import core.sync.mutex : Mutex;
    import core.time : MonoTime, Duration, seconds, msecs;
    import std.process : ProcessPipes;

    enum Stop { none, cancelled, timedOut }

    private Mutex turn;            // one evaluation at a time
    private Mutex state;           // guards what follows
    private ProcessPipes proc;
    private bool running;
    private string current;        // id of the request being evaluated
    private bool[string] waiting;  // ids of the requests in line
    private bool[string] dropped;  // ids cancelled while in line
    private MonoTime deadline;
    private Stop stopped;
    private Duration timeout;

    this()
    {
        turn = new Mutex;
        state = new Mutex;
        timeout = evaluationTimeout();
        if (timeout > Duration.zero)
        {
            import core.thread : Thread;
            auto t = new Thread(&watch);
            t.isDaemon = true;
            t.start();
        }
    }

    /// Evaluates a tools/call in the background; the response is sent from there.
    void start(JSONValue id, string line)
    {
        import core.thread : Thread;
        immutable key = id.toString;
        synchronized (state)
            waiting[key] = true;
        auto t = new Thread({ call(id, key, line); });
        t.isDaemon = true;
        t.start();
    }

    /// A cancelled request gets no response (as the protocol asks).
    void cancel(JSONValue id)
    {
        immutable key = id.toString;
        synchronized (state)
        {
            if (running && key == current)
                kill(Stop.cancelled);
            else if (key in waiting)
                dropped[key] = true;
        }
    }

    void stop()
    {
        synchronized (state)
            if (running)
                kill(Stop.none);
    }

    /// Nothing evaluating, nothing in line.
    bool idle()
    {
        synchronized (state)
            return current is null && waiting.length == 0;
    }

private:

    void call(JSONValue id, string key, string line)
    {
        turn.lock();
        scope (exit)
            turn.unlock();
        synchronized (state)
        {
            waiting.remove(key);
            if (key in dropped)
            {
                dropped.remove(key);
                return;
            }
            try
                launch();
            catch (Exception e)
            {
                send(result(id, toolError("cannot start the evaluation worker: " ~ e.msg)));
                return;
            }
            current = key;
            stopped = Stop.none;
            deadline = MonoTime.currTime + timeout;
        }

        string reply;
        try
        {
            proc.stdin.writeln(line);
            proc.stdin.flush();
            // the kernel may print on stdout: only JSON lines are responses
            while ((reply = proc.stdout.readln()) !is null && !reply.strip.startsWith("{"))
                stderr.write(reply);
        }
        catch (Exception)
            reply = null;    // the worker is gone

        Stop why;
        synchronized (state)
        {
            current = null;
            why = stopped;
            if (reply is null && running)
                kill(Stop.none);
        }
        if (reply !is null)
            return sendLine(reply.strip);

        final switch (why)
        {
        case Stop.cancelled:
            return;
        case Stop.timedOut:
            return send(result(id, toolError(format("evaluation stopped after %s s: the model takes too long (the limit "
                ~ "is HCAD_MCP_TIMEOUT, in seconds, 0 for none). Simplify it, or check it in parts.", timeout.total!"seconds"))));
        case Stop.none:
            immutable limit = memoryLimit();
            return send(result(id, toolError("the evaluation worker stopped without answering"
                ~ (limit ? format(": the model probably needs more than the %s MB it may use (HCAD_MCP_MEMORY_MB, "
                    ~ "0 for no limit), or it crashed the geometry kernel", limit >> 20) : ": it crashed the geometry kernel")
                ~ ". Simplify the model, or check it in parts.")));
        }
    }

    void launch()
    {
        import std.file : thisExePath;
        import std.process : pipeProcess, Redirect;
        if (running)
            return;
        // the program the server started from: once rebuilt, thisExePath names a deleted file
        proc = pipeProcess([exePath.length ? exePath : thisExePath, "mcp", "--worker"], Redirect.stdin | Redirect.stdout);
        running = true;
    }

    /// With `state` locked.
    void kill(Stop why)
    {
        import std.process : kill, wait;
        stopped = why;
        running = false;
        try
        {
            version (Posix)
            {
                import core.sys.posix.signal : SIGKILL;
                kill(proc.pid, SIGKILL);
            }
            else
                kill(proc.pid);
            proc.stdin.close();
        }
        catch (Exception)
        {
        }
        wait(proc.pid);
    }

    void watch()
    {
        import core.thread : Thread;
        while (true)
        {
            Thread.sleep(500.msecs);
            synchronized (state)
                if (running && current !is null && MonoTime.currTime > deadline)
                    kill(Stop.timedOut);
        }
    }
}

/// Seconds an evaluation may take: HCAD_MCP_TIMEOUT, default 15 minutes.
auto evaluationTimeout()
{
    import core.time : seconds;
    import std.process : environment;
    return environment.get("HCAD_MCP_TIMEOUT", "900").strip.to!long.seconds;
}

/// Bytes the worker may use: HCAD_MCP_MEMORY_MB, default half of the RAM
/// (0 for no limit), so that a runaway model does not starve the system.
ulong memoryLimit()
{
    import std.process : environment;
    if (auto mb = environment.get("HCAD_MCP_MEMORY_MB"))
        return mb.strip.to!ulong << 20;
    version (OSX)
    {
        ulong bytes;
        size_t size = bytes.sizeof;
        return sysctlbyname("hw.memsize", &bytes, &size, null, 0) == 0 ? bytes / 2 : 0;
    }
    else version (Posix)
    {
        import core.sys.posix.unistd : sysconf, _SC_PHYS_PAGES, _SC_PAGE_SIZE;
        immutable pages = sysconf(_SC_PHYS_PAGES), size = sysconf(_SC_PAGE_SIZE);
        return pages > 0 && size > 0 ? cast(ulong) pages * size / 2 : 0;
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : MEMORYSTATUSEX, GlobalMemoryStatusEx;
        MEMORYSTATUSEX m;
        m.dwLength = m.sizeof;
        return GlobalMemoryStatusEx(&m) ? m.ullTotalPhys / 2 : 0;
    }
    else
        return 0;
}

/// Caps the memory of this process: allocations beyond it fail.
void limitMemory(ulong bytes)
{
    if (bytes == 0)
        return;
    version (linux)
    {
        // RLIMIT_DATA counts the heap and the private mappings, not the code
        import core.sys.posix.sys.resource : rlimit, setrlimit, RLIMIT_DATA;
        auto r = rlimit(bytes, bytes);
        setrlimit(RLIMIT_DATA, &r);
    }
    else version (Posix)
    {
        import core.sys.posix.sys.resource : rlimit, setrlimit, RLIMIT_AS;
        auto r = rlimit(bytes, bytes);
        setrlimit(RLIMIT_AS, &r);
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : CreateJobObjectW, SetInformationJobObject, AssignProcessToJobObject,
            GetCurrentProcess;
        import core.sys.windows.winnt : JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_PROCESS_MEMORY,
            JOBOBJECTINFOCLASS;
        auto job = CreateJobObjectW(null, null);
        if (job is null)
            return;
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_PROCESS_MEMORY;
        info.ProcessMemoryLimit = cast(size_t) bytes;
        if (SetInformationJobObject(job, JOBOBJECTINFOCLASS.JobObjectExtendedLimitInformation, &info, info.sizeof))
            AssignProcessToJobObject(job, GetCurrentProcess());
    }
}

/// After a call: frees the solids nobody uses any more (their OpenCascade
/// shapes are released by the finalizers, which the GC runs only when its
/// own small heap fills up) and gives the freed memory back to the system.
void releaseMemory()
{
    import core.memory : GC;
    GC.collect();
    GC.minimize();
    version (CRuntime_Glibc)
        malloc_trim(0);
}

version (CRuntime_Glibc)
    extern (C) int malloc_trim(size_t pad) nothrow @nogc;
version (OSX)
    extern (C) int sysctlbyname(const(char)* name, void* oldp, size_t* oldlenp, void* newp, size_t newlen) nothrow @nogc;

JSONValue result(JSONValue id, JSONValue r)
{
    JSONValue v = ["jsonrpc": "2.0"];
    v["id"] = id;
    v["result"] = r;
    return v;
}

JSONValue errorResponse(JSONValue id, int code, string message)
{
    JSONValue v = ["jsonrpc": "2.0"];
    v["id"] = id;
    JSONValue e = ["message": message];
    e["code"] = code;
    v["error"] = e;
    return v;
}

// ---------------------------------------------------------------- tools

JSONValue schema(string json) => parseJSON(json);

enum modelProps = `
    "source": {"type": "string", "description": "Model source (.hcad). If omitted, the file at 'path' is read."},
    "path": {"type": "string", "description": "Model file. With 'source', only used to resolve project imports."},
    "params": {"type": "object", "description": "Parameter overrides, name to value: numbers are in the model unit (mm), strings are .hcad expressions such as \"80.mm\" or \"\\\"text\\\"\".", "additionalProperties": {"type": ["string", "number", "boolean"]}},
    "preset": {"type": "string", "description": "Name of a @preset to apply."},
    "tolerance": {"type": "number", "description": "Mesh chord tolerance in mm for exported meshes and pictures (default 0.02; smaller is finer and slower)."},
    "printability": {"type": "boolean", "description": "For 3D printing: per part, the area of overhangs needing supports and of walls too thin to print (report 'printability'), marked in pictures (overhangs striped red, thin walls hatched violet)."},
    "overhang_angle": {"type": "number", "description": "printability: overhangs steeper than this many degrees from a wall need supports (default 45)."},
    "min_wall": {"type": "number", "description": "printability: walls thinner than this many mm do not print (default 0.8)."}`;

JSONValue[] toolList()
{
    JSONValue tool(string name, string description, string properties, string required = "[]")
    {
        JSONValue t = ["name": name, "description": description];
        t["inputSchema"] = schema(`{"type": "object", "properties": {` ~ properties ~ `}, "required": ` ~ required ~ `}`);
        return t;
    }

    enum oneObjectProp = `"one_object": {"type": "boolean", "description": "In a .3mf, the parts as the pieces of `
        ~ `one object (what slicers want for prints in several colours or materials); default an object each."}`;
    enum partsProp = `"parts": {"type": "array", "items": {"type": "string"}, "description": "Only these parts, by `
        ~ `function name or @part(name:); default every part but the export: false ones."}`;

    // the Examples menu's models: "carlo (Carlo), cup (...)" and their names in JSON
    auto exampleList = examples.map!(e => e.name ~ " (" ~ e.label ~ ")").join(", ");
    auto exampleEnum = examples.map!(e => `"` ~ e.name ~ `"`).join(", ");

    // every GUI tool can name the window, when several are open
    JSONValue gui(string name, string description, string properties, string required = "[]") =>
        tool(name, description, `"window": {"type": "string", "description": "Name of the hackerscad window (shown in `
            ~ `its header bar; hcad_gui_windows lists them). Needed only when several are open."}`
            ~ (properties.length ? ", " ~ properties : ""), required);

    return [
        tool("hcad_docs", "Reference of the .hcad language, the geometry API, conventions and examples. "
            ~ "Call it before writing a model; pass a topic (e.g. 'fillet', 'hardware', 'remodel') for a short excerpt "
            ~ "(a topic a heading names gives that whole section). format: "
            ~ "cheatsheet gives every function in one line each (compact), summary the short index (llms.txt), agents "
            ~ "and skill the agent guides, stamp which docs the server has (an installed skill showing another is out "
            ~ "of date: refresh it with format skill).",
            `"topic": {"type": "string"}, "format": {"type": "string", "enum": ["reference", "cheatsheet", "summary", "agents", "skill", "stamp"]}`),
        tool("hcad_check", "Evaluate a model: parts with bounding boxes and volumes, parameters, presets, "
            ~ "writeln output, errors with line/column/suggestion and failed unittest checks.", modelProps),
        tool("hcad_render", "Evaluate a model and return the same report as hcad_check plus a PNG of the parts "
            ~ "(default views: iso, front, top, right; 'parts' draws only some). Use it to verify the result visually.",
            modelProps ~ `, "views": {"type": "array", "items": {"type": "string", "enum": ["iso", "front", "back", "top", "bottom", "left", "right"]}}, `
            ~ partsProp),
        tool("hcad_export", "Evaluate a model and write it to 'output' (a path, or several to write from one "
            ~ "evaluation): .3mf (one object per part, with colours), .stl (one part), .zip (one STL per part), .step or "
            ~ ".stp (one named body per part), or .png (name.png the iso view, name-views.png iso/front/top/right, "
            ~ "name-top.png and so on one view); .svg, .pdf or .dxf write a @drawing (the first, or the one named by "
            ~ "'drawing').",
            modelProps ~ `, "output": {"type": ["string", "array"], "items": {"type": "string"}}, "drawing": {"type": "string"}, `
            ~ partsProp ~ `, ` ~ oneObjectProp, `["output"]`),
        tool("hcad_drawing", "Evaluate a model and return a @drawing as SVG text (views with hidden lines, sections, "
            ~ "dimensions, title block), to check it before exporting it as PDF or DXF.",
            modelProps ~ `, "drawing": {"type": "string", "description": "Name of the @drawing function; default the first."}`),
        tool("hcad_measure", "Minimum distance between two parts of a model (by function name or @part(name:)), with "
            ~ "the closest points; 0 when they touch or overlap.", modelProps ~ `, "a": {"type": "string"}, "b": {"type": "string"}`, `["a", "b"]`),
        tool("hcad_features", "What a part given as a mesh is made of, to remodel it exactly: flat faces (normal, "
            ~ "offset), holes and shafts (diameter, axis, length, ISO clearance or tap drill they match), cones "
            ~ "(countersinks), spheres, roundings (radius, angle), and holes repeated on a circle or in a row, with "
            ~ "plausible rounded sizes and the measured ones. 'path' is an .stl, .obj, .3mf or .step file (or an "
            ~ ".hcad model, 'part' one of its parts). Load the mesh as a see-through reference part "
            ~ "(@part(\"slategray\", alpha: 0.3, export: false) Solid original() => load(\"x.stl\");) to compare.",
            `"path": {"type": "string"}, "part": {"type": "string"}, `
            ~ `"json": {"type": "boolean", "description": "every surface as data too (long)"}`, `["path"]`),
        tool("hcad_literals", "The numbers written more than once in a model (path), with their lines, the most used "
            ~ "first, and the ones a constant is already named after; with original (a part of the model, or a mesh "
            ~ "file), which sizes of it each one is: a hole's diameter or radius, where an axis or a flat face is. The "
            ~ "last step of a copy that matches: name the measures that matter (@param, immutable) and use the names.",
            `"path": {"type": "string"}, "original": {"type": "string"}`, `["path"]`),
        tool("hcad_section", "The section of a part given as a mesh (.stl, .obj, .3mf, .step; or an .hcad model and "
            ~ "its 'part') by a plane xy, xz or yz at 'at' mm along z, y or x: its closed outlines as straight lines, "
            ~ "arcs and whole circles with their sizes (fitted to the cut, plausibly rounded), and the same as a "
            ~ "hackerscad sketch ready to paste and extrude. For parts that are extrusions, cut them across. "
            ~ "projection: true gives the outline of the part's shadow on the plane instead ('at' unused). compare: "
            ~ "another part of the .hcad model ('part' the copy, 'compare' the original): both sections drawn on each "
            ~ "other in a picture (the original thick grey, the copy thin orange) and both outlines as text. region: "
            ~ "[u0, v0, u1, v1] in the plane's axes keeps only the outlines inside it (a lettering, a pocket).",
            `"path": {"type": "string"}, "part": {"type": "string"}, "plane": {"type": "string", "enum": ["xy", "xz", "yz"]}, `
            ~ `"at": {"type": "number", "description": "mm along the plane's normal axis"}, "projection": {"type": "boolean"}, `
            ~ `"compare": {"type": "string"}, "region": {"type": "array", "items": {"type": "number"}, "minItems": 4, `
            ~ `"maxItems": 4, "description": "two opposite corners in the plane's axes: only the outlines inside"}`,
            `["path", "plane"]`),
        tool("hcad_compare", "How far a part of a model is from another (a remodelled part from the mesh it copies, "
            ~ "loaded as a see-through reference part: @part(\"slategray\", alpha: 0.3, export: false) Solid original() => "
            ~ "load(\"x.stl\");): the largest, mean and rms distance both ways, where the worst is, the share within "
            ~ "tolerance, and a picture of part a coloured by its distance from b: green within half the tolerance, "
            ~ "yellow at it, red at twice it. Correct the model until it is green.",
            modelProps ~ `, "a": {"type": "string"}, "b": {"type": "string"}, `
            ~ `"tolerance_mm": {"type": "number", "description": "the distance that counts as matching (default 0.1)"}, `
            ~ `"json": {"type": "boolean", "description": "the whole comparison as data, every patch (long)"}`, `["a", "b"]`),
        tool("hcad_scan", "Cut a part given as a mesh (.stl, .obj, .3mf, .step; or an .hcad model and its 'part') "
            ~ "all along an axis, every 'step' mm: each hole and pocket met with its shape (circle, rectangle, rounded "
            ~ "rectangle, hexagon (a nut trap), teardrop with the direction of its point, slot, D) and where it starts "
            ~ "and ends (found to a hundredth of a mm), and where the outside keeps one size. Scan along x, y and z "
            ~ "to see the part as the operations it was made with; then hcad_section at a level for exact outlines.",
            `"path": {"type": "string"}, "part": {"type": "string"}, "axis": {"type": "string", "enum": ["x", "y", "z"]}, `
            ~ `"step": {"type": "number", "description": "mm between cuts (default: the length / 200, at least 0.25)"}`, `["path", "axis"]`),
        tool("hcad_lines", "Compare a copy and its original as drawings, as the eye does: parts 'a' (the copy) and "
            ~ "'b' (the original) drawn as lines (sharp edges and outlines, hidden lines removed) from 62 directions "
            ~ "around them. Lists the lines only one has as places on the part, the most seen and longest first (a chamfer, a countersink, a "
            ~ "notch, a lettering: small in volume, long as lines), the surface facing more than 15° otherwise (twisted, "
            ~ "curved or tilted: what shading shows), and pictures of the 'views' (12) directions that show most of "
            ~ "them ('fixed': twelve that stay the same, to compare versions): grey in common, red only in the "
            ~ "original, blue only in the copy, violet the surface facing otherwise. 'voids': compare their holes, "
            ~ "pockets and cavities made solid instead (hidden inside, they show from outside). Use it from the first "
            ~ "comparison on, with hcad_diff: what it lists is what a person sees first, and what volumes miss. Fix "
            ~ "the outside first; only once it matches, "
            ~ "and only if something still differs, 'depth' (mm) peels both like an onion (that much cut away "
            ~ "towards each view) to compare the inside; the answer says when going deeper is no use.",
            modelProps ~ `, "a": {"type": "string"}, "b": {"type": "string"}, "views": {"type": "integer"}, `
            ~ `"depth": {"type": "number", "description": "mm cut away towards each view; 0 the outside (default)"}, `
            ~ `"fixed": {"type": "boolean"}, "voids": {"type": "boolean"}`, `["a", "b"]`),
        tool("hcad_diff", "Where a part of a model (a copy) differs from another (the original, e.g. a mesh loaded as a "
            ~ "see-through reference part), as pieces of material: what the copy lacks (to add) and what it has too much "
            ~ "of (to cut), largest first, each with its box, volume, centre of mass and how much of its box it fills (a "
            ~ "full box is a box() to add or cut), and for the largest the hcad_section (plane, at, compare) that shows "
            ~ "its shape. Both are filled into cubes of 'resolution' mm (default: the size / 250); differences thinner "
            ~ "than two cubes are listed apart, with how much they make (chamfers, lettering, notches: hcad_lines "
            ~ "shows them).",
            modelProps ~ `, "a": {"type": "string"}, "b": {"type": "string"}, "resolution": {"type": "number"}`, `["a", "b"]`),
        tool("hcad_fit", "Tune measures of a copy to its original: the @param lengths named in 'params' (of the .hcad "
            ~ "model at 'path') are moved, by the downhill simplex method, to make the volume where part 'a' (the copy) "
            ~ "and part 'b' (the original) differ as small as it goes. Returns the values found, the volume before and "
            ~ "after, and the -D overrides; then write them into the model. When the sizes take away little of the "
            ~ "difference it says so: the shape differs (cut sections elsewhere before fitting again). Each step "
            ~ "evaluates the model: a few parameters at a time (each evaluation takes a second or two).",
            `"path": {"type": "string"}, "a": {"type": "string"}, "b": {"type": "string"}, `
            ~ `"params": {"type": "array", "items": {"type": "string"}}, "evaluations": {"type": "integer"}`,
            `["path", "a", "b", "params"]`),
        tool("hcad_match", "The operations of a copy and its original (two parts of an .hcad model: 'a' the copy, 'b' "
            ~ "the original) matched one by one: the holes, shafts, cones, roundings, spheres and planes hcad_features "
            ~ "finds, and the holes and pockets met along x, y and z. Lists what is in the original and not in the copy, "
            ~ "in the copy and not in the original, and in both but different (a chamfer, a counterbore, a teardrop "
            ~ "where the original has a circle), the largest first; a hole cut in steps (a tapered nut trap) is one "
            ~ "entry, told as stepped; slivers under 1 mm² or mm³ are only counted.",
            `"path": {"type": "string"}, "a": {"type": "string"}, "b": {"type": "string"}`, `["path", "a", "b"]`),
        tool("hcad_gui_windows", "The hackerscad windows open on this computer: name (the user may call a window by it), "
            ~ "file, unsaved changes, whether it is evaluating. Pass the name as 'window' to the other hcad_gui_* tools.", ``),
        gui("hcad_gui_open", "Open a model file in the user's hackerscad window (it must be running). Refused when the "
            ~ "user has unsaved changes, unless force is true (which discards them: ask the user first).",
            `"path": {"type": "string"}, "force": {"type": "boolean"}`, `["path"]`),
        gui("hcad_gui_set", "Change the model shown in the user's window: replace its source, set parameter "
            ~ "overrides or a preset (preset \"\" goes back to the defaults, as Reset to defaults). A preset clears the "
            ~ "values set before; params given in the same call apply on top of it; reset lists parameters to take "
            ~ "back to the code's value (or the preset's), as the ↺ next to a changed parameter. The window "
            ~ "re-evaluates and shows the result; the state's overrides are the values changed by hand.",
            `"source": {"type": "string"}, "params": {"type": "object", "description": "Parameter values, name to value: `
            ~ `numbers are in the model unit (mm), strings are .hcad expressions such as \"80.mm\"."}, "preset": {"type": "string"}, `
            ~ `"reset": {"type": "array", "items": {"type": "string"}, "description": "parameter names back to their default"}`),
        gui("hcad_gui_pick", "Click in the user's 3D view at x, y (fractions of its size, 0..1) or at a model point: the "
            ~ "face is highlighted and the editor jumps to the feature that created it. Returns part, face, the point and "
            ~ "normal hit, and a selector expression for that face (e.g. faces.top) to use in code.",
            `"x": {"type": "number"}, "y": {"type": "number"}, ` ~ `"point": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3, "description": "a model point in mm instead of x, y: it must be visible"}, `
            ~ `"shift": {"type": "boolean", "description": "add to the selection (or remove from it), like Shift+click"}`, `[]`),
        gui("hcad_gui_view", "Move the user's 3D view as they do with the mouse, in this order: preset (iso, front, "
            ~ "top, right: framed on the model; fit: frame it from where it is now), look_at [x, y, z] (a model point in mm "
            ~ "to centre) and size (mm across the view), orbit [yaw, pitch] in degrees (like "
            ~ "dragging right and down), pan [x, y] in fractions of the view (the model moves right and down), zoom (2 = "
            ~ "twice as far, 0.5 closer) around the centre, or around at [x, y] like the wheel there (what is under it "
            ~ "stays still); look_at_face ({x, y} fractions of the view, or {point: [x, y, z]} in mm) turns the view "
            ~ "straight at the flat face there, from outside, as the user's double click on a face or Look at face in "
            ~ "the right-click menu does (after preset, before the rest). style draws the parts shaded with edges, shaded only or as a wireframe (hidden edges "
            ~ "faint); printability marks, over any style, the overhangs needing supports in red and the walls under "
            ~ "min_wall in violet (then hcad_gui_state has their areas per part); projection is perspective or orthographic; menu opens the parts (eye), display (cube) or views (View) "
            ~ "menu of the view bar, or the header bar's examples or export menu, for a screenshot, none closes them; sidebar shows the params or steps tab; "
            ~ "cursor puts the editor's cursor at the start of a line and scrolls there (for a picture: the sketch at "
            ~ "the cursor does not follow it; hcad_gui_edit goto does); code_width sets how wide "
            ~ "the code is (pixels); theme draws the window light or dark for this run (the user's own choice, in the "
            ~ "main menu, stays); drag is what a left drag does, rotate or pan; antialias turns the smoothing of "
            ~ "edges on or off for this run (hcad_gui_state's graphics tells whether it is on). "
            ~ "hidden lists the parts to hide (the others are shown); code, console, view and params show or hide "
            ~ "those panels. hcad_gui_state gives the camera.",
            `"preset": {"type": "string", "enum": ["iso", "front", "top", "right", "fit"]}, `
            ~ `"look_at": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}, `
            ~ `"look_at_face": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}, `
            ~ `"point": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}}}, `
            ~ `"size": {"type": "number"}, `
            ~ `"orbit": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}, `
            ~ `"pan": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}, `
            ~ `"zoom": {"type": "number"}, `
            ~ `"at": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}, `
            ~ `"style": {"type": "string", "enum": ["edges", "shaded", "wireframe"]}, `
            ~ `"printability": {"type": "boolean"}, `
            ~ `"select": {"type": "string", "enum": ["part", "face", "edge", "vertex"], "description": "what a click (and hcad_gui_pick, hcad_gui_menu) picks, as the view bar's selection buttons; the right-click menu offers what fits it (kept between runs)"}, `
            ~ `"shine": {"type": "string", "enum": ["none", "normal", "high"], "description": "how shiny the surfaces are: none matte (each flat face one even tone), normal a small highlight on curves, high a shiny material (kept between runs)"}, `
            ~ `"overhang_angle": {"type": "number", "description": "printability: degrees from a wall (45)"}, `
            ~ `"min_wall": {"type": "number", "description": "printability: thinnest wall in mm (0.8)"}, `
            ~ `"projection": {"type": "string", "enum": ["perspective", "orthographic"]}, `
            ~ `"menu": {"type": "string", "enum": ["parts", "display", "views", "examples", "export", "none"]}, `
            ~ `"sidebar": {"type": "string", "enum": ["params", "steps"]}, `
            ~ `"cursor": {"type": "integer"}, "code_width": {"type": "integer"}, `
            ~ `"hidden": {"type": "array", "items": {"type": "string"}}, `
            ~ `"grid": {"type": "boolean", "description": "show the ground grid (the eye's menu; kept between runs)"}, `
            ~ `"axes": {"type": "boolean", "description": "show the X and Y axes (the eye's menu; kept between runs)"}, `
            ~ `"code": {"type": "boolean"}, "console": {"type": "boolean"}, "view": {"type": "boolean"}, `
            ~ `"params": {"type": "boolean"}, `
            ~ `"theme": {"type": "string", "enum": ["system", "light", "dark"]}, `
            ~ `"drag": {"type": "string", "enum": ["rotate", "pan"]}, "antialias": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_new", "Start a new model in the user's window, as the New button: the template (a cube with two "
            ~ "holes), parameters and view reset; with example, one of the Examples menu instead (" ~ exampleList
            ~ "), unsaved. Refused when the user has unsaved "
            ~ "changes, unless force is true (which discards them: ask the user first). To copy an object from a "
            ~ "photo or a real part, ask for its sizes (and the font of any lettering) before starting one.",
            `"force": {"type": "boolean"}, "example": {"type": "string", "enum": [` ~ exampleEnum ~ `]}`, `[]`),
        tool("hcad_gui_launch", "Open a new hackerscad window on the user's screen, on the model at path (or a new "
            ~ "one), named name (or a random name): it returns once the window answers and has evaluated the model, "
            ~ "with its state; pass its window name to the other hcad_gui_* tools. Use it when the user wants to see "
            ~ "the work and no window is open (hcad_gui_windows), or wants a window of its own for it. To show an "
            ~ "example or a trial, pass code (the model's text) or copy (a file whose text is copied in) instead of "
            ~ "path: the window then works on no file, and the user's Save asks for a name, where a window on a file "
            ~ "(an example, the user's model) would save over it as they try things. A window of no file works in "
            ~ "the copied file's folder (or dir), so what the model loads (load(\"part.stl\")) is found there.",
            `"path": {"type": "string"}, "code": {"type": "string"}, "copy": {"type": "string"}, `
            ~ `"dir": {"type": "string", "description": "the folder a window of no file works in: load() reads `
            ~ `there and below (default: the copied file's folder; with code, the server's)"}, `
            ~ `"name": {"type": "string", "description": "letters, digits and dashes"}`),
        gui("hcad_gui_transform", "Move, turn or scale a part of the user's model, as Move…, Rotate… and Scale… in the "
            ~ "3D view's right-click menu: the code is written at the end of the part's chain (a .move(), .rotate() or "
            ~ ".scale() already there is changed instead). move: [x, y, z] in mm; rotate: {axis, angle in degrees}, about "
            ~ "the middle of the part's box; scale: a factor, or [x, y, z] factors, about the middle of the bottom of the "
            ~ "part's box (a part on the ground stays on it; written as .scale(1.5) or .scale(x: 1, y: 1, z: 2), with "
            ~ "around: when that point is not the origin). hinge: degrees about the axis through origin [x, y, z] (mm) along direction "
            ~ "[x, y, z], as Rotate around its normal / this edge (written as .rotate(30.deg, Y, around: …)). show: move, "
            ~ "rotate or scale shows the frame, the rings or the scale handles on the part for the user to drag (scale with show "
            ~ "scale: previewed with those factors, for the user to adjust and confirm), hinge (with origin and direction) "
            ~ "one ring about that axis (none takes them away), writing nothing. place: {from, from_normal, to, "
            ~ "to_normal, spin} as Place on…: the part turned so the face of outward normal from_normal lies against the "
            ~ "surface of outward normal to_normal, the point from on the point to (corners and middles of faces, or a "
            ~ "point of the ground with to_normal [0, 0, 1]), then spun by spin degrees about to_normal: written as "
            ~ ".placeOn(other().frame(faces…), from: faces…) when both faces are flat (it follows the other part), else as "
            ~ "turns and a move; with show: true "
            ~ "inside place, previewed with its ring for the user to spin and confirm, writing nothing. A piece of @parts moves, turns or "
            ~ "scales alone. part: its name (needed with several parts).",
            `"part": {"type": "string"}, "move": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}, `
            ~ `"scale": {"type": ["number", "array"], "items": {"type": "number"}, "minItems": 3, "maxItems": 3}, `
            ~ `"rotate": {"type": "object", "properties": {"axis": {"type": "string", "enum": ["x", "y", "z"]}, `
            ~ `"angle": {"type": "number"}}, "required": ["axis", "angle"]}, `
            ~ `"place": {"type": "object", "properties": {"from": {"type": "array", "items": {"type": "number"}}, `
            ~ `"from_normal": {"type": "array", "items": {"type": "number"}}, "to": {"type": "array", "items": {"type": "number"}}, `
            ~ `"to_normal": {"type": "array", "items": {"type": "number"}}, "spin": {"type": "number"}, "show": {"type": "boolean"}}}, `
            ~ `"hinge": {"type": "number"}, "origin": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}, `
            ~ `"direction": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}, `
            ~ `"show": {"type": "string", "enum": ["move", "rotate", "scale", "hinge", "none"]}`, `[]`),
        gui("hcad_gui_colour", "Colour a part of the user's model, as Colour in the 3D view's right-click menu: "
            ~ "the colour is written as the first argument of the part's @part (alpha:, name: and export: stay). "
            ~ "colour: one of hackerscad's own colours (bright, alike in brightness under the view's light; Sky Pop "
            ~ "is the default part colour; @part takes their names too) or #RRGGBB; or, as the menu's Other… "
            ~ "wheel, hue in degrees (OKLCH: 0 pink-red, 90 yellow, 150 green, 250 blue, 300 violet) with "
            ~ "lightness (0.45-0.95) and vividness (0-0.25), the palette's 0.76 and 0.15 when left out: every hue "
            ~ "then looks as bright as the palette's colours (written as #RRGGBB). wheel: true opens the wheel on "
            ~ "the part for the user, writing nothing. A piece of @parts (clip2) is coloured alone, with .color(…) "
            ~ "on that piece in the function; all: true colours the @parts annotation instead, which the pieces not "
            ~ "coloured on their own take. part: its name (needed with several parts).",
            `"part": {"type": "string"}, "colour": {"type": "string", "description": "Sky Pop, Blue Pop, Cyan Pop, `
            ~ `Violet Pop, Pink Pop, Rose Pop, Red Pop, Orange Pop, Yellow Pop, White Pop, Gray Pop, or #RRGGBB"}, `
            ~ `"hue": {"type": "number"}, "lightness": {"type": "number"}, "vividness": {"type": "number"}, `
            ~ `"wheel": {"type": "boolean"}, "all": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_split", "Split a part of the user's model, as Split… in the 3D view's right-click menu: the "
            ~ "part becomes a plain function, an immutable keeps the plane, and @parts(varied: true) Solid[] "
            ~ "<part>Pieces() => <part>().split(plane) takes its place: a part of each piece the cut leaves (more than "
            ~ "two when the plane crosses a slot), each in its own colour. plane: xy, xz or yz; at: where it is, in mm "
            ~ "along its normal (z for xy). show: true opens Split… "
            ~ "on the part for the user to place the plane and confirm with its ✓, writing nothing (false closes it). "
            ~ "part: its name (needed with several parts).",
            `"part": {"type": "string"}, "plane": {"type": "string", "enum": ["xy", "xz", "yz"]}, `
            ~ `"at": {"type": "number"}, "show": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_annotate", "Annotations on the user's 3D view, a whiteboard you share with the user: the view "
            ~ "locks (it cannot turn or zoom, and what it shows does not change meanwhile) and marks are drawn on "
            ~ "it as on a screenshot, staying on what they mark if the view is resized, to show what you mean (\"the hole goes here\", \"this wall is too thin\"). The user draws "
            ~ "too, in Annotate mode (the view bar's button, or A): arrows, crosses, circles, lines by hand, text; when "
            ~ "the user says \"here\" or \"this\", read the marks in the state. add (locks the view if needed; returns "
            ~ "the ids): items {\"arrow\": [tail, tip]}, {\"cross\": point} (a precise point), {\"circle\": point} (round "
            ~ "it; round a whole part when the point is its name), {\"circle\": [corner, corner]}, {\"circle\": "
            ~ "{\"center\": point, \"radius\": pixels}}, {\"freehand\": [points]}, {\"text\": \"…\", \"at\": point}; "
            ~ "each with colour (magenta by default, red, orange, yellow, green, blue, black, white or \"#RRGGBB\") "
            ~ "and label (a text beside it). A point is [x, y] as fractions of the view (0..1 from the top left), "
            ~ "{\"px\": [x, y]} in pixels, or, projected into the view, [x, y, z] in mm, a part's name (its centre "
            ~ "of mass) or {\"part\": name, \"face\": i} (that face's centre). remove: ids; clear: true (all), "
            ~ "\"agent\" (yours) or \"user\" (with none left the view goes live again, unless the user is "
            ~ "annotating); mode: true locks the view for the user to draw, false goes back to the live view and "
            ~ "drops every mark; list: true; save: an absolute .png path writes the view with its marks to a "
            ~ "picture, copy: true puts it on the clipboard (the bar's Save and Copy: for a person who is not "
            ~ "looking at the window). In one call: mode, clear, remove, add, then save and copy. Returns annotations: [{id, kind, "
            ~ "by (agent or user), points (fractions), colour, text or label, under}]: under is, for each key point "
            ~ "(an arrow's tip then its tail, a cross's or circle's centre, a text's point, a line's ends), what the "
            ~ "view shows there: part, face, point (mm), normal and a selector for the face, or part null. "
            ~ "While the view is annotated hcad_gui_view cannot move it, pick, inspect, rollback, step, sketch, "
            ~ "transform, split and menu are refused, and a changed model shows only once it is live again (the "
            ~ "camera where it was): after reading the user's marks, or when yours have served, set mode: false.",
            `"add": {"type": "array", "items": {"type": "object", "properties": {"kind": {"type": "string", "enum": `
            ~ `["arrow", "cross", "circle", "freehand", "text"]}, "points": {"type": "array"}, "at": {}, `
            ~ `"arrow": {"type": "array"}, "cross": {}, "circle": {}, "freehand": {"type": "array"}, `
            ~ `"text": {"type": "string"}, "label": {"type": "string"}, "colour": {"type": "string"}}}}, `
            ~ `"remove": {"type": "array", "items": {"type": "integer"}}, "clear": {"type": ["boolean", "string"]}, `
            ~ `"list": {"type": "boolean"}, "mode": {"type": "boolean"}, "save": {"type": "string"}, "copy": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_rename", "Rename the user's window (the name in its header bar, which the user and the "
            ~ "'window' argument use): letters, digits and dashes.", `"name": {"type": "string"}`, `["name"]`),
        gui("hcad_gui_feature", "Point at the user's 3D view (x, y as fractions of its size, or a model point) and add a feature there, "
            ~ "like the right-click menu: the code (with a stable selector) is appended to the part in the editor. Actions: "
            ~ "fillet-edge, chamfer-edge, fillet-face (all edges of the face), chamfer-face, shell (opens the face), "
            ~ "draft (tilts the face), extrude-face (grows a flat face outwards, value the depth), cut-face (sinks it into the material), thread (an ISO metric thread on a cylindrical face, size e.g. M8: the shaft's diameter, or for a hole the size it is the tap drill of), hole (kind and size: a hole for a screw, 5 mm deep), pocket (a rectangle cut "
            ~ "in), boss (a cylinder standing on the face), sketch (Sketch on face…: the part's function keeps its "
            ~ "solid in a variable and starts an empty sketch on that flat face, its edges as references; add its "
            ~ "geometry and then cut or extrude its profile with hcad_gui_edit). With use_selection: true it acts on the Shift selection "
            ~ "(hcad_gui_pick with shift) that contains the point, as the menu does: several edges or faces at once.",
            `"x": {"type": "number"}, "y": {"type": "number"}, ` ~ `"point": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3, "description": "a model point in mm instead of x, y: it must be visible"}, `
            ~ `"action": {"type": "string", "enum": ["fillet-edge", "chamfer-edge", "fillet-face", "chamfer-face", `
            ~ `"shell", "draft", "extrude-face", "cut-face", "thread", "hole", "pocket", "boss", "sketch"]}, "value": {"type": "string", "description": `
            ~ `"radius, distance, thickness, angle or depth, e.g. 2.mm or -4.deg"}, `
            ~ `"kind": {"type": "string", "enum": ["clearance", "tap", "insert"]}, `
            ~ `"size": {"type": "string", "description": "ISO metric size: M2, M2.5, M3, M4, M5, M6 or M8 for holes; any that fits the cylinder for thread (M10, M12…)"}, `
            ~ `"use_selection": {"type": "boolean"}`, `["action"]`),
        gui("hcad_gui_menu", "Right-click the user's 3D view at x, y (fractions of its size) or at a model point and "
            ~ "choose entries of the menu in order, e.g. [\"Hole at point\", \"Clearance\", \"M3\"] or [\"Fillet edge…\"]: "
            ~ "what the user would do with the mouse. Entries that write code append it to the part in the editor. "
            ~ "Without path, returns the entries the menu has there (with sub-entries and the values it shows) and "
            ~ "chooses nothing. With open: true the menu stays open (path: only groups to open), to show it in "
            ~ "hcad_gui_screenshot. On empty space the menu lists the hidden parts. Entries that copy (Measure, "
            ~ "Copy as code) also return the text as copied. On a face made from a sketch's profile, Edit sketch… "
            ~ "shows the sketch and puts the cursor on its sketch() line. bar: \"view\" is the view bar's View menu "
            ~ "instead (no point): Iso, Top, Front, Right and Sketches, one entry per sketch of the model (\"line 12 · "
            ~ "4 dimensions · fully constrained\"), e.g. path [\"Sketches\", \"line 12 · 4 dimensions · fully "
            ~ "constrained\"] opens it.",
            `"x": {"type": "number"}, "y": {"type": "number"}, ` ~ `"point": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3, "description": "a model point in mm instead of x, y: it must be visible"}, `
            ~ `"path": {"type": "array", "items": {"type": "string"}}, "open": {"type": "boolean"}, `
            ~ `"bar": {"type": "string", "enum": ["view"], "description": "a menu of the view bar instead of the right-click menu"}`, `[]`),
        gui("hcad_gui_section", "Cut the user's 3D view with a plane: parallel to xy, xz or yz, or to the selected face "
            ~ "(face; clicking another face moves it there); without plane, the plane shown stays (xy when none is); at is "
            ~ "the position from 0 to 1 across the model; flip: true shows the other side, false the first one; cut solids "
            ~ "are shown filled and hatched; on: false removes it.",
            `"plane": {"type": "string", "enum": ["xy", "xz", "yz", "face"]}, "at": {"type": "number"}, `
            ~ `"flip": {"type": "boolean"}, "on": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_sketch", "Show a sketch in the user's 3D view, seen from above (a sketch on a face: from outside that face, the "
            ~ "face's edges and what s.project gave drawn in violet as references), with its dimensions (the user "
            ~ "can click them to change them) and the points that can still move in blue, as selecting its step or "
            ~ "inspecting one of its lines does. line (to to_line) is any line of a sketch: the sketch() call, its "
            ~ ".profile, an s.point/line/arc/circle/ellipse/polyline/rect/polygon/slot/teardrop call or a constraint call; what "
            ~ "those lines make, and the entities "
            ~ "their constraints involve (and their dimensions), are drawn in orange. Without line, the first sketch "
            ~ "whole; on: false hides it (Esc, or hcad_gui_rollback with {}, also does). The reply's sketch tells "
            ~ "the one shown: degrees_of_freedom, free_points (line, x, y) and, for a line, made (the entities it "
            ~ "makes: id, kind (point, line, arc, circle or ellipse), line; a shape such as s.rect makes several, "
            ~ "with their constraints), constraints (kind: the method, e.g. tangent, concentric, horizontal; line, "
            ~ "the entity ids they involve, their dimension) and "
            ~ "highlighted (every entity in orange). sketches lists all of them: solved, degrees_of_freedom, "
            ~ "free_points, and the dimensions with their label, the line and col of their value in the code, the value "
            ~ "and conflicting when the constraints disagree, stale for the last good sketch (shown, faint, while "
            ~ "the code has an error in it) and partial for one made before an error stopped the run. "
            ~ "The window also shows the sketch whose code the editor's cursor is in (hcad_gui_edit with goto moves the "
            ~ "cursor): follow: false turns that off, true on (the display menu's Show the sketch at the cursor, kept "
            ~ "between runs); pin: true keeps the sketch shown from the cursor when the cursor leaves its code. A line "
            ~ "given here takes the view over from the cursor until Esc or on: false. align: true turns the view "
            ~ "straight back at the sketch shown (Look at sketch in the right-click menu: from outside its face, or "
            ~ "from above), after the user or you turned it. state's sketch tells from_cursor, "
            ~ "pinned, partial, stale (and error_line).",
            `"line": {"type": "integer"}, "to_line": {"type": "integer"}, "on": {"type": "boolean"}, `
            ~ `"follow": {"type": "boolean"}, "pin": {"type": "boolean"}, "align": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_step", "Click a row of the Steps panel in the user's window: the model as it was after that "
            ~ "step (its new faces in orange; for a union or difference, its two operands coloured; for a line run "
            ~ "several times, every run), what a value row made, or what a function returns; the step of a sketch "
            ~ "(or of what its .profile made on that line) also shows the sketch, as hcad_gui_sketch. row is 0-based, in the "
            ~ "order of the steps list of hcad_gui_state with source: true; headings are not rows to click. "
            ~ "hcad_gui_rollback with {} (or Esc) goes back to the final model.",
            `"row": {"type": "integer"}`, `["row"]`),
        gui("hcad_gui_dimension", "Change a sketch dimension in the user's window, as clicking it and typing: the "
            ~ "value at line and col (from hcad_gui_sketch) becomes value, e.g. \"40.mm\". With edit: true instead "
            ~ "of value, its field opens where the label is, as a click on it does, for the user to type in (the "
            ~ "sketch must be shown).",
            `"line": {"type": "integer"}, "col": {"type": "integer"}, "value": {"type": "string"}, "edit": {"type": "boolean"}`,
            `["line", "col"]`),
        gui("hcad_gui_rollback", "Show the user's model as it was right after the feature on a line of code (its new "
            ~ "faces in orange, the final parts as ghosts); without line, back to the final model.",
            `"line": {"type": "integer"}`, `[]`),
        gui("hcad_gui_inspect", "Show in the user's 3D view what a line of code made (Inspect): the solids, 2D profiles "
            ~ "(where they were drawn, before being extruded or placed) and paths of its calls in orange, the final parts "
            ~ "as ghosts. line to to_line covers several lines; function shows what that function returns. On the line "
            ~ "declaring a function, what it returns. On the lines of a sketch (the sketch() call, .profile, "
            ~ "s.line(…), s.ellipse(…), s.rect(…), s.tangent(…)…) the sketch is shown too, with what they make or "
            ~ "constrain in orange. "
            ~ "Without arguments, back to the final model. Returns the state, whose inspect lists the items shown "
            ~ "(line, function, kind, calls, bounding box) and, on a sketch's lines, sketch: the entities and "
            ~ "constraints highlighted, as hcad_gui_sketch tells them.",
            `"line": {"type": "integer"}, "to_line": {"type": "integer"}, "function": {"type": "string"}`, `[]`),
        gui("hcad_gui_export", "Export the model open in the user's window, with the parameters and preset set "
            ~ "there, to 'path': .3mf (one object per part, colours), .stl (one part), .zip (one STL per part), "
            ~ ".step (one named body per part) or .png (the 3D view as shown; with 'parts', those alone). Drawings "
            ~ "(.svg, .pdf, .dxf) are made by hcad_export on the file.",
            `"path": {"type": "string"}, ` ~ partsProp ~ `, ` ~ oneObjectProp, `["path"]`),
        gui("hcad_gui_complete", "What the editor's completion offers in the user's window: at the cursor, or at "
            ~ "line and col (1-based). Gives the proposals with their signature and documentation, and inside a call "
            ~ "the callee's signature and the argument the cursor is on, with forms: its ways to be called, simplest "
            ~ "first, when its parameters are alternatives (rotate, cylinder, move…).",
            `"line": {"type": "integer"}, "col": {"type": "integer"}, `
            ~ `"show": {"type": "boolean", "description": "also move the cursor there and open the list in the window"}, `
            ~ `"select": {"type": "string", "description": "with show, the entry to select in the list"}`, `[]`),
        gui("hcad_gui_cheatsheet", "Opens the cheatsheet window in the user's GUI (every function and object in "
            ~ "one line, and \"how do I…\" recipes), filtered by query when given: to show the user where to look.",
            `"query": {"type": "string"}`, `[]`),
        gui("hcad_gui_edit", "Change the code in the user's editor like typing does (Ctrl+Z undoes it, and the window "
            ~ "re-evaluates): old and new replace text that appears exactly once; lines [from, to] and text replace those "
            ~ "lines (1-based, inclusive); insert (a line number) and text insert before that line (one more than the "
            ~ "line count appends). Returns the state and the lines of the new text. action (comment, duplicate, delete, "
            ~ "move_up, move_down, indent, unindent) with lines does what the editor's keys do to those lines (Ctrl+/, "
            ~ "Ctrl+D, Ctrl+Shift+K, Alt+Up, Alt+Down, Tab, Shift+Tab); goto (a line) puts the cursor there as the user "
            ~ "would: in a sketch's code, the view shows that sketch (unless something chosen is shown: a step, Inspect, "
            ~ "a section).",
            `"old": {"type": "string"}, "new": {"type": "string"}, `
            ~ `"lines": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2}, `
            ~ `"insert": {"type": "integer"}, "text": {"type": "string"}, "goto": {"type": "integer"}, `
            ~ `"action": {"type": "string", "enum": ["comment", "duplicate", "delete", "move_up", "move_down", "indent", "unindent"]}`, `[]`),
        gui("hcad_gui_find", "Find in the code of the user's editor, as its find bar (Ctrl+F): the matches of text, with "
            ~ "line and column (regex, case, word as its options); with replace, every match is replaced, as its "
            ~ "Replace all (one step of Undo), and the window re-evaluates; show: true opens the find bar on text (and "
            ~ "replace) for the user instead, replacing nothing.",
            `"text": {"type": "string"}, "replace": {"type": "string"}, "regex": {"type": "boolean"}, "show": {"type": "boolean"}, `
            ~ `"case": {"type": "boolean"}, "word": {"type": "boolean"}`, `["text"]`),
        gui("hcad_gui_undo", "Undo the last change of the code in the user's editor (theirs or yours), or redo with "
            ~ "redo: true; steps repeats it.", `"redo": {"type": "boolean"}, "steps": {"type": "integer"}`, `[]`),
        gui("hcad_gui_project", "Convert between the model and the user's 3D view: points (model points in mm) give "
            ~ "where they appear as fractions of the view and whether they are visible; screen ([x, y] fractions) gives "
            ~ "what is there: part, face, point, normal and a selector. Use it to aim pick, menu and feature, or to frame.",
            `"points": {"type": "array", "items": {"type": "array", "items": {"type": "number"}}}, `
            ~ `"screen": {"type": "array", "items": {"type": "array", "items": {"type": "number"}}}`, `[]`),
        gui("hcad_gui_selection", "The faces or edges selected in the user's 3D view, with their selectors and sizes "
            ~ "(area, centre and normal of a face; length or radius of an edge): what the user means by \"this edge\". "
            ~ "With selector (e.g. faces.top, edges.of(faces.top)) on part, selects what it picks, to show the user "
            ~ "which faces or edges you mean; the right-click menu then acts on them. clear: true empties it.",
            `"selector": {"type": "string"}, "part": {"type": "string", "description": "needed with several parts"}, `
            ~ `"clear": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_measure", "Measure in the user's window: the distance between a and b (part names, or points "
            ~ "[x, y, z]), with the closest points; without a and b, between the two selected items, with the angle "
            ~ "between them and, for parallel flat faces, the gap between their planes (a wall's thickness).",
            `"a": {"type": ["string", "array"]}, "b": {"type": ["string", "array"]}`, `[]`),
        gui("hcad_gui_save", "Save the model in the user's window to its file, or to path (the window then works on "
            ~ "that file, like Save As). Refused when path exists, unless force is true (ask the user first).",
            `"path": {"type": "string"}, "force": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_stop", "Stop the evaluation running in the user's window (hcad_gui_state tells whether one is "
            ~ "running and at which stage); it runs again at the next edit.", ``),
        gui("hcad_gui_test", "Run the model's unittests in the user's window, as its bug button and F5 do (the window "
            ~ "does not run them at every change): returns how many it has, how many failed, and the state with the "
            ~ "problems.", ``),
        gui("hcad_gui_about", "Open the About window of the user's hackerscad (version, credits, licences); close: true "
            ~ "closes it; debug: true returns the debug information its Copy button copies (versions, system, screen, "
            ~ "renderer, frame times, fonts, model size) without opening it.",
            `"close": {"type": "boolean"}, "debug": {"type": "boolean"}`),
        gui("hcad_gui_screenshot", "Picture of the user's hackerscad window, after the current evaluation finishes; "
            ~ "target cheatsheet pictures the cheatsheet window instead (open it with hcad_gui_cheatsheet), colour "
            ~ "the colour wheel (open it with hcad_gui_colour, wheel: true), about the About window (hcad_gui_about).",
            `"target": {"type": "string", "enum": ["window", "cheatsheet", "colour", "about"]}`, `[]`),
        gui("hcad_gui_state", "State of the user's window: file, parameters, parts, camera, problems, version; "
            ~ "annotations lists the marks drawn on the locked 3D view, the user's (by: user) and yours, each with "
            ~ "what lies under its key points (part, face, point in mm, selector; see hcad_gui_annotate), "
            ~ "annotate_mode whether the view is annotated, annotated_view its size and whether the model changed "
            ~ "since: when the user says \"here\", \"this\" or \"there\", look at them first; "
            ~ "user_changed tells which lines the user changed since your previous hcad_gui_* call. It waits for the "
            ~ "running evaluation; with now: true it answers at once, with evaluating, stage (e.g. part 3 of 12: gear) "
            ~ "and seconds; with source: true it includes the code as it is in the editor (maybe not saved) and steps, "
            ~ "the Steps panel row by row. cursor is the editor's cursor (line, col); sketch the sketch shown (from_cursor, "
            ~ "pinned, partial, stale) and sketch_follow the setting Show the sketch at the cursor. params give value, "
            ~ "default, type, min, max, step and choices; revision "
            ~ "counts the evaluations, log is what the model printed, outdated says the window should be restarted; "
            ~ "graphics tells what draws the 3D view (OpenGL renderer, software: true when the processor draws it) "
            ~ "and how fast: frames gives, over the last frames drawn while the view moved (hcad_gui_view counts), "
            ~ "the wait from the movement to the frame (wait_ms; slow counts those over 33 ms, the jerks a user "
            ~ "sees), the time apart (interval_ms: also long when the movements come slowly), on the processor "
            ~ "(draw_ms) and on the graphics card (gpu_ms, -1 when not known), each with its _max_ms.",
            `"now": {"type": "boolean"}, "source": {"type": "boolean"}`, `[]`),
    ];
}

JSONValue callTool(string name, JSONValue args)
{
    JSONValue[] content;
    bool isError;

    void text(string s)
    {
        content ~= JSONValue(["type": "text", "text": s]);
    }

    void image(const(ubyte)[] png)
    {
        JSONValue c = ["type": "image", "mimeType": "image/png"];
        c["data"] = Base64.encode(png).idup;
        content ~= c;
    }

    string arg(string key) => args.type == JSONType.object && key in args && args[key].type == JSONType.string
        ? args[key].str : null;

    switch (name)
    {
    case "hcad_docs":
        {
            import hackerscad.tool.cheatsheet : cheatsheetMarkdown;
            switch (arg("format"))
            {
            case "cheatsheet": text(cheatsheetMarkdown()); break;
            case "summary": text(summaryText()); break;
            case "agents": text(agentsText()); break;
            case "skill": text(skillText()); break;
            case "stamp": text(docsStamp()); break;
            case null, "reference": text(reference(arg("topic"))); break;
            default: throw new Exception("format must be reference, cheatsheet, summary, agents, skill or stamp");
            }
            break;
        }
    case "hcad_check", "hcad_render", "hcad_export":
        {
            auto run = evaluateModel(options(args));
            isError = run.hasErrors;
            string[] only;
            if (args.type == JSONType.object && "parts" in args && args["parts"].type == JSONType.array)
                foreach (v; args["parts"].array)
                    only ~= v.str;
            if (name == "hcad_export" && run.ok)
            {
                // one file, or several from one evaluation
                string[] outputs;
                if (args.type == JSONType.object && "output" in args && args["output"].type == JSONType.array)
                    foreach (v; args["output"].array)
                        outputs ~= v.str;
                else if (arg("output").length)
                    outputs = [arg("output")];
                enforce(outputs.length, "missing 'output'");
                immutable oneObject = args.type == JSONType.object && "one_object" in args
                    && args["one_object"].type == JSONType.true_;
                foreach (output; outputs)
                {
                    run.exportTo(output, only, oneObject);
                    text("written " ~ output);
                }
            }
            text(run.report().toPrettyString(JSONOptions.doNotEscapeSlashes));
            auto diags = run.renderedDiagnostics();
            if (diags.length)
                text(diags);
            if (name == "hcad_render" && run.ok && run.result.parts.length)
                image(run.png(views(args), 450, only.length ? run.partIndices(only, true) : null));
            break;
        }
    case "hcad_drawing":
        {
            import hackerscad.drawing.sheet : toSvg;
            import hackerscad.lang.errors : HcadError;
            auto run = evaluateModel(options(args));
            isError = !run.ok;
            if (run.ok)
            {
                try
                    text(toSvg(run.drawingSheet()));
                catch (HcadError e)
                {
                    isError = true;
                    text(e.msg);
                }
            }
            else
                text(run.renderedDiagnostics());
            break;
        }
    case "hcad_features":
        {
            import hackerscad.tool.features : meshOf, featuresJson;
            import hackerscad.geom.meshfeatures : analyse, report;
            try
            {
                auto a = analyse(meshOf(arg("path"), arg("part")));
                if (auto js = "json" in args)
                    if (js.type == JSONType.true_)
                    {
                        text(report(a) ~ "\n" ~ featuresJson(a).toPrettyString(JSONOptions.doNotEscapeSlashes));
                        break;
                    }
                text(report(a) ~ "(json: true gives every surface as data)\n");
            }
            catch (Exception e)
            {
                isError = true;
                text(e.msg);
            }
            break;
        }
    case "hcad_literals":
        {
            import hackerscad.tool.literals : literalsReport;
            try
                text(literalsReport(arg("path"), arg("original")));
            catch (Exception e)
            {
                isError = true;
                text(e.msg);
            }
            break;
        }
    case "hcad_section":
        {
            import hackerscad.tool.features : sectionReport, sectionOverlay, projectionReport;
            try
            {
                auto at = "at" in args;
                immutable level = at is null ? 0 : at.type == JSONType.integer ? at.integer : at.floating;
                double[] region;
                if (auto rg = "region" in args)
                    if (rg.type == JSONType.array)
                        foreach (x; rg.array)
                            region ~= x.type == JSONType.integer ? x.integer : x.floating;
                if (arg("compare").length)
                {
                    string t;
                    auto png = sectionOverlay(arg("path"), arg("part"), arg("compare"), arg("plane"), level, t);
                    text(t);
                    image(png);
                }
                else if (auto pr = "projection" in args)
                {
                    if (pr.type == JSONType.true_)
                        text(projectionReport(arg("path"), arg("part"), arg("plane")));
                    else
                        text(sectionReport(arg("path"), arg("part"), arg("plane"), level, region));
                }
                else
                    text(sectionReport(arg("path"), arg("part"), arg("plane"), level, region));
            }
            catch (Exception e)
            {
                isError = true;
                text(e.msg);
            }
            break;
        }
    case "hcad_compare":
        {
            auto run = evaluateModel(options(args));
            isError = !run.ok;
            if (!run.ok)
            {
                text(run.renderedDiagnostics());
                break;
            }
            import hackerscad.lang.errors : HcadError;
            size_t ia, ib;
            try
            {
                ia = run.partIndices([arg("a")], true)[0];
                ib = run.partIndices([arg("b")], true)[0];
            }
            catch (HcadError e)
            {
                isError = true;
                text(e.msg ~ (e.diag.suggestion.length ? " (" ~ e.diag.suggestion ~ ")" : ""));
                break;
            }
            double tol = 0.1;
            if (auto t = "tolerance_mm" in args)
                tol = t.type == JSONType.integer ? t.integer : t.floating;
            ubyte[] png;
            auto j = run.compare(ia, ib, tol, png);
            auto js = "json" in args;
            text(js && js.type == JSONType.true_ ? j.toPrettyString()
                : Run.compareText(j, run.result.parts[ia].name, run.result.parts[ib].name));
            image(png);
            break;
        }
    case "hcad_scan":
        {
            import hackerscad.tool.features : scanReport;
            try
            {
                auto st = "step" in args;
                text(scanReport(arg("path"), arg("part"), arg("axis"),
                    st is null ? 0 : st.type == JSONType.integer ? st.integer : st.floating));
            }
            catch (Exception e)
            {
                isError = true;
                text(e.msg);
            }
            break;
        }
    case "hcad_lines":
        {
            auto run = evaluateModel(options(args));
            isError = !run.ok;
            if (!run.ok)
            {
                text(run.renderedDiagnostics());
                break;
            }
            import hackerscad.lang.errors : HcadError;
            try
            {
                auto v = "views" in args;
                ubyte[] png;
                text(run.lines(run.partIndices([arg("a")], true)[0], run.partIndices([arg("b")], true)[0],
                    "depth" !in args ? 0.0 : args["depth"].type == JSONType.integer ? args["depth"].integer
                    : args["depth"].floating, v is null ? 12 : cast(size_t) v.integer,
                    "fixed" in args && args["fixed"].type == JSONType.true_, "voids" in args && args["voids"].type == JSONType.true_,
                    png));
                image(png);
            }
            catch (HcadError e)
            {
                isError = true;
                text(e.msg);
            }
            break;
        }
    case "hcad_diff":
        {
            auto run = evaluateModel(options(args));
            isError = !run.ok;
            if (!run.ok)
            {
                text(run.renderedDiagnostics());
                break;
            }
            import hackerscad.lang.errors : HcadError;
            try
            {
                auto res = "resolution" in args;
                text(run.differences(run.partIndices([arg("a")], true)[0], run.partIndices([arg("b")], true)[0],
                    res is null ? 0 : res.type == JSONType.integer ? res.integer : res.floating));
            }
            catch (HcadError e)
            {
                isError = true;
                text(e.msg);
            }
            break;
        }
    case "hcad_fit":
        {
            import hackerscad.tool.fitting : fit;
            try
            {
                string[] names;
                if (auto ps = "params" in args)
                    foreach (v; ps.array)
                        names ~= v.str;
                auto ev = "evaluations" in args;
                text(fit(arg("path"), arg("a"), arg("b"), names, ev is null ? 60 : cast(int) ev.integer));
            }
            catch (Exception e)
            {
                isError = true;
                text(e.msg);
            }
            break;
        }
    case "hcad_match":
        {
            import hackerscad.tool.features : matchReport;
            try
                text(matchReport(arg("path"), arg("a"), arg("b")));
            catch (Exception e)
            {
                isError = true;
                text(e.msg);
            }
            break;
        }
    case "hcad_measure":
        {
            auto run = evaluateModel(options(args));
            isError = !run.ok;
            if (run.ok)
            {
                import hackerscad.geom.vec : Vec3;
                import hackerscad.lang.errors : HcadError;
                import hackerscad.kernel.brep : Brep;
                Brep a, b;
                try
                {
                    a = run.result.parts[run.partIndices([arg("a")], true)[0]].solid.brep;
                    b = run.result.parts[run.partIndices([arg("b")], true)[0]].solid.brep;
                }
                catch (HcadError e)
                {
                    isError = true;
                    text(e.msg ~ (e.diag.suggestion.length ? " (" ~ e.diag.suggestion ~ ")" : ""));
                    break;
                }
                Vec3 pa, pb;
                immutable d = run.kernel.distance(a, b, pa, pb);
                JSONValue j = ["distance_mm": d];
                j["point_a"] = [pa.x, pa.y, pa.z];
                j["point_b"] = [pb.x, pb.y, pb.z];
                text(j.toPrettyString());
            }
            else
                text(run.renderedDiagnostics());
            break;
        }
    case "hcad_gui_open", "hcad_gui_set", "hcad_gui_state", "hcad_gui_pick", "hcad_gui_view", "hcad_gui_sketch",
            "hcad_gui_new", "hcad_gui_rename", "hcad_gui_dimension", "hcad_gui_step", "hcad_gui_rollback", "hcad_gui_inspect", "hcad_gui_feature", "hcad_gui_section", "hcad_gui_menu", "hcad_gui_about", "hcad_gui_test", "hcad_gui_find", "hcad_gui_stop", "hcad_gui_save", "hcad_gui_export",
            "hcad_gui_edit", "hcad_gui_undo", "hcad_gui_project", "hcad_gui_selection", "hcad_gui_measure", "hcad_gui_complete", "hcad_gui_cheatsheet",
            "hcad_gui_transform", "hcad_gui_colour", "hcad_gui_split", "hcad_gui_annotate":
        {
            auto method = name["hcad_gui_".length .. $];
            auto r = guiRequest(arg("window"), method, args.type == JSONType.object ? args : JSONValue((JSONValue[string]).init));
            text(r.toPrettyString(JSONOptions.doNotEscapeSlashes));
            break;
        }
    case "hcad_gui_launch":
        {
            // code, or a copy of a file: a model of no file, so the user's Save cannot overwrite anything
            string code = arg("code");
            string dir = arg("dir");
            if (code is null && arg("copy") !is null)
            {
                import std.file : exists, readText;
                import std.path : absolutePath, dirName;
                if (!exists(arg("copy")))
                    return toolError("no file " ~ arg("copy") ~ " to copy");
                code = readText(arg("copy"));
                // in the copied file's folder: what it loads is found as it is there
                if (dir is null)
                    dir = dirName(absolutePath(arg("copy")));
            }
            if (code !is null && arg("path") !is null)
                return toolError("give path (the window works on that file) or code / copy (a window of no file), not both");
            if (dir !is null)
            {
                import std.file : exists, isDir;
                import std.path : absolutePath;
                if (arg("path") !is null)
                    return toolError("dir is for a window of no file (code or copy): a window on a file works in its folder");
                if (!exists(dir) || !isDir(dir))
                    return toolError("no folder " ~ dir);
                dir = absolutePath(dir);
            }
            auto r = launchWindow(code !is null ? null : arg("path"), arg("name"), code, dir);
            if (r.type == JSONType.string)
                return toolError(r.str);
            text(r.toPrettyString(JSONOptions.doNotEscapeSlashes));
            break;
        }
    case "hcad_gui_windows":
        {
            JSONValue[] list;
            foreach (w; openWindows())
            {
                JSONValue now = ["now": true];
                try
                {
                    auto st = guiRequest(w, "state", now);
                    JSONValue e = ["name": w];
                    foreach (k; ["path", "modified", "evaluating", "version", "outdated"])
                        if (k in st)
                            e[k] = st[k];
                    list ~= e;
                }
                catch (Exception)
                {
                }
            }
            text(list.length ? JSONValue(list).toPrettyString(JSONOptions.doNotEscapeSlashes)
                : "no hackerscad window is open: open one with hcad_gui_launch (or the user starts it with "
                ~ "`hackerscad model.hcad`)");
            break;
        }
    case "hcad_gui_screenshot":
        {
            auto file = buildPath(tempDir, format("hackerscad-shot-%s.png", randomName()));
            JSONValue p = ["path": file];
            if (auto t = arg("target"))
                p["target"] = t;
            auto r = guiRequest(arg("window"), "screenshot", p);
            if (exists(file))
            {
                image(cast(ubyte[]) read(file));
                remove(file);
            }
            text(r.toPrettyString(JSONOptions.doNotEscapeSlashes));
            break;
        }
    default:
        throw new Exception("unknown tool: " ~ name);
    }
    JSONValue r = ["content": content];
    r["isError"] = isError;
    return r;
}

// the server is long-lived: agents iterating on a model reuse unchanged geometry
CachingKernel sharedCache;

RunOptions options(JSONValue args)
{
    RunOptions o;
    if (sharedCache is null)
        sharedCache = new CachingKernel(new OcctKernel);
    o.cache = sharedCache;
    if (args.type != JSONType.object)
        return o;
    if (auto p = "path" in args) o.path = p.str;
    if (auto s = "source" in args) o.source = s.str;
    if (auto p = "preset" in args) o.preset = p.str;
    if (auto p = "drawing" in args) o.drawing = p.str;
    if (auto t = "tolerance" in args)
    {
        o.tolerance = t.type == JSONType.integer ? t.integer : t.floating;
        enforce(o.tolerance > 0, "'tolerance' must be a positive number of mm");
    }
    if (auto ps = "params" in args)
        o.overrides = toOverrides(*ps);
    double number(JSONValue v) => v.type == JSONType.integer ? v.integer : v.floating;
    if (auto v = "printability" in args)
        o.printability = v.type == JSONType.true_;
    if (auto v = "overhang_angle" in args)
    {
        o.overhangAngle = number(*v);
        enforce(o.overhangAngle >= 0 && o.overhangAngle < 90, "'overhang_angle' is in degrees from 0 to 90");
    }
    if (auto v = "min_wall" in args)
    {
        o.minWall = number(*v);
        enforce(o.minWall > 0, "'min_wall' must be a positive number of mm");
    }
    return o;
}

View[] views(JSONValue args)
{
    if (args.type != JSONType.object || "views" !in args)
        return [View.iso, View.front, View.top, View.right];
    return args["views"].array.map!(v => v.str.to!View).array;
}

string randomName()
{
    import std.random : uniform;
    return format("%08x", uniform!uint);
}

unittest
{
    auto init = handle(parseJSON(`{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}`));
    assert(init["result"]["serverInfo"]["name"].str == "hackerscad");
    assert(handle(parseJSON(`{"jsonrpc": "2.0", "method": "notifications/initialized"}`)).type == JSONType.null_);
    auto list = handle(parseJSON(`{"jsonrpc": "2.0", "id": 2, "method": "tools/list"}`));
    assert(list["result"]["tools"].array.map!(t => t["name"].str).canFind("hcad_render"));
    assert(handle(parseJSON(`{"jsonrpc": "2.0", "id": 3, "method": "nope"}`))["error"]["code"].integer == -32601);

    auto call = handle(parseJSON(`{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "hcad_render",
        "arguments": {"source": "@part Solid p() => box(10, 20, 30);", "views": ["iso"]}}}`));
    auto content = call["result"]["content"].array;
    assert(!call["result"]["isError"].boolean);
    assert(content[0]["text"].str.canFind(`"volume_mm3": 6000`));
    assert(content[$ - 1]["type"].str == "image");

    auto bad = handle(parseJSON(`{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "hcad_check",
        "arguments": {"source": "@part Solid p() => box(10, 20, 30).fillet(edges, radius: 1);"}}}`));
    assert(bad["result"]["isError"].boolean);
    assert(bad["result"]["content"][0]["text"].str.canFind("did you mean 'r'?"));

    // features and compare answer in a few lines; json: true gives the data
    import std.file : tempDir, write, remove;
    immutable model = buildPath(tempDir, "hcad-mcp-compact.hcad");
    write(model, "@part Solid copy() => box(20, 20, 10) - cylinder(d: 5, h: 30, center: true);\n"
        ~ "@part Solid original() => box(20, 20, 10.5) - cylinder(d: 5.5, h: 30, center: true);\n");
    scope (exit)
        remove(model);
    JSONValue callTool(string tool, string args)
    {
        auto r = handle(parseJSON(`{"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "` ~ tool
            ~ `", "arguments": ` ~ args ~ `}}`));
        assert(!r["result"]["isError"].boolean, r.toString);
        return r["result"]["content"];
    }
    immutable where = `"path": ` ~ JSONValue(model).toString;
    auto features = callTool("hcad_features", `{` ~ where ~ `, "part": "copy"}`)[0]["text"].str;
    assert(features.canFind("hole ⌀5") && !features.canFind(`"kind"`), features);
    assert(callTool("hcad_features", `{` ~ where ~ `, "part": "copy", "json": true}`)[0]["text"].str.canFind(`"kind"`));
    auto compared = callTool("hcad_compare", `{` ~ where ~ `, "a": "copy", "b": "original"}`)[0]["text"].str;
    assert(compared.canFind("within tolerance") && !compared.canFind(`"a_to_b"`), compared);
    assert(callTool("hcad_compare", `{` ~ where ~ `, "a": "copy", "b": "original", "json": true}`)[0]["text"].str
        .canFind(`"a_to_b"`));

    // a window's folder is checked before any window opens
    auto launch(string args) => handle(parseJSON(`{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": `
        ~ `{"name": "hcad_gui_launch", "arguments": ` ~ args ~ `}}`))["result"];
    auto noDir = launch(`{"code": "@part Solid p() => box(1, 1, 1);", "dir": "/no/such/folder"}`);
    assert(noDir["isError"].boolean && noDir["content"][0]["text"].str.canFind("no folder"));
    auto onFile = launch(`{` ~ where ~ `, "dir": ` ~ JSONValue(tempDir).toString ~ `}`);
    assert(onFile["isError"].boolean && onFile["content"][0]["text"].str.canFind("window on a file"));
}

/// The desktop application next to this program: the AppImage this runs
/// from, the launcher of the macOS bundle (it sets the environment GTK
/// needs), or hackerscad beside hcad; HCAD_GUI names it otherwise.
string[] guiCommand()
{
    import std.file : thisExePath, exists;
    import std.path : dirName, buildNormalizedPath;
    import std.process : environment;
    import std.string : indexOf;
    if (auto gui = environment.get("HCAD_GUI"))
        return [gui];
    if (auto image = environment.get("APPIMAGE"))
        return [image];
    auto exe = thisExePath;
    auto bundle = exe.indexOf(".app/Contents/Resources/bin/");
    if (bundle >= 0)
        return [buildNormalizedPath(exe[0 .. bundle] ~ ".app/Contents/MacOS/hackerscad")];
    version (Windows)
        auto beside = buildPath(dirName(exe), "hackerscad.exe");
    else
        auto beside = buildPath(dirName(exe), "hackerscad");
    return exists(beside) ? [beside] : null;
}

/// Starts a window on `path` (none: a new model) named `name` (none: a
/// random free name) and waits until it answers with its first evaluation:
/// its state and name, or (a string) why it could not. `dir`: the folder a
/// window of no file works in (its untitled model is there, and load() reads
/// the files there and below); none, the server's.
JSONValue launchWindow(string path, string name, string code = null, string dir = null)
{
    import core.thread : Thread;
    import core.time : MonoTime, msecs, seconds;
    import std.path : absolutePath;
    import std.process : environment, spawnProcess, Config;
    import std.stdio : File;
    version (linux)
        if (environment.get("WAYLAND_DISPLAY") is null && environment.get("DISPLAY") is null)
            return JSONValue("no screen here (neither WAYLAND_DISPLAY nor DISPLAY is set): the user has to open "
                ~ "hackerscad on their computer");
    auto cmd = guiCommand();
    if (cmd is null)
        return JSONValue("cannot find the hackerscad application next to this hcad: set HCAD_GUI to its path");
    if (name.length)
    {
        auto n = normalizeWindowName(name);
        if (n is null)
            return JSONValue("a window name is letters, digits and dashes");
        if (windowAlive(n))
            return JSONValue("a window is already called " ~ n ~ ": use it, or choose another name");
        name = n;
    }
    else
        do
            name = randomWindowName();
        while (windowAlive(name));
    auto args = cmd ~ ("--name=" ~ name);
    // code: through a file of its own, opened as a model of no file (--copy)
    if (code !is null)
    {
        import std.file : tempDir, write;
        import std.path : buildPath;
        auto file = buildPath(tempDir, format("hackerscad-code-%s.hcad", randomName()));
        write(file, code);
        args ~= "--copy=" ~ file;
    }
    if (path.length)
    {
        import std.file : exists;
        if (!exists(path))
            return JSONValue("no file at " ~ path);
        args ~= absolutePath(path);
    }
    version (Windows)
        enum nowhere = "NUL";
    else
        enum nowhere = "/dev/null";
    try
    {
        auto pid = spawnProcess(args, File(nowhere, "r"), File(nowhere, "w"), File(nowhere, "w"), null,
            Config.detached | Config.suppressConsole, dir);
    }
    catch (Exception e)
        return JSONValue("cannot start " ~ args[0] ~ ": " ~ e.msg);
    // the window answers once GTK is up; a slow first start (the AppImage
    // unpacking, the font cache) can take a while
    immutable until = MonoTime.currTime + 60.seconds;
    while (!windowAlive(name))
    {
        if (MonoTime.currTime > until)
            return JSONValue("the window did not answer within a minute");
        Thread.sleep(200.msecs);
    }
    // its state after the first evaluation
    auto st = guiRequest(name, "state", JSONValue((JSONValue[string]).init));
    if (st.type == JSONType.object)
        st["window"] = name;
    return st;
}
