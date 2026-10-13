[← Install](01-install.md) · [Contents](../TUTORIAL.md) · [The first block →](03-the-first-block.md)

# 2. The window

Before building anything, a tour of the window: what each part is for. The
bag clip is still open; we use it to try things.

![The parts of the window](img/02-window.png)

1. **The view.** The model as the code describes it. Drag with the right
   button to turn it, with the middle one to move it, and use the wheel to
   zoom. Clicking a face selects it and highlights the line of code that made
   it; right-clicking opens the things you can do there.
2. **The view bar.** The views (Fit, Iso, Top, Front, Right); how a left drag
   moves the view; the eye, to hide or show the parts; the cube, to choose how
   the parts are drawn; the section, to cut the model and look inside; the
   magnifying glass, to see what a line of code makes.
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
in the rest of this tutorial). The buttons at the top right show or hide
the console, the code, the view and the parameters (Ctrl+J, F7, F8, F9). The
menu (☰) has New, Open, Save As,
Export, the Cheatsheet, this tutorial, and the style: light, dark, or as the
system is set.

## Change a size

In **Parameters**, find **teeth** ("Teeth per jaw") and click **+**: the clip
gets one more tooth on each jaw. The code does not change: parameters are
values you try on the model. **Reset to defaults** brings back the ones in the
code, and the **preset** menu at the top chooses ready-made sets of values
(here *small* and *large*).

## How the parts are drawn

The cube in the view bar opens a small menu:

![The display menu](img/02-display-menu.png)

- **Shaded with edges**, the usual way; **Shaded**, without the edges;
  **Wireframe**, only the edges, the hidden ones fainter: useful to see
  inside.
- **Perspective**, as a photo; **Orthographic**, where sizes do not change
  with the distance: the Front, Top and Right views become true drawings.

## The cheatsheet

Press F1: a window lists everything the language has, one line each, with
recipes for common tasks ("hole", "copy", "round"). Type in its search field to
filter it. You will not need it in this tutorial, but it is there when you
want to write a model of your own.

## Check

The clip has four teeth per jaw.

![The clip with four teeth](img/02-final.png)

[← Install](01-install.md) · [Contents](../TUTORIAL.md) · [The first block →](03-the-first-block.md)
