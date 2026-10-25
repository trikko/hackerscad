/// The sketch at the editor's cursor, and the sketches kept on screen while
/// the code is being edited: SketchFollow, mixed into MainWindow (as
/// ControlMethods is), so it uses the window's members and imports as its
/// own; it lives here only to keep app.d to a readable size.
///
/// A sketch owns stretches of code (lang/sketchval.d, stretchesOf): from its
/// first call to its last in the function that made it, and the body of a
/// helper function it was handed to. While the cursor is in one, and nothing
/// the user chose is shown (a step, Inspect, a rollback, a sketch picked) and
/// no tool is at work (moving a part, a section, a split), the view shows
/// that sketch as Inspect of one of its lines does; out of it, the model as
/// it was. When the code has an error, the sketches made before it are shown
/// (partial), and the last good one where the error is in its code or where
/// the run stopped before making it (stale, drawn faint). Marks in the editor
/// keep their lines right while lines are added or removed above them.
module hackerscad.gui.sketchfollow;

import gtk.text_mark : TextMark;
import hackerscad.gui.menu : MenuEntry;
import hackerscad.lang.sketchval : SketchView, Stretch;

/// Marks in the editor at the lines a result's sketches name: lines added or
/// removed above them move the marks, and the sketches' lines with them.
final class LineMarks
{
    TextMark[uint] at;   /// by line of the code that was evaluated
}

/// A sketch of a result, with the lines of the code it was evaluated from.
struct HeldSketch
{
    SketchView view;
    Stretch[] stretches;
    LineMarks marks;
    bool stale;   /// the last good one, shown while the code has an error in it
}

