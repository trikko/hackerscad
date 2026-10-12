# hackerscad tutorial

hackerscad is a parametric CAD where a model is a small program. You write the
model in `.hcad`, a sandboxed subset of D, and the 3D view follows as you type.
You can also work with the mouse: select a face, pick "Fillet" or "Hole at point"
from the menu, and hackerscad writes the code for you. The file stays the only
source of truth, so it diffs, versions and reviews like any other code.

This tutorial goes from the first model to drawings and AI agents. Every
example is a complete model: paste it into a new file and it runs. The full
reference is [LANGUAGE.md](LANGUAGE.md).

1. [Getting started](#1-getting-started)
2. [The window](#2-the-window)
3. [The first model, line by line](#3-the-first-model-line-by-line)
4. [Working with the mouse](#4-working-with-the-mouse)
5. [Parameters and presets](#5-parameters-and-presets)
6. [Solids, booleans and placement](#6-solids-booleans-and-placement)
7. [Selecting faces and edges](#7-selecting-faces-and-edges)
8. [Fillets, chamfers, shells and drafts](#8-fillets-chamfers-shells-and-drafts)
9. [Profiles and sketches](#9-profiles-and-sketches)
10. [Sweeps and lofts](#10-sweeps-and-lofts)
11. [Libraries: screws, threads, gears, enclosures](#11-libraries-screws-threads-gears-enclosures)
12. [Colours, transparency and reference parts](#12-colours-transparency-and-reference-parts)
13. [Design checks](#13-design-checks)
14. [Looking inside: sections and rollback](#14-looking-inside-sections-and-rollback)
15. [Drawings](#15-drawings)
16. [Exporting and the command line](#16-exporting-and-the-command-line)
17. [AI agents](#17-ai-agents)
18. [When something goes wrong](#18-when-something-goes-wrong)

## 1. Getting started

- **Linux:** download `hackerscad-<version>-x86_64.AppImage`, make it
  executable (`chmod +x`) and run it. The same file also contains the command
  line tool: `./hackerscad.AppImage hscad check model.hcad`.
- **Windows:** unzip `hackerscad-<version>-windows-x86_64.zip` anywhere and
  run `hackerscad\bin\hscad-gui.exe` (the command line tool is `hscad.exe`
  next to it). It is not signed: if SmartScreen stops it, choose "More info"
  and then "Run anyway".
- **macOS** (Apple Silicon): unzip `hackerscad-<version>-macos-arm64.zip`,
  move `hackerscad.app` to Applications and clear the attributes macOS puts on
  downloaded files (the quarantine), or it says the app is damaged (it is not signed by an
  Apple developer): `xattr -cr /Applications/hackerscad.app`.
  The command line tool is `hackerscad.app/Contents/Resources/bin/hscad`.
- **From source** (Linux, macOS): install a D compiler (LDC), dub,
  OpenCascade 7.9, GTK 4, libadwaita, GtkSourceView 5, TBB, CMake and Ninja,
  then:

```bash
dub build            # bin/hscad, the command line tool
dub build :gui       # bin/hscad-gui, the desktop application
```

The Windows version is built on Linux and can be tried there with Wine:
`tools/setup-win-cross.sh` downloads the toolchain and the libraries once,
then `packaging/windows/package.sh` builds the zip.

Start the application with a file (`hscad-gui model.hcad`) or without one. A
new file starts from a small example: a clip that keeps bags of biscuits
closed ([examples/bagclip.hcad](../examples/bagclip.hcad)). Try its sliders
first.

## 2. The window

- **Editor** (left): the model. Errors are underlined in red, and a banner over
  the view says what went wrong and where. While you type, a list proposes what
  can follow: the methods after a dot (`s.fi` → `fillet`), the units after a
  number (`30.` → `mm`), the functions of the libraries you import, and inside a
  call the arguments still to give, with the signature above the line and the
  current argument in bold. Up/Down choose, Enter or Tab accept, Escape closes,
  Ctrl+Space opens the list anywhere. Hover a name to read what it does.
- **Cheatsheet** (F1): every object and function in one line, what it takes
  and what it gives, plus "how do I…" recipes. Type in the search field
  ("copy", "hole", "frame"); double-click an entry to insert it at the cursor.
- **View** (centre):
  - right drag rotates, middle drag (or Ctrl + right drag) pans, the wheel
    zooms; left drag rotates or pans, as set by the buttons over the view;
  - Fit (F5), Iso, Top, Front and Right set the camera;
  - the section button opens the section plane (see §14).
- **Parameters** (right): a field for every parameter, the preset menu, and the
  list of parts with their colours, where the eye button hides a part.
- **Features** (right, second tab): the operations of the model, in order.
  Click one to see the model as it was at that step.
- **Console** (bottom, Ctrl+J): what the model prints, failed checks, and dimmed
  timestamped messages from hackerscad itself (evaluated, saved, exported).

Shortcuts: Ctrl+N new, Ctrl+O open, Ctrl+S save, Ctrl+Shift+S save as, Ctrl+E
export, F9 parameters panel, Ctrl+Q quit. hackerscad asks before discarding
unsaved changes, and reloads the file when another program changes it.

## 3. The first model, line by line

A USB stick with its name on the side (a fuller one, with a technical
drawing, is [examples/usbstick.hcad](../examples/usbstick.hcad)):

```d
module usbstick;

import std.shapes;

@param("Length", min: 25.mm, max: 70.mm)
@preset("short", 30.mm) @preset("long", 55.mm)
immutable length = 40.mm;

@param("Width", min: 14.mm, max: 25.mm)
immutable width = 17.mm;

@param("Thickness", min: 6.mm, max: 12.mm)
immutable thickness = 8.mm;

@param("Label")
immutable label = "hackerscad";

@param("Label height", min: 2.mm, max: 5.mm)
immutable labelSize = 3.5.mm;

immutable plugWidth = 12.mm;
immutable plugHeight = 4.5.mm;
immutable plugLength = 12.mm;

@part
Solid body()
{
    return box(length, width, thickness)
        .fillet(edges.parallel(Z), r: 3.mm)
        .fillet(edges.perpendicular(Z), r: 1.5.mm)
        - cylinder(d: 3.5.mm, h: thickness)
            .move(x: -length / 2 + 4.mm);
}

@part("white")
Solid lettering()
{
    return text(label, size: labelSize)
        .centered
        .extrude(0.4.mm)
        .placeOn(body.frame(faces.front));
}

@part("silver")
Solid plug()
{
    immutable sheet = 0.3.mm;
    auto sleeve = box(plugLength, plugWidth, plugHeight)
        - box(plugLength, plugWidth - 2 * sheet, plugHeight - 2 * sheet)
            .move(x: sheet, z: sheet);
    return sleeve.move(x: (length + plugLength) / 2, z: (thickness - plugHeight) / 2);
}

unittest
{
    assert(labelSize < thickness - 2.mm, "the label is taller than the side");
    writeln("total length: $(length + plugLength)");
}
```

What it says:

- `module usbstick;` names the model, and `import std.shapes;` brings in
  boxes, cylinders, profiles and the rest.
- **Units are part of the value.** `40.mm`, `2.5.cm`, `1.inch` and `30.deg` are
  numbers with a dimension. Adding a length to an angle is an error, while a
  length times a length is an area. Bare numbers given to geometry are
  millimetres.
- **`@param`** turns a constant into a parameter: it gets a field in the panel,
  and `min:`/`max:` are checked. **`@preset`** gives it a value in a named set
  (here "short" and "long").
- **`@part`** marks a function returning a `Solid` as a body to show and
  export. Each part is a separate object in 3MF, with its colour. Parts may use
  each other: `lettering` stands on a face of `body`.
- **Primitives stand on the XY plane**, centred in X and Y: `box(40, 17, 8)`
  goes from z = 0 to z = 8.
- **Calls chain.** `box(…).fillet(…)` is `fillet(box(…), …)`, as in D (UFCS).
  Long chains break before each dot.
- **Booleans are operators:** `a + b` union, `a - b` difference, `a & b`
  intersection.
- **`edges.parallel(Z)`** selects edges by what they are, not by number, so the
  selection survives changes upstream (see §7).
- **`unittest`** blocks run after every evaluation: `assert` reports a broken
  design rule, `writeln` prints to the console.

Try it: change `length` with its field, pick the "long" preset, type another
label, or set `r: 3.mm` to `r: 6.mm` in the code.

## 4. Working with the mouse

Click a face or an edge in the view to select it. The selection's details show
at the bottom of the view, and the editor jumps to the line that created it.
Shift+click adds to the selection.

Right-click opens the menu for the selection:

- **Fillet, Chamfer** for the selected edges; **Shell** opens the selected faces
  and hollows the solid; **Draft** tapers faces for moulding.
- **Hole at point**: a clearance, tapping or heat-set insert hole for M2…M8,
  exactly where you clicked. **Pocket** and **Boss** cut into or grow from the face.
- **Measure**: sizes, areas, distances. **Copy as code**: the selector that picks
  the selection, e.g. `faces.top + faces.front`.
- **View**: look at the face, fit, standard views.

Every action writes code into the right part, with a selector rather than a
face number, and puts each call on its own line:

```d
module mouse;

import std.shapes;

@part
Solid block()
{
    return box(40.mm, 30.mm, 20.mm)
        .fillet(edges.of(faces.top), r: 2.mm)
        .shell(open: faces.top, thickness: 1.5.mm);
}
```

Undo (Ctrl+Z) takes the code back as for any edit.

## 5. Parameters and presets

```d
module bracket;

import std.shapes;

@param("Width", min: 10.mm, max: 100.mm)
@preset("small", 20.mm) @preset("large", 60.mm)
immutable width = 40.mm;

@param("Holes", min: 1, max: 6)
@preset("large", 4)
immutable holes = 2;

@param("Material", choices: ["PLA", "PETG"])
immutable material = "PLA";

@param("Countersunk")
immutable countersunk = false;

@part
Solid plate()
{
    auto p = box(width, 15.mm, material == "PETG" ? 4.mm : 3.mm);
    foreach (i; 0 .. holes)
        p -= cylinder(d: countersunk ? 3.4.mm : 3.mm, h: 10.mm)
            .move(x: -width / 2 + (i + 0.5) * width / holes);
    return p;
}
```

- A parameter's type follows its default: lengths and angles get a field with
  their unit, numbers a number field, strings a text field, `choices:` a menu,
  booleans a switch.
- Presets are rows of a table where the parameters are the columns. A
  parameter without a value for a preset keeps its default.
- The panel's values are temporary overrides. The file changes only when you
  edit the default in the code.
- From the command line: `hscad render bracket.hcad -o b.stl -D width=80.mm
  --preset large`.

## 6. Solids, booleans and placement

```d
module placement;

import std.shapes;

@part
Solid base() => box(60.mm, 40.mm, 5.mm);

@part("orange")
Solid post()
{
    // on the top face of the base, 15 mm to the right of its centre
    return cylinder(d: 8.mm, h: 20.mm)
        .placeOn(base.frame(faces.top).at(x: 15.mm));
}

@part("steelblue")
Solid side() => box(10.mm, 40.mm, 10.mm).nextTo(base, X, gap: 5.mm);

@part("gold")
Solid washers()
{
    // six washers around the Z axis, on the base
    return (cylinder(d: 8.mm, h: 2.mm) - cylinder(d: 4.mm, h: 2.mm))
        .move(x: 12.mm)
        .circularPattern(6, axis: Z)
        .move(x: -12.mm, z: 5.mm);
}
```

- `move(x:, y:, z:)`, `rotate(x:, y:, z:)` (degrees), `mirror(X)` and `scale(k)`
  transform a solid.
- `a.nextTo(b, X, gap:)` puts a beside b, and `a.align(b, x: "center", z: "min")`
  aligns their bounding boxes.
- `body.frame(faces.top)` is a coordinate frame on a face: the origin at its
  centre, Z along the outward normal. `placeOn(frame)` moves a solid built on XY
  onto it, and `frame.at(x:, y:)` shifts the origin on the face.
- `linearPattern(n, step: vec(…))` and `circularPattern(n, axis:)` copy a solid.
  Subtract the result to cut all the copies at once.
- `s.bbox`, `s.volume`, `s.area` and `distance(a, b)` measure.

## 7. Selecting faces and edges

Features take selectors, which are resolved on the solid they apply to:

- **By direction:** `faces.top`, `faces.front`, `faces.normal(X)`,
  `edges.parallel(Z)`, `edges.perpendicular(Z)`.
- **By kind or size:** `edges.circles`, `edges.lines`, `faces.largest`.
- **By adjacency:** `edges.of(faces.top)` (the edges around the top face),
  `edges.between(faces.top, faces.front)`.
- **By provenance:** `faces.from(holes)` (the walls cut by a tool),
  `edges.from(holes)`.
- **By predicate:** `edges.filter(e => e.isCircle && e.radius == 3.mm)`,
  `faces.filter(f => f.center.z > 10.mm)`.
- **Combined:** `faces.top + faces.front` (either), `edges.circles - edges.of(faces.bottom)`
  (but not), `a & b` (both).

```d
module selectors;

import std.shapes;

@part
Solid plate()
{
    auto holes = cylinder(d: 6.mm, h: 10.mm)
        .linearPattern(3, step: vec(15.mm, 0.mm, 0.mm))
        .move(x: -15.mm);
    return (box(60.mm, 30.mm, 6.mm) - holes)
        .fillet(edges.parallel(Z) - edges.from(holes), r: 4.mm)
        .chamfer(edges.between(faces.from(holes), faces.top), d: 0.8.mm);
}
```

Since a selector describes what it wants ("the vertical edges that are not hole
walls"), it keeps working when the plate grows or gets more holes. Right-click
→ Copy as code gives the selector for what you selected in the view.

## 8. Fillets, chamfers, shells and drafts

```d
module features;

import std.shapes;

@part
Solid cup()
{
    return box(50.mm, 35.mm, 30.mm)
        .fillet(edges.parallel(Z), r: 8.mm)
        .fillet(edges.of(faces.bottom), r: 3.mm)
        .shell(open: faces.top, thickness: 2.mm);
}

@part("orange")
Solid mould()
{
    return box(30.mm, 30.mm, 20.mm)
        .draft(faces.normal(X) + faces.normal(-X), angle: 3.deg)
        .move(x: 60.mm);
}
```

- `fillet(edges, r:)` and `chamfer(edges, d:)` round or bevel edges.
- `shell(open: faces, thickness:)` hollows a solid, leaving the given faces
  open. Open several faces in **one** shell (`open: faces.top + faces.left`): a
  second shell would offset the first one's walls again and round their inner
  corners.
- A fillet radius must be larger than the shell thickness that follows it,
  otherwise the inner offset of the corner is degenerate.
- `draft(faces, angle:, pull: Z)` tapers faces so a part leaves a mould.
- When a feature fails, the error says which feature and suggests a fix
  (a smaller radius, fewer edges at a time).

## 9. Profiles and sketches

Profiles are 2D shapes on XY: `rect`, `circle`, `polygon`, `slot`,
`regularPolygon`, `text`. They combine with `+ - &`, round their corners with
`.round(r)`, and become solids with `.extrude(h)` or `.revolve(axis:)`.

```d
module profiles;

import std.shapes;

@part
Solid plate() => (rect(60.mm, 40.mm).round(6.mm) - slot(20.mm, 6.mm)).extrude(4.mm);

@part("orange")
Solid knob()
{
    // a half outline in XY, turned around the Y axis
    auto half = polygon([vec(0.mm, 0.mm), vec(12.mm, 0.mm), vec(10.mm, 14.mm), vec(0.mm, 14.mm)]);
    return half
        .revolve(axis: Y)
        .rotate(x: 90.deg)
        .move(x: 50.mm);
}
```

For shapes defined by relations rather than coordinates, use a **constrained
sketch**. Add points, lines, arcs and circles, then the
constraints, and hackerscad's solver finds the positions:

```d
module sketched;

import std.shapes;

@part
Solid bracket()
{
    auto s = sketch();
    auto a = s.point(0, 0, fixed: true);
    auto b = s.point(40, 0);
    auto c = s.point(40, 30);
    auto d = s.point(0, 10);
    auto bottom = s.line(a, b), right = s.line(b, c), top = s.line(c, d), left = s.line(d, a);
    s.horizontal(bottom);
    s.vertical(right);
    s.vertical(left);
    s.length(bottom, 50.mm);
    s.length(right, 30.mm);
    s.length(left, 12.mm);
    s.fillet(c, 4.mm);
    return s.profile.extrude(8.mm);
}
```

`s.dof` says how many degrees of freedom are left. An under-constrained sketch
still works, with a warning naming the lines of the free points, while
conflicting constraints are an error pointing at them. In the view the pencil
button shows the sketch with its dimensions, and clicking a dimension edits it
in the code.

## 10. Sweeps and lofts

```d
module sweeps;

import std.shapes;

// a handle: a profile moved along a smooth curve
@part
Solid handle()
{
    auto p = spline([vec(0.mm, 0.mm, 0.mm), vec(0.mm, 0.mm, 30.mm), vec(30.mm, 0.mm, 45.mm), vec(60.mm, 0.mm, 30.mm), vec(60.mm, 0.mm, 0.mm)]);
    return circle(d: 8.mm).sweep(p);
}

// a vase: a smooth solid through profiles at different heights
@part("orange")
Solid vase()
{
    return loft([
        circle(r: 20.mm),
        regularPolygon(6, r: 24.mm).rotate(z: 30.deg).move(z: 40.mm),
        circle(r: 12.mm).move(z: 80.mm),
    ]).move(x: 100.mm);
}
```

- `path([…])` has straight segments, `spline([…])` passes smoothly through its
  points, `helix(r:, pitch:, height:)` is for springs and threads (sweep with
  `frenet: true`).
- `loft(profiles, ruled: true)` gives flat sides instead of smooth ones.

## 11. Libraries: screws, threads, gears, enclosures

```d
module fixings;

import std.shapes;
import hardware;
import gears : spurGear;

@part
Solid lid()
{
    auto l = box(50.mm, 50.mm, 6.mm);
    // tools to subtract: their top is on z = 0, going down
    l -= hole(M3, 6.mm, "countersink").move(x: -15.mm, z: 6.mm);
    l -= hole(M3, 6.mm, "insert").move(x: 15.mm, z: 6.mm);
    l -= nutTrap(M3, 3.mm).move(y: 15.mm, z: 6.mm);
    return l;
}

@part("silver")
Solid bolt() => screw(M3, 12.mm).move(x: -15.mm, z: 20.mm);

@part("orange")
Solid gear() => spurGear(1.5.mm, 24, 6.mm, bore: 5.mm).move(x: 70.mm);
```

- `hardware`: the sizes `M2`…`M8` (`M3.clearance`, `M3.tap`, `M3.insert`…),
  `screw`, `nut`, `washer`, `hole(size, depth, kind)` with kind `"clearance"`,
  `"tap"`, `"insert"`, `"counterbore"` or `"countersink"`, and `nutTrap`.
- `threads`: `threadedRod(d, pitch, length)` and `tappedHole(d, pitch, depth)` for real
  ISO threads. For an M3 printed in plastic, a `"tap"` hole and a self-tapping
  screw or a heat-set `"insert"` is usually better.
- `gears`: `spurGear`, `rack`, `centerDistance` to place meshing gears.
- `hinges`, `snaps`, `enclosures`: print-in-place hinges, snap-fit hooks, boxes
  with lids. [examples/library.hcad](../examples/library.hcad) shows them all.
- Your own: put functions in `lib/name.hcad` next to the model and
  `import lib.name;`. To use them in every project, put them in the personal
  library folder (`~/.local/share/hackerscad/lib` on Linux,
  `%APPDATA%\hackerscad\lib` on Windows, `~/Library/Application
  Support/hackerscad/lib` on macOS) or in a folder listed in `$HCAD_PATH`.
  A library of several files is a folder with a `package.hcad` that says
  `public import pizza.base, pizza.toppings;`: then `import pizza;` is
  enough.

## 12. Colours, transparency and reference parts

```d
module colours;

import std.shapes;

@part
Solid holder()
{
    return box(30.mm, 30.mm, 20.mm)
        .fillet(edges.parallel(Z), r: 4.mm)
        - cylinder(d: 14.mm, h: 20.mm).move(z: 4.mm);
}

// see-through, and left out of exports: the bottle the holder is for
@part("slategray", alpha: 0.35, export: false)
Solid bottle() => cylinder(d: 13.6.mm, h: 60.mm).move(z: 4.mm);

@part("#F2BE94")
Solid cap() => cylinder(d: 18.mm, h: 6.mm).move(x: 40.mm);
```

- Colours are CSS names, `"#RRGGBB"`, `"#RRGGBBAA"` or `rgb(r, g, b, alpha:)`.
  Without a colour a part is mint.
- `alpha:` below 1 makes a part see-through in the view and in pictures.
- `export: false` makes a reference part. It is drawn so you can check the fit
  (a shaft, a circuit board, the phone a stand holds), but STL, 3MF and STEP
  leave it out.

[examples/knob.hcad](../examples/knob.hcad) puts these together: a fluted knob,
printable without supports, on a see-through potentiometer shaft.

## 13. Design checks

```d
module checks;

import std.shapes;

@param("Wall", min: 0.4.mm, max: 5.mm)
immutable wall = 1.2.mm;

@part
Solid box1() => box(40.mm, 40.mm, 20.mm).shell(open: faces.top, thickness: wall);

unittest
{
    assert(wall >= 0.8.mm, "walls under 0.8 mm do not print well");
    assert(box1.bbox.size.z <= 25.mm, "must fit in the drawer");
    writeln("volume: $(format("%.1f", box1.volume / 1.cm ^^ 3)) cm³");
}
```

`unittest` blocks are the model's requirements, written next to it. A failing
`assert` keeps the geometry but shows the message in the console, in the CLI
output and to agents. An `assert` inside a function stops the evaluation with
its message, which is useful when the parameters make no sense together.

## 14. Looking inside: sections and rollback

- **Section view:** the section button over the view opens a bar with the
  plane (XY, XZ, YZ or the selected face), a slider to move it and a button to
  flip its side. Cut solids show their inside filled and hatched. In face mode,
  clicking another face moves the plane there.
- **Rollback:** in the Features tab, click an operation to see the model as it
  was right after it, with the later material as a ghost. Click it again to
  return to the full model.

## 15. Drawings

A function marked `@drawing` describes a technical sheet:

```d
module sheet;

import std.shapes;

@part
Solid flange()
{
    auto f = cylinder(d: 60.mm, h: 8.mm) + cylinder(d: 30.mm, h: 20.mm);
    f -= cylinder(d: 16.mm, h: 20.mm);
    f -= cylinder(d: 6.mm, h: 8.mm)
        .move(x: 22.mm)
        .circularPattern(4, axis: Z);
    return f;
}

@drawing
Drawing flangeSheet()
{
    auto d = drawing(title: "Flange", material: "PETG");
    d.standardViews(flange);
    d.section(flange, XZ, label: "A");
    return d;
}
```

`standardViews` lays out front, top, side and isometric views, picks a
standard scale, and adds the overall dimensions and the hole callouts
("4× ⌀6"). `section` adds a hatched cut. Export with `hscad render sheet.hcad
-o flange.pdf` (or `.svg`, `.dxf`).

## 16. Exporting and the command line

From the application, Ctrl+E exports 3MF (one object per part, with colours),
STL, STEP or PNG. The command line tool does the same without a window:

```bash
hscad render model.hcad -o model.3mf -o model.step      # several outputs at once
hscad render model.hcad -o shot.png                      # iso picture
hscad render model.hcad -o shot-views.png                # iso, front, top, right
hscad render model.hcad -o model.stl -D width=80.mm --preset large
hscad check model.hcad                                    # parts, sizes, checks
hscad check model.hcad --json                             # the same for scripts
hscad docs                                                # the language reference
```

## 17. AI agents

`hscad mcp` is a Model Context Protocol server: an agent such as Claude Code
can write models, check them, look at pictures of the result and export,
without guessing the language.

```bash
claude mcp add hscad -- hscad mcp
```

Then ask, for example, "a hexagonal pen holder, 10 cm tall, with a rounded
bottom". The agent reads the reference (`hcad_docs`), writes the model, checks
it (`hcad_check`), looks at renders (`hcad_render`) and fixes it.

When the application is open, the `hcad_gui_*` tools drive it: open a file,
set parameters, select faces, run the context menu, move the section plane,
take screenshots. You see the agent work in the window, and the agent sees
what you see.

## 18. When something goes wrong

- **Red underline and a banner over the view:** a syntax or evaluation error.
  The message names the problem and often suggests the fix ("did you mean
  `r`?").
- **Nothing changes in the view:** the last good model stays visible while the
  code has an error. Read the banner.
- **A feature fails:** fillets and shells are the delicate ones. Try a smaller
  radius, fewer edges at a time, or open all the faces in a single shell.
- **Slow models:** threads, text cut into curved faces and fillets on many
  edges take the longest. hackerscad caches every operation, so changing a
  parameter recomputes only what depends on it.
- **"Unknown argument":** the error lists the arguments the function takes.
  `hscad docs fillet` prints the reference of one function.
