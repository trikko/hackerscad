/// Drawing composition: projected views of solids (hidden lines dashed),
/// sections with hatching, dimensions, notes and the title block, laid out
/// on a sheet.
module hackerscad.drawing.layout;

import std.algorithm : min, max, maxElement, minElement, sort, canFind;
import std.range : walkLength;
import std.array : array;
import std.format : format;
import std.math : abs, sqrt, floor, PI, isNaN, cos, sin;

import hackerscad.drawing.sheet;
import hackerscad.geom.vec;
import hackerscad.kernel.brep;

/// Standard view directions: from the model towards the viewer, and up.
struct Direction
{
    Vec3 dir, up;
}

Direction directionOf(string name)
{
    switch (name)
    {
    case "front": return Direction(Vec3(0, -1, 0), Vec3(0, 0, 1));
    case "back": return Direction(Vec3(0, 1, 0), Vec3(0, 0, 1));
    case "top": return Direction(Vec3(0, 0, 1), Vec3(0, 1, 0));
    case "bottom": return Direction(Vec3(0, 0, -1), Vec3(0, -1, 0));
    case "right": return Direction(Vec3(1, 0, 0), Vec3(0, 0, 1));
    case "left": return Direction(Vec3(-1, 0, 0), Vec3(0, 0, 1));
    case "iso": return Direction(Vec3(1, -1, 1).normalized, Vec3(0, 0, 1));
    default: throw new Exception(format("unknown view '%s' (front, back, top, bottom, right, left, iso)", name));
    }
}

immutable string[] viewNames = ["front", "back", "top", "bottom", "right", "left", "iso"];

/// A view of a solid, placed on the sheet.
struct View
{
    Brep solid;
    string name;          /// "front", … or "section A-A"
    Direction direction;
    double scale = 1;     /// paper mm per model mm
    double x = 0, y = 0;  /// centre on the sheet
    bool autoPlaced;      /// placed by the layout
    bool dimensions = true;
    // a section: the plane, and the solid already cut
    bool isSection;
    Vec3 planeOrigin, planeNormal;
    string label;

    // computed
    ViewSegment[] segments;
    double minX = 0, minY = 0, maxX = 0, maxY = 0;   /// model units, view coordinates
    Vec3[][] hatchLoops;   /// section faces, model coordinates

    Vec3 xAxis() const => direction.up.cross(direction.dir).normalized;
    Vec3 yAxis() const => direction.dir.cross(xAxis).normalized;

    /// View coordinates (model units) of a model point.
    double[2] project(Vec3 p) const => [p.dot(xAxis), p.dot(yAxis)];

    /// Sheet coordinates of view coordinates.
    double[2] toSheet(double u, double v) const =>
        [x + (u - (minX + maxX) / 2) * scale, y + (v - (minY + maxY) / 2) * scale];

    double width() const => (maxX - minX) * scale;
    double height() const => (maxY - minY) * scale;
}

struct Dimension
{
    size_t view;
    Vec3 from, to;        /// model points
    double offset = 8;    /// paper mm from the measured points; the side follows the sign
    string text;          /// default: the measured length
}

struct Note
{
    string text;
    double x, y, size = 3.5;
}

/// What to draw; `render` turns it into a Sheet.
struct Drawing
{
    string size = "A4";
    bool landscape = true;
    string title, author, material, file;
    string projection = "first";   /// ISO "first" angle (Europe) or "third" (America)
    double scale = 0;              /// 0: the largest standard scale that fits
    View[] views;
    Dimension[] dims;
    Note[] notes;
}

double[2] sheetSize(string size, bool landscape)
{
    double[2] s;
    switch (size)
    {
    case "A4": s = [297, 210]; break;
    case "A3": s = [420, 297]; break;
    case "A2": s = [594, 420]; break;
    case "A1": s = [841, 594]; break;
    case "Letter": s = [279.4, 215.9]; break;
    default: throw new Exception(format("unknown sheet size '%s' (A4, A3, A2, A1, Letter)", size));
    }
    return landscape ? s : [s[1], s[0]];
}

/// Preferred scales, largest first (ISO 5455).
immutable double[] standardScales = [10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01];

