/// Constrained sketches in the language: `sketch()` returns an object whose
/// methods add geometry and constraints; `.profile` solves it and returns the
/// outline as a Profile.
module hackerscad.lang.sketchval;

import std.algorithm : map, sort, uniq;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.math : abs, cos, sin;

import hackerscad.geom.vec;
import hackerscad.kernel.brep : Brep;
import hackerscad.lang.builtins : Args, primitive, polygonFit;
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
    // the profiles of the shapes a sketch has: one-shape sketches with everything given (polygon's
    // form through points is in builtins.d, and comes here for a regular one)
    foreach (name; ["rect", "circle", "ellipse", "slot", "teardrop"])
        def(name, shapeBuiltin(it, name));
}

/// rect(…), circle(…)…: the profile of a one-shape sketch with everything given, made by the
/// sketch's own method (the centre, when not given, at the origin).
BuiltinImpl shapeBuiltin(Interp it, string name) => (ref CallArgs a) => shapeProfile(it, a, name);

/// ditto
Value shapeProfile(Interp it, ref CallArgs a, string name)
{
    auto sv = new SketchVal(it, a.span, true);
    auto x = Args(it, a, name, shapeParams(name, a, 0));
    sv.shape(name, x, a.span);
    return sv.shapeProfile(name, a.span);
}

/// Whether a value stands for a point: a vector, a SketchPoint, or [x, y].
bool isPointArg(Value v)
{
    import std.algorithm : all;
    if (v.kind == Kind.vec)
        return true;
    if (v.kind == Kind.object_)
        return cast(SketchEntityVal) v.obj !is null;
    return v.kind == Kind.array && (v.arr.length == 2 || v.arr.length == 3) && v.arr.all!(e => e.isNum);
}

