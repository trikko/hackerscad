/// Sketch geometry and constraints on the XY plane.
///
/// Points, lines, arcs, circles and ellipses are entities; constraints refer to them by
/// index. Positions given when entities are created are only the starting
/// guess: the solver moves them until every constraint holds, staying as close
/// to the guess as the constraints allow. The non-construction lines and arcs
/// must form closed loops, which become the outline of a profile.
module hackerscad.sketch.sketch;

import std.algorithm : max, min;
import std.format : format;
import std.math : abs, atan2, cos, remainder, sin, sqrt, tan, PI;

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
    circle,
    ellipse,
    spline
}

struct Entity
{
    EntityKind kind;
    size_t[3] refs;       /// line: p1 p2; arc: center start end (counter-clockwise); circle, ellipse: center
    size_t var;           /// point: index of x (y follows); circle: index of the radius; ellipse: rx (ry, angle follow)
    bool construction;
    bool reference;       /// geometry from outside the sketch (a face's edges): fixed, not part of the outline
    size_t[] through;     /// spline: the points it goes through, in order (refs[0] and refs[1]: its two ends)
    bool closed;          /// spline: round from the last point back to the first, smoothly (a loop of its own)
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
    onEllipse,
    radiusX,          /// an ellipse's radius along its own x axis
    radiusY,
    ellipseAngle,     /// the direction of an ellipse's x axis, from X (either way along it)
    direction,        /// from point refs[0] towards refs[1], at an angle from X
    equalRadii,       /// an ellipse as wide as tall: a circle
    tangentAt,        /// a line touching a circle or arc at point refs[2]: the radius there square to it
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

/// Where a segment of the outline comes from.
struct OutlineSource
{
    size_t entity = size_t.max;   /// the line, arc, circle or ellipse it is (part of)
    size_t corner = size_t.max;   /// a corner fillet's arc: the point it rounds
}

struct SolveReport
{
    bool solved;
    size_t dof;
    size_t[] freePoints;       /// entity indices of points that can still move
    size_t[] freeShapes;       /// circles and ellipses whose radius (or turn) can still change
    size_t[] conflicting;      /// constraint indices
    double residual;
}

final class Sketch
{
    Entity[] entities;
    Constraint[] constraints;
    double[] vars;
    double[size_t] fillets;    /// corner point → radius
    bool[] frozen;             /// per unknown: held where it is, not an unknown at all (references)
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

    /// A smooth curve through points (see hackerscad.geom.spline): open, its
    /// ends join lines and arcs as theirs do; closed, a loop of its own. It
    /// adds no unknowns: its points move it.
    size_t spline(size_t[] pts, bool closed, bool construction = false)
    {
        foreach (p; pts)
            expect(p, EntityKind.point);
        if (pts.length < (closed ? 3 : 2))
            throw new SketchException(closed ? "a closed spline needs at least 3 points" : "a spline needs at least 2 points");
        foreach (i; 0 .. closed ? pts.length : pts.length - 1)
            if (pts[i] == pts[(i + 1) % pts.length])
                throw new SketchException("a spline goes through two different points in a row", [pts[i]]);
        Entity e = Entity(EntityKind.spline, [pts[0], pts[$ - 1], 0], 0, construction);
        e.through = pts.dup;
        e.closed = closed;
        entities ~= e;
        dirty = true;
        return entities.length - 1;
    }

    /// The Bézier poles of spline `e` as it lies now (hackerscad.geom.spline).
    Vec3[] splinePoles(size_t e)
    {
        import hackerscad.geom.spline : poles = splinePoles;
        solveIfNeeded();
        Vec3[] pts;
        foreach (p; entities[e].through)
            pts ~= pos(p, vars);
        foreach (i; 0 .. entities[e].closed ? pts.length : pts.length - 1)
            if ((pts[(i + 1) % pts.length] - pts[i]).length < 1e-9)
                throw new SketchException("two points in a row of a spline lie on each other", [entities[e].through[i]]);
        return poles(pts, entities[e].closed);
    }

    /// An ellipse: radius rx along its own x axis, which is `angle` from X, and ry across.
    size_t ellipse(size_t center, double rx, double ry, double angle, bool construction = false)
    {
        expect(center, EntityKind.point);
        vars ~= [rx, ry, angle];
        entities ~= Entity(EntityKind.ellipse, [center, 0, 0], vars.length - 3, construction);
        dirty = true;
        return entities.length - 1;
    }

