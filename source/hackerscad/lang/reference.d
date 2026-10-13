/// What every built-in name is: its arguments, what it applies to and one
/// line of documentation. The editor's completion and hover help read it;
/// a test checks that every built-in of the prelude is described here.
module hackerscad.lang.reference;

enum RefKind
{
    function_,   /// called by name: box(…)
    method,      /// called after a dot (UFCS): s.fillet(…)
    property,    /// read after a dot: s.volume
    keyword,
    unit,        /// 60.mm
    constant,    /// X, XY, PI
    type,
    annotation,  /// @part
}

struct Ref
{
    string name;
    /// For methods and properties, what they apply to: Solid, Profile,
    /// Shape (both), Path, Frame, Plane, Axis, Vec, BBox, Edges, Faces,
    /// Edge, Face, list, number, Sketch, Drawing. Empty for free names.
    string on;
    string[] params;   /// "name: Type", in order; named arguments use the name
    string type;       /// what it gives
    string doc;
    RefKind kind = RefKind.function_;
    string group;      /// section of the cheatsheet

    /// "fillet(edges: Edges, r: Length) → Solid"
    string signature() const
    {
        import std.array : join;
        if (kind == RefKind.property || kind == RefKind.constant || kind == RefKind.unit || kind == RefKind.keyword
            || kind == RefKind.type || kind == RefKind.annotation)
            return type.length ? name ~ ": " ~ type : name;
        return name ~ "(" ~ params.join(", ") ~ ")" ~ (type.length ? " → " ~ type : "");
    }

    /// The parameter names, for named arguments.
    string[] paramNames() const
    {
        import std.string : indexOf;
        string[] r;
        foreach (p; params)
        {
            auto i = p.indexOf(':');
            auto n = i < 0 ? p : p[0 .. i];
            if (n.length && n[0] != '.')
                r ~= n;
        }
        return r;
    }
}

/// The entries of one section of the cheatsheet.
private Ref[] group(string title, Ref[] entries)
{
    foreach (ref e; entries)
        e.group = title;
    return entries;
}

private alias F = (string name, string on, string[] params, string type, string doc) =>
    Ref(name, on, params, type, doc, on.length ? RefKind.method : RefKind.function_);
private alias P = (string name, string on, string type, string doc) => Ref(name, on, null, type, doc, RefKind.property);
private alias C = (string name, string type, string doc) => Ref(name, "", null, type, doc, RefKind.constant);
private alias U = (string name, string doc) => Ref(name, "number", null, "Length or Angle", doc, RefKind.unit);
private alias K = (string name, string doc) => Ref(name, "", null, "", doc, RefKind.keyword);
private alias A = (string name, string[] params, string doc) => Ref(name, "", params, "", doc, RefKind.annotation);
private alias T = (string name, string doc) => Ref(name, "", null, "", doc, RefKind.type);

