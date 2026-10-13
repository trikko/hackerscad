/// Where the drawings of two solids differ: both drawn as lines (their sharp
/// edges and their outlines, hidden lines removed) from many directions
/// around them, the lines one has and the other has not found in each view,
/// taken back to where they are on the part and grouped. A chamfer, a
/// countersink, a notch or a lettering is a fraction of a millimetre of
/// surface but a long line in a drawing: what the eye sees first.
module hackerscad.render.linediff;

import std.algorithm : max, min, sort;
import std.math : abs, ceil, cos, floor, sin, sqrt, PI;

import hackerscad.geom.mesh;
import hackerscad.geom.vec;
import hackerscad.render.raster : Image;

/// A direction to look from, in degrees: the azimuth around z (0 from the
/// front, -y; 90 from the right, +x) and the elevation (90 from above).
struct Direction
{
    double azimuth = 0, elevation = 0;
    /// Peeled: how deep (mm, from the nearest point) the parts are cut away on the viewer's side, to
    /// see the lines inside; 0 the whole parts.
    double depth = 0;

    /// From the part towards the viewer.
    Vec3 eye() const
    {
        immutable a = azimuth * PI / 180, e = elevation * PI / 180;
        return Vec3(sin(a) * cos(e), -cos(a) * cos(e), sin(e));
    }

    string toString() const
    {
        import std.format : format;
        immutable cut = depth > 0 ? format(", the nearest %g mm cut away", depth) : "";
        if (elevation >= 89.9)
            return "top" ~ cut;
        if (elevation <= -89.9)
            return "bottom" ~ cut;
        return format("azimuth %g°, elevation %g°", azimuth, elevation) ~ cut;
    }
}

/// Rings around the part, every 30° of azimuth at elevations -60 to 60
/// (every other ring turned by 15°), and the views from above and below;
/// with `depth`, the millimetres cut away on the viewer's side in each (the
/// onion peeled).
Direction[] orbit(double depth = 0)
{
    Direction[] r;
    foreach (ring, el; [-60.0, -30, 0, 30, 60])
        foreach (k; 0 .. 12)
            r ~= Direction(k * 30.0 + (ring % 2 ? 15 : 0), el, depth);
    r ~= Direction(0, 90, depth);
    r ~= Direction(0, -90, depth);
    return r;
}

/// A group of lines one part has and the other has not.
struct Stroke
{
    bool missing;      /// a line of b (the original) that a lacks; else a line of a that b has not
    Vec3 lo, hi;       /// its box on the part
    double length = 0; /// mm, about
    size_t[] seenFrom; /// the directions (indices) that show it
}

/// The drawings compared from each direction.
struct LineDiff
{
    Direction[] directions;
    size_t[] differing;  /// per direction: how many pixels of lines differ
    Image[] pictures;    /// per direction: common lines grey, b's only red, a's only blue
    Stroke[] strokes;    /// most seen and longest first
    double tolerance;    /// mm: lines nearer than this in a picture count as the same
}