    /// Makes entity `e` a reference: construction geometry whose position
    /// and size are given, out of the unknowns (no degree of freedom, and
    /// constraints only between references are checked, not solved). The
    /// points of a line or an arc are frozen on their own.
    void freeze(size_t e)
    {
        entities[e].reference = true;
        entities[e].construction = true;
        frozen.length = vars.length;
        immutable v = entities[e].var;
        final switch (entities[e].kind)
        {
        case EntityKind.point: frozen[v .. v + 2] = true; break;
        case EntityKind.circle: frozen[v] = true; break;
        case EntityKind.ellipse: frozen[v .. v + 3] = true; break;
        case EntityKind.line, EntityKind.arc, EntityKind.spline: break;
        }
        dirty = true;
    }

    /// Adds a constraint; the orientation of signed ones follows the current geometry.
    void constrain(ConstraintKind kind, size_t[] refs, double value = 0, size_t tag = 0, double value2 = 0)
    {
        // a line tangent to an arc it ends on: "tangent" holds to first order wherever that end
        // slides along the line, and the freedoms would be counted one too many; the radius square
        // to the line at the shared point says the same exactly
        if (kind == ConstraintKind.tangentLine && refs.length == 2 && refs[0] < entities.length
            && refs[1] < entities.length && entities[refs[0]].kind == EntityKind.line
            && entities[refs[1]].kind == EntityKind.arc)
            foreach (p; entities[refs[0]].refs[0 .. 2])
                if (p == entities[refs[1]].refs[1] || p == entities[refs[1]].refs[2])
                {
                    kind = ConstraintKind.tangentAt;
                    refs = [refs[0], refs[1], p];
                    break;
                }
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
        case ellipseAngle:
            {
                // the turn is only the ellipse's own unknown: it starts where it is asked to be, else a
                // start a quarter turn away would be a flat spot of the residual
                import std.math : round;
                immutable v = entities[c.refs[0]].var + 2;
                vars[v] = c.value + PI * round((vars[v] - c.value) / PI);
                break;
            }
        case coincident, fix, horizontal, vertical, length, distance, onLine, onCircle, parallel, perpendicular,
                equalLength, equalRadius, radius, midpoint, symmetric, arcRadius, onEllipse, radiusX, radiusY,
                direction, equalRadii, tangentAt:
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

    /// Where a point is now, without solving: the starting guess of new geometry.
    Vec3 guess(size_t p)
    {
        expect(p, EntityKind.point);
        return pos(p, vars);
    }

    /// An ellipse's radii (positive) and the direction of its x axis.
    void ellipseAxes(size_t e, out double rx, out double ry, out double angle)
    {
        solveIfNeeded();
        expect(e, EntityKind.ellipse);
        ellipseOf(e, vars, rx, ry, angle);
    }

    SolveReport solve()
    {
        Equation[] eqs;
        foreach (c; constraints)
            eqs ~= equation(c);
        // a round ellipse looks the same however it is turned: its angle stays
        // where it is (unless a constraint sets it) rather than count as a
        // degree of freedom nothing could take away
        bool[size_t] round, turned;
        foreach (c; constraints)
            if (c.kind == ConstraintKind.equalRadii)
                round[c.refs[0]] = true;
            else if (c.kind == ConstraintKind.ellipseAngle)
                turned[c.refs[0]] = true;
        foreach (e, _; round)
            if (e !in turned)
            {
                immutable v = entities[e].var + 2, at = vars[v];
                eqs ~= Equation(1, (const(double)[] x, double[] r) { r[0] = x[v] - at; });
            }
        // the frozen values stay out of the unknowns: the equations see them
        // where they are, and the solver only the others
        frozen.length = vars.length;
        size_t[] unknown;
        foreach (i; 0 .. vars.length)
            if (!frozen[i])
                unknown ~= i;
        hackerscad.sketch.solver.SolveResult res;
        if (unknown.length == vars.length)
            res = hackerscad.sketch.solver.solve(vars, eqs);
        else
        {
            auto full = vars.dup;
            // one closure per call: closures made in a loop share one frame
            static Equation over(Equation e, double[] full, size_t[] unknown)
            {
                return Equation(e.count, (const(double)[] y, double[] r) {
                    foreach (k, i; unknown)
                        full[i] = y[k];
                    e.eval(full, r);
                });
            }
            Equation[] reduced;
            foreach (e; eqs)
                reduced ~= over(e, full, unknown);
            auto y = new double[unknown.length];
            foreach (k, i; unknown)
                y[k] = vars[i];
            res = hackerscad.sketch.solver.solve(y, reduced);
            foreach (k, i; unknown)
                vars[i] = y[k];
            auto free = new bool[vars.length];
            foreach (k, i; unknown)
                free[i] = res.free[k];
            res.free = free;
        }
        SolveReport rep;
        rep.solved = res.converged;
        rep.dof = res.dof;
        rep.residual = res.residual;
        foreach (i, e; entities)
            if (e.kind == EntityKind.point && (res.free[e.var] || res.free[e.var + 1]))
                rep.freePoints ~= i;
            else if ((e.kind == EntityKind.circle && res.free[e.var])
                    || (e.kind == EntityKind.ellipse && (res.free[e.var] || res.free[e.var + 1] || res.free[e.var + 2])))
                rep.freeShapes ~= i;
        foreach (k; res.conflicting)
            rep.conflicting ~= k;
        last = rep;
        dirty = false;
        return rep;
    }

    /// Takes the geometry as it is for solved, with no freedom left, without
    /// running the solver: for shapes built with every point already where
    /// the constraints put it (a profile's rect, circle… are one-shape
    /// sketches with everything given).
    void assumeSolved()
    {
        last = SolveReport.init;
        last.solved = true;
        dirty = false;
    }

    SolveReport report()
    {
        solveIfNeeded();
        return last;
    }

    /// Closed loops of the non-construction lines, arcs, circles and ellipses.
    OutlineSeg[] outline()
    {
        OutlineSource[] sources;
        return outline(sources);
    }

    /// The same, with where each segment comes from (`sources[i]` for `segs[i]`).
    OutlineSeg[] outline(out OutlineSource[] sources)
    {
        solveIfNeeded();
        if (!last.solved)
            throw new SketchException("the sketch constraints conflict", last.conflicting);
        OutlineSeg[] segs;

        // full circles are loops of their own: one whole edge (a round ellipse), as a profile's
        // circle(r) has, starting on +X
        foreach (i, e; entities)
            if (e.kind == EntityKind.circle && !e.construction)
            {
                auto c = pos(e.refs[0], vars);
                immutable r = abs(vars[e.var]);
                if (r < 1e-9)
                    throw new SketchException("a circle of the outline has no size", [e.refs[0]]);
                segs ~= OutlineSeg(OutlineSeg.Kind.ellipse, c.x, c.y, r, r, 0);
                segs ~= OutlineSeg(OutlineSeg.Kind.end);
                sources ~= [OutlineSource(i), OutlineSource.init];
            }
            else if (e.kind == EntityKind.ellipse && !e.construction)
            {
                auto c = pos(e.refs[0], vars);
                double rx, ry, angle;
                ellipseOf(i, vars, rx, ry, angle);
                if (rx < 1e-9 || ry < 1e-9)
                    throw new SketchException("an ellipse of the outline has no size", [e.refs[0]]);
                segs ~= OutlineSeg(OutlineSeg.Kind.ellipse, c.x, c.y, rx, ry, angle);
                segs ~= OutlineSeg(OutlineSeg.Kind.end);
                sources ~= [OutlineSource(i), OutlineSource.init];
            }
            else if (e.kind == EntityKind.spline && e.closed && !e.construction)
            {
                segs ~= splineSeg(splinePoles(i));
                segs ~= OutlineSeg(OutlineSeg.Kind.end);
                sources ~= [OutlineSource(i), OutlineSource.init];
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
            else if (e.kind == EntityKind.spline && !e.closed)
                all ~= Seg(i, pos(e.refs[0], vars), pos(e.refs[1], vars), canonical(e.refs[0]), canonical(e.refs[1]));
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
            segs ~= loopSegments(all, order, rev, cornerPoint, sources);
            segs ~= OutlineSeg(OutlineSeg.Kind.end);
            sources ~= OutlineSource.init;
        }
        if (segs.length == 0)
            throw new SketchException("the sketch has no outline: draw lines, arcs, circles or ellipses that are not construction");
        return segs;
    }

private:

    // a function of its own, so that each delegate captures its own constraint
    Equation equation(Constraint c) => Equation(equationCount(c.kind), (const(double)[] x, double[] r) { eval(c, x, r); });

    OutlineSeg[] loopSegments(S)(S[] all, size_t[] order, bool[] rev, size_t[] cornerPoint,
        ref OutlineSource[] sources)
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
        auto filletCorner = new size_t[n];
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
            filletCorner[i] = cornerPoint[corner];
            hasArc[i] = true;
        }
        OutlineSeg[] segs;
        foreach (i; 0 .. n)
        {
            auto e = entities[all[order[i]].entity];
            if (e.kind == EntityKind.line)
            {
                if ((b[i] - a[i]).length > 1e-9)
                {
                    segs ~= OutlineSeg(OutlineSeg.Kind.line, a[i].x, a[i].y, b[i].x, b[i].y);
                    sources ~= OutlineSource(all[order[i]].entity);
                }
            }
            else if (e.kind == EntityKind.spline)
            {
                import std.algorithm : reverse;
                auto poles = splinePoles(all[order[i]].entity);
                if (rev[i])
                    poles.reverse();
                segs ~= splineSeg(poles);
                sources ~= OutlineSource(all[order[i]].entity);
            }
            else
            {
                auto m = arcMid(all[order[i]].entity);
                segs ~= OutlineSeg(OutlineSeg.Kind.arc, a[i].x, a[i].y, b[i].x, b[i].y, m.x, m.y);
                sources ~= OutlineSource(all[order[i]].entity);
            }
            if (hasArc[i])
            {
                segs ~= filletArc[i];
                sources ~= OutlineSource(size_t.max, filletCorner[i]);
            }
        }
        return segs;
    }

