/// The prelude: units, math, ranges/algorithms in the style of Phobos, and
/// the geometry API (primitives, transforms, features, selectors).
module hackerscad.lang.builtins;

import std.conv : to, ConvException;
import std.format : format;
import std.math : PI, abs, sqrt, floor, ceil, round, sin, cos, tan, asin, acos, atan, atan2, isNaN;
import std.algorithm : canFind, map, sort, max, min;
import std.array : array, join;
import std.uni : toLower;
import std.algorithm : startsWith;

import hackerscad.lang.errors;
import hackerscad.lang.lexer : Tok;
import hackerscad.lang.ast : TypeRef;
import hackerscad.lang.value;
import hackerscad.lang.interp;
import hackerscad.kernel.brep;

immutable string[] stdModules = [
    "std.shapes", "std.math", "std.algorithm", "std.range", "std.conv", "std.format", "std.stdio", "std.array",
];

/// Built-in .hcad library sources.
/// Built-in libraries (lib/*.hcad), imported as `import gears;` or `import std.gears;`.
immutable string[string] librarySources;

shared static this()
{
    librarySources = [
        "hardware": import("hardware.hcad"),
        "threads": import("threads.hcad"),
        "gears": import("gears.hcad"),
        "hinges": import("hinges.hcad"),
        "snaps": import("snaps.hcad"),
        "enclosures": import("enclosures.hcad"),
    ];
}

void installPrelude(Interp it, Env env)
{
    foreach (name, src; librarySources)
    {
        it.embedded[name] = src;
        it.embedded["std." ~ name] = src;
    }

    void def(string name, BuiltinImpl impl)
    {
        auto b = new Builtin;
        b.name = name;
        b.impl = impl;
        env.vars[name] = Value.make(Kind.builtin, b);
        env.readonly[name] = true;
    }

    void constant(string name, Value v)
    {
        env.vars[name] = v;
        env.readonly[name] = true;
    }

    {
        import hackerscad.lang.sketchval : installSketch;
        installSketch(it, &def);
        import hackerscad.lang.drawingval : installDrawing;
        installDrawing(it, &def);
    }

    // ---- types as values (for to!T, T.init and error messages)
    foreach (t; ["int", "long", "double", "float", "real", "bool", "string", "Length", "Angle", "Area", "Volume",
        "Vec2", "Vec3", "Solid", "Profile", "Edge", "Face"])
    {
        auto tv = new TypeVal;
        tv.name = t;
        constant(t, Value.make(Kind.type, tv));
    }

    // ---- units
    void unit(string name, double factor, Dim dim)
    {
        auto b = new Builtin;
        b.name = name;
        b.unitFactor = factor;
        b.unitDim = dim;
        b.impl = (ref CallArgs a) {
            auto x = Args(it, a, name, ["value"]);
            auto v = x.get("value");
            if (!v.isNum || v.n.dim != Dim.none)
                throw new HcadError(Code.units, format("'%s' applies to a plain number, not to %s", name, v.typeName), x.spanOf("value"));
            return Value.number(v.n.value * factor, dim);
        };
        env.vars[name] = Value.make(Kind.builtin, b);
        env.readonly[name] = true;
    }

    unit("mm", 1, Dim.length);
    unit("cm", 10, Dim.length);
    unit("m", 1000, Dim.length);
    unit("inch", 25.4, Dim.length);
    unit("deg", PI / 180, Dim.angle);
    unit("rad", 1, Dim.angle);

    // ---- constants
    constant("PI", Value.number(PI));
    constant("X", Value.vector(Vec3(1, 0, 0), 3, Dim.none));
    constant("Y", Value.vector(Vec3(0, 1, 0), 3, Dim.none));
    constant("Z", Value.vector(Vec3(0, 0, 1), 3, Dim.none));
    constant("nothing", Value.of(new SolidVal(null, Span.init)));
    constant("XY", planeValue(Vec3(0, 0, 0), Vec3(0, 0, 1)));
    constant("XZ", planeValue(Vec3(0, 0, 0), Vec3(0, 1, 0)));
    constant("YZ", planeValue(Vec3(0, 0, 0), Vec3(1, 0, 0)));
    constant("World", frameValue(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)));
    constant("edges", Value.make(Kind.selector, new SelectorVal));
    {
        auto f = new SelectorVal;
        f.faces = true;
        constant("faces", Value.make(Kind.selector, f));
    }

    // ---- output and strings
    def("writeln", (ref CallArgs a) { it.print(a.positional.map!(v => v.toString).join, a.span); return Value.void_; });
    def("write", (ref CallArgs a) { it.print(a.positional.map!(v => v.toString).join, a.span); return Value.void_; });
    def("format", (ref CallArgs a) => Value.of(formatValues(a)));
    def("to", (ref CallArgs a) => convert(it, a));

    // ---- math
    def("sqrt", (ref CallArgs a) {
        auto v = num(a, "sqrt");
        if (v.n.dim.len % 2 || v.n.dim.ang % 2)
            throw new HcadError(Code.units, format("sqrt of a %s has no unit", v.n.dim.name), a.span);
        return Value.number(sqrt(v.n.value), Dim(cast(byte)(v.n.dim.len / 2), cast(byte)(v.n.dim.ang / 2)));
    });
    def("abs", (ref CallArgs a) { auto v = num(a, "abs"); return Value.number(abs(v.n.value), v.n.dim, v.n.isInt); });
    def("floor", (ref CallArgs a) { auto v = num(a, "floor"); return Value.number(floor(v.n.value), v.n.dim, v.n.dim == Dim.none); });
    def("ceil", (ref CallArgs a) { auto v = num(a, "ceil"); return Value.number(ceil(v.n.value), v.n.dim, v.n.dim == Dim.none); });
    def("round", (ref CallArgs a) { auto v = num(a, "round"); return Value.number(round(v.n.value), v.n.dim, v.n.dim == Dim.none); });
    def("sin", (ref CallArgs a) => Value.number(sin(angleArg(a, "sin"))));
    def("cos", (ref CallArgs a) => Value.number(cos(angleArg(a, "cos"))));
    def("tan", (ref CallArgs a) => Value.number(tan(angleArg(a, "tan"))));
    def("asin", (ref CallArgs a) => Value.number(asin(plain(a, "asin")), Dim.angle));
    def("acos", (ref CallArgs a) => Value.number(acos(plain(a, "acos")), Dim.angle));
    def("atan", (ref CallArgs a) => Value.number(atan(plain(a, "atan")), Dim.angle));
    def("atan2", (ref CallArgs a) {
        auto x = Args(it, a, "atan2", ["y", "x"]);
        auto y = x.get("y"), xx = x.get("x");
        if (!y.isNum || !xx.isNum || y.n.dim != xx.n.dim)
            throw new HcadError(Code.units, "atan2 needs two numbers with the same unit", a.span);
        return Value.number(atan2(y.n.value, xx.n.value), Dim.angle);
    });
    def("min", (ref CallArgs a) => extreme(it, a, "min", false));
    def("max", (ref CallArgs a) => extreme(it, a, "max", true));
    def("minElement", (ref CallArgs a) => extreme(it, a, "minElement", false));
    def("maxElement", (ref CallArgs a) => extreme(it, a, "maxElement", true));
    def("clamp", (ref CallArgs a) {
        auto x = Args(it, a, "clamp", ["value", "lo", "hi"]);
        auto v = x.get("value"), lo = x.get("lo"), hi = x.get("hi");
        if (it.applyBinary(Tok.lt, v, lo, a.span).truthy) return lo;
        if (it.applyBinary(Tok.gt, v, hi, a.span).truthy) return hi;
        return v;
    });

    // ---- vectors
    def("vec", (ref CallArgs a) => arrayToVec(it, a.positional, a.caller, a.span));
    def("dot", (ref CallArgs a) {
        auto x = Args(it, a, "dot", ["a", "b"]);
        auto p = x.vecAny("a"), q = x.vecAny("b");
        return Value.number(p.v.dot(q.v), p.dim + q.dim);
    });
    def("cross", (ref CallArgs a) {
        auto x = Args(it, a, "cross", ["a", "b"]);
        auto p = x.vecAny("a"), q = x.vecAny("b");
        return Value.vector(p.v.cross(q.v), 3, p.dim + q.dim);
    });
    def("distance", (ref CallArgs a) {
        auto x = Args(it, a, "distance", ["a", "b"]);
        if (x.get("a").kind == Kind.solid && x.get("b").kind == Kind.solid)
        {
            // minimum distance between two solids (0 when they touch or overlap)
            Vec3 pa, pb;
            return Value.number(it.kernel.distance(nonEmpty(x.solid("a"), a.span), nonEmpty(x.solid("b"), a.span), pa, pb), Dim.length);
        }
        auto p = x.vecAny("a"), q = x.vecAny("b");
        if (p.dim != q.dim)
            throw new HcadError(Code.units, "distance between vectors with different units", a.span);
        return Value.number((p.v - q.v).length, p.dim);
    });

    // ---- ranges and algorithms (eager arrays, Phobos names)
    def("iota", (ref CallArgs a) {
        auto x = Args(it, a, "iota", ["a", "b", "step"]);
        Value lo = Value.integer(0), hi;
        if (x.has("b"))
        {
            lo = x.get("a");
            hi = x.get("b");
        }
        else
            hi = x.get("a");
        auto step = x.has("step") ? x.get("step") : Value.number(1, lo.isNum ? lo.n.dim : Dim.none, true);
        if (!lo.isNum || !hi.isNum || !step.isNum || lo.n.dim != hi.n.dim || step.n.dim != lo.n.dim)
            throw new HcadError(Code.units, "iota needs numbers with the same unit", a.span);
        if (step.n.value == 0)
            throw new HcadError(Code.type, "iota step cannot be zero", a.span);
        immutable isInt = lo.n.isInt && hi.n.isInt && step.n.isInt;
        Value[] r;
        for (double v = lo.n.value; step.n.value > 0 ? v < hi.n.value - 1e-12 : v > hi.n.value + 1e-12; v += step.n.value)
        {
            if (r.length >= it.limits.arrayLength)
                throw new HcadError(Code.limit, "array too large", a.span);
            r ~= Value.number(v, lo.n.dim, isInt);
        }
        return Value.of(r);
    });
    // functions are ordinary arguments: xs.map(x => x * 2), xs.filter(f)
    def("map", (ref CallArgs a) {
        auto xs = arrayArg(a, 0, "map");
        auto f = fnArg(a, 1, "map", "x => …");
        Value[] r;
        r.reserve(xs.length);
        foreach (v; xs)
            r ~= call1(it, f, v, a.span);
        return Value.of(r);
    });
    def("filter", (ref CallArgs a) {
        auto xs = arrayArg(a, 0, "filter");
        auto f = fnArg(a, 1, "filter", "x => condition");
        Value[] r;
        foreach (v; xs)
            if (call1(it, f, v, a.span).truthy)
                r ~= v;
        return Value.of(r);
    });
    def("fold", (ref CallArgs a) {
        // xs.fold((acc, x) => …) or xs.fold((acc, x) => …, seed)
        auto xs = arrayArg(a, 0, "fold");
        auto f = fnArg(a, 1, "fold", "(acc, x) => …");
        Value acc;
        size_t start = 0;
        if (a.positional.length > 2)
            acc = a.positional[2];
        else
        {
            if (xs.length == 0)
                throw new HcadError(Code.type, "fold of an empty array needs a seed: xs.fold(f, seed)", a.span);
            acc = xs[0];
            start = 1;
        }
        foreach (v; xs[start .. $])
            acc = call2(it, f, acc, v, a.span);
        return acc;
    });
    def("sum", (ref CallArgs a) {
        noTemplate(a, "sum");
        auto xs = arrayArg(a, 0, "sum");
        if (a.positional.length > 1)
        {
            Value acc = a.positional[1];
            foreach (v; xs)
                acc = it.applyBinary(Tok.plus, acc, v, a.span);
            return acc;
        }
        if (xs.length == 0)
            return Value.integer(0);
        if (xs[0].kind == Kind.solid)
            return unionAll(it, xs, a.span);
        Value acc = xs[0];
        foreach (v; xs[1 .. $])
            acc = it.applyBinary(Tok.plus, acc, v, a.span);
        return acc;
    });
    def("fuse", (ref CallArgs a) {
        noTemplate(a, "fuse");
        Value[] xs = a.positional.length == 1 && a.positional[0].kind == Kind.array ? a.positional[0].arr : a.positional;
        return unionAll(it, xs, a.span);
    });
    def("any", (ref CallArgs a) {
        auto xs = arrayArg(a, 0, "any");
        auto f = fnArg(a, 1, "any", "x => condition");
        foreach (v; xs)
            if (call1(it, f, v, a.span).truthy)
                return Value.of(true);
        return Value.of(false);
    });
    def("all", (ref CallArgs a) {
        auto xs = arrayArg(a, 0, "all");
        auto f = fnArg(a, 1, "all", "x => condition");
        foreach (v; xs)
            if (!call1(it, f, v, a.span).truthy)
                return Value.of(false);
        return Value.of(true);
    });
    def("count", (ref CallArgs a) {
        noTemplate(a, "count");
        auto xs = arrayArg(a, 0, "count");
        if (a.positional.length < 2)
            return Value.integer(xs.length);
        auto f = fnArg(a, 1, "count", "x => condition");
        long n;
        foreach (v; xs)
            if (call1(it, f, v, a.span).truthy)
                n++;
        return Value.integer(n);
    });
    def("canFind", (ref CallArgs a) {
        // xs.canFind(value) or xs.canFind(x => condition)
        noTemplate(a, "canFind");
        auto xs = arrayArg(a, 0, "canFind");
        if (a.positional.length != 2)
            throw new HcadError(Code.arity, "use xs.canFind(value) or xs.canFind(x => condition)", a.span);
        auto needle = a.positional[1];
        foreach (v; xs)
            if (needle.isCallable ? call1(it, needle, v, a.span).truthy : it.applyBinary(Tok.eq, v, needle, a.span).truthy)
                return Value.of(true);
        return Value.of(false);
    });
    def("sort", (ref CallArgs a) {
        // xs.sort or xs.sort((a, b) => a > b)
        noTemplate(a, "sort");
        auto xs = arrayArg(a, 0, "sort").dup;
        Value less = a.positional.length > 1 ? fnArg(a, 1, "sort", "(a, b) => a < b") : Value.void_;
        // a comparison that is not a strict order (a <= b, or one that
        // changes its mind) makes the sort's own check fail: say why
        import core.exception : AssertError;
        try
            sort!((x, y) => less.kind == Kind.void_ ? it.applyBinary(Tok.lt, x, y, a.span).truthy
                : call2(it, less, x, y, a.span).truthy)(xs);
        catch (AssertError)
            throw new HcadError(Code.type, "the comparison given to sort is not consistent: it must say whether "
                ~ "a comes strictly before b, like (a, b) => a < b (not <=)", a.span);
        return Value.of(xs);
    });
    def("reverse", (ref CallArgs a) {
        import std.range : retro;
        return Value.of(arrayArg(a, 0, "reverse").retro.array);
    });
    def("retro", (ref CallArgs a) {
        import std.range : retro;
        return Value.of(arrayArg(a, 0, "retro").retro.array);
    });
    def("array", (ref CallArgs a) => Value.of(arrayArg(a, 0, "array")));
    def("enumerate", (ref CallArgs a) {
        Value[] r;
        foreach (i, v; arrayArg(a, 0, "enumerate"))
            r ~= Value.of([Value.integer(i), v]);
        return Value.of(r);
    });
    def("zip", (ref CallArgs a) {
        Value[][] lists;
        foreach (i; 0 .. a.positional.length)
            lists ~= arrayArg(a, i, "zip");
        Value[] r;
        if (lists.length)
            foreach (k; 0 .. lists.map!(l => l.length).fold!min)
                r ~= Value.of(lists.map!(l => l[k]).array);
        return Value.of(r);
    });
    def("cartesianProduct", (ref CallArgs a) {
        Value[][] acc = [[]];
        foreach (i; 0 .. a.positional.length)
        {
            Value[][] next;
            foreach (prefix; acc)
                foreach (v; arrayArg(a, i, "cartesianProduct"))
                    next ~= prefix ~ v;
            acc = next;
        }
        return Value.of(acc.map!(t => Value.of(t)).array);
    });
    def("join", (ref CallArgs a) {
        auto xs = arrayArg(a, 0, "join");
        auto sep = a.positional.length > 1 ? a.positional[1].toString : "";
        return Value.of(xs.map!(v => v.toString).join(sep));
    });
    def("rgb", (ref CallArgs a) {
        // rgb(r, g, b) with 0…255 channels, rgb(r, g, b, alpha: 0.5) for a transparent colour
        auto x = Args(it, a, "rgb", ["r", "g", "b", "alpha"]);
        uint c = !x.has("g") ? cast(uint) x.num("r")
            : (cast(uint) x.num("r") << 16) | (cast(uint) x.num("g") << 8) | cast(uint) x.num("b");
        if (x.has("alpha"))
            c = withAlpha(c, x.num("alpha"));
        return Value.integer(c);
    });

    installGeometry(it, env, &def);
}

