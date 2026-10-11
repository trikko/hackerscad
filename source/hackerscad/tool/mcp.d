/// Model Context Protocol server over stdio (`hscad mcp`): lets AI agents
/// read the reference, evaluate and render models, export them and drive an
/// open hackerscad window.
module hackerscad.tool.mcp;

import hackerscad.about : appVersion;
import std.algorithm : map, canFind;
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

import hackerscad.render.raster : View;
import hackerscad.tool.docs : reference;
import hackerscad.tool.runner;
import hackerscad.tool.guiclient;
import hackerscad.kernel.cache : CachingKernel;
import hackerscad.kernel.occt.backend : OcctKernel;

enum serverVersion = appVersion;

enum instructions = "hackerscad is a parametric CAD for code-defined models (.hcad, a sandboxed subset of D). "
    ~ "Call hcad_docs first, then iterate with hcad_render (it returns dimensions, problems and pictures) "
    ~ "until the model matches the request, then hcad_export. If the user has hackerscad open, "
    ~ "hcad_gui_* tools show your work in their window.";

/// Runs the server until stdin closes.
void serve()
{
    foreach (line; stdin.byLineCopy)
    {
        if (line.strip.length == 0)
            continue;
        JSONValue msg;
        try
            msg = parseJSON(line);
        catch (JSONException)
        {
            send(errorResponse(JSONValue(null), -32700, "parse error"));
            continue;
        }
        auto response = handle(msg);
        if (response.type != JSONType.null_)
            send(response);
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
                r["capabilities"] = ["tools": JSONValue((JSONValue[string]).init)];
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
    stdout.writeln(v.toString(JSONOptions.doNotEscapeSlashes));
    stdout.flush();
}

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
    "preset": {"type": "string", "description": "Name of a @preset to apply."}`;

JSONValue[] toolList()
{
    JSONValue tool(string name, string description, string properties, string required = "[]")
    {
        JSONValue t = ["name": name, "description": description];
        t["inputSchema"] = schema(`{"type": "object", "properties": {` ~ properties ~ `}, "required": ` ~ required ~ `}`);
        return t;
    }

    return [
        tool("hcad_docs", "Reference of the .hcad language, the geometry API, conventions and examples. "
            ~ "Call it before writing a model; pass a topic (e.g. 'fillet', 'hardware') for a short excerpt.",
            `"topic": {"type": "string"}`),
        tool("hcad_check", "Evaluate a model: parts with bounding boxes and volumes, parameters, presets, "
            ~ "writeln output, errors with line/column/suggestion and failed unittest checks.", modelProps),
        tool("hcad_render", "Evaluate a model and return the same report as hcad_check plus a PNG of the parts "
            ~ "(default views: iso, front, top, right). Use it to verify the result visually.",
            modelProps ~ `, "views": {"type": "array", "items": {"type": "string", "enum": ["iso", "front", "back", "top", "bottom", "left", "right"]}}`),
        tool("hcad_export", "Evaluate a model and write it to 'output': .3mf (one object per part, with colours), "
            ~ ".stl, .step or .png; .svg, .pdf or .dxf write a @drawing (the first, or the one named by 'drawing').",
            modelProps ~ `, "output": {"type": "string"}, "drawing": {"type": "string"}`, `["output"]`),
        tool("hcad_drawing", "Evaluate a model and return a @drawing as SVG text (views with hidden lines, sections, "
            ~ "dimensions, title block), to check it before exporting it as PDF or DXF.",
            modelProps ~ `, "drawing": {"type": "string", "description": "Name of the @drawing function; default the first."}`),
        tool("hcad_measure", "Minimum distance between two parts of a model (by @part name), with the closest "
            ~ "points; 0 when they touch or overlap.", modelProps ~ `, "a": {"type": "string"}, "b": {"type": "string"}`, `["a", "b"]`),
        tool("hcad_gui_open", "Open a model file in the user's hackerscad window (it must be running). Refused when the "
            ~ "user has unsaved changes, unless force is true (which discards them: ask the user first).",
            `"path": {"type": "string"}, "force": {"type": "boolean"}`, `["path"]`),
        tool("hcad_gui_set", "Change the model shown in the user's window: replace its source, set parameter "
            ~ "overrides or a preset. The window re-evaluates and shows the result.",
            `"source": {"type": "string"}, "params": {"type": "object"}, "preset": {"type": "string"}`),
        tool("hcad_gui_pick", "Click in the user's 3D view at a point given as fractions of its size (0..1): the "
            ~ "face is highlighted and the editor jumps to the feature that created it. Returns part, face and a selector expression for that face (e.g. faces.top) to use in code.",
            `"x": {"type": "number"}, "y": {"type": "number"}, "shift": {"type": "boolean", "description": `
            ~ `"add to the selection (or remove from it), like Shift+click"}`, `["x", "y"]`),
        tool("hcad_gui_view", "Set the user's 3D view: iso, front, top or right (framed on the model).",
            `"preset": {"type": "string", "enum": ["iso", "front", "top", "right"]}`, `["preset"]`),
        tool("hcad_gui_feature", "Point at the user's 3D view (x, y as fractions of its size) and add a feature there, "
            ~ "like the right-click menu: the code (with a stable selector) is appended to the part in the editor. Actions: "
            ~ "fillet-edge, chamfer-edge, fillet-face (all edges of the face), chamfer-face, shell (opens the face).",
            `"x": {"type": "number"}, "y": {"type": "number"}, "action": {"type": "string", "enum": ["fillet-edge", `
            ~ `"chamfer-edge", "fillet-face", "chamfer-face", "shell"]}, "value": {"type": "string", "description": `
            ~ `"radius, distance or thickness, e.g. 2.mm"}`, `["x", "y", "action"]`),
        tool("hcad_gui_menu", "Right-click the user's 3D view at x, y (fractions of its size) and choose entries of the "
            ~ "menu in order, e.g. [\"Hole at point\", \"Clearance\", \"M3\"] or [\"Fillet edge…\"]: what the user would do "
            ~ "with the mouse. Entries that write code append it to the part in the editor.",
            `"x": {"type": "number"}, "y": {"type": "number"}, "path": {"type": "array", "items": {"type": "string"}}`,
            `["x", "y", "path"]`),
        tool("hcad_gui_section", "Cut the user's 3D view with a plane: parallel to xy, xz or yz, or to the selected face "
            ~ "(face; clicking another face moves it there); at is the position from 0 to 1 across the model; flip inverts the "
            ~ "plane normal (shows the other side); cut solids are shown filled and hatched; on: false removes it.",
            `"plane": {"type": "string", "enum": ["xy", "xz", "yz", "face"]}, "at": {"type": "number"}, `
            ~ `"flip": {"type": "boolean"}, "on": {"type": "boolean"}`, `[]`),
        tool("hcad_gui_sketch", "Show (on: true) or hide the sketches in the user's 3D view, with their dimensions and the "
            ~ "points that can still move in blue.", `"on": {"type": "boolean"}`, `[]`),
        tool("hcad_gui_rollback", "Show the user's model as it was right after the feature on a line of code (its new "
            ~ "faces in orange, the final parts as ghosts); without line, back to the final model.",
            `"line": {"type": "integer"}`, `[]`),
        tool("hcad_gui_export", "Export the model open in the user's window, with the parameters and preset set "
            ~ "there, to 'path': .3mf (one object per part, colours), .stl, .step or .png.",
            `"path": {"type": "string"}`, `["path"]`),
        tool("hcad_gui_complete", "What the editor's completion offers in the user's window: at the cursor, or at "
            ~ "line and col (1-based). Gives the proposals with their signature and documentation, and inside a call "
            ~ "the callee's signature and the argument the cursor is on.",
            `"line": {"type": "integer"}, "col": {"type": "integer"}, `
            ~ `"show": {"type": "boolean", "description": "also move the cursor there and open the list in the window"}`, `[]`),
        tool("hcad_gui_cheatsheet", "Opens the cheatsheet window in the user's GUI (every function and object in "
            ~ "one line, and \"how do I…\" recipes), filtered by query when given: to show the user where to look.",
            `"query": {"type": "string"}`, `[]`),
        tool("hcad_gui_stop", "Stop the evaluation running in the user's window (hcad_gui_state tells whether one is "
            ~ "running and at which stage); it runs again at the next edit.", ``),
        tool("hcad_gui_about", "Open the About window of the user's hackerscad (version, credits, licences).", ``),
        tool("hcad_gui_screenshot", "Picture of the user's hackerscad window, after the current evaluation finishes.", ``),
        tool("hcad_gui_state", "State of the user's window: file, parameters, parts, problems. It waits for the running "
            ~ "evaluation; with now: true it answers at once, with evaluating, stage (e.g. part 3 of 12: gear) and seconds.",
            `"now": {"type": "boolean"}`, `[]`),
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
        text(reference(arg("topic")));
        break;
    case "hcad_check", "hcad_render", "hcad_export":
        {
            auto run = evaluateModel(options(args));
            isError = run.hasErrors;
            if (name == "hcad_export" && run.ok)
            {
                auto output = arg("output");
                enforce(output.length, "missing 'output'");
                run.exportTo(output);
                text("written " ~ output);
            }
            text(run.report().toPrettyString(JSONOptions.doNotEscapeSlashes));
            auto diags = run.renderedDiagnostics();
            if (diags.length)
                text(diags);
            if (name == "hcad_render" && run.ok && run.result.parts.length)
                image(run.png(views(args)));
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
                auto find(string n)
                {
                    foreach (p; run.result.parts)
                        if (p.name == n)
                            return p.solid.brep;
                    throw new Exception(format("no @part named '%s'", n));
                }
                Vec3 pa, pb;
                immutable d = run.kernel.distance(find(arg("a")), find(arg("b")), pa, pb);
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
            "hcad_gui_rollback", "hcad_gui_feature", "hcad_gui_section", "hcad_gui_menu", "hcad_gui_about", "hcad_gui_stop", "hcad_gui_export", "hcad_gui_complete", "hcad_gui_cheatsheet":
        {
            auto method = name["hcad_gui_".length .. $];
            auto r = guiRequest(method, args.type == JSONType.object ? args : JSONValue((JSONValue[string]).init));
            text(r.toPrettyString(JSONOptions.doNotEscapeSlashes));
            break;
        }
    case "hcad_gui_screenshot":
        {
            auto file = buildPath(tempDir, format("hackerscad-shot-%s.png", randomName()));
            JSONValue p = ["path": file];
            auto r = guiRequest("screenshot", p);
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
