module hackerscad.lang.interp;

import std.conv : ConvException, to;
import std.format : format;
import std.math : PI, abs, floor, isNaN, fmod;
import std.algorithm : canFind, map;
import std.array : array, join;
import std.path : buildNormalizedPath, absolutePath, dirName, relativePath, isAbsolute;
import std.file : exists, readText;
import std.string : startsWith, strip;
import std.uni : toLower;

import hackerscad.lang.errors;
import hackerscad.lang.lexer : Tok;
import hackerscad.lang.ast;
import hackerscad.lang.parser;
import hackerscad.lang.value;
import hackerscad.kernel.brep;

struct LogLine
{
    string text;
    Span span;
}

struct ParamInfo
{
    string name;
    Value value;       /// effective value (default or override)
    Value defaultValue;
    string doc;
    Value min, max, step;
    Value[] choices;
    Value[string] presets;   /// preset name → value
    Span span;
}

struct PartResult
{
    string name;
    SolidVal solid;
    uint rgb;       /// see alphaOf
    Span span;
    bool export_ = true;   /// false: shown, but left out of STL/3MF/STEP (a reference part)
    string label;   /// the name in exported files: @part(name:), or `name`
}

/// A modelling operation that creates faces, with the code that ran it.
struct FeatureInfo
{
    string kind;
    Span span;
    SolidVal result;   /// the solid right after the feature (for rollback views)
    bool moved;        /// result is the solid moved, turned or mirrored right after it was made
    SolidVal[] operands;   /// of a union, difference or intersection: the two solids it combined
    Object frame;      /// the function call it ran in (Interp.callFrame)
}

/// A solid, profile or path a call in the evaluated file produced (the
/// GUI's Inspect shows them): recorded only with Interp.recordTrace.
struct TraceEntry
{
    Span site;      /// the call or operator that produced it
    Span decl;      /// for what a function returned: the function's name, else empty
    string fn;      /// the function called, or the operator
    string kind;    /// Solid, Profile or Path
    SolidVal value;
    uint calls;     /// how many times the site ran (only the first ones and the last are kept)
    uint after;     /// how many features were made before it: its place among them
    uint seq;       /// the order of the entries made between the same two features
}

/// How many times the calls that made `entries` ran, each call site counted once.
uint callsOf(const TraceEntry[] entries)
{
    uint total;
    Span[] seen;
    foreach (e; entries)
    {
        import std.algorithm : canFind;
        if (seen.canFind(e.site))
            continue;
        seen ~= e.site;
        total += e.calls;
    }
    return total;
}

/// A function declared in a file and the lines it covers (up to the next
/// declaration), for the GUI's feature tree and Inspect.
struct FunctionInfo
{
    string name;       /// "Struct.method" for methods
    Span nameSpan;     /// what TraceEntry.decl points at
    uint first, last;  /// lines, attributes included; last is uint.max for the last one
}

/// A @drawing function and the drawing it returned (rendered on export).
struct DrawingResult
{
    string name;
    ObjectVal drawing;   /// a DrawingVal
    Span span;
}

struct EvalResult
{
    PartResult[] parts;
    DrawingResult[] drawings;
    ParamInfo[] params;
    string[] presets;
    FeatureInfo[] features;   /// features[id - 1] for SolidVal.creators ids
    TraceEntry[] trace;       /// with Interp.recordTrace: the geometry each call made
    LogLine[] log;
    Diagnostic[] diagnostics;   /// warnings and failed unittests
}

/// The stack of the thread a model is evaluated on.
enum size_t evalStackSize = 512 * 1024 * 1024;

struct Limits
{
    size_t steps = 200_000_000;
    uint depth = 1000;
    size_t arrayLength = 10_000_000;
}

private enum Flow
{
    normal,
    break_,
    continue_,
    return_,
}

final class Interp
{
    BrepKernel kernel;
    string root;              /// project directory: imports cannot leave it
    /// Folders searched after the project for `import name;`: the
    /// personal library folder and $HCAD_PATH (see libraryPaths()).
    string[] libraryDirs;
    Limits limits;
    string[string] overrides; /// -D name=expr
    string preset;            /// --preset name
    shared(bool)* cancel;     /// set by another thread to abandon the evaluation
    void delegate(string) onStage;   /// told what is being evaluated (the GUI shows it)

    LogLine[] log;
    Diagnostic[] diagnostics;
    ParamInfo[] params;
    string[] presetNames;
    FeatureInfo[] features;
    ObjectVal[] sketches;     /// sketches created by the run, for the GUI
    /// Records in `trace` the geometry the calls of the evaluated file make
    /// (the GUI's Inspect); off by default, it costs time and memory.
    bool recordTrace;
    TraceEntry[] trace;

    Env prelude;
    ModuleVal[string] modules;
    string[string] embedded;  /// built-in .hcad libraries by module name

    private size_t steps;
    private uint depth;
    private Value returnValue;
    private Value[FuncDecl] partCache;
    private bool[FuncDecl] partsInProgress;
    private string traceFile;              /// the evaluated file: only its calls are traced
    private TraceSite[Span] traceSites;

    this(BrepKernel kernel)
    {
        this.kernel = kernel;
        libraryDirs = libraryPaths();
        prelude = new Env(null, null);
        import hackerscad.lang.builtins : installPrelude;
        installPrelude(this, prelude);
    }

    // ------------------------------------------------------------ entry points

    /// Evaluates a model file: parameters, parts and unittests.
    EvalResult run(string path)
    {
        auto full = absolutePath(path);
        if (root is null)
            root = dirName(full);
        return runSource(readText(full), full);
    }

    EvalResult runSource(string source, string path)
    {
        // a failure that is not a model error (a bug, a library throwing)
        // is still reported as one, instead of ending the program
        // on a thread with a large stack: deep recursion in a model (up to
        // the limit of calls) and deeply nested code must not overflow it
        import core.thread : Thread;
        static bool onEvalThread;   // thread-local: true on the thread below
        if (!onEvalThread)
        {
            EvalResult r;
            auto t = new Thread({
                onEvalThread = true;
                r = runSource(source, path);
            }, evalStackSize);
            t.start();
            t.join(true);   // rethrows what the thread threw
            return r;
        }
        try
            return runSourceUnguarded(source, path);
        catch (HcadError e)
            throw e;
        catch (KernelException e)
            throw e;
        catch (Exception e)
            throw new HcadError(Code.type, e.msg, Span(path, 1, 1));
    }

    private EvalResult runSourceUnguarded(string source, string path)
    {
        if (root is null)
            root = dirName(absolutePath(path));
        traceFile = path;
        auto mod = loadModule(source, path, baseName(path));
        EvalResult r;

        // preset names, from @preset("name", value) on the parameters
        foreach (d; collectOrdered!VarDecl(mod))
            if (hasAttr(d.attrs, "param"))
                foreach (a; d.attrs)
                    if (a.name == "preset")
                    {
                        auto lit = a.args.length == 2 ? cast(Literal) a.args[0].value : null;
                        if (lit is null || lit.type != Literal.Type.string_ || a.args[0].name.length || a.args[1].name.length)
                            throw new HcadError(Code.syntax, `use @preset("name", value)`, a.span);
                        if (!presetNames.canFind(lit.text))
                            presetNames ~= lit.text;
                    }
        if (preset.length && !presetNames.canFind(preset))
            throw new HcadError(Code.undefined, format("unknown preset '%s'", preset), Span(path, 0, 0), suggest(preset, presetNames));

        // parameters, in source order
        foreach (d; collectOrdered!VarDecl(mod))
            if (hasAttr(d.attrs, "param"))
                global(mod.env, d.name, d.nameSpan);
        foreach (name, _; overrides)
            if (!params.canFind!(p => p.name == name))
                throw new HcadError(Code.undefined, format("'%s' is not a @param of this model", name), Span(path),
                    suggest(name, params.map!(p => p.name).array));

        // parts
        size_t partCount, partIndex;
        foreach (f; collectOrdered!FuncDecl(mod))
            partCount += findAttr(f.attrs, "part") !is null;
        foreach (f; collectOrdered!FuncDecl(mod))
        {
            auto a = findAttr(f.attrs, "part");
            if (a is null)
                continue;
            stage(format("part %d of %d: %s", ++partIndex, partCount, f.name));
            auto v = callPart(f, mod);
            if (v.kind != Kind.solid)
                throw new HcadError(Code.type, format("@part '%s' must return a Solid, not %s", f.name, v.typeName), f.nameSpan);
            if (v.solid.brep is null)
                throw new HcadError(Code.kernel, format("@part '%s' is empty (did a boolean remove everything?)", f.name), f.nameSpan);
            if (v.solid.path)
                throw new HcadError(Code.type, format("@part '%s' returns a Path: sweep a profile along it", f.name), f.nameSpan);
            if (v.solid.flat)
                throw new HcadError(Code.type, format("@part '%s' returns a 2D profile: extrude or revolve it", f.name), f.nameSpan);
            // @part("colour", alpha: 0.5, export: false, name: "Tank")
            import hackerscad.lang.builtins : colorOf;
            uint rgb = v.solid.hasColor ? v.solid.rgb : defaultPartColor;
            bool export_ = true;
            string label = f.name;
            foreach (i, arg; a.args)
            {
                auto val = eval(arg.value, mod.env);
                if (arg.name.length == 0 && i == 0)
                    rgb = colorOf(val, arg.span);
                else if (arg.name == "alpha")
                {
                    if (!val.isNum || val.n.value < 0 || val.n.value > 1)
                        throw new HcadError(Code.type, "alpha goes from 0 (invisible) to 1 (opaque)", arg.span);
                    rgb = withAlpha(rgb, val.n.value);
                }
                else if (arg.name == "export")
                {
                    if (val.kind != Kind.bool_)
                        throw new HcadError(Code.type, "export must be true or false", arg.span);
                    export_ = val.b;
                }
                else if (arg.name == "name")
                {
                    if (val.kind != Kind.str || val.s.strip.length == 0)
                        throw new HcadError(Code.type, "name is the part's name in exported files: a text, "
                            ~ "like name: \"Tank\"", arg.span);
                    label = val.s.strip;
                }
                else
                    throw new HcadError(Code.type, "@part takes a colour, alpha:, export: and name:", arg.span,
                        suggest(arg.name, ["alpha", "export", "name"]));
            }
            foreach (q; r.parts)
                if (q.label.toLower == label.toLower)
                    throw new HcadError(Code.type, format("two parts would have the same name in exported files, "
                        ~ "'%s': give one a name: of its own", label), f.nameSpan);
            r.parts ~= PartResult(f.name, v.solid, rgb, f.nameSpan, export_, label);
        }
        // drawings: collected here, projected only when exported
        foreach (f; collectOrdered!FuncDecl(mod))
        {
            if (findAttr(f.attrs, "drawing") is null)
                continue;
            auto v = callPart(f, mod);
            if (v.kind != Kind.object_ || v.obj.typeName != "Drawing")
                throw new HcadError(Code.type, format("@drawing '%s' must return a Drawing (drawing(…)), not %s", f.name,
                    v.typeName), f.nameSpan);
            r.drawings ~= DrawingResult(f.name, v.obj, f.nameSpan);
        }
        if (r.parts.length == 0 && r.drawings.length == 0)
            diagnostics ~= Diagnostic(Severity.warning, Code.undefined, "the model has no @part function: nothing to export",
                Span(path, 1, 1));

        // unittests are design checks: failures are reported, geometry is kept
        if (mod.unittests.length)
            stage("checks (unittest)");
        foreach (s; mod.unittests)
        {
            try
                execBlock(s.body, new Env(mod.env, mod));
            catch (HcadError e)
                diagnostics ~= e.diag;
            catch (KernelException e)
                diagnostics ~= Diagnostic(Severity.error, Code.kernel, e.msg, s.span);
        }

        r.params = params;
        r.presets = presetNames;
        r.features = features;
        finishTrace();
        r.trace = trace;
        r.log = log;
        r.diagnostics = diagnostics;
        return r;
    }

