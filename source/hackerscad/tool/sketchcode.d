/// Turns edits made on a sketch in the window into its code: the name of
/// each point, line or curve (a variable, an element of a shape's lines, a
/// line's point, a face's edge), a name given where a call has none, and new
/// statements written at the end of the sketch's code. A sketch made inside
/// a loop or an if, or an entity made in another function, is left alone,
/// with why.
module hackerscad.tool.sketchcode;

import std.algorithm : count, countUntil, max, min;
import std.range : iota;
import std.format : format;

import hackerscad.lang.errors : Span;
import hackerscad.lang.lexer;
import hackerscad.lang.sketchval : SketchView;
import hackerscad.geom.vec : Vec3;
import hackerscad.tool.codegen : CodegenException, Edit, offsetOf;

/// Writes `statement(names)` at the end of sketch `v`'s code, the names
/// those of entities `ids` (given first where a call has none): the new
/// source. The statement is one line, without its indentation or `;`.
string writeToSketch(string source, string file, const ref SketchView v, const(size_t)[] ids,
    string delegate(string[] names) statement)
{
    auto w = SketchWriter(source, file, v);
    string[] names;
    foreach (e; ids)
        names ~= w.name(e);
    w.add(statement(names));
    return w.result();
}

/// Writes statements into a sketch's code (see the module's comment).
struct SketchWriter
{
    string source;
    const(SketchView)* view;
    Token[] toks;
    string var;               /// the sketch's variable
    string file;
    size_t bodyOpen, bodyClose;   /// the braces of the function the sketch is made in (token indices)
    private bool[string] used;
    private Insert[] inserts;
    private string[] added;
    private string[size_t] named;   /// call statement start (token) → the name given

    private struct Insert
    {
        size_t offset;
        string text;
        size_t cut;   /// characters taken away at offset (a statement dropped)
    }

    /// The statements of the function's body, first and last token each (a
    /// loop or an if with its block is one)
    private size_t[2][] statements;

    this(string source, string file, const ref SketchView v)
    {
        this.source = source;
        this.file = file;
        view = &v;
        if (v.span.file != file)
            throw new CodegenException("the sketch is made in another file (" ~ v.span.file ~ "): its code is edited there");
        toks = lex(source, file);
        // the names a variable could clash with (not a method after a dot, nor a named argument's label)
        foreach (i, t; toks)
            if (t.kind == Tok.ident && !(i > 0 && toks[i - 1].kind == Tok.dot)
                && !(i + 1 < toks.length && toks[i + 1].kind == Tok.colon))
                used[t.text] = true;
        // the sketch's call: `auto s = sketch();` or `auto s = body.sketch(faces.top);`
        immutable call = callToken(v.span);
        if (call == size_t.max)
            throw new CodegenException("the sketch's code is no longer where it was: evaluate again");
        immutable st = statementStart(call);
        if (!(toks[st].kind == Tok.kwAuto && toks[st + 1].kind == Tok.ident && toks[st + 2].kind == Tok.assign
                && closing(call) + 1 < toks.length && toks[closing(call) + 1].kind == Tok.semicolon))
            throw new CodegenException("the sketch is not kept in a variable (auto s = sketch();): its code is "
                ~ "edited by hand");
        var = toks[st + 1].text;
        // the function it is made in: the outermost braces round it
        size_t depth0Open = size_t.max;
        int depth;
        foreach (i; 0 .. call)
        {
            if (toks[i].kind == Tok.lbrace)
            {
                if (depth == 0)
                    depth0Open = i;
                depth++;
            }
            else if (toks[i].kind == Tok.rbrace)
                depth--;
        }
        if (depth0Open == size_t.max)
            throw new CodegenException("the sketch is not made in a function");
        bodyOpen = depth0Open;
        bodyClose = closing(bodyOpen);
        splitBody();
        if (!direct(call))
            throw new CodegenException("the sketch is made inside a loop or an if: its code is edited by hand");
    }

    /// The code that names entity `e`; a name is given to its call where
    /// it has none. Throws when it cannot be named from here.
    string name(size_t e)
    {
        auto en = view.entities[e];
        if (en.edge >= 0)
            return format("%s.edges[%d]", var, en.edge);
        if (en.origin)
            return var ~ ".origin";
        // a corner of the face it is drawn on: an end of one of its edges
        if (en.reference)
        {
            foreach (i, other; view.entities)
                if (other.edge >= 0)
                    if (auto part = pointOf(i, e))
                        return format("%s.edges[%d].%s", var, other.edge, part);
            throw new CodegenException("this reference has no name in the code");
        }
        // made by a call that returned a list: its element, or a point of one
        foreach (l; view.lists)
            if (l.call == en.span)
            {
                immutable k = l.entities.countUntil(e);
                if (k >= 0)
                    return format("%s[%d]", callName(l.call, methodOf(l.call)), k);
                foreach (j, other; l.entities)
                    if (auto part = pointOf(other, e))
                        return format("%s[%d].%s", callName(l.call, methodOf(l.call)), j, part);
                // a helper of the shape (a construction diagonal, a centre): not in what it returns
                throw new CodegenException(format("what line %d draws to help its shape has no name of its own",
                    en.span.line));
            }
        // a point made by the call of another entity (a vector where a point goes): that one's
        if (en.kind == "point")
            foreach (i, other; view.entities)
                if (i != e && other.kind != "point" && other.span == en.span)
                    if (auto part = pointOf(i, e))
                        return callName(en.span, baseName(other.kind)) ~ "." ~ part;
        // a point written inside another entity's call (s.circle(s.point(…), …)): that one's, circle.center
        if (en.kind == "point")
        {
            immutable c = callToken(en.span);
            if (c != size_t.max)
                foreach (i, other; view.entities)
                {
                    if (i == e || other.kind == "point")
                        continue;
                    immutable oc = callToken(other.span);
                    if (oc != size_t.max && oc < c && c < closing(oc))
                        if (auto part = pointOf(i, e))
                            return callName(other.span, baseName(other.kind)) ~ "." ~ part;
                }
        }
        return callName(en.span, baseName(en.kind));
    }

    /// Adds a statement at the end of the sketch's code.
    void add(string statement)
    {
        import std.algorithm : any, canFind, endsWith;
        // geometry only: constraints (s.on, s.midpoint…), fills and points take no construction
        static immutable geometry = ["line", "arc", "circle", "ellipse", "polyline", "spline", "rect", "polygon",
            "slot", "teardrop"];
        if (construction && statement.endsWith(")") && geometry.any!(g => statement.canFind("." ~ g ~ "(")))
            statement = statement[0 .. $ - 1] ~ (statement.endsWith("()") ? "" : ", ") ~ "construction: true)";
        added ~= statement;
    }