string scaleText(double s)
{
    if (s >= 1)
        return format("%g:1", s);
    return format("1:%g", 1 / s);
}

Sheet render(ref Drawing d, BrepKernel k)
{
    Sheet sh;
    auto size = sheetSize(d.size, d.landscape);
    sh.width = size[0];
    sh.height = size[1];
    enum margin = 10.0, titleH = 28.0;

    // project every view (model units)
    foreach (ref v; d.views)
        project(v, k);

    // the drawing area, above the title block
    immutable areaX = margin + 5, areaY = margin + titleH + 5;
    immutable areaW = sh.width - 2 * margin - 10, areaH = sh.height - 2 * margin - titleH - 10;
    layout(d, areaX, areaY, areaW, areaH);

    // frame and title block
    sh.rect(margin, margin, sh.width - 2 * margin, sh.height - 2 * margin);
    titleBlock(sh, d, margin);

    foreach (i, ref v; d.views)
        drawView(sh, v, k);
    foreach (dim; d.dims)
        if (dim.view < d.views.length)
            drawDimension(sh, d.views[dim.view], dim);
    foreach (n; d.notes)
        sh.text(n.x, n.y, n.text, n.size);
    return sh;
}

private:

void project(ref View v, BrepKernel k)
{
    auto solid = v.solid;
    v.segments = k.hiddenLines(solid, v.direction.dir, v.direction.up, 0.05);
    bool any;
    void grow(double u, double w)
    {
        if (!any)
        {
            v.minX = v.maxX = u;
            v.minY = v.maxY = w;
            any = true;
            return;
        }
        v.minX = min(v.minX, u);
        v.maxX = max(v.maxX, u);
        v.minY = min(v.minY, w);
        v.maxY = max(v.maxY, w);
    }

    foreach (g; v.segments)
    {
        grow(g.x1, g.y1);
        grow(g.x2, g.y2);
    }
    // a drawing can be rendered again (a second export): start afresh, or
    // the loops would double and the even-odd hatching cancel out
    v.hatchLoops = null;
    if (v.isSection)
    {
        // faces lying on the cutting plane, facing the viewer, are hatched
        foreach (i, f; k.faces(solid))
            if (abs((f.center - v.planeOrigin).dot(v.planeNormal)) < 1e-6 && f.normal.dot(v.planeNormal) > 0.999)
                foreach (loop; k.faceLoops(solid, cast(int) i, 0.05))
                    v.hatchLoops ~= loop;
    }
}

