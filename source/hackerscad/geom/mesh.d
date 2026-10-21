module hackerscad.geom.mesh;

import hackerscad.geom.vec;
import std.algorithm.mutation : swap;

private long[3] to3(long[] a) => [a[0], a[1], a[2]];

/// Indexed triangle mesh, the common currency between kernels, exporters and
/// the viewport.
struct Mesh
{
    float[] verts;     /// x y z per vertex
    uint[] tris;       /// three vertex indices per triangle
    uint[] faceStart;  /// optional: B-rep face i owns triangles faceStart[i] .. faceStart[i + 1]

    /// B-rep face that owns triangle `t`, or -1 when unknown.
    int faceOf(size_t t) const
    {
        import std.range : assumeSorted;
        if (faceStart.length < 2 || t >= faceStart[$ - 1])
            return -1;
        auto upto = faceStart.assumeSorted.lowerBound(cast(uint) t + 1);
        return cast(int) upto.length - 1;
    }

    size_t vertexCount() const => verts.length / 3;
    size_t triangleCount() const => tris.length / 3;

    Vec3 vertex(size_t i) const => Vec3(verts[i * 3], verts[i * 3 + 1], verts[i * 3 + 2]);

    /// Merges vertices closer than `tolerance` (mm). Kernels emit one vertex
    /// set per face, and points on seams differ by rounding errors; exporters
    /// want a single connected surface.
    Mesh welded(double tolerance = 1e-4) const
    {
        import std.math : lround;

        // a grid of cells `tolerance` wide: two points a hair apart may fall in
        // cells side by side, so the cells round a point are searched too
        uint[][long[3]] cells;
        auto remap = new uint[vertexCount];
        Mesh r;
        foreach (i; 0 .. vertexCount)
        {
            float[3] p3 = verts[i * 3 .. i * 3 + 3];
            long[3] key = [lround(p3[0] / tolerance), lround(p3[1] / tolerance), lround(p3[2] / tolerance)];
            long found = -1;
            if (auto p = key in cells)
                found = (*p)[0];
            else
                foreach (dx; -1 .. 2)
                    foreach (dy; -1 .. 2)
                        foreach (dz; -1 .. 2)
                            if (found < 0)
                                if (auto p = [key[0] + dx, key[1] + dy, key[2] + dz].to3 in cells)
                                    foreach (id; *p)
                                        if (found < 0 && (r.vertex(id) - Vec3(p3[0], p3[1], p3[2])).length <= tolerance)
                                            found = id;
            if (found >= 0)
                remap[i] = cast(uint) found;
            else
            {
                immutable id = cast(uint) r.vertexCount;
                cells[key] ~= id;
                r.verts ~= p3[];
                remap[i] = id;
            }
        }
        r.tris.reserve(tris.length);
        // the faces keep their triangles, less the ones that collapse
        size_t face;
        immutable faced = faceStart.length >= 2;
        foreach (t; 0 .. triangleCount)
        {
            while (faced && face < faceStart.length && faceStart[face] <= t)
            {
                r.faceStart ~= cast(uint) r.triangleCount;
                face++;
            }
            immutable a = remap[tris[t * 3]], b = remap[tris[t * 3 + 1]], c = remap[tris[t * 3 + 2]];
            if (a != b && b != c && a != c)
                r.tris ~= [a, b, c];
        }
        while (faced && face < faceStart.length)
        {
            r.faceStart ~= cast(uint) r.triangleCount;
            face++;
        }
        return r;
    }

