[← Let an AI agent help](11-ai-agents.md) · [Contents](../TUTORIAL.md)

# 12. Going further

The planter used boxes, the mouse, profiles, loops and checks. hackerscad has
more; here is a short tour, each part with an example to paste into a new
file. The [language reference](../LANGUAGE.md) describes everything, and the
[examples](../../examples) are complete models to open and change.

## Constrained sketches

For outlines defined by relations rather than coordinates ("this side is
vertical, that one 30 mm long"), draw a **sketch**: points and lines, then the
constraints, and hackerscad works out the positions.

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

The pencil button in the view bar shows the sketch with its dimensions:
click one to change it. Points still free to move are blue.

## Sweeps and lofts

`loft([…])` passes smoothly through outlines at different heights (a vase);
`.sweep(path)` moves an outline along a curve (a handle, a pipe, a spring).

```d
module jug;

import std.shapes;

@part("orange")
Solid jug()
{
    auto body = loft([
        circle(r: 20.mm),
        circle(r: 26.mm).move(z: 40.mm),
        circle(r: 12.mm).move(z: 80.mm),
    ]);
    auto vase = body.shell(open: faces.top, thickness: 2.mm);
    auto curve = spline([
        vec(12.mm, 0.mm, 72.mm), vec(30.mm, 0.mm, 74.mm),
        vec(40.mm, 0.mm, 52.mm), vec(24.mm, 0.mm, 30.mm),
    ]);
    auto handle = circle(d: 7.mm).sweep(curve);
    // the ends of the handle go into the wall: what would show inside goes
    return vase + handle - (body - vase);
}
```

## Libraries: screws, threads, gears, enclosures

```d
module fixings;

import std.shapes;
import hardware;
import gears : spurGear;

@part
Solid lid()
{
    auto l = box(50.mm, 50.mm, 6.mm);
    // tools to take away: their top is on z = 0, going down
    l -= hole(M3, 6.mm, "counterbore").move(x: -15.mm, z: 6.mm);
    l -= hole(M3, 6.mm, "insert").move(x: 15.mm, z: 6.mm);
    l -= nutTrap(M3, 3.mm).move(y: 15.mm, z: 6.mm);
    return l;
}

@part("orange")
Solid gear() => spurGear(1.5.mm, 24, 6.mm, bore: 5.mm).move(x: 70.mm);
```

- `hardware`: screw sizes `M2` to `M8`, screws, nuts, washers, and holes made
  for them (`"clearance"`, `"tap"`, `"insert"`, `"counterbore"`,
  `"countersink"`).
- `threads`: real ISO threads; `gears`: gears and racks; `hinges`, `snaps`,
  `enclosures`: print-in-place hinges, snap-fit hooks, boxes with lids.
  [examples/library.hcad](../../examples/library.hcad) shows them all.
- Your own functions go in a file next to the model (`lib/name.hcad`, then
  `import lib.name;`), or in your personal library folder, to use them in
  every project.

## Reference parts

A part that is only there to check the fit, see-through and left out of the
exports:

```d
@part("slategray", alpha: 0.35, export: false)
Solid bottle() => cylinder(d: 13.6.mm, h: 60.mm).move(z: 4.mm);
```

[examples/knob.hcad](../../examples/knob.hcad) is a knob on the shaft of a
potentiometer, drawn this way.

## Technical drawings

A function marked `@drawing` makes a sheet with views, dimensions and
sections, to export as PDF, SVG or DXF. Added at the end of the planter, this
one draws the tank:

```d
@drawing
Drawing sheet()
{
    auto d = drawing(title: "Tank", material: "PETG");
    d.standardViews(tank);
    d.section(tank, XZ, label: "A");
    return d;
}
```

## The command line

`hcad` does what the window does, without it: useful for scripts and for
exporting many sizes at once.

```sh
hcad check planter.hcad                       # parts, sizes, checks
hcad render planter.hcad -o planter.3mf       # export
hcad render planter.hcad -o planter-views.png # a picture from four sides
hcad render planter.hcad -o basil.3mf --preset basil
hcad render planter.hcad -o big.3mf -D size=90.mm
hcad docs fillet                              # the reference of one function
```

## When something goes wrong

- **A red underline and a banner over the view:** the code has a mistake. The
  message says what and where, and often how to fix it ("did you mean `r`?").
  Click the banner to go to the line. Meanwhile the view keeps the last model
  that worked.
- **A rounding or a shell fails:** try a smaller radius, fewer edges at a
  time, or a different order (round first, then shell).
- **The model is slow:** threads, text on curved faces and roundings on many
  edges take the longest. hackerscad remembers every step, so changing a
  parameter recomputes only what depends on it.
- **"Unknown argument":** the message lists the arguments the function takes;
  `hcad docs` and the cheatsheet (F1) describe each function.

[← Let an AI agent help](11-ai-agents.md) · [Contents](../TUTORIAL.md)
