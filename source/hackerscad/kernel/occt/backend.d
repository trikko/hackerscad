module hackerscad.kernel.occt.backend;

import std.string : fromStringz, toStringz;
import std.conv : to;

import hackerscad.kernel.brep;
import hackerscad.kernel.occt.c;

final class OcctBrep : Brep
{
    private hc_shape* handle;
    private FaceOrigin[] origins;

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

    Brep rect(double w, double h) => wrap(hc_rect(w, h), "rect");
    Brep circle(double r) => wrap(hc_circle(r), "circle");
    Brep polygon(const(double)[] xy) => wrap(hc_polygon(xy.ptr, cast(int)(xy.length / 2)), "polygon");
    Brep text(string s, double size, string font) => wrap(hc_text(s.toStringz, size, font.toStringz), "text");
    Brep profileRound(Brep s, double r) => wrap(hc_profile_round(h(s), r), "round");
    Brep profileOffset(Brep s, double d) => wrap(hc_profile_offset(h(s), d), "offset");
    Brep extrude(Brep p, double height, double taper) => wrap(hc_extrude(h(p), height, taper), "extrude");
    Brep revolve(Brep p, Vec3 o, Vec3 d, double angle) =>
        wrap(hc_revolve(h(p), o.x, o.y, o.z, d.x, d.y, d.z, angle), "revolve");

    Brep outline(const(OutlineSeg)[] segs)
    {
        double[] data;
        foreach (g; segs)
            data ~= [cast(double) g.kind, g.ax, g.ay, g.bx, g.by, g.mx, g.my];
        return wrap(hc_outline(data.ptr, cast(int) segs.length), "outline");
    }
    Brep polyline(const(Vec3)[] pts, bool closed) =>
        wrap(hc_polyline(cast(const(double)*) pts.ptr, cast(int) pts.length, closed), "path");
    Brep spline(const(Vec3)[] pts, bool closed) =>
        wrap(hc_spline(cast(const(double)*) pts.ptr, cast(int) pts.length, closed), "spline");
    Brep helix(double r, double pitch, double height, bool left) => wrap(hc_helix(r, pitch, height, left), "helix");
    void pathFrame(Brep path, bool atEnd, out Vec3 point, out Vec3 tangent)
    {
        double[6] v;
        check(hc_path_frame(h(path), atEnd, v) == 1, "path query");
        point = Vec3(v[0], v[1], v[2]);
        tangent = Vec3(v[3], v[4], v[5]).normalized;
    }
    Brep sweep(Brep profile, Brep path, bool frenet) => wrap(hc_sweep(h(profile), h(path), frenet), "sweep");
    Brep loft(Brep[] profiles, bool ruled)
    {
        const(hc_shape)*[] ps;
        foreach (p; profiles)
            ps ~= h(p);
        return wrap(hc_loft(ps.ptr, cast(int) ps.length, ruled), "loft");
    }

    Brep offset(Brep s, double d) => wrap(hc_offset_solid(h(s), d), "offset");

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

    Brep mirror(Brep s, Vec3 n) => wrap(hc_mirror(h(s), n.x, n.y, n.z), "mirror");

    Brep boolean(Brep a, Brep b, BoolOp op)
    {
        static immutable int[BoolOp.max + 1] codes = [HC_FUSE, HC_CUT, HC_COMMON];
        return wrap(hc_boolean(h(a), h(b), codes[op]), op.to!string);
    }

    EdgeInfo[] edges(Brep s)
    {
        auto r = new EdgeInfo[hc_edge_count(h(s))];
        foreach (i, ref e; r)
        {
            double[17] v;
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
        }
        return r;
    }

    FaceInfo[] faces(Brep s)
    {
        auto r = new FaceInfo[hc_face_count(h(s))];
        foreach (i, ref f; r)
        {
            double[7] v;
            check(hc_face_info(h(s), cast(int) i, v) == 0, "face query");
            f = FaceInfo(Vec3(v[0], v[1], v[2]), Vec3(v[3], v[4], v[5]), v[6]);
        }
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

    Brep chamfer(Brep s, const(int)[] edges, double d) =>
        wrap(hc_chamfer(h(s), edges.ptr, cast(int) edges.length, d), "chamfer");

    Brep facePrism(Brep s, int face, Vec3 v) => wrap(hc_face_prism(h(s), face, v.x, v.y, v.z), "push/pull");

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

    void writeStep(Brep[] parts, string[] names, string path)
    {
        assert(parts.length > 0 && parts.length == names.length);
        hc_shape*[] ps;
        const(char)*[] ns;
        foreach (i, p; parts)
        {
            ps ~= h(p);
            ns ~= names[i].toStringz;
        }
        check(hc_write_step(ps.ptr, ns.ptr, cast(int) ps.length, path.toStringz) == 0, "STEP export");
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
            throw new KernelException(op ~ " failed: " ~ hc_last_error().fromStringz.idup);
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

    auto path = buildPath(tempDir, "hackerscad-test.step");
    scope (exit)
        remove(path);
    k.writeStep([s], ["s"], path);
    assert(isClose(k.volume(k.readStep(path)), k.volume(s), 1e-6));

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