    // ------------------------------------------------------------ modules

    /// The functions and struct methods declared in a file evaluated (or
    /// imported) by this run, in source order.
    FunctionInfo[] functionsOf(string path)
    {
        auto mod = path in modules;
        if (mod is null || mod.program is null)
            return null;
        static uint startOf(Stmt d, Attribute[] attrs)
        {
            uint l = d.span.line;
            foreach (a; attrs)
                if (a.span.line > 0 && a.span.line < l)
                    l = a.span.line;
            return l;
        }
        // every declaration starts a range: the functions' ones are kept
        struct Start
        {
            uint line;
            string name;
            FuncDecl f;
        }
        Start[] starts;
        void walk(Stmt[] decls)
        {
            foreach (d; decls)
            {
                if (auto b = cast(Block) d)
                    walk(b.stmts);
                else if (auto f = cast(FuncDecl) d)
                    starts ~= Start(startOf(f, f.attrs), f.name, f);
                else if (auto st = cast(StructDecl) d)
                {
                    starts ~= Start(st.span.line, st.name, null);
                    foreach (m; st.methods)
                        starts ~= Start(startOf(m, m.attrs), st.name ~ "." ~ m.name, m);
                }
                else if (auto v = cast(VarDecl) d)
                    starts ~= Start(startOf(v, v.attrs), v.name, null);
                else if (d !is null)
                    starts ~= Start(d.span.line, null, null);
            }
        }
        walk(mod.program.decls);
        import std.algorithm : sort;
        starts.sort!((a, b) => a.line < b.line);
        FunctionInfo[] r;
        foreach (i, st; starts)
            if (st.f !is null)
            {
                uint last = uint.max;
                foreach (nx; starts[i + 1 .. $])
                    if (nx.line > st.line)
                    {
                        last = nx.line - 1;
                        break;
                    }
                r ~= FunctionInfo(st.name, st.f.nameSpan, st.line, last);
            }
        return r;
    }

    /// The names the prelude defines (built-ins, units, constants).
    string[] preludeNames() => prelude.vars.keys;

    private void stage(string what)
    {
        if (onStage !is null)
            onStage(what);
    }

    ModuleVal loadModule(string source, string path, string name)
    {
        if (auto m = path in modules)
            return *m;
        auto prog = parse(source, path);
        auto mod = new ModuleVal;
        mod.name = prog.moduleDecl ? prog.moduleDecl.name.join(".") : name;
        mod.path = path;
        mod.source = source;
        mod.env = new Env(prelude, mod);
        mod.program = prog;
        modules[path] = mod;

        if (prog.moduleDecl)
            foreach (a; prog.moduleDecl.attrs)
            {
                if (a.name != "unit")
                    throw new HcadError(Code.syntax, format("unknown module attribute '@%s'", a.name), a.span, suggest(a.name, ["unit"]));
                if (a.args.length != 1)
                    throw new HcadError(Code.arity, "@unit takes one unit, e.g. @unit(inch)", a.span);
                auto u = eval(a.args[0].value, prelude);
                if (u.kind != Kind.builtin || u.bi.unitFactor == 0 || u.bi.unitDim != Dim.length)
                    throw new HcadError(Code.type, "@unit needs a length unit: mm, cm, m or inch", a.args[0].span);
                mod.unitFactor = u.bi.unitFactor;
            }

        foreach (d; prog.decls)
            declare(d, mod);
        return mod;
    }

    private void declare(Stmt d, ModuleVal mod)
    {
        auto env = mod.env;
        void define(string name, Value v, Span span, bool isPrivate)
        {
            if (name in env.vars || name in env.pending)
                throw new HcadError(Code.redefined, format("'%s' is already defined in this module", name), span);
            env.vars[name] = v;
            env.readonly[name] = true;
            if (!isPrivate)
                mod.publicNames[name] = true;
        }

        if (auto v = cast(VarDecl) d)
        {
            checkAttrs(v.attrs, ["param", "preset"]);
            if (findAttr(v.attrs, "preset") && !hasAttr(v.attrs, "param"))
                throw new HcadError(Code.syntax, "@preset can only be used on a @param", findAttr(v.attrs, "preset").span);
            if (v.name in env.vars || v.name in env.pending)
                throw new HcadError(Code.redefined, format("'%s' is already defined in this module", v.name), v.nameSpan);
            env.pending[v.name] = v;
            env.readonly[v.name] = true;
            if (!v.isPrivate)
                mod.publicNames[v.name] = true;
        }
        else if (auto b = cast(Block) d)
            foreach (s; b.stmts)
                declare(s, mod);
        else if (auto f = cast(FuncDecl) d)
        {
            checkAttrs(f.attrs, ["part", "drawing"]);
            define(f.name, Value.make(Kind.func, closureOf(f, env, mod)), f.nameSpan, f.isPrivate);
        }
        else if (auto s = cast(StructDecl) d)
            define(s.name, Value.make(Kind.type, structType(s, mod)), s.span, s.isPrivate);
        else if (auto i = cast(ImportDecl) d)
            doImport(i, mod);
        else if (auto u = cast(Unittest) d)
            mod.unittests ~= u;
        else
            throw new HcadError(Code.syntax, "only declarations are allowed at module level (move this inside a function)", d.span);
    }

    private void checkAttrs(Attribute[] attrs, string[] allowed)
    {
        foreach (a; attrs)
            if (!allowed.canFind(a.name))
            {
                string list;
                foreach (i, x; allowed)
                    list ~= (i ? ", @" : "@") ~ x;
                throw new HcadError(Code.syntax, format("unknown attribute '@%s' here (allowed: %s)", a.name, list),
                    a.span, suggest(a.name, allowed));
            }
    }

    private void doImport(ImportDecl d, ModuleVal into)
    {
        auto name = d.path.join(".");
        ModuleVal mod;
        if (auto src = name in embedded)
        {
            // one module per library, whatever name imported it
            auto canonical = name.startsWith("std.") ? name[4 .. $] : name;
            mod = loadModule(embedded[canonical], "<" ~ canonical ~ ">", canonical);
        }
        else if (d.path[0] == "std")
        {
            import hackerscad.lang.builtins : stdModules;
            if (!stdModules.canFind(name))
                throw new HcadError(Code.import_, format("unknown standard module '%s'", name), d.span, suggest(name, stdModules));
            if (d.selective.length || d.aliasName.length)
            {
                // std symbols live in the prelude: expose them under the requested names
                auto m = new ModuleVal;
                m.name = name;
                m.env = prelude;
                foreach (k; prelude.vars.keys)
                    m.publicNames[k] = true;
                mod = m;
            }
            else
                return;
        }
        else
        {
            auto file = findModule(d);
            mod = loadModule(readText(file), file, name);
        }

        if (d.aliasName.length)
        {
            into.env.vars[d.aliasName] = Value.make(Kind.module_, mod);
            into.env.readonly[d.aliasName] = true;
            if (d.isPublic)
                into.publicNames[d.aliasName] = true;
        }
        else if (d.selective.length)
        {
            foreach (s; d.selective)
            {
                auto owner = publicOwner(mod, s);
                if (owner is null)
                    throw new HcadError(Code.import_, format("module '%s' has no public symbol '%s'", name, s), d.span,
                        suggest(s, publicNamesOf(mod)));
                into.env.vars[s] = global(owner.env, s, d.span);
                into.env.readonly[s] = true;
                if (d.isPublic)
                    into.publicNames[s] = true;
            }
        }
        else
        {
            into.imported ~= mod;
            if (d.isPublic)
                into.reexported ~= mod;
        }
    }

