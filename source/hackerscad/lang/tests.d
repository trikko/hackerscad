/// Language test suite: runs .hcad snippets and checks output, errors and
/// geometry. Snippets passed to `output` run inside a unittest block.
module hackerscad.lang.tests;

version (unittest):

import std.algorithm : map, canFind;
import std.array : array, join;
import std.format : format;
import std.math : isClose, PI, sqrt;
import std.file : tempDir, mkdirRecurse, write, rmdirRecurse;
import std.path : buildPath;

import hackerscad.lang.interp;
import hackerscad.lang.errors;
import hackerscad.lang.value : Value, Dim;
import hackerscad.geom.color;
import hackerscad.kernel.occt.backend;
import hackerscad.kernel.brep : BoolOp, Vec3;

private:

__gshared OcctKernel kernel;

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
    // the shipped example evaluates with the expected parts and checks
    import std.file : thisExePath, exists;
    import std.path : dirName;

    auto path = buildPath(dirName(dirName(dirName(thisExePath))), "examples", "box.hcad");
    assert(exists(path), path);
    auto it = make();
    auto r = it.run(path);
    assert(r.parts.map!(p => p.name).array == ["body", "lid"]);
    assert(r.params.length == 5 && r.presets == ["small", "large"]);
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
    // planes, split and pieces
    auto r = runModel(q{
        immutable block = box(40, 20, 30);
        immutable halves = block.split(block.plane(faces.top).offset(-10));
        @part Solid above() => halves.above;
        @part Solid below() => halves.below;
        @part Solid tilted() => box(10, 10, 10).split(plane(origin: vec(0, 0, 5), normal: vec(1, 0, 1))).below;
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

    assert(error("@part Solid p() => box(1, 1, 1).split(Z).above;").code == Code.type);
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
                rect(10, 10).offset(2).area / 1.mm ^^ 2, regularPolygon(6, d: 10).area / 1.mm ^^ 2,
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
    assert(error("@part Solid p() => rect(10, 10).rotate(x: 90).extrude(5);").code == Code.type);
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
    // built-in libraries
    auto r = runModel(q{
        import hardware;
        import std.threads : threadedRod;
        import gears;
        import hinges : hinge;
        import snaps : snapHook;
        import enclosures : enclosure, roundedBox;

        @part Solid rod() => threadedRod(6.mm, 1.mm, 8.mm);
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
    assert(r.log[0].text == "18 mm 0.5 mm true", r.log[0].text);
    foreach (p; r.parts)
        assert(kernel.isValid(p.solid.brep) && kernel.solids(p.solid.brep).length == 1, p.name);
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
    // the most negative integer divided by -1 wraps instead of trapping
    expectOut(`long m = -9223372036854775807 - 1; writeln(m / -1, " ", m % -1);`, "-9223372036854775808 0");
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
