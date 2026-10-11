/// A small nonlinear least-squares solver for sketch constraints.
///
/// The unknowns are a flat array of doubles; every constraint contributes one
/// or more residual equations that are zero when it holds. The solver runs
/// Levenberg–Marquardt with a numeric Jacobian, then studies the Jacobian at
/// the solution: its rank gives the degrees of freedom left, and the unknowns
/// outside its row space are the ones that can still move.
module hackerscad.sketch.solver;

import std.algorithm : max, min;
import std.math : abs, sqrt, isFinite;

/// Residuals of one constraint: writes `count` values into `r`.
struct Equation
{
    size_t count;
    void delegate(const(double)[] x, double[] r) eval;
}

struct SolveResult
{
    bool converged;
    double residual;       /// largest residual left
    size_t rank;
    size_t dof;            /// unknowns not fixed by the constraints
    bool[] free;           /// per unknown: can still move
    size_t[] conflicting;  /// equations whose removal makes the system solvable
    size_t iterations;
}

/// Solves in place, starting from the values already in `x`.
SolveResult solve(double[] x, const(Equation)[] eqs, double tolerance = 1e-9, size_t maxIterations = 300)
{
    SolveResult res;
    res.converged = minimize(x, eqs, tolerance, maxIterations, res.iterations, res.residual);
    auto j = jacobian(x, eqs);
    auto basis = rowBasis(j, x.length);
    res.rank = basis.length;
    res.dof = x.length - res.rank;
    res.free = new bool[x.length];
    foreach (i; 0 .. x.length)
    {
        double inSpan = 0;
        foreach (q; basis)
            inSpan += q[i] * q[i];
        res.free[i] = inSpan < 1 - 1e-6;
    }
    if (!res.converged)
        res.conflicting = findConflicts(x, eqs, tolerance);
    return res;
}

private:

size_t totalCount(const(Equation)[] eqs)
{
    size_t m;
    foreach (e; eqs)
        m += e.count;
    return m;
}

void residuals(const(double)[] x, const(Equation)[] eqs, double[] r)
{
    size_t o;
    foreach (e; eqs)
    {
        e.eval(x, r[o .. o + e.count]);
        o += e.count;
    }
}

double norm2(const(double)[] v)
{
    double s = 0;
    foreach (a; v)
        s += a * a;
    return s;
}

double maxAbs(const(double)[] v)
{
    double s = 0;
    foreach (a; v)
        s = max(s, abs(a));
    return s;
}

/// Rows = equations, columns = unknowns (central differences).
double[][] jacobian(const(double)[] x0, const(Equation)[] eqs)
{
    immutable m = totalCount(eqs), n = x0.length;
    auto j = new double[][](m, n);
    auto x = x0.dup;
    auto rp = new double[m], rm = new double[m];
    foreach (c; 0 .. n)
    {
        immutable h = 1e-6 * (1 + abs(x0[c]));
        x[c] = x0[c] + h;
        residuals(x, eqs, rp);
        x[c] = x0[c] - h;
        residuals(x, eqs, rm);
        x[c] = x0[c];
        foreach (r; 0 .. m)
            j[r][c] = (rp[r] - rm[r]) / (2 * h);
    }
    return j;
}

bool minimize(double[] x, const(Equation)[] eqs, double tolerance, size_t maxIterations, out size_t iterations,
    out double residual)
{
    immutable m = totalCount(eqs), n = x.length;
    auto r = new double[m];
    residuals(x, eqs, r);
    double cost = norm2(r);
    double lambda = 1e-3;
    auto trial = new double[n];
    auto rt = new double[m];
    foreach (it; 0 .. maxIterations)
    {
        iterations = it;
        if (maxAbs(r) < tolerance)
            break;
        auto j = jacobian(x, eqs);
        // normal equations (JᵀJ + λ·diag) δ = −Jᵀr
        auto a = new double[][](n, n);
        auto g = new double[n];
        foreach (p; 0 .. n)
        {
            double s = 0;
            foreach (k; 0 .. m)
                s += j[k][p] * r[k];
            g[p] = -s;
            foreach (q; p .. n)
            {
                double t = 0;
                foreach (k; 0 .. m)
                    t += j[k][p] * j[k][q];
                a[p][q] = a[q][p] = t;
            }
        }
        bool improved;
        foreach (attempt; 0 .. 12)
        {
            auto aa = new double[][](n, n);
            foreach (p; 0 .. n)
            {
                aa[p][] = a[p][];
                aa[p][p] += lambda * (a[p][p] + 1e-6);
            }
            auto delta = solveLinear(aa, g.dup);
            if (delta is null)
            {
                lambda *= 10;
                continue;
            }
            foreach (p; 0 .. n)
                trial[p] = x[p] + delta[p];
            residuals(trial, eqs, rt);
            immutable c = norm2(rt);
            if (isFinite(c) && c < cost)
            {
                x[] = trial[];
                r[] = rt[];
                cost = c;
                lambda = max(lambda / 3, 1e-12);
                improved = true;
                break;
            }
            lambda *= 4;
        }
        if (!improved)
            break;
    }
    residual = maxAbs(r);
    return residual < max(tolerance * 1e3, 1e-7);
}

