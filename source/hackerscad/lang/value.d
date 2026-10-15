module hackerscad.lang.value;

import std.conv : to;
import std.format : format;
import std.math : PI, abs, isClose;
import std.array : join;
import std.algorithm : map, canFind;

import hackerscad.geom.vec;
public import hackerscad.geom.color;
import hackerscad.kernel.brep : Brep, EdgeInfo, FaceInfo;
import hackerscad.lang.errors;
import hackerscad.lang.ast;

/// Physical dimension as exponents of length and angle. Values are stored in
/// millimetres and radians.
struct Dim
{
    byte len;
    byte ang;

    enum none = Dim(0, 0);
    enum length = Dim(1, 0);
    enum area = Dim(2, 0);
    enum volume = Dim(3, 0);
    enum angle = Dim(0, 1);

    Dim opBinary(string op)(Dim o) const if (op == "+" || op == "-")
    {
        return Dim(cast(byte) mixin("len" ~ op ~ "o.len"), cast(byte) mixin("ang" ~ op ~ "o.ang"));
    }

    Dim times(int k) const => Dim(cast(byte)(len * k), cast(byte)(ang * k));

    string name() const
    {
        if (this == none) return "number";
        if (this == length) return "Length";
        if (this == area) return "Area";
        if (this == volume) return "Volume";
        if (this == angle) return "Angle";
        return format("mm^%d·rad^%d", len, ang);
    }

    /// The name with its article: "a Length", "an Angle".
    string aName() const
    {
        immutable n = name;
        return ("AEIOUaeiou".canFind(n[0]) ? "an " : "a ") ~ n;
    }

    /// Suffix used when printing.
    string unit() const
    {
        if (this == none) return "";
        if (this == angle) return "°";
        string s;
        if (len) s ~= len == 1 ? " mm" : format(" mm^%d", len);
        if (ang) s ~= format(" rad^%d", ang);
        return s;
    }
}

enum Kind : ubyte
{
    void_,
    null_,
    bool_,
    num,
    str,
    vec,
    array,
    aa,
    struct_,
    func,
    builtin,
    bound,
    type,
    module_,
    solid,
    selector,
    edge,
    face,
    object_,
}

/// A value used as a kind it is not (a number where a string was
/// expected): the interpreter reports it as a type error at the call.
class ValueKindError : Exception
{
    Kind wanted, got;
    this(Kind wanted, Kind got)
    {
        import std.conv : to;
        this.wanted = wanted;
        this.got = got;
        super("expected " ~ kindName(wanted) ~ ", not " ~ kindName(got));
    }
}

/// How a kind is named in messages.
string kindName(Kind k)
{
    final switch (k)
    {
    case Kind.void_: return "nothing";
    case Kind.null_: return "null";
    case Kind.bool_: return "a bool";
    case Kind.num: return "a number";
    case Kind.str: return "a string";
    case Kind.vec: return "a vector";
    case Kind.array: return "an array";
    case Kind.aa: return "an associative array";
    case Kind.struct_: return "a struct";
    case Kind.func: return "a function";
    case Kind.builtin: return "a function";
    case Kind.bound: return "a method";
    case Kind.type: return "a type";
    case Kind.module_: return "a module";
    case Kind.solid: return "a solid";
    case Kind.selector: return "a selector";
    case Kind.edge: return "an edge";
    case Kind.face: return "a face";
    case Kind.object_: return "an object";
    }
}

struct Value
{
    Kind kind;
    // the payload: read and written through the accessors below, which
    // check the kind first; reading the wrong member of an untagged union
    // would reinterpret its bits (a number read as a string crashes)
    private union
    {
        bool b_;
        NumVal n_;
        string s_;
        VecVal v_;
        Value[] arr_;
        AAVal aa_;
        StructVal st_;
        Closure fn_;
        Builtin bi_;
        Bound bound_;
        TypeVal type_;
        ModuleVal mod_;
        SolidVal solid_;
        SelectorVal sel_;
        EdgeVal edge_;
        FaceVal face_;
        ObjectVal obj_;
    }

    private static string accessor(string name, string kind) =>
        "@property ref inout(typeof(" ~ name ~ "_)) " ~ name ~ "() inout return {"
        ~ " if (kind != Kind." ~ kind ~ ") throw new ValueKindError(Kind." ~ kind ~ ", kind);"
        ~ " return " ~ name ~ "_; }";
    mixin(accessor("b", "bool_"));
    mixin(accessor("n", "num"));
    mixin(accessor("s", "str"));
    mixin(accessor("v", "vec"));
    mixin(accessor("arr", "array"));
    mixin(accessor("aa", "aa"));
    mixin(accessor("st", "struct_"));
    mixin(accessor("fn", "func"));
    mixin(accessor("bi", "builtin"));
    mixin(accessor("bound", "bound"));
    mixin(accessor("type", "type"));
    mixin(accessor("mod", "module_"));
    mixin(accessor("solid", "solid"));
    mixin(accessor("sel", "selector"));
    mixin(accessor("edge", "edge"));
    mixin(accessor("face", "face"));
    mixin(accessor("obj", "object_"));

