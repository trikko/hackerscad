/// Convex hulls: of points in space (quickhull, a closed triangle mesh) and
/// of points in a plane (the monotone chain, a polygon).
module hackerscad.geom.hull;

import std.algorithm : max, min, sort;
import std.math : abs;

import hackerscad.geom.mesh;
import hackerscad.geom.vec;

/// Points that have no hull: fewer than four, or all on a plane or a line.
class HullException : Exception
{
    this(string msg) { super(msg); }
}

/// The convex hull of `points`: a closed mesh, triangles wound outwards,
/// with only the points on the hull as vertices.
Mesh convexHull(const(Vec3)[] points)
{
    if (points.length < 4)
        throw new HullException("a hull in space needs at least 4 points");
    // how far is "on the plane": a fraction of the points' size
    Vec3 lo = points[0], hi = points[0];
    foreach (p; points)
    {
        lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z));
        hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z));
    }
    immutable eps = 1e-9 * max(1.0, (hi - lo).length);

    // the first tetrahedron: the two points farthest apart among the
    // extremes, the farthest from their line, the farthest from that plane
    static double axis(Vec3 p, size_t k) => k == 0 ? p.x : k == 1 ? p.y : p.z;
    size_t[6] ext;
    foreach (i, p; points)
        foreach (k; 0 .. 3)
        {
            if (axis(p, k) < axis(points[ext[2 * k]], k))
                ext[2 * k] = i;
            if (axis(p, k) > axis(points[ext[2 * k + 1]], k))
                ext[2 * k + 1] = i;
        }
    size_t i0 = ext[0], i1 = ext[1];
    double best = -1;
    foreach (a; ext)
        foreach (b; ext)
            if ((points[a] - points[b]).length > best)
            {
                best = (points[a] - points[b]).length;
                i0 = a;
                i1 = b;
            }
    if (best <= eps)
        throw new HullException("the points are all in one place: there is no hull");
    immutable dir = (points[i1] - points[i0]).normalized;
    size_t i2 = i0;
    best = -1;
    foreach (i, p; points)
    {
        immutable d = (p - points[i0]).cross(dir).length;
        if (d > best)
        {
            best = d;
            i2 = i;
        }
    }
    if (best <= eps)
        throw new HullException("the points are all on a line: there is no hull");
    immutable n0 = (points[i1] - points[i0]).cross(points[i2] - points[i0]).normalized;
    size_t i3 = i0;
    best = -1;
    foreach (i, p; points)
    {
        immutable d = abs((p - points[i0]).dot(n0));
        if (d > best)
        {
            best = d;
            i3 = i;
        }
    }
    if (best <= eps)
        throw new HullException("the points are all on a plane: a hull in space needs some depth");

    struct Face
    {
        uint[3] v;
        Vec3 n;          /// outward, unit
        double offset;   /// n · p on the face
        uint[] outside;  /// points beyond it, not yet on the hull
        bool alive = true;
    }

    Face[] faces;
    uint[ulong] edgeFace;   // directed edge a → b: the face that has it
    static ulong key(uint a, uint b) => cast(ulong) a << 32 | b;
    immutable centre = (points[i0] + points[i1] + points[i2] + points[i3]) * 0.25;

    uint addFace(uint a, uint b, uint c)
    {
        auto n = (points[b] - points[a]).cross(points[c] - points[a]).normalized;
        if (n.dot(points[a] - centre) < 0)   // only for the first four: later faces come wound right
        {
            immutable t = b;
            b = c;
            c = t;
            n = -n;
        }
        immutable f = cast(uint) faces.length;
        faces ~= Face([a, b, c], n, n.dot(points[a]));
        edgeFace[key(a, b)] = f;
        edgeFace[key(b, c)] = f;
        edgeFace[key(c, a)] = f;
        return f;
    }

    double distance(const ref Face f, size_t p) => f.n.dot(points[p]) - f.offset;

    immutable uint[4] t = [cast(uint) i0, cast(uint) i1, cast(uint) i2, cast(uint) i3];
    uint[] open;
    foreach (tri; [[0, 1, 2], [0, 3, 1], [1, 3, 2], [0, 2, 3]])
        open ~= addFace(t[tri[0]], t[tri[1]], t[tri[2]]);
    foreach (i; 0 .. points.length)
    {
        if (i == i0 || i == i1 || i == i2 || i == i3)
            continue;
        foreach (f; open)
            if (distance(faces[f], i) > eps)
            {
                faces[f].outside ~= cast(uint) i;
                break;
            }
    }

    // grow: the farthest point beyond a face, the faces it sees replaced by
    // a cone from it to their horizon
    uint[] stack = open.dup;
    uint[] seen;   // per face: the round it was found visible in
    uint round;
    while (stack.length)
    {
        immutable f = stack[$ - 1];
        stack = stack[0 .. $ - 1];
        if (!faces[f].alive || faces[f].outside.length == 0)
            continue;
        uint apex = faces[f].outside[0];
        foreach (q; faces[f].outside)
            if (distance(faces[f], q) > distance(faces[f], apex))
                apex = q;

        round++;
        seen.length = faces.length;
        uint[] visible = [f];
        seen[f] = round;
        uint[2][] horizon;
        for (size_t qi = 0; qi < visible.length; qi++)
        {
            immutable vf = visible[qi];
            foreach (k; 0 .. 3)
            {
                immutable a = faces[vf].v[k], b = faces[vf].v[(k + 1) % 3];
                immutable other = edgeFace[key(b, a)];
                if (seen[other] == round)
                    continue;
                // whether a face is seen depends on it alone: one judged
                // hidden here is hidden from every side
                if (distance(faces[other], apex) > eps)
                {
                    seen[other] = round;
                    visible ~= other;
                }
                else
                    horizon ~= [a, b];
            }
        }
        auto edges = horizon;
        uint[] orphans;
        foreach (vf; visible)
        {
            foreach (q; faces[vf].outside)
                if (q != apex)
                    orphans ~= q;
            faces[vf].outside = null;
            faces[vf].alive = false;
            foreach (k; 0 .. 3)
                edgeFace.remove(key(faces[vf].v[k], faces[vf].v[(k + 1) % 3]));
        }
        uint[] made;
        foreach (e; edges)
        {
            immutable a = e[0], b = e[1];
            auto n = (points[b] - points[a]).cross(points[apex] - points[a]).normalized;
            immutable nf = cast(uint) faces.length;
            faces ~= Face([a, b, apex], n, n.dot(points[a]));
            edgeFace[key(a, b)] = nf;
            edgeFace[key(b, apex)] = nf;
            edgeFace[key(apex, a)] = nf;
            made ~= nf;
        }
        foreach (q; orphans)
            foreach (nf; made)
                if (distance(faces[nf], q) > eps)
                {
                    faces[nf].outside ~= q;
                    break;
                }
        foreach (nf; made)
            if (faces[nf].outside.length)
                stack ~= nf;
    }

    // the faces left, with their vertices renumbered
    Mesh m;
    auto index = new int[points.length];
    index[] = -1;
    foreach (ref f; faces)
        if (f.alive)
            foreach (v; f.v)
            {
                if (index[v] < 0)
                {
                    index[v] = cast(int) m.vertexCount;
                    m.verts ~= [cast(float) points[v].x, cast(float) points[v].y, cast(float) points[v].z];
                }
                m.tris ~= cast(uint) index[v];
            }
    return m;
}

