/// Readers for triangle mesh files: STL (binary and ASCII), OBJ and 3MF.
module hackerscad.io.meshread;

import std.algorithm : startsWith, endsWith;
import std.array : split;
import std.bitmanip : littleEndianToNative;
import std.conv : to, ConvException;
import std.string : strip, lineSplitter, indexOf;

import hackerscad.geom.mesh;

class MeshFormatException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

/// STL: binary when the size matches the triangle count, ASCII otherwise.
Mesh readStl(const(ubyte)[] data)
{
    if (data.length >= 84)
    {
        immutable n = littleEndianToNative!uint(data[80 .. 84][0 .. 4]);
        if (84 + cast(ulong) n * 50 == data.length)
            return binaryStl(data, n);
    }
    return asciiStl(cast(const(char)[]) data);
}

private Mesh binaryStl(const(ubyte)[] data, uint n)
{
    Mesh m;
    m.verts.reserve(n * 9);
    m.tris.reserve(n * 3);
    foreach (t; 0 .. n)
    {
        immutable o = 84 + t * 50 + 12; // skip the normal
        foreach (k; 0 .. 9)
            m.verts ~= littleEndianToNative!float(data[o + k * 4 .. o + k * 4 + 4][0 .. 4]);
        m.tris ~= [t * 3, t * 3 + 1, t * 3 + 2];
    }
    return m.welded;
}

private Mesh asciiStl(const(char)[] text)
{
    if (!text.strip.startsWith("solid"))
        throw new MeshFormatException("not an STL file");
    Mesh m;
    foreach (line; text.lineSplitter)
    {
        auto l = line.strip;
        if (!l.startsWith("vertex"))
            continue;
        auto parts = l.split;
        if (parts.length != 4)
            throw new MeshFormatException("malformed STL vertex: " ~ l.idup);
        try
            foreach (p; parts[1 .. 4])
                m.verts ~= p.to!float;
        catch (ConvException)
            throw new MeshFormatException("malformed STL vertex: " ~ l.idup);
    }
    if (m.verts.length % 9)
        throw new MeshFormatException("STL facets must have three vertices");
    foreach (t; 0 .. cast(uint)(m.verts.length / 9))
        m.tris ~= [t * 3, t * 3 + 1, t * 3 + 2];
    return m.welded;
}

/// Wavefront OBJ: vertices and faces (polygons are fanned into triangles).
Mesh readObj(const(char)[] text)
{
    Mesh m;
    foreach (line; text.lineSplitter)
    {
        auto l = line.strip;
        try
        {
            if (l.startsWith("v "))
            {
                auto p = l.split;
                if (p.length < 4)
                    throw new MeshFormatException("OBJ vertex with fewer than 3 coordinates: " ~ l.idup);
                foreach (c; p[1 .. 4])
                    m.verts ~= c.to!float;
            }
            else if (l.startsWith("f "))
            {
                uint[] idx;
                foreach (c; l.split[1 .. $])
                {
                    // "7", "7/1" or "7/1/3"; negative indices count from the end
                    auto slash = c.indexOf('/');
                    long i = (slash >= 0 ? c[0 .. slash] : c).to!long;
                    i = i < 0 ? cast(long)(m.verts.length / 3) + i : i - 1;
                    if (i < 0 || i >= m.verts.length / 3)
                        throw new MeshFormatException("OBJ face refers to a missing vertex");
                    idx ~= cast(uint) i;
                }
                if (idx.length < 3)
                    throw new MeshFormatException("OBJ face with fewer than 3 vertices: " ~ l.idup);
                foreach (k; 1 .. idx.length - 1)
                    m.tris ~= [idx[0], idx[k], idx[k + 1]];
            }
        }
        catch (ConvException)
            throw new MeshFormatException("malformed OBJ line: " ~ l.idup);
    }
    if (m.tris.length == 0)
        throw new MeshFormatException("the OBJ file has no faces");
    return m.welded;
}

