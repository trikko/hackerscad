/// What a .hcad module declares, read without running it: its public
/// functions, structs (with their fields) and constants, with the `///`
/// comments above them. The editor's completion uses it for the model and
/// the modules it imports; the cheatsheet for the built-in libraries.
module hackerscad.tool.outline;

import std.algorithm : startsWith;
import std.array : join;
import std.file : exists, readText;
import std.path : buildNormalizedPath;
import std.string : lineSplitter, strip;

import hackerscad.lang.ast;
import hackerscad.lang.parser : parse;

struct Decl
{
    enum Kind
    {
        function_,
        struct_,
        field,
        constant,
    }

    Kind kind;
    string name;
    string signature;    /// screw(s: Screw, length: Length, socket: bool = true) → Solid
    string type;         /// result type, field type, or a constant's struct
    string on;           /// first parameter's type (callable after a dot), or the struct of a field
    string[] params;     /// parameter names
    string doc;
}

struct Outline
{
    string name;         /// the module name
    Decl[] decls;
    string[][] reexports;   /// public import paths
}

/// The outline of a module's source; an unparsable source gives what was
/// found before the error (nothing, with this parser).
Outline outline(string source, string file)
{
    Outline o;
    Program prog;
    try
        prog = parse(source, file);
    catch (Exception)
        return o;
    if (prog.moduleDecl)
        o.name = prog.moduleDecl.name.join(".");
    auto lines = source.lineSplitter.array_;
    foreach (d; prog.decls)
        add(o, d, lines);
    return o;
}

private string[] array_(R)(R r)
{
    string[] a;
    foreach (l; r)
        a ~= l;
    return a;
}

private void add(ref Outline o, Stmt d, string[] lines)
{
    if (auto b = cast(Block) d)
    {
        foreach (s; b.stmts)
            add(o, s, lines);
        return;
    }
    if (auto i = cast(ImportDecl) d)
    {
        if (i.isPublic && i.selective.length == 0 && i.aliasName.length == 0)
            o.reexports ~= i.path.dup;
        return;
    }
    if (auto f = cast(FuncDecl) d)
    {
        if (f.isPrivate)
            return;
        o.decls ~= functionDecl(f, docAbove(lines, f.nameSpan.line));
        return;
    }
    if (auto s = cast(StructDecl) d)
    {
        if (s.isPrivate)
            return;
        Decl sd;
        sd.kind = Decl.Kind.struct_;
        sd.name = s.name;
        string[] fields;
        foreach (v; s.fields)
        {
            Decl fd;
            fd.kind = Decl.Kind.field;
            fd.name = v.name;
            fd.type = v.type ? typeText(v.type) : "";
            fd.on = s.name;
            fd.signature = v.name ~ (fd.type.length ? ": " ~ fd.type : "");
            fd.doc = docAbove(lines, v.nameSpan.line);
            o.decls ~= fd;
            fields ~= fd.signature;
        }
        foreach (m; s.methods)
        {
            auto md = functionDecl(m, docAbove(lines, m.nameSpan.line));
            md.on = s.name;
            o.decls ~= md;
        }
        sd.signature = s.name ~ "(" ~ fields.join(", ") ~ ")";
        sd.params = s.fields.length ? names(s.fields) : null;
        sd.doc = docAbove(lines, s.span.line);
        o.decls ~= sd;
        return;
    }
    if (auto v = cast(VarDecl) d)
    {
        if (v.isPrivate)
            return;
        Decl c;
        c.kind = Decl.Kind.constant;
        c.name = v.name;
        c.type = v.type ? typeText(v.type) : constructed(v.init);
        c.signature = v.name ~ (c.type.length ? ": " ~ c.type : "");
        c.doc = docAbove(lines, v.nameSpan.line);
        if (c.doc.length == 0)
            foreach (a; v.attrs)
                if (a.name == "param" && a.args.length && a.args[0].name.length == 0)
                    if (auto l = cast(Literal) a.args[0].value)
                        c.doc = "Parameter: " ~ l.text;
        o.decls ~= c;
    }
}

private string[] names(VarDecl[] vs)
{
    string[] r;
    foreach (v; vs)
        r ~= v.name;
    return r;
}

