# The `.hcad` language

A `.hcad` file is written in an **interpreted, sandboxed scripting language inspired by D**. Anyone who knows D can read it without
surprises. There is no compilation step: the interpreter runs inside hackerscad and re-evaluates a
model in milliseconds.

New to it? The [tour of the language](#a-tour-of-the-language) at the end is one model that uses each
basic construct once, with comments saying what each makes appear; in the application it is under
**Examples › Language tour** (and ☰ › Language Tour).

## What stays the same as D
- **Lexical:** identifiers; numbers (`42`, `1_000`, `2.5`, `0xFF`, `2.5e3`); strings `"…"`, `` `…` ``, `r"…"` (the last two WYSIWYG as in D); comments `//`, `/* */` and nested `/+ +/`.
- **Declarations:** `immutable`, `const`, `auto`, typed variables, `struct` (fields, defaults, methods), functions (with `{ … }` or `=> expr;` bodies), `import`, `unittest`, UDAs.
- **Statements:** `if`/`else`, `foreach` (`foreach (i, x; arr)`, `foreach (i; 0 .. n)`, `foreach_reverse`), `for`, `while`, `break`, `continue`, `return`, `assert`, `switch` (with `case a, b:` and `default:`).
- **Assignments:** `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `~=`, `++`, `--`.
- **Expressions:**
  - D precedence, including `^^`; ternary `?:`.
  - UFCS: `x.f(y)` is `f(x, y)`.
  - Named arguments: `f(x: 1)`.
  - Lambdas: `x => e`, `(a, b) => e`, `(int x) { return x; }`.
  - Functions are ordinary arguments: `xs.map(x => x * 2)`, `xs.map(&twice)`.
  - Array literals `[1, 2]` and associative literals `["a": 1]`.
  - Slices `a[1 .. $]`, concatenation `~`, `in`.
  - Struct literals `Screw("M3", 3.mm)` or `Screw(d: 3.mm)`.
- **Paren-less calls:** a declared function whose parameters all have defaults is called when named without parentheses (`body.bbox`, `nextTo(body, …)`). Use `&f` to pass the function itself.
- **Modules:**
  - `import std.math;`, `import hardware : M3;`, `import hw = hardware;`, `import lib.hinges;`, `import a, b;`.
  - `lib.hinges` resolves to `lib/hinges.hcad`; a folder is a package: `import pizza;` loads `pizza.hcad`, or else `pizza/package.hcad`, whose `public import pizza.base, pizza.toppings;` makes their names visible to whoever imports `pizza` (as in D).
  - Modules are looked for in the directory of the model, then in the folders of `$HCAD_PATH`, then in the personal library folder: `~/.local/share/hackerscad/lib` on Linux (`$XDG_DATA_HOME/hackerscad/lib`), `~/Library/Application Support/hackerscad/lib` on macOS, `%APPDATA%\hackerscad\lib` on Windows. The built-in libraries (`hardware`, `gears`…) come first.
  - `private` symbols are not exported.

## What is different from D
- **Strings interpolate:** `"volume: $(body.volume)"` inserts the value of the expression; `\$` is a literal dollar. Backtick and `r"…"` strings are WYSIWYG and never interpolate.
- **`~` joins anything with a string:** `"side " ~ width` gives `"side 60 mm"` (in D both sides must be strings).
- **Dynamic typing with run-time checks.**
  - `auto` works everywhere.
  - Declared types (`Length h`, `Solid f()`) are checked on calls, returns and assignments, with clear errors.
  - There are no templates: functions are passed as normal arguments (`xs.filter(x => x > 0)`). `!` is only used for type conversions (`to!string`).
- **Value semantics.** Arrays, associative arrays and structs behave as values: `b = a; b[0] = 9;` does not change `a`.
- **Purity.**
  - Locals inside functions are mutable.
  - Module-level declarations (`immutable`, and even `auto`) are read-only and evaluated lazily, in any order. Constants use `immutable`; `enum` is reserved for enumerations.
  - Every function is therefore deterministic, and results can be cached. This is the basis of incremental regeneration.
- **Not available:** classes, pointers, `mixin`, `static if`, user templates, exceptions, `asm`, `alias`, `new`.
- **Sandbox.**
  - `load()` reads mesh, STEP and drawing (SVG, DXF) files inside the project directory only.
  - Library imports are limited to hackerscad's standard modules: `std.shapes`, `std.math`, `std.algorithm`, `std.range`, `std.conv`, `std.format`, `std.stdio`, `std.array`, and the built-in libraries (`hardware`, `threads`, `gears`, `hinges`, `snaps`, `enclosures`, `carlo`).
  - Imports cannot leave the project directory or the library folder they were found in.
  - There is no file, network or process access.
  - Evaluation steps, recursion depth and array sizes are limited.
- **`writeln`** writes to hackerscad's console (and to the JSON output for agents), not to stdout.

## hackerscad additions
- **Units** are UFCS functions: `60.mm`, `2.5.cm`, `1.m`, `1.inch`, `45.deg`, `0.5.rad`.
  - Values carry a dimension (`Length`, `Angle`, `Area`, `Volume`), and arithmetic checks it: `Length * Length` is an `Area`, while `60.mm + 45.deg` is an error.
  - **Bare numbers** passed where a length is expected use the file's default unit: `mm`, or the unit set with `@unit(inch) module name;`. Values keep their unit, so libraries written with different default units combine correctly.
  - Mixing bare and dimensioned numbers in arithmetic (`60.mm + 5`) is an error. Scaling is fine (`2 * 60.mm`).
  - A dimensioned number as a bare one: `d.to!double` is the bare number that means it in this file, a length in the file's unit (millimetres, as `d / 1.mm`, or inches under `@unit(inch)`; squared for an area, cubed for a volume), an angle in degrees (as `a / 1.deg`); `d.to!int` the same when it is whole. To mix it with bare numbers: `c.y + d.to!double / 2`, or give the other side its unit: `vec(6.25.mm, 31.5.mm)`.
  - Bare angles passed to features (`rotate(z: 45)`) are degrees. `sin`/`cos` take radians for bare numbers, as in D.
- **Vectors:** `vec(10.mm, 5.mm)`, `vec(x, y, z)`, with `.x .y .z .xy .length .normalized`, `dot`, `cross`, `distance`. Vectors compare with a small tolerance.
- **Directions:** `X`, `Y`, `Z`, `-X`…
- **`@param("description", min:, max:, step:, choices:)`** above **`immutable name = default;`** declares a parameter. It can be overridden from the GUI, from the CLI (`-D name=80.mm`, or `-D name=80` in the model unit) and by agents, and is checked against its limits.
- **`@preset("name", value)`** on a parameter gives its value in a named preset (`--preset name`, or the preset menu in the GUI). A preset is the set of values declared under its name; parameters without a value for it keep their default.
  - Parameters never change during an evaluation: their value is decided beforehand, from default, then preset, then explicit override.
  - Like a configuration table: every parameter is a column, every preset a row.
- **`@part("colour")`** above **`Solid name() { … }`** declares an exported body: a separate object in 3MF, a separate named body in STEP, its own file in a zip of STLs (`name.stl`; a lone `.stl` takes one part). A part is evaluated once per run even when other parts refer to it. Without a colour a part is Sky Pop (`#0FC3F2`). `@part("slategray", alpha: 0.35)` makes it see-through; `export: false` makes it a reference part (a shaft, a board, the object a holder is for): drawn in the view and in PNGs, left out of STL, 3MF and STEP. `name: "Tank"` is the part's name in exported files (object, body and file names) instead of the function's; two parts cannot share one.
- **`@parts`** above a function makes **a part of each separate body** it returns: of a `Solid` (two halves of a cut, copies that do not touch, the objects of a loaded 3MF) or of each element of a `Solid[]`. The parts are named after the function with a number, `jaws1`, `jaws2`… (just `jaws` when there is one), in the order of `.pieces` (along X, then Y, then Z); how many there are comes from the evaluation, so a parameter can change it. It takes what `@part` takes, plus `varied: true`, which gives the pieces colours that tell apart (the first in the part's colour). A piece coloured on its own (`pieces[1] = pieces[1].color("Blue Pop");`, what the menu's Colour writes on a piece) keeps its colour; the others take the annotation's. A solid in a `Solid[]` made of several bodies stays one part. An empty `Solid[]` makes no part: a part to choose with a parameter, `@parts Solid[] lid() => withLid ? [makeLid()] : [];`. `@part` on a function returning a `Solid[]` is an error that points at `@parts`; on a `Solid` of several bodies it is one part (one object in 3MF).
  ```d
  import carlo;   // Carlo, the mascot clip: an object to try things on

  immutable cutPlane = plane(origin: vec(10, 0, 0), normal: X);

  @parts(varied: true)
  Solid[] pieces() => carlo().split(cutPlane);    // pieces1, pieces2, pieces3: the plane crosses the slot

  @parts("Yellow Pop")
  Solid jaws() => carlo().halves(cutPlane).above; // jaws1, jaws2: the side above is two bodies
  ```
- **Colours** are CSS names (`"steelblue"`), hackerscad's own bright colours, alike in brightness under the view's light and offered by the 3D view's right-click menu (`"Sky Pop"` — the default —, `"Blue Pop"`, `"Cyan Pop"`, `"Violet Pop"`, `"Pink Pop"`, `"Rose Pop"`, `"Red Pop"`, `"Orange Pop"`, `"Yellow Pop"`, `"White Pop"`, `"Gray Pop"`: with the space, `"Pink Pop"` is not the web's `"pink"`), `"#RRGGBB"`, `"#RRGGBBAA"` (the last byte is the opacity) or `rgb(r, g, b)` with 0…255 channels, `rgb(r, g, b, alpha: 0.5)`. `solid.color("orange", alpha: 0.5)` works too.
- **`unittest { assert(…); }`** blocks are design checks. They run after evaluation; a failure does not discard the geometry, but is reported in the GUI, the CLI and to agents. `hcad check`, `hcad render` and the exports run them every time; the window runs them when asked (F5, the bug button over the console, `hcad_gui_test` for agents) and before an export, not at every change.
- **Solids and booleans:**
  - `a + b` union, `a - b` difference, `a & b` intersection; `s += x` inside functions.
  - `hull(a, b, …)` or `hull([a, b, …])`: the smallest convex shape around solids and profiles (two spheres make a capsule, four cylinders a plate with round corners); profiles in one plane give a profile, `hull(circle(r: 4.mm), circle(r: 4.mm).move(x: 20.mm))` a slot. Curved surfaces become flat facets within 0.05 mm.
  - `minkowski(a, b)`: `a` moved by every point of `b`. With a sphere (a circle for profiles) it rounds every edge and corner exactly, like `s.offset(r)`; with another convex shape (a box, a cylinder) it is made of flat facets, and one of the two shapes must be convex.
  - `s.offset(d)` grows a solid by `d` (or shrinks it, `d` negative), round where it turns.
