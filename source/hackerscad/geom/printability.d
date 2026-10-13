/// What a 3D printer will find hard in a mesh: overhangs (surfaces facing
/// down more steeply than the printer can bridge without supports) and thin
/// walls (material thinner than a nozzle can lay down), triangle by
/// triangle, for the checks of the language and the colours of the views.
module hackerscad.geom.printability;

import std.algorithm : max, min, sort;
import std.math : ceil, sin, sqrt;

import hackerscad.geom.vec;

/// The verdict on each triangle, and the totals.
struct PrintCheck
{
    bool[] overhang;        /// per triangle: it needs support
    float[] thin;           /// per triangle: the share of it over a wall thinner than the minimum (0 to 1)
    double overhangArea = 0, thinArea = 0;
    double thinnest = double.infinity;   /// the thinnest wall found under the minimum (infinity: none)

    /// Whether triangle `t` is mostly over a thin wall.
    bool isThin(size_t t) const => thin.length > t && thin[t] >= 0.5;
}

/// Checks the triangles `tris` of a closed mesh wound outwards, its vertex
/// positions every `stride` floats of `pos`. A triangle overhangs when it
/// faces down more than `angle` (radians) from a vertical wall and does not
/// lie on the bed (the lowest z); it is over a thin wall where a line into
/// the material from it leaves again within `wall` mm. A `wall` of 0 skips
/// the second check.
PrintCheck checkPrint(const(float)[] pos, size_t stride, const(uint)[] tris, double angle, double wall)
{
    PrintCheck r;
    immutable n = tris.length / 3;
    r.overhang = new bool[n];
    r.thin = new float[n];
    r.thin[] = 0;
    if (n == 0)
        return r;
    Vec3 at(uint v) => Vec3(pos[v * stride], pos[v * stride + 1], pos[v * stride + 2]);

    double bed = double.infinity, top = -double.infinity;
    foreach (v; tris)
    {
        bed = min(bed, at(v).z);
        top = max(top, at(v).z);
    }
    immutable flatTol = 1e-3 + 1e-6 * (top - bed), sinA = sin(angle);
    auto normals = new Vec3[n];
    auto areas = new double[n];
    foreach (t; 0 .. n)
    {
        auto a = at(tris[t * 3]), b = at(tris[t * 3 + 1]), c = at(tris[t * 3 + 2]);
        auto cr = (b - a).cross(c - a);
        immutable len = cr.length;
        areas[t] = len / 2;
        normals[t] = len > 0 ? cr / len : Vec3(0, 0, 0);
        // facing down more than the angle, and not resting on the bed
        immutable onBed = a.z < bed + flatTol && b.z < bed + flatTol && c.z < bed + flatTol;
        if (normals[t].z < -sinA - 1e-9 && !onBed)
        {
            r.overhang[t] = true;
            r.overhangArea += areas[t];
        }
    }
    if (wall <= 0)
        return r;

    auto bvh = Bvh(pos, stride, tris);
    foreach (t; 0 .. n)
    {
        if (areas[t] <= 0)
            continue;
        auto a = at(tris[t * 3]), b = at(tris[t * 3 + 1]), c = at(tris[t * 3 + 2]);
        // points spread over the triangle, more on large ones (at most 15)
        immutable longest = max((b - a).length, (c - b).length, (a - c).length);
        immutable k = cast(int) min(4.0, max(1.0, ceil(longest / (2 * wall))));
        int samples, hits;
        immutable d = -normals[t];
        foreach (i; 0 .. k)
            foreach (j; 0 .. k - i)
            {
                // the centres of the k² sub-triangles' upright half
                immutable u = (i + 1.0 / 3) / k, v = (j + 1.0 / 3) / k;
                auto p = a + (b - a) * u + (c - a) * v;
                samples++;
                immutable dist = bvh.exit(p, d, wall, cast(uint) t);
                if (dist < wall)
                {
                    hits++;
                    r.thinnest = min(r.thinnest, dist);
                }
            }
        r.thin[t] = cast(float) hits / samples;
        r.thinArea += areas[t] * hits / samples;
    }
    return r;
}