/// The convex hull of points in a plane: its corners counter-clockwise,
/// without points on its sides. Fewer than 3 corners: the points are on a
/// line.
double[2][] convexHull2(const(double[2])[] input)
{
    auto p = input.dup;
    sort!((a, b) => a[0] < b[0] || (a[0] == b[0] && a[1] < b[1]))(p);
    static double cross(double[2] o, double[2] a, double[2] b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
    double[2][] h;
    foreach (q; p)   // lower chain
    {
        while (h.length >= 2 && cross(h[$ - 2], h[$ - 1], q) <= 0)
            h = h[0 .. $ - 1];
        h ~= q;
    }
    immutable lower = h.length + 1;
    foreach_reverse (q; p[0 .. $ - 1])   // upper chain
    {
        while (h.length >= lower && cross(h[$ - 2], h[$ - 1], q) <= 0)
            h = h[0 .. $ - 1];
        h ~= q;
    }
    return h.length > 1 ? h[0 .. $ - 1] : h;
}

unittest
{
    // a cube's corners and points inside and on its faces: 8 corners, 12
    // triangles, the cube's volume
    Vec3[] pts;
    foreach (x; [0.0, 2])
        foreach (y; [0.0, 2])
            foreach (z; [0.0, 2])
                pts ~= Vec3(x, y, z);
    pts ~= [Vec3(1, 1, 1), Vec3(1, 1, 0), Vec3(0.5, 2, 1.5), Vec3(1.2, 0.3, 0.8)];
    auto m = convexHull(pts);
    assert(m.isClosed);
    assert(abs(m.volume - 8) < 1e-9, "volume");
    assert(m.triangleCount == 12 || m.triangleCount > 12);   // a face may split into more than 2 triangles

    // points on a sphere: every one on the hull, closed, outward
    import std.math : cos, sin, PI;
    Vec3[] sphere;
    foreach (i; 0 .. 20)
        foreach (j; 0 .. 40)
        {
            immutable th = PI * (i + 0.5) / 20, ph = 2 * PI * j / 40;
            sphere ~= Vec3(sin(th) * cos(ph), sin(th) * sin(ph), cos(th)) * 10;
        }
    auto s = convexHull(sphere);
    assert(s.isClosed && s.vertexCount == sphere.length && s.volume > 0);
    assert(s.volume < 4.0 / 3 * PI * 1000);

    import std.exception : assertThrown;
    assertThrown!HullException(convexHull([Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(1, 1, 0)]));

    // in the plane: a square with a point inside and one on a side
    auto sq = convexHull2([[0, 0], [2, 0], [2, 2], [0, 2], [1, 1], [1, 0]]);
    assert(sq == [[0, 0], [2, 0], [2, 2], [0, 2]]);
}