/// Places the views not placed by hand: the first view in the middle of the
/// left part, the others around it by projection rules, iso views on the right.
void layout(ref Drawing d, double ax, double ay, double aw, double ah)
{
    // the scale: the largest standard one at which the auto views fit
    View* front;
    foreach (ref v; d.views)
        if (v.autoPlaced && front is null && v.name != "iso" && !v.isSection)
            front = &v;
    if (front is null)
        return;
    double wFront = front.maxX - front.minX, hFront = front.maxY - front.minY;
    double side = 0, below = 0, iso = 0, isoH = 0, sections = 0;
    foreach (ref v; d.views)
    {
        if (!v.autoPlaced || &v is front)
            continue;
        if (v.name == "top" || v.name == "bottom")
            below = max(below, v.maxY - v.minY);
        else if (v.name == "iso")
        {
            iso = max(iso, v.maxX - v.minX);
            isoH = max(isoH, v.maxY - v.minY);
        }
        else if (v.isSection)
            sections += v.maxY - v.minY;           // stacked under the top view
        else
            side = max(side, v.maxX - v.minX);
    }
    enum gap = 22.0;   // paper mm between views (room for dimensions)
    double scale = d.scale;
    if (scale <= 0)
    {
        scale = standardScales[$ - 1];
        foreach (s; standardScales)
        {
            // the iso view goes in the free top-right corner and shrinks to fit there
            immutable w = (wFront + side) * s + gap * (2 + (side > 0));
            immutable h = (hFront + below + sections) * s + gap * (1 + (below > 0)) + gap * (sections > 0 ? 1 : 0)
                + (sections > 0 ? 8 : 0);
            if (w <= aw && h <= ah)
            {
                scale = s;
                break;
            }
        }
        d.scale = scale;
    }
    // room left for the iso view: right of the front column, above the title block
    immutable usedW = (wFront + side) * scale + gap * (2 + (side > 0));
    immutable isoScale = iso > 0 ? min(scale * 0.8, max(0.0, aw - usedW - 5) / iso, ah * 0.5 / max(isoH, 1e-9)) : scale;
    foreach (ref v; d.views)
        if (v.autoPlaced)
            v.scale = v.name == "iso" ? isoScale : scale;

    // first angle: the top view goes below the front, the view from the
    // right on the left; third angle the other way round
    immutable first = d.projection != "third";
    immutable col = ax + gap + (first ? side * scale + gap : 0) + wFront * scale / 2;
    immutable row = ay + ah - gap / 2 - hFront * scale / 2;
    front.x = col;
    front.y = row;
    double sectionTop = row - hFront * scale / 2 - gap - (below > 0 && first ? below * scale + gap : 0);
    foreach (ref v; d.views)
    {
        if (!v.autoPlaced || &v is front)
            continue;
        immutable w = v.width, h = v.height;
        switch (v.name)
        {
        case "top":
            v.x = col;
            v.y = first ? row - hFront * scale / 2 - gap - h / 2 : row + hFront * scale / 2 + gap + h / 2;
            break;
        case "bottom":
            v.x = col;
            v.y = first ? row + hFront * scale / 2 + gap + h / 2 : row - hFront * scale / 2 - gap - h / 2;
            break;
        case "right":
            v.y = row;
            v.x = first ? col - wFront * scale / 2 - gap - w / 2 : col + wFront * scale / 2 + gap + w / 2;
            break;
        case "left":
            v.y = row;
            v.x = first ? col + wFront * scale / 2 + gap + w / 2 : col - wFront * scale / 2 - gap - w / 2;
            break;
        case "iso":
            v.x = ax + aw - w / 2 - 5;
            v.y = ay + ah - h / 2 - 5;
            break;
        default:
            // sections: one under the other, below the lowest view of the front column
            v.x = col;
            v.y = sectionTop - h / 2;
            sectionTop -= h + gap;
        }
    }
}

void drawView(ref Sheet sh, ref View v, BrepKernel k)
{
    foreach (g; v.segments)
    {
        auto a = v.toSheet(g.x1, g.y1), b = v.toSheet(g.x2, g.y2);
        final switch (g.kind)
        {
        case ViewSegment.Kind.edge, ViewSegment.Kind.outline:
            sh.line(a[0], a[1], b[0], b[1], Pen.visible);
            break;
        case ViewSegment.Kind.tangent:
            if (v.name == "iso")
                sh.line(a[0], a[1], b[0], b[1], Pen.thin);
            break;
        case ViewSegment.Kind.hidden:
            if (v.name != "iso" && !v.isSection)
                sh.line(a[0], a[1], b[0], b[1], Pen.hidden);
            break;
        }
    }
    if (v.hatchLoops.length)
        hatch(sh, v);

    // label under the view
    immutable labelY = v.y - v.height / 2 - (v.dimensions && v.name != "iso" ? 16 : 6);
    string label = v.isSection ? "Section " ~ v.label ~ "-" ~ v.label : v.name == "iso" ? "" : "";
    if (label.length || v.scale != 0)
        if (label.length)
            sh.text(v.x, labelY, label, 3.5, Anchor.middle);

    if (!v.dimensions || v.name == "iso")
        return;
    // overall dimensions: width below, height on the left
    Dimension w, h;
    auto lo = v.toSheet(v.minX, v.minY), hi = v.toSheet(v.maxX, v.maxY);
    linearOnSheet(sh, lo[0], lo[1], hi[0], lo[1], -8, measure(v.maxX - v.minX), true);
    linearOnSheet(sh, lo[0], lo[1], lo[0], hi[1], -8, measure(v.maxY - v.minY), false);
    // holes seen end-on: one callout per diameter, with the count
    holeCallouts(sh, v, k);
}

double round2(double x) => floor(x * 100 + 0.5) / 100;

