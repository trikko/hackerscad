/// Turns actions on the 3D view into code: stable selectors for a clicked
/// face or edge, and edits that append a feature to a part or change a value
/// in the source. Used by the GUI (context menu, sketch dimensions) and by
/// the control socket.
module hackerscad.tool.codegen;

import std.algorithm : canFind;
import std.array : join;
import std.format : format;
import std.math : abs;

import hackerscad.geom.vec;
import hackerscad.kernel.brep;
import hackerscad.lang.ast;
import hackerscad.lang.errors;
import hackerscad.lang.interp;
import hackerscad.lang.lexer;
import hackerscad.lang.parser;
import hackerscad.lang.value : SolidVal;

/// A change to the source: replace `length` bytes at `offset` with `text`,
/// then select `selectLength` bytes at `selectOffset` (in the new source).
struct Edit
{
    size_t offset, length;
    string text;
    size_t selectOffset, selectLength;

    string apply(string source) const => source[0 .. offset] ~ text ~ source[offset + length .. $];
}

class CodegenException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

// ---------------------------------------------------------------- selectors

/// A selector expression that picks exactly face `face` of `s`: a named
/// one (faces.top…) when possible, otherwise one based on its position.
string faceSelector(Interp it, SolidVal s, int face)
{
    auto info = it.kernel.faces(s.brep)[face];
    string[] candidates = ["faces.top", "faces.bottom", "faces.front", "faces.back", "faces.left", "faces.right",
        "faces.largest"];
    if (auto ax = axisName(info.normal))
        candidates ~= ["faces.normal(" ~ ax ~ ").largest"];
    foreach (c; candidates)
        if (unique(it, c, s, face))
            return c;
    return format("faces.filter(f => distance(f.center, %s) < 0.01.mm)", vecMm(info.center));
}

/// A selector expression that picks exactly edge `edge` of `s`.
string edgeSelector(Interp it, SolidVal s, int edge)
{
    auto adj = it.kernel.edgeFaces(s.brep)[edge];
    auto info = it.kernel.edges(s.brep)[edge];
    string[] named;    // readable selectors of the adjacent faces
    foreach (f; adj)
        if (f >= 0)
        {
            auto fs = faceSelector(it, s, f);
            if (!fs.canFind("filter"))
                named ~= fs;
        }
    string[] candidates;
    if (named.length == 2)
        candidates ~= format("edges.between(%s, %s)", named[0], named[1]);
    foreach (f; named)
    {
        if (info.kind == EdgeKind.circle)
            candidates ~= [format("edges.of(%s).circles", f),
                format("edges.of(%s).filter(e => e.isCircle && e.radius == %s)", f, mm(info.radius))];
        else if (info.kind == EdgeKind.line)
            if (auto ax = axisName(info.direction))
                candidates ~= format("edges.of(%s).parallel(%s)", f, ax[0] == '-' ? ax[1 .. $] : ax);
    }
    if (adj[0] >= 0 && adj[1] >= 0)
        candidates ~= format("edges.between(%s, %s)", faceSelector(it, s, adj[0]), faceSelector(it, s, adj[1]));
    foreach (c; candidates)
        if (unique(it, c, s, edge))
            return c;
    return format("edges.filter(e => distance(e.mid, %s) < 0.01.mm)", vecMm(info.mid));
}

/// One selector for several edges of `s`: a group that picks exactly them
/// when there is one (edges.parallel(Z), edges.of(faces.top)…), otherwise
/// their own selectors joined with +.
string edgesSelector(Interp it, SolidVal s, int[] edges)
{
    if (edges.length == 1)
        return edgeSelector(it, s, edges[0]);
    string[] candidates = ["edges.parallel(X)", "edges.parallel(Y)", "edges.parallel(Z)", "edges.circles", "edges.lines"];
    foreach (f; ["faces.top", "faces.bottom", "faces.front", "faces.back", "faces.left", "faces.right"])
    {
        candidates ~= ["edges.of(" ~ f ~ ")", "edges.of(" ~ f ~ ").circles", "edges.of(" ~ f ~ ").lines"];
        foreach (ax; ["X", "Y", "Z"])
            candidates ~= "edges.of(" ~ f ~ ").parallel(" ~ ax ~ ")";
    }
    foreach (c; candidates)
        if (exactly(it, c, s, edges))
            return c;
    string[] parts;
    foreach (e; edges)
        parts ~= edgeSelector(it, s, e);
    return parts.join(" + ");
}

