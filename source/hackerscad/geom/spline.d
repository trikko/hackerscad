/// Smooth curves through points, as a sketch's s.spline draws them: a cubic
/// spline, continuous to its second derivative, each piece as long in its
/// parameter as the step between its two points (chord length); an open one
/// does not bend at its ends (natural), a closed one goes round smoothly.
/// It is given as cubic Bézier pieces: the view samples them and the kernel
/// joins them into one B-spline, so both draw the same curve.
module hackerscad.geom.spline;

import std.math : abs;

import hackerscad.geom.vec;

/// The Bézier poles of the spline through `pts` (at least 2, or 3 closed),
/// three per piece and then the last point: pts.length - 1 pieces when open,
/// pts.length when closed (the last pole is the first point again).
/// Consecutive points must differ.
Vec3[] splinePoles(const(Vec3)[] pts, bool closed)
{
    assert(pts.length >= (closed ? 3 : 2), "a spline needs 2 points, or 3 closed");
    immutable n = pts.length;
    immutable pieces = closed ? n : n - 1;
    Vec3 at(size_t i) => pts[i % n];
    auto h = new double[pieces];
    foreach (i; 0 .. pieces)
    {
        h[i] = (at(i + 1) - at(i)).length;
        assert(h[i] > 0, "two consecutive points of a spline coincide");
    }
    // the second derivatives at the points: m[i]; natural ends keep m[0] = m[n - 1] = 0
    auto m = new Vec3[n];
    immutable unknowns = closed ? n : n - 2;
    if (unknowns > 0)
    {
        // h[i-1] m[i-1] + 2 (h[i-1] + h[i]) m[i] + h[i] m[i+1] = 6 (slope[i] - slope[i-1]), one row per unknown
        auto a = new double[][](unknowns, unknowns);
        foreach (row; a)
            row[] = 0;
        auto rhs = new Vec3[unknowns];
        size_t col(size_t point) => closed ? point % n : point - 1;   // the unknown of a point
        foreach (r; 0 .. unknowns)
        {
            immutable i = closed ? r : r + 1;   // the point of this row
            immutable prev = closed ? (i + n - 1) % n : i - 1;
            immutable hp = h[prev % pieces], hi = h[i % pieces];
            a[r][col(i)] += 2 * (hp + hi);
            if (closed || prev >= 1)
                a[r][col(prev)] += hp;
            if (closed || i + 1 <= n - 2)
                a[r][col(i + 1)] += hi;
            rhs[r] = ((at(i + 1) - at(i)) / hi - (at(i) - at(prev)) / hp) * 6;
        }
        auto x = solve(a, rhs);
        foreach (r; 0 .. unknowns)
            m[closed ? r : r + 1] = x[r];
    }
    Vec3[] poles;
    foreach (i; 0 .. pieces)
    {
        immutable hi = h[i];
        auto p0 = at(i), p1 = at(i + 1);
        auto m0 = m[i], m1 = m[(i + 1) % n];
        auto slope = (p1 - p0) / hi;
        auto d0 = slope - (m0 * 2 + m1) * (hi / 6);   // the derivative leaving p0
        auto d1 = slope + (m0 + m1 * 2) * (hi / 6);   // and arriving at p1
        poles ~= [p0, p0 + d0 * (hi / 3), p1 - d1 * (hi / 3)];
    }
    poles ~= at(pieces);
    return poles;
}

/// Points along the Bézier pieces of `poles` (as splinePoles gives them),
/// `perPiece` steps on each: a polyline to draw.
Vec3[] sampleSpline(const(Vec3)[] poles, int perPiece = 24)
{
    Vec3[] r;
    for (size_t s = 0; s + 3 < poles.length; s += 3)
        foreach (k; 0 .. perPiece)
        {
            immutable t = cast(double) k / perPiece, u = 1 - t;
            r ~= poles[s] * (u * u * u) + poles[s + 1] * (3 * u * u * t) + poles[s + 2] * (3 * u * t * t)
                + poles[s + 3] * (t * t * t);
        }
    r ~= poles[$ - 1];
    return r;
}

/// Gaussian elimination with partial pivoting, the right-hand sides vectors.
private Vec3[] solve(double[][] a, Vec3[] b)
{
    immutable n = b.length;
    foreach (c; 0 .. n)
    {
        size_t p = c;
        foreach (r; c + 1 .. n)
            if (abs(a[r][c]) > abs(a[p][c]))
                p = r;
        if (p != c)
        {
            auto t = a[p];
            a[p] = a[c];
            a[c] = t;
            auto tb = b[p];
            b[p] = b[c];
            b[c] = tb;
        }
        foreach (r; c + 1 .. n)
        {
            immutable f = a[r][c] / a[c][c];
            if (f == 0)
                continue;
            foreach (k; c .. n)
                a[r][k] -= f * a[c][k];
            b[r] = b[r] - b[c] * f;
        }
    }
    auto x = new Vec3[n];
    foreach_reverse (r; 0 .. n)
    {
        auto s = b[r];
        foreach (k; r + 1 .. n)
            s = s - x[k] * a[r][k];
        x[r] = s / a[r][r];
    }
    return x;
}

unittest
{
    // through every point, smooth where the pieces meet, closed ones round the join too
    import std.math : isClose;
    bool same(Vec3 a, Vec3 b) => (a - b).length < 1e-9;
    auto pts = [Vec3(0, 0), Vec3(10, 5), Vec3(20, -3), Vec3(35, 4)];
    foreach (closed; [false, true])
    {
        auto p = splinePoles(pts, closed);
        immutable pieces = closed ? pts.length : pts.length - 1;
        assert(p.length == 3 * pieces + 1);
        foreach (i; 0 .. pieces)
            assert(same(p[3 * i], pts[i]));
        assert(same(p[$ - 1], closed ? pts[0] : pts[$ - 1]));
        // the same tangent arriving at a point and leaving it (the poles either side are in line, as far)
        foreach (i; 1 .. pieces)
            assert(same(p[3 * i] - p[3 * i - 1], p[3 * i + 1] - p[3 * i]) || isClose(
                (p[3 * i] - p[3 * i - 1]).normalized.dot((p[3 * i + 1] - p[3 * i]).normalized), 1.0, 1e-9));
        if (closed)
            assert(isClose((p[$ - 1] - p[$ - 2]).normalized.dot((p[1] - p[0]).normalized), 1.0, 1e-9));
        auto line = sampleSpline(p);
        assert(same(line[0], pts[0]) && same(line[$ - 1], closed ? pts[0] : pts[$ - 1]));
    }
    // points in a row: a straight line
    auto straight = splinePoles([Vec3(0, 0), Vec3(5, 0), Vec3(20, 0)], false);
    foreach (q; straight)
        assert(abs(q.y) < 1e-12);
    // two points: the segment between them
    auto two = splinePoles([Vec3(0, 0), Vec3(9, 3)], false);
    assert(two.length == 4 && same(two[1], Vec3(3, 1)) && same(two[2], Vec3(6, 2)));
}
