/// A compact context menu in the style of desktop applications: dense rows,
/// values right-aligned, section headings. Groups open as pages of the same
/// popover, with a row to go back (as GNOME menus do): one surface, so every
/// click reaches its entry.
module hackerscad.gui.menu;

import gtk.box : Box;
import gtk.button : Button;
import gtk.label : Label;
import gtk.popover : Popover;
import gtk.separator : Separator;
import gtk.stack : Stack;
import gtk.widget : Widget;
import gtk.types : Orientation, PositionType, StackTransitionType;
import gdk.rectangle : Rectangle;
import glib.global : idleAdd;
import glib.types : PRIORITY_DEFAULT;

struct MenuEntry
{
    enum Kind
    {
        item,
        group,
        heading,
        separator,
    }

    Kind kind;
    string label;
    void delegate() run;
    MenuEntry[] children;
    string detail;      /// right-aligned, dimmed (values)
    bool enabled = true;
    string swatch;      /// a colour shown before the label, "#RRGGBB"

    static MenuEntry item(string label, void delegate() run, string detail = null) =>
        MenuEntry(Kind.item, label, run, null, detail);
    static MenuEntry group(string label, MenuEntry[] children) => MenuEntry(Kind.group, label, null, children);
    static MenuEntry heading(string label, string detail = null) => MenuEntry(Kind.heading, label, null, null, detail);
    static MenuEntry separator() => MenuEntry(Kind.separator);
    static MenuEntry colour(string label, string rgb, void delegate() run, string detail = null)
    {
        auto e = item(label, run, detail);
        e.swatch = rgb;
        return e;
    }
}

/// Shows `entries` in a popover pointing at (x, y) of `parent`.
Popover popupMenu(Widget parent, double x, double y, MenuEntry[] entries)
{
    auto m = new Menu(entries);
    m.pop.setParent(parent);
    m.pop.setPointingTo(Rectangle(cast(int) x, cast(int) y, 1, 1));
    m.pop.setPosition(PositionType.Right);
    m.pop.connectClosed(() {
        idleAdd(PRIORITY_DEFAULT, () { m.pop.unparent(); return false; });
    });
    m.pop.popup();
    lastMenu = m;
    return m.pop;
}

private Menu lastMenu;

/// The entries of the last menu shown (null if none), and closing it.
MenuEntry[] lastMenuEntries() => lastMenu is null ? null : lastMenu.root;

void closeLastMenu()
{
    if (lastMenu !is null)
        lastMenu.pop.popdown();
}

/// Clicks the entries of the last menu shown, one label per level (for
/// scripts and agents): ["Hole at point", "Clearance", "M3"]. Returns null,
/// or what went wrong with the entries that were available.
string activateMenuPath(string[] path)
{
    import std.algorithm : sort;
    import std.array : join;

    if (lastMenu is null)
        return "no menu is open";
    foreach (label; path)
    {
        auto page = lastMenu.actions.get(lastMenu.current, null);
        auto b = label in page;
        if (b is null)
        {
            auto names = page.keys;
            names.sort;
            return "no entry '" ~ label ~ "' here; entries: " ~ names.join(", ");
        }
        (*b)();   // directly: Button.activate() would click only after a short delay
    }
    return null;
}

private final class Menu
{
    Popover pop;
    Stack pages;
    int pageCount;
    void delegate()[string][string] actions;   /// page name → label → what clicking it does
    string current = "main";          /// the page shown
    MenuEntry[] root;

    this(MenuEntry[] entries)
    {
        root = entries;
        pop = new Popover;
        pop.addCssClass("hcad-menu");
        pop.setHasArrow(false);
        pages = new Stack;
        pages.setVhomogeneous(false);
        pages.setHhomogeneous(false);
        // no size animation: the popover takes the new page's size at once (see show)
        pages.setInterpolateSize(false);
        pages.setTransitionType(StackTransitionType.SlideLeftRight);
        pages.setTransitionDuration(150);
        pages.addNamed(page(entries, null, null, "main"), "main");
        pop.setChild(pages);
    }

    void show(string name)
    {
        current = name;
        pages.setVisibleChildName(name);
        // a popover grows with its content but does not shrink by itself: a
        // short page after a long one would keep the long one's height
        pop.present();
    }

    /// A page of entries named `self`; `back` is the name of the page to return to.
    Widget page(MenuEntry[] entries, string title, string back, string self)
    {
        auto box = new Box(Orientation.Vertical, 0);
        if (back !is null)
        {
            auto row = new Box(Orientation.Horizontal, 8);
            auto arrow = new Label("‹");
            arrow.addCssClass("dim-label");
            row.append(arrow);
            auto l = new Label(title);
            l.setXalign(0);
            l.setHexpand(true);
            l.addCssClass("heading");
            row.append(l);
            auto b = new Button;
            b.addCssClass("flat");
            b.addCssClass("hcad-menu-back");
            b.setChild(row);
            b.connectClicked(() => show(back));
            box.append(b);
            box.append(new Separator(Orientation.Horizontal));
        }
        foreach (e; entries)
            add(box, e, self);
        return box;
    }

