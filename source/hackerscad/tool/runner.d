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
import hackerscad.geom.printability : PrintCheck, checkPrint;
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
    /// overhangs and thin walls: in the report, and marked in pictures
    bool printability;
    double overhangAngle = 45;   /// degrees from a vertical wall
    double minWall = 0.8;        /// mm
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
    bool printability;         /// report overhangs and thin walls, mark them in pictures
    double overhangAngle = 45, minWall = 0.8;

    private PrintCheck[] checks;

    /// Per part, the overhangs and thin walls of its tessellation (by face).
    PrintCheck[] printChecks()
    {
        if (checks is null)
        {
            import std.math : PI;
            partMeshes();
            PrintCheck[] r;
            foreach (m; faceMeshes)
                r ~= checkPrint(m.verts, 3, m.tris, overhangAngle * PI / 180, minWall);
            checks = r;
        }
        return checks;
    }

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
    /// `oneObject`: a 3MF holds the parts as the pieces of one object.
    void exportTo(string file, string[] only = null, bool oneObject = false)
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
        {
            import std.path : baseName, stripExtension;
            exportParts(file, parts, kernel, oneObject ? baseName(stripExtension(path)) : null);
        }
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
            {
                shaded ~= Shaded(partMeshes()[i], p.rgb, faceMeshes[i]);
                if (printability)
                {
                    // overhangs striped red, thin walls cross-hatched violet, as in the window
                    auto pc = printChecks()[i];
                    auto marks = new ubyte[pc.overhang.length];
                    foreach (t, ref mk; marks)
                        mk = pc.isThin(t) ? 2 : pc.overhang[t] ? 1 : 0;
                    shaded[$ - 1].marks = marks;
                }
            }
        auto img = views.length == 1 ? render(shaded, views[0], 1000, 700) : renderSheet(shaded, views, cell);
        return encodePng(img.rgb, img.width, img.height);
    }

    /// How far part `a` is from part `b` (a remodelled part from the mesh it
    /// copies): the distances both ways, and pictures of `a` coloured by its
    /// distance from `b` (green within tol / 2, yellow at tol, red at twice it).
    JSONValue compare(size_t a, size_t b, double tol, out ubyte[] picture)
    {
        import hackerscad.geom.deviation : deviation, deviationMap;
        import std.algorithm : max;
        partMeshes();
        auto bb = kernel.bbox(result.parts[a].solid.brep);
        immutable spacing = max(0.2, bb.size.length / 300);
        auto ab = deviation(faceMeshes[a], meshes[b], spacing), ba = deviation(meshes[b], faceMeshes[a], spacing);
        JSONValue j = ["max_mm": max(ab.max, ba.max)];
        j["a_to_b"] = ["max_mm": JSONValue(ab.max), "mean_mm": JSONValue(ab.mean), "rms_mm": JSONValue(ab.rms),
            "within_tolerance": JSONValue(ab.within(tol))];
        j["a_to_b"]["worst_at"] = [ab.worstAt.x, ab.worstAt.y, ab.worstAt.z];
        j["b_to_a"] = ["max_mm": JSONValue(ba.max), "mean_mm": JSONValue(ba.mean), "rms_mm": JSONValue(ba.rms),
            "within_tolerance": JSONValue(ba.within(tol))];
        j["b_to_a"]["worst_at"] = [ba.worstAt.x, ba.worstAt.y, ba.worstAt.z];
        j["tolerance_mm"] = tol;
        // the places where the surfaces part, in numbers: small things the volumes miss (a chamfer, a
        // notch, a countersink)
        import hackerscad.geom.deviation : patches;
        import hackerscad.geom.meshfeatures : plausible;
        JSONValue[] list(const Mesh from, const Mesh to)
        {
            JSONValue[] r;
            foreach (i, p; patches(from, to, tol, 0.5))
            {
                if (i == 25)
                    break;
                JSONValue jp = ["area_mm2": plausible(p.area), "worst_mm": plausible(p.worst), "mean_mm": plausible(p.mean)];
                jp["from"] = [plausible(p.lo.x), plausible(p.lo.y), plausible(p.lo.z)];
                jp["to"] = [plausible(p.hi.x), plausible(p.hi.y), plausible(p.hi.z)];
                jp["centre"] = [plausible(p.centre.x), plausible(p.centre.y), plausible(p.centre.z)];
                jp["facing"] = [plausible(p.normal.x), plausible(p.normal.y), plausible(p.normal.z)];
                r ~= jp;
            }
            return r;
        }
        // on b (the original): what the copy does not follow; on a: what the copy has that b does not
        j["b_surface_not_matched"] = list(meshes[b], meshes[a]);
        j["a_surface_not_matched"] = list(meshes[a], meshes[b]);
        uint[] colors;
        auto map = deviationMap(faceMeshes[a], meshes[b], max(0.3, bb.size.length / 150), tol, colors);
        auto s = Shaded(map.welded(1e-6), result.parts[a].rgb, map);
        s.colors = colors;
        auto img = renderSheet([s], [View.iso, View.front, View.top, View.right], 450);
        picture = encodePng(img.rgb, img.width, img.height);
        return j;
    }

    /// Where part `a` (a copy) differs from part `b` (the original), as pieces
    /// of material: what a lacks (to add) and what it has too much of (to cut),
    /// largest first, each with its box, volume and how much of the box it fills.
    string differences(size_t a, size_t b, double resolution)
    {
        import std.algorithm : max;
        import hackerscad.geom.voxeldiff : differences;
        import hackerscad.geom.meshfeatures : plausible;
        partMeshes();
        auto bb = kernel.bbox(result.parts[b].solid.brep);
        immutable h = resolution > 0 ? resolution : max(0.2, max(bb.size.x, bb.size.y, bb.size.z) / 250);
        auto regions = differences(meshes[a], meshes[b], h, max(1.0, 8 * h * h * h));
        string mm(double v)
        {
            immutable p = plausible(v);
            return format("%g", p == 0 ? 0.0 : p);
        }
        string s = format("%s against %s, on cubes of %s mm:\n", result.parts[a].name, result.parts[b].name, mm(h));
        if (regions.length == 0)
            return s ~ "  no differences thicker than two cubes\n";
        double lacks = 0, extra = 0;
        foreach (g; regions)
            (g.missing ? lacks : extra) += g.volume;
        s ~= format("  %s lacks %s mm³ and has %s mm³ too much, in %d regions; the largest:\n", result.parts[a].name,
            mm(lacks), mm(extra), regions.length);
        foreach (i, g; regions)
        {
            if (i == 30)
            {
                s ~= format("  and %d smaller ones\n", regions.length - 30);
                break;
            }
            auto size = g.hi - g.lo;
            s ~= format("  %s %s mm³: from (%s, %s, %s) to (%s, %s, %s), %s × %s × %s, centre of mass (%s, %s, %s)%s\n",
                g.missing ? "to add" : "to cut", mm(g.volume), mm(g.lo.x), mm(g.lo.y), mm(g.lo.z), mm(g.hi.x), mm(g.hi.y),
                mm(g.hi.z), mm(size.x), mm(size.y), mm(size.z), mm(g.centroid.x), mm(g.centroid.y), mm(g.centroid.z),
                g.fill > 0.85 ? format(", a box (fills %d%%)", cast(int)(g.fill * 100))
                    : format(", fills %d%% of its box", cast(int)(g.fill * 100)));
        }
        return s;
    }

    /// The drawings of part `a` (a copy) and part `b` (the original) compared
    /// from many directions around them: the lines one has and the other
    /// has not, and the surface facing another way in one (twisted, curved,
    /// tilted: shaded otherwise), as places on the part, the most seen and
    /// largest first; `picture` the `shown` views that show most of them, or
    /// with `fixed` twelve views that stay the same from one version to the
    /// next. `depth` (mm) peels them like an onion, that much cut away towards
    /// each view: the inside, once the outside matches. `voids` compares
    /// their holes, pockets and cavities made solid instead (b filled from its
    /// shadows, minus each part).
    string lines(size_t a, size_t b, double depth, size_t shown, bool fixed, bool voids, out ubyte[] picture)
    {
        import hackerscad.render.linediff : fixedViews, Kind, lineDiff, orbit, sheet, telling;
        import hackerscad.geom.meshfeatures : plausible;
        import std.algorithm : max, min;
        import std.math : ceil;
        partMeshes();
        Mesh ma = meshes[a], mb = meshes[b];
        string na = result.parts[a].name, nb = result.parts[b].name;
        if (voids)
        {
            import hackerscad.kernel.brep : BoolOp;
            import hackerscad.lang.convex : shapeOfShadows;
            import hackerscad.lang.errors : Span;
            auto filled = shapeOfShadows(kernel, result.parts[b].solid.brep, Span(path));
            ma = kernel.tessellate(kernel.boolean(filled, result.parts[a].solid.brep, BoolOp.cut), tolerance, 0.2).welded;
            mb = kernel.tessellate(kernel.boolean(filled, result.parts[b].solid.brep, BoolOp.cut), tolerance, 0.2).welded;
            na = "the voids of " ~ na;
            nb = "the voids of " ~ nb;
        }
        auto d = lineDiff(ma, mb, orbit(max(0.0, depth)), 300);
        // the next peel: a quarter of the thinnest side, in whole millimetres
        auto bb = kernel.bbox(result.parts[b].solid.brep);
        immutable thinnest = min(bb.size.x, bb.size.y, bb.size.z);
        immutable next = depth + max(1.0, ceil(thinnest / 4));
        immutable deeper = next < thinnest;
        string mm(double v)
        {
            immutable p = plausible(v);
            return format("%g", p == 0 ? 0.0 : p);
        }
        auto views = fixed ? fixedViews(d) : telling(d, shown);
        auto img = sheet(d, views);
        picture = encodePng(img.rgb, img.width, img.height);
        string s = format("%s against %s, drawn as lines from %d directions around them%s, lines within %s mm taken "
            ~ "as the same, surface facing more than 15° otherwise marked:\n", na, nb, d.directions.length,
            depth > 0 ? format(", peeled %s mm deep", mm(depth)) : " (the outside)", mm(d.tolerance));
        if (d.strokes.length == 0)
        {
            // the drawings match: deeper only if something differs inside, where no line shows
            import hackerscad.geom.voxeldiff : differences;
            immutable h = max(0.2, max(bb.size.x, bb.size.y, bb.size.z) / 250);
            auto regions = differences(meshes[a], meshes[b], h, max(1.0, 8 * h * h * h));
            double volume = 0;
            foreach (g; regions)
                volume += g.volume;
            if (regions.length == 0)
                s ~= "  the drawings match, and so does the material inside (no difference thicker than "
                    ~ mm(2 * h) ~ " mm): no need to peel further\n";
            else if (deeper)
                s ~= format("  the drawings match, but %s mm³ of material differ in %d places (hcad diff): peel deeper "
                    ~ "(depth %s mm) or compare the voids to see them\n", mm(volume), regions.length, mm(next));
            else
                s ~= format("  the drawings match this deep; %s mm³ of material still differ (hcad diff)\n", mm(volume));
        }
        size_t[3] count;
        double[3] total = 0;
        foreach (st; d.strokes)
        {
            count[st.kind]++;
            total[st.kind] += st.length;
        }
        // the totals go down as the copy gets closer (the counts need not: a fix can split a group in two)
        if (d.strokes.length)
            s ~= format("  in all: %s mm of lines of %s that %s lacks (%d groups), %s mm of lines of %s that %s has not "
                ~ "(%d), %s mm² of surface facing otherwise (%d); the most seen:\n", mm(total[Kind.missing]), nb, na,
                count[Kind.missing], mm(total[Kind.extra]), na, nb, count[Kind.extra], mm(total[Kind.facing]),
                count[Kind.facing]);
        // where to look: the first picture that shows it, else one direction that does
        string inPicture(const size_t[] seen)
        {
            foreach (i, v; views)
                foreach (w; seen)
                    if (v == w)
                        return format("in picture %d", i + 1);
            return format("e.g. from %s", d.directions[seen[0]]);
        }
        foreach (i, st; d.strokes)
        {
            if (i == 30)
            {
                s ~= format("  and %d less seen\n", d.strokes.length - 30);
                break;
            }
            auto size = st.hi - st.lo;
            s ~= format("  %s: about %s from (%s, %s, %s) to (%s, %s, %s), %s × %s × %s, seen from %d directions, %s\n",
                st.kind == Kind.missing ? "only in " ~ nb : st.kind == Kind.extra ? "only in " ~ na
                    : "surface facing otherwise (twisted, curved or tilted)",
                st.kind == Kind.facing ? mm(st.length) ~ " mm²" : mm(st.length) ~ " mm of lines", mm(st.lo.x), mm(st.lo.y),
                mm(st.lo.z), mm(st.hi.x), mm(st.hi.y), mm(st.hi.z), mm(size.x), mm(size.y), mm(size.z),
                st.seenFrom.length, inPicture(st.seenFrom));
        }
        s ~= format("the picture: %d views%s, left to right and top to bottom (grey the lines in common, red only in "
            ~ "%s, blue only in %s, violet the surface facing otherwise):\n", views.length,
            fixed ? " (the same each time)" : "", nb, na);
        foreach (i, v; views)
            s ~= format("  %d. %s\n", i + 1, d.directions[v]);
        if (d.strokes.length && deeper)
            s ~= format("fix these first; once they match, peel deeper (depth %s mm) only if anything still differs\n",
                mm(next));
        return s;
    }

    /// Machine-readable summary for scripts and agents.
    JSONValue report()
    {
        JSONValue j = ["ok": JSONValue(!hasErrors)];
        j["milliseconds"] = milliseconds;
        JSONValue[] parts;
        foreach (pi, p; result.parts)
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
            if (printability)
            {
                auto pc = printChecks()[pi];
                JSONValue jpr = ["overhang_mm2": pc.overhangArea, "thin_wall_mm2": pc.thinArea];
                if (pc.thinArea > 0)
                    jpr["thinnest_mm"] = pc.thinnest;
                jp["printability"] = jpr;
            }
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
    run.printability = o.printability;
    run.overhangAngle = o.overhangAngle;
    run.minWall = o.minWall;
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
