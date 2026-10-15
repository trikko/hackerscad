/// Annotations: marks drawn over the window's 3D view, as on a screenshot,
/// a whiteboard shared by the user and agents. Annotate locks the view
/// (the camera and what it shows cannot change); the user (or an agent)
/// draws arrows, crosses, circles, lines by hand and text over it, and what
/// lies under each mark's key points (the part, the face, the model point)
/// is noted when it is drawn, so an agent told "make a hole here" knows
/// where "here" is. Leaving Annotate drops them: they never float over a
/// view that moved.
///
/// This module is the data and its rules, without GTK (so the tests of the
/// core run them): the window draws them and locks the view
/// (gui/annotate), the control socket adds, removes and lists them
/// (gui/controlmethods).
module hackerscad.tool.annotations;

import std.algorithm : max, min;
import std.format : format;
import std.json;
import std.math : abs, round, sqrt;

import hackerscad.geom.vec;

/// What can be drawn: an arrow [tail, tip], a cross [the point it marks],
/// a circle (an ellipse in the box of its two corners), a line drawn by
/// hand (its points), a text (at its point, the top left of the text).
static immutable string[] kinds = ["arrow", "cross", "circle", "freehand", "text"];

/// The colours offered, by name: they read on the light and the dark grid
/// and on the parts' bright colours, each on a halo (light or dark).
static immutable string[] colourNames = ["magenta", "red", "orange", "yellow", "green", "blue", "black", "white"];
static immutable uint[] palette = [0x9E006B, 0xE01B24, 0xFF7800, 0xF6D32D, 0x26A269, 0x1C71D8, 0x1E1E1E, 0xFFFFFF];

/// The colour unless one is chosen: a deep magenta, which no part's colour
/// is mistaken for.
enum uint defaultColour = 0x9E006B;

/// A point of the view, as fractions of its width and height (0, 0 the
/// top left corner).
struct P
{
    double x = 0, y = 0;
}

/// What a point of the view shows: a part (its name, the face, the
/// model point there and the face's normal; a selector for the face when
/// one could be found), or the background (part empty).
struct Under
{
    P at;
    string part;
    int face = -1;
    Vec3 point, normal;
    string selector;
}

/// One mark on the view.
struct Annotation
{
    uint id;
    string kind;
    string by = "agent";   /// "agent" or "user"
    P[] points;            /// see `kinds`
    /// the same points as model points (the window's: each where the view
    /// shows it), so that a view drawn at another size shows the marks on
    /// what they mark; empty: the points alone
    Vec3[] at;
    string text;           /// a text's text; on the others a label beside them
    uint colour = defaultColour;
    Under[] under;         /// what lies under its key points (keyPoints), in that order
}

/// The points whose "under" counts: an arrow's tip then its tail, a
/// cross's centre, a circle's centre, a hand-drawn line's start and end, a
/// text's point.
P[] keyPoints(const Annotation n)
{
    if (n.points.length == 0)
        return null;
    switch (n.kind)
    {
    case "arrow": return n.points.length >= 2 ? [n.points[1], n.points[0]] : [n.points[0]];
    case "circle": return n.points.length >= 2 ? [P((n.points[0].x + n.points[1].x) / 2, (n.points[0].y + n.points[1].y) / 2)]
        : [n.points[0]];
    case "freehand": return n.points.length >= 2 ? [n.points[0], n.points[$ - 1]] : [n.points[0]];
    default: return [n.points[0]];
    }
}

