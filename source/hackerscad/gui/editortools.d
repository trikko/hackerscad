/// What the code editor does besides typing: a bar to find and replace
/// (Ctrl+F, Ctrl+H, F3), going to a line (Ctrl+L), commenting lines out and
/// back (Ctrl+/), duplicating (Ctrl+D), deleting (Ctrl+Shift+K) and moving
/// lines (Alt+Up, Alt+Down), brackets and quotes that close themselves.
/// Every change is one step of Undo. The control socket does the same
/// through findText() and lineAction().
module hackerscad.gui.editortools;

import std.algorithm : canFind, max, min;
import std.array : join, split;
import std.conv : to;
import std.format : format;
import std.string : strip, stripLeft;

import gdk.rectangle : Rectangle;
import gdk.types : ModifierType, KEY_Down, KEY_Escape, KEY_BackSpace, KEY_KP_Enter, KEY_Return, KEY_Up, KEY_k, KEY_K,
    KEY_d, KEY_slash;
import gtk.box : Box;
import gtk.button : Button;
import gtk.entry : Entry;
import gtk.event_controller_key : EventControllerKey;
import gtk.label : Label;
import gtk.popover : Popover;
import gtk.revealer : Revealer;
import gtk.scrolled_window : ScrolledWindow;
import gtk.search_entry : SearchEntry;
import gtk.text_iter : TextIter;
import gtk.toggle_button : ToggleButton;
import gtk.types : Align, Orientation, PolicyType, PositionType;
import gtk.widget : Widget;
import gtksource.buffer : SourceBuffer = Buffer;
import gtksource.search_context : SearchContext;
import gtksource.search_settings : SearchSettings;
import gtksource.view : SourceView = View;

/// The modifier of the shortcuts: Ctrl, and Cmd on macOS (GTK 4's <Primary>
/// is Ctrl everywhere, Cmd comes as Meta).
version (OSX)
    enum primaryMask = ModifierType.MetaMask;
else
    enum primaryMask = ModifierType.ControlMask;

final class EditorTools
{
    /// The find bar, to put above the code; hidden until Ctrl+F.
    Revealer bar;

    this(SourceView editor, SourceBuffer buffer)
    {
        this.editor = editor;
        this.buffer = buffer;
        editor.setIndentOnTab(true);
        buffer.setHighlightMatchingBrackets(true);
        settings = new SearchSettings;
        settings.setWrapAround(true);
        search = new SearchContext(buffer, settings);
        search.setHighlight(false);
        search.connectNotify("occurrences-count", () => updateCount());
        buildBar();
        buildGoTo();
        auto keys = new EventControllerKey;
        keys.setPropagationPhase(imported!"gtk.types".PropagationPhase.Capture);
        keys.connectKeyPressed((uint key, uint code, ModifierType state) => onKey(key, state));
        editor.addController(keys);
    }

    // ------------------------------------------------------------ find and replace

    /// Ctrl+F: the bar, with the selection (one line of it) to look for.
    void find() => open(false);

    /// Ctrl+H: the bar with the replace row.
    void replace() => open(true);

    /// The bar open on `text` (with the replace row and `replacement`), the
    /// first match selected: what the user sees after typing it.
    void showBar(string text, string replacement = null)
    {
        open(replacement !is null);
        findEntry.setText(text);
        if (replacement !is null)
            replaceEntry.setText(replacement);
    }

    /// F3: the next match after the selection, round to the top.
    void next()
    {
        if (!hasText())
            return find();
        TextIter s, e, ms, me;
        buffer.getSelectionBounds(s, e);
        bool wrapped;
        if (search.forward(e, ms, me, wrapped))
            select(ms, me);
        updateCount();
    }

    /// Shift+F3: the match before the selection.
    void previous()
    {
        if (!hasText())
            return find();
        TextIter s, e, ms, me;
        buffer.getSelectionBounds(s, e);
        bool wrapped;
        if (search.backward(s, ms, me, wrapped))
            select(ms, me);
        updateCount();
    }

