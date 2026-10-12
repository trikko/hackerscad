/// Control channel of the desktop application: a Unix socket (on Windows a
/// TCP port on 127.0.0.1, written in a file) speaking one JSON object per
/// line. `hackerscad` listens; the MCP server and scripts connect.
module hackerscad.tool.guiclient;

import std.conv : to;
import std.format : format;
import std.json;
import std.path : buildPath;
import std.process : environment;
import std.socket;
import std.string : indexOf;

/// Where each open window has its control channel, named after the window:
/// $XDG_RUNTIME_DIR/hackerscad/NAME.sock (or $TMPDIR/hackerscad-$USER/);
/// on Windows %LOCALAPPDATA%\hackerscad\windows\NAME.port, the file holding the port.
string controlDir()
{
    version (Windows)
        return buildPath(environment.get("LOCALAPPDATA", environment.get("TEMP", ".")), "hackerscad", "windows");
    else
    {
        auto dir = environment.get("XDG_RUNTIME_DIR");
        if (dir.length)
            return buildPath(dir, "hackerscad");
        return buildPath(environment.get("TMPDIR", "/tmp"), "hackerscad-" ~ environment.get("USER", "user"));
    }
}

version (Windows)
    enum controlExtension = ".port";
else
    enum controlExtension = ".sock";

string socketPath(string window) => buildPath(controlDir(), window ~ controlExtension);

/// A socket of the right family for the control channel.
Socket controlSocket()
{
    version (Windows)
        return new Socket(AddressFamily.INET, SocketType.STREAM);
    else
        return new Socket(AddressFamily.UNIX, SocketType.STREAM);
}

/// The address a window listens on (throws if it is not running).
Address controlAddress(string window)
{
    version (Windows)
    {
        import std.file : readText;
        import std.string : strip;
        try
            return new InternetAddress("127.0.0.1", readText(socketPath(window)).strip.to!ushort);
        catch (Exception)
            throw new SocketException("no port file");
    }
    else
        return new UnixAddress(socketPath(window));
}

/// Whether a window with this name is open and answering.
bool windowAlive(string window)
{
    try
    {
        auto probe = controlSocket();
        scope (exit)
            probe.close();
        probe.connect(controlAddress(window));
        return true;
    }
    catch (SocketException)
        return false;
}

/// Names of the open windows, sorted.
string[] openWindows()
{
    import std.algorithm : filter, map, sort;
    import std.array : array;
    import std.file : dirEntries, exists, isDir, SpanMode;
    import std.path : baseName, extension, stripExtension;
    auto dir = controlDir();
    if (!exists(dir) || !isDir(dir))
        return null;
    auto names = dirEntries(dir, "*" ~ controlExtension, SpanMode.shallow)
        .map!(e => e.name.baseName.stripExtension)
        .filter!windowAlive
        .array;
    names.sort();
    return names;
}

/// A window name as the user may type it: lower case, words joined by '-'.
/// Returns null if nothing usable is left.
string normalizeWindowName(string s)
{
    import std.ascii : isAlphaNum, toLower;
    char[] r;
    foreach (char c; s)
    {
        if (c < 0x80 && isAlphaNum(c))
            r ~= toLower(c);
        else if (r.length && r[$ - 1] != '-')
            r ~= '-';
    }
    while (r.length && r[$ - 1] == '-')
        r = r[0 .. $ - 1];
    return r.length > 40 ? r[0 .. 40].idup : r.idup;
}

