/// A drawing sheet as plain 2D vector data (millimetres, origin at the
/// bottom-left corner, y up) and its writers: SVG, PDF and DXF.
module hackerscad.drawing.sheet;

import std.array : appender, join;
import std.conv : to;
import std.format : format;
import std.math : PI, cos, sin, abs;
import std.string : replace;

/// Line styles, after ISO 128: thick visible edges, thin lines for
/// dimensions and hatching, dashed hidden edges, dash-dot centre lines.
enum Pen
{
    visible,
    thin,
    hidden,
    center,
    border,
}

struct Line
{
    double x1, y1, x2, y2;
    Pen pen;
}

enum Anchor
{
    start,
    middle,
    end,
}

struct Text
{
    double x, y;
    double size;        /// letter height in mm
    string text;
    Anchor anchor;
    double angle = 0;   /// degrees, counter-clockwise
}

/// A filled triangle (arrow heads).
struct Arrow
{
    double[6] xy;
}

struct Sheet
{
    double width = 297, height = 210;
    Line[] lines;
    Text[] texts;
    Arrow[] arrows;

    void line(double x1, double y1, double x2, double y2, Pen pen = Pen.visible)
    {
        lines ~= Line(x1, y1, x2, y2, pen);
    }

    void rect(double x, double y, double w, double h, Pen pen = Pen.border)
    {
        line(x, y, x + w, y, pen);
        line(x + w, y, x + w, y + h, pen);
        line(x + w, y + h, x, y + h, pen);
        line(x, y + h, x, y, pen);
    }

    void text(double x, double y, string s, double size = 3.5, Anchor anchor = Anchor.start, double angle = 0)
    {
        texts ~= Text(x, y, size, s, anchor, angle);
    }

    /// Arrow head with its tip at (x, y) pointing along (dx, dy).
    void arrow(double x, double y, double dx, double dy, double length = 3)
    {
        import std.math : sqrt;
        immutable l = sqrt(dx * dx + dy * dy);
        if (l == 0)
            return;
        immutable ux = dx / l, uy = dy / l, w = length / 6;
        arrows ~= Arrow([x, y, x - ux * length - uy * w, y - uy * length + ux * w, x - ux * length + uy * w,
            y - uy * length - ux * w]);
    }
}

double penWidth(Pen p)
{
    final switch (p)
    {
    case Pen.visible: return 0.5;
    case Pen.thin: return 0.25;
    case Pen.hidden: return 0.35;
    case Pen.center: return 0.25;
    case Pen.border: return 0.7;
    }
}

// ---------------------------------------------------------------- SVG

string toSvg(const Sheet s)
{
    auto o = appender!string;
    o ~= format(`<svg xmlns="http://www.w3.org/2000/svg" width="%smm" height="%smm" viewBox="0 0 %s %s">` ~ "\n",
        n(s.width), n(s.height), n(s.width), n(s.height));
    o ~= `<rect width="100%" height="100%" fill="white"/>` ~ "\n";
    o ~= `<g fill="none" stroke="black" stroke-linecap="round">` ~ "\n";
    foreach (pen; [Pen.thin, Pen.center, Pen.hidden, Pen.visible, Pen.border])
    {
        string dash = pen == Pen.hidden ? ` stroke-dasharray="2 1"` : pen == Pen.center ? ` stroke-dasharray="6 1 1 1"` : "";
        string path;
        foreach (l; s.lines)
            if (l.pen == pen)
                path ~= format("M%s %sL%s %s", n(l.x1), n(s.height - l.y1), n(l.x2), n(s.height - l.y2));
        if (path.length)
            o ~= format(`<path stroke-width="%s"%s d="%s"/>` ~ "\n", n(penWidth(pen)), dash, path);
    }
    o ~= "</g>\n";
    foreach (a; s.arrows)
        o ~= format(`<path fill="black" d="M%s %sL%s %sL%s %sZ"/>` ~ "\n", n(a.xy[0]), n(s.height - a.xy[1]), n(a.xy[2]),
            n(s.height - a.xy[3]), n(a.xy[4]), n(s.height - a.xy[5]));
    foreach (t; s.texts)
    {
        string anchor = t.anchor == Anchor.middle ? "middle" : t.anchor == Anchor.end ? "end" : "start";
        string rot = t.angle != 0 ? format(` transform="rotate(%s %s %s)"`, n(-t.angle), n(t.x), n(s.height - t.y)) : "";
        o ~= format(`<text x="%s" y="%s" font-family="DejaVu Sans, Helvetica, Arial, sans-serif" font-size="%s" `
            ~ `text-anchor="%s"%s>%s</text>` ~ "\n", n(t.x), n(s.height - t.y), n(t.size * 1.4), anchor, rot, escape(t.text));
    }
    o ~= "</svg>\n";
    return o[];
}

