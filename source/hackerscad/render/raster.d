/// Software renderer: produces shaded views with outlined edges without a
/// GPU, so the CLI, CI and agents get deterministic images of a model.
module hackerscad.render.raster;

import std.algorithm : clamp, min, max;
import std.math : abs, floor, ceil, sqrt;

import hackerscad.geom.vec;
import hackerscad.geom.mesh;
import hackerscad.geom.color : alphaOf, defaultPartColor;

enum View
{
    iso,
    front,
    back,
    top,
    bottom,
    left,
    right,
}

/// Where a picture is taken from: the direction towards the viewer, and
/// optionally a box to frame (a close-up of it, with some room around) and
/// whether what lies nearer than the box is cut away (to see inside).
struct Shot
{
    Vec3 eye = Vec3(1, -1.25, 0.95);   /// from the part towards the viewer
    bool framed;                        /// frame lo … hi instead of the whole picture
    Vec3 lo, hi;
    bool cut;                           /// leave out what lies in front of the box

    /// One of the named views.
    static Shot of(View v) => Shot(viewEye(v));

    /// The same direction, framed on a box.
    Shot framing(Vec3 boxLo, Vec3 boxHi, bool cutAway = false) const
    {
        Shot r = this;
        r.framed = true;
        r.lo = boxLo;
        r.hi = boxHi;
        r.cut = cutAway;
        return r;
    }

    /// In words, where it looks from and which way the axes run: "from the
    /// front (-y), x to the right, z up".
    string toString() const
    {
        import std.format : format;
        import std.math : atan2, asin, PI;
        auto cam = Camera(eye);
        string axis(Vec3 v)
        {
            foreach (k, name; ["x", "y", "z"])
            {
                immutable c = [v.x, v.y, v.z][k];
                if (abs(c) > 0.99)
                    return (c < 0 ? "-" : "") ~ name;
            }
            return format("(%.2g, %.2g, %.2g)", v.x, v.y, v.z);
        }
        immutable e = eye.normalized;
        string from;
        foreach (v; [View.front, View.back, View.top, View.bottom, View.left, View.right])
            if (viewEye(v).normalized.dot(e) > 0.999)
                from = format("from the %s (%s)", v, axis(e));
        if (from is null)
            from = format("from azimuth %.3g°, elevation %.3g°", atan2(e.x, -e.y) * 180 / PI, asin(e.z) * 180 / PI);
        return format("%s, %s to the right, %s up%s", from, axis(cam.right), axis(cam.up),
            framed ? format(", framed on (%.4g, %.4g, %.4g) to (%.4g, %.4g, %.4g)%s", lo.x, lo.y, lo.z, hi.x, hi.y,
                hi.z, cut ? ", what lies in front cut away" : "") : "");
    }
}

/// The direction of a named view, towards the viewer.
Vec3 viewEye(View v)
{
    final switch (v)
    {
    case View.iso: return Vec3(1, -1.25, 0.95);
    case View.front: return Vec3(0, -1, 0);
    case View.back: return Vec3(0, 1, 0);
    case View.top: return Vec3(0, 0, 1);
    case View.bottom: return Vec3(0, 0, -1);
    case View.left: return Vec3(-1, 0, 0);
    case View.right: return Vec3(1, 0, 0);
    }
}

struct Shaded
{
    Mesh mesh;   /// welded mesh: edges are detected from shared vertices
    uint rgb = defaultPartColor;
    /// Optional: the kernel's tessellation, one vertex set per B-rep face.
    /// Its normals are smoothed inside each face (as in the 3D view), so
    /// curved faces are not faceted.
    Mesh faces;
    /// Optional, per triangle of `faces` (or of `mesh` without them): 1
    /// striped red (an overhang), 2 cross-hatched violet (a thin wall).
    const(ubyte)[] marks;
    /// Optional, per triangle of `faces` (or of `mesh`): its own colour (0xRRGGBB), as for a map of
    /// deviations; it replaces the part's colour.
    const(uint)[] colors;
}

