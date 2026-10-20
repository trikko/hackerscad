/// Noise for textures: simplex noise in 3D (values in -1…1, features about
/// one unit across), cellular noise (the distances to the nearest of points
/// scattered about one per unit: cells, and their borders), layered octaves
/// of either, and the same sampled round a loop, so that a pattern closes on
/// itself without a seam on any outline.
module hackerscad.geom.noise;

import std.math : PI, abs, cos, floor, sin, sqrt;

/// Simplex noise at (x, y, z) for `seed`: smooth, about -1…1, the same for
/// the same arguments everywhere.
double simplex(double x, double y, double z, long seed = 0)
{
    auto perm = permutation(seed);
    // skew into the grid of simplices, find the cell and the corner order
    enum F3 = 1.0 / 3, G3 = 1.0 / 6;
    immutable s = (x + y + z) * F3;
    immutable i = cast(long) floor(x + s), j = cast(long) floor(y + s), k = cast(long) floor(z + s);
    immutable t = (i + j + k) * G3;
    immutable x0 = x - (i - t), y0 = y - (j - t), z0 = z - (k - t);
    int i1, j1, k1, i2, j2, k2;
    if (x0 >= y0)
    {
        if (y0 >= z0) { i1 = 1; i2 = 1; j2 = 1; }
        else if (x0 >= z0) { i1 = 1; i2 = 1; k2 = 1; }
        else { k1 = 1; i2 = 1; k2 = 1; }
    }
    else
    {
        if (y0 < z0) { k1 = 1; j2 = 1; k2 = 1; }
        else if (x0 < z0) { j1 = 1; j2 = 1; k2 = 1; }
        else { j1 = 1; i2 = 1; j2 = 1; }
    }
    immutable double[4] cx = [x0, x0 - i1 + G3, x0 - i2 + 2 * G3, x0 - 1 + 3 * G3];
    immutable double[4] cy = [y0, y0 - j1 + G3, y0 - j2 + 2 * G3, y0 - 1 + 3 * G3];
    immutable double[4] cz = [z0, z0 - k1 + G3, z0 - k2 + 2 * G3, z0 - 1 + 3 * G3];
    immutable int[4] di = [0, i1, i2, 1], dj = [0, j1, j2, 1], dk = [0, k1, k2, 1];
    double total = 0;
    foreach (c; 0 .. 4)
    {
        // each corner's falloff times its gradient's slope towards the point
        double f = 0.6 - cx[c] * cx[c] - cy[c] * cy[c] - cz[c] * cz[c];
        if (f <= 0)
            continue;
        immutable g = perm[(i + di[c] + perm[(j + dj[c] + perm[(k + dk[c]) & 255]) & 255]) & 255] % 12;
        f *= f;
        total += f * f * (gradients[g][0] * cx[c] + gradients[g][1] * cy[c] + gradients[g][2] * cz[c]);
    }
    return 32 * total;
}

/// The kinds of noise: smooth (simplex, about -1…1), cells (0 at the points
/// the cells grow from, about 1 farthest from them), edges (0 on the borders
/// between cells, rising inside them), ridged (1 on sharp ridges, falling to
/// 0 between them).
enum NoiseKind { smooth, cells, edges, ridged }

/// The distances from (x, y, z) to the nearest and the second nearest of the
/// points scattered one in each unit cube for `seed`.
void cellDistances(double x, double y, double z, long seed, out double f1, out double f2)
{
    immutable i = cast(long) floor(x), j = cast(long) floor(y), k = cast(long) floor(z);
    double d1 = double.infinity, d2 = double.infinity;
    foreach (di; -1 .. 2)
        foreach (dj; -1 .. 2)
            foreach (dk; -1 .. 2)
            {
                ulong h = hash3(i + di, j + dj, k + dk, seed);
                immutable px = i + di + unit(h), py = j + dj + unit(h), pz = k + dk + unit(h);
                immutable d = sqrt((px - x) ^^ 2 + (py - y) ^^ 2 + (pz - z) ^^ 2);
                if (d < d1)
                {
                    d2 = d1;
                    d1 = d;
                }
                else if (d < d2)
                    d2 = d;
            }
    f1 = d1;
    f2 = d2;
}

/// Noise of `kind` at (x, y, z): `octaves` layers, each twice as fine and
/// half as strong as the one before, in the same range as one.
double noiseOf(NoiseKind kind, double x, double y, double z, long seed = 0, int octaves = 1)
{
    double one(double a, double b, double c, long sd)
    {
        final switch (kind)
        {
        case NoiseKind.smooth:
            return simplex(a, b, c, sd);
        case NoiseKind.ridged:
            return 1 - abs(simplex(a, b, c, sd));
        case NoiseKind.cells:
        case NoiseKind.edges:
            double f1, f2;
            cellDistances(a, b, c, sd, f1, f2);
            immutable v = kind == NoiseKind.cells ? f1 : f2 - f1;
            return v > 1 ? 1 : v;
        }
    }
    double total = 0, weight = 0, amp = 1, freq = 1;
    foreach (o; 0 .. octaves < 1 ? 1 : octaves)
    {
        total += amp * one(x * freq, y * freq, z * freq, seed + o * 1013);
        weight += amp;
        amp /= 2;
        freq *= 2;
    }
    return total / weight;
}

