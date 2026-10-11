module hackerscad.kernel.manifold.backend;

import std.conv : to;
import std.math : cos, sin;

import hackerscad.kernel.meshkernel;
import hackerscad.kernel.manifold.c;

final class ManifoldSolid : MeshSolid
{
    private ManifoldManifold* handle;

    private this(ManifoldManifold* h)
    {
        handle = h;
    }

    ~this()
    {
        manifold_delete_manifold(handle);
    }
}

final class ManifoldKernel : MeshKernel
{
    string name() => "manifold";

    MeshSolid box(double dx, double dy, double dz) =>
        make(m => manifold_cube(m, dx, dy, dz, 0), "box");

    MeshSolid cone(double r1, double r2, double h, int segments) =>
        make(m => manifold_cylinder(m, h, r1, r2, segments, 0), "cone");

    MeshSolid sphere(double r, int segments) =>
        make(m => manifold_sphere(m, r, segments), "sphere");

    MeshSolid fromMesh(const Mesh mesh)
    {
        auto gl = manifold_meshgl(manifold_alloc_meshgl(), cast(float*) mesh.verts.ptr, mesh.vertexCount, 3,
            cast(uint*) mesh.tris.ptr, mesh.triangleCount);
        scope (exit)
            manifold_delete_meshgl(gl);
        return make(m => manifold_of_meshgl(m, gl), "mesh import");
    }

    Mesh toMesh(MeshSolid s)
    {
        auto gl = manifold_get_meshgl(manifold_alloc_meshgl(), h(s));
        scope (exit)
            manifold_delete_meshgl(gl);
        immutable nv = manifold_meshgl_num_vert(gl), np = manifold_meshgl_num_prop(gl), nt = manifold_meshgl_num_tri(gl);
        auto props = new float[nv * np];
        manifold_meshgl_vert_properties(props.ptr, gl);
        Mesh r;
        r.verts = new float[nv * 3];
        foreach (i; 0 .. nv)
            r.verts[i * 3 .. i * 3 + 3] = props[i * np .. i * np + 3];
        r.tris = new uint[nt * 3];
        manifold_meshgl_tri_verts(r.tris.ptr, gl);
        return r;
    }

    MeshSolid translate(MeshSolid s, Vec3 v) =>
        make(m => manifold_translate(m, h(s), v.x, v.y, v.z), "translate");

    MeshSolid rotate(MeshSolid s, Vec3 axis, double angleRad)
    {
        // Rodrigues' formula; manifold_transform takes the 3x4 matrix by columns
        immutable a = axis.normalized, c = cos(angleRad), si = sin(angleRad), t = 1 - c;
        double[3][3] r = [
            [t * a.x * a.x + c, t * a.x * a.y - si * a.z, t * a.x * a.z + si * a.y],
            [t * a.x * a.y + si * a.z, t * a.y * a.y + c, t * a.y * a.z - si * a.x],
            [t * a.x * a.z - si * a.y, t * a.y * a.z + si * a.x, t * a.z * a.z + c],
        ];
        return make(m => manifold_transform(m, h(s),
            r[0][0], r[1][0], r[2][0],
            r[0][1], r[1][1], r[2][1],
            r[0][2], r[1][2], r[2][2],
            0, 0, 0), "rotate");
    }

    MeshSolid scale(MeshSolid s, Vec3 f) => make(m => manifold_scale(m, h(s), f.x, f.y, f.z), "scale");

    MeshSolid mirror(MeshSolid s, Vec3 n) => make(m => manifold_mirror(m, h(s), n.x, n.y, n.z), "mirror");

    MeshSolid boolean(MeshSolid a, MeshSolid b, BoolOp op) =>
        make(m => manifold_boolean(m, h(a), h(b), opType(op)), op.to!string);

    MeshSolid batch(MeshSolid[] solids, BoolOp op)
    {
        auto vec = toVec(solids);
        scope (exit)
            manifold_delete_manifold_vec(vec);
        return make(m => manifold_batch_boolean(m, vec, opType(op)), "batch " ~ op.to!string);
    }

    MeshSolid hull(MeshSolid[] solids)
    {
        auto vec = toVec(solids);
        scope (exit)
            manifold_delete_manifold_vec(vec);
        return make(m => manifold_batch_hull(m, vec), "hull");
    }