/// One selector for several faces of `s`: a group that picks exactly them
/// when there is one (faces.normal(X)…), otherwise their own selectors joined with +.
string facesSelector(Interp it, SolidVal s, int[] faces)
{
    if (faces.length == 1)
        return faceSelector(it, s, faces[0]);
    foreach (ax; ["X", "Y", "Z"])
        if (exactly(it, "faces.normal(" ~ ax ~ ") + faces.normal(-" ~ ax ~ ")", s, faces))
            return "faces.normal(" ~ ax ~ ") + faces.normal(-" ~ ax ~ ")";
    string[] parts;
    foreach (f; faces)
        parts ~= faceSelector(it, s, f);
    return parts.join(" + ");
}

/// Whether `expr` selects exactly `items` (in any order).
private bool exactly(Interp it, string expr, SolidVal s, int[] items)
{
    import std.algorithm : sort;
    try
    {
        auto r = it.trySelector(expr, s).dup;
        auto want = items.dup;
        r.sort();
        want.sort();
        return r == want;
    }
    catch (HcadError)
        return false;
}

private bool unique(Interp it, string expr, SolidVal s, int index)
{
    try
    {
        auto r = it.trySelector(expr, s);
        return r.length == 1 && r[0] == index;
    }
    catch (HcadError)
        return false;
}

private string axisName(Vec3 n)
{
    foreach (i, name; ["X", "Y", "Z"])
    {
        immutable c = i == 0 ? n.x : i == 1 ? n.y : n.z;
        if (abs(abs(c) - 1) < 1e-9)
            return (c < 0 ? "-" : "") ~ name;
    }
    return null;
}

private string mm(double v) => format("%.6g.mm", abs(v) < 1e-9 ? 0.0 : v);
private string vecMm(Vec3 v) => format("vec(%s, %s, %s)", mm(v.x), mm(v.y), mm(v.z));

// ---------------------------------------------------------------- edits

/// Appends `call` (".fillet(…)") to the value returned by the @part function
/// `part`; `placeholder` (e.g. "1.mm"), if found in `call`, is selected.
Edit appendToPart(string source, string file, string part, string call, string placeholder = null)
{
    auto prog = parse(source, file);
    FuncDecl fn;
    foreach (d; prog.decls)
        if (auto f = cast(FuncDecl) d)
            if (f.name == part)
                fn = f;
    if (fn is null)
        throw new CodegenException(format("cannot find the function of part '%s' in this file", part));

    auto toks = lex(source, file);
    size_t first;   // index of the first token of the returned expression
    if (fn.exprBody !is null)
    {
        first = tokenAt(toks, fn.nameSpan);
        while (first < toks.length && toks[first].kind != Tok.arrow)
            first++;
        first++;
    }
    else
    {
        Return ret;
        foreach (st; fn.body.stmts)
            if (auto r = cast(Return) st)
                ret = r;
        if (ret is null || ret.value is null)
            throw new CodegenException(format("part '%s' has no final return statement to add to", part));
        first = tokenAt(toks, ret.span) + 1;
    }
    // the expression ends at the ';' closing the statement
    size_t last = first;
    int depth;
    bool operators;
    for (; last < toks.length; last++)
    {
        immutable k = toks[last].kind;
        if (depth == 0 && k == Tok.semicolon)
            break;
        if (k == Tok.lparen || k == Tok.lbracket || k == Tok.lbrace)
            depth++;
        else if (k == Tok.rparen || k == Tok.rbracket || k == Tok.rbrace)
            depth--;
        else if (depth == 0 && isOperator(k) && last > first)
            operators = true;
    }
    if (last >= toks.length)
        throw new CodegenException("cannot find the end of the returned expression");
    immutable start = offsetOf(source, toks[first].span);
    immutable end = offsetOf(source, toks[last].span);
    auto expr = trimRight(source[start .. end]);
    // a.b - c.fillet() would only round c: wrap expressions with operators
    auto body = operators ? "(" ~ expr ~ ")" : expr;
    // one call per line, starting with the dot, indented like the chain
    // already there (or one level deeper than the statement)
    size_t lineStart = start;
    while (lineStart > 0 && source[lineStart - 1] != '\n')
        lineStart--;
    size_t ws = lineStart;
    while (ws < source.length && (source[ws] == ' ' || source[ws] == '\t'))
        ws++;
    string indent = source[lineStart .. ws] ~ "    ";
    {
        import std.string : splitLines, stripLeft;
        foreach (l; expr.splitLines[1 .. $])
            if (l.stripLeft.length && l.stripLeft[0] == '.')
            {
                indent = l[0 .. l.length - l.stripLeft.length];
                break;
            }
    }
    // calls may span lines (a comment above them): indent every line
    import std.array : replace, join;
    import std.string : splitLines;
    if (fn.exprBody !is null)
        return toBlock(source, toks, fn, first, last, body, call, placeholder);
    string[] lines;
    foreach (l; call.splitLines)
        lines ~= wrapCall(l, indent);
    auto added = "\n" ~ lines.join("\n");
    Edit e;
    e.offset = start;
    e.length = expr.length;
    e.text = body ~ added;
    e.selectOffset = start + e.text.length;
    if (placeholder.length)
    {
        import std.string : lastIndexOf;
        auto at = added.lastIndexOf(placeholder);
        if (at >= 0)
        {
            e.selectOffset = start + body.length + at;
            e.selectLength = placeholder.length;
        }
    }
    return e;
}

