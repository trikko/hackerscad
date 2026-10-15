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
    // the face farthest one way, whichever way it faces (a tilted top), before its position
    candidates ~= ["faces.farthest(Z)", "faces.farthest(-Z)", "faces.farthest(X)", "faces.farthest(-X)",
        "faces.farthest(Y)", "faces.farthest(-Y)"];
    foreach (c; candidates)
        if (unique(it, c, s, face))
            return c;
    return format("faces.filter(f => distance(f.center, %s) < 0.01.mm)", vecMm(info.center));
}

/// Place on…'s call: the placed part's face `from` (a selector) laid
/// against the frame `onto`, `at` the point of it carried when that is not
/// its middle (null), turned by `turn` degrees about the frame's Z.
string placeOnCall(string onto, string from, string at, double turn)
{
    import std.math : round;
    // whole degrees stay whole, and a turn reads between -180 and 180
    auto t = turn - 360 * round(turn / 360);
    t = abs(t - round(t)) < 1e-6 ? round(t) : round(t * 1e6) / 1e6;
    if (t == -180)
        t = 180;
    if (t != 0)
        onto ~= format(".turn(%g.deg)", t);
    return format(".placeOn(%s, from: %s%s)", onto, from, at is null ? "" : ", at: " ~ at);
}

/// A frame on face `face` (a selector) of what `of` gives, its origin
/// `origin` when that is not the face's middle (null).
string frameExpr(string of, string face, string origin) =>
    format("%s.frame(%s%s)", of, face, origin is null ? "" : ", origin: " ~ origin);

/// The frame on the ground at `p` (its z ignored): World, moved there.
string groundFrame(Vec3 p)
{
    import std.math : round;
    string[] moved;
    foreach (i, n; ["x", "y"])
        if (abs(round(p[i] * 1000) / 1000) > 0)
            moved ~= n ~ ": " ~ mm(round(p[i] * 1000) / 1000);
    return moved.length ? "World.at(" ~ moved.join(", ") ~ ")" : "World";
}

/// A point to the thousandth of a millimetre, for placeOnCall and frameExpr.
string pointMm(Vec3 v)
{
    import std.math : round;
    foreach (i; 0 .. 3)
        v[i] = round(v[i] * 1000) / 1000;
    return vecMm(v);
}

unittest
{
    assert(placeOnCall("vase().frame(faces.farthest(Z))", "faces.bottom", null, 0)
        == ".placeOn(vase().frame(faces.farthest(Z)), from: faces.bottom)");
    assert(placeOnCall(groundFrame(Vec3(10, 0.00001, 0)), "faces.right", "vec(2.mm, 3.mm, 8.mm)", -270.0000001)
        == ".placeOn(World.at(x: 10.mm).turn(90.deg), from: faces.right, at: vec(2.mm, 3.mm, 8.mm))");
    assert(placeOnCall(groundFrame(Vec3(0, 0, 0)), "faces.top", null, -180) == ".placeOn(World.turn(180.deg), from: faces.top)");
    assert(frameExpr("base()", "faces.top", null) == "base().frame(faces.top)");
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

/// Where the value returned by the @part function `part` is in the source.
private struct Returned
{
    FuncDecl fn;
    Token[] toks;
    size_t first, last;   /// its first token, and the ';' after it
    bool operators;       /// a top-level operator in it (a - b)
    size_t start, end;    /// its text, trailing spaces left out
}

private Returned returned(string source, string file, string part)
{
    auto prog = parse(source, file);
    Returned r;
    foreach (d; prog.decls)
        if (auto f = cast(FuncDecl) d)
            if (f.name == part)
                r.fn = f;
    if (r.fn is null)
        throw new CodegenException(format("cannot find the function of part '%s' in this file", part));
    auto fn = r.fn;
    auto toks = r.toks = lex(source, file);
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
            if (auto rt = cast(Return) st)
                ret = rt;
        if (ret is null || ret.value is null)
            throw new CodegenException(format("part '%s' has no final return statement to add to", part));
        first = tokenAt(toks, ret.span) + 1;
    }
    // the expression ends at the ';' closing the statement
    size_t last = first;
    int depth;
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
            r.operators = true;
    }
    if (last >= toks.length)
        throw new CodegenException("cannot find the end of the returned expression");
    r.first = first;
    r.last = last;
    r.start = offsetOf(source, toks[first].span);
    r.end = r.start + trimRight(source[r.start .. offsetOf(source, toks[last].span)]).length;
    return r;
}