private Decl functionDecl(FuncDecl f, string doc)
{
    Decl d;
    d.kind = Decl.Kind.function_;
    d.name = f.name;
    d.type = f.returnType ? typeText(f.returnType) : "";
    string[] ps;
    foreach (i, p; f.params)
    {
        auto t = p.type ? typeText(p.type) : "";
        if (i == 0)
            d.on = t;
        d.params ~= p.name;
        auto text = p.name ~ (t.length ? ": " ~ t : "");
        if (auto l = cast(Literal) p.defaultValue)
            text ~= " = " ~ (l.type == Literal.Type.string_ ? "\"" ~ l.text ~ "\"" : l.text);
        else if (p.defaultValue !is null)
            text ~= " = …";
        ps ~= text;
    }
    d.signature = f.name ~ "(" ~ ps.join(", ") ~ ")" ~ (d.type.length ? " → " ~ d.type : "");
    d.doc = doc;
    return d;
}

private string typeText(TypeRef t)
{
    if (t is null)
        return "";
    if (t.isAA)
        return typeText(t.elem) ~ "[" ~ typeText(t.key) ~ "]";
    if (t.isArray)
        return typeText(t.elem) ~ "[]";
    return t.name;
}

/// The struct a constant is built from: immutable M3 = Screw(…) is a Screw.
private string constructed(Expr e)
{
    if (auto c = cast(Call) e)
        if (auto id = cast(Ident) c.callee)
            if (id.name.length && id.name[0] >= 'A' && id.name[0] <= 'Z')
                return id.name;
    return "";
}

/// The `///` comment lines right above line `line` (1-based), skipping the
/// annotations between them and the declaration.
private string docAbove(string[] lines, uint line)
{
    string[] doc;
    for (long i = cast(long) line - 2; i >= 0; i--)
    {
        auto l = lines[i].strip;
        if (l.startsWith("///"))
            doc = [l[3 .. $].strip] ~ doc;
        else if (l.startsWith("@") && doc.length == 0)
            continue;
        else
            break;
    }
    // or a trailing one: Length d;   /// nominal diameter
    if (doc.length == 0 && line >= 1 && line <= lines.length)
    {
        import std.string : indexOf;
        auto l = lines[line - 1];
        auto at = l.indexOf("///");
        if (at > 0)
            return l[at + 3 .. $].strip;
    }
    return doc.join(" ");
}

// ---------------------------------------------------------------- modules

/// The source of the module `path` imports, found as the interpreter finds
/// it: the built-in libraries, then the model's directory and the library
/// folders, as name.hcad or name/package.hcad. null when not found (or a
/// std module, which lives in the prelude).
string moduleSource(const string[] path, string root, const string[] libraryDirs, out string file)
{
    import hackerscad.lang.builtins : librarySources, stdPackage;
    auto name = path.join(".");
    if (name == "std")
    {
        file = "<std>";
        return stdPackage();
    }
    auto canonical = name.startsWith("std.") ? name[4 .. $] : name;
    if (auto src = canonical in librarySources)
    {
        file = "<" ~ canonical ~ ">";
        return *src;
    }
    if (path.length && path[0] == "std")
        return null;
    auto rel = path.join("/");
    foreach (base; [root] ~ libraryDirs)
    {
        if (base.length == 0)
            continue;
        auto dir = buildNormalizedPath(base);
        foreach (candidate; [rel ~ ".hcad", rel ~ "/package.hcad"])
        {
            auto f = buildNormalizedPath(dir, candidate);
            if (f.startsWith(dir) && exists(f))
            {
                file = f;
                try
                    return readText(f);
                catch (Exception)
                    return null;
            }
        }
    }
    return null;
}

/// The public declarations a module makes visible, its `public import`s
/// followed (to a small depth).
Decl[] visibleDecls(const string[] path, string root, const string[] libraryDirs, int depth = 0)
{
    string file;
    auto src = moduleSource(path, root, libraryDirs, file);
    if (src is null)
        return null;
    auto o = outline(src, file);
    auto r = o.decls;
    if (depth < 8)
        foreach (re; o.reexports)
            r ~= visibleDecls(re, root, libraryDirs, depth + 1);
    return r;
}