/// `=> expr;` turned into a body with braces, the call added to the
/// returned chain: one statement per line reads better than a long
/// expression once features are added.
private Edit toBlock(string source, Token[] toks, FuncDecl fn, size_t first, size_t last, string body, string call,
    string placeholder)
{
    import std.array : join;
    import std.string : splitLines, lastIndexOf;
    auto arrow = first - 1;
    size_t from = offsetOf(source, toks[arrow].span);
    while (from > 0 && source[from - 1] == ' ')
        from--;
    immutable to = offsetOf(source, toks[last].span) + 1;   // after the ';'
    // the declaration's indentation
    size_t ls = offsetOf(source, fn.nameSpan);
    while (ls > 0 && source[ls - 1] != '\n')
        ls--;
    size_t le = ls;
    while (le < source.length && (source[le] == ' ' || source[le] == '\t'))
        le++;
    immutable decl = source[ls .. le];
    // the chain moves one level in: the lines after the first get four more spaces
    auto exprLines = body.splitLines;
    foreach (ref l; exprLines[1 .. $])
        if (l.length)
            l = "    " ~ l;
    string[] lines;
    foreach (l; call.splitLines)
        lines ~= wrapCall(l, decl ~ "        ");
    auto text = "\n" ~ decl ~ "{\n" ~ decl ~ "    return " ~ exprLines.join("\n") ~ "\n" ~ lines.join("\n") ~ ";\n"
        ~ decl ~ "}";
    Edit e;
    e.offset = from;
    e.length = to - from;
    e.text = text;
    e.selectOffset = from + text.length;
    if (placeholder.length)
    {
        auto at = text.lastIndexOf(placeholder);
        if (at >= 0)
        {
            e.selectOffset = from + at;
            e.selectLength = placeholder.length;
        }
    }
    return e;
}

/// One line of code at `indent`; a call longer than `width` continues on
/// the next lines, one more level in, breaking after the commas between its
/// arguments.
string wrapCall(string line, string indent, size_t width = 80)
{
    if (indent.length + line.length <= width)
        return indent ~ line;
    // split at the commas of the outermost call
    string[] pieces;
    int depth;
    size_t from;
    bool inString;
    foreach (i, c; line)
    {
        if (c == '"')
            inString = !inString;
        if (inString)
            continue;
        if (c == '(' || c == '[')
            depth++;
        else if (c == ')' || c == ']')
            depth--;
        else if (c == ',' && depth == 1)
        {
            pieces ~= line[from .. i + 1];
            from = i + 2 <= line.length && line[i + 1] == ' ' ? i + 2 : i + 1;
        }
    }
    pieces ~= line[from .. $];
    if (pieces.length < 2)
        return indent ~ line;
    // fill each line up to the width
    string r = indent, cur;
    immutable cont = indent ~ "    ";
    foreach (i, p; pieces)
    {
        auto lead = i == 0 ? indent : cont;
        if (cur.length && lead.length + cur.length + 1 + p.length > width)
        {
            r ~= cur ~ "\n";
            cur = null;
            r ~= cont;
        }
        cur ~= (cur.length ? " " : "") ~ p;
    }
    return r ~ cur;
}

