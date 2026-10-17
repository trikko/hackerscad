/// A BrepKernel that remembers results across evaluations.
///
/// Every solid gets a content key: the operation, its parameters and the
/// keys of its inputs. Asking again for the same operation on the same
/// inputs returns the very same solid, so after an edit only the operations
/// downstream of the change are computed again. Queries (faces, bounding
/// boxes, tessellations…) and failures are cached too. Entries not used in
/// the last runs are dropped.
module hackerscad.kernel.cache;

import std.traits : isNumeric;
import std.algorithm : map;
import std.array : array, join;

import hackerscad.kernel.brep;

final class CachingKernel : BrepKernel
{
    BrepKernel inner;
    size_t hits, misses;

    this(BrepKernel inner)
    {
        this.inner = inner;
    }

    string name() => "cached " ~ inner.name;

    /// Marks the start of an evaluation (for eviction and statistics).
    void beginRun()
    {
        run++;
        hits = misses = 0;
    }

    /// Drops what the last `keep` runs did not use.
    void endRun(uint keep = 2)
    {
        ulong[] stale;
        foreach (k, e; entries)
            if (e.lastRun + keep <= run)
                stale ~= k;
        foreach (k; stale)
        {
            if (auto e = k in entries)
                if (e.brep !is null)
                    keys.remove(e.brep);
            entries.remove(k);
        }
    }

    size_t size() const => entries.length;

    // ---------------------------------------------------------------- operations

    Brep box(double dx, double dy, double dz) => op(key("box", dx, dy, dz), inner.box(dx, dy, dz));
    Brep cylinder(double r, double h) => op(key("cylinder", r, h), inner.cylinder(r, h));
    Brep cone(double r1, double r2, double h) => op(key("cone", r1, r2, h), inner.cone(r1, r2, h));
    Brep sphere(double r) => op(key("sphere", r), inner.sphere(r));
    Brep torus(double major, double minor) => op(key("torus", major, minor), inner.torus(major, minor));

    Brep rect(double w, double h) => op(key("rect", w, h), inner.rect(w, h));
    Brep circle(double r) => op(key("circle", r), inner.circle(r));
    Brep ellipse(double rx, double ry) => op(key("ellipse", rx, ry), inner.ellipse(rx, ry));
    Brep polygon(const(double)[] xy) => op(key("polygon", xy), inner.polygon(xy));
    Brep splineProfile(const(double)[] xy) => op(key("splineProfile", xy), inner.splineProfile(xy));
    Brep text(string t, double size, string font) => op(key("text", t, size, font), inner.text(t, size, font));
    Brep profileRound(Brep s, double r) => op(key("round", s, r), inner.profileRound(s, r));
    Brep profileOffset(Brep s, double d) => op(key("offset", s, d), inner.profileOffset(s, d));
    Brep extrude(Brep p, double h, double taper) => op(key("extrude", p, h, taper), inner.extrude(p, h, taper));
    Brep extrudeShear(Brep p, double h, double dx, double dy) =>
        op(key("extrudeShear", p, h, dx, dy), inner.extrudeShear(p, h, dx, dy));
    Brep revolve(Brep p, Vec3 o, Vec3 d, double angle) => op(key("revolve", p, o, d, angle), inner.revolve(p, o, d, angle));