    /// A welded mesh mended where a scan or an export left it not quite a
    /// solid: triangles doubled facing each other (a wall of no thickness)
    /// taken out, the same triangle twice kept once, and where the surface
    /// touches itself, along an edge of more than two triangles or at a
    /// vertex, the sheets parted: the triangles around the edge paired
    /// across the material, a vertex given one copy per fan of triangles
    /// round it. Holes stay holes.
    Mesh repaired() const
    {
        import std.algorithm : sort, canFind;
        import std.math : atan2, abs;

        // 1. the doubled: per set of three vertices, the windings left once each pair facing away is gone
        int[uint[3]] net;   // the windings one way less the other
        uint[3][] order;
        foreach (t; 0 .. triangleCount)
        {
            uint[3] v = [tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2]];
            if (v[0] == v[1] || v[1] == v[2] || v[0] == v[2])
                continue;
            uint[3] key = v;
            key[].sort;
            // the same turn as the sorted three, or the other
            immutable i = v[0] == key[0] ? 0 : v[1] == key[0] ? 1 : 2;
            immutable sign = v[(i + 1) % 3] == key[1] ? 1 : -1;
            if (auto k = key in net)
                *k += sign;
            else
            {
                net[key] = sign;
                order ~= key;
            }
        }
        uint[] tr;
        foreach (key; order)
        {
            immutable k = net[key];
            if (k == 0)
                continue;
            tr ~= k > 0 ? [key[0], key[1], key[2]] : [key[0], key[2], key[1]];
        }
        immutable n = tr.length / 3;

        // 2. each edge's triangles; where more than two meet, the ways to pair them by their angle round it
        auto edgeKey = (uint a, uint b) => a < b ? cast(ulong) a << 32 | b : cast(ulong) b << 32 | a;
        uint[][ulong] around;
        foreach (t; 0 .. n)
            foreach (k; 0 .. 3)
                around[edgeKey(tr[t * 3 + k], tr[t * 3 + (k + 1) % 3])] ~= cast(uint) t;
        Vec3 at(uint v) => vertex(v);
        struct Fork
        {
            uint a, b;
            uint[][] options;   /// each: the triangles in pairs, the likeliest first
            size_t choice;
        }
        Fork[] forks;
        foreach (key, ts; around)
        {
            immutable a = cast(uint)(key >> 32), b = cast(uint)(key & 0xffff_ffff);
            if (ts.length <= 2 || ts.length % 2)
                continue;   // an odd count: a hole there too, left
            // the edge's direction, and two axes square to it
            auto d = (at(b) - at(a)).normalized;
            auto e1 = (abs(d.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)).cross(d).normalized;
            auto e2 = d.cross(e1);
            struct Sheet { uint t; double angle; bool forward, towardsNext; }
            Sheet[] sh;
            foreach (t; ts)
            {
                uint c;
                bool forward;
                foreach (k; 0 .. 3)
                {
                    immutable p = tr[t * 3 + k], q = tr[t * 3 + (k + 1) % 3];
                    if (p == a && q == b)
                        forward = true;
                    if (p != a && p != b)
                        c = p;
                }
                auto u = at(c) - at(a);
                u = u - d * u.dot(d);
                // the triangle's outward normal; the material behind it, towards the next sheet or the one before
                auto nrm = (at(b) - at(a)).cross(at(c) - at(a)) * (forward ? 1 : -1);
                sh ~= Sheet(t, atan2(u.dot(e2), u.dot(e1)), forward, d.cross(u).dot(nrm) < 0);
            }
            sh.sort!((x, y) => x.angle < y.angle);
            // neighbours paired starting at the first sheet or the second: turned opposite ways, so it
            // closes, and better with the material between them (not, where the sheets cross a little)
            Fork f = Fork(a, b);
            foreach (material; [true, false])
                foreach (start; 0 .. 2)
                {
                    uint[] pairs;
                    bool ok = true;
                    for (size_t i = start; i < sh.length + start; i += 2)
                    {
                        auto p = sh[i % sh.length], q = sh[(i + 1) % sh.length];
                        ok = ok && p.forward != q.forward && (!material || (p.towardsNext && !q.towardsNext));
                        pairs ~= [p.t, q.t];
                    }
                    if (ok && !f.options.canFind(pairs))
                        f.options ~= pairs;
                }
            if (f.options.length)
                forks ~= f;
        }

