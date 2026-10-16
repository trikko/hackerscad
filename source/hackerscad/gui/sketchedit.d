/// Editing a sketch from the window: SketchEdit, mixed into MainWindow (as
/// SketchFollow is), so it uses the window's members and imports as its own.
///
/// While a sketch is shown and its code can be written to (tool/sketchcode.d:
/// kept in a variable, in the open file, not in a loop), a bar of tools runs
/// down the left of the view. A click on a point or a line of the sketch adds
/// it to the sketch's selection (again: takes it away; on nothing: none), and
/// the tools that fit it write their constraint into the code: each selected
/// item, or relative to the first, a value on several as one dimension and the
/// others equal to it. The tools that take a value ask for it, the size the
/// sketch has now written in.
module hackerscad.gui.sketchedit;

mixin template SketchEdit()
{
    size_t[] sketchSel;   /// entities of the sketch drawn, in clicking order
    Box sketchBar;
    Button[string] toolButtons;

    /// The tools, in groups: a symbol each, and what it does.
    static immutable string[3][][] toolGroups = [
        [["coincident", "●", "Coincident: points on the first, or on a line or curve"],
            ["fix", "⚓", "Fix: pin the points where they are"]],
        [["horizontal", "―", "Horizontal: lines level, or two points at one height"],
            ["vertical", "|", "Vertical: lines upright, or two points one above the other"],
            ["parallel", "∥", "Parallel: lines parallel to the first"],
            ["perpendicular", "⊥", "Perpendicular: two lines at right angles"],
            ["equal", "=", "Equal: lines as long as the first, circles as big"],
            ["midpoint", "⋈", "Midpoint: a point in the middle of a line"],
            ["symmetric", "⇋", "Symmetric: two points mirrored across a line"]],
        [["tangent", "⌒", "Tangent: lines touching a circle, arc or ellipse, or two circles"],
            ["concentric", "◎", "Concentric: round the centre of the first"],
            ["on", "∈", "On: points on a line, circle, arc or ellipse"]],
        [["length", "↔", "Length: lines that long (the others as long), or two points that far apart"],
            ["distance", "⟷", "Distance: between two points, a point and a line, or two parallel lines"],
            ["angle", "∠", "Angle: between two lines, or of one from X"],
            ["radius", "R", "Radius: circles and arcs that size (the others as big)"],
            ["diameter", "⌀", "Diameter: circles and arcs that size (the others as big)"]],
    ];

    /// The bar, made once: buttons by group, separators between.
    Widget buildSketchBar()
    {
        import gtk.separator : Separator;
        sketchBar = new Box(Orientation.Vertical, 2);
        sketchBar.addCssClass("hcad-floating");
        sketchBar.addCssClass("hcad-sketchbar");
        sketchBar.setHalign(Align.Start);
        sketchBar.setValign(Align.Center);
        sketchBar.setMarginStart(8);
        foreach (g, group; toolGroups)
        {
            if (g)
                sketchBar.append(new Separator(Orientation.Horizontal));
            foreach (t; group)
            {
                auto b = new Button;
                b.setLabel(t[1]);
                b.addCssClass("flat");
                b.addCssClass("hcad-sketch-tool");
                b.setTooltipText(t[2]);
                b.connectClicked(toolClicked(t[0]));
                toolButtons[t[0]] = b;
                sketchBar.append(b);
            }
        }
        sketchBar.setVisible(false);
        return sketchBar;
    }

    // a function of its own: closures made in a loop would share its variable
    void delegate() toolClicked(string tool) => () => runSketchTool(tool);

    /// The sketch drawn now (the run shown), or null.
    const(SketchView)* drawnSketch()
    {
        auto runs = drawnRuns();
        if (runs.length != 1 || sketchIndices[runs[0]] >= last.sketches.length)
            return null;
        return &last.sketches[sketchIndices[runs[0]]];
    }

    /// Why the sketch drawn cannot be edited from here (null: it can).
    string sketchUneditable()
    {
        import hackerscad.tool.sketchcode : SketchWriter;
        auto v = drawnSketch();
        if (v is null)
            return "no sketch is drawn";
        if (v.span.file != absolutePath(path))
            return "the sketch is made in another file";
        try
            SketchWriter(text(), v.span.file, *v);
        catch (Exception e)
            return e.msg;
        return null;
    }

    /// The bar shown with an editable sketch, each tool usable when the selection fits it.
    void updateSketchBar()
    {
        import hackerscad.tool.sketchcode : planConstraint;
        if (sketchBar is null)
            return;
        auto v = drawnSketch();
        immutable why = v is null ? "none" : sketchUneditable();
        sketchBar.setVisible(v !is null && !frozen);
        foreach (tool, b; toolButtons)
        {
            string reason = why;
            if (reason is null)
            {
                planConstraint(*v, sketchSel, tool, "1.mm", reason);
                b.setSensitive(reason is null);
            }
            else
                b.setSensitive(false);
            foreach (group; toolGroups)
                foreach (t; group)
                    if (t[0] == tool)
                        b.setTooltipText(reason is null ? t[2] : t[2] ~ "\n" ~ reason);
        }
    }

    /// A click on the sketch drawn: the point or line under it joins its
    /// selection (or leaves it); on nothing, the selection empties. True when
    /// the click was on the sketch.
    bool sketchPick(double x, double y)
    {
        auto v = drawnSketch();
        if (v is null)
            return false;
        Vec3 world(Vec3 p) => v.world(p);
        double best = 64;   // 8 pixels away at most, points first
        ptrdiff_t found = -1;
        foreach (pt; v.points)
        {
            double px, py;
            if (viewport.project(world(pt.pos), px, py))
            {
                immutable d = (px - x) ^^ 2 + (py - y) ^^ 2;
                if (d < best)
                {
                    best = d;
                    found = pt.entity;
                }
            }
        }
        if (found < 0)
        {
            best = 36;   // 6 pixels from a line or curve
            foreach (g; v.segments)
            {
                if (g.entity < 0)
                    continue;
                foreach (seg; polylineOf(g))
                {
                    double ax, ay, bx, by;
                    if (!viewport.project(world(seg[0]), ax, ay) || !viewport.project(world(seg[1]), bx, by))
                        continue;
                    immutable dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
                    immutable t = l2 > 0 ? clamp(((x - ax) * dx + (y - ay) * dy) / l2, 0.0, 1.0) : 0;
                    immutable d = (ax + t * dx - x) ^^ 2 + (ay + t * dy - y) ^^ 2;
                    if (d < best)
                    {
                        best = d;
                        found = g.entity;
                    }
                }
            }
        }
        if (found < 0)
        {
            if (sketchSel.length)
            {
                sketchSel = null;
                drawRuns();
                updateSketchBar();
            }
            return false;
        }
        import std.algorithm : countUntil, remove;
        immutable at = sketchSel.countUntil(cast(size_t) found);
        if (at >= 0)
            sketchSel = sketchSel.remove(at);
        else
            sketchSel ~= cast(size_t) found;
        drawRuns();
        updateSketchBar();
        auto e = v.entities[found];
        jumpTo(e.span, format("%d selected in the sketch · %s · line %d", sketchSel.length, e.kind, e.span.line));
        return true;
    }

    /// The segment's line or curve as short straight pieces.
    static Vec3[2][] polylineOf(const ref SketchView.Segment g)
    {
        import std.math : atan2, cos, sin;
        import hackerscad.geom.spline : sampleSpline;
        Vec3[] pts;
        if (g.kind == 0)
            pts = [g.a, g.b];
        else if (g.kind == 4)
            pts = sampleSpline(g.poles, 12);
        else
        {
            double a0 = 0, a1 = 2 * PI;
            if (g.kind == 1)
            {
                a0 = atan2(g.a.y - g.c.y, g.a.x - g.c.x);
                a1 = atan2(g.b.y - g.c.y, g.b.x - g.c.x);
                while (a1 <= a0 + 1e-9)
                    a1 += 2 * PI;
            }
            immutable r2 = g.kind == 3 ? g.r2 : g.r;
            immutable ux = Vec3(cos(g.angle), sin(g.angle), 0), uy = Vec3(-sin(g.angle), cos(g.angle), 0);
            foreach (k; 0 .. 33)
            {
                immutable t = a0 + (a1 - a0) * k / 32;
                pts ~= g.c + ux * (g.r * cos(t)) + uy * (r2 * sin(t));
            }
        }
        Vec3[2][] r;
        foreach (k; 1 .. pts.length)
            r ~= [pts[k - 1], pts[k]];
        return r;
    }

    /// The selection's size as the sketch has it now, for a tool's value: "20.mm", "30.deg".
    string currentValue(string tool)
    {
        import std.math : acos, abs;
        auto v = drawnSketch();
        if (v is null || sketchSel.length == 0)
            return tool == "angle" ? "90.deg" : "10.mm";
        Vec3 pos(size_t p)
        {
            foreach (pt; v.points)
                if (pt.entity == p)
                    return pt.pos;
            return Vec3.init;
        }
        static string mm(double x) => format("%.4g.mm", x);
        auto first = v.entities[sketchSel[0]];
        Vec3 dir(size_t e) => (pos(v.entities[e].points[1]) - pos(v.entities[e].points[0])).normalized;
        switch (tool)
        {
        case "length", "distance":
            if (sketchSel.length >= 2 && first.kind == "point" && v.entities[sketchSel[1]].kind == "point")
                return mm((pos(sketchSel[1]) - pos(sketchSel[0])).length);
            if (first.kind == "line" && (tool == "length" || sketchSel.length == 1))
                return mm((pos(first.points[1]) - pos(first.points[0])).length);
            if (sketchSel.length == 2)
            {
                // a point and a line, or two lines: from the point (the first line's start) square to the other line
                auto p = first.kind == "point" ? pos(sketchSel[0]) : pos(first.points[0]);
                auto l = v.entities[sketchSel[1]];
                auto a = pos(l.points[0]), d = dir(sketchSel[1]);
                auto off = (p - a) - d * (p - a).dot(d);
                return mm(off.length);
            }
            return "10.mm";
        case "angle":
            if (sketchSel.length == 2)
                return format("%.4g.deg", acos(clamp(abs(dir(sketchSel[0]).dot(dir(sketchSel[1]))), 0.0, 1.0)) * 180 / PI);
            if (first.kind == "line")
            {
                import std.math : atan2;
                auto d = dir(sketchSel[0]);
                return format("%.4g.deg", atan2(d.y, d.x) * 180 / PI);
            }
            return "90.deg";
        case "radius", "diameter":
            foreach (g; v.segments)
                if (g.entity == sketchSel[0])
                    return mm(tool == "radius" ? g.r : 2 * g.r);
            return "5.mm";
        default:
            return null;
        }
    }

    void runSketchTool(string tool)
    {
        import hackerscad.tool.sketchcode : valueTools;
        import std.algorithm : canFind;
        if (!valueTools.canFind(tool))
            return info(applySketchTool(tool, null));
        // a value: asked in a field by the button, the size it has now written in
        auto b = toolButtons[tool];
        auto pop = new Popover;
        auto entry = new Entry;
        entry.setText(currentValue(tool));
        entry.setWidthChars(10);
        entry.setTooltipText("Enter writes it; a length takes .mm, an angle .deg");
        entry.connectActivate(() {
            immutable value = entry.getText();
            pop.popdown();
            info(applySketchTool(tool, value));
        });
        pop.setChild(entry);
        pop.setParent(b);
        import gtk.types : PositionType;
        pop.setPosition(PositionType.Right);
        pop.connectClosed(() { idleAdd(PRIORITY_DEFAULT, () { pop.unparent(); return false; }); });
        pop.popup();
        entry.grabFocus();
        entry.selectRegion(0, -1);
    }

    /// Writes tool `tool` for the selection into the sketch's code (one
    /// undo step), its value selected; what the info line then says.
    string applySketchTool(string tool, string value)
    {
        import hackerscad.tool.sketchcode : editBetween, planConstraint, writeSteps;
        if (busy())
            return "wait for the evaluation to finish, then try again";
        auto v = drawnSketch();
        if (v is null)
            return "no sketch is drawn";
        immutable src = text();
        // the sketch's lines are those of the code evaluated: it must be the same
        if (last.sources.get(absolutePath(path), null) != src)
            return "the code changed since it was evaluated: wait for it, then try again";
        string why;
        auto steps = planConstraint(*v, sketchSel, tool, value, why);
        if (steps.length == 0)
            return why;
        string after;
        try
            after = writeSteps(src, v.span.file, *v, steps);
        catch (Exception e)
            return e.msg;
        applyEdit(editBetween(src, after, value));
        sketchSel = null;
        return format("%s written in the sketch's code", tool);
    }
}
