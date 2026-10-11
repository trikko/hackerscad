/// Sketch geometry and constraints on the XY plane.
///
/// Points, lines, arcs and circles are entities; constraints refer to them by
/// index. Positions given when entities are created are only the starting
/// guess: the solver moves them until every constraint holds, staying as close
/// to the guess as the constraints allow. The non-construction lines and arcs
/// must form closed loops, which become the outline of a profile.
module hackerscad.sketch.sketch;

import std.algorithm : max, min, canFind;
import std.format : format;
import std.math : abs, sqrt, atan2, cos, sin, tan, PI, fmod;

import hackerscad.geom.vec;
import hackerscad.kernel.brep : OutlineSeg;
import hackerscad.sketch.solver;

class SketchException : Exception
{
    size_t[] entities;   /// points or constraints involved, for the caller to locate
    this(string msg, size_t[] entities = null, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
        this.entities = entities;
    }
}

enum EntityKind
{
    point,
    line,
    arc,
    circle
}

struct Entity
{
    EntityKind kind;
    size_t[3] refs;       /// line: p1 p2; arc: center start end (counter-clockwise); circle: center
    size_t var;           /// point: index of x (y follows); circle: index of the radius
    bool construction;
}

enum ConstraintKind
{
    coincident,
    fix,
    horizontal,
    vertical,
    length,
    distance,
    hdistance,
    vdistance,
    pointLineDistance,
    onLine,
    onCircle,
    parallel,
    perpendicular,
    angle,
    equalLength,
    equalRadius,
    radius,
    tangentLine,
    tangentCircles,
    midpoint,
    symmetric,
    arcRadius,        /// implicit: start and end of an arc are equally far from its centre
}

struct Constraint
{
    ConstraintKind kind;
    size_t[3] refs;
    double value = 0;
    double value2 = 0;
    double sign = 1;      /// orientation chosen from the starting guess
    size_t tag;           /// caller's id (source position), reported in errors
}

struct SolveReport
{
    bool solved;
    size_t dof;
    size_t[] freePoints;       /// entity indices of points that can still move
    size_t[] conflicting;      /// constraint indices
    double residual;
}

final class Sketch
{
    Entity[] entities;
    Constraint[] constraints;
    double[] vars;
    double[size_t] fillets;    /// corner point → radius
    private bool dirty = true;
    private SolveReport last;

    size_t point(double x, double y, bool construction = false)
    {
        vars ~= [x, y];
        entities ~= Entity(EntityKind.point, [0, 0, 0], vars.length - 2, construction);
        dirty = true;
        return entities.length - 1;
    }

    size_t line(size_t p1, size_t p2, bool construction = false)
    {
        expect(p1, EntityKind.point);
        expect(p2, EntityKind.point);
        if (p1 == p2)
            throw new SketchException("a line needs two different points");
        entities ~= Entity(EntityKind.line, [p1, p2, 0], 0, construction);
        dirty = true;
        return entities.length - 1;
    }

    size_t arc(size_t center, size_t start, size_t end, bool construction = false)
    {
        foreach (p; [center, start, end])
            expect(p, EntityKind.point);
        entities ~= Entity(EntityKind.arc, [center, start, end], 0, construction);
        immutable id = entities.length - 1;
        constraints ~= Constraint(ConstraintKind.arcRadius, [id, 0, 0]);
        dirty = true;
        return id;
    }

    size_t circle(size_t center, double r, bool construction = false)
    {
        expect(center, EntityKind.point);
        vars ~= r;
        entities ~= Entity(EntityKind.circle, [center, 0, 0], vars.length - 1, construction);
        dirty = true;
        return entities.length - 1;
    }

