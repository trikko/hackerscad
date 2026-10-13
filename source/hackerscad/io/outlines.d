/// 2D drawings read as closed outlines (polylines, in mm): SVG (paths,
/// rectangles, circles, ellipses, polygons, with their transforms) and
/// DXF (lines, arcs, circles, polylines with bulges, ellipses, splines).
/// Curves become short straight pieces, about 0.05 mm off the curve.
module hackerscad.io.outlines;

import std.algorithm : canFind, endsWith, max, min, startsWith;
import std.array : array, split;
import std.ascii : isAlpha, isDigit, isWhite;
import std.conv : to, ConvException;
import std.format : format;
import std.math : abs, acos, atan2, ceil, cos, PI, sin, sqrt;
import std.string : indexOf, strip, toLower;

/// A drawing that cannot be read: the message says why.
class OutlineException : Exception
{
    this(string msg) { super(msg); }
}

alias Pt = double[2];
alias Loop = Pt[];

/// How far straight pieces may stray from a curve (mm).
enum tolerance = 0.05;

/// Segments for an arc of `radius` turning `angle` radians.
size_t segmentsFor(double radius, double angle)
{
    // the sagitta r (1 - cos(a/2n)) within tolerance
    if (radius <= tolerance)
        return 4;
    immutable step = 2 * acos(max(-1.0, 1 - tolerance / radius));
    return max(4, cast(size_t) ceil(abs(angle) / step));
}

// ------------------------------------------------------------------- SVG

/// The closed outlines of an SVG drawing, in mm with y up. Units: from the
/// drawing's width and height in mm, cm, in or pt over its viewBox; plain
/// numbers (or px) are taken as mm.
Loop[] readSvg(string text)
{
    auto parser = SvgParser(text);
    return parser.run();
}

private struct Matrix
{
    double a = 1, b = 0, c = 0, d = 1, e = 0, f = 0;   // x' = a x + c y + e, y' = b x + d y + f

    Matrix opBinary(string op : "*")(Matrix m) const
        => Matrix(a * m.a + c * m.b, b * m.a + d * m.b, a * m.c + c * m.d, b * m.c + d * m.d,
            a * m.e + c * m.f + e, b * m.e + d * m.f + f);

    Pt apply(Pt p) const => [a * p[0] + c * p[1] + e, b * p[0] + d * p[1] + f];
}

private struct Tag
{
    string name;
    string[string] attrs;
    bool closing, selfClosing;
}

private struct SvgParser
{
    string text;
    size_t at;
    Loop[] loops;

    Loop[] run()
    {
        Matrix[] stack = [Matrix.init];
        int skipping;   // inside <defs>, <clipPath>, <mask>, <symbol>, <pattern>: not drawn
        bool rootSeen;
        while (true)
        {
            auto t = nextTag();
            if (t.name.length == 0)
                break;
            immutable hidden = ["defs", "clippath", "mask", "symbol", "pattern", "marker", "style", "title", "desc"]
                .canFind(t.name.toLower);
            if (t.closing)
            {
                if (hidden && skipping > 0)
                    skipping--;
                else if (stack.length > 1 && (t.name == "g" || t.name == "svg" || t.name == "a"))
                    stack = stack[0 .. $ - 1];
                continue;
            }
            if (hidden)
            {
                if (!t.selfClosing)
                    skipping++;
                continue;
            }
            if (skipping)
                continue;
            auto m = stack[$ - 1];
            if (auto tr = "transform" in t.attrs)
                m = m * parseTransform(*tr);
            if (t.name == "svg" && !rootSeen)
            {
                rootSeen = true;
                // millimetres from the size over the viewBox; y turned up
                double sx = 1, sy = 1, vx = 0, vy = 0, vh = 0;
                double[] vb;
                if (auto v = "viewBox" in t.attrs)
                    vb = numbers(*v);
                if (vb.length == 4)
                {
                    vx = vb[0];
                    vy = vb[1];
                    vh = vb[3];
                    if (auto w = "width" in t.attrs)
                        if (immutable mm = toMm(*w))
                            sx = mm / vb[2];
                    if (auto h = "height" in t.attrs)
                        if (immutable mm = toMm(*h))
                            sy = mm / vb[3];
                    if ("width" in t.attrs && "height" !in t.attrs)
                        sy = sx;
                    if ("height" in t.attrs && "width" !in t.attrs)
                        sx = sy;
                }
                else if (auto h = "height" in t.attrs)
                    vh = numbers(*h).length ? numbers(*h)[0] : 0;
                m = Matrix(sx, 0, 0, -sy, -vx * sx, (vy + vh) * sy) * m;
            }
            if ((t.name == "g" || t.name == "svg" || t.name == "a") && !t.selfClosing)
            {
                stack ~= m;
                continue;
            }
            shape(t, m);
        }
        if (loops.length == 0)
            throw new OutlineException("the SVG has no closed shapes (paths, rectangles, circles, polygons)");
        return loops;
    }