    /// What add adds is construction geometry (its points stay plain).
    bool construction;

    /// A name no variable of the file has yet (base, base2…), for what a statement declares.
    string fresh(string base) => unique(base);

    /// The source with the names given and the statements added.
    string result()
    {
        // where the statements go: after the last statement of the function holding the sketch's code (a loop
        // that makes some of it: after the loop), at its indentation
        size_t lastRange = rangeOf(callToken(view.span));
        void see(Span s)
        {
            immutable c = callToken(s);
            if (c != size_t.max && c > bodyOpen && c < bodyClose)
                lastRange = max(lastRange, rangeOf(c));
        }
        foreach (en; view.entities)
            if (!en.reference)
                see(en.span);
        foreach (c; view.constraints)
            see(c.span);
        foreach (f; view.fills)
            see(f.span);
        immutable lastStart = statements[lastRange][0], last = statements[lastRange][1];
        size_t lineStart = offsetOf(source, toks[lastStart].span);
        while (lineStart > 0 && source[lineStart - 1] != '\n')
            lineStart--;
        size_t indentEnd = lineStart;
        while (indentEnd < source.length && (source[indentEnd] == ' ' || source[indentEnd] == '\t'))
            indentEnd++;
        immutable indent = source[lineStart .. indentEnd];
        size_t at = offsetOf(source, toks[last].span) + 1;
        while (at < source.length && source[at] != '\n')
            at++;
        string text;
        foreach (st; added)
            text ~= "\n" ~ indent ~ st ~ ";";
        auto all = inserts ~ Insert(at, text);
        // from the end: the offsets before each stay valid
        import std.algorithm : sort;
        all.sort!((a, b) => a.offset > b.offset);
        string r = source;
        foreach (ins; all)
            r = r[0 .. ins.offset] ~ ins.text ~ r[ins.offset + ins.cut .. $];
        return r;
    }

    /// Takes away the statement of the constraint made at `s`, when it is a line of its own
    /// (`s.length(l, 20.mm);`); false when it is not (a shape's own, in a loop, sharing its line).
    bool drop(Span s)
    {
        immutable c = callToken(s);
        if (c == size_t.max || c < bodyOpen || c > bodyClose || !direct(c))
            return false;
        immutable st = statementStart(c), end = closing(c);
        if (!(toks[st].kind == Tok.ident && toks[st].text == var && st + 3 == c && end + 1 < toks.length
                && toks[end + 1].kind == Tok.semicolon))
            return false;
        size_t from = offsetOf(source, toks[st].span);
        while (from > 0 && (source[from - 1] == ' ' || source[from - 1] == '\t'))
            from--;
        if (from == 0 || source[from - 1] != '\n')
            return false;
        size_t to = offsetOf(source, toks[end + 1].span) + 1;
        while (to < source.length && (source[to] == ' ' || source[to] == '\t'))
            to++;
        if (to < source.length && source[to] != '\n')
            return false;
        // the line with the newline before it: what is added after it still goes where the line ended
        inserts ~= Insert(from - 1, "", to - (from - 1));
        return true;
    }

private:

    /// The variable a call's result is kept in, given one (`auto line2 =`)
    /// when it stands alone as a statement.
    string callName(Span s, string base)
    {
        immutable c = callToken(s);
        if (c == size_t.max)
            throw new CodegenException("the sketch's code is no longer where it was: evaluate again");
        if (c < bodyOpen || c > bodyClose)
            throw new CodegenException(format("line %d is in another function: its code is edited by hand", s.line));
        if (!direct(c))
            throw new CodegenException(format("line %d is inside a loop or an if: what it makes is named by hand",
                s.line));
        immutable st = statementStart(c);
        immutable end = closing(c);
        immutable whole = end + 1 < toks.length && toks[end + 1].kind == Tok.semicolon;
        // auto name = s.line(…); or one of several: auto a = s.line(…), b = s.line(…);
        immutable after = end + 1 < toks.length ? toks[end + 1].kind : Tok.eof;
        if (c >= 6 && toks[c - 1].kind == Tok.ident && toks[c - 2].kind == Tok.dot && toks[c - 3].kind == Tok.ident
            && toks[c - 4].kind == Tok.assign && toks[c - 5].kind == Tok.ident
            && (toks[c - 6].kind == Tok.kwAuto || toks[c - 6].kind == Tok.comma)
            && (after == Tok.semicolon || after == Tok.comma))
            return toks[c - 5].text;
        // s.line(…); alone: it gets a name
        if (whole && toks[st].kind == Tok.ident && toks[st].text == var && st + 3 == c)
        {
            if (auto n = st in named)
                return *n;
            auto n = unique(base);
            inserts ~= Insert(offsetOf(source, toks[st].span), "auto " ~ n ~ " = ");
            named[st] = n;
            return n;
        }
        throw new CodegenException(format("what line %d makes has no name of its own: name it by hand", s.line));
    }

    /// How point `p` is reached from entity `e` (start, center, points[2]…), or null.
    string pointOf(size_t e, size_t p)
    {
        auto en = view.entities[e];
        immutable k = en.points.countUntil(p);
        if (k < 0)
            return null;
        switch (en.kind)
        {
        case "line": return k == 0 ? "start" : "end";
        case "arc": return ["center", "start", "end"][k];
        case "circle", "ellipse": return "center";
        case "spline": return format("points[%d]", k);
        default: return null;
        }
    }

    static string baseName(string kind) => kind == "point" ? "p" : kind == "spline" ? "curve" : kind;

    string unique(string base)
    {
        auto n = base;
        for (int k = 2; n in used; k++)
            n = format("%s%d", base, k);
        used[n] = true;
        return n;
    }

    /// The `(` of the call at span s, or size_t.max.
    size_t callToken(Span s)
    {
        if (s.file != file)
            return size_t.max;
        foreach (i, t; toks)
            if (t.span.line == s.line && t.span.col == s.col)
                return t.kind == Tok.lparen ? i : size_t.max;
        return size_t.max;
    }

    /// The method a call names (rect, slot…), for the name its result gets.
    string methodOf(Span s)
    {
        immutable c = callToken(s);
        return c != size_t.max && c > 0 && toks[c - 1].kind == Tok.ident ? toks[c - 1].text : "lines";
    }

    /// The `)` (or `}`, `]`) that closes the bracket at i.
    size_t closing(size_t i)
    {
        int depth;
        foreach (j; i .. toks.length)
        {
            immutable k = toks[j].kind;
            if (k == Tok.lparen || k == Tok.lbracket || k == Tok.lbrace)
                depth++;
            else if (k == Tok.rparen || k == Tok.rbracket || k == Tok.rbrace)
                if (--depth == 0)
                    return j;
        }
        return toks.length - 1;
    }

