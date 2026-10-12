/// Parameter panel generated from the model's @param and @preset
/// declarations. Changes become overrides for the next evaluation.
module hackerscad.gui.params;

import std.format : format;
import std.math : PI, isNaN;
import std.algorithm : map, countUntil;
import std.array : array;
import std.conv : to;

import gtk.box : Box;
import gtk.label : Label;
import gtk.spin_button : SpinButton;
import gtk.switch_ : Switch;
import gtk.drop_down : DropDown;
import gtk.entry : Entry;
import gtk.button : Button;
import gtk.widget : Widget;
import gtk.types : Orientation, Align;

import hackerscad.lang.interp : ParamInfo;
import hackerscad.lang.value;

final class ParamsPanel
{
    Box widget;
    void delegate() onChange;
    void delegate(size_t part, bool visible) onVisibility;
    string[string] overrides;   /// name → .hcad expression
    string preset;

    private Box rows, partRows;
    Box partsWidget;   /// the parts with a check to show or hide each (shown by the view bar's eye)
    private string partSignature;
    private Label[] swatches;
    private string signature;   /// names and types: rebuild only when they change
    private string[] presets;
    private bool updating;

    this()
    {
        widget = new Box(Orientation.Vertical, 6);
        widget.setMarginTop(8);
        widget.setMarginBottom(8);
        widget.setMarginStart(10);
        widget.setMarginEnd(10);
        auto title = new Label("Parameters");
        title.addCssClass("heading");
        title.setHalign(Align.Start);
        widget.append(title);
        rows = new Box(Orientation.Vertical, 6);
        widget.append(rows);
        auto reset = new Button;
        reset.setLabel("Reset to defaults");
        reset.connectClicked(() {
            overrides = null;
            preset = null;
            signature = null;
            if (onChange)
                onChange();
        });
        widget.append(reset);

        partsWidget = new Box(Orientation.Vertical, 4);
        partsWidget.setMarginTop(6);
        partsWidget.setMarginBottom(6);
        partsWidget.setMarginStart(6);
        partsWidget.setMarginEnd(6);
        auto partsTitle = new Label("Parts shown");
        partsTitle.addCssClass("heading");
        partsTitle.setHalign(Align.Start);
        partsWidget.append(partsTitle);
        partRows = new Box(Orientation.Vertical, 2);
        partsWidget.append(partRows);
    }

    /// One row per part with a check to show or hide it.
    void updateParts(string[] names, uint[] colors, bool delegate(size_t) isHidden)
    {
        import std.array : join;

        auto sig = names.join("\n");
        if (sig == partSignature)
        {
            // same parts: only the colours may have changed
            foreach (i, sw; swatches)
                if (i < colors.length)
                    sw.setMarkup(format(`<span foreground="#%06X">●</span>`, colors[i]));
            return;
        }
        partSignature = sig;
        swatches = null;
        for (auto c = partRows.getFirstChild(); c !is null; c = partRows.getFirstChild())
            partRows.remove(c);
        foreach (i, name; names)
            partRows.append(partRow(i, name, colors[i], !isHidden(i)));
    }

    /// A row with the show/hide check of one part. Built in its own function
    /// so that each check's delegate captures its own index (in a loop body
    /// they would all share the last one).
    private Box partRow(size_t index, string name, uint color, bool visible)
    {
        import gtk.check_button : CheckButton;

        auto row = new Box(Orientation.Horizontal, 6);
        auto check = new CheckButton;
        check.setActive(visible);
        check.setTooltipText("Show or hide this part in the view (export is not affected)");
        check.connectToggled((CheckButton b) {
            if (onVisibility)
                onVisibility(index, b.getActive());
        });
        auto swatch = new Label("●");
        swatches ~= swatch;
        swatch.setMarkup(format(`<span foreground="#%06X">●</span>`, color));
        auto label = new Label(name);
        label.setHalign(Align.Start);
        row.append(check);
        row.append(swatch);
        row.append(label);
        return row;
    }

    /// Rebuilds the part list at the next updateParts (visibility changed from outside).
    void refreshParts()
    {
        partSignature = null;
    }

    /// Rebuilds the widgets at the next update (values changed from outside).
    void invalidate()
    {
        signature = null;
    }