/// Replaces the argument expression at line/col with `text`. The position
/// may fall anywhere in it (a value like 45.mm is known by its ".mm"): the
/// argument runs from the ',' or '(' before it to the ',' or ')' after it,
/// outside brackets.
Edit replaceArgument(string source, string file, uint line, uint col, string text)
{
    auto toks = lex(source, file);
    size_t first;
    while (first < toks.length && (toks[first].span.line < line || (toks[first].span.line == line && toks[first].span.col < col)))
        first++;
    if (first >= toks.length || toks[first].span.line != line || toks[first].span.col != col)
        throw new CodegenException("the value is no longer where it was: evaluate again");
    // back to the start of the argument
    {
        int depth;
        while (first > 0)
        {
            immutable k = toks[first - 1].kind;
            if (depth == 0 && (k == Tok.comma || k == Tok.lparen || k == Tok.lbracket || k == Tok.semicolon))
                break;
            if (k == Tok.rparen || k == Tok.rbracket || k == Tok.rbrace)
                depth++;
            else if (k == Tok.lparen || k == Tok.lbracket || k == Tok.lbrace)
                depth--;
            first--;
        }
    }
    // a named argument: skip "name:"
    if (first + 1 < toks.length && toks[first].kind == Tok.ident && toks[first + 1].kind == Tok.colon)
        first += 2;
    size_t last = first;
    int depth;
    for (; last < toks.length; last++)
    {
        immutable k = toks[last].kind;
        if (depth == 0 && (k == Tok.comma || k == Tok.rparen || k == Tok.semicolon))
            break;
        if (k == Tok.lparen || k == Tok.lbracket || k == Tok.lbrace)
            depth++;
        else if (k == Tok.rparen || k == Tok.rbracket || k == Tok.rbrace)
            depth--;
    }
    immutable start = offsetOf(source, toks[first].span), end = offsetOf(source, toks[last].span);
    Edit e;
    e.offset = start;
    e.length = trimRight(source[start .. end]).length;
    e.text = text;
    e.selectOffset = start;
    e.selectLength = text.length;
    return e;
}

unittest
{
    // from anywhere in the argument: its start, its ".mm", a named one
    immutable src = "s.length(back, 45.mm);\ns.distance(a, b, value: f(2) * 3.mm);\n";
    assert(argumentText(src, "t", 1, 16) == "45.mm");
    assert(argumentText(src, "t", 1, 18) == "45.mm");
    assert(argumentText(src, "t", 2, 33) == "f(2) * 3.mm");
    assert(argumentText(src, "t", 2, 18) == "f(2) * 3.mm");
    assert(replaceArgument(src, "t", 1, 18, "50.mm").apply(src).canFind("s.length(back, 50.mm);"));
}

/// The source text of the argument expression at line/col.
string argumentText(string source, string file, uint line, uint col)
{
    auto e = replaceArgument(source, file, line, col, "");
    return source[e.offset .. e.offset + e.length];
}

/// Byte offset of a 1-based line/column.
size_t offsetOf(string source, Span s)
{
    size_t o;
    uint l = 1;
    while (l < s.line && o < source.length)
        if (source[o++] == '\n')
            l++;
    return o + s.col - 1;
}

/// 0-based line and byte index in that line of a byte offset (for GtkTextBuffer).
void lineIndex(string source, size_t offset, out int line, out int index)
{
    size_t lineStart;
    foreach (i; 0 .. offset)
        if (source[i] == '\n')
        {
            line++;
            lineStart = i + 1;
        }
    index = cast(int)(offset - lineStart);
}

private size_t tokenAt(Token[] toks, Span s)
{
    foreach (i, t; toks)
        if (t.span.line == s.line && t.span.col == s.col)
            return i;
    throw new CodegenException("the source changed: evaluate again");
}

private bool isOperator(Tok k) => [Tok.plus, Tok.minus, Tok.mul, Tok.div, Tok.mod, Tok.tilde, Tok.pow, Tok.amp, Tok.pipe,
    Tok.caret, Tok.question, Tok.andAnd, Tok.orOr, Tok.eq, Tok.ne, Tok.lt, Tok.le, Tok.gt, Tok.ge].canFind(k);

private string trimRight(string s)
{
    while (s.length && (s[$ - 1] == ' ' || s[$ - 1] == '\n' || s[$ - 1] == '\t' || s[$ - 1] == '\r'))
        s = s[0 .. $ - 1];
    return s;
}

