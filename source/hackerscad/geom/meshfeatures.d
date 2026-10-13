/// What a triangle mesh is made of, for remodelling it exactly: its flat
/// faces, cylinders (holes and shafts), cones, spheres and partial
/// cylinders (roundings), and holes repeated on a circle or in a row.
/// Surfaces are told apart at sharp edges; a curved one is recognised from
/// its normals, which on a surface of revolution all cross its axis.
module hackerscad.geom.meshfeatures;

import std.algorithm : max, min, sort, map, sum, canFind;
import std.array : array;
import std.format : format;
import std.math : abs, acos, atan, atan2, ceil, cos, floor, isNaN, PI, round, sin, sqrt;

import hackerscad.geom.mesh;
import hackerscad.geom.vec;

/// The kinds of surface found.
enum Surface
{
    plane,
    cylinder,
    cone,
    sphere,
    curved,   /// none of the others (freeform, or several merged)
}

/// One surface of the mesh.
struct Feature
{
    Surface kind;
    double area = 0;
    size_t triangles;
    /// planes: the outward normal and the plane's distance from the origin along it;
    /// cylinders and cones: the axis (`point` on it, unit `axis`); spheres: the centre
    Vec3 normal, point, axis;
    double offset = 0;
    /// cylinders: the radius; cones: the radius at `from` and the half angle; spheres: the radius
    double radius = 0, halfAngle = 0;
    /// cylinders and cones: the extent along the axis from `point`; the angle covered around it
    double from = 0, to = 0, span = 0;
    bool hole;        /// its outside faces the axis (a hole, a pocket's rounded corner)
    double error = 0; /// how far the triangles' corners are from the fitted surface, at most
    Vec3 lo, hi;      /// bounding box

    bool full() const => span > 2 * PI - 0.3;
    double diameter() const => 2 * radius;
}

/// Holes or shafts of one size repeated: on a circle or in a row.
struct Pattern
{
    size_t[] members;   /// indices into the features
    bool circular;
    Vec3 center, axis;  /// circular: the circle's centre and axis
    double radius = 0;  /// circular: the radius of the circle of centres
    double step = 0;    /// circular: the angle between neighbours; a row: their distance
    Vec3 direction;     /// a row: along it
}

struct Analysis
{
    Feature[] features;
    Pattern[] patterns;
    Vec3 lo, hi;
    double tolerance = 0;
}