    MeshSolid minkowski(MeshSolid a, MeshSolid b) =>
        make(m => manifold_minkowski_sum(m, h(a), h(b)), "minkowski");

    double volume(MeshSolid s) => manifold_volume(h(s));

    double area(MeshSolid s) => manifold_surface_area(h(s));

    BBox bbox(MeshSolid s)
    {
        auto b = manifold_bounding_box(manifold_alloc_box(), h(s));
        scope (exit)
            manifold_delete_box(b);
        immutable lo = manifold_box_min(b), hi = manifold_box_max(b);
        return BBox(Vec3(lo.x, lo.y, lo.z), Vec3(hi.x, hi.y, hi.z));
    }

    size_t triangleCount(MeshSolid s) => manifold_num_tri(h(s));

private:
    static ManifoldManifold* h(MeshSolid s)
    {
        auto o = cast(ManifoldSolid) s;
        if (o is null)
            throw new KernelException("solid does not belong to the Manifold kernel");
        return o.handle;
    }

    static ManifoldOpType opType(BoolOp op)
    {
        final switch (op)
        {
        case BoolOp.fuse: return MANIFOLD_ADD;
        case BoolOp.cut: return MANIFOLD_SUBTRACT;
        case BoolOp.common: return MANIFOLD_INTERSECT;
        }
    }

    static ManifoldManifoldVec* toVec(MeshSolid[] solids)
    {
        auto vec = manifold_manifold_vec(manifold_alloc_manifold_vec(), 0);
        foreach (s; solids)
            manifold_manifold_vec_push_back(vec, h(s));
        return vec;
    }

    /// Runs a constructor on freshly allocated memory and checks the status.
    static MeshSolid make(scope ManifoldManifold* delegate(void*) build, string op)
    {
        auto m = build(manifold_alloc_manifold());
        immutable status = manifold_status(m);
        if (status != MANIFOLD_NO_ERROR)
        {
            manifold_delete_manifold(m);
            throw new KernelException(op ~ " failed: " ~ status.to!string);
        }
        return new ManifoldSolid(m);
    }
}

unittest
{
    import std.math : isClose, PI;

    auto k = new ManifoldKernel;
    auto box = k.translate(k.box(40, 30, 20), Vec3(-20, -15, -10));
    auto cyl = k.translate(k.cone(8, 8, 20, 256), Vec3(0, 0, -5));
    auto s = k.boolean(box, cyl, BoolOp.cut);

    // a 256-gon is slightly smaller than the circle
    immutable polygon = 0.5 * 256 * 64 * sin(2 * PI / 256);
    assert(isClose(k.volume(s), 24_000 - polygon * 15, 1e-6));
    auto bb = k.bbox(s);
    assert(isClose(bb.size.x, 40) && isClose(bb.size.z, 20));

    auto m = k.toMesh(s);
    assert(m.isClosed);
    assert(isClose(k.volume(k.fromMesh(m)), k.volume(s), 1e-6));

    auto r = k.bbox(k.rotate(k.box(10, 20, 30), Vec3(0, 0, 1), PI / 2));
    assert(isClose(r.size.x, 20) && isClose(r.size.y, 10));

    // n-ary union of a grid of cubes = sum of volumes
    MeshSolid[] cubes;
    foreach (i; 0 .. 10)
        foreach (j; 0 .. 10)
            cubes ~= k.translate(k.box(1, 1, 1), Vec3(i * 2, j * 2, 0));
    assert(isClose(k.volume(k.batch(cubes, BoolOp.fuse)), 100));
    assert(isClose(k.volume(k.hull(cubes)), 19 * 19));

    import std.exception : assertThrown;
    Mesh open;
    open.verts = [0, 0, 0, 1, 0, 0, 0, 1, 0];
    open.tris = [0, 1, 2];
    assertThrown!KernelException(k.fromMesh(open));
}

unittest
{
    // B-rep -> mesh -> Manifold: the hybrid path for fast booleans
    import std.math : isClose;
    import hackerscad.kernel.occt.backend : OcctKernel;

    auto occt = new OcctKernel;
    auto mk = new ManifoldKernel;
    auto brep = occt.fillet(occt.box(20, 20, 20), [0, 1, 2, 3], 3);
    auto solid = mk.fromMesh(occt.tessellate(brep, 0.01, 0.1).welded);
    assert(isClose(mk.volume(solid), occt.volume(brep), 1e-3));
}
