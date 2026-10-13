# hackerscad cheatsheet

s is a Solid, p a Profile, f a Frame; every value is immutable: operations give new values.

## Objects and types

- `Solid` — A 3D body: boxes, cylinders, booleans, features. Every operation gives a new one.
- `Profile` — A flat 2D outline on XY (rect, circle, text, sketch.profile): extrude or revolve it into a Solid.
- `Path` — A curve in space (path, spline, helix) to sweep a profile along.
- `Vec` — A 2D or 3D vector or point: vec(10.mm, 5.mm, 0.mm); .x .y .z .length.
- `Vec2` — A 2D vector.
- `Vec3` — A 3D vector.
- `Direction` — An axis direction: X, Y, Z, -X…, or any vector.
- `Plane` — An infinite plane: an origin and a normal (XY, plane(…), body.plane(faces.top)); cuts, mirrors, sections.
- `Axis` — A line in space: an origin and a direction (axis(…), body.axis(edges…)); rotations and circular patterns.
- `Frame` — A coordinate system on a face or plane: origin, X, Y and Z (body.frame(faces.top)); placeOn builds on it.
- `BBox` — A solid's bounding box: min, max, size, center.
- `Split` — What split gives: .above (where the plane's normal points) and .below.
- `Edges` — A selection of a solid's edges, for fillet and chamfer: edges.parallel(Z), edges.of(faces.top)…
- `Faces` — A selection of a solid's faces, for shell, draft, frames: faces.top, faces.normal(X)…
- `Edge` — One edge, inside a selector predicate: edges.filter(e => e.isCircle && e.radius == 3.mm).
- `Face` — One face, inside a selector predicate: faces.filter(f => f.center.z > 10.mm).
- `Sketch` — A constrained 2D drawing: points, lines, arcs and constraints; the solver places them, .profile gives the outline.
- `Drawing` — A technical sheet (views, sections, dimensions) returned by a @drawing function; exported as PDF, SVG, DXF.
- `Assembly` — Parts placed by their connections (planned).
- `Color` — A colour: "steelblue", "#RRGGBB", "#RRGGBBAA" or rgb(…).
- `Length` — A length with its unit: 10.mm, 2.5.cm; bare numbers given to geometry are mm.
- `Angle` — An angle: 30.deg, 0.5.rad.
- `Area` — An area (Length × Length).
- `Volume` — A volume.
- `bool` — true or false.
- `int` — An integer.
- `double` — A number.
- `float` — A number.
- `real` — A number.
- `long` — An integer.
- `string` — Text.

## Output

- `writeln(values…)` — Prints to the console (and to the JSON output for agents).
- `write(values…)` — Prints without a newline.
- `format(fmt: string, values…) → string` — Formats like D's format: format("%.1f", x).
- `to(value)` — Converts: x.to!string, s.to!int.

## Math

- `sqrt(x: number) → number` — Square root.
- `abs(x)` — Absolute value (keeps the unit).
- `floor(x: number) → number` — Rounds down.
- `ceil(x: number) → number` — Rounds up.
- `round(x: number) → number` — Rounds to the nearest integer; on a profile, profile.round(r) rounds its corners.
- `sin(a: Angle) → number` — Sine; bare numbers are radians.
- `cos(a: Angle) → number` — Cosine; bare numbers are radians.
- `tan(a: Angle) → number` — Tangent; bare numbers are radians.
- `asin(x: number) → Angle` — Arc sine.
- `acos(x: number) → Angle` — Arc cosine.
- `atan(x: number) → Angle` — Arc tangent.
- `atan2(y, x) → Angle` — The angle of the point (x, y).
- `min(a, b…)` — The smallest argument.
- `max(a, b…)` — The largest argument.
- `xs.minElement()` — The smallest element of a list.
- `xs.maxElement()` — The largest element of a list.
- `clamp(value, lo, hi)` — value limited to lo … hi.

## Vectors

- `vec(x, y, z) → Vec` — A 2D or 3D vector: vec(10.mm, 5.mm).
- `v.dot(b: Vec) → number` — Dot product.
- `v.cross(b: Vec) → Vec` — Cross product.
- `distance(a, b) → Length` — Between two points, or the minimum distance between two solids (0 when they touch).

## Lists

- `iota(a: int, b: int, step: int) → list` — The integers a … b-1 (or 0 … a-1).
- `xs.map(f: x => …) → list` — xs.map(x => x * 2).
- `xs.filter(f: x => bool) → list` — xs.filter(x => x > 0).
- `xs.fold(f: (acc, x) => …, seed)` — xs.fold((acc, x) => acc + x).
- `xs.sum()` — The sum; of solids, their union.
- `fuse(solids: Solid[]) → Solid` — The union of a list of solids.
- `xs.any(f: x => bool) → bool` — Whether some element satisfies f.
- `xs.all(f: x => bool) → bool` — Whether every element satisfies f.
- `xs.count(f: x => bool) → int` — How many elements (that satisfy f).
- `xs.canFind(value or f) → bool` — xs.canFind(value) or xs.canFind(x => condition).
- `xs.sort(less: (a, b) => bool) → list` — xs.sort or xs.sort((a, b) => a > b).
- `xs.reverse() → list` — The list backwards.
- `xs.retro() → list` — The list backwards.
- `xs.array() → list` — A list from a range.
- `xs.enumerate() → list` — (index, value) pairs.
- `zip(a: list, b: list) → list` — Pairs of elements.
- `cartesianProduct(a: list, b: list) → list` — Every pair.
- `xs.join(sep: string) → string` — The elements as one string.

## Colours

- `rgb(r: 0..255, g: 0..255, b: 0..255, alpha: 0..1) → Color` — A colour; rgb(r, g, b, alpha: 0.5) is see-through.

## Solids

- `box(x: Length, y: Length, z: Length, center: bool) → Solid` — A box standing on XY, centred in X and Y.
- `cylinder(r: Length, h: Length, d: Length, center: bool) → Solid` — A cylinder along Z standing on XY; give r or d, and h.
- `cone(r1: Length, r2: Length, h: Length, d1: Length, d2: Length, center: bool) → Solid` — A cone (or truncated cone) along Z.
- `sphere(r: Length, d: Length) → Solid` — A sphere centred on the origin.
- `load(path: string, scale: number) → Solid` — A part from an STL, OBJ, 3MF or STEP file in the project.

## Transforms

- `s.move(v: Vec, x: Length, y: Length, z: Length)` — Moves: move(x: 10.mm) or move(vec(…)).
- `s.rotate(angle: Angle, axis: Axis, x: Angle, y: Angle, z: Angle)` — rotate(z: 45) in degrees, or rotate(angle, axis: a) around any axis.
- `s.scale(factor: number)` — Scales around the origin.
- `s.mirror(plane: Plane)` — mirror(X): across the plane through the origin with that normal, or any plane.
- `s.color(color: Color, alpha: 0..1) → Solid` — Sets the colour: "steelblue", "#RRGGBB", rgb(…).
- `s.centered()` — Moved so its bounding box is centred on the origin.

## Features

- `s.fillet(edges: Edges, r: Length) → Solid` — Rounds the selected edges. Apply it before shell and before cutting holes.
- `s.chamfer(edges: Edges, d: Length) → Solid` — Bevels the selected edges.
- `s.shell(open: Faces, thickness: Length) → Solid` — Hollows the solid, leaving the faces in open: open. Open several faces in one shell.
- `s.draft(faces: Faces, angle: Angle, pull: Direction, neutral: Length) → Solid` — Tapers faces so the part leaves a mould.

## Placement and copies

- `s.nextTo(other: Solid, dir: Direction, gap: Length) → Solid` — Beside another solid: a.nextTo(b, X, gap: 10.mm).
- `s.on(other: Solid, gap: Length) → Solid` — On top of another solid.
- `s.align(other: Solid, x: string, y: string, z: string) → Solid` — Aligns bounding boxes per axis: "min", "center" or "max".
- `s.linearPattern(n: int, step: Vec) → Solid` — n copies, step apart, as one solid.
- `s.circularPattern(n: int, axis: Axis, angle: Angle) → Solid` — n copies around an axis, as one solid.
- `s.placeOn(frame: Frame) → Solid` — A solid built on XY (Z up) moved onto a frame or plane.
- `s.split(plane: Plane) → Split` — Cuts with a plane: .above (where the normal points) and .below.

## Profiles (2D)

- `rect(w: Length, h: Length) → Profile` — A rectangle centred on the origin.
- `circle(r: Length, d: Length) → Profile` — A circle centred on the origin.
- `polygon(points: Vec[]) → Profile` — A polygon through the points.
- `regularPolygon(n: int, r: Length, d: Length) → Profile` — regularPolygon(6, d: 10.mm): d/r through the corners.
- `slot(length: Length, width: Length) → Profile` — A stadium along X.
- `text(text: string, size: Length, font: string) → Profile` — A text outline starting at the origin on the baseline.
- `p.round(r: Length) → Profile` — Rounds the (convex) corners.
- `p.offset(distance: Length) → Profile` — Grows (d > 0) or shrinks the outline; on a plane, the parallel plane.
- `p.extrude(height: Length, taper: Angle, symmetric: bool) → Solid` — A solid along +Z from the profile.
- `p.revolve(axis: Axis, angle: Angle) → Solid` — Turns the profile around an axis in its plane; without one, x is the radius and y the height along Z.
- `p.sweep(path: Path, frenet: bool) → Solid` — Moves the profile along a path.
- `loft(profiles: Profile[], ruled: bool) → Solid` — A solid through profiles placed in space.
- `s.cut(profile: Profile, on: Frame, depth: Length, through: bool, taper: Angle) → Solid` — Digs a profile into a face: body.cut(p, on: frame, depth: 2.mm).

## Paths, sweeps and lofts

- `path(points: Vec[], closed: bool) → Path` — Straight segments through the points.
- `spline(points: Vec[], closed: bool) → Path` — A smooth curve through the points.
- `helix(r: Length, d: Length, pitch: Length, height: Length, left: bool) → Path` — A helix around +Z.

## Planes, axes and frames

- `plane(origin: Vec, normal: Direction) → Plane` — plane(origin:, normal:), plane(p1, p2, p3), or body.plane(faces.top).
- `axis(origin: Vec, direction: Direction) → Axis` — axis(origin:, direction:), axis(p1, p2), or body.axis(edges…).
- `s.frame(face: Faces, origin: Vec, x: Direction) → Frame` — A frame on a face: origin at its centre, Z outwards.
- `f.at(x: Length, y: Length, z: Length) → Frame` — The frame with its origin moved, in local coordinates.
- `f.turn(angle: Angle) → Frame` — The frame turned around its Z.
- `pl.flip() → Plane` — The plane with its normal reversed.

## Measuring

- `s.bbox → BBox` — The bounding box: min, max, size, center.
- `s.volume → Volume` — The volume.
- `s.area → Area` — The surface area (of a profile: its area).
- `s.isEmpty → bool` — Whether nothing is left.
- `s.isValid → bool` — Whether the solid is a valid closed solid.
- `s.pieces → Solid[]` — The separate bodies, ordered along X, then Y, then Z.
- `s.split(…).above → Solid` — The side of the cut the normal points to.
- `s.split(…).below → Solid` — The other side of the cut.
- `s.bbox.min → Vec` — The lowest corner.
- `s.bbox.max → Vec` — The highest corner.
- `s.bbox.size → Vec` — Width, depth and height.
- `s.bbox.center → Vec` — The centre.
- `v.x → Length` — X component.
- `v.y → Length` — Y component.
- `v.z → Length` — Z component.
- `v.xy → Vec` — X and Y.
- `v.length → Length` — Length of the vector (of a list: how many elements).
- `v.normalized → Vec` — The unit vector.
- `f.origin → Vec` — The origin (also of planes and axes).
- `pl.normal → Direction` — The normal.
- `a.direction → Direction` — The direction.

## Selectors

- `faces.top → Faces` — The face(s) facing +Z the most.
- `faces.bottom → Faces` — The face(s) facing -Z.
- `faces.front → Faces` — The face(s) facing -Y.
- `faces.back → Faces` — The face(s) facing +Y.
- `faces.left → Faces` — The face(s) facing -X.
- `faces.right → Faces` — The face(s) facing +X.
- `faces.largest → Faces` — The largest face.
- `faces.normal(dir: Direction) → Faces` — The faces with that normal: faces.normal(X).
- `faces.from(tool: Solid) → Faces` — The faces created by a tool or feature: faces.from(holes).
- `edges.parallel(axis: Direction) → Edges` — The straight edges along an axis: edges.parallel(Z).
- `edges.perpendicular(axis: Direction) → Edges` — The edges at right angles to an axis.
- `edges.lines → Edges` — The straight edges.
- `edges.circles → Edges` — The circular edges.
- `edges.of(faces: Faces) → Edges` — The edges around faces: edges.of(faces.top).
- `edges.between(a: Faces, b: Faces) → Edges` — The edges between two sets of faces.
- `e.start → Vec` — Start point.
- `e.end → Vec` — End point.
- `e.mid → Vec` — Middle point.
- `e.isLine → bool` — Whether it is straight.
- `e.isCircle → bool` — Whether it is a circle or an arc.
- `e.radius → Length` — The radius of a circular edge.
- `e.isParallel(axis: Direction) → bool` — Whether it runs along the axis (a face: whether its normal does).
- `e.isPerpendicular(axis: Direction) → bool` — Whether it is at right angles to the axis.

## Sketches

- `sketch() → Sketch` — A constrained 2D sketch: add points, lines, constraints, then take .profile.
- `sk.point(x: Length, y: Length, fixed: bool) → Point` — A point where it starts; constraints move it.
- `sk.line(p: Point, q: Point) → Line` — A line between two points.
- `sk.arc(center: Point, start: Point, end: Point) → Arc` — An arc, counter-clockwise.
- `sk.polyline(points, closed: bool) → Line[]` — Lines through points (vectors become new points).
- `sk.coincident(p: Point, q: Point)` — Two points in the same place.
- `sk.fix(p: Point)` — Pins a point.
- `sk.horizontal(line: Line)` — A horizontal line (or two points at the same height).
- `sk.vertical(line: Line)` — A vertical line.
- `sk.equal(a, b)` — Equal lengths or radii.
- `sk.tangent(a, b)` — Tangent line and circle, or two circles.
- `sk.midpoint(p: Point, line: Line)` — A point in the middle of a line.
- `sk.symmetric(p: Point, q: Point, line: Line)` — Two points symmetric about a line.
- `sk.diameter(c: Circle, v: Length)` — Sets a diameter.
- `sk.profile → Profile` — Solves the sketch and gives its outline.
- `sk.dof → int` — Degrees of freedom left.
- `sk.solved → bool` — Whether the constraints are satisfied.

## Drawings

- `drawing(size: string, title: string, author: string, material: string, projection: string, scale: number, landscape: bool) → Drawing` — A technical sheet, returned by a @drawing function.
- `d.standardViews(solid: Solid, iso: bool, dimensions: bool)` — Front, top, side and iso views, laid out.
- `d.view(solid: Solid, name: string, at: Vec, scale: number) → View` — One view: "front", "top", "iso"…
- `d.section(solid: Solid, plane: Plane, label: string) → View` — A hatched section.
- `d.dimension(view: View, from: Vec, to: Vec, offset: Length, text: string)` — A dimension between two points.
- `d.note(text: string, at: Vec, size: Length)` — A note on the sheet.

## Units

- `10.mm` — Millimetres: 60.mm.
- `10.cm` — Centimetres.
- `10.m` — Metres.
- `10.inch` — Inches.
- `10.deg` — Degrees: 45.deg.
- `10.rad` — Radians.

## Constants

- `X: Direction` — The X axis (also a plane normal).
- `Y: Direction` — The Y axis.
- `Z: Direction` — The Z axis.
- `XY: Plane` — The XY plane.
- `XZ: Plane` — The XZ plane.
- `YZ: Plane` — The YZ plane.
- `World: Frame` — The global frame.
- `PI: number` — π.
- `nothing: Solid` — The empty solid (also Solid.init): start of a union built in a loop.
- `edges: Edges` — The edges of the solid a feature applies to: edges.parallel(Z).
- `faces: Faces` — The faces of the solid a feature applies to: faces.top.

## Keywords

- `module` — Names the model: module box;
- `import` — import hardware : M3;  import pizza;  import p = parts.bracket;
- `immutable` — A constant: immutable width = 60.mm;
- `auto` — A local variable: auto s = box(…);
- `return` — Gives the result of a function.
- `foreach` — foreach (i; 0 .. n)  foreach (x; xs)
- `if` — if (condition) … else …
- `else` — The other branch of an if.
- `for` — for (int i = 0; i < n; i++)
- `while` — while (condition) …
- `struct` — A record type with fields.
- `unittest` — Design checks, run after every evaluation.
- `assert` — assert(condition, "message")
- `private` — Not visible to modules that import this one.
- `public` — public import: re-exported to whoever imports this module.
- `true` — Boolean true.
- `false` — Boolean false.

## Annotations

- `@part(color, alpha: 0..1, export: bool, name: string)` — A body to show and export: @part("steelblue"); name: its name in exported files.
- `@param(description, min:, max:, step:, choices:)` — A parameter with a field in the panel.
- `@preset(name, value)` — The parameter's value in a named preset.
- `@drawing` — A function returning a technical drawing.
- `@assembly` — A function returning an assembly.
- `@unit(unit)` — The default unit of bare numbers: @unit(inch) module m;

## Library: import hardware;

- `struct Screw(name: string, d: Length, pitch: Length, tap: Length, clearance: Length, head: Length, headHeight: Length, key: Length, nut: Length, nutHeight: Length, washer: Length, insert: Length, insertDepth: Length)` — Metric screw sizes (ISO 4762 socket head cap screws, ISO 4032 nuts, ISO 7089 washers) with the holes to print or drill for them.
- `hexPrism(acrossFlats: Length, h: Length) → Solid` — Hexagonal prism standing on XY, flats parallel to the X axis.
- `screw(s: Screw, length: Length, socket: bool = true, threaded: bool = false) → Solid` — Socket head cap screw. The underside of the head lies on z = 0: the head grows upwards and the shank downwards, so the screw drops into a hole. threaded: true models the ISO thread (slower); otherwise the shank is plain.
- `nut(s: Screw, threaded: bool = false) → Solid` — Hex nut standing on z = 0, with the corners chamfered on both faces. threaded: true cuts the ISO thread in the hole.
- `washer(s: Screw) → Solid` — Flat washer standing on z = 0.
- `hole(s: Screw, depth: Length, kind: string = "clearance") → Solid` — A hole to subtract, with its top on z = 0 going down `depth`: "clearance" (the screw passes), "tap" (pilot hole for the thread), "insert" (heat-set insert), "counterbore" (clearance with room for the head) or "countersink" (for flat heads).
- `nutTrap(s: Screw, depth: Length, clearance: Length = …) → Solid` — A pocket to trap a nut, from z = 0 going down `depth` (with a little clearance).
- `M2, M2_5, M3, M4, M5, M6, M8: Screw`

## Library: import threads;

- `toothHeight(pitch: Length) → Length` — Height of the thread tooth for a pitch (from the minor to the major diameter).
- `threadedRod(d: Length, pitch: Length, length: Length, chamfer: bool = true, left: bool = false) → Solid` — A threaded rod of nominal diameter `d` standing on z = 0, with the ends chamfered (chamfer: false leaves them square).
- `tappedHole(d: Length, pitch: Length, depth: Length, clearance: Length = …) → Solid` — A tool to subtract for an internal thread that a `d` screw fits, from z = 0 going down `depth`. `clearance` widens it for printed parts.

## Library: import gears;

- `pitchDiameter(m: Length, teeth: int) → Length`
- `outsideDiameter(m: Length, teeth: int) → Length`
- `rootDiameter(m: Length, teeth: int) → Length`
- `centerDistance(m: Length, teeth1: int, teeth2: int) → Length`
- `involute(rb: Length, r: Length) → double` — Angle of the involute of a circle of radius rb at radius r.
- `gearProfile(m: Length, teeth: int, pressure: Angle = …, backlash: Length = …, steps: int = 6) → Profile` — The outline of a spur gear centred on the origin, a tooth on +X. backlash thins the teeth (measured on the pitch circle) so that printed gears do not bind.
- `spurGear(m: Length, teeth: int, thickness: Length, bore: Length = …, pressure: Angle = …, backlash: Length = …) → Solid` — A spur gear standing on z = 0, with an optional bore.
- `rack(m: Length, teeth: int, thickness: Length, base: Length = …, pressure: Angle = …) → Solid` — A straight rack along +X starting at x = 0, teeth up, pitch line at y = 0.

## Library: import hinges;

- `struct Hinge(fixed: Solid, moving: Solid)` — The two leaves of a hinge, printed in place: they come out of the printer already joined and turn around the X axis.
- `hinge(length: Length = …, width: Length = …, thickness: Length = …, knuckles: int = 5, clearance: Length = …) → Hinge` — A print-in-place hinge along X, centred on the origin, leaves lying flat on z = 0 and the axis at z = thickness. `knuckles` alternate between the leaves (odd numbers keep it symmetric).

## Library: import snaps;

- `snapHook(length: Length = …, thickness: Length = …, width: Length = …, overhang: Length = …, lead: Angle = …) → Solid` — A hook: a flexible beam `length` long with a barb `overhang` deep at the top. `lead` is the slope that pushes it aside when inserting.
- `snapSlot(thickness: Length = …, width: Length = …, overhang: Length = …, wall: Length = …, clearance: Length = …) → Solid` — The slot a hook clicks into, to subtract from the mating wall: a window `clearance` larger than the barb.

## Library: import enclosures;

- `roundedBox(x: Length, y: Length, z: Length, r: Length = …) → Solid` — A box centred in X and Y on z = 0, with vertical edges rounded by `r`.
- `tray(x: Length, y: Length, z: Length, wall: Length = …, r: Length = …) → Solid` — An open box: walls `wall` thick, open on top.
- `struct Enclosure(base: Solid, lid: Solid)` — A base and a lid that fit together, both standing on z = 0.
- `enclosure(inner: Vec3, wall: Length = …, r: Length = …, lidHeight: Length = …, screw: Screw = …, clearance: Length = …) → Enclosure` — An enclosure with `inner` free space (x, y, z), a lid with a lip that fits inside the base, and a screw post in each corner.

## How do I…

- Copy a solid (values never change: use it again): `auto b = a.move(x: 20.mm);`
- Many copies in a row: `peg.linearPattern(4, step: vec(10.mm, 0.mm, 0.mm))`
- Copies around an axis: `peg.circularPattern(6, axis: Z)`
- A mirrored copy, keeping the original: `s + s.mirror(X)`
- A hole: subtract a cylinder: `plate - cylinder(d: 5.mm, h: 10.mm).move(x: 10.mm)`
- Screw holes from the library: `s - hole(M3, 6.mm, "countersink").move(z: 6.mm)`
- Round the vertical edges: `box(40, 30, 20).fillet(edges.parallel(Z), r: 4.mm)`
- Hollow out, open on top: `s.shell(open: faces.top, thickness: 2.mm)`
- Build on a face: `cylinder(d: 8.mm, h: 5.mm).placeOn(body.frame(faces.top))`
- Put one part beside another: `lid.nextTo(body, X, gap: 10.mm)`
- Text in relief: `text("ABC", size: 5.mm).centered.extrude(0.6.mm)`
- Cut with a plane and keep one side: `s.split(XY.offset(10.mm)).below`
- A reference part, shown but not exported: `@part("slategray", alpha: 0.4, export: false)`
- A parameter in the side panel: `@param("Width", min: 10.mm, max: 100.mm) immutable width = 40.mm;`
- Check a requirement: `unittest { assert(body.bbox.size.z <= 40.mm, "too tall"); }`
- Measure: `writeln(s.volume, " ", s.bbox.size)`
