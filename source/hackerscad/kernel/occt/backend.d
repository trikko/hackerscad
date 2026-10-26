module hackerscad.kernel.occt.backend;

import std.string : fromStringz, toStringz;
import std.conv : to;

import hackerscad.kernel.brep;
import hackerscad.kernel.occt.c;

final class OcctBrep : Brep
{
    private hc_shape* handle;
    private FaceOrigin[] origins;
    private FaceAlso[] also;
    private FaceAlso[] fromEdges;
    private string[] names;   // a STEP file's names of its faces

    private this(hc_shape* h)
    {
        handle = h;
        // the shim records the face history of the operation that just ran
        auto n = hc_history_size();
        if (n == hc_face_count(h))
        {
            auto input = new int[n], index = new int[n];
            hc_history_get(input.ptr, index.ptr);
            origins = new FaceOrigin[n];
            foreach (i; 0 .. n)
                origins[i] = FaceOrigin(input[i], index[i]);
            if (immutable m = hc_face_names_size())
            {
                import std.conv : to;
                names = new string[m];
                foreach (i; 0 .. m)
                    names[i] = hc_face_name(i).fromStringz.idup;
            }
            if (immutable m = hc_history_edges_size())
            {
                auto face = new int[m], ai = new int[m], ax = new int[m];
                hc_history_edges_get(face.ptr, ai.ptr, ax.ptr);
                fromEdges = new FaceAlso[m];
                foreach (i; 0 .. m)
                    fromEdges[i] = FaceAlso(face[i], FaceOrigin(ai[i], ax[i]));
            }
            if (immutable m = hc_history_also_size())
            {
                auto face = new int[m], ai = new int[m], ax = new int[m];
                hc_history_also_get(face.ptr, ai.ptr, ax.ptr);
                also = new FaceAlso[m];
                foreach (i; 0 .. m)
                    also[i] = FaceAlso(face[i], FaceOrigin(ai[i], ax[i]));
            }
        }
        else
            origins = new FaceOrigin[hc_face_count(h)];
    }

    ~this()
    {
        hc_shape_free(handle);
    }
}

final class OcctKernel : BrepKernel
{
    string name() => "occt";

    Brep box(double dx, double dy, double dz) => wrap(hc_box(dx, dy, dz), "box");
    Brep cylinder(double r, double h) => wrap(hc_cylinder(r, h), "cylinder");
    Brep cone(double r1, double r2, double h) => wrap(hc_cone(r1, r2, h), "cone");
    Brep sphere(double r) => wrap(hc_sphere(r), "sphere");
    Brep torus(double major, double minor) => wrap(hc_torus(major, minor), "torus");

    Brep rect(double w, double h) => wrap(hc_rect(w, h), "rect");
    Brep circle(double r) => wrap(hc_circle(r), "circle");
    Brep ellipse(double rx, double ry) => wrap(hc_ellipse(rx, ry), "ellipse");
    Brep polygon(const(double)[] xy) => wrap(hc_polygon(xy.ptr, cast(int)(xy.length / 2)), "polygon");
    Brep splineProfile(const(double)[] xy)
    {
        // a sketch's closed spline: the same curve whichever point it starts at
        Vec3[] pts;
        foreach (i; 0 .. xy.length / 2)
            pts ~= Vec3(xy[2 * i], xy[2 * i + 1], 0);
        double[] poles;
        foreach (q; closedSplinePoles(pts, "smooth outline"))
            poles ~= [q.x, q.y];
        return wrap(hc_spline_profile(poles.ptr, cast(int)(poles.length / 2)), "smooth outline");
    }