    void shape(Tag t, Matrix m)
    {
        double num(string name, double def = 0)
        {
            if (auto v = name in t.attrs)
            {
                auto n = numbers(*v);
                return n.length ? n[0] : def;
            }
            return def;
        }
        void add(Loop l)
        {
            if (l.length < 3)
                return;
            foreach (ref p; l)
                p = m.apply(p);
            loops ~= l;
        }
        switch (t.name)
        {
        case "rect":
            {
                immutable x = num("x"), y = num("y"), w = num("width"), h = num("height");
                double rx = num("rx", -1), ry = num("ry", -1);
                if (rx < 0)
                    rx = ry < 0 ? 0 : ry;
                if (ry < 0)
                    ry = rx;
                rx = min(rx, w / 2);
                ry = min(ry, h / 2);
                if (w <= 0 || h <= 0)
                    return;
                if (rx <= 0)
                    return add([[x, y], [x + w, y], [x + w, y + h], [x, y + h]]);
                Loop l;
                void corner(double cx, double cy, double from)
                {
                    immutable n = segmentsFor(max(rx, ry), PI / 2);
                    foreach (i; 0 .. n + 1)
                    {
                        immutable a = from + PI / 2 * i / n;
                        l ~= [cx + rx * cos(a), cy + ry * sin(a)];
                    }
                }
                corner(x + w - rx, y + ry, -PI / 2);
                corner(x + w - rx, y + h - ry, 0);
                corner(x + rx, y + h - ry, PI / 2);
                corner(x + rx, y + ry, PI);
                return add(l);
            }
        case "circle", "ellipse":
            {
                immutable cx = num("cx"), cy = num("cy");
                immutable rx = t.name == "circle" ? num("r") : num("rx"), ry = t.name == "circle" ? num("r") : num("ry");
                if (rx <= 0 || ry <= 0)
                    return;
                Loop l;
                immutable n = segmentsFor(max(rx, ry), 2 * PI);
                foreach (i; 0 .. n)
                    l ~= [cx + rx * cos(2 * PI * i / n), cy + ry * sin(2 * PI * i / n)];
                return add(l);
            }
        case "polygon":
            {
                auto n = numbers(t.attrs.get("points", ""));
                Loop l;
                for (size_t i = 0; i + 1 < n.length; i += 2)
                    l ~= [n[i], n[i + 1]];
                return add(l);
            }
        case "path":
            foreach (l; pathLoops(t.attrs.get("d", "")))
                add(l);
            return;
        default:
            return;   // lines, open polylines, text, images: no area
        }
    }

    Tag nextTag()
    {
        while (true)
        {
            auto lt = text.indexOf('<', at);
            if (lt < 0)
                return Tag.init;
            at = lt + 1;
            if (text[at .. $].startsWith("!--"))
            {
                auto e = text.indexOf("-->", at);
                at = e < 0 ? text.length : e + 3;
                continue;
            }
            if (text[at .. $].startsWith("![CDATA["))
            {
                auto e = text.indexOf("]]>", at);
                at = e < 0 ? text.length : e + 3;
                continue;
            }
            if (at < text.length && (text[at] == '?' || text[at] == '!'))
            {
                auto e = text.indexOf('>', at);
                at = e < 0 ? text.length : e + 1;
                continue;
            }
            Tag t;
            if (at < text.length && text[at] == '/')
            {
                t.closing = true;
                at++;
            }
            immutable nameStart = at;
            while (at < text.length && !isWhite(text[at]) && text[at] != '>' && text[at] != '/')
                at++;
            t.name = text[nameStart .. at];
            // without its namespace prefix (svg:path)
            if (auto colon = t.name.indexOf(':') + 1)
                t.name = t.name[colon .. $];
            while (at < text.length)
            {
                while (at < text.length && isWhite(text[at]))
                    at++;
                if (at >= text.length)
                    break;
                if (text[at] == '>')
                {
                    at++;
                    break;
                }
                if (text[at] == '/')
                {
                    t.selfClosing = true;
                    at++;
                    continue;
                }
                immutable ks = at;
                while (at < text.length && text[at] != '=' && !isWhite(text[at]) && text[at] != '>')
                    at++;
                auto key = text[ks .. at];
                while (at < text.length && isWhite(text[at]))
                    at++;
                if (at < text.length && text[at] == '=')
                {
                    at++;
                    while (at < text.length && isWhite(text[at]))
                        at++;
                    if (at < text.length && (text[at] == '"' || text[at] == '\''))
                    {
                        immutable q = text[at];
                        auto e = text.indexOf(q, at + 1);
                        if (e < 0)
                            e = text.length;
                        t.attrs[key] = text[at + 1 .. e];
                        at = e + 1;
                    }
                }
            }
            return t;
        }
    }
}

