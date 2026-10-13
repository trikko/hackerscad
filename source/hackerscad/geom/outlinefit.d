/// Sections of a mesh read as numbers: the mesh cut by a plane, the cut's
/// closed outlines, and each outline as straight lines, arcs and whole
/// circles fitted to its points; written back as a hackerscad sketch.
module hackerscad.geom.outlinefit;

import std.algorithm : max, min, reverse;
import std.array : array;
import std.format : format;
import std.math : abs, atan2, cos, PI, round, sin, sqrt;

import hackerscad.geom.mesh;
import hackerscad.geom.meshfeatures : plausible;
import hackerscad.geom.vec;

alias P2 = double[2];

/// The closed outlines where a plane cuts a mesh, in the plane's axes `u`,
/// `v` (2D points); the plane is {p : p · n = at}.
P2[][] slice(const Mesh m, Vec3 n, double at, Vec3 u, Vec3 v)
{
    // a vertex exactly on the plane would make the cut ambiguous: nudge the plane a hair
    double size = 1;
    foreach (i; 0 .. m.vertexCount)
        size = max(size, m.vertex(i).length);
    immutable eps = 1e-7 * size;
    foreach (i; 0 .. m.vertexCount)
        if (abs(m.vertex(i).dot(n) - at) < eps)
        {
            at += 3 * eps;
            break;
        }
    // the segments, one per triangle crossed, oriented so that the solid is on their left
    P2[2][] segs;
    foreach (t; 0 .. m.triangleCount)
    {
        Vec3[3] p;
        double[3] d;
        foreach (k; 0 .. 3)
        {
            p[k] = m.vertex(m.tris[3 * t + k]);
            d[k] = p[k].dot(n) - at;
        }
        Vec3[] cut;
        foreach (k; 0 .. 3)
        {
            immutable a = k, b = (k + 1) % 3;
            if ((d[a] < 0) != (d[b] < 0))
                cut ~= p[a] + (p[b] - p[a]) * (d[a] / (d[a] - d[b]));
        }
        if (cut.length != 2)
            continue;
        // the triangle's normal crossed with the plane's gives the direction along the outline
        auto tn = (p[1] - p[0]).cross(p[2] - p[0]);
        auto dir = n.cross(tn);
        if ((cut[1] - cut[0]).dot(dir) < 0)
        {
            auto t2 = cut[0];
            cut[0] = cut[1];
            cut[1] = t2;
        }
        segs ~= [[cut[0].dot(u), cut[0].dot(v)], [cut[1].dot(u), cut[1].dot(v)]];
    }
    // chained by their ends
    static long[2] key(P2 p, double q) => [cast(long) round(p[0] / q), cast(long) round(p[1] / q)];
    immutable q = 1e-6 * size;
    size_t[long[2]] startAt;
    foreach (i, s; segs)
        startAt[key(s[0], q)] = i;
    auto used = new bool[segs.length];
    P2[][] loops;
    foreach (i; 0 .. segs.length)
    {
        if (used[i])
            continue;
        P2[] loop;
        size_t at_ = i;
        while (!used[at_])
        {
            used[at_] = true;
            loop ~= segs[at_][0];
            auto next = key(segs[at_][1], q) in startAt;
            if (next is null)
                break;
            at_ = *next;
        }
        if (loop.length >= 3)
            loops ~= loop;
    }
    return loops;
}

/// A piece of an outline.
struct Element
{
    bool arc;          /// else a straight line
    P2 from, to;
    P2 center;         /// arcs
    double radius = 0; /// arcs
    double sweep = 0;  /// arcs: radians, positive counter-clockwise
    bool circle;       /// a whole circle (from == to)

    double length() const => arc ? abs(sweep) * radius : sqrt((to[0] - from[0]) ^^ 2 + (to[1] - from[1]) ^^ 2);
}