    /// The Bézier poles of the closed spline through `pts` (a point repeating the one before, or the
    /// last the first, left out), as a sketch's closed spline has them.
    private static Vec3[] closedSplinePoles(Vec3[] pts, string what)
    {
        import hackerscad.geom.spline : splinePoles;
        double size = 0;
        foreach (q; pts)
            size = size > q.length ? size : q.length;
        Vec3[] kept;
        foreach (q; pts)
            if (kept.length == 0 || (q - kept[$ - 1]).length > 1e-9 * (1 + size))
                kept ~= q;
        while (kept.length > 1 && (kept[0] - kept[$ - 1]).length <= 1e-9 * (1 + size))
            kept = kept[0 .. $ - 1];
        if (kept.length < 3)
            throw new KernelException(what ~ " failed: a closed curve needs at least 3 different points");
        return splinePoles(kept, true);
    }
    Brep text(string s, double size, string font, int style, double spacing, double lineSpacing) =>
        wrap(hc_text(s.toStringz, size, font.toStringz, style, spacing, lineSpacing), "text");
    string fontFamily(string font) => hc_font_family(font.toStringz).fromStringz.idup;
    string[] fontFamilies(out int[] styles)
    {
        import std.algorithm : findSplit;
        import std.conv : to;
        import std.string : splitLines;
        string[] names;
        foreach (line; hc_font_families().fromStringz.idup.splitLines)
            if (auto p = line.findSplit("\t"))
            {
                names ~= p[0];
                styles ~= p[2].to!int;
            }
        return names;
    }
    int fontKnown(string font, int style, out string[] similar)
    {
        import std.string : splitLines;
        if (auto known = hc_font_known(font.toStringz, style))
            return known;
        similar = hc_last_error().fromStringz.idup.splitLines;
        return 0;
    }
    Brep profileRound(Brep s, double r) => wrap(hc_profile_round(h(s), r), "round");
    Brep profileOffset(Brep s, double d) => wrap(hc_profile_offset(h(s), d), "offset");
    Brep extrude(Brep p, double height, double taper) => wrap(hc_extrude(h(p), height, taper), "extrude");
    Brep extrudeShear(Brep p, double height, double dx, double dy) =>
        wrap(hc_extrude_shear(h(p), height, dx, dy), "oblique extrusion");
    Brep revolve(Brep p, Vec3 o, Vec3 d, double angle) =>
        wrap(hc_revolve(h(p), o.x, o.y, o.z, d.x, d.y, d.z, angle), "revolve");

    Brep outline(const(OutlineSeg)[] segs)
    {
        auto data = outlineData(segs);
        return wrap(hc_outline(data.ptr, cast(int)(data.length / 7)), "outline");
    }

    Brep outlineRegions(const(OutlineSeg)[] segs, out int full)
    {
        auto data = outlineData(segs);
        int count;
        auto r = wrap(hc_outline_regions(data.ptr, cast(int)(data.length / 7), &count), "outline's areas");
        full = count;
        return r;
    }

    private static double[] outlineData(const(OutlineSeg)[] segs)
    {
        // seven numbers a segment; a spline's poles follow it, one record each (kind 5)
        double[] data;
        foreach (g; segs)
        {
            immutable poles = g.poles.length / 2;
            data ~= [cast(double) g.kind, g.ax, g.ay, g.bx, g.by, g.kind == OutlineSeg.Kind.spline ? poles : g.mx, g.my];
            if (g.kind == OutlineSeg.Kind.spline)
                foreach (k; 0 .. poles)
                    data ~= [5.0, g.poles[2 * k], g.poles[2 * k + 1], 0, 0, 0, 0];
        }
        return data;
    }
    Brep polyline(const(Vec3)[] pts, bool closed) =>
        wrap(hc_polyline(cast(const(double)*) pts.ptr, cast(int) pts.length, closed), "path");
    Brep spline(const(Vec3)[] pts, bool closed)
    {
        // closed: as a sketch's closed spline, the same curve whichever point it starts at
        if (closed)
        {
            auto poles = closedSplinePoles(pts.dup, "spline");
            return wrap(hc_spline_poles(cast(const(double)*) poles.ptr, cast(int) poles.length), "spline");
        }
        return wrap(hc_spline(cast(const(double)*) pts.ptr, cast(int) pts.length, closed), "spline");
    }
    Brep outlinePath(const(OutlineSeg)[] segs)
    {
        auto data = outlineData(segs);
        return wrap(hc_outline_path(data.ptr, cast(int)(data.length / 7)), "path");
    }
    Brep pathOfPieces(const(PathPiece)[] pieces)
    {
        double[] data;
        foreach (q; pieces)
            data ~= [q.arc ? 1.0 : 0.0, q.a.x, q.a.y, q.a.z, q.b.x, q.b.y, q.b.z, q.m.x, q.m.y, q.m.z];
        return wrap(hc_wire3(data.ptr, cast(int) pieces.length), "path");
    }
    Brep edgesPath(Brep s, const(int)[] edges) => wrap(hc_edges_path(h(s), edges.ptr, cast(int) edges.length), "path");
    Brep projectedCurve(Brep a, Brep b, Vec3 na, Vec3 nb)
    {
        double[3] x = [na.x, na.y, na.z], y = [nb.x, nb.y, nb.z];
        return wrap(hc_projected_curve(h(a), h(b), x, y), "curve from two views");
    }
    Brep helix(double r, double pitch, double height, bool left, double taper = 0) =>
        wrap(hc_helix_tapered(r, pitch, height, left, taper), "helix");
    Brep isoThread(double d, double pitch, double length, double chamfer) =>
        wrap(hc_iso_thread(d, pitch, length, chamfer), "thread");
    Brep joinTouching(Brep a, Brep b) => wrap(hc_join_touching(h(a), h(b), false), "join");

    /// The glued fuse of the performance test (see perftest.d).
    Brep fuseGlued(Brep a, Brep b) => wrap(hc_join_touching(h(a), h(b), true), "glued fuse");

