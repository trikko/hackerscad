# hackerscad

hackerscad is a parametric CAD: a model is a .hcad file, a sandboxed subset of
the D language (no file, network or process access), evaluated into exact
solids (OpenCascade) and exported as STL, 3MF, STEP, PNG or drawings (PDF,
SVG, DXF). The desktop application shows the model while the user edits it;
the command line tool and the MCP server let an agent do the same.

hackerscad is new and not in your training data: do not write OpenSCAD
(.scad), CadQuery or build123d code, the syntax and the names differ. Read the
reference first and follow the rules below.

## Setup and updates

This text was made by hcad 0.3.1 (docs stamp `0.3.1-0bdd71a0`). Before the first
model of a session, run `hcad docs --stamp` (`hcad` may be a full path, or the
AppImage followed by the word `hcad`; with the MCP server, hcad_docs with
format stamp):

- **It prints `0.3.1-0bdd71a0`:** this text is up to date.
- **It prints something else:** hackerscad was updated and this text is
  older or newer than it. Installed as a skill, refresh it in place:
  `hcad docs --skill` into this SKILL.md, `hcad docs` into the llms-full.txt
  next to it, then read it again. Otherwise, where they differ, follow
  `hcad docs`: the reference of the installed version.
- **`hcad` is not found:** hackerscad is not installed, or not in the PATH.
  Ask the user where it is, or whether to install it from
  https://github.com/trikko/hackerscad/releases (the latest release, or the
  nightly pre-release when there is none):
  - Linux: the AppImage in `~/.local/bin`, made executable, and a link to it
    named `~/.local/bin/hcad` (a link named hcad runs the command line tool);
  - Windows: the zip unpacked (for example in `%LOCALAPPDATA%\Programs`), its
    `bin` folder added to the user's `Path`;
  - macOS: the zip unpacked into `/Applications`, and
    `/Applications/hackerscad.app/Contents/Resources/bin` added to the `PATH`
    in `~/.zshrc`.

  Then refresh this text as above, add the MCP server (below) and ask the
  user to restart you, so its tools appear.

## How to work