// ================================================================ geometry

private void installGeometry(Interp it, Env env, void delegate(string, BuiltinImpl) def)
{
    auto k() => it.kernel;

    Value solid(Brep b, string kind, Span span) => Value.of(primitive(it, b, kind, span));

    // Primitives stand on the XY plane, centred in X and Y; center: true
    // centres them in Z too. Spheres are centred.
    def("box", (ref CallArgs a) {
        auto x = Args(it, a, "box", ["x", "y", "z", "center"]);
        double dx, dy, dz;
        if (!x.has("y") && x.has("x") && (x.get("x").kind == Kind.vec || x.get("x").kind == Kind.array))
        {
            auto v = x.vecLen("x");
            dx = v.x, dy = v.y, dz = v.z;
        }
        else
            dx = x.len("x"), dy = x.len("y"), dz = x.len("z");
        positive(a, [dx, dy, dz], "box sizes");
        auto b = k.translate(k.box(dx, dy, dz), Vec3(-dx / 2, -dy / 2, x.flag("center", false) ? -dz / 2 : 0));
        return solid(b, "box", a.span);
    });
    def("cylinder", (ref CallArgs a) {
        auto x = Args(it, a, "cylinder", ["r", "h", "d", "center"]);
        auto r = x.radius("r", "d"), h = x.len("h");
        positive(a, [r, h], "cylinder sizes");
        return solid(k.translate(k.cylinder(r, h), Vec3(0, 0, x.flag("center", false) ? -h / 2 : 0)), "cylinder", a.span);
    });
    def("cone", (ref CallArgs a) {
        auto x = Args(it, a, "cone", ["r1", "r2", "h", "d1", "d2", "center"]);
        auto r1 = x.radius("r1", "d1"), r2 = x.radius("r2", "d2"), h = x.len("h");
        positive(a, [h], "cone height");
        return solid(k.translate(k.cone(r1, r2, h), Vec3(0, 0, x.flag("center", false) ? -h / 2 : 0)), "cone", a.span);
    });
    def("sphere", (ref CallArgs a) {
        auto x = Args(it, a, "sphere", ["r", "d"]);
        auto r = x.radius("r", "d");
        positive(a, [r], "sphere radius");
        return solid(k.sphere(r), "sphere", a.span);
    });

    def("move", (ref CallArgs a) {
        auto x = Args(it, a, "move", ["solid", "v", "x", "y", "z"]);
        auto s = x.solid("solid");
        Vec3 v = x.has("v") ? x.vecLen("v") : Vec3(0, 0, 0);
        v = v + Vec3(x.lenOr("x", 0), x.lenOr("y", 0), x.lenOr("z", 0));
        return transformed(it, a.span, s, b => k.translate(b, v));
    });
    def("rotate", (ref CallArgs a) {
        // rotate(x:, y:, z:) Euler angles, or rotate(angle, axis:) around a
        // direction (through the origin) or an Axis (through its own origin)
        auto x = Args(it, a, "rotate", ["solid", "angle", "axis", "x", "y", "z"]);
        auto s = x.solid("solid");
        if (x.has("angle"))
        {
            Vec3 o, d = Vec3(0, 0, 1);
            if (x.has("axis"))
                axisArg(x, "axis", o, d);
            immutable ang = x.angle("angle");
            return transformed(it, a.span, s, b => k.translate(k.rotate(k.translate(b, -o), d, ang), o));
        }
        // Euler angles applied around X, then Y, then Z
        immutable rx = x.angleOr("x", 0), ry = x.angleOr("y", 0), rz = x.angleOr("z", 0);
        return transformed(it, a.span, s, (Brep b) {
            if (rx != 0) b = k.rotate(b, Vec3(1, 0, 0), rx);
            if (ry != 0) b = k.rotate(b, Vec3(0, 1, 0), ry);
            if (rz != 0) b = k.rotate(b, Vec3(0, 0, 1), rz);
            return b;
        });
    });
    def("scale", (ref CallArgs a) {
        auto x = Args(it, a, "scale", ["solid", "factor"]);
        auto s = x.solid("solid");
        immutable f = x.num("factor");
        if (f <= 0)
            throw new HcadError(Code.type, "scale factor must be positive", x.spanOf("factor"));
        return transformed(it, a.span, s, b => k.scale(b, f));
    });
    def("mirror", (ref CallArgs a) {
        // mirror(X) across the plane through the origin with that normal, or
        // mirror(plane) across any Plane
        auto x = Args(it, a, "mirror", ["solid", "plane"]);
        auto s = x.solid("solid");
        Vec3 o, n;
        auto v = x.get("plane");
        if (v.kind == Kind.struct_ && v.st.def is planeDef)
            planeArg(x, "plane", o, n);
        else
            n = x.dir("plane");
        return transformed(it, a.span, s, b => k.translate(k.mirror(k.translate(b, -o), n), o));
    });
    def("color", (ref CallArgs a) {
        auto x = Args(it, a, "color", ["solid", "color", "alpha"]);
        auto s = x.solid("solid");
        auto r = new SolidVal(s.brep, s.origin);
        r.creators = s.creators;
        r.flat = s.flat;
        r.path = s.path;
        r.rgb = colorOf(x.get("color"), x.spanOf("color"));
        if (x.has("alpha"))
            r.rgb = withAlpha(r.rgb, x.num("alpha"));
        r.hasColor = true;
        return Value.of(r);
    });

    def("fillet", (ref CallArgs a) {
        auto x = Args(it, a, "fillet", ["solid", "edges", "r"]);
        auto s = x.solid("solid");
        auto sel = x.selector("edges", false);
        immutable r = x.len("r");
        auto idx = resolveSelector(it, sel, s, x.spanOf("edges"));
        return edgeFeature(it, a, s, idx, "fillet", "r", b => k.fillet(b, idx, r));
    });
    def("chamfer", (ref CallArgs a) {
        auto x = Args(it, a, "chamfer", ["solid", "edges", "d"]);
        auto s = x.solid("solid");
        auto sel = x.selector("edges", false);
        immutable d = x.len("d");
        auto idx = resolveSelector(it, sel, s, x.spanOf("edges"));
        return edgeFeature(it, a, s, idx, "chamfer", "d", b => k.chamfer(b, idx, d));
    });
    def("shell", (ref CallArgs a) {
        auto x = Args(it, a, "shell", ["solid", "open", "thickness"]);
        auto s = x.solid("solid");
        auto sel = x.selector("open", true);
        immutable t = x.len("thickness");
        auto idx = resolveSelector(it, sel, s, x.spanOf("open"));
        return transformed(it, a.span, s, b => k.shell(b, idx, t), "shell");
    });

    // placement relative to another solid
    def("nextTo", (ref CallArgs a) {
        auto x = Args(it, a, "nextTo", ["solid", "other", "dir", "gap"]);
        auto s = x.solid("solid"), o = x.solid("other");
        auto d = x.has("dir") ? x.dir("dir") : Vec3(1, 0, 0);
        immutable gap = x.lenOr("gap", 0);
        auto bs = k.bbox(nonEmpty(s, a.span)), bo = k.bbox(nonEmpty(o, a.span));
        Vec3 shift;
        foreach (axis; 0 .. 3)
        {
            immutable c = comp(d, axis);
            if (abs(c) < 0.5)
                continue;
            immutable delta = c > 0 ? comp(bo.max, axis) + gap - comp(bs.min, axis) : comp(bo.min, axis) - gap - comp(bs.max, axis);
            shift = shift + axisVec(axis) * delta;
        }
        return transformed(it, a.span, s, b => k.translate(b, shift));
    });
    def("on", (ref CallArgs a) {
        auto x = Args(it, a, "on", ["solid", "other", "gap"]);
        auto s = x.solid("solid"), o = x.solid("other");
        auto bs = k.bbox(nonEmpty(s, a.span)), bo = k.bbox(nonEmpty(o, a.span));
        auto shift = Vec3(bo.center.x - bs.center.x, bo.center.y - bs.center.y, bo.max.z + x.lenOr("gap", 0) - bs.min.z);
        return transformed(it, a.span, s, b => k.translate(b, shift));
    });
    def("align", (ref CallArgs a) {
        // a.align(b, x: "center", z: "min"): match bounding box positions per axis
        auto x = Args(it, a, "align", ["solid", "other", "x", "y", "z"]);
        auto s = x.solid("solid"), o = x.solid("other");
        auto bs = k.bbox(nonEmpty(s, a.span)), bo = k.bbox(nonEmpty(o, a.span));
        Vec3 shift;
        foreach (axis, n; ["x", "y", "z"])
        {
            if (!x.has(n))
                continue;
            auto how = x.get(n);
            if (how.kind != Kind.str)
                throw new HcadError(Code.type, format("'%s' must be \"min\", \"center\" or \"max\"", n), x.spanOf(n));
            double from, to;
            switch (how.s)
            {
            case "min": from = comp(bs.min, axis); to = comp(bo.min, axis); break;
            case "max": from = comp(bs.max, axis); to = comp(bo.max, axis); break;
            case "center": from = comp(bs.center, axis); to = comp(bo.center, axis); break;
            default:
                throw new HcadError(Code.type, format("'%s' must be \"min\", \"center\" or \"max\"", n), x.spanOf(n),
                    Interp.suggest(how.s, ["min", "center", "max"]));
            }
            shift = shift + axisVec(axis) * (to - from);
        }
        return transformed(it, a.span, s, b => k.translate(b, shift));
    });

    // patterns: copies united into one solid (subtract it to cut many holes)
    def("linearPattern", (ref CallArgs a) {
        auto x = Args(it, a, "linearPattern", ["solid", "n", "step"]);
        auto s = x.solid("solid");
        immutable n = count(x, "n");
        auto step = x.vecLen("step");
        Value[] copies;
        foreach (i; 0 .. n)
            copies ~= transformed(it, a.span, s, b => k.translate(b, step * i));
        return unionAll(it, copies, a.span);
    });
    def("circularPattern", (ref CallArgs a) {
        auto x = Args(it, a, "circularPattern", ["solid", "n", "axis", "angle"]);
        auto s = x.solid("solid");
        immutable n = count(x, "n");
        Vec3 o, axis = Vec3(0, 0, 1);
        if (x.has("axis"))
            axisArg(x, "axis", o, axis);
        immutable total = x.angleOr("angle", 2 * PI);
        // a full turn spaces n copies evenly; a partial arc includes both ends
        immutable step = abs(total - 2 * PI) < 1e-9 ? total / n : n > 1 ? total / (n - 1) : 0;
        Value[] copies;
        foreach (i; 0 .. n)
            copies ~= transformed(it, a.span, s, b => k.translate(k.rotate(k.translate(b, -o), axis, step * i), o));
        return unionAll(it, copies, a.span);
    });

    def("draft", (ref CallArgs a) {
        // s.draft(faces.filter(f => f.isPerpendicular(Z) == false), angle: 2.deg, pull: Z, neutral: 0.mm)
        auto x = Args(it, a, "draft", ["solid", "faces", "angle", "pull", "neutral"]);
        auto s = x.solid("solid");
        auto sel = x.selector("faces", true);
        immutable ang = x.angle("angle");
        auto pull = x.has("pull") ? x.dir("pull") : Vec3(0, 0, 1);
        auto point = pull * x.lenOr("neutral", 0);
        auto idx = resolveSelector(it, sel, s, x.spanOf("faces"));
        return transformed(it, a.span, s, b => k.draft(b, idx, ang, pull, point), "draft");
    });

    // ---- files: parts made elsewhere, inside the project directory only
    def("load", (ref CallArgs a) {
        // load("part.stl", scale: 1): STL, OBJ and 3MF (mesh; STL and OBJ in mm) or STEP (exact B-rep)
        import std.file : exists, read, readText, isFile;
        import std.path : buildNormalizedPath, absolutePath, extension, dirName;
        import std.string : toLower;
        import hackerscad.io.meshread;

        auto x = Args(it, a, "load", ["path", "scale"]);
        auto p = x.get("path");
        if (p.kind != Kind.str)
            throw new HcadError(Code.type, "load needs a file path string", x.spanOf("path"));
        auto root = buildNormalizedPath(absolutePath(it.root));
        auto base = a.caller && a.caller.path.length && a.caller.path[0] != '<' ? dirName(a.caller.path) : root;
        auto file = buildNormalizedPath(absolutePath(p.s, base));
        if (!(file == root || file.startsWith(root ~ "/")))
            throw new HcadError(Code.sandbox, "load can only read files inside the project directory", x.spanOf("path"));
        if (!exists(file) || !isFile(file))
            throw new HcadError(Code.import_, "file not found: " ~ p.s, x.spanOf("path"));

        Brep b;
        immutable ext = extension(file).toLower;
        try
        {
            switch (ext)
            {
            case ".step", ".stp":
                b = k.readStep(file);
                break;
            case ".stl", ".obj", ".3mf":
                {
                    auto mesh = ext == ".stl" ? readStl(cast(ubyte[]) read(file))
                        : ext == ".obj" ? readObj(readText(file)) : read3mf(cast(ubyte[]) read(file));
                    if (!mesh.isClosed)
                        throw new HcadError(Code.kernel, "the mesh in " ~ p.s ~ " is not closed (it has holes or loose edges)",
                            x.spanOf("path"));
                    b = k.fromMesh(mesh);
                    break;
                }
            default:
                throw new HcadError(Code.import_, format("unsupported file type '%s' (use .stl, .obj, .3mf, .step or .stp)", ext),
                    x.spanOf("path"));
            }
        }
        catch (MeshFormatException e)
            throw new HcadError(Code.import_, e.msg, x.spanOf("path"));
        if (x.has("scale"))
        {
            immutable f = x.num("scale");
            if (f <= 0)
                throw new HcadError(Code.type, "scale must be positive", x.spanOf("scale"));
            b = k.scale(b, f);
        }
        return Value.of(primitive(it, b, "load", a.span));
    });

    def("centered", (ref CallArgs a) {
        // moves a profile (in X and Y) or a solid (in X, Y and Z) so that its bounding box is centred on the origin
        auto x = Args(it, a, "centered", ["shape"]);
        auto s = x.solid("shape");
        auto bb = k.bbox(nonEmpty(s, a.span));
        auto c = bb.center;
        if (s.flat)
            c.z = 0;
        return transformed(it, a.span, s, b => k.translate(b, -c));
    });

    // ---- profiles (2D, on the XY plane) and what turns them into solids
    Value flat(Brep b, string kind, Span span)
    {
        auto sv = primitive(it, b, kind, span);
        sv.flat = true;
        return Value.of(sv);
    }

    def("rect", (ref CallArgs a) {
        auto x = Args(it, a, "rect", ["w", "h"]);
        immutable w = x.len("w"), h = x.has("h") ? x.len("h") : w;
        positive(a, [w, h], "rect sizes");
        return flat(k.rect(w, h), "rect", a.span);
    });
    def("circle", (ref CallArgs a) {
        auto x = Args(it, a, "circle", ["r", "d"]);
        auto r = x.radius("r", "d");
        positive(a, [r], "circle radius");
        return flat(k.circle(r), "circle", a.span);
    });
    def("polygon", (ref CallArgs a) {
        // polygon([vec(0, 0), vec(30, 0), vec(0, 20)]) or [[0, 0], [30, 0], [0, 20]]
        auto x = Args(it, a, "polygon", ["points"]);
        auto pts = x.get("points");
        if (pts.kind != Kind.array || pts.arr.length < 3)
            throw new HcadError(Code.type, "polygon needs an array of at least 3 points", x.spanOf("points"));
        double[] xy;
        foreach (p; pts.arr)
        {
            auto v = p.kind == Kind.array ? arrayToVec(it, p.arr, a.caller, x.spanOf("points")) : p;
            if (v.kind != Kind.vec)
                throw new HcadError(Code.type, format("polygon points must be vectors, not %s", v.typeName), x.spanOf("points"));
            immutable f = v.v.dim == Dim.none ? x.unitFactor : 1;
            xy ~= [v.v.v.x * f, v.v.v.y * f];
        }
        return flat(k.polygon(xy), "polygon", a.span);
    });
    def("regularPolygon", (ref CallArgs a) {
        // regularPolygon(6, d: 10.mm): d/r measure the corners (circumscribed circle)
        auto x = Args(it, a, "regularPolygon", ["n", "r", "d"]);
        immutable n = count(x, "n"), r = x.radius("r", "d");
        if (n < 3)
            throw new HcadError(Code.type, "a regular polygon has at least 3 sides", x.spanOf("n"));
        double[] xy;
        foreach (i; 0 .. n)
            xy ~= [r * cos(2 * PI * i / n), r * sin(2 * PI * i / n)];
        return flat(k.polygon(xy), "polygon", a.span);
    });
    def("slot", (ref CallArgs a) {
        // a stadium: length end to end along X, width along Y
        auto x = Args(it, a, "slot", ["length", "width"]);
        immutable l = x.len("length"), w = x.len("width");
        if (l < w)
            throw new HcadError(Code.type, "a slot must be at least as long as it is wide", a.span);
        auto c = k.circle(w / 2);
        auto shape = k.boolean(k.boolean(k.rect(l - w, w), k.translate(c, Vec3(-(l - w) / 2, 0, 0)), BoolOp.fuse),
            k.translate(c, Vec3((l - w) / 2, 0, 0)), BoolOp.fuse);
        return flat(shape, "slot", a.span);
    });
    def("text", (ref CallArgs a) {
        // text("hello", size: 10.mm, font: "Sans"): a text outline starting at the
        // origin on its baseline
        if (a.positional.length > 1 || (a.positional.length == 1 && a.positional[0].kind != Kind.str))
            throw new HcadError(Code.type, "text(\"…\", size:, font:) makes a 2D text profile; to build strings use "
                ~ "\"… $(value) …\" or ~", a.span);
        auto x = Args(it, a, "text", ["text", "size", "font"]);
        auto t = x.get("text");
        if (t.kind != Kind.str || t.s.length == 0)
            throw new HcadError(Code.type, "text needs a non-empty string", x.spanOf("text"));
        auto font = x.has("font") ? x.get("font").s : "Sans";
        return flat(k.text(t.s, x.lenOr("size", 10), font), "text", a.span);
    });
    def("round", (ref CallArgs a) {
        auto x = Args(it, a, "round", ["profile", "r"]);
        auto p = profileArg(x, "profile");
        immutable r = x.len("r");
        return Value.of(flatResult(transformed(it, a.span, p, b => k.profileRound(b, r), "round")));
    });
    def("extrude", (ref CallArgs a) {
        // profile.extrude(10.mm, taper: 2.deg, symmetric: true), or
        // body.extrude(profile, on: frame, depth: 5.mm) to add material on a face
        if (a.positional.length && a.positional[0].kind == Kind.solid && !a.positional[0].solid.flat)
            return onFace(it, a, false);
        auto x = Args(it, a, "extrude", ["profile", "height", "taper", "symmetric"]);
        auto p = profileArg(x, "profile");
        immutable h = x.len("height"), taper = x.angleOr("taper", 0);
        immutable sym = x.flag("symmetric", false);
        requireXY(it, p, a.span);
        auto sv = derived(it, k.extrude(nonEmpty(p, a.span), h, taper), [p], "extrude", a.span);
        sv.flat = false;
        if (sym)
            return transformed(it, a.span, sv, b => k.translate(b, Vec3(0, 0, -h / 2)));
        return Value.of(sv);
    });
    def("cut", (ref CallArgs a) {
        // body.cut(profile, on: frame, depth: 3.mm) or through: true
        return onFace(it, a, true);
    });
    def("revolve", (ref CallArgs a) {
        // profile.revolve(axis: Y, angle: 360.deg): the axis lies in the profile's plane.
        // Without an axis it turns around Y and stands up: the profile's x is
        // the radius and its y the height along Z (pots, bottles, knobs).
        auto x = Args(it, a, "revolve", ["profile", "axis", "angle"]);
        auto p = profileArg(x, "profile");
        Vec3 o, d = Vec3(0, 1, 0);
        immutable upright = !x.has("axis");
        if (!upright)
            axisArg(x, "axis", o, d);
        immutable ang = x.angleOr("angle", 2 * PI);
        auto b = k.revolve(nonEmpty(p, a.span), o, d, ang);
        if (upright)
            b = k.rotate(b, Vec3(1, 0, 0), PI / 2);
        auto sv = derived(it, b, [p], "revolve", a.span);
        sv.flat = false;
        return Value.of(sv);
    });

    // ---- paths, sweeps and lofts
    Value pathValue(Brep b, string kind, Span span)
    {
        auto sv = primitive(it, b, kind, span);
        sv.path = true;
        return Value.of(sv);
    }
    Vec3[] points(ref Args x, string n, size_t least)
    {
        auto v = x.get(n);
        if (v.kind != Kind.array || v.arr.length < least)
            throw new HcadError(Code.type, format("'%s' must be an array of at least %d points", n, least), x.spanOf(n));
        Vec3[] r;
        foreach (p; v.arr)
        {
            auto q = p.kind == Kind.array ? arrayToVec(it, p.arr, x.raw.caller, x.spanOf(n)) : p;
            if (q.kind != Kind.vec)
                throw new HcadError(Code.type, format("'%s' must contain vectors, not %s", n, q.typeName), x.spanOf(n));
            if (q.v.dim != Dim.none && q.v.dim != Dim.length)
                throw new HcadError(Code.units, format("points must be lengths, not %s", q.v.dim.name), x.spanOf(n));
            r ~= q.v.dim == Dim.none ? q.v.v * x.unitFactor : q.v.v;
        }
        return r;
    }
    def("path", (ref CallArgs a) {
        // path([vec(0, 0, 0), vec(0, 0, 20), vec(30, 0, 20)]): straight segments through the points
        auto x = Args(it, a, "path", ["points", "closed"]);
        return pathValue(k.polyline(points(x, "points", 2), x.flag("closed", false)), "path", a.span);
    });
    def("spline", (ref CallArgs a) {
        // a smooth curve through the points
        auto x = Args(it, a, "spline", ["points", "closed"]);
        return pathValue(k.spline(points(x, "points", 2), x.flag("closed", false)), "spline", a.span);
    });
    def("helix", (ref CallArgs a) {
        // helix(r: 10.mm, pitch: 2.mm, height: 20.mm): around +Z, starting at (r, 0, 0)
        auto x = Args(it, a, "helix", ["r", "d", "pitch", "height", "left"]);
        immutable r = x.radius("r", "d"), p = x.len("pitch"), h = x.len("height");
        positive(a, [r, p, h], "helix sizes");
        return pathValue(k.helix(r, p, h, x.flag("left", false)), "helix", a.span);
    });
    def("sweep", (ref CallArgs a) {
        // circle(d: 4.mm).sweep(path): the profile, drawn on XY around the origin, starts
        // at the beginning of the path and normal to it, its +Y kept towards world +Z
        auto x = Args(it, a, "sweep", ["profile", "path", "frenet"]);
        auto p = profileArg(x, "profile");
        auto pv = x.get("path");
        if (pv.kind != Kind.solid || !pv.solid.path)
            throw new HcadError(Code.type, format("'path' must be a Path (path, spline, helix), not %s", pv.typeName), x.spanOf("path"));
        auto sv = derived(it, k.sweep(nonEmpty(p, a.span), pv.solid.brep, x.flag("frenet", false)), [p], "sweep", a.span);
        sv.flat = false;
        return Value.of(sv);
    });
    def("loft", (ref CallArgs a) {
        // loft([circle(r: 20), rect(30).move(z: 40), circle(r: 10).move(z: 80)]): a solid through
        // profiles placed in space; ruled: true gives flat sides between them
        auto x = Args(it, a, "loft", ["profiles", "ruled"]);
        auto v = x.get("profiles");
        if (v.kind != Kind.array || v.arr.length < 2)
            throw new HcadError(Code.type, "loft needs an array of at least 2 profiles", x.spanOf("profiles"));
        Brep[] bs;
        SolidVal[] ins;
        foreach (p; v.arr)
        {
            if (p.kind != Kind.solid || !p.solid.flat || p.solid.path)
                throw new HcadError(Code.type, format("loft profiles must be 2D profiles, not %s", p.typeName), x.spanOf("profiles"));
            bs ~= nonEmpty(p.solid, a.span);
            ins ~= p.solid;
        }
        auto sv = derived(it, k.loft(bs, x.flag("ruled", false)), ins, "loft", a.span);
        sv.flat = false;
        return Value.of(sv);
    });

    // ---- planes
    def("plane", (ref CallArgs a) {
        // plane(origin: vec(0, 0, 10), normal: Z) or body.plane(faces.top)
        if (a.positional.length && a.positional[0].kind == Kind.solid)
        {
            auto x = Args(it, a, "plane", ["solid", "face"]);
            auto s = x.solid("solid");
            auto idx = resolveSelector(it, x.selector("face", true), s, x.spanOf("face"));
            if (idx.length != 1)
                throw new HcadError(Code.type, format("plane needs exactly one face, the selector matched %d", idx.length),
                    x.spanOf("face"));
            auto f = k.faces(s.brep)[idx[0]];
            return planeValue(f.center, f.normal);
        }
        if (a.positional.length == 3)
        {
            // through three points; the normal follows the right-hand rule p1 → p2 → p3
            auto x = Args(it, a, "plane", ["p1", "p2", "p3"]);
            auto p1 = x.vecLen("p1"), p2 = x.vecLen("p2"), p3 = x.vecLen("p3");
            auto n = (p2 - p1).cross(p3 - p1);
            if (n.length < 1e-9)
                throw new HcadError(Code.type, "the three points are on one line: they do not define a plane", a.span);
            return planeValue(p1, n.normalized);
        }
        if (a.positional.length == 2 && isAxis(a.positional[0]))
        {
            // containing a line and a point
            auto x = Args(it, a, "plane", ["axis", "point"]);
            Vec3 o, d;
            axisArg(x, "axis", o, d);
            auto p = x.vecLen("point");
            auto n = d.cross(p - o);
            if (n.length < 1e-9)
                throw new HcadError(Code.type, "the point is on the axis: it does not define a plane", x.spanOf("point"));
            return planeValue(o, n.normalized);
        }
        auto x = Args(it, a, "plane", ["origin", "normal"]);
        return planeValue(x.has("origin") ? x.vecLen("origin") : Vec3(0, 0, 0), x.has("normal") ? x.dir("normal") : Vec3(0, 0, 1));
    });

    // ---- axes
    def("axis", (ref CallArgs a) {
        // axis(origin:, direction:), axis(p1, p2), body.axis(edges…) from a straight
        // edge (its line) or a circular one (its centre and normal), frame.axis(Z)
        if (a.positional.length && a.positional[0].kind == Kind.solid)
        {
            auto x = Args(it, a, "axis", ["solid", "edge"]);
            auto s = x.solid("solid");
            auto idx = resolveSelector(it, x.selector("edge", false), s, x.spanOf("edge"));
            if (idx.length != 1)
                throw new HcadError(Code.type, format("axis needs exactly one edge, the selector matched %d", idx.length),
                    x.spanOf("edge"));
            auto e = k.edges(s.brep)[idx[0]];
            if (e.kind == EdgeKind.circle)
                return axisValue(e.center, e.axis);
            if (e.kind == EdgeKind.line)
                return axisValue(e.start, e.direction);
            throw new HcadError(Code.type, "only straight and circular edges define an axis", x.spanOf("edge"));
        }
        if (a.positional.length && a.positional[0].kind == Kind.struct_ && a.positional[0].st.def is frameDef)
        {
            // one of the frame's axes, in local terms: frame.axis(X)
            auto x = Args(it, a, "axis", ["frame", "direction"]);
            Vec3 o, ax, ay, az;
            frameArg(x, "frame", o, ax, ay, az);
            auto l = x.has("direction") ? x.dir("direction") : Vec3(0, 0, 1);
            return axisValue(o, (ax * l.x + ay * l.y + az * l.z).normalized);
        }
        if (a.positional.length == 2)
        {
            auto x = Args(it, a, "axis", ["p1", "p2"]);
            auto p1 = x.vecLen("p1"), p2 = x.vecLen("p2");
            if ((p2 - p1).length < 1e-9)
                throw new HcadError(Code.type, "the two points coincide", a.span);
            return axisValue(p1, (p2 - p1).normalized);
        }
        auto x = Args(it, a, "axis", ["origin", "direction"]);
        return axisValue(x.has("origin") ? x.vecLen("origin") : Vec3(0, 0, 0), x.has("direction") ? x.dir("direction") : Vec3(0, 0, 1));
    });
    // ---- frames: an origin and three axes to build on a face or plane
    def("frame", (ref CallArgs a) {
        // body.frame(faces.top, origin: vec(…), x: Y) or plane.frame(origin: vec(…), x: Y)
        Vec3 o, n;
        Args x;
        if (a.positional.length && a.positional[0].kind == Kind.solid)
        {
            x = Args(it, a, "frame", ["solid", "face", "origin", "x"]);
            auto s = x.solid("solid");
            auto idx = resolveSelector(it, x.selector("face", true), s, x.spanOf("face"));
            if (idx.length != 1)
                throw new HcadError(Code.type, format("frame needs exactly one face, the selector matched %d", idx.length),
                    x.spanOf("face"));
            auto f = k.faces(s.brep)[idx[0]];
            o = f.center;
            n = f.normal;
        }
        else
        {
            x = Args(it, a, "frame", ["plane", "origin", "x"]);
            planeArg(x, "plane", o, n);
        }
        if (x.has("origin"))
        {
            // a chosen origin is projected onto the plane
            auto p = x.vecLen("origin");
            o = p - n * (p - o).dot(n);
        }
        auto xAxis = inPlane(x.has("x") ? x.dir("x") : Vec3(1, 0, 0), n);
        if (xAxis.length < 1e-9)
        {
            if (x.has("x"))
                throw new HcadError(Code.type, "the x direction is perpendicular to the plane", x.spanOf("x"));
            xAxis = inPlane(Vec3(0, 1, 0), n);
        }
        xAxis = xAxis.normalized;
        return frameValue(o, xAxis, n.cross(xAxis), n);
    });
    def("at", (ref CallArgs a) {
        // the same frame with its origin moved, in local coordinates
        auto x = Args(it, a, "at", ["frame", "x", "y", "z"]);
        Vec3 o, ax, ay, az;
        frameArg(x, "frame", o, ax, ay, az);
        return frameValue(o + ax * x.lenOr("x", 0) + ay * x.lenOr("y", 0) + az * x.lenOr("z", 0), ax, ay, az);
    });
    def("turn", (ref CallArgs a) {
        // rotates the X and Y axes around the frame's Z
        auto x = Args(it, a, "turn", ["frame", "angle"]);
        Vec3 o, ax, ay, az;
        frameArg(x, "frame", o, ax, ay, az);
        immutable t = x.angle("angle");
        return frameValue(o, ax * cos(t) + ay * sin(t), ay * cos(t) - ax * sin(t), az);
    });
    def("placeOn", (ref CallArgs a) {
        // a solid built on XY with Z up, moved onto a frame (Z along its normal)
        // or onto a plane (its origin, X projected on it)
        auto x = Args(it, a, "placeOn", ["solid", "frame"]);
        auto s = x.solid("solid");
        Vec3 o, ax, ay, az;
        auto v = x.get("frame");
        if (v.kind == Kind.struct_ && v.st.def is planeDef)
        {
            planeArg(x, "frame", o, az);
            ax = inPlane(Vec3(1, 0, 0), az);
            if (ax.length < 1e-9)
                ax = inPlane(Vec3(0, 1, 0), az);
            ax = ax.normalized;
            ay = az.cross(ax);
        }
        else
            frameArg(x, "frame", o, ax, ay, az);
        Vec3 axis;
        immutable angle = axisAngle(ax, ay, az, axis);
        return transformed(it, a.span, s, (Brep b) {
            if (angle > 1e-12)
                b = k.rotate(b, axis, angle);
            return k.translate(b, o);
        });
    });

    def("offset", (ref CallArgs a) {
        // profile.offset(d) grows or shrinks a profile; plane.offset(d) is a parallel plane
        if (a.positional.length && a.positional[0].kind == Kind.solid)
        {
            auto x = Args(it, a, "offset", ["profile", "distance"]);
            auto p = profileArg(x, "profile");
            immutable d = x.len("distance");
            return Value.of(flatResult(transformed(it, a.span, p, b => k.profileOffset(b, d), "offset")));
        }
        auto x = Args(it, a, "offset", ["plane", "distance"]);
        Vec3 o, n;
        planeArg(x, "plane", o, n);
        return planeValue(o + n * x.len("distance"), n);
    });
    def("flip", (ref CallArgs a) {
        auto x = Args(it, a, "flip", ["plane"]);
        Vec3 o, n;
        planeArg(x, "plane", o, n);
        return planeValue(o, -n);
    });
    def("split", (ref CallArgs a) {
        // s.split(plane): .above is on the side the normal points to, .below the other
        auto x = Args(it, a, "split", ["solid", "plane"]);
        auto s = x.solid("solid");
        Vec3 o, n;
        planeArg(x, "plane", o, n);
        auto half = halfSpace(it, nonEmpty(s, a.span), o, n, a.span);
        auto above = solidBoolean(it, s, half, BoolOp.common, a.span);
        auto below = solidBoolean(it, s, half, BoolOp.cut, a.span);
        return Value.make(Kind.struct_, StructVal(halvesDef, [above, below]));
    });
}

