/// Constrained sketches in the language: `sketch()` returns an object whose
/// methods add geometry and constraints; `.profile` solves it and returns the
/// outline as a Profile.
module hackerscad.lang.sketchval;

import std.algorithm : map, sort, uniq;
import std.array : array, join;
import std.conv : to;
import std.format : format;

import hackerscad.geom.vec;
import hackerscad.kernel.brep : Brep;
import hackerscad.lang.builtins : Args, primitive;
import hackerscad.lang.errors;
import hackerscad.lang.interp;
import hackerscad.lang.value;
import hackerscad.sketch.sketch;

/// Registers `sketch()` in the prelude.
void installSketch(Interp it, void delegate(string, BuiltinImpl) def)
{
    def("sketch", (ref CallArgs a) {
        Args(it, a, "sketch", []);
        return Value.make(Kind.object_, new SketchVal(it, a.span));
    });
}

final class SketchVal : ObjectVal
{
    Interp it;
    Sketch sk;
    Span span;
    Span[] entitySpans;
    Span[] constraintSpans;   /// indexed by Constraint.tag
    Span[] valueSpans;        /// the value argument of each constraint (by tag), for editing
    bool[] diameters;         /// by tag: the value is a diameter
    private bool warned;

    this(Interp it, Span span)
    {
        this.it = it;
        this.span = span;
        sk = new Sketch;
        constraintSpans ~= span;   // tag 0: implicit constraints
        valueSpans ~= Span.init;
        diameters ~= false;
        it.sketches ~= this;
    }

    override string typeName() const => "Sketch";

    override string describe()
    {
        auto r = sk.report();
        return format("Sketch(%d entities, %d constraints, %s)", sk.entities.length, sk.constraints.length,
            !r.solved ? "conflicting" : r.dof ? format("%d degrees of freedom", r.dof) : "fully constrained");
    }

    override string[] memberNames() => ["point", "line", "arc", "circle", "polyline", "coincident", "fix", "horizontal",
        "vertical", "length", "distance", "on", "parallel", "perpendicular", "angle", "equal", "radius", "diameter",
        "tangent", "midpoint", "symmetric", "fillet", "profile", "dof", "solved"];

    override bool property(string name, Span at, out Value result)
    {
        switch (name)
        {
        case "profile": result = profile(at); return true;
        case "dof": result = Value.integer(sk.report().dof); return true;
        case "solved": result = Value.of(sk.report().solved); return true;
        default: return false;
        }
    }

