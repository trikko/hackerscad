/// The prelude: units, math, ranges/algorithms in the style of Phobos, and
/// the geometry API (primitives, transforms, features, selectors).
module hackerscad.lang.builtins;

import std.conv : to, ConvException;
import std.format : format;
import std.math : PI, E, abs, sqrt, floor, ceil, round, sin, cos, tan, asin, acos, atan, atan2, isFinite, exp, log, log10, log2, hypot;
import std.algorithm : all, any, canFind, countUntil, filter, map, sort, max, min;
import std.array : array, join;
import std.uni : toLower;
static import std.string;
import std.algorithm : startsWith;

import hackerscad.lang.errors;
import hackerscad.lang.lexer : Tok;
import hackerscad.lang.ast : TypeRef;
import hackerscad.lang.value;
import hackerscad.lang.interp;
import hackerscad.kernel.brep;
import hackerscad.lang.threading : ThreadSpec;

immutable string[] stdModules = [
    "std.shapes", "std.math", "std.algorithm", "std.range", "std.conv", "std.format", "std.stdio", "std.array",
];

/// Built-in .hcad library sources.
/// Built-in libraries (lib/*.hcad), imported as `import std.gears;` (the old `import gears;` works too, with a
/// warning: a module of the project of that name comes first).
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
        "joints": import("joints.hcad"),
        "molds": import("molds.hcad"),
        "flex": import("flex.hcad"),
        "carlo": import("carlo.hcad"),
    ];
}

/// `import std;`: a module that gives every built-in library (the
/// standard modules are in the prelude anyway).
string stdPackage()
{
    import std.algorithm : sort;
    string src = "module std;\n";
    foreach (name; librarySources.keys.sort)
        src ~= "public import std." ~ name ~ ";\n";
    return src;
}

