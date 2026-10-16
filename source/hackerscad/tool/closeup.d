/// Close-ups of the places where a copy and its original differ (an entry
/// of hcad diff, compare, lines or match): seen from a direction nothing is
/// in the way of, or with what lies in front cut away, framed on the place
/// with some room around it; the drawings of both side by side with the
/// copy coloured by its distance from the original.
module hackerscad.tool.closeup;

import std.algorithm : max, min;
import std.format : format;
import std.math : abs, ceil;

import hackerscad.geom.mesh;
import hackerscad.geom.vec;
import hackerscad.render.raster : Image, Shaded, Shot, render;
import hackerscad.render.linediff : Direction, lineDiff, orbit;

/// A place to look at closely.
struct Place
{
    string what;      /// how the report names it: "diff 2: to add 8.5 mm³ …"
    Vec3 lo, hi;      /// its box
    bool hasEye;      /// look from `eye` (the way its surface faces), if nothing is in the way
    Vec3 eye;
}

/// The part of `m` within the box (its triangles that reach into it).
Mesh within(const Mesh m, Vec3 lo, Vec3 hi)
{
    Mesh r;
    auto index = new uint[m.vertexCount];
    index[] = uint.max;
    foreach (t; 0 .. m.triangleCount)
    {
        Vec3[3] p;
        foreach (k; 0 .. 3)
            p[k] = m.vertex(m.tris[3 * t + k]);
        if (min(p[0].x, p[1].x, p[2].x) > hi.x || max(p[0].x, p[1].x, p[2].x) < lo.x
            || min(p[0].y, p[1].y, p[2].y) > hi.y || max(p[0].y, p[1].y, p[2].y) < lo.y
            || min(p[0].z, p[1].z, p[2].z) > hi.z || max(p[0].z, p[1].z, p[2].z) < lo.z)
            continue;
        foreach (k; 0 .. 3)
        {
            immutable v = m.tris[3 * t + k];
            if (index[v] == uint.max)
            {
                index[v] = cast(uint) r.vertexCount;
                r.verts ~= m.verts[3 * v .. 3 * v + 3];
            }
            r.tris ~= index[v];
        }
    }
    return r;
}

/// How many of the points see the viewer along `eye` with nothing of `m` in
/// the way (a ray from each, nudged off the surface it lies on). With a box
/// (`lo` … `hi`, the place itself), what the ray meets before it leaves the
/// box is the place's own surface, not in the way: material to add lies
/// inside the original, and its ray leaves through the original's face.
size_t clearRays(const Mesh m, const Vec3[] points, Vec3 eye, double nudge, Vec3 lo = Vec3.init, Vec3 hi = Vec3.init)
{
    size_t clear;
    immutable e = eye.normalized;
    immutable boxed = hi.x > lo.x || hi.y > lo.y || hi.z > lo.z;
    foreach (p; points)
    {
        immutable o = p + e * nudge;
        // where the ray leaves the box
        double leave = 0;
        if (boxed)
        {
            leave = double.infinity;
            foreach (k; 0 .. 3)
            {
                immutable d = [e.x, e.y, e.z][k], q = [o.x, o.y, o.z][k];
                if (abs(d) > 1e-12)
                    leave = min(leave, ((d > 0 ? [hi.x, hi.y, hi.z][k] : [lo.x, lo.y, lo.z][k]) - q) / d);
            }
            leave = max(0.0, leave) + nudge;
        }
        bool blocked;
        foreach (t; 0 .. m.triangleCount)
        {
            // Möller–Trumbore
            auto a = m.vertex(m.tris[3 * t]), b = m.vertex(m.tris[3 * t + 1]), c = m.vertex(m.tris[3 * t + 2]);
            auto e1 = b - a, e2 = c - a, pv = e.cross(e2);
            immutable det = e1.dot(pv);
            if (abs(det) < 1e-12)
                continue;
            immutable inv = 1 / det;
            auto tv = o - a;
            immutable u = tv.dot(pv) * inv;
            if (u < 0 || u > 1)
                continue;
            auto qv = tv.cross(e1);
            immutable v = e.dot(qv) * inv;
            if (v < 0 || u + v > 1)
                continue;
            if (e2.dot(qv) * inv > leave)
            {
                blocked = true;
                break;
            }
        }
        if (!blocked)
            clear++;
    }
    return clear;
}