    /// Esc in the bar: closed, the matches no longer marked, back to the code.
    void close()
    {
        bar.setRevealChild(false);
        search.setHighlight(false);
        editor.grabFocus();
    }

    /// The matches of `text` in the code (line and column from 1), the
    /// first `most`; with `replacement`, every match replaced, as one step of
    /// Undo, and how many. The problem with a regular expression, or null.
    string findText(string text, bool regex, bool caseSensitive, bool word, string replacement, bool replaceAll,
        out FoundText[] found, out uint replaced, size_t most = 200)
    {
        auto s = new SearchSettings;
        s.setSearchText(text);
        s.setRegexEnabled(regex);
        s.setCaseSensitive(caseSensitive);
        s.setAtWordBoundaries(word);
        s.setWrapAround(false);
        auto c = new SearchContext(buffer, s);
        c.setHighlight(false);
        if (auto e = c.getRegexError())
            return e.message;
        if (replaceAll)
        {
            try
                replaced = c.replaceAll(replacement);
            catch (Exception e)
                return e.msg;
            return null;
        }
        TextIter at, ms, me;
        buffer.getStartIter(at);
        bool wrapped;
        while (found.length < most && c.forward(at, ms, me, wrapped) && !wrapped)
        {
            found ~= FoundText(ms.getLine() + 1, ms.getLineOffset() + 1, buffer.getText(ms, me, true));
            at = me.copy();
            if (ms.equal(me) && !at.forwardChar())
                break;
        }
        return null;
    }

    // ------------------------------------------------------------ go to line

    /// Ctrl+L: a field over the code for the line to go to.
    void goToLine()
    {
        TextIter it;
        buffer.getIterAtMark(it, buffer.getInsert());
        goToEntry.setPlaceholderText(format("Line, 1 to %d", buffer.getLineCount()));
        goToEntry.setText((it.getLine() + 1).to!string);
        Rectangle r;
        r.x = editor.getWidth() / 2;
        r.y = 8;
        r.width = 1;
        r.height = 1;
        goToPopover.setPointingTo(&r);
        goToPopover.popup();
        goToEntry.grabFocus();
        goToEntry.selectRegion(0, -1);
    }

    /// The cursor at the start of line `line` (from 1), shown.
    void showLine(int line)
    {
        TextIter it;
        buffer.getIterAtLine(it, max(0, min(line, buffer.getLineCount()) - 1));
        buffer.placeCursor(it);
        editor.scrollToMark(buffer.getInsert(), 0.2, false, 0, 0);
    }

    // ------------------------------------------------------------ lines

    /// What lineAction does.
    enum LineAction { comment, duplicate, remove, up, down, indent, unindent }

    /// Does `action` to the lines from `first` to `last` (from 1; 0: the
    /// selected ones), as one step of Undo; false when there is nothing to do.
    bool lineAction(LineAction action, int first = 0, int last = 0)
    {
        int a, b;
        if (first > 0)
        {
            a = max(1, first) - 1;
            b = min(max(first, last), buffer.getLineCount()) - 1;
        }
        else
            selectedLines(a, b);
        final switch (action)
        {
        case LineAction.comment: return comment(a, b);
        case LineAction.duplicate: return duplicate(a, b, first > 0);
        case LineAction.remove: return remove(a, b);
        case LineAction.up: return move(a, b, -1);
        case LineAction.down: return move(a, b, 1);
        case LineAction.indent: return indent(a, b, true);
        case LineAction.unindent: return indent(a, b, false);
        }
    }

private:

    SourceView editor;
    SourceBuffer buffer;
    SearchSettings settings;
    SearchContext search;
    SearchEntry findEntry;
    Entry replaceEntry;
    Label count;
    Box replaceRow;
    ToggleButton caseToggle, wordToggle, regexToggle, replaceToggle;
    Popover goToPopover;
    Entry goToEntry;