    Brep threadDirect(const(double)[] rz, double lead, double length, double chamfer, double rOut) =>
        wrap(hc_thread_direct(rz.ptr, cast(int)(rz.length / 2), lead, length, chamfer, rOut), "direct thread");

    Brep threadBand(const(double)[] rz, double lead, double length, double slope) =>
        wrap(hc_thread_band(rz.ptr, cast(int)(rz.length / 2), lead, length, slope), "thread");
    Brep gridSolid(const(Vec3)[] pts, int rings, int per) =>
        wrap(hc_grid_solid(cast(const(double)*) pts.ptr, rings, per), "solid through rings");
    Brep gridHollow(const(Vec3)[] outer, int outerRings, const(Vec3)[] inner, int innerRings, int per) =>
        wrap(hc_grid_hollow(cast(const(double)*) outer.ptr, outerRings, cast(const(double)*) inner.ptr, innerRings, per),
            "hollow solid through rings");
    void pathSample(Brep path, int n, out Vec3[] points, out Vec3[] tangents)
    {
        auto v = new double[6 * n];
        check(hc_path_sample(h(path), n, v.ptr) == 1, "path sampling");
        foreach (i; 0 .. n)
        {
            points ~= Vec3(v[6 * i], v[6 * i + 1], v[6 * i + 2]);
            tangents ~= Vec3(v[6 * i + 3], v[6 * i + 4], v[6 * i + 5]);
        }
    }
    void pathFrame(Brep path, bool atEnd, out Vec3 point, out Vec3 tangent)
    {
        double[6] v;
        check(hc_path_frame(h(path), atEnd, v) == 1, "path query");
        point = Vec3(v[0], v[1], v[2]);
        tangent = Vec3(v[3], v[4], v[5]).normalized;
    }
    Brep sweep(Brep profile, Brep path, bool frenet, double twist = 0) =>
        wrap(hc_sweep_twisted(h(profile), h(path), frenet, twist), "sweep");
    Brep sweepRoll(Brep profile, Brep path, const(double)[] angles, Vec3 up, Brep guide)
    {
        double[3] u = [up.x, up.y, up.z];
        return wrap(hc_sweep_ex(h(profile), h(path), 0, angles.ptr, cast(int) angles.length, u,
            guide is null ? null : h(guide)), "sweep");
    }
    Brep loft(Brep[] profiles, bool ruled)
    {
        const(hc_shape)*[] ps;
        foreach (p; profiles)
            ps ~= h(p);
        return wrap(hc_loft(ps.ptr, cast(int) ps.length, ruled), "loft");
    }

    Brep splineEnds(const(Vec3)[] pts, Vec3 t0, Vec3 t1, double weight)
    {
        double[] xyz;
        foreach (p; pts)
            xyz ~= [p.x, p.y, p.z];
        const(double)[3] a = [t0.x, t0.y, t0.z], b = [t1.x, t1.y, t1.z];
        return wrap(hc_spline_ends(xyz.ptr, cast(int) pts.length, a, b, weight), "spline");
    }

    Brep loftAlong(Brep[] profiles, Brep path)
    {
        const(hc_shape)*[] ps;
        foreach (p; profiles)
            ps ~= h(p);
        return wrap(hc_loft_along(ps.ptr, cast(int) ps.length, h(path)), "loft");
    }

    Brep loftOpen(Brep[] paths, bool ruled)
    {
        const(hc_shape)*[] ps;
        foreach (p; paths)
            ps ~= h(p);
        return wrap(hc_loft_open(ps.ptr, cast(int) ps.length, ruled), "surface through paths");
    }

    Brep fill(Brep path, Brep s, const(int)[] edges, const(int)[] tangent, const(Vec3)[] points)
    {
        double[] xyz;
        foreach (p; points)
            xyz ~= [p.x, p.y, p.z];
        return wrap(hc_fill(path is null ? null : h(path), s is null ? null : h(s), edges.ptr, cast(int) edges.length,
            tangent.ptr, cast(int) tangent.length, xyz.ptr, cast(int) points.length), "fill");
    }

