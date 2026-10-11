# hackerscad Model Exception, version 1.0

hackerscad is free software, licensed under the GNU General Public License
version 3 ([LICENSE](LICENSE)). This exception is an additional permission
under section 7 of that license. It makes sure the license of hackerscad
does not extend to the models you write with it, nor to what hackerscad
makes from them.

## Definitions

- **hackerscad** is the software in this repository: the applications, the
  language, its built-in functions and objects, and the libraries that come
  with it (the `.hcad` modules in `lib/`, such as `hardware`, `threads` and
  `gears`).
- A **model** is a program or a file written to be run by hackerscad (for
  example a `.hcad` file), together with the data and the files it imports.
- **Output** is what hackerscad produces from a model: meshes (STL, 3MF),
  solids (STEP), images (PNG), drawings (SVG, PDF, DXF), and the text and
  data it prints or reports.

## Additional permission

1. **Models.** A model is not a work based on hackerscad because it is
   written in hackerscad's language, calls its functions, imports the
   libraries that come with it, or is run, checked or rendered by hackerscad.
   You may use, modify and distribute your models under terms of your choice.

2. **Output.** You may use and distribute output under terms of your choice,
   including in commercial products, even when it contains geometry, data or
   text produced by hackerscad's code or by its libraries (a screw from
   `hardware`, a thread from `threads`, a gear from `gears`).

## Limits

- This exception does not cover hackerscad itself. hackerscad, modified
  versions of it, and works based on it, including modified copies of its
  libraries, remain under the GNU General Public License version 3.
- Source code copied out of hackerscad's libraries into a model is still
  hackerscad's code and remains under its license; importing a library
  instead of copying it keeps your model free of it.
- Files a model imports that you did not write (meshes, STEP files, other
  people's modules) keep their own licenses.

When you distribute a modified version of hackerscad you may keep this
exception for your version or remove it.