/// A box covering everything on the normal's side of the plane (seen from
/// solid `near`), registered as a "split" feature for face provenance.
SolidVal halfSpace(Interp it, Brep near, Vec3 o, Vec3 n, Span span)
{
    import std.math : acos;

    auto k = it.kernel;
    auto bb = k.bbox(near);
    immutable size = 4 * (bb.size.length + (bb.center - o).length) + 10;
    auto b = k.translate(k.box(size, size, size), Vec3(-size / 2, -size / 2, 0)); // above XY
    immutable c = n.dot(Vec3(0, 0, 1));
    if (c < -1 + 1e-12)
        b = k.rotate(b, Vec3(1, 0, 0), PI);
    else if (c < 1 - 1e-12)
        b = k.rotate(b, Vec3(0, 0, 1).cross(n), acos(c));
    b = k.translate(b, o);
    return primitive(it, b, "split", span);
}

Value axisValue(Vec3 origin, Vec3 direction) => Value.make(Kind.struct_, StructVal(axisDef,
    [Value.vector(origin, 3, Dim.length), Value.vector(direction.normalized, 3, Dim.none)]));

bool isAxis(Value v) => v.kind == Kind.struct_ && v.st.def is axisDef;

/// An Axis value, or a bare direction meaning an axis through the origin.
void axisArg(ref Args x, string name, out Vec3 origin, out Vec3 direction)
{
    auto v = x.get(name);
    if (isAxis(v))
    {
        origin = v.st.fields[0].v.v;
        direction = v.st.fields[1].v.v;
        return;
    }
    if (v.kind == Kind.vec || v.kind == Kind.array)
    {
        origin = Vec3(0, 0, 0);
        direction = x.dir(name);
        return;
    }
    throw new HcadError(Code.type, format("'%s' must be an Axis or a direction (Z, axis(p1, p2), body.axis(edges…)), not %s",
        name, v.typeName), x.spanOf(name));
}