private string n(double v) => format("%.3f", abs(v) < 5e-4 ? 0.0 : v).stripZeros;

private string stripZeros(string s)
{
    import std.string : indexOf;
    if (s.indexOf('.') < 0)
        return s;
    while (s[$ - 1] == '0')
        s = s[0 .. $ - 1];
    if (s[$ - 1] == '.')
        s = s[0 .. $ - 1];
    return s;
}

private string escape(string s) => s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");

// ---------------------------------------------------------------- PDF

/// A one-page PDF with the standard Helvetica font (texts in WinAnsi:
/// characters outside Latin-1 are replaced, ⌀ becomes Ø).
ubyte[] toPdf(const Sheet s)
{
    enum k = 72.0 / 25.4;   // mm → points
    auto c = appender!string;
    c ~= "1 J 1 j\n";
    foreach (pen; [Pen.thin, Pen.center, Pen.hidden, Pen.visible, Pen.border])
    {
        bool any;
        foreach (l; s.lines)
            if (l.pen == pen)
            {
                if (!any)
                {
                    c ~= format("%s w %s d\n", n(penWidth(pen) * k), pen == Pen.hidden ? format("[%s %s] 0", n(2 * k), n(k))
                        : pen == Pen.center ? format("[%s %s %s %s] 0", n(6 * k), n(k), n(k), n(k)) : "[] 0");
                    any = true;
                }
                c ~= format("%s %s m %s %s l\n", n(l.x1 * k), n(l.y1 * k), n(l.x2 * k), n(l.y2 * k));
            }
        if (any)
            c ~= "S\n";
    }
    foreach (a; s.arrows)
        c ~= format("%s %s m %s %s l %s %s l f\n", n(a.xy[0] * k), n(a.xy[1] * k), n(a.xy[2] * k), n(a.xy[3] * k),
            n(a.xy[4] * k), n(a.xy[5] * k));
    foreach (t; s.texts)
    {
        immutable size = t.size * 1.4 * k;
        auto str = latin1(t.text);
        immutable width = str.length * size * 0.52;   // Helvetica, roughly
        immutable shift = t.anchor == Anchor.middle ? width / 2 : t.anchor == Anchor.end ? width : 0;
        immutable ca = cos(t.angle * PI / 180), sa = sin(t.angle * PI / 180);
        c ~= format("BT /F1 %s Tf %s %s %s %s %s %s Tm (%s) Tj ET\n", n(size), n(ca), n(sa), n(-sa), n(ca),
            n(t.x * k - shift * ca), n(t.y * k - shift * sa), str);
    }
    auto content = c[];

    string[] objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        format("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %s %s] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            n(s.width * k), n(s.height * k)),
        format("<< /Length %d >>\nstream\n%sendstream", content.length, content),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    ];
    auto pdf = appender!string;
    pdf ~= "%PDF-1.4\n";
    size_t[] offsets;
    foreach (i, obj; objects)
    {
        offsets ~= pdf[].length;
        pdf ~= format("%d 0 obj\n%s\nendobj\n", i + 1, obj);
    }
    immutable xref = pdf[].length;
    pdf ~= format("xref\n0 %d\n0000000000 65535 f \n", objects.length + 1);
    foreach (o; offsets)
        pdf ~= format("%010d 00000 n \n", o);
    pdf ~= format("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", objects.length + 1, xref);
    return cast(ubyte[]) pdf[].dup;
}

/// PDF string literal in WinAnsi (Latin-1 for the characters we use).
private string latin1(string s)
{
    string r;
    foreach (dchar ch; s)
    {
        if (ch == '⌀')
            ch = 'Ø';
        if (ch == '(' || ch == ')' || ch == '\\')
            r ~= '\\';
        if (ch < 256)
            r ~= cast(char) ch;   // the byte itself: PDF strings are bytes
        else
            r ~= '?';
    }
    return r;
}

// ---------------------------------------------------------------- DXF

