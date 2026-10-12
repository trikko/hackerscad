module hackerscad.geom.mesh;

import hackerscad.geom.vec;

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

        uint[long[3]] index;
        auto remap = new uint[vertexCount];
        Mesh r;
        foreach (i; 0 .. vertexCount)
        {
            float[3] p3 = verts[i * 3 .. i * 3 + 3];
            long[3] key = [lround(p3[0] / tolerance), lround(p3[1] / tolerance), lround(p3[2] / tolerance)];
            if (auto p = key in index)
                remap[i] = *p;
            else
            {
                immutable id = cast(uint) r.vertexCount;
                index[key] = id;
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

    /// True when every edge is shared by exactly two triangles with opposite
    /// winding, i.e. the mesh is a closed, consistently oriented surface.
    bool isClosed() const
    {
        int[ulong] directed;
        foreach (t; 0 .. triangleCount)
            foreach (k; 0 .. 3)
            {
                immutable ulong a = tris[t * 3 + k], b = tris[t * 3 + (k + 1) % 3];
                directed[a << 32 | b]++;
            }
        foreach (key, n; directed)
            if (n != 1 || directed.get((key & 0xffff_ffff) << 32 | key >> 32, 0) != 1)
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
