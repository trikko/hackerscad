# The `.hcad` language

A `.hcad` file is written in an **interpreted, sandboxed scripting language inspired by D**. Anyone who knows D can read it without
surprises. There is no compilation step: the interpreter runs inside hackerscad and re-evaluates a
model in milliseconds.

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
  - Library imports are limited to hackerscad's standard modules: `std.shapes`, `std.math`, `std.algorithm`, `std.range`, `std.conv`, `std.format`, `std.stdio`, `std.array`, and `hardware`.
  - Imports cannot leave the project directory or the library folder they were found in.
  - There is no file, network or process access.
  - Evaluation steps, recursion depth and array sizes are limited.
- **`writeln`** writes to hackerscad's console (and to the JSON output for agents), not to stdout.

## hackerscad additions
- **Units** are UFCS functions: `60.mm`, `2.5.cm`, `1.m`, `1.inch`, `45.deg`, `0.5.rad`.
  - Values carry a dimension (`Length`, `Angle`, `Area`, `Volume`), and arithmetic checks it: `Length * Length` is an `Area`, while `60.mm + 45.deg` is an error.
  - **Bare numbers** passed where a length is expected use the file's default unit: `mm`, or the unit set with `@unit(inch) module name;`. Values keep their unit, so libraries written with different default units combine correctly.
  - Mixing bare and dimensioned numbers in arithmetic (`60.mm + 5`) is an error. Scaling is fine (`2 * 60.mm`).
  - Bare angles passed to features (`rotate(z: 45)`) are degrees. `sin`/`cos` take radians for bare numbers, as in D.
- **Vectors:** `vec(10.mm, 5.mm)`, `vec(x, y, z)`, with `.x .y .z .xy .length .normalized`, `dot`, `cross`, `distance`. Vectors compare with a small tolerance.
- **Directions:** `X`, `Y`, `Z`, `-X`…
- **`@param("description", min:, max:, step:, choices:)`** above **`immutable name = default;`** declares a parameter. It can be overridden from the GUI, from the CLI (`-D name=80.mm`, or `-D name=80` in the model unit) and by agents, and is checked against its limits.
- **`@preset("name", value)`** on a parameter gives its value in a named preset (`--preset name`, or the preset menu in the GUI). A preset is the set of values declared under its name; parameters without a value for it keep their default.
  - Parameters never change during an evaluation: their value is decided beforehand, from default, then preset, then explicit override.
  - Like a configuration table: every parameter is a column, every preset a row.
- **`@part("colour")`** above **`Solid name() { … }`** declares an exported body: a separate object in 3MF, a separate named body in STEP, its own file in a zip of STLs (`name.stl`; a lone `.stl` takes one part). A part is evaluated once per run even when other parts refer to it. Without a colour a part is mint (`#8FCBB4`). `@part("slategray", alpha: 0.4)` makes it see-through; `export: false` makes it a reference part (a shaft, a board, the object a holder is for): drawn in the view and in PNGs, left out of STL, 3MF and STEP. `name: "Tank"` is the part's name in exported files (object, body and file names) instead of the function's; two parts cannot share one.
- **Colours** are CSS names (`"steelblue"`), `"#RRGGBB"`, `"#RRGGBBAA"` (the last byte is the opacity) or `rgb(r, g, b)` with 0…255 channels, `rgb(r, g, b, alpha: 0.5)`. `solid.color("orange", alpha: 0.5)` works too.
- **`unittest { assert(…); }`** blocks are design checks. They run after evaluation; a failure does not discard the geometry, but is reported in the GUI, the CLI and to agents.
- **Solids and booleans:**
  - `a + b` union, `a - b` difference, `a & b` intersection; `s += x` inside functions.
  - `hull(a, b, …)` or `hull([a, b, …])`: the smallest convex shape around solids and profiles (two spheres make a capsule, four cylinders a plate with round corners); profiles in one plane give a profile, `hull(circle(r: 4.mm), circle(r: 4.mm).move(x: 20.mm))` a slot. Curved surfaces become flat facets within 0.05 mm.
  - `minkowski(a, b)`: `a` moved by every point of `b`. With a sphere (a circle for profiles) it rounds every edge and corner exactly, like `s.offset(r)`; with another convex shape (a box, a cylinder) it is made of flat facets, and one of the two shapes must be convex.
  - `s.offset(d)` grows a solid by `d` (or shrinks it, `d` negative), round where it turns.
