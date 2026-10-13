/// Where two solids differ, as pieces of material: both meshes filled into
/// a grid of small cubes (a ray up each column, inside between its
/// crossings), compared, and the cubes that differ grouped into regions:
/// material the copy lacks, and material it has too much of.
module hackerscad.geom.voxeldiff;

import std.algorithm : max, min, sort;
import std.math : ceil, floor, sqrt;

import hackerscad.geom.mesh;
import hackerscad.geom.vec;

/// One region where they differ.
struct Region
{
    bool missing;      /// in b and not in a (else in a and not in b)
    double volume = 0; /// mm³
    Vec3 lo, hi;       /// its box
    Vec3 centroid;
    double fill = 0;   /// its volume over its box's: near 1, it is a box
}

/// The regions where `a` (a copy) differs from `b` (the original), on cubes
/// of side `h`; regions thinner than two cubes or smaller than `minVolume`
/// are left out (an edge a hair off makes a skin, not a region).
Region[] differences(const Mesh a, const Mesh b, double h, double minVolume)
{
    Vec3 lo = Vec3(double.infinity, double.infinity, double.infinity), hi = -lo;
    foreach (m; [a, b])
        foreach (i; 0 .. m.vertexCount)
        {
            auto p = m.vertex(i);
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z));
            hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z));
        }
    lo = lo - Vec3(h, h, h);
    hi = hi + Vec3(h, h, h);
    immutable nx = cast(size_t) ceil((hi.x - lo.x) / h), ny = cast(size_t) ceil((hi.y - lo.y) / h),
        nz = cast(size_t) ceil((hi.z - lo.z) / h);
    auto fa = fillGrid(a, lo, h, nx, ny, nz), fb = fillGrid(b, lo, h, nx, ny, nz);
    size_t idx(size_t i, size_t j, size_t k) => (k * ny + j) * nx + i;

    // the cubes that differ: 1 missing in a, 2 extra in a; then two layers peeled off and put back,
    // which drops skins one or two cubes thick
    auto diff = new ubyte[nx * ny * nz];
    foreach (q; 0 .. diff.length)
        diff[q] = fa[q] == fb[q] ? 0 : fb[q] ? 1 : 2;
    auto core = diff.dup;
    foreach (k; 0 .. nz)
        foreach (j; 0 .. ny)
            foreach (i; 0 .. nx)
            {
                immutable q = idx(i, j, k);
                if (!diff[q])
                    continue;
                // kept only when its six neighbours differ the same way
                bool all = i > 0 && j > 0 && k > 0 && i + 1 < nx && j + 1 < ny && k + 1 < nz;
                if (all)
                    foreach (o; [idx(i - 1, j, k), idx(i + 1, j, k), idx(i, j - 1, k), idx(i, j + 1, k), idx(i, j, k - 1),
                            idx(i, j, k + 1)])
                        if (diff[o] != diff[q])
                            all = false;
                if (!all)
                    core[q] = 0;
            }

    // regions: grown from the core through every cube that differs the same way
    auto label = new int[diff.length];
    label[] = -1;
    Region[] r;
    foreach (k; 0 .. nz)
        foreach (j; 0 .. ny)
            foreach (i; 0 .. nx)
            {
                immutable q0 = idx(i, j, k);
                if (!core[q0] || label[q0] >= 0)
                    continue;
                immutable kind = diff[q0];
                immutable id = cast(int) r.length;
                Region g;
                g.missing = kind == 1;
                g.lo = Vec3(double.infinity, double.infinity, double.infinity);
                g.hi = -g.lo;
                Vec3 sum;
                size_t count;
                size_t[] stack = [q0];
                label[q0] = id;
                while (stack.length)
                {
                    immutable q = stack[$ - 1];
                    stack = stack[0 .. $ - 1];
                    immutable ii = q % nx, jj = (q / nx) % ny, kk = q / (nx * ny);
                    auto c = lo + Vec3((ii + 0.5) * h, (jj + 0.5) * h, (kk + 0.5) * h);
                    g.lo = Vec3(min(g.lo.x, c.x - h / 2), min(g.lo.y, c.y - h / 2), min(g.lo.z, c.z - h / 2));
                    g.hi = Vec3(max(g.hi.x, c.x + h / 2), max(g.hi.y, c.y + h / 2), max(g.hi.z, c.z + h / 2));
                    sum = sum + c;
                    count++;
                    void visit(size_t o)
                    {
                        if (diff[o] == kind && label[o] < 0)
                        {
                            label[o] = id;
                            stack ~= o;
                        }
                    }
                    if (ii > 0) visit(q - 1);
                    if (ii + 1 < nx) visit(q + 1);
                    if (jj > 0) visit(q - nx);
                    if (jj + 1 < ny) visit(q + nx);
                    if (kk > 0) visit(q - nx * ny);
                    if (kk + 1 < nz) visit(q + nx * ny);
                }
                g.volume = count * h * h * h;
                g.centroid = sum / count;
                auto box = g.hi - g.lo;
                g.fill = g.volume / max(1e-12, box.x * box.y * box.z);
                r ~= g;
            }
    Region[] kept;
    foreach (g; r)
        if (g.volume >= minVolume)
            kept ~= g;
    kept.sort!((x, y) => x.volume > y.volume);
    return kept;
}