/// The lighting of the 3D view (its fragment shader), for a view direction
/// v (towards the viewer): ambient, diffuse from a light a little above the
/// viewer, and a highlight.
Vec3 viewLighting(Vec3 n, Vec3 v, Vec3 base)
{
    if (n.dot(v) < 0)
        n = -n;   // two-sided: open meshes still look solid
    immutable l = (v + Vec3(0, 0, 0.6)).normalized;
    immutable diffuse = max(0.0, n.dot(l));
    // x^48 = ((x^3)^2)^2^2^2, by squaring: once per pixel, pow is costly
    immutable x = max(0.0, n.dot((l + v).normalized));
    double h = x * x * x;
    foreach (_; 0 .. 4)
        h *= h;
    immutable specular = h * 0.22;
    return base * (0.34 + 0.66 * diffuse) + Vec3(255, 255, 255) * specular;
}

/// A closed surface (the side of a cylinder) is meshed with its seam
/// vertices twice, one copy per side, each with a normal from its own side
/// only: the light would show the seam. Copies in the same face at the same
/// point share the sum of their normals.
void smoothSeams(const Mesh raw, Vec3[] normals)
{
    import std.math : lround;
    auto face = new int[raw.vertexCount];
    face[] = -1;
    foreach (t; 0 .. raw.triangleCount)
        foreach (k; 0 .. 3)
            face[raw.tris[t * 3 + k]] = raw.faceOf(t);
    enum cell = 1e-5;
    size_t[][long[4]] same;
    foreach (i; 0 .. raw.vertexCount)
    {
        auto p = raw.vertex(i);
        same[[face[i], lround(p.x / cell), lround(p.y / cell), lround(p.z / cell)]] ~= i;
    }
    foreach (group; same)
        if (group.length > 1)
        {
            Vec3 sum;
            foreach (i; group)
                sum = sum + normals[i];
            foreach (i; group)
                normals[i] = sum;
        }
}

/// Per-vertex normals of a mesh with separate vertices per face: the
/// area-weighted sum of the normals of the triangles around each vertex.
Vec3[] vertexNormals(const Mesh m)
{
    auto normals = new Vec3[m.vertexCount];
    foreach (t; 0 .. m.triangleCount)
    {
        auto ia = m.tris[t * 3], ib = m.tris[t * 3 + 1], ic = m.tris[t * 3 + 2];
        auto a = m.vertex(ia);
        auto n = (m.vertex(ib) - a).cross(m.vertex(ic) - a);
        normals[ia] = normals[ia] + n;
        normals[ib] = normals[ib] + n;
        normals[ic] = normals[ic] + n;
    }
    smoothSeams(m, normals);
    foreach (ref n; normals)
        n = n.length > 0 ? n.normalized : Vec3(0, 0, 1);
    return normals;
}

struct Image
{
    uint width, height;
    ubyte[] rgb;
}

/// Renders the meshes from the given view, fitted to the image.
Image render(const Shaded[] items, View view, uint width, uint height) =>
    render(items, prepare(items), Shot.of(view), width, height);

/// Renders the meshes as the shot says: from its direction, framed on its box
/// if it has one.
Image render(const Shaded[] items, Shot shot, uint width, uint height) =>
    render(items, prepare(items), shot, width, height);

/// What does not depend on the view: computed once for a sheet of views.
private struct Prepared
{
    uint[2][] edges;    /// feature edges of the welded mesh
    Vec3[] normals;     /// smooth normals of the face mesh, if any
}

private Prepared[] prepare(const Shaded[] items)
{
    auto r = new Prepared[items.length];
    foreach (i, it; items)
    {
        // a see-through part (a reference, a mesh with a face per facet) shows
        // only its sharp edges: all of them would bury the picture in lines
        r[i].edges = featureEdges(it.mesh, alphaOf(it.rgb) < 0.999 ? 40 : 25);
        if (it.faces.triangleCount)
            r[i].normals = vertexNormals(it.faces);
    }
    return r;
}