/// A measured length as written on the drawing: tenths of a millimetre.
string measure(double x) => format("%g", floor(x * 10 + 0.5) / 10);

void holeCallouts(ref Sheet sh, ref View v, BrepKernel k)
{
    // the full circles seen end-on, grouped by the line they lie on: one hole each, with its
    // circles at every depth (a counterbore's two diameters, a countersink's rim)
    struct Circle
    {
        Vec3 center;
        double radius;
    }

    struct Hole
    {
        Vec3 center;
        Circle[] circles;
    }

    immutable dir = v.direction.dir;
    Hole[] holes;
    foreach (e; k.edges(v.solid))
    {
        if (e.kind != EdgeKind.circle || abs(abs(e.axis.dot(dir)) - 1) > 1e-6)
            continue;
        if ((e.end - e.start).length > 1e-6)
            continue;   // only full circles
        bool placed;
        foreach (ref h; holes)
        {
            auto d = e.center - h.center;
            if ((d - dir * d.dot(dir)).length < 1e-6)
            {
                h.circles ~= Circle(e.center, e.radius);
                placed = true;
                break;
            }
        }
        if (!placed)
            holes ~= Hole(e.center, [Circle(e.center, e.radius)]);
    }
    // a circle round empty space, both sides of it along the axis just inside the rim: a hole's
    // (a boss's top or a round part's outline have material on one side)
    auto side = dir.cross(abs(dir.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)).normalized;
    bool aroundVoid(Circle c)
    {
        immutable inward = c.radius - min(0.01, c.radius / 4), along = 0.01;
        auto p = c.center + side * inward;
        return !k.inside(v.solid, p + dir * along) && !k.inside(v.solid, p - dir * along);
    }
    size_t[string] counts;
    Vec3[string] where;
    double[string] rim;
    foreach (h; holes)
    {
        Circle[] open;
        foreach (c; h.circles)
            if (2 * c.radius < min(v.maxX - v.minX, v.maxY - v.minY) - 1e-6 && aroundVoid(c))
                open ~= c;
        if (open.length == 0)
            continue;
        double small = double.infinity, large = 0;
        foreach (c; open)
        {
            small = min(small, c.radius);
            large = max(large, c.radius);
        }
        string text = format("⌀%g", round2(2 * small));
        if (large > small + 1e-6)
        {
            // the wider part: a cylinder (its rim at two depths) is a counterbore, a cone a countersink
            double[] depths;
            foreach (c; h.circles)
                if (abs(c.radius - large) < 1e-6)
                    depths ~= c.center.dot(dir);
            if (depths.length >= 2)
                text ~= format(", counterbore ⌀%g × %s", round2(2 * large), measure(depths.maxElement - depths.minElement));
            else
                text ~= format(", countersink ⌀%g", round2(2 * large));
        }
        counts[text]++;
        if (text !in where)
        {
            where[text] = h.center;
            rim[text] = large;
        }
    }
    auto keys = counts.keys;
    keys.sort;
    foreach (i, key; keys)
    {
        auto c = v.project(where[key]);
        auto p = v.toSheet(c[0], c[1]);
        immutable r = rim[key] * v.scale;
        // centre mark
        sh.line(p[0] - r - 1.5, p[1], p[0] + r + 1.5, p[1], Pen.center);
        sh.line(p[0], p[1] - r - 1.5, p[0], p[1] + r + 1.5, Pen.center);
        // leader towards the upper right, outside the view
        immutable ang = PI / 4;
        immutable sx = p[0] + r * cos(ang), sy = p[1] + r * sin(ang);
        immutable ex = max(sx + 6, v.x + v.width / 2 + 4 + i * 2), ey = max(sy + 6, v.y + v.height / 2 + 4 + i * 6);
        sh.line(ex, ey, sx, sy, Pen.thin);
        sh.arrow(sx, sy, sx - ex, sy - ey, 2.5);
        auto text = (counts[key] > 1 ? format("%d× ", counts[key]) : "") ~ key;
        sh.line(ex, ey, ex + text.walkLength * 1.6, ey, Pen.thin);
        sh.text(ex + 0.5, ey + 1, text, 2.5);
    }
}

