/+ dub.sdl:
    name "tutorial-shots"
    dependency "hackerscad:core" path=".."
+/
// Rebuilds the tutorial's models and pictures: drives the application
// through the steps of each page as a reader would (clicks, right-click
// menus, typed values, pasted code), saves the model at the end of each page
// in docs/tutorial/planter-NN.hcad and the pictures in docs/tutorial/img/.
// Needs a display, bin/hackerscad and ImageMagick (for the numbered marks).
// From the repository root:
//
//     dub run --single tools/tutorial-shots.d
module tutorialshots;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm : canFind, setDifference, sort;
import std.array : array;
import std.conv : to;
import std.file : exists, mkdirRecurse, remove, tempDir, write;
import std.format : format;
import std.json;
import std.path : absolutePath, buildPath;
import std.process : execute, spawnProcess, Pid, kill, wait, thisProcessID;
import std.stdio : writeln;
import std.string : indexOf, lineSplitter;

import hackerscad.tool.guiclient : guiRequest, openWindows;

enum docs = "docs/tutorial", img = "docs/tutorial/img";

string window;    /// the window driven
Pid app;
string work;      /// the model file it edits

/// With page numbers (`… tutorial-shots.d 2 10`) only those pages are
/// redone; the pages from 3 on build on the previous ones, so alone they
/// make sense only from 1, 2 or 10.
void main(string[] args)
{
    mkdirRecurse(img);
    auto dir = buildPath(tempDir, "tutorial");
    mkdirRecurse(dir);
    work = buildPath(dir, "planter.hcad");
    if (exists(work))
        remove(work);

    // a new file starts from the bag clip example
    start(buildPath(dir, "untitled.hcad"));
    scope (exit)
        stop();
    auto pages = [&page1, &page2, &page3, &page4, &page5, &page6, &page7, &page8, &page9, &page10, &page11, &page12];
    if (args.length > 1)
        foreach (n; args[1 .. $])
            pages[n.to!int - 1]();
    else
        foreach (page; pages)
            page();
    writeln("done: ", img);
}

// ---------------------------------------------------------------- the pages

void page1()
{
    view(`{"preset": "iso"}`);
    shot("01-first-start");
}

void page2()
{
    // the parts of the window, numbered
    shot("02-window");
    // in order of use: the view, its bar, parameters and steps, the code, the console
    mark("02-window", [[1040, 520], [1037, 70], [1530, 470], [350, 395], [350, 865]]);
    view(`{"menu": "display"}`);
    shot("02-display-menu");
    view(`{"menu": "none"}`);
    req("set", `{"params": {"teeth": 4}}`);
    shot("02-final");
    req("set", `{"preset": ""}`);   // back to the defaults
}

void page3()
{
    setSource(start3);
    open(work);
    view(`{"preset": "iso"}`);
    shot("03-block");
    // Shift+click on the four vertical edges; the one at the back after turning the view
    // (just inside a visible face: a click lands on the edge within a few pixels)
    click([31, -31, 33], false);
    click([-30.5, -31, 33], true);
    click([31, 30.5, 33], true);
    view(`{"orbit": [180, 0]}`);
    click([-30.5, 31, 33], true);
    view(`{"preset": "iso"}`);
    shot("03-edges");
    menu([31, -31, 33], null);
    shot("03-menu");
    menu([31, -31, 33], ["Fillet 4 edges…"]);
    shot("03-fillet-typed", 0);   // the value to type over is selected
    type("r: 1.mm", "r: 10.mm");
    clearSelection();
    shot("03-final");
    save(3);
}

