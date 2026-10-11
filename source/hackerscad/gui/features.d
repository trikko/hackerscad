/// Feature tree: the modelling operations of the model in source order.
/// Selecting one rolls the view back to the solid right after it.
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

import hackerscad.lang.interp : FeatureInfo;

final class FeaturesPanel
{
    Box widget;
    /// A feature was chosen: its id (index + 1 in the outcome's features).
    void delegate(uint id) onSelect;
    /// Back to the final model.
    void delegate() onFinal;

    private ListBox list;
    private Button finalButton;
    private uint[] rowIds;
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
        auto hint = new Label("Select a feature to see the model as it was right after it.");
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
            if (i < 0 || i >= rowIds.length)
                return;
            finalButton.setSensitive(true);
            if (onSelect)
                onSelect(rowIds[i]);
        });
        widget.append(list);
    }

    /// Lists the features of `file`, one row per line of code (a loop that
    /// runs a feature many times gives one row with a count).
    void update(FeatureInfo[] features, string file)
    {
        struct Row
        {
            uint line, col;
            string kind;
            uint id;     // the last run of this feature
            size_t count;
        }

        Row[string] rows;
        foreach (i, f; features)
        {
            if (f.span.file != absolutePath(file))
                continue;
            auto key = format("%d:%d:%s", f.span.line, f.span.col, f.kind);
            auto r = key in rows;
            if (r is null)
                rows[key] = Row(f.span.line, f.span.col, f.kind, cast(uint)(i + 1), 1);
            else
            {
                r.id = cast(uint)(i + 1);
                r.count++;
            }
        }
        auto ordered = rows.values;
        ordered.sort!((a, b) => a.line != b.line ? a.line < b.line : a.col < b.col);
        string sig;
        foreach (r; ordered)
            sig ~= format("%d %d %s %d;", r.line, r.col, r.kind, r.count);
        rowIds = null;
        foreach (r; ordered)
            rowIds ~= r.id;
        if (sig == signature)
            return;
        signature = sig;
        list.removeAll();
        finalButton.setSensitive(false);
        foreach (r; ordered)
        {
            auto box = new Box(Orientation.Horizontal, 8);
            box.setMarginTop(4);
            box.setMarginBottom(4);
            box.setMarginStart(6);
            box.setMarginEnd(6);
            auto line = new Label(format("%d", r.line));
            line.addCssClass("dim-label");
            line.addCssClass("numeric");
            line.setWidthChars(4);
            line.setXalign(1);
            box.append(line);
            auto kind = new Label(r.count > 1 ? format("%s ×%d", r.kind, r.count) : r.kind);
            kind.setXalign(0);
            kind.setEllipsize(EllipsizeMode.End);
            kind.setHexpand(true);
            box.append(kind);
            list.append(box);
        }
    }

    void clearSelection()
    {
        list.unselectAll();
        finalButton.setSensitive(false);
    }
}