    override BuiltinImpl method(string name)
    {
        switch (name)
        {
        case "point":
            return (ref CallArgs a) {
                // s.point(x, y): x and y are where to start; the constraints move it. fixed: true pins it there
                auto x = Args(it, a, "point", ["sketch", "x", "y", "fixed", "construction"]);
                immutable px = x.len("x"), py = x.len("y");
                auto id = sk.point(px, py, x.flag("construction", false));
                entitySpans.length = sk.entities.length;
                entitySpans[id] = a.span;
                if (x.flag("fixed", false))
                    add(ConstraintKind.fix, [id], a.span, px, py);
                return entity(id);
            };
        case "line":
            return (ref CallArgs a) {
                auto x = Args(it, a, "line", ["sketch", "start", "end", "construction"]);
                return made(a.span, () => sk.line(pointArg(x, "start"), pointArg(x, "end"), x.flag("construction", false)));
            };
        case "arc":
            return (ref CallArgs a) {
                // counter-clockwise from start to end around center
                auto x = Args(it, a, "arc", ["sketch", "center", "start", "end", "construction"]);
                return made(a.span, () => sk.arc(pointArg(x, "center"), pointArg(x, "start"), pointArg(x, "end"),
                    x.flag("construction", false)));
            };
        case "circle":
            return (ref CallArgs a) {
                // s.circle(c, r: 5.mm) has that radius; without r/d the radius is left to the constraints
                auto x = Args(it, a, "circle", ["sketch", "center", "r", "d", "construction"]);
                immutable given = x.has("r") || x.has("d");
                immutable r = given ? x.radius("r", "d") : 10;
                auto c = made(a.span, () => sk.circle(pointArg(x, "center"), r, x.flag("construction", false)));
                if (given)
                    add(ConstraintKind.radius, [idOf(c)], a.span, r, 0, x.spanOf(x.has("r") ? "r" : "d"), x.has("d"));
                return c;
            };
        case "polyline":
            return (ref CallArgs a) {
                // s.polyline([p1, p2, p3], closed: true): lines between consecutive points (SketchPoints or
                // vectors, which become new points)
                auto x = Args(it, a, "polyline", ["sketch", "points", "closed", "construction"]);
                auto v = x.get("points");
                if (v.kind != Kind.array || v.arr.length < 2)
                    throw new HcadError(Code.type, "polyline needs an array of at least 2 points", x.spanOf("points"));
                size_t[] ps;
                foreach (p; v.arr)
                {
                    if (p.kind == Kind.object_ && cast(SketchEntityVal) p.obj)
                        ps ~= pointOf(p, x.spanOf("points"));
                    else
                    {
                        auto q = vecOf(x, p, x.spanOf("points"));
                        ps ~= sk.point(q.x, q.y);
                        entitySpans.length = sk.entities.length;
                        entitySpans[ps[$ - 1]] = a.span;
                    }
                }
                immutable closed = x.flag("closed", true), cons = x.flag("construction", false);
                Value[] lines;
                foreach (i; 0 .. closed ? ps.length : ps.length - 1)
                    lines ~= made(a.span, () => sk.line(ps[i], ps[(i + 1) % ps.length], cons));
                return Value.of(lines);
            };
        case "coincident":
            return constraint("coincident", ["a", "b"], (ref Args x, Span s) {
                add(ConstraintKind.coincident, [pointArg(x, "a"), pointArg(x, "b")], s);
            });
        case "fix":
            return constraint("fix", ["point"], (ref Args x, Span s) {
                auto p = pointArg(x, "point");
                auto at = sk.position(p);
                add(ConstraintKind.fix, [p], s, at.x, at.y);
            });
        case "horizontal", "vertical":
            return constraint(name, ["a", "b"], (ref Args x, Span s) {
                // a line, or two points
                immutable h = name == "horizontal";
                if (x.has("b"))
                    add(h ? ConstraintKind.vdistance : ConstraintKind.hdistance, [pointArg(x, "a"), pointArg(x, "b")], s, 0);
                else
                    add(h ? ConstraintKind.horizontal : ConstraintKind.vertical, [lineArg(x, "a")], s);
            });
        case "length":
            return constraint("length", ["line", "value"], (ref Args x, Span s) {
                add(ConstraintKind.length, [lineArg(x, "line")], s, positiveLen(x, "value"), 0, x.spanOf("value"));
            });
        case "distance":
            return constraint("distance", ["a", "b", "value", "along"], (ref Args x, Span s) {
                // between two points (along: X or Y for one direction only) or from a point to a line
                immutable d = x.len("value");
                auto b = entityArg(x, "b");
                if (sk.entities[b].kind == EntityKind.line)
                    return add(ConstraintKind.pointLineDistance, [pointArg(x, "a"), b], s, d, 0, x.spanOf("value"));
                auto p = pointArg(x, "a"), q = pointArg(x, "b");
                if (!x.has("along"))
                    return add(ConstraintKind.distance, [p, q], s, positiveLen(x, "value"), 0, x.spanOf("value"));
                auto dir = x.dir("along");
                if (dir.x * dir.x > 0.999)
                    return add(ConstraintKind.hdistance, [p, q], s, d, 0, x.spanOf("value"));
                if (dir.y * dir.y > 0.999)
                    return add(ConstraintKind.vdistance, [p, q], s, d, 0, x.spanOf("value"));
                throw new HcadError(Code.type, "'along' must be X or Y", x.spanOf("along"));
            });
        case "on":
            return constraint("on", ["point", "curve"], (ref Args x, Span s) {
                auto p = pointArg(x, "point"), c = entityArg(x, "curve");
                add(sk.entities[c].kind == EntityKind.line ? ConstraintKind.onLine : ConstraintKind.onCircle, [p, c], s);
            });
        case "parallel":
            return constraint("parallel", ["a", "b"], (ref Args x, Span s) {
                add(ConstraintKind.parallel, [lineArg(x, "a"), lineArg(x, "b")], s);
            });
        case "perpendicular":
            return constraint("perpendicular", ["a", "b"], (ref Args x, Span s) {
                add(ConstraintKind.perpendicular, [lineArg(x, "a"), lineArg(x, "b")], s);
            });
        case "angle":
            return constraint("angle", ["a", "b", "value"], (ref Args x, Span s) {
                // between the directions of two lines (start → end)
                add(ConstraintKind.angle, [lineArg(x, "a"), lineArg(x, "b")], s, x.angle("value"), 0, x.spanOf("value"));
            });
        case "equal":
            return constraint("equal", ["a", "b"], (ref Args x, Span s) {
                // equal lengths (lines) or radii (circles, arcs)
                auto a = entityArg(x, "a"), b = entityArg(x, "b");
                add(sk.entities[a].kind == EntityKind.line ? ConstraintKind.equalLength : ConstraintKind.equalRadius, [a, b], s);
            });
        case "radius", "diameter":
            return constraint(name, ["circle", "value"], (ref Args x, Span s) {
                immutable v = positiveLen(x, "value");
                add(ConstraintKind.radius, [entityArg(x, "circle")], s, name == "radius" ? v : v / 2, 0, x.spanOf("value"),
                    name == "diameter");
            });
        case "tangent":
            return constraint("tangent", ["a", "b"], (ref Args x, Span s) {
                auto a = entityArg(x, "a"), b = entityArg(x, "b");
                if (sk.entities[b].kind == EntityKind.line)
                {
                    immutable t = a;
                    a = b;
                    b = t;
                }
                add(sk.entities[a].kind == EntityKind.line ? ConstraintKind.tangentLine : ConstraintKind.tangentCircles, [a, b], s);
            });
        case "midpoint":
            return constraint("midpoint", ["point", "line"], (ref Args x, Span s) {
                add(ConstraintKind.midpoint, [pointArg(x, "point"), lineArg(x, "line")], s);
            });
        case "symmetric":
            return constraint("symmetric", ["a", "b", "line"], (ref Args x, Span s) {
                add(ConstraintKind.symmetric, [pointArg(x, "a"), pointArg(x, "b"), lineArg(x, "line")], s);
            });
        case "fillet":
            return constraint("fillet", ["point", "r"], (ref Args x, Span s) {
                // rounds the corner where two lines meet at this point
                wrapErrors(s, () => sk.fillet(pointArg(x, "point"), positiveLen(x, "r")));
            });
        default:
            return null;
        }
    }