    /// Adds a constraint; the orientation of signed ones follows the current geometry.
    void constrain(ConstraintKind kind, size_t[] refs, double value = 0, size_t tag = 0, double value2 = 0)
    {
        Constraint c;
        c.kind = kind;
        foreach (i, r; refs)
            c.refs[i] = r;
        c.value = value;
        c.value2 = value2;
        c.tag = tag;
        check(c);
        c.sign = 1;
        // signed constraints keep the side the drawing is on
        final switch (c.kind) with (ConstraintKind)
        {
        case hdistance, vdistance, pointLineDistance, angle, tangentLine:
            c.sign = signedPart(c, vars) < 0 ? -1 : 1;
            break;
        case tangentCircles:
            {
                // external when the circles are apart, internal when one holds the other
                immutable d = (pos(center(c.refs[0]), vars) - pos(center(c.refs[1]), vars)).length;
                immutable ra = radiusOf(c.refs[0], vars), rb = radiusOf(c.refs[1], vars);
                c.sign = abs(d - (ra + rb)) <= abs(d - abs(ra - rb)) ? 0 : (ra >= rb ? 1 : -1);
                break;
            }
        case coincident, fix, horizontal, vertical, length, distance, onLine, onCircle, parallel, perpendicular,
                equalLength, equalRadius, radius, midpoint, symmetric, arcRadius:
            break;
        }
        constraints ~= c;
        dirty = true;
    }

    void fillet(size_t p, double r)
    {
        expect(p, EntityKind.point);
        fillets[p] = r;
    }

    Vec3 position(size_t p)
    {
        solveIfNeeded();
        expect(p, EntityKind.point);
        return pos(p, vars);
    }

    double radius(size_t e)
    {
        solveIfNeeded();
        return radiusOf(e, vars);
    }

    SolveReport solve()
    {
        Equation[] eqs;
        foreach (c; constraints)
            eqs ~= equation(c);
        auto res = hackerscad.sketch.solver.solve(vars, eqs);
        SolveReport rep;
        rep.solved = res.converged;
        rep.dof = res.dof;
        rep.residual = res.residual;
        foreach (i, e; entities)
            if (e.kind == EntityKind.point && (res.free[e.var] || res.free[e.var + 1]))
                rep.freePoints ~= i;
        foreach (k; res.conflicting)
            rep.conflicting ~= k;
        last = rep;
        dirty = false;
        return rep;
    }

    SolveReport report()
    {
        solveIfNeeded();
        return last;
    }

    /// Closed loops of the non-construction lines, arcs and circles.
    OutlineSeg[] outline()
    {
        solveIfNeeded();
        if (!last.solved)
            throw new SketchException("the sketch constraints conflict", last.conflicting);
        OutlineSeg[] segs;

        // full circles are loops of their own (two half arcs)
        foreach (i, e; entities)
            if (e.kind == EntityKind.circle && !e.construction)
            {
                auto c = pos(e.refs[0], vars);
                immutable r = vars[e.var];
                segs ~= OutlineSeg(OutlineSeg.Kind.arc, c.x + r, c.y, c.x - r, c.y, c.x, c.y + r);
                segs ~= OutlineSeg(OutlineSeg.Kind.arc, c.x - r, c.y, c.x + r, c.y, c.x, c.y - r);
                segs ~= OutlineSeg(OutlineSeg.Kind.end);
            }

        // lines and arcs, joined at points that coincide after solving
        struct Seg
        {
            size_t entity;
            Vec3 a, b;
            size_t ka, kb;    // canonical end points
        }

        Seg[] all;
        Vec3[] corners;
        size_t[] cornerPoint;
        size_t canonical(size_t p)
        {
            auto q = pos(p, vars);
            foreach (i, c; corners)
                if ((c - q).length < 1e-6 * max(1.0, q.length))
                {
                    if (p in fillets)
                        cornerPoint[i] = p;
                    return i;
                }
            corners ~= q;
            cornerPoint ~= p;
            return corners.length - 1;
        }

        foreach (i, e; entities)
        {
            if (e.construction)
                continue;
            if (e.kind == EntityKind.line)
                all ~= Seg(i, pos(e.refs[0], vars), pos(e.refs[1], vars), canonical(e.refs[0]), canonical(e.refs[1]));
            else if (e.kind == EntityKind.arc)
                all ~= Seg(i, pos(e.refs[1], vars), pos(e.refs[2], vars), canonical(e.refs[1]), canonical(e.refs[2]));
        }
        size_t[][] at = new size_t[][](corners.length);
        foreach (i, s; all)
        {
            at[s.ka] ~= i;
            at[s.kb] ~= i;
        }
        foreach (k, list; at)
            if (list.length != 2)
                throw new SketchException(list.length < 2
                        ? "the outline is open at this point (it must form closed loops)"
                        : format("%d segments meet at this point; the outline must form simple loops", list.length),
                    [cornerPoint[k]]);

        auto used = new bool[all.length];
        foreach (start; 0 .. all.length)
        {
            if (used[start])
                continue;
            // walk the loop: (segment, reversed)
            size_t[] order;
            bool[] rev;
            size_t cur = start;
            size_t from = all[start].ka;
            while (!used[cur])
            {
                used[cur] = true;
                immutable r = all[cur].ka != from;
                order ~= cur;
                rev ~= r;
                immutable to = r ? all[cur].ka : all[cur].kb;
                auto next = at[to][0] == cur ? at[to][1] : at[to][0];
                from = to;
                cur = next;
            }
            segs ~= loopSegments(all, order, rev, cornerPoint);
            segs ~= OutlineSeg(OutlineSeg.Kind.end);
        }
        if (segs.length == 0)
            throw new SketchException("the sketch has no outline: draw lines, arcs or circles that are not construction");
        return segs;
    }

private:

    // a function of its own, so that each delegate captures its own constraint
    Equation equation(Constraint c) => Equation(equationCount(c.kind), (const(double)[] x, double[] r) { eval(c, x, r); });

    OutlineSeg[] loopSegments(S)(S[] all, size_t[] order, bool[] rev, size_t[] cornerPoint)
    {
        immutable n = order.length;
        // ends of every segment in walking order, trimmed by corner fillets
        auto a = new Vec3[n], b = new Vec3[n];
        foreach (i; 0 .. n)
        {
            auto s = all[order[i]];
            a[i] = rev[i] ? s.b : s.a;
            b[i] = rev[i] ? s.a : s.b;
        }
        auto filletArc = new OutlineSeg[n];
        auto hasArc = new bool[n];
        foreach (i; 0 .. n)
        {
            immutable j = (i + 1) % n;
            auto s = all[order[i]];
            immutable corner = rev[i] ? s.ka : s.kb;
            auto pr = cornerPoint[corner] in fillets;
            if (pr is null)
                continue;
            immutable r = *pr;
            if (entities[all[order[i]].entity].kind != EntityKind.line || entities[all[order[j]].entity].kind != EntityKind.line)
                throw new SketchException("corner fillets join two lines", [cornerPoint[corner]]);
            auto v = b[i];
            auto u1 = (a[i] - v), u2 = (b[j] - v);
            immutable l1 = u1.length, l2 = u2.length;
            u1 = u1 * (1 / l1);
            u2 = u2 * (1 / l2);
            immutable cosT = max(-1.0, min(1.0, u1.dot(u2)));
            immutable half = acos(cosT) / 2;
            if (half < 1e-6 || half > PI / 2 - 1e-6)
                throw new SketchException("cannot round a straight corner", [cornerPoint[corner]]);
            immutable t = r / tan(half);
            if (t > l1 + 1e-9 || t > l2 + 1e-9)
                throw new SketchException(format("the fillet (r = %.4g mm) is too big for the lines at this corner", r),
                    [cornerPoint[corner]]);
            auto bis = (u1 + u2) * (1 / (u1 + u2).length);
            immutable dc = r / sin(half);
            auto mid = v + bis * (dc - r);
            b[i] = v + u1 * t;
            a[j] = v + u2 * t;
            filletArc[i] = OutlineSeg(OutlineSeg.Kind.arc, b[i].x, b[i].y, a[j].x, a[j].y, mid.x, mid.y);
            hasArc[i] = true;
        }
        OutlineSeg[] segs;
        foreach (i; 0 .. n)
        {
            auto e = entities[all[order[i]].entity];
            if (e.kind == EntityKind.line)
            {
                if ((b[i] - a[i]).length > 1e-9)
                    segs ~= OutlineSeg(OutlineSeg.Kind.line, a[i].x, a[i].y, b[i].x, b[i].y);
            }
            else
            {
                auto m = arcMid(all[order[i]].entity);
                segs ~= OutlineSeg(OutlineSeg.Kind.arc, a[i].x, a[i].y, b[i].x, b[i].y, m.x, m.y);
            }
            if (hasArc[i])
                segs ~= filletArc[i];
        }
        return segs;
    }

