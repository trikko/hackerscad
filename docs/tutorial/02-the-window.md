[← Install](01-install.md) · [Contents](../TUTORIAL.md) · [The first block →](03-the-first-block.md)

# 2. The window

Before building anything, a tour of the window: what each part is for. The
bag clip, Carlo, is still open; we use it to try things.

![The parts of the window](img/02-window.png)

1. **The view.** The model as the code describes it. Drag with the right
   button to turn it, with the middle one to move it, and use the wheel to
   zoom. Clicking a face selects it and highlights the line of code that made
   it; right-clicking opens the things you can do there, among them
   **Move…** and **Rotate…**: drag the X, Y and Z arrows (or the frame
   under the part, across), or the knobs of the three rings round it, one
   after the other; the bar reads how far, and the ✓ next to the part
   writes one `.move()` or one `.rotate()` into the code (the X leaves it
   as it was). **Scale…** works the same way: drag the X, Y or Z handle to
   stretch the part along that axis, or the knob at the corner of its box to
   scale it all alike; the middle of its bottom stays where it is, so a part
   on the ground stays on it, and the ✓ writes one `.scale()`. With a face
   picked, **Rotate around its normal…** (its axis, for a round face) gives one ring around it; with an edge, **Rotate around
   this edge…** turns the part on it as on a hinge. **Place on…** carries
   a point of the face you clicked (a corner, the middle of an edge or of
   the face: the green point) onto one of another face, onto the origin or
   onto the ground: the two faces end up against each other, and a ring
   spins the part about them. When both faces are flat it writes a
   `placeOn` onto the other part's face (`.placeOn(vase().frame(faces.farthest(Z)), from: faces.bottom)`),
   so the part follows that face when the other part changes. **Split…** puts a plane as big as the part on it, moved like
   the section's: its ✓ cuts the part there into a part per piece
   (more than two when the plane crosses a slot), each in its colour. **Colour** offers
   hackerscad's own bright colours (Sky Pop, Pink Pop…), and writes the
   name of the one you pick into the part's `@part` (on one piece of a part
   split into pieces, on that piece alone; **Default colour of…** colours
   the others); **Other…** opens a
   wheel where every hue is as bright as those, the part showing each one
   until you Apply it (or Cancel). A double click on a flat face turns the
   view straight at it (**Look at face** in the menu does the same);
   **Sketch on face…** starts a sketch on it, and on a face a sketch made,
   **Edit sketch…** shows that sketch ([chapters 12](12-medal.md) and
   [15](15-going-further.md)).