    Brep outlineRegions(const(OutlineSeg)[] segs, out int full) => inner.outlineRegions(segs, full);
    int[] faceOuterEdges(Brep s, int face) => inner.faceOuterEdges(s, face);
    Brep[] profileParts(Brep p, int which) => inner.profileParts(p, which);
    Brep outline(const(OutlineSeg)[] segs) =>
        op(key("outline", segs.map!(g => [cast(double) g.kind, g.ax, g.ay, g.bx, g.by, g.mx, g.my] ~ g.poles).join),
            inner.outline(segs));
    Brep polyline(const(Vec3)[] pts, bool closed) => op(key("polyline", flatten(pts), closed), inner.polyline(pts, closed));
    Brep spline(const(Vec3)[] pts, bool closed) => op(key("spline", flatten(pts), closed), inner.spline(pts, closed));
    Brep outlinePath(const(OutlineSeg)[] segs) =>
        op(key("outlinePath", segs.map!(g => [cast(double) g.kind, g.ax, g.ay, g.bx, g.by, g.mx, g.my] ~ g.poles).join),
            inner.outlinePath(segs));
    Brep pathOfPieces(const(PathPiece)[] pieces) =>
        op(key("pathOfPieces", pieces.map!(q => [q.arc ? 1.0 : 0.0] ~ flatten([q.a, q.b, q.m])).join), inner.pathOfPieces(pieces));
    Brep edgesPath(Brep s, const(int)[] edges) => op(key("edgesPath", s, edges.map!(e => cast(double) e).array),
        inner.edgesPath(s, edges));
    Brep projectedCurve(Brep a, Brep b, Vec3 na, Vec3 nb) =>
        op(key("projectedCurve", a, b, na, nb), inner.projectedCurve(a, b, na, nb));
    Brep helix(double r, double pitch, double height, bool left, double taper = 0) =>
        op(key("helix", r, pitch, height, left, taper), inner.helix(r, pitch, height, left, taper));
    Brep threadBand(const(double)[] rz, double lead, double length, double slope) =>
        op(key("threadBand", rz, lead, length, slope), inner.threadBand(rz, lead, length, slope));
    Brep isoThread(double d, double pitch, double length, double chamfer) =>
        op(key("isoThread", d, pitch, length, chamfer), inner.isoThread(d, pitch, length, chamfer));
    void pathFrame(Brep path, bool atEnd, out Vec3 point, out Vec3 tangent) => inner.pathFrame(path, atEnd, point, tangent);
    void pathSample(Brep path, int n, out Vec3[] points, out Vec3[] tangents) => inner.pathSample(path, n, points, tangents);
    Brep gridSolid(const(Vec3)[] pts, int rings, int per) => op(key("gridSolid", flatten(pts), rings, per), inner.gridSolid(pts, rings, per));
    Brep gridHollow(const(Vec3)[] outside, int outerRings, const(Vec3)[] inside, int innerRings, int per) =>
        op(key("gridHollow", flatten(outside), outerRings, flatten(inside), innerRings, per),
            inner.gridHollow(outside, outerRings, inside, innerRings, per));
    Brep sweep(Brep profile, Brep path, bool frenet, double twist = 0) =>
        op(key("sweep", profile, path, frenet, twist), inner.sweep(profile, path, frenet, twist));
    Brep sweepRoll(Brep profile, Brep path, const(double)[] angles, Vec3 up, Brep guide) =>
        guide is null ? op(key("sweepRoll", profile, path, angles, up), inner.sweepRoll(profile, path, angles, up, null))
            : op(key("sweepRoll", profile, path, angles, up, guide), inner.sweepRoll(profile, path, angles, up, guide));
    Brep loftOpen(Brep[] paths, bool ruled)
    {
        ulong[] ks;
        foreach (p; paths)
            ks ~= keyOf(p);
        return op(key("loftOpen", cast(const(double)[]) ks.map!(x => cast(double) x).array, ruled), inner.loftOpen(paths, ruled));
    }
    Brep splitBy(Brep s, Brep tool) => op(key("splitBy", s, tool), inner.splitBy(s, tool));
    Brep thicken(Brep s, double t) => op(key("thicken", s, t), inner.thicken(s, t));
    bool normalAt(Brep s, Vec3 p, out Vec3 point, out Vec3 normal) => inner.normalAt(s, p, point, normal);
    Brep sew(Brep[] parts, double tolerance)
    {
        ulong[] ks;
        foreach (p; parts)
            ks ~= keyOf(p);
        return op(key("sew", cast(const(double)[]) ks.map!(x => cast(double) x).array, tolerance), inner.sew(parts, tolerance));
    }
    Brep loft(Brep[] profiles, bool ruled)
    {
        ulong[] ks;
        foreach (p; profiles)
            ks ~= keyOf(p);
        return op(key("loft", cast(const(double)[]) ks.map!(x => cast(double) x).array, ruled), inner.loft(profiles, ruled));
    }

