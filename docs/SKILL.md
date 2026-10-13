---
name: hackerscad
description: Official reference for hackerscad, the parametric CAD where models are .hcad files (a sandboxed subset of D) exported as STL, 3MF, STEP and drawings. Use it whenever the user asks to model, modify, check or export a 3D part with hackerscad, works on .hcad files, or wants hackerscad installed or updated.
---

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

This text was made by hcad 0.3.1 (docs stamp `0.3.1-c45e28db`). Before the first
model of a session, run `hcad docs --stamp` (`hcad` may be a full path, or the
AppImage followed by the word `hcad`; with the MCP server, hcad_docs with
format stamp):

- **It prints `0.3.1-c45e28db`:** this text is up to date.
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
  hcad_drawing (.pdf .svg .dxf). When the user has the application open, the
  hcad_gui_* tools drive it (open, edit the code, set parameters, move the
  view, pick faces, select and measure, context menu, section plane, rollback,
  inspect (the solids and 2D profiles a line or function makes), save,
  screenshot, state), so they see what you do. Points can be given in
  model millimetres (hcad_gui_project converts them). Each window has a name
  in its header bar; with several open, hcad_gui_windows lists them and the
  user may tell you which one ("work in blue-otter").
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
  as lines, arcs and circles, and as a sketch ready to extrude;
  `hcad compare model.hcad --a clone --b original -o map.png` (hcad_compare)
  how far the remodelled part is from the mesh, with a coloured map and
  the surface patches that do not match; `hcad diff` (hcad_diff) the
  material to add or cut; `hcad lines` (hcad_lines) both drawn as lines
  from many sides, the lines only one has (chamfers, countersinks,
  letterings: what the eye sees first; once the outside matches,
  `--depth MM` peels both, `--voids` compares the holes made solid;
  violet marks surface facing otherwise: twisted, curved); `hcad scan`
  (hcad_scan) holes and pockets along
  an axis; `hcad fit` (hcad_fit) tunes @param lengths to the original.
  `--printability` adds per part the overhangs needing supports and the
  walls too thin to print (marked in the pictures: red stripes, violet
  hatching); with the window, `hcad_gui_view` style `printability`.
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
      @part("slategray", alpha: 0.4, export: false)
- Lengths: write units (60.mm, 2.5.cm, 1.inch). Bare numbers passed to
  geometry are millimetres. Never add a bare number to a length (60.mm + 5 is
  an error; write 60.mm + 5.mm).
- Angles: rotate(z: 45) uses degrees; 30.deg is explicit.
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
  to the edge.
- To round or chamfer the edges a cut left behind, select them by provenance:
  .fillet(edges.between(faces.from(holes), faces.top), r: 0.5.mm).
- Cut with planes: body.split(body.plane(faces.top).offset(-10.mm)) gives
  .above and .below; s.pieces lists separate bodies, ordered along X, Y, Z.
- Profiles: rect, circle, polygon, regularPolygon, slot, text, combined
  with + - &, .round(r), .offset(d); turn them into solids with .extrude(h)
  or .revolve(axis: Y). On a face: body.extrude(profile, on: frame, depth:)
  adds, body.cut(profile, on: frame, depth: | through: true) removes.
- Sweeps and lofts: circle(d: 4.mm).sweep(path([vec(0, 0, 0), vec(0, 0, 30),
  vec(30, 0, 30)])), circle(d: 1.mm).sweep(helix(r: 5.mm, pitch: 2.mm,
  height: 20.mm), frenet: true), loft([circle(r: 20), rect(25).move(z: 40)]).
- Exact 2D outlines with dimensions: auto s = sketch(); points, lines, arcs,
  circles, then constraints (horizontal, vertical, length, distance, angle,
  tangent, equal…) and s.profile. Prefer it when a request gives dimensions
  of an irregular outline; a warning lists points left free.
- To build on a face, take its frame and place parts built on XY (Z up):
  cylinder(d: 8.mm, h: 5.mm).placeOn(body.frame(faces.top).at(x: 10.mm)).
- Axes and planes anywhere: rotate(90.deg, axis: body.axis(edges.filter(e =>
  e.isCircle && e.radius == 3.mm))), s.mirror(plane(origin: vec(10, 0, 0),
  normal: X)), plane(p1, p2, p3), plane(axis, point).
- Existing parts: load("part.stl"/".obj"/".3mf"/".step", scale: 1) gives a solid to
  modify; text("LABEL", size: 4.mm).centered centres a profile for engraving.
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
  call, the line starting with the dot.

The full reference: `hcad docs` (llms-full.txt).