/// Analyses a closed or open mesh, in mm.
Analysis analyse(const Mesh input)
{
    Analysis r;
    auto m = input.welded(1e-5);
    immutable nt = m.triangleCount;
    if (nt == 0)
        return r;
    r.lo = r.hi = m.vertex(0);
    foreach (i; 0 .. m.vertexCount)
    {
        auto p = m.vertex(i);
        r.lo = Vec3(min(r.lo.x, p.x), min(r.lo.y, p.y), min(r.lo.z, p.z));
        r.hi = Vec3(max(r.hi.x, p.x), max(r.hi.y, p.y), max(r.hi.z, p.z));
    }
    immutable size = max(1.0, (r.hi - r.lo).length);
    r.tolerance = 1e-3 + 1e-5 * size;

    // per triangle: normal and area; edges and their two triangles
    auto normal = new Vec3[nt];
    auto area = new double[nt];
    foreach (t; 0 .. nt)
    {
        auto a = m.vertex(m.tris[3 * t]), b = m.vertex(m.tris[3 * t + 1]), c = m.vertex(m.tris[3 * t + 2]);
        auto cr = (b - a).cross(c - a);
        area[t] = cr.length / 2;
        normal[t] = area[t] > 0 ? cr / (2 * area[t]) : Vec3(0, 0, 0);
    }
    uint[][ulong] edgeTris;
    static ulong key(uint a, uint b) => a < b ? (cast(ulong) a << 32 | b) : (cast(ulong) b << 32 | a);
    foreach (t; 0 .. nt)
        foreach (k; 0 .. 3)
            edgeTris[key(m.tris[3 * t + k], m.tris[3 * t + (k + 1) % 3])] ~= cast(uint) t;

    // regions: triangles joined across edges that do not fold sharply (35°)
    immutable smooth = cos(35 * PI / 180), flat = cos(0.5 * PI / 180);
    auto region = new int[nt];
    region[] = -1;
    int regions;
    foreach (seed; 0 .. nt)
    {
        if (region[seed] >= 0 || area[seed] <= 0)
            continue;
        uint[] stack = [cast(uint) seed];
        region[seed] = regions;
        while (stack.length)
        {
            immutable t = stack[$ - 1];
            stack = stack[0 .. $ - 1];
            foreach (k; 0 .. 3)
            {
                auto other = edgeTris.get(key(m.tris[3 * t + k], m.tris[3 * t + (k + 1) % 3]), null);
                if (other.length != 2)
                    continue;   // an open or non-manifold edge stops a region
                immutable u = other[0] == t ? other[1] : other[0];
                if (region[u] >= 0 || area[u] <= 0 || normal[t].dot(normal[u]) < smooth)
                    continue;
                region[u] = regions;
                stack ~= u;
            }
        }
        regions++;
    }

    uint[][] members = new uint[][regions];
    foreach (t; 0 .. nt)
        if (region[t] >= 0)
            members[region[t]] ~= cast(uint) t;

    // triangles of `set` joined across edges for which `joins` holds, as groups
    uint[][] components(const uint[] set, bool delegate(uint, uint) joins)
    {
        bool[uint] inSet;
        foreach (t; set)
            inSet[t] = true;
        bool[uint] done;
        uint[][] out_;
        foreach (seed; set)
        {
            if (seed in done)
                continue;
            uint[] group, stack = [seed];
            done[seed] = true;
            while (stack.length)
            {
                immutable t = stack[$ - 1];
                stack = stack[0 .. $ - 1];
                group ~= t;
                foreach (k; 0 .. 3)
                {
                    auto other = edgeTris.get(key(m.tris[3 * t + k], m.tris[3 * t + (k + 1) % 3]), null);
                    if (other.length != 2)
                        continue;
                    immutable u = other[0] == t ? other[1] : other[0];
                    if (u in inSet && u !in done && joins(t, u))
                    {
                        done[u] = true;
                        stack ~= u;
                    }
                }
            }
            out_ ~= group;
        }
        return out_;
    }
    // a region that is no simple surface: planes and curves meeting without an edge (a rounded
    // bend): its largest flat part taken off, while it is a tenth of it or more, and the rest anew
    void process(uint[] g, int depth)
    {
        auto f = fit(m, g, normal, area, r.tolerance, flat);
        if (f.kind != Surface.curved || depth > 60)
        {
            if (f.area > 0)
                r.features ~= f;
            return;
        }
        auto flats = components(g, (a, b) => normal[a].dot(normal[b]) >= flat);
        size_t best;
        double bestArea = 0;
        foreach (i, c; flats)
        {
            double ar = 0;
            foreach (t; c)
                ar += area[t];
            if (ar > bestArea)
            {
                bestArea = ar;
                best = i;
            }
        }
        if (flats.length <= 1 || bestArea < 0.1 * f.area)
        {
            r.features ~= f;
            return;
        }
        r.features ~= fit(m, flats[best], normal, area, r.tolerance, flat);
        bool[uint] taken;
        foreach (t; flats[best])
            taken[t] = true;
        uint[] rest;
        foreach (t; g)
            if (t !in taken)
                rest ~= t;
        foreach (c; components(rest, (a, b) => normal[a].dot(normal[b]) >= smooth))
            process(c, depth + 1);
    }
    foreach (g; members)
        process(g, 0);
    r.features = mergeCylinders(r.features, r.tolerance);
    // largest first
    r.features.sort!((a, b) => a.area > b.area);
    r.patterns = patterns(r.features, r.tolerance);
    return r;
}