/// How far (pixels) point (x, y) is from mark `n` drawn on a w × h view
/// (0 inside a text's box, of size `textW` × `textH` pixels).
double distanceTo(const Annotation n, double x, double y, double w, double h, double textW = 0, double textH = 0)
{
    double seg(P a, P b)
    {
        immutable ax = a.x * w, ay = a.y * h, dx = b.x * w - ax, dy = b.y * h - ay, l2 = dx * dx + dy * dy;
        immutable t = l2 < 1e-9 ? 0 : max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / l2));
        return sqrt((ax + t * dx - x) ^^ 2 + (ay + t * dy - y) ^^ 2);
    }
    if (n.points.length == 0)
        return double.infinity;
    switch (n.kind)
    {
    case "circle":
        {
            if (n.points.length < 2)
                return double.infinity;
            // the distance to the ellipse, nearly: along the ray from its centre
            immutable cx = (n.points[0].x + n.points[1].x) / 2 * w, cy = (n.points[0].y + n.points[1].y) / 2 * h;
            immutable rx = max(1.0, abs(n.points[1].x - n.points[0].x) / 2 * w);
            immutable ry = max(1.0, abs(n.points[1].y - n.points[0].y) / 2 * h);
            immutable u = (x - cx) / rx, v = (y - cy) / ry, r = sqrt(u * u + v * v);
            if (r < 1e-9)
                return min(rx, ry);
            return abs(r - 1) * sqrt((x - cx) ^^ 2 + (y - cy) ^^ 2) / r;
        }
    case "text":
        {
            immutable x0 = n.points[0].x * w, y0 = n.points[0].y * h;
            immutable dx = max(0.0, max(x0 - x, x - (x0 + textW))), dy = max(0.0, max(y0 - y, y - (y0 + textH)));
            return sqrt(dx * dx + dy * dy);
        }
    case "cross":
        return max(0.0, sqrt((n.points[0].x * w - x) ^^ 2 + (n.points[0].y * h - y) ^^ 2) - crossPixels);
    default:
        if (n.points.length == 1)
            return sqrt((n.points[0].x * w - x) ^^ 2 + (n.points[0].y * h - y) ^^ 2);
        double d = double.infinity;
        foreach (k; 1 .. n.points.length)
            d = min(d, seg(n.points[k - 1], n.points[k]));
        return d;
    }
}

/// How far a cross's arms reach from its centre, in pixels.
enum crossPixels = 10.0;

/// Mark `n` moved by (dx, dy), fractions of the view; what lies under
/// it (and its model points) is to be found again.
void moveBy(ref Annotation n, double dx, double dy)
{
    foreach (ref p; n.points)
        p = P(p.x + dx, p.y + dy);
    n.under = null;
    n.at = null;
}

/// Whether a colour needs a dark halo to read (it is light) rather than a white one.
bool lightColour(uint rgb)
{
    immutable r = ((rgb >> 16) & 255) / 255.0, g = ((rgb >> 8) & 255) / 255.0, b = (rgb & 255) / 255.0;
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6;
}

/// "#RRGGBB" of a colour.
string hexOf(uint rgb) => format("#%06X", rgb & 0xFFFFFF);

/// A colour from "#RRGGBB" (or "RRGGBB") or one of colourNames; false when it is neither.
bool colourOf(string s, out uint rgb)
{
    import std.conv : to;
    import std.string : strip, toLower;
    s = s.strip;
    foreach (i, name; colourNames)
        if (s.toLower == name)
        {
            rgb = palette[i];
            return true;
        }
    if (s.length && s[0] == '#')
        s = s[1 .. $];
    if (s.length != 6)
        return false;
    try
        rgb = s.to!uint(16);
    catch (Exception)
        return false;
    return true;
}

/// Turns a point of a request that is not [fx, fy] or {"px": [x, y]} into
/// a point of the view: [x, y, z] in mm, a part's name, {"part": name,
/// "face": i}. `box` is set (and `hasBox`) to the rectangle a part covers,
/// for a circle round it. Null, or what is wrong.
alias PointReader = string delegate(JSONValue v, out P p, out P[2] box, out bool hasBox);

private double num(JSONValue v)
{
    switch (v.type)
    {
    case JSONType.integer: return v.integer;
    case JSONType.uinteger: return v.uinteger;
    case JSONType.float_: return v.floating;
    default: throw new JSONException("not a number");
    }
}

private bool isNumber(JSONValue v) => v.type == JSONType.integer || v.type == JSONType.uinteger
    || v.type == JSONType.float_;

enum pointHelp = "a point is [x, y] as fractions of the view (0..1 from the top left), {\"px\": [x, y]} in "
    ~ "pixels, [x, y, z] in mm, a part's name or {\"part\": name, \"face\": i}";

/// Reads a point of a request on a w × h view. Null, or what is wrong.
string readPoint(JSONValue v, PointReader read, double w, double h, out P p, out P[2] box, out bool hasBox)
{
    if (v.type == JSONType.array && v.array.length == 2 && isNumber(v[0]) && isNumber(v[1]))
    {
        p = P(num(v[0]), num(v[1]));
        return null;
    }
    if (v.type == JSONType.object && "px" in v)
    {
        auto q = v["px"];
        if (q.type != JSONType.array || q.array.length != 2 || !isNumber(q[0]) || !isNumber(q[1]))
            return "px is [x, y] in pixels of the view";
        p = P(num(q[0]) / w, num(q[1]) / h);
        return null;
    }
    if (read is null)
        return pointHelp;
    return read(v, p, box, hasBox);
}