    /// A spline's piece of outline: its ends, and all its poles.
    static OutlineSeg splineSeg(Vec3[] poles)
    {
        auto g = OutlineSeg(OutlineSeg.Kind.spline, poles[0].x, poles[0].y, poles[$ - 1].x, poles[$ - 1].y);
        foreach (q; poles)
            g.poles ~= [q.x, q.y];
        return g;
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
    bool isEllipse(size_t e) => e < entities.length && entities[e].kind == EntityKind.ellipse;

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
            need(isLine(c.refs[0]) && (isRound(c.refs[1]) || isEllipse(c.refs[1])), "a line and a circle, arc or ellipse");
            break;
        case onEllipse:
            need(isPoint(c.refs[0]) && isEllipse(c.refs[1]), "a point and an ellipse");
            break;
        case radiusX, radiusY, ellipseAngle, equalRadii:
            need(isEllipse(c.refs[0]), "an ellipse");
            break;
        case tangentAt:
            need(isLine(c.refs[0]) && isRound(c.refs[1]) && isPoint(c.refs[2]), "a line, a circle or arc and a point");
            break;
        case direction:
            need(isPoint(c.refs[0]) && isPoint(c.refs[1]) && c.refs[0] != c.refs[1], "two different points");
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

    /// An ellipse with its radii made positive (the solver may flip their signs).
    void ellipseOf(size_t e, const(double)[] x, out double rx, out double ry, out double angle) const
    {
        immutable v = entities[e].var;
        rx = abs(x[v]);
        ry = abs(x[v + 1]);
        angle = wrap(x[v + 2]);
    }

    /// How far a circle, arc or ellipse reaches from its centre across a line:
    /// for an ellipse, its support along the line's normal (exact tangency).
    double reach(size_t curve, size_t line, const(double)[] x) const
    {
        auto en = entities[curve];
        if (en.kind != EntityKind.ellipse)
            return radiusOf(curve, x);
        auto d = dirOf(line, x);
        immutable dl = d.length;
        immutable nx = -d.y / dl, ny = d.x / dl;
        immutable v = en.var, a = x[v + 2];
        immutable nu = nx * cos(a) + ny * sin(a), nv = -nx * sin(a) + ny * cos(a);
        return sqrt((x[v] * nu) ^^ 2 + (x[v + 1] * nv) ^^ 2);
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
        case tangentLine: r[0] = c.sign * signedPart(c, x) - reach(c.refs[1], c.refs[0], x); break;
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
        case onEllipse:
            {
                // zero on the ellipse, scaled to a length so that it weighs like the other residuals
                immutable v = entities[c.refs[1]].var;
                immutable rx = x[v], ry = x[v + 1], a = x[v + 2];
                auto d = pos(c.refs[0], x) - pos(center(c.refs[1]), x);
                immutable u = d.x * cos(a) + d.y * sin(a), w = -d.x * sin(a) + d.y * cos(a);
                r[0] = (sqrt((u / rx) ^^ 2 + (w / ry) ^^ 2) - 1) * sqrt(abs(rx * ry));
                break;
            }
        case radiusX: r[0] = abs(x[entities[c.refs[0]].var]) - c.value; break;
        case radiusY: r[0] = abs(x[entities[c.refs[0]].var + 1]) - c.value; break;
        // an ellipse turned half a turn is the same ellipse
        case ellipseAngle: r[0] = remainder(x[entities[c.refs[0]].var + 2] - c.value, PI); break;
        case direction:
            {
                auto d = pos(c.refs[1], x) - pos(c.refs[0], x);
                r[0] = wrap(atan2(d.y, d.x) - c.value);
                break;
            }
        case tangentAt:
            {
                // where a line meets an arc, "tangent" alone holds to first order
                // wherever the point slides along the line: square radius instead
                auto d = dirOf(c.refs[0], x), q = pos(c.refs[2], x) - pos(center(c.refs[1]), x);
                r[0] = q.dot(d) / (d.length * q.length);
                break;
            }
        case equalRadii: r[0] = abs(x[entities[c.refs[0]].var]) - abs(x[entities[c.refs[0]].var + 1]); break;
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
    OutlineSource[] from;
    auto loop = sq.outline(from);
    assert(loop.length == 6);   // 4 lines + 1 arc + end
    // each segment knows its line; the fillet's arc, its corner
    assert(from.length == loop.length);
    size_t arcs;
    foreach (k, g; loop)
        if (g.kind == OutlineSeg.Kind.arc)
        {
            arcs++;
            assert(from[k].entity == size_t.max && from[k].corner == c2);
        }
        else if (g.kind == OutlineSeg.Kind.line)
            assert(sq.entities[from[k].entity].kind == EntityKind.line && from[k].corner == size_t.max);
    assert(arcs == 1);
}

unittest
{
    import std.math : isClose;
    // references: frozen, no freedom, constraints to them solved on the rest
    auto s = new Sketch;
    auto a = s.point(0, 0), b = s.point(30, 0);
    auto edge = s.line(a, b);
    foreach (e; [a, b, edge])
        s.freeze(e);
    auto ring = s.circle(s.point(0, 0), 5);
    s.freeze(ring);
    s.freeze(s.entities[ring].refs[0]);
    auto rep = s.solve();
    assert(rep.solved && rep.dof == 0 && rep.freePoints.length == 0 && rep.freeShapes.length == 0);
    // a point 4 above the edge, on the ring's centre's vertical: 2 freedoms taken, none left
    auto p = s.point(3, 7);
    s.constrain(ConstraintKind.pointLineDistance, [p, edge], 4);
    s.constrain(ConstraintKind.vertical, [s.line(s.entities[ring].refs[0], p, true)]);
    rep = s.solve();
    assert(rep.solved && rep.dof == 0, format("%s", rep));
    assert(isClose(s.position(p).y, 4, 1e-6) && abs(s.position(p).x) < 1e-6);
    assert(s.position(b).x == 30 && s.radius(ring) == 5);
    // a constraint between references that does not hold: a conflict, nothing moves
    s.constrain(ConstraintKind.vertical, [edge]);
    assert(!s.solve().solved && s.position(b).x == 30);
    // references are not part of the outline
    auto t = new Sketch;
    auto r = t.circle(t.point(0, 0), 10);
    t.freeze(r);
    t.circle(t.point(0, 0), 4);
    assert(t.outline().length == 2);   // the small circle and its end
}
