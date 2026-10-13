/// How far apart two surfaces are: points spread over one, each one's
/// distance to the nearest point of the other (a tree of boxes keeps it
/// quick), for checking a remodelled part against the mesh it copies.
module hackerscad.geom.deviation;

import std.algorithm : max, min, sort;
import std.math : ceil, sqrt;

import hackerscad.geom.mesh;
import hackerscad.geom.vec;

/// The distances from `a`'s surface to `b`'s.
struct Deviation
{
    double max = 0, mean = 0, rms = 0;
    Vec3 worstAt;          /// where on a it is largest
    double[] samples;      /// every point's distance

    /// The share of the points within `tol`.
    double within(double tol) const
    {
        if (samples.length == 0)
            return 1;
        size_t ok;
        foreach (d; samples)
            ok += d <= tol;
        return cast(double) ok / samples.length;
    }
}

/// From a to b: points every `spacing` mm or so on each triangle of a (its
/// corners, the middle, and a grid on large ones).
Deviation deviation(const Mesh a, const Mesh b, double spacing)
{
    Deviation r;
    if (a.triangleCount == 0 || b.triangleCount == 0)
        return r;
    auto tree = Nearest(b);
    double sum = 0, sum2 = 0;
    size_t count;
    foreach (t; 0 .. a.triangleCount)
    {
        auto p0 = a.vertex(a.tris[3 * t]), p1 = a.vertex(a.tris[3 * t + 1]), p2 = a.vertex(a.tris[3 * t + 2]);
        immutable longest = max((p1 - p0).length, (p2 - p1).length, (p0 - p2).length);
        immutable k = cast(int) min(6.0, max(1.0, ceil(longest / spacing)));
        foreach (i; 0 .. k + 1)
            foreach (j; 0 .. k + 1 - i)
            {
                auto p = p0 + (p1 - p0) * (cast(double) i / k) + (p2 - p0) * (cast(double) j / k);
                immutable d = tree.distance(p);
                r.samples ~= d;
                sum += d;
                sum2 += d * d;
                count++;
                if (d > r.max)
                {
                    r.max = d;
                    r.worstAt = p;
                }
            }
    }
    r.mean = sum / count;
    r.rms = sqrt(sum2 / count);
    return r;
}

/// `a` cut into triangles about `spacing` across (at most 8 × 8 of a
/// triangle) and each one's colour by its distance from `b`: a map of the
/// deviation to draw.
Mesh deviationMap(const Mesh a, const Mesh b, double spacing, double tol, out uint[] colors)
{
    Mesh r;
    auto tree = Nearest(b);
    foreach (t; 0 .. a.triangleCount)
    {
        auto p0 = a.vertex(a.tris[3 * t]), p1 = a.vertex(a.tris[3 * t + 1]), p2 = a.vertex(a.tris[3 * t + 2]);
        immutable longest = max((p1 - p0).length, (p2 - p1).length, (p0 - p2).length);
        immutable k = cast(int) min(8.0, max(1.0, ceil(longest / spacing)));
        Vec3 at(int i, int j) => p0 + (p1 - p0) * (cast(double) i / k) + (p2 - p0) * (cast(double) j / k);
        void tri(Vec3 x, Vec3 y, Vec3 z)
        {
            immutable base = cast(uint) r.vertexCount;
            foreach (p; [x, y, z])
                r.verts ~= [cast(float) p.x, cast(float) p.y, cast(float) p.z];
            r.tris ~= [base, base + 1, base + 2];
            colors ~= heat(tree.distance((x + y + z) / 3), tol);
        }
        foreach (i; 0 .. k)
            foreach (j; 0 .. k - i)
            {
                tri(at(i, j), at(i + 1, j), at(i, j + 1));
                if (i + j + 1 < k)
                    tri(at(i + 1, j), at(i + 1, j + 1), at(i, j + 1));
            }
    }
    return r;
}

/// Nearest-point queries on a mesh's triangles.
struct Nearest
{
    private
    {
        struct Node
        {
            Vec3 lo, hi;
            uint first, count;   // a leaf's triangles in order; count 0: children at first, first + 1
        }
        Node[] nodes;
        uint[] order;
        Mesh m;
    }

    this(const Mesh mesh)
    {
        m = Mesh(mesh.verts.dup, mesh.tris.dup);
        immutable n = m.triangleCount;
        order = new uint[n];
        auto centre = new Vec3[n];
        foreach (t; 0 .. n)
        {
            order[t] = cast(uint) t;
            centre[t] = (m.vertex(m.tris[3 * t]) + m.vertex(m.tris[3 * t + 1]) + m.vertex(m.tris[3 * t + 2])) / 3;
        }
        nodes ~= Node.init;
        build(0, 0, cast(uint) n, centre);
    }

