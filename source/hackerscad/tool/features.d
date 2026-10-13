/// `hcad features` and the hcad_features tool: what a mesh or a model is made
/// of (geom/meshfeatures), as a report and as JSON, to remodel a part
/// given as STL.
module hackerscad.tool.features;

import std.file : exists, read, readText;
import std.format : format;
import std.json;
import std.path : extension;
import std.string : toLower;

import hackerscad.geom.mesh;
import hackerscad.geom.meshfeatures;
import hackerscad.geom.vec;

/// The triangles of `file`: a mesh (.stl, .obj, .3mf), a STEP file, or a
/// model (.hcad: its part `part`, or all of them). Throws with a message
/// for the user.
Mesh meshOf(string file, string part = null)
{
    import hackerscad.io.meshread;
    if (!exists(file))
        throw new Exception("file not found: " ~ file);
    immutable ext = extension(file).toLower;
    switch (ext)
    {
    case ".stl": return readStl(cast(const(ubyte)[]) read(file));
    case ".obj": return readObj(readText(file));
    case ".3mf": return read3mf(cast(const(ubyte)[]) read(file));
    case ".step", ".stp":
        {
            import hackerscad.kernel.occt.backend : OcctKernel;
            auto k = new OcctKernel;
            return k.tessellate(k.readStep(file), 0.01, 0.1);
        }
    case ".hcad":
        {
            import hackerscad.tool.runner : evaluateModel, RunOptions;
            RunOptions o;
            o.path = file;
            auto run = evaluateModel(o);
            if (!run.ok)
                throw new Exception(run.renderedDiagnostics());
            Mesh all;
            foreach (i, p; run.result.parts)
            {
                if (part.length && p.name != part && p.label != part)
                    continue;
                auto m = run.kernel.tessellate(p.solid.brep, 0.01, 0.1);
                immutable base = cast(uint) all.vertexCount;
                all.verts ~= m.verts;
                foreach (t; m.tris)
                    all.tris ~= base + t;
            }
            if (all.triangleCount == 0)
                throw new Exception(part.length ? "no part named " ~ part : "the model has no parts");
            return all;
        }
    default:
        throw new Exception(format("cannot read '%s': use .stl, .obj, .3mf, .step or .hcad", ext));
    }
}

private JSONValue v3(Vec3 v) => JSONValue([plausible(v.x), plausible(v.y), plausible(v.z)]);

/// The analysis as JSON: the size, every surface (rounded values with the
/// measured diameter alongside), the patterns.
JSONValue featuresJson(const Analysis a)
{
    import std.math : PI;
    JSONValue j = ["size_mm": v3(a.hi - a.lo), "min_mm": v3(a.lo), "max_mm": v3(a.hi)];
    JSONValue[] fs;
    foreach (i, f; a.features)
    {
        JSONValue jf = ["index": JSONValue(i), "area_mm2": JSONValue(plausible(f.area)), "triangles": JSONValue(f.triangles)];
        final switch (f.kind)
        {
        case Surface.plane:
            jf["kind"] = "plane";
            jf["normal"] = v3(f.normal);
            jf["offset_mm"] = plausible(f.offset);
            break;
        case Surface.cylinder:
            jf["kind"] = f.full ? (f.hole ? "hole" : "shaft") : (f.hole ? "inner rounding" : "rounding");
            jf["diameter_mm"] = plausible(f.diameter);
            jf["measured_diameter_mm"] = f.diameter;
            jf["radius_mm"] = plausible(f.radius);
            jf["length_mm"] = plausible(f.to - f.from);
            jf["axis"] = v3(f.axis);
            jf["start_mm"] = v3(f.point);
            jf["degrees"] = plausible(f.span * 180 / PI);
            if (f.hole && f.full)
                if (auto hint = holeHint(plausible(f.diameter)))
                    jf["likely"] = hint;
            break;
        case Surface.cone:
            jf["kind"] = f.hole ? "cone hole" : "cone";
            jf["diameter_mm"] = plausible(f.diameter);
            jf["half_angle_deg"] = plausible(f.halfAngle * 180 / PI);
            jf["length_mm"] = plausible(f.to - f.from);
            jf["axis"] = v3(f.axis);
            jf["start_mm"] = v3(f.point);
            break;
        case Surface.sphere:
            jf["kind"] = f.hole ? "hollow sphere" : "sphere";
            jf["diameter_mm"] = plausible(f.diameter);
            jf["center_mm"] = v3(f.point);
            break;
        case Surface.curved:
            jf["kind"] = "freeform";
            break;
        }
        jf["bbox_min_mm"] = v3(f.lo);
        jf["bbox_max_mm"] = v3(f.hi);
        jf["fit_error_mm"] = f.error;
        fs ~= jf;
    }
    j["surfaces"] = fs;
    JSONValue[] ps;
    foreach (p; a.patterns)
    {
        JSONValue jp = ["surfaces": JSONValue(p.members), "count": JSONValue(p.members.length)];
        jp["diameter_mm"] = plausible(a.features[p.members[0]].diameter);
        if (p.circular)
        {
            jp["kind"] = "circle";
            jp["center_mm"] = v3(p.center);
            jp["axis"] = v3(p.axis);
            jp["circle_radius_mm"] = plausible(p.radius);
            jp["step_deg"] = plausible(p.step * 180 / PI);
        }
        else
        {
            jp["kind"] = "row";
            jp["direction"] = v3(p.direction);
            jp["step_mm"] = plausible(p.step);
        }
        ps ~= jp;
    }
    j["patterns"] = ps;
    return j;
}

