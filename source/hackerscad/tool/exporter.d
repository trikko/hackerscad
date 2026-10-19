/// Writing parts to files, for the command line, the MCP server and the
/// window alike: the format comes from the extension.
///
/// - .3mf: one file, one object per part, with names and colours;
/// - .stl: one part (STL has no way to keep bodies apart);
/// - .zip: one STL per part, named like the parts;
/// - .step/.stp: one file, each part a separate, named body.
module hackerscad.tool.exporter;

import std.algorithm : canFind, map;
import std.array : array, join;
import std.file : write;
import std.format : format;
import std.path : extension;
import std.uni : toLower;

import hackerscad.geom.mesh;
import hackerscad.io.stl : toStl;
import hackerscad.io.threemf : Part, write3mf;
import hackerscad.kernel.brep : Brep, BrepKernel;

/// A part as the exporters take it.
struct ExportPart
{
    string name;   /// @part(name:) or the function's name
    Mesh mesh;     /// welded and closed
    uint rgb;
    Brep brep;
    string[] tags;          /// the part's own (addTag)
    string[][] faceTags;    /// per face of brep (the mesh's faceStart follows the same faces)
}

/// The extensions export takes for solids (PNG and drawings are written
/// elsewhere).
immutable string[] solidFormats = [".3mf", ".stl", ".zip", ".step", ".stp"];

/// Thrown for what the caller can fix: a format, several parts in one STL.
class ExportException : Exception
{
    this(string msg) { super(msg); }
}

/// Edges where a welded mesh is not a plain surface: shared by more than two
/// triangles, as where two bodies of a part touch only along an edge or at a
/// corner. Slicers often mend such a mesh wrongly.
size_t nonManifoldEdges(const Mesh m)
{
    uint[ulong] uses;
    foreach (t; 0 .. m.tris.length / 3)
        foreach (i; 0 .. 3)
        {
            uint a = m.tris[t * 3 + i], b = m.tris[t * 3 + (i + 1) % 3];
            if (a > b)
            {
                immutable c = a;
                a = b;
                b = c;
            }
            uses[(cast(ulong) a << 32) | b]++;
        }
    size_t n;
    foreach (c; uses)
        n += c > 2;
    return n;
}

/// Writes `parts` (at least one) to `file`. With `assembly` (a name), a
/// 3MF holds them as the pieces of one object of that name (prints in
/// several colours or materials).
string[] exportParts(string file, ExportPart[] parts, BrepKernel kernel, string assembly = null)
{
    assert(parts.length > 0);
    // what the file will hold that a printer may not like
    string[] warnings;
    if ([".3mf", ".stl", ".zip"].canFind(extension(file).toLower))
        foreach (p; parts)
            if (immutable n = nonManifoldEdges(p.mesh))
                warnings ~= format("part '%s' has %d edge%s shared by more than two faces: bodies touching only along an "
                    ~ "edge or at a corner; overlap them a little (or keep them apart) so the mesh prints as meant",
                    p.name, n, n > 1 ? "s" : "");
    switch (extension(file).toLower)
    {
    case ".3mf":
        write3mf(parts.map!(p => Part(p.name, p.mesh, p.rgb, p.tags, p.faceTags)).array, file, assembly);
        break;
    case ".stl":
        if (parts.length > 1)
            throw new ExportException(format("%d parts (%s) do not fit one STL: export a .zip, one STL each, "
                ~ "or a .3mf, or choose one part", parts.length, parts.map!(p => p.name).join(", ")));
        write(file, toStl(parts[0].mesh));
        break;
    case ".zip":
        write(file, stlZip(parts));
        break;
    case ".step", ".stp":
        {
            // each face its tags, as its name
            import hackerscad.about : madeWith, madeWithNote;
            string[][] names;
            foreach (p; parts)
                names ~= p.faceTags.map!(t => t.join(";")).array;
            kernel.writeStep(parts.map!(p => p.brep).array, parts.map!(p => p.name).array, file, names, madeWith, madeWithNote);
        }
        break;
    default:
        throw new ExportException(format("unsupported output format '%s' (use %s)", extension(file),
            solidFormats.join(", ")));
    }
    return warnings;
}

/// A zip with one binary STL per part, `name.stl`.
ubyte[] stlZip(const ExportPart[] parts)
{
    import std.datetime.systime : Clock;
    import std.zip : ArchiveMember, CompressionMethod, ZipArchive;
    import hackerscad.about : madeWithNote;
    auto zip = new ZipArchive;
    zip.comment = madeWithNote;
    immutable now = Clock.currTime;
    foreach (i, name; fileNames(parts.map!(p => p.name).array))
    {
        auto m = new ArchiveMember;
        m.name = name ~ ".stl";
        m.time = now;
        m.expandedData = toStl(parts[i].mesh);
        m.compressionMethod = CompressionMethod.deflate;
        zip.addMember(m);
    }
    return cast(ubyte[]) zip.build();
}

/// Part names made into file names: no characters that systems refuse,
/// and no two alike (a number added to the later ones).
string[] fileNames(const string[] names)
{
    string[] r;
    foreach (n; names)
    {
        string safe;
        foreach (dchar c; n)
            safe ~= c < 32 || `/\:*?"<>|`.canFind(c) ? '_' : c;
        if (safe.length == 0 || safe == "." || safe == "..")
            safe = "part";
        auto name = safe;
        for (int k = 2; r.canFind!(x => x.toLower == name.toLower); k++)
            name = format("%s-%d", safe, k);
        r ~= name;
    }
    return r;
}

unittest
{
    assert(fileNames(["tank", "pot", "a/b", "Pot", ""]) == ["tank", "pot", "a_b", "Pot-2", "part"]);
}

unittest
{
    import std.zip : ZipArchive;
    Mesh m;
    m.verts = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1];
    m.tris = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3];
    auto zip = new ZipArchive(stlZip([ExportPart("tank", m), ExportPart("pot", m)]));
    assert("tank.stl" in zip.directory && "pot.stl" in zip.directory);
    assert(zip.expand(zip.directory["pot.stl"]).length == 84 + 4 * 50);
}