    /// The solved sketch, for drawing it over the 3D view.
    SketchView view()
    {
        SketchView v;
        v.span = span;
        auto rep = sk.report();
        v.solved = rep.solved;
        v.dof = rep.dof;
        bool[size_t] free;
        foreach (p; rep.freePoints)
            free[p] = true;
        // the outline as the profile will have it (with corner fillets), when it can be built
        import hackerscad.kernel.brep : OutlineSeg;
        OutlineSeg[] outline;
        if (rep.solved)
        {
            try
                outline = sk.outline();
            catch (SketchException)
            {
            }
        }
        foreach (g; outline)
        {
            if (g.kind == OutlineSeg.Kind.line)
                v.segments ~= SketchView.Segment(0, Vec3(g.ax, g.ay, 0), Vec3(g.bx, g.by, 0), Vec3.init, 0, false);
            else if (g.kind == OutlineSeg.Kind.arc)
            {
                // circle through the three points, counter-clockwise from a to b
                auto a = Vec3(g.ax, g.ay, 0), b = Vec3(g.bx, g.by, 0), m = Vec3(g.mx, g.my, 0);
                auto c = circumcentre(a, m, b);
                immutable ccw = (m - a).x * (b - a).y - (m - a).y * (b - a).x > 0;
                v.segments ~= SketchView.Segment(1, ccw ? a : b, ccw ? b : a, c, (a - c).length, false);
            }
        }
        foreach (i, e; sk.entities)
        {
            final switch (e.kind)
            {
            case EntityKind.point:
                v.points ~= SketchView.Point(sk.position(i), (i in free) !is null, i < entitySpans.length ? entitySpans[i] : span,
                    e.construction);
                break;
            case EntityKind.line:
                if (outline.length && !e.construction)
                    break;
                v.segments ~= SketchView.Segment(0, sk.position(e.refs[0]), sk.position(e.refs[1]), Vec3.init, 0, e.construction);
                break;
            case EntityKind.arc:
                if (outline.length && !e.construction)
                    break;
                v.segments ~= SketchView.Segment(1, sk.position(e.refs[1]), sk.position(e.refs[2]), sk.position(e.refs[0]),
                    sk.radius(i), e.construction);
                break;
            case EntityKind.circle:
                if (outline.length && !e.construction)
                    break;
                v.segments ~= SketchView.Segment(2, Vec3.init, Vec3.init, sk.position(e.refs[0]), sk.radius(i), e.construction);
                break;
            }
        }
        bool[size_t] conflicting;
        foreach (c; rep.conflicting)
            conflicting[c] = true;
        foreach (ci, c; sk.constraints)
        {
            if (c.tag >= valueSpans.length || valueSpans[c.tag] == Span.init)
                continue;
            SketchView.Dimension d;
            d.value = valueSpans[c.tag];
            d.conflicting = (ci in conflicting) !is null;
            auto P(size_t k) => sk.position(c.refs[k]);
            auto lineMid(size_t l) => (sk.position(sk.entities[l].refs[0]) + sk.position(sk.entities[l].refs[1])) * 0.5;
            switch (c.kind) with (ConstraintKind)
            {
            case length:
                d.at = lineMid(c.refs[0]);
                d.label = format("%.4g", c.value);
                break;
            case distance, hdistance, vdistance:
                d.at = (P(0) + P(1)) * 0.5;
                d.label = format("%.4g", c.value);
                break;
            case pointLineDistance:
                d.at = (P(0) + lineMid(c.refs[1])) * 0.5;
                d.label = format("%.4g", c.value);
                break;
            case radius:
                {
                    auto e = sk.entities[c.refs[0]];
                    auto ctr = sk.position(e.refs[0]);
                    immutable r = sk.radius(c.refs[0]);
                    d.at = ctr + Vec3(r * 0.7071, r * 0.7071, 0);
                    d.label = diameters[c.tag] ? format("⌀%.4g", 2 * c.value) : format("R%.4g", c.value);
                    break;
                }
            case angle:
                {
                    import std.math : PI;
                    d.at = (lineMid(c.refs[0]) + lineMid(c.refs[1])) * 0.5;
                    d.label = format("%.4g°", c.value * 180 / PI);
                    break;
                }
            default:
                continue;
            }
            v.dimensions ~= d;
        }
        return v;
    }