/// Numbers in an attribute ("10 20.5,-3e2"), units dropped.
private double[] numbers(string s)
{
    double[] r;
    size_t i;
    while (i < s.length)
    {
        while (i < s.length && !(isDigit(s[i]) || s[i] == '-' || s[i] == '+' || s[i] == '.'))
            i++;
        if (i >= s.length)
            break;
        immutable start = i;
        if (s[i] == '-' || s[i] == '+')
            i++;
        bool dot;
        while (i < s.length && (isDigit(s[i]) || (s[i] == '.' && !dot)))
        {
            dot = dot || s[i] == '.';
            i++;
        }
        if (i < s.length && (s[i] == 'e' || s[i] == 'E') && i + 1 < s.length
            && (isDigit(s[i + 1]) || s[i + 1] == '-' || s[i + 1] == '+'))
        {
            i += 2;
            while (i < s.length && isDigit(s[i]))
                i++;
        }
        try
            r ~= s[start .. i].to!double;
        catch (ConvException)
        {
        }
    }
    return r;
}

/// A length with its unit in mm; 0 when it has none (or px).
private double toMm(string s)
{
    auto v = s.strip;
    auto n = numbers(v);
    if (n.length == 0)
        return 0;
    if (v.endsWith("mm"))
        return n[0];
    if (v.endsWith("cm"))
        return n[0] * 10;
    if (v.endsWith("in"))
        return n[0] * 25.4;
    if (v.endsWith("pt"))
        return n[0] * 25.4 / 72;
    if (v.endsWith("pc"))
        return n[0] * 25.4 / 6;
    return 0;
}

private Matrix parseTransform(string s)
{
    Matrix m;
    size_t i;
    while (i < s.length)
    {
        while (i < s.length && !isAlpha(s[i]))
            i++;
        immutable ns = i;
        while (i < s.length && isAlpha(s[i]))
            i++;
        auto name = s[ns .. i];
        auto open = s.indexOf('(', i), close = s.indexOf(')', i);
        if (open < 0 || close < 0)
            break;
        auto v = numbers(s[open + 1 .. close]);
        i = close + 1;
        double at(size_t k, double def = 0) => k < v.length ? v[k] : def;
        Matrix t;
        switch (name)
        {
        case "matrix": if (v.length == 6) t = Matrix(v[0], v[1], v[2], v[3], v[4], v[5]); break;
        case "translate": t = Matrix(1, 0, 0, 1, at(0), at(1)); break;
        case "scale": t = Matrix(at(0, 1), 0, 0, at(1, at(0, 1)), 0, 0); break;
        case "rotate":
            {
                immutable a = at(0) * PI / 180, cx = at(1), cy = at(2);
                t = Matrix(1, 0, 0, 1, cx, cy) * Matrix(cos(a), sin(a), -sin(a), cos(a), 0, 0) * Matrix(1, 0, 0, 1, -cx, -cy);
                break;
            }
        case "skewX": t = Matrix(1, 0, sin(at(0) * PI / 180) / cos(at(0) * PI / 180), 1, 0, 0); break;
        case "skewY": t = Matrix(1, sin(at(0) * PI / 180) / cos(at(0) * PI / 180), 0, 1, 0, 0); break;
        default: break;
        }
        m = m * t;
    }
    return m;
}