private Image render(const Shaded[] items, const Prepared[] prepared, Shot shot, uint width, uint height)
{
    enum ss = 3; // supersampling factor
    auto c = Canvas(width * ss, height * ss);
    c.clear();

    auto cam = Camera(shot.eye);
    double x0 = double.max, y0 = double.max, x1 = -double.max, y1 = -double.max, z0 = double.max, z1 = -double.max;
    foreach (it; items)
        foreach (i; 0 .. it.mesh.vertexCount)
        {
            auto p = cam.project(it.mesh.vertex(i));
            x0 = min(x0, p.x), x1 = max(x1, p.x), y0 = min(y0, p.y), y1 = max(y1, p.y);
            z0 = min(z0, p.z), z1 = max(z1, p.z);
        }
    if (x0 > x1)
        return c.downsample(ss);
    immutable depthRange = z1 - z0;

    // a close-up: the frame is the box's, with room around it; what lies in
    // front of the box (nearer the viewer) can be cut away
    double margin = 0.08;
    if (shot.framed)
    {
        x0 = y0 = z0 = double.max;
        x1 = y1 = z1 = -double.max;
        foreach (k; 0 .. 8)
        {
            auto p = cam.project(Vec3(k & 1 ? shot.hi.x : shot.lo.x, k & 2 ? shot.hi.y : shot.lo.y,
                k & 4 ? shot.hi.z : shot.lo.z));
            x0 = min(x0, p.x), x1 = max(x1, p.x), y0 = min(y0, p.y), y1 = max(y1, p.y);
            z0 = min(z0, p.z), z1 = max(z1, p.z);
        }
        margin = 0.15;
        if (shot.cut)
            c.nearest = cast(float)(z1 + 0.05 * max(x1 - x0, y1 - y0, 1e-3));
    }
    immutable k = min(c.w * (1 - 2 * margin) / max(x1 - x0, 1e-9), c.h * (1 - 2 * margin) / max(y1 - y0, 1e-9));
    immutable ox = c.w / 2.0 - k * (x0 + x1) / 2, oy = c.h / 2.0 + k * (y0 + y1) / 2;
    Vec3 toScreen(Vec3 p)
    {
        auto q = cam.project(p);
        return Vec3(ox + k * q.x, oy - k * q.y, q.z);
    }


    // opaque parts first, then the see-through ones blended over them
    immutable edgeTolerance = 0.004 * max(depthRange, 1e-6);
    Edges[] opaqueEdges;
    foreach (see; [false, true])
    {
        if (see && opaqueEdges.length)
            c.drawEdges(opaqueEdges, &toScreen, ss * 1.1, edgeTolerance, ss);
        foreach (i, it; items)
        {
            immutable alpha = alphaOf(it.rgb);
            if ((alpha < 0.999) != see)
                continue;
            immutable base = Vec3((it.rgb >> 16) & 0xFF, (it.rgb >> 8) & 0xFF, it.rgb & 0xFF);
            auto m = it.mesh;
            Vec3 light(Vec3 n) => viewLighting(n, cam.eye, base);
            Vec3 overhangLight(Vec3 n) => viewLighting(n, cam.eye, Vec3(230, 64, 51));
            Vec3 thinLight(Vec3 n) => viewLighting(n, cam.eye, Vec3(148, 92, 224));
            if (it.faces.triangleCount)
            {
                // smooth inside each face, as in the 3D view
                auto f = it.faces;
                auto normals = prepared[i].normals;
                foreach (t; 0 .. f.triangleCount)
                {
                    auto ia = f.tris[t * 3], ib = f.tris[t * 3 + 1], ic = f.tris[t * 3 + 2];
                    immutable mark = t < it.marks.length ? it.marks[t] : 0;
                    Vec3 own;
                    if (t < it.colors.length)
                        own = Vec3((it.colors[t] >> 16) & 0xFF, (it.colors[t] >> 8) & 0xFF, it.colors[t] & 0xFF);
                    Vec3 ownLight(Vec3 n) => viewLighting(n, cam.eye, own);
                    c.triangle(toScreen(f.vertex(ia)), toScreen(f.vertex(ib)), toScreen(f.vertex(ic)),
                        normals[ia], normals[ib], normals[ic], t < it.colors.length ? &ownLight
                        : mark ? (mark == 1 ? &overhangLight : &thinLight) : &light, alpha, mark, 10.0 * ss);
                }
            }
            else
                foreach (t; 0 .. m.triangleCount)
                {
                    auto a = m.vertex(m.tris[t * 3]), b = m.vertex(m.tris[t * 3 + 1]), d = m.vertex(m.tris[t * 3 + 2]);
                    auto n = (b - a).cross(d - a).normalized;
                    immutable mark = t < it.marks.length ? it.marks[t] : 0;
                    c.triangle(toScreen(a), toScreen(b), toScreen(d), n, n, n,
                        mark ? (mark == 1 ? &overhangLight : &thinLight) : &light, alpha, mark, 10.0 * ss);
                }
            // the opaque parts' edges go to a mask, drawn once all their faces
            // are in the depth buffer; see-through parts draw theirs faintly
            if (see)
                foreach (e; prepared[i].edges)
                    c.line(toScreen(m.vertex(e[0])), toScreen(m.vertex(e[1])), edgeColour, ss * 1.1, edgeTolerance,
                        0.15);   // a thick line blends each pixel several times
            else
                opaqueEdges ~= Edges(m, prepared[i].edges.dup);
        }
    }

    return c.downsample(ss);
}

