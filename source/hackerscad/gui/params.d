/// Parameter panel generated from the model's @param and @preset
/// declarations. Changes become overrides for the next evaluation.
module hackerscad.gui.params;

import std.format : format;
import std.math : PI, abs, isNaN;
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
import gtk.separator : Separator;
import gtk.widget : Widget;
import gtk.types : Orientation, Align, StateFlags;

import hackerscad.lang.interp : ParamInfo;
import hackerscad.lang.value;

final class ParamsPanel
{
    Box widget;
    void delegate() onChange;
    void delegate(size_t part, bool visible) onVisibility;
    void delegate(int line) onGoto;   /// a click on a parameter's label: show its line in the code
    string[string] overrides;   /// name → .hcad expression
    string preset;

    private Box rows, partRows;
    Box partsWidget;   /// the parts with a check to show or hide each (shown by the view bar's eye)
    private string partSignature;
    private Label[] swatches;
    private string signature;   /// names and types: rebuild only when they change
    private string[] presets;
    private bool updating;
    /// each parameter's label and reset button, marked when it is changed by hand
    private Label[string] labels;
    private Button[string] resets;
    private string[string] texts;   /// the labels' text, without the mark

    this()
    {
        widget = new Box(Orientation.Vertical, 6);
        widget.setMarginTop(8);
        widget.setMarginBottom(8);
        widget.setMarginStart(10);
        // the overlay scroll bar runs down the right edge: the fields' + stays clear of it
        widget.setMarginEnd(20);
        auto title = new Label("Parameters");
        title.addCssClass("heading");
        title.setHalign(Align.Start);
        widget.append(title);
        // no spacing: each parameter has its own margins, a line between them
        rows = new Box(Orientation.Vertical, 0);
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
        scope (exit)
            markChanged();
        if (sig == signature)
            return;
        signature = sig;
        presets = presetNames;
        updating = true;
        scope (exit)
            updating = false;

        // the focus leaves the rows before they go (a ↺ just clicked has
        // it): GTK would hand it to a field near the top and scroll there
        if (rows.getStateFlags() & StateFlags.FocusWithin)
            if (auto root = rows.getRoot())
                root.setFocus(null);
        for (auto c = rows.getFirstChild(); c !is null; c = rows.getFirstChild())
            rows.remove(c);
        labels = null;
        resets = null;
        texts = null;

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
            add(row("Preset", null, 0, dd, null));
        }
        foreach (p; params)
            add(row(p.doc.length ? p.doc : p.name, p.name, p.span.line, editor(p), p.defaultValue.toString));
    }

    /// Marks the parameters changed by hand (a dot, the accent colour) and
    /// shows their reset buttons.
    void markChanged()
    {
        foreach (name, label; labels)
        {
            immutable changed = (name in overrides) !is null;
            label.setText(changed ? "● " ~ texts[name] : texts[name]);
            if (changed)
                label.addCssClass("accent");
            else
                label.removeCssClass("accent");
            resets[name].setOpacity(changed ? 1 : 0);
            resets[name].setCanTarget(changed);
        }
    }

    /// Back to the code's value (or the preset's) for one parameter.
    void reset(string name)
    {
        overrides.remove(name);
        signature = null;   // the control shows the value again
        if (onChange)
            onChange();
    }