/// Where to look at a place from, and whether what lies in front must be cut
/// away: its own direction when nothing is in the way, else the direction
/// around the part from which most of it is in sight (of those, the one
/// most outward from the part's middle); cut when none sees most of it.
Shot shotOf(const Mesh original, Place p, Vec3 middle)
{
    immutable c = (p.lo + p.hi) / 2;
    Vec3[] points = [c];
    foreach (k; 0 .. 8)
        points ~= c + (Vec3(k & 1 ? p.hi.x : p.lo.x, k & 2 ? p.hi.y : p.lo.y, k & 4 ? p.hi.z : p.lo.z) - c) * 0.5;
    immutable nudge = max(0.02, 0.02 * (p.hi - p.lo).length);
    // the room around it: the place and as much again, a millimetre at least
    immutable size = p.hi - p.lo;
    immutable pad = max(1.0, 0.5 * max(size.x, size.y, size.z));
    immutable lo = p.lo - Vec3(pad, pad, pad), hi = p.hi + Vec3(pad, pad, pad);
    if (p.hasEye && clearRays(original, points, p.eye, nudge, p.lo, p.hi) * 2 > points.length)
        return Shot(p.eye.normalized).framing(lo, hi);
    // the preferred side: across the place's thinnest side (a thin piece is
    // seen face on), towards the outside of the part
    auto out_ = c - middle;
    immutable away = out_.length > 1e-9 ? out_.normalized : Vec3(0, 0, 1);
    Vec3 outward = Vec3(away.x >= 0 ? 1 : -1, 0, 0);
    if (size.y < size.x && size.y <= size.z)
        outward = Vec3(0, away.y >= 0 ? 1 : -1, 0);
    else if (size.z < size.x && size.z < size.y)
        outward = Vec3(0, 0, away.z >= 0 ? 1 : -1);
    outward = (outward + away * 0.3).normalized;
    size_t bestClear;
    double bestOut = -2;
    Vec3 best = p.hasEye ? p.eye.normalized : outward;
    foreach (d; orbit())
    {
        immutable e = d.eye;
        immutable n = clearRays(original, points, e, nudge, p.lo, p.hi);
        immutable o = e.dot(outward);
        if (n > bestClear || (n == bestClear && n > 0 && o > bestOut))
        {
            bestClear = n;
            bestOut = o;
            best = e;
        }
    }
    return Shot(best).framing(lo, hi, bestClear * 2 <= points.length);
}

/// The close-ups of `places`, one row each: on the left the drawings (grey
/// in both, red only in the original, blue only in the copy), on the right
/// the copy coloured by its distance from the original (green within half
/// `tol`, yellow at it, red at twice it) with the original see-through. The
/// text says, per row, what it is and from where it is seen.
Image closeUps(const Mesh copy, const Mesh original, uint copyRgb, const Place[] places, double tol, out string text,
    uint cell = 450)
{
    import hackerscad.geom.deviation : deviationMap;
    Vec3 lo = Vec3(double.infinity, double.infinity, double.infinity), hi = -lo;
    foreach (i; 0 .. original.vertexCount)
    {
        auto p = original.vertex(i);
        lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z));
        hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z));
    }
    immutable middle = (lo + hi) / 2;
    auto sheet = Image(2 * cell, cast(uint)(cell * places.length), new ubyte[2 * cell * cell * places.length * 3]);
    sheet.rgb[] = 255;
    foreach (row, p; places)
    {
        auto shot = shotOf(original, p, middle);
        auto lines = lineDiff(copy, original, [Direction.of(shot.eye)], cell, &shot).pictures[0];
        // the map: only what is near, finely
        auto near = within(copy, shot.lo, shot.hi);
        auto frame = shot.hi - shot.lo;
        uint[] colors;
        auto map = deviationMap(near, original, max(0.05, max(frame.x, frame.y, frame.z) / 120), tol, colors);
        auto s = Shaded(map.welded(1e-6), copyRgb, map);
        s.colors = colors;
        // the original, see-through (alpha 0.3)
        auto ghost = Shaded(within(original, shot.lo, shot.hi).welded(1e-6), 0xB3708090);
        auto shaded = render([s, ghost], shot, cell, cell);
        foreach (k, img; [lines, shaded])
            foreach (y; 0 .. cell)
                foreach (x; 0 .. cell)
                {
                    immutable edge = x == 0 || y == 0 || x == cell - 1 || y == cell - 1;
                    immutable q = ((row * cell + y) * sheet.width + k * cell + x) * 3;
                    if (edge)
                        sheet.rgb[q .. q + 3] = [210, 210, 215];
                    else
                        sheet.rgb[q .. q + 3] = img.rgb[(y * cell + x) * 3 .. (y * cell + x) * 3 + 3];
                }
        text ~= format("  close-up %d (row %d of the picture): %s; seen %s, %s mm across\n", row + 1, row + 1, p.what,
            shot, ceil(max(frame.x, frame.y, frame.z)));
    }
    text ~= format("  in each row, left: the drawings (grey in both, red only in the original, blue only in the copy); "
        ~ "right: the copy coloured by its distance from the original (green within %g mm, yellow at %g, red at %g), "
        ~ "the original see-through\n", tol / 2, tol, 2 * tol);
    return sheet;
}

unittest
{
    // a ray from the middle of a box's top face goes up clear, down blocked by
    // the bottom face; the shot for a place on top looks from above
    Mesh m;
    foreach (k; 0 .. 8)
        m.verts ~= [cast(float)(k & 1 ? 10 : 0), cast(float)(k & 2 ? 10 : 0), cast(float)(k & 4 ? 10 : 0)];
    m.tris = [0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6, 0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3, 0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5];
    assert(clearRays(m, [Vec3(5, 5, 10)], Vec3(0, 0, 1), 0.01) == 1);
    assert(clearRays(m, [Vec3(5, 5, 10)], Vec3(0, 0, -1), 0.01) == 0);
    auto shot = shotOf(m, Place("top", Vec3(4, 4, 9.9), Vec3(6, 6, 10)), Vec3(5, 5, 5));
    assert(shot.eye.z > 0.8 && !shot.cut, "a place on top is seen from above");
    // a place inside the block: nothing sees it, so the front is cut away
    auto inside = shotOf(m, Place("inside", Vec3(4, 4, 4), Vec3(6, 6, 6)), Vec3(5, 5, 5));
    assert(inside.cut, "a place inside is seen with the front cut away");
    // the close-up picture: one row of two panels
    string text;
    auto img = closeUps(m, m, 0x4682B4, [Place("top", Vec3(4, 4, 9.9), Vec3(6, 6, 10))], 0.1, text, 120);
    assert(img.width == 240 && img.height == 120 && text.length);
}
