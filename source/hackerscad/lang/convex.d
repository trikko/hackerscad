/// hull() and minkowski(): convex hulls and Minkowski sums of solids and
/// profiles, computed on their surfaces' points (geom/hull) and turned back
/// into solids by the kernel.
module hackerscad.lang.convex;

import std.algorithm : max, min;
import std.format : format;
import std.math : abs, acos, PI;

import hackerscad.geom.hull;
import hackerscad.geom.mesh;
import hackerscad.geom.vec;
import hackerscad.kernel.brep;
import hackerscad.lang.errors;

/// How closely curved surfaces are followed: a hull of a sphere is
/// made of flat facets this close to it (mm, and at most this angle
/// between facets). Finer would multiply the points, and a Minkowski sum
/// multiplies the points of its two shapes.
enum deflection = 0.05, angularDeflection = 0.2;

/// The most pieces a Minkowski sum of a shape that is not convex is made
/// of (one per convex flat face or curved triangle): beyond it the sum
/// would take minutes and gigabytes.
enum maxPieces = 500;

/// The points of a solid's or profile's surface.
Vec3[] pointsOf(BrepKernel k, Brep b)
{
    auto m = k.tessellate(b, deflection, angularDeflection).welded;
    auto r = new Vec3[m.vertexCount];
    foreach (i; 0 .. m.vertexCount)
        r[i] = m.vertex(i);
    return r;
}

/// A plane through points (origin and unit normal), when they all lie on one.
bool commonPlane(const Vec3[] pts, out Vec3 origin, out Vec3 normal)
{
    if (pts.length < 3)
        return false;
    Vec3 lo = pts[0], hi = pts[0];
    foreach (p; pts)
    {
        lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z));
        hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z));
    }
    immutable eps = 1e-6 * max(1.0, (hi - lo).length);
    // the normal of the largest triangle from the first point
    origin = pts[0];
    size_t far;
    foreach (i, p; pts)
        if ((p - origin).length > (pts[far] - origin).length)
            far = i;
    Vec3 best;
    foreach (p; pts)
    {
        auto n = (pts[far] - origin).cross(p - origin);
        if (n.length > best.length)
            best = n;
    }
    if (best.length <= eps * eps)
        return false;
    // one way for every plane: up, or else towards +Y, or else +X (two
    // profiles of one plane get the same normal, and their faces join)
    normal = best.normalized;
    if (normal.z < -1e-9 || (abs(normal.z) <= 1e-9 && (normal.y < -1e-9 || (abs(normal.y) <= 1e-9 && normal.x < 0))))
        normal = -normal;
    foreach (p; pts)
        if (abs((p - origin).dot(normal)) > eps)
            return false;
    return true;
}

/// The turn that takes Z to `normal` (axis and angle): a profile drawn on XY
/// turned so and moved to a point lies in the plane.
void turnFromZ(Vec3 normal, out Vec3 axis, out double angle)
{
    auto z = Vec3(0, 0, 1);
    auto c = z.cross(normal);
    angle = acos(max(-1.0, min(1.0, z.dot(normal))));
    if (c.length < 1e-12)
        axis = Vec3(1, 0, 0);   // along Z already, or opposite: half a turn about X
    else
        axis = c.normalized;
}

/// v turned by `angle` about the unit `axis` (Rodrigues).
Vec3 turned(Vec3 v, Vec3 axis, double angle)
{
    import std.math : cos, sin;
    return v * cos(angle) + axis.cross(v) * sin(angle) + axis * (axis.dot(v) * (1 - cos(angle)));
}

/// Points of a plane as x, y along the plane's own axes (Z turned onto
/// the normal takes X and Y to them).
double[2][] flatten(const Vec3[] pts, Vec3 origin, Vec3 normal)
{
    Vec3 axis;
    double angle;
    turnFromZ(normal, axis, angle);
    immutable u = turned(Vec3(1, 0, 0), axis, angle), v = turned(Vec3(0, 1, 0), axis, angle);
    auto r = new double[2][pts.length];
    foreach (i, p; pts)
        r[i] = [(p - origin).dot(u), (p - origin).dot(v)];
    return r;
}

