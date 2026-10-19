/// Code completion for the editor: what can be written at the cursor, from
/// the built-ins (lang/reference.d), the model's own declarations and the
/// modules it imports (read, not run). It works on the text before the
/// cursor, which is usually incomplete code.
module hackerscad.tool.complete;

import std.algorithm : canFind, endsWith, sort, startsWith;
import std.array : array, join, split;
import std.ascii : isAlphaNum, isDigit, isWhite;
import std.regex : ctRegex, matchAll;
import std.string : indexOf, lastIndexOf, strip, toLower;

import hackerscad.lang.reference;
import hackerscad.tool.outline;

struct Completion
{
    string label;    /// what the list shows
    string insert;   /// what replaces the typed prefix
    string kind;     /// function, method, property, field, parameter, keyword, unit, constant, type, module, annotation
    string detail;   /// signature or type
    string doc;
}

struct CompletionResult
{
    size_t from;           /// the typed prefix starts here (byte offset)
    string prefix;
    Completion[] items;
    string signature;      /// inside a call: the callee's signature
    int activeParam = -1;  /// and which argument the cursor is on
    string signatureDoc;
    string forms;          /// its ways to be called, when they are alternatives (Ref.usage)
}

/// What to offer at byte offset `cursor` of `source` (the file at `path`).
CompletionResult complete(string source, size_t cursor, string path, const string[] libraryDirs)
{
    import std.path : dirName, absolutePath;
    if (cursor > source.length)
        cursor = source.length;
    CompletionResult r;
    auto before = source[0 .. cursor];

    // the identifier being typed
    size_t start = cursor;
    while (start > 0 && isIdent(before[start - 1]))
        start--;
    r.from = start;
    r.prefix = before[start .. $];
    auto ctx = Context(source, cursor, path.length ? dirName(absolutePath(path)) : ".", libraryDirs);

    // inside a call: the signature, and the argument names
    signatureAt(ctx, before, r);

    if (inStringOrComment(before))
        return r;
    immutable ch = start > 0 ? before[start - 1] : '\0';
    if (ch == '@')
        r.items = annotations();
    else if (ch == '.' && numberBefore(before[0 .. start - 1]))
        r.items = units();
    else if (ch == '.')
        r.items = membersOf(ctx, receiverType(ctx, before[0 .. start - 1]));
    else if (isImportLine(before[0 .. start]))
        r.items = moduleNames(ctx);
    else
    {
        r.items = argumentNames(r) ~ general(ctx);
    }
    r.items = filtered(r.items, r.prefix);
    return r;
}

private bool isIdent(char c) => isAlphaNum(c) || c == '_';

/// The name at byte offset `at`: its signature and documentation, as the
/// editor shows them when the pointer rests on it. Empty when unknown.
string[2] describeAt(string source, size_t at, string path, const string[] libraryDirs)
{
    import std.path : dirName, absolutePath;
    if (at > source.length)
        return [null, null];
    size_t s = at, e = at;
    while (s > 0 && isIdent(source[s - 1]))
        s--;
    while (e < source.length && isIdent(source[e]))
        e++;
    if (s == e || isDigit(source[s]))
        return [null, null];
    auto word = source[s .. e];
    auto ctx = Context(source, e, path.length ? dirName(absolutePath(path)) : ".", libraryDirs);
    if (s > 0 && source[s - 1] == '.' && !numberBefore(source[0 .. s - 1]))
    {
        auto recv = receiverType(ctx, source[0 .. s - 1]);
        if (recv.startsWith("module:"))
            foreach (d; ctx.aliased(recv[7 .. $]))
                if (d.name == word)
                    return [d.signature, d.doc];
        foreach (d; ctx.all)
            if (d.name == word && d.on.length && (recv.length == 0 || d.on == recv))
                return [d.signature, d.doc];
        foreach (ref r; reference)
            if (r.name == word && r.on.length && (recv.length == 0 || applies(r.on, recv)))
                return [r.usage, withArguments(r)];
    }
    foreach (d; ctx.all)
        if (d.name == word && d.kind != Decl.Kind.field)
            return [d.signature, d.doc];
    foreach (ref r; reference)
        if (r.name == word && r.on.length == 0)
            return [r.kind == RefKind.annotation ? "@" ~ r.signature : r.usage, withArguments(r)];
    foreach (ref r; reference)
        if (r.name == word)
            return [r.usage, withArguments(r)];
    return [null, null];
}