StructDef axisDef()
{
    __gshared StructDef def;   // one for every thread: values compare by it
    if (def is null)
        def = builtinStruct("Axis", ["origin", "direction"], "Vec3");
    return def;
}

Value frameValue(Vec3 origin, Vec3 x, Vec3 y, Vec3 z) => Value.make(Kind.struct_, StructVal(frameDef,
    [Value.vector(origin, 3, Dim.length), Value.vector(x, 3, Dim.none), Value.vector(y, 3, Dim.none), Value.vector(z, 3, Dim.none)]));

void frameArg(ref Args x, string name, out Vec3 origin, out Vec3 ax, out Vec3 ay, out Vec3 az)
{
    auto v = x.get(name);
    if (v.kind != Kind.struct_ || v.st.def !is frameDef)
        throw new HcadError(Code.type, format("'%s' must be a Frame or a Plane (World, body.frame(faces.top), XY), not %s",
            name, v.typeName), x.spanOf(name));
    origin = v.st.fields[0].v.v;
    ax = v.st.fields[1].v.v;
    ay = v.st.fields[2].v.v;
    az = v.st.fields[3].v.v;
}

StructDef frameDef()
{
    __gshared StructDef def;   // one for every thread: values compare by it
    if (def is null)
    {
        def = builtinStruct("Frame", ["origin", "x", "y", "z"], "Vec3");
    }
    return def;
}

