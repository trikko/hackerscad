/// Readers for triangle mesh files: STL (binary and ASCII), OBJ, PLY, 3MF
/// and glTF (.glb, .gltf).
module hackerscad.io.meshread;

import std.algorithm : startsWith, endsWith, max;
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

/// Why a mesh read is not closed, in words: its edges with one triangle
/// (holes), those with more than two (where the surface touches itself) and
/// its triangles doubled facing the other way (walls of no thickness).
/// `mendable`: there are of the last two kinds, what Mesh.repaired mends.
string openness(const Mesh m, out bool mendable)
{
    import std.format : format;
    import std.algorithm : sort;

    uint[ulong] uses;   // undirected edges: how many triangles
    uint[3][] faces;    // each triangle's vertices, sorted, to find the doubled
    foreach (t; 0 .. m.triangleCount)
    {
        uint[3] v = [m.tris[t * 3], m.tris[t * 3 + 1], m.tris[t * 3 + 2]];
        foreach (k; 0 .. 3)
        {
            immutable a = v[k], b = v[(k + 1) % 3];
            uses[a < b ? cast(ulong) a << 32 | b : cast(ulong) b << 32 | a]++;
        }
        v[].sort;
        faces ~= v;
    }
    size_t holes, touching, doubled;
    foreach (n; uses)
        if (n == 1)
            holes++;
        else if (n > 2)
            touching++;
    faces.sort;
    foreach (i; 1 .. faces.length)
        if (faces[i] == faces[i - 1])
            doubled++;
    mendable = touching || doubled;
    string[] what;
    if (holes)
        what ~= format("%s edges of holes", holes);
    if (touching)
        what ~= format("%s edges where the surface touches itself (more than two triangles)", touching);
    if (doubled)
        what ~= format("%s triangles doubled (walls of no thickness)", doubled);
    if (what.length == 0)
        return "triangles facing the wrong way";
    import std.array : join;
    return what.join(", ");
}

