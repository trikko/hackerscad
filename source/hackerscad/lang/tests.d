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
    assert(d.code == Code.undefined && d.suggestion.canFind("did you mean 'w'?") && d.suggestion.canFind("(the @params: w"),
        d.suggestion);
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
    expectOut("writeln(M3.d, \" \", M3.tap);", "3 mm 2.5 mm", "import std.hardware : M3;");
    expectOut("writeln(hw.M4.clearance);", "4.5 mm", "import hw = std.hardware;");
    expectOut("writeln(PI > 3);", "true", "import std.math; import std.algorithm;");
    assert(error("import std.nope;").code == Code.import_);
    assert(error("import std.hardware : M99;").code == Code.import_);
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
        @part Solid f() { return Solid.init + box(1, 1, 1) - Solid.init; }
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
    import std.algorithm : startsWith;
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
        // the block, and the bearing as a reference (its unittest: nothing in the bearing's way)
        assert(r.parts.length == 2 && r.parts[0].name == "pillowBlock" && kernel.isValid(r.parts[0].solid.brep),
            o.to!string);
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
        import std.hardware : M3, M8, screw, nut;
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
    // profiles in two planes do not combine (one of no place is taken into the other's plane)
    assert(error("@part Solid p() => (rect(10, 10).move(z: 1) + rect(10, 10).rotate(x: 90)).extrude(5);").code == Code.type);
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
    assert(r.log[0].text == "Path 94.68 mm long, open Path 1.414 mm long, open", r.log[0].text);

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
    // (what the fillet made, told when it is wrong: round the wave it took 476 mm³ on macOS alone)
    string made(string name)
    {
        auto b = r.parts.filter!(p => p.name == name).front.solid.brep;
        return format("%s: %s mm³, %s faces, %s", name, kernel.volume(b), kernel.faces(b).length, kernel.bbox(b));
    }
    assert(pebbleCut > 20 && pebbleCut < 40, format("%s; %s; %s", pebbleCut, made("flat"), made("round")));
    assert(waveCut > 25 && waveCut < 45, format("%s; %s; %s", waveCut, made("block"), made("soft")));
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
        import std.hardware;
        import std.threads : threadedRod;
        import std.gears;
        import std.hinges : hinge;
        import std.snaps : snapHook;
        import std.enclosures : enclosure, roundedBox;

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
    import std.string : indexOf;
    import std.algorithm : startsWith;
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
    // a thread as the threads library swept it before it was built from its helices: the tooth swept
    // along a 22-turn helix, fused to its core; the long freeform faces that go wrong
    auto rod = runModel(q{
        immutable p = 1.25.mm, h = 0.5413 * p, overlap = 0.1 * p, foot = 0.375 * p + overlap * 0.5774;
        immutable tooth = polygon([vec(overlap, -foot), vec(-h, -p / 16), vec(-h, p / 16), vec(overlap, foot)]);
        @part Solid rod() => (cylinder(d: 8.mm - 2 * h + 0.02.mm, h: 25.mm + 4 * p).move(z: -2 * p)
            + tooth.sweep(helix(d: 8.mm - 2 * h, pitch: p, height: 25.mm + 2 * p), frenet: true).move(z: -p))
            & cylinder(d: 8.02.mm, h: 25.mm);
    }).parts[0].solid.brep;
    immutable area = meshArea(kernel.tessellate(rod, 0.02, 0.25).welded);
    stillBroken(abs(area - kernel.area(rod)) > 0.02 * kernel.area(rod),
        "BRepMesh covering more than the flanks of an M8 × 25 thread swept along its helix (shim.cpp, meshed_badly)");
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
    expectErr(`writeln(Solid.init.centroid);`, "E0410", shapes);
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
    expectErr(`writeln(spurGear(1.mm, 20, 5.mm, backlash: 5.mm));`, "E0600", "import std.gears;");
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
    // tags: on faces and on the solid, kept through moves, cuts, fillets and unions
    expectOut(`auto b = box(40, 30, 10);
        b.faces.top.addTag("lid");
        b.addTag("body");
        b = b.rotate(x: 180) - cylinder(r: 5, h: 30).move(z: -15);
        b = b.fillet(edges.of(faces.tagged("lid")), 1);
        writeln(b.faces.tagged("lid").count, " ", b.faces.tagged("lid").list[0].normal, " ", b.tags);`,
        `1 [0, 0, -1] ["body"]`);
    // two faces merged into one carry both tags; a solid tagged recursive hands them to its faces
    expectOut(`auto a = box(20, 20, 10);
        a.faces.top.addTag("left");
        auto b = box(20, 20, 10).move(x: 20);
        b.faces.top.addTag("right");
        auto boss = cylinder(r: 5, h: 8).move(x: 10, z: 10).addTag("boss", recursive: true);
        auto c = a + b + boss;
        writeln(c.faces.tagged("left").tags, " ", c.faces.tagged("boss").count, " ", c.tags);`,
        `["left", "right"] 2 []`);
    // a tool's tags on the walls it cuts; the solid's own tags left to the first operand
    expectOut(`auto b = box(20, 20, 10).addTag("plate");
        b -= cylinder(r: 2, h: 20).move(z: -5).addTag("bore", recursive: true);
        writeln(b.tags, " ", b.faces.tagged("bore").count, " ", b.faces.tagged("bore").hasTag("bore"));`,
        `["plate"] 1 true`);
    // remove, clear, a list of tags, a chain, foreach, a profile's tag kept by its extrusion
    expectOut(`auto b = box(10, 10, 10);
        b.faces.top.addTag(["lid", "seat"]);
        b.faces.top.removeTag("seat");
        auto t = b.faces.top.tags;
        b.faces.top.clearTags();
        auto c = box(5, 5, 5).faces.bottom.addTag("foot");
        int n = 0;
        foreach (f; c.faces.tagged("foot"))
            n++;
        writeln(t, " ", b.faces.top.tags, " ", n, " ", rect(10, 10).addTag("plate").extrude(2).tags);`,
        `["lid"] [] 1 ["plate"]`);
    // tags kept by draft, offset, a face pushed out, knurl
    expectOut(`auto b = box(40, 30, 10);
        b.faces.top.addTag("lid");
        b.faces.front.addTag("front");
        writeln(b.draft(faces.front, 5.deg).faces.tagged("front").count, " ",
            b.offset(1).faces.tagged("lid").count, " ",
            b.extrude(faces.top, depth: 2).faces.tagged("lid").count, " ",
            b.cut(faces.top, depth: 2).faces.tagged("lid").count);`,
        `1 1 1 1`);
    // references: a point and an axis tagged on a solid follow it; a sketch's point and circle become them
    expectOut(`auto b = box(60, 40, 8).addTag("pin", at: vec(15, 10, 8));
        b.addTag("hinge", at: axis(origin: vec(-30, 0, 4), direction: Y));
        b = b.rotate(x: 90).move(x: 100);
        writeln(b.point("pin"), " ", b.axis("hinge").direction, " ", b.mirror(X).point("pin"));`,
        `[115 mm, -8 mm, 10 mm] [0, 0, 1] [-115 mm, -8 mm, 10 mm]`);
    expectOut(`auto s = sketch();
        auto a = s.point(0, 0, fixed: true);
        auto b = s.point(60, 0);
        s.horizontal(a, b);
        s.distance(a, b, 60.mm);
        s.slot(a, b, w: 16.mm);
        s.circle(b, d: 6.mm).addTag("hole");
        b.addTag("pivot");
        s.addTag("link");
        auto p = s.profile.extrude(4).rotate(x: 90).move(z: 20);
        writeln(p.tags, " ", p.point("pivot"), " ", p.axis("hole").direction, " ", p.frame("pivot").origin,
            " ", b.tags, " ", (p - box(10, 10, 10)).point("pivot"));`,
        `["link"] [60 mm, 0 mm, 20 mm] [0, -1, 0] [60 mm, 0 mm, 20 mm] ["pivot"] [60 mm, 0 mm, 20 mm]`);
    // a sketch on a face: its point where the face is
    expectOut(`auto body = box(40, 40, 10);
        auto s = sketch(body, faces.top);
        s.circle(s.point(5, 5).addTag("mark"), d: 4);
        writeln(s.profile.point("mark"), " ", body.extrude(s.profile, depth: 2).point("mark"));`,
        `[5 mm, 5 mm, 10 mm] [5 mm, 5 mm, 10 mm]`);
    assert(error(`@part Solid p() { auto b = box(10, 10, 10).addTag("pin", at: vec(1, 2, 3)); return b.plane("pin"); }`)
        .message.canFind("'pin' is a point"));
    assert(error(`@part Solid p() { auto b = box(10, 10, 10).addTag("pin", at: vec(1, 2, 3)); b.point("pn"); return b; }`)
        .suggestion.canFind("'pin'"));
    // a sketch's tagged lines and circles: the faces swept from them, extruded (moved after) or revolved
    // (upright too: revolve() with no axis, stood up after)
    expectOut(`auto s = sketch();
        auto a = s.point(0, 0, fixed: true);
        auto b = s.point(100, 0);
        auto c = s.point(0, 25);
        auto sides = s.polyline([a, b, c]);
        s.horizontal(sides[0]);
        s.vertical(sides[2]);
        s.length(sides[0], 100.mm);
        s.length(sides[2], 25.mm);
        sides[0].addTag("base");
        sides[1].addTag("slope");
        s.circle(s.point(20, 8), d: 6.mm).addTag("bore");
        auto d = s.profile.move(x: 5).extrude(40.mm, along: Y);
        d = d.fillet(edges.between(faces.tagged("slope"), faces.tagged("base")), 3.mm);
        auto r = sketch();
        auto p = r.polyline([r.point(0, 0, fixed: true), r.point(20, 0), r.point(10, 30), r.point(0, 30)]);
        p[1].addTag("cone");
        writeln(d.faces.tagged("slope").count, " ", d.faces.tagged("bore").count, " ",
            d.faces.tagged("slope").list[0].normal.y, " ", r.profile.revolve(axis: Y).faces.tagged("cone").count,
            " ", r.profile.revolve().faces.tagged("cone").count, " ",
            r.profile.revolve().faces.tagged("cone").list[0].normal.z > 0);`,
        `1 1 0 1 1 true`);
    // aligned turns and moves a part as one transform: its tagged points go with it (on a corner, still on one)
    expectOut(`auto b = box(10, 20, 30).addTag("pin", at: vec(5.mm, 10.mm, 30.mm));
        auto al = b.rotate(x: 20, z: 10).aligned;
        auto q = al.point("pin");
        auto z = al.bbox.size;
        writeln(abs(abs(q.x) - z.x / 2) < 1e-6.mm, " ", abs(abs(q.y) - z.y / 2) < 1e-6.mm, " ",
            abs(q.z) < 1e-6.mm || abs(q.z - z.z) < 1e-6.mm);`,
        `true true true`);
    // a profile's tagged point: extruded from a tilted profile (once there, not twice), swept (where the
    // profile starts on the path, across it)
    expectOut(`auto r = sketch();
        r.point(1, 2, fixed: true).addTag("pt");
        r.rect(r.point(0, 0, fixed: true), r.point(6, 3, fixed: true));
        writeln(r.profile.across(Y).extrude(5).point("pt"), " ", r.profile.rotate(x: 90).extrude(5).point("pt"));
        writeln(r.profile.sweep(path([vec(0, 0, 0), vec(30, 0, 0)])).point("pt"), " ",
            r.profile.sweep(path([vec(10, 0, 5), vec(10, 0, 30)])).point("pt"));`,
        "[1 mm, 0 mm, 2 mm] [1 mm, 0 mm, 2 mm]\n[0 mm, 1 mm, 2 mm] [11 mm, 2 mm, 5 mm]");
    // threaded, a hole's part and a shaft's part keep their faces' tags where they were (not on the thread's
    // own faces, which are new: a rod's end threaded over is the thread's)
    expectOut(`auto b = box(40, 40, 10);
        b.faces.top.addTag("lid");
        auto hb = b - cylinder(d: 17.5, h: 30, center: true).addTag("bore", recursive: true);
        auto h = hb.thread(hb.faces.tagged("bore"), "M20");
        auto s = box(30, 30, 5) + cylinder(d: 12, h: 20).move(z: 5).addTag("shaft", recursive: true);
        s.faces.bottom.addTag("foot");
        auto t = s.thread(s.faces.tagged("shaft").filter(f => f.area > 300 * 1.mm ^^ 2), "M12");
        auto c = cylinder(d: 12, h: 20);
        c.faces.bottom.addTag("end");
        writeln(h.faces.tagged("lid").list[0].center, " ", t.faces.tagged("foot").list[0].center, " ",
            c.thread(faces.largest, "M12").faces.tagged("end").count);`,
        "[0 mm, 0 mm, 10 mm] [0 mm, 0 mm, 0 mm] 0");
    // a tag there whose faces the rest of the selector leaves out: said so, not that the tag is missing
    assert(error(`@part Solid p() { auto s = box(10, 10, 10); s.faces.top.addTag("lid");
        return s.fillet(edges.of(s.faces.tagged("lid").filter(f => f.area > 1000 * 1.mm ^^ 2)), r: 1); }`)
        .message.canFind("none of them is left"));
    // a part returning Solid.nothing is no part this time; one a cut emptied, or Solid.init, is an error that says
    // how to leave it out
    {
        auto r = runModel("@param(\"Off\")\nimmutable off = true;\n@part Solid a() => box(10, 10, 10);\n"
            ~ "@part Solid lid() => off ? Solid.nothing : box(5, 5, 5);\n");
        assert(r.parts.length == 1 && r.parts[0].name == "a", "the lid left out");
        assert(error("@part Solid p() => box(1, 1, 1) - box(5, 5, 5, center: true);").message.canFind("Solid.nothing"));
        assert(error("@part Solid p() => Solid.init;").message.canFind("is empty"));
    }
    // hull(…, grow:): a box grown 1 mm all round, rounded, between the exact rounded volume and 2% beyond it; a
    // round part's hull (thousands of faces, which offset could not grow) grown too, as far from it as asked
    expectOut(`import std.math;
        auto g = hull(box(10, 10, 10), grow: 1.mm);
        immutable exact = 10 ^^ 3 + 6 * 100 + 3 * 10 * PI + 4.0 / 3 * PI;
        writeln(g.volume / 1.mm ^^ 3 > exact && g.volume / 1.mm ^^ 3 < exact * 1.05, " ",
            g.bbox.size.x > 12.mm && g.bbox.size.x < 12.05.mm);
        auto knob = cylinder(d: 30, h: 15).fillet(edges.of(faces.top), r: 3.mm);
        auto c = hull(knob, grow: 0.5.mm);
        immutable d = hull(knob).deviation(c);
        writeln(c.isValid, " ", d > 0.49.mm && d < 0.52.mm);`, "true true\ntrue true");
    // the built-in libraries are std.gears…: the old name works with a warning that says so
    {
        auto r = runModel("import gears;\n@part Solid p() => spurGear(1.mm, 12, 3.mm);\n");
        assert(r.parts.length == 1 && r.diagnostics.canFind!(d => d.severity == Severity.warning
            && d.message.canFind("std.gears")), "the old name, warned");
        auto q = runModel("import std.gears;\n@part Solid p() => spurGear(1.mm, 12, 3.mm);\n");
        assert(q.parts.length == 1 && !q.diagnostics.canFind!(d => d.severity == Severity.warning), "the new name");
    }
    // a tag with a dot belongs to its module: given only there, read anywhere
    assert(error(`@part Solid p() { return box(1, 1, 1).addTag("hardware.bore"); }`)
        .message.canFind("can only be given in module hardware"));
    // the mistakes: a tag not there, an empty one, one lost, edges, faces of no solid
    auto d = error(`@part Solid p() { auto b = box(10, 10, 10); b.faces.top.addTag("lid");
        return b.fillet(edges.of(faces.tagged("lidd")), 1); }`);
    assert(d.message.canFind("tagged 'lidd'") && d.suggestion.canFind("'lid'"), d.message ~ " " ~ d.suggestion);
    assert(error(`@part Solid p() { auto b = box(10, 10, 10); b.faces.top.removeTag("seat"); return b; }`)
        .message.canFind("no face selected is tagged 'seat'"));
    assert(error(`@part Solid p() { auto b = box(10, 10, 10); b.faces.top.addTag(""); return b; }`)
        .message.canFind("empty"));
    assert(error(`immutable base = box(10, 10, 10); @part Solid p() { base.addTag("x"); return base; }`)
        .message.canFind("would be lost"));
    assert(error(`@part Solid p() { box(10, 10, 10).addTag("x"); return box(1, 1, 1); }`)
        .message.canFind("would be lost"));
    assert(error(`@part Solid p() { auto b = box(10, 10, 10); b.edges.parallel(Z).addTag("x"); return b; }`)
        .message.canFind("edges have no tags"));
    assert(error(`@part Solid p() { auto b = box(10, 10, 10); faces.top.addTag("x"); return b; }`)
        .message.canFind("of which solid"));
}

unittest
{
    mixin(slowTest);
    // the libraries' tags: holes, gears, hinges, enclosures, joints and molds name their faces and axes
    expectOut(`auto p = box(40, 20, 6) - hole(M3, 6.mm, "counterbore").move(x: -10, z: 6)
            - hole(M4, 6.mm).move(x: 10, z: 6);
        auto g = spurGear(2.mm, 20, 8.mm, bore: 5.mm).rotate(x: 90);
        auto h = pinHinge();
        auto e = enclosure(vec(60.mm, 40.mm, 25.mm));
        auto j = splitJoint(box(100, 20, 10), plane(origin: vec(0, 0, 0), normal: X), "dovetail");
        auto m = mold(sphere(r: 15), plane(origin: vec(0, 0, 0), normal: Z));
        auto dw = splitJoint(box(120, 30, 12), plane(origin: vec(0, 0, 0), normal: X), "dowels", count: 2);
        auto jp = joinParts(box(10, 60, 60), box(80, 40, 12).move(x: 45, z: 20), plane(origin: vec(5, 0, 0), normal: X),
            "dowels");
        writeln(dw.loose.length, " ", dw.print.length, " ", dw.print[0].bbox.min.z, " ", jp.loose.length > 0, " ",
            dw.print[0].bbox.size.z < dw.print[0].bbox.size.y);
        writeln(p.faces.tagged("hardware.bore").count, " ", p.faces.tagged("hardware.seat").count, " ",
            g.axis("gears.axis").direction, " ", g.faces.tagged("gears.bore").count, " ",
            h.moving.axis("hinges.axis").direction, " ", h.fixed.faces.tagged("hinges.pin").count, " ",
            e.base.faces.tagged("enclosures.rim").count, " ", e.lid.faces.tagged("enclosures.lip").count > 0, " ",
            j.a.faces.tagged("joints.cut").count > 0, " ", j.b.plane("joints.plane").normal, " ",
            m.a.faces.tagged("molds.cavity").count, " ", m.b.faces.tagged("molds.sprue").count > 0);`,
        "2 2 0 mm true true\n4 2 [0, -1, 0] 1 [1, 0, 0] 3 1 true true [1, 0, 0] 1 true",
        "import std.hardware; import std.gears; import std.hinges; import std.enclosures; import std.joints; import std.molds;");
}

