/// One evaluation of a model with everything clients need: the JSON report,
/// exports and rendered images. Shared by the CLI, the MCP server and the
/// GUI control socket.
module hackerscad.tool.runner;

import std.algorithm : map, endsWith;
import std.array : array;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.file : exists, readText, getcwd, write;
import std.format : format;
import std.json;
import std.path : absolutePath, buildPath, dirName, extension;
import std.string : toLower;

import hackerscad.io.stl;
import hackerscad.io.threemf;
import hackerscad.kernel.brep;
import hackerscad.kernel.occt.backend;
import hackerscad.kernel.cache;
import hackerscad.lang.errors;
import hackerscad.lang.interp;
import hackerscad.lang.value;
import hackerscad.render.png;
import hackerscad.render.raster;
import hackerscad.drawing.sheet : Sheet, toSvg, toPdf, toDxf;

struct RunOptions
{
    string path;               /// model file, or the import root for inline source
    string source;             /// inline source; read from `path` when null
    string[string] overrides;  /// parameter → .hcad expression
    string preset;
    string drawing;            /// @drawing to export as .svg/.pdf/.dxf (default: the first)
    double tolerance = 0.02;
    CachingKernel cache;       /// reuse results of previous runs (long-lived servers)
}

final class Run
{
    Interp interp;
    EvalResult result;
    string drawingName;
    Diagnostic[] fatal;        /// the error that stopped evaluation, if any
    string path;
    long milliseconds;

    private Mesh[] meshes;

    BrepKernel kernel() => interp.kernel;
    bool ok() const => fatal.length == 0;

    /// Errors (fatal or from failed unittests).
    bool hasErrors() const
    {
        if (fatal.length)
            return true;
        foreach (d; result.diagnostics)
            if (d.severity == Severity.error)
                return true;
        return false;
    }

    /// Welded meshes of the parts, in part order.
    Mesh[] partMeshes(double tolerance = 0.02)
    {
        if (meshes is null)
            foreach (p; result.parts)
            {
                auto raw = kernel.tessellate(p.solid.brep, tolerance, 0.2);
                faceMeshes ~= raw;
                meshes ~= raw.welded;
            }
        return meshes;
    }

    /// The tessellations as the kernel made them (one vertex set per face), for smooth shading.
    Mesh[] faceMeshes;

    string sourceOf(string file)
    {
        if (auto m = file in interp.modules)
            return m.source;
        return exists(file) ? readText(file) : "";
    }

    /// Diagnostics rendered with source context, as the CLI prints them.
    string renderedDiagnostics()
    {
        string r;
        foreach (d; fatal ~ result.diagnostics)
            r ~= render(d, sourceOf(d.span.file));
        return r;
    }

    /// Writes .3mf, .stl, .step or .png according to the extension.
    /// The sheet of a @drawing (the first when no name is given).
    Sheet drawingSheet(string name = null)
    {
        import hackerscad.lang.drawingval : DrawingVal;
        if (name is null)
            name = drawingName;
        if (result.drawings.length == 0)
            throw new HcadError(Code.undefined, "the model has no @drawing function: add one returning drawing(…)", Span(path));
        foreach (d; result.drawings)
            if (name.length == 0 || d.name == name)
                return (cast(DrawingVal) d.drawing).render();
        import std.algorithm : map;
        import std.array : array;
        throw new HcadError(Code.undefined, format("no @drawing named '%s'", name), Span(path),
            Interp.suggest(name, result.drawings.map!(d => d.name).array));
    }

    void exportTo(string file)
    {
        switch (extension(file).toLower)
        {
        case ".svg":
            write(file, toSvg(drawingSheet()));
            return;
        case ".pdf":
            write(file, toPdf(drawingSheet()));
            return;
        case ".dxf":
            write(file, toDxf(drawingSheet()));
            return;
        default:
            break;
        }
        if (result.parts.length == 0)
            throw new HcadError(Code.undefined, "nothing to export: the model has no @part", Span.init);
        auto ms = partMeshes();
        // reference parts (@part(export: false)) appear only in pictures
        size_t[] kept;
        foreach (i, p; result.parts)
            if (p.export_)
                kept ~= i;
        immutable picture = extension(file).toLower == ".png";
        if (!picture && kept.length == 0)
            throw new HcadError(Code.undefined, "nothing to export: every @part has export: false", Span.init);
        switch (extension(file).toLower)
        {
        case ".3mf":
            Part[] parts;
            foreach (i; kept)
                parts ~= Part(result.parts[i].name, ms[i], result.parts[i].rgb);
            write3mf(parts, file);
            break;
        case ".stl":
            Mesh all;
            foreach (i; kept)
            {
                auto m = ms[i];
                immutable base = cast(uint) all.vertexCount;
                all.verts ~= m.verts;
                foreach (t; m.tris)
                    all.tris ~= t + base;
            }
            writeStl(all, file);
            break;
        case ".step", ".stp":
            Brep acc = result.parts[kept[0]].solid.brep;
            foreach (i; kept[1 .. $])
                acc = kernel.boolean(acc, result.parts[i].solid.brep, BoolOp.fuse);
            kernel.writeStep(acc, file);
            break;
        case ".png":
            write(file, png(pngViews(file)));
            break;
        default:
            throw new HcadError(Code.import_, format("unsupported output format '%s' (use .3mf, .stl, .step, .png, .svg, .pdf or .dxf)",
                extension(file)), Span.init);
        }
    }