    /// The file of a project or library module: a.b is a/b.hcad, or the
    /// folder a/b with its package.hcad; searched in the project directory,
    /// then in libraryDirs. A module never comes from outside the folder it
    /// was found in.
    private string findModule(ImportDecl d)
    {
        auto rel = d.path.join("/");
        string[] tried;
        foreach (base; [root] ~ libraryDirs)
        {
            if (base.length == 0)
                continue;
            auto dir = buildNormalizedPath(base);
            foreach (candidate; [rel ~ ".hcad", rel ~ "/package.hcad"])
            {
                auto file = buildNormalizedPath(dir, candidate);
                if (!file.startsWith(dir))
                    throw new HcadError(Code.sandbox, "imports cannot leave the project or library folders", d.span);
                if (exists(file))
                    return file;
                tried ~= base == root ? relativePath(file, root) : file;
            }
        }
        throw new HcadError(Code.import_, format("module '%s' not found (looked for %s)", d.path.join("."),
            tried.join(", ")), d.span);
    }

    /// The module whose public name `name` is, following `public import`s.
    static ModuleVal publicOwner(ModuleVal m, string name, int depth = 0)
    {
        if (name in m.publicNames)
            return m;
        if (depth < 32)
            foreach (r; m.reexported)
                if (auto o = publicOwner(r, name, depth + 1))
                    return o;
        return null;
    }

    /// Every public name of a module, re-exported ones included (for suggestions).
    static string[] publicNamesOf(ModuleVal m, int depth = 0)
    {
        auto names = m.publicNames.keys;
        if (depth < 32)
            foreach (r; m.reexported)
                names ~= publicNamesOf(r, depth + 1);
        return names;
    }

    // ------------------------------------------------------------ name lookup

    /// Resolves a name: locals, module globals (evaluated lazily), imported
    /// modules, then the prelude.
    Value lookup(string name, Env env, Span span)
    {
        for (auto e = env; e !is null; e = e.parent)
        {
            if (auto v = name in e.vars)
                return *v;
            if (name in e.pending)
                return global(e, name, span);
            if (e.mod !is null && e.parent is prelude)
                foreach (m; e.mod.imported)
                    if (auto owner = publicOwner(m, name))
                        return global(owner.env, name, span);
        }
        throw new HcadError(Code.undefined, format("undefined identifier '%s'", name), span, suggest(name, env.allNames));
    }

    /// The nearest binding of `name`; with `callable`, bindings that are
    /// not functions are skipped (UFCS: a `bool chamfer` parameter does not
    /// hide the chamfer function).
    bool tryLookup(string name, Env env, out Value v, bool callable = false)
    {
        for (auto e = env; e !is null; e = e.parent)
        {
            if (auto p = name in e.vars)
            {
                v = *p;
                if (!callable || v.isCallable)
                    return true;
            }
            if (name in e.pending)
            {
                v = global(e, name, Span.init);
                if (!callable || v.isCallable)
                    return true;
            }
            if (e.mod !is null && e.parent is prelude)
                foreach (m; e.mod.imported)
                    if (name in m.publicNames)
                    {
                        v = global(m.env, name, Span.init);
                        if (!callable || v.isCallable)
                            return true;
                    }
        }
        return false;
    }

    /// Evaluates a module-level variable on first use (order independent,
    /// like D module scope), applying @param overrides.
    Value global(Env env, string name, Span span)
    {
        if (auto v = name in env.vars)
            return *v;
        auto d = env.pending.get(name, null);
        if (d is null)
            return lookup(name, env, span);
        if (name in env.evaluating)
            throw new HcadError(Code.redefined, format("'%s' depends on itself", name), d.nameSpan);
        env.evaluating[name] = true;
        scope (exit)
            env.evaluating.remove(name);

        auto v = d.init ? eval(d.init, env) : defaultOf(d.type, env.mod, d.nameSpan);
        if (d.type)
            v = coerce(v, d.type, env.mod, d.init ? d.init.span : d.nameSpan, "'" ~ name ~ "'");

        if (auto pa = findAttr(d.attrs, "param"))
            v = applyParam(d, *pa, v, env);
        env.vars[name] = v;
        env.pending.remove(name);
        return v;
    }

    private Value applyParam(VarDecl d, Attribute a, Value def, Env env)
    {
        ParamInfo p;
        p.name = d.name;
        p.defaultValue = def;
        p.span = d.nameSpan;
        foreach (arg; a.args)
        {
            auto v = eval(arg.value, env);
            switch (arg.name)
            {
            case null:
                if (v.kind != Kind.str)
                    throw new HcadError(Code.type, "the first @param argument is the description string", arg.span);
                p.doc = v.s;
                break;
            case "doc":
                if (v.kind != Kind.str)
                    throw new HcadError(Code.type, "doc is the description of the parameter: a string", arg.span);
                p.doc = v.s;
                break;
            case "min": p.min = v; break;
            case "max": p.max = v; break;
            case "step": p.step = v; break;
            case "choices":
                if (v.kind != Kind.array)
                    throw new HcadError(Code.type, "choices must be an array", arg.span);
                p.choices = v.arr;
                break;
            default:
                throw new HcadError(Code.unknownArg, format("unknown @param argument '%s'", arg.name), arg.span,
                    suggest(arg.name, ["doc", "min", "max", "step", "choices"]));
            }
        }

        // every candidate value is checked like the default: type, unit, limits
        Value check(Value v, Span span)
        {
            // a bare number for a length/angle parameter uses the model's unit
            if (v.isNum && v.n.dim == Dim.none && def.isNum && def.n.dim != Dim.none)
                v = Value.number(v.n.value * (def.n.dim == Dim.length ? env.mod.unitFactor : PI / 180), def.n.dim);
            if (v.kind != def.kind || (v.isNum && v.n.dim != def.n.dim))
                throw new HcadError(Code.type, format("parameter '%s' expects %s, got %s", d.name, def.typeName, v.typeName), span);
            if (p.min.isNum && v.n.value < p.min.n.value || p.max.isNum && v.n.value > p.max.n.value)
                throw new HcadError(Code.type, format("parameter '%s' = %s is outside [%s, %s]", d.name, v,
                    p.min.kind == Kind.void_ ? "-∞" : p.min.toString, p.max.kind == Kind.void_ ? "∞" : p.max.toString), span);
            if (p.choices.length && !p.choices.canFind(v))
                throw new HcadError(Code.type, format("parameter '%s' = %s is not one of %s", d.name, v, Value.of(p.choices)), span);
            return v;
        }

        check(def, d.nameSpan);
        foreach (pa; d.attrs)
            if (pa.name == "preset")
                p.presets[(cast(Literal) pa.args[0].value).text] = check(eval(pa.args[1].value, env), pa.args[1].span);

        Value v = def;
        if (auto pv = preset in p.presets)
            v = *pv;
        if (auto o = d.name in overrides)
            v = check(eval(parseExpression(*o, "-D " ~ d.name), env), d.nameSpan);
        p.value = v;
        params ~= p;
        return v;
    }

    // ------------------------------------------------------------ statements

    private Flow exec(Stmt s, Env env)
    {
        tick(s.span);
        if (auto e = cast(ExprStmt) s)
        {
            eval(e.expr, env);
            return Flow.normal;
        }
        if (auto b = cast(Block) s)
            return execBlock(b, b.scoped ? new Env(env, env.mod) : env);
        if (auto v = cast(VarDecl) s)
        {
            if (v.attrs.length)
                throw new HcadError(Code.syntax, "attributes are only allowed on module-level declarations", v.attrs[0].span);
            if (v.name in env.vars)
                throw new HcadError(Code.redefined, format("'%s' is already declared in this scope", v.name), v.nameSpan);
            auto val = v.init ? eval(v.init, env) : defaultOf(v.type, env.mod, v.nameSpan);
            if (v.type)
                val = coerce(val, v.type, env.mod, v.init ? v.init.span : v.nameSpan, "'" ~ v.name ~ "'");
            env.vars[v.name] = val;
            if (v.storage != Storage.auto_)
                env.readonly[v.name] = true;
            return Flow.normal;
        }
        if (auto f = cast(FuncDecl) s)
        {
            env.vars[f.name] = Value.make(Kind.func, closureOf(f, env, env.mod));
            env.readonly[f.name] = true;
            return Flow.normal;
        }
        if (auto i = cast(If) s)
        {
            if (eval(i.cond, env).truthy)
                return exec(i.then, new Env(env, env.mod));
            if (i.otherwise)
                return exec(i.otherwise, new Env(env, env.mod));
            return Flow.normal;
        }
        if (auto f = cast(Foreach) s)
            return execForeach(f, env);
        if (auto f = cast(For) s)
        {
            auto scope_ = new Env(env, env.mod);
            if (f.init)
                exec(f.init, scope_);
            while (f.cond is null || eval(f.cond, scope_).truthy)
            {
                auto fl = exec(f.body, new Env(scope_, env.mod));
                if (fl == Flow.break_)
                    break;
                if (fl == Flow.return_)
                    return fl;
                if (f.step)
                    eval(f.step, scope_);
            }
            return Flow.normal;
        }
        if (auto w = cast(While) s)
        {
            while (eval(w.cond, env).truthy)
            {
                auto fl = exec(w.body, new Env(env, env.mod));
                if (fl == Flow.break_)
                    break;
                if (fl == Flow.return_)
                    return fl;
            }
            return Flow.normal;
        }
        if (auto r = cast(Return) s)
        {
            returnValue = r.value ? eval(r.value, env) : Value.void_;
            return Flow.return_;
        }
        if (cast(Break) s)
            return Flow.break_;
        if (cast(Continue) s)
            return Flow.continue_;
        if (auto a = cast(AssertStmt) s)
        {
            if (!eval(a.cond, env).truthy)
            {
                auto msg = a.message ? eval(a.message, env).toString : "assertion failed";
                throw new HcadError(Code.assertion, msg, a.span);
            }
            return Flow.normal;
        }
        if (auto sw = cast(Switch) s)
        {
            auto subject = eval(sw.subject, env);
            ptrdiff_t chosen = -1;
            foreach (i, values; sw.caseValues)
            {
                if (values.length == 0)
                {
                    if (chosen < 0)
                        chosen = i; // default, unless a later case matches
                    continue;
                }
                foreach (cv; values)
                    if (eval(cv, env) == subject)
                    {
                        chosen = i;
                        goto found;
                    }
            }
        found:
            if (chosen < 0)
                throw new HcadError(Code.type, format("no case matches %s and there is no default", subject), sw.span);
            auto scope_ = new Env(env, env.mod);
            foreach (st; sw.caseBodies[chosen])
            {
                auto fl = exec(st, scope_);
                if (fl == Flow.break_)
                    break;
                if (fl != Flow.normal)
                    return fl;
            }
            return Flow.normal;
        }
        if (auto i = cast(ImportDecl) s)
        {
            doImport(i, env.mod);
            return Flow.normal;
        }
        throw new HcadError(Code.syntax, "this declaration is only allowed at module level", s.span);
    }