void drawDimension(ref Sheet sh, ref View v, Dimension d)
{
    auto a = v.project(d.from), b = v.project(d.to);
    auto pa = v.toSheet(a[0], a[1]), pb = v.toSheet(b[0], b[1]);
    immutable dx = b[0] - a[0], dy = b[1] - a[1];
    string text = d.text.length ? d.text : measure(sqrt(dx * dx + dy * dy));
    // horizontal, vertical or aligned
    if (abs(dy) < 1e-9)
        linearOnSheet(sh, pa[0], pa[1], pb[0], pb[1], d.offset, text, true);
    else if (abs(dx) < 1e-9)
        linearOnSheet(sh, pa[0], pa[1], pb[0], pb[1], d.offset, text, false);
    else
        alignedOnSheet(sh, pa[0], pa[1], pb[0], pb[1], d.offset, text);
}

/// A horizontal (or vertical) dimension between two sheet points, `offset`
/// paper mm below (left of) them when negative, above (right of) when positive.
void linearOnSheet(ref Sheet sh, double x1, double y1, double x2, double y2, double offset, string text, bool horizontal)
{
    if (horizontal)
    {
        immutable y = (offset < 0 ? min(y1, y2) : max(y1, y2)) + offset;
        immutable ext = offset < 0 ? -1.5 : 1.5;
        sh.line(x1, y1 + (offset < 0 ? -1 : 1), x1, y + ext, Pen.thin);
        sh.line(x2, y2 + (offset < 0 ? -1 : 1), x2, y + ext, Pen.thin);
        sh.line(x1, y, x2, y, Pen.thin);
        sh.arrow(x1, y, x1 - x2, 0);
        sh.arrow(x2, y, x2 - x1, 0);
        sh.text((x1 + x2) / 2, y + 1, text, 3.5, Anchor.middle);
    }
    else
    {
        immutable x = (offset < 0 ? min(x1, x2) : max(x1, x2)) + offset;
        immutable ext = offset < 0 ? -1.5 : 1.5;
        sh.line(x1 + (offset < 0 ? -1 : 1), y1, x + ext, y1, Pen.thin);
        sh.line(x2 + (offset < 0 ? -1 : 1), y2, x + ext, y2, Pen.thin);
        sh.line(x, y1, x, y2, Pen.thin);
        sh.arrow(x, y1, 0, y1 - y2);
        sh.arrow(x, y2, 0, y2 - y1);
        sh.text(x - 1, (y1 + y2) / 2, text, 3.5, Anchor.middle, 90);
    }
}

void alignedOnSheet(ref Sheet sh, double x1, double y1, double x2, double y2, double offset, string text)
{
    import std.math : atan2;
    immutable l = sqrt((x2 - x1) ^^ 2 + (y2 - y1) ^^ 2);
    immutable nx = -(y2 - y1) / l * offset, ny = (x2 - x1) / l * offset;
    sh.line(x1, y1, x1 + nx, y1 + ny, Pen.thin);
    sh.line(x2, y2, x2 + nx, y2 + ny, Pen.thin);
    sh.line(x1 + nx, y1 + ny, x2 + nx, y2 + ny, Pen.thin);
    sh.arrow(x1 + nx, y1 + ny, x1 - x2, y1 - y2);
    sh.arrow(x2 + nx, y2 + ny, x2 - x1, y2 - y1);
    double ang = atan2(y2 - y1, x2 - x1) * 180 / PI;
    if (ang > 90 || ang < -90)
        ang += 180;
    sh.text((x1 + x2) / 2 + nx * 1.15, (y1 + y2) / 2 + ny * 1.15, text, 3.5, Anchor.middle, ang);
}

