/// Sections of a mesh read as numbers: the mesh cut by a plane, the cut's
/// closed outlines, and each outline as straight lines, arcs and whole
/// circles fitted to its points; written back as a hackerscad sketch.
module hackerscad.geom.outlinefit;

import std.algorithm : max, min, reverse;
import std.array : array;
import std.format : format;
import std.math : abs, asin, atan2, cos, PI, round, sin, sqrt;

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
    immutable eps = 1e-5 + 1e-7 * size;
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
    // chained by their ends, whichever way each one points: a sliver of a triangle (meshes have them where
    // they were mended) has no reliable normal, and its segment may point back; each outline is then turned
    // the way most of its length points
    static long[2] key(P2 p, double q) => [cast(long) round(p[0] / q), cast(long) round(p[1] / q)];
    immutable q = 1e-6 * size;
    size_t[][long[2]] touching;
    foreach (i, s; segs)
        if (key(s[0], q) != key(s[1], q))
            foreach (e; 0 .. 2)
                touching[key(s[e], q)] ~= i;
    auto used = new bool[segs.length];
    P2[][] loops;
    P2[][] open;   // chains that did not come back to their start (a mesh with a flaw there)
    foreach (i; 0 .. segs.length)
    {
        if (used[i] || key(segs[i][0], q) == key(segs[i][1], q))
            continue;
        P2[] loop = [segs[i][0]];
        double along = 0;   // the length of the segments walked their own way, less the others'
        size_t at_ = i;
        P2 from = segs[i][0];
        bool closed;
        immutable home = key(segs[i][0], q);
        while (true)
        {
            used[at_] = true;
            immutable forward = key(segs[at_][0], q) == key(from, q);
            immutable to = segs[at_][forward ? 1 : 0];
            along += (forward ? 1 : -1) * dist(segs[at_][0], segs[at_][1]);
            if (key(to, q) == home)
            {
                closed = true;
                break;
            }
            loop ~= to;
            size_t next = size_t.max;
            foreach (o; touching.get(key(to, q), null))
                if (!used[o])
                {
                    next = o;
                    break;
                }
            if (next == size_t.max)
                break;
            from = to;
            at_ = next;
        }
        if (along < 0)
            loop.reverse();
        if (!closed)
        {
            open ~= loop;
            continue;
        }
        // an outline with no area: a face lying in the plane, cut along its edge
        if (loop.length >= 3 && abs(area(loop)) > 1e-4)
            loops ~= loop;
    }
    // open chains joined end to start where their ends are close (a gap a mesh left), the rest dropped:
    // closing them blindly would draw lines across the part
    immutable gap = max(1e-3, 1e-5 * size);
    auto taken = new bool[open.length];
    foreach (i; 0 .. open.length)
    {
        if (taken[i])
            continue;
        taken[i] = true;
        auto chain = open[i];
        for (bool grown = true; grown;)
        {
            grown = false;
            if (dist(chain[$ - 1], chain[0]) <= gap)
                break;
            foreach (j; 0 .. open.length)
                if (!taken[j] && dist(chain[$ - 1], open[j][0]) <= gap)
                {
                    chain ~= open[j][1 .. $];
                    taken[j] = true;
                    grown = true;
                    break;
                }
        }
        if (chain.length >= 4 && dist(chain[$ - 1], chain[0]) <= gap && abs(area(chain[0 .. $ - 1])) > 1e-4)
            loops ~= chain[0 .. $ - 1];
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
Element[] fit(const P2[] input, double tol, bool traced = false)
{
    if (traced)
        return fitTraced(input, tol);
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

private bool collinear(const P2[] loop, size_t start, size_t i, size_t j, double tol, bool anyDirection = false)
{
    immutable n = loop.length;
    auto a = loop[(start + i) % n], b = loop[(start + j) % n];
    foreach (k; i + 1 .. j)
        if (pointLine(loop[(start + k) % n], a, b) > tol)
            return false;
    if (anyDirection)
        return true;
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

/// What an outline is, in a designer's words.
struct Shape
{
    string kind;   /// circle, notched circle, rectangle, rounded rectangle, hexagon, teardrop, slot, D, polygon,
                   /// outline
    P2 center;
    double a = 0, b = 0;   /// circle: diameter; rectangle: width, height (along the axes); hexagon: across
                           /// flats; teardrop: diameter; slot: length, width; rounded rectangle: w, h, b = r
    double r = 0;          /// rounded rectangle: the corners' radius; D: the flat's distance from the centre;
                           /// notched circle: the notch's radius
    double angle = 0;      /// rectangle, hexagon, slot: the turn of its first side; teardrop: where the point
                           /// is; notched circle: where the notch is
    size_t sides;          /// polygon: how many

    /// One line: "rectangle 10 × 19, centre (−7.75, 1.85)".
    string toString() const
    {
        immutable c = pt(center);
        switch (kind)
        {
        case "circle": return format("circle ⌀%s, centre %s", mm(a), c);
        case "notched circle":
            return format("circle ⌀%s with a notch r %s towards %s° (for printing), centre %s", mm(a), mm(r),
                mm(angle * 180 / PI), c);
        case "rectangle":
            return format("rectangle %s × %s, centre %s%s", mm(a), mm(b), c, turned);
        case "rounded rectangle":
            return format("rounded rectangle %s × %s, corners r %s, centre %s%s", mm(a), mm(b), mm(r), c, turned);
        case "hexagon": return format("hexagon %s across flats, centre %s%s", mm(a), c, turned);
        case "teardrop": return format("teardrop ⌀%s, point towards %s°, centre %s", mm(a), mm(angle * 180 / PI), c);
        case "slot": return format("slot %s long, %s wide, centre %s%s", mm(a), mm(b), c, turned);
        case "D": return format("D ⌀%s, the flat %s from the centre, centre %s", mm(a), mm(r), c);
        case "polygon": return format("polygon of %d sides, centre %s, %s × %s", sides, c, mm(a), mm(b));
        default: return format("outline, centre %s, %s × %s", c, mm(a), mm(b));
        }
    }

    private string turned() const
    {
        immutable deg = angle * 180 / PI;
        return abs(deg) < 0.05 ? "" : format(", turned %s°", mm(deg));
    }

    /// The same shape, within `tol` (for following it along an axis).
    bool same(const Shape o, double tol) const
    {
        return kind == o.kind && abs(a - o.a) < tol && abs(b - o.b) < tol && abs(r - o.r) < tol
            && dist(center, o.center) < tol && sides == o.sides;
    }
}

/// The shape of a fitted outline.
Shape classify(const Element[] e)
{
    Shape s;
    // the box around its points, and its middle
    double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    void grow(P2 p)
    {
        x0 = min(x0, p[0]);
        x1 = max(x1, p[0]);
        y0 = min(y0, p[1]);
        y1 = max(y1, p[1]);
    }
    foreach (x; e)
    {
        grow(x.from);
        if (x.arc)
        {
            // the arc's extreme points
            foreach (k; 0 .. 4)
            {
                immutable ang = PI / 2 * k;
                immutable a0 = atan2(x.from[1] - x.center[1], x.from[0] - x.center[0]);
                double d = ang - a0;
                while (x.sweep > 0 && d < 0) d += 2 * PI;
                while (x.sweep < 0 && d > 0) d -= 2 * PI;
                if (abs(d) <= abs(x.sweep) + 1e-9)
                    grow([x.center[0] + x.radius * cos(ang), x.center[1] + x.radius * sin(ang)]);
            }
        }
    }
    s.center = [(x0 + x1) / 2, (y0 + y1) / 2];
    s.a = x1 - x0;
    s.b = y1 - y0;
    s.kind = "outline";
    size_t lines, arcs;
    foreach (x; e)
        (x.arc ? arcs : lines)++;
    if (e.length == 1 && e[0].circle)
    {
        s.kind = "circle";
        s.center = e[0].center;
        s.a = 2 * e[0].radius;
        return s;
    }
    // turns between consecutive lines (degrees), for polygons
    double turnAt(size_t i)
    {
        auto p = e[i], q = e[(i + 1) % e.length];
        return turn(p.from, p.to, q.to) * 180 / PI;
    }
    if (arcs == 0 && lines >= 3)
    {
        bool allTurn(double deg)
        {
            foreach (i; 0 .. e.length)
                if (abs(abs(turnAt(i)) - deg) > 1.5)
                    return false;
            return true;
        }
        s.sides = lines;
        s.kind = "polygon";
        if (lines == 4 && allTurn(90) && abs(e[0].length - e[2].length) < 0.02 && abs(e[1].length - e[3].length) < 0.02)
        {
            s.kind = "rectangle";
            s.angle = atan2(e[0].to[1] - e[0].from[1], e[0].to[0] - e[0].from[0]);
            // sides along the axes when it is not turned: width along x
            s.a = e[0].length;
            s.b = e[1].length;
            normalise(s);
        }
        else if (lines == 6 && allTurn(60))
        {
            double side = 0;
            foreach (x; e)
                side += x.length;
            side /= 6;
            s.kind = "hexagon";
            s.a = side * sqrt(3.0);
            s.angle = atan2(e[0].to[1] - e[0].from[1], e[0].to[0] - e[0].from[0]);
        }
        return s;
    }
    // a rounded rectangle: four lines and four quarter arcs of one radius
    if (lines == 4 && arcs == 4)
    {
        bool ok = true;
        double rr = -1;
        Element[] ls;
        foreach (x; e)
        {
            if (x.arc)
            {
                if (abs(abs(x.sweep) - PI / 2) > 0.03 || (rr >= 0 && abs(x.radius - rr) > 0.02))
                    ok = false;
                rr = x.radius;
            }
            else
                ls ~= x;
        }
        if (ok)
        {
            s.kind = "rounded rectangle";
            s.r = rr;
            s.angle = atan2(ls[0].to[1] - ls[0].from[1], ls[0].to[0] - ls[0].from[0]);
            s.a = ls[0].length + 2 * rr;
            s.b = ls[1].length + 2 * rr;
            normalise(s);
            return s;
        }
    }
    // a slot: two half circles of one radius and two lines
    if (lines == 2 && arcs == 2)
    {
        Element[] as, ls;
        foreach (x; e)
            (x.arc ? as : ls) ~= x;
        if (abs(abs(as[0].sweep) - PI) < 0.05 && abs(abs(as[1].sweep) - PI) < 0.05 && abs(as[0].radius - as[1].radius) < 0.02)
        {
            s.kind = "slot";
            s.a = dist(as[0].center, as[1].center) + 2 * as[0].radius;
            s.b = 2 * as[0].radius;
            s.angle = atan2(as[1].center[1] - as[0].center[1], as[1].center[0] - as[0].center[0]);
            s.center = [(as[0].center[0] + as[1].center[0]) / 2, (as[0].center[1] + as[1].center[1]) / 2];
            return s;
        }
    }
    // a circle with a small notch on its edge (a printing notch, a keyhole): arcs of one circle around most of
    // it (300° or more), and a few short pieces near its edge, the notch's round end the widest small arc
    {
        double R = 0;
        foreach (x; e)
            if (x.arc)
                R = max(R, x.radius);
        double around = 0;
        P2 c;
        foreach (x; e)
            if (x.arc && abs(x.radius - R) < 0.01 * R + 1e-3)
            {
                around += abs(x.sweep);
                c = x.center;
            }
        bool small = true;
        double sweep = 0, notchR = 0;
        P2 nc;
        foreach (x; e)
        {
            if (x.arc && abs(x.radius - R) < 0.01 * R + 1e-3 && dist(x.center, c) < 0.01 * R + 1e-3)
                continue;
            // the rest: short, and near the circle's edge
            if (dist(x.from, x.to) > R || dist(x.from, c) > 1.6 * R || dist(x.to, c) > 1.6 * R
                || (x.arc && x.radius > 0.6 * R))
                small = false;
            else if (x.arc && abs(x.sweep) > sweep)
            {
                sweep = abs(x.sweep);
                notchR = x.radius;
                nc = x.center;
            }
        }
        if (R > 0 && around > 300 * PI / 180 && small && sweep > PI / 2)
        {
            s.kind = "notched circle";
            s.center = c;
            s.a = 2 * R;
            s.r = notchR;
            s.angle = atan2(nc[1] - c[1], nc[0] - c[0]);
            return s;
        }
    }
    // a teardrop: one big arc (230° or more) and two lines to a point (perhaps cut by a small arc or flat)
    {
        size_t big = size_t.max;
        foreach (i, x; e)
            if (x.arc && abs(x.sweep) > 230 * PI / 180)
                big = i;
        if (big != size_t.max && e.length <= 5)
        {
            auto c = e[big].center;
            // the point: the farthest corner from the centre
            P2 tip = e[big].from;
            foreach (x; e)
                foreach (p; [x.from, x.to])
                    if (dist(p, c) > dist(tip, c))
                        tip = p;
            if (dist(tip, c) > e[big].radius * 1.05 || e.length >= 3)
            {
                s.kind = "teardrop";
                s.center = c;
                s.a = 2 * e[big].radius;
                // the point's direction: the middle of the part the arc leaves out
                immutable a0 = atan2(e[big].to[1] - c[1], e[big].to[0] - c[0]);
                immutable a1 = atan2(e[big].from[1] - c[1], e[big].from[0] - c[0]);
                double mid = (a0 + a1) / 2;
                // the gap is the short way between the arc's ends
                if (abs(a0 - a1) > PI)
                    mid += PI;
                s.angle = atan2(sin(mid), cos(mid));
                return s;
            }
        }
    }
    // a D: one arc and one line
    if (e.length == 2 && arcs == 1)
    {
        auto x = e[0].arc ? e[0] : e[1];
        auto l = e[0].arc ? e[1] : e[0];
        s.kind = "D";
        s.center = x.center;
        s.a = 2 * x.radius;
        s.r = pointLine(x.center, l.from, l.to);
        return s;
    }
    s.sides = e.length;
    return s;
}

/// A rectangle given by its first side: as width along x and height along y when it lies along the
/// axes, the turn otherwise between -45° and 45°.
private void normalise(ref Shape s)
{
    double a = s.angle;
    while (a > PI / 4) { a -= PI / 2; immutable t = s.a; s.a = s.b; s.b = t; }
    while (a < -PI / 4) { a += PI / 2; immutable t = s.a; s.a = s.b; s.b = t; }
    s.angle = abs(a) < 1e-6 ? 0 : a;
}

unittest
{
    // a rectangle, a hexagon, a teardrop, read from their outlines
    P2[] rect = [[0, 0], [10, 0], [10, 19], [0, 19]];
    auto r = classify(fit(rect, 0.01));
    assert(r.kind == "rectangle" && abs(r.a - 10) < 1e-9 && abs(r.b - 19) < 1e-9 && abs(r.center[0] - 5) < 1e-9, r.toString);
    P2[] hex;
    foreach (i; 0 .. 6)
        hex ~= [4 * cos(PI / 3 * i), 4 * sin(PI / 3 * i)];
    auto h = classify(fit(hex, 0.01));
    assert(h.kind == "hexagon" && abs(h.a - 4 * sqrt(3.0)) < 1e-9, h.toString);
    // a teardrop ⌀4 with its point up (+Y): an arc of 270° and two 45° sides
    P2[] drop;
    foreach (i; 0 .. 37)
    {
        immutable ang = PI / 4 + PI / 2 + 1.5 * PI * i / 36;
        drop ~= [2 * cos(ang), 2 * sin(ang)];
    }
    drop ~= [0, 2 * sqrt(2.0)];
    auto t = classify(fit(drop, 0.01));
    assert(t.kind == "teardrop" && abs(t.a - 4) < 1e-6 && abs(t.angle - PI / 2) < 0.05, t.toString);
}

/// The outlines of a mesh's shadow on the plane of `u` and `v`: every
/// triangle drawn on a grid of `pixel` mm, and the edges of what it covers
/// traced (marching squares, the corners at the middles of the pixels'
/// sides), outside loops counter-clockwise, holes clockwise.
P2[][] shadowLoops(const Mesh m, Vec3 u, Vec3 v, double pixel)
{
    import std.math : floor, ceil;
    double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    foreach (i; 0 .. m.vertexCount)
    {
        auto p = m.vertex(i);
        x0 = min(x0, p.dot(u));
        x1 = max(x1, p.dot(u));
        y0 = min(y0, p.dot(v));
        y1 = max(y1, p.dot(v));
    }
    // a pixel of margin all around: the outlines close inside the grid
    x0 -= 2 * pixel;
    y0 -= 2 * pixel;
    immutable nx = cast(size_t) ceil((x1 - x0) / pixel) + 3, ny = cast(size_t) ceil((y1 - y0) / pixel) + 3;
    auto mask = new bool[nx * ny];
    // pixel (i, j) covers the square from x0 + i·pixel; its centre half a pixel in
    foreach (t; 0 .. m.triangleCount)
    {
        P2[3] p;
        foreach (k; 0 .. 3)
        {
            auto q = m.vertex(m.tris[3 * t + k]);
            p[k] = [(q.dot(u) - x0) / pixel - 0.5, (q.dot(v) - y0) / pixel - 0.5];
        }
        immutable den = (p[1][1] - p[2][1]) * (p[0][0] - p[2][0]) + (p[2][0] - p[1][0]) * (p[0][1] - p[2][1]);
        if (abs(den) < 1e-12)
            continue;
        immutable i0 = cast(long) ceil(min(p[0][0], p[1][0], p[2][0])), i1 = cast(long) floor(max(p[0][0], p[1][0], p[2][0]));
        immutable j0 = cast(long) ceil(min(p[0][1], p[1][1], p[2][1])), j1 = cast(long) floor(max(p[0][1], p[1][1], p[2][1]));
        foreach (j; max(0, j0) .. min(cast(long) ny - 1, j1) + 1)
            foreach (i; max(0, i0) .. min(cast(long) nx - 1, i1) + 1)
            {
                immutable w0 = ((p[1][1] - p[2][1]) * (i - p[2][0]) + (p[2][0] - p[1][0]) * (j - p[2][1])) / den;
                immutable w1 = ((p[2][1] - p[0][1]) * (i - p[2][0]) + (p[0][0] - p[2][0]) * (j - p[2][1])) / den;
                if (w0 >= -1e-9 && w1 >= -1e-9 && 1 - w0 - w1 >= -1e-9)
                    mask[j * nx + i] = true;
            }
    }
    bool at(long i, long j) => i >= 0 && j >= 0 && i < nx && j < ny && mask[j * nx + i];
    // the boundary as directed edges between pixel corners, the covered pixels on their left;
    // corners numbered (i, j) at x0 + i·pixel, y0 + j·pixel
    alias Corner = long[2];
    Corner[Corner] next;
    foreach (j; -1 .. cast(long) ny)
        foreach (i; -1 .. cast(long) nx)
        {
            immutable here = at(i, j);
            // the edge between (i, j) and its right neighbour, and its upper one
            if (here != at(i + 1, j))
            {
                // vertical edge at x = i + 1, from y = j to j + 1
                if (here)
                    next[[i + 1, j]] = [i + 1, j + 1];
                else
                    next[[i + 1, j + 1]] = [i + 1, j];
            }
            if (here != at(i, j + 1))
            {
                // horizontal edge at y = j + 1, from x = i to i + 1
                if (here)
                    next[[i + 1, j + 1]] = [i, j + 1];
                else
                    next[[i, j + 1]] = [i + 1, j + 1];
            }
        }
    P2[][] loops;
    bool[Corner] used;
    foreach (start, _; next)
    {
        if (start in used)
            continue;
        Corner[] cs;
        Corner c = start;
        while (c !in used)
        {
            used[c] = true;
            cs ~= c;
            auto nx_ = c in next;
            if (nx_ is null)
                break;
            c = *nx_;
        }
        if (cs.length < 4)
            continue;
        // the middles of the edges: a smoother outline than the pixel corners
        P2[] loop;
        foreach (k; 0 .. cs.length)
        {
            auto a = cs[k], b = cs[(k + 1) % cs.length];
            loop ~= [x0 + (a[0] + b[0]) / 2.0 * pixel, y0 + (a[1] + b[1]) / 2.0 * pixel];
        }
        loops ~= loop;
    }
    return loops;
}

/// fit for an outline traced on a grid: its pixel steps first smoothed away
/// (Douglas–Peucker within half the tolerance), then lines and arcs as fit
/// finds them, with no rule on the pieces' directions and lengths.
private Element[] fitTraced(const P2[] input, double tol)
{
    // a loop simplified: the farthest point from the chord kept while it is farther than eps
    P2[] simplify(const P2[] pts, double eps)
    {
        if (pts.length < 3)
            return pts.dup;
        size_t far;
        double best = 0;
        foreach (k; 1 .. pts.length - 1)
        {
            immutable d = pointLine(pts[k], pts[0], pts[$ - 1]);
            if (d > best)
            {
                best = d;
                far = k;
            }
        }
        if (best <= eps)
            return [pts[0], pts[$ - 1]];
        auto a = simplify(pts[0 .. far + 1], eps), b = simplify(pts[far .. $], eps);
        return a[0 .. $ - 1] ~ b;
    }
    // split the loop at its two farthest-apart points, each half simplified
    size_t far;
    double best = 0;
    foreach (k; 1 .. input.length)
        if (dist(input[0], input[k]) > best)
        {
            best = dist(input[0], input[k]);
            far = k;
        }
    auto half1 = simplify(input[0 .. far + 1], 0.5 * tol), half2 = simplify(input[far .. $] ~ input[0], 0.5 * tol);
    auto loop = half1[0 .. $ - 1] ~ half2[0 .. $ - 1];
    if (loop.length < 3)
        return null;
    immutable n = loop.length;
    P2 at(size_t i) => loop[i % n];
    {
        P2 c;
        double r, worst;
        if (circleFit(input, c, r, worst) && worst < tol)
            return [Element(true, input[0], input[0], c, r, area(input) > 0 ? 2 * PI : -2 * PI, true)];
    }
    // start at the longest piece: a straight side, never inside an arc
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
        size_t lineEnd = i + 1;
        while (lineEnd + 1 <= n && collinear(loop, start, i, lineEnd + 1, tol, true))
            lineEnd++;
        size_t arcEnd = i;
        P2 ac;
        double ar = 0;
        // an arc: at least six points (three always lie on some circle: a corner would pass), each
        // piece short against the radius
        for (size_t j = i + 3; j <= n; j++)
        {
            P2[] pts;
            foreach (k; i .. j + 1)
                pts ~= at(start + k);
            P2 c;
            double r, worst;
            if (!circleFit(pts, c, r, worst) || worst > tol || r > 200 * tol + 50)
                break;
            bool short_ = true;
            foreach (k; 0 .. pts.length - 1)
                if (dist(pts[k], pts[k + 1]) > 0.77 * r)
                    short_ = false;
            if (!short_)
                break;
            if (j >= i + 5)
            {
                arcEnd = j;
                ac = c;
                ar = r;
            }
        }
        auto a = at(start + i);
        if (arcEnd > lineEnd + 1)
        {
            auto b = at(start + arcEnd);
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
    return out_;
}

unittest
{
    // the shadow of a 10 × 6 rectangle seen from above, traced on a grid: four sides of the right size
    Mesh m;
    m.verts = [0, 0, 0, 10, 0, 0, 10, 6, 0, 0, 6, 0];
    m.tris = [0, 1, 2, 0, 2, 3];
    auto loops = shadowLoops(m, Vec3(1, 0, 0), Vec3(0, 1, 0), 0.05);
    assert(loops.length == 1);
    auto e = fit(loops[0], 0.075, true);
    auto s = classify(e);
    assert(s.kind == "rectangle" && abs(s.a - 10) < 0.06 && abs(s.b - 6) < 0.06, s.toString);
}

unittest
{
    // a 10 mm cube with one side triangle turned the wrong way (as a sliver mended badly would be): the cut
    // across it is still one closed outline, counter-clockwise, 100 mm²
    Mesh m;
    foreach (k; 0 .. 8)
        m.verts ~= [k & 1 ? 10.0f : 0, k & 2 ? 10.0f : 0, k & 4 ? 10.0f : 0];
    m.tris = [0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6, 0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3, 0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5];
    // the first triangle of the side x = 10 reversed
    m.tris[30 .. 33] = [1, 7, 3];
    auto loops = slice(m, Vec3(0, 0, 1), 5, Vec3(1, 0, 0), Vec3(0, 1, 0));
    assert(loops.length == 1, format("%d outlines", loops.length));
    assert(abs(area(loops[0]) - 100) < 1e-6, format("area %s", area(loops[0])));
}

unittest
{
    // a hole ⌀3.3 with a notch r 0.5 on top (as printed parts have): a circle, notched upwards; not a teardrop
    P2[] o;
    immutable R = 1.65, nr = 0.5;
    // the circle from just right of the notch round to just left of it, then the notch's sides and round top
    immutable gap = asin(nr / R);
    foreach (i; 0 .. 61)
    {
        immutable ang = PI / 2 + gap + (2 * PI - 2 * gap) * i / 60;
        o ~= [R * cos(ang), R * sin(ang)];
    }
    immutable top = 1.65 + 0.2;
    o ~= [nr, top];
    foreach (i; 1 .. 12)
    {
        immutable ang = PI * i / 12;
        o ~= [nr * cos(ang), top + nr * sin(ang)];
    }
    o ~= [-nr, top];
    auto sh = classify(fit(o, 0.005));
    assert(sh.kind == "notched circle", sh.toString ~ "\n" ~ describe([fit(o, 0.005)]));
    assert(abs(sh.a - 3.3) < 0.01 && abs(sh.r - 0.5) < 0.02 && abs(sh.angle - PI / 2) < 0.05, sh.toString);
}