    Flow execBlock(Block b, Env env)
    {
        foreach (st; b.stmts)
        {
            auto fl = exec(st, env);
            if (fl != Flow.normal)
                return fl;
        }
        return Flow.normal;
    }

    private Flow execForeach(Foreach f, Env env)
    {
        Flow iteration(Value key, Value val)
        {
            auto scope_ = new Env(env, env.mod);
            if (f.key.name.length)
                scope_.vars[f.key.name] = f.key.type ? coerce(key, f.key.type, env.mod, f.key.span, "'" ~ f.key.name ~ "'") : key;
            scope_.vars[f.value.name] = f.value.type ? coerce(val, f.value.type, env.mod, f.value.span, "'" ~ f.value.name ~ "'") : val;
            return exec(f.body, scope_);
        }

        if (f.hi)
        {
            auto lo = eval(f.aggregate, env), hi = eval(f.hi, env);
            if (!lo.isNum || !hi.isNum)
                throw new HcadError(Code.type, "a range foreach needs numeric bounds", f.aggregate.span);
            if (lo.n.dim != hi.n.dim)
                throw new HcadError(Code.units, format("range bounds have different units: %s and %s", lo.n.dim.name, hi.n.dim.name), f.span);
            immutable isInt = lo.n.isInt && hi.n.isInt;
            auto count = cast(long) floor(hi.n.value - lo.n.value);
            if (hi.n.value - lo.n.value > count)
                count++;
            foreach (k; 0 .. count < 0 ? 0 : count)
            {
                immutable i = f.reverse ? count - 1 - k : k;
                auto fl = iteration(Value.integer(i), Value.number(lo.n.value + i, lo.n.dim, isInt));
                if (fl == Flow.break_) break;
                if (fl == Flow.return_) return fl;
            }
            return Flow.normal;
        }

        auto agg = eval(f.aggregate, env);
        if (agg.kind == Kind.array)
        {
            auto items = agg.arr;
            foreach (k; 0 .. items.length)
            {
                immutable i = f.reverse ? items.length - 1 - k : k;
                auto fl = iteration(Value.integer(i), items[i]);
                if (fl == Flow.break_) break;
                if (fl == Flow.return_) return fl;
            }
            return Flow.normal;
        }
        if (agg.kind == Kind.aa)
        {
            foreach (k, v; agg.aa.vals)
            {
                auto fl = iteration(agg.aa.keys[k], v);
                if (fl == Flow.break_) break;
                if (fl == Flow.return_) return fl;
            }
            return Flow.normal;
        }
        if (agg.kind == Kind.str)
        {
            foreach (i, dchar c; agg.s)
            {
                auto fl = iteration(Value.integer(i), Value.of(c.to!string));
                if (fl == Flow.break_) break;
                if (fl == Flow.return_) return fl;
            }
            return Flow.normal;
        }
        throw new HcadError(Code.type, format("cannot iterate over %s", agg.typeName), f.aggregate.span);
    }

    // ------------------------------------------------------------ expressions

    /// How deep eval is in the expression tree: a chain like 1 + 1 + …
    /// parsed in a loop still evaluates recursively.
    private uint exprDepth;
    enum maxExprDepth = 20_000;

    Value eval(Expr e, Env env)
    {
        if (++exprDepth > maxExprDepth)
            throw new HcadError(Code.limit, format("expression nested more than %d levels deep", maxExprDepth), e.span);
        scope (exit)
            exprDepth--;
        return evalExpr(e, env);
    }

    private Value evalExpr(Expr e, Env env)
    {
        if (auto l = cast(Literal) e)
            return literal(l);
        if (auto id = cast(Ident) e)
            return autoCall(lookup(id.name, env, id.span), id.span);
        if (auto is_ = cast(InterpString) e)
        {
            string r = is_.parts[0];
            foreach (i, x; is_.exprs)
                r ~= eval(x, env).toString ~ is_.parts[i + 1];
            return Value.of(r);
        }
        if (auto b = cast(Binary) e)
            return binary(b, env);
        if (auto c = cast(Call) e)
            return call(c, env);
        if (auto m = cast(Member) e)
            return member(m, env, false);
        if (auto u = cast(Unary) e)
        {
            if (u.op == Tok.amp)
            {
                // &f: the function itself, not a call
                auto id = cast(Ident) u.operand;
                if (id is null)
                    throw new HcadError(Code.type, "'&' can only take a function name", u.span);
                return lookup(id.name, env, id.span);
            }
            auto v = eval(u.operand, env);
            switch (u.op)
            {
            case Tok.bang: return Value.of(!v.truthy);
            case Tok.plus: return v;
            default:
                if (v.isNum)
                    return Value.number(-v.n.value, v.n.dim, v.n.isInt);
                if (v.kind == Kind.vec)
                    return Value.vector(-v.v.v, v.v.n, v.v.dim);
                throw new HcadError(Code.type, "cannot negate " ~ v.typeName, u.span);
            }
        }
        if (auto a = cast(Assign) e)
        {
            Value v = eval(a.value, env);
            if (a.op != Tok.assign)
            {
                auto op = a.op == Tok.plusAssign ? Tok.plus : a.op == Tok.minusAssign ? Tok.minus
                    : a.op == Tok.mulAssign ? Tok.mul : a.op == Tok.divAssign ? Tok.div
                    : a.op == Tok.modAssign ? Tok.mod : a.op == Tok.catAssign ? Tok.tilde
                    : a.op == Tok.andAssign ? Tok.amp : Tok.pipe;
                v = applyBinary(op, eval(a.target, env), v, a.span);
            }
            assignTo(a.target, v, env);
            return v;
        }
        if (auto t = cast(Ternary) e)
            return eval(t.cond, env).truthy ? eval(t.then, env) : eval(t.otherwise, env);
        if (auto a = cast(ArrayLit) e)
        {
            Value[] items;
            items.reserve(a.elems.length);
            foreach (x; a.elems)
                items ~= eval(x, env);
            return Value.of(items);
        }
        if (auto a = cast(AssocLit) e)
        {
            auto aa = new AAVal;
            foreach (i, k; a.keys)
            {
                auto kv = eval(k, env);
                auto key = aaKey(kv, k.span);
                aa.keys[key] = kv;
                aa.vals[key] = eval(a.values[i], env);
            }
            return Value.make(Kind.aa, aa);
        }
        if (auto ix = cast(Index) e)
        {
            auto obj = eval(ix.object, env);
            auto idxEnv = dollarEnv(obj, env);
            if (ix.indices.length != 1)
                throw new HcadError(Code.index, "only one index is supported", ix.span);
            return index(obj, eval(ix.indices[0], idxEnv), ix.span);
        }
        if (auto sl = cast(Slice) e)
        {
            auto obj = eval(sl.object, env);
            if (sl.lo is null)
                return obj;
            auto idxEnv = dollarEnv(obj, env);
            auto lo = toIndex(eval(sl.lo, idxEnv), sl.lo.span), hi = toIndex(eval(sl.hi, idxEnv), sl.hi.span);
            if (obj.kind == Kind.array)
            {
                checkBounds(lo, hi, obj.arr.length, sl.span);
                return Value.of(obj.arr[lo .. hi]);
            }
            if (obj.kind == Kind.str)
            {
                checkBounds(lo, hi, obj.s.length, sl.span);
                return Value.of(obj.s[lo .. hi]);
            }
            throw new HcadError(Code.type, "cannot slice " ~ obj.typeName, sl.span);
        }
        if (auto d = cast(Dollar) e)
            return lookup("$", env, d.span);
        if (auto l = cast(Lambda) e)
        {
            auto c = new Closure;
            c.name = "lambda";
            c.params = l.params;
            c.body = l.blockBody;
            c.exprBody = l.exprBody;
            c.env = env;
            c.mod = env.mod;
            c.span = l.span;
            return Value.make(Kind.func, c);
        }
        if (auto i = cast(IncDec) e)
        {
            auto old = eval(i.target, env);
            if (!old.isNum)
                throw new HcadError(Code.type, "++/-- need a number", i.span);
            auto nv = Value.number(old.n.value + (i.increment ? 1 : -1), old.n.dim, old.n.isInt);
            assignTo(i.target, nv, env);
            return i.prefix ? nv : old;
        }
        throw new HcadError(Code.syntax, "unsupported expression", e.span);
    }

    private Value literal(Literal l)
    {
        final switch (l.type)
        {
        case Literal.Type.int_:
            try
                return Value.integer(l.text.to!long);
            catch (ConvException)
                throw new HcadError(Code.lex, "integer too large: the largest is 9223372036854775807; "
                    ~ "write it as a number with a dot (" ~ l.text ~ ".0) for a floating value", l.span);
        case Literal.Type.float_: return Value.number(l.text.to!double);
        case Literal.Type.string_: return Value.of(l.text);
        case Literal.Type.true_: return Value.of(true);
        case Literal.Type.false_: return Value.of(false);
        case Literal.Type.null_: return Value.null_;
        }
    }

    private Env dollarEnv(Value obj, Env env)
    {
        if (obj.kind != Kind.array && obj.kind != Kind.str)
            return env;
        auto e = new Env(env, env.mod);
        e.vars["$"] = Value.integer(obj.kind == Kind.array ? obj.arr.length : obj.s.length);
        return e;
    }