- **Printing:** `teardrop(d: 5.mm)` (in a sketch `s.teardrop(c, d: 5.mm)`) is a round hole with a 45° point towards +Y: cut on a wall (`carlo().cut(teardrop(d: 3.4.mm), on: faces.front, through: true)`) the point is up and the hole prints without supports (`angle:` another point, `flat: true` cuts it at the circle's top). `faces.overhanging()` selects the faces facing down more steeply than 45° from a wall (`faces.overhanging(60.deg)` another angle; faces resting on the bed are not counted), `s.overhangs(45.deg)` is their area and `s.thinWalls(0.8.mm)` the surface over walls thinner than that: `assert(part.thinWalls == 0.mm ^^ 2)` in a unittest keeps a model printable. The Printability check box of the display menu marks both on the model.
- **Profiles from solids:** `s.section(XZ)` (any plane: `s.section(s.plane(faces.top).offset(-2.mm))`) is the cut of the solid by the plane, a profile lying in it; `s.projection` is the solid's shadow seen from above, a profile on XY, and `s.projection(XZ)` its shadow on any plane, cast along the plane's normal (curved surfaces within 0.02 mm). Both can be extruded, offset, combined like any profile.
- **Mass:** `s.centroid` is the centre of mass; `s.mass(density: 1.24)` the mass in grams for a density in g/cm³ (PLA 1.24, PETG 1.27, ABS 1.04, aluminium 2.70, steel 7.85); `s.inertia(density: 1.24)` the principal moments of inertia about the centre of mass, ascending, in g·mm².
  - `Solid.init` and `nothing` are the empty solid. `solids.sum` and `fuse(…)` unite arrays.
- **Math** (with `import std.math`): `sqrt`, `abs`, `floor`, `ceil`, `round`, `sin`, `cos`, `tan` (angles; bare numbers are radians), `asin`, `acos`, `atan`, `atan2(y, x)`, `pow(x, y)` (as `x ^^ y`: a length squared is an area), `exp`, `log(x)` and `log(x, base)`, `log10`, `log2`, `hypot(a, b)`, `sign`, `min`, `max`, `clamp(v, lo, hi)`, `lerp(a, b, t)` (numbers, lengths or vectors), and `PI`, `E`.
- **Primitives** stand on the XY plane, centred in X and Y; `center: true` centres them in Z too. Spheres are centred.
  - `box(x, y, z)`, `cylinder(r | d, h)`, `cone(r1 | d1, r2 | d2, h)`, `sphere(r | d)`, `torus(major, minor)` (round Z, centred on the origin: major to the middle of the tube, minor its radius).
- **Profiles** (2D shapes on the XY plane, type `Profile`):
  - The shapes are those of a sketch (below), with the same names and arguments: a profile's shape is a one-shape sketch with everything given, centred on the origin unless a point is given (a vector, `vec(10, 5)` or `[10, 5]`). `rect(w, h)` (`rect(20.mm)`, a square), `rect(p, q)` (two opposite corners), `rect(p, w:, h:)` (from its lower left corner) or `rect(center: c, w:, h:)`, with `angle: 30.deg` (rotated about its centre, its first side that far from X: a slanted rectangle anywhere is `rect(center: vec(15.4, 3.3), w: 5.6.mm, h: 14.mm, angle: 45.deg)`) and `corner: 3.mm` (the four corners rounded); `circle(r | d)` or `circle(c, r | d)`; `ellipse(rx, ry)` or `ellipse(c, rx:, ry:)`, with `angle:`; `polygon(6, d: 10.mm)` or `polygon(c, 6, d: 10.mm)`, regular (d/r through the corners; `fit: "sides"`: the circle the sides touch, `d` across the flats; `angle:` the direction of its first corner, else its first side lies at the bottom, horizontal); `slot(length, w)` (a stadium, length end to end along X; `angle:` turned, `center:` elsewhere) or `slot(p, q, w:)` (round two centres); `teardrop(r | d, angle:, flat:)` or `teardrop(c, r | d, …)` (see Printing).
  - Not sketch shapes: `polygon([vec(0, 0), vec(30, 0), vec(0, 20)])` (through the points; `smooth: true`, a smooth closed curve through them), `text("text", size: 10.mm, font: "Sans")` (starting at the origin on the baseline) and `load("outline.svg")` (see Importing parts).
  - Combine with `+ - &`: profiles overlap, add up and cut each other, where a sketch draws one outline; a sketch's `s.profile` is a Profile too, so the two mix (`s.profile - circle(d: 5.mm)`). Profiles move, turn, scale and mirror like solids: `p.move(x: 10.mm, y: 5.mm)`, `p.rotate(30.deg)` or `p.rotate(z: 30)` (in its plane, about the origin; `around: q` about a point), `p.scale(2)` or `p.scale(x: 2, y: 3)`, `p.mirror(X)` (across the line through the origin with that normal). `.round(r)` rounds the corners; `.offset(d)` grows (d > 0) or shrinks it; `.area`. `p.across(X)` stands it up across X as `extrude(along: X)` does (its x along Y, its y up Z; `across(Y)`: its x along X): `loft([a.across(X), b.across(X).move(x: 20.mm)])` lofts along X.
  - `.extrude(h)` makes a solid along +Z (negative h goes down); options `taper: 3.deg` (the sides lean in going away from the profile, whichever way the solid goes: up, down with a negative height, along X or Y; staying flat and meeting at sharp edges: the outline narrows and the holes widen; a negative taper the other way; `h` is still the height along the axis, and an edge or hole of the profile that would close up before the top is an error), `symmetric: true`, `twist: 90.deg` (the profile turns around Z as it rises, evenly: twisted vases, spiral columns; `twist: 2 * 360.deg` two turns; not with `taper`). `along: Y` stands the profile up across Y (its x along X, its y up Z) and pushes it towards +Y, `along: X` across X (its x along Y, its y up Z) towards +X; a negative height goes the other way: a prism along X or Y without turning anything. A profile lying in another plane, a section (`body.section(XZ.offset(10.mm)).extrude(2.mm)`), one turned or moved whole, or one drawn on a face, is extruded across its own plane, along its normal, from where it lies.
  - `.revolve()`: turned around the axis, standing up: the profile's x is the radius and its y the height along Z (pots, bottles, knobs). `.revolve(axis: X, angle: 180.deg)`: around an axis in the profile's plane (a direction through the origin or an `Axis`), without standing up; `angle:` turns less than all the way.
  - On a face or plane, add or remove material in one step: `carlo().extrude(circle(d: 6.mm), on: frame, depth: 5.mm)` grows outwards along the frame's Z; `carlo().cut(circle(d: 6.mm), on: frame, depth: 2.mm)` digs in, `through: true` cuts all the way. Both accept `taper:`.
  - Threads: `body.thread(face, "M8")` cuts a thread on a cylindrical face: on the outside of a shaft (made at the thread's nominal diameter, ⌀8) the grooves, on the wall of a hole (made at the tap drill, about ⌀6.8 for M8) the thread a screw fits. The size names the standard: ISO metric `"M8"` (coarse) or `"M8x1"` (fine), unified inch `"1/4-20 UNC"`, `"1/4 UNF"`, `"#10-32"`, trapezoidal for lead screws `"Tr12x3"`, BSP pipe threads `"G1/2"` (parallel) and `"R1/2"` (tapered), and `"1/2 NPT"` (tapered; the shaft is the pipe's outside diameter). Tapered threads have their nominal size at the fixed end and narrow by 1 in 16 on the diameter towards the tip of a shaft, or into a hole. `pitch: 1.mm` alone puts a 60° thread of that pitch on the cylinder's own diameter. The thread covers the whole face, or `length: 10.mm` or `turns: 8` from the free end (the tip of a shaft, the opening of a hole; `flip: true` the other end). `starts: 2` for multi-start threads, `left: true` left-handed, `clearance: 0.2.mm` the play for printed parts (0.15 mm by default in holes, none on shafts), `chamfer: false` without the 45° bevel at the free end. In the 3D view, right-click a cylinder: **Thread** lists the sizes that fit it. The `threads` library (`threadedRod`, `tappedHole`) makes loose rods and tools to cut.
- Extrude and cut faces: `carlo().extrude(faces.top, depth: 5.mm)` sweeps flat faces of the body outwards along their normals and adds the material, `carlo().cut(faces.top, depth: 2.mm)` sinks them (a negative depth to extrude does the same). `along: vec(1, 0, 1)` sweeps them in another direction, slanted sides: material is added when the direction leaves the face, removed when it enters. In the 3D view: right-click a face, Extrude face… or Cut face….
- **Paths, sweeps and lofts:**
  - Paths (type `Path`): `path([vec(0, 0, 0), vec(0, 0, 20), vec(30, 0, 20)])` (straight segments, mitred corners; `closed: true`), `spline([…])` (a smooth curve through the points), `helix(r | d, pitch:, height:, left: false)` (around +Z, starting at (r, 0, 0)). Paths move, rotate and mirror like solids.
  - `profile.sweep(path)`: the profile, drawn on XY around the origin, starts at the beginning of the path, normal to it, with its +Y kept towards world +Z (towards +Y when the path starts vertically). `frenet: true` follows the curvature (use it for helices: springs, threads). `twist: 360.deg` turns the profile once around the path on the way, evenly along it (twisted ribbons, ropes; not with `frenet`). Holes in the profile give tubes.
  - `loft([circle(r: 20), rect(30).move(z: 40), circle(r: 10).move(z: 80)])`: a smooth solid through profiles placed in space; `ruled: true` gives flat sides. Profiles with holes are lofted as tubes when every profile has the same number of holes.
- **Constrained sketches** (2D, on XY or on a face): `auto s = sketch();` then add geometry and constraints and take `s.profile`.
  - Areas: the profile fills what lies inside an odd number of loops: a loop inside another is a hole, and where two loops overlap (two circles crossing) the overlap is a hole too. `s.fill(at)` makes the area holding `at` full whatever the loops say, `s.fill(at, full: false)` empty (`at` a vector, or a point of the sketch, which keeps it in its area as the constraints move it; the last fill in an area counts). In the window the full areas are tinted, and the sketch bar's ◩ turns an area full or empty with a click inside it.
  - Construction geometry: `construction: true` on any geometry call or shape (`s.line(p, q, construction: true)`, `s.rect(…, construction: true)`) makes guides to constrain to, drawn dashed in the window, never part of the profile.
  - Geometry: `s.point(x, y)` (where it starts: constraints move it; `fixed: true` pins it there), `s.line(p, q)`, `s.arc(center, start, end)` (counter-clockwise), `s.circle(center, r: | d:)` (without r/d the radius is left to the constraints), `s.polyline([p1, p2, vec(…)], closed: true)` (returns the lines; vectors become new points), `s.ellipse(center, rx:, ry:, angle:)` (rx along its own x axis, `angle` from X, ry across; what is not given is left to the constraints, the turn too: `s.ellipse(c, rx: 20.mm, ry: 12.mm)` with c fixed leaves 1 degree of freedom), `s.spline([p1, p2, vec(…)], closed: false)` (a smooth curve through the points, in order, vectors becoming new points: open, its two ends join lines and arcs as theirs do; `closed: true` goes round back to the first point, a loop of its own; it bends evenly, as a thin strip bent through the points would, and its points move it: constrain them; `.points`, `.start`, `.end`, `.closed`, `.length` along the curve). `construction: true` geometry helps constraining but is not part of the outline.
  - Shapes, made of the geometry above with their constraints, the same shapes and arguments as the profiles above (the points they need are new; a vector where a point goes, here and in `s.circle` and `s.ellipse`, becomes a new point starting there; without the centre, `s.circle(d: 10.mm)`, `s.rect(40.mm, 20.mm)`, `s.polygon(6, d: 10.mm)`, `s.slot(30.mm, 6.mm)`, `s.teardrop(d: 5.mm)`, it is a new point at the origin, free to move): `s.rect(p, q)` (opposite corners), `s.rect(p, w:, h:)` (one corner, p the lower left) or `s.rect(center: c, w:, h:)` returns its 4 lines p → (q.x, p.y) → q → (p.x, q.y), that is bottom, right, top, left when p is the lower left corner; they are horizontal and vertical, so a rectangle of new corners has 4 degrees of freedom, 0 with w, h and a fixed centre (a construction diagonal holds the centre in its middle); `angle: 30.deg` turns it (its first side that far from X: the sides are then square to each other and parallel in pairs instead of horizontal and vertical), `angle: "free"` leaves the turn to the constraints (`s.parallel(r[0], line)` lays it along a slanted line); `corner: r` rounds the four corners. `s.polygon(center, n, r: | d:, fit:, angle:)` returns the n lines of a regular polygon, its corners on a construction circle of that radius (`fit: "corners"`, the default), or its sides touching it with `fit: "sides"` (`d` across the flats: a nut's spanner size); `angle` is the direction of the first corner from the centre, else the turn is left free (1 degree of freedom: `s.horizontal(lines[0])` takes it; it starts with the first side at the bottom, horizontal, where the profile has it); `s.polygon([p, q, vec(0, 20)])` is the closed polyline through the points. `s.slot(p, q, w:)` returns `[line, arc round q, line, arc round p]`: two half circles joined by lines tangent to them, 0 degrees of freedom with p, q fixed and w given; `s.slot(length, w, center: c, angle:)` the same by its length end to end, along X unless turned (a construction line joins the two centres, c in its middle). `s.teardrop(c, r: | d:, angle:, flat:)` returns `[arc, line, line]`: an arc round c and two lines tangent to it meeting above it, `angle` (45° unless given) from the vertical; `flat: true` cuts the point with a line touching the circle's top (`[arc, line, flat, line]`); 0 degrees of freedom with c fixed and r given. Sizes given (w, h, r, d, rx, ry, angle, corner: one dimension for the four corners) are dimensions, shown and editable in the sketch view (a slot's length is not: the dimension would be between its centres).
  - Constraints: `coincident(p, q)`, `fix(p)`, `horizontal(line | p, q)`, `vertical(…)`, `length(line, v)`, `distance(p, q, v)`, `distance(p, q, v, along: X | Y)`, `distance(p, line, v)`, `on(p, line | circle | arc)` (a shape's lines instead of p: every corner on the circle, the shape inscribed: `s.on(s.polygon(c, 6), circ)`), `parallel(a, b)`, `perpendicular(a, b)`, `angle(a, b, v)` (between the line directions, start → end), `equal(a, b)` (lengths or radii), `radius(c, v)`, `diameter(c, v)`, `tangent(line | circle, circle | line)` (a shape's lines and a circle: every side touching it, the shape round it: `s.tangent(s.rect(center: c), circ)`), `midpoint(p, line)`, `symmetric(p, q, line)`, `concentric(a, b)` (circles, arcs, ellipses or a point round the same centre), `angle(line, v)` (of one line from X).
  - On ellipses: `on(p, e)`, `tangent(line, e)`, `concentric(e, …)`, `radius(e, rx: v, ry: v)` (either or both), `horizontal(e)` / `vertical(e)` (its x axis along X or Y), `angle(e, v)`, and `equal(e)`: as wide as tall, a circle. A round ellipse looks the same however it is turned: its turn then stays where it is, unless an angle sets it, and is not a degree of freedom.
  - `s.fillet(p, r)` rounds the corner where two lines meet at p (r is shown as a dimension on its arc).
  - Reading back: `p.x`, `p.y`, `p.pos`, `line.start`, `line.end`, `line.length`, `line.mid`, `c.center`, `c.radius`, `e.center`, `e.rx`, `e.ry`, `e.angle`, `s.dof` (degrees of freedom left), `s.solved`.
  - `s.profile` solves and returns the closed loops of non-construction lines, arcs, circles and ellipses as a `Profile` (inner loops are holes). Lines, arcs and curves with a free end (open) stay in the sketch, drawn, but out of the profile, with a warning naming them. Under-constrained sketches still work, with a warning listing the lines of the free points; conflicting constraints are an error pointing at them.
  - **On a face:** `auto s = carlo().sketch(faces.top);` draws on that flat face, with the axes of `carlo().frame(faces.top)` (origin at the face's centre; on a wall x to the right and y up seen from outside; `origin:` and `x:` as frame takes them). The face's edges are in the sketch from the start, as references: fixed construction geometry, no degree of freedom, shown in the sketch view. `s.edges` lists them, each loop from its lowest edge counter-clockwise like a rect's sides (bottom, right, top, left), the outside first; `s.origin` is the origin as a fixed point; `s.project(edges.…)` flattens other edges of the solid onto the plane as references (a hole's rim under the face; a circle seen aslant becomes an ellipse). Constrain to them as to any geometry: `s.distance(c.center, s.edges[0], 5.mm)`, `s.concentric(c, s.project(edges.filter(…))[0])`. `sketch(frame)` and `sketch(plane)` draw on a frame or plane, with `s.origin` and no edges.
  - The profile of such a sketch lies where it was drawn: `carlo().cut(s.profile, depth: 2.mm)` and `carlo().extrude(s.profile, depth: 1.mm)` need no `on:`, `s.profile.extrude(3.mm)` stands on the face, `revolve` turns it there and `loft` goes through profiles drawn on different planes. Moved, offset or combined with a profile of no place it stays in its plane (in the sketch's coordinates); two profiles drawn on different faces do not combine.
- **Transforms:** `move(v | x:, y:, z:)`, `rotate(x:, y:, z:)` or `rotate(angle, axis:)` (a direction through the origin, or an `Axis` anywhere), `scale(k)` or `scale(x: 2, y: 0.5, z: 1)` (a factor each: an ellipsoid from a sphere; the faces become freeform; `around: p` keeps point p where it is instead of the origin), `mirror(X)` (plane through the origin with that normal) or `mirror(plane)` (any plane), `color(c)`.
- **Placement:** `a.nextTo(b, X, gap: 10.mm)`, `a.on(b)`, `a.align(b, x: "center", z: "min")` (each axis `"min"`, `"center"` or `"max"` of the bounding boxes).
- **Patterns:** `hole.linearPattern(4, step: vec(10, 0, 0))`, `peg.circularPattern(6, axis: Z, angle: 360.deg)` give one solid with all the copies (subtract it to cut them all).
- **Axes:** `axis(origin: vec(10, 0, 0), direction: Z)`, `axis(p1, p2)` (through two points), `carlo().axis(edges.filter(…))` (the line of a straight edge, or the centre and normal of a circular one such as a hole rim), `frame.axis(X)` (an axis of a frame). Fields: `origin`, `direction`. Use them with `rotate(angle, axis: a)` and `circularPattern(n, axis: a)`.
- **Planes:** `XY`, `XZ`, `YZ`, `plane(origin: vec(0, 0, 10), normal: Z)`, `plane(p1, p2, p3)` (three points; the normal follows p1 → p2 → p3 by the right-hand rule), `plane(axis, point)` (containing a line and a point), or the plane of a face: `carlo().plane(faces.top)`. Planes also mirror: `s.mirror(plane)`.
  - `p.offset(5.mm)` is the parallel plane moved along the normal (negative goes the other way); `p.flip` reverses the normal.
  - Fields: `origin`, `normal`.
- **Frames** (an origin and X, Y, Z axes) to build on faces and planes:
  - `carlo().frame(faces.top)`: origin at the face centre, Z along the outward normal. On a wall (any face that is not flat) X is horizontal and to the right seen from outside and Y goes up, on every side: a text reads and a teardrop points up whichever wall it is on; on a flat face X is the global X. The same axes place profiles with `on:`. Options: `origin: vec(…)` (projected on the face), `x: Y`.
  - `plane.frame(origin: vec(…), x: …)`: on a plane the origin defaults to the plane's origin; give a point to choose another one.
  - `World` is the global frame; `f.at(x: 10, y: -5)` moves the origin in local coordinates; `f.turn(30.deg)` rotates X and Y around Z. Fields: `origin`, `x`, `y`, `z`.
  - `solid.placeOn(f)`: a solid built on XY with Z up is moved onto the frame. A plane works too (`placeOn(plane)`): its origin is the zero, with the axes of a frame on a face. A boss: `cylinder(d: 8, h: 5).placeOn(f)`; a pocket: `carlo() - box(10, 10, 3).move(z: -3).placeOn(f)`.
  - `solid.placeOn(f, from: faces.bottom)` lays a face of the solid against the frame instead (the face's middle on its origin, the two facing each other, X on X); `at: vec(…)` carries that point of the face instead of its middle. A lid on a vase's mouth, wherever the vase leans: `lid.placeOn(vase().frame(faces.farthest(Z)), from: faces.bottom)`; turn it with `frame.turn(30.deg)`. Place on… in the window writes these.
- **Cutting:** `s.halves(plane)` returns the two sides of the cut, each one solid: `.above` (where the normal points) and `.below`. `s.split(plane)` returns the pieces the cut leaves, both sides, as a `Solid[]` ordered along X, then Y, then Z: more than two when the plane crosses a slot; choose among them with `.above(plane)`, `.below(plane)`, `.largest`… or make a part of each with `@parts`.
- **Textures and noise:** `noise(x, y, z, seed: 3)` is smooth noise, about -1…1 with features about one unit across (lengths count in mm); `loopNoise(around, along, bumps: 6)` is noise round a loop, `around` 0…1 once round, with no seam where it closes. `profile.outline(n, round: 2.mm)` gives n points evenly round a profile's outline, each with `.at`, its outward `.normal` (turning round a corner as on a fillet `round` big, so that a push inwards smaller than that does not cross itself) and `.around` (0…1). `polygon(points, smooth: true)` is a smooth closed curve through the points, filled. `loft` also takes rings of points (`Vec3[][]`, the same count in each): one smooth surface through every point, closed round each ring, the end rings filled flat, in milliseconds where a loft through as many smooth profiles takes seconds; `loft(rings, inside: innerRings)` makes it hollow, the inner wall through the inner rings, a floor at the inner first ring and a flat rim between the last rings, which lie in one plane. Together they make textured solids: a ring per height, every outline point pushed along its normal by a function of where it is, lofted; along a curve, `path.frames(n)` gives n frames evenly along it, Z along the path and turning as little as they can, to place the rings on with `placeOn` (see `examples/03_randomvase.hcad`, a vase along a curve with its lid):
  ```d
  Vec3[] ring(double up)
  {
      Vec3[] pts;
      foreach (q; circle(r: 30.mm).outline(140, round: 2.mm))
      {
          auto p = q.at + q.normal * (2.mm * loopNoise(q.around, up * 8, bumps: 9));
          pts ~= vec(p.x, p.y, 100.mm * up);
      }
      return pts;
  }
  // then: Vec3[][] rings; foreach (k; 0 .. 41) rings ~= [ring(k / 40.0)]; return loft(rings);
  ```
- **Separate bodies:** `s.pieces` lists the disconnected bodies of a solid (e.g. after a cut through it), ordered by position along X, then Y, then Z; pick one with `[i]` or sort them (`s.pieces.sort((a, b) => a.volume > b.volume)`). A list of solids also says which are where: `.above(plane)` and `.below(plane)` (by centre of mass, so the pieces of a split, which touch the plane, count), `.crossing(plane)` (those it cuts through), `.nearest(point)`, `.largest`, `.smallest`, and `.top`, `.bottom`, `.left`, `.right`, `.front`, `.back` (the highest, lowest…): `carlo().split(cutPlane).below(cutPlane).largest`. To make parts of them, see `@parts`.
- **Push and pull:** `s.push(from: ref, by: 5.mm)` moves a solid away from a point, a Plane or an Axis, `s.pull(to: ref, by: 5.mm)` towards it, along the line from the reference to the solid's centre of mass (from a plane along its normal, from an axis square to it). On a list each solid goes its own way, so the pieces of a cut spread apart, an exploded view: `carlo().split(cutPlane).push(from: cutPlane, by: 4.mm)`. A solid whose centre is on the reference stays, with a warning.
- **Importing parts:** `load("part.stl")`, `load("part.obj")`, `load("part.3mf")`, `load("part.step")`, with `scale:` (STL and OBJ are read in mm; 3MF uses its own unit and build transforms). Meshes become solids (coplanar triangles merged into faces, closed meshes only), STEP files keep their exact geometry; both can be cut, filleted, measured and selected like any other solid. Paths are relative to the model file and must stay inside the project directory. To remodel a mesh exactly, set it straight first if it came tilted (`load("part.stl").aligned` lies on its largest flat face, longest along X, centred on z = 0); `writeln(load("part.stl").features)` lists what it is made of (flat faces, holes and shafts with the ISO size they match, cones, spheres, roundings, chamfers with their size, surfaces turned round an axis, patterns of holes, with plausible sizes; `hcad features part.stl` on the command line, `hcad_features` for agents); load it as a see-through reference part to compare. `hcad section part.stl --plane xy --at 3` (`hcad_section` for agents) gives a cut across it as lines, arcs and circles with their sizes, and as a sketch ready to paste and extrude. `clone.deviation(original)` is how far apart the two surfaces are at most (`assert(clone.deviation(original) < 0.2.mm)` in a unittest); `hcad compare model.hcad --a clone --b original -o map.png` (`hcad_compare`) also gives the mean, the share within a tolerance, a picture of the clone coloured green where it matches, yellow at the tolerance, red beyond, and the patches of each surface the other does not follow (area, offset, facing: a missing chamfer or countersink shows there). `hcad diff` lists the pieces of material to add or cut, the thin differences apart, and the section that shows each piece; `hcad scan file.stl --axis z` the holes and pockets met along an axis with their shapes and depths; `hcad section … --compare` draws two sections on each other and `--projection` reads a shadow's outline; `hcad fit model.hcad --a clone --b original --param width` tunes @param lengths until the two match (and says when the shape, not the sizes, differs); `hcad match` matches the operations of the two one by one (a nut trap cut in steps is one hole); `hcad section … --region u0,v0,u1,v1` keeps the outlines inside a rectangle of the plane (a lettering); `hcad literals model.hcad --original original` lists the numbers the model repeats and which sizes of the original they are, to name them as @params once the copy matches. `hcad review model.hcad --a clone --b original -o review.png` (`hcad_review`) runs the whole comparison round in one: distances both ways, material, drawings outside and of the voids, and close-ups of the first entries of each, framed where they are in sight; `--look x,y,z` adds a close-up of what is at that point. The reports of compare, diff, lines and match are numbered: `--focus 2 -o close.png` (`focus: 2`) draws a close-up of entry 2, from where it is in sight (what lies in front cut away when nothing is); `hcad render … --from right --look-at 1,2,13 --size 14 --opaque -o detail.png` (`view`, `opaque` for agents) takes a picture from anywhere, close on a detail, and compare and lines take the same `--from`, `--look-at`, `--size`, `--cut`. Drawings become profiles on XY: `load("logo.svg")` and `load("plate.dxf")` give their closed outlines (an outline inside another is a hole, inside a hole an island), ready to extrude; SVG sizes come from the drawing's width and height in mm, cm, in or pt (plain numbers are mm), DXF from its $INSUNITS (mm when unset); curves within 0.05 mm. Open lines, text and images are left out.
- **Centring:** `shape.centered` moves a profile (in X and Y) or a solid (in X, Y and Z) so its bounding box is centred on the origin, e.g. `text("LABEL", size: 4.mm).centered`.
- **Measuring:** `distance(a, b)` between two solids (0 when they touch), `s.bbox`, `s.volume`, `s.area`.
- **Introspection:** `s.bbox` (`min`, `max`, `size`, `center`), `s.volume`, `s.area`, `s.isValid`.
- **Features:** `fillet(edges, r:)`, `chamfer(edges, d:)`, `shell(open: faces, thickness:)`, `draft(faces, angle:, pull: Z, neutral: 0.mm)` (mould taper around the neutral plane).
- **Face provenance:** every face remembers the feature that created it (primitive, fillet, shell, split…). Clicking a face in the GUI highlights it and jumps to that line.
- **Topological selectors** are resolved against the solid the feature is applied to:
  - predicates: `edges.filter(e => e.isParallel(Z))`, `faces.filter(f => f.normal == Z)`;
  - shortcuts: `edges.parallel(Z)`, `edges.perpendicular(Z)`, `edges.lines`, `edges.circles`, `faces.top/bottom/left/right/front/back`, `faces.normal(X)`, `faces.largest`, `faces.farthest(Z)` (the face whose centre lies farthest that way, whichever way it faces: a tilted top);
  - by provenance: `faces.from(tool)` (faces created by a tool or feature, e.g. the walls of the holes cut with it), `edges.from(tool)` (edges between two such faces);
  - by adjacency: `edges.of(faces.top)` (edges touching those faces), `edges.between(faces.from(holes), faces.top)` (the rim of the holes on the top face);
  - edge properties: `start`, `end`, `mid`, `direction`, `length`, `isLine`, `isCircle`, `isParallel(axis)`, `isPerpendicular(axis)`, and for circles `center`, `axis`, `radius` (e.g. `edges.filter(e => e.isCircle && e.radius == 3.mm)`);
  - face properties: `center`, `normal`, `area`.
- **Built-in libraries** (`import gears;` or `import std.gears;`, selective imports work too):
  - `hardware`: `Screw` sizes `M2`, `M2_5`, `M3`, `M4`, `M5`, `M6`, `M8` with `d`, `pitch`, `tap`, `clearance`, `head`, `headHeight`, `key`, `nut`, `nutHeight`, `washer`, `insert`, `insertDepth`; `screw(M3, 20.mm, threaded: false)` (socket head cap screw, underside of the head on z = 0), `nut(M3, threaded: false)`, `washer(M3)`, `hexPrism(acrossFlats, h)`; tools to subtract, top on z = 0 going down: `hole(M3, depth, "clearance" | "tap" | "insert" | "counterbore" | "countersink")`, `nutTrap(M3, depth)`.
  - `threads`: `threadedRod(d, pitch, length, chamfer: true, left: false)` (ISO metric profile, real geometry), `tappedHole(d, pitch, depth, clearance: 0.15.mm)` (a tool to subtract for an internal thread), `toothHeight(pitch)`. Threads take a second or two to compute.
  - `gears`: `spurGear(m, teeth, thickness, bore: 0.mm, pressure: 20.deg, backlash: 0.1.mm)` (involute, centred, a tooth on +X), `gearProfile(m, teeth, …)`, `rack(m, teeth, thickness)`, `pitchDiameter`, `outsideDiameter`, `rootDiameter`, `centerDistance(m, z1, z2)` (where to put two meshing gears; turn the second by half a tooth: `rotate(z: 180.deg / z2)`).
  - `hinges`: `hinge(length:, width:, thickness:, knuckles: 5, clearance: 0.4.mm)` returns `.fixed` and `.moving`, two leaves printed in place around an axis along X at z = thickness.
  - `snaps`: `snapHook(length:, thickness:, width:, overhang:, lead: 30.deg)` (a cantilever hook standing on z = 0, barb towards +X) and `snapSlot(…)` (the window to subtract from the mating wall).
  - `enclosures`: `roundedBox(x, y, z, r)`, `tray(x, y, z, wall:, r:)` (open on top), `enclosure(vec(x, y, z), wall:, r:, lidHeight:, screw: M3)` returns `.base` and `.lid` (lid with a lip that fits inside, screw posts in the corners).
  - `carlo`: `carlo(teeth: 3, height: 15.mm, toothR:, gap:, jaw:, back:, lean: 17.deg, mouth: 1.5.deg, eye: true)`, Carlo the mascot, a bag clip lying on z = 0 (the constrained sketch of the tutorial's chapter 13, extruded; `lean` tilts the back and the tips, a positive `mouth` opens the slot towards the tips, a negative one closes it).
- **Drawings** (technical sheets, exported as SVG, PDF or DXF): a function marked `@drawing` returns `drawing(size: "A4", title:, author:, material:, projection: "first" | "third", scale: 0 (fit), landscape: true)` after adding to it:
  - `d.standardViews(solid, iso: true, dimensions: true)`: front, top, side and an isometric view, laid out and scaled to fit, with overall dimensions and hole callouts;
  - `d.view(solid, "front" | "back" | "top" | "bottom" | "right" | "left" | "iso", at: vec(x, y), scale:)` (without `at:` the layout places it; `at:` is in paper mm from the bottom-left corner);
  - `d.section(solid, plane, label: "A")`: the solid cut by the plane, seen from the side the normal points to, cut faces hatched;
  - `d.dimension(view, from: vec(…), to: vec(…), offset: 8.mm, text:)` between two model points, on a view returned by `view`/`standardViews`; `d.note("text", at: vec(x, y), size: 3.5.mm)`.
  - `hcad render model.hcad -o sheet.pdf` exports the first drawing, `--drawing name` another one.
- **Standard algorithms** (eager, Phobos names, functions as normal arguments): `map`, `filter`, `fold`, `sum`, `any`, `all`, `count`, `canFind`, `sort`, `reverse`, `iota`, `cartesianProduct`, `zip`, `enumerate`, `join`, `min`, `max`, `minElement`, `maxElement`, `clamp`, `to!T`, `format`.

## Style

- Annotations (`@param`, `@preset`, `@part`, `@drawing`) go on their own line, above what they annotate; short ones share a line (`@preset("small", 40.mm) @preset("large", 120.mm)`), long ones get one line each.
- Long chains break before each call, the new line starting with the dot:

```d
@part("steelblue")
Solid block() => box(40, 30, 20)
    .fillet(edges.parallel(Z), r: 3.mm)
    .shell(open: faces.top, thickness: 2.mm);
```

## A tour of the language

Every basic construct once (values and units, parameters, functions, structs, `if`, `foreach`,
`while`, `for` with `continue`, `switch`, lists with `map`, `?:`, `unittest`, `writeln`), each
with a comment on what it makes appear in the view or in the console. It is
[examples/05_language.hcad](../examples/05_language.hcad), and **Examples › Language tour** in the
application: open it there, change the numbers and watch.

```d
// Language tour: if, for, while, switch, functions, structs and arrays, each with what it shows
/// A tour of the language: every basic construct once, each with what it
/// makes appear in the 3D view or in the Console below the editor.
/// Read it top to bottom, change the numbers, and watch what happens.
module language;

import std.shapes;
import std.math;

// ---- values and units
// Lengths carry their unit: 10.mm, 2.cm and 1.inch are all lengths, and a
// plain number in a shape is in mm. Angles are 30.deg (or radians).
// Module-level values are read-only: `immutable` for constants.
immutable plate = 60.mm;          // the width of the base plate below
immutable gap = 4.mm;
immutable tilt = 15.deg;

// ---- parameters
// @param puts a value in the Parameters panel (on the right), to change it:
// the model follows. min and max keep it sensible.
// Try 1, 3 and 5: the pegs on the plate change, and so do the green
// markers in front (see `switch` below).
@param("How many pegs", min: 1, max: 6)
immutable pegs = 4;

@param("Round pegs instead of square ones")
immutable round = true;

// ---- functions
// A function with a block body: statements, then `return`.
Solid peg(Length size, bool isRound)
{
    // `if`/`else`: one of the two shapes is made, never both
    if (isRound)
        return cylinder(d: size, h: 12.mm);
    else
        return box(size, size, 12.mm);
}

// A function with an expression body: `=> expression;`
Length pitch(int count) => (plate - 2 * gap) / count;

// ---- structs
// A struct groups values; it can have defaults and methods.
struct Marker
{
    Length r = 2.mm;
    Length height = 3.mm;

    Solid shape() => cylinder(r: r, h: height);
}

// ---- the parts: what the view shows
// Each @part function is one object in the view (and in the exports),
// with its colour. Without @part a function is only a helper.

/// The base plate with a row of pegs on it.
@part("steelblue")
Solid base()
{
    auto b = box(plate, 20.mm, 4.mm);   // boxes stand on z = 0, centred in x and y
    // `foreach` over a range: one peg per step, `pegs` of them (the parameter)
    foreach (i; 0 .. pegs)
    {
        immutable x = -plate / 2 + gap + pitch(pegs) * (i + 0.5);
        // `min`: as wide as the pitch allows, but never more than 16 mm,
        // so a few pegs do not grow past the plate's 20 mm depth
        b += peg(min(pitch(pegs) - 2.mm, 16.mm), round).move(x: x, z: 4.mm);
    }
    return b;
}

/// A staircase, built with `while`: it stops when the steps reach 15 mm.
@part("orange")
Solid stairs()
{
    auto s = Solid.init;   // the empty solid: nothing to see yet
    auto h = 3.mm;
    int step = 0;
    while (h <= 15.mm)
    {
        s += box(6.mm, 12.mm, h).move(x: 6.mm * step);
        h += 3.mm;
        step++;
    }
    // a C-style `for` and `continue`: holes in every step but the second
    for (int i = 0; i < step; i++)
    {
        if (i == 1)
            continue;   // this step keeps no hole: look for it in the view
        s -= cylinder(d: 2.mm, h: 40.mm, center: true).move(x: 6.mm * i);
    }
    return s.move(y: 30.mm);
}

/// `switch`: the green markers in front change shape with the number of
/// pegs: circles for 1 or 2, triangles for 3, hexagons for 4 to 6.
@part("seagreen")
Solid markers()
{
    auto outline = circle(r: 3.mm);   // a profile: a flat outline on XY
    switch (pegs)
    {
    case 1, 2:
        outline = circle(r: 3.mm);
        break;
    case 3:
        outline = polygon(3, r: 3.mm);
        break;
    default:
        outline = polygon(6, r: 3.mm);   // 4 to 6 pegs: hexagons
        break;
    }
    // arrays and algorithms: positions computed with `map`, shapes joined with `sum`
    auto xs = [-20.mm, 0.mm, 20.mm];
    return xs
        .map(x => outline.extrude(2.mm).move(x: x, y: -25.mm))
        .sum;
}

/// A struct at work, and the ternary `?:`: tall when the pegs are round.
@part("crimson")
Solid marker()
{
    auto m = Marker(r: 3.mm, height: round ? 8.mm : 3.mm);
    return m.shape.rotate(x: tilt).move(x: 45.mm);
}

// A function that is never called and has no @part: nothing of it appears.
Solid unused() => sphere(r: 100.mm);

// ---- checks and messages
// `unittest` blocks run after the parts are built. `writeln` prints to the
// Console; a failing `assert` is reported as a problem (the parts still show).
unittest
{
    writeln("pegs: ", pegs, ", pitch: ", pitch(pegs));
    writeln("base volume: ", base.volume);
    // the plate is wider than the pegs need: try 6 pegs and a plate of 20.mm
    assert(pitch(pegs) > 4.mm, "the pegs do not fit on the plate");
    // an associative array, looked up by key
    immutable names = [1: "one", 2: "two", 3: "three"];
    writeln("stairs: ", stairs.pieces.length == 1 ? "one piece" : "several pieces",
        ", three is ", names[3]);
}
```