unittest
{
    // a name that exists on its own, used as a member: no "did you mean" the same name
    auto d = error("@part Solid p() { auto w = box(1, 1, 1).World; return box(1, 1, 1); }");
    assert(d.message.canFind("stands on its own") && !d.suggestion.canFind("'World'"), d.message ~ " " ~ d.suggestion);
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
    // a coarse thread in a hole: its teeth go out from the axis, so a Tr24x8 nut's ⌀16 hole takes it,
    // while a ⌀16 shaft is still refused it
    auto r = runModel(q{
        import std.math;
        @part Solid nut() => (cylinder(d: 40, h: 10)
            - cylinder(d: 16, h: 10).addTag("bore", recursive: true))
            .thread(faces.tagged("bore"), "Tr24x8");
        unittest { assert(nut.isValid && nut.volume < PI * (20.mm ^^ 2 - 8.mm ^^ 2) * 10.mm, "threaded"); }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error(`@part Solid p() => cylinder(d: 16, h: 10).thread(faces.largest, pitch: 8.mm);`)
        .message.canFind("reach the axis"));
}

unittest
{
    mixin(slowTest);
    // taper: any thread made conical; NPT's own taper turned off; too much of it refused
    auto r = runModel(q{
        Solid shaft(Length d, Length h) => cylinder(d: d * 1.6, h: 5) + cylinder(d: d, h: h).move(z: 5);
        @part Solid m20() => shaft(20.mm, 20.mm).thread(faces.largest, "M20", taper: 1.79.deg);
        @part Solid plain() => shaft(20.mm, 20.mm).thread(faces.largest, "M20");
        @part Solid npt() => shaft(21.336.mm, 20.mm).thread(faces.largest, "1/2 NPT", taper: 0.deg);
        @part Solid socket() => (box(40, 40, 20) - cylinder(d: 17.6, h: 50, center: true))
            .thread(faces.filter(f => f.area > 1000 * 1.mm ^^ 2 && f.area < 1200 * 1.mm ^^ 2), "M20", taper: 1.79.deg);
        unittest
        {
            assert(m20.isValid && npt.isValid && socket.isValid, "valid");
            immutable top = m20.section(XY.offset(23.mm)).bbox.size.x, bottom = m20.section(XY.offset(7.mm)).bbox.size.x;
            assert(bottom - top > 0.8.mm && bottom - top < 1.3.mm, "taper");
            assert(m20.volume < plain.volume, "narrower");
            immutable nt = npt.section(XY.offset(23.mm)).bbox.size.x, nb = npt.section(XY.offset(7.mm)).bbox.size.x;
            assert(abs(nb - nt) < 0.1.mm, "parallel");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error(`@part Solid p() => cylinder(d: 8, h: 20).thread(faces.largest, "M8", taper: 10.deg);`)
        .message.canFind("narrows the"));
    assert(error(`@part Solid p() => cylinder(d: 8, h: 20).thread(faces.largest, "M8", taper: -1.deg);`)
        .message.canFind("leans from the axis"));
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
    import std.algorithm : startsWith;
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
        import std.hardware : hexPrism;
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
            // a part whose area is not spread along its sides (an L with a hole off centre): squared all the same
            immutable l = (box(60, 30, 4) + box(8, 30, 14) - cylinder(d: 8, h: 20).move(x: 20, y: 7)).aligned;
            assert(abs(l.bbox.size.x / 1.mm - 60) < 1e-6 && abs(l.bbox.size.y / 1.mm - 30) < 1e-6, "squared");
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
            // DejaVu Sans (the default font on many Linux systems; another where it is not installed)
            immutable dejavu = text("Hello", size: 10.mm, font: "DejaVu Sans").round(0.15.mm);
            assert(dejavu.extrude(1).isValid, "DejaVu Sans");
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
    // straight line they do not turn; a closed path's frames go all round,
    // its start not repeated at the end (the step from the last to the first
    // as from one to the next)
    expectOut(q{
        auto f = path([vec(0.mm, 0.mm, 0.mm), vec(0.mm, 0.mm, 40.mm)]).frames(5);
        writeln(f.length, " ", f[1].origin.z, " ", f[4].z.z, " ", f[0].x == f[4].x);
        auto ring = spline([vec(10.mm, 0.mm, 0.mm), vec(0.mm, 10.mm, 0.mm), vec(-10.mm, 0.mm, 0.mm),
            vec(0.mm, -10.mm, 0.mm)], closed: true).frames(30);
        writeln(ring.length, " ", abs((ring[29].origin - ring[0].origin).length
            - (ring[1].origin - ring[0].origin).length) < 0.01.mm, " ",
            abs(ring[7].x.dot(ring[7].z)) < 1e-9);
    }, "5 10 mm 1 true\n30 true true", "import std.math;");
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
    assert(near(box("sec")[0], Vec3(-10, 75, 0)) && near(box("sec")[1], Vec3(10, 78, 30)));
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


unittest
{
    // loops that overlap: the overlap is a hole (even-odd), and s.fill makes an area full or empty
    import std.conv : to;
    import std.math : PI, acos, sqrt, isClose;
    immutable two = "auto s = sketch();\n"
        ~ "s.circle(s.point(0, 0, fixed: true), r: 10.mm);\n"
        ~ "s.circle(s.point(12, 0, fixed: true), r: 10.mm);\n";
    double area(string code)
    {
        import std.array : split;
    import std.string : indexOf;
    import std.algorithm : startsWith;
        return output(code ~ "writeln(s.profile.extrude(1.mm).volume);").split(" ")[0].to!double;   // "… mm³"
    }
    immutable lens = 200 * acos(0.6) - 6 * sqrt(400.0 - 144);   // what the two circles share
    bool near(double a, double b) => isClose(a, b, 1e-4);
    assert(near(area(two), 2 * (PI * 100 - lens)), area(two).to!string);
    assert(near(area(two ~ "s.fill(vec(6, 0));\n"), 2 * PI * 100 - lens));
    assert(near(area(two ~ "s.fill(vec(-5, 0), full: false);\n"), PI * 100 - lens));
    // a point of the sketch: the area holding it, wherever the constraints put it
    assert(near(area(two ~ "auto c = s.point(6, 1);\ns.fill(c);\n"), 2 * PI * 100 - lens));
    // a point there only for a fill: no degrees of freedom left by it
    assert(output(two ~ "auto c = s.point(6, 1);\ns.fill(c);\nwriteln(s.dof);") == "0");
    // a nested loop's hole filled: an island again
    assert(near(area("auto s = sketch();\ns.circle(s.point(0, 0, fixed: true), r: 10.mm);\n"
        ~ "s.circle(s.point(0, 0), r: 5.mm);\ns.fill(vec(0, 0));\n"), PI * 100));
}

unittest
{
    // an ellipse's offset is a curve "the ellipse, d away": kept so, the solid it makes broke once copied by a
    // move (unorientable faces); made a B-spline through it, it stays valid, its size the same
    expectOut(`auto p = (ellipse(25.mm, 19.mm).move(x: 20.mm, y: 12.mm) - circle(d: 8.mm).move(x: 20.mm, y: 12.mm))
            .offset(-2.mm);
        auto s = p.extrude(3.mm);
        writeln(s.isValid, " ", s.move(y: 50.mm).isValid, " ", s.move(x: 0.mm).isValid, " ",
            ellipse(25.mm, 19.mm).offset(-2.mm).extrude(3.mm).rotate(z: 30).isValid, " ",
            abs(s.volume.to!double - s.move(y: 50.mm).volume.to!double) < 1e-6);`,
        "true true true true true");
}

unittest
{
    // shear: an oblique prism, as much material as a straight one, its top moved sideways
    expectOut(`auto s = rect(10.mm, 10.mm).extrude(4.mm, shear: vec(3.mm, 1.mm));
        writeln(s.volume, " ", s.bbox.size, " ", s.isValid);`, "400 mm^3 [13 mm, 11 mm, 4 mm] true");
    expectErr(`rect(10.mm, 10.mm).extrude(4.mm, shear: vec(1.mm, 0.mm), taper: 2.deg);`, "E0202");
}

unittest
{
    // a profile's parts: its outline without holes, its holes, its separate regions
    expectOut(`auto p = rect(30.mm, 20.mm) - circle(d: 5.mm) - circle(vec(8.mm, 0.mm), d: 3.mm)
            + circle(vec(30.mm, 0.mm), d: 6.mm);
        writeln(p.pieces.length, " ", p.holes.length, " ", round(p.outer.area.to!double), " ",
            round(p.holes[0].area.to!double + p.holes[1].area.to!double));`, "2 2 628 27");
    // edges: the outer loop of the top (4 lines, 4 arcs, not the hole's rim), and the chain round the rounded
    // corners from one straight edge: the same
    expectOut(`auto b = rect(30.mm, 20.mm, corner: 4.mm).extrude(5.mm) - cylinder(d: 6.mm, h: 20.mm);
        auto loop = b.chamfer(edges.loop(faces.top), d: 0.5.mm);
        auto chain = b.chamfer(edges.chain(edges.between(faces.top, faces.right)), d: 0.5.mm);
        writeln(abs(loop.volume.to!double - chain.volume.to!double) < 1e-6, " ",
            loop.volume < b.chamfer(edges.of(faces.top), d: 0.5.mm).volume);`, "true false");
}

unittest
{
    // contains: inside a solid (its surface and the holes out), inside a profile's area
    expectOut(`auto b = box(20.mm, 20.mm, 10.mm) - cylinder(d: 6.mm, h: 30.mm);
        auto p = rect(20.mm, 10.mm) - circle(d: 4.mm);
        writeln(b.contains(vec(5.mm, 5.mm, 5.mm)), " ", b.contains(vec(0.mm, 0.mm, 5.mm)), " ",
            b.contains(vec(5.mm, 5.mm, 10.mm)), " ", p.contains(vec(6.mm, 0.mm)), " ", p.contains(vec(0.mm, 0.mm)));`,
        "true false false true false");
}

unittest
{
    mixin(slowTest);
    // paths: a sketch's chains, a solid's edges, corners bent round, a curve from two views; a circle of
    // area π swept along each has a volume of π times the path's length
    expectOut(`auto s = sketch();
        s.polyline([vec(0, 0), vec(30, 0), vec(30, 20)], closed: false);
        s.circle(vec(60, 0), r: 5);
        auto bent = path([vec(0, 0, 0), vec(0, 0, 40.mm), vec(50.mm, 0, 40.mm)], bend: 10.mm);
        auto rim = box(40.mm, 30.mm, 10.mm).path(edges.loop(faces.top));
        auto top = sketch();
        top.polyline([vec(0, 0), vec(40, 0)], closed: false);
        auto side = sketch(XZ);
        side.polyline([vec(0, 0), vec(40, 30)], closed: false);
        auto rise = path(top.path, side.path);
        writeln(format("%d %.3f %.3f %.3f %.3f", s.paths.length, len(s.paths[0]), len(bent), len(rim), len(rise)));
        writeln(format("%.3f", rise.bbox.max.z / 1.mm));`,
        format("2 %.3f %.3f 140.000 50.000\n30.000", 50.0, 30 + 40 + 5 * PI),
        "import std.math;\ndouble len(Path p) => circle(r: 1.mm).sweep(p).volume / 1.mm ^^ 3 / PI;");
    assert(error(`@part Solid p() { auto s = sketch(); s.polyline([vec(0, 0), vec(1, 0)], closed: false);
        s.polyline([vec(2, 0), vec(3, 0)], closed: false); return circle(d: 1).sweep(s.path); }`).message.canFind("2 separate chains"));
    assert(error(`@part Solid p() => circle(d: 1).sweep(path([vec(0, 0, 0), vec(0, 0, 5), vec(5, 0, 5)], bend: 6));`)
        .message.canFind("does not fit"));
    assert(error(`@part Solid p() => circle(d: 1).sweep(box(10, 10, 10).path(edges.parallel(Z)));`)
        .message.canFind("separate pieces"));
}

unittest
{
    mixin(slowTest);
    // the roll about the path: up, a guide or a twist that varies keep the profile across the path, so the
    // volume stays the area times the length; up along the path, or two ways at once, are errors
    expectOut(`auto road = spline([vec(0, 0, 0), vec(40.mm, 30.mm, 5.mm), vec(80.mm, -10.mm, 15.mm), vec(120.mm, 20.mm, 0)]);
        auto rail = spline([vec(0, 0, 20.mm), vec(40.mm, 50.mm, 25.mm), vec(80.mm, -30.mm, 35.mm), vec(120.mm, 20.mm, 20.mm)]);
        auto bar = rect(10.mm, 2.mm);
        immutable plain = bar.sweep(road).volume;
        writeln(abs(bar.sweep(road, up: Z).volume / plain - 1) < 1e-4, " ",
            abs(bar.sweep(road, guide: rail).volume / plain - 1) < 1e-4, " ",
            abs(bar.sweep(road, twist: t => 60.deg * sin(t * 720.deg)).volume / plain - 1) < 1e-4);`,
        "true true true", "import std.math;");
    assert(error(`@part Solid p() => rect(10, 2).sweep(path([vec(0, 0, 0), vec(30, 0, 0), vec(30, 0, 30)], bend: 8), up: Z);`)
        .message.canFind("runs along up"));
    assert(error(`@part Solid p() => rect(10, 2).sweep(helix(r: 10, pitch: 5, height: 20), twist: 90.deg, up: Z);`)
        .message.canFind("give one"));
}

unittest
{
    // halfway between two parallel faces; faces at an angle have no such plane
    expectOut(`auto b = box(20.mm, 10.mm, 30.mm);
        writeln(b.plane(faces.top, faces.bottom));`, "Plane(origin: [0 mm, 0 mm, 15 mm], normal: [0, 0, 1])");
    assert(error(`@part Solid p() { auto b = box(2, 2, 2); auto m = b.plane(faces.top, faces.front); return b; }`)
        .message.canFind("not parallel"));
    // the planes kept in variables are noted for the window, named after them
    auto it = make();
    auto r = runModel("immutable mid = XY.offset(5.mm);\n@part Solid p() { auto side = XZ.flip; return box(1, 1, 1).halves(mid).below; }\n", it);
    assert(r.diagnostics.length == 0);
    // in the order they are made: mid when the part first uses it
    assert(it.planes.map!(p => p.name).array == ["side", "mid"], it.planes.map!(p => p.name).join(" "));
}

unittest
{
    mixin(slowTest);
    // surfaces: a curve swept, a loft through paths; split, push, thicken, sew
    expectOut(`auto route = path([vec(0, 0, 0), vec(0, 0, 40.mm), vec(50.mm, 0, 40.mm)], bend: 15.mm);
        auto ribbon = path([vec(-8.mm, 0), vec(8.mm, 0)]).sweep(route);
        auto tube = (circle(d: 12.mm) - circle(d: 9.mm)).sweep(route);
        auto halves = tube.split(ribbon);
        auto apart = halves.push(from: ribbon, by: 5.mm);
        writeln(halves.length, " ", abs(halves[0].volume / tube.volume - 0.5) < 1e-6, " ",
            (apart[0].bbox.center - halves[0].bbox.center).dot(apart[1].bbox.center - halves[1].bbox.center) < 0);
        Vec3[] sq(Length z) => [vec(0, 0, z), vec(10.mm, 0, z), vec(10.mm, 10.mm, z), vec(0, 10.mm, z)];
        auto sides = loft([path(sq(0.mm), closed: true), path(sq(10.mm), closed: true)], ruled: true);
        auto bottom = rect(10.mm, 10.mm).move(x: 5.mm, y: 5.mm);
        writeln(format("%.3f", sew([sides, bottom, bottom.move(z: 10.mm)]).volume / 1.mm ^^ 3), " ",
            format("%.3f", loft([path([vec(0, 0, 0), vec(20.mm, 0, 0)]), path([vec(0, 0, 20.mm), vec(20.mm, 0, 20.mm)])])
                .thicken(2.mm).volume / 1.mm ^^ 3));`,
        "2 true true\n1000.000 800.000", "import std.math;");
    assert(error(`@part Solid p() => path([vec(-1, 0), vec(1, 0)]).sweep(path([vec(0, 0, 0), vec(0, 0, 5)]));`)
        .message.canFind("no inside"));
    assert(error(`@part Solid p() { auto s = path([vec(-1, 0), vec(1, 0)]).sweep(path([vec(0, 0, 0), vec(0, 0, 5)]));
        return box(2, 2, 2) + s; }`).message.canFind("cannot combine a Surface"));
    assert(error(`@part Solid p() { auto s = path([vec(0, 0, 0), vec(1, 0, 0), vec(1, 1, 0), vec(0, 1, 0)]).sweep(path([vec(0, 0, 0), vec(0, 0, 5)]));
        return sew([s]); }`).message.canFind("open"));
}

unittest
{
    mixin(slowTest);
    // a projection's outline is lines and arcs, not the mesh's tiny segments: a circle stays one, and a
    // sweep of a shadow along a guide does not crawl
    expectOut(`auto disc = (cylinder(d: 20.mm, h: 5.mm) - cylinder(d: 8.mm, h: 20.mm).move(z: -5.mm)).projection;
        writeln(format("%.3f", disc.extrude(1.mm).volume / 1.mm ^^ 3 / (PI * (100 - 16))));
        Vec3[] pts;
        foreach (i; 0 .. 31)
            pts ~= vec(i * 3.mm, 12.mm * cos(i * 12.deg), 12.mm * sin(i * 12.deg));
        writeln(format("%.3f", disc.sweep(path([vec(0, 0, 0), vec(90.mm, 0, 0)]), guide: spline(pts)).volume
            / 1.mm ^^ 3 / (90 * PI * (100 - 16))));`, "1.000\n1.000", "import std.math;");
}

unittest
{
    mixin(slowTest);
    // a thread along an arc, lofted through rings, and a hex head: OpenCascade warned and dropped the thread
    // (the union was the head alone, no error), and with the head sunk in, the volume of the union meshed
    // its big B-spline face for minutes; now a union is the right one or an error, quickly
    enum thread = q{
        import std.math;
        Length radiusAt(Length u)
        {
            immutable p = 1.25.mm, h = 0.5413 * p;
            immutable q = u - p * floor(u / p);
            immutable x = q > p / 2 ? p - q : q;
            if (x <= p / 16) return 4.mm;
            if (x >= p / 2 - p / 8) return 4.mm - h;
            return 4.mm - h * (x - p / 16) / (p / 2 - p / 8 - p / 16);
        }
        Solid thread()
        {
            Vec3[] pts;
            foreach (i; 0 .. 61)
                pts ~= vec(100.mm - 100.mm * cos(i / 60.0 * 0.5), 0.mm, 100.mm * sin(i / 60.0 * 0.5));
            immutable frames = spline(pts).frames(161);
            Vec3[][] rings;
            foreach (k, f; frames)
            {
                Vec3[] ring;
                foreach (j; 0 .. 32)
                {
                    immutable phi = j * 360.deg / 32;
                    immutable r = radiusAt(50.mm * k / 160 - 1.25.mm * j / 32);
                    ring ~= f.origin + f.x * (r * cos(phi)) + f.y * (r * sin(phi));
                }
                rings ~= [ring];
            }
            return loft(rings);
        }
        Solid head(Length top) => polygon(6, d: 13.mm, fit: "sides").extrude(5.3.mm).move(z: top - 5.3.mm);
    };
    // touching at z = 0: the whole of both, or an error saying it could not be done
    try
    {
        auto r = runModel(thread ~ q{
            unittest { writeln(format("%.1f", ((thread() + head(0.mm)).volume - thread().volume - head(0.mm).volume) / 1.mm ^^ 3)); }
            @part Solid p() => box(1, 1, 1);
        });
        foreach (d; r.diagnostics)
            assert(d.severity != Severity.error || d.message.canFind("could not combine") || d.message.canFind("wrong result"),
                d.message);
        if (r.log.length)
            assert(r.log[0].text == "0.0" || r.log[0].text == "-0.0", "the union lost a body: " ~ r.log[0].text);
    }
    catch (HcadError e)
        assert(e.msg.canFind("could not combine") || e.msg.canFind("wrong result"), e.msg);
    // sunk 0.5 mm: the union's volume is the two less what they share
    expectOut(`immutable both = thread() + head(0.5.mm);
        immutable shared_ = thread() & head(0.5.mm);
        writeln(format("%.1f", (both.volume + shared_.volume - thread().volume - head(0.5.mm).volume) / 1.mm ^^ 3));`,
        "0.0", thread);
}

unittest
{
    mixin(slowTest);
    // an ISO thread built from its helices is exact: its volume is the profile's mean cross-section
    // times its length (a flat crest p/8 on the major radius, a flat root p/4 on the minor one, straight
    // flanks between), and it is right-handed (a nut's thread, made the same way, fits it)
    expectOut(`immutable p = 1.25.mm, R = 4.mm, r = R - 0.5413 * p;
        immutable mean = PI * (R ^^ 2 / 8 + r ^^ 2 / 4 + 5.0 / 8 * (R ^^ 2 + R * r + r ^^ 2) / 3);
        writeln(format("%.4f", isoThread(d: 8.mm, pitch: p, length: 20.mm).volume / (mean * 20.mm)));
        // the nut's tool lowered by whole pitches: its thread in phase with the rod's
        auto nut = cylinder(d: 14.mm, h: 6.mm) - tappedHole(8.mm, p, 7 * p, clearance: 0.1.mm).move(z: 6 * p);
        writeln(format("%.3f", (nut & threadedRod(8.mm, p, 6.mm, chamfer: false)).volume / 1.mm ^^ 3));
        writeln((nut & threadedRod(8.mm, p, 6.mm, chamfer: false, left: true)).volume > 10 * 1.mm ^^ 3);`,
        "1.0000\n0.000\ntrue", "import std.math;\nimport std.threads;");
}

unittest
{
    mixin(slowTest);
    // threads on faces are built from their helices too: a two-start M8 (its fuse of two swept ridges
    // failed) has the volume of a one-start one, the same profile as dense along the shaft
    expectOut(`Solid shaft() => cylinder(d: 8.mm, h: 25.mm) + cylinder(d: 14.mm, h: 5.mm).move(z: -5.mm);
        auto side = faces.filter(f => f.area > 600 * 1.mm ^^ 2);
        immutable one = shaft().thread(side, "M8").volume, two = shaft().thread(side, "M8", starts: 2).volume;
        writeln(abs(two / one - 1) < 1e-3, " ", one < shaft().volume);`, "true true", "import std.math;");
}

unittest
{
    mixin(slowTest);
    // the standards added on 2026-10-18 thread a shaft of their size: each takes some of it away, and
    // less than its teeth's depth would all round
    expectOut(`foreach (size; ["1/2-10 ACME", "S20x4", "E27", "E14", "28-400", "PCO 1881", "3/4 GHT"])
        {
            auto shaft = cylinder(d: major(size), h: 15.mm);
            auto done = shaft.thread(faces.filter(f => f.area > PI * major(size) * 15.mm * 0.9), size);
            immutable core = PI / 4 * (major(size) - 2 * depthOf(size)) ^^ 2 * 15.mm;
            writeln(size, " ", done.volume < shaft.volume && done.volume > core);
        }`,
        "1/2-10 ACME true\nS20x4 true\nE27 true\nE14 true\n28-400 true\nPCO 1881 true\n3/4 GHT true",
        "import std.math;\nLength major(string s) => [\"1/2-10 ACME\": 12.7.mm, \"S20x4\": 20.mm, \"E27\": 26.45.mm, \"E14\": 13.89.mm, "
        ~ "\"28-400\": 27.3812.mm, \"PCO 1881\": 27.43.mm, \"3/4 GHT\": 26.9875.mm][s];\n"
        ~ "Length depthOf(string s) => [\"1/2-10 ACME\": 1.27.mm, \"S20x4\": 3.471.mm, \"E27\": 1.095.mm, \"E14\": 0.8.mm, "
        ~ "\"28-400\": 1.1938.mm, \"PCO 1881\": 1.245.mm, \"3/4 GHT\": 1.2.mm][s];");
}

unittest
{
    mixin(slowTest);
    // the topic guides: every model in them (a code block with a @part) evaluates, its unittests pass
    import hackerscad.tool.docs : guides;
    import std.array : split;
    import std.string : indexOf;
    import std.algorithm : startsWith;
    foreach (g; guides)
    {
        assert(g.text.startsWith("# " ~ g.title ~ "\n"), "the guide " ~ g.slug ~ " starts with its title");
        foreach (n, block; g.text.split("```d\n")[1 .. $])
        {
            immutable code = block[0 .. block.indexOf("\n```")];
            if (!code.canFind("@part"))
                continue;
            auto r = runModel(code);
            foreach (d; r.diagnostics)
                assert(d.severity != Severity.error, format("guide %s, model %d: %s (line %d)\n%s", g.slug, n + 1,
                    d.message, d.span.line, code));
        }
    }
}

unittest
{
    mixin(slowTest);
    // a surface that misses a solid, or ends inside it, is refused, not a piece silently lost
    assert(error(`import std.carlo;
        immutable sheet = spline([vec(-12, 0), vec(0, 3), vec(12, -3), vec(24, 3), vec(36, 0)])
            .sweep(path([vec(0, -15, 7.5), vec(0, 20, 7.5)]));
        @part Solid p() => carlo().split(sheet)[0];`).message.canFind("reach across it"));
    assert(error(`immutable sheet = spline([vec(-12, 0), vec(0, 3), vec(12, -3)])
            .sweep(path([vec(0, -15, 50), vec(0, 20, 50)]));
        @part Solid p() => box(10, 10, 10).split(sheet)[0];`).message.canFind("reach across it"));
    // a surface through a square and a circle: whole and straight, not twisted; sharp-edged
    // sheets thicken joined at their edges
    auto r = runModel(q{
        immutable sq = path([vec(-10, -10, 0), vec(10, -10, 0), vec(10, 10, 0), vec(-10, 10, 0)], closed: true);
        Path ring()
        {
            auto s = sketch();
            s.circle(vec(0, 0), d: 30.mm);
            return s.path.move(z: 30.mm);
        }
        immutable funnel = loft([sq, ring()]);
        @part Solid prism() => loft([sq, sq.scale(1.5).move(z: 30.mm)]).thicken(1.mm);
        // sharp corners meeting a circle: made from the paths, either way
        @part Solid outwards() => funnel.thicken(1.mm);
        @part Solid inwards() => funnel.thicken(-1.mm).move(x: 50);
        unittest
        {
            assert(outwards.isValid && abs(outwards.bbox.size.x - 32.mm) < 0.01.mm, "outwards");
            assert(inwards.isValid && abs(inwards.bbox.size.x - 30.mm) < 0.01.mm, "inwards");
            assert(abs(funnel.bbox.min.y + 15.mm) < 0.1.mm && abs(funnel.bbox.max.y - 15.mm) < 0.1.mm, "whole");
            assert(prism.isValid && prism.volume > 3000 * 1.mm ^^ 3, "joined");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    // hole callouts: a countersunk and a counterbored hole named so, a boss not taken for a hole
    import hackerscad.lang.drawingval : DrawingVal;
    import hackerscad.drawing.sheet : toSvg;
    auto r = runModel(q{
        import std.hardware : M4, hole;
        @part Solid plate() => box(60, 30, 6)
            + cylinder(d: 16, h: 14).move(x: 18)
            - hole(M4, 6.mm, "countersink").move(x: -22, y: -7, z: 6)
            - hole(M4, 6.mm, "countersink").move(x: -22, y: 7, z: 6)
            - hole(M4, 6.mm, "counterbore").move(x: 0, y: -7, z: 6);
        @drawing Drawing sheet()
        {
            auto d = drawing(title: "Plate");
            d.standardViews(plate);
            return d;
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    auto svg = toSvg((cast(DrawingVal) r.drawings[0].drawing).render());
    assert(svg.canFind("2× ⌀4.5, countersink ⌀") && svg.canFind("⌀4.5, counterbore ⌀"), svg);
    assert(!svg.canFind(">⌀16<"), "the boss is not a hole");
}

unittest
{
    // faces.from a tool made again by calling its function a second time: the same faces
    auto r = runModel(q{
        Solid holes() => cylinder(d: 4, h: 20).move(x: 5) + cylinder(d: 4, h: 20).move(x: -5);
        @part Solid b() => (box(30, 20, 10) - holes())
            .chamfer(edges.between(faces.from(holes()), faces.top), d: 0.5.mm);
        unittest
        {
            immutable plain = box(30, 20, 10) - holes();
            assert(b.volume < plain.volume, "chamfered");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    // s.line and s.arc take vectors as s.polyline does: new points there
    auto r = runModel(q{
        Profile p()
        {
            auto s = sketch();
            auto a = s.line(vec(0, 0), vec(30, 0));
            auto b = s.arc(vec(30, 10), a.end, vec(30, 20));
            auto c = s.line(b.end, vec(0, 20));
            s.line(c.end, a.start);
            return s.profile;
        }
        @part Solid x() => p().extrude(2.mm);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(partVolume(r, "x") > 1400);
}

unittest
{
    // a solid tool cut on a face: placed with its z = 0 on the face and +Z out of it
    auto r = runModel(q{
        import std.hardware : hole, M3;
        @part Solid p() => box(30, 20, 10)
            .cut(hole(M3, 6.mm, "counterbore"), on: faces.top, at: vec(5.mm, 3.mm, 0.mm))
            .cut(hole(M3, 6.mm, "countersink"), on: faces.farthest(X), at: vec(15.mm, 0.mm, 5.mm));
        unittest
        {
            // the top's hole, near its point, and the side's
            assert(!p.contains(vec(5.mm, 3.mm, 9.mm)) && !p.contains(vec(14.mm, 0.mm, 5.mm)), "cut");
            assert(p.contains(vec(5.mm, 3.mm, 1.mm)), "6 mm deep only");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error(`import std.hardware : hole, M3; @part Solid p() => box(30, 20, 10).cut(hole(M3, 6.mm), on: faces.top, depth: 2.mm);`)
        .message.canFind("a solid tool is cut as it is"));
}

unittest
{
    mixin(slowTest);
    // a female thread cut from the same free end as a male one is in step with it, whatever the
    // lengths: a nut cut over a bolt's tip runs on it, for either hand
    auto r = runModel(q{
        Solid rod(bool left) => cylinder(d: 8, h: 30).thread(faces.largest, "M8", left: left);
        Solid nut(bool left) => ((cylinder(d: 16, h: 30) - cylinder(d: 6.9, h: 32).move(z: -1))
            .thread(faces.filter(f => f.area > 500 * 1.mm ^^ 2 && f.area < 800 * 1.mm ^^ 2), "M8", left: left)
            & cylinder(d: 16, h: 6).move(z: 18));
        @part Solid p() => rod(false);
        unittest
        {
            assert((rod(false) & nut(false)).volume < 0.01 * 1.mm ^^ 3, "right");
            assert((rod(true) & nut(true)).volume < 0.01 * 1.mm ^^ 3, "left");
            assert((rod(false) & nut(true)).volume > 1 * 1.mm ^^ 3, "the wrong hand binds");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    mixin(slowTest);
    // the dual-thread bolt: both nuts run free on the bolt cut by both threads
    import std.file : thisExePath;
    import std.path : dirName;
    auto it = make();
    auto r = it.run(buildPath(dirName(dirName(dirName(thisExePath))), "examples", "11_dualthread.hcad"));
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error && d.severity != Severity.warning, d.message);
}

unittest
{
    // s.dof of a sketch whose constraints conflict: the conflict, not 0
    auto d = error(`Profile p()
        {
            auto s = sketch();
            auto l = s.rect(vec(0, 0), vec(20, 10));
            s.length(l[0], 20.mm);
            s.length(l[0], 30.mm);
            writeln(s.dof);
            return s.profile;
        }
        @part Solid x() => p().extrude(1.mm);`);
    assert(d.message.canFind("conflict"), d.message);
}

unittest
{
    // Profile p; is an empty profile, to add to in a loop as an empty Solid is
    auto r = runModel(q{
        Profile holes()
        {
            Profile all;
            foreach (i; 0 .. 4)
                all = all + circle(d: 3.mm).move(x: i * 6.mm);
            return all;
        }
        @part Solid x() => (rect(30.mm, 10.mm) - holes().move(x: -9.mm)).extrude(2.mm);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(isClose(partVolume(r, "x"), 600 - 4 * PI * 1.5 * 1.5 * 2, 1e-3));
}

unittest
{
    // Carlo grown by 0.3 mm (faces meeting tangentially): the offset works, and without its workaround fails
    import hackerscad.kernel.occt.c;
    immutable src = "import std.carlo;\n@part Solid x() => carlo().offset(0.3.mm);";
    assert(!fails(src), "Carlo grows by 0.3 mm");
    hc_workaround(HC_WORKAROUND_OFFSET_TOLERANCE, 0);
    scope (exit)
        hc_workaround(HC_WORKAROUND_OFFSET_TOLERANCE, 1);
    stillBroken(fails("import std.carlo;\n@part Solid x() => carlo().offset(0.31.mm);"),
        "MakeOffsetShape at 1e-6 on tangent faces (shim.cpp, hc_offset_solid)");
}

unittest
{
    mixin(slowTest);
    // the hardware library's heads, larger and inch sizes, square nuts and extrusions with their T-nuts
    auto r = runModel(q{
        import std.hardware;
        @part Solid heads() => screw(M4, 12.mm, head: "button") + screw(M4, 12.mm, head: "flat").move(x: 12)
            + screw(M4, 12.mm, head: "hex").move(x: 24) + screw(ST2_9, 10.mm, head: "pan").move(x: 36)
            + screw(M12, 20.mm).move(x: 52) + screw(UNC1_4_20, 15.mm).move(x: 72);
        @part Solid slot() => box(20, 20, 10) - squareNutSlot(M3, 15.mm).move(z: 5) - hole(M3, 10.mm).move(z: 10);
        Solid rail(int series) => extrusion(series, 40.mm).move(z: -20.mm).rotate(y: -90)
            .move(z: -extrusionSeries(series).size / 2);
        @part Solid r20() => rail(20);
        unittest
        {
            assert(heads.isValid && slot.isValid, "valid");
            // the T-nuts and the key sit in their slots without touching
            foreach (series; [20, 30])
            {
                assert((rail(series) & tNut(series)).volume < 0.001 * 1.mm ^^ 3, "T-nut");
                assert((rail(series) & slotKey(series, 20.mm)).volume < 0.001 * 1.mm ^^ 3, "key");
                // and they are in it: lifted above the face, a T-nut would not be under the lips
                assert(tNut(series).bbox.max.z <= 0.mm && tNut(series).bbox.min.z < -extrusionSeries(series).lip, "depth");
            }
            // the nut in its slot, the screw through both
            assert((squareNut(M3).move(z: -squareNutHeight(M3) / 2) & squareNutSlot(M3, 10.mm)).volume
                > 0.9 * squareNut(M3).volume, "the nut in its slot");
            assert(abs(headOf(M4, "flat").d - 8.96.mm) < 0.01.mm, "ISO 10642 head");
            // grub screws: as long as asked, the socket end on z = 0, each point, in a tapped hole's room
            foreach (pt; ["cup", "flat", "cone", "dog"])
            {
                auto g = setScrew(M3, 6.mm, point: pt);
                assert(g.isValid && abs(g.bbox.max.z / 1.mm) < 1e-6 && abs(g.bbox.min.z / 1.mm + 6) < 1e-6, pt);
                assert(g.volume < cylinder(d: 3, h: 6).volume, pt ~ ": its socket and point take away");
            }
            assert(setKey(M3) == 1.5.mm && setKey(M8) == 4.mm, "ISO 4029 keys");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error("import std.hardware; @part Solid p() => box(10, 10, 10) - hole(ST2_9, 5.mm, \"insert\");")
        .message.canFind("no heat-set insert"));
}

unittest
{
    mixin(slowTest);
    // fill: a wavy rim closed by a smooth face, a dome through a point, an opening of a solid closed
    auto r = runModel(q{
        import std.math;
        Path rim()
        {
            Vec3[] pts;
            foreach (i; 0 .. 24)
            {
                immutable t = i * 360.deg / 24;
                pts ~= vec(20.mm * cos(t), 14.mm * sin(t), 4.mm * sin(2 * t));
            }
            return spline(pts, closed: true);
        }
        @part Solid cap() => fill(rim()).thicken(1.mm);
        @part Solid dome() => fill(rim(), through: [vec(0.mm, 0.mm, 10.mm)]).thicken(1.mm).move(x: 50.mm);
        immutable bore = cylinder(d: 8, h: 20).move(z: 4);
        immutable body = box(30, 20, 10) - bore;
        @part Solid lid() => body.fill(edges.between(faces.top, faces.from(bore)), tangent: faces.top)
            .thicken(1.mm).move(x: 100);
        unittest
        {
            assert(cap.isValid && cap.bbox.size.z > 8.mm && cap.bbox.size.z < 9.5.mm, "the cap follows the rim");
            assert(dome.bbox.max.z > 9.5.mm, "the dome reaches its point");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error(`@part Solid p() => fill(path([vec(0, 0, 0), vec(10, 0, 0), vec(10, 10, 0)])).thicken(1.mm);`)
        .message.canFind("closed"));
}

unittest
{
    mixin(slowTest);
    // shadowCase: round Carlo lying and standing, with a lip and with a snap: nothing touching it, the lid on
    // the base, base and lid meeting halfway up
    auto r = runModel(q{
        import std.carlo;
        import std.enclosures;
        immutable lying = shadowCase(carlo());
        immutable standing = shadowCase(carlo().rotate(y: -90), close: "snap", split: 0.3);
        @part Solid base() => lying.base;
        unittest
        {
            foreach (k, c; [lying, standing])
            {
                auto clip = k == 0 ? carlo() : carlo().rotate(y: -90);
                assert(c.base.isValid && c.lid.isValid, "valid");
                assert((c.base & clip).volume == 0.mm ^^ 3 && (c.lid & clip).volume == 0.mm ^^ 3, "room inside");
                assert((c.base & c.lid).volume < 0.01 * 1.mm ^^ 3, "the lid on the base");
            }
            // the lid comes down to halfway up Carlo (15 mm), the snap's to 30% of its 41.5 mm
            assert(abs(lying.lid.bbox.min.z - 7.5.mm) < 0.01.mm, "halfway");
            assert(abs(standing.lid.bbox.min.z - (standing.base.bbox.min.z + 2.mm + 0.3 * 41.5497.mm)) < 0.05.mm,
                "the split");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    mixin(slowTest);
    // the faces a surface cuts keep where they came from: faces.from(the surface) finds them
    auto r = runModel(q{
        immutable wave = spline([vec(-25.mm, 0.mm), vec(-10.mm, 3.mm), vec(5.mm, -3.mm), vec(25.mm, 2.mm)])
            .sweep(path([vec(0.mm, -20.mm, 12.mm), vec(0.mm, 20.mm, 12.mm)]));
        immutable block = box(40.mm, 30.mm, 20.mm).split(wave)[0];
        @part Solid p() => block.fillet(edges.of(faces.from(wave)), r: 1.mm);
        unittest { assert(p.volume < block.volume, "rounded"); }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    // fill follows a curved rim only through chords: without them the plate sags far below it
    import hackerscad.kernel.occt.c;
    import std.array : replace;
    immutable src = `import std.math;
        Path rim()
        {
            Vec3[] pts;
            foreach (i; 0 .. 24)
                pts ~= vec(20.mm * cos(i * 15.deg), 14.mm * sin(i * 15.deg), 4.mm * sin(i * 30.deg));
            return spline(pts, closed: true);
        }
        @part Solid p() => box(1, 1, 1);
        unittest { writeln(fill(rim()).bbox.min.z); }`;
    double lowest(string code)
    {
        import std.conv : to;
        import std.array : split;
        return runModel(code).log[0].text.split(" ")[0].to!double;
    }
    assert(lowest(src) > -4.1, "the fill follows its rim");
    hc_workaround(HC_WORKAROUND_FILL_CHORDS, 0);
    scope (exit)
        hc_workaround(HC_WORKAROUND_FILL_CHORDS, 1);
    // the rim as OpenCascade's own periodic interpolation makes it, called directly: spline(closed: true) is a
    // sketch's closed spline now, which the filling does not sag on
    import std.math : cos, sin;
    double[] xyz;
    foreach (i; 0 .. 25)
        xyz ~= [20 * cos(i * 14.4 * PI / 180), 14 * sin(i * 14.4 * PI / 180), 4 * sin(i * 28.8 * PI / 180)];
    auto rim = hc_spline(xyz.ptr, 25, 1);
    assert(rim !is null);
    scope (exit)
        hc_shape_free(rim);
    auto plate = hc_fill(rim, null, null, 0, null, 0, null, 0);
    assert(plate !is null);
    scope (exit)
        hc_shape_free(plate);
    double[6] bb;
    assert(hc_bbox(plate, bb) == 0);
    stillBroken(bb[2] < -5, "MakeFilling sagging along curved edges (shim.cpp, hc_fill)");
}

unittest
{
    // offset(sharp: true): a box grown stays a box
    auto r = runModel(q{
        @part Solid p() => box(20, 10, 5).offset(2.mm, sharp: true);
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(isClose(partVolume(r, "p"), 24.0 * 14 * 9, 1e-6));
}

unittest
{
    mixin(slowTest);
    // threads on shafts built straight from their faces and joined by hand: the same solids as the
    // boolean way (HCAD_THREAD_DIRECT=0), whatever the starts, hand, bevel, shoulder or length
    import std.process : environment;
    immutable src = q{
        Solid shaft() => cylinder(d: 32.mm, h: 5.mm) + cylinder(d: 20.mm, h: 30.mm).move(z: 5.mm);
        @part Solid a() => cylinder(d: 20.mm, h: 30.mm).thread(faces.largest, "M20");
        @part Solid b() => shaft().thread(faces.largest, "M20", chamfer: false).move(x: 40);
        @part Solid c() => shaft().thread(faces.largest, "M20", starts: 2, left: true).move(x: 80);
        @part Solid d() => shaft().thread(faces.largest, "Tr20x4", length: 15.mm).move(x: 120);
        @part Solid e() => cylinder(d: 8.mm, h: 20.mm).thread(faces.largest, "M8", flip: true).move(x: 160);
        @part Solid f() => shaft().thread(faces.largest, "M20", clearance: 0.2.mm).move(x: 200);
    };
    double[string] volumes(string direct)
    {
        environment["HCAD_THREAD_DIRECT"] = direct;
        scope (exit)
            environment.remove("HCAD_THREAD_DIRECT");
        auto r = runModel(src);
        foreach (d; r.diagnostics)
            assert(d.severity != Severity.error, d.message);
        double[string] v;
        foreach (p; r.parts)
        {
            assert(kernel.isValid(p.solid.brep), p.name ~ " is not valid");
            v[p.name] = kernel.volume(p.solid.brep);
        }
        return v;
    }
    auto boolean = volumes("0"), direct = volumes("1");
    foreach (name, vb; boolean)
        assert(abs(direct[name] - vb) < 1e-4 * vb, format("%s: %s by hand, %s by the boolean", name, direct[name], vb));
}

unittest
{
    mixin(slowTest);
    // a solid less a list: one boolean, the same solid as one at a time, the holes' faces theirs
    auto r = runModel(q{
        Solid[] holes()
        {
            Solid[] h;
            foreach (i; 0 .. 4)
                h ~= cylinder(d: 3.mm, h: 10.mm, center: true).move(x: i * 8.mm - 12.mm);
            return h;
        }
        immutable plate = box(40, 10, 4);
        @part Solid all() => plate - holes();
        @part Solid each() => plate - holes()[0] - holes()[1] - holes()[2] - holes()[3];
        @part Solid rounded() => (plate - holes()).chamfer(edges.between(faces.from(holes()), faces.top), d: 0.3.mm);
        unittest
        {
            assert(abs(all.volume - each.volume) < 1e-6 * each.volume, "the same solid");
            assert(rounded.volume < all.volume, "the holes' faces found");
        }
    });
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    assert(error("@part Solid p() => box(10, 10, 10) - [box(1, 1, 1), 3];").message.canFind("list holds"));
}

// ---------------------------------------------------------------- tilings and noise kinds

unittest
{
    mixin(slowTest);
    // nine 10 mm squares, 2 mm apart: 8 × 8 each
    expectOut("writeln(rect(30.mm, 30.mm).tiles(kind: \"square\", size: 10.mm, gap: 2.mm).area);", "576 mm^2");
    // cut at the border, or only the whole ones
    expectOut("writeln(rect(25.mm, 25.mm).tiles(kind: \"square\", size: 10.mm, gap: 2.mm).area);", "441 mm^2");
    expectOut("writeln(rect(25.mm, 25.mm).tiles(kind: \"square\", size: 10.mm, gap: 2.mm, whole: true).area);",
        "64 mm^2");
    // keep: and scale: from each cell's centre
    expectOut("writeln(rect(30.mm, 30.mm).tiles(kind: \"square\", size: 10.mm, gap: 2.mm, "
        ~ "keep: (Vec2 c) => c.x > 0.mm).area);", "192 mm^2");
    expectOut("writeln(rect(30.mm, 30.mm).tiles(kind: \"square\", size: 10.mm, gap: 2.mm, scale: 0.5).area);",
        "144 mm^2");
    // every kind fills the region, less the walls (and the slivers the border cuts off, under 2% of a cell)
    foreach (kind; ["hex", "triangle", "brick", "octagon", "diamond", "voronoi"])
    {
        auto r = runModel("unittest { auto a = circle(d: 40.mm).tiles(kind: \"" ~ kind ~ "\", size: 6.mm).area; "
            ~ "auto b = circle(d: 40.mm).tiles(kind: \"" ~ kind ~ "\", size: 6.mm, gap: 1.mm).area; "
            ~ "assert(a <= circle(d: 40.mm).area + 0.01 * 1.mm ^^ 2 && a > 0.98 * circle(d: 40.mm).area, \"" ~ kind
            ~ " covers (but for slivers at the border)\"); "
            ~ "assert(b < 0.8 * a && b > 0.3 * a, \"" ~ kind ~ " walls\"); }");
        foreach (dg; r.diagnostics)
            assert(dg.severity != Severity.error, kind ~ ": " ~ dg.message);
    }
    // your own tile: plus signs tile the plane; circles too close overlap
    expectOut("auto s = 5.mm; auto t = rect(40.mm, 40.mm).tiles(tile: rect(3 * s, s) + rect(s, 3 * s), "
        ~ "step: [vec(2 * s, s), vec(-s, 2 * s)]); writeln(t.area);", "1600 mm^2");
    auto d = errorIn("rect(40.mm, 40.mm).tiles(tile: circle(d: 8.mm), step: [vec(6.mm, 0.mm), vec(0.mm, 9.mm)]);");
    assert(d.code == Code.type && d.message.canFind("overlap") && d.message.canFind("1·a + 0·b"), d.message);
    expectErr("rect(40.mm, 40.mm).tiles(kind: \"star\", size: 5.mm);", Code.type);
    expectErr("rect(40.mm, 40.mm).tiles(kind: \"hex\");", Code.missingArg);
    expectErr("rect(40.mm, 40.mm).tiles(kind: \"hex\", size: 4.mm, gap: 5.mm);", Code.type);
    // a grille of many holes extrudes (quickly) into a sound solid of the right volume
    auto g = runModel("@part Solid p() => (rect(100.mm, 100.mm) - rect(96.mm, 96.mm)"
        ~ ".tiles(kind: \"hex\", size: 3.mm, gap: 0.8.mm)).extrude(2.mm);\n"
        ~ "unittest { auto f = rect(100.mm, 100.mm) - rect(96.mm, 96.mm).tiles(kind: \"hex\", size: 3.mm, gap: 0.8.mm); "
        ~ "assert(abs(p.volume - f.area * 2.mm) < 1e-6 * p.volume); }");
    foreach (dg; g.diagnostics)
        assert(dg.severity != Severity.error, dg.message);
    assert(kernel.isValid(g.parts[0].solid.brep));
}

unittest
{
    // the kinds of noise and their ranges; octaves
    expectOut("double lo = 1, hi = -1; foreach (i; 0 .. 300) { auto v = noise(i * 0.13, i * 0.07, kind: \"edges\"); "
        ~ "lo = min(lo, v); hi = max(hi, v); } writeln(lo >= 0 && lo < 0.1 && hi <= 1 && hi > 0.3);", "true");
    expectOut("writeln(noise(0.3, 0.2, kind: \"ridged\", octaves: 3) <= 1, \" \", "
        ~ "loopNoise(0, 1.5, bumps: 6, kind: \"cells\") == loopNoise(1, 1.5, bumps: 6, kind: \"cells\"));", "true true");
    expectErr("noise(1, kind: \"perlin\");", Code.type);
    expectErr("noise(1, octaves: 12);", Code.type);
}

unittest
{
    mixin(slowTest);
    // a 10 × 10 mm square rolled round a cylinder of radius 20: half a radian of a ring 1 mm
    // thick, 10 mm tall; raised on the front (-Y), or dug in
    expectOut("auto c = cylinder(r: 20.mm, h: 30.mm); "
        ~ "auto up = c.extrude(rect(10.mm, 10.mm), wrap: faces.largest, depth: 1.mm); "
        ~ "auto down = c.cut(rect(10.mm, 10.mm), wrap: faces.largest, depth: 1.mm); "
        ~ "writeln(abs(up.volume - c.volume - 0.25 * 41 * 10 * 1.mm ^^ 3) < 0.01 * 1.mm ^^ 3, \" \", "
        ~ "abs(c.volume - down.volume - 0.25 * 39 * 10 * 1.mm ^^ 3) < 0.01 * 1.mm ^^ 3, \" \", "
        ~ "abs(up.bbox.min.y + 21.mm) < 0.01.mm, \" \", abs(up.bbox.min.z) < 1e-6.mm);", "true true true true");
    // at: puts it elsewhere; several regions in one go
    expectOut("auto c = cylinder(r: 20.mm, h: 30.mm); "
        ~ "auto r = c.extrude(rect(4.mm, 4.mm) + rect(4.mm, 4.mm).move(x: 10.mm), wrap: faces.largest, "
        ~ "at: vec(20.mm, 0.mm, 15.mm), depth: 1.mm); "
        ~ "writeln(r.bbox.max.x > 20.9.mm, \" \", r.isValid, \" \", r.volume > c.volume + 30 * 1.mm ^^ 3);",
        "true true true");
    // projected onto a ball from the front: about the disc's area times the depth
    expectOut("auto b = sphere(20.mm); auto p = b.cut(circle(d: 10.mm), project: faces.largest, along: Y, depth: 1.mm); "
        ~ "auto gone = (b.volume - p.volume) / (PI * 25 * 1.mm ^^ 3); writeln(gone > 0.9 && gone < 1.1);", "true");
    expectErr("cylinder(r: 5.mm, h: 10.mm).cut(rect(40.mm, 4.mm), wrap: faces.largest, depth: 1.mm);", Code.kernel);
    expectErr("cylinder(r: 5.mm, h: 10.mm).cut(rect(4.mm, 4.mm), wrap: faces.largest, project: faces.largest, "
        ~ "depth: 1.mm);", Code.unknownArg);
    expectErr("cylinder(r: 5.mm, h: 10.mm).cut(rect(4.mm, 4.mm), wrap: faces.largest, on: faces.top, depth: 1.mm);",
        Code.type);
}

unittest
{
    // a hole with ribs: wider than the tap hole, narrower than the screw's wall; a rib towards -Y
    // (none opposite it), and none in the lead at the top
    expectOut("import std.hardware; auto h = hole(M3, 10.mm, \"ribs\"); "
        ~ "writeln(h.volume > PI * 1.25 ^^ 2 * 10 * 1.mm ^^ 3 && h.volume < PI * 1.65 ^^ 2 * 10 * 1.mm ^^ 3, \" \", "
        ~ "h.contains(vec(0.mm, -1.4.mm, -5.mm)), \" \", h.contains(vec(0.mm, 1.4.mm, -5.mm)), \" \", "
        ~ "h.contains(vec(0.mm, -1.4.mm, -0.3.mm)));", "true false true true");
    // the mouth chamfered 0.5 mm for ribs unless told otherwise; any kind takes chamfer:
    expectOut("import std.hardware; writeln(hole(M3, 10.mm, \"ribs\").contains(vec(1.9.mm, 0.mm, -0.1.mm)), \" \", "
        ~ "hole(M3, 10.mm, \"ribs\", chamfer: 0.mm).contains(vec(1.9.mm, 0.mm, -0.1.mm)), \" \", "
        ~ "hole(M3, 10.mm, chamfer: 0.4.mm).contains(vec(1.95.mm, 0.mm, -0.1.mm)), \" \", "
        ~ "hole(M3, 10.mm).contains(vec(1.95.mm, 0.mm, -0.1.mm)));", "true false true false");
}

unittest
{
    mixin(slowTest);
    import std.process : environment;
    // pockets, reliefs and cuts through a wall laid on a curved face, built at once (no boolean) and
    // the boolean way: the same solid; on a cone, a hole's inner wall, with islands (the O, the D), and
    // through a conical sleeve
    immutable model = "@part Solid cone() => loft([circle(d: 40.mm), circle(d: 25.mm).move(z: 40.mm)])"
        ~ ".cut(rect(70.mm, 25.mm).tiles(kind: \"voronoi\", size: 8.mm, gap: 1.2.mm, round: 1.mm, relax: 2), "
        ~ "wrap: faces.largest, depth: 1.mm);\n"
        ~ "@part Solid tube() => (cylinder(d: 40.mm, h: 40.mm) - cylinder(d: 34.mm, h: 50.mm).move(z: -5.mm))"
        ~ ".cut(text(\"ODD\", size: 6.mm).centered, wrap: faces.filter(f => f.area > 4000.mm * 1.mm "
        ~ "&& f.area < 4500.mm * 1.mm), depth: 1.mm);\n"
        ~ "@part Solid mug() => cylinder(d: 40.mm, h: 40.mm)"
        ~ ".extrude(text(\"ODD\", size: 8.mm).centered, wrap: faces.largest, depth: 0.8.mm);\n"
        ~ "@part Solid sleeve() => loft([circle(d: 40.mm), circle(d: 50.mm).move(z: 60.mm)])"
        ~ ".shell(open: faces.top + faces.bottom, thickness: 2.mm)"
        ~ ".cut(rect(90.mm, 30.mm).tiles(kind: \"voronoi\", size: 9.mm, gap: 2.mm, round: 1.mm, relax: 2), "
        ~ "wrap: faces.largest, depth: 4.mm);\n"
        // cells running off the face at its top and bottom: those the boolean way, the rest at once
        ~ "@part Solid edged() => cylinder(d: 40.mm, h: 30.mm)"
        ~ ".cut(rect(100.mm, 40.mm).tiles(kind: \"voronoi\", size: 7.mm, gap: 1.2.mm, round: 0.8.mm, relax: 2), "
        ~ "wrap: faces.largest, depth: 1.mm);\n";
    double[] volumes(string direct)
    {
        auto before = environment.get("HCAD_WRAP_DIRECT");
        environment["HCAD_WRAP_DIRECT"] = direct;
        scope (exit)
        {
            if (before is null)
                environment.remove("HCAD_WRAP_DIRECT");
            else
                environment["HCAD_WRAP_DIRECT"] = before;
        }
        auto r = runModel(model);
        foreach (d; r.diagnostics)
            assert(d.severity != Severity.error && d.code != Code.kernel, d.message);
        double[] v;
        foreach (p; r.parts)
        {
            assert(kernel.isValid(p.solid.brep), p.name);
            v ~= kernel.volume(p.solid.brep);
        }
        return v;
    }
    auto direct = volumes("1"), boolean = volumes("0");
    foreach (i; 0 .. 5)
        assert(abs(direct[i] - boolean[i]) < 1e-3 * 1000, format("%s: %s %s", i, direct[i], boolean[i]));
}

unittest
{
    mixin(slowTest);
    // every joint: the two pieces apart from each other, one body each, and together the solid less
    // the play; the wedge of the scarf a body of its own
    auto r = runModel("import std.joints;\n"
        ~ "unittest { auto beam = box(20.mm, 20.mm, 120.mm); auto p = plane(origin: vec(0.mm, 0.mm, 60.mm), normal: Z);\n"
        ~ "foreach (kind; jointKinds) { auto j = splitJoint(beam, p, kind: kind, count: 3);\n"
        ~ "assert((j.a & j.b).volume < 0.001 * 1.mm ^^ 3, kind ~ \": the pieces overlap\");\n"
        ~ "assert(j.a.pieces.length == 1 && j.b.pieces.length == 1, kind ~ \": a piece in several bodies\");\n"
        ~ "auto lost = beam.volume - j.a.volume - j.b.volume;\n"
        ~ "assert(lost > 0.mm ^^ 3 && lost < 0.03 * beam.volume, kind ~ \": the play takes $(lost)\"); }\n"
        ~ "auto k = splitJoint(beam, p, kind: \"kanawa\"); assert(k.loose.length == 1 && k.loose[0].volume > 0.mm ^^ 3);\n"
        ~ "assert((k.loose[0] & k.a).volume < 0.001 * 1.mm ^^ 3 && (k.loose[0] & k.b).volume < 0.001 * 1.mm ^^ 3); }\n");
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    mixin(slowTest);
    // halves cut flat with keys: apart from each other and from the keys, the keys in both pockets,
    // each half laid on its cut face on z = 0; spots far apart and away from the edges
    auto r = runModel("import std.joints;\n"
        ~ "unittest { auto egg = sphere(30.mm).scale(z: 1.5).move(z: 45.mm);\n"
        ~ "auto h = splitFlat(egg, plane(origin: vec(0.mm, 0.mm, 45.mm), normal: Y), keys: 2);\n"
        ~ "assert(h.keys.length == 2 && h.print.length == 2);\n"
        ~ "assert((h.a & h.b).volume < 0.001 * 1.mm ^^ 3);\n"
        ~ "foreach (k; h.keys) { assert((k & h.a).volume < 0.001 * 1.mm ^^ 3 && (k & h.b).volume < 0.001 * 1.mm ^^ 3);\n"
        ~ "assert(k.bbox.min.y < -0.5.mm && k.bbox.max.y > 0.5.mm); }\n"
        ~ "assert(abs(h.aPrint.bbox.min.z) < 1e-6.mm && abs(h.aPrint.bbox.max.z - 30.mm) < 0.01.mm);\n"
        ~ "assert(abs(h.bPrint.bbox.min.z) < 1e-6.mm && abs(h.bPrint.bbox.max.z - 30.mm) < 0.01.mm);\n"
        ~ "foreach (k; h.print) assert(abs(k.bbox.min.z) < 1e-6.mm);\n"
        ~ "auto sp = rect(100.mm, 20.mm).spots(2, margin: 5.mm);\n"
        ~ "assert(sp.length == 2 && distance(sp[0], sp[1]) > 80.mm && abs(sp[0].x) <= 45.mm + 1e-6.mm);\n"
        ~ "assert(rect(10.mm, 10.mm).spots(2, margin: 6.mm).length == 0); }\n");
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    mixin(slowTest);
    // a mold: the halves apart, the cavity the part's volume, keys on a fitting sockets in b, the
    // pour hole open from the cavity to the outside, both laid on z = 0
    auto r = runModel("import std.carlo; import std.molds;\n"
        ~ "unittest { auto c = carlo(eye: false); auto m = mold(c, plane(origin: vec(0.mm, 0.mm, 7.5.mm), normal: Z));\n"
        ~ "assert((m.a & m.b).volume < 0.001 * 1.mm ^^ 3, \"the halves overlap\");\n"
        ~ "assert((m.a & c).volume < 0.001 * 1.mm ^^ 3 && (m.b & c).volume < 0.001 * 1.mm ^^ 3, \"the cavity is filled\");\n"
        ~ "auto bb = c.bbox; auto block = box(bb.size.x + 20.mm, bb.size.y + 20.mm, bb.size.z + 20.mm);\n"
        ~ "assert(m.a.bbox.max.z > 7.5.mm + 1.mm, \"no keys\");\n"
        ~ "assert(m.a.pieces.length == 1 && m.b.pieces.length == 1);\n"
        ~ "assert(abs(m.aPrint.bbox.min.z) < 1e-6.mm && abs(m.bPrint.bbox.min.z) < 1e-6.mm);\n"
        ~ "auto above = m.b.section(plane(origin: vec(0.mm, 0.mm, 20.mm), normal: Z));\n"
        ~ "assert(above.holes.length == 3, \"the pour hole and two vents\"); }\n");
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    mixin(slowTest);
    // two parts joined where one meets the other: apart, the tenon inside the upright's room and not
    // past its far side, nothing pushed outside the shelf's end
    auto r = runModel("import std.joints;\n"
        ~ "unittest { auto up = box(12.mm, 60.mm, 100.mm).move(x: -6.mm); auto sh = box(60.mm, 50.mm, 12.mm).move(x: 30.mm, z: 40.mm);\n"
        ~ "foreach (kind; [\"tenon\", \"dovetail\", \"pins\", \"lap\", \"kama\"]) {\n"
        ~ "auto j = joinParts(up, sh, plane(origin: vec(0.mm, 0.mm, 46.mm), normal: X), kind: kind);\n"
        ~ "assert((j.a & j.b).volume < 0.001 * 1.mm ^^ 3, kind ~ \": overlap\");\n"
        ~ "assert(j.b.bbox.min.x >= -12.mm - 1e-6.mm && j.b.bbox.min.z >= 40.mm - 1e-6.mm && j.b.bbox.max.z <= 52.mm + 1e-6.mm, kind ~ \": past the shelf\");\n"
        ~ "assert(j.a.pieces.length == 1 && j.b.pieces.length == 1, kind); } }\n");
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    mixin(slowTest);
    // kerf: slots through a plate in the zone only, running across its length (along Y here), the
    // plate one piece; along: turns them
    auto r = runModel("import std.flex;\n"
        ~ "unittest { auto plate = box(120.mm, 40.mm, 3.mm); auto zone = box(40.mm, 50.mm, 10.mm, center: true);\n"
        ~ "auto k = kerf(plate, zone); assert(k.volume < plate.volume && k.pieces.length == 1);\n"
        ~ "auto mid = k.section(plane(origin: vec(0.mm, 0.mm, 1.5.mm), normal: Z));\n"
        ~ "assert(mid.holes.length > 10, \"no slots\"); auto h = mid.holes[0].bbox.size; assert(h.y > h.x, \"slots along X\");\n"
        ~ "assert((plate - zone).volume - (k - zone).volume < 0.01 * 1.mm ^^ 3, \"slots outside the zone\");\n"
        ~ "auto t = kerf(plate, zone, along: X).section(plane(origin: vec(0.mm, 0.mm, 1.5.mm), normal: Z));\n"
        ~ "auto g = t.holes[0].bbox.size; assert(g.x > g.y); }\n");
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    mixin(slowTest);
    // knurling: raised all round a cylinder by the depth, a whole number of cells, the ends plain
    expectOut("auto c = cylinder(d: 30.mm, h: 20.mm); auto k = c.knurl(faces.largest); "
        ~ "writeln(abs(k.bbox.size.x - 31.mm) < 0.01.mm, \" \", k.volume > c.volume, \" \", k.isValid, \" \", "
        ~ "c.knurl(faces.largest, kind: \"straight\").volume > c.volume);", "true true true true");
    expectErr("cylinder(d: 30.mm, h: 20.mm).knurl(faces.largest, kind: \"wavy\");", Code.type);
    // any other face: a flat one (raised inside its outline, the margin in from it) and the side of a
    // loft through rings, which closes round on itself
    expectOut("auto b = box(30.mm, 20.mm, 5.mm); auto k = b.knurl(faces.top, margin: 2.mm); "
        ~ "writeln(abs(k.bbox.size.z - 5.5.mm) < 0.01.mm, \" \", abs(k.bbox.size.x - 30.mm) < 0.01.mm, \" \", "
        ~ "k.volume > b.volume, \" \", k.isValid);", "true true true true");
    expectOut("Vec3[][] rings; foreach (i; 0 .. 7) { Vec3[] r; foreach (j; 0 .. 60) "
        ~ "r ~= vec((25.mm + i * 1.mm) * cos(j * 6.deg) * 1.4, (25.mm + i * 1.mm) * sin(j * 6.deg), i * 5.mm); "
        ~ "rings ~= [r]; } auto v = loft(rings); "
        ~ "auto k = v.knurl(faces.largest, kind: \"diagonal\", margin: 3.mm); "
        ~ "writeln(k.volume > v.volume, \" \", k.isValid, \" \", abs(k.bbox.size.z - 30.mm) < 0.01.mm);",
        "true true true");
}

unittest
{
    mixin(slowTest);
    // the hinges: leaves apart, the pin's bore through every knuckle, the snap's cones in its sockets
    auto r = runModel("import std.hinges;\n"
        ~ "unittest { auto p = pinHinge(); assert((p.fixed & p.moving).volume < 0.001 * 1.mm ^^ 3);\n"
        ~ "assert(!p.fixed.contains(vec(-19.mm, 0.mm, 3.mm)) && !p.moving.contains(vec(0.mm, 0.mm, 3.mm)), \"no bore\");\n"
        ~ "auto s = snapHinge(); assert((s.fixed & s.moving).volume < 0.001 * 1.mm ^^ 3);\n"
        ~ "assert(s.fixed.contains(vec(-4.5.mm, 0.mm, 3.mm)) && s.fixed.contains(vec(4.5.mm, 0.mm, 3.mm)), \"no cones\");\n"
        ~ "auto l = livingHinge(); assert(l.pieces.length == 1 && l.contains(vec(0.mm, 0.mm, 0.25.mm))\n"
        ~ "&& !l.contains(vec(0.mm, 0.mm, 1.mm))); }\n");
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
}

unittest
{
    mixin(slowTest);
    import std.process : environment;
    // a thread in a hole made as a sleeve joined by hand (the default) and the boolean way: the same solid,
    // right and left handed, two starts, with and without the countersink, through and blind, its length
    // or shorter
    immutable model = "@part Solid a() => (polygon(6, d: 19.mm, fit: \"sides\").extrude(10.mm) "
        ~ "- cylinder(d: 10.3.mm, h: 30.mm, center: true)).thread(faces.largest, \"M12\", clearance: 0.2.mm);\n"
        ~ "@part Solid b() => (cylinder(d: 34.mm, h: 16.mm) - cylinder(d: 17.3.mm, h: 40.mm, center: true))"
        ~ ".thread(faces.filter(f => f.area < 1000.mm * 1.mm && f.area > 800.mm * 1.mm), \"M20\", left: true, chamfer: false);\n"
        ~ "@part Solid c() => (box(30.mm, 30.mm, 12.mm) - cylinder(d: 12.mm, h: 40.mm, center: true))"
        ~ ".thread(faces.filter(f => f.area < 500.mm * 1.mm && f.area > 400.mm * 1.mm), \"Tr14x3\", starts: 2);\n"
        // shorter than the hole, and in blind holes: the sleeve's end on its pocket's floor; each cut in
        // half after, a boolean on what the join left
        ~ "Solid threaded(bool blind, Length length) { auto hole = blind ? cylinder(d: 6.8.mm, h: 16.mm).move(z: 10.mm) "
        ~ ": cylinder(d: 6.8.mm, h: 27.mm).move(z: -1.mm); auto b = box(30.mm, 30.mm, 25.mm) - hole; "
        ~ "auto wall = faces.filter(f => f.area > 200.mm * 1.mm && f.area < 600.mm * 1.mm); "
        ~ "return length > 0.mm ? b.thread(wall, \"M8\", length: length) : b.thread(wall, \"M8\"); }\n"
        ~ "Solid half(Solid s) => s - box(60.mm, 60.mm, 60.mm).move(y: -30.mm, z: -5.mm);\n"
        ~ "@part Solid d() => half(threaded(false, 10.mm)).move(x: 100.mm);\n"
        ~ "@part Solid e() => half(threaded(true, 0.mm)).move(x: 140.mm);\n"
        ~ "@part Solid f() => half(threaded(true, 8.mm)).move(x: 180.mm);\n";
    double[] volumes(string sleeve)
    {
        auto before = environment.get("HCAD_THREAD_SLEEVE");
        environment["HCAD_THREAD_SLEEVE"] = sleeve;
        scope (exit)
        {
            if (before is null)
                environment.remove("HCAD_THREAD_SLEEVE");
            else
                environment["HCAD_THREAD_SLEEVE"] = before;
        }
        auto r = runModel(model);
        foreach (d; r.diagnostics)
            assert(d.severity != Severity.error && d.code != Code.kernel, d.message);
        double[] v;
        foreach (p; r.parts)
        {
            assert(kernel.isValid(p.solid.brep), p.name);
            v ~= kernel.volume(p.solid.brep);
        }
        return v;
    }
    auto sleeve = volumes("1"), boolean = volumes("0");
    foreach (i; 0 .. 6)
        assert(abs(sleeve[i] - boolean[i]) < 1e-3 * boolean[i], format("%s: %s %s", i, sleeve[i], boolean[i]));
}

unittest
{
    mixin(slowTest);
    // tags through every operation on a box whose six sides are tagged: no tag on a face off its side's plane
    // (where the operation moved it), none lost while its face is there; the check itself caught on a box
    // moved and checked where it was
    auto r = runModel(`import std.joints;
import std.flex;
import std.molds;
import std.hardware : M3, hole;
import std.threads;

immutable string[] names = ["top", "bottom", "right", "left", "back", "front"];
immutable ns = [vec(0, 0, 1), vec(0, 0, -1), vec(1, 0, 0), vec(-1, 0, 0), vec(0, 1, 0), vec(0, -1, 0)];
immutable cs = [vec(0.mm, 0.mm, 20.mm), vec(0.mm, 0.mm, 0.mm), vec(20.mm, 0.mm, 10.mm),
    vec(-20.mm, 0.mm, 10.mm), vec(0.mm, 15.mm, 10.mm), vec(0.mm, -15.mm, 10.mm)];

/// A 40 × 30 × 20 box, each face tagged with its side.
Solid tagged()
{
    auto b = box(40, 30, 20);
    b.faces.top.addTag("top");
    b.faces.bottom.addTag("bottom");
    b.faces.right.addTag("right");
    b.faces.left.addTag("left");
    b.faces.back.addTag("back");
    b.faces.front.addTag("front");
    return b;
}

/// Prints what is wrong with the tags of r: a tagged face off its side's plane (moved by
/// shift, its normal and point turned by the caller), a side's tag lost though not in gone.
int check(Solid r, string op, string[] gone, string[] skip, Vec[] pts, Vec[] nrm)
{
    int bad = 0;
    foreach (i, t; names)
    {
        if (skip.canFind(t))
            continue;
        auto n = r.faces.tagged(t).count;
        if (n == 0 && !gone.canFind(t))
        {
            writeln(op, ": '", t, "' lost");
            bad++;
        }
        if (n == 0)
            continue;
        foreach (f; r.faces.tagged(t))
            if (abs(f.normal.dot(nrm[i]) - 1) > 1e-6 || abs((f.center - pts[i]).dot(nrm[i])) > 1e-3.mm)
            {
                writeln(op, ": '", t, "' on a wrong face at ", f.center, " normal ", f.normal);
                bad++;
                break;
            }
        if (gone.canFind(t))
        {
            writeln(op, ": '", t, "' expected gone, still on ", n);
            bad++;
        }
    }
    return bad;
}

int same(Solid r, string op, string[] gone = [], string[] skip = []) => check(r, op, gone, skip, cs, ns);

@part
Solid p() => box(1, 1, 1);

unittest
{
    auto b = tagged();
    auto Zp = plane(origin: vec(0, 0, 10), normal: Z);
    auto Xp = plane(origin: vec(0, 0, 0), normal: X);
    int bad = 0;
    bad += same(b, "identity");
    bad += same(b.fillet(edges.of(faces.tagged("top")), r: 2), "fillet top edges");
    bad += same(b.fillet(edges.parallel(Z), r: 3), "fillet vertical edges");
    bad += same(b.chamfer(edges.of(faces.tagged("top")), d: 2), "chamfer top edges");
    bad += same(b.shell(open: faces.tagged("top"), thickness: 2), "shell (the rim keeps top)");
    bad += same(b.draft(faces.tagged("front"), 5.deg), "draft front", [], ["front"]);
    bad += same(b - cylinder(d: 10, h: 50, center: true), "hole through");
    bad += same(b - cylinder(d: 10, h: 50).move(z: 5), "blind hole from top");
    bad += same(b + box(10, 10, 10).move(z: 20), "union on top");
    bad += same(b + box(10, 10, 10).move(x: 15, z: 5), "union through the right");
    bad += same(b & box(30, 20, 40, center: true), "intersection", ["right", "left", "back", "front"]);
    bad += same(b - box(10, 50, 50, center: true).move(x: 20), "notch across right", ["right"]);
    bad += same(b.cut(circle(d: 5), on: b.frame(faces.tagged("top")), depth: 3), "cut on top");
    bad += same(b.extrude(rect(10, 10), on: b.frame(faces.tagged("top")), depth: 3), "extrude on top");
    bad += same(b.extrude(rect(10, 10), on: b.frame(faces.tagged("front")), depth: 3), "extrude on front");
    auto sp = b.split(Zp);
    bad += same(sp[0], "split lower", ["top"]);
    bad += same(sp[1], "split upper", ["bottom"]);
    bad += same(b.halves(Zp).above, "halves above", ["bottom"]);
    bad += same(b.halves(Zp).below, "halves below", ["top"]);
    bad += same(b.split(Xp)[0], "split left piece", ["right"]);
    bad += same(b.knurl(faces.tagged("front")), "knurl front", [], ["front"]);
    bad += same(kerf(b, box(10, 40, 40, center: true)), "kerf");

    // faces moved: where each side is now
    Vec[] up(Length d) => cs.map(c => c + vec(0.mm, 0.mm, d)).array;
    bad += check(b.move(z: 5), "move", [], [], up(5.mm), ns);
    bad += check(b.on(box(10, 10, 5)), "on", [], [], up(5.mm), ns);
    bad += check(b.push(from: vec(0, 0, -100), by: 10.mm), "push", [], [], up(10.mm), ns);
    bad += check(b.centered, "centered", [], [], up(-10.mm), ns);
    bad += check(b.offset(1, sharp: true), "offset sharp", [], [],
        iota(0, 6).map(i => cs[i] + ns[i] * 1.mm).array, ns);
    bad += check(b.scale(2), "scale", [], [], cs.map(c => c * 2).array, ns);
    bad += check(b.mirror(X), "mirror X", [], [], cs.map(c => vec(-c.x, c.y, c.z)).array,
        ns.map(n => vec(-n.x, n.y, n.z)).array);
    bad += check(b.rotate(z: 90), "rotate z 90", [], [], cs.map(c => vec(-c.y, c.x, c.z)).array,
        ns.map(n => vec(-n.y, n.x, n.z)).array);
    bad += check(b.extrude(faces.tagged("top"), depth: 5), "pull top face", [], [],
        [vec(0.mm, 0.mm, 25.mm)] ~ cs[1 .. $], ns);
    bad += check(b.cut(faces.tagged("top"), depth: 5), "push top face", [], [],
        [vec(0.mm, 0.mm, 15.mm)] ~ cs[1 .. $], ns);

    // the libraries
    auto j = splitJoint(b, Xp);
    bad += same(j.a, "splitJoint a", ["right"]) + same(j.b, "splitJoint b", ["left"]);
    auto d = splitJoint(b, Xp, kind: "dowels");
    bad += same(d.a, "dowels a", ["right"]) + same(d.b, "dowels b", ["left"]);

    // the check itself: a box moved and checked where it was must fail
    writeln("sanity caught ", check(b.move(z: 5), "sanity (expected wrong)", [], [], cs, ns));

    bad += same(b.linearPattern(2, vec(100, 0, 0)), "linearPattern", [], ["right", "left"]);
    bad += check(b.placeOn(box(60, 60, 10).frame(faces.top)), "placeOn", [], [], up(10.mm), ns);
    bad += check(b.nextTo(box(10, 10, 10), X, gap: 5.mm), "nextTo", [], [],
        cs.map(c => c + vec(30.mm, 0.mm, 0.mm)).array, ns);
    bad += check(b.align(box(100, 100, 100), z: "max"), "align", [], [], up(80.mm), ns);
    bad += check(b.pull(to: vec(0, 0, 100), by: 10.mm), "pull", [], [], up(10.mm), ns);
    bad += check(b.offset(1), "offset round", [], [], iota(0, 6).map(i => cs[i] + ns[i] * 1.mm).array, ns);
    bad += same(hull(b, sphere(r: 1).move(z: 30)), "hull", ["top"]);
    bad += check(minkowski(b, sphere(r: 1)), "minkowski", [], [], iota(0, 6).map(i => cs[i] + ns[i] * 1.mm).array, ns);
    bad += check(minkowski(b, box(2, 2, 2, center: true)), "minkowski box", [], [],
        iota(0, 6).map(i => cs[i] + ns[i] * 1.mm).array, ns);

    bad += same(b.cut(rect(10, 5), wrap: faces.tagged("front"), depth: 1), "wrap cut front");
    bad += same(b.cut(rect(30, 20).tiles(kind: "hex", size: 6, gap: 1), on: b.frame(faces.tagged("top")), depth: 1),
        "tiles on top");
    bad += same(b - hole(M3, 10, "counterbore").move(z: 20), "hole() counterbore");
    bad += same(b - tappedHole(8, 1.25, 10).move(z: 20), "tappedHole");
    auto hb = b - cylinder(d: 10.2, h: 50, center: true).addTag("bore", recursive: true);
    bad += same(hb.thread(hb.faces.tagged("bore"), "M12"), "thread in a hole");
    auto sb = b + cylinder(d: 12, h: 15).move(z: 20).addTag("shaft", recursive: true);
    bad += same(sb.thread(sb.faces.tagged("shaft").filter(f => f.area > 300 * 1.mm ^^ 2), "M12"), "thread on a shaft");
    bad += same(threadedRod(8, 1.25, 30).move(z: 20) + b, "union with a threaded rod");
    auto fl = splitFlat(b, Zp);
    bad += same(fl.a, "splitFlat a", ["top"]) + same(fl.b, "splitFlat b", ["bottom"]);
    auto jp = joinParts(b, box(10, 10, 10).move(z: 20), plane(origin: vec(0, 0, 20), normal: Z));
    bad += same(jp.a, "joinParts a");
    writeln("bad ", bad);
}
`);
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    auto log = r.log.map!(l => l.text).join("\n");
    assert(log.canFind("sanity caught 2") && log.canFind("bad 0"), log);
}

// references (addTag(…, at:)) where the solid goes: each piece of a split those that lie in it or on it,
// a copy joined to itself holds them once, a tag given again replaces them, a pattern keeps its first copy's
unittest
{
    expectOut(`auto b = box(40, 10, 10).addTag("pin", at: vec(-15, 0, 5)).addTag("mid", at: vec(0, 0, 5));
        auto h = b.halves(plane(origin: vec(0, 0, 0), normal: X));
        writeln(h.below.point("pin"), " ", h.above.point("mid"), " ", h.below.point("mid"), " ",
            (h.above + h.below).point("pin"), " ", (b + b).point("pin"));
        auto ps = b.split(plane(origin: vec(0, 0, 0), normal: X));
        writeln(ps[0].point("pin"), " ", ps[1].point("mid"), " ", (ps[0] + ps[1]).point("mid"));
        writeln(b.extrude(faces.top, depth: 5).point("pin"), " ", b.cut(faces.top, depth: 5).point("pin"));
        writeln(b.linearPattern(3, vec(50, 0, 0)).point("pin"), " ", b.move(x: 50).circularPattern(4).point("pin"));
        auto c = b;
        c.addTag("pin", at: vec(1, 2, 3));
        writeln(c.point("pin"), " ", minkowski(b, sphere(r: 1)).point("pin"));`,
        "[-15 mm, 0 mm, 5 mm] [0 mm, 0 mm, 5 mm] [0 mm, 0 mm, 5 mm] [-15 mm, 0 mm, 5 mm] [-15 mm, 0 mm, 5 mm]\n"
        ~ "[-15 mm, 0 mm, 5 mm] [0 mm, 0 mm, 5 mm] [0 mm, 0 mm, 5 mm]\n"
        ~ "[-15 mm, 0 mm, 5 mm] [-15 mm, 0 mm, 5 mm]\n"
        ~ "[-15 mm, 0 mm, 5 mm] [35 mm, 0 mm, 5 mm]\n"
        ~ "[1 mm, 2 mm, 3 mm] [-15 mm, 0 mm, 5 mm]");
    // not on the side it does not lie on, nor in what an intersection leaves out (a hole's axis stays)
    auto e = error(`@part Solid p() { auto b = box(40, 10, 10).addTag("pin", at: vec(-15, 0, 5));
        return box(1, 1, 1).move(z: b.halves(plane(origin: vec(0, 0, 0), normal: X)).above.point("pin").z); }`);
    assert(e.message.canFind("no point, axis, plane or frame of this solid is tagged 'pin'"), e.message);
    assert(error(`@part Solid p() { auto b = box(40, 10, 10).addTag("pin", at: vec(-15, 0, 5));
        return box(1, 1, 1).move((b & box(5, 5, 5)).point("pin")); }`).message.canFind("tagged 'pin'"));
    expectOut(`auto d = box(40, 10, 10) - cylinder(d: 4, h: 30, center: true).move(x: 15)
            .addTag("drill", at: axis(origin: vec(15, 0, 5), direction: Z));
        writeln((d & box(20, 20, 20).move(x: 15)).axis("drill").origin, " ",
            d.halves(XY.offset(5)).below.axis("drill").origin);`,
        "[15 mm, 0 mm, 5 mm] [15 mm, 0 mm, 5 mm]");
    assert(error(`@part Solid p() { auto d = box(40, 10, 10) - cylinder(d: 4, h: 30, center: true).move(x: 15)
            .addTag("drill", at: axis(origin: vec(15, 0, 5), direction: Z));
        return box(1, 1, 1).move((d & box(10, 10, 10).move(x: -15)).axis("drill").origin); }`)
        .message.canFind("tagged 'drill'"));
    // copies in different places: which, and what to do
    e = error(`@part Solid p() { auto b = box(10, 10, 10).addTag("pin", at: vec(0, 0, 10));
        auto u = b + b.move(x: 20); return box(1, 1, 1).move(u.point("pin")); }`);
    assert(e.message.canFind("different places") && e.suggestion.canFind("replaces"), e.message ~ " " ~ e.suggestion);
}

// the frame of a tagged axis or plane: its X as plane(…).frame() and frame(face) have it, also once turned;
// an empty solid's references kept by a union
unittest
{
    expectOut(`auto t = box(10, 10, 10).addTag("a", at: axis(origin: vec(0, 0, 0), direction: Z))
            .addTag("p", at: plane(origin: vec(0, 0, 0), normal: -Z));
        writeln(t.frame("a").x, " ", t.frame("p").x, " ", t.frame("p").y, " ", t.rotate(y: 90).frame("a").x, " ",
            plane(origin: vec(0, 0, 0), normal: X).frame().x, " ", t.frame(faces.bottom).y);
        auto n = Solid.nothing.addTag("q", at: vec(1, 2, 3));
        writeln((box(1, 1, 1) + n).point("q"));`,
        "[1, 0, 0] [1, 0, 0] [0, -1, 0] [0, 1, 0] [0, 1, 0] [0, -1, 0]\n[1 mm, 2 mm, 3 mm]");
}

// extruded symmetric, a sketch's point stays where it was drawn; sheared, a circle's axis leans with its hole
unittest
{
    expectOut(`auto s = sketch();
        s.rect(s.point(0, 0, fixed: true), s.point(20, 10, fixed: true));
        s.point(5, 5, fixed: true).addTag("mark");
        s.circle(s.point(15, 5, fixed: true), d: 3).addTag("hole");
        writeln(s.profile.extrude(10, symmetric: true).point("mark"), " ",
            s.profile.rotate(x: 90).extrude(10, symmetric: true).point("mark"), " ",
            s.profile.extrude(10, shear: vec(10, 0)).axis("hole").direction, " ",
            s.profile.extrude(10, shear: vec(10, 0), symmetric: true).axis("hole").origin);`,
        "[5 mm, 5 mm, 0 mm] [5 mm, 0 mm, 5 mm] [0.707107, 0, 0.707107] [15 mm, 5 mm, 0 mm]");
}

// a sketch's tagged lines and circles tag the faces made from them also sheared, twisted, offset, the
// profile joined with or less another; where a step cannot keep them, the error says so
unittest
{
    enum prof = `Profile prof()
    {
        auto s = sketch();
        auto l = s.polyline([s.point(0, 0, fixed: true), s.point(20, 0, fixed: true), s.point(20, 10, fixed: true),
            s.point(0, 10, fixed: true)], closed: true);
        l[1].addTag("side");
        s.circle(s.point(10, 5, fixed: true), d: 4).addTag("bore");
        return s.profile;
    }
    void show(Solid r) { writeln(r.faces.tagged("side").count, " ", r.faces.tagged("bore").count); }`;
    expectOut(`auto P = prof();
        show(P.extrude(5, shear: vec(2, 1)));
        show(P.extrude(5, twist: 30.deg));
        show(P.offset(1).extrude(5));
        show(P.offset(-0.5).extrude(5));
        show((P - circle(d: 2).move(x: 3, y: 3)).extrude(5));
        show((P + circle(d: 4).move(x: 20, y: 5)).extrude(5));
        show(P.round(1).extrude(5));`, "1 1\n1 1\n1 1\n1 1\n1 1\n2 1\n1 1", prof);
    auto e = error(prof ~ `@part Solid p() => hull(prof()).extrude(5).fillet(edges.of(faces.tagged("side")), r: 1);`);
    assert(e.message.canFind("lost its name") && e.message.canFind("a hull"), e.message);
    e = error(prof ~ `@part Solid p() => (box(50, 50, 50) - loft([prof(), prof().move(z: 10)]))
        .fillet(edges.of(faces.tagged("bore")), r: 1);`);
    assert(e.message.canFind("lost its name") && e.message.canFind("a loft"), e.message);
}

// tags: no ';' nor blank ones (a STEP file would change them), dots only between a module and a name,
// tags lost in a foreach told, removeTag's hint telling tags and references apart
unittest
{
    assert(error(`@part Solid p() { auto b = box(1, 1, 1); b.faces.top.addTag("a;b"); return b; }`)
        .message.canFind("cannot hold ';'"));
    assert(error(`@part Solid p() => box(1, 1, 1).addTag("  ");`).message.canFind("blank"));
    assert(error(`@part Solid p() { auto s = sketch(); s.circle(s.point(0, 0), d: 2).addTag(" "); return box(1, 1, 1); }`)
        .message.canFind("blank"));
    foreach (t; [".x", "x.", "a..b"])
        assert(error(`@part Solid p() => box(1, 1, 1).addTag("` ~ t ~ `");`).message.canFind("is not a tag"), t);
    auto e = error(`@part Solid p() => box(1, 1, 1).addTag("sub.deep.z");`);
    assert(e.message.canFind("only be given in module sub.deep") && e.suggestion.canFind("'z' without the dot"),
        e.message ~ " " ~ e.suggestion);
    e = error(`@part Solid p() { Solid[] arr = [box(1, 1, 1), box(2, 2, 2)];
        foreach (s; arr)
            s.addTag("all");
        return arr[0]; }`);
    assert(e.message.canFind("would be lost") && e.suggestion.canFind("arr[i].addTag"), e.message);
    // used in the loop too: not lost
    expectOut(`Solid[] arr = [box(1, 1, 1)];
        Solid[] kept;
        foreach (s; arr) { s.addTag("all"); kept ~= s; }
        writeln(kept[0].tags);`, `["all"]`);
    e = error(`@part Solid p() { auto b = box(1, 1, 1).addTag("body").addTag("pin", at: vec(0, 0, 0));
        b.removeTag("nothere"); return b; }`);
    assert(e.suggestion.canFind("its tags: body") && e.suggestion.canFind("its references: pin"), e.suggestion);
    assert(error(`@part Solid p() { auto s = sketch(); auto c = s.circle(s.point(0, 0), d: 2); c.removeTag("x");
        return box(1, 1, 1); }`).message.canFind("this circle is not tagged"));
}

// ---------------------------------------------------------------- profiles in planes, tiles, sketches (bug hunt 2026-10-20)

unittest
{
    // tiles with no gap touch one another: joined into one area, a valid profile (r - t was 300 mm², the cut invalid)
    expectOut(q{
        auto r = rect(40.mm, 40.mm);
        auto t = r.tiles(kind: "square", size: 10.mm);
        auto b = box(40, 40, 5).cut(t, on: faces.top, depth: 1.mm);
        writeln((r - t).isEmpty, " ", b.volume, " ", b.isValid, " ", (t & rect(10.mm, 10.mm)).area, " ",
            (r - r.tiles(kind: "hex", size: 10.mm)).isEmpty, " ", (r - r.tiles(kind: "voronoi", size: 10.mm)).isEmpty);
    }, "true 6400 mm^3 true 100 mm^2 true true");
}

unittest
{
    // a half section drawn on XZ turns round world Z: with axis: Z, an Axis along Z, or no axis (round its
    // upright y); on a face, a direction alone goes through the sketch's origin; a section's default too
    expectOut(q{
        auto s = sketch(XZ);
        s.rect(s.point(5, 0, fixed: true), w: 20.mm, h: 10.mm);
        auto a = s.profile.revolve(axis: Z);
        auto d = s.profile.revolve();
        auto x = s.profile.revolve(axis: axis(origin: vec(0, 0, 0), direction: Z));
        writeln(a.bbox.min, a.bbox.max, " ", d.bbox.min, d.bbox.max, " ", x.bbox.max);
        auto top = box(20, 20, 10).sketch(faces.top);
        top.rect(top.point(5, 0, fixed: true), w: 5.mm, h: 3.mm);
        writeln(top.profile.revolve(axis: Y).bbox.min, top.profile.revolve().bbox.min);
        writeln(box(40, 40, 40).section(XZ).move(x: 30.mm).revolve().bbox.max);
    }, "[-25 mm, -25 mm, 0 mm][25 mm, 25 mm, 10 mm] [-25 mm, -25 mm, 0 mm][25 mm, 25 mm, 10 mm] [25 mm, 25 mm, 10 mm]\n"
        ~ "[-10 mm, 0 mm, 0 mm][-10 mm, -10 mm, 10 mm]\n[50 mm, 50 mm, 40 mm]");
    // Y is across XZ: not an axis in its plane
    auto d = errorIn(q{
        auto s = sketch(XZ);
        s.rect(s.point(5, 0, fixed: true), w: 20.mm, h: 10.mm);
        s.profile.revolve(axis: Y);
    });
    assert(d.message.canFind("axis must lie in the profile's plane") && d.suggestion.canFind("world"), d.message);
}

unittest
{
    // booleans of profiles off XY: one of no place is taken into the other's plane, two in one plane combine,
    // two planes are an error (they did nothing, silently)
    expectOut(q{
        auto mz = rect(20.mm, 10.mm).move(z: 2.mm);
        writeln((mz - circle(d: 2.mm)).area, " ", (mz & rect(10.mm, 10.mm)).area, " ", (mz - circle(d: 2.mm)).bbox.min);
        auto b = box(20, 10, 5);
        writeln((b.section(XY.offset(2.mm)) - circle(d: 2.mm)).area);
        auto s = b.sketch(faces.front);
        s.circle(s.origin, d: 4.mm);
        writeln((b.section(XZ.offset(5.mm)) - s.profile).area);
    }, "196.858 mm^2 100 mm^2 [-10 mm, -5 mm, 2 mm]\n196.858 mm^2\n87.4336 mm^2");
    auto d = errorIn(q{
        auto b = box(20, 10, 5);
        auto s = b.sketch(faces.front);
        s.circle(s.origin, d: 4.mm);
        writeln((b.section(XZ) - s.profile).area);
    });
    assert(d.code == Code.type && d.message.canFind("different planes") && d.span.line == 7, d.message);
}

unittest
{
    // tiles and hull of a profile drawn on a face stay on it (they cut nothing); tiles of a section work
    expectOut(q{
        auto b = box(40, 40, 10);
        auto s = b.sketch(faces.front);
        s.rect(center: s.origin, w: 30.mm, h: 6.mm);
        auto cells = s.profile.tiles(kind: "square", size: 5.mm, gap: 1.mm);
        writeln(b.volume - b.cut(cells, depth: 1.mm).volume, " ", cells.area);
        auto h = hull(s.profile, circle(d: 2.mm));
        writeln(b.volume - b.cut(h, depth: 1.mm).volume, " ", h.area);
        auto sec = box(40, 40, 40).section(XZ).tiles(kind: "hex", size: 6.mm, gap: 1.mm);
        writeln(sec.bbox.min, sec.bbox.max);
    }, "96 mm^3 96 mm^2\n180 mm^3 180 mm^2\n[-20 mm, 0 mm, 0 mm][20 mm, 0 mm, 40 mm]");
}

unittest
{
    // a difference that takes everything is an empty Profile, not a Solid; extruding it says so
    expectOut("writeln(cutAway(rect(10.mm, 10.mm), rect(20.mm, 20.mm)).isEmpty, \" \", "
        ~ "(rect(10.mm, 10.mm) & rect(5.mm, 5.mm).move(x: 50.mm)).isEmpty);", "true true",
        "Profile cutAway(Profile a, Profile b) => a - b;");
    auto d = errorIn("(rect(10.mm, 10.mm) - rect(20.mm, 20.mm)).extrude(2.mm);");
    assert(d.message.canFind("the profile is empty"), d.message);
    // a hull of profiles in two planes is a solid: extruding it says what it is
    d = errorIn("hull(rect(10.mm, 10.mm).move(z: 3.mm), rect(10.mm, 10.mm).rotate(x: 90.deg)).extrude(2.mm);");
    assert(d.message.canFind("this is a Solid, not a profile"), d.message);
}

unittest
{
    // a sketch's rect with w: alone is a square, as the profile's
    expectOut(q{
        auto s = sketch();
        s.rect(center: s.point(0, 0, fixed: true), w: 30.mm);
        auto t = sketch();
        t.rect(t.point(0, 0, fixed: true), w: 12.mm);
        writeln(s.profile.bbox.size, " ", s.dof, " ", t.profile.bbox.size, " ", t.dof);
    }, "[30 mm, 30 mm, 0 mm] 0 [12 mm, 12 mm, 0 mm] 0");
}

unittest
{
    // a profile on a face or in a plane: bbox, spots, contains and outline all where it lies
    expectOut(q{
        auto b = box(40, 20, 10);
        auto s = b.sketch(faces.front);
        s.circle(s.origin, d: 4.mm);
        auto p = s.profile;
        writeln(p.bbox.min, p.bbox.max, " ", p.spots(1), " ", p.contains(vec(0.mm, -10.mm, 5.mm)));
        auto sec = b.section(XZ);
        writeln(sec.contains(vec(0.mm, 0.mm, 5.mm)), " ", sec.contains(vec(0.mm, 5.mm)));
        foreach (q; box(20, 10, 10).section(XZ).outline(4))
            writeln(q.at, " ", q.normal);
    }, "[-2 mm, -10 mm, 3 mm][2 mm, -10 mm, 7 mm] [[0 mm, -10 mm, 5 mm]] true\ntrue false\n"
        ~ "[10 mm, 0 mm, 5 mm] [1, 0, 0]\n[0 mm, 0 mm, 10 mm] [0, 0, 1]\n[-10 mm, 0 mm, 5 mm] [-1, 0, 0]\n"
        ~ "[0 mm, 0 mm, 0 mm] [0, 0, -1]");
}

unittest
{
    // a bow tie: an error where it is drawn, not an empty error at 1:1 or an invalid part
    auto d = errorIn(q{
        auto s = sketch();
        auto a = s.point(0, 0, fixed: true);
        auto b = s.point(10, 0, fixed: true);
        auto c = s.point(10, 10, fixed: true);
        auto d = s.point(0, 10, fixed: true);
        s.polyline([a, c, b, d]);
        writeln(s.profile.area);
    });
    assert(d.code == Code.sketch && d.message.canFind("the outline drawn at line 9 crosses itself") && d.span.line == 9,
        d.message);
}

unittest
{
    // smooth closed curves as a sketch's closed spline: symmetric whatever the first point; a closed
    // spline whose last point repeats the first is the same curve
    expectOut(q{
        Vec2[] p;
        foreach (i; 0 .. 4)
            p ~= vec(10.mm * cos(i * 90.deg), 10.mm * sin(i * 90.deg));
        auto a = polygon(p, smooth: true);
        auto b = polygon([p[1], p[2], p[3], p[0]], smooth: true);
        writeln(a.bbox.min, a.bbox.max, " ", b.bbox.min, b.bbox.max);
        auto sp = spline([vec(20, 0, 0), vec(0, 20, 0), vec(-20, 0, 0), vec(0, -20, 0)], closed: true);
        auto sq = spline([vec(20, 0, 0), vec(0, 20, 0), vec(-20, 0, 0), vec(0, -20, 0), vec(20, 0, 0)], closed: true);
        writeln(circle(d: 0.2.mm).sweep(sp).bbox.max, " ", circle(d: 0.2.mm).sweep(sq).bbox.min);
    }, "[-10 mm, -10 mm, 0 mm][10 mm, 10 mm, 0 mm] [-10 mm, -10 mm, 0 mm][10 mm, 10 mm, 0 mm]\n"
        ~ "[20.1 mm, 20.1 mm, 0.1 mm] [-20.1 mm, -20.1 mm, -0.1 mm]");
}

unittest
{
    // a font not installed: a warning naming it (the text still made with another)
    auto r = runModel(`unittest { auto t = text("HI", size: 5.mm, font: "No Such Font XYZ"); }`);
    bool warned;
    foreach (d; r.diagnostics)
    {
        assert(d.severity != Severity.error, d.message);
        warned = warned || (d.severity == Severity.warning && d.message.canFind("'No Such Font XYZ' is installed"));
    }
    assert(warned);
}

unittest
{
    // shrunk to nothing: an empty profile (all of it, or one region of two); zero heights and depths said plainly
    expectOut(q{
        writeln(rect(20.mm, 10.mm).offset(-5.mm).isEmpty, " ", rect(20.mm, 10.mm).offset(-6.mm).isEmpty, " ",
            circle(d: 10.mm).offset(-5.mm).isEmpty, " ",
            (rect(20.mm, 10.mm) + circle(d: 40.mm).move(x: 50.mm)).offset(-5.5.mm).area);
    }, "true true true 660.52 mm^2");
    auto d = errorIn("rect(20.mm, 10.mm).extrude(0.mm);");
    assert(d.message == "the height must not be zero", d.message);
    d = errorIn("box(10, 10, 10).cut(rect(2.mm, 2.mm), on: faces.top, depth: 0.mm);");
    assert(d.message == "depth must not be zero", d.message);
}

unittest
{
    // sketch errors: a fillet's at the s.fillet call; one on no corner is an error, not ignored
    auto d = errorIn(q{
        auto s = sketch();
        auto r = s.rect(s.point(0, 0, fixed: true), w: 20.mm, h: 10.mm);
        s.fillet(r[0].end, 12.mm);
        writeln(s.profile.area);
    });
    assert(d.message.canFind("too big") && d.span.line == 6, format("%s %s", d.span.line, d.message));
    d = errorIn(q{
        auto s = sketch();
        auto o = s.point(0, 0, fixed: true);
        s.circle(o, r: 5.mm);
        s.fillet(o, 2.mm);
        writeln(s.profile.area);
    });
    assert(d.message.canFind("a fillet rounds a corner") && d.span.line == 7, format("%s %s", d.span.line, d.message));
    // an arc's own equation in a conflict: its line, not the sketch's
    d = errorIn(q{
        auto s = sketch();
        auto o = s.point(0, 0, fixed: true);
        auto a = s.point(10, 0, fixed: true);
        auto b = s.point(0, 5, fixed: true);
        s.arc(o, a, b);
        s.line(b, o);
        s.line(o, a);
        writeln(s.profile.area);
    });
    assert(d.message.canFind("lines 5, 6, 7, 8"), d.message);
    // s.paths names the conflict as s.profile does
    d = errorIn(q{
        auto s = sketch();
        auto a = s.point(0, 0, fixed: true);
        auto l = s.line(a, s.point(10, 3));
        s.horizontal(l);
        s.vertical(l);
        s.length(l, 5.mm);
        writeln(s.paths.length);
    });
    assert(d.message.canFind("check the constraints at line"), d.message);
}

unittest
{
    // the methods' own names, not the solver's; types and members suggested from the sketch's own
    auto d = errorIn("auto s = sketch(); s.on(s.point(1, 1), s.point(2, 2));");
    assert(d.message == "s.on needs a point and a line, a circle, an arc or an ellipse", d.message);
    d = errorIn("auto s = sketch(); s.equal(s.line(vec(0, 0), vec(10, 0)), s.circle(vec(0, 0), r: 5.mm));");
    assert(d.message == "s.equal needs two lines, or two circles or arcs", d.message);
    d = errorIn("auto s = sketch(); s.tangent(s.point(3, 3), s.line(vec(0, 0), vec(10, 0)));");
    assert(d.message.canFind("s.tangent needs"), d.message);
    d = errorIn("auto s = sketch(); s.equal(s.line(vec(0, 0), vec(10, 0)));");
    assert(d.message == "missing argument 'b' for s.equal(a, b)", d.message);
    d = errorIn("auto s = sketch(); writeln(s.circle(vec(0, 0), r: 5.mm).start);");
    assert(d.suggestion == "its members: center, radius", d.suggestion);
    d = errorIn("Point q = sketch().point(1, 2);");
    assert(d.suggestion == "did you mean 'SketchPoint'?", d.suggestion);
    expectOut("SketchPoint p = sketch().point(1, 2); writeln(p.x);", "1 mm");
}

unittest
{
    // fills: one in no area is a warning there; every area emptied is said so, at the fill
    auto r = runModel(q{unittest {
        auto s = sketch();
        s.circle(s.point(0, 0, fixed: true), r: 10.mm);
        s.fill(vec(50.mm, 0.mm));
        writeln(s.profile.area);
    }});
    bool warned;
    foreach (d; r.diagnostics)
        warned = warned || (d.severity == Severity.warning && d.message.canFind("lies in no area") && d.span.line == 4);
    assert(warned);
    auto d = errorIn(q{
        auto s = sketch();
        s.circle(s.point(0, 0, fixed: true), r: 10.mm);
        s.fill(vec(0.mm, 0.mm), full: false);
        writeln(s.profile.area);
    });
    assert(d.message.canFind("every area of the outline is left empty") && d.span.line == 6, d.message);
}

unittest
{
    // an SVG's circles and ellipses as true curves (a circle of r 5 was 77.57 mm²), turned and stretched too
    auto dir = buildPath(tempDir, "hcad-svg-round");
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    write(buildPath(dir, "round.svg"), `<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="20mm" viewBox="0 0 100 20">
        <circle cx="10" cy="10" r="5"/>
        <g transform="translate(50 0) rotate(30)"><ellipse cx="5" cy="5" rx="4" ry="2"/></g>
        <g transform="translate(70 0) scale(2 1)"><circle cx="5" cy="5" r="3"/></g></svg>`);
    auto it = make();
    it.root = dir;
    auto r = it.runSource(q{
        unittest { foreach (q; load("round.svg").pieces) writeln(q.area); }
    }, buildPath(dir, "main.hcad"));
    foreach (d; r.diagnostics)
        assert(d.severity != Severity.error, d.message);
    auto log = r.log.map!(l => l.text).join(" ");
    assert(log == "78.5398 mm^2 25.1327 mm^2 56.5487 mm^2", log);
}

unittest
{
    // a sketch of many separate loops: the solver takes its independent parts apart, the profile its
    // holes in one cut (225 holes took 3.5 s)
    import std.datetime.stopwatch : StopWatch, AutoStart;
    auto sw = StopWatch(AutoStart.yes);
    expectOut(q{
        auto s = sketch();
        s.rect(s.point(0, 0, fixed: true), w: 160.mm, h: 160.mm);
        foreach (i; 0 .. 15)
            foreach (j; 0 .. 15)
                s.circle(s.point(10 + i * 10, 10 + j * 10, fixed: true), r: 3.mm);
        writeln(s.profile.area, " ", s.dof);
    }, "19238.3 mm^2 0");
    assert(sw.peek.total!"msecs" < 1500, format("%s ms", sw.peek.total!"msecs"));
}


// ---------------------------------------------------------------- bug hunt 2026-10-20: solids, selectors

unittest
{
    // a profile's depth on a face is positive, the call saying which way: no quiet pocket from a
    // negative extrude, no cut doing nothing
    auto d = errorIn("auto s = box(30, 24, 20).extrude(circle(d: 5.mm), on: faces.top, depth: -30.mm);");
    assert(d.code == Code.type && d.message.canFind("use cut"), d.message);
    d = errorIn("auto s = box(30, 24, 20).cut(circle(d: 5.mm), on: faces.top, depth: -2.mm);");
    assert(d.code == Code.type && d.message.canFind("use extrude"), d.message);
    d = errorIn("auto s = box(30, 24, 20).cut(circle(d: 5.mm), on: faces.top, depth: 0.mm);");
    assert(d.message.canFind("must not be zero"), d.message);
}

unittest
{
    // faces.top on a part turned a little: the face facing up the most; exact as before when square
    expectOut("auto b = box(10, 20, 5).rotate(x: 0.1.deg); writeln(b.faces.top.count);"
        ~ " writeln(box(40, 40, 20).rotate(x: 30.deg).faces.top.count, \" \", box(40, 40, 20).rotate(x: 30.deg).faces.bottom.count);"
        ~ " auto st = box(20, 10, 10) + box(10, 10, 5).move(x: 20.mm); writeln(st.faces.top.count);"
        ~ " auto tw = (box(20, 10, 10) + box(10, 10, 10).move(x: 20.mm, z: 5.mm)).rotate(y: 0.2.deg); writeln(tw.faces.top.count);"
        ~ " writeln(box(10, 20, 5).rotate(x: 0.1.deg).shell(open: faces.top, thickness: 1.mm).volume < 1000 * 1.mm ^^ 3);",
        "1\n1 1\n1\n1\ntrue");
}

unittest
{
    // a curved face faces the way its normal points on the whole: a dome up, a cylinder's whole side no way
    expectOut("auto boss = box(20, 20, 5) + cylinder(d: 10.mm, h: 10.mm).move(z: 5.mm);"
        ~ " writeln(boss.faces.normal(-X).count, \" \", boss.faces.top.count);"
        ~ " auto dome = cylinder(d: 10.mm, h: 10.mm) + sphere(5.mm).move(z: 10.mm);"
        ~ " writeln(dome.faces.top.count, \" \", dome.faces.normal(Z).count);"
        ~ " writeln(sphere(5.mm).faces.normal(Z).count, \" \", box(10, 10, 10).fillet(edges.parallel(Z), r: 2.mm)"
        ~ ".faces.normal(Z).count);",
        "1 1\n1 1\n0 1");
}

unittest
{
    // @parts: Solid.nothing in the list is no part; another empty solid an error with its place;
    // nothing at all, said so
    auto r = runModel("@parts\nSolid[] many() => [box(5, 5, 5), Solid.nothing];\n");
    assert(r.parts.length == 1);
    auto d = error("@parts\nSolid[] many() => [box(5, 5, 5), box(1, 1, 1) - box(3, 3, 3).move(x: -1.mm, y: -1.mm, "
        ~ "z: -1.mm)];\n");
    assert(d.message.canFind("[1] is empty") && d.span.line == 2, d.message);
    r = runModel("@parts\nSolid lid() => Solid.nothing;\n");
    assert(r.parts.length == 0 && r.diagnostics.canFind!(x => x.message.canFind("no parts this time")));
}

unittest
{
    // the sum of an empty Solid[] is an empty solid, as fuse([]) is; of an empty Profile[] an empty profile
    expectOut("Solid[] none; writeln((box(10, 10, 10) + none.sum.move(x: 1.mm)).volume);"
        ~ " Profile[] flat; writeln((rect(2.mm, 2.mm) + flat.sum).area);"
        ~ " writeln([box(1, 1, 1)].filter(s => s.volume > 2 * 1.mm ^^ 3).sum.isEmpty);"
        ~ " int[] n; writeln(n.sum);",
        "1000 mm^3\n4 mm^2\ntrue\n0");
}

unittest
{
    // a condition is true or false (or an integer, as in D): a length, a solid is a mistake
    auto d = errorIn("auto s = box(10, 10, 10).fillet(edges.filter(e => e.length), r: 1.mm);");
    assert(d.code == Code.type && d.message.canFind("true or false, not Length"), d.message);
    expectErr("if (3.mm) writeln(1);", Code.type);
    expectErr("if (box(1, 1, 1)) writeln(1);", Code.type);
    expectErr("auto x = \"a\" && true;", Code.type);
    expectOut("writeln([1, 2, 3, 4].filter(x => x % 2), \" \", !0);", "[1, 3] true");
}

unittest
{
    // selectors combined from one solid stay of it: counted, gone through
    expectOut("auto s = box(30, 20, 10); writeln((s.faces.top + s.faces.bottom).count);"
        ~ " foreach (f; s.faces.top + s.faces.bottom) writeln(f.center.z);", "2\n0 mm\n10 mm");
}

unittest
{
    // a tapered cut through: as deep as the body, not a closing outline 100 mm on
    expectOut("auto a = box(30, 24, 20).cut(circle(d: 10.mm), on: faces.top, through: true, taper: 3.deg);"
        ~ " writeln(a.volume < 30.mm * 24.mm * 20.mm - 1000 * 1.mm ^^ 3, \" \", a.faces.count);", "true 7");
}

unittest
{
    // the wording of face extrude and thread errors
    auto d = errorIn("auto a = box(30, 24, 10).extrude(faces.top, depth: 5.mm, along: vec(1, 0, 0));");
    assert(d.message.canFind("extrude failed") && !d.message.canFind("push/pull"), d.message);
    d = errorIn("auto a = (box(20, 20, 15) - cylinder(d: 6.8.mm, h: 40.mm, center: true))"
        ~ ".thread(faces.filter(f => !f.isPerpendicular(Z)), \"M8\");");
    assert(d.message.canFind("matched 5 faces"), d.message);
}

unittest
{
    // nextTo along an axis as before; an oblique direction along it, the boxes touching
    expectOut("auto b = box(30, 24, 20); auto s = box(4, 6, 8).move(x: -70.mm);"
        ~ " writeln(s.nextTo(b, X, gap: 1.mm).bbox.min); writeln(s.nextTo(b, vec(1, 2, 0)).bbox.min);",
        "[16 mm, -3 mm, 0 mm]\n[5.5 mm, 12 mm, 0 mm]");
}

unittest
{
    // seams are no edges: a cylinder's side has no straight edge to round; a sphere none at all
    expectOut("writeln(cylinder(d: 10.mm, h: 10.mm).edges.lines.count, \" \", cylinder(d: 10.mm, h: 10.mm).edges.count);",
        "0 2");
    auto d = errorIn("auto a = cylinder(d: 10.mm, h: 10.mm).fillet(edges.parallel(Z), r: 1.mm);");
    assert(d.suggestion.canFind("seam"), d.message ~ " / " ~ d.suggestion);
    d = errorIn("auto a = sphere(5.mm).fillet(edges, r: 1.mm);");
    assert(d.suggestion.canFind("seam") && !d.message.canFind("suitable"), d.message);
}

unittest
{
    mixin(slowTest);
    // fillet and chamfer failures: a size that works, no kernel jargon, rounds of one radius made in turn
    auto d = errorIn("auto a = box(10, 10, 10).fillet(edges.of(faces.top), r: 2.mm).fillet(edges.parallel(Z), r: 2.mm);");
    assert(!d.message.canFind("NotDone") && d.suggestion.canFind("in one fillet"), d.message ~ " / " ~ d.suggestion);
    d = errorIn("auto a = box(10, 10, 10).fillet(edges.parallel(Z), r: 2.mm).chamfer(edges.of(faces.top), d: 3.mm);");
    assert(d.suggestion.canFind("up to about 1.9") && !d.suggestion.canFind("0.522"), d.suggestion);
    expectOut("writeln(box(10, 10, 10).fillet(edges.parallel(Z), r: 2.mm).chamfer(edges.of(faces.top), d: 1.mm).isValid);",
        "true");
}

unittest
{
    // the axis of a curved face; a frame on one says how to get it
    expectOut("auto c = cylinder(d: 20.mm, h: 30.mm).move(x: 5.mm); auto ax = c.axis(faces.largest);"
        ~ " writeln(ax.direction, \" \", ax.origin.x);", "[0, 0, 1] 5 mm");
    auto d = errorIn("auto f = cylinder(d: 20.mm, h: 30.mm).frame(faces.largest);");
    assert(d.message.canFind("body.axis(faces"), d.message);
    d = errorIn("auto a = box(10, 10, 10).axis(faces.top);");
    assert(d.message.canFind("turned round an axis"), d.message);
    d = errorIn("auto a = box(10, 10, 10).fillet(faces.top, r: 1.mm);");
    assert(d.message.canFind("an edge selector") && !d.message.canFind("Selector"), d.message);
}

unittest
{
    // bounding boxes: a fill's plate boxed where it is trimmed, no 1e-7 past a part's corners
    expectOut("Path rim = path([vec(0.mm, 0.mm, 0.mm), vec(10.mm, 0.mm, 0.mm), vec(10.mm, 10.mm, 5.mm),"
        ~ " vec(0.mm, 10.mm, 0.mm)], closed: true); auto t = fill(rim, through: [vec(5.mm, 5.mm, 8.mm)]).thicken(1.mm);"
        ~ " writeln(t.bbox.min.x > -1.mm, \" \", t.bbox.max.x < 11.mm, \" \", t.bbox.min.z);"
        ~ " writeln(box(10, 10, 10).scale(z: 2).bbox.min.z, \" \", loft([circle(d: 20.mm), circle(d: 10.mm).move(z: 50.mm)])"
        ~ ".bbox.min.z, \" \", sphere(5.mm).scale(z: 2).bbox.min);",
        "true true 0 mm\n0 mm 0 mm [-5 mm, -5 mm, -10 mm]");
}

unittest
{
    mixin(slowTest);
    // projections: a loft's straight sides stay straight; a twisted prism's shadow is made
    expectOut("auto p = loft([rect(20.mm, 10.mm), rect(10.mm, 30.mm).move(z: 50.mm)]).projection;"
        ~ " writeln(p.area, \" \", p.bbox.max.x);", "500 mm^2 10 mm");
    expectOut("auto p = rect(20.mm, 10.mm).extrude(30.mm, twist: 60.deg).projection;"
        ~ " writeln(p.area > 310 * 1.mm ^^ 2 && p.area < 325 * 1.mm ^^ 2);", "true");
}

unittest
{
    // a hole closing as the solid grows: filled, the result well defined
    expectOut("auto s = box(30, 24, 10) - cylinder(d: 8.mm, h: 30.mm, center: true);"
        ~ " writeln(s.offset(4.5.mm, sharp: true).volume, \" \", s.offset(4.5.mm).bbox.size);",
        "24453 mm^3 [39 mm, 33 mm, 19 mm]");
}

unittest
{
    // symmetric: the profile is the middle of the solid, tapered or twisted too
    expectOut("auto p = rect(20.mm, 10.mm);"
        ~ " writeln(p.extrude(10.mm, taper: 10.deg, symmetric: true).section(XY).bbox.size);"
        ~ " writeln(p.extrude(10.mm, twist: 90.deg, symmetric: true).section(XY).bbox.size);"
        ~ " auto t = p.extrude(10.mm, taper: 10.deg, symmetric: true); writeln(t.bbox.min.z, \" \", t.bbox.max.z,"
        ~ " \" \", t.section(XY.offset(4.mm)).bbox.size == t.section(XY.offset(-4.mm)).bbox.size);",
        "[20 mm, 10 mm, 0 mm]\n[20 mm, 10 mm, 0 mm]\n-5 mm 5 mm true");
}

unittest
{
    mixin(slowTest);
    // a Minkowski sum with a box: swept along its sides, in a moment
    import std.datetime.stopwatch : StopWatch, AutoStart;
    auto sw = StopWatch(AutoStart.yes);
    expectOut("auto m = minkowski(box(40, 40, 10) - cylinder(d: 10.2.mm, h: 30.mm, center: true), box(2, 2, 2, center: true));"
        ~ " writeln(m.bbox.size, \" \", m.isValid, \" \", m.volume > 20500 * 1.mm ^^ 3 && m.volume < 20700 * 1.mm ^^ 3);",
        "[42 mm, 42 mm, 12 mm] true true");
    assert(sw.peek.total!"seconds" < 20);
}


// ------------------------------------------------- the libraries' fixes (bug hunt of 2026-10-20)

/// A model with no errors and no warnings.
void clean(EvalResult r)
{
    foreach (d; r.diagnostics)
        assert(d.severity == Severity.note, d.message);
}

unittest
{
    mixin(slowTest);
    // hole(): every kind within its depth, at every size; an insert, a counterbore's or a countersink's seat
    // deeper than the hole is an error that says so; a counterbore takes a chamfer, a countersink refuses one
    clean(runModel(q{
        import std.hardware;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            foreach (s; [M2, M2_5, M3, M4, M5, M6, M8, M10, M12])
                foreach (k; ["clearance", "tap", "insert", "counterbore", "countersink", "ribs"])
                    assert(abs(hole(s, 17.mm, k).bbox.min.z + 17.mm) < 0.001.mm, s.name ~ " " ~ k);
            immutable cb = "counterbore";
            assert(hole(M3, 5.mm, cb, chamfer: 1.mm).volume > hole(M3, 5.mm, cb).volume + 5 * 1.mm ^^ 3, "chamfered");
            assert(hole(M3, 5.mm, cb, chamfer: 1.mm).bbox.size.x > hole(M3, 5.mm, cb).bbox.size.x + 1.9.mm, "round the head");
        }
    }));
    assert(error("import std.hardware;\n@part Solid p() => box(20, 20, 3) - hole(M3, 3.mm, \"insert\").move(z: 3);")
        .message.canFind("the M3 insert is 5.7 mm long, deeper than the hole's 3 mm"));
    assert(error("import std.hardware;\n@part Solid p() => box(20, 20, 3) - hole(M3, 3.mm, \"counterbore\").move(z: 3);")
        .message.canFind("the counterbore for the M3 head is 3.2 mm deep"));
    assert(error("import std.hardware;\n@part Solid p() => box(20, 20, 3) - hole(M12, 5.mm, \"countersink\").move(z: 5);")
        .message.canFind("the countersink for the M12 head"));
    assert(error("import std.hardware;\n@part Solid p() => hole(M3, 5.mm, \"countersink\", chamfer: 1.mm);")
        .message.canFind("chamfer already"));
}

unittest
{
    // the hardware library's checks: what has no size says so, at the call
    immutable hw = "import std.hardware;\n";
    assert(error(hw ~ "@part Solid p() => nut(ST2_9);").message.canFind("ST2.9 is a self-tapping screw"));
    assert(error(hw ~ "@part Solid p() => box(10, 10, 10) - nutTrap(ST2_9, 3.mm);").message.canFind("no nut"));
    assert(error(hw ~ "@part Solid p() => box(30, 30, 10) - squareNutSlot(M10, 10.mm);")
        .message.canFind("go from M2 to M8, not M10"));
    assert(error(hw ~ "@part Solid p() => setScrew(M12, 3.mm, point: \"flat\");").message.canFind("6 mm long at least"));
    assert(error(hw ~ "@part Solid p() => screw(M3, 0.3.mm);").message.canFind("1.5 mm long at least"));
    assert(error("import std.snaps;\n@part Solid p() => snapHook(lead: 90.deg);").message.canFind("from 5°"));
    assert(error("import std.snaps;\n@part Solid p() => snapHook(lead: 0.deg);").message.canFind("from 5°"));
    assert(error("import std.gears;\n@part Solid p() => spurGear(2.mm, 20, 5.mm, backlash: 3.mm);")
        .message.canFind("keep it below"));
    assert(error("import std.gears;\n@part Solid p() => rack(2.mm, 10, 5.mm, pressure: 40.deg);")
        .message.canFind("pressure angle goes from above 0° to 30°"));
}

unittest
{
    mixin(slowTest);
    // a threaded nut's hole is tagged as the plain one's; a left-handed tapped hole; short screws are fine
    clean(runModel(q{
        import std.hardware;
        import std.threads;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            auto n = nut(M3, threaded: true);
            assert(n.faces.tagged("hardware.bore").count > 10 && n.faces.tagged("hardware.bore").count < n.faces.count);
            auto l = tappedHole(8.mm, 1.25.mm, 10.mm, left: true), r = tappedHole(8.mm, 1.25.mm, 10.mm);
            assert(abs(l.volume - r.volume) < 0.01 * 1.mm ^^ 3 && (l - r).volume > 1.mm ^^ 3, "left-handed");
            assert(setScrew(M12, 6.mm, point: "flat").volume > 0.mm ^^ 3 && screw(M3, 1.5.mm).volume > 0.mm ^^ 3);
        }
    }));
}

unittest
{
    mixin(slowTest);
    // gears cut as a rack cuts them: small pinions, undercut, mesh with a large wheel and a rack with no
    // backlash at all
    clean(runModel(q{
        import std.gears;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable m = 2.mm;
            auto wheel = spurGear(m, 40, 3.mm, backlash: 0.mm);
            foreach (z; [6, 10, 14])
            {
                auto g = spurGear(m, z, 3.mm, backlash: 0.mm);
                auto bar = rack(m, 2 * z + 6, 3.mm, backlash: 0.mm).move(x: -(z + 3) * PI * m, y: -m * z / 2);
                foreach (k; 0 .. 6)
                {
                    immutable t = 360.0 / z * k / 6;
                    assert((g.rotate(z: t) & wheel.rotate(z: 180 + 180.0 / 40 - t * z / 40)
                        .move(x: centerDistance(m, z, 40))).volume == 0.mm ^^ 3, "z$(z) with z40 at $(t)");
                    assert((g.rotate(z: t - 90) & bar.move(x: t / 180.0 * PI * m * z / 2)).volume == 0.mm ^^ 3,
                        "z$(z) on the rack at $(t)");
                }
            }
        }
    }));
}

unittest
{
    mixin(slowTest);
    // shadowCase on a slanted plane: quick, one solid each, as tall as the part along the normal; a flat part
    // with the default lip; a round part's walls round, its lip three faces
    clean(runModel(q{
        import std.enclosures;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            immutable n = vec(1, 1, 1).normalized;
            auto c = shadowCase(sphere(10.mm), on: plane(origin: vec(0.mm, 0.mm, 0.mm), normal: n));
            assert(c.base.pieces.length == 1 && c.lid.pieces.length == 1 && (c.base & c.lid).volume < 0.01 * 1.mm ^^ 3);
            assert(c.base.volume > 2000 * 1.mm ^^ 3 && c.lid.volume > 2000 * 1.mm ^^ 3, "whole");
            auto turned = (c.base + c.lid)
                .rotate(acos(n.z), axis: axis(origin: vec(0.mm, 0.mm, 0.mm), direction: cross(n, Z).normalized));
            assert(abs(turned.bbox.size.z - 24.5.mm) < 0.01.mm, "20 mm of sphere, 0.5 mm over it, two walls");
            auto flat = shadowCase(box(20.mm, 20.mm, 4.mm));
            assert((flat.base & flat.lid).volume < 0.01 * 1.mm ^^ 3 && flat.base.bbox.max.z < 4.5.mm, "a lower lip");
            auto round = shadowCase(cylinder(d: 20.mm, h: 20.mm));
            assert(abs(round.base.bbox.min.x + 12.5.mm) < 0.001.mm, "round walls");
            assert(round.base.faces.tagged("enclosures.lip").count == 3, "the lip's faces");
        }
    }));
    assert(error("import std.enclosures;\n@part Solid p() => shadowCase(box(20, 20, 4), lip: 3.mm).base;")
        .message.canFind("the lip reaches the lid's top"));
}

unittest
{
    mixin(slowTest);
    // splitJoint on a tube: pins and dowels on its wall, a wedged scarf, no tenon in its hollow middle;
    // fingers on a slanted cut leave no loose slivers; keys: as count:, count: as keys:; joinParts with a
    // seated dovetail and a barbed tenon
    clean(runModel(q{
        import std.joints;
        import std.molds;
        immutable tube = cylinder(d: 30.mm, h: 100.mm) - cylinder(d: 22.mm, h: 300.mm, center: true);
        immutable mid = plane(origin: vec(0.mm, 0.mm, 50.mm), normal: Z);
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            foreach (k; ["pins", "dowels", "kanawa"])
            {
                auto j = splitJoint(tube, mid, kind: k);
                assert(j.a.pieces.length == 1 && j.b.pieces.length == 1, k);
                assert(tube.volume - j.a.volume - j.b.volume > 5 * 1.mm ^^ 3 && (j.a & j.b).volume == 0.mm ^^ 3, k);
            }
            auto f = splitJoint(box(20.mm, 20.mm, 100.mm),
                plane(origin: vec(0.mm, 0.mm, 50.mm), normal: vec(0.2, 0, 1).normalized), kind: "fingers");
            assert(f.a.pieces.length == 1 && f.b.pieces.length == 1, "no slivers");
            auto beam = box(20.mm, 20.mm, 100.mm);
            assert(splitJoint(beam, mid, kind: "pins", keys: 3).a.volume == splitJoint(beam, mid, kind: "pins", count: 3).a.volume);
            assert(splitFlat(beam, mid, count: 1).keys.length == 1);
            immutable post = box(20.mm, 20.mm, 60.mm), shelf = box(20.mm, 20.mm, 40.mm).move(z: 60.mm);
            immutable top = plane(origin: vec(0.mm, 0.mm, 60.mm), normal: Z);
            foreach (k; ["koshikake", "barbed"])
            {
                auto j = joinParts(post, shelf, top, kind: k);
                assert((j.a & j.b).volume == 0.mm ^^ 3 && j.a.volume < post.volume && j.b.volume > shelf.volume, k);
            }
        }
    }));
    assert(error("import std.joints;\nimmutable tube = cylinder(d: 30.mm, h: 100.mm) - cylinder(d: 22.mm, h: 300.mm, center: true);\n"
        ~ "@part Solid p() => splitJoint(tube, plane(origin: vec(0.mm, 0.mm, 50.mm), normal: Z)).a;")
        .message.canFind("hollow or narrow in the middle of the cut"));

    // WORKAROUND (OpenCascade 7.9, boolean cut) in splitJoint: the wedge's hole of a kanawa on a tube cut
    // from a piece once joined fails; the library cuts it from each part before joining them
    stillBroken(fails(q{
        immutable tube = cylinder(d: 30.mm, h: 100.mm) - cylinder(d: 22.mm, h: 300.mm, center: true);
        immutable s = sqrt(PI / 4 * (900 - 484)) * 1.mm, len = 0.6 * s, far = 4 * s, g = 0.2.mm;
        immutable hook = 0.2 * s, lip = min(0.15 * len, 0.3 * s);
        Solid span(Length x0, Length x1, Length y0, Length y1, Length z0, Length z1, Length c) =>
            box(x1 - x0 + 2 * c, y1 - y0 + 2 * c, z1 - z0 + 2 * c)
                .move(x: (x0 + x1) / 2, y: (y0 + y1) / 2, z: z0 - c + 50.mm);
        @part Solid a()
        {
            auto up = span(-far, far, -far, 0.mm, -0.01.mm, len, 0.mm)
                + span(-far, far, -0.01.mm, hook, len - lip, len, 0.mm);
            auto down = span(-far, far, 0.mm, far, -len, 0.01.mm, g)
                + span(-far, far, -hook, 0.01.mm, -len, -len + lip, g);
            immutable w = 0.18 * s, reach = 2 * s, taper = reach / 20;
            auto hole = loft([rect(w + 2 * g, w + 2 * g).move(z: -reach / 2),
                    rect(w + taper + 2 * g, w + taper + 2 * g).move(z: reach / 2)])
                .rotate(x: -90)
                .move(z: 50.mm);
            auto below = tube.halves(plane(origin: vec(0.mm, 0.mm, 50.mm), normal: Z)).below;
            return (below - down) + (tube & up) - hole;
        }
    }), "OpenCascade's cut of a kanawa's wedge hole from a tube's piece once joined");
}

unittest
{
    mixin(slowTest);
    // kerf on a strap narrower than six pitches: one piece, its slots shorter; mold on a plane at 45°: its
    // pry notches cut, as on any other plane
    clean(runModel(q{
        import std.flex;
        import std.molds;
        @part Solid p() => box(1, 1, 1);
        unittest
        {
            foreach (w; [8.mm, 12.mm, 15.mm])
            {
                auto b = box(120.mm, w, 3.mm);
                auto k = kerf(b, box(40.mm, w + 10.mm, 10.mm, center: true));
                assert(k.pieces.length == 1 && k.volume < b.volume - 100 * 1.mm ^^ 3, "strap $(w)");
            }
            auto at = plane(origin: vec(0.mm, 0.mm, 0.mm), normal: vec(1, 1, 0).normalized);
            assert(mold(sphere(10.mm), at, pry: false).a.volume - mold(sphere(10.mm), at).a.volume > 50 * 1.mm ^^ 3);
        }
    }));
    assert(error("import std.flex;\n@part Solid p() => kerf(box(120, 12, 3), box(40, 20, 10, center: true), length: 20.mm);")
        .message.canFind("cut the part apart"));
}


unittest
{
    mixin(slowTest);
    // a roll along a mitred path (no bend:): up, a twist and a guide sweep each straight stretch with
    // its roll, the stretches meeting in the mitre planes; the volume stays the area times the length
    expectOut(`auto l = path([vec(0, 0, 0), vec(40, 0, 0), vec(40, 40, 0)]);
        auto bar = rect(10.mm, 2.mm);
        writeln(v(bar.sweep(l, up: Z)), " ", v(bar.sweep(l, twist: 90.deg)), " ",
            v(bar.sweep(l, guide: path([vec(0, 0, 5), vec(40, 0, 5), vec(40, 40, 5)]))));
        auto z = circle(d: 4.mm).sweep(path([vec(0, 0, 0), vec(20, 0, 0), vec(20, 20, 10), vec(0, 20, 30)]),
            twist: 180.deg);
        writeln(abs(z.volume / (PI * 4 * (20 + sqrt(500.0) + sqrt(800.0)) * 1.mm ^^ 3) - 1) < 1e-4);`,
        "1600 1600 1600\ntrue", "import std.math;\ndouble v(Solid s) => round(s.volume / 1.mm ^^ 3 * 10) / 10;   // to 0.1 mm³");
    // a gentle kink is a corner, not a bend: no warning that the profile folds, and a valid solid
    auto r = runModel(`@part Solid a() => circle(d: 4.mm).sweep(path([vec(0, 0, 0), vec(40, 0, 0), vec(80, 10, 0)]), up: Z);`);
    assert(r.diagnostics.length == 0, r.diagnostics.length ? r.diagnostics[0].message : "");
    assert(abs(partVolume(r, "a") / (PI * 4 * (40 + sqrt(1700.0))) - 1) < 1e-4);
    // a path turning right back on itself: said, with where
    auto back = error(`@part Solid a() => circle(d: 2.mm).sweep(path([vec(0, 0, 0), vec(10, 0, 0), vec(0, 0, 0)]));`);
    assert(back.message.canFind("turns right back on itself at (10, 0, 0)"), back.message);
}

unittest
{
    mixin(slowTest);
    // along a helix the profile keeps to its axis: a twist, up and a guide work over many turns, and a
    // round profile comes out the right size; a closed circle of a sketch takes a twist
    expectOut(`auto h4 = helix(r: 10.mm, pitch: 2.mm, height: 8.mm), h30 = helix(r: 10.mm, pitch: 2.mm, height: 60.mm);
        immutable turn = sqrt((20 * PI) ^^ 2 + 4.0), l30 = 30 * turn;
        auto bar = rect(2.mm, 1.mm);
        writeln(abs(bar.sweep(h4, twist: 30.deg).volume / (8 * turn * 1.mm ^^ 3) - 1) < 1e-4);
        writeln(abs(bar.sweep(h30, up: Z).volume / (2 * l30 * 1.mm ^^ 3) - 1) < 1e-4, " ",
            abs(bar.sweep(h30).volume / (2 * l30 * 1.mm ^^ 3) - 1) < 1e-4);
        auto wire = circle(d: 1.mm).sweep(h30);
        writeln(abs(wire.volume / (PI / 4 * l30 * 1.mm ^^ 3) - 1) < 1e-4, " ", abs(wire.bbox.size.x / 21.mm - 1) < 1e-3);
        auto g = rect(1.mm, 0.5.mm).sweep(helix(r: 10.mm, pitch: 2.mm, height: 20.mm),
            guide: helix(r: 12.mm, pitch: 2.mm, height: 20.mm));
        writeln(abs(g.volume / (0.5 * 10 * turn * 1.mm ^^ 3) - 1) < 1e-4);
        auto s = sketch();
        s.circle(s.point(0, 0, fixed: true), d: 40.mm);
        writeln(abs(rect(4.mm, 2.mm).sweep(s.path, twist: 360.deg).volume / (8 * 40 * PI * 1.mm ^^ 3) - 1) < 1e-4);`,
        "true\ntrue true\ntrue true\ntrue\ntrue", "import std.math;");
}

unittest
{
    // frames round a closed path: n of them a length/n apart, the start not repeated; a path's length
    expectOut(`immutable sq = path([vec(0, 0, 0), vec(20, 0, 0), vec(20, 20, 0), vec(0, 20, 0)], closed: true);
        foreach (f; sq.frames(4))
            writeln(f.origin);
        writeln(sq.length, " ", path([vec(0, 0, 0), vec(3, 4, 0)]).length);`,
        "[0 mm, 0 mm, 0 mm]\n[20 mm, 0 mm, 0 mm]\n[20 mm, 20 mm, 0 mm]\n[0 mm, 20 mm, 0 mm]\n80 mm 5 mm");
}

unittest
{
    // annotations before a unittest, a struct or an import are errors, not dropped; @unit belongs to
    // the module line
    auto e = error("@whatever(3)\nunittest { writeln(1); }\n");
    assert(e.code == Code.syntax && e.message.canFind("'@whatever' cannot be put before a unittest"), e.message);
    assert(error("@unit(inch)\nunittest { writeln(1); }\n").message.canFind("before its module line"));
    assert(error("@part\nstruct S { int a; }\n").message.canFind("before a struct"));
    assert(error("@param(\"x\")\nimport std.hardware;\n").message.canFind("before an import"));
}

unittest
{
    // columns count characters, not the bytes of UTF-8; a tab in the line is a tab under it
    import std.algorithm : startsWith;
    import hackerscad.tool.codegen : offsetOf;
    auto e = error("Solid b()\n{\n    auto s = \"àèìòù €\";  auto y = nosuch;\n    return box(1, 1, 1);\n}\n@part Solid a() => b();\n");
    assert(e.span.line == 3 && e.span.col == 35, format("%s", e.span));
    immutable tabbed = "unittest\n{\n\tauto y = nosuch;\n}\n";
    auto t = error(tabbed);
    assert(t.span.col == 11 && render(t, tabbed).canFind("| \t         ^^^^^^"), render(t, tabbed));
    // the code tools find a token by its column after letters of several bytes
    immutable src = "auto s = \"é\"; auto y = 3;\n";
    assert(src[offsetOf(src, Span("", 1, 20, 1)) .. $].startsWith("y = 3"));
}

unittest
{
    // a Length times an Angle (in radians) is a Length, an arc's; a Length over an Angle too
    expectOut(`writeln(10.mm * 90.deg, " ", 1.mm / 2.deg);`, "15.708 mm 28.6479 mm");
}

unittest
{
    // an array literal holds one type: a string among numbers, a Length among Angles are errors;
    // whole and fractional numbers mix, and bare numbers with Lengths (bare numbers given to geometry are mm)
    auto e = errorIn(`auto a = [1, "a"];`);
    assert(e.code == Code.type && e.message.canFind("[0] is an int, [1] a string"), e.message);
    assert(errorIn(`auto a = [1.mm, 2.deg];`).message.canFind("[0] is a Length, [1] an Angle"));
    expectOut(`auto a = [1, 2.5]; auto b = [1.mm, 2]; auto c = [box(1, 1, 1), circle(d: 1)];
        writeln(a.length + b.length + c.length);`, "6");
}

unittest
{
    // -D for a string @param: a bare word is the word, when it names nothing; else the usual errors
    auto model = `@param string style = "round";
        @part Solid p() => style == "square" ? box(1, 1, 1) : box(2, 2, 2);`;
    auto it = make();
    it.overrides["style"] = "square";
    assert(isClose(partVolume(runModel(model, it), "p"), 1));
    it = make();
    it.overrides["style"] = "X";
    assert(error(model, it).code == Code.type);
}

unittest
{
    // a private symbol of an imported module: said private, not undefined
    auto dir = buildPath(tempDir, "hcad-private-test");
    mkdirRecurse(buildPath(dir, "lib"));
    scope (exit)
        rmdirRecurse(dir);
    write(buildPath(dir, "lib", "parts.hcad"), "module lib.parts;\nprivate immutable secret = 1;\n");
    foreach (src; ["import lib.parts;\nunittest { auto x = secret; }", "import p = lib.parts;\nunittest { auto x = p.secret; }"])
    {
        auto it = make();
        it.root = dir;
        auto e = error(src, it);
        assert(e.message.canFind("'secret' is private to module 'lib.parts'"), e.message);
    }
    // changing an immutable: no mention of enum, which hcad files do not have
    assert(!errorIn("immutable x = 1; x = 2;").message.canFind("enum"));
}

unittest
{
    // writeln of shapes and selections: a short summary
    expectOut(`writeln(box(30, 20, 10)); writeln(rect(30.mm, 20.mm)); writeln(path([vec(0, 0, 0), vec(10, 0, 0)]));
        writeln(box(1, 1, 1).faces.top, " ", faces.top);`,
        "Solid 30 × 20 × 10 mm, volume 6000 mm³\nProfile 30 × 20 mm, area 600 mm²\nPath 10 mm long, open\nfaces (1) faces");
}

unittest
{
    // drawings: a sheet with only a section is laid out and scaled; a section plane that misses the part is an
    // error; a dimension of the model's own replaces the view's overall one across the same span, and a positive
    // offset is away from the part
    import hackerscad.drawing.sheet : toSvg;
    import hackerscad.lang.drawingval : DrawingVal;
    auto r = runModel(q{
        @part Solid bracket() => box(60, 30, 6);
        @drawing Drawing sheet()
        {
            auto d = drawing(title: "S");
            d.section(bracket, YZ, label: "B");
            return d;
        }
    });
    auto svg = toSvg((cast(DrawingVal) r.drawings[0].drawing).render());
    assert(svg.canFind("Section B-B") && !svg.canFind("inf"), svg);
    auto miss = error(q{
        @part Solid bracket() => box(60, 30, 6);
        @drawing Drawing sheet()
        {
            auto d = drawing(title: "S");
            d.section(bracket, YZ.offset(100.mm), label: "B");
            return d;
        }
    });
    assert(miss.message.canFind("does not cut the part"), miss.message);
    r = runModel(q{
        @part Solid bracket() => box(60, 30, 6);
        @drawing Drawing sheet()
        {
            auto d = drawing(title: "M", size: "A3", scale: 2, landscape: false);
            auto v = d.view(bracket, "top", at: vec(100, 150));
            d.dimension(v, from: vec(-30, -15, 6), to: vec(30, -15, 6), offset: 10.mm);
            return d;
        }
    });
    svg = toSvg((cast(DrawingVal) r.drawings[0].drawing).render());
    // one 60, below the bottom edge (at 120 mm up the sheet, its text 309 mm down from the top of the A3)
    assert(svg.count(">60<") == 1 && svg.canFind(`y="309"`) && svg.canFind(`text-anchor="middle">60<`), svg);
}

unittest
{
    // hcad section --projection --no-sketch: the outline without the sketch
    import hackerscad.io.stl : toStl;
    import hackerscad.tool.features : projectionReport;
    auto dir = buildPath(tempDir, "hcad-projection-test");
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    write(buildPath(dir, "b.stl"), toStl(kernel.tessellate(kernel.box(20, 10, 5), 0.01, 0.1).welded));
    assert(projectionReport(buildPath(dir, "b.stl"), null, "xy").canFind("as a sketch"));
    assert(!projectionReport(buildPath(dir, "b.stl"), null, "xy", false).canFind("as a sketch"));
}

unittest
{
    // more than two segments at a point: the areas they close, all full, each to fill or empty (an arc from
    // one corner of a rectangle to the opposite one; a line across a rectangle, ending on its sides)
    expectOut(q{
        auto s = sketch();
        auto p = s.point(0, 20, fixed: true);
        auto q = s.point(20, 0, fixed: true);
        auto r = s.rect(p, q);
        s.arc(s.point(0, 0, fixed: true), q, p);
        writeln(round(s.profile.area.to!double));
        s.fill(vec(5, 5), full: false);
        writeln(round(s.profile.area.to!double));
        auto t = sketch();
        t.rect(t.point(0, 0, fixed: true), t.point(20, 10, fixed: true));
        t.line(t.point(10, 0, fixed: true), t.point(10, 10, fixed: true));
        writeln(t.profile.area);
        t.fill(vec(15, 5), full: false);
        writeln(t.profile.area, " ", t.profile.bbox.max);
    }, "400\n86\n200 mm^2\n100 mm^2 [10 mm, 10 mm, 0 mm]");
}

unittest
{
    // text's weight and style: bold, a style said in the font's name, a weight given by name; letters and
    // lines spaced
    expectOut(q{
        auto plain = text("BASIL", size: 9.mm, font: "Sans").area;
        writeln(text("BASIL", size: 9.mm, font: "Sans", bold: true).area > plain * 1.2);
        writeln(text("BASIL", size: 9.mm, font: "Sans Bold").area == text("BASIL", size: 9.mm, bold: true).area);
        auto w = text("BASIL", size: 9.mm).bbox.size.x;
        writeln(round((text("BASIL", size: 9.mm, spacing: 2.mm).bbox.size.x - w).to!double));
        auto h = text("A\nB", size: 9.mm);
        auto h2 = text("A\nB", size: 9.mm, lineSpacing: 2);
        writeln(h2.bbox.size.y > h.bbox.size.y + 5.mm);
    }, "true\ntrue\n8\ntrue");
    assert(error(`unittest { text("x", weight: "fat"); }`).message.canFind("no font weight is called 'fat'"));
    assert(error(`unittest { text("x", weight: 700, bold: true); }`).message.canFind("not both"));
}