2. **The view bar.** Fit, and the views in the **View** menu (Iso, Top,
   Front, Right, and **Sketches**, the model's sketches: one opens to be
   edited); four buttons for what a click picks, **whole parts, faces,
   edges or vertices** (Alt+1 to Alt+4; the choice is kept): the right-click
   menu offers what fits it, picked faces are striped, a picked part dotted;
   the eye, to hide or show the parts, the ground grid and
   the axes; the cube, to choose how the parts are drawn; the section, to cut
   the model and look inside (parallel to the face you picked, if any; drag
   the squares at the plane's corners to move it, the X past them closes it); the magnifying glass, to see what a line
   of code makes; the arrow at a ring, **Annotate** (A): the view stops
   still, to draw arrows, crosses, circles and text on it like on a
   screenshot, to show something or to tell an AI agent where (chapter
   11), and the two buttons by the colours save it as a picture or copy it,
   to paste in a message; **Done** (or Esc) brings the view back to life.
   With the cursor in a sketch's code the view shows that sketch by itself,
   with its dimensions, seen straight on (from above, or from outside the
   face it is drawn on): the pin in the bar keeps it there while you read
   other code, and **Look at sketch** in its right-click menu turns the view
   back onto it.
3. **Parameters and Steps.** Two tabs. *Parameters* has the sizes the model
   lets you change, without touching the code; *Steps* shows how the model is
   built, one step at a time.
4. **The code.** A model in hackerscad is a short text, written in a small
   language. You will rarely start from an empty page: the mouse writes most
   of it for you, and the few lines to type are given in this tutorial, ready
   to copy. Every change shows in the view while you type.
5. **The console.** What the model writes, its checks, and the messages of
   hackerscad itself (evaluated, saved, exported).

The buttons at the top left start a new model, open one, save it and export
it (Ctrl+N, Ctrl+O, Ctrl+S, Ctrl+E; on macOS, Cmd in place of Ctrl, here and
in the rest of this tutorial). **Examples** opens ready models to try:
Carlo, the bag clip, the espresso cup of the README, the planter this tutorial builds, a tour
of the language that shows `if`, `for`, `while`, `switch`, functions and
structs, each with what it makes appear, and more complete models. The buttons at the top right show or hide
the console, the code, the view and the parameters (Ctrl+J, F7, F8, F9); the
✕ at the top of the code, the console and the parameters hides them too
(with nothing else left, the view comes back). The
menu (☰) has New, Open, Save As,
Export, the Cheatsheet, this tutorial, and the style: light, dark, or as the
system is set.

## Change a size

In **Parameters**, find **Teeth per jaw** and click **+**: the clip
gets one more tooth on each jaw. The code does not change: parameters are
values you try on the model, and the code hands them to `carlo()`, which
draws the clip. A value you changed is marked with a dot, and the ↺ at the
end of its line brings back the one in the code; **Reset to defaults**
brings back all of them.

## How the parts are drawn

The cube in the view bar opens a small menu:

![The display menu](img/02-display-menu.png)

- **Shaded with edges**, the usual way; **Shaded**, without the edges;
  **Wireframe**, only the edges, the hidden ones fainter: useful to see
  inside.
- **Printability**, a check box over any of these styles, for 3D printing:
  what overhangs more than 45° and needs supports is striped red, walls
  thinner than 0.8 mm are cross-hatched violet; the two fields under it
  change the limits, and the status line gives the areas. On a part of a
  near colour these marks turn darker, and what marks a picked face turns
  blue on a yellow or orange part, so that they always show.
- **Perspective**, as a photo; **Orthographic**, where sizes do not change
  with the distance: the Front, Top and Right views become true drawings.
- **Show the sketch at the cursor**: on, the view shows the sketch whose
  code the cursor is in ([chapter 12](12-medal.md)); off, only its step in
  *Steps* or the magnifying glass do. The choice is kept.
- **Shine**: **None**, matte, each flat face one even tone; **Normal**, a
  small highlight on curves; **High**, a shiny material with soft highlights
  on every curve. The choice is kept.
- **Smooth edges**, under *Quality*: edges and curves without steps. It asks
  more of the graphics card: turn it off if turning the view is slow. The
  choice is kept.

## Editing the code

The editor has the keys of a code editor:

- **Ctrl+F** opens a bar over the code to find text: every match is marked,
  it says which one is selected ("2 of 3"), **F3** and **Shift+F3** (or Enter
  and Shift+Enter) go to the next and the previous; **Aa** matches case,
  **ab|** whole words only, **.\*** takes a regular expression. **Ctrl+H**
  adds a row to replace the selected match or all of them (one Ctrl+Z
  undoes it). Esc closes it.
- **Ctrl+L** goes to a line; **Ctrl+/** comments the selected lines out with
  `//`, or back in; **Ctrl+D** duplicates the line (or the selection);
  **Ctrl+Shift+K** deletes the lines; **Alt+Up** and **Alt+Down** move them;
  **Tab** and **Shift+Tab** indent them in and out.
- Brackets and quotes close themselves: type `(` and `)` comes after the
  cursor, type it again and the cursor steps over it; around a selection they
  enclose it. The bracket matching the one at the cursor is marked.

## Keys and mouse

- **The view:** right drag (or Shift and the left button) turns it, middle
  drag (or Ctrl and the left or right button) moves it, the wheel zooms; F6
  frames the model; each click adds what is under the pointer to what is
  picked (clicked again, it leaves), a left drag a box of them (what is
  wholly inside it; dragged from right to left, what it touches too), a
  click on nothing, Esc or Space empties it; a right-click opens the
  menu; a double
  click on a flat face looks straight at it; Alt+1 to Alt+4 choose what a
  click picks (parts, faces, edges, vertices); **A** annotates the view; Esc
  closes what is shown over the model (a sketch, a step, the marks).
- **The window:** Ctrl+N, Ctrl+O, Ctrl+S and Ctrl+E new, open, save and
  export; Ctrl+J, F7, F8, F9 show or hide the console, the code, the view
  and the parameters; Ctrl+I shows what the line at the cursor makes; F5
  runs the model's `unittest` checks; F1 opens the cheatsheet.
- **The code:** the keys of the list above (Ctrl+F, Ctrl+H, Ctrl+L, Ctrl+/,
  Ctrl+D…); Ctrl+click on a line shows what it makes, in the view.

## The cheatsheet

Press F1: a window lists everything the language has, one line each, with
recipes for common tasks ("hole", "copy", "round"). Type in its search field to
filter it. You will not need it in this tutorial, but it is there when you
want to write a model of your own.

## Check

The clip has four teeth per jaw.

![The clip with four teeth](img/02-final.png)

[← Install](01-install.md) · [Contents](../TUTORIAL.md) · [The first block →](03-the-first-block.md)
