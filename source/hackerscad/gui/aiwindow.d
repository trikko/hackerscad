/// The AI Agents window: how to connect an agent to hackerscad (its MCP
/// server and its skill, the commands for this installation, to copy), which
/// agent drives this window and what it asked lately, and what to ask an
/// agent to see that it is connected: it then shows there by its own name.
/// An agent that works on the window but never shows here is not using
/// hackerscad's tools: it may be clicking in it through the screen (Codex's
/// computer use on macOS), slow and blind to the model.
module hackerscad.gui.aiwindow;

import std.algorithm : canFind, map;
import std.array : array, join;
import std.datetime.systime : Clock, SysTime;
import std.format : format;
import std.string : indexOf, strip;

import adw.action_row : ActionRow;
import adw.header_bar : HeaderBar;
import adw.toolbar_view : ToolbarView;
import adw.window : AdwWindow = Window;
import glib.global : timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gobject.value : Value;
import gtk.box : Box;
import gtk.frame : Frame;
import gtk.image : Image;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.scrolled_window : ScrolledWindow;
import gtk.types : Align, Orientation, PolicyType, SelectionMode;
import gtk.widget : Widget;
import gtk.window : Window;


/// A request an agent sent to the window.
struct AgentCall
{
    SysTime when;
    string client;   /// the agent as its MCP server tells it, empty when not said
    string method;
    string error;    /// empty when it went well
}

/// What the AI window shows of the agents: the requests of this window,
/// the latest last (at most `keep`).
struct AgentLog
{
    enum keep = 40;
    AgentCall[] calls;

    void add(AgentCall c)
    {
        calls ~= c;
        if (calls.length > keep)
            calls = calls[$ - keep .. $];
    }

    /// The agents seen, each once, the latest first.
    string[] clients() const
    {
        string[] r;
        foreach_reverse (c; calls)
            if (!r.canFind(c.client))
                r ~= c.client;
        return r;
    }
}

/// The name an agent is shown by: its own, or what it is when it said none.
string clientLabel(string client) =>
    client.length ? client : "hcad without a name (the command line, or an MCP server older than this window)";

/// The command that runs hackerscad's command line tool here: the AppImage
/// followed by the word hcad, else hcad beside this program (in the macOS
/// bundle's bin, in a Windows folder, in bin/ built from source).
string[] hcadCommand()
{
    import std.file : exists, thisExePath;
    import std.path : buildPath, dirName;
    import std.process : environment;
    if (auto image = environment.get("APPIMAGE"))
        return [image, "hcad"];
    version (Windows)
        auto beside = buildPath(dirName(thisExePath), "hcad.exe");
    else
        auto beside = buildPath(dirName(thisExePath), "hcad");
    return [exists(beside) ? beside : "hcad"];
}

/// `words` as one command line, those with spaces or quotes quoted.
string commandLine(const string[] words)
{
    string q(string w)
    {
        import std.algorithm : any;
        if (!w.any!(c => c == ' ' || c == '"' || c == '\'' || c == '(' || c == ')' || c == '&' || c == ';'))
            return w;
        version (Windows)
            return `"` ~ w ~ `"`;
        else
        {
            import std.array : replace;
            return "'" ~ w.replace("'", `'\''`) ~ "'";
        }
    }
    return words.map!q.join(" ");
}

/// An agent hackerscad tells how to connect: the command that adds the MCP
/// server, the one that lists them, and the folder of its skills.
struct Agent
{
    string name;
    string[] add;      /// before hcad's own command
    string list;
    string skills;     /// the folder for all projects, ~ for the home
}

immutable Agent[] agents = [
    Agent("Claude Code", ["claude", "mcp", "add", "-s", "user", "hcad", "--"], "claude mcp list", "~/.claude/skills"),
    Agent("Codex", ["codex", "mcp", "add", "hcad", "--"], "codex mcp list", "~/.agents/skills"),
    Agent("Antigravity", ["agy", "mcp", "add", "hcad"], "agy mcp list", "~/.gemini/antigravity-cli/skills"),
];

/// The command that adds hackerscad's MCP server to `a`.
string mcpCommand(const Agent a) => commandLine(a.add ~ hcadCommand() ~ "mcp");