/// A profile from a polygon drawn in the plane's own axes.
Brep placedPolygon(BrepKernel k, const(double[2])[] corners, Vec3 origin, Vec3 normal)
{
    double[] xy;
    foreach (c; corners)
        xy ~= [c[0], c[1]];
    Vec3 axis;
    double angle;
    turnFromZ(normal, axis, angle);
    auto b = k.polygon(xy);
    if (angle > 1e-12)
        b = k.rotate(b, axis, angle);
    return k.translate(b, origin);
}

/// The solid of a hull mesh.
Brep solidOf(BrepKernel k, Vec3[] pts, Span span)
{
    try
        return k.fromMesh(convexHull(pts));
    catch (HullException e)
        throw new HcadError(Code.type, e.msg, span);
}

/// The convex hull of solids and profiles: a solid, or a profile when
/// they are all profiles in one plane.
Brep hullOf(BrepKernel k, Brep[] items, bool allFlat, Span span, out bool flat)
{
    Vec3[] pts;
    foreach (b; items)
        pts ~= pointsOf(k, b);
    Vec3 origin, normal;
    flat = allFlat && commonPlane(pts, origin, normal);
    if (!flat)
        return solidOf(k, pts, span);
    auto corners = convexHull2(flatten(pts, origin, normal));
    if (corners.length < 3)
        throw new HcadError(Code.type, "the profiles are on a line: their hull has no area", span);
    return placedPolygon(k, corners, origin, normal);
}

/// Area of a polygon (positive counter-clockwise).
double area2(const(double[2])[] p)
{
    double a = 0;
    foreach (i; 0 .. p.length)
    {
        auto q = p[i], r = p[(i + 1) % p.length];
        a += q[0] * r[1] - r[0] * q[1];
    }
    return a / 2;
}

/// The Minkowski sum of two solids, or of two profiles in one plane: every
/// point of the one moved by every point of the other. One of them must
/// be convex (a sphere, a cylinder, a box…); the other may be anything.
Brep minkowskiOf(BrepKernel k, Brep a, Brep b, bool flat, Span span)
{
    auto ma = k.tessellate(a, deflection, angularDeflection).welded;
    auto mb = k.tessellate(b, deflection, angularDeflection).welded;
    Vec3[] pa, pb;
    foreach (i; 0 .. ma.vertexCount)
        pa ~= ma.vertex(i);
    foreach (i; 0 .. mb.vertexCount)
        pb ~= mb.vertex(i);
    // with a ball (a disc for profiles), the sum is an offset: exact, and
    // fast whatever the other shape
    // (when the kernel's offset fails on a shape, the general way below)
    Vec3 centre;
    double r;
    try
    {
        if (isBall(pb, k.bbox(b), flat ? k.area(b) : k.volume(b), flat, centre, r))
            return flat ? k.profileOffset(k.translate(a, centre), r) : k.offset(k.translate(a, centre), r);
        if (isBall(pa, k.bbox(a), flat ? k.area(a) : k.volume(a), flat, centre, r))
            return flat ? k.profileOffset(k.translate(b, centre), r) : k.offset(k.translate(b, centre), r);
    }
    catch (KernelException)
    {
    }
    return flat ? minkowski2(k, a, b, ma, mb, pa, pb, span) : minkowski3(k, a, b, ma, mb, pa, pb, span);
}

/// A sphere (a disc when flat): every point of its surface (outline) as far
/// from the middle of its exact box, and its exact volume (area) the
/// ball's. A regular polygon has its corners equidistant too: the area
/// tells it apart.
bool isBall(const Vec3[] pts, BBox box, double size, bool flat, out Vec3 centre, out double r)
{
    if (pts.length < 16)
        return false;
    centre = (box.min + box.max) * 0.5;
    r = 0;
    foreach (p; pts)
        r = max(r, (p - centre).length);
    if (r <= 0)
        return false;
    // a disc's inner points (from its triangles) are not on the outline:
    // only the far ones count there
    size_t onRim;
    foreach (p; pts)
    {
        immutable d = (p - centre).length;
        if (abs(d - r) <= 1e-4 * r)
            onRim++;
        else if (!flat)
            return false;
    }
    if (onRim < 16)
        return false;
    immutable ball = flat ? PI * r * r : 4.0 / 3 * PI * r * r * r;
    return abs(abs(size) - ball) <= 1e-3 * ball;
}

private:

Vec3[] hullPoints(Vec3[] pts, Span span)
{
    try
    {
        auto h = convexHull(pts);
        auto r = new Vec3[h.vertexCount];
        foreach (i; 0 .. h.vertexCount)
            r[i] = h.vertex(i);
        return r;
    }
    catch (HullException e)
        throw new HcadError(Code.type, e.msg, span);
}