/// A built-in's documentation, and for one called with arguments how they
/// go: in order, or by name in any order.
private string withArguments(const ref Ref r)
{
    if ((r.kind != RefKind.function_ && r.kind != RefKind.method) || r.paramNames.length < 2)
        return r.doc;
    import std.array : join;
    return r.doc ~ "\nArguments in order (" ~ r.paramNames.join(", ") ~ "), or by name in any order: name: value.";
}

/// Whether `text` ends with a number (30, 2.5), not a name like M3.
private bool numberBefore(string text)
{
    size_t s = text.length;
    while (s > 0 && (isIdent(text[s - 1]) || text[s - 1] == '.'))
        s--;
    auto token = text[s .. $];
    return token.length && isDigit(token[0]);
}

// ---------------------------------------------------------------- context

private struct Context
{
    string source;
    size_t cursor;
    string root;
    const(string)[] libraryDirs;

    Decl[] ownCache;
    bool ownDone;
    Decl[] importedCache;
    bool importedDone;
    Decl[][string] aliasCache;

    /// The model's declarations; while it does not parse (the line being
    /// typed), without the cursor's line.
    Decl[] own()
    {
        if (!ownDone)
        {
            ownDone = true;
            auto o = outline(source, "<model>");
            if (o.decls.length == 0)
            {
                auto ls = source[0 .. cursor].lastIndexOf('\n');
                auto le = source.indexOf('\n', cursor);
                auto blanked = source[0 .. ls < 0 ? 0 : ls] ~ (le < 0 ? "" : source[le .. $]);
                o = outline(blanked, "<model>");
            }
            ownCache = o.decls;
        }
        return ownCache;
    }

    /// The imports of the model, read from its text (it may not parse).
    Import[] imports()
    {
        Import[] r;
        foreach (m; matchAll(source, ctRegex!(`(?m)^\s*(?:public\s+)?import\s+([^;]+);`)))
            foreach (part; splitImports(m[1]))
                r ~= part;
        return r;
    }

    /// Declarations the model sees unqualified from its imports.
    Decl[] imported()
    {
        if (!importedDone)
        {
            importedDone = true;
            foreach (i; imports)
            {
                if (i.aliasName.length)
                    continue;
                auto decls = visibleDecls(i.path, root, libraryDirs);
                if (i.selective.length)
                {
                    foreach (d; decls)
                        if (i.selective.canFind(d.name) || d.kind == Decl.Kind.field)
                            importedCache ~= d;
                }
                else
                    importedCache ~= decls;
            }
        }
        return importedCache;
    }

    /// The declarations of a module imported as `name = …`.
    Decl[] aliased(string name)
    {
        if (auto d = name in aliasCache)
            return *d;
        Decl[] r;
        foreach (i; imports)
            if (i.aliasName == name)
                r = visibleDecls(i.path, root, libraryDirs);
        aliasCache[name] = r;
        return r;
    }

    /// Every declaration in reach: the model's and the imported ones.
    Decl[] all() => own ~ imported;
}

private struct Import
{
    string[] path;
    string aliasName;
    string[] selective;
}

/// "hardware : M3, hole" or "a, b.c" or "hw = hardware".
private Import[] splitImports(string text)
{
    Import[] r;
    auto colon = text.indexOf(':');
    if (colon >= 0)
    {
        Import i = oneImport(text[0 .. colon]);
        foreach (n; text[colon + 1 .. $].split(","))
            i.selective ~= n.strip;
        return [i];
    }
    foreach (part; text.split(","))
        r ~= oneImport(part);
    return r;
}

private Import oneImport(string text)
{
    Import i;
    auto eq = text.indexOf('=');
    if (eq >= 0)
    {
        i.aliasName = text[0 .. eq].strip;
        text = text[eq + 1 .. $];
    }
    foreach (p; text.strip.split("."))
        i.path ~= p.strip;
    return i;
}

// ---------------------------------------------------------------- types