    void buildBar()
    {
        findEntry = new SearchEntry;
        findEntry.setHexpand(true);
        findEntry.setPlaceholderText("Find");
        findEntry.connectSearchChanged(() {
            settings.setSearchText(findEntry.getText());
            // the first match from where the selection starts, as one types
            TextIter s, e, ms, me;
            buffer.getSelectionBounds(s, e);
            bool wrapped;
            if (findEntry.getText().length && search.forward(s, ms, me, wrapped))
                select(ms, me);
            updateCount();
        });
        findEntry.connectActivate(() => next());
        findEntry.connectNextMatch(() => next());
        findEntry.connectPreviousMatch(() => previous());
        findEntry.connectStopSearch(() => close());
        {
            // Shift+Enter: the previous match
            auto keys = new EventControllerKey;
            keys.connectKeyPressed((uint key, uint code, ModifierType state) {
                if ((key == KEY_Return || key == KEY_KP_Enter) && (state & ModifierType.ShiftMask))
                {
                    previous();
                    return true;
                }
                return false;
            });
            findEntry.addController(keys);
        }
        count = new Label("");
        count.addCssClass("dim-label");
        count.addCssClass("numeric");
        count.setWidthChars(9);
        caseToggle = option("Aa", "Match case", (bool on) => settings.setCaseSensitive(on));
        wordToggle = option("ab|", "Whole words only", (bool on) => settings.setAtWordBoundaries(on));
        regexToggle = option(".*", "Regular expression", (bool on) => settings.setRegexEnabled(on));
        replaceToggle = new ToggleButton;
        replaceToggle.setIconName("edit-find-replace-symbolic");
        replaceToggle.setTooltipText("Replace (Ctrl+H)");
        replaceToggle.addCssClass("flat");
        replaceToggle.connectToggled(() => replaceRow.setVisible(replaceToggle.getActive()));

        auto findRow = new Box(Orientation.Horizontal, 4);
        findRow.append(findEntry);
        findRow.append(count);
        findRow.append(iconButton("go-up-symbolic", "Previous (Shift+F3)", () => previous()));
        findRow.append(iconButton("go-down-symbolic", "Next (F3, Enter)", () => next()));
        auto options = new Box(Orientation.Horizontal, 0);
        options.addCssClass("linked");
        options.append(caseToggle);
        options.append(wordToggle);
        options.append(regexToggle);
        findRow.append(options);
        findRow.append(replaceToggle);
        findRow.append(iconButton("window-close-symbolic", "Close (Esc)", () => close()));

        replaceEntry = new Entry;
        replaceEntry.setHexpand(true);
        replaceEntry.setPlaceholderText("Replace with");
        replaceEntry.connectActivate(() => replaceOne());
        auto one = new Button;
        one.setLabel("Replace");
        one.connectClicked(() => replaceOne());
        auto all = new Button;
        all.setLabel("Replace all");
        all.connectClicked(() => replaceEvery());
        replaceRow = new Box(Orientation.Horizontal, 4);
        replaceRow.append(replaceEntry);
        replaceRow.append(one);
        replaceRow.append(all);
        replaceRow.setVisible(false);

        auto rows = new Box(Orientation.Vertical, 4);
        rows.addCssClass("hcad-findbar");
        rows.append(findRow);
        rows.append(replaceRow);
        // narrower than its row when the code is (a narrow window): clipped, and scrolled sideways
        auto clip = new ScrolledWindow;
        clip.setPolicy(PolicyType.External, PolicyType.Never);
        clip.setPropagateNaturalWidth(true);
        clip.setPropagateNaturalHeight(true);
        clip.setChild(rows);
        bar = new Revealer;
        bar.setChild(clip);
        bar.setRevealChild(false);
    }