/// `v` without its component along the unit normal `n`.
Vec3 inPlane(Vec3 v, Vec3 n) => v - n * v.dot(n);

/// Axis and angle of the rotation whose matrix has columns x, y, z.
double axisAngle(Vec3 x, Vec3 y, Vec3 z, out Vec3 axis)
{
    import std.math : acos;

    immutable trace = x.x + y.y + z.z;
    immutable c = max(-1.0, min(1.0, (trace - 1) / 2));
    immutable angle = acos(c);
    if (angle < 1e-12)
    {
        axis = Vec3(0, 0, 1);
        return 0;
    }
    if (PI - angle < 1e-6)
    {
        // half turn: the axis comes from the diagonal
        auto d = Vec3(sqrt(max(0.0, (x.x + 1) / 2)), sqrt(max(0.0, (y.y + 1) / 2)), sqrt(max(0.0, (z.z + 1) / 2)));
        if (d.x >= d.y && d.x >= d.z)
            axis = Vec3(d.x, x.y / (2 * d.x), x.z / (2 * d.x));
        else if (d.y >= d.z)
            axis = Vec3(y.x / (2 * d.y), d.y, y.z / (2 * d.y));
        else
            axis = Vec3(z.x / (2 * d.z), z.y / (2 * d.z), d.z);
        axis = axis.normalized;
        return angle;
    }
    // R[i][j]: row i, column j; columns are x, y, z
    axis = Vec3(y.z - z.y, z.x - x.z, x.y - y.x).normalized;
    return angle;
}

Value planeValue(Vec3 origin, Vec3 normal) => Value.make(Kind.struct_, StructVal(planeDef,
    [Value.vector(origin, 3, Dim.length), Value.vector(normal.normalized, 3, Dim.none)]));

void planeArg(ref Args x, string name, out Vec3 origin, out Vec3 normal)
{
    auto v = x.get(name);
    if (v.kind != Kind.struct_ || v.st.def !is planeDef)
        throw new HcadError(Code.type, format("'%s' must be a Plane (XY, plane(origin:, normal:), body.plane(faces.top)), not %s",
            name, v.typeName), x.spanOf(name));
    origin = v.st.fields[0].v.v;
    normal = v.st.fields[1].v.v;
}

StructDef planeDef()
{
    __gshared StructDef def;   // one for every thread: values compare by it
    if (def is null)
        def = builtinStruct("Plane", ["origin", "normal"], "Vec3");
    return def;
}

StructDef halvesDef()
{
    __gshared StructDef def;   // one for every thread: values compare by it
    if (def is null)
        def = builtinStruct("Halves", ["above", "below"], "Solid");
    return def;
}

StructDef builtinStruct(string name, string[] fields, string type)
{
    auto def = new StructDef;
    def.name = name;
    foreach (f; fields)
    {
        auto t = new TypeRef;
        t.name = type;
        def.fields ~= StructDef.FieldInfo(f, t, null);
    }
    return def;
}

// ================================================================ helpers used by the interpreter

Value solidBoolean(Interp it, SolidVal a, SolidVal b, BoolOp op, Span span)
{
    SolidVal r;
    if (a.brep is null || b.brep is null)
    {
        final switch (op)
        {
        case BoolOp.fuse: r = a.brep is null ? b : a; break;
        case BoolOp.cut: r = a; break;
        case BoolOp.common: r = new SolidVal(null, span); break;
        }
        return Value.of(r);
    }
    try
    {
        auto b2 = it.kernel.boolean(a.brep, b.brep, op);
        // an operation can leave nothing (disjoint intersection, total cut)
        if (it.kernel.faces(b2).length == 0)
        {
            r = new SolidVal(null, span);
            r.rgb = a.rgb;
            r.hasColor = a.hasColor;
        }
        else
            r = derived(it, b2, [a, b], op == BoolOp.fuse ? "union" : op == BoolOp.cut ? "difference" : "intersection", span);
    }
    catch (KernelException e)
        throw new HcadError(Code.kernel, e.msg, span);
    return Value.of(r);
}

uint colorOf(Value v, Span span)
{
    if (v.isNum && v.n.isInt)
        return cast(uint) v.n.value;
    if (v.kind != Kind.str)
        throw new HcadError(Code.type, "a color is a name (\"steelblue\"), \"#RRGGBB\", \"#RRGGBBAA\" or rgb(…)", span);
    auto s = v.s.toLower;
    try
    {
        if (s.length == 7 && s[0] == '#')
            return s[1 .. $].to!uint(16);
        if (s.length == 9 && s[0] == '#')
        {
            immutable c = s[1 .. $].to!uint(16);
            return withAlpha(c >> 8, (c & 0xFF) / 255.0);
        }
    }
    catch (ConvException)
        throw new HcadError(Code.type, format("'%s' is not a hex colour", v.s), span);
    if (auto c = s in namedColors)
        return *c;
    throw new HcadError(Code.type, format("unknown color '%s'", v.s), span, Interp.suggest(s, namedColors.keys));
}

immutable uint[string] namedColors;

shared static this()
{
    // the built-in struct types, made before any thread uses them
    cast(void) axisDef();
    cast(void) frameDef();
    cast(void) planeDef();
    cast(void) halvesDef();
    cast(void) bboxDef();
    // the CSS colour names
    namedColors = [
        "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF, "aquamarine": 0x7FFFD4,
        "azure": 0xF0FFFF, "beige": 0xF5F5DC, "bisque": 0xFFE4C4, "black": 0x000000, "blanchedalmond": 0xFFEBCD,
        "blue": 0x0000FF, "blueviolet": 0x8A2BE2, "brown": 0xA52A2A, "burlywood": 0xDEB887, "cadetblue": 0x5F9EA0,
        "chartreuse": 0x7FFF00, "chocolate": 0xD2691E, "coral": 0xFF7F50, "cornflowerblue": 0x6495ED,
        "cornsilk": 0xFFF8DC, "crimson": 0xDC143C, "cyan": 0x00FFFF, "darkblue": 0x00008B, "darkcyan": 0x008B8B,
        "darkgoldenrod": 0xB8860B, "darkgray": 0xA9A9A9, "darkgreen": 0x006400, "darkgrey": 0xA9A9A9,
        "darkkhaki": 0xBDB76B, "darkmagenta": 0x8B008B, "darkolivegreen": 0x556B2F, "darkorange": 0xFF8C00,
        "darkorchid": 0x9932CC, "darkred": 0x8B0000, "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F,
        "darkslateblue": 0x483D8B, "darkslategray": 0x2F4F4F, "darkslategrey": 0x2F4F4F, "darkturquoise": 0x00CED1,
        "darkviolet": 0x9400D3, "deeppink": 0xFF1493, "deepskyblue": 0x00BFFF, "dimgray": 0x696969,
        "dimgrey": 0x696969, "dodgerblue": 0x1E90FF, "firebrick": 0xB22222, "floralwhite": 0xFFFAF0,
        "forestgreen": 0x228B22, "fuchsia": 0xFF00FF, "gainsboro": 0xDCDCDC, "ghostwhite": 0xF8F8FF,
        "gold": 0xFFD700, "goldenrod": 0xDAA520, "gray": 0x808080, "green": 0x008000, "greenyellow": 0xADFF2F,
        "grey": 0x808080, "honeydew": 0xF0FFF0, "hotpink": 0xFF69B4, "indianred": 0xCD5C5C, "indigo": 0x4B0082,
        "ivory": 0xFFFFF0, "khaki": 0xF0E68C, "lavender": 0xE6E6FA, "lavenderblush": 0xFFF0F5,
        "lawngreen": 0x7CFC00, "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6, "lightcoral": 0xF08080,
        "lightcyan": 0xE0FFFF, "lightgoldenrodyellow": 0xFAFAD2, "lightgray": 0xD3D3D3, "lightgreen": 0x90EE90,
        "lightgrey": 0xD3D3D3, "lightpink": 0xFFB6C1, "lightsalmon": 0xFFA07A, "lightseagreen": 0x20B2AA,
        "lightskyblue": 0x87CEFA, "lightslategray": 0x778899, "lightslategrey": 0x778899,
        "lightsteelblue": 0xB0C4DE, "lightyellow": 0xFFFFE0, "lime": 0x00FF00, "limegreen": 0x32CD32,
        "linen": 0xFAF0E6, "magenta": 0xFF00FF, "maroon": 0x800000, "mediumaquamarine": 0x66CDAA,
        "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3, "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371,
        "mediumslateblue": 0x7B68EE, "mediumspringgreen": 0x00FA9A, "mediumturquoise": 0x48D1CC,
        "mediumvioletred": 0xC71585, "midnightblue": 0x191970, "mintcream": 0xF5FFFA, "mistyrose": 0xFFE4E1,
        "moccasin": 0xFFE4B5, "navajowhite": 0xFFDEAD, "navy": 0x000080, "oldlace": 0xFDF5E6, "olive": 0x808000,
        "olivedrab": 0x6B8E23, "orange": 0xFFA500, "orangered": 0xFF4500, "orchid": 0xDA70D6,
        "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98, "paleturquoise": 0xAFEEEE, "palevioletred": 0xDB7093,
        "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9, "peru": 0xCD853F, "pink": 0xFFC0CB, "plum": 0xDDA0DD,
        "powderblue": 0xB0E0E6, "purple": 0x800080, "rebeccapurple": 0x663399, "red": 0xFF0000,
        "rosybrown": 0xBC8F8F, "royalblue": 0x4169E1, "saddlebrown": 0x8B4513, "salmon": 0xFA8072,
        "sandybrown": 0xF4A460, "seagreen": 0x2E8B57, "seashell": 0xFFF5EE, "sienna": 0xA0522D, "silver": 0xC0C0C0,
        "skyblue": 0x87CEEB, "slateblue": 0x6A5ACD, "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xFFFAFA,
        "springgreen": 0x00FF7F, "steelblue": 0x4682B4, "tan": 0xD2B48C, "teal": 0x008080, "thistle": 0xD8BFD8,
        "tomato": 0xFF6347, "turquoise": 0x40E0D0, "violet": 0xEE82EE, "wheat": 0xF5DEB3, "white": 0xFFFFFF,
        "whitesmoke": 0xF5F5F5, "yellow": 0xFFFF00, "yellowgreen": 0x9ACD32,
    ];
}