/// The closed subpaths of path data: open ones are closed (a shape filled
/// by a viewer is closed by it), single points and lines dropped.
private Loop[] pathLoops(string d)
{
    Loop[] loops;
    Loop cur;
    Pt pos = [0, 0], start = [0, 0], lastCtrl = [0, 0];
    char lastCmd;
    size_t i;
    void finish()
    {
        if (cur.length >= 3)
            loops ~= cur;
        cur = null;
    }
    double[] args(size_t count)
    {
        // `count` numbers, or none when the next thing is a command
        double[] r;
        foreach (_; 0 .. count)
        {
            while (i < d.length && (isWhite(d[i]) || d[i] == ','))
                i++;
            if (i >= d.length || isAlpha(d[i]) && d[i] != 'e' && d[i] != 'E')
                return null;
            immutable s = i;
            if (d[i] == '-' || d[i] == '+')
                i++;
            bool dot;
            while (i < d.length && (isDigit(d[i]) || (d[i] == '.' && !dot)))
            {
                dot = dot || d[i] == '.';
                i++;
            }
            if (i < d.length && (d[i] == 'e' || d[i] == 'E'))
            {
                i++;
                if (i < d.length && (d[i] == '-' || d[i] == '+'))
                    i++;
                while (i < d.length && isDigit(d[i]))
                    i++;
            }
            if (i == s)
                return null;
            try
                r ~= d[s .. i].to!double;
            catch (ConvException)
                throw new OutlineException("malformed number in an SVG path: " ~ d[s .. i]);
        }
        return r;
    }
    // arc flags are single digits that may touch the next number ("a5 5 0 011 1")
    double flag()
    {
        while (i < d.length && (isWhite(d[i]) || d[i] == ','))
            i++;
        if (i < d.length && (d[i] == '0' || d[i] == '1'))
            return d[i++] - '0';
        throw new OutlineException("malformed arc flag in an SVG path");
    }
    void lineTo(Pt p)
    {
        if (cur.length == 0)
            cur ~= pos;
        cur ~= p;
        pos = p;
    }
    void cubic(Pt c1, Pt c2, Pt p)
    {
        immutable len = dist(pos, c1) + dist(c1, c2) + dist(c2, p);
        immutable n = max(4, cast(size_t) ceil(len / 0.5));
        auto p0 = pos;
        foreach (k; 1 .. n + 1)
        {
            immutable t = cast(double) k / n, u = 1 - t;
            lineTo([u * u * u * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * p[0],
                u * u * u * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * p[1]]);
        }
        lastCtrl = c2;
    }
    void quadratic(Pt c, Pt p)
    {
        immutable len = dist(pos, c) + dist(c, p);
        immutable n = max(4, cast(size_t) ceil(len / 0.5));
        auto p0 = pos;
        foreach (k; 1 .. n + 1)
        {
            immutable t = cast(double) k / n, u = 1 - t;
            lineTo([u * u * p0[0] + 2 * u * t * c[0] + t * t * p[0], u * u * p0[1] + 2 * u * t * c[1] + t * t * p[1]]);
        }
        lastCtrl = c;
    }
    void arc(double rx, double ry, double rot, bool large, bool sweep, Pt p)
    {
        // the endpoint form to the centre form (SVG implementation notes, F.6.5)
        auto p0 = pos;
        rx = abs(rx);
        ry = abs(ry);
        if (rx == 0 || ry == 0 || (p0[0] == p[0] && p0[1] == p[1]))
            return lineTo(p);
        immutable phi = rot * PI / 180, cp = cos(phi), sp = sin(phi);
        immutable dx = (p0[0] - p[0]) / 2, dy = (p0[1] - p[1]) / 2;
        immutable x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy;
        immutable lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lambda > 1)
        {
            rx *= sqrt(lambda);
            ry *= sqrt(lambda);
        }
        immutable num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        immutable den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        auto coef = sqrt(max(0.0, num / den));
        if (large == sweep)
            coef = -coef;
        immutable cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx;
        immutable cx = cp * cx1 - sp * cy1 + (p0[0] + p[0]) / 2, cy = sp * cx1 + cp * cy1 + (p0[1] + p[1]) / 2;
        double angle(double ux, double uy, double vx, double vy)
        {
            immutable a = atan2(ux * vy - uy * vx, ux * vx + uy * vy);
            return a;
        }
        immutable t1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry);
        auto dt = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry);
        if (!sweep && dt > 0)
            dt -= 2 * PI;
        else if (sweep && dt < 0)
            dt += 2 * PI;
        immutable n = segmentsFor(max(rx, ry), dt);
        foreach (k; 1 .. n + 1)
        {
            immutable t = t1 + dt * k / n;
            immutable ex = rx * cos(t), ey = ry * sin(t);
            Pt q = [cp * ex - sp * ey + cx, sp * ex + cp * ey + cy];
            lineTo(k == n ? p : q);
        }
    }

    while (i < d.length)
    {
        while (i < d.length && (isWhite(d[i]) || d[i] == ','))
            i++;
        if (i >= d.length)
            break;
        char cmd;
        if (isAlpha(d[i]))
            cmd = d[i++];
        else if (lastCmd)
            cmd = lastCmd == 'M' ? 'L' : lastCmd == 'm' ? 'l' : lastCmd;   // implicit repetition
        else
            throw new OutlineException("an SVG path must start with M");
        immutable rel = cmd >= 'a';
        Pt off = rel ? pos : [0.0, 0.0];
        switch (cmd | 0x20)
        {
        case 'm':
            {
                auto a = args(2);
                if (!a)
                    break;
                finish();
                pos = [off[0] + a[0], off[1] + a[1]];
                start = pos;
                break;
            }
        case 'l':
            {
                auto a = args(2);
                if (!a)
                    break;
                lineTo([off[0] + a[0], off[1] + a[1]]);
                break;
            }
        case 'h':
            {
                auto a = args(1);
                if (!a)
                    break;
                lineTo([(rel ? pos[0] : 0) + a[0], pos[1]]);
                break;
            }
        case 'v':
            {
                auto a = args(1);
                if (!a)
                    break;
                lineTo([pos[0], (rel ? pos[1] : 0) + a[0]]);
                break;
            }
        case 'c':
            {
                auto a = args(6);
                if (!a)
                    break;
                cubic([off[0] + a[0], off[1] + a[1]], [off[0] + a[2], off[1] + a[3]], [off[0] + a[4], off[1] + a[5]]);
                break;
            }
        case 's':
            {
                auto a = args(4);
                if (!a)
                    break;
                // the first control point mirrors the previous curve's last
                Pt c1 = "cCsS".canFind(lastCmd) ? [2 * pos[0] - lastCtrl[0], 2 * pos[1] - lastCtrl[1]] : pos;
                cubic(c1, [off[0] + a[0], off[1] + a[1]], [off[0] + a[2], off[1] + a[3]]);
                break;
            }
        case 'q':
            {
                auto a = args(4);
                if (!a)
                    break;
                quadratic([off[0] + a[0], off[1] + a[1]], [off[0] + a[2], off[1] + a[3]]);
                break;
            }
        case 't':
            {
                auto a = args(2);
                if (!a)
                    break;
                Pt c = "qQtT".canFind(lastCmd) ? [2 * pos[0] - lastCtrl[0], 2 * pos[1] - lastCtrl[1]] : pos;
                quadratic(c, [off[0] + a[0], off[1] + a[1]]);
                break;
            }
        case 'a':
            {
                auto a = args(3);
                if (!a)
                    break;
                immutable large = flag() != 0, sweep = flag() != 0;
                auto e = args(2);
                if (!e)
                    throw new OutlineException("malformed arc in an SVG path");
                arc(a[0], a[1], a[2], large, sweep, [off[0] + e[0], off[1] + e[1]]);
                break;
            }
        case 'z':
            pos = start;
            finish();
            break;
        default:
            throw new OutlineException(format("unknown SVG path command '%s'", cmd));
        }
        lastCmd = cmd;
    }
    finish();
    return loops;
}

