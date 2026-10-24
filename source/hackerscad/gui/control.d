/// Listens on the control socket and runs requests on the GTK main thread.
module hackerscad.gui.control;

import core.atomic : atomicLoad, atomicStore;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : msecs;
import std.file : exists, remove;
import djson;
import std.socket;
import std.conv : octal;
import std.string : indexOf;

import glib.global : idleAdd;
import glib.types : PRIORITY_DEFAULT;

import hackerscad.tool.guiclient : socketPath, controlDir, controlSocket, windowAlive, normalizeWindowName,
    randomWindowName, removeStaleChannels;

/// Called on the main thread; must eventually call `reply` exactly once. `client` is who sent the
/// request, as its MCP server tells (the agent's name and version, "codex 0.48"), empty when not said.
alias Handler = void delegate(string method, JValue params, string client,
    void delegate(JValue result, string error) reply);

/// The control channel of one window, under a name agents use to tell the
/// windows apart: random at start, the user can change it.
final class ControlServer
{
    private Handler handler;
    private Socket listener;
    private Thread thread;
    private shared bool stopping;
    private string path;
    private string name_;
    private Socket next;     // a renamed channel, taken over by the accept loop (under `this`)
    private string nextPath;

    string name() const => name_;

    /// Starts listening under the name `wanted` when it is free and usable,
    /// otherwise under a free random one.
    bool start(Handler h, string wanted = null)
    {
        handler = h;
        removeStaleChannels();
        if (wanted.length)
        {
            auto n = normalizeWindowName(wanted);
            string why = n is null ? "use letters, digits and dashes" : windowAlive(n) ? "another window has it" : null;
            if (why is null)
                try
                {
                    listener = bindAs(n);
                    name_ = n;
                    path = socketPath(n);
                    thread = new Thread(&acceptLoop);
                    thread.isDaemon = true;
                    thread.start();
                    return true;
                }
                catch (Exception e)
                    why = e.msg;
            import std.stdio : stderr;
            try
                stderr.writeln("hackerscad: cannot name the window '", wanted, "' (", why, "): a random name instead");
            catch (Exception)
            {
            }
        }
        foreach (attempt; 0 .. 50)
        {
            auto candidate = randomWindowName();
            if (attempt >= 25)
            {
                import std.conv : to;
                import std.random : uniform;
                candidate ~= "-" ~ uniform(2, 100).to!string;
            }
            if (windowAlive(candidate))
                continue;
            try
                listener = bindAs(candidate);
            catch (Exception)
                continue;
            name_ = candidate;
            path = socketPath(candidate);
            thread = new Thread(&acceptLoop);
            thread.isDaemon = true;
            thread.start();
            return true;
        }
        return false;
    }

    /// Renames the window; returns why it cannot, or null.
    string rename(string wanted)
    {
        auto n = normalizeWindowName(wanted);
        if (n is null)
            return "use letters, digits and dashes";
        if (n == name_)
            return null;
        if (windowAlive(n))
            return "another window is called " ~ n;
        Socket s;
        try
            s = bindAs(n);
        catch (Exception e)
            return e.msg;
        synchronized (this)
        {
            if (next !is null)
                next.close();
            next = s;
            nextPath = socketPath(n);
        }
        name_ = n;
        return null;
    }

    /// Stops the listener thread before closing the socket: closing it under
    /// a blocked accept() would raise an exception while the runtime shuts down.
    void stop()
    {
        if (listener is null)
            return;
        atomicStore(stopping, true);
        thread.join();
        listener.close();
        listener = null;
        if (exists(path))
            remove(path);
        synchronized (this)
            if (next !is null)
            {
                next.close();
                if (exists(nextPath))
                    remove(nextPath);
                next = null;
            }
    }

    /// A listening socket for `window`; a stale file of a dead window is replaced.
    private static Socket bindAs(string window)
    {
        import std.file : mkdirRecurse;
        auto dir = controlDir();
        mkdirRecurse(dir);
        version (Posix)
        {
            // only this user may drive the windows
            import std.file : setAttributes;
            setAttributes(dir, octal!700);
        }
        auto file = socketPath(window);
        if (exists(file))
            remove(file);
        auto s = controlSocket();
        version (Windows)
        {
            // no Unix sockets: a port chosen by the system, written where clients look
            import std.file : write;
            s.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
            s.listen(4);
            write(file, s.localAddress.toPortString);
        }
        else
        {
            s.bind(new UnixAddress(file));
            s.listen(4);
        }
        return s;
    }

    private void acceptLoop()
    {
        auto set = new SocketSet;
        while (!atomicLoad(stopping))
        {
            synchronized (this)
                if (next !is null)
                {
                    // renamed: the old name goes away, the new one is in use
                    listener.close();
                    if (exists(path))
                        remove(path);
                    listener = next;
                    path = nextPath;
                    next = null;
                }
            set.reset();
            set.add(listener);
            if (Socket.select(set, null, null, 200.msecs) <= 0)
                continue;
            Socket client;
            try
                client = listener.accept();
            catch (SocketException)
                continue;
            // each client in a thread of its own: a request waiting for an evaluation (set, edit) held the
            // others behind it, the stop that would end that evaluation among them. The requests still run one
            // at a time, on the GTK thread
            serveApart(client);
        }
    }

    /// serveClient in a thread; a function of its own, so that each thread has its own `client` (a closure
    /// made in the accept loop would share the loop's variable with the next client)
    private void serveApart(Socket client)
    {
        auto t = new Thread(() => serveClient(client));
        t.isDaemon = true;
        t.start();
    }

    private void serveClient(Socket client)
    {
        scope (exit)
            client.close();
        char[] buf;
        char[4096] chunk;
        while (buf.indexOf('\n') < 0)
        {
            auto n = client.receive(chunk[]);
            if (n <= 0)
                return;
            buf ~= chunk[0 .. n];
        }

        JValue response;
        try
        {
            auto req = parseJSONComplete(buf[0 .. buf.indexOf('\n')]);
            auto method = req["method"].get!string;
            auto params = req.has("params") ? req["params"] : JSOB();
            auto sender = req.has("client") ? req["client"].get!string : "";

            // run on the GTK thread and wait for the answer
            auto done = new Semaphore(0);
            JValue result;
            string error;
            idleAdd(PRIORITY_DEFAULT, () {
                try
                    handler(method, params, sender, (JValue r, string e) {
                        result = r;
                        error = e;
                        done.notify();
                    });
                catch (Exception e)
                {
                    error = e.msg;
                    done.notify();
                }
                return false;
            });
            done.wait();
            if (error.length)
                response = JSOB("error", error);
            else
                response = JSOB("result", result);
        }
        catch (Exception e)
            response = JSOB("error", e.msg);
        client.send(response.toJSON() ~ "\n");
    }
}