/// The section of `file` (as for meshOf) by plane `plane` ("xy", "xz" or
/// "yz") at `at` mm along its third axis (z, y or x): its outlines as lines,
/// arcs and circles, and the same as a hackerscad sketch in the plane's
/// axes (x and y for xy, x and z for xz, y and z for yz).
string sectionReport(string file, string part, string plane, double at)
{
    import std.algorithm : sort, max;
    import std.math : abs;
    import hackerscad.geom.outlinefit;
    Vec3 u, v, n;
    double along = at;
    switch (plane)
    {
    case "xy": u = Vec3(1, 0, 0); v = Vec3(0, 1, 0); break;
    case "xz": u = Vec3(1, 0, 0); v = Vec3(0, 0, 1); along = -at; break;   // u × v = -Y
    case "yz": u = Vec3(0, 1, 0); v = Vec3(0, 0, 1); break;
    default: throw new Exception("the plane is xy, xz or yz");
    }
    n = u.cross(v);
    auto m = meshOf(file, part).welded(1e-5);
    auto loops = slice(m, n, along, u, v);
    if (loops.length == 0)
        throw new Exception(format("the plane %s at %g mm does not cut the part", plane, at));
    double size = 1;
    foreach (l; loops)
        foreach (p; l)
            size = max(size, abs(p[0]), abs(p[1]));
    Element[][] fitted;
    foreach (l; loops)
        fitted ~= fit(l, 0.01 + 1e-4 * size);
    // the largest outline first
    double[] areas;
    foreach (l; loops)
        areas ~= abs(area(l));
    auto order = new size_t[loops.length];
    foreach (i, ref o; order)
        o = i;
    order.sort!((a, b) => areas[a] > areas[b]);
    Element[][] sorted;
    foreach (i; order)
        sorted ~= fitted[i];
    immutable axes = plane == "xy" ? "x, y" : plane == "xz" ? "x, z" : "y, z";
    return format("section %s at %g mm (coordinates %s):\n", plane, at, axes) ~ describe(sorted)
        ~ "\n// as a sketch (" ~ axes ~ " of the plane become its x, y):\n" ~ sketchCode(sorted, "section");
}