/// Compares the drawings of `a` (a copy) and `b` (the original) from each
/// direction, in pictures `size` pixels wide.
LineDiff lineDiff(const Mesh a, const Mesh b, const Direction[] directions, uint size = 300)
{
    enum ss = 2;   // drawn at twice the size: thinner lines, finer comparison
    immutable n = size * ss;
    auto ea = Lines(a), eb = Lines(b);
    LineDiff r;
    r.directions = directions.dup;

    // the cells of a grid on the part where differing lines fall, each with the views that see it
    double diag = 0;
    {
        Vec3 lo = Vec3(double.infinity, double.infinity, double.infinity), hi = -lo;
        foreach (m; [&ea.mesh, &eb.mesh])
            foreach (i; 0 .. m.vertexCount)
            {
                auto p = m.vertex(i);
                lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z));
                hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z));
            }
        diag = (hi - lo).length;
    }
    immutable g = max(0.4, diag / 250);
    // per kind (0 missing, 1 extra): cell key → the views that see a differing line in it, as bits
    immutable words = (directions.length + 63) / 64;
    ulong[][long][2] cells;
    void mark(int kind, long c, size_t vi)
    {
        auto bits = c in cells[kind];
        if (bits is null)
        {
            cells[kind][c] = new ulong[words];
            bits = c in cells[kind];
        }
        (*bits)[vi / 64] |= 1UL << (vi % 64);
    }
    long key(Vec3 p) => (cast(long) floor(p.x / g) + (1L << 20)) | ((cast(long) floor(p.y / g) + (1L << 20)) << 21)
        | ((cast(long) floor(p.z / g) + (1L << 20)) << 42);

    foreach (vi, d; directions)
    {
        auto cam = Camera(d.eye);
        // one frame for both, so that their pictures lie on each other
        double x0 = double.max, y0 = double.max, x1 = -double.max, y1 = -double.max, z0 = double.max, z1 = -double.max;
        foreach (m; [&ea.mesh, &eb.mesh])
            foreach (i; 0 .. m.vertexCount)
            {
                auto p = cam.project(m.vertex(i));
                x0 = min(x0, p.x), x1 = max(x1, p.x), y0 = min(y0, p.y), y1 = max(y1, p.y);
                z0 = min(z0, p.z), z1 = max(z1, p.z);
            }
        immutable k = n * 0.9 / max(x1 - x0, y1 - y0, 1e-9);
        immutable ox = n / 2.0 - k * (x0 + x1) / 2, oy = n / 2.0 + k * (y0 + y1) / 2;
        Vec3 toScreen(Vec3 p)
        {
            auto q = cam.project(p);
            return Vec3(ox + k * q.x, oy - k * q.y, q.z);
        }
        immutable tol = 0.004 * max(z1 - z0, 1e-6);
        immutable cut = d.depth > 0 ? z1 - d.depth : double.infinity;
        auto da = ea.draw(cam.eye, &toScreen, n, tol, cut), db = eb.draw(cam.eye, &toScreen, n, tol, cut);

        // lines farther than r pixels from any line of the other
        enum reach = 3 * ss / 2;
        r.tolerance = reach / k;
        auto onlyB = minus(db.line, grow(da.line, n, reach)), onlyA = minus(da.line, grow(db.line, n, reach));
        dropSpecks(onlyB, n, 6 * ss);
        dropSpecks(onlyA, n, 6 * ss);
        size_t count;
        foreach (q; 0 .. n * n)
        {
            if (onlyB[q])
                mark(0, key(db.at[q]), vi);
            if (onlyA[q])
                mark(1, key(da.at[q]), vi);
            count += onlyA[q] + onlyB[q];
        }
        r.differing ~= count / ss;

        // the picture: grey the lines in common, red and blue (thickened) what differs
        auto red = grow(onlyB, n, ss), blue = grow(onlyA, n, ss);
        auto img = Image(size, size, new ubyte[size * size * 3]);
        foreach (y; 0 .. size)
            foreach (x; 0 .. size)
            {
                bool rr, bb, gg;
                foreach (dy; 0 .. ss)
                    foreach (dx; 0 .. ss)
                    {
                        immutable q = (y * ss + dy) * n + x * ss + dx;
                        rr |= red[q];
                        bb |= blue[q];
                        gg |= da.line[q] || db.line[q];
                    }
                ubyte[3] c = rr ? [220, 30, 30] : bb ? [30, 90, 230] : gg ? [150, 150, 158] : [255, 255, 255];
                img.rgb[(y * size + x) * 3 .. (y * size + x) * 3 + 3] = c[];
            }
        r.pictures ~= img;
    }

    // the strokes: cells that touch, of one kind
    foreach (kind; 0 .. 2)
    {
        bool[long] done;
        foreach (c0, _; cells[kind])
        {
            if (c0 in done)
                continue;
            Stroke s;
            s.missing = kind == 0;
            s.lo = Vec3(double.infinity, double.infinity, double.infinity);
            s.hi = -s.lo;
            auto views = new ulong[words];
            size_t count;
            long[] stack = [c0];
            done[c0] = true;
            while (stack.length)
            {
                immutable c = stack[$ - 1];
                stack = stack[0 .. $ - 1];
                views[] |= cells[kind][c][];
                count++;
                immutable ix = (c & ((1L << 21) - 1)) - (1L << 20), iy = ((c >> 21) & ((1L << 21) - 1)) - (1L << 20),
                    iz = (c >> 42) - (1L << 20);
                s.lo = Vec3(min(s.lo.x, ix * g), min(s.lo.y, iy * g), min(s.lo.z, iz * g));
                s.hi = Vec3(max(s.hi.x, (ix + 1) * g), max(s.hi.y, (iy + 1) * g), max(s.hi.z, (iz + 1) * g));
                foreach (dz; -1 .. 2)
                    foreach (dy; -1 .. 2)
                        foreach (dx; -1 .. 2)
                        {
                            immutable o = c + dx + (cast(long) dy << 21) + (cast(long) dz << 42);
                            if (o in cells[kind] && o !in done)
                            {
                                done[o] = true;
                                stack ~= o;
                            }
                        }
            }
            foreach (vi; 0 .. directions.length)
                if (views[vi / 64] & (1UL << (vi % 64)))
                    s.seenFrom ~= vi;
            s.length = count * g;
            // a line seen from one direction only is often where two drawings part by a hair
            if (s.seenFrom.length >= 2 && s.length >= 4 * g)
                r.strokes ~= s;
        }
    }
    r.strokes.sort!((x, y) => x.seenFrom.length * x.length > y.seenFrom.length * y.length);
    return r;
}

