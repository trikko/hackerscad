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
    Button[] drawButtons;     /// one per group of drawTools
    Label[] drawLabels;       /// the symbol each shows: its group's tool chosen last
    string[] drawChoice;      /// that tool
    int polygonSides = 6;     /// what the polygon tool draws
    Button deleteButton;
    Button constructionButton;
    bool sketchMarked;       /// the code's "picked" marks are the sketch selection's
    bool drawConstruction;   /// what is drawn is construction geometry (the bar's ┄ with nothing selected)
    string drawTool;      /// the drawing tool at work (null: clicks select)
    bool sketchEditHold;  /// the bar wrote into the code: the sketch stays shown until it is evaluated
    Vec3[] drawn;         /// its clicks so far, on the sketch's plane
    ptrdiff_t[] drawnAt;  /// for each: the point of the sketch it snapped to, or -1 (a new one)

    /// The drawing tools: a symbol each, a name for their group's menu, and how to use it.
    static immutable string[4][] drawTools = [
        ["select", "↖", "Select", "Select: a click adds a point or a line to the selection (again: takes it away)"],
        ["point", "∙", "Point", "Point: a click puts one"],
        ["line", "╱", "Lines", "Lines: click their points; on the first again it closes, a double click, Enter or a right-click ends them"],
        ["spline", "∿", "Smooth curve", "Smooth curve: click its points; on the first again it closes, a double click, Enter or a right-click ends it"],
        ["rect", "▭", "Rectangle by corners", "Rectangle: two opposite corners"],
        ["center-rect", "⊡", "Rectangle from its centre", "Rectangle from its centre: the centre, then a corner"],
        ["turned-rect", "◇", "Turned rectangle", "Turned rectangle: one side's two ends, then how far the other side is"],
        ["polygon", "⬡", "Regular polygon", "Regular polygon: its centre, then a corner (the sides: in the menu)"],
        ["slot", "⊂⊃", "Slot", "Slot: the centres of its two ends, then how wide"],
        ["circle", "○", "Circle", "Circle: its centre, then a point on it"],
        ["ellipse", "⬭", "Ellipse", "Ellipse: its centre, the end of its long axis, then how wide"],
        ["teardrop", "△", "Teardrop", "Teardrop (a hole that prints sideways, its point up): its centre, then a point on its circle"],
        ["arc", "◜", "Arc by its centre", "Arc: its centre, where it starts, where it ends (counter-clockwise)"],
        ["3-point-arc", "⌒", "Arc through 3 points", "Arc through three points: where it starts, where it ends, a point on it"],
        ["fill", "◩", "Fill", "Fill: a click inside a closed area makes it full (extruded) or empty"],
    ];

    /// The drawing tools by button: a right-click (or a click on the one at work) gives the others of its group.
    static immutable string[][] drawGroups = [["select"], ["point"], ["line", "spline"],
        ["rect", "center-rect", "turned-rect", "polygon", "slot"], ["circle", "ellipse", "teardrop"],
        ["arc", "3-point-arc"], ["fill"]];

    /// The row of drawTools for `tool`.
    static string[4] drawToolInfo(string tool)
    {
        foreach (t; drawTools)
            if (t[0] == tool)
                return t;
        return ["", "", "", ""];
    }

    /// How many clicks a drawing tool takes (size_t.max: until it is ended).
    static size_t drawClicks(string tool)
    {
        switch (tool)
        {
        case "point", "fill":
            return 1;
        case "rect", "center-rect", "polygon", "circle", "teardrop":
            return 2;
        case "turned-rect", "slot", "ellipse", "arc", "3-point-arc":
            return 3;
        default:
            return size_t.max;
        }
    }

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
            if (symbol !is null)
                b.setLabel(symbol);
            b.addCssClass("flat");
            b.addCssClass("hcad-sketch-tool");
            if (tip !is null)
                b.setTooltipText(tip);
            return b;
        }
        foreach (g, group; drawGroups)
        {
            auto b = button(null, null);
            auto label = new Label(drawToolInfo(group[0])[1]);
            if (group.length > 1)
            {
                // a corner mark: there is a menu of the group's other tools
                auto overlay = new Overlay;
                overlay.setChild(label);
                auto mark = new Label("◢");
                mark.addCssClass("hcad-tool-more");
                mark.setHalign(Align.End);
                mark.setValign(Align.End);
                overlay.addOverlay(mark);
                b.setChild(overlay);
                auto menuClick = new GestureClick;
                menuClick.setButton(3);
                menuClick.connectPressed(drawMenuPressed(g));
                b.addController(menuClick);
            }
            else
                b.setChild(label);
            b.connectClicked(drawClicked(g));
            drawButtons ~= b;
            drawLabels ~= label;
            drawChoice ~= group[0];
            left.append(b);
        }
        updateDrawTips();
        deleteButton = button("⌫", "Delete what is selected, what is drawn on it and the constraints on them (Delete)");
        deleteButton.connectClicked(() { info(deleteSelection()); });
        left.append(deleteButton);
        constructionButton = button("┄", "Construction: what is selected becomes construction geometry (dashed, a guide "
            ~ "to constrain to, never filled or extruded), or back; with nothing selected, what you draw next is (X)");
        constructionButton.connectClicked(() { info(constructionClicked()); });
        left.append(constructionButton);
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
    void delegate() drawClicked(size_t g) => () {
        // the tool at work clicked again: the menu of its group
        if (drawGroups[g].length > 1 && drawTool == drawChoice[g])
            return drawMenu(g);
        startDrawing(drawChoice[g] == "select" ? null : drawChoice[g]);
    };
    void delegate(int, double, double, GestureClick) drawMenuPressed(size_t g) =>
        (int n, double x, double y, GestureClick c) => drawMenu(g);

    /// Each drawing button's tooltip: its tool, and its group's menu.
    void updateDrawTips()
    {
        foreach (g, b; drawButtons)
            b.setTooltipText(drawToolInfo(drawChoice[g])[3]
                ~ (drawGroups[g].length > 1 ? "\nRight-click: the other kinds" : ""));
    }

    /// The menu of a drawing button: its group's tools (the polygon with its sides); one chosen starts it.
    void drawMenu(size_t g)
    {
        import gtk.spin_button : SpinButton;
        import gtk.types : PositionType;
        auto pop = new Popover;
        auto list = new Box(Orientation.Vertical, 0);
        foreach (tool; drawGroups[g])
        {
            immutable t = drawToolInfo(tool);
            auto row = new Box(Orientation.Horizontal, 6);
            auto item = new Button;
            item.addCssClass("flat");
            auto inside = new Box(Orientation.Horizontal, 8);
            auto symbol = new Label(t[1]);
            symbol.setWidthChars(2);
            inside.append(symbol);
            auto name = new Label(t[2]);
            name.setXalign(0);
            name.setHexpand(true);
            inside.append(name);
            item.setChild(inside);
            item.setHexpand(true);
            item.setTooltipText(t[3]);
            item.connectClicked(menuChoice(pop, g, tool));
            row.append(item);
            if (tool == "polygon")
            {
                auto sides = SpinButton.newWithRange(3, 64, 1);
                sides.setValue(polygonSides);
                sides.setTooltipText("Its number of sides");
                sides.connectValueChanged(() { polygonSides = cast(int) sides.getValue(); });
                row.append(sides);
            }
            list.append(row);
        }
        pop.setChild(list);
        pop.setParent(drawButtons[g]);
        pop.setPosition(PositionType.Right);
        pop.connectClosed(() { idleAdd(PRIORITY_DEFAULT, () { pop.unparent(); return false; }); });
        pop.popup();
    }

    // a function of its own, as toolClicked: closures made in the menu's loop would share its variable
    void delegate() menuChoice(Popover pop, size_t g, string tool) => () {
        pop.popdown();
        chooseDrawTool(g, tool);
    };

    /// Tool `tool` of group g chosen (from its menu, or by name): its button shows it, and it starts.
    void chooseDrawTool(size_t g, string tool)
    {
        drawChoice[g] = tool;
        drawLabels[g].setLabel(drawToolInfo(tool)[1]);
        updateDrawTips();
        startDrawing(tool == "select" ? null : tool);
    }

    /// startDrawing for any tool, by name: its button shows it first.
    void chooseDrawTool(string tool)
    {
        foreach (g, group; drawGroups)
            foreach (t; group)
                if (t == tool)
                    return drawButtons.length ? chooseDrawTool(g, tool) : startDrawing(tool == "select" ? null : tool);
    }

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
        markSketchSelection();
        import hackerscad.tool.sketchcode : planConstraint;
        if (sketchBar is null)
            return;
        auto v = drawnSketch();
        immutable why = v is null ? "none" : sketchUneditable();
        immutable shown = v !is null && !frozen;
        sketchBar.setVisible(shown);
        // what the bar covers, for the view to frame the sketch beside it
        int least, natural, b0, b1;
        sketchBar.measure(Orientation.Horizontal, -1, least, natural, b0, b1);
        viewport.leftInset = shown ? natural + 16 : 0;
        if (deleteButton !is null)
            deleteButton.setSensitive(why is null && sketchSel.length > 0);
        if (constructionButton !is null)
        {
            constructionButton.setSensitive(why is null);
            if (drawConstruction)
                constructionButton.addCssClass("hcad-tool-on");
            else
                constructionButton.removeCssClass("hcad-tool-on");
        }
        foreach (g, b; drawButtons)
        {
            b.setSensitive(why is null);
            if (drawChoice[g] == (drawTool is null ? "select" : drawTool))
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

    /// The lines of code that made what is selected in the sketch, marked as
    /// a part picked in the view marks its line; the cursor stays where it
    /// is (moving it would show the sketch at the cursor instead, and its
    /// orange could not be clicked away). Nothing selected: no mark.
    void markSketchSelection()
    {
        // the mark is the 3D view's too: left alone when the sketch did not make it
        if (!sketchMarked && sketchSel.length == 0)
            return;
        TextIter s, e;
        buffer.getBounds(s, e);
        buffer.removeTagByName("picked", s, e);
        sketchMarked = false;
        auto v = drawnSketch();
        if (v is null)
            return;
        foreach (id; sketchSel)
        {
            if (id >= v.entities.length)
                continue;
            auto span = v.entities[id].span;
            TextIter a, b;
            if (span.file != absolutePath(path) || span.line == 0 || !buffer.getIterAtLine(a, span.line - 1))
                continue;
            buffer.getIterAtLine(b, span.line);
            buffer.applyTagByName("picked", a, b);
            sketchMarked = true;
        }
    }

    /// Scrolls the code to a line of the sketch (when it is in the open file), the cursor left alone.
    void showSketchLine(Span span)
    {
        TextIter a;
        if (span.file == absolutePath(path) && span.line > 0 && buffer.getIterAtLine(a, span.line - 1))
            editor.scrollToIter(a, 0.1, true, 0, 0.3);
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
        info(format("%d selected in the sketch · %s · line %d", sketchSel.length, e.kind, e.span.line));
        if (at < 0)
            showSketchLine(e.span);
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
        sketchEditHold = true;
        applyEdit(editBetween(src, after, value));
        // the selection stays: another constraint on the same items, or a click on nothing for none
        return format("%s written in the sketch's code", tool);
    }

    /// A box over the sketch drawn: its points and lines wholly inside it (crossing: touching it too) join
    /// the selection.
    void sketchBox(double x0, double y0, double x1, double y1, bool crossing)
    {
        auto v = drawnSketch();
        immutable lx = min(x0, x1), hx = max(x0, x1), ly = min(y0, y1), hy = max(y0, y1);
        bool inside(double x, double y) => x >= lx && x <= hx && y >= ly && y <= hy;
        size_t[] took;
        void take(ptrdiff_t entity)
        {
            import std.algorithm : canFind;
            if (entity >= 0 && !sketchSel.canFind(cast(size_t) entity) && !took.canFind(cast(size_t) entity))
                took ~= cast(size_t) entity;
        }
        foreach (pt; v.points)
        {
            double px, py;
            if (viewport.project(v.world(pt.pos), px, py) && inside(px, py))
                take(pt.entity);
        }
        foreach (g; v.segments)
        {
            if (g.entity < 0)
                continue;
            bool any, every = true;
            foreach (seg; polylineOf(g))
            {
                double ax, ay, bx, by;
                if (!viewport.project(v.world(seg[0]), ax, ay) || !viewport.project(v.world(seg[1]), bx, by))
                {
                    every = false;
                    continue;
                }
                any = any || boxMeetsSegment(lx, ly, hx, hy, ax, ay, bx, by);
                every = every && inside(ax, ay) && inside(bx, by);
            }
            if (crossing ? any : every)
                take(g.entity);
        }
        sketchSel ~= took;
        drawRuns();
        updateSketchBar();
        info(took.length ? format("%d selected in the sketch (%d by the box)", sketchSel.length, took.length)
            : "the box took nothing: drag over points and lines of the sketch");
    }

    /// Esc in a sketch, a step at a time before leaving it: the clicks of a shape
    /// being drawn, then the drawing tool and the selection (back to ↖). False: nothing to undo here.
    bool sketchEscape()
    {
        if (drawn.length)
        {
            drawn = null;
            drawnAt = null;
            showDrawing(double.nan, double.nan);
            return true;
        }
        if (drawTool is null && sketchSel.length == 0)
            return false;
        startDrawing(null);
        updateSketchBar();
        return true;
    }

    // ---- drawing

    /// A shape drawn by clicks, the sizes the code gets: rounded to a hundredth of a
    /// millimetre and a tenth of a degree (the clicks are to a tenth of a millimetre).
    struct DrawnShape
    {
        size_t[] uses;       /// the clicks its statement names, in order
        double w, h, r, angle;
        Vec3 center;         /// a 3-point arc's centre, a new point
        Vec3[][] outline;    /// to preview it
    }

    /// The shape tool `tool` makes from the clicks `pts` (as many as it takes, or
    /// the first ones and the pointer); null, or why it cannot (too few, in a line, no size).
    static string shapeOf(string tool, const(Vec3)[] pts, int sides, out DrawnShape d)
    {
        import std.math : atan2, cos, sin, round, abs, PI;
        static double mm(double x) => round(x * 100) / 100;
        static double deg(double a) => round(a * 180 / PI * 10) / 10;
        static Vec3 dir(double a) => Vec3(cos(a), sin(a));
        static Vec3[] arcPoints(Vec3 c, double r, double a0, double a1, Vec3 ax = Vec3(1, 0), Vec3 ay = Vec3(0, 1),
            double ry = double.nan)
        {
            Vec3[] ring;
            foreach (k; 0 .. 49)
            {
                immutable t = a0 + (a1 - a0) * k / 48;
                ring ~= c + ax * (r * cos(t)) + ay * ((ry == ry ? ry : r) * sin(t));
            }
            return ring;
        }
        if (pts.length < 2)
            return "click more";
        auto a = pts[0], b = pts[1];
        switch (tool)
        {
        case "center-rect":
            d.w = mm(2 * abs(b.x - a.x));
            d.h = mm(2 * abs(b.y - a.y));
            if (d.w == 0 || d.h == 0)
                return "a rectangle needs a width and a height";
            d.uses = [0];
            auto c = a - (b - a);
            d.outline = [[c, Vec3(b.x, c.y), b, Vec3(c.x, b.y), c]];
            return null;
        case "turned-rect":
            {
                immutable len = (b - a).length;
                if (len == 0)
                    return "a side needs a length";
                auto u = (b - a) / len, n = Vec3(-u.y, u.x);
                if (pts.length < 3)
                {
                    d.outline = [[a, b]];
                    return "click how far the other side is";
                }
                double h = (pts[2] - a).dot(n);
                // the other side on the right: the rectangle starts at the second click, the side the other way
                size_t from = 0;
                if (h < 0)
                {
                    from = 1;
                    u = u * -1;
                    n = n * -1;
                    h = -h;
                }
                auto p = pts[from];
                d.w = mm(len);
                d.h = mm(h);
                d.angle = deg(atan2(u.y, u.x));
                if (d.h == 0)
                    return "a rectangle needs a height";
                d.uses = [from];
                d.outline = [[p, p + u * len, p + u * len + n * h, p + n * h, p]];
                return null;
            }
        case "polygon":
            {
                d.r = mm((b - a).length);
                if (d.r == 0)
                    return "a polygon needs a size";
                d.angle = deg(atan2(b.y - a.y, b.x - a.x));
                d.uses = [0];
                Vec3[] ring;
                foreach (k; 0 .. sides + 1)
                    ring ~= a + dir(d.angle * PI / 180 + 2 * PI * k / sides) * d.r;
                d.outline = [ring];
                return null;
            }
        case "slot":
            {
                immutable len = (b - a).length;
                if (len == 0)
                    return "a slot's ends need to be apart";
                if (pts.length < 3)
                {
                    d.outline = [[a, b]];
                    return "click how wide";
                }
                auto u = (b - a) / len, n = Vec3(-u.y, u.x);
                d.w = mm(2 * abs((pts[2] - a).dot(n)));
                if (d.w == 0)
                    return "a slot needs a width";
                d.uses = [0, 1];
                immutable r = d.w / 2, t = atan2(u.y, u.x);
                d.outline = [[a + n * r, b + n * r] ~ arcPoints(b, r, t + PI / 2, t - PI / 2)
                    ~ [a - n * r] ~ arcPoints(a, r, t - PI / 2, t - 3 * PI / 2)];
                return null;
            }
        case "ellipse":
            {
                d.w = mm((b - a).length);   // rx
                if (d.w == 0)
                    return "an ellipse needs a size";
                auto u = (b - a) / (b - a).length, n = Vec3(-u.y, u.x);
                d.angle = deg(atan2(u.y, u.x));
                if (pts.length < 3)
                {
                    d.outline = [[a, b]];
                    return "click how wide";
                }
                d.h = mm(abs((pts[2] - a).dot(n)));   // ry
                if (d.h == 0)
                    return "an ellipse needs a width";
                d.uses = [0];
                d.outline = [arcPoints(a, d.w, 0, 2 * PI, u, n, d.h)];
                return null;
            }
        case "teardrop":
            {
                d.r = mm((b - a).length);
                if (d.r == 0)
                    return "a teardrop needs a size";
                d.uses = [0];
                // its point straight up, the sides at 45°
                auto tip = a + Vec3(0, d.r * 2 ^^ 0.5);
                auto ring = arcPoints(a, d.r, PI / 4 + PI / 2, PI / 4 + 2 * PI);
                d.outline = [[tip] ~ ring ~ [tip]];
                return null;
            }
        case "3-point-arc":
            {
                if (pts.length < 3)
                {
                    d.outline = [[a, b]];
                    return "click a point on it";
                }
                auto m = pts[2];
                // the centre: as far from all three
                immutable den = 2 * (a.x * (b.y - m.y) + b.x * (m.y - a.y) + m.x * (a.y - b.y));
                if (abs(den) < 1e-9)
                    return "the three points are in a line: no arc goes through them";
                immutable a2 = a.dot(a), b2 = b.dot(b), m2 = m.dot(m);
                auto c = Vec3((a2 * (b.y - m.y) + b2 * (m.y - a.y) + m2 * (a.y - b.y)) / den,
                    (a2 * (m.x - b.x) + b2 * (a.x - m.x) + m2 * (b.x - a.x)) / den);
                d.center = Vec3(round(c.x * 100) / 100, round(c.y * 100) / 100);
                // counter-clockwise from start to end through the third, else the other way round
                double angleOf(Vec3 q) => atan2(q.y - c.y, q.x - c.x);
                double ccw(double from, double to)
                {
                    double x = to - from;
                    while (x < 0)
                        x += 2 * PI;
                    return x;
                }
                immutable through = ccw(angleOf(a), angleOf(m)) < ccw(angleOf(a), angleOf(b));
                d.uses = through ? [0, 1] : [1, 0];
                auto s0 = pts[d.uses[0]], s1 = pts[d.uses[1]];
                immutable a0 = angleOf(s0);
                d.outline = [arcPoints(c, (s0 - c).length, a0, a0 + ccw(a0, angleOf(s1)))];
                return null;
            }
        default:
            return "no such shape: " ~ tool;
        }
    }

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
        info(drawToolInfo(tool)[3] ~ " · Esc drops it");
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
        // an area is clicked inside: no point to snap to
        ptrdiff_t at = drawTool == "fill" ? -1 : snapAt(x, y, p);
        if (at == -1 && !onSketchPlane(x, y, p))
            return;
        // on the first point again: the lines or the curve close, and are written
        if (at == -2)
            return finishDrawing(true);
        // on the last point again (a double click): the lines or the curve end there; a shape takes no point twice
        if (drawn.length)
        {
            double lx, ly;
            if (viewport.project(drawnSketch().world(drawn[$ - 1]), lx, ly) && (lx - x) ^^ 2 + (ly - y) ^^ 2 < 100)
            {
                if (drawTool == "line" || drawTool == "spline")
                    return finishDrawing(false);
                return;
            }
        }
        drawn ~= p;
        drawnAt ~= at;
        if (drawn.length >= drawClicks(drawTool))
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
            case "center-rect", "turned-rect", "polygon", "slot", "ellipse", "teardrop", "3-point-arc":
                {
                    DrawnShape shape;
                    Vec3[][] lines;
                    if (shapeOf(drawTool, pts, polygonSides, shape) is null)
                        lines = shape.outline;
                    else
                        lines = [pts];   // too few clicks, or in a line: what is clicked
                    foreach (line; lines)
                    {
                        Vec3[] world;
                        foreach (q; line)
                            world ~= w(q);
                        viewport.drawingLines ~= world;
                    }
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
        info(writeDrawing(tool, pts, at, closed, drawConstruction));
    }

    /// The statements for what was drawn: new points made, those snapped to named.
    string writeDrawing(string tool, Vec3[] pts, ptrdiff_t[] at, bool closed, bool construction)
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
        // a point clicked twice in a row counts once
        {
            Vec3[] keptPts;
            ptrdiff_t[] keptAt;
            foreach (i, q; pts)
                if (i == 0 || (q - pts[i - 1]).length > 1e-6 || at[i] != at[i - 1])
                {
                    keptPts ~= q;
                    keptAt ~= at[i];
                }
            pts = keptPts;
            at = keptAt;
        }
        immutable clicks = drawClicks(tool);
        if (clicks != size_t.max && pts.length != clicks)
            return format("%s takes %d point%s", tool, clicks, clicks == 1 ? "" : "s");
        string select;
        try
        {
            auto w = SketchWriter(src, v.span.file, *v);
            w.construction = construction;
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
            case "center-rect", "turned-rect", "polygon", "slot", "ellipse", "teardrop", "3-point-arc":
                {
                    DrawnShape d;
                    if (auto why = shapeOf(tool, pts, polygonSides, d))
                        return why;
                    static string mm(double x) => format("%s.mm", num(x));
                    static string deg(double x) => format("%s.deg", num(x));
                    string[] use;
                    foreach (i; d.uses)
                        use ~= pointName(i);
                    string n;
                    switch (tool)
                    {
                    case "center-rect":
                        n = w.fresh("rect");
                        w.add(format("auto %s = %s.rect(center: %s, w: %s, h: %s)", n, w.var, use[0], mm(d.w), mm(d.h)));
                        break;
                    case "turned-rect":
                        n = w.fresh("rect");
                        w.add(format("auto %s = %s.rect(%s, w: %s, h: %s, angle: %s)", n, w.var, use[0], mm(d.w),
                            mm(d.h), deg(d.angle)));
                        break;
                    case "polygon":
                        n = w.fresh("polygon");
                        w.add(format("auto %s = %s.polygon(%s, %d, r: %s, angle: %s)", n, w.var, use[0], polygonSides,
                            mm(d.r), deg(d.angle)));
                        break;
                    case "slot":
                        n = w.fresh("slot");
                        w.add(format("auto %s = %s.slot(%s, %s, w: %s)", n, w.var, use[0], use[1], mm(d.w)));
                        break;
                    case "ellipse":
                        n = w.fresh("ellipse");
                        w.add(format("auto %s = %s.ellipse(%s, rx: %s, ry: %s, angle: %s)", n, w.var, use[0], mm(d.w),
                            mm(d.h), deg(d.angle)));
                        break;
                    case "teardrop":
                        n = w.fresh("teardrop");
                        w.add(format("auto %s = %s.teardrop(%s, r: %s)", n, w.var, use[0], mm(d.r)));
                        break;
                    default:   // 3-point-arc: its centre a new point, kept as far from both ends by the solver
                        immutable c = w.fresh("p");
                        w.add(format("auto %s = %s.point(%s, %s)", c, w.var, num(d.center.x), num(d.center.y)));
                        n = w.fresh("arc");
                        w.add(format("auto %s = %s.arc(%s, %s, %s)", n, w.var, c, use[0], use[1]));
                        break;
                    }
                    select = n;
                    break;
                }
            case "fill":
                {
                    auto q = pts[0];
                    ptrdiff_t region = -1;
                    foreach (k, r; v.regions)
                        if (r.holds(q))
                            region = k;
                    if (region < 0)
                        return "click inside a closed area of the sketch";
                    immutable full = !v.regions[region].full;
                    // fills already in that area: the last one turned, the others gone; else a new one
                    size_t[] here;
                    foreach (k, f; v.fills)
                        if (v.regions[region].holds(f.at))
                            here ~= k;
                    if (here.length == 0)
                    {
                        w.add(format("%s.fill(vec(%s, %s)%s)", w.var, num(q.x), num(q.y), full ? "" : ", full: false"));
                        select = format("%s.fill(vec(%s, %s)", w.var, num(q.x), num(q.y));
                        break;
                    }
                    import std.string : splitLines, KeepTerminator, indexOf;
                    auto lines = src.splitLines(KeepTerminator.yes);
                    foreach_reverse (k; here)
                    {
                        immutable l = v.fills[k].span.line;
                        if (v.fills[k].span.file != v.span.file || l == 0 || l > lines.length)
                            return format("the fill at line %d is not in this file: change it by hand", l);
                        auto line = lines[l - 1];
                        immutable open = line.indexOf(".fill(");
                        if (open < 0)
                            return format("line %d: change the fill there by hand", l);
                        if (k != here[$ - 1])
                        {
                            lines[l - 1] = "";
                            continue;
                        }
                        // its first argument as written, then full or not
                        size_t i = open + 6;
                        int depth;
                        while (i < line.length && !(depth == 0 && (line[i] == ',' || line[i] == ')')))
                        {
                            depth += line[i] == '(' || line[i] == '[' ? 1 : line[i] == ')' || line[i] == ']' ? -1 : 0;
                            i++;
                        }
                        auto end = i;
                        depth = 0;
                        while (end < line.length && !(depth == 0 && line[end] == ')'))
                        {
                            depth += line[end] == '(' ? 1 : line[end] == ')' ? -1 : 0;
                            end++;
                        }
                        lines[l - 1] = line[0 .. i] ~ (full ? "" : ", full: false") ~ line[end .. $];
                    }
                    import std.array : join;
                    sketchEditHold = true;
                    applyEdit(editBetween(src, lines.join));
                    return format("the area made %s: fill written in the sketch's code", full ? "full" : "empty");
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
            sketchEditHold = true;
            applyEdit(editBetween(src, w.result(), select));
        }
        catch (Exception e)
            return e.msg;
        return tool ~ " written in the sketch's code";
    }

    /// Deletes what is selected in the sketch from its code (see deleteFromSketch); what the info line says.
    /// The bar's ┄: the selection to construction geometry or back (toggleConstruction); with nothing
    /// selected, drawing as construction on or off. What the info line says.
    string constructionClicked()
    {
        if (sketchSel.length == 0)
        {
            drawConstruction = !drawConstruction;
            updateSketchBar();
            return drawConstruction ? "what you draw now is construction geometry: dashed guides, never filled (┄ again: "
                ~ "back to normal)" : "what you draw is normal geometry again";
        }
        return constructionSelection();
    }

    /// The selection to construction geometry, or back when all of it is; what the info line says.
    string constructionSelection()
    {
        import hackerscad.tool.sketchcode : toggleConstruction, editBetween;
        if (busy())
            return "wait for the evaluation to finish, then try again";
        auto v = drawnSketch();
        if (v is null)
            return "no sketch is drawn";
        immutable src = text();
        if (last.sources.get(absolutePath(path), null) != src)
            return "the code changed since it was evaluated: wait for it, then try again";
        string why;
        bool on;
        auto after = toggleConstruction(src, v.span.file, *v, sketchSel, why, on);
        if (after is null)
            return why;
        sketchEditHold = true;
        applyEdit(editBetween(src, after));
        return on ? "construction geometry now: dashed, out of what is filled and extruded (a shape's every side)"
            : "normal geometry again: part of the outline";
    }

    string deleteSelection()
    {
        import hackerscad.tool.sketchcode : deleteFromSketch, editBetween;
        if (sketchSel.length == 0)
            return "select what to delete first";
        if (busy())
            return "wait for the evaluation to finish, then try again";
        auto v = drawnSketch();
        if (v is null)
            return "no sketch is drawn";
        immutable src = text();
        if (last.sources.get(absolutePath(path), null) != src)
            return "the code changed since it was evaluated: wait for it, then try again";
        string why;
        auto after = deleteFromSketch(src, v.span.file, *v, sketchSel, why);
        if (after is null)
            return why;
        sketchEditHold = true;
        applyEdit(editBetween(src, after));
        immutable n = sketchSel.length;
        sketchSel = null;
        return format("%d deleted from the sketch's code, with what was drawn on %s and the constraints on them",
            n, n == 1 ? "it" : "them");
    }
}