    Brep translate(Brep s, Vec3 v) => op(key("translate", s, v), inner.translate(s, v));
    Brep rotate(Brep s, Vec3 axis, double angle) => op(key("rotate", s, axis, angle), inner.rotate(s, axis, angle));
    Brep scale(Brep s, double f) => op(key("scale", s, f), inner.scale(s, f));
    Brep scaleXyz(Brep s, double sx, double sy, double sz) => op(key("scaleXyz", s, sx, sy, sz), inner.scaleXyz(s, sx, sy, sz));
    Brep mirror(Brep s, Vec3 n) => op(key("mirror", s, n), inner.mirror(s, n));
    Brep boolean(Brep a, Brep b, BoolOp o) => op(key("boolean", a, b, cast(int) o), inner.boolean(a, b, o));
    Brep booleanMerged(Brep a, Brep b, BoolOp o) =>
        op(key("booleanMerged", a, b, cast(int) o), inner.booleanMerged(a, b, o));

    Brep offset(Brep s, double d) => op(key("solidOffset", s, d), inner.offset(s, d));
    int touching(Brep s) => query!"touching"(s, inner.touching(s));
    Brep bridgeTouching(Brep s, double r) => op(key("bridgeTouching", s, r), inner.bridgeTouching(s, r));
    MassProps massProps(Brep s) => inner.massProps(s);
    Brep section(Brep s, Vec3 o, Vec3 n) => op(key("section", s, o, n), inner.section(s, o, n));

    Brep fuseAll(Brep[] parts)
    {
        ulong[] ks;
        foreach (p; parts)
            ks ~= keyOf(p);
        return op(key("fuseAll", cast(const(double)[]) ks.map!(x => cast(double) x).array), inner.fuseAll(parts));
    }

    Brep[] solids(Brep s)
    {
        immutable base = key("solids", s);
        auto e = touch(base);
        if (e !is null && e.list !is null)
            return e.list;
        auto r = inner.solids(s);
        foreach (i, b; r)
            remember(mix(base, i), b);
        store(base).list = r;
        return r;
    }

    Brep fillet(Brep s, const(int)[] edges, double r) => op(key("fillet", s, edges, r), inner.fillet(s, edges, r));
    Brep chamfer(Brep s, const(int)[] edges, double d) => op(key("chamfer", s, edges, d), inner.chamfer(s, edges, d));
    bool faceCylinder(Brep s, int face, out CylinderInfo info) => inner.faceCylinder(s, face, info);
    bool inside(Brep s, Vec3 p) => inner.inside(s, p);
    Brep facePrism(Brep s, int face, Vec3 v) => op(key("facePrism", s, face, v), inner.facePrism(s, face, v));
    Brep shell(Brep s, const(int)[] faces, double t) => op(key("shell", s, faces, t), inner.shell(s, faces, t));
    Brep draft(Brep s, const(int)[] faces, double angle, Vec3 pull, Vec3 neutral) =>
        op(key("draft", s, faces, angle, pull, neutral), inner.draft(s, faces, angle, pull, neutral));

    // ---------------------------------------------------------------- queries

