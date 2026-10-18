# Joints between parts

A part too long for the printer's bed, cut in two pieces that lock together with no screws and no glue, as joiners join timber: tenons, dovetails, pins, finger joints, half laps, the gooseneck and the wedged scarf of Japanese carpentry. The `joints` library cuts a solid along a plane and shapes both sides of the cut.

<!-- render: joints-kinds --from 0.6,-1,0.5 -->
```d
// a beam 20 mm square cut with each kind of joint, the
// two pieces pulled apart to show it

import joints;

Solid shown(int i)
{
    auto beam = box(20.mm, 20.mm, 120.mm);
    auto middle = plane(origin: vec(0.mm, 0.mm, 60.mm),
        normal: Z);
    auto j = splitJoint(beam, middle, kind: jointKinds[i],
        count: 4);
    auto s = j.a + j.b.move(z: 30.mm);
    foreach (l; j.loose)
        s += l.move(y: 30.mm, z: 15.mm);
    return s.move(x: i * 40.mm);
}

@part("Sky Pop")
Solid tenon() => shown(0);

@part("Pink Pop")
Solid dovetail() => shown(1);

@part("gold")
Solid pins() => shown(2);

@part("mediumseagreen")
Solid fingers() => shown(3);

@part("Sky Pop")
Solid lap() => shown(4);

@part("Pink Pop")
Solid kama() => shown(5);

@part("gold")
Solid kanawa() => shown(6);
```

![Tenon, dovetail, pins, fingers, half lap, gooseneck and wedged scarf, each pulled apart](img/joints-kinds.png)

## Cutting with a joint

`splitJoint(body, plane, kind:)` cuts `body` along the plane and gives a `Joint`:

- `.a`, the piece behind the plane (against its normal), with what pushes into the other;
- `.b`, the piece in front of it, with the hollow it fits in;
- `.loose`, the parts printed apart that lock it: the wedge of a `"kanawa"`.

The joint sits in the middle of the cut. Its size follows the cut: by default it is the square root of the section's area, the width of a square beam, so the same call suits a thin rod and a thick post. The hollows are `clearance` larger all round (0.2 mm unless given), so the pieces go together without forcing: see [Fits and printing](fits.md) to choose it for your printer.

| Kind | What it is | Goes together | Holds against |
|---|---|---|---|
| `"tenon"` | a rectangular tenon in a mortise (hozo) | pushed straight in | bending; glue or a pin for pulling |
| `"dovetail"` | a tail widening into the other piece (ari) | slid in from the side | pulling apart |
| `"pins"` | round pins in holes (`count:` of them) | pushed straight in | bending and twisting |
| `"fingers"` | a finger (box) joint, the fingers of each in turn (`count:`) | pushed straight in | bending; a wide gluing surface |
| `"lap"` | a half lap (ai-gaki): each piece keeps half the thickness | laid on each other | bending one way |
| `"kama"` | a gooseneck (kama tsugi): a neck and a wider head | dropped in from the side | pulling apart |
| `"kanawa"` | a half lap with a hook at each end, locked by a wedge (kanawa tsugi) | laid on, then the wedge driven through | pulling, bending and twisting |

| Argument | What it does |
|---|---|
| `kind:` | one of the kinds above (`jointKinds` lists them) |
| `clearance:` | the play where the pieces meet, 0.2 mm unless given |
| `size:` | the joint's scale, instead of the square root of the section's area |
| `length:` | how far it reaches across the cut, 0.6 of the size unless given |
| `turn:` | turns it about the plane's normal: which way a dovetail or a gooseneck slides in |
| `count:` | the number of pins or fingers |

## A rail longer than the bed

A rail 300 mm long does not fit a printer of 220 mm. Cut in the middle with a gooseneck it prints in two pieces, each lying on its flat side, and drops together from above:

<!-- render: joints-rail --from 0.3,-1,1.2 -->
```d
// a rail 300 mm long in two pieces joined by a
// gooseneck, shown a little apart

import joints;

@param("Play in the joint", min: 0.1.mm, max: 0.5.mm)
immutable play = 0.2.mm;

Solid rail() => box(300.mm, 30.mm, 12.mm)
    .fillet(edges.parallel(X), r: 2.mm);

// the cut across the middle: the neck runs along X,
// and the pieces drop together from above
Joint pieces() => splitJoint(rail(),
    plane(origin: vec(0.mm, 0.mm, 6.mm), normal: X),
    kind: "kama", size: 24.mm, length: 30.mm,
    clearance: play);

@part("Sky Pop")
Solid left() => pieces().a;

@part("Pink Pop")
Solid right() => pieces().b.move(x: 8.mm);
```

![A rail in two pieces joined by a gooseneck](img/joints-rail.png)

`size:` and `length:` are given here: the rail is wide and flat, and the square root of its section would make a neck too wide for it. `turn: 90.deg` would stand the gooseneck the other way, to slide in from the side instead of from above: try it and look at the picture.

## The wedged scarf

The kanawa tsugi of Japanese carpentry joins two beams end to end in a half lap with a hook at each end; a wedge driven through the middle pushes the hooks against each other, and the joint becomes as stiff as the beam. The wedge is a loose part, printed apart, tapering 1 in 20: it goes in by hand and is tapped home.

<!-- render: joints-kanawa --from 0.8,-1,0.6 -->
```d
// a post joined end to end with a wedged scarf: the
// two halves and the wedge, a little apart

import joints;

Solid post() => box(25.mm, 25.mm, 160.mm);

Joint scarf() => splitJoint(post(),
    plane(origin: vec(0.mm, 0.mm, 80.mm), normal: Z),
    kind: "kanawa");

@part("Sky Pop")
Solid lower() => scarf().a;

@part("Pink Pop")
Solid upper() => scarf().b.move(z: 12.mm);

@part("gold")
Solid wedge() => scarf().loose[0].move(y: -25.mm, z: 6.mm);
```

![A post joined with a wedged scarf, the wedge beside it](img/joints-kanawa.png)

## Printing joints

- Lay each piece so that what holds the joint lies along the layers, not across them: a tenon or a pin printed standing up snaps off along a layer. The rail above prints lying flat, its neck along the bed.
- A dovetail, a gooseneck and a scarf print flat on the side they slide on: their walls stand upright, with no overhang.
- Print a short sample of the joint first, both pieces, and adjust `clearance` (a `@param`): 0.1 to 0.15 mm on a well-tuned printer for a tight fit, 0.3 mm for one that goes together easily.
- The first layers spread a little (the *elephant's foot*): a hollow touching the bed comes out tight at its mouth. A 0.4 mm chamfer round it, or a slightly larger clearance, takes care of it.
- PLA joints hold well dry; tight ones in PETG creep less over months under load.

## Common errors

| Message | What to do |
|---|---|
| *the joint kind is one of tenon, dovetail, pins, fingers, lap, kama, kanawa* | a kind from the list |
| one piece comes out in two bodies | the plane cuts through two separate parts of the solid (both jaws of a clip): cut where the section is one piece |
| the joint is too big for a flat part | the size follows the section's area: give `size:` (and `length:`) |
| the pieces do not go together | the joint slides the wrong way for how you want to assemble them: `turn: 90.deg` |
| *undefined identifier 'splitJoint'* | `import joints;` |

## In the application

- The parts of a joint are ordinary parts: make one of each piece with `@part`, and export them to print each in its own colour, or together on one bed.
- To see the fit, move one piece onto the other in the code (or drag it): the [section](planes.md) through the joint shows the play all round.