/// The plane across `axis` ("x", "y" or "z") and its own axes: (u, v, n),
/// with names for the report, as sectionReport uses them.
private void planeAcross(string axis, out Vec3 u, out Vec3 v, out string names, out bool flip)
{
    switch (axis)
    {
    case "z": u = Vec3(1, 0, 0); v = Vec3(0, 1, 0); names = "x, y"; flip = false; break;
    case "y": u = Vec3(1, 0, 0); v = Vec3(0, 0, 1); names = "x, z"; flip = true; break;
    case "x": u = Vec3(0, 1, 0); v = Vec3(0, 0, 1); names = "y, z"; flip = false; break;
    default: throw new Exception("the axis is x, y or z");
    }
}

/// Cuts every `step` mm along `axis`: the holes and pockets met (each one's
/// shape and where it starts and ends, found to a hundredth of a mm) and
/// the outside outline's changes, to see a part as the operations it was
/// made with.
string scanReport(string file, string part, string axis, double step)
{
    import std.algorithm : max, min, sort;
    import std.math : abs, floor, ceil;
    import hackerscad.geom.outlinefit;
    Vec3 u, v;
    string names;
    bool flip;
    planeAcross(axis, u, v, names, flip);
    auto n = u.cross(v);
    auto m = meshOf(file, part).welded(1e-5);
    double lo = double.infinity, hi = -double.infinity;
    foreach (i; 0 .. m.vertexCount)
    {
        immutable a = m.vertex(i).dot(n) * (flip ? -1 : 1);
        lo = min(lo, a);
        hi = max(hi, a);
    }
    if (!(step > 0))
        step = max(0.25, (hi - lo) / 200);

    // the shapes at one level: outside outlines and holes (an outline inside an odd number of others)
    struct Level
    {
        Shape[] outer, holes;
    }
    static bool inside(const P2[] poly, P2 p)
    {
        bool r;
        for (size_t i = 0, j = poly.length - 1; i < poly.length; j = i++)
            if ((poly[i][1] > p[1]) != (poly[j][1] > p[1])
                && p[0] < (poly[j][0] - poly[i][0]) * (p[1] - poly[i][1]) / (poly[j][1] - poly[i][1]) + poly[i][0])
                r = !r;
        return r;
    }
    Level at(double t)
    {
        Level l;
        auto loops = slice(m, n, flip ? -t : t, u, v);
        double size = 1;
        foreach (lp; loops)
            foreach (p; lp)
                size = max(size, abs(p[0]), abs(p[1]));
        foreach (i, lp; loops)
        {
            int depth;
            foreach (j, other; loops)
                if (i != j && inside(other, lp[0]))
                    depth++;
            auto sh = classify(fit(lp, 0.01 + 1e-4 * size));
            (depth % 2 ? l.holes : l.outer) ~= sh;
        }
        return l;
    }
    // the outside followed by its box alone: small details along it change its pieces, not its size
    static bool sameBox(const Shape a, const Shape b)
    {
        import std.math : abs;
        return abs(a.a - b.a) < 0.05 && abs(a.b - b.b) < 0.05 && abs(a.center[0] - b.center[0]) < 0.05
            && abs(a.center[1] - b.center[1]) < 0.05;
    }
    static bool has(const Shape[] list, const Shape s, bool hole)
    {
        foreach (x; list)
            if (hole ? x.same(s, 0.05) : sameBox(x, s))
                return true;
        return false;
    }

    // the levels, and every shape followed from level to level
    struct Run
    {
        Shape shape;
        double from, to;   /// the levels it was seen at, first and last
        bool hole;
    }
    Run[] runs;
    size_t[] open;
    double[] levels;
    for (double t = lo + step / 2; t < hi; t += step)
        levels ~= t;
    foreach (t; levels)
    {
        auto l = at(t);
        size_t[] still;
        foreach (hole; [false, true])
            foreach (sh; hole ? l.holes : l.outer)
            {
                bool found;
                foreach (k; open)
                    if (runs[k].hole == hole && (hole ? runs[k].shape.same(sh, 0.05) : sameBox(runs[k].shape, sh)))
                    {
                        runs[k].to = t;
                        still ~= k;
                        found = true;
                        break;
                    }
                if (!found)
                {
                    runs ~= Run(sh, t, t, hole);
                    still ~= runs.length - 1;
                }
            }
        open = still;
    }
    // each run's ends found more closely: halving the step to where the shape is no longer there
    double edge(const Run r, double inside_, double outside_)
    {
        foreach (_; 0 .. 7)
        {
            immutable mid = (inside_ + outside_) / 2;
            auto l = at(mid);
            if (has(r.hole ? l.holes : l.outer, r.shape, r.hole))
                inside_ = mid;
            else
                outside_ = mid;
        }
        return (inside_ + outside_) / 2;
    }
    foreach (ref r; runs)
    {
        r.from = r.from - step / 2 <= lo ? lo : edge(r, r.from, r.from - step);
        r.to = r.to + step / 2 >= hi ? hi : edge(r, r.to, r.to + step);
    }
    string mm(double x)
    {
        import hackerscad.geom.meshfeatures : plausible;
        immutable p = plausible(x);
        return format("%g", p == 0 ? 0.0 : p);
    }
    string s = format("scan along %s from %s to %s, every %s mm (shapes in %s):\n", axis, mm(lo), mm(hi), mm(step), names);
    // the outside: where it keeps one size for a millimetre or more; the rest are its chamfers and slopes
    s ~= "outside (where its size stays the same for 1 mm or more; cut there with hcad section for its outline):\n";
    size_t brief;
    foreach (r; runs)
        if (!r.hole)
        {
            if (r.to - r.from >= max(1.0, 2 * step))
                s ~= format("  %s to %s: %s × %s, centre (%s, %s)\n", mm(r.from), mm(r.to), mm(r.shape.a), mm(r.shape.b),
                    mm(r.shape.center[0]), mm(r.shape.center[1]));
            else
                brief++;
        }
    if (brief)
        s ~= format("  and %d short changes between them (chamfers, slopes, small steps)\n", brief);
    s ~= "holes and pockets (deeper than 0.2 mm):\n";
    Run[] holes;
    foreach (r; runs)
        if (r.hole && r.to - r.from > 0.2)
            holes ~= r;
    holes.sort!((a, b) => a.from < b.from);
    foreach (r; holes)
        s ~= format("  %s to %s (%s deep): %s\n", mm(r.from), mm(r.to), mm(r.to - r.from), r.shape.toString);
    return s;
}

