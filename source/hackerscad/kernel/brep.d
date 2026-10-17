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
    Vec3 startTangent, endTangent;   /// unit tangents at start and end, along the curve's direction

    Vec3 direction() const => (end - start).normalized;
}

/// The edges `seed` and every edge running on from them without a corner
/// (tangent where they meet within the angle whose cosine is `cosTol`), as
/// a flag per edge: a curved outline made of many pieces, taken whole.
bool[] tangentChain(const(EdgeInfo)[] edges, const(int)[] seed, double cosTol)
{
    import std.math : abs;
    auto on = new bool[edges.length];
    size_t[] todo;
    foreach (s; seed)
        if (s >= 0 && s < edges.length && !on[s])
        {
            on[s] = true;
            todo ~= s;
        }
    // the tangent of edge e at p, when p is one of its ends
    bool tangentAt(size_t e, Vec3 p, out Vec3 t)
    {
        const g = &edges[e];
        immutable eps = 1e-6 * (1 + p.length);
        if ((g.start - p).length < eps)
        {
            t = g.startTangent;
            return true;
        }
        if ((g.end - p).length < eps)
        {
            t = g.endTangent;
            return true;
        }
        return false;
    }
    while (todo.length)
    {
        immutable e = todo[$ - 1];
        todo = todo[0 .. $ - 1];
        foreach (p; [edges[e].start, edges[e].end])
        {
            Vec3 te;
            tangentAt(e, p, te);
            foreach (o; 0 .. edges.length)
            {
                Vec3 to;
                if (on[o] || !tangentAt(o, p, to) || abs(te.dot(to)) < cosTol)
                    continue;
                on[o] = true;
                todo ~= o;
            }
        }
    }
    return on;
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

/// A face lying on a cylinder: its axis, radius, extent along the axis
/// (from `from` to `to`, measured from `origin` along `axis`), the angle it
/// spans around it, and whether it is the outside of a shaft (true) or the
/// wall of a hole (false).
struct CylinderInfo
{
    Vec3 origin, axis;
    double radius = 0, from = 0, to = 0, span = 0;
    bool outside;
}

class KernelException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// One piece of a planar outline: a line a → b, an arc a → b through m, the
/// end of a loop, a whole ellipse (a loop of its own, before an end):
/// centre a, radii bx (along its own x axis, mx radians from X) and by, or a
/// smooth curve a → b given by its poles; or, after the loops, the area
/// holding point a forced full (bx 1) or empty (bx 0).
struct OutlineSeg
{
    enum Kind : int { line, arc, end, ellipse, spline, fill = 6 }
    Kind kind;
    double ax = 0, ay = 0, bx = 0, by = 0, mx = 0, my = 0;
    /// a spline a → b: the poles of its cubic Bézier pieces (x y each, three
    /// per piece and then b), joined into one curve
    double[] poles;
}

/// A piece of a path in space: a line a → b, or an arc a → b through m.
struct PathPiece
{
    bool arc;
    Vec3 a, b, m;
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
    Brep torus(double major, double minor);

    /// Profiles: planar faces on XY. Rectangle and circle are centred on the
    /// origin; polygon takes x0 y0 x1 y1 …; text starts at the origin on its
    /// baseline (`font`: family name or font file path).
    Brep rect(double w, double h);
    Brep circle(double r);
    Brep ellipse(double rx, double ry);
    Brep polygon(const(double)[] xy);
    /// A smooth closed curve through the points on XY, filled.
    Brep splineProfile(const(double)[] xy);
    Brep text(string s, double size, string font);
    /// Rounds the corners of a profile.
    Brep profileRound(Brep s, double r);
    /// Grows (d > 0) or shrinks (d < 0) a profile.
    Brep profileOffset(Brep s, double d);
    /// A solid grown (d > 0) or shrunk, round where it turns.
    Brep offset(Brep s, double d);
    /// How many edges and corners the bodies of `s` only touch along or at
    /// (a mesh of them is not a closed surface).
    int touching(Brep s);
    /// `s` with a rod of radius r along each of those edges and a ball at
    /// each of those corners, so its bodies overlap there.
    Brep bridgeTouching(Brep s, double r);
    /// Profile → solid along +Z (−Z if negative), `height` along the axis;
    /// a positive taper leans the sides in (holes widen), a negative one out.
    Brep extrude(Brep profile, double height, double taper);
    /// Profile → oblique prism: its top moved by (dx, dy) from its bottom, `height` up.
    Brep extrudeShear(Brep profile, double height, double dx, double dy);
    /// Profile → solid of revolution around an axis in its plane.
    Brep revolve(Brep profile, Vec3 origin, Vec3 direction, double angle);
    /// Outline segments: see OutlineSeg. Nested loops are holes, where loops
    /// overlap the overlap is one, and fills force an area.
    Brep outline(const(OutlineSeg)[] segs);
    /// The edges of a face's outer loop (no hole's), as indices into edges(s).
    int[] faceOuterEdges(Brep s, int face);
    /// A profile's parts: which 0 each region's outline without holes, 1 each hole filled, 2 each region.
    Brep[] profileParts(Brep p, int which);
    /// Every area the loops of an outline make, as faces: the `full` first, then the empty ones.
    Brep outlineRegions(const(OutlineSeg)[] segs, out int full);
    /// Paths (wires) for sweeps.
    Brep polyline(const(Vec3)[] pts, bool closed);
    Brep spline(const(Vec3)[] pts, bool closed);
    /// One chain of outline segments (see OutlineSeg; open or closed) as a path on XY.
    Brep outlinePath(const(OutlineSeg)[] segs);
    /// Lines and arcs end to end as a path.
    Brep pathOfPieces(const(PathPiece)[] pieces);
    /// Edges of `s` (indices into edges(s)) joined end to end into one path.
    Brep edgesPath(Brep s, const(int)[] edges);
    /// The curve that flat paths a and b both look like, seen across their
    /// planes (normals na and nb; zero: found from the path).
    Brep projectedCurve(Brep a, Brep b, Vec3 na, Vec3 nb);
    /// `taper`: the angle (radians) the helix's cone leans from the axis,
    /// widening as it rises when positive; 0, a cylinder of radius r.
    Brep helix(double r, double pitch, double height, bool left, double taper = 0);
    /// A right-handed ISO metric thread of major diameter d standing on z = 0, `length` tall, its
    /// ends chamfered by `chamfer` (0: square).
    Brep isoThread(double d, double pitch, double length, double chamfer);
    /// A right-handed thread band from its profile's corners (r z each, r at z = 0, over one
    /// lead), its helices on cones widening `slope` a unit up; from about two leads under z = 0
    /// to two over `length`: cut it to length.
    Brep threadBand(const(double)[] rz, double lead, double length, double slope);
    /// Point and tangent at the start (or end) of a path.
    void pathFrame(Brep path, bool atEnd, out Vec3 point, out Vec3 tangent);
    /// A solid through `rings` rings of `per` points each (ring after ring),
    /// one smooth surface closed round them, the end rings filled flat.
    Brep gridSolid(const(Vec3)[] pts, int rings, int per);
    /// A hollow solid through outer and inner rings: walls, a foot, a floor
    /// inside, and a flat rim joining the last rings (which lie in one plane).
    Brep gridHollow(const(Vec3)[] outer, int outerRings, const(Vec3)[] inner, int innerRings, int per);
    /// `n` points evenly along a path by length, ends included, with unit tangents.
    void pathSample(Brep path, int n, out Vec3[] points, out Vec3[] tangents);
    /// `twist`: radians the profile turns about the path from its start to
    /// its end, evenly along it.
    Brep sweep(Brep profile, Brep path, bool frenet, double twist = 0);
    /// The same, the profile's roll about the path decided by `angles`
    /// (radians, evenly along it, from where it would turn by itself), or kept
    /// towards `up` (non-zero), or towards the curve `guide` (non-null).
    Brep sweepRoll(Brep profile, Brep path, const(double)[] angles, Vec3 up, Brep guide);
    Brep loft(Brep[] profiles, bool ruled);
    /// Surfaces: through paths in order (not filled); the solids of `s` cut by
    /// a surface; a surface made `t` thick (on its normals' side; t < 0 the
    /// other); surfaces sewn along their edges into one closed solid.
    Brep loftOpen(Brep[] paths, bool ruled);
    Brep splitBy(Brep s, Brep tool);
    Brep thicken(Brep s, double t);
    /// The point of `s` nearest to `p`, and its face's normal there; false off its faces.
    bool normalAt(Brep s, Vec3 p, out Vec3 point, out Vec3 normal);
    Brep sew(Brep[] parts, double tolerance);
    /// Hidden-line projection: `dir` points from the model to the viewer.
    ViewSegment[] hiddenLines(Brep s, Vec3 dir, Vec3 up, double deflection);
    /// Boundary loops of a face as 3D polylines (outer and holes).
    Vec3[][] faceLoops(Brep s, int face, double deflection);

    Brep translate(Brep s, Vec3 v);
    /// Rotation around an axis through the origin.
    Brep rotate(Brep s, Vec3 axis, double angleRad);
    Brep scale(Brep s, double factor);
    /// A scale by its own factor along each axis, about the origin.
    Brep scaleXyz(Brep s, double sx, double sy, double sz);
    /// Mirror across the plane through the origin with the given normal.
    Brep mirror(Brep s, Vec3 normal);

    Brep boolean(Brep a, Brep b, BoolOp op);
    /// The same, with the result's faces that lie on one surface merged
    /// into one (what pushing or pulling a face should give).
    Brep booleanMerged(Brep a, Brep b, BoolOp op);
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
    /// Whether point `p` lies inside the solid (not on its surface).
    bool inside(Brep s, Vec3 p);
    /// Whether face `face` lies on a cylinder, and which.
    bool faceCylinder(Brep s, int face, out CylinderInfo info);
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