/// PLY (ASCII or binary, as scanners write it): its vertices' x, y, z and
/// its faces (polygons fanned into triangles), in mm as STL.
Mesh readPly(const(ubyte)[] data)
{
    import std.algorithm : countUntil;
    import std.bitmanip : bigEndianToNative;

    // the header: lines up to "end_header"
    size_t at;
    string line()
    {
        immutable nl = (cast(const(char)[]) data[at .. $]).indexOf('\n');
        if (nl < 0)
            throw new MeshFormatException("the PLY header has no end_header");
        auto l = (cast(const(char)[]) data[at .. at + nl]).strip.idup;
        at += nl + 1;
        return l;
    }
    if (data.length < 4 || cast(const(char)[]) data[0 .. 3] != "ply")
        throw new MeshFormatException("not a PLY file");
    line();
    struct Property { string name, type, countType; }   // countType: a list's
    struct Element { string name; size_t count; Property[] props; }
    Element[] elements;
    string format;
    for (auto l = line(); l != "end_header"; l = line())
    {
        auto w = l.split;
        if (w.length == 0 || w[0] == "comment" || w[0] == "obj_info")
            continue;
        try
        {
            if (w[0] == "format" && w.length >= 2)
                format = w[1];
            else if (w[0] == "element" && w.length == 3)
                elements ~= Element(w[1], w[2].to!size_t);
            else if (w[0] == "property" && elements.length && w.length == 3)
                elements[$ - 1].props ~= Property(w[2], w[1]);
            else if (w[0] == "property" && elements.length && w.length == 5 && w[1] == "list")
                elements[$ - 1].props ~= Property(w[4], w[3], w[2]);
            else
                throw new MeshFormatException("malformed PLY header line: " ~ l);
        }
        catch (ConvException)
            throw new MeshFormatException("malformed PLY header line: " ~ l);
    }
    if (format != "ascii" && format != "binary_little_endian" && format != "binary_big_endian")
        throw new MeshFormatException("unknown PLY format " ~ format);

    size_t sizeOf(string type)
    {
        switch (type)
        {
        case "char", "uchar", "int8", "uint8": return 1;
        case "short", "ushort", "int16", "uint16": return 2;
        case "int", "uint", "float", "int32", "uint32", "float32": return 4;
        case "double", "float64": return 8;
        default: throw new MeshFormatException("unknown PLY type " ~ type);
        }
    }
    // the next value: a word of the text, or one of the binary
    auto words = format == "ascii" ? (cast(const(char)[]) data[at .. $]).split : null;
    size_t word;
    double next(string type)
    {
        if (format == "ascii")
        {
            if (word >= words.length)
                throw new MeshFormatException("the PLY file is truncated");
            try
                return words[word++].to!double;
            catch (ConvException)
                throw new MeshFormatException("malformed PLY number: " ~ words[word - 1].idup);
        }
        immutable n = sizeOf(type);
        if (at + n > data.length)
            throw new MeshFormatException("the PLY file is truncated");
        ubyte[8] b;
        b[0 .. n] = data[at .. at + n];
        at += n;
        T get(T)() => format == "binary_big_endian" ? bigEndianToNative!T(b[0 .. T.sizeof])
            : littleEndianToNative!T(b[0 .. T.sizeof]);
        switch (type)
        {
        case "char", "int8": return cast(byte) b[0];
        case "uchar", "uint8": return b[0];
        case "short", "int16": return get!short;
        case "ushort", "uint16": return get!ushort;
        case "int", "int32": return get!int;
        case "uint", "uint32": return get!uint;
        case "float", "float32": return get!float;
        default: return get!double;
        }
    }

    Mesh m;
    size_t vertices;
    foreach (e; elements)
    {
        immutable xi = e.props.countUntil!(p => p.name == "x"), yi = e.props.countUntil!(p => p.name == "y"),
            zi = e.props.countUntil!(p => p.name == "z");
        immutable fi = e.props.countUntil!(p => p.countType.length && (p.name == "vertex_indices" || p.name == "vertex_index"));
        if (e.name == "vertex" && (xi < 0 || yi < 0 || zi < 0))
            throw new MeshFormatException("the PLY vertices have no x, y and z");
        foreach (_; 0 .. e.count)
        {
            double[3] xyz;
            foreach (pi, p; e.props)
            {
                if (p.countType.length)
                {
                    immutable n = next(p.countType);
                    if (!(n >= 0 && n < 1 << 20))
                        throw new MeshFormatException("malformed PLY list");
                    uint[] idx;
                    foreach (k; 0 .. cast(size_t) n)
                    {
                        immutable v = next(p.type);
                        if (e.name == "face" && pi == fi)
                        {
                            if (!(v >= 0 && v < vertices))
                                throw new MeshFormatException("PLY face refers to a missing vertex");
                            idx ~= cast(uint) v;
                        }
                    }
                    foreach (k; 1 .. idx.length >= 2 ? idx.length - 1 : 1)
                        m.tris ~= [idx[0], idx[k], idx[k + 1]];
                    continue;
                }
                immutable v = next(p.type);
                if (e.name == "vertex")
                    foreach (c, i; [xi, yi, zi])
                        if (pi == i)
                            xyz[c] = v;
            }
            if (e.name == "vertex")
                m.verts ~= [cast(float) xyz[0], cast(float) xyz[1], cast(float) xyz[2]];
        }
        if (e.name == "vertex")
            vertices = e.count;
    }
    if (m.tris.length == 0)
        throw new MeshFormatException("the PLY file has no faces (a point cloud?)");
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

/// glTF binary (.glb): its JSON and its buffer, read as readGltf does.
/// `fetch` gives the files its buffers name (none: they cannot be read).
Mesh readGlb(const(ubyte)[] data, const(ubyte)[] delegate(string uri) fetch = null)
{
    uint u32(size_t o)
    {
        if (o + 4 > data.length)
            throw new MeshFormatException("the GLB file is truncated");
        return littleEndianToNative!uint(data[o .. o + 4][0 .. 4]);
    }
    if (data.length < 12 || u32(0) != 0x46546C67)   // "glTF"
        throw new MeshFormatException("not a GLB file");
    if (u32(4) != 2)
        throw new MeshFormatException("only glTF 2.0 is read, this GLB is version " ~ u32(4).to!string);
    // chunks: the JSON first, then the binary buffer (optional)
    const(char)[] json;
    const(ubyte)[] bin;
    for (size_t o = 12; o + 8 <= data.length;)
    {
        immutable len = u32(o), type = u32(o + 4);
        if (o + 8 + cast(ulong) len > data.length)
            throw new MeshFormatException("the GLB file is truncated");
        auto chunk = data[o + 8 .. o + 8 + len];
        if (type == 0x4E4F534A && json is null)   // "JSON"
            json = cast(const(char)[]) chunk;
        else if (type == 0x004E4942 && bin is null)   // "BIN\0"
            bin = chunk;
        o += 8 + len;
    }
    if (json is null)
        throw new MeshFormatException("the GLB file has no JSON chunk");
    return readGltf(json, bin, fetch);
}

/// glTF 2.0: the triangles of every mesh of the default scene, placed by
/// its nodes' transforms, in millimetres (glTF is in metres) and turned Z
/// up (glTF is Y up). `bin` is a GLB's buffer, for the buffer with no uri;
/// data: URIs are decoded, other files asked to `fetch`.
Mesh readGltf(const(char)[] text, const(ubyte)[] bin = null, const(ubyte)[] delegate(string uri) fetch = null)
{
    // a value of the wrong kind where a number or a list belongs: a format error too
    try
        return gltfMesh(text, bin, fetch);
    catch (MeshFormatException e)
        throw e;
    catch (Exception e)
        throw new MeshFormatException("malformed glTF file: " ~ e.msg);
}

private Mesh gltfMesh(const(char)[] text, const(ubyte)[] bin, const(ubyte)[] delegate(string uri) fetch)
{
    import djson;
    import std.math : sqrt;

    JValue g;
    try
        g = parseJSONComplete(text.idup);
    catch (Exception e)
        throw new MeshFormatException("malformed glTF JSON: " ~ e.msg);
    if (!g.isObject)
        throw new MeshFormatException("malformed glTF JSON");
    JValue list(JValue v, string key) => v.has(key) && v[key].isArray ? v[key] : JValue.init;
    size_t count(JValue v) => v.isArray ? v.length : 0;
    double num(JValue v, string key, double fallback)
    {
        if (!v.has(key))
            return fallback;
        if (!v[key].isNumber)
            throw new MeshFormatException("glTF " ~ key ~ " is not a number");
        return v[key].get!double;
    }
    size_t index(JValue v, string key, size_t length, string what)
    {
        immutable i = num(v, key, -1);
        if (!(i >= 0 && i < length) || i != cast(size_t) i)
            throw new MeshFormatException("glTF " ~ key ~ " refers to a missing " ~ what);
        return cast(size_t) i;
    }

    foreach (i; 0 .. count(list(g, "extensionsRequired")))
    {
        auto e = list(g, "extensionsRequired")[i];
        immutable name = e.isString ? e.get!string : "";
        if (name == "KHR_draco_mesh_compression" || name == "EXT_meshopt_compression" || name == "KHR_meshopt_compression")
            throw new MeshFormatException("the glTF meshes are compressed (" ~ name ~ "): export them without compression");
    }

    // the buffers, read once each
    auto buffersJ = list(g, "buffers");
    auto buffers = new const(ubyte)[][count(buffersJ)];
    auto have = new bool[count(buffersJ)];
    const(ubyte)[] buffer(size_t b)
    {
        if (have[b])
            return buffers[b];
        auto j = buffersJ[b];
        if (!j.has("uri"))
        {
            if (bin is null)
                throw new MeshFormatException("glTF buffer " ~ b.to!string ~ " has no data (not a GLB?)");
            buffers[b] = bin;
        }
        else
        {
            immutable uri = j["uri"].isString ? j["uri"].get!string : "";
            if (uri.startsWith("data:"))
            {
                import std.base64 : Base64, Base64Exception;
                immutable comma = uri.indexOf(',');
                if (comma < 0 || uri[0 .. comma].indexOf(";base64") < 0)
                    throw new MeshFormatException("glTF data URI not in base64");
                try
                    buffers[b] = Base64.decode(uri[comma + 1 .. $]);
                catch (Base64Exception)
                    throw new MeshFormatException("malformed base64 in a glTF data URI");
            }
            else if (fetch is null)
                throw new MeshFormatException("glTF buffer in another file: " ~ uri);
            else
                buffers[b] = fetch(uri);
        }
        if (buffers[b].length < num(j, "byteLength", 0))
            throw new MeshFormatException("glTF buffer " ~ b.to!string ~ " is shorter than its byteLength");
        have[b] = true;
        return buffers[b];
    }

    // an accessor's values, as numbers, `width` per element
    auto accessors = list(g, "accessors"), views = list(g, "bufferViews");
    double[] values(size_t a, out size_t width)
    {
        auto j = accessors[a];
        if (j.has("sparse"))
            throw new MeshFormatException("sparse glTF accessors are not read");
        immutable n = cast(size_t) num(j, "count", 0);
        immutable type = j.has("type") && j["type"].isString ? j["type"].get!string : "";
        switch (type)
        {
        case "SCALAR": width = 1; break;
        case "VEC2": width = 2; break;
        case "VEC3": width = 3; break;
        case "VEC4": width = 4; break;
        default: throw new MeshFormatException("unexpected glTF accessor type " ~ type);
        }
        immutable ct = cast(int) num(j, "componentType", 0);
        immutable size = ct == 5120 || ct == 5121 ? 1 : ct == 5122 || ct == 5123 ? 2 : ct == 5125 || ct == 5126 ? 4 : 0;
        if (size == 0)
            throw new MeshFormatException("unknown glTF component type " ~ ct.to!string);
        immutable normalized = j.has("normalized") && j["normalized"].isBool && j["normalized"].get!bool;
        auto r = new double[n * width];
        if (!j.has("bufferView"))
        {
            r[] = 0;   // all zero, as the spec has it
            return r;
        }
        auto v = views[index(j, "bufferView", count(views), "buffer view")];
        auto data = buffer(index(v, "buffer", count(buffersJ), "buffer"));
        immutable start = cast(size_t)(num(v, "byteOffset", 0) + num(j, "byteOffset", 0));
        immutable stride = num(v, "byteStride", 0) > 0 ? cast(size_t) num(v, "byteStride", 0) : size * width;
        if (n && start + (n - 1) * stride + size * width > data.length)
            throw new MeshFormatException("glTF accessor reaches past its buffer");
        foreach (e; 0 .. n)
            foreach (c; 0 .. width)
            {
                immutable o = start + e * stride + c * size;
                double x;
                switch (ct)
                {
                case 5120: x = cast(byte) data[o]; break;
                case 5121: x = data[o]; break;
                case 5122: x = littleEndianToNative!short(data[o .. o + 2][0 .. 2]); break;
                case 5123: x = littleEndianToNative!ushort(data[o .. o + 2][0 .. 2]); break;
                case 5125: x = littleEndianToNative!uint(data[o .. o + 4][0 .. 4]); break;
                default: x = littleEndianToNative!float(data[o .. o + 4][0 .. 4]); break;
                }
                if (normalized)
                    x = ct == 5120 ? max(x / 127, -1) : ct == 5121 ? x / 255 : ct == 5122 ? max(x / 32767, -1) : ct == 5123
                        ? x / 65535 : x;
                r[e * width + c] = x;
            }
        return r;
    }

    Mesh result;
    auto meshes = list(g, "meshes");
    // mesh `m` placed by the column-major 4x4 matrix `t`
    void addMesh(size_t m, const double[16] t)
    {
        // a mirroring transform turns the triangles inside out: put them back
        immutable det = t[0] * (t[5] * t[10] - t[9] * t[6]) - t[4] * (t[1] * t[10] - t[9] * t[2])
            + t[8] * (t[1] * t[6] - t[5] * t[2]);
        auto prims = list(meshes[m], "primitives");
        foreach (pi; 0 .. count(prims))
        {
            auto p = prims[pi];
            immutable mode = cast(int) num(p, "mode", 4);
            if (mode < 4)
                continue;   // points and lines
            if (!p.has("attributes") || !p["attributes"].has("POSITION"))
                continue;
            size_t w;
            auto pos = values(index(p["attributes"], "POSITION", count(accessors), "accessor"), w);
            if (w != 3)
                throw new MeshFormatException("glTF POSITION is not a VEC3");
            immutable base = cast(uint)(result.verts.length / 3);
            immutable nv = pos.length / 3;
            foreach (k; 0 .. nv)
            {
                immutable x = pos[k * 3], y = pos[k * 3 + 1], z = pos[k * 3 + 2];
                immutable X = t[0] * x + t[4] * y + t[8] * z + t[12];
                immutable Y = t[1] * x + t[5] * y + t[9] * z + t[13];
                immutable Z = t[2] * x + t[6] * y + t[10] * z + t[14];
                // metres to mm, Y up to Z up
                result.verts ~= [cast(float)(X * 1000), cast(float)(-Z * 1000), cast(float)(Y * 1000)];
            }
            uint[] idx;
            if (p.has("indices"))
            {
                size_t iw;
                foreach (x; values(index(p, "indices", count(accessors), "accessor"), iw))
                {
                    if (!(x >= 0 && x < nv))
                        throw new MeshFormatException("glTF index refers to a missing vertex");
                    idx ~= cast(uint) x;
                }
            }
            else
                foreach (k; 0 .. cast(uint) nv)
                    idx ~= k;
            void tri(uint a, uint b, uint c)
            {
                if (a == b || b == c || a == c)
                    return;
                if (det < 0)
                    result.tris ~= [base + a, base + c, base + b];
                else
                    result.tris ~= [base + a, base + b, base + c];
            }
            if (mode == 4)
                for (size_t k = 0; k + 2 < idx.length; k += 3)
                    tri(idx[k], idx[k + 1], idx[k + 2]);
            else if (mode == 5)   // strip: every other one turned
                foreach (k; 0 .. idx.length >= 2 ? idx.length - 2 : 0)
                    k % 2 ? tri(idx[k + 1], idx[k], idx[k + 2]) : tri(idx[k], idx[k + 1], idx[k + 2]);
            else if (mode == 6)   // fan
                foreach (k; 1 .. idx.length >= 2 ? idx.length - 1 : 1)
                    tri(idx[0], idx[k], idx[k + 1]);
        }
    }

    // the nodes' tree from the scene's roots, each node's transform after its parent's
    auto nodes = list(g, "nodes");
    void addNode(size_t n, const double[16] parent, int depth)
    {
        if (depth > 64)
            throw new MeshFormatException("glTF nodes nest too deeply (or in a loop)");
        auto j = nodes[n];
        double[16] local = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
        if (j.has("matrix") && j["matrix"].isArray && j["matrix"].length == 16)
            foreach (k; 0 .. 16)
                local[k] = j["matrix"][k].get!double;
        else
        {
            double[3] tr = [0, 0, 0], sc = [1, 1, 1];
            double[4] q = [0, 0, 0, 1];
            if (j.has("translation") && j["translation"].isArray && j["translation"].length == 3)
                foreach (k; 0 .. 3)
                    tr[k] = j["translation"][k].get!double;
            if (j.has("scale") && j["scale"].isArray && j["scale"].length == 3)
                foreach (k; 0 .. 3)
                    sc[k] = j["scale"][k].get!double;
            if (j.has("rotation") && j["rotation"].isArray && j["rotation"].length == 4)
                foreach (k; 0 .. 4)
                    q[k] = j["rotation"][k].get!double;
            immutable ql = sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
            if (ql > 0)
                q[] /= ql;
            immutable x = q[0], y = q[1], z = q[2], w = q[3];
            // T * R * S, column-major
            local = [(1 - 2 * (y * y + z * z)) * sc[0], 2 * (x * y + z * w) * sc[0], 2 * (x * z - y * w) * sc[0], 0,
                2 * (x * y - z * w) * sc[1], (1 - 2 * (x * x + z * z)) * sc[1], 2 * (y * z + x * w) * sc[1], 0,
                2 * (x * z + y * w) * sc[2], 2 * (y * z - x * w) * sc[2], (1 - 2 * (x * x + y * y)) * sc[2], 0,
                tr[0], tr[1], tr[2], 1];
        }
        double[16] t;
        foreach (c; 0 .. 4)
            foreach (r; 0 .. 4)
            {
                double s = 0;
                foreach (k; 0 .. 4)
                    s += parent[k * 4 + r] * local[c * 4 + k];
                t[c * 4 + r] = s;
            }
        if (j.has("mesh"))
            addMesh(index(j, "mesh", count(meshes), "mesh"), t);
        auto kids = list(j, "children");
        foreach (k; 0 .. count(kids))
        {
            if (!kids[k].isNumber || !(kids[k].get!double >= 0 && kids[k].get!double < count(nodes)))
                throw new MeshFormatException("glTF child refers to a missing node");
            addNode(cast(size_t) kids[k].get!double, t, depth + 1);
        }
    }

    immutable double[16] identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
    auto scenes = list(g, "scenes");
    if (count(scenes))
    {
        auto sc = scenes[g.has("scene") ? index(g, "scene", count(scenes), "scene") : 0];
        auto roots = list(sc, "nodes");
        foreach (k; 0 .. count(roots))
        {
            if (!roots[k].isNumber || !(roots[k].get!double >= 0 && roots[k].get!double < count(nodes)))
                throw new MeshFormatException("glTF scene refers to a missing node");
            addNode(cast(size_t) roots[k].get!double, identity, 0);
        }
    }
    else
        // no scene: every mesh as it is
        foreach (m; 0 .. count(meshes))
            addMesh(m, identity);
    if (result.tris.length == 0)
        throw new MeshFormatException("the glTF file has no triangles");
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
    import std.algorithm : minElement, maxElement;
    import std.array : join;
    import std.base64 : Base64;
    import std.bitmanip : nativeToLittleEndian;
    import std.exception : assertThrown;
    import std.math : isClose;
    import std.format : format;

    // a tetrahedron of 1 cm sides in metres: floats, then ushort indices
    ubyte[] bin;
    foreach (float f; [0.0, 0, 0, 0.01, 0, 0, 0, 0.01, 0, 0, 0, 0.01])
        bin ~= nativeToLittleEndian(f)[];
    foreach (ushort i; [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3])
        bin ~= nativeToLittleEndian(i)[];
    string json(string node, string buffer) => `{"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],`
        ~ ` "nodes": [{"children": [1]}, ` ~ node ~ `], "meshes": [{"primitives": [{"attributes": {"POSITION": 0},`
        ~ ` "indices": 1}]}], "buffers": [` ~ buffer ~ `], "bufferViews": [{"buffer": 0, "byteLength": 48},`
        ~ ` {"buffer": 0, "byteOffset": 48, "byteLength": 24}], "accessors": [{"bufferView": 0, "componentType": 5126,`
        ~ ` "count": 4, "type": "VEC3"}, {"bufferView": 1, "componentType": 5123, "count": 12, "type": "SCALAR"}]}`;
    ubyte[] glb(string j)
    {
        while (j.length % 4)
            j ~= " ";
        ubyte[] o = cast(ubyte[]) "glTF".dup ~ nativeToLittleEndian(2u)[]
            ~ nativeToLittleEndian(cast(uint)(12 + 8 + j.length + 8 + bin.length))[];
        o ~= nativeToLittleEndian(cast(uint) j.length)[] ~ cast(ubyte[]) "JSON".dup ~ cast(ubyte[]) j.dup;
        return o ~ nativeToLittleEndian(cast(uint) bin.length)[] ~ cast(ubyte[]) "BIN\0".dup ~ bin;
    }
    immutable buf = `{"byteLength": 72}`;

    // in mm, the node's move applied, closed and outward
    auto m = readGlb(glb(json(`{"mesh": 0, "translation": [0.005, 0, 0]}`, buf)));
    assert(m.vertexCount == 4 && m.isClosed && isClose(m.volume, 1000.0 / 6, 1e-4));
    float[] xs;
    foreach (k; 0 .. m.vertexCount)
        xs ~= m.verts[k * 3];
    assert(isClose(xs.minElement, 5) && isClose(xs.maxElement, 15));
    // glTF's up (Y) is Z here, its Z towards the viewer -Y
    auto up = readGlb(glb(json(`{"mesh": 0, "translation": [0, 0.02, 0.03]}`, buf)));
    float[] zs, ys;
    foreach (k; 0 .. up.vertexCount)
    {
        ys ~= up.verts[k * 3 + 1];
        zs ~= up.verts[k * 3 + 2];
    }
    assert(isClose(zs.minElement, 20) && isClose(ys.maxElement, -30));
    // a mirror and a turn: still outward
    auto mirrored = readGlb(glb(json(`{"mesh": 0, "scale": [-1, 1, 1], "rotation": [0, 0.7071068, 0, 0.7071068]}`, buf)));
    assert(mirrored.isClosed && isClose(mirrored.volume, 1000.0 / 6, 1e-4));
    // a .gltf with its buffer in a data URI
    auto text = readGltf(json(`{"mesh": 0}`, format(`{"byteLength": 72, "uri": "data:application/octet-stream;base64,%s"}`,
        Base64.encode(bin))));
    assert(text.isClosed && isClose(text.volume, 1000.0 / 6, 1e-4));
    // and in a file of its own
    auto beside = readGltf(json(`{"mesh": 0}`, `{"byteLength": 72, "uri": "t.bin"}`), null,
        (string uri) { assert(uri == "t.bin"); return cast(const(ubyte)[]) bin; });
    assert(beside.isClosed);

    assertThrown!MeshFormatException(readGlb(cast(ubyte[]) "hello"));
    assertThrown!MeshFormatException(readGltf(json(`{"mesh": 0}`, `{"byteLength": 72, "uri": "t.bin"}`)));
    assertThrown!MeshFormatException(readGltf(`{"extensionsRequired": ["KHR_draco_mesh_compression"]}`));
    assertThrown!MeshFormatException(readGltf(`{"nodes": [{"mesh": "x"}], "scenes": [{"nodes": [0]}]}`));
}

unittest
{
    import std.bitmanip : nativeToLittleEndian, nativeToBigEndian;
    import std.exception : assertThrown;
    import std.math : isClose;

    // a tetrahedron as text, with a colour per vertex and a square face's worth of fan
    auto text = readPly(cast(const(ubyte)[]) ("ply\nformat ascii 1.0\ncomment made by hand\nelement vertex 4\n"
        ~ "property float x\nproperty float y\nproperty float z\nproperty uchar red\nelement face 4\n"
        ~ "property list uchar int vertex_indices\nend_header\n0 0 0 255\n10 0 0 0\n0 10 0 0\n0 0 10 0\n"
        ~ "3 0 2 1\n3 0 1 3\n3 0 3 2\n3 1 2 3\n"));
    assert(text.vertexCount == 4 && text.isClosed && isClose(text.volume, 1000.0 / 6, 1e-4));

    // the same in binary, both byte orders, with y before x and an edge element after the faces
    foreach (big; [false, true])
    {
        ubyte[] b = cast(ubyte[]) ("ply\nformat " ~ (big ? "binary_big_endian" : "binary_little_endian")
            ~ " 1.0\nelement vertex 4\nproperty double y\nproperty double x\nproperty double z\n"
            ~ "element face 4\nproperty list uchar uint vertex_index\nelement edge 1\nproperty int vertex1\n"
            ~ "property int vertex2\nend_header\n").dup;
        foreach (double v; [0.0, 0, 0, 0, 10, 0, 0, 0, 10, 10, 0, 0])
            b ~= big ? nativeToBigEndian(v)[] : nativeToLittleEndian(v)[];
        foreach (f; [[0u, 1, 2], [0u, 2, 3], [0u, 3, 1], [2u, 1, 3]])
        {
            b ~= 3;
            foreach (i; f)
                b ~= big ? nativeToBigEndian(i)[] : nativeToLittleEndian(i)[];
        }
        b ~= nativeToLittleEndian(0)[] ~ nativeToLittleEndian(1)[];
        auto bin = readPly(b);
        assert(bin.isClosed && isClose(bin.volume, 1000.0 / 6, 1e-4));
    }

    assertThrown!MeshFormatException(readPly(cast(const(ubyte)[]) "hello"));
    assertThrown!MeshFormatException(readPly(cast(const(ubyte)[]) ("ply\nformat ascii 1.0\nelement vertex 1\n"
        ~ "property float x\nproperty float y\nproperty float z\nend_header\n1 2 3\n")));
}

unittest
{
    // short lines are format errors, not crashes
    import std.exception : assertThrown;
    assertThrown!MeshFormatException(readObj("v 0 0\nf 1 1 1\n"));
    assertThrown!MeshFormatException(readObj("v 0 0 0\nv 1 0 0\nf 1 2\n"));
    assertThrown!MeshFormatException(readObj("v 0 0 0\nf\n"));
}