Value arrayToVec(Interp it, Value[] items, ModuleVal mod, Span span)
{
    if (items.length != 2 && items.length != 3)
        throw new HcadError(Code.arity, format("a vector has 2 or 3 components, not %d", items.length), span);
    Dim dim = Dim.none;
    foreach (v; items)
    {
        if (!v.isNum)
            throw new HcadError(Code.type, format("vector components must be numbers, not %s", v.typeName), span);
        if (v.n.dim != Dim.none)
        {
            if (dim != Dim.none && dim != v.n.dim)
                throw new HcadError(Code.units, "vector components have different units", span);
            dim = v.n.dim;
        }
    }
    double[3] c = 0;
    foreach (i, v; items)
        c[i] = v.n.value * (v.n.dim == Dim.none && dim == Dim.length ? (mod ? mod.unitFactor : 1)
            : v.n.dim == Dim.none && dim == Dim.angle ? PI / 180 : 1);
    return Value.vector(Vec3(c[0], c[1], c[2]), cast(ubyte) items.length, dim);
}

/// Properties and methods of built-in values. Methods come back bound to
/// the receiver with isMethod set, so `e.isLine` and `e.isParallel(Z)` work.
bool builtinMember(Interp it, Value obj, string name, Span span, out Value result, out bool isMethod)
{
    Value method(BuiltinImpl impl)
    {
        auto b = new Builtin;
        b.name = name;
        b.impl = impl;
        auto bound = new Bound;
        bound.receiver = obj;
        bound.func = Value.make(Kind.builtin, b);
        isMethod = true;
        return Value.make(Kind.bound, bound);
    }

    Value vec3(Vec3 v, Dim d = Dim.length) => Value.vector(v, 3, d);
    Value len(double x) => Value.number(x, Dim.length);

    switch (obj.kind)
    {
    case Kind.object_:
        if (obj.obj.property(name, span, result))
            return true;
        if (auto impl = obj.obj.method(name))
        {
            result = method(impl);
            return true;
        }
        return false;
    case Kind.array:
        if (name == "length") { result = Value.integer(obj.arr.length); return true; }
        if (name == "empty") { result = Value.of(obj.arr.length == 0); return true; }
        return false;
    case Kind.str:
        if (name == "length") { result = Value.integer(obj.s.length); return true; }
        return false;
    case Kind.aa:
        if (name == "length") { result = Value.integer(obj.aa.vals.length); return true; }
        if (name == "keys") { result = Value.of(obj.aa.keys.values); return true; }
        if (name == "values") { result = Value.of(obj.aa.vals.values); return true; }
        return false;
    case Kind.vec:
        {
            auto v = obj.v;
            switch (name)
            {
            case "x": result = Value.number(v.v.x, v.dim); return true;
            case "y": result = Value.number(v.v.y, v.dim); return true;
            case "z":
                if (v.n < 3) return false;
                result = Value.number(v.v.z, v.dim);
                return true;
            case "xy": result = Value.vector(Vec3(v.v.x, v.v.y, 0), 2, v.dim); return true;
            case "length": result = Value.number(v.v.length, v.dim); return true;
            case "normalized": result = Value.vector(v.v.normalized, v.n, Dim.none); return true;
            default: return false;
            }
        }
    case Kind.type:
        if (name == "init")
        {
            auto t = new TypeRef;
            t.name = obj.type.name;
            t.span = span;
            result = it.defaultOf(t, obj.type.def ? obj.type.def.mod : it.currentModule, span);
            return true;
        }
        return false;
    case Kind.solid:
        {
            auto s = obj.solid;
            switch (name)
            {
            case "bbox":
                {
                    auto b = it.kernel.bbox(nonEmpty(s, span));
                    result = Value.make(Kind.struct_, StructVal(bboxDef,
                        [vec3(b.min), vec3(b.max), vec3(b.size), vec3(b.center)]));
                    return true;
                }
            case "volume": result = Value.number(s.brep ? it.kernel.volume(s.brep) : 0, Dim.volume); return true;
            case "area": result = Value.number(s.brep ? it.kernel.area(s.brep) : 0, Dim.area); return true;
            case "isEmpty": result = Value.of(s.brep is null); return true;
            case "pieces":
                {
                    // separate bodies, ordered by position along X, then Y, then Z
                    Value[] r;
                    if (s.brep !is null)
                        foreach (b; it.kernel.solids(s.brep))
                            r ~= Value.of(derived(it, b, [s], "pieces", span));
                    auto key(Value v) => it.kernel.bbox(v.solid.brep).center;
                    sort!((p, q) {
                        auto a = key(p), b = key(q);
                        if (abs(a.x - b.x) > 1e-6) return a.x < b.x;
                        if (abs(a.y - b.y) > 1e-6) return a.y < b.y;
                        return a.z < b.z;
                    })(r);
                    result = Value.of(r);
                    return true;
                }
            case "isValid": result = Value.of(s.brep !is null && it.kernel.isValid(s.brep)); return true;
            default: return false;
            }
        }
    case Kind.edge:
        {
            auto e = obj.edge.info;
            switch (name)
            {
            case "start": result = vec3(e.start); return true;
            case "end": result = vec3(e.end); return true;
            case "mid": result = vec3(e.mid); return true;
            case "direction": result = vec3(e.direction, Dim.none); return true;
            case "length": result = len(e.length); return true;
            case "isLine": result = Value.of(e.kind == EdgeKind.line); return true;
            case "center", "axis", "radius":
                if (e.kind != EdgeKind.circle)
                    throw new HcadError(Code.type, format("'%s' is only defined for circular edges (check e.isCircle first)", name), span);
                result = name == "center" ? vec3(e.center) : name == "axis" ? vec3(e.axis, Dim.none) : len(e.radius);
                return true;
            case "isCircle": result = Value.of(e.kind == EdgeKind.circle); return true;
            case "isParallel":
                result = method((ref CallArgs a) {
                    auto x = Args(it, a, "isParallel", ["edge", "axis"]);
                    return Value.of(e.kind == EdgeKind.line && abs(e.direction.dot(x.dir("axis"))) > 1 - 1e-6);
                });
                return true;
            case "isPerpendicular":
                result = method((ref CallArgs a) {
                    auto x = Args(it, a, "isPerpendicular", ["edge", "axis"]);
                    return Value.of(e.kind == EdgeKind.line && abs(e.direction.dot(x.dir("axis"))) < 1e-6);
                });
                return true;
            default: return false;
            }
        }
    case Kind.face:
        {
            auto f = obj.face.info;
            switch (name)
            {
            case "center": result = vec3(f.center); return true;
            case "normal": result = vec3(f.normal, Dim.none); return true;
            case "area": result = Value.number(f.area, Dim.area); return true;
            case "isParallel":
                result = method((ref CallArgs a) {
                    auto x = Args(it, a, "isParallel", ["face", "axis"]);
                    return Value.of(abs(f.normal.dot(x.dir("axis"))) < 1e-6);
                });
                return true;
            case "isPerpendicular":
                result = method((ref CallArgs a) {
                    auto x = Args(it, a, "isPerpendicular", ["face", "axis"]);
                    return Value.of(abs(f.normal.dot(x.dir("axis"))) > 1 - 1e-6);
                });
                return true;
            default: return false;
            }
        }
    case Kind.selector:
        return selectorMember(it, obj.sel, name, span, result, isMethod, &method);
    default:
        return false;
    }
}

/// Calling a selector directly is a mistake: point to .filter().
Value refineSelector(Interp it, SelectorVal sel, ref CallArgs a)
{
    immutable what = sel.faces ? "faces" : "edges";
    throw new HcadError(Code.syntax, format("use %s.filter(%s => condition) to select %s", what, what[0 .. 1], what), a.span);
}

/// Indices of the edges/faces of `s` matched by the selector.
int[] resolveSelector(Interp it, SelectorVal sel, SolidVal s, Span span, bool allowEmpty = false)
{
    auto b = nonEmpty(s, span);
    SelectCtx ctx;
    auto faces = it.kernel.faces(b);
    ctx.faces = faces;
    ctx.creators = s.creators.length == faces.length ? s.creators : null;
    if (!sel.faces)
    {
        ctx.edges = it.kernel.edges(b);
        ctx.edgeFaces = it.kernel.edgeFaces(b);
    }
    int[][SelectorVal] nested;
    ctx.resolve = (SelectorVal inner) {
        if (auto r = inner in nested)
            return *r;
        return nested[inner] = resolveSelector(it, inner, s, span, true);
    };

    immutable n = sel.faces ? faces.length : ctx.edges.length;
    int[] r;
    foreach (i; 0 .. n)
    {
        bool ok = true;
        foreach (t; sel.tests)
            if (!t(i, ctx))
            {
                ok = false;
                break;
            }
        foreach (p; sel.predicates)
        {
            if (!ok)
                break;
            Value item;
            if (sel.faces)
            {
                auto f = new FaceVal;
                f.info = faces[i];
                f.index = i;
                item = Value.make(Kind.face, f);
            }
            else
            {
                auto e = new EdgeVal;
                e.info = ctx.edges[i];
                e.index = i;
                item = Value.make(Kind.edge, e);
            }
            ok = call1(it, p, item, span).truthy;
        }
        if (ok)
            r ~= cast(int) i;
    }
    if (r.length == 0 && !allowEmpty)
        throw new HcadError(Code.kernel, format("the selector matched no %s on this solid", sel.faces ? "faces" : "edges"), span);
    return r;
}

/// Named/positional argument reader with validation and unit coercion.
struct Args
{
    Interp it;
    CallArgs* raw;
    string fn;
    string[] names;
    Value[string] vals;
    Span[string] spans;

    this(Interp it, ref CallArgs a, string fn, string[] names)
    {
        this.it = it;
        raw = &a;
        this.fn = fn;
        this.names = names;
        if (a.templateArgs.length)
            throw new HcadError(Code.arity, format("'%s' takes no template arguments (!)", fn), a.span);
        if (a.positional.length > names.length)
            throw new HcadError(Code.arity, format("%s(%s) takes at most %d arguments, %d given", fn, names.join(", "),
                names.length, a.positional.length), a.span);
        foreach (i, v; a.positional)
        {
            vals[names[i]] = v;
            spans[names[i]] = i < a.positionalSpans.length ? a.positionalSpans[i] : a.span;
        }
        foreach (k; a.namedOrder)
        {
            if (!names.canFind(k))
                throw new HcadError(Code.unknownArg, format("unknown argument '%s' for %s(%s)", k, fn, names.join(", ")),
                    a.namedSpans[k], Interp.suggest(k, names));
            if (k in vals)
                throw new HcadError(Code.unknownArg, format("argument '%s' given both by position and by name", k), a.namedSpans[k]);
            vals[k] = a.named[k];
            spans[k] = a.namedSpans[k];
        }
    }