    static double acos(double c)
    {
        import std.math : acos;
        return acos(c);
    }

    Vec3 arcMid(size_t arcId)
    {
        auto e = entities[arcId];
        auto c = pos(e.refs[0], vars), s = pos(e.refs[1], vars), t = pos(e.refs[2], vars);
        immutable a0 = atan2(s.y - c.y, s.x - c.x);
        double a1 = atan2(t.y - c.y, t.x - c.x);
        while (a1 <= a0 + 1e-12)
            a1 += 2 * PI;
        immutable am = (a0 + a1) / 2, r = (s - c).length;
        return Vec3(c.x + r * cos(am), c.y + r * sin(am), 0);
    }

    void solveIfNeeded()
    {
        if (dirty)
            solve();
    }

    void expect(size_t e, EntityKind kind)
    {
        if (e >= entities.length || entities[e].kind != kind)
            throw new SketchException(format("expected a sketch %s", kind));
    }

    bool isRound(size_t e) => e < entities.length && (entities[e].kind == EntityKind.arc || entities[e].kind == EntityKind.circle);
    bool isLine(size_t e) => e < entities.length && entities[e].kind == EntityKind.line;
    bool isPoint(size_t e) => e < entities.length && entities[e].kind == EntityKind.point;

    void check(const Constraint c)
    {
        void need(bool ok, string what)
        {
            if (!ok)
                throw new SketchException(format("%s needs %s", c.kind, what));
        }

        final switch (c.kind) with (ConstraintKind)
        {
        case coincident, distance, hdistance, vdistance:
            need(isPoint(c.refs[0]) && isPoint(c.refs[1]), "two points");
            break;
        case fix:
            need(isPoint(c.refs[0]), "a point");
            break;
        case horizontal, vertical, length:
            need(isLine(c.refs[0]), "a line");
            break;
        case pointLineDistance, onLine, midpoint:
            need(isPoint(c.refs[0]) && isLine(c.refs[1]), "a point and a line");
            break;
        case onCircle:
            need(isPoint(c.refs[0]) && isRound(c.refs[1]), "a point and a circle or arc");
            break;
        case parallel, perpendicular, angle, equalLength:
            need(isLine(c.refs[0]) && isLine(c.refs[1]), "two lines");
            break;
        case equalRadius, tangentCircles:
            need(isRound(c.refs[0]) && isRound(c.refs[1]), "two circles or arcs");
            break;
        case radius:
            need(isRound(c.refs[0]), "a circle or an arc");
            break;
        case tangentLine:
            need(isLine(c.refs[0]) && isRound(c.refs[1]), "a line and a circle or arc");
            break;
        case symmetric:
            need(isPoint(c.refs[0]) && isPoint(c.refs[1]) && isLine(c.refs[2]), "two points and a line");
            break;
        case arcRadius:
            break;
        }
    }

    static size_t equationCount(ConstraintKind k)
    {
        switch (k) with (ConstraintKind)
        {
        case coincident, fix, midpoint, symmetric: return 2;
        default: return 1;
        }
    }

    Vec3 pos(size_t p, const(double)[] x) const
    {
        immutable v = entities[p].var;
        return Vec3(x[v], x[v + 1], 0);
    }

    size_t center(size_t e) const => entities[e].refs[0];

    double radiusOf(size_t e, const(double)[] x) const
    {
        auto en = entities[e];
        if (en.kind == EntityKind.circle)
            return x[en.var];
        return (pos(en.refs[1], x) - pos(en.refs[0], x)).length;
    }

    Vec3 dirOf(size_t line, const(double)[] x) const
    {
        auto e = entities[line];
        return pos(e.refs[1], x) - pos(e.refs[0], x);
    }

