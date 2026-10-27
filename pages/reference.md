# The hackerscad language

A model is a text file, `.hcad`, written in a small scripting language with a C-style syntax: braces, semicolons, `if` and `for`, functions with typed parameters. If you have written C, Java, C# or JavaScript you can read it already. It runs inside hackerscad, in a sandbox, and the model is evaluated again in milliseconds after every change. Much of it is inspired by [D](https://dlang.org), whose syntax it borrows.

This page explains how the language works. The [guides](/guides/) explain each kind of shape at length, with pictures, and the [cheatsheet](/cheatsheet.html) lists every function in one line.

## A model at a glance

```d
// a box with a lid, its size changed from the side panel
import std;

@param("Width", min: 20.mm, max: 120.mm)
immutable width = 60.mm;

immutable thickness = 2.mm;

Solid openBox(Length height)
{
    return box(width, 40.mm, height)
        .fillet(edges.parallel(Z), r: 4.mm)
        .shell(open: faces.top, thickness: thickness);
}

@part("Sky Pop")
Solid base()
{
    return openBox(30.mm);
}

unittest
{
    assert(base.bbox.size.x <= 120.mm, "too wide for the printer");
}
```

- `import std;` brings in the built-in libraries: shapes, screws, threads, gears and the rest.
- `@param` puts **Width** in the side panel, with its limits; the model is evaluated again when you change it.
- `immutable` declares a constant. Lengths carry their unit: `60.mm`.
- `Solid openBox(Length height) { … }` is a function: typed parameter, typed result, a `return`.
- `@part` marks a function whose result is a part: it is drawn in the 3D view and exported.
- `unittest` holds checks on the design, run after the model is built.

## Values and types