    // one call per entry: closures made in a loop would share its variables
    void add(Box box, MenuEntry e, string currentPage)
    {
        final switch (e.kind)
        {
        case MenuEntry.Kind.separator:
            box.append(new Separator(Orientation.Horizontal));
            return;
        case MenuEntry.Kind.heading:
            {
                auto row = new Box(Orientation.Horizontal, 12);
                row.addCssClass("hcad-menu-heading");
                auto l = new Label(e.label);
                l.setXalign(0);
                l.setHexpand(true);
                row.append(l);
                if (e.detail.length)
                    row.append(new Label(e.detail));
                box.append(row);
                return;
            }
        case MenuEntry.Kind.item, MenuEntry.Kind.group:
            break;
        }
        auto row = new Box(Orientation.Horizontal, 16);
        if (e.swatch.length)
        {
            row.setSpacing(10);
            row.append(swatchDot(e.swatch));
        }
        auto label = new Label(e.label);
        label.setXalign(0);
        label.setHexpand(true);
        row.append(label);
        if (e.detail.length)
        {
            auto d = new Label(e.detail);
            d.addCssClass("dim-label");
            d.addCssClass("numeric");
            row.append(d);
        }
        auto button = new Button;
        button.addCssClass("flat");
        button.setChild(row);
        button.setSensitive(e.enabled);
        box.append(button);

        if (e.kind == MenuEntry.Kind.group)
        {
            auto arrow = new Label("›");
            arrow.addCssClass("dim-label");
            row.append(arrow);
            // pages are named after a running number: titles may repeat in different groups
            import std.conv : to;
            immutable name = "page" ~ (pageCount++).to!string;
            auto children = e.children;
            auto title = e.label;
            bool built;
            void open()
            {
                if (!built)
                {
                    auto p = page(children, title, currentPage, name);
                    pages.addNamed(p, name);
                    built = true;
                }
                show(name);
            }

            button.connectClicked(() => open());
            actions[currentPage][e.label] = &open;
        }
        else
        {
            auto run = e.run;
            void choose()
            {
                pop.popdown();
                if (run !is null)
                    run();
            }

            button.connectClicked(() => choose());
            actions[currentPage][e.label] = &choose;
        }
    }

}

/// A round sample of colour `rgb` ("#RRGGBB"), outlined so that white shows.
private Widget swatchDot(string rgb)
{
    import gdk.display : Display;
    import gtk.css_provider : CssProvider;
    import gtk.style_context : StyleContext;
    import std.string : toLower;
    immutable cls = "hcad-swatch-" ~ rgb[1 .. $].toLower;
    // one rule per colour, added the first time it is shown
    static bool[string] styled;
    if (cls !in styled)
    {
        auto css = new CssProvider;
        css.loadFromString("." ~ cls ~ " { background: " ~ rgb ~ "; }");
        StyleContext.addProviderForDisplay(Display.getDefault(), css, 600);
        styled[cls] = true;
    }
    auto dot = new Box(Orientation.Horizontal, 0);
    dot.addCssClass("hcad-swatch");
    dot.addCssClass(cls);
    dot.setValign(imported!"gtk.types".Align.Center);
    return dot;
}

/// Draws popover `p`, when open, over a snapshot of `window` at the place
/// GTK put it: popovers are surfaces of their own, missing from a
/// screenshot of the window.
void snapshotPopover(imported!"gtk.snapshot".Snapshot snap, Widget window, Popover p)
{
    import gdk.c.functions : gdk_popup_get_position_x, gdk_popup_get_position_y;
    import gdk.c.types : GdkPopup;
    import graphene.point : Point;
    import gtk.native : Native;
    import gtk.widget_paintable : WidgetPaintable;
    auto top = cast(Native) window;
    if (top is null || p is null || !p.getVisible() || p.getWidth() <= 0 || p.getSurface() is null)
        return;
    double wx, wy, sx, sy;
    top.getSurfaceTransform(wx, wy);
    p.getSurfaceTransform(sx, sy);
    auto popup = cast(GdkPopup*) p.getSurface()._cPtr;
    Point at;
    at.x = cast(float)(gdk_popup_get_position_x(popup) + sx - wx);
    at.y = cast(float)(gdk_popup_get_position_y(popup) + sy - wy);
    snap.save();
    snap.translate(at);
    new WidgetPaintable(p).snapshot(snap, p.getWidth(), p.getHeight());
    snap.restore();
}