    void buildGoTo()
    {
        goToEntry = new Entry;
        goToEntry.setWidthChars(18);
        goToEntry.connectActivate(() {
            try
                showLine(goToEntry.getText().strip.to!int);
            catch (Exception)
            {
            }
            goToPopover.popdown();
            editor.grabFocus();
        });
        goToPopover = new Popover;
        goToPopover.setChild(goToEntry);
        goToPopover.setPosition(PositionType.Bottom);
        goToPopover.setParent(editor);
    }

    static ToggleButton option(string label, string tooltip, void delegate(bool) changed)
    {
        auto t = new ToggleButton;
        t.setLabel(label);
        t.setTooltipText(tooltip);
        t.connectToggled(() => changed(t.getActive()));
        return t;
    }

    static Button iconButton(string icon, string tooltip, void delegate() clicked)
    {
        auto b = new Button;
        b.setIconName(icon);
        b.setTooltipText(tooltip);
        b.addCssClass("flat");
        b.connectClicked(clicked);
        return b;
    }

    bool hasText() => bar.getRevealChild() && findEntry.getText().length > 0;

    void open(bool withReplace)
    {
        TextIter s, e;
        if (buffer.getSelectionBounds(s, e))
        {
            auto picked = buffer.getText(s, e, true);
            if (!picked.canFind('\n'))
                findEntry.setText(picked);
        }
        if (withReplace)
            replaceToggle.setActive(true);
        bar.setRevealChild(true);
        search.setHighlight(true);
        findEntry.grabFocus();
        findEntry.selectRegion(0, -1);
        updateCount();
    }

    void select(TextIter from, TextIter to)
    {
        buffer.selectRange(from, to);
        editor.scrollToMark(buffer.getInsert(), 0.2, false, 0, 0);
    }

    /// "3 of 12" (the selection is the third match), "12 found", "no match",
    /// or what is wrong with the regular expression.
    void updateCount()
    {
        if (count is null)
            return;
        if (auto e = search.getRegexError())
        {
            count.setText("bad pattern");
            count.setTooltipText(e.message);
            return;
        }
        count.setTooltipText(null);
        immutable n = search.getOccurrencesCount();
        if (findEntry.getText().length == 0 || n < 0)
            return count.setText("");
        if (n == 0)
            return count.setText("no match");
        TextIter s, e;
        buffer.getSelectionBounds(s, e);
        immutable at = search.getOccurrencePosition(s, e);
        count.setText(at > 0 ? format("%d of %d", at, n) : format("%d found", n));
    }

    /// Replace: the selected match replaced, then the next one selected.
    void replaceOne()
    {
        TextIter s, e;
        buffer.getSelectionBounds(s, e);
        if (search.getOccurrencePosition(s, e) > 0)
            try
                search.replace(s, e, replaceEntry.getText());
            catch (Exception)
            {
            }
        next();
    }

    void replaceEvery()
    {
        uint n;
        try
            n = search.replaceAll(replaceEntry.getText());
        catch (Exception)
        {
        }
        count.setText(format("%d replaced", n));
    }

    bool onKey(uint key, ModifierType state)
    {
        immutable ctrl = (state & primaryMask) != 0, shift = (state & ModifierType.ShiftMask) != 0,
            alt = (state & ModifierType.AltMask) != 0;
        if (alt && !ctrl && (key == KEY_Up || key == KEY_Down))
            return lineAction(key == KEY_Up ? LineAction.up : LineAction.down) || true;
        if (ctrl && !shift && key == KEY_slash)
            return lineAction(LineAction.comment) || true;
        if (ctrl && !shift && key == KEY_d)
            return lineAction(LineAction.duplicate) || true;
        if (ctrl && shift && (key == KEY_k || key == KEY_K))
            return lineAction(LineAction.remove) || true;
        if (key == KEY_Escape && bar.getRevealChild())
        {
            close();
            return true;
        }
        if (ctrl || alt)
            return false;
        if (key == KEY_BackSpace)
            return removePair();
        return typePaired(cast(dchar) imported!"gdk.global".keyvalToUnicode(key));
    }

    // ------------------------------------------------------------ brackets and quotes