| Type | Written | Notes |
|---|---|---|
| number | `42`, `2.5`, `1_000`, `0xFF` | whole and fractional numbers mix freely |
| `Length` | `60.mm`, `2.5.cm`, `1.inch` | a number with a unit |
| `Angle` | `30.deg`, `0.5.rad` | |
| `bool` | `true`, `false` | |
| `string` | `"Hello"` | see [Strings](#strings-and-output) |
| `Vec` | `vec(10.mm, 5.mm)`, `vec(x, y, z)` | `.x`, `.y`, `.z`, `.length`, `.normalized` |
| array | `[1, 2, 3]`, `[box(1, 1, 1), sphere(2)]` | one type per array |
| `Solid`, `Profile`, `Path` | `box(…)`, `circle(…)`, `helix(…)` | a 3D body, a flat shape, a curve |

### Units

Write the unit on every length and angle. The arithmetic keeps track of them: a length times a length is an area, and adding a length to an angle is an error, caught before anything is built.

```d
immutable side = 40.mm;
immutable area = side * side;        // an Area: 1600 mm²
immutable diagonal = side * sqrt(2); // still a Length
```

A plain number passed to a shape is taken as millimetres, so `box(40, 20, 10)` works. Mixing a plain number with a length in a sum is an error, because it is usually a mistake: write `60.mm + 5.mm`, not `60.mm + 5`. To get the plain number back, `side.to!double` gives `40` (millimetres).

## Variables

```d
immutable height = 30.mm;   // a constant, at the top of the file

Solid stack()
{
    auto total = 0.mm;      // a variable, inside a function
    Solid s;                // an empty solid, to add to
    foreach (i; 0 .. 3)
    {
        s += box(20, 20, 10).move(z: total);
        total += 10.mm;
    }
    return s;
}
```

- At the top of the file, declarations are constants. Use `immutable`.
- Inside a function, `auto x = …` declares a variable whose type is the value's, like `var` in Java or `let` in JavaScript. A type can be written instead: `Length total = 0.mm;`.
- Values are copied, never shared: `b = a; b[0] = 9;` leaves `a` as it was. The same holds for shapes: `s.move(x: 5.mm);` on its own changes nothing, it gives a moved copy. Write `s = s.move(x: 5.mm);`. hackerscad warns when a result is thrown away like that.

## Operators

| | |
|---|---|
| arithmetic | `+ - * / %`, and `^^` for a power: `r ^^ 2` |
| comparison | `== != < <= > >=` |
| logic | `&& \|\| !`, and `cond ? a : b` |
| assignment | `= += -= *= /= %= ~= ++ --` |
| joining | `~` joins arrays, or anything with a string: `"side " ~ width` |
| shapes | `a + b` union, `a - b` difference, `a & b` intersection |

```d
@part
Solid plate()
{
    auto p = box(60, 40, 4);
    p -= cylinder(d: 5, h: 10).move(x: 20, y: 12);   // a hole
    return p & sphere(d: 70).move(z: -10);           // keep what is inside the sphere
}
```

## Control flow

```d
Solid row(int n, bool round)
{
    Solid s;
    foreach (i; 0 .. n)                  // i from 0 to n - 1
    {
        if (i % 2 == 1)
            continue;
        s += (round ? cylinder(d: 8, h: 4) : box(8, 8, 4))
            .move(x: i * 12.mm);
    }
    return s;
}
```

- `if` / `else`, `while`, `for (int i = 0; i < n; i++)`, `break`, `continue`, `switch` with `case a, b:` and `default:`, as in C.
- `foreach (i; 0 .. n)` counts from 0 to n − 1.
- `foreach (x; list)` goes through an array, `foreach (i, x; list)` with the index too.
- A condition is a `bool`. A length or a solid is not true or false by itself: compare it, `if (width > 50.mm)`.

## Functions

```d
// parameters with types, one with a default value
Solid peg(Length d, Length h = 10.mm)
{
    return cylinder(d: d, h: h).chamfer(edges.of(faces.top), d: 0.5.mm);
}

@part
Solid pegs()
{
    return peg(6.mm) + peg(d: 8.mm, h: 20.mm).move(x: 15.mm);
}
```

- Parameters and results have types: `Solid`, `Profile`, `Length`, `int`, `bool`, `string`… A wrong type is an error that says where.
- Arguments can be named: `peg(d: 8.mm, h: 20.mm)`, in any order, as in Python or Kotlin.
- A parameter with a default can be left out.
- A call can be written as a method on its first argument: `peg(6.mm)` is also `6.mm.peg()`, and that is how shapes chain: `box(…).fillet(…).shell(…)`.
- A function whose arguments all have defaults can be called without parentheses: `body.bbox`, `body.volume`.

### Functions as values

```d
immutable sizes = [4.mm, 6.mm, 8.mm];
immutable big = sizes.filter(d => d > 5.mm);      // [6 mm, 8 mm]
immutable holes = sizes.map(d => cylinder(d: d, h: 10));
```

`x => expression` is a small function, like an arrow function in JavaScript; `(a, b) => a + b` takes two. A longer one is written with braces: `(Length d) { return d * 2; }`. Functions are passed like any other value, to `map`, `filter`, `sort`, and to features that take one, such as a sweep that changes size along the way.

## Arrays

```d
unittest
{
    auto xs = [10.mm, 20.mm];
    xs ~= 30.mm;              // append
    writeln(xs.length);       // 3
    writeln(xs[1 .. $]);      // [20 mm, 30 mm]: a slice, $ is the length
    writeln(xs.sum);          // 60 mm
}
```

An array holds values of one type. `a[i]` reads an element, `a[i .. j]` a slice, `~` joins two arrays. Arrays of solids are common: `parts.sum` unites them, and `plate - holes` takes a whole array of holes away at once, much faster than one at a time.

## Strings and output

```d
unittest
{
    auto v = box(10, 20, 30).volume;
    writeln("volume: $(v)");       // volume: 6000 mm^3
    writeln(box(30, 20, 10));      // Solid 30 × 20 × 10 mm, volume 6000 mm³
}
```

`"…"` strings insert the value of `$(expression)`, like template strings in JavaScript. `writeln` prints to hackerscad's console, from a function or a `unittest` (the top of a file holds only declarations); a shape prints as a short summary, `Solid 30 × 20 × 10 mm, volume 6000 mm³`. Backtick strings `` `…` `` are taken as they are, with no `$(…)` and no escapes.

## Structs

```d
struct Slot
{
    Length width = 6.mm;
    Length length = 20.mm;

    Profile shape()
    {
        return slot(length, width);
    }
}

immutable wide = Slot(width: 10.mm);
```

A `struct` groups values under one name, with default values and methods. It is created like a function call, with positional or named fields: `Slot(10.mm, 30.mm)` or `Slot(width: 10.mm)`. There are no classes and no inheritance.

## Parameters, presets and parts

| | |
|---|---|
| `@param("Label", min:, max:, step:)` | a constant you can change from the side panel, the command line (`-D width=80.mm`) or an agent; `choices: ["a", "b"]` for a list |
| `@preset("name", value)` | the parameter's value in a named set of values, chosen from the panel or with `--preset name` |
| `@part("colour")` | the function's result is a part: drawn, exported as its own object |
| `@part("slategray", alpha: 0.35, export: false)` | a see-through reference part, not exported: the object your part must fit |
| `@parts` | a part for each separate body the function returns |

```d
@param("Diameter", min: 50.mm, max: 100.mm)
@preset("espresso", 60.mm)
immutable diameter = 80.mm;
```

Colours are CSS names (`"steelblue"`) or hackerscad's own bright ones, offered by the 3D view: `"Sky Pop"` (the default), `"Pink Pop"`, `"Yellow Pop"` and the rest.

## Checks: unittest and assert

```d
unittest
{
    assert(wall >= 1.2.mm, "walls under 1.2 mm leak");
    assert((lid & base).volume < 0.01.mm ^^ 3, "the lid runs into the base");
}
```

`unittest` blocks hold what the design must do. They run after the model is built: the command line runs them every time, the window when you ask (F5) and before an export. A failed `assert` shows its message, so write it as the problem: "the lid runs into the base", not "the lid fits".

## Modules and libraries

```d
import std;                       // every built-in library
import std.hardware : M3, hole;   // only these names
import parts.bracket;             // parts/bracket.hcad, next to the model
```

The built-in libraries cover screws and holes, threads, gears, hinges, snaps, enclosures, joints, moulds and more: see the [guides](/guides/). A file of your own is a module: `import bracket;` loads `bracket.hcad` from the model's folder or from your personal library folder. Names declared `private` stay inside their module.

## The sandbox

A model can only make shapes. It cannot read or write files, use the network or start programs, so a model from anyone is safe to open. `load("part.stl")` reads a mesh, STEP or drawing file, from the project's folder only. The number of steps, the depth of recursion and the size of arrays are limited, so a mistake stops with an error instead of hanging.

## What is not there

No classes, no pointers, no exceptions, no `new`. Every value is a value, and every function gives the same result for the same arguments: that is what lets hackerscad rebuild only what changed.

## Where next

- [Tutorial](/tutorial/): a first model, step by step, mostly with the mouse.
- [Guides](/guides/): each subject at length, with pictures.
- [Cheatsheet](/cheatsheet.html): every function in one line.
- In the application: **Examples › Language tour**, one model that uses each construct once.
