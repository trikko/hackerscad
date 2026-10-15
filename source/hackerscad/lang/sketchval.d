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
    private bool warned;
    private string calling;   /// the constraint method running

    this(Interp it, Span span)
    {
        this.it = it;
        this.span = span;
        sk = new Sketch;
        constraintSpans ~= span;   // tag 0: implicit constraints
        valueSpans ~= Span.init;
        diameters ~= false;
        constraintKinds ~= "";
        constraintRefs ~= null;
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
        "slot", "coincident", "concentric", "fix", "horizontal", "vertical", "length", "distance", "on", "parallel",
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
        case "circle":
            return (ref CallArgs a) {
                // s.circle(c, r: 5.mm) has that radius; without r/d the radius is left to the constraints
                auto x = Args(it, a, "circle", ["sketch", "center", "r", "d", "construction"]);
                immutable given = x.has("r") || x.has("d");
                immutable r = given ? x.radius("r", "d") : 10;
                if (given && !(r > 0))
                    throw new HcadError(Code.type, "a circle's radius must be positive", x.spanOf(x.has("r") ? "r" : "d"));
                auto ctr = pointOrNew(x, "center", a.span);
                auto c = made(a.span, () => sk.circle(ctr, r, x.flag("construction", false)));
                calling = x.has("d") ? "diameter" : "radius";
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
        case "ellipse":
            return (ref CallArgs a) {
                // s.ellipse(c, rx: 20.mm, ry: 12.mm, angle: 30.deg): rx along its own x axis, angle from X;
                // what is not given is left to the constraints, as a circle's radius
                auto x = Args(it, a, "ellipse", ["sketch", "center", "rx", "ry", "angle", "construction"]);
                immutable rx = x.has("rx") ? positiveLen(x, "rx") : x.has("ry") ? 1.6 * positiveLen(x, "ry") : 10;
                immutable ry = x.has("ry") ? positiveLen(x, "ry") : 0.6 * rx;
                immutable angle = x.angleOr("angle", 0);
                auto ctr = pointOrNew(x, "center", a.span);
                auto e = made(a.span, () => sk.ellipse(ctr, rx, ry, angle, x.flag("construction", false)));
                calling = "radius";
                if (x.has("rx"))
                    add(ConstraintKind.radiusX, [idOf(e)], a.span, rx, 0, x.spanOf("rx"));
                if (x.has("ry"))
                    add(ConstraintKind.radiusY, [idOf(e)], a.span, ry, 0, x.spanOf("ry"));
                calling = "angle";
                if (x.has("angle"))
                    add(ConstraintKind.ellipseAngle, [idOf(e)], a.span, angle, 0, x.spanOf("angle"));
                return e;
            };
        case "rect":
            return (ref CallArgs a) {
                // s.rect(p, q): p and q opposite corners; s.rect(center: c, w: 40.mm, h: 20.mm). The lines go
                // p → (q.x, p.y) → q → (p.x, q.y) → p: bottom, right, top, left when p is the lower left corner
                auto x = Args(it, a, "rect", ["sketch", "p", "q", "center", "w", "h", "corner", "construction"]);
                immutable cons = x.flag("construction", false);
                size_t[4] c;
                size_t ctr = size_t.max;
                if (x.has("center"))
                {
                    if (x.has("p") || x.has("q"))
                        throw new HcadError(Code.unknownArg, "give either two corners or center:", x.spanOf("center"));
                    ctr = pointOrNew(x, "center", a.span);
                    immutable o = sk.guess(ctr);
                    immutable w = x.has("w") ? positiveLen(x, "w") : 20, h = x.has("h") ? positiveLen(x, "h") : 10;
                    foreach (i, d; [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(1, 1, 0), Vec3(-1, 1, 0)])
                        c[i] = newPoint(o.x + d.x * w / 2, o.y + d.y * h / 2, a.span);
                }
                else
                {
                    foreach (n; ["w", "h"])
                        if (x.has(n))
                            throw new HcadError(Code.unknownArg, format("'%s' goes with center:; two corners already "
                                ~ "give the size", n), x.spanOf(n));
                    c[0] = pointOrNew(x, "p", a.span);
                    c[2] = pointOrNew(x, "q", a.span);
                    immutable p = sk.guess(c[0]), q = sk.guess(c[2]);
                    if (abs(p.x - q.x) < 1e-9 || abs(p.y - q.y) < 1e-9)
                        throw new HcadError(Code.type, "the opposite corners of a rectangle must differ in x and in y",
                            x.spanOf("q"));
                    c[1] = newPoint(q.x, p.y, a.span);
                    c[3] = newPoint(p.x, q.y, a.span);
                }
                Value[] lines;
                foreach (i; 0 .. 4)
                    lines ~= made(a.span, () => sk.line(c[i], c[(i + 1) % 4], cons));
                calling = "horizontal";
                add(ConstraintKind.horizontal, [idOf(lines[0])], a.span);
                add(ConstraintKind.horizontal, [idOf(lines[2])], a.span);
                calling = "vertical";
                add(ConstraintKind.vertical, [idOf(lines[1])], a.span);
                add(ConstraintKind.vertical, [idOf(lines[3])], a.span);
                if (ctr != size_t.max)
                {
                    // the centre halves a diagonal
                    auto diag = made(a.span, () => sk.line(c[0], c[2], true));
                    calling = "midpoint";
                    add(ConstraintKind.midpoint, [ctr, idOf(diag)], a.span);
                    calling = "length";
                    if (x.has("w"))
                        add(ConstraintKind.length, [idOf(lines[0])], a.span, positiveLen(x, "w"), 0, x.spanOf("w"));
                    if (x.has("h"))
                        add(ConstraintKind.length, [idOf(lines[1])], a.span, positiveLen(x, "h"), 0, x.spanOf("h"));
                }
                if (x.has("corner"))
                {
                    // one dimension for the four, on the upper right corner (when p is the lower left one)
                    immutable r = positiveLen(x, "corner");
                    foreach (i, p; c)
                    {
                        wrapErrors(a.span, () => sk.fillet(p, r));
                        record("fillet", [p], a.span, i == 2 ? x.spanOf("corner") : Span.init, false);
                    }
                }
                return Value.of(lines);
            };
        case "polygon":
            return (ref CallArgs a) {
                // s.polygon(c, 6, r: 10.mm): a regular polygon, its corners on a construction circle round c
                // (r its radius, or d its diameter); fit: "sides" puts its sides on the circle instead,
                // touching it (d across the flats: a nut's spanner size); angle: the direction of the
                // first corner from c, else the turn is left free (it starts with the first side at the
                // bottom, horizontal)
                import std.math : PI;
                auto x = Args(it, a, "polygon", ["sketch", "center", "n", "r", "d", "fit", "angle", "construction"]);
                immutable sides = polygonFit(x);
                immutable nv = x.num("n");
                if (nv != cast(long) nv || nv < 3 || nv > 1000)
                    throw new HcadError(Code.type, "a polygon needs a whole number of sides, 3 or more", x.spanOf("n"));
                immutable n = cast(size_t) nv;
                immutable given = x.has("r") || x.has("d");
                immutable r = given ? x.radius("r", "d") : 10;
                if (given && !(r > 0))
                    throw new HcadError(Code.type, "a polygon's radius must be positive", x.spanOf(x.has("r") ? "r" : "d"));
                immutable cons = x.flag("construction", false);
                auto ctr = pointOrNew(x, "center", a.span);
                immutable o = sk.guess(ctr);
                auto circ = made(a.span, () => sk.circle(ctr, r, true));
                calling = x.has("d") ? "diameter" : "radius";
                if (given)
                    add(ConstraintKind.radius, [idOf(circ)], a.span, r, 0, x.spanOf(x.has("r") ? "r" : "d"), x.has("d"));
                immutable a0 = x.angleOr("angle", -PI / 2 - PI / n);
                // the corners start where they end up: on the circle, or out from it so that the
                // sides touch it
                immutable rc = sides ? r / cos(PI / n) : r;
                size_t[] ps;
                foreach (i; 0 .. n)
                {
                    immutable t = a0 + 2 * PI * i / n;
                    ps ~= newPoint(o.x + rc * cos(t), o.y + rc * sin(t), a.span);
                }
                Value[] lines;
                foreach (i; 0 .. n)
                    lines ~= made(a.span, () => sk.line(ps[i], ps[(i + 1) % n], cons));
                // the corners on a circle (with fit: "sides", one of no given size, round the same
                // centre) and the sides equal make it regular; then one side touching the circle of
                // the given size sets it. (Every side touching it says the same, but the solver
                // cannot tell that from it: at the regular shape it would count a freedom too many.)
                auto through = sides ? made(a.span, () => sk.circle(ctr, rc, true)) : circ;
                calling = "on";
                foreach (p; ps)
                    add(ConstraintKind.onCircle, [p, idOf(through)], a.span);
                if (sides)
                {
                    calling = "tangent";
                    add(ConstraintKind.tangentLine, [idOf(lines[0]), idOf(circ)], a.span);
                }
                calling = "equal";
                foreach (l; lines[1 .. $])
                    add(ConstraintKind.equalLength, [idOf(l), idOf(lines[0])], a.span);
                if (x.has("angle"))
                {
                    calling = "angle";
                    add(ConstraintKind.direction, [ctr, ps[0]], a.span, a0, 0, x.spanOf("angle"));
                }
                return Value.of(lines);
            };
        case "slot":
            return (ref CallArgs a) {
                // s.slot(p, q, w: 6.mm): two half circles round p and q joined by two lines tangent to them;
                // returns [line, arc round q, line, arc round p], counter-clockwise
                auto x = Args(it, a, "slot", ["sketch", "p", "q", "w", "construction"]);
                immutable cons = x.flag("construction", false);
                auto p = pointOrNew(x, "p", a.span), q = pointOrNew(x, "q", a.span);
                if (p == q)
                    throw new HcadError(Code.type, "a slot needs two different points", x.spanOf("q"));
                immutable pp = sk.guess(p), qq = sk.guess(q);
                immutable len = (qq - pp).length;
                if (len < 1e-9)
                    throw new HcadError(Code.type, "the two ends of a slot must not start in the same place", x.spanOf("q"));
                immutable w = x.has("w") ? positiveLen(x, "w") : len / 3;
                immutable u = (qq - pp) * (1 / len), nrm = Vec3(-u.y, u.x, 0) * (w / 2);
                auto pr = newPoint(pp.x - nrm.x, pp.y - nrm.y, a.span), qr = newPoint(qq.x - nrm.x, qq.y - nrm.y, a.span);
                auto ql = newPoint(qq.x + nrm.x, qq.y + nrm.y, a.span), pl = newPoint(pp.x + nrm.x, pp.y + nrm.y, a.span);
                auto bottom = made(a.span, () => sk.line(pr, qr, cons));
                auto endQ = made(a.span, () => sk.arc(q, qr, ql, cons));
                auto top = made(a.span, () => sk.line(ql, pl, cons));
                auto endP = made(a.span, () => sk.arc(p, pl, pr, cons));
                calling = "tangent";
                add(ConstraintKind.tangentAt, [idOf(bottom), idOf(endP), pr], a.span);
                add(ConstraintKind.tangentAt, [idOf(bottom), idOf(endQ), qr], a.span);
                add(ConstraintKind.tangentAt, [idOf(top), idOf(endQ), ql], a.span);
                add(ConstraintKind.tangentAt, [idOf(top), idOf(endP), pl], a.span);
                calling = "equal";
                add(ConstraintKind.equalRadius, [idOf(endQ), idOf(endP)], a.span);
                if (x.has("w"))
                {
                    calling = "diameter";
                    add(ConstraintKind.radius, [idOf(endP)], a.span, w / 2, 0, x.spanOf("w"), true);
                }
                return Value.of([bottom, endQ, top, endP]);
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
                immutable k = sk.entities[c].kind;
                add(k == EntityKind.line ? ConstraintKind.onLine : k == EntityKind.ellipse ? ConstraintKind.onEllipse
                    : ConstraintKind.onCircle, [p, c], s);
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
                seg.kind = 3;
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