    // ------------------------------------------------------------ helpers

    Value entity(size_t id) => Value.make(Kind.object_, new SketchEntityVal(this, id));

    size_t idOf(Value v) => (cast(SketchEntityVal) v.obj).id;

    Value made(Span s, size_t delegate() f)
    {
        size_t id;
        wrapErrors(s, () { id = f(); });
        entitySpans.length = sk.entities.length;
        entitySpans[id] = s;
        return entity(id);
    }

    void add(ConstraintKind k, size_t[] refs, Span s, double v = 0, double v2 = 0, Span valueSpan = Span.init,
        bool diameter = false)
    {
        constraintSpans ~= s;
        valueSpans ~= valueSpan;
        diameters ~= diameter;
        wrapErrors(s, () => sk.constrain(k, refs, v, constraintSpans.length - 1, v2));
    }

    BuiltinImpl constraint(string name, string[] params, void delegate(ref Args, Span) f)
    {
        return (ref CallArgs a) {
            auto x = Args(it, a, name, ["sketch"] ~ params);
            f(x, a.span);
            return Value.void_;
        };
    }

    void wrapErrors(Span s, void delegate() f)
    {
        try
            f();
        catch (SketchException e)
            throw new HcadError(Code.sketch, e.msg, s);
    }

    size_t entityArg(ref Args x, string n) => entityOf(x.get(n), x.spanOf(n));

