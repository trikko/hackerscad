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
  --part NAME       export only this @part (by function name or name:); repeat it
                    for more; without it, every part but the export: false ones
  --tolerance MM    mesh chord tolerance (default 0.02)
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
    try
        getopt(args, "o|output", &outputs, "D", &defines, "preset", &o.preset, "drawing", &o.drawing, "tolerance", &o.tolerance,
            "part", &only, "json", &json);
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
                run.exportTo(out_, only);
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