        // 3. corners (triangle * 3 + slot) joined across the edges paired, a vertex once per group of
        // them: a copy for each fan after the first. Where an edge still has more than two triangles
        // (the sheets one fan round both its ends), its other pairing tried, a few rounds
        auto parent = new uint[n * 3];
        uint find(uint x)
        {
            while (parent[x] != x)
                x = parent[x] = parent[parent[x]];
            return x;
        }
        uint slot(size_t t, uint v) => cast(uint)(t * 3 + (tr[t * 3] == v ? 0 : tr[t * 3 + 1] == v ? 1 : 2));
        void join(uint t1, uint t2, uint a, uint b)
        {
            parent[find(slot(t1, a))] = find(slot(t2, a));
            parent[find(slot(t1, b))] = find(slot(t2, b));
        }
        Mesh r;
        foreach (round; 0 .. 6)
        {
            foreach (i; 0 .. parent.length)
                parent[i] = cast(uint) i;
            foreach (key, ts; around)
                if (ts.length == 2)
                    join(ts[0], ts[1], cast(uint)(key >> 32), cast(uint)(key & 0xffff_ffff));
            foreach (ref f; forks)
            {
                auto pairs = f.options[f.choice];
                for (size_t i = 0; i + 1 < pairs.length; i += 2)
                    join(pairs[i], pairs[i + 1], f.a, f.b);
            }
            r.verts = verts.dup;
            r.tris = tr.dup;
            uint[uint] copyOf;   // a group's root -> its vertex
            auto taken = new bool[vertexCount];
            foreach (c; 0 .. cast(uint)(n * 3))
            {
                immutable root = find(c), v = tr[c];
                if (auto p = root in copyOf)
                {
                    r.tris[c] = *p;
                    continue;
                }
                uint id = v;
                if (taken[v])
                {
                    id = cast(uint) r.vertexCount;
                    r.verts ~= verts[v * 3 .. v * 3 + 3];
                }
                taken[v] = true;
                copyOf[root] = id;
                r.tris[c] = id;
            }
            // the forks still shared by more than two triangles: the next way
            uint[ulong] uses;
            foreach (t; 0 .. n)
                foreach (k; 0 .. 3)
                    uses[edgeKey(r.tris[t * 3 + k], r.tris[t * 3 + (k + 1) % 3])]++;
            bool changed;
            foreach (ref f; forks)
            {
                immutable t = f.options[f.choice][0];
                // the fork's edge as the first of its triangles now has it
                immutable a = r.tris[slot(t, f.a)], b = r.tris[slot(t, f.b)];
                if (uses.get(edgeKey(a, b), 0) > 2 && f.options.length > 1)
                {
                    f.choice = (f.choice + 1) % f.options.length;
                    changed = true;
                }
            }
            if (!changed)
                break;
        }
        return r;
    }

    /// True when every edge is shared by exactly two triangles with opposite
    /// winding, i.e. the mesh is a closed, consistently oriented surface.
    bool isClosed() const
    {
        // every directed edge once, and its reverse once: sorted, then looked up
        import std.range : assumeSorted;
        auto keys = new ulong[tris.length];
        foreach (t; 0 .. triangleCount)
            foreach (k; 0 .. 3)
                keys[t * 3 + k] = cast(ulong) tris[t * 3 + k] << 32 | tris[t * 3 + (k + 1) % 3];
        sortKeys(keys);
        auto sorted = keys.assumeSorted;
        foreach (i, key; keys)
            if ((i + 1 < keys.length && keys[i + 1] == key) || !sorted.contains((key & 0xffff_ffff) << 32 | key >> 32))
                return false;
        return true;
    }

    /// Signed volume by the divergence theorem; positive for outward winding.
    double volume() const
    {
        double v = 0;
        foreach (t; 0 .. triangleCount)
        {
            auto a = vertex(tris[t * 3]), b = vertex(tris[t * 3 + 1]), c = vertex(tris[t * 3 + 2]);
            v += a.dot(b.cross(c));
        }
        return v / 6;
    }
}