    size_t entityOf(Value v, Span s)
    {
        auto e = v.kind == Kind.object_ ? cast(SketchEntityVal) v.obj : null;
        if (e is null)
            throw new HcadError(Code.type, format("expected a sketch point, line, arc or circle, not %s", v.typeName), s);
        if (e.owner !is this)
            throw new HcadError(Code.type, "this entity belongs to another sketch", s);
        return e.id;
    }

    size_t pointOf(Value v, Span s)
    {
        auto id = entityOf(v, s);
        if (sk.entities[id].kind != EntityKind.point)
            throw new HcadError(Code.type, format("expected a SketchPoint, not %s", v.typeName), s);
        return id;
    }

    size_t pointArg(ref Args x, string n) => pointOf(x.get(n), x.spanOf(n));

    size_t lineArg(ref Args x, string n)
    {
        auto id = entityArg(x, n);
        if (sk.entities[id].kind != EntityKind.line)
            throw new HcadError(Code.type, format("'%s' must be a SketchLine, not %s", n, x.get(n).typeName), x.spanOf(n));
        return id;
    }

    double positiveLen(ref Args x, string n)
    {
        immutable v = x.len(n);
        if (v <= 0)
            throw new HcadError(Code.type, format("'%s' must be positive", n), x.spanOf(n));
        return v;
    }

    Vec3 vecOf(ref Args x, Value p, Span s)
    {
        import hackerscad.lang.builtins : arrayToVec;

        if (p.kind == Kind.array)
            p = arrayToVec(it, p.arr, x.raw.caller, s);
        if (p.kind != Kind.vec || (p.v.dim != Dim.length && p.v.dim != Dim.none))
            throw new HcadError(Code.type, format("expected a point (vector of lengths), not %s", p.typeName), s);
        return p.v.dim == Dim.none ? p.v.v * x.unitFactor : p.v.v;
    }

    string lines(size_t[] spansIdx, const(Span)[] table)
    {
        auto ls = spansIdx.map!(i => i < table.length ? table[i].line : 0).array.sort.uniq.map!(l => l.to!string).array;
        return ls.join(", ");
    }

    Value profile(Span at)
    {
        auto rep = sk.report();
        if (!rep.solved)
        {
            size_t[] tags;
            foreach (c; rep.conflicting)
                tags ~= sk.constraints[c].tag;
            throw new HcadError(Code.sketch, format("the sketch constraints conflict: check the constraints at line%s %s",
                tags.length > 1 ? "s" : "", lines(tags, constraintSpans)), tags.length ? constraintSpans[tags[0]] : span,
                "remove or change one of them");
        }
        import hackerscad.kernel.brep : OutlineSeg;

        OutlineSeg[] segs;
        try
            segs = sk.outline();
        catch (SketchException e)
        {
            auto where = e.entities.length && e.entities[0] < entitySpans.length ? entitySpans[e.entities[0]] : span;
            throw new HcadError(Code.sketch, e.msg, where);
        }
        if (rep.dof && !warned)
        {
            warned = true;
            it.diagnostics ~= Diagnostic(Severity.warning, Code.sketch,
                format("the sketch is under-constrained: %d degree%s of freedom left (free points at line%s %s)", rep.dof,
                    rep.dof > 1 ? "s" : "", rep.freePoints.length > 1 ? "s" : "", lines(rep.freePoints, entitySpans)),
                span, "add dimensions or constraints, or fix the points with fixed: true");
        }
        import hackerscad.kernel.brep : KernelException;

        Brep b;
        try
            b = it.kernel.outline(segs);
        catch (KernelException e)
            throw new HcadError(Code.kernel, e.msg, span, "does the outline cross itself?");
        auto sv = primitive(it, b, "sketch", span);
        sv.flat = true;
        return Value.of(sv);
    }
}

