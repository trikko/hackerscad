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
    Button[string] drawButtons;
    string drawTool;      /// the drawing tool at work (null: clicks select)
    Vec3[] drawn;         /// its clicks so far, on the sketch's plane
    ptrdiff_t[] drawnAt;  /// for each: the point of the sketch it snapped to, or -1 (a new one)

    /// The drawing tools: a symbol each, and how to use it.
    static immutable string[3][] drawTools = [
        ["select", "↖", "Select: a click adds a point or a line to the selection (again: takes it away)"],
        ["point", "∙", "Point: a click puts one"],
        ["line", "╱", "Lines: click their points; on the first again it closes, Enter or a right-click ends it"],
        ["rect", "▭", "Rectangle: two opposite corners"],
        ["circle", "○", "Circle: its centre, then a point on it"],
        ["arc", "◜", "Arc: its centre, where it starts, where it ends (counter-clockwise)"],
        ["spline", "∿", "Smooth curve: click its points; on the first again it closes, Enter or a right-click ends it"],
    ];

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

    /// The bar, made once: two columns of buttons by group, separators
    /// between (drawing, points and curves at the left; directions and
    /// sizes at the right), half as tall as one.
    Widget buildSketchBar()
    {
        import gtk.separator : Separator;
        sketchBar = new Box(Orientation.Horizontal, 2);
        sketchBar.addCssClass("hcad-floating");
        sketchBar.addCssClass("hcad-sketchbar");
        sketchBar.setHalign(Align.Start);
        sketchBar.setValign(Align.Center);
        sketchBar.setMarginStart(8);
        auto left = new Box(Orientation.Vertical, 2), right = new Box(Orientation.Vertical, 2);
        sketchBar.append(left);
        sketchBar.append(new Separator(Orientation.Vertical));
        sketchBar.append(right);
        Button button(string symbol, string tip)
        {
            auto b = new Button;
            b.setLabel(symbol);
            b.addCssClass("flat");
            b.addCssClass("hcad-sketch-tool");
            b.setTooltipText(tip);
            return b;
        }
        foreach (t; drawTools)
        {
            auto b = button(t[1], t[2]);
            b.connectClicked(drawClicked(t[0]));
            drawButtons[t[0]] = b;
            left.append(b);
        }
        // points and curves under the drawing tools; directions, then sizes, in the other column
        foreach (g, group; toolGroups)
        {
            auto column = g == 0 || g == 2 ? left : right;
            if (g != 1)
                column.append(new Separator(Orientation.Horizontal));
            foreach (t; group)
            {
                auto b = button(t[1], t[2]);
                b.connectClicked(toolClicked(t[0]));
                toolButtons[t[0]] = b;
                column.append(b);
            }
        }
        sketchBar.setVisible(false);
        return sketchBar;
    }

    // a function of its own: closures made in a loop would share its variable
    void delegate() toolClicked(string tool) => () => runSketchTool(tool);
    void delegate() drawClicked(string tool) => () => startDrawing(tool == "select" ? null : tool);

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
        foreach (tool, b; drawButtons)
        {
            b.setSensitive(why is null);
            if (tool == (drawTool is null ? "select" : drawTool))
                b.addCssClass("hcad-tool-on");
            else
                b.removeCssClass("hcad-tool-on");
        }
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
        if (drawTool !is null)
        {
            drawingClick(x, y);
            return true;
        }
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

    // ---- drawing

    /// A drawing tool chosen (null: back to selecting); what was being drawn is dropped.
    void startDrawing(string tool)
    {
        drawTool = tool;
        drawn = null;
        drawnAt = null;
        sketchSel = null;
        showDrawing(double.nan, double.nan);
        drawRuns();
        if (tool is null)
            return info("");
        foreach (t; drawTools)
            if (t[0] == tool)
                info(t[2] ~ " · Esc drops it");
    }

    /// Where view point (x, y) falls on the sketch's plane, in its own coordinates.
    bool onSketchPlane(double x, double y, out Vec3 p)
    {
        auto v = drawnSketch();
        if (v is null)
            return false;
        Vec3 o, d;
        viewport.rayAt(x, y, o, d);
        auto origin = v.placed ? v.place[0] : Vec3(0, 0, 0);
        auto ax = v.placed ? v.place[1] : Vec3(1, 0, 0), ay = v.placed ? v.place[2] : Vec3(0, 1, 0);
        auto n = v.placed ? v.place[3] : Vec3(0, 0, 1);
        immutable dn = d.dot(n);
        if (abs(dn) < 1e-9)
            return false;
        auto hit = o + d * ((origin - o).dot(n) / dn);
        // to a tenth of a millimetre: the code reads, the constraints place it exactly
        import std.math : round;
        p = Vec3(round((hit - origin).dot(ax) * 10) / 10, round((hit - origin).dot(ay) * 10) / 10, 0);
        return true;
    }

    /// The point of the sketch (or of the drawing so far) within 10 pixels of (x, y): its id (-2: the drawing's
    /// first point), where it is; -1 when none.
    ptrdiff_t snapAt(double x, double y, out Vec3 at)
    {
        auto v = drawnSketch();
        double best = 100;
        ptrdiff_t found = -1;
        void consider(Vec3 p, ptrdiff_t id)
        {
            double px, py;
            if (viewport.project(v.world(p), px, py) && (px - x) ^^ 2 + (py - y) ^^ 2 < best)
            {
                best = (px - x) ^^ 2 + (py - y) ^^ 2;
                found = id;
                at = p;
            }
        }
        if (drawn.length >= 2 && (drawTool == "line" || drawTool == "spline"))
            consider(drawn[0], -2);
        foreach (pt; v.points)
            consider(pt.pos, pt.entity);
        return found;
    }

    void drawingClick(double x, double y)
    {
        Vec3 p;
        ptrdiff_t at = snapAt(x, y, p);
        if (at == -1 && !onSketchPlane(x, y, p))
            return;
        // on the first point again: the lines or the curve close, and are written
        if (at == -2)
            return finishDrawing(true);
        drawn ~= p;
        drawnAt ~= at;
        immutable needed = drawTool == "point" ? 1 : drawTool == "rect" || drawTool == "circle" ? 2
            : drawTool == "arc" ? 3 : size_t.max;
        if (drawn.length >= needed)
            return finishDrawing(false);
        showDrawing(x, y);
    }

    /// The preview: the clicks so far, and on to the pointer at (x, y) (nan: not).
    void showDrawing(double x, double y)
    {
        auto v = drawnSketch();
        viewport.drawingLines = null;
        viewport.drawingPoints = null;
        viewport.drawingSnap = null;
        if (v is null || drawTool is null)
            return viewport.refresh();
        Vec3[] pts = drawn.dup;
        if (x == x)
        {
            Vec3 p;
            ptrdiff_t at = snapAt(x, y, p);
            if (at != -1)
                viewport.drawingSnap = [v.world(p)];
            if (at != -1 || onSketchPlane(x, y, p))
                pts ~= p;
        }
        Vec3 w(Vec3 q) => v.world(q);
        foreach (q; drawn)
            viewport.drawingPoints ~= w(q);
        if (pts.length >= 2)
        {
            import std.math : atan2, cos, sin;
            switch (drawTool)
            {
            case "rect":
                {
                    auto a = pts[0], c = pts[1];
                    viewport.drawingLines = [[w(a), w(Vec3(c.x, a.y)), w(c), w(Vec3(a.x, c.y)), w(a)]];
                    break;
                }
            case "circle", "arc":
                {
                    auto c = pts[0];
                    immutable r = (pts[1] - c).length;
                    double a0 = 0, a1 = 2 * PI;
                    if (drawTool == "arc" && pts.length >= 3)
                    {
                        a0 = atan2(pts[1].y - c.y, pts[1].x - c.x);
                        a1 = atan2(pts[2].y - c.y, pts[2].x - c.x);
                        while (a1 <= a0)
                            a1 += 2 * PI;
                    }
                    Vec3[] ring;
                    foreach (k; 0 .. 49)
                    {
                        immutable t = a0 + (a1 - a0) * k / 48;
                        ring ~= w(c + Vec3(cos(t), sin(t)) * r);
                    }
                    viewport.drawingLines = [ring, [w(c), w(pts[1])]];
                    break;
                }
            case "spline":
                {
                    import hackerscad.geom.spline : sampleSpline, splinePoles;
                    Vec3[] clean = [pts[0]];
                    foreach (q; pts[1 .. $])
                        if ((q - clean[$ - 1]).length > 1e-6)
                            clean ~= q;
                    Vec3[] line;
                    if (clean.length >= 2)
                        foreach (q; sampleSpline(splinePoles(clean, false), 16))
                            line ~= w(q);
                    viewport.drawingLines = [line];
                    break;
                }
            default:
                {
                    Vec3[] line;
                    foreach (q; pts)
                        line ~= w(q);
                    viewport.drawingLines = [line];
                }
            }
        }
        viewport.refresh();
    }

    /// The pointer moved: the preview follows it.
    void drawingMotion(double x, double y)
    {
        if (drawTool !is null && drawn.length)
            showDrawing(x, y);
        else if (drawTool !is null)
        {
            // nothing clicked yet: only where it would snap
            Vec3 p;
            viewport.drawingSnap = snapAt(x, y, p) != -1 ? [drawnSketch().world(p)] : null;
            viewport.refresh();
        }
    }

    /// Writes what was drawn into the sketch's code (closed: the lines or curve back to the first point).
    void finishDrawing(bool closed)
    {
        immutable tool = drawTool;
        auto pts = drawn.dup, at = drawnAt.dup;
        drawn = null;
        drawnAt = null;
        showDrawing(double.nan, double.nan);
        immutable least = tool == "line" ? 2 : tool == "spline" ? (closed ? 3 : 2) : 1;
        if (pts.length < least)
            return info("not enough points: nothing written");
        info(writeDrawing(tool, pts, at, closed));
    }

    /// The statements for what was drawn: new points made, those snapped to named.
    string writeDrawing(string tool, Vec3[] pts, ptrdiff_t[] at, bool closed)
    {
        import hackerscad.tool.sketchcode : SketchWriter, editBetween;
        if (busy())
            return "wait for the evaluation to finish, then try again";
        auto v = drawnSketch();
        if (v is null)
            return "no sketch is drawn";
        immutable src = text();
        if (last.sources.get(absolutePath(path), null) != src)
            return "the code changed since it was evaluated: wait for it, then try again";
        static string num(double x) => format("%.6g", x + 0.0);
        string select;
        try
        {
            auto w = SketchWriter(src, v.span.file, *v);
            string[size_t] made;
            // the point of click i: the one it snapped to, or a new one
            string pointName(size_t i)
            {
                if (at[i] >= 0)
                    return w.name(at[i]);
                if (auto n = i in made)
                    return *n;
                auto n = w.fresh("p");
                w.add(format("auto %s = %s.point(%s, %s)", n, w.var, num(pts[i].x), num(pts[i].y)));
                made[i] = n;
                return n;
            }
            switch (tool)
            {
            case "point":
                select = pointName(0);
                break;
            case "line":
                {
                    string[] names;
                    foreach (i; 0 .. pts.length)
                        names ~= pointName(i);
                    foreach (i; 0 .. closed ? names.length : names.length - 1)
                        w.add(format("%s.line(%s, %s)", w.var, names[i], names[(i + 1) % names.length]));
                    select = names[$ - 1];
                    break;
                }
            case "rect":
                {
                    immutable n = w.fresh("rect");
                    w.add(format("auto %s = %s.rect(%s, %s)", n, w.var, pointName(0), pointName(1)));
                    select = n;
                    break;
                }
            case "circle":
                {
                    immutable n = w.fresh("circle");
                    immutable r = format("%s.mm", num((pts[1] - pts[0]).length));
                    w.add(format("auto %s = %s.circle(%s, r: %s)", n, w.var, pointName(0), r));
                    select = r;
                    break;
                }
            case "arc":
                {
                    immutable n = w.fresh("arc");
                    // its end on the circle its start gives: the solver keeps them equally far
                    w.add(format("auto %s = %s.arc(%s, %s, %s)", n, w.var, pointName(0), pointName(1), pointName(2)));
                    select = n;
                    break;
                }
            case "spline":
                {
                    string[] names;
                    foreach (i; 0 .. pts.length)
                        names ~= pointName(i);
                    immutable n = w.fresh("curve");
                    import std.array : join;
                    w.add(format("auto %s = %s.spline([%s]%s)", n, w.var, names.join(", "), closed ? ", closed: true" : ""));
                    select = n;
                    break;
                }
            default:
                return "no such drawing tool: " ~ tool;
            }
            applyEdit(editBetween(src, w.result(), select));
        }
        catch (Exception e)
            return e.msg;
        return tool ~ " written in the sketch's code";
    }
}