/// Reads one annotation of a request, on a w × h view (its id is left
/// to the caller): {"kind": "arrow", "points": [P, Q], "colour": "red",
/// "label": "…"}, or the short forms {"arrow": [tail, tip]}, {"cross": P}, {"circle":
/// [corner, corner]}, {"circle": {"center": P, "radius": pixels}},
/// {"circle": P} (round a part when P names one), {"freehand": [P, …]},
/// {"text": "…", "at": P}. Null, or what is wrong.
string readAnnotation(JSONValue it, PointReader read, double w, double h, out Annotation n)
{
    import std.algorithm : canFind;
    if (it.type != JSONType.object)
        return "each annotation is an object: {\"arrow\": [tail, tip]}, {\"cross\": point}, {\"circle\": point}, {\"text\": \"…\", \"at\": point}…";
    JSONValue spec;
    bool given;
    if ("kind" in it && it["kind"].type == JSONType.string)
    {
        n.kind = it["kind"].str;
        if ("points" in it)
        {
            spec = it["points"];
            given = true;
        }
        else if ("at" in it)
        {
            spec = it["at"];
            given = true;
        }
        if (n.kind == "text" && "text" in it && it["text"].type == JSONType.string)
            n.text = it["text"].str;
    }
    else if ("text" in it && it["text"].type == JSONType.string)
    {
        n.kind = "text";
        n.text = it["text"].str;
        if ("at" in it)
        {
            spec = it["at"];
            given = true;
        }
    }
    else
        foreach (k; ["arrow", "cross", "circle", "freehand"])
            if (k in it)
            {
                n.kind = k;
                spec = it[k];
                given = true;
                break;
            }
    if (!kinds.canFind(n.kind))
        return "kind is arrow, cross, circle, freehand or text";
    if (!given)
        return n.kind == "text" ? "a text needs at: where it goes" : n.kind ~ " needs its points";
    if ("label" in it)
    {
        if (it["label"].type != JSONType.string)
            return "label is a text";
        if (n.kind == "text" && n.text.length == 0)
            n.text = it["label"].str;
        else if (n.kind != "text")
            n.text = it["label"].str;
    }
    string point(JSONValue v, out P p, out P[2] box, out bool hasBox) => readPoint(v, read, w, h, p, box, hasBox);
    P p;
    P[2] box;
    bool hasBox;
    final switch (n.kind)
    {
    case "arrow":
    case "freehand":
        if (spec.type != JSONType.array || spec.array.length < 2 || (n.kind == "arrow" && spec.array.length != 2))
            return n.kind == "arrow" ? "arrow is [tail, tip]" : "freehand is a list of points, two at least";
        foreach (v; spec.array)
        {
            if (auto problem = point(v, p, box, hasBox))
                return problem;
            n.points ~= p;
        }
        break;
    case "circle":
        if (spec.type == JSONType.object && "center" in spec)
        {
            if (auto problem = point(spec["center"], p, box, hasBox))
                return problem;
            immutable r = "radius" in spec && isNumber(spec["radius"]) ? num(spec["radius"]) : 28;
            if (r <= 0)
                return "radius is in pixels, more than 0";
            n.points = [P(p.x - r / w, p.y - r / h), P(p.x + r / w, p.y + r / h)];
        }
        else if (spec.type == JSONType.array && spec.array.length == 2 && !isNumber(spec[0]))
        {
            foreach (v; spec.array)
            {
                if (auto problem = point(v, p, box, hasBox))
                    return problem;
                n.points ~= p;
            }
        }
        else
        {
            // round a part: its box and a margin; else round the point
            if (auto problem = point(spec, p, box, hasBox))
                return problem;
            if (hasBox)
            {
                immutable mx = 10 / w, my = 10 / h;
                n.points = [P(box[0].x - mx, box[0].y - my), P(box[1].x + mx, box[1].y + my)];
            }
            else
                n.points = [P(p.x - 28 / w, p.y - 28 / h), P(p.x + 28 / w, p.y + 28 / h)];
        }
        break;
    case "cross":
        if (spec.type == JSONType.array && spec.array.length == 1)
            spec = spec[0];
        if (auto problem = point(spec, p, box, hasBox))
            return problem;
        n.points = [p];
        break;
    case "text":
        if (spec.type == JSONType.array && spec.array.length == 1)
            spec = spec[0];
        if (auto problem = point(spec, p, box, hasBox))
            return problem;
        n.points = [p];
        if (n.text.length == 0)
            return "a text needs its text";
        break;
    }
    foreach (key; ["colour", "color"])
        if (key in it && it[key].type != JSONType.null_)
        {
            if (it[key].type != JSONType.string || !colourOf(it[key].str, n.colour))
                return "colour is \"#RRGGBB\" or magenta, red, orange, yellow, green, blue, black, white";
        }
    if ("by" in it && it["by"].type == JSONType.string)
    {
        if (it["by"].str != "agent" && it["by"].str != "user")
            return "by is agent or user";
        n.by = it["by"].str;
    }
    if (n.kind == "arrow" && abs(n.points[1].x - n.points[0].x) + abs(n.points[1].y - n.points[0].y) < 1e-6)
        return "the arrow's tail and tip are the same point";
    return null;
}

