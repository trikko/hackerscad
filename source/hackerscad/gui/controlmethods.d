/// The methods of the control socket (what the hcad_gui_* tools of the MCP
/// server call): dispatchControl, mixed into MainWindow. A mixin's body is
/// compiled where it is mixed in, so it uses the window's members and
/// imports as its own; it lives here only to keep app.d to a readable size.
module hackerscad.gui.controlmethods;

mixin template ControlMethods()
{
    void dispatchControl(string method, JValue p, void delegate(JValue, string) reply)
    {
        // what the socket writes in the code is built, whether or not the window rebuilds as one types
        programEdit = true;
        scope (exit)
            programEdit = false;
        string arg(string k) => p.safe!string(k).or(null);
        bool has(string k) => p.has(k) && !p[k].isNull;
        // the view is annotated: what would change what it shows waits until it is live again
        {
            import std.algorithm : canFind;
            if (frozen && ["pick", "transform", "split", "inspect", "rollback", "step", "sketch", "menu"].canFind(method))
                return reply(JValue.init, "the view is annotated (locked, with marks on it): " ~ method ~ " would "
                    ~ "change what it shows; hcad_gui_annotate mode: false (or the user's Done) takes it back to the live view");
        }
        switch (method)
        {
        case "open":
            {
                auto file = absolutePath(arg("path"));
                if (!exists(file))
                    return reply(JValue.init, "file not found: " ~ file);
                if (auto why = notAModel(file))
                {
                    import std.array : replace;
                    return reply(JValue.init, why.replace("\n\n", " ") ~ " To use a mesh or CAD file, write a model "
                        ~ "that calls load() on it.");
                }
                if (modified && !p.safe!bool("force").or(false))
                    return reply(JValue.init, "the user has unsaved changes in " ~ baseName(path)
                        ~ ": ask them to save, or pass force: true to discard them");
                load(file);
                whenIdle(() => reply(state(), null));
                return;
            }
        case "set":
            // {"auto_rebuild": false}: the code built when asked, not as it is typed (the header's button);
            // {"build": true}: built now (Ctrl+B)
            if (p.has("auto_rebuild"))
                setAutoRebuild(p.safe!bool("auto_rebuild").or(true));
            if (auto s = arg("source"))
                replaceCode(s);
            // a preset first (it clears the values set by hand), then the
            // values given with it, on top
            if (p.has("preset"))
            {
                params.preset = arg("preset");
                params.overrides = null;
            }
            if (p.has("params"))
                foreach (k, v; toOverrides(p["params"]))
                    params.overrides[k] = v;
            // the parameters' ↺: back to the code's value (or the preset's)
            if (p.has("reset") && p["reset"].isArray)
                foreach (n; p["reset"].get!JArray.elements)
                    params.overrides.remove(n.get!string);
            params.invalidate();
            // frame the changed model, keeping the angle it is seen from
            fitNext = true;
            scheduleEvaluation(0);
            whenIdle(() => reply(state(), null));
            return;
        case "state":
            // after the running evaluation, or right away with "now": true
            // (then "evaluating" and "stage" tell how far it is)
            {
                immutable withSource = p.safe!bool("source").or(false);
                immutable withGraphics = p.safe!bool("graphics").or(false);
                // only: the fields asked for, the window's name with them
                string[] only;
                if (p.has("only"))
                {
                    if (!p["only"].isArray)
                        return reply(JValue.init, "only is a list of the state's fields, e.g. [\"revision\", "
                            ~ "\"source_hash\"]");
                    foreach (f; p["only"].get!JArray.elements)
                    {
                        auto name = f.isString ? f.get!string : "";
                        if (!stateFields.canFind(name))
                            return reply(JValue.init, format("only: no field %s in the state; its fields: %-(%s, %)",
                                f.toJSON(), stateFields));
                        only ~= name;
                    }
                }
                JValue full()
                {
                    auto j = state(withGraphics || only.canFind("graphics"));
                    if (withSource || only.canFind("source") || only.canFind("steps"))
                    {
                        j["source"] = text();
                        j["steps"] = toJSON(stepsPanel.rowsText());   // the Steps panel, row by row
                    }
                    if (only.length == 0)
                        return j;
                    JValue some = JSOB("window", j["window"]);
                    foreach (name; only)
                        if (auto v = j.getPtr(name))
                            some[name] = *v;
                    return some;
                }
                if (p.safe!bool("now").or(false))
                    reply(full(), null);
                else
                    whenIdle(() => reply(full(), null));
                return;
            }
        case "pick":
            {
                // click in the 3D view: at x, y (fractions of its size) or at a model point
                immutable shiftPick = p.safe!bool("shift").or(false);
                // a box dragged over the view: [x0, y0, x1, y1] fractions of it
                if (p.has("box"))
                {
                    if (!p["box"].isArray || p["box"].length != 4)
                        return reply(JValue.init, "box is [x0, y0, x1, y1], fractions of the view");
                    double[4] b;
                    foreach (i; 0 .. 4)
                        b[i] = numberOf(p["box"][i]) * (i % 2 ? viewport.height : viewport.width);
                    immutable crossing = p.safe!bool("crossing").or(false);
                    whenIdle(() {
                        boxed(b[0], b[1], b[2], b[3], crossing);
                        auto r = state();
                        r["status"] = infoLabel.getText();
                        reply(r, null);
                    });
                    return;
                }
                whenIdle(() {
                    double x, y;
                    if (auto problem = screenPoint(p, x, y))
                        return reply(JValue.init, problem);
                    auto hit = viewport.pickAt(x, y);
                    hit.shift = shiftPick;   // add to the selection, as Shift+click
                    picked(hit);
                    auto r = hitJson(hit);
                    r["status"] = infoLabel.getText();
                    reply(r, null);
                });
                return;
            }
        case "view":
            {
                import std.conv : to;
                alias num = numberOf;
                // the view is annotated: it is locked, so the marks stay on what they mark
                if (frozen && (has("preset") || has("look_at") || has("orbit") || has("pan") || has("zoom")
                        || has("size") || has("projection") || has("look_at_face")))
                    return reply(JValue.init, "the view is annotated (locked, with marks on it): it cannot move "
                        ~ "until hcad_gui_annotate mode: false (or the user's Done) takes it back to the live view");
                // moved as the user moves it: the frames count in graphics' figures
                if (has("preset") || has("look_at") || has("orbit") || has("pan") || has("zoom") || has("size"))
                    viewport.moved();
                // the planes, to draw a sketch on (Show planes)
                if (has("planes"))
                    setPlanesShown(p["planes"].safe!bool.or(false));
                // in the order a user would: frame, turn, move, zoom
                if (auto v = arg("preset"))
                {
                    if (v == "fit")
                        viewport.fit();
                    else
                        viewport.setView(v.to!ViewPreset);
                }
                // straight at a flat face, as a double click on it: {"x": 0.5, "y": 0.4} or {"point": [x, y, z]}
                if (has("look_at_face"))
                {
                    double fx, fy;
                    if (auto problem = screenPoint(p["look_at_face"], fx, fy))
                        return reply(JValue.init, problem);
                    if (auto problem = lookAtFace(fx, fy))
                        return reply(JValue.init, problem);
                    viewport.moved();
                }
                // centred on a model point, `size` mm across the view
                if (has("look_at") || has("size"))
                    viewport.centerOn(has("look_at") ? vec3Of(p["look_at"]) : viewport.camera().target,
                        has("size") ? num(p["size"]) : 0);
                if (has("orbit"))
                    viewport.orbit(num(p["orbit"][0]), num(p["orbit"][1]));
                if (has("pan"))
                    viewport.pan(num(p["pan"][0]), num(p["pan"][1]));
                // zoom: > 1 moves away, < 1 closer; at a point like the wheel
                if (has("zoom"))
                {
                    if (has("at"))
                        viewport.zoomAtFraction(num(p["at"][0]), num(p["at"][1]), num(p["zoom"]));
                    else
                        viewport.zoom(num(p["zoom"]));
                }
                // drawing style and projection, as the cube of the view bar
                if (auto v = arg("style"))
                {
                    auto sh = v == "wireframe" ? Shading.wireframe : v == "shaded" ? Shading.shaded : Shading.edges;
                    shadingChoice[sh].setActive(true);
                }
                // what a click picks, as the view bar's four buttons (kept between runs)
                if (auto v = arg("select"))
                {
                    import std.algorithm : countUntil;
                    immutable at = ["part", "face", "edge", "vertex"].countUntil(v);
                    if (at < 0)
                        return reply(JValue.init, "select is part, face, edge or vertex");
                    selectChoice[at].setActive(true);
                }
                // how shiny the surfaces are, as the cube's Shine choices (kept between runs)
                if (auto v = arg("shine"))
                {
                    import std.algorithm : countUntil;
                    immutable at = ["none", "normal", "high"].countUntil(v);
                    if (at < 0)
                        return reply(JValue.init, "shine must be none, normal or high");
                    shineChoice[at].setActive(true);
                }
                // the printability marks, over any style, as the cube's check box
                if (has("printability"))
                    printabilityChoice.setActive(p["printability"].safe!bool.or(false));
                // the printability marks' limits, as their two fields
                if (has("overhang_angle"))
                    overhangSpin.setValue(num(p["overhang_angle"]));
                if (has("min_wall"))
                    wallSpin.setValue(num(p["min_wall"]));
                if (auto v = arg("projection"))
                    (v == "orthographic" ? orthographicChoice : perspectiveChoice).setActive(true);
                // light or dark, for this run (the menu's choice is kept, this is not)
                if (auto v = arg("theme"))
                {
                    if (!["system", "light", "dark"].canFind(v))
                        return reply(JValue.init, "theme must be system, light or dark");
                    StyleManager.getDefault().setColorScheme(schemeFor(v));
                }
                // antialiasing, for this run (the user's choice in the cube menu stays)
                if (has("antialias"))
                    viewport.setAntialias(p["antialias"].safe!bool.or(false));
                // the rotation that glides, as the cube's check box (kept between runs)
                if (has("smooth_rotation"))
                    smoothTurnChoice.setActive(p["smooth_rotation"].safe!bool.or(false));
                // the ground grid and the axes, as the eye's menu (kept between runs)
                if (has("grid"))
                    gridChoice.setActive(p["grid"].safe!bool.or(false));
                if (has("axes"))
                    axesChoice.setActive(p["axes"].safe!bool.or(false));
                // the parts hidden with the eye of the view bar
                if (has("hidden"))
                {
                    bool[string] hide;
                    foreach (n; p["hidden"].get!JArray.elements)
                        hide[n.get!string] = true;
                    foreach (i, pm; last.parts)
                        setPartVisible(i, (pm.name in hide) is null);
                }
                // the cursor at the start of a line, the code scrolled there (and fully left)
                if (has("cursor"))
                {
                    TextIter at;
                    if (buffer.getIterAtLine(at, cast(int) p["cursor"].get!long - 1))
                    {
                        placeCursorQuietly(at);   // for a picture: the sketch at the cursor does not follow it
                        editor.scrollToIter(at, 0.1, true, 0, 0.3);
                        completion.close();
                    }
                }
                // how wide the code is, in pixels
                if (has("code_width"))
                    mainPaned.setPosition(cast(int) p["code_width"].get!long);
                // the tab of the sidebar
                if (auto tab = arg("sidebar"))
                    sideStack.setVisibleChildName(tab == "steps" ? "steps" : "params");
                // the problems of a line of the code, as a click on its icon in the gutter shows them (0 closes)
                if (has("problems"))
                {
                    immutable line = cast(int) p["problems"].get!long;
                    if (problemsPopover !is null)
                        problemsPopover.popdown();
                    if (line > 0)
                        showLineProblems(line - 1);
                }
                // a menu of the view bar opened, for a screenshot ("none" closes them)
                if (auto m = arg("menu"))
                {
                    foreach (b; [partsMenu, displayMenu, examplesButton, exportButton, viewMenuButton])
                        b.popdown();
                    if (contextPopover !is null)
                        contextPopover.popdown();
                    if (m == "parts")
                        partsMenu.popup();
                    else if (m == "display")
                        displayMenu.popup();
                    else if (m == "examples")
                        examplesButton.popup();
                    else if (m == "export")
                        exportButton.popup();
                    else if (m == "views")
                        viewMenuButton.popup();
                }
                if (has("console"))
                    consoleToggle.setActive(p["console"].safe!bool.or(false));
                if (has("params"))
                    paramsToggle.setActive(p["params"].safe!bool.or(false));
                if (has("code"))
                    codeToggle.setActive(p["code"].safe!bool.or(false));
                if (has("view"))
                    viewToggle.setActive(p["view"].safe!bool.or(false));
                whenIdle(() => reply(state(), null));
                return;
            }
        case "split":
            {
                // {"part": "clip", "plane": "xy", "at": 7.5}: the part cut in two there in the code, as
                // Split…'s ✓ (the upper half in another colour); {"part": "clip", "show": true} opens
                // Split… on it for the user to place the plane, writing nothing; "show": false closes it
                whenIdle(() {
                    if (!p.safe!bool("show").or(true))
                    {
                        if (splitPart >= 0)
                            sectionToggle.setActive(false);
                        return reply(state(), null);
                    }
                    auto name = arg("part");
                    int index = -1;
                    foreach (i, q; last.parts)
                        if (q.name == name || (name is null && last.parts.length == 1))
                            index = cast(int) i;
                    if (index < 0)
                        return reply(JValue.init, name is null ? "say which part" : "no part named '" ~ name ~ "'");
                    if (p.safe!bool("show").or(false))
                    {
                        startSplit(index);
                        return reply(state(), null);
                    }
                    immutable plane = arg("plane");
                    auto n = plane == "xy" ? Vec3(0, 0, 1) : plane == "xz" ? Vec3(0, 1, 0) : plane == "yz" ? Vec3(1, 0, 0)
                        : Vec3(0, 0, 0);
                    if (n.length == 0)
                        return reply(JValue.init, "plane is xy, xz or yz");
                    if (!has("at"))
                        return reply(JValue.init, "at: where the plane is, in mm along its normal (z for xy)");
                    if (auto problem = writeSplit(index, n, numberOf(p["at"])))
                        return reply(JValue.init, problem);
                    whenIdle(() => reply(state(), null));
                });
                return;
            }
        case "colour":
            {
                // {"part": "lid", "colour": "Violet Pop"} or "#C597FE": the colour written on its @part,
                // as the right-click menu's Colour; {"hue": 250, "lightness": 0.76, "vividness": 0.15}
                // as its Other… wheel (OKLCH; the last two as the palette's when left out);
                // {"wheel": true} opens the wheel on the part for the user, writing nothing;
                // a piece of @parts is coloured alone (.color on it), {"all": true} all its pieces (the annotation)
                whenIdle(() {
                    auto name = arg("part");
                    int index = -1;
                    foreach (i, q; last.parts)
                        if (q.name == name || (name is null && last.parts.length == 1))
                            index = cast(int) i;
                    if (index < 0)
                        return reply(JValue.init, name is null ? "say which part" : "no part named '" ~ name ~ "'");
                    import hackerscad.geom.color : partPalette;
                    import std.ascii : isHexDigit;
                    import std.algorithm : all;
                    import std.uni : sicmp, toUpper;
                    // a palette name as the palette writes it, or #RRGGBB
                    if (p.safe!bool("wheel").or(false))
                    {
                        showColourWheel(index);
                        return reply(state(), null);
                    }
                    immutable want = arg("colour");
                    string colour;
                    if (has("hue"))
                    {
                        import hackerscad.geom.color : oklchColour;
                        immutable l = has("lightness") ? numberOf(p["lightness"]) : 0.76;
                        immutable ch = has("vividness") ? numberOf(p["vividness"]) : 0.15;
                        colour = format("#%06X", oklchColour(l, ch, numberOf(p["hue"])));
                    }
                    foreach (c; partPalette)
                        if (colour is null && sicmp(c.name, want) == 0)
                            colour = c.name;
                    if (colour is null && want.length == 7 && want[0] == '#' && want[1 .. $].all!isHexDigit)
                        colour = want.toUpper;
                    if (colour is null)
                    {
                        string[] names;
                        foreach (c; partPalette)
                            names ~= c.name;
                        return reply(JValue.init, "colour is one of " ~ names.join(", ") ~ ", or #RRGGBB");
                    }
                    auto q = last.parts[index];
                    immutable everyPiece = p.safe!bool("all").or(false);
                    if (auto problem = writeColour(q.fn, everyPiece ? -1 : q.piece, q.fromSolid, colour))
                        return reply(JValue.init, problem);
                    whenIdle(() => reply(state(), null));
                });
                return;
            }
        case "transform":
            {
                // {"part": "lid", "move": [10, 0, 0]}, {"part": "lid", "rotate": {"axis": "z", "angle": 45}} or
                // {"part": "lid", "scale": 1.5} ([1, 1, 2]: a factor each): the code Move…, Rotate… and Scale…
                // write (a turn is about the middle of the part's box, a scale about the middle of its bottom);
                // {"part": "lid", "show": "move"} shows the frame (rotate: the rings, scale: the handles,
                // previewed scaled by "scale" when given), "none" takes it away
                whenIdle(() {
                    auto name = arg("part");
                    int index = -1;
                    foreach (i, q; last.parts)
                        if (q.name == name || (name is null && last.parts.length == 1))
                            index = cast(int) i;
                    if (index < 0)
                        return reply(JValue.init, name is null ? "say which part" : "no part named '" ~ name ~ "'");
                    // an axis: origin [x, y, z] mm and direction [x, y, z], for hinge
                    Vec3 hingeAt, hingeAlong;
                    immutable hasAxis = has("origin") && has("direction");
                    if (hasAxis)
                        foreach (i; 0 .. 3)
                        {
                            hingeAt[i] = numberOf(p["origin"][i]);
                            hingeAlong[i] = numberOf(p["direction"][i]);
                        }
                    if (auto show = arg("show"))
                    {
                        if (show == "none")
                            cancelTransform();
                        else if (show == "move" || show == "rotate" || show == "scale")
                        {
                            startTransform(show == "move" ? Viewport.Gizmo.move : show == "scale" ? Viewport.Gizmo.scale
                                : Viewport.Gizmo.rotate, index);
                            // scale with factors: previewed so, for the user to drag on and confirm
                            if (show == "scale" && has("scale") && viewport.gizmo == Viewport.Gizmo.scale)
                            {
                                auto q = p["scale"];
                                Vec3 f = Vec3(1, 1, 1);
                                if (q.isArray && q.length == 3)
                                    foreach (i; 0 .. 3)
                                        f[i] = numberOf(q[i]);
                                else
                                    f = Vec3(1, 1, 1) * numberOf(q);
                                if (f.x <= 0 || f.y <= 0 || f.z <= 0)
                                    return reply(JValue.init, "scale factors must be positive");
                                viewport.previewScale(f);
                                transformValue.setLabel(transformText());
                            }
                        }
                        else if (show == "hinge" && hasAxis && hingeAlong.length > 0)
                            startHinge(index, hingeAt, hingeAlong, "the axis");
                        else
                            return reply(JValue.init, "show is move, rotate, scale, hinge (with origin and direction) or none");
                        return reply(state(), null);
                    }
                    // Place on…: {"place": {"from": […], "from_normal": […], "to": […], "to_normal": […], "spin": 0}}
                    if (has("place"))
                    {
                        auto q = p["place"];
                        Vec3 v3(string k)
                        {
                            Vec3 r;
                            foreach (i; 0 .. 3)
                                r[i] = numberOf(q[k][i]);
                            return r;
                        }
                        foreach (k; ["from", "from_normal", "to", "to_normal"])
                            if (!q.isObject || !q.has(k) || !q[k].isArray || q[k].length != 3)
                                return reply(JValue.init, "place needs from, from_normal, to and to_normal, each [x, y, z]");
                        Vec3 axis;
                        double angle;
                        Viewport.faceTurn(v3("from_normal"), v3("to_normal"), axis, angle);
                        immutable spin = q.has("spin") ? numberOf(q["spin"]) : 0;
                        // show: the placing previewed with its ring, for the user to spin and confirm
                        if (q.safe!bool("show").or(false))
                        {
                            viewport.startPlace(index, v3("from"), v3("from_normal"));
                            viewport.previewPlace(v3("to"), v3("to_normal"));
                            transformTitle.setLabel("Place " ~ last.parts[index].name);
                            transformValue.setLabel(transformText());
                            transformBar.setVisible(true);
                            return reply(state(), null);
                        }
                        if (auto problem = writePlace(index, v3("from"), axis, angle, v3("to"), spin, v3("to_normal").normalized))
                            return reply(JValue.init, problem);
                        whenIdle(() => reply(state(), null));
                        return;
                    }
                    // a turn about any axis: {"hinge": 30, "origin": […], "direction": […]}
                    if (has("hinge"))
                    {
                        if (!hasAxis || hingeAlong.length == 0)
                            return reply(JValue.init, "hinge turns about an axis: give origin [x, y, z] (mm) and direction [x, y, z]");
                        if (auto problem = writeHinge(index, numberOf(p["hinge"]), hingeAt, hingeAlong))
                            return reply(JValue.init, problem);
                        whenIdle(() => reply(state(), null));
                        return;
                    }
                    string kind;
                    Vec3 v;
                    Vec3 around = last.parts[index].bbox.center;
                    if (has("scale"))
                    {
                        kind = "scale";
                        auto q = p["scale"];
                        if (q.isArray && q.length == 3)
                            foreach (i; 0 .. 3)
                                v[i] = numberOf(q[i]);
                        else if (q.isNumber)
                            v = Vec3(1, 1, 1) * numberOf(q);
                        else
                            return reply(JValue.init, "scale is a factor, or [x, y, z] factors");
                        if (v.x <= 0 || v.y <= 0 || v.z <= 0)
                            return reply(JValue.init, "scale factors must be positive");
                        if (v.x == 1 && v.y == 1 && v.z == 1)
                            return reply(JValue.init, "a scale of 1 changes nothing");
                        // the middle of the bottom of its box stays where it is
                        auto b = last.parts[index].bbox;
                        around = Vec3((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, b.min.z);
                    }
                    else if (has("move"))
                    {
                        kind = "move";
                        if (!p["move"].isArray || p["move"].length != 3)
                            return reply(JValue.init, "move is [x, y, z] in mm");
                        foreach (i; 0 .. 3)
                            v[i] = numberOf(p["move"][i]);
                    }
                    else if (has("rotate"))
                    {
                        kind = "rotate";
                        auto r = p["rotate"];
                        immutable axis = r.isObject && r.has("axis") && r["axis"].isString
                            ? ["x": 0, "y": 1, "z": 2].get(r["axis"].get!string, -1) : -1;
                        if (axis < 0 || !r.has("angle"))
                            return reply(JValue.init, "rotate is {\"axis\": \"x\", \"y\" or \"z\", \"angle\": degrees}");
                        v[axis] = numberOf(r["angle"]);
                    }
                    else
                        return reply(JValue.init, "give move, rotate, scale or show");
                    cancelTransform();
                    if (auto problem = writeTransform(index, kind, v, around))
                        return reply(JValue.init, problem);
                    whenIdle(() => reply(state(), null));
                });
                return;
            }
        case "feature":
            {
                // {"x": 0.5, "y": 0.4, "action": "fillet-edge", "value": "2.mm"}: what the context menu does,
                // on what is there or (use_selection) on the Shift selection that contains it;
                // "action": "sketch" is Sketch on face…
                auto act = arg("action"), value = arg("value"), kind = arg("kind"), size = arg("size");
                immutable useSelection = has("use_selection") && p["use_selection"].safe!bool.or(false);
                // "action": "sketch", "plane": "XZ" (or a plane of the code, by its name): Sketch on plane…
                if (act == "sketch" && has("plane"))
                {
                    auto name = arg("plane");
                    return whenIdle(() {
                        refreshPlanes();
                        immutable i = planeNamed(name);
                        if (i < 0)
                        {
                            string[] names;
                            foreach (q; viewport.planes)
                                names ~= q.name;
                            return reply(JValue.init, format("no plane '%s': there are %s", name, names.join(", ")));
                        }
                        if (auto problem = sketchOnPlaneOf(i))
                            return reply(JValue.init, problem);
                        whenIdle(() => reply(state(), null));
                    });
                }
                whenIdle(() {
                    double x, y;
                    if (auto problem = screenPoint(p, x, y))
                        return reply(JValue.init, problem);
                    // whatever the user's selection mode: the face there, and an edge near the point
                    auto hit = viewport.pickAny(x, y);
                    if (hit.part < 0)
                        return reply(JValue.init, "nothing under that point");
                    hit.edge = viewport.nearestEdge(hit.part, hit.face, x, y, 12);
                    if (!useSelection)
                        picked(hit, true);
                    setContext(hit);
                    // Sketch on face…: a sketch on the face there, to draw on
                    if (act == "sketch")
                    {
                        if (auto problem = sketchOnFaceOf(hit.part, hit.face))
                            return reply(JValue.init, problem);
                        return whenIdle(() => reply(state(), null));
                    }
                    auto code = contextCode(act, value, kind, size);
                    if (code.length == 0)
                        return reply(JValue.init, "unknown action, or it does not apply there: use fillet-edge, "
                            ~ "chamfer-edge (an edge), fillet-face, chamfer-face, shell, draft, extrude-face, cut-face (faces), thread (size: an ISO size that fits the cylinder, e.g. M8), hole (kind: "
                            ~ "clearance, tap or insert; size: M2 to M8), pocket or boss (a face), sketch (a flat face)");
                    appendFeature(last.parts[hit.part], code, null);
                    whenIdle(() {
                        auto r = state();
                        r["added"] = code;
                        reply(r, null);
                    });
                });
                return;
            }
        case "new":
            // a new model from the template, as New; unsaved changes need force
            if (modified && !p.safe!bool("force").or(false))
                return reply(JValue.init, "the model has unsaved changes: save it, or pass force: true to discard "
                    ~ "them (ask the user first)");
            // with "source": that code, in a model of no file (Save asks for a name): to show
            // an example the user can try things in without overwriting anything
            if (p.has("source") && p["source"].isString)
            {
                startNew();
                agentText = null;
                replaceCode(p["source"].get!string);
                modified = false;
                updateTitle();
            }
            // with "example": that example model instead of the template, as the Examples menu
            else if (auto ex = arg("example"))
            {
                if (!startExample(ex))
                    return reply(JValue.init, "no example named '" ~ ex ~ "': " ~ exampleNames());
            }
            else
                startNew();
            whenIdle(() => reply(state(), null));
            return;
        case "rename":
            {
                // the window's name, as clicking it in the header bar
                if (auto why = control.rename(arg("name")))
                    return reply(JValue.init, why);
                showWindowName();
                reply(state(), null);
                return;
            }
        case "menu":
            {
                // {"x": 0.5, "y": 0.5, "path": ["Hole at point", "Clearance", "M3"]}: the right-click menu there,
                // then its entries clicked in order; without path, the entries it has there; with
                // "open": true it stays open (path: groups to open), for a screenshot; {"bar": "view", "path":
                // ["Sketches", "line 12 · …"]}: the view bar's View menu instead
                string[] path;
                immutable keep = p.safe!bool("open").or(false);
                if (p.has("path") && p["path"].isArray)
                    foreach (v; p["path"].get!JArray.elements)
                        path ~= v.get!string;
                immutable list = !p.has("path") || path.length == 0;
                if (arg("bar").length)
                {
                    // the view bar's View menu: its presets, and Sketches, one entry per sketch of the model
                    if (arg("bar") != "view")
                        return reply(JValue.init, "bar is view (the View menu of the view bar)");
                    whenIdle(() {
                        if (list)
                            return reply(JSOB("entries", menuJson(viewMenuEntries())), null);
                        if (auto problem = runMenuPath(viewMenuEntries(), path))
                            return reply(JValue.init, problem);
                        whenIdle(() => reply(state(), null));
                    });
                    return;
                }
                whenIdle(() {
                    double x, y;
                    if (auto problem = screenPoint(p, x, y))
                        return reply(JValue.init, problem);
                    auto hit = viewport.pickAt(x, y);
                    // on empty space the menu lists the hidden parts, when there are some
                    bool anyHidden;
                    foreach (i; 0 .. last.parts.length)
                        anyHidden = anyHidden || viewport.isHidden(i);
                    if (hit.part < 0 && hit.plane < 0 && !anyHidden)
                        return reply(JValue.init, "nothing under that point: the menu opens on a part (or, on empty "
                            ~ "space, lists the hidden parts: none is hidden)");
                    contextMenu(hit, x, y);
                    if (list)
                    {
                        auto entries = lastMenuEntries();
                        if (!keep)
                            closeLastMenu();
                        return reply(JSOB("entries", menuJson(entries)), null);
                    }
                    lastCopied = null;
                    if (auto problem = activateMenuPath(path))
                        return reply(JValue.init, problem);
                    whenIdle(() {
                        // an entry that copies (Measure, Copy as code): the text too
                        auto r = state();
                        if (lastCopied !is null)
                            r["copied"] = lastCopied;
                        reply(r, null);
                    });
                });
                return;
            }
        case "section":
            {
                // {"plane": "xy" | "xz" | "yz" | "face", "at": 0..1 along the model, "flip": false}; {"on": false} hides it
                if (!p.safe!bool("on").or(true))
                {
                    sectionToggle.setActive(false);
                    whenIdle(() => reply(state(), null));
                    return;
                }
                // without a plane, the one shown stays (xy when none is)
                immutable planes = ["xy", "xz", "yz", "face"];
                import std.algorithm : countUntil;
                immutable wasOn = sectionToggle.getActive();
                auto which = arg("plane").length ? planes.countUntil(arg("plane"))
                    : wasOn ? sectionPlane.getSelected() : 0;
                if (which < 0)
                    return reply(JValue.init, "plane must be xy, xz, yz or face");
                immutable changed = !wasOn || which != sectionPlane.getSelected() || which == 3;
                sectionUpdating = true;
                sectionPlane.setSelected(cast(uint) which);
                sectionUpdating = false;
                sectionToggle.setActive(true);
                if (changed)
                    updateSection(true);
                if (p.has("at"))
                {
                    auto adj = sectionSlider.getAdjustment();
                    sectionSlider.setValue(adj.getLower() + p["at"].get!double * (adj.getUpper() - adj.getLower()));
                }
                if (p.has("flip"))
                    sectionFlip.setActive(p["flip"].safe!bool.or(false));
                whenIdle(() {
                    auto r = state();
                    r["section"] = sectionLabel.getLabel();
                    reply(r, null);
                });
                return;
            }
        case "sketch":
            // {"line": 52, "to_line": 54}: the sketch those lines belong to, what they make or constrain in
            // orange (as Inspect on them, without the solids); {"on": true} or nothing: the first sketch;
            // {"on": false}: none; {"follow": false}: the setting Show the sketch at the cursor; {"pin": true}: the sketch
            // at the cursor stays when it leaves; {"align": true}: the view straight at the sketch shown (Look at
            // sketch); {"run": 2}: of a sketch made again (a loop, another call), that run drawn (1-based).
            // The reply lists the sketches, and state's sketch tells the one shown
            // (from_cursor, pinned, partial, stale, run of runs). An explicit request takes the view over from the cursor
            {
                // run n of the sketch shown, or of the one line asks for: false and the reply sent when there is none
                bool toRun()
                {
                    if (!has("run"))
                        return true;
                    immutable n = p["run"].isNumber ? cast(long) p["run"].get!double : 0;
                    if (sketchIndices.length == 0)
                        reply(JValue.init, "no sketch is shown: show one first (line, or the cursor in its code)");
                    else if (n < 1 || !showSketchRun(n - 1))
                        reply(JValue.init, frozen ? "the view is annotated: it does not change"
                            : format("run %s: the sketch shown has %d run%s", p["run"].toJSON(), sketchIndices.length,
                                sketchIndices.length > 1 ? "s, from 1" : " (a loop or another call makes more)"));
                    else
                        return true;
                    return false;
                }
                // {"close": "done"}: the sketch being edited closed, its changes kept (the mode bar's Done);
                // {"close": "cancel"}: closed, the code back to what it was when it was opened (Cancel)
                if (has("close"))
                {
                    immutable how = arg("close");
                    if (how != "done" && how != "cancel")
                        return reply(JValue.init, "close is done (keep the changes) or cancel (take them back)");
                    whenIdle(() {
                        if (sketchBefore is null)
                            return reply(JValue.init, "no sketch is being edited");
                        if (how == "done")
                            sketchDone();
                        else
                            sketchCancel();
                        reply(state(), null);
                    });
                    return;
                }
                // the sketch bar: select entities of the drawn sketch (ids from state's sketch.entities), and
                // write a constraint on what is selected, as its buttons do
                // drawing: tool chooses a tool of the bar (then hcad_gui_pick clicks draw, as the user's do);
                // draw writes a shape at once from its points, [x, y] on the sketch's plane or ids of its points
                if ((has("tool") || has("draw")) && !has("line") && !p.has("on"))
                {
                    whenIdle(() {
                        if (drawnSketch() is null)
                            return reply(JValue.init, "no sketch is drawn: show one first (line)");
                        string said;
                        if (p.has("sides"))
                        {
                            immutable n = p.safe!double("sides").or(0);
                            if (n < 3 || n > 64 || n != cast(int) n)
                                return reply(JValue.init, "sides is a whole number from 3 to 64");
                            polygonSides = cast(int) n;
                        }
                        if (has("tool"))
                        {
                            immutable t = arg("tool");
                            import std.algorithm : canFind, map;
                            if (!drawTools[].map!(x => x[0]).canFind(t))
                                return reply(JValue.init, "tool is one of " ~ drawTools[].map!(x => x[0]).join(", "));
                            chooseDrawTool(t);
                        }
                        if (has("draw"))
                        {
                            immutable t = arg("draw");
                            if (!p.has("points") || !p["points"].isArray)
                                return reply(JValue.init, "draw needs points: [x, y] on the sketch's plane, or ids of its points");
                            Vec3[] pts;
                            ptrdiff_t[] at;
                            auto drawn = drawnSketch();
                            foreach (q; p["points"].get!JArray.elements)
                            {
                                if (q.isNumber)
                                {
                                    immutable id = cast(long) q.get!double;
                                    if (id < 0 || id >= drawn.entities.length || drawn.entities[id].kind != "point")
                                        return reply(JValue.init, format("%s is not a point of the sketch", q.toJSON()));
                                    Vec3 pos;
                                    foreach (pt; drawn.points)
                                        if (pt.entity == id)
                                            pos = pt.pos;
                                    pts ~= pos;
                                    at ~= cast(ptrdiff_t) id;
                                }
                                else if (q.isArray && q.length == 2)
                                {
                                    pts ~= Vec3(q[0].get!double, q[1].get!double, 0);
                                    at ~= -1;
                                }
                                else
                                    return reply(JValue.init, "each point is [x, y] or the id of a point of the sketch");
                            }
                            said = writeDrawing(t, pts, at, p.safe!bool("closed").or(false),
                                p.safe!bool("construction").or(false));
                            import std.algorithm : endsWith;
                            if (!said.endsWith("written in the sketch's code"))
                                return reply(JValue.init, said);
                        }
                        auto r = state();
                        r["sketches"] = sketchesJson();
                        if (said.length)
                            r["done"] = said;
                        reply(r, null);
                    });
                    return;
                }
                if ((has("select") || has("constrain") || has("delete") || p.has("move")
                        || (p.has("construction") && !has("draw")))
                    && !has("line") && !p.has("on"))
                {
                    whenIdle(() {
                        if (has("select"))
                        {
                            auto drawn = drawnSketch();
                            if (drawn is null)
                                return reply(JValue.init, "no sketch is drawn: show one first (line)");
                            if (!p["select"].isArray)
                                return reply(JValue.init, "select is a list of entity ids (state's sketch.entities)");
                            size_t[] ids;
                            foreach (x; p["select"].get!JArray.elements)
                            {
                                immutable id = x.isNumber ? cast(long) x.get!double : -1;
                                if (id < 0 || id >= drawn.entities.length)
                                    return reply(JValue.init, format("no entity %s in the sketch drawn", x.toJSON()));
                                ids ~= cast(size_t) id;
                            }
                            sketchSel = ids;
                            selHidden = null;
                            selHiddenAt = null;
                            drawRuns();
                        }
                        string said;
                        if (has("delete") && p["delete"].safe!bool.or(false))
                        {
                            said = deleteSelection();
                            import std.algorithm : canFind;
                            if (!said.canFind("deleted from the sketch's code"))
                                return reply(JValue.init, said);
                        }
                        // dragged as the user drags them: the selected entities' points moved by [dx, dy]
                        if (p.has("move"))
                        {
                            auto drawn = drawnSketch();
                            if (drawn is null || sketchSel.length == 0)
                                return reply(JValue.init, "move needs a sketch shown and a selection (select [ids])");
                            if (!p["move"].isArray || p["move"].length != 2)
                                return reply(JValue.init, "move is [dx, dy] on the sketch's plane");
                            auto by = Vec3(numberOf(p["move"][0]), numberOf(p["move"][1]), 0);
                            size_t[] pts;
                            Vec3[] to;
                            import std.algorithm : canFind;
                            foreach (e; sketchSel)
                                foreach (q; pointsOf(drawn, e))
                                    if (!pts.canFind(q))
                                        foreach (pt; drawn.points)
                                            if (pt.entity == q)
                                            {
                                                pts ~= q;
                                                to ~= pt.pos + by;
                                            }
                            said = moveSketchPoints(pts, to);
                            import std.algorithm : startsWith;
                            if (!said.startsWith("moved"))
                                return reply(JValue.init, said);
                        }
                        if (p.has("construction") && !has("draw"))
                        {
                            if (sketchSel.length == 0)
                                return reply(JValue.init, "construction needs a selection (select [ids])");
                            said = constructionSelection(p.safe!bool("construction").or(false));
                            import std.algorithm : canFind;
                            if (!said.canFind(" geometry"))
                                return reply(JValue.init, said);
                        }
                        if (has("constrain"))
                        {
                            immutable tool = arg("constrain");
                            said = applySketchTool(tool, arg("value"));
                            import std.algorithm : startsWith;
                            if (!said.startsWith(tool ~ " written"))
                                return reply(JValue.init, said);
                        }
                        auto r = state();
                        r["sketches"] = sketchesJson();
                        if (said.length)
                            r["done"] = said;
                        reply(r, null);
                    });
                    return;
                }
                if (has("run") && !has("line") && !p.has("on") && !has("align"))
                {
                    whenIdle(() {
                        if (!toRun())
                            return;
                        auto r = state();
                        r["sketches"] = sketchesJson();
                        reply(r, null);
                    });
                    return;
                }
                if (has("align") && !has("line") && !p.has("on"))
                {
                    whenIdle(() {
                        if (!alignToSketch())
                            return reply(JValue.init, frozen ? "the view is annotated: it does not move"
                                : "no sketch is shown: show one first (line, or the cursor in its code)");
                        auto r = state();
                        r["sketches"] = sketchesJson();
                        reply(r, null);
                    });
                    return;
                }
                immutable hide = !p.safe!bool("on").or(true);
                // follow: the setting Show the sketch at the cursor; pin: the pin of the mode bar, which keeps
                // the sketch at the cursor shown when the cursor leaves its code; alone, they show nothing else
                if (has("pin"))
                {
                    if (!sketchFollowing)
                        return reply(JValue.init, "pin keeps the sketch shown at the cursor: none is (move the "
                            ~ "cursor into a sketch's code with hcad_gui_edit goto)");
                    pinButton.setActive(p["pin"].safe!bool.or(false));
                }
                if (has("follow") || has("pin"))
                {
                    if (has("follow"))
                        setFollow(p["follow"].safe!bool.or(false));
                    if (!has("line") && !p.has("on"))
                    {
                        whenIdle(() {
                            auto r = state();
                            r["sketches"] = sketchesJson();
                            reply(r, null);
                        });
                        return;
                    }
                }
                whenIdle(() {
                    // on the latest evaluation
                    if (hide)
                    {
                        // a sketch shown on its own goes with its Inspect; over a step or a solid, alone
                        if (viewport.inInspect && inspectShown.length == 0)
                            showFinal();
                        else
                            hideSketch();
                    }
                    else if (has("line"))
                    {
                        immutable from = cast(uint) p["line"].get!long;
                        immutable to = has("to_line") ? max(from, cast(uint) p["to_line"].get!long) : from;
                        if (!inspectSketch(from, to, true))
                            return reply(JValue.init, from == to ? format("line %d is not part of a sketch", from)
                                : format("lines %d–%d are not part of a sketch", from, to));
                    }
                    else
                    {
                        if (last.sketches.length == 0)
                            return reply(JValue.init, "the model has no sketch");
                        auto first = last.sketches[0].span.line;
                        inspectSketch(first, first, false);
                    }
                    if (!hide && !toRun())
                        return;
                    auto r = state();
                    r["sketches"] = sketchesJson();
                    reply(r, null);
                });
                return;
            }
        case "step":
            {
                // {"row": 3}: a row of the Steps panel clicked (0-based, as state's steps lists them)
                if (!has("row"))
                    return reply(JValue.init, "give row: the index of the Steps panel row (state with source: true "
                        ~ "lists them)");
                sideStack.setVisibleChildName("steps");
                if (!stepsPanel.activate(cast(int) p["row"].get!long))
                    return reply(JValue.init, "no such row, or it is a heading");
                whenIdle(() => reply(state(), null));
                return;
            }
        case "dimension":
            {
                // {"line": 12, "col": 30, "value": "40.mm"}: a sketch dimension changed, as clicking it;
                // {"line": 12, "col": 30, "edit": true}: its field opened for the user to type in, as a click
                // on it does (the sketch must be shown)
                if (has("edit") && p["edit"].safe!bool.or(false))
                {
                    foreach (i, d; dims)
                        if (d.value.line == p["line"].get!long && d.value.col == p["col"].get!long)
                        {
                            editDimension(dimButtons[i], d);
                            whenIdle(() => reply(state(), null));
                            return;
                        }
                    return reply(JValue.init, "no dimension shown there: show its sketch first (hcad_gui_sketch)");
                }
                if (!has("line") || !has("col") || arg("value").length == 0)
                    return reply(JValue.init, "give line and col of the dimension (hcad_gui_sketch lists them) and "
                        ~ "the new value");
                try
                {
                    auto e = replaceArgument(text(), path, cast(uint) p["line"].get!long, cast(uint) p["col"].get!long,
                        arg("value"));
                    applyEdit(e);
                }
                catch (Exception ex)
                    return reply(JValue.init, ex.msg);
                whenIdle(() {
                    auto r = state();
                    r["sketches"] = sketchesJson();
                    reply(r, null);
                });
                return;
            }
        case "inspect":
            {
                // {"line": 12, "to_line": 20} or {"function": "lever"}: what that code made (on lines of a sketch,
                // the sketch with what they make or constrain); nothing: back to the model
                if (!has("line") && !has("function"))
                {
                    stopInspect();
                    whenIdle(() => reply(state(), null));
                    return;
                }
                whenIdle(() {
                    // on the latest evaluation
                    if (auto name = arg("function"))
                    {
                        string[] names;
                        foreach (fn; last.functions)
                        {
                            if (fn.name == name)
                            {
                                if (!inspectFunction(fn))
                                    return reply(JValue.init, format("'%s' returned no solid, profile or path", name));
                                return whenIdle(() => reply(state(), null));
                            }
                            names ~= fn.name;
                        }
                        return reply(JValue.init, format("no function '%s' in the model (there are: %s)", name,
                            names.join(", ")));
                    }
                    immutable from = cast(uint) p["line"].get!long;
                    immutable to = has("to_line") ? cast(uint) p["to_line"].get!long : from;
                    if (!inspectLines(from, max(from, to), -1))
                        return reply(JValue.init, from == to
                            ? format("line %d made no solid, profile or path and is not part of a sketch", from)
                            : format("lines %d–%d made no solid, profile or path and are not part of a sketch", from, to));
                    whenIdle(() => reply(state(), null));
                });
                return;
            }
        case "rollback":
            {
                // {"line": 12}: the model right after the feature on that line; no line: the final model
                if (!p.has("line"))
                {
                    showFinal();
                    whenIdle(() => reply(state(), null));
                    return;
                }
                immutable line = cast(uint) p["line"].get!long;
                uint id;
                foreach (i, f; last.features)
                    if (f.span.line == line && f.span.file == absolutePath(path))
                        id = cast(uint)(i + 1);
                if (id == 0)
                    return reply(JValue.init, format("no feature on line %d", line));
                showSketchOn(line, line, false);   // as its step does: a sketch's, with the sketch
                rollTo(id);
                whenIdle(() => reply(state(), null));
                return;
            }
        case "export":
            {
                // the window's model as shown (parameters, preset): .3mf .stl .step .png; meshes at the
                // window's Mesh quality, or "quality" (draft, normal, fine, mm); "quality" alone sets the window's
                // ("custom" opens Mesh quality › Custom… for the user)
                auto file = arg("path");
                string quality;
                if (p.has("quality"))
                    quality = p["quality"].isString ? p["quality"].get!string : p["quality"].toJSON();
                if (file is null && quality is null)
                    return reply(JValue.init, "missing 'path'");
                whenIdle(() {
                    try
                    {
                        import hackerscad.tool.exporter : qualityLabel, qualityTolerance;
                        if (file is null && quality == "custom")
                        {
                            customQuality();
                            return reply(state(), null);
                        }
                        if (file is null)
                        {
                            setExportQuality(quality);
                            note("mesh quality " ~ qualityLabel(exportTolerance));
                            return reply(state(), null);
                        }
                        string[] only;
                        if (p.has("parts") && p["parts"].isArray)
                            foreach (v; p["parts"].get!JArray.elements)
                                only ~= v.get!string;
                        auto warnings = exportTo(file, only, has("one_object") && p["one_object"].safe!bool.or(false),
                            quality is null ? double.nan : qualityTolerance(quality));
                        note("exported " ~ file ~ (lastExportSummary.length ? " (" ~ lastExportSummary ~ ")" : ""));
                        JValue r = JSOB("path", file);
                        if (lastExportSummary.length)
                        {
                            r["triangles"] = lastExportTriangles;
                            r["quality_mm"] = lastExportTolerance;
                        }
                        if (warnings.length)
                            r["warnings"] = toJSON(warnings);
                        reply(r, null);
                    }
                    catch (Exception e)
                        reply(JValue.init, e.msg);
                });
                return;
            }
        case "complete":
            {
                // what the completion list shows at the cursor, or at line/col (1-based)
                import std.utf : toUTFindex;
                import hackerscad.tool.complete : complete;
                auto src = text();
                size_t at;
                if (p.has("line"))
                {
                    TextIter it;
                    buffer.getIterAtLineOffset(it, cast(int) p["line"].get!long - 1,
                        p.has("col") ? cast(int) p["col"].get!long - 1 : 0);
                    at = toUTFindex(src, it.getOffset());
                    if (p.has("show") && p["show"].get!bool)
                    {
                        placeCursorQuietly(it);
                        editor.scrollToMark(buffer.getInsert(), 0, true, 0, 0.35);
                        editor.getHadjustment().setValue(0);
                    }
                }
                else
                {
                    TextIter it;
                    buffer.getIterAtMark(it, buffer.getInsert());
                    at = toUTFindex(src, it.getOffset());
                }
                auto r = complete(src, at, path, completion.libraryDirs);
                JValue items = JSAB();
                foreach (c; r.items[0 .. $ < 50 ? $ : 50])
                    items ~= JSOB("label", c.label, "kind", c.kind, "detail", c.detail, "doc", c.doc);
                JValue j = JSOB("prefix", r.prefix);
                j["items"] = items;
                if (r.signature.length)
                {
                    j["signature"] = r.signature;
                    j["activeParam"] = r.activeParam;
                    // the ways to call it, when its parameters are alternatives
                    if (r.forms.length)
                        j["forms"] = r.forms;
                }
                if (p.has("show") && p["show"].get!bool)
                {
                    // the list as the user would see it, in the window
                    editor.grabFocus();
                    completion.open();
                    if (auto sel = arg("select"))
                        completion.select(sel);
                }
                reply(j, null);
                return;
            }
        case "cheatsheet":
            showCheatsheet();
            if (auto q = arg("query"))
                cheatsheet.search(q);
            reply(JSOB("opened", true), null);
            return;
        case "save":
            {
                // to the window's file, or to path (then the window follows it, like Save As)
                auto target = arg("path").length ? absolutePath(arg("path")) : path;
                if (baseName(target) == "untitled.hcad" && !exists(target))
                    return reply(JValue.init, "the model has no file yet: pass path");
                if (target != path && exists(target) && !p.safe!bool("force").or(false))
                    return reply(JValue.init, target ~ " exists: pass force: true to overwrite it (ask the user first)");
                try
                    write(target, text());
                catch (Exception e)
                    return reply(JValue.init, "cannot save: " ~ e.msg);
                path = target;
                diskTime = mtimeOf(path);
                modified = false;
                updateTitle();
                note("saved " ~ path);
                return reply(state(), null);
            }
        case "find":
            {
                // Find and Replace all of the editor: {"text": "…", "regex": false, "case": false, "word": false}
                // lists the matches; with "replace": "…" every match is replaced (one step of Undo)
                import hackerscad.gui.editortools : FoundText;
                auto what = arg("text");
                if (what.length == 0)
                    return reply(JValue.init, "find needs text");
                bool flag(string k) => p.safe!bool(k).or(false);
                // "show": true opens the find bar on it, for the user (nothing replaced)
                if (flag("show"))
                {
                    editorTools.showBar(what, has("replace") ? arg("replace") : null);
                    return reply(state(), null);
                }
                FoundText[] found;
                uint replaced;
                immutable replacing = has("replace");
                if (auto problem = editorTools.findText(what, flag("regex"), flag("case"), flag("word"),
                        replacing ? arg("replace") : null, replacing, found, replaced))
                    return reply(JValue.init, "bad regular expression: " ~ problem);
                if (replacing)
                {
                    JValue j = JSOB("replaced", replaced);
                    whenIdle(() { j["state"] = state(); reply(j, null); });
                    return;
                }
                JValue list = JSAB();
                foreach (f; found)
                {
                    JValue m = JSOB("text", f.text);
                    m["line"] = f.line;
                    m["column"] = f.column;
                    list ~= m;
                }
                JValue j = JSOB("matches", list);
                j["count"] = list.length;
                return reply(j, null);
            }
        case "edit":
            {
                // the editor's line actions, as their keys: {"action": "comment" | "duplicate" | "delete" |
                // "move_up" | "move_down" | "indent" | "unindent", "lines": [from, to]}; {"goto": line} shows a line
                // {"fix": line}: the fix of the problem on that line written in place of the code it replaces, as
                // the Apply of its icon's popover does
                if (has("fix"))
                {
                    immutable line = cast(int) numberOf(p["fix"]) - 1;
                    foreach (sp; shownProblems)
                        if (sp.line == line && sp.d.replaces.length)
                        {
                            if (auto why = applyFix(sp.d))
                                return reply(JValue.init, why);
                            return whenIdle(() => reply(state(), null));
                        }
                    return reply(JValue.init, "no problem on that line has a fix to write in place");
                }
                if (has("goto"))
                {
                    // the cursor moved as the user moves it: the sketch whose code it is in shows
                    editorTools.showLine(cast(int) numberOf(p["goto"]));
                    if (followTimer)
                        Source.remove(followTimer);
                    followTimer = 0;
                    followArmed = true;
                    followSketch(false);
                    whenIdle(() => reply(state(), null));
                    return;
                }
                if (auto act = arg("action"))
                {
                    import hackerscad.gui.editortools : EditorTools;
                    alias A = EditorTools.LineAction;
                    immutable A[string] actions = ["comment": A.comment, "duplicate": A.duplicate, "delete": A.remove,
                        "move_up": A.up, "move_down": A.down, "indent": A.indent, "unindent": A.unindent];
                    if (!(act in actions))
                        return reply(JValue.init, "action is comment, duplicate, delete, move_up, move_down, indent or unindent");
                    int from, to;
                    if (has("lines"))
                    {
                        from = cast(int) numberOf(p["lines"][0]);
                        to = cast(int) numberOf(p["lines"][1]);
                    }
                    if (!editorTools.lineAction(actions[act], from, to))
                        return reply(JValue.init, "nothing to do there");
                    whenIdle(() => reply(state(), null));
                    return;
                }
                // a change of the code, as the user would type it (it can be undone):
                // {"old": "…", "new": "…"} | {"lines": [from, to], "text": "…"} | {"insert": line, "text": "…"}
                import std.string : indexOf;
                import std.utf : count;
                auto src = text();
                TextIter a, b;
                string with_;
                immutable lineCount = buffer.getLineCount();
                if (has("old"))
                {
                    auto old = arg("old");
                    auto at = src.indexOf(old);
                    if (old.length == 0 || at < 0)
                        return reply(JValue.init, "'old' is not in the code (hcad_gui_state with source: true shows it)");
                    if (src[at + old.length .. $].indexOf(old) >= 0)
                        return reply(JValue.init, "'old' appears more than once: include more of the code around it");
                    buffer.getIterAtOffset(a, cast(int) count(src[0 .. at]));
                    buffer.getIterAtOffset(b, cast(int) count(src[0 .. at + old.length]));
                    with_ = arg("new");
                }
                else if (has("lines") || has("insert"))
                {
                    immutable from = cast(int) numberOf(has("lines") ? p["lines"][0] : p["insert"]);
                    immutable to = has("lines") ? cast(int) numberOf(p["lines"][1]) : from - 1;
                    if (from < 1 || from > lineCount + 1 || to < from - 1 || to > lineCount)
                        return reply(JValue.init, format("lines out of range: the code has %d lines", lineCount));
                    with_ = arg("text");
                    if (from > lineCount)
                        buffer.getEndIter(a);
                    else
                        buffer.getIterAtLine(a, from - 1);
                    if (to >= lineCount)
                    {
                        buffer.getEndIter(b);
                        // appending after a last line without newline
                        if (from > lineCount && src.length && src[$ - 1] != '\n')
                            with_ = "\n" ~ with_;
                    }
                    else
                    {
                        buffer.getIterAtLine(b, to);
                        if (with_.length && with_[$ - 1] != '\n')
                            with_ ~= "\n";
                    }
                }
                else
                    return reply(JValue.init, "pass old and new, lines and text, or insert and text");
                immutable startOffset = a.getOffset();
                buffer.beginUserAction();
                buffer.delete_(a, b);
                buffer.getIterAtOffset(a, startOffset);
                buffer.insert(a, with_);
                buffer.endUserAction();
                // show the new code where it is
                TextIter s, e;
                buffer.getIterAtOffset(s, startOffset);
                buffer.getIterAtOffset(e, startOffset + cast(int) count(with_));
                immutable first = s.getLine() + 1, lastLine = e.getLine() + (e.getLineOffset() == 0 && e.getOffset() > s.getOffset() ? 0 : 1);
                TextIter all0, all1;
                buffer.getBounds(all0, all1);
                buffer.removeTagByName("picked", all0, all1);
                buffer.applyTagByName("picked", s, e);
                buffer.placeCursor(s);
                editor.scrollToIter(s, 0.1, true, 0, 0.3);
                whenIdle(() {
                    auto r = state();
                    r["lines"] = JSAB(first, max(first, lastLine));
                    reply(r, null);
                });
                return;
            }
        case "undo":
            {
                // {"redo": true} redoes; "steps" repeats
                immutable redo = p.safe!bool("redo").or(false);
                immutable steps = has("steps") ? cast(int) numberOf(p["steps"]) : 1;
                int done;
                foreach (i; 0 .. steps)
                {
                    if (redo ? !buffer.getCanRedo() : !buffer.getCanUndo())
                        break;
                    if (redo)
                        buffer.redo();
                    else
                        buffer.undo();
                    done++;
                }
                if (done == 0)
                    return reply(JValue.init, redo ? "nothing to redo" : "nothing to undo");
                whenIdle(() {
                    auto r = state();
                    r[redo ? "redone" : "undone"] = done;
                    reply(r, null);
                });
                return;
            }
        case "project":
            {
                // model points to view fractions ("points"), view fractions to what is there ("screen")
                whenIdle(() {
                    JValue r = JSOB();
                    if (has("points"))
                    {
                        JValue out_ = JSAB();
                        foreach (v; p["points"].get!JArray.elements)
                        {
                            double fx, fy;
                            bool visible;
                            if (viewport.fractionOf(vec3Of(v), fx, fy, visible))
                            {
                                JValue j = JSOB("x", fx, "y", fy);
                                j["visible"] = visible && fx >= 0 && fx <= 1 && fy >= 0 && fy <= 1;
                                out_ ~= j;
                            }
                            else
                                out_ ~= JSOB("behind_camera", true);
                        }
                        r["points"] = out_;
                    }
                    if (has("screen"))
                    {
                        JValue out_ = JSAB();
                        foreach (v; p["screen"].get!JArray.elements)
                            out_ ~= hitJson(viewport.pickAt(numberOf(v[0]) * viewport.width, numberOf(v[1]) * viewport.height));
                        r["screen"] = out_;
                    }
                    reply(r, null);
                });
                return;
            }
        case "selection":
            {
                // {"selector": "faces.top", "part": "lid"} selects, {"clear": true} empties; always the selection back
                whenIdle(() {
                    if (p.safe!bool("clear").or(false))
                        clearSelection();
                    // grown as the right-click menu does: the edges' chains, or the faces' outer edges
                    if (p.safe!bool("chain").or(false) || p.safe!bool("outer_edges").or(false))
                    {
                        immutable said = growSelection(p.safe!bool("chain").or(false));
                        import std.algorithm : startsWith;
                        if (said.startsWith("select "))
                            return reply(JValue.init, said);
                    }
                    if (auto expr = arg("selector"))
                    {
                        string problem;
                        immutable pi = partIndex(arg("part"), problem);
                        if (pi < 0)
                            return reply(JValue.init, problem);
                        auto part = last.parts[pi];
                        SolidVal sv;
                        auto it = selectorInterp(part, sv);
                        bool faces;
                        int[] found;
                        try
                            found = it.trySelector(expr, sv, faces);
                        catch (Exception e)
                            return reply(JValue.init, e.msg);
                        if (found.length == 0)
                            return reply(JValue.init, expr ~ " selects nothing on " ~ part.name);
                        auto infos = faces ? part.kernel.faces(part.brep) : null;
                        Hit[] hits;
                        foreach (i; found)
                        {
                            Hit h;
                            h.part = pi;
                            if (faces)
                            {
                                h.face = i;
                                h.point = infos[i].center;
                                h.normal = infos[i].normal;
                            }
                            else
                            {
                                h.edge = i;
                                h.point = part.edgeInfo[i].mid;
                            }
                            hits ~= h;
                        }
                        viewport.setSelection(hits);
                        info(format("%s · %d %s%s selected by the agent", part.name, hits.length, faces ? "face" : "edge",
                            hits.length == 1 ? "" : "s"));
                    }
                    reply(selectionJson(), null);
                });
                return;
            }
        case "measure":
            {
                // between a and b (part names or points [x, y, z]), or the two selected items
                whenIdle(() {
                    import hackerscad.gui.measure : measure;
                    size_t next;
                    Item ia, ib;
                    int pa, pb;
                    if (auto problem = measureItem(has("a") ? p["a"] : JValue(null), next, ia, pa))
                        return reply(JValue.init, problem);
                    if (auto problem = measureItem(has("b") ? p["b"] : JValue(null), next, ib, pb))
                        return reply(JValue.init, problem);
                    JValue r;
                    if (pa >= 0 && pb >= 0)
                    {
                        // two parts: exact, on the solids
                        Vec3 onA, onB;
                        auto d = last.parts[pa].kernel.distance(last.parts[pa].brep, last.parts[pb].brep, onA, onB);
                        r = JSOB("distance", d);
                        r["on_a"] = jsonOf(onA);
                        r["on_b"] = jsonOf(onB);
                    }
                    else
                    {
                        auto m = measure(ia, ib);
                        r = JSOB("distance", m.distance);
                        r["on_a"] = jsonOf(m.onA);
                        r["on_b"] = jsonOf(m.onB);
                        if (m.angle == m.angle)
                            r["angle_deg"] = m.angle;
                        if (m.gap == m.gap)
                            r["gap"] = m.gap;
                        r["note"] = "from the displayed mesh: curved surfaces are approximated";
                    }
                    reply(r, null);
                });
                return;
            }
        case "stop":
            {
                immutable was = evaluator.busy;
                if (was)
                    stopEvaluation();
                reply(JSOB("stopped", was), null);
                return;
            }
        case "test":
            {
                // runs the model's unittests, as F5: how many, how many failed, the state (problems)
                runTests();
                whenIdle(() {
                    JValue j = JSOB("unittests", last.unittests, "failed", last.unittestsFailed);
                    j["ran"] = last.unittestsRan;
                    j["state"] = state();
                    reply(j, null);
                });
                return;
            }
        case "about":
            // {"debug": true}: the debug information About copies, without opening it
            if (p.safe!bool("debug").or(false))
            {
                reply(JSOB("debug", debugReport()), null);
                return;
            }
            // {"close": true} closes it
            if (p.safe!bool("close").or(false))
            {
                immutable was = aboutDialog !is null;
                if (was)
                    aboutDialog.close();
                reply(JSOB("closed", was), null);
                return;
            }
            showAbout();
            reply(JSOB("opened", true), null);
            return;
        case "ai":
            {
                // the agents that sent this window requests, the latest ones, and how to connect one;
                // {"open": true} opens the AI Agents window, {"close": true} closes it
                import hackerscad.gui.aiwindow : agents, clientLabel, mcpCommand, skillCommands;
                if (p.safe!bool("open").or(false))
                    showAi();
                if (p.safe!bool("close").or(false) && aiWin !is null)
                    aiWin.close();
                auto r = JSOB("window", control ? control.name : "");
                JValue who = JSAB();
                foreach (c; agentLog.clients)
                    who ~= JValue(clientLabel(c));
                r["agents"] = who;
                JValue calls = JSAB();
                foreach (c; agentLog.calls)
                {
                    auto j = JSOB("time", c.when.toISOExtString(0), "client", c.client, "method", c.method);
                    if (c.error.length)
                        j["error"] = c.error;
                    calls ~= j;
                }
                r["calls"] = calls;
                JValue connect = JSOB();
                foreach (a; agents)
                    connect[a.name] = JSOB("mcp", mcpCommand(a), "skill", skillCommands(a));
                r["connect"] = connect;
                r["ai_window_open"] = aiWin !is null;
                reply(r, null);
                return;
            }
        case "annotate":
            {
                // marks on the locked 3D view, a whiteboard shared with the user (see
                // tool/annotations): {"add": [items]} locks the view if it is not, and returns the ids
                // (an item: {"arrow": [tail, tip]}, {"cross": P}, {"circle": P or [corner, corner]},
                // {"freehand": [P…]}, {"text": "…", "at": P}, with colour and label; a point is [x, y]
                // fractions of the view, {"px": [x, y]}, [x, y, z] mm, a part's name or {part, face});
                // {"remove": [ids]}; {"clear": true} all ({"clear": "agent"} or "user": one author's;
                // none left: back to the live view, unless the user is annotating); {"mode": true}
                // locks the view for the user to draw, false goes back to the live view (the marks go);
                // {"list": true}; {"save": "/path/view.png"} writes the view with its marks to a picture,
                // {"copy": true} puts it on the clipboard, for a person (the bar's Save and Copy).
                // In one call: mode, clear, remove, add, then save and copy
                whenIdle(() {
                    import hackerscad.tool.annotations : readAnnotation, Annotation;
                    if (has("mode"))
                    {
                        if (p["mode"].safe!bool.or(false))
                        {
                            if (!lockView(false))
                                return reply(JValue.init, "the 3D view is hidden: show it (view: true) to annotate it");
                        }
                        else if (!p["mode"].safe!bool.or(true))
                            unlockView();
                        else
                            return reply(JValue.init, "mode is true (annotate) or false (the live view)");
                    }
                    if (has("clear"))
                    {
                        auto c = p["clear"];
                        if (c.safe!bool.or(false))
                            clearNotes(null);
                        else if (c.isString && (c.get!string == "agent" || c.get!string == "user"))
                            clearNotes(c.get!string);
                        else if (!c.isBool)
                            return reply(JValue.init, "clear is true (all), \"agent\" or \"user\"");
                    }
                    JValue missing = JSAB();
                    if (has("remove"))
                    {
                        auto ids = p["remove"].isArray ? p["remove"].get!JArray.elements : [p["remove"]];
                        foreach (v; ids)
                        {
                            if (!v.isNumber)
                                return reply(JValue.init, "remove is a list of annotation ids");
                            if (notes.find(cast(uint) numberOf(v)) is null)
                                missing ~= v;
                            else
                                removeNote(cast(uint) numberOf(v));
                        }
                    }
                    JValue ids = JSAB();
                    if (has("add"))
                    {
                        immutable wasFrozen = frozen;
                        if (!lockView(false))
                            return reply(JValue.init, "the 3D view is hidden: show it (view: true) to annotate it");
                        auto items = p["add"].isArray ? p["add"].get!JArray.elements : [p["add"]];
                        Annotation[] adding;
                        foreach (k, it; items)
                        {
                            Annotation n;
                            if (auto problem = readAnnotation(it, &readNotePoint, viewW, viewH, n))
                            {
                                // nothing added: the view as it was
                                if (!wasFrozen)
                                    unlockView();
                                return reply(JValue.init, items.length > 1 ? format("item %d: %s", k, problem) : problem);
                            }
                            if (!it.has("by"))
                                n.by = "agent";
                            findUnder(n);
                            adding ~= n;
                        }
                        foreach (n; adding)
                            ids ~= notes.add(n);
                        notesChanged();
                    }
                    JValue r = JSOB("annotations", notes.toJson());
                    if (has("save") || p.safe!bool("copy").or(false))
                    {
                        if (!frozen)
                            return reply(JValue.init, "the view is not annotated: add marks (or mode: true) first");
                        if (has("save"))
                        {
                            import std.path : isAbsolute;
                            immutable file = arg("save");
                            if (!file.isAbsolute)
                                return reply(JValue.init, "save takes an absolute path to a .png file");
                            if (auto problem = writeAnnotated(file))
                                return reply(JValue.init, problem);
                            r["saved"] = file;
                        }
                        if (p.safe!bool("copy").or(false))
                        {
                            if (!copyAnnotated())
                                return reply(JValue.init, "the view could not be drawn (is the screen locked?)");
                            r["copied"] = true;
                        }
                    }
                    if (has("add"))
                        r["ids"] = ids;
                    if (missing.length)
                        r["not_found"] = missing;
                    r["annotate_mode"] = frozen;
                    reply(r, null);
                });
                return;
            }
        case "screenshot":
            {
                auto file = arg("path");
                if (file is null)
                    return reply(JValue.init, "missing 'path'");
                // the cheatsheet window, when asked for and open
                if (arg("target") == "cheatsheet" && cheatsheet is null)
                    return reply(JValue.init, "the cheatsheet is not open: open it with the cheatsheet method first");
                // the colour wheel (Colour › Other…), when open
                immutable wheelOpen = colourWheel !is null && colourWheel.win.getVisible();
                if (arg("target") == "colour" && !wheelOpen)
                    return reply(JValue.init, "the colour wheel is not open: open it with the colour method, wheel: true");
                // the About window, when open
                if (arg("target") == "about" && aboutDialog is null)
                    return reply(JValue.init, "the About window is not open: open it with the about method first");
                if (arg("target") == "ai" && aiWin is null)
                    return reply(JValue.init, "the AI Agents window is not open: open it with the ai method, open: true");
                // the drawing window: opened (on `drawing`, if given) when it is not
                if (arg("target") == "drawing")
                {
                    if (last.drawings.length == 0)
                        return reply(JValue.init, "the model has no @drawing: add a function marked @drawing returning drawing(…)");
                    showDrawing(arg("drawing"));
                }
                imported!"gtk.window".Window other = arg("target") == "cheatsheet" ? cheatsheet.widget
                    : arg("target") == "colour" ? colourWheel.win : arg("target") == "about" ? aboutDialog.window
                    : arg("target") == "ai" ? aiWin.window
                    : arg("target") == "drawing" ? drawingWin.window : null;
                // after a change GTK draws the window at its next frame, which
                // the compositor holds back while the window is hidden or
                // covered: wait for it a while, then fall back on the 3D view
                // alone, which OpenGL draws off screen
                int tries;
                bool attempt()
                {
                    if (screenshot(file, other))
                    {
                        reply(JSOB("path", file), null);
                        return false;
                    }
                    if (++tries < 10)
                    {
                        (other !is null ? other : window).queueDraw();
                        return true;
                    }
                    immutable w = max(640, viewport.area.getWidth()), h = max(480, viewport.area.getHeight());
                    auto pixels = other is null ? viewport.renderImage(w, h) : null;
                    if (pixels is null)
                    {
                        reply(JValue.init, "the window has not been drawn: is the screen locked?");
                        return false;
                    }
                    write(file, encodePng(pixels, w, h));
                    auto r = JSOB("path", file);
                    r["note"] = "the window is hidden or covered, so it has not been drawn since the latest change: "
                        ~ "this is the 3D view alone";
                    reply(r, null);
                    return false;
                }
                whenIdle(() {
                    if (attempt())
                        timeoutAdd(PRIORITY_DEFAULT, 100, &attempt);
                });
                return;
            }
        default:
            reply(JValue.init, "unknown method: " ~ method);
        }
    }
}