/// 45° hatching of the section faces (even-odd fill of their loops).
void hatch(ref Sheet sh, ref View v)
{
    double[2][][] polys;
    double lo = double.infinity, hi = -double.infinity;
    foreach (loop; v.hatchLoops)
    {
        double[2][] p;
        foreach (q; loop)
        {
            auto c = v.project(q);
            auto s = v.toSheet(c[0], c[1]);
            p ~= s;
            // hatch lines are x - y = t
            lo = min(lo, s[0] - s[1]);
            hi = max(hi, s[0] - s[1]);
        }
        polys ~= p;
    }
    enum spacing = 2.0;
    for (double t = floor(lo / spacing) * spacing + spacing / 2; t < hi; t += spacing)
    {
        // points of the line (s + t, s) where it crosses the polygon edges
        double[] cuts;
        foreach (p; polys)
            foreach (i; 0 .. p.length)
            {
                auto a = p[i], b = p[(i + 1) % p.length];
                immutable fa = a[0] - a[1] - t, fb = b[0] - b[1] - t;
                if ((fa < 0) == (fb < 0))
                    continue;
                immutable u = fa / (fa - fb);
                cuts ~= a[1] + (b[1] - a[1]) * u;   // the y of the crossing
            }
        cuts.sort;
        for (size_t i = 0; i + 1 < cuts.length; i += 2)
            sh.line(cuts[i] + t, cuts[i], cuts[i + 1] + t, cuts[i + 1], Pen.thin);
    }
}

void titleBlock(ref Sheet sh, ref Drawing d, double margin)
{
    immutable w = 180.0, h = 28.0;
    immutable x = sh.width - margin - w, y = margin;
    sh.rect(x, y, w, h);
    sh.line(x, y + 14, x + w, y + 14, Pen.thin);
    sh.line(x + 120, y, x + 120, y + 14, Pen.thin);
    sh.line(x + 150, y, x + 150, y + 14, Pen.thin);
    sh.text(x + 3, y + 18, d.title.length ? d.title : "Untitled", 6);
    sh.text(x + 3, y + 9, d.material.length ? "Material: " ~ d.material : "Dimensions in mm", 2.8);
    sh.text(x + 3, y + 4, d.author.length ? d.author : d.file, 2.5);
    sh.text(x + 122, y + 9, "Scale", 2.2);
    sh.text(x + 122, y + 3.5, scaleText(d.scale), 3.5);
    sh.text(x + 152, y + 9, "Sheet", 2.2);
    sh.text(x + 152, y + 3.5, d.size, 3.5);
    sh.text(x + w - 3, y + 3.5, d.projection == "third" ? "3rd angle" : "1st angle", 2.2, Anchor.end);
    sh.text(x + w - 3, y + 18, "hackerscad", 2.5, Anchor.end);
}

unittest
{
    import hackerscad.kernel.occt.backend : OcctKernel;
    import std.algorithm : count;

    auto k = new OcctKernel;
    // a plate with two holes
    auto plate = k.boolean(k.translate(k.box(60, 40, 10), Vec3(-30, -20, 0)),
        k.boolean(k.translate(k.cylinder(3, 30), Vec3(-15, 0, -10)), k.translate(k.cylinder(3, 30), Vec3(15, 0, -10)),
        BoolOp.fuse), BoolOp.cut);
    Drawing d;
    d.title = "Plate";
    foreach (name; ["front", "top", "right", "iso"])
        d.views ~= View(plate, name, directionOf(name), 1, 0, 0, true);
    auto sh = render(d, k);
    assert(d.scale == 2, format("%s", d.scale));
    auto svg = toSvg(sh);
    assert(svg.canFind(">60<") && svg.canFind(">40<") && svg.canFind("2× ⌀6"), svg);
    // the holes are hidden in the front view: dashed lines exist
    assert(sh.lines.count!(l => l.pen == Pen.hidden) > 0);

    // a section through the holes is hatched
    auto half = k.solids(k.boolean(plate, k.translate(k.box(200, 200, 200), Vec3(-100, 0, -100)), BoolOp.common))[0];
    View s = View(half, "section", Direction(Vec3(0, -1, 0), Vec3(0, 0, 1)), 1, 150, 100);
    s.isSection = true;
    s.planeOrigin = Vec3(0, 0, 0);
    s.planeNormal = Vec3(0, -1, 0);
    s.label = "A";
    Drawing d2;
    d2.views ~= s;
    d2.scale = 1;
    auto sh2 = render(d2, k);
    assert(sh2.lines.count!(l => l.pen == Pen.thin) > 20);
}