/// A bounding-volume hierarchy over a mesh's triangles, for rays.
struct Bvh
{
    private
    {
        struct Node
        {
            float[3] lo, hi;
            uint first, count;   // a leaf's triangles in `order`; count 0: children at first and first + 1
        }
        Node[] nodes;
        uint[] order;
        const(float)[] pos;
        size_t stride;
        const(uint)[] tris;
    }

    this(const(float)[] pos, size_t stride, const(uint)[] tris)
    {
        this.pos = pos;
        this.stride = stride;
        this.tris = tris;
        immutable n = tris.length / 3;
        order = new uint[n];
        auto centre = new float[3][n];
        foreach (t; 0 .. n)
        {
            order[t] = cast(uint) t;
            foreach (ax; 0 .. 3)
                centre[t][ax] = (vtx(tris[t * 3])[ax] + vtx(tris[t * 3 + 1])[ax] + vtx(tris[t * 3 + 2])[ax]) / 3;
        }
        nodes.reserve(2 * n);
        nodes ~= Node.init;
        build(0, 0, cast(uint) n, centre);
    }

    private float[3] vtx(uint v) const => [pos[v * stride], pos[v * stride + 1], pos[v * stride + 2]];

    private void build(size_t node, uint first, uint count, const(float[3])[] centre)
    {
        float[3] lo = float.infinity, hi = -float.infinity, clo = float.infinity, chi = -float.infinity;
        foreach (t; order[first .. first + count])
        {
            foreach (k; 0 .. 3)
            {
                auto p = vtx(tris[t * 3 + k]);
                foreach (ax; 0 .. 3)
                {
                    lo[ax] = min(lo[ax], p[ax]);
                    hi[ax] = max(hi[ax], p[ax]);
                }
            }
            foreach (ax; 0 .. 3)
            {
                clo[ax] = min(clo[ax], centre[t][ax]);
                chi[ax] = max(chi[ax], centre[t][ax]);
            }
        }
        nodes[node].lo = lo;
        nodes[node].hi = hi;
        if (count <= 4)
        {
            nodes[node].first = first;
            nodes[node].count = count;
            return;
        }
        // split at the median along the widest spread of the centres
        size_t axis;
        foreach (ax; 1 .. 3)
            if (chi[ax] - clo[ax] > chi[axis] - clo[axis])
                axis = ax;
        sort!((x, y) => centre[x][axis] < centre[y][axis])(order[first .. first + count]);
        immutable half = count / 2;
        immutable left = cast(uint) nodes.length;
        nodes ~= Node.init;
        nodes ~= Node.init;
        nodes[node].first = left;
        nodes[node].count = 0;
        build(left, first, half, centre);
        build(left + 1, first + half, count - half, centre);
    }

    /// How far the ray from `o` along the unit `d` goes before it leaves
    /// the material through a triangle facing along it (other than `skip`),
    /// looking no farther than `limit`; infinity when it does not.
    double exit(Vec3 o, Vec3 d, double limit, uint skip) const
    {
        if (nodes.length == 0)
            return double.infinity;
        double best = limit;
        bool found;
        uint[64] stack;
        size_t sp;
        stack[sp++] = 0;
        while (sp)
        {
            const node = &nodes[stack[--sp]];
            if (!hitsBox(o, d, node.lo, node.hi, best))
                continue;
            if (node.count == 0)
            {
                if (sp + 2 > stack.length)
                    continue;   // deeper than any balanced tree of 2^60 triangles
                stack[sp++] = node.first;
                stack[sp++] = node.first + 1;
                continue;
            }
            foreach (t; order[node.first .. node.first + node.count])
            {
                if (t == skip)
                    continue;
                auto a = vec(tris[t * 3]), b = vec(tris[t * 3 + 1]), c = vec(tris[t * 3 + 2]);
                // only the surface where the ray goes out of the material
                if ((b - a).cross(c - a).dot(d) <= 0)
                    continue;
                immutable s = intersect(o, d, a, b, c);
                if (s > 1e-6 && s < best)
                {
                    best = s;
                    found = true;
                }
            }
        }
        return found ? best : double.infinity;
    }