    /// The first token of the statement holding token i.
    size_t statementStart(size_t i)
    {
        int depth;
        while (i > 0)
        {
            immutable k = toks[i - 1].kind;
            if (k == Tok.rparen || k == Tok.rbracket)
                depth++;
            else if (k == Tok.lparen || k == Tok.lbracket)
            {
                if (depth == 0)
                    break;   // inside a call's arguments: the caller decides
                depth--;
            }
            else if (depth == 0 && (k == Tok.semicolon || k == Tok.lbrace || k == Tok.rbrace))
                break;
            i--;
        }
        return i;
    }

    void splitBody()
    {
        size_t i = bodyOpen + 1;
        while (i < bodyClose)
        {
            immutable first = i;
            int depth;
            for (; i < bodyClose; i++)
            {
                immutable k = toks[i].kind;
                if (k == Tok.lparen || k == Tok.lbracket || k == Tok.lbrace)
                    depth++;
                else if (k == Tok.rparen || k == Tok.rbracket || k == Tok.rbrace)
                {
                    depth--;
                    // a block closed: the statement ends, unless an else follows
                    if (depth == 0 && k == Tok.rbrace && !(i + 1 < bodyClose && toks[i + 1].kind == Tok.kwElse))
                        break;
                }
                else if (depth == 0 && k == Tok.semicolon)
                    break;
            }
            statements ~= [first, min(i, bodyClose - 1)];
            i++;
        }
    }

    /// The statement of the body holding token i.
    size_t rangeOf(size_t i)
    {
        foreach (k, r; statements)
            if (i >= r[0] && i <= r[1])
                return k;
        return 0;
    }

    /// Whether the call at token i is in a statement of the body itself (not in a loop's, an if's).
    bool direct(size_t i)
    {
        if (i <= bodyOpen || i >= bodyClose)
            return false;
        immutable r = statements[rangeOf(i)];
        immutable k = toks[r[0]].kind;
        if (k == Tok.kwForeach || k == Tok.kwForeachReverse || k == Tok.kwFor || k == Tok.kwWhile || k == Tok.kwIf
            || k == Tok.lbrace)
            return false;
        return true;
    }
}

/// The edit that turns `before` into `after` (one undo step): what lies
/// between their common start and end, `select` (if any) selected in what
/// is written.
Edit editBetween(string before, string after, string select = null)
{
    size_t head;
    while (head < before.length && head < after.length && before[head] == after[head])
        head++;
    size_t tail;
    while (tail < before.length - head && tail < after.length - head && before[$ - 1 - tail] == after[$ - 1 - tail])
        tail++;
    Edit e;
    e.offset = head;
    e.length = before.length - head - tail;
    e.text = after[head .. $ - tail];
    e.selectOffset = after.length - tail;
    if (select.length)
    {
        // the last place it starts in what was written (its end may be in the common tail: "…);" then "…);")
        import std.string : indexOf;
        for (ptrdiff_t k = after.indexOf(select, head); k >= 0 && k <= after.length - tail;
            k = after.indexOf(select, k + 1))
        {
            e.selectOffset = k;
            e.selectLength = select.length;
        }
    }
    return e;
}

unittest
{
    import std.algorithm : canFind, filter, map;
    import std.array : array;
    import std.file : tempDir;
    import std.path : buildPath;
    import std.string : indexOf;
    import hackerscad.lang.interp : Interp;
    import hackerscad.lang.sketchval : SketchVal;
    import hackerscad.kernel.occt.backend : OcctKernel;

    immutable file = buildPath(tempDir, "hcad-sketchcode.hcad");
    auto kernel = new OcctKernel;
    SketchView viewOf(string src)
    {
        auto it = new Interp(kernel);
        it.runSource(src, file);
        assert(it.sketches.length, src);
        return (cast(SketchVal) it.sketches[$ - 1]).view();
    }
    // the entity a line makes, by its text
    size_t made(const ref SketchView v, string src, string text, size_t nth = 0)
    {
        immutable line = cast(uint) src[0 .. src.indexOf(text)].count('\n') + 1;
        auto ids = v.entities.length.iota.filter!(i => v.entities[i].span.line == line).array;
        return ids[nth];
    }

    immutable src = "module m;\n\n@part\nSolid p()\n{\n"
        ~ "    auto s = sketch();\n"
        ~ "    auto a = s.point(0, 0, fixed: true);\n"
        ~ "    auto b = s.point(40, 2);\n"
        ~ "    auto c = s.point(40, 30);\n"
        ~ "    auto bottom = s.line(a, b);\n"
        ~ "    s.line(b, c);\n"
        ~ "    auto r = s.rect(vec(50, 0), vec(70, 20));\n"
        ~ "    auto w = s.spline([c, vec(20, 40), a]);\n"
        ~ "    foreach (k; [0, 1])\n"
        ~ "        s.point(80 + k * 10, 0);\n"
        ~ "    return box(1, 1, 1);\n}\n";
    auto v = viewOf(src);
    auto w = SketchWriter(src, file, v);
    assert(w.var == "s");
    assert(w.name(made(v, src, "auto a =")) == "a");
    assert(w.name(made(v, src, "auto bottom")) == "bottom");
    // a call alone gets a name, once
    immutable side = made(v, src, "s.line(b, c)");
    assert(w.name(side) == "line" && w.name(side) == "line");
    // a shape's lines, and its corners through them
    auto rect = v.lists.filter!(l => l.call.line == 12).front;
    assert(w.name(rect.entities[2]) == "r[2]");
    immutable corner = v.entities[rect.entities[1]].points[0];
    assert(w.name(corner) == "r[1].start" || w.name(corner) == "r[0].end", w.name(corner));
    // a vector where a point goes: the point is the curve's
    immutable curve = made(v, src, "auto w", 1);
    assert(v.entities[curve].kind == "spline");
    immutable mid = v.entities[curve].points[1];
    assert(w.name(mid) == "w.points[1]", w.name(mid));
    // made in a loop: left alone
    import std.exception : assertThrown;
    assertThrown!CodegenException(w.name(made(v, src, "s.point(80")));
    // a constraint written after the loop, before the return; the model still runs, one more constraint
    w.add(format("s.horizontal(%s)", w.name(made(v, src, "auto bottom"))));
    w.add(format("s.vertical(%s)", w.name(side)));
    auto after = w.result();
    assert(after.canFind("    auto line = s.line(b, c);\n"), after);
    assert(after.canFind("        s.point(80 + k * 10, 0);\n    s.horizontal(bottom);\n    s.vertical(line);\n    return"), after);
    auto v2 = viewOf(after);
    assert(v2.constraints.length == v.constraints.length + 2);
    // the edit: one undo step, what changed
    auto e = editBetween(src, after, "s.vertical(line)");
    assert(e.apply(src) == after);
    assert(after[e.selectOffset .. e.selectOffset + e.selectLength] == "s.vertical(line)",
        format("%s %s %s", e.selectOffset, e.selectLength, after[e.selectOffset .. $]));

    // a sketch in a loop, or not in a variable: not edited from the window
    immutable looped = "module m;\n@part Solid p()\n{\n    foreach (k; [1])\n    {\n        auto s = sketch();\n"
        ~ "        s.point(0, 0);\n    }\n    return box(1, 1, 1);\n}\n";
    auto lv = viewOf(looped);
    assertThrown!CodegenException(SketchWriter(looped, file, lv));
}