/// The surface a region of triangles lies on.
private Feature fit(const Mesh m, const uint[] tris, const Vec3[] normal, const double[] area, double tol, double flat)
{
    Feature f;
    f.triangles = tris.length;
    uint[] vs;
    bool[uint] seen;
    foreach (t; tris)
    {
        f.area += area[t];
        foreach (k; 0 .. 3)
        {
            immutable v = m.tris[3 * t + k];
            if (v !in seen)
            {
                seen[v] = true;
                vs ~= v;
            }
        }
    }
    auto pts = vs.map!(v => m.vertex(v)).array;
    f.lo = f.hi = pts[0];
    foreach (p; pts)
    {
        f.lo = Vec3(min(f.lo.x, p.x), min(f.lo.y, p.y), min(f.lo.z, p.z));
        f.hi = Vec3(max(f.hi.x, p.x), max(f.hi.y, p.y), max(f.hi.z, p.z));
    }
    // the area-weighted mean normal
    Vec3 mean;
    foreach (t; tris)
        mean = mean + normal[t] * area[t];
    // flat: every normal along the mean one
    bool planar = true;
    immutable mn = mean.length > 0 ? mean / mean.length : Vec3(0, 0, 1);
    foreach (t; tris)
        if (normal[t].dot(mn) < flat)
        {
            planar = false;
            break;
        }
    if (planar)
    {
        f.kind = Surface.plane;
        f.normal = mn;
        double d = 0;
        foreach (p; pts)
            d += p.dot(mn);
        f.offset = d / pts.length;
        foreach (p; pts)
            f.error = max(f.error, abs(p.dot(mn) - f.offset));
        return f;
    }

    // a sphere: the normals' lines all cross at its centre
    {
        Vec3 c;
        double err;
        if (crossing3(m, tris, normal, area, c, err))
        {
            double rs = 0;
            foreach (p; pts)
                rs += (p - c).length;
            rs /= pts.length;
            double worst = 0;
            foreach (p; pts)
                worst = max(worst, abs((p - c).length - rs));
            // the normals pass through the centre too (a cylinder's cross its axis, not one point)
            if (worst < max(tol * 20, rs * 0.02) && err < max(tol * 20, rs * 0.05) && rs > 0)
            {
                f.kind = Surface.sphere;
                f.point = c;
                f.radius = rs;
                f.error = worst;
                // inside or outside: the normals point away from the centre on a ball
                double out_ = 0;
                foreach (t; tris)
                    out_ += normal[t].dot(m.vertex(m.tris[3 * t]) - c) * area[t];
                f.hole = out_ < 0;
                return f;
            }
        }
    }

    // a surface of revolution: the axis is the direction the normals vary least along (the
    // smallest eigenvector of their covariance), and their lines cross it
    Vec3 nbar = mean / max(f.area, 1e-300);
    double[3][3] cov = 0;
    foreach (t; tris)
    {
        auto d = normal[t] - nbar;
        immutable double[3] v = [d.x, d.y, d.z];
        foreach (i; 0 .. 3)
            foreach (j; 0 .. 3)
                cov[i][j] += area[t] * v[i] * v[j];
    }
    auto axis = smallestEigenvector(cov);
    // the point of the axis: where the normals' lines, seen along it, cross
    Vec3 u = axis.cross(abs(axis.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)).normalized, w = axis.cross(u);
    double a11 = 0, a12 = 0, a22 = 0, b1 = 0, b2 = 0;
    foreach (t; tris)
    {
        auto c = (m.vertex(m.tris[3 * t]) + m.vertex(m.tris[3 * t + 1]) + m.vertex(m.tris[3 * t + 2])) / 3;
        immutable nx = normal[t].dot(u), ny = normal[t].dot(w), nl = sqrt(nx * nx + ny * ny);
        if (nl < 1e-6)
            continue;
        // the line through (cx, cy) along (nx, ny): its normal (-ny, nx); weighted by area
        immutable ex = -ny / nl, ey = nx / nl, cx = c.dot(u), cy = c.dot(w), wt = area[t] * nl;
        a11 += wt * ex * ex;
        a12 += wt * ex * ey;
        a22 += wt * ey * ey;
        immutable e = ex * cx + ey * cy;
        b1 += wt * ex * e;
        b2 += wt * ey * e;
    }
    immutable det = a11 * a22 - a12 * a12;
    if (abs(det) < 1e-12 * (a11 + a22) ^^ 2 + 1e-300)
        return curved(f);
    immutable px = (b1 * a22 - b2 * a12) / det, py = (a11 * b2 - a12 * b1) / det;
    auto origin = u * px + w * py;
    // radius against height along the axis: constant on a cylinder, linear on a cone
    double sh = 0, sr = 0, shh = 0, shr = 0;
    double hmin = double.infinity, hmax = -double.infinity;
    foreach (p; pts)
    {
        immutable h = (p - origin).dot(axis);
        auto radial = (p - origin) - axis * h;
        immutable rr = radial.length;
        sh += h;
        sr += rr;
        shh += h * h;
        shr += h * rr;
        hmin = min(hmin, h);
        hmax = max(hmax, h);
    }
    immutable n = pts.length;
    immutable varh = shh - sh * sh / n;
    immutable slope = varh > 1e-12 ? (shr - sh * sr / n) / varh : 0;
    immutable r0 = (sr - slope * sh) / n;
    double worst = 0;
    foreach (p; pts)
    {
        immutable h = (p - origin).dot(axis);
        immutable rr = ((p - origin) - axis * h).length;
        worst = max(worst, abs(rr - (r0 + slope * h)));
    }
    // a cylinder when the radius barely changes along it
    immutable isCylinder = abs(slope) < 0.01;
    immutable rmean = sr / n;
    if (!(rmean > 0) || worst > max(tol * 50, rmean * 0.03))
        return curved(f);
    f.axis = axis;
    f.point = origin + axis * hmin;
    f.from = 0;
    f.to = hmax - hmin;
    f.error = worst;
    // the angle covered: from the directions of the corners around the axis
    {
        double[] angles;
        foreach (p; pts)
        {
            auto radial = (p - origin) - axis * (p - origin).dot(axis);
            angles ~= atan2(radial.dot(w), radial.dot(u));
        }
        angles.sort();
        double gap = angles[0] + 2 * PI - angles[$ - 1];
        foreach (i; 1 .. angles.length)
            gap = max(gap, angles[i] - angles[i - 1]);
        // faceted: a full circle of k sides leaves gaps of 2π/k, not a missing arc
        f.span = 2 * PI - gap;
        if (gap < 2 * PI / 6 + 1e-6 && tris.length >= 6)
            f.span = 2 * PI;
    }
    // a hole: its outside faces the axis
    double outward = 0;
    foreach (t; tris)
    {
        auto c = m.vertex(m.tris[3 * t]);
        auto radial = (c - origin) - axis * (c - origin).dot(axis);
        outward += normal[t].dot(radial) * area[t];
    }
    f.hole = outward < 0;
    if (isCylinder)
    {
        f.kind = Surface.cylinder;
        f.radius = rmean;
    }
    else
    {
        f.kind = Surface.cone;
        f.radius = r0 + slope * hmin;
        f.halfAngle = atan(slope);
    }
    return f;
}