/// Several views side by side in a grid (left to right, top to bottom).
Image renderSheet(const Shaded[] items, const View[] views, uint cell, uint columns = 2)
{
    Shot[] shots;
    foreach (v; views)
        shots ~= Shot.of(v);
    return renderSheet(items, shots, cell, columns);
}

/// Several shots side by side in a grid (left to right, top to bottom).
Image renderSheet(const Shaded[] items, const Shot[] shots, uint cell, uint columns = 2)
{
    immutable rows = cast(uint)((shots.length + columns - 1) / columns);
    Image sheet = Image(cell * columns, cell * rows, new ubyte[cell * columns * cell * rows * 3]);
    sheet.rgb[] = 255;
    auto prepared = prepare(items);
    foreach (i, v; shots)
    {
        auto img = render(items, prepared, v, cell, cell);
        immutable cx = cast(uint)(i % columns) * cell, cy = cast(uint)(i / columns) * cell;
        foreach (y; 0 .. cell)
            sheet.rgb[((cy + y) * sheet.width + cx) * 3 .. ((cy + y) * sheet.width + cx + cell) * 3] =
                img.rgb[y * cell * 3 .. (y + 1) * cell * 3];
    }
    return sheet;
}

private immutable edgeColour = Vec3(35, 35, 40);

/// The feature edges of one mesh.
private struct Edges
{
    const(Mesh) mesh;
    uint[2][] pairs;
}

/// Edges on the boundary or between faces bent more than `angleDeg`.
uint[2][] featureEdges(const Mesh m, double angleDeg)
{
    uint[2][] sharp, tangent;
    edgeSets(m, angleDeg, sharp, tangent);
    return sharp;
}

