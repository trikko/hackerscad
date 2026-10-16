/// One evaluation of a model with everything clients need: the JSON report,
/// exports and rendered images. Shared by the CLI and the MCP server (the
/// window has its own evaluator, gui/evaluator).
module hackerscad.tool.runner;

import std.algorithm : map, endsWith, startsWith;
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
import hackerscad.tool.closeup : Place;
import hackerscad.geom.voxeldiff : Region;

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
    Shot[] freeView;           /// a PNG export: this one picture instead of the views its name asks for
    bool opaque;               /// a PNG export: see-through parts drawn solid

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
            write(file, png(pngViews(file), 450, kept, freeView.length ? &freeView[0] : null, opaque));
            return;
        }
        import hackerscad.tool.exporter : ExportException, ExportPart, exportParts;
        ExportPart[] parts;
        foreach (i; kept)
            parts ~= ExportPart(result.parts[i].label, ms[i], result.parts[i].rgb, result.parts[i].solid.brep);
        try
        {
            import std.path : baseName, stripExtension;
            // the warnings name their part: point at its function
            foreach (w; exportParts(file, parts, kernel, oneObject ? baseName(stripExtension(path)) : null))
            {
                auto at = Span(path);
                foreach (i; kept)
                    if (w.startsWith(format("part '%s'", result.parts[i].label)))
                        at = result.parts[i].span;
                result.diagnostics ~= Diagnostic(Severity.warning, Code.kernel, w, at);
            }
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

    /// `only`: the indices of the parts drawn; empty, all of them. `free`: one
    /// picture from there instead of the views; `opaque`: see-through parts
    /// drawn solid.
    ubyte[] png(const View[] views, uint cell = 450, const size_t[] only = null, const(Shot)* free = null,
        bool opaque = false)
    {
        import std.algorithm : canFind;
        Shaded[] shaded;
        foreach (i, p; result.parts)
            if (only.length == 0 || only.canFind(i))
            {
                shaded ~= Shaded(partMeshes()[i], opaque ? p.rgb & 0xFFFFFF : p.rgb, faceMeshes[i]);
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
        auto img = free !is null ? render(shaded, *free, 1000, 700)
            : views.length == 1 ? render(shaded, views[0], 1000, 700) : renderSheet(shaded, views, cell);
        return encodePng(img.rgb, img.width, img.height);
    }

    /// A picture from anywhere: `from` a named view (front, iso…) or a
    /// direction "x,y,z" towards the viewer; with `lookAt` and `size`, framed
    /// on the cube of that side round that point; `cut`, what lies in front
    /// of it left out.
    static Shot freeShot(string from, const double[] lookAt, double size, bool cut)
    {
        import std.algorithm : map;
        import std.array : array, split;
        import std.conv : to;
        import std.traits : EnumMembers;
        Shot shot;
        bool named;
        foreach (v; EnumMembers!View)
            if (from == v.to!string)
            {
                shot = Shot.of(v);
                named = true;
            }
        if (!named && from.length)
        {
            auto d = from.split(",").map!(x => x.to!double).array;
            if (d.length != 3 || (d[0] == 0 && d[1] == 0 && d[2] == 0))
                throw new Exception("from is a view (iso, front, back, top, bottom, left, right) or a direction x,y,z");
            shot = Shot(Vec3(d[0], d[1], d[2]));
        }
        if (lookAt.length)
        {
            if (lookAt.length != 3)
                throw new Exception("look_at is a point: [x, y, z]");
            immutable h = (size > 0 ? size : 20) / 2;
            immutable c = Vec3(lookAt[0], lookAt[1], lookAt[2]);
            shot = shot.framing(c - Vec3(h, h, h), c + Vec3(h, h, h), cut);
        }
        return shot;
    }

    /// How far part `a` is from part `b` (a remodelled part from the mesh it
    /// copies): the distances both ways, and pictures of `a` coloured by its
    /// distance from `b` (green within tol / 2, yellow at tol, red at twice it).
    JSONValue compare(size_t a, size_t b, double tol, out ubyte[] picture, const(Shot)* free = null, size_t views = 4)
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
        // walls thinner than the tolerance that the copy has and the original has not: two pieces of the copy a
        // hair apart (a sliver), which the distances only show as an offset
        {
            import hackerscad.geom.printability : checkPrint;
            import std.algorithm : min, max;
            import std.math : PI;
            auto ca = checkPrint(faceMeshes[a].verts, 3, faceMeshes[a].tris, PI / 2, tol);
            auto cb = checkPrint(meshes[b].verts, 3, meshes[b].tris, PI / 2, tol);
            if (ca.thinArea > cb.thinArea + 0.5)
            {
                Vec3 lo = Vec3(double.infinity, double.infinity, double.infinity), hi = -lo;
                auto fm = faceMeshes[a];
                foreach (t; 0 .. fm.triangleCount)
                    if (ca.isThin(t))
                        foreach (k; 0 .. 3)
                        {
                            auto q = fm.vertex(fm.tris[3 * t + k]);
                            lo = Vec3(min(lo.x, q.x), min(lo.y, q.y), min(lo.z, q.z));
                            hi = Vec3(max(hi.x, q.x), max(hi.y, q.y), max(hi.z, q.z));
                        }
                JSONValue sl = ["area_mm2": plausible(ca.thinArea - cb.thinArea), "thinnest_mm": plausible(ca.thinnest)];
                sl["from"] = [plausible(lo.x), plausible(lo.y), plausible(lo.z)];
                sl["to"] = [plausible(hi.x), plausible(hi.y), plausible(hi.z)];
                j["a_slivers"] = sl;
            }
        }
        uint[] colors;
        auto map = deviationMap(faceMeshes[a], meshes[b], max(0.3, bb.size.length / 150), tol, colors);
        auto s = Shaded(map.welded(1e-6), result.parts[a].rgb, map);
        s.colors = colors;
        auto shots = free !is null ? [*free] : offViews(map, colors, views);
        auto img = shots.length == 1 ? render([s], shots[0], 1000, 700) : renderSheet([s], shots, 450);
        picture = encodePng(img.rgb, img.width, img.height);
        JSONValue[] captions;
        foreach (sh; shots)
            captions ~= JSONValue(sh.toString);
        j["pictures"] = captions;
        return j;
    }

    /// The views that show the most of a map's surface out of tolerance (not
    /// green), facing the viewer, each next one what the others did not show;
    /// with nothing out of tolerance, iso, front, top and right.
    static Shot[] offViews(const Mesh map, const uint[] colors, size_t count)
    {
        import hackerscad.render.linediff : orbit;
        enum green = 0x3CAA5A;
        Vec3[] normal;
        double[] area;
        foreach (t; 0 .. map.triangleCount)
            if (t < colors.length && (colors[t] & 0xFFFFFF) != green)
            {
                auto p0 = map.vertex(map.tris[3 * t]), p1 = map.vertex(map.tris[3 * t + 1]), p2 = map.vertex(map.tris[3 * t + 2]);
                auto n = (p1 - p0).cross(p2 - p0);
                if (n.length <= 0)
                    continue;
                normal ~= n.normalized;
                area ~= n.length / 2;
            }
        Shot[] shots;
        if (area.length == 0 || count == 0)
        {
            foreach (v; [View.iso, View.front, View.top, View.right][0 .. count < 4 ? (count ? count : 4) : 4])
                shots ~= Shot.of(v);
            return shots;
        }
        auto shown = new bool[area.length];
        auto dirs = orbit();
        foreach (_; 0 .. count)
        {
            double best = 0;
            size_t pick = size_t.max;
            foreach (di, d; dirs)
            {
                double gain = 0;
                immutable e = d.eye;
                // the area as seen: facing the viewer counts in full, aslant less
                foreach (t, n; normal)
                    if (!shown[t] && n.dot(e) > 0.3)
                        gain += area[t] * n.dot(e);
                if (gain > best)
                {
                    best = gain;
                    pick = di;
                }
            }
            if (pick == size_t.max)
                break;
            shots ~= Shot(dirs[pick].eye);
            foreach (t, n; normal)
                if (n.dot(dirs[pick].eye) > 0.3)
                    shown[t] = true;
        }
        return shots;
    }

    /// The comparison `compare` gives, as a few lines of text: the distances
    /// both ways, where the worst is, and the largest patches of each surface
    /// the other does not follow (`patches` of them), one line each.
    static string compareText(JSONValue j, string na, string nb, size_t patches = 8)
    {
        import hackerscad.geom.meshfeatures : plausible;
        string mm(double v)
        {
            immutable p = plausible(v);
            return format("%g", p == 0 ? 0.0 : p);
        }
        double num(JSONValue v) => v.type == JSONType.integer ? v.integer : v.floating;
        string vec(JSONValue v) => format("(%s, %s, %s)", mm(num(v[0])), mm(num(v[1])), mm(num(v[2])));
        immutable tol = num(j["tolerance_mm"]);
        string s = format("%s against %s, tolerance %s mm:\n", na, nb, mm(tol));
        size_t number;
        foreach (way; [["a_to_b", na ~ " to " ~ nb], ["b_to_a", nb ~ " to " ~ na]])
        {
            auto d = j[way[0]];
            s ~= format("  %s: %d%% within tolerance, mean %s mm, rms %s mm, largest %s mm at %s\n", way[1],
                cast(int)(num(d["within_tolerance"]) * 100 + 0.5), mm(num(d["mean_mm"])), mm(num(d["rms_mm"])),
                mm(num(d["max_mm"])), vec(d["worst_at"]));
        }
        foreach (side; [["b_surface_not_matched", "on " ~ nb ~ ", what " ~ na ~ " does not follow"],
                ["a_surface_not_matched", "on " ~ na ~ ", what " ~ nb ~ " does not have"]])
        {
            auto list = j[side[0]].array;
            if (list.length == 0)
                continue;
            s ~= format("  %s (%d patches, the largest first):\n", side[1], list.length);
            // patches alike (one notch repeated, the two sides of one slot): one line, the others' numbers after it
            bool alike(JSONValue p, JSONValue q)
            {
                import std.algorithm : max;
                import std.math : abs;
                // the same way, or mirrored (the two sides of a slot face each other)
                foreach (k; 0 .. 3)
                    if (abs(abs(num(p["facing"][k])) - abs(num(q["facing"][k]))) > 0.15)
                        return false;
                immutable ap = num(p["area_mm2"]), aq = num(q["area_mm2"]);
                return abs(ap - aq) <= 0.2 * max(ap, aq) && abs(num(p["mean_mm"]) - num(q["mean_mm"])) <= 0.05;
            }
            immutable first = number;
            auto shown = new bool[list.length];
            size_t lines;
            foreach (i, p; list)
            {
                if (shown[i])
                    continue;
                if (lines == patches)
                {
                    size_t left;
                    foreach (sh; shown)
                        left += !sh;
                    s ~= format("    and %d smaller ones (json: true lists them)\n", left);
                    break;
                }
                shown[i] = true;
                string others;
                foreach (k; i + 1 .. list.length)
                    if (!shown[k] && alike(p, list[k]))
                    {
                        shown[k] = true;
                        others ~= format("%s%d at %s", others.length ? ", " : "", first + k + 1,
                            vec(list[k]["centre"]));
                    }
                s ~= format("    %d. %s mm² from %s to %s, facing %s, off by %s mm (at most %s)%s\n", first + i + 1,
                    mm(num(p["area_mm2"])), vec(p["from"]), vec(p["to"]), vec(p["facing"]), mm(num(p["mean_mm"])),
                    mm(num(p["worst_mm"])), others.length ? "; alike: " ~ others : "");
                lines++;
            }
            number = first + list.length;
        }
        if (auto sl = "a_slivers" in j)
            s ~= format("  %s has walls thinner than the tolerance that %s has not, %s mm² (thinnest %s mm) from %s to %s: "
                ~ "two pieces a hair apart, a sliver left between them? Cut a section there\n", na, nb,
                mm(num((*sl)["area_mm2"])), mm(num((*sl)["thinnest_mm"])), vec((*sl)["from"]), vec((*sl)["to"]));
        if ("pictures" in j)
        {
            s ~= "  the picture (the copy coloured by its distance: green within half the tolerance, yellow at it, red "
                ~ "at twice it), left to right and top to bottom:\n";
            foreach (i, c; j["pictures"].array)
                s ~= format("    %d. %s\n", i + 1, c.str);
        }
        return s ~ "  next: diff and lines on the same parts, and a close-up (focus) of the first entries of each\n";
    }

    /// The patches of a comparison (as compare gives them), numbered as
    /// compareText numbers them: the original's first, then the copy's.
    static JSONValue[] comparePatches(JSONValue j) => j["b_surface_not_matched"].array ~ j["a_surface_not_matched"].array;

    /// Close-ups of patches of a comparison, by their numbers.
    string compareFocus(JSONValue j, size_t a, size_t b, const size_t[] focus, out ubyte[] picture)
    {
        import hackerscad.tool.closeup : Place;
        auto list = comparePatches(j);
        double num(JSONValue v) => v.type == JSONType.integer ? v.integer : v.floating;
        Vec3 vec(JSONValue v) => Vec3(num(v[0]), num(v[1]), num(v[2]));
        Place[] places;
        foreach (n; focus)
        {
            if (n < 1 || n > list.length)
                throw new Exception(format("there is no patch %d: the comparison numbers 1 to %d", n, list.length));
            auto p = list[n - 1];
            places ~= Place(format("patch %d, %g mm² off by %g mm", n, num(p["area_mm2"]), num(p["mean_mm"])),
                vec(p["from"]), vec(p["to"]), true, vec(p["facing"]));
        }
        return closeUpsOf(a, b, places, num(j["tolerance_mm"]), picture);
    }

    /// Where part `a` (a copy) differs from part `b` (the original), as pieces
    /// of material: what a lacks (to add) and what it has too much of (to cut),
    /// largest first, each with its box, volume and how much of the box it fills.
    string differences(size_t a, size_t b, double resolution)
    {
        ubyte[] none;
        return differences(a, b, resolution, null, none);
    }

    /// As above; `focus` (entry numbers of the report) gives `picture`, a
    /// close-up of each.
    string differences(size_t a, size_t b, double resolution, const size_t[] focus, out ubyte[] picture)
    {
        import std.algorithm : max;
        import hackerscad.geom.voxeldiff : allDifferences, Region;
        import hackerscad.geom.meshfeatures : plausible;
        partMeshes();
        auto bb = kernel.bbox(result.parts[b].solid.brep);
        immutable h = resolution > 0 ? resolution : max(0.2, max(bb.size.x, bb.size.y, bb.size.z) / 250);
        auto found = allDifferences(meshes[a], meshes[b], h, max(1.0, 8 * h * h * h));
        auto regions = found.regions;
        string mm(double v)
        {
            immutable p = plausible(v);
            return format("%g", p == 0 ? 0.0 : p);
        }
        string where(Region g)
        {
            auto size = g.hi - g.lo;
            return format("from (%s, %s, %s) to (%s, %s, %s), %s × %s × %s, centre of mass (%s, %s, %s)", mm(g.lo.x),
                mm(g.lo.y), mm(g.lo.z), mm(g.hi.x), mm(g.hi.y), mm(g.hi.z), mm(size.x), mm(size.y), mm(size.z),
                mm(g.centroid.x), mm(g.centroid.y), mm(g.centroid.z));
        }
        // the section across its longest side, through its centre of mass: the
        // profile of what differs, the copy's drawn on the original's
        string cut(Region g)
        {
            auto size = g.hi - g.lo;
            if (size.x >= size.y && size.x >= size.z)
                return format("plane: yz, at: %s", mm(g.centroid.x));
            if (size.y >= size.z)
                return format("plane: xz, at: %s", mm(g.centroid.y));
            return format("plane: xy, at: %s", mm(g.centroid.z));
        }
        string s = format("%s against %s, on cubes of %s mm:\n", result.parts[a].name, result.parts[b].name, mm(h));
        if (regions.length == 0)
            s ~= "  no differences thicker than two cubes\n";
        else
        {
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
                s ~= format("  %d. %s %s mm³: %s%s\n", i + 1, g.missing ? "to add" : "to cut", mm(g.volume), where(g),
                    g.fill > 0.85 ? format(", a box (fills %d%%)", cast(int)(g.fill * 100))
                        : format(", fills %d%% of its box", cast(int)(g.fill * 100)));
                if (i < 5)
                    s ~= format("      to see its shape: hcad_section with part %s, compare %s, %s\n",
                        result.parts[a].name, result.parts[b].name, cut(g));
            }
        }
        if (found.thin.length)
        {
            double thin = 0;
            foreach (g; found.thin)
                thin += g.volume;
            s ~= format("  and %s mm³ in %d differences thinner than two cubes (chamfers, letterings, notches for "
                ~ "printing): hcad_lines shows them, or resolution: %s measures them; the largest:\n", mm(thin),
                found.thin.length, mm(h / 2));
            foreach (i, g; found.thin)
            {
                if (i == 10)
                {
                    s ~= format("  and %d smaller ones\n", found.thin.length - 10);
                    break;
                }
                s ~= format("  %d. %s %s mm³: %s\n", regions.length + i + 1, g.missing ? "to add" : "to cut",
                    mm(g.volume), where(g));
            }
        }
        if (focus.length == 0 && (regions.length || found.thin.length))
        {
            picture = regionPicture(a, b, regions ~ found.thin);
            s ~= "  the picture: the regions as boxes, green to add, red to cut, in the copy and the original drawn "
                ~ "see-through; iso, front, top and right\n";
        }
        if (focus.length)
        {
            import hackerscad.tool.closeup : Place;
            auto all = regions ~ found.thin;
            Place[] places;
            foreach (n; focus)
            {
                if (n < 1 || n > all.length)
                    throw new Exception(format("there is no entry %d: the report numbers 1 to %d", n, all.length));
                auto g = all[n - 1];
                places ~= Place(format("entry %d, %s %s mm³", n, g.missing ? "to add" : "to cut", mm(g.volume)), g.lo, g.hi);
            }
            s ~= closeUpsOf(a, b, places, 0.1, picture);
        }
        else if (regions.length || found.thin.length)
            s ~= "  next: a close-up (focus) of the first entries, then lines on the same parts\n";
        return s;
    }

    /// The regions where a copy differs as boxes (green to add, red to cut)
    /// in the copy and the original, both see-through: iso, front, top, right.
    ubyte[] regionPicture(size_t a, size_t b, const Region[] regions)
    {
        Mesh boxes(bool missing)
        {
            Mesh m;
            foreach (g; regions)
                if (g.missing == missing)
                {
                    immutable base = cast(uint) m.vertexCount;
                    foreach (k; 0 .. 8)
                        m.verts ~= [cast(float)(k & 1 ? g.hi.x : g.lo.x), cast(float)(k & 2 ? g.hi.y : g.lo.y),
                            cast(float)(k & 4 ? g.hi.z : g.lo.z)];
                    foreach (t; [0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6, 0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3, 0, 4, 6, 0, 6, 2,
                            1, 3, 7, 1, 7, 5])
                        m.tris ~= base + t;
                }
            return m;
        }
        partMeshes();
        Shaded[] items = [Shaded(boxes(true), 0x2EA043), Shaded(boxes(false), 0xDC3232),
            Shaded(meshes[a], 0x8C000000 | (result.parts[a].rgb & 0xFFFFFF)), Shaded(meshes[b], 0xB3708090)];
        auto img = renderSheet(items, [View.iso, View.front, View.top, View.right], 450);
        return encodePng(img.rgb, img.width, img.height);
    }

    /// Close-ups of places, as closeUps draws them, for parts a (the copy)
    /// and b (the original); the text that goes with the picture.
    string closeUpsOf(size_t a, size_t b, const Place[] places, double tol, out ubyte[] picture)
    {
        import hackerscad.tool.closeup : closeUps;
        partMeshes();
        string text;
        auto img = closeUps(meshes[a], meshes[b], result.parts[a].rgb & 0xFFFFFF, places, tol, text);
        picture = encodePng(img.rgb, img.width, img.height);
        return "close-ups:\n" ~ text;
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
    string lines(size_t a, size_t b, double depth, size_t shown, bool fixed, bool voids, out ubyte[] picture,
        const size_t[] focus = null, const(Shot)* free = null)
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
            s ~= format("  %d. %s: about %s from (%s, %s, %s) to (%s, %s, %s), %s × %s × %s, seen from %d directions, %s\n",
                i + 1, st.kind == Kind.missing ? "only in " ~ nb : st.kind == Kind.extra ? "only in " ~ na
                    : "surface facing otherwise (twisted, curved or tilted)",
                st.kind == Kind.facing ? mm(st.length) ~ " mm²" : mm(st.length) ~ " mm of lines", mm(st.lo.x), mm(st.lo.y),
                mm(st.lo.z), mm(st.hi.x), mm(st.hi.y), mm(st.hi.z), mm(size.x), mm(size.y), mm(size.z),
                st.seenFrom.length, inPicture(st.seenFrom));
        }
        s ~= format("the picture: %d views%s, left to right and top to bottom (grey the lines in common, red only in "
            ~ "%s, blue only in %s, violet the surface facing otherwise):\n", views.length,
            fixed ? " (the same each time)" : "", nb, na);
        foreach (i, v; views)
            s ~= format("  %d. %s%s\n", i + 1, Shot(d.directions[v].eye),
                d.directions[v].depth > 0 ? format(", the nearest %s mm cut away", mm(d.directions[v].depth)) : "");
        if (d.strokes.length && deeper)
            s ~= format("fix these first; once they match, peel deeper (depth %s mm) only if anything still differs\n",
                mm(next));
        if (focus.length)
        {
            import hackerscad.tool.closeup : Place, closeUps;
            Place[] places;
            foreach (n; focus)
            {
                if (n < 1 || n > d.strokes.length)
                    throw new Exception(format("there is no entry %d: the report numbers 1 to %d", n, d.strokes.length));
                auto st = d.strokes[n - 1];
                places ~= Place(format("entry %d, %s", n, st.kind == Kind.missing ? "only in " ~ nb
                    : st.kind == Kind.extra ? "only in " ~ na : "surface facing otherwise"), st.lo, st.hi, true,
                    d.directions[st.seenFrom[0]].eye);
            }
            string text;
            auto close = closeUps(ma, mb, result.parts[a].rgb & 0xFFFFFF, places, 0.1, text);
            picture = encodePng(close.rgb, close.width, close.height);
            s ~= "the picture: close-ups instead\n" ~ text;
        }
        else if (free !is null)
        {
            import hackerscad.render.linediff : Direction;
            auto one = lineDiff(ma, mb, [Direction.of(free.eye)], 700, free);
            picture = encodePng(one.pictures[0].rgb, one.pictures[0].width, one.pictures[0].height);
            s ~= format("the picture: one view instead, seen %s\n", *free);
        }
        else if (d.strokes.length)
            s ~= "  next: a close-up (focus) of the first entries; once fixed, compare again\n";
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
            try
                jp["volume_mm3"] = kernel.volume(p.solid.brep);
            catch (KernelException)
                jp["volume_mm3"] = null;   // an invalid solid may have none
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

