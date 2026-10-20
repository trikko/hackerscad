/// Drawings in the language: `drawing()` returns an object that collects
/// views, sections, dimensions and notes; @drawing functions return one.
module hackerscad.lang.drawingval;

import std.algorithm : canFind;
import std.format : format;
import std.path : baseName;

import hackerscad.drawing.layout;
import hackerscad.drawing.sheet;
import hackerscad.geom.vec;
import hackerscad.kernel.brep;
import hackerscad.lang.builtins : Args, planeArg;
import hackerscad.lang.errors;
import hackerscad.lang.interp;
import hackerscad.lang.value;

void installDrawing(Interp it, void delegate(string, BuiltinImpl) def)
{
    def("drawing", (ref CallArgs a) {
        // drawing(size: "A4", title: "Lid", material: "PETG", projection: "first", scale: 0 (fit))
        auto x = Args(it, a, "drawing", ["size", "title", "author", "material", "projection", "scale", "landscape"]);
        auto d = new DrawingVal(it, a.span);
        d.d.size = x.has("size") ? str(x, "size") : "A4";
        try
            sheetSize(d.d.size, true);
        catch (Exception e)
            throw new HcadError(Code.type, e.msg, x.spanOf("size"));
        d.d.landscape = x.flag("landscape", true);
        d.d.title = x.has("title") ? str(x, "title") : "";
        d.d.author = x.has("author") ? str(x, "author") : "";
        d.d.material = x.has("material") ? str(x, "material") : "";
        d.d.projection = x.has("projection") ? str(x, "projection") : "first";
        if (!["first", "third"].canFind(d.d.projection))
            throw new HcadError(Code.type, "projection must be \"first\" (ISO, Europe) or \"third\" (America)",
                x.spanOf("projection"));
        d.d.scale = x.has("scale") ? x.num("scale") : 0;
        d.d.file = baseName(a.span.file);
        return Value.make(Kind.object_, d);
    });
}

private string str(ref Args x, string n)
{
    auto v = x.get(n);
    if (v.kind != Kind.str)
        throw new HcadError(Code.type, format("'%s' must be a string", n), x.spanOf(n));
    return v.s;
}

final class DrawingVal : ObjectVal
{
    Interp it;
    Span span;
    Drawing d;

    this(Interp it, Span span)
    {
        this.it = it;
        this.span = span;
    }

    override string typeName() const => "Drawing";
    override string describe() => format("Drawing(%s, %d views)", d.size, d.views.length);
    override string[] memberNames() => ["standardViews", "view", "section", "dimension", "note"];

    /// Lays out and draws the sheet (hidden-line removal happens here).
    Sheet render()
    {
        try
            return hackerscad.drawing.layout.render(d, it.kernel);
        catch (KernelException e)
            throw new HcadError(Code.kernel, e.msg, span);
    }