/// 3MF: every build item (with its components and transforms) merged into
/// one mesh in millimetres. Objects in other model parts of the package
/// (production extension, `p:path`) are followed too.
Mesh read3mf(const(ubyte)[] data)
{
    auto zip = unzip(data);
    string[string] texts;   // model parts by path, without the leading '/'
    string part(string path)
    {
        if (path.length && path[0] == '/')
            path = path[1 .. $];
        if (auto t = path in texts)
            return *t;
        auto m = path in zip;
        if (!m)
            throw new MeshFormatException("the 3MF package has no part " ~ path);
        return texts[path] = (*m)();
    }

    // the root model is named in _rels/.rels; 3D/3dmodel.model by convention
    string rootPath = "3D/3dmodel.model";
    if (auto rels = "_rels/.rels" in zip)
        foreach (t; xmlTags((*rels)()))
            if (t.name == "Relationship" && !t.closing && t.attr("Type").endsWith("/3dmodel"))
                rootPath = t.attr("Target");
    immutable root = part(rootPath);

    double unit = 1;
    foreach (t; xmlTags(root))
        if (t.name == "model" && !t.closing)
        {
            switch (t.attr("unit", "millimeter"))
            {
            case "micron": unit = 0.001; break;
            case "millimeter": unit = 1; break;
            case "centimeter": unit = 10; break;
            case "inch": unit = 25.4; break;
            case "foot": unit = 304.8; break;
            case "meter": unit = 1000; break;
            default: throw new MeshFormatException("unknown 3MF unit " ~ t.attr("unit"));
            }
            break;
        }

    Mesh result;
    // adds object `id` of model part `path`, placed by the row-major 4x3 matrix `tr`
    void add(string path, string id, const double[12] tr, int depth)
    {
        if (depth > 16)
            throw new MeshFormatException("3MF components nest too deeply");
        auto tags = xmlTags(part(path));
        size_t i;
        while (i < tags.length && !(tags[i].name == "object" && !tags[i].closing && tags[i].attr("id") == id))
            i++;
        if (i == tags.length)
            throw new MeshFormatException("3MF object " ~ id ~ " not found");
        immutable base = cast(uint)(result.verts.length / 3);
        for (i++; i < tags.length && !(tags[i].name == "object" && tags[i].closing); i++)
        {
            auto t = tags[i];
            if (t.closing)
                continue;
            if (t.name == "vertex")
            {
                immutable x = t.num("x"), y = t.num("y"), z = t.num("z");
                foreach (c; 0 .. 3)
                    result.verts ~= cast(float)(x * tr[c] + y * tr[3 + c] + z * tr[6 + c] + tr[9 + c]);
            }
            else if (t.name == "triangle")
            {
                foreach (v; ["v1", "v2", "v3"])
                {
                    immutable k = base + cast(uint) t.num(v);
                    if (k >= result.verts.length / 3)
                        throw new MeshFormatException("3MF triangle refers to a missing vertex");
                    result.tris ~= k;
                }
            }
            else if (t.name == "component")
            {
                auto sub = t.attr("p:path", path);
                add(sub, t.attr("objectid"), compose(matrix(t.attr("transform")), tr), depth + 1);
            }
        }
    }

    double[12] scale = [unit, 0, 0, 0, unit, 0, 0, 0, unit, 0, 0, 0];
    foreach (t; xmlTags(root))
        if (t.name == "item" && !t.closing)
            add(t.attr("p:path", rootPath), t.attr("objectid"), compose(matrix(t.attr("transform")), scale), 0);
    if (result.tris.length == 0)
        throw new MeshFormatException("the 3MF file has no triangles");
    return result.welded;
}

