/// hackerscad desktop application: editor, live 3D view, parameters and
/// console. The model is re-evaluated in the background as you type.
module hackerscad.gui.app;

import std.file : exists, readText, write, thisExePath;
import core.time : MonoTime;
import std.path : baseName, dirName, buildPath, extension, absolutePath, buildNormalizedPath;
import std.format : format;
import std.string : toLower, toUpper;
import std.array : join;
import std.algorithm : endsWith;
import std.math : abs;
import std.algorithm : min, max, canFind;

import adw.application : AdwApplication = Application;
import adw.application_window : ApplicationWindow;
import adw.header_bar : HeaderBar;
import adw.toolbar_view : ToolbarView;
import adw.window_title : WindowTitle;
import adw.overlay_split_view : OverlaySplitView;
import gtk.toggle_button : ToggleButton;
import gio.types : ApplicationFlags;
import gio.simple_action : SimpleAction;
import gio.file : File;
import gio.async_result : AsyncResult;
import gobject.object : ObjectWrap;
import glib.global : timeoutAdd;
import glib.source : Source;
import glib.types : PRIORITY_DEFAULT;
import glib.error : ErrorWrap;
import gtk.box : Box;
import gtk.button : Button;
import gtk.label : Label;
import gtk.widget : Widget;
import gtk.paned : Paned;
import gtk.scrolled_window : ScrolledWindow;
import gtk.text_view : TextView;
import gtk.text_iter : TextIter;
import gtk.text_tag : TextTag;
import gtk.file_dialog : FileDialog;
import gtk.types : Orientation, Align, WrapMode, PackType, Justification;
import gtksource.view : SourceView = View;
import gtksource.buffer : SourceBuffer = Buffer;
import gtksource.language_manager : LanguageManager;
import gtksource.style_scheme_manager : StyleSchemeManager;
import pango.types : Underline, EllipsizeMode;
import adw.view_stack : ViewStack;
import adw.view_switcher : ViewSwitcher;
import adw.types : ViewSwitcherPolicy;
import gtk.overlay : Overlay;
import gtk.popover : Popover;
import gtk.entry : Entry;
import gdk.rectangle : Rectangle;
import gtk.drop_down : DropDown;
import gtk.scale : Scale;
import hackerscad.geom.vec : Vec3;
import glib.global : idleAdd;

import hackerscad.geom.mesh;
import hackerscad.kernel.brep : BoolOp, EdgeKind;
import hackerscad.lang.errors;
import hackerscad.io.stl;
import hackerscad.io.threemf;
import hackerscad.render.raster;
import hackerscad.render.png;
import hackerscad.gui.evaluator;
import hackerscad.gui.viewport;
import hackerscad.gui.params;
import hackerscad.gui.control;
import hackerscad.gui.features;
import hackerscad.gui.menu;
import hackerscad.gui.measure : Item;
import hackerscad.tool.codegen;
import hackerscad.about;
import hackerscad.gui.completion;
import hackerscad.gui.cheatsheet;
import hackerscad.lang.interp : Interp;
import hackerscad.lang.value : SolidVal;
import hackerscad.lang.sketchval : SketchView;
import hackerscad.tool.guiclient : toOverrides;
import std.json;

/// What a new file starts with: a small model that shows the main ideas.
enum newModelTemplate = import("bagclip.hcad");

/// Linux: the shell (GNOME, KDE on Wayland) shows the icon of a window only
/// through the desktop entry named like the application id. When no package
/// installed one, write it in ~/.local/share, pointing at this executable or
/// AppImage; kept up to date when the AppImage moves, never touching an entry
/// someone else wrote.
version (linux) void installDesktopEntry()
{
    import std.algorithm : canFind;
    import std.array : split;
    import std.file : mkdirRecurse, copy, readText, write, exists;
    import std.path : buildPath;
    import std.process : environment;

    enum id = "it.andreafontana.hackerscad.gui";
    enum marker = "X-Hackerscad-Generated=true";
    auto home = environment.get("HOME");
    if (home is null)
        return;
    auto dataHome = environment.get("XDG_DATA_HOME", buildPath(home, ".local", "share"));
    foreach (dir; environment.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":"))
        if (dir.length && exists(buildPath(dir, "applications", id ~ ".desktop")))
            return;   // installed by a package
    try
    {
        auto exe = environment.get("APPIMAGE", thisExePath);
        auto entry = buildPath(dataHome, "applications", id ~ ".desktop");
        auto text = "[Desktop Entry]\nType=Application\nName=hackerscad\nGenericName=Parametric CAD\n"
            ~ "Comment=Solid models written as code, edited with the mouse too\n"
            ~ "Exec=\"" ~ exe ~ "\" %f\nIcon=" ~ id ~ "\nTerminal=false\nStartupWMClass=" ~ id ~ "\n"
            ~ "Categories=Graphics;3DGraphics;Engineering;\nMimeType=text/x-hcad;\n" ~ marker ~ "\n";
        if (exists(entry) && !readText(entry).canFind(marker))
            return;   // someone else's
        if (!exists(entry) || readText(entry) != text)
        {
            mkdirRecurse(buildPath(dataHome, "applications"));
            write(entry, text);
        }
        auto icon = buildPath(dataHome, "icons", "hicolor", "scalable", "apps", id ~ ".svg");
        auto ours = buildPath(MainWindow.dataDir("icons"), "hicolor", "scalable", "apps", id ~ ".svg");
        if (exists(ours) && (!exists(icon) || readText(icon) != readText(ours)))
        {
            mkdirRecurse(buildPath(dataHome, "icons", "hicolor", "scalable", "apps"));
            copy(ours, icon);
            // an icon cache in the theme folder (other programs make one) is
            // trusted while the folder is older than it: touch the folder, or
            // the shell keeps showing the generic icon
            import std.datetime.systime : Clock;
            import std.file : setTimes;
            auto now = Clock.currTime;
            setTimes(buildPath(dataHome, "icons", "hicolor"), now, now);
        }
    }
    catch (Exception)
    {
        // a read-only home: the window just has no icon in the shell
    }
}

version (Windows)
    extern (C) private int _putenv_s(const(char)* name, const(char)* value) nothrow @nogc;

version (Windows)
{
    /// HCAD_GL=software (set by relaunchWithMesa when the machine's OpenGL is
    /// too old for GTK, as in many virtual machines): use Mesa's software
    /// OpenGL from bin\mesa. GTK loads opengl32.dll as soon as gid loads GTK,
    /// before main, so the folder is chosen here, when the C runtime starts.
    pragma(crt_constructor)
    extern (C) private void hcadSoftwareGl() nothrow @nogc
    {
        import core.sys.windows.windows : GetEnvironmentVariableW, GetModuleFileNameW, MAX_PATH,
            SetDllDirectoryW, SetEnvironmentVariableW;
        wchar[16] v;
        if (GetEnvironmentVariableW("HCAD_GL"w.ptr, v.ptr, cast(uint) v.length) != 8 || v[0 .. 8] != "software"w)
            return;
        wchar[MAX_PATH + 8] dir;
        auto n = GetModuleFileNameW(null, dir.ptr, MAX_PATH);
        while (n > 0 && dir[n - 1] != '\\')
            n--;
        dir[n .. n + 5] = "mesa\0"w;
        SetDllDirectoryW(dir.ptr);
        // Mesa's default on Windows (D3D12 on top of WARP) does not draw
        SetEnvironmentVariableW("GALLIUM_DRIVER"w.ptr, "llvmpipe"w.ptr);
        _putenv_s("GALLIUM_DRIVER", "llvmpipe");
    }
}

