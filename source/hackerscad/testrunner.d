/// The tests run one block at a time, each timed: at the end the slowest are
/// listed (HCAD_TEST_TIMES: how many, 15 if unset, "all" for every one), so a
/// run, the CI's too, shows where the time goes. A failing block is reported
/// and the next ones of its module still run.
module hackerscad.testrunner;

version (unittest):

import core.runtime : Runtime, UnitTestResult;
import core.time : Duration, MonoTime;

/// The modules whose blocks are run and timed one by one; a module with tests
/// that is not here runs whole, timed as one, with a note to add it.
private immutable string[] modules = [
    "hackerscad.drawing.layout", "hackerscad.drawing.sheet", "hackerscad.examples", "hackerscad.geom.color",
    "hackerscad.geom.deviation", "hackerscad.geom.hull", "hackerscad.geom.mesh", "hackerscad.geom.meshfeatures",
    "hackerscad.geom.noise", "hackerscad.geom.outlinefit", "hackerscad.geom.printability", "hackerscad.geom.spline",
    "hackerscad.geom.tiling", "hackerscad.geom.vec", "hackerscad.geom.voxeldiff", "hackerscad.io.meshread",
    "hackerscad.io.outlines", "hackerscad.io.stl", "hackerscad.io.threemf", "hackerscad.kernel.cache",
    "hackerscad.kernel.occt.backend", "hackerscad.kernel.occt.perftest", "hackerscad.lang.errors",
    "hackerscad.lang.lexer", "hackerscad.lang.parser", "hackerscad.lang.symbols", "hackerscad.lang.tests",
    "hackerscad.lang.threading", "hackerscad.lang.value", "hackerscad.parallel", "hackerscad.render.linediff",
    "hackerscad.render.png", "hackerscad.render.raster", "hackerscad.sketch.sketch", "hackerscad.sketch.solver",
    "hackerscad.tool.annotations", "hackerscad.tool.closeup", "hackerscad.tool.codegen", "hackerscad.tool.complete",
    "hackerscad.tool.docs", "hackerscad.tool.exporter", "hackerscad.tool.fitting", "hackerscad.tool.guiclient",
    "hackerscad.tool.literals", "hackerscad.tool.mcp", "hackerscad.tool.runner", "hackerscad.tool.sketchcode",
];

private struct Block
{
    string where; /// file:line
    void function() run;
}

/// Every listed module's blocks, by module name.
private Block[][string] blocks()
{
    Block[][string] r;
    static foreach (name; modules)
    {{
        mixin("import " ~ name ~ ";");
        Block[] these;
        foreach (test; __traits(getUnitTests, mixin(name)))
        {
            enum loc = __traits(getLocation, test);
            these ~= Block(loc[0] ~ ":" ~ loc[1].stringof, &test);
        }
        r[name] = these;
    }}
    return r;
}

shared static this()
{
    Runtime.extendedModuleUnitTester = &runAll;
}

private UnitTestResult runAll()
{
    import std.algorithm : sort;
    import std.conv : to;
    import std.format : format;
    import std.process : environment;
    import std.stdio : stderr, writeln, writefln;

    struct Timed
    {
        string where;
        Duration took;
    }
    Timed[] times;
    size_t tested, passed;
    auto known = blocks();
    bool run(string where, void delegate() test)
    {
        immutable start = MonoTime.currTime;
        scope (exit)
            times ~= Timed(where, MonoTime.currTime - start);
        try
        {
            test();
            return true;
        }
        catch (Throwable t)
        {
            stderr.writeln(t);
            return false;
        }
    }
    foreach (m; ModuleInfo)
    {
        if (m is null || m.unitTest is null)
            continue;
        tested++;
        bool ok = true;
        if (auto bs = m.name in known)
            foreach (b; *bs)
                ok = run(b.where, () => b.run()) && ok;
        else
        {
            stderr.writefln("%s: not in hackerscad/testrunner.d, run whole and timed as one", m.name);
            ok = run(m.name, () => m.unitTest()());
        }
        passed += ok;
    }

    // the slowest, and the whole
    times.sort!((a, b) => a.took > b.took);
    immutable want = environment.get("HCAD_TEST_TIMES", "15");
    immutable shown = want == "all" ? times.length : want.to!size_t;
    Duration all;
    foreach (t; times)
        all += t.took;
    writefln("slowest test blocks (%s of %s, %.1f s in all):", shown < times.length ? shown : times.length,
        times.length, all.total!"msecs" / 1000.0);
    foreach (t; times[0 .. shown < times.length ? shown : $])
        writeln(format("  %7.2f s  %s", t.took.total!"msecs" / 1000.0, t.where));

    UnitTestResult r;
    r.executed = tested;
    r.passed = passed;
    r.runMain = false;
    r.summarize = true;
    return r;
}