/// The members of a zip archive (with Zip64, as 3MF writers often use it),
/// each read and inflated on demand.
private string delegate()[string] unzip(const(ubyte)[] d)
{
    void check(ulong end)
    {
        if (end > d.length)
            throw new MeshFormatException("the 3MF zip archive is truncated");
    }
    ulong u16(size_t o) { check(o + 2); return d[o] | d[o + 1] << 8; }
    ulong u32(size_t o) { check(o + 4); return u16(o) | u16(o + 2) << 16; }
    ulong u64(size_t o) { return u32(o) | u32(o + 4) << 32; }

    // end of central directory: the last record, possibly followed by a comment
    if (d.length < 22)
        throw new MeshFormatException("not a 3MF file (not a zip archive)");
    long eocd = -1;
    foreach_reverse (o; 0 .. d.length - 21)
        if (u32(o) == 0x06054b50)
        {
            eocd = o;
            break;
        }
    if (eocd < 0)
        throw new MeshFormatException("not a 3MF file (not a zip archive)");
    ulong count = u16(eocd + 10), cd = u32(eocd + 16);
    if (eocd >= 20 && u32(eocd - 20) == 0x07064b50)   // Zip64 locator
    {
        immutable z = u64(eocd - 12);
        if (u32(z) != 0x06064b50)
            throw new MeshFormatException("malformed Zip64 record in the 3MF file");
        count = u64(z + 32);
        cd = u64(z + 48);
    }

    string delegate()[string] members;
    foreach (_; 0 .. count)
    {
        if (u32(cd) != 0x02014b50)
            throw new MeshFormatException("malformed zip directory in the 3MF file");
        immutable method = u16(cd + 10);
        ulong packed = u32(cd + 20), size = u32(cd + 24), local = u32(cd + 42);
        immutable nameLen = u16(cd + 28), extraLen = u16(cd + 30), commentLen = u16(cd + 32);
        check(cd + 46 + nameLen);
        auto name = (cast(const(char)[]) d[cd + 46 .. cd + 46 + nameLen]).idup;
        // Zip64 extra field: only the values that overflowed, in this order
        for (size_t e = cd + 46 + nameLen; e + 4 <= cd + 46 + nameLen + extraLen; e += 4 + u16(e + 2))
            if (u16(e) == 1)
            {
                size_t f = e + 4;
                if (size == uint.max) { size = u64(f); f += 8; }
                if (packed == uint.max) { packed = u64(f); f += 8; }
                if (local == uint.max) local = u64(f);
            }
        cd += 46 + nameLen + extraLen + commentLen;

        members[name] = member(d, name, method, packed, size, local);
    }
    return members;
}

/// Reads and inflates one zip member (a function of its own, so that each
/// closure keeps its own copy of the values).
private string delegate() member(const(ubyte)[] d, string name, ulong method, ulong packed, ulong size, ulong local)
{
    import std.zlib : uncompress, ZlibException;

    return () {
        ulong u16(size_t o) { return d[o] | d[o + 1] << 8; }
        ulong u32(size_t o) { return u16(o) | u16(o + 2) << 16; }
        if (local + 30 > d.length)
            throw new MeshFormatException("the 3MF zip archive is truncated");
        if (u32(local) != 0x04034b50)
            throw new MeshFormatException("malformed zip entry " ~ name ~ " in the 3MF file");
        immutable start = local + 30 + u16(local + 26) + u16(local + 28);
        if (start + packed > d.length)
            throw new MeshFormatException("the 3MF zip archive is truncated");
        auto raw = d[start .. start + packed];
        if (method == 0)
            return (cast(const(char)[]) raw).idup;
        if (method != 8)
            throw new MeshFormatException("unsupported compression in the 3MF file");
        try
            return cast(string) uncompress(raw, cast(size_t) size, -15);
        catch (ZlibException)
            throw new MeshFormatException("corrupt zip entry " ~ name ~ " in the 3MF file");
    };
}

/// "m00 m01 m02 m10 … m32" (identity when empty)
private double[12] matrix(string s)
{
    double[12] m = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0];
    if (s.strip.length == 0)
        return m;
    auto p = s.split;
    if (p.length != 12)
        throw new MeshFormatException("malformed 3MF transform: " ~ s);
    try
        foreach (k; 0 .. 12)
            m[k] = p[k].to!double;
    catch (ConvException)
        throw new MeshFormatException("malformed 3MF transform: " ~ s);
    return m;
}

/// a then b (points are row vectors: p * a * b)
private double[12] compose(const double[12] a, const double[12] b)
{
    double[12] r;
    foreach (row; 0 .. 4)
        foreach (c; 0 .. 3)
            r[row * 3 + c] = a[row * 3] * b[c] + a[row * 3 + 1] * b[3 + c] + a[row * 3 + 2] * b[6 + c]
                + (row == 3 ? b[9 + c] : 0);
    return r;
}

/// Just enough XML for 3MF: start/end tags with their attributes.
private struct XmlTag
{
    string name;
    bool closing;
    string[string] attrs;

    string attr(string key, string fallback = "") const
    {
        auto v = key in attrs;
        return v ? *v : fallback;
    }

    double num(string key) const
    {
        auto v = key in attrs;
        if (!v)
            throw new MeshFormatException("3MF <" ~ name ~ "> has no " ~ key);
        try
            return (*v).to!double;
        catch (ConvException)
            throw new MeshFormatException("malformed 3MF number: " ~ *v);
    }
}