    private Vec3 vec(uint v) const => Vec3(pos[v * stride], pos[v * stride + 1], pos[v * stride + 2]);

    private static bool hitsBox(Vec3 o, Vec3 d, const float[3] lo, const float[3] hi, double tmax)
    {
        double t0 = 0, t1 = tmax;
        foreach (ax; 0 .. 3)
        {
            immutable oa = ax == 0 ? o.x : ax == 1 ? o.y : o.z, da = ax == 0 ? d.x : ax == 1 ? d.y : d.z;
            if (da == 0)
            {
                if (oa < lo[ax] - 1e-6 || oa > hi[ax] + 1e-6)
                    return false;
                continue;
            }
            double ta = (lo[ax] - oa) / da, tb = (hi[ax] - oa) / da;
            if (ta > tb)
            {
                immutable s = ta;
                ta = tb;
                tb = s;
            }
            t0 = max(t0, ta - 1e-6);
            t1 = min(t1, tb + 1e-6);
            if (t0 > t1)
                return false;
        }
        return true;
    }

    /// Möller–Trumbore: the distance along the ray to the triangle, or -1.
    private static double intersect(Vec3 o, Vec3 d, Vec3 a, Vec3 b, Vec3 c)
    {
        auto e1 = b - a, e2 = c - a;
        auto p = d.cross(e2);
        immutable det = e1.dot(p);
        if (det > -1e-12 && det < 1e-12)
            return -1;
        immutable inv = 1 / det;
        auto s = o - a;
        immutable u = s.dot(p) * inv;
        if (u < -1e-9 || u > 1 + 1e-9)
            return -1;
        auto q = s.cross(e1);
        immutable v = d.dot(q) * inv;
        if (v < -1e-9 || u + v > 1 + 1e-9)
            return -1;
        return e2.dot(q) * inv;
    }
}

unittest
{
    import std.math : abs, PI;

    // a box x0..x1 × y0..y1 × z0..z1 as 12 triangles wound outwards
    void box(ref float[] pos, ref uint[] tris, double[3] lo, double[3] hi)
    {
        immutable base = cast(uint)(pos.length / 3);
        foreach (i; 0 .. 8)
            pos ~= [cast(float)(i & 1 ? hi[0] : lo[0]), cast(float)(i & 2 ? hi[1] : lo[1]), cast(float)(i & 4 ? hi[2] : lo[2])];
        immutable uint[] faces = [0, 2, 3, 0, 3, 1,  4, 5, 7, 4, 7, 6,  0, 1, 5, 0, 5, 4,
            2, 6, 7, 2, 7, 3,  0, 4, 6, 0, 6, 2,  1, 3, 7, 1, 7, 5];
        foreach (f; faces)
            tris ~= base + f;
    }
    // a T: a post 10 × 10 × 10 on the bed under a slab 30 × 10 × 0.5, whose
    // underside sticks out 10 mm on each side
    float[] pos;
    uint[] tris;
    box(pos, tris, [10, 0, 0], [20, 10, 10]);
    box(pos, tris, [0, 0, 10], [30, 10, 10.5]);
    auto r = checkPrint(pos, 3, tris, PI / 4, 0.8);
    // the slab's underside (300 mm², the post's top under it is inside but
    // counted, as the two boxes are not fused) and the post's bottom (on the bed, not counted)
    assert(abs(r.overhangArea - 300) < 1e-6, "overhang");
    // the slab is 0.5 thick: its top and bottom (600 mm²) and the post's
    // top meet a wall 0.5 away
    assert(r.thinArea >= 600 - 1e-6 && abs(r.thinnest - 0.5) < 1e-5, "thin");
    // a thick wall: nothing thin
    float[] p2;
    uint[] t2;
    box(p2, t2, [0, 0, 0], [10, 10, 10]);
    auto r2 = checkPrint(p2, 3, t2, PI / 4, 0.8);
    assert(r2.thinArea == 0 && r2.overhangArea == 0);
}