/// The feature edges (as featureEdges), and `tangent`: the others between
/// two B-rep faces (when the mesh knows its faces), a fillet meeting a flat
/// face, a hole grazing a curve. A solid made from a mesh (an STL loaded)
/// has a face per facet: there they show its facets, as the file has them.
void edgeSets(const Mesh m, double angleDeg, out uint[2][] sharp, out uint[2][] tangent)
{
    import std.math : cos, PI;

    immutable limit = cos(angleDeg * PI / 180);
    immutable nt = m.triangleCount;
    auto normals = triangleNormals(m);
    foreach (ref n; normals)
        n = n.normalized;
    // the face of every triangle, once (faceOf searches for it)
    auto face = new int[nt];
    face[] = -1;
    if (m.faceStart.length >= 2)
        foreach (f; 0 .. m.faceStart.length - 1)
            foreach (t; m.faceStart[f] .. min(m.faceStart[f + 1], nt))
                face[t] = cast(int) f;
    // every side of every triangle, keyed by its two vertices and sorted: the
    // sides of one edge come next to each other
    auto keys = new ulong[nt * 3];
    auto tri = new uint[nt * 3];
    foreach (t; 0 .. nt)
        foreach (k; 0 .. 3)
        {
            ulong a = m.tris[t * 3 + k], b = m.tris[t * 3 + (k + 1) % 3];
            keys[t * 3 + k] = min(a, b) << 32 | max(a, b);
            tri[t * 3 + k] = cast(uint) t;
        }
    sortKeys(keys, tri);
    // calls `edge` with each edge's vertices and its triangles
    void eachEdge(scope void delegate(uint a, uint b, const uint[] ts) edge)
    {
        for (size_t i = 0; i < keys.length;)
        {
            size_t j = i + 1;
            while (j < keys.length && keys[j] == keys[i])
                j++;
            edge(cast(uint)(keys[i] >> 32), cast(uint)(keys[i] & 0xffff_ffff), tri[i .. j]);
            i = j;
        }
    }
    // two faces of the solid that meet at an angle anywhere meet at an
    // edge all along: where the angle fades (two cylinders crossing) the
    // edge goes on, instead of breaking into dashes
    static ulong pairOf(int f0, int f1) => cast(ulong) min(f0, f1) << 32 | cast(uint) max(f0, f1);
    bool[ulong] sharpPairs;
    eachEdge((a, b, ts) {
        if (ts.length == 2 && normals[ts[0]].dot(normals[ts[1]]) < limit)
        {
            immutable f0 = face[ts[0]], f1 = face[ts[1]];
            if (f0 != f1 && f0 >= 0 && f1 >= 0)
                sharpPairs[pairOf(f0, f1)] = true;
        }
    });
    eachEdge((a, b, ts) {
        if (ts.length != 2)
            sharp ~= [a, b];
        else if (normals[ts[0]].dot(normals[ts[1]]) < limit)
        {
            // a fold inside one face is the mesh's, not an edge: a face of
            // the solid is smooth (deep ripples bent between two triangles
            // would show as dashes)
            immutable f0 = face[ts[0]], f1 = face[ts[1]];
            if (f0 != f1 || f0 < 0)
                sharp ~= [a, b];
        }
        else
        {
            immutable f0 = face[ts[0]], f1 = face[ts[1]];
            if (f0 != f1 && f0 >= 0 && f1 >= 0)
            {
                if (pairOf(f0, f1) in sharpPairs)
                    sharp ~= [a, b];
                else
                    tangent ~= [a, b];
            }
        }
    });
}

/// The triangles of curved surfaces, 18 floats each: their three corners,
/// then a normal per corner, averaged over the triangles around it that
/// meet its own one at less than `angleDeg` (larger ones weigh more). The
/// outline of a curved surface crosses a triangle where the normal, between
/// its corners, turns from facing the eye to facing away: interpolated so,
/// it is one line, however the surface was cut into triangles. Flat
/// triangles (one normal at every corner) are left out.
float[] contourTriangles(const Mesh m, double angleDeg)
{
    import std.math : cos, PI;

    immutable limit = cos(angleDeg * PI / 180);
    auto area = triangleNormals(m);   // length: twice the area
    auto unit = new Vec3[area.length];
    foreach (t, n; area)
        unit[t] = n.normalized;
    // the triangles around each vertex, in one array: those of vertex v are
    // around[start[v] .. start[v + 1]]
    immutable nv = m.vertexCount;
    auto start = new uint[nv + 1];
    foreach (v; m.tris)
        start[v + 1]++;
    foreach (i; 1 .. nv + 1)
        start[i] += start[i - 1];
    auto fill = start[0 .. nv].dup;
    auto around = new uint[m.tris.length];
    foreach (t; 0 .. m.triangleCount)
        foreach (k; 0 .. 3)
            around[fill[m.tris[t * 3 + k]]++] = cast(uint) t;
    auto r = new float[m.triangleCount * 18];
    size_t used;
    foreach (t; 0 .. m.triangleCount)
    {
        Vec3[3] n;
        foreach (k; 0 .. 3)
        {
            Vec3 sum;
            immutable v = m.tris[t * 3 + k];
            foreach (o; around[start[v] .. start[v + 1]])
                if (unit[o].dot(unit[t]) >= limit)
                    sum = sum + area[o];
            n[k] = sum.normalized;
        }
        // flat here: no outline can cross it
        if (n[0].dot(n[1]) > 0.99995 && n[0].dot(n[2]) > 0.99995)
            continue;
        foreach (k; 0 .. 3)
        {
            auto p = m.vertex(m.tris[t * 3 + k]);
            r[used .. used + 3] = [cast(float) p.x, cast(float) p.y, cast(float) p.z];
            used += 3;
        }
        foreach (k; 0 .. 3)
        {
            r[used .. used + 3] = [cast(float) n[k].x, cast(float) n[k].y, cast(float) n[k].z];
            used += 3;
        }
    }
    return r[0 .. used];
}

