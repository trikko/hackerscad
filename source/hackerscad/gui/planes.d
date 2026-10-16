/// Planes in the 3D view, to draw a sketch on: PlaneTools, mixed into
/// MainWindow (as SketchEdit is), so it uses the window's members and
/// imports as its own.
///
/// The view bar's planes button (and View › Show planes) shows XY, XZ and YZ
/// and the planes the code keeps in variables: a
/// click picks one, its right-click menu writes a sketch on it into the
/// code. New sketch… (View menu) draws on the face or plane picked, or,
/// with neither, shows the planes and waits for a click on one (or on a
/// flat face); Esc gives up.
module hackerscad.gui.planes;

mixin template PlaneTools()
{
    import hackerscad.lang.interp : PlaneMade;

    ToggleButton planesToggle;    /// the view bar's: planes shown
    bool sketchOnNextPlane;       /// New sketch… with nothing picked: the next plane or flat face clicked gets it
    PlaneMade[] codePlanes;       /// the code's, for the shown planes past the main three

    enum mainPlanes = 3;

    /// The view bar's button.
    ToggleButton buildPlanesToggle()
    {
        planesToggle = toggle("hcad-planes-symbolic", "Planes: show XY, XZ, YZ and the code's planes, to draw a sketch "
            ~ "on one (click it, then right-click: Sketch on plane…)", false);
        planesToggle.addCssClass("flat");
        planesToggle.connectToggled(() {
            immutable on = planesToggle.getActive();
            if (on)
                refreshPlanes();
            else
                sketchOnNextPlane = false;
            viewport.showPlanes(on);
        });
        return planesToggle;
    }

    /// Shows or hides the planes.
    void setPlanesShown(bool on)
    {
        if (planesToggle.getActive() != on)
            planesToggle.setActive(on);
    }

    /// The planes to show: the main ones, then each one the code kept in a
    /// variable (once per place, named after it), up to 24.
    void refreshPlanes()
    {
        alias SP = Viewport.ShownPlane;
        auto o = Vec3(0, 0, 0);
        SP[] ps = [SP("XY", o, Vec3(0, 0, 1), true), SP("XZ", o, Vec3(0, -1, 0), true), SP("YZ", o, Vec3(1, 0, 0), true)];
        codePlanes = null;
        foreach (p; last.planes)
        {
            if (codePlanes.length >= 24)
                break;
            bool seen;
            foreach (q; ps)
                if (abs((p.origin - q.origin).dot(q.normal)) < 1e-6 && abs(abs(p.normal.dot(q.normal)) - 1) < 1e-9)
                    seen = true;
            if (seen)
                continue;   // a main plane (XZ.flip), or one made already
            codePlanes ~= p;
            ps ~= SP(p.name, p.origin, p.normal, false);
        }
        viewport.setPlanes(ps);
    }

    /// The function of the open file whose lines hold `line`, or null (at module level).
    string functionAtLine(uint line)
    {
        foreach (f; last.functions)
            if (line >= f.first && line <= f.end)
                return f.name;
        return null;
    }

    /// The part of the open file whose function holds the cursor, or null.
    string cursorPart()
    {
        TextIter it;
        buffer.getIterAtMark(it, buffer.getInsert());
        auto fn = functionAtLine(it.getLine() + 1);
        if (fn is null)
            return null;
        foreach (p; last.parts)
            if (p.fn == fn && p.span.file == absolutePath(path))
                return fn;
        return null;
    }

    /// The code of shown plane i for a sketch in part `part` (null: a new
    /// one): XY, XZ, YZ; a variable the part can see (of the module or of
    /// that part); else the plane written out.
    string planeCodeFor(int i, string part)
    {
        if (i < mainPlanes)
            return viewport.planes[i].name;
        auto p = codePlanes[i - mainPlanes];
        auto fn = functionAtLine(p.span.line);
        if (fn is null || (part !is null && fn == part))
            return p.name;
        static string n(double x) => format("%g", abs(x) < 1e-9 ? 0 : x);
        return format("plane(origin: vec(%s, %s, %s), normal: vec(%s, %s, %s))", n(p.origin.x), n(p.origin.y), n(p.origin.z),
            n(p.normal.x), n(p.normal.y), n(p.normal.z));
    }

    /// Sketch on plane i: the code of an empty sketch on it, in the part the
    /// cursor is in, or in a new part; the problem, or null.
    string sketchOnPlaneOf(int i)
    {
        if (busy())
            return "wait for the evaluation to finish, then try again";
        if (i < 0 || i >= viewport.planes.length)
            return "no such plane";
        immutable part = cursorPart();
        try
        {
            import hackerscad.tool.codegen : sketchOnPlane;
            applyEdit(sketchOnPlane(text(), path, part, planeCodeFor(i, part)));
        }
        catch (CodegenException e)
            return e.msg;
        sketchOnNextPlane = false;
        viewport.pickPlane(-1);
        viewport.setSelection(null);
        setPlanesShown(false);
        // the sketch shows as soon as the cursor, on its line, has it evaluated
        followArmed = true;
        info(part is null ? "a new part: draw the sketch, its profile is extruded 5 mm" : "");
        return null;
    }

    /// New sketch…: on the flat face or the plane picked; with neither, the
    /// planes shown and the next click on one (or on a flat face) draws there.
    string newSketch()
    {
        auto sel = viewport.selection();
        if (sel.length == 1 && sel[0].face >= 0 && sel[0].edge < 0 && canSketchOn(sel[0].part, sel[0].face))
            return sketchOnFaceOf(sel[0].part, sel[0].face);
        if (viewport.planesOn && viewport.pickedPlane >= 0)
            return sketchOnPlaneOf(viewport.pickedPlane);
        setPlanesShown(true);
        sketchOnNextPlane = true;
        return "click a plane, or a flat face, to draw a sketch on it (Esc: none)";
    }

    /// Esc while New sketch… waits for a click: it gives up.
    bool planeEscape()
    {
        if (!sketchOnNextPlane)
            return false;
        sketchOnNextPlane = false;
        setPlanesShown(false);
        info("");
        return true;
    }

    /// A click on a plane (or, New sketch… waiting, on a flat face): picked,
    /// or the sketch written. True when handled.
    bool planePicked(Hit hit)
    {
        if (hit.plane >= 0)
        {
            if (sketchOnNextPlane)
            {
                if (auto problem = sketchOnPlaneOf(hit.plane))
                    info(problem);
                return true;
            }
            viewport.setSelection(null);
            viewport.pickPlane(viewport.pickedPlane == hit.plane ? -1 : hit.plane);
            if (viewport.pickedPlane >= 0)
                info(format("plane %s: right-click it for Sketch on plane…", viewport.planes[hit.plane].name));
            else
                info("");
            return true;
        }
        if (sketchOnNextPlane && hit.part >= 0 && hit.face >= 0 && canSketchOn(hit.part, hit.face))
        {
            sketchOnNextPlane = false;
            setPlanesShown(false);
            if (auto problem = sketchOnFaceOf(hit.part, hit.face))
                info(problem);
            return true;
        }
        if (viewport.pickedPlane >= 0)
            viewport.pickPlane(-1);
        return false;
    }

    /// The right-click menu of plane i.
    MenuEntry[] planeMenu(int i)
    {
        immutable index = i;
        return [MenuEntry.heading("PLANE " ~ viewport.planes[i].name),
            MenuEntry.item("Sketch on plane…", () {
                if (auto problem = sketchOnPlaneOf(index))
                    info(problem);
            }),
            MenuEntry.item("Offset plane…", () {
                if (auto problem = offsetPlane(index))
                    info(problem);
            }),
            MenuEntry.item("Hide planes", () => setPlanesShown(false))];
    }

    /// The planes shown, for agents: name, a point, the normal, picked; and
    /// whether New sketch… waits for a click on one.
    JValue planesJson()
    {
        JValue r = JSAB();
        foreach (i, p; viewport.planes)
        {
            JValue j = JSOB("name", p.name, "main", p.main);
            j["origin"] = toJSON([p.origin.x, p.origin.y, p.origin.z]);
            j["normal"] = toJSON([p.normal.x, p.normal.y, p.normal.z]);
            if (!p.main)
                j["line"] = codePlanes[i - mainPlanes].span.line;
            if (i == viewport.pickedPlane)
                j["picked"] = true;
            r ~= j;
        }
        JValue w = JSOB("shown", r);
        w["waiting_for_click"] = sketchOnNextPlane;
        return w;
    }

    /// Shown plane called `name`, or -1.
    int planeNamed(string name)
    {
        foreach (i, p; viewport.planes)
            if (p.name == name)
                return cast(int) i;
        return -1;
    }

    /// Writes a plane into part `part` (null: the module), its code `expr`
    /// (%BODY%: the part's solid), `placeholder` selected; the planes shown
    /// so it shows. The problem, or null.
    string writePlane(string part, string expr, string placeholder)
    {
        if (busy())
            return "wait for the evaluation to finish, then try again";
        try
        {
            import hackerscad.tool.codegen : planeVariable;
            applyEdit(planeVariable(text(), path, part, expr, placeholder));
        }
        catch (CodegenException e)
            return e.msg;
        setPlanesShown(true);
        info(placeholder.length ? "type the distance; the new plane shows in violet: right-click it to sketch on it"
            : "the new plane shows in violet: right-click it to sketch on it");
        return null;
    }

    /// The part of the open file `index` is, whole (not a piece of @parts), or null.
    string wholePartFn(int index)
    {
        if (index < 0 || index >= last.parts.length || isPiece(index))
            return null;
        auto part = last.parts[index];
        return part.span.file == absolutePath(path) ? part.fn : null;
    }

    /// Plane on face…: the plane of one flat face, moved off it; Plane
    /// between faces: halfway between two that face each other.
    string planeOnFaces(int index, int[] faces)
    {
        auto fn = wholePartFn(index);
        if (fn is null)
            return "a plane on faces goes in a whole part of this file (not a piece of @parts)";
        import hackerscad.gui.measure : faceItem;
        foreach (f; faces)
            if (!faceItem(last.parts[index], f).planar)
                return "a plane goes on flat faces";
        SolidVal sv;
        auto it = selectorInterp(last.parts[index], sv);
        try
        {
            if (faces.length == 1)
                return writePlane(fn, "%BODY%.plane(" ~ facesSelector(it, sv, faces) ~ ").offset(5.mm)", "5.mm");
            auto a = faceItem(last.parts[index], faces[0]).normal, b = faceItem(last.parts[index], faces[1]).normal;
            if (abs(abs(a.dot(b)) - 1) > 1e-6)
                return "the two faces are not parallel: no plane lies halfway between them";
            return writePlane(fn, "%BODY%.plane(" ~ facesSelector(it, sv, faces[0 .. 1]) ~ ", "
                ~ facesSelector(it, sv, faces[1 .. 2]) ~ ")", null);
        }
        catch (HcadError e)
            return "fix the errors in the code first: " ~ e.msg;
    }

    /// Plane through points: three corners, as coordinates.
    string planeThroughVertices(int index, int[] vertices)
    {
        static string mm(double v) => format("%g.mm", abs(v) < 1e-9 ? 0 : v);
        string[] pts;
        Vec3[] at;
        foreach (v; vertices)
        {
            auto q = viewport.vertexAt(index, v);
            at ~= q;
            pts ~= format("vec(%s, %s, %s)", mm(q.x), mm(q.y), mm(q.z));
        }
        if ((at[1] - at[0]).cross(at[2] - at[0]).length < 1e-9)
            return "the three points are on one line: they do not define a plane";
        auto fn = wholePartFn(index);
        return writePlane(fn !is null ? fn : cursorPart(), format("plane(%s, %s, %s)", pts[0], pts[1], pts[2]), null);
    }

    /// Offset plane…: shown plane i moved along its normal, into the part the
    /// cursor is in (or the module).
    string offsetPlane(int i)
    {
        if (i < 0 || i >= viewport.planes.length)
            return "no such plane";
        immutable part = cursorPart();
        return writePlane(part, planeCodeFor(i, part) ~ ".offset(10.mm)", "10.mm");
    }
}
