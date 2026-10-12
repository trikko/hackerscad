/// Feature tree: the modelling operations of the model in source order,
/// grouped by function. Selecting one rolls the view back to the solid right
/// after it; a function's "returns" row shows what it returns (Inspect).
module hackerscad.gui.features;

import std.algorithm : any, sort;
import std.format : format;
import std.path : absolutePath;

import gtk.box : Box;
import gtk.button : Button;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.types : Orientation, Align, SelectionMode;
import pango.types : EllipsizeMode;

import hackerscad.lang.interp : FeatureInfo, FunctionInfo, TraceEntry, callsOf;

final class FeaturesPanel
{
    Box widget;
    /// A feature was chosen: its id (index + 1 in the outcome's features).
    void delegate(uint[] ids) onSelect;   /// a feature row: every run of it
    /// Back to the final model.
    void delegate() onFinal;

    /// The "returns" row of a function was chosen: show what it returns.
    void delegate(FunctionInfo f) onReturns;
    /// A call that makes geometry without new faces (a function, a move) was
    /// chosen: what every run of it made.
    void delegate(TraceEntry[] made) onValue;

    private struct Entry
    {
        enum Type
        {
            header,    // a function
            returns,   // what it returns
            feature,
            value,     // a call that made geometry but no feature: clip(), .move(…)
        }

        Type type;
        uint id;       // feature id (the last run)
        int func;      // index in functions, -1 outside any
        string line, text;
        bool flat;
        uint[] ids;    // every run of a feature
        TraceEntry[] values;   // what a value row made
    }

    private ListBox list;
    private Button finalButton;
    private Entry[] entries;
    private FunctionInfo[] functions;
    private string signature;

    this()
    {
        widget = new Box(Orientation.Vertical, 6);
        widget.setMarginTop(8);
        widget.setMarginBottom(8);
        widget.setMarginStart(10);
        widget.setMarginEnd(10);
        auto title = new Label("Steps");
        title.addCssClass("heading");
        title.setHalign(Align.Start);
        widget.append(title);
        auto hint = new Label("How the model is built, step by step, in the order the code runs: "
            ~ "select a step to see what it made, or what a function returns.");
        hint.addCssClass("dim-label");
        hint.setWrap(true);
        hint.setXalign(0);
        widget.append(hint);
        finalButton = new Button;
        finalButton.setLabel("Show the final model");
        finalButton.setSensitive(false);
        finalButton.connectClicked(() {
            list.unselectAll();
            finalButton.setSensitive(false);
            if (onFinal)
                onFinal();
        });
        widget.append(finalButton);
        list = new ListBox;
        list.setSelectionMode(SelectionMode.Single);
        list.addCssClass("boxed-list");
        list.connectRowActivated((ListBoxRow row) {
            immutable i = row.getIndex();
            if (i < 0 || i >= entries.length)
                return;
            auto e = entries[i];
            if (e.type == Entry.Type.header)
                return;
            finalButton.setSensitive(true);
            if (e.type == Entry.Type.returns)
            {
                if (onReturns && e.func >= 0 && e.func < functions.length)
                    onReturns(functions[e.func]);
            }
            else if (e.type == Entry.Type.value)
            {
                if (onValue)
                    onValue(e.values);
            }
            else if (onSelect)
                onSelect(e.ids);
        });
        widget.append(list);
    }

    /// The rows as the panel shows them, one string each (for agents).
    string[] rowsText()
    {
        string[] r;
        foreach (e; entries)
            final switch (e.type)
            {
            case Entry.Type.header:
                r ~= format("[%s] (line %s)", e.text, e.line);
                break;
            case Entry.Type.returns:
                r ~= format("    ↩ %s", e.text);
                break;
            case Entry.Type.feature:
            case Entry.Type.value:
                r ~= format("    %4s  %s%s%s", e.line, e.text, e.flat ? "  [2D]" : "", e.type == Entry.Type.value ? "  (call)" : "");
                break;
            }
        return r;
    }