/// The directions that between them show the most of the strokes: each
/// next one the view that adds the most length not shown yet.
size_t[] telling(const LineDiff d, size_t count)
{
    auto shown = new bool[d.strokes.length];
    size_t[] r;
    auto used = new bool[d.directions.length];
    foreach (_; 0 .. min(count, d.directions.length))
    {
        double best = -1;
        size_t pick;
        foreach (vi; 0 .. d.directions.length)
        {
            if (used[vi])
                continue;
            double gain = 0;
            foreach (si, s; d.strokes)
                if (!shown[si])
                    foreach (v; s.seenFrom)
                        if (v == vi)
                            gain += s.length;
            // ties (nothing left to show): the view with the most differing pixels
            gain = gain * 1e6 + d.differing[vi];
            if (gain > best)
            {
                best = gain;
                pick = vi;
            }
        }
        used[pick] = true;
        r ~= pick;
        foreach (si, s; d.strokes)
            foreach (v; s.seenFrom)
                if (v == pick)
                    shown[si] = true;
    }
    return r;
}

/// The pictures of the given directions in a grid, `columns` wide, a thin
/// grey frame around each.
Image sheet(const LineDiff d, const size_t[] which, uint columns = 4)
{
    if (which.length == 0)
        return Image(1, 1, [255, 255, 255]);
    immutable size = d.pictures[which[0]].width;
    immutable rows = cast(uint)((which.length + columns - 1) / columns);
    auto s = Image(size * columns, size * rows, new ubyte[size * columns * size * rows * 3]);
    s.rgb[] = 255;
    foreach (i, vi; which)
    {
        immutable cx = cast(uint)(i % columns) * size, cy = cast(uint)(i / columns) * size;
        auto p = d.pictures[vi];
        foreach (y; 0 .. size)
            foreach (x; 0 .. size)
            {
                immutable edge = x == 0 || y == 0 || x == size - 1 || y == size - 1;
                immutable q = ((cy + y) * s.width + cx + x) * 3;
                if (edge)
                    s.rgb[q .. q + 3] = [210, 210, 215];
                else
                    s.rgb[q .. q + 3] = p.rgb[(y * size + x) * 3 .. (y * size + x) * 3 + 3];
            }
    }
    return s;
}

private:

struct Camera
{
    Vec3 eye, right, up;

    this(Vec3 e)
    {
        eye = e.normalized;
        auto worldUp = abs(eye.z) > 0.99 ? Vec3(0, eye.z > 0 ? 1 : -1, 0) : Vec3(0, 0, 1);
        right = worldUp.cross(eye).normalized;
        up = eye.cross(right);
    }

    Vec3 project(Vec3 p) const => Vec3(p.dot(right), p.dot(up), p.dot(eye));
}

/// A drawing: which pixels are on a line, and where on the part each one is.
struct Drawn
{
    bool[] line;
    Vec3[] at;
}

/// A mesh's edges with the normals of the faces on each side: drawn when
/// sharp, or when one side faces the viewer and the other away (an outline).
struct Lines
{
    Mesh mesh;
    uint[2][] edges;
    Vec3[2][] normals;  // the second is nan on an open edge
    bool[] sharp;