private double dist(Pt a, Pt b) => sqrt((a[0] - b[0]) ^^ 2 + (a[1] - b[1]) ^^ 2);

// ------------------------------------------------------------------- DXF

/// The closed outlines of a DXF drawing (its ENTITIES), in mm: circles,
/// ellipses and closed polylines as they are; lines, arcs, open polylines
/// and splines joined end to end into loops where their ends meet.
Loop[] readDxf(string text)
{
    // group code / value pairs
    string[2][] pairs;
    {
        auto lines = text.split('\n');
        for (size_t i = 0; i + 1 < lines.length; i += 2)
            pairs ~= [lines[i].strip, lines[i + 1].strip];
    }
    double scale = 1;
    // the drawing's unit ($INSUNITS: 1 inch, 4 mm, 5 cm, 6 m; none: mm)
    foreach (k, p; pairs)
        if (p[0] == "9" && p[1] == "$INSUNITS" && k + 1 < pairs.length)
        {
            switch (pairs[k + 1][1])
            {
            case "1": scale = 25.4; break;
            case "5": scale = 10; break;
            case "6": scale = 1000; break;
            default: break;
            }
        }
    Loop[] loops;
    Loop[] pieces;   // open chains, joined at the end

    // the entities: from "0 <TYPE>" to the next "0"
    size_t i;
    while (i < pairs.length && !(pairs[i][0] == "2" && pairs[i][1] == "ENTITIES"))
        i++;
    while (i < pairs.length)
    {
        if (pairs[i][0] != "0")
        {
            i++;
            continue;
        }
        auto type = pairs[i][1];
        if (type == "ENDSEC" || type == "EOF")
            break;
        size_t j = i + 1;
        while (j < pairs.length && pairs[j][0] != "0")
            j++;
        auto body = pairs[i + 1 .. j];
        double get(string code, double def = 0)
        {
            foreach (p; body)
                if (p[0] == code)
                    try
                        return p[1].to!double;
                    catch (ConvException)
                        return def;
            return def;
        }
        double[] all(string code)
        {
            double[] r;
            foreach (p; body)
                if (p[0] == code)
                    try
                        r ~= p[1].to!double;
                    catch (ConvException)
                    {
                    }
            return r;
        }
        switch (type)
        {
        case "LINE":
            pieces ~= [[get("10"), get("20")], [get("11"), get("21")]];
            break;
        case "CIRCLE":
            {
                immutable cx = get("10"), cy = get("20"), r = get("40");
                Loop l;
                immutable n = segmentsFor(r, 2 * PI);
                foreach (k; 0 .. n)
                    l ~= [cx + r * cos(2 * PI * k / n), cy + r * sin(2 * PI * k / n)];
                loops ~= l;
                break;
            }
        case "ARC":
            {
                immutable cx = get("10"), cy = get("20"), r = get("40");
                immutable a0 = get("50") * PI / 180;
                auto a1 = get("51") * PI / 180;
                if (a1 <= a0)
                    a1 += 2 * PI;
                Loop l;
                immutable n = segmentsFor(r, a1 - a0);
                foreach (k; 0 .. n + 1)
                {
                    immutable a = a0 + (a1 - a0) * k / n;
                    l ~= [cx + r * cos(a), cy + r * sin(a)];
                }
                pieces ~= l;
                break;
            }
        case "ELLIPSE":
            {
                immutable cx = get("10"), cy = get("20"), mx = get("11"), my = get("21"), ratio = get("40", 1);
                immutable t0 = get("41"), t1raw = get("42", 2 * PI);
                immutable t1 = t1raw <= t0 ? t1raw + 2 * PI : t1raw;
                immutable major = sqrt(mx * mx + my * my);
                Loop l;
                immutable n = segmentsFor(major, t1 - t0);
                foreach (k; 0 .. n + 1)
                {
                    immutable t = t0 + (t1 - t0) * k / n, u = cos(t), v = sin(t) * ratio;
                    l ~= [cx + u * mx - v * my, cy + u * my + v * mx];
                }
                if (abs(t1 - t0 - 2 * PI) < 1e-9)
                    loops ~= l[0 .. $ - 1];
                else
                    pieces ~= l;
                break;
            }
        case "LWPOLYLINE":
            {
                // vertices with the bulge of the piece after each (tan of a quarter of its arc)
                Pt[] pts;
                double[] bulges;
                foreach (p; body)
                {
                    if (p[0] == "10")
                    {
                        pts ~= [p[1].to!double, 0.0];
                        bulges ~= 0;
                    }
                    else if (p[0] == "20" && pts.length)
                        pts[$ - 1][1] = p[1].to!double;
                    else if (p[0] == "42" && bulges.length)
                        bulges[$ - 1] = p[1].to!double;
                }
                immutable closed = (cast(int) get("70")) & 1;
                auto l = withBulges(pts, bulges, closed != 0);
                if (closed)
                    loops ~= l;
                else
                    pieces ~= l;
                break;
            }
        case "POLYLINE":
            {
                // its VERTEX entities follow, until SEQEND
                Pt[] pts;
                double[] bulges;
                immutable closed = (cast(int) get("70")) & 1;
                size_t k = j;
                while (k < pairs.length)
                {
                    if (pairs[k][0] == "0" && pairs[k][1] == "SEQEND")
                        break;
                    if (pairs[k][0] == "0" && pairs[k][1] == "VERTEX")
                    {
                        pts ~= [0.0, 0.0];
                        bulges ~= 0;
                    }
                    else if (pts.length && pairs[k][0] == "10")
                        pts[$ - 1][0] = pairs[k][1].to!double;
                    else if (pts.length && pairs[k][0] == "20")
                        pts[$ - 1][1] = pairs[k][1].to!double;
                    else if (pts.length && pairs[k][0] == "42")
                        bulges[$ - 1] = pairs[k][1].to!double;
                    k++;
                }
                j = k;
                auto l = withBulges(pts, bulges, closed != 0);
                if (closed)
                    loops ~= l;
                else
                    pieces ~= l;
                break;
            }
        case "SPLINE":
            {
                immutable degree = cast(int) get("71", 3);
                auto knots = all("40");
                auto xs = all("10"), ys = all("20");
                Pt[] ctrl;
                foreach (k; 0 .. min(xs.length, ys.length))
                    ctrl ~= [xs[k], ys[k]];
                auto ws = all("41");
                Loop l;
                if (ctrl.length > degree && knots.length == ctrl.length + degree + 1)
                    l = bspline(degree, knots, ctrl, ws.length == ctrl.length ? ws : null);
                else
                {
                    // fit points only
                    auto fx = all("11"), fy = all("21");
                    foreach (k; 0 .. min(fx.length, fy.length))
                        l ~= [fx[k], fy[k]];
                }
                if (l.length < 2)
                    break;
                if ((cast(int) get("70")) & 1)
                    loops ~= l;
                else
                    pieces ~= l;
                break;
            }
        default:
            break;
        }
        i = j;
    }
    loops ~= joinPieces(pieces);
    if (loops.length == 0)
        throw new OutlineException("the DXF has no closed outlines (circles, closed polylines, or lines and arcs "
            ~ "meeting end to end)");
    foreach (ref l; loops)
        foreach (ref p; l)
            p = [p[0] * scale, p[1] * scale];
    return loops;
}