private Feature curved(Feature f)
{
    f.kind = Surface.curved;
    return f;
}

/// Where the normals' lines of the triangles cross in space (least
/// squares), and how far from it they pass at most. False when they do not
/// meet near one point.
private bool crossing3(const Mesh m, const uint[] tris, const Vec3[] normal, const double[] area, out Vec3 c, out double err)
{
    double[3][3] a = 0;
    double[3] b = 0;
    foreach (t; tris)
    {
        auto p = (m.vertex(m.tris[3 * t]) + m.vertex(m.tris[3 * t + 1]) + m.vertex(m.tris[3 * t + 2])) / 3;
        immutable double[3] n = [normal[t].x, normal[t].y, normal[t].z];
        immutable double[3] pp = [p.x, p.y, p.z];
        foreach (i; 0 .. 3)
            foreach (j; 0 .. 3)
            {
                immutable proj = (i == j ? 1 : 0) - n[i] * n[j];
                a[i][j] += area[t] * proj;
                b[i] += area[t] * proj * pp[j];
            }
    }
    double[3] x;
    if (!solve3(a, b, x))
        return false;
    c = Vec3(x[0], x[1], x[2]);
    err = 0;
    foreach (t; tris)
    {
        auto p = m.vertex(m.tris[3 * t]);
        auto d = c - p;
        err = max(err, (d - normal[t] * d.dot(normal[t])).length);
    }
    return true;
}