void page4()
{
    // the four flat sides: two in front, two after turning the view
    click([0, -31, 33], false);
    click([31, 0, 33], true);
    view(`{"orbit": [180, 0]}`);
    click([0, 31, 33], true);
    click([-31, 0, 33], true);
    view(`{"preset": "iso"}`);
    menu([0, -31, 33], ["Draft 4 faces…"]);
    type("angle: 3.deg", "angle: -4.deg");
    clearSelection();
    shot("04-draft");
    // the bottom, seen from below
    view(`{"orbit": [0, -55]}`);
    click([0, 0, 0], false);
    menu([0, 0, 0], ["Fillet face edges…"]);
    type("r: 1.mm", "r: 12.mm");
    view(`{"preset": "iso"}`);
    click([0, 0, 66], false);
    menu([0, 0, 66], ["Shell, opening this face…"]);
    type("thickness: 2.mm", "thickness: 1.6.mm");
    clearSelection();
    shot("04-shell");
    req("section", `{"plane": "xz", "at": 0.5}`);
    shot("04-final");
    req("section", `{"on": false}`);
    save(4);
}

void page5()
{
    paste("import std.shapes;\n", "import std.shapes;\n" ~ params5);
    type("box(62.mm, 62.mm, 66.mm)", "box(size, size, height)");
    shot("05-params");
    req("set", `{"params": {"size": 80, "height": 50}}`);
    shot("05-final");
    req("set", `{"preset": ""}`);   // back to the defaults
    save(5);
}

void page6()
{
    // the pot, pasted: it floats in the tank for now
    paste("\n}\n", "\n}\n" ~ pot6);
    view(`{"preset": "iso"}`);
    shot("06-pot", lineOf("Solid pot()"));
    // the holes in the floor of the pot, seen from above with the tank hidden
    view(`{"hidden": ["tank"], "preset": "top", "projection": "orthographic"}`);
    view(`{"preset": "fit"}`);
    menuOpen([0, 0, 17.6], ["Hole at point", "Clearance"]);
    Thread.sleep(500.msecs);
    shot("06-hole-menu");
    menu([0, 0, 17.6], ["Hole at point", "Clearance", "M8"]);
    menu([-12, -12, 17.6], ["Hole at point", "Clearance", "M3"]);
    clearSelection();
    shot("06-one-hole", lineOf("Solid pot()"));
    replacePart("pot", potLoop6);
    shot("06-holes", lineOf("Solid pot()"));
    view(`{"hidden": [], "preset": "iso", "projection": "perspective"}`);
    req("section", `{"plane": "xz", "at": 0.5}`);
    shot("06-final", lineOf("Solid pot()"));
    req("section", `{"on": false}`);
    save(6);
}

void page7()
{
    view(`{"sidebar": "steps"}`);
    req("rollback", format(`{"line": %d}`, lineOf(".draft(")));
    shot("07-steps", lineOf(".draft("));
    req("rollback", `{}`);
    req("inspect", `{"function": "potShape"}`);
    shot("07-inspect", lineOf("Solid potShape()"));
    req("inspect", `{}`);
    view(`{"sidebar": "params", "preset": "iso"}`);
    click([0, -33.8, 40], false);   // on the front of the tank, which leans out by 4°
    shot("07-final");
    clearSelection();
}

void page8()
{
    // the shelf in the tank, the corner off the pot
    type("    return box(size, size, height)", "    auto t = box(size, size, height)");
    type("thickness: 1.6.mm);\n}", "thickness: 1.6.mm);\n    // the shelf the pot rests on\n    return t + shelf();\n}");
    appendSource(shelf8);
    view(`{"hidden": ["pot"], "preset": "iso"}`);
    req("section", `{"plane": "xz", "at": 0.5}`);
    shot("08-shelf", lineOf("Solid shelf()"));
    req("section", `{"on": false}`);
    // what each line of the shelf makes, as Ctrl+click shows it
    void inspect(string line, string name)
    {
        req("inspect", format(`{"line": %d}`, lineOf(line)));
        shot(name, lineOf("Solid shelf()"));
    }
    view(`{"preset": "iso"}`);
    inspect("auto outline = inside(z);", "08-outlines");
    inspect("curve ~= [outline.offset(", "08-curve");
    inspect("auto full = loft(wall);", "08-full");
    inspect("auto narrowing = loft(curve);", "08-narrowing");
    inspect("return full - narrowing;", "08-difference");
    req("inspect", `{}`);
    // the shelf in section, close
    req("section", `{"plane": "xz", "at": 0.5}`);
    view(`{"preset": "front", "projection": "orthographic", "look_at": [22, 0, 14], "size": 32}`);
    shot("08-shelf-close", lineOf("Solid shelf()"));
    req("section", `{"on": false}`);
    view(`{"hidden": [], "preset": "top"}`);
    view(`{"preset": "fit"}`);
    type("auto p = potShape()", "auto p = (potShape() - corner())");
    shot("08-corner", lineOf("Solid corner()"));
    view(`{"preset": "iso", "projection": "perspective"}`);
    req("section", `{"plane": "xz", "at": 0.5}`);
    shot("08-final", lineOf("Solid pot()"));
    req("section", `{"on": false}`);
    view(`{"preset": "iso", "style": "wireframe"}`);
    shot("08-wireframe", lineOf("Solid shelf()"));
    view(`{"style": "edges"}`);
    save(8);
}