/// One statement a sketch tool writes: `format` with the names of `ids` in it, in order.
struct SketchStep
{
    string format;
    size_t[] ids;
}

/// The constraint tools of the sketch bar.
immutable string[] sketchTools = ["coincident", "on", "horizontal", "vertical", "parallel", "perpendicular", "equal",
    "tangent", "concentric", "midpoint", "symmetric", "fix", "length", "distance", "angle", "radius", "diameter",
    "extend", "offset", "mirror", "pattern", "circular-pattern"];

/// The tools that take a value (a length, an angle; a pattern's count, and its step).
immutable string[] valueTools = ["length", "distance", "angle", "radius", "diameter", "offset", "pattern",
    "circular-pattern"];

/// What constraint tool `tool` writes for the entities `sel` of sketch `v`,
/// selected in that order (`value` for the tools that take one, "20.mm",
/// "30.deg"): several items get it each (horizontal, vertical, fix), or
/// relative to the first (parallel, equal, concentric, coincident), a value
/// on several is one dimension and the others equal to it. Empty, with
/// `why`, when the selection does not fit the tool.
SketchStep[] planConstraint(const ref SketchView v, const(size_t)[] sel, string tool, string value, out string why)
{
    size_t[] points, lines, rounds, ellipses, others;
    foreach (e; sel)
    {
        switch (v.entities[e].kind)
        {
        case "point": points ~= e; break;
        case "line": lines ~= e; break;
        case "circle", "arc": rounds ~= e; break;
        case "ellipse": ellipses ~= e; break;
        default: others ~= e; break;
        }
    }
    immutable n = sel.length;
    SketchStep[] steps;
    SketchStep step(string f, size_t[] ids...) => SketchStep(f, ids.dup);
    // each item to the first: a, b; a, c; …
    SketchStep[] toFirst(string call, const(size_t)[] items)
    {
        SketchStep[] r;
        foreach (x; items[1 .. $])
            r ~= step("s." ~ call ~ "(%s, %s)", items[0], x);
        return r;
    }
    bool only(const(size_t)[] kind, size_t least = 1) => kind.length == n && n >= least;
    // the first k of the selection, as a list: [%s, %s]
    static string list(size_t k)
    {
        import std.array : join, replicate;
        return "[" ~ ["%s"].replicate(k).join(", ") ~ "]";
    }
    string fail(string reason)
    {
        why = reason;
        return null;
    }
    auto curves = rounds ~ ellipses;
    switch (tool)
    {
    case "horizontal", "vertical":
        if (only(lines))
            foreach (l; lines)
                steps ~= step("s." ~ tool ~ "(%s)", l);
        else if (only(points, 2) && n == 2)
            steps ~= step("s." ~ tool ~ "(%s, %s)", points[0], points[1]);
        else if (tool == "horizontal" && only(ellipses))
            foreach (e; ellipses)
                steps ~= step("s.horizontal(%s)", e);
        else
            fail(tool ~ ": lines (each made " ~ tool ~ "), or two points (lined up " ~ (tool == "horizontal"
                ? "level" : "upright") ~ ")");
        break;
    case "parallel":
        if (only(lines, 2))
            steps = toFirst("parallel", lines);
        else
            fail("parallel: two lines or more (each parallel to the first)");
        break;
    case "perpendicular":
        if (only(lines, 2) && n == 2)
            steps ~= step("s.perpendicular(%s, %s)", lines[0], lines[1]);
        else
            fail("perpendicular: two lines");
        break;
    case "equal":
        if (only(lines, 2))
            steps = toFirst("equal", lines);
        else if (only(rounds, 2))
            steps = toFirst("equal", rounds);
        else if (only(ellipses) && n == 1)
            steps ~= step("s.equal(%s)", ellipses[0]);
        else
            fail("equal: lines (as long as the first), or circles and arcs (as big as the first)");
        break;
    case "concentric":
        if (curves.length + points.length == n && curves.length >= 1 && n >= 2)
        {
            // the first curve the others' centre (a point: on its centre)
            auto items = curves ~ points;
            steps = toFirst("concentric", items);
        }
        else
            fail("concentric: circles, arcs or ellipses, and points (round the centre of the first)");
        break;
    case "tangent":
        if (curves.length == 1 && lines.length >= 1 && n == 1 + lines.length)
            foreach (l; lines)
                steps ~= step("s.tangent(%s, %s)", l, curves[0]);
        else if (only(rounds, 2) && n == 2)
            steps ~= step("s.tangent(%s, %s)", rounds[0], rounds[1]);
        else
            fail("tangent: a circle, arc or ellipse and lines (each touching it), or two circles or arcs");
        break;
    case "coincident":
        if (only(points, 2))
            steps = toFirst("coincident", points);
        else if (points.length >= 1 && n == points.length + 1)
            goto case "on";
        else
            fail("coincident: points (all on the first), or points and one line or curve (on it)");
        break;
    case "on":
        if (points.length >= 1 && n == points.length + 1 && points.length != n)
        {
            immutable curve = sel[sel.countUntil!(e => v.entities[e].kind != "point")];
            if (v.entities[curve].kind == "spline")
                fail("on: a point on a spline is not a constraint yet: put the spline through the point");
            else
                foreach (p; points)
                    steps ~= step("s.on(%s, %s)", p, curve);
        }
        else
            fail("on: points and one line, circle, arc or ellipse (each point on it)");
        break;
    case "midpoint":
        if (points.length == 1 && lines.length == 1 && n == 2)
            steps ~= step("s.midpoint(%s, %s)", points[0], lines[0]);
        else
            fail("midpoint: a point and a line (the point in its middle)");
        break;
    case "symmetric":
        if (points.length == 2 && lines.length == 1 && n == 3)
            steps ~= step("s.symmetric(%s, %s, %s)", points[0], points[1], lines[0]);
        else
            fail("symmetric: two points and a line (the points mirrored across it)");
        break;
    case "fix":
        if (only(points))
            foreach (p; points)
                steps ~= step("s.fix(%s)", p);
        else
            fail("fix: points (each pinned where it is)");
        break;
    case "length":
        if (only(lines))
        {
            // one dimension, the others as long
            steps ~= step("s.length(%s, " ~ value ~ ")", lines[0]);
            steps ~= toFirst("equal", lines);
        }
        else if (only(points, 2) && n == 2)
            steps ~= step("s.distance(%s, %s, " ~ value ~ ")", points[0], points[1]);
        else
            fail("length: lines (the first that long, the others as long), or two points (that far apart)");
        break;
    case "distance":
        if (only(points, 2) && n == 2)
            steps ~= step("s.distance(%s, %s, " ~ value ~ ")", points[0], points[1]);
        else if (points.length == 1 && lines.length == 1 && n == 2)
            steps ~= step("s.distance(%s, %s, " ~ value ~ ")", points[0], lines[0]);
        else if (only(lines, 2) && n == 2)
            // parallel lines that far apart: from the first's start to the second
            steps ~= step("s.distance(%s.start, %s, " ~ value ~ ")", lines[0], lines[1]);
        else
            fail("distance: two points, a point and a line, or two lines (from the first's start to the second)");
        break;
    case "angle":
        if (only(lines, 2) && n == 2)
            steps ~= step("s.angle(%s, %s, " ~ value ~ ")", lines[0], lines[1]);
        else if (only(lines) && n == 1)
            steps ~= step("s.angle(%s, " ~ value ~ ")", lines[0]);
        else if (only(ellipses) && n == 1)
            steps ~= step("s.angle(%s, " ~ value ~ ")", ellipses[0]);
        else
            fail("angle: two lines (the angle between them), or one line or ellipse (from X)");
        break;
    case "radius", "diameter":
        if (only(rounds))
        {
            steps ~= step("s." ~ tool ~ "(%s, " ~ value ~ ")", rounds[0]);
            steps ~= toFirst("equal", rounds);
        }
        else
            fail(tool ~ ": circles or arcs (the first that size, the others as big)");
        break;
    case "extend":
        if (n == 2 && v.entities[sel[0]].kind == "line" && v.entities[sel[1]].kind != "point")
            steps ~= step("s.extend(%s, to: %s)", sel[0], sel[1]);
        else
            fail("extend: a line, then the line or curve it is carried on to (its nearer end goes)");
        break;
    case "offset":
        if (n >= 1 && lines.length + sel.count!(e => v.entities[e].kind == "arc") == n)
            steps ~= step("s.offset(" ~ list(n) ~ ", " ~ value ~ ")", sel.dup);
        else
            fail("offset: lines and arcs end to end (copied that far away: outwards round a closed chain, else to "
                ~ "the left going from the first to the last)");
        break;
    case "mirror":
        if (n >= 2 && v.entities[sel[$ - 1]].kind == "line")
            steps ~= step("s.mirror(" ~ list(n - 1) ~ ", %s)", sel.dup);
        else
            fail("mirror: what to copy, then the line to mirror it across (selected last)");
        break;
    case "pattern":
        if (n >= 1)
            steps ~= step("s.pattern(" ~ list(n) ~ ", " ~ value ~ ")", sel.dup);
        break;
    case "circular-pattern":
        if (n >= 2 && v.entities[sel[$ - 1]].kind == "point")
            steps ~= step("s.circularPattern(" ~ list(n - 1) ~ ", " ~ value ~ ", center: %s)", sel.dup);
        else
            fail("circular pattern: what to copy, then the point to copy it round (selected last)");
        break;
    default:
        fail("no such tool: " ~ tool);
    }
    if (n == 0)
    {
        why = "select what to constrain first: points, lines, circles";
        return null;
    }
    return steps;
}

