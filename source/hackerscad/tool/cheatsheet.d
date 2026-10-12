/// The cheatsheet: every function, method and property of the language with
/// one line each, by section, plus "how do I…" recipes. Generated from
/// lang/reference.d as Markdown (hcad docs --cheatsheet) or as a printable
/// HTML page (docs/cheatsheet.html).
module hackerscad.tool.cheatsheet;

import std.array : appender, replace;
import std.format : formattedWrite;

import hackerscad.lang.reference;

/// The sections in the order of the reference.
string[] sections()
{
    string[] r;
    foreach (ref e; reference)
        if (r.length == 0 || r[$ - 1] != e.group)
            r ~= e.group;
    return r;
}

/// How an entry is written in the cheatsheet: s.fillet(edges, r) → Solid.
string usage(const Ref e)
{
    final switch (e.kind)
    {
    case RefKind.method:
        return receiverName(e.on) ~ "." ~ e.signature;
    case RefKind.property:
        return receiverName(e.on) ~ "." ~ e.name ~ (e.type.length ? " → " ~ e.type : "");
    case RefKind.unit:
        return "10." ~ e.name;
    case RefKind.annotation:
        return "@" ~ e.name ~ (e.params.length ? "(" ~ joined(e.params) ~ ")" : "");
    case RefKind.function_, RefKind.constant, RefKind.keyword, RefKind.type:
        return e.signature;
    }
}

private string joined(const string[] xs)
{
    import std.array : join;
    return xs.join(", ");
}

/// The variable a cheatsheet line uses for a receiver type.
private string receiverName(string on)
{
    switch (on)
    {
    case "Solid": return "s";
    case "Shape": return "s";
    case "Profile": return "p";
    case "Frame": return "f";
    case "Plane": return "pl";
    case "Axis": return "a";
    case "Vec": return "v";
    case "BBox": return "s.bbox";
    case "Split": return "s.split(…)";
    case "Edges": return "edges";
    case "Faces": return "faces";
    case "Edge": return "e";
    case "Face": return "f";
    case "list": return "xs";
    case "Sketch": return "sk";
    case "Drawing": return "d";
    default: return "x";
    }
}

/// One line of a library section: usage and description.
struct LibLine
{
    string usage, doc;
}

/// The built-in libraries, one section each, from their sources: functions,
/// structs with their fields, constants (those of one type on one line).
LibLine[][string] libraryLines(out string[] order)
{
    import hackerscad.tool.outline;
    import hackerscad.lang.builtins : librarySources;
    order = ["hardware", "threads", "gears", "hinges", "snaps", "enclosures"];
    LibLine[][string] r;
    foreach (lib; order)
    {
        auto o = outline(librarySources[lib], "<" ~ lib ~ ">");
        LibLine[] lines;
        string[][string] constantsOf;
        string[] constantTypes;
        foreach (d; o.decls)
            final switch (d.kind)
            {
            case Decl.Kind.function_:
                lines ~= LibLine(d.signature, d.doc);
                break;
            case Decl.Kind.struct_:
                lines ~= LibLine("struct " ~ d.signature, d.doc);
                break;
            case Decl.Kind.field:
                break;
            case Decl.Kind.constant:
                if (d.type !in constantsOf)
                    constantTypes ~= d.type;
                constantsOf[d.type] ~= d.name;
                break;
            }
        foreach (t; constantTypes)
            lines ~= LibLine(constantsOf[t].joined ~ (t.length ? ": " ~ t : ""), "");
        r[lib] = lines;
    }
    return r;
}

/// Markdown, for hcad docs --cheatsheet.
string cheatsheetMarkdown()
{
    auto o = appender!string;
    o ~= "# hackerscad cheatsheet\n\n"
        ~ "s is a Solid, p a Profile, f a Frame; every value is immutable: operations give new values.\n";
    foreach (section; sections)
    {
        o.formattedWrite("\n## %s\n\n", section);
        foreach (ref e; reference)
            if (e.group == section)
                o.formattedWrite("- `%s` — %s\n", usage(e), e.doc);
    }
    string[] order;
    auto libs = libraryLines(order);
    foreach (lib; order)
    {
        o.formattedWrite("\n## Library: import %s;\n\n", lib);
        foreach (l; libs[lib])
            o.formattedWrite("- `%s`%s\n", l.usage, l.doc.length ? " — " ~ l.doc : "");
    }
    o ~= "\n## How do I…\n\n";
    foreach (r; recipes)
        o.formattedWrite("- %s: `%s`\n", r.task, r.code);
    return o[];
}

private string esc(string s) => s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");

/// A page to print or keep open: the sections in columns, compact, in the
/// colours of the logo.
string cheatsheetHtml(string logoSvg = null)
{
    import hackerscad.about : appVersion;
    auto o = appender!string;
    o ~= `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>hackerscad cheatsheet</title>
<style>
body { font: 13px/1.35 system-ui, sans-serif; margin: 24px; color: #1d2b26; background: #fff; }
header { display: flex; align-items: center; gap: 14px; margin-bottom: 14px; }
header svg { width: 56px; height: 56px; }
h1 { font-size: 22px; margin: 0; font-weight: 600; }
header p { margin: 2px 0 0; color: #5b6b65; }
main { columns: 3 380px; column-gap: 22px; }
section { break-inside: avoid; margin: 0 0 16px; border: 1px solid #cfe7dd; border-radius: 8px; overflow: hidden; }
h2 { font-size: 13px; margin: 0; padding: 5px 10px; background: #8fcbb4; color: #10382b; }
dl { margin: 0; padding: 6px 10px; }
dt { font: 12px/1.4 ui-monospace, "DejaVu Sans Mono", monospace; color: #0f5540; margin-top: 4px; }
dd { margin: 0 0 0 12px; color: #4a5a54; }
@media print { body { margin: 8mm; } main { columns: 3; } }
</style></head><body>
<header>`;
    o ~= logoSvg;
    o.formattedWrite(`<div><h1>hackerscad cheatsheet</h1><p>version %s · s is a Solid, p a Profile, f a Frame · values never change: operations give new ones</p></div></header>
<main>
`, appVersion);
    o ~= "<section><h2>How do I…</h2><dl>\n";
    foreach (r; recipes)
        o.formattedWrite("<dt>%s</dt><dd>%s</dd>\n", esc(r.code), esc(r.task));
    o ~= "</dl></section>\n";
    foreach (section; sections)
    {
        o.formattedWrite("<section><h2>%s</h2><dl>\n", esc(section));
        foreach (ref e; reference)
            if (e.group == section)
                o.formattedWrite("<dt>%s</dt><dd>%s</dd>\n", esc(usage(e)), esc(e.doc));
        o ~= "</dl></section>\n";
    }
    string[] order;
    auto libs = libraryLines(order);
    foreach (lib; order)
    {
        o.formattedWrite("<section><h2>import %s;</h2><dl>\n", lib);
        foreach (l; libs[lib])
            o.formattedWrite("<dt>%s</dt><dd>%s</dd>\n", esc(l.usage), esc(l.doc));
        o ~= "</dl></section>\n";
    }
    o ~= "</main></body></html>\n";
    return o[];
}