/// The type of the expression that ends where `text` ends (before a dot).
private string receiverType(ref Context ctx, string text)
{
    // strip trailing spaces and newlines (chains break before the dot)
    size_t e = text.length;
    while (e > 0 && isWhite(text[e - 1]))
        e--;
    text = text[0 .. e];
    if (text.length == 0)
        return "";
    if (text[$ - 1] == ')')
    {
        // a call: the callee's result type
        auto open = matchingOpen(text, text.length - 1);
        if (open < 0)
            return "";
        auto calleeEnd = open;
        auto calleeStart = calleeEnd;
        while (calleeStart > 0 && isIdent(text[calleeStart - 1]))
            calleeStart--;
        auto callee = text[calleeStart .. calleeEnd];
        auto recvBefore = calleeStart > 0 && text[calleeStart - 1] == '.' ? receiverType(ctx, text[0 .. calleeStart - 1]) : "";
        return resultType(ctx, callee, recvBefore);
    }
    if (text[$ - 1] == ']')
    {
        auto open = matchingOpen(text, text.length - 1);
        if (open < 0)
            return "";
        auto t = receiverType(ctx, text[0 .. open]);
        return t.endsWith("[]") ? t[0 .. $ - 2] : "";
    }
    // an identifier, maybe after another dot
    size_t s = text.length;
    while (s > 0 && isIdent(text[s - 1]))
        s--;
    auto name = text[s .. $];
    if (name.length == 0)
        return "";
    if (s > 0 && text[s - 1] == '.')
    {
        if (numberBefore(text[0 .. s - 1]))
            return "Length";   // 30.mm.
        auto recv = receiverType(ctx, text[0 .. s - 1]);
        if (recv.startsWith("module:"))
            foreach (d; ctx.aliased(recv[7 .. $]))
                if (d.name == name)
                    return d.type;
        return memberType(ctx, recv, name);
    }
    return nameType(ctx, name);
}

/// The type a name has where it is used.
private string nameType(ref Context ctx, string name)
{
    if (name == "edges")
        return "Edges";
    if (name == "faces")
        return "Faces";
    foreach (i; ctx.imports)
        if (i.aliasName == name)
            return "module:" ~ name;
    foreach (d; ctx.all)
        if (d.name == name && d.kind == Decl.Kind.constant && d.type.length)
            return d.type;
    foreach (d; ctx.all)
        if (d.name == name && d.kind == Decl.Kind.function_)
            return d.type;   // a paren-less call: body.bbox
    foreach (ref e; reference)
        if (e.name == name && e.on.length == 0 && e.kind == RefKind.constant)
            return e.type;
    // a local: auto name = …; or Type name = …;
    auto before = ctx.source[0 .. ctx.cursor];
    string found;
    foreach (m; matchAll(before, ctRegex!(`\b(\w+)\s+(\w+)\s*=\s*([^;]*)`)))
        if (m[2] == name)
        {
            if (m[1] != "auto" && m[1] != "immutable" && m[1] != "const")
                found = m[1];
            else
                found = expressionType(ctx, m[3]);
        }
    // a parameter of the function being written: (Solid s, Length h)
    if (found.length == 0)
        foreach (m; matchAll(before, ctRegex!(`[(,]\s*(\w+)\s+(\w+)\s*(?:=[^,)]*)?(?=[,)])`)))
            if (m[2] == name)
                found = m[1];
    return found;
}

/// The type of an initializer, from its outermost call chain.
private string expressionType(ref Context ctx, string expr)
{
    expr = expr.strip;
    // up to the first top-level operator, the chain decides
    return receiverType(ctx, expr);
}

/// The result of calling `callee` (on a value of type `recv`, if a method).
private string resultType(ref Context ctx, string callee, string recv)
{
    if (recv.startsWith("module:"))
    {
        foreach (d; ctx.aliased(recv[7 .. $]))
            if (d.name == callee)
                return d.type;
        return "";
    }
    foreach (d; ctx.all)
        if (d.name == callee && d.kind == Decl.Kind.function_)
            return d.type;
    foreach (d; ctx.all)
        if (d.name == callee && d.kind == Decl.Kind.struct_)
            return callee;
    string any;
    foreach (ref e; reference)
        if (e.name == callee && (e.kind == RefKind.function_ || e.kind == RefKind.method))
        {
            auto t = e.type.length ? e.type : recv;   // transforms give what they get
            if (recv.length && applies(e.on, recv))
                return t;
            if (any.length == 0)
                any = t;
        }
    return any;
}