unittest
{
    // a free shot: a named view or a direction, framed on a cube round a point
    import std.exception : assertThrown;
    auto f = Run.freeShot("front", [1, 2, 3], 4, true);
    assert(f.eye.y < -0.99 && f.framed && f.cut && f.lo.x == -1 && f.hi.z == 5);
    assert(Run.freeShot("1,0,0", null, 0, false).eye.x > 0.99 && !Run.freeShot("1,0,0", null, 0, false).framed);
    assertThrown(Run.freeShot("sideways", null, 0, false));
    // the views of a comparison: where the copy is off; a square facing +x out of tolerance
    Mesh map;
    map.verts = [5, 0, 0, 5, 1, 0, 5, 1, 1, 5, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1];
    map.tris = [0, 1, 2, 0, 2, 3, 4, 6, 5];
    auto shots = Run.offViews(map, [0xDC3232, 0xDC3232, 0x3CAA5A], 2);
    assert(shots.length >= 1 && shots[0].eye.x > 0.5, "the first view faces the red square");
    assert(Run.offViews(map, [0x3CAA5A, 0x3CAA5A, 0x3CAA5A], 4).length == 4, "all green: the usual four");
}

unittest
{
    // the comparison's text: patches alike (here the two sides of a slot, facing each other) on one line, numbered
    import std.algorithm : canFind;
    JSONValue j = parseJSON(`{"tolerance_mm": 0.1, "max_mm": 0.3,
        "a_to_b": {"max_mm": 0.3, "mean_mm": 0.01, "rms_mm": 0.02, "within_tolerance": 0.97, "worst_at": [0, 0, 0]},
        "b_to_a": {"max_mm": 0.2, "mean_mm": 0.01, "rms_mm": 0.02, "within_tolerance": 0.98, "worst_at": [0, 0, 0]},
        "b_surface_not_matched": [
            {"area_mm2": 4, "mean_mm": 0.2, "worst_mm": 0.3, "facing": [1, 0, 0], "from": [0, 0, 0], "to": [0, 1, 1], "centre": [0, 0.5, 0.5]},
            {"area_mm2": 4.2, "mean_mm": 0.21, "worst_mm": 0.3, "facing": [-1, 0, 0], "from": [5, 0, 0], "to": [5, 1, 1], "centre": [5, 0.5, 0.5]},
            {"area_mm2": 1, "mean_mm": 0.5, "worst_mm": 0.6, "facing": [0, 0, 1], "from": [0, 0, 9], "to": [1, 1, 9], "centre": [0.5, 0.5, 9]}],
        "a_surface_not_matched": []}`);
    immutable t = Run.compareText(j, "copy", "original");
    assert(t.canFind("1. 4 mm²") && t.canFind("alike: 2 at (5, 0.5, 0.5)") && t.canFind("3. 1 mm²"), t);
    assert(!t.canFind("\n    2. "), t);
}