mixin template SketchFollow()
{
    HeldSketch[] held;        /// what last.sketches is made from, in the same order
    HeldSketch[] goodHeld;    /// the sketches of the last result that evaluated
    LineMarks[] markSets;     /// every set of marks in the buffer
    Stretch[][] stretches;    /// of last.sketches, in the lines of the code now
    bool[] staleSketch;       /// by last.sketches: the last good one, shown faint
    uint sketchErrorLine;     /// the error partial and stale sketches are shown under (0: none)
    bool sketchConflict;      /// that error is a sketch's (its constraints conflict): the sketch shows it
    int heldLineCount = -1;   /// the code's line count when last.sketches were brought up to date

    bool followCursor = true;      /// the setting: Show the sketch at the cursor
    bool sketchFollowing;          /// the sketch shown is the one at the cursor
    bool sketchPinned;             /// …and stays when the cursor leaves its code
    Span followSpan;               /// its sketch() call, in the lines of the code now
    size_t followSharing;          /// other sketches drawing on the function the cursor is in
    Viewport.Camera followCamera;  /// the camera before it was shown, back when it goes
    uint followTimer;
    int quietCursor = -1;          /// where the program put the cursor (a click in the view): not followed
    bool followArmed;              /// the user moved the cursor since the code was loaded
    Span followDismissed;          /// closed with Esc: not shown again while the cursor stays on its line
    uint followDismissedLine;      /// that line
    ToggleButton pinButton;        /// in the mode bar
    bool pinUpdating;
    import gtk.check_button : CheckButton;
    CheckButton followChoice;      /// in the display menu
    import gio.menu : SketchMenu = Menu;
    SketchMenu sketchMenu;         /// View › Sketches
    size_t[] sketchMenuIndices;    /// its entries, by index in last.sketches
    MenuButton viewMenuButton;

    static bool sameCall(const Span a, const Span b) => a.file == b.file && a.line == b.line && a.col == b.col;

    // ---- the sketches kept while the code is edited

    /// The sketches of a new result: those it made when it evaluated. With
    /// an error, those made before it (partial), but the last good one where
    /// the error is in its code (except a conflict of its constraints, which
    /// the new one shows in red) or where the run stopped before making it
    /// (the code does not parse, an error above it): stale, drawn faint.
    void holdSketches(Outcome o)
    {
        import std.algorithm : sort, SwapStrategy;
        import hackerscad.lang.sketchval : stretchesOf;
        immutable file = absolutePath(path);
        auto marks = new LineMarks;
        HeldSketch[] fresh;
        foreach (v; o.sketches)
            fresh ~= HeldSketch(v, stretchesOf(v, file, o.functions), marks);
        sketchErrorLine = 0;
        if (o.ok)
            held = goodHeld = fresh;
        else
        {
            Diagnostic err;
            foreach (d; o.diagnostics)
                if (d.severity == Severity.error)
                {
                    err = d;
                    break;
                }
            immutable errLine = err.span.file == file ? err.span.line : 0;
            sketchErrorLine = errLine;
            sketchConflict = err.code == Code.sketch;
            HeldSketch[] kept;
            Span[] replaced;
            foreach (g; goodHeld)
            {
                auto now = remapped(g);
                bool inside, made;
                foreach (st; now.stretches)
                    inside = inside || (errLine >= st.from && errLine <= st.to);
                foreach (f; fresh)
                    made = made || sameCall(f.view.span, now.view.span);
                if ((inside && err.code != Code.sketch) || !made)
                {
                    g.stale = true;
                    kept ~= g;
                    replaced ~= now.view.span;
                }
            }
            HeldSketch[] r;
            foreach (f; fresh)
                if (!replaced.canFind!(sp => sameCall(sp, f.view.span)))
                    r ~= f;
            r ~= kept;
            // in the order of the code: the last made wins a tie at the cursor
            r.sort!((a, b) => lineNow(a.marks, a.view.span.line) < lineNow(b.marks, b.view.span.line),
                SwapStrategy.stable);
            held = r;
        }
        markLines(marks, fresh);
        markSets ~= marks;
        dropUnusedMarks();
        bringSketchesUp();
    }

    /// Line `l` of the code a result was evaluated from, in the code now.
    uint lineNow(LineMarks m, uint l)
    {
        if (m is null)
            return l;
        if (auto mark = l in m.at)
        {
            TextIter it;
            buffer.getIterAtMark(it, *mark);
            return it.getLine() + 1;
        }
        return l;
    }

    /// A held sketch with the lines of the code now.
    HeldSketch remapped(HeldSketch h)
    {
        immutable file = absolutePath(path);
        void fix(ref Span s)
        {
            if (s.file == file && s.line > 0)
                s.line = lineNow(h.marks, s.line);
        }
        auto v = h.view;
        fix(v.span);
        v.entities = v.entities.dup;
        foreach (ref e; v.entities)
            fix(e.span);
        v.points = v.points.dup;
        foreach (ref p; v.points)
            fix(p.span);
        v.segments = v.segments.dup;
        foreach (ref g; v.segments)
            fix(g.span);
        v.dimensions = v.dimensions.dup;
        foreach (ref d; v.dimensions)
            fix(d.value);
        v.constraints = v.constraints.dup;
        foreach (ref c; v.constraints)
            fix(c.span);
        v.profiles = v.profiles.dup;
        foreach (ref p; v.profiles)
            fix(p);
        auto r = h;
        r.view = v;
        r.stretches = h.stretches.dup;
        foreach (ref st; r.stretches)
        {
            st.from = lineNow(h.marks, st.from);
            st.to = lineNow(h.marks, st.to);
        }
        return r;
    }

    /// A mark at the start of every line the sketches name.
    void markLines(LineMarks marks, HeldSketch[] sketches)
    {
        immutable file = absolutePath(path);
        immutable count = buffer.getLineCount();
        void line(uint l)
        {
            if (l == 0 || l > count || (l in marks.at) !is null)
                return;
            TextIter it;
            if (buffer.getIterAtLine(it, l - 1))
                marks.at[l] = buffer.createMark(null, it, false);   // text typed at the line's start goes before it
        }
        void add(const Span s)
        {
            if (s.file == file)
                line(s.line);
        }
        foreach (h; sketches)
        {
            add(h.view.span);
            foreach (e; h.view.entities)
                add(e.span);
            foreach (p; h.view.points)
                add(p.span);
            foreach (g; h.view.segments)
                add(g.span);
            foreach (d; h.view.dimensions)
                add(d.value);
            foreach (c; h.view.constraints)
                add(c.span);
            foreach (p; h.view.profiles)
                add(p);
            foreach (st; h.stretches)
            {
                line(st.from);
                line(st.to);
            }
        }
    }

    /// The marks no held sketch uses leave the buffer.
    void dropUnusedMarks()
    {
        LineMarks[] still;
        foreach (m; markSets)
        {
            bool used;
            foreach (h; held ~ goodHeld)
                used = used || h.marks is m;
            if (used)
                still ~= m;
            else
                foreach (mark; m.at)
                    buffer.deleteMark(mark);
        }
        markSets = still;
    }

    /// last.sketches, their stretches and which are stale, in the lines of the code now.
    void bringSketchesUp()
    {
        SketchView[] views;
        Stretch[][] sts;
        bool[] stale;
        foreach (h; held)
        {
            auto now = remapped(h);
            views ~= now.view;
            sts ~= now.stretches;
            stale ~= h.stale;
        }
        last.sketches = views;
        stretches = sts;
        staleSketch = stale;
        heldLineCount = buffer.getLineCount();
    }

    /// Lines were added or removed: the sketches' lines follow their marks.
    void sketchLinesMoved()
    {
        if (held.length == 0 || buffer.getLineCount() == heldLineCount)
            return;
        bringSketchesUp();
        if (sketchFollowing && sketchIndices.length && sketchIndices[0] < last.sketches.length)
            followSpan = last.sketches[sketchIndices[0]].span;
        if (sketchIndices.length)
            updateDimensions();   // their buttons edit the value where it is now
        updateSketchMenu();
    }

    /// Another model: nothing of the previous one's sketches stays.
    void dropSketches()
    {
        held = goodHeld = null;
        dropUnusedMarks();
        stretches = null;
        staleSketch = null;
        last.sketches = null;
        sketchErrorLine = 0;
        followDismissed = Span.init;
        disarmFollow();
    }

    /// Whether the sketch shown is the last good one, or one made before an error.
    bool shownStale()
    {
        foreach (i; sketchIndices)
            if (i < staleSketch.length && staleSketch[i])
                return true;
        return false;
    }

    bool shownPartial()
    {
        foreach (i; sketchIndices)
            if (i < last.sketches.length && last.sketches[i].partial)
                return true;
        return false;
    }

    /// What the mode bar says first when the sketch shown is not the code's as it is.
    string sketchStateNote()
    {
        immutable where = sketchErrorLine ? format("line %d: ", sketchErrorLine) : "";
        if (shownStale())
            return where ~ "error — showing the last good sketch";
        if (shownPartial() && !sketchConflict)
            return where ~ "error — the sketch as made before it";
        return "";
    }

    // ---- the sketch at the cursor

    /// The editor's cursor moved (typing moves it too): in a moment, the
    /// sketch it is in (not at every key).
    void cursorMoved()
    {
        TextIter it;
        buffer.getIterAtMark(it, buffer.getInsert());
        if (it.getOffset() == quietCursor)
            return;
        quietCursor = -1;
        followArmed = true;
        if (followTimer)
            Source.remove(followTimer);
        followTimer = timeoutAdd(PRIORITY_DEFAULT, 150, () {
            followTimer = 0;
            followSketch(false);
            return false;
        });
    }

    /// Places the cursor for the program (a click in the view, a step's
    /// line, a screenshot): the view does not follow it.
    void placeCursorQuietly(TextIter at)
    {
        quietCursor = at.getOffset();
        buffer.placeCursor(at);
    }

    /// The code was replaced (another model): the cursor is not the user's yet.
    void disarmFollow()
    {
        if (followTimer)
            Source.remove(followTimer);
        followTimer = 0;
        followArmed = false;
    }

    /// Replaces the whole code, as loading a model does.
    void replaceCode(string code)
    {
        // another model: built, whether or not the window rebuilds as one types
        programEdit = true;
        scope (exit)
            programEdit = false;
        buffer.setText(code);
        disarmFollow();
    }

    /// Something the user chose is shown (a step, Inspect, a rollback, a
    /// sketch picked) or a tool is at work (moving a part, a section, a
    /// split): the cursor leaves the view alone.
    bool followHeld()
    {
        if (viewport.inRollback || viewport.gizmo != Viewport.Gizmo.none || viewport.placing || sectionToggle.getActive()
            || frozen)   // the view is annotated: it does not change under the marks
            return true;
        return !sketchFollowing && (viewport.inInspect || sketchIndices.length > 0);
    }

    /// The runs of the sketch made by the sketch() call at `call` (a sketch
    /// made in a loop, or by a function called again, has several).
    size_t[] runsOf(Span call)
    {
        size_t[] r;
        foreach (i, sk; last.sketches)
            if (sameCall(sk.span, call))
                r ~= i;
        return r;
    }

    /// Shows the sketch whose code the cursor is in, what the cursor's line
    /// makes or constrains in orange; out of every sketch's code, the model
    /// as it was (unless pinned). `refresh`: a new result, or the setting
    /// turned on (a selection does not hold it back then).
    void followSketch(bool refresh)
    {
        import hackerscad.lang.sketchval : sketchAt;
        if (!followCursor || (!followArmed && !sketchFollowing) || followHeld())
            return;
        if ((!refresh || !sketchFollowing) && buffer.getHasSelection())
            return;   // a selection being made: the view stays as it is
        TextIter it;
        buffer.getIterAtMark(it, buffer.getInsert());
        immutable line = it.getLine() + 1;
        immutable col = it.getLineOffset() + 1;
        immutable file = absolutePath(path);
        ptrdiff_t prefer = -1;
        if (sketchFollowing)
        {
            auto runs = runsOf(followSpan);
            if (runs.length)
                prefer = runs[0];
        }
        auto at = sketchAt(last.sketches, stretches, file, line, prefer);
        if (at.index >= 0 && sameCall(last.sketches[at.index].span, followDismissed))
        {
            if (line == followDismissedLine)
                return;   // closed with Esc: not again while the cursor stays where it was
            followDismissed = Span.init;   // the cursor moved on: shown again
        }
        if (at.index < 0)
        {
            // out of every sketch: the one closed may be shown again, once the cursor has left its line (the
            // code just rewritten, the sketches not yet evaluated, may not know the line is still in it)
            if (line != followDismissedLine)
                followDismissed = Span.init;
            if (!sketchFollowing)
                return;
            auto runs = runsOf(followSpan);
            // pinned, or a line the sketch bar just wrote (not yet part of the sketch until evaluated): it stays
            if ((!sketchPinned && !sketchEditHold) || runs.length == 0)
                return unfollow();
            return showFollowed(runs, line, col, 0, false);   // pinned: the same sketch, nothing in orange
        }
        showFollowed(runsOf(last.sketches[at.index].span), line, col, at.sharing, true);
    }

    /// Draws sketch `runs` as Inspect of a line of it does (from above, the
    /// parts as ghosts), for the cursor at line, col.
    void showFollowed(size_t[] runs, uint line, int col, size_t sharing, bool lit)
    {
        immutable file = absolutePath(path);
        if (!sketchFollowing)
            followCamera = viewport.camera();
        SketchView.Found[] found;
        foreach (i; runs)
            found ~= lit ? last.sketches[i].on(file, line, line) : SketchView.Found.init;
        inspectRequest++;   // what a previous Inspect is still computing is not needed
        drawSketches(runs, found, line, line, lit);
        inspectQuery = InspectQuery.init;   // a new result: the cursor decides again, not Inspect
        inspectShown = null;
        inspectMeshes = null;
        viewport.showInspect(null);
        sketchFollowing = true;
        followSpan = last.sketches[runs[0]].span;
        followSharing = sharing;
        auto sk = last.sketches[runs[0]];
        bool any;
        foreach (f; found)
            any = any || f.highlight.length > 0;
        string what;
        if (!lit)
            what = format("Sketch of line %d, pinned", sk.span.line);
        else if (sharing)
            what = format("Sketch of line %d: line %d is in a function %d sketches share", sk.span.line, line, sharing + 1);
        else
            what = format("Sketch of line %d at the cursor%s", sk.span.line, any ? format(": line %d in orange", line) : "");
        info(lit ? format("line %d · %s", line, sketchFoundText()) : sketchFoundText());
        // the code has an error: that first (the rest is in the info line)
        immutable note = sketchStateNote();
        showModeBar(note.length ? note : what);
    }

    /// The cursor left the sketch's code: the model as it was, seen as it was.
    void unfollow()
    {
        if (!sketchFollowing)
            return;
        sketchFollowing = false;
        setPinned(false);
        stopInspect();   // the ghosts go, and with them the sketch and the bar
        hideSketch();
        viewport.setCamera(followCamera);
        info("");
    }

    /// The sketch at the cursor is closed (Esc, Show final model): the
    /// camera goes back, and the sketch stays closed until the cursor moves
    /// to another line. Called by hideSketch.
    void followClosed()
    {
        if (!sketchFollowing)
            return;
        followDismissed = followSpan;
        {
            TextIter it;
            buffer.getIterAtMark(it, buffer.getInsert());
            followDismissedLine = it.getLine() + 1;
        }
        sketchFollowing = false;
        setPinned(false);
        viewport.setCamera(followCamera);
    }

    /// Something the user chose (a step, Inspect, the socket) takes the view
    /// over from the cursor: it stays as that leaves it.
    void followTakenOver()
    {
        if (!sketchFollowing)
            return;
        sketchFollowing = false;
        setPinned(false);
    }

    void setPinned(bool on)
    {
        sketchPinned = on;
        if (pinButton !is null && pinButton.getActive() != on)
        {
            pinUpdating = true;
            pinButton.setActive(on);
            pinUpdating = false;
        }
    }

    /// The pin of the mode bar: the sketch at the cursor stays when it leaves.
    ToggleButton makePinButton()
    {
        pinButton = new ToggleButton;
        pinButton.setIconName("hcad-pin-symbolic");
        pinButton.setTooltipText("Keep this sketch shown when the cursor leaves its code (Esc closes it)");
        pinButton.addCssClass("flat");
        pinButton.setVisible(false);
        pinButton.connectToggled(() {
            if (pinUpdating)
                return;
            sketchPinned = pinButton.getActive();
            if (sketchFollowing)
                followSketch(true);   // unpinned out of its code: it goes
        });
        return pinButton;
    }

    /// The setting Show the sketch at the cursor (the display menu, the socket's sketch {follow}).
    void setFollow(bool on)
    {
        import hackerscad.gui.settings : setSetting;
        followCursor = on;
        setSetting("sketch-follow", on ? "on" : "off");
        if (followChoice !is null && followChoice.getActive() != on)
            followChoice.setActive(on);
        if (!on)
            unfollow();
        else
            followSketch(true);
    }

    /// Shows sketch `index` to edit it: the cursor on its sketch() call,
    /// the sketch from above (Edit sketch… on a face, View › Sketches).
    void openSketch(size_t index)
    {
        if (sceneLocked())
            return;
        if (index >= last.sketches.length)
            return;
        auto sk = last.sketches[index];
        showFinal();
        followDismissed = Span.init;
        TextIter at;
        if (sk.span.file != absolutePath(path) || !buffer.getIterAtLine(at, sk.span.line - 1))
            return;
        placeCursorQuietly(at);
        editor.scrollToIter(at, 0.1, true, 0, 0.3);
        editor.grabFocus();
        if (followCursor)
        {
            followArmed = true;
            showFollowed(runsOf(sk.span), sk.span.line, 1, 0, true);
        }
        else
            inspectSketch(sk.span.line, sk.span.line, false);
    }

    /// The sketch a face of a part comes from, by index in last.sketches
    /// (-1: none): through the features, from the face's feature back to
    /// the "sketch" feature of the profile it was made from (an extrude,
    /// revolve, sweep or loft of it, moved or combined on the way). With no
    /// such link (the profile's own faces were lost on the way), for a
    /// feature made from a profile, the sketch whose stretch holds the
    /// feature's line.
    ptrdiff_t sketchOfFace(PartMesh part, int face)
    {
        import hackerscad.lang.sketchval : sketchAt;
        if (face < 0 || face >= part.creators.length)
            return -1;
        immutable file = absolutePath(path);
        immutable first = part.creators[face];
        uint[] todo = [first];
        bool[uint] seen;
        while (todo.length)
        {
            immutable id = todo[0];
            todo = todo[1 .. $];
            if (id == 0 || id > last.features.length || (id in seen) !is null)
                continue;
            seen[id] = true;
            auto f = last.features[id - 1];
            if (f.kind == "sketch" && f.span.file == file)
                foreach (i, h; held)
                    if (!h.stale && sameCall(h.view.span, f.span))
                        return i;
            todo ~= f.from;
        }
        if (first == 0 || first > last.features.length)
            return -1;
        auto f = last.features[first - 1];
        if (f.from.length == 0 || f.span.file != file)
            return -1;
        // the features' lines are those of the code evaluated: so are the held sketches'
        SketchView[] views;
        Stretch[][] sts;
        foreach (h; held)
        {
            views ~= h.stale ? SketchView.init : h.view;
            sts ~= h.stale ? null : h.stretches;
        }
        return sketchAt(views, sts, file, f.span.line).index;
    }

    // ---- View › Sketches

    /// "line 12 · 4 dimensions · fully constrained"
    string sketchMenuLabel(size_t i)
    {
        auto sk = last.sketches[i];
        immutable dims = sk.dimensions.length == 1 ? "1 dimension" : format("%d dimensions", sk.dimensions.length);
        immutable state = !sk.solved ? "conflicting" : sk.dof ? format("%d free", sk.dof) : "fully constrained";
        immutable note = i < staleSketch.length && staleSketch[i] ? " · last good" : sk.partial ? " · before an error" : "";
        return format("line %d · %s · %s%s", sk.span.line, dims, state, note);
    }

    /// The model's sketches, one entry each (a sketch made several times once).
    size_t[] distinctSketches()
    {
        size_t[] r;
        Span[] seen;
        foreach (i, sk; last.sketches)
            if (!seen.canFind!(s => sameCall(s, sk.span)))
            {
                seen ~= sk.span;
                r ~= i;
            }
        return r;
    }

    void updateSketchMenu()
    {
        if (sketchMenu is null)
            return;
        sketchMenu.removeAll();
        sketchMenuIndices = distinctSketches();
        foreach (k, i; sketchMenuIndices)
            sketchMenu.append(sketchMenuLabel(i), format("win.open-sketch::%d", k));
        if (sketchMenuIndices.length == 0)
            sketchMenu.append("No sketch in the model", "win.no-sketch");
    }

    /// The action of View › Sketches' entries: the k-th sketch of the list.
    void sketchMenuAction()
    {
        import glib.variant : Variant;
        import glib.variant_type : VariantType;
        auto a = new SimpleAction("open-sketch", new VariantType("s"));
        a.connectActivate((Variant v, SimpleAction self) {
            import std.conv : to, ConvException;
            try
            {
                immutable k = v.getString().to!size_t;
                if (k < sketchMenuIndices.length)
                    openSketch(sketchMenuIndices[k]);
            }
            catch (ConvException)
            {
            }
        });
        window.addAction(a);
    }

    /// The View menu as menu entries, for the socket's menu {bar: "view"}.
    MenuEntry[] viewMenuEntries()
    {
        MenuEntry[] presets = [MenuEntry.item("Iso", () => viewport.setView(ViewPreset.iso)),
            MenuEntry.item("Top", () => viewport.setView(ViewPreset.top)),
            MenuEntry.item("Front", () => viewport.setView(ViewPreset.front)),
            MenuEntry.item("Right", () => viewport.setView(ViewPreset.right))];
        MenuEntry[] list;
        foreach (i; distinctSketches())
        {
            immutable index = i;
            list ~= MenuEntry.item(sketchMenuLabel(i), () => openSketch(index));
        }
        if (list.length == 0)
        {
            auto none = MenuEntry.item("No sketch in the model", null);
            none.enabled = false;
            list ~= none;
        }
        return presets ~ [MenuEntry.item("New sketch…", () => info(newSketch())),
            MenuEntry.item(planesToggle.getActive() ? "Hide planes" : "Show planes",
                () => setPlanesShown(!planesToggle.getActive()))] ~ MenuEntry.group("Sketches", list);
    }

    /// The sketch state for agents: where the one shown comes from.
    void sketchOriginJson(ref JValue j)
    {
        j["from_cursor"] = sketchFollowing;
        j["pinned"] = sketchPinned;
        j["partial"] = shownPartial() && !shownStale();
        j["stale"] = shownStale();
        if (shownStale() || shownPartial())
            j["error_line"] = sketchErrorLine;
        if (sketchFollowing && followSharing)
            j["shared_with"] = followSharing;
    }
}

/// Runs the entries of `entries` along `path`, one label per level; null,
/// or what went wrong with the labels that were there.
string runMenuPath(MenuEntry[] entries, string[] path)
{
    import std.array : join;
    foreach (k, label; path)
    {
        string[] names;
        MenuEntry* found;
        foreach (ref e; entries)
            if (e.kind == MenuEntry.Kind.item || e.kind == MenuEntry.Kind.group)
            {
                names ~= e.label;
                if (e.label == label)
                    found = &e;
            }
        if (found is null)
            return "no entry '" ~ label ~ "' here; entries: " ~ names.join(", ");
        if (found.kind == MenuEntry.Kind.group)
        {
            entries = found.children;
            continue;
        }
        if (!found.enabled || found.run is null)
            return "'" ~ label ~ "' cannot be chosen now";
        if (k + 1 < path.length)
            return "'" ~ label ~ "' has no entries under it";
        found.run();
        return null;
    }
    return null;
}