immutable Ref[] reference =
    group("Objects and types", [
    T("Solid", "A 3D body: boxes, cylinders, booleans, features. Every operation gives a new one."),
    T("Profile", "A flat 2D outline on XY (rect, circle, text, sketch.profile): extrude or revolve it into a Solid."),
    T("Path", "A curve in space (path, spline, helix) to sweep a profile along."),
    T("Vec", "A 2D or 3D vector or point: vec(10.mm, 5.mm, 0.mm); .x .y .z .length."),
    T("Vec2", "A 2D vector."),
    T("Vec3", "A 3D vector."),
    T("Direction", "An axis direction: X, Y, Z, -X…, or any vector."),
    T("Plane", "An infinite plane: an origin and a normal (XY, plane(…), body.plane(faces.top)); cuts, mirrors, sections."),
    T("Axis", "A line in space: an origin and a direction (axis(…), body.axis(edges…)); rotations and circular patterns."),
    T("Frame", "A coordinate system on a face or plane: origin, X, Y and Z (body.frame(faces.top)); placeOn builds on it."),
    T("BBox", "A solid's bounding box: min, max, size, center."),
    T("Split", "What split gives: .above (where the plane's normal points) and .below."),
    T("Edges", "A selection of a solid's edges, for fillet and chamfer: edges.parallel(Z), edges.of(faces.top)…"),
    T("Faces", "A selection of a solid's faces, for shell, draft, frames: faces.top, faces.normal(X)…"),
    T("Edge", "One edge, inside a selector predicate: edges.filter(e => e.isCircle && e.radius == 3.mm)."),
    T("Face", "One face, inside a selector predicate: faces.filter(f => f.center.z > 10.mm)."),
    T("Sketch", "A constrained 2D drawing: points, lines, arcs and constraints; the solver places them, .profile gives the outline."),
    T("Drawing", "A technical sheet (views, sections, dimensions) returned by a @drawing function; exported as PDF, SVG, DXF."),
    T("Assembly", "Parts placed by their connections (planned)."),
    T("Color", "A colour: \"steelblue\", \"#RRGGBB\", \"#RRGGBBAA\" or rgb(…)."),
    T("Length", "A length with its unit: 10.mm, 2.5.cm; bare numbers given to geometry are mm."),
    T("Angle", "An angle: 30.deg, 0.5.rad."),
    T("Area", "An area (Length × Length)."),
    T("Volume", "A volume."),
    T("bool", "true or false."),
    T("int", "An integer."),
    T("double", "A number."),
    T("float", "A number."),
    T("real", "A number."),
    T("long", "An integer."),
    T("string", "Text."),
    ]) ~
    group("Output", [
    F("writeln", "", ["values…"], "", "Prints to the console (and to the JSON output for agents)."),
    F("write", "", ["values…"], "", "Prints without a newline."),
    F("format", "", ["fmt: string", "values…"], "string", "Formats like D's format: format(\"%.1f\", x)."),
    F("to", "", ["value"], "", "Converts: x.to!string, s.to!int."),
    ]) ~
    group("Math", [
    F("sqrt", "", ["x: number"], "number", "Square root."),
    F("abs", "", ["x"], "", "Absolute value (keeps the unit)."),
    F("floor", "", ["x: number"], "number", "Rounds down."),
    F("ceil", "", ["x: number"], "number", "Rounds up."),
    F("round", "", ["x: number"], "number", "Rounds to the nearest integer; on a profile, profile.round(r) rounds its corners."),
    F("sin", "", ["a: Angle"], "number", "Sine; bare numbers are radians."),
    F("cos", "", ["a: Angle"], "number", "Cosine; bare numbers are radians."),
    F("tan", "", ["a: Angle"], "number", "Tangent; bare numbers are radians."),
    F("asin", "", ["x: number"], "Angle", "Arc sine."),
    F("acos", "", ["x: number"], "Angle", "Arc cosine."),
    F("atan", "", ["x: number"], "Angle", "Arc tangent."),
    F("atan2", "", ["y", "x"], "Angle", "The angle of the point (x, y)."),
    F("min", "", ["a", "b…"], "", "The smallest argument."),
    F("max", "", ["a", "b…"], "", "The largest argument."),
    F("minElement", "list", [], "", "The smallest element of a list."),
    F("maxElement", "list", [], "", "The largest element of a list."),
    F("clamp", "", ["value", "lo", "hi"], "", "value limited to lo … hi."),
    ]) ~
    group("Vectors", [
    F("vec", "", ["x", "y", "z"], "Vec", "A 2D or 3D vector: vec(10.mm, 5.mm)."),
    F("dot", "Vec", ["b: Vec"], "number", "Dot product."),
    F("cross", "Vec", ["b: Vec"], "Vec", "Cross product."),
    F("distance", "", ["a", "b"], "Length", "Between two points, or the minimum distance between two solids (0 when they touch)."),
    ]) ~
    group("Lists", [
    F("iota", "", ["a: int", "b: int", "step: int"], "list", "The integers a … b-1 (or 0 … a-1)."),
    F("map", "list", ["f: x => …"], "list", "xs.map(x => x * 2)."),
    F("filter", "list", ["f: x => bool"], "list", "xs.filter(x => x > 0)."),
    F("fold", "list", ["f: (acc, x) => …", "seed"], "", "xs.fold((acc, x) => acc + x)."),
    F("sum", "list", [], "", "The sum; of solids, their union."),
    F("fuse", "", ["solids: Solid[]"], "Solid", "The union of a list of solids."),
    F("any", "list", ["f: x => bool"], "bool", "Whether some element satisfies f."),
    F("all", "list", ["f: x => bool"], "bool", "Whether every element satisfies f."),
    F("count", "list", ["f: x => bool"], "int", "How many elements (that satisfy f)."),
    F("canFind", "list", ["value or f"], "bool", "xs.canFind(value) or xs.canFind(x => condition)."),
    F("sort", "list", ["less: (a, b) => bool"], "list", "xs.sort or xs.sort((a, b) => a > b)."),
    F("reverse", "list", [], "list", "The list backwards."),
    F("retro", "list", [], "list", "The list backwards."),
    F("array", "list", [], "list", "A list from a range."),
    F("enumerate", "list", [], "list", "(index, value) pairs."),
    F("zip", "", ["a: list", "b: list"], "list", "Pairs of elements."),
    F("cartesianProduct", "", ["a: list", "b: list"], "list", "Every pair."),
    F("join", "list", ["sep: string"], "string", "The elements as one string."),
    ]) ~
    group("Colours", [
    F("rgb", "", ["r: 0..255", "g: 0..255", "b: 0..255", "alpha: 0..1"], "Color", "A colour; rgb(r, g, b, alpha: 0.5) is see-through."),
    ]) ~
    group("Solids", [
    F("box", "", ["x: Length", "y: Length", "z: Length", "center: bool"], "Solid", "A box standing on XY, centred in X and Y."),
    F("cylinder", "", ["r: Length", "h: Length", "d: Length", "center: bool"], "Solid", "A cylinder along Z standing on XY; give r or d, and h."),
    F("cone", "", ["r1: Length", "r2: Length", "h: Length", "d1: Length", "d2: Length", "center: bool"], "Solid",
        "A cone (or truncated cone) along Z."),
    F("sphere", "", ["r: Length", "d: Length"], "Solid", "A sphere centred on the origin."),
    F("load", "", ["path: string", "scale: number"], "Solid", "A part from an STL, OBJ, 3MF or STEP file in the project."),
    ]) ~
    group("Transforms", [
    F("move", "Shape", ["v: Vec", "x: Length", "y: Length", "z: Length"], "", "Moves: move(x: 10.mm) or move(vec(…))."),
    F("rotate", "Shape", ["angle: Angle", "axis: Axis", "x: Angle", "y: Angle", "z: Angle"], "",
        "rotate(z: 45) in degrees, or rotate(angle, axis: a) around any axis."),
    F("scale", "Shape", ["factor: number"], "", "Scales around the origin."),
    F("mirror", "Shape", ["plane: Plane"], "", "mirror(X): across the plane through the origin with that normal, or any plane."),
    F("color", "Solid", ["color: Color", "alpha: 0..1"], "Solid", "Sets the colour: \"steelblue\", \"#RRGGBB\", rgb(…)."),
    F("centered", "Shape", [], "", "Moved so its bounding box is centred on the origin."),
    ]) ~
    group("Features", [
    F("fillet", "Solid", ["edges: Edges", "r: Length"], "Solid", "Rounds the selected edges. Apply it before shell and before cutting holes."),
    F("chamfer", "Solid", ["edges: Edges", "d: Length"], "Solid", "Bevels the selected edges."),
    F("shell", "Solid", ["open: Faces", "thickness: Length"], "Solid",
        "Hollows the solid, leaving the faces in open: open. Open several faces in one shell."),
    F("draft", "Solid", ["faces: Faces", "angle: Angle", "pull: Direction", "neutral: Length"], "Solid",
        "Tapers faces so the part leaves a mould."),
    ]) ~
    group("Placement and copies", [
    F("nextTo", "Solid", ["other: Solid", "dir: Direction", "gap: Length"], "Solid", "Beside another solid: a.nextTo(b, X, gap: 10.mm)."),
    F("on", "Solid", ["other: Solid", "gap: Length"], "Solid", "On top of another solid."),
    F("align", "Solid", ["other: Solid", "x: string", "y: string", "z: string"], "Solid",
        "Aligns bounding boxes per axis: \"min\", \"center\" or \"max\"."),
    F("linearPattern", "Solid", ["n: int", "step: Vec"], "Solid", "n copies, step apart, as one solid."),
    F("circularPattern", "Solid", ["n: int", "axis: Axis", "angle: Angle"], "Solid", "n copies around an axis, as one solid."),
    F("placeOn", "Solid", ["frame: Frame"], "Solid", "A solid built on XY (Z up) moved onto a frame or plane."),
    F("split", "Solid", ["plane: Plane"], "Split", "Cuts with a plane: .above (where the normal points) and .below."),
    ]) ~
    group("Profiles (2D)", [
    F("rect", "", ["w: Length", "h: Length"], "Profile", "A rectangle centred on the origin."),
    F("circle", "", ["r: Length", "d: Length"], "Profile", "A circle centred on the origin."),
    F("polygon", "", ["points: Vec[]"], "Profile", "A polygon through the points."),
    F("regularPolygon", "", ["n: int", "r: Length", "d: Length"], "Profile", "regularPolygon(6, d: 10.mm): d/r through the corners."),
    F("slot", "", ["length: Length", "width: Length"], "Profile", "A stadium along X."),
    F("text", "", ["text: string", "size: Length", "font: string"], "Profile", "A text outline starting at the origin on the baseline."),
    F("round", "Profile", ["r: Length"], "Profile", "Rounds the (convex) corners."),
    F("offset", "Profile", ["distance: Length"], "Profile", "Grows (d > 0) or shrinks the outline; on a plane, the parallel plane."),
    F("extrude", "Profile", ["height: Length", "taper: Angle", "symmetric: bool"], "Solid", "A solid along +Z from the profile."),
    F("revolve", "Profile", ["axis: Axis", "angle: Angle"], "Solid",
        "Turns the profile around an axis in its plane; without one, x is the radius and y the height along Z."),
    F("sweep", "Profile", ["path: Path", "frenet: bool"], "Solid", "Moves the profile along a path."),
    F("loft", "", ["profiles: Profile[]", "ruled: bool"], "Solid", "A solid through profiles placed in space."),
    F("cut", "Solid", ["profile: Profile", "on: Frame", "depth: Length", "through: bool", "taper: Angle"], "Solid",
        "Digs a profile into a face: body.cut(p, on: frame, depth: 2.mm)."),
    ]) ~
    group("Paths, sweeps and lofts", [
    F("path", "", ["points: Vec[]", "closed: bool"], "Path", "Straight segments through the points."),
    F("spline", "", ["points: Vec[]", "closed: bool"], "Path", "A smooth curve through the points."),
    F("helix", "", ["r: Length", "d: Length", "pitch: Length", "height: Length", "left: bool"], "Path", "A helix around +Z."),
    ]) ~
    group("Planes, axes and frames", [
    F("plane", "", ["origin: Vec", "normal: Direction"], "Plane", "plane(origin:, normal:), plane(p1, p2, p3), or body.plane(faces.top)."),
    F("axis", "", ["origin: Vec", "direction: Direction"], "Axis", "axis(origin:, direction:), axis(p1, p2), or body.axis(edges…)."),
    F("frame", "Solid", ["face: Faces", "origin: Vec", "x: Direction"], "Frame", "A frame on a face: origin at its centre, Z outwards."),
    F("at", "Frame", ["x: Length", "y: Length", "z: Length"], "Frame", "The frame with its origin moved, in local coordinates."),
    F("turn", "Frame", ["angle: Angle"], "Frame", "The frame turned around its Z."),
    F("flip", "Plane", [], "Plane", "The plane with its normal reversed."),
    ]) ~
    group("Measuring", [
    P("bbox", "Solid", "BBox", "The bounding box: min, max, size, center."),
    P("volume", "Solid", "Volume", "The volume."),
    P("area", "Shape", "Area", "The surface area (of a profile: its area)."),
    P("isEmpty", "Solid", "bool", "Whether nothing is left."),
    P("isValid", "Solid", "bool", "Whether the solid is a valid closed solid."),
    P("pieces", "Solid", "Solid[]", "The separate bodies, ordered along X, then Y, then Z."),
    P("above", "Split", "Solid", "The side of the cut the normal points to."),
    P("below", "Split", "Solid", "The other side of the cut."),
    P("min", "BBox", "Vec", "The lowest corner."),
    P("max", "BBox", "Vec", "The highest corner."),
    P("size", "BBox", "Vec", "Width, depth and height."),
    P("center", "BBox", "Vec", "The centre."),
    P("x", "Vec", "Length", "X component."),
    P("y", "Vec", "Length", "Y component."),
    P("z", "Vec", "Length", "Z component."),
    P("xy", "Vec", "Vec", "X and Y."),
    P("length", "Vec", "Length", "Length of the vector (of a list: how many elements)."),
    P("normalized", "Vec", "Vec", "The unit vector."),
    P("origin", "Frame", "Vec", "The origin (also of planes and axes)."),
    P("normal", "Plane", "Direction", "The normal."),
    P("direction", "Axis", "Direction", "The direction."),
    ]) ~
    group("Selectors", [
    P("top", "Faces", "Faces", "The face(s) facing +Z the most."),
    P("bottom", "Faces", "Faces", "The face(s) facing -Z."),
    P("front", "Faces", "Faces", "The face(s) facing -Y."),
    P("back", "Faces", "Faces", "The face(s) facing +Y."),
    P("left", "Faces", "Faces", "The face(s) facing -X."),
    P("right", "Faces", "Faces", "The face(s) facing +X."),
    P("largest", "Faces", "Faces", "The largest face."),
    F("normal", "Faces", ["dir: Direction"], "Faces", "The faces with that normal: faces.normal(X)."),
    F("from", "Faces", ["tool: Solid"], "Faces", "The faces created by a tool or feature: faces.from(holes)."),
    F("parallel", "Edges", ["axis: Direction"], "Edges", "The straight edges along an axis: edges.parallel(Z)."),
    F("perpendicular", "Edges", ["axis: Direction"], "Edges", "The edges at right angles to an axis."),
    P("lines", "Edges", "Edges", "The straight edges."),
    P("circles", "Edges", "Edges", "The circular edges."),
    F("of", "Edges", ["faces: Faces"], "Edges", "The edges around faces: edges.of(faces.top)."),
    F("between", "Edges", ["a: Faces", "b: Faces"], "Edges", "The edges between two sets of faces."),
    P("start", "Edge", "Vec", "Start point."),
    P("end", "Edge", "Vec", "End point."),
    P("mid", "Edge", "Vec", "Middle point."),
    P("isLine", "Edge", "bool", "Whether it is straight."),
    P("isCircle", "Edge", "bool", "Whether it is a circle or an arc."),
    P("radius", "Edge", "Length", "The radius of a circular edge."),
    F("isParallel", "Edge", ["axis: Direction"], "bool", "Whether it runs along the axis (a face: whether its normal does)."),
    F("isPerpendicular", "Edge", ["axis: Direction"], "bool", "Whether it is at right angles to the axis."),
    ]) ~
    group("Sketches", [
    F("sketch", "", [], "Sketch", "A constrained 2D sketch: add points, lines, constraints, then take .profile."),
    F("point", "Sketch", ["x: Length", "y: Length", "fixed: bool"], "Point", "A point where it starts; constraints move it."),
    F("line", "Sketch", ["p: Point", "q: Point"], "Line", "A line between two points."),
    F("arc", "Sketch", ["center: Point", "start: Point", "end: Point"], "Arc", "An arc, counter-clockwise."),
    F("polyline", "Sketch", ["points", "closed: bool"], "Line[]", "Lines through points (vectors become new points)."),
    F("coincident", "Sketch", ["p: Point", "q: Point"], "", "Two points in the same place."),
    F("fix", "Sketch", ["p: Point"], "", "Pins a point."),
    F("horizontal", "Sketch", ["line: Line"], "", "A horizontal line (or two points at the same height)."),
    F("vertical", "Sketch", ["line: Line"], "", "A vertical line."),
    F("equal", "Sketch", ["a", "b"], "", "Equal lengths or radii."),
    F("tangent", "Sketch", ["a", "b"], "", "Tangent line and circle, or two circles."),
    F("midpoint", "Sketch", ["p: Point", "line: Line"], "", "A point in the middle of a line."),
    F("symmetric", "Sketch", ["p: Point", "q: Point", "line: Line"], "", "Two points symmetric about a line."),
    F("diameter", "Sketch", ["c: Circle", "v: Length"], "", "Sets a diameter."),
    P("profile", "Sketch", "Profile", "Solves the sketch and gives its outline."),
    P("dof", "Sketch", "int", "Degrees of freedom left."),
    P("solved", "Sketch", "bool", "Whether the constraints are satisfied."),
    ]) ~
    group("Drawings", [
    F("drawing", "", ["size: string", "title: string", "author: string", "material: string", "projection: string",
        "scale: number", "landscape: bool"], "Drawing", "A technical sheet, returned by a @drawing function."),
    F("standardViews", "Drawing", ["solid: Solid", "iso: bool", "dimensions: bool"], "", "Front, top, side and iso views, laid out."),
    F("view", "Drawing", ["solid: Solid", "name: string", "at: Vec", "scale: number"], "View", "One view: \"front\", \"top\", \"iso\"…"),
    F("section", "Drawing", ["solid: Solid", "plane: Plane", "label: string"], "View", "A hatched section."),
    F("dimension", "Drawing", ["view: View", "from: Vec", "to: Vec", "offset: Length", "text: string"], "", "A dimension between two points."),
    F("note", "Drawing", ["text: string", "at: Vec", "size: Length"], "", "A note on the sheet."),
    ]) ~
    group("Units", [
    U("mm", "Millimetres: 60.mm."),
    U("cm", "Centimetres."),
    U("m", "Metres."),
    U("inch", "Inches."),
    U("deg", "Degrees: 45.deg."),
    U("rad", "Radians."),
    ]) ~
    group("Constants", [
    C("X", "Direction", "The X axis (also a plane normal)."),
    C("Y", "Direction", "The Y axis."),
    C("Z", "Direction", "The Z axis."),
    C("XY", "Plane", "The XY plane."),
    C("XZ", "Plane", "The XZ plane."),
    C("YZ", "Plane", "The YZ plane."),
    C("World", "Frame", "The global frame."),
    C("PI", "number", "π."),
    C("nothing", "Solid", "The empty solid (also Solid.init): start of a union built in a loop."),
    C("edges", "Edges", "The edges of the solid a feature applies to: edges.parallel(Z)."),
    C("faces", "Faces", "The faces of the solid a feature applies to: faces.top."),
    ]) ~
    group("Keywords", [
    K("module", "Names the model: module box;"),
    K("import", "import hardware : M3;  import pizza;  import p = parts.bracket;"),
    K("immutable", "A constant: immutable width = 60.mm;"),
    K("auto", "A local variable: auto s = box(…);"),
    K("return", "Gives the result of a function."),
    K("foreach", "foreach (i; 0 .. n)  foreach (x; xs)"),
    K("if", "if (condition) … else …"),
    K("else", "The other branch of an if."),
    K("for", "for (int i = 0; i < n; i++)"),
    K("while", "while (condition) …"),
    K("struct", "A record type with fields."),
    K("unittest", "Design checks, run after every evaluation."),
    K("assert", "assert(condition, \"message\")"),
    K("private", "Not visible to modules that import this one."),
    K("public", "public import: re-exported to whoever imports this module."),
    K("true", "Boolean true."),
    K("false", "Boolean false."),
    ]) ~
    group("Annotations", [
    A("part", ["color", "alpha: 0..1", "export: bool", "name: string"], "A body to show and export: @part(\"steelblue\"); name: its name in exported files."),
    A("param", ["description", "min:", "max:", "step:", "choices:"], "A parameter with a field in the panel."),
    A("preset", ["name", "value"], "The parameter's value in a named preset."),
    A("drawing", [], "A function returning a technical drawing."),
    A("assembly", [], "A function returning an assembly."),
    A("unit", ["unit"], "The default unit of bare numbers: @unit(inch) module m;"),
    ]);