    static Value void_() => Value.init;

    static Value null_()
    {
        Value r;
        r.kind = Kind.null_;
        return r;
    }

    static Value of(bool x)
    {
        Value r;
        r.kind = Kind.bool_;
        r.b = x;
        return r;
    }

    static Value number(double x, Dim d = Dim.none, bool isInt = false)
    {
        Value r;
        r.kind = Kind.num;
        r.n = NumVal(x, d, isInt && d == Dim.none);
        return r;
    }

    static Value integer(long x) => number(x, Dim.none, true);

    static Value of(string x)
    {
        Value r;
        r.kind = Kind.str;
        r.s = x;
        return r;
    }

    static Value of(Value[] x)
    {
        Value r;
        r.kind = Kind.array;
        r.arr = x;
        return r;
    }

    static Value vector(Vec3 x, ubyte n, Dim d)
    {
        Value r;
        r.kind = Kind.vec;
        r.v = VecVal(x, n, d);
        return r;
    }

    static Value make(T)(Kind k, T payload)
    {
        Value r;
        r.kind = k;
        static if (is(T == AAVal)) r.aa = payload;
        else static if (is(T == StructVal)) r.st = payload;
        else static if (is(T == Closure)) r.fn = payload;
        else static if (is(T == Builtin)) r.bi = payload;
        else static if (is(T == Bound)) r.bound = payload;
        else static if (is(T == TypeVal)) r.type = payload;
        else static if (is(T == ModuleVal)) r.mod = payload;
        else static if (is(T == SolidVal)) r.solid = payload;
        else static if (is(T == SelectorVal)) r.sel = payload;
        else static if (is(T == EdgeVal)) r.edge = payload;
        else static if (is(T == FaceVal)) r.face = payload;
        else static if (is(T : ObjectVal)) r.obj = payload;
        else static assert(0, "unsupported payload " ~ T.stringof);
        return r;
    }

    static Value of(SolidVal x) => make(Kind.solid, x);

    bool isNum() const => kind == Kind.num;
    bool isCallable() const => kind == Kind.func || kind == Kind.builtin || kind == Kind.bound
        || (kind == Kind.type && type.def !is null);

    /// Name of the type, for error messages and the type checker.
    string typeName() const
    {
        final switch (kind)
        {
        case Kind.void_: return "void";
        case Kind.null_: return "null";
        case Kind.bool_: return "bool";
        case Kind.num: return n.dim == Dim.none ? (n.isInt ? "int" : "double") : n.dim.name;
        case Kind.str: return "string";
        case Kind.vec: return v.n == 2 ? "Vec2" : "Vec3";
        case Kind.array: return "array";
        case Kind.aa: return "associative array";
        case Kind.struct_: return st.def.name;
        case Kind.func: case Kind.builtin: case Kind.bound: return "function";
        case Kind.type: return "type";
        case Kind.module_: return "module";
        case Kind.solid: return solid.path ? "Path" : solid.flat ? "Profile" : "Solid";
        case Kind.selector: return sel.faces ? "FaceSelector" : "EdgeSelector";
        case Kind.edge: return "Edge";
        case Kind.face: return "Face";
        case Kind.object_: return obj.typeName;
        }
    }

    bool truthy() const
    {
        switch (kind)
        {
        case Kind.bool_: return b;
        case Kind.num: return n.value != 0;
        case Kind.null_: case Kind.void_: return false;
        case Kind.str: return s.length > 0;
        case Kind.array: return arr.length > 0;
        default: return true;
        }
    }

    bool opEquals(const Value o) const
    {
        if (kind != o.kind)
            return false;
        switch (kind)
        {
        case Kind.void_: case Kind.null_: return true;
        case Kind.bool_: return b == o.b;
        case Kind.num: return n.dim == o.n.dim && n.value == o.n.value;
        case Kind.str: return s == o.s;
        case Kind.vec: return v.n == o.v.n && v.dim == o.v.dim && v.v == o.v.v;
        case Kind.array:
            if (arr.length != o.arr.length) return false;
            foreach (i; 0 .. arr.length)
                if (arr[i] != o.arr[i]) return false;
            return true;
        case Kind.struct_:
            if (st.def !is o.st.def) return false;
            foreach (i; 0 .. st.fields.length)
                if (st.fields[i] != o.st.fields[i]) return false;
            return true;
        case Kind.aa:
            if (aa is o.aa) return true;
            if (aa.vals.length != o.aa.vals.length) return false;
            foreach (key, val; aa.vals)
            {
                auto other = key in o.aa.vals;
                if (other is null || *other != val) return false;
            }
            return true;
        case Kind.type: return type.name == o.type.name;
        case Kind.solid: return solid is o.solid;
        case Kind.object_: return obj is o.obj;
        default: return false;
        }
    }

