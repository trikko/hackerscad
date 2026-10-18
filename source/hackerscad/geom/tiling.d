/// Tilings of the plane: the motifs of the regular ones (one or more convex
/// polygons repeated on a lattice of two steps), convex polygons shrunk to
/// leave a wall between neighbours, and Voronoi cells round scattered points.
module hackerscad.geom.tiling;

import std.math : PI, abs, cos, floor, sin, sqrt;

/// A polygon on the plane: x, y of each corner in turn, counter-clockwise.
alias Poly = double[2][];

/// What a lattice tiling repeats: its polygons, round the lattice point at the
/// origin, and the two steps of the lattice.
struct Motif
{
    Poly[] polys;
    double[2] a, b;
}

/// The names of the regular tilings `motif` knows.
immutable string[] tilingKinds = ["square", "hex", "triangle", "brick", "octagon", "diamond"];

/// The motif of a regular tiling, `size` the distance between neighbouring
/// cells' centres (a square's side, a hexagon across its flats, a
/// triangle's side, a brick's height); false for an unknown kind.
bool motif(string kind, double size, out Motif m)
{
    immutable s = size, r3 = sqrt(3.0);
    switch (kind)
    {
    case "square":
        m = Motif([square(s)], [s, 0], [0, s]);
        return true;
    case "diamond":
        // squares stood on a corner, `size` their side
        m = Motif([regular(4, s / sqrt(2.0), 0)], [s / sqrt(2.0), s / sqrt(2.0)], [-s / sqrt(2.0), s / sqrt(2.0)]);
        return true;
    case "hex":
        // pointed up: neighbours to the sides and at 60°
        m = Motif([regular(6, s / r3, PI / 6)], [s, 0], [s / 2, s * r3 / 2]);
        return true;
    case "triangle":
        {
            // one pointing up, one down, in each rhombus of the lattice
            immutable h = s * r3 / 2;
            Poly up = [[-s / 2, -h / 3], [s / 2, -h / 3], [0, 2 * h / 3]];
            Poly down = [[0, 2 * h / 3], [s / 2, -h / 3], [s, 2 * h / 3]];
            m = Motif([up, down], [s, 0], [s / 2, h]);
            return true;
        }
    case "brick":
        m = Motif([rectangle(2 * s, s)], [2 * s, 0], [s, s]);
        return true;
    case "octagon":
        {
            // octagons across their flats `size`, small squares in the gaps
            immutable t = s / (1 + sqrt(2.0));
            Poly small = regular(4, t / sqrt(2.0), 0);
            foreach (ref p; small)
                p = [p[0] + s / 2, p[1] + s / 2];
            m = Motif([regular(8, s / 2 / cos(PI / 8), PI / 8), small], [s, 0], [0, s]);
            return true;
        }
    default:
        return false;
    }
}

/// A convex polygon with every side moved in by `d`: what is left of it, or
/// nothing when it vanishes.
Poly shrinkConvex(Poly p, double d)
{
    if (d <= 0)
        return p;
    auto out_ = p.dup;
    foreach (i; 0 .. p.length)
    {
        immutable q = p[i], r = p[(i + 1) % p.length];
        immutable ex = r[0] - q[0], ey = r[1] - q[1], len = sqrt(ex * ex + ey * ey);
        if (len < 1e-12)
            continue;
        // inward normal of a counter-clockwise side: (-ey, ex)
        immutable nx = -ey / len, ny = ex / len;
        out_ = clip(out_, nx, ny, nx * q[0] + ny * q[1] + d);
        if (out_.length < 3)
            return null;
    }
    return out_;
}

/// The area of a polygon, positive counter-clockwise.
double area(Poly p)
{
    double a = 0;
    foreach (i; 0 .. p.length)
    {
        immutable q = p[i], r = p[(i + 1) % p.length];
        a += q[0] * r[1] - r[0] * q[1];
    }
    return a / 2;
}