    override BuiltinImpl method(string name)
    {
        switch (name)
        {
        case "standardViews":
            return (ref CallArgs a) {
                // front, top, side and an isometric view, scaled to fit, with overall dimensions and hole callouts
                auto x = Args(it, a, "standardViews", ["drawing", "solid", "iso", "dimensions"]);
                auto s = solidArg(x);
                immutable dims = x.flag("dimensions", true);
                Value[] views;
                foreach (n; ["front", "top", "right"] ~ (x.flag("iso", true) ? ["iso"] : []))
                    views ~= addView(s, n, true, dims);
                return Value.of(views);
            };
        case "view":
            return (ref CallArgs a) {
                // d.view(part, "front"): placed by the layout; at: vec(x, y) (paper mm from the bottom-left) and
                // scale: place it by hand
                auto x = Args(it, a, "view", ["drawing", "solid", "name", "at", "scale", "dimensions"]);
                auto s = solidArg(x);
                auto n = x.has("name") ? str(x, "name") : "front";
                if (!viewNames.canFind(n))
                    throw new HcadError(Code.type, format("unknown view '%s' (front, back, top, bottom, right, left, iso)", n),
                        x.spanOf("name"), Interp.suggest(n, viewNames.dup));
                auto v = addView(s, n, !x.has("at"), x.flag("dimensions", true));
                place(x, d.views[$ - 1]);
                return v;
            };
        case "section":
            return (ref CallArgs a) {
                // d.section(part, plane, label: "A"): the part cut by the plane, seen from the side the normal points
                // to, the cut faces hatched
                auto x = Args(it, a, "section", ["drawing", "solid", "plane", "label", "at", "scale"]);
                auto s = solidArg(x);
                Vec3 o, n;
                planeArg(x, "plane", o, n);
                Brep kept;
                try
                {
                    // keep what lies behind the plane: a half space as a huge box
                    auto bb = it.kernel.bbox(s);
                    immutable big = (bb.max - bb.min).length * 4 + 100;
                    auto slab = it.kernel.translate(it.kernel.box(big, big, big), Vec3(-big / 2, -big / 2, -big));
                    slab = orient(slab, n);
                    kept = it.kernel.boolean(s, it.kernel.translate(slab, o), BoolOp.common);
                }
                catch (KernelException e)
                    throw new HcadError(Code.kernel, e.msg, a.span);
                // a plane beside the part would give an empty view, or the whole part with nothing cut
                import std.algorithm : max, min;
                import std.math : abs;

                static double tidy(double v) => abs(v) < 1e-6 ? 0 : v;
                bool cuts;
                if (kept !is null)
                    foreach (f; it.kernel.faces(kept))
                        if (abs((f.center - o).dot(n)) < 1e-6 && f.normal.dot(n) > 0.999)
                        {
                            cuts = true;
                            break;
                        }
                if (!cuts)
                {
                    auto bb = it.kernel.bbox(s);
                    double lo = double.infinity, hi = -double.infinity;
                    foreach (i; 0 .. 8)
                    {
                        immutable c = Vec3(i & 1 ? bb.max.x : bb.min.x, i & 2 ? bb.max.y : bb.min.y,
                            i & 4 ? bb.max.z : bb.min.z).dot(n);
                        lo = min(lo, c);
                        hi = max(hi, c);
                    }
                    throw new HcadError(Code.type, format("the section plane does not cut the part: it lies at %g mm "
                        ~ "along its normal, the part from %g to %g mm; move the plane into the part", tidy(o.dot(n)),
                        tidy(lo), tidy(hi)), x.spanOf("plane"));
                }
                View v;
                v.solid = kept;
                v.name = "section";
                v.isSection = true;
                v.planeOrigin = o;
                v.planeNormal = n;
                v.label = x.has("label") ? str(x, "label") : format("%c", cast(char)('A' + sections++));
                // look against the normal, with up as close to +Z as possible
                auto up = abs(n.z) > 0.99 ? Vec3(0, 1, 0) : Vec3(0, 0, 1);
                v.direction = Direction(n, up);
                v.autoPlaced = !x.has("at");
                v.dimensions = false;
                d.views ~= v;
                place(x, d.views[$ - 1]);
                return Value.make(Kind.object_, new ViewVal(this, d.views.length - 1));
            };
        case "dimension":
            return (ref CallArgs a) {
                // d.dimension(view, from: vec(…), to: vec(…), offset: 8.mm): between two model points
                auto x = Args(it, a, "dimension", ["drawing", "view", "from", "to", "offset", "text"]);
                auto vv = x.get("view");
                auto view = vv.kind == Kind.object_ ? cast(ViewVal) vv.obj : null;
                if (view is null || view.owner !is this)
                    throw new HcadError(Code.type, "'view' must be a view of this drawing", x.spanOf("view"));
                Dimension dim;
                dim.view = view.index;
                dim.from = x.vecLen("from");
                dim.to = x.vecLen("to");
                dim.offset = x.lenOr("offset", 8);
                dim.text = x.has("text") ? str(x, "text") : "";
                d.dims ~= dim;
                return Value.void_;
            };
        case "note":
            return (ref CallArgs a) {
                auto x = Args(it, a, "note", ["drawing", "text", "at", "size"]);
                auto at = x.vecLen("at");
                d.notes ~= Note(str(x, "text"), at.x, at.y, x.lenOr("size", 3.5));
                return Value.void_;
            };
        default:
            return null;
        }
    }

private:

    int sections;

    Brep solidArg(ref Args x)
    {
        auto v = x.get("solid");
        if (v.kind != Kind.solid || v.solid.flat || v.solid.path || v.solid.brep is null)
            throw new HcadError(Code.type, format("'solid' must be a Solid, not %s", v.typeName), x.spanOf("solid"));
        return v.solid.brep;
    }

    Value addView(Brep s, string name, bool auto_, bool dims)
    {
        View v;
        v.solid = s;
        v.name = name;
        v.direction = directionOf(name);
        v.autoPlaced = auto_;
        v.dimensions = dims;
        d.views ~= v;
        return Value.make(Kind.object_, new ViewVal(this, d.views.length - 1));
    }

    void place(ref Args x, ref View v)
    {
        if (x.has("at"))
        {
            auto p = x.vecLen("at");
            v.x = p.x;
            v.y = p.y;
            v.scale = x.has("scale") ? x.num("scale") : (d.scale > 0 ? d.scale : 1);
        }
    }

    /// The half-space box (below z = 0) turned so that its top faces `n`.
    Brep orient(Brep slab, Vec3 n)
    {
        import std.math : acos, abs;
        auto z = Vec3(0, 0, 1);
        auto axis = z.cross(n);
        if (axis.length < 1e-9)
            return n.z > 0 ? slab : it.kernel.mirror(slab, z);
        return it.kernel.rotate(slab, axis.normalized, acos(z.dot(n)));
    }
}

/// A view of a drawing, to attach dimensions to.
final class ViewVal : ObjectVal
{
    DrawingVal owner;
    size_t index;

    this(DrawingVal owner, size_t index)
    {
        this.owner = owner;
        this.index = index;
    }

    override string typeName() const => "DrawingView";
    override string describe() => "DrawingView(" ~ owner.d.views[index].name ~ ")";
}

private double abs(double x) => x < 0 ? -x : x;