- **Printing:** `teardrop(d: 5.mm)` is a round hole with a 45° point towards +Y: cut on a wall (`body.cut(teardrop(d: 3.4.mm), on: faces.front, through: true)`) the point is up and the hole prints without supports (`angle:` another point, `flat: true` cuts it at the circle's top). `faces.overhanging()` selects the faces facing down more steeply than 45° from a wall (`faces.overhanging(60.deg)` another angle; faces resting on the bed are not counted), `s.overhangs(45.deg)` is their area and `s.thinWalls(0.8.mm)` the surface over walls thinner than that: `assert(part.thinWalls == 0.mm ^^ 2)` in a unittest keeps a model printable. The Printability display style shows both on the model.
- **Profiles from solids:** `s.section(XZ)` (any plane: `s.section(s.plane(faces.top).offset(-2.mm))`) is the cut of the solid by the plane, a profile lying in it; `s.projection` is the solid's shadow seen from above, a profile on XY, and `s.projection(XZ)` its shadow on any plane, cast along the plane's normal (curved surfaces within 0.02 mm). Both can be extruded, offset, combined like any profile.
- **Mass:** `s.centroid` is the centre of mass; `s.mass(density: 1.24)` the mass in grams for a density in g/cm³ (PLA 1.24, PETG 1.27, ABS 1.04, aluminium 2.70, steel 7.85); `s.inertia(density: 1.24)` the principal moments of inertia about the centre of mass, ascending, in g·mm².
  - `Solid.init` and `nothing` are the empty solid. `solids.sum` and `fuse(…)` unite arrays.
- **Primitives** stand on the XY plane, centred in X and Y; `center: true` centres them in Z too. Spheres are centred.
  - `box(x, y, z)`, `cylinder(r | d, h)`, `cone(r1 | d1, r2 | d2, h)`, `sphere(r | d)`.
- **Profiles** (2D shapes on the XY plane, type `Profile`):
  - `rect(w, h)` and `circle(r | d)` centred on the origin; `polygon([vec(0, 0), vec(30, 0), vec(0, 20)])`; `regularPolygon(6, d: 10.mm)` (d/r through the corners); `slot(length, width)` (a stadium along X); `text("text", size: 10.mm, font: "Sans")` (starting at the origin on the baseline).
  - Combine with `+ - &`, move/rotate/mirror like solids; `.round(r)` rounds the corners; `.offset(d)` grows (d > 0) or shrinks it; `.area`.
  - `.extrude(h)` makes a solid along +Z (negative h goes down); options `taper: 3.deg` (sides narrow towards the top), `symmetric: true`. Extrude while the profile lies on XY, then place the solid.
  - `.revolve()`: turned around the axis, standing up: the profile's x is the radius and its y the height along Z (pots, bottles, knobs). `.revolve(axis: X, angle: 180.deg)`: around an axis in the profile's plane (a direction through the origin or an `Axis`), without standing up; `angle:` turns less than all the way.
  - On a face or plane, add or remove material in one step: `body.extrude(profile, on: frame, depth: 5.mm)` grows outwards along the frame's Z; `body.cut(profile, on: frame, depth: 2.mm)` digs in, `through: true` cuts all the way. Both accept `taper:`.
  - Push and pull faces: `body.extrude(faces.top, depth: 5.mm)` sweeps flat faces of the body outwards along their normals and adds the material, `body.cut(faces.top, depth: 2.mm)` sinks them (a negative depth to extrude does the same). `along: vec(1, 0, 1)` sweeps them in another direction, slanted sides: material is added when the direction leaves the face, removed when it enters. In the 3D view: right-click a face, Extrude face… or Push face in….
- **Paths, sweeps and lofts:**
  - Paths (type `Path`): `path([vec(0, 0, 0), vec(0, 0, 20), vec(30, 0, 20)])` (straight segments, mitred corners; `closed: true`), `spline([…])` (a smooth curve through the points), `helix(r | d, pitch:, height:, left: false)` (around +Z, starting at (r, 0, 0)). Paths move, rotate and mirror like solids.
  - `profile.sweep(path)`: the profile, drawn on XY around the origin, starts at the beginning of the path, normal to it, with its +Y kept towards world +Z (towards +Y when the path starts vertically). `frenet: true` follows the curvature (use it for helices: springs, threads). Holes in the profile give tubes.
  - `loft([circle(r: 20), rect(30).move(z: 40), circle(r: 10).move(z: 80)])`: a smooth solid through profiles placed in space; `ruled: true` gives flat sides. Profiles with holes are lofted as tubes when every profile has the same number of holes.
- **Constrained sketches** (2D on XY): `auto s = sketch();` then add geometry and constraints and take `s.profile`.
  - Geometry: `s.point(x, y)` (where it starts: constraints move it; `fixed: true` pins it there), `s.line(p, q)`, `s.arc(center, start, end)` (counter-clockwise), `s.circle(center, r: | d:)` (without r/d the radius is left to the constraints), `s.polyline([p1, p2, vec(…)], closed: true)` (returns the lines; vectors become new points). `construction: true` geometry helps constraining but is not part of the outline.
  - Constraints: `coincident(p, q)`, `fix(p)`, `horizontal(line | p, q)`, `vertical(…)`, `length(line, v)`, `distance(p, q, v)`, `distance(p, q, v, along: X | Y)`, `distance(p, line, v)`, `on(p, line | circle | arc)`, `parallel(a, b)`, `perpendicular(a, b)`, `angle(a, b, v)` (between the line directions, start → end), `equal(a, b)` (lengths or radii), `radius(c, v)`, `diameter(c, v)`, `tangent(line | circle, circle | line)`, `midpoint(p, line)`, `symmetric(p, q, line)`.
  - `s.fillet(p, r)` rounds the corner where two lines meet at p.
  - Reading back: `p.x`, `p.y`, `p.pos`, `line.start`, `line.end`, `line.length`, `line.mid`, `c.center`, `c.radius`, `s.dof` (degrees of freedom left), `s.solved`.
  - `s.profile` solves and returns the closed loops of non-construction lines, arcs and circles as a `Profile` (inner loops are holes). Under-constrained sketches still work, with a warning listing the lines of the free points; conflicting constraints are an error pointing at them.
- **Transforms:** `move(v | x:, y:, z:)`, `rotate(x:, y:, z:)` or `rotate(angle, axis:)` (a direction through the origin, or an `Axis` anywhere), `scale(k)`, `mirror(X)` (plane through the origin with that normal) or `mirror(plane)` (any plane), `color(c)`.
- **Placement:** `a.nextTo(b, X, gap: 10.mm)`, `a.on(b)`, `a.align(b, x: "center", z: "min")` (each axis `"min"`, `"center"` or `"max"` of the bounding boxes).
- **Patterns:** `hole.linearPattern(4, step: vec(10, 0, 0))`, `peg.circularPattern(6, axis: Z, angle: 360.deg)` give one solid with all the copies (subtract it to cut them all).
- **Axes:** `axis(origin: vec(10, 0, 0), direction: Z)`, `axis(p1, p2)` (through two points), `body.axis(edges.filter(…))` (the line of a straight edge, or the centre and normal of a circular one such as a hole rim), `frame.axis(X)` (an axis of a frame). Fields: `origin`, `direction`. Use them with `rotate(angle, axis: a)` and `circularPattern(n, axis: a)`.
- **Planes:** `XY`, `XZ`, `YZ`, `plane(origin: vec(0, 0, 10), normal: Z)`, `plane(p1, p2, p3)` (three points; the normal follows p1 → p2 → p3 by the right-hand rule), `plane(axis, point)` (containing a line and a point), or the plane of a face: `body.plane(faces.top)`. Planes also mirror: `s.mirror(plane)`.
  - `p.offset(5.mm)` is the parallel plane moved along the normal (negative goes the other way); `p.flip` reverses the normal.
  - Fields: `origin`, `normal`.
- **Frames** (an origin and X, Y, Z axes) to build on faces and planes:
  - `body.frame(faces.top)`: origin at the face centre, Z along the outward normal, X along the global X projected on the face (global Y if X is perpendicular). Options: `origin: vec(…)` (projected on the face), `x: Y`.
  - `plane.frame(origin: vec(…), x: …)`: on a plane the origin defaults to the plane's origin; give a point to choose another one.
  - `World` is the global frame; `f.at(x: 10, y: -5)` moves the origin in local coordinates; `f.turn(30.deg)` rotates X and Y around Z. Fields: `origin`, `x`, `y`, `z`.
  - `solid.placeOn(f)`: a solid built on XY with Z up is moved onto the frame. A plane works too (`placeOn(plane)`): its origin is the zero and X is the global X projected on it. A boss: `cylinder(d: 8, h: 5).placeOn(f)`; a pocket: `body - box(10, 10, 3).move(z: -3).placeOn(f)`.
- **Cutting:** `s.split(plane)` returns both sides: `.above` (where the normal points) and `.below`.
- **Separate bodies:** `s.pieces` lists the disconnected bodies of a solid (e.g. after a cut through it), ordered by position along X, then Y, then Z; pick one with `[i]` or sort them (`s.pieces.sort((a, b) => a.volume > b.volume)`).
- **Importing parts:** `load("part.stl")`, `load("part.obj")`, `load("part.3mf")`, `load("part.step")`, with `scale:` (STL and OBJ are read in mm; 3MF uses its own unit and build transforms). Meshes become solids (coplanar triangles merged into faces, closed meshes only), STEP files keep their exact geometry; both can be cut, filleted, measured and selected like any other solid. Paths are relative to the model file and must stay inside the project directory. Drawings become profiles on XY: `load("logo.svg")` and `load("plate.dxf")` give their closed outlines (an outline inside another is a hole, inside a hole an island), ready to extrude; SVG sizes come from the drawing's width and height in mm, cm, in or pt (plain numbers are mm), DXF from its $INSUNITS (mm when unset); curves within 0.05 mm. Open lines, text and images are left out.
- **Centring:** `shape.centered` moves a profile (in X and Y) or a solid (in X, Y and Z) so its bounding box is centred on the origin, e.g. `text("LABEL", size: 4.mm).centered`.
- **Measuring:** `distance(a, b)` between two solids (0 when they touch), `s.bbox`, `s.volume`, `s.area`.
- **Introspection:** `s.bbox` (`min`, `max`, `size`, `center`), `s.volume`, `s.area`, `s.isValid`.
- **Features:** `fillet(edges, r:)`, `chamfer(edges, d:)`, `shell(open: faces, thickness:)`, `draft(faces, angle:, pull: Z, neutral: 0.mm)` (mould taper around the neutral plane).
- **Face provenance:** every face remembers the feature that created it (primitive, fillet, shell, split…). Clicking a face in the GUI highlights it and jumps to that line.
- **Topological selectors** are resolved against the solid the feature is applied to:
  - predicates: `edges.filter(e => e.isParallel(Z))`, `faces.filter(f => f.normal == Z)`;
  - shortcuts: `edges.parallel(Z)`, `edges.perpendicular(Z)`, `edges.lines`, `edges.circles`, `faces.top/bottom/left/right/front/back`, `faces.normal(X)`, `faces.largest`;
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

## Example
See [examples/box.hcad](../examples/box.hcad).