version (Windows)
{
    /// Whether the system's OpenGL can run GTK: version 3.2 at least, and not
    /// Windows' own software one ("GDI Generic"). opengl32.dll is loaded here
    /// by hand: linked to the program, Windows would load the system's before
    /// hcadSoftwareGl could choose Mesa's.
    private bool hardwareGl()
    {
        import core.sys.windows.windows;
        import std.algorithm : canFind;
        import std.array : split;
        import std.conv : to;
        import std.string : fromStringz;
        enum uint GL_RENDERER = 0x1F01, GL_VERSION = 0x1F02;
        auto lib = LoadLibraryW("opengl32.dll"w.ptr);
        if (lib is null)
            return false;
        alias Create = extern (Windows) HGLRC function(HDC) nothrow @nogc;
        alias MakeCurrent = extern (Windows) BOOL function(HDC, HGLRC) nothrow @nogc;
        alias Delete = extern (Windows) BOOL function(HGLRC) nothrow @nogc;
        alias GetString = extern (Windows) const(char)* function(uint) nothrow @nogc;
        auto create = cast(Create) GetProcAddress(lib, "wglCreateContext");
        auto makeCurrent = cast(MakeCurrent) GetProcAddress(lib, "wglMakeCurrent");
        auto remove = cast(Delete) GetProcAddress(lib, "wglDeleteContext");
        auto getString = cast(GetString) GetProcAddress(lib, "glGetString");
        if (!create || !makeCurrent || !remove || !getString)
            return false;
        bool ok;
        auto w = CreateWindowExW(0, "STATIC"w.ptr, ""w.ptr, WS_POPUP, 0, 0, 1, 1, null, null, null, null);
        auto dc = w ? GetDC(w) : null;
        if (dc)
        {
            PIXELFORMATDESCRIPTOR pfd;
            pfd.nSize = pfd.sizeof;
            pfd.nVersion = 1;
            pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
            pfd.iPixelType = PFD_TYPE_RGBA;
            pfd.cColorBits = 32;
            immutable format = ChoosePixelFormat(dc, &pfd);
            auto gl = format && SetPixelFormat(dc, format, &pfd) ? create(dc) : null;
            if (gl && makeCurrent(dc, gl))
            {
                // "4.6.0 NVIDIA 555.85": major and minor come first
                try
                {
                    auto v = getString(GL_VERSION).fromStringz.split(" ")[0].split(".");
                    immutable major = v[0].to!int, minor = v.length > 1 ? v[1].to!int : 0;
                    ok = (major > 3 || (major == 3 && minor >= 2))
                        && !getString(GL_RENDERER).fromStringz.canFind("GDI Generic");
                }
                catch (Exception)
                {
                }
                makeCurrent(null, null);
            }
            if (gl)
                remove(gl);
            ReleaseDC(w, dc);
        }
        if (w)
            DestroyWindow(w);
        return ok;
    }

    /// When the machine's OpenGL is too old for GTK, starts the program again
    /// with Mesa's (HCAD_GL=software) and says so: the new process loads it
    /// from the start, this one already holds the system's. Without Mesa
    /// (a separate download), the 3D view explains what to do.
    private bool relaunchWithMesa(string[] args)
    {
        import std.file : exists, thisExePath;
        import std.path : buildPath, dirName;
        import std.process : environment, spawnProcess;
        import hackerscad.about : appVersion;
        import hackerscad.gui.viewport : Viewport;
        // the help is ready whenever Mesa is missing: shown only if OpenGL fails
        immutable hasMesa = exists(buildPath(dirName(thisExePath), "mesa", "opengl32.dll"));
        if (!hasMesa)
            Viewport.glHelp = "This computer's OpenGL is too old for the 3D view: it happens in virtual "
                ~ "machines without 3D acceleration, and without a graphics driver.\n\n"
                ~ "Download hackerscad-" ~ appVersion ~ "-windows-mesa.zip from the page of hackerscad's "
                ~ "releases and unzip it into the folder that holds hackerscad.exe, then start hackerscad "
                ~ "again: it draws with a software OpenGL.\n\n"
                ~ "Or install the graphics driver, or turn on 3D acceleration in the virtual machine.";
        if (environment.get("HCAD_GL") !is null || !hasMesa || hardwareGl())
            return false;
        auto env = environment.toAA();
        env["HCAD_GL"] = "software";
        try
        {
            spawnProcess([thisExePath] ~ args[1 .. $], env);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
}

int main(string[] args)
{
    version (Windows)
    {
        if (relaunchWithMesa(args))
            return 0;
        // a windowed program has no console: started from a terminal it
        // writes there, otherwise its messages go nowhere instead of failing
        {
            import core.sys.windows.wincon : AttachConsole, ATTACH_PARENT_PROCESS;
            import std.stdio : stdout, stderr;
            if (AttachConsole(ATTACH_PARENT_PROCESS))
            {
                stdout.reopen("CONOUT$", "w");
                stderr.reopen("CONOUT$", "w");
            }
            else
            {
                stdout.reopen("NUL", "w");
                stderr.reopen("NUL", "w");
            }
        }
        // under Wine, Pango's DirectWrite backend draws the wrong glyphs:
        // use fontconfig (the Windows build is tested with Wine on Linux)
        import core.sys.windows.windows : GetModuleHandleA, GetProcAddress;
        import std.process : environment;
        auto ntdll = GetModuleHandleA("ntdll.dll");
        if (ntdll !is null && GetProcAddress(ntdll, "wine_get_version") !is null
            && environment.get("PANGOCAIRO_BACKEND") is null)
        {
            // Pango reads it with the C runtime's getenv, which keeps its own copy
            _putenv_s("PANGOCAIRO_BACKEND", "fc");
        }
        // GLib follows XDG_DATA_DIRS when set (MSYS2 and other tools export
        // theirs): our share/ goes first, for the icons, the GtkSourceView
        // files and the settings schemas
        import std.file : thisExePath;
        import std.path : buildPath, dirName;
        import std.string : toStringz;
        auto share = buildPath(dirName(dirName(thisExePath())), "share");
        auto dirs = environment.get("XDG_DATA_DIRS");
        _putenv_s("XDG_DATA_DIRS", toStringz(dirs.length ? share ~ ";" ~ dirs : share));
        _putenv_s("GSETTINGS_SCHEMA_DIR", toStringz(buildPath(share, "glib-2.0", "schemas")));
    }
    version (linux)
        installDesktopEntry();
    // --screenshot=FILE.png saves the window after the first evaluation and quits
    string path, shot;
    foreach (a; args[1 .. $])
    {
        if (a.length > 13 && a[0 .. 13] == "--screenshot=")
            shot = a[13 .. $];
        else
            path = absolutePath(a);
    }
    if (path is null)
        path = absolutePath("untitled.hcad");
    auto app = new AdwApplication("it.andreafontana.hackerscad.gui", ApplicationFlags.NonUnique);
    app.connectActivate(() {
        auto w = new MainWindow(app, path);
        w.screenshotPath = shot;
    });
    return app.run(args[0 .. 1]);
}

struct ExportFormat
{
    string ext, label, what;
}

final class MainWindow
{
    ApplicationWindow window;
    SourceBuffer buffer;
    EditorCompletion completion;
    CheatsheetWindow cheatsheet;
    SourceView editor;
    TextView console;
    Label consoleHint;
    Viewport viewport;
    ParamsPanel params;
    WindowTitle title;
    import gtk.spinner : Spinner;
    Spinner busyIndicator;
    string statusText;   /// the latest program message (for the control socket)
    ToggleButton paramsToggle, consoleToggle, rotateMode, panMode, sketchToggle, sectionToggle;
    Box sectionBar, viewBar;
    DropDown sectionPlane;
    Scale sectionSlider;
    Label sectionLabel;
    Vec3 sectionNormal = Vec3(0, 0, 1);
    bool sectionFlipped, sectionUpdating;
    ToggleButton sectionFlip;
    double sectionFace = 0;   /// position of the selected face along its normal
    FeaturesPanel features;
    Overlay overlay;
    Button[] dimButtons;
    SketchView.Dimension[] dims;
    bool positionQueued;
    Evaluator evaluator;
    ControlServer control;
    Button windowName;   /// the name agents use for this window
    Label windowNameLabel;

    string path;
    bool modified;
    uint debounce;
    bool firstResult = true;
    Outcome last;
    string screenshotPath;

    this(AdwApplication app, string path)
    {
        this.path = path;
        window = new ApplicationWindow(app);
        window.setDefaultSize(1440, 880);

        // ---- header bar
        auto header = new HeaderBar;
        title = new WindowTitle(baseName(path), dirName(path));
        header.setTitleWidget(title);
        header.packStart(button("document-open-symbolic", "Open (Ctrl+O)", &openFile));
        header.packStart(button("document-save-symbolic", "Save (Ctrl+S)", &save));
        header.packStart(exportMenu());
        busyIndicator = new Spinner;
        busyIndicator.setTooltipText("Evaluating the model");
        busyIndicator.setVisible(false);
        consoleToggle = toggle("utilities-terminal-symbolic", "Show console (Ctrl+J)", true);
        paramsToggle = toggle("sidebar-show-right-symbolic", "Show parameters (F9)", true);
        header.packEnd(mainMenu());
        header.packEnd(paramsToggle);
        header.packEnd(consoleToggle);
        header.packEnd(busyIndicator);
        windowName = new Button;
        windowName.addCssClass("flat");
        {
            import gtk.image : Image;
            auto content = new Box(Orientation.Horizontal, 6);
            content.append(Image.newFromIconName("hcad-agent-symbolic"));
            windowNameLabel = new Label("");
            content.append(windowNameLabel);
            windowName.setChild(content);
        }
        windowName.setVisible(false);
        windowName.connectClicked(&renameWindow);
        header.packEnd(windowName);

        // ---- toolbar above the 3D view: views, navigation, section, sketches
        viewBar = new Box(Orientation.Horizontal, 6);
        viewBar.addCssClass("hcad-viewbar");
        sketchToggle = toggle("document-edit-symbolic",
            "Show the sketches and their dimensions: blue points can still move, click a dimension to change it", false);
        sketchToggle.connectToggled(() {
            viewport.setSketchMode(sketchToggle.getActive());
            if (sketchToggle.getActive() && last.sketches.length)
                viewport.setView(ViewPreset.top);
            updateDimensions();
        });
        sketchToggle.setVisible(false);
        sectionToggle = toggle("hcad-section-symbolic", "Section view: cut the model with a plane you can slide", false);
        sectionToggle.connectToggled(() {
            sectionBar.setVisible(sectionToggle.getActive());
            updateSection(true);
        });
        // left-drag mode: rotate or pan (right drag always rotates, middle pans)
        import gtk.icon_theme : IconTheme;
        import gdk.display : Display;
        IconTheme.getForDisplay(Display.getDefault()).addSearchPath(dataDir("icons"));
        version (OSX)
        {
            // laid out by fontconfig (see the bundle's launcher), the system
            // font is asked for by a name only CoreText knows: name a Mac font
            import std.process : environment;
            import gtk.settings : Settings;
            if (environment.get("PANGOCAIRO_BACKEND") == "fc")
                Settings.getDefault().gtkFontName = "Helvetica Neue 13";
        }
        {
            // the logo, for the taskbar and the window switcher
            import gtk.window : Window;
            Window.setDefaultIconName("it.andreafontana.hackerscad.gui");
        }
        {
            import gtk.css_provider : CssProvider;
            import gtk.style_context : StyleContext;
            auto css = new CssProvider;
            css.loadFromString("button.hcad-dimension { padding: 1px 5px; min-height: 0; min-width: 0; font-size: 0.85em;"
                ~ " border-radius: 4px; }"
                ~ " .hcad-progress { padding: 10px 10px 10px 16px; }"
                ~ " .hcad-gl-help { padding: 18px 22px; margin: 24px; }"
                ~ " popover.hcad-completion > contents { padding: 0; }"
                ~ " .hcad-completion-list row { padding: 1px 0; min-height: 0; }"
                ~ " .hcad-completion-doc { padding: 8px 10px; border-left: 1px solid alpha(currentColor, 0.12);"
                ~ " min-width: 200px; font-size: 0.9em; }"
                ~ " popover.hcad-signature > contents { padding: 4px 8px; }"
                ~ " .hcad-kind { font: 0.72em sans-serif; min-width: 4.6em; border-radius: 4px; padding: 1px 3px;"
                ~ " background: alpha(currentColor, 0.1); }"
                ~ " .hcad-kind-function, .hcad-kind-method, .hcad-kind-variable { color: #2f7d63; background: alpha(#8fcbb4, 0.35); }"
                ~ " .hcad-kind-property, .hcad-kind-field { color: #3a6ea5; background: alpha(#3a6ea5, 0.14); }"
                ~ " .hcad-kind-parameter { color: #9a5b00; background: alpha(#e5a50a, 0.22); }"
                ~ " .hcad-kind-constant, .hcad-kind-type { color: #7a4fa0; background: alpha(#9141ac, 0.14); }"
                ~ " .hcad-floating { background: alpha(@window_bg_color, 0.82); border-radius: 9px;"
                ~ " border: 1px solid alpha(currentColor, 0.10); box-shadow: 0 1px 4px alpha(black, 0.12); }"
                ~ " .hcad-viewbar { padding: 3px 6px; }"
                ~ " .hcad-viewbar button { min-height: 24px; min-width: 24px; padding: 1px 7px; }"
                ~ " .hcad-viewbar separator { margin: 4px 2px; }"
                ~ " .hcad-sectionbar { padding: 2px 8px 4px 8px; border-top: 1px solid alpha(currentColor, 0.10); }"
                ~ " .hcad-sectionbar label { font-size: 0.9em; }"
                ~ " popover.hcad-menu > contents { padding: 4px 0; min-width: 210px; border-radius: 6px; }"
                ~ " popover.hcad-menu button { min-height: 0; padding: 3px 14px; border-radius: 0; font-weight: normal;"
                ~ " font-size: 0.93em; }"
                ~ " popover.hcad-menu button:hover { background: alpha(@accent_bg_color, 0.14); }"
                ~ " popover.hcad-menu separator { margin: 4px 0; }"
                ~ " popover.hcad-menu .hcad-menu-heading { padding: 4px 14px 2px 14px; font-size: 0.78em; font-weight: bold;"
                ~ " opacity: 0.55; }"
                ~ " label.hcad-info { padding: 4px 10px; border-radius: 6px; font-size: 0.9em;"
                ~ " background: alpha(@window_bg_color, 0.85); border: 1px solid alpha(currentColor, 0.10); }"
                ~ " button.hcad-problem { padding: 6px 12px; border-radius: 8px; font-weight: normal;"
                ~ " box-shadow: 0 1px 4px alpha(black, 0.18); }"
                ~ " button.hcad-problem.error { background: #c01c28; color: white; }"
                ~ " button.hcad-problem.warning { background: #e5a50a; color: #1e1e1e; }"
                ~ " popover.hcad-menu button { min-height: 0; padding: 4px 10px; border-radius: 5px; font-weight: normal; }"
                ~ " popover.hcad-menu separator { margin: 3px 6px; }");
            StyleContext.addProviderForDisplay(Display.getDefault(), css, 600);
        }
        auto modes = new Box(Orientation.Horizontal, 0);
        modes.addCssClass("linked");
        rotateMode = toggle("object-rotate-right-symbolic", "Left drag rotates the view (right drag always rotates)", true);
        panMode = toggle("hcad-pan-symbolic", "Left drag pans the view (middle drag or Ctrl + right drag always pan)", false);
        panMode.setGroup(rotateMode);
        rotateMode.connectToggled(() {
            viewport.leftMode = rotateMode.getActive() ? DragMode.rotate : DragMode.pan;
        });
        modes.append(rotateMode);
        modes.append(panMode);

        auto views = new Box(Orientation.Horizontal, 0);
        views.addCssClass("linked");
        views.append(textButton("Fit", "Frame the model (F5)", () => viewport.fit()));
        views.append(textButton("Iso", "Isometric view", () => viewport.setView(ViewPreset.iso)));
        views.append(textButton("Top", "Top view", () => viewport.setView(ViewPreset.top)));
        views.append(textButton("Front", "Front view", () => viewport.setView(ViewPreset.front)));
        views.append(textButton("Right", "Right view", () => viewport.setView(ViewPreset.right)));
        viewBar.append(views);
        viewBar.append(separator());
        viewBar.append(modes);
        viewBar.append(separator());
        viewBar.append(sectionToggle);
        viewBar.append(sketchToggle);
        foreach (b; [rotateMode, panMode, sectionToggle, sketchToggle])
            b.addCssClass("flat");

        // ---- editor
        buffer = new SourceBuffer;
        auto lm = LanguageManager.getDefault();
        lm.prependSearchPath(dataDir("language-specs"));
        if (auto lang = lm.getLanguage("hcad"))
            buffer.setLanguage(lang);
        if (auto scheme = StyleSchemeManager.getDefault().getScheme("Adwaita"))
            buffer.setStyleScheme(scheme);
        // errors: red squiggle under the code, a tinted line and an icon in the gutter
        import gdk.rgba : RGBA;
        void problemTags(string name, RGBA colour, string lineColour)
        {
            auto t = new TextTag(name);
            t.underline = Underline.Error;
            t.underlineRgba = colour;
            buffer.getTagTable().add(t);
            auto l = new TextTag(name ~ "-line");
            l.paragraphBackground = lineColour;
            buffer.getTagTable().add(l);
        }
        problemTags("error", RGBA(0.86, 0.1, 0.1, 1), "rgba(230, 60, 60, 0.13)");
        problemTags("warning", RGBA(0.85, 0.55, 0.0, 1), "rgba(240, 180, 40, 0.13)");
        auto pickTag = new TextTag("picked");
        pickTag.paragraphBackground = "rgba(255, 210, 60, 0.25)";
        buffer.getTagTable().add(pickTag);

        editor = new SourceView;
        editor.setBuffer(buffer);
        editor.setMonospace(true);
        editor.setShowLineNumbers(true);
        editor.setShowLineMarks(true);
        {
            import gtksource.mark_attributes : MarkAttributes;
            auto ea = new MarkAttributes;
            ea.setIconName("dialog-error-symbolic");
            editor.setMarkAttributes("error", ea, 2);
            auto wa = new MarkAttributes;
            wa.setIconName("dialog-warning-symbolic");
            editor.setMarkAttributes("warning", wa, 1);
        }
        editor.setAutoIndent(true);
        editor.setTabWidth(4);
        editor.setIndentWidth(4);
        editor.setInsertSpacesInsteadOfTabs(true);
        editor.setHighlightCurrentLine(true);
        editor.setTopMargin(6);
        // completion, call signatures and help on names
        completion = new EditorCompletion(editor, buffer);
        completion.path = () => path;
        {
            import hackerscad.lang.interp : libraryPaths;
            completion.libraryDirs = libraryPaths();
        }
        editor.setLeftMargin(4);
        auto editorScroll = new ScrolledWindow;
        editorScroll.setChild(editor);
        editorScroll.setVexpand(true);

        console = new TextView;
        console.setEditable(false);
        {
            auto program = new TextTag("program");
            program.foreground = "#8a8f98";
            program.scale = 0.88;
            console.getBuffer().getTagTable().add(program);
        }
        console.setMonospace(true);
        console.setWrapMode(WrapMode.None);
        console.setLeftMargin(8);
        console.setTopMargin(4);
        auto consoleScroll = new ScrolledWindow;
        consoleScroll.setChild(console);
        consoleScroll.setVexpand(true);
        // a title, and a hint while there is nothing to show
        auto consoleTitle = new Label("Console");
        consoleTitle.addCssClass("caption-heading");
        consoleTitle.addCssClass("dim-label");
        consoleTitle.setXalign(0);
        consoleTitle.setMarginStart(8);
        consoleTitle.setMarginTop(4);
        consoleTitle.setMarginBottom(2);
        consoleHint = new Label("Output of writeln, failed unittests and errors appear here.");
        consoleHint.addCssClass("dim-label");
        consoleHint.setHalign(Align.Start);
        consoleHint.setValign(Align.Start);
        consoleHint.setMarginStart(10);
        consoleHint.setMarginTop(4);
        consoleHint.setCanTarget(false);
        auto consoleOverlay = new Overlay;
        consoleOverlay.setChild(consoleScroll);
        consoleOverlay.addOverlay(consoleHint);
        auto consolePane = new Box(Orientation.Vertical, 0);
        consolePane.append(consoleTitle);
        consolePane.append(consoleOverlay);
        consolePane.setSizeRequest(-1, 70);
        consoleToggle.connectToggled(() => consolePane.setVisible(consoleToggle.getActive()));
        editorScroll.setSizeRequest(300, 200);

        auto left = new Paned(Orientation.Vertical);
        left.setStartChild(editorScroll);
        left.setEndChild(consolePane);
        left.setPosition(700);
        left.setResizeStartChild(true);

        // ---- view and parameters
        buildSectionBar();
        viewport = new Viewport;
        viewport.onPick = &picked;
        viewport.onContext = &contextMenu;
        // labels move after the frame, not while the view is being drawn
        viewport.onFrame = () {
            if (positionQueued || dimButtons.length == 0)
                return;
            positionQueued = true;
            idleAdd(PRIORITY_DEFAULT, () {
                positionQueued = false;
                positionDimensions();
                return false;
            });
        };
        overlay = new Overlay;
        overlay.setChild(viewport.area);
        // no usable OpenGL, and the application knows what to do: say it
        viewport.onGlFailed = (string help) {
            auto card = new Label(help);
            card.setWrap(true);
            card.setMaxWidthChars(56);
            card.setJustify(Justification.Left);
            card.setHalign(Align.Center);
            card.setValign(Align.Center);
            card.addCssClass("card");
            card.addCssClass("hcad-gl-help");
            overlay.addOverlay(card);
        };
        features = new FeaturesPanel;
        features.onSelect = &rollTo;
        features.onFinal = () {
            viewport.clearRollback();
            info("");
        };
        params = new ParamsPanel;
        params.onChange = () => scheduleEvaluation(0);
        params.onVisibility = (size_t part, bool visible) => viewport.setHidden(part, !visible);
        auto paramsScroll = new ScrolledWindow;
        paramsScroll.setChild(params.widget);

        // parameters in a sidebar with bounded width that can be hidden
        // parameters and the feature tree share the sidebar
        auto stack = new ViewStack;
        stack.addTitledWithIcon(paramsScroll, "params", "Parameters", "preferences-other-symbolic");
        auto featuresScroll = new ScrolledWindow;
        featuresScroll.setChild(features.widget);
        stack.addTitledWithIcon(featuresScroll, "features", "Features", "view-list-symbolic");
        stack.setVexpand(true);
        auto switcher = new ViewSwitcher;
        switcher.setMarginTop(6);
        switcher.setMarginBottom(2);
        switcher.setMarginStart(6);
        switcher.setMarginEnd(6);
        switcher.setStack(stack);
        switcher.setPolicy(ViewSwitcherPolicy.Narrow);
        auto sidebar = new Box(Orientation.Vertical, 0);
        sidebar.append(switcher);
        sidebar.append(stack);

        // the view tools float over the 3D view, slightly see-through
        auto tools = new Box(Orientation.Vertical, 0);
        tools.addCssClass("hcad-floating");
        tools.setHalign(Align.Center);
        tools.setValign(Align.Start);
        tools.setMarginTop(8);
        tools.append(viewBar);
        tools.append(sectionBar);
        overlay.addOverlay(tools);
        info("");
        overlay.setVexpand(true);

        auto right = new OverlaySplitView;
        right.setContent(overlay);
        right.setSidebar(sidebar);
        right.setSidebarPosition(PackType.End);
        right.setMinSidebarWidth(220);
        right.setMaxSidebarWidth(420);
        right.setSidebarWidthFraction(0.22);
        right.setEnableShowGesture(false);
        right.setShowSidebar(true);
        paramsToggle.connectToggled(() => right.setShowSidebar(paramsToggle.getActive()));
        viewport.area.setSizeRequest(320, 240);

        auto main = new Paned(Orientation.Horizontal);
        main.setStartChild(left);
        main.setEndChild(right);
        main.setPosition(560);
        main.setShrinkStartChild(false);
        main.setShrinkEndChild(false);

        auto toolbar = new ToolbarView;
        toolbar.addTopBar(header);
        toolbar.setContent(main);
        window.setContent(toolbar);

        // ---- actions and shortcuts
        action(app, "save", ["<Control>s"], &save);
        action(app, "open", ["<Control>o"], &openFile);
        action(app, "new", ["<Control>n"], &newFile);
        action(app, "save-as", ["<Control><Shift>s"], () => saveAs());
        action(app, "quit", ["<Control>q"], () => window.close());
        // Ctrl+E: the format used last (3MF at first); the menus name them all
        action(app, "export", ["<Control>e"], () => exportFile(exportFormat));
        foreach (f; exportFormats)
            exportAction(app, f.ext);
        action(app, "fit", ["F5"], () => viewport.fit());
        action(app, "params", ["F9"], () => paramsToggle.setActive(!paramsToggle.getActive()));
        action(app, "console", ["<Control>j"], () => consoleToggle.setActive(!consoleToggle.getActive()));
        action(app, "about", [], &showAbout);
        action(app, "cheatsheet", ["F1"], &showCheatsheet);
        action(app, "tutorial", [], () => openUri(appWebsite ~ "/blob/main/docs/TUTORIAL.md"));
        action(app, "reference", [], () => openUri(appWebsite ~ "/blob/main/docs/LANGUAGE.md"));

        evaluator = new Evaluator;
        evaluator.onResult = &showOutcome;
        evaluator.onProgress = (string what) { stage = what; };

        buffer.setText(exists(path) ? readText(path) : newModelTemplate);
        modified = false;
        updateTitle();
        buffer.connectChanged(() {
            revision++;
            modified = true;
            updateTitle();
            scheduleEvaluation(250);
        });
        scheduleEvaluation(0);

        // external control (MCP server, scripts), under a name agents can tell apart
        try
        {
            exeAtStart = thisExePath;
            exeTimeAtStart = mtimeOf(exeAtStart);
        }
        catch (Exception)
            exeAtStart = null;
        control = new ControlServer;
        if (control.start(&handleControl))
            showWindowName();
        else
            control = null;
        window.connectCloseRequest(() {
            // unsaved changes: ask first, and close again once answered
            if (modified && !closeConfirmed)
            {
                confirmDiscard(() {
                    closeConfirmed = true;
                    window.close();
                });
                return true;
            }
            if (control)
                control.stop();
            return false;
        });
        // the file may be changed by someone else (an agent, another editor)
        diskTime = mtimeOf(path);
        timeoutAdd(PRIORITY_DEFAULT, 1000, () {
            checkDisk();
            return true;
        });
        window.present();
    }

private:

    Button button(string icon, string tooltip, void delegate() onClick)
    {
        auto b = new Button;
        b.setIconName(icon);
        b.setTooltipText(tooltip);
        b.connectClicked(onClick);
        return b;
    }

    ToggleButton toggle(string icon, string tooltip, bool active)
    {
        auto b = new ToggleButton;
        b.setIconName(icon);
        b.setTooltipText(tooltip);
        b.setActive(active);
        return b;
    }

    static Widget separator()
    {
        import gtk.separator : Separator;
        return new Separator(Orientation.Vertical);
    }

    Button textButton(string label, string tooltip, void delegate() onClick)
    {
        auto b = new Button;
        b.addCssClass("flat");
        b.setLabel(label);
        b.setTooltipText(tooltip);
        b.connectClicked(onClick);
        return b;
    }

    /// The menu at the right of the header bar: files, help, about.
    Widget mainMenu()
    {
        import gio.menu : Menu;
        import gtk.menu_button : MenuButton;
        auto files = new Menu;
        files.append("New", "win.new");
        files.append("Open…", "win.open");
        files.append("Save As…", "win.save-as");
        files.appendSubmenu("Export", exportModel());
        auto help = new Menu;
        help.append("Cheatsheet", "win.cheatsheet");
        help.append("Tutorial", "win.tutorial");
        help.append("Language Reference", "win.reference");
        auto app = new Menu;
        app.append("About hackerscad", "win.about");
        app.append("Quit", "win.quit");
        auto menu = new Menu;
        menu.appendSection(null, files);
        menu.appendSection(null, help);
        menu.appendSection(null, app);
        auto b = new MenuButton;
        b.setIconName("open-menu-symbolic");
        b.setTooltipText("Main menu");
        b.setMenuModel(menu);
        b.setPrimary(true);
        return b;
    }

    void showCheatsheet()
    {
        if (cheatsheet is null)
        {
            cheatsheet = new CheatsheetWindow(window);
            cheatsheet.onInsert = (string s) {
                buffer.insertAtCursor(s);
                editor.grabFocus();
            };
        }
        cheatsheet.present();
    }

    void openUri(string uri)
    {
        import gtk.uri_launcher : UriLauncher;
        new UriLauncher(uri).launch(window, null, null);
    }

    /// The About window: version, author, what hackerscad is built with
    /// and the licences of those libraries.
    void showAbout()
    {
        import adw.about_dialog : AboutDialog;
        import gtk.types : License;
        import std.array : array;
        import std.algorithm : map;
        auto d = new AboutDialog;
        d.setApplicationName(appName);
        d.setApplicationIcon("it.andreafontana.hackerscad.gui");
        d.setVersion(appVersion);
        d.setDeveloperName(appAuthor);
        d.setDevelopers([appAuthor]);
        d.setCopyright(appCopyright);
        d.setComments("The hacker's CAD: solid models written as code in a small language, "
            ~ "edited with the mouse too, driven by AI agents through MCP.");
        d.setWebsite(appWebsite);
        d.setIssueUrl(appIssues);
        d.setLicenseType(License.Gpl30Only);
        d.addLegalSection("Models and their output", null, License.Custom, appModelException);
        d.addCreditSection("Built with", components.map!(c => c.name ~ " " ~ c.url).array);
        d.addCreditSection("Inspired by", ["OpenSCAD https://openscad.org", "Onshape https://www.onshape.com"]);
        foreach (c; components)
        {
            License t;
            string text;
            switch (c.license)
            {
            case "Apache-2.0": t = License.Apache20; break;
            case "MIT": t = License.MitX11; break;
            case "LGPL-2.1-or-later": t = License.Lgpl21; break;
            default:
                t = License.Custom;
                text = c.license ~ " (" ~ c.url ~ ")";
            }
            d.addLegalSection(c.name, c.copyright, t, text);
        }
        import std.system : os;
        import std.conv : to;
        d.setDebugInfo(appName ~ " " ~ appVersion ~ "\n" ~ os.to!string ~ "\n" ~ path);
        d.present(window);
    }

    void action(AdwApplication app, string name, string[] accels, void delegate() run)
    {
        auto a = new SimpleAction(name);
        a.connectActivate(() => run());
        window.addAction(a);
        app.setAccelsForAction("win." ~ name, accels);
    }

    /// Data files: installed (bin/../share/hackerscad), next to the
    /// executable (bin/../data, Windows zip: data), or in the source tree.
    static string dataDir(string sub)
    {
        immutable exe = dirName(thisExePath);
        foreach (base; [buildPath(exe, "..", "share", "hackerscad"), buildPath(exe, "..", "data"), buildPath(exe, "data")])
            if (exists(buildPath(base, sub)))
                return buildNormalizedPath(base, sub);
        return buildPath("data", sub);
    }

    string text()
    {
        TextIter s, e;
        buffer.getBounds(s, e);
        return buffer.getText(s, e, true);
    }

    void updateTitle()
    {
        title.setTitle((modified ? "• " : "") ~ baseName(path));
        title.setSubtitle(dirName(path));
    }

    void scheduleEvaluation(uint delayMs)
    {
        if (debounce)
            Source.remove(debounce);
        debounce = timeoutAdd(PRIORITY_DEFAULT, delayMs, () {
            debounce = 0;
            busyIndicator.setVisible(true);
            busyIndicator.start();
            startProgress();
            Request r;
            r.source = text();
            r.path = path;
            r.overrides = params.overrides.dup;
            r.preset = params.preset;
            evaluator.request(r);
            return false;
        });
    }

    void showOutcome(Outcome o)
    {
        // a failed evaluation leaves the last good model on screen: it is
        // also what Export saves
        if (!o.ok)
            o.parts = last.parts;
        last = o;
        hadResult = true;
        params.update(o.params, o.presets);
        features.update(o.features, path);
        if (viewport.inRollback)
        {
            viewport.clearRollback();
            features.clearSelection();
        }
        viewport.setSketches(o.sketches);
        if (sectionToggle.getActive())
            updateSection(false);
        // the sketch button only makes sense when the model has sketches
        sketchToggle.setVisible(o.sketches.length > 0);
        if (o.sketches.length == 0 && sketchToggle.getActive())
            sketchToggle.setActive(false);
        updateDimensions();

        TextIter s, e;
        buffer.getBounds(s, e);
        foreach (tag; ["error", "error-line", "warning", "warning-line"])
            buffer.removeTagByName(tag, s, e);
        buffer.removeSourceMarks(s, e, null);

        string log;
        foreach (l; o.log)
            log ~= l.text ~ "\n";
        size_t errors;
        Diagnostic first;
        bool haveFirst;
        foreach (d; o.diagnostics)
        {
            errors += d.severity == Severity.error;
            log ~= render(d, o.sources.get(d.span.file, "")) ~ "\n";
            if (d.span.file == absolutePath(path) && d.span.line > 0)
                markProblem(d.span, d.severity == Severity.error ? "error" : "warning");
            if (!haveFirst || (d.severity == Severity.error && first.severity != Severity.error))
            {
                first = d;
                haveFirst = true;
            }
        }
        modelOutput = log;
        busyIndicator.stop();
        busyIndicator.setVisible(false);
        stopProgress();
        showProblem(haveFirst, first, o.ok);

        if (o.ok)
        {
            viewport.setParts(o.parts, firstResult);
            firstResult = false;
            import std.algorithm : map;
            import std.array : array;
            params.updateParts(o.parts.map!(p => p.name).array, o.parts.map!(p => p.rgb).array, &viewport.isHidden);
            immutable total = o.cacheHits + o.cacheMisses;
            note(format("%s %d part%s in %d ms%s%s", errors ? "evaluated with problems:" : "evaluated:", o.parts.length,
                o.parts.length == 1 ? "" : "s", o.milliseconds,
                total ? format(" (%d%% from cache)", o.cacheHits * 100 / total) : "", sketchSummary()), true);
        }
        else
        {
            // keep showing the last good geometry while the code is being fixed
            auto d = o.diagnostics.length ? o.diagnostics[0] : Diagnostic.init;
            note(format("not evaluated: %s at line %d", d.code, d.span.line), true);
        }

        if (screenshotPath.length)
        {
            auto shot = screenshotPath;
            screenshotPath = null;
            // HCAD_SCREENSHOT_WAIT=seconds keeps the window open afterwards,
            // for a capture of the whole screen (the CI screenshots)
            import std.conv : to;
            import std.process : environment;
            uint linger;
            try
                linger = environment.get("HCAD_SCREENSHOT_WAIT", "0").to!uint * 1000;
            catch (Exception)
            {
            }
            timeoutAdd(PRIORITY_DEFAULT, 700, () {
                screenshot(shot);
                timeoutAdd(PRIORITY_DEFAULT, linger, () { window.close(); return false; });
                return false;
            });
        }
    }

    /// Renders the whole window, 3D view included, to a PNG file.
    /// Returns false when nothing could be captured (e.g. the screen is
    /// locked and the compositor does not draw windows).
    bool screenshot(string file, imported!"gtk.window".Window other = null)
    {
        import gtk.widget_paintable : WidgetPaintable;
        import gtk.snapshot : Snapshot;

        imported!"gtk.window".Window w = other !is null ? other : window;
        auto paintable = new WidgetPaintable(w);
        auto snap = new Snapshot;
        paintable.snapshot(snap, w.getWidth(), w.getHeight());
        if (completion !is null && other is null)
            completion.snapshotOver(snap, window);
        auto node = snap.toNode();
        if (node is null)
        {
            import std.stdio : stderr;
            stderr.writeln("screenshot: the window has not been drawn (is the screen locked?)");
            return false;
        }
        return w.getRenderer().renderTexture(node, null).saveToPng(file);
    }

    /// Underlines the code of a problem (at least the whole word), tints its
    /// line and puts an icon in the gutter.
    void markProblem(Span span, string kind)
    {
        TextIter a, b, lineStart, lineEnd;
        if (!buffer.getIterAtLine(lineStart, span.line - 1))
            return;
        lineEnd = lineStart.copy();
        if (!lineEnd.endsLine())
            lineEnd.forwardToLineEnd();
        immutable lineLength = lineEnd.getLineIndex();
        immutable from = min(cast(int) span.col - 1, max(0, lineLength - 1));
        buffer.getIterAtLineIndex(a, span.line - 1, from);
        b = a.copy();
        int n = span.length > 1 ? span.length : 1;
        b.forwardChars(n);
        // a one-character span on a word covers the whole word
        if (n == 1 && b.insideWord())
            b.forwardWordEnd();
        if (b.compare(lineEnd) > 0)
            b = lineEnd.copy();
        buffer.applyTagByName(kind, a, b);
        auto next = lineEnd.copy();
        next.forwardChar();
        buffer.applyTagByName(kind ~ "-line", lineStart, next);
        buffer.createSourceMark(null, kind, lineStart);
    }

    string modelOutput;      /// writeln output and problems of the latest evaluation
    string[] programLog;     /// messages of the program itself, with their time
    bool lastWasEvaluation;

    /// A message of the program (not of the model): shown at the bottom of the
    /// console, dimmed. Evaluation summaries replace each other.
    void note(string message, bool evaluation = false)
    {
        import std.datetime.systime : Clock;
        auto t = Clock.currTime();
        auto line = format("%02d:%02d:%02d  %s", t.hour, t.minute, t.second, message);
        if (evaluation && lastWasEvaluation && programLog.length)
            programLog[$ - 1] = line;
        else
            programLog ~= line;
        if (programLog.length > 60)
            programLog = programLog[$ - 60 .. $];
        lastWasEvaluation = evaluation;
        statusText = message;
        renderConsole();
    }

    /// The model's output first, then the program's messages.
    void renderConsole()
    {
        auto b = console.getBuffer();
        b.setText(modelOutput);
        if (programLog.length)
        {
            TextIter end;
            b.getEndIter(end);
            immutable from = end.getOffset();
            b.insert(end, (modelOutput.length ? "\n" : "") ~ programLog.join("\n"));
            TextIter a, z;
            b.getIterAtOffset(a, from);
            b.getEndIter(z);
            b.applyTagByName("program", a, z);
        }
        consoleHint.setVisible(modelOutput.length == 0 && programLog.length == 0);
        // keep the latest lines in view
        TextIter last;
        b.getEndIter(last);
        console.scrollToIter(last, 0, false, 0, 1);
    }

    // ---- what a long evaluation is doing, over the view
    Box progressBox;
    Label progressLabel;
    uint progressTimer;
    string stage;
    MonoTime evalStart;

    void startProgress()
    {
        evalStart = MonoTime.currTime;
        stage = "reading the model";
        if (progressTimer == 0)
            progressTimer = timeoutAdd(PRIORITY_DEFAULT, 200, () => tickProgress());
    }

    /// Shown after 0.4 s: what is being computed and for how long, with a
    /// Stop button; the old model is veiled meanwhile.
    bool tickProgress()
    {
        import std.format : format;
        if (!evaluator.busy)
        {
            stopProgress();
            return false;
        }
        immutable seconds = (MonoTime.currTime - evalStart).total!"msecs" / 1000.0;
        if (seconds < 0.4)
            return true;
        if (progressBox is null)
        {
            progressBox = new Box(Orientation.Horizontal, 10);
            progressBox.addCssClass("hcad-floating");
            progressBox.addCssClass("hcad-progress");
            progressBox.setHalign(Align.Center);
            progressBox.setValign(Align.Center);
            auto spin = new Spinner;
            spin.start();
            progressBox.append(spin);
            progressLabel = new Label("");
            progressLabel.addCssClass("numeric");
            progressBox.append(progressLabel);
            auto stop = new Button;
            stop.setLabel("Stop");
            stop.setTooltipText("Stop this evaluation; it runs again at the next edit");
            stop.connectClicked(() => stopEvaluation());
            progressBox.append(stop);
            overlay.addOverlay(progressBox);
        }
        progressLabel.setLabel(format("Evaluating · %s · %.1f s", stage, seconds));
        progressBox.setVisible(true);
        viewport.area.setOpacity(0.45);
        return true;
    }

    void stopProgress()
    {
        if (progressTimer)
            Source.remove(progressTimer);
        progressTimer = 0;
        if (progressBox !is null)
            progressBox.setVisible(false);
        viewport.area.setOpacity(1);
    }

    void stopEvaluation()
    {
        import std.format : format;
        immutable seconds = (MonoTime.currTime - evalStart).total!"msecs" / 1000.0;
        evaluator.cancel();
        busyIndicator.stop();
        busyIndicator.setVisible(false);
        stopProgress();
        note(format("evaluation stopped after %.1f s (at %s): it runs again at the next edit", seconds, stage));
    }

    Label infoLabel;

    /// Shows what is selected (or a short message) at the bottom of the 3D view; empty hides it.
    void info(string text)
    {
        if (infoLabel is null)
        {
            infoLabel = new Label("");
            infoLabel.addCssClass("hcad-info");
            infoLabel.setHalign(Align.End);
            infoLabel.setValign(Align.End);
            infoLabel.setMarginEnd(10);
            infoLabel.setMarginBottom(10);
            infoLabel.setEllipsize(EllipsizeMode.Middle);
            infoLabel.setMaxWidthChars(70);
            infoLabel.setCanTarget(false);
            overlay.addOverlay(infoLabel);
        }
        infoLabel.setLabel(text);
        infoLabel.setVisible(text.length > 0);
    }

    Button problemBanner;
    Label problemText;
    Span problemSpan;

    /// A banner over the 3D view with the first problem; it jumps to the line.
    void showProblem(bool any, Diagnostic d, bool evaluated)
    {
        if (problemBanner is null)
        {
            problemBanner = new Button;
            problemBanner.addCssClass("hcad-problem");
            problemText = new Label("");
            problemText.setEllipsize(EllipsizeMode.End);
            problemText.setMaxWidthChars(80);
            problemText.setXalign(0);
            problemBanner.setChild(problemText);
            problemBanner.setHalign(Align.Start);
            problemBanner.setValign(Align.End);
            problemBanner.setMarginStart(10);
            problemBanner.setMarginEnd(10);
            problemBanner.setMarginBottom(10);
            problemBanner.connectClicked(() => jumpTo(problemSpan, problemText.getText()));
            overlay.addOverlay(problemBanner);
        }
        problemBanner.setVisible(any);
        if (!any)
            return;
        immutable error = d.severity == Severity.error;
        problemBanner.removeCssClass(error ? "warning" : "error");
        problemBanner.addCssClass(error ? "error" : "warning");
        problemSpan = d.span;
        auto where = d.span.line > 0 ? (d.span.file == absolutePath(path) ? format("line %d: ", d.span.line)
            : format("%s:%d: ", baseName(d.span.file), d.span.line)) : "";
        auto hint = d.suggestion.length ? (d.suggestion.length < 40 && !d.suggestion.canFind(' ') ? " · did you mean '"
            ~ d.suggestion ~ "'?" : " · " ~ d.suggestion) : "";
        problemText.setText(format("%s %s%s%s", error ? "✗" : "⚠", where, d.message, hint));
        problemBanner.setTooltipText(d.message ~ hint ~ (!evaluated && last.parts.length ? "\nThe view shows the last valid model."
            : "") ~ "\nClick to go to the line.");
    }

    /// A click selects a face: it is highlighted and the editor shows the
    /// line of the feature that created it (or the part's function).
    void picked(Hit hit)
    {
        // in sketch mode a click near a sketch point shows the line that created it
        if (sketchToggle.getActive())
            foreach (sk; last.sketches)
                foreach (pt; sk.points)
                {
                    double px, py;
                    if (viewport.project(pt.pos, px, py) && (px - hit.x) ^^ 2 + (py - hit.y) ^^ 2 < 64)
                    {
                        jumpTo(pt.span, format("sketch point · line %d%s", pt.span.line,
                            pt.free ? " · can still move" : " · fully constrained"));
                        return;
                    }
                }
        if (hit.part >= 0 && hit.edge < 0)
            hit.edge = viewport.nearestEdge(hit.part, hit.face, hit.x, hit.y, 6);
        if (hit.shift && hit.part >= 0)
        {
            // Shift+click builds a selection of faces and edges for one operation
            viewport.toggleSelect(hit);
            auto sel = viewport.selection();
            size_t nf, ne;
            foreach (h; sel)
                (h.edge >= 0 ? ne : nf)++;
            info(format("%d face%s, %d edge%s selected · right-click for operations", nf, nf == 1 ? "" : "s",
                ne, ne == 1 ? "" : "s"));
            return;
        }
        viewport.select(hit);
        // a section parallel to the selected face follows the new face
        if (sectionToggle.getActive() && sectionPlane.getSelected() == 3 && hit.face >= 0)
            updateSection(true);
        TextIter s, e;
        buffer.getBounds(s, e);
        buffer.removeTagByName("picked", s, e);
        if (hit.part < 0 || hit.part >= last.parts.length)
        {
            info("");
            return;
        }
        auto part = last.parts[hit.part];
        auto span = part.span;
        string what = part.name;
        if (hit.face >= 0 && hit.face < part.creators.length)
        {
            immutable id = part.creators[hit.face];
            if (id > 0 && id <= last.features.length)
            {
                auto f = last.features[id - 1];
                what = format("%s · %s %d · %s, line %d", part.name, hit.edge >= 0 ? "edge" : "face",
                    hit.edge >= 0 ? hit.edge : hit.face, f.kind, f.span.line);
                // features from imported modules point elsewhere: stay on the part
                if (f.span.file == absolutePath(path))
                    span = f.span;
            }
        }
        TextIter a, b;
        if (!buffer.getIterAtLine(a, span.line - 1))
            return;
        buffer.getIterAtLine(b, span.line);
        buffer.applyTagByName("picked", a, b);
        buffer.placeCursor(a);
        editor.scrollToIter(a, 0.1, true, 0, 0.3);
        info(format("%s · %.1f × %.1f × %.1f mm", what, part.bbox.size.x, part.bbox.size.y, part.bbox.size.z));
    }

    /// Highlights a line of the editor and shows a message.
    void jumpTo(Span span, string message)
    {
        TextIter s, e;
        buffer.getBounds(s, e);
        buffer.removeTagByName("picked", s, e);
        info(message);
        if (span.file != absolutePath(path) || span.line == 0)
            return;
        TextIter a, b;
        if (!buffer.getIterAtLine(a, span.line - 1))
            return;
        buffer.getIterAtLine(b, span.line);
        buffer.applyTagByName("picked", a, b);
        buffer.placeCursor(a);
        editor.scrollToIter(a, 0.1, true, 0, 0.3);
    }

    // ---- section view

    void buildSectionBar()
    {
        sectionBar = new Box(Orientation.Horizontal, 8);
        sectionBar.addCssClass("hcad-sectionbar");
        auto title = new Label("Section");
        title.addCssClass("dim-label");
        sectionBar.append(title);
        sectionPlane = DropDown.newFromStrings(["XY plane", "XZ plane", "YZ plane", "Selected face"]);
        sectionPlane.addCssClass("flat");
        sectionPlane.setTooltipText("The cutting plane: parallel to a main plane, or to the face you clicked");
        sectionPlane.connectNotify("selected", () => updateSection(true));
        sectionBar.append(sectionPlane);
        sectionSlider = Scale.newWithRange(Orientation.Horizontal, 0, 1, 0.001);
        sectionSlider.setDrawValue(false);
        sectionSlider.setSizeRequest(240, -1);
        sectionSlider.connectValueChanged(() {
            if (!sectionUpdating)
                applySection();
        });
        sectionBar.append(sectionSlider);
        sectionLabel = new Label("");
        sectionLabel.addCssClass("numeric");
        sectionLabel.setWidthChars(16);
        sectionLabel.setXalign(1);
        sectionBar.append(sectionLabel);
        sectionFlip = new ToggleButton;
        sectionFlip.addCssClass("flat");
        sectionFlip.setIconName("object-flip-vertical-symbolic");
        sectionFlip.setTooltipText("Invert the plane's normal: show the other side of the cut");
        sectionFlip.connectToggled(() {
            if (sectionUpdating)
                return;
            sectionFlipped = sectionFlip.getActive();
            applySection();
        });
        sectionBar.append(sectionFlip);
        sectionBar.setVisible(false);
    }

    /// Recomputes the plane direction and the slider range; `reset` puts the
    /// plane in the middle of the model.
    void updateSection(bool reset)
    {
        if (!sectionToggle.getActive())
        {
            viewport.setSection(false, sectionNormal, 0);
            return;
        }
        Vec3 n;
        double through = double.nan;
        switch (sectionPlane.getSelected())
        {
        case 0: n = Vec3(0, 0, 1); break;
        case 1: n = Vec3(0, 1, 0); break;
        case 2: n = Vec3(1, 0, 0); break;
        default:
            Vec3 p;
            if (!viewport.selectedPlane(p, n))
            {
                info("click a face first, then choose \"Selected face\"");
                sectionUpdating = true;
                sectionPlane.setSelected(0);
                sectionUpdating = false;
                n = Vec3(0, 0, 1);
            }
            else
            {
                // the plane starts on the face and goes into the part as the slider moves left
                through = p.dot(n);
                sectionFace = through;
                reset = true;
            }
        }
        immutable old = sectionSlider.getValue();
        double lo, hi;
        viewport.extentAlong(n, lo, hi);
        sectionNormal = n;
        sectionUpdating = true;
        immutable margin = (hi - lo) * 0.001 + 1e-6;
        sectionSlider.setRange(lo - margin, hi + margin);
        if (through == through)
            sectionSlider.setValue(through - (hi - lo) * 0.02);
        else if (reset)
            sectionSlider.setValue((lo + hi) / 2);
        else
            sectionSlider.setValue(old);
        sectionUpdating = false;
        if (reset)
            sectionFlipped = false;
        sectionUpdating = true;
        sectionFlip.setActive(sectionFlipped);
        sectionUpdating = false;
        applySection();
    }

    void applySection()
    {
        immutable v = sectionSlider.getValue();
        // flipping keeps the same plane and hides the other side
        auto n = sectionFlipped ? sectionNormal * -1 : sectionNormal;
        viewport.setSection(true, n, sectionFlipped ? -v : v);
        immutable sel = sectionPlane.getSelected();
        string axis = sel == 0 ? "Z" : sel == 1 ? "Y" : sel == 2 ? "X" : "depth";
        sectionLabel.setLabel(format("%s = %.2f mm", axis, sel < 3 ? v : sectionFace - v));
    }

    // ---- feature tree and rollback

    void rollTo(uint id)
    {
        if (id == 0 || id > last.features.length)
            return;
        auto f = last.features[id - 1];
        jumpTo(f.span, format("rollback · line %d · %s (computing…)", f.span.line, f.kind));
        evaluator.prepareFeature(f, f.kind, (PartMesh m) {
            viewport.showRollback(m, id);
            info(format("rollback · line %d · %s · its new faces in orange", f.span.line, f.kind));
        });
    }

    // ---- context menu: features written into the code

    void contextMenu(Hit hit, double x, double y)
    {
        if (hit.part < 0 || hit.part >= last.parts.length || viewport.inRollback)
            return;
        hit.edge = viewport.nearestEdge(hit.part, hit.face, x, y, 12);
        // right-clicking inside a Shift selection keeps it; elsewhere selects what is under the pointer
        bool inSelection;
        foreach (h; viewport.selection())
            if (Viewport.sameItem(h, hit) || (h.part == hit.part && h.face == hit.face && hit.edge < 0))
                inSelection = true;
        if (!inSelection || viewport.selection().length <= 1)
            picked(hit);
        contextHit = hit;
        auto part = last.parts[hit.part];
        auto sel = viewport.selection();
        selFaces = null;
        selEdges = null;
        foreach (h; sel)
        {
            if (h.edge >= 0)
                selEdges ~= h.edge;
            else if (h.face >= 0)
                selFaces ~= h.face;
        }
        // the face under an edge still offers face operations
        if (selFaces.length == 0 && hit.face >= 0 && sel.length <= 1)
            selFaces = [hit.face];
        immutable nf = selFaces.length, ne = selEdges.length;
        alias I = MenuEntry.item, G = MenuEntry.group, H = MenuEntry.heading;
        alias S = MenuEntry.separator;
        string count(size_t n, string what) => n == 1 ? what : format("%d %ss", n, what);

        MenuEntry[] entries;
        string title = ne && nf ? format("%s, %s", count(ne, "edge"), count(nf, "face")) : ne ? count(ne, "edge")
            : nf ? count(nf, "face") : "Part";
        entries ~= H(title.toUpper, part.name);

        if (ne)
        {
            entries ~= I(ne == 1 ? "Fillet edge…" : format("Fillet %d edges…", ne), () => ctxEdges(".fillet(%s, r: 1.mm)", "1.mm"));
            entries ~= I(ne == 1 ? "Chamfer edge…" : format("Chamfer %d edges…", ne), () => ctxEdges(".chamfer(%s, d: 0.5.mm)",
                "0.5.mm"));
        }
        if (nf)
        {
            entries ~= I(nf == 1 ? "Fillet face edges…" : "Fillet edges of the faces…",
                () => ctxFaces(".fillet(edges.of(%s), r: 1.mm)", "1.mm"));
            entries ~= I(nf == 1 ? "Chamfer face edges…" : "Chamfer edges of the faces…",
                () => ctxFaces(".chamfer(edges.of(%s), d: 0.5.mm)", "0.5.mm"));
            entries ~= I(nf == 1 ? "Shell, opening this face…" : format("Shell, opening %d faces…", nf),
                () => ctxFaces(".shell(open: %s, thickness: 2.mm)", "2.mm"));
            entries ~= I(nf == 1 ? "Draft face…" : format("Draft %d faces…", nf), () => ctxFaces(".draft(%s, angle: 3.deg)", "3.deg"));
        }
        if (hit.face >= 0)
        {
            entries ~= S();
            MenuEntry[] holes;
            foreach (kind; [["Clearance", "clearance"], ["Tapping", "tap"], ["Heat-set insert", "insert"]])
            {
                MenuEntry[] sizes;
                foreach (size; ["M2", "M2.5", "M3", "M4", "M5", "M6", "M8"])
                    sizes ~= I(size, holeAction(kind[1], size), format("⌀ %g", holeDiameter(kind[1], size)));
                holes ~= G(kind[0], sizes);
            }
            entries ~= G("Hole at point", holes);
            entries ~= I("Pocket at point…", () => ctxOnFace(".cut(rect(10.mm, 6.mm), on: %s, at: %s, depth: 2.mm)", "2.mm"));
            entries ~= I("Boss at point…", () => ctxOnFace(".extrude(circle(d: 6.mm), on: %s, at: %s, depth: 3.mm)", "3.mm"));
        }

        // measurements: values on the right, a click copies them
        MenuEntry[] measures;
        if (ne == 1 && selEdges[0] < part.edgeInfo.length)
        {
            auto e = part.edgeInfo[selEdges[0]];
            string v = e.kind == EdgeKind.circle ? format("R %.4g mm", e.radius) : format("%.4g mm", (e.end - e.start).length);
            measures ~= I(e.kind == EdgeKind.circle ? "Edge radius" : "Edge length", () => copy(v), v);
            if (e.kind == EdgeKind.circle)
            {
                auto dia = format("⌀ %.4g mm", 2 * e.radius);
                measures ~= I("Edge diameter", () => copy(dia), dia);
            }
        }
        if (sel.length == 2)
        {
            // between the two selected items
            import hackerscad.gui.measure : measure, faceItem, edgeItem;
            Item item(Hit h) => h.edge >= 0 ? edgeItem(part, h.edge) : faceItem(part, h.face);
            auto m = measure(item(sel[0]), item(sel[1]));
            auto dv = format("%.4g mm", m.distance);
            measures ~= I("Distance", () => copy(dv), dv);
            if (m.gap == m.gap)
            {
                auto gv = format("%.4g mm", m.gap);
                measures ~= I("Gap between planes", () => copy(gv), gv);
            }
            if (m.angle == m.angle)
            {
                auto av = format("%.4g°", m.angle);
                measures ~= I("Angle", () => copy(av), av);
            }
        }
        if (nf)
        {
            double a = 0;
            foreach (f; selFaces)
                a += faceArea(part, f);
            auto av = format("%.4g mm²", a);
            measures ~= I(nf == 1 ? "Face area" : "Faces area", () => copy(av), av);
        }
        auto sz = part.bbox.size;
        auto size = format("%.4g × %.4g × %.4g", sz.x, sz.y, sz.z);
        measures ~= I("Part size", () => copy(size), size);
        auto vol = format("%.5g mm³", part.volume);
        measures ~= I("Part volume", () => copy(vol), vol);
        auto pt = hit.point;
        auto point = format("vec(%.4g.mm, %.4g.mm, %.4g.mm)", pt.x, pt.y, pt.z);
        measures ~= I("Point", () => copy(point), format("%.4g, %.4g, %.4g", pt.x, pt.y, pt.z));

        MenuEntry[] copies;
        if (nf)
        {
            copies ~= I("Face selector", () => copy(facesCode()));
            if (nf == 1)
            {
                copies ~= I("Frame on face", () => copy(".frame(" ~ facesCode() ~ ")"));
                copies ~= I("Plane of face", () => copy(".plane(" ~ facesCode() ~ ")"));
            }
        }
        if (ne)
        {
            copies ~= I("Edge selector", () => copy(edgesCode()));
            if (ne == 1)
                copies ~= I("Axis along edge", () => copy(".axis(" ~ edgesCode() ~ ")"));
        }

        MenuEntry[] view;
        if (hit.face >= 0)
        {
            view ~= I("Section parallel to face", () {
                sectionUpdating = true;
                sectionPlane.setSelected(3);
                sectionUpdating = false;
                sectionToggle.setActive(true);
                updateSection(true);
            });
            view ~= I("Look at face", () {
                Vec3 p, n;
                if (viewport.selectedPlane(p, n))
                    viewport.lookAlong(n);
            });
            view ~= S();
        }
        view ~= I("Hide part", () => setPartVisible(contextHit.part, false));
        view ~= I("Show only this part", () {
            foreach (i; 0 .. last.parts.length)
                setPartVisible(i, i == contextHit.part);
        });
        view ~= I("Show all parts", () {
            foreach (i; 0 .. last.parts.length)
                setPartVisible(i, true);
        });

        entries ~= S();
        entries ~= G("Measure", measures);
        if (copies.length)
            entries ~= G("Copy as code", copies);
        entries ~= G("View", view);
        contextPopover = popupMenu(viewport.area, x, y, entries);
    }

    import gtk.popover : Popover;
    Popover contextPopover;

    int[] selFaces, selEdges;

    Interp selectorInterp(out SolidVal sv)
    {
        auto part = last.parts[contextHit.part];
        sv = new SolidVal(part.brep, Span.init);
        sv.creators = part.creators;
        return new Interp(part.kernel);
    }

    /// Selector code for the selected faces / edges, joined with +.
    string facesCode()
    {
        SolidVal sv;
        auto it = selectorInterp(sv);
        string[] parts;
        foreach (f; selFaces)
            parts ~= faceSelector(it, sv, f);
        return parts.join(" + ");
    }

    string edgesCode()
    {
        SolidVal sv;
        auto it = selectorInterp(sv);
        string[] parts;
        foreach (e; selEdges)
            parts ~= edgeSelector(it, sv, e);
        return parts.join(" + ");
    }

    void ctxFaces(string code, string placeholder) => appendFeature(last.parts[contextHit.part], format(code, facesCode()),
        placeholder);
    void ctxEdges(string code, string placeholder) => appendFeature(last.parts[contextHit.part], format(code, edgesCode()),
        placeholder);

    Hit contextHit;

    void ctxFeature(string action, string placeholder)
    {
        if (contextHit.part < 0 || contextHit.part >= last.parts.length)
            return;
        auto code = featureCode(contextHit, action, null);
        if (code.length)
            appendFeature(last.parts[contextHit.part], code, placeholder);
    }

    string ctxSelector(bool edge)
    {
        auto part = last.parts[contextHit.part];
        auto it = new Interp(part.kernel);
        auto sv = new SolidVal(part.brep, Span.init);
        sv.creators = part.creators;
        return edge ? edgeSelector(it, sv, contextHit.edge) : faceSelector(it, sv, contextHit.face);
    }

    string ctxAt() => format("vec(%.4g.mm, %.4g.mm, %.4g.mm)", contextHit.point.x, contextHit.point.y, contextHit.point.z);

    /// `code` with %s for the face selector and %s for the clicked point.
    void ctxOnFace(string code, string placeholder)
    {
        appendFeature(last.parts[contextHit.part], format(code, ctxSelector(false), ctxAt()), placeholder);
    }

    static double holeDiameter(string kind, string size)
    {
        import std.algorithm : countUntil;
        immutable sizes = ["M2", "M2.5", "M3", "M4", "M5", "M6", "M8"];
        immutable double[] cl = [2.4, 2.9, 3.4, 4.5, 5.5, 6.6, 9], tp = [1.6, 2.05, 2.5, 3.3, 4.2, 5, 6.8],
            ins = [3.2, 3.6, 4.2, 5.6, 6.4, 8, 9.7];
        auto i = sizes.countUntil(size);
        return kind == "clearance" ? cl[i] : kind == "tap" ? tp[i] : ins[i];
    }

    // a function of its own: closures made in a loop would all share the last size
    void delegate() holeAction(string kind, string size) => () => ctxHole(kind, size);

    void ctxHole(string kind, string size)
    {
        // a blind hole 5 mm deep at the clicked point: edit the depth, or use through: true
        appendFeature(last.parts[contextHit.part], format("// %s %s hole (through: true instead of depth for a through hole)\n"
            ~ ".cut(circle(d: %g.mm), on: %s, at: %s, depth: 5.mm)", size, kind, holeDiameter(kind, size), ctxSelector(false),
            ctxAt()), "5.mm");
    }

    /// Area of a B-rep face from its triangles.
    static double faceArea(PartMesh p, int face)
    {
        if (face < 0 || face + 1 >= p.faceStart.length)
            return 0;
        double a = 0;
        Vec3 vtx(uint i) => Vec3(p.vertices[i * 6], p.vertices[i * 6 + 1], p.vertices[i * 6 + 2]);
        foreach (t; p.faceStart[face] .. p.faceStart[face + 1])
        {
            auto v0 = vtx(p.indices[t * 3]), v1 = vtx(p.indices[t * 3 + 1]), v2 = vtx(p.indices[t * 3 + 2]);
            a += (v1 - v0).cross(v2 - v0).length / 2;
        }
        return a;
    }

    void setPartVisible(size_t i, bool visible)
    {
        viewport.setHidden(i, !visible);
        params.refreshParts();
        import std.algorithm : map;
        import std.array : array;
        params.updateParts(last.parts.map!(p => p.name).array, last.parts.map!(p => p.rgb).array, &viewport.isHidden);
    }

    /// The code a context-menu action appends, or null.
    string featureCode(Hit hit, string action, string value)
    {
        auto part = last.parts[hit.part];
        auto it = new Interp(part.kernel);
        auto sv = new SolidVal(part.brep, Span.init);
        sv.creators = part.creators;
        string or(string def) => value.length ? value : def;
        switch (action)
        {
        case "fillet-edge":
            return hit.edge < 0 ? null : ".fillet(" ~ edgeSelector(it, sv, hit.edge) ~ ", r: " ~ or("1.mm") ~ ")";
        case "chamfer-edge":
            return hit.edge < 0 ? null : ".chamfer(" ~ edgeSelector(it, sv, hit.edge) ~ ", d: " ~ or("0.5.mm") ~ ")";
        case "fillet-face":
            return hit.face < 0 ? null : ".fillet(edges.of(" ~ faceSelector(it, sv, hit.face) ~ "), r: " ~ or("1.mm") ~ ")";
        case "chamfer-face":
            return hit.face < 0 ? null : ".chamfer(edges.of(" ~ faceSelector(it, sv, hit.face) ~ "), d: " ~ or("0.5.mm") ~ ")";
        case "shell":
            return hit.face < 0 ? null : ".shell(open: " ~ faceSelector(it, sv, hit.face) ~ ", thickness: " ~ or("2.mm") ~ ")";
        default:
            return null;
        }
    }

    void copy(string text)
    {
        import gobject.value : Value;
        window.getClipboard().set(new Value(text));
        info("copied: " ~ text);
    }

    void appendFeature(PartMesh part, string call, string placeholder)
    {
        if (busy())
            return info("wait for the evaluation to finish, then try again");
        if (part.span.file != absolutePath(path))
            return info(format("part '%s' is defined in another file", part.name));
        try
            applyEdit(appendToPart(text(), path, part.name, call, placeholder));
        catch (CodegenException e)
            info(e.msg);
        catch (HcadError e)
            info("fix the errors in the code first: " ~ e.msg);
    }

    /// Applies an edit to the buffer (one undo step) and selects its placeholder.
    void applyEdit(Edit e)
    {
        auto src = text();
        int l0, i0, l1, i1;
        lineIndex(src, e.offset, l0, i0);
        lineIndex(src, e.offset + e.length, l1, i1);
        TextIter a, b;
        buffer.getIterAtLineIndex(a, l0, i0);
        buffer.getIterAtLineIndex(b, l1, i1);
        buffer.beginUserAction();
        buffer.delete_(a, b);
        buffer.getIterAtLineIndex(a, l0, i0);
        buffer.insert(a, e.text);
        buffer.endUserAction();
        auto now = text();
        lineIndex(now, e.selectOffset, l0, i0);
        lineIndex(now, e.selectOffset + e.selectLength, l1, i1);
        buffer.getIterAtLineIndex(a, l0, i0);
        buffer.getIterAtLineIndex(b, l1, i1);
        buffer.selectRange(a, b);
        editor.scrollToIter(a, 0.1, false, 0, 0);
        editor.grabFocus();
    }

    // ---- sketch dimensions over the 3D view

    string sketchSummary()
    {
        if (last.sketches.length == 0)
            return "";
        size_t dof;
        bool conflict;
        foreach (sk; last.sketches)
        {
            dof += sk.dof;
            conflict = conflict || !sk.solved;
        }
        return conflict ? " · sketch conflicts" : dof ? format(" · sketch: %d free", dof) : " · sketches fully constrained";
    }

    void updateDimensions()
    {
        foreach (b; dimButtons)
            overlay.removeOverlay(b);
        dimButtons = null;
        dims = null;
        if (!sketchToggle.getActive())
            return;
        foreach (sk; last.sketches)
            foreach (d; sk.dimensions)
            {
                if (d.value.file != absolutePath(path))
                    continue;
                auto b = new Button;
                b.setLabel(d.label);
                b.addCssClass("osd");
                b.addCssClass("hcad-dimension");
                if (d.conflicting)
                    b.addCssClass("destructive-action");
                b.setHalign(Align.Start);
                b.setValign(Align.Start);
                b.setTooltipText(format("line %d: click to change", d.value.line));
                auto dim = d;
                b.connectClicked(() => editDimension(b, dim));
                overlay.addOverlay(b);
                dimButtons ~= b;
                dims ~= d;
            }
        positionDimensions();
    }

    void positionDimensions()
    {
        foreach (i, b; dimButtons)
        {
            double x, y;
            immutable visible = viewport.project(dims[i].at, x, y);
            b.setVisible(visible);
            if (!visible)
                continue;
            immutable mx = cast(int)(x - b.getWidth() / 2), my = cast(int)(y - b.getHeight() / 2);
            if (abs(b.getMarginStart() - mx) > 0 || abs(b.getMarginTop() - my) > 0)
            {
                b.setMarginStart(mx < 0 ? 0 : mx);
                b.setMarginTop(my < 0 ? 0 : my);
            }
        }
    }

    /// Edits the value of a dimension in place: the source is rewritten.
    void editDimension(Button b, SketchView.Dimension d)
    {
        string current;
        try
            current = argumentText(text(), path, d.value.line, d.value.col);
        catch (Exception e)
            return info(e.msg);
        auto pop = new Popover;
        pop.setParent(b);
        pop.connectClosed(() {
            idleAdd(PRIORITY_DEFAULT, () { pop.unparent(); return false; });
        });
        auto entry = new Entry;
        entry.setText(current);
        entry.setWidthChars(14);
        entry.connectActivate(() {
            auto value = entry.getText();
            pop.popdown();
            if (value.length == 0 || value == current)
                return;
            try
            {
                auto e = replaceArgument(text(), path, d.value.line, d.value.col, value);
                applyEdit(e);
                info(format("line %d: %s → %s", d.value.line, current, value));
            }
            catch (Exception ex)
                info(ex.msg);
        });
        pop.setChild(entry);
        pop.popup();
        entry.grabFocus();
    }

    void save() => saveThen(null);

    /// Saves (asking for a name when the file has none), then runs `then`.
    void saveThen(void delegate() then)
    {
        if (baseName(path) == "untitled.hcad" && !exists(path))
            return saveAs(then);
        try
        {
            write(path, text());
            diskTime = mtimeOf(path);
            modified = false;
            updateTitle();
            note("saved " ~ path);
        }
        catch (Exception e)
        {
            note("cannot save: " ~ e.msg);
            return;
        }
        if (then !is null)
            then();
    }

    void saveAs(void delegate() then = null)
    {
        auto d = new FileDialog;
        d.setInitialName(baseName(path));
        d.save(window, null, (ObjectWrap src, AsyncResult res) {
            try
            {
                auto f = d.saveFinish(res);
                if (f is null)
                    return;
                path = f.getPath();
                saveThen(then);
            }
            catch (ErrorWrap)
            {
            }
        });
    }

    bool closeConfirmed;
    long diskTime;

    /// Runs `then` once unsaved changes are saved or knowingly discarded.
    void confirmDiscard(void delegate() then)
    {
        if (!modified)
            return then();
        import adw.alert_dialog : AlertDialog;
        import adw.types : ResponseAppearance;
        auto d = new AlertDialog(format("Save changes to “%s”?", baseName(path)),
            "If you don't save, your changes will be lost.");
        d.addResponse("cancel", "_Cancel");
        d.addResponse("discard", "_Discard");
        d.addResponse("save", "_Save");
        d.setResponseAppearance("discard", ResponseAppearance.Destructive);
        d.setResponseAppearance("save", ResponseAppearance.Suggested);
        d.setDefaultResponse("save");
        d.setCloseResponse("cancel");
        d.connectResponse(null, (string response) {
            if (response == "save")
                saveThen(then);
            else if (response == "discard")
                then();
        });
        d.present(window);
    }

    static long mtimeOf(string file)
    {
        import std.file : timeLastModified;
        try
            return exists(file) ? timeLastModified(file).stdTime : 0;
        catch (Exception)
            return 0;
    }

    bool diskPrompt;

    /// Reloads the file when it changed on disk: silently if there are no
    /// local changes, otherwise after asking.
    void checkDisk()
    {
        if (diskPrompt || !exists(path))
            return;
        immutable t = mtimeOf(path);
        if (t == diskTime || diskTime == 0)
            return;
        diskTime = t;
        string disk;
        try
            disk = readText(path);
        catch (Exception)
            return;
        if (disk == text())
            return;
        if (!modified)
        {
            reloadKeepingView(disk);
            note("reloaded " ~ baseName(path) ~ ": the file changed on disk");
            return;
        }
        import adw.alert_dialog : AlertDialog;
        import adw.types : ResponseAppearance;
        diskPrompt = true;
        auto d = new AlertDialog("The file changed on disk",
            format("“%s” was modified by another program, and you have unsaved changes here.", baseName(path)));
        d.addResponse("keep", "_Keep Mine");
        d.addResponse("reload", "_Reload");
        d.setResponseAppearance("reload", ResponseAppearance.Destructive);
        d.setCloseResponse("keep");
        d.connectResponse(null, (string response) {
            diskPrompt = false;
            if (response == "reload")
                reloadKeepingView(disk);
        });
        d.present(window);
    }

    /// Replaces the text with the file's, keeping the cursor line and the parameters.
    void reloadKeepingView(string disk)
    {
        import gtk.text_mark : TextMark;
        TextIter it;
        buffer.getIterAtMark(it, buffer.getInsert());
        immutable line = it.getLine();
        buffer.setText(disk);
        TextIter at;
        if (buffer.getIterAtLine(at, line))
            buffer.placeCursor(at);
        modified = false;
        updateTitle();
    }

    void newFile()
    {
        confirmDiscard(() {
            path = buildPath(dirName(path), "untitled.hcad");
            params.overrides = null;
            params.preset = null;
            params.invalidate();
            firstResult = true;
            viewport.showAll();
            buffer.setText(newModelTemplate);
            diskTime = 0;
            modified = false;
            updateTitle();
        });
    }

    void openFile() => confirmDiscard(&chooseFile);

    void chooseFile()
    {
        auto d = new FileDialog;
        d.open(window, null, (ObjectWrap src, AsyncResult res) {
            try
            {
                auto f = d.openFinish(res);
                if (f !is null)
                    load(f.getPath());
            }
            catch (ErrorWrap)
            {
            }
        });
    }

    void load(string file)
    {
        agentText = null;
        path = file;
        params.overrides = null;
        params.preset = null;
        params.invalidate();
        firstResult = true;
        viewport.showAll();
        buffer.setText(readText(path));
        diskTime = mtimeOf(path);
        modified = false;
        updateTitle();
    }

    // ---- external control

    void showWindowName()
    {
        windowNameLabel.setLabel(control.name);
        windowName.setTooltipText("This window's name for AI agents (the 'window' of the hcad_gui_* tools). "
            ~ "Click to rename it.");
        windowName.setVisible(true);
    }

    void renameWindow()
    {
        auto pop = new Popover;
        pop.setParent(windowName);
        pop.connectClosed(() {
            idleAdd(PRIORITY_DEFAULT, () { pop.unparent(); return false; });
        });
        auto box = new Box(Orientation.Vertical, 6);
        auto hint = new Label("Name for AI agents");
        hint.addCssClass("dim-label");
        hint.setXalign(0);
        auto entry = new Entry;
        entry.setText(control.name);
        entry.setWidthChars(20);
        auto problem = new Label("");
        problem.addCssClass("error");
        problem.setXalign(0);
        problem.setVisible(false);
        entry.connectActivate(() {
            if (auto why = control.rename(entry.getText()))
            {
                problem.setLabel(why);
                problem.setVisible(true);
                return;
            }
            showWindowName();
            pop.popdown();
        });
        box.append(hint);
        box.append(entry);
        box.append(problem);
        pop.setChild(box);
        pop.popup();
        entry.grabFocus();
    }

    bool busy() => debounce != 0 || evaluator.busy || !hadResult;
    bool hadResult;   /// the first evaluation has been shown

    /// Runs `f` once the pending evaluation has finished and been drawn.
    void whenIdle(void delegate() f)
    {
        timeoutAdd(PRIORITY_DEFAULT, 50, () {
            if (busy())
                return true;
            timeoutAdd(PRIORITY_DEFAULT, 150, () { f(); return false; });
            return false;
        });
    }

    /// The code as the agent last saw it (after its previous request): what
    /// the user changed since then is reported in the state.
    string agentText;
    JSONValue userChange;
    ulong revision;     /// goes up at every change of the code

    void handleControl(string method, JSONValue p, void delegate(JSONValue, string) reply)
    {
        if (agentText !is null)
            userChange = changedLines(agentText, text());
        dispatchControl(method, p, (JSONValue r, string e) {
            agentText = text();
            userChange = JSONValue.init;
            reply(r, e);
        });
    }

    /// The lines of `after` that differ from `before` (null when equal).
    static JSONValue changedLines(string before, string after)
    {
        import std.string : splitLines;
        if (before == after)
            return JSONValue(null);
        auto a = before.splitLines, b = after.splitLines;
        size_t head, tail;
        while (head < a.length && head < b.length && a[head] == b[head])
            head++;
        while (tail < a.length - head && tail < b.length - head && a[$ - 1 - tail] == b[$ - 1 - tail])
            tail++;
        JSONValue j = ["from": head + 1, "to": b.length - tail, "replaced_lines": a.length - tail - head];
        return j;
    }

    /// The window point a request aims at: "point" [x, y, z] in model mm, or
    /// "x" and "y" as fractions of the view. Null, or what is wrong.
    string screenPoint(JSONValue p, out double x, out double y)
    {
        if ("point" in p && p["point"].type == JSONType.array)
        {
            auto v = vec3Of(p["point"]);
            double fx, fy;
            bool visible;
            if (!viewport.fractionOf(v, fx, fy, visible))
                return "that point is behind the camera";
            if (fx < 0 || fx > 1 || fy < 0 || fy > 1)
                return format("that point is outside the view (at %.2f, %.2f): move the view first", fx, fy);
            if (!visible)
                return "that point is hidden by another surface from this view: turn the view, or use a section";
            x = fx * viewport.width;
            y = fy * viewport.height;
            return null;
        }
        x = ("x" in p ? numberOf(p["x"]) : 0.5) * viewport.width;
        y = ("y" in p ? numberOf(p["y"]) : 0.5) * viewport.height;
        return null;
    }

    static double numberOf(JSONValue v) => v.type == JSONType.integer ? v.integer : v.type == JSONType.uinteger
        ? v.uinteger : v.floating;
    static Vec3 vec3Of(JSONValue v) => Vec3(numberOf(v[0]), numberOf(v[1]), v.array.length > 2 ? numberOf(v[2]) : 0);
    static JSONValue jsonOf(Vec3 v) => JSONValue([v.x, v.y, v.z]);

    /// Index of the part named `name`; without a name, the only part. -1, with `problem` set, otherwise.
    int partIndex(string name, out string problem)
    {
        foreach (i, pm; last.parts)
            if (pm.name == name || (name.length == 0 && last.parts.length == 1))
                return cast(int) i;
        import std.algorithm : map;
        problem = (name.length ? "no part '" ~ name ~ "'" : "several parts: pass part") ~ "; parts: "
            ~ last.parts.map!(pm => pm.name).join(", ");
        return -1;
    }

    /// What the view shows under window point (x, y), with a selector for it.
    JSONValue hitJson(Hit hit)
    {
        JSONValue r = ["part": hit.part >= 0 ? JSONValue(last.parts[hit.part].name) : JSONValue(null)];
        if (hit.part < 0)
            return r;
        r["face"] = hit.face;
        r["point"] = jsonOf(hit.point);
        r["normal"] = jsonOf(hit.normal);
        if (hit.face >= 0)
        {
            auto part = last.parts[hit.part];
            auto it = new Interp(part.kernel);
            auto sv = new SolidVal(part.brep, Span.init);
            sv.creators = part.creators;
            try
                r["selector"] = faceSelector(it, sv, hit.face);
            catch (Exception)
            {
            }
        }
        return r;
    }

    /// The selected faces and edges, with selectors and sizes.
    JSONValue selectionJson()
    {
        JSONValue[] items;
        foreach (h; viewport.selection())
        {
            if (h.part < 0 || h.part >= last.parts.length)
                continue;
            auto part = last.parts[h.part];
            auto it = new Interp(part.kernel);
            auto sv = new SolidVal(part.brep, Span.init);
            sv.creators = part.creators;
            JSONValue j = ["part": part.name];
            try
            {
                if (h.edge >= 0)
                {
                    auto e = part.edgeInfo[h.edge];
                    j["kind"] = "edge";
                    j["index"] = h.edge;
                    j["selector"] = edgeSelector(it, sv, h.edge);
                    j["shape"] = e.kind == EdgeKind.line ? "line" : e.kind == EdgeKind.circle ? "circle" : "curve";
                    j["start"] = jsonOf(e.start);
                    j["end"] = jsonOf(e.end);
                    if (e.kind == EdgeKind.line)
                        j["length"] = (e.end - e.start).length;
                    if (e.kind == EdgeKind.circle)
                    {
                        j["radius"] = e.radius;
                        j["center"] = jsonOf(e.center);
                    }
                }
                else if (h.face >= 0)
                {
                    auto f = part.kernel.faces(part.brep)[h.face];
                    j["kind"] = "face";
                    j["index"] = h.face;
                    j["selector"] = faceSelector(it, sv, h.face);
                    j["center"] = jsonOf(f.center);
                    j["normal"] = jsonOf(f.normal);
                    j["area"] = f.area;
                }
            }
            catch (Exception e)
                j["problem"] = e.msg;
            items ~= j;
        }
        return JSONValue(["selection": JSONValue(items)]);
    }

    /// A measured item: a part name, a point [x, y, z], or (null) the next selected item.
    string measureItem(JSONValue v, ref size_t nextSelected, out Item item, out int wholePart)
    {
        import hackerscad.gui.measure : faceItem, edgeItem, pointItem;
        wholePart = -1;
        if (v.type == JSONType.array)
        {
            item = pointItem(vec3Of(v));
            return null;
        }
        if (v.type == JSONType.string)
        {
            string problem;
            immutable i = partIndex(v.str, problem);
            if (i < 0)
                return problem;
            wholePart = i;
            auto pm = last.parts[i];
            foreach (f; 0 .. cast(int) pm.faceStart.length - 1)
            {
                auto fi = faceItem(pm, f);
                item.triangles ~= fi.triangles;
                item.points ~= fi.points;
            }
            return null;
        }
        auto sel = viewport.selection();
        if (nextSelected >= sel.length)
            return "select two items first (hcad_gui_selection or Shift+click), or pass a and b";
        auto h = sel[nextSelected++];
        item = h.edge >= 0 ? edgeItem(last.parts[h.part], h.edge) : faceItem(last.parts[h.part], h.face);
        return null;
    }

    /// A menu as JSON: entries with their label, value and sub-entries; headings as titles.
    static JSONValue menuJson(MenuEntry[] entries)
    {
        JSONValue[] r;
        foreach (e; entries)
        {
            final switch (e.kind)
            {
            case MenuEntry.Kind.separator:
                continue;
            case MenuEntry.Kind.heading:
                r ~= JSONValue(["heading": e.label ~ (e.detail.length ? " · " ~ e.detail : "")]);
                continue;
            case MenuEntry.Kind.item, MenuEntry.Kind.group:
                break;
            }
            JSONValue j = ["label": e.label];
            if (e.detail.length)
                j["value"] = e.detail;
            if (!e.enabled)
                j["enabled"] = false;
            if (e.kind == MenuEntry.Kind.group)
                j["entries"] = menuJson(e.children);
            r ~= j;
        }
        return JSONValue(r);
    }

    /// The executable on disk is not the one running (rebuilt or updated).
    bool exeChanged()
    {
        if (exeAtStart.length == 0)
            return false;
        try
            return mtimeOf(exeAtStart) != exeTimeAtStart;
        catch (Exception)
            return false;
    }

    string exeAtStart;
    long exeTimeAtStart;

    void dispatchControl(string method, JSONValue p, void delegate(JSONValue, string) reply)
    {
        string arg(string k) => k in p && p[k].type == JSONType.string ? p[k].str : null;
        bool has(string k) => k in p && p[k].type != JSONType.null_;
        switch (method)
        {
        case "open":
            {
                auto file = absolutePath(arg("path"));
                if (!exists(file))
                    return reply(JSONValue.init, "file not found: " ~ file);
                if (modified && !("force" in p && p["force"].type == JSONType.true_))
                    return reply(JSONValue.init, "the user has unsaved changes in " ~ baseName(path)
                        ~ ": ask them to save, or pass force: true to discard them");
                load(file);
                whenIdle(() => reply(state(), null));
                return;
            }
        case "set":
            if (auto s = arg("source"))
                buffer.setText(s);
            if ("params" in p)
                foreach (k, v; toOverrides(p["params"]))
                    params.overrides[k] = v;
            if ("preset" in p)
            {
                params.preset = arg("preset");
                params.overrides = null;
            }
            params.invalidate();
            firstResult = true; // frame the changed model
            scheduleEvaluation(0);
            whenIdle(() => reply(state(), null));
            return;
        case "state":
            // after the running evaluation, or right away with "now": true
            // (then "evaluating" and "stage" tell how far it is)
            {
                immutable withSource = "source" in p && p["source"].type == JSONType.true_;
                JSONValue full()
                {
                    auto j = state();
                    if (withSource)
                        j["source"] = text();
                    return j;
                }
                if ("now" in p && p["now"].type == JSONType.true_)
                    reply(full(), null);
                else
                    whenIdle(() => reply(full(), null));
                return;
            }
        case "pick":
            {
                // click in the 3D view: at x, y (fractions of its size) or at a model point
                immutable shiftPick = "shift" in p && p["shift"].type == JSONType.true_;
                whenIdle(() {
                    double x, y;
                    if (auto problem = screenPoint(p, x, y))
                        return reply(JSONValue.init, problem);
                    auto hit = viewport.pickAt(x, y);
                    hit.shift = shiftPick;   // add to the selection, as Shift+click
                    picked(hit);
                    auto r = hitJson(hit);
                    r["status"] = infoLabel.getLabel();
                    reply(r, null);
                });
                return;
            }
        case "view":
            {
                import std.conv : to;
                alias num = numberOf;
                // in the order a user would: frame, turn, move, zoom
                if (auto v = arg("preset"))
                {
                    if (v == "fit")
                        viewport.fit();
                    else
                        viewport.setView(v.to!ViewPreset);
                }
                // centred on a model point, `size` mm across the view
                if (has("look_at") || has("size"))
                    viewport.centerOn(has("look_at") ? vec3Of(p["look_at"]) : viewport.camera().target,
                        has("size") ? num(p["size"]) : 0);
                if (has("orbit"))
                    viewport.orbit(num(p["orbit"][0]), num(p["orbit"][1]));
                if (has("pan"))
                    viewport.pan(num(p["pan"][0]), num(p["pan"][1]));
                // zoom: > 1 moves away, < 1 closer; at a point like the wheel
                if (has("zoom"))
                {
                    if (has("at"))
                        viewport.zoomAtFraction(num(p["at"][0]), num(p["at"][1]), num(p["zoom"]));
                    else
                        viewport.zoom(num(p["zoom"]));
                }
                // the parts hidden with their eye in the parameters panel
                if (has("hidden"))
                {
                    bool[string] hide;
                    foreach (n; p["hidden"].array)
                        hide[n.str] = true;
                    foreach (i, pm; last.parts)
                        setPartVisible(i, (pm.name in hide) is null);
                }
                if (has("console"))
                    consoleToggle.setActive(p["console"].type == JSONType.true_);
                if (has("params"))
                    paramsToggle.setActive(p["params"].type == JSONType.true_);
                whenIdle(() => reply(state(), null));
                return;
            }
        case "feature":
            {
                // {"x": 0.5, "y": 0.4, "action": "fillet-edge", "value": "2.mm"}: what the context menu does
                auto act = arg("action"), value = arg("value");
                whenIdle(() {
                    double x, y;
                    if (auto problem = screenPoint(p, x, y))
                        return reply(JSONValue.init, problem);
                    auto hit = viewport.pickAt(x, y);
                    if (hit.part < 0)
                        return reply(JSONValue.init, "nothing under that point");
                    hit.edge = viewport.nearestEdge(hit.part, hit.face, x, y, 12);
                    auto code = featureCode(hit, act, value);
                    if (code.length == 0)
                        return reply(JSONValue.init, "unknown action or no edge there: use fillet-edge, chamfer-edge, "
                            ~ "fillet-face, chamfer-face or shell");
                    appendFeature(last.parts[hit.part], code, null);
                    whenIdle(() {
                        auto r = state();
                        r["added"] = code;
                        reply(r, null);
                    });
                });
                return;
            }
        case "context":
            {
                // {"x": 0.5, "y": 0.5} or {"point": [x, y, z]}: opens the right-click menu there
                auto file = arg("path");
                whenIdle(() {
                    double x, y;
                    if (auto problem = screenPoint(p, x, y))
                        return reply(JSONValue.init, problem);
                    contextMenu(viewport.pickAt(x, y), x, y);
                    if (file.length && contextPopover !is null)
                        timeoutAdd(PRIORITY_DEFAULT, 400, () {
                            // the menu is a surface of its own: render it alone
                            import gtk.widget_paintable : WidgetPaintable;
                            import gtk.snapshot : Snapshot;
                            auto paintable = new WidgetPaintable(contextPopover);
                            auto snap = new Snapshot;
                            paintable.snapshot(snap, contextPopover.getWidth() + 40, contextPopover.getHeight() + 40);
                            if (auto node = snap.toNode())
                                contextPopover.getNative().getRenderer().renderTexture(node, null).saveToPng(file);
                            reply(state(), null);
                            return false;
                        });
                    else
                        reply(state(), null);
                });
                return;
            }
        case "menu":
            {
                // {"x": 0.5, "y": 0.5, "path": ["Hole at point", "Clearance", "M3"]}: the right-click menu there,
                // then its entries clicked in order; without path, the entries it has there
                string[] path;
                if ("path" in p && p["path"].type == JSONType.array)
                    foreach (v; p["path"].array)
                        path ~= v.str;
                immutable list = !("path" in p) || path.length == 0;
                whenIdle(() {
                    double x, y;
                    if (auto problem = screenPoint(p, x, y))
                        return reply(JSONValue.init, problem);
                    auto hit = viewport.pickAt(x, y);
                    if (hit.part < 0)
                        return reply(JSONValue.init, "nothing under that point: the menu opens on a part");
                    contextMenu(hit, x, y);
                    if (list)
                    {
                        auto entries = lastMenuEntries();
                        closeLastMenu();
                        return reply(JSONValue(["entries": menuJson(entries)]), null);
                    }
                    if (auto problem = activateMenuPath(path))
                        return reply(JSONValue.init, problem);
                    whenIdle(() => reply(state(), null));
                });
                return;
            }
        case "section":
            {
                // {"plane": "xy" | "xz" | "yz" | "face", "at": 0..1 along the model, "flip": false}; {"on": false} hides it
                if ("on" in p && p["on"].type == JSONType.false_)
                {
                    sectionToggle.setActive(false);
                    whenIdle(() => reply(state(), null));
                    return;
                }
                immutable planes = ["xy", "xz", "yz", "face"];
                import std.algorithm : countUntil;
                auto which = arg("plane").length ? planes.countUntil(arg("plane")) : 0;
                if (which < 0)
                    return reply(JSONValue.init, "plane must be xy, xz, yz or face");
                sectionUpdating = true;
                sectionPlane.setSelected(cast(uint) which);
                sectionUpdating = false;
                sectionToggle.setActive(true);
                updateSection(true);
                if ("at" in p)
                {
                    auto adj = sectionSlider.getAdjustment();
                    sectionSlider.setValue(adj.getLower() + p["at"].get!double * (adj.getUpper() - adj.getLower()));
                }
                if ("flip" in p && p["flip"].type == JSONType.true_)
                    sectionFlip.setActive(true);
                whenIdle(() {
                    auto r = state();
                    r["section"] = sectionLabel.getLabel();
                    reply(r, null);
                });
                return;
            }
        case "sketch":
            // {"on": true}: show the sketches with their dimensions
            sketchToggle.setActive("on" !in p || p["on"].type != JSONType.false_);
            whenIdle(() => reply(state(), null));
            return;
        case "rollback":
            {
                // {"line": 12}: the model right after the feature on that line; no line: the final model
                if ("line" !in p)
                {
                    viewport.clearRollback();
                    features.clearSelection();
                    whenIdle(() => reply(state(), null));
                    return;
                }
                immutable line = cast(uint) p["line"].get!long;
                uint id;
                foreach (i, f; last.features)
                    if (f.span.line == line && f.span.file == absolutePath(path))
                        id = cast(uint)(i + 1);
                if (id == 0)
                    return reply(JSONValue.init, format("no feature on line %d", line));
                rollTo(id);
                whenIdle(() => reply(state(), null));
                return;
            }
        case "export":
            {
                // the window's model as shown (parameters, preset): .3mf .stl .step .png
                auto file = arg("path");
                if (file is null)
                    return reply(JSONValue.init, "missing 'path'");
                whenIdle(() {
                    try
                    {
                        exportTo(file);
                        note("exported " ~ file);
                        reply(JSONValue(["path": file]), null);
                    }
                    catch (Exception e)
                        reply(JSONValue.init, e.msg);
                });
                return;
            }
        case "complete":
            {
                // what the completion list shows at the cursor, or at line/col (1-based)
                import std.utf : toUTFindex;
                import hackerscad.tool.complete : complete;
                auto src = text();
                size_t at;
                if ("line" in p)
                {
                    TextIter it;
                    buffer.getIterAtLineOffset(it, cast(int) p["line"].integer - 1,
                        "col" in p ? cast(int) p["col"].integer - 1 : 0);
                    at = toUTFindex(src, it.getOffset());
                    if ("show" in p && p["show"].boolean)
                    {
                        buffer.placeCursor(it);
                        editor.scrollToMark(buffer.getInsert(), 0, true, 0, 0.35);
                        editor.getHadjustment().setValue(0);
                    }
                }
                else
                {
                    TextIter it;
                    buffer.getIterAtMark(it, buffer.getInsert());
                    at = toUTFindex(src, it.getOffset());
                }
                auto r = complete(src, at, path, completion.libraryDirs);
                JSONValue[] items;
                foreach (c; r.items[0 .. $ < 50 ? $ : 50])
                    items ~= JSONValue(["label": c.label, "kind": c.kind, "detail": c.detail, "doc": c.doc]);
                JSONValue j = ["prefix": r.prefix];
                j["items"] = items;
                if (r.signature.length)
                {
                    j["signature"] = r.signature;
                    j["activeParam"] = r.activeParam;
                }
                if ("show" in p && p["show"].boolean)
                {
                    // the list as the user would see it, in the window
                    editor.grabFocus();
                    completion.open();
                    if (auto sel = arg("select"))
                        completion.select(sel);
                }
                reply(j, null);
                return;
            }
        case "cheatsheet":
            showCheatsheet();
            if (auto q = arg("query"))
                cheatsheet.search(q);
            reply(JSONValue(["opened": true]), null);
            return;
        case "save":
            {
                // to the window's file, or to path (then the window follows it, like Save As)
                auto target = arg("path").length ? absolutePath(arg("path")) : path;
                if (baseName(target) == "untitled.hcad" && !exists(target))
                    return reply(JSONValue.init, "the model has no file yet: pass path");
                if (target != path && exists(target) && !("force" in p && p["force"].type == JSONType.true_))
                    return reply(JSONValue.init, target ~ " exists: pass force: true to overwrite it (ask the user first)");
                try
                    write(target, text());
                catch (Exception e)
                    return reply(JSONValue.init, "cannot save: " ~ e.msg);
                path = target;
                diskTime = mtimeOf(path);
                modified = false;
                updateTitle();
                note("saved " ~ path);
                return reply(state(), null);
            }
        case "edit":
            {
                // a change of the code, as the user would type it (it can be undone):
                // {"old": "…", "new": "…"} | {"lines": [from, to], "text": "…"} | {"insert": line, "text": "…"}
                import std.string : indexOf;
                import std.utf : count;
                auto src = text();
                TextIter a, b;
                string with_;
                immutable lineCount = buffer.getLineCount();
                if (has("old"))
                {
                    auto old = arg("old");
                    auto at = src.indexOf(old);
                    if (old.length == 0 || at < 0)
                        return reply(JSONValue.init, "'old' is not in the code (hcad_gui_state with source: true shows it)");
                    if (src[at + old.length .. $].indexOf(old) >= 0)
                        return reply(JSONValue.init, "'old' appears more than once: include more of the code around it");
                    buffer.getIterAtOffset(a, cast(int) count(src[0 .. at]));
                    buffer.getIterAtOffset(b, cast(int) count(src[0 .. at + old.length]));
                    with_ = arg("new");
                }
                else if (has("lines") || has("insert"))
                {
                    immutable from = cast(int) numberOf(has("lines") ? p["lines"][0] : p["insert"]);
                    immutable to = has("lines") ? cast(int) numberOf(p["lines"][1]) : from - 1;
                    if (from < 1 || from > lineCount + 1 || to < from - 1 || to > lineCount)
                        return reply(JSONValue.init, format("lines out of range: the code has %d lines", lineCount));
                    with_ = arg("text");
                    if (from > lineCount)
                        buffer.getEndIter(a);
                    else
                        buffer.getIterAtLine(a, from - 1);
                    if (to >= lineCount)
                    {
                        buffer.getEndIter(b);
                        // appending after a last line without newline
                        if (from > lineCount && src.length && src[$ - 1] != '\n')
                            with_ = "\n" ~ with_;
                    }
                    else
                    {
                        buffer.getIterAtLine(b, to);
                        if (with_.length && with_[$ - 1] != '\n')
                            with_ ~= "\n";
                    }
                }
                else
                    return reply(JSONValue.init, "pass old and new, lines and text, or insert and text");
                immutable startOffset = a.getOffset();
                buffer.beginUserAction();
                buffer.delete_(a, b);
                buffer.getIterAtOffset(a, startOffset);
                buffer.insert(a, with_);
                buffer.endUserAction();
                // show the new code where it is
                TextIter s, e;
                buffer.getIterAtOffset(s, startOffset);
                buffer.getIterAtOffset(e, startOffset + cast(int) count(with_));
                immutable first = s.getLine() + 1, lastLine = e.getLine() + (e.getLineOffset() == 0 && e.getOffset() > s.getOffset() ? 0 : 1);
                TextIter all0, all1;
                buffer.getBounds(all0, all1);
                buffer.removeTagByName("picked", all0, all1);
                buffer.applyTagByName("picked", s, e);
                buffer.placeCursor(s);
                editor.scrollToIter(s, 0.1, true, 0, 0.3);
                whenIdle(() {
                    auto r = state();
                    r["lines"] = [first, max(first, lastLine)];
                    reply(r, null);
                });
                return;
            }
        case "undo":
            {
                // {"redo": true} redoes; "steps" repeats
                immutable redo = "redo" in p && p["redo"].type == JSONType.true_;
                immutable steps = has("steps") ? cast(int) numberOf(p["steps"]) : 1;
                int done;
                foreach (i; 0 .. steps)
                {
                    if (redo ? !buffer.getCanRedo() : !buffer.getCanUndo())
                        break;
                    if (redo)
                        buffer.redo();
                    else
                        buffer.undo();
                    done++;
                }
                if (done == 0)
                    return reply(JSONValue.init, redo ? "nothing to redo" : "nothing to undo");
                whenIdle(() {
                    auto r = state();
                    r[redo ? "redone" : "undone"] = done;
                    reply(r, null);
                });
                return;
            }
        case "project":
            {
                // model points to view fractions ("points"), view fractions to what is there ("screen")
                whenIdle(() {
                    JSONValue r = JSONValue((JSONValue[string]).init);
                    if (has("points"))
                    {
                        JSONValue[] out_;
                        foreach (v; p["points"].array)
                        {
                            double fx, fy;
                            bool visible;
                            if (viewport.fractionOf(vec3Of(v), fx, fy, visible))
                            {
                                JSONValue j = ["x": fx, "y": fy];
                                j["visible"] = visible && fx >= 0 && fx <= 1 && fy >= 0 && fy <= 1;
                                out_ ~= j;
                            }
                            else
                                out_ ~= JSONValue(["behind_camera": true]);
                        }
                        r["points"] = out_;
                    }
                    if (has("screen"))
                    {
                        JSONValue[] out_;
                        foreach (v; p["screen"].array)
                            out_ ~= hitJson(viewport.pickAt(numberOf(v[0]) * viewport.width, numberOf(v[1]) * viewport.height));
                        r["screen"] = out_;
                    }
                    reply(r, null);
                });
                return;
            }
        case "selection":
            {
                // {"selector": "faces.top", "part": "lid"} selects, {"clear": true} empties; always the selection back
                whenIdle(() {
                    if ("clear" in p && p["clear"].type == JSONType.true_)
                        viewport.setSelection(null);
                    if (auto expr = arg("selector"))
                    {
                        string problem;
                        immutable pi = partIndex(arg("part"), problem);
                        if (pi < 0)
                            return reply(JSONValue.init, problem);
                        auto part = last.parts[pi];
                        auto it = new Interp(part.kernel);
                        auto sv = new SolidVal(part.brep, Span.init);
                        sv.creators = part.creators;
                        bool faces;
                        int[] found;
                        try
                            found = it.trySelector(expr, sv, faces);
                        catch (Exception e)
                            return reply(JSONValue.init, e.msg);
                        if (found.length == 0)
                            return reply(JSONValue.init, expr ~ " selects nothing on " ~ part.name);
                        auto infos = faces ? part.kernel.faces(part.brep) : null;
                        Hit[] hits;
                        foreach (i; found)
                        {
                            Hit h;
                            h.part = pi;
                            if (faces)
                            {
                                h.face = i;
                                h.point = infos[i].center;
                                h.normal = infos[i].normal;
                            }
                            else
                            {
                                h.edge = i;
                                h.point = part.edgeInfo[i].mid;
                            }
                            hits ~= h;
                        }
                        viewport.setSelection(hits);
                        info(format("%s · %d %s%s selected by the agent", part.name, hits.length, faces ? "face" : "edge",
                            hits.length == 1 ? "" : "s"));
                    }
                    reply(selectionJson(), null);
                });
                return;
            }
        case "measure":
            {
                // between a and b (part names or points [x, y, z]), or the two selected items
                whenIdle(() {
                    import hackerscad.gui.measure : measure;
                    size_t next;
                    Item ia, ib;
                    int pa, pb;
                    if (auto problem = measureItem(has("a") ? p["a"] : JSONValue(null), next, ia, pa))
                        return reply(JSONValue.init, problem);
                    if (auto problem = measureItem(has("b") ? p["b"] : JSONValue(null), next, ib, pb))
                        return reply(JSONValue.init, problem);
                    JSONValue r;
                    if (pa >= 0 && pb >= 0)
                    {
                        // two parts: exact, on the solids
                        Vec3 onA, onB;
                        auto d = last.parts[pa].kernel.distance(last.parts[pa].brep, last.parts[pb].brep, onA, onB);
                        r = JSONValue(["distance": d]);
                        r["on_a"] = jsonOf(onA);
                        r["on_b"] = jsonOf(onB);
                    }
                    else
                    {
                        auto m = measure(ia, ib);
                        r = JSONValue(["distance": m.distance]);
                        r["on_a"] = jsonOf(m.onA);
                        r["on_b"] = jsonOf(m.onB);
                        if (m.angle == m.angle)
                            r["angle_deg"] = m.angle;
                        if (m.gap == m.gap)
                            r["gap"] = m.gap;
                        r["note"] = "from the displayed mesh: curved surfaces are approximated";
                    }
                    reply(r, null);
                });
                return;
            }
        case "stop":
            {
                immutable was = evaluator.busy;
                if (was)
                    stopEvaluation();
                reply(JSONValue(["stopped": was]), null);
                return;
            }
        case "about":
            showAbout();
            reply(JSONValue(["opened": true]), null);
            return;
        case "screenshot":
            {
                auto file = arg("path");
                if (file is null)
                    return reply(JSONValue.init, "missing 'path'");
                // the cheatsheet window, when asked for and open
                auto other = arg("window") == "cheatsheet" && cheatsheet !is null ? cheatsheet.widget : null;
                whenIdle(() {
                    if (screenshot(file, other))
                        reply(JSONValue(["path": file]), null);
                    else
                        reply(JSONValue.init, "the window has not been drawn: is the screen locked?");
                });
                return;
            }
        default:
            reply(JSONValue.init, "unknown method: " ~ method);
        }
    }

    JSONValue state()
    {
        JSONValue j = ["path": path, "status": statusText];
        j["window"] = control ? control.name : null;
        j["version"] = appVersion;
        if (exeChanged())
            j["outdated"] = "hackerscad was rebuilt or updated after this window started: ask the user to restart it "
                ~ "to get the newest tools";
        j["revision"] = revision;
        if (userChange.type != JSONType.null_)
            j["user_changed"] = userChange;
        j["evaluating"] = evaluator.busy;
        if (evaluator.busy)
        {
            j["stage"] = stage;
            j["seconds"] = (MonoTime.currTime - evalStart).total!"msecs" / 1000.0;
        }
        j["modified"] = modified;
        j["preset"] = params.preset;
        JSONValue[string] ov;
        foreach (k, v; params.overrides)
            ov[k] = v;
        j["overrides"] = ov;
        JSONValue[] parts;
        foreach (pm; last.parts)
        {
            JSONValue jp = ["name": pm.name, "color": format("#%06X", pm.rgb)];
            jp["size"] = [pm.bbox.size.x, pm.bbox.size.y, pm.bbox.size.z];
            jp["volume_mm3"] = pm.volume;
            jp["line"] = pm.span.line;
            jp["hidden"] = viewport.isHidden(parts.length);
            parts ~= jp;
        }
        j["parts"] = parts;
        JSONValue[] ps;
        foreach (pi; last.params)
        {
            JSONValue jp = ["name": pi.name, "value": pi.value.toString];
            if (pi.doc.length)
                jp["doc"] = pi.doc;
            ps ~= jp;
        }
        j["params"] = ps;
        j["presets"] = last.presets;
        auto cam = viewport.camera();
        JSONValue jc = ["yaw": cam.yaw, "pitch": cam.pitch, "distance": cam.distance];
        jc["target"] = [cam.target.x, cam.target.y, cam.target.z];
        j["camera"] = jc;
        string problems;
        foreach (d; last.diagnostics)
            problems ~= render(d, last.sources.get(d.span.file, ""));
        j["problems"] = problems;
        string log;
        foreach (l; last.log)
            log ~= l.text ~ "\n";
        j["log"] = log;
        return j;
    }

    /// The export formats, as the menus show them.
    static immutable ExportFormat[] exportFormats = [
        ExportFormat("3mf", "3MF", "one object per part, with colours: for slicers"),
        ExportFormat("stl", "STL", "one mesh: for any slicer"),
        ExportFormat("step", "STEP", "exact solids: for other CAD programs"),
        ExportFormat("png", "PNG", "a picture of the parts"),
    ];
    string exportFormat = "3mf";

    // one call per format: closures made in a loop would share its variable
    void exportAction(AdwApplication app, string ext)
    {
        action(app, "export-" ~ ext, [], () => exportFile(ext));
    }

    import gio.menu : GMenu = Menu;
    GMenu exportModel()
    {
        auto m = new GMenu;
        foreach (f; exportFormats)
            m.append(f.label ~ " — " ~ f.what, "win.export-" ~ f.ext);
        return m;
    }

    /// The export button: a menu of the formats.
    Widget exportMenu()
    {
        import gtk.menu_button : MenuButton;
        auto b = new MenuButton;
        b.setIconName("document-send-symbolic");
        b.setTooltipText("Export: 3MF, STL, STEP or PNG (Ctrl+E repeats the last format)");
        b.setMenuModel(exportModel());
        return b;
    }

    void exportFile(string ext)
    {
        import gtk.file_filter : FileFilter;
        import std.algorithm : find;
        if (last.parts.length == 0)
            return;
        exportFormat = ext;
        auto format = exportFormats.find!(f => f.ext == ext)[0];
        auto d = new FileDialog;
        d.setTitle("Export " ~ format.label);
        // every format in the dialog's list, the chosen one selected
        import gio.list_store : ListStore;
        auto filters = new ListStore(FileFilter._getGType());
        foreach (f; exportFormats)
        {
            auto filter = new FileFilter;
            filter.setName(f.label ~ " — " ~ f.what ~ " (*." ~ f.ext ~ ")");
            filter.addSuffix(f.ext);
            if (f.ext == "step")
                filter.addSuffix("stp");
            filters.append(filter);
            if (f.ext == ext)
                d.setDefaultFilter(filter);
        }
        d.setFilters(filters);
        immutable base = baseName(path).endsWith(".hcad") ? baseName(path)[0 .. $ - 5] : "model";
        d.setInitialName(base ~ "." ~ ext);
        d.save(window, null, (ObjectWrap src, AsyncResult res) {
            try
            {
                auto f = d.saveFinish(res);
                if (f is null)
                    return;
                auto out_ = f.getPath();
                // the format comes from the name; without a known extension, the chosen one
                immutable given = extension(out_).toLower;
                if (![".3mf", ".stl", ".step", ".stp", ".png"].canFind(given))
                    out_ ~= "." ~ ext;
                exportFormat = given.length > 1 && [".3mf", ".stl", ".step", ".png"].canFind(given) ? given[1 .. $] : ext;
                exportTo(out_);
                note("exported " ~ out_);
            }
            catch (ErrorWrap)
            {
            }
            catch (Exception e)
                note("export failed: " ~ e.msg);
        });
    }

    void exportTo(string out_)
    {
        import std.algorithm : filter;
        import std.array : array;
        // reference parts (export: false) only appear in pictures
        if (last.parts.length == 0)
            throw new Exception("nothing to export: the model has no parts yet");
        auto parts = extension(out_).toLower == ".png" ? last.parts : last.parts.filter!(p => p.export_).array;
        if (parts.length == 0)
            throw new Exception("nothing to export: every part has export: false");
        switch (extension(out_).toLower)
        {
        case ".stl":
            Mesh all;
            foreach (p; parts)
            {
                immutable base = cast(uint) all.vertexCount;
                all.verts ~= p.welded.verts;
                foreach (t; p.welded.tris)
                    all.tris ~= t + base;
            }
            writeStl(all, out_);
            break;
        case ".step", ".stp":
            auto k = parts[0].kernel;
            auto acc = parts[0].brep;
            foreach (p; parts[1 .. $])
                acc = k.boolean(acc, p.brep, BoolOp.fuse);
            k.writeStep(acc, out_);
            break;
        case ".png":
            {
                // the 3D view as it is, drawn by OpenGL at twice its size
                immutable w = max(640, viewport.area.getWidth() * 2), h = max(480, viewport.area.getHeight() * 2);
                auto pixels = viewport.renderImage(w, h);
                if (pixels !is null)
                {
                    write(out_, encodePng(pixels, w, h));
                    break;
                }
                // without OpenGL: the software renderer, with the view's normals
                Shaded[] shaded;
                foreach (p; parts)
                {
                    Mesh faces;
                    foreach (v; 0 .. p.vertices.length / 6)
                        faces.verts ~= p.vertices[v * 6 .. v * 6 + 3];
                    faces.tris = p.indices.dup;
                    shaded ~= Shaded(p.welded, p.rgb, faces);
                }
                auto img = render(shaded, View.iso, 1200, 800);
                write(out_, encodePng(img.rgb, img.width, img.height));
                break;
            }
        default:
            Part[] ps;
            foreach (p; parts)
                ps ~= Part(p.name, p.welded, p.rgb);
            write3mf(ps, extension(out_).length ? out_ : out_ ~ ".3mf");
        }
    }
}