private JSONValue pointJson(P p) => JSONValue([round(p.x * 10000) / 10000, round(p.y * 10000) / 10000]);
private JSONValue vecJson(Vec3 v) => JSONValue([round(v.x * 1000) / 1000, round(v.y * 1000) / 1000, round(v.z * 1000) / 1000]);

/// An annotation as the state lists it: id, kind, by, points (fractions of
/// the view), colour, text, and under: for each key point, what the
/// picture shows there (part, face, point in mm, normal, selector; part
/// null on the background).
JSONValue toJson(const Annotation n)
{
    JSONValue j = ["kind": n.kind, "by": n.by, "colour": hexOf(n.colour)];
    j["id"] = n.id;
    JSONValue[] ps;
    foreach (p; n.points)
        ps ~= pointJson(p);
    j["points"] = ps;
    if (n.text.length)
        j[n.kind == "text" ? "text" : "label"] = n.text;
    JSONValue[] us;
    foreach (u; n.under)
    {
        JSONValue ju = ["at": pointJson(u.at)];
        if (u.part.length == 0)
            ju["part"] = null;
        else
        {
            ju["part"] = u.part;
            ju["face"] = u.face;
            ju["point"] = vecJson(u.point);
            ju["normal"] = vecJson(u.normal);
            if (u.selector.length)
                ju["selector"] = u.selector;
        }
        us ~= ju;
    }
    j["under"] = us;
    return j;
}

/// Reads an annotation as toJson writes it.
string fromJson(JSONValue j, out Annotation n)
{
    if (auto problem = readAnnotation(j, null, 1, 1, n))
        return problem;
    if ("id" in j)
        n.id = cast(uint) num(j["id"]);
    if ("under" in j && j["under"].type == JSONType.array)
        foreach (ju; j["under"].array)
        {
            Under u;
            P[2] box;
            bool hasBox;
            if ("at" in ju)
                readPoint(ju["at"], null, 1, 1, u.at, box, hasBox);
            if ("part" in ju && ju["part"].type == JSONType.string)
            {
                u.part = ju["part"].str;
                if ("face" in ju)
                    u.face = cast(int) num(ju["face"]);
                foreach (key, ref v; ["point": &u.point, "normal": &u.normal])
                    if (key in ju && ju[key].type == JSONType.array && ju[key].array.length == 3)
                        *v = Vec3(num(ju[key][0]), num(ju[key][1]), num(ju[key][2]));
                if ("selector" in ju && ju["selector"].type == JSONType.string)
                    u.selector = ju["selector"].str;
            }
            n.under ~= u;
        }
    return null;
}

/// The annotations on the view: ids from 1, never reused.
struct AnnotationSet
{
    Annotation[] items;
    uint nextId = 1;

    /// Adds `n` with a new id; returns the id.
    uint add(Annotation n)
    {
        n.id = nextId++;
        items ~= n;
        return n.id;
    }

    /// Removes annotation `id`; false when there is none.
    bool remove(uint id)
    {
        foreach (i, n; items)
            if (n.id == id)
            {
                items = items[0 .. i] ~ items[i + 1 .. $];
                return true;
            }
        return false;
    }

    /// Removes all of them (`by` null), or all of one author's; how many went.
    size_t clear(string by = null)
    {
        immutable before = items.length;
        Annotation[] kept;
        foreach (n; items)
            if (by !is null && n.by != by)
                kept ~= n;
        items = kept;
        return before - items.length;
    }