private:

    /// A parameter's block, after a line when others come before it: which
    /// name and description go with which control reads at a glance.
    void add(Widget block)
    {
        if (rows.getFirstChild() !is null)
            rows.append(new Separator(Orientation.Horizontal));
        rows.append(block);
    }

    /// The label (the description, or the name when there is none) above
    /// the control; a switch stands at the end of the label's line instead.
    /// The variable's name is in the tooltip, and a click on the label shows
    /// its line in the code (`line` 0: neither).
    Widget row(string text, string name, int line, Widget editor, string defaultText)
    {
        import gtk.gesture_click : GestureClick;

        auto box = new Box(Orientation.Vertical, 3);
        box.setMarginTop(8);
        box.setMarginBottom(10);
        import pango.types : EllipsizeMode;

        auto label = new Label(text);
        label.setHalign(Align.Start);
        label.setXalign(0);
        // on one line: a long description ends in "…" rather than holding
        // the column wide, and reads whole in the tooltip
        label.setEllipsize(EllipsizeMode.End);
        label.addCssClass("caption-heading");
        if (line > 0)
        {
            label.setTooltipText(format("%s\n%s · line %d: click to see it in the code", text, name, line));
            label.setCursorFromName("pointer");
            auto click = new GestureClick;
            click.connectReleased(() {
                if (onGoto)
                    onGoto(line);
            });
            label.addController(click);
        }
        // the label's line: the label, the reset button when the value is
        // changed by hand, a switch at its end
        auto bar = new Box(Orientation.Horizontal, 6);
        label.setHexpand(true);
        label.setValign(Align.Center);
        bar.append(label);
        if (line > 0)
        {
            import gtk.image : Image;

            // small, and always in its place (hidden by its opacity): the
            // line keeps its height whether it shows or not
            auto icon = Image.newFromIconName("hcad-undo-symbolic");
            icon.setPixelSize(12);
            auto undo = new Button;
            undo.setChild(icon);
            undo.addCssClass("flat");
            undo.addCssClass("hcad-param-reset");
            undo.setValign(Align.Center);
            undo.setTooltipText("Back to " ~ (preset.length ? "the preset's value" : "the default: " ~ defaultText));
            undo.setOpacity(0);
            undo.setCanTarget(false);
            undo.connectClicked(() => reset(name));
            bar.append(undo);
            labels[name] = label;
            resets[name] = undo;
            texts[name] = text;
        }
        auto isSwitch = cast(Switch) editor !is null;
        if (isSwitch)
        {
            editor.setValign(Align.Center);
            bar.append(editor);
        }
        box.append(bar);
        if (!isSwitch)
            box.append(editor);
        return box;
    }

    /// A value set in the panel; `atBase`: it is the code's (or the preset's) again, typed back by hand, and
    /// the parameter is no longer changed, as its ↺ would make it
    void changed(string name, string expr, bool atBase)
    {
        if (updating)
            return;
        if (atBase)
            overrides.remove(name);
        else
            overrides[name] = expr;
        if (onChange)
            onChange();
    }

    Widget editor(ParamInfo p)
    {
        auto v = p.value;
        // what ↺ goes back to: the preset's value, or the code's
        immutable base = preset.length && (preset in p.presets) ? p.presets[preset] : p.defaultValue;
        if (p.choices.length)
        {
            auto dd = DropDown.newFromStrings(p.choices.map!(c => c.toString).array);
            auto idx = p.choices.countUntil(v);
            dd.setSelected(cast(uint)(idx < 0 ? 0 : idx));
            auto choices = p.choices;
            dd.connectNotify("selected", () {
                auto c = choices[dd.getSelected()];
                changed(p.name, literal(c), literal(c) == literal(base));
            });
            return dd;
        }
        switch (v.kind)
        {
        case Kind.bool_:
            {
                auto sw = new Switch;
                sw.setActive(v.b);
                sw.setHalign(Align.Start);
                sw.connectStateSet((bool state) {
                    changed(p.name, state ? "true" : "false", base.kind == Kind.bool_ && state == base.b);
                    return false;
                });
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
                wheelScrollsPanel(spin);
                spin.setDigits(v.n.isInt ? 0 : 2);
                spin.setValue(v.n.value * k);
                immutable suffix = v.n.dim == Dim.length ? ".mm" : isAngle ? ".deg" : "";
                immutable isInt = v.n.isInt;
                spin.connectValueChanged(() {
                    auto x = spin.getValue();
                    // the default as the field shows it (to its digits): typed back, it is the default
                    immutable atBase = base.isNum && abs(x - base.n.value * k) < (isInt ? 0.5 : 0.005);
                    changed(p.name, isInt ? format("%d", cast(long) x) : format("%.6g", x) ~ (suffix.length ? suffix : ""),
                        atBase);
                });
                if (v.n.dim == Dim.none || v.n.dim == Dim.length || isAngle)
                    return withUnit(spin, v.n.dim == Dim.length ? "mm" : isAngle ? "°" : "");
                return spin;
            }
        case Kind.str:
            {
                auto e = new Entry;
                e.setText(v.s);
                e.connectActivate(() => changed(p.name, literal(Value.of(e.getText())),
                    base.kind == Kind.str && e.getText() == base.s));
                return e;
            }
        default:
            return new Label(v.toString);
        }
    }

    /// The wheel over a field scrolls the panel: it changes the value only
    /// once the field has been clicked into (a turn meant for the list must
    /// not change a size by mistake).
    static void wheelScrollsPanel(Widget w)
    {
        import gtk.event_controller_scroll : EventControllerScroll;
        import gtk.scrolled_window : ScrolledWindow;
        import gtk.types : EventControllerScrollFlags, PropagationPhase, StateFlags;
        import gdk.types : ScrollUnit;
        auto scroll = new EventControllerScroll(EventControllerScrollFlags.Vertical);
        scroll.setPropagationPhase(PropagationPhase.Capture);
        scroll.connectScroll((double dx, double dy, EventControllerScroll sc) {
            if (w.getStateFlags() & StateFlags.FocusWithin)
                return false;
            if (auto panel = cast(ScrolledWindow) w.getAncestor(ScrolledWindow._getGType()))
            {
                auto adj = panel.getVadjustment();
                // a wheel notch scrolls about three lines; touchpads report pixels
                adj.setValue(adj.getValue() + (sc.getUnit() == ScrollUnit.Wheel ? dy * 50 : dy));
            }
            return true;
        });
        w.addController(scroll);
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