/// Appends `call` (".fillet(…)") to the value returned by the @part function
/// `part`; `placeholder` (e.g. "1.mm"), if found in `call`, is selected.
Edit appendToPart(string source, string file, string part, string call, string placeholder = null)
{
    auto r = returned(source, file, part);
    auto fn = r.fn;
    auto toks = r.toks;
    immutable first = r.first, last = r.last, operators = r.operators;
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

/// An angle (degrees) the short way: from -180 (left out) to 180.
double halfTurn(double a)
{
    import std.math : fmod;
    auto r = fmod(a, 360);
    if (r > 180)
        r -= 360;
    else if (r <= -180)
        r += 360;
    return abs(r) < 1e-9 ? 0 : r;
}

/// A turn as a matrix: about X by e.x, then Y by e.y, then Z by e.z
/// (degrees), as rotate(x:, y:, z:) does it.
double[3][3] turnMatrix(Vec3 e)
{
    import std.math : cos, sin, PI;
    double[3][3] m = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
    foreach (k; 0 .. 3)
    {
        immutable a = e[k] * PI / 180, c = cos(a), s = sin(a);
        immutable i = (k + 1) % 3, j = (k + 2) % 3;
        double[3][3] r = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
        r[i][i] = c;
        r[j][j] = c;
        r[j][i] = s;
        r[i][j] = -s;
        double[3][3] p;
        foreach (row; 0 .. 3)
            foreach (col; 0 .. 3)
            {
                p[row][col] = 0;
                foreach (q; 0 .. 3)
                    p[row][col] += r[row][q] * m[q][col];
            }
        m = p;
    }
    return m;
}

/// The angles about X, then Y, then Z (degrees) of a turn: the inverse of
/// turnMatrix, rounded to a thousandth of a degree.
Vec3 turnAngles(double[3][3] m)
{
    import std.math : asin, atan2, round, PI;
    // m = Rz(c) Ry(b) Rx(a): m[2][0] = -sin b
    immutable sb = -m[2][0] > 1 ? 1.0 : -m[2][0] < -1 ? -1.0 : -m[2][0];
    double a, b = asin(sb), c;
    if (abs(sb) < 1 - 1e-9)
    {
        a = atan2(m[2][1], m[2][2]);
        c = atan2(m[1][0], m[0][0]);
    }
    else
    {
        // straight up or down: X and Z turn about the same line, all of it on X
        c = 0;
        a = atan2(sb * m[0][1], m[1][1]);
    }
    double deg(double r)
    {
        auto d = round(r * 180 / PI * 1000) / 1000;
        return d == -180 ? 180 : d == 0 ? 0 : d;
    }
    return Vec3(deg(a), deg(b), deg(c));
}

/// Gives the part `part` the colour `colour` (a name, "#RRGGBB"), written as
/// the first argument of its @part: in place of the colour it had, or added;
/// the named arguments (alpha:, name:, export:) stay. The colour is selected.
Edit colourPart(string source, string file, string part, string colour)
{
    auto prog = parse(source, file);
    FuncDecl fn;
    foreach (d; prog.decls)
        if (auto f = cast(FuncDecl) d)
            if (f.name == part)
                fn = f;
    if (fn is null)
        throw new CodegenException(format("cannot find the function of part '%s' in this file", part));
    Attribute at;
    bool found;
    foreach (a; fn.attrs)
        if (a.name == "part" || a.name == "parts")
        {
            at = a;
            found = true;
        }
    if (!found)
        throw new CodegenException(format("'%s' has no @part", part));
    colour = `"` ~ colour ~ `"`;
    auto toks = lex(source, file);
    immutable i = tokenAt(toks, at.span);   // '@', then 'part', then '(' when it has arguments
    Edit e;
    if (at.args.length == 0 || i + 2 >= toks.length || toks[i + 2].kind != Tok.lparen)
    {
        // @part or @part(): the colour in brackets after the name
        e.offset = offsetOf(source, toks[i + 1].span) + toks[i + 1].text.length;
        immutable empty = i + 3 < toks.length && toks[i + 2].kind == Tok.lparen && toks[i + 3].kind == Tok.rparen;
        e.length = empty ? offsetOf(source, toks[i + 3].span) + 1 - e.offset : 0;
        e.text = "(" ~ colour ~ ")";
        e.selectOffset = e.offset + 1;
    }
    else if (at.args[0].name is null)
    {
        // the colour it had, up to the ',' or ')' after it
        size_t j = tokenAt(toks, at.args[0].span);
        int depth;
        for (; j < toks.length; j++)
        {
            immutable k = toks[j].kind;
            if (depth == 0 && (k == Tok.comma || k == Tok.rparen))
                break;
            if (k == Tok.lparen || k == Tok.lbracket || k == Tok.lbrace)
                depth++;
            else if (k == Tok.rparen || k == Tok.rbracket || k == Tok.rbrace)
                depth--;
        }
        if (j >= toks.length)
            throw new CodegenException("cannot find the end of the colour of @part");
        e.offset = offsetOf(source, at.args[0].span);
        e.length = trimRight(source[e.offset .. offsetOf(source, toks[j].span)]).length;
        e.text = colour;
        e.selectOffset = e.offset;
    }
    else
    {
        // only named arguments: the colour first
        e.offset = offsetOf(source, toks[i + 2].span) + 1;
        e.text = colour ~ ", ";
        e.selectOffset = e.offset;
    }
    e.selectLength = colour.length;
    return e;
}

unittest
{
    // added to a bare @part, to an empty one and before named arguments;
    // replaced, a name or an expression too, the named arguments kept
    auto src = "module m;\n\n@part\nSolid p() => box(10, 10, 10);\n";
    auto e = colourPart(src, "m.hcad", "p", "Sky Pop");
    auto a = e.apply(src);
    assert(a.canFind(`@part("Sky Pop")` ~ "\nSolid p()"), a);
    assert(a[e.selectOffset .. e.selectOffset + e.selectLength] == `"Sky Pop"`, a);
    assert(colourPart(a, "m.hcad", "p", "#FF8A82").apply(a).canFind(`@part("#FF8A82")`));
    auto b = "module m;\n\n@part()\nSolid p() => box(1, 1, 1);\n";
    assert(colourPart(b, "m.hcad", "p", "White Pop").apply(b).canFind(`@part("White Pop")` ~ "\n"));
    auto c = "module m;\n\n@part(name: \"Lid\", alpha: 0.4)\nSolid p() => box(1, 1, 1);\n";
    assert(colourPart(c, "m.hcad", "p", "Violet Pop").apply(c).canFind(`@part("Violet Pop", name: "Lid", alpha: 0.4)`));
    auto d = "module m;\n\n@part(\"sienna\" , alpha: 0.5)\nSolid p() => box(1, 1, 1);\n";
    assert(colourPart(d, "m.hcad", "p", "Cyan Pop").apply(d).canFind(`@part("Cyan Pop" , alpha: 0.5)`));
    auto f = "module m;\nimmutable string tint = \"red\";\n@part(tint ~ \"\", export: false)\nSolid p() => box(1, 1, 1);\n";
    assert(colourPart(f, "m.hcad", "p", "Gray Pop").apply(f).canFind(`@part("Gray Pop", export: false)`));
    // @parts too
    auto h = "module m;\n\n@parts\nSolid p() => box(1, 1, 1);\n";
    assert(colourPart(h, "m.hcad", "p", "Red Pop").apply(h).canFind(`@parts("Red Pop")` ~ "\nSolid p()"));
    auto i = "module m;\n\n@parts(varied: true)\nSolid p() => box(1, 1, 1);\n";
    assert(colourPart(i, "m.hcad", "p", "Red Pop").apply(i).canFind(`@parts("Red Pop", varied: true)`));
    // a function that is not a part
    auto g = "module m;\n\nSolid p() => box(1, 1, 1);\n";
    bool threw;
    try
        colourPart(g, "m.hcad", "p", "Red Pop");
    catch (CodegenException)
        threw = true;
    assert(threw);
}

/// Splits the part `part` along the plane of normal `n` at `offset` (mm
/// along it): the part becomes a plain function, an immutable keeps the plane,
/// and `<part>Pieces` takes its place, `@parts(varied: true)` on what
/// `split` gives: a part of each piece, however many the cut leaves (a cut
/// across a slot makes more than two), each in its own colour.
Edit splitPart(string source, string file, string part, Vec3 n, double offset)
{
    import std.math : round;
    import std.regex : regex, replaceAll;
    import std.string : strip;
    auto prog = parse(source, file);
    FuncDecl fn;
    bool[string] taken;
    foreach (d; prog.decls)
    {
        if (auto f = cast(FuncDecl) d)
        {
            taken[f.name] = true;
            if (f.name == part)
                fn = f;
        }
        else if (auto v = cast(VarDecl) d)
            taken[v.name] = true;
    }
    if (fn is null)
        throw new CodegenException(format("cannot find the function of part '%s' in this file", part));
    Attribute at;
    bool found;
    foreach (a; fn.attrs)
        if (a.name == "part")
        {
            at = a;
            found = true;
        }
    if (!found)
        throw new CodegenException(format("'%s' has no @part", part));
    string fresh(string want)
    {
        auto name = want;
        for (int k = 2; name in taken; k++)
            name = format("%s%d", want, k);
        taken[name] = true;
        return name;
    }
    immutable cutName = fresh(part ~ "Cut"), pieces = fresh(part ~ "Pieces");

    auto toks = lex(source, file);
    immutable i = tokenAt(toks, at.span);
    // the annotation's text, up to its ')' or its name
    size_t attrEnd;
    if (i + 2 < toks.length && toks[i + 2].kind == Tok.lparen)
    {
        size_t j = i + 2;
        int depth;
        for (; j < toks.length; j++)
        {
            if (toks[j].kind == Tok.lparen)
                depth++;
            else if (toks[j].kind == Tok.rparen && --depth == 0)
                break;
        }
        attrEnd = offsetOf(source, toks[j].span) + 1;
    }
    else
        attrEnd = offsetOf(source, toks[i + 1].span) + toks[i + 1].text.length;
    immutable attrStart = offsetOf(source, at.span);
    // two parts cannot share a name: a name: of the part's own stays behind;
    // @part becomes @parts, its pieces in colours that tell apart
    auto args = source[attrStart .. attrEnd].replaceAll(regex(`^@parts?\s*\(?`), "").replaceAll(regex(`\)$`), "")
        .replaceAll(regex(`,?\s*name:\s*"[^"]*"`), "").replaceAll(regex(`,?\s*varied:\s*\w+`), "")
        .replaceAll(regex(`^\s*,\s*`), "").strip;
    immutable attr = "@parts(" ~ (args.length ? args ~ ", " : "") ~ "varied: true)";
    // the annotation and the line break after it go
    size_t cut = attrEnd;
    while (cut < source.length && (source[cut] == ' ' || source[cut] == '\t'))
        cut++;
    if (cut < source.length && source[cut] == '\n')
        cut++;

    // where the function ends: its ';' (=> body) or its closing '}'
    size_t k = tokenAt(toks, fn.nameSpan);
    while (k < toks.length && toks[k].kind != Tok.arrow && toks[k].kind != Tok.lbrace)
        k++;
    int depth;
    for (; k < toks.length; k++)
    {
        immutable kind = toks[k].kind;
        if (kind == Tok.lparen || kind == Tok.lbracket || kind == Tok.lbrace)
            depth++;
        else if (kind == Tok.rparen || kind == Tok.rbracket || kind == Tok.rbrace)
        {
            if (--depth == 0 && kind == Tok.rbrace && fn.exprBody is null)
                break;
        }
        else if (depth == 0 && kind == Tok.semicolon && fn.exprBody !is null)
            break;
    }
    if (k >= toks.length)
        throw new CodegenException(format("cannot find the end of the function of part '%s'", part));
    immutable fnEnd = offsetOf(source, toks[k].span) + 1;

    // the plane: a main axis by its name, else the normal's numbers
    n = n.normalized;
    string number(double x) => format("%.6g", abs(x) < 1e-9 ? 0.0 : round(x * 1e6) / 1e6);
    string normal;
    foreach (a, name; ["X", "Y", "Z"])
    {
        if (abs(n[a] - 1) < 1e-9)
            normal = name;
        else if (abs(n[a] + 1) < 1e-9)
            normal = "-" ~ name;
    }
    if (normal is null)
        normal = format("vec(%s, %s, %s)", number(n.x), number(n.y), number(n.z));
    auto origin = n * offset;
    foreach (a; 0 .. 3)
        origin[a] = round(origin[a] * 1000) / 1000;
    immutable code = format("\n\n// %s, cut by Split… in the 3D view: a part of each piece the cut leaves,\n"
        ~ "// however many, each in its own colour\n"
        ~ "immutable %s = plane(origin: %s, normal: %s);\n\n%s\nSolid[] %s() => %s().split(%s);",
        part, cutName, vecMm(origin), normal, attr, pieces, part, cutName);
    auto after = source[0 .. attrStart] ~ source[cut .. fnEnd] ~ code ~ source[fnEnd .. $];
    // only what changed is replaced: between what both texts start and end with
    size_t head, tail;
    while (head < source.length && head < after.length && source[head] == after[head])
        head++;
    while (tail < source.length - head && tail < after.length - head && source[$ - 1 - tail] == after[$ - 1 - tail])
        tail++;
    Edit e;
    e.offset = head;
    e.length = source.length - head - tail;
    e.text = after[head .. $ - tail];
    e.selectOffset = after.length - tail;
    return e;
}

unittest
{
    // the part becomes a function, its pieces @parts in varied colours; a
    // name of its own left out
    auto src = "module m;\n\nimport std.shapes;\n\n@part(\"Sky Pop\", name: \"Clip\")\nSolid clip()\n{\n"
        ~ "    return box(10.mm, 10.mm, 10.mm);\n}\n\n@part\nSolid other() => clip().move(x: 20.mm);\n";
    auto a = splitPart(src, "m.hcad", "clip", Vec3(0, 0, 1), 5).apply(src);
    assert(a.canFind("Solid clip()\n{") && !a.canFind(`name: "Clip"`), a);
    assert(a.canFind("immutable clipCut = plane(origin: vec(0.mm, 0.mm, 5.mm), normal: Z);"), a);
    assert(a.canFind("@parts(\"Sky Pop\", varied: true)\nSolid[] clipPieces() => clip().split(clipCut);"), a);
    assert(a.canFind("@part\nSolid other()"), a);
    // an => part without arguments, a slanted plane, names already taken
    auto b = "module m;\n\n@part\nSolid p() => box(1.mm, 1.mm, 1.mm);\n\nimmutable pCut = 3;\n";
    auto c = splitPart(b, "m.hcad", "p", Vec3(1, 0, 1), 0).apply(b);
    assert(c.canFind("Solid p() => box(1.mm, 1.mm, 1.mm);\n\n// p, cut"), c);
    assert(c.canFind("immutable pCut2 = plane(origin: vec(0.mm, 0.mm, 0.mm), normal: vec(0.707107, 0, 0.707107));"), c);
    assert(c.canFind("@parts(varied: true)\nSolid[] pPieces() => p().split(pCut2);"), c);
    assert(!c.canFind("@part\nSolid p()"), c);
}

/// Moves the part `part` by `v` (kind "move", mm), or turns it (kind
/// "rotate": `v` the angles about X, then Y, then Z in degrees) about
/// `around`, or scales it (kind "scale": `v` the factors along X, Y and Z)
/// keeping `around` where it is. When its chain already ends with such a
/// call holding plain numbers (for a turn, about the same point), the two
/// make one call, or none when they come to nothing; otherwise one is added.
Edit transformPart(string source, string file, string part, string kind, Vec3 v, Vec3 around = Vec3(0, 0, 0))
{
    auto r = returned(source, file, part);
    return transformExpr(source, r.start, r.end, r.operators, kind, v, around,
        (string call) => appendToPart(source, file, part, call));
}

/// The core of transformPart, on the expression at [start, end) of `source`
/// (`operators`: a top-level operator in it): its last call changed when it is
/// such a move or turn, else `append` adds the call.
private Edit transformExpr(string source, size_t start, size_t end, bool operators, string kind, Vec3 v, Vec3 around,
    Edit delegate(string call) append)
{
    import std.conv : to;
    import std.regex : matchFirst, regex;
    immutable num = `-?[0-9]+(?:\.[0-9]+)?(?:e-?[0-9]+)?`;
    string number(double x) => format("%.6g", abs(x) < 1e-9 ? 0.0 : x);
    // a turn and the point it turns about, the shortest way to write them
    string turnCall(Vec3 angles, Vec3 pivot)
    {
        foreach (i; 0 .. 3)
            angles[i] = halfTurn(angles[i]);
        string[] args;
        foreach (i, n; ["x", "y", "z"])
            if (abs(angles[i]) > 1e-9)
                args ~= n ~ ": " ~ number(angles[i]);
        if (args.length == 0)
            return null;
        // only the pivot's part across the axis matters: along it, it moves nothing
        auto u = turnAxis(turnMatrix(angles));
        pivot = pivot - u * pivot.dot(u);
        foreach (i; 0 .. 3)
        {
            import std.math : round;
            pivot[i] = round(pivot[i] * 1000) / 1000;
        }
        if (pivot.length > 1e-6)
            args ~= "around: " ~ vecMm(pivot);
        return ".rotate(" ~ args.join(", ") ~ ")";
    }
    string moveCall(Vec3 w)
    {
        string[] args;
        foreach (i, n; ["x", "y", "z"])
            if (abs(w[i]) > 1e-9)
                args ~= n ~ ": " ~ number(w[i]) ~ ".mm";
        return args.length ? ".move(" ~ args.join(", ") ~ ")" : null;
    }
    struct R { size_t start; }
    immutable r = R(start);
    auto expr = source[start .. end];
    LastCall c;
    if (kind == "scale")
        return scaleExpr(source, start, expr, operators, v, around, append);
    if (!operators && lastCall(expr, c) && !c.positional && c.name == kind)
    {
        // the numbers it holds, or none when one is not plain
        bool plain = true;
        Vec3 had, pivot;
        foreach (name, value; c.args)
        {
            immutable axis = ["x": 0, "y": 1, "z": 2].get(name, -1);
            if (axis >= 0)
            {
                auto m = value.matchFirst(regex("^(" ~ num ~ ")" ~ (kind == "move" ? `\.mm$` : `(?:\.deg)?$`)));
                if (m.empty)
                    plain = false;
                else
                    had[axis] = m[1].to!double;
            }
            else if (kind == "rotate" && name == "around")
            {
                auto m = value.matchFirst(regex(`^vec\((` ~ num ~ `)\.mm, (` ~ num ~ `)\.mm, (` ~ num ~ `)\.mm\)$`));
                if (m.empty)
                    plain = false;
                else
                    pivot = Vec3(m[1].to!double, m[2].to!double, m[3].to!double);
            }
            else
                plain = false;
        }
        string call;
        if (plain && kind == "move")
            call = moveCall(had + v);
        else if (plain)
        {
            // the turn there, then the new one: one turn about some point, when
            // there is one (two turns about different points can leave a slide
            // along the axis, which no single turn makes)
            auto m1 = turnMatrix(had), m2 = turnMatrix(v);
            auto m = product(m2, m1);
            // where each sends the origin: t = (I - R) p
            auto t = apply(m2, pivot - apply(m1, pivot)) + (around - apply(m2, around));
            Vec3 p;
            if (isIdentity(m))
                plain = t.length < 1e-6;   // undone: nothing left, or a move no turn makes
            else
                plain = pivotOf(m, t, p);
            if (plain && !isIdentity(m))
                call = turnCall(turnAngles(m), p);
        }
        if (plain)
        {
            Edit e;
            e.offset = r.start + c.start;
            e.length = c.end - c.start;
            if (call is null)
            {
                // nothing left: the call goes, with the line break before it
                size_t from = e.offset;
                while (from > r.start && (source[from - 1] == ' ' || source[from - 1] == '\t' || source[from - 1] == '\n'))
                    from--;
                e.length += e.offset - from;
                e.offset = from;
                e.text = "";
            }
            else
                e.text = call;
            e.selectOffset = e.offset + e.text.length;
            return e;
        }
    }
    auto call = kind == "move" ? moveCall(v) : turnCall(v, around);
    if (call is null)
        throw new CodegenException("nothing to move or turn");
    return append(call);
}

/// A scale by the factors `f` (along X, Y, Z) that keeps `pivot` where it
/// is, the shortest way to write it: one factor when they are all the same,
/// else the ones that are not 1; around: only when the point is not the
/// origin, and only along the axes that scale. Null when nothing scales.
string scaleCall(Vec3 f, Vec3 pivot)
{
    import std.math : round;
    string number(double x) => format("%.6g", round(x * 1e6) / 1e6);
    foreach (i; 0 .. 3)
        if (abs(f[i] - 1) < 1e-9)
        {
            f[i] = 1;
            pivot[i] = 0;   // along an axis that does not scale, it moves nothing
        }
        else
            pivot[i] = round(pivot[i] * 1000) / 1000;
    string[] args;
    if (f.x == f.y && f.y == f.z)
    {
        if (f.x == 1)
            return null;
        args ~= number(f.x);
    }
    else
        foreach (i, n; ["x", "y", "z"])
            if (f[i] != 1)
                args ~= n ~ ": " ~ number(f[i]);
    if (pivot.length > 1e-6)
        args ~= "around: " ~ vecMm(pivot);
    return ".scale(" ~ args.join(", ") ~ ")";
}

/// transformExpr for a scale: a plain scale last in the chain takes this one
/// in (one scale about some point, or none when they come to nothing),
/// else `append` adds it.
private Edit scaleExpr(string source, size_t start, string expr, bool operators, Vec3 f, Vec3 around,
    Edit delegate(string call) append)
{
    import std.conv : to;
    import std.regex : matchFirst, regex;
    immutable num = `-?[0-9]+(?:\.[0-9]+)?(?:e-?[0-9]+)?`;
    LastCall c;
    if (!operators && lastCall(expr, c) && c.name == "scale" && c.unnamed.length <= 1)
    {
        bool plain = true;
        Vec3 had = Vec3(1, 1, 1), pivot;
        if (c.unnamed.length == 1)
        {
            if (c.unnamed[0].matchFirst(regex("^" ~ num ~ "$")).empty)
                plain = false;
            else
                had = Vec3(1, 1, 1) * c.unnamed[0].to!double;
        }
        foreach (name, value; c.args)
        {
            immutable axis = ["x": 0, "y": 1, "z": 2].get(name, -1);
            if (axis >= 0 && c.unnamed.length == 0 && !value.matchFirst(regex("^" ~ num ~ "$")).empty)
                had[axis] = value.to!double;
            else if (name == "around")
            {
                auto m = value.matchFirst(regex(`^vec\((` ~ num ~ `)\.mm, (` ~ num ~ `)\.mm, (` ~ num ~ `)\.mm\)$`));
                if (m.empty)
                    plain = false;
                else
                    pivot = Vec3(m[1].to!double, m[2].to!double, m[3].to!double);
            }
            else
                plain = false;
        }
        // x -> f (had (x - p) + p - q) + q: factors f * had, and the point
        // that stays, axis by axis, where (1 - s) q' = what it moves
        Vec3 s, q;
        foreach (i; 0 .. 3)
        {
            s[i] = f[i] * had[i];
            immutable t = f[i] * (pivot[i] - had[i] * pivot[i] - around[i]) + around[i];
            if (abs(s[i] - 1) > 1e-9)
                q[i] = t / (1 - s[i]);
            else if (abs(t) > 1e-6)
                plain = false;   // undone along it, but moved: no scale writes that
        }
        if (plain)
        {
            Edit e;
            e.offset = start + c.start;
            e.length = c.end - c.start;
            e.text = scaleCall(s, q);
            if (e.text is null)
            {
                // nothing left: the call goes, with the line break before it
                size_t from = e.offset;
                while (from > start && (source[from - 1] == ' ' || source[from - 1] == '\t' || source[from - 1] == '\n'))
                    from--;
                e.length += e.offset - from;
                e.offset = from;
            }
            e.selectOffset = e.offset + e.text.length;
            return e;
        }
    }
    auto call = scaleCall(f, around);
    if (call is null)
        throw new CodegenException("nothing to scale");
    return append(call);
}

/// Piece `index` of the @parts function `part` (`fromSolid`: it returns a
/// Solid, made into pieces): the source with a statement
/// `pieces[index] = pieces[index]…;` before its return, the function made a
/// block that takes its pieces apart first if it is not one yet, and where
/// that statement's right side is. A move, a turn or a feature of one piece
/// goes there, and the list is returned with it changed.
string pieceStatement(string source, string file, string part, size_t index, bool fromSolid,
    out size_t rhsStart, out size_t rhsEnd, out bool operators)
{
    import std.regex : matchFirst, regex;
    import std.string : strip;
    auto r = returned(source, file, part);
    auto fn = r.fn;
    auto toks = r.toks;
    immutable expr = source[r.start .. r.end].strip;
    immutable from = tokenAt(toks, fn.nameSpan);
    // the list is in a variable of the body, returned as it is (a Solid is made into pieces first)
    string var;
    if (!fromSolid && fn.exprBody is null && !expr.matchFirst(regex(`^[A-Za-z_]\w*$`)).empty)
        foreach (j; from .. r.first)
            if (toks[j].kind == Tok.ident && toks[j].text == expr && j > 0 && toks[j - 1].kind == Tok.kwAuto)
                var = expr;
    if (var is null)
    {
        // reshape: auto pieces = <what it returned>; return pieces;
        bool[string] used;
        foreach (j; from .. toks.length)
            if (toks[j].kind == Tok.ident)
                used[toks[j].text] = true;
        string name = "pieces";
        for (int k = 2; name in used; k++)
            name = format("pieces%d", k);
        immutable list = expr ~ (fromSolid ? ".pieces" : "");
        string after;
        immutable semi = offsetOf(source, toks[r.last].span) + 1;
        if (fn.exprBody !is null)
        {
            size_t arrow = r.first - 1;
            size_t cut = offsetOf(source, toks[arrow].span);
            while (cut > 0 && (source[cut - 1] == ' ' || source[cut - 1] == '\t' || source[cut - 1] == '\n'))
                cut--;
            after = source[0 .. cut] ~ format("\n{\n    auto %s = %s;\n    return %s;\n}", name, list, name) ~ source[semi .. $];
        }
        else
        {
            immutable ret = offsetOf(source, toks[r.first - 1].span);   // the 'return'
            size_t lineStart = ret;
            while (lineStart > 0 && source[lineStart - 1] != '\n')
                lineStart--;
            immutable indent = source[lineStart .. ret];
            after = source[0 .. ret] ~ format("auto %s = %s;\n%sreturn %s;", name, list, indent, name) ~ source[semi .. $];
        }
        // a Solid split into pieces returns a list now
        if (fromSolid && fn.returnType !is null && fn.returnType.name == "Solid" && !fn.returnType.isArray)
        {
            immutable t = offsetOf(source, fn.returnType.span) + "Solid".length;
            after = after[0 .. t] ~ "[]" ~ after[t .. $];
        }
        return pieceStatement(after, file, part, index, false, rhsStart, rhsEnd, operators);
    }
    // its statement for this piece, or one made before the return
    immutable want = format("%d", index);
    foreach (j; from .. r.first)
        if (j + 5 < toks.length && toks[j].kind == Tok.ident && toks[j].text == var && toks[j + 1].kind == Tok.lbracket
            && toks[j + 2].kind == Tok.intLit && toks[j + 2].text == want && toks[j + 3].kind == Tok.rbracket
            && toks[j + 4].kind == Tok.assign && (j == 0 || toks[j - 1].kind == Tok.semicolon || toks[j - 1].kind == Tok.lbrace
                || toks[j - 1].kind == Tok.rbrace))
        {
            size_t k = j + 5;
            int depth;
            for (; k < toks.length; k++)
            {
                immutable kind = toks[k].kind;
                if (depth == 0 && kind == Tok.semicolon)
                    break;
                if (kind == Tok.lparen || kind == Tok.lbracket || kind == Tok.lbrace)
                    depth++;
                else if (kind == Tok.rparen || kind == Tok.rbracket || kind == Tok.rbrace)
                    depth--;
                else if (depth == 0 && isOperator(kind) && k > j + 5)
                    operators = true;
            }
            rhsStart = offsetOf(source, toks[j + 5].span);
            rhsEnd = rhsStart + trimRight(source[rhsStart .. offsetOf(source, toks[k].span)]).length;
            return source;
        }
    immutable ret = offsetOf(source, toks[r.first - 1].span);
    size_t lineStart = ret;
    while (lineStart > 0 && source[lineStart - 1] != '\n')
        lineStart--;
    immutable indent = source[lineStart .. ret];
    auto after = source[0 .. lineStart] ~ format("%s%s[%d] = %s[%d];\n", indent, var, index, var, index) ~ source[lineStart .. $];
    return pieceStatement(after, file, part, index, false, rhsStart, rhsEnd, operators);
}

/// `call` added at the end of the expression at [start, end) (wrapped when
/// it has an operator), `placeholder` in it selected.
private Edit appendAt(string source, size_t start, size_t end, bool operators, string call, string placeholder = null)
{
    auto expr = source[start .. end];
    auto body = operators ? "(" ~ expr ~ ")" : expr;
    Edit e;
    e.offset = start;
    e.length = expr.length;
    e.text = body ~ call;
    e.selectOffset = start + e.text.length;
    if (placeholder.length)
    {
        import std.string : lastIndexOf;
        auto at = call.lastIndexOf(placeholder);
        if (at >= 0)
        {
            e.selectOffset = start + body.length + at;
            e.selectLength = placeholder.length;
        }
    }
    return e;
}

/// One edit from `source` to `after`, between what both start and end with;
/// the selection of `e`, made on the way to `after`, kept.
private Edit between(string source, string after, Edit e)
{
    size_t head, tail;
    while (head < source.length && head < after.length && source[head] == after[head])
        head++;
    while (tail < source.length - head && tail < after.length - head && source[$ - 1 - tail] == after[$ - 1 - tail])
        tail++;
    Edit r;
    r.offset = head;
    r.length = source.length - head - tail;
    r.text = after[head .. $ - tail];
    r.selectOffset = e.selectOffset;
    r.selectLength = e.selectLength;
    return r;
}

/// The axis through `origin` along `dir` as the arguments of rotate after
/// the angle: the direction (a main one by its name), then around: the
/// axis's point nearest the world's origin, so one axis always reads the
/// same. No axis() call: a model may use that name for a value of its own.
private string axisCode(Vec3 origin, Vec3 dir)
{
    import std.math : round;
    dir = dir.normalized;
    string number(double x) => format("%.6g", abs(x) < 1e-9 ? 0.0 : round(x * 1e6) / 1e6);
    string d;
    foreach (a, name; ["X", "Y", "Z"])
    {
        if (abs(dir[a] - 1) < 1e-9)
            d = name;
        else if (abs(dir[a] + 1) < 1e-9)
            d = "-" ~ name;
    }
    if (d is null)
        d = format("vec(%s, %s, %s)", number(dir.x), number(dir.y), number(dir.z));
    auto o = origin - dir * origin.dot(dir);
    foreach (a; 0 .. 3)
        o[a] = round(o[a] * 1000) / 1000;
    return o.length < 1e-9 ? d : format("%s, around: %s", d, vecMm(o));
}

/// A turn of `angle` degrees about the axis through `origin` along `dir`
/// (counter-clockwise looking down it) at the end of the expression at
/// [start, end): a turn about the same axis already last there takes it in
/// (and goes when they come to nothing), else `append` adds it.
private Edit hingeExpr(string source, size_t start, size_t end, bool operators, double angle, Vec3 origin, Vec3 dir,
    Edit delegate(string call) append)
{
    import std.conv : to;
    import std.regex : matchFirst, regex, escaper;
    import std.array : array;
    immutable ax = axisCode(origin, dir);
    string call(double a) => abs(halfTurn(a)) < 1e-9 ? null : format(".rotate(%s.deg, %s)", format("%.6g", halfTurn(a)), ax);
    auto expr = source[start .. end];
    LastCall c;
    if (!operators && lastCall(expr, c) && c.name == "rotate")
    {
        auto m = expr[c.start .. c.end].matchFirst(regex(`^\.rotate\((-?[0-9]+(?:\.[0-9]+)?(?:e-?[0-9]+)?)\.deg,\s*(.*)\)$`));
        if (!m.empty && m[2] == ax)
        {
            Edit e;
            e.offset = start + c.start;
            e.length = c.end - c.start;
            e.text = call(m[1].to!double + angle);
            if (e.text is null)
            {
                // nothing left: the call goes, with the line break before it
                size_t from = e.offset;
                while (from > start && (source[from - 1] == ' ' || source[from - 1] == '\t' || source[from - 1] == '\n'))
                    from--;
                e.length += e.offset - from;
                e.offset = from;
            }
            e.selectOffset = e.offset + e.text.length;
            return e;
        }
    }
    auto text = call(angle);
    if (text is null)
        throw new CodegenException("nothing to turn");
    return append(text);
}

/// Turns the part `part` by `angle` degrees about the axis through `origin`
/// along `dir` (a face's normal, a hole's axis, an edge), as the hinge ring does.
Edit hingePart(string source, string file, string part, double angle, Vec3 origin, Vec3 dir)
{
    auto r = returned(source, file, part);
    return hingeExpr(source, r.start, r.end, r.operators, angle, origin, dir,
        (string call) => appendToPart(source, file, part, call));
}

/// hingePart for piece `index` of a @parts function: that piece alone.
Edit hingePiece(string source, string file, string part, size_t index, bool fromSolid, double angle, Vec3 origin, Vec3 dir)
{
    size_t a, b;
    bool ops;
    auto src = pieceStatement(source, file, part, index, fromSolid, a, b, ops);
    auto e = hingeExpr(src, a, b, ops, angle, origin, dir, (string call) => appendAt(src, a, b, ops, call));
    return between(source, e.apply(src), e);
}

unittest
{
    // a turn about an edge: added, joined with the next about the same axis,
    // gone when they come to nothing; another axis is a new call
    auto src = "module m;\n\n@part\nSolid p() => box(10, 10, 10);\n";
    auto a = hingePart(src, "m.hcad", "p", 30, Vec3(5, 3, 10), Vec3(0, 1, 0)).apply(src);
    assert(a.canFind(".rotate(30.deg, Y, around: vec(5.mm, 0.mm, 10.mm))"), a);
    auto b = hingePart(a, "m.hcad", "p", 15, Vec3(5, 8, 10), Vec3(0, 1, 0)).apply(a);
    assert(b.canFind(".rotate(45.deg, Y, around: vec(5.mm, 0.mm, 10.mm))") && !b.canFind("30.deg"), b);
    auto c = hingePart(b, "m.hcad", "p", -45, Vec3(5, 0, 10), Vec3(0, 1, 0)).apply(b);
    assert(!c.canFind(".rotate("), c);
    auto d = hingePart(a, "m.hcad", "p", 20, Vec3(0, 0, 0), Vec3(1, 1, 0)).apply(a);
    assert(d.canFind("30.deg") && d.canFind(".rotate(20.deg, vec(0.707107, 0.707107, 0))"), d);
    // on a piece
    auto e = "module m;\n\n@parts\nSolid[] q() => box(10, 10, 10).split(XY.offset(5.mm));\n";
    auto f = hingePiece(e, "m.hcad", "q", 1, false, 90, Vec3(0, 0, 10), Vec3(0, 0, -1)).apply(e);
    assert(f.canFind("pieces[1] = pieces[1].rotate(90.deg, -Z);"), f);
}

/// transformPart for piece `index` of a @parts function: only that piece moves or turns.
Edit transformPiece(string source, string file, string part, size_t index, bool fromSolid, string kind, Vec3 v,
    Vec3 around = Vec3(0, 0, 0))
{
    size_t a, b;
    bool ops;
    auto src = pieceStatement(source, file, part, index, fromSolid, a, b, ops);
    auto e = transformExpr(src, a, b, ops, kind, v, around, (string call) => appendAt(src, a, b, ops, call));
    return between(source, e.apply(src), e);
}

/// appendToPart for piece `index` of a @parts function: the feature on that piece only.
Edit appendToPiece(string source, string file, string part, size_t index, bool fromSolid, string call,
    string placeholder = null)
{
    import std.string : strip;
    size_t a, b;
    bool ops;
    auto src = pieceStatement(source, file, part, index, fromSolid, a, b, ops);
    auto e = appendAt(src, a, b, ops, call.strip, placeholder);
    return between(source, e.apply(src), e);
}

unittest
{
    // a piece of a list: the function takes its pieces apart, that one turns,
    // the list is returned; a second turn joins the first; another piece gets its own line
    auto src = "module m;

@parts
Solid[] p() => box(10, 10, 10).split(XY.offset(5.mm));
";
    auto a = transformPiece(src, "m.hcad", "p", 1, false, "rotate", Vec3(0, 0, 90)).apply(src);
    assert(a.canFind("Solid[] p()
{
    auto pieces = box(10, 10, 10).split(XY.offset(5.mm));
"
        ~ "    pieces[1] = pieces[1].rotate(z: 90);
    return pieces;
}"), a);
    auto b = transformPiece(a, "m.hcad", "p", 1, false, "rotate", Vec3(0, 0, 30)).apply(a);
    assert(b.canFind("pieces[1] = pieces[1].rotate(z: 120);") && !b.canFind("z: 90"), b);
    auto c = transformPiece(b, "m.hcad", "p", 0, false, "move", Vec3(5, 0, 0)).apply(b);
    assert(c.canFind("    pieces[0] = pieces[0].move(x: 5.mm);
    return pieces;"), c);
    // a Solid made into pieces: .pieces, and a list it returns now
    auto d = "module m;

@parts
Solid jaws()
{
    auto s = box(4, 4, 4) + box(4, 4, 4).move(x: 10);
    return s;
}
";
    auto e = transformPiece(d, "m.hcad", "jaws", 0, true, "move", Vec3(0, 0, 3)).apply(d);
    assert(e.canFind("Solid[] jaws()") && e.canFind("auto pieces = s.pieces;
    pieces[0] = pieces[0].move(z: 3.mm);
    return pieces;"), e);
    // a feature on a piece, its size selected
    auto f = appendToPiece(src, "m.hcad", "p", 0, false, ".fillet(edges, r: 1.mm)", "1.mm");
    auto g = f.apply(src);
    assert(g.canFind("pieces[0] = pieces[0].fillet(edges, r: 1.mm);"), g);
    assert(g[f.selectOffset .. f.selectOffset + f.selectLength] == "1.mm", g);
}

private double[3][3] product(double[3][3] a, double[3][3] b)
{
    double[3][3] m;
    foreach (row; 0 .. 3)
        foreach (col; 0 .. 3)
        {
            m[row][col] = 0;
            foreach (q; 0 .. 3)
                m[row][col] += a[row][q] * b[q][col];
        }
    return m;
}

private Vec3 apply(double[3][3] m, Vec3 v) => Vec3(m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
    m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z, m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z);

private bool isIdentity(double[3][3] m)
{
    foreach (i; 0 .. 3)
        foreach (j; 0 .. 3)
            if (abs(m[i][j] - (i == j)) > 1e-9)
                return false;
    return true;
}

/// The axis of a turn (a unit vector; Z for none).
Vec3 turnAxis(double[3][3] m)
{
    auto w = Vec3(m[2][1] - m[1][2], m[0][2] - m[2][0], m[1][0] - m[0][1]);
    if (w.length > 1e-9)
        return w.normalized;
    if (isIdentity(m))
        return Vec3(0, 0, 1);
    // half a turn: the axis is what R + I keeps, its largest column
    Vec3 best;
    foreach (j; 0 .. 3)
    {
        auto col = Vec3(m[0][j] + (j == 0), m[1][j] + (j == 1), m[2][j] + (j == 2));
        if (col.length > best.length)
            best = col;
    }
    return best.normalized;
}

/// The point, nearest the origin, that turn m (moving the origin by t)
/// turns about: (I - m) p = t. False when there is none: t slides along the axis.
private bool pivotOf(double[3][3] m, Vec3 t, out Vec3 p)
{
    auto u = turnAxis(m);
    if (abs(t.dot(u)) > 1e-6)
        return false;
    // across the axis, (I - m) is a 2 × 2 that can be undone
    auto e1 = (abs(u.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)).cross(u).normalized;
    auto e2 = u.cross(e1);
    Vec3 col(Vec3 e) => e - apply(m, e);
    immutable a = col(e1).dot(e1), b = col(e2).dot(e1), c = col(e1).dot(e2), d = col(e2).dot(e2);
    immutable det = a * d - b * c;
    if (abs(det) < 1e-12)
        return false;
    immutable t1 = t.dot(e1), t2 = t.dot(e2);
    p = e1 * ((d * t1 - b * t2) / det) + e2 * ((a * t2 - c * t1) / det);
    return true;
}

/// The last call of a chain: `.name(args)` from `start` to `end` in it,
/// with its named arguments' texts.
private struct LastCall
{
    size_t start, end;
    string name;
    string[string] args;   /// the named ones
    bool positional;       /// some argument has no name
    string[] unnamed;      /// those without a name, in order
}

private bool lastCall(string expr, out LastCall c)
{
    import std.string : strip;
    import std.ascii : isAlphaNum;
    if (expr.length == 0 || expr[$ - 1] != ')')
        return false;
    // back to the matching '(' (strings hold no parentheses in what is matched here)
    int depth;
    size_t open = size_t.max;
    foreach_reverse (i, ch; expr)
    {
        if (ch == ')')
            depth++;
        else if (ch == '(' && --depth == 0)
        {
            open = i;
            break;
        }
    }
    if (open == size_t.max)
        return false;
    size_t n = open;
    while (n > 0 && (isAlphaNum(expr[n - 1]) || expr[n - 1] == '_'))
        n--;
    size_t dot = n;
    while (dot > 0 && (expr[dot - 1] == ' ' || expr[dot - 1] == '\n' || expr[dot - 1] == '\t'))
        dot--;
    if (dot == 0 || expr[dot - 1] != '.' || n == open)
        return false;
    c.start = dot - 1;
    c.end = expr.length;
    c.name = expr[n .. open];
    // the arguments, split at the commas outside parentheses
    auto inside = expr[open + 1 .. $ - 1];
    size_t from;
    depth = 0;
    foreach (i; 0 .. inside.length + 1)
    {
        if (i < inside.length)
        {
            if (inside[i] == '(' || inside[i] == '[')
                depth++;
            else if (inside[i] == ')' || inside[i] == ']')
                depth--;
            if (inside[i] != ',' || depth)
                continue;
        }
        auto arg = inside[from .. i].strip;
        from = i + 1;
        if (arg.length == 0)
            continue;
        import std.string : indexOf;
        immutable colon = arg.indexOf(':');
        if (colon < 0 || arg[0 .. colon].strip.length == 0 || arg.indexOf('(') >= 0 && arg.indexOf('(') < colon)
        {
            c.positional = true;   // not a name: before ':' there is a call, or nothing
            c.unnamed ~= arg;
            continue;
        }
        c.args[arg[0 .. colon].strip] = arg[colon + 1 .. $].strip;
    }
    return true;
}

/// `=> expr;` turned into a body with braces, the call added to the
/// returned chain: one statement per line reads better than a long
/// expression once features are added.
private Edit toBlock(string source, Token[] toks, FuncDecl fn, size_t first, size_t last, string body, string call,
    string placeholder)
{
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

unittest
{
    // a move or a turn is added, then changed in place, then dropped when it
    // comes to nothing; a call it cannot read gets another after it
    auto src = "module m;\n\n@part\nSolid p() => box(10, 10, 10);\n";
    auto a = transformPart(src, "m.hcad", "p", "move", Vec3(12, -3, 0)).apply(src);
    assert(a.canFind(".move(x: 12.mm, y: -3.mm)"), a);
    auto b = transformPart(a, "m.hcad", "p", "move", Vec3(-2, 3, 5)).apply(a);
    assert(b.canFind(".move(x: 10.mm, z: 5.mm)") && !b.canFind("y:"), b);
    auto c = transformPart(b, "m.hcad", "p", "move", Vec3(-10, 0, -5)).apply(b);
    assert(!c.canFind(".move("), c);
    // a point on the axis turns nothing more: no around
    auto d = transformPart(c, "m.hcad", "p", "rotate", Vec3(0, 0, 45), Vec3(0, 0, 5)).apply(c);
    assert(d.canFind(".rotate(z: 45);"), d);
    auto e = transformPart(d, "m.hcad", "p", "rotate", Vec3(0, 0, 30), Vec3(0, 0, 5)).apply(d);
    assert(e.canFind(".rotate(z: 75);") && !e.canFind("z: 45"), e);
    // about another axis and another point: still one turn, about a third point
    auto f = transformPart(e, "m.hcad", "p", "rotate", Vec3(90, 0, 0), Vec3(0, 0, 5)).apply(e);
    import std.algorithm : count;
    assert(f.count(".rotate(") == 1 && f.canFind("around:"), f);
    // unless the two leave a slide along the axis, which no single turn makes:
    // then a second one
    auto sl = transformPart(c, "m.hcad", "p", "rotate", Vec3(0, 0, 90)).apply(c);
    auto sl2 = transformPart(sl, "m.hcad", "p", "rotate", Vec3(60, 0, 0), Vec3(0, 5, 0)).apply(sl);
    assert(sl2.count(".rotate(") == 2, sl2);
    // turns about the same axis through different points make one: half a
    // turn about the point between them
    auto k = transformPart(c, "m.hcad", "p", "rotate", Vec3(0, 0, 90), Vec3(10, 0, 0)).apply(c);
    assert(k.canFind(".rotate(z: 90, around: vec(10.mm, 0.mm, 0.mm))"), k);
    auto k2 = transformPart(k, "m.hcad", "p", "rotate", Vec3(0, 0, 90), Vec3(0, 0, 0)).apply(k);
    assert(k2.count(".rotate(") == 1 && k2.canFind(".rotate(z: 180, around: vec(5.mm, 5.mm, 0.mm))"), k2);
    // only the pivot's part across the axis is written
    auto l = transformPart(c, "m.hcad", "p", "rotate", Vec3(0, 0, -90), Vec3(0, 0, 15)).apply(c);
    assert(l.canFind(".rotate(z: -90);"), l);
    auto l2 = transformPart(c, "m.hcad", "p", "rotate", Vec3(0, 0, 45), Vec3(10, 5, 15)).apply(c);
    assert(l2.canFind(".rotate(z: 45, around: vec(10.mm, 5.mm, 0.mm))"), l2);
    // turns in the order X, Y, Z keep their numbers
    auto q = transformPart(c, "m.hcad", "p", "rotate", Vec3(90, 0, 0), Vec3(0, 0, 5)).apply(c);
    auto q2 = transformPart(q, "m.hcad", "p", "rotate", Vec3(0, 0, 90), Vec3(0, 0, 5)).apply(q);
    assert(q2.canFind(".rotate(x: 90, z: 90, around:"), q2);
    // and a turn undone leaves nothing
    auto q3 = transformPart(q2, "m.hcad", "p", "rotate", Vec3(0, 0, -90), Vec3(0, 0, 5)).apply(q2);
    auto q4 = transformPart(q3, "m.hcad", "p", "rotate", Vec3(-90, 0, 0), Vec3(0, 0, 5)).apply(q3);
    assert(!q4.canFind(".rotate("), q4);
    auto g = "module m;\n\n@part\nSolid p() => box(10, 10, 10).move(x: w);\nimmutable w = 3.mm;\n";
    auto h = transformPart(g, "m.hcad", "p", "move", Vec3(1, 0, 0)).apply(g);
    assert(h.canFind(".move(x: w)") && h.canFind(".move(x: 1.mm)"), h);
}

unittest
{
    // a scale about the bottom of the part: one factor, or one per axis; a
    // second scale about the same point is taken in, and an undone one goes
    import std.algorithm : count;
    auto src = "module m;\n\n@part\nSolid p() => box(10, 10, 10);\n";
    auto a = transformPart(src, "m.hcad", "p", "scale", Vec3(1.5, 1.5, 1.5), Vec3(0, 0, 0)).apply(src);
    assert(a.canFind(".scale(1.5)") && !a.canFind("around"), a);
    auto b = transformPart(a, "m.hcad", "p", "scale", Vec3(2, 2, 2)).apply(a);
    assert(b.canFind(".scale(3)") && b.count(".scale(") == 1, b);
    auto c = transformPart(b, "m.hcad", "p", "scale", Vec3(1, 1, 1.0 / 3)).apply(b);
    assert(c.canFind(".scale(x: 3, y: 3)") && c.count(".scale(") == 1, c);
    auto d = transformPart(c, "m.hcad", "p", "scale", Vec3(1.0 / 3, 1.0 / 3, 1)).apply(c);
    assert(!d.canFind(".scale("), d);
    // about a point off the origin: around:, only along the axes that scale
    auto e = transformPart(src, "m.hcad", "p", "scale", Vec3(1, 1, 2), Vec3(5, 5, 3)).apply(src);
    assert(e.canFind(".scale(z: 2, around: vec(0.mm, 0.mm, 3.mm))"), e);
    auto f = transformPart(e, "m.hcad", "p", "scale", Vec3(1.2, 0.8, 1), Vec3(5, 5, 3)).apply(e);
    assert(f.canFind(".scale(x: 1.2, y: 0.8, z: 2, around: vec(5.mm, 5.mm, 3.mm))") && f.count(".scale(") == 1, f);
    // about two different points: still one scale, about a third point
    auto g = transformPart(e, "m.hcad", "p", "scale", Vec3(1, 1, 2), Vec3(0, 0, 0)).apply(e);
    assert(g.canFind(".scale(z: 4, around: vec(0.mm, 0.mm, 2.mm))"), g);
    // undone, but moved: a second one
    auto h = transformPart(e, "m.hcad", "p", "scale", Vec3(1, 1, 0.5), Vec3(0, 0, 0)).apply(e);
    assert(h.count(".scale(") == 2, h);
    // a factor it cannot read: another call after it
    auto k = "module m;\n\n@part\nSolid p() => box(10, 10, 10).scale(w);\nimmutable w = 2;\n";
    auto l = transformPart(k, "m.hcad", "p", "scale", Vec3(2, 2, 2)).apply(k);
    assert(l.canFind(".scale(w)") && l.canFind(".scale(2)"), l);
    assert(scaleCall(Vec3(1, 1, 1), Vec3(3, 4, 5)) is null);
}

unittest
{
    // turnAngles undoes turnMatrix
    foreach (e; [Vec3(30, 0, 0), Vec3(0, -45, 0), Vec3(10, 20, 30), Vec3(-120, 35, 170)])
    {
        auto back = turnAngles(turnMatrix(e));
        assert(abs(back.x - e.x) < 1e-6 && abs(back.y - e.y) < 1e-6 && abs(back.z - e.z) < 1e-6);
    }
}

unittest
{
    assert(halfTurn(270) == -90 && halfTurn(400) == 40 && halfTurn(-190) == 170 && halfTurn(180) == 180
        && halfTurn(-180) == 180 && halfTurn(720) == 0);
    auto src = "module m;\n\n@part\nSolid p() => box(10, 10, 10);\n";
    auto a = transformPart(src, "m.hcad", "p", "rotate", Vec3(0, 0, 400)).apply(src);
    assert(a.canFind(".rotate(z: 40);"), a);
}