/// A polyline with the bulges of its pieces drawn as arcs.
private Loop withBulges(Pt[] pts, double[] bulges, bool closed)
{
    Loop r;
    immutable n = pts.length;
    foreach (k; 0 .. n)
    {
        r ~= pts[k];
        if (!closed && k + 1 == n)
            break;
        immutable b = bulges[k];
        if (abs(b) < 1e-12)
            continue;
        auto p = pts[k], q = pts[(k + 1) % n];
        immutable chord = dist(p, q);
        if (chord == 0)
            continue;
        // the arc through p and q turning 4 atan(b), left of p → q when positive
        import std.math : atan;
        immutable theta = 4 * atan(b), radius = chord / (2 * sin(abs(theta) / 2));
        immutable mx = (p[0] + q[0]) / 2, my = (p[1] + q[1]) / 2;
        immutable h = sqrt(max(0.0, radius * radius - chord * chord / 4)) * (abs(theta) > PI ? -1 : 1);
        immutable ux = (q[0] - p[0]) / chord, uy = (q[1] - p[1]) / chord;
        immutable side = b > 0 ? 1 : -1;
        immutable cx = mx - uy * h * side, cy = my + ux * h * side;
        immutable a0 = atan2(p[1] - cy, p[0] - cx);
        immutable segs = segmentsFor(radius, theta);
        foreach (s; 1 .. segs)
        {
            immutable a = a0 + theta * s / segs;
            r ~= [cx + radius * cos(a), cy + radius * sin(a)];
        }
    }
    if (closed && r.length > 1 && dist(r[0], r[$ - 1]) < 1e-9)
        r = r[0 .. $ - 1];
    return r;
}