/// The entries named `name` (several when a name means different things on
/// different receivers, like round or length).
const(Ref)[] lookupRef(string name)
{
    const(Ref)[] r;
    foreach (ref e; reference)
        if (e.name == name)
            r ~= e;
    return r;
}

/// "How do I…": one line of code for the things people look for.
struct Recipe
{
    string task;
    string code;
}

immutable Recipe[] recipes = [
    Recipe("Copy a solid (values never change: use it again)", "auto b = a.move(x: 20.mm);"),
    Recipe("Many copies in a row", "peg.linearPattern(4, step: vec(10.mm, 0.mm, 0.mm))"),
    Recipe("Copies around an axis", "peg.circularPattern(6, axis: Z)"),
    Recipe("A mirrored copy, keeping the original", "s + s.mirror(X)"),
    Recipe("A hole: subtract a cylinder", "plate - cylinder(d: 5.mm, h: 10.mm).move(x: 10.mm)"),
    Recipe("Screw holes from the library", "s - hole(M3, 6.mm, \"countersink\").move(z: 6.mm)"),
    Recipe("Round the vertical edges", "box(40, 30, 20).fillet(edges.parallel(Z), r: 4.mm)"),
    Recipe("Hollow out, open on top", "s.shell(open: faces.top, thickness: 2.mm)"),
    Recipe("Build on a face", "cylinder(d: 8.mm, h: 5.mm).placeOn(body.frame(faces.top))"),
    Recipe("Put one part beside another", "lid.nextTo(body, X, gap: 10.mm)"),
    Recipe("Text in relief", "text(\"ABC\", size: 5.mm).centered.extrude(0.6.mm)"),
    Recipe("Cut with a plane and keep one side", "s.split(XY.offset(10.mm)).below"),
    Recipe("A reference part, shown but not exported", "@part(\"slategray\", alpha: 0.4, export: false)"),
    Recipe("A parameter in the side panel", "@param(\"Width\", min: 10.mm, max: 100.mm) immutable width = 40.mm;"),
    Recipe("Check a requirement", "unittest { assert(body.bbox.size.z <= 40.mm, \"too tall\"); }"),
    Recipe("Measure", "writeln(s.volume, \" \", s.bbox.size)"),
];