    /// PNG of the parts: one view at 1000×700, or a 2-column sheet.
    /// The views a PNG's name asks for: name-views.png the four, name-top.png
    /// (front, back, bottom, left, right, iso) that one, else the iso view.
    static View[] pngViews(string file)
    {
        import std.algorithm : endsWith;
        import std.conv : to;
        import std.traits : EnumMembers;
        if (file.endsWith("-views.png"))
            return [View.iso, View.front, View.top, View.right];
        foreach (v; EnumMembers!View)
            if (file.endsWith("-" ~ v.to!string ~ ".png"))
                return [v];
        return [View.iso];
    }

    ubyte[] png(const View[] views, uint cell = 450)
    {
        Shaded[] shaded;
        foreach (i, p; result.parts)
            shaded ~= Shaded(partMeshes()[i], p.rgb, faceMeshes[i]);
        auto img = views.length == 1 ? render(shaded, views[0], 1000, 700) : renderSheet(shaded, views, cell);
        return encodePng(img.rgb, img.width, img.height);
    }

    /// Machine-readable summary for scripts and agents.
    JSONValue report()
    {
        JSONValue j = ["ok": JSONValue(!hasErrors)];
        j["milliseconds"] = milliseconds;
        JSONValue[] parts;
        foreach (p; result.parts)
        {
            auto bb = kernel.bbox(p.solid.brep);
            JSONValue jp = ["name": p.name];
            jp["color"] = hexColor(p.rgb);
            if (!p.export_)
                jp["export"] = false;
            jp["bbox"] = ["min": [bb.min.x, bb.min.y, bb.min.z], "max": [bb.max.x, bb.max.y, bb.max.z],
                "size": [bb.size.x, bb.size.y, bb.size.z]];
            jp["volume_mm3"] = kernel.volume(p.solid.brep);
            jp["valid"] = kernel.isValid(p.solid.brep);
            jp["line"] = p.span.line;
            parts ~= jp;
        }
        j["parts"] = parts;
        JSONValue[] drawings;
        foreach (d; result.drawings)
            drawings ~= JSONValue(d.name);
        j["drawings"] = drawings;

        JSONValue[] params;
        foreach (p; result.params.length ? result.params : interp.params)
        {
            JSONValue jp = ["name": p.name, "value": p.value.toString, "default": p.defaultValue.toString,
                "type": p.value.typeName];
            if (p.doc.length) jp["doc"] = p.doc;
            if (p.min.kind != Kind.void_) jp["min"] = p.min.toString;
            if (p.max.kind != Kind.void_) jp["max"] = p.max.toString;
            if (p.choices.length) jp["choices"] = p.choices.map!(c => c.toString).array;
            if (p.presets.length)
            {
                JSONValue[string] ps;
                foreach (name, v; p.presets)
                    ps[name] = v.toString;
                jp["presets"] = ps;
            }
            params ~= jp;
        }
        j["params"] = params;
        j["presets"] = result.presets.length ? result.presets : interp.presetNames;
        j["log"] = (result.log.length ? result.log : interp.log).map!(l => l.text).array;

        JSONValue[] diags;
        foreach (d; fatal ~ result.diagnostics)
        {
            JSONValue jd = ["severity": format("%s", d.severity), "code": d.code, "message": d.message,
                "file": d.span.file];
            jd["line"] = d.span.line;
            jd["column"] = d.span.col;
            if (d.suggestion.length) jd["suggestion"] = d.suggestion;
            diags ~= jd;
        }
        j["diagnostics"] = diags;
        return j;
    }
}

/// Evaluates a model; language and kernel errors end up in `Run.fatal`.
Run evaluateModel(RunOptions o)
{
    auto run = new Run;
    if (o.cache !is null)
    {
        o.cache.beginRun();
        run.interp = new Interp(o.cache);
    }
    else
        run.interp = new Interp(new OcctKernel);
    scope (exit)
        if (o.cache !is null)
            o.cache.endRun();
    run.interp.overrides = o.overrides;
    run.drawingName = o.drawing;
    run.interp.preset = o.preset;
    auto sw = StopWatch(AutoStart.yes);
    run.path = o.path.length ? absolutePath(o.path) : buildPath(getcwd(), "inline.hcad");
    try
    {
        string source = o.source;
        if (source is null)
        {
            if (!exists(run.path))
                throw new HcadError(Code.import_, "file not found: " ~ o.path, Span(o.path));
            source = readText(run.path);
        }
        run.interp.root = dirName(run.path);
        run.result = run.interp.runSource(source, run.path);
    }
    catch (HcadError e)
        run.fatal = [e.diag];
    catch (KernelException e)
        run.fatal = [Diagnostic(Severity.error, Code.kernel, e.msg, Span(run.path))];
    run.milliseconds = sw.peek.total!"msecs";
    return run;
}