- **With the MCP server** (best): the tools are named hcad_*, whatever name
  the server was added under (usually `hcad`, sometimes `hackerscad`). If they
  are missing, use the command line below and suggest adding the server once:
  `claude mcp add -s user hcad -- hcad mcp` (Codex: `codex mcp add hcad --
  hcad mcp`), then restarting the agent. Tools:
  hcad_docs (the reference, one topic, or format: cheatsheet for every
  function in one line), hcad_check (errors with line,
  column and suggestion; parts, sizes, volumes), hcad_render (pictures of the
  views: look at them), hcad_measure, hcad_export (.3mf, .stl for one part,
  .zip for one STL per part, .step, .png; 'parts' picks some),
  hcad_drawing (.pdf .svg .dxf); to remodel a mesh or STEP (see
  Remodelling a mesh), hcad_features, hcad_scan, hcad_section,
  hcad_review (the comparison round in one call), hcad_diff, hcad_lines,
  hcad_compare, hcad_match, hcad_fit and hcad_literals
  (hcad_docs topic remodel gives the method). When the user has the application open, the
  hcad_gui_* tools drive it (open, edit the code, set parameters, move the
  view, pick faces, select and measure, context menu, section plane, rollback,
  inspect (the solids and 2D profiles a line or function makes), save,
  screenshot, state), so they see what you do. Points can be given in
  model millimetres (hcad_gui_project converts them). Each window has a name
  in its header bar; with several open, hcad_gui_windows lists them and the
  user may tell you which one ("work in blue-otter"). With none open, or to
  show your work in a window of its own, hcad_gui_launch opens one on the
  user's screen (on a model, or a new one) and gives its name. To show an
  example or a trial, launch it with code (the model's text) or copy (a
  file whose text is copied in), not path: the window works on no file, so
  the user can try things and Save asks for a name, where a window on a file
  (an example of the project, a model of the user's) would save over it.
  While a window shows a
  model, change its code with hcad_gui_edit, never by writing its .hcad file:
  the user may have unsaved changes (moving a part with the mouse edits the
  code), and a file rewritten under them makes the window ask which to keep.
  For the command line tools, save a copy elsewhere (hcad_gui_state with
  source: true gives the code) instead of moving the window to a file.
  With a window open, at the start of every turn, before thinking or
  editing: hcad_gui_state with only ["source_hash", "user_changed"]; if
  the code changed, read it again (source: true) and work on it, never on
  your earlier copy: the user may have edited it. The same source_hash as
  before is the same code, no need to fetch it again. The other hcad_gui_*
  tools reply with the whole state too: give them only as well
  (hcad_gui_edit with only: ["revision", "problems", "parts"]).
  Never take the most recent window for the user's: if it is not clear
  which one they mean, ask, or open one of your own. Show the work in the
  window as it goes, not only pictures at the end, and leave the view on
  what changed (hcad_gui_view look_at it, with a size that shows where it
  is; preset fit when the whole model changed). To show the user what you mean
  ("the hole goes here", "this wall is too thin"), mark up the view with
  hcad_gui_annotate (arrows, crosses, circles, text over it, the view
  locked meanwhile); the user marks it the same way in Annotate mode. When they say
  "here", "this" or "there", or to look at the marks, read them in
  hcad_gui_state, not in a screenshot: each says what lies under it (part,
  face, point in mm, selector) or, on the background, what it points at
  (points_at), and its colour's name. Then set mode:
  false, so the view goes live again and shows your changes.
- **With the command line:** `hcad docs` prints the whole reference
  (`hcad docs fillet` one topic); `hcad check model.hcad --json` reports
  errors, parts and sizes; `hcad render model.hcad -o model-views.png`
  draws iso/front/top/right (look at it); `-o model.3mf`, `.step`, `.zip`
  (one STL per part), `.stl` (one part: `--part name`);
  `-D width=80.mm` and `--preset name` change parameters.
  `hcad features part.stl` lists what a mesh is made of (planes, holes,
  shafts, cones, roundings, hole patterns, with plausible sizes): the start
  for remodelling a part given as STL (hcad_features with the server);
  `hcad section part.stl --plane xy --at 3` (hcad_section) a cut across it
  as lines, arcs and circles, and as a sketch ready to extrude (`--region
  U0,V0,U1,V1` only the outlines inside);
  `hcad compare model.hcad --a clone --b original -o map.png` (hcad_compare)
  how far the remodelled part is from the mesh, with a coloured map and
  the surface patches that do not match; `hcad diff` (hcad_diff) the
  material to add or cut, the thin differences it leaves out, and the
  section that shows each region; `hcad match` (hcad_match) the operations
  matched one by one; `hcad lines` (hcad_lines) both drawn as lines
  from many sides, the lines only one has (chamfers, countersinks,
  letterings: what the eye sees first; once the outside matches,
  `--depth MM` peels both, `--voids` compares the holes made solid;
  violet marks surface facing otherwise: twisted, curved); `hcad scan`
  (hcad_scan) holes and pockets along
  an axis; `hcad fit` (hcad_fit) tunes @param lengths to the original;
  `hcad literals model.hcad --original original` (hcad_literals) the
  numbers the model repeats, and which sizes of the original they are.
  `--printability` adds per part the overhangs needing supports and the
  walls too thin to print (marked in the pictures: red stripes, violet
  hatching); with the window, `hcad_gui_view` with `printability: true`.
- Ask instead of guessing whenever it changes the result, and ask before
  you start, not afterwards: a font, the scale of a photo, a size of a real
  part, the process or printer, which window, overwriting a file. For a
  design, few questions: those that change the result most, numbered;
  leave the rest. Always say plainly that the user answers the ones they
  can, the more the better, and you estimate the others, made @params to
  change later.
- The loop: write the model, check it, render and look, compare sizes and
  pictures with the request, fix, then export. Put the request's
  requirements in unittest blocks so the checks repeat them.

## Rules that avoid most mistakes
- Every exported body is a function marked @part that takes no arguments and
  returns a Solid, with the annotation on its own line:
      @part("steelblue")
      Solid body() { ... }
- Reference objects (the shaft a knob fits on, the phone a stand holds) are
  parts too, see-through and not exported, so the fit can be checked:
      @part("slategray", alpha: 0.35, export: false)
- Lengths: write units (60.mm, 2.5.cm, 1.inch). Bare numbers passed to
  geometry are millimetres. Never add a bare number to a length (60.mm + 5 is
  an error; write 60.mm + 5.mm, or d.to!double for the bare number a length
  stands for in this file). Vectors too: write the unit on every number,
  for clarity (vec(6.25.mm, 31.5.mm)); a vector of bare numbers and one of
  lengths do not add (vec(1, 2) + vec(1.mm, 2.mm) is an error). Your own
  functions take Length parameters
  (Solid peg(Length d) …): a bare number passes as mm, a @param as it is,
  no .to!double.
- Angles: rotate(z: 45) uses degrees; 30.deg is explicit.
- A number takes its unit after a dot: 8.2.mm, not 8.2mm (in -D too).
  There is no cast: x.to!int, x.to!double, round(x), floor(x), ceil(x).
- Primitives stand on the XY plane and are centred in X and Y:
  box(x, y, z) spans z = 0 .. z; cylinder(r: or d:, h:) also; center: true
  centres in Z. sphere(r) is centred on the origin.
- Booleans: a + b (union), a - b (difference), a & b (intersection).
- Place parts relative to each other instead of computing coordinates:
  lid.nextTo(body, X, gap: 10.mm), cap.on(body).
- Fillets, chamfers and shells take selectors, evaluated on the solid they
  apply to: .fillet(edges.parallel(Z), r: 3.mm),
  .chamfer(edges.filter(e => e.mid.z > 5.mm), d: 1.mm),
  .shell(open: faces.top, thickness: 2.mm). Apply fillets before shell and
  before cutting holes; a fillet radius must be smaller than the faces next
  to the edge. When one fails, its error names the edges that fail and, when
  that is why, the face beside them too narrow for the size (round before
  the cut that narrows it, or make the size smaller).
- To round or chamfer the edges a cut left behind, select them by provenance:
  .fillet(edges.between(faces.from(holes), faces.top), r: 0.5.mm).
- Select by provenance, not by position: edges.between(faces.from(upright),
  faces.from(foot)) follows the @params, a filter on e.mid.z does not.
  faces.top is the highest face (after an upright with a round top is
  added, that top, no longer the foot's); faces.normal(Z) also takes
  curved faces whose normal at their centre points up; faces.from(foot)
  has neither problem, and a frame can be taken on the solid before
  (foot.frame(faces.top)).
- Cut with planes: body.split(body.plane(faces.top).offset(-10.mm)) gives
  .above and .below; s.pieces lists separate bodies, ordered along X, Y, Z.
- Profiles: rect, circle, ellipse, polygon, slot, teardrop (the shapes of a
  sketch, same names and arguments, centred on the origin unless given a
  point: rect(40.mm, 20.mm, corner: 3.mm), rect(p, q), circle(c, d: 5.mm),
  rect(center: vec(15.4, 3.3), w: 5.6.mm, h: 14.mm, angle: 45.deg) (a
  rotated one, round a point),
  polygon(6, d: 13.mm, fit: "sides"), slot(p, q, w: 6.mm)), polygon(points),
  text; combined with + - &, moved, turned, scaled, mirrored like solids,
  .round(r), .offset(d); turn them into solids with .extrude(h) or
  .revolve(axis: Y). A prism along X or Y: .extrude(h, along: Y) (the
  profile's x along X, its y up Z, towards +Y; along: X its x along Y,
  towards +X; a negative h the other way); taper: 3.deg narrows the solid
  and widens its holes going away from the profile, whichever way it goes
  (a negative taper widens it and narrows the holes). A profile in another
  plane (a section, one turned or moved, one drawn on a face) extrudes
  across its own plane, from where it lies. On a face:
  body.extrude(profile, on: frame, depth:) adds, body.cut(profile, on:
  frame, depth: | through: true) removes.
  Stand a profile up with p.across(X) or across(Y) (as extrude(along:)
  does), not with rotate: loft([a.across(X), b.across(X).move(x: 20.mm)])
  runs along X.
- Sweeps and lofts: circle(d: 4.mm).sweep(path([vec(0, 0, 0), vec(0, 0, 30),
  vec(30, 0, 30)])), circle(d: 1.mm).sweep(helix(r: 5.mm, pitch: 2.mm,
  height: 20.mm), frenet: true), loft([circle(r: 20), rect(25).move(z: 40)]).
- Exact 2D outlines with dimensions: auto s = sketch(); points, lines, arcs,
  circles, ellipses, splines (s.spline([p, q, r]): a smooth curve through
  points, closed: true a loop of its own) and shapes (s.rect, s.polygon(c,
  6, d:, fit: "sides"), s.slot, s.teardrop), then constraints (horizontal, vertical, length,
  distance, angle, tangent, on, equal, concentric…) and s.profile, to
  extrude or revolve.
  Prefer a sketch over unions and differences of boxes and cylinders for
  the outline of a prismatic part (built from flat outlines, extruded,
  revolved and cut: a bracket, a plate, a case, a holder, a knob, a cam, a
  gasket, a clip; not a sculpted shape like a figurine), with the sizes
  given or estimated (estimated ones become @params): write each dimension
  as a constraint, aim for s.dof == 0 (a warning lists what is left free),
  then add 3D features (holes, fillets, shells) to the extruded solid. A
  profile made of more than three shapes, moved by sizes worked out by
  hand, or rounded with .offset(r).offset(-r) is an outline that wants a
  sketch: it reads as its dimensions, keeps its tangents when a @param
  changes, and its edges take fillets. One shape alone can stay one line
  (rect(40.mm, 20.mm, corner: 3.mm)); in a sketch (s.rect) its sizes
  become dimensions the user changes with a click in the window. Examples
  below: the medal (a first sketch, step by step), the pillow block (a
  part from five sketches on five surfaces) and the carlo library (a clip
  drawn with tangent arcs, a loop and if/else).
- To build on a face, take its frame and place parts built on XY (Z up):
  cylinder(d: 8.mm, h: 5.mm).placeOn(body.frame(faces.top).at(x: 10.mm)).
- To draw an outline on a face, measured from the part's own edges, sketch
  there: auto s = body.sketch(faces.top); its edges are references in
  s.edges (the lowest first, counter-clockwise: bottom, right, top, left on
  a rectangular face), s.origin is its centre, s.project(edges.…) flattens
  other edges onto it (a hole's rim below). Constrain the new geometry to
  them (s.distance(p, s.edges[0], 3.mm)), then body.cut(s.profile, depth:)
  or body.extrude(s.profile, depth:): the profile knows its face, no on:.
  In the window: hcad_gui_feature with action sketch on a flat face.
- Axes and planes anywhere: rotate(90.deg, axis: body.axis(edges.filter(e =>
  e.isCircle && e.radius == 3.mm))), s.mirror(plane(origin: vec(10, 0, 0),
  normal: X)), plane(p1, p2, p3), plane(axis, point).
- Existing parts: load("part.stl"/".obj"/".3mf"/".step", scale: 1) gives a solid to
  modify; text("LABEL", size: 4.mm).centered centres a profile for engraving.
- When asked to copy lettering from a photo, a drawing or a model: if the
  font cannot be recognised, or text() does not have it (it uses the fonts
  installed), ask the user before going on, offering a similar installed
  font (name it), or tracing the letters as a sketch (lines and arcs sized
  from the picture), or load("letters.svg") if they can give a vector
  tracing; never swap the font before the user has chosen (saying so
  afterwards is not enough). Working with no one to ask (a task run on its
  own): trace the letters as a sketch, and say so in the report. Logos, engraved or hand-drawn
  lettering are traced as a sketch. Lettering on a mesh or STEP to copy
  needs no question: its exact shape is there (see Remodelling a mesh).
- Constants are immutable; module-level values cannot be modified.
- Expose the dimensions a user may want to change as parameters:
      @param("Outer width", min: 20.mm, max: 200.mm)
      immutable width = 60.mm;
  and put requirements in unittest blocks:
  unittest { assert(body.bbox.size.z <= 40.mm, "must fit in the drawer"); }
- Use the libraries instead of modelling common parts by hand:
  import hardware : M3, screw, nut, hole; then M3.clearance, M3.tap,
  screw(M3, 20.mm), nut(M3), hole(M3, 5.mm, "counterbore"|"insert"|…);
  import threads (threadedRod, tappedHole); import gears (spurGear, rack,
  centerDistance); import hinges (hinge(…).fixed/.moving, print in place);
  import snaps (snapHook, snapSlot); import enclosures (roundedBox, tray,
  enclosure(vec(x, y, z)).base/.lid).
- Before modelling anything common by hand (a teardrop, a screw hole, a
  nut trap, a thread, a slot, a rounded box), look for it: hcad_docs with
  a topic, or format: cheatsheet (every function in one line); write your
  own only when nothing fits.
- Functions are ordinary arguments: xs.map(x => x * 2), xs.filter(f).
- Your own modules: import parts.bracket; is parts/bracket.hcad next to the
  model; import pizza; is pizza.hcad or pizza/package.hcad (which can
  public import its modules), also from the personal library folder.
- Strings interpolate: writeln("volume: $(body.volume)"); text("…", size:)
  is a 2D text profile, not a string function.
- Errors come with a line, a column and often a suggestion: apply it.
- Technical drawings: a function marked @drawing returns drawing(title: …),
  filled with d.standardViews(part) (views, overall dimensions, hole
  callouts) and d.section(part, XZ, label: "A"); export it as .pdf/.svg/.dxf.
- Keep models quick to evaluate: text cut into curved faces and threads take
  seconds; prefer text in relief as a separate part, and plain holes or
  heat-set inserts (hole(M3, d, "insert")) to modelled threads.
- Style: annotations (@param, @preset, @part, @drawing) go on their own line above
  the declaration, several per line when short; chains break before each
  call, the line starting with the dot; lines short (the editor shows about
  56 characters at its default width); an empty line above each comment
  (not right after { or another comment); comments say why.
- For an example, a trial or an explanation that needs some object to work
  on (to move, cut, place, measure), use Carlo, the mascot clip: import
  carlo; then carlo(), and call it Carlo (always the same, recognisable,
  small and quick to evaluate). Not instead of an object the
  request names (the phone, the shaft): model that one.

## Sketches: habits
- Pin one point (fixed: true) or the outline floats.
- A distance is never negative: which side comes from where the points are
  drawn; draw them roughly where they go.
- Guides that are not part of the outline: construction: true lines and
  circles (a diagonal whose midpoint is the centre, a circle to inscribe in).
- s.on(shape, circle) puts every corner of a rect/polygon on a circle,
  s.tangent(shape, circle) every side touching it; polygon(…, fit: "sides")
  sizes it across the flats (a nut's spanner size).
- A profile is a flat closed shape with its holes. One outline told by its
  sizes and relations: a sketch. Overlapping shapes, an offset outline, text
  or an SVG on a shape: profile operations (+ - &, .offset). They mix:
  s.profile + circle(d: 5.mm).

## Prismatic parts and 3D printing
- A prismatic part: its outline as a sketch from the drawing's dimensions,
  extruded or revolved; then fillets and chamfers; then holes (hardware:
  hole(M3, depth, "clearance" | "tap" | "insert" | "counterbore" |
  "countersink")); then check.
- Then build in steps, as on a machine: each further feature (a boss, a
  pocket, a slot, a rib, a step) starts from a face and is extruded from
  it or cut into it; on the faces it makes, again. Not one profile with
  everything at once: each step reads as what it does, and follows its
  face when a @param moves it. A feature of one shape at a place you know
  is one profile on the face: body.cut(circle(d: 6.mm), on:
  body.frame(faces.top), depth: 3.mm), body.extrude(rect(10.mm, 4.mm),
  on: …). A sketch on the face, body.sketch(faces.…), when its outline has
  several shapes or relations (tangent, equal), or its place is measured
  from the face's edges. A feature with a tool of its own takes that tool:
  hole() for a screw, shell for thin walls, a loop for a pattern, a
  library part, a loft or sweep for a shape that changes along its length.
  Example: the pillow block.
- Fits: ask how it will be made (FDM, resin, machined) before choosing
  clearances; for FDM about 0.2–0.3 mm for a sliding fit, press fits from a
  test print. Put clearances in @params.
- Holes across a wall that will print sideways: teardrop(d:) with the point
  up (flat: true cuts the point). Say how the part is meant to print, and
  lay it so (its largest flat face on the ground); look at --printability.

## Copying a real part, or building onto one
- From a photo or a real object to copy or build onto (not a mesh or STEP:
  those have the sizes, see below), your first reply is
  the questions, before writing any code or touching the user's window
  (no hcad_gui_new, no hcad_gui_edit), even when the user says "make it"
  without giving sizes. In one message: the sizes to measure (below), the
  font if there is lettering, and, said plainly, that any of them can be
  left: the more answered the better, the rest estimated from the photo
  (they may be off: @params to correct after a test print). Estimate only when the user answers so, or already said so in the
  request ("just estimate", "I have no caliper"). Saying at the end what
  was estimated does not replace asking.
- Do not invent shapes or sizes you are not sure of: ask. Ask in the way
  that helps: not "how big is it?" but what to measure and how ("with a
  caliper, the distance between the centres of the two holes, axis to
  axis"; "how thick is the rim at the arrow in the photo?"; "is the left
  side straight or curved?"). Number the questions, say what each size is
  for, and which sizes are critical (fits, holes) and which can be rough.
  If, once asked, the user cannot measure or asks you to estimate, say what is estimated and make those sizes
  @params to correct after a test print.
- From a photo: ask for one known size (the scale) and about the hidden
  sides; say which sizes are guessed.

## Remodelling a mesh or STEP
- The sizes are in the file: start at once, no questions. Load it as a
  see-through reference part beside the copy (@part("slategray", alpha:
  0.35, export: false) Solid original() => load("x.stl");), straightened
  if tilted (load(…).aligned).
- 1, read it: hcad_features (chamfers with their size, holes, surfaces
  turned round an axis), hcad_scan along x, y and z (the holes and pockets
  as the operations they were made with), then hcad_section at the levels
  the scans name: exact lines and arcs (region: only the outlines inside a
  rectangle, a lettering, a pocket).
- 2, build from the largest to the smallest: the outside as one outline
  per stretch, the sketch hcad_section gives at that level pasted and
  extruded; then, as for any prismatic part, the features on its faces in
  steps: one of one shape (a round hole, a rectangular pocket, a boss) is
  a profile with the sizes hcad_scan and hcad_features give (hole() when
  they name a screw size); one whose outline has several shapes, a
  section of the original parallel to that face, just inside it, its
  sketch pasted and extruded from the face or cut into it (the sketch is
  in the plane's own coordinates: extrude it along that axis from the
  face's level); the chamfers of the end faces
  before anything is cut in them; then holes, pockets and traps; last
  small chamfers, notches and lettering. Lettering (small regular grooves
  0.5 mm deep in a face are lettering, not notches): cut a section 0.25 mm
  inside the face, paste the sketch hcad_section gives with region round
  the letters (it solves as it is), extrude it 0.5 mm into the face; never
  trace by hand.
- 3, THE ROUND: after every change, hcad_review (hcad review on the
  command line). One call does it all: the distances both ways, the
  material that differs, the drawings outside and of the voids, and
  close-ups of the first entries of each, chosen and framed where they are
  in sight; it ends saying whether it is done or what comes next. It is a
  summary, the first three entries of each report; detail: true gives
  them all. Fix what the close-ups show and review again. To look at a place again after a
  change, give its point (look: [x, y, z]): entry numbers change, points
  do not. The single tools (hcad_compare, hcad_diff, hcad_lines, focus,
  view) go deeper on one place; hcad_section with compare where the
  review says, to read a shape; opaque: true draws the reference solid.
- 4, then: hcad_match (the operations one by one: a hexagon where the copy
  has a circle, a trap cut in steps, a notch for printing); hcad_lines with
  depth once the outside and the voids match; hcad_fit only to tune sizes
  of a shape already right.
- 5, done when hcad_review says so (95% or more of both surfaces within
  0.1 mm) and its close-ups show nothing worth fixing.
- 6, name the measures that matter: hcad_literals lists the numbers the
  model repeats and which sizes of the original they are (a hole's
  diameter, an axis); make those @params or named constants, use the
  names, and put the relations in unittest blocks (the rod fits its hole).
- What the numbers do not say: hcad_diff leaves out what is thinner than
  two cubes, and says how much it left (chamfers, lettering, notches: look
  at hcad_lines). When hcad_fit takes away little, or moves a size away
  from what an exact section measures, the shape differs, not the sizes:
  cut sections elsewhere, off the axis too (a step that drops towards the
  sides is often turned round an axis; hcad_features names it).
- Parts printed and shared online have habits to look for: notches on top
  of sideways holes, a layer closing a hole for a millimetre (printed over,
  drilled after), teardrop points cut flat at an angle that is not 45°
  (read it from the section, not teardrop()), nut traps wider at the mouth,
  0.5 mm chamfers where holes open.

## Before saying it is done
- No errors and no warnings (an under-constrained sketch's warning counts);
  the sizes match the request; reference parts fit, with no unwanted
  overlap ((a & b).volume); printability looked at if it is to be printed;
  the pictures actually looked at.
- Say what was not checked (a fit that needs a test print, a size guessed).
- Say it briefly, and name the @params the user can change to try variants.

## Showing and asking with annotations (hcad_gui_annotate)
- Use them to ask and to answer, not only words: "is this the face you
  mean?" (an arrow on it), "the wall is 0.8 mm here" (a cross and a
  label), "should the hole go here or here?" (two numbered crosses, and the
  question in the chat with the same numbers). When an answer is about a
  place on the model, show it.
- Turn and frame the view first, so it can be understood: the part of
  interest in sight, not hidden behind another, seen from a side that
  makes it recognisable, with enough around it to tell where it is on the
  part (not zoomed so close that it is unclear what it is, nor so far that
  the detail is lost); one view per question if needed. Annotations lock
  the view: frame it, then annotate.
- Unless the user asks otherwise: arrows, crosses and circles in a colour
  that stands out in that view, against the part's colour and the
  background (not the part's own colour: red or magenta on a sky-blue part,
  blue or black on a red one); short labels, off the part; few marks at a
  time, one per thing to point at.
- When the user says "here", "this", "from here to there", or asks you to
  look at the marks: read them in hcad_gui_state, not in a screenshot.
  Each point has the part, face, point in mm and selector under it; a
  point on the background has points_at, the surface the mark points at
  (ahead of an arrow, or the nearest round it) and how many pixels away;
  each mark has colour_name beside its hex (the default magenta is often
  called purple or violet). A screenshot only for what the data cannot
  tell: the shape of a line drawn by hand, a mark with nothing under it
  and no points_at. If in doubt, confirm what you understood with a mark
  of your own before changing the model.
- When they have served, clear your marks (clear: "agent", or mode: false):
  while any are there the view stays locked and changes to the model do not
  show. Do not clear the user's marks without asking.

The full reference: `hcad docs` (llms-full.txt).