    private void build(size_t node, uint first, uint count, const Vec3[] centre)
    {
        Vec3 lo = Vec3(double.infinity, double.infinity, double.infinity), hi = -lo;
        Vec3 clo = lo, chi = hi;
        foreach (t; order[first .. first + count])
        {
            foreach (k; 0 .. 3)
            {
                auto p = m.vertex(m.tris[3 * t + k]);
                lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z));
                hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z));
            }
            auto c = centre[t];
            clo = Vec3(min(clo.x, c.x), min(clo.y, c.y), min(clo.z, c.z));
            chi = Vec3(max(chi.x, c.x), max(chi.y, c.y), max(chi.z, c.z));
        }
        nodes[node].lo = lo;
        nodes[node].hi = hi;
        if (count <= 4)
        {
            nodes[node].first = first;
            nodes[node].count = count;
            return;
        }
        auto ext = chi - clo;
        immutable axis = ext.x >= ext.y && ext.x >= ext.z ? 0 : ext.y >= ext.z ? 1 : 2;
        double key(uint t) => axis == 0 ? centre[t].x : axis == 1 ? centre[t].y : centre[t].z;
        order[first .. first + count].sort!((p, q) => key(p) < key(q));
        immutable half = count / 2, left = cast(uint) nodes.length;
        nodes ~= Node.init;
        nodes ~= Node.init;
        nodes[node].first = left;
        nodes[node].count = 0;
        build(left, first, half, centre);
        build(left + 1, first + half, count - half, centre);
    }

    /// The distance from p to the nearest point of the mesh.
    double distance(Vec3 p) const
    {
        double best = double.infinity;
        uint[64] stack;
        size_t sp;
        stack[sp++] = 0;
        while (sp)
        {
            const node = &nodes[stack[--sp]];
            if (boxDistance2(p, node.lo, node.hi) >= best * best)
                continue;
            if (node.count == 0)
            {
                if (sp + 2 > stack.length)
                    continue;
                // the nearer child last, so that it is searched first
                immutable a = node.first, b = node.first + 1;
                immutable da = boxDistance2(p, nodes[a].lo, nodes[a].hi), db = boxDistance2(p, nodes[b].lo, nodes[b].hi);
                stack[sp++] = da < db ? b : a;
                stack[sp++] = da < db ? a : b;
                continue;
            }
            foreach (t; order[node.first .. node.first + node.count])
                best = min(best, pointTriangle(p, m.vertex(m.tris[3 * t]), m.vertex(m.tris[3 * t + 1]),
                    m.vertex(m.tris[3 * t + 2])));
        }
        return best;
    }

    private static double boxDistance2(Vec3 p, Vec3 lo, Vec3 hi)
    {
        immutable dx = p.x < lo.x ? lo.x - p.x : p.x > hi.x ? p.x - hi.x : 0;
        immutable dy = p.y < lo.y ? lo.y - p.y : p.y > hi.y ? p.y - hi.y : 0;
        immutable dz = p.z < lo.z ? lo.z - p.z : p.z > hi.z ? p.z - hi.z : 0;
        return dx * dx + dy * dy + dz * dz;
    }
}

/// The distance from p to the triangle abc (the nearest point by regions,
/// as in Ericson's Real-Time Collision Detection).
double pointTriangle(Vec3 p, Vec3 a, Vec3 b, Vec3 c)
{
    auto ab = b - a, ac = c - a, ap = p - a;
    immutable d1 = ab.dot(ap), d2 = ac.dot(ap);
    if (d1 <= 0 && d2 <= 0)
        return ap.length;
    auto bp = p - b;
    immutable d3 = ab.dot(bp), d4 = ac.dot(bp);
    if (d3 >= 0 && d4 <= d3)
        return bp.length;
    immutable vc = d1 * d4 - d3 * d2;
    if (vc <= 0 && d1 >= 0 && d3 <= 0)
        return (p - (a + ab * (d1 / (d1 - d3)))).length;
    auto cp = p - c;
    immutable d5 = ab.dot(cp), d6 = ac.dot(cp);
    if (d6 >= 0 && d5 <= d6)
        return cp.length;
    immutable vb = d5 * d2 - d1 * d6;
    if (vb <= 0 && d2 >= 0 && d6 <= 0)
        return (p - (a + ac * (d2 / (d2 - d6)))).length;
    immutable va = d3 * d6 - d5 * d4;
    if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0)
        return (p - (b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))))).length;
    immutable denom = 1 / (va + vb + vc);
    return (p - (a + ab * (vb * denom) + ac * (vc * denom))).length;
}

/// A colour for a deviation: green within `tol`/2, through yellow at `tol`,
/// to red at twice it.
uint heat(double d, double tol)
{
    import std.math : round;
    immutable f = min(1.0, max(0.0, (d - tol / 2) / (1.5 * tol)));
    // green (60, 170, 90) → yellow (235, 200, 60) → red (220, 50, 40)
    double r, g, b;
    if (f < 0.5)
    {
        immutable s = f * 2;
        r = 60 + s * (235 - 60);
        g = 170 + s * (200 - 170);
        b = 90 + s * (60 - 90);
    }
    else
    {
        immutable s = (f - 0.5) * 2;
        r = 235 + s * (220 - 235);
        g = 200 + s * (50 - 200);
        b = 60 + s * (40 - 60);
    }
    return cast(uint) round(r) << 16 | cast(uint) round(g) << 8 | cast(uint) round(b);
}

unittest
{
    import std.math : abs;
    // two squares 1 mm apart: every point 1 mm off
    Mesh a, b;
    a.verts = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0];
    a.tris = [0, 1, 2, 0, 2, 3];
    b.verts = [0, 0, 1, 10, 0, 1, 10, 10, 1, 0, 10, 1];
    b.tris = [0, 1, 2, 0, 2, 3];
    auto d = deviation(a, b, 1);
    assert(abs(d.max - 1) < 1e-6 && abs(d.mean - 1) < 1e-6 && d.within(0.5) == 0 && d.within(1.5) == 1);
    // the nearest point off a corner, an edge, the face
    assert(abs(pointTriangle(Vec3(-1, -1, 0), Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)) - sqrt(2.0)) < 1e-12);
    assert(abs(pointTriangle(Vec3(0.5, -2, 0), Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)) - 2) < 1e-12);
    assert(abs(pointTriangle(Vec3(0.2, 0.2, 3), Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)) - 3) < 1e-12);
}