/// The parameters of a shape (the same for the profile and the sketch's method), in the order its
/// positional arguments fill them from argument `first` on: those of the form by its size when
/// that argument is a number (rect(w, h), circle(r), polygon(n, …), slot(length, w)…), of the
/// form from points when it is a point (rect(p, q), circle(c, r), slot(p, q, w:)…), and for
/// polygon an array of points, polygon([p1, p2, p3]).
string[] shapeParams(string name, ref CallArgs a, size_t first)
{
    immutable sized = a.positional.length > first && a.positional[first].isNum;
    if (name == "polygon" && (a.positional.length > first ? !sized && !isPointArg(a.positional[first])
            : ("points" in a.named) !is null))
        return ["points", "smooth"];
    switch (name)
    {
    case "rect": return sized ? ["w", "h", "center", "angle", "corner", "p", "q"]
        : ["p", "q", "center", "w", "h", "angle", "corner"];
    case "circle": return sized ? ["r", "d", "center"] : ["center", "r", "d"];
    case "ellipse": return sized ? ["rx", "ry", "angle", "center"] : ["center", "rx", "ry", "angle"];
    case "polygon": return sized ? ["n", "r", "d", "fit", "angle", "center"] : ["center", "n", "r", "d", "fit", "angle"];
    case "slot": return sized ? ["length", "w", "center", "angle", "p", "q"] : ["p", "q", "w", "length", "center", "angle"];
    case "teardrop": return sized ? ["r", "d", "angle", "flat", "center"] : ["center", "r", "d", "angle", "flat"];
    default: assert(0, name);
    }
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
    string[] constraintKinds; /// by tag: the method that made it ("tangent", "fillet"…)
    size_t[][] constraintRefs;   /// by tag: the entities it involves
    Span[] profileSpans;      /// where `.profile` was read
    bool asProfile;           /// a profile's one-shape sketch: everything given, not shown as a sketch
    private bool warned;
    private string calling;   /// the constraint method running

    this(Interp it, Span span, bool asProfile = false)
    {
        this.it = it;
        this.span = span;
        this.asProfile = asProfile;
        sk = new Sketch;
        constraintSpans ~= span;   // tag 0: implicit constraints
        valueSpans ~= Span.init;
        diameters ~= false;
        constraintKinds ~= "";
        constraintRefs ~= null;
        if (!asProfile)
            it.sketches ~= this;
    }

    override string typeName() const => "Sketch";

    override string describe()
    {
        auto r = sk.report();
        return format("Sketch(%d entities, %d constraints, %s)", sk.entities.length, sk.constraints.length,
            !r.solved ? "conflicting" : r.dof ? format("%d degrees of freedom", r.dof) : "fully constrained");
    }

    override string[] memberNames() => ["point", "line", "arc", "circle", "ellipse", "polyline", "rect", "polygon",
        "slot", "teardrop", "coincident", "concentric", "fix", "horizontal", "vertical", "length", "distance", "on", "parallel",
        "perpendicular", "angle", "equal", "radius", "diameter", "tangent", "midpoint", "symmetric", "fillet",
        "profile", "dof", "solved"];

    override bool property(string name, Span at, out Value result)
    {
        switch (name)
        {
        case "profile":
            {
                import std.algorithm : canFind;
                if (!profileSpans.canFind(at))
                    profileSpans ~= at;
                result = profile(at);
                return true;
            }
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
                calling = "fix";
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
        case "polyline":
            return (ref CallArgs a) {
                // s.polyline([p1, p2, p3], closed: true): lines between consecutive points (SketchPoints or
                // vectors, which become new points)
                auto x = Args(it, a, "polyline", ["sketch", "points", "closed", "construction"]);
                return polyline(x, x.flag("closed", true), a.span);
            };
        case "circle", "ellipse", "rect", "polygon", "slot", "teardrop":
            return (ref CallArgs a) {
                auto x = Args(it, a, name, ["sketch"] ~ shapeParams(name, a, 1) ~ ["construction"]);
                return shape(name, x, a.span);
            };
        case "coincident":
            return constraint("coincident", ["a", "b"], (ref Args x, Span s) {
                add(ConstraintKind.coincident, [pointArg(x, "a"), pointArg(x, "b")], s);
            });
        case "concentric":
            return constraint("concentric", ["a", "b"], (ref Args x, Span s) {
                // circles, arcs or ellipses (or a point) round the same centre
                auto a = entityArg(x, "a"), b = entityArg(x, "b");
                size_t centreOf(size_t e, string n)
                {
                    final switch (sk.entities[e].kind)
                    {
                    case EntityKind.point: return e;
                    case EntityKind.arc, EntityKind.circle, EntityKind.ellipse: return sk.entities[e].refs[0];
                    case EntityKind.line:
                        throw new HcadError(Code.type, format("'%s' must be a circle, an arc, an ellipse or a point", n),
                            x.spanOf(n));
                    }
                }
                immutable ca = centreOf(a, "a"), cb = centreOf(b, "b");
                record(calling, [a, b], s, Span.init, false);
                if (ca != cb)
                    wrapErrors(s, () => sk.constrain(ConstraintKind.coincident, [ca, cb], 0, constraintSpans.length - 1));
            });
        case "fix":
            return constraint("fix", ["point"], (ref Args x, Span s) {
                auto p = pointArg(x, "point");
                auto at = sk.position(p);
                add(ConstraintKind.fix, [p], s, at.x, at.y);
            });
        case "horizontal", "vertical":
            return constraint(name, ["a", "b"], (ref Args x, Span s) {
                // a line, two points, or an ellipse (its x axis)
                import std.math : PI;
                immutable h = name == "horizontal";
                if (x.has("b"))
                    add(h ? ConstraintKind.vdistance : ConstraintKind.hdistance, [pointArg(x, "a"), pointArg(x, "b")], s, 0);
                else if (sk.entities[entityArg(x, "a")].kind == EntityKind.ellipse)
                    add(ConstraintKind.ellipseAngle, [entityArg(x, "a")], s, h ? 0 : PI / 2);
                else
                    add(h ? ConstraintKind.horizontal : ConstraintKind.vertical, [lineArg(x, "a")], s);
            });
        case "length":
            return constraint("length", ["line", "value"], (ref Args x, Span s) {
                add(ConstraintKind.length, [lineArg(x, "line")], s, positiveLen(x, "value"), 0, x.spanOf("value"));
            });
        case "distance":
            return constraint("distance", ["a", "b", "value", "along"], (ref Args x, Span s) {
                // between two points (along: X or Y for one direction only) or from a point to a line;
                // which side is the drawing's, so a distance is never negative (a minus sign would
                // only flip it to the other side, against what the drawing shows)
                immutable d = x.len("value");
                if (d < 0)
                    throw new HcadError(Code.type, "a distance is not negative: the side comes from where the "
                        ~ "points are drawn", x.spanOf("value"));
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
                // a point on a curve; a shape's lines (s.rect, s.polygon, s.polyline) on a circle or
                // ellipse: every corner on it, the shape inscribed
                auto c = entityArg(x, "curve");
                immutable k = sk.entities[c].kind;
                immutable kind = k == EntityKind.line ? ConstraintKind.onLine : k == EntityKind.ellipse
                    ? ConstraintKind.onEllipse : ConstraintKind.onCircle;
                if (auto lines = linesOf(x.get("point"), x.spanOf("point")))
                {
                    foreach (l; lines)
                        add(kind, [sk.entities[l].refs[0], c], s);
                    return;
                }
                add(kind, [pointArg(x, "point"), c], s);
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
                // between the directions of two lines (start → end); s.angle(line, v): of one line from X;
                // s.angle(ellipse, v): of the ellipse's x axis from X
                immutable one = !x.has("b") || !(x.get("b").kind == Kind.object_ && cast(SketchEntityVal) x.get("b").obj);
                if (!one)
                    return add(ConstraintKind.angle, [lineArg(x, "a"), lineArg(x, "b")], s, x.angle("value"), 0,
                        x.spanOf("value"));
                immutable v = x.has("b") ? "b" : "value";
                if (x.has("b") && x.has("value"))
                    throw new HcadError(Code.type, "'b' must be a SketchLine", x.spanOf("b"));
                auto a = entityArg(x, "a");
                if (sk.entities[a].kind == EntityKind.ellipse)
                    return add(ConstraintKind.ellipseAngle, [a], s, x.angle(v), 0, x.spanOf(v));
                auto l = lineArg(x, "a");
                record(calling, [l], s, x.spanOf(v), false);
                wrapErrors(s, () => sk.constrain(ConstraintKind.direction, sk.entities[l].refs[0 .. 2].dup, x.angle(v),
                    constraintSpans.length - 1));
            });
        case "equal":
            return constraint("equal", ["a", "b"], (ref Args x, Span s) {
                // equal lengths (lines) or radii (circles, arcs); s.equal(e): an ellipse as wide as tall
                auto a = entityArg(x, "a");
                if (!x.has("b") && sk.entities[a].kind == EntityKind.ellipse)
                    return add(ConstraintKind.equalRadii, [a], s);
                auto b = entityArg(x, "b");
                add(sk.entities[a].kind == EntityKind.line ? ConstraintKind.equalLength : ConstraintKind.equalRadius, [a, b], s);
            });
        case "radius", "diameter":
            return constraint(name, ["circle", "value", "rx", "ry"], (ref Args x, Span s) {
                // an ellipse's: s.radius(e, rx: 20.mm, ry: 12.mm), either or both
                auto c = entityArg(x, "circle");
                if (sk.entities[c].kind == EntityKind.ellipse)
                {
                    if (name == "diameter" || x.has("value") || !(x.has("rx") || x.has("ry")))
                        throw new HcadError(Code.type, "an ellipse has two radii: s.radius(e, rx: …, ry: …) "
                            ~ "(s.equal(e) makes them equal)",
                            x.spanOf(x.has("value") ? "value" : "circle"));
                    if (x.has("rx"))
                        add(ConstraintKind.radiusX, [c], s, positiveLen(x, "rx"), 0, x.spanOf("rx"));
                    if (x.has("ry"))
                        add(ConstraintKind.radiusY, [c], s, positiveLen(x, "ry"), 0, x.spanOf("ry"));
                    return;
                }
                foreach (n; ["rx", "ry"])
                    if (x.has(n))
                        throw new HcadError(Code.unknownArg, format("'%s' is for ellipses", n), x.spanOf(n));
                immutable v = positiveLen(x, "value");
                add(ConstraintKind.radius, [c], s, name == "radius" ? v : v / 2, 0, x.spanOf("value"), name == "diameter");
            });
        case "tangent":
            return constraint("tangent", ["a", "b"], (ref Args x, Span s) {
                // a shape's lines (s.rect, s.polygon, s.polyline) and a circle or ellipse: every side
                // touching it, the shape round it
                if (auto lines = linesOf(x.get("a"), x.spanOf("a")))
                {
                    auto round = entityArg(x, "b");
                    if (sk.entities[round].kind == EntityKind.line || sk.entities[round].kind == EntityKind.point)
                        throw new HcadError(Code.type, "a shape is tangent to a circle, an arc or an ellipse",
                            x.spanOf("b"));
                    foreach (l; lines)
                        add(ConstraintKind.tangentLine, [l, round], s);
                    return;
                }
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
                auto p = pointArg(x, "point");
                wrapErrors(s, () => sk.fillet(p, positiveLen(x, "r")));
                record("fillet", [p], s, x.spanOf("r"), false);   // a tag of its own, with no equation
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
        v.profiles = profileSpans.dup;
        auto rep = sk.report();
        v.solved = rep.solved;
        v.dof = rep.dof;
        bool[size_t] free;
        foreach (p; rep.freePoints)
            free[p] = true;
        Span spanOf(size_t e) => e < entitySpans.length && entitySpans[e] != Span.init ? entitySpans[e] : span;
        foreach (i, e; sk.entities)
            v.entities ~= SketchView.Entity(["point", "line", "arc", "circle", "ellipse"][e.kind], spanOf(i), e.construction);
        // the outline as the profile will have it (with corner fillets), when it can be built
        import hackerscad.kernel.brep : OutlineSeg;
        OutlineSeg[] outline;
        OutlineSource[] sources;
        if (rep.solved)
        {
            try
                outline = sk.outline(sources);
            catch (SketchException)
            {
            }
        }
        // the call that made a fillet, by corner point
        Span[size_t] filletAt;
        foreach (tag, kind; constraintKinds)
            if (kind == "fillet" && constraintRefs[tag].length)
                filletAt[constraintRefs[tag][0]] = constraintSpans[tag];
        foreach (k, g; outline)
        {
            auto from = k < sources.length ? sources[k] : OutlineSource.init;
            SketchView.Segment seg;
            if (from.entity != size_t.max)
            {
                seg.entity = from.entity;
                seg.span = spanOf(from.entity);
            }
            else if (from.corner != size_t.max)
            {
                seg.corner = from.corner;
                seg.span = filletAt.get(from.corner, span);
            }
            if (g.kind == OutlineSeg.Kind.line)
            {
                seg.kind = 0;
                seg.a = Vec3(g.ax, g.ay, 0);
                seg.b = Vec3(g.bx, g.by, 0);
                v.segments ~= seg;
            }
            else if (g.kind == OutlineSeg.Kind.arc)
            {
                // circle through the three points, counter-clockwise from a to b
                auto a = Vec3(g.ax, g.ay, 0), b = Vec3(g.bx, g.by, 0), m = Vec3(g.mx, g.my, 0);
                auto c = circumcentre(a, m, b);
                immutable ccw = (m - a).x * (b - a).y - (m - a).y * (b - a).x > 0;
                seg.kind = 1;
                seg.a = ccw ? a : b;
                seg.b = ccw ? b : a;
                seg.c = c;
                seg.r = (a - c).length;
                v.segments ~= seg;
            }
            else if (g.kind == OutlineSeg.Kind.ellipse)
            {
                // a circle's outline is a round ellipse: drawn as the circle it is
                seg.kind = from.entity != size_t.max && sk.entities[from.entity].kind == EntityKind.circle ? 2 : 3;
                seg.c = Vec3(g.ax, g.ay, 0);
                seg.r = g.bx;
                seg.r2 = g.by;
                seg.angle = g.mx;
                v.segments ~= seg;
            }
        }
        foreach (i, e; sk.entities)
        {
            SketchView.Segment seg;
            seg.entity = i;
            seg.span = spanOf(i);
            seg.construction = e.construction;
            final switch (e.kind)
            {
            case EntityKind.point:
                v.points ~= SketchView.Point(sk.position(i), (i in free) !is null, spanOf(i), e.construction, i);
                continue;
            case EntityKind.line:
                seg.kind = 0;
                seg.a = sk.position(e.refs[0]);
                seg.b = sk.position(e.refs[1]);
                break;
            case EntityKind.arc:
                seg.kind = 1;
                seg.a = sk.position(e.refs[1]);
                seg.b = sk.position(e.refs[2]);
                seg.c = sk.position(e.refs[0]);
                seg.r = sk.radius(i);
                break;
            case EntityKind.circle:
                seg.kind = 2;
                seg.c = sk.position(e.refs[0]);
                seg.r = sk.radius(i);
                break;
            case EntityKind.ellipse:
                seg.kind = 3;
                seg.c = sk.position(e.refs[0]);
                sk.ellipseAxes(i, seg.r, seg.r2, seg.angle);
                break;
            }
            // the outline already drew it, trimmed by its fillets
            if (outline.length && !e.construction)
                continue;
            v.segments ~= seg;
        }

        // every constraint call, valueless ones too (tag 0, the implicit ones, is not a call)
        bool[size_t] conflicting;   // by tag
        foreach (c; rep.conflicting)
            conflicting[sk.constraints[c].tag] = true;
        foreach (tag; 1 .. constraintSpans.length)
        {
            SketchView.Constraint rc;
            rc.kind = constraintKinds[tag];
            rc.span = constraintSpans[tag];
            rc.entities = constraintRefs[tag].dup;
            rc.conflicting = (tag in conflicting) !is null;
            // a fillet rounds the corner of the lines that meet at its point
            if (rc.kind == "fillet" && rc.entities.length)
            {
                auto at = sk.position(rc.entities[0]);
                foreach (i, e; sk.entities)
                    if (e.kind == EntityKind.line && !e.construction)
                        foreach (q; e.refs[0 .. 2])
                            if ((sk.position(q) - at).length < 1e-6 * (1 + at.length))
                            {
                                rc.entities ~= i;
                                break;
                            }
            }
            v.constraints ~= rc;
        }

        foreach (c; sk.constraints)
        {
            if (c.tag >= valueSpans.length || valueSpans[c.tag] == Span.init)
                continue;
            SketchView.Dimension d;
            d.value = valueSpans[c.tag];
            d.conflicting = (c.tag in conflicting) !is null;
            d.constraint = c.tag - 1;
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
            case direction:
                {
                    import std.math : PI;
                    d.at = (P(0) + P(1)) * 0.5;
                    d.label = format("%.4g°", c.value * 180 / PI);
                    break;
                }
            case radiusX, radiusY, ellipseAngle:
                {
                    import std.math : PI;
                    double rx, ry, t;
                    sk.ellipseAxes(c.refs[0], rx, ry, t);
                    auto ux = Vec3(cos(t), sin(t), 0), uy = Vec3(-sin(t), cos(t), 0);
                    auto ctr = sk.position(sk.entities[c.refs[0]].refs[0]);
                    // each at its own end of an axis, so that the three do not pile up on a small ellipse
                    if (c.kind == radiusX)
                    {
                        d.at = ctr + ux * rx;
                        d.label = format("Rx%.4g", c.value);
                    }
                    else if (c.kind == radiusY)
                    {
                        d.at = ctr + uy * ry;
                        d.label = format("Ry%.4g", c.value);
                    }
                    else
                    {
                        d.at = ctr - ux * rx;
                        d.label = format("%.4g°", c.value * 180 / PI);
                    }
                    break;
                }
            default:
                continue;
            }
            if (d.constraint < v.constraints.length)
                v.constraints[d.constraint].dimension = v.dimensions.length;
            v.dimensions ~= d;
        }

        // corner fillets have no equation: their radius shown on their arc
        Vec3[size_t] filletMid;
        foreach (k, g; outline)
            if (k < sources.length && sources[k].corner != size_t.max)
                filletMid[sources[k].corner] = Vec3(g.mx, g.my, 0);
        foreach (tag, kind; constraintKinds)
        {
            if (kind != "fillet" || valueSpans[tag] == Span.init || !constraintRefs[tag].length)
                continue;
            immutable p = constraintRefs[tag][0];
            auto r = p in sk.fillets;
            if (r is null)
                continue;
            SketchView.Dimension d;
            d.value = valueSpans[tag];
            d.constraint = tag - 1;
            d.at = filletMid.get(p, sk.position(p));
            d.label = format("R%.4g", *r);
            v.constraints[d.constraint].dimension = v.dimensions.length;
            v.dimensions ~= d;
        }
        return v;
    }

    // ------------------------------------------------------------ shapes
    // One way to build each shape, for both levels: s.rect(…) in a sketch, and rect(…), the
    // profile, a one-shape sketch with everything given (asProfile). The points are made where
    // the constraints put them, so a profile's sketch needs no solving.

    Value shape(string name, ref Args x, Span s)
    {
        switch (name)
        {
        case "circle": return circleShape(x, s);
        case "ellipse": return ellipseShape(x, s);
        case "rect": return rectShape(x, s);
        case "polygon": return x.has("points") ? polygonOfPoints(x, s) : polygonShape(x, s);
        case "slot": return slotShape(x, s);
        case "teardrop": return teardropShape(x, s);
        default: assert(0, name);
        }
    }

    /// The outline of a one-shape sketch with everything given: a profile's rect, circle…
    Value shapeProfile(string kind, Span at)
    {
        import hackerscad.kernel.brep : KernelException, OutlineSeg;

        sk.assumeSolved();
        OutlineSeg[] segs;
        try
            segs = sk.outline();
        catch (SketchException e)
            throw new HcadError(Code.sketch, e.msg, at);
        Brep b;
        try
            b = it.kernel.outline(segs);
        catch (KernelException e)
            throw new HcadError(Code.kernel, e.msg, at);
        auto sv = primitive(it, b, kind, at);
        sv.flat = true;
        return Value.of(sv);
    }

    bool construction(ref Args x) => x.flag("construction", false);

    /// center:, or a new point at the origin.
    size_t centreOf(ref Args x, Span s) => x.has("center") ? pointOrNew(x, "center", s) : newPoint(0, 0, s);

    /// r: or d:, when given (and positive); a profile needs one.
    bool radiusGiven(ref Args x, string what, ref double r)
    {
        if (!(x.has("r") || x.has("d")) && !asProfile)
            return false;
        r = x.radius("r", "d");
        if (!(r > 0))
            throw new HcadError(Code.type, format("%s's radius must be positive", what), x.spanOf(x.has("r") ? "r" : "d"));
        return true;
    }

    void radiusDimension(ref Args x, size_t round, double r, Span s)
    {
        calling = x.has("d") ? "diameter" : "radius";
        add(ConstraintKind.radius, [round], s, r, 0, x.spanOf(x.has("r") ? "r" : "d"), x.has("d"));
    }

    Value circleShape(ref Args x, Span s)
    {
        // s.circle(c, r: 5.mm) has that radius; without r/d the radius is left to the constraints
        double r = 10;
        immutable given = radiusGiven(x, "a circle", r);
        auto ctr = centreOf(x, s);
        auto c = made(s, () => sk.circle(ctr, r, construction(x)));
        if (given)
            radiusDimension(x, idOf(c), r, s);
        return c;
    }

    Value ellipseShape(ref Args x, Span s)
    {
        // s.ellipse(c, rx: 20.mm, ry: 12.mm, angle: 30.deg): rx along its own x axis, angle from X;
        // what is not given is left to the constraints, as a circle's radius
        if (asProfile)
            foreach (n; ["rx", "ry"])
                positiveLen(x, n);
        immutable rx = x.has("rx") ? positiveLen(x, "rx") : x.has("ry") ? 1.6 * positiveLen(x, "ry") : 10;
        immutable ry = x.has("ry") ? positiveLen(x, "ry") : 0.6 * rx;
        immutable angle = x.angleOr("angle", 0);
        auto ctr = centreOf(x, s);
        auto e = made(s, () => sk.ellipse(ctr, rx, ry, angle, construction(x)));
        calling = "radius";
        if (x.has("rx"))
            add(ConstraintKind.radiusX, [idOf(e)], s, rx, 0, x.spanOf("rx"));
        if (x.has("ry"))
            add(ConstraintKind.radiusY, [idOf(e)], s, ry, 0, x.spanOf("ry"));
        calling = "angle";
        if (x.has("angle"))
            add(ConstraintKind.ellipseAngle, [idOf(e)], s, angle, 0, x.spanOf("angle"));
        return e;
    }

    Value rectShape(ref Args x, Span s)
    {
        // s.rect(p, q): p and q opposite corners; s.rect(center: c, w: 40.mm, h: 20.mm), or round a
        // new point at the origin without center:. The lines go p → (q.x, p.y) → q → (p.x, q.y) → p:
        // bottom, right, top, left when p is the lower left corner. angle: 30.deg turns it (its
        // first side that far from X); angle: "free" leaves the turn to the constraints
        // (s.parallel(r[0], line) lays it along a slanted line). A profile's h is w when not given
        immutable cons = construction(x);
        bool turned, free;
        double turn = 0;
        if (x.has("angle"))
        {
            turned = true;
            auto av = x.get("angle");
            if (av.kind == Kind.str)
            {
                if (av.s != "free" || asProfile)
                    throw new HcadError(Code.type, asProfile ? "a profile's angle is an angle (\"free\" is for "
                        ~ "sketches)" : "a rectangle's angle is an angle, or \"free\"", x.spanOf("angle"));
                free = true;
            }
            else
                turn = x.angle("angle");
        }
        // the directions of its sides: along the first, and across
        immutable u = Vec3(cos(turn), sin(turn), 0), v = Vec3(-sin(turn), cos(turn), 0);
        size_t[4] c;
        size_t ctr = size_t.max;
        double hDefault(double w) => asProfile ? w : 10;
        if (!x.has("p") && !x.has("q"))
        {
            // round its centre
            if (asProfile)
                positiveLen(x, "w");
            ctr = centreOf(x, s);
            immutable o = sk.guess(ctr);
            immutable w = x.has("w") ? positiveLen(x, "w") : 20, h = x.has("h") ? positiveLen(x, "h") : hDefault(w);
            foreach (i, d; [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(1, 1, 0), Vec3(-1, 1, 0)])
            {
                immutable q = Vec3(o.x, o.y, 0) + u * (d.x * w / 2) + v * (d.y * h / 2);
                c[i] = newPoint(q.x, q.y, s);
            }
        }
        else if (x.has("center"))
            throw new HcadError(Code.unknownArg, "give either corners or center:", x.spanOf("center"));
        else if (!x.has("p"))
            throw new HcadError(Code.missingArg, "q is the corner opposite p: give p too", x.spanOf("q"));
        else if (!x.has("q"))
        {
            // one corner and the size: the rest of it along and across from there
            if (!x.has("w") || (!x.has("h") && !asProfile))
                throw new HcadError(Code.missingArg, "a rectangle from one corner needs w: and h: (or give "
                    ~ "the opposite corner)", s);
            immutable w = positiveLen(x, "w"), h = x.has("h") ? positiveLen(x, "h") : w;
            c[0] = pointOrNew(x, "p", s);
            immutable o = sk.guess(c[0]);
            foreach (i, q; [u * w, u * w + v * h, v * h])
            {
                immutable at = Vec3(o.x, o.y, 0) + q;
                c[i + 1] = newPoint(at.x, at.y, s);
            }
        }
        else
        {
            foreach (n; ["w", "h"])
                if (x.has(n))
                    throw new HcadError(Code.unknownArg, format("'%s' goes with center: or with one corner; two "
                        ~ "corners already give the size", n), x.spanOf(n));
            c[0] = pointOrNew(x, "p", s);
            c[2] = pointOrNew(x, "q", s);
            immutable p = sk.guess(c[0]), q = sk.guess(c[2]);
            // the diagonal along and across the sides
            immutable dq = Vec3(q.x - p.x, q.y - p.y, 0), along = dq.dot(u), across = dq.dot(v);
            if (abs(along) < 1e-9 || abs(across) < 1e-9)
                throw new HcadError(Code.type, turned
                    ? "the opposite corners of a rectangle must not lie along one of its sides"
                    : "the opposite corners of a rectangle must differ in x and in y", x.spanOf("q"));
            immutable c1 = Vec3(p.x, p.y, 0) + u * along, c3 = Vec3(p.x, p.y, 0) + v * across;
            c[1] = newPoint(c1.x, c1.y, s);
            c[3] = newPoint(c3.x, c3.y, s);
        }
        Value[] lines;
        foreach (i; 0 .. 4)
            lines ~= made(s, () => sk.line(c[i], c[(i + 1) % 4], cons));
        if (!turned)
        {
            calling = "horizontal";
            add(ConstraintKind.horizontal, [idOf(lines[0])], s);
            add(ConstraintKind.horizontal, [idOf(lines[2])], s);
            calling = "vertical";
            add(ConstraintKind.vertical, [idOf(lines[1])], s);
            add(ConstraintKind.vertical, [idOf(lines[3])], s);
        }
        else
        {
            // square corners, opposite sides parallel: a rectangle that can turn
            calling = "perpendicular";
            add(ConstraintKind.perpendicular, [idOf(lines[0]), idOf(lines[1])], s);
            calling = "parallel";
            add(ConstraintKind.parallel, [idOf(lines[0]), idOf(lines[2])], s);
            add(ConstraintKind.parallel, [idOf(lines[1]), idOf(lines[3])], s);
            if (!free)
            {
                calling = "angle";
                add(ConstraintKind.direction, [c[0], c[1]], s, turn, 0, x.spanOf("angle"));
            }
        }
        if (ctr != size_t.max)
        {
            // the centre halves a diagonal
            auto diag = made(s, () => sk.line(c[0], c[2], true));
            calling = "midpoint";
            add(ConstraintKind.midpoint, [ctr, idOf(diag)], s);
        }
        if (ctr != size_t.max || !x.has("q"))
        {
            calling = "length";
            if (x.has("w"))
                add(ConstraintKind.length, [idOf(lines[0])], s, positiveLen(x, "w"), 0, x.spanOf("w"));
            if (x.has("h"))
                add(ConstraintKind.length, [idOf(lines[1])], s, positiveLen(x, "h"), 0, x.spanOf("h"));
        }
        if (x.has("corner"))
        {
            // one dimension for the four, on the upper right corner (when p is the lower left one)
            immutable r = positiveLen(x, "corner");
            foreach (i, p; c)
            {
                wrapErrors(s, () => sk.fillet(p, r));
                record("fillet", [p], s, i == 2 ? x.spanOf("corner") : Span.init, false);
            }
        }
        return Value.of(lines);
    }

    Value polygonShape(ref Args x, Span s)
    {
        // s.polygon(c, 6, r: 10.mm): a regular polygon, its corners on a construction circle round c
        // (r its radius, or d its diameter); fit: "sides" puts its sides on the circle instead,
        // touching it (d across the flats: a nut's spanner size); angle: the direction of the
        // first corner from c, else the turn is left free (it starts with the first side at the
        // bottom, horizontal, where a profile has it)
        import std.math : PI;
        immutable sides = polygonFit(x);
        immutable nv = x.num("n");
        if (nv != cast(long) nv || nv < 3 || nv > 1000)
            throw new HcadError(Code.type, "a polygon needs a whole number of sides, 3 or more", x.spanOf("n"));
        immutable n = cast(size_t) nv;
        double r = 10;
        immutable given = radiusGiven(x, "a polygon", r);
        immutable cons = construction(x);
        auto ctr = centreOf(x, s);
        immutable o = sk.guess(ctr);
        auto circ = made(s, () => sk.circle(ctr, r, true));
        if (given)
            radiusDimension(x, idOf(circ), r, s);
        immutable a0 = x.angleOr("angle", -PI / 2 - PI / n);
        // the corners start where they end up: on the circle, or out from it so that the
        // sides touch it
        immutable rc = sides ? r / cos(PI / n) : r;
        size_t[] ps;
        foreach (i; 0 .. n)
        {
            immutable t = a0 + 2 * PI * i / n;
            ps ~= newPoint(o.x + rc * cos(t), o.y + rc * sin(t), s);
        }
        Value[] lines;
        foreach (i; 0 .. n)
            lines ~= made(s, () => sk.line(ps[i], ps[(i + 1) % n], cons));
        if (asProfile)
            return Value.of(lines);   // nothing to solve: the constraints would only be counted
        // the corners on a circle (with fit: "sides", one of no given size, round the same
        // centre) and the sides equal make it regular; then one side touching the circle of
        // the given size sets it. (Every side touching it says the same, but the solver
        // cannot tell that from it: at the regular shape it would count a freedom too many.)
        auto through = sides ? made(s, () => sk.circle(ctr, rc, true)) : circ;
        calling = "on";
        foreach (p; ps)
            add(ConstraintKind.onCircle, [p, idOf(through)], s);
        if (sides)
        {
            calling = "tangent";
            add(ConstraintKind.tangentLine, [idOf(lines[0]), idOf(circ)], s);
        }
        calling = "equal";
        foreach (l; lines[1 .. $])
            add(ConstraintKind.equalLength, [idOf(l), idOf(lines[0])], s);
        if (x.has("angle"))
        {
            calling = "angle";
            add(ConstraintKind.direction, [ctr, ps[0]], s, a0, 0, x.spanOf("angle"));
        }
        return Value.of(lines);
    }

    Value polygonOfPoints(ref Args x, Span s)
    {
        // s.polygon([p1, p2, p3]): the closed polyline through them
        if (x.has("smooth"))
            throw new HcadError(Code.unknownArg, "a smooth outline is not sketch geometry: polygon(points, smooth: "
                ~ "true) is a profile of its own", x.spanOf("smooth"));
        return polyline(x, true, s);
    }

    Value polyline(ref Args x, bool closed, Span s)
    {
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
                ps ~= newPoint(q.x, q.y, s);
            }
        }
        immutable cons = construction(x);
        Value[] lines;
        foreach (i; 0 .. closed ? ps.length : ps.length - 1)
            lines ~= made(s, () => sk.line(ps[i], ps[(i + 1) % ps.length], cons));
        return Value.of(lines);
    }

    Value slotShape(ref Args x, Span s)
    {
        // s.slot(p, q, w: 6.mm): two half circles round p and q joined by two lines tangent to them;
        // s.slot(length, w): length end to end, along X (angle: turned) round center: or a new point
        // at the origin. Returns [line, arc round q, line, arc round p], counter-clockwise
        immutable cons = construction(x);
        if (x.has("p") || x.has("q"))
        {
            foreach (n; ["length", "center", "angle"])
                if (x.has(n))
                    throw new HcadError(Code.unknownArg, format("'%s' is for a slot by its length, slot(length, w:); "
                        ~ "between two centres give p, q and w:", n), x.spanOf(n));
            if (asProfile)
                positiveLen(x, "w");
            auto p = pointOrNew(x, "p", s), q = pointOrNew(x, "q", s);
            if (p == q)
                throw new HcadError(Code.type, "a slot needs two different points", x.spanOf("q"));
            immutable len = (sk.guess(q) - sk.guess(p)).length;
            if (len < 1e-9)
                throw new HcadError(Code.type, "the two ends of a slot must not start in the same place", x.spanOf("q"));
            return slotBetween(x, p, q, x.has("w") ? positiveLen(x, "w") : len / 3, cons, s);
        }
        // by its length
        if ((asProfile || x.has("length")) && !x.has("w"))
            throw new HcadError(Code.missingArg, "a slot by its length needs w: too", s);
        if (asProfile)
            positiveLen(x, "length");
        immutable w = x.has("w") ? positiveLen(x, "w") : 10;
        immutable l = x.has("length") ? positiveLen(x, "length") : 3 * w;
        if (l < w - 1e-9)
            throw new HcadError(Code.type, "a slot must be at least as long as it is wide", x.spanOf("length"));
        immutable t = x.angleOr("angle", 0), half = (l - w) / 2;
        auto ctr = centreOf(x, s);
        if (half < 1e-9)
        {
            // as long as wide: a circle
            auto c = made(s, () => sk.circle(ctr, w / 2, cons));
            calling = "diameter";
            add(ConstraintKind.radius, [idOf(c)], s, w / 2, 0, x.spanOf("w"), true);
            return c;
        }
        immutable o = sk.guess(ctr), u = Vec3(cos(t), sin(t), 0) * half;
        auto p = newPoint(o.x - u.x, o.y - u.y, s), q = newPoint(o.x + u.x, o.y + u.y, s);
        auto ends = slotBetween(x, p, q, w, cons, s);
        auto axis = made(s, () => sk.line(p, q, true));
        calling = "midpoint";
        add(ConstraintKind.midpoint, [ctr, idOf(axis)], s);
        if (x.has("angle"))
        {
            calling = "angle";
            add(ConstraintKind.direction, [p, q], s, t, 0, x.spanOf("angle"));
        }
        else
        {
            calling = "horizontal";
            add(ConstraintKind.horizontal, [idOf(axis)], s);
        }
        if (x.has("length"))
        {
            // between the centres: not shown as a dimension, which would read l - w
            calling = "length";
            add(ConstraintKind.length, [idOf(axis)], s, l - w);
        }
        return ends;
    }

    Value slotBetween(ref Args x, size_t p, size_t q, double w, bool cons, Span s)
    {
        immutable pp = sk.guess(p), qq = sk.guess(q);
        immutable u = (qq - pp) * (1 / (qq - pp).length), nrm = Vec3(-u.y, u.x, 0) * (w / 2);
        auto pr = newPoint(pp.x - nrm.x, pp.y - nrm.y, s), qr = newPoint(qq.x - nrm.x, qq.y - nrm.y, s);
        auto ql = newPoint(qq.x + nrm.x, qq.y + nrm.y, s), pl = newPoint(pp.x + nrm.x, pp.y + nrm.y, s);
        auto bottom = made(s, () => sk.line(pr, qr, cons));
        auto endQ = made(s, () => sk.arc(q, qr, ql, cons));
        auto top = made(s, () => sk.line(ql, pl, cons));
        auto endP = made(s, () => sk.arc(p, pl, pr, cons));
        calling = "tangent";
        add(ConstraintKind.tangentAt, [idOf(bottom), idOf(endP), pr], s);
        add(ConstraintKind.tangentAt, [idOf(bottom), idOf(endQ), qr], s);
        add(ConstraintKind.tangentAt, [idOf(top), idOf(endQ), ql], s);
        add(ConstraintKind.tangentAt, [idOf(top), idOf(endP), pl], s);
        calling = "equal";
        add(ConstraintKind.equalRadius, [idOf(endQ), idOf(endP)], s);
        if (x.has("w"))
        {
            calling = "diameter";
            add(ConstraintKind.radius, [idOf(endP)], s, w / 2, 0, x.spanOf("w"), true);
        }
        return Value.of([bottom, endQ, top, endP]);
    }

    Value teardropShape(ref Args x, Span s)
    {
        // s.teardrop(c, d: 5.mm, angle: 45.deg, flat: false): a round hole with a point towards +Y,
        // so that a hole through a wall prints without supports: an arc round c and two lines
        // tangent to it meeting above it, angle (3° to 90°) from the vertical; flat: true cuts the
        // point with a line touching the circle's top. Returns [arc, right line, left line] (and
        // the flat between them). At 90° the lines meet on the circle: the teardrop is the circle
        import std.math : PI, sin;
        double r = 10;
        immutable given = radiusGiven(x, "a teardrop", r);
        immutable ang = x.angleOr("angle", PI / 4), cons = construction(x);
        if (!(ang >= PI / 60 - 1e-9 && ang <= PI / 2 + 1e-9))
            throw new HcadError(Code.type, "the point's angle is from the vertical: between 3° and 90°", x.spanOf("angle"));
        auto ctr = centreOf(x, s);
        if (cos(ang) < 1e-6)
        {
            auto c = made(s, () => sk.circle(ctr, r, cons));
            if (given)
                radiusDimension(x, idOf(c), r, s);
            return c;
        }
        immutable o = sk.guess(ctr), ca = r * cos(ang), sa = r * sin(ang), tipY = r / sin(ang);
        auto left = newPoint(o.x - ca, o.y + sa, s), right = newPoint(o.x + ca, o.y + sa, s);
        auto tip = newPoint(o.x, o.y + tipY, s);
        auto arc = made(s, () => sk.arc(ctr, left, right, cons));
        if (given)
            radiusDimension(x, idOf(arc), r, s);
        immutable flat = x.flag("flat", false);
        // the sides, to the point (lines of the outline, or construction ones cut by the flat)
        auto up = made(s, () => sk.line(right, tip, cons || flat));
        auto down = made(s, () => sk.line(tip, left, cons || flat));
        Value[] result = [arc];
        if (!flat)
            result ~= [up, down];
        else
        {
            // the flat, at the circle's top, from one side to the other
            immutable f = (r - sa) / (tipY - sa);
            auto fr = newPoint(o.x + ca * (1 - f), o.y + r, s), fl = newPoint(o.x - ca * (1 - f), o.y + r, s);
            auto r1 = made(s, () => sk.line(right, fr, cons));
            auto top = made(s, () => sk.line(fr, fl, cons));
            auto l1 = made(s, () => sk.line(fl, left, cons));
            result ~= [r1, top, l1];
            if (!asProfile)
            {
                calling = "on";
                add(ConstraintKind.onLine, [fr, idOf(up)], s);
                add(ConstraintKind.onLine, [fl, idOf(down)], s);
                calling = "horizontal";
                add(ConstraintKind.horizontal, [idOf(top)], s);
                calling = "tangent";
                add(ConstraintKind.tangentLine, [idOf(top), idOf(arc)], s);
            }
        }
        if (asProfile)
            return Value.of(result);
        calling = "tangent";
        add(ConstraintKind.tangentAt, [idOf(up), idOf(arc), right], s);
        add(ConstraintKind.tangentAt, [idOf(down), idOf(arc), left], s);
        // the point straight above the centre, the sides at the angle from the vertical
        auto axis = made(s, () => sk.line(tip, ctr, true));
        calling = "vertical";
        add(ConstraintKind.vertical, [idOf(axis)], s);
        calling = "angle";
        add(ConstraintKind.angle, [idOf(axis), idOf(down)], s, ang, 0, x.has("angle") ? x.spanOf("angle") : Span.init);
        return Value.of(result);
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
        record(calling, refs, s, valueSpan, diameter);
        wrapErrors(s, () => sk.constrain(k, refs, v, constraintSpans.length - 1, v2));
    }

    /// A new tag: what a constraint call was, for errors and the GUI.
    void record(string kind, size_t[] refs, Span s, Span valueSpan, bool diameter)
    {
        constraintSpans ~= s;
        valueSpans ~= valueSpan;
        diameters ~= diameter;
        constraintKinds ~= kind;
        constraintRefs ~= refs.dup;
    }

    BuiltinImpl constraint(string name, string[] params, void delegate(ref Args, Span) f)
    {
        return (ref CallArgs a) {
            auto x = Args(it, a, name, ["sketch"] ~ params);
            calling = name;
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
            throw new HcadError(Code.type, format("expected a sketch point, line, arc, circle or ellipse, not %s", v.typeName), s);
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

    /// The lines of a shape (an array of SketchLines, as s.rect, s.polygon and s.polyline return),
    /// or null when `v` is not an array.
    size_t[] linesOf(Value v, Span s)
    {
        if (v.kind != Kind.array)
            return null;
        size_t[] ids;
        foreach (e; v.arr)
        {
            immutable id = entityOf(e, s);
            if (sk.entities[id].kind != EntityKind.line)
                throw new HcadError(Code.type, "a shape here is a list of lines (s.rect, s.polygon, s.polyline)", s);
            ids ~= id;
        }
        if (ids.length == 0)
            throw new HcadError(Code.type, "an empty list of lines", s);
        return ids;
    }

    /// A SketchPoint, or a vector: a new point starting there.
    size_t pointOrNew(ref Args x, string n, Span s)
    {
        auto v = x.get(n);
        if (v.kind == Kind.object_ && cast(SketchEntityVal) v.obj)
            return pointOf(v, x.spanOf(n));
        auto q = vecOf(x, v, x.spanOf(n));
        return newPoint(q.x, q.y, s);
    }

    size_t newPoint(double px, double py, Span s)
    {
        auto id = sk.point(px, py);
        entitySpans.length = sk.entities.length;
        entitySpans[id] = s;
        return id;
    }

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
        if (asProfile && p.v.v.z != 0)
            throw new HcadError(Code.type, "a profile lies on XY (z = 0): place it afterwards with move, rotate or "
                ~ "placeOn", s);
        return p.v.dim == Dim.none ? p.v.v * x.unitFactor : p.v.v;
    }

    string lines(size_t[] spansIdx, const(Span)[] table)
    {
        auto ls = spansIdx.map!(i => i < table.length ? table[i].line : 0).array.sort.uniq.map!(l => l.to!string).array;
        return ls.join(", ");
    }

    /// "free points at lines 7, 9; free sizes at line 12"
    string freeWhere(SolveReport rep)
    {
        import std.algorithm : canFind;
        string[] r;
        string at(string what, size_t[] ids)
        {
            auto ls = lines(ids, entitySpans);
            return format("free %s at line%s %s", what, ls.canFind(",") ? "s" : "", ls);
        }
        if (rep.freePoints.length)
            r ~= at("points", rep.freePoints);
        if (rep.freeShapes.length)
            r ~= at("sizes or turns", rep.freeShapes);
        return r.join("; ");
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
                format("the sketch is under-constrained: %d degree%s of freedom left (%s)", rep.dof, rep.dof > 1 ? "s" : "",
                    freeWhere(rep)),
                span, "add dimensions or constraints, or fix the points with fixed: true");
        }
        import hackerscad.kernel.brep : KernelException;

        // the same loop twice (two equal circles) cancels out: no hole, no error
        {
            import std.algorithm : sort;
            import std.array : join;
            bool[string] seen;
            string[] points;
            foreach (g; segs)
            {
                if (g.kind != OutlineSeg.Kind.end)
                {
                    foreach (c; [g.ax, g.ay, g.bx, g.by, g.mx, g.my])
                        points ~= format("%.6f", c + 0.0);
                    continue;
                }
                auto key = points.sort.release.join(" ");
                if (key in seen)
                    throw new HcadError(Code.sketch, "two outlines of the sketch lie on each other (two equal circles?): "
                        ~ "they would cancel out", span);
                seen[key] = true;
                points = null;
            }
        }

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
    /// A point, line, arc, circle or ellipse of the sketch, by its id (the order they were made in).
    struct Entity
    {
        string kind;        /// "point", "line", "arc", "circle" or "ellipse"
        Span span;          /// the call that made it
        bool construction;
    }

    struct Point
    {
        Vec3 pos;
        bool free;          /// can still move: drawn in blue (black when fixed)
        Span span;
        bool construction;
        size_t entity;      /// its id in entities
    }

    struct Segment
    {
        int kind;           /// 0 line a → b, 1 arc around c from a to b (counter-clockwise), 2 circle around c,
                            /// 3 ellipse around c (radius r along its x axis, `angle` from X, r2 across)
        Vec3 a, b, c;
        double r = 0, r2 = 0, angle = 0;
        bool construction;
        ptrdiff_t entity = -1;   /// the line, arc, circle or ellipse it draws (or part of it); -1 for a fillet's arc
        ptrdiff_t corner = -1;   /// a corner fillet's arc: the point it rounds
        Span span;               /// the call that made it (the s.fillet call for a fillet's arc)
    }

    struct Dimension
    {
        Vec3 at;            /// where to show the label
        string label;
        Span value;         /// the value argument in the source, to edit it
        bool conflicting;
        size_t constraint;  /// its entry in constraints
    }

    /// A constraint call (valueless ones too: tangent, parallel, on…; and fillets).
    struct Constraint
    {
        string kind;        /// the method called: "tangent", "distance", "fillet"…
        Span span;          /// the call
        size_t[] entities;  /// the entities it involves (a fillet: its point and the lines meeting there)
        ptrdiff_t dimension = -1;   /// its entry in dimensions, when it has a value shown
        bool conflicting;
    }

    /// What lines from..to of `file` make in the sketch: the entities and
    /// constraints written there, and the entities to highlight (theirs, and
    /// the ones those constraints involve).
    struct Found
    {
        size_t[] entities;      /// made on those lines
        size_t[] constraints;   /// written on those lines
        size_t[] highlight;     /// entities to highlight
        bool sketch;            /// the lines hold the sketch() call or a .profile of it
    }

    Span span;
    bool solved;
    size_t dof;
    Point[] points;
    Segment[] segments;
    Dimension[] dimensions;
    Entity[] entities;
    Constraint[] constraints;
    Span[] profiles;        /// where its .profile was read

    /// The entities and constraints on lines from..to of `file`.
    Found on(string file, uint from, uint to) const
    {
        import std.algorithm : canFind;
        Found f;
        bool inside(const Span s) => s.file == file && s.line >= from && s.line <= to;
        void light(size_t e)
        {
            if (!f.highlight.canFind(e))
                f.highlight ~= e;
        }
        f.sketch = inside(span) || profiles.canFind!(p => inside(p));
        foreach (i, e; entities)
            if (inside(e.span))
            {
                f.entities ~= i;
                light(i);
            }
        foreach (i, c; constraints)
            if (inside(c.span))
            {
                f.constraints ~= i;
                foreach (e; c.entities)
                    light(e);
            }
        return f;
    }

    /// Whether lines from..to of `file` belong to the sketch: its sketch()
    /// call, a .profile of it, or one of its entities or constraints.
    bool covers(string file, uint from, uint to) const
    {
        auto f = on(file, from, to);
        return f.sketch || f.entities.length || f.constraints.length;
    }
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
        case EntityKind.ellipse: return "SketchEllipse";
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
        case EntityKind.ellipse: return ["center", "rx", "ry", "angle"];
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
        case EntityKind.ellipse:
            {
                double rx, ry, t;
                if (name != "center")
                    sk.ellipseAxes(id, rx, ry, t);
                switch (name)
                {
                case "center": result = point(e.refs[0]); return true;
                case "rx": result = len(rx); return true;
                case "ry": result = len(ry); return true;
                case "angle": result = Value.number(t, Dim.angle); return true;
                default: return false;
                }
            }
        }
    }
}