private string memberType(ref Context ctx, string recv, string name)
{
    foreach (d; ctx.all)
        if (d.kind == Decl.Kind.field && d.on == recv && d.name == name)
            return d.type;
    foreach (ref e; reference)
        if (e.name == name && e.on.length && (recv.length == 0 || applies(e.on, recv)))
            return e.type.length ? e.type : recv;
    return "";
}

/// Whether a member defined on `on` applies to a value of type `t`.
private bool applies(string on, string t)
{
    if (on == t)
        return true;
    if (on == "Shape")
        return t == "Solid" || t == "Profile";
    if (on == "list")
        return t.endsWith("[]");
    if (on == "Frame")
        return t == "Plane" || t == "Axis";   // origin and friends
    return false;
}

// ---------------------------------------------------------------- items

private Completion[] membersOf(ref Context ctx, string t)
{
    Completion[] r;
    if (t.startsWith("module:"))
    {
        foreach (d; ctx.aliased(t[7 .. $]))
            if (d.kind != Decl.Kind.field)
                r ~= fromDecl(d);
        return r;
    }
    // struct fields and methods (Screw: M3.clearance)
    foreach (d; ctx.all)
        if ((d.kind == Decl.Kind.field || d.kind == Decl.Kind.function_) && d.on.length && d.on == t)
            r ~= fromDecl(d, true);
    bool[string] seen;
    foreach (ref e; reference)
    {
        if (e.on.length == 0)
            continue;
        if (t.length ? !applies(e.on, t) : !(e.on == "Solid" || e.on == "Shape" || e.on == "list"))
            continue;
        auto key = e.name ~ "/" ~ e.on;
        if (key in seen)
            continue;
        seen[key] = true;
        r ~= fromRef(e);
    }
    // user and library functions whose first argument fits (UFCS)
    if (t.length)
        foreach (d; ctx.all)
            if (d.kind == Decl.Kind.function_ && d.on == t && !r.canFind!(c => c.label == d.name))
                r ~= fromDecl(d, true);
    return r;
}

private Completion[] general(ref Context ctx)
{
    Completion[] r;
    foreach (ref e; reference)
        if (e.on.length == 0 && e.kind != RefKind.annotation)
            r ~= fromRef(e);
    foreach (d; ctx.all)
        if (d.kind != Decl.Kind.field)
            r ~= fromDecl(d);
    foreach (name, type; locals(ctx))
        r ~= Completion(name, name, "variable", type, "");
    foreach (i; ctx.imports)
        if (i.aliasName.length)
            r ~= Completion(i.aliasName, i.aliasName, "module", i.path.join("."), "");
    return r;
}

/// Variables declared before the cursor (auto x = …, Solid s = …).
private string[string] locals(ref Context ctx)
{
    string[string] r;
    auto before = ctx.source[0 .. ctx.cursor];
    // only the declaration the cursor is in: from its first line, the last
    // one that starts at the left margin with a name or an annotation
    size_t start;
    foreach (m; matchAll(before, ctRegex!(`(?:^|\n)[A-Za-z_@][^\n]*`)))
        start = m.pre.length;
    before = before[start .. $];
    foreach (m; matchAll(before, ctRegex!(`\b(auto|immutable|const|Solid|Profile|Length|Angle|Vec|int|double|bool|string)\s+(\w+)\s*=`)))
        r[m[2]] = m[1] == "auto" || m[1] == "immutable" || m[1] == "const" ? "" : m[1];
    foreach (m; matchAll(before, ctRegex!(`foreach\s*\(\s*(?:(\w+)\s*,\s*)?(\w+)\s*;`)))
    {
        if (m[1].length)
            r[m[1]] = "int";
        r[m[2]] = "";
    }
    return r;
}