    /// D-like textual form, used by writeln and text().
    string toString() const
    {
        final switch (kind)
        {
        case Kind.void_: return "void";
        case Kind.null_: return "null";
        case Kind.bool_: return b ? "true" : "false";
        case Kind.num: return formatNum(n.value, n.dim, n.isInt);
        case Kind.str: return s;
        case Kind.vec:
            {
                double[] c = [v.v.x, v.v.y, v.v.z][0 .. v.n];
                return "[" ~ c.map!(x => formatNum(x, v.dim.ang ? Dim.none : v.dim, false)).join(", ") ~ "]";
            }
        case Kind.array: return "[" ~ arr.map!(x => x.kind == Kind.str ? `"` ~ x.s ~ `"` : x.toString).join(", ") ~ "]";
        case Kind.aa:
            {
                string[] parts;
                foreach (k, val; aa.vals)
                    parts ~= aa.keys[k].toString ~ ": " ~ val.toString;
                return "[" ~ parts.join(", ") ~ "]";
            }
        case Kind.struct_:
            {
                string[] parts;
                foreach (i, f; st.def.fields)
                    parts ~= f.name ~ ": " ~ st.fields[i].toString;
                return st.def.name ~ "(" ~ parts.join(", ") ~ ")";
            }
        case Kind.func: return "function " ~ fn.name;
        case Kind.builtin: return "function " ~ bi.name;
        case Kind.bound: return "function";
        case Kind.type: return type.name;
        case Kind.module_: return "module " ~ mod.name;
        case Kind.solid: return solid.brep is null ? "Solid(empty)" : solid.path ? "Path" : solid.flat ? "Profile" : "Solid";
        case Kind.selector: return sel.faces ? "faces" : "edges";
        case Kind.edge: return "Edge";
        case Kind.face: return "Face";
        case Kind.object_: return (cast() obj).describe();
        }
    }
}

string formatNum(double x, Dim d, bool isInt)
{
    if (isInt)
        return (cast(long) x).to!string;
    if (d == Dim.angle)
        x = x * 180 / PI;
    string s = format("%.6g", abs(x) < 1e-12 ? 0.0 : x);
    return s ~ d.unit;
}

struct NumVal
{
    double value;
    Dim dim;
    bool isInt;
}

struct VecVal
{
    Vec3 v;
    ubyte n;   /// 2 or 3 components
    Dim dim;
}

final class AAVal
{
    Value[string] vals;
    Value[string] keys;   /// original key values, by canonical key
}

string aaKey(const Value k, Span span)
{
    switch (k.kind)
    {
    case Kind.str: return "s" ~ k.s;
    // the exact value (hexadecimal, every bit), not 6 digits: 1000000 and
    // 1000001 are two keys; -0 is 0, as == says
    case Kind.num: return format("n%a%s/%s", k.n.value == 0 ? 0.0 : k.n.value, k.n.dim.len, k.n.dim.ang);
    case Kind.bool_: return k.b ? "b1" : "b0";
    default:
        throw new HcadError(Code.type, "associative array keys must be strings, numbers or bools, not " ~ k.typeName, span);
    }
}

final class StructDef
{
    string name;
    StructDecl decl;
    FieldInfo[] fields;
    Closure[string] methods;
    ModuleVal mod;

    struct FieldInfo
    {
        string name;
        TypeRef type;
        Expr init;
    }

    ptrdiff_t fieldIndex(string n) const
    {
        foreach (i, f; fields)
            if (f.name == n)
                return i;
        return -1;
    }
}

struct StructVal
{
    StructDef def;
    Value[] fields;
}

/// Lexical environment. Variables declared with enum/immutable/const are
/// read-only; module-level globals are evaluated lazily on first use.
final class Env
{
    Env parent;
    Value[string] vars;
    bool[string] readonly;
    VarDecl[string] pending;   /// module-level globals not evaluated yet
    bool[string] evaluating;   /// cycle detection for pending globals
    ModuleVal mod;
    /// Declared types of variables (int n = …), checked again on assignment;
    /// `mod` resolves the type's name.
    struct Typed
    {
        TypeRef type;
        ModuleVal mod;
    }
    Typed[string] types;