    /// The one with id `id`, or null.
    Annotation* find(uint id)
    {
        foreach (ref n; items)
            if (n.id == id)
                return &n;
        return null;
    }

    size_t count(string by) const
    {
        size_t k;
        foreach (n; items)
            k += n.by == by;
        return k;
    }

    JSONValue toJson() const
    {
        JSONValue[] r;
        foreach (n; items)
            r ~= .toJson(n);
        return JSONValue(r);
    }
}

unittest
{
    // ids grow and are never reused; clear by author
    AnnotationSet s;
    Annotation a = {kind: "circle", points: [P(0.1, 0.1), P(0.2, 0.2)]};
    Annotation b = {kind: "arrow", by: "user", points: [P(0, 0), P(0.5, 0.5)]};
    assert(s.add(a) == 1);
    assert(s.add(b) == 2);
    assert(s.add(a) == 3);
    assert(s.remove(1));
    assert(!s.remove(1));
    assert(s.find(2).kind == "arrow");
    assert(s.count("user") == 1 && s.count("agent") == 1);
    assert(s.clear("user") == 1);
    assert(s.items.length == 1 && s.items[0].id == 3);
    assert(s.add(b) == 4);
    assert(s.clear() == 2 && s.items.length == 0);
    assert(s.add(a) == 5);
}

unittest
{
    // 2D geometry: key points, distances on a 200 × 100 picture, moving
    Annotation r = {kind: "arrow", points: [P(0, 0.5), P(1, 0.5)]};
    assert(keyPoints(r) == [P(1, 0.5), P(0, 0.5)]);
    assert(abs(distanceTo(r, 100, 60, 200, 100) - 10) < 1e-9);
    Annotation c = {kind: "circle", points: [P(0.25, 0), P(0.75, 1)]};   // centre 100, 50; radii 50, 50
    assert(keyPoints(c) == [P(0.5, 0.5)]);
    assert(abs(distanceTo(c, 160, 50, 200, 100) - 10) < 1e-9);
    assert(abs(distanceTo(c, 100, 50, 200, 100) - 50) < 1e-9);
    Annotation t = {kind: "text", points: [P(0.5, 0.5)], text: "here"};
    assert(distanceTo(t, 110, 55, 200, 100, 40, 12) == 0);
    assert(abs(distanceTo(t, 100, 40, 200, 100, 40, 12) - 10) < 1e-9);
    Annotation f = {kind: "freehand", points: [P(0, 0), P(0.5, 0), P(0.5, 1)]};
    assert(keyPoints(f) == [P(0, 0), P(0.5, 1)]);
    f.under = [Under(P(0, 0))];
    moveBy(f, 0.1, 0.2);
    assert(abs(f.points[2].x - 0.6) < 1e-12 && abs(f.points[2].y - 1.2) < 1e-12 && f.under.length == 0);
    Annotation x = {kind: "cross", points: [P(0.5, 0.5)]};
    assert(keyPoints(x) == [P(0.5, 0.5)] && distanceTo(x, 105, 50, 200, 100) == 0);
    assert(abs(distanceTo(x, 100 + crossPixels + 4, 50, 200, 100) - 4) < 1e-9);
    assert(lightColour(0xFFFFFF) && lightColour(0xF6D32D) && !lightColour(defaultColour) && !lightColour(0x1C71D8));
}