/// A closed outline as lines and arcs within `tol` of its points: from each
/// point, the longest piece (line or arc) that stays within it.
Element[] fit(const P2[] input, double tol)
{
    // points on the straight line between their neighbours dropped: a facet's two triangles cut
    // its chord in two, and the uneven pieces would hide the curve's even facets
    P2[] loop = input.dup;
    for (bool changed = true; changed && loop.length > 3;)
    {
        changed = false;
        P2[] kept;
        foreach (i; 0 .. loop.length)
        {
            auto a = loop[(i + loop.length - 1) % loop.length], b = loop[i], c = loop[(i + 1) % loop.length];
            if (dist(a, b) < 1e-9 || (pointLine(b, a, c) < 0.05 * tol && abs(turn(a, b, c)) < 0.02))
            {
                changed = true;
                continue;
            }
            kept ~= b;
        }
        if (kept.length < 3)
            break;
        loop = kept;
    }
    immutable n = loop.length;
    if (n < 3)
        return null;
    P2 at(size_t i) => loop[i % n];
    // a whole circle?
    {
        P2 c;
        double r, worst;
        if (circleFit(loop, c, r, worst) && worst < tol && n >= 8)
        {
            immutable ccw = area(loop) > 0;
            return [Element(true, loop[0], loop[0], c, r, ccw ? 2 * PI : -2 * PI, true)];
        }
    }
    // start at the longest segment (a straight side, or a sharp corner's), so that no arc is cut
    // by the start
    size_t start;
    double longest = -1;
    foreach (i; 0 .. n)
        if (dist(at(i), at(i + 1)) > longest)
        {
            longest = dist(at(i), at(i + 1));
            start = i;
        }
    Element[] out_;
    size_t i = 0;
    while (i < n)
    {
        // the longest line from i
        size_t lineEnd = i + 1;
        while (lineEnd + 1 <= n && collinear(loop, start, i, lineEnd + 1, tol))
            lineEnd++;
        // the longest arc from i: at least 3 segments, turning one way, under a full turn
        size_t arcEnd = i;
        P2 ac;
        double ar = 0;
        for (size_t j = i + 3; j <= n; j++)
        {
            P2[] pts;
            foreach (k; i .. j + 1)
                pts ~= at(start + k);
            P2 c;
            double r, worst;
            if (!circleFit(pts, c, r, worst) || worst > tol || r > 1e4 * tol)
                break;
            // no straight run in it: every segment short against the radius (< 45° of arc), and
            // none much longer than the typical one (a curve is cut in about even facets; a
            // straight side among them is much longer)
            bool ok = true;
            double[] lens;
            foreach (k; 0 .. pts.length - 1)
            {
                immutable l = dist(pts[k], pts[k + 1]);
                if (l > 0.77 * r)
                    ok = false;
                lens ~= l;
            }
            import std.algorithm : sort, maxElement;
            auto sorted = lens.dup;
            sorted.sort();
            if (lens.maxElement > 3 * sorted[$ / 2] + tol)
                ok = false;
            if (!ok)
                break;
            arcEnd = j;
            ac = c;
            ar = r;
        }
        auto a = at(start + i);
        if (arcEnd > lineEnd)
        {
            auto b = at(start + arcEnd);
            // the sweep: the turning from a to b around the centre, the way the points go
            double sweep = 0;
            foreach (k; i .. arcEnd)
            {
                auto p = at(start + k), q = at(start + k + 1);
                auto d = atan2(q[1] - ac[1], q[0] - ac[0]) - atan2(p[1] - ac[1], p[0] - ac[0]);
                while (d > PI) d -= 2 * PI;
                while (d < -PI) d += 2 * PI;
                sweep += d;
            }
            out_ ~= Element(true, a, b, ac, ar, sweep);
            i = arcEnd;
        }
        else
        {
            out_ ~= Element(false, a, at(start + lineEnd));
            i = lineEnd;
        }
    }
    // lines in a row along one direction (a run split by a point between) joined
    Element[] merged;
    foreach (e; out_)
    {
        if (merged.length && !e.arc && !merged[$ - 1].arc)
        {
            auto pr = merged[$ - 1];
            if (abs(turn(pr.from, pr.to, e.to)) < 1e-3 && pointLine(pr.to, pr.from, e.to) < tol)
            {
                merged[$ - 1].to = e.to;
                continue;
            }
        }
        merged ~= e;
    }
    // and across the start: a side the start fell in the middle of
    if (merged.length > 2 && !merged[0].arc && !merged[$ - 1].arc)
    {
        auto last = merged[$ - 1], first = merged[0];
        if (abs(turn(last.from, last.to, first.to)) < 1e-3 && pointLine(last.to, last.from, first.to) < tol)
        {
            merged[0].from = last.from;
            merged = merged[0 .. $ - 1];
        }
    }
    return merged;
}