    bool has(string n) => (n in vals) !is null;
    Span spanOf(string n) => spans.get(n, raw.span);

    Value get(string n)
    {
        if (auto v = n in vals)
            return *v;
        throw new HcadError(Code.missingArg, format("missing argument '%s' for %s(%s)", n, fn, names.join(", ")), raw.span);
    }

    double unitFactor() => raw.caller ? raw.caller.unitFactor : 1;

    double len(string n)
    {
        auto v = get(n);
        if (!v.isNum)
            throw new HcadError(Code.type, format("'%s' must be a Length, not %s", n, v.typeName), spanOf(n));
        if (v.n.dim == Dim.length)
            return v.n.value;
        if (v.n.dim == Dim.none)
            return v.n.value * unitFactor;
        throw new HcadError(Code.units, format("'%s' must be a Length, not a %s", n, v.n.dim.name), spanOf(n));
    }

    double lenOr(string n, double def) => has(n) ? len(n) : def;

    /// r or d (diameter): exactly one must be given.
    double radius(string r, string d)
    {
        if (has(r) && has(d))
            throw new HcadError(Code.unknownArg, format("give either '%s' or '%s', not both", r, d), spanOf(d));
        if (has(d))
            return len(d) / 2;
        if (!has(r))
            throw new HcadError(Code.missingArg, format("%s needs '%s' (radius) or '%s' (diameter)", fn, r, d), raw.span);
        return len(r);
    }

    double angle(string n)
    {
        auto v = get(n);
        if (v.isNum && v.n.dim == Dim.angle)
            return v.n.value;
        if (v.isNum && v.n.dim == Dim.none)
            return v.n.value * PI / 180; // bare angles in features are degrees
        throw new HcadError(Code.units, format("'%s' must be an Angle, not %s", n, v.typeName), spanOf(n));
    }

    double angleOr(string n, double def) => has(n) ? angle(n) : def;

    double num(string n)
    {
        auto v = get(n);
        if (!v.isNum || v.n.dim != Dim.none)
            throw new HcadError(Code.type, format("'%s' must be a plain number, not %s", n, v.typeName), spanOf(n));
        return v.n.value;
    }

    bool flag(string n, bool def)
    {
        if (!has(n))
            return def;
        auto v = get(n);
        if (v.kind != Kind.bool_)
            throw new HcadError(Code.type, format("'%s' must be true or false", n), spanOf(n));
        return v.b;
    }

    SolidVal solid(string n)
    {
        auto v = get(n);
        if (v.kind != Kind.solid)
            throw new HcadError(Code.type, format("%s needs a Solid, not %s", fn, v.typeName), spanOf(n));
        return v.solid;
    }

    SelectorVal selector(string n, bool faces)
    {
        auto v = get(n);
        if (v.kind != Kind.selector || v.sel.faces != faces)
            throw new HcadError(Code.type, format("'%s' must be a %s selector (e.g. %s), not %s", n, faces ? "face" : "edge",
                faces ? "faces.top" : "edges.parallel(Z)", v.typeName), spanOf(n));
        return v.sel;
    }

    VecVal vecAny(string n)
    {
        auto v = get(n);
        if (v.kind == Kind.array)
            v = arrayToVec(it, v.arr, raw.caller, spanOf(n));
        if (v.kind != Kind.vec)
            throw new HcadError(Code.type, format("'%s' must be a vector, not %s", n, v.typeName), spanOf(n));
        return v.v;
    }

    /// A position: lengths, or bare numbers in the model unit.
    Vec3 vecLen(string n)
    {
        auto v = vecAny(n);
        if (v.dim == Dim.length)
            return v.v;
        if (v.dim == Dim.none)
            return v.v * unitFactor;
        throw new HcadError(Code.units, format("'%s' must be a vector of lengths, not %s", n, v.dim.name), spanOf(n));
    }

    /// A direction (X, -Z, vec(1, 1, 0)…), normalized.
    Vec3 dir(string n)
    {
        auto v = vecAny(n);
        if (v.v.length == 0)
            throw new HcadError(Code.type, format("'%s' cannot be a zero vector", n), spanOf(n));
        return v.v.normalized;
    }
}

/// Fillet and chamfer: kernel failures get a message that says what to try.
Value edgeFeature(Interp it, ref CallArgs a, SolidVal s, int[] idx, string kind, string size, Brep delegate(Brep) f)
{
    try
        return transformed(it, a.span, s, f, kind);
    catch (KernelException e)
    {
        string hint;
        immutable bodies = s.brep is null ? 0 : it.kernel.solids(s.brep).length;
        if (bodies > 1)
            hint = format("the solid is made of %s separate bodies touching each other; fuse them first", bodies);
        else
            hint = format("try a smaller %s, or apply it to fewer edges at a time (%s edges selected)", size, idx.length);
        throw new HcadError(Code.kernel, e.msg, a.span, hint);
    }
}

/// Applies an operation to one solid, keeping colour and face provenance;
/// faces the operation creates are attributed to a new `kind` feature.
Value transformed(Interp it, Span span, SolidVal s, Brep delegate(Brep) f, string kind = "transform")
{
    if (s.brep is null)
        return Value.of(s);
    auto r = derived(it, f(s.brep), [s], kind, span);
    // moving what a feature has just made, in the same call (circle(…).move(…)):
    // the feature shows where its solid ends up. A caller moving what a function
    // returned (f().move(…)) moves it on its own line, not on the feature's.
    if (s.creators.length && s.creators[0] > 0 && s.creators[0] <= it.features.length)
    {
        auto feature = &it.features[s.creators[0] - 1];
        if (feature.result is s && feature.frame is it.callFrame)
        {
            feature.result = r;
            feature.moved = true;
        }
    }
    return Value.of(r);
}

SolidVal primitive(Interp it, Brep b, string kind, Span span)
{
    auto r = new SolidVal(b, span);
    immutable id = it.addFeature(kind, span);
    r.creators = new uint[it.kernel.faces(b).length];
    r.creators[] = id;
    it.features[id - 1].result = r;
    return r;
}

/// A result solid whose faces inherit the creators of the faces they come
/// from (kernel face history); new faces belong to a new feature.
SolidVal derived(Interp it, Brep b, SolidVal[] inputs, string kind, Span span)
{
    auto r = new SolidVal(b, span);
    if (inputs.length)
    {
        r.rgb = inputs[0].rgb;
        r.hasColor = inputs[0].hasColor;
        r.flat = inputs[0].flat || (inputs[0].brep is null && inputs.length > 1 && inputs[1].flat);
        // a path moved, turned or mirrored is still a path
        r.path = inputs.length == 1 && inputs[0].path;
    }
    auto origins = it.kernel.faceOrigins(b);
    r.creators = new uint[origins.length];
    uint created;
    foreach (i, o; origins)
    {
        if (o.input >= 0 && o.input < inputs.length && o.index < inputs[o.input].creators.length)
            r.creators[i] = inputs[o.input].creators[o.index];
        else
        {
            if (created == 0)
                created = it.addFeature(kind, span);
            r.creators[i] = created;
        }
    }
    // a boolean is a step of the model even when all its faces come from
    // its operands (a - b where b only trims a): the feature tree lists it
    immutable boolean = inputs.length == 2 && (kind == "union" || kind == "difference" || kind == "intersection");
    if (boolean && created == 0)
        created = it.addFeature(kind, span);
    if (created)
    {
        it.features[created - 1].result = r;
        if (boolean)
            it.features[created - 1].operands = inputs.dup;
    }
    return r;
}

private:

SolidVal profileArg(ref Args x, string name)
{
    auto v = x.get(name);
    if (v.kind != Kind.solid || !v.solid.flat)
        throw new HcadError(Code.type, format("'%s' must be a 2D profile (rect, circle, polygon…), not %s", name, v.typeName),
            x.spanOf(name));
    return v.solid;
}

SolidVal flatResult(Value v)
{
    v.solid.flat = true;
    return v.solid;
}

/// Extrusion works on profiles lying on XY: build there, then place the solid.
void requireXY(Interp it, SolidVal p, Span span)
{
    auto k = it.kernel;
    auto bb = k.bbox(nonEmpty(p, span));
    bool onXY = abs(bb.min.z) < 1e-6 && abs(bb.max.z) < 1e-6;
    foreach (f; k.faces(p.brep))
        onXY = onXY && abs(abs(f.normal.z) - 1) < 1e-9;
    if (!onXY)
        throw new HcadError(Code.type, "extrude a profile while it lies on XY, then place the solid (placeOn, move, rotate)", span);
}

/// body.extrude(profile, on:, depth:) adds material outwards from a face;
/// body.cut(profile, on:, depth: | through: true) removes it inwards.
Value onFace(Interp it, ref CallArgs a, bool remove)
{
    auto k = it.kernel;
    immutable fn = remove ? "cut" : "extrude";
    auto x = Args(it, a, fn, ["solid", "profile", "on", "at", "depth", "through", "taper"]);
    auto body = x.solid("solid");
    auto p = profileArg(x, "profile");
    requireXY(it, p, a.span);
    Vec3 o, ax, ay, az;
    if (x.has("on"))
    {
        auto v = x.get("on");
        if (v.kind == Kind.selector)
        {
            // a face of this very solid: body.cut(circle(d: 3), on: faces.top, at: vec(…), depth: 2.mm)
            auto idx = resolveSelector(it, x.selector("on", true), body, x.spanOf("on"));
            if (idx.length != 1)
                throw new HcadError(Code.type, format("'on' needs exactly one face, the selector matched %d", idx.length),
                    x.spanOf("on"));
            auto f = k.faces(body.brep)[idx[0]];
            o = f.center;
            az = f.normal;
            ax = inPlane(Vec3(1, 0, 0), az);
            if (ax.length < 1e-9)
                ax = inPlane(Vec3(0, 1, 0), az);
            ax = ax.normalized;
            ay = az.cross(ax);
        }
        else if (v.kind == Kind.struct_ && v.st.def is planeDef)
        {
            planeArg(x, "on", o, az);
            ax = inPlane(Vec3(1, 0, 0), az);
            if (ax.length < 1e-9)
                ax = inPlane(Vec3(0, 1, 0), az);
            ax = ax.normalized;
            ay = az.cross(ax);
        }
        else
            frameArg(x, "on", o, ax, ay, az);
    }
    else
    {
        ax = Vec3(1, 0, 0);
        ay = Vec3(0, 1, 0);
        az = Vec3(0, 0, 1);
    }
    if (x.has("at"))
    {
        // a point projected onto the face or plane becomes the origin
        auto q = x.vecLen("at");
        o = q - az * (q - o).dot(az);
    }
    double depth;
    if (x.flag("through", false))
    {
        if (!remove)
            throw new HcadError(Code.type, "through: is for cut()", x.spanOf("through"));
        auto bb = k.bbox(nonEmpty(body, a.span));
        depth = 2 * ((bb.center - o).length + bb.size.length) + 1;
    }
    else
        depth = x.len("depth");
    immutable taper = x.angleOr("taper", 0);
    auto tool = derived(it, k.extrude(nonEmpty(p, a.span), remove ? -depth : depth, taper), [p], fn, a.span);
    tool.flat = false;
    Vec3 axis;
    immutable angle = axisAngle(ax, ay, az, axis);
    auto placed = transformed(it, a.span, tool, (Brep b) {
        if (angle > 1e-12)
            b = k.rotate(b, axis, angle);
        return k.translate(b, o);
    });
    return solidBoolean(it, body, placed.solid, remove ? BoolOp.cut : BoolOp.fuse, a.span);
}

int count(ref Args x, string n)
{
    immutable v = x.num(n);
    if (v != floor(v) || v < 1 || v > 10_000)
        throw new HcadError(Code.type, format("'%s' must be a whole number between 1 and 10000", n), x.spanOf(n));
    return cast(int) v;
}

Brep nonEmpty(SolidVal s, Span span)
{
    if (s.brep is null)
        throw new HcadError(Code.kernel, "the solid is empty", span);
    return s.brep;
}

void positive(ref CallArgs a, double[] xs, string what)
{
    foreach (x; xs)
        if (!(x > 0))
            throw new HcadError(Code.type, what ~ " must be positive", a.span);
}

double comp(Vec3 v, size_t i) => i == 0 ? v.x : i == 1 ? v.y : v.z;
Vec3 axisVec(size_t i) => i == 0 ? Vec3(1, 0, 0) : i == 1 ? Vec3(0, 1, 0) : Vec3(0, 0, 1);