/// Which cubes of the grid are inside the closed mesh: along each column, a
/// ray up from below, inside between its first and second crossing, third
/// and fourth…
private bool[] fillGrid(const Mesh m, Vec3 lo, double h, size_t nx, size_t ny, size_t nz)
{
    auto inside = new bool[nx * ny * nz];
    // the crossings of each column, from every triangle over it
    auto zs = new double[][nx * ny];
    // the columns go through cube centres, nudged off so that no ray runs exactly along an edge
    immutable ox = lo.x + 0.5 * h + 1.234e-5 * h, oy = lo.y + 0.5 * h + 2.345e-5 * h;
    foreach (t; 0 .. m.triangleCount)
    {
        auto p0 = m.vertex(m.tris[3 * t]), p1 = m.vertex(m.tris[3 * t + 1]), p2 = m.vertex(m.tris[3 * t + 2]);
        immutable x0 = min(p0.x, p1.x, p2.x), x1 = max(p0.x, p1.x, p2.x);
        immutable y0 = min(p0.y, p1.y, p2.y), y1 = max(p0.y, p1.y, p2.y);
        immutable i0 = cast(long) ceil((x0 - ox) / h), i1 = cast(long) floor((x1 - ox) / h);
        immutable j0 = cast(long) ceil((y0 - oy) / h), j1 = cast(long) floor((y1 - oy) / h);
        immutable den = (p1.y - p2.y) * (p0.x - p2.x) + (p2.x - p1.x) * (p0.y - p2.y);
        if (den == 0)
            continue;   // seen edge on from above: no column crosses it
        foreach (j; max(0, j0) .. min(cast(long) ny - 1, j1) + 1)
            foreach (i; max(0, i0) .. min(cast(long) nx - 1, i1) + 1)
            {
                immutable x = ox + i * h, y = oy + j * h;
                immutable w0 = ((p1.y - p2.y) * (x - p2.x) + (p2.x - p1.x) * (y - p2.y)) / den;
                immutable w1 = ((p2.y - p0.y) * (x - p2.x) + (p0.x - p2.x) * (y - p2.y)) / den;
                immutable w2 = 1 - w0 - w1;
                if (w0 < 0 || w1 < 0 || w2 < 0)
                    continue;
                zs[j * nx + i] ~= w0 * p0.z + w1 * p1.z + w2 * p2.z;
            }
    }
    foreach (j; 0 .. ny)
        foreach (i; 0 .. nx)
        {
            auto z = zs[j * nx + i];
            if (z.length < 2)
                continue;
            z.sort();
            for (size_t c = 0; c + 1 < z.length; c += 2)
            {
                immutable k0 = cast(long) ceil((z[c] - lo.z) / h - 0.5), k1 = cast(long) floor((z[c + 1] - lo.z) / h - 0.5);
                foreach (k; max(0, k0) .. min(cast(long) nz - 1, k1) + 1)
                    inside[(k * ny + j) * nx + i] = true;
            }
        }
    return inside;
}

unittest
{
    import std.math : abs;
    // a 10 mm cube against the same cube with a 4 × 4 × 10 notch cut out of a corner
    Mesh cube(double x0, double y0, double z0, double x1, double y1, double z1)
    {
        Mesh m;
        foreach (k; 0 .. 8)
            m.verts ~= [cast(float)(k & 1 ? x1 : x0), cast(float)(k & 2 ? y1 : y0), cast(float)(k & 4 ? z1 : z0)];
        m.tris = [0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6, 0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3, 0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5];
        return m;
    }
    auto whole = cube(0, 0, 0, 10, 10, 10);
    // the notched one as two blocks: 10 × 6 × 10 and 6 × 4 × 10
    auto notched = cube(0, 0, 0, 10, 6, 10);
    auto second = cube(0, 6, 0, 6, 10, 10);
    immutable base = cast(uint) notched.vertexCount;
    notched.verts ~= second.verts;
    foreach (t; second.tris)
        notched.tris ~= base + t;
    auto r = differences(notched, whole, 0.25, 1);
    assert(r.length == 1 && r[0].missing, "one region missing");
    assert(abs(r[0].volume - 160) < 160 * 0.1, "its volume");
    assert(abs(r[0].lo.x - 6) < 0.3 && abs(r[0].hi.y - 10) < 0.3 && r[0].fill > 0.8, "its box");
}
