/// The models of the Examples menu: every examples/NN_name.hcad, in the
/// order of their numbers, built into the program. The first line of each
/// is a comment, "// Label: what it shows", the menu's entry.
/// tools/examples-list.sh lists the files before each build.
module hackerscad.examples;

/// An example: name (the file's, without number and extension, as the
/// window and agents call it), label, what it shows, source.
struct Example
{
    string name, label, what, source;
}

/// The example of `file` (NN_name.hcad) with code `source`.
Example example(string file, string source)
{
    import std.algorithm : findSplit, findSplitBefore, skipOver;
    import std.string : strip;
    Example e;
    e.name = file[3 .. $ - ".hcad".length];
    e.source = source;
    auto first = source.findSplitBefore("\n")[0].strip;
    first.skipOver("//") || first.skipOver("/+") || first.skipOver("/*");
    first.skipOver("/");
    auto s = first.strip.findSplit(": ");
    e.label = s[0].strip;
    e.what = s[2].strip;
    return e;
}

private enum files = () {
    import std.algorithm : filter, map;
    import std.array : array, split;
    import std.string : strip;
    return import("examples.txt").split("\n").map!strip.filter!(f => f.length).array;
}();

/// All of them, in order.
static immutable Example[] examples = () {
    Example[] r;
    static foreach (f; files)
        r ~= example(f, import(f));
    return r;
}();

/// Their names, for messages: "carlo, cup or language".
string exampleNames()
{
    import std.algorithm : map;
    import std.array : array, join;
    auto n = examples.map!(e => e.name).array;
    return n.length < 2 ? n.join : n[0 .. $ - 1].join(", ") ~ " or " ~ n[$ - 1];
}

unittest
{
    auto e = example("03_tour.hcad", "// Language tour: if, for: each once\nmodule tour;\n");
    assert(e.name == "tour" && e.label == "Language tour" && e.what == "if, for: each once");
    assert(example("00_x.hcad", "/// Plain\n").label == "Plain");
    assert(examples.length >= 4 && examples[0].name == "carlo");
}