/// A random name easy to say to an agent, such as "blue-otter".
string randomWindowName()
{
    import std.random : choice;
    static immutable adjectives = ["amber", "blue", "brave", "bright", "calm", "clever", "coral", "crimson",
        "eager", "fuzzy", "gentle", "golden", "green", "happy", "jolly", "keen", "lively", "lucky", "mellow",
        "misty", "noble", "olive", "plum", "proud", "quick", "quiet", "rapid", "rusty", "silver", "sunny",
        "swift", "tidy", "violet", "witty", "young", "zesty"];
    static immutable nouns = ["badger", "beaver", "bison", "comet", "crane", "falcon", "ferret", "fox", "gecko",
        "harbor", "heron", "koala", "lantern", "lemur", "lynx", "maple", "meadow", "moose", "otter", "owl",
        "panda", "pebble", "pine", "puffin", "quokka", "raven", "river", "robin", "salmon", "spruce", "tiger",
        "walrus", "willow", "wombat", "yak", "zebra"];
    return choice(adjectives) ~ "-" ~ choice(nouns);
}

/// Sends {"method": …, "params": …} to a window and returns the "result"
/// member. Without a name, the only open window; with several, an error
/// that lists them.
JSONValue guiRequest(string window, string method, JSONValue params)
{
    import std.array : join;
    import std.algorithm : canFind;
    enum notRunning = "hackerscad is not running: start it with `hackerscad model.hcad`";
    auto open = openWindows();
    if (window.length == 0)
    {
        if (open.length == 0)
            throw new Exception(notRunning);
        if (open.length > 1)
            throw new Exception(format("%s hackerscad windows are open (%s): say which one with 'window', "
                ~ "or ask the user (the name is in the header bar of each window)", open.length, open.join(", ")));
        window = open[0];
    }
    else if (!open.canFind(window))
        throw new Exception(open.length
            ? format("no hackerscad window named '%s'; open: %s", window, open.join(", "))
            : notRunning);

    auto sock = controlSocket();
    scope (exit)
        sock.close();
    try
        sock.connect(controlAddress(window));
    catch (SocketException)
        throw new Exception(format("the hackerscad window '%s' does not answer", window));
    sock.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(60));

    JSONValue req = ["method": method];
    req["params"] = params;
    auto line = req.toString(JSONOptions.doNotEscapeSlashes) ~ "\n";
    sock.send(line);

    char[] buf;
    char[4096] chunk;
    while (buf.indexOf('\n') < 0)
    {
        auto n = sock.receive(chunk[]);
        if (n <= 0)
            throw new Exception("no answer from hackerscad");
        buf ~= chunk[0 .. n];
    }
    auto resp = parseJSON(buf[0 .. buf.indexOf('\n')]);
    if (auto e = "error" in resp)
    {
        // a window started before its program was updated lacks the newest tools
        if (e.str == "unknown method: " ~ method)
            throw new Exception(format("the hackerscad window '%s' runs an older version without '%s': ask the user "
                ~ "to restart it", window, method));
        throw new Exception(e.str);
    }
    return resp["result"];
}

/// JSON parameter values → .hcad expressions: numbers are in the model
/// unit, strings are expressions, booleans are booleans.
string[string] toOverrides(JSONValue params)
{
    string[string] r;
    if (params.type != JSONType.object)
        return r;
    foreach (name, v; params.object)
    {
        switch (v.type)
        {
        case JSONType.string: r[name] = v.str; break;
        case JSONType.integer: r[name] = v.integer.to!string; break;
        case JSONType.uinteger: r[name] = v.uinteger.to!string; break;
        case JSONType.float_: r[name] = format("%.10g", v.floating); break;
        case JSONType.true_: r[name] = "true"; break;
        case JSONType.false_: r[name] = "false"; break;
        default: throw new Exception(format("parameter '%s': unsupported value %s", name, v));
        }
    }
    return r;
}

import core.time : dur;

unittest
{
    auto o = toOverrides(parseJSON(`{"w": 80, "h": "2.5.cm", "f": 1.5, "b": true}`));
    assert(o["w"] == "80" && o["h"] == "2.5.cm" && o["f"] == "1.5" && o["b"] == "true");

    assert(normalizeWindowName("  Benchy Hull! v2 ") == "benchy-hull-v2");
    assert(normalizeWindowName("***") is null);
    foreach (i; 0 .. 20)
    {
        auto n = randomWindowName();
        assert(normalizeWindowName(n) == n);
    }
}