    static double cross2(Vec3 a, Vec3 b) => a.x * b.y - a.y * b.x;

    static double wrap(double a)
    {
        while (a > PI)
            a -= 2 * PI;
        while (a < -PI)
            a += 2 * PI;
        return a;
    }

    /// The signed quantity whose sign is frozen at creation.
    double signedPart(const Constraint c, const(double)[] x) const
    {
        switch (c.kind) with (ConstraintKind)
        {
        case hdistance: return pos(c.refs[1], x).x - pos(c.refs[0], x).x;
        case vdistance: return pos(c.refs[1], x).y - pos(c.refs[0], x).y;
        case pointLineDistance:
            {
                auto d = dirOf(c.refs[1], x);
                return cross2(d, pos(c.refs[0], x) - pos(entities[c.refs[1]].refs[0], x)) / d.length;
            }
        case tangentLine:
            {
                auto d = dirOf(c.refs[0], x);
                return cross2(d, pos(center(c.refs[1]), x) - pos(entities[c.refs[0]].refs[0], x)) / d.length;
            }
        case angle:
            {
                auto a = dirOf(c.refs[0], x), b = dirOf(c.refs[1], x);
                return atan2(cross2(a, b), a.dot(b));
            }
        default: return 0;
        }
    }

    void eval(const Constraint c, const(double)[] x, double[] r) const
    {
        final switch (c.kind) with (ConstraintKind)
        {
        case coincident:
            {
                auto d = pos(c.refs[0], x) - pos(c.refs[1], x);
                r[0] = d.x;
                r[1] = d.y;
                break;
            }
        case fix:
            {
                auto p = pos(c.refs[0], x);
                r[0] = p.x - c.value;
                r[1] = p.y - c.value2;
                break;
            }
        case horizontal: r[0] = dirOf(c.refs[0], x).y; break;
        case vertical: r[0] = dirOf(c.refs[0], x).x; break;
        case length: r[0] = dirOf(c.refs[0], x).length - c.value; break;
        case distance: r[0] = (pos(c.refs[0], x) - pos(c.refs[1], x)).length - c.value; break;
        case hdistance, vdistance, pointLineDistance:
            r[0] = c.sign * signedPart(c, x) - c.value;
            break;
        case onLine:
            {
                auto d = dirOf(c.refs[1], x);
                r[0] = cross2(d, pos(c.refs[0], x) - pos(entities[c.refs[1]].refs[0], x)) / d.length;
                break;
            }
        case onCircle:
            r[0] = (pos(c.refs[0], x) - pos(center(c.refs[1]), x)).length - radiusOf(c.refs[1], x);
            break;
        case parallel:
            {
                auto a = dirOf(c.refs[0], x), b = dirOf(c.refs[1], x);
                r[0] = cross2(a, b) / (a.length * b.length);
                break;
            }
        case perpendicular:
            {
                auto a = dirOf(c.refs[0], x), b = dirOf(c.refs[1], x);
                r[0] = a.dot(b) / (a.length * b.length);
                break;
            }
        case angle: r[0] = wrap(signedPart(c, x) - c.sign * c.value); break;
        case equalLength: r[0] = dirOf(c.refs[0], x).length - dirOf(c.refs[1], x).length; break;
        case equalRadius: r[0] = radiusOf(c.refs[0], x) - radiusOf(c.refs[1], x); break;
        case radius: r[0] = radiusOf(c.refs[0], x) - c.value; break;
        case tangentLine: r[0] = c.sign * signedPart(c, x) - radiusOf(c.refs[1], x); break;
        case tangentCircles:
            {
                immutable d = (pos(center(c.refs[0]), x) - pos(center(c.refs[1]), x)).length;
                immutable ra = radiusOf(c.refs[0], x), rb = radiusOf(c.refs[1], x);
                r[0] = c.sign == 0 ? d - (ra + rb) : d - c.sign * (ra - rb);
                break;
            }
        case midpoint:
            {
                auto e = entities[c.refs[1]];
                auto m = (pos(e.refs[0], x) + pos(e.refs[1], x)) * 0.5;
                auto p = pos(c.refs[0], x);
                r[0] = p.x - m.x;
                r[1] = p.y - m.y;
                break;
            }
        case symmetric:
            {
                auto p = pos(c.refs[0], x), q = pos(c.refs[1], x);
                auto d = dirOf(c.refs[2], x);
                auto o = pos(entities[c.refs[2]].refs[0], x);
                auto m = (p + q) * 0.5;
                r[0] = cross2(d, m - o) / d.length;
                r[1] = (q - p).dot(d) / d.length;
                break;
            }
        case arcRadius:
            {
                auto e = entities[c.refs[0]];
                auto ctr = pos(e.refs[0], x);
                r[0] = (pos(e.refs[1], x) - ctr).length - (pos(e.refs[2], x) - ctr).length;
                break;
            }
        }
    }
}

