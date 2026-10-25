/// Annotations, the window's side: Annotate locks the 3D view (its camera
/// cannot move, and what it shows cannot change: a new result of the
/// model, the sketch at the cursor, Inspect, a step wait until it is
/// unlocked), and the user, or an agent through the control socket, marks
/// it up as a screenshot: arrows, crosses, circles, lines by hand, text.
/// Each point of a mark is kept as a model point where the view shows it,
/// so the marks stay on what they mark when the view is drawn at another
/// size (a panel closed, the window resized), and each mark notes what the
/// view shows under its key points (part, face, model point). Leaving
/// Annotate drops the marks and unlocks the view, the camera where it was.
/// Annotate is mixed into MainWindow (as ControlMethods is), so it uses the
/// window's members and imports as its own; it lives here only to keep
/// app.d to a readable size. The data and its rules are in
/// tool/annotations.
module hackerscad.gui.annotate;

mixin template Annotate()
{
    import cairo.context : Context;
    import cairo.types : Format, LineCap, LineJoin, FontSlant, FontWeight, TextExtents;
    import gtk.drawing_area : DrawingArea;
    import hackerscad.tool.annotations : AnnotationSet, Annotation, P, Under, Near, keyPoints, distanceTo, moveBy,
        lightColour, palette, colourNames, defaultColour, crossPixels;
    import core.time : msecs;

    AnnotationSet notes;           /// the marks on the view, the user's and the agents'
    ToggleButton annotateToggle;   /// in the view bar: on while the view is annotated
    Box annotateBar;
    Label annotateText;
    DrawingArea noteArea;          /// the marks, over the 3D view (and taking the pointer from it)
    bool frozen;                   /// the view is annotated, and locked
    Outcome heldOutcome;           /// a result of the model that came meanwhile, shown once unlocked
    bool haveHeld;
    bool userAnnotating;           /// the user turned Annotate on (not an agent)
    bool changedSinceFrozen;       /// a result of the model is waiting
    string noteTool = "arrow";
    uint noteColour = defaultColour;
    ToggleButton[string] toolButtons;
    MenuButton colourButton;
    Box colourSwatch;
    uint selectedNote;             /// 0: none
    double[2][uint] textBoxes;     /// each text's (and label's) size as drawn, for picking it
    bool settingToggle;            /// the toggle is being set from code

    // a mark being drawn or moved
    bool noteDrawing, noteMoving, noteDragged;
    double noteX0, noteY0;
    P[] draft;
    P[] movingFrom;
    uint lastNoteClick;
    MonoTime lastNoteClickAt;
    Entry noteEntry;

    enum strokePixels = 4.0;   /// how thick the marks are drawn

    /// The view bar's Annotate button, the bar shown while the view is
    /// annotated, and the layer the marks are drawn on.
    void buildAnnotate()
    {
        import gtk.image : Image;
        import gtk.gesture_drag : GestureDrag;
        annotateToggle = toggle("hcad-annotate-symbolic", "Annotate (A): mark points, arrows and sizes on the model "
            ~ "to show them, or to tell an agent where", false);
        annotateToggle.addCssClass("flat");
        annotateToggle.connectToggled(() {
            if (settingToggle)
                return;
            if (annotateToggle.getActive())
            {
                if (!lockView(true))
                {
                    settingToggle = true;
                    annotateToggle.setActive(false);
                    settingToggle = false;
                }
            }
            else
                unlockView();
        });

        // two rows, so that it is never wider than the view bar: what it says with Clear and
        // Close, then the tools and the colour
        annotateBar = new Box(Orientation.Vertical, 2);
        auto top = new Box(Orientation.Horizontal, 6);
        auto row = new Box(Orientation.Horizontal, 6);
        // centred: when the view is narrower than the view bar, the floating bars are cut at both
        // sides, and what is in the middle still shows
        top.setHalign(Align.Center);
        row.setHalign(Align.Center);
        annotateBar.append(top);
        annotateBar.append(row);
        annotateBar.addCssClass("hcad-modebar");
        annotateBar.addCssClass("hcad-annotatebar");
        auto icon = new Image;
        icon.setFromIconName("hcad-annotate-symbolic");
        top.append(icon);
        annotateText = new Label("");
        annotateText.setEllipsize(EllipsizeMode.End);
        annotateText.setXalign(0);
        annotateText.setWidthChars(10);
        annotateText.setMaxWidthChars(20);
        top.append(annotateText);
        auto tools = new Box(Orientation.Horizontal, 0);
        tools.addCssClass("linked");
        static immutable string[5] keys = ["arrow", "cross", "circle", "freehand", "text"];
        static immutable string[5] tips = ["Arrow: drag from the tail to the tip", "Cross: click the point to mark",
            "Circle: drag across the box it fits in", "Freehand: draw with the pointer", "Text: click where it goes, type, Enter"];
        ToggleButton first;
        foreach (i, key; keys)
        {
            auto b = toggle("hcad-mark-" ~ key ~ "-symbolic", tips[i], key == noteTool);
            if (first is null)
                first = b;
            else
                b.setGroup(first);
            toolButtons[key] = b;
            tools.append(b);
        }
        foreach (key; keys)
            toolButtons[key].connectToggled(toolChosen(key));
        row.append(tools);
        // the colour: a swatch, a menu of the others
        {
            import gtk.popover : Popover;
            colourButton = new MenuButton;
            colourButton.addCssClass("flat");
            colourButton.setTooltipText("The colour of the next mark (and of the one selected)");
            colourSwatch = new Box(Orientation.Horizontal, 0);
            colourSwatch.addCssClass("hcad-swatch");
            colourSwatch.addCssClass("hcad-mark-colour-0");
            colourButton.setChild(colourSwatch);
            auto grid = new Box(Orientation.Horizontal, 4);
            grid.setMarginStart(6);
            grid.setMarginEnd(6);
            grid.setMarginTop(6);
            grid.setMarginBottom(6);
            foreach (i; 0 .. palette.length)
                grid.append(swatchButton(i));
            auto pop = new Popover;
            pop.setChild(grid);
            colourButton.setPopover(pop);
            row.append(colourButton);
        }
        // the view with its marks as a picture, for a person (an agent reads them from the state)
        {
            auto keep = new Box(Orientation.Horizontal, 0);
            keep.addCssClass("linked");
            auto save = new Button;
            save.setIconName("document-save-symbolic");
            save.setTooltipText("Save the view with its marks as a PNG picture");
            save.connectClicked(() => saveAnnotated());
            auto copy = new Button;
            copy.setIconName("edit-copy-symbolic");
            copy.setTooltipText("Copy the view with its marks, to paste the picture in a message");
            copy.connectClicked(() { info(copyAnnotated() ? "the view with its marks is copied: paste it as a picture"
                : "the view could not be captured"); });
            keep.append(save);
            keep.append(copy);
            row.append(keep);
        }
        auto clear = new Button;
        clear.setLabel("Clear");
        clear.setTooltipText("Remove all the marks, yours and the agents'");
        clear.connectClicked(() => clearNotes(null));
        top.append(clear);
        auto done = new Button;
        done.setLabel("Close");
        done.setTooltipText("Back to the live view (Esc): the marks go, unless saved or copied first");
        done.addCssClass("suggested-action");
        done.connectClicked(() => unlockView());
        top.append(done);
        annotateBar.setVisible(false);

        noteArea = new DrawingArea;
        noteArea.setHexpand(true);
        noteArea.setVexpand(true);
        noteArea.setFocusable(true);
        noteArea.setDrawFunc((DrawingArea, Context cr, int w, int h) => drawNotes(cr, w, h));
        noteArea.setVisible(false);
        auto drag = new GestureDrag;
        drag.setButton(1);
        drag.connectDragBegin((double x, double y, GestureDrag g) => noteDragBegin(x, y));
        drag.connectDragUpdate((double dx, double dy, GestureDrag g) => noteDragUpdate(dx, dy));
        drag.connectDragEnd((double dx, double dy, GestureDrag g) => noteDragEnd(dx, dy));
        noteArea.addController(drag);
        auto right = new GestureClick;
        right.setButton(3);
        right.connectPressed((int n, double x, double y, GestureClick g) => noteMenu(x, y));
        noteArea.addController(right);
        auto keys2 = new EventControllerKey;
        keys2.connectKeyPressed((uint key, uint code, ModifierType state) {
            if (key == KEY_Escape)
            {
                if (noteDrawing || noteMoving)
                {
                    noteDrawing = noteMoving = false;
                    draft = null;
                    noteArea.queueDraw();
                }
                else if (selectedNote)
                {
                    selectedNote = 0;
                    noteArea.queueDraw();
                }
                else
                    unlockView();
                return true;
            }
            if ((key == KEY_Delete || key == KEY_BackSpace) && selectedNote)
            {
                removeNote(selectedNote);
                return true;
            }
            if ((key == KEY_a || key == KEY_A)
                && (state & (ModifierType.ControlMask | ModifierType.AltMask | ModifierType.MetaMask)) == 0)
            {
                unlockView();
                return true;
            }
            return false;
        });
        noteArea.addController(keys2);
    }

    /// A colour of the menu: a function of its own, so each button keeps its colour.
    /// The view as annotated, its marks drawn on it (not the bar over it), as
    /// a PNG picture; null when it cannot be had. The window as drawn when it
    /// is; hidden or covered (not drawn since), the 3D view drawn apart, as a
    /// screenshot does then, and the marks drawn on it.
    ubyte[] annotatedPng()
    {
        import gtk.widget_paintable : WidgetPaintable;
        import gtk.snapshot : Snapshot;
        immutable w = viewport.area.getWidth(), h = viewport.area.getHeight();
        if (w > 0 && h > 0)
        {
            auto snap = new Snapshot;
            new WidgetPaintable(viewport.area).snapshot(snap, w, h);
            if (noteArea.getVisible())
                new WidgetPaintable(noteArea).snapshot(snap, w, h);
            if (auto node = snap.toNode())
            {
                // let go on this thread (releaseNode, in app.d)
                scope (exit)
                    releaseNode(node);
                return window.getRenderer().renderTexture(node, null).saveToPngBytes().getData().dup;
            }
        }
        import cairo.global : imageSurfaceCreateFromPng, create;
        import hackerscad.render.png : encodePng;
        import std.file : read, remove, tempDir, write;
        import std.path : buildPath;
        import std.process : thisProcessID;
        immutable rw = max(640, w), rh = max(480, h);
        auto pixels = viewport.renderImage(rw, rh);
        if (pixels is null)
            return null;
        auto file = buildPath(tempDir, format("hcad-annotated-%d.png", thisProcessID));
        scope (exit)
            if (file.exists)
                remove(file);
        write(file, encodePng(pixels, rw, rh));
        auto surface = imageSurfaceCreateFromPng(file);
        drawNotes(create(surface), rw, rh);
        surface.flush();
        surface.writeToPng(file);
        return cast(ubyte[]) read(file);
    }

    /// Save (in the bar, "annotate" with save on the socket): the view with its
    /// marks written to a PNG file; the problem, or null.
    string writeAnnotated(string file)
    {
        auto picture = annotatedPng();
        if (picture is null)
            return "the view could not be drawn (is the screen locked?)";
        try
        {
            static import std.file;
            std.file.write(file, picture);
        }
        catch (Exception e)
            return "could not write " ~ file ~ ": " ~ e.msg;
        return null;
    }

    /// The bar's Save: where to save the picture, then saved there.
    void saveAnnotated()
    {
        import std.path : baseName, stripExtension;
        auto d = new FileDialog;
        d.setInitialName(baseName(path).stripExtension ~ "-annotated.png");
        d.save(window, null, (ObjectWrap src, AsyncResult res) {
            try
            {
                auto f = d.saveFinish(res);
                if (f is null)
                    return;
                auto problem = writeAnnotated(f.getPath());
                info(problem !is null ? problem : "saved " ~ f.getPath());
            }
            catch (ErrorWrap)
            {
            }
        });
    }

    /// Copy (in the bar, "annotate" with copy on the socket): the picture on
    /// the clipboard, as PNG; whether it could be had.
    bool copyAnnotated()
    {
        import gdk.content_provider : ContentProvider;
        import glib.bytes : Bytes;
        auto picture = annotatedPng();
        if (picture is null)
            return false;
        window.getClipboard().setContent(ContentProvider.newForBytes("image/png", new Bytes(picture)));
        return true;
    }

    Button swatchButton(size_t i)
    {
        auto b = new Button;
        b.addCssClass("flat");
        auto sw = new Box(Orientation.Horizontal, 0);
        sw.addCssClass("hcad-swatch");
        sw.addCssClass(format("hcad-mark-colour-%d", i));
        b.setChild(sw);
        b.setTooltipText(colourNames[i]);
        b.connectClicked(() {
            setNoteColour(palette[i]);
            colourButton.popdown();
        });
        return b;
    }

    void setNoteColour(uint rgb)
    {
        noteColour = rgb;
        foreach (k; 0 .. palette.length)
            colourSwatch.removeCssClass(format("hcad-mark-colour-%d", k));
        foreach (k, c; palette)
            if (c == rgb)
                colourSwatch.addCssClass(format("hcad-mark-colour-%d", k));
        if (auto n = notes.find(selectedNote))
        {
            n.colour = rgb;
            noteArea.queueDraw();
        }
    }

    void delegate() toolChosen(string key) => () {
        if (toolButtons[key].getActive())
            noteTool = key;
    };

    /// Locks the view to draw on it (true; false when there is no view to
    /// annotate). Whatever is under way that moves the view (moving a part,
    /// Place on…) is left first.
    bool lockView(bool byUser)
    {
        if (frozen)
        {
            userAnnotating = userAnnotating || byUser;
            return true;
        }
        if (viewport.area.getWidth() <= 0 || viewport.area.getHeight() <= 0 || !viewport.area.getVisible())
        {
            info("the 3D view is hidden: show it to annotate it");
            return false;
        }
        cancelTransform();
        if (noteEntry !is null)
        {
            overlay.removeOverlay(noteEntry);
            noteEntry = null;
        }
        viewport.lock(true);
        frozen = true;
        userAnnotating = byUser;
        changedSinceFrozen = false;
        selectedNote = 0;
        foreach (b; dimButtons)
            b.setVisible(false);   // they would change with the code: they come back once unlocked
        settingToggle = true;
        annotateToggle.setActive(true);
        settingToggle = false;
        noteArea.setVisible(true);
        annotateBar.setVisible(true);
        updateAnnotateBar();
        noteArea.queueDraw();
        noteArea.grabFocus();
        return true;
    }

    /// Back to the live view: the marks go, the camera stays where it was,
    /// and what changed meanwhile (a new result, the sketch at the cursor)
    /// shows.
    void unlockView()
    {
        if (noteEntry !is null)
        {
            overlay.removeOverlay(noteEntry);
            noteEntry = null;
        }
        notes.clear();
        immutable was = frozen;
        frozen = userAnnotating = noteDrawing = noteMoving = false;
        draft = null;
        selectedNote = 0;
        settingToggle = true;
        annotateToggle.setActive(false);
        settingToggle = false;
        noteArea.setVisible(false);
        annotateBar.setVisible(false);
        viewport.lock(false);
        // the camera stays where it was: no jump when the view comes back (the sketch at the
        // cursor shows once the cursor moves again)
        if (!sketchFollowing)
            disarmFollow();
        if (haveHeld)
        {
            haveHeld = false;
            fitNext = false;
            showOutcome(heldOutcome);
        }
        else if (was)
            positionDimensions();
        viewport.area.grabFocus();
    }

    /// A result of the model while the view is annotated: kept for later.
    bool holdOutcome(Outcome o)
    {
        if (!frozen)
            return false;
        heldOutcome = o;
        haveHeld = true;
        changedSinceFrozen = true;
        busyIndicator.stop();
        busyIndicator.setTooltipText(null);
        stopProgress();
        updateAnnotateBar();
        return true;
    }

    /// Something would change what the locked view shows: refused (`say`:
    /// with a word in the status line).
    bool sceneLocked(bool say = true)
    {
        if (!frozen)
            return false;
        if (say)
            info("the view is annotated: Close (or Esc in the view) goes back to the live view first");
        return true;
    }

    /// Removes all the marks (`by` null) or one author's; with none left,
    /// back to the live view, unless the user is annotating.
    void clearNotes(string by)
    {
        notes.clear(by);
        selectedNote = 0;
        if (notes.items.length == 0 && !userAnnotating)
            return unlockView();
        notesChanged();
    }

    void notesChanged()
    {
        updateAnnotateBar();
        noteArea.queueDraw();
    }

    void updateAnnotateBar()
    {
        immutable n = notes.items.length;
        auto text = n == 0 ? "Annotate · draw on the view" : format("Annotated · %d mark%s", n, n == 1 ? "" : "s");
        if (changedSinceFrozen)
            text ~= " · model changed";
        annotateText.setLabel(text);
        annotateText.setTooltipText("The view is locked while it is annotated (it cannot turn, and changes to the "
            ~ "model wait), so the marks stay on what they mark. Click a mark to select it (drag it to move it, Delete removes it), double-click it to "
            ~ "write on it, right-click it for its menu. Done or Esc goes back to the live view, without the marks "
            ~ "(and shows the model as it is now, when it changed meanwhile). "
            ~ "An agent reads the marks, and what lies under them, when you say \"here\"");
    }

    bool annotating() => frozen;

    // ---- what lies under a mark

    int viewW() => max(1, viewport.width);
    int viewH() => max(1, viewport.height);

    /// Mark n's points where the view shows its model points now.
    void projectNote(ref Annotation n)
    {
        if (n.at.length != n.points.length)
            return;
        foreach (i, a; n.at)
        {
            double x, y;
            if (viewport.project(a, x, y))
                n.points[i] = P(x / viewW, y / viewH);
        }
    }

    /// Mark n's points kept as model points the view shows there.
    void anchorNote(ref Annotation n)
    {
        n.at = null;
        foreach (p; n.points)
            n.at ~= viewport.planePoint(p.x * viewW, p.y * viewH);
    }

    /// Every mark's points where the view shows them now (its size may have changed).
    void refreshNotes()
    {
        foreach (ref n; notes.items)
            projectNote(n);
    }

    /// What the view shows at p.
    Under underAt(P p)
    {
        Under u;
        u.at = p;
        auto hit = viewport.pickShown(p.x * viewW, p.y * viewH);
        if (hit.part < 0 || hit.part >= last.parts.length)
            return u;
        auto j = hitJson(hit);
        u.part = last.parts[hit.part].name;
        u.face = hit.face;
        u.point = hit.point;
        u.normal = hit.normal;
        if (j.has("selector") && j["selector"].isString)
            u.selector = j["selector"].get!string;
        return u;
    }

    /// What lies under mark n's key points, and its points as model points;
    /// a point on the background, the surface it points at.
    void findUnder(ref Annotation n)
    {
        import hackerscad.tool.annotations : searchFrom;
        anchorNote(n);
        n.under = null;
        foreach (k, p; keyPoints(n))
        {
            auto u = underAt(p);
            if (u.part.length == 0)
            {
                double dx, dy, reach;
                searchFrom(n, k, viewW, viewH, dx, dy, reach);
                u.near = nearestTo(p, dx, dy, reach);
            }
            n.under ~= u;
        }
    }

    /// The surface the view shows nearest p (on the background): first
    /// along (dx, dy) up to twice `reach` pixels (ahead of an arrow), else
    /// on rings round p up to `reach`.
    Near nearestTo(P p, double dx, double dy, double reach)
    {
        import std.math : PI, cos, sin, ceil;
        import hackerscad.tool.annotations : Near;
        immutable x0 = p.x * viewW, y0 = p.y * viewH;
        Near found(double x, double y, double pixels, bool ahead)
        {
            Near r;
            auto hit = viewport.pickShown(x, y);
            if (hit.part < 0 || hit.part >= last.parts.length)
                return r;
            auto j = hitJson(hit);
            r = Near(last.parts[hit.part].name, hit.face, hit.point, hit.normal,
                j.has("selector") && j["selector"].isString ? j["selector"].get!string : null, pixels, ahead);
            return r;
        }
        if (dx != 0 || dy != 0)
            for (double t = 3; t <= 2 * reach; t += 3)
            {
                auto r = found(x0 + dx * t, y0 + dy * t, t, true);
                if (r.part.length)
                    return r;
            }
        for (double rad = 4; rad <= reach; rad += 4)
        {
            immutable steps = cast(int) max(8.0, ceil(2 * PI * rad / 6));
            foreach (i; 0 .. steps)
            {
                immutable a = 2 * PI * i / steps;
                auto r = found(x0 + rad * cos(a), y0 + rad * sin(a), rad, false);
                if (r.part.length)
                    return r;
            }
        }
        return Near.init;
    }

    /// Where the view shows a model point; false when behind the camera.
    bool viewPointOf(Vec3 v, out P p)
    {
        double x, y;
        if (!viewport.project(v, x, y))
            return false;
        p = P(x / viewW, y / viewH);
        return true;
    }

    /// The control socket's points that are not in the view's terms:
    /// [x, y, z] mm, a part's name (its centre of mass, and its box for a
    /// circle round it), {"part": name, "face": i} (the face's centre).
    string readNotePoint(JValue v, out P p, out P[2] box, out bool hasBox)
    {
        import hackerscad.tool.annotations : pointHelp;
        if (v.isArray && v.length == 3)
        {
            if (!viewPointOf(vec3Of(v), p))
                return "that point is behind the camera";
            return null;
        }
        string part;
        int face = -1;
        if (v.isString)
            part = v.get!string;
        else if (v.isObject && v.has("part") && v["part"].isString)
        {
            part = v["part"].get!string;
            if (v.has("face") && !v["face"].isNull)
                face = cast(int) numberOf(v["face"]);
        }
        else
            return pointHelp;
        string problem;
        immutable index = partIndex(part, problem);
        if (index < 0 || part.length == 0)
            return problem.length ? problem : "say which part";
        auto pm = last.parts[index];
        if (pm.kernel is null || pm.brep is null)
            return "part '" ~ part ~ "' has no solid";
        Vec3 at;
        if (face < 0)
        {
            at = pm.kernel.massProps(pm.brep).centroid;
            double[4] r;
            if (viewport.partRect(index, r))
            {
                box = [P(r[0] / viewW, r[1] / viewH), P(r[2] / viewW, r[3] / viewH)];
                hasBox = true;
            }
        }
        else
        {
            auto fs = pm.kernel.faces(pm.brep);
            if (face >= fs.length)
                return format("part '%s' has no face %d", part, face);
            at = fs[face].center;
        }
        if (!viewPointOf(at, p))
            return "that point is behind the camera";
        return null;
    }

    // ---- drawing

    static void rgb(Context cr, uint c, double alpha = 1)
    {
        cr.setSourceRgba(((c >> 16) & 255) / 255.0, ((c >> 8) & 255) / 255.0, (c & 255) / 255.0, alpha);
    }

    /// The path drawn three times: a soft shadow, a halo that sets it off
    /// any background (white, or dark round a light colour), the colour.
    void inks(Context cr, uint colour, double width, bool fill, void delegate() path)
    {
        cr.setLineJoin(LineJoin.Round);
        cr.setLineCap(LineCap.Round);
        immutable light = lightColour(colour);
        // the shadow, a little down and right
        cr.save();
        cr.translate(0.8, 1.4);
        cr.newPath();
        path();
        cr.setSourceRgba(0, 0, 0, 0.22);
        cr.setLineWidth(width + 3);
        if (fill)
            cr.fillPreserve();
        cr.stroke();
        cr.restore();
        // the halo
        cr.newPath();
        path();
        if (light)
            cr.setSourceRgba(0.1, 0.1, 0.12, 0.85);
        else
            cr.setSourceRgba(1, 1, 1, 0.95);
        cr.setLineWidth(width + 3);
        cr.stroke();
        // the colour
        cr.newPath();
        path();
        rgb(cr, colour);
        if (fill)
            cr.fill();
        else
        {
            cr.setLineWidth(width);
            cr.stroke();
        }
    }

    /// An arrow from (x0, y0) to its tip (x1, y1): a shaft that widens
    /// towards a filled head, whose size follows the stroke.
    void arrowPath(Context cr, double x0, double y0, double x1, double y1, double s)
    {
        import std.math : sqrt;
        immutable dx = x1 - x0, dy = y1 - y0, len = sqrt(dx * dx + dy * dy);
        if (len < 1)
            return;
        immutable ux = dx / len, uy = dy / len, vx = -uy, vy = ux;
        immutable hl = min(len * 0.6, s * 5.5), hw = hl * 0.5;     // the head's length and half width
        immutable t0 = s * 0.38, t1 = s * 0.72;                    // the shaft's half width at the tail, at the head
        immutable notch = hl * 0.8;                                // where the shaft meets the head
        void at(double u, double v, bool first = false)
        {
            immutable x = x0 + ux * u + vx * v, y = y0 + uy * u + vy * v;
            if (first)
                cr.moveTo(x, y);
            else
                cr.lineTo(x, y);
        }
        at(0, -t0, true);
        at(len - notch, -t1);
        at(len - hl, -hw);
        at(len, 0);
        at(len - hl, hw);
        at(len - notch, t1);
        at(0, t0);
        cr.closePath();
    }

    /// Draws mark n (in view pixels of a w × h area): its shape, or its
    /// text (drawn after all the shapes, so that none covers a text).
    void drawNote(Context cr, const Annotation n, double w, double h, bool textPass)
    {
        import std.math : PI, sqrt, abs;
        if (n.points.length == 0)
            return;
        immutable s = strokePixels;
        double X(P p) => p.x * w;
        double Y(P p) => p.y * h;
        if (!textPass)
            switch (n.kind)
        {
        case "arrow":
            if (n.points.length >= 2)
                inks(cr, n.colour, 1.0, true, () => arrowPath(cr, X(n.points[0]), Y(n.points[0]), X(n.points[1]), Y(n.points[1]), s));
            break;
        case "cross":
            {
                immutable x = X(n.points[0]), y = Y(n.points[0]), r0 = 3.0, r1 = crossPixels;
                inks(cr, n.colour, s * 0.8, false, () {
                    foreach (d; [[1, 0], [-1, 0], [0, 1], [0, -1]])
                    {
                        cr.moveTo(x + d[0] * r0, y + d[1] * r0);
                        cr.lineTo(x + d[0] * r1, y + d[1] * r1);
                    }
                });
                break;
            }
        case "circle":
            if (n.points.length >= 2)
            {
                immutable cx = (X(n.points[0]) + X(n.points[1])) / 2, cy = (Y(n.points[0]) + Y(n.points[1])) / 2;
                immutable rx = max(2.0, abs(X(n.points[1]) - X(n.points[0])) / 2), ry = max(2.0, abs(Y(n.points[1]) - Y(n.points[0])) / 2);
                inks(cr, n.colour, s, false, () {
                    cr.save();
                    cr.translate(cx, cy);
                    cr.scale(rx, ry);
                    cr.arc(0, 0, 1, 0, 2 * PI);
                    cr.restore();
                });
            }
            break;
        case "freehand":
            inks(cr, n.colour, s, false, () {
                foreach (i, p; n.points)
                    if (i == 0)
                        cr.moveTo(X(p), Y(p));
                    else
                        cr.lineTo(X(p), Y(p));
            });
            break;
        default:
            break;
        }
        if (!textPass || n.text.length == 0)
            return;
        // the text: bold, on a halo; a text mark at its point, a label beside its mark
        cr.selectFontFace("Sans", FontSlant.Normal, FontWeight.Bold);
        cr.setFontSize(n.kind == "text" ? 18 : 15);
        TextExtents e;
        cr.textExtents(n.text, e);
        double tx, ty;   // the top left of the text
        auto p0 = n.points[0];
        switch (n.kind)
        {
        case "arrow":
            {
                // beyond the tail, away from the tip
                immutable dx = X(n.points[1]) - X(p0), dy = Y(n.points[1]) - Y(p0), len = max(1.0, sqrt(dx * dx + dy * dy));
                immutable ux = -dx / len, uy = -dy / len;
                immutable cx = X(p0) + ux * (e.width / 2 + 8), cy = Y(p0) + uy * (e.height / 2 + 8);
                tx = cx - e.width / 2;
                ty = cy - e.height / 2;
                break;
            }
        case "circle":
            tx = max(X(n.points[0]), X(n.points[1])) - abs(X(n.points[1]) - X(n.points[0])) * 0.15 + 4;
            ty = min(Y(n.points[0]), Y(n.points[1])) - e.height - 2;
            break;
        case "cross":
            tx = X(p0) + crossPixels + 5;
            ty = Y(p0) - crossPixels - e.height;
            break;
        case "freehand":
            tx = X(n.points[$ - 1]) + 8;
            ty = Y(n.points[$ - 1]) - e.height - 4;
            break;
        default:
            tx = X(p0);
            ty = Y(p0);
            break;
        }
        // inside the view
        tx = max(4.0, min(w - e.width - 4, tx));
        ty = max(4.0, min(h - e.height - 4, ty));
        if (n.kind == "text")
            textBoxes[n.id] = [e.width + 2, e.height + 2];
        immutable bx = tx - e.xBearing, by = ty - e.yBearing;
        cr.newPath();
        cr.moveTo(bx, by);
        cr.textPath(n.text);
        cr.setLineJoin(LineJoin.Round);
        if (lightColour(n.colour))
            cr.setSourceRgba(0.1, 0.1, 0.12, 0.85);
        else
            cr.setSourceRgba(1, 1, 1, 0.95);
        cr.setLineWidth(4);
        cr.strokePreserve();
        rgb(cr, n.colour);
        cr.fill();
    }

    /// The marks, the one being drawn, the one selected.
    void drawNotes(Context cr, int w, int h)
    {
        if (!frozen)
            return;
        refreshNotes();
        foreach (textPass; [false, true])
            foreach (n; notes.items)
                drawNote(cr, n, w, h, textPass);
        if (noteDrawing && draft.length >= 2)
        {
            Annotation d;
            d.kind = noteTool;
            d.points = draft;
            d.colour = noteColour;
            drawNote(cr, d, w, h, false);
        }
        // the selected one: a dashed box round it
        if (auto n = notes.find(selectedNote))
        {
            double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
            foreach (p; n.points)
            {
                x0 = min(x0, p.x * w);
                y0 = min(y0, p.y * h);
                x1 = max(x1, p.x * w);
                y1 = max(y1, p.y * h);
            }
            if (n.kind == "text" && n.id in textBoxes)
            {
                x1 = x0 + textBoxes[n.id][0];
                y1 = y0 + textBoxes[n.id][1];
            }
            immutable m = n.kind == "cross" ? crossPixels + 5 : 8;
            cr.newPath();
            cr.rectangle(x0 - m, y0 - m, x1 - x0 + 2 * m, y1 - y0 + 2 * m);
            cr.setLineWidth(1.5);
            cr.setDash([5.0, 4.0], 0);
            cr.setSourceRgba(1, 1, 1, 0.9);
            cr.strokePreserve();
            cr.setDash([5.0, 4.0], 4.5);
            cr.setSourceRgba(0.1, 0.1, 0.12, 0.9);
            cr.stroke();
            cr.setDash([], 0);
        }
    }

    // ---- the pointer on the view

    /// The mark under view point (x, y): its id, or 0.
    uint noteAt(double x, double y)
    {
        immutable w = noteArea.getWidth(), h = noteArea.getHeight();
        uint best;
        double bestD = 8;
        foreach_reverse (n; notes.items)
        {
            auto tb = n.id in textBoxes;
            immutable d = distanceTo(n, x, y, w, h, tb ? (*tb)[0] : 0, tb ? (*tb)[1] : 0);
            if (d < bestD)
            {
                bestD = d;
                best = n.id;
            }
        }
        return best;
    }

    void noteDragBegin(double x, double y)
    {
        noteArea.grabFocus();
        noteX0 = x;
        noteY0 = y;
        noteDragged = false;
        immutable id = noteAt(x, y);
        if (id)
        {
            selectedNote = id;
            noteMoving = true;
            auto n = notes.find(id);
            projectNote(*n);
            movingFrom = n.points.dup;
            n.at = null;   // moved on screen; kept as model points again once dropped
        }
        else
        {
            selectedNote = 0;
            noteDrawing = true;
            immutable w = noteArea.getWidth(), h = noteArea.getHeight();
            draft = [P(x / w, y / h)];
        }
        noteArea.queueDraw();
    }

    void noteDragUpdate(double dx, double dy)
    {
        import std.math : abs;
        if (!noteDragged && abs(dx) + abs(dy) < 3)
            return;
        noteDragged = true;
        immutable w = noteArea.getWidth(), h = noteArea.getHeight();
        auto at = P((noteX0 + dx) / w, (noteY0 + dy) / h);
        if (noteMoving)
        {
            if (auto n = notes.find(selectedNote))
                foreach (i, ref p; n.points)
                    p = P(movingFrom[i].x + dx / w, movingFrom[i].y + dy / h);
        }
        else if (noteDrawing)
        {
            if (noteTool == "freehand")
            {
                auto last_ = draft[$ - 1];
                if (abs(last_.x - at.x) * w + abs(last_.y - at.y) * h > 2)
                    draft ~= at;
            }
            else if (noteTool == "arrow" || noteTool == "circle")
                draft = [draft[0], at];
        }
        noteArea.queueDraw();
    }

    void noteDragEnd(double dx, double dy)
    {
        immutable w = noteArea.getWidth(), h = noteArea.getHeight();
        if (noteMoving)
        {
            noteMoving = false;
            if (auto n = notes.find(selectedNote))
            {
                if (noteDragged)
                    findUnder(*n);
                else
                {
                    anchorNote(*n);
                    // a second click on it: write on it
                    immutable now = MonoTime.currTime;
                    if (lastNoteClick == n.id && now - lastNoteClickAt < 450.msecs)
                    {
                        lastNoteClick = 0;
                        editNoteText(n.id, noteX0, noteY0);
                    }
                    else
                    {
                        lastNoteClick = n.id;
                        lastNoteClickAt = now;
                    }
                }
            }
            notesChanged();
            return;
        }
        if (!noteDrawing)
            return;
        noteDrawing = false;
        Annotation n;
        n.kind = noteTool;
        n.by = "user";
        n.colour = noteColour;
        if (!noteDragged)
        {
            draft = null;
            if (noteTool == "cross")
                n.points = [P(noteX0 / w, noteY0 / h)];
            else if (noteTool == "text")
                return editNoteText(0, noteX0, noteY0);
            else
                return noteArea.queueDraw();
        }
        else
        {
            if (noteTool == "cross")
                n.points = [P((noteX0 + dx) / w, (noteY0 + dy) / h)];
            else if (noteTool == "text")
            {
                draft = null;
                return editNoteText(0, noteX0, noteY0);
            }
            else
                n.points = draft;
            draft = null;
        }
        findUnder(n);
        notes.add(n);
        notesChanged();
    }

    void removeNote(uint id)
    {
        if (notes.remove(id))
        {
            if (selectedNote == id)
                selectedNote = 0;
            notesChanged();
        }
    }

    /// The menu of a right click: a mark's own (write on it, delete it), or the view's.
    void noteMenu(double x, double y)
    {
        immutable id = noteAt(x, y);
        MenuEntry[] entries;
        if (id)
        {
            selectedNote = id;
            noteArea.queueDraw();
            auto n = notes.find(id);
            entries ~= MenuEntry.heading(n.kind.toUpper, n.by == "agent" ? "by an agent" : "yours");
            entries ~= MenuEntry.item(n.kind == "text" ? "Edit text…" : n.text.length ? "Edit label…" : "Add label…",
                () => editNoteText(id, x, y));
            entries ~= MenuEntry.item("Delete", () => removeNote(id));
            entries ~= MenuEntry.separator();
        }
        if (notes.items.length)
            entries ~= MenuEntry.item("Clear all marks", () => clearNotes(null));
        entries ~= MenuEntry.item("Back to the live view", () => unlockView());
        contextPopover = popupMenu(noteArea, x, y, entries);
    }

    /// A field at (x, y) to write a text (id 0: a new text mark there) or a
    /// mark's label: Enter or a click elsewhere keeps it, Esc does not.
    void editNoteText(uint id, double x, double y)
    {
        import gtk.event_controller_focus : EventControllerFocus;
        if (noteEntry !is null)
            overlay.removeOverlay(noteEntry);
        auto n = id ? notes.find(id) : null;
        if (id && n is null)
            return;
        immutable w = noteArea.getWidth(), h = noteArea.getHeight();
        auto entry = new Entry;
        noteEntry = entry;
        entry.addCssClass("hcad-dimension-entry");
        entry.setText(n !is null ? n.text : "");
        entry.setPlaceholderText(n is null || n.kind == "text" ? "text" : "label");
        immutable chars = cast(int) max(14, (n !is null ? n.text.length : 0) + 2);
        entry.setWidthChars(chars);
        entry.setMaxWidthChars(chars);
        entry.setHalign(Align.Start);
        entry.setValign(Align.Start);
        entry.setMarginStart(max(0, cast(int) x - 4));
        entry.setMarginTop(max(0, cast(int) y - 13));
        overlay.addOverlay(entry);
        bool done;
        void finish(bool keep)
        {
            if (done)
                return;
            done = true;
            immutable value = entry.getText();
            idleAdd(PRIORITY_DEFAULT, () {
                overlay.removeOverlay(entry);
                if (noteEntry is entry)
                    noteEntry = null;
                if (keep && frozen)
                {
                    if (id == 0 && value.length)
                    {
                        Annotation t;
                        t.kind = "text";
                        t.by = "user";
                        t.text = value;
                        t.colour = noteColour;
                        t.points = [P(x / w, y / h)];
                        findUnder(t);
                        notes.add(t);
                    }
                    else if (auto m = notes.find(id))
                    {
                        if (m.kind == "text" && value.length == 0)
                            notes.remove(id);
                        else
                            m.text = value;
                    }
                }
                notesChanged();
                if (frozen)
                    noteArea.grabFocus();
                return false;
            });
        }
        entry.connectActivate(() => finish(true));
        auto keys = new EventControllerKey;
        keys.connectKeyPressed((uint key, uint code, ModifierType state) {
            if (key != KEY_Escape)
                return false;
            finish(false);
            return true;
        });
        entry.addController(keys);
        auto focus = new EventControllerFocus;
        focus.connectLeave(() => finish(true));
        entry.addController(focus);
        entry.grabFocus();
    }

    /// The annotations for the state, and whether the view is annotated.
    void annotationsState(ref JValue j)
    {
        refreshNotes();
        j["annotations"] = notes.toJson();
        j["annotate_mode"] = frozen;
        if (frozen)
        {
            JValue v = JSOB("width", viewW, "height", viewH);
            v["model_changed"] = changedSinceFrozen;
            j["annotated_view"] = v;
        }
    }
}