/// A B-spline (rational with weights) sampled along its knots.
private Loop bspline(int p, double[] knots, Pt[] ctrl, double[] weights)
{
    Pt at(double t)
    {
        // de Boor on homogeneous points
        size_t k = p;
        while (k + 1 < knots.length - p - 1 && knots[k + 1] <= t)
            k++;
        double[3][] d;
        foreach (j; 0 .. p + 1)
        {
            immutable idx = k - p + j;
            immutable w = weights ? weights[idx] : 1;
            d ~= [ctrl[idx][0] * w, ctrl[idx][1] * w, w];
        }
        foreach (r; 1 .. p + 1)
            foreach_reverse (j; r .. p + 1)
            {
                immutable i = k - p + j;
                immutable den = knots[i + p - r + 1] - knots[i];
                immutable alpha = den == 0 ? 0 : (t - knots[i]) / den;
                foreach (c; 0 .. 3)
                    d[j][c] = (1 - alpha) * d[j - 1][c] + alpha * d[j][c];
            }
        return [d[p][0] / d[p][2], d[p][1] / d[p][2]];
    }
    immutable t0 = knots[p], t1 = knots[$ - p - 1];
    double len = 0;
    foreach (k; 1 .. ctrl.length)
        len += dist(ctrl[k - 1], ctrl[k]);
    immutable n = max(8, cast(size_t) ceil(len / 0.5));
    Loop r;
    foreach (k; 0 .. n + 1)
        r ~= at(t0 + (t1 - t0) * k / n);
    return r;
}