    /// The closing bracket or quote of an opening one, or 0.
    static dchar closing(dchar c)
    {
        switch (c)
        {
        case '(': return ')';
        case '[': return ']';
        case '{': return '}';
        case '"': return '"';
        default: return 0;
        }
    }

    /// An opening bracket or quote typed: its closing one too, the cursor
    /// between them (round the selection, if any); a closing one typed in
    /// front of the same: the cursor steps over it.
    bool typePaired(dchar c)
    {
        TextIter s, e;
        immutable selected = buffer.getSelectionBounds(s, e);
        auto after = e.copy();
        auto nextChar = after.getChar();
        if (!selected && (c == ')' || c == ']' || c == '}' || c == '"') && nextChar == c)
        {
            // step over the closing one typed earlier
            after.forwardChar();
            buffer.placeCursor(after);
            return true;
        }
        immutable close = closing(c);
        if (close == 0)
            return false;
        if (selected)
        {
            auto inside = buffer.getText(s, e, true);
            buffer.beginUserAction();
            buffer.delete_(s, e);
            buffer.insert(s, c.to!string ~ inside ~ close.to!string);
            buffer.endUserAction();
            return true;
        }
        // only before a space, the end of a line or a closing bracket, and a
        // quote not right after a letter or digit (an apostrophe, a string being closed)
        if (!(nextChar == 0 || nextChar == ' ' || nextChar == '\n' || nextChar == '\t' || nextChar == ')'
                || nextChar == ']' || nextChar == '}' || nextChar == ';' || nextChar == ','))
            return false;
        if (c == '"')
        {
            auto before = s.copy();
            if (before.backwardChar())
            {
                immutable p = before.getChar();
                if ((p >= 'a' && p <= 'z') || (p >= 'A' && p <= 'Z') || (p >= '0' && p <= '9') || p == '"')
                    return false;
            }
        }
        buffer.beginUserAction();
        buffer.insertAtCursor(c.to!string ~ close.to!string);
        buffer.endUserAction();
        TextIter at;
        buffer.getIterAtMark(at, buffer.getInsert());
        at.backwardChar();
        buffer.placeCursor(at);
        return true;
    }

    /// Backspace between a pair just typed, "(|)": both go.
    bool removePair()
    {
        TextIter s, e;
        if (buffer.getSelectionBounds(s, e))
            return false;
        auto before = s.copy();
        if (!before.backwardChar())
            return false;
        immutable close = closing(before.getChar());
        if (close == 0 || s.getChar() != close)
            return false;
        auto after = s.copy();
        after.forwardChar();
        buffer.beginUserAction();
        buffer.delete_(before, after);
        buffer.endUserAction();
        return true;
    }

    // ------------------------------------------------------------ line actions

    /// The lines the selection covers (from 0); a selection ending at the
    /// start of a line leaves that line out.
    void selectedLines(out int a, out int b)
    {
        TextIter s, e;
        buffer.getSelectionBounds(s, e);
        a = s.getLine();
        b = e.getLine();
        if (b > a && e.getLineOffset() == 0)
            b--;
    }

    /// The text of lines a to b (from 0), without the last line break.
    string linesText(int a, int b)
    {
        TextIter s, e;
        rangeOf(a, b, s, e);
        return buffer.getText(s, e, true);
    }

    /// From the start of line a to the end of line b, its break left out.
    void rangeOf(int a, int b, out TextIter s, out TextIter e)
    {
        buffer.getIterAtLine(s, a);
        buffer.getIterAtLine(e, b);
        if (!e.endsLine())
            e.forwardToLineEnd();
    }

