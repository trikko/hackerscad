module hackerscad.cli.main;

import std.stdio;
import std.getopt;
import std.json;
import std.string : indexOf;

import hackerscad.lang.errors;
import hackerscad.kernel.brep : KernelException;
import hackerscad.tool.runner;
import hackerscad.tool.docs : reference, agentsText, skillText, summaryText;
import hackerscad.tool.mcp : serve, serveWorker;

enum usage = `hackerscad — parametric CAD with a D-like language

usage:
  hcad render FILE.hcad -o OUT [-o OUT…] [-D name=value…] [--preset NAME] [--part NAME…]
      OUT can be .3mf (one object per part), .stl (one part), .zip (one STL
      per part), .step (one named body per part) or .png (iso view;
      name-views.png gives iso/front/top/right, name-top.png only the top,
      and so on for front, back, bottom, left, right), or .svg, .pdf, .dxf for a
      @drawing (the first one, or --drawing NAME)
  hcad check FILE.hcad [--json] [-D name=value…] [--preset NAME]
      evaluates the model and reports parts, parameters, output and problems
  hcad docs [TOPIC | --cheatsheet | --agents | --skill | --summary]
      language reference and agent guide (without a topic: the full text,
      llms-full.txt); --cheatsheet every function in one line each (also
      --cheatsheet-html), --agents AGENTS.md, --skill SKILL.md, --summary
      llms.txt
  hcad features FILE [--part NAME] [--json]
      what a mesh (.stl .obj .3mf), a STEP file or a model is made of, to
      remodel it: flat faces, holes and shafts, cones, spheres, roundings,
      patterns of holes, with plausible sizes
  hcad section FILE --plane xy|xz|yz --at MM [--part NAME]
      the section of a mesh, STEP file or model as lines, arcs and circles
      with their sizes, and as a sketch ready to paste
  hcad compare FILE.hcad --a PART --b PART [--tolerance MM] [-o OUT.png]
      how far part a is from part b (a remodelled part from the mesh it
      copies, loaded as a reference part): distances both ways, and a
      picture of a coloured green, yellow, red by its distance from b
  hcad scan FILE --axis x|y|z [--step MM] [--part NAME]
      cuts all along an axis: each hole and pocket met with its shape (circle,
      rectangle, hexagon, teardrop, slot…) and where it starts and ends, and
      the outside outline's changes
  hcad mcp
      Model Context Protocol server on stdio, for AI agents; models are
      evaluated in a worker process that is killed when an evaluation is
      cancelled or exceeds HCAD_MCP_TIMEOUT (seconds, default 900) and may use
      HCAD_MCP_MEMORY_MB (default half of the RAM); 0 disables either limit
  hcad --version
      version, and the libraries hackerscad is built with

options:
  -D name=value     override a @param (e.g. -D width=80.mm)
  --preset NAME     use the values of a @preset
  --drawing NAME    the @drawing to export as .svg, .pdf or .dxf
  --one-object      a .3mf holds the parts as pieces of one object, as slicers want
                    them for prints in several colours or materials
  --part NAME       export only this @part (by function name or name:); repeat it
                    for more; without it, every part but the export: false ones
  --tolerance MM    mesh chord tolerance (default 0.02)
  --printability    report overhangs and thin walls per part, and mark them in
                    pictures: overhangs striped red, thin walls hatched violet
  --overhang DEG    overhangs steeper than this from a wall need supports (45)
  --min-wall MM     walls thinner than this do not print (0.8)
  --json            machine-readable output (for scripts and agents)`;

/// The garbage collector marks on one thread: marking in parallel spent
/// most of its time spinning on locks, against OCCT's own threads.
extern (C) __gshared string[] rt_options = ["gcopt=parallel:0"];