unittest
{
    // the same point a hair apart across a cell's border of the welding grid (0.00015 rounds up,
    // 0.0001499 down): welded all the same
    Mesh m;
    m.verts = [0.00015f, 0, 0, 0, 1, 0, 1, 0, 0, 0.0001499f, 0, 0, 0, 1, 0, 0, -1, 0];
    m.tris = [0, 1, 2, 3, 5, 4];
    assert(m.welded.vertexCount == 4, "a point split by the grid");
}

unittest
{
    import std.math : isClose;

    // two cubes meeting along an edge, one with a wall of no thickness inside
    Mesh cube(double x0, double y0)
    {
        Mesh m;
        foreach (k; 0 .. 8)
            m.verts ~= [cast(float)(x0 + (k & 1)), cast(float)(y0 + (k >> 1 & 1)), cast(float)(k >> 2)];
        m.tris = [0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5];
        return m;
    }
    auto a = cube(0, 0), b = cube(1, 1);
    Mesh two;
    two.verts = a.verts ~ b.verts;
    two.tris = a.tris.dup;
    foreach (t; b.tris)
        two.tris ~= t + 8;
    two.tris ~= [0, 3, 5, 0, 5, 3];   // the wall, both ways
    auto w = two.welded;
    assert(!w.isClosed);
    auto r = w.repaired;
    assert(r.isClosed && r.triangleCount == 24 && isClose(r.volume, 2));
    // a sound mesh comes back as it was
    auto c = cube(0, 0).welded;
    assert(c.repaired.verts == c.verts && c.repaired.triangleCount == 12 && isClose(c.repaired.volume, 1));
}

unittest
{
    // a tetrahedron given as four faces with separate vertices
    float[] p = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1];
    uint[][] faces = [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]];
    Mesh m;
    foreach (f; faces)
    {
        immutable base = cast(uint) m.vertexCount;
        foreach (i; f)
            m.verts ~= p[i * 3 .. i * 3 + 3];
        m.tris ~= [base, base + 1, base + 2];
    }
    assert(!m.isClosed);
    auto w = m.welded;
    assert(w.vertexCount == 4);
    assert(w.isClosed);
    import std.math : isClose;
    assert(isClose(w.volume, 1.0 / 6));
}

/// Sorts `keys` (and `vals` along, when given) by radix: four passes of 16
/// bits, linear in the length. Meshes have millions of edges to group, and
/// a sort beats a map of them by an order of magnitude.
void sortKeys(ref ulong[] keys, ref uint[] vals)
{
    auto k2 = new ulong[keys.length], v2 = new uint[vals.length];
    auto count = new size_t[65537];
    foreach (pass; 0 .. 4)
    {
        immutable shift = pass * 16;
        count[] = 0;
        foreach (k; keys)
            count[((k >> shift) & 0xffff) + 1]++;
        foreach (i; 1 .. count.length)
            count[i] += count[i - 1];
        foreach (i, k; keys)
        {
            immutable d = count[(k >> shift) & 0xffff]++;
            k2[d] = k;
            if (vals.length)
                v2[d] = vals[i];
        }
        swap(keys, k2);
        swap(vals, v2);
    }
}

/// ditto
void sortKeys(ref ulong[] keys)
{
    uint[] none;
    sortKeys(keys, none);
}

unittest
{
    ulong[] keys = [5, 1UL << 40, 3, 0, 1UL << 40 | 2, 7UL << 60];
    uint[] vals = [0, 1, 2, 3, 4, 5];
    sortKeys(keys, vals);
    assert(keys == [0, 3, 5, 1UL << 40, 1UL << 40 | 2, 7UL << 60]);
    assert(vals == [3, 2, 0, 1, 4, 5]);
}