void page9()
{
    paste("@param(\"Size\", min: 50.mm, max: 120.mm)\n",
        "@param(\"Size\", min: 50.mm, max: 120.mm)\n@preset(\"herbs\", 62.mm) @preset(\"basil\", 80.mm) @preset(\"chili\", 96.mm)\n");
    paste("@param(\"Height\", min: 50.mm, max: 120.mm)\n",
        "@param(\"Height\", min: 50.mm, max: 120.mm)\n@preset(\"herbs\", 66.mm) @preset(\"basil\", 90.mm) @preset(\"chili\", 110.mm)\n");
    paste("immutable height = 66.mm;\n", "immutable height = 66.mm;\n" ~ drainage9);
    type(drainLoop, drainIf);
    appendSource(check9);
    shot("09-if", lineOf("if (drainage)"));
    req("set", `{"params": {"size": 50}}`);
    req("test", `{}`);   // F5: the window runs the unittests when asked
    shot("09-check", lineOf("unittest"));
    req("set", `{"preset": ""}`);
    req("set", `{"preset": "basil"}`);
    view(`{"preset": "fit"}`);
    shot("09-final");
    req("set", `{"preset": ""}`);   // back to the defaults
    save(9);
}

void page10()
{
    view(`{"preset": "front", "projection": "orthographic"}`);
    shot("10-final");
    view(`{"preset": "iso", "projection": "perspective"}`);
}

void page11()
{
    // what an agent asked "write BASIL on the front of the tank" does: the
    // window shows its change at once
    type("    // the shelf the pot rests on\n    return t + shelf();", "    // the name, 1 mm deep in the front wall (which leans out by 4°)\n"
        ~ "    t -= text(\"BASIL\", size: 9.mm, font: \"Sans Bold\").centered\n"
        ~ "        .extrude(2.mm, symmetric: true)\n"
        ~ "        .rotate(x: 94)\n"
        ~ "        .move(y: -size / 2 - 32.mm * tan(4.deg), z: 32.mm);\n"
        ~ "    // the shelf the pot rests on\n    return t + shelf();");
    view(`{"preset": "iso"}`);
    shot("11-final", lineOf("Solid tank()"));
    save(11);
}

void page12()
{
    import std.file : copy;
    auto dir = buildPath(tempDir, "tutorial");
    // the language tour, from the Examples menu
    req("new", `{"example": "language", "force": true}`);
    view(`{"preset": "iso"}`);
    shot("12-examples");

    // the hook: made longer with the mouse, then made printable
    auto hook = buildPath(dir, "hook.hcad");
    copy(buildPath(docs, "12-hook-1.hcad"), hook);
    open(hook);
    view(`{"preset": "iso", "style": "edges"}`);
    shot("12-hook");
    menu([0, -22, 33], ["Extrude face…"]);
    type("depth: 5.mm", "depth: 10.mm");
    clearSelection();
    view(`{"preset": "iso"}`);
    shot("12-hook-longer", lineOf(".extrude("));
    // seen from below, with the printability marks
    view(`{"printability": true, "orbit": [0, -50]}`);
    shot("12-hook-print");
    // laid on its back, where it stays
    type("        .extrude(faces.front, depth: 10.mm);", "        .extrude(faces.front, depth: 10.mm)\n        .rotate(x: -90);");
    view(`{"preset": "iso"}`);
    shot("12-hook-back", lineOf(".rotate("));
    // two gussets under the arm
    type("    return (plate + arm)\n", gussets12);
    view(`{"preset": "iso"}`);
    shot("12-hook-final", lineOf("auto gusset"));
    view(`{"printability": false}`);
    write(buildPath(docs, "12-hook.hcad"), source());

    // a label from a drawing, and the models of the other sections
    copy(buildPath(docs, "leaf.svg"), buildPath(dir, "leaf.svg"));
    foreach (name; ["label", "sketch", "jug", "fixings"])
    {
        auto file = buildPath(dir, name ~ ".hcad");
        copy(buildPath(docs, "12-" ~ name ~ ".hcad"), file);
        open(file);
        view(`{"preset": "iso"}`);
        shot("12-" ~ name);
    }
}