private double dist(P2 a, P2 b) => sqrt((a[0] - b[0]) ^^ 2 + (a[1] - b[1]) ^^ 2);

/// The signed angle turned at b going a → b → c.
private double turn(P2 a, P2 b, P2 c)
{
    immutable x1 = b[0] - a[0], y1 = b[1] - a[1], x2 = c[0] - b[0], y2 = c[1] - b[1];
    return atan2(x1 * y2 - y1 * x2, x1 * x2 + y1 * y2);
}

private double pointLine(P2 p, P2 a, P2 b)
{
    immutable dx = b[0] - a[0], dy = b[1] - a[1], l = sqrt(dx * dx + dy * dy);
    if (l < 1e-300)
        return dist(p, a);
    return abs((p[0] - a[0]) * dy - (p[1] - a[1]) * dx) / l;
}

private bool collinear(const P2[] loop, size_t start, size_t i, size_t j, double tol)
{
    immutable n = loop.length;
    auto a = loop[(start + i) % n], b = loop[(start + j) % n];
    foreach (k; i + 1 .. j)
        if (pointLine(loop[(start + k) % n], a, b) > tol)
            return false;
    // and every segment along the line's direction (within 1°): the first facet of a curve
    // next to it may lie within the tolerance, but it already turns
    immutable dx = b[0] - a[0], dy = b[1] - a[1], l = sqrt(dx * dx + dy * dy);
    foreach (k; i .. j)
    {
        auto p = loop[(start + k) % n], q = loop[(start + k + 1) % n];
        immutable sx = q[0] - p[0], sy = q[1] - p[1], sl = sqrt(sx * sx + sy * sy);
        if (sl > 1e-12 && l > 1e-12 && (sx * dx + sy * dy) / (sl * l) < 0.99985)
            return false;
    }
    return true;
}

/// The signed area (positive counter-clockwise).
double area(const P2[] loop)
{
    double a = 0;
    foreach (i; 0 .. loop.length)
    {
        auto p = loop[i], q = loop[(i + 1) % loop.length];
        a += p[0] * q[1] - q[0] * p[1];
    }
    return a / 2;
}

/// The circle nearest to the points (algebraic fit), and how far from it the farthest is.
bool circleFit(const P2[] pts, out P2 c, out double r, out double worst)
{
    // x² + y² + D x + E y + F = 0, least squares, on the points moved to their mean (far from
    // the origin the sums lose the digits the fit needs)
    double mx = 0, my = 0;
    foreach (p; pts)
    {
        mx += p[0];
        my += p[1];
    }
    mx /= pts.length;
    my /= pts.length;
    double[3][3] a = 0;
    double[3] b = 0;
    foreach (q; pts)
    {
        immutable P2 p = [q[0] - mx, q[1] - my];
        immutable double[3] row = [p[0], p[1], 1];
        immutable rhs = -(p[0] * p[0] + p[1] * p[1]);
        foreach (s; 0 .. 3)
        {
            foreach (t; 0 .. 3)
                a[s][t] += row[s] * row[t];
            b[s] += row[s] * rhs;
        }
    }
    // Cramer's rule
    double det3(double[3][3] m) => m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    immutable d = det3(a);
    if (abs(d) < 1e-18)
        return false;
    double[3] x;
    foreach (col; 0 .. 3)
    {
        auto m = a;
        foreach (row; 0 .. 3)
            m[row][col] = b[row];
        x[col] = det3(m) / d;
    }
    immutable P2 local = [-x[0] / 2, -x[1] / 2];
    immutable rr = local[0] * local[0] + local[1] * local[1] - x[2];
    if (!(rr > 0))
        return false;
    r = sqrt(rr);
    c = [local[0] + mx, local[1] + my];
    worst = 0;
    foreach (p; pts)
        worst = max(worst, abs(dist(p, c) - r));
    return true;
}

