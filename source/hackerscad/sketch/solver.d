/// A small nonlinear least-squares solver for sketch constraints.
///
/// The unknowns are a flat array of doubles; every constraint contributes one
/// or more residual equations that are zero when it holds. The solver runs
/// Levenberg–Marquardt with a numeric Jacobian, then studies the Jacobian at
/// the solution: its rank gives the degrees of freedom left, and the unknowns
/// outside its row space are the ones that can still move. Unknowns that no
/// equation ties together (two circles each held on its own) make a Jacobian
/// that is block diagonal: its blocks are studied and solved apart, the same
/// arithmetic in a fraction of the time (hundreds of holes in a plate).
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

/// Solves in place, starting from the values already in `x`; `held[i]` keeps
/// x[i] where it is, no unknown (it is not free and counts no freedom).
SolveResult solve(double[] x, const(Equation)[] eqs, double tolerance = 1e-9, size_t maxIterations = 300,
    const(bool)[] held = null)
{
    size_t[] cols;
    foreach (i; 0 .. x.length)
        if (i >= held.length || !held[i])
            cols ~= i;
    SolveResult res;
    res.converged = minimize(x, eqs, cols, tolerance, maxIterations, res.iterations, res.residual);
    auto j = jacobian(x, eqs, cols);
    res.free = new bool[x.length];
    foreach (b; blocks(j, cols.length))
    {
        auto basis = rowBasis(j, b);
        res.rank += basis.length;
        foreach (k, c; b.cols)
        {
            double inSpan = 0;
            foreach (q; basis)
                inSpan += q[k] * q[k];
            res.free[cols[c]] = inSpan < 1 - 1e-6;
        }
    }
    res.dof = cols.length - res.rank;
    if (!res.converged)
        res.conflicting = findConflicts(x, eqs, cols, tolerance);
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

/// Rows = equations, columns = the unknowns `cols` (central differences).
double[][] jacobian(const(double)[] x0, const(Equation)[] eqs, const(size_t)[] cols)
{
    immutable m = totalCount(eqs), n = cols.length;
    auto j = new double[][](m, n);
    auto x = x0.dup;
    auto rp = new double[m], rm = new double[m];
    foreach (c, v; cols)
    {
        immutable h = 1e-6 * (1 + abs(x0[v]));
        x[v] = x0[v] + h;
        residuals(x, eqs, rp);
        x[v] = x0[v] - h;
        residuals(x, eqs, rm);
        x[v] = x0[v];
        foreach (r; 0 .. m)
            j[r][c] = (rp[r] - rm[r]) / (2 * h);
    }
    return j;
}

/// Columns of a Jacobian that no row ties together, and the rows (not all zero) on each: the matrix
/// is block diagonal over them, exactly (a zero is a zero), so that its rank, its row space and the
/// normal equations split into theirs.
struct Block
{
    size_t[] cols, rows;
}

/// ditto
Block[] blocks(const(double[])[] j, size_t n)
{
    auto parent = new size_t[n];
    foreach (i; 0 .. n)
        parent[i] = i;
    size_t root(size_t i)
    {
        while (parent[i] != i)
            i = parent[i] = parent[parent[i]];
        return i;
    }
    foreach (row; j)
    {
        size_t first = size_t.max;
        foreach (c; 0 .. n)
            if (row[c] != 0)
            {
                if (first == size_t.max)
                    first = root(c);
                else
                    parent[root(c)] = first;
            }
    }
    auto index = new size_t[n];
    index[] = size_t.max;
    Block[] r;
    foreach (c; 0 .. n)
    {
        immutable g = root(c);
        if (index[g] == size_t.max)
        {
            index[g] = r.length;
            r ~= Block();
        }
        r[index[g]].cols ~= c;
    }
    foreach (k, row; j)
        foreach (c; 0 .. n)
            if (row[c] != 0)
            {
                r[index[root(c)]].rows ~= k;
                break;
            }
    return r;
}

bool minimize(double[] x, const(Equation)[] eqs, const(size_t)[] cols, double tolerance, size_t maxIterations,
    out size_t iterations, out double residual)
{
    immutable m = totalCount(eqs), n = cols.length;
    auto r = new double[m];
    residuals(x, eqs, r);
    double cost = norm2(r);
    double lambda = 1e-3;
    auto trial = x.dup;
    auto rt = new double[m];
    foreach (it; 0 .. maxIterations)
    {
        iterations = it;
        if (maxAbs(r) < tolerance)
            break;
        auto j = jacobian(x, eqs, cols);
        // normal equations (JᵀJ + λ·diag) δ = −Jᵀr, a block at a time
        auto bs = blocks(j, n);
        auto a = new double[][][](bs.length);
        auto g = new double[][](bs.length);
        double floor = 1e-6;
        foreach (bi, b; bs)
        {
            immutable nb = b.cols.length;
            a[bi] = new double[][](nb, nb);
            g[bi] = new double[nb];
            foreach (p, cp; b.cols)
            {
                double s = 0;
                foreach (k; b.rows)
                    s += j[k][cp] * r[k];
                g[bi][p] = -s;
                foreach (q; p .. nb)
                {
                    immutable cq = b.cols[q];
                    double t = 0;
                    foreach (k; b.rows)
                        t += j[k][cp] * j[k][cq];
                    a[bi][p][q] = a[bi][q][p] = t;
                }
                // unknowns the residuals barely depend on (a nearly horizontal line
                // sliding along itself) are damped like the others, else one step
                // throws them far from where they were
                floor = max(floor, 1e-3 * a[bi][p][p]);
            }
        }
        bool improved;
        foreach (attempt; 0 .. 12)
        {
            bool singular;
            trial[] = x[];
            foreach (bi, b; bs)
            {
                immutable nb = b.cols.length;
                auto aa = new double[][](nb, nb);
                foreach (p; 0 .. nb)
                {
                    aa[p][] = a[bi][p][];
                    aa[p][p] += lambda * (a[bi][p][p] + floor);
                }
                auto delta = solveLinear(aa, g[bi].dup);
                if (delta is null)
                {
                    singular = true;
                    break;
                }
                foreach (p, c; b.cols)
                    trial[cols[c]] = x[cols[c]] + delta[p];
            }
            if (singular)
            {
                lambda *= 10;
                continue;
            }
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

/// Orthonormal basis of the row space of block `b` of `j`, in its columns'
/// order (modified Gram–Schmidt, rows scaled to unit length first so that
/// lengths and angles weigh the same).
double[][] rowBasis(const(double[])[] j, Block b)
{
    immutable n = b.cols.length;
    double[][] basis;
    foreach (k; b.rows)
    {
        auto v = new double[n];
        foreach (i, c; b.cols)
            v[i] = j[k][c];
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
size_t[] findConflicts(const(double)[] x0, const(Equation)[] eqs, const(size_t)[] cols, double tolerance)
{
    size_t[] r;
    foreach_reverse (skip; 0 .. eqs.length)
    {
        const(Equation)[] rest = eqs[0 .. skip] ~ eqs[skip + 1 .. $];
        auto x = x0.dup;
        size_t its;
        double res;
        if (minimize(x, rest, cols, tolerance, 100, its, res))
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