    private size_t toIndex(Value v, Span span)
    {
        if (!v.isNum || v.n.dim != Dim.none || v.n.value != floor(v.n.value) || v.n.value < 0)
            throw new HcadError(Code.index, format("index must be a non-negative integer, not %s", v), span);
        return cast(size_t) v.n.value;
    }

    private void checkBounds(size_t lo, size_t hi, size_t len, Span span)
    {
        if (lo > hi || hi > len)
            throw new HcadError(Code.index, format("slice [%d .. %d] out of bounds for length %d", lo, hi, len), span);
    }

    Value index(Value obj, Value idx, Span span)
    {
        switch (obj.kind)
        {
        case Kind.array:
            {
                auto i = toIndex(idx, span);
                if (i >= obj.arr.length)
                    throw new HcadError(Code.index, format("index %d out of bounds for length %d", i, obj.arr.length), span);
                return obj.arr[i];
            }
        case Kind.str:
            {
                auto i = toIndex(idx, span);
                if (i >= obj.s.length)
                    throw new HcadError(Code.index, format("index %d out of bounds for length %d", i, obj.s.length), span);
                return Value.of(obj.s[i .. i + 1]);
            }
        case Kind.vec:
            {
                auto i = toIndex(idx, span);
                if (i >= obj.v.n)
                    throw new HcadError(Code.index, format("index %d out of bounds for a %d-component vector", i, obj.v.n), span);
                return Value.number([obj.v.v.x, obj.v.v.y, obj.v.v.z][i], obj.v.dim);
            }
        case Kind.aa:
            {
                auto k = aaKey(idx, span);
                if (auto p = k in obj.aa.vals)
                    return *p;
                throw new HcadError(Code.index, format("key %s not found", idx), span);
            }
        default:
            throw new HcadError(Code.type, "cannot index " ~ obj.typeName, span);
        }
    }

    /// Assignment with value semantics: `a.b[2] = x` rebuilds a.b and a.
    private void assignTo(Expr target, Value v, Env env)
    {
        if (auto id = cast(Ident) target)
        {
            auto e = env.find(id.name);
            if (e is null)
                throw new HcadError(Code.undefined, format("undefined identifier '%s'", id.name), id.span, suggest(id.name, env.allNames));
            if (e.readonly.get(id.name, false))
                throw new HcadError(Code.immutable_, format("cannot modify '%s': it is enum/immutable/const or module-level", id.name), id.span);
            env.find(id.name).vars[id.name] = v;
            return;
        }
        if (auto ix = cast(Index) target)
        {
            auto obj = eval(ix.object, env);
            auto i = eval(ix.indices[0], dollarEnv(obj, env));
            if (obj.kind == Kind.array)
            {
                auto k = toIndex(i, ix.span);
                if (k >= obj.arr.length)
                    throw new HcadError(Code.index, format("index %d out of bounds for length %d", k, obj.arr.length), ix.span);
                auto copy = obj.arr.dup;
                copy[k] = v;
                assignTo(ix.object, Value.of(copy), env);
                return;
            }
            if (obj.kind == Kind.aa)
            {
                auto aa = new AAVal;
                aa.vals = obj.aa.vals.dup;
                aa.keys = obj.aa.keys.dup;
                auto key = aaKey(i, ix.span);
                aa.vals[key] = v;
                aa.keys[key] = i;
                assignTo(ix.object, Value.make(Kind.aa, aa), env);
                return;
            }
            throw new HcadError(Code.type, "cannot assign to an element of " ~ obj.typeName, ix.span);
        }
        if (auto m = cast(Member) target)
        {
            auto obj = eval(m.object, env);
            if (obj.kind == Kind.struct_)
            {
                auto fi = obj.st.def.fieldIndex(m.name);
                if (fi < 0)
                    throw new HcadError(Code.undefined, format("%s has no field '%s'", obj.st.def.name, m.name), m.nameSpan,
                        suggest(m.name, obj.st.def.fields.map!(f => f.name).array));
                auto fields = obj.st.fields.dup;
                fields[fi] = coerce(v, obj.st.def.fields[fi].type, env.mod, m.span, "field '" ~ m.name ~ "'", obj.st.def.mod);
                assignTo(m.object, Value.make(Kind.struct_, StructVal(obj.st.def, fields)), env);
                return;
            }
            if (obj.kind == Kind.vec && (m.name == "x" || m.name == "y" || m.name == "z"))
            {
                if (!v.isNum || v.n.dim != obj.v.dim)
                    throw new HcadError(Code.units, format("cannot assign %s to a component of a %s vector", v.typeName, obj.v.dim.name), m.span);
                auto nv = obj.v;
                if (m.name == "x") nv.v.x = v.n.value;
                else if (m.name == "y") nv.v.y = v.n.value;
                else nv.v.z = v.n.value;
                assignTo(m.object, Value.vector(nv.v, nv.n, nv.dim), env);
                return;
            }
            throw new HcadError(Code.type, format("cannot assign to '%s' of %s", m.name, obj.typeName), m.span);
        }
        throw new HcadError(Code.type, "this expression cannot be assigned to", target.span);
    }

    // ------------------------------------------------------------ operators

    private Value binary(Binary b, Env env)
    {
        if (b.op == Tok.andAnd)
            return Value.of(eval(b.left, env).truthy && eval(b.right, env).truthy);
        if (b.op == Tok.orOr)
            return Value.of(eval(b.left, env).truthy || eval(b.right, env).truthy);
        return applyBinary(b.op, eval(b.left, env), eval(b.right, env), b.span);
    }

    Value applyBinary(Tok op, Value l, Value r, Span span)
    {
        import hackerscad.lang.builtins : solidBoolean;

        if (op == Tok.eq)
            return Value.of(equal(l, r));
        if (op == Tok.ne)
            return Value.of(!equal(l, r));
        if (op == Tok.kwIs)
            return Value.of(l.kind == r.kind && (l.kind == Kind.null_ || l == r));
        if (op == Tok.kwIn)
        {
            if (r.kind == Kind.aa)
                return Value.of((aaKey(l, span) in r.aa.vals) !is null);
            throw new HcadError(Code.type, "'in' needs an associative array on the right", span);
        }

        if (l.kind == Kind.selector && r.kind == Kind.selector && (op == Tok.plus || op == Tok.minus || op == Tok.amp))
        {
            // faces.left + faces.top: union; - difference; & intersection
            if (l.sel.faces != r.sel.faces)
                throw new HcadError(Code.type, "cannot combine a face selector with an edge selector", span);
            auto a = l.sel, b = r.sel;
            auto c = new SelectorVal;
            c.faces = a.faces;
            immutable o = op;
            c.tests ~= (size_t i, ref SelectCtx ctx) {
                import std.algorithm : canFind;
                immutable inA = ctx.resolve(a).canFind(cast(int) i), inB = ctx.resolve(b).canFind(cast(int) i);
                return o == Tok.plus ? inA || inB : o == Tok.minus ? inA && !inB : inA && inB;
            };
            return Value.make(Kind.selector, c);
        }
        if (l.kind == Kind.solid || r.kind == Kind.solid)
        {
            if (l.kind != Kind.solid || r.kind != Kind.solid)
                throw new HcadError(Code.type, format("cannot combine %s and %s with '%s'", l.typeName, r.typeName, opText(op)), span);
            if (l.solid.path || r.solid.path)
                throw new HcadError(Code.type, format("cannot combine a Path with '%s': sweep a profile along it first", opText(op)), span);
            if (l.solid.flat != r.solid.flat && l.solid.brep !is null && r.solid.brep !is null)
                throw new HcadError(Code.type, format("cannot combine a %s and a %s: extrude the profile first", l.typeName, r.typeName), span);
            Value v;
            switch (op)
            {
            case Tok.plus: v = solidBoolean(this, l.solid, r.solid, BoolOp.fuse, span); break;
            case Tok.minus: v = solidBoolean(this, l.solid, r.solid, BoolOp.cut, span); break;
            case Tok.amp: v = solidBoolean(this, l.solid, r.solid, BoolOp.common, span); break;
            default:
                throw new HcadError(Code.type, format("'%s' is not defined for solids (use + - &)", opText(op)), span);
            }
            if (recordTrace)
                traceCall(v, span, opText(op), Span.init);
            return v;
        }

        if (op == Tok.tilde)
        {
            if (l.kind == Kind.array && r.kind == Kind.array)
                return Value.of(l.arr ~ r.arr);
            if (l.kind == Kind.array)
                return Value.of(l.arr ~ r);
            if (r.kind == Kind.array)
                return Value.of(l ~ r.arr);
            // a string joined with anything else takes its textual form
            if (l.kind == Kind.str || r.kind == Kind.str)
                return Value.of(l.toString ~ r.toString);
            throw new HcadError(Code.type, format("cannot concatenate %s and %s", l.typeName, r.typeName), span);
        }

        if (l.isNum && r.isNum)
            return numeric(op, l.n, r.n, span);

        if (l.kind == Kind.vec || r.kind == Kind.vec)
            return vectorOp(op, l, r, span);

        if (l.kind == Kind.str && r.kind == Kind.str)
        {
            switch (op)
            {
            case Tok.lt: return Value.of(l.s < r.s);
            case Tok.le: return Value.of(l.s <= r.s);
            case Tok.gt: return Value.of(l.s > r.s);
            case Tok.ge: return Value.of(l.s >= r.s);
            default: break;
            }
        }
        if (l.kind == Kind.bool_ && r.kind == Kind.bool_)
        {
            if (op == Tok.amp) return Value.of(l.b && r.b);
            if (op == Tok.pipe) return Value.of(l.b || r.b);
            if (op == Tok.caret) return Value.of(l.b != r.b);
        }
        throw new HcadError(Code.type, format("operator '%s' is not defined for %s and %s", opText(op), l.typeName, r.typeName), span);
    }