int main(string[] args)
{
    if (args.length >= 2 && (args[1] == "--version" || args[1] == "version"))
    {
        import hackerscad.about;
        writeln(appName, " ", appVersion, " - ", appSummary);
        writeln(appCopyright, " - ", appWebsite);
        writeln("license: ", appLicense);
        writeln("\nbuilt with:");
        write(componentList());
        return 0;
    }
    if (args.length < 2 || args[1] == "-h" || args[1] == "--help")
    {
        writeln(usage);
        return args.length < 2 ? 2 : 0;
    }
    auto command = args[1];
    args = args[0] ~ args[2 .. $];

    switch (command)
    {
    case "mcp":
        if (args.length > 1 && args[1] == "--worker")
            serveWorker();
        else
            serve();
        return 0;
    case "docs":
        {
            // --agents (AGENTS.md), --skill (SKILL.md), --summary (llms.txt), or the reference
            immutable topic = args.length > 1 ? args[1] : null;
            import hackerscad.tool.cheatsheet : cheatsheetMarkdown, cheatsheetHtml;
            if (topic == "--cheatsheet-html")
            {
                // with the logo when run from the source tree
                import std.file : exists, readText;
                auto logo = exists("data/logo/it.andreafontana.hackerscad.gui.svg")
                    ? readText("data/logo/it.andreafontana.hackerscad.gui.svg") : null;
                write(cheatsheetHtml(logo));
                return 0;
            }
            write(topic == "--agents" ? agentsText() : topic == "--skill" ? skillText()
                : topic == "--summary" ? summaryText() : topic == "--cheatsheet" ? cheatsheetMarkdown()
                : reference(topic));
            return 0;
        }
    case "features":
        {
            string part;
            bool asJson;
            try
                getopt(args, "part", &part, "json", &asJson);
            catch (GetOptException e)
            {
                stderr.writeln("error: ", e.msg);
                return 2;
            }
            if (args.length != 2)
            {
                stderr.writeln(usage);
                return 2;
            }
            import hackerscad.tool.features : meshOf, featuresJson;
            import hackerscad.geom.meshfeatures : analyse, report;
            try
            {
                auto a = analyse(meshOf(args[1], part));
                if (asJson)
                    writeln(featuresJson(a).toPrettyString(JSONOptions.doNotEscapeSlashes));
                else
                    write(report(a));
            }
            catch (Exception e)
            {
                stderr.writeln("error: ", e.msg);
                return 1;
            }
            return 0;
        }
    case "section":
        {
            string part, plane = "xy";
            double at = 0;
            try
                getopt(args, "part", &part, "plane", &plane, "at", &at);
            catch (GetOptException e)
            {
                stderr.writeln("error: ", e.msg);
                return 2;
            }
            if (args.length != 2)
            {
                stderr.writeln(usage);
                return 2;
            }
            import hackerscad.tool.features : sectionReport;
            try
                write(sectionReport(args[1], part, plane, at));
            catch (Exception e)
            {
                stderr.writeln("error: ", e.msg);
                return 1;
            }
            return 0;
        }
    case "compare":
        {
            string pa, pb, out_;
            double tol = 0.1;
            try
                getopt(args, "a", &pa, "b", &pb, "tolerance", &tol, "o|output", &out_);
            catch (GetOptException e)
            {
                stderr.writeln("error: ", e.msg);
                return 2;
            }
            if (args.length != 2 || pa.length == 0 || pb.length == 0)
            {
                stderr.writeln(usage);
                return 2;
            }
            RunOptions ro;
            ro.path = args[1];
            auto run = evaluateModel(ro);
            if (!run.ok)
            {
                stderr.write(run.renderedDiagnostics());
                return 1;
            }
            try
            {
                ubyte[] png;
                auto j = run.compare(run.partIndices([pa], true)[0], run.partIndices([pb], true)[0], tol, png);
                writefln("largest distance %.3f mm (a to b %.3f, b to a %.3f), mean %.3f mm, %.0f%% within %g mm",
                    j["max_mm"].floating, j["a_to_b"]["max_mm"].floating, j["b_to_a"]["max_mm"].floating,
                    j["a_to_b"]["mean_mm"].floating, 100 * j["a_to_b"]["within_tolerance"].floating, tol);
                if (out_.length)
                {
                    import std.file : write;
                    write(out_, png);
                }
            }
            catch (HcadError e)
            {
                stderr.writeln("error: ", e.msg);
                return 1;
            }
            return 0;
        }
    case "scan":
        {
            string part, axis = "z";
            double step = 0;
            try
                getopt(args, "part", &part, "axis", &axis, "step", &step);
            catch (GetOptException e)
            {
                stderr.writeln("error: ", e.msg);
                return 2;
            }
            if (args.length != 2)
            {
                stderr.writeln(usage);
                return 2;
            }
            import hackerscad.tool.features : scanReport;
            try
                write(scanReport(args[1], part, axis, step));
            catch (Exception e)
            {
                stderr.writeln("error: ", e.msg);
                return 1;
            }
            return 0;
        }
    case "render", "check":
        break;
    default:
        stderr.writeln("error: unknown command '", command, "'\n\n", usage);
        return 2;
    }

    string[] outputs, defines;
    RunOptions o;
    bool json;
    string[] only;
    bool oneObject;
    try
        getopt(args, "o|output", &outputs, "D", &defines, "preset", &o.preset, "drawing", &o.drawing, "tolerance", &o.tolerance,
            "part", &only, "one-object", &oneObject, "json", &json, "printability", &o.printability,
            "overhang", &o.overhangAngle, "min-wall", &o.minWall);
    catch (GetOptException e)
    {
        stderr.writeln("error: ", e.msg);
        return 2;
    }
    if (args.length != 2)
    {
        stderr.writeln(usage);
        return 2;
    }
    if (!(o.tolerance > 0))
    {
        stderr.writeln("error: --tolerance expects a positive number of mm, got ", o.tolerance);
        return 2;
    }
    if (!(o.overhangAngle >= 0 && o.overhangAngle < 90) || !(o.minWall > 0))
    {
        stderr.writeln("error: --overhang expects degrees from 0 to 90 and --min-wall a positive number of mm");
        return 2;
    }
    o.path = args[1];
    foreach (d; defines)
    {
        auto eq = d.indexOf('=');
        if (eq <= 0)
        {
            stderr.writeln("error: -D expects name=value, got '", d, "'");
            return 2;
        }
        o.overrides[d[0 .. eq]] = d[eq + 1 .. $];
    }
    if (command == "render" && outputs.length == 0)
    {
        stderr.writeln("error: render needs at least one -o OUTPUT");
        return 2;
    }

    auto run = evaluateModel(o);
    if (run.ok && command == "render")
    {
        try
            foreach (out_; outputs)
                run.exportTo(out_, only, oneObject);
        catch (HcadError e)
            run.fatal ~= e.diag;
        catch (KernelException e)
            run.fatal ~= Diagnostic(Severity.error, Code.kernel, e.msg, Span(o.path));
    }

    if (json)
    {
        writeln(run.report().toPrettyString(JSONOptions.doNotEscapeSlashes));
        return run.hasErrors ? 1 : 0;
    }

    foreach (l; run.ok ? run.result.log : run.interp.log)
        writeln(l.text);
    if (run.ok)
        foreach (p; run.result.parts)
        {
            auto bb = run.kernel.bbox(p.solid.brep);
            writefln("part %-12s %.1f × %.1f × %.1f mm   volume %.1f mm³%s%s", p.name, bb.size.x, bb.size.y, bb.size.z,
                run.kernel.volume(p.solid.brep), p.label != p.name ? "   (exported as \"" ~ p.label ~ "\")" : "",
                p.export_ ? "" : "   (reference, not exported)");
        }
    if (run.ok && run.printability)
        foreach (i, p; run.result.parts)
        {
            import std.format : format;
            auto pc = run.printChecks()[i];
            writefln("  %-17s %.0f mm² overhangs beyond %g°, %.0f mm² walls under %g mm%s", p.name, pc.overhangArea,
                o.overhangAngle, pc.thinArea, o.minWall, pc.thinArea > 0 ? format(" (the thinnest %.2f mm)", pc.thinnest) : "");
        }
    stderr.write(run.renderedDiagnostics());
    if (!run.ok)
        return 1;
    size_t problems;
    foreach (d; run.result.diagnostics)
        problems += d.severity == Severity.error;
    if (problems)
        writefln("done in %d ms, %d failed check%s", run.milliseconds, problems, problems == 1 ? "" : "s");
    else
        writefln("ok in %d ms", run.milliseconds);
    return problems ? 1 : 0;
}