private bool solve3(double[3][3] a, double[3] b, out double[3] x)
{
    // Gaussian elimination with partial pivoting
    foreach (col; 0 .. 3)
    {
        size_t piv = col;
        foreach (r; col + 1 .. 3)
            if (abs(a[r][col]) > abs(a[piv][col]))
                piv = r;
        if (abs(a[piv][col]) < 1e-12)
            return false;
        if (piv != col)
        {
            auto t = a[piv];
            a[piv] = a[col];
            a[col] = t;
            immutable tb = b[piv];
            b[piv] = b[col];
            b[col] = tb;
        }
        foreach (r; col + 1 .. 3)
        {
            immutable f = a[r][col] / a[col][col];
            foreach (c; col .. 3)
                a[r][c] -= f * a[col][c];
            b[r] -= f * b[col];
        }
    }
    foreach_reverse (r; 0 .. 3)
    {
        double s = b[r];
        foreach (c; r + 1 .. 3)
            s -= a[r][c] * x[c];
        x[r] = s / a[r][r];
    }
    // a near-singular system (a cylinder's normals cross along a whole line) is not a point
    double scale = 0;
    foreach (i; 0 .. 3)
        scale = max(scale, abs(a[i][i]));
    foreach (i; 0 .. 3)
        if (abs(a[i][i]) < 1e-6 * scale)
            return false;
    return true;
}

/// The eigenvector of the smallest eigenvalue of a symmetric 3×3 matrix (Jacobi).
Vec3 smallestEigenvector(double[3][3] a)
{
    double[3][3] v = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
    foreach (sweep; 0 .. 50)
    {
        double off = abs(a[0][1]) + abs(a[0][2]) + abs(a[1][2]);
        if (off < 1e-15)
            break;
        foreach (p; 0 .. 2)
            foreach (q; p + 1 .. 3)
            {
                if (abs(a[p][q]) < 1e-300)
                    continue;
                immutable theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
                immutable t = (theta >= 0 ? 1 : -1) / (abs(theta) + sqrt(theta * theta + 1));
                immutable c = 1 / sqrt(t * t + 1), s = t * c;
                foreach (k; 0 .. 3)
                {
                    immutable akp = a[k][p], akq = a[k][q];
                    a[k][p] = c * akp - s * akq;
                    a[k][q] = s * akp + c * akq;
                }
                foreach (k; 0 .. 3)
                {
                    immutable apk = a[p][k], aqk = a[q][k];
                    a[p][k] = c * apk - s * aqk;
                    a[q][k] = s * apk + c * aqk;
                }
                foreach (k; 0 .. 3)
                {
                    immutable vkp = v[k][p], vkq = v[k][q];
                    v[k][p] = c * vkp - s * vkq;
                    v[k][q] = s * vkp + c * vkq;
                }
            }
    }
    size_t best = 0;
    foreach (i; 1 .. 3)
        if (a[i][i] < a[best][best])
            best = i;
    return Vec3(v[0][best], v[1][best], v[2][best]).normalized;
}

/// Pieces of one cylinder (a mesh can split it along a seam): the same axis
/// line, radius and side, overlapping along the axis; joined into one,
/// their angles added.
private Feature[] mergeCylinders(Feature[] fs, double tol)
{
    auto gone = new bool[fs.length];
    foreach (i; 0 .. fs.length)
    {
        if (gone[i] || fs[i].kind != Surface.cylinder)
            continue;
        foreach (j; i + 1 .. fs.length)
        {
            if (gone[j] || fs[j].kind != Surface.cylinder || fs[j].hole != fs[i].hole)
                continue;
            auto a = fs[i], b = fs[j];
            if (abs(a.radius - b.radius) > max(0.01, 0.005 * a.radius) || abs(abs(a.axis.dot(b.axis)) - 1) > 1e-4)
                continue;
            auto off = b.point - a.point;
            if ((off - a.axis * off.dot(a.axis)).length > max(0.02, 0.01 * a.radius))
                continue;
            // their extents along a's axis
            immutable s0 = a.from, s1 = a.to;
            double t0 = off.dot(a.axis) + (b.axis.dot(a.axis) > 0 ? b.from : -b.to);
            double t1 = off.dot(a.axis) + (b.axis.dot(a.axis) > 0 ? b.to : -b.from);
            if (t1 < s0 - 0.05 || t0 > s1 + 0.05)
                continue;
            // one cylinder: extent the union, angles summed (at most a full turn)
            immutable lo = min(s0, t0), hi = max(s1, t1);
            fs[i].point = a.point + a.axis * lo;
            fs[i].from = 0;
            fs[i].to = hi - lo;
            fs[i].span = min(2 * PI, a.span + b.span);
            fs[i].area = a.area + b.area;
            fs[i].triangles = a.triangles + b.triangles;
            fs[i].error = max(a.error, b.error);
            fs[i].lo = Vec3(min(a.lo.x, b.lo.x), min(a.lo.y, b.lo.y), min(a.lo.z, b.lo.z));
            fs[i].hi = Vec3(max(a.hi.x, b.hi.x), max(a.hi.y, b.hi.y), max(a.hi.z, b.hi.z));
            gone[j] = true;
        }
    }
    Feature[] r;
    foreach (i, f; fs)
        if (!gone[i])
            r ~= f;
    return r;
}