    private bool equal(Value l, Value r)
    {
        if (l.kind == Kind.vec && r.kind == Kind.vec)
        {
            // geometric vectors compare with a tolerance (normals are computed)
            if (l.v.n != r.v.n || l.v.dim != r.v.dim)
                return false;
            return (l.v.v - r.v.v).length <= 1e-9 * (1 + l.v.v.length);
        }
        return l == r;
    }

    private Value numeric(Tok op, NumVal a, NumVal b, Span span)
    {
        void sameDim()
        {
            if (a.dim != b.dim)
                throw new HcadError(Code.units, format("incompatible units: %s %s %s", a.dim.name, opText(op), b.dim.name), span,
                    a.dim == Dim.none || b.dim == Dim.none ? "add a unit to the bare number, e.g. 5.mm" : null);
        }

        immutable bothInt = a.isInt && b.isInt;
        switch (op)
        {
        case Tok.plus: sameDim(); return Value.number(a.value + b.value, a.dim, bothInt);
        case Tok.minus: sameDim(); return Value.number(a.value - b.value, a.dim, bothInt);
        case Tok.mul: return Value.number(a.value * b.value, a.dim + b.dim, bothInt);
        case Tok.div:
            if (b.value == 0 && bothInt)
                throw new HcadError(Code.type, "integer division by zero", span);
            // the most negative integer divided by -1 does not fit: the
            // processor traps on it, so it is negated instead (and wraps)
            if (bothInt)
                return Value.integer(b.value == -1 ? -cast(long) a.value : cast(long) a.value / cast(long) b.value);
            return Value.number(a.value / b.value, a.dim - b.dim);
        case Tok.mod:
            sameDim();
            if (bothInt)
            {
                if (b.value == 0)
                    throw new HcadError(Code.type, "integer modulo by zero", span);
                return Value.integer(b.value == -1 ? 0 : cast(long) a.value % cast(long) b.value);
            }
            return Value.number(fmod(a.value, b.value), a.dim);
        case Tok.pow:
            {
                if (b.dim != Dim.none)
                    throw new HcadError(Code.units, "the exponent must be a plain number", span);
                if (a.dim != Dim.none && b.value != floor(b.value))
                    throw new HcadError(Code.units, format("a %s can only be raised to an integer power", a.dim.name), span);
                import std.math : pow;
                return Value.number(pow(a.value, b.value), a.dim.times(cast(int) b.value), bothInt && b.value >= 0);
            }
        case Tok.lt: sameDim(); return Value.of(a.value < b.value);
        case Tok.le: sameDim(); return Value.of(a.value <= b.value);
        case Tok.gt: sameDim(); return Value.of(a.value > b.value);
        case Tok.ge: sameDim(); return Value.of(a.value >= b.value);
        case Tok.amp, Tok.pipe, Tok.caret:
            if (!bothInt)
                throw new HcadError(Code.type, "bitwise operators need integers", span);
            immutable x = cast(long) a.value, y = cast(long) b.value;
            return Value.integer(op == Tok.amp ? x & y : op == Tok.pipe ? x | y : x ^ y);
        default:
            throw new HcadError(Code.type, format("operator '%s' is not defined for numbers", opText(op)), span);
        }
    }

    private Value vectorOp(Tok op, Value l, Value r, Span span)
    {
        if (l.kind == Kind.vec && r.kind == Kind.vec)
        {
            if (op != Tok.plus && op != Tok.minus)
                throw new HcadError(Code.type, format("operator '%s' is not defined between vectors (use dot/cross)", opText(op)), span);
            if (l.v.dim != r.v.dim)
                throw new HcadError(Code.units, format("incompatible units: %s and %s vectors", l.v.dim.name, r.v.dim.name), span);
            auto n = l.v.n > r.v.n ? l.v.n : r.v.n;
            return Value.vector(op == Tok.plus ? l.v.v + r.v.v : l.v.v - r.v.v, cast(ubyte) n, l.v.dim);
        }
        if (l.kind == Kind.vec && r.isNum && (op == Tok.mul || op == Tok.div))
            return Value.vector(op == Tok.mul ? l.v.v * r.n.value : l.v.v / r.n.value, l.v.n,
                op == Tok.mul ? l.v.dim + r.n.dim : l.v.dim - r.n.dim);
        if (r.kind == Kind.vec && l.isNum && op == Tok.mul)
            return Value.vector(r.v.v * l.n.value, r.v.n, r.v.dim + l.n.dim);
        throw new HcadError(Code.type, format("operator '%s' is not defined for %s and %s", opText(op), l.typeName, r.typeName), span);
    }

    static string opText(Tok op)
    {
        switch (op)
        {
        case Tok.plus: return "+";
        case Tok.minus: return "-";
        case Tok.mul: return "*";
        case Tok.div: return "/";
        case Tok.mod: return "%";
        case Tok.pow: return "^^";
        case Tok.tilde: return "~";
        case Tok.amp: return "&";
        case Tok.pipe: return "|";
        case Tok.caret: return "^";
        case Tok.lt: return "<";
        case Tok.le: return "<=";
        case Tok.gt: return ">";
        case Tok.ge: return ">=";
        default: return op.to!string;
        }
    }

    // ------------------------------------------------------------ members and calls

    /// `obj.name`. Fields and built-in properties first, then UFCS. Outside a
    /// call, a method or UFCS function is called without arguments (D style).
    private Value member(Member m, Env env, bool forCall)
    {
        auto obj = eval(m.object, env);
        import hackerscad.lang.builtins : builtinMember;

        if (obj.kind == Kind.module_)
        {
            auto owner = publicOwner(obj.mod, m.name);
            if (owner is null)
                throw new HcadError(Code.undefined, format("module '%s' has no public symbol '%s'", obj.mod.name, m.name),
                    m.nameSpan, suggest(m.name, publicNamesOf(obj.mod)));
            return global(owner.env, m.name, m.nameSpan);
        }
        if (obj.kind == Kind.struct_)
        {
            auto fi = obj.st.def.fieldIndex(m.name);
            if (fi >= 0)
                return obj.st.fields[fi];
            if (auto meth = m.name in obj.st.def.methods)
                return finish(boundTo(obj, Value.make(Kind.func, *meth)), forCall, m.span);
        }

        Value v;
        bool isMethod;
        if (builtinMember(this, obj, m.name, m.nameSpan, v, isMethod))
            return isMethod ? finish(v, forCall, m.span) : v;

        // UFCS: a free function taking obj as first argument
        Value f;
        if (tryLookup(m.name, env, f, true))
            return finish(boundTo(obj, f), forCall, m.span);

        string[] candidates;
        if (obj.kind == Kind.object_)
            candidates = obj.obj.memberNames;
        if (obj.kind == Kind.struct_)
            candidates = obj.st.def.fields.map!(x => x.name).array ~ obj.st.def.methods.keys;
        throw new HcadError(Code.undefined, format("%s has no member '%s' and there is no function '%s'", obj.typeName, m.name, m.name),
            m.nameSpan, suggest(m.name, candidates ~ env.allNames));
    }

    /// In D a declared function without required parameters is called when
    /// named without parentheses (`body.bbox`, `nextTo(body, …)`).
    private Value autoCall(Value v, Span span)
    {
        if (v.kind != Kind.func || v.fn.decl is null || v.fn.isMethod)
            return v;
        foreach (p; v.fn.params)
            if (p.defaultValue is null)
                return v;
        CallArgs none;
        none.span = span;
        return callValue(v, none, span);
    }

    private Value boundTo(Value receiver, Value f)
    {
        auto b = new Bound;
        b.receiver = receiver;
        b.func = f;
        return Value.make(Kind.bound, b);
    }

    private Value finish(Value bound, bool forCall, Span span)
    {
        if (forCall)
            return bound;
        CallArgs none;
        none.span = span;
        return callValue(bound, none, span);
    }

    private Value call(Call c, Env env)
    {
        Value callee;
        if (auto m = cast(Member) c.callee)
            callee = member(m, env, true);
        else if (auto id = cast(Ident) c.callee)
            callee = lookup(id.name, env, id.span);
        else
            callee = eval(c.callee, env);

        CallArgs args;
        args.span = c.span;
        args.caller = env.mod;
        foreach (t; c.templateArgs)
        {
            // map!colonna passes the function, as a D alias parameter would
            auto id = cast(Ident) t;
            args.templateArgs ~= id ? lookup(id.name, env, id.span) : eval(t, env);
        }
        foreach (a; c.args)
        {
            auto v = eval(a.value, env);
            if (a.name is null)
            {
                args.positional ~= v;
                args.positionalSpans ~= a.value.span;
            }
            else
            {
                if (a.name in args.named)
                    throw new HcadError(Code.unknownArg, format("argument '%s' given twice", a.name), a.span);
                args.named[a.name] = v;
                args.namedOrder ~= a.name;
                args.namedSpans[a.name] = a.span;
            }
        }
        return callValue(callee, args, c.callee.span);
    }

    Value callValue(Value f, ref CallArgs args, Span span)
    {
        tick(span);
        if (args.span == Span.init)
            args.span = span;
        if (args.caller is null)
            args.caller = currentModule;
        switch (f.kind)
        {
        case Kind.bound:
            {
                CallArgs inner = args;
                inner.positional = f.bound.receiver ~ args.positional;
                inner.positionalSpans = span ~ args.positionalSpans;
                return callValue(f.bound.func, inner, span);
            }
        case Kind.builtin:
            {
                Value r;
                try
                    r = f.bi.impl(args);
                catch (KernelException e)
                    throw new HcadError(Code.kernel, e.msg, args.span);
                catch (ValueKindError e)
                    throw new HcadError(Code.type, f.bi.name ~ ": " ~ e.msg, args.span);
                catch (ConvException e)
                    throw new HcadError(Code.type, f.bi.name ~ ": " ~ e.msg, args.span);
                if (recordTrace)
                    traceCall(r, span, f.bi.name, Span.init);
                return r;
            }
        case Kind.func:
            return callClosure(f.fn, args, span);
        case Kind.type:
            if (f.type.def !is null)
                return construct(f.type.def, args);
            break;
        case Kind.selector:
            {
                import hackerscad.lang.builtins : refineSelector;
                return refineSelector(this, f.sel, args);
            }
        default:
            break;
        }
        throw new HcadError(Code.type, format("%s is not callable", f.typeName), span);
    }

