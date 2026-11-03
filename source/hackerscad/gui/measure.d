/// Measurements between items of the 3D view (faces, edges, points), from
/// their triangles and polylines: what the context menu shows when two items
/// are selected, and what hcad_gui_measure answers.
module hackerscad.gui.measure;

import std.math : abs, acos, sqrt, PI;
import std.algorithm : min, max;

import hackerscad.geom.vec;
import hackerscad.gui.evaluator : PartMesh;
import hackerscad.gui.viewport : edgePolyline;

/// The geometry of an item: a face's triangles, an edge's segments, a point.
struct Item
{
    Vec3[3][] triangles;
    Vec3[2][] segments;
    Vec3[] points;          /// corners: the closest points are searched from them
    Vec3 normal;            /// planar faces
    Vec3 direction;         /// straight edges
    bool planar, straight;
}

Item faceItem(PartMesh p, int face)
{
    Item it;
    if (face < 0 || face + 1 >= p.faceStart.length)
        return it;
    Vec3 vtx(uint i) => Vec3(p.vertices[i * 6], p.vertices[i * 6 + 1], p.vertices[i * 6 + 2]);
    foreach (t; p.faceStart[face] .. p.faceStart[face + 1])
    {
        Vec3[3] tri = [vtx(p.indices[t * 3]), vtx(p.indices[t * 3 + 1]), vtx(p.indices[t * 3 + 2])];
        it.triangles ~= tri;
        it.points ~= tri[];
    }
    if (it.triangles.length)
    {
        // planar when every corner lies on the plane of the largest triangle
        Vec3 n;
        double best = 0;
        foreach (tri; it.triangles)
        {
            auto c = (tri[1] - tri[0]).cross(tri[2] - tri[0]);
            if (c.length > best)
            {
                best = c.length;
                n = c;
            }
        }
        if (best > 0)
        {
            it.normal = n.normalized;
            immutable d = it.normal.dot(it.triangles[0][0]);
            it.planar = true;
            foreach (q; it.points)
                if (abs(it.normal.dot(q) - d) > 1e-4)
                    it.planar = false;
        }
    }
    return it;
}

Item edgeItem(PartMesh p, int edge)
{
    Item it;
    if (edge < 0 || edge >= p.edgeInfo.length)
        return it;
    auto pts = edgePolyline(p.edgeInfo[edge]);
    foreach (k; 0 .. pts.length - 1)
        it.segments ~= [pts[k], pts[k + 1]];
    it.points = pts;
    import hackerscad.kernel.brep : EdgeKind;
    if (p.edgeInfo[edge].kind == EdgeKind.line)
    {
        it.straight = true;
        it.direction = p.edgeInfo[edge].direction;
    }
    return it;
}

Item pointItem(Vec3 v)
{
    Item it;
    it.points = [v];
    return it;
}

/// Minimum distance between two items, with the closest points.
struct Distance
{
    double distance = double.infinity;
    Vec3 onA, onB;
    double angle = double.nan;      /// degrees (0 to 90) between the planes or lines, when both have one
    double gap = double.nan;        /// parallel planar faces: distance between their planes
}

Distance measure(Item a, Item b)
{
    Distance r;
    void from(ref const Item src, ref const Item dst, bool swapped)
    {
        const near = Near(dst);
        foreach (q; src.points)
        {
            Vec3 c;
            immutable d = closest(dst, near, q, c);
            if (d < r.distance)
            {
                r.distance = d;
                r.onA = swapped ? c : q;
                r.onB = swapped ? q : c;
            }
        }
    }
    from(a, b, false);
    from(b, a, true);
    // the two lines of an edge pair can be closest in their middles
    foreach (sa; a.segments)
        foreach (sb; b.segments)
        {
            Vec3 ca, cb;
            segmentSegment(sa[0], sa[1], sb[0], sb[1], ca, cb);
            immutable d = (ca - cb).length;
            if (d < r.distance)
            {
                r.distance = d;
                r.onA = ca;
                r.onB = cb;
            }
        }
    Vec3 da = a.planar ? a.normal : a.straight ? a.direction : Vec3.init;
    Vec3 db = b.planar ? b.normal : b.straight ? b.direction : Vec3.init;
    if (da.length > 0.5 && db.length > 0.5)
    {
        immutable c = max(-1.0, min(1.0, da.dot(db)));
        double ang = acos(c) * 180 / PI;
        // between planes or lines, 0 to 90; between a face and an edge, the
        // angle of the edge to the face's plane
        ang = min(ang, 180 - ang);
        if (a.planar != b.planar)
            ang = 90 - ang;
        r.angle = ang;
        if (a.planar && b.planar && abs(abs(c) - 1) < 1e-6)
            r.gap = abs(a.normal.dot(b.points[0] - a.points[0]));
    }
    return r;
}

/// How far one item lies from the other besides the nearest points of
/// measure: the farthest a point of either is from the other, and the mean
/// (by area for faces, by length for edges), both ways. Parallel flat faces
/// facing each other give the same three.
struct Spread
{
    double max = 0, mean = 0;
}

