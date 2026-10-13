/// The cheatsheet window (F1): every object, function and library entry
/// with one line, by section, searchable; the "how do I…" recipes first.
module hackerscad.gui.cheatsheet;

import std.algorithm : canFind;
import std.string : toLower;

import adw.header_bar : HeaderBar;
import adw.toolbar_view : ToolbarView;
import adw.window : AdwWindow = Window;
import gtk.box : Box;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.scrolled_window : ScrolledWindow;
import gtk.search_entry : SearchEntry;
import gtk.types : Orientation, PolicyType, SelectionMode;
import gtk.window : Window;
import pango.types : WrapMode;

import hackerscad.lang.reference;
import hackerscad.tool.cheatsheet : sections, usage, libraryLines;

final class CheatsheetWindow
{
    /// Called with the text to insert when an entry is double-clicked.
    void delegate(string) onInsert;

    this(Window parent)
    {
        collect();
        window = new AdwWindow;
        window.setTitle("hackerscad cheatsheet");
        window.setDefaultSize(620, 760);
        window.setTransientFor(parent);
        window.setHideOnClose(true);

        auto toolbar = new ToolbarView;
        toolbar.addTopBar(new HeaderBar);
        auto content = new Box(Orientation.Vertical, 8);
        content.setMarginStart(12);
        content.setMarginEnd(12);
        content.setMarginTop(6);
        content.setMarginBottom(12);
        searchEntry = new SearchEntry;
        searchEntry.setPlaceholderText("copy, hole, Frame, fillet…");
        searchEntry.connectSearchChanged(() => fill(searchEntry.getText()));
        content.append(searchEntry);
        list = new ListBox;
        list.setSelectionMode(SelectionMode.None);
        list.addCssClass("hcad-cheatsheet");
        list.connectRowActivated((ListBoxRow r) {
            auto i = r.getIndex();
            if (i >= 0 && i < shown.length && shown[i].insert.length && onInsert !is null)
                onInsert(shown[i].insert);
        });
        auto scroller = new ScrolledWindow;
        scroller.setPolicy(PolicyType.Never, PolicyType.Automatic);
        scroller.setVexpand(true);
        scroller.setChild(list);
        content.append(scroller);
        toolbar.setContent(content);
        window.setContent(toolbar);
        fill("");
    }

    Window widget() => window;

    /// Shows the entries matching `query`, as if typed in the search field.
    void search(string query) => searchEntry.setText(query);

    void present()
    {
        window.present();
        searchEntry.grabFocus();
    }

private:

    AdwWindow window;
    SearchEntry searchEntry;
    ListBox list;
    Entry[] entries, shown;
    enum recipes = "How do I…";

    struct Entry
    {
        string section, usage, doc, insert;
        bool heading;
    }

    void collect()
    {
        foreach (r; hackerscad.lang.reference.recipes)
            entries ~= Entry(recipes, r.code, r.task, r.code);
        foreach (section; sections)
            foreach (ref e; reference)
                if (e.group == section)
                    entries ~= Entry(section, usage(e), e.doc, e.name);
        string[] order;
        auto libs = libraryLines(order);
        foreach (lib; order)
            foreach (l; libs[lib])
            {
                import std.string : indexOf;
                auto name = l.usage;
                auto paren = name.indexOf('(');
                entries ~= Entry("import " ~ lib ~ ";", l.usage, l.doc, paren > 0 ? name[0 .. paren] : "");
            }
    }

    /// Every word of the query in the entry, singular or plural alike
    /// ("copy" finds "copies").
    static bool matches(const Entry e, string query)
    {
        import std.array : split;
        auto text = (e.usage ~ " " ~ e.doc ~ " " ~ e.section).toLower;
        foreach (w; query.split)
        {
            auto stem = w;
            foreach (suffix; ["ies", "es", "s", "y"])
                if (stem.length > suffix.length + 2 && stem[$ - suffix.length .. $] == suffix)
                {
                    stem = stem[0 .. $ - suffix.length];
                    break;
                }
            if (!text.canFind(stem))
                return false;
        }
        return true;
    }

    void fill(string query)
    {
        while (auto child = list.getFirstChild())
            list.remove(child);
        shown = null;
        auto q = query.toLower;
        string section;
        foreach (e; entries)
        {
            if (!matches(e, q))
                continue;
            if (e.section != section)
            {
                section = e.section;
                auto h = new Label(section);
                h.addCssClass("heading");
                h.setXalign(0);
                h.setMarginTop(shown.length ? 12 : 2);
                h.setMarginBottom(2);
                auto row = new ListBoxRow;
                row.setChild(h);
                row.setActivatable(false);
                list.append(row);
                shown ~= Entry(section, "", "", "", true);
            }
            auto box = new Box(Orientation.Vertical, 1);
            box.setMarginStart(6);
            box.setMarginTop(3);
            box.setMarginBottom(3);
            // a recipe is looked up by its task, the rest by its code
            immutable recipe = e.section == recipes;
            auto u = new Label(e.usage);
            u.addCssClass("monospace");
            u.setXalign(0);
            u.setWrap(true);
            u.setWrapMode(WrapMode.WordChar);
            u.setSelectable(true);
            Label d;
            if (e.doc.length)
            {
                d = new Label(e.doc);
                d.setXalign(0);
                d.setWrap(true);
            }
            if (recipe && d !is null)
            {
                u.addCssClass("dim-label");
                box.append(d);
                box.append(u);
            }
            else
            {
                box.append(u);
                if (d !is null)
                {
                    d.addCssClass("dim-label");
                    box.append(d);
                }
            }
            auto row = new ListBoxRow;
            row.setChild(box);
            row.setTooltipText(e.insert.length ? "Double-click to insert it at the cursor" : null);
            list.append(row);
            shown ~= e;
        }
    }
}