/// `f` with each %s in turn replaced by the next of `names`.
string fill(string f, const(string)[] names)
{
    import std.array : replaceFirst;
    foreach (name; names)
        f = f.replaceFirst("%s", name);
    return f;
}

/// Writes the steps of a sketch tool into the source (see planConstraint):
/// the new source; the last value written is what to select.
string writeSteps(string source, string file, const ref SketchView v, SketchStep[] steps)
{
    auto w = SketchWriter(source, file, v);
    foreach (st; steps)
    {
        string[] names;
        foreach (id; st.ids)
            names ~= w.name(id);
        // the format's "s." is the sketch's own variable
        auto f = st.format.length > 2 && st.format[0 .. 2] == "s." ? w.var ~ st.format[1 .. $] : st.format;
        w.add(fill(f, names));
    }
    return w.result();
}

unittest
{
    // which statements each tool writes for a selection, and what it says when the selection does not fit
    SketchView v;
    foreach (kind; ["point", "point", "point", "line", "line", "line", "circle", "arc", "ellipse"])
        v.entities ~= SketchView.Entity(kind);
    string plan(string tool, size_t[] sel, string value = "20.mm")
    {
        string why;
        auto steps = planConstraint(v, sel, tool, value, why);
        if (steps.length == 0)
            return "! " ~ why;
        string[] r;
        foreach (st; steps)
        {
            string[] names;
            foreach (id; st.ids)
                names ~= format("e%d", id);
            r ~= fill(st.format, names);
        }
        import std.array : join;
        return r.join("; ");
    }
    assert(plan("horizontal", [3, 4]) == "s.horizontal(e3); s.horizontal(e4)", plan("horizontal", [3, 4]));
    assert(plan("vertical", [0, 1]) == "s.vertical(e0, e1)");
    assert(plan("parallel", [5, 3, 4]) == "s.parallel(e5, e3); s.parallel(e5, e4)");
    assert(plan("parallel", [3])[0] == '!');
    assert(plan("perpendicular", [3, 4]) == "s.perpendicular(e3, e4)");
    assert(plan("equal", [6, 7]) == "s.equal(e6, e7)");
    assert(plan("equal", [3, 6])[0] == '!');
    assert(plan("tangent", [3, 6, 4]) == "s.tangent(e3, e6); s.tangent(e4, e6)");
    assert(plan("tangent", [6, 7]) == "s.tangent(e6, e7)");
    assert(plan("coincident", [0, 1, 2]) == "s.coincident(e0, e1); s.coincident(e0, e2)");
    assert(plan("coincident", [0, 6]) == "s.on(e0, e6)");
    assert(plan("on", [0, 1, 3]) == "s.on(e0, e3); s.on(e1, e3)");
    assert(plan("concentric", [6, 7, 0]) == "s.concentric(e6, e7); s.concentric(e6, e0)");
    assert(plan("midpoint", [0, 3]) == "s.midpoint(e0, e3)");
    assert(plan("symmetric", [0, 1, 5]) == "s.symmetric(e0, e1, e5)");
    assert(plan("fix", [0, 2]) == "s.fix(e0); s.fix(e2)");
    // a value on several: one dimension, the others equal to it
    assert(plan("length", [3, 4, 5]) == "s.length(e3, 20.mm); s.equal(e3, e4); s.equal(e3, e5)");
    assert(plan("length", [0, 1]) == "s.distance(e0, e1, 20.mm)");
    assert(plan("distance", [0, 3]) == "s.distance(e0, e3, 20.mm)");
    assert(plan("distance", [3, 4]) == "s.distance(e3.start, e4, 20.mm)");
    assert(plan("angle", [3, 4], "30.deg") == "s.angle(e3, e4, 30.deg)");
    assert(plan("angle", [3], "30.deg") == "s.angle(e3, 30.deg)");
    assert(plan("radius", [6, 7], "5.mm") == "s.radius(e6, 5.mm); s.equal(e6, e7)");
    assert(plan("diameter", [3])[0] == '!');
    assert(plan("horizontal", []) == "! select what to constrain first: points, lines, circles");
    // the sketch's own editing: a line extended to another, outlines offset, mirrored and repeated
    assert(plan("extend", [3, 6]) == "s.extend(e3, to: e6)");
    assert(plan("extend", [6, 3])[0] == '!');
    assert(plan("offset", [3, 7, 4], "2.mm") == "s.offset([e3, e7, e4], 2.mm)");
    assert(plan("offset", [3, 6])[0] == '!');
    assert(plan("mirror", [6, 7, 5]) == "s.mirror([e6, e7], e5)");
    assert(plan("mirror", [6, 7])[0] == '!');
    assert(plan("pattern", [6], "3, step: vec(10.mm, 0.mm)") == "s.pattern([e6], 3, step: vec(10.mm, 0.mm))");
    assert(plan("circular-pattern", [6, 7, 0], "6") == "s.circularPattern([e6, e7], 6, center: e0)");
    assert(plan("circular-pattern", [6, 7])[0] == '!');
}