    Brep thickenLoft(Brep[] paths, bool ruled, double t)
    {
        const(hc_shape)*[] ps;
        foreach (p; paths)
            ps ~= h(p);
        return wrap(hc_thicken_loft(ps.ptr, cast(int) ps.length, ruled, t), "thicken");
    }
    Brep splitBy(Brep s, Brep tool) => wrap(hc_split_by(h(s), h(tool)), "split");
    Brep thicken(Brep s, double t) => wrap(hc_thicken(h(s), t), "thicken");
    bool normalAt(Brep s, Vec3 p, out Vec3 point, out Vec3 normal)
    {
        double[3] q = [p.x, p.y, p.z];
        double[6] r;
        if (hc_normal_at(h(s), q, r) != 1)
            return false;
        point = Vec3(r[0], r[1], r[2]);
        normal = Vec3(r[3], r[4], r[5]);
        return true;
    }
    Brep enclosed(Brep[] parts, const(Vec3)[2][] planes)
    {
        const(hc_shape)*[] ps;
        foreach (p; parts)
            ps ~= h(p);
        double[] q;
        foreach (pl; planes)
            q ~= [pl[0].x, pl[0].y, pl[0].z, pl[1].x, pl[1].y, pl[1].z];
        return wrap(hc_enclosed(ps.ptr, cast(int) ps.length, q.ptr, cast(int) planes.length), "enclosed");
    }
    Brep sew(Brep[] parts, double tolerance)
    {
        const(hc_shape)*[] ps;
        foreach (p; parts)
            ps ~= h(p);
        int open;
        return wrap(hc_sew(ps.ptr, cast(int) ps.length, tolerance, &open), "sew");
    }

    Brep offset(Brep s, double d, bool sharp = false) => wrap(hc_offset_solid(h(s), d, sharp), "offset");
    int touching(Brep s) => hc_touching_count(h(s));
    Brep bridgeTouching(Brep s, double r) => wrap(hc_bridge_touching(h(s), r), "joining");

    Brep section(Brep s, Vec3 origin, Vec3 normal)
    {
        double[3] o = [origin.x, origin.y, origin.z], n = [normal.x, normal.y, normal.z];
        return wrap(hc_section(h(s), o, n), "section");
    }

    MassProps massProps(Brep s)
    {
        double[7] v;
        check(hc_mass_props(h(s), v) == 0, "mass properties");
        return MassProps(v[0], Vec3(v[1], v[2], v[3]), [v[4], v[5], v[6]]);
    }

    Brep cutAll(Brep a, Brep[] tools)
    {
        const(hc_shape)*[] ts;
        foreach (t; tools)
            ts ~= h(t);
        return wrap(hc_cut_all(h(a), ts.ptr, cast(int) ts.length), "cut");
    }

    Brep wrapTool(Brep s, int face, Brep profile, bool project, Vec3 at, Vec3 dir, double inner, double outer)
    {
        double[3] a = [at.x, at.y, at.z], d = [dir.x, dir.y, dir.z];
        return wrap(hc_wrap_tool(h(s), face, h(profile), project, a.ptr, d.ptr, inner, outer), "wrap");
    }

    Brep wrapDirect(Brep s, int face, Brep profile, bool project, Vec3 at, Vec3 dir, double floor)
    {
        double[3] a = [at.x, at.y, at.z], d = [dir.x, dir.y, dir.z];
        return wrap(hc_wrap_direct(h(s), face, h(profile), project, a.ptr, d.ptr, floor), "wrap");
    }

    Vec3[] spots(Brep s, int n, double margin)
    {
        auto buf = new double[3 * n];
        immutable got = hc_spots(h(s), n, margin, buf.ptr);
        check(got >= 0, "spots");
        Vec3[] r;
        foreach (i; 0 .. got)
            r ~= Vec3(buf[3 * i], buf[3 * i + 1], buf[3 * i + 2]);
        return r;
    }

    int wrapSkipped() => hc_wrap_skipped();

    Brep wrapFlat(Brep s, int face, Vec3 at, out double round, out Vec3 middle)
    {
        double[3] m, a = [at.x, at.y, at.z];
        auto r = wrap(hc_wrap_flat(h(s), face, a.ptr, &round, m.ptr), "wrap");
        middle = Vec3(m[0], m[1], m[2]);
        return r;
    }

    int[] wrapOutside(Brep s, int face, Brep profile, bool project, Vec3 at, Vec3 dir, double floor, out int regions)
    {
        double[3] a = [at.x, at.y, at.z], d = [dir.x, dir.y, dir.z];
        int n;
        auto buf = new int[](4096);
        immutable got = hc_wrap_outside(h(s), face, h(profile), project, a.ptr, d.ptr, floor, buf.ptr, cast(int) buf.length, &n);
        check(got >= 0, "wrap");
        regions = n;
        if (got > buf.length)
        {
            buf.length = got;
            hc_wrap_outside(h(s), face, h(profile), project, a.ptr, d.ptr, floor, buf.ptr, got, &n);
        }
        return buf[0 .. got];
    }

    Brep profileRegions(Brep profile, const(int)[] which) =>
        wrap(hc_profile_regions(h(profile), which.ptr, cast(int) which.length), "regions");

    Brep threadSleeve(const(double)[] rz, double lead, double length, int sides, double rPoly) =>
        wrap(hc_thread_sleeve(rz.ptr, cast(int)(rz.length / 2), lead, length, sides, rPoly), "thread");
    Brep joinCoincident(Brep a, Brep b) => wrap(hc_join_coincident(h(a), h(b)), "union");