/// Spread of a and b, from about `budget` points spread over each.
Spread spread(Item a, Item b, size_t budget = 1200)
{
    Spread r;
    double means = 0;
    void from(ref const Item src, ref const Item dst)
    {
        Vec3[] at;
        double[] weight;
        double total = 0;
        foreach (t; src.triangles)
            total += (t[1] - t[0]).cross(t[2] - t[0]).length / 2;
        foreach (sg; src.segments)
            total += (sg[1] - sg[0]).length;
        // triangles cut into k² smaller ones, segments into k pieces, k by their share of the budget
        foreach (t; src.triangles)
        {
            immutable area = (t[1] - t[0]).cross(t[2] - t[0]).length / 2;
            immutable k = cast(size_t) max(1.0, min(30.0, sqrt(budget * area / max(total, 1e-12))));
            foreach (i; 0 .. k)
                foreach (j; 0 .. k - i)
                {
                    immutable u = (i + 1.0 / 3) / k, v = (j + 1.0 / 3) / k;
                    at ~= t[0] + (t[1] - t[0]) * u + (t[2] - t[0]) * v;
                    weight ~= area / (k * k);
                }
        }
        foreach (sg; src.segments)
        {
            immutable len = (sg[1] - sg[0]).length;
            immutable k = cast(size_t) max(1.0, min(200.0, budget * len / max(total, 1e-12)));
            foreach (i; 0 .. k)
            {
                at ~= sg[0] + (sg[1] - sg[0]) * ((i + 0.5) / k);
                weight ~= len / k;
            }
        }
        if (at.length == 0)
            foreach (q; src.points)
            {
                at ~= q;
                weight ~= 1;
            }
        const near = Near(dst);
        // one point's nearest is the next one's first guess: they come in order
        size_t hint;
        double sum = 0, wsum = 0;
        foreach (i, q; at)
        {
            Vec3 c;
            immutable d = closest(dst, near, q, c, &hint);
            sum += d * weight[i];
            wsum += weight[i];
            r.max = max(r.max, d);
        }
        // the corners too, for the farthest: each once, not once per triangle
        bool[Vec3] seen;
        foreach (q; src.points)
        {
            if (q in seen)
                continue;
            seen[q] = true;
            Vec3 c;
            r.max = max(r.max, closest(dst, near, q, c, &hint));
        }
        means += wsum > 0 ? sum / wsum : 0;
    }
    from(a, b);
    from(b, a);
    r.mean = means / 2;
    return r;
}

private:

/// The triangles' and segments' bounding spheres, so that closest skips
/// at once those too far to hold the nearest point: two whole parts have
/// thousands of triangles, and a point was checked against every one.
struct Near
{
    Vec3[] centre;
    double[] radius;

    this(ref const Item it)
    {
        foreach (t; it.triangles)
        {
            immutable m = (t[0] + t[1] + t[2]) / 3;
            centre ~= m;
            radius ~= max((t[0] - m).length, (t[1] - m).length, (t[2] - m).length);
        }
        foreach (sg; it.segments)
        {
            centre ~= (sg[0] + sg[1]) / 2;
            radius ~= (sg[1] - sg[0]).length / 2;
        }
    }
}

/// The nearest point of `it` to q. With `hint`, the index of a triangle or
/// segment near q, checked first (in place of a pass over all of them),
/// and set to the nearest one found.
double closest(ref const Item it, ref const Near near, Vec3 q, out Vec3 c, size_t* hint = null)
{
    immutable nt = it.triangles.length;
    Vec3 on(size_t i) => i < nt ? onTriangle(q, it.triangles[i][0], it.triangles[i][1], it.triangles[i][2])
        : onSegment(q, it.segments[i - nt][0], it.segments[i - nt][1]);
    double best = double.infinity;
    void take(Vec3 p)
    {
        immutable d = (p - q).length;
        if (d < best)
        {
            best = d;
            c = p;
        }
    }
    if (near.centre.length)
    {
        // the one whose sphere comes nearest first: a good bound early
        size_t first;
        if (hint !is null && *hint < near.centre.length)
            first = *hint;
        else
        {
            double low = double.infinity;
            foreach (i, m; near.centre)
            {
                immutable l = (m - q).length - near.radius[i];
                if (l < low)
                {
                    low = l;
                    first = i;
                }
            }
        }
        size_t won = first;
        take(on(first));
        foreach (i, m; near.centre)
            if (i != first && (m - q).length - near.radius[i] < best)
            {
                immutable was = best;
                take(on(i));
                if (best < was)
                    won = i;
            }
        if (hint !is null)
            *hint = won;
    }
    else
        foreach (p; it.points)
            take(p);
    return best;
}

Vec3 onSegment(Vec3 p, Vec3 a, Vec3 b)
{
    auto ab = b - a;
    immutable l = ab.dot(ab);
    if (l < 1e-18)
        return a;
    return a + ab * max(0.0, min(1.0, (p - a).dot(ab) / l));
}