/// Deletes entities `ids` of sketch `v` from the source: the statements
/// that make them, those that make what is drawn on them (a line on a
/// point), the constraints on any of them; a shape goes whole. The new
/// source, or null with `why` when it cannot be done from here (a statement
/// in a loop, a name still used elsewhere).
string deleteFromSketch(string source, string file, const ref SketchView v, const(size_t)[] ids, out string why)
{
    import std.algorithm : canFind, sort, uniq;
    import std.array : array;
    SketchWriter w;
    try
        w = SketchWriter(source, file, v);
    catch (CodegenException e)
    {
        why = e.msg;
        return null;
    }
    // what goes: those given, what is made on them, everything their calls make (a shape's lines and corners)
    bool[size_t] gone;
    foreach (e; ids)
        gone[e] = true;
    for (bool more = true; more;)
    {
        more = false;
        foreach (i, en; v.entities)
        {
            if (i in gone || en.reference)
                continue;
            bool goes = en.points.canFind!(p => (p in gone) !is null);
            foreach (g, _; gone)
                if (v.entities[g].span == en.span && !v.entities[g].reference)
                    goes = true;
            if (goes)
            {
                gone[i] = true;
                more = true;
            }
        }
    }
    foreach (g, _; gone)
        if (v.entities[g].reference)
        {
            why = "a face's edges and the origin are references: they stay";
            return null;
        }
    // the statements: the calls that made them, the constraints on them
    size_t[] starts;
    bool[string] names;
    string fail(string reason)
    {
        why = reason;
        return null;
    }
    size_t[2] statementOf(Span s)
    {
        immutable c = w.callToken(s);
        if (c == size_t.max || !w.direct(c))
            return [size_t.max, size_t.max];
        return w.statements[w.rangeOf(c)];
    }
    foreach (g, _; gone)
    {
        auto st = statementOf(v.entities[g].span);
        if (st[0] == size_t.max)
            return fail(format("line %d is in a loop, an if or another function: delete it by hand",
                v.entities[g].span.line));
        // the whole statement must be the call: auto x = s.line(…); or s.line(…);
        auto t = w.toks;
        // the names the statement declares (auto a = …, b = …)
        string[] declared;
        int depth;
        foreach (k; st[0] .. st[1])
        {
            immutable kk = t[k].kind;
            if (kk == Tok.lparen || kk == Tok.lbracket || kk == Tok.lbrace)
                depth++;
            else if (kk == Tok.rparen || kk == Tok.rbracket || kk == Tok.rbrace)
                depth--;
            else if (depth == 0 && kk == Tok.ident && k + 1 < t.length && t[k + 1].kind == Tok.assign
                && (t[k - 1].kind == Tok.kwAuto || t[k - 1].kind == Tok.comma))
                declared ~= t[k].text;
        }
        if (declared.length > 1)
        {
            // all of them must go: the entities each declares
            foreach (i, en; v.entities)
                if ((i in gone) is null && !en.reference)
                {
                    immutable ci = w.callToken(en.span);
                    if (ci != size_t.max && ci >= st[0] && ci <= st[1])
                        return fail(format("line %d declares %-(%s, %) together: delete it by hand, or split it",
                            v.entities[g].span.line, declared));
                }
        }
        foreach (d; declared)
            names[d] = true;
        starts ~= st[0];
    }
    foreach (c; v.constraints)
        if (c.entities.canFind!(e => (e in gone) !is null))
        {
            auto st = statementOf(c.span);
            if (st[0] == size_t.max)
                return fail(format("the constraint at line %d is in a loop, an if or another function: delete it by hand",
                    c.span.line));
            starts ~= st[0];
        }
    starts = starts.sort.uniq.array;
    // a name declared there and used anywhere else: not deleted
    foreach (i, t; w.toks)
        if (t.kind == Tok.ident && t.text in names && !(i > 0 && w.toks[i - 1].kind == Tok.dot))
        {
            bool inside;
            foreach (st0; starts)
            {
                immutable r = w.statements[w.rangeOf(st0)];
                if (i >= r[0] && i <= r[1])
                    inside = true;
            }
            if (!inside)
                return fail(format("%s is still used at line %d: change that first", t.text, t.span.line));
        }
    // whole lines out (a statement alone on its lines), from the end
    string r = source;
    foreach_reverse (st0; starts)
    {
        immutable range = w.statements[w.rangeOf(st0)];
        size_t a = offsetOf(source, w.toks[range[0]].span), b = offsetOf(source, w.toks[range[1]].span) + 1;
        while (a > 0 && (source[a - 1] == ' ' || source[a - 1] == '\t'))
            a--;
        if (b < source.length && source[b] == '\n' && (a == 0 || source[a - 1] == '\n'))
            b++;
        r = r[0 .. a] ~ r[b .. $];
    }
    return r;
}