/// DXF R12 (ASCII): lines on layers VISIBLE, HIDDEN, THIN, CENTER, BORDER and
/// texts on TEXT. Arrow heads become SOLID entities.
string toDxf(const Sheet s)
{
    auto o = appender!string;
    void g(int code, string value)
    {
        o ~= format("%d\n%s\n", code, value);
    }

    g(0, "SECTION");
    g(2, "HEADER");
    g(9, "$INSUNITS");
    g(70, "4");
    g(0, "ENDSEC");
    g(0, "SECTION");
    g(2, "TABLES");
    g(0, "TABLE");
    g(2, "LTYPE");
    g(70, "3");
    foreach (lt; [["CONTINUOUS", "Solid line", ""], ["DASHED", "Dashed", "2,-1"], ["CENTER", "Center", "6,-1,1,-1"]])
    {
        g(0, "LTYPE");
        g(2, lt[0]);
        g(70, "0");
        g(3, lt[1]);
        g(72, "65");
        import std.algorithm : splitter;
        import std.array : array;
        auto parts = lt[2].length ? lt[2].splitter(',').array : [];
        g(73, parts.length.to!string);
        double total = 0;
        foreach (p; parts)
            total += abs(p.to!double);
        g(40, n(total));
        foreach (p; parts)
            g(49, p);
    }
    g(0, "ENDTAB");
    g(0, "TABLE");
    g(2, "LAYER");
    g(70, "6");
    foreach (layer; [["VISIBLE", "CONTINUOUS", "7"], ["HIDDEN", "DASHED", "8"], ["THIN", "CONTINUOUS", "7"],
            ["CENTER", "CENTER", "1"], ["BORDER", "CONTINUOUS", "7"], ["TEXT", "CONTINUOUS", "7"]])
    {
        g(0, "LAYER");
        g(2, layer[0]);
        g(70, "0");
        g(62, layer[2]);
        g(6, layer[1]);
    }
    g(0, "ENDTAB");
    g(0, "ENDSEC");
    g(0, "SECTION");
    g(2, "ENTITIES");
    static immutable string[] layers = ["VISIBLE", "THIN", "HIDDEN", "CENTER", "BORDER"];
    foreach (l; s.lines)
    {
        g(0, "LINE");
        g(8, layers[l.pen]);
        g(10, n(l.x1));
        g(20, n(l.y1));
        g(30, "0");
        g(11, n(l.x2));
        g(21, n(l.y2));
        g(31, "0");
    }
    foreach (a; s.arrows)
    {
        g(0, "SOLID");
        g(8, "THIN");
        foreach (i, codes; [[10, 20], [11, 21], [12, 22], [13, 23]])
        {
            immutable j = i < 3 ? i : 2;
            g(codes[0], n(a.xy[j * 2]));
            g(codes[1], n(a.xy[j * 2 + 1]));
        }
    }
    foreach (t; s.texts)
    {
        g(0, "TEXT");
        g(8, "TEXT");
        g(10, n(t.x));
        g(20, n(t.y));
        g(30, "0");
        g(40, n(t.size));
        g(1, t.text.replace("⌀", "%%c"));
        if (t.angle != 0)
            g(50, n(t.angle));
        if (t.anchor != Anchor.start)
        {
            g(72, t.anchor == Anchor.middle ? "1" : "2");
            g(11, n(t.x));
            g(21, n(t.y));
            g(31, "0");
        }
    }
    g(0, "ENDSEC");
    g(0, "EOF");
    return o[];
}

unittest
{
    import std.algorithm : canFind;

    Sheet s;
    s.rect(10, 10, 100, 50);
    s.line(0, 0, 10, 10, Pen.hidden);
    s.text(20, 20, "⌀6 <x>", 3.5, Anchor.middle);
    s.arrow(50, 50, 1, 0);
    auto svg = toSvg(s);
    assert(svg.canFind(`stroke-dasharray="2 1"`) && svg.canFind("⌀6 &lt;x&gt;") && svg.canFind(`text-anchor="middle"`));
    auto pdf = cast(string) toPdf(s);
    assert(pdf[0 .. 8] == "%PDF-1.4" && pdf.canFind("/Helvetica") && pdf.canFind("%%EOF"));
    auto dxf = toDxf(s);
    assert(dxf.canFind("LINE\n8\nHIDDEN") && dxf.canFind("%%c6") && dxf.canFind("EOF"));
}
