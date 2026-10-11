/// Control channel of the desktop application: a Unix socket (on Windows a
/// TCP port on 127.0.0.1, written in a file) speaking one JSON object per
/// line. `hscad-gui` listens; the MCP server and scripts connect.
module hackerscad.tool.guiclient;

import std.conv : to;
import std.format : format;
import std.json;
import std.path : buildPath;
import std.process : environment;
import std.socket;
import std.string : indexOf;

/// $XDG_RUNTIME_DIR/hackerscad-gui.sock (or $TMPDIR/hackerscad-gui-$USER.sock);
/// on Windows %LOCALAPPDATA%\hackerscad\gui.port, the file holding the port.
string socketPath()
{
    version (Windows)
        return buildPath(environment.get("LOCALAPPDATA", environment.get("TEMP", ".")), "hackerscad", "gui.port");
    else
    {
        auto dir = environment.get("XDG_RUNTIME_DIR");
        if (dir.length)
            return buildPath(dir, "hackerscad-gui.sock");
        return buildPath(environment.get("TMPDIR", "/tmp"), "hackerscad-gui-" ~ environment.get("USER", "user") ~ ".sock");
    }
}

/// A socket of the right family for the control channel.
Socket controlSocket()
{
    version (Windows)
        return new Socket(AddressFamily.INET, SocketType.STREAM);
    else
        return new Socket(AddressFamily.UNIX, SocketType.STREAM);
}

/// The address the GUI listens on (throws if it is not running).
Address controlAddress()
{
    version (Windows)
    {
        import std.file : readText;
        import std.string : strip;
        try
            return new InternetAddress("127.0.0.1", readText(socketPath()).strip.to!ushort);
        catch (Exception)
            throw new SocketException("no port file");
    }
    else
        return new UnixAddress(socketPath());
}

/// Sends {"method": …, "params": …} and returns the "result" member.
JSONValue guiRequest(string method, JSONValue params)
{
    auto sock = controlSocket();
    scope (exit)
        sock.close();
    try
        sock.connect(controlAddress());
    catch (SocketException)
        throw new Exception("hackerscad is not running: start it with `hscad-gui model.hcad`");
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
        throw new Exception(e.str);
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
}