    ModuleVal currentModule;
    /// One object per running call of a declared function (null at module
    /// level): a feature is moved with its solid only within its own call.
    Object callFrame;

    private Value callClosure(Closure c, ref CallArgs args, Span span)
    {
        if (c.isPart)
        {
            if (args.positional.length || args.named.length)
                throw new HcadError(Code.arity, format("@part '%s' takes no arguments", c.name), span);
            if (auto v = c.decl in partCache)
                return *v;
            if (c.decl in partsInProgress)
                throw new HcadError(Code.redefined, format("@part '%s' depends on itself", c.name), span);
            partsInProgress[c.decl] = true;
            scope (exit)
                partsInProgress.remove(c.decl);
            c.isPart = false;
            scope (exit)
                c.isPart = true;
            auto v = callClosure(c, args, span);
            partCache[c.decl] = v;
            return v;
        }

        if (++depth > limits.depth)
            throw new HcadError(Code.limit, format("recursion deeper than %d calls", limits.depth), span);
        auto savedModule = currentModule;
        auto savedFrame = callFrame;
        currentModule = c.mod;
        callFrame = new Object;
        scope (exit)
        {
            depth--;
            currentModule = savedModule;
            callFrame = savedFrame;
        }

        auto env = new Env(c.env, c.mod);
        if (c.isMethod)
        {
            // struct method: fields are visible by name, the struct as `this`
            auto self = args.positional[0];
            env.vars["this"] = self;
            env.readonly["this"] = true;
            foreach (i, f; self.st.def.fields)
            {
                env.vars[f.name] = self.st.fields[i];
                env.readonly[f.name] = true;
            }
            args.positional = args.positional[1 .. $];
            if (args.positionalSpans.length)
                args.positionalSpans = args.positionalSpans[1 .. $];
            env = new Env(env, c.mod);
        }
        if (args.templateArgs.length)
            throw new HcadError(Code.arity, format("'%s' takes no template arguments (!)", c.name), span);
        if (args.positional.length > c.params.length)
            throw new HcadError(Code.arity, format("'%s' takes %d argument%s, %d given", c.name, c.params.length,
                c.params.length == 1 ? "" : "s", args.positional.length), args.span);

        foreach (i, p; c.params)
        {
            Value v;
            Span vs = args.span;
            if (i < args.positional.length)
            {
                v = args.positional[i];
                if (i < args.positionalSpans.length)
                    vs = args.positionalSpans[i];
                if (p.name in args.named)
                    throw new HcadError(Code.unknownArg, format("argument '%s' given both by position and by name", p.name), args.namedSpans[p.name]);
            }
            else if (auto nv = p.name in args.named)
            {
                v = *nv;
                vs = args.namedSpans[p.name];
            }
            else if (p.defaultValue)
            {
                v = eval(p.defaultValue, env);
                vs = p.defaultValue.span;
            }
            else
                throw new HcadError(Code.missingArg, format("missing argument '%s' for '%s'", p.name, c.name), args.span);
            if (p.type)
                v = coerce(v, p.type, args.caller, vs, "argument '" ~ p.name ~ "'", c.mod);
            env.vars[p.name] = v;
        }
        foreach (name; args.namedOrder)
            if (!c.params.canFind!(p => p.name == name))
                throw new HcadError(Code.unknownArg, format("unknown argument '%s' for %s(%s)", name, c.name,
                    c.params.map!(p => p.name).join(", ")), args.namedSpans[name], suggest(name, c.params.map!(p => p.name).array));

        Value result;
        if (c.exprBody)
            result = eval(c.exprBody, env);
        else if (c.body)
        {
            auto body = cast(Block) c.body;
            result = execBlock(body, env) == Flow.return_ ? returnValue : Value.void_;
        }
        if (c.returnType && c.returnType.name != "auto")
        {
            if (c.returnType.name == "void")
            {
                if (result.kind != Kind.void_)
                    throw new HcadError(Code.type, format("void function '%s' cannot return a value", c.name), span);
            }
            else
            {
                if (result.kind == Kind.void_)
                    throw new HcadError(Code.type, format("'%s' must return %s", c.name, c.returnType), c.span);
                result = coerce(result, c.returnType, c.mod, c.span, "return value of '" ~ c.name ~ "'");
            }
        }
        // what a declared function returns (a lambda's result is its caller's)
        if (recordTrace && c.decl !is null)
            traceCall(result, span, c.name, c.decl.nameSpan);
        return result;
    }

    private uint traceSeq;
    private enum maxTraceCalls = 64;    /// runs of one call site kept in the trace
    private enum maxTrace = 3000;       /// entries in the whole trace

    private struct TraceSite
    {
        uint calls;
        size_t start, length;   /// the entries of the latest run kept
    }

    /// Records the solids, profiles and paths in `v` (also inside arrays and
    /// structs, up to 16) as made by the call at `site`, when the call or the
    /// function `decl` is in the evaluated file. A site that runs many times
    /// (a loop) keeps its first runs and the last one.
    private void traceCall(Value v, Span site, string fn, Span decl)
    {
        if (v.kind != Kind.solid && v.kind != Kind.array && v.kind != Kind.struct_)
            return;
        if (site.file != traceFile && decl.file != traceFile)
            return;
        SolidVal[16] found;
        size_t n, budget = 256;   // values looked at: a long array of numbers is not walked
        void collect(ref Value x)
        {
            if (n == found.length || budget == 0)
                return;
            budget--;
            if (x.kind == Kind.solid)
            {
                if (x.solid !is null && x.solid.brep !is null)
                    found[n++] = x.solid;
            }
            else if (x.kind == Kind.array)
                foreach (ref e; x.arr)
                    collect(e);
            else if (x.kind == Kind.struct_)
                foreach (ref e; x.st.fields)
                    collect(e);
        }
        collect(v);
        if (n == 0)
            return;
        auto s = site in traceSites;
        if (s is null)
        {
            traceSites[site] = TraceSite.init;
            s = site in traceSites;
        }
        s.calls++;
        TraceEntry entry(SolidVal sv) => TraceEntry(site, decl, fn, sv.path ? "Path" : sv.flat ? "Profile" : "Solid", sv, 0,
            cast(uint) features.length, ++traceSeq);
        if (s.calls > maxTraceCalls)
        {
            // the latest run takes the place of the previous last one
            if (s.length == n)
                foreach (i; 0 .. n)
                    trace[s.start + i] = entry(found[i]);
            return;
        }
        if (trace.length + n > maxTrace)
            return;
        s.start = trace.length;
        s.length = n;
        foreach (i; 0 .. n)
            trace ~= entry(found[i]);
    }

    /// Tells every trace entry how many times its site ran (at the end of a
    /// run, or after a failed one).
    void finishTrace()
    {
        foreach (ref e; trace)
            if (auto s = e.site in traceSites)
                e.calls = s.calls;
    }

    private Value callPart(FuncDecl f, ModuleVal mod)
    {
        if (f.params.length)
            throw new HcadError(Code.arity, "a @part function takes no arguments (use @param for its parameters)", f.nameSpan);
        CallArgs none;
        return callValue(global(mod.env, f.name, f.nameSpan), none, f.nameSpan);
    }

    /// `Screw(d: 3.mm, tap: 2.5.mm)` or positional in field order.
    private Value construct(StructDef def, ref CallArgs args)
    {
        if (args.positional.length > def.fields.length)
            throw new HcadError(Code.arity, format("%s has %d fields, %d values given", def.name, def.fields.length, args.positional.length), args.span);
        auto fields = new Value[def.fields.length];
        foreach (i, f; def.fields)
        {
            Value v;
            if (i < args.positional.length)
                v = args.positional[i];
            else if (auto nv = f.name in args.named)
                v = *nv;
            else if (f.init)
                v = eval(f.init, def.mod.env);
            else
                v = defaultOf(f.type, def.mod, args.span);
            fields[i] = coerce(v, f.type, args.caller, args.span, "field '" ~ f.name ~ "'", def.mod);
        }
        foreach (name; args.namedOrder)
            if (def.fieldIndex(name) < 0)
                throw new HcadError(Code.unknownArg, format("%s has no field '%s'", def.name, name), args.namedSpans[name],
                    suggest(name, def.fields.map!(x => x.name).array));
        return Value.make(Kind.struct_, StructVal(def, fields));
    }

    // ------------------------------------------------------------ types

    private TypeVal structType(StructDecl s, ModuleVal mod)
    {
        auto def = new StructDef;
        def.name = s.name;
        def.decl = s;
        def.mod = mod;
        foreach (f; s.fields)
        {
            if (f.type is null && f.init is null)
                throw new HcadError(Code.syntax, "struct fields need a type or an initializer", f.nameSpan);
            if (def.fieldIndex(f.name) >= 0)
                throw new HcadError(Code.redefined, format("field '%s' is declared twice", f.name), f.nameSpan);
            def.fields ~= StructDef.FieldInfo(f.name, f.type, f.init);
        }
        auto t = new TypeVal;
        t.name = s.name;
        t.def = def;
        foreach (m; s.methods)
        {
            // methods see the fields through an implicit `this` environment
            auto c = closureOf(m, mod.env, mod);
            c.isMethod = true;
            def.methods[m.name] = c;
        }
        return t;
    }

    private Closure closureOf(FuncDecl f, Env env, ModuleVal mod)
    {
        auto c = new Closure;
        c.name = f.name;
        c.params = f.params;
        c.returnType = f.returnType;
        c.body = f.body;
        c.exprBody = f.exprBody;
        c.env = env;
        c.mod = mod;
        c.span = f.nameSpan;
        c.decl = f;
        c.isPart = hasAttr(f.attrs, "part");
        return c;
    }