private string mm(double v)
{
    immutable p = plausible(v);
    return format("%g", p == 0 ? 0.0 : p);   // never "-0"
}
private string pt(P2 p) => format("(%s, %s)", mm(p[0]), mm(p[1]));

/// The outlines as lines of text: each piece with its sizes.
string describe(const Element[][] loops)
{
    string s;
    foreach (li, loop; loops)
    {
        s ~= format("outline %d:\n", li + 1);
        foreach (e; loop)
        {
            if (e.circle)
                s ~= format("  circle ⌀%s, centre %s\n", mm(2 * e.radius), pt(e.center));
            else if (e.arc)
                s ~= format("  arc r %s, centre %s, from %s to %s, %s°%s\n", mm(e.radius), pt(e.center), pt(e.from), pt(e.to),
                    mm(abs(e.sweep) * 180 / PI), e.sweep > 0 ? " counter-clockwise" : " clockwise");
            else
                s ~= format("  line %s → %s, %s long\n", pt(e.from), pt(e.to), mm(e.length));
        }
    }
    return s;
}

/// The outlines as a hackerscad sketch, in the plane's axes: points pinned
/// where they are, lines, arcs and circles; `name` its function.
string sketchCode(const Element[][] loops, string name)
{
    string s = format("/// The section, from the mesh: extrude it, or turn it into a shape of your own.\nProfile %s()\n{\n    auto s = sketch();\n", name);
    int k;
    string point(P2 p)
    {
        immutable id = format("p%d", k++);
        s ~= format("    auto %s = s.point(%s.mm, %s.mm, fixed: true);\n", id, mm(p[0]), mm(p[1]));
        return id;
    }
    foreach (loop; loops)
    {
        if (loop.length == 1 && loop[0].circle)
        {
            auto c = point(loop[0].center);
            s ~= format("    s.circle(%s, d: %s.mm);\n", c, mm(2 * loop[0].radius));
            continue;
        }
        immutable first = point(loop[0].from);
        string prev = first;
        foreach (i, e; loop)
        {
            immutable next = i + 1 == loop.length ? first : point(e.to);
            if (e.arc)
            {
                auto c = point(e.center);
                // arcs go counter-clockwise from start to end
                if (e.sweep > 0)
                    s ~= format("    s.arc(%s, %s, %s);\n", c, prev, next);
                else
                    s ~= format("    s.arc(%s, %s, %s);\n", c, next, prev);
            }
            else
                s ~= format("    s.line(%s, %s);\n", prev, next);
            prev = next;
        }
    }
    s ~= "    return s.profile;\n}\n";
    return s;
}

unittest
{
    // a rounded rectangle 40 × 20, corners r 5, faceted every 15°, with a hole ⌀6 in it
    P2[] outline;
    void corner(double cx, double cy, double from)
    {
        foreach (i; 0 .. 7)
        {
            immutable a = from + PI / 2 * i / 6;
            outline ~= [cx + 5 * cos(a), cy + 5 * sin(a)];
        }
    }
    corner(15, -5, -PI / 2);
    corner(15, 5, 0);
    corner(-15, 5, PI / 2);
    corner(-15, -5, PI);
    auto e = fit(outline, 0.01);
    size_t lines, arcs;
    foreach (x; e)
    {
        if (x.arc)
        {
            arcs++;
            assert(abs(x.radius - 5) < 1e-6 && abs(abs(x.sweep) - PI / 2) < 1e-6, describe([e]));
        }
        else
            lines++;
    }
    assert(lines == 4 && arcs == 4, describe([e]));
    P2[] hole;
    foreach (i; 0 .. 48)
        hole ~= [3 * cos(-2 * PI * i / 48), 3 * sin(-2 * PI * i / 48)];
    auto h = fit(hole, 0.01);
    assert(h.length == 1 && h[0].circle && abs(h[0].radius - 3) < 1e-9 && h[0].sweep < 0);
    auto code = sketchCode([e, h], "section");
    assert(code.length > 0);
}
