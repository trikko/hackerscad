/// Names as numbers: each name the interpreter meets (a variable, a function, a builtin) is given one
/// once, and scopes find their bindings by that number instead of hashing the name's text in every
/// scope on the way out to the builtins.
module hackerscad.lang.symbols;

import core.sync.mutex : Mutex;

/// A name's number.
alias Sym = uint;

/// No name yet (a tree node whose name was not looked up).
enum Sym noSym = uint.max;

private __gshared Mutex lock;
private __gshared Sym[string] ids;
private __gshared string[] names;

shared static this()
{
    lock = new Mutex;
}

/// The number of `name`, the same for every interpreter and thread.
Sym intern(string name)
{
    lock.lock();
    scope (exit)
        lock.unlock();
    if (auto p = name in ids)
        return *p;
    immutable id = cast(Sym) names.length;
    names ~= name;
    ids[name] = id;
    return id;
}

/// The name a number stands for.
string nameOf(Sym s)
{
    lock.lock();
    scope (exit)
        lock.unlock();
    return names[s];
}

/// How many names have a number: every number is below it.
Sym symbolCount()
{
    lock.lock();
    scope (exit)
        lock.unlock();
    return cast(Sym) names.length;
}

unittest
{
    immutable a = intern("symbols_test_a"), b = intern("symbols_test_b");
    assert(a != b && intern("symbols_test_a") == a && nameOf(b) == "symbols_test_b" && symbolCount() > b);
}