    /// Lists the features of `file`, one row per line of code (a loop that
    /// runs a feature many times gives one row with a count), grouped under
    /// the functions they are in. Each group ends with what the function
    /// returns, when the trace has it.
    void update(FeatureInfo[] features, TraceEntry[] trace, FunctionInfo[] functions, string file, string[] source = null)
    {
        // the call as written, when the code at `line:col` starts with `name`:
        // tooth(upper(k)) and tooth(lower(k)) are two rows, not "tooth()" twice
        string written(uint line, uint col, string name, string fallback)
        {
            import std.algorithm : startsWith;

            import std.string : indexOf;

            if (line == 0 || line > source.length || col == 0)
                return fallback;
            auto s = source[line - 1];
            if (col - 1 >= s.length)
                return fallback;
            // a feature's span is its argument list: back to the name before it
            if (s[col - 1] == '(' && col - 1 >= name.length && s[col - 1 - name.length .. col - 1] == name)
                col -= cast(uint) name.length;
            // a call's may start at the receiver (clip.move(…))
            if (!s[col - 1 .. $].startsWith(name))
            {
                immutable at = s[col - 1 .. $].indexOf(name ~ "(");
                if (at < 0)
                    return fallback;
                col += cast(uint) at;
            }
            size_t i = col - 1 + name.length, depth;
            if (i >= s.length || s[i] != '(')
                return fallback;
            foreach (j; i .. s.length)
            {
                if (s[j] == '(')
                    depth++;
                else if (s[j] == ')' && --depth == 0)
                {
                    auto call = s[col - 1 .. j + 1];
                    return call.length > 40 ? call[0 .. 37] ~ "…)" : call;
                }
            }
            return fallback;
        }

        struct Row
        {
            uint line, col;
            string kind;
            uint id;     // the last run of this feature
            uint first;  // the first run: the order in which the code made them
            uint[] ids;  // every run
            size_t count;
            bool flat;
            TraceEntry[] values;   // a call that made geometry but no feature
            double order;          // where it comes among the features (first run)
            uint seq;              // among calls between the same two features
        }

        immutable full = absolutePath(file);
        Row[string] rows;
        foreach (i, f; features)
        {
            if (f.span.file != full)
                continue;
            auto key = format("%d:%d:%s", f.span.line, f.span.col, f.kind);
            auto r = key in rows;
            if (r is null)
                rows[key] = Row(f.span.line, f.span.col, written(f.span.line, f.span.col, f.kind, f.kind), cast(uint)(i + 1),
                    cast(uint)(i + 1), [cast(uint)(i + 1)], 1,
                    f.result !is null && f.result.flat, null, i + 1);
            else
            {
                r.id = cast(uint)(i + 1);
                r.ids ~= cast(uint)(i + 1);
                r.count++;
            }
        }
        // calls that made geometry without a feature of their own: a function's
        // result (auto b = clip();), a move of it (clip.move(…)). Not the
        // operators (their booleans are features), nor what a feature on the
        // same line already shows (circle(…).move(…) is the circle, moved)
        bool[string] featureKindsOn;          // "line:kind" of the features
        bool[void*][uint] featureResultsOn;   // line → results of its features
        foreach (f; features)
            if (f.span.file == full)
            {
                featureKindsOn[format("%d:%s", f.span.line, f.kind)] = true;
                if (f.result !is null)
                    featureResultsOn[f.span.line][cast(void*) f.result] = true;
            }
        foreach (e; trace)
        {
            if (e.site.file != full || e.fn == "+" || e.fn == "-" || e.fn == "&")
                continue;
            // the call that is a feature of the same line (circle, offset, extrude)
            if (!e.decl.file.length && format("%d:%s", e.site.line, e.fn) in featureKindsOn)
                continue;
            // a @part evaluated by the program: its call is its own name
            if (e.decl.file.length && e.site.line == e.decl.line && e.site.col == e.decl.col)
                continue;
            if (auto on = e.site.line in featureResultsOn)
                if (cast(void*) e.value in *on)
                    continue;
            immutable label = written(e.site.line, e.site.col, e.fn, e.decl.file.length ? e.fn ~ "()" : e.fn);
            auto key = format("%d:%d:value:%s", e.site.line, e.site.col, label);
            auto r = key in rows;
            if (r is null)
                rows[key] = Row(e.site.line, e.site.col, label, 0, 0, null, e.calls, e.kind == "Profile", [e], e.after + 0.5, e.seq);
            else
                r.values ~= e;
        }

        auto ordered = rows.values;
        // in the order the code made them, not the order it is written in: in
        // `c -= circle(…).move(…)` the circle comes before the difference
        ordered.sort!((a, b) => a.order != b.order ? a.order < b.order : a.seq < b.seq);

        // what each function returns (the kind of its latest result), and how many times it ran
        string[size_t] returns;
        TraceEntry[][size_t] returned;
        foreach (e; trace)
            foreach (i, fn; functions)
                if (e.decl.file == full && e.decl.line == fn.nameSpan.line && e.decl.col == fn.nameSpan.col)
                {
                    returns[i] = e.kind;
                    returned[i] ~= e;
                }

        // the function each feature is written in (-1: outside any)
        int funcOf(uint line)
        {
            foreach (i, fn; functions)
                if (line >= fn.first && line <= fn.last)
                    return cast(int) i;
            return -1;
        }

        // the groups, in file order; features outside any function come first
        // how many times each function ran (known when it returns geometry)
        uint[size_t] fnCalls;
        foreach (i, rs; returned)
            fnCalls[i] = callsOf(rs);

        Entry[] entries;
        void addFeatures(int func)
        {
            // counts are per call of the function: the circle in a tooth()
            // called 12 times is one circle, the header says "12 calls"
            immutable calls = func >= 0 ? fnCalls.get(cast(size_t) func, 1) : 1;
            foreach (r; ordered)
                if (funcOf(r.line) == func)
                {
                    immutable n = calls > 1 && r.count % calls == 0 ? r.count / calls : r.count;
                    immutable per = calls > 1 && r.count % calls == 0 && n > 1 ? " per call" : "";
                    entries ~= Entry(r.values.length ? Entry.Type.value : Entry.Type.feature, r.id, func, format("%d", r.line),
                        n > 1 ? format("%s ×%d%s", r.kind, n, per) : r.kind, r.flat, r.ids, r.values);
                }
        }
        addFeatures(-1);
        foreach (i, fn; functions)
        {
            immutable any = ordered.any!(r => funcOf(r.line) == cast(int) i);
            auto ret = i in returns;
            if (any || ret)
            {
                immutable calls = fnCalls.get(i, 1);
                entries ~= Entry(Entry.Type.header, 0, cast(int) i, format("%d", fn.first),
                    calls > 1 ? format("%s · %d calls", fn.name, calls) : fn.name, false);
                addFeatures(cast(int) i);
                // what it returns, after the steps that made it
                if (ret)
                    entries ~= Entry(Entry.Type.returns, 0, cast(int) i, "↩", "returns " ~ (*ret == "Profile"
                        ? "a 2D profile" : *ret == "Path" ? "a path" : "a solid"), *ret == "Profile");
            }
        }

        string sig;
        foreach (e; entries)
            sig ~= format("%s %s %s %s %s;", e.type, e.line, e.text, e.flat, e.func >= 0 ? functions[e.func].name : "");
        this.entries = entries;
        this.functions = functions;
        if (sig == signature)
            return;
        signature = sig;
        list.removeAll();
        finalButton.setSensitive(false);
        foreach (i, e; entries)
        {
            auto box = new Box(Orientation.Horizontal, 8);
            box.setMarginTop(e.type == Entry.Type.header ? 8 : 4);
            box.setMarginBottom(4);
            box.setMarginStart(e.type == Entry.Type.header ? 2 : 6);
            box.setMarginEnd(6);
            if (e.type == Entry.Type.header)
            {
                auto name = new Label(e.text);
                name.addCssClass("heading");
                name.setXalign(0);
                name.setEllipsize(EllipsizeMode.End);
                name.setHexpand(true);
                box.append(name);
                auto line = new Label("line " ~ e.line);
                line.addCssClass("dim-label");
                line.addCssClass("numeric");
                box.append(line);
            }
            else
            {
                auto line = new Label(e.line);
                line.addCssClass("dim-label");
                line.addCssClass("numeric");
                line.setWidthChars(4);
                line.setXalign(1);
                box.append(line);
                auto kind = new Label(e.text);
                kind.setXalign(0);
                kind.setEllipsize(EllipsizeMode.End);
                kind.setHexpand(true);
                if (e.type == Entry.Type.returns)
                    kind.addCssClass("dim-label");
                box.append(kind);
                if (e.flat)
                {
                    auto badge = new Label("2D");
                    badge.addCssClass("hcad-kind");
                    badge.addCssClass("hcad-kind-property");
                    badge.setTooltipText("A 2D profile");
                    box.append(badge);
                }
            }
            list.append(box);
            if (e.type == Entry.Type.header)
            {
                auto row = list.getRowAtIndex(cast(int) i);
                if (row !is null)
                {
                    row.setActivatable(false);
                    row.setSelectable(false);
                }
            }
        }
    }

    void clearSelection()
    {
        list.unselectAll();
        finalButton.setSensitive(false);
    }
}