    /// Lines a to b replaced by `text`, as one step of Undo, then selected
    /// from line `selA` to line `selB`.
    void replaceLines(int a, int b, string text, int selA, int selB)
    {
        TextIter s, e;
        rangeOf(a, b, s, e);
        buffer.beginUserAction();
        buffer.delete_(s, e);
        buffer.insert(s, text);
        buffer.endUserAction();
        TextIter x, y;
        buffer.getIterAtLine(x, selA);
        buffer.getIterAtLine(y, selB);
        if (!y.endsLine())
            y.forwardToLineEnd();
        buffer.selectRange(y, x);
        editor.scrollToMark(buffer.getInsert(), 0.1, false, 0, 0);
    }

    /// Ctrl+/: "// " in front of the lines at their least indent, or taken
    /// away when every line that is not blank has it.
    bool comment(int a, int b)
    {
        auto lines = linesText(a, b).split("\n");
        bool all = true;
        size_t indent = size_t.max;
        foreach (l; lines)
            if (l.strip.length)
            {
                all = all && l.stripLeft.length >= 2 && l.stripLeft[0 .. 2] == "//";
                indent = min(indent, l.length - l.stripLeft.length);
            }
        if (indent == size_t.max)
            return false;
        foreach (ref l; lines)
        {
            if (!l.strip.length)
                continue;
            if (all)
            {
                immutable at = l.length - l.stripLeft.length;
                immutable cut = l.length > at + 2 && l[at + 2] == ' ' ? 3 : 2;
                l = l[0 .. at] ~ l[at + cut .. $];
            }
            else
                l = l[0 .. indent] ~ "// " ~ l[indent .. $];
        }
        replaceLines(a, b, lines.join("\n"), a, b);
        return true;
    }

    /// Ctrl+D: the selection repeated after itself, or with none (or lines
    /// asked for by number) the lines repeated under them.
    bool duplicate(int a, int b, bool byNumber)
    {
        TextIter s, e;
        if (!byNumber && buffer.getSelectionBounds(s, e) && s.getLine() == e.getLine())
        {
            auto text = buffer.getText(s, e, true);
            buffer.beginUserAction();
            buffer.insert(e, text);
            buffer.endUserAction();
            return true;
        }
        auto text = linesText(a, b);
        replaceLines(a, b, text ~ "\n" ~ text, b + 1, b + 1 + (b - a));
        return true;
    }

    /// Ctrl+Shift+K: the lines gone, line breaks and all.
    bool remove(int a, int b)
    {
        TextIter s, e;
        buffer.getIterAtLine(s, a);
        if (b + 1 < buffer.getLineCount())
            buffer.getIterAtLine(e, b + 1);
        else
        {
            buffer.getEndIter(e);
            // the last line: the break before it goes instead
            if (a > 0)
            {
                s.backwardChar();
            }
        }
        buffer.beginUserAction();
        buffer.delete_(s, e);
        buffer.endUserAction();
        return true;
    }

    /// Alt+Up, Alt+Down: the lines swapped with the one above or below.
    bool move(int a, int b, int by)
    {
        if ((by < 0 && a == 0) || (by > 0 && b + 1 >= buffer.getLineCount()))
            return false;
        auto block = linesText(a, b);
        if (by < 0)
        {
            auto above = linesText(a - 1, a - 1);
            replaceLines(a - 1, b, block ~ "\n" ~ above, a - 1, b - 1);
        }
        else
        {
            auto below = linesText(b + 1, b + 1);
            replaceLines(a, b + 1, below ~ "\n" ~ block, a + 1, b + 1);
        }
        return true;
    }

    /// The lines four spaces in, or out (as far as they have spaces).
    bool indent(int a, int b, bool inwards)
    {
        auto lines = linesText(a, b).split("\n");
        foreach (ref l; lines)
        {
            if (inwards)
                l = l.strip.length ? "    " ~ l : l;
            else
            {
                size_t n;
                while (n < 4 && n < l.length && l[n] == ' ')
                    n++;
                l = l[n .. $];
            }
        }
        replaceLines(a, b, lines.join("\n"), a, b);
        return true;
    }
}

/// A match of find(): where it is (from 1) and what it is.
struct FoundText
{
    int line, column;
    string text;
}