/// Full cylinders of one radius on parallel axes: on a circle, or in a row.
private Pattern[] patterns(const Feature[] fs, double tol)
{
    Pattern[] r;
    auto used = new bool[fs.length];
    foreach (i, f; fs)
    {
        if (used[i] || f.kind != Surface.cylinder || !f.full)
            continue;
        size_t[] group = [i];
        foreach (j; i + 1 .. fs.length)
        {
            auto g = fs[j];
            if (used[j] || g.kind != Surface.cylinder || !g.full || g.hole != f.hole)
                continue;
            if (abs(g.radius - f.radius) > max(0.02, 0.01 * f.radius) || abs(abs(g.axis.dot(f.axis)) - 1) > 1e-3)
                continue;
            group ~= j;
        }
        if (group.length < 2)
            continue;
        // the centres, seen along the axis; pieces of one hole (a slot across it splits it) count once
        auto ax = f.axis;
        Vec3 u = ax.cross(abs(ax.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)).normalized, w = ax.cross(u);
        Vec3 centre(size_t k)
        {
            auto p = fs[k].point;
            return p - ax * p.dot(ax);   // projected onto the plane through the origin
        }
        {
            size_t[] distinct;
            foreach (k; group)
            {
                bool same;
                foreach (q; distinct)
                    if ((centre(k) - centre(q)).length < max(0.05, 0.02 * f.radius))
                        same = true;
                if (!same)
                    distinct ~= k;
            }
            group = distinct;
        }
        if (group.length < 2)
            continue;
        Pattern p;
        p.axis = ax;
        if (group.length >= 3)
        {
            // a circle through the centres (algebraic fit)
            double[3][3] a = 0;
            double[3] b = 0;
            foreach (k; group)
            {
                auto c = centre(k);
                immutable x = c.dot(u), y = c.dot(w);
                immutable double[3] row = [x, y, 1];
                foreach (s; 0 .. 3)
                {
                    foreach (t; 0 .. 3)
                        a[s][t] += row[s] * row[t];
                    b[s] += row[s] * (x * x + y * y);
                }
            }
            double[3] sol;
            if (solve3(a, b, sol))
            {
                immutable cx = sol[0] / 2, cy = sol[1] / 2, rc = sqrt(max(0.0, sol[2] + cx * cx + cy * cy));
                double worst = 0;
                double[] angles;
                foreach (k; group)
                {
                    auto c = centre(k);
                    worst = max(worst, abs(sqrt((c.dot(u) - cx) ^^ 2 + (c.dot(w) - cy) ^^ 2) - rc));
                    angles ~= atan2(c.dot(w) - cy, c.dot(u) - cx);
                }
                if (rc > 1e-3 && worst < max(0.05, 0.01 * rc) && angles.length >= 3)
                {
                    angles.sort();
                    double stepMin = double.infinity;
                    foreach (k; 1 .. angles.length)
                        stepMin = min(stepMin, angles[k] - angles[k - 1]);
                    p.circular = true;
                    p.center = u * cx + w * cy + ax * fs[i].point.dot(ax);
                    p.radius = rc;
                    p.step = stepMin;
                }
            }
        }
        if (!p.circular)
        {
            // a row: the centres on a line, evenly spaced
            auto c0 = centre(group[0]);
            Vec3 far = c0;
            foreach (k; group)
                if ((centre(k) - c0).length > (far - c0).length)
                    far = centre(k);
            auto dir = (far - c0).normalized;
            double[] ts;
            bool line = true;
            foreach (k; group)
            {
                auto d = centre(k) - c0;
                if ((d - dir * d.dot(dir)).length > max(0.05, tol * 10))
                    line = false;
                ts ~= d.dot(dir);
            }
            if (!line)
                continue;
            ts.sort();
            immutable step = (ts[$ - 1] - ts[0]) / (ts.length - 1);
            foreach (k; 1 .. ts.length)
                if (abs(ts[k] - ts[k - 1] - step) > max(0.05, 0.01 * step))
                    line = false;
            if (!line)
                continue;
            p.direction = dir;
            p.step = step;
        }
        p.members = group;
        foreach (k; group)
            used[k] = true;
        r ~= p;
    }
    return r;
}

