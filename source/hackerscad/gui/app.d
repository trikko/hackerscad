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
import std.math : abs, PI, round;
import std.algorithm : min, max, canFind, clamp;

import adw.application : AdwApplication = Application;
import adw.application_window : ApplicationWindow;
import adw.header_bar : HeaderBar;
import adw.toolbar_view : ToolbarView;
import adw.window_title : WindowTitle;
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
import gtk.types : Orientation, Align, WrapMode, Justification;
import gtksource.view : SourceView = View;
import gtksource.buffer : SourceBuffer = Buffer;
import gtksource.language_manager : LanguageManager;
import gtksource.style_scheme_manager : StyleSchemeManager;
import pango.types : Underline, EllipsizeMode;
import adw.view_stack : ViewStack;
import adw.view_switcher : ViewSwitcher;
import adw.types : ColorScheme, ViewSwitcherPolicy;
import adw.style_manager : StyleManager;
import gtk.menu_button : MenuButton;
import gtk.overlay : Overlay;
import hackerscad.gui.editortools : EditorTools;
import gtk.popover : Popover;
import gtk.entry : Entry;
import gtk.drop_down : DropDown;
import gtk.scale : Scale;
import gtk.gesture_click : GestureClick;
import gtk.event_controller_key : EventControllerKey;
import gtk.event_controller_motion : EventControllerMotion;
import gdk.types : ModifierType, KEY_Escape, KEY_space, KEY_Return, KEY_KP_Enter, KEY_Control_L, KEY_Control_R,
    KEY_Meta_L, KEY_Meta_R, KEY_a, KEY_A, KEY_x, KEY_X, KEY_Delete, KEY_BackSpace;
import hackerscad.geom.vec : BBox, Vec3;
import glib.global : idleAdd;

import hackerscad.geom.mesh;
import hackerscad.kernel.brep : EdgeKind;
import hackerscad.examples : examples, exampleNames;
import hackerscad.tool.codegen : transformPart;
import hackerscad.lang.errors;
import hackerscad.io.stl;
import hackerscad.lang.threading : ThreadSpec, allThreads, fits;
import hackerscad.io.threemf;
import hackerscad.render.raster;
import hackerscad.render.png;
import hackerscad.gui.evaluator;
import hackerscad.gui.viewport;
import hackerscad.gui.params;
import hackerscad.gui.control;
import hackerscad.gui.steps;
import hackerscad.gui.controlmethods : ControlMethods;
import hackerscad.gui.menu;
import hackerscad.gui.measure : Item;
import hackerscad.tool.codegen;
import hackerscad.about;
import hackerscad.gui.completion;
import hackerscad.gui.cheatsheet;
import hackerscad.lang.interp : Interp, TraceEntry, FunctionInfo, callsOf;
import hackerscad.lang.value : Kind, SolidVal;
import hackerscad.lang.sketchval : SketchView, Stretch;
import hackerscad.gui.sketchfollow;
import hackerscad.gui.sketchedit;
import hackerscad.gui.annotate : Annotate;
import hackerscad.tool.guiclient : toOverrides;
import djson;

/// The key held to click a line of code and see what it makes: Ctrl, and
/// Cmd on macOS, where Ctrl+click is the right click.
version (OSX)
{
    enum inspectClick = ModifierType.MetaMask;
    static immutable uint[] inspectKeys = [KEY_Meta_L, KEY_Meta_R];
    /// The key of the shortcuts, as the tooltips name it.
    enum shortcutKey = "Cmd";
}
else
{
    enum inspectClick = ModifierType.ControlMask;
    static immutable uint[] inspectKeys = [KEY_Control_L, KEY_Control_R];
    enum shortcutKey = "Ctrl";
}

/// What the window opens on when there is no file: a small model that
/// shows the main ideas.
enum startModel = import("00_carlo.hcad");

/// What New starts with: Carlo, to replace with one's own model.
enum newModelTemplate = `// Delete this and write your own model in its place.

import std.shapes;
import carlo;

@part
Solid body()
{
    return carlo();
}
`;

/// Linux: the shell (GNOME, KDE on Wayland) shows the icon of a window only
/// through the desktop entry named like the application id. When no package
/// installed one, write it in ~/.local/share, pointing at this executable or
/// AppImage; kept up to date when the AppImage moves, never touching an entry
/// someone else wrote.
version (linux) void installDesktopEntry()
{
    import std.array : split;
    import std.file : mkdirRecurse, copy, readText, write, exists;
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
            // GNOME Shell keeps the icons it drew in memory, by name, until the
            // applications folder changes: writing the entry again makes it reload
            if (exists(entry))
                write(entry, text);
        }
    }
    catch (Exception)
    {
        // a read-only home: the window just has no icon in the shell
    }
}

version (Windows)
{
    extern (C) private int _putenv_s(const(char)* name, const(char)* value) nothrow @nogc;
    extern (C) private int _wputenv_s(const(wchar)* name, const(wchar)* value) nothrow @nogc;
}

/// Whether hackerscad runs under Wine (its ntdll has wine_get_version).
bool underWine()
{
    version (Windows)
    {
        import core.sys.windows.windows : GetModuleHandleA, GetProcAddress;
        auto ntdll = GetModuleHandleA("ntdll.dll");
        return ntdll !is null && GetProcAddress(ntdll, "wine_get_version") !is null;
    }
    else
        return false;
}

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
        // WORKAROUND (Mesa, MSYS2 CLANG64 build): its default on Windows,
        // D3D12 on top of WARP, does not draw. To see whether a newer Mesa
        // still needs it: on Windows without 3D acceleration (a virtual
        // machine), start with HCAD_GL=software and these two lines left
        // out; if the 3D view draws, they can go
        SetEnvironmentVariableW("GALLIUM_DRIVER"w.ptr, "llvmpipe"w.ptr);
        _putenv_s("GALLIUM_DRIVER", "llvmpipe");
    }
}

version (Windows)
{
    /// Text laid out with fontconfig, in Adwaita Sans and Mono from the
    /// package (share\fonts\adwaita, etc\fonts), as on Linux: with
    /// DirectWrite, Windows' own way, the letters are smaller (Segoe UI, 9
    /// points) and under Wine every label takes ages to draw. Set before GTK
    /// starts; a value already set is kept (PANGOCAIRO_BACKEND=win32 brings
    /// DirectWrite back).
    pragma(crt_constructor)
    extern (C) private void hcadFonts() nothrow @nogc
    {
        import core.sys.windows.windows : GetEnvironmentVariableW, GetModuleFileNameW, MAX_PATH,
            SetEnvironmentVariableW;
        wchar[8] v;
        if (GetEnvironmentVariableW("PANGOCAIRO_BACKEND"w.ptr, v.ptr, cast(uint) v.length) != 0)
            return;
        // the folder of the package: bin\..
        wchar[MAX_PATH + 32] dir;
        auto n = GetModuleFileNameW(null, dir.ptr, MAX_PATH);
        while (n > 0 && dir[n - 1] != '\\')
            n--;
        if (n > 0)
            n--;
        while (n > 0 && dir[n - 1] != '\\')
            n--;
        immutable base = n;
        // Windows' copy and the C runtime's, which fontconfig reads
        void set(const(wchar)* name, const(wchar)* value)
        {
            SetEnvironmentVariableW(name, value);
            _wputenv_s(name, value);
        }
        void put(const(wchar)* name, const(wchar)[] tail)
        {
            n = base;
            foreach (c; tail)
                dir[n++] = c;
            dir[n] = 0;
            set(name, dir.ptr);
        }
        put("FONTCONFIG_FILE"w.ptr, "etc\\fonts\\fonts.conf"w);
        put("FONTCONFIG_PATH"w.ptr, "etc\\fonts"w);
        set("PANGOCAIRO_BACKEND"w.ptr, "fc"w.ptr);
    }

    /// Whether the system's OpenGL can run GTK: version 3.2 at least, and not
    /// Windows' own software one ("GDI Generic"). opengl32.dll is loaded here
    /// by hand: linked to the program, Windows would load the system's before
    /// hcadSoftwareGl could choose Mesa's.
    private bool hardwareGl()
    {
        import core.sys.windows.windows;
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
        import std.process : environment, spawnProcess;
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

/// A fingerprint of the code, quick enough for every key typed: whether the
/// text is back to the one saved, and, in the state, whether the code
/// changed without sending it.
ulong codeHash(string code)
{
    import std.bitmanip : littleEndianToNative;
    import std.digest.murmurhash : MurmurHash3;
    MurmurHash3!(128, 64) h;
    h.put(cast(const(ubyte)[]) code);
    return littleEndianToNative!ulong(h.finish()[0 .. 8]);
}

/// The garbage collector marks on one thread: marking in parallel spent
/// most of its time spinning on locks, against OCCT's own threads.
extern (C) __gshared string[] rt_options = ["gcopt=parallel:0"];

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
        // WORKAROUND (Wine, Pango's DirectWrite backend): under Wine it draws
        // the wrong glyphs: fontconfig instead (the Windows build is tested
        // with Wine on Linux). To check a newer Wine: run the Windows build
        // with PANGOCAIRO_BACKEND=win32 and look at the editor's text
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
        import std.string : toStringz;
        auto share = buildPath(dirName(dirName(thisExePath())), "share");
        auto dirs = environment.get("XDG_DATA_DIRS");
        _putenv_s("XDG_DATA_DIRS", toStringz(dirs.length ? share ~ ";" ~ dirs : share));
        _putenv_s("GSETTINGS_SCHEMA_DIR", toStringz(buildPath(share, "glib-2.0", "schemas")));
    }
    version (linux)
        installDesktopEntry();
    // --screenshot=FILE.png saves the window after the first evaluation and quits;
    // --size=WIDTHxHEIGHT opens the window that big (for pictures of it);
    // --theme=light|dark|system for this run only (the menu's choice is kept);
    // --name=NAME names the window (for agents and scripts that start it:
    // they know its name before it opens), when no open window has it;
    // --copy=FILE opens that file's text in a model of no file (Save asks
    // for a name): an example to try things in, overwriting nothing
    string path, shot, theme, name, copy, size;
    {
        import std.getopt : getopt, config, GetOptException;
        import std.stdio : stderr;
        auto rest = args.dup;
        try
            getopt(rest, config.passThrough, "screenshot", &shot, "theme", &theme, "name", &name, "copy", &copy,
                "size", &size);
        catch (GetOptException e)
            stderr.writeln("hackerscad: ", e.msg);
        // what is left: the model to open (options the system adds, -psn_… on
        // macOS, pass through and are left out)
        foreach (a; rest[1 .. $])
            if (a.length && a[0] != '-')
                path = absolutePath(a);
    }
    if (name.length)
        MainWindow.startName = name;
    if (copy.length)
    {
        try
            MainWindow.startText = readText(copy);
        catch (Exception e)
        {
            import std.stdio : stderr;
            stderr.writeln("hackerscad: cannot read ", copy, ": ", e.msg);
        }
    }
    if (size.length)
    {
        import std.array : split;
        import std.conv : to, ConvException;
        auto wh = size.split("x");
        try
            if (wh.length == 2)
                MainWindow.startSize = [wh[0].to!int, wh[1].to!int];
        catch (ConvException)
        {
        }
    }
    if (path is null)
        path = absolutePath("untitled.hcad");
    auto app = new AdwApplication("it.andreafontana.hackerscad.gui", ApplicationFlags.NonUnique);
    bool styled;
    app.connectActivate(() {
        if (!styled)
        {
            styled = true;
            if (theme.length)
                StyleManager.getDefault().setColorScheme(MainWindow.schemeFor(theme));
            else
                MainWindow.applySavedTheme();
        }
        auto w = new MainWindow(app, path);
        w.screenshotPath = shot;
    });
    return app.run(args[0 .. 1]);
}

struct ExportFormat
{
    string ext, label, what;
}

/// What Inspect shows: the lines from..to, or what a function returns.
struct InspectQuery
{
    uint from, to;      /// lines (1-based); 0 when a function is shown
    int col = -1;       /// cursor column on a single line (1-based), -1 for none
    string function_;   /// a function's name: what it returns
    bool sketchOnly;    /// only the sketch the lines belong to, nothing standing out (a step of it)
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
    EditorTools editorTools;   /// the editor's find bar and line actions
    Button testsButton;   /// runs the model's unittests (F5)
    Box testsDot;         /// over its corner: yellow, not run since the last change; red, one failed
    bool testsNext;       /// the next evaluation runs them
    string statusText;   /// the latest program message (for the control socket)
    ToggleButton paramsToggle, consoleToggle, codeToggle, viewToggle, sectionToggle, inspectToggle;
    Box sectionBar, viewBar;
    DropDown sectionPlane;
    Scale sectionSlider;
    Label sectionLabel;
    Vec3 sectionNormal = Vec3(0, 0, 1);
    bool sectionFlipped, sectionUpdating;
    ToggleButton sectionFlip;
    double sectionFace = 0;   /// position of the selected face along its normal
    StepsPanel stepsPanel;
    // Inspect: the solids and profiles a line of code made
    InspectQuery inspectQuery;   /// what is shown, asked again after each evaluation
    TraceEntry[] inspectShown;
    PartMesh[] inspectMeshes;    /// one per inspectShown entry (empty when it could not be made)
    uint inspectRequest;         /// goes up at every request: late meshes are dropped
    Overlay overlay;
    Button[] dimButtons;
    SketchView.Dimension[] dims;
    // the sketch drawn over the view: the one of the step selected or of the
    // inspected line, with its dimensions, its free points and what the line
    // makes or constrains in orange
    uint[2] sketchLines;          /// the lines it was asked for (0 when none is shown)
    bool sketchHighlight;         /// what those lines make stands out (Inspect; not a step)
    size_t[] sketchIndices;       /// in last.sketches (a sketch made in a loop or a function called again: every run)
    size_t sketchRun;             /// with several runs, the one drawn (0-based in sketchIndices)
    SketchView.Found[] sketchFound;   /// what the lines make in each
    bool positionQueued;
    Evaluator evaluator;
    ControlServer control;
    Button windowName;   /// the name agents use for this window
    Label windowNameLabel;

    string path;
    bool modified;
    ulong savedHash;   /// codeHash of the text as saved, opened or made new
    bool hasSaved;     /// false while no text was saved (an imported mesh's model)
    uint debounce;
    bool firstResult = true;
    bool fitNext;   /// frame the next result from where the view looks now (the socket's set)
    Outcome last;
    string screenshotPath;

