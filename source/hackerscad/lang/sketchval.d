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
import hackerscad.kernel.brep : Brep, EdgeInfo, EdgeKind;
import hackerscad.lang.builtins : Args, primitive, polygonFit;
import hackerscad.lang.errors;
import hackerscad.lang.interp;
import hackerscad.lang.value;
import hackerscad.sketch.sketch;

/// Registers `sketch()` in the prelude.
void installSketch(Interp it, void delegate(string, BuiltinImpl) def)
{
    def("sketch", (ref CallArgs a) {
        // sketch() on XY; body.sketch(faces.top) on a face of a solid, its edges as references;
        // sketch(frame) or sketch(plane) on a frame or plane (origin:, x: as frame takes them)
        import hackerscad.lang.builtins : faceXAxis, flatFace, frameArg, inPlane, planeArg, planeDef,
            resolveSelector;
        if (a.positional.length == 0 && a.named.length == 0)
            return Value.make(Kind.object_, new SketchVal(it, a.span));
        Args x;
        Vec3 o, n, ax, ay;
        SolidVal body;
        int face = -1;
        bool framed;
        if (a.positional.length && a.positional[0].kind == Kind.solid)
        {
            x = Args(it, a, "sketch", ["solid", "face", "origin", "x"]);
            body = x.solid("solid");
            if (body.flat || body.path)
                throw new HcadError(Code.type, "sketch(face) draws on a face of a solid, not of a profile or a path",
                    x.spanOf("solid"));
            auto idx = resolveSelector(it, x.selector("face", true), body, x.spanOf("face"));
            if (idx.length != 1)
                throw new HcadError(Code.type, format("sketch needs exactly one face, the selector matched %d",
                    idx.length), x.spanOf("face"));
            auto f = flatFace(it, body, idx[0], "sketch", x.spanOf("face"));
            face = idx[0];
            o = f.center;
            n = f.normal;
        }
        else
        {
            x = Args(it, a, "sketch", ["on", "origin", "x"]);
            auto v = x.get("on");
            if (v.kind == Kind.struct_ && v.st.def is planeDef)
                planeArg(x, "on", o, n);
            else
            {
                Vec3 az;
                frameArg(x, "on", o, ax, ay, az);
                n = az;
                framed = true;
            }
        }
        if (x.has("origin"))
        {
            // a chosen origin is projected onto the plane
            auto q = x.vecLen("origin");
            o = q - n * (q - o).dot(n);
        }
        if (x.has("x"))
        {
            ax = inPlane(x.dir("x"), n);
            if (ax.length < 1e-9)
                throw new HcadError(Code.type, "the x direction is perpendicular to the plane", x.spanOf("x"));
            ax = ax.normalized;
            ay = n.cross(ax);
        }
        else if (!framed)
        {
            ax = faceXAxis(n);
            ay = n.cross(ax);
        }
        auto sv = new SketchVal(it, a.span);
        sv.placeOn(o, ax, ay, n.normalized, body, face);
        return Value.make(Kind.object_, sv);
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
    bool placed;              /// drawn on a face or plane: its frame below (else on XY)
    Vec3[4] place;            /// origin, x, y, z
    SolidVal on;              /// the solid whose face it is drawn on (null on a frame or plane)
    size_t[] faceEdges;       /// the references of that face's edges
    size_t originRef = size_t.max;   /// the reference point at the origin
    private size_t[][size_t] edgeRefs;   /// edge of `on` → its references (more than one for a curve)
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
        "slot", "teardrop", "edges", "origin", "project", "coincident", "concentric", "fix", "horizontal", "vertical", "length", "distance", "on", "parallel",
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
        case "edges":
            {
                // the face's edges, as references (a curve that is neither a line nor a circle:
                // the lines that follow it)
                if (on is null)
                    throw new HcadError(Code.type, "edges are the references of a sketch drawn on a face: "
                        ~ "body.sketch(faces.top)", at);
                Value[] r;
                foreach (e; faceEdges)
                    r ~= entity(e);
                result = Value.of(r);
                return true;
            }
        case "origin":
            if (!placed)
                throw new HcadError(Code.type, "origin is the reference point of a sketch drawn on a face or plane: "
                    ~ "on XY, s.point(0, 0, fixed: true)", at);
            result = entity(originRef);
            return true;
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
        case "project":
            return (ref CallArgs a) {
                // s.project(edges.…): edges of the solid the sketch is on, flattened onto its plane
                // as references (a circle seen aslant: an ellipse)
                import hackerscad.lang.builtins : resolveSelector;
                auto x = Args(it, a, "project", ["sketch", "edges"]);
                if (on is null)
                    throw new HcadError(Code.type, "project takes edges of the solid a sketch is drawn on: "
                        ~ "body.sketch(faces.top)", a.span);
                auto idx = resolveSelector(it, x.selector("edges", false), on, x.spanOf("edges"));
                auto infos = it.kernel.edges(on.brep);
                Value[] r;
                foreach (i; idx)
                    foreach (e; reference(i, infos[i], x.spanOf("edges")))
                        r ~= entity(e);
                return Value.of(r);
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
        v.placed = placed;
        if (placed)
            v.place = place;
        if (on !is null)
            v.body = on.brep;
        auto rep = sk.report();
        v.solved = rep.solved;
        v.dof = rep.dof;
        bool[size_t] free;
        foreach (p; rep.freePoints)
            free[p] = true;
        Span spanOf(size_t e) => e < entitySpans.length && entitySpans[e] != Span.init ? entitySpans[e] : span;
        foreach (i, e; sk.entities)
            v.entities ~= SketchView.Entity(["point", "line", "arc", "circle", "ellipse"][e.kind], spanOf(i), e.construction,
                e.reference);
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
            seg.reference = e.reference;
            final switch (e.kind)
            {
            case EntityKind.point:
                v.points ~= SketchView.Point(sk.position(i), (i in free) !is null, spanOf(i), e.construction, i,
                    e.reference);
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
        // the labels where the sketch lies in the model
        foreach (ref d; v.dimensions)
            d.at = v.world(d.at);
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

    /// Draws the sketch on the frame (o, ax, ay, az); on face `face` of
    /// `body`, that face's edges become references, as does the origin.
    void placeOn(Vec3 o, Vec3 ax, Vec3 ay, Vec3 az, SolidVal body, int face)
    {
        placed = true;
        place = [o, ax, ay, az];
        on = body;
        originRef = refPoint(Vec3(0, 0, 0));
        if (body is null)
            return;
        auto infos = it.kernel.edges(body.brep);
        size_t[] mine;
        foreach (i, ends; it.kernel.edgeFaces(body.brep))
            if (ends[0] == face || ends[1] == face)
                mine ~= i;
        foreach (i; loopOrder(mine, infos))
            faceEdges ~= reference(i, infos[i], span);
    }

    /// The edges of a face in the order of its loops, as a rect gives its
    /// sides: each loop from its lowest edge (then leftmost), counter-clockwise
    /// in the sketch; the loop with the lowest edge first (the outside).
    size_t[] loopOrder(size_t[] edges, EdgeInfo[] infos)
    {
        import std.algorithm : canFind;
        size_t[] r;
        bool[size_t] used;
        immutable tol = 1e-6;
        while (r.length < edges.length)
        {
            // the lowest edge left, by its middle
            size_t first = size_t.max;
            foreach (i; edges)
                if (i !in used && (first == size_t.max || less(local(infos[i].mid), local(infos[first].mid))))
                    first = i;
            used[first] = true;
            size_t[] loop = [first];
            Vec3[] pts = [local(infos[first].start), local(infos[first].mid)];
            auto head = local(infos[first].start), at = local(infos[first].end);
            // on along the edges that meet at its end
            for (bool more = (head - at).length >= tol; more;)
            {
                more = false;
                foreach (i; edges)
                    if (i !in used)
                    {
                        auto a = local(infos[i].start), b = local(infos[i].end);
                        if ((a - at).length < tol || (b - at).length < tol)
                        {
                            immutable forward = (a - at).length < tol;
                            used[i] = true;
                            loop ~= i;
                            pts ~= [at, local(infos[i].mid)];
                            at = forward ? b : a;
                            more = (at - head).length >= tol;
                            break;
                        }
                    }
            }
            pts ~= at;
            // clockwise as found: the other way round, from the same edge
            double area = 0;
            foreach (k; 0 .. pts.length)
            {
                auto p = pts[k], q = pts[(k + 1) % pts.length];
                area += p.x * q.y - q.x * p.y;
            }
            if (area < 0 && loop.length > 2)
            {
                size_t[] back = [loop[0]];
                foreach_reverse (i; loop[1 .. $])
                    back ~= i;
                loop = back;
            }
            r ~= loop;
        }
        return r;
    }

    private static bool less(Vec3 a, Vec3 b) => a.y < b.y - 1e-6 || (a.y <= b.y + 1e-6 && a.x < b.x);

    /// A point of the plane in the sketch's coordinates.
    Vec3 local(Vec3 p) => Vec3((p - place[0]).dot(place[1]), (p - place[0]).dot(place[2]), 0);

    /// The reference point at `at` (in the sketch's coordinates): one per
    /// place, so that edges meeting at a corner share it.
    size_t refPoint(Vec3 at)
    {
        foreach (i, e; sk.entities)
            if (e.reference && e.kind == EntityKind.point && (sk.position(i) - at).length < 1e-7)
                return i;
        auto id = sk.point(at.x, at.y, true);
        sk.freeze(id);
        entitySpans.length = sk.entities.length;
        entitySpans[id] = span;
        return id;
    }

    /// The references of edge `index` of the solid the sketch is on,
    /// flattened onto its plane: a line, an arc, a circle or an ellipse (a
    /// circle seen aslant), lines along any other curve, a point for an edge
    /// seen end-on. Made once per edge.
    size_t[] reference(size_t index, EdgeInfo e, Span at)
    {
        import std.math : atan2, PI;
        if (auto had = index in edgeRefs)
            return *had;
        size_t[] r;
        size_t keep(size_t id)
        {
            sk.freeze(id);
            entitySpans.length = sk.entities.length;
            entitySpans[id] = span;
            r ~= id;
            return id;
        }
        immutable tol = 1e-7;
        auto a = local(e.start), b = local(e.end), m = local(e.mid);
        immutable n = place[3];
        if (e.kind == EdgeKind.line)
        {
            if ((a - b).length < tol)
                r ~= refPoint(a);
            else
                keep(sk.line(refPoint(a), refPoint(b), true));
        }
        else if (e.kind == EdgeKind.circle && abs(abs(e.axis.normalized.dot(n)) - 1) < 1e-9)
        {
            // in a plane parallel to the sketch: a circle, or an arc counter-clockwise as the sketch sees it
            auto c = local(e.center);
            immutable full = (a - b).length < tol && e.length > PI * e.radius;
            if (full)
                keep(sk.circle(refPoint(c), e.radius, true));
            else
            {
                double ang(Vec3 p) => atan2(p.y - c.y, p.x - c.x);
                double ccw(double from, double to)
                {
                    auto d = to - from;
                    while (d < 0)
                        d += 2 * PI;
                    while (d >= 2 * PI)
                        d -= 2 * PI;
                    return d;
                }
                immutable through = ccw(ang(a), ang(m)) < ccw(ang(a), ang(b));
                auto from = through ? a : b, to = through ? b : a;
                keep(sk.arc(refPoint(c), refPoint(from), refPoint(to), true));
            }
        }
        else if (e.kind == EdgeKind.circle && (a - b).length < tol && e.length > PI * e.radius)
        {
            // a whole circle seen aslant: an ellipse, its diameter along both planes kept
            auto axis = e.axis.normalized;
            auto along = axis.cross(n);
            immutable ry = e.radius * abs(axis.dot(n));
            auto c = local(e.center);
            immutable angle = atan2(along.dot(place[2]), along.dot(place[1]));
            if (ry < tol)
            {
                // edge-on: the diameter it shows
                auto d = Vec3(cos(angle), sin(angle), 0) * e.radius;
                keep(sk.line(refPoint(c - d), refPoint(c + d), true));
            }
            else
            {
                auto centre = refPoint(c);
                keep(sk.ellipse(centre, e.radius, ry, angle, true));
            }
        }
        else
        {
            // any other curve (or an arc seen aslant): lines through points along it
            Vec3[] pts = [a, m, b];
            foreach (k; 0 .. pts.length - 1)
                if ((pts[k] - pts[k + 1]).length >= tol)
                    keep(sk.line(refPoint(pts[k]), refPoint(pts[k + 1]), true));
            if (r.length == 0)
                r ~= refPoint(a);
        }
        edgeRefs[index] = r;
        return r;
    }

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
                // past the constraints: equations the sketch adds itself
                if (c < sk.constraints.length)
                    tags ~= sk.constraints[c].tag;
            import std.algorithm : canFind;
            immutable where = lines(tags, constraintSpans);
            if (where.length == 0)
                throw new HcadError(Code.sketch, "the sketch constraints conflict, and no single one is to blame: "
                    ~ "several contradict each other, or the points start too far from where they must go", span,
                    "draw the points nearer where they go, pin fewer of them (fixed: true), or leave out the "
                    ~ "constraints added last until it solves");
            throw new HcadError(Code.sketch, format("the sketch constraints conflict: check the constraints at line%s %s",
                where.canFind(",") ? "s" : "", where), constraintSpans[tags[0]], "remove or change one of them");
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
            string[] pieces;   // one per segment, whichever way the loop runs or starts
            foreach (g; segs)
            {
                if (g.kind != OutlineSeg.Kind.end)
                {
                    // each value kept with its own coordinate (sorting them all
                    // together would mix x and y: circles at (12, 0) and (0, 12)
                    // would look the same); the two ends in either order
                    string pt(double x, double y) => format("%.6f,%.6f", x + 0.0, y + 0.0);
                    auto ends = [pt(g.ax, g.ay), pt(g.bx, g.by)].sort.release;
                    pieces ~= format("%d %s %s %s", cast(int) g.kind, ends[0], ends[1], pt(g.mx, g.my));
                    continue;
                }
                auto key = pieces.sort.release.join(" ");
                if (key in seen)
                    throw new HcadError(Code.sketch, "two outlines of the sketch lie on each other (two equal circles?): "
                        ~ "they would cancel out", span);
                seen[key] = true;
                pieces = null;
            }
        }

        Brep b;
        try
            b = it.kernel.outline(segs);
        catch (KernelException e)
            throw new HcadError(Code.kernel, e.msg, span, "does the outline cross itself?");
        auto sv = primitive(it, b, "sketch", span);
        sv.flat = true;
        // drawn on a face or plane: the profile lies there
        sv.placed = placed;
        sv.place = place;
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
        bool reference;     /// a face's edge or the origin, on a sketch drawn on a face
    }

    struct Point
    {
        Vec3 pos;
        bool free;          /// can still move: drawn in blue (black when fixed)
        Span span;
        bool construction;
        size_t entity;      /// its id in entities
        bool reference;     /// a reference point (a corner of the face, the origin): fixed, drawn apart
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
        bool reference;          /// a face's edge, or another projected onto the sketch
    }

    struct Dimension
    {
        Vec3 at;            /// where to show the label, in the model's coordinates (on the sketch's plane)
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
    bool placed;            /// drawn on a face or plane: positions are in its frame (else on XY)
    Vec3[4] place = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];   /// origin, x, y, z
    Brep body;              /// a sketch on a face: the solid that face is of, as it was then (shown under it)
    Point[] points;
    Segment[] segments;
    Dimension[] dimensions;
    Entity[] entities;
    Constraint[] constraints;
    Span[] profiles;        /// where its .profile was read
    bool partial;           /// made by a run an error stopped: what came after the error is missing

    /// A point of the sketch (x, y in its plane) in the model's coordinates.
    Vec3 world(Vec3 p) const => placed ? place[0] + place[1] * p.x + place[2] * p.y : p;

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
        // a face's edges come with the sketch() call: they stay references, not
        // what its line makes (in orange only where a constraint uses them)
        foreach (i, e; entities)
            if (inside(e.span) && !e.reference)
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

/// The sketches a run made in `file`, as plain data. Kept by the
/// interpreter when the run stops at an error too (`failed`): they are then
/// marked partial, made only as far as the code ran.
SketchView[] sketchViews(Interp it, string file, bool failed)
{
    SketchView[] r;
    foreach (sk; it.sketches)
        if (auto sv = cast(SketchVal) sk)
            if (sv.span.file == file)
            {
                try
                {
                    auto v = sv.view();
                    v.partial = failed;
                    r ~= v;
                }
                catch (Exception)
                {
                    // a sketch that cannot be solved or drawn is left out
                }
            }
    return r;
}

/// Lines from..to of a file that a sketch owns: where the cursor shows it.
struct Stretch
{
    uint from, to;
    bool helper;   /// the body of another function the sketch was handed to, which drew on it
}

/// The lines of `file` holding the sketch's calls: its sketch() call, its
/// entities, its constraints and where its .profile was read (sorted, once each).
uint[] callLines(const ref SketchView v, string file)
{
    uint[] r;
    void add(const Span s)
    {
        if (s.file == file && s.line > 0)
            r ~= s.line;
    }
    add(v.span);
    foreach (e; v.entities)
        add(e.span);
    foreach (c; v.constraints)
        add(c.span);
    foreach (p; v.profiles)
        add(p);
    return r.sort.uniq.array;
}

/// The stretches of `file` a sketch owns. In the function its sketch() call
/// is in: from the first to the last line of its calls, with every line in
/// between (a foreach header, braces, a value computed on the way, comments,
/// a branch not taken). Another function that drew on it (a helper it was
/// handed to): that function's lines, from its declaration to its closing
/// brace. Another function that only read its .profile: those lines.
/// `functions` are the file's (Interp.functionsOf).
Stretch[] stretchesOf(const ref SketchView v, string file, const(FunctionInfo)[] functions)
{
    // the function a line is in, -1 outside them all
    ptrdiff_t functionOf(uint line)
    {
        foreach (i, f; functions)
            if (line >= f.first && line <= (f.end >= f.first ? f.end : f.last))
                return i;
        return -1;
    }
    struct Group
    {
        uint from = uint.max, to;
        bool draws;   /// entities or constraints made there, not only the sketch read
    }
    Group[ptrdiff_t] groups;
    void add(const Span s, bool draws)
    {
        if (s.file != file || s.line == 0)
            return;
        auto g = &groups.require(functionOf(s.line), Group.init);
        if (s.line < g.from)
            g.from = s.line;
        if (s.line > g.to)
            g.to = s.line;
        g.draws = g.draws || draws;
    }
    add(v.span, false);
    foreach (e; v.entities)
        add(e.span, true);
    foreach (c; v.constraints)
        add(c.span, true);
    foreach (p; v.profiles)
        add(p, false);
    immutable home = v.span.file == file ? functionOf(v.span.line) : ptrdiff_t.min;
    Stretch[] r;
    foreach (k, g; groups)
    {
        if (k != home && k >= 0 && g.draws)
        {
            auto f = functions[k];
            r ~= Stretch(f.first, f.end >= f.first ? f.end : g.to, true);
        }
        else
            r ~= Stretch(g.from, g.to, false);
    }
    r.sort!((a, b) => a.from < b.from);
    return r;
}

/// Which sketch line `line` of `file` belongs to.
struct SketchAt
{
    ptrdiff_t index = -1;   /// in the sketches given; -1 for none
    /// other sketches (other sketch() calls) that own the line just as much:
    /// a helper function they were all handed to
    size_t sharing;
}

/// The sketch among `views` (each with its stretches) that line `line` of
/// `file` belongs to: the one whose stretch holding it is narrowest, then
/// the one with a call nearest to it, then `prefer` (the one shown) if it
/// is still a candidate, then the last made.
SketchAt sketchAt(const(SketchView)[] views, const(Stretch[])[] stretches, string file, uint line,
    ptrdiff_t prefer = -1)
{
    import std.algorithm : canFind;
    enum none = uint.max;
    uint[] width = new uint[views.length], distance = new uint[views.length];
    foreach (i, v; views)
    {
        width[i] = none;
        if (i >= stretches.length)
            continue;
        foreach (st; stretches[i])
            if (line >= st.from && line <= st.to && st.to - st.from < width[i])
                width[i] = st.to - st.from;
        if (width[i] == none)
            continue;
        distance[i] = none;
        foreach (l; callLines(v, file))
        {
            immutable d = l > line ? l - line : line - l;
            if (d < distance[i])
                distance[i] = d;
        }
    }
    SketchAt r;
    foreach (i; 0 .. views.length)
    {
        if (width[i] == none)
            continue;
        if (r.index < 0)
        {
            r.index = i;
            continue;
        }
        immutable b = r.index;
        if (width[i] < width[b] || (width[i] == width[b] && distance[i] < distance[b]))
            r.index = i;
        else if (width[i] == width[b] && distance[i] == distance[b] && b != prefer)
            r.index = i;   // a tie: the last made, unless the one shown is the best so far
    }
    if (r.index < 0)
        return r;
    if (prefer >= 0 && prefer < views.length && width[prefer] == width[r.index] && distance[prefer] == distance[r.index])
        r.index = prefer;
    Span[] others;
    foreach (i; 0 .. views.length)
        if (width[i] == width[r.index] && distance[i] == distance[r.index] && views[i].span != views[r.index].span
            && !others.canFind(views[i].span))
            others ~= views[i].span;
    r.sharing = others.length;
    return r;
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