private Completion[] annotations()
{
    Completion[] r;
    foreach (ref e; reference)
        if (e.kind == RefKind.annotation)
            r ~= Completion(e.name, e.name, "annotation", e.params.length ? "@" ~ e.name ~ "(" ~ e.params.join(", ") ~ ")" : "@" ~ e.name, e.doc);
    return r;
}

private Completion[] units()
{
    Completion[] r;
    foreach (ref e; reference)
        if (e.kind == RefKind.unit)
            r ~= Completion(e.name, e.name, "unit", "", e.doc);
    return r;
}

private bool isImportLine(string before)
{
    auto ls = before.lastIndexOf('\n');
    auto line = before[ls + 1 .. $].strip;
    return line.startsWith("import") || line.startsWith("public import");
}

private Completion[] moduleNames(ref Context ctx)
{
    import std.file : dirEntries, SpanMode, exists, isDir;
    import std.path : baseName, stripExtension, buildPath;
    import hackerscad.lang.builtins : librarySources, stdModules;
    Completion[] r;
    foreach (name; librarySources.keys.sort)
        r ~= Completion("std." ~ name, "std." ~ name, "module", "built-in library", "");
    foreach (name; stdModules)
        r ~= Completion(name, name, "module", "standard module", "");
    foreach (base; [ctx.root] ~ ctx.libraryDirs)
    {
        if (base.length == 0 || !exists(base) || !isDir(base))
            continue;
        try
            foreach (e; dirEntries(base, SpanMode.shallow))
            {
                auto n = baseName(e.name);
                if (e.isFile && n.endsWith(".hcad"))
                    r ~= Completion(n.stripExtension, n.stripExtension, "module", e.name, "");
                else if (e.isDir && exists(buildPath(e.name, "package.hcad")))
                    r ~= Completion(n, n, "module", "package " ~ e.name, "");
            }
        catch (Exception)
        {
        }
    }
    return r;
}

private Completion fromRef(const Ref e)
{
    string kind;
    final switch (e.kind)
    {
    case RefKind.function_: kind = "function"; break;
    case RefKind.method: kind = "method"; break;
    case RefKind.property: kind = "property"; break;
    case RefKind.keyword: kind = "keyword"; break;
    case RefKind.unit: kind = "unit"; break;
    case RefKind.constant: kind = "constant"; break;
    case RefKind.type: kind = "type"; break;
    case RefKind.annotation: kind = "annotation"; break;
    }
    return Completion(e.name, e.name, kind, e.signature, e.doc);
}

private Completion fromDecl(Decl d, bool member = false)
{
    final switch (d.kind)
    {
    case Decl.Kind.function_:
        return Completion(d.name, d.name, member ? "method" : "function", d.signature, d.doc);
    case Decl.Kind.struct_:
        return Completion(d.name, d.name, "type", d.signature, d.doc);
    case Decl.Kind.field:
        return Completion(d.name, d.name, "field", d.signature, d.doc);
    case Decl.Kind.constant:
        return Completion(d.name, d.name, "constant", d.signature, d.doc);
    }
}

/// Starting with the prefix first, then containing it; one per label.
private Completion[] filtered(Completion[] items, string prefix)
{
    auto p = prefix.toLower;
    Completion[] first, second;
    bool[string] seen;
    foreach (c; items)
    {
        auto l = c.label.toLower;
        if (c.label in seen)
            continue;
        if (l.startsWith(p))
            first ~= c;
        else if (p.length >= 2 && l.indexOf(p) >= 0)
            second ~= c;
        else
            continue;
        seen[c.label] = true;
    }
    // the free argument names of the call first, in the order of the
    // signature, then the shorter names
    Completion[] arguments, rest;
    foreach (c; first)
        (c.kind == "parameter" ? arguments : rest) ~= c;
    rest.sort!((a, b) => a.label.length != b.label.length ? a.label.length < b.label.length : a.label < b.label);
    return arguments ~ rest ~ second;
}

// ---------------------------------------------------------------- calls