    this(AdwApplication app, string path)
    {
        this.path = path;
        window = new ApplicationWindow(app);
        window.setDefaultSize(startSize[0], startSize[1]);

        // ---- header bar
        auto header = new HeaderBar;
        title = new WindowTitle(baseName(path), dirName(path));
        header.setTitleWidget(title);
        header.packStart(button("document-new-symbolic", "New model (" ~ shortcutKey ~ "+N)", &newFile));
        header.packStart(button("document-open-symbolic", "Open (" ~ shortcutKey ~ "+O)", &openFile));
        // words, not icons: Adwaita's save (an arrow down) and send (an
        // arrow out) read as download and upload
        header.packStart(textButton("Save", "Save (" ~ shortcutKey ~ "+S)", &save));
        header.packStart(exportMenu());
        header.packStart(examplesMenu());
        busyIndicator = new Spinner;
        // always in its place, drawn only while it spins: shown and hidden, it
        // pushed the window's name aside at every evaluation
        busyIndicator.setTooltipText(null);
        consoleToggle = toggle("utilities-terminal-symbolic", "Show console (" ~ shortcutKey ~ "+J)", true);
        paramsToggle = toggle("sidebar-show-right-symbolic", "Show parameters (F9)", true);
        codeToggle = toggle("sidebar-show-symbolic", "Show code (F7)", true);
        viewToggle = toggle("hcad-view-symbolic", "Show the 3D view (F8)", true);
        header.packEnd(mainMenu());
        header.packEnd(paramsToggle);
        header.packEnd(viewToggle);
        header.packEnd(codeToggle);
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
        sectionToggle = toggle("hcad-section-symbolic", "Section view: cut the model with a plane you can slide", false);
        sectionToggle.connectToggled(() {
            sectionBar.setVisible(sectionToggle.getActive());
            // closed: a split under way ends too
            if (!sectionToggle.getActive())
                endSplit();
            else
                planeFromSelection();
            updateSection(true);
        });
        inspectToggle = toggle("edit-find-symbolic", "Inspect (" ~ shortcutKey ~ "+I): click a line of code to see the solids and "
            ~ "2D profiles it makes, or a function's name to see what it returns; " ~ shortcutKey ~ "+click a line does the same", false);
        inspectToggle.connectToggled(() => updateEditorCursor(false));
        buildAnnotate();
        import gtk.icon_theme : IconTheme;
        import gdk.display : Display;
        IconTheme.getForDisplay(Display.getDefault()).addSearchPath(dataDir("icons"));
        version (Windows)
        {
            // laid out by fontconfig (see hcadFonts), in the font that comes with the package
            import std.process : environment;
            import gtk.settings : Settings;
            if (environment.get("PANGOCAIRO_BACKEND") == "fc")
                Settings.getDefault().gtkFontName = "Adwaita Sans 11";
        }
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
                ~ " button.hcad-dimension-lit { background-color: rgb(255, 140, 13); color: black; }"
                // a dimension being edited: a field the size of its label
                // solid, on the 3D view: the theme's field colours, the accent round it
                ~ " entry.hcad-dimension-entry { min-width: 0; min-height: 24px; padding: 0 6px; font-size: 0.85em;"
                ~ " border-radius: 4px; background-color: @view_bg_color; color: @view_fg_color;"
                ~ " box-shadow: 0 0 0 2px @accent_color, 0 2px 6px alpha(black, 0.25); }"
                // a parameter's ↺, no taller than its label
                ~ " button.hcad-param-reset { min-height: 0; min-width: 0; padding: 0 4px; margin: 0; }"
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
                ~ " .hcad-modebar { padding: 4px 6px 4px 10px; border-top: 1px solid alpha(currentColor, 0.10);"
                ~ " background: alpha(@accent_bg_color, 0.14); border-radius: 0 0 9px 9px; }"
                ~ " .hcad-modebar label { font-size: 0.9em; font-weight: bold; }"
                ~ " .hcad-modebar button { min-height: 24px; padding: 1px 10px; }"
                ~ " .hcad-annotatebar button { min-width: 22px; padding: 1px 5px; }"
                ~ " .hcad-annotatebar menubutton > button { padding: 1px 4px; }"
                // the colours of the annotations (tool/annotations' palette)
                ~ " .hcad-mark-colour-0 { background: #9E006B; } .hcad-mark-colour-1 { background: #E01B24; }"
                ~ " .hcad-mark-colour-2 { background: #FF7800; } .hcad-mark-colour-3 { background: #F6D32D; }"
                ~ " .hcad-mark-colour-4 { background: #26A269; } .hcad-mark-colour-5 { background: #1C71D8; }"
                ~ " .hcad-mark-colour-6 { background: #1E1E1E; } .hcad-mark-colour-7 { background: #FFFFFF; }"
                ~ " .hcad-gizmo-value { background: alpha(@window_bg_color, 0.9); border-radius: 6px; padding: 2px 7px;"
                ~ " border: 1px solid alpha(currentColor, 0.15); font-weight: bold; }"
                ~ " popover.hcad-menu > contents { padding: 4px 0; min-width: 210px; border-radius: 6px; }"
                ~ " popover.hcad-menu button { min-height: 0; padding: 3px 14px; border-radius: 0; font-weight: normal;"
                ~ " font-size: 0.93em; }"
                ~ " popover.hcad-menu button:hover { background: alpha(@accent_bg_color, 0.14); }"
                ~ " popover.hcad-menu separator { margin: 4px 0; }"
                ~ " .hcad-swatch { min-width: 14px; min-height: 14px; border-radius: 50%;"
                ~ " border: 1px solid alpha(currentColor, 0.3); }"
                ~ " popover.hcad-menu .hcad-menu-heading { padding: 4px 14px 2px 14px; font-size: 0.78em; font-weight: bold;"
                ~ " opacity: 0.55; }"
                ~ " button.hcad-pane-close { min-width: 22px; min-height: 22px; padding: 0; opacity: 0.55; }"
                ~ " .hcad-sketchbar { padding: 4px; }"
                ~ " button.hcad-sketch-tool { min-width: 30px; min-height: 28px; padding: 0; font-size: 1.15em; }"
                ~ " button.hcad-sketch-tool.hcad-tool-on { background: alpha(@accent_bg_color, 0.25); }"
                ~ " label.hcad-tool-more { font-size: 0.45em; opacity: 0.55; margin: 0 1px 1px 0; }"
                ~ " button.hcad-pane-close:hover { opacity: 1; }"
                ~ " label.hcad-info { padding: 4px 10px; border-radius: 6px; font-size: 0.9em;"
                ~ " background: alpha(@window_bg_color, 0.85); border: 1px solid alpha(currentColor, 0.10); }"
                ~ " button.hcad-problem { padding: 6px 12px; border-radius: 8px; font-weight: normal;"
                ~ " box-shadow: 0 1px 4px alpha(black, 0.18); }"
                ~ " button.hcad-problem.error { background: #c01c28; color: white; }"
                ~ " button.hcad-problem.warning { background: #e5a50a; color: #1e1e1e; }"
                ~ " popover.hcad-menu button { min-height: 0; padding: 4px 10px; border-radius: 5px; font-weight: normal; }"
                ~ " popover.hcad-menu separator { margin: 3px 6px; }"
                ~ " .hcad-findbar { padding: 6px 8px; border-bottom: 1px solid alpha(currentColor, 0.12); }"
                ~ " .hcad-findbar button.toggle, .hcad-findbar button { min-width: 0; padding: 2px 7px; }"
                ~ " .hcad-tests-dot { min-width: 8px; min-height: 8px; border-radius: 50%; background: #f6c90e;"
                ~ " box-shadow: 0 0 0 1.5px @window_bg_color; }"
                ~ " .hcad-tests-dot.hcad-tests-failed { background: #e01b24; }"
                ~ " .hcad-about-version { padding: 2px 12px; border-radius: 999px; font-weight: bold;"
                ~ " color: @accent_color; background: alpha(@accent_bg_color, 0.15); }");
            StyleContext.addProviderForDisplay(Display.getDefault(), css, 600);
            if (underWine())
            {
                // Wine cannot blend a window's own transparent pixels with
                // the desktop: the band GTK leaves round windows, menus and
                // tooltips for their shadows comes out black. Without the
                // shadows there is no band
                auto flat = new CssProvider;
                flat.loadFromString("window, window.csd, window.csd:backdrop, window.solid-csd { box-shadow: none; margin: 0; }"
                    ~ " popover > contents, popover.background > contents, popover.menu > contents { box-shadow: none; }"
                    ~ " tooltip, tooltip.background { box-shadow: none; }");
                StyleContext.addProviderForDisplay(Display.getDefault(), flat, 700);
            }
        }

        // Fit on its own, the views in one menu: room for what a click picks
        auto views = new Box(Orientation.Horizontal, 0);
        views.addCssClass("linked");
        views.append(textButton("Fit", "Frame the model (F6)", () => viewport.fit()));
        {
            import gio.menu : Menu;
            auto presets = new Menu;
            presets.append("Iso", "win.view-iso");
            presets.append("Top", "win.view-top");
            presets.append("Front", "win.view-front");
            presets.append("Right", "win.view-right");
            // the model's sketches, one entry each: it opens it to edit it
            sketchMenu = new Menu;
            auto list = new Menu;
            list.appendSection(null, presets);
            list.appendSubmenu("Sketches", sketchMenu);
            auto viewMenu = viewMenuButton = new MenuButton;
            viewMenu.setLabel("View");
            viewMenu.setTooltipText("Look from a side: iso, top, front, right; open one of the model's sketches");
            viewMenu.setMenuModel(list);
            views.append(viewMenu);
        }
        viewBar.append(views);
        viewBar.append(separator());
        // what a click picks: whole parts, faces, edges or vertices (the last choice kept)
        {
            import hackerscad.gui.settings : setSetting, setting;
            auto picks = new Box(Orientation.Horizontal, 0);
            picks.addCssClass("linked");
            static immutable string[4] keys = ["part", "face", "edge", "vertex"];
            static immutable string[4] tips = ["Click picks whole parts (Alt+1): move, rotate, colour, split…",
                "Click picks faces (Alt+2): fillet their edges, shell, extrude, holes…",
                "Click picks edges (Alt+3): fillet, chamfer, turn around them",
                "Click picks vertices (Alt+4): their position, distances"];
            immutable saved = setting("select", "part");
            foreach (i, key; keys)
            {
                auto b = toggle("hcad-select-" ~ key ~ "-symbolic", tips[i], key == saved);
                b.addCssClass("flat");
                if (i > 0)
                    b.setGroup(selectChoice[0]);
                selectChoice[i] = b;
                picks.append(b);
            }
            foreach (i; 0 .. 4)
                selectChoice[i].connectToggled(selectModeToggled(i));
            viewBar.append(picks);
            viewBar.append(separator());
        }
        viewBar.append(separator());
        partsMenu = new MenuButton;   // its list is added once the parameters panel exists
        partsMenu.setIconName("view-reveal-symbolic");
        partsMenu.setTooltipText("Parts shown in the view");
        partsMenu.addCssClass("flat");
        viewBar.append(partsMenu);
        displayMenu = new MenuButton;
        displayMenu.setIconName("hcad-display-symbolic");
        displayMenu.setTooltipText("How the view draws the parts: edges, wireframe, perspective or orthographic");
        displayMenu.addCssClass("flat");
        displayMenu.setPopover(displayPopover());
        viewBar.append(displayMenu);
        viewBar.append(sectionToggle);
        viewBar.append(inspectToggle);
        viewBar.append(annotateToggle);
        foreach (b; [sectionToggle, inspectToggle])
            b.addCssClass("flat");

        // ---- editor
        buffer = new SourceBuffer;
        auto lm = LanguageManager.getDefault();
        lm.prependSearchPath(dataDir("language-specs"));
        if (auto lang = lm.getLanguage("hcad"))
            buffer.setLanguage(lang);
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
        // room under the last line: the overlay scrollbar would sit on it
        editor.setBottomMargin(28);
        // completion, call signatures and help on names
        completion = new EditorCompletion(editor, buffer);
        completion.path = () => path;
        {
            import hackerscad.lang.interp : libraryPaths;
            completion.libraryDirs = libraryPaths();
        }
        editor.setLeftMargin(4);
        // find and replace, go to a line, line actions, brackets that close themselves
        editorTools = new EditorTools(editor, buffer);
        auto editorScroll = new ScrolledWindow;
        editorScroll.setChild(editor);
        editorScroll.setVexpand(true);
        auto editorPane = new Box(Orientation.Vertical, 0);
        {
            // a title with the pane's X, as the console has
            auto title = new Label("Code");
            title.addCssClass("caption-heading");
            title.addCssClass("dim-label");
            title.setXalign(0);
            title.setHexpand(true);
            title.setMarginStart(8);
            title.setMarginTop(4);
            title.setMarginBottom(2);
            auto head = new Box(Orientation.Horizontal, 0);
            head.append(title);
            head.append(closeButton(codeToggle, "Hide the code (F7)"));
            editorPane.append(head);
        }
        editorPane.append(editorTools.bar);
        editorPane.append(editorScroll);

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
        // room for the overlay scroll bars: the last line and the line ends stay readable
        console.setBottomMargin(14);
        console.setRightMargin(14);
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
        // the unittests, run when asked: their results come here
        testsButton = new Button;
        testsButton.setIconName("hcad-test-symbolic");
        testsButton.addCssClass("flat");
        testsButton.addCssClass("hcad-tests");
        testsButton.setMarginEnd(4);
        testsButton.setSensitive(false);
        testsButton.setTooltipText("Run the model's unittests (F5): it has none");
        testsButton.connectClicked(() => runTests());
        testsDot = new Box(Orientation.Horizontal, 0);
        testsDot.addCssClass("hcad-tests-dot");
        testsDot.setHalign(Align.End);
        testsDot.setValign(Align.Start);
        testsDot.setMarginTop(3);
        testsDot.setMarginEnd(7);
        testsDot.setCanTarget(false);
        testsDot.setVisible(false);
        auto testsCorner = new Overlay;
        testsCorner.setChild(testsButton);
        testsCorner.addOverlay(testsDot);
        consoleTitle.setHexpand(true);
        auto consoleHead = new Box(Orientation.Horizontal, 0);
        consoleHead.append(consoleTitle);
        consoleHead.append(testsCorner);
        consoleHead.append(closeButton(consoleToggle, "Hide the console (" ~ shortcutKey ~ "+J)"));
        auto consolePane = new Box(Orientation.Vertical, 0);
        consolePane.append(consoleHead);
        consolePane.append(consoleOverlay);
        consolePane.setSizeRequest(-1, 70);
        editorScroll.setSizeRequest(300, 200);

        auto left = new Paned(Orientation.Vertical);
        left.setStartChild(editorPane);
        left.setEndChild(consolePane);
        left.setPosition(700);
        left.setResizeStartChild(true);

        // ---- view and parameters
        buildSectionBar();
        buildTransformBar();
        viewport = new Viewport;
        viewport.setAntialias(antialiasChoice.getActive());
        viewport.onPick = (Hit h) => picked(h);
        viewport.onSketchShown = () => showProblems();
        viewport.onBox = (double x0, double y0, double x1, double y1, bool crossing) => boxed(x0, y0, x1, y1, crossing);
        viewport.onMotion = (double x, double y) => drawingMotion(x, y);
        // a double click on a flat face: the view looks straight at it
        viewport.onDoubleClick = (double x, double y) { lookAtFace(x, y); };
        // the selection mode kept from the last run (its buttons were made before the view)
        foreach (i, b; selectChoice)
            if (b !is null && b.getActive())
                viewport.setSelectMode(cast(SelectMode) i);
        // the shine kept from the last run (the menu was built before the view)
        viewport.setShine(savedShine());
        viewport.onContext = &contextMenu;
        // a handle of the section plane dragged: the slider follows (and moves the plane)
        viewport.onSectionDrag = (double offset) {
            sectionSlider.setValue(sectionFlipped ? -offset : offset);
        };
        // its X clicked: the section closes, as with the button
        viewport.onSectionClose = () => sectionToggle.setActive(false);
        // the split's ✓: the cut written into the code
        viewport.onSectionAccept = () {
            if (auto problem = applySplit())
                info(problem);
        };
        viewport.onGizmo = (double x, double y) => showTransformValue(x, y);
        // the ✓ and the X next to a part being moved or turned
        viewport.onGizmoAccept = () => applyTransform();
        // Place on…: where the anchor goes was clicked; the ring now spins it
        viewport.onPlaceTarget = (Vec3 to, Vec3 toN) {
            viewport.previewPlace(to, toN);
            transformValue.setLabel(transformText());
            info("turn it with the ring if you like, then ✓ (X leaves it where it was)");
        };
        viewport.onGizmoCancel = () => cancelTransform();
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
        {
            // the layer Annotate draws on lies over the 3D view (taking the pointer from it), under what floats over both
            auto stacked = new Overlay;
            stacked.setChild(viewport.area);
            stacked.addOverlay(viewport.band);
            stacked.addOverlay(noteArea);
            overlay.setChild(stacked);
        }
        // what floats over the view stays inside it: a long message or bar is
        // cut, never drawn over the parameters and the steps
        {
            import gtk.types : Overflow;
            overlay.setOverflow(Overflow.Hidden);
        }
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
        stepsPanel = new StepsPanel;
        stepsPanel.onSelect = &showFeature;
        stepsPanel.onFinal = () => showFinal();
        stepsPanel.onValue = (TraceEntry[] made) {
            if (made.length == 0)
                return;
            followTakenOver();
            jumpTo(made[0].site, "");
            inspectQuery = InspectQuery.init;   // a feature row: back to the final model after a run
            showInspected(distinct(made), format("line %d · %s", made[0].site.line,
                made[0].decl.file.length ? made[0].fn ~ "()" : made[0].fn), false);
            showSketchOn(made[0].site.line, made[0].site.line, false);
        };
        stepsPanel.onReturns = (FunctionInfo fn) {
            jumpTo(fn.nameSpan, "");
            hideSketch();
            inspectFunction(fn);
        };
        // Esc in the view closes Inspect
        {
            auto keys = new EventControllerKey;
            // Esc: back from Inspect or a rollback, otherwise (like Space) an empty selection
            keys.connectKeyPressed((uint key, uint code, ModifierType state) {
                // A: Annotate, the view locked to draw on (its own keys then)
                immutable plain = (state & (ModifierType.ControlMask | ModifierType.AltMask | ModifierType.MetaMask
                    | ModifierType.SuperMask)) == 0;
                if ((key == KEY_a || key == KEY_A) && plain)
                {
                    annotateToggle.setActive(true);
                    return true;
                }
                // what is selected in a sketch: Delete takes it out of the code
                if (sketchSel.length && (key == KEY_Delete || key == KEY_BackSpace))
                {
                    info(deleteSelection());
                    return true;
                }
                // X in a sketch that can be edited: the bar's ┄
                if ((key == KEY_x || key == KEY_X) && viewport.sketchShown && drawnSketch() !is null
                    && sketchUneditable() is null && !(state & (ModifierType.ControlMask | ModifierType.AltMask)))
                {
                    info(constructionClicked());
                    return true;
                }
                // drawing in a sketch: Enter ends it (as drawn), Esc drops it
                if (drawTool !is null && (key == KEY_Return || key == KEY_KP_Enter))
                {
                    finishDrawing(false);
                    return true;
                }
                if (key == KEY_Escape && sketchEscape())
                    return true;
                // moving or turning a part: Enter writes it, Esc leaves it
                if (viewport.gizmo != Viewport.Gizmo.none && (key == KEY_Return || key == KEY_KP_Enter))
                {
                    applyTransform();
                    return true;
                }
                if ((viewport.gizmo != Viewport.Gizmo.none || viewport.placing) && key == KEY_Escape)
                {
                    cancelTransform();
                    return true;
                }
                if (key == KEY_Escape && (viewport.inInspect || viewport.inRollback || sketchIndices.length))
                {
                    showFinal();
                    return true;
                }
                if ((key == KEY_Escape || key == KEY_space) && viewport.selection().length)
                {
                    clearSelection();
                    return true;
                }
                return false;
            });
            viewport.area.addController(keys);
        }
        params = new ParamsPanel;
        partsMenu.setPopover(partsPopover());
        params.onChange = () => scheduleEvaluation(0);
        params.onGoto = (int line) => editorTools.showLine(line);
        params.onVisibility = (size_t part, bool visible) => viewport.setHidden(part, !visible);
        auto paramsScroll = new ScrolledWindow;
        paramsScroll.setChild(params.widget);

        // parameters in a sidebar with bounded width that can be hidden
        // parameters and the feature tree share the sidebar
        auto stack = sideStack = new ViewStack;
        stack.addTitledWithIcon(paramsScroll, "params", "Parameters", "preferences-other-symbolic");
        auto stepsScroll = new ScrolledWindow;
        stepsScroll.setChild(stepsPanel.widget);
        stack.addTitledWithIcon(stepsScroll, "steps", "Steps", "view-list-symbolic");
        stack.setVexpand(true);
        auto switcher = new ViewSwitcher;
        switcher.setMarginTop(6);
        switcher.setMarginBottom(2);
        switcher.setMarginStart(6);
        switcher.setMarginEnd(6);
        switcher.setStack(stack);
        switcher.setPolicy(ViewSwitcherPolicy.Narrow);
        auto sidebar = new Box(Orientation.Vertical, 0);
        auto sideHead = new Box(Orientation.Horizontal, 0);
        switcher.setHexpand(true);
        sideHead.append(switcher);
        {
            auto x = closeButton(paramsToggle, "Hide the parameters (F9)");
            x.setMarginEnd(6);
            sideHead.append(x);
        }
        sidebar.append(sideHead);
        sidebar.append(stack);

        // the view tools float over the 3D view, slightly see-through
        auto tools = new Box(Orientation.Vertical, 0);
        tools.addCssClass("hcad-floating");
        tools.setHalign(Align.Center);
        tools.setValign(Align.Start);
        tools.setMarginTop(8);
        tools.append(viewBar);
        tools.append(sectionBar);
        tools.append(transformBar);
        tools.append(modeBar);
        tools.append(annotateBar);
        overlay.addOverlay(tools);
        overlay.addOverlay(buildSketchBar());
        info("");
        overlay.setVexpand(true);

        // the parameters and stepsPanel column: drag its edge to make it wider
        auto right = new Paned(Orientation.Horizontal);
        right.setStartChild(overlay);
        right.setEndChild(sidebar);
        right.setResizeStartChild(true);
        right.setResizeEndChild(false);   // a wider window widens the view, not the column
        right.setShrinkStartChild(false);
        right.setShrinkEndChild(true);    // narrower than its widgets would like: they are clipped
        right.setWideHandle(true);
        sidebar.setSizeRequest(220, -1);
        bool placed;
        right.connectNotify("max-position", () {
            // the column starts 300 px wide, once the window has a size
            if (placed || right.maxPosition < 600)
                return;
            placed = true;
            right.setPosition(right.maxPosition - 300);
        });
        // code, console, view and parameters each have a button; what is left fills the window
        void updatePanes(ToggleButton changed)
        {
            editorPane.setVisible(codeToggle.getActive());
            consolePane.setVisible(consoleToggle.getActive());
            overlay.setVisible(viewToggle.getActive());
            sidebar.setVisible(paramsToggle.getActive());
            immutable leftShown = codeToggle.getActive() || consoleToggle.getActive();
            immutable rightShown = viewToggle.getActive() || paramsToggle.getActive();
            if (!leftShown && !rightShown)
            {
                // the last pane closed: the 3D view comes back
                viewToggle.setActive(true);
                return;
            }
            left.setVisible(leftShown);
            right.setVisible(rightShown);
        }
        // a function per button: a closure made in a loop body would share
        // the loop's variable, and every button would pass the last one
        void watch(ToggleButton b)
        {
            b.connectToggled(() => updatePanes(b));
        }
        foreach (t; [codeToggle, consoleToggle, viewToggle, paramsToggle])
            watch(t);
        viewport.area.setSizeRequest(320, 240);

        auto main = mainPaned = new Paned(Orientation.Horizontal);
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
        action(app, "save", ["<Primary>s"], &save);
        action(app, "open", ["<Primary>o"], &openFile);
        action(app, "new", ["<Primary>n"], &newFile);
        action(app, "save-as", ["<Primary><Shift>s"], () => saveAs());
        appQuit(app);
        // Ctrl+E (Cmd+E on macOS): the format used last (3MF at first); the menus name them all
        action(app, "export", ["<Primary>e"], () => exportFile(exportFormat));
        foreach (f; exportFormats)
            exportAction(app, f.ext);
        action(app, "export-3mf-one", [], () => exportFile("3mf", null, true));
        foreach (e; examples)
            action(app, "example-" ~ e.name, [], exampleAction(e.name));
        action(app, "fit", ["F6"], () => viewport.fit());
        action(app, "view-iso", [], () => viewport.setView(ViewPreset.iso));
        action(app, "view-top", [], () => viewport.setView(ViewPreset.top));
        action(app, "view-front", [], () => viewport.setView(ViewPreset.front));
        action(app, "view-right", [], () => viewport.setView(ViewPreset.right));
        // the selection mode from the keyboard
        foreach (i, key; ["part", "face", "edge", "vertex"])
            action(app, "select-" ~ key, ["<Alt>" ~ format("%d", i + 1)], selectModeKey(i));
        action(app, "params", ["F9"], () => paramsToggle.setActive(!paramsToggle.getActive()));
        action(app, "console", ["<Primary>j"], () => consoleToggle.setActive(!consoleToggle.getActive()));
        action(app, "code", ["F7"], () => codeToggle.setActive(!codeToggle.getActive()));
        action(app, "view", ["F8"], () => viewToggle.setActive(!viewToggle.getActive()));
        themeAction();
        followStyle();
        action(app, "inspect", ["<Primary>i"], () {
            TextIter s, e;
            if (buffer.getSelectionBounds(s, e) && e.getLine() > s.getLine())
                inspectCursor();
            else
                inspectToggle.setActive(!inspectToggle.getActive());
        });
        action(app, "about", [], &showAbout);
        action(app, "run-tests", ["F5"], &runTests);
        action(app, "find", ["<Primary>f"], () => editorTools.find());
        action(app, "replace", ["<Primary>h"], () => editorTools.replace());
        action(app, "find-next", ["F3"], () => editorTools.next());
        action(app, "find-previous", ["<Shift>F3"], () => editorTools.previous());
        action(app, "go-to-line", ["<Primary>l"], () => editorTools.goToLine());
        action(app, "cheatsheet", ["F1"], &showCheatsheet);
        action(app, "tutorial", [], () => openUri(appWebsite ~ "/blob/main/docs/TUTORIAL.md"));
        action(app, "reference", [], () => openUri(appWebsite ~ "/blob/main/docs/LANGUAGE.md"));

        evaluator = new Evaluator;
        evaluator.onResult = &showOutcome;
        evaluator.onProgress = (string what) { stage = what; };

        // started on a file that is not a model: an empty model next to it, and why
        string refused, why;
        if (exists(path) && (why = notAModel(path)) !is null)
        {
            refused = path;
            path = this.path = buildPath(dirName(path), "untitled.hcad");
            updateTitle();
            idleAdd(PRIORITY_DEFAULT, () { refuseFile(refused, why); return false; });
        }
        // --copy: that code, as a model of no file (Save asks for a name)
        if (startText !is null)
        {
            path = this.path = buildPath(dirName(path), "untitled.hcad");
            buffer.setText(startText);
            startText = null;
        }
        else
            buffer.setText(exists(path) ? readText(path) : startModel);
        markSaved();
        buffer.connectChanged(() {
            revision++;
            // typed and undone back to the saved text: no change
            modified = !hasSaved || codeHash(text()) != savedHash;
            updateTitle();
            sketchLinesMoved();
            scheduleEvaluation(250);
        });
        // the sketch at the cursor
        buffer.connectNotify("cursor-position", () => cursorMoved());
        disarmFollow();
        sketchMenuAction();
        updateSketchMenu();
        scheduleEvaluation(0);

        // Inspect: a click with the lens armed, or a Ctrl+click, shows what that line makes
        {
            auto click = new GestureClick;
            click.connectReleased((int n, double x, double y, GestureClick g) {
                immutable ctrl = (g.getCurrentEventState() & inspectClick) != 0;
                if (!ctrl && !inspectToggle.getActive())
                    return;
                TextIter s, e;
                if (buffer.getSelectionBounds(s, e) && e.getLine() > s.getLine())
                    inspectCursor();   // dragged over several lines
                else
                {
                    import gtk.types : TextWindowType;
                    int bx, by;
                    editor.windowToBufferCoords(TextWindowType.Widget, cast(int) x, cast(int) y, bx, by);
                    TextIter it;
                    if (editor.getIterAtLocation(it, bx, by))
                        inspectLines(it.getLine() + 1, it.getLine() + 1, it.getLineOffset() + 1);
                }
                inspectToggle.setActive(false);   // one shot: the lens goes back to a text cursor
            });
            editor.addController(click);

            // the lens cursor while Ctrl (Cmd on macOS) is held over the code
            auto keys = new EventControllerKey;
            keys.connectKeyPressed((uint key, uint code, ModifierType state) {
                if (inspectKeys.canFind(key))
                    updateEditorCursor(true);
                else if (key == KEY_Escape && sketchEscape())
                    return true;
                else if (key == KEY_Escape && (viewport.inInspect || viewport.inRollback || sketchIndices.length))
                {
                    showFinal();
                    return true;
                }
                else if (key == KEY_Escape && viewport.selection().length)
                    clearSelection();   // and the key goes on: it also closes the completion list
                return false;
            });
            keys.connectKeyReleased((uint key, uint code, ModifierType state) {
                if (inspectKeys.canFind(key))
                    updateEditorCursor(false);
            });
            editor.addController(keys);
            auto motion = new EventControllerMotion;
            motion.connectMotion((double x, double y, EventControllerMotion m) {
                updateEditorCursor((m.getCurrentEventState() & inspectClick) != 0);
            });
            motion.connectLeave(() => updateEditorCursor(false));
            editor.addController(motion);
        }

        // external control (MCP server, scripts), under a name agents can tell apart
        try
        {
            exeAtStart = thisExePath;
            exeTimeAtStart = mtimeOf(exeAtStart);
        }
        catch (Exception)
            exeAtStart = null;
        control = new ControlServer;
        immutable wanted = startName;
        startName = null;   // the first window only: the others get their own
        if (control.start(&handleControl, wanted))
        {
            showWindowName();
            // whoever started it (a script, an agent) learns which window is theirs
            try
            {
                import std.stdio : stdout;
                stdout.writeln("hackerscad: window ", control.name);
                stdout.flush();
            }
            catch (Exception)
            {
                // no console (Windows): nobody to tell
            }
        }
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

    ToggleButton[4] selectChoice;   /// part, face, edge, vertex

    void delegate() selectModeKey(size_t i) => () => selectChoice[i].setActive(true);

    /// A selection-mode button turned on: clicks pick that kind, the
    /// selection is cleared (it was of another kind), the choice is kept.
    void delegate() selectModeToggled(size_t i)
    {
        return () {
            import hackerscad.gui.settings : setSetting;
            if (!selectChoice[i].getActive())
                return;
            setSetting("select", ["part", "face", "edge", "vertex"][i]);
            if (viewport !is null)
            {
                viewport.setSelectMode(cast(SelectMode) i);
                viewport.setSelection(null);
            }
        };
    }

    /// The X of a pane: it hides the pane, as its button in the header bar
    /// does (and that button shows it again).
    static Button closeButton(ToggleButton pane, string tooltip)
    {
        auto b = new Button;
        b.setIconName("window-close-symbolic");
        b.addCssClass("flat");
        b.addCssClass("circular");
        b.addCssClass("hcad-pane-close");
        b.setTooltipText(tooltip);
        b.setValign(Align.Center);
        b.connectClicked(() => pane.setActive(false));
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
        auto files = new Menu;
        files.append("New", "win.new");
        files.append("Open…", "win.open");
        files.append("Save As…", "win.save-as");
        files.appendSubmenu("Export", exportModel());
        auto help = new Menu;
        help.append("Cheatsheet", "win.cheatsheet");
        help.append("Tutorial", "win.tutorial");
        help.append("Language Tour", "win.example-language");
        help.append("Language Reference", "win.reference");
        auto style = new Menu;
        style.append("Follow the system", "win.theme::system");
        style.append("Light", "win.theme::light");
        style.append("Dark", "win.theme::dark");
        auto look = new Menu;
        look.appendSubmenu("Style", style);
        auto app = new Menu;
        app.append("About hackerscad", "win.about");
        app.append("Quit", "app.quit");
        auto menu = new Menu;
        menu.appendSection(null, files);
        menu.appendSection(null, help);
        menu.appendSection(null, look);
        menu.appendSection(null, app);
        auto b = new MenuButton;
        b.setIconName("open-menu-symbolic");
        b.setTooltipText("Main menu");
        b.setMenuModel(menu);
        b.setPrimary(true);
        return b;
    }

    // ---- light or dark

    /// The colour scheme for a theme preference: system, light or dark.
    static ColorScheme schemeFor(string theme) =>
        theme == "light" ? ColorScheme.ForceLight : theme == "dark" ? ColorScheme.ForceDark : ColorScheme.PreferLight;

    /// Applies the theme saved last; once per run, before the first window.
    static void applySavedTheme()
    {
        import hackerscad.gui.settings : setting;
        StyleManager.getDefault().setColorScheme(schemeFor(setting("theme", "system")));
    }

    /// Main menu › Style: follow the system, light or dark, kept for the
    /// next runs; every window's menu shows the choice.
    void themeAction()
    {
        import glib.variant : Variant;
        import glib.variant_type : VariantType;
        import hackerscad.gui.settings : setSetting, setting;
        auto a = SimpleAction.newStateful("theme", new VariantType("s"), Variant.newString(setting("theme", "system")));
        a.connectChangeState((Variant value, SimpleAction self) {
            immutable theme = value.getString();
            self.setState(value);
            setSetting("theme", theme);
            StyleManager.getDefault().setColorScheme(schemeFor(theme));
        });
        // another window chose: this menu shows it too
        StyleManager.getDefault().connectNotify("color-scheme", () {
            auto cs = StyleManager.getDefault().getColorScheme();
            a.setState(Variant.newString(cs == ColorScheme.ForceLight ? "light" : cs == ColorScheme.ForceDark ? "dark" : "system"));
        });
        window.addAction(a);
    }

    /// The editor and the 3D view follow the window's style: libadwaita
    /// darkens the rest by itself.
    void followStyle()
    {
        auto sm = StyleManager.getDefault();
        applyStyle(sm.getDark());
        sm.connectNotify("dark", () => applyStyle(StyleManager.getDefault().getDark()));
    }

    void applyStyle(bool dark)
    {
        auto schemes = StyleSchemeManager.getDefault();
        foreach (name; dark ? ["Adwaita-dark", "classic-dark", "oblivion"] : ["Adwaita", "classic"])
            if (auto scheme = schemes.getScheme(name))
            {
                buffer.setStyleScheme(scheme);
                break;
            }
        viewport.setDark(dark);
        // the completion's kind labels: lighter text on a dark popup
        import gtk.css_provider : CssProvider;
        import gtk.style_context : StyleContext;
        import gdk.display : Display;
        if (darkCss is null)
        {
            darkCss = new CssProvider;
            darkCss.loadFromString(
                " .hcad-kind-function, .hcad-kind-method, .hcad-kind-variable { color: #8fdcbf; }"
                ~ " .hcad-kind-property, .hcad-kind-field { color: #8fb8e8; }"
                ~ " .hcad-kind-parameter { color: #f3c362; }"
                ~ " .hcad-kind-constant, .hcad-kind-type { color: #c9a3e6; }");
        }
        if (dark)
            StyleContext.addProviderForDisplay(Display.getDefault(), darkCss, 601);
        else
            StyleContext.removeProviderForDisplay(Display.getDefault(), darkCss);
    }

    static imported!"gtk.css_provider".CssProvider darkCss;

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
    /// The About window while it is open: asked again, it comes forward
    /// instead of a second one opening.
    import hackerscad.gui.aboutwindow : AboutWindow;
    AboutWindow aboutDialog;

    void showAbout()
    {
        if (aboutDialog !is null)
            return aboutDialog.present();
        aboutDialog = new AboutWindow(window, debugReport());
        aboutDialog.onClosed = () { aboutDialog = null; };
        aboutDialog.openUri = (string uri) => openUri(uri);
        aboutDialog.present();
    }

    /// app.quit, once per application: closes every window, each asking
    /// about unsaved changes. macOS's application menu calls it (Quit, Cmd+Q).
    static void appQuit(AdwApplication app)
    {
        if (app.lookupAction("quit") !is null)
            return;
        auto a = new SimpleAction("quit");
        a.connectActivate(() {
            foreach (w; app.getWindows())
                w.close();
        });
        app.addAction(a);
        app.setAccelsForAction("app.quit", ["<Primary>q"]);
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

    /// The text is the one saved, opened or made new: from now on, the
    /// edits that bring it back to this are no change.
    void markSaved()
    {
        modified = false;
        savedHash = codeHash(text());
        hasSaved = true;
        updateTitle();
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
            busyIndicator.setTooltipText("Evaluating the model");
            busyIndicator.start();
            startProgress();
            Request r;
            r.source = text();
            r.path = path;
            r.overrides = params.overrides.dup;
            r.preset = params.preset;
            r.tests = testsNext;
            testsNext = false;
            evaluator.request(r);
            return false;
        });
    }

    /// Runs the model's unittests with the next evaluation (F5, the bug
    /// button, an export, the socket's "test"): the window does not run them
    /// at every change, they can take seconds.
    void runTests()
    {
        testsNext = true;
        scheduleEvaluation(0);
    }

    /// The bug button after an evaluation: how many unittests and how they
    /// went, or that they have not run since the code or a value changed.
    void showTests(Outcome o)
    {
        testsDot.removeCssClass("hcad-tests-failed");
        testsDot.setVisible(o.unittests > 0 && (!o.unittestsRan || o.unittestsFailed > 0));
        testsButton.setSensitive(o.unittests > 0);
        immutable n = o.unittests == 1 ? "its unittest" : format("its %d unittests", o.unittests);
        if (o.unittests == 0)
            testsButton.setTooltipText("Run the model's unittests (F5): it has none");
        else if (!o.unittestsRan)
        {
            testsButton.setTooltipText("Run " ~ n ~ " (F5): not run since the last change");
        }
        else if (o.unittestsFailed == 0)
        {
            testsButton.setTooltipText(format("%s passed (F5 runs them again)", o.unittests == 1 ? "The unittest"
                : format("All %d unittests", o.unittests)));
            note(o.unittests == 1 ? "unittest: passed" : format("unittests: all %d passed", o.unittests));
        }
        else
        {
            testsDot.addCssClass("hcad-tests-failed");
            testsButton.setTooltipText(format("%d of %d unittests failed: see the console (F5 runs them again)",
                o.unittestsFailed, o.unittests));
            note(format("unittests: %d of %d failed", o.unittestsFailed, o.unittests));
        }
    }

    void showOutcome(Outcome o)
    {
        // the view is annotated: it does not change under the marks; shown once it is unlocked
        if (holdOutcome(o))
            return;
        if (o.ok)
            showTests(o);
        // a failed evaluation leaves the last good model on screen: it is
        // also what Export saves
        if (!o.ok)
            o.parts = last.parts;
        // Inspect keeps what it had when the run stopped before making anything,
        // and the feature groups when the code does not parse
        if (!o.ok && o.trace.length == 0)
            o.trace = last.trace;
        if (o.functions.length == 0)
            o.functions = last.functions;
        // the selection, to find again on the new parts
        auto selBefore = viewport.selection();
        auto partsBefore = last.parts;
        last = o;
        hadResult = true;
        // the sketches made, or the last good ones while the code has an error
        holdSketches(o);
        params.update(o.params, o.presets);
        {
            import std.string : splitLines;
            stepsPanel.update(o.features, o.trace, o.functions, path, text().splitLines);
        }
        viewport.setSketches(last.sketches, staleSketch);
        {
            // the solids sketches on faces are drawn on: the new ones, and those
            // of the sketches still shown from before (the last good one)
            import hackerscad.kernel.brep : Brep;
            PartMesh[Brep] bodies;
            foreach (i, sk; o.sketches)
                if (sk.body !is null && i < o.sketchBodies.length && o.sketchBodies[i].vertices.length)
                    bodies[sk.body] = o.sketchBodies[i];
            foreach (sk; last.sketches)
                if (sk.body !is null && (sk.body in bodies) is null)
                    if (auto had = sk.body in viewport.sketchBodies)
                        bodies[sk.body] = *had;
            viewport.setSketchBodies(bodies);
        }
        updateSketchMenu();
        // the sketch shown stays (a dimension was changed): of the same lines, in the new model
        immutable sketchWas = sketchLines;
        immutable sketchLit = sketchHighlight;
        if (sketchFollowing)
        {
            // the sketch at the cursor, in the new model
            if (!o.cancelled)
                followSketch(true);
        }
        else
        {
            // Inspect shows what the same lines make now
            if (viewport.inInspect && !o.cancelled)
                reinspect();
            if (viewport.inRollback)
                showFinal();
            if (sketchWas[0] > 0 && !o.cancelled)
            {
                if (sketchLines == sketchWas)
                    showSketchOn(sketchWas[0], sketchWas[1], sketchHighlight);   // the new sketch, the same lines
                else if (sketchLines[0] == 0 && !viewport.inInspect && !viewport.inRollback)
                    inspectSketch(sketchWas[0], sketchWas[1], sketchLit);   // the step it came from is gone
            }
            // a sketch made where the cursor is
            if (!o.cancelled)
                followSketch(true);
        }
        if (sectionToggle.getActive())
            updateSection(false);
        updateDimensions();

        string log;
        foreach (l; o.log)
            log ~= l.text ~ "\n";
        size_t errors;
        foreach (d; o.diagnostics)
        {
            errors += d.severity == Severity.error;
            log ~= render(d, o.sources.get(d.span.file, "")) ~ "\n";
        }
        modelOutput = log;
        busyIndicator.stop();
        busyIndicator.setTooltipText(null);
        stopProgress();
        problems = o.diagnostics.dup;
        problemsEvaluated = o.ok;
        showProblems();

        // what the sketch bar wrote is evaluated (well or not): the sketch follows the cursor again
        if (sketchEditHold)
        {
            sketchEditHold = false;
            followSketch(true);
        }
        if (o.ok)
        {
            viewport.setParts(o.parts, firstResult);
            firstResult = false;
            keepSelection(selBefore, partsBefore);
            if (fitNext)
            {
                fitNext = false;
                viewport.fit();
            }
            // a split under way follows its part by name; gone (split, renamed), it ends
            if (splitPart >= 0)
            {
                splitPart = -1;
                foreach (i, q; o.parts)
                    if (q.name == splitName)
                        splitPart = cast(int) i;
                viewport.sectionPart = splitPart;
                if (splitPart < 0)
                    sectionToggle.setActive(false);
            }
            noteGraphics();
            import std.algorithm : map;
            import std.array : array;
            params.updateParts(o.parts.map!(p => p.name).array, o.parts.map!(p => p.rgb).array, &viewport.isHidden);
            immutable total = o.cacheHits + o.cacheMisses;
            note(format("%s %d part%s in %d ms%s%s", errors ? "evaluated with problems:" : "evaluated:", o.parts.length,
                o.parts.length == 1 ? "" : "s", o.milliseconds,
                total ? format(" (%d%% from cache)", o.cacheHits * 100 / total) : "", sketchSummary()), true);
            if (viewport.printability)
                printSummary();
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
        // the open menus of the view: the right-click one, the parts, the display style
        if (other is null)
            foreach (pop; [contextPopover, partsMenu ? partsMenu.getPopover() : null,
                    displayMenu ? displayMenu.getPopover() : null])
                snapshotPopover(snap, window, pop);
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
    /// Once the 3D view has drawn: which OpenGL it uses, in the console,
    /// and a warning when the processor does the drawing (slow).
    void noteGraphics()
    {
        if (graphicsNoted || viewport.glRenderer.length == 0)
            return;
        graphicsNoted = true;
        note(format("3D view: OpenGL %s on %s", viewport.glVersion, viewport.glRenderer));
        if (viewport.softwareGl())
            note("the 3D view is drawn by the processor, without the graphics card: it will be slow. Update the "
                ~ "graphics driver (on Windows from the maker of the card, not Windows Update's basic driver); in a "
                ~ "virtual machine or a remote session this is expected");
    }

    bool graphicsNoted;

    /// The frame figures for About: average / worst over the frames drawn
    /// while the view moved.
    /// What to paste into a problem report: hackerscad and the libraries,
    /// the system, the screen, what draws the window and the 3D view and how
    /// fast, the fonts, how heavy the model is, the settings that change how
    /// it draws. No file names: reports are public.
    string debugReport()
    {
        import std.process : environment;
        import std.system : os;
        import std.conv : to;
        import gdk.display : Display;
        import gdk.rectangle : Rectangle;
        import gtk.settings : Settings;
        string[] r = [format("%s %s", appName, appVersion), "system: " ~ systemText(),
            format("GTK %s.%s.%s, libadwaita %s.%s.%s", imported!"gtk.global".getMajorVersion(),
                imported!"gtk.global".getMinorVersion(), imported!"gtk.global".getMicroVersion(),
                imported!"adw.global".getMajorVersion(), imported!"adw.global".getMinorVersion(),
                imported!"adw.global".getMicroVersion())];
        auto display = Display.getDefault();
        string screen = "display: " ~ typeOf(display);
        if (auto surface = window.getSurface())
        {
            screen ~= format(", window scale %g (%d)", surface.getScale(), window.getScaleFactor());
            if (auto m = display.getMonitorAtSurface(surface))
            {
                Rectangle g;
                m.getGeometry(g);
                screen ~= format(", monitor %d×%d at %g Hz, scale %d", g.width, g.height, m.getRefreshRate() / 1000.0,
                    m.getScaleFactor());
            }
        }
        r ~= screen;
        r ~= format("window %d×%d, drawn by %s", window.getWidth(), window.getHeight(),
            window.getRenderer() is null ? "?" : typeOf(window.getRenderer()));
        r ~= format("3D view: %d×%d pixels, OpenGL %s on %s (%s)%s, antialiasing %s",
            viewport.area.getWidth() * viewport.area.getScaleFactor(), viewport.area.getHeight() * viewport.area.getScaleFactor(),
            viewport.glVersion, viewport.glRenderer, viewport.glVendor,
            viewport.softwareGl() ? ", drawn by the processor" : "", viewport.antialiasing() ? "on" : "off");
        r ~= frameText(viewport.frameStats())[1 .. $];
        size_t triangles;
        foreach (part; last.parts)
            triangles += part.indices.length / 3;
        r ~= format("model: %d parts, %d triangles", last.parts.length, triangles);
        r ~= "font: " ~ Settings.getDefault().gtkFontName;
        r ~= "theme: " ~ imported!"hackerscad.gui.settings".setting("theme", "system");
        foreach (name; ["GSK_RENDERER", "GDK_BACKEND", "GDK_DEBUG", "GDK_SCALE", "HCAD_GL", "PANGOCAIRO_BACKEND",
                "GALLIUM_DRIVER", "LIBGL_ALWAYS_SOFTWARE", "LANG"])
            if (auto v = environment.get(name))
                r ~= name ~ "=" ~ v;
        return r.join("\n");
    }

    /// The system: its name and version, Wine's when under Wine, the
    /// desktop on Linux.
    static string systemText()
    {
        import std.process : environment;
        import std.system : os;
        import std.conv : to;
        version (Windows)
        {
            import core.sys.windows.windows : GetModuleHandleA, GetProcAddress;
            import std.string : fromStringz;
            auto ntdll = GetModuleHandleA("ntdll.dll");
            struct Info { uint size, major, minor, build, platform; wchar[128] sp; }
            Info v;
            v.size = Info.sizeof;
            alias RtlGetVersion = extern (Windows) int function(Info*) nothrow @nogc;
            auto get = cast(RtlGetVersion) GetProcAddress(ntdll, "RtlGetVersion");
            string text = get !is null && get(&v) == 0 ? format("Windows %d.%d build %d", v.major, v.minor, v.build) : "Windows";
            alias WineVersion = extern (C) const(char)* function() nothrow @nogc;
            if (auto wine = cast(WineVersion) GetProcAddress(ntdll, "wine_get_version"))
                text ~= " under Wine " ~ wine().fromStringz.idup;
            return text;
        }
        else
        {
            string text = os.to!string;
            version (linux)
            {
                import std.file : readText;
                import std.string : lineSplitter, startsWith, strip;
                try
                    foreach (line; readText("/etc/os-release").lineSplitter)
                        if (line.startsWith("PRETTY_NAME="))
                            text = line["PRETTY_NAME=".length .. $].strip(`"`);
                catch (Exception)
                {
                }
                text ~= ", " ~ environment.get("XDG_CURRENT_DESKTOP", "?") ~ " on " ~ environment.get("XDG_SESSION_TYPE", "?");
            }
            return text;
        }
    }

    /// The GObject type of `o`: which display, which renderer.
    static string typeOf(imported!"gobject.object".ObjectWrap o)
    {
        import gobject.c.functions : g_type_name_from_instance;
        import gobject.c.types : GTypeInstance;
        import std.string : fromStringz;
        return g_type_name_from_instance(cast(GTypeInstance*) o._cPtr).fromStringz.idup;
    }

    static string frameText(Viewport.FrameStats f)
    {
        if (f.frames == 0)
            return "\nframes: none measured yet (turn the view for a few seconds, then open About again)";
        return format("\nframes, average / worst over the last %d while moving:", f.frames)
            ~ format("\n  %.1f / %.1f ms waiting to start, %d slow (over 33 ms: jerks)", f.waitMs, f.waitMaxMs, f.slow)
            ~ format("\n  %.1f / %.1f ms apart (16.7: 60 a second)", f.intervalMs, f.intervalMaxMs)
            ~ format("\n  %.2f / %.2f ms on the processor", f.drawMs, f.drawMaxMs)
            ~ (f.gpuMs < 0 ? "\n  graphics card time: not known" : format("\n  %.2f / %.2f ms on the graphics card",
                f.gpuMs, f.gpuMaxMs));
    }

    /// What draws the window, for diagnosis (state, About).
    JValue graphicsJson()
    {
        import std.process : environment;
        JValue g = JSOB("renderer", viewport.glRenderer, "version", viewport.glVersion, "vendor", viewport.glVendor);
        g["software"] = viewport.softwareGl();
        g["antialias"] = viewport.antialiasing();
        auto f = viewport.frameStats();
        JValue frames = JSOB("frames", f.frames, "slow", f.slow);
        frames["draw_ms"] = f.drawMs;
        frames["draw_max_ms"] = f.drawMaxMs;
        frames["gpu_ms"] = f.gpuMs;
        frames["gpu_max_ms"] = f.gpuMaxMs;
        frames["wait_ms"] = f.waitMs;
        frames["wait_max_ms"] = f.waitMaxMs;
        frames["interval_ms"] = f.intervalMs;
        frames["interval_max_ms"] = f.intervalMaxMs;
        g["frames"] = frames;
        // how GTK draws the rest, and whether hackerscad fell back on Mesa
        foreach (name; ["GSK_RENDERER", "GDK_DEBUG", "HCAD_GL"])
            if (auto v = environment.get(name))
                g[name] = v;
        return g;
    }

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
        // through a mark: scrolling to an iter now would use the old layout
        TextIter last;
        b.getEndIter(last);
        auto end = b.getMark("end");
        if (end is null)
            end = b.createMark("end", last, false);
        else
            b.moveMark(end, last);
        console.scrollToMark(end, 0, false, 0, 1);
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
        immutable seconds = (MonoTime.currTime - evalStart).total!"msecs" / 1000.0;
        evaluator.cancel();
        busyIndicator.stop();
        busyIndicator.setTooltipText(null);
        stopProgress();
        note(format("evaluation stopped after %.1f s (at %s): it runs again at the next edit", seconds, stage));
    }

    Label infoLabel;

    /// Shows what is selected (or a short message) at the bottom of the 3D view; empty hides it.
    void info(string text)
    {
        makeInfoLabel();
        infoLabel.setLabel(text);
        infoLabel.setVisible(text.length > 0);
    }

    /// The info card at the bottom right: a title, then a row for each
    /// size, its name dimmed, and a hint under them; wrapped, never cut.
    void infoCard(string title, string[2][] rows, string hint = null)
    {
        import glib.global : markupEscapeText;
        string esc(string t) => markupEscapeText(t);
        string m = "<b>" ~ esc(title) ~ "</b>";
        foreach (r; rows)
            m ~= "\n<span alpha=\"65%\">" ~ esc(r[0]) ~ "</span>  " ~ esc(r[1]);
        if (hint.length)
            m ~= "\n<span alpha=\"55%\" size=\"small\">" ~ esc(hint) ~ "</span>";
        makeInfoLabel();
        infoLabel.setMarkup(m);
        infoLabel.setVisible(true);
    }

    void makeInfoLabel()
    {
        if (infoLabel !is null)
            return;
        infoLabel = new Label("");
        infoLabel.addCssClass("hcad-info");
        infoLabel.setHalign(Align.End);
        infoLabel.setValign(Align.End);
        infoLabel.setMarginEnd(10);
        infoLabel.setMarginBottom(10);
        // long lines wrap: what it says is never cut short
        infoLabel.setWrap(true);
        infoLabel.setMaxWidthChars(60);
        infoLabel.setXalign(0);
        infoLabel.setCanTarget(false);
        overlay.addOverlay(infoLabel);
    }

    Button problemBanner;
    Label problemText;
    Span problemSpan;
    Diagnostic[] problems;     /// the last run's
    bool problemsEvaluated;    /// whether that run made the model

    /// The last run's problems marked in the code, the first in the banner. A
    /// sketch's warnings (free points, open lines) only while a sketch is
    /// shown: else they are in the log alone, not always in sight.
    void showProblems()
    {
        TextIter s, e;
        buffer.getBounds(s, e);
        foreach (tag; ["error", "error-line", "warning", "warning-line"])
            buffer.removeTagByName(tag, s, e);
        buffer.removeSourceMarks(s, e, null);
        Diagnostic first;
        bool haveFirst;
        foreach (d; problems)
        {
            if (d.severity != Severity.error && d.code == Code.sketch && !viewport.sketchShown)
                continue;
            if (d.span.file == absolutePath(path) && d.span.line > 0)
                markProblem(d.span, d.severity == Severity.error ? "error" : "warning");
            if (!haveFirst || (d.severity == Severity.error && first.severity != Severity.error))
            {
                first = d;
                haveFirst = true;
            }
        }
        showProblem(haveFirst, first, problemsEvaluated);
    }

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
    /// Empties the selection, and the line it marked in the code.
    void clearSelection()
    {
        viewport.setSelection(null);
        TextIter s, e;
        buffer.getBounds(s, e);
        buffer.removeTagByName("picked", s, e);
        info("");
    }

    /// A click in the 3D view: each item clicked joins the selection
    /// (clicked again, it leaves it), a click on nothing empties it;
    /// `alone` (a right-click away from the selection) selects it alone.
    /// A box dragged over the view: what it takes joins the selection, the sketch's when one is shown
    /// (wholly inside it; dragged right to left, what it touches too).
    void boxed(double x0, double y0, double x1, double y1, bool crossing)
    {
        if (sceneLocked())
            return;
        if (viewport.sketchShown)
        {
            if (drawnSketch() !is null && drawTool is null)
                sketchBox(x0, y0, x1, y1, crossing);
            return;
        }
        Hit[] all = viewport.selection();
        size_t added;
        foreach (h; viewport.boxItems(x0, y0, x1, y1, crossing))
            if (!all.canFind!(x => Viewport.sameItem(x, h)))
            {
                all ~= h;
                added++;
            }
        viewport.setSelection(all);
        if (sectionToggle.getActive() && splitPart < 0)
            refreshPlaneChoices();
        if (added == 0)
            return info("the box took nothing" ~ (all.length ? "" : ": drag over what to select"));
        showSelection();
    }

    void picked(Hit hit, bool alone = false)
    {
        if (sceneLocked())
            return;
        // with a sketch shown, a click on one of its points or lines selects it (the bar at the left constrains
        // what is selected) and shows the line that made it; on nothing, the sketch's selection empties
        if (viewport.sketchShown && sketchPick(hit.x, hit.y))
            return;
        // a click on nothing closes Inspect; not a sketch shown: in its
        // empty space a click is part of working on it (Esc closes it)
        if (hit.part < 0 && viewport.inInspect && !viewport.sketchShown)
            stopInspect();
        if (hit.part < 0 || alone)
            viewport.select(hit);
        else
            viewport.toggleSelect(hit);
        // a section parallel to the selected face follows the new face
        // a face picked or dropped: the section offers its plane, or not
        if (sectionToggle.getActive() && splitPart < 0)
            refreshPlaneChoices();
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
        // clicked again: it left the selection, the rest stays
        if (!viewport.selection().canFind!(h => Viewport.sameItem(h, hit)))
            return showSelection();
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
                // stepsPanel from imported modules point elsewhere: stay on the part
                if (f.span.file == absolutePath(path))
                    span = f.span;
            }
        }
        TextIter a, b;
        if (!buffer.getIterAtLine(a, span.line - 1))
            return;
        buffer.getIterAtLine(b, span.line);
        buffer.applyTagByName("picked", a, b);
        placeCursorQuietly(a);
        editor.scrollToIter(a, 0.1, true, 0, 0.3);
        // the sizes of what was picked: the part's, or the face's, edge's, vertex's
        if (viewport.selection().length > 1)
            return showSelection();
        infoCard(what, selectionRows());
    }

    /// After an evaluation, the items selected on the parts before (`was`)
    /// found again: the same part by name, the same face, edge or vertex,
    /// still alike (a flat face facing the same way, an edge of the same
    /// kind and direction); the others leave the selection. The info line
    /// gives the sizes again, as the model now makes them.
    void keepSelection(Hit[] before, PartMesh[] was)
    {
        import std.algorithm : countUntil;
        import hackerscad.gui.measure : faceItem;
        import hackerscad.kernel.brep : EdgeKind;
        if (before.length == 0)
            return;
        Hit[] kept;
        foreach (h; before)
        {
            if (h.part < 0 || h.part >= was.length)
                continue;
            immutable pi = last.parts.countUntil!(q => q.name == was[h.part].name);
            if (pi < 0)
                continue;
            auto p = last.parts[pi], old = was[h.part];
            if (h.edge >= 0)
            {
                if (h.edge >= p.edgeInfo.length || h.edge >= old.edgeInfo.length)
                    continue;
                auto e = p.edgeInfo[h.edge], o = old.edgeInfo[h.edge];
                if (e.kind != o.kind || (e.kind == EdgeKind.line && abs(e.direction.dot(o.direction)) < 0.99)
                    || (e.kind == EdgeKind.circle && abs(e.axis.dot(o.axis)) < 0.99))
                    continue;
            }
            else if (h.vertex >= 0)
            {
                if (h.vertex >= viewport.vertices(pi).length)
                    continue;
            }
            else if (h.face >= 0)
            {
                if (h.face + 1 >= p.faceStart.length || h.face + 1 >= old.faceStart.length)
                    continue;
                auto f = faceItem(p, h.face), g = faceItem(old, h.face);
                if (f.planar != g.planar || (f.planar && f.normal.dot(g.normal) < 0.99))
                    continue;
            }
            h.part = cast(int) pi;
            kept ~= h;
        }
        viewport.setSelection(kept);
        if (kept.length == 1)
            infoCard(last.parts[kept[0].part].name, selectionRows());
        else
            showSelection();
    }

    /// The info card of the selection: how many items, their sizes (how far
    /// apart, the room they take); none when nothing is selected.
    void showSelection()
    {
        auto n = viewport.selection().length;
        if (n == 0)
            return info("");
        immutable what = ["part", "face", "edge", "vertex"][viewport.selectMode];
        infoCard(format("%d %s selected", n, n == 1 ? what : what == "vertex" ? "vertices" : what ~ "s"),
            selectionRows(), "right-click: operations · on nothing, Esc or Space: none");
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
        placeCursorQuietly(a);
        editor.scrollToIter(a, 0.1, true, 0, 0.3);
    }

    // ---- section view

    // ---- moving and turning a part by hand

    Box transformBar;
    Label transformTitle, transformValue;
    string transformPartName;

    void buildTransformBar()
    {
        transformBar = new Box(Orientation.Horizontal, 8);
        transformBar.addCssClass("hcad-modebar");
        transformTitle = new Label("");
        transformTitle.setEllipsize(EllipsizeMode.End);
        transformBar.append(transformTitle);
        transformValue = new Label("");
        transformValue.addCssClass("numeric");
        transformValue.setXalign(0);
        transformValue.setHexpand(true);
        transformValue.setEllipsize(EllipsizeMode.End);
        transformBar.append(transformValue);
        // applied and cancelled by the ✓ and the X next to the part
        transformBar.setTooltipText("✓ or Enter writes it into the code, X or Esc leaves the part as it was");
        transformBar.setVisible(false);
    }

    /// The frame (move), the rings (rotate) or the handles (scale) on part `index`.
    void startTransform(Viewport.Gizmo kind, int index)
    {
        if (sceneLocked())
            return;
        if (index < 0 || index >= last.parts.length)
            return;
        auto part = last.parts[index];
        if (part.span.file != absolutePath(path))
            return info(format("part '%s' is defined in another file", part.name));
        transformPartName = part.fn;   // a piece of @parts moves with all its function makes
        viewport.startGizmo(kind, index);
        transformTitle.setLabel((kind == Viewport.Gizmo.move ? "Move " : kind == Viewport.Gizmo.scale ? "Scale "
            : "Rotate ") ~ part.name);
        transformValue.setLabel(transformText());
        transformBar.setVisible(true);
    }

    /// An axis to turn about, and the words that name it in the menu.
    struct Axis
    {
        Vec3 origin, dir;
        string about;
    }

    /// The axes of what is picked on `part`: of one face, its normal through
    /// its middle (round: its axis); of one edge, along it (round: its axis).
    Axis[] pickedAxes(PartMesh part)
    {
        Axis[] r;
        Axis a;
        if (selFaces.length == 1 && pickedAxis(part, true, a.origin, a.dir, a.about))
            r ~= a;
        if (selEdges.length == 1 && pickedAxis(part, false, a.origin, a.dir, a.about))
        {
            // an edge round like the face it bounds turns about the same axis: once
            if (a.about != "its axis" || r.length == 0 || r[0].about != "its axis")
                r ~= a;
        }
        return r;
    }

    /// A menu entry for a turn about `a` (one per call: closures in a loop share one frame).
    MenuEntry hingeEntry(int index, Axis a) =>
        MenuEntry.item("Rotate around " ~ a.about ~ "…", () => startHinge(index, a.origin, a.dir, a.about));

    bool pickedAxis(PartMesh part, bool face, out Vec3 origin, out Vec3 dir, out string about)
    {
        if (part.kernel is null || part.brep is null)
            return false;
        if (face && selFaces.length == 1)
        {
            import hackerscad.kernel.brep : CylinderInfo;
            CylinderInfo cy;
            if (part.kernel.faceCylinder(part.brep, selFaces[0], cy))
            {
                origin = cy.origin;
                dir = cy.axis;
                about = "its axis";
                return true;
            }
            auto faces = part.kernel.faces(part.brep);
            if (selFaces[0] >= faces.length)
                return false;
            origin = faces[selFaces[0]].center;
            dir = faces[selFaces[0]].normal;
            about = "its normal";
            return dir.length > 0.5;
        }
        if (!face && selEdges.length == 1 && selEdges[0] < part.edgeInfo.length)
        {
            auto e = part.edgeInfo[selEdges[0]];
            if (e.kind == EdgeKind.circle)
            {
                origin = e.center;
                dir = e.axis;
                about = "its axis";
            }
            else if (e.kind == EdgeKind.line)
            {
                origin = e.start;
                dir = e.direction;
                about = "this edge";
            }
            else
                return false;
            return dir.length > 0.5;
        }
        return false;
    }

    /// The ring about an axis on part `index`, as a hinge.
    void startHinge(int index, Vec3 origin, Vec3 dir, string about)
    {
        if (sceneLocked())
            return;
        if (index < 0 || index >= last.parts.length)
            return;
        auto part = last.parts[index];
        if (part.span.file != absolutePath(path))
            return info(format("part '%s' is defined in another file", part.name));
        if (sectionToggle.getActive() && splitPart >= 0)
            sectionToggle.setActive(false);
        transformPartName = part.fn;
        viewport.startHinge(index, origin, dir);
        transformTitle.setLabel(format("Rotate %s around %s", part.name, about));
        transformValue.setLabel(transformText());
        transformBar.setVisible(true);
    }

    /// What the drag has done so far, as Apply will write it: how far along
    /// X, Y and Z, the angles about them of all the turns as one, or the
    /// factors and the size they give.
    string transformText()
    {
        // the short way round: several turns of the ring read as what they come to
        import hackerscad.tool.codegen : halfTurn;
        immutable spin = halfTurn(viewport.hingeAngle);
        if (viewport.gizmo == Viewport.Gizmo.hinge && viewport.placeActive)
            return spin == 0 ? "placed" : format("placed, turned %+g°", spin);
        if (viewport.gizmo == Viewport.Gizmo.hinge)
            return spin == 0 ? "not turned" : format("%+g°", spin);
        if (viewport.gizmo == Viewport.Gizmo.move)
        {
            auto m = viewport.gizmoMove;
            string[] parts;
            foreach (i, n; ["X", "Y", "Z"])
                if (m[i] != 0)
                    parts ~= format("%s %+g mm", n, m[i]);
            return parts.length ? parts.join("   ") : "not moved";
        }
        if (viewport.gizmo == Viewport.Gizmo.scale)
            return scaleText(viewport.gizmoScale, viewport.gizmoPart);
        auto angles = combinedTurn();
        string[] parts;
        foreach (i, n; ["X", "Y", "Z"])
            if (angles[i] != 0)
                parts ~= format("%s %+g°", n, angles[i]);
        return parts.length ? parts.join("   ") : "not turned";
    }

    /// The factors as the bar reads them: "× 1.25" alike, else one per axis,
    /// with the size of part `index`'s box they come to.
    string scaleText(Vec3 f, int index)
    {
        string number(double x) => format("%.6g", x);
        string factors = f.x == f.y && f.y == f.z ? "× " ~ number(f.x)
            : format("x × %s · y × %s · z × %s", number(f.x), number(f.y), number(f.z));
        if (f.x == 1 && f.y == 1 && f.z == 1)
            factors = "not scaled";
        if (index < 0 || index >= last.parts.length)
            return factors;
        auto size = last.parts[index].bbox.max - last.parts[index].bbox.min;
        return format("%s   %s × %s × %s mm", factors, number(size.x * f.x), number(size.y * f.y), number(size.z * f.z));
    }

    /// All the turns made, in order, as one: the angles about X, Y and Z
    /// (degrees, between -180 and 180).
    Vec3 combinedTurn()
    {
        import hackerscad.tool.codegen : turnMatrix, turnAngles;
        double[3][3] m = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
        foreach (t; viewport.gizmoTurns)
        {
            Vec3 e;
            e[t.axis] = t.angle;
            auto r = turnMatrix(e);
            double[3][3] p;
            foreach (row; 0 .. 3)
                foreach (col; 0 .. 3)
                {
                    p[row][col] = 0;
                    foreach (q; 0 .. 3)
                        p[row][col] += r[row][q] * m[q][col];
                }
            m = p;
        }
        return turnAngles(m);
    }

    /// The values in the bar, while the part moves or turns.
    void showTransformValue(double x, double y)
    {
        transformValue.setLabel(transformText());
    }

    void cancelTransform()
    {
        if (viewport is null || transformBar is null)
            return;
        viewport.stopPlace();
        viewport.stopGizmo();
        transformBar.setVisible(false);
    }

    /// Writes the move or turn into the part's code (or nothing, if the part
    /// did not move), and takes the frame or rings away.
    void applyTransform()
    {
        if (viewport.gizmo == Viewport.Gizmo.none)
            return;
        if (viewport.gizmo == Viewport.Gizmo.hinge && viewport.placeActive)
        {
            if (auto problem = writePlace(viewport.gizmoPart, viewport.placeFrom, viewport.placeAxis, viewport.placeAngle,
                    viewport.placeTo, viewport.hingeAngle, viewport.placeToN))
            {
                info(problem);
                return cancelTransform();
            }
            viewport.stopGizmo(true);
            transformBar.setVisible(false);
            return;
        }
        if (viewport.gizmo == Viewport.Gizmo.hinge)
        {
            import hackerscad.tool.codegen : halfTurn;
            if (halfTurn(viewport.hingeAngle) == 0)
                return cancelTransform();
            if (auto problem = writeHinge(viewport.gizmoPart, viewport.hingeAngle, viewport.hingeOrigin, viewport.hingeDir))
            {
                info(problem);
                return cancelTransform();
            }
            viewport.stopGizmo(true);
            transformBar.setVisible(false);
            return;
        }
        Turn[] steps;
        if (viewport.gizmo == Viewport.Gizmo.scale)
        {
            // about the middle of the bottom of its box: a part on the ground stays on it
            immutable f = viewport.gizmoScale;
            if (f.x == 1 && f.y == 1 && f.z == 1)
                return cancelTransform();
            if (auto problem = writeTransform(viewport.gizmoPart, "scale", f, viewport.gizmoAnchor))
            {
                info(problem);
                return cancelTransform();
            }
            viewport.stopGizmo(true);
            transformBar.setVisible(false);
            return;
        }
        if (viewport.gizmo == Viewport.Gizmo.move)
        {
            if (viewport.gizmoMove.length > 0)
                steps ~= Turn("move", viewport.gizmoMove);
        }
        else
        {
            auto angles = combinedTurn();
            if (angles.length > 0)
                steps ~= Turn("rotate", angles);
        }
        if (steps.length == 0)
            return cancelTransform();
        if (auto problem = writeTransforms(viewport.gizmoPart, steps, viewport.gizmoCentre))
        {
            info(problem);
            return cancelTransform();
        }
        viewport.stopGizmo(true);
        transformBar.setVisible(false);
    }

    /// A move (by v, mm), a turn (v the angles about X, Y, Z, degrees) or a
    /// scale (v the factors along X, Y, Z).
    struct Turn
    {
        string kind;
        Vec3 v;
    }

    /// Moves (kind "move", by v in mm), turns (kind "rotate", v the angles
    /// in degrees, about `around`) or scales (kind "scale", v the factors,
    /// keeping `around` where it is) part `name` in the code; the problem, or null.
    string writeTransform(int index, string kind, Vec3 v, Vec3 around) =>
        writeTransforms(index, [Turn(kind, v)], around);

    /// Place on…'s code for part `index`: the turn of `angle` degrees about
    /// `axis` through `from`, the move from `from` to `to`, then the spin
    /// about `toN` through `to`, as one change; the problem, or null.
    string writePlace(int index, Vec3 from, Vec3 axis, double angle, Vec3 to, double spin, Vec3 toN)
    {
        if (busy())
            return "wait for the evaluation to finish, then try again";
        if (index < 0 || index >= last.parts.length)
            return "no part to place";
        try
        {
            import hackerscad.tool.codegen : appendToPiece, hingePart, hingePiece, transformPiece;
            import std.math : round;
            auto p = last.parts[index];
            immutable piece = isPiece(index);
            auto before = text(), after = before;
            // the angle and the move rounded where they are whole (a cube's face turns by 90)
            auto a = abs(angle - round(angle)) < 1e-6 ? round(angle) : angle;
            auto move = to - from;
            foreach (i; 0 .. 3)
                move[i] = round(move[i] * 1000) / 1000;
            // a placeOn onto the face (or the ground) when both faces are flat: it
            // follows the other part when that changes; otherwise the turns and the move
            if (auto call = placeCode(index, from, axis, angle, to, spin, toN))
                after = (piece ? appendToPiece(after, path, p.fn, p.piece, p.fromSolid, call)
                    : appendToPart(after, path, p.fn, call)).apply(after);
            else
            {
                if (abs(a) > 1e-6)
                    after = (piece ? hingePiece(after, path, p.fn, p.piece, p.fromSolid, a, from, axis)
                        : hingePart(after, path, p.fn, a, from, axis)).apply(after);
                if (move.length > 1e-6)
                    after = (piece ? transformPiece(after, path, p.fn, p.piece, p.fromSolid, "move", move)
                        : transformPart(after, path, p.fn, "move", move)).apply(after);
                if (abs(spin) > 1e-6)
                    after = (piece ? hingePiece(after, path, p.fn, p.piece, p.fromSolid, spin, to, toN)
                        : hingePart(after, path, p.fn, spin, to, toN)).apply(after);
            }
            if (after == before)
                return "it is there already";
            size_t head, tail;
            while (head < before.length && head < after.length && before[head] == after[head])
                head++;
            while (tail < before.length - head && tail < after.length - head && before[$ - 1 - tail] == after[$ - 1 - tail])
                tail++;
            Edit e;
            e.offset = head;
            e.length = before.length - head - tail;
            e.text = after[head .. $ - tail];
            e.selectOffset = after.length - tail;
            applyEdit(e);
            viewport.setSelection(null);
            info("");
            return null;
        }
        catch (CodegenException e)
            return e.msg;
        catch (HcadError e)
            return "fix the errors in the code first: " ~ e.msg;
    }

    /// Place on…'s placeOn call, or null when it cannot be one: the face of
    /// part `index` that `from` lies on (facing -toN once turned by `angle`
    /// about `axis`) laid against the face of another part that `to` lies on
    /// (or the ground), both flat and named by selectors, turned about the
    /// target's normal so that it lies as the preview showed it (`spin` more).
    string placeCode(int index, Vec3 from, Vec3 axis, double angle, Vec3 to, double spin, Vec3 toN)
    {
        import hackerscad.tool.codegen : faceSelector, frameExpr, groundFrame, placeOnCall, pointMm;
        import hackerscad.lang.builtins : faceXAxis;
        import std.math : atan2;
        toN = toN.normalized;
        auto p = last.parts[index];
        auto fromN = turned(axis, -angle, toN * -1);
        immutable sf = faceAt(p, from, fromN);
        if (sf < 0 || !isFlat(p, sf))
            return null;
        SolidVal sv;
        auto fromSel = faceSelector(selectorInterp(p, sv), sv, sf);
        auto fi = p.kernel.faces(p.brep)[sf];
        auto at = (from - fi.center).length < 1e-3 ? null : pointMm(from);
        // where it goes: a face of another part of this file, or the ground
        string onto;
        foreach (j, q; last.parts)
        {
            if (j == index)
                continue;
            immutable tf = faceAt(q, to, toN);
            if (tf < 0)
                continue;
            if (q.piece >= 0 || q.span.file != absolutePath(path) || !isFlat(q, tf))
                return null;
            SolidVal tv;
            auto ti = q.kernel.faces(q.brep)[tf];
            onto = frameExpr(q.fn ~ "()", faceSelector(selectorInterp(q, tv), tv, tf),
                (to - ti.center).length < 1e-3 ? null : pointMm(to));
            break;
        }
        if (onto is null)
        {
            if (abs(to.z) > 1e-6 || toN.z < 1 - 1e-6)
                return null;
            onto = groundFrame(to);
        }
        // the frame's X carried as the preview carries it, and how far round from the target's X
        auto xf = turned(toN, spin, turned(axis, angle, faceXAxis(fromN)));
        auto xt = faceXAxis(toN), yt = toN.cross(xt);
        return placeOnCall(onto, fromSel, at, atan2(xf.dot(yt), xf.dot(xt)) * 180 / PI);
    }

    /// `v` turned by `degrees` about the unit direction `k` (counter-clockwise looking down it).
    static Vec3 turned(Vec3 k, double degrees, Vec3 v)
    {
        import std.math : cos, sin;
        immutable r = degrees * PI / 180;
        k = k.normalized;
        return v * cos(r) + k.cross(v) * sin(r) + k * (k.dot(v) * (1 - cos(r)));
    }

    /// The face of `p` that point `at` lies on with outward normal `n`, or -1.
    static int faceAt(PartMesh p, Vec3 at, Vec3 n)
    {
        if (p.kernel is null || p.brep is null || p.flat || p.path)
            return -1;
        auto fs = p.kernel.faces(p.brep);
        double best = 1e-3 * max(1.0, p.bbox.size.length);
        int r = -1;
        foreach (f, info; fs)
        {
            if (info.normal.dot(n.normalized) < 1 - 1e-4 || f + 1 >= p.faceStart.length)
                continue;
            // its middle, an anchor even where it is not on the face (a rim's, in the hole)
            if ((at - info.center).length < best)
            {
                best = (at - info.center).length;
                r = cast(int) f;
            }
            foreach (t; p.faceStart[f] .. p.faceStart[f + 1])
            {
                Vec3 corner(uint c)
                {
                    immutable q = p.indices[3 * t + c] * 6;
                    return Vec3(p.vertices[q], p.vertices[q + 1], p.vertices[q + 2]);
                }
                immutable d = triangleDistance(at, corner(0), corner(1), corner(2));
                if (d < best)
                {
                    best = d;
                    r = cast(int) f;
                }
            }
        }
        return r;
    }

    /// How far `p` is from the triangle a b c.
    static double triangleDistance(Vec3 p, Vec3 a, Vec3 b, Vec3 c)
    {
        auto n = (b - a).cross(c - a);
        if (n.length > 1e-12)
        {
            n = n.normalized;
            auto q = p - n * (p - a).dot(n);
            // inside when on the same side of every edge
            immutable s1 = (b - a).cross(q - a).dot(n), s2 = (c - b).cross(q - b).dot(n), s3 = (a - c).cross(q - c).dot(n);
            if (s1 >= 0 && s2 >= 0 && s3 >= 0)
                return abs((p - a).dot(n));
        }
        double segment(Vec3 u, Vec3 v)
        {
            auto d = v - u;
            immutable t = d.length < 1e-12 ? 0 : clamp((p - u).dot(d) / d.dot(d), 0.0, 1.0);
            return (p - (u + d * t)).length;
        }
        return min(segment(a, b), segment(b, c), segment(c, a));
    }

    /// Whether face `face` of `p` is flat (a frame can stand on it).
    static bool isFlat(PartMesh p, int face)
    {
        auto f = p.kernel.faces(p.brep)[face];
        immutable size = max(1.0, p.bbox.size.length);
        foreach (loop; p.kernel.faceLoops(p.brep, face, 1e-3 * size))
            foreach (q; loop)
                if (abs((q - f.center).dot(f.normal)) > 1e-6 * size)
                    return false;
        return true;
    }

    /// Place on… from a face of part `index`, `at` the point clicked on it:
    /// the face's anchor nearest that point is carried.
    void startPlaceOn(int index, int face, Vec3 at)
    {
        if (sceneLocked())
            return;
        if (index < 0 || index >= last.parts.length)
            return;
        auto part = last.parts[index];
        if (part.span.file != absolutePath(path))
            return info(format("part '%s' is defined in another file", part.name));
        if (sectionToggle.getActive() && splitPart >= 0)
            sectionToggle.setActive(false);
        cancelTransform();
        Vec3 n;
        auto anchors = viewport.faceAnchors(index, face, n);
        if (anchors.length == 0 || n.length < 0.5)
            return info("that face has no corner or middle to place from");
        auto from = anchors[0];
        foreach (a; anchors)
            if ((a - at).length < (from - at).length)
                from = a;
        viewport.startPlace(index, from, n);
        transformTitle.setLabel("Place " ~ part.name);
        transformValue.setLabel("click where the green point goes: a corner or the middle of a face, or the ground");
        transformBar.setVisible(true);
        info("Place " ~ part.name ~ ": click a corner or the middle of another face, or the ground · Esc cancels");
    }

    /// Turns part `index` by `angle` degrees about the axis through `origin`
    /// along `dir`, in the code (a piece of @parts alone); the problem, or null.
    string writeHinge(int index, double angle, Vec3 origin, Vec3 dir)
    {
        if (busy())
            return "wait for the evaluation to finish, then try again";
        if (index < 0 || index >= last.parts.length)
            return "no part to turn";
        try
        {
            import hackerscad.tool.codegen : hingePart, hingePiece;
            auto p = last.parts[index];
            applyEdit(isPiece(index) ? hingePiece(text(), path, p.fn, p.piece, p.fromSolid, angle, origin, dir)
                : hingePart(text(), path, p.fn, angle, origin, dir));
            viewport.setSelection(null);
            info("");
            return null;
        }
        catch (CodegenException e)
            return e.msg;
        catch (HcadError e)
            return "fix the errors in the code first: " ~ e.msg;
    }

    /// Whether part `index` is one piece of several made by @parts: what is
    /// written for it goes to that piece alone (pieces[k] = pieces[k]…).
    bool isPiece(size_t index) => index < last.parts.length && last.parts[index].piece >= 0
        && (last.parts[index].name != last.parts[index].fn || !last.parts[index].fromSolid);

    /// The moves and turns one after the other, in one change of the code.
    string writeTransforms(int index, Turn[] steps, Vec3 around)
    {
        if (busy())
            return "wait for the evaluation to finish, then try again";
        try
        {
            import hackerscad.tool.codegen : Edit, transformPiece;
            auto before = text(), after = before;
            if (index < 0 || index >= last.parts.length)
                return "no part to move";
            auto p = last.parts[index];
            foreach (st; steps)
                // a piece of @parts moves alone; any other part, all its function makes
                after = (isPiece(index) ? transformPiece(after, path, p.fn, p.piece, p.fromSolid, st.kind, st.v, around)
                    : transformPart(after, path, p.fn, st.kind, st.v, around)).apply(after);
            // only what changed is replaced: between what both texts start and end with
            size_t head, tail;
            while (head < before.length && head < after.length && before[head] == after[head])
                head++;
            while (tail < before.length - head && tail < after.length - head
                && before[$ - 1 - tail] == after[$ - 1 - tail])
                tail++;
            Edit e;
            e.offset = head;
            e.length = before.length - head - tail;
            e.text = after[head .. $ - tail];
            e.selectOffset = after.length - tail;
            applyEdit(e);
            viewport.setSelection(null);
            info("");
            return null;
        }
        catch (CodegenException e)
            return e.msg;
        catch (HcadError e)
            return "fix the errors in the code first: " ~ e.msg;
    }

    void buildSectionBar()
    {
        buildModeBar();
        sectionBar = new Box(Orientation.Horizontal, 8);
        sectionBar.addCssClass("hcad-sectionbar");
        sectionTitle = new Label("Section");
        sectionTitle.addCssClass("dim-label");
        sectionBar.append(sectionTitle);
        sectionPlane = DropDown.newFromStrings(["XY plane", "XZ plane", "YZ plane", "Selected face"]);
        sectionPlane.addCssClass("flat");
        sectionPlane.setTooltipText("The cutting plane: parallel to a main plane, or to the face you clicked");
        sectionPlane.connectNotify("selected", () {
            if (!sectionUpdating)
                updateSection(true);
        });
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
            if (!facePlane(p, n))
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
        viewport.extentAlong(n, lo, hi, splitPart);
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
        // the half towards the viewer goes, so that the cut faces them
        if (reset)
            sectionFlipped = through != through && n.dot(viewport.viewDirection()) > 0;
        sectionUpdating = true;
        sectionFlip.setActive(sectionFlipped);
        sectionUpdating = false;
        applySection();
    }

    // ---- splitting a part in two (Split… in the right-click menu): the
    // section, its plane as big as the part, and a ✓ that writes the cut

    Label sectionTitle;
    int splitPart = -1;
    string splitName;
    bool splitFace;             /// Split… opened on a face: its plane is offered first
    Vec3 splitFaceP, splitFaceN;

    /// The face the section's fourth choice is parallel to: the one Split…
    /// was opened on, else the face picked; false when there is none.
    bool facePlane(out Vec3 p, out Vec3 n)
    {
        if (splitPart >= 0)
        {
            p = splitFaceP;
            n = splitFaceN;
            return splitFace;
        }
        return viewport.selectedPlane(p, n);
    }

    /// The section's plane choices: the main planes, and a face's only when
    /// there is one ("Clicked face" for Split…, "Selected face" else).
    void refreshPlaneChoices()
    {
        import gtk.string_list : StringList;
        Vec3 p, n;
        immutable face = facePlane(p, n);
        auto items = ["XY plane", "XZ plane", "YZ plane"];
        if (face)
            items ~= splitPart >= 0 ? "Clicked face" : "Selected face";
        immutable was = sectionPlane.getSelected();
        sectionUpdating = true;
        sectionPlane.setModel(new StringList(items));
        sectionPlane.setSelected(was < items.length ? was : 0);
        sectionUpdating = false;
    }

    /// The section plane on part `index` alone, to split it where it is.
    void startSplit(int index, bool onFace = false, Vec3 facePoint = Vec3(0, 0, 0), Vec3 faceNormal = Vec3(0, 0, 1))
    {
        if (sceneLocked())
            return;
        if (index < 0 || index >= last.parts.length)
            return;
        auto part = last.parts[index];
        if (part.span.file != absolutePath(path))
            return info(format("part '%s' is defined in another file", part.name));
        if (part.fn != part.name)
            return info(format("%s is a piece of %s (@parts): split what %s returns in the code, or each piece "
                ~ "in its own @part", part.name, part.fn, part.fn));
        cancelTransform();
        splitPart = index;
        splitName = part.name;
        splitFace = onFace;
        splitFaceP = facePoint;
        splitFaceN = faceNormal.normalized;
        viewport.sectionPart = index;
        sectionTitle.setLabel("Split " ~ part.name);
        sectionTitle.removeCssClass("dim-label");
        if (sectionToggle.getActive())
        {
            planeFromSelection();
            updateSection(true);
        }
        else
            sectionToggle.setActive(true);
        viewport.makeRoom();
        info(format("move the plane, then ✓ splits %s into a part per piece (X leaves it whole)", part.name));
    }

    /// Opening the section or Split…: a face picked gives the plane, else a
    /// main plane (the last one chosen, or XY).
    void planeFromSelection()
    {
        Vec3 p, n;
        immutable picked = facePlane(p, n);
        refreshPlaneChoices();
        immutable want = picked ? 3 : sectionPlane.getSelected() == 3 ? 0 : sectionPlane.getSelected();
        sectionUpdating = true;
        sectionPlane.setSelected(want);
        sectionUpdating = false;
    }

    /// Back to a plain section (or none).
    void endSplit()
    {
        if (splitPart < 0)
            return;
        splitPart = -1;
        splitFace = false;
        viewport.sectionPart = -1;
        sectionTitle.setLabel("Section");
        sectionTitle.addCssClass("dim-label");
    }

    /// Writes the split where the plane is; the problem, or null.
    string applySplit()
    {
        if (splitPart < 0)
            return null;
        return writeSplit(splitPart, sectionNormal, sectionSlider.getValue());
    }

    /// How many separate bodies part `index` leaves below and above the
    /// plane of normal `n` at `at` mm along it (0: none, the plane misses it).
    int[2] splitPieces(int index, Vec3 n, double at)
    {
        import std.math : PI, acos;
        import hackerscad.kernel.brep : BoolOp;
        auto part = last.parts[index];
        auto k = part.kernel;
        if (k is null || part.brep is null)
            return [1, 1];
        n = n.normalized;
        auto o = n * at;
        auto bb = k.bbox(part.brep);
        immutable size = 4 * (bb.size.length + (bb.center - o).length) + 10;
        // a box covering what lies on side `d` of the plane, as split() makes it
        auto half(Vec3 d)
        {
            auto b = k.translate(k.box(size, size, size), Vec3(-size / 2, -size / 2, 0));
            immutable c = d.dot(Vec3(0, 0, 1));
            if (c < -1 + 1e-12)
                b = k.rotate(b, Vec3(1, 0, 0), PI);
            else if (c < 1 - 1e-12)
                b = k.rotate(b, Vec3(0, 0, 1).cross(d), acos(c));
            return k.translate(b, o);
        }
        int count(Vec3 d)
        {
            auto rest = k.boolean(part.brep, half(d), BoolOp.cut);
            return rest is null ? 0 : cast(int) k.solids(rest).length;
        }
        return [count(n), count(n * -1)];
    }

    /// Splits part `index` along the plane of normal `n` at `at` mm along it,
    /// in the code, a part per body; the problem, or null.
    string writeSplit(int index, Vec3 n, double at)
    {
        if (busy())
            return "wait for the evaluation to finish, then try again";
        if (last.parts[index].fn != last.parts[index].name)
            return format("%s is a piece of %s (@parts): split what %s returns in the code", last.parts[index].name,
                last.parts[index].fn, last.parts[index].fn);
        int[2] pieces;
        try
            pieces = splitPieces(index, n, at);
        catch (Exception e)
            return "cannot cut the part there: " ~ e.msg;
        if (pieces[0] == 0 || pieces[1] == 0)
            return format("the plane does not cut %s: move it inside the part", last.parts[index].name);
        try
        {
            import hackerscad.tool.codegen : splitPart;
            applyEdit(splitPart(text(), path, last.parts[index].name, n, at));
        }
        catch (CodegenException e)
            return e.msg;
        catch (HcadError e)
            return "fix the errors in the code first: " ~ e.msg;
        // done: Split… closes, whoever wrote it
        if (splitPart >= 0)
            sectionToggle.setActive(false);
        info(format("%s split into %d parts, one per piece", last.parts[index].name, pieces[0] + pieces[1]));
        return null;
    }

    void applySection()
    {
        // the slider can move with the section closed (a new model's range):
        // that must not bring the plane back
        if (!sectionToggle.getActive())
            return viewport.setSection(false, sectionNormal, 0);
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
        followTakenOver();
        inspectRequest++;   // an Inspect on its way would replace the rollback
        jumpTo(f.span, format("rollback · line %d · %s (computing…)", f.span.line, f.kind));
        evaluator.prepareFeature(f, f.kind, (PartMesh m) {
            viewport.showRollback(m, id);
            info(format("rollback · line %d · %s%s · its new faces in orange", f.span.line, f.kind, f.moved ? " (moved)" : ""));
            showModeBar(format("Model after line %d (%s%s)", f.span.line, f.kind, f.moved ? ", moved" : ""));
        });
    }

    /// A row of the feature tree: every run of that line of code. One run of
    /// a feature rolls back to it; many runs show what they all made; a union,
    /// difference or intersection shows its two operands in two colours.
    void showFeature(uint[] ids)
    {
        if (sceneLocked())
            return;
        import std.algorithm : filter;
        import std.array : array;

        ids = ids.filter!(id => id > 0 && id <= last.features.length).array;
        if (ids.length == 0)
            return;
        followTakenOver();
        auto f = last.features[ids[$ - 1] - 1];
        immutable boolean = f.operands.length == 2;
        // the step of a sketch (or of what its profile made on that line): the sketch too
        if (f.span.file == absolutePath(path))
            showSketchOn(f.span.line, f.span.line, false);
        else
            hideSketch();
        if (ids.length == 1 && !boolean)
            return rollTo(ids[0]);

        immutable request = ++inspectRequest;
        immutable runs = ids.length > 1 ? format(" ×%d", ids.length) : "";
        jumpTo(f.span, format("line %d · %s%s (computing…)", f.span.line, f.kind, runs));
        SolidVal[] vals;
        Vec3[] colors;
        string legend;
        if (boolean)
        {
            immutable first = Vec3(0.25, 0.5, 0.86);
            immutable second = f.kind == "difference" ? Vec3(0.86, 0.22, 0.18)
                : f.kind == "union" ? Vec3(0.2, 0.66, 0.32) : Vec3(0.56, 0.36, 0.82);
            bool[void*] seen;   // identical runs are shown once (and counted)
            foreach (id; ids)
            {
                auto g = last.features[id - 1];
                if (g.operands.length != 2)
                    continue;
                foreach (k, op; g.operands)
                {
                    if (op is null || cast(void*) op.brep in seen)
                        continue;
                    seen[cast(void*) op.brep] = true;
                    vals ~= op;
                    colors ~= k == 0 ? first : second;
                }
            }
            string sq(Vec3 c) => format(`<span foreground="#%02X%02X%02X">■</span>`,
                cast(int)(c.x * 255), cast(int)(c.y * 255), cast(int)(c.z * 255));
            immutable what = f.kind == "difference" ? "taken away" : f.kind == "union" ? "added" : "intersected";
            legend = format("%s first operand · %s second operand (%s)", sq(first), sq(second), what);
        }
        else
        {
            bool[void*] seen;
            foreach (id; ids)
            {
                auto r = last.features[id - 1].result;
                if (r is null || cast(void*) r.brep in seen)
                    continue;
                seen[cast(void*) r.brep] = true;
                vals ~= r;
            }
        }
        // the same words as a function's "returns": identical runs are shown once
        immutable different = boolean ? 0 : vals.length;
        immutable shown = ids.length > 1 && !boolean && different < ids.length
            ? format(" · %d different result%s shown", different, different == 1 ? "" : "s") : "";
        evaluator.prepareSolids(vals, (PartMesh[] ms) {
            if (request != inspectRequest)
                return;
            if (viewport.inRollback)
                viewport.clearRollback();
            viewport.showInspect(ms, colors);
            inspectQuery = InspectQuery.init;   // a feature row: not asked again after a run
            inspectShown = null;
            immutable where = format("Line %d · %s%s%s", f.span.line, f.kind, runs, shown);
            info(where ~ (boolean ? " · its operands" : " · every run"));
            showModeBar(boolean ? where ~ ": " ~ legend : where ~ ": what every run made", boolean);
        });
    }

    MenuButton partsMenu;   /// the eye of the view bar
    MenuButton displayMenu; /// the cube of the view bar: drawing style and projection
    ViewStack sideStack;    /// the sidebar: Parameters and Steps
    static int[2] startSize = [1440, 880];   /// of the window (--size=WxH)
    static string startName;   /// the first window's name (--name=NAME), if free
    static string startText;   /// the first window's code, in a model of no file (--copy=FILE)
    Paned mainPaned;        /// the code on the left, the rest on the right
    import gtk.check_button : CheckButton;
    CheckButton[Shading] shadingChoice;
    CheckButton perspectiveChoice, orthographicChoice, antialiasChoice, printabilityChoice;
    CheckButton[3] shineChoice;   /// none, normal, high

    /// The shine chosen last (Normal the first time).
    static Shine savedShine()
    {
        import hackerscad.gui.settings : setting;
        immutable v = setting("shine", "normal");
        return v == "none" ? Shine.none : v == "high" ? Shine.high : Shine.normal;
    }


    Box printLimits;
    import gtk.spin_button : SpinButton;
    SpinButton overhangSpin, wallSpin;

    /// What the printability style finds, per part shown.
    JValue printabilityJson()
    {
        JValue ps = JSAB();
        foreach (i, p; last.parts)
        {
            if (viewport.isHidden(i))
                continue;
            auto pc = viewport.printCheckOf(i);
            JValue jp = JSOB("part", p.name);
            jp["overhang_mm2"] = pc.overhangArea;
            jp["thin_wall_mm2"] = pc.thinArea;
            if (pc.thinArea > 0)
                jp["thinnest_mm"] = pc.thinnest;
            ps ~= jp;
        }
        JValue j = JSOB("overhang_angle_deg", viewport.overhangAngle * 180 / PI, "min_wall_mm", viewport.minWall);
        j["parts"] = ps;
        return j;
    }

    /// The printability totals in the status line.
    void printSummary()
    {
        double over = 0, thin = 0, thinnest = double.infinity;
        foreach (i; 0 .. last.parts.length)
            if (!viewport.isHidden(i))
            {
                auto pc = viewport.printCheckOf(i);
                over += pc.overhangArea;
                thin += pc.thinArea;
                thinnest = min(thinnest, pc.thinnest);
            }
        if (over < 0.5 && thin < 0.5)
            return info("printability: no overhangs, no thin walls");
        string[] what;
        if (over >= 0.5)
            what ~= format("%.0f mm² overhangs (red)", over);
        if (thin >= 0.5)
            what ~= format("%.0f mm² thin walls (violet, %.2f mm)", thin, thinnest);
        info("printability: " ~ what.join(", "));
    }

    /// What the cube of the view bar opens: how the parts are drawn and the projection.
    Popover displayPopover()
    {
        auto box = new Box(Orientation.Vertical, 2);
        void heading(string text)
        {
            auto l = new Label(text);
            l.setXalign(0);
            l.addCssClass("heading");
            box.append(l);
        }
        CheckButton choice(string label, string tooltip, CheckButton group, void delegate() chosen)
        {
            auto b = new CheckButton;
            b.setLabel(label);
            b.setTooltipText(tooltip);
            if (group !is null)
                b.setGroup(group);
            b.connectToggled(() {
                if (b.getActive() && viewport !is null)
                    chosen();
            });
            box.append(b);
            return b;
        }
        void style(Shading sh, string label, string tooltip)
        {
            auto group = Shading.edges in shadingChoice;
            shadingChoice[sh] = choice(label, tooltip, group ? *group : null, () => viewport.setShading(sh));
        }
        heading("Style");
        style(Shading.edges, "Shaded with edges", "Surfaces with their edges outlined");
        style(Shading.shaded, "Shaded", "Surfaces only, without edges");
        style(Shading.wireframe, "Wireframe", "Edges only, the hidden ones faint");
        import gtk.separator : Separator;
        box.append(new Separator(Orientation.Horizontal));
        heading("Check");
        // over any style: marks, not a way of drawing
        printabilityChoice = new CheckButton;
        printabilityChoice.setLabel("Printability");
        printabilityChoice.setTooltipText("For 3D printing: in red what overhangs and needs supports, in violet "
            ~ "the walls thinner than the nozzle can print (the part rests on its lowest face), in any style");
        printabilityChoice.connectToggled(() {
            immutable on = printabilityChoice.getActive();
            printLimits.setVisible(on);
            if (viewport is null)
                return;
            viewport.setPrintability(on);
            if (on)
                printSummary();
            else
                info("");
        });
        box.append(printabilityChoice);
        {
            // the limits: the steepest overhang from a wall, the thinnest wall
            import gtk.spin_button : SpinButton;
            printLimits = new Box(Orientation.Horizontal, 6);
            printLimits.setMarginStart(28);
            overhangSpin = SpinButton.newWithRange(0, 89, 5);
            overhangSpin.setValue(45);
            overhangSpin.setTooltipText("Overhangs steeper than this from a vertical wall are red (45° prints on "
                ~ "most printers)");
            wallSpin = SpinButton.newWithRange(0.1, 5, 0.1);
            wallSpin.setDigits(1);
            wallSpin.setValue(0.8);
            wallSpin.setTooltipText("Walls thinner than this are violet (two lines of a 0.4 mm nozzle: 0.8 mm)");
            void changed()
            {
                if (viewport is null)
                    return;
                viewport.setPrintLimits(overhangSpin.getValue() * PI / 180, wallSpin.getValue());
                if (viewport.printability)
                    printSummary();
            }
            overhangSpin.connectValueChanged(() => changed());
            wallSpin.connectValueChanged(() => changed());
            printLimits.append(new Label("overhang °"));
            printLimits.append(overhangSpin);
            printLimits.append(new Label("wall mm"));
            printLimits.append(wallSpin);
            printLimits.setVisible(false);
            box.append(printLimits);
        }
        // built before the view: its defaults
        shadingChoice[Shading.edges].setActive(true);
        box.append(new Separator(Orientation.Horizontal));
        heading("Projection");
        perspectiveChoice = choice("Perspective", "Far things look smaller, as in a photo", null,
            () => viewport.setOrthographic(false));
        orthographicChoice = choice("Orthographic", "Parallel lines stay parallel: sizes do not change with depth",
            perspectiveChoice, () => viewport.setOrthographic(true));
        perspectiveChoice.setActive(true);
        box.append(new Separator(Orientation.Horizontal));
        heading("Sketches");
        {
            // kept between runs
            import hackerscad.gui.settings : setting;
            followCursor = setting("sketch-follow", "on") != "off";
            followChoice = new CheckButton;
            followChoice.setLabel("Show the sketch at the cursor");
            followChoice.setTooltipText("With the cursor in a sketch's code, the view shows that sketch from above, "
                ~ "with its dimensions and what the cursor's line makes in orange; out of it, the model again");
            followChoice.setActive(followCursor);
            followChoice.connectToggled(() {
                if (followChoice.getActive() != followCursor)
                    setFollow(followChoice.getActive());
            });
            box.append(followChoice);
        }
        box.append(new Separator(Orientation.Horizontal));
        // how shiny the surfaces are, kept between runs like the smoothing of edges
        heading("Shine");
        {
            import hackerscad.gui.settings : setSetting, setting;
            static immutable string[3] keys = ["none", "normal", "high"];
            auto pick(Shine sh) => () {
                setSetting("shine", keys[sh]);
                viewport.setShine(sh);
            };
            shineChoice[Shine.none] = choice("None", "Matte, the light in parallel rays as from the sun: each flat "
                ~ "face one even tone, no shiny spots", null, pick(Shine.none));
            shineChoice[Shine.normal] = choice("Normal", "A light from where you look, a small highlight on curves",
                shineChoice[Shine.none], pick(Shine.normal));
            shineChoice[Shine.high] = choice("High", "A shiny material: soft highlights on every curve, at any angle",
                shineChoice[Shine.none], pick(Shine.high));
            shineChoice[savedShine()].setActive(true);
        }
        box.append(new Separator(Orientation.Horizontal));
        heading("Quality");
        // kept between runs: on a slow integrated card the user may want it off
        {
            import hackerscad.gui.settings : setSetting, setting;
            antialiasChoice = new CheckButton;
            antialiasChoice.setLabel("Smooth edges");
            antialiasChoice.setTooltipText("Antialiasing: edges and curves without steps. It asks more of the graphics "
                ~ "card: turn it off if turning the view is slow (it is off when the processor draws)");
            antialiasChoice.setActive(setting("antialias", "on") != "off");
            antialiasChoice.connectToggled(() {
                setSetting("antialias", antialiasChoice.getActive() ? "on" : "off");
                if (viewport !is null)
                    viewport.setAntialias(antialiasChoice.getActive());
            });
            box.append(antialiasChoice);
        }
        auto pop = new Popover;
        pop.setChild(box);
        return pop;
    }

    /// What the eye opens: the parts with a check each.
    Popover partsPopover()
    {
        auto box = new Box(Orientation.Vertical, 6);
        box.append(params.partsWidget);
        auto all = new Button;
        all.setLabel("Show all");
        all.connectClicked(() {
            foreach (i; 0 .. last.parts.length)
                viewport.setHidden(i, false);
            refreshPartList();
        });
        box.append(all);
        // the ground grid and the axes, kept between runs
        {
            import gtk.separator : Separator;
            import hackerscad.gui.settings : setSetting, setting;
            box.append(new Separator(Orientation.Horizontal));
            gridChoice = new CheckButton;
            gridChoice.setLabel("Ground grid");
            gridChoice.setTooltipText("The grid of the plane the parts stand on, 10 mm squares");
            axesChoice = new CheckButton;
            axesChoice.setLabel("Axes");
            axesChoice.setTooltipText("The X (red) and Y (green) axes on the ground");
            gridChoice.setActive(setting("grid", "on") != "off");
            axesChoice.setActive(setting("axes", "on") != "off");
            void changed()
            {
                setSetting("grid", gridChoice.getActive() ? "on" : "off");
                setSetting("axes", axesChoice.getActive() ? "on" : "off");
                if (viewport !is null)
                    viewport.setGuides(gridChoice.getActive(), axesChoice.getActive());
            }
            gridChoice.connectToggled(() => changed());
            axesChoice.connectToggled(() => changed());
            box.append(gridChoice);
            box.append(axesChoice);
            if (viewport !is null)
                viewport.setGuides(gridChoice.getActive(), axesChoice.getActive());
        }
        auto pop = new Popover;
        pop.setChild(box);
        return pop;
    }

    CheckButton gridChoice, axesChoice;   /// in the eye's menu

    void refreshPartList()
    {
        params.refreshParts();
        import std.algorithm : map;
        import std.array : array;
        params.updateParts(last.parts.map!(p => p.name).array, last.parts.map!(p => p.rgb).array, &viewport.isHidden);
    }

    // ---- the bar that tells the view is not showing the final model

    Box modeBar;
    Label modeText;
    Button runButton;   /// Run 1 of 2: the next run of a sketch made again

    void buildModeBar()
    {
        import gtk.image : Image;

        modeBar = new Box(Orientation.Horizontal, 8);
        modeBar.addCssClass("hcad-modebar");
        auto icon = new Image;
        icon.setFromIconName("edit-find-symbolic");
        modeBar.append(icon);
        modeText = new Label("");
        modeText.setEllipsize(EllipsizeMode.End);
        modeText.setMaxWidthChars(48);
        modeText.setXalign(0);
        modeText.setHexpand(true);
        modeBar.append(modeText);
        modeBar.append(makePinButton());
        // a sketch made again (a loop, another call): its runs one at a time
        runButton = new Button;
        runButton.addCssClass("flat");
        runButton.setTooltipText("Show the next run of this sketch: a loop or another call made it again");
        runButton.setVisible(false);
        runButton.connectClicked(() {
            if (sketchIndices.length > 1)
                showSketchRun((drawnRuns()[0] + 1) % sketchIndices.length);
        });
        modeBar.append(runButton);
        auto back = new Button;
        back.setLabel("Show final model");
        back.setTooltipText("Back to the parts as the model makes them (Esc)");
        back.addCssClass("suggested-action");
        back.connectClicked(() => showFinal());
        modeBar.append(back);
        modeBar.setVisible(false);
    }

    /// Shows the bar with `text` (Pango markup when `markup`), or hides it (null).
    void showModeBar(string text, bool markup = false)
    {
        if (markup)
            modeText.setMarkup(text);
        else
            modeText.setLabel(text);
        modeText.setTooltipText(text.length > 48 && !markup ? text : null);
        modeBar.setVisible(text.length > 0);
        pinButton.setVisible(sketchFollowing && text.length > 0);
        runButton.setVisible(text.length > 0 && sketchIndices.length > 1);
        showingStep(text.length > 0);
    }

    bool inStep;
    bool[string] hiddenBeforeStep;   /// the parts hidden before a step was shown, by name

    /// A step of the model (rollback, a feature row, Inspect) is shown alone:
    /// the final parts are hidden, their eyes can show them again; back to
    /// the final model, the parts are shown or hidden as they were.
    void showingStep(bool on)
    {
        if (on == inStep)
            return;
        inStep = on;
        if (on)
        {
            hiddenBeforeStep = null;
            foreach (i, part; last.parts)
            {
                if (viewport.isHidden(i))
                    hiddenBeforeStep[part.name] = true;
                viewport.setHidden(i, true);
            }
        }
        else
            foreach (i, part; last.parts)
                viewport.setHidden(i, (part.name in hiddenBeforeStep) !is null);
        params.refreshParts();
        import std.algorithm : map;
        import std.array : array;
        params.updateParts(last.parts.map!(p => p.name).array, last.parts.map!(p => p.rgb).array, &viewport.isHidden);
    }

    /// Back to the final model: closes Inspect and rollback.
    /// A new or another model: everything about the view as at the start
    /// (point of view and zoom with the first result, style, projection,
    /// section, printability limits, what the previous model left open,
    /// selected or hidden, its annotations). Smooth edges, and the preferences kept between
    /// runs (the panels shown, the theme, grid and axes), stay.
    void resetInterface()
    {
        showFinal();
        clearSelection();
        completion.close();
        sectionToggle.setActive(false);
        sectionPlane.setSelected(0);
        sectionFlip.setActive(false);
        sectionFlipped = false;
        cancelTransform();
        inspectToggle.setActive(false);
        hideSketch();
        dropSketches();
        shadingChoice[Shading.edges].setActive(true);
        printabilityChoice.setActive(false);
        if (overhangSpin !is null)
        {
            overhangSpin.setValue(45);
            wallSpin.setValue(0.8);
        }
        perspectiveChoice.setActive(true);
        sideStack.setVisibleChildName("params");
        viewport.showAll();
        // the picture and its marks were of the other model
        unlockView();
    }

    void showFinal()
    {
        if (sceneLocked(false))
            return;
        viewport.clearRollback();
        if (viewport.inInspect)
            stopInspect();
        hideSketch();
        stepsPanel.clearSelection();
        info("");
        showModeBar(null);
    }

    /// The editor's pointer: a lens while a click would inspect (Ctrl held, or the lens armed).
    void updateEditorCursor(bool ctrl)
    {
        editor.setCursorFromName(ctrl || inspectToggle.getActive() ? "zoom-in" : "text");
    }

    // ---- Inspect: from the code to the geometry it makes

    /// Inspects the code at the cursor, or the selected lines.
    void inspectCursor()
    {
        TextIter s, e;
        if (buffer.getSelectionBounds(s, e) && e.getLine() > s.getLine())
        {
            // a selection ending at the start of a line does not take that line
            immutable to = e.getLineOffset() == 0 ? e.getLine() : e.getLine() + 1;
            inspectLines(s.getLine() + 1, max(s.getLine() + 1, to), -1);
            return;
        }
        TextIter it;
        buffer.getIterAtMark(it, buffer.getInsert());
        inspectLines(it.getLine() + 1, it.getLine() + 1, it.getLineOffset() + 1);
    }

    /// Shows what lines from..to made. On the declaration of a function, with
    /// the cursor on or before its name (or a line made nothing), what the
    /// function returns. False, and the view as it was, when nothing is found.
    bool inspectLines(uint from, uint to, int col)
    {
        followTakenOver();
        if (from == to)
            foreach (fn; last.functions)
                if (from >= fn.first && from <= fn.nameSpan.line)
                {
                    immutable onName = from < fn.nameSpan.line || (col > 0 && col <= fn.nameSpan.col + fn.nameSpan.length);
                    if (onName || entriesOn(from, to).length == 0)
                        return inspectFunction(fn);
                    break;
                }
        auto made = entriesOn(from, to);
        SketchView.Found[] found;
        immutable onSketch = sketchesOn(from, to, found).length > 0;
        if (made.length == 0 && !onSketch)
            return false;
        // a line of a sketch: the sketch, and in orange what the line makes or constrains in it
        if (made.length == 0)
            return inspectSketch(from, to, true, col);
        inspectQuery = InspectQuery(from, to, col, null);
        showInspected(made, from == to ? format("line %d", from) : format("lines %d–%d", from, to), false);
        if (onSketch)
            showSketchOn(from, to, true);
        else
            hideSketch();
        return true;
    }

    /// Inspect of lines that make no solid but belong to a sketch: the sketch
    /// alone over the ghosts of the parts, what the lines make or constrain
    /// in orange (`highlight`; without it the whole sketch, as for its step).
    bool inspectSketch(uint from, uint to, bool highlight, int col = -1)
    {
        if (sceneLocked())
            return false;
        followTakenOver();
        inspectRequest++;   // what a previous Inspect is still computing is not needed
        if (viewport.inRollback)
        {
            viewport.clearRollback();
            stepsPanel.clearSelection();
        }
        if (!showSketchOn(from, to, highlight))
            return false;
        inspectQuery = InspectQuery(from, to, col, null, !highlight);
        inspectShown = null;
        inspectMeshes = null;
        viewport.showInspect(null);
        immutable where = from == to ? format("line %d", from) : format("lines %d–%d", from, to);
        info(where ~ " · " ~ sketchFoundText());
        immutable note = sketchStateNote();
        showModeBar(note.length ? note : highlight ? "Inspecting " ~ where ~ ": its sketch, in orange what it makes or constrains"
            : format("The sketch of line %d", from));
        return true;
    }

    /// The sketches lines from..to of the model belong to (every run of
    /// them), and what the lines make in each.
    size_t[] sketchesOn(uint from, uint to, out SketchView.Found[] found)
    {
        immutable file = absolutePath(path);
        size_t[] r;
        foreach (i, sk; last.sketches)
        {
            auto f = sk.on(file, from, to);
            if (f.sketch || f.entities.length || f.constraints.length)
            {
                r ~= i;
                found ~= f;
            }
        }
        return r;
    }

    /// Draws the sketch lines from..to belong to, with its dimensions and
    /// free points; with `highlight`, what the lines make or constrain in
    /// orange. False (and no sketch drawn) when they are no sketch's.
    bool showSketchOn(uint from, uint to, bool highlight)
    {
        followTakenOver();
        SketchView.Found[] found;
        auto which = sketchesOn(from, to, found);
        if (which.length == 0)
        {
            hideSketch();
            return false;
        }
        drawSketches(which, found, from, to, highlight);
        return true;
    }

    /// Draws sketches `which` (indices in last.sketches), asked for by lines
    /// from..to, which make `found` in each (in orange with `highlight`).
    void drawSketches(size_t[] which, SketchView.Found[] found, uint from, uint to, bool highlight)
    {
        if (sceneLocked(false))
            return;
        // another sketch: seen from above, as a drawing
        immutable another = sketchIndices != which;
        sketchLines = [from, to];
        sketchHighlight = highlight;
        sketchIndices = which;
        sketchFound = found;
        if (another)
        {
            sketchRun = 0;
            sketchSel = null;
        }
        drawRuns();
        // a sketch on a face: seen from outside that face
        if (another && which.length && which[0] < last.sketches.length && last.sketches[which[0]].placed)
            viewport.lookAlong(last.sketches[which[0]].place[3]);
        else if (another)
            viewport.setView(ViewPreset.top);
    }

    /// The runs of the sketch shown that are drawn, as positions in
    /// sketchIndices: one at a time when a loop or another call made it
    /// again (their dimensions would lie on each other), else all.
    size_t[] drawnRuns()
    {
        size_t[] r;
        if (sketchIndices.length > 1)
            r ~= min(sketchRun, sketchIndices.length - 1);
        else
            foreach (k; 0 .. sketchIndices.length)
                r ~= k;
        return r;
    }

    /// Draws the runs drawnRuns gives, with their dimensions.
    void drawRuns()
    {
        size_t[] shown;
        size_t[][] lit;
        foreach (k; drawnRuns())
        {
            shown ~= sketchIndices[k];
            // what is selected stands out; else what the cursor's line makes
            lit ~= sketchSel.length ? sketchSel.dup : sketchHighlight && k < sketchFound.length ? sketchFound[k].highlight : null;
        }
        viewport.showSketches(shown, lit);
        updateDimensions();
        updateSketchBar();
        if (runButton !is null)
        {
            runButton.setLabel(format("Run %d of %d", min(sketchRun, sketchIndices.length - 1) + 1,
                sketchIndices.length));
            runButton.setVisible(modeBar.getVisible() && sketchIndices.length > 1);
        }
    }

    /// Run `run` (0-based) of the sketch shown, drawn instead of the one
    /// drawn now: the mode bar's Run button, the socket's sketch {run}.
    /// False when the sketch shown has no such run.
    bool showSketchRun(size_t run)
    {
        if (run >= sketchIndices.length || sceneLocked(false))
            return false;
        sketchRun = run;
        drawRuns();
        info(sketchFoundText());
        return true;
    }

    /// Look at sketch: the view straight at the sketch shown, from outside
    /// the face it is drawn on, or from above (the right-click menu, "sketch"
    /// with align on the socket); false when none is shown.
    bool alignToSketch()
    {
        if (sketchIndices.length == 0 || sketchIndices[0] >= last.sketches.length || frozen)
            return false;
        auto sk = last.sketches[sketchIndices[0]];
        if (sk.placed)
            viewport.lookAlong(sk.place[3]);
        else
            viewport.setView(ViewPreset.top);
        return true;
    }

    void hideSketch()
    {
        if (sceneLocked(false))
            return;
        if (sketchIndices.length == 0 && sketchLines[0] == 0)
            return;
        followClosed();   // the sketch at the cursor: the camera goes back
        sketchLines = [0, 0];
        sketchIndices = null;
        sketchRun = 0;
        sketchSel = null;
        drawTool = null;
        drawn = null;
        drawnAt = null;
        drawnVia = null;
        viewport.drawingLines = null;
        viewport.drawingPoints = null;
        viewport.drawingSnap = null;
        sketchFound = null;
        viewport.showSketches(null);
        updateDimensions();
        updateSketchBar();
    }

    /// "sketch of line 37 · fully constrained · 2 lines, 1 constraint (tangent)"
    string sketchFoundText()
    {
        if (sketchIndices.length == 0)
            return "";
        auto sk = last.sketches[sketchIndices[0]];
        string[] what;
        size_t[string] made, cons;
        string[] madeOrder, consOrder;
        foreach (k; drawnRuns())
        {
            immutable index = sketchIndices[k];
            auto f = sketchFound[k];
            foreach (e; f.entities)
            {
                auto kind = last.sketches[index].entities[e].kind;
                if (kind !in made)
                    madeOrder ~= kind;
                made[kind]++;
            }
            foreach (c; f.constraints)
            {
                auto kind = last.sketches[index].constraints[c].kind;
                if (kind !in cons)
                    consOrder ~= kind;
                cons[kind]++;
            }
        }
        foreach (kind; madeOrder)
            what ~= made[kind] > 1 ? format("%d %ss", made[kind], kind) : ("aeiou".canFind(kind[0]) ? "an " : "a ") ~ kind;
        foreach (kind; consOrder)
            what ~= cons[kind] > 1 ? format("%s ×%d", kind, cons[kind]) : kind;
        auto state = !sk.solved ? "conflicting" : sk.dof ? format("%d degree%s of freedom", sk.dof, sk.dof > 1 ? "s" : "")
            : "fully constrained";
        auto runs = sketchIndices.length > 1
            ? format(" (run %d of %d)", drawnRuns()[0] + 1, sketchIndices.length) : "";
        return format("sketch of line %d%s · %s%s", sk.span.line, runs, state,
            what.length && sketchHighlight ? " · " ~ what.join(", ") : "");
    }

    /// The sketch shown, for agents (null when none is): its state, the
    /// points that can still move, and what the lines asked for make or
    /// constrain in it.
    JValue shownSketchJson()
    {
        if (sketchIndices.length == 0)
            return JValue(null);
        JValue j = JSOB("lines", JSAB(sketchLines[0], sketchLines[1]));
        j["status"] = sketchFoundText();
        // a sketch made again (a loop, another call): its runs, one drawn at a time
        if (sketchIndices.length > 1)
        {
            j["run"] = drawnRuns()[0] + 1;
            j["runs"] = sketchIndices.length;
        }
        // what the sketch bar works on: the drawn sketch's entities by id, those selected, and whether its code
        // can be written to from here (else why not)
        if (auto drawn = drawnSketch())
        {
            JValue ents = JSAB();
            foreach (id, e; drawn.entities)
                if (!e.reference || e.edge >= 0 || e.origin)
                    ents ~= JSOB("id", id, "kind", e.kind, "line", e.span.line);
            j["entities"] = ents;
            JValue sel = JSAB();
            foreach (x; sketchSel)
                sel ~= x;
            j["selected"] = sel;
            // the closed areas: full (extruded) or empty, and a point inside each
            JValue areas = JSAB();
            foreach (r; drawn.regions)
                if (r.triangles.length >= 3)
                {
                    auto c = (r.triangles[0] + r.triangles[1] + r.triangles[2]) / 3;
                    areas ~= JSOB("full", r.full, "inside", JSAB(round(c.x * 100) / 100, round(c.y * 100) / 100));
                }
            j["areas"] = areas;
            if (auto why = sketchUneditable())
                j["not_editable"] = why;
            // a drawing tool at work, and what it has clicked so far (on the sketch's plane)
            if (drawTool !is null)
            {
                JValue pts = JSAB();
                foreach (q; this.drawn)
                    pts ~= toJSON([q.x, q.y]);
                j["drawing"] = JSOB("tool", drawTool, "points", pts);
            }
        }
        sketchOriginJson(j);
        JValue list = JSAB();
        foreach (k, index; sketchIndices)
        {
            if (index >= last.sketches.length)
                continue;
            auto sk = last.sketches[index];
            JValue js = JSOB("line", sk.span.line, "solved", sk.solved);
            js["degrees_of_freedom"] = sk.dof;
            sketchPlaneJson(js, sk);
            JValue free = JSAB();
            foreach (pt; sk.points)
                if (pt.free)
                    free ~= JSOB("line", pt.span.line, "x", pt.pos.x, "y", pt.pos.y);
            js["free_points"] = free;
            js["dimensions"] = sk.dimensions.length;
            if (sketchHighlight)
            {
                auto f = sketchFound[k];
                JValue entity(size_t e)
                {
                    JValue je = JSOB("id", e, "kind", sk.entities[e].kind, "line", sk.entities[e].span.line);
                    if (sk.entities[e].construction)
                        je["construction"] = true;
                    return je;
                }
                JValue es = JSAB(), cs = JSAB(), lit = JSAB();
                foreach (e; f.entities)
                    es ~= entity(e);
                foreach (c; f.constraints)
                {
                    auto rc = sk.constraints[c];
                    JValue jc = JSOB("kind", rc.kind, "line", rc.span.line);
                    jc["entities"] = toJSON(rc.entities);
                    if (rc.dimension >= 0)
                        jc["dimension"] = sk.dimensions[rc.dimension].label;
                    if (rc.conflicting)
                        jc["conflicting"] = true;
                    cs ~= jc;
                }
                foreach (e; f.highlight)
                    lit ~= entity(e);
                js["made"] = es;
                js["constraints"] = cs;
                js["highlighted"] = lit;
            }
            list ~= js;
        }
        j["sketches"] = list;
        return j;
    }

    /// Shows what a function returned (every call of it, up to the trace's limits).
    bool inspectFunction(FunctionInfo fn)
    {
        followTakenOver();
        immutable file = absolutePath(path);
        TraceEntry[] made;
        foreach (e; last.trace)
            if (e.decl.file == file && e.decl.line == fn.nameSpan.line && e.decl.col == fn.nameSpan.col)
                made ~= e;
        immutable calls = callsOf(made);   // before identical results are merged
        made = distinct(made);
        if (made.length == 0)
            return false;
        inspectQuery = InspectQuery(0, 0, -1, fn.name);
        showInspected(made, format("line %d · %s returns", fn.nameSpan.line, fn.name), true, calls);
        return true;
    }

    /// The trace entries made on lines from..to of the model's file.
    TraceEntry[] entriesOn(uint from, uint to)
    {
        immutable file = absolutePath(path);
        TraceEntry[] r;
        foreach (e; last.trace)
            if (e.site.line >= from && e.site.line <= to && e.site.file == file)
                r ~= e;
        return distinct(r);
    }

    /// Without the values met twice (a call and the function it returned from).
    static TraceEntry[] distinct(TraceEntry[] es)
    {
        bool[void*] seen;
        TraceEntry[] r;
        foreach (e; es)
        {
            auto key = cast(void*) e.value.brep;
            if (key in seen)
                continue;
            seen[key] = true;
            r ~= e;
        }
        return r;
    }

    /// Tessellates the values (on the evaluator's thread) and shows them.
    void showInspected(TraceEntry[] made, string where, bool returns, uint calls = 0)
    {
        if (sceneLocked())
            return;
        enum maxShown = 64;
        if (made.length > maxShown)
            made = made[0 .. maxShown];
        // the cursor moved within the same code (typing): nothing new to show
        if (viewport.inInspect && sameValues(made, inspectShown))
        {
            inspectRequest++;   // a request still on its way is not needed
            inspectShown = made;
            info(inspectSummary(where, made, inspectMeshes, returns, calls));
            return;
        }
        immutable request = ++inspectRequest;
        if (viewport.inRollback)
        {
            viewport.clearRollback();
            stepsPanel.clearSelection();
        }
        info(where ~ " (computing…)");
        SolidVal[] vals;
        foreach (e; made)
            vals ~= e.value;
        evaluator.prepareSolids(vals, (PartMesh[] ms) {
            if (request != inspectRequest)
                return;   // a newer request, or Inspect was closed
            inspectShown = made;
            inspectMeshes = ms;
            viewport.showInspect(ms);
            info(inspectSummary(where, made, ms, returns, calls));
            showModeBar("Inspecting " ~ where ~ ": in orange what it makes");
        });
    }

    static bool sameValues(TraceEntry[] a, TraceEntry[] b)
    {
        if (a.length != b.length)
            return false;
        foreach (i; 0 .. a.length)
            if (a[i].value !is b[i].value)
                return false;
        return true;
    }

    /// "line 73 · polygon → Profile 2D · 32 × 18 mm"
    /// `calls`: how many times a function ran, when `returns` (0: count `made`).
    static string inspectSummary(string where, TraceEntry[] made, PartMesh[] ms, bool returns, uint calls = 0)
    {
        string[] what;
        foreach (e; made)
        {
            auto kind = e.kind == "Profile" ? "Profile 2D" : e.kind;
            auto w = returns ? kind : format("%s%s → %s", e.fn, e.calls > 1 ? format(" ×%d", e.calls) : "", kind);
            if (!what.canFind(w))
                what ~= w;
        }
        auto list = what.length > 3 ? what[0 .. 3].join(", ") ~ format(" and %d more", what.length - 3) : what.join(", ");
        if (returns)
        {
            // a function called many times: every call is shown, say how many
            if (calls == 0)
                calls = callsOf(made);
            // identical results (the same geometry again) are shown once
            if (calls > 1)
                list ~= made.length < calls ? format(" · called %d times, %d different result%s shown", calls,
                    made.length, made.length == 1 ? "" : "s") : format(" · called %d times, all shown", calls);
        }
        bool any, allFlat = true, anyFlat;
        BBox box;
        foreach (m; ms)
        {
            if (m.vertices.length == 0 && m.edgeInfo.length == 0)
                continue;
            box = any ? box.merged(m.bbox) : m.bbox;
            any = true;
            allFlat = allFlat && m.flat;
            anyFlat = anyFlat || m.flat;
        }
        if (!any)
            return format("%s · %s · could not be shown", where, list);
        auto d = box.size;
        string size;
        if (allFlat)
        {
            // the two sides of the profile's plane, wherever it lies
            double[3] a = [d.x, d.y, d.z];
            import std.algorithm : sort;
            a[].sort!"a > b";
            size = format("%.1f × %.1f mm", a[0], a[1]);
        }
        else
            size = format("%.1f × %.1f × %.1f mm", d.x, d.y, d.z);
        return format("%s · %s · %s%s", where, list, size, anyFlat ? " · profiles in their own coordinates" : "");
    }

    /// Shows the same lines (or function) again, on a new evaluation.
    void reinspect()
    {
        if (inspectQuery.function_.length)
        {
            foreach (fn; last.functions)
                if (fn.name == inspectQuery.function_)
                {
                    inspectFunction(fn);
                    return;
                }
        }
        else if (inspectQuery.sketchOnly)
        {
            if (!inspectSketch(inspectQuery.from, inspectQuery.to, false))
                showFinal();
        }
        else if (inspectQuery.from > 0)
            inspectLines(inspectQuery.from, inspectQuery.to, inspectQuery.col);
        else
            showFinal();   // a feature row: its runs are gone with the old model, like a rollback
    }

    void stopInspect()
    {
        if (sceneLocked(false))
            return;
        inspectRequest++;
        immutable was = viewport.inInspect;
        inspectQuery = InspectQuery.init;
        inspectShown = null;
        inspectMeshes = null;
        viewport.clearInspect();
        if (was)
            hideSketch();
        if (was)
        {
            stepsPanel.clearSelection();
            info("");
        }
        if (!viewport.inRollback)
            showModeBar(null);
    }

    /// What Inspect shows, for agents (null when it is off).
    JValue inspectJson()
    {
        if (!viewport.inInspect)
            return JValue(null);
        JValue j = JSOB("status", infoLabel !is null ? infoLabel.getText() : "");
        if (inspectQuery.function_.length)
            j["function"] = inspectQuery.function_;
        else
            j["lines"] = JSAB(inspectQuery.from, inspectQuery.to);
        JValue items = JSAB();
        foreach (i, e; inspectShown)
        {
            JValue it = JSOB("line", e.site.line);
            it["function"] = e.fn;
            it["kind"] = e.kind;
            it["calls"] = e.calls;
            if (e.decl.line > 0)
                it["returned_by_line"] = e.decl.line;
            if (e.site.file != absolutePath(path))
                it["file"] = e.site.file;
            if (i < inspectMeshes.length && (inspectMeshes[i].vertices.length || inspectMeshes[i].edgeInfo.length))
            {
                auto b = inspectMeshes[i].bbox;
                it["min"] = toJSON([b.min.x, b.min.y, b.min.z]);
                it["max"] = toJSON([b.max.x, b.max.y, b.max.z]);
            }
            items ~= it;
        }
        j["items"] = items;
        if (sketchIndices.length)
            j["sketch"] = shownSketchJson();
        return j;
    }

    // ---- context menu: stepsPanel written into the code

    void contextMenu(Hit hit, double x, double y)
    {
        // drawing in a sketch: a right-click ends what is being drawn
        if (drawTool !is null)
            return finishDrawing(false);
        if (hit.part < 0 || hit.part >= last.parts.length)
        {
            // a sketch shown (its parts hidden, so a click finds none): the view
            // back on it, or the model; then, as on empty space, the hidden parts
            MenuEntry[] head;
            if (sketchIndices.length)
                head = [MenuEntry.heading("SKETCH"), MenuEntry.item("Look at sketch", () { alignToSketch(); }),
                    MenuEntry.item("Show final model", () => showFinal())];
            // on empty space: the hidden parts can come back
            MenuEntry[] back;
            foreach (i, part; last.parts)
                if (viewport.isHidden(i))
                {
                    immutable index = i;
                    back ~= MenuEntry.item("Show " ~ part.name, () => setPartVisible(index, true));
                }
            if (back.length > 1)
                back ~= MenuEntry.item("Show all parts", () {
                    foreach (i; 0 .. last.parts.length)
                        setPartVisible(i, true);
                });
            if (back.length)
                back = MenuEntry.heading("HIDDEN PARTS") ~ back;
            if (head.length && back.length)
                head ~= MenuEntry.separator();
            if (head.length + back.length == 0)
                return;
            contextPopover = popupMenu(viewport.area, x, y, head ~ back);
            return;
        }
        if (viewport.inRollback)
            return;
        setContext(hit);
        auto part = last.parts[hit.part];
        auto sel = viewport.selection();
        // items of several parts: the operations written in each part in turn, and the sizes
        if (sel.canFind!(h => h.part != hit.part))
        {
            immutable nparts = selectionByPart().length;
            immutable nfs = selFaces.length, nes = selEdges.length;
            immutable on = format(" on %d parts…", nparts);
            MenuEntry[] some = [MenuEntry.heading(nes ? format("%d EDGES", nes) : nfs ? format("%d FACES", nfs)
                : format("%d ITEMS", sel.length), format("%d parts", nparts))];
            if (nes)
            {
                some ~= MenuEntry.item("Fillet edges" ~ on, () => ctx("fillet-edge", "1.mm"));
                some ~= MenuEntry.item("Chamfer edges" ~ on, () => ctx("chamfer-edge", "0.5.mm"));
            }
            if (nfs)
            {
                some ~= MenuEntry.item("Fillet edges of the faces" ~ on, () => ctx("fillet-face", "1.mm"));
                some ~= MenuEntry.item("Chamfer edges of the faces" ~ on, () => ctx("chamfer-face", "0.5.mm"));
                some ~= MenuEntry.item("Shell, opening the faces" ~ on, () => ctx("shell", "2.mm"));
                some ~= MenuEntry.item("Draft faces" ~ on, () => ctx("draft", "3.deg"));
                some ~= MenuEntry.item("Extrude faces" ~ on, () => ctx("extrude-face", "5.mm"));
                some ~= MenuEntry.item("Cut faces" ~ on, () => ctx("cut-face", "2.mm"));
            }
            MenuEntry[] sizes;
            foreach (row; selectionRows())
            {
                auto v = row[1];
                sizes ~= MenuEntry.item(row[0][0 .. 1].toUpper ~ row[0][1 .. $], () => copy(v), v);
            }
            if (sizes.length)
                some ~= MenuEntry.group("Measure", sizes);
            some ~= MenuEntry.item("Clear selection", () => clearSelection());
            contextPopover = popupMenu(viewport.area, x, y, some);
            return;
        }
        immutable nf = selFaces.length, ne = selEdges.length, nv = selVertices.length;
        immutable mode = viewport.selectMode;
        alias I = MenuEntry.item, G = MenuEntry.group, H = MenuEntry.heading;
        alias S = MenuEntry.separator;
        string count(size_t n, string what) => n == 1 ? what : format("%d %ss", n, what);

        MenuEntry[] entries;
        // what the menu is for follows the selection mode: only what fits it is offered
        string title = ne ? count(ne, "edge") : nf ? count(nf, "face") : nv == 1 ? "vertex"
            : nv ? format("%d vertices", nv) : "Part";
        entries ~= H(title.toUpper, part.name);
        // the face under the click came from a sketch's profile: open the sketch
        {
            auto under = viewport.pickAny(x, y);
            immutable sketch = under.part == contextHit.part ? sketchOfFace(part, under.face) : -1;
            if (sketch >= 0)
                entries ~= I("Edit sketch…", () => openSketch(sketch));
        }

        if (ne)
        {
            entries ~= I(ne == 1 ? "Fillet edge…" : format("Fillet %d edges…", ne), () => ctx("fillet-edge", "1.mm"));
            entries ~= I(ne == 1 ? "Chamfer edge…" : format("Chamfer %d edges…", ne), () => ctx("chamfer-edge", "0.5.mm"));
        }
        if (nf)
        {
            entries ~= I(nf == 1 ? "Fillet face edges…" : "Fillet edges of the faces…", () => ctx("fillet-face", "1.mm"));
            entries ~= I(nf == 1 ? "Chamfer face edges…" : "Chamfer edges of the faces…", () => ctx("chamfer-face", "0.5.mm"));
            entries ~= I(nf == 1 ? "Shell, opening this face…" : format("Shell, opening %d faces…", nf),
                () => ctx("shell", "2.mm"));
            entries ~= I(nf == 1 ? "Draft face…" : format("Draft %d faces…", nf), () => ctx("draft", "3.deg"));
            entries ~= I(nf == 1 ? "Extrude face…" : format("Extrude %d faces…", nf), () => ctx("extrude-face", "5.mm"));
            entries ~= I(nf == 1 ? "Cut face…" : format("Cut %d faces…", nf), () => ctx("cut-face", "2.mm"));
            // a sketch to draw on a flat face, its edges as references
            if (nf == 1 && canSketchOn(contextHit.part, selFaces[0]))
            {
                immutable index = contextHit.part, face = selFaces[0];
                entries ~= I("Sketch on face…", () {
                    if (auto problem = sketchOnFaceOf(index, face))
                        info(problem);
                });
            }
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
            entries ~= I("Pocket at point…", () => ctx("pocket", "2.mm"));
            entries ~= I("Boss at point…", () => ctx("boss", "3.mm"));
            // a whole cylinder: the ISO threads that fit it
            auto sizes = threadSizes();
            if (sizes.length)
            {
                // by family: ISO metric, unified inch, trapezoidal, pipe threads
                MenuEntry[] th;
                string[] families;
                foreach (t; sizes)
                    if (!families.canFind(t.family))
                        families ~= t.family;
                foreach (f; families)
                {
                    MenuEntry[] group;
                    foreach (t; sizes)
                        if (t.family == f)
                            group ~= I(t.name, threadAction(t.name));
                    th ~= families.length == 1 ? group : [G(f, group)];
                }
                entries ~= G(threadOutside ? "Thread (outside)" : "Thread (in the hole)", th);
            }
        }

        // measurements: values on the right, a click copies them
        MenuEntry[] measures;
        if (ne == 1 && selEdges[0] < part.edgeInfo.length)
        {
            auto e = part.edgeInfo[selEdges[0]];
            string v = e.kind == EdgeKind.circle ? format("R %.4g mm", e.radius) : format("%.4g mm", e.length);
            measures ~= I(e.kind == EdgeKind.circle ? "Edge radius" : "Edge length", () => copy(v), v);
            if (e.kind == EdgeKind.circle)
            {
                auto dia = format("⌀ %.4g mm", 2 * e.radius);
                measures ~= I("Edge diameter", () => copy(dia), dia);
            }
        }
        if (sel.length == 2 && nv == 0)
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
        auto vol = format("%.5g mm³", part.volume);
        if (mode == SelectMode.part)
        {
            measures ~= I("Part size", () => copy(size), size);
            measures ~= I("Part volume", () => copy(vol), vol);
        }
        // two vertices: how far apart, and along X, Y and Z
        if (nv == 2)
        {
            auto d = viewport.vertexAt(sel[1].part, sel[1].vertex) - viewport.vertexAt(sel[0].part, sel[0].vertex);
            auto dv = format("%.4g mm", d.length);
            measures ~= I("Distance", () => copy(dv), dv);
            auto dx = format("%.4g, %.4g, %.4g", d.x, d.y, d.z);
            measures ~= I("Apart along X, Y, Z", () => copy(dx), dx);
        }
        if (mode == SelectMode.face || mode == SelectMode.vertex)
        {
            auto pt = hit.point;
            auto point = format("vec(%.4g.mm, %.4g.mm, %.4g.mm)", pt.x, pt.y, pt.z);
            measures ~= I(mode == SelectMode.vertex ? "Vertex" : "Point", () => copy(point),
                format("%.4g, %.4g, %.4g", pt.x, pt.y, pt.z));
        }

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
        if (nv)
        {
            auto vp = hit.point;
            auto code = format("vec(%.4g.mm, %.4g.mm, %.4g.mm)", vp.x, vp.y, vp.z);
            copies ~= I("Point", () => copy(code));
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
                refreshPlaneChoices();
                sectionUpdating = true;
                sectionPlane.setSelected(3);
                sectionUpdating = false;
                sectionToggle.setActive(true);
                updateSection(true);
            });
        }

        // straight at the face under the click (as a double click on it)
        {
            immutable cx = x, cy = y;
            if (faceUnder(cx, cy, null))
                entries ~= I("Look at face", () { lookAtFace(cx, cy); });
        }

        // a turn about what is picked: a face's normal (a round face's axis), an edge (a hinge)
        auto hinges = pickedAxes(part);
        if (hinges.length)
            entries ~= S();
        foreach (choice; hinges)
            entries ~= hingeEntry(contextHit.part, choice);

        // Place on…: from the face under the click (any mode)
        {
            auto under = viewport.pickAny(x, y);
            if (under.part == contextHit.part && under.face >= 0)
            {
                immutable index = contextHit.part, face = under.face;
                immutable at = under.point;
                entries ~= I("Place on…", () => startPlaceOn(index, face, at));
            }
        }

        // what the whole part can do: the menu itself in the Part mode, a group in the others
        auto whole = entries.length;
        entries ~= S();
        {
            auto name = part.name;
            entries ~= G("Export " ~ name, [I("3MF…", () => exportFile("3mf", name)),
                I("STL…", () => exportFile("stl", name)), I("STEP…", () => exportFile("step", name))]);
        }
        entries ~= I("Move…", () => startTransform(Viewport.Gizmo.move, contextHit.part));
        entries ~= I("Rotate…", () => startTransform(Viewport.Gizmo.rotate, contextHit.part));
        entries ~= I("Scale…", () => startTransform(Viewport.Gizmo.scale, contextHit.part));
        {
            // the face under the click gives the plane, whatever the selection mode
            auto under = viewport.pickAny(x, y);
            immutable onFace = under.part == contextHit.part && under.face >= 0 && under.normal.length > 0.5;
            immutable at = under.point, normal = under.normal;
            // a piece of @parts is split where its pieces are made, in the code
            if (!isPiece(contextHit.part))
                entries ~= I("Split…", () => startSplit(contextHit.part, onFace, at, normal));
        }
        {
            // hackerscad's own colours (geom/color.d), the default first
            import hackerscad.geom.color : partPalette;
            MenuEntry[] colours, all;
            immutable now = part.rgb & 0xFFFFFF;
            foreach (c; partPalette)
                colours ~= colourEntry(c.name, c.rgb, now == c.rgb ? "✓" : null, false);
            colours ~= S();
            colours ~= I("Other…", () => showColourWheel(contextHit.part));
            entries ~= G("Colour", colours);
            // a piece: its own colour, or its group's (the @parts annotation's),
            // a default that the pieces not coloured on their own take
            if (isPiece(contextHit.part))
            {
                foreach (c; partPalette)
                    all ~= colourEntry(c.name, c.rgb, null, true);
                entries ~= G("Default colour of " ~ part.fn, all);
            }
        }
        entries ~= I("Hide " ~ part.name, () => setPartVisible(contextHit.part, false));
        if (last.parts.length > 1)
            entries ~= I("Show only " ~ part.name, () {
                foreach (i; 0 .. last.parts.length)
                    setPartVisible(i, i == contextHit.part);
            });
        bool anyHidden;
        foreach (i; 0 .. last.parts.length)
            anyHidden = anyHidden || viewport.isHidden(i);
        if (anyHidden)
            entries ~= I("Show all parts", () {
                foreach (i; 0 .. last.parts.length)
                    setPartVisible(i, true);
            });
        if (mode != SelectMode.part)
        {
            auto partOnes = entries[whole + 1 .. $].dup;
            entries = entries[0 .. whole] ~ S() ~ G("Part " ~ part.name, partOnes);
        }
        entries ~= S();
        entries ~= G("Measure", measures);
        if (copies.length)
            entries ~= G("Copy as code", copies);
        if (view.length)
            entries ~= G("View", view);
        contextPopover = popupMenu(viewport.area, x, y, entries);
    }

    Popover contextPopover;

    /// A Colour entry: its sample, and clicking it writes the colour's name on
    /// the part the menu is for (`all`: on the @parts of its piece; one entry
    /// per call: closures made in a loop share one frame).
    MenuEntry colourEntry(string name, uint rgb, string detail, bool all)
    {
        return MenuEntry.colour(name, format("#%06X", rgb), () {
            auto p = last.parts[contextHit.part];
            if (auto problem = writeColour(p.fn, all ? -1 : p.piece, p.fromSolid, name))
                info(problem);
        }, detail);
    }

    import hackerscad.gui.colourwheel : ColourWheel;
    ColourWheel colourWheel;

    /// Colour › Other…: the calibrated wheel, on part `index`'s colour; the
    /// part shows each colour chosen, Apply writes the last as "#RRGGBB".
    void showColourWheel(int index)
    {
        if (index < 0 || index >= last.parts.length)
            return;
        if (colourWheel !is null && colourWheel.win.getVisible())
            colourWheel.win.close();   // the part it was on takes back its colour
        auto name = last.parts[index].fn;
        immutable piece = last.parts[index].piece, fromSolid = last.parts[index].fromSolid;
        immutable start = last.parts[index].rgb & 0xFFFFFF;
        // the preview and its undoing touch the parts the wheel opened on: once
        // the model is evaluated again, the new parts have their own colours
        immutable version_ = viewport.partsVersion;
        void show(uint rgb)
        {
            if (viewport.partsVersion == version_)
                viewport.previewColour(index, rgb);
        }
        colourWheel = new ColourWheel(window, start, (uint rgb) => show(rgb), (uint rgb) {
            if (auto problem = writeColour(name, piece, fromSolid, format("#%06X", rgb)))
            {
                show(start);
                info(problem);
            }
        }, () => show(start));
    }

    /// Gives the part of function `name` the colour `colour` (a name,
    /// "#RRGGBB") in the code, on its @part; piece `piece` of a @parts
    /// function (from 0; -1 the annotation, for all) with .color on it alone.
    /// The problem, or null.
    string writeColour(string name, int piece, bool fromSolid, string colour)
    {
        if (busy())
            return "wait for the evaluation to finish, then try again";
        try
        {
            import hackerscad.tool.codegen : colourPart, colourPiece;
            applyEdit(piece >= 0 ? colourPiece(text(), path, name, piece, fromSolid, colour)
                : colourPart(text(), path, name, colour));
            info("");
            return null;
        }
        catch (CodegenException e)
            return e.msg;
        catch (HcadError e)
            return "fix the errors in the code first: " ~ e.msg;
    }

    int[] selFaces, selEdges, selVertices;

    /// An interpreter to resolve selectors on `part`, and the part as a
    /// solid value (with where its faces come from, for stable selectors).
    Interp selectorInterp(PartMesh part, out SolidVal sv)
    {
        sv = new SolidVal(part.brep, Span.init);
        sv.creators = part.creators;
        return new Interp(part.kernel);
    }

    /// ditto, on the part the right-click menu is for
    Interp selectorInterp(out SolidVal sv) => selectorInterp(last.parts[contextHit.part], sv);

    /// Selector code for the selected faces / edges: a group when one picks
    /// exactly them, otherwise each one's, joined with +.
    string facesCode()
    {
        SolidVal sv;
        auto it = selectorInterp(sv);
        return facesSelector(it, sv, selFaces);
    }

    string edgesCode()
    {
        SolidVal sv;
        auto it = selectorInterp(sv);
        return edgesSelector(it, sv, selEdges);
    }

    /// Whether a flat face is under view coordinates (x, y), and its outward
    /// normal (null: only whether).
    bool faceUnder(double x, double y, Vec3* normal)
    {
        import hackerscad.gui.measure : faceItem;
        auto hit = viewport.pickAny(x, y);
        if (hit.part < 0 || hit.face < 0 || hit.part >= last.parts.length)
            return false;
        if (!faceItem(last.parts[hit.part], hit.face).planar || hit.normal.length < 0.5)
            return false;
        if (normal !is null)
            *normal = hit.normal.normalized;
        return true;
    }

    /// Look at face (a double click on a flat face, the right-click menu,
    /// "view" with look_at_face on the socket): the view straight at the face
    /// under (x, y), from outside it; the problem, or null.
    string lookAtFace(double x, double y)
    {
        if (frozen)
            return "the view is annotated: it does not move";
        Vec3 n;
        if (!faceUnder(x, y, &n))
            return "no flat face there";
        viewport.lookAlong(n);
        return null;
    }

    /// Whether face `face` of part `index` is flat, to draw a sketch on, and
    /// the part is a whole one (a piece of @parts is made with the others).
    bool canSketchOn(int index, int face)
    {
        import hackerscad.gui.measure : faceItem;
        return index >= 0 && index < last.parts.length && !isPiece(index) && faceItem(last.parts[index], face).planar;
    }

    /// Sketch on face…: the part's function draws a sketch on face `face`
    /// (Sketch on face… in the right-click menu, "feature" with action
    /// "sketch" on the socket); the problem, or null.
    string sketchOnFaceOf(int index, int face)
    {
        if (busy())
            return "wait for the evaluation to finish, then try again";
        if (!canSketchOn(index, face))
            return "a sketch goes on a flat face of a whole part (not a piece of @parts)";
        auto part = last.parts[index];
        if (part.span.file != absolutePath(path))
            return format("part '%s' is defined in another file", part.name);
        try
        {
            import hackerscad.tool.codegen : sketchOnFace;
            SolidVal sv;
            auto it = selectorInterp(part, sv);
            applyEdit(sketchOnFace(text(), path, part.fn, facesSelector(it, sv, [face])));
            viewport.setSelection(null);
            // the sketch shows as soon as the cursor, on its line, has it evaluated
            followArmed = true;
            info("");
            return null;
        }
        catch (CodegenException e)
            return e.msg;
        catch (HcadError e)
            return "fix the errors in the code first: " ~ e.msg;
    }

    /// A right-click menu entry: its code appended, the size `placeholder`
    /// selected for the user to type over.
    void ctx(string action, string placeholder, string kind = null, string size = null)
    {
        auto groups = selectionByPart();
        if (groups.length <= 1)
        {
            if (auto code = contextCode(action, null, kind, size))
                appendFeature(last.parts[contextHit.part], code, placeholder);
            return;
        }
        // items of several parts: the operation written in each, one after the
        // other, the last in the code first, so that the first one's value is
        // left selected to type over (the others are changed by hand)
        if (busy())
            return info("wait for the evaluation to finish, then try again");
        struct Step
        {
            PartMesh part;
            string code;
        }
        Step[] steps;
        auto keepHit = contextHit;
        auto keepFaces = selFaces, keepEdges = selEdges, keepVertices = selVertices;
        foreach (g; groups)
        {
            contextOn(g);
            if (auto code = contextCode(action, null, kind, size))
                steps ~= Step(last.parts[g[0].part], code);
        }
        contextHit = keepHit;
        selFaces = keepFaces;
        selEdges = keepEdges;
        selVertices = keepVertices;
        foreach_reverse (st; steps)
            writeFeature(st.part, st.code, placeholder);
        if (steps.length > 1)
            info(format("written in %d parts: the first one's value is selected, the others are changed by hand",
                steps.length));
    }

    /// The selection's items by part, the parts in the order of their code.
    Hit[][] selectionByPart()
    {
        import std.algorithm : sort;
        Hit[][int] by;
        foreach (h; viewport.selection())
            if (h.part >= 0 && h.part < last.parts.length)
                by[h.part] ~= h;
        auto keys = by.keys;
        keys.sort!((a, b) => last.parts[a].span.line < last.parts[b].span.line);
        Hit[][] r;
        foreach (k; keys)
            r ~= by[k];
        return r;
    }

    /// The context of the right-click menu on `hits`, items of one part.
    void contextOn(Hit[] hits)
    {
        contextHit = hits[$ - 1];
        selFaces = null;
        selEdges = null;
        selVertices = null;
        foreach (h; hits)
        {
            if (h.edge >= 0)
                selEdges ~= h.edge;
            else if (h.vertex >= 0)
                selVertices ~= h.vertex;
            else if (h.face >= 0)
                selFaces ~= h.face;
        }
    }

    Hit contextHit;

    /// What the right-click menu acts on, from a hit: inside a Shift
    /// selection the whole selection, elsewhere what is under the pointer
    /// (selected then); the face under an edge still offers face operations.
    void setContext(Hit hit)
    {
        bool inSelection;
        foreach (h; viewport.selection())
            if (Viewport.sameItem(h, hit) || (h.part == hit.part && h.face == hit.face && hit.edge < 0))
                inSelection = true;
        if (!inSelection)
            picked(hit, true);
        contextHit = hit;
        auto sel = viewport.selection();
        selFaces = null;
        selEdges = null;
        selVertices = null;
        foreach (h; sel)
        {
            if (h.edge >= 0)
                selEdges ~= h.edge;
            else if (h.vertex >= 0)
                selVertices ~= h.vertex;
            else if (h.face >= 0)
                selFaces ~= h.face;
        }
        if (selFaces.length == 0 && hit.face >= 0 && sel.length <= 1)
            selFaces = [hit.face];
    }

    /// The code the right-click menu's `action` appends for the context
    /// (see setContext), `value` in place of its default size; null when
    /// the action does not apply there.
    string contextCode(string action, string value, string kind, string size)
    {
        string or(string def) => value.length ? value : def;
        immutable edges = selEdges.length > 0, faces = selFaces.length > 0, onFace = contextHit.face >= 0;
        switch (action)
        {
        case "fillet-edge": return edges ? format(".fillet(%s, r: %s)", edgesCode(), or("1.mm")) : null;
        case "chamfer-edge": return edges ? format(".chamfer(%s, d: %s)", edgesCode(), or("0.5.mm")) : null;
        case "fillet-face": return faces ? format(".fillet(edges.of(%s), r: %s)", facesCode(), or("1.mm")) : null;
        case "chamfer-face": return faces ? format(".chamfer(edges.of(%s), d: %s)", facesCode(), or("0.5.mm")) : null;
        case "shell": return faces ? format(".shell(open: %s, thickness: %s)", facesCode(), or("2.mm")) : null;
        case "draft": return faces ? format(".draft(%s, angle: %s)", facesCode(), or("3.deg")) : null;
        // flat faces swept along their normals (along: vec(…) slants them)
        case "extrude-face": return faces ? format(".extrude(%s, depth: %s)", facesCode(), or("5.mm")) : null;
        case "cut-face": return faces ? format(".cut(%s, depth: %s)", facesCode(), or("2.mm")) : null;
        case "hole":
            {
                if (!onFace || !["clearance", "tap", "insert"].canFind(kind)
                    || !["M2", "M2.5", "M3", "M4", "M5", "M6", "M8"].canFind(size))
                    return null;
                return format("// %s %s hole (through: true goes all the way)\n"
                    ~ ".cut(circle(d: %g.mm), on: %s, at: %s, depth: %s)", size, kind, holeDiameter(kind, size),
                    ctxSelector(false), ctxAt(), or("5.mm"));
            }
        case "thread":
            {
                // an ISO metric thread on the clicked cylinder (the selected faces, if they are its parts)
                if (!onFace || !threadSizes().canFind!(t => t.name == size))
                    return null;
                return format(".thread(%s, \"%s\")", ctxSelector(false), size);
            }
        case "pocket":
            return onFace ? format(".cut(rect(10.mm, 6.mm), on: %s, at: %s, depth: %s)", ctxSelector(false), ctxAt(),
                or("2.mm")) : null;
        case "boss":
            return onFace ? format(".extrude(circle(d: 6.mm), on: %s, at: %s, depth: %s)", ctxSelector(false), ctxAt(),
                or("3.mm")) : null;
        default:
            return null;
        }
    }

    string ctxSelector(bool edge)
    {
        SolidVal sv;
        auto it = selectorInterp(sv);
        return edge ? edgeSelector(it, sv, contextHit.edge) : faceSelector(it, sv, contextHit.face);
    }

    /// The clicked point, to the hundredth of a millimetre: a click is not
    /// more precise, and 0 stays 0 instead of -3.6e-10.
    string ctxAt()
    {
        import std.math : round;
        string mm(double v)
        {
            immutable r = round(v * 100) / 100;
            return format("%g.mm", r == 0 ? 0.0 : r);
        }
        auto p = contextHit.point;
        return format("vec(%s, %s, %s)", mm(p.x), mm(p.y), mm(p.z));
    }

    /// `code` with %s for the face selector and %s for the clicked point.

    static double holeDiameter(string kind, string size)
    {
        import std.algorithm : countUntil;
        immutable sizes = ["M2", "M2.5", "M3", "M4", "M5", "M6", "M8"];
        immutable double[] cl = [2.4, 2.9, 3.4, 4.5, 5.5, 6.6, 9], tp = [1.6, 2.05, 2.5, 3.3, 4.2, 5, 6.8],
            ins = [3.2, 3.6, 4.2, 5.6, 6.4, 8, 9.7];
        auto i = sizes.countUntil(size);
        return kind == "clearance" ? cl[i] : kind == "tap" ? tp[i] : ins[i];
    }

    bool threadOutside;   /// what threadSizes found: a shaft (true) or a hole

    /// The threads that fit the cylindrical face of the context: for a shaft
    /// those of its diameter, for a hole those it is the tap drill of; none
    /// when the face is not a whole cylinder.
    ThreadSpec[] threadSizes()
    {
        import hackerscad.kernel.brep : CylinderInfo;
        import std.math : PI;
        if (contextHit.face < 0 || contextHit.part >= last.parts.length)
            return null;
        auto part = last.parts[contextHit.part];
        if (part.brep is null || part.kernel is null)
            return null;
        CylinderInfo c;
        try
            if (!part.kernel.faceCylinder(part.brep, contextHit.face, c) || c.span < 2 * PI - 1e-6)
                return null;
        catch (Exception)
            return null;
        threadOutside = c.outside;
        ThreadSpec[] r;
        foreach (t; allThreads())
            if (fits(t, 2 * c.radius, c.outside))
                r ~= t;
        return r;
    }

    // a function of its own: closures made in a loop would all share the last size
    void delegate() threadAction(string size) => () => ctx("thread", null, null, size);

    // a function of its own: closures made in a loop would all share the last size
    // a blind hole 5 mm deep at the clicked point: edit the depth, or use through: true
    void delegate() holeAction(string kind, string size) => () => ctx("hole", "5.mm", kind, size);

    /// The sizes of what is selected, as rows of a name and a value: a
    /// part's size, an edge's length (or radius), a face's size in its own
    /// plane and area, a vertex's place; two items how far apart (nearest,
    /// farthest, on average) and at what angle; more, the room they take
    /// together. None when nothing is selected.
    string[2][] selectionRows()
    {
        import hackerscad.gui.measure : measure, spread, faceItem, edgeItem, pointItem, Item;
        import hackerscad.kernel.brep : CylinderInfo, EdgeKind;
        auto sel = viewport.selection();
        if (sel.length == 0)
            return null;
        // to a millionth of a millimetre: no 2.7e-15 for a flat face's thickness
        static string g(double v)
        {
            import std.math : round;
            return format("%.4g", round(v * 1e6) / 1e6 + 0.0);
        }
        immutable mode = viewport.selectMode;
        Item item(Hit h)
        {
            auto p = last.parts[h.part];
            final switch (mode)
            {
            case SelectMode.edge:
                return edgeItem(p, h.edge);
            case SelectMode.vertex:
                return pointItem(viewport.vertexAt(h.part, h.vertex));
            case SelectMode.face:
                return faceItem(p, h.face);
            case SelectMode.part:
                // the whole surface
                Item it;
                foreach (f; 0 .. cast(int) p.faceStart.length - 1)
                {
                    auto fi = faceItem(p, f);
                    it.triangles ~= fi.triangles;
                    it.points ~= fi.points;
                }
                return it;
            }
        }
        foreach (h; sel)
            if (h.part < 0 || h.part >= last.parts.length)
                return null;
        if (sel.length == 1)
        {
            auto h = sel[0];
            auto p = last.parts[h.part];
            final switch (mode)
            {
            case SelectMode.part:
                return [["size", format("%s × %s × %s mm", g(p.bbox.size.x), g(p.bbox.size.y), g(p.bbox.size.z))],
                    ["volume", format("%s mm³", g(p.volume))]];
            case SelectMode.vertex:
                auto v = viewport.vertexAt(h.part, h.vertex);
                return [["at", format("%s, %s, %s", g(v.x), g(v.y), g(v.z))]];
            case SelectMode.edge:
                if (h.edge < 0 || h.edge >= p.edgeInfo.length)
                    return null;
                auto e = p.edgeInfo[h.edge];
                if (e.kind == EdgeKind.circle)
                {
                    // a whole circle, or an arc of it and how long it is
                    string[2][] r = [["radius", format("R %s mm", g(e.radius))], ["diameter", format("⌀ %s mm", g(2 * e.radius))]];
                    if (abs(e.length - 2 * PI * e.radius) >= 1e-3 * max(1.0, e.radius))
                        r ~= ["arc", format("%s mm long", g(e.length))];
                    return r;
                }
                return [["length", format("%s mm", g(e.length))]];
            case SelectMode.face:
                auto it = faceItem(p, h.face);
                string[2] area = ["area", format("%s mm²", g(faceArea(p, h.face)))];
                CylinderInfo c;
                bool round;
                try
                    round = p.kernel !is null && p.kernel.faceCylinder(p.brep, h.face, c);
                catch (Exception)
                    round = false;
                if (round)
                    return [["diameter", format("⌀ %s mm", g(2 * c.radius))], ["length", format("%s mm", g(c.to - c.from))],
                        area];
                if (!it.planar)
                    return [area];
                // its size in its own plane: across and up as seen from outside it
                auto n = it.normal;
                Vec3 u = abs(n.z) > 0.99 ? Vec3(1, 0, 0) : Vec3(0, 0, 1).cross(n).normalized;
                Vec3 w = n.cross(u);
                double u0 = double.infinity, u1 = -double.infinity, w0 = double.infinity, w1 = -double.infinity;
                foreach (q; it.points)
                {
                    u0 = min(u0, q.dot(u));
                    u1 = max(u1, q.dot(u));
                    w0 = min(w0, q.dot(w));
                    w1 = max(w1, q.dot(w));
                }
                return [["size", format("%s × %s mm", g(u1 - u0), g(w1 - w0))], area];
            }
        }
        if (sel.length == 2)
        {
            auto a = item(sel[0]), b = item(sel[1]);
            if (mode == SelectMode.vertex)
            {
                auto d = b.points[0] - a.points[0];
                return [["distance", format("%s mm", g(d.length))],
                    ["along X, Y, Z", format("%s, %s, %s mm", g(d.x), g(d.y), g(d.z))]];
            }
            auto m = measure(a, b);
            // two parts: the nearest exactly, on the solids
            if (mode == SelectMode.part)
            {
                auto pa = last.parts[sel[0].part], pb = last.parts[sel[1].part];
                Vec3 onA, onB;
                try
                    m.distance = pa.kernel.distance(pa.brep, pb.brep, onA, onB);
                catch (Exception)
                {
                }
            }
            auto s = spread(a, b);
            string[2][] r;
            // the same everywhere (parallel faces, parallel edges): one number
            if (s.max - m.distance < 1e-3 * max(1.0, s.max))
                r ~= ["distance", format("%s mm", g(m.distance))];
            else
                r ~= [["nearest", format("%s mm", g(m.distance))], ["farthest", format("%s mm", g(s.max))],
                    ["mean", format("%s mm", g(s.mean))]];
            if (m.gap == m.gap)
                r ~= ["between the planes", format("%s mm", g(m.gap))];
            if (m.angle == m.angle && mode != SelectMode.part)
                r ~= ["angle", format("%s°", g(m.angle))];
            return r;
        }
        // more: the room they take together
        Vec3 lo = Vec3(double.infinity, double.infinity, double.infinity), hi = -lo;
        foreach (h; sel)
            foreach (q; item(h).points)
            {
                lo = Vec3(min(lo.x, q.x), min(lo.y, q.y), min(lo.z, q.z));
                hi = Vec3(max(hi.x, q.x), max(hi.y, q.y), max(hi.z, q.z));
            }
        auto s = hi - lo;
        return [["together", format("%s × %s × %s mm", g(s.x), g(s.y), g(s.z))]];
    }

    /// The rows of selectionRows on one line, "length 78 mm · …" (for agents).
    string selectionSizes()
    {
        string[] r;
        foreach (row; selectionRows())
            r ~= row[0] ~ " " ~ row[1];
        return r.join(" · ");
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

    void copy(string text)
    {
        import gobject.value : Value;
        window.getClipboard().set(new Value(text));
        info("copied: " ~ text);
        lastCopied = text;
    }

    string lastCopied;   /// what the latest copy put on the clipboard, for the control socket

    void appendFeature(PartMesh part, string call, string placeholder)
    {
        if (busy())
            return info("wait for the evaluation to finish, then try again");
        writeFeature(part, call, placeholder);
    }

    /// appendFeature without waiting for the evaluation: the steps of one
    /// operation on several parts, their selectors all from the same one.
    void writeFeature(PartMesh part, string call, string placeholder)
    {
        if (part.span.file != absolutePath(path))
            return info(format("part '%s' is defined in another file", part.name));
        try
        {
            // on a piece of @parts, that piece alone
            import std.algorithm : countUntil;
            immutable at = last.parts.countUntil!(q => q.name == part.name);
            applyEdit(at >= 0 && isPiece(at) ? appendToPiece(text(), path, part.fn, part.piece, part.fromSolid, call, placeholder)
                : appendToPart(text(), path, part.fn, call, placeholder));
            // the feature changes the faces and edges: the selection would
            // point at others
            viewport.setSelection(null);
            info("");
        }
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
        // the dimensions to show, and which stand out (those of the
        // constraints on the inspected lines)
        SketchView.Dimension[] want;
        bool[] wantLit;
        foreach (k; drawnRuns())
        {
            immutable index = sketchIndices[k];
            if (index >= last.sketches.length)
                continue;
            auto sk = last.sketches[index];
            bool[size_t] lit;
            if (sketchHighlight && k < sketchFound.length)
                foreach (c; sketchFound[k].constraints)
                    if (sk.constraints[c].dimension >= 0)
                        lit[sk.constraints[c].dimension] = true;
            foreach (di, d; sk.dimensions)
            {
                if (d.value.file != absolutePath(path))
                    continue;
                want ~= d;
                wantLit ~= (di in lit) !is null;
            }
        }
        // the same dimensions as shown: keep the buttons, only their look
        // changes (made again, they would flash at the corner of the view
        // before finding their place, at every click on a line)
        bool same = want.length == dims.length;
        foreach (i, d; want)
            if (same)
                same = d.label == dims[i].label && d.value == dims[i].value && d.conflicting == dims[i].conflicting;
        if (same)
        {
            foreach (i, b; dimButtons)
            {
                if (wantLit[i] && !want[i].conflicting)
                    b.addCssClass("hcad-dimension-lit");
                else
                    b.removeCssClass("hcad-dimension-lit");
                b.setOpacity(shownStale() ? 0.55 : 1);
            }
            dims = want;
            positionDimensions();
            return;
        }
        foreach (b; dimButtons)
            overlay.removeOverlay(b);
        dimButtons = null;
        dims = null;
        foreach (i, d; want)
            addDimensionButton(d, wantLit[i]);
        positionDimensions();
    }

    /// A button on dimension `d`: a function of its own, so that each
    /// button's click handler keeps its own dimension (a closure made in a
    /// loop body shares the loop's variables, and every button would edit
    /// the last one).
    void addDimensionButton(SketchView.Dimension d, bool lit)
    {
        auto b = new Button;
        b.setLabel(d.label);
        b.addCssClass("osd");
        b.addCssClass("hcad-dimension");
        if (d.conflicting)
            b.addCssClass("destructive-action");
        else if (lit)
            b.addCssClass("hcad-dimension-lit");
        if (shownStale())
            b.setOpacity(0.55);   // the last good sketch, while the code has an error
        b.setHalign(Align.Start);
        b.setValign(Align.Start);
        b.setTooltipText(format("line %d: click to change", d.value.line));
        b.connectClicked(() => editDimension(b, d));
        overlay.addOverlay(b);
        dimButtons ~= b;
        dims ~= d;
    }

    Button editingDimension;   /// the dimension whose field is open (hidden meanwhile)

    void positionDimensions()
    {
        foreach (i, b; dimButtons)
        {
            double x, y;
            immutable visible = viewport.project(dims[i].at, x, y);
            // the one being edited stays hidden under its field; all while the view is annotated
            b.setVisible(visible && b !is editingDimension && !frozen);
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

    /// A sketch drawn on a face or plane, for agents: where (origin, x, y,
    /// normal; points are given in its x, y) and how many references it has.
    static void sketchPlaneJson(ref JValue js, const SketchView sk)
    {
        if (!sk.placed)
            return;
        JValue v(Vec3 p) => toJSON([p.x, p.y, p.z]);
        js["plane"] = JSOB("origin", v(sk.place[0]), "x", v(sk.place[1]), "y", v(sk.place[2]), "normal", v(sk.place[3]));
        size_t refs;
        foreach (e; sk.entities)
            refs += e.reference && e.kind != "point";
        js["references"] = refs;
    }

    /// The sketches of the model, for the control socket: whether each is
    /// solved, how many points can still move, and its dimensions with the
    /// place of their value in the code (to change it with "dimension").
    JValue sketchesJson()
    {
        JValue r = JSAB();
        foreach (i, sk; last.sketches)
        {
            JValue js = JSOB("line", sk.span.line, "solved", sk.solved);
            js["degrees_of_freedom"] = sk.dof;
            sketchPlaneJson(js, sk);
            if (i < staleSketch.length && staleSketch[i])
                js["stale"] = true;   // the last good one: the code has an error in it
            else if (sk.partial)
                js["partial"] = true;   // made before an error stopped the run
            size_t free;
            foreach (pt; sk.points)
                free += pt.free;
            js["free_points"] = free;
            JValue ds = JSAB();
            foreach (d; sk.dimensions)
            {
                JValue jd = JSOB("label", d.label, "line", d.value.line, "col", d.value.col);
                if (d.value.file != absolutePath(path))
                    jd["file"] = d.value.file;
                else
                    try
                        jd["value"] = argumentText(text(), path, d.value.line, d.value.col);
                    catch (Exception)
                    {
                    }
                if (d.conflicting)
                    jd["conflicting"] = true;
                ds ~= jd;
            }
            js["dimensions"] = ds;
            r ~= js;
        }
        return r;
    }

    /// Edits the value of a dimension in place: the source is rewritten.
    void editDimension(Button b, SketchView.Dimension d)
    {
        string current;
        try
            current = argumentText(text(), path, d.value.line, d.value.col);
        catch (Exception e)
            return info(e.msg);
        // edited in place: the label becomes a field of the same size and
        // look, where it is; Enter writes the value, Esc or a click elsewhere
        // leaves it as it was
        import gtk.event_controller_focus : EventControllerFocus;
        auto entry = new Entry;
        entry.addCssClass("hcad-dimension-entry");
        entry.setText(current);
        // as wide as its value and a little room (a field's natural width is
        // otherwise a long line)
        immutable chars = cast(int) max(4, current.length + 2);
        entry.setWidthChars(chars);
        entry.setMaxWidthChars(chars);
        entry.setHalign(Align.Start);
        entry.setValign(Align.Start);
        // the field centred where the label was
        immutable cx = b.getMarginStart() + b.getWidth() / 2, cy = b.getMarginTop() + b.getHeight() / 2;
        entry.setMarginStart(max(0, cx - (cast(int) current.length + 2) * 4));
        entry.setMarginTop(max(0, cy - 13));
        editingDimension = b;
        b.setVisible(false);
        overlay.addOverlay(entry);
        bool done;
        void finish(string value)
        {
            if (done)
                return;
            done = true;
            // away from the signal handler: the entry goes, the button comes back
            idleAdd(PRIORITY_DEFAULT, () {
                overlay.removeOverlay(entry);
                if (editingDimension is b)
                    editingDimension = null;
                b.setVisible(true);
                return false;
            });
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
        }
        entry.connectActivate(() => finish(entry.getText()));
        auto keys = new EventControllerKey;
        keys.connectKeyPressed((uint key, uint code, ModifierType state) {
            if (key != KEY_Escape)
                return false;
            finish(null);
            return true;
        });
        entry.addController(keys);
        auto focus = new EventControllerFocus;
        focus.connectLeave(() => finish(null));
        entry.addController(focus);
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
            markSaved();
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
        TextIter it;
        buffer.getIterAtMark(it, buffer.getInsert());
        immutable line = it.getLine();
        buffer.setText(disk);
        TextIter at;
        if (buffer.getIterAtLine(at, line))
            placeCursorQuietly(at);
        markSaved();
    }

    void newFile() => confirmDiscard(&startNew);

    /// A new model from the template (New, Ctrl+N, the control socket).
    void startNew()
    {
        path = buildPath(dirName(path), "untitled.hcad");
        params.overrides = null;
        params.preset = null;
        params.invalidate();
        firstResult = true;
        resetInterface();
        replaceCode(newModelTemplate);
        diskTime = 0;
        markSaved();
    }

    void openFile() => confirmDiscard(&chooseFile);

    void chooseFile()
    {
        import gtk.file_filter : FileFilter;
        import gio.list_store : ListStore;

        auto d = new FileDialog;
        d.setTitle("Open a hackerscad model");
        auto filters = new ListStore(FileFilter._getGType());
        auto models = new FileFilter;
        models.setName("hackerscad models (*.hcad)");
        models.addSuffix("hcad");
        filters.append(models);
        auto meshes = new FileFilter;
        meshes.setName("Meshes, CAD files and drawings, to use with load() in a model (*.stl, *.obj, *.3mf, *.step, *.svg, *.dxf)");
        foreach (ext; importable)
            meshes.addSuffix(ext[1 .. $]);
        filters.append(meshes);
        auto all = new FileFilter;
        all.setName("All files");
        all.addPattern("*");
        filters.append(all);
        d.setFilters(filters);
        d.setDefaultFilter(models);
        d.open(window, null, (ObjectWrap src, AsyncResult res) {
            try
            {
                auto f = d.openFinish(res);
                if (f !is null)
                    openModel(f.getPath());
            }
            catch (ErrorWrap)
            {
            }
        });
    }

    /// Files a model can use with load(), not open as a model.
    static immutable importable = [".stl", ".obj", ".3mf", ".step", ".stp", ".svg", ".dxf"];

    /// Why `file` is not a model hackerscad can open (null if it is one).
    static string notAModel(string file)
    {
        import std.uni : toLower;

        immutable ext = extension(file).toLower;
        if (importable.canFind(ext))
            return format("“%s” is a %s file, not a hackerscad model. hackerscad opens models written as code "
                ~ "(.hcad); a model can use this file with load(\"%s\").", baseName(file), ext[1 .. $].toUpper,
                baseName(file));
        if (ext != ".hcad")
            return format("hackerscad opens only its models, .hcad files written as code: “%s” is not one%s.",
                baseName(file), ext.length ? format(" (%s files are not supported)", ext) : "");
        // a .hcad that is not text (a binary renamed, a broken download)
        try
        {
            import std.stdio : File;
            ubyte[4096] head;
            auto got = File(file, "rb").rawRead(head[]);
            if (got.canFind(0))
                return format("“%s” is not a text file: a hackerscad model is code.", baseName(file));
        }
        catch (Exception e)
            return format("“%s” cannot be read: %s", baseName(file), e.msg);
        return null;
    }

    /// Opens `file` if it is a model, else says why not (and for a mesh or
    /// CAD file, offers a new model that loads it).
    void openModel(string file)
    {
        if (auto why = notAModel(file))
            return refuseFile(file, why);
        load(file);
    }

    void refuseFile(string file, string why)
    {
        import adw.alert_dialog : AlertDialog;
        import adw.types : ResponseAppearance;
        import std.uni : toLower;

        immutable canLoad = importable.canFind(extension(file).toLower);
        auto d = new AlertDialog("Not a hackerscad model", why);
        if (canLoad)
        {
            d.addResponse("cancel", "_Cancel");
            d.addResponse("new", "_New model that loads it");
            d.setResponseAppearance("new", ResponseAppearance.Suggested);
            d.setDefaultResponse("new");
            d.setCloseResponse("cancel");
            d.connectResponse(null, (string response) {
                if (response == "new")
                    confirmDiscard(() => newModelLoading(file));
            });
        }
        else
        {
            d.addResponse("ok", "_OK");
            d.setCloseResponse("ok");
        }
        d.present(window);
    }

    /// A new, unsaved model next to `file` that loads it as a part.
    void newModelLoading(string file)
    {
        import std.uni : isAlphaNum;
        import std.path : stripExtension;

        auto stem = baseName(stripExtension(file));
        string name;
        foreach (dchar c; stem)
            name ~= c.isAlphaNum && c < 128 ? c : '_';
        if (name.length == 0 || (name[0] >= '0' && name[0] <= '9'))
            name = "model_" ~ name;
        auto target = buildPath(dirName(file), name ~ ".hcad");
        for (int k = 2; exists(target); k++)
            target = buildPath(dirName(file), format("%s_%d.hcad", name, k));
        agentText = null;
        path = target;
        params.overrides = null;
        params.preset = null;
        params.invalidate();
        firstResult = true;
        resetInterface();
        import std.uni : toLower;
        immutable drawing = [".svg", ".dxf"].canFind(extension(file).toLower);
        replaceCode(drawing
            ? format("module %s;\n\nimport std.shapes;\n\n"
                ~ "// the outlines of %s, from the same folder as this model, made a plate\n"
                ~ "@part\nSolid imported() => load(\"%s\")\n    .extrude(3.mm);\n", name, baseName(file), baseName(file))
            : format("module %s;\n\nimport std.shapes;\n\n"
                ~ "// %s, from the same folder as this model: cut it, add to it, measure it\n"
                ~ "@part\nSolid imported() => load(\"%s\");\n", name, baseName(file), baseName(file)));
        diskTime = 0;
        modified = true;
        hasSaved = false;
        updateTitle();
    }

    void load(string file)
    {
        agentText = null;
        path = file;
        params.overrides = null;
        params.preset = null;
        params.invalidate();
        firstResult = true;
        resetInterface();
        replaceCode(readText(path));
        diskTime = mtimeOf(path);
        markSaved();
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
    JValue userChange;
    ulong revision;     /// goes up at every change of the code

    void handleControl(string method, JValue p, void delegate(JValue, string) reply)
    {
        if (agentText !is null)
            userChange = changedLines(agentText, text());
        // only: of the state a reply carries, the fields named (the rest of the reply stays), as state's own only
        bool[string] only;
        if (method != "state" && p.isObject && p.has("only") && !p["only"].isNull)
        {
            if (!p["only"].isArray)
                return reply(JValue.init, "only is a list of the state's fields, e.g. [\"revision\", \"problems\"]");
            foreach (f; p["only"].get!JArray.elements)
            {
                auto name = f.isString ? f.get!string : "";
                if (!stateFields.canFind(name))
                    return reply(JValue.init, format("only: no field %s in the state; its fields: %-(%s, %)",
                        f.toJSON(), stateFields));
                only[name] = true;
            }
        }
        dispatchControl(method, p, (JValue r, string e) {
            agentText = text();
            userChange = JValue.init;
            if (only.length && r.isObject)
                foreach (name; stateFields)
                    if (name != "window" && name !in only && r.has(name))
                        r.remove(name);
            reply(r, e);
        });
    }

    /// The lines of `after` that differ from `before` (null when equal).
    static JValue changedLines(string before, string after)
    {
        import std.string : splitLines;
        if (before == after)
            return JValue(null);
        auto a = before.splitLines, b = after.splitLines;
        size_t head, tail;
        while (head < a.length && head < b.length && a[head] == b[head])
            head++;
        while (tail < a.length - head && tail < b.length - head && a[$ - 1 - tail] == b[$ - 1 - tail])
            tail++;
        JValue j = JSOB("from", head + 1, "to", b.length - tail, "replaced_lines", a.length - tail - head);
        return j;
    }

    /// The window point a request aims at: "point" [x, y, z] in model mm, or
    /// "x" and "y" as fractions of the view. Null, or what is wrong.
    string screenPoint(JValue p, out double x, out double y)
    {
        if (p.has("point") && p["point"].isArray)
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
        x = (p.has("x") ? numberOf(p["x"]) : 0.5) * viewport.width;
        y = (p.has("y") ? numberOf(p["y"]) : 0.5) * viewport.height;
        return null;
    }

    static double numberOf(JValue v) => v.get!double;
    static Vec3 vec3Of(JValue v) => Vec3(numberOf(v[0]), numberOf(v[1]), v.length > 2 ? numberOf(v[2]) : 0);
    static JValue jsonOf(Vec3 v) => toJSON([v.x, v.y, v.z]);

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
    JValue hitJson(Hit hit)
    {
        JValue r = JSOB("part", hit.part >= 0 ? JValue(last.parts[hit.part].name) : JValue(null));
        if (hit.part < 0)
            return r;
        r["face"] = hit.face;
        r["point"] = jsonOf(hit.point);
        r["normal"] = jsonOf(hit.normal);
        if (hit.face >= 0)
        {
            auto part = last.parts[hit.part];
            SolidVal sv;
            auto it = selectorInterp(part, sv);
            try
                r["selector"] = faceSelector(it, sv, hit.face);
            catch (Exception)
            {
            }
        }
        return r;
    }

    /// The selected faces and edges, with selectors and sizes.
    JValue selectionJson()
    {
        JValue items = JSAB();
        foreach (h; viewport.selection())
        {
            if (h.part < 0 || h.part >= last.parts.length)
                continue;
            auto part = last.parts[h.part];
            SolidVal sv;
            auto it = selectorInterp(part, sv);
            JValue j = JSOB("part", part.name);
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
                    j["length"] = e.length;   // along the curve
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
        JValue r = JSOB("selection", items);
        // what the info line says of it: sizes, how far apart, the room they take
        if (auto sizes = selectionSizes())
            r["sizes"] = sizes;
        return r;
    }

    /// A measured item: a part name, a point [x, y, z], or (null) the next selected item.
    string measureItem(JValue v, ref size_t nextSelected, out Item item, out int wholePart)
    {
        import hackerscad.gui.measure : faceItem, edgeItem, pointItem;
        wholePart = -1;
        if (v.isArray)
        {
            item = pointItem(vec3Of(v));
            return null;
        }
        if (v.isString)
        {
            string problem;
            immutable i = partIndex(v.get!string, problem);
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
            return "select two items first (hcad_gui_selection or two clicks), or pass a and b";
        auto h = sel[nextSelected++];
        item = h.edge >= 0 ? edgeItem(last.parts[h.part], h.edge) : faceItem(last.parts[h.part], h.face);
        return null;
    }

    /// A menu as JSON: entries with their label, value and sub-entries; headings as titles.
    static JValue menuJson(MenuEntry[] entries)
    {
        JValue r = JSAB();
        foreach (e; entries)
        {
            final switch (e.kind)
            {
            case MenuEntry.Kind.separator:
                continue;
            case MenuEntry.Kind.heading:
                r ~= JSOB("heading", e.label ~ (e.detail.length ? " · " ~ e.detail : ""));
                continue;
            case MenuEntry.Kind.item, MenuEntry.Kind.group:
                break;
            }
            JValue j = JSOB("label", e.label);
            if (e.detail.length)
                j["value"] = e.detail;
            if (!e.enabled)
                j["enabled"] = false;
            if (e.kind == MenuEntry.Kind.group)
                j["entries"] = menuJson(e.children);
            r ~= j;
        }
        return r;
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

    // the control socket's methods: gui/controlmethods
    mixin ControlMethods;
    mixin SketchFollow;
    mixin SketchEdit;
    mixin Annotate;

    /// Every field the state can have, for hcad_gui_state's only.
    static immutable string[] stateFields = ["path", "status", "window", "version", "outdated", "revision",
        "user_changed", "evaluating", "stage", "seconds", "modified", "source_hash", "preset", "overrides", "parts",
        "params", "presets", "inspect", "sketch", "sketch_follow", "annotations", "annotate_mode", "annotated_view",
        "cursor", "camera", "printability", "graphics", "problems", "log", "source", "steps"];

    /// The window's state, as hcad_gui_state gives it; `graphics` adds
    /// what draws the 3D view and how fast.
    JValue state(bool graphics = false)
    {
        JValue j = JSOB("path", path, "status", statusText);
        j["window"] = control ? control.name : null;
        j["version"] = appVersion;
        if (exeChanged())
            j["outdated"] = "hackerscad was rebuilt or updated after this window started: ask the user to restart it "
                ~ "to get the newest tools";
        j["revision"] = revision;
        if (!userChange.isNull)
            j["user_changed"] = userChange;
        j["evaluating"] = evaluator.busy;
        if (evaluator.busy)
        {
            j["stage"] = stage;
            j["seconds"] = (MonoTime.currTime - evalStart).total!"msecs" / 1000.0;
        }
        j["modified"] = modified;
        j["source_hash"] = format("%016x", codeHash(text()));
        j["preset"] = params.preset;
        j["overrides"] = JValue(params.overrides);
        JValue parts = JSAB();
        foreach (pm; last.parts)
        {
            import hackerscad.geom.color : hexColor;
            JValue jp = JSOB("name", pm.name, "color", hexColor(pm.rgb));
            jp["size"] = toJSON([pm.bbox.size.x, pm.bbox.size.y, pm.bbox.size.z]);
            jp["volume_mm3"] = pm.volume;
            jp["line"] = pm.span.line;
            jp["hidden"] = viewport.isHidden(parts.length);
            if (pm.label != pm.name)
                jp["export_name"] = pm.label;
            if (!pm.export_)
                jp["export"] = false;
            parts ~= jp;
        }
        j["parts"] = parts;
        JValue ps = JSAB();
        foreach (pi; last.params)
        {
            JValue jp = JSOB("name", pi.name, "value", pi.value.toString);
            jp["default"] = pi.defaultValue.toString;
            jp["type"] = pi.value.typeName;
            if (pi.doc.length)
                jp["doc"] = pi.doc;
            // the limits and steps of the panel's field, the entries of its menu
            auto limits = ["min": pi.min, "max": pi.max, "step": pi.step];
            foreach (key; ["max", "min", "step"])
                if (limits[key].kind != Kind.void_)
                    jp[key] = limits[key].toString;
            if (pi.choices.length)
            {
                JValue cs = JSAB();
                foreach (c; pi.choices)
                    cs ~= c.toString;
                jp["choices"] = cs;
            }
            ps ~= jp;
        }
        j["params"] = ps;
        j["presets"] = toJSON(last.presets);
        j["inspect"] = inspectJson();
        j["sketch"] = shownSketchJson();
        j["sketch_follow"] = followCursor;
        annotationsState(j);
        {
            TextIter it;
            buffer.getIterAtMark(it, buffer.getInsert());
            j["cursor"] = JSOB("line", it.getLine() + 1, "col", it.getLineOffset() + 1);
        }
        auto cam = viewport.camera();
        JValue jc = JSOB("yaw", cam.yaw, "pitch", cam.pitch, "distance", cam.distance);
        jc["target"] = toJSON([cam.target.x, cam.target.y, cam.target.z]);
        jc["projection"] = cam.orthographic ? "orthographic" : "perspective";
        jc["grid"] = viewport.showGrid;
        jc["axes"] = viewport.showAxes;
        jc["style"] = viewport.shading == Shading.wireframe ? "wireframe"
            : viewport.shading == Shading.shaded ? "shaded" : "edges";
        jc["printability"] = viewport.printability;
        jc["shine"] = ["none", "normal", "high"][viewport.shine];
        jc["select"] = ["part", "face", "edge", "vertex"][viewport.selectMode];
        j["camera"] = jc;
        if (viewport.printability)
            j["printability"] = printabilityJson();
        if (graphics)
            j["graphics"] = graphicsJson();
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
        ExportFormat("stl", "STL", "for any slicer: a zip of one STL per part when there are more"),
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
        {
            m.append(f.label ~ " — " ~ f.what, "win.export-" ~ f.ext);
            if (f.ext == "3mf")
                m.append("3MF, one object — the parts as its pieces: for prints in several colours",
                    "win.export-3mf-one");
        }
        return m;
    }

    MenuButton examplesButton, exportButton;   /// in the header bar

    /// The Examples button: models to open and try, as unsaved new models.
    Widget examplesMenu()
    {
        auto m = new GMenu;
        foreach (e; examples)
            m.append(e.what.length ? e.label ~ " — " ~ e.what : e.label, "win.example-" ~ e.name);
        auto b = new MenuButton;
        b.setLabel("Examples");
        b.setAlwaysShowArrow(true);
        b.setTooltipText("Open an example model, to try and change");
        b.setMenuModel(m);
        examplesButton = b;
        return b;
    }

    // a function of its own: closures made in a loop would all share the last name
    void delegate() exampleAction(string name) => () => confirmDiscard(() { startExample(name); });

    /// A new model with the example `name`'s code, not saved yet: its
    /// file would be name.hcad next to the current one (name_2.hcad if
    /// that exists). False when there is no such example.
    bool startExample(string name)
    {
        import std.algorithm : find;
        auto e = examples.find!(x => x.name == name);
        if (e.length == 0)
            return false;
        auto target = buildPath(dirName(path), name ~ ".hcad");
        for (int k = 2; exists(target); k++)
            target = buildPath(dirName(path), format("%s_%d.hcad", name, k));
        agentText = null;
        path = target;
        params.overrides = null;
        params.preset = null;
        params.invalidate();
        firstResult = true;
        resetInterface();
        replaceCode(e[0].source);
        diskTime = 0;
        markSaved();
        return true;
    }

    /// The export button: a menu of the formats.
    Widget exportMenu()
    {
        auto b = new MenuButton;
        b.setLabel("Export");
        b.setAlwaysShowArrow(true);
        b.setTooltipText("Export: 3MF, STL, STEP or PNG (" ~ shortcutKey ~ "+E repeats the last format)");
        b.setMenuModel(exportModel());
        exportButton = b;
        return b;
    }

    /// The export dialog for format `ext`; `part`: that part alone;
    /// `oneObject`: a 3MF of one object made of the parts.
    void exportFile(string ext, string part = null, bool oneObject = false)
    {
        import gtk.file_filter : FileFilter;
        import std.algorithm : count, find;
        if (last.parts.length == 0)
            return;
        // the unittests, if they have not run on this model: while the file is chosen
        if (last.unittests > 0 && !last.unittestsRan)
            runTests();
        exportFormat = ext;
        auto format = exportFormats.find!(f => f.ext == ext)[0];
        // several parts in STL: a zip, one file each
        immutable several = part is null && last.parts.count!(p => p.export_) > 1;
        immutable fileExt = ext == "stl" && several ? "zip" : ext;
        auto d = new FileDialog;
        d.setTitle("Export " ~ (part ? part ~ " as " : "") ~ format.label
            ~ (fileExt == "zip" ? ": a zip with one STL per part" : ""));
        // every format in the dialog's list, the chosen one selected
        import gio.list_store : ListStore;
        auto filters = new ListStore(FileFilter._getGType());
        void addFilter(string label, string what, string fext)
        {
            auto filter = new FileFilter;
            filter.setName(label ~ " — " ~ what ~ " (*." ~ fext ~ ")");
            filter.addSuffix(fext);
            if (fext == "step")
                filter.addSuffix("stp");
            filters.append(filter);
            if (fext == fileExt)
                d.setDefaultFilter(filter);
        }
        foreach (f; exportFormats)
            addFilter(f.label, f.what, f.ext);
        addFilter("ZIP", "one STL per part", "zip");
        d.setFilters(filters);
        immutable base = baseName(path).endsWith(".hcad") ? baseName(path)[0 .. $ - 5] : "model";
        string initial = base;
        if (part)
            foreach (p; last.parts)
                if (p.name == part)
                {
                    import hackerscad.tool.exporter : fileNames;
                    initial = fileNames([p.label])[0];
                }
        d.setInitialName(initial ~ "." ~ fileExt);
        d.save(window, null, (ObjectWrap src, AsyncResult res) {
            try
            {
                auto f = d.saveFinish(res);
                if (f is null)
                    return;
                auto out_ = f.getPath();
                // the format comes from the name; without a known extension, the chosen one
                immutable given = extension(out_).toLower;
                if (![".3mf", ".stl", ".zip", ".step", ".stp", ".png"].canFind(given))
                    out_ ~= "." ~ fileExt;
                if (part is null)
                    exportFormat = given == ".zip" ? "stl" : given.length > 1
                        && [".3mf", ".stl", ".step", ".png"].canFind(given) ? given[1 .. $] : ext;
                auto warnings = exportTo(out_, part ? [part] : null, oneObject);
                note("exported " ~ out_ ~ (warnings.length ? "; warning: " ~ warnings.join("; ") : ""));
            }
            catch (ErrorWrap)
            {
            }
            catch (Exception e)
                note("export failed: " ~ e.msg);
        });
    }

    /// Writes the parts shown (with the window's parameters) to `out_`, the
    /// format from its extension (see hackerscad.tool.exporter; .png the
    /// view). `only`: those parts, by function name or @part(name:); else
    /// every part but the reference ones.
    string[] exportTo(string out_, string[] only = null, bool oneObject = false)
    {
        import std.algorithm : countUntil, filter, map;
        import std.array : array, join;
        import hackerscad.tool.exporter : ExportPart, exportParts;
        if (last.parts.length == 0)
            throw new Exception("nothing to export: the model has no parts yet");
        if (extension(out_).length == 0)
            out_ ~= ".3mf";
        PartMesh[] parts;
        foreach (want; only)
        {
            auto i = last.parts.countUntil!(p => p.name == want || p.label == want);
            if (i < 0)
                throw new Exception(format("no part named '%s' (the parts: %s)", want,
                    last.parts.map!(p => p.name).join(", ")));
            parts ~= last.parts[i];
        }
        // reference parts (export: false) only appear in pictures
        if (only.length == 0)
            parts = extension(out_).toLower == ".png" ? last.parts : last.parts.filter!(p => p.export_).array;
        if (parts.length == 0)
            throw new Exception("nothing to export: every part has export: false");
        switch (extension(out_).toLower)
        {
        case ".png":
            {
                // the 3D view as it is, drawn by OpenGL at twice its size;
                // parts asked for by name alone, the others hidden meanwhile
                immutable w = max(640, viewport.area.getWidth() * 2), h = max(480, viewport.area.getHeight() * 2);
                bool[] wasHidden;
                if (only.length)
                    foreach (i, pm; last.parts)
                    {
                        wasHidden ~= viewport.isHidden(i);
                        viewport.setHidden(i, !parts.canFind!(q => q.name == pm.name));
                    }
                auto pixels = viewport.renderImage(w, h);
                foreach (i, hide; wasHidden)
                    viewport.setHidden(i, hide);
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
        {
            import std.path : stripExtension;
            return exportParts(out_, parts.map!(p => ExportPart(p.label, p.welded, p.rgb, p.brep)).array, parts[0].kernel,
                oneObject ? baseName(stripExtension(path)) : null);
        }
        }
        return null;
    }
}
