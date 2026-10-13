/// One evaluation of a model with everything clients need: the JSON report,
/// exports and rendered images. Shared by the CLI and the MCP server (the
/// window has its own evaluator, gui/evaluator).
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
    double tolerance = 0.02;   /// mesh chord tolerance of exports and pictures (--tolerance)

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

    /// Welded meshes of the parts, in part order, at `tolerance`.
    Mesh[] partMeshes()
    {
        if (meshes is null)
        {
            // kept only when every part is done: a failure halfway would
            // otherwise leave a short list for the next call
            Mesh[] welded, raw;
            foreach (p; result.parts)
            {
                auto m = kernel.tessellate(p.solid.brep, tolerance, 0.2);
                raw ~= m;
                welded ~= m.welded;
            }
            faceMeshes = raw;
            meshes = welded;
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

    /// The parts named in `only` (by function name or @part(name:)), in
    /// that order; without names, every part but the reference ones
    /// (export: false), which pictures include.
    size_t[] partIndices(const string[] only, bool picture)
    {
        import std.algorithm : countUntil;
        size_t[] kept;
        if (only.length)
            foreach (want; only)
            {
                auto i = result.parts.countUntil!(p => p.name == want || p.label == want);
                if (i < 0)
                    throw new HcadError(Code.undefined, format("no @part named '%s'", want), Span(path),
                        Interp.suggest(want, result.parts.map!(p => p.name).array));
                kept ~= i;
            }
        else
            foreach (i, p; result.parts)
                if (p.export_ || picture)
                    kept ~= i;
        return kept;
    }

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
        throw new HcadError(Code.undefined, format("no @drawing named '%s'", name), Span(path),
            Interp.suggest(name, result.drawings.map!(d => d.name).array));
    }

    /// Writes .3mf, .stl, .zip (one STL per part), .step, .png, or a
    /// @drawing as .svg, .pdf or .dxf, according to the extension.
    /// `only`: the parts to write, by function name or @part(name:);
    /// empty, every exported part (not the reference ones).
    void exportTo(string file, string[] only = null)
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
        immutable picture = extension(file).toLower == ".png";
        auto kept = partIndices(only, picture);
        if (kept.length == 0)
            throw new HcadError(Code.undefined, "nothing to export: every @part has export: false", Span.init);
        if (picture)
        {
            write(file, png(pngViews(file), 450, kept));
            return;
        }
        import hackerscad.tool.exporter : ExportException, ExportPart, exportParts;
        ExportPart[] parts;
        foreach (i; kept)
            parts ~= ExportPart(result.parts[i].label, ms[i], result.parts[i].rgb, result.parts[i].solid.brep);
        try
            exportParts(file, parts, kernel);
        catch (ExportException e)
            throw new HcadError(Code.import_, e.msg, Span(path));
    }

    /// PNG of the parts: one view at 1000×700, or a 2-column sheet.
    /// The views a PNG's name asks for: name-views.png the four, name-top.png
    /// (front, back, bottom, left, right, iso) that one, else the iso view.
    static View[] pngViews(string file)
    {
        import std.conv : to;
        import std.traits : EnumMembers;
        if (file.endsWith("-views.png"))
            return [View.iso, View.front, View.top, View.right];
        foreach (v; EnumMembers!View)
            if (file.endsWith("-" ~ v.to!string ~ ".png"))
                return [v];
        return [View.iso];
    }

    /// `only`: the indices of the parts drawn; empty, all of them.
    ubyte[] png(const View[] views, uint cell = 450, const size_t[] only = null)
    {
        import std.algorithm : canFind;
        Shaded[] shaded;
        foreach (i, p; result.parts)
            if (only.length == 0 || only.canFind(i))
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
            if (p.label != p.name)
                jp["export_name"] = p.label;
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
    run.tolerance = o.tolerance;
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

unittest
{
    // --tolerance reaches the meshes of exports and pictures
    RunOptions coarse, fine;
    coarse.source = fine.source = "import std.shapes;\n@part Solid s() => sphere(10.mm);\n";
    coarse.tolerance = 1;
    fine.tolerance = 0.01;
    auto a = evaluateModel(coarse), b = evaluateModel(fine);
    assert(a.ok && b.ok, a.fatal.length ? a.fatal[0].message : b.fatal.length ? b.fatal[0].message : "");
    assert(a.partMeshes()[0].triangleCount * 2 < b.partMeshes()[0].triangleCount);
}