    /// Checks a value against a declared type, converting where D would:
    /// int → double, and bare numbers → Length/Angle in the caller's unit.
    Value coerce(Value v, TypeRef t, ModuleVal mod, Span span, string what, ModuleVal typeScope = null)
    {
        // bare numbers take the unit of `mod` (the caller); type names are
        // resolved where the declaration lives (`typeScope`)
        auto types = typeScope ? typeScope : mod;
        if (t is null || t.name == "auto")
            return v;
        noreturn fail()
        {
            throw new HcadError(Code.type, format("%s must be %s, not %s", what, t, v.typeName), span);
        }

        if (t.isArray)
        {
            if (v.kind != Kind.array)
                fail();
            auto items = v.arr.dup;
            foreach (i, ref x; items)
                x = coerce(x, t.elem, mod, span, format("%s[%d]", what, i), typeScope);
            return Value.of(items);
        }
        if (t.isAA)
        {
            if (v.kind != Kind.aa)
                fail();
            return v;
        }
        switch (t.name)
        {
        case "int", "long", "size_t":
            if (!v.isNum || v.n.dim != Dim.none || v.n.value != floor(v.n.value))
                fail();
            return Value.integer(cast(long) v.n.value);
        case "double", "float", "real":
            if (!v.isNum || v.n.dim != Dim.none)
                fail();
            return Value.number(v.n.value);
        case "bool":
            if (v.kind != Kind.bool_) fail();
            return v;
        case "string":
            if (v.kind != Kind.str) fail();
            return v;
        case "Length", "Angle", "Area", "Volume":
            {
                immutable want = t.name == "Length" ? Dim.length : t.name == "Angle" ? Dim.angle
                    : t.name == "Area" ? Dim.area : Dim.volume;
                if (!v.isNum)
                    fail();
                if (v.n.dim == want)
                    return v;
                if (v.n.dim == Dim.none && (want == Dim.length || want == Dim.angle))
                    return Value.number(v.n.value * (want == Dim.length ? (mod ? mod.unitFactor : 1) : PI / 180), want);
                throw new HcadError(Code.units, format("%s must be a %s, not a %s", what, t.name, v.n.dim.name), span);
            }
        case "Vec2", "Vec3":
            {
                if (v.kind == Kind.array)
                {
                    import hackerscad.lang.builtins : arrayToVec;
                    v = arrayToVec(this, v.arr, mod, span);
                }
                if (v.kind != Kind.vec || (t.name == "Vec2") != (v.v.n == 2))
                    fail();
                return v;
            }
        case "Path":
            if (v.kind != Kind.solid || !v.solid.path) fail();
            return v;
        case "Solid":
            if (v.kind == Kind.solid && v.solid.path) fail();
            if (v.kind == Kind.solid && v.solid.flat)
                throw new HcadError(Code.type, format("%s must be a Solid, but this is a 2D profile: extrude it first", what), span);
            if (v.kind != Kind.solid) fail();
            return v;
        case "Profile":
            if (v.kind != Kind.solid || !v.solid.flat || v.solid.path) fail();
            return v;
        case "Edge":
            if (v.kind != Kind.edge) fail();
            return v;
        case "Face":
            if (v.kind != Kind.face) fail();
            return v;
        case "EdgeSelector", "Edges":
            if (v.kind != Kind.selector || v.sel.faces) fail();
            return v;
        case "FaceSelector", "Faces":
            if (v.kind != Kind.selector || !v.sel.faces) fail();
            return v;
        default:
            {
                if (v.kind == Kind.object_ && v.obj.typeName == t.name)
                    return v;
                if (objectTypes.canFind(t.name))
                    fail();
                Value tv;
                if (tryLookup(t.name, types ? types.env : prelude, tv) && tv.kind == Kind.type && tv.type.def !is null)
                {
                    if (v.kind != Kind.struct_ || v.st.def !is tv.type.def)
                        fail();
                    return v;
                }
                throw new HcadError(Code.undefined, format("unknown type '%s'", t.name), t.span,
                    suggest(t.name, ["int", "double", "bool", "string", "Length", "Angle", "Area", "Volume", "Vec2", "Vec3",
                        "Solid", "Profile", "Edge", "Face"]));
            }
        }
    }

    /// Names of the built-in object types, usable in declarations.
    static immutable string[] objectTypes = ["Sketch", "SketchPoint", "SketchLine", "SketchArc", "SketchCircle",
        "Drawing", "DrawingView"];

    /// Default value of a declared type, like T.init in D.
    Value defaultOf(TypeRef t, ModuleVal mod, Span span)
    {
        if (t is null)
            throw new HcadError(Code.syntax, "a declaration without a type needs an initializer", span);
        if (t.isArray)
            return Value.of(cast(Value[])[]);
        if (t.isAA)
            return Value.make(Kind.aa, new AAVal);
        switch (t.name)
        {
        case "int", "long", "size_t": return Value.integer(0);
        case "double", "float", "real": return Value.number(double.nan);
        case "bool": return Value.of(false);
        case "string": return Value.of("");
        case "Length": return Value.number(0, Dim.length);
        case "Angle": return Value.number(0, Dim.angle);
        case "Area": return Value.number(0, Dim.area);
        case "Volume": return Value.number(0, Dim.volume);
        case "Vec2": return Value.vector(Vec3(0, 0, 0), 2, Dim.length);
        case "Vec3": return Value.vector(Vec3(0, 0, 0), 3, Dim.length);
        case "Solid": return Value.of(new SolidVal(null, span));
        default:
            {
                Value tv;
                if (tryLookup(t.name, mod ? mod.env : prelude, tv) && tv.kind == Kind.type && tv.type.def !is null)
                {
                    CallArgs none;
                    none.span = span;
                    none.caller = mod;
                    return construct(tv.type.def, none);
                }
                throw new HcadError(Code.undefined, format("unknown type '%s'", t.name), t.span);
            }
        }
    }

    // ------------------------------------------------------------ helpers

    void tick(Span span)
    {
        import core.atomic : atomicLoad;
        if (cancel !is null && atomicLoad(*cancel))
            throw new HcadError(Code.limit, "evaluation cancelled", span);
        if (++steps > limits.steps)
            throw new HcadError(Code.limit, format("evaluation stopped after %d steps (infinite loop?)", limits.steps), span);
    }

    /// Registers a face-creating operation; returns its id (never 0).
    /// The faces `expr` (a selector such as "faces.top") picks on `s`; used
    /// to turn clicks in the GUI into selector code.
    int[] trySelector(string expr, SolidVal s)
    {
        bool faces;
        return trySelector(expr, s, faces);
    }

    /// The same, telling whether the indices are of faces or of edges.
    int[] trySelector(string expr, SolidVal s, out bool faces)
    {
        import hackerscad.lang.parser : parseExpression;
        import hackerscad.lang.builtins : resolveSelector;

        auto v = eval(parseExpression(expr, "<selector>"), new Env(prelude, null));
        if (v.kind != Kind.selector)
            throw new HcadError(Code.type, expr ~ " is not a selector", Span.init);
        faces = v.sel.faces;
        return resolveSelector(this, v.sel, s, Span.init, true);
    }

    uint addFeature(string kind, Span span)
    {
        features ~= FeatureInfo(kind, span);
        features[$ - 1].frame = callFrame;
        return cast(uint) features.length;
    }

    void print(string text, Span span)
    {
        log ~= LogLine(text, span);
    }

    static string suggest(string name, const(string)[] candidates)
    {
        // common long names for the short parameter names of the API
        static immutable string[string] synonyms = ["radius": "r", "diameter": "d", "height": "h",
            "thick": "thickness", "distance": "d", "size": "x", "position": "v", "offset": "v", "colour": "color",
            "middle": "center", "centre": "center"];
        if (auto syn = name in synonyms)
            if (candidates.canFind(*syn))
                return format("did you mean '%s'?", *syn);
        auto c = closest(name, candidates);
        return c is null ? null : format("did you mean '%s'?", c);
    }
}

private:

string baseName(string path)
{
    import std.path : stripExtension, baseName;
    return stripExtension(baseName(path));
}

bool hasAttr(Attribute[] attrs, string name) => findAttr(attrs, name) !is null;

Attribute* findAttr(Attribute[] attrs, string name)
{
    foreach (ref a; attrs)
        if (a.name == name)
            return &a;
    return null;
}

T[string] collect(T)(ModuleVal mod)
{
    T[string] r;
    foreach (d; collectOrdered!T(mod))
        r[d.name] = d;
    return r;
}

T[] collectOrdered(T)(ModuleVal mod)
{
    T[] r;
    void walk(Stmt s)
    {
        if (auto x = cast(T) s)
            r ~= x;
        else if (auto b = cast(Block) s)
            foreach (y; b.stmts)
                walk(y);
    }

    foreach (d; mod.program.decls)
        walk(d);
    return r;
}

/// Where `import name;` looks after the project directory: the folders in
/// $HCAD_PATH (separated like PATH), then the personal library folder:
/// ~/.local/share/hackerscad/lib (or $XDG_DATA_HOME/hackerscad/lib) on
/// Linux, ~/Library/Application Support/hackerscad/lib on macOS,
/// %APPDATA%\hackerscad\lib on Windows.
public string[] libraryPaths()
{
    import std.path : buildPath, pathSeparator;
    import std.process : environment;
    import std.array : split;

    string[] dirs;
    foreach (d; environment.get("HCAD_PATH", "").split(pathSeparator))
        if (d.length)
            dirs ~= d;
    version (Windows)
        dirs ~= buildPath(environment.get("APPDATA", ""), "hackerscad", "lib");
    else version (OSX)
        dirs ~= buildPath(environment.get("HOME", ""), "Library", "Application Support", "hackerscad", "lib");
    else
    {
        auto data = environment.get("XDG_DATA_HOME", "");
        dirs ~= data.length ? buildPath(data, "hackerscad", "lib")
            : buildPath(environment.get("HOME", ""), ".local", "share", "hackerscad", "lib");
    }
    return dirs;
}