/// Convex when its hull holds no more than itself; within a thousandth,
/// as a meshed curved surface is not exactly convex at its poles and
/// seams (and its volume may come out negative, by its winding).
bool convex3(const Mesh m, Vec3[] pts)
{
    immutable hv = abs(convexHull(pts).volume), mv = abs(m.volume);
    return hv - mv <= 1e-3 * hv + 1e-9;
}

Vec3[] sums(const Vec3[] a, const Vec3[] b)
{
    auto r = new Vec3[a.length * b.length];
    size_t n;
    foreach (p; a)
        foreach (q; b)
            r[n++] = p + q;
    return r;
}

Brep minkowski3(BrepKernel k, Brep a, Brep b, Mesh ma, Mesh mb, Vec3[] pa, Vec3[] pb, Span span)
{
    immutable ca = convex3(ma, pa), cb = convex3(mb, pb);
    if (!ca && !cb)
        throw new HcadError(Code.type, "minkowski needs one of the two shapes convex (a sphere, a cylinder, a box…)", span);
    if (!cb)
    {
        swap(a, b);
        swap(ma, mb);
        swap(pa, pb);
    }
    auto hb = hullPoints(pb, span);
    if (ca && cb)
        return solidOf(k, sums(hullPoints(pa, span), hb), span);
    // A not convex: its surface swept by B, piece by piece (a convex flat
    // face at once, any other face triangle by triangle), and A moved by a
    // point of B to fill the inside
    Brep[] pieces = [k.translate(a, hb[0])];
    immutable faced = ma.faceStart.length >= 2;
    immutable faceCount = faced ? ma.faceStart.length - 1 : ma.triangleCount;
    // count the pieces first: too many, and the sum is refused before any work
    {
        size_t count;
        foreach (f; 0 .. faceCount)
        {
            immutable t0 = faced ? ma.faceStart[f] : f, t1 = faced ? ma.faceStart[f + 1] : f + 1;
            bool planar = true;
            foreach (t; t0 .. t1)
                planar = planar && triangleNormal(ma, t).dot(triangleNormal(ma, t0)) > 1 - 1e-9;
            count += planar ? 1 : t1 - t0;
        }
        if (count > maxPieces)
            throw new HcadError(Code.limit, format("minkowski of this shape needs %d pieces (at most %d): its curved "
                ~ "faces are swept triangle by triangle. Round it with fillet, or use minkowski on a simpler shape",
                count, maxPieces), span);
    }
    foreach (f; 0 .. faceCount)
    {
        immutable t0 = faced ? ma.faceStart[f] : f, t1 = faced ? ma.faceStart[f + 1] : f + 1;
        if (t1 <= t0)
            continue;
        Vec3[] facePts;
        bool planar = true;
        auto n0 = triangleNormal(ma, t0);
        double faceArea = 0;
        foreach (t; t0 .. t1)
        {
            foreach (j; 0 .. 3)
                facePts ~= ma.vertex(ma.tris[t * 3 + j]);
            planar = planar && triangleNormal(ma, t).dot(n0) > 1 - 1e-9;
            faceArea += triangleArea(ma, t);
        }
        bool convexFace;
        if (planar && t1 - t0 > 1)
        {
            Vec3 o, n;
            if (commonPlane(facePts, o, n))
                convexFace = abs(abs(area2(convexHull2(flatten(facePts, o, n)))) - faceArea) <= 1e-6 * faceArea + 1e-12;
        }
        if (planar && (convexFace || t1 - t0 == 1))
            pieces ~= solidOf(k, sums(facePts, hb), span);
        else
            foreach (t; t0 .. t1)
                pieces ~= solidOf(k, sums([ma.vertex(ma.tris[t * 3]), ma.vertex(ma.tris[t * 3 + 1]),
                    ma.vertex(ma.tris[t * 3 + 2])], hb), span);
    }
    return k.fuseAll(pieces);
}