/// The normal of every triangle, as long as twice its area.
private Vec3[] triangleNormals(const Mesh m)
{
    auto r = new Vec3[m.triangleCount];
    foreach (t; 0 .. m.triangleCount)
    {
        auto a = m.vertex(m.tris[t * 3]), b = m.vertex(m.tris[t * 3 + 1]), c = m.vertex(m.tris[t * 3 + 2]);
        r[t] = (b - a).cross(c - a);
    }
    return r;
}

private:

struct Camera
{
    Vec3 eye, right, up; // eye points from the model towards the viewer

    this(View v)
    {
        this(viewEye(v));
    }

    this(Vec3 e)
    {
        eye = e.normalized;
        auto worldUp = abs(eye.z) > 0.99 ? Vec3(0, eye.z > 0 ? 1 : -1, 0) : Vec3(0, 0, 1);
        right = worldUp.cross(eye).normalized;
        up = eye.cross(right);
    }

    /// x, y on the view plane; z grows towards the viewer
    Vec3 project(Vec3 p) const => Vec3(p.dot(right), p.dot(up), p.dot(eye));
}

public struct Canvas
{
    uint w, h;
    float[] color; // rgb
    float[] depth;
    float[] mask;  // edge coverage, before it is laid over the colours
    /// a close-up cut: what lies nearer the viewer than this is left out
    float nearest = float.infinity;

    this(uint w, uint h)
    {
        this.w = w;
        this.h = h;
        color = new float[w * h * 3];
        depth = new float[w * h];
    }

    void clear()
    {
        depth[] = -float.infinity;
        foreach (y; 0 .. h)
        {
            immutable t = cast(float) y / h; // soft vertical gradient
            foreach (x; 0 .. w)
                color[(y * w + x) * 3 .. (y * w + x) * 3 + 3] = [246 - 20 * t, 247 - 18 * t, 250 - 12 * t];
        }
    }

