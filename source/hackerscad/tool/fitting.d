/// `hcad fit`: a copy's measures tuned to its original. The parameters
/// named (@param lengths of the model) are moved by the downhill simplex
/// method (Nelder and Mead) to make the volume where the copy and the
/// original differ as small as it goes.
module hackerscad.tool.fitting;

import std.algorithm : max, min, sort;
import std.format : format;
import std.math : abs, ceil;

import hackerscad.geom.mesh;
import hackerscad.geom.vec;
import hackerscad.geom.voxeldiff : mismatch;
import hackerscad.kernel.cache : CachingKernel;
import hackerscad.kernel.occt.backend : OcctKernel;
import hackerscad.tool.runner;

/// Tunes `params` of the model `file` so that part `a` matches part `b`;
/// `evaluations` at most. A report of the values found and how much closer
/// they bring the copy.
string fit(string file, string a, string b, string[] params, int evaluations, void delegate(string) progress = null)
{
    if (params.length == 0)
        throw new Exception("name the @param lengths to tune: --param name (several times)");
    auto cache = new CachingKernel(new OcctKernel);
    RunOptions base;
    base.path = file;
    base.cache = cache;
    auto first = evaluateModel(base);
    if (!first.ok)
        throw new Exception(first.renderedDiagnostics());
    // the starting values, in mm
    double[] x0;
    foreach (name; params)
    {
        bool found;
        foreach (p; first.result.params)
            if (p.name == name)
            {
                if (!p.value.isNum)
                    throw new Exception(format("@param %s is not a number", name));
                x0 ~= p.value.n.value;
                found = true;
            }
        if (!found)
            throw new Exception(format("the model has no @param %s", name));
    }
    immutable ib = first.partIndices([b], true)[0];
    auto original = first.partMeshes()[ib];
    // the grid: around the original, a little larger, cubes about 1/200 of its size
    Vec3 lo = original.vertex(0), hi = lo;
    foreach (i; 0 .. original.vertexCount)
    {
        auto p = original.vertex(i);
        lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z));
        hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z));
    }
    immutable size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z);
    immutable h = max(0.15, size / 250);
    lo = lo - Vec3(3, 3, 3);
    hi = hi + Vec3(3, 3, 3);

    int count;
    double cost(const double[] x)
    {
        count++;
        RunOptions o = base;
        o.overrides = null;
        foreach (i, name; params)
            o.overrides[name] = format("%.4f.mm", x[i]);
        auto run = evaluateModel(o);
        if (!run.ok)
            return double.infinity;
        try
        {
            immutable ia = run.partIndices([a], true)[0];
            return mismatch(run.partMeshes()[ia], original, h, lo, hi);
        }
        catch (Exception)
            return double.infinity;
    }

    // the simplex: the start and a step of 0.3 mm (or 5 %) along each parameter
    immutable n = params.length;
    double[][] pts = [x0.dup];
    foreach (i; 0 .. n)
    {
        auto p = x0.dup;
        p[i] += max(0.3, 0.05 * abs(x0[i]));
        pts ~= p;
    }
    double[] f;
    foreach (p; pts)
        f ~= cost(p);
    immutable startCost = f[0];
    while (count < evaluations)
    {
        // sorted, best first
        auto order = new size_t[n + 1];
        foreach (i, ref o; order)
            o = i;
        order.sort!((p, q) => f[p] < f[q]);
        double[][] sp;
        double[] sf;
        foreach (i; order)
        {
            sp ~= pts[i];
            sf ~= f[i];
        }
        pts = sp;
        f = sf;
        if (progress)
            progress(format("%d evaluations, the best %.2f mm³", count, f[0]));
        // small enough: the points within 0.005 mm of each other
        double spread = 0;
        foreach (p; pts[1 .. $])
            foreach (i; 0 .. n)
                spread = max(spread, abs(p[i] - pts[0][i]));
        if (spread < 0.005)
            break;
        auto centroid = new double[n];
        centroid[] = 0;
        foreach (p; pts[0 .. n])
            foreach (i; 0 .. n)
                centroid[i] += p[i] / n;
        double[] along(double t)
        {
            auto r = new double[n];
            foreach (i; 0 .. n)
                r[i] = centroid[i] + t * (pts[n][i] - centroid[i]);
            return r;
        }
        auto xr = along(-1);
        immutable fr = cost(xr);
        if (fr < f[0])
        {
            auto xe = along(-2);
            immutable fe = cost(xe);
            if (fe < fr)
            {
                pts[n] = xe;
                f[n] = fe;
            }
            else
            {
                pts[n] = xr;
                f[n] = fr;
            }
        }
        else if (fr < f[n - 1])
        {
            pts[n] = xr;
            f[n] = fr;
        }
        else
        {
            auto xc = along(fr < f[n] ? -0.5 : 0.5);
            immutable fc = cost(xc);
            if (fc < min(fr, f[n]))
            {
                pts[n] = xc;
                f[n] = fc;
            }
            else
            {
                // shrink towards the best
                foreach (k; 1 .. n + 1)
                {
                    foreach (i; 0 .. n)
                        pts[k][i] = pts[0][i] + 0.5 * (pts[k][i] - pts[0][i]);
                    f[k] = cost(pts[k]);
                }
            }
        }
    }
    size_t best;
    foreach (i; 1 .. f.length)
        if (f[i] < f[best])
            best = i;
    string s = format("fitted in %d evaluations, on cubes of %.2f mm: the parts differ by %.1f mm³, %.1f mm³ before\n",
        count, h, f[best], startCost) ~ verdict(startCost, f[best]);
    foreach (i, name; params)
        s ~= format("  %s: %.3f mm (was %.3f)\n", name, pts[best][i], x0[i]);
    s ~= "  as overrides:";
    foreach (i, name; params)
        s ~= format(" -D %s=%.2f.mm", name, pts[best][i]);
    return s ~ "\n";
}

/// What the fit says about the copy's shape: when the sizes take away little
/// of the difference, it is the shape that differs, and no size will fix it.
string verdict(double before, double after)
{
    if (before > 0 && after > 1 && after > 0.8 * before)
        return "  the sizes explain little of the difference: the shape itself differs (a surface revolved, tilted "
            ~ "or stepped where the copy has it straight); cut a section through the largest hcad_diff region, and "
            ~ "another away from it, before fitting again\n";
    return "";
}

unittest
{
    import std.algorithm : canFind;
    assert(verdict(139.4, 130.1).canFind("the shape itself differs"));
    assert(verdict(139.4, 20).length == 0);
    assert(verdict(0, 0).length == 0);
    assert(verdict(1.2, 0.9).length == 0);   // under 1 mm³: nothing left to explain
}