    Brep tiles(Brep[] motifs, const(double)[] place, Brep region, int mode, double minArea = 0)
    {
        const(hc_shape)*[] ms;
        foreach (m; motifs)
            ms ~= h(m);
        return wrap(hc_tiles(ms.ptr, cast(int) ms.length, place.ptr, cast(int)(place.length / 4),
            region is null ? null : h(region), mode, minArea), "tiles");
    }

    Brep fuseAll(Brep[] parts)
    {
        const(hc_shape)*[] ps;
        foreach (p; parts)
            ps ~= h(p);
        return wrap(hc_fuse_all(ps.ptr, cast(int) ps.length), "union");
    }

    ViewSegment[] hiddenLines(Brep s, Vec3 dir, Vec3 up, double deflection)
    {
        double* buf;
        immutable n = hc_hlr(h(s), dir.x, dir.y, dir.z, up.x, up.y, up.z, deflection, &buf);
        check(n >= 0, "hidden line removal");
        scope (exit)
            hc_free(buf);
        auto r = new ViewSegment[n];
        foreach (i, ref g; r)
        {
            auto v = buf[i * 5 .. i * 5 + 5];
            g = ViewSegment(v[0], v[1], v[2], v[3], cast(ViewSegment.Kind) cast(int) v[4]);
        }
        return r;
    }

    Vec3[][] faceLoops(Brep s, int face, double deflection)
    {
        double* buf;
        immutable n = hc_face_loops(h(s), face, deflection, &buf);
        check(n >= 0, "face loops");
        scope (exit)
            hc_free(buf);
        Vec3[][] r;
        size_t o;
        foreach (_; 0 .. n)
        {
            immutable count = cast(size_t) buf[o++];
            Vec3[] loop;
            foreach (k; 0 .. count)
            {
                loop ~= Vec3(buf[o], buf[o + 1], buf[o + 2]);
                o += 3;
            }
            r ~= loop;
        }
        return r;
    }

    Brep translate(Brep s, Vec3 v) => wrap(hc_translate(h(s), v.x, v.y, v.z), "translate");

    Brep rotate(Brep s, Vec3 axis, double angleRad) =>
        wrap(hc_rotate(h(s), axis.x, axis.y, axis.z, angleRad), "rotate");

    Brep scale(Brep s, double factor) => wrap(hc_scale(h(s), factor), "scale");
    Brep scaleXyz(Brep s, double sx, double sy, double sz) => wrap(hc_scale_xyz(h(s), sx, sy, sz), "scale");

    Brep mirror(Brep s, Vec3 n) => wrap(hc_mirror(h(s), n.x, n.y, n.z), "mirror");

    Brep boolean(Brep a, Brep b, BoolOp op)
    {
        static immutable int[BoolOp.max + 1] codes = [HC_FUSE, HC_CUT, HC_COMMON];
        return wrap(hc_boolean(h(a), h(b), codes[op]), op.to!string);
    }

    Brep booleanMerged(Brep a, Brep b, BoolOp op)
    {
        static immutable int[BoolOp.max + 1] codes = [HC_FUSE, HC_CUT, HC_COMMON];
        return wrap(hc_boolean_merged(h(a), h(b), codes[op]), op.to!string);
    }

    EdgeInfo[] edges(Brep s)
    {
        auto r = new EdgeInfo[hc_edge_count(h(s))];
        foreach (i, ref e; r)
        {
            double[23] v;
            immutable kind = hc_edge_info(h(s), cast(int) i, v);
            check(kind >= 0, "edge query");
            e.kind = kind == HC_EDGE_LINE ? EdgeKind.line : kind == HC_EDGE_CIRCLE ? EdgeKind.circle : EdgeKind.other;
            e.start = Vec3(v[0], v[1], v[2]);
            e.end = Vec3(v[3], v[4], v[5]);
            e.mid = Vec3(v[6], v[7], v[8]);
            e.center = Vec3(v[9], v[10], v[11]);
            e.axis = Vec3(v[12], v[13], v[14]);
            e.radius = v[15];
            e.length = v[16];
            e.startTangent = Vec3(v[17], v[18], v[19]);
            e.endTangent = Vec3(v[20], v[21], v[22]);
        }
        return r;
    }

    int[] faceOuterEdges(Brep s, int face)
    {
        auto buf = new int[64];
        immutable n = hc_face_outer_edges(h(s), face, buf.ptr, cast(int) buf.length);
        check(n >= 0, "face loop query");
        if (n > buf.length)
        {
            buf = new int[n];
            check(hc_face_outer_edges(h(s), face, buf.ptr, n) == n, "face loop query");
        }
        return buf[0 .. n].dup;
    }