/// The commands that install the skill for `a`, for all projects.
string skillCommands(const Agent a)
{
    immutable hcad = commandLine(hcadCommand());
    immutable dir = a.skills ~ "/hackerscad";
    version (Windows)
    {
        import std.array : replace;
        immutable w = dir.replace("~", "%USERPROFILE%").replace("/", `\`);
        return format("mkdir \"%s\"\n%s docs --skill > \"%s\\SKILL.md\"\n%s docs > \"%s\\llms-full.txt\"", w, hcad, w,
            hcad, w);
    }
    else
        return format("mkdir -p %s\n%s docs --skill > %s/SKILL.md\n%s docs > %s/llms-full.txt", dir, hcad, dir, hcad, dir);
}

unittest
{
    assert(commandLine(["claude", "mcp", "add", "/my apps/hcad", "mcp"]).canFind("'/my apps/hcad'")
        || commandLine(["claude", "mcp", "add", "/my apps/hcad", "mcp"]).canFind(`"/my apps/hcad"`));
    assert(mcpCommand(agents[1]).canFind("codex mcp add hcad -- ") && mcpCommand(agents[1])[$ - 4 .. $] == " mcp");
    AgentLog log;
    foreach (i; 0 .. 50)
        log.add(AgentCall(Clock.currTime, i % 2 ? "codex 0.48" : "claude-code 2.1", "state"));
    assert(log.calls.length == AgentLog.keep && log.clients == ["codex 0.48", "claude-code 2.1"]);
}

final class AiWindow
{
    AdwWindow window;
    /// Called when it closes.
    void delegate() onClosed;

    /// `windowName`: the name agents call this window by; `log`: its agents' requests, read again every
    /// second while the window is open.
    this(Window parent, string windowName, const(AgentLog)* delegate() log)
    {
        this.windowName = windowName;
        this.log = log;
        window = new AdwWindow;
        window.setTitle("AI Agents");
        window.setDefaultSize(620, 720);
        window.setTransientFor(parent);
        window.connectCloseRequest(() {
            open = false;
            if (onClosed !is null)
                onClosed();
            return false;
        });

        auto page = new Box(Orientation.Vertical, 12);
        page.setMarginStart(18);
        page.setMarginEnd(18);
        page.setMarginTop(6);
        page.setMarginBottom(18);

        page.append(heading("Is an agent connected?"));
        // laid out to keep still while it changes every second: the headline changes only with the state,
        // each agent a row whose one-line subtitle holds what moves, the latest requests always shown lines
        status = text("");
        status.setSelectable(false);
        page.append(status);
        agentList = new ListBox;
        agentList.setSelectionMode(SelectionMode.None);
        agentList.addCssClass("boxed-list");
        page.append(agentList);
        recent = new Label("");
        recent.setXalign(0);
        recent.setYalign(0);
        recent.setMarginStart(10);
        recent.setMarginEnd(10);
        recent.setMarginTop(6);
        recent.setMarginBottom(8);
        recent.addCssClass("monospace");
        recent.addCssClass("dim-label");
        auto title = new Label("Latest requests");
        title.addCssClass("heading");
        title.setXalign(0);
        title.setMarginTop(4);
        page.append(title);
        auto frame = new Frame(null);
        frame.setChild(recent);
        page.append(frame);

        // the check is the agent's own: asked to call a tool on this window, it shows above by its name
        page.append(heading("Check your agent"));
        immutable ask = format("Call the hcad_gui_ai tool on the hackerscad window %s.", windowName);
        page.append(text("Ask your agent, in its own chat, what the row below says (click it to copy). Connected, it "
            ~ "shows above under its own name within seconds. If it answers that it has no such tool, or nothing "
            ~ "shows, it is not connected: add the MCP server below and restart the agent."));
        auto check = new ListBox;
        check.setSelectionMode(SelectionMode.None);
        check.addCssClass("boxed-list");
        check.append(copyRow("Ask your agent", ask, null));
        page.append(check);

        page.append(heading("Connect an agent"));
        page.append(text("An agent drives hackerscad through its MCP server, with the hcad_gui_* tools, and learns "
            ~ "the language from its skill. Add both once with the commands below (click a row to copy it), then "
            ~ "restart the agent. Without the server an agent may click in this window through the screen, "
            ~ "slowly and blind to the model: on macOS Codex shows a green icon on the window then."));
        auto list = new ListBox;
        list.setSelectionMode(SelectionMode.None);
        list.addCssClass("boxed-list");
        foreach (a; agents)
        {
            list.append(copyRow(a.name ~ ": the MCP server", mcpCommand(a), "check it with " ~ a.list));
            list.append(copyRow(a.name ~ ": the skill, for all projects", skillCommands(a), null));
        }
        page.append(list);
        page.append(text("Other agents: a server started by the command " ~ commandLine(hcadCommand() ~ "mcp")
            ~ ", named hcad (the skill names its tools so)."));

        auto scroll = new ScrolledWindow;
        scroll.setPolicy(PolicyType.Never, PolicyType.Automatic);
        scroll.setVexpand(true);
        scroll.setChild(page);
        auto t = new ToolbarView;
        t.addTopBar(new HeaderBar);
        t.setContent(scroll);
        window.setContent(t);

        refresh();
        timeoutAdd(PRIORITY_DEFAULT, 1000, () {
            if (!open)
                return false;
            refresh();
            return true;
        });
    }

    void present() => window.present();

    void close() => window.close();

private:

    string windowName;
    const(AgentLog)* delegate() log;
    Label status, recent;
    ListBox agentList;
    ActionRow[string] agentRows;   /// by client, those shown
    enum recentLines = 8;
    bool open = true;

    /// The status and the latest requests, from the log as it is now.
    void refresh()
    {
        auto l = log();
        immutable none = l is null || l.calls.length == 0;
        immutable headline = none
            ? format("No agent has used this window (%s) through hackerscad's tools since it opened. If one is "
                ~ "working on it all the same, it is not using them: add the MCP server below and restart the agent.",
                windowName)
            : format("Connected through MCP: the agents that have used this window (%s).",
                windowName);
        if (status.getLabel() != headline)
            status.setLabel(headline);
        agentList.setVisible(!none);
        string[] lines;
        if (!none)
        {
            // a row per agent, made once; its subtitle updated in place
            foreach (c; l.clients)
            {
                size_t n;
                AgentCall last;
                foreach (x; l.calls)
                    if (x.client == c)
                    {
                        n++;
                        last = x;
                    }
                auto row = agentRows.get(c, null);
                if (row is null)
                {
                    row = new ActionRow;
                    row.setUseMarkup(false);
                    row.setTitle(clientLabel(c));
                    row.setTitleLines(1);
                    row.setSubtitleLines(1);
                    agentList.prepend(row);
                    agentRows[c] = row;
                }
                immutable sub = format("%s request%s · last: %s%s", n, n > 1 ? "s" : "", last.method,
                    last.error.length ? ", it failed" : "");
                if (row.getSubtitle() != sub)
                    row.setSubtitle(sub);
            }
            foreach_reverse (c; l.calls[$ > recentLines ? $ - recentLines : 0 .. $])
            {
                auto who = c.client.length ? c.client : "(no name)";
                if (who.length > 24)
                    who = who[0 .. 23] ~ "…";
                lines ~= format("%02d:%02d:%02d  %-12s %-24s %s", c.when.hour, c.when.minute, c.when.second,
                    c.method, who, c.error.length ? "failed" : "");
            }
        }
        // always as many lines: the window keeps its height
        if (lines.length == 0)
            lines ~= "No requests yet";
        while (lines.length < recentLines)
            lines ~= "";
        immutable shown = lines.join("\n");
        if (recent.getLabel() != shown)
            recent.setLabel(shown);
    }

    static Label heading(string s)
    {
        auto l = new Label(s);
        l.addCssClass("heading");
        l.setXalign(0);
        l.setMarginTop(6);
        return l;
    }

    static Label text(string s)
    {
        auto l = new Label(s);
        l.setWrap(true);
        l.setXalign(0);
        l.setSelectable(true);
        return l;
    }

    ActionRow copyRow(string title, string command, string note)
    {
        auto r = new ActionRow;
        r.setUseMarkup(false);
        r.setTitle(title);
        r.setSubtitle(command ~ (note.length ? "\n(" ~ note ~ ")" : ""));
        r.setSubtitleSelectable(true);
        r.addSuffix(Image.newFromIconName("hcad-copy-symbolic"));
        r.setActivatable(true);
        r.connectActivated(() {
            window.getClipboard().set(new Value(command));
            r.setTitle(title ~ ": copied");
        });
        return r;
    }
}
