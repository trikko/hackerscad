/// Kernel-independent B-rep interface. The language, the cache and the
/// topological naming only talk to this module, so the OpenCascade backend
/// can later be replaced, one operation at a time, by a native D kernel.
module hackerscad.kernel.brep;

public import hackerscad.geom.vec;
public import hackerscad.geom.mesh;

/// Opaque handle to an immutable solid owned by a kernel.
abstract class Brep
{
}

enum BoolOp
{
    fuse,
    cut,
    common,
}

enum EdgeKind
{
    line,
    circle,
    other,
}

struct EdgeInfo
{
    EdgeKind kind;
    Vec3 start, end, mid;
    Vec3 center, axis;   /// circles only
    double radius = 0;   /// circles only
    double length = 0;   /// along the curve

    Vec3 direction() const => (end - start).normalized;
}

/// Where a face of an operation's result comes from: operand `input`
/// (0 first, 1 second) and its face `index` there, or -1 when the operation
/// created the face.
struct MassProps
{
    double volume;
    Vec3 centroid;
    double[3] moments;
}

struct FaceOrigin
{
    int input = -1;
    int index = -1;
}

struct FaceInfo
{
    Vec3 center;
    Vec3 normal;
    double area;
}

class KernelException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// One piece of a planar outline: a line a → b, an arc a → b through m, or
/// the end of a loop.
struct OutlineSeg
{
    enum Kind : int { line, arc, end }
    Kind kind;
    double ax = 0, ay = 0, bx = 0, by = 0, mx = 0, my = 0;
}

/// A projected edge segment in a drawing view (x right, y up).
struct ViewSegment
{
    enum Kind : int { edge, tangent, outline, hidden }
    double x1, y1, x2, y2;
    Kind kind;
}

interface BrepKernel
{
    string name();

    /// Box with its min corner at the origin.
    Brep box(double dx, double dy, double dz);
    /// Cylinder and cone stand on the XY plane, axis along +Z.
    Brep cylinder(double r, double h);
    Brep cone(double r1, double r2, double h);
    /// Sphere centred at the origin.
    Brep sphere(double r);

    /// Profiles: planar faces on XY. Rectangle and circle are centred on the
    /// origin; polygon takes x0 y0 x1 y1 …; text starts at the origin on its
    /// baseline (`font`: family name or font file path).
    Brep rect(double w, double h);
    Brep circle(double r);
    Brep polygon(const(double)[] xy);
    Brep text(string s, double size, string font);
    /// Rounds the corners of a profile.
    Brep profileRound(Brep s, double r);
    /// Grows (d > 0) or shrinks (d < 0) a profile.
    Brep profileOffset(Brep s, double d);
    /// A solid grown (d > 0) or shrunk, round where it turns.
    Brep offset(Brep s, double d);
    /// Profile → solid along +Z (−Z if negative); taper narrows the top.
    Brep extrude(Brep profile, double height, double taper);
    /// Profile → solid of revolution around an axis in its plane.
    Brep revolve(Brep profile, Vec3 origin, Vec3 direction, double angle);
    /// Outline segments: see OutlineSeg. Nested loops are holes.
    Brep outline(const(OutlineSeg)[] segs);
    /// Paths (wires) for sweeps.
    Brep polyline(const(Vec3)[] pts, bool closed);
    Brep spline(const(Vec3)[] pts, bool closed);
    Brep helix(double r, double pitch, double height, bool left);
    /// Point and tangent at the start (or end) of a path.
    void pathFrame(Brep path, bool atEnd, out Vec3 point, out Vec3 tangent);
    Brep sweep(Brep profile, Brep path, bool frenet);
    Brep loft(Brep[] profiles, bool ruled);
    /// Hidden-line projection: `dir` points from the model to the viewer.
    ViewSegment[] hiddenLines(Brep s, Vec3 dir, Vec3 up, double deflection);
    /// Boundary loops of a face as 3D polylines (outer and holes).
    Vec3[][] faceLoops(Brep s, int face, double deflection);

    Brep translate(Brep s, Vec3 v);
    /// Rotation around an axis through the origin.
    Brep rotate(Brep s, Vec3 axis, double angleRad);
    Brep scale(Brep s, double factor);
    /// Mirror across the plane through the origin with the given normal.
    Brep mirror(Brep s, Vec3 normal);

    Brep boolean(Brep a, Brep b, BoolOp op);
    /// The union of all of `parts`, in one go.
    Brep fuseAll(Brep[] parts);
    /// The disconnected solid bodies of `s` (face origins point into `s`).
    Brep[] solids(Brep s);

    /// Edges and faces in a stable order for a given shape; the index is what
    /// fillet/chamfer/shell accept.
    EdgeInfo[] edges(Brep s);
    FaceInfo[] faces(Brep s);
    /// How many faces `s` has, without computing anything about them.
    size_t faceCount(Brep s);

    /// Face origins recorded when `s` was produced (see FaceOrigin).
    FaceOrigin[] faceOrigins(Brep s);
    /// For every edge, the indices of its two faces (-1 when missing).
    int[2][] edgeFaces(Brep s);

    Brep fillet(Brep s, const(int)[] edges, double r);
    Brep chamfer(Brep s, const(int)[] edges, double d);
    /// The flat face `face` swept by the vector `v`: what pushing or
    /// pulling it adds or removes.
    Brep facePrism(Brep s, int face, Vec3 v);
    /// Hollows the solid inwards, opening the given faces.
    Brep shell(Brep s, const(int)[] faces, double thickness);
    /// Tilts faces by `angle` for moulding: `pull` is the opening direction,
    /// the faces pivot on the plane through `neutral` normal to `pull`.
    Brep draft(Brep s, const(int)[] faces, double angle, Vec3 pull, Vec3 neutral);

    double volume(Brep s);
    /// Volume, centre of mass and principal moments of inertia about it
    /// (ascending, per unit density: mm⁵).
    MassProps massProps(Brep s);
    /// The cut of a solid by a plane: a profile, where the plane is.
    Brep section(Brep s, Vec3 origin, Vec3 normal);
    double area(Brep s);
    BBox bbox(Brep s);
    bool isValid(Brep s);
    /// Minimum distance and the closest points.
    double distance(Brep a, Brep b, out Vec3 onA, out Vec3 onB);

    /// Triangles grouped by face (Mesh.faceStart), one vertex set per face.
    Mesh tessellate(Brep s, double linearDeflection, double angularDeflection);

    /// A closed triangle mesh (e.g. from STL) as a solid, coplanar triangles merged.
    Brep fromMesh(const Mesh m);

    /// One STEP file, each part a separate, named body.
    void writeStep(Brep[] parts, string[] names, string path);
    Brep readStep(string path);
}
