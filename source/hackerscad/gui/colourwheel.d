/// The right-click menu's Colour › Other…: a calibrated colour wheel, in a
/// small window of its own (it can be moved off the part). Its ring holds
/// every hue at one OKLCH lightness and chroma, so all of them look equally
/// bright (as the palette's colours do); two sliders change the lightness and
/// how vivid the colours are. The part shows each colour while it is chosen.
module hackerscad.gui.colourwheel;

import std.format : format;
import std.math : PI, atan2, cos, sin, sqrt;

import cairo.context : Context;
import gtk.box : Box;
import gtk.button : Button;
import gtk.drawing_area : DrawingArea;
import gtk.gesture_drag : GestureDrag;
import gtk.label : Label;
import gtk.scale : Scale;
import gtk.types : Orientation;
import gtk.widget : Widget;
import gtk.window : Window;

import hackerscad.geom.color : colourOklch, oklchColour;

final class ColourWheel
{
    Window win;
    private DrawingArea wheel;
    private Label hex;
    private double lightness, chroma, hue;
    private double dragX, dragY;

    private bool done;

    /// Opens over `parent` on colour `start` (0xRRGGBB): each colour chosen
    /// goes to `preview`; Apply gives the last to `apply`; Cancel, or closing
    /// the window, calls `cancel`.
    this(Window parent, uint start, void delegate(uint rgb) preview, void delegate(uint rgb) apply,
        void delegate() cancel)
    {
        this.preview = preview;
        auto o = colourOklch(start);
        lightness = o[0];
        hue = o[2];
        // a grey has no hue to keep: the palette's vividness
        chroma = o[1] < 0.03 ? 0.15 : o[1];

        win = new Window;
        win.setTitle("Other colour");
        win.setTransientFor(parent);
        win.setModal(false);
        win.setResizable(false);
        win.setHideOnClose(false);
        auto box = new Box(Orientation.Vertical, 6);
        box.setMarginTop(10);
        box.setMarginBottom(10);
        box.setMarginStart(12);
        box.setMarginEnd(12);

        wheel = new DrawingArea;
        wheel.setContentWidth(220);
        wheel.setContentHeight(220);
        wheel.setDrawFunc((DrawingArea, Context cr, int w, int h) => draw(cr, w, h));
        wheel.setTooltipText("Every hue at the same brightness: click or drag on the ring");
        auto drag = new GestureDrag;
        drag.connectDragBegin((double px, double py) {
            dragX = px;
            dragY = py;
            pick(px, py);
        });
        drag.connectDragUpdate((double dx, double dy) => pick(dragX + dx, dragY + dy));
        wheel.addController(drag);
        box.append(wheel);

        box.append(slider("Lightness", 0.45, 0.95, lightness, (v) { lightness = v; }));
        box.append(slider("Vividness", 0, 0.25, chroma, (v) { chroma = v; }));

        auto row = new Box(Orientation.Horizontal, 8);
        hex = new Label("");
        // one width for every code: digits and A-F differ in a proportional font
        hex.addCssClass("monospace");
        hex.setWidthChars(7);
        hex.setMaxWidthChars(7);
        hex.setSelectable(true);
        hex.setHexpand(true);
        hex.setXalign(0);
        row.append(hex);
        auto no = new Button;
        no.setLabel("Cancel");
        no.connectClicked(() => win.close());
        row.append(no);
        auto ok = new Button;
        ok.setLabel("Apply");
        ok.addCssClass("suggested-action");
        ok.connectClicked(() {
            done = true;
            immutable rgb = colour();
            win.close();
            apply(rgb);
        });
        row.append(ok);
        box.append(row);
        win.setChild(box);
        // closed any other way than Apply: the part takes back its colour
        win.connectCloseRequest(() {
            if (!done)
            {
                done = true;
                cancel();
            }
            return false;
        });
        changed();
        win.present();
    }

    private void delegate(uint rgb) preview;

    /// The colour shown: on the ring, at the lightness and vividness chosen.
    uint colour() => oklchColour(lightness, chroma, hue);

    private Widget slider(string name, double min, double max, double value, void delegate(double) set)
    {
        auto row = new Box(Orientation.Horizontal, 8);
        auto l = new Label(name);
        l.setXalign(0);
        l.setWidthChars(9);
        l.addCssClass("dim-label");
        row.append(l);
        auto s = Scale.newWithRange(Orientation.Horizontal, min, max, 0.01);
        s.setValue(value);
        s.setDrawValue(false);
        s.setHexpand(true);
        s.connectValueChanged(() {
            set(s.getValue());
            changed();
        });
        row.append(s);
        return row;
    }

    private void changed()
    {
        hex.setText(format("#%06X", colour()));
        wheel.queueDraw();
        if (preview !is null)
            preview(colour());
    }

    // the ring between these fractions of the half size; hue 0 at the right,
    // growing counterclockwise as on paper
    private enum outer = 0.97, inner = 0.68;

    private void pick(double x, double y)
    {
        immutable cx = wheel.getWidth() / 2.0, cy = wheel.getHeight() / 2.0;
        if (sqrt((x - cx) ^^ 2 + (y - cy) ^^ 2) < 4)
            return;
        auto h = -atan2(y - cy, x - cx) * 180 / PI;
        hue = h < 0 ? h + 360 : h;
        changed();
    }

    private void draw(Context cr, int w, int h)
    {
        immutable cx = w / 2.0, cy = h / 2.0, half = (w < h ? w : h) / 2.0;
        immutable R = half * outer, r = half * inner;
        void source(uint rgb) => cr.setSourceRgb((rgb >> 16 & 0xFF) / 255.0, (rgb >> 8 & 0xFF) / 255.0, (rgb & 0xFF) / 255.0);
        enum steps = 180;
        foreach (i; 0 .. steps)
        {
            // a little overlap: no seams between the slices
            immutable a0 = -2 * PI * i / steps, a1 = -2 * PI * (i + 1) / steps - 0.01;
            cr.newPath();
            cr.arcNegative(cx, cy, R, a0, a1);
            cr.arc(cx, cy, r, a1, a0);
            cr.closePath();
            source(oklchColour(lightness, chroma, 360.0 * (i + 0.5) / steps));
            cr.fill();
        }
        // the colour chosen, in the middle
        cr.newPath();
        cr.arc(cx, cy, r - 10, 0, 2 * PI);
        source(colour());
        cr.fill();
        // where it is on the ring
        immutable a = -hue * PI / 180, m = (R + r) / 2;
        immutable mx = cx + m * cos(a), my = cy + m * sin(a);
        cr.newPath();
        cr.arc(mx, my, (R - r) / 2 - 1, 0, 2 * PI);
        cr.setLineWidth(3);
        cr.setSourceRgb(1, 1, 1);
        cr.stroke();
        cr.newPath();
        cr.arc(mx, my, (R - r) / 2 + 1, 0, 2 * PI);
        cr.setLineWidth(1);
        cr.setSourceRgba(0, 0, 0, 0.5);
        cr.stroke();
    }
}
