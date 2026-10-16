/// Language test suite: runs .hcad snippets and checks output, errors and
/// geometry. Snippets passed to `output` run inside a unittest block.
module hackerscad.lang.tests;

version (unittest):

import std.algorithm : map, canFind, count;
import std.array : array, join;
import std.format : format;
import std.conv : to;
import std.math : isClose, PI, sqrt, abs;
import std.file : tempDir, mkdirRecurse, write, rmdirRecurse;
import std.path : buildPath;

import hackerscad.lang.interp;
import hackerscad.lang.errors;
import hackerscad.lang.value : Value, Dim;
import hackerscad.geom.color;
import hackerscad.kernel.occt.backend;
import hackerscad.kernel.brep : BoolOp, Brep, Vec3;

private:

__gshared OcctKernel kernel;

/// The first line of a test that takes a second or more (threads, sweeps,
/// meshes, the libraries and examples): skipped when HCAD_TESTS=fast, for a
/// quick run while working; run otherwise, before a commit and by the CI.
enum slowTest = q{
    if (skipSlow())
        return;
};

__gshared int skipped;   /// slow tests left out this run

bool skipSlow()
{
    import std.process : environment;
    immutable skip = environment.get("HCAD_TESTS") == "fast";
    if (skip)
        skipped++;
    return skip;
}

shared static ~this()
{
    import std.stdio : stderr;
    if (skipped)
        stderr.writefln("HCAD_TESTS=fast: %d slow tests of lang/tests.d skipped (run them all before a commit)", skipped);
}

Interp make()
{
    if (kernel is null)
        kernel = new OcctKernel;
    return new Interp(kernel);
}

EvalResult runModel(string src, Interp it = null)
{
    if (it is null)
        it = make();
    return it.runSource(src, buildPath(tempDir, "hcad-test.hcad"));
}

/// Runs `code` inside a unittest block and returns what writeln printed.
string output(string code, string decls = "")
{
    auto r = runModel(decls ~ "\nunittest {\n" ~ code ~ "\n}\n");
    foreach (d; r.diagnostics)
        if (d.severity == Severity.error)
            assert(0, format("unexpected error %s: %s (line %d)\n%s", d.code, d.message, d.span.line, code));
    return r.log.map!(l => l.text).join("\n");
}

/// The first error raised by a model (thrown or from a failed unittest).
Diagnostic error(string src, Interp it = null)
{
    try
    {
        auto r = runModel(src, it);
        foreach (d; r.diagnostics)
            if (d.severity == Severity.error)
                return d;
    }
    catch (HcadError e)
        return e.diag;
    assert(0, "expected an error:\n" ~ src);
}

Diagnostic errorIn(string code, string decls = "") => error(decls ~ "\nunittest {\n" ~ code ~ "\n}\n");

void expectOut(string code, string expected, string decls = "", size_t line = __LINE__)
{
    auto got = output(code, decls);
    assert(got == expected, format("line %d: expected\n%s\ngot\n%s", line, expected, got));
}

void expectErr(string code, string errCode, string decls = "", size_t line = __LINE__)
{
    auto d = errorIn(code, decls);
    assert(d.code == errCode, format("line %d: expected %s, got %s: %s", line, errCode, d.code, d.message));
}

double partVolume(EvalResult r, string name)
{
    foreach (p; r.parts)
        if (p.name == name)
            return kernel.volume(p.solid.brep);
    assert(0, "no part " ~ name);
}

// ---------------------------------------------------------------- expressions

unittest
{
    expectOut("writeln(7 / 2, \" \", 7.0 / 2, \" \", 7 % 3, \" \", -7 / 2);", "3 3.5 1 -3");
    expectOut("writeln(1 + 2 * 3, \" \", (1 + 2) * 3, \" \", -2 ^^ 2, \" \", 2 ^^ 3 ^^ 2);", "7 9 -4 512");
    expectOut("writeln(3 > 2 && 2 > 1, \" \", !true || false, \" \", 1 == 1.0, \" \", 5 & 3, \" \", 5 | 3);",
        "true false true 1 7");
    expectOut("writeln(true ? \"yes\" : \"no\", \" \", 1 > 2 ? 1 : 2);", "yes 2");
    expectOut("auto x = 5; x += 2; x *= 3; x -= 1; x /= 4; writeln(x); x++; ++x; x--; writeln(x);", "5\n6");
    expectOut("writeln(0xFF, \" \", 1_000, \" \", 2.5e3);", "255 1000 2500");
}

// ---------------------------------------------------------------- units

unittest
{
    expectOut("writeln(60.mm, \" \", 2.5.cm, \" \", 1.inch, \" \", 45.deg);", "60 mm 25 mm 25.4 mm 45°");
    expectOut("writeln(2 * 60.mm, \" \", 60.mm / 2, \" \", 1.cm == 10.mm, \" \", 3.mm < 1.cm);", "120 mm 30 mm true true");
    expectOut("writeln(10.mm * 10.mm, \" \", sqrt(16.mm * 1.mm), \" \", 1.cm ^^ 3);", "100 mm^2 4 mm 1000 mm^3");
    expectOut("writeln(sin(30.deg), \" \", 60.mm / 1.cm, \" \", atan2(1.mm, 1.mm));", "0.5 6 45°");
    expectOut("Length f(Length x) => x * 2; writeln(f(5), \" \", f(5.mm));", "10 mm 10 mm");
    expectErr("auto x = 60.mm + 5;", Code.units);
    expectErr("auto x = 60.mm + 45.deg;", Code.units);
    expectErr("auto x = 3.mm < 2;", Code.units);
    expectErr("auto x = sin(3.mm);", Code.units);
    expectErr("auto x = 3.mm.mm;", Code.units);
    expectErr("Length f(Length x) => x; auto y = f(3.deg);", Code.units);
}

unittest
{
    // @unit(inch): bare lengths in this file are inches
    auto r = runModel("@unit(inch) module m;\n@part Solid p() { return box(1, 1, 1); }\nunittest { writeln(box(1, 2, 3).bbox.size.y); }");
    assert(isClose(partVolume(r, "p"), 25.4 ^^ 3, 1e-9));
    assert(r.log[0].text == "50.8 mm");
    assert(error("@unit(deg) module m;").code == Code.type);
}

// ---------------------------------------------------------------- strings

unittest
{
    expectOut(`writeln("a" ~ "b", " ", 1 ~ "-" ~ 2.mm, " ", format("%d|%.2f|%s|%5.1f", 42, 3.14159, 2.mm, 2.mm));`,
        "ab 1-2 mm 42|3.14|2 mm|  2.0");
    // "…" interpolates $(expr); \$ is a literal dollar; backticks are WYSIWYG as in D
    expectOut(`immutable w = 20.mm; writeln("w = $(w), twice $(w * 2), $("q" ~ "r") \$(w)");`, "w = 20 mm, twice 40 mm, qr $(w)");
    expectOut("writeln(`raw $(x) \\n`);", `raw $(x) \n`);
    expectOut(`writeln("a\tb".length, " ", "line $(1 + 1)\n".length);`, "3 7");
    expectErr(`auto s = "a $(1 +";`, Code.lex);
    expectErr(`auto s = "a $(nope)";`, Code.undefined);
    expectErr(`auto s = text(1, "-");`, Code.type);
    expectOut(`writeln(to!string(3) ~ "!", " ", "42".to!int + 1, " ", "abc".length, " ", "abc"[1], " ", "hello"[1 .. $ - 1]);`,
        "3! 43 3 b ell");
    expectOut("writeln(\"a\\tb\" == `a\tb`, \" \", r\"\\n\".length);", "true 2");
    expectOut(`writeln("a" ~ 1 ~ true);`, "a1true");   // a string joins anything
    expectErr(`auto s = 2.5.to!int;`, Code.type);
}

// ---------------------------------------------------------------- arrays and associative arrays

unittest
{
    expectOut("auto a = [1, 2, 3]; a ~= 4; writeln(a, \" \", a.length, \" \", a[$ - 1], \" \", a[1 .. 3], \" \", a ~ [5]);",
        "[1, 2, 3, 4] 4 4 [2, 3] [1, 2, 3, 4, 5]");
    // value semantics: copies do not alias
    expectOut("auto a = [1, 2]; auto b = a; b[0] = 9; writeln(a, \" \", b);", "[1, 2] [9, 2]");
    expectOut("int[] a; a ~= 1; Length[] l = [1, 2]; writeln(a, \" \", l);", "[1] [1 mm, 2 mm]");
    expectOut("auto m = [\"a\": 1, \"b\": 2]; m[\"c\"] = 3; writeln(\"b\" in m, \" \", \"z\" in m, \" \", m[\"c\"], \" \", m.length);",
        "true false 3 3");
    expectOut("auto g = [[1, 2], [3, 4]]; g[1][0] = 7; writeln(g);", "[[1, 2], [7, 4]]");
    expectErr("auto a = [1, 2]; auto x = a[5];", Code.index);
    expectErr("auto a = [1, 2]; auto x = a[1 .. 5];", Code.index);
    expectErr("auto m = [\"a\": 1]; auto x = m[\"b\"];", Code.index);
    expectErr("int[] a = [1, \"x\"];", Code.type);
}

// ---------------------------------------------------------------- control flow

unittest
{
    expectOut("int s; foreach (i; 0 .. 5) s += i; writeln(s);", "10");
    expectOut("string r; foreach (i, x; [\"a\", \"b\"]) r ~= \"$(i)$(x)\"; writeln(r);", "0a1b");
    expectOut("int[] r; foreach_reverse (i; 0 .. 3) r ~= i; writeln(r);", "[2, 1, 0]");
    expectOut("int s; foreach (k, v; [\"a\": 1, \"b\": 2]) s += v; writeln(s);", "3");
    expectOut("int s; for (int i = 0; i < 10; i++) { if (i == 2) continue; if (i == 5) break; s += i; } writeln(s);", "8");
    expectOut("int i; while (i < 3) i++; writeln(i);", "3");
    expectOut("foreach (x; [1, 2, 3]) switch (x) { case 1: writeln(\"one\"); break; case 2, 3: writeln(\"many\"); break; default: writeln(\"?\"); }",
        "one\nmany\nmany");
    expectOut("if (1 > 2) writeln(\"a\"); else if (2 > 1) writeln(\"b\"); else writeln(\"c\");", "b");
    expectErr("switch (3) { case 1: break; }", Code.type);
    expectErr("assert(1 > 2, \"no\");", Code.assertion);
}

// ---------------------------------------------------------------- functions

unittest
{
    enum decls = q{
        int fact(int n) { return n <= 1 ? 1 : n * fact(n - 1); }
        double area(double w, double h = 2) => w * h;
        int twice(int x) => x * 2;
        auto adder(int k) { return (int x) => x + k; }
    };
    expectOut("writeln(fact(10), \" \", area(3), \" \", area(h: 4, w: 2), \" \", adder(3)(4));", "3628800 6 8 7", decls);
    expectOut("int sq(int x) { return x * x; } writeln(sq(4), \" \", 4.sq, \" \", [1, 2].map(&twice));", "16 16 [2, 4]", decls);
    expectErr("auto x = [1].map!(x => x);", Code.syntax);   // functions are normal arguments
    expectOut("auto f = &twice; writeln(f(5), \" \", ((a, b) => a * b)(3, 4), \" \", ((x) { return x + 1; })(1));", "10 12 2", decls);
    expectErr("auto x = area(1, 2, 3);", Code.arity, decls);
    expectErr("auto x = area(h: 1);", Code.missingArg, decls);
    auto d = errorIn("auto x = area(1, hh: 2);", decls);
    assert(d.code == Code.unknownArg && d.suggestion == "did you mean 'h'?");
    expectErr("auto x = twice(\"a\");", Code.type, decls);
    expectErr("auto x = twice(2.5);", Code.type, decls);
    expectErr("int loop(int n) => loop(n + 1); auto x = loop(0);", Code.limit);
    expectErr("void f() { return 1; } f();", Code.type);
    expectErr("int f() { } auto x = f();", Code.type);
}

unittest
{
    // paren-less calls of declared functions, as in D
    expectOut("writeln(answer + 1, \" \", answer.twice);", "43 84", "int answer() => 42; int twice(int x) => x * 2;");
    // closures capture their scope
    expectOut("int k = 10; auto f = (int x) => x + k; writeln(f(1));", "11");
}

// ---------------------------------------------------------------- structs

unittest
{
    enum decls = q{
        struct Screw
        {
            string name;
            Length d;
            Length head = 5.mm;
            Length clearance() => d + 0.4.mm;
            Length scaled(double k) => d * k;
        }
    };
    expectOut("auto s = Screw(\"M3\", 3); writeln(s.d, \" \", s.head, \" \", s.clearance, \" \", s.scaled(2));",
        "3 mm 5 mm 3.4 mm 6 mm", decls);
    expectOut("auto s = Screw(d: 4.mm, name: \"M4\"); s.head = 7; writeln(s);", "Screw(name: M4, d: 4 mm, head: 7 mm)", decls);
    expectOut("Screw s; writeln(s.d, \" \", Screw.init.head);", "0 mm 5 mm", decls);
    expectOut("auto a = Screw(\"a\", 1); auto b = a; b.d = 2; writeln(a.d, \" \", b.d, \" \", a == Screw(\"a\", 1));", "1 mm 2 mm true", decls);
    expectErr("auto s = Screw(\"a\", 1, 2, 3);", Code.arity, decls);
    auto d = errorIn("auto s = Screw(diam: 3);", decls);
    assert(d.code == Code.unknownArg);
    expectErr("auto s = Screw(\"a\", \"b\");", Code.type, decls);
    expectErr("auto s = Screw(\"a\", 1); auto x = s.weight;", Code.undefined, decls);
}

// ---------------------------------------------------------------- algorithms

unittest
{
    expectOut("auto a = [3, 1, 2]; writeln(a.sort, \" \", a.sort((x, y) => x > y), \" \", a.reverse, \" \", a);",
        "[1, 2, 3] [3, 2, 1] [2, 1, 3] [3, 1, 2]");
    expectOut("auto a = iota(1, 6); writeln(a.filter(x => x % 2).map(x => x * 10), \" \", a.sum, \" \", a.fold((s, x) => s * x), \" \", a.fold((s, x) => s + x, 100));",
        "[10, 30, 50] 15 120 115");
    expectOut("writeln([1, 2].any(x => x > 1), [1, 2].all(x => x > 1), \" \", [1, 2, 3].count(x => x > 1), \" \", [1, 2].canFind(2), [1, 2].canFind(x => x > 5));",
        "truefalse 2 truefalse");
    expectOut("writeln(cartesianProduct([1, 2], [3, 4]), \" \", zip([1, 2], [\"a\", \"b\"]), \" \", [\"x\"].enumerate);",
        `[[1, 3], [1, 4], [2, 3], [2, 4]] [[1, "a"], [2, "b"]] [[0, "x"]]`);
    expectOut("writeln(iota(0.mm, 3.mm), \" \", iota(0, 1, 0.25), \" \", min(3, 1, 2), \" \", [2.mm, 5.mm].maxElement, \" \", clamp(15, 0, 10));",
        "[0 mm, 1 mm, 2 mm] [0, 0.25, 0.5, 0.75] 1 5 mm 10");
    expectOut("writeln([\"a\", \"b\"].join(\"-\"), \" \", vec(1, 2, 3) + vec(1, 1, 1), \" \", vec(3.mm, 4).length, \" \", dot(X, Y), \" \", cross(X, Y));",
        "a-b [2, 3, 4] 5 mm 0 [0, 0, 1]");
    expectErr("auto x = [1].map(2);", Code.arity);
    expectErr("auto x = iota(0, 1, 0);", Code.type);
}

// ---------------------------------------------------------------- module scope

unittest
{
    // order independent globals, like D module scope
    expectOut("writeln(b);", "3", "immutable b = a + 1; immutable a = 2;");
    expectErr("", Code.redefined, "immutable a = b; immutable b = a; @part Solid p() { return box(a, a, a); }");
    expectErr("a = 3;", Code.immutable_, "immutable a = 2;");
    expectErr("a = 3;", Code.immutable_, "auto a = 2;");
    expectErr("immutable x = 1; x = 2;", Code.immutable_);
    expectErr("auto x = 1; auto x = 2;", Code.redefined);
    expectErr("", Code.redefined, "immutable a = 1; immutable a = 2;");
    auto d = errorIn("auto x = lenght;", "immutable length_ = 1; immutable lenghts = 2;");
    assert(d.code == Code.undefined && d.span.line == 3 && d.span.col == 10);
    assert(error("writeln(1);").code == Code.syntax);  // statements are not allowed at module level
    assert(error("class Foo {}").code == Code.syntax);
}

// ---------------------------------------------------------------- params, presets, parts

unittest
{
    enum model = q{
        @param("Width", min: 10.mm, max: 100.mm) @preset("big", 80.mm) @preset("small", 15) immutable w = 20.mm;
        @param(choices: ["a", "b"]) @preset("big", "b") immutable variant = "a";
        @part("red") Solid p() { writeln("p evaluated"); return box(w, 10, 10); }
        @part Solid q() { return box(1, 1, 1).nextTo(p, X, gap: 5) .color("#00FF00"); }
    };
    auto r = runModel(model);
    assert(r.params.length == 2 && r.params[0].doc == "Width" && r.params[1].choices.length == 2);
    assert(r.presets == ["big", "small"]);
    assert(r.params[0].presets["small"] == Value.number(15, Dim.length) && r.params[1].presets["big"] == Value.of("b"));
    assert(r.parts.length == 2 && r.parts[0].rgb == 0xFF0000 && r.parts[1].rgb == 0x00FF00);
    assert(r.log.length == 1, "a @part is evaluated once even when referenced");
    assert(isClose(partVolume(r, "p"), 2000));
    assert(isClose(kernel.bbox(r.parts[1].solid.brep).min.x, 15.0, 1e-6));

    // transparency and reference parts
    r = runModel(q{
        @part("#FF000080") Solid a() => box(1, 1, 1);
        @part("slategray", alpha: 0.25, export: false) Solid b() => box(1, 1, 1);
        @part Solid c() => box(1, 1, 1).color(rgb(0, 0, 255, alpha: 1));
        @part Solid d() => box(1, 1, 1);
    });
    assert(rgbPart(r.parts[0].rgb) == 0xFF0000 && isClose(alphaOf(r.parts[0].rgb), 128 / 255.0, 1e-9));
    assert(isClose(alphaOf(r.parts[1].rgb), 0.25, 0.01) && !r.parts[1].export_ && r.parts[0].export_);
    assert(r.parts[2].rgb == 0x0000FF && r.parts[3].rgb == defaultPartColor);
    assert(hexColor(r.parts[0].rgb) == "#FF000080" && hexColor(r.parts[2].rgb) == "#0000FF");

    // the name in exported files: name:, else the function's; two alike are refused
    r = runModel(q{
        @part("orange", name: "Big tank") Solid tank() => box(2, 2, 2);
        @part Solid pot() => box(1, 1, 1);
    });
    assert(r.parts[0].label == "Big tank" && r.parts[1].label == "pot" && r.parts[0].name == "tank");
    auto same = error(`@part(name: "pot") Solid a() => box(1, 1, 1); @part Solid pot() => box(1, 1, 1);`);
    assert(same.message.canFind("same name"), same.message);
    assert(error(`@part(name: 3) Solid a() => box(1, 1, 1);`).message.canFind("a text"));

    auto it = make();
    it.overrides["w"] = "50";      // bare number: model unit
    assert(isClose(partVolume(runModel(model, it), "p"), 5000));
    it = make();
    it.preset = "big";
    assert(isClose(partVolume(runModel(model, it), "p"), 8000));
    it = make();
    it.overrides["w"] = "500.mm";
    assert(error(model, it).code == Code.type);
    it = make();
    it.overrides["variant"] = `"c"`;
    assert(error(model, it).code == Code.type);
    it = make();
    it.overrides["ww"] = "1";
    auto d = error(model, it);
    assert(d.code == Code.undefined && d.suggestion == "did you mean 'w'?");
    it = make();
    it.preset = "huge";
    assert(error(model, it).code == Code.undefined);

    assert(error("@part Solid p() { return 3; }").code == Code.type);
    assert(error("@part Solid p(int x) { return box(1, 1, 1); }").code == Code.arity);
    assert(runModel("immutable a = 1;").diagnostics[0].severity == Severity.warning);
    assert(error("enum a = 1;").code == Code.syntax);
    assert(error("@param(max: 5) @preset(\"x\", 9) immutable a = 1;").code == Code.type);   // presets are checked too
    assert(error("@preset(\"x\", 9) immutable a = 1;").code == Code.syntax);
    assert(error("@prams immutable a = 1;").suggestion == "did you mean 'param'?");
    assert(error("@param @preset(9) immutable a = 1;").code == Code.syntax);

    // a failed unittest is reported but the geometry is kept
    auto f = runModel("@part Solid p() { return box(1, 1, 1); }\nunittest { assert(p.volume > 2.mm ^^ 3, \"too small\"); }");
    assert(f.parts.length == 1 && f.diagnostics[0].code == Code.assertion && f.diagnostics[0].message == "too small");
}

// ---------------------------------------------------------------- imports and sandbox

unittest
{
    expectOut("writeln(M3.d, \" \", M3.tap);", "3 mm 2.5 mm", "import hardware : M3;");
    expectOut("writeln(hw.M4.clearance);", "4.5 mm", "import hw = hardware;");
    expectOut("writeln(PI > 3);", "true", "import std.math; import std.algorithm;");
    assert(error("import std.nope;").code == Code.import_);
    assert(error("import hardware : M99;").code == Code.import_);
    assert(error("import lib.missing;").code == Code.import_);

    // project modules, with private symbols
    auto dir = buildPath(tempDir, "hcad-import-test");
    mkdirRecurse(buildPath(dir, "lib"));
    scope (exit)
        rmdirRecurse(dir);
    write(buildPath(dir, "lib", "parts.hcad"), "module lib.parts;\nLength twice(Length x) => x * 2;\nprivate immutable secret = 1;\n");
    auto it = make();
    it.root = dir;
    auto r = it.runSource("import lib.parts;\nimport p = lib.parts;\nunittest { writeln(twice(2), \" \", p.twice(3.mm)); }",
        buildPath(dir, "main.hcad"));
    assert(r.log[0].text == "4 mm 6 mm");
    it = make();
    it.root = dir;
    assert(error("import p = lib.parts;\nunittest { auto x = p.secret; }", it).code == Code.undefined);
}

unittest
{
    // libraries: a folder with package.hcad re-exporting its modules, found
    // in a library folder; the project comes first
    auto base = buildPath(tempDir, "hcad-library-test");
    auto lib = buildPath(base, "lib"), project = buildPath(base, "project");
    mkdirRecurse(buildPath(lib, "pizza"));
    mkdirRecurse(project);
    scope (exit)
        rmdirRecurse(base);
    write(buildPath(lib, "pizza", "package.hcad"), "module pizza;\npublic import pizza.base, pizza.toppings;\n");
    write(buildPath(lib, "pizza", "base.hcad"), "module pizza.base;\nLength crust(Length d) => d / 20;\n");
    write(buildPath(lib, "pizza", "toppings.hcad"),
        "module pizza.toppings;\nimport pizza.base;\ndouble slices(Length d) => floor(crust(d) / 1.mm) * 2;\n");
    write(buildPath(lib, "olive.hcad"), "module olive;\nimmutable from = \"library\";\n");
    write(buildPath(project, "olive.hcad"), "module olive;\nimmutable from = \"project\";\n");

    Interp at(string dir)
    {
        auto it = make();
        it.root = dir;
        it.libraryDirs = [lib];
        return it;
    }

    auto r = at(project).runSource("import pizza;\nimport p = pizza;\nimport pizza : slices;\nimport olive;\n"
        ~ "unittest { writeln(crust(300.mm), \" \", p.slices(300.mm), \" \", slices(100.mm), \" \", from); }",
        buildPath(project, "main.hcad"));
    assert(r.log[0].text == "15 mm 30 10 project", r.log[0].text);

    // not found: the message lists where it looked
    auto e = error("import calzone;", at(project));
    assert(e.code == Code.import_ && e.message.canFind("calzone/package.hcad") && e.message.canFind(lib));
}

unittest
{
    // resource limits stop runaway models
    auto it = make();
    it.limits.steps = 10_000;
    assert(error("unittest { while (true) {} }", it).code == Code.limit);
}

// ---------------------------------------------------------------- geometry

unittest
{
    auto r = runModel(q{
        @part Solid a() { return box(10, 20, 30); }
        @part Solid b() { return cylinder(d: 10, h: 10) - cylinder(r: 2, h: 10); }
        @part Solid c() { return sphere(5).move(x: 100) + box(2, 2, 2, center: true).move(vec(100, 0, 0)); }
        @part Solid d() { return box(10, 10, 10) & box(10, 10, 10).move(x: 5); }
        @part Solid e() { return box(10, 20, 30).rotate(z: 90); }
        @part Solid f() { return Solid.init + box(1, 1, 1) - nothing; }
    });
    assert(isClose(partVolume(r, "a"), 6000));
    auto ba = kernel.bbox(r.parts[0].solid.brep);
    assert(isClose(ba.min.x, -5.0) && isClose(ba.min.z, 0.0, 0, 1e-9) && isClose(ba.max.z, 30.0));
    assert(isClose(partVolume(r, "b"), PI * (25 - 4) * 10, 1e-6));
    assert(isClose(partVolume(r, "c"), 4.0 / 3 * PI * 125, 1e-6));
    assert(isClose(partVolume(r, "d"), 500));
    auto be = kernel.bbox(r.parts[4].solid.brep);
    assert(isClose(be.size.x, 20.0, 1e-6) && isClose(be.size.y, 10.0, 1e-6));
    assert(isClose(partVolume(r, "f"), 1));
}