private Vec3 circumcentre(Vec3 a, Vec3 b, Vec3 c)
{
    immutable d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y));
    immutable a2 = a.x * a.x + a.y * a.y, b2 = b.x * b.x + b.y * b.y, c2 = c.x * c.x + c.y * c.y;
    return Vec3((a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
        (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d, 0);
}

/// Plain data of a solved sketch (safe to hand to another thread).
struct SketchView
{
    struct Point
    {
        Vec3 pos;
        bool free;          /// can still move: drawn in blue, as in Onshape
        Span span;
        bool construction;
    }

    struct Segment
    {
        int kind;           /// 0 line a → b, 1 arc around c from a to b (counter-clockwise), 2 circle around c
        Vec3 a, b, c;
        double r;
        bool construction;
    }

    struct Dimension
    {
        Vec3 at;            /// where to show the label
        string label;
        Span value;         /// the value argument in the source, to edit it
        bool conflicting;
    }

    Span span;
    bool solved;
    size_t dof;
    Point[] points;
    Segment[] segments;
    Dimension[] dimensions;
}

final class SketchEntityVal : ObjectVal
{
    SketchVal owner;
    size_t id;

    this(SketchVal owner, size_t id)
    {
        this.owner = owner;
        this.id = id;
    }

    private Entity e() const => owner.sk.entities[id];

    override string typeName() const
    {
        final switch (e.kind)
        {
        case EntityKind.point: return "SketchPoint";
        case EntityKind.line: return "SketchLine";
        case EntityKind.arc: return "SketchArc";
        case EntityKind.circle: return "SketchCircle";
        }
    }

    override string describe()
    {
        Value v;
        if (e.kind == EntityKind.point && property("pos", Span.init, v))
            return "SketchPoint" ~ v.toString;
        return typeName;
    }

    override string[] memberNames()
    {
        final switch (e.kind)
        {
        case EntityKind.point: return ["x", "y", "pos"];
        case EntityKind.line: return ["start", "end", "length", "mid"];
        case EntityKind.arc: return ["center", "start", "end", "radius"];
        case EntityKind.circle: return ["center", "radius"];
        }
    }

    override bool property(string name, Span at, out Value result)
    {
        auto sk = owner.sk;
        Value len(double x) => Value.number(x, Dim.length);
        Value point(size_t p) => owner.entity(p);
        Value vec2(Vec3 v) => Value.vector(v, 2, Dim.length);
        final switch (e.kind)
        {
        case EntityKind.point:
            {
                auto p = sk.position(id);
                switch (name)
                {
                case "x": result = len(p.x); return true;
                case "y": result = len(p.y); return true;
                case "pos": result = vec2(p); return true;
                default: return false;
                }
            }
        case EntityKind.line:
            switch (name)
            {
            case "start": result = point(e.refs[0]); return true;
            case "end": result = point(e.refs[1]); return true;
            case "length": result = len((sk.position(e.refs[1]) - sk.position(e.refs[0])).length); return true;
            case "mid": result = vec2((sk.position(e.refs[0]) + sk.position(e.refs[1])) * 0.5); return true;
            default: return false;
            }
        case EntityKind.arc:
            switch (name)
            {
            case "center": result = point(e.refs[0]); return true;
            case "start": result = point(e.refs[1]); return true;
            case "end": result = point(e.refs[2]); return true;
            case "radius": result = len(sk.radius(id)); return true;
            default: return false;
            }
        case EntityKind.circle:
            switch (name)
            {
            case "center": result = point(e.refs[0]); return true;
            case "radius": result = len(sk.radius(id)); return true;
            default: return false;
            }
        }
    }
}
