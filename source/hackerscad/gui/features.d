/// Feature tree: the modelling operations of the model in source order,
/// grouped by function. Selecting one rolls the view back to the solid right
/// after it; a function's "returns" row shows what it returns (Inspect).
module hackerscad.gui.features;

import std.algorithm : sort;
import std.format : format;
import std.path : absolutePath;

import gtk.box : Box;
import gtk.button : Button;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.types : Orientation, Align, SelectionMode;
import pango.types : EllipsizeMode;

import hackerscad.lang.interp : FeatureInfo, FunctionInfo, TraceEntry;

final class FeaturesPanel
{
    Box widget;
    /// A feature was chosen: its id (index + 1 in the outcome's features).
    void delegate(uint id) onSelect;
    /// Back to the final model.
    void delegate() onFinal;

    /// The "returns" row of a function was chosen: show what it returns.
    void delegate(FunctionInfo f) onReturns;

    private struct Entry
    {
        enum Type
        {
            header,    // a function
            returns,   // what it returns
            feature,
        }

        Type type;
        uint id;       // feature id
        int func;      // index in functions, -1 outside any
        string line, text;
        bool flat;
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
        auto title = new Label("Features");
        title.addCssClass("heading");
        title.setHalign(Align.Start);
        widget.append(title);
        auto hint = new Label("Select a feature to see the model as it was right after it, "
            ~ "or what a function returns.");
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
            else if (onSelect)
                onSelect(e.id);
        });
        widget.append(list);
    }

    /// Lists the features of `file`, one row per line of code (a loop that
    /// runs a feature many times gives one row with a count), grouped under
    /// the functions they are in. Each group starts with what the function
    /// returns, when the trace has it.
    void update(FeatureInfo[] features, TraceEntry[] trace, FunctionInfo[] functions, string file)
    {
        struct Row
        {
            uint line, col;
            string kind;
            uint id;     // the last run of this feature
            size_t count;
            bool flat;
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
                rows[key] = Row(f.span.line, f.span.col, f.kind, cast(uint)(i + 1), 1, f.result !is null && f.result.flat);
            else
            {
                r.id = cast(uint)(i + 1);
                r.count++;
            }
        }
        auto ordered = rows.values;
        ordered.sort!((a, b) => a.line != b.line ? a.line < b.line : a.col < b.col);

        // what each function returns (the kind of its latest result)
        string[size_t] returns;
        foreach (e; trace)
            foreach (i, fn; functions)
                if (e.decl.file == full && e.decl.line == fn.nameSpan.line && e.decl.col == fn.nameSpan.col)
                    returns[i] = e.kind;

        // the groups, in file order; features outside any function come first
        Entry[] entries;
        size_t next;
        while (next < ordered.length && (functions.length == 0 || ordered[next].line < functions[0].first))
            next++;
        void addFeatures(Row[] rs, int func)
        {
            foreach (r; rs)
                entries ~= Entry(Entry.Type.feature, r.id, func, format("%d", r.line),
                    r.count > 1 ? format("%s ×%d", r.kind, r.count) : r.kind, r.flat);
        }
        addFeatures(ordered[0 .. next], -1);
        foreach (i, fn; functions)
        {
            size_t end = next;
            while (end < ordered.length && ordered[end].line <= fn.last)
                end++;
            auto ret = i in returns;
            if (end > next || ret)
            {
                entries ~= Entry(Entry.Type.header, 0, cast(int) i, format("%d", fn.first), fn.name, false);
                if (ret)
                    entries ~= Entry(Entry.Type.returns, 0, cast(int) i, "↩", "returns " ~ (*ret == "Profile"
                        ? "a 2D profile" : *ret == "Path" ? "a path" : "a solid"), *ret == "Profile");
                addFeatures(ordered[next .. end], cast(int) i);
            }
            next = end;
        }
        addFeatures(ordered[next .. $], -1);

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