private XmlTag[] xmlTags(string s)
{
    import std.ascii : isWhite;

    XmlTag[] tags;
    size_t i;
    while (true)
    {
        immutable lt = s.indexOf('<', i);
        if (lt < 0)
            break;
        immutable gt = s.indexOf('>', lt);
        if (gt < 0)
            break;
        auto body = s[lt + 1 .. gt];
        i = gt + 1;
        if (body.length == 0 || body[0] == '?' || body[0] == '!')
            continue;
        XmlTag t;
        if (body[0] == '/')
        {
            t.closing = true;
            t.name = body[1 .. $].strip;
            tags ~= t;
            continue;
        }
        immutable selfClosing = body[$ - 1] == '/';
        if (selfClosing)
            body = body[0 .. $ - 1];
        size_t j;
        while (j < body.length && !isWhite(body[j]))
            j++;
        t.name = body[0 .. j];
        while (true)
        {
            immutable eq = body.indexOf('=', j);
            if (eq < 0)
                break;
            auto key = body[j .. eq].strip;
            size_t q0 = eq + 1;
            while (q0 < body.length && isWhite(body[q0]))
                q0++;
            immutable q1 = q0 < body.length ? body.indexOf(body[q0], q0 + 1) : -1;
            if (q1 < 0 || (body[q0] != '"' && body[q0] != '\''))
                throw new MeshFormatException("malformed XML in the 3MF file");
            t.attrs[key] = body[q0 + 1 .. q1];
            j = q1 + 1;
        }
        tags ~= t;
        if (selfClosing)
            tags ~= XmlTag(t.name, true);
    }
    return tags;
}

unittest
{
    import hackerscad.io.stl : toStl;

    // a tetrahedron written as binary STL comes back closed
    float[] p = [0, 0, 0, 10, 0, 0, 0, 10, 0, 0, 0, 10];
    Mesh m;
    m.verts = p;
    m.tris = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3];
    auto back = readStl(toStl(m));
    assert(back.vertexCount == 4 && back.triangleCount == 4 && back.isClosed);

    auto ascii = readStl(cast(ubyte[]) "solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid t\n");
    assert(ascii.triangleCount == 1);

    auto obj = readObj("v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n");
    assert(obj.triangleCount == 2);

    // a 3MF written by hackerscad comes back, scaled by the unit and the item transform
    import hackerscad.io.threemf : to3mf, Part;
    auto three = read3mf(to3mf([Part("t", m)]));
    assert(three.vertexCount == 4 && three.isClosed);
    import std.zip : ZipArchive, ArchiveMember;
    auto zip = new ZipArchive;
    void put(string name, string text)
    {
        auto am = new ArchiveMember;
        am.name = name;
        am.expandedData = cast(ubyte[]) text.dup;
        zip.addMember(am);
    }
    put("3D/3dmodel.model", `<?xml version="1.0"?><model unit="centimeter"><resources>`
        ~ `<object id="1"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/>`
        ~ `<vertex x="0" y="1" z="0"/><vertex x="0" y="0" z="1"/></vertices><triangles>`
        ~ `<triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/><triangle v1="0" v2="3" v3="2"/>`
        ~ `<triangle v1="1" v2="2" v3="3"/></triangles></mesh></object>`
        ~ `<object id="2"><components><component objectid="1" transform="2 0 0 0 2 0 0 0 2 0 0 0"/></components></object>`
        ~ `</resources><build><item objectid="2" transform="1 0 0 0 1 0 0 0 1 5 0 0"/></build></model>`);
    auto scaled = read3mf(cast(ubyte[]) zip.build());
    assert(scaled.isClosed);
    import std.algorithm : maxElement;
    assert(scaled.verts.maxElement == 70);   // (1 cm * 2 + 5 cm) in mm

    import std.exception : assertThrown;
    assertThrown!MeshFormatException(readStl(cast(ubyte[]) "hello"));
    assertThrown!MeshFormatException(read3mf(cast(ubyte[]) "hello"));
}

unittest
{
    // short lines are format errors, not crashes
    import std.exception : assertThrown;
    assertThrown!MeshFormatException(readObj("v 0 0\nf 1 1 1\n"));
    assertThrown!MeshFormatException(readObj("v 0 0 0\nv 1 0 0\nf 1 2\n"));
    assertThrown!MeshFormatException(readObj("v 0 0 0\nf\n"));
}
