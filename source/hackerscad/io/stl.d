module hackerscad.io.stl;

import std.bitmanip : nativeToLittleEndian;

import hackerscad.geom.mesh;

/// Binary STL. STL has no units: values are millimetres by convention.
ubyte[] toStl(const Mesh m)
{
    auto data = new ubyte[84 + m.triangleCount * 50];
    data[0 .. 11] = cast(const(ubyte)[]) "hackerscad\0";
    data[80 .. 84] = nativeToLittleEndian(cast(uint) m.triangleCount);
    size_t o = 84;
    void put(float f)
    {
        data[o .. o + 4] = nativeToLittleEndian(f);
        o += 4;
    }

    foreach (t; 0 .. m.triangleCount)
    {
        auto a = m.vertex(m.tris[t * 3]), b = m.vertex(m.tris[t * 3 + 1]), c = m.vertex(m.tris[t * 3 + 2]);
        auto n = (b - a).cross(c - a).normalized;
        foreach (v; [n, a, b, c])
        {
            put(cast(float) v.x);
            put(cast(float) v.y);
            put(cast(float) v.z);
        }
        o += 2; // attribute byte count
    }
    return data;
}

unittest
{
    Mesh m;
    m.verts = [0, 0, 0, 1, 0, 0, 0, 1, 0];
    m.tris = [0, 1, 2];
    auto d = toStl(m);
    assert(d.length == 134);
    assert(d[80] == 1);
}