/// Gaussian elimination with partial pivoting; null if singular.
double[] solveLinear(double[][] a, double[] b)
{
    immutable n = b.length;
    foreach (c; 0 .. n)
    {
        size_t p = c;
        foreach (r; c + 1 .. n)
            if (abs(a[r][c]) > abs(a[p][c]))
                p = r;
        if (abs(a[p][c]) < 1e-300)
            return null;
        if (p != c)
        {
            auto t = a[p];
            a[p] = a[c];
            a[c] = t;
            immutable tb = b[p];
            b[p] = b[c];
            b[c] = tb;
        }
        foreach (r; c + 1 .. n)
        {
            immutable f = a[r][c] / a[c][c];
            if (f == 0)
                continue;
            foreach (k; c .. n)
                a[r][k] -= f * a[c][k];
            b[r] -= f * b[c];
        }
    }
    auto x = new double[n];
    foreach_reverse (c; 0 .. n)
    {
        double s = b[c];
        foreach (k; c + 1 .. n)
            s -= a[c][k] * x[k];
        x[c] = s / a[c][c];
    }
    return x;
}

/// Orthonormal basis of the row space (modified Gram–Schmidt, rows scaled
/// to unit length first so that lengths and angles weigh the same).
double[][] rowBasis(double[][] j, size_t n)
{
    double[][] basis;
    foreach (row; j)
    {
        auto v = row.dup;
        immutable len = sqrt(norm2(v));
        if (len < 1e-12)
            continue;
        v[] /= len;
        foreach (pass; 0 .. 2)
            foreach (q; basis)
            {
                double d = 0;
                foreach (i; 0 .. n)
                    d += v[i] * q[i];
                v[] -= d * q[];
            }
        immutable rest = sqrt(norm2(v));
        if (rest < 1e-7)
            continue;
        v[] /= rest;
        basis ~= v;
    }
    return basis;
}

/// Constraints that, removed one at a time, let the rest be satisfied.
size_t[] findConflicts(const(double)[] x0, const(Equation)[] eqs, double tolerance)
{
    size_t[] r;
    foreach_reverse (skip; 0 .. eqs.length)
    {
        const(Equation)[] rest = eqs[0 .. skip] ~ eqs[skip + 1 .. $];
        auto x = x0.dup;
        size_t its;
        double res;
        if (minimize(x, rest, tolerance, 100, its, res))
            r ~= skip;
        if (r.length >= 6)
            break;
    }
    return r;
}

unittest
{
    import std.math : isClose;

    // a point on a circle of radius 5 around the origin, with x fixed at 3
    double[] x = [1, 1];
    Equation onCircle = Equation(1, (const(double)[] v, double[] r) { r[0] = sqrt(v[0] ^^ 2 + v[1] ^^ 2) - 5; });
    Equation fixX = Equation(1, (const(double)[] v, double[] r) { r[0] = v[0] - 3; });
    auto res = solve(x, [onCircle, fixX]);
    assert(res.converged && res.dof == 0);
    assert(isClose(x[0], 3, 1e-9) && isClose(x[1], 4, 1e-9));

    // only on the circle: one degree of freedom, both unknowns can move
    x = [1, 1];
    res = solve(x, [onCircle]);
    assert(res.converged && res.dof == 1 && res.free[0] && res.free[1]);

    // conflicting: x = 3 and x = 7
    Equation fix7 = Equation(1, (const(double)[] v, double[] r) { r[0] = v[0] - 7; });
    x = [1, 1];
    res = solve(x, [onCircle, fixX, fix7]);
    assert(!res.converged && res.conflicting.length >= 1);
}
