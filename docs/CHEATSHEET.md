# hackerscad cheatsheet

s is a Solid, p a Profile, f a Frame; every value is immutable: operations give new values.

## Objects and types

- `Solid` — A 3D body: boxes, cylinders, booleans, features. Every operation gives a new one.
- `Profile` — A flat 2D outline on XY (rect, circle, text, sketch.profile; a shape's profile is a one-shape sketch with everything given): combine with + - &, extrude or revolve it into a Solid.
- `Path` — A curve in space (path, spline, helix) to sweep a profile along.
- `Surface` — Faces with an edge open, no inside (a curve swept, a loft through paths): split a solid with it, thicken it, sew surfaces into a solid.
- `Vec` — A 2D or 3D vector or point: vec(10.mm, 5.mm, 0.mm); .x .y .z .length.
- `Vec2` — A 2D vector.
- `Vec3` — A 3D vector.
- `Direction` — An axis direction: X, Y, Z, -X…, or any vector.
- `Plane` — An infinite plane: an origin and a normal (XY, plane(…), body.plane(faces.top)); cuts, mirrors, sections.
- `Axis` — A line in space: an origin and a direction (axis(…), body.axis(edges…)); rotations and circular patterns.
- `Frame` — A coordinate system on a face or plane: origin, X, Y and Z (body.frame(faces.top)); placeOn builds on it.
- `BBox` — A solid's bounding box: min, max, size, center.
- `Halves` — What halves gives: .above (where the plane's normal points) and .below.
- `Edges` — A selection of a solid's edges, for fillet and chamfer: edges.parallel(Z), edges.of(faces.top)…
- `Faces` — A selection of a solid's faces, for shell, draft, frames: faces.top, faces.normal(X)…
- `Edge` — One edge, inside a selector predicate: edges.filter(e => e.isCircle && e.radius == 3.mm).
- `Face` — One face, inside a selector predicate: faces.filter(f => f.center.z > 10.mm).
- `Sketch` — A constrained 2D drawing: points, lines, arcs, circles, ellipses and constraints; the solver places them, .profile gives the outline.
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
- `to(value)` — Converts: x.to!string, s.to!int; a Length to the bare number that means it in this file (mm, or inches under @unit(inch); Area and Volume squared, cubed), an Angle to degrees.

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
- `pow(x, y)` — x to the power y, as x ^^ y: a length squared is an area.
- `exp(x: number) → number` — e to the power x.
- `log(x: number, base: number) → number` — The natural logarithm; log(x, base) in another base.
- `log10(x: number) → number` — The logarithm in base 10.
- `log2(x: number) → number` — The logarithm in base 2.
- `hypot(a, b)` — The hypotenuse: hypot(3.mm, 4.mm) is 5 mm.
- `sign(x) → int` — -1, 0 or 1.
- `lerp(a, b, t: number)` — From a (t = 0) to b (t = 1) in a straight line: numbers, lengths or vectors.
- `min(a, b…)` — The smallest argument.
- `max(a, b…)` — The largest argument.
- `random(lo: number, hi: number, seed: int)` — Uniform between lo and hi (lengths, angles or plain numbers), the next of the seed's stream: the same at every run; change the seed for others.
- `noise(x: number, y: number, z: number, seed: int) → double` — Smooth noise, about -1…1, features about one unit across; lengths count in mm.
- `loopNoise(around: number, along: number, bumps: number, seed: int) → double` — Noise round a loop: around 0…1, along across it, about bumps features round; no seam where it closes.
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
- `torus(major: Length, minor: Length) → Solid` — A ring round Z centred on the origin: major to the middle of the tube, minor the tube's radius.
- `sphere(r: Length, d: Length) → Solid` — A sphere centred on the origin.
- `load(path: string, scale: number) → Solid` — A part from an STL, OBJ, 3MF or STEP file in the project; from an SVG or DXF drawing, its closed outlines as a profile on XY (mm).

## Transforms

- `s.move(v: Vec, x: Length, y: Length, z: Length)` — Moves: move(x: 10.mm) or move(vec(…)).
- `s.rotate(angle: Angle, axis: Axis, x: Angle, y: Angle, z: Angle, around: Vec)` — Turns about the origin, or about the point given as around:.
- `s.scale(factor: number, x: number, y: number, z: number, around: Vec)` — Scales around the origin, or around the point given as around:.
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
- `s.placeOn(frame: Frame, from: Faces, at: Vec) → Solid` — A solid built on XY (Z up) moved onto a frame or plane; from: one of its faces laid against it instead (at: a point of that face onto the origin).
- `s.split(plane: Plane | Surface | Solid) → Solid[]` — Cuts with a plane (or a surface, or another solid's skin) into the pieces it leaves, both sides, along X, then Y, then Z: for @parts, or .above(plane), .largest…
- `x.thicken(thickness: Length) → Solid` — The surface made a solid that thick, on the side its normals point (negative: the other side).
- `fill(path: Path, through: Vec[]) → Surface` — A smooth face closing a loop: a closed path, or on a solid body.fill(edges, tangent: faces) a loop of its edges (meeting the faces given smoothly, the others with an edge); through: points it passes through too.
- `sew(surfaces: Surface[]) → Solid` — Surfaces (and flat profiles, to close their ends) that close round a space, joined along their edges into one solid; an error says how many edges stay open.
- `s.halves(plane: Plane) → Halves` — Cuts with a plane in two sides: .above (where the normal points) and .below, each one solid.

## Profiles (2D)

- `rect(w: Length, h: Length, p: Vec, q: Vec, center: Vec, angle: Angle, corner: Length) → Profile` — A rectangle: centred on the origin (or center:), from two opposite corners, or from one corner and its size; angle: turns it about its centre (a rotated, tilted rectangle, at an angle), corner: rounds its corners. s.rect with everything given.
- `circle(r: Length, d: Length, center: Vec) → Profile` — A circle centred on the origin, or round a point. s.circle with everything given.
- `ellipse(rx: Length, ry: Length, angle: Angle, center: Vec) → Profile` — An ellipse centred on the origin (or round a point), rx along X, ry along Y; angle: turns it. s.ellipse with everything given.
- `polygon(points: Vec[], smooth: bool, n: int, r | d: Length, fit: string, angle: Angle, center: Vec) → Profile` — A polygon through the points (smooth: true, a smooth closed curve through them instead); or a regular one of n sides, centred on the origin or round a point: d/r the circle through its corners, or with fit: "sides" the circle its sides touch; angle: the direction of its first corner, else its first side lies at the bottom, horizontal. s.polygon with everything given.
- `slot(length: Length, w: Length, p: Vec, q: Vec, center: Vec, angle: Angle) → Profile` — A stadium: length end to end along X, centred on the origin (or center:, angle: turned); or round two centres p and q, w wide. s.slot with everything given.
- `teardrop(r | d: Length, angle: Angle, flat: bool, center: Vec) → Profile` — A hole that prints sideways without supports: a circle with a 45° point towards +Y (up on a wall); angle: another point (3° to 90° from the vertical), flat: true cuts the point. s.teardrop with everything given.
- `text(text: string, size: Length, font: string) → Profile` — A text outline starting at the origin on the baseline.
- `p.round(r: Length) → Profile` — Rounds every corner, outward and inward, holes too; an error names a corner r is too large for.
- `p.offset(distance: Length) → Profile` — Grows (d > 0) or shrinks the outline; on a plane, the parallel plane.
- `p.across(axis: X | Y) → Profile` — The profile stood up across X or Y, as extrude(along:) stands it (across X: its x along Y, its y up Z), at the origin: move it along the axis and loft through several, or extrude it where it is.
- `s.offset(distance: Length) → Solid` — Grows (d > 0) or shrinks the solid, round where it turns (its walls thickened).
- `p.extrude(height: Length, taper: Angle, symmetric: bool, twist: Angle, along: X | Y, shear: Vec) → Solid` — A solid along +Z from the profile (a negative height: down, towards -Z); taper: 3.deg leans its sides in going away from the profile, whichever way the solid goes (the outline narrows, holes widen; a negative taper widens); twist: 90.deg turns it around Z as it rises, evenly; shear: vec(dx, dy) moves its top that much sideways (in the profile's own x and y) from its bottom, the sides leaning straight: an oblique prism (a blade's bevel, a leaning slot). along: X stands the profile up across X (its x along Y, its y up Z) and pushes it towards +X, along: Y (its x along X) towards +Y; a negative height towards -X or -Y. A profile lying in another plane (a section, one turned or drawn on a face) is extruded across its own plane, from where it is.
- `p.revolve(axis: Axis, angle: Angle) → Solid` — Turns the profile around an axis in its plane, on one side of it (touching it at most), by an angle up to 360°; without one, x is the radius and y the height along Z.
- `p.sweep(path: Path, frenet: bool, twist: Angle | (t) => Angle, up: Direction, guide: Path) → Solid` — Moves the profile along a path, across it (a curve, a Path on XY, instead: a Surface); how it turns about the path: as little as it can, or one of frenet: true (with the curvature: helices), twist: 360.deg (once, evenly; t => angle: by that much at t, 0 at the start to 1 at the end), up: Z (its +Y towards that way all along; an error where the path runs that way), guide: rail (its +Y towards the point as far along that path).
- `loft(profiles: Profile[], ruled: bool, inside: Vec3[][]) → Solid` — A solid through profiles placed in space; through paths (Path[]), a Surface; or through rings of points (Vec3[][], the same count each): one smooth surface closed round them, much faster for many rings; inside: rings for an inner wall, hollow with a floor, open between the last rings (which lie in one plane).
- `hull(shapes…) → Solid` — The smallest convex shape around solids and profiles: hull(a, b) or hull([a, b]); profiles in one plane give a profile.
- `minkowski(a, b) → Solid` — a moved by every point of b: minkowski(box(…), sphere(2.mm)) rounds the box; one of the two must be convex.
- `s.cut(profile: Profile | Solid, on: Frame | Faces | Plane, at: Vec3, depth: Length, through: bool, taper: Angle) → Solid` — Digs a profile into a face: body.cut(p, on: frame, depth: 2.mm).
- `s.thread(face: Faces, size: string, pitch: Length, length: Length, turns: number, starts: int, left: bool, clearance: Length, chamfer: bool, flip: bool, taper: Angle) → Solid` — A thread on a cylindrical face, outside a shaft or inside a hole (made at the tap drill size): "M8", "M8x1", "1/4-20 UNC", "#10-32 UNF", "Tr12x3", "G1/2", tapered "R1/2" and "1/2 NPT"; taper: 1.79.deg makes any thread conical (each side's lean, narrowing to the free end).
- `s.extrude(faces: Selector, depth: Length, along: Vec3) → Solid` — Pulls flat faces of the solid outwards: body.extrude(faces.top, depth: 5.mm); along: slants the sweep; body.cut(faces.top, depth: 2.mm) pushes them in.

## Paths, sweeps and lofts

- `path(points: Vec[], closed: bool, bend: Length) → Path` — Straight segments through the points; bend: every corner rounded by an arc of that radius (a bent tube or wire). body.path(edges): edges of a solid joined end to end. path(a, b): the curve in space that looks like path a seen across a's plane and like b across b's (a handle drawn from above and from the front).
- `spline(points: Vec[], closed: bool) → Path` — A smooth curve through the points.
- `isoThread(d: Length, pitch: Length, length: Length, chamfer: Length) → Solid` — A right-handed ISO metric thread (basic profile) standing on z = 0, its ends chamfered by chamfer: (0, square), built exactly from its helices: what the threads library's threadedRod and tappedHole are made of (use those).
- `helix(r: Length, d: Length, pitch: Length, height: Length, left: bool) → Path` — A helix around +Z.

## Planes, axes and frames

- `plane(origin: Vec, normal: Direction) → Plane` — plane(origin:, normal:), plane(p1, p2, p3), body.plane(faces.top), or body.plane(faces.top, faces.bottom) halfway between two parallel faces.
- `axis(origin: Vec, direction: Direction) → Axis` — axis(origin:, direction:), axis(p1, p2), or body.axis(edges…).
- `s.frame(face: Faces, origin: Vec, x: Direction) → Frame` — A frame on a face: origin at its centre, Z outwards.
- `f.at(x: Length, y: Length, z: Length) → Frame` — The frame with its origin moved, in local coordinates.
- `f.turn(angle: Angle) → Frame` — The frame turned around its Z.
- `pl.flip() → Plane` — The plane with its normal reversed.

## Measuring

- `s.bbox → BBox` — The bounding box: min, max, size, center.
- `s.volume → Volume` — The volume.
- `s.centroid → Vec3` — The centre of mass (of a uniform solid).
- `s.section(plane: Plane) → Profile` — The cut of the solid by a plane: a profile in that plane.
- `s.projection(plane: Plane) → Profile` — The solid's shadow on a plane, cast along its normal: a profile lying in it. Without a plane, seen from above onto XY.
- `s.features → string` — What the solid is made of, one surface a line: flat faces, holes and shafts (with the ISO size they match), cones, spheres, roundings, chamfers (with their size), surfaces turned round an axis, patterns of holes; to remodel a loaded mesh: writeln(load("x.stl").features).
- `s.aligned → Solid` — The solid lying on its largest flat face, its longest extent along X, centred in X and Y on z = 0: a mesh found tilted, set straight to remodel it.
- `s.deviation(other: Solid) → Length` — How far apart the two surfaces are at most, both ways: to check a remodelled part against the mesh it copies, assert(clone.deviation(original) < 0.1.mm).
- `s.overhangs(angle: Angle) → Area` — The area facing down more steeply than the angle from a wall (45° by default), off the bed: what needs supports.
- `s.thinWalls(min: Length) → Area` — The surface over walls thinner than min (0.8 mm by default): 0 when every wall prints.
- `s.mass(density: number) → number` — Grams, for a density in g/cm³: PLA 1.24, PETG 1.27, ABS 1.04, aluminium 2.70, steel 7.85.
- `s.inertia(density: number) → Vec3` — The principal moments of inertia about the centre of mass, ascending, in g·mm².
- `s.area → Area` — The surface area (of a profile: its area).
- `s.isEmpty → bool` — Whether nothing is left.
- `s.isValid → bool` — Whether the solid is a valid closed solid.
- `s.contains(point: Vec) → bool` — Whether a point lies inside the solid (on its surface: no); of a profile, inside its area, the point taken onto its plane.
- `s.pieces → Solid[]` — The separate bodies, ordered along X, then Y, then Z; of a profile, its separate regions, each with its holes.
- `p.outer → Profile` — The outline without its holes (of each region, joined).
- `p.holes → Profile[]` — Each hole of the profile, filled: a profile of its own.
- `x.frames(n: int) → Frame[]` — n frames evenly along a path, Z along it, turning as little as they can (a profile placed on them does not twist): place rings on them and loft.
- `p.outline(n: int, round: Length) → OutlinePoint[]` — n points evenly round a profile's outline, counter-clockwise: .at, .normal (outward, turning round corners as on a fillet `round` big), .around (0…1).
- `xs.above(plane: Plane) → Solid[]` — Of a list of solids, those on the normal's side (by centre of mass): s.pieces.above(p).
- `s.push(from: Vec3 | Plane | Axis | Surface, by: Length) → Solid` — Moved away from a point, a plane or an axis, along the line from it to the centre of mass; from a surface, across it where it is nearest, to the side the solid lies on; on a list of solids each goes its own way (an exploded view).
- `s.pull(to: Vec3 | Plane | Axis, by: Length) → Solid` — Moved towards a point, a plane or an axis: the opposite of push.
- `xs.below(plane: Plane) → Solid[]` — Of a list of solids, those on the other side of the plane.
- `xs.crossing(plane: Plane) → Solid[]` — Of a list of solids, those the plane cuts through.
- `xs.nearest(point: Vec3) → Solid` — Of a list of solids, the one closest to a point.
- `xs.largest → Solid` — Of a list of solids, the biggest by volume (smallest: the least).
- `xs.smallest → Solid` — Of a list of solids, the least by volume.
- `xs.top → Solid` — Of a list of solids, the highest (bottom, left, right, front, back alike).
- `s.halves(…).above → Solid` — The side of the cut the normal points to.
- `s.halves(…).below → Solid` — The other side of the cut.
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
- `faces.farthest(dir: Direction) → Faces` — The face whose centre lies farthest that way, whichever way it faces: faces.farthest(Z), a tilted top.
- `faces.overhanging(angle: Angle) → Faces` — The faces (or parts of them) facing down more steeply than the angle from a wall (45° by default), off the bed: where a printer needs supports.
- `faces.from(tool: Solid) → Faces` — The faces created by a tool or feature: faces.from(holes).
- `edges.parallel(axis: Direction) → Edges` — The straight edges along an axis: edges.parallel(Z).
- `edges.perpendicular(axis: Direction) → Edges` — The edges at right angles to an axis.
- `edges.lines → Edges` — The straight edges.
- `edges.circles → Edges` — The circular edges.
- `edges.of(faces: Faces) → Edges` — The edges around faces: edges.of(faces.top).
- `edges.between(a: Faces, b: Faces) → Edges` — The edges between two sets of faces.
- `edges.loop(faces: Faces) → Edges` — The edges of the outer loop of each face, not those round its holes.
- `edges.chain(edges: Edges, angle: Angle) → Edges` — Those edges and every edge running on from them without a corner (tangent where they meet, within angle: 2° unless given): a curved outline made of many pieces, taken whole.
- `e.start → Vec` — Start point.
- `e.end → Vec` — End point.
- `e.mid → Vec` — Middle point.
- `e.isLine → bool` — Whether it is straight.
- `e.isCircle → bool` — Whether it is a circle or an arc.
- `e.radius → Length` — The radius of a circular edge.
- `e.isParallel(axis: Direction) → bool` — Whether it runs along the axis (a face: whether it lies along it, its normal at right angles: the side walls for Z).
- `e.isPerpendicular(axis: Direction) → bool` — Whether it is at right angles to the axis (a face: whether its normal runs along it: top and bottom for Z).

## Sketches

- `sketch(on: Frame | Plane, origin: Vec, x: Direction) → Sketch` — A constrained 2D sketch: add points, lines, constraints, then take .profile. On XY, or on a face of a solid (its edges as references, its axes as frame's) or a frame or plane: the profile then lies there.
- `sk.edges → Entity[]` — A sketch on a face: the face's edges as references (fixed construction lines, arcs, circles), each loop from its lowest edge counter-clockwise, as a rect's sides: bottom, right, top, left; the outside first.
- `sk.origin → Point` — A sketch on a face or plane: its origin (the face's centre) as a fixed reference point.
- `sk.project(edges: Edges) → Entity[]` — Edges of the solid the sketch is on, flattened onto its plane as references: a circle seen aslant is an ellipse, other curves lines along them.
- `sk.point(x: Length, y: Length, fixed: bool, construction: bool) → Point` — A point where it starts; constraints move it.
- `sk.line(p: Point | Vec2, q: Point | Vec2, construction: bool) → Line` — A line between two points (a vector makes a new point); construction: true (on every geometry call and shape) makes a guide to constrain to, drawn dashed, never part of the profile.
- `sk.arc(center: Point | Vec2, start: Point | Vec2, end: Point | Vec2, construction: bool) → Arc` — An arc, counter-clockwise (a vector makes a new point).
- `sk.polyline(points, closed: bool, construction: bool) → Line[]` — Lines through points (vectors become new points).
- `sk.spline(points, closed: bool) → SketchSpline` — A smooth curve through points (vectors become new points): open, its ends join lines and arcs as theirs do; closed: true, a loop of its own. Its points move it: constrain them.
- `sk.circle(center: Point, r: Length, d: Length) → Circle` — A circle round a point (a new one at the origin without it); without r/d the radius is left to the constraints. The same shape as the profile circle(…).
- `sk.ellipse(center: Point, rx: Length, ry: Length, angle: Angle) → Ellipse` — An ellipse: rx along its own x axis, angle from X, ry across; what is not given is left to the constraints. The same shape as the profile ellipse(…).
- `sk.rect(p: Point, q: Point, center: Point, w: Length, h: Length, angle: Angle | "free", corner: Length) → Line[]` — A rectangle: its 4 lines (bottom, right, top, left), horizontal and vertical; angle: turns it (its first side from X), "free" leaves the turn to the constraints; corner: rounds them. The same shape as the profile rect(…).
- `sk.polygon(center: Point, n: int, r: Length, d: Length, fit: string, angle: Angle) → Line[]` — A regular polygon: its n lines, corners on a construction circle of the size given; fit: "sides" makes its sides touch it instead; angle: the direction of the first corner, else the turn is left free (starting with the first side at the bottom, horizontal). s.polygon([p1, p2, p3]): the closed polyline through the points. The same shapes as the profile polygon(…).
- `sk.slot(p: Point, q: Point, w: Length, length: Length, center: Point, angle: Angle) → [Line, Arc, Line, Arc]` — Two half circles round p and q joined by tangent lines: [line, arc round q, line, arc round p]; or by its length end to end, along X (angle: turned) round center: or a new point at the origin. The same shape as the profile slot(…).
- `sk.teardrop(center: Point, r | d: Length, angle: Angle, flat: bool) → [Arc, Line, Line]` — A hole that prints sideways: an arc round the centre and two lines tangent to it meeting above it, angle (45° unless given) from the vertical; flat: true cuts the point with a line on the circle's top ([arc, line, flat, line]). The same shape as the profile teardrop(…).
- `sk.fill(at: Point | Vec, full: bool)` — The area of the profile holding `at` full (or full: false, empty), whatever the loops round it say: by default an area is full inside an odd number of loops (a loop in a loop is a hole; where two loops overlap, so is the overlap). A point of the sketch keeps it in its area as the constraints move it; the last fill in an area counts.
- `sk.coincident(p: Point, q: Point)` — Two points in the same place.
- `sk.length(line: Line, v: Length)` — Sets the length of a line.
- `sk.distance(a: Point, b: Point | Line, v: Length, along: X | Y)` — Sets how far a point is from another point (along: X or Y only across or up), or from a line.
- `sk.parallel(a: Line, b: Line)` — Two parallel lines.
- `sk.perpendicular(a: Line, b: Line)` — Two lines at right angles.
- `sk.fillet(p: Point, r: Length)` — Rounds the corner where two lines meet at p.
- `sk.fix(p: Point)` — Pins a point.
- `sk.horizontal(line: Line)` — A horizontal line (or two points at the same height, or an ellipse's x axis along X).
- `sk.vertical(line: Line)` — A vertical line.
- `sk.equal(a, b)` — Equal lengths or radii; s.equal(e): an ellipse as wide as tall.
- `sk.on(p: Point, curve)` — A point on a line, circle, arc or ellipse; a shape's lines (s.rect, s.polygon, s.polyline) on a circle or ellipse: every corner on it, the shape inscribed.
- `sk.concentric(a, b)` — Circles, arcs or ellipses (or a point) round the same centre.
- `sk.tangent(a, b)` — Tangent line and circle, arc or ellipse, or two circles; a shape's lines and a circle or ellipse: every side touching it, the shape round it.
- `sk.midpoint(p: Point, line: Line)` — A point in the middle of a line.
- `sk.symmetric(p: Point, q: Point, line: Line)` — Two points symmetric about a line.
- `sk.radius(c: Circle, v: Length, rx: Length, ry: Length)` — Sets a radius (an ellipse's: rx, ry).
- `sk.diameter(c: Circle, v: Length)` — Sets a diameter.
- `sk.angle(a: Line, b: Line, v: Angle)` — The angle between two lines, or of one line or an ellipse from X.
- `sk.profile → Profile` — Solves the sketch and gives its outline: its closed loops; what is drawn open (a free end) stays out, with a warning.
- `sk.path → Path` — Solves the sketch and gives what it draws (lines, arcs, curves, circles, not construction) as one path, where the sketch lies: open or closed, to sweep along; an error if it draws several separate chains.
- `sk.paths → Path[]` — Every separate chain the sketch draws, as paths, in the order they are drawn.
- `sk.dof → int` — Degrees of freedom left.
- `sk.solved → bool` — Whether the constraints are satisfied.
- `pt.x → Length` — Where the point is across, solved (y: up).
- `pt.y → Length` — Where the point is up, solved.
- `pt.pos → Vec` — Where the point is, solved: vec(x, y).
- `line.start → SketchPoint` — Its first point (end: the other one); an arc's and a spline's too.
- `line.end → SketchPoint` — Its last point; an arc's and a spline's too (a closed spline's: its first).
- `line.length → Length` — How long it is, solved.
- `line.mid → Vec` — Its middle, solved.
- `circ.center → SketchPoint` — The centre of a circle, an arc or an ellipse.
- `circ.radius → Length` — The radius of a circle or an arc, solved.
- `ell.rx → Length` — The radius along the ellipse's own x axis, solved.
- `ell.ry → Length` — The radius across, solved.
- `ell.angle → Angle` — How far the ellipse's x axis is turned from X, solved.
- `x.points → SketchPoint[]` — The points the spline goes through, in order.
- `x.closed → bool` — Whether it goes round back to its first point.
- `x.length → Length` — How long it is along the curve, solved.

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
- `XY: Plane` — The XY plane, its normal +Z (up): a sketch on it reads as the Top view shows it.
- `XZ: Plane` — The XZ plane, its normal -Y (towards the front): a sketch on it reads as the Front view shows it.
- `YZ: Plane` — The YZ plane, its normal +X (to the right): a sketch on it reads as the Right view shows it.
- `World: Frame` — The global frame.
- `PI: number` — π.
- `E: number` — e, the base of the natural logarithm.
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
- `@parts(color, alpha: 0..1, export: bool, name: string, varied: bool)` — A part per separate body of the Solid returned (or per element of a Solid[]), named clip1, clip2…; varied: true, each in its own colour.
- `@param(description, min:, max:, step:, choices:)` — A parameter with a field in the panel.
- `@preset(name, value)` — The parameter's value in a named preset.
- `@drawing` — A function returning a technical drawing.
- `@assembly` — A function returning an assembly.
- `@unit(unit)` — The default unit of bare numbers: @unit(inch) module m;

## Library: import hardware;

- `struct Screw(name: string, d: Length, pitch: Length, tap: Length, clearance: Length, head: Length, headHeight: Length, key: Length, nut: Length, nutHeight: Length, washer: Length, insert: Length, insertDepth: Length)` — Metric screw sizes (ISO 4762 socket head cap screws, ISO 4032 nuts, ISO 7089 washers) with the holes to print or drill for them.
- `struct Head(d: Length, h: Length, key: Length)` — The head of another kind for screw s: its diameter (across the flats for "hex"), its height and the hex key. "button" ISO 7380, "flat" ISO 10642 (countersunk, 90°), "hex" ISO 4017 (spanner across the flats), "pan" ISO 7049 (self-tapping); "socket" the ISO 4762 of the size itself.
- `headOf(s: Screw, head: string) → Head`
- `hexPrism(acrossFlats: Length, h: Length) → Solid` — Hexagonal prism standing on XY, flats parallel to the X axis.
- `screw(s: Screw, length: Length, socket: bool = true, threaded: bool = false, head: string = "socket") → Solid` — A screw: head "socket" (ISO 4762, the default), "button" (ISO 7380), "flat" (ISO 10642, countersunk), "hex" (ISO 4017) or "pan" (the self-tapping ST sizes). The underside of the head lies on z = 0 (for a flat head, its top: it sinks into its countersink): the head grows upwards and the shank downwards, so the screw drops into a hole. threaded: true models the ISO thread (slower); otherwise the shank is plain; socket: false leaves out the hex socket.
- `nut(s: Screw, threaded: bool = false) → Solid` — Hex nut standing on z = 0, with the corners chamfered on both faces. threaded: true cuts the ISO thread in the hole.
- `washer(s: Screw) → Solid` — Flat washer standing on z = 0.
- `hole(s: Screw, depth: Length, kind: string = "clearance", head: string = "socket") → Solid` — A hole to subtract, with its top on z = 0 going down `depth`: "clearance" (the screw passes), "tap" (pilot hole for the thread), "insert" (heat-set insert), "counterbore" (clearance with room for the head) or "countersink" (for flat heads).
- `nutTrap(s: Screw, depth: Length, clearance: Length = …) → Solid` — A pocket to trap a nut, from z = 0 going down `depth` (with a little clearance).
- `squareNutSize(s: Screw) → Length` — Square nuts (DIN 562, thin): across the flats and height. They slide into a slot from the side, where a hex nut needs a pocket from above.
- `squareNutHeight(s: Screw) → Length`
- `squareNut(s: Screw) → Solid` — A square nut standing on z = 0, centred, its hole plain.
- `squareNutSlot(s: Screw, reach: Length, clearance: Length = …) → Solid` — The slot a square nut slides into, to subtract: centred on the screw's axis at the origin, its middle on z = 0, open towards +X for `reach` (out through the part's side), `clearance` larger all round.
- `struct Extrusion(size: Length, slot: Length, lip: Length, cavity: Length, depth: Length, bore: Length, screw: Screw)` — Aluminium extrusions, B-type slot (the common 20 and 30 series: 2020, 3030, Misumi HFS5 and HFS6 and their copies): `series` 20 or 30. The sizes are typical ones: check your supplier's drawing for tight fits.
- `extrusionSeries(series: int) → Extrusion`
- `extrusion(series: int, length: Length) → Solid` — A length of extrusion standing on z = 0 along Z, centred in X and Y: a reference part to build onto (a bracket, a printed T-nut, a clamp).
- `tNut(series: int, length: Length = …, clearance: Length = …) → Solid` — A T-nut that slides into the slot of an extrusion (`series` 20 or 30), as it sits in a slot facing +Z with the extrusion's face on z = 0: its neck in the opening, its body under the lips, `length` long along X, a hole for the series' screw through it (a tap hole: printed, the screw cuts its thread; the metal ones are the same shape).
- `slotKey(series: int, length: Length, clearance: Length = …) → Solid` — A key along the bottom of a printed part, to sit in an extrusion's slot and keep the part square to it: `length` long along X, standing down from z = 0 into the slot.
- `M2, M2_5, M3, M4, M5, M6, M8, M10, M12, UNC4_40, UNC6_32, UNC8_32, UNC10_24, UNC1_4_20, ST2_2, ST2_9, ST3_5, ST4_2: Screw`

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
- `spurGear(m: Length, teeth: int, thickness: Length, bore: Length = …, pressure: Angle = …, backlash: Length = …, steps: int = 6) → Solid` — A spur gear standing on z = 0, with an optional bore; `steps` points on each flank (more: smoother teeth, slower).
- `rack(m: Length, teeth: int, thickness: Length, base: Length = …, pressure: Angle = …, backlash: Length = …) → Solid` — A straight rack along +X starting at x = 0, teeth up, pitch line at y = 0; backlash thins the teeth on the pitch line, as on a gear.

## Library: import hinges;

- `struct Hinge(fixed: Solid, moving: Solid)` — The two leaves of a hinge, printed in place: they come out of the printer already joined and turn around the X axis.
- `hinge(length: Length = …, width: Length = …, thickness: Length = …, knuckles: int = 5, clearance: Length = …) → Hinge` — A print-in-place hinge along X, centred on the origin, leaves lying flat on z = 0 and the axis at z = thickness. `knuckles` alternate between the leaves (odd numbers keep it symmetric).

## Library: import snaps;

- `snapHook(length: Length = …, thickness: Length = …, width: Length = …, overhang: Length = …, lead: Angle = …) → Solid` — A hook: a flexible beam `length` long with a barb `overhang` deep at the top. `lead` is the slope that pushes it aside when inserting.
- `snapSlot(thickness: Length = …, width: Length = …, overhang: Length = …, wall: Length = …, clearance: Length = …) → Solid` — The slot a hook clicks into, to subtract from the mating wall: a window round the beam, `clearance` larger, with room on the -X side for the beam to bend aside while the barb goes through; then the barb rests on the wall beyond the window's +X edge.

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
- Cut with a plane and keep one side: `s.halves(XY.offset(10.mm)).below`
- Cut with a plane into pieces: `s.split(XY.offset(10.mm))`
- A reference part, shown but not exported: `@part("slategray", alpha: 0.35, export: false)`
- A parameter in the side panel: `@param("Width", min: 10.mm, max: 100.mm) immutable width = 40.mm;`
- Check a requirement: `unittest { assert(body.bbox.size.z <= 40.mm, "too tall"); }`
- Measure: `writeln(s.volume, " ", s.bbox.size)`

## Keys and mouse (on macOS, Cmd for Ctrl)

- **Right drag, or Shift + left drag** — turns the view
- **Middle drag, or Ctrl + left or right drag** — moves the view
- **Left drag** — a box: what is wholly inside it joins what is picked (dragged right to left: what it touches too); in a sketch, its points and lines
- **Wheel** — zooms, towards the pointer
- **F6** — frames the whole model (Fit)
- **Click** — adds what is under the pointer to what is picked (again: takes it away); on nothing, Esc or Space: none
- **Right-click** — what can be done there: fillets, holes, Move…, Colour, Sketch on face…
- **Double click on a flat face** — the view straight at that face
- **Alt+1 … Alt+4** — a click picks whole parts, faces, edges or vertices
- **A** — annotates the view: arrows, crosses, circles, text; Done or Esc goes back
- **Esc** — closes what is shown over the model: a sketch, a step, Inspect, the marks
- **Drag, in a sketch** — from a point, line or circle: moves it, its constraints kept; from nothing: a box
- **X, in a sketch** — what is selected to construction geometry (dashed guides) or back; nothing selected: what you draw next
- **Ctrl+N, Ctrl+O, Ctrl+S, Ctrl+E** — new, open, save, export
- **Ctrl+J, F7, F8, F9** — show or hide the console, the code, the view, the parameters
- **Ctrl+I, or Ctrl+click on a line** — shows what the line makes, in the view
- **F5** — runs the model's unittest checks
- **F1** — this cheatsheet
- **Ctrl+F, F3, Shift+F3** — finds in the code, next, previous
- **Ctrl+H** — replaces
- **Ctrl+L** — goes to a line
- **Ctrl+/** — comments the lines out, or back in
- **Ctrl+D** — duplicates the line or the selection
- **Ctrl+Shift+K** — deletes the lines
- **Alt+Up, Alt+Down** — moves the lines up or down
- **Tab, Shift+Tab** — indents the lines in or out
- **Ctrl+Z, Ctrl+Shift+Z** — undoes, redoes (the changes the mouse wrote too)
- **Ctrl+Q** — quits
