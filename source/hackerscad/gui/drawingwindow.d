/// The window of a model's technical drawings (@drawing): the sheet drawn
/// as it will print, white on the window's grey, with the drawing to show
/// chosen at the top when there are several, and its export (PDF, SVG,
/// DXF). It follows the model: each evaluation gives it the new sheets.
module hackerscad.gui.drawingwindow;

import std.math : PI;

import adw.header_bar : HeaderBar;
import adw.toolbar_view : ToolbarView;
import adw.window : AdwWindow = Window;
import cairo.context : Context;
import cairo.types : FontSlant, FontWeight, LineCap, TextExtents;
import gtk.button : Button;
import gtk.drawing_area : DrawingArea;
import gtk.drop_down : DropDown;
import gtk.label : Label;
import gtk.string_list : StringList;
import gtk.window : Window;

import hackerscad.drawing.sheet;
import hackerscad.gui.evaluator : DrawingSheet;

final class DrawingWindow
{
    AdwWindow window;
    /// Called when it closes.
    void delegate() onClosed;
    /// Export the drawing shown as "pdf", "svg" or "dxf" (its name given).
    void delegate(string ext, string drawing) onExport;

    this(Window parent)
    {
        window = new AdwWindow;
        window.setTitle("Drawing");
        window.setDefaultSize(900, 660);
        window.setTransientFor(parent);
        window.connectCloseRequest(() {
            if (onClosed !is null)
                onClosed();
            return false;
        });
        auto bar = new HeaderBar;
        names = new StringList(null);
        chooser = DropDown.newFromStrings(null);
        chooser.setModel(names);
        chooser.setTooltipText("Which @drawing of the model");
        chooser.connectNotify("selected", () { area.queueDraw(); });
        bar.packStart(chooser);
        foreach (ext; ["dxf", "svg", "pdf"])
        {
            auto b = new Button;
            b.setLabel(ext == "pdf" ? "PDF…" : ext == "svg" ? "SVG…" : "DXF…");
            b.setTooltipText("Export this drawing as " ~ (ext == "pdf" ? "PDF" : ext == "svg" ? "SVG" : "DXF"));
            immutable e = ext;
            b.connectClicked(() {
                if (onExport !is null && shown >= 0)
                    onExport(e, sheets[shown].name);
            });
            bar.packEnd(b);
        }
        area = new DrawingArea;
        area.setDrawFunc((DrawingArea, Context cr, int w, int h) => draw(cr, w, h));
        area.setHexpand(true);
        area.setVexpand(true);
        auto view = new ToolbarView;
        view.addTopBar(bar);
        view.setContent(area);
        window.setContent(view);
    }

    void present() => window.present();

    void close() => window.close();

    /// The model's sheets after an evaluation; the one shown stays, by name.
    void setSheets(DrawingSheet[] all)
    {
        string keep = shown >= 0 && shown < sheets.length ? sheets[shown].name : null;
        sheets = all;
        // the list rebuilt only when the names change: rebuilding it resets the choice
        string[] now;
        foreach (s; all)
            now ~= s.name;
        if (now != listed)
        {
            names.splice(0, cast(uint) listed.length, now);
            listed = now;
        }
        shown = -1;
        foreach (i, s; all)
            if (s.name == keep)
                shown = cast(int) i;
        if (shown < 0 && all.length)
            shown = 0;
        if (shown >= 0)
            chooser.setSelected(shown);
        chooser.setVisible(all.length > 1);
        window.setTitle(shown >= 0 ? "Drawing: " ~ all[shown].name : "Drawing");
        area.queueDraw();
    }

    /// The drawing shown (for the window's tools), or null.
    string current() const => shown >= 0 && shown < sheets.length ? sheets[shown].name : null;

    /// Shows the drawing `name`; false if the model has none so named.
    bool show(string name)
    {
        foreach (i, s; sheets)
            if (s.name == name)
            {
                shown = cast(int) i;
                chooser.setSelected(shown);
                area.queueDraw();
                return true;
            }
        return false;
    }

private:

    DrawingArea area;
    DropDown chooser;
    StringList names;
    string[] listed;
    DrawingSheet[] sheets;
    int shown = -1;

    void draw(Context cr, int w, int h)
    {
        if (chooser.getSelected() < sheets.length)
            shown = cast(int) chooser.getSelected();
        cr.setSourceRgba(0.86, 0.87, 0.89, 1);
        cr.rectangle(0, 0, w, h);
        cr.fill();
        if (shown < 0 || shown >= sheets.length)
            return message(cr, w, h, "The model has no @drawing: add a function marked @drawing returning drawing(…)");
        auto ds = sheets[shown];
        if (ds.error.length)
            return message(cr, w, h, "The drawing could not be made: " ~ ds.error);
        const s = ds.sheet;
        // the sheet fitted with a margin, white, its y up as on paper
        immutable k = min((w - 40) / s.width, (h - 40) / s.height);
        immutable ox = (w - k * s.width) / 2, oy = (h - k * s.height) / 2;
        cr.setSourceRgba(1, 1, 1, 1);
        cr.rectangle(ox, oy, k * s.width, k * s.height);
        cr.fill();
        double X(double x) => ox + k * x;
        double Y(double y) => oy + k * (s.height - y);
        cr.setLineCap(LineCap.Round);
        cr.setSourceRgba(0, 0, 0, 1);
        foreach (pen; [Pen.thin, Pen.center, Pen.hidden, Pen.visible, Pen.border])
        {
            cr.setLineWidth(max(0.6, k * penWidth(pen)));
            if (pen == Pen.hidden)
                cr.setDash([2 * k, 1 * k], 0);
            else if (pen == Pen.center)
                cr.setDash([6 * k, 1 * k, 1 * k, 1 * k], 0);
            else
                cr.setDash([], 0);
            bool any;
            foreach (l; s.lines)
                if (l.pen == pen)
                {
                    cr.moveTo(X(l.x1), Y(l.y1));
                    cr.lineTo(X(l.x2), Y(l.y2));
                    any = true;
                }
            if (any)
                cr.stroke();
        }
        cr.setDash([], 0);
        foreach (a; s.arrows)
        {
            cr.moveTo(X(a.xy[0]), Y(a.xy[1]));
            cr.lineTo(X(a.xy[2]), Y(a.xy[3]));
            cr.lineTo(X(a.xy[4]), Y(a.xy[5]));
            cr.closePath();
            cr.fill();
        }
        cr.selectFontFace("Sans", FontSlant.Normal, FontWeight.Normal);
        foreach (t; s.texts)
        {
            // ⌀ is missing from many fonts: Ø in its place, as in the PDF
            import std.array : replace;
            immutable text = t.text.replace("⌀", "Ø");
            cr.save();
            cr.setFontSize(k * t.size * 1.4);
            TextExtents e;
            cr.textExtents(text, e);
            cr.translate(X(t.x), Y(t.y));
            cr.rotate(-t.angle * PI / 180);
            immutable dx = t.anchor == Anchor.middle ? -e.xAdvance / 2 : t.anchor == Anchor.end ? -e.xAdvance : 0;
            cr.moveTo(dx, 0);
            cr.showText(text);
            cr.restore();
        }
    }

    void message(Context cr, int w, int h, string text)
    {
        cr.setSourceRgba(0.25, 0.27, 0.3, 1);
        cr.selectFontFace("Sans", FontSlant.Normal, FontWeight.Normal);
        cr.setFontSize(15);
        TextExtents e;
        cr.textExtents(text, e);
        cr.moveTo(max(10.0, (w - e.xAdvance) / 2), h / 2.0);
        cr.showText(text);
    }

    static double min(double a, double b) => a < b ? a : b;
    static double max(double a, double b) => a > b ? a : b;
}