    Brep[] profileParts(Brep p, int which)
    {
        immutable n = hc_profile_part_count(h(p), which);
        check(n >= 0, "profile parts");
        Brep[] r;
        foreach (i; 0 .. n)
            r ~= wrap(hc_profile_part(h(p), which, i), "profile part");
        return r;
    }

    FaceInfo[] faces(Brep s)
    {
        // each face's area and centre is an integration over it, ~8 ms on a thread's helical
        // faces: on the threads there are (--threads), the faces being independent
        import std.parallelism : parallel;
        auto r = new FaceInfo[hc_face_count(h(s))];
        auto shape = h(s);
        shared bool failed;
        foreach (i, ref f; parallel(r, 4))
        {
            double[8] v;
            if (hc_face_info(shape, cast(int) i, v) != 0)
            {
                failed = true;
                continue;
            }
            f = FaceInfo(Vec3(v[0], v[1], v[2]), Vec3(v[3], v[4], v[5]), v[6], v[7] != 0);
        }
        check(!failed, "face query");
        return r;
    }

    Brep[] solids(Brep s)
    {
        Brep[] r;
        foreach (i; 0 .. hc_solid_count(h(s)))
            r ~= wrap(hc_solid(h(s), i), "solid extraction");
        return r;
    }

    size_t faceCount(Brep s) => hc_face_count(h(s));

    FaceOrigin[] faceOrigins(Brep s)
    {
        auto o = cast(OcctBrep) s;
        h(s);
        return o.origins;
    }

    FaceAlso[] faceFromEdges(Brep s)
    {
        auto o = cast(OcctBrep) s;
        h(s);
        return o.fromEdges;
    }

    FaceAlso[] faceOriginsAlso(Brep s)
    {
        auto o = cast(OcctBrep) s;
        h(s);
        return o.also;
    }

    int[2][] edgeFaces(Brep s)
    {
        auto r = new int[2][hc_edge_count(h(s))];
        check(hc_edge_faces(h(s), cast(int*) r.ptr) == r.length, "edge adjacency");
        return r;
    }

    Brep draft(Brep s, const(int)[] faces, double angle, Vec3 pull, Vec3 neutral)
    {
        auto p = pull.normalized;
        return wrap(hc_draft(h(s), faces.ptr, cast(int) faces.length, angle, neutral.x, neutral.y, neutral.z,
            p.x, p.y, p.z), "draft");
    }

    double distance(Brep a, Brep b, out Vec3 onA, out Vec3 onB)
    {
        double[6] v;
        immutable d = hc_distance(h(a), h(b), v);
        check(d >= 0, "distance");
        onA = Vec3(v[0], v[1], v[2]);
        onB = Vec3(v[3], v[4], v[5]);
        return d;
    }

    Brep fillet(Brep s, const(int)[] edges, double r) =>
        wrap(hc_fillet(h(s), edges.ptr, cast(int) edges.length, r), "fillet");

    Brep filletVar(Brep s, const(int)[] edges, double r1, double r2) =>
        wrap(hc_fillet_var(h(s), edges.ptr, cast(int) edges.length, r1, r2), "fillet");

    Brep chamfer(Brep s, const(int)[] edges, double d) =>
        wrap(hc_chamfer(h(s), edges.ptr, cast(int) edges.length, d), "chamfer");

    Brep chamferOn(Brep s, const(int)[] edges, const(int)[] faces, double d, double d2, double angle)
    {
        assert(edges.length == faces.length);
        return wrap(hc_chamfer_on(h(s), edges.ptr, faces.ptr, cast(int) edges.length, d, d2, angle), "chamfer");
    }

    bool inside(Brep s, Vec3 p)
    {
        immutable r = hc_point_inside(h(s), p.x, p.y, p.z);
        check(r >= 0, "point classification");
        return r == 1;
    }

    bool faceCylinder(Brep s, int face, out CylinderInfo info)
    {
        double[11] v;
        immutable r = hc_face_cylinder(h(s), face, v);
        check(r >= 0, "face query");
        if (r == 0)
            return false;
        info = CylinderInfo(Vec3(v[0], v[1], v[2]), Vec3(v[3], v[4], v[5]), v[6], v[7], v[8], v[9], v[10] != 0);
        return true;
    }

    bool faceAxis(Brep s, int face, out Vec3 origin, out Vec3 direction)
    {
        double[6] v;
        immutable r = hc_face_axis(h(s), face, v);
        check(r >= 0, "face query");
        if (r == 0)
            return false;
        origin = Vec3(v[0], v[1], v[2]);
        direction = Vec3(v[3], v[4], v[5]);
        return true;
    }

    Brep sweepSolid(Brep s, Vec3 v) => wrap(hc_sweep_solid(h(s), v.x, v.y, v.z), "sweep");

    Brep facePrism(Brep s, int face, Vec3 v) => wrap(hc_face_prism(h(s), face, v.x, v.y, v.z), "push/pull");

