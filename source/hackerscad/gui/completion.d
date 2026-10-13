/// Code completion in the editor: a list of what can be written at the
/// cursor (with its documentation), the signature of the call being
/// written, and help when the pointer rests on a name. The proposals come
/// from hackerscad.tool.complete; the popups are plain GTK widgets, so the
/// editor keeps the focus.
module hackerscad.gui.completion;

import std.conv : to;
import std.typecons : Yes;
import std.utf : count, toUTFindex;

import gdk.rectangle : Rectangle;
import gdk.types : ModifierType, KEY_Up, KEY_Down, KEY_Return, KEY_KP_Enter, KEY_Tab, KEY_Escape, KEY_space, KEY_Page_Up,
    KEY_Page_Down;
import glib.global : timeoutAdd;
import glib.source : Source;
import glib.types : PRIORITY_DEFAULT;
import gtk.box : Box;
import gtk.event_controller_key : EventControllerKey;
import gtk.gesture_click : GestureClick;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.popover : Popover;
import gtk.scrolled_window : ScrolledWindow;
import gtk.text_iter : TextIter;
import gtk.tooltip : Tooltip;
import gtk.snapshot : Snapshot;
import gtk.widget : Widget;
import gtk.widget_paintable : WidgetPaintable;
import gtk.types : Orientation, Align, PositionType, PropagationPhase, PolicyType, TextWindowType, SelectionMode;
import gtksource.buffer : SourceBuffer = Buffer;
import gtksource.view : SourceView = View;
import pango.types : EllipsizeMode, WrapMode;

import hackerscad.tool.complete;

final class EditorCompletion
{
    /// The model's path and the library folders, for the imports.
    string delegate() path;
    string[] libraryDirs;

    this(SourceView view, SourceBuffer buffer)
    {
        this.view = view;
        this.buffer = buffer;
        build();

        auto keys = new EventControllerKey;
        keys.setPropagationPhase(PropagationPhase.Capture);
        keys.connectKeyPressed((uint key, uint code, ModifierType state) => onKey(key, state));
        view.addController(keys);

        // typing opens or updates the list; the signature follows the cursor
        buffer.connectInsertText((TextIter at, string text) {
            if (text.length == 1)
                schedule(text[0] == '.' || text[0] == '@' || text[0] == '(' || text[0] == ',' || isWordChar(text[0]), false);
            else
                hide();
        }, Yes.After);
        buffer.connectDeleteRange((TextIter a, TextIter b) {
            if (list.getVisible())
                schedule(false, false);
            else
                updateSignatureSoon();
        }, Yes.After);
        auto click = new GestureClick;
        click.connectPressed(() { hide(); updateSignatureSoon(); });
        view.addController(click);

        // help on the name under the pointer
        view.setHasTooltip(true);
        view.connectQueryTooltip((int x, int y, bool keyboard, Tooltip tip) => tooltip(x, y, tip));
    }

    /// Ctrl+Space: the list even without a typed prefix.
    void open() => schedule(true, true);

    /// Draws the open popups over a snapshot of `window` (they are surfaces
    /// of their own, missing from the window's screenshot).
    void snapshotOver(Snapshot snap, Widget window)
    {
        import gdk.c.functions : gdk_popup_get_position_x, gdk_popup_get_position_y;
        import gdk.c.types : GdkPopup;
        import graphene.point : Point;
        import gtk.native : Native;
        auto top = cast(Native) window;
        if (top is null)
            return;
        double wx, wy;
        top.getSurfaceTransform(wx, wy);
        foreach (p; [sig, list])
        {
            if (!p.getVisible() || p.getWidth() <= 0 || p.getSurface() is null)
                continue;
            // where GTK put the popup's surface, and the popover inside it
            auto popup = cast(GdkPopup*) p.getSurface()._cPtr;
            double sx, sy;
            p.getSurfaceTransform(sx, sy);
            Point at;
            at.x = cast(float) (gdk_popup_get_position_x(popup) + sx - wx);
            at.y = cast(float) (gdk_popup_get_position_y(popup) + sy - wy);
            snap.save();
            snap.translate(at);
            new WidgetPaintable(p).snapshot(snap, p.getWidth(), p.getHeight());
            snap.restore();
        }
    }

