module hackerscad.cli.main;

import std.stdio;
import std.getopt;
import djson;
import std.string : indexOf;

import hackerscad.lang.errors;
import hackerscad.kernel.brep : KernelException;
import hackerscad.tool.runner;
import hackerscad.render.raster : Shot;
import hackerscad.tool.docs : reference, agentsText, skillText, summaryText, docsStamp;
import hackerscad.tool.mcp : serve, serveWorker;

enum usage = `hackerscad — parametric CAD with a D-like language

usage:
  hcad [--threads N] COMMAND …
      --threads N: how many threads the heavy work uses (booleans, meshing,
      pictures; default a third of the CPUs, also the environment variable
      HCAD_THREADS)
  hcad render FILE.hcad -o OUT [-o OUT…] [-D name=value…] [--preset NAME] [--part NAME…]
      OUT can be .3mf (one object per part), .stl (one part), .zip (one STL
      per part), .step (one named body per part) or .png (iso view;
      name-views.png gives iso/front/top/right, name-top.png only the top,
      and so on for front, back, bottom, left, right), or .svg, .pdf, .dxf for a
      @drawing (the first one, or --drawing NAME); a .png from anywhere:
      --from VIEW|X,Y,Z [--look-at X,Y,Z --size MM [--cut]] (framed on the
      cube of that side round that point; --cut cuts the parts across the
      view through that point, the cut faces closed);
      --opaque draws see-through parts solid
  hcad check FILE.hcad [--json] [-D name=value…] [--preset NAME]
      evaluates the model and reports parts, parameters, output and problems
  hcad docs [TOPIC | --guide [NAME] | --cheatsheet | --agents | --skill | --summary | --stamp]
      language reference and agent guide (without a topic: the full text,
      llms-full.txt); --guide NAME a topic guide in full (threads, sweeps,
      sketches…; without a name, the list); --cheatsheet every function in one line each (also
      --cheatsheet-html), --agents AGENTS.md, --skill SKILL.md, --summary
      llms.txt; --stamp which docs this build has: an installed skill that
      shows another is out of date
  hcad features FILE [--part NAME] [--json]
      what a mesh (.stl .obj .3mf), a STEP file or a model is made of, to
      remodel it: flat faces, holes and shafts, cones, spheres, roundings,
      chamfers, surfaces turned round an axis, patterns of holes, with
      plausible sizes
  hcad literals FILE.hcad [--original PART|MESH]
      the numbers written more than once in a model, with their lines, and
      which sizes of the original they are (a hole's diameter, an axis): the
      measures to name and turn into @params once a copy matches
  hcad section FILE --plane xy|xz|yz --at MM [--part NAME] [--region U0,V0,U1,V1]
      the section of a mesh, STEP file or model as lines, arcs and circles
      with their sizes, and as a sketch ready to paste; --region keeps the
      outlines inside that rectangle of the plane (when none lies wholly
      inside, those crossing it cut at its edges); --no-sketch leaves the
      sketch out; --projection: the
      outline of its shadow on the plane instead; --compare PART -o OUT.png:
      the sections of two parts of a model drawn on each other
  hcad compare FILE.hcad --a PART --b PART [--tolerance MM] [--json] [--views N] [-o OUT.png]
      how far part a is from part b (a remodelled part from the mesh it
      copies, loaded as a reference part): distances both ways, the patches
      that part (numbered), and a picture of a coloured green, yellow, red
      by its distance from b, from the N views (4) that show most of it off
      (or --from …, as for render)
  hcad lines FILE.hcad --a PART --b PART [--depth MM] [--voids] [--fixed] [--views N] [-o OUT.png]
      parts a (a copy) and b (the original) drawn as lines (sharp edges and
      outlines) from 62 directions around them: the lines only one has, as
      places on the part, the most seen first, and the surface facing
      otherwise (twisted, curved, tilted: shaded otherwise); OUT.png the N
      views (12) showing most of them (--fixed: twelve that stay the same,
      to compare versions), grey in common, red only in b, blue only in a,
      violet the surface facing otherwise. --voids compares their holes,
      pockets and cavities made solid instead.
      Once the outside matches, and only if something still differs,
      --depth MM peels both like an onion (that much cut away towards each
      view) to compare the inside; --from … one view of your own instead
  hcad scan FILE --axis x|y|z [--step MM] [--part NAME]
      cuts all along an axis: each hole and pocket met with its shape (circle,
      rectangle, hexagon, teardrop, slot…) and where it starts and ends, and
      the outside outline's changes
  hcad diff FILE.hcad --a PART --b PART [--resolution MM] [-o OUT.png]
      where part a (a copy) differs from part b (the original): the pieces
      of material a lacks and has too much of, numbered, with their boxes
      and volumes, the thin ones apart; OUT.png draws them as boxes
  hcad fit FILE.hcad --a PART --b PART --param NAME [--param NAME…] [--evaluations N]
      tunes the named @param lengths so that part a (a copy) matches part b
      (the original) as closely as it goes: the volume where they differ made
      as small as possible (downhill simplex)
  hcad match FILE.hcad --a PART --b PART
      the operations of a copy (a) and its original (b) matched one by one:
      holes, shafts, cones, roundings, planes, and the pockets met along x, y
      and z; what has no match, however small, is listed, numbered
  hcad review FILE.hcad --a COPY --b ORIGINAL [--tolerance MM] [--each N] [--no-voids] [--look X,Y,Z] [--detail] [-o OUT.png]
      a copy against its original (a mesh or STEP remodelled, a previous
      version), the whole round in one: distances (compare), material
      (diff), drawings outside and of the voids (lines), and close-ups of
      the first N (2) entries of each, framed where they are in sight;
      --look a point: a close-up of what is there (it keeps its place from
      one change to the next); OUT-map.png and OUT-close.png the pictures.
      A summary: of each report its totals and first three entries;
      --detail the whole reports
      Not for modelling from a request: there check and render
  --focus N[,M…] -o OUT.png  (compare, diff, lines, match)
      close-ups of those entries of the report: each from where it is in
      sight (what lies in front cut away when nothing is), the drawings of
      both and the copy coloured by its distance
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

/// The picture asked for by --from, --look-at, --size and --cut (none when
/// neither of the first two is given).
Shot[] freeShotArg(string from, string lookAt, double size, bool cut)
{
    import std.algorithm : map;
    import std.array : array, split;
    import std.conv : to;
    if (from.length == 0 && lookAt.length == 0)
        return null;
    return [Run.freeShot(from, lookAt.length ? lookAt.split(",").map!(x => x.to!double).array : null, size, cut)];
}

/// "2,5" → [2, 5]: the entries to look at closely (--focus).
size_t[] focusList(string arg)
{
    import std.algorithm : map, splitter, filter;
    import std.array : array;
    import std.conv : to;
    import std.string : strip;
    return arg.splitter(",").map!(x => x.strip).filter!(x => x.length).map!(x => x.to!size_t).array;
}

int main(string[] args)
{
    {
        import hackerscad.parallel : threadsFromArgs;
        if (auto problem = threadsFromArgs(args))
        {
            stderr.writeln("error: ", problem);
            return 2;
        }
    }
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
            if (topic == "--guide" || topic == "--guide-index")
            {
                import hackerscad.tool.docs : guideIndex, guideList, guideText;
                if (topic == "--guide-index")
                {
                    write(guideIndex());
                    return 0;
                }
                if (args.length < 3)
                {
                    write(guideList());
                    return 0;
                }
                auto g = guideText(args[2]);
                if (g is null)
                {
                    stderr.writeln("no guide named '", args[2], "'\n", guideList());
                    return 1;
                }
                write(g);
                return 0;
            }
            if (topic == "--stamp")
            {
                writeln(docsStamp());
                return 0;
            }
            write(topic == "--agents" ? agentsText() : topic == "--skill" ? skillText()
                : topic == "--summary" ? summaryText() : topic == "--cheatsheet" ? cheatsheetMarkdown()
                : reference(topic));
            return 0;
        }
    case "literals":
        {
            string original;
            try
                getopt(args, "original", &original);
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
            import hackerscad.tool.literals : literalsReport;
            try
                write(literalsReport(args[1], original));
            catch (Exception e)
            {
                stderr.writeln("error: ", e.msg);
                return 1;
            }
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
                    writeln(featuresJson(a).toJSON(true));
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
            string part, plane = "xy", other, out_, region;
            double at = 0;
            bool projection, noSketch;
            try
                getopt(args, "part", &part, "plane", &plane, "at", &at, "projection", &projection, "compare", &other,
                    "o|output", &out_, "region", &region, "no-sketch", &noSketch);
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
            import hackerscad.tool.features : sectionReport, sectionOverlay, projectionReport;
            try
            {
                if (other.length)
                {
                    string text;
                    import std.algorithm : map;
                    import std.array : array, split;
                    import std.conv : to;
                    auto png = sectionOverlay(args[1], part, other, plane, at, text,
                        region.length ? region.split(",").map!(x => x.to!double).array : null);
                    write(text);
                    if (out_.length)
                    {
                        import std.file : write;
                        write(out_, png);
                    }
                }
                else if (projection)
                    write(projectionReport(args[1], part, plane, !noSketch));
                else
                {
                    import std.algorithm : map;
                    import std.array : array, split;
                    import std.conv : to;
                    auto r = region.length ? region.split(",").map!(x => x.to!double).array : null;
                    write(sectionReport(args[1], part, plane, at, r, !noSketch));
                }
            }
            catch (Exception e)
            {
                stderr.writeln("error: ", e.msg);
                return 1;
            }
            return 0;
        }
    case "compare":
        {
            string pa, pb, out_, focusArg, from, lookAt;
            double tol = 0.1, size = 0;
            bool asJson, cut;
            size_t views = 4;
            try
                getopt(args, "a", &pa, "b", &pb, "tolerance", &tol, "o|output", &out_, "json", &asJson,
                    "focus", &focusArg, "from", &from, "look-at", &lookAt, "size", &size, "cut", &cut, "views", &views);
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
                immutable ia = run.partIndices([pa], true)[0], ib = run.partIndices([pb], true)[0];
                auto free = freeShotArg(from, lookAt, size, cut);
                auto j = run.compare(ia, ib, tol, png, free.length ? &free[0] : null, views);
                if (asJson)
                    writeln(j.toJSON(true));
                else
                    write(Run.compareText(j, run.result.parts[ia].name, run.result.parts[ib].name, 10));
                if (auto focus = focusList(focusArg))
                    write(run.compareFocus(j, ia, ib, focus, png));
                if (out_.length)
                {
                    import std.file : write;
                    write(out_, png);
                }
            }
            catch (Exception e)
            {
                stderr.writeln("error: ", e.msg);
                return 1;
            }
            return 0;
        }
    case "lines":
        {
            string pa, pb, out_, focusArg, from, lookAt;
            size_t views = 12;
            double depth = 0, size = 0;
            bool fixed, voids, cut;
            try
                getopt(args, "a", &pa, "b", &pb, "depth", &depth, "fixed", &fixed, "voids", &voids, "views", &views,
                    "o|output", &out_, "focus", &focusArg, "from", &from, "look-at", &lookAt, "size", &size, "cut", &cut);
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
                auto free = freeShotArg(from, lookAt, size, cut);
                write(run.lines(run.partIndices([pa], true)[0], run.partIndices([pb], true)[0], depth, views, fixed, voids,
                    png, focusList(focusArg), free.length ? &free[0] : null));
                if (out_.length)
                {
                    import std.file : write;
                    write(out_, png);
                }
            }
            catch (Exception e)
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
    case "diff":
        {
            string pa, pb, out_, focusArg;
            double res = 0;
            try
                getopt(args, "a", &pa, "b", &pb, "resolution", &res, "o|output", &out_, "focus", &focusArg);
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
                write(run.differences(run.partIndices([pa], true)[0], run.partIndices([pb], true)[0], res,
                    focusList(focusArg), png));
                if (out_.length && png.length)
                {
                    import std.file : write;
                    write(out_, png);
                }
            }
            catch (Exception e)
            {
                stderr.writeln("error: ", e.msg);
                return 1;
            }
            return 0;
        }
    case "fit":
        {
            string pa, pb;
            string[] names;
            int evaluations = 60;
            try
                getopt(args, "a", &pa, "b", &pb, "param", &names, "evaluations", &evaluations);
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
            import hackerscad.tool.fitting : fit;
            try
                write(fit(args[1], pa, pb, names, evaluations, (string s) { stderr.writeln(s); }));
            catch (Exception e)
            {
                stderr.writeln("error: ", e.msg);
                return 1;
            }
            return 0;
        }
    case "review":
        {
            string pa, pb, out_, look;
            double tol = 0.1;
            size_t each = 2;
            bool noVoids, detail;
            try
                getopt(args, "a", &pa, "b", &pb, "tolerance", &tol, "each", &each, "no-voids", &noVoids, "detail", &detail, "look", &look,
                    "o|output", &out_);
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
                import std.algorithm : map;
                import std.array : array, split;
                import std.conv : to;
                ubyte[][] pictures;
                write(run.review(run.partIndices([pa], true)[0], run.partIndices([pb], true)[0], tol, each, !noVoids,
                    look.length ? look.split(",").map!(x => x.to!double).array : null, pictures, detail));
                // name.png: name-map.png (the distances) and name-close.png (the close-ups)
                if (out_.length)
                {
                    import std.file : write;
                    import std.path : stripExtension;
                    immutable stem = out_.stripExtension;
                    if (pictures.length)
                        write(stem ~ "-map.png", pictures[0]);
                    if (pictures.length > 1)
                        write(stem ~ "-close.png", pictures[1]);
                    writefln("pictures: %s-map.png%s", stem, pictures.length > 1 ? ", " ~ stem ~ "-close.png" : "");
                }
            }
            catch (Exception e)
            {
                stderr.writeln("error: ", e.msg);
                return 1;
            }
            return 0;
        }
    case "match":
        {
            string pa, pb, out_, focusArg;
            try
                getopt(args, "a", &pa, "b", &pb, "o|output", &out_, "focus", &focusArg);
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
            import hackerscad.tool.features : matchReport;
            try
            {
                ubyte[] png;
                write(matchReport(args[1], pa, pb, focusList(focusArg), png));
                if (out_.length && png.length)
                {
                    import std.file : write;
                    write(out_, png);
                }
            }
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
    bool oneObject, cut, opaque;
    string from, lookAt;
    double size = 0;
    try
        getopt(args, "o|output", &outputs, "D", &defines, "preset", &o.preset, "drawing", &o.drawing, "tolerance", &o.tolerance,
            "part", &only, "one-object", &oneObject, "json", &json, "printability", &o.printability,
            "overhang", &o.overhangAngle, "min-wall", &o.minWall, "from", &from, "look-at", &lookAt, "size", &size,
            "cut", &cut, "opaque", &opaque);
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
    run.opaque = opaque;
    if (from.length || lookAt.length)
    {
        import std.algorithm : map;
        import std.array : array, split;
        import std.conv : to;
        try
            run.freeView = [Run.freeShot(from, lookAt.length ? lookAt.split(",").map!(x => x.to!double).array : null,
                size, cut)];
        catch (Exception e)
        {
            stderr.writeln("error: ", e.msg);
            return 2;
        }
    }
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
        writeln(run.report().toJSON(true));
        return run.hasErrors ? 1 : 0;
    }

    foreach (l; run.ok ? run.result.log : run.interp.log)
        writeln(l.text);
    if (run.ok)
        foreach (p; run.result.parts)
        {
            auto bb = run.kernel.bbox(p.solid.brep);
            double volume = double.nan;   // an invalid solid may have none
            try
                volume = run.kernel.volume(p.solid.brep);
            catch (KernelException) {}
            writefln("part %-12s %.1f × %.1f × %.1f mm   volume %.1f mm³%s%s", p.name, bb.size.x, bb.size.y, bb.size.z,
                volume, p.label != p.name ? "   (exported as \"" ~ p.label ~ "\")" : "",
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