unittest
{
    // reading requests on a 200 × 100 view: fractions, pixels, points the window turns into the view.s
    string read(JSONValue v, out P p, out P[2] box, out bool hasBox)
    {
        if (v.type == JSONType.string && v.str == "clip")
        {
            p = P(0.5, 0.5);
            box = [P(0.4, 0.3), P(0.6, 0.7)];
            hasBox = true;
            return null;
        }
        if (v.type == JSONType.array && v.array.length == 3)
        {
            p = P(0.25, 0.75);
            return null;
        }
        return "no part named that";
    }
    Annotation n;
    assert(readAnnotation(parseJSON(`{"arrow": [[0.1, 0.2], {"px": [100, 50]}], "colour": "red"}`), &read, 200, 100, n) is null);
    assert(n.kind == "arrow" && n.points == [P(0.1, 0.2), P(0.5, 0.5)] && n.colour == 0xE01B24 && n.by == "agent");
    assert(readAnnotation(parseJSON(`{"arrow": [[0, 0], [10, 20, 30]], "label": "hole"}`), &read, 200, 100, n) is null);
    assert(n.points[1] == P(0.25, 0.75) && n.text == "hole");
    assert(readAnnotation(parseJSON(`{"circle": "clip"}`), &read, 200, 100, n) is null);
    assert(abs(n.points[0].x - 0.35) < 1e-12 && abs(n.points[1].y - 0.8) < 1e-12);
    assert(readAnnotation(parseJSON(`{"circle": {"center": [0.5, 0.5], "radius": 20}}`), &read, 200, 100, n) is null);
    assert(abs(n.points[0].x - 0.4) < 1e-12 && abs(n.points[1].y - 0.7) < 1e-12);
    assert(readAnnotation(parseJSON(`{"circle": [[0.1, 0.1], [0.3, 0.4]], "colour": "#123456"}`), &read, 200, 100, n) is null);
    assert(n.points == [P(0.1, 0.1), P(0.3, 0.4)] && n.colour == 0x123456);
    assert(readAnnotation(parseJSON(`{"text": "PLA", "at": [0.1, 0.9]}`), &read, 200, 100, n) is null);
    assert(n.kind == "text" && n.text == "PLA" && n.points == [P(0.1, 0.9)]);
    assert(readAnnotation(parseJSON(`{"freehand": [[0, 0], [0.1, 0.1], [0.2, 0]], "by": "user"}`), &read, 200, 100, n) is null);
    assert(n.points.length == 3 && n.by == "user");
    assert(readAnnotation(parseJSON(`{"cross": [10, 20, 30], "colour": "yellow"}`), &read, 200, 100, n) is null);
    assert(n.kind == "cross" && n.points == [P(0.25, 0.75)] && n.colour == 0xF6D32D);
    assert(readAnnotation(parseJSON(`{"kind": "cross", "points": [[0.2, 0.3]]}`), &read, 200, 100, n) is null);
    assert(n.points == [P(0.2, 0.3)]);

    assert(readAnnotation(parseJSON(`{"arrow": [[0, 0]]}`), &read, 200, 100, n) !is null);
    assert(readAnnotation(parseJSON(`{"arrow": [[0, 0], "box"]}`), &read, 200, 100, n) == "no part named that");
    assert(readAnnotation(parseJSON(`{"arrow": [[0.5, 0.5], [0.5, 0.5]]}`), &read, 200, 100, n) !is null);
    assert(readAnnotation(parseJSON(`{"kind": "blob", "points": []}`), &read, 200, 100, n) !is null);
    assert(readAnnotation(parseJSON(`{"kind": "text", "at": [0, 0]}`), &read, 200, 100, n) !is null);
    assert(readAnnotation(parseJSON(`{"circle": [0.5, 0.5], "colour": "pink"}`), &read, 200, 100, n) !is null);
}

unittest
{
    // the state's form reads back as the same annotation, with what lies under it
    AnnotationSet s;
    Annotation a = {kind: "arrow", by: "user", points: [P(0.1, 0.2), P(0.4, 0.5)], text: "hole", colour: 0x1C71D8};
    a.under = [Under(P(0.4, 0.5), "clip", 25, Vec3(1, 2, 15), Vec3(0, 0, 1), "faces.top"), Under(P(0.1, 0.2))];
    s.add(a);
    Annotation t = {kind: "text", points: [P(0.7, 0.1)], text: "too thin?"};
    s.add(t);
    auto j = parseJSON(s.toJson().toString);
    assert(j[0]["under"][0]["part"].str == "clip" && j[0]["under"][0]["face"].integer == 25);
    assert(j[0]["under"][1]["part"].type == JSONType.null_ && j[0]["label"].str == "hole" && j[1]["text"].str == "too thin?");
    foreach (k, item; j.array)
    {
        Annotation back;
        assert(fromJson(item, back) is null);
        auto orig = s.items[k];
        assert(back.id == orig.id && back.kind == orig.kind && back.by == orig.by && back.text == orig.text);
        assert(back.points == orig.points && back.colour == orig.colour && back.under.length == orig.under.length);
        foreach (i, u; back.under)
            assert(u.at == orig.under[i].at && u.part == orig.under[i].part && u.face == orig.under[i].face
                && u.point == orig.under[i].point && u.normal == orig.under[i].normal && u.selector == orig.under[i].selector);
    }
}