unittest
{
    // features with selectors, as in the example box
    auto r = runModel(q{
        @part Solid filleted() { return box(40, 30, 20).fillet(edges.filter(e => e.isParallel(Z)), r: 5); }
        @part Solid same() { return box(40, 30, 20).fillet(edges.parallel(Z), r: 5); }
        @part Solid hollow() { return box(40, 30, 20).shell(open: faces.top, thickness: 2); }
        @part Solid chamfered() { return box(10, 10, 10).chamfer(edges.filter(e => e.mid.z > 5.mm), d: 1); }
        unittest
        {
            writeln(hollow.bbox.size.z, " ", filleted.volume < 24000.mm ^^ 3);
        }
    });
    immutable filletVol = 24_000 - 4 * (25 - PI * 25 / 4) * 20;
    assert(isClose(partVolume(r, "filleted"), filletVol, 1e-6));
    assert(isClose(partVolume(r, "same"), filletVol, 1e-6));
    assert(isClose(partVolume(r, "hollow"), 24_000 - 36 * 26 * 18, 1e-6));
    // the chamfered top is a frustum: 10x10 at the base of the chamfer, 8x8 on top
    assert(isClose(partVolume(r, "chamfered"), 1000 - (100 - (64 + 100 + 80) / 3.0), 1e-6));
    assert(r.log[0].text == "20 mm true");

    // a union leaves no seam where two faces lie on one plane: chamfering the
    // edges round the joined top is the same as on one box
    auto joined = runModel(q{
        @part Solid joined() => (box(10, 10, 10).move(x: -5) + box(10, 10, 10).move(x: 5))
            .chamfer(edges.of(faces.top), d: 1);
        @part Solid whole() => box(20, 10, 10).chamfer(edges.of(faces.top), d: 1);
        @part Solid overlapping() => (box(10, 10, 10).move(x: -4) + box(12, 10, 10).move(x: 5))
            .chamfer(edges.of(faces.filter(f => f.center.y < -4.9.mm)), d: 1);
        @part Solid single() => box(20, 10, 10).move(x: 1)
            .chamfer(edges.of(faces.filter(f => f.center.y < -4.9.mm)), d: 1);
    });
    assert(isClose(partVolume(joined, "joined"), partVolume(joined, "whole"), 1e-6));
    assert(isClose(partVolume(joined, "overlapping"), partVolume(joined, "single"), 1e-6));

    // across: a profile stood up across X, as extrude(along: X) does; a loft along X through two
    auto stood = runModel(q{
        @part Solid a() => rect(10, 4).across(X).extrude(3);
        @part Solid b() => rect(10, 4).extrude(3, along: X);
        @part Solid c() => loft([rect(10, 4).across(X), circle(d: 4).across(X).move(x: 20)]);
    });
    foreach (d; stood.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(isClose(partVolume(stood, "a"), partVolume(stood, "b"), 1e-6));
    auto loftBox = stood.parts[2].solid;
    assert(abs(make().kernel.bbox(loftBox.brep).size.x - 20) < 1e-6, "the loft runs along X");

    // a taper narrows going away from the profile, whichever way the solid goes; along: X goes towards +X,
    // a negative height the other way; and the reference says so
    auto ways = runModel(q{
        @part Solid down() => rect(10, 10).extrude(-10, taper: 10.deg);
        @part Solid x() => rect(10, 10).extrude(10, taper: 10.deg, along: X);
        @part Solid minusX() => rect(10, 10).extrude(-10, taper: 10.deg, along: X);
    });
    foreach (d; ways.diagnostics)
        assert(d.severity != Severity.error, d.message);
    foreach (i, lo; [-10.0, 0, -10])
    {
        auto b = make().kernel.bbox(ways.parts[i].solid.brep);
        immutable from = i == 0 ? b.min.z : b.min.x, to = i == 0 ? b.max.z : b.max.x;
        assert(abs(from - lo) < 1e-6 && abs(to - (lo + 10)) < 1e-6, ways.parts[i].name);
    }
    auto narrow = runModel(q{
        @part Solid a() => rect(10, 10).extrude(-10, taper: 10.deg).section(XY.offset(-9.mm)).extrude(1);
        @part Solid b() => rect(10, 10).extrude(-10, taper: 10.deg, along: X).section(YZ.offset(-9.mm)).extrude(1);
    });
    import std.math : tan;
    immutable side = 10 - 2 * 9 * tan(10 * PI / 180);
    foreach (i; 0 .. 2)
        assert(isClose(partVolume(narrow, i ? "b" : "a"), side * side, 1e-4), narrow.parts[i].name);
    import hackerscad.lang.reference : lookupRef;
    import std.algorithm : any;
    assert(lookupRef("extrude").any!(r => r.doc.canFind("going away from the profile") && r.doc.canFind("towards +X")));

    // two arcs meeting (a hole with its printing notch, grown): tapered in a moment (the draft ran for minutes)
    import std.datetime.stopwatch : StopWatch, AutoStart;
    auto clock = StopWatch(AutoStart.yes);
    auto notch = runModel(q{
        Profile notched() => circle(d: 3.3) + circle(vec(0, 1.5), r: 0.5) + rect(vec(-0.5, 0), vec(0.5, 1.5));
        @part Solid a() => notched().offset(0.5).extrude(1, taper: 30.deg);
        @part Solid b() => notched().offset(0.5).extrude(1, taper: -20.deg);
    });
    foreach (d; notch.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(clock.peek.total!"seconds" < 5 && partVolume(notch, "a") > 5 && partVolume(notch, "b") > partVolume(notch, "a"));
    // arcs that meet and corners that close exactly at the top (a hole's mouth chamfered): made
    auto mouth = runModel(q{
        @part Solid a() => (circle(d: 10) & rect(8, 20)).offset(0.5).extrude(0.5, taper: 45.deg);
    });
    foreach (d; mouth.diagnostics)
        assert(d.severity != Severity.error, d.message);
    // a taper that closes a rounded corner on the way fails at once
    auto closing = error(q{
        @part Solid a() => rect(4, 3).offset(0.5).extrude(1, taper: 30.deg);
    });
    assert(closing.message.canFind("closes up") && clock.peek.total!"seconds" < 5, closing.message);
    // as far as it lasts, it is made: the corner closing exactly at the top
    auto lasting = runModel(q{
        @part Solid a() => rect(10, 6).offset(1).extrude(1, taper: 45.deg);
    });
    foreach (d; lasting.diagnostics)
        assert(d.severity != Severity.error, d.message);

    // a bare number next to a length, an unknown colour: the fix in the suggestion
    assert(error("@param(\"x\") immutable x = 3.mm;\n@part Solid a() => box(10, 10, 10).move(x: x - 1.5);")
        .suggestion == "write the bare number with its unit: 1.5.mm");
    assert(error(`@part Solid a() => box(10, 10, 10).color("sky");`).suggestion.canFind("skyblue"));

    // a part that comes out broken says which of its steps broke it, and points there
    auto broken = runModel("@part Solid a() => box(10, 10, 10);\n"
        ~ "@part Solid b() => box(10, 10, 10) + circle(d: 8).sweep(path([vec(0, 0, 0), vec(0, 0, 12), vec(1, 0, 12)]))"
        ~ ".move(x: 3);\n");
    bool told;
    foreach (d; broken.diagnostics)
        if (d.message.canFind("not a valid closed solid"))
        {
            assert(d.message.canFind("first broken by the sweep at line 2") && d.span.line == 2, d.message);
            told = true;
        }
    assert(told, "the broken part is told");

    // where the faces cannot be merged ("Courbes non jointives"), the union
    // is still made, as it was before faces were merged
    auto unmerged = runModel(q{
        Solid alongX(Profile p, double x0, double x1) => p.extrude(x1 - x0, along: X).move(x: x0);
        @part Solid c()
        {
            auto bolt = slot(vec(1.85, 12), vec(1.85, 15), w: 3.2.mm) + rect(vec(1.25, 15), vec(2.45, 17.25));
            return alongX(bolt, -19.75, 0.76)
                + polygon([vec(0.7, 0.25), vec(0.95, 1.25), vec(0.95, 2.45), vec(0.7, 3.45)]).extrude(6.85.mm)
                    .move(z: 10.4.mm)
                + box(1.1, 1.2, 5.7).move(x: 1.25, y: 1.85, z: 11)
                + alongX(circle(vec(1.85, 15), d: 3.2.mm), -21, -19);
        }
    });
    foreach (d; unmerged.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(isClose(partVolume(unmerged, "c"), 397.4, 1e-3), partVolume(unmerged, "c").to!string);

    assert(error("@part Solid p() { return box(1, 1, 1).fillet(edges.filter(e => e.length > 5.mm), r: 0.1); }").code == Code.kernel);
    assert(error("@part Solid p() { return box(1, 1, 1).fillet(faces.top, r: 0.1); }").code == Code.type);
    assert(error("@part Solid p() { return box(1, 1, 1).fillet(edges!(e => e.isLine), r: 0.1); }").code == Code.syntax);
    assert(error("@part Solid p() { return box(1, 1, 1).fillet(edges, r: 5); }").code == Code.kernel);
    assert(error("@part Solid p() { return box(-1, 1, 1); }").code == Code.type);
    assert(error("@part Solid p() { return cylinder(r: 1, d: 2, h: 1); }").code == Code.unknownArg);
    assert(error("@part Solid p() { return box(1, 1, 1) + 3; }").code == Code.type);
    assert(error("@part Solid p() { return box(1, 1, 1).color(\"blu\"); }").suggestion == "did you mean 'blue'?");
}

unittest
{
    // an object type declared without a value starts as null, then takes one
    auto r = runModel(q{
        @part Solid p()
        {
            auto s = sketch();
            SketchArc first;
            writeln(first);
            first = s.arc(s.point(0, 0), s.point(5, 0), s.point(0, 5));
            s.radius(first, 5.mm);
            writeln(first);
            return box(1, 1, 1);
        }
    });
    assert(r.log[0].text == "null" && r.log[1].text == "SketchArc", r.log[0].text ~ " / " ~ r.log[1].text);
}

unittest
{
    // the tutorial's Carlo: a sketch fully constrained, one valid part, with 3 teeth, 5 and 1, without the eye, the mouth closed
    import std.file : thisExePath, readText;
    import std.path : dirName;
    auto path = buildPath(dirName(dirName(dirName(thisExePath))), "docs", "tutorial", "13-carlo.hcad");
    string[string][] cases = [["teeth": "3"], ["teeth": "5"], ["eye": "false"], ["teeth": "1"], ["mouth": "-2"]];
    foreach (o; cases)
    {
        auto teeth = o.to!string;
        auto it = make();
        it.overrides = o;
        auto r = it.run(path);
        foreach (d; r.diagnostics)
            assert(d.severity != Severity.error && d.severity != Severity.warning, d.message);
        assert(r.parts.length == 1 && kernel.isValid(r.parts[0].solid.brep), teeth);
        assert(r.log[0].text == "degrees of freedom left: 0", r.log[0].text);
    }
}

unittest
{
    // Carlo in three places kept the same: the tutorial's sketch, lib/carlo.hcad and the start
    // example; valid with one tooth or six, the mouth closed, leaning 0° or 30°
    import std.file : thisExePath, readText;
    import std.path : dirName;
    import std.string : indexOf;
    auto root = dirName(dirName(dirName(thisExePath)));
    auto tutorial = readText(buildPath(root, "docs", "tutorial", "13-carlo.hcad"));
    auto sketchCode = tutorial[tutorial.indexOf("    auto s = sketch();") .. tutorial.indexOf("    writeln(")];
    auto library = readText(buildPath(root, "lib", "carlo.hcad"));
    assert(library.indexOf(sketchCode) >= 0, "lib/carlo.hcad no longer draws the sketch of docs/tutorial/13-carlo.hcad");
    // the start example shows the library's carlo(), word for word
    auto carloCode = library[library.indexOf("/// Carlo lying flat") .. $];
    assert(readText(buildPath(root, "examples", "00_carlo.hcad")).indexOf(carloCode) >= 0,
        "examples/00_carlo.hcad no longer shows the carlo() of lib/carlo.hcad");
    string[string][] cases = [null, ["teeth": "1", "mouth": "-2"], ["teeth": "6", "eye": "false"], ["lean": "0"],
        ["lean": "30", "toothR": "4"]];
    foreach (o; cases)
    {
        auto it = make();
        it.overrides = o;
        auto r = it.run(buildPath(root, "examples", "00_carlo.hcad"));
        foreach (d; r.diagnostics)
            assert(d.severity != Severity.error && d.severity != Severity.warning, o.to!string ~ ": " ~ d.message);
        assert(r.parts.map!(p => p.name).array == ["clip"] && kernel.isValid(r.parts[0].solid.brep), o.to!string);
    }
}

unittest
{
    // the pillow block of the tutorial's page 14 is the example's, but for the first line (the
    // menu's entry), and every piece of code on the page is a piece of it, word for word
    import std.file : thisExePath, readText;
    import std.path : dirName;
    import std.string : indexOf, split;
    auto root = dirName(dirName(dirName(thisExePath)));
    auto model = readText(buildPath(root, "docs", "tutorial", "14-pillow-block.hcad"));
    auto example = readText(buildPath(root, "examples", "10_pillowblock.hcad"));
    assert(example[example.indexOf("\n") + 1 .. $] == model,
        "docs/tutorial/14-pillow-block.hcad differs from examples/10_pillowblock.hcad");
    auto page = readText(buildPath(root, "docs", "tutorial", "14-pillow-block.md")).split("```d\n");
    assert(page.length > 1);
    foreach (block; page[1 .. $])
    {
        auto code = block[0 .. block.indexOf("```\n")];
        assert(model.indexOf(code) >= 0, "a piece of code on page 14 is not in its model:\n" ~ code);
    }
}

unittest
{
    mixin(slowTest);
    // the pillow block holds together at the ends of its parameters, its sketches fully constrained
    import std.file : thisExePath;
    import std.path : dirName;
    auto path = buildPath(dirName(dirName(dirName(thisExePath))), "examples", "10_pillowblock.hcad");
    string[string][] cases = [null, ["travel": "2", "uprightDepth": "20"],
        ["footLength": "140", "footWidth": "50", "footHeight": "15", "axisHeight": "50", "uprightWidth": "70",
            "uprightDepth": "10", "travel": "10"],
        ["footLength": "80", "uprightWidth": "40", "axisHeight": "50", "footHeight": "5", "travel": "2"]];
    foreach (o; cases)
    {
        auto it = make();
        it.overrides = o;
        auto r = it.run(path);
        foreach (d; r.diagnostics)
            assert(d.severity != Severity.error && d.severity != Severity.warning, o.to!string ~ ": " ~ d.message);
        assert(r.parts.length == 1 && kernel.isValid(r.parts[0].solid.brep), o.to!string);
    }
}

unittest
{
    mixin(slowTest);
    // the shipped example evaluates with the expected parts and checks
    import std.file : thisExePath, exists;
    import std.path : dirName;

    auto path = buildPath(dirName(dirName(dirName(thisExePath))), "examples", "04_box.hcad");
    assert(exists(path), path);
    auto it = make();
    auto r = it.run(path);
    assert(r.parts.map!(p => p.name).array == ["base", "lid"]);
    assert(r.params.length == 8 && r.presets == ["small", "flat"]);
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(kernel.isValid(r.parts[0].solid.brep) && kernel.isValid(r.parts[1].solid.brep));
}

unittest
{
    // hardware library: a screw and a nut are valid, non-empty solids
    auto r = runModel(q{
        import hardware : M3, M8, screw, nut;
        @part Solid s() => screw(M3, 50.mm);
        @part Solid n() => nut(M8);
    });
    auto bs = kernel.bbox(r.parts[0].solid.brep);
    assert(isClose(bs.max.z, 3.0, 1e-6) && isClose(bs.min.z, -50.0, 1e-6), "head above z = 0, shank below");
    assert(kernel.isValid(r.parts[0].solid.brep) && kernel.isValid(r.parts[1].solid.brep));
    immutable hexArea = 13.0 * 13.0 * 3 / (2 * 1.7320508); // across flats 13 mm
    assert(partVolume(r, "n") < hexArea * 6.8 && partVolume(r, "n") > 0.6 * hexArea * 6.8);
}

unittest
{
    // provenance selectors: round the top rim of holes cut with a pattern
    auto r = runModel(q{
        immutable hole = cylinder(d: 4, h: 20, center: true).move(x: -15);
        immutable holes = hole.linearPattern(4, step: vec(10, 0, 0));
        @part Solid plate()
        {
            auto p = box(50, 20, 5) - holes;
            return p.fillet(edges.between(faces.from(holes), faces.top), r: 0.5);
        }
        @part Solid ring() => cylinder(d: 4, h: 2).move(x: 20).circularPattern(6);
        @part Solid wedge() => box(10, 10, 10).draft(faces.filter(f => f.isParallel(Z)), angle: 5.deg);
        @part Solid snug() => box(5, 5, 5).align(plate, x: "max", y: "min", z: "max");
        unittest
        {
            writeln(holes.volume > 0.mm ^^ 3, " ", distance(box(1, 1, 1), box(1, 1, 1).move(x: 4)));
        }
    });
    import std.math : PI;
    immutable plain = 50.0 * 20 * 5 - 4 * PI * 4 * 5;
    assert(partVolume(r, "plate") < plain && partVolume(r, "plate") > plain - 20, "rims rounded");
    assert(isClose(partVolume(r, "ring"), 6 * PI * 4 * 2, 1e-6));
    // drafted side faces: the top shrinks, the bottom (neutral plane) stays
    assert(partVolume(r, "wedge") < 1000 && kernel.isValid(r.parts[2].solid.brep));
    auto bs = kernel.bbox(r.parts[3].solid.brep);
    assert(isClose(bs.max.x, 25.0, 1e-6) && isClose(bs.min.y, -10.0, 1e-6) && isClose(bs.max.z, 5.0, 1e-6));
    assert(r.log[0].text == "true 3 mm");

    // creators: every face of the plate knows its feature
    auto plate = r.parts[0].solid;
    assert(plate.creators.length == kernel.faces(plate.brep).length);
    foreach (c; plate.creators)
        assert(c > 0);
    import std.algorithm : map, canFind;
    auto kinds = plate.creators.map!(c => r.features[c - 1].kind).array;
    assert(kinds.canFind("box") && kinds.canFind("cylinder") && kinds.canFind("fillet"));

    assert(error("@part Solid p() => box(1, 1, 1).align(box(2, 2, 2), x: \"middle\");").suggestion == "did you mean 'center'?");
    assert(error("@part Solid p() => box(1, 1, 1).linearPattern(0, step: vec(1, 0, 0));").code == Code.type);
}

unittest
{
    // planes, halves and pieces
    auto r = runModel(q{
        immutable block = box(40, 20, 30);
        immutable cut = block.halves(block.plane(faces.top).offset(-10));
        @part Solid above() => cut.above;
        @part Solid below() => cut.below;
        @part Solid tilted() => box(10, 10, 10).halves(plane(origin: vec(0, 0, 5), normal: vec(1, 0, 1))).below;
        immutable sides = (cylinder(d: 30, h: 6) - cylinder(d: 20, h: 6) - box(3, 40, 20)).pieces;
        @part Solid left() => sides[0];
        unittest
        {
            writeln(XY.normal, " ", XY.offset(5.mm).origin, " ", XY.flip.normal, " ", sides.length);
        }
    });
    assert(isClose(partVolume(r, "above"), 40 * 20 * 10.0, 1e-6));
    assert(isClose(partVolume(r, "below"), 40 * 20 * 20.0, 1e-6));
    assert(isClose(partVolume(r, "tilted"), 500, 1e-6));
    assert(kernel.bbox(r.parts[3].solid.brep).center.x < 0, "pieces are ordered along X");
    assert(r.log[0].text == "[0, 0, 1] [0 mm, 0 mm, 5 mm] [0, 0, -1] 2");

    // the faces made by the cut belong to the split feature
    import std.algorithm : map, canFind;
    auto kinds = r.parts[0].solid.creators.map!(c => r.features[c - 1].kind).array;
    assert(kinds.canFind("split") && kinds.canFind("box"));

    assert(error("@part Solid p() => box(1, 1, 1).halves(Z).above;").code == Code.type);
    // split: the pieces of both sides, in order; .above without a plane points at halves
    auto s = runModel(q{
        immutable ring = cylinder(d: 30, h: 6) - cylinder(d: 20, h: 6);
        @parts Solid[] bits() => ring.split(plane(origin: vec(0, 0, 0), normal: X));
        @parts Solid[] four() => ring.split(XZ).above(XZ).sort((a, b) => a.volume > b.volume);
    });
    foreach (d; s.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(s.parts.length == 3 && s.parts[0].name == "bits1" && s.parts[2].name == "four");
    assert(kernel.bbox(s.parts[0].solid.brep).center.x < kernel.bbox(s.parts[1].solid.brep).center.x);
    auto noPlane = error("@part Solid p() => box(10, 10, 10).split(XY.offset(5.mm)).above;");
    assert(noPlane.message.canFind("s.halves(plane).above"), noPlane.message);
    assert(error("@part Solid p() => box(1, 1, 1).plane(faces.normal(X).filter(f => false));").code == Code.kernel);
}

unittest
{
    // frames: build on faces and planes
    auto r = runModel(q{
        immutable body = box(40, 20, 10);
        immutable top = body.frame(faces.top);
        @part Solid boss() => cylinder(d: 4, h: 5).placeOn(top.at(x: 10));
        @part Solid side() => box(2, 2, 3).placeOn(body.frame(faces.right));
        @part Solid pocketed() => body - box(10, 10, 3).move(z: -3).placeOn(top);

        // a face tilted by 30°: a peg placed on it touches it without overlapping
        immutable tilted = box(30, 30, 10).rotate(y: 30);
        immutable peg = cylinder(d: 6, h: 8).placeOn(tilted.frame(faces.filter(f => f.normal.z > 0.8)));
        @part Solid both() => tilted + peg;
        unittest
        {
            writeln(top.origin, " ", top.z, " ", top.turn(90.deg).x, " ", XY.frame(origin: vec(5, 5, 7)).origin);
            writeln(distance(tilted, peg), " ", isClose((tilted + peg).volume, tilted.volume + peg.volume));
        }
        bool isClose(Volume a, Volume b) => abs(a - b) < 1e-3.mm ^^ 3;
    });
    auto bb = kernel.bbox(r.parts[0].solid.brep);
    assert(isClose(bb.min.z, 10.0, 1e-6) && isClose(bb.center.x, 10.0, 1e-6));
    auto bs = kernel.bbox(r.parts[1].solid.brep);
    assert(isClose(bs.min.x, 20.0, 1e-6) && isClose(bs.max.x, 23.0, 1e-6));
    assert(isClose(partVolume(r, "pocketed"), 40 * 20 * 10 - 300.0, 1e-6));
    assert(r.log[0].text == "[0 mm, 0 mm, 10 mm] [0, 0, 1] [0, 1, 0] [5 mm, 5 mm, 0 mm]", r.log[0].text);
    assert(r.log[1].text == "0 mm true", r.log[1].text);

    assert(error("@part Solid p() => box(1, 1, 1).placeOn(X);").code == Code.type);
    assert(error("immutable f = XY.frame(x: Z);\n@part Solid p() => box(1, 1, 1).placeOn(f);").code == Code.type);
}

unittest
{
    // placeOn from: a face of the solid laid against the frame, at: a point of it onto the origin
    auto r = runModel(q{
        immutable body = box(40, 20, 10);
        immutable top = body.frame(faces.top);
        @part Solid lying() => box(4, 6, 8).placeOn(top, from: faces.right);
        @part Solid corner() => box(4, 6, 8).placeOn(top, from: faces.right, at: vec(2, 3, 8));
        @part Solid same() => box(4, 6, 8).placeOn(top.turn(30.deg), from: faces.bottom);
        @part Solid plain() => box(4, 6, 8).placeOn(top.turn(30.deg));
        unittest
        {
            writeln(body.frame(faces.farthest(Z)).origin, " ", body.frame(faces.farthest(X)).origin);
        }
    });
    bool near(double a, double b) => abs(a - b) < 1e-6;
    auto l = kernel.bbox(r.parts[0].solid.brep);
    // its Y along X, its Z along Y, its X up, the right face's middle on the top's
    assert(near(l.size.x, 6) && near(l.size.y, 8) && near(l.size.z, 4), format("%s", l.size));
    assert(near(l.min.z, 10) && near(l.center.x, 0) && near(l.center.y, 0));
    auto c = kernel.bbox(r.parts[1].solid.brep).center;
    assert(near(c.x, -3) && near(c.y, 4) && near(c.z, 12), format("%s", c));
    // the bottom face from: is the same as building on XY
    auto s1 = kernel.bbox(r.parts[2].solid.brep), s2 = kernel.bbox(r.parts[3].solid.brep);
    assert((s1.min - s2.min).length < 1e-6 && (s1.max - s2.max).length < 1e-6);
    assert(r.log[0].text == "[0 mm, 0 mm, 10 mm] [20 mm, 0 mm, 5 mm]", r.log[0].text);
    assert(error("@part Solid p() => box(1, 1, 1).placeOn(XY, at: vec(0, 0, 0));").code == Code.type);
    assert(error("@part Solid p() => box(1, 1, 1).placeOn(XY, from: faces.normal(Z) + faces.normal(-Z));").code == Code.type);
}

unittest
{
    // axes, plane constructors, mirroring across planes
    auto r = runModel(q{
        immutable cube = box(2, 2, 2, center: true);
        @part Solid turned() => cube.rotate(180.deg, axis: axis(origin: vec(10, 0, 0), direction: Z));
        @part Solid mirrored() => cube.mirror(plane(origin: vec(10, 0, 0), normal: X));
        immutable plate = box(40, 40, 4) - cylinder(d: 6, h: 10, center: true).move(x: 10, y: 5);
        immutable holeAxis = plate.axis(edges.filter(e => e.isCircle && e.radius == 3.mm && e.mid.z > 2.mm));
        @part Solid pegs() => cylinder(d: 2, h: 3).move(x: 15, y: 5).circularPattern(4, axis: holeAxis);
        unittest
        {
            writeln(plane(vec(0, 0, 0), vec(1, 0, 0), vec(0, 1, 0)).normal, " ",
                    plane(axis(origin: vec(0, 0, 0), direction: X), vec(0, 0, 5)).normal, " ",
                    holeAxis.origin, " ", abs(holeAxis.direction.z), " ",
                    axis(vec(0, 0, 0), vec(0, 3, 0)).direction, " ", World.at(z: 5).axis(X).origin);
        }
    });
    auto bt = kernel.bbox(r.parts[0].solid.brep);
    assert(isClose(bt.center.x, 20.0, 1e-6) && isClose(bt.center.y, 0.0, 1e-6, 1e-9));
    auto bm = kernel.bbox(r.parts[1].solid.brep);
    assert(isClose(bm.center.x, 20.0, 1e-6));
    // four pegs around the hole at (10, 5): the pattern spans 10 ± 5 + 1 in X and Y
    auto bp = kernel.bbox(r.parts[2].solid.brep);
    assert(isClose(bp.min.x, 4.0, 1e-6) && isClose(bp.max.x, 16.0, 1e-6) && isClose(bp.min.y, -1.0, 1e-6));
    assert(r.log[0].text == "[0, 0, 1] [0, -1, 0] [10 mm, 5 mm, 4 mm] 1 [0, 1, 0] [0 mm, 0 mm, 5 mm]", r.log[0].text);

    assert(error("immutable p = plane(vec(0, 0, 0), vec(1, 0, 0), vec(2, 0, 0));\n@part Solid s() => box(1, 1, 1).mirror(p);").code == Code.type);
    assert(error("@part Solid s() => box(1, 1, 1).rotate(10, axis: \"z\");").code == Code.type);
    assert(error("@part Solid s() => box(1, 1, 1).fillet(edges.filter(e => e.radius > 1.mm), r: 0.1);").code == Code.type);
}

unittest
{
    // planes from faces mirror and carry drawings too
    auto r = runModel(q{
        immutable body = box(20, 10, 10);
        @part Solid twin() => sphere(2).move(x: 3).mirror(body.plane(faces.right));
        @part Solid onCut() => cylinder(d: 2, h: 4).placeOn(body.plane(faces.top).offset(5.mm));
    });
    auto bt = kernel.bbox(r.parts[0].solid.brep);
    assert(isClose(bt.center.x, 17.0, 1e-6), "mirrored across x = 10");
    auto bc = kernel.bbox(r.parts[1].solid.brep);
    assert(isClose(bc.min.z, 15.0, 1e-6) && isClose(bc.max.z, 19.0, 1e-6));
}

unittest
{
    // profiles and what turns them into solids
    auto r = runModel(q{
        immutable body = box(40, 30, 10);
        immutable top = body.frame(faces.top);
        @part Solid plain() => rect(10, 20).extrude(5);
        @part Solid holed() => (rect(20, 20) - circle(d: 10)).extrude(2);
        @part Solid tapered() => rect(10, 10).extrude(10, taper: 5.deg);
        @part Solid centred() => circle(r: 2).extrude(6, symmetric: true);
        @part Solid ring() => rect(5, 10).move(x: 7.5).revolve(axis: Y);
        @part Solid upright() => rect(5, 10).move(x: 7.5, y: 5).revolve();
        @part Solid added() => body.extrude(circle(d: 6), on: top, depth: 4);
        @part Solid pocket() => body.cut(rect(5, 5), on: top.at(x: 10), depth: 2);
        @part Solid through() => body.cut(slot(20, 6), on: top, through: true);
        unittest
        {
            writeln(format("%.3f %.3f %.3f %.3f %.3f", rect(20, 10).round(3).area / 1.mm ^^ 2,
                rect(10, 10).offset(2).area / 1.mm ^^ 2, polygon(6, d: 10).area / 1.mm ^^ 2,
                slot(30, 10).area / 1.mm ^^ 2, rect(10, 10).offset(-2).area / 1.mm ^^ 2));
            writeln(text("Hi", size: 10).area > 10 * 1.mm ^^ 2, " ", (rect(4, 4) + circle(d: 2).move(x: 2)).area > 16 * 1.mm ^^ 2);
        }
    });
    import std.math : PI, sqrt;
    assert(isClose(partVolume(r, "plain"), 1000, 1e-9));
    assert(isClose(partVolume(r, "holed"), (400 - 25 * PI) * 2, 1e-9));
    assert(partVolume(r, "tapered") < 1000 && partVolume(r, "tapered") > 500);
    auto bc = kernel.bbox(r.parts[3].solid.brep);
    assert(isClose(bc.min.z, -3.0, 1e-6) && isClose(bc.max.z, 3.0, 1e-6));
    assert(isClose(partVolume(r, "ring"), PI * (100 - 25) * 10, 1e-6));
    // lofts between sections that start elsewhere or turn the other way, or
    // have different numbers of edges, do not twist
    {
        auto lr = runModel(q{
            @part Solid turned() => loft([polygon([vec(0, 0), vec(10, 0), vec(10, 10), vec(0, 10)]),
                polygon([vec(10, 0), vec(0, 0), vec(0, 10), vec(10, 10)]).move(z: 10)], ruled: true);
            @part Solid inset() => loft([rect(40, 20).round(4), rect(40, 20).offset(-3).move(z: 15)]);
        });
        assert(isClose(partVolume(lr, "turned"), 1000, 1e-6), "a loft of the same square, listed otherwise");
        foreach (p; lr.parts)
            if (p.name == "inset")
            {
                auto bi = kernel.bbox(p.solid.brep);
                assert(bi.max.x - bi.min.x < 41 && bi.max.z - bi.min.z < 15.5, "an inset loft stays within its sections");
            }
    }
    // without an axis it stands up: the profile's y is the height along Z
    foreach (p; r.parts)
        if (p.name == "upright")
        {
            auto bu = kernel.bbox(p.solid.brep);
            import std.math : abs;
            assert(abs(bu.min.z) < 1e-6 && abs(bu.max.z - 10) < 1e-6, "revolve() stands up");
            assert(abs(bu.max.x - 10) < 1e-6 && abs(bu.max.y - 10) < 1e-6);
        }
    assert(isClose(partVolume(r, "upright"), PI * (100 - 25) * 10, 1e-6));
    assert(isClose(partVolume(r, "added"), 12_000 + PI * 9 * 4, 1e-6));
    assert(isClose(partVolume(r, "pocket"), 12_000 - 50.0, 1e-6));
    assert(isClose(partVolume(r, "through"), 12_000 - (14 * 6 + PI * 9) * 10, 1e-6));
    assert(r.log[0].text == format("%.3f %.3f %.3f %.3f %.3f", 200 - (4 - PI) * 9, 196 - (4 - PI) * 4,
        3 * sqrt(3.0) / 2 * 25, 200 + PI * 25, 36.0), r.log[0].text);
    assert(r.log.length > 1 && r.log[1].text == "true true", r.log.length > 1 ? r.log[1].text : "missing line");

    assert(error("@part Solid p() => rect(10, 10);").code == Code.type);
    assert(error("@part Solid p() => box(1, 1, 1) + rect(1, 1);").code == Code.type);
    assert(error("@part Solid p() => (rect(10, 10) + rect(10, 10).rotate(x: 90)).extrude(5);").code == Code.type);
    assert(error("@part Solid p() => box(1, 1, 1).extrude(3);").code == Code.type);
    assert(error("@part Solid p() => polygon([vec(0, 0), vec(1, 0)]).extrude(1);").code == Code.type);
}

unittest
{
    // largest picks among the faces selected so far
    auto r = runModel(q{
        immutable l = box(40, 30, 5) + box(5, 30, 40).move(x: -17.5);
        unittest { writeln(l.plane(faces.normal(X).largest).origin.x); }
    });
    assert(r.log.length && r.log[0].text == "-15 mm", r.log.length ? r.log[0].text : "no output");
}

unittest
{
    // load(): STL / OBJ meshes and STEP files become solids to work on
    import hackerscad.io.stl : toStl;
    import std.file : write, mkdirRecurse, rmdirRecurse;

    auto dir = buildPath(tempDir, "hcad-load-test");
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto cube = kernel.boolean(kernel.box(20, 20, 20), kernel.translate(kernel.cylinder(4, 30), Vec3(10, 10, -5)), BoolOp.cut);
    write(buildPath(dir, "cube.stl"), toStl(kernel.tessellate(cube, 0.01, 0.1).welded));
    kernel.writeStep([cube], ["cube"], buildPath(dir, "cube.step"));
    // several parts: separate, named bodies in one file
    kernel.writeStep([cube, kernel.translate(cube, Vec3(30, 0, 0))], ["left", "right"], buildPath(dir, "two.step"));
    {
        import std.file : readText;
        auto step = readText(buildPath(dir, "two.step"));
        assert(step.canFind("PRODUCT('left'") && step.canFind("PRODUCT('right'"));
        assert(kernel.solids(kernel.readStep(buildPath(dir, "two.step"))).length == 2);
    }
    write(buildPath(dir, "tri.obj"), "v 0 0 0\nv 10 0 0\nv 0 10 0\nv 0 0 10\nf 1 3 2\nf 1 2 4\nf 1 4 3\nf 2 3 4\n");
    write(buildPath(dir, "open.obj"), "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n");
    // drawings: a 40 x 20 mm plate with a hole of 10 mm and an island in it
    write(buildPath(dir, "plate.svg"), `<svg xmlns="http://www.w3.org/2000/svg" width="40mm" height="20mm" viewBox="0 0 400 200">
        <rect width="400" height="200" rx="20"/><circle cx="100" cy="100" r="50"/><circle cx="100" cy="100" r="20"/>
        <path d="M250 50 h100 v100 h-100 z M275 75 v50 h50 v-50 z"/></svg>`);
    write(buildPath(dir, "plate.dxf"), "0\nSECTION\n2\nENTITIES\n0\nLWPOLYLINE\n90\n4\n70\n1\n"
        ~ "10\n0\n20\n0\n10\n40\n20\n0\n10\n40\n20\n20\n10\n0\n20\n20\n"
        ~ "0\nCIRCLE\n10\n10\n20\n10\n40\n5\n0\nARC\n10\n30\n20\n10\n40\n4\n50\n0\n51\n180\n"
        ~ "0\nLINE\n10\n26\n20\n10\n11\n34\n21\n10\n0\nENDSEC\n0\nEOF\n");

    auto it = make();
    it.root = dir;
    auto r = it.runSource(q{
        immutable mesh = load("cube.stl");
        @part Solid fromStl() => mesh - cylinder(d: 2, h: 50, center: true).move(x: 3, y: 3);
        @part Solid rounded() => mesh.fillet(edges.parallel(Z).filter(e => e.mid.x > 15.mm && e.mid.y > 15.mm), r: 2);
        @part Solid fromStep() => load("cube.step", scale: 2);
        @part Solid fromObj() => load("tri.obj");
        @part Solid fromSvg() => load("plate.svg").extrude(2);
        @part Solid fromDxf() => load("plate.dxf").extrude(1);
        unittest { writeln(mesh.plane(faces.top).origin.z, " ", mesh.centered.bbox.center); }
    }, buildPath(dir, "main.hcad"));
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    import std.math : PI;
    immutable cubeVol = 8000 - PI * 16 * 20;
    // the STL facets the hole wall, so the volume is close but not exact
    assert(isClose(partVolume(r, "fromStl"), cubeVol - PI * 1 * 20, 2e-3));
    assert(partVolume(r, "rounded") < partVolume(r, "fromStl") + PI * 20, "fillet on an imported part");
    assert(isClose(partVolume(r, "fromStep"), cubeVol * 8, 1e-6));
    assert(isClose(partVolume(r, "fromObj"), 1000.0 / 6, 1e-6));
    // plate with rounded corners (r 2), less the ring (r 5 - r 2) and the square frame (10² - 5²)
    immutable plate = 800 - (4 - PI) * 4 - PI * (25 - 4) - 75;
    assert(isClose(partVolume(r, "fromSvg"), plate * 2, 2e-3), format("%s", partVolume(r, "fromSvg")));
    // a plate with a round hole and a half disc cut by its diameter
    assert(isClose(partVolume(r, "fromDxf"), 800 - PI * 25 - PI * 8, 2e-3), format("%s", partVolume(r, "fromDxf")));
    assert(r.log[0].text == "20 mm [0 mm, 0 mm, 0 mm]", r.log[0].text);

    // coplanar triangles merge into real faces: the top of the cube is one face
    size_t tops;
    foreach (f; kernel.faces(r.parts[0].solid.brep))
        tops += f.normal.z > 0.999;
    assert(tops == 1);

    // errors, evaluated as a model in the same directory
    string errorAt(string src)
    {
        auto i = make();
        i.root = dir;
        try
            i.runSource(src, buildPath(dir, "main.hcad"));
        catch (HcadError e)
            return e.diag.code;
        return null;
    }

    assert(errorAt(`@part Solid p() => load("../secret.stl");`) == Code.sandbox);
    assert(errorAt(`@part Solid p() => load("open.obj");`) == Code.kernel);
    assert(errorAt(`@part Solid p() => load("missing.stl");`) == Code.import_);
    assert(errorAt(`@part Solid p() => load("cube.dxf");`) == Code.import_);
}

unittest
{
    // 2D booleans give one face per region: the extrusion is one body, and
    // fillets work on its outline (docs/BUG_PROFILI_UNITI.md)
    auto r = runModel(q{
        immutable h = 8.mm;
        Solid top(Solid s) => s.fillet(edges.filter(e => e.mid.z < 0.1.mm || e.mid.z > h - 0.1.mm), r: 1.mm);
        @part Solid joined() => top((circle(r: 20.mm) + rect(30.mm, 30.mm).move(y: 15.mm)).extrude(h));
        @part Solid u() => ((circle(r: 20.mm) + rect(40.mm, 20.mm).move(y: 10.mm))
            - (circle(r: 10.mm) + rect(20.mm, 30.mm).move(y: 15.mm))).extrude(h);
        @part Solid s() => top(slot(40.mm, 20.mm).extrude(h));
        @part Solid c() => cylinder(r: 10.mm, h: 5.mm).fillet(edges.perpendicular(Z), r: 1.mm);
        unittest {
            writeln((circle(r: 20.mm) + rect(30.mm, 30.mm).move(y: 15.mm)).extrude(h).pieces.length);
            writeln(slot(40.mm, 20.mm).extrude(h).pieces.length, " ", u.pieces.length);
            // a clockwise polygon merges with a circle too
            auto cw = polygon([vec(-8, -1), vec(8, -1), vec(12, -78), vec(-12, -78)]) + circle(d: 24).move(y: -78);
            writeln(cw.extrude(1).pieces.length, " ", cw.offset(2).offset(-2).round(1).extrude(1).pieces.length, " ",
                polygon([vec(0, 0), vec(0, 10), vec(10, 0)]).extrude(1).volume);
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(r.log[0].text == "1", r.log[0].text);
    assert(r.log[1].text == "1 1", r.log[1].text);
    assert(r.log[2].text == "1 1 50 mm^3", r.log[2].text);
    import std.math : PI;
    // slot area: rectangle + full circle, times the height (before the fillet the area is exact)
    auto slotSolid = kernel.extrude(kernel.boolean(kernel.boolean(kernel.rect(20, 20),
        kernel.translate(kernel.circle(10), Vec3(-10, 0, 0)), BoolOp.fuse), kernel.translate(kernel.circle(10), Vec3(10, 0, 0)), BoolOp.fuse), 8, 0);
    immutable area = 2 * (400 + PI * 100) + 8 * (40 + 2 * PI * 10);
    assert(isClose(kernel.area(slotSolid), area, 1e-6));
}

unittest
{
    mixin(slowTest);
    // paths, sweeps and lofts

    auto r = runModel(q{
        @part Solid pipe() => (circle(d: 8) - circle(d: 6)).sweep(path([vec(0, 0, 0), vec(0, 0, 30)]));
        @part Solid bent() => circle(d: 4).sweep(path([vec(0, 0, 0), vec(0, 0, 20), vec(20, 0, 20)]));
        @part Solid spring() => circle(d: 1).sweep(helix(r: 5, pitch: 3, height: 9), frenet: true);
        @part Solid frustum() => loft([circle(r: 10), circle(r: 5).move(z: 10)], ruled: true);
        @part Solid hollow() => loft([rect(20) - rect(10), (rect(20) - rect(10)).move(z: 10)]);
        unittest { writeln(helix(r: 5, pitch: 3, height: 9), " ", path([vec(0, 0), vec(1, 1)])); }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(isClose(partVolume(r, "pipe"), PI * (16 - 9) * 30, 1e-6));
    assert(partVolume(r, "bent") > PI * 4 * 38 && partVolume(r, "bent") < PI * 4 * 42);
    // three turns of a 1 mm wire: length ≈ 3 · √((2π·5)² + 3²)
    immutable wire = 3 * sqrt((2 * PI * 5) ^^ 2 + 9.0);
    assert(isClose(partVolume(r, "spring"), PI * 0.25 * wire, 1e-2));
    assert(isClose(partVolume(r, "frustum"), PI * 10 / 3 * (100 + 50 + 25), 1e-6));
    assert(isClose(partVolume(r, "hollow"), 300 * 10, 1e-6));
    assert(r.log[0].text == "Path Path");

    assert(error(`@part Solid p() => helix(r: 5, pitch: 1, height: 5);`).code == Code.type);
    assert(error(`@part Solid p() => box(1, 1, 1) + path([vec(0, 0), vec(1, 1)]);`).code == Code.type);
    assert(error(`@part Solid p() => circle(d: 1).sweep(box(1, 1, 1));`).code == Code.type);
}

unittest
{
    // constrained sketches
    auto r = runModel(q{
        Profile triangle(bool tall)
        {
            auto s = sketch();
            auto a = s.point(0, 0, fixed: true);
            auto b = s.point(25, 3);
            auto c = s.point(2, 35);
            auto ab = s.line(a, b), bc = s.line(b, c), ca = s.line(c, a);
            s.horizontal(ab);
            s.vertical(ca);
            s.length(ab, 30.mm);
            if (tall)
                s.length(ca, 40.mm);
            return s.profile;
        }
        @part Solid tri() => triangle(true).extrude(1);
        @part Solid loose() => triangle(false).extrude(1).move(x: 50);
        @part Solid plate()
        {
            auto s = sketch();
            auto o = s.point(0, 0, fixed: true);
            auto pts = s.polyline([vec(0, 0), vec(40, 1), vec(41, 20), vec(-1, 21)]);
            s.coincident(o, pts[0].start);
            s.horizontal(pts[0]);
            s.vertical(pts[1]);
            s.horizontal(pts[2]);
            s.vertical(pts[3]);
            s.length(pts[0], 40.mm);
            s.length(pts[1], 20.mm);
            s.fillet(pts[2].start, 5.mm);
            auto c = s.circle(s.point(20, 10), d: 6.mm);
            s.midpoint(c.center, s.line(pts[0].start, pts[1].end, construction: true));
            writeln(s.dof, " ", pts[1].end.pos, " ", c.radius);
            return s.profile.extrude(2);
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    import std.math : PI;
    assert(isClose(partVolume(r, "tri"), 600, 1e-6));
    assert(isClose(partVolume(r, "plate"), (800 - (25 - PI * 25 / 4) - PI * 9) * 2, 1e-6));
    assert(r.log[0].text == "0 [40 mm, 20 mm] 3 mm", r.log[0].text);
    // the loose triangle solves but warns, naming the line of the free point
    auto w = r.diagnostics.map!(d => d.message).join("\n");
    assert(w.canFind("1 degree of freedom left (free points at line 7)"), w);

    // conflicting constraints and open outlines are errors pointing at the source
    auto e = error(q{
        @part Solid p()
        {
            auto s = sketch();
            auto a = s.point(0, 0, fixed: true), b = s.point(10, 0);
            auto l = s.line(a, b);
            s.length(l, 10.mm);
            s.length(l, 20.mm);
            return s.profile.extrude(1);
        }
    });
    assert(e.code == Code.sketch && e.message.canFind("conflict"), e.message);
    assert(e.message.canFind("at line"), e.message);

    // two arcs whose pinned ends are not the same distance from their pinned
    // centres: no single constraint to blame, and no empty "at line"
    e = error(q{
        @part Solid p()
        {
            auto s = sketch();
            foreach (x; [0, 20])
            {
                auto c = s.point(x, 0, fixed: true);
                auto a = s.point(x + 5, 0, fixed: true), b = s.point(x, 5.02, fixed: true);
                s.arc(c, a, b);
                s.line(b, c);
                s.line(c, a);
            }
            return s.profile.extrude(1);
        }
    });
    assert(e.code == Code.sketch && e.message.canFind("no single one is to blame"), e.message);
    assert(!e.message.canFind("at line"), e.message);
    e = error(q{
        @part Solid p()
        {
            auto s = sketch();
            s.line(s.point(0, 0), s.point(10, 0));
            s.line(s.point(10, 0), s.point(10, 10));
            return s.profile.extrude(1);
        }
    });
    assert(e.code == Code.sketch && e.message.canFind("open"), e.message);
}

unittest
{
    // what the GUI shows of a sketch: each segment knows its entity and the
    // call that made it, each constraint call (valueless ones too) the
    // entities it involves, so Inspect on a line can highlight them
    import hackerscad.lang.sketchval : SketchVal, SketchView;
    import std.string : splitLines, indexOf;

    immutable src = `@part Solid p()
{
    auto s = sketch();
    auto a = s.point(0, 0, fixed: true);
    auto b = s.point(30, 1);
    auto c = s.point(31, 20);
    auto d = s.point(1, 21);
    auto ab = s.line(a, b);
    auto bc = s.line(b, c);
    auto cd = s.line(c, d);
    auto da = s.line(d, a);
    s.horizontal(ab);
    s.parallel(cd, ab);
    s.perpendicular(da, ab);
    s.vertical(bc);
    s.length(ab, 30.mm);
    s.distance(a, d, 20.mm);
    s.fillet(c, 3.mm);
    auto hole = s.circle(s.point(10, 10), d: 4.mm);
    s.on(hole.center, s.line(a, c, construction: true));
    foreach (i; 0 .. 2)
        s.horizontal(s.line(s.point(5 + 10 * i, 15, fixed: true), s.point(8 + 10 * i, 16), construction: true));
    return s.profile.extrude(1);
}
`;
    uint lineOf(string needle)
    {
        foreach (i, l; src.splitLines)
            if (l.indexOf(needle) >= 0)
                return cast(uint)(i + 1);
        assert(0, needle);
    }

    auto it = make();
    auto r = runModel(src, it);
    foreach (dg; r.diagnostics)
        assert(dg.severity != Severity.error, dg.message);
    assert(it.sketches.length == 1);
    auto v = (cast(SketchVal) it.sketches[0]).view();
    immutable file = v.span.file;
    // free: the hole along its line, the end of each line of the loop
    assert(v.solved && v.dof == 3, format("%s %s", v.solved, v.dof));
    assert(v.profiles.length == 1 && v.profiles[0].line == lineOf("s.profile"));

    // entities in the order they were made, with their calls
    assert(v.entities[0].kind == "point" && v.entities[0].span.line == lineOf("auto a ="));
    immutable ab = 4, bc = 5, cd = 6;
    assert(v.entities[ab].kind == "line" && v.entities[ab].span.line == lineOf("auto ab ="));
    assert(v.points.length == 9 && v.points[1].entity == 1);

    // the outline draws each line once (cd and bc trimmed by the fillet at c), and the fillet's arc
    size_t[ptrdiff_t] drawn;
    foreach (g; v.segments)
        drawn[g.entity]++;
    foreach (e; [ab, bc, cd])
        assert(drawn.get(e, 0) == 1, format("%s", drawn));
    auto arc = v.segments.map!(g => g.corner).array.canFind(2);
    assert(arc, "the fillet's arc names its corner point");
    foreach (g; v.segments)
        if (g.corner == 2)
            assert(g.entity == -1 && g.span.line == lineOf("s.fillet"));
        else
            assert(g.entity >= 0 && g.span == v.entities[g.entity].span);

    // constraint records: valueless ones too, with the entities they involve
    SketchView.Constraint byLine(string needle)
    {
        foreach (c; v.constraints)
            if (c.span.line == lineOf(needle))
                return c;
        assert(0, needle);
    }
    auto par = byLine("s.parallel");
    assert(par.kind == "parallel" && par.entities == [cd, ab] && par.dimension < 0);
    auto len = byLine("s.length");
    assert(len.kind == "length" && len.entities == [ab] && len.dimension >= 0);
    assert(v.dimensions[len.dimension].label == "30" && v.dimensions[len.dimension].constraint < v.constraints.length);
    assert(v.constraints[v.dimensions[len.dimension].constraint].span == len.span);
    auto fil = byLine("s.fillet");
    assert(fil.kind == "fillet" && fil.entities[0] == 2 && fil.entities.canFind(bc) && fil.entities.canFind(cd), format("%s", fil));
    assert(byLine("auto a =").kind == "fix");
    assert(byLine("auto hole").kind == "diameter");

    // Inspect on a line: an entity line highlights it; a constraint line, what it involves
    auto f = v.on(file, lineOf("auto bc ="), lineOf("auto bc ="));
    assert(f.entities == [bc] && f.highlight == [bc] && f.constraints.length == 0 && !f.sketch);
    f = v.on(file, lineOf("s.parallel"), lineOf("s.parallel"));
    assert(f.entities.length == 0 && f.constraints.length == 1 && f.highlight == [cd, ab]);
    // a loop: several entities and constraints from one line, all of them
    f = v.on(file, lineOf("s.horizontal(s.line"), lineOf("s.horizontal(s.line"));
    assert(f.entities.length == 6 && f.constraints.length == 4, format("%s", f));   // 2 × (2 points, a line; fix, horizontal)
    // the sketch() line and the .profile line belong to the sketch, other lines not
    assert(v.on(file, lineOf("sketch()"), lineOf("sketch()")).sketch);
    assert(v.covers(file, lineOf("s.profile"), lineOf("s.profile")));
    assert(!v.covers(file, 1, 1) && !v.covers("other.hcad", lineOf("s.parallel"), lineOf("s.parallel")));
}

unittest
{
    // the stretch of code a sketch owns (the GUI shows it while the cursor is
    // there): from its first call to its last in its function, every line in
    // between; the body of a helper that drew on it; a sketch nested in
    // another's stretch wins its own lines; a helper two sketches share goes
    // to the last made, and says it is shared
    import hackerscad.lang.sketchval : SketchVal, SketchView, Stretch, stretchesOf, sketchAt, sketchViews;
    import std.string : splitLines, indexOf;

    immutable src = `void rim(Sketch s, double r)
{
    // the rim
    auto c = s.point(0, 0, fixed: true);
    s.circle(c, r: r);
}

@part Solid clip()
{
    immutable teeth = 3;
    auto s = sketch();
    auto a = s.point(0, 0, fixed: true);
    // a comment
    foreach (i; 0 .. teeth)
    {
        immutable x = 10.0 * i;
        s.point(x, 5, fixed: true);
    }
    if (teeth > 5)
        s.point(1, 1, fixed: true);
    else
    {
        s.point(2, 2, fixed: true);
    }
    rim(s, 30);
    auto t = sketch();
    t.point(3, 3, fixed: true);
    s.point(4, 4, fixed: true);
    writeln("done");
    return box(1, 1, 1);
}

@part Solid other()
{
    auto u = sketch();
    rim(u, 10);
    return box(2, 2, 2);
}
`;
    uint lineOf(string needle)
    {
        foreach (i, l; src.splitLines)
            if (l.indexOf(needle) >= 0)
                return cast(uint)(i + 1);
        assert(0, needle);
    }

    auto it = make();
    auto r = runModel(src, it);
    foreach (dg; r.diagnostics)
        assert(dg.severity != Severity.error, dg.message);
    immutable file = buildPath(tempDir, "hcad-test.hcad");
    auto views = sketchViews(it, file, false);
    assert(views.length == 3 && !views[0].partial);
    auto fns = it.functionsOf(file);
    auto rimFn = fns[0];
    assert(rimFn.name == "rim" && rimFn.first == 1 && rimFn.end == lineOf("    s.circle(c, r: r);") + 1, format("%s", rimFn));
    Stretch[][] stretches;
    foreach (ref v; views)
        stretches ~= stretchesOf(v, file, fns);
    // s: from sketch() to its last point, and the helper's body
    assert(stretches[0] == [Stretch(1, lineOf("    s.circle(c, r: r);") + 1, true),
        Stretch(lineOf("auto s = sketch()"), lineOf("s.point(4, 4"), false)], format("%s", stretches[0]));
    // t: its two lines
    assert(stretches[1] == [Stretch(lineOf("auto t = sketch()"), lineOf("t.point(3, 3"), false)]);
    ptrdiff_t at(uint line, ptrdiff_t prefer = -1) => sketchAt(views, stretches, file, line, prefer).index;
    // lines in between belong to s: a comment, a foreach header and its braces, a value computed on the way,
    // the branch not taken, the call of the helper
    foreach (needle; ["auto s = sketch()", "// a comment", "foreach (i;", "immutable x =", "s.point(1, 1",
        "    else", "rim(s, 30)", "s.point(4, 4"])
        assert(at(lineOf(needle)) == 0, needle);
    assert(at(lineOf("foreach (i;") + 1) == 0);   // its brace
    // outside: before the first call, after the last, another function
    foreach (needle; ["immutable teeth", "writeln(\"done\")", "@part Solid clip()", "return box(1, 1, 1)", "return box(2"])
        assert(at(lineOf(needle)) < 0, needle);
    // nested: t's lines are t's, though inside s's stretch
    assert(at(lineOf("auto t = sketch()")) == 1 && at(lineOf("t.point(3, 3")) == 1);
    // the helper, drawn on by s and u: the last made, or the one shown; shared with one other
    auto h = sketchAt(views, stretches, file, lineOf("// the rim"));
    assert(h.index == 2 && h.sharing == 1, format("%s", h));
    assert(at(lineOf("// the rim"), 0) == 0);
    assert(at(lineOf("auto u = sketch()")) == 2);
    assert(sketchAt(views, stretches, file, lineOf("auto t = sketch()")).sharing == 0);
}

unittest
{
    // a run an error stops keeps the sketches made before it, marked partial
    // (the GUI shows them instead of an empty view)
    import hackerscad.lang.sketchval : sketchViews;
    auto it = make();
    bool failed;
    try
        runModel(`@part Solid p()
{
    auto s = sketch();
    auto c = s.circle(s.point(0, 0, fixed: true), r: 5.mm);
    auto body = s.profile.extrude(2);
    return body + missing;
}
`, it);
    catch (HcadError e)
        failed = e.diag.span.line == 6;
    assert(failed);
    auto views = sketchViews(it, buildPath(tempDir, "hcad-test.hcad"), true);
    assert(views.length == 1 && views[0].partial && views[0].solved && views[0].dof == 0 && views[0].segments.length == 1);
    assert(views[0].profiles.length == 1 && views[0].profiles[0].line == 5);
}

unittest
{
    // sketch shapes: ellipses, rectangles, regular polygons, slots, concentric
    import std.algorithm : filter, sort;
    auto r = runModel(q{
        @part Solid oval()
        {
            auto s = sketch();
            auto e = s.ellipse(s.point(0, 0, fixed: true), rx: 20.mm, ry: 10.mm);
            s.horizontal(e);
            writeln("oval ", s.dof);
            return s.profile.extrude(1);
        }
        @part Solid through()
        {
            // the radii from two points it passes through
            auto s = sketch();
            auto e = s.ellipse(vec(0, 0));
            s.fix(e.center);
            s.horizontal(e);
            s.on(s.point(30, 0, fixed: true), e);
            s.on(s.point(18, 12, fixed: true), e);
            writeln("through ", s.dof, " ", e.rx, " ", e.ry);
            return s.profile.extrude(1);
        }
        @part Solid touching()
        {
            // a horizontal line tangent to a tilted ellipse: its height is the ellipse's reach
            auto s = sketch();
            auto e = s.ellipse(s.point(0, 0, fixed: true), rx: 20.mm, ry: 10.mm, angle: 30.deg);
            auto l = s.line(s.point(-30, 16), s.point(30, 17), construction: true);
            s.horizontal(l);
            s.tangent(l, e);
            writeln("touching ", abs(l.start.y - sqrt(175.0).mm) < 0.000001.mm);
            return s.profile.extrude(1);
        }
        @part Solid round()
        {
            // drawn squashed, made round
            auto s = sketch();
            auto e = s.ellipse(s.point(0, 0, fixed: true));
            s.equal(e);
            s.radius(e, rx: 15.mm);
            writeln("round ", s.dof, " ", e.ry);
            return s.profile.extrude(1);
        }
        @part Solid plate()
        {
            // a rounded rectangle round a fixed centre, an elliptic hole in its middle
            auto s = sketch();
            auto c = s.point(0, 0, fixed: true);
            auto sides = s.rect(center: c, w: 60.mm, h: 40.mm, corner: 5.mm);
            auto hole = s.ellipse(vec(3, 2), rx: 10.mm, ry: 5.mm);
            s.concentric(hole, c);
            s.vertical(hole);
            writeln("plate ", s.dof, " ", sides.length, " ", sides[1].length);
            return s.profile.extrude(1);
        }
        @part Solid corners()
        {
            auto s = sketch();
            s.rect(vec(0, 0), vec(30, 20));
            writeln("corners ", s.dof);
            auto t = sketch();
            t.rect(t.point(0, 0, fixed: true), t.point(30, 20, fixed: true));
            writeln("corners ", t.dof);
            return t.profile.extrude(1);
        }
        @part Solid hexagon()
        {
            auto s = sketch();
            auto sides = s.polygon(s.point(0, 0, fixed: true), 6, r: 10.mm);
            writeln("hexagon ", s.dof);
            s.horizontal(sides[0]);
            writeln("hexagon ", s.dof, " ", abs(sides[0].length - 10.mm) < 0.000001.mm);
            return s.profile.extrude(1);
        }
        @part Solid triangle()
        {
            auto s = sketch();
            auto sides = s.polygon(s.point(0, 0, fixed: true), 3, d: 20.mm, angle: 90.deg);
            writeln("triangle ", s.dof, " ", abs(sides[0].start.y - 10.mm) < 0.000001.mm);
            return s.profile.extrude(1);
        }
        @part Solid slotted()
        {
            auto s = sketch();
            auto parts = s.slot(s.point(0, 0, fixed: true), s.point(30, 0, fixed: true), w: 10.mm);
            writeln("slot ", s.dof, " ", parts[1].radius);
            return s.profile.extrude(1);
        }
        @part Solid rings()
        {
            // an elliptic ring: a circle hole concentric with the ellipse
            auto s = sketch();
            auto e = s.ellipse(s.point(0, 0, fixed: true), rx: 20.mm, ry: 12.mm, angle: 0.deg);
            auto c = s.circle(s.point(2, 1), d: 8.mm);
            s.concentric(e, c);
            writeln("rings ", s.dof);
            return s.profile.extrude(1);
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    auto log = r.log.map!(l => l.text).array;
    assert(log == ["oval 0", "through 0 30 mm 15 mm", "touching true", "round 0 15 mm", "plate 0 4 40 mm", "corners 4",
        "corners 0", "hexagon 1", "hexagon 0 true", "triangle 0 true", "slot 0 5 mm", "rings 0"], format("%s", log));
    void near(string part, double want)
    {
        immutable got = partVolume(r, part);
        // the kernel integrates ellipses numerically: close, not exact
        assert(isClose(got, want, 1e-4), format("%s: %.9g, not %.9g", part, got, want));
    }
    near("oval", PI * 200);
    near("through", PI * 450);
    near("round", PI * 225);
    near("plate", 2400 - (100 - 25 * PI) - PI * 50);
    near("corners", 600);
    near("hexagon", 1.5 * sqrt(3.0) * 100);
    near("triangle", 0.75 * sqrt(3.0) * 100);
    near("slotted", 300 + PI * 25);
    near("rings", PI * 240 - PI * 16);

    // what the GUI gets: the ellipse as a curve, its radii and the rect's sizes as dimensions
    import hackerscad.lang.sketchval : SketchVal;
    auto it = make();
    runModel(q{
        @part Solid p()
        {
            auto s = sketch();
            auto c = s.point(0, 0, fixed: true);
            s.rect(center: c, w: 60.mm, h: 40.mm, corner: 4.mm);
            auto e = s.ellipse(c, rx: 10.mm, ry: 5.mm, angle: 30.deg);
            return s.profile.extrude(1);
        }
    }, it);
    auto v = (cast(SketchVal) it.sketches[0]).view();
    assert(v.solved && v.dof == 0);
    assert(v.entities.map!(e => e.kind).canFind("ellipse"));
    auto oval = v.segments.filter!(g => g.kind == 3).array;
    assert(oval.length == 1 && isClose(oval[0].r, 10) && isClose(oval[0].r2, 5) && isClose(oval[0].angle, PI / 6));
    assert(v.entities[oval[0].entity].kind == "ellipse");
    auto labels = v.dimensions.map!(d => d.label).array.sort.array;
    // the four corners share one dimension, on the arc of the upper right one
    assert(labels == ["30°", "40", "60", "R4", "Rx10", "Ry5"], format("%s", labels));
    auto corner = v.dimensions.filter!(d => d.label == "R4").front;
    assert(corner.at.x > 28 && corner.at.y > 18 && v.constraints[corner.constraint].kind == "fillet", format("%s", corner));
    auto kinds = v.constraints.map!(c => c.kind).array;
    assert(kinds.canFind("midpoint") && kinds.count("horizontal") == 2 && kinds.count("radius") == 2, format("%s", kinds));

    // a round ellipse with a turn of its own is not over-constrained; ellipses need rx: and ry: for a radius
    r = runModel(q{
        @part Solid p()
        {
            auto s = sketch();
            auto e = s.ellipse(s.point(0, 0, fixed: true), rx: 8.mm, angle: 10.deg);
            s.equal(e);
            writeln(s.dof, " ", s.solved);
            return s.profile.extrude(1);
        }
    });
    assert(r.log[0].text == "0 true", r.log[0].text);
    auto e = error(q{
        @part Solid p()
        {
            auto s = sketch();
            auto e = s.ellipse(vec(0, 0));
            s.radius(e, 5.mm);
            return s.profile.extrude(1);
        }
    });
    assert(e.code == Code.type && e.message.canFind("two radii"), e.message);
}

unittest
{
    // a sketch's spline: closed, a loop of its own; open, its ends join lines; drawn as the profile has it,
    // smooth (a fillet along it and round the corner where it meets a line takes what it should, no more)
    import hackerscad.lang.sketchval : SketchVal;
    import std.algorithm : filter;
    auto it = make();
    auto r = runModel(q{
        Profile pebble()
        {
            auto s = sketch();
            s.spline([vec(0, 0), vec(30, -5), vec(45, 15), vec(20, 30), vec(-5, 18)], closed: true);
            return s.profile;
        }
        Profile wave()
        {
            auto s = sketch();
            auto a = s.point(0, 0, fixed: true), b = s.point(60, 0, fixed: true);
            auto c = s.point(60, 20, fixed: true), m = s.point(30, 30, fixed: true), d = s.point(0, 20, fixed: true);
            s.line(a, b);
            s.line(b, c);
            auto w = s.spline([c, m, d]);
            s.line(d, a);
            writeln(w.points.length, " ", w.closed, " ", w.start.x, " ", w.end.x, " ", w.length > 60.mm);
            return s.profile;
        }
        @part Solid flat() => pebble().extrude(5.mm);
        @part Solid round() => pebble().extrude(5.mm).fillet(edges.of(faces.top), r: 1.mm);
        @part Solid block() => wave().extrude(8.mm);
        @part Solid soft() => wave().extrude(8.mm).fillet(edges.of(faces.top), r: 1.mm);
    }, it);
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(r.log[0].text == "3 false 60 mm 0 mm true", r.log[0].text);
    double vol(string name) => kernel.volume(r.parts.filter!(p => p.name == name).front.solid.brep);
    foreach (p; r.parts)
        assert(kernel.isValid(p.solid.brep), p.name);
    // a fillet of r 1 takes (1 - π/4) mm² along each mm of edge: about 30 mm³ round the pebble, 35 round the wave
    immutable pebbleCut = vol("flat") - vol("round"), waveCut = vol("block") - vol("soft");
    assert(pebbleCut > 20 && pebbleCut < 40, format("%s", pebbleCut));
    assert(waveCut > 25 && waveCut < 45, format("%s", waveCut));
    // the view draws the spline as the profile has it: one segment of kind 4, through its points
    // (each call of wave() makes its sketch again: the last one)
    auto v = (cast(SketchVal) it.sketches[$ - 1]).view();
    auto curve = v.segments.filter!(g => g.kind == 4).array;
    assert(curve.length == 1 && v.entities[curve[0].entity].kind == "spline", format("%s", v.segments.map!(g => g.kind)));
    assert((curve[0].poles[0] - Vec3(60, 20, 0)).length < 1e-9 || (curve[0].poles[0] - Vec3(0, 20, 0)).length < 1e-9);
    assert(curve[0].poles.length == 7);

    // too few points, two in a row on each other
    foreach (bad; ["s.spline([vec(0, 0), vec(10, 0), vec(5, 8)], closed: true); s.spline([vec(0, 0), vec(1, 1)], closed: true);",
            "auto p = s.point(0, 0); s.spline([p, p, vec(10, 0)]);"])
    {
        auto e = error("@part Solid p() { auto s = sketch(); " ~ bad ~ " return s.profile.extrude(1); }");
        assert(e.message.canFind("spline"), e.message);
    }
}

unittest
{
    mixin(slowTest);
    // built-in libraries
    auto r = runModel(q{
        import hardware;
        import std.threads : threadedRod;
        import gears;
        import hinges : hinge;
        import snaps : snapHook;
        import enclosures : enclosure, roundedBox;

        @part Solid rod() => threadedRod(6.mm, 1.mm, 8.mm);
        @part Solid leftRod() => threadedRod(6.mm, 1.mm, 8.mm, left: true);
        @part Solid gear() => spurGear(1.mm, 24, 5.mm);
        @part Solid fixed() => hinge(length: 30.mm).fixed;
        @part Solid moving() => hinge(length: 30.mm).moving;
        @part Solid hook() => snapHook();
        @part Solid base() => enclosure(vec(30.mm, 20.mm, 15.mm)).base;
        @part Solid plate() => roundedBox(20.mm, 20.mm, 2.mm) - hole(M3, 2.mm, "countersink").move(z: 2.mm);
        unittest
        {
            writeln(centerDistance(1.mm, 24, 12), " ", M3.pitch, " ", abs(gear.bbox.size.x - 26.mm) < 0.1.mm);
            assert(distance(fixed, moving) > 0.1.mm, "the hinge leaves must not touch");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    import std.math : PI;
    // the thread lies between the minor and the major cylinder
    immutable minor = 6 - 2 * 0.5413;
    assert(partVolume(r, "rod") > PI * (minor / 2) ^^ 2 * 8 && partVolume(r, "rod") < PI * 9 * 8);
    // left-handed: the mirror image, as large
    assert(isClose(partVolume(r, "leftRod"), partVolume(r, "rod"), 1e-9));
    assert(r.log[0].text == "18 mm 0.5 mm true", r.log[0].text);
    foreach (p; r.parts)
        assert(kernel.isValid(p.solid.brep) && kernel.solids(p.solid.brep).length == 1, p.name);
}

unittest
{
    mixin(slowTest);
    // an M8 × 25 thread: OpenCascade's mesher covered more than its flanks
    // (triangles folded over each other, 5% more area than the rod), which
    // hc_tessellate works around by dividing those faces for the mesh
    auto r = runModel(q{
        import std.threads : threadedRod;
        @part Solid rod() => threadedRod(8.mm, 1.25.mm, 25.mm);
    });
    auto brep = r.parts[0].solid.brep;
    // as the 3D view and the exports mesh it
    foreach (angular; [0.2, 0.25])
    {
        auto m = kernel.tessellate(brep, 0.02, angular).welded;
        assert(m.isClosed);
        immutable area = meshArea(m);
        assert(abs(area - kernel.area(brep)) < 0.01 * kernel.area(brep),
            format("the mesh covers %.1f mm², the rod %.1f mm²", area, kernel.area(brep)));
    }
}

unittest
{
    // rotate(around:) turns about a point: a part spun in place stays there
    auto r = runModel(q{
        @part Solid spun() => box(10.mm, 4.mm, 2.mm).move(x: 20.mm).rotate(z: 90, around: vec(20.mm, 0.mm, 0.mm));
        @part Solid swung() => box(10.mm, 4.mm, 2.mm).move(x: 20.mm).rotate(90.deg, axis: Z, around: vec(20.mm, 0.mm, 0.mm));
        @part Solid orbited() => box(10.mm, 4.mm, 2.mm).move(x: 20.mm).rotate(z: 90);
    });
    foreach (p; r.parts)
    {
        auto b = kernel.bbox(p.solid.brep);
        immutable c = (b.min + b.max) * 0.5;
        if (p.name == "orbited")
            assert(abs(c.x) < 1e-6 && abs(c.y - 20) < 1e-6, p.name);
        else
            assert(abs(c.x - 20) < 1e-6 && abs(c.y) < 1e-6 && abs(b.size.x - 4) < 1e-6, p.name);
    }
}

/// The area of a mesh's triangles.
double meshArea(M)(M m)
{
    double area = 0;
    foreach (t; 0 .. m.tris.length / 3)
    {
        Vec3 v(size_t k) => Vec3(m.verts[m.tris[t * 3 + k] * 3], m.verts[m.tris[t * 3 + k] * 3 + 1],
            m.verts[m.tris[t * 3 + k] * 3 + 2]);
        area += (v(1) - v(0)).cross(v(2) - v(0)).length / 2;
    }
    return area;
}

/// For the known bugs below: fails when a bug of a library, which hackerscad
/// works around, no longer shows (a new version fixed it). Then try removing
/// the WORKAROUND it names, and its check here.
void stillBroken(bool broken, string bug)
{
    assert(broken, "fixed upstream? " ~ bug ~ " no longer shows: try removing its WORKAROUND, and this check");
}

// Whether a model fails: with an error, thrown or reported.
bool fails(string src)
{
    import std.algorithm : any;
    try
        return runModel(src).diagnostics.any!(d => d.severity == Severity.error);
    catch (HcadError)
        return true;
}

unittest
{
    // gid's bugs cannot be tried here (one corrupts the heap): the
    // WORKAROUNDs for them (GLArea.getError in gui/viewport.d, the library
    // pairs in tools/win-forwarders.sh and packaging/macos/package.sh) are
    // tied to the version they were seen in
    import std.file : thisExePath, readText;
    import djson : parseJSONComplete;
    import std.path : dirName;
    auto root = dirName(dirName(dirName(thisExePath)));
    immutable v = parseJSONComplete(readText(buildPath(root, "dub.selections.json")))["versions"]["gid"].get!string;
    assert(v == "0.9.13", "gid is now " ~ v ~ ": check whether GLArea.getError still frees the error it does not own, "
        ~ "and whether symbols are still looked up in the first library of a pair only; drop the WORKAROUNDs it "
        ~ "fixed, then put the new version here");
}

unittest
{
    // the basics: powers, logarithms, the hypotenuse, sign, lerp, e; an ellipse and a torus, exact
    auto r = runModel(q{
        import std.math;
        @part Solid ring() => torus(20.mm, 4.mm);
        @part Solid oval() => ellipse(15.mm, 8.mm).extrude(5.mm);
        @part Solid tall() => ellipse(6.mm, 12.mm).extrude(1.mm);
        unittest
        {
            writeln(pow(2, 10), " ", pow(3.mm, 2), " ", log(8, 2), " ", log10(1000), " ", log2(32), " ", log(E));
            writeln(hypot(3.mm, 4.mm), " ", sign(-2.mm), " ", lerp(10.mm, 20.mm, 0.25), " ", lerp(vec(0, 0, 0), vec(10, 20, 0), 0.5));
        }
    });
    assert(r.log[0].text == "1024 9 mm^2 3 3 5 1", r.log[0].text);
    assert(r.log[1].text == "5 mm -1 12.5 mm [5, 10, 0]", r.log[1].text);
    assert(isClose(partVolume(r, "ring"), 2 * PI * PI * 20 * 16, 1e-6));
    assert(isClose(partVolume(r, "oval"), PI * 15 * 8 * 5, 1e-4));
    auto tall = kernel.bbox(r.parts[2].solid.brep);
    assert(isClose(tall.size.x, 12, 1e-6) && isClose(tall.size.y, 24, 1e-6));
    assert(error("import std.math;\n@part Solid p() => box(1, 1, 1);\nunittest { writeln(pow(3.mm, 1.5)); }").code == Code.units);
    assert(error("@part Solid p() => torus(5.mm, 6.mm);").code == Code.type);
}

unittest
{
    mixin(slowTest);
    // scale with a factor each: an ellipsoid from a sphere, a squashed box, an oval profile
    auto r = runModel(q{
        @part Solid egg() => sphere(10.mm).scale(x: 2, y: 1.5);
        @part Solid low() => box(10.mm, 10.mm, 10.mm).scale(z: 0.5);
        @part Solid oval() => circle(10.mm).scale(y: 0.4).extrude(3.mm);
    });
    assert(isClose(partVolume(r, "egg"), 4.0 / 3 * PI * 20 * 15 * 10, 1e-4));
    assert(isClose(partVolume(r, "low"), 500, 1e-6));
    assert(isClose(partVolume(r, "oval"), PI * 10 * 4 * 3, 2e-3));
    auto egg = kernel.bbox(r.parts[0].solid.brep);
    assert(isClose(egg.size.x, 40, 1e-4) && isClose(egg.size.y, 30, 1e-4) && isClose(egg.size.z, 20, 1e-4));
    assert(error("@part Solid p() => box(1, 1, 1).scale(2, x: 3);").code == Code.type);
    assert(error("@part Solid p() => box(1, 1, 1).scale(y: 0);").code == Code.type);
    // around: the point that stays where it is
    auto q = runModel(q{
        @part Solid up() => box(10.mm, 10.mm, 10.mm).move(z: 5.mm).scale(2, around: vec(0.mm, 0.mm, 5.mm));
        @part Solid tall() => box(10.mm, 10.mm, 10.mm).move(z: 5.mm).scale(z: 3, around: vec(0.mm, 0.mm, 5.mm));
    });
    auto up = kernel.bbox(q.parts[0].solid.brep), tall = kernel.bbox(q.parts[1].solid.brep);
    assert(isClose(up.min.z, 5, 1e-6) && isClose(up.max.z, 25, 1e-6) && isClose(up.max.x, 10, 1e-6), "scale around");
    assert(isClose(tall.min.z, 5, 1e-6) && isClose(tall.max.z, 35, 1e-6) && isClose(tall.max.x, 5, 1e-6), "scale around");
}

// The known bugs of OpenCascade, each tried with its workaround turned off.

unittest
{
    // the volume of a smooth outline extruded: a C, then the area times the height
    import hackerscad.kernel.occt.c;
    auto src = q{
        import std.math;
        Vec2[] c()
        {
            Vec2[] o, i;
            foreach (k; 0 .. 25)
            {
                immutable t = 30.deg + k * 300.deg / 24;
                o ~= vec(20.mm * cos(t), 20.mm * sin(t));
                i ~= vec(14.mm * cos(t), 14.mm * sin(t));
            }
            Vec2[] p = o;
            foreach_reverse (q; i)
                p ~= q;
            return p;
        }
        @part Solid a() => polygon(c(), smooth: true).extrude(10.mm);
        unittest { writeln(polygon(c(), smooth: true).area * 10.mm); }
    };
    auto r = runModel(src);
    import std.array : split;
    import std.conv : to;
    immutable want = r.log[0].text.split(" ")[0].to!double;
    assert(abs(partVolume(r, "a") - want) < 0.005 * want, format("%s for %s", partVolume(r, "a"), want));
    hc_workaround(HC_WORKAROUND_MESH_VOLUME, 0);
    scope (exit)
        hc_workaround(HC_WORKAROUND_MESH_VOLUME, 1);
    // another height: the volumes are cached by shape
    import std.array : replace;
    immutable raw = kernel.volume(runModel(src.replace("10.mm", "11.mm")).parts[0].solid.brep);
    stillBroken(abs(raw - want * 1.1) > 0.02 * want * 1.1,
        "BRepGProp's volume of a smooth outline extruded, 6% off (shim.cpp, hc_volume, mesh_volume)");
}

unittest
{
    mixin(slowTest);
    import hackerscad.kernel.occt.c;
    hc_workaround(HC_WORKAROUND_MESH_DIVIDE, 0);
    scope (exit)
        hc_workaround(HC_WORKAROUND_MESH_DIVIDE, 1);
    auto rod = runModel(q{
        import std.threads : threadedRod;
        @part Solid rod() => threadedRod(8.mm, 1.25.mm, 25.mm);
    }).parts[0].solid.brep;
    immutable area = meshArea(kernel.tessellate(rod, 0.02, 0.25).welded);
    stillBroken(abs(area - kernel.area(rod)) > 0.02 * kernel.area(rod),
        "BRepMesh covering more than the flanks of an M8 × 25 thread (shim.cpp, meshed_badly)");
}

unittest
{
    import hackerscad.kernel.occt.c;
    hc_workaround(HC_WORKAROUND_SHELL_STRATEGIES, 0);
    scope (exit)
        hc_workaround(HC_WORKAROUND_SHELL_STRATEGIES, 1);
    stillBroken(fails(import("01_cup.hcad")),
        "MakeThickSolid failing to hollow the espresso cup with its first strategy (shim.cpp, hc_shell)");
}

unittest
{
    import hackerscad.kernel.occt.c;
    hc_workaround(HC_WORKAROUND_HELIX_PIECES, 0);
    scope (exit)
        hc_workaround(HC_WORKAROUND_HELIX_PIECES, 1);
    // 40 turns on a cylinder 6.64 mm across: a curve that strays from the
    // helix makes its box wider (with the workaround it is 6.64 exactly)
    auto box = kernel.bbox(kernel.helix(3.32, 1.25, 40 * 1.25, false)).size;
    stillBroken(box.x > 6.6401 || box.y > 6.6401,
        "BuildCurves3d building a wrong 3D curve for a 40-turn helix (shim.cpp, hc_helix_tapered)");
}

unittest
{
    // cut/extrude on a face of the same solid, at a point
    auto r = runModel(q{
        @part Solid a() => box(20, 20, 10).cut(circle(d: 4), on: faces.top, at: vec(5, 5, 0), depth: 3.mm);
        @part Solid b() => box(20, 20, 10).extrude(rect(4), on: faces.right, depth: 2.mm);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    import std.math : PI;
    assert(isClose(partVolume(r, "a"), 4000 - PI * 4 * 3, 1e-6));
    assert(isClose(partVolume(r, "b"), 4000 + 32, 1e-6));
    auto bb = kernel.bbox(r.parts[0].solid.brep);
    assert(isClose(bb.max.z, 10));
}

unittest
{
    // shell where the kernel's own offset fails (an open face next to fillets, a hole):
    // the result must be a valid, smaller solid, never a broken one shown as if nothing happened
    auto r = runModel(q{
        immutable size = 30.mm;
        @part Solid a() => box(size, size, size / 2).fillet(edges.parallel(Z), r: size / 6)
            .shell(open: faces.front, thickness: 2.mm);
        @part Solid b() => (box(size, size, size / 2).fillet(edges.parallel(Z), r: size / 6)
            - cylinder(d: size / 2, h: size)).shell(open: faces.front, thickness: 2.mm);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    foreach (p; r.parts)
    {
        assert(kernel.isValid(p.solid.brep), p.name);
        assert(partVolume(r, p.name) < 30.0 * 30 * 15 * 0.7, p.name);
    }
}

unittest
{
    // a drafted pot with a corner cut off: the kernel's first offset returns a
    // sound solid that is hardly hollowed, which must not pass for the shell
    auto r = runModel(q{
        @part Solid pot() => (box(60.mm, 60.mm, 48.mm)
            .fillet(edges.parallel(Z), r: 9.mm)
            .draft(faces.left + faces.front + faces.back + faces.right, angle: -4.deg)
            .fillet(edges.of(faces.bottom), r: 1.mm)
            .move(z: 16.mm)
            - box(40.mm, 40.mm, 200.mm, center: true).rotate(z: 45.deg).move(x: 37.mm, y: 37.mm))
            .shell(open: faces.top, thickness: 1.6.mm);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    // walls 1.6 mm: about 20 000 mm³, not a block of about 180 000
    assert(partVolume(r, "pot") < 30_000, format("%s", partVolume(r, "pot")));
}

unittest
{
    // selectors combine like solids: + union, - difference, & intersection
    auto r = runModel(q{
        @part Solid a() => box(20, 20, 10).shell(open: faces.left + faces.top, thickness: 2.mm);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    // walls 2 mm, open on two faces: outer minus a cavity 18 (x, open) × 16 × 8 (open on top)
    assert(isClose(partVolume(r, "a"), 4000 - 18 * 16 * 8, 1e-6), format("%s", partVolume(r, "a")));
    auto e = error(`@part Solid p() => box(5, 5, 5).fillet(edges.parallel(Z) + faces.top, r: 1);`);
    assert(e.code == Code.type, e.message);
}

unittest
{
    // every name of the prelude is described for completion and the cheatsheet
    import hackerscad.lang.reference : lookupRef;
    import std.algorithm : sort;
    auto it = make();
    string[] missing;
    foreach (name; it.preludeNames)
        if (lookupRef(name).length == 0)
            missing ~= name;
    missing.sort;
    assert(missing.length == 0, "not in lang/reference.d: " ~ missing.join(", "));
}

unittest
{
    // the trace (the GUI's Inspect): the geometry each call of the file made
    enum src = "Profile p() => rect(10, 5) + circle(3);\n"
        ~ "@part Solid s() => p.extrude(4).move(x: 10);\n"
        ~ "@part Solid many()\n{\n    auto a = box(1, 1, 1);\n"
        ~ "    foreach (i; 0 .. 20)\n        a = a + box(1, 1, 1).move(x: i);\n    return a;\n}\n";
    assert(runModel(src).trace.length == 0);   // off unless asked for
    auto it = make();
    it.recordTrace = true;
    auto r = runModel(src, it);
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    bool has(uint line, string fn, string kind)
    {
        foreach (e; r.trace)
            if (e.site.line == line && e.fn == fn && e.kind == kind && e.decl == Span.init)
                return true;
        return false;
    }
    assert(has(1, "rect", "Profile") && has(1, "circle", "Profile") && has(1, "+", "Profile"));
    assert(has(2, "extrude", "Solid") && has(2, "move", "Solid"));
    // what p and s return, by their declarations
    bool returned(string fn, uint declLine, bool flat)
    {
        foreach (e; r.trace)
            if (e.fn == fn && e.decl.line == declLine && e.value.flat == flat)
                return true;
        return false;
    }
    assert(returned("p", 1, true) && returned("s", 2, false));
    // a loop: every run is kept (up to 64), with the count
    size_t kept;
    foreach (e; r.trace)
        if (e.site.line == 7 && e.fn == "+")
        {
            kept++;
            assert(e.calls == 20);
        }
    assert(kept == 20, format("%d", kept));
    // the last entry of the loop is the final union
    auto many = r.parts[1].solid;
    bool lastKept;
    foreach (e; r.trace)
        lastKept = lastKept || (e.site.line == 7 && e.fn == "+" && e.value is many);
    assert(lastKept);
    // the functions of the file and their lines, for the feature tree
    auto fs = it.functionsOf(buildPath(tempDir, "hcad-test.hcad"));
    assert(fs.length == 3 && fs[0].name == "p" && fs[1].name == "s" && fs[2].name == "many", format("%s", fs));
    assert(fs[0].first == 1 && fs[0].last == 1 && fs[1].first == 2 && fs[1].last == 2 && fs[2].first == 3);
}

unittest
{
    // values of the wrong kind, malformed literals and failing library calls
    // are errors with a line, never a crash of the program
    expectErr(`writeln(text("hi", font: 12345));`, "E0202", "import std.shapes;");
    assert(error("import std.shapes;\n@param(doc: 5) immutable k = 3;\n@part Solid a() => box(1, 1, 1);").code == "E0202");
    expectErr(`writeln(0x);`, "E0100");
    expectErr(`writeln(0xFFFFFFFFFFFFFFFFFF);`, "E0100");
    expectErr(`writeln(99999999999999999999);`, "E0100");
    expectErr(`writeln(to!int("abc"));`, "E0202", "import std.conv;");
    expectErr(`writeln([3, 1, 2, 2, 5, 1, 9, 3, 3, 7, 1, 0].sort((p, q) => p <= q));`, "E0202", "import std.algorithm;");
    // integers are exact up to 2^53: past it an error, not a silent rounding or wrap
    expectOut(`long m = -9007199254740990 - 1; writeln(m / -1, " ", m % -1);`, "9007199254740991 0");
    expectErr(`writeln(9007199254740992);`, "E0100");
    expectErr(`writeln(3 ^^ 40);`, "E0501");
    expectErr(`writeln(9007199254740991 + 1);`, "E0501");
    expectErr(`writeln(1e30.to!int);`, "E0501", "import std.conv;");
    expectErr(`writeln(1e400);`, "E0100");
}

unittest
{
    // edge cases found probing the operators: each was a crash, a hang, a
    // wrong result or a silent acceptance
    enum shapes = "import std.shapes;";
    // a struct containing itself, lists doubled without end, huge widths
    expectErr(`writeln(P());`, "E0501", "struct P { P inner; }");
    expectErr(`auto a = [1]; foreach (i; 0 .. 40) a = a ~ a;`, "E0501");
    expectErr(`writeln(format("%300000000.1f", 1.0));`, "E0501", "import std.format;");
    // NaN and infinity never reach the kernel
    expectErr(`writeln(box(1.0 / 0, 1, 1));`, "E0202", shapes);
    expectErr(`writeln(box(1, 1, 1).rotate(z: asin(2)));`, "E0202", shapes ~ "import std.math;");
    // self-intersecting and degenerate polygons
    expectErr(`writeln(polygon([vec(0, 0), vec(10, 10), vec(10, 0), vec(0, 10)]).area);`, "E0202", shapes);
    expectErr(`writeln(polygon([vec(0, 0), vec(10, 0), vec(0, 0), vec(0, 10)]).area);`, "E0202", shapes);
    expectErr(`writeln(polygon([vec(0, 0), vec(5, 0), vec(10, 0)]).area);`, "E0202", shapes);
    expectOut(`writeln(polygon([vec(0, 0), vec(10, 0), vec(10, 0), vec(10, 10), vec(0, 10), vec(0, 0)]).area);`,
        "100 mm^2", shapes);
    // cone with equal radii is a cylinder; rotate does not drop arguments
    expectOut(`writeln(format("%.3f", cone(r1: 5, r2: 5, h: 10).volume));`, "785.398", shapes ~ "import std.format;");
    expectErr(`writeln(cone(r1: -5, r2: 2, h: 10));`, "E0202", shapes);
    expectErr(`writeln(box(10, 20, 30).rotate(90.deg, x: 90));`, "E0204", shapes);
    expectErr(`writeln(box(10, 20, 30).rotate(axis: X));`, "E0205", shapes);
    // a full turn either way, or several, spaces the copies evenly
    expectOut(`auto b = box(2, 2, 2).move(x: 10);
        writeln(b.circularPattern(4, angle: -360.deg).volume, " ", b.circularPattern(4, angle: 720.deg).volume);`,
        "32 mm^3 32 mm^3", shapes);
    expectErr(`writeln(fuse([box(2, 2, 2), rect(4, 4)]));`, "E0202", shapes);
    expectOut(`Solid[] cs; cs ~= box(1, 1, 1); cs ~= box(2, 2, 2); writeln(cs.length);`, "2", shapes);
    // the empty sum is zero of any kind
    expectOut(`Solid[] e; writeln((box(2, 2, 2) - e.sum).volume, " ", [1.mm].filter(x => false).sum + 1.mm);`,
        "8 mm^3 1 mm", shapes ~ "import std.algorithm;");
    // math on numbers and angles
    expectOut(`writeln(round(2.5), " ", floor(45.5.deg), " ", ceil(1.2.deg));`, "3 45° 2°", "import std.math;");
    expectOut(`write("a"); write("b"); writeln("c");`, "abc");
    expectOut(`writeln(format("[%5d][%-3s][%d]", 42, "a", 90.deg));`, "[   42][a  ][90]", "import std.format;");
    expectErr(`writeln(format("%d", 2.5));`, "E0202", "import std.format;");
    expectErr(`writeln(clamp(5, 10, 0));`, "E0202", "import std.algorithm;");
    expectOut(`writeln(0.mm == 0, " ", 1.mm != 2.mm);`, "true true");
    expectErr(`writeln(1.mm == 1);`, "E0310");
    // declared types hold on every assignment
    expectErr(`int a = 1; a = "s";`, "E0202");
    expectErr(`Length b = 1.mm; b = 2.deg;`, "E0310");
    expectErr(`int c = 1; c += 0.5;`, "E0202");
    expectOut(`foreach (i, x; ["a", "b"].enumerate) write(i, x); writeln();`, "0a1b", "import std.range;");
    // @param limits in the parameter's unit; whole numbers stay whole
    auto it = make();
    it.overrides = ["a": "100"];
    assert(error("@param(\"a\", min: 10, max: 90) immutable a = 45.deg;\nimport std.shapes;\n@part Solid p() => box(1, 1, 1);",
        it).code == "E0202");
    it = make();
    it.overrides = ["n": "2.5"];
    assert(error("@param(\"n\", min: 1, max: 10) immutable n = 3;\nimport std.shapes;\n@part Solid p() => box(n, 1, 1);",
        it).code == "E0202");
    // threads: bounded, and no negative clearance
    expectErr(`writeln(cylinder(d: 8, h: 20).thread(faces.largest, "M8x0.0001"));`, "E0501", shapes);
    expectErr(`writeln(cylinder(d: 8, h: 20).thread(faces.largest, "M8", starts: 100));`, "E0501", shapes);
    expectErr(`writeln(cylinder(d: 8, h: 20).thread(faces.largest, "M8", clearance: -1.mm));`, "E0202", shapes);
    // frames stand on flat faces only
    expectErr(`writeln(cylinder(d: 10, h: 20).frame(faces.largest));`, "E0202", shapes);
    // overhangs of a curved surface: 2πR²(1 - sin a) for a sphere, within 2 %
    expectOut(`immutable o = sphere(r: 10).move(z: 10).overhangs(45.deg) / 1.mm^^2;
        writeln(abs(o / (2 * PI * 100 * (1 - sin(45.deg))) - 1) < 0.02);`, "true", shapes ~ "import std.math;");
    expectErr(`writeln(nothing.centroid);`, "E0410", shapes);
    // bodies touching along an edge or at a corner: one body, bridged, and a warning
    {
        auto r = runModel(shapes ~ "\n@part Solid p() => box(10, 10, 10) + box(10, 10, 10).move(x: 10, y: 10);"
            ~ "\n@part Solid q() => box(10, 10, 10) + box(10, 10, 10).move(x: 10, y: 10, z: 10);");
        assert(r.diagnostics.count!(d => d.severity == Severity.warning && d.message.canFind("bridged")) == 2);
        foreach (p; r.parts)
            assert(make().kernel.solids(p.solid.brep).length == 1 && abs(partVolume(r, p.name) - 2000) < 0.01, p.name);
    }
    // fillets, chamfers, shells and drafts say what is wrong with their sizes
    expectErr(`writeln(box(10, 10, 10).fillet(edges.parallel(Z), r: 0));`, "E0202", shapes);
    expectErr(`writeln(box(10, 10, 10).chamfer(edges.parallel(Z), d: -1));`, "E0202", shapes);
    expectErr(`writeln(box(10, 10, 10).shell(open: faces.top, thickness: 0));`, "E0202", shapes);
    expectErr(`writeln(box(10, 10, 10).shell(open: faces.top, thickness: 12));`, "E0202", shapes);
    expectErr(`writeln(box(10, 10, 10).draft(faces.normal(X), angle: 90.deg));`, "E0202", shapes);
    // a circle tapered almost to a point: an exact truncated cone
    expectOut(`writeln(format("%.3f", circle(r: 3).extrude(5.mm, taper: 30.deg).volume / 1.mm^^3));`,
        format("%.3f", PI * 5 / 3 * (9 + 3 * (3 - 5 / sqrt(3.0)) + (3 - 5 / sqrt(3.0)) ^^ 2)),
        shapes ~ "import std.format;");
    expectErr(`writeln(spurGear(1.mm, 20, 5.mm, backlash: 5.mm));`, "E0600", "import gears;");
}

unittest
{
    // recursion up to the limit of calls fits the evaluation thread's stack;
    // beyond it, and with code nested too deep, an error instead of a crash
    expectOut(`writeln(f(990));`, "990", "int f(int n) { if (n == 0) return 0; return 1 + f(n - 1); }");
    expectErr(`writeln(f(5000));`, "E0501", "int f(int n) { if (n == 0) return 0; return 1 + f(n - 1); }");
    import std.array : replicate;
    expectErr(`writeln(` ~ "(".replicate(3000) ~ "1" ~ ")".replicate(3000) ~ `);`, "E0501");
}

unittest
{
    // a path moved or coloured is still a path: it can be swept along, and
    // it is not a part
    auto r = runModel(q{
        immutable p = path([vec(0, 0, 0), vec(0, 0, 20), vec(20, 0, 20)]);
        @part Solid tube() => circle(d: 4).sweep(p.move(x: 5).color("red"));
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(partVolume(r, "tube") > 100);
    assert(error("@part Solid a() => path([vec(0, 0, 0), vec(0, 0, 20)]).move(x: 3);").message.canFind("Path"));
}

unittest
{
    // a drawing rendered twice (two exports) keeps its section hatched
    import hackerscad.lang.drawingval : DrawingVal;
    import hackerscad.drawing.sheet : toSvg;
    auto r = runModel(q{
        @part Solid block() => box(40, 20, 10) - cylinder(d: 8, h: 10);
        @drawing Drawing sheet()
        {
            auto d = drawing(title: "Block");
            d.standardViews(block);
            d.section(block, XZ, label: "A");
            return d;
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    auto dv = cast(DrawingVal) r.drawings[0].drawing;
    auto first = toSvg(dv.render()), second = toSvg(dv.render());
    assert(first == second, "a second render differs from the first");
}

unittest
{
    // associative arrays: numeric keys are exact, and equal contents compare equal
    expectOut(`int[double] m; m[1000000] = 1; m[1000001] = 2; m[1.0000001] = 3; m[1.0000002] = 4; writeln(m.length);`, "4");
    expectOut(`int[string] p, q; p["a"] = 1; q["a"] = 1; writeln(p == q); q["b"] = 2; writeln(p == q);`, "true\nfalse");
}

unittest
{
    // an edge's length is along the curve: a full circle is 2πr, not 0
    auto r = runModel(q{
        @part Solid c() => cylinder(r: 10, h: 5).chamfer(edges.filter(e => e.isCircle && e.length > 1.mm), d: 1.mm);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    // the sorted edge grouping gives the same edges as grouping them in a map
    import hackerscad.render.raster : edgeSets;
    import hackerscad.geom.mesh : Mesh;
    import hackerscad.geom.vec : Vec3;
    import std.algorithm : min, max, sort;
    static void reference(const Mesh m, double angleDeg, out uint[2][] sharp, out uint[2][] tangent)
    {
        import std.math : cos, PI;
        immutable limit = cos(angleDeg * PI / 180);
        Vec3 normal(size_t t)
        {
            auto a = m.vertex(m.tris[t * 3]), b = m.vertex(m.tris[t * 3 + 1]), c = m.vertex(m.tris[t * 3 + 2]);
            return (b - a).cross(c - a).normalized;
        }
        size_t[][ulong] faces;
        foreach (t; 0 .. m.triangleCount)
            foreach (k; 0 .. 3)
            {
                ulong a = m.tris[t * 3 + k], b = m.tris[t * 3 + (k + 1) % 3];
                faces[min(a, b) << 32 | max(a, b)] ~= t;
            }
        bool[ulong] pairs;
        foreach (key, ts; faces)
            if (ts.length == 2 && normal(ts[0]).dot(normal(ts[1])) < limit)
            {
                immutable f0 = m.faceOf(ts[0]), f1 = m.faceOf(ts[1]);
                if (f0 != f1 && f0 >= 0 && f1 >= 0)
                    pairs[cast(ulong) min(f0, f1) << 32 | max(f0, f1)] = true;
            }
        foreach (key, ts; faces)
        {
            immutable a = cast(uint)(key >> 32), b = cast(uint)(key & 0xffff_ffff);
            if (ts.length != 2 || normal(ts[0]).dot(normal(ts[1])) < limit)
                sharp ~= [a, b];
            else
            {
                immutable f0 = m.faceOf(ts[0]), f1 = m.faceOf(ts[1]);
                if (f0 != f1 && f0 >= 0 && f1 >= 0)
                {
                    if ((cast(ulong) min(f0, f1) << 32 | max(f0, f1)) in pairs)
                        sharp ~= [a, b];
                    else
                        tangent ~= [a, b];
                }
            }
        }
    }
    auto r = runModel(q{
        @part Solid a() => (box(30, 20, 10).fillet(edges.parallel(Z), r: 3) - cylinder(d: 8, h: 10))
            .chamfer(edges.of(faces.top), d: 0.5);
        @part Solid b() => cylinder(d: 20, h: 20, center: true) & cylinder(d: 20, h: 20, center: true).rotate(x: 90);
    });
    foreach (p; r.parts)
    {
        auto m = kernel.tessellate(p.solid.brep, 0.05, 0.2).welded;
        uint[2][] s1, t1, s2, t2;
        edgeSets(m, 25, s1, t1);
        reference(m, 25, s2, t2);
        foreach (x; [&s1, &t1, &s2, &t2])
            sort(*x);
        assert(s1 == s2 && t1 == t2, p.name);
        assert(m.isClosed);
    }
}

unittest
{
    // load() reuses an unchanged file, and reads it again when it changes
    import hackerscad.io.stl : toStl;
    import std.file : write, mkdirRecurse, rmdirRecurse;
    auto dir = buildPath(tempDir, "hcad-load-cache-test");
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto file = buildPath(dir, "part.stl");
    write(file, toStl(kernel.tessellate(kernel.box(10, 10, 10), 0.01, 0.1).welded));
    double volumeOf()
    {
        auto it = make();
        it.root = dir;
        auto r = it.runSource(q{
            @part Solid p() => load("part.stl");
        }, buildPath(dir, "main.hcad"));
        return partVolume(r, "p");
    }
    assert(isClose(volumeOf(), 1000, 1e-6));
    assert(isClose(volumeOf(), 1000, 1e-6));
    write(file, toStl(kernel.tessellate(kernel.box(20, 10, 10), 0.01, 0.1).welded));
    assert(isClose(volumeOf(), 2000, 1e-6));
}

unittest
{
    mixin(slowTest);
    // a solid made from a fine mesh: volume and area summed from its
    // triangles match the mesh's own
    auto m = kernel.tessellate(kernel.sphere(10), 0.01, 0.05).welded;
    assert(m.triangleCount > 500);
    auto s = kernel.fromMesh(m);
    assert(isClose(kernel.volume(s), m.volume, 1e-9), format("%s %s", kernel.volume(s), m.volume));
    assert(kernel.area(s) > 4 * 3.14 * 100 * 0.98);
}

unittest
{
    // a step shows its solid as it made it, unless the same statement moves
    // it at once: a rod kept in a variable and turned later stands upright
    auto r = runModel(q{
        @part Solid body()
        {
            auto cube = box(20, 20, 20, center: true);
            auto rod = cylinder(d: 14, h: 30, center: true);
            auto peg = cylinder(d: 4, h: 10).move(x: 30);
            return cube - rod.rotate(x: 90) - rod.rotate(y: 90) + peg;
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    import std.algorithm : filter;
    import std.array : array;
    auto cylinders = r.features.filter!(f => f.kind == "cylinder").array;
    assert(cylinders.length == 2);
    auto rod = kernel.bbox(cylinders[0].result.brep);
    assert(!cylinders[0].moved && isClose(rod.size.z, 30, 1e-6), "the rod as made, standing");
    assert(cylinders[1].moved && kernel.bbox(cylinders[1].result.brep).center.x > 29, "the peg where it was moved to");
}

unittest
{
    // the copies of a seam vertex (a cylinder's side meets itself) share one
    // normal, so the light does not show the seam
    import hackerscad.render.raster : vertexNormals;
    import hackerscad.geom.vec : Vec3;
    import std.math : lround;
    auto raw = kernel.tessellate(kernel.cylinder(7, 30), 0.02, 0.25);
    auto normals = vertexNormals(raw);
    Vec3[long[4]] seen;
    foreach (i; 0 .. raw.vertexCount)
    {
        size_t t;
        foreach (j, v; raw.tris)
            if (v == i)
            {
                t = j / 3;
                break;
            }
        auto p = raw.vertex(i);
        long[4] key = [raw.faceOf(t), lround(p.x * 1e5), lround(p.y * 1e5), lround(p.z * 1e5)];
        if (auto n = key in seen)
            assert((*n - normals[i]).length < 1e-9, "two copies of a seam vertex with different normals");
        else
            seen[key] = normals[i];
    }
}

unittest
{
    mixin(slowTest);
    // hull and minkowski: volumes and areas as computed by hand (within the
    // facets of the curved surfaces), profiles in a plane stay profiles
    import std.math : abs, PI;
    auto r = runModel(q{
        @part Solid capsule() => hull(sphere(5), sphere(5).move(x: 20));
        @part Solid plate() => hull([cylinder(r: 4, h: 3), cylinder(r: 4, h: 3).move(x: 30),
            cylinder(r: 4, h: 3).move(y: 20), cylinder(r: 4, h: 3).move(x: 30, y: 20)]);
        @part Solid slot() => hull(circle(r: 4), circle(r: 4).move(x: 20)).extrude(3);
        @part Solid rounded() => minkowski(box(20, 20, 10), sphere(2));
        @part Solid ell() => minkowski(box(30, 10, 5) + box(10, 30, 5).move(x: -10, y: 10), sphere(1.5));
        @part Solid octagon() => minkowski(rect(10, 10), rect(3, 3).rotate(z: 45)).extrude(1);
        @part Solid grown() => box(20, 20, 10).offset(2);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    void near(string part, double want, double tolerance)
    {
        immutable got = partVolume(r, part);
        assert(abs(got - want) <= tolerance * want, format("%s: %s, expected about %s", part, got, want));
    }
    near("capsule", PI * 25 * 20 + 4.0 / 3 * PI * 125, 0.01);
    near("plate", (30 * 20 + 2 * 30 * 4 + 2 * 20 * 4 + PI * 16) * 3, 0.002);
    near("slot", (20 * 8 + PI * 16) * 3, 0.005);
    // a box grown by a ball: its faces moved out, its edges quarter cylinders, its corners a ball
    immutable roundedBox = 4000 + 1600 * 2 + 200 * PI * 4 / 4 + 4.0 / 3 * PI * 8;
    near("rounded", roundedBox, 1e-4);
    near("grown", roundedBox, 1e-4);
    near("ell", 5370.2, 1e-3);
    // a square grown by a diamond of half-diagonal h: an octagon
    immutable h = 1.5 * 2 ^^ 0.5;
    near("octagon", (10 + 2 * h) ^^ 2 - 2 * h * h, 1e-6);
    assert(error("@part Solid p() => minkowski(box(5, 5, 5), circle(r: 1));").message.canFind("two solids or two profiles"));
    assert(error("@part Solid p() => hull(circle(r: 1), circle(r: 1).move(x: 2), circle(r: 1).move(x: 4)).extrude(1)"
        ~ " - hull(vec(0, 0, 0));").message.length > 0);
}

unittest
{
    // mass properties of a block 10 × 20 × 30: its centre, 6 g of water, the
    // moments m/12 (b² + c²) about its three axes
    expectOut(`auto b = box(10, 20, 30).move(x: 5); writeln(b.centroid, " ", b.mass(density: 1), " ", b.inertia(density: 1));`,
        "[5 mm, 0 mm, 15 mm] 6 [250, 500, 650]", "import std.shapes;");
    expectErr(`writeln(box(1, 1, 1).mass(density: 0));`, "E0202", "import std.shapes;");
}

unittest
{
    // profiles from solids: a cut by a plane (exact), the shadow seen from
    // above (within the meshing of curved surfaces)
    auto r = runModel(q{
        import std.math;
        immutable cube = box(20, 20, 20, center: true) - cylinder(d: 14, h: 30, center: true).rotate(x: 90)
            - cylinder(d: 14, h: 30, center: true).rotate(y: 90);
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable mm2 = 1.mm ^^ 2;
            assert(abs(cube.section(XZ).area / mm2 - 120) < 1e-6, "cut");
            assert(abs(sphere(10).section(XY.offset(6.mm)).area / mm2 - PI * 64) < 1e-6, "ball");
            assert(abs(sphere(10).projection.area / mm2 - PI * 100) < PI, "shadow");
            assert(abs(cylinder(r: 5, h: 20).rotate(x: 90).projection.area / mm2 - 200) < 0.5, "lying");
            // on another plane: the standing cylinder seen from the front, lying in XZ
            immutable side = cylinder(r: 5, h: 20).projection(XZ.offset(-30.mm));
            assert(abs(side.area / mm2 - 200) < 0.5, "side");
            assert(abs(side.bbox.size.y / 1.mm) < 1e-6 && abs(side.bbox.size.z / 1.mm - 20) < 1e-6, "in XZ");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error("@part Solid p() => circle(r: 2).section(XY).extrude(1);").message.canFind("cuts solids"));
}

unittest
{
    // push and pull: flat faces swept along their normals, or slanted
    auto r = runModel(q{
        immutable b = box(10, 10, 10);
        @part Solid up() => b.extrude(faces.top, depth: 5);
        @part Solid down() => b.cut(faces.top, depth: 4);
        @part Solid sides() => b.extrude(faces.filter(f => f.isPerpendicular(Z) == false), depth: 1);
        @part Solid slant() => b.extrude(faces.top, depth: 5, along: vec(1, 0, 1));
        // the sides stay one face each: the front can be the plane of a frame
        @part Solid merged() => up().cut(circle(d: 2), on: faces.front, depth: 1.mm);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(isClose(partVolume(r, "up"), 1500, 1e-9));
    assert(isClose(partVolume(r, "down"), 600, 1e-9));
    assert(isClose(partVolume(r, "sides"), 1000 + 4 * 100, 1e-9));
    // a prism slanted at 45°: the same base, height 5/√2
    assert(isClose(partVolume(r, "slant"), 1000 + 100 * 5 / sqrt(2.0), 1e-9));
    assert(error("@part Solid p() => cylinder(r: 5, h: 5).extrude(faces.largest, depth: 1);")
        .message.canFind("flat"));
    assert(error("@part Solid p() => box(1, 1, 1).extrude(faces.top, depth: 1, along: X);").message.canFind("plane"));
}

unittest
{
    // printing: teardrops, overhanging faces, overhang and thin-wall areas
    auto r = runModel(q{
        import std.math;
        // a shelf: a 0.5 mm plate sticking out 10 mm from a post on the bed
        immutable shelf = box(10, 10, 10).move(z: 5) + box(30, 10, 0.5).move(z: 10.25);
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable mm2 = 1.mm ^^ 2;
            // circle plus the triangle up to the point: r² (π - π/4 + 1) for 45°
            assert(abs(teardrop(d: 10).area / mm2 - 25 * (PI * 3 / 4 + 1)) < 1e-6, "teardrop");
            assert(abs(teardrop(d: 10, flat: true).bbox.size.y / 1.mm - 10) < 1e-6, "flat");
            assert(abs(shelf.overhangs / mm2 - 200) < 1e-6, "shelf");
            assert(shelf.overhangs(60.deg) == shelf.overhangs, "flat underside");
            assert(box(10, 10, 10).overhangs / mm2 == 0, "cube");
            // the plate's top and underside beside the post (over the post it is 10.5 thick)
            assert(abs(shelf.thinWalls / mm2 - 400) < 1, "thin");
            assert(shelf.thinWalls(0.4.mm) / mm2 == 0, "thick enough");
            // a horizontal hole: the upper half of its wall overhangs, a teardrop's point does not
            immutable wall = box(20, 10, 20);
            immutable round = wall.cut(circle(d: 8), on: faces.front, depth: 10.mm);
            immutable drop = wall.cut(teardrop(d: 8), on: faces.front, depth: 10.mm);
            assert(round.overhangs / mm2 > 20, "round hole");
            assert(drop.overhangs / mm2 < 1, "teardrop hole");
            // the hole's wall, the one overhanging face
            assert(abs(round.plane(faces.overhanging()).origin.z / 1.mm - 10) < 1e-6, "selector");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error("@part Solid p() => box(20, 10, 20).cut(teardrop(d: 8), on: faces.front, depth: 10.mm)"
        ~ ".chamfer(edges.of(faces.overhanging()), d: 1);").message.canFind("no"));
}

unittest
{
    // on every wall a frame's Y goes up and X right seen from outside: a
    // teardrop points up on the back as on the front
    auto r = runModel(q{
        import std.math;
        immutable wall = box(20, 20, 20);
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            foreach (f; [wall.frame(faces.front), wall.frame(faces.back), wall.frame(faces.left), wall.frame(faces.right)])
            {
                assert(f.y == Z, "y up");
                assert(f.x.cross(f.y) == f.z, "right-handed");
            }
            assert(wall.frame(faces.top).x == X, "flat faces keep X");
            immutable mm2 = 1.mm ^^ 2;
            foreach (side; [faces.front, faces.back, faces.left, faces.right])
                assert(wall.cut(teardrop(d: 6), on: side, at: vec(0.mm, 0.mm, 10.mm), depth: 5.mm).overhangs / mm2 < 0.5,
                    "teardrop up");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    mixin(slowTest);
    // twisted extrusions and sweeps: the profile turns, the volume stays
    auto r = runModel(q{
        import std.math;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable mm3 = 1.mm ^^ 3;
            immutable bar = rect(20, 10).extrude(30, twist: 90.deg);
            // the guide of the twist is a fitted curve: a few millionths off
            assert(abs(bar.volume / mm3 - 6000) < 0.01, "volume");
            // a quarter turn: the top lies across the bottom
            assert(abs(bar.section(XY.offset(30.mm - 1e-6.mm)).bbox.size.x / 1.mm - 10) < 1e-3, "turned");
            assert(abs(bar.section(XY.offset(15.mm)).bbox.size.x / 1.mm - 15 * sqrt(2.0)) < 1e-3, "half way");
            assert(abs(polygon(6, r: 10).extrude(40, twist: 720.deg).volume / mm3 - 40 * 150 * sqrt(3.0)) < 0.1,
                "two turns");
            immutable down = (circle(r: 15) - circle(r: 13)).extrude(-20, twist: -60.deg);
            assert(abs(down.bbox.min.z / 1.mm + 20) < 1e-6, "downwards");
            immutable ribbon = rect(4, 2).sweep(spline([vec(0, 0, 0), vec(20, 0, 10), vec(40, 10, 30)]), twist: 180.deg);
            assert(abs(ribbon.volume / mm3 - 8 * ribbon.bbox.size.length / 1.mm) < 8 * 60, "ribbon");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error("@part Solid p() => rect(5, 5).extrude(5, twist: 30.deg, taper: 2.deg);").message.canFind("not both"));
}

unittest
{
    // tapered extrusions: as tall as asked, the sides flat and meeting at
    // sharp edges, the outline and the holes leaning opposite ways
    auto r = runModel(q{
        import std.math;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable mm2 = 1.mm ^^ 2, mm3 = 1.mm ^^ 3;
            immutable g = 5 * tan(10.deg);
            // a frustum of a square of side a to b, and of a cone r to s, 5 tall
            double square(double a, double b) => 5.0 / 3 * (a * a + b * b + a * b);
            double cone(double r, double s) => PI * 5.0 / 3 * (r * r + s * s + r * s);
            immutable plate = rect(20, 20) - circle(r: 5);
            immutable outward = plate.extrude(5, taper: -10.deg);
            assert(abs(outward.bbox.size.z / 1.mm - 5) < 1e-6, "outward: as tall as asked");
            assert(abs(outward.volume / mm3 - (square(20, 20 + 2 * g) - cone(5, 5 - g))) < 1e-3, "outward");
            immutable outTop = outward.section(XY.offset(5.mm - 1e-6.mm));
            assert(abs(outTop.bbox.size.x / 1.mm - (20 + 2 * g)) < 1e-3, "outward: the outline grows, sharp");
            assert(abs(outTop.area / mm2 - ((20 + 2 * g) ^^ 2 - PI * (5 - g) ^^ 2)) < 1e-2, "outward: the hole shrinks");
            immutable inward = plate.extrude(5, taper: 10.deg);
            assert(abs(inward.volume / mm3 - (square(20, 20 - 2 * g) - cone(5, 5 + g))) < 1e-3, "inward");
            immutable down = plate.extrude(-5, taper: 10.deg);
            assert(abs(down.bbox.min.z / 1.mm + 5) < 1e-6 && abs(down.bbox.max.z / 1.mm) < 1e-6, "downwards");
            assert(abs(down.volume / mm3 - inward.volume / mm3) < 1e-3, "downwards: the same solid");
            // a profile shrunk and tapered back out as far: the roundings of
            // its hole's corners close up just at the top, which is the profile
            immutable frame = rect(30, 20) - rect(10, 6);
            immutable foot = frame.offset(-1).extrude(1, taper: -45.deg);
            assert(abs(foot.bbox.size.z / 1.mm - 1) < 1e-6, "foot: as tall as asked");
            assert(abs(foot.section(XY.offset(1.mm - 1e-6.mm)).area / mm2 - frame.area / mm2) < 0.2, "foot: the top");
            // and it fuses with what stands on it
            immutable stand = foot + frame.extrude(10).move(z: 0.7);
            assert(abs(stand.bbox.size.z / 1.mm - 10.7) < 1e-6, "foot and stand");
            assert(stand.volume > frame.extrude(10).volume + foot.volume * 0.5, "foot and stand: one solid");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    // a feature that closes up on the way is an error, not a crash
    immutable closes = error("@part Solid p() => (rect(30, 20) - rect(10, 6)).offset(-1).extrude(1.5, taper: -45.deg);");
    assert(closes.message.canFind("closes up") && closes.message.canFind("atan(r / height)"), closes.message);
}

unittest
{
    mixin(slowTest);
    // threads on cylindrical faces: a bolt's shaft, a nut's hole
    auto r = runModel(q{
        import std.math;
        immutable blank = cylinder(d: 13, h: 5) + cylinder(d: 8, h: 30).move(z: 5);
        immutable shaft = faces.filter(f => f.center.z > 10.mm && f.center.z < 30.mm);
        @part Solid bolt() => blank.thread(shaft, "M8");
        @part Solid part() => blank.thread(shaft, "M8", turns: 8, left: true);
        @part Solid nut() => (box(20, 20, 8) - cylinder(d: 6.8, h: 20, center: true))
            .thread(faces.filter(f => f.area > 165 * 1.mm ^^ 2 && f.area < 200 * 1.mm ^^ 2), "M8");
        unittest
        {
            immutable mm3 = 1.mm ^^ 3, head = PI * 6.5 ^^ 2 * 5;
            // the threaded length of an M8 (ISO basic profile) is about 1241 mm³ over 30 mm
            assert(abs(bolt.volume / mm3 - head - 1240.9) < 2, "bolt");
            // 8 turns are 10 mm threaded, the other 20 mm stay plain
            assert(abs(part.volume / mm3 - head - PI * 16 * 20 - 412.5) < 3, "part");
            assert(part.isValid && bolt.isValid && nut.isValid, "valid");
            // the nut loses a little more than its plain hole
            assert(nut.volume < 3200 * mm3 - PI * 3.4 ^^ 2 * 8 * mm3 - 40 * mm3, "nut");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error(`@part Solid p() => cylinder(d: 8, h: 20).thread(faces.filter(f => f.center.z > 5.mm `
        ~ `&& f.center.z < 15.mm), "M10");`).message.canFind("wants ⌀10"));
    assert(error(`@part Solid p() => (box(20, 20, 8) - cylinder(d: 8, h: 20, center: true))`
        ~ `.thread(faces.filter(f => f.area > 165 * 1.mm ^^ 2 && f.area < 220 * 1.mm ^^ 2), "M8");`).message.canFind("tap drill"));
    assert(error(`@part Solid p() => box(10, 10, 10).thread(faces.top, "M8");`).message.canFind("cylindrical"));
}

unittest
{
    // a name that exists on its own, used as a member: no "did you mean" the same name
    auto d = error("@part Solid p() { foreach (f; box(1, 1, 1).faces) {} return box(1, 1, 1); }");
    assert(d.message.canFind("stands on its own") && !d.suggestion.canFind("'faces'"), d.message ~ " " ~ d.suggestion);
}

unittest
{
    mixin(slowTest);
    // the thread families, and the taper of pipe threads
    auto r = runModel(q{
        import std.math;
        Solid shaft(Length d, Length h) => cylinder(d: d * 1.6, h: 5) + cylinder(d: d, h: h).move(z: 5);
        @part Solid unc() => shaft(6.35.mm, 15.mm).thread(faces.largest, "1/4-20 UNC");
        @part Solid tr() => shaft(12.mm, 15.mm).thread(faces.largest, "Tr12x3");
        @part Solid npt() => shaft(21.336.mm, 20.mm).thread(faces.largest, "1/2 NPT");
        @part Solid socket() => (box(40, 40, 20) - cylinder(d: 18.6, h: 50, center: true))
            .thread(faces.filter(f => f.area > 1100 * 1.mm ^^ 2 && f.area < 1200 * 1.mm ^^ 2), "R1/2");
        unittest
        {
            assert(unc.isValid && tr.isValid && npt.isValid && socket.isValid, "valid");
            // NPT narrows by 1 in 16 on the diameter: 1.25 mm over 20 mm, a little less at the bevel
            immutable top = npt.section(XY.offset(23.mm)).bbox.size.x, bottom = npt.section(XY.offset(7.mm)).bbox.size.x;
            assert(bottom - top > 0.8.mm && bottom - top < 1.3.mm, "taper");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error(`@part Solid p() => cylinder(d: 8, h: 20).thread(faces.filter(f => f.center.z > 5.mm `
        ~ `&& f.center.z < 15.mm), "Z9");`).message.canFind("names a thread"));
}

unittest
{
    // what a solid is made of: a plate with a circle of holes, read back from its triangles
    auto r = runModel(q{
        immutable plate = box(40, 40, 5)
            - cylinder(d: 3.4, h: 20, center: true).move(x: 12).circularPattern(6, axis: Z)
            - cylinder(d: 10, h: 20, center: true);
        @part Solid p() => plate;
        unittest { writeln(plate.features); }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    immutable report = r.log[0].text;
    assert(report.canFind("hole ⌀10 ") && report.canFind("hole ⌀3.4 = M3 clearance"), report);
    assert(report.canFind("pattern: 6× hole ⌀3.4 on a circle of radius 12") && report.canFind("60° apart"), report);
}

unittest
{
    // a section read back as a sketch: a plate with rounded corners and a hole, as STL, cut across;
    // the sketch it gives evaluates to the same outline
    import hackerscad.io.stl : toStl;
    import hackerscad.tool.features : sectionReport;
    import std.file : write, mkdirRecurse, rmdirRecurse;
    import std.string : indexOf;
    auto dir = buildPath(tempDir, "hcad-section-test");
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto plate = kernel.boolean(kernel.extrude(kernel.profileRound(kernel.rect(40, 20), 5), 6, 0),
        kernel.translate(kernel.cylinder(3, 20), Vec3(8, 0, -5)), BoolOp.cut);
    write(buildPath(dir, "plate.stl"), toStl(kernel.tessellate(plate, 0.01, 0.1).welded));
    immutable rep = sectionReport(buildPath(dir, "plate.stl"), null, "xy", 3);
    assert(rep.canFind("circle ⌀6, centre (8, 0)") && rep.canFind("arc r 5"), rep);
    // a region round the hole: only its outline, not the plate's
    immutable hole = sectionReport(buildPath(dir, "plate.stl"), null, "xy", 3, [4, -4, 12, 4]);
    assert(hole.canFind("circle ⌀6, centre (8, 0)") && !hole.canFind("arc r 5") && !hole.canFind("outline 2"), hole);
    // a region across the plate's end: the outline cut at its edges; without the sketch on request
    immutable end = sectionReport(buildPath(dir, "plate.stl"), null, "xy", 3, [12, -15, 30, 15], false);
    assert(end.canFind("cut at its edges") && end.canFind("arc r 5") && !end.canFind("Profile section"), end);
    assert(!end.canFind(" 0 long"), end);
    assert(!end.canFind("circle ⌀6"), "the hole lies outside the region");
    assert(end.canFind("line (12, -10) → (12, 10)") || end.canFind("line (12, 10) → (12, -10)"), end);
    auto code = rep[rep.indexOf("/// The section") .. $];
    auto r = runModel("import std.math;\n" ~ code ~ "@part Solid p() => section().extrude(1.mm);\n"
        ~ "unittest { writeln(section().area / 1.mm ^^ 2); }\n");
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    import std.conv : to;
    import std.math : abs, PI;
    // 40 × 20 less the four corners' squares plus their quarter circles, less the hole
    immutable expected = 800 - 4 * (25 - PI * 25 / 4) - PI * 9;
    assert(abs(r.log[0].text.to!double - expected) < 0.5, r.log[0].text);

    // sizes that do not round evenly (corners r 4.03 round a centre off the
    // grid): the arcs' ends, pinned to the hundredth, are not the same distance
    // from a pinned centre; the sketch solves, with nothing left free
    auto odd = kernel.translate(kernel.extrude(kernel.profileRound(kernel.rect(40.13, 20.07), 4.03), 6, 0),
        Vec3(0.333, -0.271, 0));
    write(buildPath(dir, "odd.stl"), toStl(kernel.tessellate(odd, 0.01, 0.1).welded));
    immutable oddRep = sectionReport(buildPath(dir, "odd.stl"), null, "xy", 3);
    auto oddCode = oddRep[oddRep.indexOf("/// The section") .. $];
    auto o = runModel("import std.math;\n" ~ oddCode ~ "@part Solid p() => section().extrude(1.mm);\n"
        ~ "unittest { writeln(section().area / 1.mm ^^ 2); }\n");
    assert(o.diagnostics.length == 0, oddCode ~ o.diagnostics[0].message);
    immutable oddArea = 40.13 * 20.07 - 4 * 4.03 ^^ 2 * (1 - PI / 4);
    assert(abs(o.log[0].text.to!double - oddArea) < 0.5, o.log[0].text);
}

unittest
{
    mixin(slowTest);
    // hcad features: chamfers told as such, with their size, and a surface
    // turned round an axis (a torus here) told with its axis and place
    import hackerscad.tool.features : meshOf;
    import hackerscad.geom.meshfeatures : analyse, report;
    import std.file : write, mkdirRecurse, rmdirRecurse;
    auto dir = buildPath(tempDir, "hcad-features-test");
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    immutable model = buildPath(dir, "shapes.hcad");
    write(model, q{
        @part Solid block() => box(30, 20, 10).chamfer(edges.of(faces.top), d: 1);
        @part Solid ring() => torus(10, 3).move(x: 5, y: 3);
    });
    immutable block = report(analyse(meshOf(model, "block")));
    assert(block.canFind("chamfer 1 mm") && block.canFind("chamfers: 4 of 1 mm"), block);
    immutable ring = report(analyse(meshOf(model, "ring")));
    assert(ring.canFind("turned round the axis (0, 0, 1) through (5, 3, 0)"), ring);
}

unittest
{
    mixin(slowTest);
    // hcad match: a nut trap cut in three steps is one hole, told as stepped,
    // not three slivers; the copy's straight one is the same hole, different
    import hackerscad.tool.features : matchReport;
    import std.file : write, mkdirRecurse, rmdirRecurse;
    auto dir = buildPath(tempDir, "hcad-match-test");
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    immutable model = buildPath(dir, "trap.hcad");
    write(model, q{
        import hardware : hexPrism;
        @part Solid copy() => box(20, 20, 10) - hexPrism(5.45, 9).move(z: 2);
        @part Solid original() => box(20, 20, 10) - hexPrism(5.45, 9).move(z: 2)
            - hexPrism(5.6, 4).move(z: 7) - hexPrism(5.75, 3).move(z: 8.5);
    });
    immutable rep = matchReport(model, "copy", "original");
    assert(rep.canFind("stepped from 5.45 to 5.75 in 3 layers (tapered)"), rep);
    assert(rep.canFind("in both, different"), rep);
}

unittest
{
    // how far two solids are: a block against the same block 0.5 mm taller
    auto r = runModel(q{
        import std.math;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable d = box(20, 10, 5).deviation(box(20, 10, 5.5));
            assert(abs(d / 1.mm - 0.5) < 1e-6, "taller");
            assert(cylinder(d: 10, h: 5).deviation(cylinder(d: 10, h: 5)) < 0.001.mm, "same");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    // a block tilted and moved anyhow, set straight: on its largest face, longest along X, centred
    auto r = runModel(q{
        import std.math;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable s = box(40, 10, 20).rotate(x: 33).rotate(y: -20).rotate(z: 71).move(x: 40, y: -12, z: 9).aligned;
            immutable size = s.bbox.size;
            assert(abs(size.x / 1.mm - 40) < 1e-3 && abs(size.y / 1.mm - 20) < 1e-3 && abs(size.z / 1.mm - 10) < 1e-3, "size");
            assert(abs(s.bbox.min.z / 1.mm) < 1e-3 && abs(s.bbox.center.x / 1.mm) < 1e-3, "placed");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    // a block with a hole through it and a pocket in its side: filled from its shadows, both are gone
    import std.math : abs;
    import hackerscad.lang.convex : shapeOfShadows;
    import hackerscad.lang.errors : Span;
    make();
    auto block = kernel.box(20, 20, 10);
    auto bb = kernel.bbox(block);
    auto c = bb.center;
    // each moved so that its box starts where asked, wherever the kernel makes it
    auto at(Brep s, Vec3 lo) => kernel.translate(s, lo - kernel.bbox(s).min);
    auto hole = at(kernel.cylinder(3, 30), Vec3(c.x - 3, c.y - 3, bb.min.z - 10));
    auto pocket = at(kernel.box(4, 4, 4), Vec3(bb.min.x - 1, c.y - 2, c.z - 2));
    auto part = kernel.boolean(kernel.boolean(block, hole, BoolOp.cut), pocket, BoolOp.cut);
    auto filled = shapeOfShadows(kernel, part, Span("t.hcad"));
    // 0.02 inside on every side
    assert(abs(kernel.volume(filled) - 19.96 * 19.96 * 9.96) < 1, format("the part filled: %s mm³", kernel.volume(filled)));
    auto voids = kernel.boolean(filled, part, BoolOp.cut);
    assert(abs(kernel.volume(voids) - (PI * 9 * 10 + 3 * 4 * 4)) < 2, "its voids: the hole and the pocket inside the block");
}

unittest
{
    // tapered regions that grow into each other are one solid, not counted twice
    auto r = runModel(q{
        import std.math;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable a = rect(10, 10), b = rect(10, 10).move(x: 12);
            immutable both = (a + b).extrude(10, taper: -10.deg);
            immutable apart = a.extrude(10, taper: -10.deg) + b.extrude(10, taper: -10.deg);
            assert(abs(both.volume / 1.mm ^^ 3 - apart.volume / 1.mm ^^ 3) < 1e-3, "overlap counted once");
            assert(both.pieces.length == 1 && both.isValid, "one solid");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    // a circle shrinking to its centre before the top would be an hourglass
    foreach (src; ["circle(r: 3).extrude(5.mm, taper: 60.deg)",
            "box(20, 20, 10).cut(circle(r: 3), on: faces.top, depth: 5.mm, taper: 60.deg)",
            "box(20, 20, 10).cut(circle(r: 3), on: faces.top, through: true, taper: 30.deg)"])
    {
        immutable d = error("@part Solid p() => " ~ src ~ ";");
        assert(d.message.canFind("closes up"), src ~ ": " ~ d.message);
    }
}

unittest
{
    // offsets of profiles: regions grown into each other merge; a narrow
    // neck that closes up leaves the islands on either side
    auto r = runModel(q{
        import std.math;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable mm2 = 1.mm ^^ 2;
            // two 14 mm squares rounded by 2, overlapping on a 2 mm strip with rounded ends
            immutable square = 196 - 4 * (4 - PI), lens = 2 * (10 + 2 * (PI - (sqrt(3.0) / 2 + PI / 3)));
            immutable grown = (rect(10, 10) + rect(10, 10).move(x: 12)).offset(2.mm);
            assert(abs(grown.area / mm2 - (2 * square - lens)) < 1e-3, "merged");
            assert(grown.extrude(1).pieces.length == 1, "one region");
            // two 7 mm squares, each with a little bulge where the neck met it
            immutable bulge = 2 * (1.5 - (sqrt(1.25) / 2 + 1.125 * asin(2.0 / 3) / 1.deg * PI / 180));
            immutable shrunk = (rect(10, 10) + rect(10, 10).move(x: 20) + rect(12, 2).move(x: 10)).offset(-1.5.mm);
            assert(abs(shrunk.area / mm2 - (98 + 2 * bulge)) < 1e-3, "islands");
            assert(shrunk.extrude(1).pieces.length == 2, "two islands");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    // rounding profiles: holes and text too, every corner; a radius that
    // does not fit is an error naming the corner
    auto r = runModel(q{
        import std.math;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable mm2 = 1.mm ^^ 2, corner = 1 - PI / 4;
            assert(abs((rect(20, 20) - circle(r: 3)).round(1).area / mm2 - (400 - 4 * corner - 9 * PI)) < 1e-6, "round hole");
            // the hole's corners filled as much as the outline's are cut
            immutable framed = (rect(20, 20) - rect(5, 5)).round(1);
            assert(abs(framed.area / mm2 - 375) < 1e-6 && framed.extrude(1).isValid, "square hole");
            immutable label = text("Hello", size: 10.mm);
            immutable soft = label.round(0.15.mm);
            assert(abs(soft.area / mm2 - label.area / mm2) > 1e-3 && soft.extrude(1).isValid, "text");
            assert(abs(rect(10, 10).round(5).area / mm2 - 25 * PI) < 1e-6, "a circle");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error("@part Solid p() => rect(10, 10).round(6.mm).extrude(1);").message.canFind("too large for the corner at"));
    assert(error("@part Solid p() => rect(10, 10).round(100.mm).extrude(1);").message.canFind("too large"));
    assert(error("@part Solid p() => rect(10, 10).round(0).extrude(1);").message.canFind("greater than 0"));
    assert(error("@part Solid p() => rect(10, 10).round(-2.mm).extrude(1);").message.canFind("greater than 0"));
}

unittest
{
    mixin(slowTest);
    // a twisted sweep along a curve keeps the volume of the untwisted one:
    // the area of the profile times the length of the path
    auto r = runModel(q{
        import std.math;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable mm3 = 1.mm ^^ 3, coil = helix(r: 10.mm, pitch: 5.mm, height: 20.mm);
            immutable length = 4 * sqrt((20 * PI) ^^ 2 + 25.0);
            assert(abs(circle(r: 1.mm).sweep(coil).volume / mm3 - PI * length) < 0.01, "plain");
            assert(abs(circle(r: 1.mm).sweep(coil, twist: 90.deg).volume / mm3 - PI * length) < 0.01, "circle");
            assert(abs(rect(2, 1).sweep(coil, twist: 90.deg).volume / mm3 - 2 * length) < 0.01, "rectangle");
            assert(abs(rect(4, 4).sweep(coil, twist: 1.deg).volume / mm3 - 16 * length) < 0.05, "a little");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    // revolve: an angle up to a full turn, an axis in the profile's plane, the profile on one side of it
    assert(error("@part Solid p() => rect(10, 10).move(x: 10).revolve(angle: 400.deg);").message.canFind("at most 360°"));
    assert(error("@part Solid p() => rect(10, 10).move(x: 10).revolve(angle: 0.deg);").message.canFind("more than 0°"));
    assert(error("@part Solid p() => rect(10, 10).move(y: 10).revolve(axis: Z);").message.canFind("profile's plane"));
    assert(error("@part Solid p() => rect(10, 10).revolve();").message.canFind("crosses the axis"));
    assert(error("@part Solid p() => rect(10, 10).move(x: 4.mm).revolve();").message.canFind("crosses the axis"));
    auto r = runModel("@part Solid touching() => rect(10, 10).move(x: 5.mm).revolve();\n"
        ~ "@part Solid back() => rect(10, 10).move(x: 10).revolve(angle: -90.deg);");
    assert(isClose(partVolume(r, "touching"), PI * 100 * 10, 1e-6));
    assert(isClose(partVolume(r, "back"), PI * (225 - 25) * 10 / 4, 1e-6));
}

unittest
{
    // solids offset by nothing stay as they are; teardrops up to 90°; text of a size
    auto r = runModel(q{
        import std.math;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            assert(abs(box(10, 10, 10).offset(0).volume / 1.mm ^^ 3 - 1000) < 1e-9, "offset 0");
            assert(abs(box(10, 10, 10).offset(1e-7).volume / 1.mm ^^ 3 - 1000) < 1e-9, "offset almost 0");
            // at 90° the sides meet on the circle: no point left
            assert(abs(teardrop(r: 5, angle: 90.deg).area / 1.mm ^^ 2 - 25 * PI) < 1e-6, "teardrop 90°");
            assert(abs(teardrop(r: 5, angle: 90.deg, flat: true).area / 1.mm ^^ 2 - 25 * PI) < 1e-6, "flat 90°");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error("@part Solid p() => teardrop(r: 5, angle: 91.deg).extrude(1);").message.canFind("between 3° and 90°"));
    foreach (size; ["0", "-2", "1e-6"])
        assert(error(`@part Solid p() => text("A", size: ` ~ size ~ `).extrude(1);`).message.canFind("text size"), size);
}

unittest
{
    // @parts: a part per separate body of a Solid, or per element of a Solid[];
    // numbered when there are several, in the order of .pieces
    auto r = runModel(q{
        immutable apart = box(4, 4, 4) + box(4, 4, 4).move(x: 10) + box(4, 4, 4).move(x: 20);
        @parts("Red Pop", varied: true) Solid cubes() => apart;
        @parts Solid[] two() => [box(1, 1, 1).move(y: 30), box(2, 2, 2).move(y: 40)];
        @parts Solid lone() => box(1, 1, 1).move(z: 50);
        @part Solid whole() => apart.move(z: 70);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    import std.algorithm : all, canFind;
    auto names = r.parts.map!(p => p.name).array;
    assert(names == ["cubes1", "cubes2", "cubes3", "two1", "two2", "lone", "whole"], names.join(" "));
    assert(r.parts.all!(p => names.canFind(p.name)) && r.parts[2].fn == "cubes" && r.parts[5].fn == "lone");
    // varied: the first in the given colour, the others different; without it all the same
    assert(r.parts[0].rgb == 0xFF8A82 && r.parts[1].rgb != r.parts[0].rgb && r.parts[2].rgb != r.parts[1].rgb);
    assert(r.parts[3].rgb == r.parts[4].rgb);
    // a piece coloured on its own keeps its colour, the others take @parts's
    auto own = runModel(q{
        @parts("Red Pop")
        Solid[] two()
        {
            auto pieces = [box(1, 1, 1), box(1, 1, 1).move(x: 5)];
            pieces[1] = pieces[1].color("#112233");
            return pieces;
        }
    });
    assert((own.parts[0].rgb & 0xFFFFFF) == 0xFF8A82 && (own.parts[1].rgb & 0xFFFFFF) == 0x112233);
    assert(isClose(partVolume(r, "cubes2"), 64, 1e-6) && isClose(partVolume(r, "whole"), 192, 1e-6));
    // @part on a list points at @parts; @parts on what is not solid says what it takes
    assert(error("@part Solid[] p() => [box(1, 1, 1)];").message.canFind("@parts makes a part of each"));
    assert(error("@parts int p() => 3;").message.canFind("a Solid (a part per separate body)"));
    assert(error("@part(varied: true) Solid p() => box(1, 1, 1);").message.canFind("@part takes"));
}

unittest
{
    // a list of solids says which are where
    expectOut(q{
        auto ps = (box(2, 2, 2) + box(2, 2, 2).move(x: 10) + box(4, 4, 4).move(z: 10)).pieces;
        auto p = plane(origin: vec(5.mm, 0.mm, 0.mm), normal: X);
        writeln(ps.length, " ", ps.above(p).length, " ", ps.below(p).length, " ", ps.crossing(XY).length);
        writeln(ps.largest.volume, " ", ps.smallest.volume, " ", ps.top.centroid.z, " ", ps.right.centroid.x);
        writeln(ps.nearest(vec(11.mm, 0.mm, 0.mm)).centroid.x, " ", ps.left.centroid.x);
    }, "3 1 2 0\n64 mm^3 8 mm^3 12 mm 10 mm\n10 mm 0 mm");
    assert(errorIn("auto x = box(1, 1, 1).pieces[0 .. 0].largest;").message.canFind("empty list"));
}

unittest
{
    // noise: repeatable, in range, seeded; loopNoise closes on itself; an
    // outline's points: evenly round, normals outward, round corners kept clear
    expectOut(q{
        writeln(noise(1.37, 2.71, 0.43, seed: 2) == noise(1.37, 2.71, 0.43, seed: 2), " ",
            noise(1.37, 2.71, 0.43, seed: 2) != noise(1.37, 2.71, 0.43, seed: 3), " ",
            abs(noise(0.3, 0.7, 0.1)) <= 1);
        writeln(abs(loopNoise(0, 2, bumps: 6) - loopNoise(1, 2, bumps: 6)) < 1e-9);
        auto o = rect(40.mm, 20.mm).outline(120);
        writeln(o.length, " ", o[0].around, " ", o[60].around);
        // the first point faces +X (the middle of the right side), its normal outwards
        writeln(o[0].at.x, " ", o[0].normal.x);
        writeln(polygon([vec(0, 0), vec(10, 0), vec(10, 10), vec(0, 10)], smooth: true).area > 0.mm ^^ 2);
    }, "true true true\ntrue\n120 0 0.5\n20 mm 1\ntrue", "import std.math;");
    // pushed in along the normals, a sharp box stays clear with round: as deep as the push
    auto r = runModel(q{
        Profile ring(Length z) {
            Vec2[] pts;
            foreach (q; rect(40.mm, 30.mm).outline(120, round: 2.mm))
                pts ~= q.at - q.normal * 1.5.mm;
            return polygon(pts, smooth: true).move(z: z);
        }
        @part Solid p() => loft([ring(0.mm), ring(10.mm), ring(20.mm)]);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    // frames along a path: evenly spaced, Z along it, X and Y square; on a
    // straight line they do not turn; a closed path's last frame is its first
    expectOut(q{
        auto f = path([vec(0.mm, 0.mm, 0.mm), vec(0.mm, 0.mm, 40.mm)]).frames(5);
        writeln(f.length, " ", f[1].origin.z, " ", f[4].z.z, " ", f[0].x == f[4].x);
        auto ring = spline([vec(10.mm, 0.mm, 0.mm), vec(0.mm, 10.mm, 0.mm), vec(-10.mm, 0.mm, 0.mm),
            vec(0.mm, -10.mm, 0.mm)], closed: true).frames(30);
        writeln(abs(ring[0].x.dot(ring[29].x) - 1) < 1e-6, " ", abs(ring[7].x.dot(ring[7].z)) < 1e-9);
    }, "5 10 mm 1 true\ntrue true", "import std.math;");
}

unittest
{
    // a loft through rings of points: one smooth closed surface, the ends flat;
    // a cylinder's rings give a cylinder's volume; rings of different counts are refused
    auto r = runModel(q{
        import std.math;
        Vec3[] ring(Length z) {
            Vec3[] pts;
            foreach (i; 0 .. 48)
                pts ~= vec(10.mm * cos(i * 360.deg / 48), 10.mm * sin(i * 360.deg / 48), z);
            return pts;
        }
        @part Solid c() {
            Vec3[][] rings;
            foreach (k; 0 .. 6)
                rings ~= [ring(4.mm * k)];
            return loft(rings);
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(isClose(partVolume(r, "c"), PI * 100 * 20, 1e-3), "a cylinder through rings");
    assert(error("@part Solid p() => loft([[vec(0, 0, 0), vec(1, 0, 0), vec(0, 1, 0)], "
        ~ "[vec(0, 0, 1), vec(1, 0, 1), vec(0, 1, 1), vec(1, 1, 1)]]);").message.canFind("the same count"));
}

unittest
{
    // fit: "sides" sizes a regular polygon by the circle its sides touch: a hexagon 13 mm across the
    // flats, in a sketch and as a profile, and a pentagon; fully constrained, the sizes are dimensions
    import std.math : tan, PI;
    auto r = runModel(`import std.shapes;
@part Solid a()
{
    auto s = sketch();
    auto c = s.point(0, 0, fixed: true);
    s.horizontal(s.polygon(c, 6, d: 13.mm, fit: "sides")[0]);
    writeln(s.dof);
    return s.profile.extrude(1.mm);
}
@part Solid b() => polygon(6, d: 13.mm, fit: "sides").extrude(1.mm);
@part Solid p()
{
    auto s = sketch();
    s.polygon(s.point(0, 0, fixed: true), 5, r: 10.mm, fit: "sides", angle: 90.deg);
    return s.profile.extrude(1.mm);
}
`);
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error && d.severity != Severity.warning, d.message);
    assert(r.log[0].text == "0", r.log[0].text);
    immutable hexagon = 6 * 6.5 ^^ 2 * tan(PI / 6);
    assert(isClose(partVolume(r, "a"), hexagon, 1e-6) && isClose(partVolume(r, "b"), hexagon, 1e-6));
    assert(isClose(partVolume(r, "p"), 5 * 10.0 ^^ 2 * tan(PI / 5), 1e-6));
    import std.algorithm : canFind;
    auto e = errorIn(`auto p = polygon(6, d: 13.mm, fit: "flats");`, "import std.shapes;");
    assert(e.message.canFind("fit is"), e.message);
}

unittest
{
    // on and tangent with a whole shape: a hexagon in a circle, an octagon and a square round one, a
    // rectangle in one; each fully constrained, with the area its geometry gives
    import std.math : sin, tan, PI;
    auto r = runModel(`import std.shapes;
@part Solid hex()
{
    auto s = sketch();
    auto c = s.point(0, 0, fixed: true);
    auto circ = s.circle(c, d: 30.mm, construction: true);
    auto h = s.polygon(c, 6);
    s.on(h, circ);
    s.horizontal(h[0]);
    writeln(s.dof);
    return s.profile.extrude(1.mm);
}
@part Solid oct()
{
    auto s = sketch();
    auto c = s.point(0, 0, fixed: true);
    auto circ = s.circle(c, d: 20.mm, construction: true);
    auto o = s.polygon(c, 8);
    s.tangent(o, circ);
    s.horizontal(o[0]);
    writeln(s.dof);
    return s.profile.extrude(1.mm);
}
@part Solid square()
{
    auto s = sketch();
    auto circ = s.circle(s.point(0, 0, fixed: true), d: 20.mm, construction: true);
    s.tangent(s.rect(vec(-12, -12), vec(11, 11)), circ);
    writeln(s.dof);
    return s.profile.extrude(1.mm);
}
@part Solid inside()
{
    auto s = sketch();
    auto circ = s.circle(s.point(0, 0, fixed: true), d: 30.mm, construction: true);
    auto q = s.rect(vec(-12, -8), vec(11, 9));
    s.on(q, circ);
    writeln(s.dof);
    s.length(q[0], 24.mm);
    writeln(s.dof);
    return s.profile.extrude(1.mm);
}
`);
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error && d.severity != Severity.warning, d.message);
    // the rectangle in the circle keeps its proportion free until a side is given
    assert(r.log.map!(l => l.text).array == ["0", "0", "0", "1", "0"], r.log.map!(l => l.text).join(","));
    assert(isClose(partVolume(r, "hex"), 6 * 15.0 ^^ 2 * sin(PI / 3) / 2, 1e-6));
    assert(isClose(partVolume(r, "oct"), 8 * 10.0 ^^ 2 * tan(PI / 8), 1e-6));
    assert(isClose(partVolume(r, "square"), 400, 1e-6) && isClose(partVolume(r, "inside"), 24 * 18, 1e-6));
}

unittest
{
    // a rectangle turned by an angle, and one free to turn laid along a slanted line: fully constrained,
    // the sizes they were given, the slanted one's side along the line
    auto r = runModel(`import std.shapes;
@part Solid a()
{
    auto s = sketch();
    s.rect(center: s.point(0, 0, fixed: true), w: 30.mm, h: 20.mm, angle: 25.deg);
    writeln(s.dof);
    auto f = s.point(40, -10, fixed: true), g = s.point(80, 10, fixed: true);
    auto slanted = s.line(f, g, construction: true);
    auto q = s.rect(center: s.point(60, 10), w: 20.mm, h: 10.mm, angle: "free");
    writeln(s.dof);
    s.parallel(q[0], slanted);
    s.on(q[0].start, slanted);
    s.distance(f, q[0].start, 5.mm);
    writeln(s.dof);
    writeln(q[0].end.y - q[0].start.y > 0.mm);
    return s.profile.extrude(1.mm);
}
@part Solid b()
{
    auto s = sketch();
    auto r = s.rect(s.point(0, 0, fixed: true), w: 30.mm, h: 20.mm);
    writeln(s.dof, " ", r[1].end.x, " ", r[1].end.y);
    return s.profile.extrude(1.mm);
}
`);
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error && d.severity != Severity.warning, d.message);
    assert(r.log.map!(l => l.text).array == ["0", "3", "0", "true", "0 30 mm 20 mm"], r.log.map!(l => l.text).join(","));
    assert(isClose(partVolume(r, "a"), 600 + 200, 1e-6));
    import std.algorithm : canFind;
    auto e = errorIn(`auto s = sketch(); s.rect(center: s.point(0, 0), angle: "loose");`, "import std.shapes;");
    assert(e.message.canFind("free"), e.message);
}


unittest
{
    // the shapes are one-shape sketches with everything given: a profile and the sketch's shape
    // of the same sizes are the same outline, by every form
    immutable decls = q{
        import std.math;
        immutable mm2 = 1.mm ^^ 2;
        void same(Profile a, Profile b, string what)
        {
            assert(abs(a.area - b.area) / mm2 < 1e-6, what ~ ": area");
            assert(abs((a & b).area - a.area) / mm2 < 1e-4, what ~ ": overlap");
            assert((a.bbox.center - b.bbox.center).length / 1.mm < 1e-6, what ~ ": place");
        }
    };
    output(q{
        auto s1 = sketch();
        s1.rect(center: s1.point(0, 0, fixed: true), w: 40.mm, h: 20.mm, corner: 3.mm);
        same(rect(40.mm, 20.mm, corner: 3.mm), s1.profile, "rect");
        assert(abs(rect(40.mm, 20.mm, corner: 3.mm).area / mm2 - (800 - (4 - PI) * 9)) < 1e-6, "corner");
        same(rect(40.mm, 20.mm).round(3.mm), rect(40.mm, 20.mm, corner: 3.mm), "round");
        same(rect(vec(0, 0), vec(40, 20)), rect(center: vec(20, 10), w: 40.mm, h: 20.mm), "corners");
        same(rect(vec(0, 0), w: 40.mm, h: 20.mm), rect(vec(40, 20), vec(0, 0)), "a corner and the size");
        assert(abs(rect(20.mm).area / mm2 - 400) < 1e-6, "square");
        same(rect(40.mm, 20.mm, angle: 90.deg), rect(20.mm, 40.mm), "turned");
        auto s2 = sketch();
        s2.rect(s2.point(5, 5, fixed: true), s2.point(45, 25, fixed: true));
        same(rect(vec(5, 5), vec(45, 25)), s2.profile, "sketch corners");
        auto s3 = sketch();
        s3.circle(s3.point(10, 5, fixed: true), d: 8.mm);
        same(circle(vec(10, 5), d: 8.mm), s3.profile, "circle");
        same(circle(center: vec(10, 5), r: 4.mm), circle(d: 8.mm).move(x: 10.mm, y: 5.mm), "circle centre");
        auto s4 = sketch();
        s4.ellipse(s4.point(0, 0, fixed: true), rx: 15.mm, ry: 8.mm, angle: 30.deg);
        same(ellipse(15.mm, 8.mm, angle: 30.deg), s4.profile, "ellipse");
        same(ellipse(vec(3, 4), rx: 15.mm, ry: 8.mm), ellipse(15.mm, 8.mm).move(x: 3.mm, y: 4.mm), "ellipse centre");
        auto s5 = sketch();
        s5.polygon(s5.point(0, 0, fixed: true), 6, d: 13.mm, fit: "sides", angle: 0.deg);
        same(polygon(6, d: 13.mm, fit: "sides", angle: 0.deg), s5.profile, "hexagon");
        // without an angle the first side lies at the bottom: a square stands on a side
        assert(abs(polygon(4, r: 10.mm).bbox.size.x / 1.mm - sqrt(200.0)) < 1e-6, "flat square");
        same(polygon(vec(10, 0), 3, r: 5.mm), polygon(3, r: 5.mm).move(x: 10.mm), "polygon centre");
        auto s6 = sketch();
        s6.polygon([vec(0, 0), vec(30, 0), vec(0, 20)]);
        same(polygon([vec(0, 0), vec(30, 0), vec(0, 20)]), s6.profile, "through points");
        auto s7 = sketch();
        s7.slot(s7.point(0, 0, fixed: true), s7.point(20, 10, fixed: true), w: 6.mm);
        same(slot(vec(0, 0), vec(20, 10), w: 6.mm), s7.profile, "slot between centres");
        assert(abs(slot(30.mm, 10.mm).area / mm2 - (200 + 25 * PI)) < 1e-6, "slot");
        same(slot(30.mm, 10.mm, angle: 90.deg), slot(vec(0, -10), vec(0, 10), w: 10.mm), "slot turned");
        auto s8 = sketch();
        s8.slot(30.mm, 10.mm, center: s8.point(5, 5, fixed: true), angle: 20.deg);
        same(slot(30.mm, 10.mm, center: vec(5, 5), angle: 20.deg), s8.profile, "slot by its length");
        assert(s8.dof == 0, "slot dof");
        auto s9 = sketch();
        s9.teardrop(s9.point(0, 0, fixed: true), d: 10.mm);
        same(teardrop(d: 10.mm), s9.profile, "teardrop");
        assert(s9.dof == 0, "teardrop dof");
        auto s10 = sketch();
        s10.teardrop(s10.point(4, 2, fixed: true), r: 5.mm, angle: 30.deg, flat: true);
        same(teardrop(vec(4, 2), r: 5.mm, angle: 30.deg, flat: true), s10.profile, "flat teardrop");
        assert(s10.dof == 0, "flat teardrop dof");
        same(teardrop(r: 5.mm, angle: 30.deg, flat: true), teardrop(r: 5.mm, angle: 30.deg) & rect(20.mm, 10.mm),
            "flat: cut at the top");
        // a sketch's shape without its centre stands round a new point at the origin
        auto s11 = sketch();
        s11.circle(d: 8.mm);
        assert(s11.dof == 2, "free centre");
        same(circle(d: 8.mm), s11.profile, "circle at the origin");
    }, decls);

    // profiles move, turn, scale and mirror like solids
    output(q{
        immutable p = rect(40.mm, 20.mm) - circle(vec(10, 0), d: 6.mm);
        assert(abs(p.rotate(30.deg).area - p.area) / mm2 < 1e-6, "rotate");
        assert(abs(p.rotate(z: 30).area - p.area) / mm2 < 1e-6, "rotate z");
        assert(abs(p.mirror(X).area - p.area) / mm2 < 1e-6, "mirror");
        assert((p.mirror(X) & circle(vec(10, 0), d: 6.mm)).area / mm2 > 28, "mirrored: the hole on the other side");
        assert(abs(p.scale(2).area - 4 * p.area) / mm2 < 1e-6, "scale");
        assert(abs(p.scale(x: 2, y: 3).area / p.area - 6) < 1e-6, "scale x, y");
        assert(abs(p.move(x: 5.mm, y: 2.mm).bbox.center.x / 1.mm - 5) < 1e-6, "move");
        // a mirrored or half-turned profile (its outline running the other way) fuses into one with another:
        // one piece extruded, one outline rounded
        immutable arm = rect(vec(52.mm, -2.mm), vec(64.mm, 18.mm));
        immutable bar = rect(vec(-64.mm, 12.mm), vec(64.mm, 18.mm));
        foreach (u; [bar + arm.mirror(X), arm.mirror(X) + bar, bar + arm.mirror(Y).move(y: 16.mm),
            bar + arm.rotate(x: 180).move(y: 16.mm), bar + arm.mirror(Z)])
        {
            assert(abs(u.area / mm2 - 936) < 1e-6, "fused area");
            assert(u.extrude(1.mm).pieces.length == 1 && u.round(2.mm).extrude(1.mm).pieces.length == 1, "one piece");
        }
        // and offset alike: the outline grows, the holes shrink, whichever way the outline runs (mirrored,
        // half-turned, drawn clockwise)
        immutable sym = rect(20.mm, 10.mm).round(2.mm) - circle(vec(5, 0), d: 3.mm) - circle(vec(-5, 0), d: 3.mm);
        immutable clockwise = polygon([vec(-10, -5), vec(-10, 5), vec(10, 5), vec(10, -5)]).round(2.mm)
            - circle(vec(5, 0), d: 3.mm) - circle(vec(-5, 0), d: 3.mm);
        foreach (d; [1.mm, -1.mm])
            foreach (q; [sym.mirror(X), sym.rotate(x: 180), clockwise, sym.mirror(X).mirror(Y)])
                assert(abs((q.offset(d).area - sym.offset(d).area) / mm2) < 1e-3, "offset");
    }, decls);

    import std.algorithm : canFind;
    assert(errorIn(`auto p = circle();`).message.canFind("'r' (radius) or 'd'"));
    assert(errorIn(`auto p = slot(30.mm);`).message.canFind("needs w:"));
    assert(errorIn(`auto p = rect(10.mm, angle: "free");`).message.canFind("\"free\" is for sketches"));
    assert(errorIn(`auto p = teardrop(d: 5.mm, angle: 95.deg);`).message.canFind("between 3° and 90°"));
    assert(errorIn(`auto s = sketch(); s.polygon([vec(0, 0), vec(9, 0), vec(0, 9)], smooth: true);`)
        .message.canFind("not sketch geometry"));
    assert(errorIn(`auto p = slot(vec(0, 0), vec(9, 0), w: 2.mm, length: 9.mm);`).message.canFind("by its length"));
}

unittest
{
    // metamorphic: each 2D operation gives on an input mirrored, turned or drawn clockwise what it gives on the
    // input drawn as usual (its outlines counter-clockwise): the same area or volume, outlines, holes and bodies,
    // a valid solid. Mirrored, turned over or drawn clockwise, an outline runs the other way, which unions,
    // offsets and the rest once read wrong (822c967): a table of operations by transforms, on three inputs
    mixin(slowTest);
    import std.range : retro;
    alias Loop = double[2][];
    struct Input
    {
        string name;
        const(Loop)[] outlines, holes;
    }
    immutable Loop ell = [[-15, -10], [15, -10], [15, -2], [-5, -2], [-5, 12], [-15, 12]];
    immutable Loop hole = [[-12, 5], [-8, 5], [-8, 9], [-12, 9]];
    const inputs = [
        Input("an L", [ell], []),
        Input("an L with a hole", [ell], [hole]),
        // three outlines, the hole in one
        Input("three pieces", [[[-15, -10], [4, -10], [4, -2], [-5, -2], [-5, 12], [-15, 12]],
            [[6, -10], [15, -10], [15, -2], [6, -2]], [[9, 4], [13, 4], [13, 8], [9, 8]]], [hole]),
    ];
    // the other operand of the booleans, the same mirrored or turned: a cross centred on the origin, crossing
    // the L (the difference leaves three pieces of it)
    immutable Loop cross = [[-2, -20], [2, -20], [2, -2], [20, -2], [20, 2], [2, 2], [2, 20], [-2, 20], [-2, 2],
        [-20, 2], [-20, -2], [-2, -2]];

    // how a transform moves a point (x, y) to (m[0] x + m[1] y, m[2] x + m[3] y), and the method that does it
    struct Transform
    {
        string name, method;
        double[4] m;
        bool clockwise;   // no method: the same points, drawn the other way round
    }
    const transforms = [
        Transform("as drawn", "", [1, 0, 0, 1]),
        Transform("mirrored in X", ".mirror(X)", [-1, 0, 0, 1]),
        Transform("mirrored in Y", ".mirror(Y)", [1, 0, 0, -1]),
        Transform("mirrored in X and Y", ".mirror(X).mirror(Y)", [-1, 0, 0, -1]),
        Transform("turned 180°", ".rotate(180.deg)", [-1, 0, 0, -1]),
        Transform("turned 90°", ".rotate(90.deg)", [0, -1, 1, 0]),
        Transform("turned over", ".rotate(x: 180)", [1, 0, 0, -1]),
        Transform("clockwise", "", [1, 0, 0, 1], true),
    ];

    // %1$s the input, %2$s the cross; a profile is extruded 1 mm to measure it. Where the result lies counts
    // for a revolve: it is compared with the input drawn where the transform puts it
    struct Op
    {
        string name, code;
        bool binary, flat, sketch, placed;
    }
    const ops = [
        Op("union", "%1$s + %2$s", true, true),
        Op("union the other way", "%2$s + %1$s", true, true),
        Op("difference", "%1$s - %2$s", true, true),
        Op("difference the other way", "%2$s - %1$s", true, true),
        Op("intersection", "%1$s & %2$s", true, true),
        Op("grown", "%1$s.offset(1.mm)", false, true),
        Op("shrunk", "%1$s.offset(-1.mm)", false, true),
        Op("rounded", "%1$s.round(1.mm)", false, true),
        Op("filleted", "%1$s.extrude(5.mm).fillet(edges, r: 0.5.mm)"),
        Op("filleted on top", "%1$s.extrude(5.mm).fillet(edges.of(faces.top), r: 1.mm)"),
        Op("revolved", "%1$s.move(x: 40.mm).revolve()", false, false, false, true),
        Op("revolved round X", "%1$s.move(y: 40.mm).revolve(axis: X, angle: 90.deg)", false, false, false, true),
        // drawn in a sketch, through the transformed points in their order
        Op("a sketch", "%1$s", false, true, true),
        Op("a sketch less the cross", "%1$s - %2$s", true, true, true),
    ];

    string apply(const Op op, string a, string b) => op.binary ? format(op.code, a, b) : format(op.code, a);
    string loops(const Loop[] ls, const double[4] m, bool reverse)
    {
        string[] r;
        foreach (l; ls)
        {
            string[] pts;
            foreach (p; l)
                pts ~= format("vec(%g, %g)", m[0] * p[0] + m[1] * p[1], m[2] * p[0] + m[3] * p[1]);
            if (reverse)
                pts = pts.retro.array;
            r ~= "[" ~ pts.join(", ") ~ "]";
        }
        return "[" ~ r.join(", ") ~ "]";
    }
    // the input moved by m as a profile drawn anew, counter-clockwise (or the other way round)
    string drawn(const Input i, const double[4] m, bool reverse)
        => format("drawn(%s, %d)", loops(i.outlines ~ i.holes, m, reverse), i.outlines.length);
    immutable double[4] same = [1, 0, 0, 1];
    bool mirrors(const double[4] m) => m[0] * m[3] - m[1] * m[2] < 0;

    string src = `import std.shapes;
Profile drawn(Vec[][] loops, int outlines)
{
    auto p = polygon(loops[0]);
    foreach (i; 1 .. loops.length)
        p = i < outlines ? p + polygon(loops[i]) : p - polygon(loops[i]);
    return p;
}
Profile sketched(Vec[][] loops)
{
    auto s = sketch();
    foreach (l; loops)
    {
        SketchPoint[] q;
        foreach (v; l)
            q ~= s.point(v.x, v.y, fixed: true);
        s.polygon(q);
    }
    return s.profile;
}
`;
    // a part per case, on a line of its own, named by it: the base (the input as drawn), each transform, and for
    // a revolve the input drawn anew where the transform puts it, to compare with
    struct Case
    {
        string label;
        size_t reference;
    }
    Case[size_t] cases;
    size_t parts;
    size_t part(string code, bool flat, string label)
    {
        src ~= format("@part Solid c%d() => %s;   // %s\n", parts, flat ? "(" ~ code ~ ").extrude(1.mm)" : code, label);
        return parts++;
    }
    immutable b0 = format("polygon(%s[0])", loops([cross], same, false));
    foreach (op; ops)
        foreach (input; inputs)
        {
            immutable base = part(apply(op, drawn(input, same, false), b0), op.flat, op.name ~ ", " ~ input.name);
            foreach (t; transforms)
            {
                if (t.name == "as drawn" && !op.sketch)
                    continue;
                // the input transformed by its method, drawn clockwise, or sketched through the moved points
                immutable a = op.sketch ? format("sketched(%s)", loops(input.outlines ~ input.holes, t.m, t.clockwise))
                    : t.clockwise ? drawn(input, same, true) : drawn(input, same, false) ~ t.method;
                immutable tb = t.clockwise ? format("polygon(%s[0])", loops([cross], same, true)) : b0 ~ t.method;
                immutable reference = op.placed ? part(apply(op, drawn(input, t.m, mirrors(t.m)), b0), op.flat,
                    op.name ~ ", " ~ input.name ~ " drawn " ~ t.name) : base;
                // with the cross as drawn, and transformed too
                foreach (b; op.binary && tb != b0 ? [b0, tb] : [b0])
                {
                    immutable label = format("%s, %s %s%s", op.name, input.name, t.name, b == b0 ? "" : ", the cross too");
                    cases[part(apply(op, a, b), op.flat, label)] = Case(label, reference);
                }
            }
        }

    EvalResult r;
    try
        r = runModel(src);
    catch (HcadError e)
        r.diagnostics ~= e.diag;
    import std.string : splitLines;
    immutable lines = src.splitLines;
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error,
            format("%s\n%s", d.message, d.span.line > 0 && d.span.line <= lines.length ? lines[d.span.line - 1] : ""));
    assert(r.parts.length == parts, format("%d parts of %d", r.parts.length, parts));

    // what must not change: valid, the volume, the bodies, the top faces (one per outline: profiles on each
    // other not fused into one stay two) and their holes
    static struct Measure
    {
        bool valid;
        double volume;
        size_t bodies, tops, holes;

        string toString() const => format("%s, %s mm³, %d bodies, %d top faces, %d holes", valid ? "valid" : "not valid",
            volume, bodies, tops, holes);
    }
    Measure measure(Brep b)
    {
        auto m = Measure(kernel.isValid(b), kernel.volume(b), kernel.solids(b).length);
        immutable top = kernel.bbox(b).max.z;
        foreach (i, f; kernel.faces(b))
            if (f.normal.z > 1 - 1e-9 && abs(f.center.z - top) < 1e-6)
            {
                m.tops++;
                m.holes += kernel.faceLoops(b, cast(int) i, 0.1).length - 1;
            }
        return m;
    }
    auto measures = r.parts.map!(p => measure(p.solid.brep)).array;
    // every case that fails, in the table's order
    import std.algorithm : sort;
    string[] wrong;
    foreach (n; cases.keys.sort)
    {
        immutable c = cases[n], got = measures[n], want = measures[c.reference];
        if (!got.valid || abs(got.volume - want.volume) > 1e-6 * want.volume || got.bodies != want.bodies
            || got.tops != want.tops || got.holes != want.holes)
            wrong ~= format("%s: %s, as drawn %s", c.label, got, want);
    }
    assert(wrong.length == 0, format("%d cases of %d:\n%-(%s\n%)", wrong.length, cases.length, wrong));
}

unittest
{
    // two equal circles in different places are two holes, not "outlines on each other" (the check
    // once mixed x and y); the same circle twice still is an error
    import std.algorithm : canFind;
    auto r = runModel(`import std.shapes;
@part Solid a()
{
    auto s = sketch();
    s.rect(center: s.point(0, 0, fixed: true), w: 60.mm, h: 60.mm);
    s.circle(s.point(12, 0, fixed: true), d: 6.mm);
    s.circle(s.point(0, 12, fixed: true), d: 6.mm);
    return s.profile.extrude(1.mm);
}
`);
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    import std.math : PI;
    assert(isClose(partVolume(r, "a"), 3600 - 2 * PI * 9, 1e-6));
    auto e = errorIn(`auto s = sketch(); s.circle(s.point(0, 0), d: 6.mm); s.circle(s.point(0, 0), d: 6.mm);
auto p = s.profile;`, "import std.shapes;");
    assert(e.message.canFind("on each other"), e.message);
}

unittest
{
    // push and pull: the pieces of a cut spread apart from the plane, each its own way; a solid pulled
    // towards a point; one whose centre is on the reference stays, with a warning
    auto r = runModel(`import std.shapes;
immutable cut = plane(origin: vec(0, 0, 0), normal: X);
@parts Solid[] apart() => box(20, 10, 10).split(cut).push(from: cut, by: 3.mm);
@part Solid near() => box(10, 10, 10).move(y: 50.mm).pull(to: vec(0, 0, 5), by: 10.mm);
@part Solid stays() => box(10, 10, 10).move(x: 100.mm).push(from: vec(100, 0, 5), by: 4.mm);
`);
    assert(r.parts.length == 4, format("%s", r.parts.map!(p => p.name).array));
    auto b0 = kernel.bbox(r.parts[0].solid.brep), b1 = kernel.bbox(r.parts[1].solid.brep);
    assert(isClose(b0.max.x, -3, 1e-6) && isClose(b1.min.x, 3, 1e-6), "the halves 3 mm each side of the cut");
    assert(isClose(kernel.bbox(r.parts[2].solid.brep).min.y, 35, 1e-6), "pulled 10 mm towards the origin");
    assert(isClose(kernel.bbox(r.parts[3].solid.brep).min.x, 95, 1e-6), "no direction: stays");
    import std.algorithm : canFind;
    assert(r.diagnostics.canFind!(d => d.severity == Severity.warning && d.message.canFind("no way to go")));
}


unittest
{
    // every name the language offers has its entry in the reference (hcad docs, the cheatsheet, the
    // agents' docs): the built-in functions and methods, a sketch's and a drawing's methods, the
    // members of sketch entities, and the public functions of the libraries
    import std.algorithm : canFind, sort, uniq;
    import std.array : array;
    import hackerscad.lang.reference : reference;
    import hackerscad.lang.value : Kind;
    import std.array : join;
    bool documented(string name) => reference.canFind!(r => r.name == name);
    string[] missing;
    auto it = make();
    foreach (name, v; it.prelude.vars)
        if (v.kind == Kind.builtin && !documented(name))
            missing ~= name;
    // a sketch's methods and properties, each with an entry of its own on Sketch
    import hackerscad.lang.sketchval : SketchVal;
    import hackerscad.lang.errors : Span;
    foreach (name; new SketchVal(it, Span.init, true).memberNames)
        if (!reference.canFind!(r => r.name == name && r.on == "Sketch"))
            missing ~= name ~ " (of a sketch)";
    foreach (name; ["standardViews", "view", "section", "dimension", "note"])
        if (!documented(name))
            missing ~= name;
    // what sketch geometry reads back: an entry for the entity itself, not a namesake of a solid's
    foreach (name; ["x", "y", "pos", "start", "end", "length", "mid", "center", "radius", "rx", "ry", "angle"])
        if (!reference.canFind!(r => r.name == name && r.on.length > 6 && r.on[0 .. 6] == "Sketch"))
            missing ~= name ~ " (of a sketch entity)";
    assert(missing.length == 0, "not in the reference (source/hackerscad/lang/reference.d): "
        ~ missing.sort.uniq.array.join(", "));
}

unittest
{
    // a sketch on a face: its edges as references in the order of a rect's
    // sides (bottom, right, top, left), its profile cut or extruded where it lies
    auto r = runModel(q{
        immutable body = box(40.mm, 30.mm, 10.mm) - cylinder(d: 8.mm, h: 6.mm).move(x: 10.mm, z: -1.mm);
        @part Solid plate()
        {
            auto s = body.sketch(faces.top);
            assert(s.edges.length == 4 && s.dof == 0);
            assert(abs(s.edges[0].mid.y + 15.mm) < 1e-6.mm && abs(s.edges[1].mid.x - 20.mm) < 1e-6.mm);
            auto c = s.circle(s.point(3, 4), d: 6.mm);
            s.distance(c.center, s.edges[0], 5.mm);
            s.distance(c.center, s.edges[1], 5.mm);
            assert(s.dof == 0 && abs(c.center.x - 15.mm) < 1e-6.mm && abs(c.center.y + 10.mm) < 1e-6.mm);
            return body.cut(s.profile, depth: 3.mm);
        }
        @part Solid boss()
        {
            // the blind hole's rim, from under the top, in the sketch on it; a wall's x to the right, y up
            auto s = body.sketch(faces.top);
            auto rim = s.project(edges.filter(e => e.isCircle && e.center.z > 1.mm));
            auto c = s.circle(s.point(0, 0), d: 4.mm);
            s.concentric(c, rim[0]);
            auto w = body.sketch(faces.front);
            w.rect(center: w.origin, w: 4.mm, h: 2.mm);
            return s.profile.extrude(2.mm).move(z: 20.mm) + w.profile.extrude(1.mm);
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(isClose(partVolume(r, "plate"), 40 * 30 * 10 - PI * 16 * 5 - PI * 9 * 3, 1e-6));
    auto boss = r.parts[1].solid;
    assert(isClose(partVolume(r, "boss"), PI * 4 * 2 + 4 * 2 * 1, 1e-6));
    auto bb = kernel.bbox(boss.brep);
    assert(abs(bb.min.y + 16) < 1e-6 && abs(bb.max.z - 32) < 1e-6 && abs(bb.min.x + 2) < 1e-6 && abs(bb.max.x - 12) < 1e-6);
    // on: for a profile that already has its face; profiles of two faces together; edges without a face
    enum base = "immutable body = box(10, 10, 10);\n";
    assert(error(base ~ "@part Solid p() { auto s = body.sketch(faces.top); s.circle(s.origin, d: 2); "
        ~ "return body.cut(s.profile, on: faces.top, depth: 1); }").message.canFind("leave on: out"));
    assert(error(base ~ "@part Solid p() { auto s = body.sketch(faces.top); s.circle(s.origin, d: 2); "
        ~ "auto t = body.sketch(faces.front); t.circle(t.origin, d: 2); return (s.profile + t.profile).extrude(1); }")
        .message.canFind("different faces"));
    assert(error("@part Solid p() { auto s = sketch(); writeln(s.edges); return box(1, 1, 1); }").message.canFind("drawn on a face"));
    assert(error(base ~ "@part Solid p() { auto s = body.sketch(faces.filter(f => f.normal.z > -2)); return body; }")
        .message.canFind("exactly one face"));
}

unittest
{
    // along: X or Y, a prism across that axis; a profile in another plane, extruded from there
    auto r = runModel(q{
        @part Solid ay() => rect(10, 20).extrude(5.mm, along: Y);
        @part Solid ax() => rect(10, 20).extrude(-5.mm, along: X).move(y: 40);
        @part Solid sec() => box(20, 10, 30).section(XZ.offset(2.mm)).extrude(3.mm).move(y: 80);
        @part Solid turned() => rect(10, 20).rotate(x: 90).move(z: 10).extrude(3.mm).move(y: 120);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    Vec3[2] box(string name)
    {
        foreach (p; r.parts)
            if (p.name == name)
            {
                auto b = kernel.bbox(p.solid.brep);
                return [b.min, b.max];
            }
        assert(0, name);
    }
    bool near(Vec3 a, Vec3 b) => (a - b).length < 1e-6;
    assert(near(box("ay")[0], Vec3(-5, 0, -10)) && near(box("ay")[1], Vec3(5, 5, 10)));
    assert(near(box("ax")[0], Vec3(-5, 35, -10)) && near(box("ax")[1], Vec3(0, 45, 10)));
    assert(near(box("sec")[0], Vec3(-10, 82, 0)) && near(box("sec")[1], Vec3(10, 85, 30)));
    assert(near(box("turned")[0], Vec3(-5, 117, 0)) && near(box("turned")[1], Vec3(5, 120, 20)));
    assert(isClose(partVolume(r, "ay"), 1000, 1e-9) && isClose(partVolume(r, "sec"), 1800, 1e-9));
    assert(error("@part Solid p() => rect(1, 1).extrude(1, along: vec(1, 1, 0));").message.canFind("X, Y or Z"));
    assert(error("@part Solid p() { auto s = sketch(XZ); s.circle(s.origin, d: 2); return s.profile.extrude(1, along: Y); }")
        .message.canFind("leave along: out"));
}

unittest
{
    // to! of a quantity: its number in mm (mm², mm³), an angle in degrees
    auto r = runModel(q{
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            assert(8.05.mm.to!double == 8.05 && 1.inch.to!double == 25.4 && 12.mm.to!int == 12);
            assert(30.deg.to!double == 30 && (2.mm * 3.mm).to!double == 6);
            assert(vec(6.25, 31.5).y + 8.mm.to!double / 2 == 35.5);
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error("@part Solid p() { writeln(12.5.mm.to!int); return box(1, 1, 1); }").message.canFind("not an integer"));
    // in a file in inches: the number in inches, as its bare numbers are
    auto inch = runModel("@unit(inch) module m;\n@part Solid p() => box(1, 1, 1);\n"
        ~ "unittest { assert(1.inch.to!double == 1 && 25.4.mm.to!int == 1 && (2.inch * 3.inch).to!double == 6); }");
    foreach (d; inch.diagnostics)
        assert(d.severity != Severity.error, d.message);

}

unittest
{
    mixin(slowTest);
    // a failed fillet names the edges that fail, and the face beside them too
    // narrow for the radius: a roof 1.5 mm wide beside the channel
    enum src = "immutable roof = cylinder(r: 9.5.mm, h: 10.mm, center: true).rotate(y: 90).move(z: 15.mm);\n"
        ~ "immutable channel = box(7, 14, 40).move(z: 15.mm);\n"
        ~ "immutable block = box(20, 30, 40) - box(10, 19, 16).move(z: -1.mm) - (roof & box(10, 19, 30)) - channel;\n"
        ~ "immutable seam = edges.between(faces.from(channel), faces.from(roof)).filter(e => !e.isLine);\n";
    auto d = error(src ~ "@part Solid p() => block.fillet(seam, r: 2.9.mm);");
    assert(d.message.canFind("fillet failed on the curved edge at (3.5, 0, 24.5)"), d.message);
    assert(d.suggestion.canFind("only 1.5 mm wide") && d.suggestion.canFind("smaller than 1.5 mm"), d.suggestion);
    auto r = runModel(src ~ "@part Solid p() => block.fillet(seam, r: 1.4.mm);");
    foreach (x; r.diagnostics)
        assert(x.severity != Severity.error, x.message);
}

