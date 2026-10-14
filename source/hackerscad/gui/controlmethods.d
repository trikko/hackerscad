/// The methods of the control socket (what the hcad_gui_* tools of the MCP
/// server call): dispatchControl, mixed into MainWindow. A mixin's body is
/// compiled where it is mixed in, so it uses the window's members and
/// imports as its own; it lives here only to keep app.d to a readable size.
module hackerscad.gui.controlmethods;

mixin template ControlMethods()
{
    void dispatchControl(string method, JSONValue p, void delegate(JSONValue, string) reply)
    {
        string arg(string k) => k in p && p[k].type == JSONType.string ? p[k].str : null;
        bool has(string k) => k in p && p[k].type != JSONType.null_;
        switch (method)
        {
        case "open":
            {
                auto file = absolutePath(arg("path"));
                if (!exists(file))
                    return reply(JSONValue.init, "file not found: " ~ file);
                if (auto why = notAModel(file))
                    return reply(JSONValue.init, why ~ " To use a mesh or CAD file, write a model that calls load() on it.");
                if (modified && !("force" in p && p["force"].type == JSONType.true_))
                    return reply(JSONValue.init, "the user has unsaved changes in " ~ baseName(path)
                        ~ ": ask them to save, or pass force: true to discard them");
                load(file);
                whenIdle(() => reply(state(), null));
                return;
            }
        case "set":
            if (auto s = arg("source"))
                buffer.setText(s);
            // a preset first (it clears the values set by hand), then the
            // values given with it, on top
            if ("preset" in p)
            {
                params.preset = arg("preset");
                params.overrides = null;
            }
            if ("params" in p)
                foreach (k, v; toOverrides(p["params"]))
                    params.overrides[k] = v;
            params.invalidate();
            firstResult = true; // frame the changed model
            scheduleEvaluation(0);
            whenIdle(() => reply(state(), null));
            return;
        case "state":
            // after the running evaluation, or right away with "now": true
            // (then "evaluating" and "stage" tell how far it is)
            {
                immutable withSource = "source" in p && p["source"].type == JSONType.true_;
                JSONValue full()
                {
                    auto j = state();
                    if (withSource)
                    {
                        j["source"] = text();
                        j["steps"] = stepsPanel.rowsText();   // the Steps panel, row by row
                    }
                    return j;
                }
                if ("now" in p && p["now"].type == JSONType.true_)
                    reply(full(), null);
                else
                    whenIdle(() => reply(full(), null));
                return;
            }
        case "pick":
            {
                // click in the 3D view: at x, y (fractions of its size) or at a model point
                immutable shiftPick = "shift" in p && p["shift"].type == JSONType.true_;
                whenIdle(() {
                    double x, y;
                    if (auto problem = screenPoint(p, x, y))
                        return reply(JSONValue.init, problem);
                    auto hit = viewport.pickAt(x, y);
                    hit.shift = shiftPick;   // add to the selection, as Shift+click
                    picked(hit);
                    auto r = hitJson(hit);
                    r["status"] = infoLabel.getLabel();
                    reply(r, null);
                });
                return;
            }
        case "view":
            {
                import std.conv : to;
                alias num = numberOf;
                // moved as the user moves it: the frames count in graphics' figures
                if (has("preset") || has("look_at") || has("orbit") || has("pan") || has("zoom") || has("size"))
                    viewport.moved();
                // in the order a user would: frame, turn, move, zoom
                if (auto v = arg("preset"))
                {
                    if (v == "fit")
                        viewport.fit();
                    else
                        viewport.setView(v.to!ViewPreset);
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
                        return reply(JSONValue.init, "select is part, face, edge or vertex");
                    selectChoice[at].setActive(true);
                }
                // how shiny the surfaces are, as the cube's Shine choices (kept between runs)
                if (auto v = arg("shine"))
                {
                    import std.algorithm : countUntil;
                    immutable at = ["none", "normal", "high"].countUntil(v);
                    if (at < 0)
                        return reply(JSONValue.init, "shine must be none, normal or high");
                    shineChoice[at].setActive(true);
                }
                // the printability marks, over any style, as the cube's check box
                if (has("printability"))
                    printabilityChoice.setActive(p["printability"].type == JSONType.true_);
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
                        return reply(JSONValue.init, "theme must be system, light or dark");
                    StyleManager.getDefault().setColorScheme(schemeFor(v));
                }
                // antialiasing, for this run (the user's choice in the cube menu stays)
                if (has("antialias"))
                    viewport.setAntialias(p["antialias"].type == JSONType.true_);
                // what a left drag does, as the two buttons of the view bar
                if (auto v = arg("drag"))
                    (v == "pan" ? panMode : rotateMode).setActive(true);
                // the ground grid and the axes, as the eye's menu (kept between runs)
                if (has("grid"))
                    gridChoice.setActive(p["grid"].type == JSONType.true_);
                if (has("axes"))
                    axesChoice.setActive(p["axes"].type == JSONType.true_);
                // the parts hidden with the eye of the view bar
                if (has("hidden"))
                {
                    bool[string] hide;
                    foreach (n; p["hidden"].array)
                        hide[n.str] = true;
                    foreach (i, pm; last.parts)
                        setPartVisible(i, (pm.name in hide) is null);
                }
                // the cursor at the start of a line, the code scrolled there (and fully left)
                if (has("cursor"))
                {
                    TextIter at;
                    if (buffer.getIterAtLine(at, cast(int) p["cursor"].get!long - 1))
                    {
                        buffer.placeCursor(at);
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
                // a menu of the view bar opened, for a screenshot ("none" closes them)
                if (auto m = arg("menu"))
                {
                    foreach (b; [partsMenu, displayMenu, examplesButton, exportButton])
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
                }
                if (has("console"))
                    consoleToggle.setActive(p["console"].type == JSONType.true_);
                if (has("params"))
                    paramsToggle.setActive(p["params"].type == JSONType.true_);
                if (has("code"))
                    codeToggle.setActive(p["code"].type == JSONType.true_);
                if (has("view"))
                    viewToggle.setActive(p["view"].type == JSONType.true_);
                whenIdle(() => reply(state(), null));
                return;
            }
        case "split":
            {
                // {"part": "clip", "plane": "xy", "at": 7.5}: the part cut in two there in the code, as
                // Split…'s ✓ (the upper half in another colour); {"part": "clip", "show": true} opens
                // Split… on it for the user to place the plane, writing nothing; "show": false closes it
                whenIdle(() {
                    if ("show" in p && p["show"].type == JSONType.false_)
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
                        return reply(JSONValue.init, name is null ? "say which part" : "no part named '" ~ name ~ "'");
                    if ("show" in p && p["show"].type == JSONType.true_)
                    {
                        startSplit(index);
                        return reply(state(), null);
                    }
                    immutable plane = arg("plane");
                    auto n = plane == "xy" ? Vec3(0, 0, 1) : plane == "xz" ? Vec3(0, 1, 0) : plane == "yz" ? Vec3(1, 0, 0)
                        : Vec3(0, 0, 0);
                    if (n.length == 0)
                        return reply(JSONValue.init, "plane is xy, xz or yz");
                    if (!has("at"))
                        return reply(JSONValue.init, "at: where the plane is, in mm along its normal (z for xy)");
                    if (auto problem = writeSplit(index, n, numberOf(p["at"])))
                        return reply(JSONValue.init, problem);
                    whenIdle(() => reply(state(), null));
                });
                return;
            }
        case "colour":
            {
                // {"part": "lid", "colour": "Violet Pop"} or "#C597FE": the colour written on its @part,
                // as the right-click menu's Colour; {"hue": 250, "lightness": 0.76, "vividness": 0.15}
                // as its Other… wheel (OKLCH; the last two as the palette's when left out);
                // {"wheel": true} opens the wheel on the part for the user, writing nothing
                whenIdle(() {
                    auto name = arg("part");
                    int index = -1;
                    foreach (i, q; last.parts)
                        if (q.name == name || (name is null && last.parts.length == 1))
                            index = cast(int) i;
                    if (index < 0)
                        return reply(JSONValue.init, name is null ? "say which part" : "no part named '" ~ name ~ "'");
                    import hackerscad.geom.color : partPalette;
                    import std.ascii : isHexDigit;
                    import std.algorithm : all;
                    import std.uni : sicmp, toUpper;
                    // a palette name as the palette writes it, or #RRGGBB
                    if ("wheel" in p && p["wheel"].type == JSONType.true_)
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
                        return reply(JSONValue.init, "colour is one of " ~ names.join(", ") ~ ", or #RRGGBB");
                    }
                    if (auto problem = writeColour(last.parts[index].fn, colour))
                        return reply(JSONValue.init, problem);
                    whenIdle(() => reply(state(), null));
                });
                return;
            }
        case "transform":
            {
                // {"part": "lid", "move": [10, 0, 0]} or {"part": "lid", "rotate": {"axis": "z", "angle": 45}}:
                // the code Move… and Rotate… write (a turn is about the middle of the part's box);
                // {"part": "lid", "show": "move"} shows the frame (rotate: the rings), "none" takes it away
                whenIdle(() {
                    auto name = arg("part");
                    int index = -1;
                    foreach (i, q; last.parts)
                        if (q.name == name || (name is null && last.parts.length == 1))
                            index = cast(int) i;
                    if (index < 0)
                        return reply(JSONValue.init, name is null ? "say which part" : "no part named '" ~ name ~ "'");
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
                        else if (show == "move" || show == "rotate")
                            startTransform(show == "move" ? Viewport.Gizmo.move : Viewport.Gizmo.rotate, index);
                        else if (show == "hinge" && hasAxis && hingeAlong.length > 0)
                            startHinge(index, hingeAt, hingeAlong, "the axis");
                        else
                            return reply(JSONValue.init, "show is move, rotate, hinge (with origin and direction) or none");
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
                            if (q.type != JSONType.object || !(k in q) || q[k].type != JSONType.array || q[k].array.length != 3)
                                return reply(JSONValue.init, "place needs from, from_normal, to and to_normal, each [x, y, z]");
                        Vec3 axis;
                        double angle;
                        Viewport.faceTurn(v3("from_normal"), v3("to_normal"), axis, angle);
                        immutable spin = "spin" in q ? numberOf(q["spin"]) : 0;
                        // show: the placing previewed with its ring, for the user to spin and confirm
                        if ("show" in q && q["show"].type == JSONType.true_)
                        {
                            viewport.startPlace(index, v3("from"), v3("from_normal"));
                            viewport.previewPlace(v3("to"), v3("to_normal"));
                            transformTitle.setLabel("Place " ~ last.parts[index].name);
                            transformValue.setLabel(transformText());
                            transformBar.setVisible(true);
                            return reply(state(), null);
                        }
                        if (auto problem = writePlace(index, v3("from"), axis, angle, v3("to"), spin, v3("to_normal").normalized))
                            return reply(JSONValue.init, problem);
                        whenIdle(() => reply(state(), null));
                        return;
                    }
                    // a turn about any axis: {"hinge": 30, "origin": […], "direction": […]}
                    if (has("hinge"))
                    {
                        if (!hasAxis || hingeAlong.length == 0)
                            return reply(JSONValue.init, "hinge turns about an axis: give origin [x, y, z] (mm) and direction [x, y, z]");
                        if (auto problem = writeHinge(index, numberOf(p["hinge"]), hingeAt, hingeAlong))
                            return reply(JSONValue.init, problem);
                        whenIdle(() => reply(state(), null));
                        return;
                    }
                    string kind;
                    Vec3 v;
                    if (has("move"))
                    {
                        kind = "move";
                        if (p["move"].type != JSONType.array || p["move"].array.length != 3)
                            return reply(JSONValue.init, "move is [x, y, z] in mm");
                        foreach (i; 0 .. 3)
                            v[i] = numberOf(p["move"][i]);
                    }
                    else if (has("rotate"))
                    {
                        kind = "rotate";
                        auto r = p["rotate"];
                        immutable axis = r.type == JSONType.object && "axis" in r && r["axis"].type == JSONType.string
                            ? ["x": 0, "y": 1, "z": 2].get(r["axis"].str, -1) : -1;
                        if (axis < 0 || "angle" !in r)
                            return reply(JSONValue.init, "rotate is {\"axis\": \"x\", \"y\" or \"z\", \"angle\": degrees}");
                        v[axis] = numberOf(r["angle"]);
                    }
                    else
                        return reply(JSONValue.init, "give move, rotate or show");
                    cancelTransform();
                    if (auto problem = writeTransform(index, kind, v, last.parts[index].bbox.center))
                        return reply(JSONValue.init, problem);
                    whenIdle(() => reply(state(), null));
                });
                return;
            }
        case "feature":
            {
                // {"x": 0.5, "y": 0.4, "action": "fillet-edge", "value": "2.mm"}: what the context menu does,
                // on what is there or (use_selection) on the Shift selection that contains it
                auto act = arg("action"), value = arg("value"), kind = arg("kind"), size = arg("size");
                immutable useSelection = has("use_selection") && p["use_selection"].type == JSONType.true_;
                whenIdle(() {
                    double x, y;
                    if (auto problem = screenPoint(p, x, y))
                        return reply(JSONValue.init, problem);
                    // whatever the user's selection mode: the face there, and an edge near the point
                    auto hit = viewport.pickAny(x, y);
                    if (hit.part < 0)
                        return reply(JSONValue.init, "nothing under that point");
                    hit.edge = viewport.nearestEdge(hit.part, hit.face, x, y, 12);
                    if (!useSelection)
                        picked(hit);
                    setContext(hit);
                    auto code = contextCode(act, value, kind, size);
                    if (code.length == 0)
                        return reply(JSONValue.init, "unknown action, or it does not apply there: use fillet-edge, "
                            ~ "chamfer-edge (an edge), fillet-face, chamfer-face, shell, draft, extrude-face, push-face (faces), thread (size: an ISO size that fits the cylinder, e.g. M8), hole (kind: "
                            ~ "clearance, tap or insert; size: M2 to M8), pocket or boss (a face)");
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
            if (modified && !("force" in p && p["force"].type == JSONType.true_))
                return reply(JSONValue.init, "the model has unsaved changes: save it, or pass force: true to discard "
                    ~ "them (ask the user first)");
            // with "source": that code, in a model of no file (Save asks for a name): to show
            // an example the user can try things in without overwriting anything
            if ("source" in p && p["source"].type == JSONType.string)
            {
                startNew();
                agentText = null;
                buffer.setText(p["source"].str);
                modified = false;
                updateTitle();
            }
            // with "example": that example model instead of the template, as the Examples menu
            else if (auto ex = arg("example"))
            {
                if (!startExample(ex))
                    return reply(JSONValue.init, "no example named '" ~ ex ~ "': " ~ exampleNames());
            }
            else
                startNew();
            whenIdle(() => reply(state(), null));
            return;
        case "rename":
            {
                // the window's name, as clicking it in the header bar
                if (auto why = control.rename(arg("name")))
                    return reply(JSONValue.init, why);
                showWindowName();
                reply(state(), null);
                return;
            }
        case "menu":
            {
                // {"x": 0.5, "y": 0.5, "path": ["Hole at point", "Clearance", "M3"]}: the right-click menu there,
                // then its entries clicked in order; without path, the entries it has there; with
                // "open": true it stays open (path: groups to open), for a screenshot
                string[] path;
                immutable keep = "open" in p && p["open"].type == JSONType.true_;
                if ("path" in p && p["path"].type == JSONType.array)
                    foreach (v; p["path"].array)
                        path ~= v.str;
                immutable list = !("path" in p) || path.length == 0;
                whenIdle(() {
                    double x, y;
                    if (auto problem = screenPoint(p, x, y))
                        return reply(JSONValue.init, problem);
                    auto hit = viewport.pickAt(x, y);
                    // on empty space the menu lists the hidden parts, when there are some
                    bool anyHidden;
                    foreach (i; 0 .. last.parts.length)
                        anyHidden = anyHidden || viewport.isHidden(i);
                    if (hit.part < 0 && !anyHidden)
                        return reply(JSONValue.init, "nothing under that point: the menu opens on a part (or, on empty "
                            ~ "space, lists the hidden parts: none is hidden)");
                    contextMenu(hit, x, y);
                    if (list)
                    {
                        auto entries = lastMenuEntries();
                        if (!keep)
                            closeLastMenu();
                        return reply(JSONValue(["entries": menuJson(entries)]), null);
                    }
                    lastCopied = null;
                    if (auto problem = activateMenuPath(path))
                        return reply(JSONValue.init, problem);
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
                if ("on" in p && p["on"].type == JSONType.false_)
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
                    return reply(JSONValue.init, "plane must be xy, xz, yz or face");
                immutable changed = !wasOn || which != sectionPlane.getSelected() || which == 3;
                sectionUpdating = true;
                sectionPlane.setSelected(cast(uint) which);
                sectionUpdating = false;
                sectionToggle.setActive(true);
                if (changed)
                    updateSection(true);
                if ("at" in p)
                {
                    auto adj = sectionSlider.getAdjustment();
                    sectionSlider.setValue(adj.getLower() + p["at"].get!double * (adj.getUpper() - adj.getLower()));
                }
                if ("flip" in p)
                    sectionFlip.setActive(p["flip"].type == JSONType.true_);
                whenIdle(() {
                    auto r = state();
                    r["section"] = sectionLabel.getLabel();
                    reply(r, null);
                });
                return;
            }
        case "sketch":
            // {"on": true}: show the sketches with their dimensions; the reply lists them
            sketchToggle.setActive("on" !in p || p["on"].type != JSONType.false_);
            whenIdle(() {
                auto r = state();
                r["sketches"] = sketchesJson();
                reply(r, null);
            });
            return;
        case "step":
            {
                // {"row": 3}: a row of the Steps panel clicked (0-based, as state's steps lists them)
                if (!has("row"))
                    return reply(JSONValue.init, "give row: the index of the Steps panel row (state with source: true "
                        ~ "lists them)");
                sideStack.setVisibleChildName("steps");
                if (!stepsPanel.activate(cast(int) p["row"].get!long))
                    return reply(JSONValue.init, "no such row, or it is a heading");
                whenIdle(() => reply(state(), null));
                return;
            }
        case "dimension":
            {
                // {"line": 12, "col": 30, "value": "40.mm"}: a sketch dimension changed, as clicking it
                if (!has("line") || !has("col") || arg("value").length == 0)
                    return reply(JSONValue.init, "give line and col of the dimension (hcad_gui_sketch lists them) and "
                        ~ "the new value");
                try
                {
                    auto e = replaceArgument(text(), path, cast(uint) p["line"].get!long, cast(uint) p["col"].get!long,
                        arg("value"));
                    applyEdit(e);
                }
                catch (Exception ex)
                    return reply(JSONValue.init, ex.msg);
                whenIdle(() {
                    auto r = state();
                    r["sketches"] = sketchesJson();
                    reply(r, null);
                });
                return;
            }
        case "inspect":
            {
                // {"line": 12, "to_line": 20} or {"function": "lever"}: what that code made; nothing: back to the model
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
                                    return reply(JSONValue.init, format("'%s' returned no solid, profile or path", name));
                                return whenIdle(() => reply(state(), null));
                            }
                            names ~= fn.name;
                        }
                        return reply(JSONValue.init, format("no function '%s' in the model (there are: %s)", name,
                            names.join(", ")));
                    }
                    immutable from = cast(uint) p["line"].get!long;
                    immutable to = has("to_line") ? cast(uint) p["to_line"].get!long : from;
                    if (!inspectLines(from, max(from, to), -1))
                        return reply(JSONValue.init, from == to ? format("line %d made no solid, profile or path", from)
                            : format("lines %d–%d made no solid, profile or path", from, to));
                    whenIdle(() => reply(state(), null));
                });
                return;
            }
        case "rollback":
            {
                // {"line": 12}: the model right after the feature on that line; no line: the final model
                if ("line" !in p)
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
                    return reply(JSONValue.init, format("no feature on line %d", line));
                rollTo(id);
                whenIdle(() => reply(state(), null));
                return;
            }
        case "export":
            {
                // the window's model as shown (parameters, preset): .3mf .stl .step .png
                auto file = arg("path");
                if (file is null)
                    return reply(JSONValue.init, "missing 'path'");
                whenIdle(() {
                    try
                    {
                        string[] only;
                        if ("parts" in p && p["parts"].type == JSONType.array)
                            foreach (v; p["parts"].array)
                                only ~= v.str;
                        auto warnings = exportTo(file, only, has("one_object") && p["one_object"].type == JSONType.true_);
                        note("exported " ~ file);
                        JSONValue r = ["path": file];
                        if (warnings.length)
                            r["warnings"] = warnings;
                        reply(r, null);
                    }
                    catch (Exception e)
                        reply(JSONValue.init, e.msg);
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
                if ("line" in p)
                {
                    TextIter it;
                    buffer.getIterAtLineOffset(it, cast(int) p["line"].integer - 1,
                        "col" in p ? cast(int) p["col"].integer - 1 : 0);
                    at = toUTFindex(src, it.getOffset());
                    if ("show" in p && p["show"].boolean)
                    {
                        buffer.placeCursor(it);
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
                JSONValue[] items;
                foreach (c; r.items[0 .. $ < 50 ? $ : 50])
                    items ~= JSONValue(["label": c.label, "kind": c.kind, "detail": c.detail, "doc": c.doc]);
                JSONValue j = ["prefix": r.prefix];
                j["items"] = items;
                if (r.signature.length)
                {
                    j["signature"] = r.signature;
                    j["activeParam"] = r.activeParam;
                    // the ways to call it, when its parameters are alternatives
                    if (r.forms.length)
                        j["forms"] = r.forms;
                }
                if ("show" in p && p["show"].boolean)
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
            reply(JSONValue(["opened": true]), null);
            return;
        case "save":
            {
                // to the window's file, or to path (then the window follows it, like Save As)
                auto target = arg("path").length ? absolutePath(arg("path")) : path;
                if (baseName(target) == "untitled.hcad" && !exists(target))
                    return reply(JSONValue.init, "the model has no file yet: pass path");
                if (target != path && exists(target) && !("force" in p && p["force"].type == JSONType.true_))
                    return reply(JSONValue.init, target ~ " exists: pass force: true to overwrite it (ask the user first)");
                try
                    write(target, text());
                catch (Exception e)
                    return reply(JSONValue.init, "cannot save: " ~ e.msg);
                path = target;
                diskTime = mtimeOf(path);
                modified = false;
                updateTitle();
                note("saved " ~ path);
                return reply(state(), null);
            }
        case "edit":
            {
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
                        return reply(JSONValue.init, "'old' is not in the code (hcad_gui_state with source: true shows it)");
                    if (src[at + old.length .. $].indexOf(old) >= 0)
                        return reply(JSONValue.init, "'old' appears more than once: include more of the code around it");
                    buffer.getIterAtOffset(a, cast(int) count(src[0 .. at]));
                    buffer.getIterAtOffset(b, cast(int) count(src[0 .. at + old.length]));
                    with_ = arg("new");
                }
                else if (has("lines") || has("insert"))
                {
                    immutable from = cast(int) numberOf(has("lines") ? p["lines"][0] : p["insert"]);
                    immutable to = has("lines") ? cast(int) numberOf(p["lines"][1]) : from - 1;
                    if (from < 1 || from > lineCount + 1 || to < from - 1 || to > lineCount)
                        return reply(JSONValue.init, format("lines out of range: the code has %d lines", lineCount));
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
                    return reply(JSONValue.init, "pass old and new, lines and text, or insert and text");
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
                    r["lines"] = [first, max(first, lastLine)];
                    reply(r, null);
                });
                return;
            }
        case "undo":
            {
                // {"redo": true} redoes; "steps" repeats
                immutable redo = "redo" in p && p["redo"].type == JSONType.true_;
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
                    return reply(JSONValue.init, redo ? "nothing to redo" : "nothing to undo");
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
                    JSONValue r = JSONValue((JSONValue[string]).init);
                    if (has("points"))
                    {
                        JSONValue[] out_;
                        foreach (v; p["points"].array)
                        {
                            double fx, fy;
                            bool visible;
                            if (viewport.fractionOf(vec3Of(v), fx, fy, visible))
                            {
                                JSONValue j = ["x": fx, "y": fy];
                                j["visible"] = visible && fx >= 0 && fx <= 1 && fy >= 0 && fy <= 1;
                                out_ ~= j;
                            }
                            else
                                out_ ~= JSONValue(["behind_camera": true]);
                        }
                        r["points"] = out_;
                    }
                    if (has("screen"))
                    {
                        JSONValue[] out_;
                        foreach (v; p["screen"].array)
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
                    if ("clear" in p && p["clear"].type == JSONType.true_)
                        clearSelection();
                    if (auto expr = arg("selector"))
                    {
                        string problem;
                        immutable pi = partIndex(arg("part"), problem);
                        if (pi < 0)
                            return reply(JSONValue.init, problem);
                        auto part = last.parts[pi];
                        SolidVal sv;
                        auto it = selectorInterp(part, sv);
                        bool faces;
                        int[] found;
                        try
                            found = it.trySelector(expr, sv, faces);
                        catch (Exception e)
                            return reply(JSONValue.init, e.msg);
                        if (found.length == 0)
                            return reply(JSONValue.init, expr ~ " selects nothing on " ~ part.name);
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
                    if (auto problem = measureItem(has("a") ? p["a"] : JSONValue(null), next, ia, pa))
                        return reply(JSONValue.init, problem);
                    if (auto problem = measureItem(has("b") ? p["b"] : JSONValue(null), next, ib, pb))
                        return reply(JSONValue.init, problem);
                    JSONValue r;
                    if (pa >= 0 && pb >= 0)
                    {
                        // two parts: exact, on the solids
                        Vec3 onA, onB;
                        auto d = last.parts[pa].kernel.distance(last.parts[pa].brep, last.parts[pb].brep, onA, onB);
                        r = JSONValue(["distance": d]);
                        r["on_a"] = jsonOf(onA);
                        r["on_b"] = jsonOf(onB);
                    }
                    else
                    {
                        auto m = measure(ia, ib);
                        r = JSONValue(["distance": m.distance]);
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
                reply(JSONValue(["stopped": was]), null);
                return;
            }
        case "about":
            showAbout();
            reply(JSONValue(["opened": true]), null);
            return;
        case "screenshot":
            {
                auto file = arg("path");
                if (file is null)
                    return reply(JSONValue.init, "missing 'path'");
                // the cheatsheet window, when asked for and open
                if (arg("target") == "cheatsheet" && cheatsheet is null)
                    return reply(JSONValue.init, "the cheatsheet is not open: open it with the cheatsheet method first");
                // the colour wheel (Colour › Other…), when open
                immutable wheelOpen = colourWheel !is null && colourWheel.win.getVisible();
                if (arg("target") == "colour" && !wheelOpen)
                    return reply(JSONValue.init, "the colour wheel is not open: open it with the colour method, wheel: true");
                imported!"gtk.window".Window other = arg("target") == "cheatsheet" ? cheatsheet.widget
                    : arg("target") == "colour" ? colourWheel.win : null;
                // after a change GTK draws the window at its next frame, which
                // the compositor holds back while the window is hidden or
                // covered: wait for it a while, then fall back on the 3D view
                // alone, which OpenGL draws off screen
                int tries;
                bool attempt()
                {
                    if (screenshot(file, other))
                    {
                        reply(JSONValue(["path": file]), null);
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
                        reply(JSONValue.init, "the window has not been drawn: is the screen locked?");
                        return false;
                    }
                    write(file, encodePng(pixels, w, h));
                    auto r = JSONValue(["path": file]);
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
            reply(JSONValue.init, "unknown method: " ~ method);
        }
    }
}
