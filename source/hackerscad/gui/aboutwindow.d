/// The About window: Carlo, the name, the version and what hackerscad is;
/// a list below to open the website or report a problem, see the credits
/// and licences (a page of their own, inside the window) and copy the
/// debug information. A window of its own, light to draw: libadwaita's
/// about dialog built every page at once, over the main window, and where
/// text is slow to draw (Wine) it froze both.
module hackerscad.gui.aboutwindow;

import std.array : join;
import std.format : format;

import adw.action_row : ActionRow;
import adw.header_bar : HeaderBar;
import adw.navigation_page : NavigationPage;
import adw.navigation_view : NavigationView;
import adw.toolbar_view : ToolbarView;
import adw.window : AdwWindow = Window;
import gobject.value : Value;
import gtk.box : Box;
import gtk.image : Image;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.scrolled_window : ScrolledWindow;
import gtk.types : Align, Orientation, PolicyType, SelectionMode;
import gtk.widget : Widget;
import gtk.window : Window;

import hackerscad.about;

final class AboutWindow
{
    AdwWindow window;
    /// Called when it closes.
    void delegate() onClosed;
    /// Opens a web address (the window's own way, so that it works everywhere).
    void delegate(string uri) openUri;

    /// `debugInfo`: what draws the view and how fast, to copy into a report.
    this(Window parent, string debugInfo)
    {
        window = new AdwWindow;
        window.setTitle("About " ~ appName);
        window.setDefaultSize(460, 470);
        window.setTransientFor(parent);
        window.connectCloseRequest(() {
            if (onClosed !is null)
                onClosed();
            return false;
        });

        auto pages = new NavigationView;
        credits = new NavigationPage(withBar(creditsPage()), "Credits and licences");
        pages.add(new NavigationPage(withBar(mainPage(pages, debugInfo)), "About " ~ appName));
        window.setContent(pages);
    }

    void present() => window.present();

    void close() => window.close();

private:

    NavigationPage credits;

    /// The logo and name at the top, what hackerscad is, then the list.
    Widget mainPage(NavigationView pages, string debugInfo)
    {
        auto page = new Box(Orientation.Vertical, 14);
        page.setMarginStart(18);
        page.setMarginEnd(18);
        page.setMarginTop(6);
        page.setMarginBottom(18);

        auto head = new Box(Orientation.Horizontal, 14);
        auto logo = Image.newFromIconName("it.andreafontana.hackerscad.gui");
        logo.setPixelSize(72);
        logo.setTooltipText("Carlo, hackerscad's mascot: a bag clip with a crocodile's grin");
        head.append(logo);
        auto titles = new Box(Orientation.Vertical, 2);
        titles.setValign(Align.Center);
        auto name = new Label(appName);
        name.addCssClass("title-2");
        name.setXalign(0);
        titles.append(name);
        auto ver = new Label("Version " ~ appVersion);
        ver.setXalign(0);
        titles.append(ver);
        auto by = new Label(appCopyright);
        by.addCssClass("dim-label");
        by.setXalign(0);
        titles.append(by);
        head.append(titles);
        page.append(head);

        auto about = new Label("The hacker's CAD: solid models written as code in a small language, edited "
            ~ "with the mouse too, driven by AI agents through MCP.");
        about.setWrap(true);
        about.setXalign(0);
        page.append(about);

        auto list = new ListBox;
        list.setSelectionMode(SelectionMode.None);
        list.addCssClass("boxed-list");
        list.append(row("Website", appWebsite, "hcad-external-link-symbolic", () => open(appWebsite)));
        list.append(row("Report a problem", appIssues, "hcad-external-link-symbolic", () => open(appIssues)));
        {
            // where the log and the crash reports are, to attach to a problem report
            import hackerscad.gui.crashlog : logDir;
            import std.file : mkdirRecurse;
            immutable dir = logDir();
            ActionRow logs;
            logs = row("Logs and crash reports", dir, "hcad-folder-symbolic", () {
                try
                    mkdirRecurse(dir);
                catch (Exception)
                {
                }
                // the reason in the row when it cannot open
                openFolder(window, dir, (string why) => logs.setSubtitle(dir ~ " (cannot open it: " ~ why ~ ")"));
            });
            list.append(logs);
        }
        list.append(row("Credits and licences", "the libraries hackerscad is built with", "hcad-next-symbolic",
            () => pages.push(credits)));
        ActionRow copy;
        copy = row("Copy debug information", "what draws the 3D view and how fast, for a problem report",
            "hcad-copy-symbolic", () {
                window.getClipboard().set(new Value(debugInfo));
                copy.setSubtitle("Copied: paste it into the report");
            });
        list.append(copy);
        page.append(list);
        return page;
    }

    /// The credits and licences, scrolling inside the window.
    Widget creditsPage()
    {
        auto text = new Label(creditsText());
        text.setWrap(true);
        text.setSelectable(true);
        text.setXalign(0);
        text.setYalign(0);
        text.setMarginStart(18);
        text.setMarginEnd(18);
        text.setMarginTop(6);
        text.setMarginBottom(18);
        auto s = new ScrolledWindow;
        s.setPolicy(PolicyType.Never, PolicyType.Automatic);
        s.setVexpand(true);
        s.setChild(text);
        return s;
    }

    static Widget withBar(Widget content)
    {
        auto t = new ToolbarView;
        t.addTopBar(new HeaderBar);
        t.setContent(content);
        return t;
    }

    static ActionRow row(string title, string subtitle, string icon, void delegate() activated)
    {
        auto r = new ActionRow;
        r.setTitle(title);
        r.setSubtitle(subtitle);
        r.addSuffix(Image.newFromIconName(icon));
        r.setActivatable(true);
        r.connectActivated(activated);
        return r;
    }

    /// Opens a folder in the file manager (a file:// URI through the URI launcher is refused by the desktop
    /// portal on Linux); `failed` gets the reason when it cannot
    public static void openFolder(Window parent, string dir, void delegate(string why) failed)
    {
        import gio.async_result : AsyncResult;
        import gio.file : File;
        import glib.error : ErrorWrap;
        import gobject.object : ObjectWrap;
        import gtk.file_launcher : FileLauncher;
        auto launcher = new FileLauncher(File.newForPath(dir));
        launcher.launch(parent, null, (ObjectWrap source, AsyncResult result) {
            try
                launcher.launchFinish(result);
            catch (ErrorWrap e)
                failed(e.msg);
        });
    }

    void open(string uri)
    {
        if (openUri !is null)
            openUri(uri);
    }

    /// The libraries hackerscad is built with and their licences, what
    /// inspired it, and its own licence.
    static string creditsText()
    {
        string[] lines = [format("%s, %s. Licence: %s.", appName, appCopyright, appLicense), "", appModelException, "",
            "Built with:"];
        foreach (c; components)
            lines ~= format("• %s: %s. %s, %s. %s", c.name, c.what, c.copyright, c.license, c.url);
        lines ~= ["", "Inspired by OpenSCAD (https://openscad.org) and Onshape (https://www.onshape.com)."];
        return lines.join("\n");
    }
}