/// The sections of two parts of a model by one plane, drawn on each other:
/// the original (`b`) in thick grey, the copy (`a`) in thin orange, with
/// both outlines as text. The picture is a PNG.
ubyte[] sectionOverlay(string file, string a, string b, string plane, double at, out string text)
{
    import std.algorithm : max, min;
    import hackerscad.geom.outlinefit;
    import hackerscad.render.raster : Canvas;
    import hackerscad.render.png : encodePng;
    Vec3 u, v;
    double along = at;
    switch (plane)
    {
    case "xy": u = Vec3(1, 0, 0); v = Vec3(0, 1, 0); break;
    case "xz": u = Vec3(1, 0, 0); v = Vec3(0, 0, 1); along = -at; break;
    case "yz": u = Vec3(0, 1, 0); v = Vec3(0, 0, 1); break;
    default: throw new Exception("the plane is xy, xz or yz");
    }
    auto n = u.cross(v);
    auto la = slice(meshOf(file, a).welded(1e-5), n, along, u, v);
    auto lb = slice(meshOf(file, b).welded(1e-5), n, along, u, v);
    if (la.length == 0 && lb.length == 0)
        throw new Exception(format("the plane %s at %g mm cuts neither part", plane, at));
    double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    foreach (ls; [la, lb])
        foreach (l; ls)
            foreach (p; l)
            {
                x0 = min(x0, p[0]);
                x1 = max(x1, p[0]);
                y0 = min(y0, p[1]);
                y1 = max(y1, p[1]);
            }
    enum W = 900, H = 700, ss = 3;
    auto c = Canvas(W * ss, H * ss);
    c.clear();
    immutable k = 0.9 * min(W * ss / max(x1 - x0, 1e-9), H * ss / max(y1 - y0, 1e-9));
    immutable ox = W * ss / 2.0 - k * (x0 + x1) / 2, oy = H * ss / 2.0 + k * (y0 + y1) / 2;
    Vec3 screen(P2 p) => Vec3(ox + k * p[0], oy - k * p[1], 0);
    // a millimetre grid, faint
    immutable gridStep = (x1 - x0) > 60 ? 10.0 : (x1 - x0) > 15 ? 5.0 : 1.0;
    import std.math : floor, ceil;
    for (double g = floor(x0 / gridStep) * gridStep; g <= x1; g += gridStep)
        c.line(screen([g, y0]), screen([g, y1]), Vec3(225, 228, 235), ss, 1);
    for (double g = floor(y0 / gridStep) * gridStep; g <= y1; g += gridStep)
        c.line(screen([x0, g]), screen([x1, g]), Vec3(225, 228, 235), ss, 1);
    foreach (l; lb)
        foreach (i; 0 .. l.length)
            c.line(screen(l[i]), screen(l[(i + 1) % l.length]), Vec3(120, 125, 140), 4.5 * ss, 1);
    foreach (l; la)
        foreach (i; 0 .. l.length)
            c.line(screen(l[i]), screen(l[(i + 1) % l.length]), Vec3(235, 110, 20), 1.6 * ss, 1);
    auto img = c.downsample(ss);
    Element[][] fa, fb;
    double size = 1;
    foreach (ls; [la, lb])
        foreach (l; ls)
            foreach (p; l)
                size = max(size, p[0] < 0 ? -p[0] : p[0], p[1] < 0 ? -p[1] : p[1]);
    foreach (l; la)
        fa ~= fit(l, 0.01 + 1e-4 * size);
    foreach (l; lb)
        fb ~= fit(l, 0.01 + 1e-4 * size);
    immutable axes = plane == "xy" ? "x, y" : plane == "xz" ? "x, z" : "y, z";
    text = format("section %s at %g mm (coordinates %s); grid every %g mm. %s, the copy (thin orange):\n", plane, at, axes,
        gridStep, a) ~ describe(fa) ~ format("%s, the original (thick grey):\n", b) ~ describe(fb);
    return encodePng(img.rgb, img.width, img.height);
}