/// The innermost unclosed call around the cursor: its signature, the
/// argument the cursor is on, and the argument names still free.
private void signatureAt(ref Context ctx, string before, ref CompletionResult r)
{
    int depth = 0;
    int commas = 0;
    long i = cast(long) before.length - 1;
    string used;
    for (; i >= 0; i--)
    {
        auto c = before[i];
        if (c == ')' || c == ']')
            depth++;
        else if (c == '(' || c == '[')
        {
            if (depth == 0)
                break;
            depth--;
        }
        else if (c == ',' && depth == 0)
            commas++;
        else if (c == ';' || c == '{' || c == '}')
            return;
    }
    if (i < 0 || before[i] != '(')
        return;
    auto args = before[i + 1 .. $];
    size_t s = i;
    while (s > 0 && isIdent(before[s - 1]))
        s--;
    auto callee = before[s .. i];
    if (callee.length == 0)
        return;
    auto recv = s > 0 && before[s - 1] == '.' ? receiverType(ctx, before[0 .. s - 1]) : "";
    string[] params;
    // the model's and imported functions first, then the built-ins
    foreach (d; ctx.all)
        if (d.name == callee && (d.kind == Decl.Kind.function_ || d.kind == Decl.Kind.struct_))
        {
            r.signature = d.signature;
            r.signatureDoc = d.doc;
            params = d.params;
            // called after a dot, the first parameter is the receiver
            if (recv.length && params.length && d.on.length)
                params = params[1 .. $];
            break;
        }
    if (r.signature.length == 0)
        foreach (ref e; reference)
            if (e.name == callee && (e.kind == RefKind.function_ || e.kind == RefKind.method)
                && (recv.length == 0 || e.on.length == 0 || applies(e.on, recv)))
            {
                r.signature = e.signature;
                r.signatureDoc = e.doc;
                r.forms = e.forms.length ? e.usage : null;
                params = e.paramNames;
                break;
            }
    if (r.signature.length == 0)
        return;
    r.activeParam = commas;
    // a named argument being typed decides which one is active
    auto lastArg = args[args.lastIndexOf(',') + 1 .. $];
    auto colon = lastArg.indexOf(':');
    // after a named argument only named ones can follow: an empty argument
    // will be the first one not given yet, a positional one is none
    if (colon < 0 && args[0 .. args.length - lastArg.length].indexOf(':') >= 0)
    {
        r.activeParam = -1;
        if (lastArg.strip.length == 0)
            foreach (k, p; params)
                if (args.indexOf(p ~ ":") < 0)
                {
                    r.activeParam = cast(int) k;
                    break;
                }
    }
    if (colon > 0)
    {
        auto n = lastArg[0 .. colon].strip;
        foreach (k, p; params)
            if (p == n)
                r.activeParam = cast(int) k;
    }
    // argument names not given yet, offered as "name: "
    foreach (p; params)
        if (args.indexOf(p ~ ":") < 0)
            r.items ~= Completion(p ~ ":", p ~ ": ", "parameter", parameterIn(r.signature, p),
                r.signature ~ (r.signatureDoc.length ? "\n\n" ~ r.signatureDoc : ""));
}

/// A parameter as the signature declares it: "h: Length".
private string parameterIn(string signature, string name)
{
    auto open = signature.indexOf('(');
    auto close = signature.lastIndexOf(')');
    if (open < 0 || close <= open)
        return name;
    foreach (part; signature[open + 1 .. close].split(", "))
    {
        auto p = part.strip;
        if (p == name || p.startsWith(name ~ ":") || p.startsWith(name ~ " ="))
            return p;
    }
    return name;
}

private Completion[] argumentNames(ref CompletionResult r) => r.items;

private long matchingOpen(string text, size_t close)
{
    int depth = 0;
    for (long i = close; i >= 0; i--)
    {
        auto c = text[i];
        if (c == ')' || c == ']')
            depth++;
        else if (c == '(' || c == '[')
        {
            depth--;
            if (depth == 0)
                return i;
        }
    }
    return -1;
}

/// Whether the cursor is in a string or a line comment (no completion there).
private bool inStringOrComment(string before)
{
    auto ls = before.lastIndexOf('\n');
    auto line = before[ls + 1 .. $];
    bool inString;
    foreach (k, c; line)
    {
        if (c == '"' && (k == 0 || line[k - 1] != '\\'))
            inString = !inString;
        else if (!inString && c == '/' && k + 1 < line.length && line[k + 1] == '/')
            return true;
    }
    return inString;
}