void installPrelude(Interp it, Env env)
{
    foreach (name, src; librarySources)
    {
        it.embedded[name] = src;
        it.embedded["std." ~ name] = src;
    }
    it.embedded["std"] = stdPackage();

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
    constant("E", Value.number(E));
    constant("X", Value.vector(Vec3(1, 0, 0), 3, Dim.none));
    constant("Y", Value.vector(Vec3(0, 1, 0), 3, Dim.none));
    constant("Z", Value.vector(Vec3(0, 0, 1), 3, Dim.none));
    constant("XY", planeValue(Vec3(0, 0, 0), Vec3(0, 0, 1)));
    // its normal towards the front (-Y), as XY's is up and YZ's to the right: a sketch on it is seen as the
    // Front view sees it, x to the right and y up
    constant("XZ", planeValue(Vec3(0, 0, 0), Vec3(0, -1, 0)));
    constant("YZ", planeValue(Vec3(0, 0, 0), Vec3(1, 0, 0)));
    constant("World", frameValue(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)));
    constant("edges", Value.make(Kind.selector, new SelectorVal));
    {
        auto f = new SelectorVal;
        f.faces = true;
        constant("faces", Value.make(Kind.selector, f));
    }

    // ---- output and strings
    def("writeln", (ref CallArgs a) { it.print(a.positional.map!(v => shown(it, v, a.span)).join, a.span); return Value.void_; });
    def("write", (ref CallArgs a) { it.print(a.positional.map!(v => shown(it, v, a.span)).join, a.span, false); return Value.void_; });
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
    // angles round to whole degrees, not radians
    Value whole(ref CallArgs a, string name, double function(double) f)
    {
        auto v = num(a, name);
        immutable x = v.n.dim == Dim.angle ? f(v.n.value * 180 / PI) * PI / 180 : f(v.n.value);
        return Value.number(x, v.n.dim, v.n.dim == Dim.none && isFinite(x));
    }
    def("floor", (ref CallArgs a) => whole(a, "floor", x => floor(x)));
    def("ceil", (ref CallArgs a) => whole(a, "ceil", x => ceil(x)));
    def("round", (ref CallArgs a) => whole(a, "round", x => round(x)));
    def("sin", (ref CallArgs a) => Value.number(sin(angleArg(a, "sin"))));
    def("cos", (ref CallArgs a) => Value.number(cos(angleArg(a, "cos"))));
    def("tan", (ref CallArgs a) => Value.number(tan(angleArg(a, "tan"))));
    def("asin", (ref CallArgs a) => Value.number(asin(plain(a, "asin")), Dim.angle));
    def("acos", (ref CallArgs a) => Value.number(acos(plain(a, "acos")), Dim.angle));
    def("atan", (ref CallArgs a) => Value.number(atan(plain(a, "atan")), Dim.angle));
    def("pow", (ref CallArgs a) {
        // pow(x, y) is x ^^ y: a length squared is an area, a length to 1.5 an error
        import hackerscad.lang.lexer : Tok;
        auto x = Args(it, a, "pow", ["x", "y"]);
        return it.applyBinary(Tok.pow, x.get("x"), x.get("y"), a.span);
    });
    def("exp", (ref CallArgs a) => Value.number(exp(plain(a, "exp"))));
    def("log", (ref CallArgs a) {
        // the natural logarithm; log(x, base) in another base
        auto x = Args(it, a, "log", ["x", "base"]);
        immutable v = x.num("x");
        if (!(v > 0))
            throw new HcadError(Code.type, "log of a number that is not above 0", x.spanOf("x"));
        if (!x.has("base"))
            return Value.number(log(v));
        immutable b = x.num("base");
        if (!(b > 0) || b == 1)
            throw new HcadError(Code.type, "a logarithm's base is above 0 and not 1", x.spanOf("base"));
        return Value.number(log(v) / log(b));
    });
    def("log10", (ref CallArgs a) => Value.number(log10(plain(a, "log10"))));
    def("log2", (ref CallArgs a) => Value.number(log2(plain(a, "log2"))));
    def("hypot", (ref CallArgs a) {
        // the length of the hypotenuse: hypot(3.mm, 4.mm) is 5 mm
        auto x = Args(it, a, "hypot", ["a", "b"]);
        auto p = x.get("a"), q = x.get("b");
        if (!p.isNum || !q.isNum || p.n.dim != q.n.dim)
            throw new HcadError(Code.units, "hypot needs two numbers with the same unit", a.span);
        return Value.number(hypot(p.n.value, q.n.value), p.n.dim);
    });
    def("sign", (ref CallArgs a) {
        auto v = num(a, "sign");
        return Value.integer(v.n.value > 0 ? 1 : v.n.value < 0 ? -1 : 0);
    });
    def("lerp", (ref CallArgs a) {
        // lerp(a, b, t): from a (t = 0) to b (t = 1), in a straight line; numbers or vectors
        auto x = Args(it, a, "lerp", ["a", "b", "t"]);
        import hackerscad.lang.lexer : Tok;
        auto from = x.get("a"), to = x.get("b");
        auto t = Value.number(x.num("t"));
        return it.applyBinary(Tok.plus, from, it.applyBinary(Tok.mul, it.applyBinary(Tok.minus, to, from, a.span), t, a.span), a.span);
    });
    def("atan2", (ref CallArgs a) {
        auto x = Args(it, a, "atan2", ["y", "x"]);
        auto y = x.get("y"), xx = x.get("x");
        if (!y.isNum || !xx.isNum || y.n.dim != xx.n.dim)
            throw new HcadError(Code.units, "atan2 needs two numbers with the same unit", a.span);
        return Value.number(atan2(y.n.value, xx.n.value), Dim.angle);
    });
    // ---- noise: smooth randomness for textures
    double plainOrMm(Value v, string what, Span span)
    {
        if (!v.isNum)
            throw new HcadError(Code.type, format("%s must be a number, not %s", what, v.typeName), span);
        return v.n.value;   // a length counts in mm
    }
    import hackerscad.geom.noise : NoiseKind;
    NoiseKind noiseKind(ref Args x)
    {
        if (!x.has("kind"))
            return NoiseKind.smooth;
        auto v = x.get("kind");
        foreach (kind; [NoiseKind.smooth, NoiseKind.cells, NoiseKind.edges, NoiseKind.ridged])
            if (v.kind == Kind.str && v.s == format("%s", kind))
                return kind;
        throw new HcadError(Code.type, "the noise kind is \"smooth\", \"cells\", \"edges\" or \"ridged\"",
            x.spanOf("kind"));
    }
    int octaves(ref Args x)
    {
        immutable o = x.has("octaves") ? x.num("octaves") : 1;
        if (!(o >= 1 && o <= 8))
            throw new HcadError(Code.type, format("octaves go from 1 to 8, not %g", o), x.spanOf("octaves"));
        return cast(int) o;
    }
    def("noise", (ref CallArgs a) {
        // noise(x, y, z, seed: 3): smooth, about -1…1, features about one unit across;
        // kind: "cells", "edges", "ridged" (0…1), octaves: finer layers on top
        import hackerscad.geom.noise : noiseOf;
        auto x = Args(it, a, "noise", ["x", "y", "z", "seed", "kind", "octaves"]);
        return Value.number(noiseOf(noiseKind(x), plainOrMm(x.get("x"), "x", x.spanOf("x")),
            x.has("y") ? plainOrMm(x.get("y"), "y", x.spanOf("y")) : 0,
            x.has("z") ? plainOrMm(x.get("z"), "z", x.spanOf("z")) : 0,
            x.has("seed") ? cast(long) x.num("seed") : 0, octaves(x)));
    });
    def("random", (ref CallArgs a) {
        // random(lo, hi, seed: 7): uniform between lo and hi (lengths, angles or plain numbers),
        // the next of the seed's stream: the same numbers, in the same order, at every run
        auto x = Args(it, a, "random", ["lo", "hi", "seed"]);
        auto lo = x.has("lo") ? x.get("lo") : Value.number(0), hi = x.has("hi") ? x.get("hi") : Value.number(1);
        if (!lo.isNum || !hi.isNum || lo.n.dim != hi.n.dim)
            throw new HcadError(Code.units, "random(lo, hi): two numbers of the same kind (lengths, angles or plain)", a.span);
        immutable seed = x.has("seed") ? cast(long) x.num("seed") : 0;
        auto state = seed in it.randomStreams;
        if (state is null)
        {
            it.randomStreams[seed] = cast(ulong) seed * 0x9E3779B97F4A7C15UL + 0xD1B54A32D192ED03UL;
            state = seed in it.randomStreams;
        }
        // xorshift64*: 53 bits of it make a double in 0…1
        *state ^= *state >> 12;
        *state ^= *state << 25;
        *state ^= *state >> 27;
        immutable u = ((*state * 0x2545F4914F6CDD1DUL) >> 11) * (1.0 / (1UL << 53));
        return Value.number(lo.n.value + (hi.n.value - lo.n.value) * u, lo.n.dim);
    });
    def("loopNoise", (ref CallArgs a) {
        // loopNoise(around, along, bumps: 6): round a loop (0…1), no seam where it closes
        import hackerscad.geom.noise : loopNoise;
        auto x = Args(it, a, "loopNoise", ["around", "along", "bumps", "seed", "kind", "octaves"]);
        return Value.number(loopNoise(x.num("around"), x.has("along") ? plainOrMm(x.get("along"), "along", x.spanOf("along")) : 0,
            x.has("bumps") ? x.num("bumps") : 4, x.has("seed") ? cast(long) x.num("seed") : 0, noiseKind(x), octaves(x)));
    });

    def("min", (ref CallArgs a) => extreme(it, a, "min", false));
    def("max", (ref CallArgs a) => extreme(it, a, "max", true));
    def("minElement", (ref CallArgs a) => extreme(it, a, "minElement", false));
    def("maxElement", (ref CallArgs a) => extreme(it, a, "maxElement", true));
    def("clamp", (ref CallArgs a) {
        auto x = Args(it, a, "clamp", ["value", "lo", "hi"]);
        auto v = x.get("value"), lo = x.get("lo"), hi = x.get("hi");
        if (it.applyBinary(Tok.gt, lo, hi, a.span).truthy)
            throw new HcadError(Code.type, format("clamp: lo (%s) is above hi (%s)", lo, hi), a.span);
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
            if (call1(it, f, v, a.span).condition(a.span))
                r ~= v;
        // what the list holds, kept when nothing is left: its .sum still an empty solid
        auto kept = Value.of(r);
        kept.holds = a.positional[0].holds;
        if (kept.holds == ElemHint.none && xs.length && xs.all!(v => v.kind == Kind.solid))
            kept.holds = xs[0].solid.flat ? ElemHint.profile : ElemHint.solid;
        return kept;
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
        {
            // an empty Solid[] adds up to an empty solid (as fuse([]) does), an empty Profile[] to an
            // empty profile; a list of no declared type to 0
            if (a.positional[0].holds == ElemHint.none)
                return Value.integer(0);
            auto e = new SolidVal(null, a.span);
            e.flat = a.positional[0].holds == ElemHint.profile;
            return Value.of(e);
        }
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
            if (call1(it, f, v, a.span).condition(a.span))
                return Value.of(true);
        return Value.of(false);
    });
    def("all", (ref CallArgs a) {
        auto xs = arrayArg(a, 0, "all");
        auto f = fnArg(a, 1, "all", "x => condition");
        foreach (v; xs)
            if (!call1(it, f, v, a.span).condition(a.span))
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
            if (call1(it, f, v, a.span).condition(a.span))
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
            if (needle.isCallable ? call1(it, needle, v, a.span).condition(a.span) : it.applyBinary(Tok.eq, v, needle, a.span).truthy)
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
                : call2(it, less, x, y, a.span).condition(a.span))(xs);
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
            auto xs = arrayArg(a, i, "cartesianProduct");
            if (xs.length && acc.length > it.limits.arrayLength / xs.length)
                throw new HcadError(Code.limit, format("cartesianProduct would give more than %s pairs", it.limits.arrayLength), a.span);
            foreach (prefix; acc)
                foreach (v; xs)
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

    // round(x) on numbers, p.round(r) on profiles: the profile one replaced
    // the math one under the same name
    {
        auto profileRound = env.vars["round"].bi.impl;
        def("round", (ref CallArgs a) => a.positional.length && a.positional[0].isNum
            ? whole(a, "round", x => round(x)) : profileRound(a));
    }
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
        if (r1 < 0 || r2 < 0)
            throw new HcadError(Code.type, "cone radii must not be negative", a.span);
        if (max(r1, r2) <= 0)
            throw new HcadError(Code.type, "a cone needs a radius greater than zero at one end at least", a.span);
        // a point too small for the kernel is a point
        if (r1 < 1e-6 * r2) r1 = 0;
        if (r2 < 1e-6 * r1) r2 = 0;
        immutable shift = Vec3(0, 0, x.flag("center", false) ? -h / 2 : 0);
        if (abs(r1 - r2) <= 1e-9 * max(r1, r2))   // equal radii: a cylinder
            return solid(k.translate(k.cylinder(r1, h), shift), "cone", a.span);
        return solid(k.translate(k.cone(r1, r2, h), shift), "cone", a.span);
    });
    def("torus", (ref CallArgs a) {
        // torus(major, minor): round Z, centred on the origin; major from the axis
        // to the middle of the tube, minor the tube's radius
        auto x = Args(it, a, "torus", ["major", "minor"]);
        immutable major = x.len("major"), minor = x.len("minor");
        positive(a, [major, minor], "torus radius");
        if (minor >= major)
            throw new HcadError(Code.type, "a torus's tube (minor) must be thinner than its ring (major)", x.spanOf("minor"));
        return solid(k.torus(major, minor), "torus", a.span);
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
    def("push", (ref CallArgs a) {
        // push(from: p | plane | axis, by: 5.mm): moved away from it, from its centre of mass
        auto x = Args(it, a, "push", ["solid", "from", "by"]);
        auto s = x.solid("solid");
        immutable v = pushOffset(it, x, "from", s, x.len("by"), a.span);
        return transformed(it, a.span, s, b => k.translate(b, v));
    });
    def("pull", (ref CallArgs a) {
        // pull(to: p | plane | axis, by: 5.mm): moved towards it, the opposite of push
        auto x = Args(it, a, "pull", ["solid", "to", "by"]);
        auto s = x.solid("solid");
        immutable v = pushOffset(it, x, "to", s, -x.len("by"), a.span);
        return transformed(it, a.span, s, b => k.translate(b, v));
    });
    def("across", (ref CallArgs a) {
        // profile.across(X): stood up across X, as extrude(along: X) stands it
        // (its x along Y, its y up Z), to place and loft or extrude where it is
        auto x = Args(it, a, "across", ["profile", "axis"]);
        auto p = x.solid("profile");
        if (!p.flat)
            throw new HcadError(Code.type, "across stands a profile up; a solid turns with rotate", x.spanOf("profile"));
        auto d = x.dir("axis");
        immutable alongX = abs(d[0] - 1) < 1e-9, alongY = abs(d[1] - 1) < 1e-9;
        if (!alongX && !alongY)
            throw new HcadError(Code.type, "across: X or Y (the profile's x along Y or X, its y up Z)", x.spanOf("axis"));
        return transformed(it, a.span, p, (Brep b) {
            b = k.rotate(b, Vec3(1, 0, 0), PI / 2);
            return alongX ? k.rotate(b, Vec3(0, 0, 1), PI / 2) : b;
        });
    });
    def("rotate", (ref CallArgs a) {
        // rotate(x:, y:, z:) Euler angles, or rotate(angle, axis:) around a
        // direction (through the origin) or an Axis (through its own origin);
        // around: a point the rotation turns about instead of the origin
        auto x = Args(it, a, "rotate", ["solid", "angle", "axis", "x", "y", "z", "around"]);
        auto s = x.solid("solid");
        foreach (n; ["x", "y", "z"])
            if (x.has("angle") && x.has(n))
                throw new HcadError(Code.unknownArg, format("rotate takes an angle (and an axis:), or x:, y:, z:, not "
                    ~ "both: '%s' would be ignored", n), x.spanOf(n));
        if (x.has("axis") && !x.has("angle"))
            throw new HcadError(Code.missingArg, "rotate(axis: …) needs the angle too: rotate(90.deg, axis: X)",
                x.spanOf("axis"));
        if (x.has("angle"))
        {
            Vec3 o, d = Vec3(0, 0, 1);
            if (x.has("axis"))
                axisArg(x, "axis", o, d);
            if (x.has("around"))
                o = x.vecLen("around");
            immutable ang = x.angle("angle");
            return transformed(it, a.span, s, b => k.translate(k.rotate(k.translate(b, -o), d, ang), o));
        }
        // Euler angles applied around X, then Y, then Z
        immutable rx = x.angleOr("x", 0), ry = x.angleOr("y", 0), rz = x.angleOr("z", 0);
        immutable c = x.has("around") ? x.vecLen("around") : Vec3(0, 0, 0);
        return transformed(it, a.span, s, (Brep b) {
            b = k.translate(b, -c);
            if (rx != 0) b = k.rotate(b, Vec3(1, 0, 0), rx);
            if (ry != 0) b = k.rotate(b, Vec3(0, 1, 0), ry);
            if (rz != 0) b = k.rotate(b, Vec3(0, 0, 1), rz);
            return k.translate(b, c);
        });
    });
    def("scale", (ref CallArgs a) {
        // scale(k) the same way along every axis; scale(x: 2, y: 0.5) a factor
        // each (the ones not given stay 1): an ellipsoid from a sphere;
        // around: the point that stays where it is instead of the origin
        auto x = Args(it, a, "scale", ["solid", "factor", "x", "y", "z", "around"]);
        auto s = x.solid("solid");
        if (x.has("factor") && (x.has("x") || x.has("y") || x.has("z")))
            throw new HcadError(Code.type, "scale takes one factor, or x:, y:, z:, not both", x.spanOf("factor"));
        immutable f = x.has("factor") ? x.num("factor") : 1.0;
        immutable sx = x.has("x") ? x.num("x") : f, sy = x.has("y") ? x.num("y") : f, sz = x.has("z") ? x.num("z") : f;
        foreach (k_, v; ["factor": f, "x": sx, "y": sy, "z": sz])
            if (v <= 0)
                throw new HcadError(Code.type, "scale factors must be positive", x.has(k_) ? x.spanOf(k_) : a.span);
        immutable c = x.has("around") ? x.vecLen("around") : Vec3(0, 0, 0);
        if (sx == sy && sy == sz)
            return transformed(it, a.span, s, b => k.translate(k.scale(k.translate(b, -c), sx), c));
        return transformed(it, a.span, s, b => k.translate(k.scaleXyz(k.translate(b, -c), sx, sy, sz), c));
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
        r.tags = s.tags;
        r.faceTags = s.faceTags;
        r.anchors = s.anchors;
        r.edgeTags = s.edgeTags;
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
        if (!(r > 0))
            throw new HcadError(Code.type, "the fillet radius r must be greater than 0", x.spanOf("r"));
        auto idx = resolveSelector(it, sel, s, x.spanOf("edges"));
        return edgeFeature(it, a, s, idx, "fillet", "r", r, (b, e, v) => k.fillet(b, e, v));
    });
    def("chamfer", (ref CallArgs a) {
        auto x = Args(it, a, "chamfer", ["solid", "edges", "d"]);
        auto s = x.solid("solid");
        auto sel = x.selector("edges", false);
        immutable d = x.len("d");
        if (!(d > 0))
            throw new HcadError(Code.type, "the chamfer size d must be greater than 0", x.spanOf("d"));
        auto idx = resolveSelector(it, sel, s, x.spanOf("edges"));
        return edgeFeature(it, a, s, idx, "chamfer", "d", d, (b, e, v) => k.chamfer(b, e, v));
    });
    def("shell", (ref CallArgs a) {
        auto x = Args(it, a, "shell", ["solid", "open", "thickness"]);
        auto s = x.solid("solid");
        auto sel = x.selector("open", true);
        immutable t = x.len("thickness");
        if (!(t > 0))
            throw new HcadError(Code.type, "the wall thickness must be greater than 0", x.spanOf("thickness"));
        auto idx = resolveSelector(it, sel, s, x.spanOf("open"));
        if (s.brep !is null)
        {
            if (idx.length >= k.faceCount(s.brep))
                throw new HcadError(Code.type, "every face is open: nothing would be left to make the walls of",
                    x.spanOf("open"));
            auto size = k.bbox(s.brep).size;
            immutable thinnest = min(size.x, size.y, size.z);
            // (an open side needs one wall across, a closed one two: the kernel says the rest)
            if (t >= thinnest)
                throw new HcadError(Code.type, format("a wall of %g mm leaves nothing inside a part %g mm thin", t,
                    thinnest), x.spanOf("thickness"));
        }
        return transformed(it, a.span, s, b => k.shell(b, idx, t), "shell");
    });

    // placement relative to another solid
    def("nextTo", (ref CallArgs a) {
        auto x = Args(it, a, "nextTo", ["solid", "other", "dir", "gap"]);
        auto s = x.solid("solid"), o = x.solid("other");
        auto d = x.has("dir") ? x.dir("dir") : Vec3(1, 0, 0);
        immutable gap = x.lenOr("gap", 0);
        auto bs = k.bbox(nonEmpty(s, a.span)), bo = k.bbox(nonEmpty(o, a.span));
        if (d.length < 1e-12)
            throw new HcadError(Code.type, "nextTo needs a direction, not a zero vector", x.spanOf("dir"));
        d = d.normalized;
        // its centre on the line from the other's centre that way, as near as the boxes go without
        // overlapping (touching), then gap further along it; across the axes the direction does not
        // go along it stays where it is (along X: only its x changes, its box just past the other's)
        double t = double.infinity;
        foreach (axis; 0 .. 3)
            if (abs(comp(d, axis)) > 1e-9)
                t = min(t, (comp(bs.size, axis) + comp(bo.size, axis)) / 2 / abs(comp(d, axis)));
        Vec3 shift;
        foreach (axis; 0 .. 3)
            if (abs(comp(d, axis)) > 1e-9)
                shift = shift + axisVec(axis) * (comp(bo.center, axis) + comp(d, axis) * (t + gap) - comp(bs.center, axis));
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
        if (n > 1 && step.length == 0)
            throw new HcadError(Code.type, "a step of zero puts every copy in the same place", x.spanOf("step"));
        Value[] copies;
        foreach (i; 0 .. n)
            copies ~= transformed(it, a.span, s, b => k.translate(b, step * i));
        return firstCopyAnchors(unionAll(it, copies, a.span), s);
    });
    def("circularPattern", (ref CallArgs a) {
        auto x = Args(it, a, "circularPattern", ["solid", "n", "axis", "angle"]);
        auto s = x.solid("solid");
        immutable n = count(x, "n");
        Vec3 o, axis = Vec3(0, 0, 1);
        if (x.has("axis"))
            axisArg(x, "axis", o, axis);
        immutable total = x.angleOr("angle", 2 * PI);
        if (n > 1 && abs(total) < 1e-9)
            throw new HcadError(Code.type, "an angle of 0 puts every copy in the same place", x.spanOf("angle"));
        // a full turn (either way, or several) spaces n copies evenly; a
        // partial arc includes both ends
        immutable turns = total / (2 * PI);
        immutable full = abs(turns - round(turns)) < 1e-9 / (2 * PI);
        immutable step = full ? (total > 0 ? 2 * PI : -2 * PI) / n : n > 1 ? total / (n - 1) : 0;
        Value[] copies;
        foreach (i; 0 .. n)
            copies ~= transformed(it, a.span, s, b => k.translate(k.rotate(k.translate(b, -o), axis, step * i), o));
        return firstCopyAnchors(unionAll(it, copies, a.span), s);
    });

    def("draft", (ref CallArgs a) {
        // s.draft(faces.filter(f => f.isPerpendicular(Z) == false), angle: 2.deg, pull: Z, neutral: 0.mm)
        auto x = Args(it, a, "draft", ["solid", "faces", "angle", "pull", "neutral"]);
        auto s = x.solid("solid");
        auto sel = x.selector("faces", true);
        immutable ang = x.angle("angle");
        if (ang == 0 || !(abs(ang) < PI / 2 - 1e-9))
            throw new HcadError(Code.type, "the draft angle goes from 0 to 90° (either way), both excluded",
                x.spanOf("angle"));
        auto pull = x.has("pull") ? x.dir("pull") : Vec3(0, 0, 1);
        auto point = pull * x.lenOr("neutral", 0);
        auto idx = resolveSelector(it, sel, s, x.spanOf("faces"));
        try
            return transformed(it, a.span, s, b => k.draft(b, idx, ang, pull, point), "draft");
        catch (KernelException e)
            throw new HcadError(Code.kernel, "the kernel could not draft these faces", a.span,
                "a smaller angle (a few degrees, as moulds use), or fewer faces at a time");
    });

    // ---- files: parts made elsewhere, inside the project directory only
    def("load", (ref CallArgs a) {
        // load("part.stl", scale: 1): STL, OBJ, PLY, 3MF and glTF (mesh; STL, OBJ and PLY in mm, glTF from metres, Z up)
        // or STEP (exact B-rep);
        // load("logo.svg") and load("plate.dxf"): the drawing's closed outlines, a profile on XY
        import std.file : exists, read, readText, isFile;
        import std.path : buildNormalizedPath, absolutePath, extension, dirName;
        import std.string : toLower;
        import hackerscad.io.meshread;

        auto x = Args(it, a, "load", ["path", "scale", "repair"]);
        immutable repair = x.flag("repair", false);
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
        // the same file, unchanged, with the same kernel: what it gave last
        // time (reading and checking a large mesh takes most of a second)
        import std.file : timeLastModified, getSize;
        immutable cacheKey = format("%s|%s|%s|%s|%s", cast(void*) k, file, timeLastModified(file).stdTime, getSize(file),
            repair);
        synchronized (loadCacheLock)
            if (auto cached = cacheKey in loadCache)
                b = *cached;
        if (b is null)
        try
        {
            switch (ext)
            {
            case ".step", ".stp":
                b = k.readStep(file);
                break;
            case ".svg", ".dxf":
                {
                    import hackerscad.io.outlines : readSvg, readDxf, OutlineException;
                    import hackerscad.lang.convex : profileOfLoops;
                    import hackerscad.io.outlines : Round;
                    try
                    {
                        // whole circles and ellipses as the curves they are
                        Round[] rounds;
                        auto loops = ext == ".svg" ? readSvg(readText(file), rounds) : readDxf(readText(file), rounds);
                        b = profileOfLoops(k, loops, x.spanOf("path"), rounds);
                    }
                    catch (OutlineException e)
                        throw new HcadError(Code.import_, e.msg, x.spanOf("path"));
                    break;
                }
            case ".stl", ".obj", ".ply", ".3mf", ".glb", ".gltf":
                {
                    // a glTF's buffers in files of their own: next to it, inside the project too
                    const(ubyte)[] beside(string uri)
                    {
                        import std.uri : decodeComponent;
                        auto f = buildNormalizedPath(absolutePath(decodeComponent(uri), dirName(file)));
                        if (!f.startsWith(root ~ "/") || !exists(f) || !isFile(f))
                            throw new MeshFormatException("the glTF buffer " ~ uri ~ " is not a file inside the project");
                        return cast(const(ubyte)[]) read(f);
                    }
                    auto mesh = ext == ".stl" ? readStl(cast(ubyte[]) read(file))
                        : ext == ".obj" ? readObj(readText(file))
                        : ext == ".ply" ? readPly(cast(ubyte[]) read(file))
                        : ext == ".glb" ? readGlb(cast(ubyte[]) read(file), &beside)
                        : ext == ".gltf" ? readGltf(readText(file), null, &beside) : read3mf(cast(ubyte[]) read(file));
                    // mended where it is not quite a solid: doubled walls out, the sheets that touch parted
                    if (repair && !mesh.isClosed)
                        mesh = mesh.repaired;
                    if (!mesh.isClosed)
                    {
                        // repair: true offered for what it mends, not tried: on a large mesh it takes a while
                        bool mendable;
                        immutable what = openness(mesh, mendable);
                        throw new HcadError(Code.kernel, "the mesh in " ~ p.s ~ " is not a closed solid: " ~ what,
                            x.spanOf("path"), !repair && mendable ? "try load(\"" ~ p.s ~ "\", repair: true): it takes out "
                            ~ "the doubled walls and parts the sheets that touch (holes it leaves)"
                            : (repair ? "what repair: true left needs " : "it needs ")
                            ~ "mending in MeshLab or Blender (fill holes, make it manifold)");
                    }
                    b = k.fromMesh(mesh);
                    break;
                }
            default:
                throw new HcadError(Code.import_, format("unsupported file type '%s' (use .stl, .obj, .ply, .3mf, .glb, .gltf, .step, .stp, .svg or .dxf)", ext),
                    x.spanOf("path"));
            }
        }
        catch (MeshFormatException e)
            throw new HcadError(Code.import_, e.msg, x.spanOf("path"));
        synchronized (loadCacheLock)
        {
            // a few files at a time: a model loads one or two
            if (loadCache.length >= 16 && cacheKey !in loadCache)
                loadCache.clear();
            loadCache[cacheKey] = b;
        }
        // a STEP file's names of its faces (what hackerscad writes: their tags, ";" between)
        string[][] named;
        foreach (i, n; k.faceNames(b))
        {
            import std.string : split, strip;
            if (named.length == 0)
                named = new string[][k.faceNames(b).length];
            foreach (t; n.split(";"))
                if (t.strip.length)
                    named[i] = tagUnion(named[i], [t.strip]);
        }
        if (x.has("scale"))
        {
            immutable f = x.num("scale");
            if (f <= 0)
                throw new HcadError(Code.type, "scale must be positive", x.spanOf("scale"));
            b = k.scale(b, f);
        }
        auto r = primitive(it, b, "load", a.span);
        if (named.length == k.faceCount(b))
            r.faceTags = named;
        r.flat = ext == ".svg" || ext == ".dxf";
        return Value.of(r);
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

    // rect, circle, ellipse, slot, teardrop and the regular polygon are the profiles of one-shape
    // sketches with everything given: sketchval.d builds them, with the sketch's own methods
    def("polygon", (ref CallArgs a) {
        // polygon([vec(0, 0), vec(30, 0), vec(0, 20)]) or [[0, 0], [30, 0], [0, 20]];
        // smooth: true, a smooth closed curve through the points instead of straight sides.
        // polygon(6, d: 10.mm), polygon(c, 6, d: 10.mm): a regular one, a sketch's shape
        import hackerscad.lang.sketchval : shapeParams, shapeProfile;
        if (shapeParams("polygon", a, 0)[0] != "points")
            return shapeProfile(it, a, "polygon");
        auto x = Args(it, a, "polygon", ["points", "smooth"]);
        auto pts = x.get("points");
        if (pts.kind != Kind.array || pts.arr.length < 3)
            throw new HcadError(Code.type, "polygon needs an array of at least 3 points", x.spanOf("points"));
        double[] xy;
        foreach (p; pts.arr)
        {
            auto v = p.kind == Kind.array ? arrayToVec(it, p.arr, a.caller, x.spanOf("points")) : p;
            if (v.kind != Kind.vec)
                throw new HcadError(Code.type, format("polygon points must be vectors, not %s", v.typeName), x.spanOf("points"));
            if (v.v.dim != Dim.none && v.v.dim != Dim.length)
                throw new HcadError(Code.units, format("polygon points are lengths, not %s", v.typeName), x.spanOf("points"));
            immutable f = v.v.dim == Dim.none ? x.unitFactor : 1;
            if (v.v.v.z != 0)
                throw new HcadError(Code.type, "polygon points lie on XY (z = 0): place the profile afterwards with "
                    ~ "move, rotate or placeOn", x.spanOf("points"));
            if (!isFinite(v.v.v.x) || !isFinite(v.v.v.y))
                throw new HcadError(Code.type, "polygon points must be finite numbers", x.spanOf("points"));
            xy ~= [v.v.v.x * f, v.v.v.y * f];
        }
        if (x.flag("smooth", false))
            return flat(k.splineProfile(xy), "polygon", a.span);
        polygonCheck(xy, x.spanOf("points"));
        return flat(k.polygon(xy), "polygon", a.span);
    });
    def("tiles", (ref CallArgs a) => tilesOf(it, a));
    def("knurl", (ref CallArgs a) => knurlOf(it, a));
    def("text", (ref CallArgs a) {
        // text("hello", size: 10.mm, font: "Sans"): a text outline starting at the
        // origin on its baseline
        if (a.positional.length > 1 || (a.positional.length == 1 && a.positional[0].kind != Kind.str))
            throw new HcadError(Code.type, "text(\"…\", size:, font:) makes a 2D text profile; to build strings use "
                ~ "\"… $(value) …\" or ~", a.span);
        auto x = Args(it, a, "text", ["text", "size", "font", "weight", "bold", "italic", "spacing", "lineSpacing"]);
        auto t = x.get("text");
        if (t.kind != Kind.str || t.s.length == 0)
            throw new HcadError(Code.type, "text needs a non-empty string", x.spanOf("text"));
        auto font = x.has("font") ? x.get("font").s : "Sans";
        immutable size = x.lenOr("size", 10);
        // fonts give no outline below a few hundredths of a millimetre
        if (!(size >= 0.01))
            throw new HcadError(Code.type, format("the text size must be at least 0.01 mm, not %g mm", size),
                x.has("size") ? x.spanOf("size") : a.span);
        immutable spacing = x.lenOr("spacing", 0);
        immutable lineSpacing = x.has("lineSpacing") ? x.num("lineSpacing") : 1.0;
        if (!(lineSpacing > 0))
            throw new HcadError(Code.type, format("lineSpacing is how many times the font's own distance "
                ~ "between lines: more than 0, not %g", lineSpacing), x.spanOf("lineSpacing"));
        // the weight: weight: "light" or 300, bold: true; a style said in the font's name ("Sans Bold")
        // counts as well
        int weight = 0;
        if (x.has("weight"))
            weight = fontWeight(x.get("weight"), x.spanOf("weight"));
        if (x.has("bold"))
        {
            if (weight)
                throw new HcadError(Code.type, "give bold: or weight:, not both (bold: true is weight: \"bold\")",
                    x.spanOf("bold"));
            weight = x.flag("bold", false) ? 700 : 400;
        }
        bool italic = x.flag("italic", false);
        auto fontSpan = x.has("font") ? x.spanOf("font") : a.span;
        if (font.canFind('/') || font.canFind('\\'))
            return flat(k.text(t.s, size, font, 0, spacing, lineSpacing), "text", a.span);
        auto f = textFont(it, font, weight, italic, fontSpan);
        return flat(k.text(t.s, size, f.family, f.style, spacing, lineSpacing), "text", a.span);
    });
    def("round", (ref CallArgs a) {
        auto x = Args(it, a, "round", ["profile", "r"]);
        auto p = profileArg(x, "profile");
        immutable r = x.len("r");
        if (!(r > 0))
            throw new HcadError(Code.type, "the rounding radius r must be greater than 0", x.spanOf("r"));
        return Value.of(flatResult(transformed(it, a.span, p, b => k.profileRound(b, r), "round")));
    });
    def("extrude", (ref CallArgs a) {
        // profile.extrude(10.mm, taper: 2.deg, symmetric: true), or
        // body.extrude(profile, on: frame, depth: 5.mm) to add material on a face
        if (a.positional.length && a.positional[0].kind == Kind.solid && !a.positional[0].solid.flat)
            return pushesFace(a) ? pushFace(it, a, false) : onFace(it, a, false);
        auto x = Args(it, a, "extrude", ["profile", "height", "taper", "symmetric", "twist", "along", "shear"]);
        auto p = profileArg(x, "profile");
        immutable h = x.len("height"), taper = x.angleOr("taper", 0), twist = x.angleOr("twist", 0);
        if (abs(h) < 1e-9)
            throw new HcadError(Code.type, "the height must not be zero", x.spanOf("height"));
        immutable sym = x.flag("symmetric", false);
        if (twist != 0 && taper != 0)
            throw new HcadError(Code.type, "an extrusion is either twisted or tapered, not both", x.spanOf("twist"));
        // shear: vec(dx, dy), the top moved that much from the bottom, in the profile's own x and y: an oblique prism
        double sx = 0, sy = 0;
        if (x.has("shear"))
        {
            auto v = x.vecLen("shear");
            if (abs(v.z) > 1e-12)
                throw new HcadError(Code.type, "shear: is how far the top moves sideways, vec(dx, dy): the height "
                    ~ "is the extrusion's", x.spanOf("shear"));
            if (taper != 0 || twist != 0)
                throw new HcadError(Code.type, "an extrusion is sheared, tapered or twisted: one of them",
                    x.spanOf("shear"));
            sx = v.x;
            sy = v.y;
        }
        // along: X or Y, the profile stood up across that axis and pushed along it
        int along = 2;
        if (x.has("along"))
        {
            auto d = x.dir("along");
            foreach (i; 0 .. 3)
                if (abs(abs(d[i]) - 1) < 1e-9 && d[i] > 0)
                    along = i;
            if (abs(d[along] - 1) > 1e-9)
                throw new HcadError(Code.type, "along: is X, Y or Z (towards -X, a negative height)", x.spanOf("along"));
            if (p.placed)
                throw new HcadError(Code.type, "this profile was drawn on a face or plane: it is extruded across "
                    ~ "it, leave along: out", x.spanOf("along"));
        }
        // a profile that lies in another plane (a section, a profile turned): extruded
        // across that plane, from where it is; on XY or drawn on a face, as it is
        auto base = nonEmpty(p, a.span);
        Vec3[4] tilt;
        immutable tilted = !p.placed && tiltedProfile(it, p, a.span, tilt);
        if (tilted && along != 2)
            throw new HcadError(Code.type, "this profile does not lie on XY: it is extruded across its own plane, "
                ~ "leave along: out", x.spanOf("along"));
        if (tilted)
            base = fromPlace(k, tilt, base);
        // symmetric: the profile is the middle of the solid, as it is (sheared, its top and bottom moved
        // half each way; twisted, turned half each way; tapered, narrowing both ways away from it)
        immutable turn = h < 0 ? -twist : twist;
        if (sym && twist != 0)
            base = k.rotate(base, Vec3(0, 0, 1), -turn / 2);
        // twisted: a sweep up a straight line, the profile turning around Z as it rises
        auto sv = derived(it, twist != 0 ? k.sweep(base, k.polyline([Vec3(0, 0, 0), Vec3(0, 0, h)], false),
            false, turn) : sx != 0 || sy != 0 ? k.extrudeShear(base, h, sx, sy)
            : sym && taper != 0 ? k.boolean(k.extrude(base, h / 2, taper), k.extrude(base, -h / 2, taper), BoolOp.fuse)
            : k.extrude(base, h, taper), [p], "extrude", a.span);
        sv.flat = false;
        sv.placed = false;
        // sheared or twisted, the kernel does not say which side comes from which of the profile's lines:
        // the side standing on each, at the bottom, has its tags
        if (sv.lostEdgeTags.length && p.edgeTags.length)
        {
            auto onBase = carryEdgeTags(k, base, p.edgeTags, sv.brep, 0);
            if (onBase.length)
            {
                auto fs = k.faces(sv.brep);
                if (sv.faceTags.length != fs.length)
                    sv.faceTags = new string[][fs.length];
                foreach (j, pair; k.edgeFaces(sv.brep))
                    if (j < onBase.length && onBase[j].length)
                        foreach (f; pair)
                            if (f >= 0 && f < fs.length && abs(abs(fs[f].normal.z) - 1) > 1e-9)
                                sv.faceTags[f] = tagUnion(sv.faceTags[f], onBase[j]);
                keptEdgeTags(sv);
            }
        }
        // a tilted profile's references lie where it lies: brought onto XY with it, put back below
        if (tilted && sv.anchors.length)
            sv.anchors = mapAnchors(it, (Brep q) => fromPlace(k, tilt, q), sv.anchors, a.span);
        // sheared: a circle's axis leans as its hole does
        if (sx != 0 || sy != 0)
            foreach (ref an; sv.anchors)
                if (an.kind == AnchorKind.axis && abs(abs(an.z.z) - 1) < 1e-9)
                {
                    an.z = (Vec3(sx, sy, h) * (an.z.z * h > 0 ? 1 : -1)).normalized;
                    an.x = faceXAxis(an.z);
                    an.y = an.z.cross(an.x);
                }
        if (sym && taper == 0)
        {
            // the profile's references stay where it was drawn: halfway up now
            auto kept = sv.anchors;
            sv = transformed(it, a.span, sv, b => k.translate(b, Vec3(-sx / 2, -sy / 2, -h / 2))).solid;
            sv.anchors = kept;
        }
        // along X: the profile's x along Y and its y up Z, pushed towards +X (a turn of
        // 120° about the diagonal); along Y: its x along X and y up Z, towards +Y (Y and Z
        // swapped: a mirror)
        if (along == 0)
            sv = transformed(it, a.span, sv, b => k.rotate(b, Vec3(1, 1, 1).normalized, 2 * PI / 3)).solid;
        else if (along == 1)
            sv = transformed(it, a.span, sv, b => k.mirror(b, Vec3(0, 1, -1).normalized)).solid;
        // a profile drawn on a face, or lying in a plane: the solid stands there
        if (p.placed || tilted)
            return transformed(it, a.span, sv, b => toPlace(k, p.placed ? p.place : tilt, b));
        return Value.of(sv);
    });
    def("thread", (ref CallArgs a) {
        // body.thread(faces.…, "M8"): an ISO metric thread on a cylindrical face, outside a shaft
        // or inside a hole; length:, turns:, pitch:, starts:, left:, clearance:, chamfer:, flip:
        return threadFace(it, a);
    });
    def("cut", (ref CallArgs a) {
        // body.cut(profile, on: frame, depth: 3.mm) or through: true
        return pushesFace(a) ? pushFace(it, a, true) : onFace(it, a, true);
    });
    def("revolve", (ref CallArgs a) {
        // profile.revolve(axis: Y, angle: 360.deg): the axis lies in the profile's plane.
        // Without an axis it turns around Y and stands up: the profile's x is
        // the radius and its y the height along Z (pots, bottles, knobs).
        auto x = Args(it, a, "revolve", ["profile", "axis", "angle"]);
        auto p = profileArg(x, "profile");
        // a profile drawn on a face or plane, or lying in one: turned in that plane's coordinates and
        // put back there; an axis given is the world's, as everything else in that plane (a direction
        // alone, X or Z, through the plane's origin: the sketch's, or where the plane is nearest the world's)
        Vec3[4] frame;
        immutable lies = liesOf(it, p, a.span, frame);
        Vec3 o, d = Vec3(0, 1, 0);
        immutable upright = !x.has("axis");
        if (!upright)
        {
            axisArg(x, "axis", o, d);
            if (lies != Lies.onXY)
            {
                if (!isAxis(x.get("axis")))
                    o = frame[0];
                auto w = o - frame[0];
                o = Vec3(w.dot(frame[1]), w.dot(frame[2]), w.dot(frame[3]));
                d = Vec3(d.dot(frame[1]), d.dot(frame[2]), d.dot(frame[3]));
            }
        }
        // standing in a plane whose y goes up (sketch(XZ), a section across Y, a wall's face): turned round
        // that y, as it stands (a half section through Z turns round Z)
        immutable standing = lies != Lies.onXY && frame[2].z > 1 - 1e-9;
        immutable ang = x.angleOr("angle", 2 * PI);
        if (!(abs(ang) > 1e-9 && abs(ang) <= 2 * PI + 1e-9))
            throw new HcadError(Code.type, "a revolve turns by more than 0° and at most 360° (either way)",
                x.has("angle") ? x.spanOf("angle") : a.span);
        auto local = lies == Lies.tilted ? fromPlace(k, frame, p.brep) : nonEmpty(p, a.span);
        Brep b;
        try
            b = k.revolve(local, o, d, max(-2 * PI, min(2 * PI, ang)));
        catch (KernelException e)
            throw new HcadError(Code.kernel, e.msg, a.span, lies != Lies.onXY && !upright
                ? "this profile lies in a plane of its own: the axis is a world one (X, Y, Z or an Axis) lying in "
                ~ "that plane (for one drawn on XZ, Z or X)" : null);
        auto sv = derived(it, b, [p], "revolve", a.span);
        sv.flat = false;
        sv.placed = false;
        // stood up and placed after: as a transform, so the faces keep the tags of the
        // profile's lines they were turned from
        if (!upright && lies == Lies.onXY)
            return Value.of(sv);
        // a tilted profile's references lie where it lies: brought into its plane's coordinates with it
        if (lies == Lies.tilted && sv.anchors.length)
            sv.anchors = mapAnchors(it, (Brep q) => fromPlace(k, frame, q), sv.anchors, a.span);
        immutable stand = upright && !standing;
        return transformed(it, a.span, sv, (Brep s) {
            if (stand)
                s = k.rotate(s, Vec3(1, 0, 0), PI / 2);
            return lies != Lies.onXY ? toPlace(k, frame, s) : s;
        });
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
        // bend: 5.mm rounds every corner with an arc of that radius, as a bent tube
        if (a.positional.length && a.positional[0].kind == Kind.solid && !a.positional[0].solid.path)
        {
            // body.path(edges.loop(faces.top)): edges of a solid joined end to end
            auto y = Args(it, a, "path", ["solid", "edges"]);
            auto s = y.solid("solid");
            auto idx = resolveSelector(it, y.selector("edges", false), s, y.spanOf("edges"));
            Brep b;
            try
                b = k.edgesPath(s.brep, idx);
            catch (KernelException e)
                throw new HcadError(Code.kernel, e.msg, y.spanOf("edges"), "select edges that follow one another: "
                    ~ "edges.loop(faces…), edges.chain(…)");
            if (s.flat && s.placed)
                b = toPlace(k, s.place, b);
            return pathValue(b, "path", a.span);
        }
        if (a.positional.length == 2 && a.positional[0].kind == Kind.solid && a.positional[0].solid.path)
        {
            // path(top, side): the curve in space that looks like one path seen across its plane, and like
            // the other across its own (a handle drawn from above and from the side)
            auto y = Args(it, a, "path", ["a", "b"]);
            SolidVal pathOf(string n)
            {
                auto v = y.get(n);
                if (v.kind != Kind.solid || !v.solid.path)
                    throw new HcadError(Code.type, format("path(a, b) takes two paths, each drawn in a plane, not %s",
                        v.typeName), y.spanOf(n));
                return v.solid;
            }
            auto pa = pathOf("a"), pb = pathOf("b");
            if (pa.pathNormal.length > 0 && pb.pathNormal.length > 0 && abs(pa.pathNormal.dot(pb.pathNormal)) > 1 - 1e-9)
                throw new HcadError(Code.type, "the two paths are drawn in parallel planes: they are the same view; "
                    ~ "draw them in two planes at an angle (XY and XZ)", a.span);
            // both views must cover the same stretch of the line they share (the X of a top view and of a
            // front one): else the curve is quietly only where they overlap
            if (pa.pathNormal.length > 0 && pb.pathNormal.length > 0)
            {
                immutable shared_ = pa.pathNormal.cross(pb.pathNormal).normalized;
                double[2] along(SolidVal v)
                {
                    auto bb = k.bbox(v.brep);
                    double lo = double.infinity, hi = -double.infinity;
                    foreach (i; 0 .. 8)
                    {
                        immutable c = Vec3(i & 1 ? bb.max.x : bb.min.x, i & 2 ? bb.max.y : bb.min.y, i & 4 ? bb.max.z : bb.min.z);
                        lo = min(lo, c.dot(shared_));
                        hi = max(hi, c.dot(shared_));
                    }
                    // a box's own tolerance (1e-7) is no stretch: printed, -1e-07 would puzzle
                    double snap(double v) => abs(v) < 1e-6 ? 0 : v;
                    return [snap(lo), snap(hi)];
                }
                immutable ra = along(pa), rb = along(pb);
                immutable tol = 0.02 * max(ra[1] - ra[0], rb[1] - rb[0]) + 1e-3;
                if (abs(ra[0] - rb[0]) > tol || abs(ra[1] - rb[1]) > tol)
                    throw new HcadError(Code.type, format("the two views cover different stretches of the line they "
                        ~ "share: %.4g to %.4g mm and %.4g to %.4g mm; draw both over the same one", ra[0], ra[1], rb[0],
                        rb[1]), a.span);
            }
            try
                return pathValue(k.projectedCurve(pa.brep, pb.brep, pa.pathNormal, pb.pathNormal), "path", a.span);
            catch (KernelException e)
                throw new HcadError(Code.kernel, e.msg, a.span, "draw both views over the same stretch: what one "
                    ~ "covers along the line they share, the other must cover too; a straight path's plane is known "
                    ~ "only when drawn in a sketch (s.path)");
        }
        auto x = Args(it, a, "path", ["points", "closed", "bend"]);
        auto pts = points(x, "points", 2);
        immutable closed = x.flag("closed", false);
        immutable bend = x.lenOr("bend", 0);
        if (bend < 0)
            throw new HcadError(Code.type, "bend is a radius: it must be positive", x.spanOf("bend"));
        if (bend == 0)
            return pathValue(k.polyline(pts, closed), "path", a.span);
        return pathValue(k.pathOfPieces(bentPath(pts, closed, bend, x.spanOf("bend"))), "path", a.span);
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
    def("isoThread", (ref CallArgs a) {
        // isoThread(d: 8.mm, pitch: 1.25.mm, length: 20.mm, chamfer: 0.68.mm): an ISO metric thread, right-handed,
        // standing on z = 0 (the threads library's threadedRod and tappedHole are made of it)
        auto x = Args(it, a, "isoThread", ["d", "pitch", "length", "chamfer"]);
        immutable d = x.len("d"), p = x.len("pitch"), l = x.len("length"), c = x.lenOr("chamfer", 0);
        positive(a, [d, p, l], "isoThread sizes");
        if (p * 0.5413 * 2 >= d)
            throw new HcadError(Code.type, "the pitch is too coarse for that diameter: the thread would reach the axis",
                x.spanOf("pitch"));
        Brep b;
        try
            b = k.isoThread(d, p, l, c);
        catch (KernelException e)
            throw new HcadError(Code.kernel, e.msg, a.span);
        return Value.of(primitive(it, b, "thread", a.span));
    });
    def("sweep", (ref CallArgs a) {
        // circle(d: 4.mm).sweep(path): the profile, drawn on XY around the origin, starts
        // at the beginning of the path and normal to it, its +Y kept towards world +Z;
        // how it turns about the path on the way: as little as it can, or frenet: true (the
        // curvature), twist: 360.deg (once, evenly; or t => angle, 0 to 1 along it), up: Z
        // (its +Y towards Z all along), guide: rail (its +Y towards that path)
        // a curve (a Path on XY) instead of a profile: swept, a Surface
        auto x = Args(it, a, "sweep", ["profile", "path", "frenet", "twist", "up", "guide"]);
        immutable open = x.get("profile").kind == Kind.solid && x.get("profile").solid.path;
        SolidVal p;
        if (open)
        {
            p = x.get("profile").solid;
            auto bb = k.bbox(nonEmpty(p, a.span));
            if (abs(bb.min.z) > 1e-6 || abs(bb.max.z) > 1e-6)
                throw new HcadError(Code.type, "a curve swept into a surface is drawn on XY around the origin, as a "
                    ~ "profile is (path([vec(-5, 0), vec(5, 0)]))", x.spanOf("profile"));
        }
        else
            p = profileArg(x, "profile");
        SolidVal pathOf(string n)
        {
            auto pv = x.get(n);
            if (pv.kind != Kind.solid || !pv.solid.path)
                throw new HcadError(Code.type, format("'%s' must be a Path (path, spline, helix), not %s", n, pv.typeName),
                    x.spanOf(n));
            return pv.solid;
        }
        auto route = pathOf("path");
        immutable frenet = x.flag("frenet", false);
        string[] ways;
        foreach (n; ["frenet", "twist", "up", "guide"])
            if (x.has(n) && (n != "frenet" || frenet))
                ways ~= n;
        if (ways.length > 1)
            throw new HcadError(Code.type, format("%s and %s both decide how the profile turns about the path: give one",
                ways[0], ways[1]), x.spanOf(ways[1]));
        // a profile reaching further from the path than its tightest bend folds through itself there:
        // OpenCascade may still call the solid valid, or fail to build it
        double reach = 0, tightest = double.infinity;
        if (!open)
        {
            // how far the outline gets from the origin: line ends, circles whole (arcs counted whole too)
            foreach (e; k.edges(p.brep))
            {
                double far(Vec3 q) => sqrt(q.x * q.x + q.y * q.y);
                if (e.kind == EdgeKind.circle)
                    reach = max(reach, far(e.center) + e.radius);
                else
                    reach = max(reach, max(far(e.start), far(e.end), far(e.mid)));
            }
            Vec3[] pts, tans;
            k.pathSample(route.brep, 400, pts, tans);
            auto turns = new double[pts.length];
            turns[0] = 0;
            foreach (i; 1 .. pts.length)
                turns[i] = acos(min(1.0, max(-1.0, tans[i - 1].dot(tans[i]))));
            foreach (i; 1 .. pts.length)
            {
                // a sharp corner (mitred) is not a bend: it turns all at once, between two
                // samples, where a bend turns over the samples beside them too
                immutable before = turns[i - 1], after = i + 1 < pts.length ? turns[i + 1] : 0;
                if (turns[i] > 1e-9 && turns[i] < PI / 9 && max(before, after) > 0.1 * turns[i])
                    tightest = min(tightest, (pts[i] - pts[i - 1]).length / turns[i]);
            }
        }
        immutable folds = reach > tightest * 1.001;
        Brep made;
        try
        {
            if (x.has("twist") && x.get("twist").isCallable)
            {
                // a roll that varies along the path: the function at 65 places from 0 (the start) to 1 (the end)
                auto f = x.get("twist");
                double[] angles;
                foreach (i; 0 .. 65)
                {
                    auto v = call1(it, f, Value.number(i / 64.0), x.spanOf("twist"));
                    if (!v.isNum || (v.n.dim != Dim.angle && v.n.dim != Dim.none))
                        throw new HcadError(Code.units, format("twist: t => … must give an Angle, not %s", v.typeName),
                            x.spanOf("twist"));
                    angles ~= v.n.dim == Dim.angle ? v.n.value : v.n.value * PI / 180;
                }
                // the turn is counted from the start: f(0) is where the profile starts, unturned
                made = k.sweepRoll(nonEmpty(p, a.span), route.brep, angles, Vec3(0, 0, 0), null);
            }
            else if (x.has("up"))
                made = k.sweepRoll(nonEmpty(p, a.span), route.brep, null, x.dir("up"), null);
            else if (x.has("guide"))
                made = k.sweepRoll(nonEmpty(p, a.span), route.brep, null, Vec3(0, 0, 0), pathOf("guide").brep);
            else
                made = k.sweep(nonEmpty(p, a.span), route.brep, frenet, x.angleOr("twist", 0));
        }
        catch (KernelException e)
            throw new HcadError(Code.kernel, e.msg, a.span, folds ? format("the profile reaches %.3g mm from the "
                ~ "path, more than its tightest bend's radius (%.3g mm): a smaller profile or a wider bend", reach,
                tightest) : null);
        if (folds)
            it.diagnostics ~= Diagnostic(Severity.warning, Code.kernel, format("the profile reaches %.3g mm from "
                ~ "the path, more than its tightest bend's radius (%.3g mm): the sweep folds through itself there; "
                ~ "a smaller profile or a wider bend", reach, tightest), a.span);
        auto sv = derived(it, made, [p], "sweep", a.span);
        sv.flat = false;
        sv.placed = false;
        sv.path = false;
        sv.surface = open;
        // the profile's references where it starts: at the path's start, across it, its +Y towards
        // world +Z (+Y when the path starts vertical), up: or the guide's start, as the kernel places it
        if (sv.anchors.length)
        {
            Vec3 o, t;
            k.pathFrame(route.brep, false, o, t);
            auto up = abs(t.z) > 0.999 ? Vec3(0, 1, 0) : Vec3(0, 0, 1);
            if (x.has("up"))
                up = x.dir("up");
            else if (x.has("guide"))
            {
                Vec3 g, gt;
                k.pathFrame(pathOf("guide").brep, false, g, gt);
                up = g - o;
            }
            auto y = (up - t * up.dot(t)).normalized;
            Vec3[4] start = [o, y.cross(t), y, t];
            sv.anchors = mapAnchors(it, (Brep q) => toPlace(k, start, q), sv.anchors, a.span);
        }
        return Value.of(sv);
    });
    def("loft", (ref CallArgs a) {
        // loft([circle(r: 20), rect(30).move(z: 40), circle(r: 10).move(z: 80)]): a solid through
        // profiles placed in space; ruled: true gives flat sides between them
        auto x = Args(it, a, "loft", ["profiles", "ruled", "inside"]);
        auto v = x.get("profiles");
        if (v.kind != Kind.array || v.arr.length < 2)
            throw new HcadError(Code.type, "loft needs an array of at least 2 profiles", x.spanOf("profiles"));
        // rings of points (Vec3[] each, the same count): one smooth surface through every
        // point, closed round each ring, the end rings filled flat; fast where a loft
        // through as many smooth profiles would take seconds
        if (v.arr[0].kind == Kind.array)
        {
            // every ring with `per` points (the first ring's count when 0)
            Vec3[] ringsOf(Value w, string arg, ref size_t per)
            {
                Vec3[] pts;
                if (w.kind != Kind.array || w.arr.length < 2)
                    throw new HcadError(Code.type, "loft through rings of points needs 2 rings at least", x.spanOf(arg));
                foreach (r, ring; w.arr)
                {
                    if (ring.kind != Kind.array || ring.arr.length < 3)
                        throw new HcadError(Code.type, "loft through rings of points: each ring is an array of 3 points or more",
                            x.spanOf(arg));
                    if (per == 0)
                        per = ring.arr.length;
                    else if (ring.arr.length != per)
                        throw new HcadError(Code.type, format("loft through rings of points: a ring has %d points, the first %d; "
                            ~ "give them all the same count", ring.arr.length, per), x.spanOf(arg));
                    foreach (q; ring.arr)
                    {
                        if (q.kind != Kind.vec || (q.v.dim != Dim.length && q.v.dim != Dim.none))
                            throw new HcadError(Code.type, format("loft rings hold points (vec(x, y, z) in mm), not %s", q.typeName),
                                x.spanOf(arg));
                        immutable f = q.v.dim == Dim.none ? x.unitFactor : 1;
                        pts ~= q.v.v * f;
                    }
                }
                return pts;
            }
            size_t per;
            auto pts = ringsOf(v, "profiles", per);
            if (x.flag("ruled", false))
                throw new HcadError(Code.type, "rings of points make a smooth surface: for flat sides, loft polygons with ruled: true",
                    x.spanOf("ruled"));
            // inside: rings for the inner wall: hollow, a floor at the inner first ring, open between the last two
            if (x.has("inside"))
            {
                auto w = x.get("inside");
                auto innerPts = ringsOf(w, "inside", per);
                return Value.of(primitive(it, k.gridHollow(pts, cast(int) v.arr.length, innerPts, cast(int) w.arr.length,
                    cast(int) per), "loft", a.span));
            }
            return Value.of(primitive(it, k.gridSolid(pts, cast(int) v.arr.length, cast(int) per), "loft", a.span));
        }
        Brep[] bs;
        SolidVal[] ins;
        // paths, not profiles: a Surface through them
        if (v.arr.length && v.arr[0].kind == Kind.solid && v.arr[0].solid.path)
        {
            foreach (p; v.arr)
            {
                if (p.kind != Kind.solid || !p.solid.path)
                    throw new HcadError(Code.type, format("a surface through paths takes paths only, not %s", p.typeName),
                        x.spanOf("profiles"));
                bs ~= nonEmpty(p.solid, a.span);
            }
            Brep b;
            try
                b = k.loftOpen(bs, x.flag("ruled", false));
            catch (KernelException e)
                throw new HcadError(Code.kernel, e.msg, a.span);
            auto sv = primitive(it, b, "loft", a.span);
            sv.surface = true;
            sv.loftPaths = bs;
            sv.loftRuled = x.flag("ruled", false);
            return Value.of(sv);
        }
        foreach (p; v.arr)
        {
            if (p.kind != Kind.solid || !p.solid.flat || p.solid.path)
                throw new HcadError(Code.type, format("loft profiles must be 2D profiles, not %s", p.typeName), x.spanOf("profiles"));
            // a profile drawn on a face or plane: there
            bs ~= p.solid.placed ? toPlace(k, p.solid.place, nonEmpty(p.solid, a.span)) : nonEmpty(p.solid, a.span);
            ins ~= p.solid;
        }
        auto sv = derived(it, k.loft(bs, x.flag("ruled", false)), ins, "loft", a.span);
        sv.flat = false;
        sv.placed = false;
        return Value.of(sv);
    });

    // ---- profiles from solids
    def("section", (ref CallArgs a) {
        // s.section(XZ) or s.section(s.plane(faces.top).offset(-2)): the cut, a profile in that plane
        auto x = Args(it, a, "section", ["solid", "plane"]);
        auto s = x.solid("solid");
        if (s.flat || s.path)
            throw new HcadError(Code.type, "section cuts solids: a profile is already flat", a.span);
        Vec3 o, n;
        planeArg(x, "plane", o, n);
        auto r = primitive(it, k.section(nonEmpty(s, a.span), o, n), "section", a.span);
        r.flat = true;
        r.rgb = s.rgb;
        r.hasColor = s.hasColor;
        return Value.of(r);
    });
    def("projection", (ref CallArgs a) {
        // s.projection: the solid's shadow seen from above, a profile on XY;
        // s.projection(XZ): its shadow on that plane, cast along the plane's normal
        auto x = Args(it, a, "projection", ["solid", "plane"]);
        auto s = x.solid("solid");
        if (s.flat || s.path)
            throw new HcadError(Code.type, "projection is of solids: a profile is already flat", a.span);
        import hackerscad.lang.convex : projectionOf, projectionOn;
        Brep shadow;
        if (x.has("plane"))
        {
            Vec3 o, n;
            planeArg(x, "plane", o, n);
            shadow = projectionOn(k, nonEmpty(s, a.span), o, n, a.span);
        }
        else
            shadow = projectionOf(k, nonEmpty(s, a.span), a.span);
        auto r = primitive(it, shadow, "projection", a.span);
        r.flat = true;
        r.rgb = s.rgb;
        r.hasColor = s.hasColor;
        return Value.of(r);
    });

    // ---- mass properties: density in g/cm³ (PLA 1.24, PETG 1.27, ABS 1.04)
    // ---- remodelling: what a mesh is made of
    def("features", (ref CallArgs a) {
        // writeln(load("part.stl").features): its flat faces, holes, shafts, cones, spheres, roundings
        // and patterns of holes, one a line, with plausible sizes
        auto x = Args(it, a, "features", ["solid"]);
        auto s = x.solid("solid");
        if (s.flat || s.path)
            throw new HcadError(Code.type, "features are of solids", a.span);
        import hackerscad.geom.meshfeatures : analyse, report;
        return Value.of(report(analyse(k.tessellate(nonEmpty(s, a.span), 0.01, 0.1))));
    });

    def("aligned", (ref CallArgs a) {
        // load("x.stl").aligned: lying on its largest flat face, its longest extent along X, centred in
        // X and Y on z = 0; a part without flat faces lies along its principal axes
        auto x = Args(it, a, "aligned", ["solid"]);
        auto s = x.solid("solid");
        if (s.flat || s.path)
            throw new HcadError(Code.type, "aligned is for solids", a.span);
        import hackerscad.geom.meshfeatures : analyse, Surface, smallestEigenvector;
        import hackerscad.lang.convex : turnFromZ;
        auto b = nonEmpty(s, a.span);
        auto m = k.tessellate(b, 0.05, 0.3);
        // the turns found, applied again at the end as one transform (its references follow)
        Vec3[] turnAxes;
        double[] turnAngles;
        void turn(Vec3 axis, double angle)
        {
            b = k.rotate(b, axis, angle);
            turnAxes ~= axis;
            turnAngles ~= angle;
        }
        // the face to lie on: the largest flat one, or across the direction the part is thinnest in
        Vec3 down;
        bool found;
        foreach (f; analyse(m).features)
            if (f.kind == Surface.plane)
            {
                down = f.normal;
                found = true;
                break;
            }
        // how the surface's area spreads about its centre: each triangle's exact second moment (its
        // centre alone would pull a box made of two triangles a face towards their diagonals)
        double[3][3] spread(const Mesh mm)
        {
            Vec3 first;
            double total = 0;
            double[3][3] second = 0;
            foreach (t; 0 .. mm.triangleCount)
            {
                Vec3[3] v = [mm.vertex(mm.tris[3 * t]), mm.vertex(mm.tris[3 * t + 1]), mm.vertex(mm.tris[3 * t + 2])];
                immutable area = (v[1] - v[0]).cross(v[2] - v[0]).length / 2;
                auto sum = v[0] + v[1] + v[2];
                first = first + sum * (area / 3);
                total += area;
                // ∫ p pᵀ dA over a triangle: area / 12 · (Σ vᵢ vᵢᵀ + (Σ vᵢ)(Σ vᵢ)ᵀ)
                foreach (r; 0 .. 3)
                    foreach (q; 0 .. 3)
                    {
                        double m = sum[r] * sum[q];
                        foreach (i; 0 .. 3)
                            m += v[i][r] * v[i][q];
                        second[r][q] += area / 12 * m;
                    }
            }
            auto mean = first / total;
            foreach (r; 0 .. 3)
                foreach (q; 0 .. 3)
                    second[r][q] -= total * mean[r] * mean[q];
            return second;
        }
        if (!found)
            down = smallestEigenvector(spread(m));
        // that direction turned to -Z
        Vec3 ax;
        double angle;
        turnFromZ(-down, ax, angle);
        if (angle > 1e-9)
            turn(ax, -angle);
        // turned about Z: the main direction of what it covers along X
        {
            auto c = spread(k.tessellate(b, 0.05, 0.3));
            immutable theta = 0.5 * atan2(2 * c[0][1], c[0][0] - c[1][1]);
            if (abs(theta) > 1e-9)
                turn(Vec3(0, 0, 1), -theta);
        }
        // the spread of the area is seldom exactly along the part's sides (a bracket, a hole off
        // centre): its largest upright flat face, when it has one, is squared to X or Y
        foreach (f; analyse(k.tessellate(b, 0.05, 0.3)).features)
            if (f.kind == Surface.plane && abs(f.normal.z) < 1e-6)
            {
                // its exact normal: the solid's own face lying that way (the mesh's is a little off)
                auto n = f.normal;
                double best = 0;
                foreach (g; k.faces(b))
                    if (g.normal.dot(f.normal) > 0.9999 && g.area > best)
                    {
                        best = g.area;
                        n = g.normal;
                    }
                immutable phi = atan2(n.y, n.x);
                immutable off = phi - PI / 2 * round(phi / (PI / 2));
                if (abs(off) > 1e-12 && abs(off) < PI / 18)
                    turn(Vec3(0, 0, 1), -off);
                break;
            }
        auto bb = k.bbox(b);
        immutable shift = Vec3(-bb.center.x, -bb.center.y, -bb.min.z);
        return transformed(it, a.span, s, (Brep q) {
            foreach (i, axis; turnAxes)
                q = k.rotate(q, axis, turnAngles[i]);
            return k.translate(q, shift);
        }, "aligned", true);
    });
    def("deviation", (ref CallArgs a) {
        // clone.deviation(original): how far apart their surfaces are at most, both ways
        auto x = Args(it, a, "deviation", ["a", "b"]);
        auto sa = x.solid("a"), sb = x.solid("b");
        if (sa.flat || sa.path || sb.flat || sb.path)
            throw new HcadError(Code.type, "deviation compares solids", a.span);
        import hackerscad.geom.deviation : deviation;
        auto ma = k.tessellate(nonEmpty(sa, a.span), 0.01, 0.1), mb = k.tessellate(nonEmpty(sb, a.span), 0.01, 0.1);
        auto bb = k.bbox(sa.brep);
        immutable spacing = max(0.2, bb.size.length / 300);
        return Value.number(max(deviation(ma, mb, spacing).max, deviation(mb, ma, spacing).max), Dim.length);
    });

    // ---- printing: what a printer will find hard
    def("overhangs", (ref CallArgs a) {
        // s.overhangs(45.deg): the area facing down more steeply than the angle from a wall, off the bed
        auto x = Args(it, a, "overhangs", ["solid", "angle"]);
        auto s = x.solid("solid");
        if (s.flat || s.path)
            throw new HcadError(Code.type, "overhangs are of solids", a.span);
        immutable angle = x.angleOr("angle", PI / 4);
        if (!(angle >= 0 && angle < PI / 2))
            throw new HcadError(Code.type, "the overhang angle is from a vertical wall: 0 to 90°", x.spanOf("angle"));
        import hackerscad.geom.printability : checkPrint;
        auto m = k.tessellate(nonEmpty(s, a.span), 0.02, 0.1);
        return Value.number(checkPrint(m.verts, 3, m.tris, angle, 0).overhangArea, Dim.area);
    });
    def("thinWalls", (ref CallArgs a) {
        // s.thinWalls(0.8.mm): the surface over walls thinner than that (0 when there are none)
        auto x = Args(it, a, "thinWalls", ["solid", "min"]);
        auto s = x.solid("solid");
        if (s.flat || s.path)
            throw new HcadError(Code.type, "thin walls are of solids", a.span);
        immutable wall = x.lenOr("min", 0.8);
        if (!(wall > 0))
            throw new HcadError(Code.type, "the thinnest wall must be positive", x.spanOf("min"));
        import hackerscad.geom.printability : checkPrint;
        auto m = k.tessellate(nonEmpty(s, a.span), 0.05, 0.2);
        return Value.number(checkPrint(m.verts, 3, m.tris, PI / 4, wall).thinArea, Dim.area);
    });

    def("mass", (ref CallArgs a) {
        // s.mass(density: 1.24): grams
        auto x = Args(it, a, "mass", ["solid", "density"]);
        auto s = x.solid("solid");
        immutable density = x.num("density");
        if (s.flat || s.path)
            throw new HcadError(Code.type, "mass is of solids", a.span);
        if (density <= 0)
            throw new HcadError(Code.type, "density is in g/cm³ and positive: PLA 1.24, PETG 1.27, ABS 1.04",
                x.spanOf("density"));
        return Value.number(it.kernel.volume(nonEmpty(s, a.span)) * density / 1000);
    });
    def("inertia", (ref CallArgs a) {
        // s.inertia(density: 1.24): the principal moments of inertia about the centre of mass,
        // ascending, in g·mm²
        auto x = Args(it, a, "inertia", ["solid", "density"]);
        auto s = x.solid("solid");
        immutable density = x.num("density");
        if (s.flat || s.path)
            throw new HcadError(Code.type, "inertia is of solids", a.span);
        if (density <= 0)
            throw new HcadError(Code.type, "density is in g/cm³ and positive", x.spanOf("density"));
        auto m = it.kernel.massProps(nonEmpty(s, a.span)).moments;
        return Value.vector(Vec3(m[0], m[1], m[2]) * (density / 1000), 3, Dim.none);
    });

    // ---- convex hulls and Minkowski sums (lang/convex)
    def("hull", (ref CallArgs a) {
        // hull(a, b, …) or hull([a, b, …]): the smallest convex shape around them; grow: that much bigger all round
        import hackerscad.lang.convex : hullOf, grownHullOf, pointsOf;
        double grow = 0;
        foreach (n; a.namedOrder)
        {
            if (n != "grow")
                throw new HcadError(Code.unknownArg, "hull takes the shapes, hull(a, b, …) or hull([a, b, …]), and "
                    ~ "grow:", *(n in a.namedSpans), Interp.suggest(n, ["grow"]));
            auto g = *(n in a.named);
            if (!g.isNum || (g.n.dim != Dim.length && g.n.dim != Dim.none) || g.n.value < 0)
                throw new HcadError(Code.type, "grow: is a length, 0 or more (how much bigger all round)",
                    *(n in a.namedSpans));
            grow = g.n.value;
        }
        SolidVal[] items;
        void add(Value v, Span span)
        {
            if (v.kind == Kind.array)
                foreach (e; v.arr)
                    add(e, span);
            else if (v.kind == Kind.solid && !v.solid.path)
                items ~= v.solid;
            else
                throw new HcadError(Code.type, format("hull takes solids and profiles, not %s", v.typeName), span);
        }
        foreach (i, v; a.positional)
            add(v, i < a.positionalSpans.length ? a.positionalSpans[i] : a.span);
        if (items.length == 0)
            throw new HcadError(Code.arity, "hull needs shapes: hull(a, b) or hull([a, b])", a.span);
        Brep[] bs;
        bool allFlat = true;
        foreach (sv; items)
            allFlat = allFlat && sv.flat;
        // profiles in one plane (a sketch's, a section): their hull stays there, one of no place taken into
        // it; in different planes, a solid round them where they lie
        Lies lies;
        Vec3[4] frame;
        bool onePlane;
        auto inPlane = allFlat ? intoOnePlane(it, items, a.span, lies, frame, onePlane) : null;
        foreach (i, sv; items)
        {
            nonEmpty(sv, a.span);
            bs ~= onePlane ? inPlane[i].brep : sv.placed ? toPlace(k, sv.place, sv.brep) : sv.brep;
        }
        bool flat;
        Brep made;
        if (grow > 0)
        {
            if (allFlat)
                throw new HcadError(Code.type, "grow: is for the hull of solids: grow a profile's with .offset", a.span);
            Vec3[] pts;
            foreach (b; bs)
                pts ~= pointsOf(k, b);
            made = grownHullOf(k, pts, grow, a.span);
        }
        else
            made = hullOf(k, bs, allFlat, a.span, flat);
        auto r = primitive(it, made, "hull", a.span);
        r.flat = flat;
        if (flat && onePlane)
            r = liesAs(r, lies, frame);
        // made anew: the names of the profiles' sketch lines are not handed on
        lostEdgeTagsOf(r, items, "hull");
        r.rgb = items[0].rgb;
        r.hasColor = items[0].hasColor;
        // the flat faces of theirs the hull lies on keep their tags; their references stay where they are
        if (!flat)
        {
            r.tags = items[0].tags;
            foreach (sv; items)
                r.anchors ~= sv.anchors;
            r.anchors = mergeAnchors(r.anchors);
            tagsByPlane(it, r, items, (size_t, Vec3) => 0.0);
        }
        return Value.of(r);
    });
    def("minkowski", (ref CallArgs a) {
        // minkowski(a, b): a moved by every point of b (b a sphere: a with round edges)
        import hackerscad.lang.convex : minkowskiOf;
        auto x = Args(it, a, "minkowski", ["a", "b"]);
        auto sa = x.solid("a"), sb = x.solid("b");
        if (sa.path || sb.path)
            throw new HcadError(Code.type, "minkowski takes solids or profiles, not paths", a.span);
        if (sa.flat != sb.flat)
            throw new HcadError(Code.type, "minkowski takes two solids or two profiles, not one of each", a.span);
        auto r = primitive(it, minkowskiOf(k, nonEmpty(sa, a.span), nonEmpty(sb, a.span), sa.flat, a.span),
            "minkowski", a.span);
        r.flat = sa.flat;
        r.rgb = sa.rgb;
        r.hasColor = sa.hasColor;
        // a's tags and references (b, moving a about, is the tool: a sphere rounding it)
        r.tags = sa.tags;
        r.anchors = sa.anchors.dup;
        // a flat face of either moved out by how far the other reaches that way keeps its tags
        if (!r.flat && (sa.faceTags.length || sb.faceTags.length))
        {
            auto ma = k.tessellate(sa.brep, 0.01, 0.1), mb = k.tessellate(sb.brep, 0.01, 0.1);
            double reach(const Mesh m, Vec3 n)
            {
                double best = -double.infinity;
                foreach (v; 0 .. m.vertexCount)
                    best = max(best, m.vertex(v).dot(n));
                return best;
            }
            // (the reach measured on a fine mesh: its points lie on the surface, a chord's sag inside)
            tagsByPlane(it, r, [sa, sb], (size_t i, Vec3 n) => reach(i == 0 ? mb : ma, n), 0.02);
        }
        return Value.of(r);
    });

    // ---- planes
    def("plane", (ref CallArgs a) {
        // plane(origin: vec(0, 0, 10), normal: Z) or body.plane(faces.top)
        if (a.positional.length == 2 && a.positional[0].kind == Kind.solid && a.positional[1].kind == Kind.str)
        {
            // body.plane("mid"): the plane tagged so
            auto x = Args(it, a, "plane", ["solid", "tag"]);
            return anchorValue(it, x.solid("solid"), tagName(x.get("tag"), x.spanOf("tag")), AnchorKind.plane, x.spanOf("tag"));
        }
        if (a.positional.length && a.positional[0].kind == Kind.solid)
        {
            // body.plane(faces.top, faces.bottom): halfway between two flat faces that face each other
            auto x = Args(it, a, "plane", ["solid", "face", "other"]);
            auto s = x.solid("solid");
            FaceInfo oneFace(string n)
            {
                auto idx = resolveSelector(it, x.selector(n, true), s, x.spanOf(n));
                if (idx.length != 1)
                    throw new HcadError(Code.type, format("plane needs exactly one face, the selector matched %d",
                        idx.length), x.spanOf(n));
                return k.faces(s.brep)[idx[0]];
            }
            auto f = oneFace("face");
            if (!x.has("other"))
                return planeValue(f.center, f.normal);
            auto g = oneFace("other");
            if (abs(abs(f.normal.dot(g.normal)) - 1) > 1e-6)
                throw new HcadError(Code.type, "the two faces are not parallel: no plane lies halfway between them",
                    x.spanOf("other"));
            immutable gap = (g.center - f.center).dot(f.normal);
            return planeValue(f.center + f.normal * (gap / 2), f.normal);
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
        if (a.positional.length == 2 && a.positional[0].kind == Kind.solid && a.positional[1].kind == Kind.str)
        {
            // body.axis("bore"): the axis tagged so (a circle of its sketch: the circle's)
            auto x = Args(it, a, "axis", ["solid", "tag"]);
            return anchorValue(it, x.solid("solid"), tagName(x.get("tag"), x.spanOf("tag")), AnchorKind.axis, x.spanOf("tag"));
        }
        if (a.positional.length == 2 && a.positional[0].kind == Kind.solid && a.positional[1].kind == Kind.selector
            && a.positional[1].sel.faces)
        {
            // body.axis(faces.largest): the axis of a cylinder's, a cone's or a turned face
            auto x = Args(it, a, "axis", ["solid", "face"]);
            auto s = x.solid("solid");
            auto idx = resolveSelector(it, x.selector("face", true), s, x.spanOf("face"));
            if (idx.length != 1)
                throw new HcadError(Code.type, format("axis needs exactly one face, the selector matched %d", idx.length),
                    x.spanOf("face"));
            Vec3 o, d;
            if (!k.faceAxis(s.brep, idx[0], o, d))
                throw new HcadError(Code.type, "only a face turned round an axis (a cylinder, a cone, a revolved face) "
                    ~ "has one; of a flat face, body.frame(…) gives its normal", x.spanOf("face"));
            return axisValue(o, d);
        }
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
        if (a.positional.length == 2 && a.positional[0].kind == Kind.solid && a.positional[1].kind == Kind.str)
        {
            // body.frame("seat"): the frame tagged so (or one on the point, axis or plane tagged so)
            auto y = Args(it, a, "frame", ["solid", "tag"]);
            return anchorValue(it, y.solid("solid"), tagName(y.get("tag"), y.spanOf("tag")), AnchorKind.frame, y.spanOf("tag"));
        }
        if (a.positional.length && a.positional[0].kind == Kind.solid)
        {
            x = Args(it, a, "frame", ["solid", "face", "origin", "x"]);
            auto s = x.solid("solid");
            auto idx = resolveSelector(it, x.selector("face", true), s, x.spanOf("face"));
            if (idx.length != 1)
                throw new HcadError(Code.type, format("frame needs exactly one face, the selector matched %d", idx.length),
                    x.spanOf("face"));
            auto f = flatFace(it, s, idx[0], "frame", x.spanOf("face"));
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
        Vec3 xAxis;
        if (x.has("x"))
        {
            xAxis = inPlane(x.dir("x"), n);
            if (xAxis.length < 1e-9)
                throw new HcadError(Code.type, "the x direction is perpendicular to the plane", x.spanOf("x"));
            xAxis = xAxis.normalized;
        }
        else
            xAxis = faceXAxis(n);
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
        // or onto a plane (its origin, X projected on it); from: a face of the
        // solid (or a frame) laid against it instead, at: a point of that face
        auto x = Args(it, a, "placeOn", ["solid", "frame", "from", "at"]);
        auto s = x.solid("solid");
        Vec3 o, ax, ay, az;
        auto v = x.get("frame");
        if (v.kind == Kind.struct_ && v.st.def is planeDef)
        {
            planeArg(x, "frame", o, az);
            ax = faceXAxis(az);
            ay = az.cross(ax);
        }
        else
            frameArg(x, "frame", o, ax, ay, az);
        if (x.has("at") && !x.has("from"))
            throw new HcadError(Code.type, "at: is a point of the from: face", x.spanOf("at"));
        // the frame carried onto it: the world's (XY, Z up), or one on the solid's
        // face, outwards, turned to face into the target (X kept, Y and Z reversed)
        Vec3 fo = Vec3(0, 0, 0), fx = Vec3(1, 0, 0), fy = Vec3(0, 1, 0), fz = Vec3(0, 0, 1);
        if (x.has("from"))
        {
            auto f = x.get("from");
            if (f.kind == Kind.selector)
            {
                auto idx = resolveSelector(it, x.selector("from", true), s, x.spanOf("from"));
                if (idx.length != 1)
                    throw new HcadError(Code.type, format("from: needs exactly one face, the selector matched %d",
                        idx.length), x.spanOf("from"));
                auto face = flatFace(it, s, idx[0], "placeOn", x.spanOf("from"));
                fo = face.center;
                fz = face.normal;
                fx = faceXAxis(fz);
                fy = fz.cross(fx);
            }
            else
                frameArg(x, "from", fo, fx, fy, fz);
            if (x.has("at"))
            {
                auto q = x.vecLen("at");
                fo = q - fz * (q - fo).dot(fz);
            }
            fy = fy * -1;
            fz = fz * -1;
        }
        // the turn taking fx, fy, fz to ax, ay, az: its columns, the world axes turned
        Vec3 col(Vec3 e) => ax * fx.dot(e) + ay * fy.dot(e) + az * fz.dot(e);
        Vec3 axis;
        immutable angle = axisAngle(col(Vec3(1, 0, 0)), col(Vec3(0, 1, 0)), col(Vec3(0, 0, 1)), axis);
        immutable shift = o - col(Vec3(1, 0, 0)) * fo.x - col(Vec3(0, 1, 0)) * fo.y - col(Vec3(0, 0, 1)) * fo.z;
        return transformed(it, a.span, s, (Brep b) {
            if (angle > 1e-12)
                b = k.rotate(b, axis, angle);
            return k.translate(b, shift);
        });
    });

    def("offset", (ref CallArgs a) {
        // profile.offset(d) grows or shrinks a profile, solid.offset(d) a solid (round where it
        // turns); plane.offset(d) is a parallel plane
        if (a.positional.length && a.positional[0].kind == Kind.solid && !a.positional[0].solid.flat
            && !a.positional[0].solid.path)
        {
            auto x = Args(it, a, "offset", ["solid", "distance", "sharp"]);
            auto s = x.solid("solid");
            immutable d = x.len("distance");
            // sharp: the faces moved and extended to meet, no rounds (quicker on many faces: a hull)
            immutable sharp = x.flag("sharp", false);
            // no distance: the solid as it is (the kernel cannot offset by nothing)
            if (abs(d) < 1e-6)
                return Value.of(s);
            // a hole closing up (grown by its radius or more) makes the kernel fail, or turn the hole's
            // wall inside out: grown, the solid covers the hole all the same, so those holes are filled first
            Brep filled = s.brep;
            double closes = 0, smallest = double.infinity;
            if (d > 0 && s.brep !is null)
                foreach (f; 0 .. k.faceCount(s.brep))
                {
                    CylinderInfo c;
                    if (!k.faceCylinder(s.brep, cast(int) f, c) || c.outside)
                        continue;
                    smallest = min(smallest, c.radius);
                    if (c.radius > d)
                        continue;
                    closes = max(closes, c.radius);
                    import hackerscad.lang.convex : turnFromZ;
                    Vec3 turnAxis;
                    double turn;
                    turnFromZ(c.axis.normalized, turnAxis, turn);
                    auto plug = k.cylinder(c.radius, c.to - c.from);
                    if (turn > 1e-12)
                        plug = k.rotate(plug, turnAxis, turn);
                    try
                        filled = k.boolean(filled, k.translate(plug, c.origin + c.axis.normalized * c.from), BoolOp.fuse);
                    catch (KernelException)
                    {
                    }
                }
            try
                return transformed(it, a.span, s, b => k.offset(filled is s.brep ? b : filled, d, sharp), "offset");
            catch (KernelException e)
                throw new HcadError(Code.kernel, e.msg, a.span, closes > 0
                    ? format("the holes of ⌀%g mm and less close up at this distance (filled first, it still fails): "
                        ~ "try a smaller distance", 2 * closes)
                    : smallest < double.infinity ? format("a hole of ⌀%g mm closes up when grown by %g mm or more",
                        2 * smallest, smallest) : null);
        }
        if (a.positional.length && a.positional[0].kind == Kind.solid)
        {
            auto x = Args(it, a, "offset", ["profile", "distance"]);
            auto p = profileArg(x, "profile");
            immutable d = x.len("distance");
            auto r = flatResult(transformed(it, a.span, p, b => k.profileOffset(b, d), "offset"));
            // shrunk away: an empty profile, where it lay
            if (r.brep !is null && k.faceCount(r.brep) == 0)
                r.brep = null;
            // a line offset is the parallel side, a circle the one round the same centre: their tags kept
            if (p.edgeTags.length && r.brep !is null)
            {
                r.edgeTags = carryEdgeTags(k, p.brep, p.edgeTags, r.brep, d, r.edgeTags);
                keptEdgeTags(r);
            }
            return Value.of(r);
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
    // s.halves(plane): the two sides of a cut, .above where the normal points, .below the other
    Value[2] cutSides(ref CallArgs a, string name)
    {
        auto x = Args(it, a, name, ["solid", "plane"]);
        auto s = x.solid("solid");
        Vec3 o, n;
        planeArg(x, "plane", o, n);
        auto half = halfSpace(it, nonEmpty(s, a.span), o, n, a.span);
        Value[2] sides = [solidBoolean(it, s, half, BoolOp.common, a.span), solidBoolean(it, s, half, BoolOp.cut, a.span)];
        // each reference to the side it lies on (both, on the cut)
        if (s.anchors.length)
        {
            SolidVal[] both;
            foreach (ref side; sides)
                if (side.kind == Kind.solid)
                {
                    // the copy of s an empty side may be is not s
                    if (side.solid is s)
                        side = Value.of(copySolid(s));
                    both ~= side.solid;
                }
            shareAnchors(it, s.anchors, both);
        }
        return sides;
    }
    // surface.thicken(2.mm): made a solid that thick, on the side its normals point (negative: the other side)
    // fill(path, through: […]): a smooth face closing a closed path, a Surface; body.fill(edges…,
    // tangent: faces…) the same on a loop of a solid's edges, meeting the faces given smoothly
    def("fill", (ref CallArgs a) {
        immutable onBody = a.positional.length && a.positional[0].kind == Kind.solid && !a.positional[0].solid.path
            && !a.positional[0].solid.flat;
        auto x = onBody ? Args(it, a, "fill", ["solid", "edges", "through", "tangent"])
            : Args(it, a, "fill", ["path", "through"]);
        Vec3[] pts;
        if (x.has("through"))
        {
            auto v = x.get("through");
            if (v.kind != Kind.array)
                throw new HcadError(Code.type, "through: is a list of points: [vec(0.mm, 0.mm, 12.mm)]", x.spanOf("through"));
            foreach (p; v.arr)
            {
                auto q = p.kind == Kind.array ? arrayToVec(it, p.arr, a.caller, x.spanOf("through")) : p;
                if (q.kind != Kind.vec || (q.v.dim != Dim.none && q.v.dim != Dim.length))
                    throw new HcadError(Code.type, format("through: takes points (vectors of lengths), not %s", q.typeName),
                        x.spanOf("through"));
                pts ~= q.v.v * (q.v.dim == Dim.none ? x.unitFactor : 1);
            }
        }
        Brep b;
        SolidVal[] from;
        try
        {
            if (onBody)
            {
                auto body = x.solid("solid");
                auto bb = nonEmpty(body, a.span);
                auto es = resolveSelector(it, x.selector("edges", false), body, x.spanOf("edges"));
                if (es.length == 0)
                    throw new HcadError(Code.type, "the selector matched no edges", x.spanOf("edges"));
                int[] fs;
                if (x.has("tangent"))
                    fs = resolveSelector(it, x.selector("tangent", true), body, x.spanOf("tangent"));
                b = k.fill(null, bb, es.map!(e => cast(int) e).array, fs, pts);
                from = [body];
            }
            else
            {
                auto v = x.get("path");
                if (v.kind != Kind.solid || !v.solid.path)
                    throw new HcadError(Code.type, format("fill closes a closed Path (or a loop of a solid's edges: "
                        ~ "body.fill(edges.loop(…))), not %s", v.typeName), x.spanOf("path"));
                b = k.fill(nonEmpty(v.solid, a.span), null, null, null, pts);
                from = [v.solid];
            }
        }
        catch (KernelException e)
            throw new HcadError(Code.kernel, e.msg, a.span);
        auto sv = derived(it, b, from, "fill", a.span);
        sv.flat = false;
        sv.path = false;
        sv.placed = false;
        sv.surface = true;
        return Value.of(sv);
    });
    def("thicken", (ref CallArgs a) {
        auto x = Args(it, a, "thicken", ["surface", "thickness"]);
        auto s = x.solid("surface");
        if (!s.surface)
            throw new HcadError(Code.type, format("thicken makes a Surface a solid, not a %s: a solid grows with offset",
                x.get("surface").typeName), x.spanOf("surface"));
        immutable t = x.len("thickness");
        if (t == 0)
            throw new HcadError(Code.type, "thicken by 0 leaves no solid", x.spanOf("thickness"));
        Brep b;
        try
            b = k.thicken(nonEmpty(s, a.span), t);
        catch (KernelException e)
        {
            // a loft through closed paths, where sharp and smooth edges meet: built from the paths
            if (s.loftPaths.length < 2)
                throw new HcadError(Code.kernel, e.msg, a.span);
            try
                b = k.thickenLoft(s.loftPaths, s.loftRuled, t);
            catch (KernelException e2)
                throw new HcadError(Code.kernel, e.msg ~ "; nor from its paths: " ~ e2.msg, a.span);
        }
        auto sv = derived(it, b, [s], "thicken", a.span);
        sv.surface = false;
        return Value.of(sv);
    });
    // sew([a, b, c]): surfaces that close round a space, joined along their edges into one solid
    def("sew", (ref CallArgs a) {
        auto x = Args(it, a, "sew", ["surfaces"]);
        auto v = x.get("surfaces");
        if (v.kind != Kind.array || v.arr.length == 0)
            throw new HcadError(Code.type, "sew takes an array of surfaces: sew([a, b, c])", x.spanOf("surfaces"));
        Brep[] bs;
        SolidVal[] ins;
        foreach (q; v.arr)
        {
            if (q.kind != Kind.solid || q.solid.path || !q.solid.flat && !q.solid.surface)
                throw new HcadError(Code.type, format("sew joins surfaces and flat profiles (to close their ends), not %s",
                    q.typeName), x.spanOf("surfaces"));
            bs ~= q.solid.placed ? toPlace(k, q.solid.place, nonEmpty(q.solid, a.span)) : nonEmpty(q.solid, a.span);
            ins ~= q.solid;
        }
        Brep b;
        try
            b = k.sew(bs, 1e-4);
        catch (KernelException e)
            throw new HcadError(Code.kernel, e.msg, a.span, "the surfaces must meet edge to edge all round");
        auto sv = derived(it, b, ins, "sew", a.span);
        sv.surface = false;
        sv.flat = false;
        sv.placed = false;
        return Value.of(sv);
    });
    def("halves", (ref CallArgs a) {
        auto sides = cutSides(a, "halves");
        // a copy: sides lives on this call's stack
        return Value.make(Kind.struct_, StructVal(halvesDef, sides[].dup));
    });
    // s.split(plane): the pieces the cut leaves, both sides, along X, then Y, then Z
    def("split", (ref CallArgs a) {
        // s.split(surface): the pieces a surface (or a solid) cuts it into
        if (a.positional.length > 1 && a.positional[1].kind == Kind.solid)
        {
            auto x = Args(it, a, "split", ["solid", "by"]);
            auto s = x.solid("solid");
            auto tool = x.get("by").solid;
            if (tool.path || tool.flat)
                throw new HcadError(Code.type, format("split cuts with a Plane, a Surface or a Solid, not a %s",
                    x.get("by").typeName), x.spanOf("by"));
            Brep cut;
            try
                cut = k.splitBy(nonEmpty(s, a.span), nonEmpty(tool, a.span));
            catch (KernelException e)
                throw new HcadError(Code.kernel, e.msg, a.span);
            auto all = piecesOf(it, derived(it, cut, [s, tool], "split", a.span), a.span);
            foreach (q; all)
                q.surface = false;
            sortPieces(it, all);
            Value[] r;
            foreach (q; all)
                r ~= Value.of(q);
            return Value.of(r);
        }
        auto sides = cutSides(a, "split");
        SolidVal[] all;
        foreach (side; sides)
            if (side.kind == Kind.solid && side.solid.brep !is null)
                all ~= piecesOf(it, side.solid, a.span);
        sortPieces(it, all);
        Value[] r;
        foreach (p; all)
            r ~= Value.of(p);
        return Value.of(r);
    });
}

/// What writeln shows of a value: a shape with a short summary (its size, and
/// its volume, area or length: all cheap, nothing meshed), a selection taken
/// from a solid with how many it selects; the rest as toString writes it.
string shown(Interp it, Value v, Span span)
{
    static string g(double x) => format("%.4g", abs(x) < 1e-9 ? 0 : x);
    switch (v.kind)
    {
    case Kind.array:
        return "[" ~ v.arr.map!(x => x.kind == Kind.str ? `"` ~ x.s ~ `"` : shown(it, x, span)).join(", ") ~ "]";
    case Kind.selector:
        if (v.sel.of is null || v.sel.of.brep is null)
            return v.toString;
        return format("%s (%d)", v.toString, resolveSelector(it, v.sel, v.sel.of, span, true).length);
    case Kind.solid:
        {
            auto s = v.solid;
            if (s.brep is null)
                return v.toString;
            auto k = it.kernel;
            immutable z = k.bbox(s.brep).size;
            immutable size = s.flat && !s.placed ? format("%s × %s mm", g(z.x), g(z.y))
                : format("%s × %s × %s mm", g(z.x), g(z.y), g(z.z));
            if (s.path)
            {
                double l = 0;
                foreach (e; k.edges(s.brep))
                    l += e.length;
                Vec3 a, b, ta, tb;
                k.pathFrame(s.brep, false, a, ta);
                k.pathFrame(s.brep, true, b, tb);
                return format("Path %s mm long, %s", g(l), (a - b).length < 1e-6 ? "closed" : "open");
            }
            if (s.flat)
                return format("Profile %s, area %s mm²", size, g(k.area(s.brep)));
            if (s.surface)
                return format("Surface %s, area %s mm²", size, g(k.area(s.brep)));
            return format("Solid %s, volume %s mm³", size, g(k.volume(s.brep)));
        }
    default:
        return v.toString;
    }
}

/// `n` frames evenly along path `s` by length, ends included: origin, X, Y,
/// Z, with Z along the path. They turn as little as a frame can while
/// following it (rotation-minimising, by double reflection), so profiles
/// placed on them do not twist round the path; on a closed path what twist
/// is left is spread evenly, so the last matches the first. A closed path
/// has no end: there the n frames are a length/n apart all round, the start
/// not repeated.
Vec3[4][] pathFrames(Interp it, SolidVal s, int n)
{
    import std.math : atan2;
    Vec3 from, to, t0, t1;
    it.kernel.pathFrame(s.brep, false, from, t0);
    it.kernel.pathFrame(s.brep, true, to, t1);
    immutable loop = (from - to).length < 1e-6;
    immutable wanted = n;
    if (loop)
        n++;   // the last one is the first again: computed (it closes the spread), not given
    Vec3[] p, t;
    it.kernel.pathSample(s.brep, n, p, t);
    Vec3[4][] r;
    // the first X: across the path, level when it can be
    auto z0 = t[0].normalized;
    auto x0 = (abs(z0.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)).cross(z0).normalized;
    Vec3[] xs = [x0];
    foreach (i; 0 .. n - 1)
    {
        auto v1 = p[i + 1] - p[i];
        immutable c1 = v1.dot(v1);
        if (c1 < 1e-18)
        {
            xs ~= xs[i];
            continue;
        }
        auto rL = xs[i] - v1 * (2 / c1 * v1.dot(xs[i]));
        auto tL = t[i] - v1 * (2 / c1 * v1.dot(t[i]));
        auto v2 = t[i + 1] - tL;
        immutable c2 = v2.dot(v2);
        auto x1 = c2 < 1e-18 ? rL : rL - v2 * (2 / c2 * v2.dot(rL));
        // kept square to the tangent against rounding
        xs ~= (x1 - t[i + 1] * x1.dot(t[i + 1])).normalized;
    }
    // closed: the turn left between the last X and the first, spread along
    double spread = 0;
    if ((p[0] - p[$ - 1]).length < 1e-6 && n > 2)
    {
        auto a = xs[0], b = xs[$ - 1], tz = t[$ - 1].normalized;
        spread = atan2(tz.dot(b.cross(a)), b.dot(a));
    }
    foreach (i; 0 .. n)
    {
        auto z = t[i].normalized, x = xs[i];
        if (spread != 0)
        {
            // turn X about Z by its share of the spread
            immutable g = spread * i / (n - 1), c = cos(g), sn = sin(g);
            x = x * c + z.cross(x) * sn + z * (z.dot(x) * (1 - c));
        }
        r ~= [p[i], x, z.cross(x), z];
    }
    return r[0 .. wanted];
}

/// What `outline(n)` gives for each point: where it is, its outward
/// normal (smoothed over corners) and how far round the outline (0…1).
StructDef outlinePointDef()
{
    __gshared StructDef def;
    if (def is null)
    {
        def = new StructDef;
        def.name = "OutlinePoint";
        foreach (f; [["at", "Vec2"], ["normal", "Vec2"], ["around", "double"]])
        {
            auto t = new TypeRef;
            t.name = f[1];
            def.fields ~= StructDef.FieldInfo(f[0], t, null);
        }
    }
    return def;
}

/// `n` points evenly spaced round the outer outline of profile `s`,
/// counter-clockwise from its point nearest +X: each with its outward normal,
/// taken across a little stretch either side so it turns smoothly round a
/// corner (a texture pushed out along it does not cross itself there), and
/// its share of the way round.
Value[] outlinePoints(Interp it, SolidVal s, size_t n, Span span, double round = 0)
{
    import std.math : atan2;
    // a profile in a plane (drawn on a face, a section): taken round in that plane, given where it lies
    Lies lies;
    Vec3[4] frame;
    auto local = localOf(it, s, span, lies, frame);
    auto loops = it.kernel.faceLoops(local, 0, 0.01);
    if (loops.length == 0)
        throw new HcadError(Code.kernel, "this profile has no outline", span);
    // the outer loop: the largest area; counter-clockwise
    double areaOf(Vec3[] l)
    {
        double a = 0;
        foreach (i; 0 .. l.length)
            a += l[i].x * l[(i + 1) % l.length].y - l[(i + 1) % l.length].x * l[i].y;
        return a / 2;
    }
    auto loop = loops[0];
    foreach (l; loops[1 .. $])
        if (abs(areaOf(l)) > abs(areaOf(loop)))
            loop = l;
    loop = loop.dup;
    if (loop.length > 1 && (loop[0] - loop[$ - 1]).length < 1e-9)
        loop = loop[0 .. $ - 1];
    if (areaOf(loop) < 0)
    {
        import std.algorithm : reverse;
        reverse(loop);
    }
    // lengths along it
    double[] at = [0];
    foreach (i; 0 .. loop.length)
        at ~= at[$ - 1] + (loop[(i + 1) % loop.length] - loop[i]).length;
    immutable per = at[$ - 1];
    // start where a line from the middle towards +X meets the outline: the
    // same place whatever the outline's own first point (a stable start)
    Vec3 mid = Vec3(0, 0, 0);
    foreach (p; loop)
        mid = mid + p;
    mid = mid * (1.0 / loop.length);
    double start = 0, nearest = double.infinity;
    foreach (i; 0 .. loop.length)
    {
        auto a = loop[i] - mid, b = loop[(i + 1) % loop.length] - mid;
        if ((a.y <= 0) == (b.y <= 0) || a.y == b.y)
            continue;
        immutable f = -a.y / (b.y - a.y), x = a.x + (b.x - a.x) * f;
        if (x > 0 && x < nearest)
        {
            nearest = x;
            start = at[i] + (at[i + 1] - at[i]) * f;
        }
    }
    Vec3 pointAt(double d)
    {
        while (d < 0)
            d += per;
        while (d >= per)
            d -= per;
        size_t lo = 0, hi = loop.length;
        while (hi - lo > 1)
        {
            immutable m = (lo + hi) / 2;
            if (at[m] <= d)
                lo = m;
            else
                hi = m;
        }
        immutable len = at[lo + 1] - at[lo];
        immutable f = len > 0 ? (d - at[lo]) / len : 0;
        return loop[lo] + (loop[(lo + 1) % loop.length] - loop[lo]) * f;
    }
    // the normal across a stretch either side (the spacing, or a quarter round of
    // a fillet `round` big): corners turn smoothly, an inward push under `round` keeps clear
    immutable step = per / n, reach = max(step * 1.5, round * PI / 2);
    Value[] r;
    foreach (i; 0 .. n)
    {
        immutable d = start + per * i / n;
        auto p = pointAt(d);
        auto tangent = pointAt(d + reach) - pointAt(d - reach);
        auto normal = Vec3(tangent.y, -tangent.x, 0).normalized;
        immutable here = Vec3(p.x, p.y, 0);
        if (lies != Lies.onXY)
            r ~= Value.make(Kind.struct_, StructVal(outlinePointDef, [Value.vector(worldOf(frame, here), 3, Dim.length),
                Value.vector(frame[1] * normal.x + frame[2] * normal.y, 3, Dim.none), Value.number(cast(double) i / n)]));
        else
            r ~= Value.make(Kind.struct_, StructVal(outlinePointDef, [Value.vector(here, 2, Dim.length),
                Value.vector(normal, 2, Dim.none), Value.number(cast(double) i / n)]));
    }
    return r;
}

/// What a list of solids has (`s.pieces.below(p)`, `.largest`, `.top`):
/// which of them lie where.
bool solidsMember(Interp it, Value[] xs, string name, Span span, out Value result, Value delegate(BuiltinImpl) method)
{
    auto k = it.kernel;
    Vec3 centre(Value v) => v.solid.brep is null ? Vec3(0, 0, 0) : k.massProps(v.solid.brep).centroid;
    Value one(string what, bool delegate(Value, Value) better)
    {
        if (xs.length == 0)
            throw new HcadError(Code.index, format("%s of an empty list: no solid to choose", what), span);
        auto best = xs[0];
        foreach (v; xs[1 .. $])
            if (better(v, best))
                best = v;
        return best;
    }
    // the solids on the normal's side of a plane (by their centre of mass), or cut by it
    Value side(string what, int want)
    {
        return method((ref CallArgs a) {
            // the receiver is the first argument: no plane after it is the old split(p).above
            if (a.positional.length + a.named.length < 2)
                throw new HcadError(Code.arity, format("%s(plane) chooses among solids: say which plane. For the two "
                    ~ "sides of a cut, s.halves(plane).%s; s.split(plane) gives the pieces", what, what == "crossing" ? "above" : what), span);
            auto x = Args(it, a, what, ["list", "plane"]);
            Vec3 o, n;
            planeArg(x, "plane", o, n);
            Value[] r;
            foreach (v; xs)
            {
                if (v.solid.brep is null)
                    continue;
                bool keep;
                if (want == 0)
                {
                    // both sides keep something: the plane goes through it
                    keep = !k.boolean(v.solid.brep, sideBox(k, v.solid.brep, o, n), BoolOp.cut).isEmptyBrep(k)
                        && !k.boolean(v.solid.brep, sideBox(k, v.solid.brep, o, n * -1), BoolOp.cut).isEmptyBrep(k);
                }
                else
                    keep = (centre(v) - o).dot(n) * want > 0;
                if (keep)
                    r ~= v;
            }
            return Value.of(r);
        });
    }
    switch (name)
    {
    case "push", "pull":
        {
            // each solid moved away from (push) or towards (pull) a point, a plane or an axis, along
            // the line from it to the solid's centre of mass: pieces of a cut spread apart
            immutable away = name == "push";
            result = method((ref CallArgs a) {
                auto x = Args(it, a, name, ["list", away ? "from" : "to", "by"]);
                immutable by = away ? x.len("by") : -x.len("by");
                Value[] r;
                foreach (v; xs)
                {
                    if (v.solid.brep is null)
                    {
                        r ~= v;
                        continue;
                    }
                    immutable off = pushOffset(it, x, away ? "from" : "to", v.solid, by, a.span);
                    r ~= transformed(it, a.span, v.solid, b => k.translate(b, off));
                }
                return Value.of(r);
            });
            return true;
        }
    case "above": result = side("above", 1); return true;
    case "below": result = side("below", -1); return true;
    case "crossing": result = side("crossing", 0); return true;
    case "nearest":
        result = method((ref CallArgs a) {
            auto x = Args(it, a, "nearest", ["list", "point"]);
            auto p = x.vecLen("point");
            // a speck at the point: the distance to each solid's surface
            auto speck = k.translate(k.box(1e-3, 1e-3, 1e-3), p - Vec3(5e-4, 5e-4, 5e-4));
            double dist(Value v)
            {
                Vec3 a1, b1;
                return v.solid.brep is null ? double.infinity : k.distance(v.solid.brep, speck, a1, b1);
            }
            return one("nearest", (v, best) => dist(v) < dist(best));
        });
        return true;
    case "largest", "smallest":
        {
            immutable big = name == "largest";
            double vol(Value v) => v.solid.brep is null ? 0 : k.massProps(v.solid.brep).volume;
            result = one(name, (v, best) => big ? vol(v) > vol(best) : vol(v) < vol(best));
            return true;
        }
    case "top", "bottom", "right", "left", "back", "front":
        {
            // the highest, lowest, …: by centre of mass, as faces.top is the one facing up
            immutable axis = name == "top" || name == "bottom" ? 2 : name == "right" || name == "left" ? 0 : 1;
            immutable sign = name == "top" || name == "right" || name == "back" ? 1 : -1;
            result = one(name, (v, best) => centre(v)[axis] * sign > centre(best)[axis] * sign);
            return true;
        }
    default:
        return false;
    }
}

/// A box covering what lies on the normal's side of the plane through `o`,
/// around `near`: what split() and crossing() cut with.
Brep sideBox(BrepKernel k, Brep near, Vec3 o, Vec3 n)
{
    auto bb = k.bbox(near);
    immutable size = 4 * (bb.size.length + (bb.center - o).length) + 10;
    auto b = k.translate(k.box(size, size, size), Vec3(-size / 2, -size / 2, 0)); // above XY
    immutable c = n.normalized.dot(Vec3(0, 0, 1));
    if (c < -1 + 1e-12)
        b = k.rotate(b, Vec3(1, 0, 0), PI);
    else if (c < 1 - 1e-12)
        b = k.rotate(b, Vec3(0, 0, 1).cross(n.normalized), acos(c));
    return k.translate(b, o);
}

private bool isEmptyBrep(Brep b, BrepKernel k) => b is null || k.solids(b).length == 0;

/// The separate bodies of `s`, ordered by position along X, then Y, then Z
/// (`.pieces`, and @parts on a Solid). A body keeps the colour of `s`.
SolidVal[] piecesOf(Interp it, SolidVal s, Span span)
{
    SolidVal[] r;
    if (s.brep is null)
        return r;
    foreach (b; it.kernel.solids(s.brep))
    {
        auto p = derived(it, b, [s], "pieces", span);
        if (s.hasColor)
        {
            p.hasColor = true;
            p.rgb = s.rgb;
        }
        r ~= p;
    }
    // each reference to the bodies it lies in or on
    if (r.length > 1 && s.anchors.length)
        shareAnchors(it, s.anchors, r);
    sortPieces(it, r);
    return r;
}

/// Puts solids in the order of `.pieces`: along X, then Y, then Z (by the
/// middle of their boxes).
void sortPieces(Interp it, SolidVal[] r)
{
    auto key(SolidVal v) => it.kernel.bbox(v.brep).center;
    sort!((p, q) {
        auto a = key(p), b = key(q);
        if (abs(a.x - b.x) > 1e-6) return a.x < b.x;
        if (abs(a.y - b.y) > 1e-6) return a.y < b.y;
        return a.z < b.z;
    })(r);
}

/// A box covering everything on the normal's side of the plane (seen from
/// solid `near`), registered as a "split" feature for face provenance.
SolidVal halfSpace(Interp it, Brep near, Vec3 o, Vec3 n, Span span)
{

    return primitive(it, sideBox(it.kernel, near, o, n), "split", span);
}

Value axisValue(Vec3 origin, Vec3 direction) => Value.make(Kind.struct_, StructVal(axisDef,
    [Value.vector(origin, 3, Dim.length), Value.vector(direction.normalized, 3, Dim.none)]));

bool isAxis(Value v) => v.kind == Kind.struct_ && v.st.def is axisDef;

/// How far push or pull moves solid `s`: `by` along the line from the reference (`name`: a point, a
/// Plane or an Axis) to its centre of mass; from a plane along its normal, from an axis square to it.
/// A solid whose centre is on the reference has no direction: it stays, with a warning.
Vec3 pushOffset(Interp it, ref Args x, string name, SolidVal s, double by, Span span)
{
    if (s.brep is null)
        return Vec3(0, 0, 0);
    immutable c = it.kernel.massProps(s.brep).centroid;
    auto v = x.get(name);
    Vec3 dir;
    if (v.kind == Kind.struct_ && v.st.def is planeDef)
    {
        Vec3 o, n;
        planeArg(x, name, o, n);
        n = n.normalized;
        immutable side = (c - o).dot(n);
        dir = abs(side) < 1e-9 ? Vec3(0, 0, 0) : n * (side > 0 ? 1 : -1);
    }
    else if (isAxis(v))
    {
        Vec3 o, d;
        axisArg(x, name, o, d);
        d = d.normalized;
        auto q = c - o;
        dir = q - d * q.dot(d);
    }
    else if (v.kind == Kind.vec || v.kind == Kind.array)
        dir = c - x.vecLen(name);
    else if (v.kind == Kind.solid && v.solid.surface && v.solid.brep !is null)
    {
        // across the surface where it is nearest, towards the side the solid lies on there (its centre of
        // mass may lie beyond the surface: half a bent tube)
        Vec3 on, n;
        if (!it.kernel.normalAt(v.solid.brep, c, on, n))
            throw new HcadError(Code.type, format("'%s': the surface has no face near the solid", name), x.spanOf(name));
        immutable size = it.kernel.bbox(s.brep).size.length;
        foreach (step; [1e-3, 1e-2, 5e-2])
        {
            immutable e = max(1e-3, size * step);
            immutable plus = it.kernel.inside(s.brep, on + n * e), minus = it.kernel.inside(s.brep, on - n * e);
            if (plus != minus)
            {
                dir = plus ? n : -n;
                break;
            }
        }
        if (dir.length < 1e-9)
            dir = c - on;   // not touching the surface there: away from it
    }
    else
        throw new HcadError(Code.type, format("'%s' is a point, a Plane, an Axis or a Surface, not %s", name, v.typeName),
            x.spanOf(name));
    if (dir.length < 1e-9)
    {
        it.diagnostics ~= Diagnostic(Severity.warning, Code.type, format("a solid's centre of mass is on the %s: "
            ~ "it has no way to go, and stays where it is", name == "from" ? "reference it is pushed from"
            : "reference it is pulled to"), span);
        return Vec3(0, 0, 0);
    }
    return dir.normalized * by;
}

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

/// The X axis of a frame on a face or plane with normal `n`: on a wall (any
/// face that is not flat) horizontal and to the right seen from outside, so
/// that Y goes up it (a text reads, a teardrop points up, on every side);
/// on a flat face the global X.
Vec3 faceXAxis(Vec3 n)
{
    n = n.normalized;
    if (abs(n.z) < 1 - 1e-9)
        return Vec3(0, 0, 1).cross(n).normalized;
    return inPlane(Vec3(1, 0, 0), n).normalized;
}

/// `b`, built on XY in a frame's coordinates, moved onto the frame
/// (origin, x, y, z): a placed profile's solid where the profile lies.
Brep toPlace(BrepKernel k, Vec3[4] place, Brep b)
{
    Vec3 axis;
    immutable angle = axisAngle(place[1], place[2], place[3], axis);
    if (angle > 1e-12)
        b = k.rotate(b, axis, angle);
    return k.translate(b, place[0]);
}

/// `b`, lying on the frame `place`, brought onto XY in the frame's
/// coordinates: the opposite of toPlace.
Brep fromPlace(BrepKernel k, Vec3[4] place, Brep b)
{
    b = k.translate(b, -place[0]);
    Vec3 axis;
    immutable angle = axisAngle(place[1], place[2], place[3], axis);
    if (angle > 1e-12)
        b = k.rotate(b, axis, -angle);
    return b;
}

/// Whether profile `p` lies flat in a plane other than XY (a section, a
/// profile turned or moved up), and the frame of that plane: its normal the
/// faces' own, its origin where the plane is nearest the world's origin (a
/// profile moved up keeps its x and y, one on XZ reads x and z), its axes
/// those of a frame on a face with that normal. An error when it is not flat
/// at all.
bool tiltedProfile(Interp it, SolidVal p, Span span, out Vec3[4] place)
{
    auto k = it.kernel;
    auto bb = k.bbox(nonEmpty(p, span));
    // flat at z = 0: on XY, whatever its faces (not read: every boolean of profiles asks)
    if (abs(bb.min.z) < 1e-6 && abs(bb.max.z) < 1e-6)
        return false;
    auto fs = k.faces(p.brep);
    if (fs.length == 0)
        return false;
    auto n = fs[0].normal.normalized;
    immutable size = max(bb.size.length, 1e-3);
    foreach (f; fs)
        if (abs(abs(f.normal.normalized.dot(n)) - 1) > 1e-7 || abs((f.center - fs[0].center).dot(n)) > 1e-6 * size)
            throw new HcadError(Code.type, "this profile is not flat in one plane: extrude a profile that lies in a "
                ~ "plane (a section, a drawing, a profile moved or turned whole)", span);
    auto o = n * fs[0].center.dot(n);
    auto ax = faceXAxis(n);
    place = [o, ax, n.cross(ax), n];
    return true;
}

/// How a profile lies: on XY (no place of its own), drawn on a face or plane
/// (placed: its brep on XY, in the frame's coordinates) or in another plane
/// (tilted: a section, a profile turned or moved up; its brep where it lies).
enum Lies
{
    onXY,
    placed,
    tilted,
}

/// How profile `p` lies, and the frame of its plane (placed or tilted).
Lies liesOf(Interp it, SolidVal p, Span span, out Vec3[4] frame)
{
    if (p.placed)
    {
        frame = p.place;
        return Lies.placed;
    }
    if (p.brep !is null && tiltedProfile(it, p, span, frame))
        return Lies.tilted;
    frame = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    return Lies.onXY;
}

/// Whether two frames' planes are one (facing either way).
bool samePlane(Vec3[4] a, Vec3[4] b, double size)
    => abs(abs(a[3].dot(b[3])) - 1) < 1e-7 && abs((b[0] - a[0]).dot(a[3])) < 1e-6 * (1 + size);

/// Profiles brought together into one plane, for a boolean or a hull: each as
/// a copy whose brep and references are where the first that lies somewhere
/// (`lies`, `frame`) keeps them; one of no place is taken into that plane, in
/// its coordinates. `ok` false (and nothing brought) when two lie in different
/// planes. Copies of the profiles themselves when none lies anywhere.
SolidVal[] intoOnePlane(Interp it, SolidVal[] ps, Span span, out Lies lies, out Vec3[4] frame, out bool ok)
{
    auto k = it.kernel;
    auto how = new Lies[ps.length];
    auto frames = new Vec3[4][ps.length];
    lies = Lies.onXY;
    foreach (i, p; ps)
    {
        how[i] = liesOf(it, p, span, frames[i]);
        if (how[i] != Lies.onXY && lies == Lies.onXY)
        {
            lies = how[i];
            frame = frames[i];
        }
    }
    ok = true;
    if (lies == Lies.onXY)
        return ps;
    double size = 0;
    foreach (p; ps)
        if (p.brep !is null)
            size = max(size, k.bbox(p.brep).size.length);
    // each into the frame's coordinates (placed) or where it lies (tilted)
    // (made by a function of its own: a delegate made in a loop would share the loop's variables)
    static Brep delegate(Brep) mover(BrepKernel k, Lies from, Vec3[4] f, Lies to, Vec3[4] target)
    {
        return (Brep b) {
            if (from == to && (from == Lies.tilted || f == target))
                return b;
            // into world coordinates, then into the target's
            if (from == Lies.onXY)
                return to == Lies.tilted ? toPlace(k, target, b) : b;
            auto w = from == Lies.placed ? toPlace(k, f, b) : b;
            return to == Lies.placed ? fromPlace(k, target, w) : w;
        };
    }
    Brep delegate(Brep)[] moves;
    foreach (i, p; ps)
    {
        if (how[i] != Lies.onXY && !samePlane(frame, frames[i], size))
        {
            ok = false;
            return null;
        }
        moves ~= mover(k, how[i], frames[i], lies, frame);
    }
    SolidVal[] r;
    foreach (i, p; ps)
    {
        auto c = new SolidVal(p.brep is null ? null : moves[i](p.brep), p.origin);
        c.rgb = p.rgb;
        c.hasColor = p.hasColor;
        c.creators = p.creators;
        c.tags = p.tags;
        c.faceTags = p.faceTags;
        c.edgeTags = p.edgeTags;
        c.flat = true;
        if (p.anchors.length)
            c.anchors = mapAnchors(it, moves[i], p.anchors, span);
        r ~= c;
    }
    return r;
}

/// Profile `r`, made in the coordinates that intoOnePlane gave, put where
/// they lie.
SolidVal liesAs(SolidVal r, Lies lies, Vec3[4] frame)
{
    r.flat = true;
    r.placed = lies == Lies.placed;
    if (r.placed)
        r.place = frame;
    return r;
}

/// Profile `p`'s brep in its plane's coordinates (on XY when it lies on XY), and how it lies.
Brep localOf(Interp it, SolidVal p, Span span, out Lies lies, out Vec3[4] frame)
{
    lies = liesOf(it, p, span, frame);
    return lies == Lies.tilted ? fromPlace(it.kernel, frame, p.brep) : nonEmpty(p, span);
}

/// A point in a frame's coordinates, in the world's.
Vec3 worldOf(Vec3[4] frame, Vec3 p) => frame[0] + frame[1] * p.x + frame[2] * p.y + frame[3] * p.z;

/// The lines through `pts` with each corner rounded by an arc of radius r
/// (a straight corner left as it is); an error at `span` names a corner
/// with no room for it.
PathPiece[] bentPath(Vec3[] pts, bool closed, double r, Span span)
{
    // points that repeat would make a corner of no direction
    Vec3[] p;
    foreach (q; pts)
        if (p.length == 0 || (q - p[$ - 1]).length > 1e-9)
            p ~= q;
    if (closed && p.length > 2 && (p[0] - p[$ - 1]).length <= 1e-9)
        p = p[0 .. $ - 1];
    immutable n = p.length;
    if (n < 2)
        throw new HcadError(Code.type, "a path needs two different points at least", span);
    // at each corner: how far back along each side its arc starts, and the arc
    auto cut = new double[n];
    auto arc = new PathPiece[n];
    auto rounded = new bool[n];
    cut[] = 0;
    foreach (i; 0 .. n)
    {
        if (!closed && (i == 0 || i == n - 1))
            continue;
        auto v = p[i], u1 = (p[(i + n - 1) % n] - v).normalized, u2 = (p[(i + 1) % n] - v).normalized;
        immutable half = acos(max(-1.0, min(1.0, u1.dot(u2)))) / 2;
        if (half > PI / 2 - 1e-9)
            continue;   // straight on: nothing to round
        if (half < 1e-9)
            throw new HcadError(Code.type, format("the path turns right back at point %d", i), span);
        immutable t = r / tan(half);
        auto bis = (u1 + u2).normalized;
        cut[i] = t;
        rounded[i] = true;
        arc[i] = PathPiece(true, v + u1 * t, v + u2 * t, v + bis * (r / sin(half) - r));
    }
    // each side must hold the arcs at both its ends
    foreach (i; 0 .. (closed ? n : n - 1))
    {
        immutable j = (i + 1) % n;
        if (cut[i] + cut[j] > (p[j] - p[i]).length + 1e-9)
            throw new HcadError(Code.type, format("bend %.4g mm does not fit between points %d and %d: the side is "
                ~ "%.4g mm, its corners' arcs need %.4g mm", r, i, j, (p[j] - p[i]).length, cut[i] + cut[j]), span,
                "a smaller bend, or the points further apart");
    }
    PathPiece[] pieces;
    // side after side, each followed by the arc of the corner it ends at
    foreach (i; 0 .. (closed ? n : n - 1))
    {
        immutable j = (i + 1) % n;
        auto from = p[i] + (p[j] - p[i]).normalized * cut[i];
        auto to = p[j] + (p[i] - p[j]).normalized * cut[j];
        if ((to - from).length > 1e-9)
            pieces ~= PathPiece(false, from, to);
        if (rounded[j] && (closed || j != n - 1))
            pieces ~= arc[j];
    }
    return pieces;
}

/// Axis and angle of the rotation whose matrix has columns x, y, z.
double axisAngle(Vec3 x, Vec3 y, Vec3 z, out Vec3 axis)
{

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

/// The radius of the rod that joins bodies touching only along an edge (mm).
enum touchingBridge = 0.02;

/// `a - [b, c, …]`: a less every solid of the list, in one boolean.
Value cutAllSolids(Interp it, SolidVal a, Value[] tools, Span span)
{
    SolidVal[] ts;
    foreach (v; tools)
    {
        if (v.kind != Kind.solid || v.solid.path || v.solid.surface || v.solid.flat != a.flat)
            throw new HcadError(Code.type, format("a %s less a list: the list holds %ss, not %s", a.flat ? "profile" : "solid",
                a.flat ? "profile" : "solid", v.typeName), span);
        if (v.solid.brep !is null)
            ts ~= v.solid;
    }
    if (a.brep is null || ts.length == 0)
        return Value.of(a);
    if (ts.length == 1 || a.flat)
    {
        SolidVal r = a;
        foreach (t; ts)
            r = solidBoolean(it, r, t, BoolOp.cut, span).solid;
        return Value.of(r);
    }
    Brep[] bs;
    foreach (t; ts)
        bs ~= t.brep;
    Brep b2;
    try
        b2 = it.kernel.cutAll(a.brep, bs);
    catch (KernelException e)
        throw new HcadError(Code.kernel, e.msg, span);
    if (it.kernel.faceCount(b2) == 0)
        return Value.of(new SolidVal(null, span));
    return Value.of(derived(it, b2, [a] ~ ts, "difference", span));
}

Value solidBoolean(Interp it, SolidVal a, SolidVal b, BoolOp op, Span span, bool merged = false)
{
    SolidVal r;
    if (a.brep is null || b.brep is null)
    {
        final switch (op)
        {
        case BoolOp.fuse:
            r = a.brep is null ? b : a;
            // an empty solid's references are kept (its own tags and faces are not)
            auto none = a.brep is null ? a : b;
            if (none.anchors.length && r !is none)
            {
                r = copySolid(r);
                r.anchors = mergeAnchors(r.anchors ~ none.anchors);
            }
            break;
        case BoolOp.cut: r = a; break;
        case BoolOp.common:
            r = new SolidVal(null, span);
            // nothing in common between profiles is an empty profile, where they lie
            r.flat = a.flat || b.flat;
            r.placed = a.placed || b.placed;
            r.place = a.placed ? a.place : b.place;
            break;
        }
        return Value.of(r);
    }
    // profiles: both brought into the plane of the one that lies somewhere (a sketch's, a
    // section, a profile moved up), the other of no place taken into it; two planes, an error
    Lies lies;
    Vec3[4] frame;
    if (a.flat && b.flat)
    {
        bool one;
        auto both = intoOnePlane(it, [a, b], span, lies, frame, one);
        if (!one)
            throw new HcadError(Code.type, "these two profiles lie in different planes (drawn on different faces, "
                ~ "or a section and a sketch elsewhere): combine profiles that lie in the same one", span);
        a = both[0];
        b = both[1];
    }
    try
    {
        auto b2 = merged ? it.kernel.booleanMerged(a.brep, b.brep, op) : it.kernel.boolean(a.brep, b.brep, op);
        // bodies touching only along an edge or at a corner make a mesh that
        // is not one closed surface: a sliver joins them, and the user is told
        if (op == BoolOp.fuse && !a.flat && !b.flat)
            if (immutable n = it.kernel.touching(b2))
            {
                b2 = it.kernel.bridgeTouching(b2, touchingBridge);
                it.diagnostics ~= Diagnostic(Severity.warning, Code.kernel, format("the bodies joined here touch only "
                    ~ "along %s edge%s or at a corner: they are bridged with %g mm of material there; overlap them "
                    ~ "(or keep them apart) to choose yourself", n == 1 ? "an" : format("%d", n), n == 1 ? "" : "s",
                    touchingBridge), span);
            }
        // an operation can leave nothing (disjoint intersection, total cut)
        if (it.kernel.faceCount(b2) == 0)
        {
            r = new SolidVal(null, span);
            r.rgb = a.rgb;
            r.hasColor = a.hasColor;
        }
        else
        {
            r = derived(it, b2, [a, b], op == BoolOp.fuse ? "union" : op == BoolOp.cut ? "difference" : "intersection", span);
            // an intersection: the references in the part of an operand it cut away go (as a split's, each to
            // where it lies; one in a hole stays as long as the result is as near as the operand was)
            if (op == BoolOp.common && r.anchors.length)
            {
                Anchor[] kept;
                foreach (input; [a, b])
                    foreach (an; input.anchors)
                        if (pointDistance(it.kernel, b2, an.o) <= pointDistance(it.kernel, input.brep, an.o) + 1e-4)
                            kept ~= an;
                r.anchors = mergeAnchors(kept);
            }
        }
    }
    catch (KernelException e)
        throw new HcadError(Code.kernel, e.msg, span);
    // a profile stays one, empty too (a - b with b over all of a), where they lie
    if (a.flat && b.flat)
        r = liesAs(r, lies, frame);
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
    immutable own = paletteColour(s);
    if (own >= 0)
        return cast(uint) own;
    string[] names = namedColors.keys;
    foreach (c; partPalette)
        names ~= c.name.toLower;
    // nothing close: the names that contain the word, and the hex form
    auto hint = Interp.suggest(s, names);
    if (hint is null)
    {
        import std.algorithm : canFind, sort;
        string[] near;
        foreach (n; names)
            if (n.canFind(s))
                near ~= n;
        near.sort();
        hint = (near.length ? "names with it: " ~ near[0 .. near.length < 4 ? $ : 4].join(", ") ~ "; or " : "")
            ~ "a hex colour, \"#RRGGBB\"";
    }
    throw new HcadError(Code.type, format("unknown color '%s'", v.s), span, hint);
}

immutable uint[string] namedColors;

/// Files read by load(), by kernel, path, time and size: see load.
private __gshared Brep[string] loadCache;
private __gshared Object loadCacheLock;

shared static this()
{
    loadCacheLock = new Object;
    // the built-in struct types, made before any thread uses them
    cast(void) axisDef();
    cast(void) frameDef();
    cast(void) planeDef();
    cast(void) halvesDef();
    cast(void) outlinePointDef();
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
    // the members read most (a list's length, a vector's x), here: builtinMemberAll keeps a closure
    // (its methods' receiver), so its whole frame is allocated on every call
    switch (obj.kind)
    {
    case Kind.array:
        if (name == "length") { result = Value.integer(obj.arr.length); return true; }
        if (name == "empty") { result = Value.of(obj.arr.length == 0); return true; }
        break;
    case Kind.str:
        if (name == "length") { result = Value.integer(obj.s.length); return true; }
        break;
    case Kind.vec:
        if (name == "x") { result = Value.number(obj.v.v.x, obj.v.dim); return true; }
        if (name == "y") { result = Value.number(obj.v.v.y, obj.v.dim); return true; }
        if (name == "z" && obj.v.n == 3) { result = Value.number(obj.v.v.z, obj.v.dim); return true; }
        break;
    case Kind.object_, Kind.aa, Kind.type, Kind.solid, Kind.edge, Kind.face, Kind.selector:
        break;
    default:
        // a number (1.mm), a struct, a function…: no builtin members
        return false;
    }
    return builtinMemberAll(it, obj, name, span, result, isMethod);
}

/// ditto
private bool builtinMemberAll(Interp it, Value obj, string name, Span span, out Value result, out bool isMethod)
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
        // a list of solids (s.pieces): which are where
        import std.algorithm : all;
        if (obj.arr.all!(e => e.kind == Kind.solid))
            return solidsMember(it, obj.arr, name, span, result, &method);
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
        // Solid.nothing: the empty solid, meant: returned by a @part, no part this time
        if (name == "nothing" && obj.type.name == "Solid")
        {
            auto none = new SolidVal(null, span);
            none.none = true;
            result = Value.of(none);
            return true;
        }
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
            case "faces", "edges":
                {
                    // its faces or edges, to select some and tag them: b.faces.top.addTag("lid")
                    auto r = new SelectorVal;
                    r.faces = name == "faces";
                    r.of = s;
                    result = Value.make(Kind.selector, r);
                    return true;
                }
            case "tags": result = tagList(s.tags); return true;
            case "point":
                result = method((ref CallArgs a) {
                    // the point tagged so (addTag(…, at:), a sketch's point), where the solid now is
                    auto x = Args(it, a, "point", ["solid", "tag"]);
                    return anchorValue(it, s, tagName(x.get("tag"), x.spanOf("tag")), AnchorKind.point, x.spanOf("tag"));
                });
                return true;
            case "hasTag":
                result = method((ref CallArgs a) {
                    auto x = Args(it, a, "hasTag", ["solid", "tag"]);
                    return Value.of(s.tags.canFind(tagName(x.get("tag"), x.spanOf("tag"))));
                });
                return true;
            case "addTag", "removeTag", "clearTags":
                result = method((ref CallArgs a) {
                    immutable clear = name == "clearTags";
                    auto x = Args(it, a, name, clear ? ["solid", "recursive"] : name == "addTag"
                        ? ["solid", "tag", "recursive", "at"] : ["solid", "tag", "recursive"]);
                    immutable all = x.flag("recursive", false);
                    auto names = clear ? null : tagNames(x.get("tag"), x.spanOf("tag"));
                    if (name == "addTag")
                        ownTags(names, a.caller, x.spanOf("tag"));
                    if (x.has("at"))
                    {
                        // a point, axis, plane or frame tagged on the solid, to follow it
                        if (x.has("recursive"))
                            throw new HcadError(Code.type, "at: tags a reference on the solid, not its faces: recursive does "
                                ~ "not apply", x.spanOf("recursive"));
                        auto r = copySolid(s);
                        // a tag given again: the new reference replaces those it named
                        r.anchors = s.anchors.filter!(an => !names.canFind(an.tag)).array;
                        foreach (t; names)
                            r.anchors ~= anchorOf(x, "at", t);
                        return Value.of(r);
                    }
                    if (name == "removeTag")
                        foreach (t; names)
                            if (!s.tags.canFind(t) && !s.anchors.any!(an => an.tag == t)
                                && !(all && s.faceTags.any!(f => f.canFind(t))))
                                throw new HcadError(Code.type, format("this solid is not tagged '%s'", t), x.spanOf("tag"),
                                    tagHint(t, s.tags, all ? s.faceTags : null, s.anchors.map!(an => an.tag).array));
                    string[] change(string[] tags) => name == "addTag" ? tagUnion(tags, names)
                        : clear ? null : tags.filter!(t => !names.canFind(t)).array;
                    auto r = copySolid(s);
                    r.tags = change(s.tags);
                    if (name != "addTag")
                        r.anchors = s.anchors.filter!(an => !clear && !names.canFind(an.tag)).array;
                    if (all && s.brep !is null)
                    {
                        r.faceTags = facesTagsOf(it, s).dup;
                        foreach (ref f; r.faceTags)
                            f = change(f);
                    }
                    return Value.of(r);
                });
                return true;
            case "bbox":
                {
                    // a profile drawn on a face: where it lies, as its contains and spots
                    auto b = it.kernel.bbox(s.placed ? toPlace(it.kernel, s.place, nonEmpty(s, span)) : nonEmpty(s, span));
                    result = Value.make(Kind.struct_, StructVal(bboxDef,
                        [vec3(b.min), vec3(b.max), vec3(b.size), vec3(b.center)]));
                    return true;
                }
            case "volume": result = Value.number(s.brep ? it.kernel.volume(s.brep) : 0, Dim.volume); return true;
            case "area": result = Value.number(s.brep ? it.kernel.area(s.brep) : 0, Dim.area); return true;
            case "length":
                {
                    // a path's length, along it
                    if (!s.path)
                        return false;
                    double l = 0;
                    foreach (e; it.kernel.edges(nonEmpty(s, span)))
                        l += e.length;
                    result = Value.number(l, Dim.length);
                    return true;
                }
            case "centroid":
                if (s.flat || s.path)
                    return false;
                nonEmpty(s, span);
                result = Value.vector(it.kernel.massProps(s.brep).centroid, 3, Dim.length);
                return true;
            case "isEmpty": result = Value.of(s.brep is null); return true;
            case "frames":
                {
                    // frames(n): n frames evenly along a path, Z along it, turning as little as they can
                    result = method((ref CallArgs a) {
                        auto x = Args(it, a, "frames", ["path", "n"]);
                        if (!s.path)
                            throw new HcadError(Code.type, "frames are along a path (path, spline, helix)", span);
                        immutable n = x.has("n") ? cast(int) x.num("n") : 32;
                        if (n < 2 || n > 10_000)
                            throw new HcadError(Code.type, "frames takes from 2 to 10000", x.spanOf("n"));
                        Value[] r;
                        foreach (f; pathFrames(it, s, n))
                            r ~= frameValue(f[0], f[1], f[2], f[3]);
                        return Value.of(r);
                    });
                    return true;
                }
            case "outline":
                {
                    // a profile's outline as n points evenly round it, each with its outward normal
                    result = method((ref CallArgs a) {
                        auto x = Args(it, a, "outline", ["profile", "n", "round"]);
                        if (!s.flat)
                            throw new HcadError(Code.type, "outline is of a profile (a 2D shape): this is a solid", span);
                        immutable n = x.has("n") ? cast(size_t) x.num("n") : 64;
                        if (n < 3 || n > 100_000)
                            throw new HcadError(Code.type, "outline takes from 3 to 100000 points", x.spanOf("n"));
                        Value[] r;
                        // round: the normals turn round a corner as on a fillet that big
                        foreach (q; outlinePoints(it, s, n, span, x.has("round") ? x.len("round") : 0))
                            r ~= q;
                        return Value.of(r);
                    });
                    return true;
                }
            case "pieces":
                {
                    Value[] r;
                    if (s.flat)
                    {
                        // a profile: its separate regions, each with its holes
                        SolidVal[] parts;
                        foreach (b; s.brep is null ? null : it.kernel.profileParts(s.brep, 2))
                            parts ~= derived(it, b, [s], "pieces", span);
                        // each reference to the regions it lies in or on
                        if (parts.length > 1 && s.anchors.length)
                            shareAnchors(it, s.anchors, parts);
                        foreach (q; parts)
                            r ~= Value.of(q);
                        result = Value.of(r);
                        return true;
                    }
                    foreach (p; piecesOf(it, s, span))
                        r ~= Value.of(p);
                    result = Value.of(r);
                    return true;
                }
            case "outer", "holes":
                {
                    // a profile's outline without its holes, or its holes each filled
                    if (!s.flat)
                        return false;
                    auto parts = s.brep is null ? null : it.kernel.profileParts(s.brep, name == "outer" ? 0 : 1);
                    if (name == "holes")
                    {
                        Value[] r;
                        foreach (b; parts)
                            r ~= Value.of(derived(it, b, [s], "holes", span));
                        result = Value.of(r);
                        return true;
                    }
                    if (parts.length == 0)
                        throw new HcadError(Code.type, "the profile is empty: it has no outline", span);
                    auto b = parts[0];
                    foreach (q; parts[1 .. $])
                        b = it.kernel.boolean(b, q, BoolOp.fuse);
                    result = Value.of(derived(it, b, [s], "outer", span));
                    return true;
                }
            case "contains":
                {
                    // body.contains(p): whether point p lies inside the solid (on its surface: no); a profile, inside
                    // its area (p taken onto its plane)
                    result = method((ref CallArgs a) {
                        auto x = Args(it, a, "contains", ["solid", "point"]);
                        auto q = x.vecLen("point");
                        if (s.brep is null)
                            return Value.of(false);
                        if (!s.flat)
                            return Value.of(it.kernel.inside(s.brep, q));
                        // a profile in a plane (drawn on a face, a section): the point taken onto it, in
                        // its coordinates
                        Lies lies;
                        Vec3[4] frame;
                        auto local = localOf(it, s, a.span, lies, frame);
                        auto d = q - frame[0];
                        q = Vec3(d.dot(frame[1]), d.dot(frame[2]), 0);
                        auto slab = it.kernel.extrude(local, 1, 0);
                        return Value.of(it.kernel.inside(slab, Vec3(q.x, q.y, 0.5)));
                    });
                    return true;
                }
            case "spots":
                {
                    // profile.spots(3, margin: 5.mm): points inside it, at least margin from its edges, as far
                    // apart as they can be (where to put the keys, the pins, the feet)
                    if (!s.flat)
                        return false;
                    result = method((ref CallArgs a) {
                        auto x = Args(it, a, "spots", ["profile", "n", "margin"]);
                        immutable n = cast(int) x.num("n");
                        if (n < 1 || n > 100)
                            throw new HcadError(Code.type, "spots: from 1 to 100 points", x.spanOf("n"));
                        immutable margin = x.lenOr("margin", 0);
                        Brep b = nonEmpty(s, a.span);
                        Value[] r;
                        // a profile drawn on a face: where it lies
                        foreach (q; it.kernel.spots(b, n, margin))
                            r ~= Value.vector(s.placed ? worldOf(s.place, q) : q, 3, Dim.length);
                        return Value.of(r);
                    });
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

/// A tag: a text, not empty.
string tagName(Value v, Span span)
{
    if (v.kind != Kind.str || v.s.length == 0)
        throw new HcadError(Code.type, format("a tag is a text, such as \"lid\", not %s", v.kind == Kind.str ? "an empty one"
            : v.typeName), span);
    return v.s;
}

/// A tag with a dot belongs to a module, the one its name starts with ("hinges.pin" to the hinges
/// library): given only there, so that a library's tags and a model's never collide. A tag given is
/// not blank and holds no ';' (a STEP file keeps a face's tags joined by it).
void ownTags(const(string)[] tags, ModuleVal caller, Span span)
{
    import std.string : indexOf, lastIndexOf, strip;
    foreach (t; tags)
    {
        if (t.strip.length == 0)
            throw new HcadError(Code.type, "a tag cannot be blank: give it a name, such as \"lid\"", span);
        if (t.indexOf(';') >= 0)
            throw new HcadError(Code.type, format("a tag cannot hold ';' (a STEP file keeps a face's tags joined by "
                ~ "it): '%s'", t), span, "use another character, such as '-' or '_'");
        if (t.indexOf('.') < 0)
            continue;
        if (t[0] == '.' || t[$ - 1] == '.' || t.indexOf("..") >= 0)
            throw new HcadError(Code.type, format("'%s' is not a tag: a dot goes between the name of a module and "
                ~ "a name, such as \"hinges.pin\"", t), span, "leave the dot out");
        immutable mine = caller is null ? null : caller.name;
        if (mine.length && t.length > mine.length + 1 && t[0 .. mine.length] == mine && t[mine.length] == '.')
            continue;
        // the module is all before the last dot (sub.deep's tags are "sub.deep.name"), the name after it
        immutable mod = t[0 .. t.lastIndexOf('.')], bare = t[t.lastIndexOf('.') + 1 .. $];
        throw new HcadError(Code.type, format("a tag with a dot belongs to a module: '%s' can only be given in module %s",
            t, mod), span, mine.length ? format("here, in module %s: '%s' without the dot, or '%s.%s'",
            mine, bare, mine, bare) : format("here: '%s' without the dot", bare));
    }
}

/// Tags given as one text or a list of them.
string[] tagNames(Value v, Span span)
{
    if (v.kind != Kind.array)
        return [tagName(v, span)];
    string[] r;
    foreach (e; v.arr)
        r = tagUnion(r, [tagName(e, span)]);
    if (r.length == 0)
        throw new HcadError(Code.type, "no tag given: the list is empty", span);
    return r;
}

Value tagList(const(string)[] tags)
{
    Value[] r;
    foreach (t; tags)
        r ~= Value.of(t);
    return Value.of(r);
}

/// "did you mean" over the tags there are, and which they are.
string tagHint(string t, const(string)[] tags, const(string[])[] faceTags, const(string)[] refs = null)
{
    string[] all = tags.dup;
    foreach (f; faceTags)
        all = tagUnion(all, f);
    auto named = tagUnion(null, refs);
    if (all.length == 0 && named.length == 0)
        return null;
    auto close = Interp.suggest(t, all ~ named);
    // its references (addTag(…, at:)) told apart from its tags
    auto lists = (all.length ? [format("its tags: %-(%s, %)", all)] : []) ~ (named.length
        ? [format("its references: %-(%s, %)", named)] : []);
    return (close ? close ~ " " : "") ~ "(" ~ lists.join("; ") ~ ")";
}

/// The tags of each face of `s` (a list of empty ones when it has none).
string[][] facesTagsOf(Interp it, SolidVal s)
{
    if (s.brep is null)
        return null;
    immutable n = it.kernel.faceCount(s.brep);
    if (s.faceTags.length == n)
        return s.faceTags;
    return new string[][n];
}

/// The faces a selector taken from a solid (b.faces.top) selects there, for its tags.
int[] selectedOf(Interp it, SelectorVal sel, string name, Span span)
{
    if (!sel.faces)
        throw new HcadError(Code.type, "edges have no tags yet: tag the faces on either side and take the edges between "
            ~ "them, edges.between(faces.tagged(\"a\"), faces.tagged(\"b\"))", span);
    if (sel.of is null)
        throw new HcadError(Code.type, format("%s: of which solid? take the faces from it, b.faces.top.%s", name, name), span);
    return resolveSelector(it, sel, sel.of, span);
}

/// A copy of `s` to change: the same shape, the same everything.
SolidVal copySolid(SolidVal s)
{
    auto r = new SolidVal(s.brep, s.origin);
    r.rgb = s.rgb;
    r.hasColor = s.hasColor;
    r.creators = s.creators;
    r.tags = s.tags;
    r.faceTags = s.faceTags;
    r.anchors = s.anchors;
    r.edgeTags = s.edgeTags;
    r.lostEdgeTags = s.lostEdgeTags;
    r.lostBy = s.lostBy;
    r.loftPaths = s.loftPaths;
    r.loftRuled = s.loftRuled;
    r.flat = s.flat;
    r.path = s.path;
    r.pathNormal = s.pathNormal;
    r.surface = s.surface;
    r.placed = s.placed;
    r.place = s.place;
    return r;
}

/// Indices of the edges/faces of `s` matched by the selector.
int[] resolveSelector(Interp it, SelectorVal sel, SolidVal s, Span span, bool allowEmpty = false)
{
    auto b = nonEmpty(s, span);
    SelectCtx ctx;
    auto faces = it.kernel.faces(b);
    ctx.faces = faces;
    ctx.creators = s.creators.length == faces.length ? s.creators : null;
    ctx.faceTags = s.faceTags.length == faces.length ? s.faceTags : null;
    if (!sel.faces)
    {
        ctx.edges = it.kernel.edges(b);
        ctx.edgeFaces = it.kernel.edgeFaces(b);
    }
    ctx.outerEdges = (int f) => it.kernel.faceOuterEdges(b, f);
    double[][double] shares;
    ctx.overhangShares = (double angle) {
        if (auto r = angle in shares)
            return *r;
        import hackerscad.geom.printability : checkPrint;
        auto m = it.kernel.tessellate(b, 0.05, 0.2);
        auto pc = checkPrint(m.verts, 3, m.tris, angle, 0);
        auto r = new double[faces.length];
        r[] = 0;
        if (m.faceStart.length == faces.length + 1)
            foreach (f; 0 .. faces.length)
            {
                double over = 0, all = 0;
                foreach (t; m.faceStart[f] .. m.faceStart[f + 1])
                {
                    auto v0 = m.vertex(m.tris[t * 3]), v1 = m.vertex(m.tris[t * 3 + 1]), v2 = m.vertex(m.tris[t * 3 + 2]);
                    immutable area = (v1 - v0).cross(v2 - v0).length / 2;
                    all += area;
                    if (pc.overhang[t])
                        over += area;
                }
                r[f] = all > 0 ? over / all : 0;
            }
        return shares[angle] = r;
    };
    int[][SelectorVal] nested;
    // a tag looked for inside (edges.of(faces.tagged("lid"))) and found nowhere: what an error says
    SelectorVal tagMissing;
    ctx.resolve = (SelectorVal inner) {
        if (auto r = inner in nested)
            return *r;
        auto r = resolveSelector(it, inner, s, span, true);
        if (r.length == 0 && inner.tagged.length && tagMissing is null)
            tagMissing = inner;
        return nested[inner] = r;
    };

    immutable n = sel.faces ? faces.length : ctx.edges.length;
    int[] r;
    bool seamsOnly;
    foreach (i; 0 .. n)
    {
        // a seam (where a cylinder's side closes on itself) is no edge: nothing to round, nothing seen
        immutable seam = !sel.faces && ctx.edgeFaces[i][1] == -2;
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
            ok = call1(it, p, item, span).condition(span);
        }
        if (ok && seam)
            seamsOnly = true;
        else if (ok)
            r ~= cast(int) i;
    }
    if (r.length == 0 && !allowEmpty)
    {
        if (!sel.tagged.length && tagMissing !is null)
            sel = tagMissing;
        if (sel.tagged.length)
        {
            string[] present;
            foreach (t; ctx.faceTags)
                present = tagUnion(present, t);
            // the tags there: the rest of the selector (a filter, a normal) left none of their faces
            if (sel.tagged.all!(t => present.canFind(t)))
                throw new HcadError(Code.kernel, format("faces tagged %-(%s, %) are there, but none of them is left by "
                    ~ "the rest of the selector", sel.tagged.map!(t => "'" ~ t ~ "'")), span,
                    "look at the filter or the direction that follows the tag");
            // a sketch's line or circle so tagged, whose name an operation on the profile lost
            foreach (t; sel.tagged)
                if (!present.canFind(t) && s.lostEdgeTags.canFind(t))
                    throw new HcadError(Code.kernel, format("no face of this solid is tagged '%s': the sketch's line, arc "
                        ~ "or circle tagged so lost its name on the way, where the profile went through %s", t,
                        lostByWords(s.lostBy[s.lostEdgeTags.countUntil(t)])), span,
                        "tag the solid's faces themselves: b.faces.….addTag(\"" ~ t ~ "\")");
            auto close = present.length ? Interp.suggest(sel.tagged[0], present) : null;
            throw new HcadError(Code.kernel, format("no face of this solid is tagged %-(%s, %)", sel.tagged.map!(t => "'" ~ t ~ "'")),
                span, present.length ? (close ? close ~ " " : "") ~ format("(the tags on its faces: %-(%s, %))", present)
                    : "none of its faces has a tag: give them one with addTag (b.faces.top.addTag(\"lid\"))");
        }
        throw new HcadError(Code.kernel, format("the selector matched no %s on this solid", sel.faces ? "faces" : "edges"), span,
            seamsOnly ? "only seams: the line where a curved face closes on itself (down a cylinder's side, round a "
                ~ "sphere) is not an edge, nothing to round there" : null);
    }
    return r;
}

/// Named/positional argument reader with validation and unit coercion.
/// A regular polygon's fit: argument, "corners" (the default: its size is the circle through the
/// corners) or "sides" (the circle its sides touch); true for "sides".
bool polygonFit(ref Args x)
{
    if (!x.has("fit"))
        return false;
    auto v = x.get("fit");
    if (v.kind != Kind.str || (v.s != "corners" && v.s != "sides"))
        throw new HcadError(Code.type, "fit is \"corners\" or \"sides\"", x.spanOf("fit"));
    return v.s == "sides";
}

struct Args
{
    Interp it;
    CallArgs* raw;
    string fn;
    string[] names;

    // the arguments are read where the call left them, by position (the declared names' order) or by
    // name: nothing copied (every builtin call, 1.mm included, made two associative arrays of them)
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
        foreach (k; a.namedOrder)
        {
            immutable i = position(k);
            if (i < 0)
                throw new HcadError(Code.unknownArg, format("unknown argument '%s' for %s(%s)", k, fn, names.join(", ")),
                    a.namedSpans[k], Interp.suggest(k, names));
            if (i < a.positional.length)
                throw new HcadError(Code.unknownArg, format("argument '%s' given both by position and by name", k), a.namedSpans[k]);
        }
    }

    /// Where `n` is among the declared names (-1: not there).
    private ptrdiff_t position(string n) const
    {
        foreach (i, m; names)
            if (m == n)
                return i;
        return -1;
    }

    /// The value given for `n`, or null.
    private Value* find(string n)
    {
        immutable i = position(n);
        if (i >= 0 && i < raw.positional.length)
            return &raw.positional[i];
        return n in raw.named;
    }

    bool has(string n) => find(n) !is null;

    Span spanOf(string n)
    {
        immutable i = position(n);
        if (i >= 0 && i < raw.positional.length)
            return i < raw.positionalSpans.length ? raw.positionalSpans[i] : raw.span;
        return raw.namedSpans.get(n, raw.span);
    }

    Value get(string n)
    {
        if (auto v = find(n))
            return *v;
        // a sketch's method: as it is written, s.equal(a, b)
        if (names.length && names[0] == "sketch")
            throw new HcadError(Code.missingArg, format("missing argument '%s' for s.%s(%s)", n, fn,
                names[1 .. $].join(", ")), raw.span);
        throw new HcadError(Code.missingArg, format("missing argument '%s' for %s(%s)", n, fn, names.join(", ")), raw.span);
    }

    double unitFactor() => raw.caller ? raw.caller.unitFactor : 1;

    /// NaN or infinity (1.0 / 0, sqrt(-1)…) would hang the kernel or give nonsense.
    double finite(string n, double x)
    {
        if (!isFinite(x))
            throw new HcadError(Code.type, format("'%s' is %s: a division by zero, or sqrt, asin or acos out of their range?",
                n, x != x ? "not a number (NaN)" : "infinite"), spanOf(n));
        return x;
    }

    double len(string n)
    {
        auto v = get(n);
        if (v.isNum)
            finite(n, v.n.value);
        if (!v.isNum)
            throw new HcadError(Code.type, format("'%s' must be a Length, not %s", n, v.typeName), spanOf(n));
        if (v.n.dim == Dim.length)
            return v.n.value;
        if (v.n.dim == Dim.none)
            return v.n.value * unitFactor;
        throw new HcadError(Code.units, format("'%s' must be a Length, not %s", n, v.n.dim.aName), spanOf(n));
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
        if (v.isNum)
            finite(n, v.n.value);
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
        return finite(n, v.n.value);
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
            throw new HcadError(Code.type, format("'%s' must be %s (e.g. %s), not %s", n, faces ? "a face selector"
                : "an edge selector", faces ? "faces.top" : "edges.parallel(Z)", v.kind == Kind.selector
                ? (v.sel.faces ? "faces" : "edges") : v.typeName), spanOf(n));
        return v.sel;
    }

    VecVal vecAny(string n)
    {
        auto v = get(n);
        if (v.kind == Kind.array)
            v = arrayToVec(it, v.arr, raw.caller, spanOf(n));
        if (v.kind != Kind.vec)
            throw new HcadError(Code.type, format("'%s' must be a vector, not %s", n, v.typeName), spanOf(n));
        finite(n, v.v.v.x), finite(n, v.v.v.y), finite(n, v.v.v.z);
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
/// OpenCascade only says "not done": the edges are tried one by one to find
/// those that fail, and the largest size that works on them all is searched
/// for, with a face narrower than that beside the failing edges (a rounding
/// needs that much room on each face) named with its width.
Value edgeFeature(Interp it, ref CallArgs a, SolidVal s, int[] idx, string kind, string size, double value,
    Brep delegate(Brep, const(int)[], double) f)
{
    try
        return transformed(it, a.span, s, (Brep b) => f(b, idx, value), kind);
    catch (KernelException e)
    {
        auto k = it.kernel;
        immutable bodies = s.brep is null ? 0 : k.solids(s.brep).length;
        if (bodies > 1)
            throw new HcadError(Code.kernel, e.msg, a.span, format("the solid is made of %s separate bodies touching "
                ~ "each other; fuse them first", bodies));
        bool works(const(int)[] es, double v)
        {
            try
                f(s.brep, es, v);
            catch (KernelException)
                return false;
            return true;
        }
        // which edges fail on their own (not too many tries: each is a fillet)
        int[] failing;
        immutable tried = idx.length <= 24;
        if (tried)
            foreach (i; idx)
                if (!works([i], value))
                    failing ~= i;
        auto infos = k.edges(s.brep);
        string where(const(int)[] es)
        {
            string[] r;
            foreach (i; es[0 .. min($, 3)])
                r ~= format("%s at (%s)", infos[i].kind == EdgeKind.line ? "the straight edge" : infos[i].kind
                    == EdgeKind.circle ? "the curved edge" : "the edge", fmtPoint(infos[i].mid));
            return r.join(", ") ~ (es.length > 3 ? format(" and %d more", es.length - 3) : "");
        }
        // rounds of that very radius made before, which these edges may run into: OpenCascade cannot join
        // two rounds of one radius meeting at a corner when they are made one after the other
        bool sameRadius;
        if (kind == "fillet")
            foreach (fi; 0 .. k.faceCount(s.brep))
            {
                CylinderInfo ci;
                if (k.faceCylinder(s.brep, cast(int) fi, ci) && abs(ci.radius - value) < 1e-6 * (1 + value))
                    sameRadius = true;
            }
        immutable together = sameRadius ? "; where they run into rounds of that same r made before, round them all in "
            ~ "one fillet (the two selectors joined with +), or these first" : "";
        if (tried && failing.length == 0)
            throw new HcadError(Code.kernel, format("%s failed: each of the %d edges takes it on its own, not all together",
                kind, idx.length), a.span, format("where they meet the %s does not close: %s them in groups, or try "
                ~ "a smaller %s", kind, kind, size) ~ together);
        auto bad = tried ? failing : idx;
        // the largest size that works on all the edges (a few tries, halving the gap): a number that is
        // right, or none
        double ok = 0;
        if (tried)
        {
            double lo = 0, hi = value;
            foreach (_; 0 .. 7)
            {
                immutable mid = (lo + hi) / 2;
                if (works(idx, mid))
                    lo = mid;
                else
                    hi = mid;
            }
            ok = lo;
        }
        // the narrowest face beside the failing edges: the reason, when it is about the size that works
        immutable narrow = narrowestBeside(it, s.brep, bad);
        string msg = format("%s failed%s", kind, tried ? format(" on %s", where(bad)) : "");
        string hint;
        if (ok > 0 && narrow < value && narrow > 0.8 * ok && narrow < 1.25 * ok)
            hint = format("a face beside %s is only %s mm wide there, and a %s of %s %s needs that much room on it: "
                ~ "make %s smaller than %s mm (or %s before the cut that narrows that face)", bad.length > 1 ? "them"
                : "it", fmtNum(narrow), kind, size, fmtNum(value), size, fmtNum(narrow), kind);
        else if (ok > 0)
            hint = format("%s up to about %s mm works on these edges: make %s smaller, or apply it to fewer edges at a "
                ~ "time (%s edges selected)", size, fmtDown(ok), size, idx.length);
        else
            hint = format("try a smaller %s, or apply it to fewer edges at a time (%s edges selected)", size, idx.length);
        // OpenCascade's own words, without the "fillet failed:" they start with; none when they only say
        // it was not done
        import std.algorithm : findSplitAfter;
        auto said = e.msg.findSplitAfter(": ");
        immutable words = said ? said[1].idup : e.msg;
        immutable silent = words.canFind("NotDone") || words.canFind("command not done");
        throw new HcadError(Code.kernel, msg ~ (silent ? "" : " (" ~ words ~ ")"), a.span, hint ~ together);
    }
}

/// `v` to 3 significant digits, rounded down: a size that still works.
private string fmtDown(double v)
{
    import std.math : log10, pow;
    immutable step = pow(10.0, floor(log10(v)) - 2);
    return format("%g", floor(v / step) * step);
}

private string fmtNum(double v) => format("%.3g", v);
private string fmtPoint(Vec3 p)
{
    import std.math : round;
    double c(double v) => abs(v) < 1e-6 ? 0.0 : round(v * 1000) / 1000;
    return format("%g, %g, %g", c(p.x), c(p.y), c(p.z));
}

/// How wide the narrowest face beside edges `es` is, near them: the
/// shortest distance from points along each edge to the rest of the outline
/// of the faces it joins (the parts of that outline on the edge itself left
/// out). Infinity when it cannot tell.
double narrowestBeside(Interp it, Brep b, const(int)[] es)
{
    import std.math : acos;
    auto k = it.kernel;
    auto infos = k.edges(b);
    auto ends = k.edgeFaces(b);
    immutable size = k.bbox(b).size.length;
    immutable tol = 1e-4 * size;
    double best = double.infinity;
    foreach (i; es)
    {
        auto e = infos[i];
        // points along the edge, and whether a point lies on it
        Vec3[] along;
        bool delegate(Vec3) on;
        if (e.kind == EdgeKind.circle)
        {
            auto ax = e.axis.normalized, c = e.center;
            auto u = (e.start - c) - ax * (e.start - c).dot(ax);
            u = u.normalized;
            auto v = ax.cross(u);
            double ang(Vec3 p) { auto d = p - c; return atan2(d.dot(v), d.dot(u)); }
            double a1 = ang(e.end), am = ang(e.mid);
            if (a1 <= 1e-9)
                a1 += 2 * PI;
            if (am < 0)
                am += 2 * PI;
            if (am > a1)   // runs the other way round
                a1 -= 2 * PI;
            foreach (t; 0 .. 9)
            {
                immutable th = a1 * t / 8;
                along ~= c + (u * cos(th) + v * sin(th)) * e.radius;
            }
            on = (Vec3 p) {
                auto d = p - c;
                immutable h = d.dot(ax);
                return abs(h) < tol && abs((d - ax * h).length - e.radius) < tol;
            };
        }
        else
        {
            foreach (t; 0 .. 5)
                along ~= e.start + (e.end - e.start) * (t / 4.0);
            if (e.kind != EdgeKind.line)
                along ~= e.mid;
            auto pts = e.kind == EdgeKind.line ? [e.start, e.end] : [e.start, e.mid, e.end];
            on = (Vec3 p) {
                foreach (j; 0 .. pts.length - 1)
                    if (segmentDistance(p, pts[j], pts[j + 1]) < (e.kind == EdgeKind.line ? tol : 0.05 * e.length + tol))
                        return true;
                return false;
            };
        }
        foreach (face; ends[i])
        {
            if (face < 0)
                continue;
            foreach (loop; k.faceLoops(b, face, 1e-3 * size))
                foreach (j; 0 .. loop.length)
                {
                    auto p = loop[j], q = loop[(j + 1) % loop.length];
                    if (on(p) || on(q))
                        continue;
                    foreach (x; along)
                        best = min(best, segmentDistance(x, p, q));
                }
        }
    }
    return best;
}

/// Distance from point `x` to the segment p–q.
private double segmentDistance(Vec3 x, Vec3 p, Vec3 q)
{
    auto d = q - p;
    immutable l2 = d.dot(d);
    immutable t = l2 > 0 ? max(0.0, min(1.0, (x - p).dot(d) / l2)) : 0;
    return (x - (p + d * t)).length;
}

/// Applies an operation to one solid, keeping colour and face provenance;
/// faces the operation creates are attributed to a new `kind` feature.
/// `rigid`: the operation only moves, turns, mirrors or scales (by default when `kind` is "transform").
Value transformed(Interp it, Span span, SolidVal s, Brep delegate(Brep) f, string kind = "transform",
    bool rigid = false)
{
    if (s.brep is null)
        return Value.of(s);
    rigid = rigid || kind == "transform";
    auto r = derived(it, f(s.brep), [s], kind, span, !rigid);
    // moved, turned, mirrored, scaled: its references too, and a profile's tagged edges, in the same order
    if (rigid && s.anchors.length)
        r.anchors = mapAnchors(it, f, s.anchors, span);
    if (rigid && s.edgeTags.length)
    {
        r.edgeTags = s.edgeTags;
        keptEdgeTags(r);
    }
    // moving what a feature has just made, in the same statement
    // (circle(…).move(…)): the feature shows where its solid ends up. A caller
    // moving what a function returned (f().move(…)), or a solid kept in a
    // variable and moved later (rod.rotate(…), maybe twice), moves it on its
    // own line, not on the feature's.
    if (s.creators.length && s.creators[0] > 0 && s.creators[0] <= it.features.length)
    {
        auto feature = &it.features[s.creators[0] - 1];
        if (feature.result is s && feature.frame is it.callFrame && feature.statement is it.currentStatement)
        {
            if (!feature.moved)
                feature.made = s;
            feature.result = r;
            feature.moved = true;
        }
    }
    return Value.of(r);
}

/// `as` taken where a transform (`f`, which moves a Brep) takes a solid: the transform read off what
/// it does to a box's face centres (an affine map), whatever it is made of.
Anchor[] mapAnchors(Interp it, Brep delegate(Brep) f, const(Anchor)[] as, Span span)
{
    auto k = it.kernel;
    auto probe = k.box(1, 1, 1);
    auto before = k.faces(probe), after = k.faces(f(probe));
    if (before.length != after.length)
        throw new HcadError(Code.kernel, "the references tagged on the solid could not follow it", span);
    // four centres not in one plane: the map from the differences to the first
    double[3][3] c, d;
    size_t[3] pick;
    bool found;
    double det3(const ref double[3][3] m) => m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    search: foreach (a; 1 .. before.length)
        foreach (b; a + 1 .. before.length)
            foreach (e; b + 1 .. before.length)
            {
                pick = [a, b, e];
                foreach (col, i; pick)
                {
                    auto v = before[i].center - before[0].center;
                    c[0][col] = v.x;
                    c[1][col] = v.y;
                    c[2][col] = v.z;
                }
                if (abs(det3(c)) > 1e-6)
                {
                    found = true;
                    break search;
                }
            }
    assert(found);
    foreach (col, i; pick)
    {
        auto v = after[i].center - after[0].center;
        d[0][col] = v.x;
        d[1][col] = v.y;
        d[2][col] = v.z;
    }
    // M = D C⁻¹
    double[3][3] ci, m;
    immutable det = det3(c);
    foreach (i; 0 .. 3)
        foreach (j; 0 .. 3)
        {
            immutable i1 = (j + 1) % 3, i2 = (j + 2) % 3, j1 = (i + 1) % 3, j2 = (i + 2) % 3;
            ci[i][j] = (c[i1][j1] * c[i2][j2] - c[i1][j2] * c[i2][j1]) / det;
        }
    foreach (i; 0 .. 3)
        foreach (j; 0 .. 3)
            m[i][j] = d[i][0] * ci[0][j] + d[i][1] * ci[1][j] + d[i][2] * ci[2][j];
    Vec3 lin(Vec3 v) => Vec3(m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
        m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z, m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z);
    // a normal goes by the inverse transpose: the same for a turn or a mirror, not for a stretch
    double[3][3] mi;
    immutable dm = det3(m);
    foreach (i; 0 .. 3)
        foreach (j; 0 .. 3)
        {
            immutable i1 = (j + 1) % 3, i2 = (j + 2) % 3, j1 = (i + 1) % 3, j2 = (i + 2) % 3;
            mi[i][j] = (m[i1][j1] * m[i2][j2] - m[i1][j2] * m[i2][j1]) / dm;
        }
    Vec3 normal(Vec3 v) => Vec3(mi[0][0] * v.x + mi[1][0] * v.y + mi[2][0] * v.z,
        mi[0][1] * v.x + mi[1][1] * v.y + mi[2][1] * v.z, mi[0][2] * v.x + mi[1][2] * v.y + mi[2][2] * v.z).normalized;
    immutable o0 = before[0].center, o1 = after[0].center;
    Anchor[] r;
    foreach (a; as)
    {
        Anchor b = a;
        b.o = o1 + lin(a.o - o0);
        b.x = lin(a.x).normalized;
        b.z = a.kind == AnchorKind.axis ? lin(a.z).normalized : normal(a.z);
        b.y = b.z.cross(b.x).normalized;
        b.x = b.y.cross(b.z).normalized;
        r ~= b;
    }
    return r;
}

/// The reference tagged so on `s`, read as `want` (a point, an axis, a plane or a frame), where it is.
Value anchorValue(Interp it, SolidVal s, string tag, AnchorKind want, Span span)
{
    import std.algorithm : filter;
    auto found = s.anchors.filter!(a => a.tag == tag).array;
    immutable what = ["point", "axis", "plane", "frame"][want];
    if (found.length == 0)
    {
        auto names = s.anchors.map!(a => a.tag).array;
        auto close = names.length ? Interp.suggest(tag, names) : null;
        throw new HcadError(Code.undefined, format("no point, axis, plane or frame of this solid is tagged '%s'", tag), span,
            names.length ? (close ? close ~ " " : "") ~ format("(its references: %-(%s, %))", names)
                : "tag one with addTag(\"name\", at: …), or a point of the sketch it is made from");
    }
    found = mergeAnchors(found);
    if (found.length > 1)
        throw new HcadError(Code.type, format("%d references in different places on this solid are tagged '%s': each "
            ~ "copy joined into it brought its own", found.length, tag), span,
            format("tag the copies apart before joining them, or tag the joined solid again (addTag(\"%s\", at: …) "
            ~ "replaces them)", tag));
    auto a = found[0];
    if (want == AnchorKind.plane && a.kind == AnchorKind.point)
        throw new HcadError(Code.type, format("'%s' is a point: a plane needs a direction too (tag a plane, an axis or "
            ~ "a frame)", tag), span);
    if (want == AnchorKind.axis && a.kind == AnchorKind.point)
        throw new HcadError(Code.type, format("'%s' is a point: an axis needs a direction too (tag a circle, a line, "
            ~ "an axis or a frame)", tag), span);
    // a profile drawn on a face: its coordinates are the face's
    Vec3 at(Vec3 p) => s.placed ? s.place[0] + s.place[1] * p.x + s.place[2] * p.y + s.place[3] * p.z : p;
    Vec3 dir(Vec3 v) => s.placed ? s.place[1] * v.x + s.place[2] * v.y + s.place[3] * v.z : v;
    final switch (want)
    {
    case AnchorKind.point: return Value.vector(at(a.o), 3, Dim.length);
    case AnchorKind.axis: return axisValue(at(a.o), dir(a.z));
    case AnchorKind.plane: return planeValue(at(a.o), dir(a.z));
    case AnchorKind.frame:
        // an axis or a plane: its X as a plane's frame() and a face's have it, wherever it was turned
        if (a.kind == AnchorKind.axis || a.kind == AnchorKind.plane)
        {
            auto z = dir(a.z).normalized, x = faceXAxis(z);
            return frameValue(at(a.o), x, z.cross(x), z);
        }
        return frameValue(at(a.o), dir(a.x), dir(a.y), dir(a.z));
    }
}

/// Whether two references are one: of one tag and kind, in one place (and facing one way), to a hair.
bool sameAnchor(const Anchor a, const Anchor b)
{
    immutable tol = 1e-6 * (1 + a.o.length);
    if (a.tag != b.tag || a.kind != b.kind || (a.o - b.o).length > tol)
        return false;
    if (a.kind == AnchorKind.point)
        return true;
    return (a.z - b.z).length < 1e-6 && (a.kind != AnchorKind.frame || (a.x - b.x).length < 1e-6);
}

/// `as` without the references equal to an earlier one: a solid joined to a copy of itself (two
/// halves joined again, a face pushed out) holds each of them once.
Anchor[] mergeAnchors(const(Anchor)[] as)
{
    Anchor[] r;
    foreach (a; as)
        if (!r.any!(b => sameAnchor(a, b)))
            r ~= a;
    return r;
}

/// How far point `p` lies from `b`: 0 inside it or on its surface.
double pointDistance(BrepKernel k, Brep b, Vec3 p)
{
    // a speck of a box there: a solid inside another one is at distance 0
    enum e = 1e-5;
    Vec3 u, v;
    return k.distance(b, k.translate(k.box(e, e, e), p - Vec3(e / 2, e / 2, e / 2)), u, v);
}

/// The references `from` hands to the pieces it was cut into: each to the pieces it lies in or on
/// (one on the cut, to those on both sides of it), one in none (on a hole's axis) to the nearest.
void shareAnchors(Interp it, const(Anchor)[] from, SolidVal[] pieces)
{
    foreach (p; pieces)
        if (p !is null)
            p.anchors = null;
    foreach (a; from)
    {
        auto d = new double[pieces.length];
        double least = double.infinity;
        foreach (i, p; pieces)
        {
            d[i] = p is null || p.brep is null ? double.infinity : pointDistance(it.kernel, p.brep, a.o);
            least = min(least, d[i]);
        }
        foreach (i, p; pieces)
            if (d[i] < double.infinity && d[i] <= least + 1e-4)
                p.anchors ~= a;
    }
}

/// A reference to tag on a solid: a point, an Axis, a Plane or a Frame.
Anchor anchorOf(ref Args x, string name, string tag)
{
    auto v = x.get(name);
    Anchor a;
    a.tag = tag;
    if (v.kind == Kind.vec)
    {
        a.kind = AnchorKind.point;
        a.o = x.vecLen(name);
        return a;
    }
    if (isAxis(v))
    {
        a.kind = AnchorKind.axis;
        axisArg(x, name, a.o, a.z);
    }
    else if (v.kind == Kind.struct_ && v.st.def is planeDef)
    {
        a.kind = AnchorKind.plane;
        planeArg(x, name, a.o, a.z);
    }
    else if (v.kind == Kind.struct_ && v.st.def is frameDef)
    {
        a.kind = AnchorKind.frame;
        frameArg(x, name, a.o, a.x, a.y, a.z);
        return a;
    }
    else
        throw new HcadError(Code.type, format("at: is a point, an Axis, a Plane or a Frame to tag, not %s", v.typeName),
            x.spanOf(name));
    // an x and a y across the direction, as a plane's frame() has them (a frame read from it takes them anew)
    a.z = a.z.normalized;
    a.x = faceXAxis(a.z);
    a.y = a.z.cross(a.x);
    return a;
}

SolidVal primitive(Interp it, Brep b, string kind, Span span)
{
    auto r = new SolidVal(b, span);
    immutable id = it.addFeature(kind, span);
    r.creators = new uint[it.kernel.faceCount(b)];
    r.creators[] = id;
    it.features[id - 1].result = r;
    return r;
}

/// A result solid whose faces inherit the creators of the faces they come
/// from (kernel face history); new faces belong to a new feature.
SolidVal derived(Interp it, Brep b, SolidVal[] inputs, string kind, Span span, bool carry = true)
{
    auto r = new SolidVal(b, span);
    if (inputs.length)
    {
        r.rgb = inputs[0].rgb;
        r.hasColor = inputs[0].hasColor;
        r.flat = inputs[0].flat || (inputs[0].brep is null && inputs.length > 1 && inputs[1].flat);
        // a path moved, turned or mirrored is still a path; a surface, a surface
        r.path = inputs.length == 1 && inputs[0].path;
        r.surface = inputs.length == 1 && inputs[0].surface;
        // a profile drawn on a face stays there: moved, combined, offset in its plane
        foreach (input; inputs)
            if (r.flat && input !is null && input.flat && input.placed && !r.placed)
            {
                r.placed = true;
                r.place = input.place;
            }
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
    inheritTags(it, r, b, inputs, origins);
    // a profile made from profiles: the tags of their sketches' lines and circles on the edges lying where
    // those were (what a boolean or pieces leaves of them)
    bool[2] profile;   // known, and whether r is a profile (r.flat may be its input's still: an extrusion)
    bool isProfile()
    {
        if (!profile[0])
            profile = [true, r.flat && it.kernel.solids(b).length == 0];
        return profile[1];
    }
    if (carry && r.flat && inputs.any!(i => i !is null && i.edgeTags.length) && isProfile())
        foreach (input; inputs)
            if (input !is null && input.flat && input.brep !is null && input.edgeTags.length)
                r.edgeTags = carryEdgeTags(it.kernel, input.brep, input.edgeTags, b, 0, r.edgeTags);
    // the names of sketch lines and circles it could not keep: told when a face so tagged is looked for
    lostEdgeTagsOf(r, inputs, kind);
    if (r.lostEdgeTags.length)
        keptEdgeTags(r, isProfile());
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
        // made from a profile or a path: what that came from (Edit sketch… on a face)
        foreach (input; inputs)
            if (input !is null && (input.flat || input.path))
                foreach (c; input.creators)
                    if (c > 0 && !it.features[created - 1].from.canFind(c))
                        it.features[created - 1].from ~= c;
    }
    return r;
}

/// The tags of a result: the solid's own those of the first input (what it was made from, or the
/// body cut or added to), each face's those of the faces it comes from, all of them when it was made
/// of several (two faces merged into one); the faces it made new from a profile or a path, the tags
/// of that profile's or path's faces.
private void inheritTags(Interp it, SolidVal r, Brep b, SolidVal[] inputs, const(FaceOrigin)[] origins)
{
    if (inputs.length == 0)
        return;
    if (inputs[0] !is null)
        r.tags = inputs[0].tags;
    // the references of all of them: a hole's axis stays when it is cut; those of a copy joined to
    // itself, once
    foreach (input; inputs)
        if (input !is null && input.anchors.length)
            r.anchors ~= input.anchors;
    if (inputs.length > 1)
        r.anchors = mergeAnchors(r.anchors);
    bool any;
    string[] fromProfiles;
    auto fromEdges = it.kernel.faceFromEdges(b);
    foreach (input; inputs)
        if (input !is null && input.edgeTags.length && fromEdges.length)
            any = true;
    foreach (input; inputs)
        if (input !is null && input.faceTags.length)
        {
            any = true;
            if (input.flat || input.path)
                foreach (t; input.faceTags)
                    fromProfiles = tagUnion(fromProfiles, t);
        }
    if (!any)
        return;
    const(string)[] tagsOf(FaceOrigin o)
    {
        if (o.input < 0 || o.input >= inputs.length || inputs[o.input] is null)
            return null;
        auto from = inputs[o.input].faceTags;
        return o.index >= 0 && o.index < from.length ? from[o.index] : null;
    }
    r.faceTags = new string[][origins.length];
    foreach (i, o; origins)
        r.faceTags[i] = o.input < 0 ? fromProfiles : tagUnion(null, tagsOf(o));
    foreach (a; it.kernel.faceOriginsAlso(b))
        if (a.face >= 0 && a.face < r.faceTags.length)
            r.faceTags[a.face] = tagUnion(r.faceTags[a.face], tagsOf(a.origin));
    // the sides swept from a profile's tagged lines and circles
    foreach (a; fromEdges)
        if (a.face >= 0 && a.face < r.faceTags.length && a.origin.input >= 0 && a.origin.input < inputs.length
            && inputs[a.origin.input] !is null && a.origin.index < inputs[a.origin.input].edgeTags.length)
            r.faceTags[a.face] = tagUnion(r.faceTags[a.face], inputs[a.origin.input].edgeTags[a.origin.index]);
}

/// For results built anew (a hull, a Minkowski sum): each flat face of an input that has tags hands them to
/// the faces of `r` lying in its plane, facing the same way, moved `shift(input, normal)` along its normal
/// (to within `tol` mm, when the shift is measured on a mesh).
private void tagsByPlane(Interp it, SolidVal r, SolidVal[] inputs, double delegate(size_t, Vec3) shift,
    double tol = 0)
{
    auto k = it.kernel;
    FaceInfo[] made;
    foreach (ii, sv; inputs)
    {
        if (sv is null || sv.brep is null || sv.flat || !sv.faceTags.length)
            continue;
        if (made is null)
        {
            made = k.faces(r.brep);
            if (r.faceTags.length != made.length)
                r.faceTags = new string[][made.length];
        }
        auto own = k.faces(sv.brep);
        foreach (i, f; own)
        {
            if (i >= sv.faceTags.length || !sv.faceTags[i].length)
                continue;
            immutable off = f.center.dot(f.normal) + shift(ii, f.normal);
            foreach (j, g; made)
                if (g.normal.dot(f.normal) > 1 - 1e-9
                    && abs(g.center.dot(f.normal) - off) < max(tol, 1e-6 * (1 + abs(off))))
                    r.faceTags[j] = tagUnion(r.faceTags[j], sv.faceTags[i]);
        }
    }
}

/// The names of sketch lines and circles `inputs` hold (on their edges) or had lost, in r.lostEdgeTags as
/// lost by `kind` until r is found to hold them (keptEdgeTags).
void lostEdgeTagsOf(SolidVal r, SolidVal[] inputs, string kind)
{
    foreach (input; inputs)
        if (input !is null)
            foreach (i, t; input.lostEdgeTags)
                if (!r.lostEdgeTags.canFind(t))
                {
                    r.lostEdgeTags ~= t;
                    r.lostBy ~= input.lostBy[i];
                }
    foreach (input; inputs)
        if (input !is null)
            foreach (ts; input.edgeTags)
                foreach (t; ts)
                    if (!r.lostEdgeTags.canFind(t))
                    {
                        r.lostEdgeTags ~= t;
                        r.lostBy ~= kind;
                    }
}

/// `r` without the names of sketch lines and circles among those it lost (r.lostEdgeTags) that it holds
/// after all, on a profile's edges or a solid's faces.
void keptEdgeTags(SolidVal r)
{
    keptEdgeTags(r, r.flat);
}

/// The same, `r` a profile or not.
void keptEdgeTags(SolidVal r, bool profile)
{
    if (!r.lostEdgeTags.length)
        return;
    string[] present;
    foreach (t; profile ? r.edgeTags : r.faceTags)
        present = tagUnion(present, t);
    string[] tags, by;
    foreach (i, t; r.lostEdgeTags)
        if (!present.canFind(t))
        {
            tags ~= t;
            by ~= r.lostBy[i];
        }
    r.lostEdgeTags = tags;
    r.lostBy = by;
}

/// What lost a sketch line's name, in words (a feature kind: "offset", "hull").
string lostByWords(string kind)
{
    switch (kind)
    {
    case "extrude": return "an extrusion";
    case "round": return "round()";
    case "tiles": return "tiles";
    default: return ("aeiou".canFind(kind.length ? kind[0] : 'x') ? "an " : "a ") ~ kind;
    }
}

/// The tags `tags` of the edges of profile `from` on the edges of profile `to` that lie on them (a line on
/// the same line, within it; an arc on the same circle), or `distance` away from them when `to` is `from`
/// offset; added to `onto` (per edge of `to`, may be empty).
string[][] carryEdgeTags(BrepKernel k, Brep from, const(string[])[] tags, Brep to, double distance,
    string[][] onto = null)
{
    auto fe = k.edges(from), te = k.edges(to);
    auto r = onto.length == te.length ? onto.dup : new string[][te.length];
    immutable d = abs(distance);
    foreach (j, g; te)
        foreach (i, f; fe)
        {
            if (i >= tags.length || !tags[i].length || f.kind == EdgeKind.other || f.kind != g.kind && !(d == 0
                && g.kind == EdgeKind.other))
                continue;
            immutable tol = 1e-6 * (1 + f.mid.length + d);
            bool on;
            if (g.kind == EdgeKind.other)
            {
                // a curve the kernel made in place of a line or an arc (a twisted extrusion's): its ends and
                // middle on it
                on = true;
                foreach (q; [g.start, g.mid, g.end])
                    if (f.kind == EdgeKind.line)
                    {
                        auto u = f.end - f.start;
                        immutable t = (q - f.start).dot(u) / u.dot(u);
                        on = on && t > -tol && t < 1 + tol && (q - (f.start + u * t)).length < tol;
                    }
                    else
                        on = on && abs((q - f.center).length - f.radius) < tol && abs((q - f.center).dot(f.axis)) < tol;
            }
            else if (f.kind == EdgeKind.line)
            {
                auto u = f.end - f.start;
                immutable l = u.length;
                if (l < 1e-12 || g.direction.cross(u / l).length > 1e-6)
                    continue;
                immutable t = (g.mid - f.start).dot(u) / (l * l);
                auto across = g.mid - (f.start + u * t);
                // within it, as far from it as the offset (lines offset keep their length; a cut one is shorter)
                on = t > -tol && t < 1 + tol && abs(across.length - d) < tol;
            }
            else if (f.kind == EdgeKind.circle)
                on = (g.center - f.center).length < tol && g.axis.cross(f.axis).length < 1e-6
                    && abs(abs(g.radius - f.radius) - d) < tol;
            if (on)
                r[j] = tagUnion(r[j], tags[i]);
        }
    foreach (t; r)
        if (t.length)
            return r;
    return onto.length == te.length ? onto : null;
}

/// `a` with the tags of `b` it does not have, in order.
string[] tagUnion(const(string)[] a, const(string)[] b)
{
    string[] r = a.dup;
    foreach (t; b)
        if (!r.canFind(t))
            r ~= t;
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

/// region.tiles(kind: "hex", size: 8.mm, gap: 1.mm): the region filled with
/// cells, each shrunk to leave `gap` between neighbours (see reference.d).
Value tilesOf(Interp it, ref CallArgs a)
{
    import hackerscad.geom.tiling : Motif, Poly, motif, shrinkConvex, voronoi, scatter, tilingKinds;
    import std.range : iota;
    import std.math : cos, sin, sqrt;
    auto k = it.kernel;
    auto x = Args(it, a, "tiles", ["region", "kind", "size", "gap", "round", "angle", "tile", "step", "origin",
        "whole", "scale", "keep", "seed", "jitter", "relax", "points"]);
    auto region = profileArg(x, "region");
    // a region drawn on a face or lying in another plane: tiled in that plane's coordinates, the tiles left there
    Vec3[4] frame;
    immutable lies = liesOf(it, region, x.spanOf("region"), frame);
    auto area = lies == Lies.tilted ? fromPlace(k, frame, region.brep) : nonEmpty(region, x.spanOf("region"));
    immutable bb = k.bbox(area);
    immutable gap = x.lenOr("gap", 0), rnd = x.lenOr("round", 0), ang = x.angleOr("angle", 0);
    if (gap < 0 || rnd < 0)
        throw new HcadError(Code.type, "gap and round cannot be negative", a.span);
    immutable custom = x.has("tile");
    immutable kind = x.has("kind") ? x.get("kind").s : custom ? "tile" : x.has("points") ? "voronoi" : "hex";
    if (custom && x.has("kind"))
        throw new HcadError(Code.unknownArg, "give either a kind or your own tile:, not both", x.spanOf("kind"));
    if (!custom && kind != "voronoi" && !tilingKinds.canFind(kind))
        throw new HcadError(Code.type, format("the tiling kind is one of %-(\"%s\", %)\" or \"voronoi\" (or give tile: and step:)",
            tilingKinds), x.spanOf("kind"));
    if (!custom && !x.has("size") && !x.has("points"))
        throw new HcadError(Code.missingArg, "tiles needs size: (the distance between neighbouring cells)", a.span);
    immutable size = x.lenOr("size", 0);
    if (x.has("size") && !(size > 0))
        throw new HcadError(Code.type, "the size must be greater than 0", x.spanOf("size"));
    immutable ca = cos(ang), sa = sin(ang);
    double[2] turn(double[2] p) => [p[0] * ca - p[1] * sa, p[0] * sa + p[1] * ca];
    Vec3 origin = x.has("origin") ? x.vecLen("origin")
        : Vec3((bb.min.x + bb.max.x) / 2, (bb.min.y + bb.max.y) / 2, 0);

    // a scale and a choice for each cell, from its centre
    double scaleAt(double cx, double cy)
    {
        if (!x.has("scale"))
            return 1;
        auto f = x.get("scale");
        auto v = f.isCallable ? call1(it, f, Value.vector(Vec3(cx, cy, 0), 2, Dim.length), x.spanOf("scale")) : f;
        if (!v.isNum || v.n.dim != Dim.none)
            throw new HcadError(Code.type, "scale: a plain number, or a function of the cell's centre giving one",
                x.spanOf("scale"));
        return v.n.value < 0 ? 0 : v.n.value;
    }
    bool keepAt(double cx, double cy)
    {
        if (!x.has("keep"))
            return true;
        auto v = call1(it, x.get("keep"), Value.vector(Vec3(cx, cy, 0), 2, Dim.length), x.spanOf("keep"));
        if (v.kind != Kind.bool_)
            throw new HcadError(Code.type, "keep: a function of the cell's centre giving true or false", x.spanOf("keep"));
        return v.b;
    }
    Brep rounded(Brep b, bool must)
    {
        if (rnd <= 0)
            return b;
        try
            return k.profileRound(b, rnd);
        catch (KernelException e)
        {
            if (must)
                throw new HcadError(Code.kernel, format("round: %s mm is too much for the tile, once shrunk by the gap: %s",
                    rnd, e.msg), x.spanOf("round"));
            return b;   // a small Voronoi cell stays sharp
        }
    }

    Brep[] motifs;
    double[] place;
    double[2] ea, eb;   // the lattice's steps
    if (kind == "voronoi")
    {
        // the points: given, or scattered over the region and a cell beyond
        double[2][] sites;
        double spacing = size;
        immutable x0 = bb.min.x - 2 * size, y0 = bb.min.y - 2 * size, x1 = bb.max.x + 2 * size, y1 = bb.max.y + 2 * size;
        if (x.has("points"))
        {
            auto pv = x.get("points");
            if (pv.kind != Kind.array || pv.arr.length < 2)
                throw new HcadError(Code.type, "points: a list of at least two points", x.spanOf("points"));
            foreach (q; pv.arr)
            {
                auto v = q.kind == Kind.array ? arrayToVec(it, q.arr, a.caller, x.spanOf("points")) : q;
                if (v.kind != Kind.vec)
                    throw new HcadError(Code.type, "points: vectors", x.spanOf("points"));
                immutable f = v.v.dim == Dim.none ? x.unitFactor : 1;
                sites ~= [v.v.v.x * f, v.v.v.y * f];
            }
        }
        else
        {
            immutable jitter = x.has("jitter") ? x.num("jitter") : 1;
            immutable relax = x.has("relax") ? cast(int) x.num("relax") : 0;
            if (jitter < 0 || jitter > 1 || relax < 0 || relax > 20)
                throw new HcadError(Code.type, "jitter goes from 0 (hexagons) to 1, relax from 0 to 20", a.span);
            sites = scatter(x0, y0, x1, y1, size, jitter, relax, x.has("seed") ? cast(long) x.num("seed") : 0);
        }
        if (sites.length > 20_000)
            throw new HcadError(Code.type, format("%s cells: more than 20 000, make them larger", sites.length), a.span);
        double vx0 = x0, vy0 = y0, vx1 = x1, vy1 = y1;
        foreach (sp; sites)
        {
            vx0 = min(vx0, sp[0] - 1), vy0 = min(vy0, sp[1] - 1);
            vx1 = max(vx1, sp[0] + 1), vy1 = max(vy1, sp[1] + 1);
        }
        auto cells = voronoi(sites, vx0, vy0, vx1, vy1, gap);
        foreach (i, c; cells)
        {
            if (c.length < 3 || !keepAt(sites[i][0], sites[i][1]))
                continue;
            immutable sc = scaleAt(sites[i][0], sites[i][1]);
            if (sc <= 0)
                continue;
            double[] xy;
            foreach (q; c)
                xy ~= [q[0] - sites[i][0], q[1] - sites[i][1]];
            Brep m;
            try
                m = rounded(k.polygon(xy), false);
            catch (KernelException)
                continue;   // a sliver
            place ~= [cast(double) motifs.length, sites[i][0], sites[i][1], sc];
            motifs ~= m;
        }
    }
    else
    {
        Brep[] base;
        if (custom)
        {
            // your own tile: one profile or several, repeated by step: [a, b]
            auto tv = x.get("tile");
            Value[] parts = tv.kind == Kind.array ? tv.arr : [tv];
            foreach (pv; parts)
            {
                if (pv.kind != Kind.solid || !pv.solid.flat)
                    throw new HcadError(Code.type, "tile: a profile, or a list of profiles", x.spanOf("tile"));
                requireXY(it, pv.solid, x.spanOf("tile"));
                Brep b = pv.solid.brep;
                if (gap > 0)
                {
                    try
                        b = k.profileOffset(b, -gap / 2);
                    catch (KernelException e)
                        throw new HcadError(Code.kernel, format("the tile cannot shrink by half the gap (%s mm): %s",
                            gap / 2, e.msg), x.spanOf("gap"));
                }
                base ~= rounded(b, true);
            }
            if (!x.has("step"))
                throw new HcadError(Code.missingArg, "your own tile needs step: [a, b], the two steps it repeats by",
                    x.spanOf("tile"));
            auto st = x.get("step");
            if (st.kind != Kind.array || st.arr.length != 2)
                throw new HcadError(Code.type, "step: two vectors, [vec(…), vec(…)]", x.spanOf("step"));
            double[2][2] steps;
            foreach (i, sv; st.arr)
            {
                auto v = sv.kind == Kind.array ? arrayToVec(it, sv.arr, a.caller, x.spanOf("step")) : sv;
                if (v.kind != Kind.vec)
                    throw new HcadError(Code.type, "step: two vectors, [vec(…), vec(…)]", x.spanOf("step"));
                immutable f = v.v.dim == Dim.none ? x.unitFactor : 1;
                steps[i] = [v.v.v.x * f, v.v.v.y * f];
            }
            ea = steps[0], eb = steps[1];
            if (abs(ea[0] * eb[1] - ea[1] * eb[0]) < 1e-9)
                throw new HcadError(Code.type, "the two steps lie along one line: they repeat nothing across",
                    x.spanOf("step"));
            // the one requirement: the copies (shrunk by the gap) must not overlap
            Brep all = base.length == 1 ? base[0] : k.tiles(base, iota(base.length).map!(i => [cast(double) i, 0, 0, 1])
                .join, null, 0);
            double sum = 0;
            foreach (b; base)
                sum += k.area(b);
            if (base.length > 1 && abs(k.area(k.fuseAll(base)) - sum) > 1e-6 * sum + 1e-9)
                throw new HcadError(Code.type, "the tile's profiles overlap one another", x.spanOf("tile"));
            foreach (i; -2 .. 3)
                foreach (j; -2 .. 3)
                {
                    if (i < 0 || (i == 0 && j <= 0))
                        continue;   // each pair once
                    auto moved = k.translate(all, Vec3(i * ea[0] + j * eb[0], i * ea[1] + j * eb[1], 0));
                    auto ov = k.boolean(all, moved, BoolOp.common);
                    immutable o = ov is null ? 0 : k.area(ov);
                    if (o > 1e-6 * sum + 1e-9)
                        throw new HcadError(Code.type, format("the tiles overlap (by %.3g mm² between one and the one "
                            ~ "%s·a %s %s·b from it): a larger step, a smaller tile or a wider gap", o, i,
                            j < 0 ? "-" : "+", abs(j)), x.spanOf("tile"));
                }
            if (ang != 0)
            {
                foreach (ref b; base)
                    b = k.rotate(b, Vec3(0, 0, 1), ang);
                ea = turn(ea), eb = turn(eb);
            }
        }
        else
        {
            Motif m;
            motif(kind, size, m);
            foreach (p; m.polys)
            {
                auto q = shrinkConvex(p, gap / 2);
                if (q is null)
                    throw new HcadError(Code.type, format("a gap of %s mm leaves nothing of %s cells %s mm across",
                        gap, kind, size), x.spanOf("gap"));
                double[] xy;
                foreach (c; q)
                    xy ~= turn(c)[];
                base ~= rounded(k.polygon(xy), true);
            }
            ea = turn(m.a), eb = turn(m.b);
        }
        // the lattice points whose tiles can reach the region
        double reach = 0;
        foreach (b; base)
        {
            immutable tb = k.bbox(b);
            reach = max(reach, abs(tb.min.x), abs(tb.max.x), abs(tb.min.y), abs(tb.max.y));
        }
        reach *= sqrt(2.0);
        immutable det = ea[0] * eb[1] - ea[1] * eb[0];
        double imin = double.infinity, imax = -double.infinity, jmin = double.infinity, jmax = -double.infinity;
        foreach (cx; [bb.min.x - reach, bb.max.x + reach])
            foreach (cy; [bb.min.y - reach, bb.max.y + reach])
            {
                immutable dx = cx - origin.x, dy = cy - origin.y;
                immutable fi = (dx * eb[1] - dy * eb[0]) / det, fj = (ea[0] * dy - ea[1] * dx) / det;
                imin = min(imin, fi), imax = max(imax, fi), jmin = min(jmin, fj), jmax = max(jmax, fj);
            }
        if ((imax - imin) * (jmax - jmin) * base.length > 40_000)
            throw new HcadError(Code.type, "more than 20 000 tiles: make them larger", a.span);
        motifs = base;
        foreach (i; cast(long) floor(imin) .. cast(long) ceil(imax) + 1)
            foreach (j; cast(long) floor(jmin) .. cast(long) ceil(jmax) + 1)
            {
                immutable px = origin.x + i * ea[0] + j * eb[0], py = origin.y + i * ea[1] + j * eb[1];
                if (px < bb.min.x - reach || px > bb.max.x + reach || py < bb.min.y - reach || py > bb.max.y + reach)
                    continue;
                if (!keepAt(px, py))
                    continue;
                immutable sc = scaleAt(px, py);
                if (sc <= 0)
                    continue;
                foreach (mi; 0 .. base.length)
                    place ~= [cast(double) mi, px, py, sc];
            }
    }
    if (place.length == 0)
        throw new HcadError(Code.type, "no tile is left (keep: or scale: dropped them all?)", a.span);
    try
    {
        // a sliver the border cuts off a cell: under 2% of a cell, left out
        double cell = 0;
        foreach (mo; motifs)
            cell += k.area(mo);
        cell /= motifs.length;
        // with no gap the cells touch: joined into one area, or they make no valid profile
        auto made = k.tiles(motifs, place, area, (x.flag("whole", false) ? 2 : 1) | (gap > 0 ? 0 : 4), 0.02 * cell);
        if (lies == Lies.tilted)
            made = toPlace(k, frame, made);
        return Value.of(liesAs(flatResult(Value.of(primitive(it, made, "tiles", a.span))), lies, frame));
    }
    catch (KernelException e)
        throw new HcadError(Code.kernel, e.msg, a.span);
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

/// The depth of a profile cut into or raised from a face: always positive, the way given by the
/// call (cut digs in, extrude raises), so a sign never quietly turns one into the other.
void checkFaceDepth(double depth, bool remove, Span span)
{
    if (depth == 0)
        throw new HcadError(Code.type, "depth must not be zero", span);
    if (!(depth > 0))
        throw new HcadError(Code.type, remove
            ? "depth must be greater than 0: cut digs the profile into the face; to raise it, use extrude"
            : "depth must be greater than 0: extrude raises the profile from the face; to dig it in, use cut", span);
}

/// body.extrude(profile, on:, depth:) adds material outwards from a face;
/// body.cut(profile, on:, depth: | through: true) removes it inwards.
Value onFace(Interp it, ref CallArgs a, bool remove)
{
    auto k = it.kernel;
    immutable fn = remove ? "cut" : "extrude";
    auto x = Args(it, a, fn, ["solid", "profile", "on", "at", "depth", "through", "taper", "wrap", "project", "along"]);
    auto body = x.solid("solid");
    if (x.has("wrap") || x.has("project"))
        return onCurvedFace(it, a, x, body, remove);
    if (x.has("along"))
        throw new HcadError(Code.type, "along: is the direction of project:", x.spanOf("along"));
    // a solid as the tool: built on XY, its z = 0 brought onto the face and +Z out of it (a hole()
    // from the hardware library, which goes down from z = 0, cuts into the material)
    auto given = x.get("profile");
    // s.extrude(2.mm) on what is a solid already (a hull of profiles in two planes is one)
    if (given.isNum)
        throw new HcadError(Code.type, format("this is a %s, not a profile: a profile is extruded by a height, a "
            ~ "solid %s a profile on one of its faces (%s(profile, on: faces.top, depth: …)) or pushes its faces "
            ~ "(%s(faces.top, depth: …))", body.brep is null ? "Solid (empty)" : "Solid", remove ? "cuts" : "adds",
            fn, fn), x.spanOf("profile"));
    immutable solidTool =given.kind == Kind.solid && !given.solid.flat && !given.solid.path && !given.solid.surface;
    if (solidTool && !x.has("on"))
        throw new HcadError(Code.type, format("%s with a solid needs on: the face or frame to place it on", fn),
            x.spanOf("profile"));
    if (solidTool)
        foreach (n; ["depth", "through", "taper"])
            if (x.has(n))
                throw new HcadError(Code.type, format("'%s' is for a profile: a solid tool is cut as it is", n),
                    x.spanOf(n));
    auto p = solidTool ? given.solid : profileArg(x, "profile");
    // a profile drawn on a face, or lying in another plane (a section, its tiles): where it lies
    Vec3[4] where;
    immutable lies = solidTool ? Lies.onXY : liesOf(it, p, a.span, where);
    Vec3 o, ax, ay, az;
    if (lies != Lies.onXY && x.has("on"))
        throw new HcadError(Code.type, format("this profile %s: it is already where it goes, leave on: out",
            lies == Lies.placed ? "was drawn on a face (its sketch's)" : "lies in a plane of its own (a section?)"),
            x.spanOf("on"));
    if (lies != Lies.onXY)
    {
        o = where[0];
        ax = where[1];
        ay = where[2];
        az = where[3];
        if (x.has("at"))
            throw new HcadError(Code.type, "this profile lies where it was drawn: place it in its sketch (or move "
                ~ "it), not with at:", x.spanOf("at"));
    }
    else if (x.has("on"))
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
            ax = faceXAxis(az);
            ay = az.cross(ax);
        }
        else if (v.kind == Kind.struct_ && v.st.def is planeDef)
        {
            planeArg(x, "on", o, az);
            ax = faceXAxis(az);
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
    if (solidTool)
    {
        Vec3 turnAxis;
        immutable turn = axisAngle(ax, ay, az, turnAxis);
        auto moved = transformed(it, a.span, p, (Brep b) {
            if (turn > 1e-12)
                b = k.rotate(b, turnAxis, turn);
            return k.translate(b, o);
        });
        return solidBoolean(it, body, moved.solid, remove ? BoolOp.cut : BoolOp.fuse, a.span);
    }
    double depth;
    if (x.flag("through", false))
    {
        if (!remove)
            throw new HcadError(Code.type, "through: is for cut()", x.spanOf("through"));
        // as far in as the body goes behind the face, and a millimetre more: no further, or a taper
        // would close the outline up long before the tool's end
        auto bb = k.bbox(nonEmpty(body, a.span));
        double behind = 0;
        foreach (i; 0 .. 8)
        {
            immutable q = Vec3(i & 1 ? bb.max.x : bb.min.x, i & 2 ? bb.max.y : bb.min.y, i & 4 ? bb.max.z : bb.min.z);
            behind = max(behind, (o - q).dot(az));
        }
        depth = behind + 1;
    }
    else
    {
        depth = x.len("depth");
        checkFaceDepth(depth, remove, x.spanOf("depth"));
    }
    immutable taper = x.angleOr("taper", 0);
    auto tool = derived(it, k.extrude(lies == Lies.tilted ? fromPlace(k, where, p.brep) : nonEmpty(p, a.span),
        remove ? -depth : depth, taper), [p], fn, a.span);
    tool.flat = false;
    tool.placed = false;
    // a tilted profile's references lie where it lies: brought into its plane's coordinates with it
    if (lies == Lies.tilted && tool.anchors.length)
        tool.anchors = mapAnchors(it, (Brep q) => fromPlace(k, where, q), tool.anchors, a.span);
    Vec3 axis;
    immutable angle = axisAngle(ax, ay, az, axis);
    auto placed = transformed(it, a.span, tool, (Brep b) {
        if (angle > 1e-12)
            b = k.rotate(b, axis, angle);
        return k.translate(b, o);
    });
    // a boss on a face with the whole body behind that face's plane: it can touch the body only
    // there, so it is joined by hand (that face holed, the two sewn), ten times quicker than the
    // fuse on a body of many faces; anything else, and a profile not inside the face, the fuse
    if (!remove && taper >= 0 && body.brep !is null)
    {
        immutable bb = k.bbox(body.brep);
        double ahead = -double.infinity;
        foreach (i; 0 .. 8)
        {
            immutable q = Vec3(i & 1 ? bb.max.x : bb.min.x, i & 2 ? bb.max.y : bb.min.y, i & 4 ? bb.max.z : bb.min.z);
            ahead = max(ahead, (q - o).dot(az));
        }
        if (ahead <= 1e-7 * (1 + bb.size.length))
            try
                return Value.of(derived(it, k.joinTouching(body.brep, placed.solid.brep), [body, placed.solid], "union",
                    a.span));
            catch (KernelException)
            {
            }
    }
    return solidBoolean(it, body, placed.solid, remove ? BoolOp.cut : BoolOp.fuse, a.span);
}

/// body.knurl(faces.…, kind: "diamond", pitch: 1.6.mm, depth: 0.5.mm): a grip raised on a face of any shape,
/// diamonds, straight ridges along it or slanted ones, laid on the face as wrap: does; round a face that
/// closes on itself (a cylinder, a vase's side) a whole number of them, so the pattern closes too.
Value knurlOf(Interp it, ref CallArgs a)
{
    import std.math : PI, tan, round, abs, floor, ceil;
    import std.algorithm : max;
    auto k = it.kernel;
    auto x = Args(it, a, "knurl", ["solid", "face", "kind", "pitch", "depth", "angle", "margin"]);
    auto body = x.solid("solid");
    auto idx = resolveSelector(it, x.selector("face", true), body, x.spanOf("face"));
    if (idx.length != 1)
        throw new HcadError(Code.type, format("knurl needs exactly one face, the selector matched %d", idx.length),
            x.spanOf("face"));
    immutable kind = x.has("kind") ? x.get("kind").s : "diamond";
    if (!["diamond", "straight", "diagonal"].canFind(kind))
        throw new HcadError(Code.type, "the knurl is \"diamond\", \"straight\" or \"diagonal\"", x.spanOf("kind"));
    immutable depth = x.lenOr("depth", 0.5), margin = x.lenOr("margin", 0.5), slant = x.angleOr("angle", 30 * PI / 180);
    if (!(depth > 0) || margin < 0 || !(slant > 0 && slant < PI / 2))
        throw new HcadError(Code.type, "knurl: depth above 0, margin not below 0, angle between 0 and 90°", a.span);
    immutable pitch = x.lenOr("pitch", 1.6);

    // where the cells go: the face unrolled flat as wrap: lays a profile on it, `margin` in from its edges;
    // round a face that closes on itself, the length once round (a hair less, so the pattern does not
    // run onto itself where it closes), and margin in from the edges it has
    Brep region;
    double round_ = 0;
    Vec3 middle;
    CylinderInfo cyl;
    if (k.faceCylinder(nonEmpty(body, a.span), idx[0], cyl) && cyl.span >= 2 * PI - 1e-6)
    {
        round_ = 2 * PI * cyl.radius;
        // where the face's own parameters have their middle, for the anchor
        middle = Vec3(double.nan, double.nan, double.nan);
        try
        {
            double r;
            k.wrapFlat(body.brep, idx[0], Vec3(double.nan, double.nan, double.nan), r, middle);
        }
        catch (KernelException)
        {
        }
        immutable high = abs(cyl.to - cyl.from) - 2 * margin;
        if (!(high > 0))
            throw new HcadError(Code.type, "knurl: the face is not taller than twice its margin", x.spanOf("face"));
        region = k.rect(round_ - 1e-3, high);
    }
    else
    {
        Brep flat;
        try
        {
            // unrolled where the knurl will be anchored: round a face that closes on itself the middle of its
            // parameters (lengths along it are measured from there)
            flat = k.wrapFlat(body.brep, idx[0], Vec3(double.nan, double.nan, double.nan), round_, middle);
            if (round_ > 0 && middle == middle)
                flat = k.wrapFlat(body.brep, idx[0], middle, round_, middle);
        }
        catch (KernelException e)
            throw new HcadError(Code.kernel, "knurl: the face cannot be unrolled: " ~ e.msg, x.spanOf("face"));
        if (round_ > 0)
        {
            immutable fb = k.bbox(flat);
            immutable high = fb.size.y - 2 * margin;
            if (!(high > 0))
                throw new HcadError(Code.type, "knurl: the face is not taller than twice its margin", x.spanOf("face"));
            region = k.translate(k.rect(round_ - 1e-3, high), Vec3(0, fb.center.y, 0));
        }
        else
        {
            try
                region = margin > 0 ? k.profileOffset(flat, -margin) : flat;
            catch (KernelException e)
                throw new HcadError(Code.kernel, "knurl: the face is too small for its margin", x.spanOf("face"));
        }
    }
    immutable rb = k.bbox(region);
    // a whole number of them round a face that closes on itself: the pattern closes where the face does
    int n = 0;
    if (round_ > 0)
    {
        n = cast(int) round(round_ / pitch);
        if (n < 6)
            throw new HcadError(Code.type, "knurl: the pitch leaves fewer than 6 round the face", x.spanOf("pitch"));
    }
    immutable double p = round_ > 0 ? round_ / n : pitch, rise = p / tan(slant);
    immutable double yc = rb.center.y, high = rb.size.y;
    Brep tile;
    double[2][2] step;
    final switch (kind)
    {
    case "diamond":
        // a rhombus, its diagonals the pitch round and the rise along: a groove a third of the pitch between
        tile = k.polygon([-p / 3, 0, 0, -rise / 3, p / 3, 0, 0, rise / 3]);
        step = [[p, 0], [p / 2, rise / 2]];
        break;
    case "straight":
        tile = k.polygon([-p / 4, yc - high, p / 4, yc - high, p / 4, yc + high, -p / 4, yc + high]);
        step = [[p, 0], [0, 4 * high]];
        break;
    case "diagonal":
        {
            // a ridge leaning at the angle from the face's length
            immutable double lean = 2 * high * tan(slant);
            tile = k.polygon([-p / 4 - lean / 2, yc - high, p / 4 - lean / 2, yc - high, p / 4 + lean / 2, yc + high,
                -p / 4 + lean / 2, yc + high]);
            step = [[p, 0], [0, 4 * high]];
            break;
        }
    }
    // the cells over the region, a lattice from the anchor, cut at the region's edges: every one that
    // reaches into it, a slanted ridge from as far aside as it leans
    immutable reachJ = kind == "diamond" ? cast(long) ceil(max(abs(rb.min.y), abs(rb.max.y)) / (rise / 2)) + 2 : 0;
    immutable aside = p + (kind == "diagonal" ? high * tan(slant) + abs(yc) * tan(slant) : 0.0);
    immutable reachI = cast(long) ceil((max(abs(rb.min.x), abs(rb.max.x)) + aside) / p) + reachJ / 2 + 4;
    double[] place;
    foreach (i; -reachI .. reachI + 1)
        foreach (j; -reachJ .. reachJ + 1)
        {
            immutable px = i * step[0][0] + j * step[1][0], py = i * step[0][1] + j * step[1][1];
            if (px < rb.min.x - aside || px > rb.max.x + aside)
                continue;
            place ~= [0.0, px, py, 1.0];
        }
    Brep cells;
    try
        cells = k.tiles([tile], place, region, 1, 0);
    catch (KernelException e)
        throw new HcadError(Code.kernel, "knurl: " ~ e.msg, a.span);
    // round a face that closes on itself, anchored at the middle of its parameters: the pattern closes
    // where the face's own seam is, so the face itself is holed, its edges shared with the faces round it
    // (none to sew there); elsewhere where wrap: lays a profile by default
    immutable nan = Vec3(double.nan, double.nan, double.nan);
    immutable anchor = round_ > 0 && middle == middle ? middle : nan;
    try
        return Value.of(derived(it, k.wrapDirect(body.brep, idx[0], cells, false, anchor, Vec3(0, 0, 0), depth), [body],
            "knurl", a.span));
    catch (KernelException)
    {
    }
    try
    {
        auto tool = k.wrapTool(body.brep, idx[0], cells, false, anchor, Vec3(0, 0, 0), -0.01, depth);
        return Value.of(derived(it, k.fuseAll(body.brep ~ k.solids(tool)), [body], "knurl", a.span));
    }
    catch (KernelException e)
        throw new HcadError(Code.kernel, "knurl: " ~ e.msg, a.span);
}

/// body.cut(profile, wrap: faces.…, depth:) and project:: the profile laid on a face of any shape,
/// rolled onto it (wrap, its lengths kept along the face) or carried along a direction (project, from
/// the plane touching the face), then dug in or raised `depth` along the face's normal.
Value onCurvedFace(Interp it, ref CallArgs a, ref Args x, SolidVal body, bool remove)
{
    auto k = it.kernel;
    immutable fn = remove ? "cut" : "extrude";
    if (x.has("wrap") && x.has("project"))
        throw new HcadError(Code.unknownArg, "give either wrap: or project:, not both", x.spanOf("project"));
    foreach (n; ["on", "through", "taper"])
        if (x.has(n))
            throw new HcadError(Code.type, format("'%s' does not go with wrap: or project:", n), x.spanOf(n));
    immutable project = x.has("project");
    immutable what = project ? "project" : "wrap";
    if (x.has("along") && !project)
        throw new HcadError(Code.type, "along: is the direction of project:", x.spanOf("along"));
    auto p = profileArg(x, "profile");
    requireXY(it, p, a.span);
    auto idx = resolveSelector(it, x.selector(what, true), body, x.spanOf(what));
    if (idx.length != 1)
        throw new HcadError(Code.type, format("'%s' needs exactly one face, the selector matched %d", what, idx.length),
            x.spanOf(what));
    immutable depth = x.len("depth");
    checkFaceDepth(depth, remove, x.spanOf("depth"));
    immutable at = x.has("at") ? x.vecLen("at") : Vec3(double.nan, double.nan, double.nan);
    immutable dir = x.has("along") ? x.dir("along") : Vec3(0, 0, 0);
    // first built at once, the face holed and the floors sewn in, with no boolean: quicker, and sound
    // where a boolean against curved faces fails; a region not inside the face takes the boolean way
    import std.process : environment;
    void skipped()
    {
        if (immutable n = k.wrapSkipped())
            it.diagnostics ~= Diagnostic(Severity.warning, Code.kernel, format("%s: %s of the profile's regions could "
                ~ "not be laid on the face (a sliver, a tiny arc) and %s left out", what, n, n == 1 ? "was" : "were"),
                a.span);
    }
    // a little beyond the face on the side away from the material, so the two do not share a surface
    immutable over = 0.01;
    if (environment.get("HCAD_WRAP_DIRECT", "1") != "0")
    {
        // the regions that run off the face (a cell of a tiling cut at its edge, a letter over it) take
        // the boolean way on their own, the rest built at once: one region off the face no longer sends
        // them all the slow way
        try
        {
            int regions;
            auto off = k.wrapOutside(nonEmpty(body, a.span), idx[0], nonEmpty(p, a.span), project, at, dir,
                remove ? -depth : depth, regions);
            if (off.length > 0 && off.length < regions)
            {
                int[] on;
                foreach (i; 0 .. regions)
                    if (!off.canFind(i))
                        on ~= i;
                auto r = k.wrapDirect(body.brep, idx[0], k.profileRegions(p.brep, on), project, at, dir,
                    remove ? -depth : depth);
                skipped();
                auto tool = k.wrapTool(body.brep, idx[0], k.profileRegions(p.brep, off), project, at, dir,
                    remove ? -depth : -over, remove ? over : depth);
                skipped();
                auto parts = k.solids(tool);
                auto joined = remove ? k.cutAll(r, parts) : k.fuseAll(r ~ parts);
                return Value.of(derived(it, joined, [body, p], fn, a.span));
            }
        }
        catch (KernelException e)
        {
            if (environment.get("HCAD_WRAP_DEBUG"))
                it.diagnostics ~= Diagnostic(Severity.warning, Code.kernel, "split: " ~ e.msg, a.span);
        }
        try
        {
            auto r = k.wrapDirect(nonEmpty(body, a.span), idx[0], nonEmpty(p, a.span), project, at, dir,
                remove ? -depth : depth);
            skipped();
            return Value.of(derived(it, r, [body, p], fn, a.span));
        }
        catch (KernelException e)
        {
            // why the direct way was not taken, for whoever works on it
            if (environment.get("HCAD_WRAP_DEBUG"))
                it.diagnostics ~= Diagnostic(Severity.warning, Code.kernel, e.msg, a.span);
        }
    }
    Brep tool;
    try
        tool = k.wrapTool(nonEmpty(body, a.span), idx[0], nonEmpty(p, a.span), project, at, dir,
            remove ? -depth : -over, remove ? over : depth);
    catch (KernelException e)
        throw new HcadError(Code.kernel, format("%s: %s", what, e.msg), a.span);
    skipped();
    auto t = derived(it, tool, [p], fn, a.span);
    t.flat = false;
    // the regions all in one boolean: a fuse with a compound of several leaves them out
    auto parts = k.solids(tool);
    if (parts.length > 1)
        try
            return Value.of(derived(it, remove ? k.cutAll(body.brep, parts) : k.fuseAll(body.brep ~ parts), [body, t],
                remove ? "cut" : "union", a.span));
        catch (KernelException)
        {
        }
    return solidBoolean(it, body, t, remove ? BoolOp.cut : BoolOp.fuse, a.span);
}

/// Whether an extrude() or cut() of a solid is given faces of it (a push
/// or pull) rather than a profile.
bool pushesFace(ref CallArgs a)
{
    if (a.positional.length >= 2)
        return a.positional[1].kind == Kind.selector;
    return ("faces" in a.named) !is null;
}

/// body.extrude(faces.top, depth: 5.mm) grows flat faces outwards along
/// their normals; body.cut(faces.top, depth: 2.mm) sinks them (as does a
/// negative depth to extrude). `along:` sweeps them in another direction,
/// slanted: material is added when it points out of the face, removed
/// when it points in.
Value pushFace(Interp it, ref CallArgs a, bool remove)
{
    auto k = it.kernel;
    immutable fn = remove ? "cut" : "extrude";
    auto x = Args(it, a, fn, ["solid", "faces", "depth", "along"]);
    auto body = x.solid("solid");
    auto idx = resolveSelector(it, x.selector("faces", true), body, x.spanOf("faces"));
    if (idx.length == 0)
        throw new HcadError(Code.type, "the selector matched no faces", x.spanOf("faces"));
    auto depth = x.len("depth");
    if (remove)
        depth = -depth;
    if (depth == 0)
        throw new HcadError(Code.type, "depth must not be zero", x.spanOf("depth"));
    Vec3 along;
    if (x.has("along"))
    {
        along = x.dir("along");
        if (along.length < 1e-12)
            throw new HcadError(Code.type, "'along' needs a direction, not a zero vector", x.spanOf("along"));
        along = along.normalized;
    }
    auto infos = k.faces(nonEmpty(body, a.span));
    Brep[] prisms;
    // each prism's faces with the tags of the face it sweeps, for the joined tool to hand on
    SolidVal[] swept;
    int outwards, inwards;
    foreach (f; idx)
    {
        immutable n = infos[f].normal;
        immutable v = (x.has("along") ? along : n) * depth;
        (v.dot(n) > 0 ? outwards : inwards)++;
        try
            prisms ~= k.facePrism(body.brep, f, v);
        catch (KernelException e)
        {
            import std.string : chompPrefix;
            throw new HcadError(Code.kernel, fn ~ " failed: " ~ e.msg.chompPrefix("push/pull failed: "),
                x.spanOf(x.has("along") ? "along" : "faces"));
        }
        auto p = new SolidVal(prisms[$ - 1], a.span);
        inheritTags(it, p, p.brep, [body], k.faceOrigins(p.brep));
        swept ~= p;
    }
    if (outwards && inwards)
        throw new HcadError(Code.type, "the direction goes out of some faces and into others: push or pull them apart",
            x.spanOf("along"));
    auto tool = prisms.length == 1 ? derived(it, prisms[0], [body], fn, a.span)
        : derived(it, k.fuseAll(prisms), swept, fn, a.span);
    tool.flat = false;
    // the faces beside the pushed one stay whole: a box pulled up is a taller box
    return solidBoolean(it, body, tool, outwards ? BoolOp.fuse : BoolOp.cut, a.span, true);
}

/// A thread along +Z from z = 0 to `len`: the core and the teeth of `t`,
/// `starts` of them, longer than `len` at both ends (trim it). The major
/// diameter is `major` at z = 0 and changes by `slope` (on the radius) a
/// millimetre up: tapered threads.
Brep threadedCore(BrepKernel k, const ThreadSpec t, double major, double slope, double len, int starts, bool left)
{
    // built from its boundary: each corner of the tooth's profile on its own helix, a ruled face
    // between two of them (see threadBand); the profile `starts` times in a lead for more starts.
    // Right-handed: the mirror image of a right-handed thread is the left-handed one
    immutable pitch = t.pitch, lead = pitch * starts;
    immutable r0 = major / 2 - t.depth;   // the minor radius at z = 0
    // the tooth: x towards the axis (0 on the minor radius), y along it
    auto xy = t.tooth(0);
    double[] rz;
    foreach (s; 0 .. starts)
        for (size_t i = 0; i + 1 < xy.length; i += 2)
            rz ~= [r0 - xy[i], xy[i + 1] + pitch * s];
    auto rod = k.threadBand(rz, lead, len, slope);
    return left ? k.mirror(rod, Vec3(0, 1, 0)) : rod;
}

/// body.thread(faces.…, "M8", …): see def("thread").
Value threadFace(Interp it, ref CallArgs a)
{
    import hackerscad.lang.convex : turnFromZ;
    import hackerscad.lang.threading;
    auto k = it.kernel;
    auto x = Args(it, a, "thread", ["solid", "face", "size", "pitch", "length", "turns", "starts", "left", "clearance",
        "chamfer", "flip", "taper"]);
    auto body = x.solid("solid");
    if (body.flat || body.path)
        throw new HcadError(Code.type, "thread() goes on a cylindrical face of a solid", a.span);
    auto b = nonEmpty(body, a.span);
    auto idx = resolveSelector(it, x.selector("face", true), body, x.spanOf("face"));
    if (idx.length == 0)
        throw new HcadError(Code.type, "the selector matched no faces", x.spanOf("face"));
    // the faces of one cylinder (a boolean can split it in parts): their extent along the axis
    CylinderInfo c;
    double from = double.infinity, to = -double.infinity, span = 0;
    foreach (n, f; idx)
    {
        CylinderInfo ci;
        if (!k.faceCylinder(b, f, ci))
            throw new HcadError(Code.type, idx.length == 1
                ? "a thread goes on a cylindrical face: the outside of a shaft or the wall of a hole"
                : format("the selector matched %d faces, not all cylindrical: a thread needs the one face of a shaft "
                    ~ "or hole (faces.largest, faces.tagged(…))", idx.length), x.spanOf("face"));
        if (n == 0)
            c = ci;
        else
        {
            // the same cylinder: same axis line and radius
            immutable off = ci.origin - c.origin;
            if (abs(abs(ci.axis.dot(c.axis)) - 1) > 1e-6 || (off - c.axis * off.dot(c.axis)).length > 1e-6
                || abs(ci.radius - c.radius) > 1e-6)
                throw new HcadError(Code.type, "the faces are not one cylinder: thread them one at a time", x.spanOf("face"));
            if (ci.axis.dot(c.axis) < 0)
            {
                immutable t = -ci.to;
                ci.to = -ci.from;
                ci.from = t;
            }
            ci.from += off.dot(c.axis);
            ci.to += off.dot(c.axis);
        }
        from = min(from, ci.from);
        to = max(to, ci.to);
        span += ci.span;
    }
    if (span < 2 * PI - 1e-6)
        throw new HcadError(Code.type, "the face is only part of a cylinder: a thread needs it all around", x.spanOf("face"));

    // the thread: by name ("M8", "1/4-20 UNC", "Tr12x3", "G1/2", "1/2 NPT"), or a pitch alone, an
    // ISO 60° thread on the cylinder's own diameter
    immutable outside = c.outside;
    ThreadSpec t;
    if (x.has("size"))
    {
        auto sv = x.get("size");
        if (sv.kind != Kind.str || !parseThread(sv.s, t))
            throw new HcadError(Code.type, "the size names a thread: \"M8\" or \"M8x1\" (ISO metric), \"1/4-20 UNC\", "
                ~ "\"#10-32 UNF\", \"Tr12x3\" (trapezoidal), \"G1/2\" (BSP), \"R1/2\" (BSP tapered), \"1/2 NPT\"",
                x.spanOf("size"));
    }
    if (x.has("pitch"))
    {
        immutable p = x.len("pitch");
        if (!(p > 0))
            throw new HcadError(Code.type, "the pitch must be positive", x.spanOf("pitch"));
        if (t.pitch == 0)
        {
            t = ThreadSpec(format("pitch %g", p), ThreadForm.iso60, 0, p);
            t.major = outside ? 2 * c.radius : 2 * c.radius + 2 * t.depth;
        }
        t.pitch = p;
    }
    if (t.pitch == 0)
        throw new HcadError(Code.type, "say which thread: thread(face, \"M8\"), or pitch: 1.25.mm on the cylinder's diameter",
            a.span);
    // taper: any thread made conical, the angle each side leans from the axis (R and NPT have theirs)
    if (x.has("taper"))
    {
        immutable ta = x.angle("taper");
        if (!(ta >= 0) || ta >= PI / 6)
            throw new HcadError(Code.type, "the taper is the angle each side leans from the axis: from 0 (parallel) to "
                ~ "under 30° (R and NPT lean 1.79°)", x.spanOf("taper"));
        t.taper = ta;
    }
    immutable pitch = t.pitch, h = t.depth;
    // the cylinder must suit the thread: a shaft about its major diameter, a hole about its minor
    if (!fits(t, 2 * c.radius, outside))
        throw new HcadError(Code.type, outside
            ? format("the shaft is ⌀%g mm: a %s thread wants ⌀%g mm", 2 * c.radius, t.name, t.major)
            : format("the hole is ⌀%g mm: a %s thread wants a hole of about ⌀%g mm (the tap drill)", 2 * c.radius, t.name,
                t.minor + 0.15 * pitch), x.spanOf("face"));

    immutable starts = x.has("starts") ? count(x, "starts") : 1;
    // every start is a sweep of its own: more take minutes and no thread has them
    if (starts > 12)
        throw new HcadError(Code.limit, format("%s starts: a thread has at most 12", starts), x.spanOf("starts"));
    // a shaft's teeth go in towards the axis, a hole's out from it: only a shaft's can reach it
    if (outside && h >= 0.45 * c.radius)
        throw new HcadError(Code.type, format("a pitch of %g mm is too coarse for ⌀%g mm: its teeth would reach the axis",
            pitch, 2 * c.radius), x.spanOf(x.has("pitch") ? "pitch" : "size"));
    immutable left = x.flag("left", false);
    immutable clearance = x.has("clearance") ? x.len("clearance") : outside ? 0 : 0.15;
    if (clearance < 0)
        throw new HcadError(Code.type, "the clearance is play between the parts: it cannot be negative", x.spanOf("clearance"));
    immutable lead = pitch * starts;
    // which end it starts from: the free one, where the axis leaves the material (the tip of a
    // shaft, the opening of a hole); flip: true for the other
    immutable faceLen = to - from;
    auto side = c.axis.cross(abs(c.axis.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)).normalized;
    // where the ends are looked at: halfway to a shaft's axis, or, on a tube whose bore reaches
    // there, in its wall, half a tooth under the face
    immutable probe = !outside ? 0
        : k.inside(b, c.origin + c.axis * ((from + to) / 2) + side * (0.5 * c.radius)) ? 0.5 * c.radius
        : c.radius - 0.5 * h;
    bool freeAtTo;
    {
        bool solidAt(double t) => k.inside(b, c.origin + c.axis * t + side * probe);
        immutable beyondTo = solidAt(to + 0.01), beyondFrom = solidAt(from - 0.01);
        freeAtTo = beyondTo != beyondFrom ? !beyondTo : true;
    }
    if (x.flag("flip", false))
        freeAtTo = !freeAtTo;
    double len = faceLen;
    if (x.has("length") && x.has("turns"))
        throw new HcadError(Code.type, "give the thread a length or a number of turns, not both", x.spanOf("turns"));
    if (x.has("length"))
        len = x.len("length");
    if (x.has("turns"))
        len = x.num("turns") * lead;
    if (!(len > 0) || len > faceLen + 1e-6)
        throw new HcadError(Code.type, x.has("turns")
            ? format("%g turns of %g mm make %g mm: the thread must be longer than 0 and fit in the face's %g mm",
                x.num("turns"), lead, len, faceLen)
            : format("the thread must be longer than 0 and fit in the face's %g mm", faceLen),
            x.spanOf(x.has("turns") ? "turns" : "length"));
    if (len < pitch)
        throw new HcadError(Code.type, format("a thread needs one pitch (%g mm) of length at least", pitch),
            x.spanOf(x.has("turns") ? "turns" : x.has("length") ? "length" : "face"));
    // a sweep per turn and start: a hair-thin pitch would run for minutes
    if (len / pitch > 500)
        throw new HcadError(Code.limit, format("%g turns: a thread has at most 500 (is the pitch, %g mm, right?)",
            len / pitch, pitch), x.spanOf(x.has("pitch") ? "pitch" : "size"));
    // narrowing along its length, the thread must keep a core at its narrow end
    if (t.taper > 0 && (t.major / 2 + clearance * (outside ? -1 : 1)) - h - tan(t.taper) * len < 0.2 * t.major / 2)
        throw new HcadError(Code.type, format("a taper of %g° over %g mm narrows the ⌀%g mm thread to nothing: a smaller "
            ~ "angle or a shorter length", t.taper * 180 / PI, len, t.major), x.spanOf(x.has("taper") ? "taper" : "size"));
    immutable chamfer = x.flag("chamfer", true);
    // where the thread stops short of the face, or the face ends against more material (a
    // bolt's head), the threaded length reaches a fifth of a pitch into it: overlapping, the
    // two fuse cleanly, where only touching along a plane they often do not
    double sink = 0;
    {
        immutable fixedAt = freeAtTo ? to - len : from + len;
        immutable beyond = fixedAt + (freeAtTo ? -0.01 : 0.01);
        if (len < faceLen - 1e-6 || k.inside(b, c.origin + c.axis * beyond + side * probe))
            sink = 0.2 * pitch;
    }

    // built along +Z from 0 (the fixed end) to len (the free end), then placed
    Brep tool;
    // a straight thread on a shaft built straight from its faces, cut to length and bevelled with no
    // boolean, and later joined to the face it stands on by hand: 5 to 10 times quicker. Tapered
    // threads and holes the boolean way (HCAD_THREAD_DIRECT=0 always so, to compare)
    import std.process : environment;
    bool direct = outside && t.taper == 0 && environment.get("HCAD_THREAD_DIRECT", "1") != "0";
    // a straight thread in a hole, through or blind, as long as it or shorter: a sleeve built straight from
    // its faces, its end closed by its own face (the reach into the material, sink, is for the boolean
    // way's tool); HCAD_THREAD_SLEEVE=0 never, to compare; tapered threads the boolean way
    immutable trySleeve = !outside && t.taper == 0 && environment.get("HCAD_THREAD_SLEEVE", "1") != "0";
    // the screw that fits, cut into the wall
    Brep holeTool()
    {
        // tapered: the full size at the opening, narrowing inwards
        immutable slope = tan(t.taper), dd = t.major + 2 * clearance;   // at the opening, z = len
        // past the opening (and past the far end of a through hole) the tool reaches into the
        // air a little: cutting nothing there, it leaves no face lying on the body's
        immutable below = sink > 0 ? 0 : 0.2 * pitch, above = 0.2 * pitch;
        immutable d0 = dd - 2 * slope * (len + below);   // at z = -below
        auto r = k.boolean(k.translate(threadedCore(k, t, d0, slope, len + below + above, starts, left), Vec3(0, 0, -below)),
            k.translate(k.cylinder(dd, len + below + above), Vec3(0, 0, -below)), BoolOp.common);
        if (chamfer)   // the opening countersunk at 45°, to start the screw
            r = k.boolean(r, k.translate(k.cone(dd / 2 - h, dd / 2 + 0.01, h + 0.01), Vec3(0, 0, len - h)),
                BoolOp.fuse);
        return r;
    }
    try
    {
        if (outside && direct)
        {
            immutable dd = t.major - 2 * clearance;
            try
            {
                // the corners as threadedCore has them
                immutable r0 = dd / 2 - t.depth;
                auto xy = t.tooth(0);
                double[] rz;
                foreach (st; 0 .. starts)
                    for (size_t i = 0; i + 1 < xy.length; i += 2)
                        rz ~= [r0 - xy[i], xy[i + 1] + pitch * st];
                tool = k.threadDirect(rz, lead, len, chamfer ? h : 0, dd / 2 + 0.01);
                if (left)
                    tool = k.mirror(tool, Vec3(0, 1, 0));
            }
            catch (KernelException)
                direct = false;
        }
        if (outside && !direct)
        {
            // what the grooves take away: around the cylinder, less the threaded rod
            // tapered: the full size at the fixed end, narrowing to the tip
            immutable dd = t.major - 2 * clearance, slope = -tan(t.taper);
            auto rod = k.translate(threadedCore(k, t, dd - 2 * slope * sink, slope, len + sink, starts, left),
                Vec3(0, 0, -sink));
            auto keep = slope == 0 ? k.cylinder(dd / 2 + 0.01, len) : k.cone(dd / 2 + 0.01, dd / 2 + 0.01 + slope * len, len);
            if (chamfer)   // the tip's crest bevelled at 45°, a tooth high
            {
                auto ed = k.edges(keep);
                int[] top;
                foreach (i, e; ed)
                    if (e.kind == EdgeKind.circle && e.center.z > len - 1e-6)
                        top ~= cast(int) i;
                keep = k.chamfer(keep, top, h);
            }
            tool = k.boolean(rod, keep, BoolOp.common);
            // into the material, a plain core a little narrower than the thread's: overlapping the
            // shaft or the head there, the two fuse cleanly
            if (sink > 0)
                tool = k.boolean(tool, k.translate(k.cylinder(dd / 2 - h - 0.02, sink + 0.02), Vec3(0, 0, -sink)),
                    BoolOp.fuse);
        }
        else if (!outside && !trySleeve)
            tool = holeTool();
    }
    catch (KernelException e)
        throw new HcadError(Code.kernel, "the thread could not be built: " ~ e.msg, a.span);
    // the helices start at the bottom of what was built (sink or below it); turned so that each is at
    // angle 0 at the free end instead, a male thread and a female one cut from the same free end are
    // in step, whatever their lengths (a nut cut over a bolt's tip fits it)
    void inStep()
    {
        immutable shift = outside ? (direct ? 0 : sink) : (sink > 0 ? 0 : 0.2 * pitch);
        immutable turn = 2 * PI * (len + shift) / lead * (left ? 1 : -1);
        immutable phase = turn - 2 * PI * floor(turn / (2 * PI));
        if (phase > 1e-12)
            try
                tool = k.rotate(tool, Vec3(0, 0, 1), phase);
            catch (KernelException e)
                throw new HcadError(Code.kernel, "the thread could not be built: " ~ e.msg, a.span);
    }
    if (tool !is null)
        inStep();
    // +Z onto the axis, pointing to the free end; z = 0 at len before it
    immutable dir = freeAtTo ? c.axis : -c.axis;
    immutable start = c.origin + c.axis * (freeAtTo ? to - len : from + len);
    Vec3 ax;
    double angle;
    turnFromZ(dir, ax, angle);
    Brep placed(Brep t)
    {
        if (angle > 1e-12)
            t = k.rotate(t, ax, angle);
        return k.translate(t, start);
    }
    // a through hole threaded with no boolean on helical faces: a prism hole of a few flat sides cut
    // (planes only), and a sleeve built straight from its faces, flat outside and threaded inside,
    // joined to it by hand where their flat faces lie on each other: two to three times quicker
    if (trySleeve)
    {
        immutable dd = t.major + 2 * clearance, r0 = dd / 2 - t.depth;
        auto xy = t.tooth(0);
        double[] rz;
        foreach (st; 0 .. starts)
            for (size_t i = 0; i + 1 < xy.length; i += 2)
                rz ~= [r0 - xy[i], xy[i + 1] + pitch * st];
        // the hole drilled wider than the thread's root (a tap drill on the large side): the crests stop at its
        // wall, as the boolean leaves them. The profile, one pitch of corners, is cut at r = the hole's radius,
        // a corner put where an edge crosses it
        {
            // where the sleeve ends inside the part (a short thread, a blind hole) the crests stop 0.01 mm
            // short of the hole's wall: lying on it, the floor between them and the round hole going on
            // would be a face of no width along them, and booleans after it fail
            immutable rh = c.radius + (sink > 0 ? 0.01 : 0);
            double[] cut;
            immutable m = rz.length / 2;
            foreach (i; 0 .. m)
            {
                immutable r1 = rz[2 * i], z1 = rz[2 * i + 1];
                // the next corner: the first one again, a lead on, after the last
                immutable r2 = rz[(2 * i + 2) % rz.length], z2 = rz[(2 * i + 3) % rz.length] + (i + 1 == m ? lead : 0);
                if (r1 >= rh)
                    cut ~= [r1, z1];
                if ((r1 >= rh) != (r2 >= rh))
                {
                    immutable f = (rh - r1) / (r2 - r1);
                    cut ~= [rh, z1 + f * (z2 - z1)];
                }
            }
            if (cut.length >= 6)
                rz = cut;
        }
        // the fewest sides whose flats clear the thread's crests by 0.5 mm and whose corners stay in the part
        foreach (sides; [3, 4, 6, 8, 12])
        {
            immutable rPoly = (dd / 2 + 0.5) / cos(PI / sides);
            bool fits = true;
            foreach (i; 0 .. sides)
            {
                auto corner = placed(k.translate(k.box(0.001, 0.001, 0.001), Vec3(rPoly * cos(2 * PI * i / sides),
                    rPoly * sin(2 * PI * i / sides), len / 2)));
                fits = fits && k.inside(b, k.bbox(corner).center);
            }
            if (!fits)
                continue;
            try
            {
                immutable turn = 2 * PI * len / lead * (left ? 1 : -1);
                immutable phase = turn - 2 * PI * floor(turn / (2 * PI));
                auto sleeve = k.threadSleeve(rz, lead, len, sides, rPoly);
                if (left)
                    sleeve = k.mirror(sleeve, Vec3(0, 1, 0));
                double[] ring;
                foreach (i; 0 .. sides)
                    ring ~= [rPoly * cos(2 * PI * i / sides), rPoly * sin(2 * PI * i / sides)];
                auto prism = k.extrude(k.polygon(ring), len, 0);
                if (left)
                    prism = k.mirror(prism, Vec3(0, 1, 0));
                if (phase > 1e-12)
                {
                    sleeve = k.rotate(sleeve, Vec3(0, 0, 1), phase);
                    prism = k.rotate(prism, Vec3(0, 0, 1), phase);
                }
                // each step derived from the one before: a face's origin is in the step's own inputs
                auto holed = derived(it, k.boolean(b, placed(prism), BoolOp.cut), [body], "thread", a.span);
                auto joined = derived(it, k.joinCoincident(holed.brep, placed(sleeve)), [holed], "thread", a.span);
                // the opening countersunk at 45°, to start the screw
                if (chamfer)
                    joined = derived(it, k.boolean(joined.brep, placed(k.translate(k.cone(dd / 2 - h,
                        dd / 2 + 0.01 + 0.01, h + 0.01), Vec3(0, 0, len - h))), BoolOp.cut), [joined], "thread",
                        a.span);
                if (environment.get("HCAD_THREAD_DEBUG"))
                {
                    import std.stdio : stderr;
                    stderr.writefln("sleeve: %s sides, length %s of %s", sides, len, faceLen);
                }
                return Value.of(joined);
            }
            catch (KernelException e)
            {
                // why the sleeve was not taken, for whoever works on it
                if (environment.get("HCAD_THREAD_DEBUG"))
                {
                    import std.stdio : stderr;
                    stderr.writefln("sleeve failed: %s", e.msg);
                }
                break;
            }
        }
        // no sleeve: the boolean way
        try
            tool = holeTool();
        catch (KernelException e)
            throw new HcadError(Code.kernel, "the thread could not be built: " ~ e.msg, a.span);
        inStep();
    }
    // the thread and its helpers are built apart: none of their faces is one of the body's
    SolidVal apart(Brep q)
    {
        auto r = derived(it, q, null, "thread", a.span);
        r.rgb = body.rgb;
        r.hasColor = body.hasColor;
        return r;
    }
    auto sv = apart(placed(tool));
    sv.flat = false;
    if (!outside)
        return solidBoolean(it, body, sv, BoolOp.cut, a.span);
    // a shaft: its plain length taken away and the threaded one put in its place (cutting the
    // grooves out of it would lay the crests exactly on its surface, which booleans handle badly)
    SolidVal plain;
    try
        plain = apart(placed(k.cylinder(c.radius + 0.02, len)));
    catch (KernelException e)
        throw new HcadError(Code.kernel, "the thread could not be built: " ~ e.msg, a.span);
    plain.flat = false;
    // the threaded rod is solid: what was empty inside the face (a tube's bore) is taken out of it
    // again. The plain cylinder reaches a little past both ends, so a bore going on is cut whole
    SolidVal hollow;
    try
    {
        immutable past = 0.25 * pitch + sink;
        auto inner = k.translate(k.cylinder(c.radius - 0.01, len + 2 * past), Vec3(0, 0, -past));
        auto empty = k.boolean(placed(inner), b, BoolOp.cut);
        if (k.solids(empty).length && k.volume(empty) > 1e-6)
        {
            hollow = apart(empty);
            hollow.flat = false;
        }
    }
    catch (KernelException e)
        throw new HcadError(Code.kernel, "the thread could not be built: " ~ e.msg, a.span);
    Value hollowed(Value v) => hollow is null ? v : solidBoolean(it, v.solid, hollow, BoolOp.cut, a.span);
    auto bare = solidBoolean(it, body, plain, BoolOp.cut, a.span);
    // the thread standing on material at its fixed end (a shoulder, a head): joined to that face by
    // hand, or, when it does not stand on a flat face wider than itself (the shaft goes on at its
    // own diameter), the boolean with the plain core it needs to fuse cleanly
    if (direct && sink > 0 && bare.solid.brep !is null)
    {
        try
            return hollowed(Value.of(derived(it, k.joinTouching(bare.solid.brep, sv.brep), [bare.solid, sv], "union",
                a.span)));
        catch (KernelException)
        {
            immutable dd = t.major - 2 * clearance;
            auto core = k.translate(k.cylinder(dd / 2 - h - 0.02, sink + 0.02), Vec3(0, 0, -sink));
            auto withCore = apart(placed(k.boolean(tool, core, BoolOp.fuse)));
            withCore.flat = false;
            return hollowed(solidBoolean(it, bare.solid, withCore, BoolOp.fuse, a.span));
        }
    }
    return hollowed(solidBoolean(it, bare.solid, sv, BoolOp.fuse, a.span));
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
        throw new HcadError(Code.kernel, s.flat ? "the profile is empty (a difference took all of it, or an "
            ~ "intersection found nothing in common?): check it with isEmpty first" : "the solid is empty", span);
    return s.brep;
}

/// A face that a frame can stand on: on a curved one its centre and average
/// normal are inside the body (on a cylinder's axis), and what is placed on
/// it ends up buried, so it is refused.
public FaceInfo flatFace(Interp it, SolidVal s, int face, string fn, Span span)
{
    auto f = it.kernel.faces(s.brep)[face];
    immutable size = it.kernel.bbox(s.brep).size.length;
    foreach (loop; it.kernel.faceLoops(s.brep, face, 1e-3 * size))
        foreach (p; loop)
            if (abs((p - f.center).dot(f.normal)) > 1e-6 * size)
            {
                CylinderInfo c;
                immutable cylinder = it.kernel.faceCylinder(s.brep, face, c);
                throw new HcadError(Code.type, format("%s needs a flat face; this one is curved%s", fn, cylinder
                    ? format(" (a cylinder ⌀%g mm): body.axis(faces.…) gives its axis, plane(origin:, normal:) a plane "
                        ~ "touching it", 2 * c.radius) : ""), span);
            }
    return f;
}

/// Rejects outlines that cross or retrace themselves, or enclose nothing:
/// the kernel builds them without a word and their solids have no volume.
/// Repeated points are dropped from `xy` first.
void polygonCheck(ref double[] xy, Span span)
{
    import std.math : abs;
    double size = 0;
    foreach (c; xy)
        size = max(size, abs(c));
    immutable eps = 1e-9 * max(size, 1e-6);
    double[] kept;
    foreach (i; 0 .. xy.length / 2)
    {
        immutable px = xy[2 * i], py = xy[2 * i + 1];
        if (kept.length && abs(kept[$ - 2] - px) <= eps && abs(kept[$ - 1] - py) <= eps)
            continue;
        kept ~= [px, py];
    }
    while (kept.length > 2 && abs(kept[0] - kept[$ - 2]) <= eps && abs(kept[1] - kept[$ - 1]) <= eps)
        kept = kept[0 .. $ - 2];
    immutable n = kept.length / 2;
    if (n < 3)
        throw new HcadError(Code.type, "polygon needs at least 3 different points", span);
    double px(size_t i) => kept[2 * (i % n)];
    double py(size_t i) => kept[2 * (i % n) + 1];
    // orientation of c from segment a-b: > 0 left, < 0 right, 0 on the line
    double orient(size_t a, size_t b, size_t c)
    {
        immutable o = (px(b) - px(a)) * (py(c) - py(a)) - (py(b) - py(a)) * (px(c) - px(a));
        return abs(o) <= eps * size ? 0 : o;
    }
    bool within(size_t a, size_t b, size_t c) =>   // c on the line a-b: whether between them
        min(px(a), px(b)) - eps <= px(c) && px(c) <= max(px(a), px(b)) + eps
        && min(py(a), py(b)) - eps <= py(c) && py(c) <= max(py(a), py(b)) + eps;
    bool cross(size_t a, size_t b, size_t c, size_t d)
    {
        immutable o1 = orient(a, b, c), o2 = orient(a, b, d), o3 = orient(c, d, a), o4 = orient(c, d, b);
        if (((o1 > 0 && o2 < 0) || (o1 < 0 && o2 > 0)) && ((o3 > 0 && o4 < 0) || (o3 < 0 && o4 > 0)))
            return true;
        return (o1 == 0 && within(a, b, c)) || (o2 == 0 && within(a, b, d))
            || (o3 == 0 && within(c, d, a)) || (o4 == 0 && within(c, d, b));
    }
    bool line = true;
    foreach (i; 2 .. n)
        line = line && orient(0, 1, i) == 0;
    if (line)
        throw new HcadError(Code.type, "the polygon's points are all on one line: it encloses nothing", span);
    foreach (i; 0 .. n)
    {
        // a point going straight back the way it came
        immutable a = i, b = i + 1, c = i + 2;
        if (orient(a, b, c) == 0 && (px(b) - px(a)) * (px(c) - px(b)) + (py(b) - py(a)) * (py(c) - py(b)) < 0)
            throw new HcadError(Code.type, format("the polygon turns back on itself at point %d (%g, %g)", (i + 1) % n,
                px(b), py(b)), span);
        immutable xlo = min(px(a), px(b)) - eps, xhi = max(px(a), px(b)) + eps;
        foreach (j; i + 2 .. n)
        {
            if (i == 0 && j == n - 1)
                continue;   // neighbours through the closing segment
            if (max(px(j), px(j + 1)) < xlo || min(px(j), px(j + 1)) > xhi)
                continue;
            if (cross(a, b, j, j + 1))
                throw new HcadError(Code.type, format("the polygon crosses itself: its side %d (from (%g, %g)) meets "
                    ~ "side %d (from (%g, %g)); give the points in order around the outline", i + 1, px(a), py(a),
                    j + 1, px(j), py(j)), span);
        }
    }
    double area = 0;
    foreach (i; 0 .. n)
        area += px(i) * py(i + 1) - px(i + 1) * py(i);
    if (abs(area) / 2 <= eps * max(size, 1e-6))
        throw new HcadError(Code.type, "the polygon encloses no area", span);
    xy = kept;
}

void positive(ref CallArgs a, double[] xs, string what)
{
    foreach (x; xs)
        if (!(x > 0))
            throw new HcadError(Code.type, what ~ " must be positive", a.span);
}

double comp(Vec3 v, size_t i) => i == 0 ? v.x : i == 1 ? v.y : v.z;
Vec3 axisVec(size_t i) => i == 0 ? Vec3(1, 0, 0) : i == 1 ? Vec3(0, 1, 0) : Vec3(0, 0, 1);

/// A pattern of `s`: the references of its first copy (where `s` was), not one of each copy.
Value firstCopyAnchors(Value pattern, SolidVal s)
{
    if (pattern.kind == Kind.solid && pattern.solid !is s)
        pattern.solid.anchors = s.anchors.dup;
    return pattern;
}

Value unionAll(Interp it, Value[] xs, Span span)
{
    bool flat, solid;
    foreach (v; xs)
    {
        if (v.kind != Kind.solid)
            throw new HcadError(Code.type, format("cannot fuse %s with solids", v.typeName), span);
        if (v.solid.path)
            throw new HcadError(Code.type, "cannot fuse a Path: sweep a profile along it", span);
        if (v.solid.brep !is null)
            (v.solid.flat ? flat : solid) = true;
    }
    if (flat && solid)
        throw new HcadError(Code.type, "cannot combine a Solid and a Profile: extrude the profile first", span);
    // in pairs, then pairs of pairs: joining one at a time into a growing
    // body makes long patterns quadratic (400 copies took half a minute)
    Value fuse(Value[] part)
    {
        if (part.length == 0)
            return Value.of(new SolidVal(null, span));
        if (part.length == 1)
            return part[0];
        return solidBoolean(it, fuse(part[0 .. $ / 2]).solid, fuse(part[$ / 2 .. $]).solid, BoolOp.fuse, span);
    }
    return fuse(xs);
}

SelectorVal copy(SelectorVal s)
{
    auto r = new SelectorVal;
    r.faces = s.faces;
    r.predicates = s.predicates.dup;
    r.tests = s.tests.dup;
    r.of = s.of;
    r.tagged = s.tagged;
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
    case "tagged":
        // the faces tagged so (addTag), or tagged with any of a list
        return fn((ref CallArgs a) {
            auto x = Args(it, a, "tagged", ["selector", "tag"]);
            if (!sel.faces)
                throw new HcadError(Code.type, "edges have no tags yet: tag the faces on either side and take the edges "
                    ~ "between them, edges.between(faces.tagged(\"a\"), faces.tagged(\"b\"))", a.span);
            auto names = tagNames(x.get("tag"), x.spanOf("tag"));
            auto r = copy(sel);
            r.tagged = tagUnion(r.tagged, names);
            r.tests ~= (size_t i, ref SelectCtx c) => c.faceTags.length && c.faceTags[i].any!(t => names.canFind(t));
            return Value.make(Kind.selector, r);
        });
    case "count", "list":
        {
            // taken from a solid: how many it selects there, or them (Face or Edge values)
            if (sel.of is null)
                throw new HcadError(Code.type, format("%s: of which solid? take them from it, b.%s.….%s", name,
                    sel.faces ? "faces" : "edges", name), span);
            auto idx = resolveSelector(it, sel, sel.of, span, true);
            if (name == "count")
            {
                result = Value.integer(idx.length);
                return true;
            }
            Value[] r;
            auto b = sel.of.brep;
            if (sel.faces)
            {
                auto fs = it.kernel.faces(b);
                foreach (i; idx)
                {
                    auto f = new FaceVal;
                    f.info = fs[i];
                    f.index = i;
                    r ~= Value.make(Kind.face, f);
                }
            }
            else
            {
                auto es = it.kernel.edges(b);
                foreach (i; idx)
                {
                    auto e = new EdgeVal;
                    e.info = es[i];
                    e.index = i;
                    r ~= Value.make(Kind.edge, e);
                }
            }
            result = Value.of(r);
            return true;
        }
    case "tags":
        {
            // the tags of the faces selected, all of them
            auto idx = selectedOf(it, sel, name, span);
            auto all = facesTagsOf(it, sel.of);
            string[] r;
            foreach (i; idx)
                r = tagUnion(r, all[i]);
            result = tagList(r);
            return true;
        }
    case "hasTag":
        // whether every face selected has that tag
        return fn((ref CallArgs a) {
            auto x = Args(it, a, "hasTag", ["selector", "tag"]);
            immutable t = tagName(x.get("tag"), x.spanOf("tag"));
            auto all = facesTagsOf(it, sel.of);
            return Value.of(selectedOf(it, sel, name, a.span).all!(i => all[i].canFind(t)));
        });
    case "addTag", "removeTag", "clearTags":
        // the solid they were taken from, those faces' tags changed
        return fn((ref CallArgs a) {
            immutable clear = name == "clearTags";
            auto x = Args(it, a, name, clear ? ["selector"] : ["selector", "tag"]);
            auto names = clear ? null : tagNames(x.get("tag"), x.spanOf("tag"));
            if (name == "addTag")
                ownTags(names, a.caller, x.spanOf("tag"));
            auto idx = selectedOf(it, sel, name, a.span);
            auto s = sel.of;
            auto tags = facesTagsOf(it, s).dup;
            if (name == "removeTag")
                foreach (t; names)
                    if (!idx.any!(i => tags[i].canFind(t)))
                    {
                        string[] present;
                        foreach (i; idx)
                            present = tagUnion(present, tags[i]);
                        throw new HcadError(Code.type, format("no face selected is tagged '%s'%s", t, s.tags.canFind(t)
                            ? " (the solid itself is: b.removeTag)" : ""), x.spanOf("tag"), tagHint(t, present, null));
                    }
            foreach (i; idx)
                tags[i] = name == "addTag" ? tagUnion(tags[i], names)
                    : clear ? null : tags[i].filter!(t => !names.canFind(t)).array.dup;
            auto r = copySolid(s);
            r.faceTags = tags;
            return Value.make(Kind.solid, r);
        });
    case "from":
        // faces created by a tool or feature: faces.from(hole); edges: both faces from it
        return fn((ref CallArgs a) {
            auto x = Args(it, a, "from", ["selector", "solid"]);
            // a list of tools: the faces of any of them (holes taken away all at once)
            SolidVal[] tools;
            {
                auto given = x.get("solid");
                if (given.kind == Kind.array)
                {
                    foreach (v; given.arr)
                    {
                        if (v.kind != Kind.solid)
                            throw new HcadError(Code.type, format("from takes a solid or a list of solids, not a list "
                                ~ "holding %s", v.typeName), x.spanOf("solid"));
                        tools ~= v.solid;
                    }
                }
                else
                    tools = [x.solid("solid")];
            }
            bool[uint] ids;
            // the features by where in the code they ran: a tool made again by calling its function
            // a second time (body - holes(), then faces.from(holes())) has new features from the
            // same lines, which find the faces when the features themselves are not on the solid
            bool[string] lines;
            string where(uint c) => c > 0 && c <= it.features.length
                ? it.features[c - 1].kind ~ "@" ~ it.features[c - 1].span.toString : null;
            foreach (tool; tools)
            foreach (c; tool.creators)
            {
                ids[c] = true;
                if (auto w = where(c))
                    lines[w] = true;
            }
            // per solid looked at: whether any of its faces comes from the tool itself
            const(uint)* seenFor;
            bool byId;
            bool fromTool(ref SelectCtx c, uint creator)
            {
                if (seenFor !is c.creators.ptr)
                {
                    seenFor = c.creators.ptr;
                    byId = false;
                    foreach (cr; c.creators)
                        if (cr in ids)
                        {
                            byId = true;
                            break;
                        }
                }
                if (byId)
                    return (creator in ids) !is null;
                auto w = where(creator);
                return w !is null && (w in lines) !is null;
            }
            if (sel.faces)
                return with_((size_t i, ref SelectCtx c) => c.creators.length && fromTool(c, c.creators[i]));
            return with_((size_t i, ref SelectCtx c) {
                if (!c.creators.length)
                    return false;
                foreach (f; c.edgeFaces[i])
                    if (f < 0 || !fromTool(c, c.creators[f]))
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
        case "loop":
            // edges.loop(faces.top): the outer loop of each face, not the edges round its holes
            return fn((ref CallArgs a) {
                auto inner = faceSelector(a, "loop");
                int[] memo;
                const(EdgeInfo)* key;
                return with_((size_t i, ref SelectCtx c) {
                    if (c.edges.ptr !is key)
                    {
                        key = c.edges.ptr;
                        memo = null;
                        foreach (f; c.resolve(inner))
                            memo ~= c.outerEdges(f);
                    }
                    return memo.canFind(cast(int) i);
                });
            });
        case "chain":
            // edges.chain(edges.…): those edges and every edge running on from them without a corner (tangent
            // within `angle`, 2° unless given): a curved outline made of many pieces, taken whole
            return fn((ref CallArgs a) {
                auto x = Args(it, a, "chain", ["selector", "edges", "angle"]);
                auto seed = x.selector("edges", false);
                immutable cosTol = cos(x.angleOr("angle", 2 * PI / 180));
                bool[] memo;
                const(EdgeInfo)* key;
                return with_((size_t i, ref SelectCtx c) {
                    if (c.edges.ptr !is key)
                    {
                        key = c.edges.ptr;
                        memo = tangentChain(c.edges, c.resolve(seed), cosTol);
                    }
                    return memo[i];
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
    // furthest along it (the outer skin, not inner floors); on a part turned a little (or a
    // mesh not quite square) none points exactly that way: then those facing it the most,
    // within half a degree, and among them the outermost along their own normal
    Value extremal(Vec3 axis)
    {
        bool[] memo;
        const(FaceInfo)* key;
        return with_((size_t i, ref SelectCtx c) {
            if (c.faces.ptr !is key)
            {
                key = c.faces.ptr;
                memo = extremalFaces(c.faces, axis);
            }
            return memo[i];
        });
    }

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
    case "overhanging":
        // faces.overhanging(45.deg): faces facing down more steeply than the angle from a wall (any part
        // of them), not resting on the bed: where a printer needs supports
        return fn((ref CallArgs a) {
            auto x = Args(it, a, "overhanging", ["selector", "angle"]);
            immutable angle = x.angleOr("angle", PI / 4);
            if (!(angle >= 0 && angle < PI / 2))
                throw new HcadError(Code.type, "the overhang angle is from a vertical wall: 0 to 90°", x.spanOf("angle"));
            return with_((size_t i, ref SelectCtx c) => c.overhangShares(angle)[i] > 0.01);
        });
    case "farthest":
        // faces.farthest(Z): the face whose centre lies farthest that way, whatever way it faces
        // (a vase's tilted mouth); among the faces selected so far
        return fn((ref CallArgs a) {
            auto x = Args(it, a, "farthest", ["selector", "axis"]);
            auto ax = x.dir("axis");
            auto prefix = copy(sel);
            return with_((size_t i, ref SelectCtx c) {
                auto candidates = c.resolve(prefix);
                if (!candidates.canFind(cast(int) i))
                    return false;
                double best = -double.infinity;
                foreach (j; candidates)
                    best = max(best, c.faces[j].center.dot(ax));
                return c.faces[i].center.dot(ax) >= best - 1e-6;
            });
        });
    case "normal":
        return fn((ref CallArgs a) {
            auto x = Args(it, a, "normal", ["selector", "axis"]);
            auto ax = x.dir("axis");
            return with_((size_t i, ref SelectCtx c) => c.faces[i].facing && c.faces[i].normal.dot(ax) > 1 - 1e-6);
        });
    default:
        return false;
    }
}

/// Which faces faces.top (axis Z), faces.right… pick: those facing `axis` exactly and furthest along it;
/// when none faces it exactly (a part turned, a mesh not quite square), those facing it the most (at
/// least 60° from sideways, within half a degree of the best) and outermost along their own normal.
bool[] extremalFaces(const(FaceInfo)[] faces, Vec3 axis)
{
    auto r = new bool[faces.length];
    double bestDot = -double.infinity;
    foreach (g; faces)
        if (g.facing)
            bestDot = max(bestDot, g.normal.dot(axis));
    if (bestDot > 1 - 1e-6)
    {
        double best = -double.infinity;
        foreach (g; faces)
            if (g.facing && g.normal.dot(axis) > 1 - 1e-6)
                best = max(best, g.center.dot(axis));
        foreach (i, g; faces)
            r[i] = g.facing && g.normal.dot(axis) > 1 - 1e-6 && g.center.dot(axis) >= best - 1e-6;
        return r;
    }
    if (!(bestDot >= 0.5))
        return r;
    immutable minDot = cos(min(acos(bestDot) + 0.5 * PI / 180, PI));
    Vec3 n;
    foreach (g; faces)
        if (g.facing && g.normal.dot(axis) == bestDot)
            n = g.normal;
    double best = -double.infinity;
    foreach (g; faces)
        if (g.facing && g.normal.dot(axis) >= minDot)
            best = max(best, g.center.dot(n));
    foreach (i, g; faces)
        r[i] = g.facing && g.normal.dot(axis) >= minDot && g.center.dot(n) >= best - 1e-3;
    return r;
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
        throw new HcadError(Code.units, format("%s takes a plain number, not %s", name, v.n.dim.aName), a.span);
    return v.n.value;
}

/// sin(30.deg) or sin(0.5) in radians, as in D.
double angleArg(ref CallArgs a, string name)
{
    auto v = num(a, name);
    if (v.n.dim != Dim.angle && v.n.dim != Dim.none)
        throw new HcadError(Code.units, format("%s takes an Angle, not %s", name, v.n.dim.aName), a.span);
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
    // a quantity as the bare number that means it in this file: lengths in its unit
    // (mm, or the one of @unit(inch); squared for an area, cubed for a volume),
    // angles in degrees, as bare angles are in rotate
    immutable fileUnit = a.caller ? a.caller.unitFactor : 1;
    // (to 12 significant digits: 30.deg is 30, not 29.999999999999996)
    double plain(Value q)
    {
        immutable v = q.n.value / (PI / 180) ^^ q.n.dim.ang / fileUnit ^^ q.n.dim.len;
        static import std.conv;
        return isFinite(v) ? std.conv.to!double(format("%.12g", v)) : v;
    }
    switch (target)
    {
    case "string": return Value.of(v.toString);
    case "int", "long":
        {
            double x;
            if (v.kind == Kind.str)
            {
                try
                    x = std.string.strip(v.s).to!long;
                catch (ConvException)
                    throw new HcadError(Code.type, format("\"%s\" is not a whole number", v.s), a.span);
            }
            else if (v.isNum && v.n.dim == Dim.none)
                x = v.n.value;
            else if (v.isNum)
                x = plain(v);
            else
                break;
            if (x != floor(x))
                throw new HcadError(Code.type, format("%s is not an integer (use floor/round first)", v), a.span);
            if (!(abs(x) <= maxExactInt))
                throw new HcadError(Code.limit, format("%s is too large for an exact integer (at most %s)", v, maxExactInt), a.span);
            return Value.integer(cast(long) x);
        }
    case "double", "float", "real":
        if (v.kind == Kind.str)
        {
            try
                return Value.number(std.string.strip(v.s).to!double);
            catch (ConvException)
                throw new HcadError(Code.type, format("\"%s\" is not a number", v.s), a.span);
        }
        if (v.isNum && v.n.dim == Dim.none)
            return Value.number(v.n.value);
        if (v.isNum)
            return Value.number(plain(v));
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
        // "%300000000s" would fill the memory
        {
            import std.conv : to;
            import std.string : split;
            auto digits = fmt[i + 1 .. j];
            while (digits.length && "-+ ".canFind(digits[0]))
                digits = digits[1 .. $];
            foreach (part; digits.split("."))
                if (part.length > 3)
                    throw new HcadError(Code.limit, format("'%s': widths and precisions go up to 999", spec), a.span);
        }
        switch (fmt[j])
        {
        case 's': r ~= format(spec, v.toString); break;
        case 'd':
            {
                if (!v.isNum) throw new HcadError(Code.type, "%d needs a number", a.span);
                // angles in degrees, like %f
                immutable x = v.n.dim == Dim.angle ? v.n.value * 180 / PI : v.n.value;
                if (!isFinite(x) || abs(x) >= 9.2e18)
                    throw new HcadError(Code.type, format("%%d: %s is too large for a whole number", v.toString), a.span);
                if (abs(x - round(x)) > 1e-9 * max(1.0, abs(x)))
                    throw new HcadError(Code.type, format("%%d needs a whole number, not %s: round it, or use %%.0f",
                        v.toString), a.span);
                r ~= format(spec, cast(long) round(x));
                break;
            }
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


/// The weights of fonts by name (with their other spellings), 100 to 900.
private immutable string[][int] weightNames;

shared static this()
{
    weightNames = [100: ["Thin", "Hairline"], 200: ["ExtraLight", "UltraLight"], 300: ["Light"],
        400: ["Regular", "Normal", "Book"], 500: ["Medium"], 600: ["SemiBold", "DemiBold"], 700: ["Bold"],
        800: ["ExtraBold", "UltraBold"], 900: ["Black", "Heavy"]];
}

/// A weight: a name ("light", "semi-bold", any case) or a number from 100 to 900.
private int fontWeight(Value v, Span span)
{
    import std.string : replace;
    if (v.kind == Kind.str)
    {
        immutable name = v.s.toLower.replace("-", "").replace(" ", "");
        foreach (w, names; weightNames)
            foreach (n; names)
                if (n.toLower == name)
                    return w;
        throw new HcadError(Code.type, format("no font weight is called '%s'", v.s), span,
            "thin, extralight, light, regular, medium, semibold, bold, extrabold, black, or 100 … 900");
    }
    if (v.isNum && v.n.dim == Dim.none && v.n.value >= 100 && v.n.value <= 900)
        return cast(int) (round(v.n.value / 100) * 100);
    throw new HcadError(Code.type, "weight: a name (\"light\", \"bold\"…) or a number from 100 to 900", span);
}

/// The font a text uses: its family and style (0 regular, 1 bold, 2 italic, 3 bold italic) for the name
/// given (an alias, "Sans", or a family, a style perhaps said at its end: "Sans Bold Italic"), the weight
/// (0: the name's, else regular) and italic asked; a weight the family has not: the nearest it has, and
/// what is missing said as a warning, once.
private auto textFont(Interp it, string font, int weight, bool italic, Span span)
{
    import std.string : split, strip;
    import std.typecons : tuple;
    auto k = it.kernel;
    void warn(string msg, string hint)
    {
        if (!it.diagnostics.canFind!(d => d.message == msg))
            it.diagnostics ~= Diagnostic(Severity.warning, Code.type, msg, span, hint);
    }
    // a style at the end of a name that is no family itself: "Sans Bold", "DejaVu Serif Light Italic"
    string family = k.fontFamily(font);
    if (family.length == 0)
    {
        auto words = font.split(" ");
        int named;
        bool slanted;
        while (words.length > 1)
        {
            immutable last = words[$ - 1].toLower;
            if (last == "italic" || last == "oblique")
                slanted = true;
            else if (auto w = fontWeight(last))
                named = named ? named : w;
            else
                break;
            words = words[0 .. $ - 1];
            if (auto found = k.fontFamily(words.join(" ")))
            {
                family = found;
                if (!weight)
                    weight = named;
                italic = italic || slanted;
                break;
            }
        }
    }
    if (family.length == 0)
    {
        string[] similar;
        k.fontKnown(font, 0, similar);
        warn(format("no font '%s' is installed: the text uses another one", font), similar.length
            ? format("installed fonts like it: %-(%s, %)", similar)
            : "give a font that is installed (fc-list lists them), or the path of a font file");
        return tuple!("family", "style")(font, italic ? 2 : 0);
    }
    if (!weight)
        weight = 400;
    // the weights of the family: regular and bold its own styles, the others families named after it
    int[] masks;
    auto names = k.fontFamilies(masks);
    int[string] stylesOf;
    foreach (i, n; names)
        stylesOf[n] = masks[i];
    struct Choice { int weight; string family; bool bold; }
    Choice[] have;
    immutable own = stylesOf.get(family, 1);
    if (own & 5)
        have ~= Choice(400, family, false);
    if (own & 10)
        have ~= Choice(700, family, true);
    foreach (w, spellings; weightNames)
        foreach (n; spellings)
            if (auto st = (family ~ " " ~ n) in stylesOf)
                if (!have.canFind!(c => c.weight == w))
                    have ~= Choice(w, family ~ " " ~ n, false);
    if (have.length == 0)
        have ~= Choice(400, family, false);
    have.sort!((p, q) => p.weight < q.weight);
    auto best = have[0];
    foreach (c; have)
        if (abs(c.weight - weight) < abs(best.weight - weight) || (abs(c.weight - weight) == abs(best.weight - weight)
            && c.weight > best.weight && weight > 400))
            best = c;
    string nameOf(int w) => weightNames[w][0];
    if (best.weight != weight)
        warn(format("'%s' has no %s weight installed: the text uses %s", family, nameOf(weight), nameOf(best.weight)),
            format("its weights: %-(%s, %)", have.map!(c => nameOf(c.weight))));
    immutable styles = stylesOf.get(best.family, 1);
    int want = best.bold ? (italic ? 3 : 1) : (italic ? 2 : 0);
    if (!(styles & (1 << want)))
    {
        if (italic)
            warn(format("'%s' has no italic installed: the text stands upright", best.family),
                "give a font that has one, or its file's path");
        return tuple!("family", "style")(best.family, best.bold ? 1 : 0);
    }
    return tuple!("family", "style")(best.family, want);
}

/// A weight's name ("Light", any case) as a number; 0 for a word that is none.
private int fontWeight(string name)
{
    foreach (w, names; weightNames)
        foreach (n; names)
            if (n.toLower == name.toLower)
                return w;
    return 0;
}