    this(const Mesh m)
    {
        mesh = m.welded(1e-4);
        auto tn = new Vec3[mesh.triangleCount];
        foreach (t; 0 .. mesh.triangleCount)
        {
            auto p0 = mesh.vertex(mesh.tris[3 * t]), p1 = mesh.vertex(mesh.tris[3 * t + 1]),
                p2 = mesh.vertex(mesh.tris[3 * t + 2]);
            tn[t] = (p1 - p0).cross(p2 - p0).normalized;
        }
        size_t[ulong] seen;
        foreach (t; 0 .. mesh.triangleCount)
            foreach (c; 0 .. 3)
            {
                uint u = mesh.tris[3 * t + c], v = mesh.tris[3 * t + (c + 1) % 3];
                if (u > v)
                {
                    immutable w = u;
                    u = v;
                    v = w;
                }
                if (u == v)
                    continue;
                immutable kk = (cast(ulong) u << 32) | v;
                if (auto e = kk in seen)
                    normals[*e][1] = tn[t];
                else
                {
                    seen[kk] = edges.length;
                    edges ~= [u, v];
                    normals ~= [tn[t], Vec3(double.nan, double.nan, double.nan)];
                }
            }
        sharp = new bool[edges.length];
        immutable limit = cos(20 * PI / 180);
        foreach (i, nn; normals)
            sharp[i] = nn[1].x != nn[1].x || nn[0].dot(nn[1]) < limit;
    }

    /// Seen from `eye`, without what is nearer than `cut` (in the view's depth): there the section's
    /// outline is drawn.
    Drawn draw(Vec3 eye, scope Vec3 delegate(Vec3) toScreen, uint n, double tol, double cut = double.infinity) const
    {
        auto depth = new float[n * n];
        depth[] = -float.infinity;
        foreach (t; 0 .. mesh.triangleCount)
        {
            auto a = toScreen(mesh.vertex(mesh.tris[3 * t])), b = toScreen(mesh.vertex(mesh.tris[3 * t + 1])),
                c = toScreen(mesh.vertex(mesh.tris[3 * t + 2]));
            immutable area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
            if (abs(area) < 1e-12)
                continue;
            immutable xs = max(0, cast(int) floor(min(a.x, b.x, c.x))), xe = min(cast(int) n - 1, cast(int) ceil(max(a.x, b.x, c.x)));
            immutable ys = max(0, cast(int) floor(min(a.y, b.y, c.y))), ye = min(cast(int) n - 1, cast(int) ceil(max(a.y, b.y, c.y)));
            foreach (y; ys .. ye + 1)
                foreach (x; xs .. xe + 1)
                {
                    immutable px = x + 0.5, py = y + 0.5;
                    immutable w0 = ((b.x - px) * (c.y - py) - (b.y - py) * (c.x - px)) / area;
                    immutable w1 = ((c.x - px) * (a.y - py) - (c.y - py) * (a.x - px)) / area;
                    immutable w2 = 1 - w0 - w1;
                    if (w0 < 0 || w1 < 0 || w2 < 0)
                        continue;
                    immutable z = w0 * a.z + w1 * b.z + w2 * c.z;
                    if (z > depth[y * n + x] && z <= cut)
                        depth[y * n + x] = cast(float) z;
                }
        }
        Drawn d;
        d.line = new bool[n * n];
        d.at = new Vec3[n * n];
        void segment(Vec3 p, Vec3 q, bool hidden)
        {
            auto a = toScreen(p), b = toScreen(q);
            immutable len = sqrt((b.x - a.x) ^^ 2 + (b.y - a.y) ^^ 2);
            immutable steps = max(1, cast(int)(len * 2));
            foreach (s; 0 .. steps + 1)
            {
                immutable t = cast(double) s / steps;
                immutable x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t;
                foreach (yy; cast(int) floor(y - 0.75) .. cast(int) ceil(y + 0.75))
                    foreach (xx; cast(int) floor(x - 0.75) .. cast(int) ceil(x + 0.75))
                    {
                        if (xx < 0 || yy < 0 || xx >= n || yy >= n)
                            continue;
                        immutable at = yy * n + xx;
                        // seen when no face is in front of it (beyond the tolerance), and not cut away
                        if (hidden && (z < depth[at] - tol || z > cut))
                            continue;
                        d.line[at] = true;
                        d.at[at] = p + (q - p) * t;
                    }
            }
        }
        foreach (i, e; edges)
        {
            if (!sharp[i])
            {
                // an outline: one side towards the viewer, the other away
                immutable s0 = normals[i][0].dot(eye), s1 = normals[i][1].dot(eye);
                if ((s0 > 0) == (s1 > 0))
                    continue;
            }
            segment(mesh.vertex(e[0]), mesh.vertex(e[1]), true);
        }
        if (cut < double.infinity)
            // the section: where the cut crosses each triangle, always in front
            foreach (t; 0 .. mesh.triangleCount)
            {
                Vec3[3] p = [mesh.vertex(mesh.tris[3 * t]), mesh.vertex(mesh.tris[3 * t + 1]), mesh.vertex(mesh.tris[3 * t + 2])];
                Vec3[2] ends;
                size_t found;
                foreach (c; 0 .. 3)
                {
                    immutable za = toScreen(p[c]).z - cut, zb = toScreen(p[(c + 1) % 3]).z - cut;
                    if ((za > 0) != (zb > 0) && found < 2)
                        ends[found++] = p[c] + (p[(c + 1) % 3] - p[c]) * (za / (za - zb));
                }
                if (found == 2)
                    segment(ends[0], ends[1], false);
            }
        return d;
    }
}