/// Its centroid.
double[2] centroid(Poly p)
{
    double cx = 0, cy = 0, a = 0;
    foreach (i; 0 .. p.length)
    {
        immutable q = p[i], r = p[(i + 1) % p.length];
        immutable c = q[0] * r[1] - r[0] * q[1];
        a += c;
        cx += (q[0] + r[0]) * c;
        cy += (q[1] + r[1]) * c;
    }
    return abs(a) < 1e-15 ? p[0] : [cx / (3 * a), cy / (3 * a)];
}

/// The Voronoi cells of `sites` within the box (x0, y0)–(x1, y1): each the
/// part of the plane nearer its site than any other, its sides moved in by
/// `wall`/2 so that neighbours stand `wall` apart. Cells too small to keep
/// are empty.
Poly[] voronoi(const double[2][] sites, double x0, double y0, double x1, double y1, double wall)
{
    // sites bucketed in squares about the mean spacing, to find neighbours
    immutable n = sites.length;
    Poly[] cells = new Poly[n];
    if (n == 0)
        return cells;
    immutable spacing = sqrt((x1 - x0) * (y1 - y0) / n), cell = spacing > 1e-9 ? spacing : 1;
    immutable cols = cast(long)((x1 - x0) / cell) + 1, rows = cast(long)((y1 - y0) / cell) + 1;
    size_t[][] buckets = new size_t[][cast(size_t)(cols * rows)];
    long bx(double x) => clampL(cast(long) floor((x - x0) / cell), 0, cols - 1);
    long by(double y) => clampL(cast(long) floor((y - y0) / cell), 0, rows - 1);
    foreach (i, s; sites)
        buckets[cast(size_t)(by(s[1]) * cols + bx(s[0]))] ~= i;
    foreach (i, s; sites)
    {
        Poly c = [[x0, y0], [x1, y0], [x1, y1], [x0, y1]];
        // rings of buckets outwards, until no site farther can cut the cell
        for (long ring = 0; ; ring++)
        {
            immutable cx = bx(s[0]), cy = by(s[1]);
            bool any = false;
            foreach (yy; cy - ring .. cy + ring + 1)
                foreach (xx; cx - ring .. cx + ring + 1)
                {
                    if (yy < 0 || yy >= rows || xx < 0 || xx >= cols)
                        continue;
                    if (abs(yy - cy) != ring && abs(xx - cx) != ring)
                        continue;
                    any = true;
                    foreach (j; buckets[cast(size_t)(yy * cols + xx)])
                    {
                        if (j == i)
                            continue;
                        // nearer s than sites[j], wall/2 in from the bisector
                        immutable dx = sites[j][0] - s[0], dy = sites[j][1] - s[1], d = sqrt(dx * dx + dy * dy);
                        if (d < 1e-12)
                            continue;
                        immutable nx = -dx / d, ny = -dy / d;
                        c = clip(c, nx, ny, nx * (s[0] + dx / 2) + ny * (s[1] + dy / 2) + wall / 2);
                        if (c.length < 3)
                            break;
                    }
                    if (c.length < 3)
                        break;
                }
            if (c.length < 3 || !any)
                break;
            // a site beyond this ring is at least `ring` buckets away: it cannot
            // cut a cell whose corners all lie nearer than half that
            double far = 0;
            foreach (q; c)
                far = maxD(far, sqrt((q[0] - s[0]) ^^ 2 + (q[1] - s[1]) ^^ 2));
            if (2 * far < ring * cell)
                break;
        }
        cells[i] = c.length >= 3 ? c : null;
    }
    return cells;
}

