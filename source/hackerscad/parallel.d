/// How many threads the heavy work uses: OpenCascade's booleans and meshing
/// (its thread pool) and hackerscad's own (the views of a picture drawn side
/// by side). Every CPU unless set: `--threads N` on the command line, or the
/// environment variable HCAD_THREADS (the window and the MCP server too).
module hackerscad.parallel;

import core.atomic : atomicLoad, atomicStore;

private shared uint chosen;

/// The threads in use: what was set, else every CPU.
uint threadCount()
{
    immutable n = atomicLoad(chosen);
    if (n > 0)
        return n;
    import std.parallelism : totalCPUs;
    return totalCPUs;
}

/// Sets the threads for everything that runs in parallel (at least 1).
void setThreads(uint n)
{
    import std.parallelism : defaultPoolThreads;
    import hackerscad.kernel.occt.c : hc_set_threads;
    if (n < 1)
        n = 1;
    atomicStore(chosen, n);
    // the calling thread works too: the pool has one fewer
    defaultPoolThreads = n - 1;
    hc_set_threads(cast(int) n);
}

/// The setting from the arguments (`--threads N` or `--threads=N`, taken out
/// of them) or from HCAD_THREADS, applied; an error message when it is not a
/// number of 1 or more, else null.
string threadsFromArgs(ref string[] args)
{
    import std.conv : to, ConvException;
    import std.process : environment;
    import std.algorithm : startsWith;
    string value = environment.get("HCAD_THREADS");
    string[] rest;
    for (size_t i = 0; i < args.length; i++)
    {
        if (args[i] == "--threads" && i + 1 < args.length)
            value = args[++i];
        else if (args[i].startsWith("--threads="))
            value = args[i]["--threads=".length .. $];
        else
            rest ~= args[i];
    }
    args = rest;
    if (value.length == 0)
    {
        setThreads(threadCount());
        return null;
    }
    try
    {
        immutable n = value.to!uint;
        if (n < 1)
            return "--threads (or HCAD_THREADS) is a number of 1 or more";
        setThreads(n);
        return null;
    }
    catch (ConvException)
        return "--threads (or HCAD_THREADS) is a number of 1 or more, not '" ~ value ~ "'";
}

unittest
{
    immutable before = threadCount();
    scope (exit)
        setThreads(before);
    string[] a = ["hcad", "render", "--threads", "3", "x.hcad"];
    assert(threadsFromArgs(a) is null && a == ["hcad", "render", "x.hcad"] && threadCount() == 3);
    a = ["hcad", "--threads=0"];
    assert(threadsFromArgs(a) !is null);
    a = ["hcad"];
    setThreads(0);
    assert(threadCount() == 1);
}