    EdgeInfo[] edges(Brep s) => query!"edges"(s, inner.edges(s));
    FaceInfo[] faces(Brep s) => query!"faces"(s, inner.faces(s));
    FaceOrigin[] faceOrigins(Brep s) => inner.faceOrigins(s);
    size_t faceCount(Brep s) => inner.faceCount(s);   // stored on the solid itself
    int[2][] edgeFaces(Brep s) => query!"edgeFaces"(s, inner.edgeFaces(s));
    double volume(Brep s) => query!"volume"(s, inner.volume(s));
    double area(Brep s) => query!"area"(s, inner.area(s));
    BBox bbox(Brep s) => query!"bbox"(s, inner.bbox(s));
    bool isValid(Brep s) => query!"isValid"(s, inner.isValid(s));

    double distance(Brep a, Brep b, out Vec3 onA, out Vec3 onB)
    {
        auto e = touch(key("distance", a, b));
        if (e !is null && e.hasDistance)
        {
            onA = e.points[0];
            onB = e.points[1];
            return e.distance;
        }
        immutable d = inner.distance(a, b, onA, onB);
        auto n = store(key("distance", a, b));
        n.hasDistance = true;
        n.distance = d;
        n.points = [onA, onB];
        return d;
    }

    Mesh tessellate(Brep s, double linear, double angular)
    {
        immutable k = key("tessellate", s, linear, angular);
        if (auto e = touch(k))
            if (e.hasMesh)
                return e.mesh;
        auto m = inner.tessellate(s, linear, angular);
        auto n = store(k);
        n.mesh = m;
        n.hasMesh = true;
        return m;
    }

    Brep fromMesh(const Mesh m) => op(key("fromMesh", cast(const(double)[]) m.verts.map!(v => cast(double) v).array,
        cast(const(int)[]) m.tris), inner.fromMesh(m));

    ViewSegment[] hiddenLines(Brep s, Vec3 dir, Vec3 up, double deflection)
    {
        static final class Box
        {
            ViewSegment[] value;
        }

        immutable k = key("hlr", s, dir, up, deflection);
        if (auto e = touch(k))
            if (auto b = cast(Box) e.queryResult)
                return b.value;
        auto b = new Box;
        b.value = inner.hiddenLines(s, dir, up, deflection);
        store(k).queryResult = b;
        return b.value;
    }

    Vec3[][] faceLoops(Brep s, int face, double deflection) => inner.faceLoops(s, face, deflection);

    // files can change on disk: not cached
    void writeStep(Brep[] parts, string[] names, string path) => inner.writeStep(parts, names, path);
    Brep readStep(string path) => remember(fresh(), inner.readStep(path));

private:

    struct Entry
    {
        Brep brep;
        string error;      /// the operation failed with this message
        Brep[] list;
        Mesh mesh;
        bool hasMesh;
        double distance;
        Vec3[] points;
        bool hasDistance;
        Object queryResult;
        ulong lastRun;
    }

    Entry[ulong] entries;
    ulong[Brep] keys;      /// solid identity → content key
    ulong run, counter;

    Entry* touch(ulong k)
    {
        auto e = k in entries;
        if (e !is null)
        {
            e.lastRun = run;
            hits++;
        }
        return e;
    }

    Entry* store(ulong k)
    {
        misses++;
        if (auto e = k in entries)
        {
            e.lastRun = run;
            return e;
        }
        entries[k] = Entry.init;
        auto e = k in entries;
        e.lastRun = run;
        return e;
    }

    Brep remember(ulong k, Brep b)
    {
        auto e = store(k);
        e.brep = b;
        keys[b] = k;
        return b;
    }

    /// Runs an operation unless its result (or its failure) is known.
    Brep op(ulong k, lazy Brep compute)
    {
        if (auto e = touch(k))
        {
            if (e.error.length)
                throw new KernelException(e.error);
            if (e.brep !is null)
                return e.brep;
        }
        try
            return remember(k, compute());
        catch (KernelException ex)
        {
            store(k).error = ex.msg;
            throw ex;
        }
    }

    /// Cached result of a query on one solid.
    T query(string what, T)(Brep s, lazy T compute)
    {
        static final class Box
        {
            T value;
        }

        immutable k = key(what, s);
        if (auto e = touch(k))
            if (auto b = cast(Box) e.queryResult)
                return b.value;
        auto b = new Box;
        b.value = compute();
        store(k).queryResult = b;
        return b.value;
    }

