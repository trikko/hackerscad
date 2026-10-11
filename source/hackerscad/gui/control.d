/// Listens on the control socket and runs requests on the GTK main thread.
module hackerscad.gui.control;

import core.atomic : atomicLoad, atomicStore;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : msecs;
import std.file : exists, remove;
import std.json;
import std.socket;
import std.string : indexOf;

import glib.global : idleAdd;
import glib.types : PRIORITY_DEFAULT;

import hackerscad.tool.guiclient : socketPath, controlSocket, controlAddress;

/// Called on the main thread; must eventually call `reply` exactly once.
alias Handler = void delegate(string method, JSONValue params, void delegate(JSONValue result, string error) reply);

final class ControlServer
{
    private Handler handler;
    private Socket listener;
    private Thread thread;
    private shared bool stopping;
    private string path;

    /// Starts listening; returns false if another window owns the socket.
    bool start(Handler h)
    {
        handler = h;
        path = socketPath();
        if (exists(path))
        {
            // a live owner answers connections; a stale file is removed
            try
            {
                auto probe = controlSocket();
                scope (exit)
                    probe.close();
                probe.connect(controlAddress());
                return false;
            }
            catch (SocketException)
                remove(path);
        }
        listener = controlSocket();
        version (Windows)
        {
            // no Unix sockets: a port chosen by the system, written where clients look
            import std.conv : to;
            import std.file : mkdirRecurse, write;
            import std.path : dirName;
            listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
            mkdirRecurse(dirName(path));
            write(path, listener.localAddress.toPortString);
        }
        else
            listener.bind(new UnixAddress(path));
        listener.listen(4);
        thread = new Thread(&acceptLoop);
        thread.isDaemon = true;
        thread.start();
        return true;
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
    }

    private void acceptLoop()
    {
        auto set = new SocketSet;
        while (!atomicLoad(stopping))
        {
            set.reset();
            set.add(listener);
            if (Socket.select(set, null, null, 200.msecs) <= 0)
                continue;
            Socket client;
            try
                client = listener.accept();
            catch (SocketException)
                continue;
            serveClient(client);
        }
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

        JSONValue response;
        try
        {
            auto req = parseJSON(buf[0 .. buf.indexOf('\n')]);
            auto method = req["method"].str;
            auto params = "params" in req ? req["params"] : JSONValue((JSONValue[string]).init);

            // run on the GTK thread and wait for the answer
            auto done = new Semaphore(0);
            JSONValue result;
            string error;
            idleAdd(PRIORITY_DEFAULT, () {
                try
                    handler(method, params, (JSONValue r, string e) {
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
                response = JSONValue(["error": error]);
            else
                response = JSONValue(["result": result]);
        }
        catch (Exception e)
            response = JSONValue(["error": e.msg]);
        client.send(response.toString(JSONOptions.doNotEscapeSlashes) ~ "\n");
    }
}