    this(Env parent, ModuleVal mod)
    {
        this.parent = parent;
        this.mod = mod;
    }

    Env find(string name)
    {
        for (auto e = this; e !is null; e = e.parent)
            if (name in e.vars || name in e.pending)
                return e;
        return null;
    }

    string[] allNames()
    {
        string[] r;
        for (auto e = this; e !is null; e = e.parent)
            r ~= e.vars.keys ~ e.pending.keys;
        return r;
    }
}

final class Closure
{
    string name;
    Param[] params;
    TypeRef returnType;   /// null for lambdas and auto
    Stmt body;            /// block body, or
    Expr exprBody;        /// expression body (=> e)
    Env env;
    ModuleVal mod;
    Span span;
    bool isMethod;        /// struct method: first argument is `this`
    FuncDecl decl;        /// declared function (not a lambda): called without parens like in D
    bool isPart;          /// @part: evaluated once per run
}

alias BuiltinImpl = Value delegate(ref CallArgs args);

final class Builtin
{
    string name;
    BuiltinImpl impl;
    double unitFactor = 0; /// non-zero for unit functions (mm, inch, deg …)
    Dim unitDim;
}

/// Evaluated call arguments with their source positions.
struct CallArgs
{
    Value[] positional;
    Value[string] named;
    string[] namedOrder;
    Value[] templateArgs;  /// f!(a, b)(…)
    Span span;
    Span[] positionalSpans;
    Span[string] namedSpans;
    ModuleVal caller;
}

/// A function with its first argument already bound (UFCS `x.f`).
final class Bound
{
    Value receiver;
    Value func;
}

final class TypeVal
{
    string name;
    StructDef def;   /// for user structs
}

final class ModuleVal
{
    string name;
    string path;
    string source;
    Env env;
    double unitFactor = 1;   /// default unit for bare lengths, in mm
    bool[string] publicNames;
    Program program;
    Unittest[] unittests;
    ModuleVal[] imported;    /// plain `import x;`: public names visible unqualified
    ModuleVal[] reexported;  /// `public import x;`: x's public names are this module's too
}

/// A solid with display attributes. `brep` is null for the empty solid.
/// A built-in object with reference semantics (sketches, assemblies…):
/// properties and methods are looked up by name.
abstract class ObjectVal
{
    abstract string typeName() const;
    string describe() => typeName;
    /// A property read without parentheses; false if there is none.
    bool property(string name, Span span, out Value result) => false;
    /// A method: called with the object as first positional argument.
    BuiltinImpl method(string name) => null;
    /// For "did you mean" suggestions.
    string[] memberNames() => null;
}

final class SolidVal
{
    Brep brep;
    uint rgb;
    bool hasColor;
    Span origin;
    uint[] creators;   /// per face: the feature that created it (Interp.features), 0 if unknown
    bool flat;         /// a 2D profile (planar faces) rather than a solid
    bool path;         /// a curve (wire) to sweep along
    bool placed;       /// a profile drawn on a face or plane (a sketch's): where it lies, below
    Vec3[4] place;     /// its frame: origin, x, y, z; the brep stays on XY, in the frame's coordinates

    this(Brep b, Span origin)
    {
        brep = b;
        this.origin = origin;
    }
}

/// What a selector test sees of the solid being selected on.
struct SelectCtx
{
    const(EdgeInfo)[] edges;
    const(FaceInfo)[] faces;
    const(uint)[] creators;        /// per face (empty if unknown)
    const(int[2])[] edgeFaces;     /// per edge
    int[] delegate(SelectorVal) resolve;   /// nested selector on the same solid
    /// per face, the share of its area that overhangs more than `angle` (radians)
    const(double)[] delegate(double angle) overhangShares;
}

alias SelectTest = bool delegate(size_t index, ref SelectCtx ctx);

/// Lazy edge/face selection, resolved against the solid a feature applies to.
final class SelectorVal
{
    bool faces;
    /// filters applied in order: callable predicates and builtin tests
    Value[] predicates;
    SelectTest[] tests;
}

final class EdgeVal
{
    EdgeInfo info;
    size_t index;
}

final class FaceVal
{
    FaceInfo info;
    size_t index;
}

unittest
{
    auto a = Value.number(60, Dim.length);
    assert(a.toString == "60 mm");
    assert(Value.number(PI / 4, Dim.angle).toString == "45°");
    assert(Value.integer(3).toString == "3");
    assert(Value.of([Value.integer(1), Value.of("a")]).toString == `[1, "a"]`);
    assert((Dim.length + Dim.length) == Dim.area);
    assert(Value.integer(2) == Value.number(2));
}