unittest
{
    // after a dot on a call chain: Solid methods
    auto src = "module m;\nimport std.shapes;\n@part Solid a() => box(1, 2, 3).fi";
    auto r = complete(src, src.length, "", null);
    assert(r.prefix == "fi" && r.items.length && r.items[0].label == "fillet", r.items.length ? r.items[0].label : "none");

    // inside a call: the signature and the free argument names
    src = "module m;\nimport std.shapes;\n@part Solid a() => box(1, 2, 3).shell(open: faces.top, ";
    r = complete(src, src.length, "", null);
    assert(r.signature.startsWith("shell(") && r.activeParam == 1);
    assert(r.items.canFind!(c => c.label == "thickness:") && !r.items.canFind!(c => c.label == "open:"));
    assert(r.items[0].kind == "parameter", r.items[0].label);

    // selectors
    src = "module m;\n@part Solid a() => box(1, 2, 3).fillet(edges.pa";
    r = complete(src, src.length, "", null);
    assert(r.items.length && r.items[0].label == "parallel");

    // a library: functions after import, struct fields after a constant
    src = "module m;\nimport std.hardware;\n@part Solid a() => ho";
    r = complete(src, src.length, "", null);
    assert(r.items.canFind!(c => c.label == "hole"), "hole");
    src = "module m;\nimport std.hardware : M3;\nimmutable d = M3.cl";
    r = complete(src, src.length, "", null);
    assert(r.items.length && r.items[0].label == "clearance");

    // another function's variables are not offered
    src = "module m;\nSolid a()\n{\n    auto zzz = 1;\n    return box(1, 2, 3);\n}\nSolid b() => zz";
    r = complete(src, src.length, "", null);
    assert(!r.items.canFind!(c => c.label == "zzz"));

    // a local variable's type from its initializer
    src = "module m;\n@part Solid a()\n{\n    auto p = rect(10, 20);\n    return p.ex";
    r = complete(src, src.length, "", null);
    assert(r.items.length && r.items[0].label == "extrude");

    // units after a number, annotations after @
    src = "immutable w = 30.m";
    r = complete(src, src.length, "", null);
    assert(r.items.canFind!(c => c.label == "mm"));
    src = "@pa";
    r = complete(src, src.length, "", null);
    assert(r.items.length == 3 && r.items[0].label == "part" && r.items.canFind!(c => c.label == "parts"));

    // hover: a built-in, a method after a dot, a library function
    src = "module m;\nimport std.hardware;\n@part Solid a() => box(1, 2, 3).fillet(edges.parallel(Z), r: 1) - hole(M3, 2);";
    assert(describeAt(src, src.indexOf("box") + 1, "", null)[0].startsWith("box("));
    assert(describeAt(src, src.indexOf("fillet") + 2, "", null)[0].startsWith("fillet("));
    assert(describeAt(src, src.indexOf("parallel") + 2, "", null)[0].startsWith("parallel("));
    assert(describeAt(src, src.indexOf("hole") + 1, "", null)[0].startsWith("hole(s: Screw"));

    // the library's signature inside its call
    src = "module m;\nimport std.hardware;\n@part Solid a() => hole(M3, ";
    r = complete(src, src.length, "", null);
    assert(r.signature.startsWith("hole(s: Screw") && r.activeParam == 1, r.signature);
}

unittest
{
    // a name whose parameters are alternatives shows its forms, simplest first
    auto src = "module m;\n@part Solid p() => box(1, 1, 1).rotate(z: 45);\n";
    import std.string : indexOf;
    auto d = describeAt(src, src.indexOf("rotate") + 2, "", null);
    assert(d[0].indexOf("s.rotate(z: 45)") == 0, d[0]);
    assert(d[0].indexOf("around: p") > 0 && d[0].indexOf("\n") > 0, d[0]);
    assert(d[1].indexOf("Arguments in order") > 0, d[1]);
    // one without forms keeps its signature
    auto b = describeAt(src, src.indexOf("box") + 1, "", null);
    assert(b[0].indexOf("box(x: Length") == 0, b[0]);
}