Brep minkowski2(BrepKernel k, Brep a, Brep b, Mesh ma, Mesh mb, Vec3[] pa, Vec3[] pb, Span span)
{
    Vec3 o, n;
    if (!commonPlane(pa ~ pb, o, n))
        throw new HcadError(Code.type, "minkowski of profiles needs them in one plane", span);
    // in the plane's axes; convex when the hull covers no more than the profile
    auto fa = flatten(pa, o, n), fb = flatten(pb, o, n);
    double areaOf(const Mesh m)
    {
        double s = 0;
        foreach (t; 0 .. m.triangleCount)
            s += triangleArea(m, t);
        return s;
    }
    immutable ca = abs(abs(area2(convexHull2(fa))) - areaOf(ma)) <= 1e-6 * areaOf(ma) + 1e-12;
    immutable cb = abs(abs(area2(convexHull2(fb))) - areaOf(mb)) <= 1e-6 * areaOf(mb) + 1e-12;
    if (!ca && !cb)
        throw new HcadError(Code.type, "minkowski needs one of the two profiles convex (a circle, a rectangle…)", span);
    if (!cb)
    {
        swap(a, b);
        swap(ma, mb);
        swap(fa, fb);
        swap(pa, pb);
    }
    auto hb = convexHull2(fb);
    double[2][] plus(const(double[2])[] p, const(double[2])[] q)
    {
        double[2][] r;
        foreach (x; p)
            foreach (y; q)
                r ~= [x[0] + y[0], x[1] + y[1]];
        return r;
    }
    Brep polygonOf(double[2][] pts)
    {
        auto h = convexHull2(pts);
        if (h.length < 3)
            throw new HcadError(Code.type, "minkowski of flat shapes without area", span);
        // the coordinates are from o, in both shapes: their sums from 2 o
        return placedPolygon(k, h, o * 2, n);
    }
    if (ca && cb)
        return polygonOf(plus(convexHull2(fa), hb));
    // A not convex: each side of its outline swept by B, and A moved by a
    // point of B (the outline: the triangle sides used once)
    Vec3 shift;
    {
        Vec3 axis;
        double angle;
        turnFromZ(n, axis, angle);
        shift = o + turned(Vec3(1, 0, 0), axis, angle) * hb[0][0] + turned(Vec3(0, 1, 0), axis, angle) * hb[0][1];
    }
    Brep[] pieces = [k.translate(a, shift)];
    uint[ulong] uses;
    static ulong edgeKey(uint p, uint q) => cast(ulong) min(p, q) << 32 | max(p, q);
    foreach (t; 0 .. ma.triangleCount)
        foreach (j; 0 .. 3)
            uses[edgeKey(ma.tris[t * 3 + j], ma.tris[t * 3 + (j + 1) % 3])]++;
    size_t outline;
    foreach (count; uses)
        outline += count == 1;
    if (outline > maxPieces)
        throw new HcadError(Code.limit, format("minkowski of this profile needs %d pieces (at most %d): its outline "
            ~ "has too many sides", outline, maxPieces), span);
    auto all = flatten(pa, o, n);   // indices as in ma's vertices
    foreach (e, count; uses)
        if (count == 1)
        {
            immutable p = cast(uint)(e >> 32), q = cast(uint)(e & 0xffff_ffff);
            pieces ~= polygonOf(plus([all[p], all[q]], hb));
        }
    return unionOfProfiles(k, pieces);
}

/// The union of profiles, two at a time and then the results two at a
/// time: the profile union merges each region back into one face (the
/// general fuse would leave the pieces' faces side by side).
Brep unionOfProfiles(BrepKernel k, Brep[] pieces)
{
    while (pieces.length > 1)
    {
        Brep[] next;
        for (size_t i = 0; i < pieces.length; i += 2)
            next ~= i + 1 < pieces.length ? k.boolean(pieces[i], pieces[i + 1], BoolOp.fuse) : pieces[i];
        pieces = next;
    }
    return pieces[0];
}

Vec3 triangleNormal(const Mesh m, size_t t)
{
    auto a = m.vertex(m.tris[t * 3]), b = m.vertex(m.tris[t * 3 + 1]), c = m.vertex(m.tris[t * 3 + 2]);
    auto n = (b - a).cross(c - a);
    return n.length > 0 ? n.normalized : n;
}

double triangleArea(const Mesh m, size_t t)
{
    auto a = m.vertex(m.tris[t * 3]), b = m.vertex(m.tris[t * 3 + 1]), c = m.vertex(m.tris[t * 3 + 2]);
    return (b - a).cross(c - a).length / 2;
}

void swap(T)(ref T a, ref T b)
{
    auto t = a;
    a = b;
    b = t;
}
