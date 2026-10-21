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
- `noise(x: number, y: number, z: number, seed: int, kind: string, octaves: int) → double` — Smooth noise, about -1…1, features about one unit across; lengths count in mm. kind: "cells" (0 at each cell's point, about 1 farthest), "edges" (0 on the borders between cells: a Voronoi relief), "ridged" (1 on sharp ridges), each 0…1; octaves: up to 8 layers, each twice as fine and half as strong.
- `loopNoise(around: number, along: number, bumps: number, seed: int, kind: string, octaves: int) → double` — Noise round a loop: around 0…1, along across it, about bumps features round; no seam where it closes. kind: and octaves: as noise.
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
- `xs.sum()` — The sum; of solids, their union (of an empty Solid[], an empty solid).
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
- `load(path: string, scale: number, repair: bool) → Solid` — A part from an STL, OBJ, PLY, 3MF, glTF (.glb, .gltf: metres to mm, Y up turned to Z up) or STEP file in the project; repair: true mends a mesh that is not quite a solid (a scan's: doubled walls of no thickness taken out, where the surface touches itself the sheets parted; holes stay); from an SVG or DXF drawing, its closed outlines as a profile on XY (mm), whole circles and ellipses as true curves.

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

- `s.nextTo(other: Solid, dir: Direction, gap: Length) → Solid` — Beside another solid: a.nextTo(b, X, gap: 10.mm), its box just past b's that way (only its x changes); an oblique direction (vec(1, 2, 0)) puts its centre on the line from b's centre that way, the boxes touching, gap further along it.
- `s.on(other: Solid, gap: Length) → Solid` — On top of another solid.
- `s.align(other: Solid, x: string, y: string, z: string) → Solid` — Aligns bounding boxes per axis: "min", "center" or "max".
- `s.linearPattern(n: int, step: Vec) → Solid` — n copies, step apart, as one solid (its tagged references: the first copy's).
- `s.circularPattern(n: int, axis: Axis, angle: Angle) → Solid` — n copies around an axis, as one solid (its tagged references: the first copy's).
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
- `polygon(points: Vec[], smooth: bool, n: int, r | d: Length, fit: string, angle: Angle, center: Vec) → Profile` — A polygon through the points (smooth: true, a smooth closed curve through them instead, the same as a sketch's closed spline: whichever point it starts at); or a regular one of n sides, centred on the origin or round a point: d/r the circle through its corners, or with fit: "sides" the circle its sides touch; angle: the direction of its first corner, else its first side lies at the bottom, horizontal. s.polygon with everything given.
- `slot(length: Length, w: Length, p: Vec, q: Vec, center: Vec, angle: Angle) → Profile` — A stadium: length end to end along X, centred on the origin (or center:, angle: turned); or round two centres p and q, w wide. s.slot with everything given.
- `teardrop(r | d: Length, angle: Angle, flat: bool, center: Vec) → Profile` — A hole that prints sideways without supports: a circle with a 45° point towards +Y (up on a wall); angle: another point (3° to 90° from the vertical), flat: true cuts the point. s.teardrop with everything given.
- `s.knurl(face: Faces, kind: string, pitch: Length, depth: Length, angle: Angle, margin: Length) → Solid` — A grip raised depth (0.5 mm) on a face of any shape (a knob's side, a handle, a flat pad, a lofted grip), laid on it as wrap: does: kind "diamond" (the default), "straight" ridges along the face, or "diagonal" ones leaning at angle (30°, also the diamonds' slant); pitch (1.6 mm), round a face that closes on itself (a cylinder, a loft through rings) adjusted so a whole number go round and the pattern closes; margin (0.5 mm) left plain along the face's edges. Put it last: a boolean after it meets every cell.
- `p.tiles(kind: string, size: Length, gap: Length, round: Length, angle: Angle, tile: Profile | Profile[], step: Vec[2], origin: Vec, whole: bool, scale: number | (Vec2 centre) => number, keep: (Vec2 centre) => bool, seed: int, jitter: number, relax: int, points: Vec[]) → Profile` — The region filled with cells, gap apart (each shrunk by gap/2), cut at its border (whole: true keeps only the cells wholly inside): subtract it for a grille, cut or extrude it on a face for a pattern of pockets or reliefs (taper: slants their sides). kind: "square", "hex", "triangle", "brick", "octagon" (with small squares), "diamond", size the distance between neighbouring cells' centres; "voronoi", cells round points about size apart, jitter: 0 (hexagons) to 1 (the default), relax: smoothing passes for evener cells, seed:, or points: your own. Or your own tile: one profile or several (a sketch's), repeated by step: [a, b]; the copies must not overlap, an error says which do. round: rounds each cell, angle: turns the tiling, origin: where a cell sits (the region's centre); scale: a factor for each cell, keep: which cells stay, both functions of its centre. With no gap (the default) the cells touch: they are joined into one area. A region drawn on a face or lying in another plane (a section) is tiled there, in that plane's coordinates, and its tiles stay there.
- `text(text: string, size: Length, font: string, weight: string | int, bold: bool, italic: bool, spacing: Length, lineSpacing: number) → Profile` — A text outline starting at the origin on the baseline (lines below one another, the last on it); font: an installed font's name, "Sans", "Serif", "Monospace" or a family (a warning, naming similar ones, when it is not installed and another is used), a style at its end counting ("Sans Bold Italic"), or a font file's path; weight: "thin", "extralight", "light", "regular", "medium", "semibold", "bold", "extrabold", "black" or 100 … 900 (one the font has not installed: the nearest, with a warning), bold: true for "bold", italic: true; spacing: 1.mm sets the letters that much further apart (negative: closer), lineSpacing: 1.5 the lines 1.5 times as far as the font has them. A narrower or wider font is a family of its own: "DejaVu Sans Condensed".
- `p.round(r: Length) → Profile` — Rounds every corner, outward and inward, holes too; an error names a corner r is too large for.
- `p.offset(distance: Length) → Profile` — Grows (d > 0) or shrinks the outline (shrunk to nothing: an empty profile, isEmpty); on a plane, the parallel plane.
- `p.spots(n: int, margin: Length) → Vec3[]` — Up to n points inside the profile (in any plane), at least margin from its edges, as far apart as they can be: where to put keys, pins or feet; one point: the middle; none when nothing is that far from the edges.
- `p.across(axis: X | Y) → Profile` — The profile stood up across X or Y, as extrude(along:) stands it (across X: its x along Y, its y up Z), at the origin: move it along the axis and loft through several, or extrude it where it is.
- `s.offset(distance: Length, sharp: bool) → Solid` — Grows (d > 0) or shrinks the solid, round where it turns (its walls thickened); sharp: true its faces moved and extended until they meet, edges staying sharp. Holes it grows over close up (filled).
- `p.extrude(height: Length, taper: Angle, symmetric: bool, twist: Angle, along: X | Y, shear: Vec) → Solid` — A solid along +Z from the profile (a negative height: down, towards -Z; not zero); taper: 3.deg leans its sides in going away from the profile, whichever way the solid goes (the outline narrows, holes widen; a negative taper widens); twist: 90.deg turns it around Z as it rises, evenly; shear: vec(dx, dy) moves its top that much sideways (in the profile's own x and y) from its bottom, the sides leaning straight: an oblique prism (a blade's bevel, a leaning slot). symmetric: true puts half the height each side of the profile, which is then the middle of the solid (a taper narrows both ways from it, a twist turns half each way). along: X stands the profile up across X (its x along Y, its y up Z) and pushes it towards +X, along: Y (its x along X) towards +Y; a negative height towards -X or -Y. A profile lying in another plane (a section, one turned or drawn on a face) is extruded across its own plane, from where it is.
- `p.revolve(axis: Axis, angle: Angle) → Solid` — Turns the profile around an axis in its plane, on one side of it (touching it at most), by an angle up to 360°; without one, x is the radius and y the height along Z. A profile drawn on a face or plane, or lying in one (a section), turns where it lies: its axis a world one (X, Y, Z through the plane's origin, or an Axis anywhere), as everything else in that plane; without one, round its own y axis (one drawn on XZ: round Z), stood up when its y is not upright.
- `p.sweep(path: Path, frenet: bool, twist: Angle | (t) => Angle, up: Direction, guide: Path) → Solid` — Moves the profile along a path, across it (a curve, a Path on XY, instead: a Surface); how it turns about the path: as little as it can, or one of frenet: true (with the curvature: helices), twist: 360.deg (once, evenly; t => angle: by that much at t, 0 at the start to 1 at the end), up: Z (its +Y towards that way all along; an error where the path runs that way), guide: rail (its +Y towards the point as far along that path).
- `loft(profiles: Profile[], ruled: bool, inside: Vec3[][]) → Solid` — A solid through profiles placed in space; through paths (Path[]), a Surface; or through rings of points (Vec3[][], the same count each): one smooth surface closed round them, much faster for many rings; inside: rings for an inner wall, hollow with a floor, open between the last rings (which lie in one plane).
- `hull(shapes…) → Solid` — The smallest convex shape around solids and profiles: hull(a, b) or hull([a, b]); profiles in one plane give a profile, lying there (one of no place taken into it); in different planes, a solid. Their flat faces it lies on keep their tags. grow: 2.mm makes it that much bigger all round, rounded (2% farther at most, never nearer): quicker and surer than an offset of a hull.
- `minkowski(a, b) → Solid` — a moved by every point of b: minkowski(box(…), sphere(2.mm)) rounds the box; one of the two must be convex. Their flat faces, moved out, keep their tags; a's own tags and references stay.
- `s.cut(profile: Profile | Solid, on: Frame | Faces | Plane, at: Vec3, depth: Length, through: bool, taper: Angle, wrap: Faces, project: Faces, along: Vec3) → Solid` — Digs a profile into a face: body.cut(p, on: frame, depth: 2.mm); body.extrude(p, on: …, depth:) raises it the same way. On a curved face (one face of any shape): wrap: rolls the profile onto it like a label, its lengths kept along the face (exact on cylinders, cones and extrusions, a little stretched on a sphere), its x across the face (round a cylinder) and y along it, read from outside; project: carries it onto the face along a direction (along:, else the face's normal), from the plane touching the face, as a light casts it (stretched where the face turns away). The profile's origin goes to the front of the face (the side facing -Y, halfway along), or to at: a point over it; depth goes along the face's normal. depth is always positive: cut digs in, extrude raises (a negative depth is an error: use the other one).
- `s.thread(face: Faces, size: string, pitch: Length, length: Length, turns: number, starts: int, left: bool, clearance: Length, chamfer: bool, flip: bool, taper: Angle) → Solid` — A thread on a cylindrical face, outside a shaft or inside a hole (made at the tap drill size): "M8", "M8x1", "1/4-20 UNC", "#10-32 UNF", "Tr12x3", "G1/2", tapered "R1/2" and "1/2 NPT"; taper: 1.79.deg makes any thread conical (each side's lean, narrowing to the free end).
- `s.extrude(faces: Selector, depth: Length, along: Vec3) → Solid` — Pulls flat faces of the solid outwards: body.extrude(faces.top, depth: 5.mm); along: slants the sweep; body.cut(faces.top, depth: 2.mm) pushes them in.

## Paths, sweeps and lofts

- `path(points: Vec[], closed: bool, bend: Length) → Path` — Straight segments through the points; bend: every corner rounded by an arc of that radius (a bent tube or wire). body.path(edges): edges of a solid joined end to end. path(a, b): the curve in space that looks like path a seen across a's plane and like b across b's (a handle drawn from above and from the front).
- `spline(points: Vec[], closed: bool) → Path` — A smooth curve through the points; closed: true, round through the first again, the same curve whichever point it starts at.
- `isoThread(d: Length, pitch: Length, length: Length, chamfer: Length) → Solid` — A right-handed ISO metric thread (basic profile) standing on z = 0, its ends chamfered by chamfer: (0, square), built exactly from its helices: what the threads library's threadedRod and tappedHole are made of (use those).
- `helix(r: Length, d: Length, pitch: Length, height: Length, left: bool) → Path` — A helix around +Z.

## Planes, axes and frames

- `plane(origin: Vec, normal: Direction) → Plane` — plane(origin:, normal:), plane(p1, p2, p3), body.plane(faces.top), or body.plane(faces.top, faces.bottom) halfway between two parallel faces.
- `axis(origin: Vec, direction: Direction) → Axis` — axis(origin:, direction:), axis(p1, p2), body.axis(edges…) (a straight edge's line, a circle's centre and normal) or body.axis(faces…) (a cylinder's, a cone's or a turned face's axis).
- `s.frame(face: Faces, origin: Vec, x: Direction) → Frame` — A frame on a face: origin at its centre, Z outwards.
- `f.at(x: Length, y: Length, z: Length) → Frame` — The frame with its origin moved, in local coordinates.
- `f.turn(angle: Angle) → Frame` — The frame turned around its Z.
- `pl.flip() → Plane` — The plane with its normal reversed.

## Tags

- `s.addTag(tag: string | string[], recursive: bool) → Solid` — Tags the solid (a profile, a path, a surface) as an object: b.addTag("body"). A tag is a name, not blank and without ';'; one with a dot belongs to the module named before its last dot ("hinges.pin"), given only there. recursive: true tags each of its faces as well, which keep it when the solid is joined to or cut from another. Changes the variable it is called on and gives the solid back, for a chain.
- `s.addTag(tag: string | string[], at: Vec3 | Axis | Plane | Frame) → Solid` — Tags a point, an axis, a plane or a frame on the solid: it moves, turns, mirrors and scales with it, and stays through cuts and joins (a copy joined to itself holds it once). Split (split, halves, pieces), each piece has the references lying in it or on it, one on the cut both, one in none (a hole's axis) the nearest; an intersection drops those in what it cuts away; a pattern keeps its first copy's; minkowski(a, b) a's. Given again, the tag's new reference replaces the old. Read it back with b.point(tag), b.axis(tag), b.plane(tag), b.frame(tag).
- `s.point(tag: string) → Vec3` — Where the reference tagged so is now (a point, or the origin of an axis, plane or frame): b.point("pin").
- `s.axis(tag: string) → Axis` — The axis tagged so (also a plane's normal or a frame's Z through its origin); a circle or arc tagged in the sketch: its centre, across the sketch.
- `s.plane(tag: string) → Plane` — The plane tagged so (also an axis's or a frame's, across it).
- `s.frame(tag: string) → Frame` — The frame tagged so, or one on the point, axis or plane tagged so (its X as plane(…).frame() has it): to place a part there with placeOn.
- `s.removeTag(tag: string | string[], recursive: bool) → Solid` — Takes a tag off the solid (and the references tagged so); recursive: true off its faces too.
- `s.clearTags(recursive: bool) → Solid` — Takes every tag off the solid; recursive: true off its faces too.
- `s.hasTag(tag: string) → bool` — Whether the solid itself is tagged so.
- `s.tags → string[]` — The solid's own tags (not its faces').
- `s.faces → Faces` — The solid's faces, to select some and read or change their tags: b.faces.top.addTag("lid").
- `s.edges → Edges` — The solid's edges, to select some and count or list them.
- `faces.addTag(tag: string | string[]) → Solid` — Tags the faces selected, on the solid they were taken from: b.faces.top.addTag("lid"). The faces made from them later keep the tag: split, trimmed, filleted, moved, merged with another face (which then has both). Changes the variable it is called on and gives the solid back, for a chain.
- `faces.removeTag(tag: string | string[]) → Solid` — Takes a tag off the faces selected: b.faces.top.removeTag("seat").
- `faces.clearTags() → Solid` — Takes every tag off the faces selected.
- `faces.hasTag(tag: string) → bool` — Whether every face selected has that tag.
- `faces.tags → string[]` — The tags of the faces selected, all of them: b.faces.top.tags.
- `faces.tagged(tag: string | string[]) → Faces` — The faces with that tag, or with any of a list: wherever the solid was moved or turned since.
- `faces.count → int` — Taken from a solid (b.faces.top): how many faces are selected. Edges likewise.
- `faces.list → Face[]` — Taken from a solid: the faces selected, as Face values (foreach over b.faces.top does the same). Edges likewise, as Edge values.

## Measuring

- `s.bbox → BBox` — The bounding box: min, max, size, center; of a profile drawn on a face, where it lies.
- `s.volume → Volume` — The volume.
- `x.length → Length` — How long the path is, along it (round a closed one, once).
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
- `s.isEmpty → bool` — Whether nothing is left (a profile less one over all of it is an empty profile).
- `s.isValid → bool` — Whether the solid is a valid closed solid.
- `s.contains(point: Vec) → bool` — Whether a point lies inside the solid (on its surface: no); of a profile, inside its area, the point (a world one, vec(x, y) at z = 0) taken onto the profile's plane.
- `s.pieces → Solid[]` — The separate bodies, ordered along X, then Y, then Z; of a profile, its separate regions, each with its holes.
- `p.outer → Profile` — The outline without its holes (of each region, joined).
- `p.holes → Profile[]` — Each hole of the profile, filled: a profile of its own.
- `x.frames(n: int) → Frame[]` — n frames evenly along a path, Z along it, turning as little as they can (a profile placed on them does not twist): place rings on them and loft. Ends included; on a closed path n frames a length/n apart, the start not repeated.
- `p.outline(n: int, round: Length) → OutlinePoint[]` — n points evenly round a profile's outline, counter-clockwise: .at, .normal (outward, turning round corners as on a fillet `round` big), .around (0…1); of a profile lying in another plane (drawn on a face, a section), .at and .normal are 3D, where it lies.
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

- `faces.top → Faces` — The face(s) facing +Z the most (exactly, the outermost; on a part turned a little, those within half a degree of the most); a curved face by its normal over the whole face (a dome's up; a cylinder's whole side, a sphere none).
- `faces.bottom → Faces` — The face(s) facing -Z.
- `faces.front → Faces` — The face(s) facing -Y.
- `faces.back → Faces` — The face(s) facing +Y.
- `faces.left → Faces` — The face(s) facing -X.
- `faces.right → Faces` — The face(s) facing +X.
- `faces.largest → Faces` — The largest face.
- `faces.normal(dir: Direction) → Faces` — The faces with that normal: faces.normal(X); a curved face by its normal over the whole face (a dome's up, a cylinder's whole side none).
- `faces.farthest(dir: Direction) → Faces` — The face whose centre lies farthest that way, whichever way it faces: faces.farthest(Z), a tilted top.
- `faces.overhanging(angle: Angle) → Faces` — The faces (or parts of them) facing down more steeply than the angle from a wall (45° by default), off the bed: where a printer needs supports.
- `faces.from(tool: Solid | Solid[]) → Faces` — The faces created by a tool or feature: faces.from(holes); a list, those of any of its solids.
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
- `sk.origin → SketchPoint` — A sketch on a face or plane: its origin (the face's centre) as a fixed reference point.
- `sk.project(edges: Edges) → Entity[]` — Edges of the solid the sketch is on, flattened onto its plane as references: a circle seen aslant is an ellipse, other curves lines along them.
- `sk.point(x: Length, y: Length, fixed: bool, construction: bool) → SketchPoint` — A point where it starts; constraints move it.
- `sk.addTag(tag: string | string[]) → Sketch` — Tags the sketch: its profile and paths have the tag. removeTag, clearTags, hasTag and tags as on a solid.
- `x.addTag(tag: string | string[]) → Entity` — Tags a point, line, circle, arc or ellipse of the sketch (construction ones too): the profile and paths made from it, and what is extruded or revolved from them, have a reference so tagged, a point where the point is, an axis through a circle's centre across the sketch or along a line; it follows them wherever they are moved. A line, circle or arc also tags the face extruded or revolved from it (a side, a hole's wall): extruded straight, tapered, sheared, twisted or symmetric, or revolved, the profile moved, turned, scaled or mirrored first, offset (the parallel side), rounded, cut into pieces, or joined with, less or intersected with another profile (the edges left on it). A hull of the profile, a sweep or a loft loses the faces' names (not the points'): looking for one then says so. Gives the entity back: s.circle(c, d: 6.mm).addTag("bore"). removeTag, clearTags, hasTag and tags as on a solid.
- `sk.line(p: SketchPoint | Vec2, q: SketchPoint | Vec2, construction: bool) → SketchLine` — A line between two points (a vector makes a new point); construction: true (on every geometry call and shape) makes a guide to constrain to, drawn dashed, never part of the profile.
- `sk.arc(center: SketchPoint | Vec2, start: SketchPoint | Vec2, end: SketchPoint | Vec2, construction: bool) → SketchArc` — An arc, counter-clockwise (a vector makes a new point).
- `sk.polyline(points, closed: bool, construction: bool) → SketchLine[]` — Lines through points (vectors become new points).
- `sk.spline(points, closed: bool) → SketchSpline` — A smooth curve through points (vectors become new points): open, its ends join lines and arcs as theirs do; closed: true, a loop of its own. Its points move it: constrain them.
- `sk.circle(center: SketchPoint, r: Length, d: Length) → SketchCircle` — A circle round a point (a new one at the origin without it); without r/d the radius is left to the constraints. The same shape as the profile circle(…).
- `sk.ellipse(center: SketchPoint, rx: Length, ry: Length, angle: Angle) → SketchEllipse` — An ellipse: rx along its own x axis, angle from X, ry across; what is not given is left to the constraints. The same shape as the profile ellipse(…).
- `sk.rect(p: SketchPoint, q: SketchPoint, center: SketchPoint, w: Length, h: Length, angle: Angle | "free", corner: Length) → SketchLine[]` — A rectangle: its 4 lines (bottom, right, top, left), horizontal and vertical; angle: turns it (its first side from X), "free" leaves the turn to the constraints; corner: rounds them; w: alone, a square. The same shape as the profile rect(…).
- `sk.polygon(center: SketchPoint, n: int, r: Length, d: Length, fit: string, angle: Angle) → SketchLine[]` — A regular polygon: its n lines, corners on a construction circle of the size given; fit: "sides" makes its sides touch it instead; angle: the direction of the first corner, else the turn is left free (starting with the first side at the bottom, horizontal). s.polygon([p1, p2, p3]): the closed polyline through the points. The same shapes as the profile polygon(…).
- `sk.slot(p: SketchPoint, q: SketchPoint, w: Length, length: Length, center: SketchPoint, angle: Angle) → [SketchLine, SketchArc, SketchLine, SketchArc]` — Two half circles round p and q joined by tangent lines: [line, arc round q, line, arc round p]; or by its length end to end, along X (angle: turned) round center: or a new point at the origin. The same shape as the profile slot(…).
- `sk.teardrop(center: SketchPoint, r | d: Length, angle: Angle, flat: bool) → [SketchArc, SketchLine, SketchLine]` — A hole that prints sideways: an arc round the centre and two lines tangent to it meeting above it, angle (45° unless given) from the vertical; flat: true cuts the point with a line on the circle's top ([arc, line, flat, line]). The same shape as the profile teardrop(…).
- `sk.fill(at: SketchPoint | Vec, full: bool)` — The area of the profile holding `at` full (or full: false, empty), whatever the loops round it say: by default an area is full inside an odd number of loops (a loop in a loop is a hole; where two loops overlap, so is the overlap); where more than two lines or arcs meet at a point (a line across a rectangle, ending on its sides), every area they close is full. A point of the sketch keeps it in its area as the constraints move it; the last fill in an area counts; one in no area (outside every loop) fills nothing, with a warning.
- `sk.coincident(p: SketchPoint, q: SketchPoint)` — Two points in the same place.
- `sk.length(line: SketchLine, v: Length)` — Sets the length of a line.
- `sk.distance(a: SketchPoint, b: SketchPoint | SketchLine, v: Length, along: X | Y)` — Sets how far a point is from another point (along: X or Y only across or up), or from a line.
- `sk.parallel(a: SketchLine, b: SketchLine)` — Two parallel lines.
- `sk.perpendicular(a: SketchLine, b: SketchLine)` — Two lines at right angles.
- `sk.fillet(p: SketchPoint, r: Length)` — Rounds the corner where two lines meet at p (an error on any other point: a circle's centre, a free end).
- `sk.fix(p: SketchPoint)` — Pins a point.
- `sk.horizontal(line: SketchLine)` — A horizontal line (or two points at the same height, or an ellipse's x axis along X).
- `sk.vertical(line: SketchLine)` — A vertical line.
- `sk.equal(a, b)` — Equal lengths or radii; s.equal(e): an ellipse as wide as tall.
- `sk.on(p: SketchPoint, curve)` — A point on a line, circle, arc or ellipse; a shape's lines (s.rect, s.polygon, s.polyline) on a circle or ellipse: every corner on it, the shape inscribed.
- `sk.concentric(a, b)` — Circles, arcs or ellipses (or a point) round the same centre.
- `sk.tangent(a, b)` — Tangent line and circle, arc or ellipse, or two circles; a shape's lines and a circle or ellipse: every side touching it, the shape round it.
- `sk.midpoint(p: SketchPoint, line: SketchLine)` — A point in the middle of a line.
- `sk.symmetric(p: SketchPoint, q: SketchPoint, line: SketchLine)` — Two points symmetric about a line.
- `sk.radius(c: SketchCircle, v: Length, rx: Length, ry: Length)` — Sets a radius (an ellipse's: rx, ry).
- `sk.diameter(c: SketchCircle, v: Length)` — Sets a diameter.
- `sk.angle(a: SketchLine, b: SketchLine, v: Angle)` — The angle between two lines, or of one line or an ellipse from X.
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
- `d.view(solid: Solid, name: string, at: Vec, scale: number, dimensions: bool) → View` — One view: "front", "top", "iso"…; with its overall width and height and its hole callouts unless dimensions: false (an overall one your own dimension repeats is left out).
- `d.section(solid: Solid, plane: Plane, label: string) → View` — A hatched section (the plane must cut the solid).
- `d.dimension(view: View, from: Vec, to: Vec, offset: Length, text: string)` — A dimension between two points, offset paper mm away from the part (negative: towards its middle).
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
- `Solid.nothing: Solid` — The empty solid, meant so: returned by a @part, no part this time (a lid left out by a parameter). Solid.init is the empty solid to start a union built in a loop; a part left empty by it, or by a cut, is an error.
- `edges: Edges` — The edges of the solid a feature applies to: edges.parallel(Z).
- `faces: Faces` — The faces of the solid a feature applies to: faces.top.

## Keywords

- `module` — Names the model: module box;
- `import` — import std.hardware : M3;  import pizza;  import p = parts.bracket;
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

- `struct Screw(name: string, d: Length, pitch: Length, tap: Length, clearance: Length, head: Length, headHeight: Length, key: Length, nut: Length, nutHeight: Length, washer: Length, insert: Length, insertDepth: Length)` — Metric screw sizes (ISO 4762 socket head cap screws, ISO 4032 nuts, ISO 7089 washers) with the holes to print or drill for them.  Tags: a hole's faces are tagged "hardware.bore" (the counterbore's and the countersink's, where the head sits, "hardware.seat"), and stay so in the part it is cut from; a nut's hole is "hardware.bore" too, threaded or not; holes, screws, nuts and washers carry the axis "hardware.axis" (body.axis("hardware.axis"), with one of them in it).
- `struct Head(d: Length, h: Length, key: Length)` — The head of another kind for screw s: its diameter (across the flats for "hex"), its height and the hex key. "button" ISO 7380, "flat" ISO 10642 (countersunk, 90°), "hex" ISO 4017 (spanner across the flats), "pan" ISO 7049 (self-tapping); "socket" the ISO 4762 of the size itself.
- `headOf(s: Screw, head: string) → Head`
- `hexPrism(acrossFlats: Length, h: Length) → Solid` — Hexagonal prism standing on XY, flats parallel to the X axis.
- `screw(s: Screw, length: Length, socket: bool = true, threaded: bool = false, head: string = "socket") → Solid` — A screw: head "socket" (ISO 4762, the default), "button" (ISO 7380), "flat" (ISO 10642, countersunk), "hex" (ISO 4017) or "pan" (the self-tapping ST sizes). The underside of the head lies on z = 0 (for a flat head, its top: it sinks into its countersink): the head grows upwards and the shank downwards, so the screw drops into a hole. threaded: true models the thread (the ISO one for metric sizes), built on the shank's side; otherwise the shank is plain; socket: false leaves out the hex socket.
- `setKey(s: Screw) → Length` — The hex key of a set screw (a grub screw) of size s: ISO 4026-4029, smaller than the socket head's.
- `setScrew(s: Screw, length: Length, point: string = "cup", threaded: bool = false) → Solid` — A set screw (a grub screw): threaded all along, no head, a hex socket in its top. point: "cup" (ISO 4029, the common one: a ring that bites into a shaft), "flat" (ISO 4026, to leave a mark), "cone" (ISO 4027, into a dimple) or "dog" (ISO 4028, a pin into a hole). Its socket end lies on z = 0 and the rest goes down, `length` long, point and all, so it drops into a hole the way hole() is placed. threaded: true models the thread.
- `nut(s: Screw, threaded: bool = false) → Solid` — Hex nut standing on z = 0, with the corners chamfered on both faces. threaded: true threads the hole (the ISO thread for metric sizes, with no play: the nut of a real screw).
- `washer(s: Screw) → Solid` — Flat washer standing on z = 0.
- `hole(s: Screw, depth: Length, kind: string = "clearance", head: string = "socket", chamfer: Length = …) → Solid` — A hole to subtract, with its top on z = 0 going down `depth`: "clearance" (the screw passes), "tap" (pilot hole for the thread), "insert" (heat-set insert), "counterbore" (clearance with room for the head), "countersink" (for flat heads) or "ribs": a hole the screw passes with three ribs along it, 120° apart, that the screw cuts its thread into as it goes in (better than a printed thread for small screws, and than a plain tap hole: less material to cut, so less force and no split wall). One rib points to -Y: on a wall (where a face's frame has y up) it is the bottom one, which prints best; the ribs start 0.6 mm in, a lead for the tip.  The whole hole lies within `depth`: an insert, a counterbore or a countersink deeper than that is an error.  `chamfer` widens the mouth at 45° by that much all round (a counterbore's round the head): it guides the screw in, and takes up the first layers' spread when the hole opens on the bed. 0.5 mm for "ribs" unless given, none for the others; a countersink's cone is a chamfer already (one given to it is an error).
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
- `tappedHole(d: Length, pitch: Length, depth: Length, clearance: Length = …, left: bool = false) → Solid` — A tool to subtract for an internal thread that a `d` screw fits, from z = 0 going down `depth`. `clearance` widens it for printed parts; left: true for a left-handed screw.

## Library: import gears;

- `pitchDiameter(m: Length, teeth: int) → Length`
- `outsideDiameter(m: Length, teeth: int) → Length`
- `rootDiameter(m: Length, teeth: int) → Length`
- `centerDistance(m: Length, teeth1: int, teeth2: int) → Length`
- `involute(rb: Length, r: Length) → double` — Angle of the involute of a circle of radius rb at radius r.
- `gearProfile(m: Length, teeth: int, pressure: Angle = …, backlash: Length = …, steps: int = 6) → Profile` — The outline of a spur gear centred on the origin, a tooth on +X. backlash thins the teeth (measured on the pitch circle) so that printed gears do not bind. The teeth are those a rack cuts (generated): under about 21 teeth the rack's tip undercuts the flanks' roots, room for the tips of the gear they mesh with.
- `spurGear(m: Length, teeth: int, thickness: Length, bore: Length = …, pressure: Angle = …, backlash: Length = …, steps: int = 6) → Solid` — A spur gear standing on z = 0, with an optional bore; `steps` points on each flank's involute and as many on its root (more: smoother teeth, slower). Tags: the axis "gears.axis", the bore's wall "gears.bore".
- `rack(m: Length, teeth: int, thickness: Length, base: Length = …, pressure: Angle = …, backlash: Length = …) → Solid` — A straight rack along +X starting at x = 0, teeth up, pitch line at y = 0; backlash thins the teeth on the pitch line, as on a gear. Tag: the pitch line "gears.pitch" (an axis along it, on the rack's bottom face).

## Library: import hinges;

- `struct Hinge(fixed: Solid, moving: Solid)` — The two leaves of a hinge, printed in place: they come out of the printer already joined and turn around the X axis. Tags: both leaves carry the axis they turn round, "hinges.axis"; pinHinge's holes for the pin are tagged "hinges.pin".
- `hinge(length: Length = …, width: Length = …, thickness: Length = …, knuckles: int = 5, clearance: Length = …) → Hinge` — A print-in-place hinge along X, centred on the origin, leaves lying flat on z = 0 and the axis at z = thickness. `knuckles` alternate between the leaves (odd numbers keep it symmetric).
- `livingHinge(length: Length = …, width: Length = …, thickness: Length = …, web: Length = …, gap: Length = …) → Solid` — A living hinge: two plates `width` wide each, lying flat side by side along X, joined by a thin web `web` thick and `gap` wide at their underside, which bends. For PETG, PP or TPU (PLA cracks after a few bends); print it flat, the web on the bed, so its layers run across the fold. The plates lie on -Y and +Y, the fold line along X at y = 0.
- `pinHinge(length: Length = …, width: Length = …, thickness: Length = …, knuckles: int = 5, pin: Length = …, clearance: Length = …) → Hinge` — A hinge turning on a separate pin: the knuckles of both leaves holed `pin` + 2 × `clearance` across, for a length of 1.75 mm filament, a nail or a screw pushed through when assembled. Laid as hinge() lays its leaves (the axis along X at z = thickness); the leaves print apart, flat, and the hinge comes apart again.
- `snapHinge(length: Length = …, width: Length = …, thickness: Length = …, clearance: Length = …) → Hinge` — A hinge that snaps together: three knuckles, the two outer ones on the fixed leaf with a cone standing in from each, the middle one on the moving leaf with a conical socket at each end. Spring the outer knuckles apart a little, push the middle one between them, and the cones click into their sockets; it comes apart the same way. Laid as hinge() lays its leaves; they print apart, flat.

## Library: import snaps;

- `snapHook(length: Length = …, thickness: Length = …, width: Length = …, overhang: Length = …, lead: Angle = …) → Solid` — A hook: a flexible beam `length` long with a barb `overhang` deep at the top. `lead` is the slope that pushes it aside when inserting.
- `snapSlot(thickness: Length = …, width: Length = …, overhang: Length = …, wall: Length = …, clearance: Length = …) → Solid` — The slot a hook clicks into, to subtract from the mating wall: a window round the beam, `clearance` larger, with room on the -X side for the beam to bend aside while the barb goes through; then the barb rests on the wall beyond the window's +X edge.

## Library: import enclosures;

- `roundedBox(x: Length, y: Length, z: Length, r: Length = …) → Solid` — A box centred in X and Y on z = 0, with vertical edges rounded by `r`.
- `tray(x: Length, y: Length, z: Length, wall: Length = …, r: Length = …) → Solid` — An open box: walls `wall` thick, open on top.
- `struct Enclosure(base: Solid, lid: Solid)` — A base and a lid that fit together, both standing on z = 0.
- `enclosure(inner: Vec3, wall: Length = …, r: Length = …, lidHeight: Length = …, screw: Screw = …, clearance: Length = …) → Enclosure` — An enclosure with `inner` free space (x, y, z), a lid with a lip that fits inside the base, and a screw post in each corner.
- `shadowCase(inside: Solid, on: Plane = …, wall: Length = …, clearance: Length = …, split: double = 0.5, close: string = "lip", lip: Length = …, play: Length = …) → Enclosure` — A case with upright walls round one part: the shadow it casts on the plane `on` (the ground, XY, unless given), its convex hull grown by `clearance`, walls `wall` thick standing square to the plane, so the part drops in along the plane's normal and lifts out. Base and lid meet at `split` of the part's height (halfway unless given): opened, the part stands out of the base, to take it. The base: a floor `wall` thick under the part, its walls, and a lip `lip` high rising from their inner half; the lid: its walls, `play` wider round the lip, and a top `wall` thick `clearance` over the part. close: "lip" holds the lid on by friction; "snap" adds a bead round the lip, halfway up it, that clicks into a groove inside the lid (its wall gives a little as it goes over). The lip is 3 mm high unless given, lower on a flat part (a card, a coin, a board) where that does not fit under the lid's top.  Tags: the base's floor inside is "enclosures.floor", the top of its walls, where the lid rests, "enclosures.rim", the lip (on the base) "enclosures.lip"; the lid has none.

## Library: import joints;

- `struct Joint(a: Solid, b: Solid, loose: Solid[], print: Solid[])` — The two pieces of a solid cut along a plane with a joint between them, and the loose parts that lock it (a wedge), if any.
- `splitJoint(body: Solid, at: Plane, kind: string = "tenon", size: Length = …, length: Length = …, clearance: Length = …, turn: Angle = …, count: int = 2, keys: int = …) → Joint` — `body` cut along the plane `at` into two pieces that fit together with a joint, `clearance` apart where they meet (0.2 mm suits most FDM printers: see the fits guide). The joint is centred on the cut (the middle of the section), laid along the section's longer side; `turn` turns it further about the plane's normal; `size` sets its scale (by default the square root of the section's area: the width of a square beam) and `length` how far it reaches across the plane (0.6 of the size). `count` (or `keys`, as in splitFlat and mold) is the number of fingers, pins or dowels (pins thinner the more there are). The fingers share the section's width; pins and dowels go in a row across its middle or, where that is hollow (a tube), on the material round it, as thick as it has room for; a tenon there is an error.  - "tenon": a tenon on a, its mortise in b (hozo); - "dovetail": a tail across the piece, sliding in sideways (ari); - "pins": round pins on a, holes in b; - "fingers": a box joint, fingers of a and b in turn; - "lap": a half lap (ai-gaki), each piece keeping half the thickness; - "kama": a gooseneck, dropping in from the side (kama tsugi); - "kanawa": a half lap with hooks at both ends, locked by a wedge driven through the middle (kanawa tsugi): the wedge is in `loose`; - "koshikake": a dovetail over a seat that the other piece rests on (koshikake ari tsugi), which carries a load without bending open; - "barbed": a tenon with barbs, split down its middle, driven in: it goes in and does not come out. - "dowels": `count` loose dowels, the printed kind of wooden ones: a rod with two flats, each end split, half into a round hole of a and half into one of b, held by friction (the split halves press on the walls); they print lying on a flat (`print`), and the holes are plain round ones.
- `struct FlatSplit(a: Solid, b: Solid, keys: Solid[], aPrint: Solid, bPrint: Solid, print: Solid[])` — The two halves of a solid cut flat along a plane, each to print lying on its cut face, and the flat keys that join them.
- `splitFlat(body: Solid, at: Plane, keys: int = 2, kind: string = "bowtie", size: Length = …, depth: Length = …, clearance: Length = …, wall: Length = …, count: int = …) → FlatSplit` — `body` cut flat along the plane `at` into two halves, each printed lying on its cut face (nothing stands out of it, so it lies flat on the bed), joined by `keys` flat keys (or `count`, as in splitJoint): a pocket in each half's cut face, half the key in each. The keys print lying flat too, and fit their pockets `clearance` apart; glue them in, or leave them dry to take apart.  The keys go where the cut has room for them, at least `wall` from its edges, as far apart as they can be. "bowtie" keys (butterflies, chigiri) keep the halves from sliding and from turning, even one alone; "disc" keys are round, two at least. `size` is a key's length (from the section's size unless given), `depth` how deep it goes into each half. The pockets open with a 0.4 mm chamfer: the first layers spread a little on the bed, and the pocket's mouth is on the bed.
- `joinParts(a: Solid, b: Solid, at: Plane, kind: string = "tenon", size: Length = …, length: Length = …, clearance: Length = …, turn: Angle = …, count: int = 2, keys: int = …) → Joint` — Two separate parts joined where one meets the other: `b` ends on the plane `at` (a face of `a`, its normal pointing into `b`), and the joint goes from `b` into `a`: a shelf into an upright, a rail into a post. The joint is centred on `b`'s end and sized by it, as splitJoint does; what reaches past `a`'s far side stops flush with it (a through tenon). Kinds: "tenon", "dovetail" (a sliding dovetail, its housing running out of `a` the way it slides in), "pins", "fingers" (a corner of a box), "lap", "kama" (its housing too runs out of `a`), "koshikake" (a sliding dovetail over a seat, its housing running out of `a` too), "barbed" (driven in for good), "dowels" (holes in both, the dowels in `.loose` and, lying flat, in `.print`); not "kanawa", which joins two ends: splitJoint. `count` (or `keys`) as in splitJoint. Gives the two parts changed: `.a` with the hollows, `.b` with what fits in them.
- `jointKinds: string[]`

## Library: import molds;

- `struct Mold(a: Solid, b: Solid, aPrint: Solid, bPrint: Solid)` — The two halves of a mold, where they go and laid for printing.  Tags: the faces of the hollow the object leaves are "molds.cavity", the halves' faces along the parting plane "molds.parting", the pour hole's "molds.sprue".
- `mold(object: Solid, at: Plane, wall: Length = …, keys: int = 4, sprue: Length = …, vents: int = 2, seal: Length = …, clearance: Length = …, pry: bool = true, count: int = …) → Mold` — A two-part mold to cast `object` in (silicone, resin, plaster): a block `wall` thick round it, cut along the parting plane `at`, the object's shape hollow inside. The plane should cross the object where it is widest, so each half lets go of the cast.  - `keys` (or `count`, as in splitJoint) cones on a's parting face and their sockets in b's line the halves up (where the face has room, as far apart as they can be), `clearance` apart; - a seal round the cavity (its convex hull), a ridge `seal` high on a and its groove in b, keeps the liquid from creeping out between the halves (0.mm: none); - a pour hole `sprue` wide with a funnel, and `vents` thin channels for the air, go up through b from the cavity's highest points (along the plane's normal: put that side up when pouring).  - `pry`: a notch on two opposite sides, across the parting line, to open the mold with a flat screwdriver without marring its faces.  Both halves print with the parting face up, on their outer faces (`aPrint`, `bPrint`): the keys and the seal stand up, the sockets and the groove open upwards, with no supports.

## Library: import flex;

- `kerf(body: Solid, zone: Solid, width: Length = …, bridge: Length = …, pitch: Length = …, length: Length = …, along: Vec3 = …) → Solid` — `body` made to bend where it lies inside `zone` (any solid: a box across a plate, a ring round a tube): rows of slots through its thickness, each row shifted half a slot from the next, so what is left is a lattice of thin bars that twist and bend (kerf bending, as in laser-cut plywood). The slots go through the part's thinnest way inside the zone, and run across the body's length (along its shorter side), so it bends along its length. `along:` (X, Y or Z) sets the way they run instead. The slots run along the axes X, Y and Z only, and go through along one of them: make a part that lies turned at an angle bend before turning it.  - `width`: how wide each slot is (0.8 mm: two lines of a 0.4 mm nozzle leave it open); - `bridge`: the material between two slots of a row: the narrower, the softer it bends; - `pitch`: from one row to the next: the closer, the tighter it bends; - `length`: of each slot (six times the pitch unless given, shorter on a narrow part: its width less a bridge, so there is material at its ends). Slots that cut the part apart are an error.  In PLA a few degrees per row; PETG and TPU bend much further. Print the part lying flat, the slots upright.

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
- **Esc** — closes what is shown over the model: a sketch (asking first if it was changed), a step, Inspect, the marks
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