    Brep shellWalls(Brep s, const(int)[] faces, double thickness, const(int)[] walls, const(double)[] values,
        bool outward)
    {
        assert(walls.length == values.length);
        return wrap(hc_shell_walls(h(s), faces.ptr, cast(int) faces.length, thickness, walls.ptr, values.ptr,
            cast(int) walls.length, outward), "shell");
    }

    Brep removeFaces(Brep s, const(int)[] faces) =>
        wrap(hc_remove_faces(h(s), faces.ptr, cast(int) faces.length), "removeFaces");
    Brep facesOpen(Brep s, const(int)[] faces) =>
        wrap(hc_faces_open(h(s), faces.ptr, cast(int) faces.length), "removeFaces");
    Brep offsetFaces(Brep s, const(int)[] faces, double d) =>
        wrap(hc_offset_faces(h(s), faces.ptr, cast(int) faces.length, d), "offsetFaces");

    Brep shell(Brep s, const(int)[] faces, double thickness) =>
        wrap(hc_shell(h(s), faces.ptr, cast(int) faces.length, thickness), "shell");

    double volume(Brep s)
    {
        immutable v = hc_volume(h(s));
        check(v >= 0, "volume");
        return v;
    }

    double area(Brep s)
    {
        immutable a = hc_area(h(s));
        check(a >= 0, "area");
        return a;
    }

    BBox bbox(Brep s)
    {
        double[6] v;
        check(hc_bbox(h(s), v) == 0, "bbox");
        return BBox(Vec3(v[0], v[1], v[2]), Vec3(v[3], v[4], v[5]));
    }

    bool isValid(Brep s) => hc_is_valid(h(s)) == 1;

    Mesh tessellate(Brep s, double linearDeflection, double angularDeflection)
    {
        auto m = hc_tessellate(h(s), linearDeflection, angularDeflection);
        check(m !is null, "tessellate");
        scope (exit)
            hc_mesh_free(m);
        Mesh r;
        r.verts = m.verts[0 .. m.nverts * 3].dup;
        r.tris = cast(uint[]) m.tris[0 .. m.ntris * 3].dup;
        r.faceStart = cast(uint[]) m.face_start[0 .. m.nfaces + 1].dup;
        return r;
    }

    Brep fromMesh(const Mesh m) =>
        wrap(hc_from_mesh(m.verts.ptr, cast(int) m.vertexCount, cast(const(int)*) m.tris.ptr, cast(int) m.triangleCount, 1e-5),
            "mesh import");

    void writeStep(Brep[] parts, string[] names, string path, string[][] faceNames = null, string system = null,
        string note = null)
    {
        assert(parts.length > 0 && parts.length == names.length);
        hc_shape*[] ps;
        const(char)*[] ns, fs;
        foreach (i, p; parts)
        {
            ps ~= h(p);
            ns ~= names[i].toStringz;
            // a name for every face of the part, in its order
            if (faceNames.length)
                foreach (f; 0 .. faceCount(p))
                    fs ~= i < faceNames.length && f < faceNames[i].length ? faceNames[i][f].toStringz : "".ptr;
        }
        check(hc_write_step(ps.ptr, ns.ptr, cast(int) ps.length, path.toStringz, fs.length ? fs.ptr : null,
            system.toStringz, note.toStringz) == 0, "STEP export");
    }

    string[] faceNames(Brep s)
    {
        auto o = cast(OcctBrep) s;
        h(s);
        return o.names;
    }

    Brep readStep(string path) => wrap(hc_read_step(path.toStringz), "STEP import");

private:
    static hc_shape* h(Brep s)
    {
        auto o = cast(OcctBrep) s;
        if (o is null)
            throw new KernelException("shape does not belong to the OCCT kernel");
        return o.handle;
    }

    static Brep wrap(hc_shape* p, string op)
    {
        check(p !is null, op);
        return new OcctBrep(p);
    }

    static void check(bool ok, string op)
    {
        if (!ok)
        {
            import std.string : chompPrefix;
            // OpenCascade's own failures carry their class's name: not for the user
            throw new KernelException(op ~ " failed: " ~ hc_last_error().fromStringz.idup.chompPrefix("Standard_Failure: "));
        }
    }
}

version (unittest)
{
    import std.algorithm : filter, map;
    import std.array : array;
    import std.math : isClose, PI, abs;
    import std.range : iota;

    // 40x30x20 box centred on the origin, as in the examples of the plan
    private Brep centredBox(OcctKernel k) => k.translate(k.box(40, 30, 20), Vec3(-20, -15, -10));
}

