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
import djson;
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
/// one could be found), or the background (part empty). On the
/// background, `near` is the surface the mark points at: the first one
/// ahead of an arrow's tip, else the nearest round the point.
struct Under
{
    P at;
    string part;
    int face = -1;
    Vec3 point, normal;
    string selector;
    Near near;
}

/// The surface nearest a point of the background (part empty: none
/// within reach), `pixels` away from it, `ahead` along an arrow.
struct Near
{
    string part;
    int face = -1;
    Vec3 point, normal;
    string selector;
    double pixels = 0;
    bool ahead;
}

/// The name of a colour of the palette, or of the one nearest it ("near red").
string colourName(uint rgb)
{
    size_t best;
    double bestD = double.infinity;
    foreach (i, c; palette)
    {
        double d = 0;
        foreach (shift; [16, 8, 0])
            d += (cast(double)((c >> shift) & 255) - ((rgb >> shift) & 255)) ^^ 2;
        if (d < bestD)
        {
            bestD = d;
            best = i;
        }
    }
    return bestD == 0 ? colourNames[best] : "near " ~ colourNames[best];
}

/// Where to look for what a mark points at when its key point `k` (of
/// keyPoints) lies on the background, on a w × h view: the direction
/// ahead in pixels (an arrow's tip: from its tail; else none) and how far
/// to look round the point (a circle's radius, else `round` pixels).
void searchFrom(const Annotation n, size_t k, double w, double h, out double dx, out double dy, out double reach,
    double round = 40)
{
    dx = dy = 0;
    reach = round;
    if (n.kind == "arrow" && k == 0 && n.points.length >= 2)
    {
        dx = (n.points[1].x - n.points[0].x) * w;
        dy = (n.points[1].y - n.points[0].y) * h;
        immutable l = sqrt(dx * dx + dy * dy);
        if (l > 0)
        {
            dx /= l;
            dy /= l;
        }
    }
    else if (n.kind == "circle" && n.points.length >= 2)
        reach = max(abs(n.points[1].x - n.points[0].x) * w, abs(n.points[1].y - n.points[0].y) * h) / 2 + 10;
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
alias PointReader = string delegate(JValue v, out P p, out P[2] box, out bool hasBox);

private double num(JValue v)
{
    if (!v.isNumber)
        throw new JSONException("not a number");
    return v.get!double;
}

private bool isNumber(JValue v) => v.isNumber;

enum pointHelp = "a point is [x, y] as fractions of the view (0..1 from the top left), {\"px\": [x, y]} in "
    ~ "pixels, [x, y, z] in mm, a part's name or {\"part\": name, \"face\": i}";

/// Reads a point of a request on a w × h view. Null, or what is wrong.
string readPoint(JValue v, PointReader read, double w, double h, out P p, out P[2] box, out bool hasBox)
{
    if (v.isArray && v.length == 2 && isNumber(v[0]) && isNumber(v[1]))
    {
        p = P(num(v[0]), num(v[1]));
        return null;
    }
    if (v.isObject && v.has("px"))
    {
        auto q = v["px"];
        if (!q.isArray || q.length != 2 || !isNumber(q[0]) || !isNumber(q[1]))
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
string readAnnotation(JValue it, PointReader read, double w, double h, out Annotation n)
{
    import std.algorithm : canFind;
    if (!it.isObject)
        return "each annotation is an object: {\"arrow\": [tail, tip]}, {\"cross\": point}, {\"circle\": point}, {\"text\": \"…\", \"at\": point}…";
    JValue spec;
    bool given;
    if (it.has("kind") && it["kind"].isString)
    {
        n.kind = it["kind"].get!string;
        if (it.has("points"))
        {
            spec = it["points"];
            given = true;
        }
        else if (it.has("at"))
        {
            spec = it["at"];
            given = true;
        }
        if (n.kind == "text" && it.has("text") && it["text"].isString)
            n.text = it["text"].get!string;
    }
    else if (it.has("text") && it["text"].isString)
    {
        n.kind = "text";
        n.text = it["text"].get!string;
        if (it.has("at"))
        {
            spec = it["at"];
            given = true;
        }
    }
    else
        foreach (k; ["arrow", "cross", "circle", "freehand"])
            if (it.has(k))
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
    if (it.has("label"))
    {
        if (!it["label"].isString)
            return "label is a text";
        if (n.kind == "text" && n.text.length == 0)
            n.text = it["label"].get!string;
        else if (n.kind != "text")
            n.text = it["label"].get!string;
    }
    string point(JValue v, out P p, out P[2] box, out bool hasBox) => readPoint(v, read, w, h, p, box, hasBox);
    P p;
    P[2] box;
    bool hasBox;
    final switch (n.kind)
    {
    case "arrow":
    case "freehand":
        if (!spec.isArray || spec.length < 2 || (n.kind == "arrow" && spec.length != 2))
            return n.kind == "arrow" ? "arrow is [tail, tip]" : "freehand is a list of points, two at least";
        foreach (v; spec)
        {
            if (auto problem = point(v, p, box, hasBox))
                return problem;
            n.points ~= p;
        }
        break;
    case "circle":
        if (spec.isObject && spec.has("center"))
        {
            if (auto problem = point(spec["center"], p, box, hasBox))
                return problem;
            immutable r = spec.has("radius") && isNumber(spec["radius"]) ? num(spec["radius"]) : 28;
            if (r <= 0)
                return "radius is in pixels, more than 0";
            n.points = [P(p.x - r / w, p.y - r / h), P(p.x + r / w, p.y + r / h)];
        }
        else if (spec.isArray && spec.length == 2 && !isNumber(spec[0]))
        {
            foreach (v; spec)
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
        if (spec.isArray && spec.length == 1)
            spec = spec[0];
        if (auto problem = point(spec, p, box, hasBox))
            return problem;
        n.points = [p];
        break;
    case "text":
        if (spec.isArray && spec.length == 1)
            spec = spec[0];
        if (auto problem = point(spec, p, box, hasBox))
            return problem;
        n.points = [p];
        if (n.text.length == 0)
            return "a text needs its text";
        break;
    }
    foreach (key; ["colour", "color"])
        if (it.has(key) && !it[key].isNull)
        {
            if (!it[key].isString || !colourOf(it[key].get!string, n.colour))
                return "colour is \"#RRGGBB\" or magenta, red, orange, yellow, green, blue, black, white";
        }
    if (it.has("by") && it["by"].isString)
    {
        if (it["by"].get!string != "agent" && it["by"].get!string != "user")
            return "by is agent or user";
        n.by = it["by"].get!string;
    }
    if (n.kind == "arrow" && abs(n.points[1].x - n.points[0].x) + abs(n.points[1].y - n.points[0].y) < 1e-6)
        return "the arrow's tail and tip are the same point";
    return null;
}

private JValue pointJson(P p) => toJSON([round(p.x * 10000) / 10000, round(p.y * 10000) / 10000]);
private JValue vecJson(Vec3 v) => toJSON([round(v.x * 1000) / 1000, round(v.y * 1000) / 1000, round(v.z * 1000) / 1000]);

/// An annotation as the state lists it: id, kind, by, points (fractions of
/// the view), colour, text, and under: for each key point, what the
/// picture shows there (part, face, point in mm, normal, selector; part
/// null on the background).
JValue toJson(const Annotation n)
{
    JValue j = JSOB("kind", n.kind, "by", n.by, "colour", hexOf(n.colour), "colour_name", colourName(n.colour));
    j["id"] = n.id;
    JValue ps = JSAB();
    foreach (p; n.points)
        ps ~= pointJson(p);
    j["points"] = ps;
    if (n.text.length)
        j[n.kind == "text" ? "text" : "label"] = n.text;
    JValue us = JSAB();
    foreach (u; n.under)
    {
        JValue ju = JSOB("at", pointJson(u.at));
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
        if (u.part.length == 0 && u.near.part.length)
        {
            JValue jn = JSOB("part", u.near.part);
            jn["face"] = u.near.face;
            jn["point"] = vecJson(u.near.point);
            jn["normal"] = vecJson(u.near.normal);
            if (u.near.selector.length)
                jn["selector"] = u.near.selector;
            jn["pixels"] = round(u.near.pixels);
            jn["how"] = u.near.ahead ? "ahead of the arrow" : "round the point";
            ju["points_at"] = jn;
        }
        us ~= ju;
    }
    j["under"] = us;
    return j;
}

/// Reads an annotation as toJson writes it.
string fromJson(JValue j, out Annotation n)
{
    if (auto problem = readAnnotation(j, null, 1, 1, n))
        return problem;
    if (j.has("id"))
        n.id = cast(uint) num(j["id"]);
    if (j.has("under") && j["under"].isArray)
        foreach (ju; j["under"])
        {
            Under u;
            P[2] box;
            bool hasBox;
            if (ju.has("at"))
                readPoint(ju["at"], null, 1, 1, u.at, box, hasBox);
            if (ju.has("part") && ju["part"].isString)
            {
                u.part = ju["part"].get!string;
                if (ju.has("face"))
                    u.face = cast(int) num(ju["face"]);
                foreach (key, ref v; ["point": &u.point, "normal": &u.normal])
                    if (ju.has(key) && ju[key].isArray && ju[key].length == 3)
                        *v = Vec3(num(ju[key][0]), num(ju[key][1]), num(ju[key][2]));
                if (ju.has("selector") && ju["selector"].isString)
                    u.selector = ju["selector"].get!string;
            }
            if (auto jn = ju.getPtr("points_at"))
                if (jn.isObject && jn.has("part") && (*jn)["part"].isString)
                {
                    u.near.part = (*jn)["part"].get!string;
                    if (jn.has("face"))
                        u.near.face = cast(int) num((*jn)["face"]);
                    foreach (key, ref v; ["point": &u.near.point, "normal": &u.near.normal])
                        if (jn.has(key) && (*jn)[key].isArray && (*jn)[key].length == 3)
                            *v = Vec3(num((*jn)[key][0]), num((*jn)[key][1]), num((*jn)[key][2]));
                    if (jn.has("selector") && (*jn)["selector"].isString)
                        u.near.selector = (*jn)["selector"].get!string;
                    if (jn.has("pixels"))
                        u.near.pixels = num((*jn)["pixels"]);
                    u.near.ahead = jn.has("how") && (*jn)["how"].isString
                        && (*jn)["how"].get!string == "ahead of the arrow";
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

    JValue toJson() const
    {
        JValue r = JSAB();
        foreach (n; items)
            r ~= .toJson(n);
        return r;
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
    string read(JValue v, out P p, out P[2] box, out bool hasBox)
    {
        if (v.isString && v.get!string == "clip")
        {
            p = P(0.5, 0.5);
            box = [P(0.4, 0.3), P(0.6, 0.7)];
            hasBox = true;
            return null;
        }
        if (v.isArray && v.length == 3)
        {
            p = P(0.25, 0.75);
            return null;
        }
        return "no part named that";
    }
    Annotation n;
    assert(readAnnotation(parseJSONComplete(`{"arrow": [[0.1, 0.2], {"px": [100, 50]}], "colour": "red"}`), &read, 200, 100, n) is null);
    assert(n.kind == "arrow" && n.points == [P(0.1, 0.2), P(0.5, 0.5)] && n.colour == 0xE01B24 && n.by == "agent");
    assert(readAnnotation(parseJSONComplete(`{"arrow": [[0, 0], [10, 20, 30]], "label": "hole"}`), &read, 200, 100, n) is null);
    assert(n.points[1] == P(0.25, 0.75) && n.text == "hole");
    assert(readAnnotation(parseJSONComplete(`{"circle": "clip"}`), &read, 200, 100, n) is null);
    assert(abs(n.points[0].x - 0.35) < 1e-12 && abs(n.points[1].y - 0.8) < 1e-12);
    assert(readAnnotation(parseJSONComplete(`{"circle": {"center": [0.5, 0.5], "radius": 20}}`), &read, 200, 100, n) is null);
    assert(abs(n.points[0].x - 0.4) < 1e-12 && abs(n.points[1].y - 0.7) < 1e-12);
    assert(readAnnotation(parseJSONComplete(`{"circle": [[0.1, 0.1], [0.3, 0.4]], "colour": "#123456"}`), &read, 200, 100, n) is null);
    assert(n.points == [P(0.1, 0.1), P(0.3, 0.4)] && n.colour == 0x123456);
    assert(readAnnotation(parseJSONComplete(`{"text": "PLA", "at": [0.1, 0.9]}`), &read, 200, 100, n) is null);
    assert(n.kind == "text" && n.text == "PLA" && n.points == [P(0.1, 0.9)]);
    assert(readAnnotation(parseJSONComplete(`{"freehand": [[0, 0], [0.1, 0.1], [0.2, 0]], "by": "user"}`), &read, 200, 100, n) is null);
    assert(n.points.length == 3 && n.by == "user");
    assert(readAnnotation(parseJSONComplete(`{"cross": [10, 20, 30], "colour": "yellow"}`), &read, 200, 100, n) is null);
    assert(n.kind == "cross" && n.points == [P(0.25, 0.75)] && n.colour == 0xF6D32D);
    assert(readAnnotation(parseJSONComplete(`{"kind": "cross", "points": [[0.2, 0.3]]}`), &read, 200, 100, n) is null);
    assert(n.points == [P(0.2, 0.3)]);

    assert(readAnnotation(parseJSONComplete(`{"arrow": [[0, 0]]}`), &read, 200, 100, n) !is null);
    assert(readAnnotation(parseJSONComplete(`{"arrow": [[0, 0], "box"]}`), &read, 200, 100, n) == "no part named that");
    assert(readAnnotation(parseJSONComplete(`{"arrow": [[0.5, 0.5], [0.5, 0.5]]}`), &read, 200, 100, n) !is null);
    assert(readAnnotation(parseJSONComplete(`{"kind": "blob", "points": []}`), &read, 200, 100, n) !is null);
    assert(readAnnotation(parseJSONComplete(`{"kind": "text", "at": [0, 0]}`), &read, 200, 100, n) !is null);
    assert(readAnnotation(parseJSONComplete(`{"circle": [0.5, 0.5], "colour": "pink"}`), &read, 200, 100, n) !is null);
}

unittest
{
    // the state's form reads back as the same annotation, with what lies under it
    AnnotationSet s;
    Annotation a = {kind: "arrow", by: "user", points: [P(0.1, 0.2), P(0.4, 0.5)], text: "hole", colour: 0x1C71D8};
    a.under = [Under(P(0.4, 0.5), "clip", 25, Vec3(1, 2, 15), Vec3(0, 0, 1), "faces.top"), Under(P(0.1, 0.2))];
    a.under[1].near = Near("clip", 3, Vec3(0, 1, 2), Vec3(1, 0, 0), "faces.left", 12, true);
    s.add(a);
    Annotation t = {kind: "text", points: [P(0.7, 0.1)], text: "too thin?"};
    s.add(t);
    auto j = parseJSONComplete(s.toJson().toString);
    assert(j[0]["under"][0]["part"].get!string == "clip" && j[0]["under"][0]["face"].get!long == 25);
    assert(j[0]["under"][1]["part"].isNull && j[0]["label"].get!string == "hole" && j[1]["text"].get!string == "too thin?");
    // a point on the background says what the mark points at; the colour has its name
    assert(j[0]["under"][1]["points_at"]["part"].get!string == "clip" && j[0]["under"][1]["points_at"]["how"].get!string == "ahead of the arrow");
    assert(j[0]["colour_name"].get!string == "blue" && j[1]["colour_name"].get!string == "magenta" && colourName(0xE01B25) == "near red");
    foreach (size_t k, item; j)
    {
        Annotation back;
        assert(fromJson(item, back) is null);
        auto orig = s.items[k];
        assert(back.id == orig.id && back.kind == orig.kind && back.by == orig.by && back.text == orig.text);
        assert(back.points == orig.points && back.colour == orig.colour && back.under.length == orig.under.length);
        foreach (i, u; back.under)
            assert(u.at == orig.under[i].at && u.part == orig.under[i].part && u.face == orig.under[i].face
                && u.point == orig.under[i].point && u.normal == orig.under[i].normal && u.selector == orig.under[i].selector
                && u.near == orig.under[i].near);
    }
    // where to look: ahead of an arrow's tip, from its tail; round a circle as far as its radius
    double dx, dy, reach;
    searchFrom(a, 0, 100, 100, dx, dy, reach);
    assert(abs(dx - sqrt(0.5)) < 1e-9 && abs(dy - sqrt(0.5)) < 1e-9 && reach == 40);
    searchFrom(a, 1, 100, 100, dx, dy, reach);
    assert(dx == 0 && dy == 0);
    Annotation c = {kind: "circle", points: [P(0.1, 0.1), P(0.5, 0.3)]};
    searchFrom(c, 0, 100, 100, dx, dy, reach);
    assert(dx == 0 && reach == 30);
}