/// Noise round a loop: `around` 0…1 once round it (0 and 1 the same point),
/// `along` across it (up a wall), both in about `bumps` features round the
/// loop. Sampled on a circle in 3D noise, so it has no seam where it closes.
double loopNoise(double around, double along, double bumps = 4, long seed = 0,
    NoiseKind kind = NoiseKind.smooth, int octaves = 1)
{
    // a circle `bumps` units round: features about one unit across; `around` taken round to 0…1 first,
    // so 1 is 0 exactly (cos and sin of 2π are not 1 and 0 to the last bit, and the cells' noise jumps
    // across a border: on macOS the two ends came out apart)
    immutable r = bumps / (2 * PI), a = 2 * PI * (around - floor(around));
    return noiseOf(kind, r * cos(a), r * sin(a), along, seed, octaves);
}

private:

ulong hash3(long i, long j, long k, long seed)
{
    ulong h = cast(ulong) seed * 0x9E3779B97F4A7C15UL;
    h ^= cast(ulong) i * 0xBF58476D1CE4E5B9UL;
    h ^= cast(ulong) j * 0x94D049BB133111EBUL;
    h ^= cast(ulong) k * 0xD6E8FEB86659FD93UL;
    return h;
}

/// The next number in 0…1 from `h` (splitmix64), moving it on.
double unit(ref ulong h)
{
    h += 0x9E3779B97F4A7C15UL;
    ulong z = h;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
    z ^= z >> 31;
    return (z >> 11) * (1.0 / (1UL << 53));
}

// the 12 edge midpoints of a cube: directions the gradients take
immutable int[3][12] gradients = [[1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0], [1, 0, 1], [-1, 0, 1], [1, 0, -1],
    [-1, 0, -1], [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1]];

/// 0…255 shuffled by the seed (a small fast generator: the same table for a seed everywhere).
ubyte[256] permutation(long seed)
{
    static long lastSeed = long.min;
    static ubyte[256] last;
    if (seed == lastSeed)
        return last;
    ubyte[256] p;
    foreach (i; 0 .. 256)
        p[i] = cast(ubyte) i;
    ulong state = cast(ulong) seed * 0x9E3779B97F4A7C15UL + 0x632BE59BD9B4E019UL;
    ulong next()
    {
        // xorshift64*
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        return state * 0x2545F4914F6CDD1DUL;
    }
    foreach_reverse (i; 1 .. 256)
    {
        immutable j = cast(size_t)(next() % (i + 1));
        immutable tmp = p[i];
        p[i] = p[j];
        p[j] = tmp;
    }
    lastSeed = seed;
    last = p;
    return p;
}

unittest
{
    import std.math : abs;
    // the same for the same arguments, different for another seed, within -1…1
    assert(simplex(1.3, 2.7, -0.4, 5) == simplex(1.3, 2.7, -0.4, 5));
    assert(simplex(1.3, 2.7, -0.4, 5) != simplex(1.3, 2.7, -0.4, 6));
    double lo = 1, hi = -1, sum = 0;
    foreach (i; 0 .. 4000)
    {
        immutable v = simplex(i * 0.137, i * 0.071, i * 0.053, 3);
        assert(v >= -1.0001 && v <= 1.0001);
        lo = v < lo ? v : lo;
        hi = v > hi ? v : hi;
        sum += v;
    }
    // it uses the range, and averages near zero
    assert(lo < -0.5 && hi > 0.5 && abs(sum / 4000) < 0.1);
    // smooth: close points, close values
    assert(abs(simplex(0.5, 0.5, 0.5) - simplex(0.501, 0.5, 0.5)) < 0.02);
    // round a loop: no seam where it closes
    assert(abs(loopNoise(0, 2.5, 6, 1) - loopNoise(1, 2.5, 6, 1)) < 1e-9);
    assert(abs(loopNoise(0.999, 2.5, 6, 1) - loopNoise(0.001, 2.5, 6, 1)) < 0.05);

    // cells: 0 at a cell's point, within 0…1; edges: 0 on a border; ridged within 0…1
    double cmin = 1, cmax = 0;
    foreach (i; 0 .. 2000)
    {
        immutable c = noiseOf(NoiseKind.cells, i * 0.131, i * 0.067, i * 0.029, 2);
        immutable e = noiseOf(NoiseKind.edges, i * 0.131, i * 0.067, i * 0.029, 2);
        immutable r = noiseOf(NoiseKind.ridged, i * 0.131, i * 0.067, i * 0.029, 2, 3);
        assert(c >= 0 && c <= 1 && e >= 0 && e <= 1 && r >= 0 && r <= 1.0001);
        cmin = c < cmin ? c : cmin;
        cmax = c > cmax ? c : cmax;
    }
    assert(cmin < 0.15 && cmax > 0.6);
    // octaves stay in the range and differ from one layer
    assert(abs(noiseOf(NoiseKind.smooth, 0.3, 0.7, 0.1, 1, 4)) <= 1.0001);
    assert(noiseOf(NoiseKind.smooth, 0.3, 0.7, 0.1, 1, 4) != simplex(0.3, 0.7, 0.1, 1));
    assert(abs(loopNoise(0, 1.5, 5, 3, NoiseKind.edges) - loopNoise(1, 1.5, 5, 3, NoiseKind.edges)) < 1e-9);
}
