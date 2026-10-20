/// `hcad literals`: the numbers written in a model that come back, where,
/// and which of them are sizes the original has (a hole's diameter, an
/// axis): the measures to name and turn into @params once a copy matches.
module hackerscad.tool.literals;

import std.algorithm : canFind, map, sort;
import std.array : array, join;
import std.conv : to;
import std.file : readText;
import std.format : format;
import std.math : abs;

import hackerscad.lang.lexer;

/// One number of the model and where it is written.
struct Literal
{
    double value;
    uint[] lines;
    string name;   /// the constant it is the value of, when one is declared with it
}

/// The numbers written at least twice in `source`, the most used first; 0, 1
/// and 2 (counts, halves, doubles) are left out. A minus sign written before
/// a number keeps its value apart (-8.75 is not 8.75).
Literal[] repeatedLiterals(string source, string file = "model")
{
    auto toks = lex(source, file);
    Literal[string] byText;
    foreach (i, t; toks)
    {
        if (t.kind != Tok.intLit && t.kind != Tok.floatLit)
            continue;
        double v = t.text.to!double;
        // a unary minus: after an operator, an opening bracket, a comma or the start
        if (i > 0 && toks[i - 1].kind == Tok.minus
            && (i == 1 || [Tok.lparen, Tok.lbracket, Tok.comma, Tok.assign, Tok.colon, Tok.question, Tok.arrow,
                Tok.plus, Tok.minus, Tok.mul, Tok.div, Tok.lt, Tok.le, Tok.gt, Tok.ge, Tok.eq, Tok.ne,
                Tok.kwReturn].canFind(toks[i - 2].kind)))
            v = -v;
        if (v == 0 || v == 1 || v == 2)
            continue;
        immutable key = format("%g", v);
        auto l = key in byText;
        if (l is null)
        {
            byText[key] = Literal(v);
            l = key in byText;
        }
        l.lines ~= t.span.line;
        // "immutable name = 6.25.mm;": the number already has a name
        if (i >= 2 && toks[i - 1].kind == Tok.assign && toks[i - 2].kind == Tok.ident
            && i >= 3 && [Tok.kwImmutable, Tok.kwEnum, Tok.kwConst, Tok.comma].canFind(toks[i - 3].kind))
            l.name = toks[i - 2].text;
    }
    Literal[] r;
    foreach (l; byText.byValue)
        if (l.lines.length >= 2)
            r ~= l;
    r.sort!((a, b) => a.lines.length != b.lines.length ? a.lines.length > b.lines.length : abs(a.value) > abs(b.value));
    return r;
}

/// What a value is on the original, from its features: "the diameter of a
/// hole ⌀8.05", "an axis at x 6.25"; empty when nothing matches. Sizes
/// match whatever the sign written; places (`signed`) only with their own.
string[] meaning(double v, const double[] sizes, const bool[] signed, const string[] names)
{
    string[] r;
    foreach (i, s; sizes)
        if (abs((signed[i] ? v : abs(v)) - s) < 0.005 && !r.canFind(names[i]))
            r ~= names[i];
    return r;
}

