/// Kernel-independent interface for fast mesh solids. Used for operations
/// that have no B-rep counterpart (hull, minkowski, imported STL) and for
/// heavy repetitive booleans where exact surfaces are not needed.
module hackerscad.kernel.meshkernel;

public import hackerscad.geom.vec;
public import hackerscad.geom.mesh;
public import hackerscad.kernel.brep : BoolOp, KernelException;

/// Opaque handle to an immutable mesh solid owned by a kernel.
abstract class MeshSolid
{
}

interface MeshKernel
{
    string name();

    /// Same placement conventions as BrepKernel: box from the origin,
    /// cylinder/cone on XY along +Z, sphere centred.
    MeshSolid box(double dx, double dy, double dz);
    MeshSolid cone(double r1, double r2, double h, int segments);
    MeshSolid sphere(double r, int segments);

    /// Requires a closed, consistently oriented (welded) mesh.
    MeshSolid fromMesh(const Mesh m);
    Mesh toMesh(MeshSolid s);

    MeshSolid translate(MeshSolid s, Vec3 v);
    /// Rotation around an axis through the origin.
    MeshSolid rotate(MeshSolid s, Vec3 axis, double angleRad);
    MeshSolid scale(MeshSolid s, Vec3 factors);
    MeshSolid mirror(MeshSolid s, Vec3 normal);

    MeshSolid boolean(MeshSolid a, MeshSolid b, BoolOp op);
    /// One n-ary boolean: much faster than chaining for many operands.
    MeshSolid batch(MeshSolid[] solids, BoolOp op);
    MeshSolid hull(MeshSolid[] solids);
    MeshSolid minkowski(MeshSolid a, MeshSolid b);

    double volume(MeshSolid s);
    double area(MeshSolid s);
    BBox bbox(MeshSolid s);
    size_t triangleCount(MeshSolid s);
}