unittest
{
    import std.math : isClose;

    // a right triangle: base 30 horizontal, height 40 vertical
    auto s = new Sketch;
    auto a = s.point(0, 0), b = s.point(25, 3), c = s.point(2, 35);
    s.constrain(ConstraintKind.fix, [a], 0, 0, 0);
    auto ab = s.line(a, b), bc = s.line(b, c), ca = s.line(c, a);
    s.constrain(ConstraintKind.horizontal, [ab]);
    s.constrain(ConstraintKind.vertical, [ca]);
    s.constrain(ConstraintKind.length, [ab], 30);
    s.constrain(ConstraintKind.length, [ca], 40);
    auto rep = s.solve();
    assert(rep.solved && rep.dof == 0, format("%s", rep));
    assert(isClose(s.position(b).x, 30, 1e-9) && abs(s.position(b).y) < 1e-9);
    assert(isClose(s.position(c).y, 40, 1e-9) && abs(s.position(c).x) < 1e-9);
    assert(isClose((s.position(b) - s.position(c)).length, 50, 1e-9));
    auto segs = s.outline();
    assert(segs.length == 4 && segs[3].kind == OutlineSeg.Kind.end);

    // without the height: one degree of freedom, point c moves
    auto u = new Sketch;
    auto p = u.point(0, 0), q = u.point(25, 3), w = u.point(2, 35);
    u.constrain(ConstraintKind.fix, [p], 0, 0, 0);
    auto pq = u.line(p, q), qw = u.line(q, w), wp = u.line(w, p);
    u.constrain(ConstraintKind.horizontal, [pq]);
    u.constrain(ConstraintKind.vertical, [wp]);
    u.constrain(ConstraintKind.length, [pq], 30);
    rep = u.solve();
    assert(rep.solved && rep.dof == 1 && rep.freePoints == [w], format("%s", rep));

    // conflicting lengths are reported
    u.constrain(ConstraintKind.length, [wp], 40, 7);
    u.constrain(ConstraintKind.length, [qw], 10, 8);
    rep = u.solve();
    assert(!rep.solved && rep.conflicting.length);

    // a line tangent to a circle, and a fillet at a corner
    auto t = new Sketch;
    auto o = t.point(0, 0);
    t.constrain(ConstraintKind.fix, [o], 0, 0, 0);
    auto circ = t.circle(o, 8);
    t.constrain(ConstraintKind.radius, [circ], 10);
    auto l1 = t.point(-20, 12), l2 = t.point(20, 9);
    auto tl = t.line(l1, l2, true);
    t.constrain(ConstraintKind.horizontal, [tl]);
    t.constrain(ConstraintKind.tangentLine, [tl, circ]);
    assert(t.solve().solved);
    assert(isClose(t.position(l1).y, 10, 1e-9));

    auto sq = new Sketch;
    auto c0 = sq.point(0, 0), c1 = sq.point(20, 0), c2 = sq.point(20, 20), c3 = sq.point(0, 20);
    sq.line(c0, c1);
    sq.line(c1, c2);
    sq.line(c2, c3);
    sq.line(c3, c0);
    sq.fillet(c2, 5);
    auto loop = sq.outline();
    assert(loop.length == 6);   // 4 lines + 1 arc + end
}