/// The report: each repeated number with its lines and, when `original` is
/// given (a mesh file, or a part of the model), the sizes of the original it
/// matches.
string literalsReport(string file, string original = null)
{
    import std.path : extension;
    import std.uni : toLower;
    auto lits = repeatedLiterals(readText(file), file);
    double[] sizes;
    bool[] signed;
    string[] names;
    if (original.length)
    {
        import hackerscad.geom.meshfeatures : analyse, Surface, plausible;
        import hackerscad.tool.features : meshOf;
        immutable ext = original.extension.toLower;
        auto mesh = [".stl", ".obj", ".ply", ".3mf", ".glb", ".gltf", ".step", ".stp"].canFind(ext) ? meshOf(original) : meshOf(file, original);
        void add(double v, string what, bool place = false)
        {
            sizes ~= place ? plausible(v) : plausible(abs(v));
            signed ~= place;
            names ~= what;
        }
        // the surfaces a person would size: not a print notch, not a sliver
        foreach (f; analyse(mesh).features)
            if (f.area >= 5 && (f.kind != Surface.cylinder || f.radius >= 1))
            final switch (f.kind)
            {
            case Surface.cylinder:
                immutable kind = f.hole ? "hole" : "shaft";
                add(2 * f.radius, format("the diameter of a %s ⌀%g", kind, plausible(2 * f.radius)));
                add(f.radius, format("the radius of a %s ⌀%g", kind, plausible(2 * f.radius)));
                foreach (k, c; ["x", "y", "z"])
                {
                    // where its axis is, across the axis's own direction
                    immutable along = [f.axis.x, f.axis.y, f.axis.z][k];
                    if (abs(along) < 0.01)
                        add([f.point.x, f.point.y, f.point.z][k], format("where the axis of the %s ⌀%g is, %s %g",
                            kind, plausible(2 * f.radius), c, plausible([f.point.x, f.point.y, f.point.z][k])), true);
                }
                break;
            case Surface.plane:
                foreach (k, c; ["x", "y", "z"])
                    if (abs(abs([f.normal.x, f.normal.y, f.normal.z][k]) - 1) < 1e-3)
                    {
                        immutable at = [f.normal.x, f.normal.y, f.normal.z][k] * f.offset;
                        add(at, format("a flat face at %s %g", c, plausible(at)), true);
                    }
                break;
            case Surface.sphere:
                add(f.radius, format("the radius of a sphere ⌀%g", plausible(2 * f.radius)));
                break;
            case Surface.cone, Surface.curved:
                break;
            }
    }
    string s = format("numbers written more than once in %s, the most used first%s:\n", file,
        original.length ? ", with what they are on " ~ original : "");
    if (lits.length == 0)
        return s ~ "  none (every number is written once, or named)\n";
    foreach (i, l; lits)
    {
        if (i == 30)
        {
            s ~= format("  and %d more\n", lits.length - 30);
            break;
        }
        string[] lineList = l.lines.map!(x => x.to!string).array;
        s ~= format("  %g, %d times (line%s %s)%s", l.value, l.lines.length, l.lines.length > 1 ? "s" : "",
            lineList.join(", "), l.name.length ? ", named " ~ l.name : "");
        auto m = meaning(l.value, sizes, signed, names);
        if (m.length)
            s ~= ": " ~ m[0 .. $ < 3 ? $ : 3].join("; ");
        s ~= "\n";
    }
    return s ~ "name the ones that matter (immutable or @param), and use the name where the number is written\n";
}

unittest
{
    auto l = repeatedLiterals(q{
        immutable axis = 6.25.mm;
        @part Solid p() => box(20, 30, 10) - cylinder(d: 8.05, h: 31).move(x: 6.25)
            - cylinder(d: 8.05, h: 32).move(x: -6.25, y: 3) - box(1, 4, 5).move(z: 0.5);
    });
    // 6.25 three times (once named), 8.05 twice, -6.25 kept apart, 0.5 and 1 once or skipped
    assert(l.length == 2, format("%s", l));
    // as many times each: the larger first
    assert(l[0].value == 8.05 && l[0].lines.length == 2 && l[0].name.length == 0);
    assert(l[1].value == 6.25 && l[1].lines.length == 2 && l[1].name == "axis");
    auto sizes = [8.05, 6.25];
    assert(meaning(8.05, sizes, [false, true], ["the diameter of a hole ⌀8.05", "an axis"]) == ["the diameter of a hole ⌀8.05"]);
    // a place keeps its side: -6.25 is not the axis at x 6.25
    assert(meaning(-6.25, sizes, [false, true], ["a", "an axis at x 6.25"]).length == 0);
    assert(meaning(6.25, sizes, [false, true], ["a", "an axis at x 6.25"]) == ["an axis at x 6.25"]);
}
