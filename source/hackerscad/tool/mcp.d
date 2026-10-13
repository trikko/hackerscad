/// Model Context Protocol server over stdio (`hcad mcp`): lets AI agents
/// read the reference, evaluate and render models, export them and drive an
/// open hackerscad window.
module hackerscad.tool.mcp;

import hackerscad.about : appVersion;
import std.algorithm : map, canFind, startsWith;
import std.array : array;
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
import hackerscad.tool.docs : agentsText, reference, skillText, summaryText;
import hackerscad.tool.runner;
import hackerscad.tool.guiclient;
import hackerscad.kernel.cache : CachingKernel;
import hackerscad.kernel.occt.backend : OcctKernel;

enum serverVersion = appVersion;

enum instructions = "hackerscad is a parametric CAD for code-defined models (.hcad, a sandboxed subset of D). "
    ~ "Call hcad_docs first, then iterate with hcad_render (it returns dimensions, problems and pictures) "
    ~ "until the model matches the request, then hcad_export. If the user has hackerscad open, "
    ~ "hcad_gui_* tools show your work in their window.";

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
    worker.stop();
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
    ["hcad_check", "hcad_render", "hcad_export", "hcad_drawing", "hcad_measure"].canFind(tool);

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
    "tolerance": {"type": "number", "description": "Mesh chord tolerance in mm for exported meshes and pictures (default 0.02; smaller is finer and slower)."}`;

JSONValue[] toolList()
{
    JSONValue tool(string name, string description, string properties, string required = "[]")
    {
        JSONValue t = ["name": name, "description": description];
        t["inputSchema"] = schema(`{"type": "object", "properties": {` ~ properties ~ `}, "required": ` ~ required ~ `}`);
        return t;
    }

    enum partsProp = `"parts": {"type": "array", "items": {"type": "string"}, "description": "Only these parts, by `
        ~ `function name or @part(name:); default every part but the export: false ones."}`;

    // every GUI tool can name the window, when several are open
    JSONValue gui(string name, string description, string properties, string required = "[]") =>
        tool(name, description, `"window": {"type": "string", "description": "Name of the hackerscad window (shown in `
            ~ `its header bar; hcad_gui_windows lists them). Needed only when several are open."}`
            ~ (properties.length ? ", " ~ properties : ""), required);

    return [
        tool("hcad_docs", "Reference of the .hcad language, the geometry API, conventions and examples. "
            ~ "Call it before writing a model; pass a topic (e.g. 'fillet', 'hardware') for a short excerpt. format: "
            ~ "cheatsheet gives every function in one line each (compact), summary the short index (llms.txt), agents "
            ~ "and skill the agent guides.",
            `"topic": {"type": "string"}, "format": {"type": "string", "enum": ["reference", "cheatsheet", "summary", "agents", "skill"]}`),
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
            ~ partsProp, `["output"]`),
        tool("hcad_drawing", "Evaluate a model and return a @drawing as SVG text (views with hidden lines, sections, "
            ~ "dimensions, title block), to check it before exporting it as PDF or DXF.",
            modelProps ~ `, "drawing": {"type": "string", "description": "Name of the @drawing function; default the first."}`),
        tool("hcad_measure", "Minimum distance between two parts of a model (by function name or @part(name:)), with "
            ~ "the closest points; 0 when they touch or overlap.", modelProps ~ `, "a": {"type": "string"}, "b": {"type": "string"}`, `["a", "b"]`),
        tool("hcad_gui_windows", "The hackerscad windows open on this computer: name (the user may call a window by it), "
            ~ "file, unsaved changes, whether it is evaluating. Pass the name as 'window' to the other hcad_gui_* tools.", ``),
        gui("hcad_gui_open", "Open a model file in the user's hackerscad window (it must be running). Refused when the "
            ~ "user has unsaved changes, unless force is true (which discards them: ask the user first).",
            `"path": {"type": "string"}, "force": {"type": "boolean"}`, `["path"]`),
        gui("hcad_gui_set", "Change the model shown in the user's window: replace its source, set parameter "
            ~ "overrides or a preset (preset \"\" goes back to the defaults, as Reset to defaults). A preset clears the "
            ~ "values set before; params given in the same call apply on top of it. The window re-evaluates and shows "
            ~ "the result.",
            `"source": {"type": "string"}, "params": {"type": "object", "description": "Parameter values, name to value: `
            ~ `numbers are in the model unit (mm), strings are .hcad expressions such as \"80.mm\"."}, "preset": {"type": "string"}`),
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
            ~ "stays still). style draws the parts shaded with edges, shaded only or as a wireframe (hidden edges "
            ~ "faint); projection is perspective or orthographic; menu opens the parts (eye) or display (cube) "
            ~ "menu of the view bar for a screenshot, none closes them; sidebar shows the params or steps tab; "
            ~ "cursor puts the editor's cursor at the start of a line and scrolls there; code_width sets how wide "
            ~ "the code is (pixels); theme draws the window light or dark for this run (the user's own choice, in the "
            ~ "main menu, stays); drag is what a left drag does, rotate or pan. "
            ~ "hidden lists the parts to hide (the others are shown); code, console, view and params show or hide "
            ~ "those panels. hcad_gui_state gives the camera.",
            `"preset": {"type": "string", "enum": ["iso", "front", "top", "right", "fit"]}, `
            ~ `"look_at": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}, `
            ~ `"size": {"type": "number"}, `
            ~ `"orbit": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}, `
            ~ `"pan": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}, `
            ~ `"zoom": {"type": "number"}, `
            ~ `"at": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}, `
            ~ `"style": {"type": "string", "enum": ["edges", "shaded", "wireframe"]}, `
            ~ `"projection": {"type": "string", "enum": ["perspective", "orthographic"]}, `
            ~ `"menu": {"type": "string", "enum": ["parts", "display", "none"]}, `
            ~ `"sidebar": {"type": "string", "enum": ["params", "steps"]}, `
            ~ `"cursor": {"type": "integer"}, "code_width": {"type": "integer"}, `
            ~ `"hidden": {"type": "array", "items": {"type": "string"}}, `
            ~ `"code": {"type": "boolean"}, "console": {"type": "boolean"}, "view": {"type": "boolean"}, `
            ~ `"params": {"type": "boolean"}, `
            ~ `"theme": {"type": "string", "enum": ["system", "light", "dark"]}, `
            ~ `"drag": {"type": "string", "enum": ["rotate", "pan"]}`, `[]`),
        gui("hcad_gui_new", "Start a new model in the user's window, as the New button: the template (a cube with two "
            ~ "holes), parameters and view reset. Refused when the user has unsaved changes, unless force is true "
            ~ "(which discards them: ask the user first).", `"force": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_rename", "Rename the user's window (the name in its header bar, which the user and the "
            ~ "'window' argument use): letters, digits and dashes.", `"name": {"type": "string"}`, `["name"]`),
        gui("hcad_gui_feature", "Point at the user's 3D view (x, y as fractions of its size, or a model point) and add a feature there, "
            ~ "like the right-click menu: the code (with a stable selector) is appended to the part in the editor. Actions: "
            ~ "fillet-edge, chamfer-edge, fillet-face (all edges of the face), chamfer-face, shell (opens the face).",
            `"x": {"type": "number"}, "y": {"type": "number"}, ` ~ `"point": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3, "description": "a model point in mm instead of x, y: it must be visible"}, `
            ~ `"action": {"type": "string", "enum": ["fillet-edge", `
            ~ `"chamfer-edge", "fillet-face", "chamfer-face", "shell"]}, "value": {"type": "string", "description": `
            ~ `"radius, distance or thickness, e.g. 2.mm"}`, `["action"]`),
        gui("hcad_gui_menu", "Right-click the user's 3D view at x, y (fractions of its size) or at a model point and "
            ~ "choose entries of the menu in order, e.g. [\"Hole at point\", \"Clearance\", \"M3\"] or [\"Fillet edge…\"]: "
            ~ "what the user would do with the mouse. Entries that write code append it to the part in the editor. "
            ~ "Without path, returns the entries the menu has there (with sub-entries and the values it shows) and "
            ~ "chooses nothing. With open: true the menu stays open (path: only groups to open), to show it in "
            ~ "hcad_gui_screenshot.",
            `"x": {"type": "number"}, "y": {"type": "number"}, ` ~ `"point": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3, "description": "a model point in mm instead of x, y: it must be visible"}, `
            ~ `"path": {"type": "array", "items": {"type": "string"}}, "open": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_section", "Cut the user's 3D view with a plane: parallel to xy, xz or yz, or to the selected face "
            ~ "(face; clicking another face moves it there); without plane, the plane shown stays (xy when none is); at is "
            ~ "the position from 0 to 1 across the model; flip: true shows the other side, false the first one; cut solids "
            ~ "are shown filled and hatched; on: false removes it.",
            `"plane": {"type": "string", "enum": ["xy", "xz", "yz", "face"]}, "at": {"type": "number"}, `
            ~ `"flip": {"type": "boolean"}, "on": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_sketch", "Show (on: true) or hide the sketches in the user's 3D view, with their dimensions and the "
            ~ "points that can still move in blue.", `"on": {"type": "boolean"}`, `[]`),
        gui("hcad_gui_rollback", "Show the user's model as it was right after the feature on a line of code (its new "
            ~ "faces in orange, the final parts as ghosts); without line, back to the final model.",
            `"line": {"type": "integer"}`, `[]`),
        gui("hcad_gui_inspect", "Show in the user's 3D view what a line of code made (Inspect): the solids, 2D profiles "
            ~ "(where they were drawn, before being extruded or placed) and paths of its calls in orange, the final parts "
            ~ "as ghosts. line to to_line covers several lines; function shows what that function returns. On the line "
            ~ "declaring a function, what it returns. Without arguments, back to the final model. Returns the state, "
            ~ "whose inspect lists the items shown (line, function, kind, calls, bounding box).",
            `"line": {"type": "integer"}, "to_line": {"type": "integer"}, "function": {"type": "string"}`, `[]`),
        gui("hcad_gui_export", "Export the model open in the user's window, with the parameters and preset set "
            ~ "there, to 'path': .3mf (one object per part, colours), .stl (one part), .zip (one STL per part), "
            ~ ".step (one named body per part) or .png (the 3D view as shown; with 'parts', those alone). Drawings "
            ~ "(.svg, .pdf, .dxf) are made by hcad_export on the file.",
            `"path": {"type": "string"}, ` ~ partsProp, `["path"]`),
        gui("hcad_gui_complete", "What the editor's completion offers in the user's window: at the cursor, or at "
            ~ "line and col (1-based). Gives the proposals with their signature and documentation, and inside a call "
            ~ "the callee's signature and the argument the cursor is on.",
            `"line": {"type": "integer"}, "col": {"type": "integer"}, `
            ~ `"show": {"type": "boolean", "description": "also move the cursor there and open the list in the window"}, `
            ~ `"select": {"type": "string", "description": "with show, the entry to select in the list"}`, `[]`),
        gui("hcad_gui_cheatsheet", "Opens the cheatsheet window in the user's GUI (every function and object in "
            ~ "one line, and \"how do I…\" recipes), filtered by query when given: to show the user where to look.",
            `"query": {"type": "string"}`, `[]`),
        gui("hcad_gui_edit", "Change the code in the user's editor like typing does (Ctrl+Z undoes it, and the window "
            ~ "re-evaluates): old and new replace text that appears exactly once; lines [from, to] and text replace those "
            ~ "lines (1-based, inclusive); insert (a line number) and text insert before that line (one more than the "
            ~ "line count appends). Returns the state and the lines of the new text.",
            `"old": {"type": "string"}, "new": {"type": "string"}, `
            ~ `"lines": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2}, `
            ~ `"insert": {"type": "integer"}, "text": {"type": "string"}`, `[]`),
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
        gui("hcad_gui_about", "Open the About window of the user's hackerscad (version, credits, licences).", ``),
        gui("hcad_gui_screenshot", "Picture of the user's hackerscad window, after the current evaluation finishes; "
            ~ "target cheatsheet pictures the cheatsheet window instead (open it with hcad_gui_cheatsheet).",
            `"target": {"type": "string", "enum": ["window", "cheatsheet"]}`, `[]`),
        gui("hcad_gui_state", "State of the user's window: file, parameters, parts, camera, problems, version; "
            ~ "user_changed tells which lines the user changed since your previous hcad_gui_* call. It waits for the "
            ~ "running evaluation; with now: true it answers at once, with evaluating, stage (e.g. part 3 of 12: gear) "
            ~ "and seconds; with source: true it includes the code as it is in the editor (maybe not saved) and steps, "
            ~ "the Steps panel row by row. params give value, default, type, min, max, step and choices; revision "
            ~ "counts the evaluations, log is what the model printed, outdated says the window should be restarted.",
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
            case null, "reference": text(reference(arg("topic"))); break;
            default: throw new Exception("format must be reference, cheatsheet, summary, agents or skill");
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
                foreach (output; outputs)
                {
                    run.exportTo(output, only);
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
            "hcad_gui_new", "hcad_gui_rename", "hcad_gui_rollback", "hcad_gui_inspect", "hcad_gui_feature", "hcad_gui_section", "hcad_gui_menu", "hcad_gui_about", "hcad_gui_stop", "hcad_gui_save", "hcad_gui_export",
            "hcad_gui_edit", "hcad_gui_undo", "hcad_gui_project", "hcad_gui_selection", "hcad_gui_measure", "hcad_gui_complete", "hcad_gui_cheatsheet":
        {
            auto method = name["hcad_gui_".length .. $];
            auto r = guiRequest(arg("window"), method, args.type == JSONType.object ? args : JSONValue((JSONValue[string]).init));
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
                : "no hackerscad window is open: the user can start one with `hackerscad model.hcad`");
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
}