// ---------------------------------------------------------------- the code the reader writes

enum gussets12 = "    // a gusset: a triangle 20 mm along the arm and 20 mm down the plate,
    // 3 mm thick, stood up under the arm
    auto gusset = polygon([vec(0, 0), vec(0, -20), vec(20, 0)])
        .extrude(3.mm)
        .rotate(y: 90)
        .move(y: -2.mm, z: 30.mm);
    return (plate + arm + gusset.move(x: -15.mm) + gusset.move(x: 12.mm))
";

enum start3 = "module planter;\n\nimport std.shapes;\n\n@part(\"sienna\")\nSolid tank() => box(62.mm, 62.mm, 66.mm);\n";

enum params5 = "\n@param(\"Size\", min: 50.mm, max: 120.mm)\nimmutable size = 62.mm;\n\n"
    ~ "@param(\"Height\", min: 50.mm, max: 120.mm)\nimmutable height = 66.mm;\n";

enum potLoop6 = "@part
Solid pot()
{
    auto p = potShape()
        .shell(open: faces.top, thickness: 1.6.mm)
        // M8 clearance hole (through: true goes all the way)
        .cut(circle(d: 9.mm), on: faces.normal(Z).largest,
            at: vec(0.mm, 0.mm, 17.6.mm), depth: 5.mm);
    // four drainage holes, one in each quarter of the floor
    foreach (x; [-12.mm, 12.mm])
        foreach (y; [-12.mm, 12.mm])
            p = p.cut(circle(d: 3.4.mm), on: faces.normal(Z).largest,
                at: vec(x, y, 17.6.mm), depth: 5.mm);
    return p;
}
";