/// A measure rounded to what a designer would likely have typed: to the
/// tenth of a millimetre when it is that close, else to the hundredth.
double plausible(double v)
{
    foreach (per; [1.0, 2, 10, 20])   // steps of 1, 0.5, 0.1, 0.05: divided, so that 3.4 is 3.4
    {
        immutable q = round(v * per) / per;
        if (abs(q - v) < 0.012)
            return q;
    }
    return round(v * 100) / 100;
}

/// What a hole's diameter is likely for: an ISO clearance or tap drill.
string holeHint(double d)
{
    // ISO 273 medium clearance, and the tap drill (nominal less the coarse pitch)
    static immutable string[] names = ["M2", "M2.5", "M3", "M4", "M5", "M6", "M8", "M10", "M12"];
    static immutable double[] clearance = [2.4, 2.9, 3.4, 4.5, 5.5, 6.6, 9, 11, 13.5];
    static immutable double[] tap = [1.6, 2.05, 2.5, 3.3, 4.2, 5, 6.8, 8.5, 10.2];
    foreach (i, n; names)
    {
        if (abs(d - clearance[i]) < 0.06)
            return n ~ " clearance";
        if (abs(d - tap[i]) < 0.06)
            return n ~ " tap drill";
    }
    return null;
}

private string mm(double v)
{
    immutable p = plausible(v);
    return format("%g", p == 0 ? 0.0 : p);   // never "-0"
}
private string vec(Vec3 v) => format("(%s, %s, %s)", mm(v.x), mm(v.y), mm(v.z));

/// A short report, one surface a line, largest first; small curved
/// regions (text, knurling) are summed up.
string report(const Analysis a, size_t most = 40)
{
    string s = format("size %s × %s × %s mm, from %s\n", mm(a.hi.x - a.lo.x), mm(a.hi.y - a.lo.y), mm(a.hi.z - a.lo.z),
        vec(a.lo));
    size_t shown;
    double otherArea = 0;
    size_t others;
    bool[size_t] inPattern;
    foreach (p; a.patterns)
        foreach (k; p.members)
            inPattern[k] = true;
    foreach (i, f; a.features)
    {
        if (shown >= most)
        {
            others++;
            otherArea += f.area;
            continue;
        }
        immutable line = describe(f);
        if (line is null)
        {
            others++;
            otherArea += f.area;
            continue;
        }
        s ~= line ~ (i in inPattern ? " (in a pattern below)" : "") ~ "\n";
        shown++;
    }
    if (others)
        s ~= format("%d more small or freeform surfaces, %s mm² in all\n", others, mm(otherArea));
    foreach (p; a.patterns)
    {
        auto f = a.features[p.members[0]];
        immutable what = format("%d× %s ⌀%s", p.members.length, f.hole ? "hole" : "shaft", mm(f.diameter));
        if (p.circular)
            s ~= format("pattern: %s on a circle of radius %s around %s, axis %s, %s° apart\n", what, mm(p.radius),
                vec(p.center), vec(p.axis), mm(p.step * 180 / PI));
        else
            s ~= format("pattern: %s in a row along %s, %s mm apart\n", what, vec(p.direction), mm(p.step));
    }
    return s;
}