/// The outline of the part's shadow on a plane (seen along its normal), as
/// lines, arcs and circles with their sizes and as a sketch: for parts made
/// by extruding an outline.
string projectionReport(string file, string part, string plane)
{
    import std.algorithm : max;
    import std.math : abs;
    import hackerscad.geom.outlinefit;
    Vec3 u, v;
    switch (plane)
    {
    case "xy": u = Vec3(1, 0, 0); v = Vec3(0, 1, 0); break;
    case "xz": u = Vec3(1, 0, 0); v = Vec3(0, 0, 1); break;
    case "yz": u = Vec3(0, 1, 0); v = Vec3(0, 0, 1); break;
    default: throw new Exception("the plane is xy, xz or yz");
    }
    // drawn on a fine grid and traced: the union of the projections of a mesh's thousands of faces
    // leaves slivers where neighbouring facets do not meet exactly
    auto m = meshOf(file, part);
    double extent = 1;
    foreach (i; 0 .. m.vertexCount)
        extent = max(extent, abs(m.vertex(i).dot(u)), abs(m.vertex(i).dot(v)));
    immutable pixel = max(0.02, extent / 1500);
    auto loops = shadowLoops(m, u, v, pixel);
    double size = 1;
    foreach (l; loops)
        foreach (p; l)
            size = max(size, abs(p[0]), abs(p[1]));
    Element[][] fitted;
    foreach (l; loops)
        fitted ~= fit(l, 1.5 * pixel, true);
    immutable axes = plane == "xy" ? "x, y" : plane == "xz" ? "x, z" : "y, z";
    return format("the shadow on %s (coordinates %s):\n", plane, axes) ~ describe(fitted)
        ~ "\n// as a sketch:\n" ~ sketchCode(fitted, "shadow");
}