/// The pixels within `r` of a set one.
bool[] grow(const bool[] m, uint n, int r)
{
    auto h = new bool[m.length], v = new bool[m.length];
    foreach (y; 0 .. n)
    {
        int last = -1_000_000;
        foreach (x; 0 .. n)
        {
            if (m[y * n + x])
                last = x;
            h[y * n + x] = x - last <= r;
        }
        last = 1_000_000;
        foreach_reverse (x; 0 .. n)
        {
            if (m[y * n + x])
                last = x;
            h[y * n + x] |= last - x <= r;
        }
    }
    foreach (x; 0 .. n)
    {
        int last = -1_000_000;
        foreach (y; 0 .. n)
        {
            if (h[y * n + x])
                last = y;
            v[y * n + x] = y - last <= r;
        }
        last = 1_000_000;
        foreach_reverse (y; 0 .. n)
        {
            if (h[y * n + x])
                last = y;
            v[y * n + x] |= last - y <= r;
        }
    }
    return v;
}

bool[] minus(const bool[] a, const bool[] b)
{
    auto r = new bool[a.length];
    foreach (i; 0 .. a.length)
        r[i] = a[i] && !b[i];
    return r;
}

/// Clears the groups of touching pixels smaller than `least`.
void dropSpecks(bool[] m, uint n, size_t least)
{
    auto seen = new bool[m.length];
    size_t[] group, stack;
    foreach (q0; 0 .. m.length)
    {
        if (!m[q0] || seen[q0])
            continue;
        group.length = 0;
        stack = [q0];
        seen[q0] = true;
        while (stack.length)
        {
            immutable q = stack[$ - 1];
            stack = stack[0 .. $ - 1];
            group ~= q;
            immutable x = cast(int)(q % n), y = cast(int)(q / n);
            foreach (dy; -1 .. 2)
                foreach (dx; -1 .. 2)
                {
                    immutable xx = x + dx, yy = y + dy;
                    if (xx < 0 || yy < 0 || xx >= n || yy >= n)
                        continue;
                    immutable o = yy * n + xx;
                    if (m[o] && !seen[o])
                    {
                        seen[o] = true;
                        stack ~= o;
                    }
                }
        }
        if (group.length < least)
            foreach (q; group)
                m[q] = false;
    }
}

unittest
{
    // a 10 mm cube against the same with one vertical edge chamfered 2 mm: the chamfer's two lines
    // are lines of the original the copy lacks; the copy's sharp corner a line the original has not
    Mesh prism(double[2][] outline, double h)
    {
        Mesh m;
        foreach (z; [0.0, h])
            foreach (p; outline)
                m.verts ~= [cast(float) p[0], cast(float) p[1], cast(float) z];
        immutable k = cast(uint) outline.length;
        foreach (i; 1 .. k - 1)
        {
            m.tris ~= [0, i + 1, i];
            m.tris ~= [k, k + i, k + i + 1];
        }
        foreach (i; 0 .. k)
        {
            immutable j = (i + 1) % k;
            m.tris ~= [i, j, k + j, i, k + j, k + i];
        }
        return m;
    }
    auto sharpCube = prism([[0, 0], [10, 0], [10, 10], [0, 10]], 10);
    auto chamfered = prism([[0, 0], [8, 0], [10, 2], [10, 10], [0, 10]], 10);
    auto d = lineDiff(sharpCube, chamfered, orbit(), 120);
    assert(d.strokes.length, "the chamfer is found");
    auto s = d.strokes[0];
    assert(s.lo.x > 6 && s.lo.y < 4 && s.hi.z > 8 && s.seenFrom.length > 5, "where the chamfer is, seen from many sides");
    size_t lost;
    foreach (st; d.strokes)
        lost += st.missing;
    assert(lost, "lines of the original the copy lacks");
}
