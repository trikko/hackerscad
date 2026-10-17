module hackerscad.lang.errors;

import std.format : format;

/// A range in a source file; lines and columns start at 1.
struct Span
{
    string file;
    uint line, col;
    uint length = 1;

    string toString() const => format("%s:%d:%d", file, line, col);
}

enum Severity
{
    error,
    warning,
    note,
}

struct Diagnostic
{
    Severity severity;
    string code;        /// e.g. "E0204"
    string message;
    Span span;
    string suggestion;  /// optional fix, shown as "did you mean …"
}

/// Thrown for any problem in a .hcad program; carries a diagnostic so the
/// CLI, the GUI and agents can render it with source context.
class HcadError : Exception
{
    Diagnostic diag;

    this(string code, string message, Span span, string suggestion = null,
        string file = __FILE__, size_t line = __LINE__)
    {
        diag = Diagnostic(Severity.error, code, message, span, suggestion);
        super(message, file, line);
    }
}

/// Error codes, grouped by phase.
enum Code : string
{
    lex = "E0100",
    syntax = "E0101",
    undefined = "E0200",
    redefined = "E0201",
    type = "E0202",
    arity = "E0203",
    unknownArg = "E0204",
    missingArg = "E0205",
    immutable_ = "E0206",
    index = "E0207",
    units = "E0310",
    kernel = "E0410",
    sketch = "E0420",
    sandbox = "E0500",
    limit = "E0501",
    assertion = "E0600",
    import_ = "E0700",
}

/// Renders a diagnostic like rustc/dmd do, with the offending line.
string render(const Diagnostic d, string source)
{
    import std.string : splitLines, strip;
    import std.array : replicate;
    import std.conv : to;

    auto lines = source.splitLines;
    // no line to show (a preset, a -D, the export as a whole): the file alone, or nothing
    if (d.span.line == 0 || d.span.line > lines.length)
        return format("%s[%s]: %s\n", d.severity, d.code, d.message)
            ~ (d.span.file.length ? "  --> " ~ d.span.file ~ "\n" : "")
            ~ (d.suggestion.length ? "  " ~ d.suggestion.strip ~ "\n" : "");
    string head = format("%s[%s]: %s\n  --> %s\n", d.severity, d.code, d.message, d.span);
    immutable num = d.span.line.to!string;
    immutable pad = " ".replicate(num.length);
    auto r = head ~ format("%s |\n%s | %s\n%s | %s%s", pad, num, lines[d.span.line - 1], pad,
        " ".replicate(d.span.col - 1), "^".replicate(d.span.length ? d.span.length : 1));
    if (d.suggestion.length)
        r ~= " " ~ d.suggestion;
    return r ~ "\n";
}

/// Closest candidate by edit distance, for "did you mean" suggestions.
string closest(string name, const(string)[] candidates)
{
    import std.algorithm : levenshteinDistance;
    import std.uni : toLower;

    string best;
    size_t bestDist = size_t.max;
    foreach (c; candidates)
    {
        immutable d = levenshteinDistance(name.toLower, c.toLower);
        if (d < bestDist)
        {
            bestDist = d;
            best = c;
        }
    }
    return bestDist <= (name.length > 4 ? 2 : 1) ? best : null;
}

unittest
{
    assert(closest("radius", ["r", "d", "rad"]) is null);
    assert(closest("cilinder", ["cylinder", "cone"]) == "cylinder");
    auto d = Diagnostic(Severity.error, "E0204", "unknown argument 'radius'", Span("a.hcad", 2, 5, 6), "did you mean 'r'?");
    auto s = render(d, "x\nfoo(radius: 1)");
    import std.algorithm : canFind;
    assert(s.canFind("2 | foo(radius: 1)"));
    assert(s.canFind("    ^^^^^^ did you mean 'r'?"));
}