/// Open chains joined where their ends meet (within 1e-6 of the drawing's
/// size); chains that come back to their start are loops, the rest dropped.
private Loop[] joinPieces(Loop[] pieces)
{
    Loop[] loops;
    double size = 1;
    foreach (c; pieces)
        foreach (p; c)
            size = max(size, abs(p[0]), abs(p[1]));
    immutable eps = 1e-6 * size + 1e-9;
    bool near(Pt a, Pt b) => dist(a, b) <= eps;
    auto used = new bool[pieces.length];
    foreach (s; 0 .. pieces.length)
    {
        if (used[s])
            continue;
        used[s] = true;
        Loop chain = pieces[s].dup;
        bool grown = true;
        while (grown && !near(chain[0], chain[$ - 1]))
        {
            grown = false;
            foreach (k; 0 .. pieces.length)
            {
                if (used[k])
                    continue;
                auto c = pieces[k];
                if (near(chain[$ - 1], c[0]))
                    chain ~= c[1 .. $];
                else if (near(chain[$ - 1], c[$ - 1]))
                {
                    foreach_reverse (p; c[0 .. $ - 1])
                        chain ~= p;
                }
                else
                    continue;
                used[k] = true;
                grown = true;
                break;
            }
        }
        if (chain.length >= 4 && near(chain[0], chain[$ - 1]))
            loops ~= chain[0 .. $ - 1];
    }
    return loops;
}

unittest
{
    // SVG: a square with a round hole, in a drawing 20 mm wide over a
    // viewBox of 200 units; y turned up
    auto loops = readSvg(`<svg xmlns="http://www.w3.org/2000/svg" width="20mm" height="20mm" viewBox="0 0 200 200">
        <!-- a comment -->
        <g transform="translate(10 10)">
          <path d="M0 0 H100 V100 H0 Z"/>
          <circle cx="50" cy="50" r="20"/>
        </g>
        <defs><rect width="5" height="5"/></defs>
        </svg>`);
    assert(loops.length == 2);
    // the square: 10 mm, from (1, 19) down to (11, 9) in mm, y up
    double x0 = double.max, y0 = double.max, x1 = -double.max, y1 = -double.max;
    foreach (p; loops[0])
    {
        x0 = min(x0, p[0]);
        x1 = max(x1, p[0]);
        y0 = min(y0, p[1]);
        y1 = max(y1, p[1]);
    }
    assert(abs(x0 - 1) < 1e-9 && abs(x1 - 11) < 1e-9 && abs(y0 - 9) < 1e-9 && abs(y1 - 19) < 1e-9);

    // arcs and relative commands: a full circle of radius 5 made of two arcs
    auto arc = readSvg(`<svg viewBox="0 0 20 20" width="20mm" height="20mm"><path d="M5 10a5 5 0 1 0 10 0a5 5 0 1 0-10 0z"/></svg>`);
    assert(arc.length == 1);
    foreach (p; arc[0])
        assert(abs(dist(p, [10.0, 10.0]) - 5) < 1e-6);

    // DXF: four lines making a square, in inches
    auto dxf = readDxf("0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n1\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
        ~ "0\nLINE\n10\n0\n20\n0\n11\n1\n21\n0\n0\nLINE\n10\n1\n20\n1\n11\n1\n21\n0\n"
        ~ "0\nLINE\n10\n1\n20\n1\n11\n0\n21\n1\n0\nLINE\n10\n0\n20\n0\n11\n0\n21\n1\n0\nENDSEC\n0\nEOF\n");
    assert(dxf.length == 1 && dxf[0].length == 4);
    foreach (p; dxf[0])
        assert(abs(p[0]) < 1e-9 || abs(p[0] - 25.4) < 1e-9);
}