Value unionAll(Interp it, Value[] xs, Span span)
{
    Value acc = Value.of(new SolidVal(null, span));
    foreach (v; xs)
    {
        if (v.kind != Kind.solid)
            throw new HcadError(Code.type, format("cannot fuse %s with solids", v.typeName), span);
        acc = solidBoolean(it, acc.solid, v.solid, BoolOp.fuse, span);
    }
    return acc;
}

SelectorVal copy(SelectorVal s)
{
    auto r = new SelectorVal;
    r.faces = s.faces;
    r.predicates = s.predicates.dup;
    r.tests = s.tests.dup;
    return r;
}

bool selectorMember(Interp it, SelectorVal sel, string name, Span span, out Value result, out bool isMethod,
    Value delegate(BuiltinImpl) method)
{
    Value with_(SelectTest t)
    {
        auto r = copy(sel);
        r.tests ~= t;
        return Value.make(Kind.selector, r);
    }

    // a method taking arguments: keep it a function value when not called
    bool fn(BuiltinImpl impl)
    {
        result = method(impl);
        isMethod = false;
        return true;
    }

    SelectorVal faceSelector(ref CallArgs a, string what)
    {
        auto x = Args(it, a, what, ["selector", "faces"]);
        return x.selector("faces", true);
    }

    switch (name)
    {
    case "filter":
        // edges.filter(e => e.isParallel(Z)), faces.filter(f => f.area > 100.mm ^^ 2)
        return fn((ref CallArgs a) {
            auto f = fnArg(a, 1, "filter", sel.faces ? "f => condition" : "e => condition");
            auto r = copy(sel);
            r.predicates ~= f;
            return Value.make(Kind.selector, r);
        });
    case "from":
        // faces created by a tool or feature: faces.from(hole); edges: both faces from it
        return fn((ref CallArgs a) {
            auto x = Args(it, a, "from", ["selector", "solid"]);
            bool[uint] ids;
            foreach (c; x.solid("solid").creators)
                ids[c] = true;
            if (sel.faces)
                return with_((size_t i, ref SelectCtx c) => c.creators.length && (c.creators[i] in ids) !is null);
            return with_((size_t i, ref SelectCtx c) {
                if (!c.creators.length)
                    return false;
                foreach (f; c.edgeFaces[i])
                    if (f < 0 || (c.creators[f] in ids) is null)
                        return false;
                return true;
            });
        });
    default:
        break;
    }

    if (!sel.faces)
    {
        switch (name)
        {
        case "lines": result = with_((size_t i, ref SelectCtx c) => c.edges[i].kind == EdgeKind.line); return true;
        case "circles": result = with_((size_t i, ref SelectCtx c) => c.edges[i].kind == EdgeKind.circle); return true;
        case "parallel":
            return fn((ref CallArgs a) {
                auto x = Args(it, a, "parallel", ["selector", "axis"]);
                auto ax = x.dir("axis");
                return with_((size_t i, ref SelectCtx c) => c.edges[i].kind == EdgeKind.line && abs(c.edges[i].direction.dot(ax)) > 1 - 1e-6);
            });
        case "perpendicular":
            return fn((ref CallArgs a) {
                auto x = Args(it, a, "perpendicular", ["selector", "axis"]);
                auto ax = x.dir("axis");
                // straight edges across the axis, and circles lying in a plane across it
                return with_((size_t i, ref SelectCtx c) => c.edges[i].kind == EdgeKind.line
                    ? abs(c.edges[i].direction.dot(ax)) < 1e-6
                    : c.edges[i].kind == EdgeKind.circle && abs(c.edges[i].axis.dot(ax)) > 1 - 1e-6);
            });
        case "of":
            // edges.of(faces.top): edges touching any of the faces
            return fn((ref CallArgs a) {
                auto inner = faceSelector(a, "of");
                return with_((size_t i, ref SelectCtx c) {
                    auto set = c.resolve(inner);
                    foreach (f; c.edgeFaces[i])
                        if (f >= 0 && set.canFind(f))
                            return true;
                    return false;
                });
            });
        case "between":
            // edges.between(faces.from(hole), faces.top): the rim of the holes on top
            return fn((ref CallArgs a) {
                auto x = Args(it, a, "between", ["selector", "a", "b"]);
                auto sa = x.selector("a", true), sb = x.selector("b", true);
                return with_((size_t i, ref SelectCtx c) {
                    auto fa = c.resolve(sa), fb = c.resolve(sb);
                    auto f0 = c.edgeFaces[i][0], f1 = c.edgeFaces[i][1];
                    if (f0 < 0 || f1 < 0)
                        return false;
                    return (fa.canFind(f0) && fb.canFind(f1)) || (fa.canFind(f1) && fb.canFind(f0));
                });
            });
        default:
            return false;
        }
    }

    // faces.top etc.: faces whose outward normal points that way and that lie
    // furthest along it (the outer skin, not inner floors)
    Value extremal(Vec3 axis) => with_((size_t i, ref SelectCtx c) {
        if (c.faces[i].normal.dot(axis) < 1 - 1e-6)
            return false;
        double best = -double.infinity;
        foreach (g; c.faces)
            if (g.normal.dot(axis) > 1 - 1e-6)
                best = max(best, g.center.dot(axis));
        return c.faces[i].center.dot(axis) >= best - 1e-6;
    });

    switch (name)
    {
    case "top": result = extremal(Vec3(0, 0, 1)); return true;
    case "bottom": result = extremal(Vec3(0, 0, -1)); return true;
    case "right": result = extremal(Vec3(1, 0, 0)); return true;
    case "left": result = extremal(Vec3(-1, 0, 0)); return true;
    case "back": result = extremal(Vec3(0, 1, 0)); return true;
    case "front": result = extremal(Vec3(0, -1, 0)); return true;
    case "largest":
        {
            // the largest among the faces selected so far: faces.normal(X).largest
            auto prefix = copy(sel);
            result = with_((size_t i, ref SelectCtx c) {
                auto candidates = c.resolve(prefix);
                if (!candidates.canFind(cast(int) i))
                    return false;
                double best = 0;
                foreach (j; candidates)
                    best = max(best, c.faces[j].area);
                return c.faces[i].area >= best * (1 - 1e-9);
            });
            return true;
        }
    case "normal":
        return fn((ref CallArgs a) {
            auto x = Args(it, a, "normal", ["selector", "axis"]);
            auto ax = x.dir("axis");
            return with_((size_t i, ref SelectCtx c) => c.faces[i].normal.dot(ax) > 1 - 1e-6);
        });
    default:
        return false;
    }
}

Value call1(Interp it, Value f, Value x, Span span)
{
    CallArgs a;
    a.positional = [x];
    a.span = span;
    return it.callValue(f, a, span);
}

Value call2(Interp it, Value f, Value x, Value y, Span span)
{
    CallArgs a;
    a.positional = [x, y];
    a.span = span;
    return it.callValue(f, a, span);
}

void noTemplate(ref CallArgs a, string name)
{
    if (a.templateArgs.length)
        throw new HcadError(Code.syntax, format("pass functions as normal arguments: xs.%s(…) instead of %s!(…)", name, name), a.span);
}

/// The function argument at position `i` (after UFCS, the array is 0).
Value fnArg(ref CallArgs a, size_t i, string name, string example)
{
    noTemplate(a, name);
    if (i >= a.positional.length || !a.positional[i].isCallable)
        throw new HcadError(Code.arity, format("%s needs a function: xs.%s(%s)", name, name, example), a.span);
    return a.positional[i];
}

Value[] arrayArg(ref CallArgs a, size_t i, string name)
{
    if (i >= a.positional.length)
        throw new HcadError(Code.missingArg, format("%s needs an array", name), a.span);
    auto v = a.positional[i];
    if (v.kind != Kind.array)
        throw new HcadError(Code.type, format("%s needs an array, not %s", name, v.typeName),
            i < a.positionalSpans.length ? a.positionalSpans[i] : a.span);
    return v.arr;
}

Value num(ref CallArgs a, string name)
{
    if (a.positional.length != 1 || !a.positional[0].isNum)
        throw new HcadError(Code.type, format("%s takes one number", name), a.span);
    return a.positional[0];
}

double plain(ref CallArgs a, string name)
{
    auto v = num(a, name);
    if (v.n.dim != Dim.none)
        throw new HcadError(Code.units, format("%s takes a plain number, not a %s", name, v.n.dim.name), a.span);
    return v.n.value;
}

/// sin(30.deg) or sin(0.5) in radians, as in D.
double angleArg(ref CallArgs a, string name)
{
    auto v = num(a, name);
    if (v.n.dim != Dim.angle && v.n.dim != Dim.none)
        throw new HcadError(Code.units, format("%s takes an Angle, not a %s", name, v.n.dim.name), a.span);
    return v.n.value;
}

Value extreme(Interp it, ref CallArgs a, string name, bool biggest)
{
    Value[] xs = a.positional.length == 1 && a.positional[0].kind == Kind.array ? a.positional[0].arr : a.positional;
    if (xs.length == 0)
        throw new HcadError(Code.arity, name ~ " needs at least one value", a.span);
    Value best = xs[0];
    foreach (v; xs[1 .. $])
        if (it.applyBinary(biggest ? Tok.gt : Tok.lt, v, best, a.span).truthy)
            best = v;
    return best;
}

Value convert(Interp it, ref CallArgs a)
{
    if (a.templateArgs.length != 1 || a.positional.length != 1)
        throw new HcadError(Code.arity, "use to!T(value), e.g. to!string(x) or x.to!int", a.span);
    auto t = a.templateArgs[0];
    string target = t.kind == Kind.type ? t.type.name : t.kind == Kind.str ? t.s : null;
    auto v = a.positional[0];
    switch (target)
    {
    case "string": return Value.of(v.toString);
    case "int", "long":
        if (v.kind == Kind.str)
            return Value.integer(v.s.to!long);
        if (!v.isNum || v.n.dim != Dim.none)
            break;
        if (v.n.value != floor(v.n.value))
            throw new HcadError(Code.type, format("%s is not an integer (use floor/round first)", v), a.span);
        return Value.integer(cast(long) v.n.value);
    case "double", "float", "real":
        if (v.kind == Kind.str)
            return Value.number(v.s.to!double);
        if (v.isNum && v.n.dim == Dim.none)
            return Value.number(v.n.value);
        break;
    default:
        break;
    }
    throw new HcadError(Code.type, format("cannot convert %s to %s", v.typeName, target), a.span);
}

string formatValues(ref CallArgs a)
{
    if (a.positional.length == 0 || a.positional[0].kind != Kind.str)
        throw new HcadError(Code.arity, "format needs a format string", a.span);
    auto fmt = a.positional[0].s;
    size_t next = 1;
    string r;
    for (size_t i = 0; i < fmt.length; i++)
    {
        if (fmt[i] != '%')
        {
            r ~= fmt[i];
            continue;
        }
        if (i + 1 < fmt.length && fmt[i + 1] == '%')
        {
            r ~= '%';
            i++;
            continue;
        }
        size_t j = i + 1;
        while (j < fmt.length && "0123456789.-+ ".canFind(fmt[j]))
            j++;
        if (j >= fmt.length)
            throw new HcadError(Code.syntax, "incomplete format specifier", a.span);
        if (next >= a.positional.length)
            throw new HcadError(Code.arity, "not enough arguments for format string", a.span);
        auto v = a.positional[next++];
        auto spec = fmt[i .. j + 1];
        switch (fmt[j])
        {
        case 's': r ~= v.toString; break;
        case 'd':
            if (!v.isNum) throw new HcadError(Code.type, "%d needs a number", a.span);
            r ~= format("%d", cast(long) v.n.value);
            break;
        case 'f', 'g', 'e':
            {
                if (!v.isNum) throw new HcadError(Code.type, spec ~ " needs a number", a.span);
                // numbers with units are shown in mm or degrees, without the suffix
                double x = v.n.dim == Dim.angle ? v.n.value * 180 / PI : v.n.value;
                r ~= format(spec, x);
                break;
            }
        default:
            throw new HcadError(Code.syntax, format("unsupported format specifier '%s'", spec), a.span);
        }
        i = j;
    }
    return r;
}

StructDef bboxDef()
{
    __gshared StructDef def;   // one for every thread: values compare by it
    if (def is null)
    {
        def = new StructDef;
        def.name = "BBox";
        foreach (f; ["min", "max", "size", "center"])
        {
            auto t = new TypeRef;
            t.name = "Vec3";
            def.fields ~= StructDef.FieldInfo(f, t, null);
        }
    }
    return def;
}

import std.algorithm : fold;