/// Closest point to p on triangle abc (Ericson, Real-Time Collision Detection 5.1.5).
Vec3 onTriangle(Vec3 p, Vec3 a, Vec3 b, Vec3 c)
{
    auto ab = b - a, ac = c - a, ap = p - a;
    immutable d1 = ab.dot(ap), d2 = ac.dot(ap);
    if (d1 <= 0 && d2 <= 0)
        return a;
    auto bp = p - b;
    immutable d3 = ab.dot(bp), d4 = ac.dot(bp);
    if (d3 >= 0 && d4 <= d3)
        return b;
    immutable vc = d1 * d4 - d3 * d2;
    if (vc <= 0 && d1 >= 0 && d3 <= 0)
        return a + ab * (d1 / (d1 - d3));
    auto cp = p - c;
    immutable d5 = ab.dot(cp), d6 = ac.dot(cp);
    if (d6 >= 0 && d5 <= d6)
        return c;
    immutable vb = d5 * d2 - d1 * d6;
    if (vb <= 0 && d2 >= 0 && d6 <= 0)
        return a + ac * (d2 / (d2 - d6));
    immutable va = d3 * d6 - d5 * d4;
    if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0)
        return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)));
    immutable denom = 1 / (va + vb + vc);
    return a + ab * (vb * denom) + ac * (vc * denom);
}

/// Closest points between segments p1q1 and p2q2 (Ericson 5.1.9).
void segmentSegment(Vec3 p1, Vec3 q1, Vec3 p2, Vec3 q2, out Vec3 c1, out Vec3 c2)
{
    auto d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2;
    immutable a = d1.dot(d1), e = d2.dot(d2), f = d2.dot(r);
    double s, t;
    if (a <= 1e-18 && e <= 1e-18)
    {
        c1 = p1;
        c2 = p2;
        return;
    }
    if (a <= 1e-18)
    {
        s = 0;
        t = max(0.0, min(1.0, f / e));
    }
    else
    {
        immutable c = d1.dot(r);
        if (e <= 1e-18)
        {
            t = 0;
            s = max(0.0, min(1.0, -c / a));
        }
        else
        {
            immutable b = d1.dot(d2), denom = a * e - b * b;
            s = denom != 0 ? max(0.0, min(1.0, (b * f - c * e) / denom)) : 0;
            t = (b * s + f) / e;
            if (t < 0)
            {
                t = 0;
                s = max(0.0, min(1.0, -c / a));
            }
            else if (t > 1)
            {
                t = 1;
                s = max(0.0, min(1.0, (b - c) / a));
            }
        }
    }
    c1 = p1 + d1 * s;
    c2 = p2 + d2 * t;
}

unittest
{
    // two parallel squares 5 apart, one shifted: gap 5, distance 5
    Item sq(double z, double dx)
    {
        Item it;
        auto a = Vec3(dx, 0, z), b = Vec3(dx + 10, 0, z), c = Vec3(dx + 10, 10, z), d = Vec3(dx, 10, z);
        it.triangles = [[a, b, c], [a, c, d]];
        it.points = [a, b, c, d];
        it.normal = Vec3(0, 0, 1);
        it.planar = true;
        return it;
    }
    auto m = measure(sq(0, 0), sq(5, 3));
    assert(abs(m.distance - 5) < 1e-9 && abs(m.gap - 5) < 1e-9 && abs(m.angle) < 1e-6);
    // crossing edges: closest in their middles
    Item seg(Vec3 a, Vec3 b)
    {
        Item it;
        it.segments = [[a, b]];
        it.points = [a, b];
        it.straight = true;
        it.direction = (b - a).normalized;
        return it;
    }
    auto e = measure(seg(Vec3(-1, 0, 0), Vec3(1, 0, 0)), seg(Vec3(0, -1, 2), Vec3(0, 1, 2)));
    assert(abs(e.distance - 2) < 1e-9 && abs(e.angle - 90) < 1e-9);
}

unittest
{
    // the spheres only skip what cannot be nearest: the same as trying
    // every triangle, from scattered points, with and without a hint
    import std.random : Random, uniform;
    auto rnd = Random(7);
    Vec3 any() => Vec3(uniform(-20.0, 20.0, rnd), uniform(-20.0, 20.0, rnd), uniform(-20.0, 20.0, rnd));
    Item it;
    foreach (k; 0 .. 300)
    {
        auto a = any();
        Vec3[3] t = [a, a + any() * 0.1, a + any() * 0.1];
        it.triangles ~= t;
        it.points ~= t[];
    }
    const near = Near(it);
    size_t hint;
    foreach (k; 0 .. 200)
    {
        auto q = any() * 1.5;
        double brute = double.infinity;
        foreach (t; it.triangles)
            brute = min(brute, (onTriangle(q, t[0], t[1], t[2]) - q).length);
        Vec3 c;
        assert(abs(closest(it, near, q, c) - brute) < 1e-12);
        assert(abs(closest(it, near, q, c, &hint) - brute) < 1e-12);
        assert(abs((c - q).length - brute) < 1e-12);
    }
}