/// Points scattered over the box about `spacing` apart: a grid of hexagons'
/// centres, each moved at random by up to `jitter` (0…1) of the spacing, then
/// `relax` times moved to the centre of its cell (evener cells).
double[2][] scatter(double x0, double y0, double x1, double y1, double spacing, double jitter, int relax,
    long seed)
{
    double[2][] pts;
    ulong state = cast(ulong) seed * 0x9E3779B97F4A7C15UL + 0x2545F4914F6CDD1DUL;
    double next()
    {
        state += 0x9E3779B97F4A7C15UL;
        ulong z = state;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
        z ^= z >> 31;
        return (z >> 11) * (1.0 / (1UL << 53));
    }
    immutable rowStep = spacing * sqrt(3.0) / 2;
    long row = 0;
    for (double y = y0; y <= y1; y += rowStep, row++)
        for (double x = x0 + (row % 2 ? spacing / 2 : 0); x <= x1; x += spacing)
        {
            immutable px = x + (next() - 0.5) * jitter * spacing, py = y + (next() - 0.5) * jitter * spacing;
            pts ~= [clampD(px, x0, x1), clampD(py, y0, y1)];
        }
    foreach (k; 0 .. relax)
    {
        auto cells = voronoi(pts, x0, y0, x1, y1, 0);
        foreach (i, c; cells)
            if (c.length >= 3)
                pts[i] = centroid(c);
    }
    return pts;
}

private:

Poly square(double s) => rectangle(s, s);

Poly rectangle(double w, double h) => [[-w / 2, -h / 2], [w / 2, -h / 2], [w / 2, h / 2], [-w / 2, h / 2]];

/// A regular n-gon, its corners `r` from the origin, the first at `start`.
Poly regular(int n, double r, double start)
{
    Poly p;
    foreach (i; 0 .. n)
        p ~= [r * cos(start + 2 * PI * i / n), r * sin(start + 2 * PI * i / n)];
    return p;
}

/// The part of `p` where nx·x + ny·y >= c.
Poly clip(Poly p, double nx, double ny, double c)
{
    Poly r;
    foreach (i; 0 .. p.length)
    {
        immutable q = p[i], s = p[(i + 1) % p.length];
        immutable dq = nx * q[0] + ny * q[1] - c, ds = nx * s[0] + ny * s[1] - c;
        if (dq >= 0)
            r ~= q;
        if ((dq >= 0) != (ds >= 0))
        {
            immutable t = dq / (dq - ds);
            r ~= [q[0] + (s[0] - q[0]) * t, q[1] + (s[1] - q[1]) * t];
        }
    }
    return r;
}

long clampL(long v, long lo, long hi) => v < lo ? lo : v > hi ? hi : v;
double clampD(double v, double lo, double hi) => v < lo ? lo : v > hi ? hi : v;
double maxD(double a, double b) => a > b ? a : b;

unittest
{
    // the motifs tile: their area is the lattice cell's
    foreach (kind; tilingKinds)
    {
        Motif m;
        assert(motif(kind, 10, m));
        double a = 0;
        foreach (p; m.polys)
            a += area(p);
        assert(abs(a - abs(m.a[0] * m.b[1] - m.a[1] * m.b[0])) < 1e-9, kind);
    }
    // a 10 mm square shrunk by 1: 8 mm
    assert(abs(area(shrinkConvex(square(10), 1)) - 64) < 1e-9);
    assert(shrinkConvex(square(10), 6) is null);
    // Voronoi of a regular grid: squares; the wall between them
    double[2][] g;
    foreach (j; 0 .. 4)
        foreach (i; 0 .. 4)
            g ~= [i * 10.0 + 5, j * 10.0 + 5];
    auto cells = voronoi(g, 0, 0, 40, 40, 2);
    assert(abs(area(cells[5]) - 64) < 1e-9 && abs(area(cells[0]) - 81) < 1e-9);
    // scattered points cover the box, the cells add up to it
    auto pts = scatter(0, 0, 100, 60, 10, 1, 2, 7);
    double total = 0;
    foreach (c; voronoi(pts, 0, 0, 100, 60, 0))
        total += area(c);
    assert(abs(total - 6000) < 1e-6);
}