    /// Selects the entry `label` when the list opens next (for the control
    /// socket: a screenshot with a chosen entry). Call after open().
    void select(string label)
    {
        pendingSelect = label;   // applied by the refresh open() schedules
    }

    /// Closes the list and the signature, if open.
    void close() => hide();

    /// What the list would show at the cursor (for the control socket).
    CompletionResult proposals()
    {
        auto src = text();
        return complete(src, cursorByte(src), path is null ? "" : path(), libraryDirs);
    }

private:

    SourceView view;
    SourceBuffer buffer;
    Popover list, sig;
    ListBox rows;
    ScrolledWindow scroller;
    Label doc, sigLabel;
    CompletionResult current;
    uint pending, sigPending;

    static bool isWordChar(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';

    void build()
    {
        list = new Popover;
        list.addCssClass("hcad-completion");
        list.setParent(view);
        list.setAutohide(false);
        list.setHasArrow(false);
        list.setPosition(PositionType.Bottom);
        list.setHalign(Align.Start);
        list.setCanFocus(false);
        auto box = new Box(Orientation.Horizontal, 0);
        rows = new ListBox;
        rows.setSelectionMode(SelectionMode.Browse);
        rows.addCssClass("hcad-completion-list");
        rows.connectRowActivated((ListBoxRow r) => accept(r.getIndex()));
        rows.connectRowSelected((ListBoxRow r) => showDoc(r is null ? -1 : r.getIndex()));
        scroller = new ScrolledWindow;
        scroller.setPolicy(PolicyType.Never, PolicyType.Automatic);
        scroller.setMaxContentHeight(260);
        scroller.setPropagateNaturalHeight(true);
        scroller.setPropagateNaturalWidth(true);
        scroller.setChild(rows);
        box.append(scroller);
        doc = new Label("");
        doc.addCssClass("hcad-completion-doc");
        doc.setWrap(true);
        doc.setWrapMode(WrapMode.WordChar);
        doc.setMaxWidthChars(38);
        doc.setXalign(0);
        doc.setYalign(0);
        doc.setValign(Align.Start);
        box.append(doc);
        list.setChild(box);

        sig = new Popover;
        sig.addCssClass("hcad-signature");
        sig.setParent(view);
        sig.setAutohide(false);
        sig.setHasArrow(false);
        sig.setPosition(PositionType.Top);
        sig.setHalign(Align.Start);
        sig.setCanFocus(false);
        sigLabel = new Label("");
        sigLabel.addCssClass("monospace");
        sigLabel.setMaxWidthChars(80);
        sigLabel.setWrap(true);
        sig.setChild(sigLabel);
    }

    string text()
    {
        TextIter s, e;
        buffer.getBounds(s, e);
        return buffer.getText(s, e, true);
    }

    /// The cursor as a byte offset of `src` (GTK counts characters).
    size_t cursorByte(string src)
    {
        TextIter it;
        buffer.getIterAtMark(it, buffer.getInsert());
        return toUTFindex(src, it.getOffset());
    }

    void schedule(bool show, bool manual)
    {
        if (pending)
            Source.remove(pending);
        pending = timeoutAdd(PRIORITY_DEFAULT, 40, () {
            pending = 0;
            refresh(show || list.getVisible(), manual);
            return false;
        });
    }

    void updateSignatureSoon()
    {
        if (sigPending)
            Source.remove(sigPending);
        sigPending = timeoutAdd(PRIORITY_DEFAULT, 60, () {
            sigPending = 0;
            auto src = text();
            showSignature(complete(src, cursorByte(src), path is null ? "" : path(), libraryDirs));
            return false;
        });
    }

    void refresh(bool wanted, bool manual)
    {
        auto src = text();
        auto at = cursorByte(src);
        current = complete(src, at, path is null ? "" : path(), libraryDirs);
        showSignature(current);
        // open the list after a dot or @, on a name of two letters, or on demand
        immutable trigger = current.from > 0 && (src[current.from - 1] == '.' || src[current.from - 1] == '@');
        if (!wanted || current.items.length == 0 || (!manual && !trigger && current.prefix.length < 2)
            || (current.items.length == 1 && current.items[0].insert == current.prefix))
        {
            hideList();
            return;
        }
        fill();
        place(list, current.from);
        list.popup();
        selectPending();
    }

    void fill()
    {
        while (auto child = rows.getFirstChild())
            rows.remove(child);
        foreach (c; current.items[0 .. $ < 80 ? $ : 80])
        {
            auto row = new Box(Orientation.Horizontal, 8);
            row.setMarginStart(6);
            row.setMarginEnd(6);
            // a letter for the kind, as in most editors (icons vary between themes)
            auto badge = new Label(badgeFor(c.kind));
            badge.addCssClass("hcad-kind");
            badge.addCssClass("hcad-kind-" ~ c.kind);
            badge.setValign(Align.Center);
            row.append(badge);
            auto name = new Label(c.label);
            name.addCssClass("monospace");
            name.setXalign(0);
            name.setHexpand(true);
            row.append(name);
            auto detail = new Label(typeOf(c.detail));
            detail.addCssClass("dim-label");
            detail.addCssClass("caption");
            detail.setEllipsize(EllipsizeMode.End);
            detail.setMaxWidthChars(18);
            row.append(detail);
            rows.append(row);
        }
        rows.selectRow(rows.getRowAtIndex(0));
        selectPending();
    }

    /// The part of a signature worth showing in the list: its result type.
    static string typeOf(string detail)
    {
        import std.string : lastIndexOf, indexOf;
        auto arrow = detail.lastIndexOf("→");
        if (arrow >= 0)
            return detail[arrow + "→".length .. $];
        auto colon = detail.indexOf(": ");
        return colon >= 0 && detail.indexOf('(') < 0 ? detail[colon + 2 .. $] : "";
    }

    /// A short word for the kind of an entry.
    static string badgeFor(string kind)
    {
        switch (kind)
        {
        case "function": return "fn";
        case "method": return "method";
        case "property": return "prop";
        case "field": return "field";
        case "parameter": return "arg";
        case "variable": return "var";
        case "keyword": return "keyword";
        case "unit": return "unit";
        case "constant": return "const";
        case "type": return "type";
        case "module": return "module";
        case "annotation": return "@";
        default: return kind;
        }
    }

    void showDoc(int i)
    {
        if (i < 0 || i >= current.items.length)
        {
            doc.setLabel("");
            return;
        }
        auto c = current.items[i];
        import glib.global : markupEscapeText;
        auto m = "<tt>" ~ markupEscapeText(c.detail.length ? c.detail : c.label) ~ "</tt>";
        if (c.doc.length)
            m ~= "\n\n" ~ markupEscapeText(c.doc);
        doc.setMarkup(m);
        doc.setVisible(true);
    }

    /// Points a popover at the text position `byteOffset`.
    void place(Popover p, size_t byteOffset)
    {
        auto src = text();
        TextIter it;
        buffer.getIterAtOffset(it, cast(int) count(src[0 .. byteOffset < src.length ? byteOffset : src.length]));
        Rectangle r;
        view.getIterLocation(it, r);
        int x, y;
        view.bufferToWindowCoords(TextWindowType.Widget, r.x, r.y, x, y);
        p.setPointingTo(Rectangle(x, y, 1, r.height));
    }

    void showSignature(CompletionResult res)
    {
        if (res.signature.length == 0)
        {
            sig.popdown();
            return;
        }
        sigLabel.setMarkup(highlighted(res.signature, res.activeParam));
        TextIter it;
        buffer.getIterAtMark(it, buffer.getInsert());
        auto src = text();
        place(sig, toUTFindex(src, it.getOffset()));
        sig.popup();
    }

    /// The signature with the active argument in bold.
    static string highlighted(string signature, int active)
    {
        import glib.global : markupEscapeText;
        import std.string : indexOf, lastIndexOf;
        auto open = signature.indexOf('('), close = signature.lastIndexOf(')');
        if (open < 0 || close < open)
            return markupEscapeText(signature);
        string[] params;
        int depth;
        size_t start = open + 1;
        foreach (k; open + 1 .. close)
        {
            auto ch = signature[k];
            if (ch == '(' || ch == '[')
                depth++;
            else if (ch == ')' || ch == ']')
                depth--;
            else if (ch == ',' && depth == 0)
            {
                params ~= signature[start .. k];
                start = k + 1;
            }
        }
        params ~= signature[start .. close];
        string m = markupEscapeText(signature[0 .. open + 1]);
        foreach (k, p; params)
        {
            if (k)
                m ~= ",";
            auto e = markupEscapeText(p);
            m ~= k == active ? "<b>" ~ e ~ "</b>" : e;
        }
        return m ~ markupEscapeText(signature[close .. $]);
    }

    bool onKey(uint key, ModifierType state)
    {
        if (key == KEY_space && (state & ModifierType.ControlMask))
        {
            open();
            return true;
        }
        if (key == KEY_Escape && sig.getVisible() && !list.getVisible())
        {
            sig.popdown();
            return true;
        }
        if (!list.getVisible())
            return false;
        auto row = rows.getSelectedRow();
        immutable i = row is null ? 0 : row.getIndex();
        immutable n = cast(int) (current.items.length < 80 ? current.items.length : 80);
        switch (key)
        {
        case KEY_Down:
            rows.selectRow(rows.getRowAtIndex((i + 1) % n));
            break;
        case KEY_Up:
            rows.selectRow(rows.getRowAtIndex((i + n - 1) % n));
            break;
        case KEY_Page_Down:
            rows.selectRow(rows.getRowAtIndex(i + 8 < n ? i + 8 : n - 1));
            break;
        case KEY_Page_Up:
            rows.selectRow(rows.getRowAtIndex(i > 8 ? i - 8 : 0));
            break;
        case KEY_Return, KEY_KP_Enter, KEY_Tab:
            accept(i);
            break;
        case KEY_Escape:
            hideList();
            break;
        default:
            return false;
        }
        if (auto r = rows.getSelectedRow())
            ensureVisible(r.getIndex(), n);
        return true;
    }

    /// Scrolls the list so that row `i` (of `n`, all the same height) shows.
    string pendingSelect;

    void selectPending()
    {
        if (pendingSelect.length == 0 || !list.getVisible())
            return;
        foreach (i, c; current.items[0 .. $ < 80 ? $ : 80])
            if (c.label == pendingSelect)
            {
                rows.selectRow(rows.getRowAtIndex(cast(int) i));
                ensureVisible(cast(int) i, cast(int) (current.items.length < 80 ? current.items.length : 80));
                pendingSelect = null;
                return;
            }
    }

    void ensureVisible(int i, int n)
    {
        auto adj = scroller.getVadjustment();
        if (n <= 0 || adj is null)
            return;
        immutable rowH = (adj.getUpper() - adj.getLower()) / n;
        immutable top = i * rowH, bottom = top + rowH;
        if (top < adj.getValue())
            adj.setValue(top);
        else if (bottom > adj.getValue() + adj.getPageSize())
            adj.setValue(bottom - adj.getPageSize());
    }

    /// Replaces the typed prefix with proposal `i`.
    void accept(int i)
    {
        if (i < 0 || i >= current.items.length)
            return;
        auto c = current.items[i];
        auto src = text();
        TextIter a, b;
        buffer.getIterAtOffset(a, cast(int) count(src[0 .. current.from]));
        buffer.getIterAtMark(b, buffer.getInsert());
        buffer.beginUserAction();
        buffer.delete_(a, b);
        buffer.insert(a, c.insert);
        buffer.endUserAction();
        hideList();
        updateSignatureSoon();
    }

    void hideList()
    {
        if (list.getVisible())
            list.popdown();
    }

    void hide()
    {
        hideList();
        sig.popdown();
    }

    bool tooltip(int x, int y, Tooltip tip)
    {
        int bx, by;
        view.windowToBufferCoords(TextWindowType.Widget, x, y, bx, by);
        TextIter it;
        if (!view.getIterAtLocation(it, bx, by))
            return false;
        auto src = text();
        auto info = describeAt(src, toUTFindex(src, it.getOffset()), path is null ? "" : path(), libraryDirs);
        if (info[0].length == 0)
            return false;
        import glib.global : markupEscapeText;
        tip.setMarkup("<tt>" ~ markupEscapeText(info[0]) ~ "</tt>"
            ~ (info[1].length ? "\n" ~ markupEscapeText(info[1]) : ""));
        return true;
    }
}