    ulong keyOf(Brep b)
    {
        if (auto k = b in keys)
            return *k;
        // a solid the cache has not seen: give it a unique key
        return remember(fresh(), b) is b ? keys[b] : 0;
    }

    static const(double)[] flatten(const(Vec3)[] pts)
    {
        double[] r;
        foreach (p; pts)
            r ~= [p.x, p.y, p.z];
        return r;
    }

    ulong fresh() => mix(0x9E37_79B9_7F4A_7C15, ++counter + (run << 32));

    // FNV-1a over the operation name and its arguments
    ulong key(Args...)(string op, Args args)
    {
        ulong h = 0xcbf2_9ce4_8422_2325;
        void bytes(const(void)[] data)
        {
            foreach (b; cast(const(ubyte)[]) data)
            {
                h ^= b;
                h *= 0x100_0000_01b3;
            }
        }

        bytes(op);
        foreach (a; args)
        {
            alias A = typeof(a);
            static if (is(A : Brep))
            {
                immutable k = keyOf(a);
                bytes((&k)[0 .. 1]);
            }
            else static if (is(A == Vec3))
            {
                double[3] v = [a.x, a.y, a.z];
                bytes(v[]);
            }
            else static if (is(A : const(char)[]))
            {
                immutable n = a.length;
                bytes((&n)[0 .. 1]);
                bytes(a);
            }
            else static if (is(A : const(double)[]))
            {
                immutable n = a.length;
                bytes((&n)[0 .. 1]);
                bytes(a);
            }
            else static if (is(A : const(int)[]))
            {
                immutable n = a.length;
                bytes((&n)[0 .. 1]);
                bytes(a);
            }
            else static if (is(A == bool))
            {
                ubyte v = a;
                bytes((&v)[0 .. 1]);
            }
            else static if (isNumeric!A)
            {
                double d = a;
                bytes((&d)[0 .. 1]);
            }
            else
                static assert(0, "cannot hash " ~ A.stringof);
            bytes("|");
        }
        return h;
    }

    static ulong mix(ulong a, ulong b)
    {
        auto h = a ^ (b + 0x9E37_79B9_7F4A_7C15 + (a << 6) + (a >> 2));
        h ^= h >> 33;
        h *= 0xff51_afd7_ed55_8ccd;
        h ^= h >> 33;
        return h;
    }
}

unittest
{
    import hackerscad.kernel.occt.backend : OcctKernel;
    import std.exception : assertThrown;

    auto k = new CachingKernel(new OcctKernel);
    k.beginRun();
    auto a = k.translate(k.box(10, 10, 10), Vec3(1, 0, 0));
    auto b = k.cylinder(2, 20);
    auto c = k.boolean(a, b, BoolOp.cut);
    auto v = k.volume(c);
    k.endRun();

    // a second run with the same operations gets the same solids back
    k.beginRun();
    auto a2 = k.translate(k.box(10, 10, 10), Vec3(1, 0, 0));
    assert(a2 is a);
    auto c2 = k.boolean(a2, k.cylinder(2, 20), BoolOp.cut);
    assert(c2 is c && k.volume(c2) == v);
    assert(k.misses == 0 && k.hits > 0);

    // a changed parameter recomputes only what depends on it
    auto c3 = k.boolean(a2, k.cylinder(3, 20), BoolOp.cut);
    assert(c3 !is c && k.volume(c3) < v);
    k.endRun();

    // failures are remembered
    assertThrown!KernelException(k.fillet(a, [0], 100));
    assertThrown!KernelException(k.fillet(a, [0], 100));

    // entries unused for two runs are dropped
    auto before = k.size;
    k.beginRun();
    k.endRun();
    k.beginRun();
    k.endRun();
    assert(k.size < before);
}