    /// A triangle lit per pixel: `shade` turns the interpolated normal into a colour.
    /// `pattern` 1 lays white diagonal stripes over it, 2 a cross-hatch,
    /// `period` pixels apart (as the window's printability style).
    void triangle(Vec3 a, Vec3 b, Vec3 c, Vec3 na, Vec3 nb, Vec3 nc, scope Vec3 delegate(Vec3) shade, double alpha = 1,
        int pattern = 0, double period = 10)
    {
        immutable area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
        if (abs(area) < 1e-12)
            return;
        immutable xs = max(0, cast(int) floor(min(a.x, b.x, c.x))), xe = min(cast(int) w - 1, cast(int) ceil(max(a.x, b.x, c.x)));
        immutable ys = max(0, cast(int) floor(min(a.y, b.y, c.y))), ye = min(cast(int) h - 1, cast(int) ceil(max(a.y, b.y, c.y)));
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
                immutable i = y * w + x;
                if (z <= depth[i] || z > nearest)
                    continue;
                auto colour = shade((na * w0 + nb * w1 + nc * w2).normalized);
                if (pattern)
                {
                    import std.math : fmod;
                    immutable band = 0.4 * period;
                    immutable on = fmod(x + y, period) < band || (pattern == 2 && fmod(x - y + 1e6 * period, period) < band);
                    if (on)
                        colour = colour * 0.4 + Vec3(255, 255, 255) * 0.6;
                }
                put(i, colour, alpha);
                if (alpha >= 1)
                    depth[i] = z;
            }
    }

    /// alpha < 1 blends over what is there, without hiding what comes later.
    void triangle(Vec3 a, Vec3 b, Vec3 c, Vec3 rgb, double alpha = 1)
    {
        immutable area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
        if (abs(area) < 1e-12)
            return;
        immutable xs = max(0, cast(int) floor(min(a.x, b.x, c.x))), xe = min(cast(int) w - 1, cast(int) ceil(max(a.x, b.x, c.x)));
        immutable ys = max(0, cast(int) floor(min(a.y, b.y, c.y))), ye = min(cast(int) h - 1, cast(int) ceil(max(a.y, b.y, c.y)));
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
                immutable i = y * w + x;
                if (z <= depth[i] || z > nearest)
                    continue;
                put(i, rgb, alpha);
                if (alpha >= 1)
                    depth[i] = z;
            }
    }

    /// The opaque parts' edges, laid over the image where they are sparse and
    /// faded where they crowd (a thread seen from afar would turn black): the
    /// fade follows how much of the area around (`ss` subpixels per pixel)
    /// is covered by edges.
    void drawEdges(Edges[] edges, Vec3 delegate(Vec3) toScreen, double width, double tolerance, uint ss)
    {
        mask = new float[w * h];
        mask[] = 0;
        foreach (ref e; edges)
            foreach (p; e.pairs)
                line(toScreen(e.mesh.vertex(p[0])), toScreen(e.mesh.vertex(p[1])), edgeColour, width, tolerance,
                    1, true);
        // coverage around each pixel, from a summed-area table
        immutable r = 4 * ss;
        auto sum = new double[(w + 1) * (h + 1)];
        sum[] = 0;
        foreach (y; 0 .. h)
        {
            double row = 0;
            foreach (x; 0 .. w)
            {
                row += mask[y * w + x];
                sum[(y + 1) * (w + 1) + x + 1] = sum[y * (w + 1) + x + 1] + row;
            }
        }
        foreach (y; 0 .. h)
            foreach (x; 0 .. w)
            {
                immutable i = y * w + x;
                if (mask[i] <= 0)
                    continue;
                immutable x0 = max(0, cast(int) x - cast(int) r), x1 = min(w, x + r + 1);
                immutable y0 = max(0, cast(int) y - cast(int) r), y1 = min(h, y + r + 1);
                immutable covered = (sum[y1 * (w + 1) + x1] - sum[y0 * (w + 1) + x1] - sum[y1 * (w + 1) + x0]
                    + sum[y0 * (w + 1) + x0]) / ((x1 - x0) * (y1 - y0));
                // full strength up to 30% of the area, a faint hatching from 65%
                immutable fade = clamp(1 - (covered - 0.3) / 0.35, 0.18, 1.0);
                put(i, edgeColour, mask[i] * fade);
            }
    }

    /// Depth-tested thick line; `tolerance` keeps edges on top of their faces.
    /// `toMask` records the coverage in `mask` instead of colouring.
    void line(Vec3 a, Vec3 b, Vec3 rgb, double width, double tolerance, double alpha = 1, bool toMask = false)
    {
        immutable len = sqrt((b.x - a.x) ^^ 2 + (b.y - a.y) ^^ 2);
        immutable steps = max(1, cast(int)(len * 2));
        immutable r = width / 2;
        foreach (s; 0 .. steps + 1)
        {
            immutable t = cast(double) s / steps;
            immutable x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t;
            foreach (yy; cast(int) floor(y - r) .. cast(int) ceil(y + r))
                foreach (xx; cast(int) floor(x - r) .. cast(int) ceil(x + r))
                {
                    if (xx < 0 || yy < 0 || xx >= w || yy >= h)
                        continue;
                    immutable i = yy * w + xx;
                    if (z < depth[i] - tolerance || z > nearest)
                        continue;
                    if (toMask)
                        mask[i] = 1;
                    else
                        put(i, rgb, alpha);
                }
        }
    }

    private void put(size_t i, Vec3 rgb, double alpha)
    {
        rgb = Vec3(min(rgb.x, 255.0), min(rgb.y, 255.0), min(rgb.z, 255.0));
        foreach (ch, v; [rgb.x, rgb.y, rgb.z])
            color[i * 3 + ch] = cast(float)(alpha >= 1 ? v : color[i * 3 + ch] * (1 - alpha) + v * alpha);
    }

    Image downsample(uint f)
    {
        auto img = Image(w / f, h / f, new ubyte[(w / f) * (h / f) * 3]);
        foreach (y; 0 .. img.height)
            foreach (x; 0 .. img.width)
                foreach (ch; 0 .. 3)
                {
                    float s = 0;
                    foreach (dy; 0 .. f)
                        foreach (dx; 0 .. f)
                            s += color[((y * f + dy) * w + x * f + dx) * 3 + ch];
                    img.rgb[(y * img.width + x) * 3 + ch] = cast(ubyte) min(255.0f, max(0.0f, s / (f * f)));
                }
        return img;
    }
}

