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

struct Shaded
{
    Mesh mesh;   /// welded mesh: edges are detected from shared vertices
    uint rgb = defaultPartColor;
    /// Optional: the kernel's tessellation, one vertex set per B-rep face.
    /// Its normals are smoothed inside each face (as in the 3D view), so
    /// curved faces are not faceted.
    Mesh faces;
}

/// The lighting of the 3D view (its fragment shader), for a view direction
/// v (towards the viewer): ambient, diffuse from a light a little above the
/// viewer, and a highlight.
Vec3 viewLighting(Vec3 n, Vec3 v, Vec3 base)
{
    import std.math : pow;
    if (n.dot(v) < 0)
        n = -n;   // two-sided: open meshes still look solid
    immutable l = (v + Vec3(0, 0, 0.6)).normalized;
    immutable diffuse = max(0.0, n.dot(l));
    immutable specular = pow(max(0.0, n.dot((l + v).normalized)), 48.0) * 0.22;
    return base * (0.34 + 0.66 * diffuse) + Vec3(255, 255, 255) * specular;
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
Image render(const Shaded[] items, View view, uint width, uint height)
{
    enum ss = 3; // supersampling factor
    auto c = Canvas(width * ss, height * ss);
    c.clear();

    auto cam = Camera(view);
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

    immutable margin = 0.08;
    immutable k = min(c.w * (1 - 2 * margin) / max(x1 - x0, 1e-9), c.h * (1 - 2 * margin) / max(y1 - y0, 1e-9));
    immutable ox = c.w / 2.0 - k * (x0 + x1) / 2, oy = c.h / 2.0 + k * (y0 + y1) / 2;
    Vec3 toScreen(Vec3 p)
    {
        auto q = cam.project(p);
        return Vec3(ox + k * q.x, oy - k * q.y, q.z);
    }


    // opaque parts first, then the see-through ones blended over them
    immutable edgeTolerance = 0.004 * max(z1 - z0, 1e-6);
    Edges[] opaqueEdges;
    foreach (see; [false, true])
    {
        if (see && opaqueEdges.length)
            c.drawEdges(opaqueEdges, &toScreen, ss * 1.1, edgeTolerance, ss);
        foreach (it; items)
        {
            immutable alpha = alphaOf(it.rgb);
            if ((alpha < 0.999) != see)
                continue;
            immutable base = Vec3((it.rgb >> 16) & 0xFF, (it.rgb >> 8) & 0xFF, it.rgb & 0xFF);
            auto m = it.mesh;
            Vec3 light(Vec3 n) => viewLighting(n, cam.eye, base);
            if (it.faces.triangleCount)
            {
                // smooth inside each face, as in the 3D view
                auto f = it.faces;
                auto normals = vertexNormals(f);
                foreach (t; 0 .. f.triangleCount)
                {
                    auto ia = f.tris[t * 3], ib = f.tris[t * 3 + 1], ic = f.tris[t * 3 + 2];
                    c.triangle(toScreen(f.vertex(ia)), toScreen(f.vertex(ib)), toScreen(f.vertex(ic)),
                        normals[ia], normals[ib], normals[ic], &light, alpha);
                }
            }
            else
                foreach (t; 0 .. m.triangleCount)
                {
                    auto a = m.vertex(m.tris[t * 3]), b = m.vertex(m.tris[t * 3 + 1]), d = m.vertex(m.tris[t * 3 + 2]);
                    auto n = (b - a).cross(d - a).normalized;
                    c.triangle(toScreen(a), toScreen(b), toScreen(d), n, n, n, &light, alpha);
                }
            // the opaque parts' edges go to a mask, drawn once all their faces
            // are in the depth buffer; see-through parts draw theirs faintly
            if (see)
                foreach (e; featureEdges(m, 25))
                    c.line(toScreen(m.vertex(e[0])), toScreen(m.vertex(e[1])), edgeColour, ss * 1.1, edgeTolerance,
                        0.15);   // a thick line blends each pixel several times
            else
                opaqueEdges ~= Edges(m, featureEdges(m, 25));
        }
    }

    return c.downsample(ss);
}

/// Several views side by side in a grid (left to right, top to bottom).
Image renderSheet(const Shaded[] items, const View[] views, uint cell, uint columns = 2)
{
    immutable rows = cast(uint)((views.length + columns - 1) / columns);
    Image sheet = Image(cell * columns, cell * rows, new ubyte[cell * columns * cell * rows * 3]);
    sheet.rgb[] = 255;
    foreach (i, v; views)
    {
        auto img = render(items, v, cell, cell);
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
    auto normals = triangleNormals(m);
    foreach (ref n; normals)
        n = n.normalized;
    size_t[][ulong] faces;
    foreach (t; 0 .. m.triangleCount)
        foreach (k; 0 .. 3)
        {
            ulong a = m.tris[t * 3 + k], b = m.tris[t * 3 + (k + 1) % 3];
            faces[min(a, b) << 32 | max(a, b)] ~= t;
        }
    foreach (key, ts; faces)
    {
        immutable a = cast(uint)(key >> 32), b = cast(uint)(key & 0xffff_ffff);
        if (ts.length != 2 || normals[ts[0]].dot(normals[ts[1]]) < limit)
            sharp ~= [a, b];
        else
        {
            immutable f0 = m.faceOf(ts[0]), f1 = m.faceOf(ts[1]);
            if (f0 != f1 && f0 >= 0 && f1 >= 0)
                tangent ~= [a, b];
        }
    }
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
    auto around = new uint[][m.vertexCount];
    foreach (t; 0 .. m.triangleCount)
        foreach (k; 0 .. 3)
            around[m.tris[t * 3 + k]] ~= cast(uint) t;
    float[] r;
    foreach (t; 0 .. m.triangleCount)
    {
        Vec3[3] n;
        foreach (k; 0 .. 3)
        {
            Vec3 sum;
            foreach (o; around[m.tris[t * 3 + k]])
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
            r ~= [cast(float) p.x, cast(float) p.y, cast(float) p.z];
        }
        foreach (k; 0 .. 3)
            r ~= [cast(float) n[k].x, cast(float) n[k].y, cast(float) n[k].z];
    }
    return r;
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
        final switch (v)
        {
        case View.iso: eye = Vec3(1, -1.25, 0.95); break;
        case View.front: eye = Vec3(0, -1, 0); break;
        case View.back: eye = Vec3(0, 1, 0); break;
        case View.top: eye = Vec3(0, 0, 1); break;
        case View.bottom: eye = Vec3(0, 0, -1); break;
        case View.left: eye = Vec3(-1, 0, 0); break;
        case View.right: eye = Vec3(1, 0, 0); break;
        }
        eye = eye.normalized;
        auto worldUp = abs(eye.z) > 0.99 ? Vec3(0, eye.z > 0 ? 1 : -1, 0) : Vec3(0, 0, 1);
        right = worldUp.cross(eye).normalized;
        up = eye.cross(right);
    }

    /// x, y on the view plane; z grows towards the viewer
    Vec3 project(Vec3 p) const => Vec3(p.dot(right), p.dot(up), p.dot(eye));
}

struct Canvas
{
    uint w, h;
    float[] color; // rgb
    float[] depth;
    float[] mask;  // edge coverage, before it is laid over the colours

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
    void triangle(Vec3 a, Vec3 b, Vec3 c, Vec3 na, Vec3 nb, Vec3 nc, scope Vec3 delegate(Vec3) shade, double alpha = 1)
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
                if (z <= depth[i])
                    continue;
                put(i, shade((na * w0 + nb * w1 + nc * w2).normalized), alpha);
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
                if (z <= depth[i])
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
                    if (z < depth[i] - tolerance)
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