unittest
{
    auto k = new OcctKernel;
    auto box = centredBox(k);
    // cylinder r=8 h=20 centred on the origin then raised by 5: z in [-5, 15]
    auto cyl = k.translate(k.cylinder(8, 20), Vec3(0, 0, -10 + 5));
    auto s = k.boolean(box, cyl, BoolOp.cut);

    assert(k.isValid(s));
    assert(isClose(k.volume(s), 24_000 - PI * 64 * 15, 1e-6));
    auto bb = k.bbox(s);
    assert(isClose(bb.size.x, 40, 1e-6) && isClose(bb.size.z, 20, 1e-6));
}

unittest
{
    auto k = new OcctKernel;
    auto box = centredBox(k);

    // vertical edges: lines parallel to Z
    auto edges = k.edges(box);
    auto vertical = edges.length.iota
        .filter!(i => edges[i].kind == EdgeKind.line && abs(edges[i].direction.z) > 0.999)
        .map!(i => cast(int) i).array;
    assert(vertical.length == 4);
    auto f = k.fillet(box, vertical, 5);
    assert(isClose(k.volume(f), 24_000 - 4 * (25 - PI * 25 / 4) * 20, 1e-6));

    // open the top face and hollow with 2 mm walls
    auto faces = k.faces(box);
    auto top = faces.length.iota.filter!(i => faces[i].normal.z > 0.999).map!(i => cast(int) i).array;
    assert(top.length == 1);
    auto sh = k.shell(box, top, 2);
    assert(isClose(k.volume(sh), 24_000 - 36 * 26 * 18, 1e-6));
}

unittest
{
    import std.file : tempDir, remove;
    import std.path : buildPath;

    auto k = new OcctKernel;
    auto s = k.boolean(centredBox(k), k.sphere(12), BoolOp.cut);

    auto m = k.tessellate(s, 0.05, 0.3).welded;
    assert(m.isClosed);
    assert(isClose(m.volume, k.volume(s), 1e-2));

    import std.format : format;
    import std.process : thisProcessID;
    auto path = buildPath(tempDir, format("hackerscad-test-%d.step", thisProcessID));
    scope (exit)
        remove(path);
    k.writeStep([s], ["s"], path);
    assert(isClose(k.volume(k.readStep(path)), k.volume(s), 1e-6));
    assert(k.faceNames(k.readStep(path)).length == 0);
    // the faces' names and the program, kept in the file
    auto named = new string[][1];
    named[0] = new string[k.faceCount(s)];
    named[0][2] = "lid;seat";
    k.writeStep([s], ["s"], path, named, "hackerscad test");
    import std.file : readText;
    import std.algorithm : canFind;
    assert(readText(path).canFind("'hackerscad test'"));
    auto back = k.readStep(path);
    auto names = k.faceNames(back);
    assert(names.length == k.faceCount(back) && names.canFind("lid;seat"));

    import std.exception : assertThrown;
    assertThrown!KernelException(k.fillet(s, [0], 1000));
}

unittest
{
    // face history: a cut keeps the box faces and adds the hole's wall
    auto k = new OcctKernel;
    auto box = k.box(10, 10, 10);
    assert(k.faceOrigins(box).length == 6);
    foreach (o; k.faceOrigins(box))
        assert(o.input == -1, "primitive faces are new");
    auto moved = k.translate(box, Vec3(1, 2, 3));
    foreach (i, o; k.faceOrigins(moved))
        assert(o.input == 0 && o.index >= 0);

    auto hole = k.translate(k.cylinder(2, 20), Vec3(5, 5, -5));
    auto cut = k.boolean(box, hole, BoolOp.cut);
    auto origins = k.faceOrigins(cut);
    assert(origins.length == 7);
    size_t fromBox, fromHole;
    foreach (o; origins)
    {
        fromBox += o.input == 0;
        fromHole += o.input == 1;
    }
    assert(fromBox == 6 && fromHole == 1);

    // fillet faces are created by the fillet
    auto f = k.fillet(box, [0], 1);
    size_t created;
    foreach (o; k.faceOrigins(f))
        created += o.input == -1;
    assert(created == 1);

    // every edge of a closed box touches two faces
    foreach (pair; k.edgeFaces(box))
        assert(pair[0] >= 0 && pair[1] >= 0 && pair[0] != pair[1]);

    // triangles are grouped by face
    auto m = k.tessellate(cut, 0.05, 0.3);
    assert(m.faceStart.length == 8 && m.faceStart[$ - 1] == m.triangleCount);
    assert(m.faceOf(0) == 0 && m.faceOf(m.triangleCount - 1) == 6);

    Vec3 a, b;
    assert(isClose(k.distance(box, k.translate(box, Vec3(15, 0, 0)), a, b), 5));
    // a solid inside another one is at distance 0, both ways round
    auto small = k.translate(k.box(1, 1, 1), Vec3(0, 0, 2));
    assert(k.distance(box, small, a, b) == 0 && k.distance(small, box, a, b) == 0);
}