unittest
{
    import hackerscad.kernel.occt.backend : OcctKernel;

    enum src = "module m;\n@part Solid a() => box(10, 10, 10) - cylinder(d: 2, h: 20);\n"
        ~ "@part Solid b()\n{\n    auto s = box(5, 5, 5);\n    return s.move(x: 20);\n}\n";
    auto e = appendToPart(src, "m.hcad", "a", ".fillet(edges.parallel(Z), r: 1.mm)", "1.mm");
    auto out1 = e.apply(src);
    assert(out1.canFind("Solid a()\n{\n    return (box(10, 10, 10) - cylinder(d: 2, h: 20))\n"
        ~ "        .fillet(edges.parallel(Z), r: 1.mm);\n}\n"), out1);
    assert(out1[e.selectOffset .. e.selectOffset + e.selectLength] == "1.mm");
    auto e2 = appendToPart(src, "m.hcad", "b", ".shell(open: faces.top, thickness: 2.mm)", "2.mm");
    assert(e2.apply(src).canFind("return s.move(x: 20)\n        .shell(open: faces.top, thickness: 2.mm);"), e2.apply(src));
    // an existing chain keeps its indentation
    enum s3 = "module m;\n@part Solid c()\n{\n    return box(5, 5, 5)\n            .move(x: 1);\n}\n";
    auto e3 = appendToPart(s3, "m.hcad", "c", ".shell(open: faces.top, thickness: 1.mm)");
    assert(e3.apply(s3).canFind("            .move(x: 1)\n            .shell(open: faces.top, thickness: 1.mm);"), e3.apply(s3));

    // replacing an argument, named or positional
    enum s2 = "unittest { s.length(l, 40.mm); s.circle(c, d: 6.mm); }";
    assert(argumentText(s2, "x", 1, 24) == "40.mm");
    assert(replaceArgument(s2, "x", 1, 24, "45.mm").apply(s2) == "unittest { s.length(l, 45.mm); s.circle(c, d: 6.mm); }");
    assert(argumentText(s2, "x", 1, 44) == "6.mm");

    // selectors that pick exactly one face or edge
    auto it = new Interp(new OcctKernel);
    auto box = new SolidVal(it.kernel.translate(it.kernel.box(10, 20, 30), Vec3(-5, -10, 0)), Span.init);
    int top = -1, side = -1;
    foreach (i, f; it.kernel.faces(box.brep))
    {
        if (f.normal.z > 0.99)
            top = cast(int) i;
        if (f.normal.x > 0.99)
            side = cast(int) i;
    }
    assert(faceSelector(it, box, top) == "faces.top");
    int edge = -1;
    foreach (i, ef; it.kernel.edgeFaces(box.brep))
        if ((ef[0] == top && ef[1] == side) || (ef[0] == side && ef[1] == top))
            edge = cast(int) i;
    // the rim of a hole through the top
    auto holed = new SolidVal(it.kernel.boolean(box.brep, it.kernel.translate(it.kernel.cylinder(2, 50), Vec3(0, 0, -10)),
        BoolOp.cut), Span.init);
    int rim = -1;
    foreach (i, ed; it.kernel.edges(holed.brep))
        if (ed.kind == EdgeKind.circle && ed.center.z > 29.9)
            rim = cast(int) i;
    assert(edgeSelector(it, holed, rim) == "edges.of(faces.top).circles", edgeSelector(it, holed, rim));

    // long calls continue on the next lines
    auto w = wrapCall(".cut(circle(d: 3.4.mm), on: faces.top, at: vec(-4.845.mm, -0.3754.mm, 20.mm), depth: 5.mm)", "        ", 60);
    assert(w == "        .cut(circle(d: 3.4.mm), on: faces.top,\n            at: vec(-4.845.mm, -0.3754.mm, 20.mm),\n"
        ~ "            depth: 5.mm)", w);

    auto es = edgeSelector(it, box, edge);
    assert(es == "edges.between(faces.top, faces.right)" || es == "edges.between(faces.right, faces.top)", es);

    // several edges or faces: one group when there is one
    int[] vertical, topEdges, sides;
    foreach (i, ed; it.kernel.edges(box.brep))
    {
        if (abs(ed.direction.z) > 0.99)
            vertical ~= cast(int) i;
        if (ed.mid.z > 29.9)
            topEdges ~= cast(int) i;
    }
    foreach (i, f; it.kernel.faces(box.brep))
        if (abs(f.normal.x) > 0.99)
            sides ~= cast(int) i;
    assert(edgesSelector(it, box, vertical) == "edges.parallel(Z)", edgesSelector(it, box, vertical));
    assert(edgesSelector(it, box, topEdges) == "edges.of(faces.top)", edgesSelector(it, box, topEdges));
    assert(facesSelector(it, box, sides) == "faces.normal(X) + faces.normal(-X)", facesSelector(it, box, sides));
    // no group for two edges of different faces: each its own
    auto two = edgesSelector(it, box, [vertical[0], topEdges[0]]);
    assert(two.canFind(" + "), two);
}