unittest
{
    // a welded cube: 12 feature edges, rendered pixels differ from background
    Mesh m;
    m.verts = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1];
    m.tris = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7];
    assert(m.isClosed);
    assert(featureEdges(m, 25).length == 12);
    auto img = render([Shaded(m, 0xFF0000)], View.iso, 64, 64);
    auto centre = img.rgb[(32 * 64 + 32) * 3 .. (32 * 64 + 32) * 3 + 3];
    assert(centre[0] > centre[2]); // reddish, not background
}

unittest
{
    // a close-up: a 1 mm box framed fills the picture; cut away, a block in
    // front of it no longer hides it
    Mesh cube(double x0, double y0, double z0, double s)
    {
        Mesh m;
        foreach (k; 0 .. 8)
            m.verts ~= [cast(float)(x0 + (k & 1) * s), cast(float)(y0 + ((k >> 1) & 1) * s), cast(float)(z0 + ((k >> 2) & 1) * s)];
        m.tris = [0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6, 0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3, 0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5];
        return m;
    }
    auto small = cube(10, 0, 0, 1), wall = cube(9, -5, -1, 3);
    auto front = Shot.of(View.front).framing(Vec3(10, 0, 0), Vec3(11, 1, 1));
    auto img = render([Shaded(small, 0xFF0000)], front, 64, 64);
    size_t red;
    foreach (q; 0 .. 64 * 64)
        red += img.rgb[q * 3] > 150 && img.rgb[q * 3 + 2] < 120;
    assert(red > 64 * 64 / 3, "the box fills the picture");
    // the wall (y -5 … -2) stands between the viewer (-y) and the box: grey hides red, unless cut away
    auto hidden = render([Shaded(small, 0xFF0000), Shaded(wall, 0x808080)], front, 64, 64);
    auto seen = render([Shaded(small, 0xFF0000), Shaded(wall, 0x808080)], front.framing(Vec3(10, 0, 0), Vec3(11, 1, 1),
        true), 64, 64);
    size_t redHidden, redSeen;
    foreach (q; 0 .. 64 * 64)
    {
        redHidden += hidden.rgb[q * 3] > 150 && hidden.rgb[q * 3 + 2] < 120;
        redSeen += seen.rgb[q * 3] > 150 && seen.rgb[q * 3 + 2] < 120;
    }
    assert(redHidden < 50 && redSeen > 64 * 64 / 3, "cut away, the wall in front no longer hides the box");
    assert(Shot.of(View.front).toString == "from the front (-y), x to the right, z up");
}