/// One line about a surface, or null for a small curved one.
string describe(const Feature f)
{
    final switch (f.kind)
    {
    case Surface.plane:
        return format("plane, normal %s, at %s mm along it, %s mm² (%s to %s)", vec(f.normal), mm(f.offset), mm(f.area),
            vec(f.lo), vec(f.hi));
    case Surface.cylinder:
        {
            immutable d = f.diameter;
            auto hint = f.hole && f.full ? holeHint(plausible(d)) : null;
            immutable kind = f.full ? (f.hole ? "hole" : "shaft") : (f.hole ? "inner rounding" : "rounding");
            immutable around = f.full ? "" : format(", %s° of it", mm(f.span * 180 / PI));
            return format("%s ⌀%s%s (measured %.3f), r %s, %s long, axis %s from %s%s", kind, mm(d),
                hint.length ? " = " ~ hint : "", d, mm(f.radius), mm(f.to - f.from), vec(f.axis), vec(f.point), around);
        }
    case Surface.cone:
        return format("cone (%s), ⌀%s at %s, half angle %s°, %s long, axis %s", f.hole ? "countersink or taper hole" : "taper",
            mm(f.diameter), vec(f.point), mm(abs(f.halfAngle) * 180 / PI), mm(f.to - f.from), vec(f.axis));
    case Surface.sphere:
        return format("sphere%s ⌀%s, centre %s", f.hole ? " (hollow)" : "", mm(f.diameter), vec(f.point));
    case Surface.curved:
        return f.area > 1 ? format("freeform surface, %s mm² (%s to %s)", mm(f.area), vec(f.lo), vec(f.hi)) : null;
    }
}

unittest
{
    // a plate 40 × 30 × 5 with four holes ⌀3.4 on a circle of radius 10, made of facets
    Mesh m;
    void quad(Vec3 a, Vec3 b, Vec3 c, Vec3 d)
    {
        immutable base = cast(uint) m.vertexCount;
        foreach (p; [a, b, c, d])
            m.verts ~= [cast(float) p.x, cast(float) p.y, cast(float) p.z];
        m.tris ~= [base, base + 1, base + 2, base, base + 2, base + 3];
    }
    // a faceted cylinder of 48 sides, outwards or inwards
    void cylinder(Vec3 c, double r, double h, bool hole)
    {
        enum k = 48;
        foreach (i; 0 .. k)
        {
            immutable a0 = 2 * PI * i / k, a1 = 2 * PI * (i + 1) / k;
            auto p0 = c + Vec3(r * cos(a0), r * sin(a0), 0), p1 = c + Vec3(r * cos(a1), r * sin(a1), 0);
            auto up = Vec3(0, 0, h);
            if (hole)
                quad(p1, p0, p0 + up, p1 + up);
            else
                quad(p0, p1, p1 + up, p0 + up);
        }
    }
    // the plate's faces (the holes only as walls: enough for the walls' recognition)
    quad(Vec3(-20, -15, 5), Vec3(20, -15, 5), Vec3(20, 15, 5), Vec3(-20, 15, 5));
    quad(Vec3(-20, -15, 0), Vec3(-20, 15, 0), Vec3(20, 15, 0), Vec3(20, -15, 0));
    foreach (i; 0 .. 4)
        cylinder(Vec3(10 * cos(PI / 2 * i), 10 * sin(PI / 2 * i), 0), 1.7, 5, true);
    cylinder(Vec3(30, 0, 0), 4, 12, false);
    auto a = analyse(m);
    size_t holes, shafts, planes;
    foreach (f; a.features)
    {
        if (f.kind == Surface.cylinder && f.hole)
        {
            holes++;
            assert(abs(f.radius - 1.7 * cos(PI / 48)) < 0.05 || abs(f.radius - 1.7) < 0.05, format("%s", f.radius));
            assert(abs(abs(f.axis.z) - 1) < 1e-6 && f.full && abs(f.to - 5) < 1e-6);
        }
        if (f.kind == Surface.cylinder && !f.hole)
            shafts++;
        if (f.kind == Surface.plane)
            planes++;
    }
    assert(holes == 4 && shafts == 1 && planes == 2, report(a));
    assert(a.patterns.length == 1 && a.patterns[0].circular && abs(a.patterns[0].radius - 10) < 1e-6
        && abs(a.patterns[0].step - PI / 2) < 1e-6, report(a));
    assert(holeHint(3.4) == "M3 clearance", holeHint(3.4));
    assert(plausible(3.3999) == 3.4, format("%s", plausible(3.3999)));
    assert(plausible(12.0004) == 12);
}