    /// Shows the parameters of the latest evaluation.
    void update(ParamInfo[] params, string[] presetNames)
    {
        auto sig = presetNames.to!string ~ params.map!(p => p.name ~ ":" ~ p.value.typeName).array.to!string;
        if (sig == signature)
            return;
        signature = sig;
        presets = presetNames;
        updating = true;
        scope (exit)
            updating = false;

        for (auto c = rows.getFirstChild(); c !is null; c = rows.getFirstChild())
            rows.remove(c);

        if (presets.length)
        {
            auto names = ["(default)"] ~ presets;
            auto dd = DropDown.newFromStrings(names);
            auto idx = preset.length ? presets.countUntil(preset) + 1 : 0;
            dd.setSelected(cast(uint)(idx < 0 ? 0 : idx));
            dd.connectNotify("selected", () {
                if (updating)
                    return;
                auto i = dd.getSelected();
                preset = i == 0 ? null : presets[i - 1];
                overrides = null; // a preset replaces manual edits
                signature = null; // show the preset's values
                if (onChange)
                    onChange();
            });
            rows.append(row("preset", null, dd));
        }
        foreach (p; params)
            rows.append(row(p.name, p.doc, editor(p)));
    }

private:

    Widget row(string name, string doc, Widget editor)
    {
        auto box = new Box(Orientation.Vertical, 2);
        auto label = new Label(name);
        label.setHalign(Align.Start);
        label.addCssClass("caption-heading");
        box.append(label);
        if (doc.length)
        {
            auto d = new Label(doc);
            d.setHalign(Align.Start);
            d.addCssClass("dim-label");
            d.addCssClass("caption");
            box.append(d);
        }
        box.append(editor);
        return box;
    }

    void changed(string name, string expr)
    {
        if (updating)
            return;
        overrides[name] = expr;
        if (onChange)
            onChange();
    }

    Widget editor(ParamInfo p)
    {
        auto v = p.value;
        if (p.choices.length)
        {
            auto dd = DropDown.newFromStrings(p.choices.map!(c => c.toString).array);
            auto idx = p.choices.countUntil(v);
            dd.setSelected(cast(uint)(idx < 0 ? 0 : idx));
            auto choices = p.choices;
            dd.connectNotify("selected", () => changed(p.name, literal(choices[dd.getSelected()])));
            return dd;
        }
        switch (v.kind)
        {
        case Kind.bool_:
            {
                auto sw = new Switch;
                sw.setActive(v.b);
                sw.setHalign(Align.Start);
                sw.connectStateSet((bool state) { changed(p.name, state ? "true" : "false"); return false; });
                return sw;
            }
        case Kind.num:
            {
                // lengths in mm, angles in degrees
                immutable isAngle = v.n.dim == Dim.angle;
                immutable k = isAngle ? 180 / PI : 1;
                double lo = p.min.isNum ? p.min.n.value * k : -1e6, hi = p.max.isNum ? p.max.n.value * k : 1e6;
                immutable step = v.n.isInt ? 1 : p.step.isNum ? p.step.n.value * k : (hi - lo) <= 20 ? 0.1 : 1;
                auto spin = SpinButton.newWithRange(lo, hi, step);
                spin.setDigits(v.n.isInt ? 0 : 2);
                spin.setValue(v.n.value * k);
                immutable suffix = v.n.dim == Dim.length ? ".mm" : isAngle ? ".deg" : "";
                immutable isInt = v.n.isInt;
                spin.connectValueChanged(() {
                    auto x = spin.getValue();
                    changed(p.name, isInt ? format("%d", cast(long) x) : format("%.6g", x) ~ (suffix.length ? suffix : ""));
                });
                if (v.n.dim == Dim.none || v.n.dim == Dim.length || isAngle)
                    return withUnit(spin, v.n.dim == Dim.length ? "mm" : isAngle ? "°" : "");
                return spin;
            }
        case Kind.str:
            {
                auto e = new Entry;
                e.setText(v.s);
                e.connectActivate(() => changed(p.name, literal(Value.of(e.getText()))));
                return e;
            }
        default:
            return new Label(v.toString);
        }
    }

    Widget withUnit(Widget w, string unit)
    {
        if (unit.length == 0)
            return w;
        auto box = new Box(Orientation.Horizontal, 6);
        w.setHexpand(true);
        box.append(w);
        box.append(new Label(unit));
        return box;
    }

    static string literal(Value v)
    {
        import std.array : replace;
        if (v.kind == Kind.str)
            return `"` ~ v.s.replace(`\`, `\\`).replace(`"`, `\"`) ~ `"`;
        if (v.isNum && v.n.dim == Dim.length)
            return format("%.6g.mm", v.n.value);
        if (v.isNum && v.n.dim == Dim.angle)
            return format("%.6g.deg", v.n.value * 180 / PI);
        return v.toString;
    }
}