enum drainage9 = "
@param(\"Drainage holes\")
immutable drainage = true;
";

enum drainLoop = "    foreach (x; [-12.mm, 12.mm])
        foreach (y; [-12.mm, 12.mm])
            p = p.cut(circle(d: 3.4.mm), on: faces.normal(Z).largest,
                at: vec(x, y, 17.6.mm), depth: 5.mm);";

enum drainIf = "    if (drainage)
        foreach (x; [-12.mm, 12.mm])
            foreach (y; [-12.mm, 12.mm])
                p = p.cut(circle(d: 3.4.mm), on: faces.normal(Z).largest,
                    at: vec(x, y, 17.6.mm), depth: 5.mm);";

enum pot6 = "
@part
Solid pot()
{
    return potShape()
        .shell(open: faces.top, thickness: 1.6.mm);
}

/// The outside of the pot: the shape of the tank, a little smaller and
/// lower, 16 mm up. Below it stays the water.
Solid potShape() => box(size - 2.mm, size - 2.mm, height - 18.mm)
    .fillet(edges.parallel(Z), r: 9.mm)
    .draft(faces.left + faces.front + faces.back + faces.right,
        angle: -4.deg)
    .fillet(edges.of(faces.bottom), r: 1.mm)
    .move(z: 16.mm);
";

enum shelf8 = "
/// The inside of the tank at height z, raised there: the walls open out
/// by 4°.
Profile inside(Length z)
{
    immutable out = z * tan(4.deg), across = size + 2 * out - 3.2.mm;
    return rect(across, across)
        .round(10.mm + out - 1.6.mm)
        .move(z: z);
}

/// A shelf 4 mm wide inside the tank, flat on top at 16 mm, where the pot
/// rests. Underneath it curves down into the wall: it prints without
/// supports.
Solid shelf()
{
    Profile[] wall, curve;
    foreach (i; 0 .. 5)
    {
        // five outlines, from 8 mm up to 16 mm
        immutable s = i / 4.0, z = 8.mm + 8.mm * s;
        auto outline = inside(z);
        wall ~= [outline];
        curve ~= [outline.offset(-4.mm * s * s - 0.01.mm)];
    }
    auto full = loft(wall);
    auto narrowing = loft(curve);
    return full - narrowing;
}

/// What is cut off the back right corner of the pot: the water goes in
/// there, between pot and tank.
Solid corner() => box(40.mm, 40.mm, 3 * height, center: true)
    .rotate(z: 45.deg)
    .move(x: size / 2 + 6.mm, y: size / 2 + 6.mm);
";

enum check9 = "
unittest
{
    // the water under the pot: about the inside of the tank, 13 mm deep
    immutable ml = (size - 3.2.mm) ^^ 2 * 13.mm / 1.cm ^^ 3;
    writeln(\"the tank holds about $(format(\"%.0f\", ml)) ml of water\");
    assert(ml > 40, \"the tank holds too little water: make it larger\");
}
";

// ---------------------------------------------------------------- driving the window

/// Starts the application on `file` and waits for its window. With mutter
/// at hand the window lives on a screen of its own, which nothing covers
/// (a covered window is not drawn, and its pictures would miss all but
/// the 3D view), in a D-Bus session of its own.
void start(string file)
{
    auto before = openWindows();
    immutable gui = format(`bin/hackerscad --size=1680x980 --theme=light "%s"`, file);
    if (execute(["which", "mutter"]).status == 0)
    {
        display = format("hcad-tutorial-%d", thisProcessID);
        // in a process group of its own: stop() ends it whole, the D-Bus
        // daemon and the portals it started included
        app = spawnProcess(["setsid", "dbus-run-session", "sh", "-c", format("mutter --headless --wayland --no-x11 "
            ~ "--virtual-monitor 1920x1080 --wayland-display %s >/dev/null 2>&1 & sleep 2; "
            ~ "WAYLAND_DISPLAY=%s GTK_A11Y=none GDK_DEBUG=no-portals %s", display, display, gui)]);
    }
    else
    {
        writeln("no mutter: keep the window in sight while the pictures are taken");
        app = spawnProcess(["sh", "-c", "exec " ~ gui]);
    }
    foreach (i; 0 .. 100)
    {
        Thread.sleep(200.msecs);
        auto now = openWindows();
        auto added = setDifference(now.sort, before.dup.sort).array;
        if (added.length)
        {
            window = added[0];
            req("state", `{}`);   // waits for the first evaluation
            view(`{"code_width": 700}`);
            return;
        }
    }
    throw new Exception("the window did not open");
}

string display;   /// the headless screen, if any

void stop()
{
    if (app is null)
        return;
    if (display.length)
        execute(["kill", "--", "-" ~ app.processID.to!string]);
    else
        kill(app);
    wait(app);
}

JSONValue req(string method, string params) => guiRequest(window, method, parseJSON(params));

void open(string file) => cast(void) req("open", JSONValue(["path": JSONValue(absolutePath(file)), "force": JSONValue(true)]).toString);

void view(string params)
{
    req("view", params);
    Thread.sleep(300.msecs);   // the view redrawn
}

string source() => req("state", `{"source": true}`)["source"].str;

/// Replaces the whole code, and saves it to the working file.
void setSource(string code)
{
    write(work, code);
}

/// What typing does: `old`, which appears once, becomes `new_`.
void type(string old, string new_)
{
    req("edit", JSONValue(["old": old, "new": new_]).toString);
    req("state", `{}`);
}

/// Pasting code where `before` is: it becomes `after`.
void paste(string before, string after) => type(before, after);

void appendSource(string code)
{
    auto lines = source().lineSplitter.array.length;
    req("edit", JSONValue(["insert": JSONValue(lines + 1), "text": JSONValue(code)]).toString);
    req("state", `{}`);
}

/// A click on a model point; with Shift it adds to the selection.
void click(double[] point, bool shift)
{
    req("pick", JSONValue(["point": JSONValue(point), "shift": JSONValue(shift)]).toString);
}

void clearSelection() => cast(void) req("selection", `{"clear": true}`);

/// A right-click at a model point and the entries chosen in order; no path: the menu stays open.
void menu(double[] point, string[] path)
{
    closeMenus();
    auto p = JSONValue(["point": JSONValue(point)]);
    if (path.length)
        p["path"] = JSONValue(path);
    else
        p["open"] = true;
    req("menu", p.toString);
}

/// The right-click menu with its groups `path` open.
void menuOpen(double[] point, string[] path)
{
    closeMenus();
    req("menu", JSONValue(["point": JSONValue(point), "path": JSONValue(path), "open": JSONValue(true)]).toString);
}

void closeMenus() => view(`{"menu": "none"}`);

/// The 1-based line of the first line of code containing `text`.
int lineOf(string text)
{
    foreach (i, l; source().lineSplitter.array)
        if (l.canFind(text))
            return cast(int) i + 1;
    throw new Exception("not in the code: " ~ text);
}

/// Part `name`, from its @part line to its closing brace, replaced with `code`.
void replacePart(string name, string code)
{
    auto src = source();
    auto at = src.indexOf("Solid " ~ name ~ "()");
    auto start = src[0 .. at].lastIndexOf("@part");
    auto end = src.indexOf("\n}\n", at) + 3;
    type(src[start .. end], code);
}

/// The last step of part `name`'s chain, up to its ';'.
string endOf(string name)
{
    auto src = source();
    auto start = src.indexOf("Solid " ~ name ~ "()");
    auto end = src.indexOf(";\n}", start);
    auto from = src[0 .. end].lastIndexOf("\n");
    return src[from + 1 .. end + 1];
}

/// Saves a picture of the window as img/NAME.png, the code shown from
/// `line` (the cursor there, out of the way); 0 leaves the cursor where it is.
void shot(string name, int line = 1)
{
    if (line > 0)
        view(format(`{"cursor": %d}`, line));
    Thread.sleep(300.msecs);
    auto r = req("screenshot", JSONValue(["path": JSONValue(absolutePath(buildPath(img, name ~ ".png")))]).toString);
    if ("note" in r)
        throw new Exception(name ~ ": " ~ r["note"].str);
    writeln("  ", name);
}

/// Numbered round marks on img/NAME.png, centred on window pixels, 72
/// pixels wide: each drawn four times larger, then made small (smooth
/// edges), with a white border and a soft shadow.
void mark(string name, int[][] at)
{
    auto file = buildPath(img, name ~ ".png");
    foreach (i, p; at)
    {
        auto badge = buildPath(tempDir, format("tutorial-badge-%d.png", i + 1));
        magick(["-size", "288x288", "xc:none", "-fill", "rgba(0,0,0,0.4)", "-draw", "circle 144,154 144,34",
            "-blur", "0x10", "(", "-size", "288x288", "xc:none", "-fill", "white", "-draw", "circle 144,144 144,26",
            "-fill", "#e66100", "-draw", "circle 144,144 144,42", ")", "-composite", "-font", "Adwaita-Sans-Bold",
            "-pointsize", "150", "-fill", "white", "-gravity", "center", "-annotate", "+0+0", (i + 1).to!string,
            "-resize", "72x72", badge]);
        magick([file, badge, "-geometry", format("+%d+%d", p[0] - 36, p[1] - 36), "-composite", file]);
        remove(badge);
    }
}

void magick(string[] args)
{
    auto r = execute(["magick"] ~ args);
    if (r.status != 0)
        throw new Exception("magick: " ~ r.output);
}

/// Saves the code at the end of page `n`.
void save(int n)
{
    write(buildPath(docs, format("planter-%02d.hcad", n)), source());
}

ptrdiff_t lastIndexOf(string s, string what)
{
    import std.string : lastIndexOf;
    return s.lastIndexOf(what);
}