unittest
{
    import std.algorithm : canFind, filter;
    import std.array : array;
    import std.file : tempDir;
    import std.path : buildPath;
    import hackerscad.lang.interp : Interp;
    import hackerscad.lang.sketchval : SketchVal;
    import hackerscad.kernel.occt.backend : OcctKernel;

    immutable file = buildPath(tempDir, "hcad-sketchdelete.hcad");
    auto kernel = new OcctKernel;
    SketchView viewOf(string src)
    {
        auto it = new Interp(kernel);
        it.runSource(src, file);
        return (cast(SketchVal) it.sketches[$ - 1]).view();
    }
    immutable src = "module m;\n@part\nSolid p()\n{\n"
        ~ "    auto s = sketch();\n"
        ~ "    auto a = s.point(0, 0, fixed: true);\n"
        ~ "    auto b = s.point(40, 2);\n"
        ~ "    auto c = s.point(20, 30);\n"
        ~ "    auto ab = s.line(a, b);\n"
        ~ "    s.line(b, c);\n"
        ~ "    s.line(c, a);\n"
        ~ "    s.horizontal(ab);\n"
        ~ "    auto r = s.rect(vec(50, 0), vec(70, 20));\n"
        ~ "    s.length(r[0], 20.mm);\n"
        ~ "    return box(1, 1, 1);\n}\n";
    auto v = viewOf(src);
    size_t at(uint line, string kind) => v.entities.length.iota.filter!(i => v.entities[i].span.line == line
        && v.entities[i].kind == kind).front;
    string why;
    // a point: it, the lines on it, the constraints on those
    auto noB = deleteFromSketch(src, file, v, [at(7, "point")], why);
    assert(noB !is null, why);
    assert(!noB.canFind("auto b =") && !noB.canFind("s.line(b, c)") && !noB.canFind("auto ab =")
        && !noB.canFind("s.horizontal(ab)") && noB.canFind("    s.line(c, a);\n    auto r ="), noB);
    viewOf(noB);
    // a line of a shape: the shape goes whole, with its constraint
    auto noRect = deleteFromSketch(src, file, v, [at(13, "line")], why);
    assert(noRect !is null && !noRect.canFind("s.rect") && !noRect.canFind("s.length(r[0]"), noRect);
    // a name still used elsewhere: left
    immutable used = src[0 .. src.length - 26] ~ "    writeln(ab.length);\n" ~ src[src.length - 26 .. $];
    auto u = viewOf(used);
    assert(deleteFromSketch(used, file, u, [at(9, "line")], why) is null && why.canFind("ab is still used"), why);
}

/// Turns the entities `ids` into construction geometry (drawn dashed, out of the
/// profile) when `on`, else into plain geometry: `construction: true` added to
/// the calls that made them, or taken away; those already so are left. A call
/// makes all it makes so (a shape's every side). The new source, or null with why.
string setConstruction(string source, string file, const ref SketchView v, const(size_t)[] ids, bool on,
    out string why)
{
    import std.algorithm : canFind;
    if (ids.length == 0)
    {
        why = "select what to turn into construction geometry, or back";
        return null;
    }
    SketchWriter w;
    try
        w = SketchWriter(source, file, v);
    catch (CodegenException e)
    {
        why = e.msg;
        return null;
    }
    foreach (e; ids)
        if (v.entities[e].reference)
        {
            why = "a face's edges and the origin are references: always out of the profile";
            return null;
        }
    // the calls, each once, with the edit each needs
    struct Change { size_t from, to; string text; }
    Change[] changes;
    size_t[] calls;
    foreach (e; ids)
    {
        immutable c = w.callToken(v.entities[e].span);
        if (c == size_t.max || !w.direct(c))
        {
            why = format("line %d is in a loop, an if or another function: change it by hand", v.entities[e].span.line);
            return null;
        }
        if (calls.canFind(c) || v.entities[e].construction == on)
            continue;
        calls ~= c;
        immutable close = w.closing(c);
        auto t = w.toks;
        // construction: given already (as false, or true to take away)
        ptrdiff_t named = -1;
        int depth;
        foreach (k; c + 1 .. close)
        {
            immutable kk = t[k].kind;
            if (kk == Tok.lparen || kk == Tok.lbracket || kk == Tok.lbrace)
                depth++;
            else if (kk == Tok.rparen || kk == Tok.rbracket || kk == Tok.rbrace)
                depth--;
            else if (depth == 0 && kk == Tok.ident && t[k].text == "construction" && t[k + 1].kind == Tok.colon)
                named = k;
        }
        size_t at(size_t k) => offsetOf(source, t[k].span);
        if (named >= 0)
        {
            // its value, to the next comma or the closing bracket
            size_t end = named + 2;
            while (end < close && t[end].kind != Tok.comma)
                end++;
            if (t[named - 1].kind == Tok.comma)
                changes ~= Change(at(named - 1), at(end), on ? ", construction: true" : "");
            else
                changes ~= Change(at(named), end < close ? at(end + 1) : at(end), on ? "construction: true"
                    ~ (end < close ? ", " : "") : "");
        }
        else if (on)
            changes ~= Change(at(close), at(close), t[close - 1].kind == Tok.lparen ? "construction: true"
                : ", construction: true");
    }
    import std.algorithm : sort;
    changes.sort!((a, b) => a.from > b.from);
    string r = source;
    foreach (ch; changes)
        r = r[0 .. ch.from] ~ ch.text ~ r[ch.to .. $];
    return r;
}

