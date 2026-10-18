module hackerscad.geom.vec;

import std.math : sqrt;

struct Vec3
{
    double x = 0, y = 0, z = 0;

    Vec3 opBinary(string op)(Vec3 o) const if (op == "+" || op == "-")
    {
        return Vec3(mixin("x" ~ op ~ "o.x"), mixin("y" ~ op ~ "o.y"), mixin("z" ~ op ~ "o.z"));
    }

    Vec3 opBinary(string op)(double k) const if (op == "*" || op == "/")
    {
        return Vec3(mixin("x" ~ op ~ "k"), mixin("y" ~ op ~ "k"), mixin("z" ~ op ~ "k"));
    }

    Vec3 opBinaryRight(string op : "*")(double k) const => this * k;

    Vec3 opUnary(string op : "-")() const => Vec3(-x, -y, -z);

    /// The coordinates by index: 0 x, 1 y, 2 z.
    ref inout(double) opIndex(size_t i) inout return
    {
        assert(i < 3, "a Vec3 has three coordinates");
        return i == 0 ? x : i == 1 ? y : z;
    }

    // inline wherever they are used (ldc does not inline across modules otherwise): the renderer
    // and the mesh code call them millions of times
    pragma(inline, true) double dot(Vec3 o) const => x * o.x + y * o.y + z * o.z;

    pragma(inline, true) Vec3 cross(Vec3 o) const => Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

    pragma(inline, true) double length() const => sqrt(dot(this));

    pragma(inline, true) Vec3 normalized() const
    {
        immutable l = length;
        return l > 0 ? this / l : this;
    }
}

struct BBox
{
    Vec3 min, max;

    Vec3 size() const => max - min;
    Vec3 center() const => (min + max) / 2;

    /// The box around this one and `o`.
    BBox merged(BBox o) const
    {
        import std.algorithm : mn = min, mx = max;
        return BBox(Vec3(mn(min.x, o.min.x), mn(min.y, o.min.y), mn(min.z, o.min.z)),
            Vec3(mx(max.x, o.max.x), mx(max.y, o.max.y), mx(max.z, o.max.z)));
    }
}

unittest
{
    auto v = Vec3(1, 2, 3);
    assert(v[0] == 1 && v[1] == 2 && v[2] == 3);
    v[1] = 5;
    v[2] += 1;
    assert(v == Vec3(1, 5, 4));
}

unittest
{
    auto a = Vec3(1, 2, 3);
    assert(a + Vec3(1, 1, 1) == Vec3(2, 3, 4));
    assert(2 * a == Vec3(2, 4, 6));
    assert(Vec3(1, 0, 0).cross(Vec3(0, 1, 0)) == Vec3(0, 0, 1));
    assert(BBox(Vec3(0, 0, 0), Vec3(2, 4, 6)).center == Vec3(1, 2, 3));
    assert(BBox(Vec3(0, 0, 0), Vec3(1, 1, 1)).merged(BBox(Vec3(-1, 2, 0), Vec3(0, 3, 4)))
        == BBox(Vec3(-1, 0, 0), Vec3(1, 3, 4)));
}