unittest
{
    import std.algorithm : canFind, filter;
    import std.array : array;
    import std.file : tempDir;
    import std.path : buildPath;
    import hackerscad.lang.interp : Interp;
    import hackerscad.lang.sketchval : SketchVal;
    import hackerscad.kernel.occt.backend : OcctKernel;

    immutable file = buildPath(tempDir, "hcad-sketchconstruction.hcad");
    auto kernel = new OcctKernel;
    SketchView viewOf(string src)
    {
        auto it = new Interp(kernel);
        it.runSource(src, file);
        return (cast(SketchVal) it.sketches[$ - 1]).view();
    }
    immutable src = "module m;\n@part\nSolid p()\n{\n"
        ~ "    auto s = sketch();\n"
        ~ "    auto a = s.point(0, 0, fixed: true);\n"
        ~ "    auto b = s.point(40, 2);\n"
        ~ "    auto ab = s.line(a, b);\n"
        ~ "    auto r = s.rect(vec(50, 0), vec(70, 20), construction: false);\n"
        ~ "    return box(1, 1, 1);\n}\n";
    auto v = viewOf(src);
    size_t at(uint line, string kind) => v.entities.length.iota.filter!(i => v.entities[i].span.line == line
        && v.entities[i].kind == kind).front;
    string why;
    auto made = setConstruction(src, file, v, [at(8, "line"), at(9, "line")], true, why);
    assert(made !is null, why);
    assert(made.canFind("s.line(a, b, construction: true)") && made.canFind("vec(70, 20), construction: true)"), made);
    // plain again
    auto v2 = viewOf(made);
    // a point written inside a circle's call: the circle's centre
    {
        immutable nested = "module m;\n@part\nSolid p()\n{\n    auto s = sketch();\n"
            ~ "    s.circle(s.point(20, 10, fixed: true), r: 6.mm);\n    return box(1, 1, 1);\n}\n";
        auto nv = viewOf(nested);
        size_t centre;
        foreach (i, e; nv.entities)
            if (e.kind == "point")
                centre = i;
        auto nw = SketchWriter(nested, file, nv);
        assert(nw.name(centre) == "circle.center", nw.name(centre));
        assert(nw.result().canFind("auto circle = s.circle("), nw.result());
    }
    // drawing as construction: the geometry is, its points and constraints are not
    auto cw = SketchWriter(src, file, v);
    cw.construction = true;
    cw.add("auto q = s.point(1, 2)");
    cw.add("auto l = s.line(a, q)");
    cw.add("s.midpoint(q, ab)");
    cw.add("s.on(q, ab)");
    auto drawn = cw.result();
    assert(drawn.canFind("s.point(1, 2);") && drawn.canFind("s.line(a, q, construction: true);")
        && drawn.canFind("s.midpoint(q, ab);") && drawn.canFind("s.on(q, ab);"), drawn);
    auto back = setConstruction(made, file, v2, [at(8, "line")], false, why);
    assert(back !is null && back.canFind("s.line(a, b);"), back);
}

/// Moves points of the sketch: their s.point(x, y) written with the places
/// `to` (where the solver starts from: it keeps them to their constraints).
/// Only points made by an s.point call of plain numbers in the sketch's own
/// code can be moved; null with why for any other.
string movePoints(string source, string file, const ref SketchView v, const(size_t)[] points, const(Vec3)[] to,
    out string why)
{
    import std.algorithm : canFind;
    SketchWriter w;
    try
        w = SketchWriter(source, file, v);
    catch (CodegenException e)
    {
        why = e.msg;
        return null;
    }
    struct Change { size_t from, to; string text; }
    Change[] changes;
    auto t = w.toks;
    size_t at(size_t k) => offsetOf(source, t[k].span);
    static string num(double x)
    {
        import std.math : round;
        return format("%.6g", round(x * 100) / 100 + 0.0);
    }
    foreach (n, p; points)
    {
        auto en = v.entities[p];
        if (en.reference)
        {
            why = "a face's edges and the origin are references: they stay";
            return null;
        }
        immutable c = w.callToken(en.span);
        if (c == size_t.max || c == 0 || t[c - 1].text != "point")
        {
            why = format("the point of line %d is made by a shape or from a vector: move it in the code", en.span.line);
            return null;
        }
        // its first two arguments, each a number (maybe negative, maybe .mm), maybe named x: and y:
        size_t k = c + 1;
        foreach (axis; 0 .. 2)
        {
            if (t[k].kind == Tok.ident && t[k + 1].kind == Tok.colon)
                k += 2;
            immutable start = k;
            if (t[k].kind == Tok.minus)
                k++;
            if (t[k].kind != Tok.intLit && t[k].kind != Tok.floatLit)
            {
                why = format("the place of the point of line %d is computed: change it in the code", en.span.line);
                return null;
            }
            k++;
            immutable mm = t[k].kind == Tok.dot && t[k + 1].kind == Tok.ident && t[k + 1].text == "mm";
            if (mm)
                k += 2;
            if (t[k].kind != Tok.comma && t[k].kind != Tok.rparen)
            {
                why = format("the place of the point of line %d is computed: change it in the code", en.span.line);
                return null;
            }
            changes ~= Change(at(start), at(k), num(axis == 0 ? to[n].x : to[n].y) ~ (mm ? ".mm" : ""));
            k++;
        }
    }
    import std.algorithm : sort;
    changes.sort!((a, b) => a.from > b.from);
    string r = source;
    foreach (ch; changes)
    {
        // what stood between the number and the comma (spaces) stays out of it
        size_t end = ch.to;
        while (end > ch.from && (r[end - 1] == ' ' || r[end - 1] == '\t'))
            end--;
        r = r[0 .. ch.from] ~ ch.text ~ r[end .. $];
    }
    return r;
}

unittest
{
    import std.algorithm : canFind;
    import std.file : tempDir;
    import std.path : buildPath;
    import hackerscad.lang.interp : Interp;
    import hackerscad.lang.sketchval : SketchVal;
    import hackerscad.kernel.occt.backend : OcctKernel;

    immutable file = buildPath(tempDir, "hcad-sketchmove.hcad");
    auto kernel = new OcctKernel;
    SketchView viewOf(string src)
    {
        auto it = new Interp(kernel);
        it.runSource(src, file);
        return (cast(SketchVal) it.sketches[$ - 1]).view();
    }
    immutable src = "module m;\n@part\nSolid p()\n{\n"
        ~ "    auto s = sketch();\n"
        ~ "    auto a = s.point(0, -2.5.mm, fixed: true);\n"
        ~ "    auto b = s.point(40, 2);\n"
        ~ "    auto c = s.point(10 * 2, 2);\n"
        ~ "    s.rect(vec(50, 0), vec(70, 20));\n"
        ~ "    return box(1, 1, 1);\n}\n";
    auto v = viewOf(src);
    size_t on(uint line)
    {
        foreach (i, e; v.entities)
            if (e.span.line == line && e.kind == "point")
                return i;
        assert(0);
    }
    string why;
    auto moved = movePoints(src, file, v, [on(6), on(7)], [Vec3(1.234, -3), Vec3(42, 5.5)], why);
    assert(moved !is null, why);
    assert(moved.canFind("s.point(1.23, -3.mm, fixed: true)") && moved.canFind("s.point(42, 5.5)"), moved);
    assert(movePoints(src, file, v, [on(8)], [Vec3(1, 1)], why) is null && why.canFind("computed"), why);
    assert(movePoints(src, file, v, [on(9)], [Vec3(1, 1)], why) is null && why.canFind("shape"), why);
}
