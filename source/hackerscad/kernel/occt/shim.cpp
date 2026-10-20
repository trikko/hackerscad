// OpenCascade implementation of shim.h. Keep this file thin: anything that
// is not a direct kernel call belongs on the D side.
#include "shim.h"

#include <string>
#include <exception>

#include <Standard_Failure.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <Message_Report.hxx>
#include <Message_Alert.hxx>
#include <TopoDS.hxx>
#include <BRepGProp_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopLoc_Location.hxx>
#include <BRep_Tool.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <BRepBuilderAPI_GTransform.hxx>
#include <gp_GTrsf.hxx>
#include <gp_Elips.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <GProp_PrincipalProps.hxx>
#include <BRepBndLib.hxx>
#include <Bnd_Box.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <TopTools_DataMapOfShapeInteger.hxx>
#include <BOPAlgo_GlueEnum.hxx>
#include <ElSLib.hxx>
#include <BRepTopAdaptor_FClass2d.hxx>
#include <OSD_ThreadPool.hxx>
#include <GCPnts_QuasiUniformDeflection.hxx>
#include <BRepCheck_Shell.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepLProp_SLProps.hxx>
#include <Poly_Triangulation.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <Geom_Plane.hxx>
#include <STEPControl_Writer.hxx>
#include <STEPControl_Reader.hxx>
#include <Interface_Static.hxx>
#include <StepData_StepModel.hxx>
#include <StepBasic_Product.hxx>
#include <StepRepr_RepresentationItem.hxx>
#include <StepShape_Face.hxx>
#include <APIHeaderSection_MakeHeader.hxx>
#include <XSControl_WorkSession.hxx>
#include <XSControl_TransferWriter.hxx>
#include <XSControl_TransferReader.hxx>
#include <Transfer_FinderProcess.hxx>
#include <Transfer_TransientProcess.hxx>
#include <TransferBRep.hxx>
#include <TransferBRep_ShapeMapper.hxx>
#include <TCollection_HAsciiString.hxx>
#include <gp_Trsf.hxx>
#include <gp_Ax1.hxx>
#include <gp_Ax2.hxx>
#include <gp_Pln.hxx>
#include <map>
#include <mutex>
#include <vector>
#include <BRepTools_WireExplorer.hxx>
#include <Geom_OffsetSurface.hxx>
#include <ShapeFix_Shell.hxx>
#include <Geom2d_TrimmedCurve.hxx>
#include <TColgp_HArray1OfPnt2d.hxx>
#include <Geom2dAPI_Interpolate.hxx>
#include <Geom_SurfaceOfRevolution.hxx>
#include <Geom_ElementarySurface.hxx>
#include <GCE2d_MakeSegment.hxx>
#include <ShapeFix_Shape.hxx>
#include <Geom_RectangularTrimmedSurface.hxx>
#include <GeomConvert.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <Geom2dAPI_PointsToBSpline.hxx>
#include <TColgp_Array1OfPnt2d.hxx>
#include <array>
#include <initializer_list>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepFilletAPI_MakeFillet2d.hxx>
#include <ChFi2d_FilletAPI.hxx>
#include <BRepOffsetAPI_MakeOffset.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepOffsetAPI_MakePipeShell.hxx>
#include <BRepTools.hxx>
#include <BRepLib.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Geom_BSplineCurve.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColStd_HArray1OfReal.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GeomAPI_Interpolate.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_ConicalSurface.hxx>
#include <Geom2d_Line.hxx>
#include <TColgp_HArray1OfPnt.hxx>
#include <BRepAdaptor_CompCurve.hxx>
#include <GCPnts_UniformAbscissa.hxx>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <BRepCheck_Result.hxx>
#include <unordered_map>
#include <Geom_Line.hxx>
#include <TColStd_Array2OfReal.hxx>
#include <NCollection_DataMap.hxx>
#include <set>
#include <OSD_Parallel.hxx>
#include <cmath>
#include <LocOpe_DPrism.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <Font_FontMgr.hxx>
#include <StdPrs_BRepFont.hxx>
#include <TColStd_SequenceOfHAsciiString.hxx>
#include <cctype>
#include <StdPrs_BRepTextBuilder.hxx>
#include <gp_Circ.hxx>
#include <TopoDS_Compound.hxx>
#include <BRep_Builder.hxx>
#include <cstring>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <ShapeFix_Solid.hxx>
#include <ShapeFix_Face.hxx>
#include <TopoDS_Iterator.hxx>
#include <BRepGProp_Domain.hxx>
#include <BRepGProp_Vinert.hxx>
#include <IntCurvesFace_ShapeIntersector.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <ShapeUpgrade_FaceDivideArea.hxx>
#include <BRepOffset_MakeOffset.hxx>
#include <BRepOffsetAPI_MakeFilling.hxx>
#include <ShapeBuild_ReShape.hxx>
#include <BRepTools_History.hxx>
#include <memory>
#include <functional>
#include <TopoDS_Shell.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BOPAlgo_Builder.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <Geom_OffsetCurve.hxx>
#include <GeomConvert_ApproxCurve.hxx>
#include <GeomConvert_ApproxSurface.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <Precision.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_HSequenceOfShape.hxx>
#include <ShapeAnalysis_FreeBounds.hxx>
#include <ShapeAnalysis_Surface.hxx>
#include <BRepBuilderAPI_FindPlane.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepFill.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>

struct hc_shape {
    TopoDS_Shape shape;
    // sub-shape maps by kind, built on first use: indexed queries
    // (hc_face_info, hc_edge_info, …) would otherwise rebuild them per call
    mutable std::mutex lock;
    mutable std::map<int, TopTools_IndexedMapOfShape> maps;
    // whether it is a valid solid, once known (-1 not yet): set by the operation that made it when it
    // checked it already, so hc_is_valid does not check it again (on a face of hundreds of holes the
    // check grows with the square of its edges)
    mutable std::atomic<int> valid{-1};
    // its volume, when the operation that made it worked it out already (NaN: not known)
    double volume = std::numeric_limits<double>::quiet_NaN();
};

static thread_local std::string g_error;

// WORKAROUND (OpenCascade 7.9.3, Message): it reports progress on stdout,
// which would corrupt --json and MCP output. By design, not a bug: it stays.
static const bool g_silenced = [] {
    Message::DefaultMessenger()->ChangePrinters().Clear();
    return true;
}();

static void set_error(const char *msg) { g_error = msg ? msg : "unknown error"; }

// Runs f, converting OCCT and C++ exceptions into hc_last_error().
template <typename F, typename R>
static R guarded(R fail, F f)
{
    try {
        g_error.clear();
        return f();
    } catch (const Standard_Failure &e) {
        std::string msg = e.DynamicType()->Name();
        if (e.GetMessageString() && *e.GetMessageString())
            msg += std::string(": ") + e.GetMessageString();
        set_error(msg.c_str());
    } catch (const std::exception &e) {
        set_error(e.what());
    } catch (...) {
        set_error("unknown exception");
    }
    return fail;
}

struct Origin {
    int input, index;
};
// HCAD_TIMING set: how long the parts of the slow operations take, on stderr (to find where to speed up)
struct Stage {
    const char *name;
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    static bool on()
    {
        static const bool timing = getenv("HCAD_TIMING") != nullptr;
        return timing;
    }
    explicit Stage(const char *n) : name(n) {}
    ~Stage()
    {
        if (on())
            fprintf(stderr, "[timing] %s %.1f ms\n", name,
                    std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count());
    }
};

// HCAD_TIMING: the time since the previous lap, at each lap
struct Laps {
    std::chrono::steady_clock::time_point last = std::chrono::steady_clock::now();
    void lap(const char *name)
    {
        if (!Stage::on())
            return;
        const auto now = std::chrono::steady_clock::now();
        fprintf(stderr, "[timing]   %s %.1f ms\n", name, std::chrono::duration<double, std::milli>(now - last).count());
        last = now;
    }
};

static thread_local std::vector<Origin> g_history;
// faces made of more than one face (two merged into one, the face two operands share): the
// origins besides the first, by result face (its index from 0)
struct Also {
    int face;
    Origin origin;
};
static thread_local std::vector<Also> g_also;
// faces swept from an edge of an input (the side of an extrusion from a line of the profile): by
// result face, the input and the edge's index there (in its edge map)
static thread_local std::vector<Also> g_from_edge;
// the names of the faces of the shape a STEP file was read into (empty: none), by face
static thread_local std::vector<std::string> g_face_names;

// Every face of `result` is new: primitives and unknown operations.
static void history_new(const TopoDS_Shape &result)
{
    TopTools_IndexedMapOfShape res;
    TopExp::MapShapes(result, TopAbs_FACE, res);
    g_history.assign(res.Extent(), Origin{-1, -1});
    g_also.clear();
    g_from_edge.clear();
    g_face_names.clear();
}

// The faces of `result` that `mk` generated from the edges of `input` (input 0): recorded.
static void history_edges(BRepBuilderAPI_MakeShape &mk, const TopoDS_Shape &input, const TopoDS_Shape &result)
{
    TopTools_IndexedMapOfShape edges, res;
    TopExp::MapShapes(input, TopAbs_EDGE, edges);
    TopExp::MapShapes(result, TopAbs_FACE, res);
    for (int i = 1; i <= edges.Extent(); i++)
        for (TopTools_ListOfShape::Iterator it(mk.Generated(edges(i))); it.More(); it.Next())
            if (it.Value().ShapeType() == TopAbs_FACE)
                if (const int j = res.FindIndex(it.Value()); j > 0)
                    g_from_edge.push_back(Also{j - 1, Origin{0, i - 1}});
}

// Result face `j` (from 1) comes from `o`: its first origin, or one more.
static void history_from(int j, Origin o)
{
    Origin &h = g_history[j - 1];
    if (h.input < 0) {
        h = o;
        return;
    }
    if (h.input == o.input && h.index == o.index)
        return;
    for (const Also &a : g_also)
        if (a.face == j - 1 && a.origin.input == o.input && a.origin.index == o.index)
            return;
    g_also.push_back(Also{j - 1, o});
}

// Maps result faces back to the operand faces they were modified from (or
// kept unchanged); faces generated by the operation stay -1.
static void history_record(BRepBuilderAPI_MakeShape &mk, const std::vector<const TopoDS_Shape *> &inputs,
                           const TopoDS_Shape &result)
{
    history_new(result);
    TopTools_IndexedMapOfShape res;
    TopExp::MapShapes(result, TopAbs_FACE, res);
    int k = 0;
    for (const TopoDS_Shape *in : inputs) {
        TopTools_IndexedMapOfShape faces;
        TopExp::MapShapes(*in, TopAbs_FACE, faces);
        for (int i = 1; i <= faces.Extent(); i++) {
            const TopoDS_Shape &f = faces(i);
            const TopTools_ListOfShape &mods = mk.Modified(f);
            if (mods.IsEmpty()) {
                if (!mk.IsDeleted(f)) {
                    int j = res.FindIndex(f);
                    if (j > 0)
                        history_from(j, Origin{k, i - 1});
                }
                continue;
            }
            for (TopTools_ListOfShape::Iterator it(mods); it.More(); it.Next()) {
                int j = res.FindIndex(it.Value());
                if (j > 0)
                    history_from(j, Origin{k, i - 1});
            }
        }
        k++;
    }
}

static hc_shape *wrap(const TopoDS_Shape &s)
{
    if (s.IsNull()) {
        set_error("operation produced an empty shape");
        return nullptr;
    }
    return new hc_shape{s};
}

static hc_shape *transformed(const hc_shape *s, const gp_Trsf &t)
{
    return guarded<>((hc_shape *)nullptr, [&] {
        // Moving or turning a large shape (an imported mesh: thousands of
        // faces) only places it: a location, without copying its geometry;
        // the faces keep their order, so each comes from the same face of the
        // input. Small shapes are copied: later operations on located shapes
        // cost more than the copy (measured on the examples). Mirrors and
        // scales always need new geometry.
        int faces = 0;
        for (TopExp_Explorer f(s->shape, TopAbs_FACE); f.More() && faces <= 500; f.Next())
            faces++;
        if (faces > 500 && !t.IsNegative() && std::abs(t.ScaleFactor() - 1) < 1e-12) {
            TopoDS_Shape moved = s->shape.Moved(TopLoc_Location(t));
            history_new(moved);
            for (size_t i = 0; i < g_history.size(); i++)
                g_history[i] = Origin{0, (int)i};
            return wrap(moved);
        }
        BRepBuilderAPI_Transform mk(s->shape, t, true);
        history_record(mk, {&s->shape}, mk.Shape());
        return wrap(mk.Shape());
    });
}

// `h` marked as checked valid by the operation that made it (BRepCheck_Analyzer passed on its shape)
static hc_shape *checked(hc_shape *h)
{
    if (h)
        h->valid = 1;
    return h;
}

static hc_shape *primitive(const TopoDS_Shape &s)
{
    history_new(s);
    return wrap(s);
}

extern "C" {

const char *hc_last_error(void) { return g_error.c_str(); }

// the WORKAROUNDs below that a test can turn off (hc_workaround)
static std::atomic<bool> g_workarounds[6] = {{true}, {true}, {true}, {true}, {true}, {true}};
static bool workaround(int which) { return g_workarounds[which].load(); }

void hc_workaround(int which, int on)
{
    if (which >= 0 && which < 6)
        g_workarounds[which] = on != 0;
}

int hc_history_size(void) { return (int)g_history.size(); }

// The threads of OpenCascade's pool, which its parallel booleans and meshing share.
void hc_set_threads(int n)
{
    if (n >= 1)
        OSD_ThreadPool::DefaultPool()->Init(n);
}

void hc_history_get(int *input, int *index)
{
    for (size_t i = 0; i < g_history.size(); i++) {
        input[i] = g_history[i].input;
        index[i] = g_history[i].index;
    }
}

int hc_history_edges_size(void) { return (int)g_from_edge.size(); }

void hc_history_edges_get(int *face, int *input, int *index)
{
    for (size_t i = 0; i < g_from_edge.size(); i++) {
        face[i] = g_from_edge[i].face;
        input[i] = g_from_edge[i].origin.input;
        index[i] = g_from_edge[i].origin.index;
    }
}

int hc_history_also_size(void) { return (int)g_also.size(); }

void hc_history_also_get(int *face, int *input, int *index)
{
    for (size_t i = 0; i < g_also.size(); i++) {
        face[i] = g_also[i].face;
        input[i] = g_also[i].origin.input;
        index[i] = g_also[i].origin.index;
    }
}

void hc_shape_free(hc_shape *s) { delete s; }

hc_shape *hc_box(double dx, double dy, double dz)
{
    return guarded<>((hc_shape *)nullptr, [&] { return primitive(BRepPrimAPI_MakeBox(dx, dy, dz).Shape()); });
}

hc_shape *hc_cylinder(double r, double h)
{
    return guarded<>((hc_shape *)nullptr, [&] { return primitive(BRepPrimAPI_MakeCylinder(r, h).Shape()); });
}

hc_shape *hc_cone(double r1, double r2, double h)
{
    return guarded<>((hc_shape *)nullptr, [&] { return primitive(BRepPrimAPI_MakeCone(r1, r2, h).Shape()); });
}

hc_shape *hc_sphere(double r)
{
    return guarded<>((hc_shape *)nullptr, [&] { return primitive(BRepPrimAPI_MakeSphere(r).Shape()); });
}

// A torus round Z, centred on the origin: `major` from the axis to the
// middle of the tube, `minor` the tube's radius.
hc_shape *hc_torus(double major, double minor)
{
    return guarded<>((hc_shape *)nullptr, [&] { return primitive(BRepPrimAPI_MakeTorus(major, minor).Shape()); });
}

// ---------------------------------------------------------------- profiles

static TopoDS_Shape compound_of(const std::vector<TopoDS_Shape> &parts)
{
    if (parts.size() == 1)
        return parts[0];
    TopoDS_Compound c;
    BRep_Builder b;
    b.MakeCompound(c);
    for (auto &p : parts)
        b.Add(c, p);
    return c;
}

static std::vector<TopoDS_Face> faces_of(const TopoDS_Shape &s)
{
    std::vector<TopoDS_Face> r;
    TopTools_IndexedMapOfShape m;
    TopExp::MapShapes(s, TopAbs_FACE, m);
    for (int i = 1; i <= m.Extent(); i++)
        r.push_back(TopoDS::Face(m(i)));
    return r;
}

hc_shape *hc_rect(double w, double h)
{
    return guarded<>((hc_shape *)nullptr, [&] {
        BRepBuilderAPI_MakePolygon poly(gp_Pnt(-w / 2, -h / 2, 0), gp_Pnt(w / 2, -h / 2, 0), gp_Pnt(w / 2, h / 2, 0),
                                        gp_Pnt(-w / 2, h / 2, 0), Standard_True);
        return primitive(BRepBuilderAPI_MakeFace(poly.Wire(), Standard_True).Face());
    });
}

hc_shape *hc_circle(double r)
{
    return guarded<>((hc_shape *)nullptr, [&] {
        gp_Circ c(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), r);
        BRepBuilderAPI_MakeWire w(BRepBuilderAPI_MakeEdge(c).Edge());
        return primitive(BRepBuilderAPI_MakeFace(w.Wire(), Standard_True).Face());
    });
}

// An ellipse centred on the origin, rx along X and ry along Y (exact: one
// elliptic edge; OCCT wants the major radius first, so a taller one is
// turned a quarter round Z).
hc_shape *hc_ellipse(double rx, double ry)
{
    return guarded<>((hc_shape *)nullptr, [&] {
        const bool wide = rx >= ry;
        gp_Ax2 ax(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1), wide ? gp_Dir(1, 0, 0) : gp_Dir(0, 1, 0));
        gp_Elips e(ax, wide ? rx : ry, wide ? ry : rx);
        BRepBuilderAPI_MakeWire w(BRepBuilderAPI_MakeEdge(e).Edge());
        return primitive(BRepBuilderAPI_MakeFace(w.Wire(), Standard_True).Face());
    });
}

// The normal of a planar face as it is oriented, or false when the face is
// not planar.
static bool oriented_normal(const TopoDS_Face &f, gp_Dir &n)
{
    // from the surface's derivatives, the face's orientation applied: a mirrored plane's own axis is not it
    if (Handle(Geom_Plane)::DownCast(BRep_Tool::Surface(f)).IsNull())
        return false;
    BRepGProp_Face props(f);
    Standard_Real u0, u1, v0, v1;
    props.Bounds(u0, u1, v0, v1);
    gp_Pnt p;
    gp_Vec v;
    props.Normal((u0 + u1) / 2, (v0 + v1) / 2, p, v);
    if (v.Magnitude() < 1e-12)
        return false;
    n = gp_Dir(v);
    return true;
}

// Profiles face +Z whatever the winding of their outline: faces pointing
// opposite ways do not merge in 2D booleans.
static TopoDS_Face upward(TopoDS_Face f)
{
    gp_Dir n;
    if (oriented_normal(f, n) && n.Z() < 0)
        f.Reverse();
    return f;
}

// A planar face around a plane's origin, `size` on each side.
static TopoDS_Face plane_face(const gp_Pln &pln, double size)
{
    return BRepBuilderAPI_MakeFace(pln, -size, size, -size, size).Face();
}

// The solid cut by a plane: its faces on the plane, a profile where it lies.
hc_shape *hc_section(const hc_shape *s, const double origin[3], const double normal[3])
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        Bnd_Box bb;
        BRepBndLib::Add(s->shape, bb);
        if (bb.IsVoid()) {
            set_error("nothing to cut");
            return nullptr;
        }
        gp_Pnt o(origin[0], origin[1], origin[2]);
        double xmin, ymin, zmin, xmax, ymax, zmax;
        bb.Get(xmin, ymin, zmin, xmax, ymax, zmax);
        gp_Pnt mid((xmin + xmax) / 2, (ymin + ymax) / 2, (zmin + zmax) / 2);
        const double size = 2 * std::sqrt(bb.SquareExtent()) + o.Distance(mid) + 10;
        BRepAlgoAPI_Common common(s->shape, plane_face(gp_Pln(o, gp_Dir(normal[0], normal[1], normal[2])), size));
        if (!common.IsDone()) {
            set_error("the cut failed");
            return nullptr;
        }
        if (!TopExp_Explorer(common.Shape(), TopAbs_FACE).More()) {
            set_error("the plane does not cut the solid");
            return nullptr;
        }
        ShapeUpgrade_UnifySameDomain unify(common.Shape(), Standard_True, Standard_True, Standard_False);
        unify.Build();
        history_new(unify.Shape());
        return wrap(unify.Shape());
    });
}

hc_shape *hc_polygon(const double *xy, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (n < 3) {
            set_error("a polygon needs at least 3 points");
            return nullptr;
        }
        BRepBuilderAPI_MakePolygon poly;
        for (int i = 0; i < n; i++)
            poly.Add(gp_Pnt(xy[2 * i], xy[2 * i + 1], 0));
        poly.Close();
        if (!poly.IsDone()) {
            set_error("invalid polygon (repeated points?)");
            return nullptr;
        }
        BRepBuilderAPI_MakeFace f(poly.Wire(), Standard_True);
        if (!f.IsDone()) {
            set_error("the polygon is not a valid planar outline");
            return nullptr;
        }
        return primitive(upward(f.Face()));
    });
}

// A smooth closed curve through the points (x, y pairs) on XY, filled: a
// profile with curved sides, as the polygon with straight ones.
static Handle(Geom_BSplineCurve) closed_bezier_curve(const std::vector<gp_Pnt> &poles);

// A smooth closed outline through cubic Bézier pieces (their poles x y each, three a piece and then
// the first again: a closed spline as a sketch's, the same whichever point it starts at).
hc_shape *hc_spline_profile(const double *xy, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (n < 10 || (n - 1) % 3 != 0) {
            set_error("a smooth outline needs at least 3 points");
            return nullptr;
        }
        std::vector<gp_Pnt> poles;
        for (int i = 0; i < n; i++)
            poles.emplace_back(xy[2 * i], xy[2 * i + 1], 0);
        BRepBuilderAPI_MakeWire wire(BRepBuilderAPI_MakeEdge(closed_bezier_curve(poles)).Edge());
        BRepBuilderAPI_MakeFace f(wire.Wire(), Standard_True);
        if (!f.IsDone()) {
            set_error("the smooth outline is not a valid planar outline");
            return nullptr;
        }
        // a curve through the points can still cross itself: say so here, not at the loft
        BRepCheck_Analyzer check(f.Face());
        if (!check.IsValid()) {
            set_error("the smooth outline crosses itself: give the points in order around it, not too close");
            return nullptr;
        }
        return primitive(upward(f.Face()));
    });
}

hc_shape *hc_text(const char *utf8, double size, const char *font, int aspect, double spacing, double line_spacing)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        // loading a font takes tens of ms, and it caches the outlines of its
        // glyphs: keep one per font, style and size (per thread: evaluations
        // run on more than one)
        thread_local std::map<std::tuple<std::string, int, double>, Handle(StdPrs_BRepFont)> fonts;
        Handle(StdPrs_BRepFont) &f = fonts[std::make_tuple(std::string(font), aspect, size)];
        if (f.IsNull()) {
            Handle(StdPrs_BRepFont) loaded = new StdPrs_BRepFont();
            bool ok = std::strchr(font, '/') ? loaded->Init(NCollection_String(font), size, 0)
                                             : loaded->FindAndInit(TCollection_AsciiString(font), (Font_FontAspect)aspect, size);
            if (!ok) {
                set_error("font not found");
                return nullptr;
            }
            f = loaded;
        }
        TopoDS_Shape shape;
        if (spacing == 0 && line_spacing == 1) {
            StdPrs_BRepTextBuilder builder;
            shape = builder.Perform(*f, NCollection_String(utf8));
        } else {
            // letters spaced or lines apart: laid out one by one, each by its advance (with the
            // font's kerning) and the spacing; lines as the text builder lays them, the last on
            // the baseline
            std::vector<std::vector<Standard_Utf32Char>> lines(1);
            for (NCollection_Utf8Iter it(utf8); *it != 0; ++it)
                if (*it == '\n')
                    lines.emplace_back();
                else
                    lines.back().push_back(*it);
            BRep_Builder b;
            TopoDS_Compound c;
            b.MakeCompound(c);
            for (size_t l = 0; l < lines.size(); l++) {
                const double y = (lines.size() - 1 - l) * f->LineSpacing() * line_spacing;
                double x = 0;
                for (size_t i = 0; i < lines[l].size(); i++) {
                    const Standard_Utf32Char ch = lines[l][i], next = i + 1 < lines[l].size() ? lines[l][i + 1] : 0;
                    TopoDS_Shape glyph = f->RenderGlyph(ch);
                    if (!glyph.IsNull()) {
                        gp_Trsf t;
                        t.SetTranslation(gp_Vec(x, y, 0));
                        b.Add(c, glyph.Moved(TopLoc_Location(t)));
                    }
                    x += f->AdvanceX(ch, next) + spacing;
                }
            }
            shape = c;
        }
        if (shape.IsNull() || faces_of(shape).empty()) {
            set_error("the text produced no outline");
            return nullptr;
        }
        return primitive(shape);
    });
}

// The family a font name means, an alias ("Sans", "Serif") turned into the installed font it stands
// for; empty when none is installed.
const char *hc_font_family(const char *font)
{
    thread_local std::string name;
    name.clear();
    guarded<>(0, [&]() -> int {
        Font_FontAspect aspect = Font_FontAspect_Regular;
        Handle(Font_SystemFont) f = Font_FontMgr::GetInstance()->FindFont(TCollection_AsciiString(font),
                                                                           Font_StrictLevel_Aliases, aspect);
        if (!f.IsNull())
            name = f->FontName().ToCString();
        return 0;
    });
    return name.c_str();
}

// Every installed family, a line each: its name, a tab, and the styles it has as bits (1 regular,
// 2 bold, 4 italic, 8 bold italic). Other weights (Light, SemiBold…) are families of their own:
// "JetBrains Mono Light".
const char *hc_font_families()
{
    thread_local std::string list;
    list.clear();
    guarded<>(0, [&]() -> int {
        Handle(Font_FontMgr) mgr = Font_FontMgr::GetInstance();
        TColStd_SequenceOfHAsciiString names;
        mgr->GetAvailableFontsNames(names);
        for (int i = 1; i <= names.Length(); i++) {
            Font_FontAspect aspect = Font_FontAspect_Regular;
            Handle(Font_SystemFont) f = mgr->FindFont(names.Value(i)->String(), Font_StrictLevel_Strict, aspect);
            if (f.IsNull())
                continue;
            int styles = 0;
            for (int a = 0; a < Font_FontAspect_NB; a++)
                styles |= f->HasFontAspect((Font_FontAspect)a) ? 1 << a : 0;
            list += std::string(names.Value(i)->ToCString()) + "\t" + std::to_string(styles) + "\n";
        }
        return 0;
    });
    return list.c_str();
}

// Whether a font of that name (or an alias of one: "Sans", "Serif") is installed, with no fall-back
// to another: 1, 2 when it has not that style (Font_FontAspect: bold, italic); if not, 0, and the last error lists (a line each) up to four installed fonts whose names share
// a word with it, for a suggestion.
int hc_font_known(const char *font, int style)
{
    return guarded<>(0, [&]() -> int {
        Handle(Font_FontMgr) mgr = Font_FontMgr::GetInstance();
        Font_FontAspect aspect = (Font_FontAspect)style;
        Handle(Font_SystemFont) found = mgr->FindFont(TCollection_AsciiString(font), Font_StrictLevel_Aliases, aspect);
        if (!found.IsNull())
            return found->HasFontAspect((Font_FontAspect)style) ? 1 : 2;
        // the words of its name that say which font it is ("Sans", "Bold" or "Font" say little)
        static const std::set<std::string> plain = {"font", "sans", "serif", "mono", "regular", "bold", "italic",
                                                    "light", "medium", "black", "thin", "condensed", "the"};
        std::vector<std::string> words;
        std::string w;
        for (const char *c = font;; c++) {
            if (*c && std::isalnum((unsigned char)*c))
                w += (char)std::tolower((unsigned char)*c);
            else {
                if (w.size() > 2 && !plain.count(w))
                    words.push_back(w);
                w.clear();
                if (!*c)
                    break;
            }
        }
        // the installed ones with most of those words (or a word starting so: "Dejavu" for "DejaVuSans")
        TColStd_SequenceOfHAsciiString names;
        mgr->GetAvailableFontsNames(names);
        std::vector<std::pair<int, std::string>> ranked;
        for (int i = 1; i <= names.Length(); i++) {
            std::string name = names.Value(i)->ToCString(), lower;
            for (char c : name)
                lower += (char)std::tolower((unsigned char)c);
            int shared = 0;
            for (const std::string &word : words)
                if (lower.find(word) != std::string::npos)
                    shared++;
            if (shared)
                ranked.emplace_back(-shared, name);
        }
        std::stable_sort(ranked.begin(), ranked.end(),
                         [](const auto &a, const auto &b) { return a.first < b.first; });
        std::string similar;
        for (size_t i = 0; i < ranked.size() && i < 4; i++)
            similar += ranked[i].second + "\n";
        set_error(similar.c_str());
        return 0;
    });
}

static TopoDS_Shape faces_from_loops(const std::vector<TopoDS_Wire> &loops);

// Shapes made one by one from the separate regions of a profile, fused:
// where they overlap (grown into each other) they become one.
static TopoDS_Shape fused(const std::vector<TopoDS_Shape> &parts)
{
    if (parts.empty())
        throw Standard_Failure("the profile is empty");
    if (parts.size() == 1)
        return parts[0];
    TopTools_ListOfShape args, tools;
    args.Append(parts[0]);
    for (size_t i = 1; i < parts.size(); i++)
        tools.Append(parts[i]);
    BRepAlgoAPI_Fuse fuse;
    fuse.SetArguments(args);
    fuse.SetTools(tools);
    fuse.Build();
    if (!fuse.IsDone())
        throw Standard_Failure("could not merge the regions of the profile");
    ShapeUpgrade_UnifySameDomain unify(fuse.Shape(), Standard_True, Standard_True, Standard_False);
    unify.Build();
    return unify.Shape();
}

// Whether the outline of a face runs on smoothly through vertex v (the seam
// of a circle, a line running into an arc tangent to it): no corner there.
static bool smooth_at(const TopoDS_Face &face, const TopoDS_Vertex &v)
{
    std::vector<gp_Dir> tangents;
    for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
        const TopoDS_Edge edge = TopoDS::Edge(e.Current());
        BRepAdaptor_Curve c(edge);
        for (const TopoDS_Vertex &end : {TopExp::FirstVertex(edge), TopExp::LastVertex(edge)}) {
            if (!end.IsSame(v))
                continue;
            gp_Pnt p;
            gp_Vec t;
            c.D1(BRep_Tool::Parameter(end, edge), p, t);
            if (t.Magnitude() > 1e-12)
                tangents.push_back(gp_Dir(t));
        }
    }
    return tangents.size() == 2 && tangents[0].IsParallel(tangents[1], 1e-2);
}

// One closed outline with each of its corners rounded by r, convex or
// concave. Throws, naming the corner, when r does not fit.
static TopoDS_Wire rounded_loop(const TopoDS_Wire &w, double r)
{
    const TopoDS_Face face = upward(BRepBuilderAPI_MakeFace(w, Standard_True).Face());
    auto too_large = [&](const TopoDS_Vertex *v) {
        char msg[200];
        if (v) {
            const gp_Pnt p = BRep_Tool::Pnt(*v);
            std::snprintf(msg, sizeof msg, "r = %g mm is too large for the corner at (%g, %g) mm: its sides are too short",
                          r, std::abs(p.X()) < 1e-9 ? 0.0 : p.X(), std::abs(p.Y()) < 1e-9 ? 0.0 : p.Y());
        } else
            std::snprintf(msg, sizeof msg, "r = %g mm is too large for the corners: the roundings overlap", r);
        return Standard_Failure(msg);
    };
    // the edges in order round the outline, each with the vertex it starts at
    std::vector<TopoDS_Edge> edges;
    std::vector<TopoDS_Vertex> starts;
    bool curved = false;
    for (BRepTools_WireExplorer ex(w, face); ex.More(); ex.Next()) {
        edges.push_back(ex.Current());
        starts.push_back(ex.CurrentVertex());
        const GeomAbs_CurveType t = BRepAdaptor_Curve(ex.Current()).GetType();
        curved = curved || (t != GeomAbs_Line && t != GeomAbs_Circle);
    }
    const size_t n = edges.size();
    bool any = false;
    if (!curved) {
        // lines and arcs: the kernel's own 2D fillet, which also rounds a
        // side away entirely (a 10 mm square rounded by 5 mm is a circle)
        BRepFilletAPI_MakeFillet2d mk(face);
        for (const TopoDS_Vertex &v : starts) {
            if (smooth_at(face, v))
                continue;
            bool ok;
            try {
                mk.AddFillet(v, r);
                ok = mk.Status() == ChFi2d_IsDone;
            } catch (const Standard_Failure &) {
                ok = false;
            }
            if (!ok)
                throw too_large(&v);
            any = true;
        }
        if (!any)
            return w;
        mk.Build();
        if (!mk.IsDone() || !BRepCheck_Analyzer(mk.Shape()).IsValid())
            throw too_large(nullptr);
        return BRepTools::OuterWire(TopoDS::Face(mk.Shape()));
    }
    // other curves (text, splines): corner by corner, each side trimmed
    // where its rounding meets it, the arcs put in between
    const gp_Pln plane = BRepAdaptor_Surface(face).Plane();
    std::vector<TopoDS_Edge> arcs(n);
    for (size_t i = 0; n > 1 && i < n; i++) {
        // the corner where edge i ends and edge j starts
        const size_t j = (i + 1) % n;
        const TopoDS_Vertex &v = starts[j];
        if (smooth_at(face, v))
            continue;
        const gp_Pnt p = BRep_Tool::Pnt(v);
        ChFi2d_FilletAPI fillet(edges[i], edges[j], plane);
        if (!fillet.Perform(r) || fillet.NbResults(p) < 1)
            throw too_large(&v);
        arcs[i] = fillet.Result(p, edges[i], edges[j]);
        if (arcs[i].IsNull())
            throw too_large(&v);
        any = true;
    }
    if (!any)
        return w;
    BRepBuilderAPI_MakeWire mw;
    for (size_t i = 0; i < n; i++) {
        mw.Add(edges[i]);
        if (!arcs[i].IsNull())
            mw.Add(arcs[i]);
    }
    if (!mw.IsDone() || !mw.Wire().Closed())
        throw too_large(nullptr);
    BRepBuilderAPI_MakeFace f(mw.Wire(), Standard_True);
    if (!f.IsDone() || !BRepCheck_Analyzer(f.Face()).IsValid())
        throw too_large(nullptr);
    return mw.Wire();
}

hc_shape *hc_profile_round(const hc_shape *s, double r)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        // each outline and hole rounded on its own: a face with holes does
        // not round as one
        std::vector<TopoDS_Shape> out;
        for (const TopoDS_Face &face : faces_of(s->shape)) {
            std::vector<TopoDS_Wire> loops;
            for (TopExp_Explorer ex(face, TopAbs_WIRE); ex.More(); ex.Next()) {
                try {
                    loops.push_back(rounded_loop(TopoDS::Wire(ex.Current()), r));
                } catch (const Standard_Failure &e) {
                    set_error(e.GetMessageString());   // which corner, without the exception's name
                    return (hc_shape *)nullptr;
                }
            }
            out.push_back(faces_from_loops(loops));
        }
        return primitive(compound_of(out));
    });
}

// A solid grown (d > 0) or shrunk by d, round where it turns: the
// Minkowski sum with a ball of radius d, exactly. sharp: its faces moved out
// and extended until they meet, edges and corners staying sharp (far fewer
// faces on a many-faceted solid, a hull: quicker to work on after).
hc_shape *hc_offset_solid(const hc_shape *s, double d, int sharp)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (std::abs(d) < 1e-6) {
            // nothing to do: the solid as it is, each face its own
            history_new(s->shape);
            for (size_t i = 0; i < g_history.size(); i++)
                g_history[i] = Origin{0, (int)i};
            return wrap(s->shape);
        }
        // faces on one surface split by a union (two blocks side by side)
        // merged first: an edge between them confuses the offset
        ShapeUpgrade_UnifySameDomain unify(s->shape, Standard_True, Standard_True, Standard_False);
        unify.Build();
        // WORKAROUND (OpenCascade 7.9.3, BRepOffsetAPI_MakeOffsetShape): on
        // solids whose faces meet tangentially (Carlo's outline of tangent
        // arcs) it can fail, throw or return a broken solid at a tolerance of
        // 1e-6 and succeed at 1e-5: tried in turn, the first valid result kept.
        // The "known bugs" unittest in lang/tests.d turns this off
        // (HC_WORKAROUND_OFFSET_TOLERANCE: 1e-6 only) and fails once it works
        TopoDS_Shape r;
        // each face of the result from the face of the solid it is offset from
        std::vector<std::pair<TopoDS_Shape, int>> from;
        bool done = false;
        const std::vector<double> tols = workaround(HC_WORKAROUND_OFFSET_TOLERANCE)
            ? std::vector<double>{1e-6, 1e-5, 1e-4} : std::vector<double>{1e-6};
        for (double tol : tols) {
            try {
                BRepOffsetAPI_MakeOffsetShape off;
                off.PerformByJoin(unify.Shape(), d, tol, BRepOffset_Skin, Standard_False, Standard_False,
                                  sharp ? GeomAbs_Intersection : GeomAbs_Arc);
                if (!off.IsDone())
                    continue;
                done = true;
                TopoDS_Shape t = off.Shape();
                if (!TopExp_Explorer(t, TopAbs_SOLID).More()) {
                    BRepBuilderAPI_MakeSolid ms;
                    for (TopExp_Explorer e(t, TopAbs_SHELL); e.More(); e.Next())
                        ms.Add(TopoDS::Shell(e.Current()));
                    t = ms.Solid();
                }
                GProp_GProps p;
                BRepGProp::VolumeProperties(t, p);
                if (!t.IsNull() && p.Mass() > 0 && BRepCheck_Analyzer(t).IsValid()) {
                    r = t;
                    Handle(BRepTools_History) h = unify.History();
                    TopTools_IndexedMapOfShape m;
                    TopExp::MapShapes(s->shape, TopAbs_FACE, m);
                    for (int i = 1; i <= m.Extent(); i++) {
                        TopTools_ListOfShape merged;
                        if (h.IsNull() || (!h->IsRemoved(m(i)) && h->Modified(m(i)).IsEmpty()))
                            merged.Append(m(i));
                        else
                            merged = h->Modified(m(i));
                        for (TopTools_ListOfShape::Iterator u(merged); u.More(); u.Next()) {
                            for (TopTools_ListOfShape::Iterator o(off.Modified(u.Value())); o.More(); o.Next())
                                from.push_back({o.Value(), i - 1});
                            for (TopTools_ListOfShape::Iterator o(off.Generated(u.Value())); o.More(); o.Next())
                                from.push_back({o.Value(), i - 1});
                        }
                    }
                    break;
                }
            } catch (const Standard_Failure &) {
            }
        }
        if (r.IsNull()) {
            set_error(!done ? (d < 0 ? "the solid cannot shrink that much (would it vanish?)"
                                     : "the kernel could not grow the solid by that much")
                            : "offset gave a broken solid: try a smaller distance");
            return nullptr;
        }
        history_new(r);
        TopTools_IndexedMapOfShape res;
        TopExp::MapShapes(r, TopAbs_FACE, res);
        for (const auto &[f, i] : from)
            if (const int j = res.FindIndex(f); j > 0)
                history_from(j, Origin{0, i});
        return wrap(r);
    });
}

// Wire `w` with each offset curve (what the kernel's offset makes of an
// ellipse or a spline: the curve kept as "that one, d away") made a B-spline
// through it, to 1e-7 mm. Kept as offset curves, the faces they bound come
// out unorientable once the solid is copied (moved, turned): invalid.
// Lines and arcs stay what they are.
static TopoDS_Wire without_offset_curves(const TopoDS_Wire &w)
{
    bool any = false;
    for (TopExp_Explorer e(w, TopAbs_EDGE); e.More() && !any; e.Next()) {
        double f, l;
        Handle(Geom_Curve) c = BRep_Tool::Curve(TopoDS::Edge(e.Current()), f, l);
        any = !c.IsNull() && c->IsKind(STANDARD_TYPE(Geom_OffsetCurve));
    }
    if (!any)
        return w;
    BRepBuilderAPI_MakeWire mk;
    for (BRepTools_WireExplorer e(w); e.More(); e.Next()) {
        const TopoDS_Edge edge = e.Current();
        double f, l;
        Handle(Geom_Curve) c = BRep_Tool::Curve(edge, f, l);
        if (c.IsNull() || !c->IsKind(STANDARD_TYPE(Geom_OffsetCurve))) {
            mk.Add(edge);
            continue;
        }
        GeomConvert_ApproxCurve approx(new Geom_TrimmedCurve(c, f, l), 1e-7, GeomAbs_C2, 200, 9);
        if (!approx.HasResult())
            return w;   // left as it was: valid until copied
        Handle(Geom_Curve) b = approx.Curve();
        if (edge.Orientation() == TopAbs_REVERSED)
            b->Reverse();
        mk.Add(BRepBuilderAPI_MakeEdge(b).Edge());
    }
    if (!mk.IsDone() || !mk.Wire().Closed())
        return w;
    return mk.Wire();
}

// The loops of one outline (a face made of `w` alone) grown by d, or
// shrunk: outlines, and islands where a narrow part closed up. None when
// it vanished. Which way the kernel offsets follows how the loop runs: the
// area says whether it grew, and a wrong way is done again the other way.
static std::vector<TopoDS_Wire> offset_loop(const TopoDS_Wire &w, double d)
{
    const std::vector<TopoDS_Face> faces = faces_of(faces_from_loops({w}));
    if (faces.empty())
        return {};
    auto area = [](const TopoDS_Shape &f) {
        GProp_GProps p;
        BRepGProp::SurfaceProperties(f, p);
        return std::abs(p.Mass());
    };
    const double before = area(faces[0]);
    auto run = [&](double by) {
        std::vector<TopoDS_Wire> loops;
        BRepOffsetAPI_MakeOffset mk(faces[0], GeomAbs_Arc);
        mk.Perform(by);
        if (!mk.IsDone())
            return loops;
        for (TopExp_Explorer ex(mk.Shape(), TopAbs_WIRE); ex.More(); ex.Next())
            if (BRepBuilderAPI_MakeFace(TopoDS::Wire(ex.Current()), Standard_True).IsDone())
                loops.push_back(without_offset_curves(TopoDS::Wire(ex.Current())));
        return loops;
    };
    std::vector<TopoDS_Wire> loops = run(d);
    const double after = loops.empty() ? 0 : area(faces_from_loops(loops));
    if (d > 0 ? after < before : after > before)
        loops = run(-d);
    return loops;
}

// Whether no point of `face` lies farther than `depth` inside its outer loop (an inward offset that
// far leaves nothing): a grid of points over it against points close together round the loop, so up
// to a grid step out either way.
static bool shallower_than(const TopoDS_Face &face, double depth)
{
    Bnd_Box box;
    BRepBndLib::Add(face, box);
    double x0, y0, z0, x1, y1, z1;
    box.Get(x0, y0, z0, x1, y1, z1);
    const int g = 40;
    const double step = std::max(x1 - x0, y1 - y0) / g;
    std::vector<gp_Pnt> rim;
    for (TopExp_Explorer e(BRepTools::OuterWire(face), TopAbs_EDGE); e.More(); e.Next()) {
        BRepAdaptor_Curve c(TopoDS::Edge(e.Current()));
        const int k = std::max(2, (int)std::ceil(GCPnts_AbscissaPoint::Length(c) / (step / 4)));
        for (int i = 0; i <= k; i++)
            rim.push_back(c.Value(c.FirstParameter() + (c.LastParameter() - c.FirstParameter()) * i / k));
    }
    double u0, u1, v0, v1;
    BRepTools::UVBounds(face, u0, u1, v0, v1);
    BRepTopAdaptor_FClass2d inside(face, 1e-7);
    BRepAdaptor_Surface surf(face);
    double deepest = 0;
    for (int i = 0; i <= g; i++)
        for (int j = 0; j <= g; j++) {
            const gp_Pnt2d q(u0 + (u1 - u0) * i / g, v0 + (v1 - v0) * j / g);
            if (inside.Perform(q) != TopAbs_IN)
                continue;
            const gp_Pnt p = surf.Value(q.X(), q.Y());
            double nearest = 1e300;
            for (const gp_Pnt &r : rim)
                nearest = std::min(nearest, p.SquareDistance(r));
            deepest = std::max(deepest, std::sqrt(nearest));
        }
    return deepest <= depth + step;
}

hc_shape *hc_profile_offset(const hc_shape *s, double d)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<TopoDS_Shape> out;
        for (const TopoDS_Face &face : faces_of(s->shape)) {
            // the outline grown by d less each hole shrunk by d (or the other way when d < 0), exactly the
            // face's offset: each loop offset on its own, as a face of it alone faces +Z. The offset of the
            // face with its holes reads the holes' way from the face's orientation, and a face turned over
            // (an outline drawn clockwise, or mirrored) grew its holes, or left nothing
            const TopoDS_Wire outer = BRepTools::OuterWire(face);
            // shrunk to nothing (or to a line, of no area): the face is gone, the profile maybe all of it
            GProp_GProps before;
            BRepGProp::SurfaceProperties(face, before);
            std::vector<TopoDS_Wire> grown;
            try {
                grown = offset_loop(outer, d);
            } catch (Standard_Failure &) {
                if (d > 0)
                    throw;
            }
            if (grown.empty()) {
                if (d < 0 && shallower_than(face, -d))
                    continue;
                set_error("OpenCascade could not offset this outline");
                return nullptr;
            }
            TopoDS_Shape region = faces_from_loops(grown);
            for (TopExp_Explorer ex(face, TopAbs_WIRE); ex.More(); ex.Next()) {
                if (ex.Current().IsSame(outer))
                    continue;
                const std::vector<TopoDS_Wire> hole = offset_loop(TopoDS::Wire(ex.Current()), -d);
                if (hole.empty())
                    continue;   // closed up
                region = BRepAlgoAPI_Cut(region, faces_from_loops(hole)).Shape();
            }
            ShapeUpgrade_UnifySameDomain unify(region, Standard_True, Standard_True, Standard_False);
            unify.Build();
            GProp_GProps after;
            BRepGProp::SurfaceProperties(unify.Shape(), after);
            if (faces_of(unify.Shape()).empty() || std::abs(after.Mass()) <= 1e-9 * std::abs(before.Mass()))
                continue;
            out.push_back(unify.Shape());
        }
        // all of it shrunk away: an empty profile
        if (out.empty())
            return primitive(compound_of({}));
        // separate regions grown into each other become one
        return primitive(fused(out));
    });
}

// A solid made, checked: valid, closed outside in (a reversed one is turned
// round), along z from z0 to z1.
static bool sound_solid(TopoDS_Shape &r, double z0, double z1)
{
    if (r.IsNull() || !TopExp_Explorer(r, TopAbs_SOLID).More() || !BRepCheck_Analyzer(r).IsValid())
        return false;
    GProp_GProps p;
    BRepGProp::VolumeProperties(r, p);
    if (std::abs(p.Mass()) < 1e-9)
        return false;
    if (p.Mass() < 0)
        r.Reverse();
    Bnd_Box bb;
    BRepBndLib::Add(r, bb);
    double bx0, by0, bz0, bx1, by1, bz1;
    bb.Get(bx0, by0, bz0, bx1, by1, bz1);
    const double tol = 1e-4 + 1e-5 * std::abs(z1 - z0);
    return std::abs(bz0 - z0) < tol && std::abs(bz1 - z1) < tol;
}

// One face extruded `height` along its normal with its sides drafted by
// `taper`: the straight prism with every side tilted about the profile's
// plane, so they stay planes (cylinders become cones) and meet at sharp
// edges. Empty if the result is broken (a feature of the profile closed up
// on the way) or, `curved` set, a side cannot be drafted (not a plane,
// cylinder or cone).
static TopoDS_Shape drafted(const TopoDS_Face &face, double height, double taper_rad, bool &curved)
{
    curved = false;
    BRepAdaptor_Surface surf(face);
    const gp_Pln plane = surf.Plane();
    const gp_Dir up = height > 0 ? gp::DZ() : -gp::DZ();
    TopoDS_Shape prism = BRepPrimAPI_MakePrism(face, gp_Vec(0, 0, height)).Shape();
    BRepOffsetAPI_DraftAngle draft(prism);
    for (TopExp_Explorer e(prism, TopAbs_FACE); e.More(); e.Next()) {
        const TopoDS_Face side = TopoDS::Face(e.Current());
        BRepAdaptor_Surface ss(side);
        if (ss.GetType() == GeomAbs_Plane && ss.Plane().Axis().Direction().IsParallel(up, 1e-9))
            continue;   // the bottom or the top
        if (ss.GetType() != GeomAbs_Plane && ss.GetType() != GeomAbs_Cylinder && ss.GetType() != GeomAbs_Cone) {
            curved = true;
            return TopoDS_Shape();
        }
        // matter is taken away above the neutral plane for a positive angle
        draft.Add(side, up, taper_rad, plane);
        if (!draft.AddDone())
            return TopoDS_Shape();
    }
    draft.Build();
    if (!draft.IsDone())
        return TopoDS_Shape();
    TopoDS_Shape r = draft.Shape();
    const double z = plane.Location().Z(), z0 = std::min(z, z + height), z1 = std::max(z, z + height);
    if (!sound_solid(r, z0, z1))
        return TopoDS_Shape();
    // a round side that narrows to its apex and widens again past it (a
    // circle shrunk to nothing on the way up) is an hourglass, valid as a
    // shape but not the extrusion asked for
    const double tol = 1e-7 + 1e-7 * (z1 - z0);
    for (TopExp_Explorer e(r, TopAbs_FACE); e.More(); e.Next()) {
        BRepAdaptor_Surface ss(TopoDS::Face(e.Current()));
        if (ss.GetType() != GeomAbs_Cone)
            continue;
        const double apex = ss.Cone().Apex().Z();
        if (apex > z0 + tol && apex < z1 - tol)
            return TopoDS_Shape();
    }
    return r;
}

// A face bounded only by full circles (a disc, a ring, a plate of round
// holes) tapered as truncated cones, exactly: the draft of a cone whose top
// is small comes out invalid. Empty if the face has other edges, or an
// outline closes up or a hole reaches it on the way.
static TopoDS_Shape drafted_circles(const TopoDS_Face &face, double height, double taper_rad)
{
    struct Ring {
        gp_Pnt c;
        double r;
    };
    auto ring_of = [](const TopoDS_Wire &w, Ring &out) {
        int n = 0;
        for (TopExp_Explorer e(w, TopAbs_EDGE); e.More(); e.Next(), n++) {
            BRepAdaptor_Curve c(TopoDS::Edge(e.Current()));
            if (c.GetType() != GeomAbs_Circle || std::abs(c.LastParameter() - c.FirstParameter() - 2 * M_PI) > 1e-9)
                return false;
            out = Ring{c.Circle().Location(), c.Circle().Radius()};
        }
        return n == 1;
    };
    const TopoDS_Wire outer = BRepTools::OuterWire(face);
    Ring o;
    if (!ring_of(outer, o))
        return TopoDS_Shape();
    std::vector<Ring> holes;
    for (TopExp_Explorer e(face, TopAbs_WIRE); e.More(); e.Next()) {
        const TopoDS_Wire w = TopoDS::Wire(e.Current());
        if (w.IsSame(outer))
            continue;
        Ring h;
        if (!ring_of(w, h))
            return TopoDS_Shape();
        holes.push_back(h);
    }
    const double grow = std::abs(height) * std::tan(taper_rad);   // the outline shrinks by it, holes widen
    const double top = o.r - grow;
    if (top < -1e-9)
        return TopoDS_Shape();
    const gp_Dir dir = height > 0 ? gp::DZ() : -gp::DZ();
    auto cone = [&](const gp_Pnt &c, double r1, double r2) {
        return BRepPrimAPI_MakeCone(gp_Ax2(c, dir), r1, std::max(r2, 0.0), std::abs(height)).Shape();
    };
    TopoDS_Shape r = cone(o.c, o.r, top);
    for (const Ring &h : holes) {
        // a hole must stay inside the outline at both ends
        const double d = gp_Pnt(h.c.X(), h.c.Y(), 0).Distance(gp_Pnt(o.c.X(), o.c.Y(), 0));
        if (h.r + grow < 0 || d + h.r + grow > top + 1e-9)
            return TopoDS_Shape();
        r = BRepAlgoAPI_Cut(r, cone(h.c, h.r, h.r + grow)).Shape();
    }
    const double z = o.c.Z();
    if (!sound_solid(r, std::min(z, z + height), std::max(z, z + height)))
        return TopoDS_Shape();
    return r;
}

// Whether two round sides of the face meet (an arc next to an arc): the
// draft of such a prism can run for minutes in the intersection of the two
// cones (OpenCascade 7.9), so it is lofted instead.
static bool arcs_meet(const TopoDS_Face &face)
{
    for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next()) {
        std::vector<bool> round;
        for (BRepTools_WireExplorer e(TopoDS::Wire(w.Current())); e.More(); e.Next())
            round.push_back(BRepAdaptor_Curve(e.Current()).GetType() == GeomAbs_Circle);
        for (size_t i = 0; i < round.size() && round.size() > 1; i++)
            if (round[i] && round[(i + 1) % round.size()])
                return true;
    }
    return false;
}

// One face of lines and arcs extruded `height` with its sides drafted by
// `taper`, as a ruled loft from each outline to its top: there every line
// moved parallel towards the material, every arc concentric with its radius
// shrunk or grown, the corners where neighbours meet again (lines give
// planes, arcs cones, corners stay sharp, as drafted sides meet). Empty when
// an outline changes on the way (a side turns over, an arc shrinks to
// nothing: something closes up), it has other curves, or the result is not
// sound.
static TopoDS_Shape lofted(const TopoDS_Face &face, double height, double taper_rad)
{
    const double shrink = std::abs(height) * std::tan(taper_rad);
    const double z0 = BRepAdaptor_Surface(face).Plane().Location().Z(), z1 = z0 + height;
    Bnd_Box box;
    BRepBndLib::Add(face, box);
    const double size = std::sqrt(box.SquareExtent()), eps = 1e-4 * std::max(1.0, size), tol = 1e-7 * std::max(1.0, size);
    struct Side {
        bool arc;
        gp_XY a, b;       // ends, in the wire's order
        gp_XY c;          // arcs: centre
        double r = 0;     // arcs: radius
        bool ccw = true;  // arcs: the way from a to b
        gp_XY to;         // lines: towards the material (unit)
        bool inside;      // arcs: the material on the centre's side
    };
    auto cross = [](gp_XY u, gp_XY v) { return u.X() * v.Y() - u.Y() * v.X(); };
    // the wires: each side, and its top
    auto top_of = [&](const TopoDS_Wire &w, TopoDS_Wire &low, TopoDS_Wire &high) -> bool {
        std::vector<Side> sides;
        BRepBuilderAPI_MakeWire lowW;
        for (BRepTools_WireExplorer e(w, face); e.More(); e.Next()) {
            const TopoDS_Edge edge = e.Current();
            lowW.Add(edge);
            BRepAdaptor_Curve cv(edge);
            const bool rev = edge.Orientation() == TopAbs_REVERSED;
            gp_Pnt p0 = cv.Value(cv.FirstParameter()), p1 = cv.Value(cv.LastParameter());
            if (rev)
                std::swap(p0, p1);
            Side sd;
            sd.a = gp_XY(p0.X(), p0.Y());
            sd.b = gp_XY(p1.X(), p1.Y());
            gp_Pnt pm;
            gp_Vec tv;
            cv.D1((cv.FirstParameter() + cv.LastParameter()) / 2, pm, tv);
            if (rev)
                tv.Reverse();
            gp_XY left(-tv.Y(), tv.X());
            if (left.Modulus() < 1e-12)
                return false;
            left.Normalize();
            const gp_Pnt probe(pm.X() + left.X() * eps, pm.Y() + left.Y() * eps, pm.Z());
            const bool matterLeft = BRepClass_FaceClassifier(face, probe, tol).State() == TopAbs_IN;
            if (cv.GetType() == GeomAbs_Line) {
                sd.arc = false;
                sd.to = matterLeft ? left : -left;
            }
            else if (cv.GetType() == GeomAbs_Circle) {
                const gp_Circ ci = cv.Circle();
                sd.arc = true;
                sd.c = gp_XY(ci.Location().X(), ci.Location().Y());
                sd.r = ci.Radius();
                sd.ccw = (ci.Axis().Direction().Z() > 0) != rev;
                const gp_XY m(pm.X(), pm.Y());
                const gp_XY towards = matterLeft ? left : -left;
                sd.inside = (sd.c - m) * towards > 0;
            }
            else
                return false;
            sides.push_back(sd);
        }
        if (sides.empty())
            return false;
        lowW.Build();
        if (!lowW.IsDone())
            return false;
        low = lowW.Wire();
        // the sides moved: lines along `to`, arcs to their new radius
        std::vector<Side> moved = sides;
        for (Side &sd : moved)
            if (sd.arc) {
                sd.r += sd.inside ? -shrink : shrink;
                if (sd.r <= tol)
                    return false;
            }
            else {
                sd.a += sd.to * shrink;
                sd.b += sd.to * shrink;
            }
        // the corners: where neighbours meet now, nearest to where they met
        const size_t n = moved.size();
        std::vector<gp_XY> corner(n);
        auto tangent = [&](const Side &sd, bool atEnd) {
            if (!sd.arc)
                return (sd.b - sd.a).Normalized();
            gp_XY rad = (atEnd ? sd.b : sd.a) - sd.c;
            rad.Normalize();
            return sd.ccw ? gp_XY(-rad.Y(), rad.X()) : gp_XY(rad.Y(), -rad.X());
        };
        auto meet = [&](const Side &p, const Side &q, gp_XY near, gp_XY &out) -> bool {
            std::vector<gp_XY> pts;
            auto lineCircle = [&](gp_XY a, gp_XY d, gp_XY c, double r) {
                const gp_XY f = a - c;
                const double B = 2 * (f * d), C = f * f - r * r, A = d * d, disc = B * B - 4 * A * C;
                if (disc < -1e-12)
                    return;
                const double sq = std::sqrt(std::max(0.0, disc));
                pts.push_back(a + d * ((-B - sq) / (2 * A)));
                pts.push_back(a + d * ((-B + sq) / (2 * A)));
            };
            if (!p.arc && !q.arc) {
                const gp_XY d1 = p.b - p.a, d2 = q.b - q.a;
                const double den = cross(d1, d2);
                if (std::abs(den) < 1e-12)
                    return false;
                pts.push_back(p.a + d1 * (cross(q.a - p.a, d2) / den));
            }
            else if (!p.arc)
                lineCircle(p.a, p.b - p.a, q.c, q.r);
            else if (!q.arc)
                lineCircle(q.a, q.b - q.a, p.c, p.r);
            else {
                const gp_XY dc = q.c - p.c;
                const double d = dc.Modulus();
                if (d < 1e-12)
                    return false;
                const double a = (p.r * p.r - q.r * q.r + d * d) / (2 * d), h2 = p.r * p.r - a * a;
                if (h2 < -1e-9)
                    return false;
                const gp_XY m = p.c + dc * (a / d), perp(-dc.Y() / d, dc.X() / d);
                const double h = std::sqrt(std::max(0.0, h2));
                pts.push_back(m + perp * h);
                pts.push_back(m - perp * h);
            }
            if (pts.empty())
                return false;
            out = pts[0];
            for (const gp_XY &x : pts)
                if ((x - near).SquareModulus() < (out - near).SquareModulus())
                    out = x;
            return true;
        };
        for (size_t i = 0; i < n; i++) {
            const Side &p = sides[i], &q = sides[(i + 1) % n];
            const gp_XY v = p.b;
            if (std::abs(cross(tangent(p, true), tangent(q, false))) < 1e-6) {
                // meeting smoothly: the corner moves with both, along the normal
                gp_XY to = p.arc ? (v - p.c).Normalized() * (p.inside ? -1.0 : 1.0) : p.to;
                corner[i] = v + to * shrink;
            }
            else if (!meet(moved[i], moved[(i + 1) % n], v, corner[i]))
                return false;
        }
        // the top's sides between the new corners, each the same way round as below
        BRepBuilderAPI_MakeWire highW;
        for (size_t i = 0; i < n; i++) {
            const gp_XY a = corner[(i + n - 1) % n], b = corner[i];
            const Side &sd = moved[i], &orig = sides[i];
            TopoDS_Edge edge;
            if (!sd.arc) {
                if ((b - a) * (orig.b - orig.a) <= tol)
                    return false;   // turned over: it closed up
                edge = BRepBuilderAPI_MakeEdge(gp_Pnt(a.X(), a.Y(), z1), gp_Pnt(b.X(), b.Y(), z1));
            }
            else {
                const gp_Circ ci(gp_Ax2(gp_Pnt(sd.c.X(), sd.c.Y(), z1), sd.ccw ? gp::DZ() : -gp::DZ()), sd.r);
                auto sweep = [&](gp_XY c, gp_XY from, gp_XY to, bool ccw) {
                    double t = std::atan2(cross(from - c, to - c), (from - c) * (to - c));
                    if (!ccw)
                        t = -t;
                    if (t <= 0)
                        t += 2 * M_PI;
                    return t;
                };
                const bool whole = n == 1;
                if (whole)
                    edge = BRepBuilderAPI_MakeEdge(ci);
                else {
                    if (std::abs(sweep(sd.c, a, b, sd.ccw) - sweep(orig.c, orig.a, orig.b, orig.ccw)) > M_PI / 2)
                        return false;   // the arc turned over: it closed up
                    edge = BRepBuilderAPI_MakeEdge(ci, gp_Pnt(a.X(), a.Y(), z1), gp_Pnt(b.X(), b.Y(), z1));
                }
            }
            if (edge.IsNull())
                return false;
            highW.Add(edge);
        }
        highW.Build();
        if (!highW.IsDone())
            return false;
        high = highW.Wire();
        return true;
    };
    const TopoDS_Wire outer = BRepTools::OuterWire(face);
    TopoDS_Shape solid;
    std::vector<TopoDS_Shape> holes;
    for (TopExp_Explorer e(face, TopAbs_WIRE); e.More(); e.Next()) {
        const TopoDS_Wire w = TopoDS::Wire(e.Current());
        TopoDS_Wire low, high;
        if (!top_of(w, low, high))
            return TopoDS_Shape();
        BRepOffsetAPI_ThruSections loft(Standard_True, Standard_True);
        loft.CheckCompatibility(Standard_False);
        loft.AddWire(low);
        loft.AddWire(high);
        loft.Build();
        if (!loft.IsDone())
            return TopoDS_Shape();
        if (w.IsSame(outer))
            solid = loft.Shape();
        else
            holes.push_back(loft.Shape());
    }
    if (solid.IsNull())
        return TopoDS_Shape();
    for (const TopoDS_Shape &h : holes) {
        BRepAlgoAPI_Cut cut(solid, h);
        if (!cut.IsDone())
            return TopoDS_Shape();
        solid = cut.Shape();
    }
    if (!sound_solid(solid, std::min(z0, z1), std::max(z0, z1)))
        return TopoDS_Shape();
    return solid;
}

// Whether a round side of the face closes up before the top: an arc with the
// face's material on its centre's side narrows as the sides lean in, and is
// gone at height r / tan(taper). Told before drafting: the draft of a prism
// whose cones pass their apex can run for minutes instead of failing.
static bool closes_up(const TopoDS_Face &face, double height, double taper_rad)
{
    const double shrink = std::abs(height) * std::tan(std::abs(taper_rad));
    const double tol = 1e-6 + 1e-6 * std::abs(height);
    for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
        BRepAdaptor_Curve c(TopoDS::Edge(e.Current()));
        if (c.GetType() != GeomAbs_Circle)
            continue;
        const gp_Circ circ = c.Circle();
        if (shrink <= circ.Radius() + tol)
            continue;
        // halfway from the centre to the arc's middle: inside the face, the
        // material is on the centre's side
        const gp_Pnt mid = c.Value((c.FirstParameter() + c.LastParameter()) / 2);
        const gp_Pnt ctr = circ.Location();
        const gp_Pnt probe((ctr.X() + mid.X()) / 2, (ctr.Y() + mid.Y()) / 2, (ctr.Z() + mid.Z()) / 2);
        BRepClass_FaceClassifier inside(face, probe, 1e-7);
        const bool material = inside.State() == TopAbs_IN;
        // a positive taper leans the sides towards the material, a negative one away
        if (material == (taper_rad > 0))
            return true;
    }
    return false;
}

// A rounding that closes up at the very top (a profile offset inwards,
// tapered back out as far): `low`, made to just below the top, with its top
// face extruded straight the last `cap`. Empty when `low` is.
static TopoDS_Shape capped(const TopoDS_Face &face, const TopoDS_Shape &low, double height, double cap)
{
    TopoDS_Shape r;
    if (low.IsNull())
        return r;
    const double ztop = BRepAdaptor_Surface(face).Plane().Location().Z() + height - cap;
    for (TopExp_Explorer e(low, TopAbs_FACE); e.More() && r.IsNull(); e.Next()) {
        const TopoDS_Face top = TopoDS::Face(e.Current());
        BRepAdaptor_Surface ts(top);
        if (ts.GetType() != GeomAbs_Plane || !ts.Plane().Axis().Direction().IsParallel(gp::DZ(), 1e-9)
            || std::abs(ts.Plane().Location().Z() - ztop) > 1e-7)
            continue;
        TopoDS_Face t = top;
        t.Orientation(TopAbs_FORWARD);
        BRepAlgoAPI_Fuse fuse(low, BRepPrimAPI_MakePrism(t, gp_Vec(0, 0, cap)).Shape());
        if (!fuse.IsDone())
            break;
        ShapeUpgrade_UnifySameDomain unify(fuse.Shape(), Standard_True, Standard_True, Standard_False);
        unify.Build();
        r = unify.Shape();
        const double z = ztop - height + cap;
        if (!sound_solid(r, std::min(z, z + height), std::max(z, z + height)))
            r.Nullify();
    }
    return r;
}

hc_shape *hc_extrude_shear(const hc_shape *s, double height, double dx, double dy)
{
    // an oblique prism: the profile pushed along (dx, dy, height), staying parallel to itself
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        return primitive(BRepPrimAPI_MakePrism(s->shape, gp_Vec(dx, dy, height)).Shape());
    });
}

// A straight prism of a profile, quick however many edges it has: OpenCascade's
// MakePrism takes time growing with the square of a face's edges (its sweep
// asks of every edge whether it is closed on the face, looking through all
// of them), minutes for a grille of a thousand holes. Here each face is
// swept on its own, and a face of many edges loop by loop: the sides of
// each loop, the face below and its copy above, closed into a solid.
// `gen` (if given) gets each side face with the index of the edge of `shape` it was swept from.
static TopoDS_Shape quick_prism(const TopoDS_Shape &shape, double height,
                               std::vector<std::pair<TopoDS_Shape, int>> *gen = nullptr)
{
    const gp_Vec v(0, 0, height);
    std::vector<TopoDS_Shape> out;
    TopTools_IndexedMapOfShape edges;
    if (gen)
        TopExp::MapShapes(shape, TopAbs_EDGE, edges);
    auto sides = [&](BRepBuilderAPI_MakeShape &mk, const TopoDS_Shape &of) {
        if (!gen)
            return;
        for (TopExp_Explorer e(of, TopAbs_EDGE); e.More(); e.Next())
            if (const int i = edges.FindIndex(e.Current()); i > 0)
                for (TopTools_ListOfShape::Iterator it(mk.Generated(e.Current())); it.More(); it.Next())
                    if (it.Value().ShapeType() == TopAbs_FACE)
                        gen->push_back({it.Value(), i - 1});
    };
    for (const TopoDS_Face &face : faces_of(shape)) {
        int nedges = 0;
        for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next())
            nedges++;
        if (nedges < 200) {
            BRepPrimAPI_MakePrism prism(face, v);
            sides(prism, face);
            out.push_back(prism.Shape());
            continue;
        }
        BRep_Builder b;
        TopoDS_Shell shell;
        b.MakeShell(shell);
        // the face above: the same plane moved up, bounded by the loops' tops
        TopoDS_Face top;
        b.MakeFace(top, Handle(Geom_Surface)::DownCast(BRep_Tool::Surface(face)->Translated(v)),
                   BRep_Tool::Tolerance(face));
        const TopoDS_Face fwd = TopoDS::Face(face.Oriented(TopAbs_FORWARD));
        for (TopExp_Explorer w(fwd, TopAbs_WIRE); w.More(); w.Next()) {
            BRepPrimAPI_MakePrism side(w.Current(), v, Standard_False);
            sides(side, w.Current());
            for (TopExp_Explorer f(side.Shape(), TopAbs_FACE); f.More(); f.Next())
                b.Add(shell, f.Current());
            b.Add(top, side.LastShape(w.Current()));
        }
        b.Add(shell, fwd.Reversed());
        b.Add(shell, top);
        shell.Closed(Standard_True);
        TopoDS_Solid solid;
        b.MakeSolid(solid);
        b.Add(solid, shell);
        BRepLib::OrientClosedSolid(solid);
        GProp_GProps area, vol;
        BRepGProp::SurfaceProperties(face, area);
        BRepGProp::VolumeProperties(solid, vol);
        if (std::abs(vol.Mass() - area.Mass() * std::abs(height)) > 1e-6 * area.Mass() * std::abs(height)) {
            // not as it should be: the slow way
            BRepPrimAPI_MakePrism prism(face, v);
            sides(prism, face);
            out.push_back(prism.Shape());
        }
        else
            out.push_back(solid);
    }
    return compound_of(out);
}

hc_shape *hc_extrude(const hc_shape *s, double height, double taper_rad)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (taper_rad == 0) {
            std::vector<std::pair<TopoDS_Shape, int>> gen;
            const TopoDS_Shape r = quick_prism(s->shape, height, &gen);
            hc_shape *h = primitive(r);
            TopTools_IndexedMapOfShape res;
            TopExp::MapShapes(r, TopAbs_FACE, res);
            for (const auto &[f, i] : gen)
                if (const int j = res.FindIndex(f); j > 0)
                    g_from_edge.push_back(Also{j - 1, Origin{0, i}});
            return h;
        }
        if (std::abs(taper_rad) >= M_PI / 2 - 1e-6) {
            set_error("a taper must be less than 90°");
            return nullptr;
        }
        std::vector<TopoDS_Shape> out;
        for (const TopoDS_Face &face : faces_of(s->shape)) {
            if (closes_up(face, height, taper_rad)) {
                set_error("tapered extrusion failed: a rounded corner of the profile closes up before the top "
                          "(a corner of radius r, as .offset(r) or .round(r) make, lasts while height × tan(taper) ≤ "
                          "r: lower the height, or the taper to at most atan(r / height))");
                return nullptr;
            }
            bool curved = false;
            TopoDS_Shape r;
            // two arcs that meet: lofted, never drafted (the draft can hang);
            // an outline that changes on the way is one that closes up
            if (arcs_meet(face)) {
                r = lofted(face, height, taper_rad);
                const double cap = height > 0 ? 1e-3 : -1e-3;
                if (r.IsNull() && std::abs(height) > 2 * std::abs(cap))
                    r = capped(face, lofted(face, height - cap, taper_rad), height, cap);
                if (r.IsNull()) {
                    set_error("tapered extrusion failed: an edge or a corner of the profile closes up before the top "
                              "(lower the height or the taper)");
                    return nullptr;
                }
            }
            else
                r = drafted(face, height, taper_rad, curved);
            if (r.IsNull() && !curved)
                r = drafted_circles(face, height, taper_rad);
            const double cap = height > 0 ? 1e-3 : -1e-3;
            if (r.IsNull() && !curved && std::abs(height) > 2 * std::abs(cap))
                r = capped(face, drafted(face, height - cap, taper_rad, curved), height, cap);
            if (r.IsNull() && !curved) {
                set_error("tapered extrusion failed: an edge or a hole of the profile closes up before the top "
                          "(lower the height or the taper; a rounded corner of radius r, as .offset(r) or "
                          ".round(r) make, lasts while height × tan(taper) ≤ r: the taper at most atan(r / height))");
                return nullptr;
            }
            if (r.IsNull()) {
                // sides of splines: the draft prism, which measures its
                // height along the sides and grows along the face's normal
                TopoDS_Face f = face;
                BRepAdaptor_Surface surf(f);
                gp_Dir n = surf.Plane().Axis().Direction();
                if (f.Orientation() == TopAbs_REVERSED)
                    n.Reverse();
                if ((n.Z() > 0) != (height > 0))
                    f.Reverse();
                LocOpe_DPrism prism(f, std::abs(height) / std::cos(taper_rad), taper_rad);
                if (prism.IsDone())
                    r = prism.Shape();
                const double z = surf.Plane().Location().Z();
                if (!prism.IsDone() || !sound_solid(r, std::min(z, z + height), std::max(z, z + height))) {
                    set_error("tapered extrusion failed (taper too steep for the height?)");
                    return nullptr;
                }
            }
            out.push_back(r);
        }
        // regions that grow into each other on the way up overlap
        return primitive(fused(out));
    });
}

hc_shape *hc_revolve(const hc_shape *s, double ox, double oy, double oz, double dx, double dy, double dz, double angle_rad)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        gp_Ax1 axis(gp_Pnt(ox, oy, oz), gp_Dir(dx, dy, dz));
        Bnd_Box bb;
        BRepBndLib::Add(s->shape, bb);
        const double size = 2 * std::sqrt(bb.SquareExtent()) + axis.Location().Distance(bb.CornerMin()) + 10;
        for (const TopoDS_Face &face : faces_of(s->shape)) {
            BRepAdaptor_Surface surf(face);
            if (surf.GetType() != GeomAbs_Plane)
                continue;
            // the axis in the profile's plane: turned around any other, the
            // profile sweeps no volume
            const gp_Pln pln = surf.Plane();
            const gp_Dir n = pln.Axis().Direction();
            if (std::abs(n.Dot(axis.Direction())) > 1e-9 || pln.Distance(axis.Location()) > 1e-7 * size) {
                set_error("the axis must lie in the profile's plane");
                return nullptr;
            }
            // and the profile on one side of it, touching it at most: across
            // it the solid would pass through itself
            const gp_Ax3 frame(axis.Location(), n, axis.Direction());
            double area[2];
            for (int side = 0; side < 2; side++) {
                TopoDS_Face half = BRepBuilderAPI_MakeFace(gp_Pln(frame), -size, size, side ? -size : 0, side ? 0 : size);
                GProp_GProps p;
                BRepGProp::SurfaceProperties(BRepAlgoAPI_Common(face, half).Shape(), p);
                area[side] = std::abs(p.Mass());
            }
            if (std::min(area[0], area[1]) > 1e-7 * (area[0] + area[1]) + 1e-12) {
                set_error("the profile crosses the axis: it must lie on one side of it (touching it is fine)");
                return nullptr;
            }
        }
        BRepPrimAPI_MakeRevol revol(s->shape, axis, angle_rad);
        hc_shape *r = primitive(revol.Shape());
        history_edges(revol, s->shape, revol.Shape());
        return r;
    });
}

// ---------------------------------------------------------------- transforms

hc_shape *hc_translate(const hc_shape *s, double x, double y, double z)
{
    gp_Trsf t;
    t.SetTranslation(gp_Vec(x, y, z));
    return transformed(s, t);
}

hc_shape *hc_rotate(const hc_shape *s, double ax, double ay, double az, double angle_rad)
{
    return guarded<>((hc_shape *)nullptr, [&] {
        gp_Trsf t;
        t.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(ax, ay, az)), angle_rad);
        return transformed(s, t);
    });
}

hc_shape *hc_scale(const hc_shape *s, double factor)
{
    gp_Trsf t;
    t.SetScale(gp_Pnt(0, 0, 0), factor);
    return transformed(s, t);
}

// A scale by its own factor along X, Y and Z, about the origin: an
// ellipsoid from a sphere. The faces become freeform (B-splines): circles
// stretched are ellipses, and OCCT keeps no analytic surface for them.
hc_shape *hc_scale_xyz(const hc_shape *s, double sx, double sy, double sz)
{
    return guarded<>((hc_shape *)nullptr, [&] {
        gp_GTrsf t;
        t.SetValue(1, 1, sx);
        t.SetValue(2, 2, sy);
        t.SetValue(3, 3, sz);
        BRepBuilderAPI_GTransform mk(s->shape, t, true);
        history_record(mk, {&s->shape}, mk.Shape());
        return wrap(mk.Shape());
    });
}

hc_shape *hc_mirror(const hc_shape *s, double nx, double ny, double nz)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        gp_Trsf t;
        t.SetMirror(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(nx, ny, nz)));
        if (TopExp_Explorer(s->shape, TopAbs_SOLID).More() || !TopExp_Explorer(s->shape, TopAbs_FACE).More())
            return transformed(s, t);
        // a profile: made again from its mirrored outlines, as one drawn so. Mirrored as it is, its faces lie
        // on planes of left-handed axes, and offset (grown to nothing), unions (two faces left) and the
        // rest read the way they face wrong
        const TopoDS_Shape m = BRepBuilderAPI_Transform(s->shape, t, Standard_True).Shape();
        std::vector<TopoDS_Shape> out;
        for (const TopoDS_Face &face : faces_of(m)) {
            std::vector<TopoDS_Wire> loops;
            for (TopExp_Explorer ex(face, TopAbs_WIRE); ex.More(); ex.Next())
                loops.push_back(TopoDS::Wire(ex.Current()));
            out.push_back(faces_from_loops(loops));
        }
        // each face from the same face of the input, as a transform keeps them
        const TopoDS_Shape r = compound_of(out);
        history_new(r);
        if (g_history.size() == faces_of(s->shape).size())
            for (size_t k = 0; k < g_history.size(); k++)
                g_history[k] = Origin{0, (int)k};
        return wrap(r);
    });
}

// The result of a boolean of solids with the faces lying on one surface
// merged (two boxes side by side make one top face, not two with a seam
// between them), each merged face keeping the origin of one of the faces it
// was made of: the first operand's, the body's face rather than the tool's.
static TopoDS_Shape unify_history(const TopoDS_Shape &r);

static TopoDS_Shape unify_keeping_origins(BRepBuilderAPI_MakeShape &mk, const hc_shape *a, const hc_shape *b)
{
    const TopoDS_Shape r = mk.Shape();
    history_record(mk, {&a->shape, &b->shape}, r);
    return unify_history(r);
}

// `r`, whose history is recorded, with the faces on one surface merged, the history carried over
// to the merged faces.
static TopoDS_Shape unify_history(const TopoDS_Shape &r)
{
    std::vector<Origin> before = g_history;
    std::vector<Also> beforeAlso = g_also;
    TopTools_IndexedMapOfShape faces;
    TopExp::MapShapes(r, TopAbs_FACE, faces);
    ShapeUpgrade_UnifySameDomain unify(r, Standard_True, Standard_True, Standard_False);
    // merging can fail on some geometry ("Courbes non jointives"): the
    // boolean's own result then, with its faces as they are, rather than none
    try {
        unify.Build();
    } catch (const Standard_Failure &) {
        g_history = before;
        g_also = beforeAlso;
        return r;
    }
    const TopoDS_Shape u = unify.Shape();
    history_new(u);
    TopTools_IndexedMapOfShape merged;
    TopExp::MapShapes(u, TopAbs_FACE, merged);
    Handle(BRepTools_History) h = unify.History();
    for (int pass = 0; pass < 2; pass++)
        for (int i = 1; i <= faces.Extent(); i++) {
            const Origin o = before[i - 1];
            if (o.input < 0 || (pass == 0) != (o.input == 0))
                continue;
            const TopoDS_Shape &f = faces(i);
            // the merged face from every face it was made of, and from what each came from
            auto set = [&](const TopoDS_Shape &g) {
                int j = merged.FindIndex(g);
                if (j <= 0)
                    return;
                history_from(j, o);
                for (const Also &a : beforeAlso)
                    if (a.face == i - 1)
                        history_from(j, a.origin);
            };
            if (h.IsNull() || (!h->IsRemoved(f) && h->Modified(f).IsEmpty()))
                set(f);
            else
                for (TopTools_ListOfShape::Iterator it(h->Modified(f)); it.More(); it.Next())
                    set(it.Value());
        }
    return u;
}

// A boolean of solids whose result has the faces lying on one surface
// merged (a face pushed or pulled stays one face with its neighbours).
// What OpenCascade said about a boolean, its alerts' names ("SelfInterferingShape"…).
static std::vector<std::string> boolean_alerts(BRepAlgoAPI_BooleanOperation &mk, Message_Gravity gravity)
{
    std::vector<std::string> r;
    Handle(Message_Report) report = mk.GetReport();
    if (report.IsNull())
        return r;
    for (const Handle(Message_Alert) &alert : report->GetAlerts(gravity)) {
        std::string name = alert->DynamicType()->Name();
        const std::string prefix = "BOPAlgo_Alert";
        if (name.rfind(prefix, 0) == 0)
            name = name.substr(prefix.size());
        if (std::find(r.begin(), r.end(), name) == r.end())
            r.push_back(name);
    }
    return r;
}

// set by check_boolean when the failure is one a fuzzier try would only hide
static thread_local bool g_boolean_broken = false;

static double solid_volume(const TopoDS_Shape &s)
{
    GProp_GProps g;
    BRepGProp::VolumeProperties(s, g, 1e-6);
    return std::abs(g.Mass());
}

// The volume integrated to a relative 1e-3 instead of 1e-6: many times quicker on a face with hundreds
// of holes, and still exact to a few parts in a million there (Gauss points fixed per face, with no
// refinement, were 3% off on holes cut through a cone's wall)
static double quick_volume(const TopoDS_Shape &s)
{
    GProp_GProps g;
    BRepGProp::VolumeProperties(s, g, 1e-3);
    return std::abs(g.Mass());
}

// One face's part of a solid's volume: the volume of the cone from `apex` to the face, signed by the face's
// orientation, to a relative 1e-3; over every face of a solid, with the same apex, they add up to its
// volume (VolumeProperties takes an apex of its own for each shape it is given, so its volumes of single
// faces do not add up)
static double face_volume_term(const TopoDS_Face &f, const gp_Pnt &apex)
{
    BRepGProp_Face bf(f);
    if (!TopoDS_Iterator(f).More()) {
        BRepGProp_Vinert v(bf, apex, 1e-3);
        return v.Mass();
    }
    BRepGProp_Domain bd(f);
    BRepGProp_Vinert v(bf, bd, apex, 1e-3);
    return v.Mass();
}

// The volume by Gauss points fixed per face, with no refinement at all: quicker still, and off by up to a
// few percent on holes through a curved wall; only for checks with a wide margin
static double rough_volume(const TopoDS_Shape &s)
{
    GProp_GProps g;
    BRepGProp::VolumeProperties(s, g, Standard_True);
    return std::abs(g.Mass());
}

// A boolean's result, checked: OpenCascade's errors stop it; its warnings
// say the result may be wrong (a body or a piece left out without an
// error: an argument that runs into itself, faces nearly on each other),
// so then the volume of a solids' result must be one the operation can
// give, or the result is refused. `retry` builds it again with some
// fuzziness (for faces that nearly coincide), once.
static void check_boolean(BRepAlgoAPI_BooleanOperation &mk, const TopoDS_Shape &a, const TopoDS_Shape &b, int op)
{
    auto list = [](const std::vector<std::string> &names) {
        std::string r;
        for (auto &n : names)
            r += (r.empty() ? "" : ", ") + n;
        return r;
    };
    if (mk.HasErrors() || !mk.IsDone())
        throw Standard_Failure(("the boolean operation failed (" + list(boolean_alerts(mk, Message_Fail)) + ")").c_str());
    if (!mk.HasWarnings())
        return;
    const auto warnings = boolean_alerts(mk, Message_Warning);
    const bool solids = TopExp_Explorer(a, TopAbs_SOLID).More() && TopExp_Explorer(b, TopAbs_SOLID).More();
    // these say the topology broke: pieces dropped without a word (a fuzzier try hides them, it does not
    // mend them); the others (edges too small, edges a face did not use) can come with a right result:
    // its volume tells
    for (auto &w : warnings)
        if (w == "SelfInterferingShape" || w == "AcquiredSelfIntersection") {
            g_boolean_broken = true;
            throw Standard_Failure(("OpenCascade could not combine these solids: the result would miss pieces (it "
                                    "warns: " + list(warnings) + "; a solid through rings or a sweep that folds on "
                                    "itself, or faces nearly on each other?)").c_str());
        }
    if (!solids)
        return;
    const double va = solid_volume(a), vb = solid_volume(b), vr = solid_volume(mk.Shape());
    const double tol = 1e-4 * (va + vb) + 1e-3;
    double lo = 0, hi = 0;
    switch (op) {
    case HC_FUSE: lo = std::max(va, vb); hi = va + vb; break;
    case HC_CUT: lo = std::max(0.0, va - vb); hi = va; break;
    default: lo = 0; hi = std::min(va, vb); break;
    }
    if (vr < lo - tol || vr > hi + tol)
        throw Standard_Failure(("the boolean operation gave a wrong result (volume " + std::to_string(vr) +
                                " mm³, it can only be between " + std::to_string(lo) + " and " + std::to_string(hi) +
                                "; OpenCascade warns: " + list(warnings) + ")").c_str());
}

hc_shape *hc_boolean_merged(const hc_shape *a, const hc_shape *b, int op)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::unique_ptr<BRepAlgoAPI_BooleanOperation> mk;
        switch (op) {
        case HC_FUSE: mk.reset(new BRepAlgoAPI_Fuse(a->shape, b->shape)); break;
        case HC_CUT: mk.reset(new BRepAlgoAPI_Cut(a->shape, b->shape)); break;
        case HC_COMMON: mk.reset(new BRepAlgoAPI_Common(a->shape, b->shape)); break;
        default: set_error("invalid boolean operation"); return nullptr;
        }
        check_boolean(*mk, a->shape, b->shape, op);
        return wrap(unify_keeping_origins(*mk, a, b));
    });
}

// Profile `s` with its faces that lie on the plane of `like`'s first face
// but face the other way turned over, so that the two fuse into one face:
// a profile mirrored or turned half round faces -Z, and faces facing
// opposite ways are not merged into one.
static TopoDS_Shape facing_like(const TopoDS_Shape &like, const TopoDS_Shape &s)
{
    TopExp_Explorer first(like, TopAbs_FACE);
    gp_Dir n;
    if (!first.More() || !oriented_normal(TopoDS::Face(first.Current()), n))
        return s;
    bool any = false;
    for (TopExp_Explorer e(s, TopAbs_FACE); e.More(); e.Next()) {
        gp_Dir m;
        if (oriented_normal(TopoDS::Face(e.Current()), m) && m.Dot(n) < -1 + 1e-9)
            any = true;
    }
    if (!any)
        return s;
    BRep_Builder builder;
    TopoDS_Compound c;
    builder.MakeCompound(c);
    for (TopExp_Explorer e(s, TopAbs_FACE); e.More(); e.Next()) {
        gp_Dir m;
        const TopoDS_Face &f = TopoDS::Face(e.Current());
        builder.Add(c, oriented_normal(f, m) && m.Dot(n) < -1 + 1e-9 ? f.Reversed() : TopoDS_Shape(f));
    }
    return c;
}

hc_shape *hc_boolean(const hc_shape *a, const hc_shape *b, int op)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        // two profiles: the second facing the way the first does
        const bool flat = !TopExp_Explorer(a->shape, TopAbs_SOLID).More() && !TopExp_Explorer(b->shape, TopAbs_SOLID).More();
        const TopoDS_Shape tool = flat ? facing_like(a->shape, b->shape) : b->shape;
        auto run = [&](BRepAlgoAPI_BooleanOperation &&mk) -> hc_shape * {
            TopoDS_Shape r = mk.Shape();
            // a union of solids: faces on one plane or surface become one, or
            // a chamfer or fillet along the seam between them fails
            if (op == HC_FUSE && TopExp_Explorer(r, TopAbs_SOLID).More())
                return wrap(unify_keeping_origins(mk, a, b));
            if (TopExp_Explorer(r, TopAbs_SOLID).More() || !TopExp_Explorer(r, TopAbs_FACE).More()) {
                history_record(mk, {&a->shape, &b->shape}, r);
                return wrap(r);
            }
            // profiles: the pieces of a 2D boolean share edges; merge them back
            // into one face per region, or extrusions become glued solids
            ShapeUpgrade_UnifySameDomain unify(r, Standard_True, Standard_True, Standard_False);
            unify.Build();
            history_new(unify.Shape());
            return wrap(unify.Shape());
        };
        // on every core: the intersections of the faces of one with the other
        // go in parallel (the random vase example: 1.56 s → 1.23 s)
        auto parallel = [&](BRepAlgoAPI_BooleanOperation &&mk, double fuzzy) -> hc_shape * {
            TopTools_ListOfShape args, tools;
            args.Append(a->shape);
            tools.Append(tool);
            mk.SetArguments(args);
            mk.SetTools(tools);
            mk.SetRunParallel(Standard_True);
            if (fuzzy > 0)
                mk.SetFuzzyValue(fuzzy);
            mk.Build();
            check_boolean(mk, a->shape, tool, op);
            return run(std::move(mk));
        };
        auto make = [&](double fuzzy) -> hc_shape * {
            switch (op) {
            case HC_FUSE: return parallel(BRepAlgoAPI_Fuse(), fuzzy);
            case HC_CUT: return parallel(BRepAlgoAPI_Cut(), fuzzy);
            case HC_COMMON: return parallel(BRepAlgoAPI_Common(), fuzzy);
            default: throw Standard_Failure("invalid boolean operation");
            }
        };
        // faces that nearly coincide can make it go wrong: then once more, with a little fuzziness
        g_boolean_broken = false;
        try {
            return make(0);
        } catch (const Standard_Failure &first) {
            if (g_boolean_broken)
                throw;
            try {
                return make(1e-5);
            } catch (const Standard_Failure &) {
                throw first;
            }
        }
    });
}

// `a` less all of `tools` in one boolean: much quicker than one cut at a time
// (400 holes in a plate: a cut each grows the plate's faces, and every next
// cut goes through them all again). Each face remembers where it came from:
// input 0 is `a`, input i + 1 the tool i.
hc_shape *hc_cut_all(const hc_shape *a, const hc_shape *const *tools, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        BRepAlgoAPI_Cut mk;
        TopTools_ListOfShape args, ts;
        args.Append(a->shape);
        for (int i = 0; i < n; i++)
            ts.Append(tools[i]->shape);
        mk.SetArguments(args);
        mk.SetTools(ts);
        mk.SetRunParallel(Standard_True);
        mk.Build();
        if (!mk.IsDone() || mk.HasErrors())
            throw Standard_Failure("the cut failed");
        const TopoDS_Shape r = mk.Shape();
        history_new(r);
        TopTools_IndexedMapOfShape res;
        TopExp::MapShapes(r, TopAbs_FACE, res);
        auto record = [&](const TopoDS_Shape &in, int k) {
            TopTools_IndexedMapOfShape faces;
            TopExp::MapShapes(in, TopAbs_FACE, faces);
            for (int i = 1; i <= faces.Extent(); i++) {
                const TopTools_ListOfShape &mods = mk.Modified(faces(i));
                if (mods.IsEmpty()) {
                    const int j = res.FindIndex(faces(i));
                    if (j > 0)
                        history_from(j, Origin{k, i - 1});
                    continue;
                }
                for (TopTools_ListOfShape::Iterator it(mods); it.More(); it.Next()) {
                    const int j = res.FindIndex(it.Value());
                    if (j > 0)
                        history_from(j, Origin{k, i - 1});
                }
            }
        };
        record(a->shape, 0);
        for (int i = 0; i < n; i++)
            record(tools[i]->shape, i + 1);
        return wrap(r);
    });
}

// Tiles: copies of the motif faces, each placed by four numbers in `place`
// (which motif, dx, dy, a scale about the motif's origin), gathered into one
// compound. mode 1 cuts them to `region` (only those crossing its border go
// through the boolean, the pieces smaller than minArea left out), mode 2 keeps
// only those wholly inside it. Plus 4: the cells touch one another (no gap
// between them), joined into one face per area they cover.
hc_shape *hc_tiles(const hc_shape *const *motifs, int nm, const double *place, int n, const hc_shape *region,
                   int flags, double minArea)
{
    Stage stage("tiles");
    const int mode = flags & 3;
    const bool merge = flags & 4;
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        // the region's faces, each with a classifier in its own parameters made once (one made for every
        // point took most of the time of a knurl's thousands of cells) and its box, to skip it at once
        struct Area {
            TopoDS_Face face;
            Handle(Geom_Surface) surf;
            std::unique_ptr<BRepTopAdaptor_FClass2d> in;
            Bnd_Box box;
        };
        std::vector<Area> rfaces;
        if (region)
            for (const TopoDS_Face &f : faces_of(region->shape)) {
                Area a;
                a.face = f;
                a.surf = BRep_Tool::Surface(f);
                a.in = std::make_unique<BRepTopAdaptor_FClass2d>(f, 1e-6);
                BRepBndLib::Add(f, a.box);
                a.box.Enlarge(1e-6);
                rfaces.push_back(std::move(a));
            }
        auto inside = [&](const gp_Pnt &p) {
            for (const Area &a : rfaces) {
                if (a.box.IsOut(p))
                    continue;
                GeomAPI_ProjectPointOnSurf on(p, a.surf);
                if (on.NbPoints() == 0 || on.LowerDistance() > 1e-6)
                    continue;
                double u, v;
                on.LowerDistanceParameters(u, v);
                if (a.in->Perform(gp_Pnt2d(u, v)) == TopAbs_IN)
                    return true;
            }
            return false;
        };
        // each motif's points round its edges (four an edge), sampled once
        std::vector<std::vector<gp_Pnt>> samples(nm);
        for (int m = 0; m < nm; m++)
            for (TopExp_Explorer e(motifs[m]->shape, TopAbs_EDGE); e.More(); e.Next()) {
                BRepAdaptor_Curve c(TopoDS::Edge(e.Current()));
                for (int k = 0; k < 4; k++)
                    samples[m].push_back(c.Value(c.FirstParameter() + (c.LastParameter() - c.FirstParameter()) * k / 4));
            }
        std::vector<TopoDS_Shape> kept, border;
        for (int i = 0; i < n; i++) {
            const int m = (int)place[4 * i];
            if (m < 0 || m >= nm)
                continue;
            gp_Trsf sc, mv;
            if (std::abs(place[4 * i + 3] - 1) > 1e-12)
                sc.SetScale(gp_Pnt(0, 0, 0), place[4 * i + 3]);
            mv.SetTranslation(gp_Vec(place[4 * i + 1], place[4 * i + 2], 0));
            const gp_Trsf tr = mv * sc;
            // whether every point sampled round its edges lies inside the region
            bool whole = true;
            if (mode != 0)
                for (const gp_Pnt &q : samples[m])
                    if (!inside(q.Transformed(tr))) {
                        whole = false;
                        break;
                    }
            if (!whole && mode != 1)
                continue;
            const TopoDS_Shape t = BRepBuilderAPI_Transform(motifs[m]->shape, tr, true).Shape();
            (whole ? kept : border).push_back(t);
        }
        Laps laps;
        laps.lap("tiles: placed and sorted");
        if (!border.empty()) {
            BRepAlgoAPI_Common mk;
            TopTools_ListOfShape args, tools;
            for (auto &b : border)
                args.Append(b);
            tools.Append(region->shape);
            mk.SetArguments(args);
            mk.SetTools(tools);
            mk.SetRunParallel(Standard_True);
            mk.Build();
            if (!mk.IsDone() || mk.HasErrors())
                throw Standard_Failure("the tiles could not be cut to the region");
            // the slivers of cells the border cuts off, too small to print or to lay on a curved face, left out
            for (const TopoDS_Face &f : faces_of(mk.Shape())) {
                GProp_GProps g;
                BRepGProp::SurfaceProperties(f, g);
                if (g.Mass() >= minArea)
                    kept.push_back(f);
            }
        }
        laps.lap("tiles: border cells cut");
        if (kept.empty()) {
            set_error("no tile lies in the region (are the tiles larger than it?)");
            return nullptr;
        }
        // cells sharing their sides would make a profile that overlaps itself along them: a fuse of
        // all of them (each one argument, so that they meet), then one face per area
        if (merge && kept.size() > 1) {
            TopTools_ListOfShape args, tools;
            args.Append(kept[0]);
            for (size_t i = 1; i < kept.size(); i++)
                tools.Append(kept[i]);
            BRepAlgoAPI_Fuse fuse;
            fuse.SetArguments(args);
            fuse.SetTools(tools);
            fuse.SetRunParallel(Standard_True);
            fuse.Build();
            if (!fuse.IsDone() || fuse.HasErrors())
                throw Standard_Failure("the touching tiles could not be joined");
            ShapeUpgrade_UnifySameDomain unify(fuse.Shape(), Standard_True, Standard_True, Standard_False);
            unify.Build();
            laps.lap("tiles: touching cells joined");
            return primitive(unify.Shape());
        }
        return primitive(compound_of(kept));
    });
}

// All the shapes joined in one general fuse: much faster than one union at
// a time when there are many (the pieces of a Minkowski sum).
hc_shape *hc_fuse_all(const hc_shape *const *shapes, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (n < 1) {
            set_error("nothing to join");
            return nullptr;
        }
        if (n == 1) {
            history_new(shapes[0]->shape);
            for (size_t i = 0; i < g_history.size(); i++)
                g_history[i] = Origin{0, (int)i};
            return wrap(shapes[0]->shape);
        }
        TopTools_ListOfShape args, tools;
        std::vector<const TopoDS_Shape *> inputs;
        args.Append(shapes[0]->shape);
        for (int i = 0; i < n; i++)
            inputs.push_back(&shapes[i]->shape);
        for (int i = 1; i < n; i++)
            tools.Append(shapes[i]->shape);
        BRepAlgoAPI_Fuse fuse;
        fuse.SetArguments(args);
        fuse.SetTools(tools);
        fuse.SetRunParallel(Standard_True);
        fuse.Build();
        if (!fuse.IsDone()) {
            set_error("joining the pieces failed");
            return nullptr;
        }
        // input i is shapes[i]
        history_record(fuse, inputs, fuse.Shape());
        return wrap(unify_history(fuse.Shape()));
    });
}

static const TopTools_IndexedMapOfShape &map_of(const hc_shape *s, TopAbs_ShapeEnum kind)
{
    std::lock_guard<std::mutex> guard(s->lock);
    auto it = s->maps.find(kind);
    if (it == s->maps.end()) {
        it = s->maps.emplace(kind, TopTools_IndexedMapOfShape()).first;
        TopExp::MapShapes(s->shape, kind, it->second);
    }
    return it->second;
}

// Where the bodies of a shape touch only along an edge or at a corner: edges
// with more than two faces or the faces of two solids, and corners shared by
// two solids along no such edge. A mesh of them is not a closed surface.
static void touching_places(const TopoDS_Shape &s, std::vector<TopoDS_Edge> &edges, std::vector<TopoDS_Vertex> &corners)
{
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces, edgeSolids, vertexSolids, vertexEdges;
    TopExp::MapShapesAndAncestors(s, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    TopExp::MapShapesAndAncestors(s, TopAbs_EDGE, TopAbs_SOLID, edgeSolids);
    TopExp::MapShapesAndAncestors(s, TopAbs_VERTEX, TopAbs_SOLID, vertexSolids);
    TopExp::MapShapesAndAncestors(s, TopAbs_VERTEX, TopAbs_EDGE, vertexEdges);
    auto distinct = [](const TopTools_ListOfShape &l) {
        TopTools_IndexedMapOfShape m;
        for (TopTools_ListOfShape::Iterator it(l); it.More(); it.Next())
            m.Add(it.Value());
        return m.Extent();
    };
    TopTools_IndexedMapOfShape bad;
    for (int i = 1; i <= edgeFaces.Extent(); i++) {
        const TopoDS_Edge e = TopoDS::Edge(edgeFaces.FindKey(i));
        if (BRep_Tool::Degenerated(e))
            continue;
        const int solids = edgeSolids.Contains(e) ? distinct(edgeSolids.FindFromKey(e)) : 0;
        if (distinct(edgeFaces(i)) > 2 || solids > 1) {
            edges.push_back(e);
            bad.Add(e);
        }
    }
    for (int i = 1; i <= vertexSolids.Extent(); i++) {
        if (distinct(vertexSolids(i)) < 2)
            continue;
        const TopoDS_Shape v = vertexSolids.FindKey(i);
        bool onEdge = false;
        if (vertexEdges.Contains(v))
            for (TopTools_ListOfShape::Iterator it(vertexEdges.FindFromKey(v)); it.More() && !onEdge; it.Next())
                onEdge = bad.Contains(it.Value());
        if (!onEdge)
            corners.push_back(TopoDS::Vertex(v));
    }
}

int hc_touching_count(const hc_shape *s)
{
    return guarded<>(-1, [&] {
        std::vector<TopoDS_Edge> edges;
        std::vector<TopoDS_Vertex> corners;
        touching_places(s->shape, edges, corners);
        return (int)(edges.size() + corners.size());
    });
}

// The shape with a thin rod of radius r along each edge where its bodies
// only touch, and a ball at each corner where they do: one closed surface,
// the bodies joined by a sliver of material.
hc_shape *hc_bridge_touching(const hc_shape *s, double r)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<TopoDS_Edge> edges;
        std::vector<TopoDS_Vertex> corners;
        touching_places(s->shape, edges, corners);
        TopTools_ListOfShape args, tools;
        args.Append(s->shape);
        for (const TopoDS_Edge &e : edges) {
            BRepAdaptor_Curve c(e);
            const gp_Pnt a = c.Value(c.FirstParameter()), b = c.Value(c.LastParameter());
            if (c.GetType() == GeomAbs_Line) {
                // a little past both ends, so the rod overlaps the corners too
                gp_Vec d(a, b);
                const double len = d.Magnitude();
                if (len < 1e-9)
                    continue;
                d.Normalize();
                tools.Append(BRepPrimAPI_MakeCylinder(gp_Ax2(a.Translated(-d * r), gp_Dir(d)), r, len + 2 * r).Shape());
            } else {
                // a curved edge: a ball every r along it
                const double len = GCPnts_AbscissaPoint::Length(c);
                const int n = std::max(2, std::min(2000, (int)std::ceil(len / r)));
                for (int i = 0; i <= n; i++) {
                    const gp_Pnt p = c.Value(c.FirstParameter() + (c.LastParameter() - c.FirstParameter()) * i / n);
                    tools.Append(BRepPrimAPI_MakeSphere(p, r).Shape());
                }
            }
        }
        for (const TopoDS_Vertex &v : corners)
            tools.Append(BRepPrimAPI_MakeSphere(BRep_Tool::Pnt(v), r).Shape());
        if (tools.IsEmpty()) {
            history_new(s->shape);
            for (size_t i = 0; i < g_history.size(); i++)
                g_history[i] = Origin{0, (int)i};
            return wrap(s->shape);
        }
        BRepAlgoAPI_Fuse fuse;
        fuse.SetArguments(args);
        fuse.SetTools(tools);
        fuse.Build();
        if (!fuse.IsDone()) {
            set_error("joining bodies that only touch failed");
            return nullptr;
        }
        history_record(fuse, {&s->shape}, fuse.Shape());
        return wrap(fuse.Shape());
    });
}

int hc_solid_count(const hc_shape *s) { return map_of(s, TopAbs_SOLID).Extent(); }

hc_shape *hc_solid(const hc_shape *s, int index)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        const auto &solids = map_of(s, TopAbs_SOLID);
        if (index < 0 || index >= solids.Extent()) {
            set_error("solid index out of range");
            return nullptr;
        }
        const TopoDS_Shape &body = solids(index + 1);
        // the body shares its faces with the parent: map them by identity
        const auto &parent = map_of(s, TopAbs_FACE);
        TopTools_IndexedMapOfShape faces;
        TopExp::MapShapes(body, TopAbs_FACE, faces);
        g_history.assign(faces.Extent(), Origin{-1, -1});
        g_also.clear();
        for (int i = 1; i <= faces.Extent(); i++) {
            int j = parent.FindIndex(faces(i));
            if (j > 0)
                g_history[i - 1] = Origin{0, j - 1};
        }
        return wrap(body);
    });
}

int hc_edge_count(const hc_shape *s) { return map_of(s, TopAbs_EDGE).Extent(); }

int hc_face_count(const hc_shape *s) { return map_of(s, TopAbs_FACE).Extent(); }

int hc_edge_info(const hc_shape *s, int index, double out[23])
{
    return guarded<>(-1, [&]() -> int {
        const auto &m = map_of(s, TopAbs_EDGE);
        if (index < 0 || index >= m.Extent()) {
            set_error("edge index out of range");
            return -1;
        }
        BRepAdaptor_Curve c(TopoDS::Edge(m(index + 1)));
        double u0 = c.FirstParameter(), u1 = c.LastParameter();
        gp_Pnt p[3] = {c.Value(u0), c.Value(u1), c.Value((u0 + u1) / 2)};
        for (int i = 0; i < 3; i++) {
            out[i * 3 + 0] = p[i].X();
            out[i * 3 + 1] = p[i].Y();
            out[i * 3 + 2] = p[i].Z();
        }
        for (int i = 9; i < 23; i++)
            out[i] = 0;
        // the unit tangents at its start and its end, along the curve's own direction (for chains of edges
        // running on smoothly)
        for (int k = 0; k < 2; k++) {
            gp_Pnt q;
            gp_Vec t;
            c.D1(k == 0 ? u0 : u1, q, t);
            if (t.Magnitude() > 1e-12)
                t.Normalize();
            out[17 + 3 * k] = t.X();
            out[18 + 3 * k] = t.Y();
            out[19 + 3 * k] = t.Z();
        }
        if (c.GetType() == GeomAbs_Circle) {
            gp_Circ circ = c.Circle();
            gp_Pnt ctr = circ.Location();
            gp_Dir ax = circ.Axis().Direction();
            double v[7] = {ctr.X(), ctr.Y(), ctr.Z(), ax.X(), ax.Y(), ax.Z(), circ.Radius()};
            for (int i = 0; i < 7; i++)
                out[9 + i] = v[i];
        }
        // the length along the curve, not the chord (a circle's is 2πr)
        switch (c.GetType()) {
        case GeomAbs_Line: out[16] = p[0].Distance(p[1]); break;
        case GeomAbs_Circle: out[16] = c.Circle().Radius() * std::abs(u1 - u0); break;
        default: out[16] = GCPnts_AbscissaPoint::Length(c, u0, u1, 1e-6); break;
        }
        switch (c.GetType()) {
        case GeomAbs_Line: return HC_EDGE_LINE;
        case GeomAbs_Circle: return HC_EDGE_CIRCLE;
        default: return HC_EDGE_OTHER;
        }
    });
}

// The edges of the outer loop of face `face` (no hole's), as indices in the
// shape's edges: how many, at most `max` written to `out`; -1 on error.
int hc_face_outer_edges(const hc_shape *s, int face, int *out, int max)
{
    return guarded<>(-1, [&]() -> int {
        const auto &fm = map_of(s, TopAbs_FACE);
        if (face < 0 || face >= fm.Extent()) {
            set_error("face index out of range");
            return -1;
        }
        const auto &em = map_of(s, TopAbs_EDGE);
        const TopoDS_Wire outer = BRepTools::OuterWire(TopoDS::Face(fm(face + 1)));
        int n = 0;
        for (TopExp_Explorer e(outer, TopAbs_EDGE); e.More(); e.Next()) {
            const int k = em.FindIndex(e.Current()) - 1;
            if (k < 0)
                continue;
            if (n < max)
                out[n] = k;
            n++;
        }
        return n;
    });
}

// The parts of a profile: which 0, the outline of each region without its
// holes (a face each); 1, each hole filled (a face each); 2, each region as
// it is. How many there are (count) and part `index`.
static std::vector<TopoDS_Shape> profile_parts(const hc_shape *s, int which)
{
    std::vector<TopoDS_Shape> r;
    for (const TopoDS_Face &face : faces_of(s->shape)) {
        if (which == 2) {
            r.push_back(face);
            continue;
        }
        const TopoDS_Wire outer = BRepTools::OuterWire(face);
        for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next()) {
            const bool isOuter = w.Current().IsSame(outer);
            if (isOuter != (which == 0))
                continue;
            BRepBuilderAPI_MakeFace f(TopoDS::Wire(w.Current()), Standard_True);
            if (f.IsDone())
                r.push_back(upward(f.Face()));
        }
    }
    return r;
}

int hc_profile_part_count(const hc_shape *s, int which)
{
    return guarded<>(-1, [&] { return (int)profile_parts(s, which).size(); });
}

hc_shape *hc_profile_part(const hc_shape *s, int which, int index)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        auto parts = profile_parts(s, which);
        if (index < 0 || index >= (int)parts.size()) {
            set_error("profile part out of range");
            return nullptr;
        }
        return primitive(parts[index]);
    });
}

// Whether face `index` lies on a cylinder: then its axis (a point, a unit
// direction), radius, extent along the axis (from, to, from the point), the
// angle it spans around the axis, and 1 when its outside faces away from
// the axis (a shaft) or 0 when towards it (a hole). Returns 1, 0 when the
// face is not cylindrical, -1 on error.
// 1 when the point is inside the solid (on its surface counts as outside),
// 0 when outside, -1 on error.
int hc_point_inside(const hc_shape *s, double x, double y, double z)
{
    return guarded<>(-1, [&]() -> int {
        BRepClass3d_SolidClassifier c(s->shape, gp_Pnt(x, y, z), 1e-7);
        return c.State() == TopAbs_IN ? 1 : 0;
    });
}

// The axis of a face turned round one (a cylinder, a cone, a torus, a surface of revolution): a point
// on it and its direction; 0 for any other face.
int hc_face_axis(const hc_shape *s, int index, double out[6])
{
    return guarded<>(-1, [&]() -> int {
        const auto &m = map_of(s, TopAbs_FACE);
        if (index < 0 || index >= m.Extent())
            throw Standard_Failure("no such face");
        BRepAdaptor_Surface surf(TopoDS::Face(m(index + 1)));
        gp_Ax1 ax;
        switch (surf.GetType()) {
        case GeomAbs_Cylinder: ax = surf.Cylinder().Axis(); break;
        case GeomAbs_Cone: ax = surf.Cone().Axis(); break;
        case GeomAbs_Torus: ax = surf.Torus().Axis(); break;
        case GeomAbs_SurfaceOfRevolution: ax = surf.AxeOfRevolution(); break;
        default: return 0;
        }
        const double v[6] = {ax.Location().X(), ax.Location().Y(), ax.Location().Z(), ax.Direction().X(),
            ax.Direction().Y(), ax.Direction().Z()};
        for (int i = 0; i < 6; i++)
            out[i] = v[i];
        return 1;
    });
}

int hc_face_cylinder(const hc_shape *s, int index, double out[11])
{
    return guarded<>(-1, [&]() -> int {
        const auto &m = map_of(s, TopAbs_FACE);
        if (index < 0 || index >= m.Extent())
            throw Standard_Failure("no such face");
        const TopoDS_Face f = TopoDS::Face(m(index + 1));
        BRepAdaptor_Surface surf(f);
        if (surf.GetType() != GeomAbs_Cylinder)
            return 0;
        const gp_Cylinder c = surf.Cylinder();
        double u0, u1, v0, v1;
        BRepTools::UVBounds(f, u0, u1, v0, v1);
        const gp_Ax1 ax = c.Axis();
        out[0] = ax.Location().X();
        out[1] = ax.Location().Y();
        out[2] = ax.Location().Z();
        out[3] = ax.Direction().X();
        out[4] = ax.Direction().Y();
        out[5] = ax.Direction().Z();
        out[6] = c.Radius();
        out[7] = v0;
        out[8] = v1;
        out[9] = u1 - u0;
        // the surface's own normal points away from the axis when its frame
        // is right-handed; a reversed face turns it round
        const bool direct = c.Position().Direct();
        out[10] = (direct == (f.Orientation() != TopAbs_REVERSED)) ? 1 : 0;
        return 1;
    });
}

// The vector area of a face, its normal integrated over it (∫n dA): half the sum of p × dp round its
// boundary, the wires sampled finely enough, each edge the way the face runs it (holes the other way,
// a seam there and back cancelling). Zero for a face that closes round on itself (a cylinder's whole
// side, a sphere): it faces no way.
static gp_Vec face_vector_area(const TopoDS_Face &f)
{
    gp_Vec sum(0, 0, 0);
    for (TopExp_Explorer e(f, TopAbs_EDGE); e.More(); e.Next()) {
        const TopoDS_Edge &edge = TopoDS::Edge(e.Current());
        if (BRep_Tool::Degenerated(edge))
            continue;
        BRepAdaptor_Curve c(edge);
        const double a = c.FirstParameter(), b = c.LastParameter();
        const int n = c.GetType() == GeomAbs_Line ? 1 : 64;
        const bool reversed = edge.Orientation() == TopAbs_REVERSED;
        gp_Pnt prev = c.Value(reversed ? b : a);
        for (int i = 1; i <= n; i++) {
            const double t = reversed ? b - (b - a) * i / n : a + (b - a) * i / n;
            const gp_Pnt q = c.Value(t);
            sum += gp_Vec(prev.XYZ()).Crossed(gp_Vec(q.XYZ())) * 0.5;
            prev = q;
        }
    }
    return sum;
}

int hc_face_info(const hc_shape *s, int index, double out[8])
{
    return guarded<>(-1, [&]() -> int {
        const auto &m = map_of(s, TopAbs_FACE);
        if (index < 0 || index >= m.Extent()) {
            set_error("face index out of range");
            return -1;
        }
        TopoDS_Face f = TopoDS::Face(m(index + 1));
        GProp_GProps props;
        BRepGProp::SurfaceProperties(f, props);
        gp_Pnt c = props.CentreOfMass();

        BRepAdaptor_Surface surf(f);
        double u = (surf.FirstUParameter() + surf.LastUParameter()) / 2;
        double v = (surf.FirstVParameter() + surf.LastVParameter()) / 2;
        BRepLProp_SLProps lp(surf, u, v, 1, 1e-6);
        gp_Dir n = lp.IsNormalDefined() ? lp.Normal() : gp_Dir(0, 0, 1);
        if (f.Orientation() == TopAbs_REVERSED)
            n.Reverse();
        // a curved face faces the way its normal points on the whole (a dome up), not the way it
        // points at the middle of its parameters (anywhere round a cylinder's side); one closing
        // round on itself faces no way (out[7] = 0)
        double facing = 1;
        if (surf.GetType() != GeomAbs_Plane) {
            const gp_Vec va = face_vector_area(f);
            const double area = props.Mass();
            if (area > 0 && va.Magnitude() > 1e-3 * area)
                n = gp_Dir(va);
            else
                facing = 0;
        }

        double vals[8] = {c.X(), c.Y(), c.Z(), n.X(), n.Y(), n.Z(), props.Mass(), facing};
        for (int i = 0; i < 8; i++)
            out[i] = vals[i];
        return 0;
    });
}

// WORKAROUND (OpenCascade 7.9.3, BRepFilletAPI, BRepOffsetAPI_DraftAngle):
// some features return a broken solid instead of failing; caught here, or
// the model silently shows the input unchanged (or garbage). No case known
// today (none of the tests or examples reaches it): it stays as a guard,
// as cheap as one validity check per feature.
static void require_valid(const TopoDS_Shape &r, const char *what)
{
    if (r.IsNull() || !BRepCheck_Analyzer(r).IsValid())
        throw Standard_Failure(what);
}

hc_shape *hc_fillet(const hc_shape *s, const int *edges, int nedges, double r)
{
    return guarded<>((hc_shape *)nullptr, [&] {
        const auto &m = map_of(s, TopAbs_EDGE);
        BRepFilletAPI_MakeFillet mk(s->shape);
        for (int i = 0; i < nedges; i++)
            mk.Add(r, TopoDS::Edge(m(edges[i] + 1)));
        require_valid(mk.Shape(), "the result is not a valid solid");
        history_record(mk, {&s->shape}, mk.Shape());
        return checked(wrap(mk.Shape()));
    });
}

hc_shape *hc_chamfer(const hc_shape *s, const int *edges, int nedges, double d)
{
    return guarded<>((hc_shape *)nullptr, [&] {
        const auto &m = map_of(s, TopAbs_EDGE);
        BRepFilletAPI_MakeChamfer mk(s->shape);
        for (int i = 0; i < nedges; i++)
            mk.Add(d, TopoDS::Edge(m(edges[i] + 1)));
        require_valid(mk.Shape(), "the result is not a valid solid");
        history_record(mk, {&s->shape}, mk.Shape());
        return checked(wrap(mk.Shape()));
    });
}

// The flat face `face` swept by the vector v: the solid a push or pull of
// the face adds or removes.
// ---------------------------------------------------------------- profiles on curved faces

// A flat profile (on XY) laid on face `face` of `s`: wrapped (project 0), rolled
// onto it as a label onto a bottle, lengths kept along the face; or projected
// (project 1), each point carried along `dir` (the face's normal at the anchor
// when zero) from the plane touching the face at the anchor. The profile's origin
// goes to the anchor `at` (NaN: the middle of the face's parameters), its x
// across the face (round a cylinder), its y along it, read from outside. Each
// region of the profile becomes a solid between `inner` and `outer` along the
// face's normal (outwards positive): what to cut or add. The edges are curves
// on the surface, exact where the face unrolls flat (a cylinder: lines and
// arcs carried exactly), fitted within a micron elsewhere.
static int g_wrap_skipped = 0;

// How many regions the last hc_wrap_tool left out, broken.
int hc_wrap_skipped(void) { return g_wrap_skipped; }

// What wrap_impl was asked, beyond its arguments: flat, the face unrolled (*round the length round it);
// outside, which regions of the profile are not wholly inside the face, nothing built (*classified set
// once it has gone through them all)
struct WrapAsk {
    double *round = nullptr;
    double *middle = nullptr;   // flat: the face's point at the middle of its parameters (x y z)
    std::vector<int> *outside = nullptr;
    bool *classified = nullptr;
};

// The walls between the edges `top` (a loop, in order, on one face) and `bottom` (the same loop on
// another), each a ruled face between an edge of one and its partner, the straight edges between them
// (the rulings) made once and shared by the two walls they part: the walls come out joined to each other
// and to the loops' faces, with nothing to sew. Each pair of curves is made into B-splines alike (degree,
// knots: their parameters kept), the ruled surface's rows their poles, so a wall's edges lie exactly on
// it (lines in its parameters). False, with nothing made, where that does not hold (rational curves,
// curves of other parameters): then BRepFill::Face and sewing as before.
static bool ruled_walls(const std::vector<TopoDS_Edge> &top, const std::vector<TopoDS_Edge> &bottom,
                        std::vector<TopoDS_Shape> &out)
{
    const size_t n = top.size();
    if (n == 0 || bottom.size() != n)
        return false;
    const double tol = 1e-7;
    struct Pair {
        Handle(Geom_BSplineCurve) t, b;
        double f, l;
    };
    std::vector<Pair> pairs;
    std::vector<TopoDS_Vertex> tv(n), bv(n);
    for (size_t j = 0; j < n; j++) {
        TopLoc_Location lt, lb;
        double f, l, fb, lb_;
        Handle(Geom_Curve) ct = BRep_Tool::Curve(top[j], lt, f, l), cb = BRep_Tool::Curve(bottom[j], lb, fb, lb_);
        if (ct.IsNull() || cb.IsNull() || !lt.IsIdentity() || !lb.IsIdentity() || std::abs(f - fb) > 1e-9
            || std::abs(l - lb_) > 1e-9 || !(l > f))
            return false;
        Handle(Geom_BSplineCurve) t = Handle(Geom_BSplineCurve)::DownCast(ct->Copy());
        Handle(Geom_BSplineCurve) b = Handle(Geom_BSplineCurve)::DownCast(cb->Copy());
        if (t.IsNull() || b.IsNull() || t->IsRational() != b->IsRational() || t->IsPeriodic() || b->IsPeriodic())
            return false;
        if (t->FirstParameter() > f + 1e-12 || t->LastParameter() < l - 1e-12 || b->FirstParameter() > f + 1e-12
            || b->LastParameter() < l - 1e-12)
            return false;
        if (t->FirstParameter() < f - 1e-12 || t->LastParameter() > l + 1e-12)
            t->Segment(f, l);
        if (b->FirstParameter() < f - 1e-12 || b->LastParameter() > l + 1e-12)
            b->Segment(f, l);
        // alike: the higher degree, every knot of either
        const int deg = std::max(t->Degree(), b->Degree());
        t->IncreaseDegree(deg);
        b->IncreaseDegree(deg);
        for (int pass = 0; pass < 2; pass++) {
            Handle(Geom_BSplineCurve) from = pass ? b : t, to = pass ? t : b;
            for (int k = 1; k <= from->NbKnots(); k++)
                to->InsertKnot(from->Knot(k), from->Multiplicity(k), 1e-12);
        }
        if (t->NbPoles() != b->NbPoles() || t->NbKnots() != b->NbKnots())
            return false;
        // rational (arcs: the same angle on two radii), only with the same weights: the wall's rulings then
        // straight and even
        if (t->IsRational())
            for (int k = 1; k <= t->NbPoles(); k++)
                if (std::abs(t->Weight(k) - b->Weight(k)) > 1e-12 * std::abs(t->Weight(k)))
                    return false;
        // the loop's corners: the end of one edge the start of the next, on both loops
        TopoDS_Vertex t0, t1, b0, b1;
        TopExp::Vertices(TopoDS::Edge(top[j].Oriented(TopAbs_FORWARD)), t0, t1);
        TopExp::Vertices(TopoDS::Edge(bottom[j].Oriented(TopAbs_FORWARD)), b0, b1);
        tv[j] = t0;
        bv[j] = b0;
        pairs.push_back({t, b, f, l});
    }
    for (size_t j = 0; j < n; j++) {
        TopoDS_Vertex t0, t1, b0, b1;
        TopExp::Vertices(TopoDS::Edge(top[j].Oriented(TopAbs_FORWARD)), t0, t1);
        TopExp::Vertices(TopoDS::Edge(bottom[j].Oriented(TopAbs_FORWARD)), b0, b1);
        if (!t1.IsSame(tv[(j + 1) % n]) || !b1.IsSame(bv[(j + 1) % n]))
            return false;
    }
    BRep_Builder B;
    // the rulings, from each corner of the top loop straight to its partner below, over [0, 1]
    std::vector<TopoDS_Edge> ruling(n);
    for (size_t j = 0; j < n; j++) {
        const gp_Pnt P = BRep_Tool::Pnt(tv[j]), Q = BRep_Tool::Pnt(bv[j]);
        if (P.Distance(Q) < 1e-9)
            return false;
        TColgp_Array1OfPnt poles(1, 2);
        poles(1) = P;
        poles(2) = Q;
        TColStd_Array1OfReal knots(1, 2);
        knots(1) = 0;
        knots(2) = 1;
        TColStd_Array1OfInteger mults(1, 2);
        mults(1) = mults(2) = 2;
        B.MakeEdge(ruling[j], new Geom_BSplineCurve(poles, knots, mults, 1), tol);
        B.Add(ruling[j], TopoDS::Vertex(tv[j].Oriented(TopAbs_FORWARD)));
        B.Add(ruling[j], TopoDS::Vertex(bv[j].Oriented(TopAbs_REVERSED)));
        B.Range(ruling[j], 0, 1);
    }
    for (size_t j = 0; j < n; j++) {
        const Pair &p = pairs[j];
        const int nu = p.t->NbPoles();
        TColgp_Array2OfPnt poles(1, nu, 1, 2);
        for (int i = 1; i <= nu; i++) {
            poles(i, 1) = p.t->Pole(i);
            poles(i, 2) = p.b->Pole(i);
        }
        TColStd_Array1OfReal uk(1, p.t->NbKnots()), vk(1, 2);
        TColStd_Array1OfInteger um(1, p.t->NbKnots()), vm(1, 2);
        p.t->Knots(uk);
        p.t->Multiplicities(um);
        vk(1) = 0;
        vk(2) = 1;
        vm(1) = vm(2) = 2;
        Handle(Geom_BSplineSurface) wall;
        if (p.t->IsRational()) {
            TColStd_Array2OfReal weights(1, nu, 1, 2);
            for (int i = 1; i <= nu; i++)
                weights(i, 1) = weights(i, 2) = p.t->Weight(i);
            wall = new Geom_BSplineSurface(poles, weights, uk, vk, um, vm, p.t->Degree(), 1);
        } else
            wall = new Geom_BSplineSurface(poles, uk, vk, um, vm, p.t->Degree(), 1);
        TopoDS_Face F;
        B.MakeFace(F, wall, tol);
        // the edges on it: the loops' along v = 0 and v = 1, the rulings along u = f and u = l
        B.UpdateEdge(top[j], new Geom2d_Line(gp_Pnt2d(0, 0), gp_Dir2d(1, 0)), F, tol);
        B.UpdateEdge(bottom[j], new Geom2d_Line(gp_Pnt2d(0, 1), gp_Dir2d(1, 0)), F, tol);
        const TopoDS_Edge &r0 = ruling[j], &r1 = ruling[(j + 1) % n];
        B.UpdateEdge(r0, new Geom2d_Line(gp_Pnt2d(p.f, 0), gp_Dir2d(0, 1)), F, tol);
        B.UpdateEdge(r1, new Geom2d_Line(gp_Pnt2d(p.l, 0), gp_Dir2d(0, 1)), F, tol);
        TopoDS_Wire W;
        B.MakeWire(W);
        B.Add(W, top[j].Oriented(TopAbs_FORWARD));
        B.Add(W, r1.Oriented(TopAbs_FORWARD));
        B.Add(W, bottom[j].Oriented(TopAbs_REVERSED));
        B.Add(W, r0.Oriented(TopAbs_REVERSED));
        W.Closed(Standard_True);
        B.Add(F, W);
        out.push_back(F);
    }
    for (auto &r : ruling) {
        B.SameParameter(r, Standard_True);
        B.SameRange(r, Standard_True);
    }
    return true;
}

// The piece of `surf` round the parameters `box` (a little more), when `surf` is a B-spline of many knots (a
// lofted face) or an offset of one: a segment of it, with the same parameters and a few knots (of an offset, the
// offset of that piece); null otherwise. OpenCascade, building a curve on a surface, first finds every crossing of
// the curve with the surface's knot lines, most of a knurl's time on such a face; on the piece, a moment.
static Handle(Geom_Surface) piece_of(const Handle(Geom_Surface) &surf, const Bnd_Box2d &box)
{
    Handle(Geom_BSplineSurface) bs = Handle(Geom_BSplineSurface)::DownCast(surf);
    Handle(Geom_OffsetSurface) os = Handle(Geom_OffsetSurface)::DownCast(surf);
    if (os)
        bs = Handle(Geom_BSplineSurface)::DownCast(os->BasisSurface());
    if (bs.IsNull() || bs->NbUKnots() * bs->NbVKnots() < 64 || box.IsVoid() || getenv("HCAD_WRAP_WHOLE"))
        return nullptr;
    double u0, v0, u1, v1;
    box.Get(u0, v0, u1, v1);
    double su0, su1, sv0, sv1;
    bs->Bounds(su0, su1, sv0, sv1);
    const double mu = 0.1 * (u1 - u0) + 1e-6 * (su1 - su0), mv = 0.1 * (v1 - v0) + 1e-6 * (sv1 - sv0);
    u0 = std::max(su0, u0 - mu);
    u1 = std::min(su1, u1 + mu);
    v0 = std::max(sv0, v0 - mv);
    v1 = std::min(sv1, v1 + mv);
    try {
        // the poles round the piece only, not the whole surface's copied for each
        Handle(Geom_BSplineSurface) piece = Handle(Geom_BSplineSurface)::DownCast(bs->Copy());
        piece->Segment(u0, u1, v0, v1);
        if (os)
            return new Geom_OffsetSurface(piece, os->Offset());
        return piece;
    } catch (const Standard_Failure &) {
        return nullptr;
    }
}

// An edge along `c` on `surf`, its 3D curve built to 1e-7 on `local` (the piece of `surf` round it, piece_of)
// when there is one, the edge then given that curve and `c` on `surf`.
static TopoDS_Edge edge_on_surface(const Handle(Geom2d_Curve) &c, const Handle(Geom_Surface) &surf,
                                   const Handle(Geom_Surface) &local = nullptr)
{
    if (local.IsNull()) {
        TopoDS_Edge e = BRepBuilderAPI_MakeEdge(c, surf).Edge();
        BRepLib::BuildCurves3d(e, 1e-7);
        return e;
    }
    TopoDS_Edge onPiece = BRepBuilderAPI_MakeEdge(c, local).Edge();
    BRepLib::BuildCurves3d(onPiece, 1e-7);
    double f, l;
    Handle(Geom_Curve) c3 = BRep_Tool::Curve(onPiece, f, l);
    if (c3.IsNull())
        return edge_on_surface(c, surf);
    // the same edge, its curve on the whole surface instead of the piece's
    const double tol = BRep_Tool::Tolerance(onPiece);
    TopoDS_Vertex v0, v1;
    TopExp::Vertices(onPiece, v0, v1);
    BRep_Builder B;
    TopoDS_Edge e;
    B.MakeEdge(e, c3, tol);
    B.UpdateEdge(e, c, surf, TopLoc_Location(), tol);
    // and on the piece too, for faces made on the piece (a floor, the piece a hole takes, quicker to integrate)
    B.UpdateEdge(e, c, local, TopLoc_Location(), tol);
    B.Add(e, v0);
    B.Add(e, v1);
    B.Range(e, f, l);
    B.SameParameter(e, Standard_True);
    B.SameRange(e, Standard_True);
    return e;
}

// Whether no two of the closed outlines `polys` (points in a plane, in order) meet: neither crosses the other,
// nor lies inside it. Only pairs whose boxes overlap are looked at, found through a grid of the boxes.
static bool outlines_apart(const std::vector<std::vector<gp_Pnt2d>> &polys)
{
    const size_t n = polys.size();
    if (n < 2)
        return true;
    std::vector<Bnd_Box2d> boxes(n);
    Bnd_Box2d all;
    for (size_t i = 0; i < n; i++) {
        for (auto &p : polys[i])
            boxes[i].Add(p);
        all.Add(boxes[i]);
    }
    double x0, y0, x1, y1;
    all.Get(x0, y0, x1, y1);
    const int g = std::max(1, (int)std::sqrt((double)n));
    const double cw = (x1 - x0) / g + 1e-12, ch = (y1 - y0) / g + 1e-12;
    std::vector<std::vector<size_t>> cells(g * g);
    auto cellsOf = [&](size_t i, auto &&f) {
        double a0, b0, a1, b1;
        boxes[i].Get(a0, b0, a1, b1);
        const int i0 = std::clamp((int)((a0 - x0) / cw), 0, g - 1), i1 = std::clamp((int)((a1 - x0) / cw), 0, g - 1);
        const int j0 = std::clamp((int)((b0 - y0) / ch), 0, g - 1), j1 = std::clamp((int)((b1 - y0) / ch), 0, g - 1);
        for (int a = i0; a <= i1; a++)
            for (int b = j0; b <= j1; b++)
                f(a * g + b);
    };
    for (size_t i = 0; i < n; i++)
        cellsOf(i, [&](int c) { cells[c].push_back(i); });
    auto side = [](const gp_Pnt2d &a, const gp_Pnt2d &b, const gp_Pnt2d &c) {
        return (b.X() - a.X()) * (c.Y() - a.Y()) - (b.Y() - a.Y()) * (c.X() - a.X());
    };
    auto inside = [](const gp_Pnt2d &p, const std::vector<gp_Pnt2d> &poly) {
        bool in = false;
        for (size_t k = 0, m = poly.size(); k < m; k++) {
            const gp_Pnt2d &a = poly[k], &b = poly[(k + 1) % m];
            if ((a.Y() > p.Y()) != (b.Y() > p.Y()) && p.X() < a.X() + (b.X() - a.X()) * (p.Y() - a.Y()) / (b.Y() - a.Y()))
                in = !in;
        }
        return in;
    };
    auto meet = [&](size_t i, size_t j) {
        const auto &A = polys[i], &B = polys[j];
        for (size_t a = 0; a < A.size(); a++) {
            const gp_Pnt2d &p = A[a], &q = A[(a + 1) % A.size()];
            for (size_t b = 0; b < B.size(); b++) {
                const gp_Pnt2d &r = B[b], &t = B[(b + 1) % B.size()];
                // crossing, or touching: an end on the other segment (two on one line apart do not meet)
                const double d1 = side(p, q, r), d2 = side(p, q, t), d3 = side(r, t, p), d4 = side(r, t, q);
                if (d1 * d2 < 0 && d3 * d4 < 0)
                    return true;
                auto on = [](const gp_Pnt2d &a, const gp_Pnt2d &b, const gp_Pnt2d &c, double d) {
                    return std::abs(d) <= 1e-12 * (1 + a.SquareDistance(b)) && c.X() >= std::min(a.X(), b.X())
                        && c.X() <= std::max(a.X(), b.X()) && c.Y() >= std::min(a.Y(), b.Y()) && c.Y() <= std::max(a.Y(), b.Y());
                };
                if (on(p, q, r, d1) || on(p, q, t, d2) || on(r, t, p, d3) || on(r, t, q, d4))
                    return true;
            }
        }
        return inside(A[0], B) || inside(B[0], A);
    };
    std::set<std::pair<size_t, size_t>> seen;
    for (auto &c : cells)
        for (size_t a = 0; a < c.size(); a++)
            for (size_t b = a + 1; b < c.size(); b++) {
                const size_t i = std::min(c[a], c[b]), j = std::max(c[a], c[b]);
                if (boxes[i].IsOut(boxes[j]) || !seen.insert({i, j}).second)
                    continue;
                if (meet(i, j)) {
                    if (getenv("HCAD_WRAP_DEBUG")) {
                        double a0, b0, a1, b1, c0, d0, c1, d1;
                        boxes[i].Get(a0, b0, a1, b1);
                        boxes[j].Get(c0, d0, c1, d1);
                        fprintf(stderr, "wrap: holes %zu [%g %g, %g %g] and %zu [%g %g, %g %g] meet\n", i, a0, b0, a1, b1, j,
                                c0, d0, c1, d1);
                    }
                    return false;
                }
            }
    return true;
}

static hc_shape *wrap_impl(const hc_shape *s, int face, const hc_shape *profile, int project, const double *at,
                           const double *dir, double inner, double outer, bool direct, WrapAsk ask = WrapAsk())
{
    double *flat = ask.round;
    g_wrap_skipped = 0;
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        const auto &m = map_of(s, TopAbs_FACE);
        if (face < 0 || face >= m.Extent())
            throw Standard_Failure("no such face");
        const TopoDS_Face F = TopoDS::Face(m(face + 1));
        Handle(Geom_Surface) S = BRep_Tool::Surface(F);
        TopLoc_Location faceLoc;
        const Handle(Geom_Surface) Sface = BRep_Tool::Surface(F, faceLoc);   // the face's own, unmoved
        double turned = 0;   // how far S was turned round its axis: S(u, v) is the face's surface at u + turned
        const double sign = F.Orientation() == TopAbs_REVERSED ? -1 : 1;
        // a trimmed surface: the one it trims (the same parameters, beyond the trim too)
        while (Handle(Geom_RectangularTrimmedSurface) tr = Handle(Geom_RectangularTrimmedSurface)::DownCast(S))
            S = tr->BasisSurface();
        // a surface closed round on itself but not periodic (a loft through rings): made
        // periodic, so the profile can run on across the line where it closes
        if (Handle(Geom_BSplineSurface) bs = Handle(Geom_BSplineSurface)::DownCast(S)) {
            Handle(Geom_BSplineSurface) c = Handle(Geom_BSplineSurface)::DownCast(bs->Copy());
            try {
                if (c->IsUClosed() && !c->IsUPeriodic())
                    c->SetUPeriodic();
                if (c->IsVClosed() && !c->IsVPeriodic())
                    c->SetVPeriodic();
                S = c;
            } catch (const Standard_Failure &) {
            }
        }
        double umin, umax, vmin, vmax;
        BRepTools::UVBounds(F, umin, umax, vmin, vmax);
        double u0 = (umin + umax) / 2, v0 = (vmin + vmax) / 2;
        if (std::isnan(at[0]) && GeomAdaptor_Surface(S).GetType() != GeomAbs_Plane) {
            // a curved face: the place across it that faces the front (-Y), as a wall's
            // frame is seen, halfway along it
            double best = -2;
            for (int i = 0; i <= 720; i++) {
                const double u = umin + (umax - umin) * i / 720, v = (vmin + vmax) / 2;
                gp_Pnt q;
                gp_Vec du, dv;
                S->D1(u, v, q, du, dv);
                const gp_Vec n = du.Crossed(dv);
                if (n.Magnitude() < 1e-12)
                    continue;
                const double f = -n.Normalized().Y() * sign;
                if (f > best + 1e-9) {
                    best = f;
                    u0 = u;
                }
            }
            // a face whose across-parameter is v (a surface lofted the other way)
            for (int i = 0; i <= 720 && best < 0.999; i++) {
                const double v = vmin + (vmax - vmin) * i / 720, u = (umin + umax) / 2;
                gp_Pnt q;
                gp_Vec du, dv;
                S->D1(u, v, q, du, dv);
                const gp_Vec n = du.Crossed(dv);
                if (n.Magnitude() < 1e-12)
                    continue;
                const double f = -n.Normalized().Y() * sign;
                if (f > best + 1e-9) {
                    best = f;
                    u0 = u;
                    v0 = v;
                }
            }
        }
        if (!std::isnan(at[0])) {
            GeomAPI_ProjectPointOnSurf pr(gp_Pnt(at[0], at[1], at[2]), S);
            if (pr.NbPoints() == 0)
                throw Standard_Failure("the point given by at: does not lie over the face");
            pr.LowerDistanceParameters(u0, v0);
        }
        // a surface turned round an axis (cylinder, cone, sphere, a turned profile): turned so that the
        // anchor sits halfway round its parameter, and a profile shorter than once round never crosses the
        // line where the parameter starts again (a face across it comes out broken)
        {
            gp_Ax1 axis;
            bool round = false;
            if (Handle(Geom_ElementarySurface) el = Handle(Geom_ElementarySurface)::DownCast(S)) {
                round = !Handle(Geom_Plane)::DownCast(S);
                axis = el->Axis();
            } else if (Handle(Geom_SurfaceOfRevolution) rv = Handle(Geom_SurfaceOfRevolution)::DownCast(S)) {
                round = true;
                axis = rv->Axis();
            }
            if (round && S->IsUPeriodic() && std::abs(u0 - M_PI) > 1e-12) {
                S = Handle(Geom_Surface)::DownCast(S->Copy());
                S->Rotate(axis, u0 - M_PI);
                turned = u0 - M_PI;
                umin -= turned;
                umax -= turned;
                u0 = M_PI;
            }
        }
        gp_Pnt O;
        gp_Vec Su, Sv;
        S->D1(u0, v0, O, Su, Sv);
        if (Su.Magnitude() < 1e-9 || Sv.Magnitude() < 1e-9)
            throw Standard_Failure("the anchor is at a pole of the face: give another point with at:");
        gp_Vec N = Su.Crossed(Sv).Normalized() * sign;
        // x along the parameter that runs most across Z (round a cylinder standing up),
        // y along the other; turned so that y goes up and x, y and the normal turn right-handed
        const bool swap = std::abs(Su.Normalized().Z()) > std::abs(Sv.Normalized().Z()) + 1e-9;
        const gp_Vec Px = swap ? Sv : Su, Py = swap ? Su : Sv;
        const double by = Py.Z() < -1e-9 ? -1 : 1;
        const double bx = (Px.Crossed(Py).Dot(N) > 0 ? 1 : -1) * by;
        // (x, y) as (u, v) through the parameters of x and y
        auto uv = [&](double px, double py) { return swap ? gp_Pnt2d(py, px) : gp_Pnt2d(px, py); };
        const double p0x = swap ? v0 : u0, p0y = swap ? u0 : v0;
        const GeomAbs_SurfaceType type = GeomAdaptor_Surface(S).GetType();
        const bool affine = !project && (type == GeomAbs_Cylinder || type == GeomAbs_Plane);
        const double lx = Px.Magnitude(), ly = Py.Magnitude();

        // wrapping elsewhere: arc length along the two lines of the surface through the anchor
        struct Table {
            std::vector<double> t, len;
            double param(double l) const
            {
                if (l < len.front() - 1e-9 || l > len.back() + 1e-9)
                    throw Standard_Failure("the profile runs off the face's surface: make it smaller, or move "
                                           "it with at:");
                const size_t i = std::min<size_t>(
                    std::max<size_t>(std::lower_bound(len.begin(), len.end(), l) - len.begin(), 1), len.size() - 1);
                const double f = (l - len[i - 1]) / std::max(len[i] - len[i - 1], 1e-300);
                return t[i - 1] + f * (t[i] - t[i - 1]);
            }
        };
        auto table = [&](bool alongU) {
            double a, b;
            const double p0 = alongU ? u0 : v0;
            const bool periodic = alongU ? S->IsUPeriodic() : S->IsVPeriodic();
            if (periodic) {
                const double per = alongU ? S->UPeriod() : S->VPeriod();
                a = p0 - per / 2;
                b = p0 + per / 2;
            } else {
                double s0, s1, t0, t1;
                S->Bounds(s0, s1, t0, t1);
                a = alongU ? s0 : t0;
                b = alongU ? s1 : t1;
                const double lo = alongU ? umin : vmin, hi = alongU ? umax : vmax, span = hi - lo;
                a = std::max(a, lo - 2 * span);
                b = std::min(b, hi + 2 * span);
            }
            Table tb;
            const int n = 4000;
            gp_Pnt prev;
            double acc = 0;
            for (int i = 0; i <= n; i++) {
                const double t = a + (b - a) * i / n;
                const gp_Pnt q = alongU ? S->Value(t, v0) : S->Value(u0, t);
                if (i > 0)
                    acc += q.Distance(prev);
                prev = q;
                tb.t.push_back(t);
                tb.len.push_back(acc);
            }
            // lengths from the anchor
            double l0 = 0;
            for (int i = 1; i <= n; i++)
                if (tb.t[i] >= p0) {
                    const double f = (p0 - tb.t[i - 1]) / (tb.t[i] - tb.t[i - 1]);
                    l0 = tb.len[i - 1] + f * (tb.len[i] - tb.len[i - 1]);
                    break;
                }
            for (double &l : tb.len)
                l -= l0;
            return tb;
        };
        if (affine && !flat) {
            // round a cylinder: no longer than once round
            Bnd_Box pb;
            BRepBndLib::Add(profile->shape, pb);
            double x0, y0, z0, x1, y1, z1;
            pb.Get(x0, y0, z0, x1, y1, z1);
            const bool periodic = swap ? S->IsVPeriodic() : S->IsUPeriodic();
            const double per = swap ? (periodic ? S->VPeriod() : 0) : (periodic ? S->UPeriod() : 0);
            if (periodic && (x1 - x0) > lx * per + 1e-6)
                throw Standard_Failure("the profile runs off the face's surface: it is longer than once round it");
        }
        Table tx, ty;
        if (!affine && !project) {
            tx = table(!swap);
            ty = table(swap);
        }

        // flat: no profile laid, the face itself unrolled into the profile's (x, y), its outline and its
        // holes; *flat the length once round when the face closes round on itself (0 if not)
        if (flat) {
            if (project)
                throw Standard_Failure("flat: only wrapped");
            // the length from the anchor along a table to the parameter t (the table inverted)
            auto lengthAt = [](const Table &tb, double t) {
                if (t <= tb.t.front())
                    return tb.len.front();
                if (t >= tb.t.back())
                    return tb.len.back();
                const size_t i = std::max<size_t>(std::lower_bound(tb.t.begin(), tb.t.end(), t) - tb.t.begin(), 1);
                const double f = (t - tb.t[i - 1]) / std::max(tb.t[i] - tb.t[i - 1], 1e-300);
                return tb.len[i - 1] + f * (tb.len[i] - tb.len[i - 1]);
            };
            const bool xPeriodic = swap ? S->IsVPeriodic() : S->IsUPeriodic();
            const double perX = xPeriodic ? (swap ? S->VPeriod() : S->UPeriod()) : 0;
            // (x, y) of a point of the face given in the face's own parameters
            auto toXY = [&](double fu, double fv, double shift) {
                const double su = fu - turned, sv = fv;
                const double px = (swap ? sv : su) + shift, py = swap ? su : sv;
                if (affine)
                    return gp_Pnt2d(bx * (px - p0x) * lx, by * (py - p0y) * ly);
                return gp_Pnt2d(bx * lengthAt(tx, px), by * lengthAt(ty, py));
            };
            double fu0, fu1, fv0, fv1;
            BRepTools::UVBounds(F, fu0, fu1, fv0, fv1);
            const double spanX = swap ? fv1 - fv0 : fu1 - fu0;
            if (ask.middle) {
                const gp_Pnt mid = Sface->Value((fu0 + fu1) / 2, (fv0 + fv1) / 2);
                ask.middle[0] = mid.X();
                ask.middle[1] = mid.Y();
                ask.middle[2] = mid.Z();
            }
            const gp_Pln xy(gp::XOY());
            *flat = 0;
            // a band all round: the length round, from a line of constant v to another (the lines it is
            // bounded by, as the band wrap_impl makes again)
            if (perX > 0 && std::abs(spanX - perX) < 1e-7) {
                const double round_ = affine ? lx * perX : tx.len.back() - tx.len.front();
                const double ya = toXY(fu0, fv0, 0).Y(), yb = toXY(fu1, fv1, 0).Y();
                *flat = round_;
                const double y0 = std::min(ya, yb), y1 = std::max(ya, yb);
                BRepBuilderAPI_MakePolygon poly(gp_Pnt(-round_ / 2, y0, 0), gp_Pnt(round_ / 2, y0, 0),
                                                gp_Pnt(round_ / 2, y1, 0), gp_Pnt(-round_ / 2, y1, 0), Standard_True);
                return primitive(BRepBuilderAPI_MakeFace(xy, poly.Wire(), Standard_True).Face());
            }
            // any other face: each wire a polygon through points along its edges, every half millimetre
            const TopoDS_Wire outerW = BRepTools::OuterWire(F);
            TopoDS_Wire outerFlat;
            std::vector<TopoDS_Wire> holes;
            for (TopExp_Explorer we(F, TopAbs_WIRE); we.More(); we.Next()) {
                const TopoDS_Wire &w = TopoDS::Wire(we.Current());
                BRepBuilderAPI_MakePolygon poly;
                for (BRepTools_WireExplorer ex(w, F); ex.More(); ex.Next()) {
                    const TopoDS_Edge &ed = ex.Current();
                    if (BRep_Tool::Degenerated(ed))
                        continue;
                    double a, b;
                    const Handle(Geom2d_Curve) c = BRep_Tool::CurveOnSurface(ed, F, a, b);
                    if (c.IsNull())
                        throw Standard_Failure("flat: an edge has no curve on the face");
                    GProp_GProps lp;
                    BRepGProp::LinearProperties(ed, lp);
                    const int n = std::clamp((int)(lp.Mass() / 0.5), 4, 2000);
                    const bool rev = ed.Orientation() == TopAbs_REVERSED;
                    // the edge kept whole on one side of the window round the anchor
                    double shift = 0;
                    if (perX > 0) {
                        const gp_Pnt2d m = c->Value((a + b) / 2);
                        const double pm = (swap ? m.Y() : m.X() - turned);
                        shift = perX * std::round((p0x - pm) / perX);
                    }
                    for (int k = 0; k < n; k++) {
                        const double t = rev ? b - (b - a) * k / n : a + (b - a) * k / n;
                        const gp_Pnt2d q = c->Value(t);
                        const gp_Pnt2d p = toXY(q.X(), q.Y(), shift);
                        poly.Add(gp_Pnt(p.X(), p.Y(), 0));
                    }
                }
                poly.Close();
                if (!poly.IsDone())
                    throw Standard_Failure("flat: a wire of the face did not unroll");
                if (w.IsSame(outerW))
                    outerFlat = poly.Wire();
                else
                    holes.push_back(poly.Wire());
            }
            if (outerFlat.IsNull())
                throw Standard_Failure("flat: the face has no outline");
            BRepBuilderAPI_MakeFace mf(xy, outerFlat, Standard_True);
            for (auto &hw : holes)
                mf.Add(hw);
            ShapeFix_Face fix(mf.Face());
            fix.FixOrientation();
            fix.Perform();
            return primitive(fix.Face());
        }

        // projecting: from the plane touching the face at the anchor, along dir
        gp_Vec X = (Px * bx).Normalized();
        X = (X - N * X.Dot(N)).Normalized();
        const gp_Vec Y = N.Crossed(X);
        gp_Vec D(dir[0], dir[1], dir[2]);
        if (D.Magnitude() < 1e-12)
            D = -N;
        D.Normalize();
        double lastU = u0, lastV = v0;
        auto projected = [&](double x, double y) {
            const gp_Pnt P = O.Translated(X * x + Y * y);
            double u = lastU, v = lastV, t = 0;
            for (int it = 0; it < 50; it++) {
                gp_Pnt q;
                gp_Vec du, dv;
                S->D1(u, v, q, du, dv);
                const gp_Vec r(P.Translated(D * t), q);   // S(u, v) - (P + t D)
                if (r.Magnitude() < 1e-9)
                    break;
                // solve [du dv -D] (Δu Δv Δt) = -r
                const gp_Vec c3 = -D;
                const double det = du.Dot(dv.Crossed(c3));
                if (std::abs(det) < 1e-14)
                    throw Standard_Failure("the projection runs along the face: give another direction");
                const gp_Vec mr = -r;
                u += mr.Dot(dv.Crossed(c3)) / det;
                v += du.Dot(mr.Crossed(c3)) / det;
                t += du.Dot(dv.Crossed(mr)) / det;
                if (it == 49)
                    throw Standard_Failure("part of the profile, projected, misses the face's surface");
            }
            lastU = u;
            lastV = v;
            return gp_Pnt2d(u, v);
        };
        auto mapped = [&](double x, double y) -> gp_Pnt2d {
            if (project)
                return projected(x, y);
            if (affine)
                return uv(p0x + bx * x / lx, p0y + by * y / ly);
            return uv(tx.param(bx * x), ty.param(by * y));
        };

        // on a cylinder or a plane, each edge of the profile as a curve in (u, v), carried exactly
        auto pcurve = [&](const TopoDS_Edge &e) -> Handle(Geom2d_Curve) {
            double f, l;
            TopLoc_Location loc;
            Handle(Geom_Curve) c = BRep_Tool::Curve(e, loc, f, l);
            if (c.IsNull())
                throw Standard_Failure("an edge of the profile has no curve");
            if (!loc.IsIdentity())
                c = Handle(Geom_Curve)::DownCast(c->Transformed(loc.Transformation()));
            const bool rev = e.Orientation() == TopAbs_REVERSED;
            if (affine) {
                Handle(Geom_BSplineCurve) bs = GeomConvert::CurveToBSplineCurve(new Geom_TrimmedCurve(c, f, l));
                if (rev)
                    bs->Reverse();
                TColgp_Array1OfPnt2d poles(1, bs->NbPoles());
                for (int i = 1; i <= bs->NbPoles(); i++)
                    poles(i) = mapped(bs->Pole(i).X(), bs->Pole(i).Y());
                TColStd_Array1OfReal knots(1, bs->NbKnots()), weights(1, bs->NbPoles());
                TColStd_Array1OfInteger mults(1, bs->NbKnots());
                bs->Knots(knots);
                bs->Multiplicities(mults);
                bs->Weights(weights);
                return new Geom2d_BSplineCurve(poles, weights, knots, mults, bs->Degree(), bs->IsPeriodic());
            }
            throw Standard_Failure("an edge carried exactly onto a face that does not unroll");
        };
        // elsewhere, a loop of the profile as curves interpolated through points of it carried
        // onto the face, one curve for each run of edges between sharp corners (one closed curve
        // when it has none, a rounded outline): two curves meeting tangentially, a rounding and
        // its side, interpolated each on its own, can cross again a micron past where they meet,
        // an outline crossing itself
        auto chains = [&](const TopoDS_Wire &w, const TopoDS_Face &on) {
            struct Piece {
                std::vector<gp_Pnt2d> pts;
                gp_Vec2d t0, t1;   // directions on the profile at its start and end
            };
            std::vector<Piece> pieces;
            for (BRepTools_WireExplorer we(w, on); we.More(); we.Next()) {
                const TopoDS_Edge &e = we.Current();
                BRepAdaptor_Curve ac(e);
                const double f = ac.FirstParameter(), l = ac.LastParameter();
                const bool rev = e.Orientation() == TopAbs_REVERSED;
                const bool straight = ac.GetType() == GeomAbs_Line;
                const double len = GCPnts_AbscissaPoint::Length(ac);
                // points evenly spaced along the whole outline, lines and arcs alike: spaced unevenly
                // (close on a tight rounding, far on a side) the interpolation swings out past the
                // rounding and can loop on itself
                const double step = 0.5;
                const int n = len < 0.05 ? 1 : std::max(straight ? 1 : 2, (int)std::ceil(len / step));
                Piece pc;
                for (int i = 0; i <= n; i++) {
                    const double t = rev ? l - (l - f) * i / n : f + (l - f) * i / n;
                    const gp_Pnt q = ac.Value(t);
                    pc.pts.push_back(gp_Pnt2d(q.X(), q.Y()));
                }
                gp_Pnt q;
                gp_Vec d;
                ac.D1(rev ? l : f, q, d);
                pc.t0 = gp_Vec2d(d.X(), d.Y()) * (rev ? -1 : 1);
                ac.D1(rev ? f : l, q, d);
                pc.t1 = gp_Vec2d(d.X(), d.Y()) * (rev ? -1 : 1);
                pieces.push_back(pc);
            }
            const size_t m = pieces.size();
            auto smooth = [&](size_t i) {   // piece i runs on into piece i + 1 without a corner
                const gp_Vec2d a = pieces[i].t1, b = pieces[(i + 1) % m].t0;
                return a.Magnitude() > 1e-12 && b.Magnitude() > 1e-12 && a.Angle(b) < 1e-3 && std::abs(a.Angle(b)) < 1e-3;
            };
            size_t start = m;
            for (size_t i = 0; i < m; i++)
                if (!smooth((i + m - 1) % m)) {
                    start = i;
                    break;
                }
            auto interpolate = [&](const std::vector<gp_Pnt2d> &xy, bool periodic) -> Handle(Geom2d_Curve) {
                if (xy.size() == 2 && !periodic)
                    return GCE2d_MakeSegment(mapped(xy[0].X(), xy[0].Y()), mapped(xy[1].X(), xy[1].Y())).Value();
                Handle(TColgp_HArray1OfPnt2d) pts = new TColgp_HArray1OfPnt2d(1, (int)xy.size());
                for (size_t i = 0; i < xy.size(); i++)
                    pts->SetValue((int)i + 1, mapped(xy[i].X(), xy[i].Y()));
                Geom2dAPI_Interpolate interp(pts, periodic, 1e-9);
                interp.Perform();
                if (!interp.IsDone())
                    throw Standard_Failure("an outline of the profile could not be laid on the face");
                return interp.Curve();
            };
            std::vector<Handle(Geom2d_Curve)> out;
            if (start == m) {
                // no corner: one closed curve round the whole loop
                std::vector<gp_Pnt2d> xy;
                for (auto &pc : pieces)
                    xy.insert(xy.end(), pc.pts.begin(), pc.pts.end() - 1);
                out.push_back(interpolate(xy, true));
                return out;
            }
            std::vector<gp_Pnt2d> xy;
            for (size_t k = 0; k < m; k++) {
                const size_t i = (start + k) % m;
                xy.insert(xy.end(), pieces[i].pts.begin() + (xy.empty() ? 0 : 1), pieces[i].pts.end());
                if (!smooth(i)) {
                    out.push_back(interpolate(xy, false));
                    xy.clear();
                }
            }
            return out;
        };
        auto offsetSurface = [&](double d) -> Handle(Geom_Surface) {
            if (std::abs(d) < 1e-12)
                return S;
            Handle(Geom_OffsetSurface) os = new Geom_OffsetSurface(S, sign * d);
            Handle(Geom_Surface) b = os->Surface();
            if (!b.IsNull())
                return b;
            return os;
        };
        const Handle(Geom_Surface) Sin = offsetSurface(inner), Sout = offsetSurface(outer);

        // the loops of each region of the profile, carried onto the face
        auto loopsOf = [&](const TopoDS_Face &pf) {
            std::vector<std::vector<Handle(Geom2d_Curve)>> loops;
            const TopoDS_Face fwd = TopoDS::Face(pf.Oriented(TopAbs_FORWARD));
            const TopoDS_Wire outerWire = BRepTools::OuterWire(fwd);
            std::vector<TopoDS_Wire> wires{outerWire};
            for (TopExp_Explorer w(fwd, TopAbs_WIRE); w.More(); w.Next())
                if (!w.Current().IsSame(outerWire))
                    wires.push_back(TopoDS::Wire(w.Current()));
            for (const TopoDS_Wire &w : wires) {
                std::vector<Handle(Geom2d_Curve)> loop;
                if (affine) {
                    for (BRepTools_WireExplorer we(w, fwd); we.More(); we.Next())
                        loop.push_back(pcurve(we.Current()));
                } else
                    loop = chains(w, fwd);
                loops.push_back(loop);
            }
            return loops;
        };
        // a loop as a wire of edges on `surf`, its curves moved by `du` along u first
        auto wireOn = [&](const std::vector<Handle(Geom2d_Curve)> &loop, const Handle(Geom_Surface) &surf, double du,
                          std::vector<TopoDS_Edge> *edges, Handle(Geom_Surface) *usedPiece = nullptr) {
            BRepBuilderAPI_MakeWire mw;
            // the loop's curves, moved; the piece of the surface round them, made once for all of them
            std::vector<Handle(Geom2d_Curve)> moved;
            Bnd_Box2d box;
            for (auto &c2 : loop) {
                Handle(Geom2d_Curve) c = c2;
                if (du != 0) {
                    c = Handle(Geom2d_Curve)::DownCast(c2->Copy());
                    c->Translate(gp_Vec2d(du, 0));
                }
                moved.push_back(c);
                for (int k = 0; k <= 8; k++)
                    box.Add(c->Value(c->FirstParameter() + (c->LastParameter() - c->FirstParameter()) * k / 8));
            }
            const Handle(Geom_Surface) local = piece_of(surf, box);
            if (usedPiece)
                *usedPiece = local;
            for (auto &c : moved) {
                TopoDS_Edge e = edge_on_surface(c, surf, local);
                mw.Add(e);
                if (!mw.IsDone())
                    throw Standard_Failure("the profile's outline does not close on the face");
                if (edges)
                    edges->push_back(mw.Edge());
            }
            return mw.Wire();
        };

        if (direct) {
            // the result built at once, with no boolean: the face with each region's outline as a
            // hole, the region's islands left at the face, its floor on the surface moved `inner`
            // along the normal (in for a pocket, out for a relief), the sides between, sewn to the
            // rest of the solid. Only for a region wholly inside the face; anything else, the caller
            // takes the boolean way
            Laps laps;
            if (!faceLoc.IsIdentity())
                throw Standard_Failure("direct: the face is placed by a location");
            int solids = 0;
            for (TopExp_Explorer e(s->shape, TopAbs_SOLID); e.More(); e.Next())
                solids++;
            if (solids != 1)
                throw Standard_Failure("direct: not one solid");
            const Handle(Geom_Surface) floorSurf = offsetSurface(inner);
            // the floors must lie in the material (a pocket) or out of it (a relief): a pocket
            // through the wall, or into another face, takes the boolean way
            // what the segment from the face out to a floor crosses (built once: a classifier searched
            // the whole solid again for each point)
            IntCurvesFace_ShapeIntersector crossing;
            // (every face but the one the probes start on: they leave it at once, and a curve met against a
            // large B-spline face, there, at each of thousands of probes, took most of a knurl's time)
            {
                TopoDS_Compound others;
                BRep_Builder ob;
                ob.MakeCompound(others);
                for (TopExp_Explorer x(s->shape, TopAbs_FACE); x.More(); x.Next())
                    if (!x.Current().IsSame(F))
                        ob.Add(others, x.Current());
                crossing.Load(others, 1e-7);
            }
            const double period = Sface->IsUPeriodic() ? Sface->UPeriod()
                                  : S->IsUPeriodic()   ? S->UPeriod()
                                                       : 0;
            double fu0, fu1, fv0, fv1;
            BRepTools::UVBounds(F, fu0, fu1, fv0, fv1);
            // a band all round an axis (the side of a cylinder, a cone, a vase), bounded by lines of
            // constant v and its seam: made again on S, whose seam is turned to the back, so the
            // regions (round the front) never cross it; on S the loops need no moving
            bool band = period > 0 && S->IsUPeriodic() && std::abs((fu1 - fu0) - period) < 1e-7;
            for (TopExp_Explorer e(F, TopAbs_EDGE); band && e.More(); e.Next()) {
                const TopoDS_Edge &ed = TopoDS::Edge(e.Current());
                if (BRep_Tool::IsClosed(ed, F) || BRep_Tool::Degenerated(ed))
                    continue;
                double a, b;
                const Handle(Geom2d_Curve) c = BRep_Tool::CurveOnSurface(ed, F, a, b);
                const double va = c->Value(a).Y(), vb = c->Value(b).Y(), vm = c->Value((a + b) / 2).Y();
                band = std::abs(va - vb) < 1e-7 && std::abs(va - vm) < 1e-7
                       && (std::abs(va - fv0) < 1e-7 || std::abs(va - fv1) < 1e-7);
            }
            TopoDS_Face base = F;
            Handle(Geom_Surface) holeSurf = Sface;
            // the band's own parameters round the anchor already (its middle the anchor, the surface not
            // turned): the face itself holed, its edges those of the faces round it, nothing to sew there
            const bool ownWindow = band && std::abs(turned) < 1e-12 && std::abs((u0 - period / 2) - fu0) < 1e-9;
            if (band && !ownWindow) {
                base = BRepBuilderAPI_MakeFace(S, u0 - period / 2, u0 + period / 2, fv0, fv1, 1e-7).Face();
                if (F.Orientation() == TopAbs_REVERSED)
                    base.Reverse();
                holeSurf = S;
                fu0 = u0 - period / 2;
                fu1 = u0 + period / 2;
            }
            // a pocket deeper than the wall: through it, when the wall's other face is this one moved in
            // by the wall's thickness (a shell's, a tube's) and a band too: that face holed as well with
            // the same loops (the two surfaces share their parameters), the sides between the two
            int farFace = 0;
            double thick = 0;
            Handle(Geom_Surface) farSurf;
            TopoDS_Face farBase;
            if (inner < 0 && band) {
                gp_Pnt p0;
                gp_Vec du0, dv0;
                S->D1(u0, v0, p0, du0, dv0);
                const gp_Vec n0 = du0.Crossed(dv0).Normalized() * sign;
                double best = 1e100;
                for (int i = 1; i <= m.Extent(); i++) {
                    if (i == face + 1)
                        continue;
                    const TopoDS_Face G = TopoDS::Face(m(i));
                    GeomAPI_ProjectPointOnSurf pr(p0, BRep_Tool::Surface(G));
                    if (pr.NbPoints() == 0)
                        continue;
                    const gp_Vec w(p0, pr.NearestPoint());
                    const double dist = w.Magnitude();
                    if (dist < 1e-6 || dist > -inner + 1e-7 || w.Normalized().Dot(-n0) < 0.9999)
                        continue;
                    double gu, gv;
                    pr.LowerDistanceParameters(gu, gv);
                    if (BRepTopAdaptor_FClass2d(G, 1e-7).Perform(gp_Pnt2d(gu, gv)) != TopAbs_IN)
                        continue;
                    if (dist < best) {
                        best = dist;
                        farFace = i;
                    }
                }
                if (farFace > 0) {
                    const TopoDS_Face G = TopoDS::Face(m(farFace));
                    const Handle(Geom_Surface) gs = BRep_Tool::Surface(G);
                    const Handle(Geom_Surface) off = offsetSurface(-best);
                    // the far face must lie on this surface moved in, all round and along it
                    bool same = true;
                    for (int i = 0; i < 8 && same; i++)
                        for (int j = 0; j <= 2 && same; j++) {
                            const gp_Pnt q = off->Value(u0 - period / 2 + period * i / 8, fv0 + (fv1 - fv0) * j / 2);
                            GeomAPI_ProjectPointOnSurf pr(q, gs);
                            same = pr.NbPoints() > 0 && pr.LowerDistance() < 1e-6;
                        }
                    // and be a band: its v range on the moved surface from where its edges lie
                    double gv0 = 1e100, gv1 = -1e100, gu0, gu1, gw0, gw1;
                    BRepTools::UVBounds(G, gu0, gu1, gw0, gw1);
                    same = same && std::abs((gu1 - gu0) - period) < 1e-7;
                    for (TopExp_Explorer e(G, TopAbs_VERTEX); same && e.More(); e.Next()) {
                        GeomAPI_ProjectPointOnSurf pr(BRep_Tool::Pnt(TopoDS::Vertex(e.Current())), off);
                        if (pr.NbPoints() == 0) {
                            same = false;
                            break;
                        }
                        double a, b;
                        pr.LowerDistanceParameters(a, b);
                        gv0 = std::min(gv0, b);
                        gv1 = std::max(gv1, b);
                    }
                    if (same && gv1 > gv0) {
                        thick = best;
                        farSurf = off;
                        farBase = BRepBuilderAPI_MakeFace(off, u0 - period / 2, u0 + period / 2, gv0, gv1, 1e-7).Face();
                    } else
                        farFace = 0;
                }
            }
            const bool through = farFace > 0;
            BRepTopAdaptor_FClass2d inside(base, 1e-7);
            std::unique_ptr<BRepTopAdaptor_FClass2d> insideFar;
            if (through)
                insideFar.reset(new BRepTopAdaptor_FClass2d(farBase, 1e-7));
            BRepBuilderAPI_MakeFace holed(TopoDS::Face(base.Oriented(TopAbs_FORWARD)));
            BRepBuilderAPI_MakeFace holedFar;
            if (through)
                holedFar.Init(TopoDS::Face(farBase.Oriented(TopAbs_FORWARD)));
            std::vector<TopoDS_Shape> extra;
            std::vector<TopoDS_Face> patches, patchesFar;
            // the holes' outlines in the face's parameters, sampled: the holed face is sound when no two meet
            std::vector<std::vector<gp_Pnt2d>> holeOutlines;
            bool cellsShared = true;   // each region's faces sewn on their own, keeping the holes' edges
            // the faces of each cell made joined (ruled walls), where they lie in `extra`
            std::vector<std::pair<size_t, size_t>> joinedCells;
            bool allJoined = true;
            double expected = 0;
            const auto regionFaces = faces_of(profile->shape);
            int regionIndex = -1;
            for (const TopoDS_Face &pf : regionFaces) {
                regionIndex++;
                const auto loops = loopsOf(pf);
                // where on the face's own parameters: turned back, then by whole periods into its bounds
                double du = band ? 0 : turned;
                if (!band) {
                    Bnd_Box2d b;
                    for (auto &c2 : loops[0])
                        for (int k = 0; k <= 8; k++) {
                            const gp_Pnt2d q = c2->Value(c2->FirstParameter() + (c2->LastParameter() - c2->FirstParameter()) * k / 8);
                            b.Add(gp_Pnt2d(q.X() + du, q.Y()));
                        }
                    double a0, b0, a1, b1;
                    b.Get(a0, b0, a1, b1);
                    if (period > 0)
                        du += period * std::round(((fu0 + fu1) / 2 - (a0 + a1) / 2) / period);
                }
                bool within = true;
                for (auto &loop : loops)
                    for (auto &c2 : loop)
                        for (int k = 0; k < 24 && within; k++) {
                            const gp_Pnt2d q = c2->Value(c2->FirstParameter() + (c2->LastParameter() - c2->FirstParameter()) * k / 24);
                            // (on a closed face the classifier brings a point back into the period: one past the
                            // seam would count as inside, the region crossing the seam's edge)
                            if ((period > 0 && (q.X() + du <= fu0 || q.X() + du >= fu1))
                                || inside.Perform(gp_Pnt2d(q.X() + du, q.Y())) != TopAbs_IN
                                || (through && insideFar->Perform(q) != TopAbs_IN))
                                within = false;
                        }
                if (ask.outside) {
                    // only which regions run off the face
                    if (!within)
                        ask.outside->push_back(regionIndex);
                    continue;
                }
                if (!within)
                    throw Standard_Failure("direct: a region is not wholly inside the face");
                // a floor in the material (a pocket) or out of it (a relief); through, the middle of the wall:
                // the segment from the face to it, at points round the outline, crosses no face of the
                // solid (the face itself where it starts aside), so it lies on the face's inner side for a
                // pocket and its outer side for a relief, as just under and just over the face
                // (eight points a side; two with many regions, a knurl's thousands: still eight round each)
                const Handle(Geom_Surface) probe = through ? offsetSurface(-thick / 2) : floorSurf;
                const int probes = regionFaces.size() > 64 ? 2 : 8;
                for (auto &c2 : loops[0])
                    for (int k = 0; k < probes; k++) {
                        const gp_Pnt2d q = c2->Value(c2->FirstParameter() + (c2->LastParameter() - c2->FirstParameter()) * (k + 0.5) / probes);
                        const gp_Pnt Q = S->Value(q.X(), q.Y()), P = probe->Value(q.X(), q.Y());
                        const gp_Vec d(Q, P);
                        const double len = d.Magnitude();
                        if (len < 1e-9)
                            continue;
                        crossing.Perform(gp_Lin(Q, gp_Dir(d)), std::min(0.01 * len, 1e-3), len);
                        if (crossing.IsDone() && crossing.NbPnt() > 0)
                            throw Standard_Failure("direct: a floor does not lie where it should (through the wall?)");
                    }
                // the outline a hole in the face, the islands faces of their own at the face
                // in (u, v) an outline runs counter-clockwise round a face made the surface's way, a
                // hole clockwise: each loop turned so (it runs either way as it comes, x turning
                // round on the inside of a hole's wall)
                auto turned_ = [&](const std::vector<Handle(Geom2d_Curve)> &loop, const TopoDS_Wire &w, bool outer) {
                    double area = 0;
                    std::vector<gp_Pnt2d> poly;
                    for (auto &c2 : loop)
                        for (int k = 0; k < 16; k++)
                            poly.push_back(c2->Value(c2->FirstParameter() + (c2->LastParameter() - c2->FirstParameter()) * k / 16));
                    for (size_t i = 0; i < poly.size(); i++) {
                        const gp_Pnt2d &a = poly[i], &b = poly[(i + 1) % poly.size()];
                        area += a.X() * b.Y() - b.X() * a.Y();
                    }
                    return (area > 0) == outer ? w : TopoDS::Wire(w.Reversed());
                };
                // the loops on the face once: the hole, the piece it takes, the islands and the walls' tops
                // all made of these edges, shared already, not left for the sewing to find and merge
                std::vector<std::vector<TopoDS_Edge>> top(loops.size()), bottom(loops.size());
                std::vector<TopoDS_Wire> topWires;
                Handle(Geom_Surface) topPiece;
                for (size_t i = 0; i < loops.size(); i++)
                    topWires.push_back(wireOn(loops[i], holeSurf, du, &top[i], i == 0 ? &topPiece : nullptr));
                // a sliver whose outline, carried onto the face, crosses itself would break the whole
                // face it is a hole in: checked on its own first, and left out (counted) if broken
                {
                    // (the check is slow: only for an outline that crosses itself in the face's parameters, where
                    // a sliver is; one that does not is sound on the face too)
                    auto crosses = [&](const std::vector<Handle(Geom2d_Curve)> &loop) {
                        std::vector<gp_Pnt2d> poly;
                        for (auto &c2 : loop)
                            for (int k = 0; k < 16; k++)
                                poly.push_back(c2->Value(c2->FirstParameter() + (c2->LastParameter() - c2->FirstParameter()) * k / 16));
                        const size_t m = poly.size();
                        auto side = [](const gp_Pnt2d &a, const gp_Pnt2d &b, const gp_Pnt2d &c) {
                            return (b.X() - a.X()) * (c.Y() - a.Y()) - (b.Y() - a.Y()) * (c.X() - a.X());
                        };
                        for (size_t i = 0; i < m; i++)
                            for (size_t j = i + 2; j < m; j++) {
                                if (i == 0 && j == m - 1)
                                    continue;
                                const gp_Pnt2d &a = poly[i], &b = poly[(i + 1) % m], &c = poly[j], &d = poly[(j + 1) % m];
                                if (side(a, b, c) * side(a, b, d) < 0 && side(c, d, a) * side(c, d, b) < 0)
                                    return true;
                            }
                        return false;
                    };
                    // (made on the piece of the surface round it when there is one: only for the volume and
                    // this check, quicker to integrate there)
                    BRepBuilderAPI_MakeFace alone(topPiece.IsNull() ? holeSurf : topPiece,
                                                  turned_(loops[0], topWires[0], true), Standard_True);
                    if (!alone.IsDone() || (crosses(loops[0]) && !BRepCheck_Analyzer(alone.Face()).IsValid())) {
                        g_wrap_skipped++;
                        continue;
                    }
                    // the piece of the face the hole takes away, for the volume
                    patches.push_back(alone.Face());
                }
                holed.Add(turned_(loops[0], topWires[0], false));
                {
                    std::vector<gp_Pnt2d> poly;
                    for (auto &c2 : loops[0])
                        for (int k = 0; k < 16; k++) {
                            const gp_Pnt2d q = c2->Value(c2->FirstParameter() + (c2->LastParameter() - c2->FirstParameter()) * k / 16);
                            poly.emplace_back(q.X() + du, q.Y());
                        }
                    holeOutlines.push_back(poly);
                }
                // the region's own faces: its islands, its floor (or the far face's islands), its walls
                std::vector<TopoDS_Shape> cell;
                for (size_t i = 1; i < loops.size(); i++)
                    cell.push_back(BRepBuilderAPI_MakeFace(holeSurf, turned_(loops[i], topWires[i], true), Standard_True).Face());
                if (through) {
                    // the far face holed by the outline, the islands' far ends faces of their own
                    std::vector<TopoDS_Wire> farWires;
                    for (size_t i = 0; i < loops.size(); i++)
                        farWires.push_back(wireOn(loops[i], farSurf, 0, &bottom[i]));
                    holedFar.Add(turned_(loops[0], farWires[0], false));
                    patchesFar.push_back(BRepBuilderAPI_MakeFace(farSurf, turned_(loops[0], farWires[0], true), Standard_True).Face());
                    for (size_t i = 1; i < loops.size(); i++)
                        cell.push_back(BRepBuilderAPI_MakeFace(farSurf, turned_(loops[i], farWires[i], true), Standard_True).Face());
                } else {
                    // the floor on the piece of its surface round it, when there is one and the islands lie on it
                    // too (one piece for the whole floor: its outline's)
                    BRepBuilderAPI_MakeFace fl;
                    Handle(Geom_Surface) floorPiece;
                    std::vector<TopoDS_Wire> fw;
                    for (size_t i = 0; i < loops.size(); i++)
                        fw.push_back(wireOn(loops[i], floorSurf, 0, &bottom[i], i == 0 ? &floorPiece : nullptr));
                    if (loops.size() > 1)
                        floorPiece.Nullify();
                    for (size_t i = 0; i < loops.size(); i++) {
                        const TopoDS_Wire w = turned_(loops[i], fw[i], i == 0);
                        if (i == 0)
                            fl.Init(floorPiece.IsNull() ? floorSurf : floorPiece, Standard_False, 1e-7);
                        fl.Add(w);
                    }
                    cell.push_back(fl.Face());
                }
                // the walls: ruled faces sharing their straight edges, joined already (HCAD_WRAP_RULED=0: the old
                // way, to compare), or each made on its own and the cell sewn below
                bool joined = !getenv("HCAD_WRAP_RULED") || std::string(getenv("HCAD_WRAP_RULED")) != "0";
                std::vector<TopoDS_Shape> walls;
                for (size_t i = 0; i < loops.size() && joined; i++)
                    joined = ruled_walls(top[i], bottom[i], walls);
                if (joined)
                    for (auto &w : walls)
                        cell.push_back(w);
                else
                    for (size_t i = 0; i < loops.size(); i++)
                        for (size_t j = 0; j < top[i].size(); j++)
                            cell.push_back(BRepFill::Face(top[i][j], bottom[i][j]));
                // sewn among themselves (the walls side by side meet along rulings each made its own),
                // so that the whole needs no sewing: OpenCascade's puts thousands of faces into a shell in a
                // time that grows with the square of their number. Only if the edges the holes are made
                // of come through as they were (else the whole is sewn as before)
                if (joined) {
                    const size_t first = extra.size();
                    for (auto &f : cell)
                        extra.push_back(f);
                    joinedCells.push_back({first, extra.size()});
                } else {
                    allJoined = false;
                    BRepBuilderAPI_Sewing local(1e-5);
                    for (auto &f : cell)
                        local.Add(f);
                    local.Perform();
                    bool kept = true;
                    for (size_t i = 0; i < loops.size() && kept; i++)
                        for (size_t j = 0; j < top[i].size() && kept; j++)
                            kept = !local.IsModifiedSubShape(top[i][j]) && (!through || !local.IsModifiedSubShape(bottom[i][j]));
                    if (kept) {
                        for (TopExp_Explorer f(local.SewedShape(), TopAbs_FACE); f.More(); f.Next())
                            extra.push_back(f.Current());
                    } else {
                        cellsShared = false;
                        for (auto &f : cell)
                            extra.push_back(f);
                    }
                }
                GProp_GProps g;
                BRepGProp::SurfaceProperties(pf, g);
                expected += g.Mass() * (through ? thick : std::abs(inner));
            }
            if (ask.outside) {
                *ask.classified = true;
                return nullptr;
            }
            if (!holed.IsDone())
                throw Standard_Failure("direct: the holes could not be made in the face");
            if (through && !holedFar.IsDone())
                throw Standard_Failure("direct: the holes could not be made in the far face");
            const TopoDS_Face holedNear = holed.Face(), holedFarFace = through ? holedFar.Face() : TopoDS_Face();
            // each cell's faces turned the way the holed face's edges say, from its hole's rim inwards: a wall
            // takes the hole's edge the other way round from the holed face, the floor and the neighbouring
            // walls theirs from the walls (ShapeFix on the whole shell, thousands of faces, took seconds)
            bool oriented = false;
            if (allJoined && !through && !getenv("HCAD_WRAP_SHAPEFIX")) {
                NCollection_DataMap<TopoDS_Shape, TopAbs_Orientation, TopTools_ShapeMapHasher> fixedEdges;
                for (TopExp_Explorer e(holedNear, TopAbs_EDGE); e.More(); e.Next())
                    fixedEdges.Bind(e.Current(), e.Current().Orientation());
                oriented = true;
                for (auto &range : joinedCells) {
                    const size_t n = range.second - range.first;
                    std::vector<int> state(n, 0);   // 0 not yet, 1 kept, -1 turned
                    NCollection_DataMap<TopoDS_Shape, TopAbs_Orientation, TopTools_ShapeMapHasher> known;
                    bool progress = true;
                    size_t done = 0;
                    while (progress && done < n) {
                        progress = false;
                        for (size_t i = 0; i < n; i++) {
                            if (state[i])
                                continue;
                            const TopoDS_Shape &f = extra[range.first + i];
                            for (TopExp_Explorer e(f, TopAbs_EDGE); e.More() && !state[i]; e.Next()) {
                                const TopAbs_Orientation *o = fixedEdges.Seek(e.Current());
                                if (!o)
                                    o = known.Seek(e.Current());
                                if (!o || BRep_Tool::Degenerated(TopoDS::Edge(e.Current())))
                                    continue;
                                // a shared edge runs one way in one face and the other way in the other
                                state[i] = e.Current().Orientation() == *o ? -1 : 1;
                            }
                            if (!state[i])
                                continue;
                            if (state[i] < 0)
                                extra[range.first + i].Reverse();
                            for (TopExp_Explorer e(extra[range.first + i], TopAbs_EDGE); e.More(); e.Next())
                                if (!fixedEdges.IsBound(e.Current()) && !known.IsBound(e.Current()))
                                    known.Bind(e.Current(), e.Current().Orientation());
                            done++;
                            progress = true;
                        }
                    }
                    if (done < n) {
                        oriented = false;
                        break;
                    }
                }
                if (getenv("HCAD_WRAP_DEBUG"))
                    fprintf(stderr, "wrap: cells turned on their own: %s\n", oriented ? "yes" : "no");
            }
            std::vector<TopoDS_Shape> kept;
            for (int i = 1; i <= m.Extent(); i++)
                if (i != face + 1 && i != farFace)
                    kept.push_back(m(i));
            TopoDS_Shell shell;
            laps.lap("direct: cells (faces, curves, probes, local sewing)");
            // the faces put together as they are, every edge already between two of them: no sewing (a band
            // all round made again on the turned surface has edges of its own round it: then it is sewn)
            bool assembled = false;
            if (cellsShared) {
                BRep_Builder bb;
                bb.MakeShell(shell);
                for (auto &f : kept)
                    bb.Add(shell, f);
                bb.Add(shell, holedNear);
                if (through)
                    bb.Add(shell, holedFarFace);
                for (auto &f : extra)
                    bb.Add(shell, f);
                TopTools_IndexedDataMapOfShapeListOfShape ef0;
                TopExp::MapShapesAndAncestors(shell, TopAbs_EDGE, TopAbs_FACE, ef0);
                assembled = true;
                for (int i = 1; i <= ef0.Extent() && assembled; i++)
                    if (!BRep_Tool::Degenerated(TopoDS::Edge(ef0.FindKey(i))) && ef0(i).Extent() != 2)
                        assembled = false;
                if (getenv("HCAD_WRAP_DEBUG"))
                    fprintf(stderr, "wrap: put together with no sewing: %s\n", assembled ? "yes" : "no");
            }
            BRepBuilderAPI_Sewing sew(1e-5);
            if (!assembled) {
                for (auto &f : kept)
                    sew.Add(f);
                sew.Add(holedNear);
                if (through)
                    sew.Add(holedFarFace);
                for (auto &f : extra)
                    sew.Add(f);
                sew.Perform();
                int shells = 0;
                for (TopExp_Explorer sh(sew.SewedShape(), TopAbs_SHELL); sh.More(); sh.Next(), shells++)
                    shell = TopoDS::Shell(sh.Current());
                if (shells != 1)
                    throw Standard_Failure("direct: the faces did not sew into one shell");
            }
            // a face given to be put together, as it is in the result
            auto inResult = [&](const TopoDS_Shape &f) -> TopoDS_Shape {
                if (!assembled)
                    return sew.IsModified(f) ? sew.Modified(f) : f;
                return f;
            };
            // the new faces turned all one way with the rest (made on a surface whose normal points
            // into the material, a hole's wall, they come the other way round)
            if (!(oriented && assembled)) {
                ShapeFix_Shell orient(shell);
                orient.FixFaceOrientation(shell);
                shell = orient.Shell();
            }
            TopoDS_Solid solid = BRepBuilderAPI_MakeSolid(shell).Solid();
            // which way it faces, from a face of the solid it was made from, left as it was: its normal
            // there points out of the old solid, so it must out of the new one (OrientClosedSolid finds it
            // by classifying a point, and on thousands of faces builds a structure for each: 650 MB and
            // seconds for a knurl of a thousand cells)
            {
                bool decided = false;
                for (TopExp_Explorer x(s->shape, TopAbs_FACE); x.More() && !decided; x.Next()) {
                    const TopoDS_Face g = TopoDS::Face(x.Current());
                    if (g.IsSame(F))
                        continue;
                    const TopoDS_Shape gm = inResult(g);
                    for (TopExp_Explorer y(solid, TopAbs_FACE); y.More() && !decided; y.Next()) {
                        if (!y.Current().IsSame(gm))
                            continue;
                        const TopoDS_Face h = TopoDS::Face(y.Current());
                        double u0g, u1g, v0g, v1g;
                        BRepTools::UVBounds(g, u0g, u1g, v0g, v1g);
                        const double ug = (u0g + u1g) / 2, vg = (v0g + v1g) / 2;
                        auto normal = [](const TopoDS_Face &f, double u, double v) {
                            BRepAdaptor_Surface a(f, Standard_False);
                            gp_Pnt p;
                            gp_Vec du, dv;
                            a.D1(u, v, p, du, dv);
                            gp_Vec n = du.Crossed(dv);
                            return f.Orientation() == TopAbs_REVERSED ? n.Reversed() : n;
                        };
                        const gp_Vec ng = normal(g, ug, vg), nh = normal(h, ug, vg);
                        if (ng.Magnitude() < 1e-12 || nh.Magnitude() < 1e-12)
                            continue;
                        if (ng.Dot(nh) < 0)
                            solid.Reverse();
                        decided = true;
                    }
                }
                if (!decided)
                    BRepLib::OrientClosedSolid(solid);
            }
            laps.lap("direct: assembly");
            // as it should be: closed, sound, its volume changed by about the regions' area times the depth
            // its volume face by face, and of each holed face the whole face less the pieces the holes take
            // (an integral over a face with thousands of holes takes seconds; over each small face and
            // piece, and the face whole, moments)
            double after = 0;
            {
                Bnd_Box sb;
                BRepBndLib::Add(s->shape, sb, false);
                double bx0, by0, bz0, bx1, by1, bz1;
                sb.Get(bx0, by0, bz0, bx1, by1, bz1);
                const gp_Pnt apex((bx0 + bx1) / 2, (by0 + by1) / 2, (bz0 + bz1) / 2);
                const TopoDS_Shape nearIn = inResult(holedNear);
                const TopoDS_Shape farIn = !through ? TopoDS_Shape()
                                           : inResult(holedFarFace);
                auto holedTerm = [&](const TopoDS_Face &in, const TopoDS_Face &whole, const std::vector<TopoDS_Face> &pieces) {
                    double t = face_volume_term(TopoDS::Face(whole.Oriented(TopAbs_FORWARD)), apex);
                    for (auto &p : pieces)
                        t -= face_volume_term(TopoDS::Face(p.Oriented(TopAbs_FORWARD)), apex);
                    return in.Orientation() == TopAbs_REVERSED ? -t : t;
                };
                // each face's term on its own (on every core), then their sum in order
                std::vector<TopoDS_Face> fs;
                for (TopExp_Explorer x(solid, TopAbs_FACE); x.More(); x.Next())
                    fs.push_back(TopoDS::Face(x.Current()));
                std::vector<double> terms(fs.size(), 0.0);
                OSD_Parallel::For(0, (int)fs.size(), [&](int i) {
                    const TopoDS_Face &f = fs[i];
                    if (f.IsSame(nearIn))
                        terms[i] = holedTerm(f, base, patches);
                    else if (through && f.IsSame(farIn))
                        terms[i] = holedTerm(f, farBase, patchesFar);
                    else
                        terms[i] = face_volume_term(f, apex);
                }, fs.size() < 64);
                for (double t : terms)
                    after += t;
            }
            laps.lap("direct: volume");
            // (within half the expected change either way)
            const double before = quick_volume(s->shape);
            const double change = inner < 0 ? before - after : after - before;
            if (!(change > 0.5 * expected && change < 1.5 * expected))
                throw Standard_Failure("direct: the volume is not what it should be");
            TopTools_IndexedDataMapOfShapeListOfShape ef;
            TopExp::MapShapesAndAncestors(solid, TopAbs_EDGE, TopAbs_FACE, ef);
            for (int i = 1; i <= ef.Extent(); i++)
                if (!BRep_Tool::Degenerated(TopoDS::Edge(ef.FindKey(i))) && ef(i).Extent() != 2)
                    throw Standard_Failure("direct: the solid is not closed");
            // sound: every face checked on its own, on every core, but the holed one, which OpenCascade checks by
            // meeting every hole's outline with every other's (seconds with hundreds of holes): there the
            // holes' outlines, sampled, met only with those whose boxes overlap theirs (each lies inside the
            // face already): seconds for a knurl of thousands of cells, where checking the whole solid took
            // hours (HCAD_WRAP_CHECK: the whole solid checked by OpenCascade, to test the direct way)
            if (getenv("HCAD_WRAP_CHECK")) {
                if (!BRepCheck_Analyzer(solid, true, true).IsValid())
                    throw Standard_Failure("direct: the solid came out broken");
            } else {
                const TopoDS_Shape nearIn = inResult(holedNear), farIn = through ? inResult(holedFarFace) : TopoDS_Shape();
                std::vector<TopoDS_Face> others;
                for (TopExp_Explorer x(solid, TopAbs_FACE); x.More(); x.Next())
                    if (!x.Current().IsSame(nearIn) && !(through && x.Current().IsSame(farIn)))
                        others.push_back(TopoDS::Face(x.Current()));
                std::atomic<bool> sound{true};
                OSD_Parallel::For(0, (int)others.size(), [&](int i) {
                    if (sound && !BRepCheck_Analyzer(others[i], true).IsValid())
                        sound = false;
                }, others.size() < 64);
                const bool apart = sound && outlines_apart(holeOutlines);
                if (getenv("HCAD_WRAP_DEBUG"))
                    fprintf(stderr, "wrap: faces sound %d, holes apart %d (%zu holes)\n", (int)sound.load(), (int)apart,
                            holeOutlines.size());
                if (!apart)
                    throw Standard_Failure("direct: the solid came out broken");
            }
            laps.lap("direct: closed and valid");
            // valid as hc_is_valid would say: its faces checked, its holes apart, closed with its volume as it
            // should be; its volume known
            hc_shape *r = checked(primitive(solid));
            if (r)
                r->volume = after;
            // the faces kept from the solid's own, the holed face (and the far one) from theirs; the
            // texture's walls and patches new, made from the face they texture as well (its tags)
            {
                const TopoDS_Shape nearIn = inResult(holedNear);
                const TopoDS_Shape farIn = through ? inResult(holedFarFace) : TopoDS_Shape();
                TopTools_IndexedMapOfShape res;
                TopExp::MapShapes(solid, TopAbs_FACE, res);
                for (int j = 1; j <= res.Extent(); j++) {
                    const TopoDS_Shape &f = res(j);
                    const int i = m.FindIndex(f);
                    if (i > 0)
                        history_from(j, Origin{0, i - 1});
                    else if (f.IsSame(nearIn))
                        history_from(j, Origin{0, face});
                    else if (through && f.IsSame(farIn))
                        history_from(j, Origin{0, farFace - 1});
                    else
                        g_also.push_back(Also{j - 1, Origin{0, face}});
                }
            }
            return r;
        }

        std::vector<TopoDS_Shape> tools;
        for (const TopoDS_Face &pf : faces_of(profile->shape)) {
            const auto loops = loopsOf(pf);
            // the region on both offset surfaces, and the sides between them
            std::vector<std::vector<TopoDS_Edge>> eIn, eOut;
            auto faceOn = [&](const Handle(Geom_Surface) &surf, std::vector<std::vector<TopoDS_Edge>> &edges) {
                BRepBuilderAPI_MakeFace mf;
                bool first = true;
                for (auto &loop : loops) {
                    BRepBuilderAPI_MakeWire mw;
                    std::vector<TopoDS_Edge> es;
                    for (auto &c2 : loop) {
                        TopoDS_Edge e = BRepBuilderAPI_MakeEdge(c2, surf).Edge();
                        BRepLib::BuildCurves3d(e, 1e-7);
                        mw.Add(e);
                        if (!mw.IsDone())
                            throw Standard_Failure("the profile's outline does not close on the face");
                        es.push_back(mw.Edge());
                    }
                    edges.push_back(es);
                    if (first)
                        mf.Init(surf, Standard_False, 1e-7);
                    mf.Add(mw.Wire());
                    first = false;
                }
                ShapeFix_Face fix(mf.Face());
                fix.FixOrientationMode() = 1;
                fix.Perform();
                return fix.Face();
            };
            const TopoDS_Face bottom = faceOn(Sin, eIn), top = faceOn(Sout, eOut);
            BRepBuilderAPI_Sewing sew(1e-5);
            sew.Add(bottom);
            sew.Add(top);
            for (size_t i = 0; i < eIn.size(); i++)
                for (size_t j = 0; j < eIn[i].size(); j++)
                    sew.Add(BRepFill::Face(eIn[i][j], eOut[i][j]));
            sew.Perform();
            TopoDS_Shell shell;
            for (TopExp_Explorer sh(sew.SewedShape(), TopAbs_SHELL); sh.More(); sh.Next())
                shell = TopoDS::Shell(sh.Current());
            if (shell.IsNull())
                throw Standard_Failure("a region laid on the face did not close into a solid");
            BRepBuilderAPI_MakeSolid ms(shell);
            TopoDS_Solid solid = ms.Solid();
            BRepLib::OrientClosedSolid(solid);
            if (solid_volume(solid) <= 0)
                throw Standard_Failure("a region laid on the face gave no volume");
            // a sliver (a cell cut at the border of the profile, a short arc) can come out
            // broken, and one broken tool breaks the whole cut: mended, or left out
            if (!BRepCheck_Analyzer(solid).IsValid()) {
                ShapeFix_Shape fix(solid);
                fix.Perform();
                if (!BRepCheck_Analyzer(fix.Shape()).IsValid() || solid_volume(fix.Shape()) <= 0) {
                    g_wrap_skipped++;
                    continue;
                }
                tools.push_back(fix.Shape());
                continue;
            }
            tools.push_back(solid);
        }
        if (tools.empty())
            throw Standard_Failure("the profile is empty");
        return primitive(compound_of(tools));
    });
}

hc_shape *hc_wrap_tool(const hc_shape *s, int face, const hc_shape *profile, int project, const double *at,
                       const double *dir, double inner, double outer)
{
    return wrap_impl(s, face, profile, project, at, dir, inner, outer, false);
}

// The same, the solid itself with the regions dug in (floor < 0) or raised (floor > 0) by `floor` along
// the face's normal, built at once with no boolean: nullptr (and an error) when that cannot be done.
hc_shape *hc_wrap_direct(const hc_shape *s, int face, const hc_shape *profile, int project, const double *at,
                         const double *dir, double floor)
{
    return wrap_impl(s, face, profile, project, at, dir, floor, 0, true);
}

// Face `face` of `s` unrolled flat as wrap lays a profile on it (the same anchor, axes and lengths, at
// `at`, NaN its default place): its outline and holes as one face on XY; *round the length once round it when it
// closes round on itself (the side of a vase, a loft through rings), else 0.
hc_shape *hc_wrap_flat(const hc_shape *s, int face, const double *at, double *round_, double *middle)
{
    const double zero3[3] = {0, 0, 0};
    WrapAsk ask;
    ask.round = round_;
    ask.middle = middle;
    return wrap_impl(s, face, nullptr, 0, at, zero3, 0, 0, false, ask);
}

// Which regions of `profile` (by their order among its faces) the direct wrap would find not wholly inside
// face `face` of `s`, laid as hc_wrap_direct lays them: up to `max` of them in `out`, how many there are;
// *regions how many regions the profile has. -1 (and an error) when the face takes no direct wrap at all.
int hc_wrap_outside(const hc_shape *s, int face, const hc_shape *profile, int project, const double *at,
                    const double *dir, double floor, int *out, int max, int *regions)
{
    std::vector<int> outside;
    bool classified = false;
    WrapAsk ask;
    ask.outside = &outside;
    ask.classified = &classified;
    wrap_impl(s, face, profile, project, at, dir, floor, 0, true, ask);
    if (!classified)
        return -1;
    *regions = (int)faces_of(profile->shape).size();
    for (int i = 0; i < (int)outside.size() && i < max; i++)
        out[i] = outside[i];
    return (int)outside.size();
}

// The regions of a profile chosen by their order among its faces, as one profile.
hc_shape *hc_profile_regions(const hc_shape *profile, const int *which, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        const auto faces = faces_of(profile->shape);
        std::vector<TopoDS_Shape> picked;
        for (int i = 0; i < n; i++) {
            if (which[i] < 0 || which[i] >= (int)faces.size())
                throw Standard_Failure("no such region");
            picked.push_back(faces[which[i]]);
        }
        if (picked.empty())
            throw Standard_Failure("no region chosen");
        return wrap(compound_of(picked));
    });
}

// Up to n points inside the flat faces of `s` (in any plane), at least `margin` from their edges, as far
// apart from each other as they can be: a grid of points over each face kept where it lies inside, then the one farthest from their
// middle, the one farthest from it, and so on, each the farthest from those chosen. x y z of each in
// `out` (room for 3 n); how many there are.
int hc_spots(const hc_shape *s, int n, double margin, double *out)
{
    return guarded<>(-1, [&]() -> int {
        // the edges as points close together, to keep the candidates `margin` from them all
        std::vector<gp_Pnt> rim;
        if (margin > 0) {
            const double step = std::max(margin / 6, 0.05);
            for (TopExp_Explorer e(s->shape, TopAbs_EDGE); e.More(); e.Next()) {
                BRepAdaptor_Curve c(TopoDS::Edge(e.Current()));
                const double len = GCPnts_AbscissaPoint::Length(c);
                const int k = std::max(2, (int)std::ceil(len / step));
                for (int i = 0; i <= k; i++)
                    rim.push_back(c.Value(c.FirstParameter() + (c.LastParameter() - c.FirstParameter()) * i / k));
            }
        }
        auto clear = [&](const gp_Pnt &q) {
            for (const gp_Pnt &r : rim)
                if (q.SquareDistance(r) < margin * margin)
                    return false;
            return true;
        };
        std::vector<gp_Pnt> cand;
        for (const TopoDS_Face &f : faces_of(s->shape)) {
            double u0, u1, v0, v1;
            BRepTools::UVBounds(f, u0, u1, v0, v1);
            BRepTopAdaptor_FClass2d inside(f, 1e-7);
            BRepAdaptor_Surface surf(f);
            const int g = 60;
            for (int i = 0; i <= g; i++)
                for (int j = 0; j <= g; j++) {
                    const gp_Pnt2d q(u0 + (u1 - u0) * i / g, v0 + (v1 - v0) * j / g);
                    if (inside.Perform(q) == TopAbs_IN) {
                        const gp_Pnt p = surf.Value(q.X(), q.Y());
                        if (clear(p))
                            cand.push_back(p);
                    }
                }
        }
        if (cand.empty() || n < 1)
            return 0;
        gp_XYZ mid(0, 0, 0);
        for (auto &c : cand)
            mid += c.XYZ();
        mid /= (double)cand.size();
        std::vector<gp_Pnt> chosen;
        std::vector<double> nearest(cand.size(), 0);
        for (size_t i = 0; i < cand.size(); i++)
            nearest[i] = cand[i].Distance(gp_Pnt(mid));
        while ((int)chosen.size() < n) {
            size_t best = 0;
            for (size_t i = 1; i < cand.size(); i++)
                if (nearest[i] > nearest[best])
                    best = i;
            if (!chosen.empty() && nearest[best] < 1e-9)
                break;
            chosen.push_back(cand[best]);
            for (size_t i = 0; i < cand.size(); i++)
                nearest[i] = chosen.size() == 1 ? cand[i].Distance(cand[best])
                                                : std::min(nearest[i], cand[i].Distance(cand[best]));
        }
        // for one point: the middle, or the candidate nearest it
        if (n == 1) {
            size_t best = 0;
            for (size_t i = 1; i < cand.size(); i++)
                if (cand[i].Distance(gp_Pnt(mid)) < cand[best].Distance(gp_Pnt(mid)))
                    best = i;
            chosen = {cand[best]};
        }
        for (size_t i = 0; i < chosen.size(); i++) {
            out[3 * i] = chosen[i].X();
            out[3 * i + 1] = chosen[i].Y();
            out[3 * i + 2] = chosen[i].Z();
        }
        return (int)chosen.size();
    });
}

// The volume solid `s` sweeps moving along v (in a straight line, not turning): `s` and every face of
// it looking towards v swept along v (a point of the sweep leaves `s` through such a face), joined; a
// cylinder split first where it turns from facing v to facing away, a face along v (a plane, a
// cylinder round v) sweeping nothing. Planes and cylinders only (input 0 is `s`): other faces fail.
hc_shape *hc_sweep_solid(const hc_shape *s, double vx, double vy, double vz)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        const gp_Vec v(vx, vy, vz);
        const double len = v.Magnitude();
        if (len < 1e-9) {
            set_error("no direction to sweep along");
            return nullptr;
        }
        const gp_Dir dir(v);
        Bnd_Box box;
        BRepBndLib::Add(s->shape, box);
        const double reach = std::sqrt(box.SquareExtent()) + len + 1;
        std::vector<TopoDS_Shape> prisms;
        auto sweep = [&](const TopoDS_Face &f) {
            BRepPrimAPI_MakePrism p(f, v);
            if (!p.IsDone())
                throw Standard_Failure("a face could not be swept");
            prisms.push_back(p.Shape());
        };
        // whether a face (or a piece of one) looks towards v, by its normal at its middle
        auto ahead = [&](const TopoDS_Face &f) {
            double u0, u1, v0, v1;
            BRepTools::UVBounds(f, u0, u1, v0, v1);
            BRepAdaptor_Surface a(f);
            BRepLProp_SLProps lp(a, (u0 + u1) / 2, (v0 + v1) / 2, 1, 1e-6);
            if (!lp.IsNormalDefined())
                return false;
            gp_Dir n = lp.Normal();
            if (f.Orientation() == TopAbs_REVERSED)
                n.Reverse();
            return n.Dot(dir) > 1e-9;
        };
        for (TopExp_Explorer e(s->shape, TopAbs_FACE); e.More(); e.Next()) {
            const TopoDS_Face &f = TopoDS::Face(e.Current());
            BRepAdaptor_Surface surf(f);
            if (surf.GetType() == GeomAbs_Plane) {
                gp_Dir n = surf.Plane().Axis().Direction();
                if (f.Orientation() == TopAbs_REVERSED)
                    n.Reverse();
                if (n.Dot(dir) > 1e-9)
                    sweep(f);
                continue;
            }
            if (surf.GetType() != GeomAbs_Cylinder)
                throw Standard_Failure("only flat and cylindrical faces are swept");
            const gp_Ax1 ax = surf.Cylinder().Axis();
            const gp_Vec along(ax.Direction());
            const gp_Vec across = v - along * v.Dot(along);
            if (across.Magnitude() < 1e-9 * len)
                continue;   // round v: it sweeps along itself
            // split where it turns from facing v to facing away: the plane through its axis across v
            const TopoDS_Face cut = BRepBuilderAPI_MakeFace(gp_Pln(ax.Location(), gp_Dir(across)), -reach, reach,
                                                            -reach, reach);
            BRepAlgoAPI_Splitter sp;
            TopTools_ListOfShape args, tools;
            args.Append(f);
            tools.Append(cut);
            sp.SetArguments(args);
            sp.SetTools(tools);
            sp.Build();
            if (!sp.IsDone())
                throw Standard_Failure("a curved face could not be split");
            for (TopExp_Explorer p(sp.Shape(), TopAbs_FACE); p.More(); p.Next())
                if (ahead(TopoDS::Face(p.Current())))
                    sweep(TopoDS::Face(p.Current()));
        }
        if (prisms.empty()) {
            history_new(s->shape);
            for (size_t i = 0; i < g_history.size(); i++)
                g_history[i] = Origin{0, (int)i};
            return wrap(s->shape);
        }
        TopTools_ListOfShape args, tools;
        args.Append(s->shape);
        std::vector<const TopoDS_Shape *> inputs{&s->shape};
        for (const auto &p : prisms) {
            tools.Append(p);
            inputs.push_back(&p);
        }
        BRepAlgoAPI_Fuse fuse;
        fuse.SetArguments(args);
        fuse.SetTools(tools);
        fuse.SetRunParallel(Standard_True);
        fuse.Build();
        if (!fuse.IsDone() || fuse.HasErrors())
            throw Standard_Failure("joining the swept faces failed");
        history_record(fuse, inputs, fuse.Shape());
        return wrap(unify_history(fuse.Shape()));
    });
}

hc_shape *hc_face_prism(const hc_shape *s, int face, double vx, double vy, double vz)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        const auto &m = map_of(s, TopAbs_FACE);
        if (face < 0 || face >= m.Extent()) {
            set_error("no such face");
            return nullptr;
        }
        const TopoDS_Face f = TopoDS::Face(m(face + 1));
        BRepAdaptor_Surface surf(f);
        if (surf.GetType() != GeomAbs_Plane) {
            set_error("only flat faces can be pushed or pulled");
            return nullptr;
        }
        const gp_Vec v(vx, vy, vz);
        if (std::abs(v.Dot(gp_Vec(surf.Plane().Axis().Direction()))) < 1e-9 * (v.Magnitude() + 1)) {
            set_error("the direction lies in the face's plane: the face would sweep no volume");
            return nullptr;
        }
        BRepPrimAPI_MakePrism prism(f, v);
        if (!prism.IsDone()) {
            set_error("the face could not be swept");
            return nullptr;
        }
        // its two ends from the face swept: the face where it was and where it ends
        history_new(prism.Shape());
        TopTools_IndexedMapOfShape res;
        TopExp::MapShapes(prism.Shape(), TopAbs_FACE, res);
        for (const TopoDS_Shape &end : {prism.FirstShape(), prism.LastShape()}) {
            const int j = res.FindIndex(end);
            if (j > 0)
                history_from(j, Origin{0, face});
        }
        return wrap(prism.Shape());
    });
}

hc_shape *hc_shell(const hc_shape *s, const int *faces, int nfaces, double thickness)
{
    return guarded<>((hc_shape *)nullptr, [&] {
        const auto &m = map_of(s, TopAbs_FACE);
        TopTools_ListOfShape remove;
        for (int i = 0; i < nfaces; i++)
            remove.Append(m(faces[i] + 1));
        GProp_GProps before;
        BRepGProp::VolumeProperties(s->shape, before);
        // a wall `thickness` thick holds about the area of the kept faces times
        // the thickness; a result far above that was not hollowed (the offset
        // can return a sound solid that is the input with only a skin removed)
        GProp_GProps skin;
        BRepGProp::SurfaceProperties(s->shape, skin);
        double open = 0;
        for (int i = 0; i < nfaces; i++) {
            GProp_GProps f;
            BRepGProp::SurfaceProperties(m(faces[i] + 1), f);
            open += f.Mass();
        }
        const double most = 2 * (skin.Mass() - open) * thickness;
        // WORKAROUND (OpenCascade 7.9.3, BRepOffsetAPI_MakeThickSolid): its
        // strategies fail, or return a broken solid, on shapes others hollow
        // well (the espresso cup needs the second), and on some shapes all
        // fail: the first sound result is kept, and the fallback below takes
        // over after them. The "known bugs" unittest in lang/tests.d turns
        // this off (HC_WORKAROUND_SHELL_STRATEGIES: the first strategy only,
        // no fallback) and fails once the cup hollows that way; then the
        // other strategies, and maybe the fallback, can go.
        struct Try {
            GeomAbs_JoinType join;
            bool intersection;
        };
        std::vector<Try> tries = {Try{GeomAbs_Arc, false}};
        if (workaround(HC_WORKAROUND_SHELL_STRATEGIES))
            tries = {Try{GeomAbs_Arc, false}, Try{GeomAbs_Intersection, true}, Try{GeomAbs_Arc, true},
                     Try{GeomAbs_Intersection, false}};
        for (Try t : tries) {
            try {
                BRepOffsetAPI_MakeThickSolid mk;
                // negative thickness keeps the outer skin and grows inwards
                mk.MakeThickSolidByJoin(s->shape, remove, -thickness, 1e-4, BRepOffset_Skin, t.intersection, false,
                                        t.join);
                if (!mk.IsDone())
                    continue;
                TopoDS_Shape r = mk.Shape();
                if (r.IsNull() || !BRepCheck_Analyzer(r).IsValid())
                    continue;
                GProp_GProps after;
                BRepGProp::VolumeProperties(r, after);
                if (after.Mass() <= 0 || after.Mass() >= before.Mass() || after.Mass() > most)
                    continue;
                history_record(mk, {&s->shape}, r);
                return wrap(r);
            } catch (const Standard_Failure &) {
            }
        }
        // fallback: the solid minus a copy shrunk by the thickness, then a slab
        // as thick as the wall removed under each open (planar) face
        if (workaround(HC_WORKAROUND_SHELL_STRATEGIES))
        try {
            BRepOffsetAPI_MakeOffsetShape off;
            off.PerformByJoin(s->shape, -thickness, 1e-4, BRepOffset_Skin, false, false, GeomAbs_Arc);
            if (off.IsDone()) {
                TopoDS_Shape inner = off.Shape();
                if (!TopExp_Explorer(inner, TopAbs_SOLID).More()) {
                    BRepBuilderAPI_MakeSolid ms;
                    for (TopExp_Explorer e(inner, TopAbs_SHELL); e.More(); e.Next())
                        ms.Add(TopoDS::Shell(e.Current()));
                    inner = ms.Solid();
                }
                // the cavity, carried out through the open faces: copies shifted
                // outwards along their normals (and along sums of them, for the
                // edges between two open faces), each kept only beyond the walls
                Bnd_Box bb;
                BRepBndLib::Add(s->shape, bb);
                double size = 4 * std::sqrt(bb.SquareExtent()) + 10;
                struct Opening {
                    gp_Dir n;
                    TopoDS_Shape half;
                };
                std::vector<Opening> open;
                bool planar = true;
                for (int i = 0; i < nfaces && planar; i++) {
                    TopoDS_Face f = TopoDS::Face(m(faces[i] + 1));
                    BRepAdaptor_Surface surf(f);
                    if (surf.GetType() != GeomAbs_Plane) {
                        planar = false;
                        break;
                    }
                    gp_Dir n = surf.Plane().Axis().Direction();
                    if (f.Orientation() == TopAbs_REVERSED)
                        n.Reverse();
                    gp_Pnt on = surf.Value((surf.FirstUParameter() + surf.LastUParameter()) / 2,
                                           (surf.FirstVParameter() + surf.LastVParameter()) / 2);
                    gp_Dir x = std::abs(n.Z()) < 0.9 ? gp_Dir(gp_Vec(n).Crossed(gp_Vec(0, 0, 1))) : gp_Dir(1, 0, 0);
                    gp_Dir y = n.Crossed(x);
                    // a half space starting just inside the face
                    gp_Pnt corner = on.Translated(gp_Vec(n) * (-thickness * 1.2) - gp_Vec(x) * (size / 2) - gp_Vec(y) * (size / 2));
                    open.push_back({n, BRepPrimAPI_MakeBox(gp_Ax2(corner, n, x), size, size, size).Shape()});
                }
                TopoDS_Shape cutter = inner;
                const size_t k = open.size();
                for (size_t mask = 1; planar && k <= 4 && mask < (size_t(1) << k); mask++) {
                    gp_Vec shift(0, 0, 0);
                    for (size_t i = 0; i < k; i++)
                        if (mask & (size_t(1) << i))
                            shift += gp_Vec(open[i].n) * (thickness * 1.5);
                    gp_Trsf t;
                    t.SetTranslation(shift);
                    TopoDS_Shape piece = BRepBuilderAPI_Transform(inner, t, true).Shape();
                    for (size_t i = 0; i < k; i++)
                        if (mask & (size_t(1) << i))
                            piece = BRepAlgoAPI_Common(piece, open[i].half).Shape();
                    cutter = BRepAlgoAPI_Fuse(cutter, piece).Shape();
                }
                TopoDS_Shape r = BRepAlgoAPI_Cut(s->shape, cutter).Shape();
                if (planar && !r.IsNull() && BRepCheck_Analyzer(r).IsValid()) {
                    GProp_GProps after;
                    BRepGProp::VolumeProperties(r, after);
                    if (after.Mass() > 0 && after.Mass() < before.Mass() && after.Mass() <= most) {
                        history_new(r);
                        return wrap(r);
                    }
                }
            }
        } catch (const Standard_Failure &) {
        }
        set_error("the kernel could not hollow this solid: the wall must be thinner than the smallest fillet "
                  "radius and than narrow parts (try a thinner wall, or shell before filleting)");
        return (hc_shape *)nullptr;
    });
}

hc_shape *hc_draft(const hc_shape *s, const int *faces, int nfaces, double angle_rad,
                   double px, double py, double pz, double nx, double ny, double nz)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        const auto &m = map_of(s, TopAbs_FACE);
        gp_Dir pull(nx, ny, nz);
        gp_Pln neutral(gp_Pnt(px, py, pz), pull);
        BRepOffsetAPI_DraftAngle mk(s->shape);
        for (int i = 0; i < nfaces; i++) {
            mk.Add(TopoDS::Face(m(faces[i] + 1)), pull, angle_rad, neutral);
            if (!mk.AddDone()) {
                set_error("draft cannot be applied to one of the faces");
                return nullptr;
            }
        }
        mk.Build();
        require_valid(mk.Shape(), "draft failed: the result is not a valid solid");
        history_record(mk, {&s->shape}, mk.Shape());
        // the faces tilted are new faces to Modified(): each from the face it tilts
        TopTools_IndexedMapOfShape res;
        TopExp::MapShapes(mk.Shape(), TopAbs_FACE, res);
        for (int i = 1; i <= m.Extent(); i++) {
            const int j = res.FindIndex(mk.ModifiedShape(m(i)));
            if (j > 0)
                history_from(j, Origin{0, i - 1});
        }
        return checked(wrap(mk.Shape()));
    });
}

int hc_edge_faces(const hc_shape *s, int *out)
{
    return guarded<>(-1, [&]() -> int {
        TopTools_IndexedDataMapOfShapeListOfShape adj;
        TopExp::MapShapesAndAncestors(s->shape, TopAbs_EDGE, TopAbs_FACE, adj);
        const auto &faces = map_of(s, TopAbs_FACE);
        const auto &edges = map_of(s, TopAbs_EDGE);
        for (int e = 1; e <= edges.Extent(); e++) {
            int *pair = out + 2 * (e - 1);
            pair[0] = pair[1] = -1;
            int n = 0;
            const TopTools_ListOfShape &l = adj.FindFromKey(edges(e));
            for (TopTools_ListOfShape::Iterator it(l); it.More() && n < 2; it.Next()) {
                int j = faces.FindIndex(it.Value());
                if (j > 0 && (n == 0 || pair[0] != j - 1))
                    pair[n++] = j - 1;
            }
            // a seam, where one curved face closes on itself (a cylinder's side), or a sphere's pole
            // (an edge of no length): -2, no edge to round
            const TopoDS_Edge &edge = TopoDS::Edge(edges(e));
            if (n == 1 && (BRep_Tool::Degenerated(edge) || BRep_Tool::IsClosed(edge, TopoDS::Face(faces(pair[0] + 1)))))
                pair[1] = -2;
        }
        return edges.Extent();
    });
}

double hc_distance(const hc_shape *a, const hc_shape *b, double out[6])
{
    return guarded<>(-1.0, [&]() -> double {
        auto put = [&](const gp_Pnt &p, const gp_Pnt &q) {
            double v[6] = {p.X(), p.Y(), p.Z(), q.X(), q.Y(), q.Z()};
            for (int i = 0; i < 6; i++)
                out[i] = v[i];
        };
        // Between the boundaries only: with solids, BRepExtrema classifies every
        // vertex of one in the other, which is very slow on imported meshes.
        // Closed solids whose boundaries do not touch either are apart or one
        // contains the other, and one point per solid tells which.
        auto boundary = [](const TopoDS_Shape &s) {
            if (!TopExp_Explorer(s, TopAbs_SOLID).More())
                return s;
            TopoDS_Compound c;
            BRep_Builder bb;
            bb.MakeCompound(c);
            for (TopExp_Explorer ex(s, TopAbs_SHELL); ex.More(); ex.Next())
                bb.Add(c, ex.Current());
            return TopoDS_Shape(c);
        };
        BRepExtrema_DistShapeShape d;
        d.SetMultiThread(Standard_True);   // the pairs of faces on every core
        d.LoadS1(boundary(a->shape));
        d.LoadS2(boundary(b->shape));
        d.Perform();
        if (!d.IsDone() || d.NbSolution() == 0) {
            set_error("distance computation failed");
            return -1.0;
        }
        if (d.Value() > Precision::Confusion()) {
            auto inside = [&](const TopoDS_Shape &outer, const TopoDS_Shape &inner, gp_Pnt &at) {
                // one within the other only if its box is within the other's: not, no point to classify
                // (a classifier on an imported mesh builds a structure over its thousands of faces)
                Bnd_Box bo, bi;
                BRepBndLib::Add(outer, bo, false);
                BRepBndLib::Add(inner, bi, false);
                if (bo.IsVoid() || bi.IsVoid())
                    return false;
                double ox0, oy0, oz0, ox1, oy1, oz1, ix0, iy0, iz0, ix1, iy1, iz1;
                bo.Get(ox0, oy0, oz0, ox1, oy1, oz1);
                bi.Get(ix0, iy0, iz0, ix1, iy1, iz1);
                if (ix0 < ox0 || iy0 < oy0 || iz0 < oz0 || ix1 > ox1 || iy1 > oy1 || iz1 > oz1)
                    return false;
                for (TopExp_Explorer s(outer, TopAbs_SOLID); s.More(); s.Next())
                    for (TopExp_Explorer i(inner, TopAbs_SOLID); i.More(); i.Next()) {
                        TopExp_Explorer v(i.Current(), TopAbs_VERTEX);
                        if (!v.More())
                            continue;
                        at = BRep_Tool::Pnt(TopoDS::Vertex(v.Current()));
                        BRepClass3d_SolidClassifier cls(s.Current(), at, Precision::Confusion());
                        if (cls.State() == TopAbs_IN)
                            return true;
                    }
                return false;
            };
            gp_Pnt at;
            if (inside(a->shape, b->shape, at) || inside(b->shape, a->shape, at)) {
                put(at, at);
                return 0.0;
            }
        }
        put(d.PointOnShape1(1), d.PointOnShape2(1));
        return d.Value();
    });
}

static bool plain_triangle(const TopoDS_Face &face, gp_Pnt p[3]);

// Volume and area of a solid made of plain triangles (an imported mesh),
// summed from the triangles: BRepGProp integrates every face, which takes
// about a second for 50 000 of them. False when a face is anything else.
static bool triangle_properties(const hc_shape *s, double &volume, double &area)
{
    const auto &faces = map_of(s, TopAbs_FACE);
    if (faces.Extent() < 500)
        return false;
    volume = area = 0;
    gp_Pnt p[3];
    for (int f = 1; f <= faces.Extent(); f++) {
        if (!plain_triangle(TopoDS::Face(faces(f)), p))
            return false;
        gp_Vec a(p[0].XYZ()), b(p[1].XYZ()), c(p[2].XYZ());
        volume += a.Dot(b.Crossed(c)) / 6;
        area += gp_Vec(p[0], p[1]).Crossed(gp_Vec(p[0], p[2])).Magnitude() / 2;
    }
    return true;
}

// The relative accuracy of the volumes, areas and moments reported: the
// plain (Gauss) integration is off by 5% and more on long freeform faces
// (an M8 × 50 thread came out 1967 mm³ for 2066), the adaptive one is not.
static const double mass_accuracy = 1e-5;


// The volume summed over the triangles of the faces' meshes (meshed finely
// here when they have none), each face's turned as the face is.
static double mesh_volume(const TopoDS_Shape &shape)
{
    Bnd_Box box;
    BRepBndLib::Add(shape, box);
    const double diag = box.IsVoid() ? 1 : sqrt(box.SquareExtent());
    bool meshed = true;
    for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More() && meshed; ex.Next()) {
        TopLoc_Location loc;
        meshed = !BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), loc).IsNull();
    }
    if (!meshed)
        BRepMesh_IncrementalMesh(shape, std::min(0.01, diag * 1e-4), false, 0.2, true);
    double volume = 0;
    for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
        const TopoDS_Face &f = TopoDS::Face(ex.Current());
        TopLoc_Location loc;
        Handle(Poly_Triangulation) t = BRep_Tool::Triangulation(f, loc);
        if (t.IsNull())
            return -1;
        const gp_Trsf tr = loc.Transformation();
        const bool flip = f.Orientation() == TopAbs_REVERSED;
        for (int i = 1; i <= t->NbTriangles(); i++) {
            int a, b, c;
            t->Triangle(i).Get(a, b, c);
            if (flip)
                std::swap(b, c);
            gp_XYZ p = t->Node(a).Transformed(tr).XYZ(), q = t->Node(b).Transformed(tr).XYZ(),
                   r = t->Node(c).Transformed(tr).XYZ();
            volume += p.Dot(q.Crossed(r)) / 6;
        }
    }
    return volume;
}

double hc_volume(const hc_shape *s)
{
    if (s && !std::isnan(s->volume))
        return s->volume;
    return guarded<>(-1.0, [&] {
        double volume, area;
        if (triangle_properties(s, volume, area))
            return volume;
        // a face with many holes (a knurl, a tiling laid on a face): the adaptive integration to 1e-5
        // takes seconds over it, to 1e-3 a fraction, and gives the same volume to a few parts in a million
        // where Gauss points fixed per face are 3% off (holes through a cone's wall)
        for (TopExp_Explorer ex(s->shape, TopAbs_FACE); ex.More(); ex.Next()) {
            int wires = 0;
            for (TopExp_Explorer w(ex.Current(), TopAbs_WIRE); w.More() && wires <= 50; w.Next())
                wires++;
            if (wires > 50)
                return quick_volume(s->shape);
        }
        GProp_GProps p;
        BRepGProp::VolumeProperties(s->shape, p, mass_accuracy);
        // WORKAROUND (OCCT 7.9, BRepGProp): on freeform faces swept from a
        // smooth outline the adaptive integration can be far off (a hook
        // made of a smooth polygon extruded: 18300 mm³ for 10500, a smooth C:
        // +6%); the volume of the mesh is then the truer one. lang/tests.d
        // turns this off (HC_WORKAROUND_MESH_VOLUME) and fails once it is right
        // only on faces swept from a curve, where it goes wrong: meshing a big B-spline surface (a
        // loft through hundreds of rings) finely takes minutes and gigabytes, and its integration is right
        bool any = false;
        for (TopExp_Explorer ex(s->shape, TopAbs_FACE); ex.More() && !any; ex.Next())
            any = BRepAdaptor_Surface(TopoDS::Face(ex.Current()), Standard_False).GetType() == GeomAbs_SurfaceOfExtrusion;
        if (any && workaround(HC_WORKAROUND_MESH_VOLUME)) {
            const double m = mesh_volume(s->shape);
            if (m > 0 && std::abs(m - p.Mass()) > 0.01 * m)
                return m;
        }
        return p.Mass();
    });
}

// Mass properties per unit density: out = volume, the centre of mass
// (x y z) and the principal moments of inertia about it (three, ascending).
int hc_mass_props(const hc_shape *s, double out[7])
{
    return guarded<>(-1, [&]() -> int {
        GProp_GProps p;
        BRepGProp::VolumeProperties(s->shape, p, mass_accuracy);
        if (p.Mass() <= 0) {
            set_error("the solid has no volume");
            return -1;
        }
        gp_Pnt c = p.CentreOfMass();
        double i1, i2, i3;
        p.PrincipalProperties().Moments(i1, i2, i3);
        double m[3] = {i1, i2, i3};
        std::sort(m, m + 3);
        double v[7] = {p.Mass(), c.X(), c.Y(), c.Z(), m[0], m[1], m[2]};
        for (int i = 0; i < 7; i++)
            out[i] = v[i];
        return 0;
    });
}

double hc_area(const hc_shape *s)
{
    return guarded<>(-1.0, [&] {
        double volume, area;
        if (triangle_properties(s, volume, area))
            return area;
        GProp_GProps p;
        BRepGProp::SurfaceProperties(s->shape, p, mass_accuracy);
        return p.Mass();
    });
}

int hc_bbox(const hc_shape *s, double out[6])
{
    Stage stage("bbox");
    return guarded<>(-1, [&] {
        // WORKAROUND (OpenCascade 7.9.3, BRepBndLib::AddOptimal): exact and
        // fast, but on tori (the fillets between planes) it takes ~10 ms per
        // face. Those get the box of a fine triangulation instead: its
        // vertices lie on the surface, so it is short by at most the
        // deflection. (Meshing B-splines, such as threads, is the slow one:
        // they keep AddOptimal.) To see whether it is still needed, time
        // AddOptimal on a box with its 12 edges filleted.
        Bnd_Box b;
        std::vector<TopoDS_Face> slow;
        // a solid of many faces (a knurl, a tiling laid on a face): its small faces, under 10 mm across,
        // boxed by points along their edges and a few inside, AddOptimal taking milliseconds each on a
        // surface offset from a B-spline. Over a face that small the surface bulges past its edges by
        // a few thousandths of a millimetre at most
        int faceCount = 0;
        for (TopExp_Explorer f(s->shape, TopAbs_FACE); f.More() && faceCount <= 500; f.Next())
            faceCount++;
        auto sampled = [](const TopoDS_Face &face, Bnd_Box &into) {
            // only where AddOptimal is slow: on a plane (a mesh's triangles) it is quicker than this
            const GeomAbs_SurfaceType st = BRepAdaptor_Surface(face, false).GetType();
            if (st != GeomAbs_BSplineSurface && st != GeomAbs_BezierSurface && st != GeomAbs_OffsetSurface
                && st != GeomAbs_OtherSurface)
                return false;
            // how large it is from points along its edges (a box from the surface's own would take in the
            // whole surface an offset face lies on)
            Bnd_Box edgesBox;
            for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
                const TopoDS_Edge &ed = TopoDS::Edge(e.Current());
                if (BRep_Tool::Degenerated(ed))
                    continue;
                BRepAdaptor_Curve c(ed);
                for (int k = 0; k <= 16; k++)
                    edgesBox.Add(c.Value(c.FirstParameter() + (c.LastParameter() - c.FirstParameter()) * k / 16));
            }
            if (edgesBox.IsVoid() || edgesBox.SquareExtent() > 100)
                return false;
            into.Add(edgesBox);
            // inside: the middle of its parameters, and halfway from there to its corners, where on it; a
            // face of four sides (a knurl's wall or floor) the middle only, which lies on it (a classifier
            // made for each of thousands of faces took longer than the rest)
            double u0, u1, v0, v1;
            BRepTools::UVBounds(face, u0, u1, v0, v1);
            BRepAdaptor_Surface a(face, Standard_True);
            int sides = 0;
            for (TopExp_Explorer e(BRepTools::OuterWire(face), TopAbs_EDGE); e.More() && sides <= 4; e.Next())
                sides++;
            if (sides <= 4) {
                int wires = 0;
                for (TopExp_Explorer w(face, TopAbs_WIRE); w.More() && wires < 2; w.Next())
                    wires++;
                if (wires == 1) {
                    into.Add(a.Value((u0 + u1) / 2, (v0 + v1) / 2));
                    return true;
                }
            }
            BRepTopAdaptor_FClass2d inside(face, 1e-7);
            const double um = (u0 + u1) / 2, vm = (v0 + v1) / 2;
            const double pts[5][2] = {{um, vm}, {(um + u0) / 2, (vm + v0) / 2}, {(um + u1) / 2, (vm + v0) / 2},
                                      {(um + u0) / 2, (vm + v1) / 2}, {(um + u1) / 2, (vm + v1) / 2}};
            for (auto &q : pts)
                if (inside.Perform(gp_Pnt2d(q[0], q[1])) == TopAbs_IN)
                    into.Add(a.Value(q[0], q[1]));
            return true;
        };
        // each face's box on its own (on every core: a knurl's thousands of faces), then all of them
        std::vector<TopoDS_Face> faces;
        for (TopExp_Explorer f(s->shape, TopAbs_FACE); f.More(); f.Next())
            faces.push_back(TopoDS::Face(f.Current()));
        std::vector<Bnd_Box> boxes(faces.size());
        std::vector<TopoDS_Face> slowOf(faces.size());
        auto boxFace = [&](int i) {
            const TopoDS_Face &face = faces[i];
            Bnd_Box &into = boxes[i];
            // a flat face with straight edges (a mesh's triangles, a polygon's sides): its corners are its box
            TopLoc_Location fl;
            const Handle(Geom_Surface) &fs = BRep_Tool::Surface(face, fl);
            if (!fs.IsNull() && fs->IsKind(STANDARD_TYPE(Geom_Plane))) {
                bool straight = true;
                for (TopExp_Explorer e(face, TopAbs_EDGE); e.More() && straight; e.Next()) {
                    const TopoDS_Edge &ed = TopoDS::Edge(e.Current());
                    if (BRep_Tool::Degenerated(ed))
                        continue;
                    TopLoc_Location el;
                    double f, l;
                    Handle(Geom_Curve) c = BRep_Tool::Curve(ed, el, f, l);
                    if (!c.IsNull() && c->IsKind(STANDARD_TYPE(Geom_TrimmedCurve)))
                        c = Handle(Geom_TrimmedCurve)::DownCast(c)->BasisCurve();
                    straight = !c.IsNull() && c->IsKind(STANDARD_TYPE(Geom_Line));
                }
                if (straight) {
                    for (TopExp_Explorer v(face, TopAbs_VERTEX); v.More(); v.Next())
                        into.Add(BRep_Tool::Pnt(TopoDS::Vertex(v.Current())));
                    return;
                }
            }
            if (faceCount > 500 && sampled(face, into))
                return;
            const GeomAbs_SurfaceType type = BRepAdaptor_Surface(face, false).GetType();
            // a B-spline (or a surface offset from one) trimmed by a boundary that is not its four sides
            // (fill's plates, thickened): its
            // box from the rectangle of parameters round the boundary takes in surface beyond it
            bool trimmed = false;
            if (type == GeomAbs_BSplineSurface || type == GeomAbs_BezierSurface || type == GeomAbs_OffsetSurface) {
                int edges = 0;
                for (TopExp_Explorer e(BRepTools::OuterWire(face), TopAbs_EDGE); e.More(); e.Next())
                    edges++;
                trimmed = edges != 4;
                // four sides that are not lines of its parameters (fill's plate through a closed path of
                // four points): the box of the parameters round them takes in surface beyond them too
                for (TopExp_Explorer e(BRepTools::OuterWire(face), TopAbs_EDGE); e.More() && !trimmed; e.Next()) {
                    double f, l;
                    const Handle(Geom2d_Curve) pc = BRep_Tool::CurveOnSurface(TopoDS::Edge(e.Current()), face, f, l);
                    if (pc.IsNull())
                        continue;
                    // along one parameter, the other constant: its ends and middle tell
                    const gp_Pnt2d p0 = pc->Value(f), p1 = pc->Value((f + l) / 2), p2 = pc->Value(l);
                    const double tol = 1e-9 * (1 + p0.Distance(p2));
                    const bool alongU = std::abs(p1.Y() - p0.Y()) < tol && std::abs(p2.Y() - p0.Y()) < tol;
                    const bool alongV = std::abs(p1.X() - p0.X()) < tol && std::abs(p2.X() - p0.X()) < tol;
                    trimmed = !alongU && !alongV;
                }
            }
            if (type == GeomAbs_Torus || trimmed) {
                // its holes do not reach past its outline: meshed without them (a face with hundreds of
                // holes, a knurl laid on it, takes seconds to mesh, its outline alone a moment)
                int wires = 0;
                for (TopExp_Explorer x(face, TopAbs_WIRE); x.More() && wires < 2; x.Next())
                    wires++;
                if (wires > 1) {
                    BRepBuilderAPI_MakeFace outline(BRep_Tool::Surface(face), BRepTools::OuterWire(face), Standard_True);
                    if (outline.IsDone()) {
                        slowOf[i] = outline.Face();
                        return;
                    }
                }
                slowOf[i] = face;
            }
            else {
                // its holes do not reach past its outline: boxed without them (AddOptimal works along every
                // edge, thousands round a knurl's holes)
                int wires = 0;
                for (TopExp_Explorer x(face, TopAbs_WIRE); x.More() && wires < 2; x.Next())
                    wires++;
                if (wires > 1) {
                    BRepBuilderAPI_MakeFace outline(BRep_Tool::Surface(face), BRepTools::OuterWire(face), Standard_True);
                    if (outline.IsDone()) {
                        BRepBndLib::AddOptimal(outline.Face(), into, false, false);
                        return;
                    }
                }
                BRepBndLib::AddOptimal(face, into, false, false);
            }
        };
        OSD_Parallel::For(0, (int)faces.size(), boxFace, faces.size() < 64);
        for (size_t i = 0; i < faces.size(); i++) {
            if (!boxes[i].IsVoid())
                b.Add(boxes[i]);
            if (!slowOf[i].IsNull())
                slow.push_back(slowOf[i]);
        }
        if (!slow.empty())
        {
            bool meshed = true;
            for (const auto &face : slow)
            {
                TopLoc_Location loc;
                meshed = meshed && !BRep_Tool::Triangulation(face, loc).IsNull();
            }
            Bnd_Box rough;
            BRepBndLib::Add(s->shape, rough, false);
            const double deflection = std::max(0.01, 1e-4 * std::sqrt(rough.SquareExtent()));
            for (const auto &face : slow)
            {
                BRepMesh_IncrementalMesh(face, deflection, false, 0.5, true);
                Bnd_Box fb;
                BRepBndLib::Add(face, fb, true);
                fb.SetGap(0);
                b.Add(fb);
            }
            // leave no fine mesh behind: tessellate() would reuse it
            if (!meshed)
                for (const auto &face : slow)
                    BRepTools::Clean(face);
        }
        if (!TopExp_Explorer(s->shape, TopAbs_FACE).More())
            BRepBndLib::AddOptimal(s->shape, b, false, false);   // wires, vertices
        b.Get(out[0], out[1], out[2], out[3], out[4], out[5]);
        // the box of a curve or surface found by search comes out a hair (1e-7, the kernel's precision)
        // past where it ends: a side ending at a corner ends there, so a part made on z = 0 has its
        // bottom at 0, not -1e-7, and exact comparisons hold
        Bnd_Box corners;
        for (TopExp_Explorer v(s->shape, TopAbs_VERTEX); v.More(); v.Next())
            corners.Add(BRep_Tool::Pnt(TopoDS::Vertex(v.Current())));
        if (!corners.IsVoid()) {
            double c[6];
            corners.Get(c[0], c[1], c[2], c[3], c[4], c[5]);
            for (int i = 0; i < 3; i++) {
                if (out[i] < c[i] && c[i] - out[i] < 1e-6)
                    out[i] = c[i];
                if (out[i + 3] > c[i + 3] && out[i + 3] - c[i + 3] < 1e-6)
                    out[i + 3] = c[i + 3];
            }
        }
        return 0;
    });
}

int hc_is_valid(const hc_shape *s)
{
    // the faces checked on every core: a solid made from a mesh has a face per
    // triangle (the phone stand example's phone: 7 s on one core)
    if (s && s->valid >= 0)
        return s->valid.load();
    const int r = guarded<>(0, [&] {
        // a face of thousands of holes (a grille) takes BRepCheck minutes: its
        // checks of a face's vertices and wires grow with the square of its
        // edges. Past 10 000 edges the check is that the surface closes (every
        // edge between two faces) round a positive volume
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(s->shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        if (edgeFaces.Extent() <= 10000)
            return BRepCheck_Analyzer(s->shape, Standard_True, Standard_True).IsValid() ? 1 : 0;
        for (int i = 1; i <= edgeFaces.Extent(); i++)
            if (!BRep_Tool::Degenerated(TopoDS::Edge(edgeFaces.FindKey(i))) && edgeFaces(i).Extent() != 2)
                return 0;
        GProp_GProps p;
        BRepGProp::VolumeProperties(s->shape, p);
        return p.Mass() > 0 ? 1 : 0;
    });
    if (s)
        s->valid = r;
    return r;
}

// A planar face bounded by three straight edges (the faces of an imported
// mesh): its triangle, counter-clockwise seen from outside. Meshing tens of
// thousands of these with BRepMesh takes seconds.
static bool plain_triangle(const TopoDS_Face &face, gp_Pnt p[3])
{
    TopoDS_Wire outer;
    int wires = 0;
    for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next(), wires++)
        outer = TopoDS::Wire(w.Current());
    if (wires != 1)
        return false;
    BRepAdaptor_Surface surface(face, false);
    if (surface.GetType() != GeomAbs_Plane)
        return false;
    int n = 0;
    for (BRepTools_WireExplorer e(outer, face); e.More(); e.Next()) {
        if (n == 3 || BRepAdaptor_Curve(e.Current()).GetType() != GeomAbs_Line)
            return false;
        p[n++] = BRep_Tool::Pnt(e.CurrentVertex());
    }
    if (n != 3)
        return false;
    gp_Pln plane = surface.Plane();
    gp_Vec outward(plane.Axis().Direction());
    if (!plane.Direct())
        outward.Reverse();
    if (face.Orientation() == TopAbs_REVERSED)
        outward.Reverse();
    if (gp_Vec(p[0], p[1]).Crossed(gp_Vec(p[0], p[2])).Dot(outward) < 0)
        std::swap(p[1], p[2]);
    return true;
}

// The area of a face's triangulation, 0 without one.
static double mesh_area(const TopoDS_Face &face)
{
    TopLoc_Location loc;
    auto tri = BRep_Tool::Triangulation(face, loc);
    if (tri.IsNull())
        return 0;
    double a = 0;
    for (int i = 1; i <= tri->NbTriangles(); i++) {
        int n1, n2, n3;
        tri->Triangle(i).Get(n1, n2, n3);
        a += gp_Vec(tri->Node(n1), tri->Node(n2)).Crossed(gp_Vec(tri->Node(n1), tri->Node(n3))).Magnitude() / 2;
    }
    return a;
}

// WORKAROUND (OpenCascade 7.9.3, BRepMesh): on long freeform faces, such as
// the flanks of a thread swept along a helix, the mesher can lose a face's
// trimming loop and cover more than the face, with triangles folded over
// each other, at some sizes only (an M8 × 25 thread, not × 22 or × 28),
// though the solid is valid. meshed_badly finds those faces (the area of
// their mesh differs from theirs) and hc_tessellate meshes them divided.
// Whether a newer OpenCascade still needs it: the "known bugs" unittest in
// lang/tests.d turns it off (HC_WORKAROUND_MESH_DIVIDE) and fails once the
// bug is gone; then this, mesh_area and the division loop in hc_tessellate
// can go.

// Whether the mesher got a face wrong (see the WORKAROUND above). Analytic
// faces mesh well and are not checked.
static bool meshed_badly(const TopoDS_Face &face)
{
    if (!workaround(HC_WORKAROUND_MESH_DIVIDE))
        return false;
    if (BRepAdaptor_Surface(face, false).GetType() <= GeomAbs_Torus)
        return false;
    // the plain (Gauss) integration first, much faster; it can be 5% off
    // itself on long faces, so a face it finds wrong is measured again with
    // the adaptive one before it counts
    const double meshed = mesh_area(face);
    auto off = [&](double exact) { return std::abs(meshed - exact) > std::max(0.01, 0.02 * exact); };
    GProp_GProps quick;
    BRepGProp::SurfaceProperties(face, quick);
    if (!off(quick.Mass()))
        return false;
    GProp_GProps exact;
    BRepGProp::SurfaceProperties(face, exact, mass_accuracy);
    return off(exact.Mass());
}

hc_mesh *hc_tessellate(const hc_shape *s, double linear_deflection, double angular_deflection)
{
    return guarded<>((hc_mesh *)nullptr, [&]() -> hc_mesh * {
        // faces in the same order as the face indices used everywhere else;
        // plain triangles are taken as they are, the rest is meshed
        const auto &faces = map_of(s, TopAbs_FACE);
        std::vector<std::array<gp_Pnt, 3>> plain(faces.Extent());
        std::vector<bool> isPlain(faces.Extent());
        TopoDS_Compound rest;
        BRep_Builder bb;
        bb.MakeCompound(rest);
        bool anyRest = false;
        for (int f = 1; f <= faces.Extent(); f++) {
            isPlain[f - 1] = plain_triangle(TopoDS::Face(faces(f)), plain[f - 1].data());
            if (!isPlain[f - 1]) {
                // already meshed at least as finely (a solid through rings comes with its own): kept
                TopLoc_Location loc;
                auto own = BRep_Tool::Triangulation(TopoDS::Face(faces(f)), loc);
                if (!own.IsNull() && own->Deflection() <= linear_deflection && own->Deflection() < 1e-6)
                    continue;
                bb.Add(rest, faces(f));
                anyRest = true;
            }
        }
        if (anyRest)
            BRepMesh_IncrementalMesh(rest, linear_deflection, false, angular_deflection, true);

        // the triangles of each face come from these faces: itself, or the
        // pieces it is divided into when the mesher got it wrong
        std::vector<std::vector<TopoDS_Face>> pieces(faces.Extent());
        std::vector<int> bad;
        for (int f = 1; f <= faces.Extent(); f++) {
            pieces[f - 1] = {TopoDS::Face(faces(f))};
            if (!isPlain[f - 1] && meshed_badly(TopoDS::Face(faces(f))))
                bad.push_back(f);
        }
        // WORKAROUND (see meshed_badly): the faces meshed wrong are divided,
        // in smaller pieces at each try, and the whole solid meshed again:
        // through one context, the edges they share with their neighbours
        // are divided in those too, so that the mesh stays closed. The solid
        // itself is left as it is.
        for (int parts = 8; !bad.empty() && parts <= 128; parts *= 4) {
            Handle(ShapeBuild_ReShape) context = new ShapeBuild_ReShape;
            for (int f : bad) {
                const TopoDS_Face &face = TopoDS::Face(faces(f));
                GProp_GProps g;
                BRepGProp::SurfaceProperties(face, g, mass_accuracy);
                ShapeUpgrade_FaceDivideArea divide(face);
                divide.SetContext(context);
                divide.MaxArea() = g.Mass() / parts;
                divide.Perform();
                context->Replace(face, divide.Result());
            }
            const TopoDS_Shape divided = context->Apply(s->shape);
            BRepMesh_IncrementalMesh(divided, linear_deflection, false, angular_deflection, true);
            std::vector<int> still;
            for (int f = 1; f <= faces.Extent(); f++) {
                if (isPlain[f - 1])
                    continue;
                std::vector<TopoDS_Face> mine;
                for (TopExp_Explorer e(context->Value(faces(f)), TopAbs_FACE); e.More(); e.Next())
                    mine.push_back(TopoDS::Face(e.Current()));
                bool wrong = false;
                if (std::find(bad.begin(), bad.end(), f) != bad.end())
                    for (const TopoDS_Face &piece : mine)
                        wrong = wrong || meshed_badly(piece);
                if (wrong)
                    still.push_back(f);
                if (!mine.empty())
                    pieces[f - 1] = mine;
            }
            bad = still;
        }

        int nv = 0, nt = 0;
        for (int f = 1; f <= faces.Extent(); f++) {
            if (isPlain[f - 1]) {
                nv += 3;
                nt += 1;
                continue;
            }
            for (const TopoDS_Face &piece : pieces[f - 1]) {
                TopLoc_Location loc;
                auto tri = BRep_Tool::Triangulation(piece, loc);
                if (tri.IsNull())
                    continue;
                nv += tri->NbNodes();
                nt += tri->NbTriangles();
            }
        }

        hc_mesh *m = new hc_mesh{nv, new float[nv * 3], nt, new int[nt * 3], faces.Extent(),
                                 new int[faces.Extent() + 1]};
        int vbase = 0, ti = 0;
        for (int f = 1; f <= faces.Extent(); f++) {
            m->face_start[f - 1] = ti / 3;
            if (isPlain[f - 1]) {
                for (int i = 0; i < 3; i++) {
                    float *v = m->verts + (vbase + i) * 3;
                    v[0] = (float)plain[f - 1][i].X();
                    v[1] = (float)plain[f - 1][i].Y();
                    v[2] = (float)plain[f - 1][i].Z();
                    m->tris[ti++] = vbase + i;
                }
                vbase += 3;
                continue;
            }
            for (const TopoDS_Face &face : pieces[f - 1]) {
                TopLoc_Location loc;
                auto tri = BRep_Tool::Triangulation(face, loc);
                if (tri.IsNull())
                    continue;
                const gp_Trsf &t = loc.Transformation();
                for (int i = 1; i <= tri->NbNodes(); i++) {
                    gp_Pnt p = tri->Node(i).Transformed(t);
                    float *v = m->verts + (vbase + i - 1) * 3;
                    v[0] = (float)p.X();
                    v[1] = (float)p.Y();
                    v[2] = (float)p.Z();
                }
                bool reversed = face.Orientation() == TopAbs_REVERSED;
                for (int i = 1; i <= tri->NbTriangles(); i++) {
                    int a, b, c;
                    tri->Triangle(i).Get(a, b, c);
                    if (reversed)
                        std::swap(b, c);
                    m->tris[ti++] = vbase + a - 1;
                    m->tris[ti++] = vbase + b - 1;
                    m->tris[ti++] = vbase + c - 1;
                }
                vbase += tri->NbNodes();
            }
        }
        m->face_start[faces.Extent()] = ti / 3;
        return m;
    });
}

void hc_mesh_free(hc_mesh *m)
{
    if (!m)
        return;
    delete[] m->verts;
    delete[] m->tris;
    delete[] m->face_start;
    delete m;
}

// Whether merging the coplanar triangles of a mesh kept the solid valid.
// The faces that are still triangles, or two triangles become a quad, are
// valid by construction: only larger faces (and faces with holes) are
// checked, with the shells' closure and orientation. A full BRepCheck of a
// mesh solid costs about half of its loading.
static bool unified_valid(const TopoDS_Shape &s)
{
    for (TopExp_Explorer f(s, TopAbs_FACE); f.More(); f.Next()) {
        TopTools_IndexedMapOfShape edges, wires;
        TopExp::MapShapes(f.Current(), TopAbs_EDGE, edges);
        TopExp::MapShapes(f.Current(), TopAbs_WIRE, wires);
        if ((edges.Extent() > 4 || wires.Extent() > 1) && !BRepCheck_Analyzer(f.Current()).IsValid())
            return false;
    }
    for (TopExp_Explorer sh(s, TopAbs_SHELL); sh.More(); sh.Next()) {
        BRepCheck_Shell check(TopoDS::Shell(sh.Current()));
        if (check.Closed() != BRepCheck_NoError || check.Orientation() != BRepCheck_NoError)
            return false;
    }
    return true;
}

// Builds the shell straight from a welded mesh, sharing vertices and edges
// between triangles; null when the mesh is not a clean closed 2-manifold
// (each edge used once in each direction), so the caller falls back to sewing.
static TopoDS_Shape shell_from_mesh(const float *verts, int nverts, const int *tris, int ntris, double tolerance)
{
    BRep_Builder bb;
    std::vector<TopoDS_Vertex> vs(nverts);
    auto vertex = [&](int i) -> const TopoDS_Vertex & {
        if (vs[i].IsNull())
            bb.MakeVertex(vs[i], gp_Pnt(verts[3 * i], verts[3 * i + 1], verts[3 * i + 2]), tolerance);
        return vs[i];
    };
    // undirected edge (low, high) -> edge from low to high, and how often each direction is used
    std::map<std::pair<int, int>, std::pair<TopoDS_Edge, int>> edges;
    auto edge = [&](int a, int b) -> TopoDS_Edge {
        auto key = std::make_pair(std::min(a, b), std::max(a, b));
        auto it = edges.find(key);
        if (it == edges.end()) {
            TopoDS_Edge e = BRepBuilderAPI_MakeEdge(vertex(key.first), vertex(key.second));
            it = edges.emplace(key, std::make_pair(e, 0)).first;
        }
        it->second.second += a < b ? 1 : 16;
        return TopoDS::Edge(a < b ? it->second.first : it->second.first.Reversed());
    };

    TopoDS_Shell shell;
    bb.MakeShell(shell);
    for (int t = 0; t < ntris; t++) {
        int a = tris[3 * t], b = tris[3 * t + 1], c = tris[3 * t + 2];
        if (a == b || b == c || a == c)
            return TopoDS_Shape();
        BRepBuilderAPI_MakeWire wire;
        wire.Add(edge(a, b));
        wire.Add(edge(b, c));
        wire.Add(edge(c, a));
        if (!wire.IsDone())
            return TopoDS_Shape();
        // the plane from the triangle itself: finding it from the wire (a
        // least-squares fit) took most of the time
        gp_Pnt pa(verts[3 * a], verts[3 * a + 1], verts[3 * a + 2]);
        gp_Vec normal = gp_Vec(pa, gp_Pnt(verts[3 * b], verts[3 * b + 1], verts[3 * b + 2]))
                            .Crossed(gp_Vec(pa, gp_Pnt(verts[3 * c], verts[3 * c + 1], verts[3 * c + 2])));
        if (normal.Magnitude() < 1e-12)
            return TopoDS_Shape();
        BRepBuilderAPI_MakeFace face(gp_Pln(pa, gp_Dir(normal)), wire.Wire(), Standard_True);
        if (!face.IsDone())
            return TopoDS_Shape();
        bb.Add(shell, face.Face());
    }
    for (auto &e : edges)
        if (e.second.second != 17)
            return TopoDS_Shape();
    shell.Closed(Standard_True);
    return shell;
}

// The shell straight from a welded mesh with its flat regions as faces: the triangles that meet edge to edge in
// one plane grouped (within `tolerance`), each group a face bounded by its outline, the outline's straight runs
// one edge each where they part the same two groups (no corner of a third there), every edge shared by its two
// faces and given its line on each. What building it a triangle at a time and then merging the triangles
// (ShapeUpgrade_UnifySameDomain) gives, in a fraction of the time; null when the mesh is not a clean closed
// 2-manifold or an outline does not close into loops (then the caller does it that way).
static TopoDS_Shape grouped_shell_from_mesh(const float *verts, int nverts, const int *tris, int ntris, double tolerance)
{
    auto P = [&](int i) { return gp_Pnt(verts[3 * i], verts[3 * i + 1], verts[3 * i + 2]); };
    // (HCAD_MESH_DEBUG: where it gave up)
    auto fail = [](int where) {
        if (getenv("HCAD_MESH_DEBUG"))
            fprintf(stderr, "mesh: grouped shell given up at %d\n", where);
        return TopoDS_Shape();
    };
    // each undirected edge: its two triangles, the one using it low to high first
    std::unordered_map<uint64_t, std::array<int, 2>> uses;
    uses.reserve(3 * (size_t)ntris);
    auto key = [](int a, int b) { return ((uint64_t)std::min(a, b) << 32) | (uint32_t)std::max(a, b); };
    std::vector<gp_Vec> normal(ntris);
    for (int t = 0; t < ntris; t++) {
        const int a = tris[3 * t], b = tris[3 * t + 1], c = tris[3 * t + 2];
        if (a == b || b == c || a == c)
            return fail(1);
        gp_Vec n = gp_Vec(P(a), P(b)).Crossed(gp_Vec(P(a), P(c)));
        if (n.Magnitude() < 1e-12)
            return fail(2);
        normal[t] = n.Normalized();
        const int v[3] = {a, b, c};
        for (int k = 0; k < 3; k++) {
            const int p = v[k], q = v[(k + 1) % 3];
            auto it = uses.emplace(key(p, q), std::array<int, 2>{-1, -1}).first;
            int &slot = it->second[p < q ? 0 : 1];
            if (slot >= 0)
                return fail(3);   // used twice the same way: not a clean 2-manifold
            slot = t;
        }
    }
    for (auto &u : uses)
        if (u.second[0] < 0 || u.second[1] < 0)
            return fail(4);
    // the groups: neighbours in one plane joined
    std::vector<int> parent(ntris);
    for (int t = 0; t < ntris; t++)
        parent[t] = t;
    std::function<int(int)> find = [&](int x) {
        while (parent[x] != x) {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        return x;
    };
    auto coplanar = [&](int t, int u) {
        if (normal[t].Dot(normal[u]) < 1 - 1e-10)
            return false;
        const gp_Pnt o = P(tris[3 * t]);
        for (int k = 0; k < 3; k++)
            if (std::abs(gp_Vec(o, P(tris[3 * u + k])).Dot(normal[t])) > tolerance)
                return false;
        return true;
    };
    for (auto &u : uses)
        if (coplanar(u.second[0], u.second[1])) {
            const int x = find(u.second[0]), y = find(u.second[1]);
            if (x != y)
                parent[x] = y;
        }
    std::vector<int> group(ntris);
    for (int t = 0; t < ntris; t++)
        group[t] = find(t);
    // the groups round each vertex, to know the corners where a third group meets two
    std::vector<std::vector<int>> around(nverts);
    for (int t = 0; t < ntris; t++)
        for (int k = 0; k < 3; k++) {
            auto &g = around[tris[3 * t + k]];
            if (std::find(g.begin(), g.end(), group[t]) == g.end())
                g.push_back(group[t]);
        }
    // each group's outline: its triangles' edges that part it from another group, from vertex to vertex
    struct Directed {
        int from, to, other;
    };
    std::unordered_map<int, std::vector<Directed>> outline;
    for (int t = 0; t < ntris; t++)
        for (int k = 0; k < 3; k++) {
            const int p = tris[3 * t + k], q = tris[3 * t + (k + 1) % 3];
            const auto &u = uses[key(p, q)];
            const int across = u[0] == t ? u[1] : u[0];
            if (group[across] != group[t])
                outline[group[t]].push_back({p, q, group[across]});
        }
    // built once; the groups whose faces OpenCascade does not take (a region touching itself, a hole
    // within the tolerance of its outline: a few of thousands) found then are built again as their triangles,
    // the groups round them keeping every vertex of theirs, so that the edges they share are the triangles'
    BRep_Builder bb;
    auto build = [&](const std::vector<bool> &bad, std::vector<int> *newBad) -> TopoDS_Shape {
    std::vector<bool> nearBad(nverts, false);
    bool anyBad = false;
    for (int t = 0; t < ntris; t++)
        if (bad[group[t]]) {
            anyBad = true;
            for (int k = 0; k < 3; k++)
                nearBad[tris[3 * t + k]] = true;
        }
    std::vector<TopoDS_Vertex> vs(nverts);
    auto vertex = [&](int i) -> const TopoDS_Vertex & {
        if (vs[i].IsNull())
            bb.MakeVertex(vs[i], P(i), tolerance);
        return vs[i];
    };
    // the straight runs, one edge each, shared: by their ends (low, high)
    std::unordered_map<uint64_t, TopoDS_Edge> runs;
    TopoDS_Shell shell;
    bb.MakeShell(shell);
    // a run between the corners a and b, from the lower one through `next` (the vertex after it on the way)
    auto runEdge = [&](int a, int b, int next) -> TopoDS_Edge {
        const uint64_t k = key(std::min(a, b), next);
        auto it = runs.find(k);
        if (it == runs.end()) {
            const int lo = std::min(a, b), hi = std::max(a, b);
            it = runs.emplace(k, TopoDS_Edge(BRepBuilderAPI_MakeEdge(vertex(lo), vertex(hi)))).first;
        }
        return it->second;
    };
    // the triangles of the groups built that way, each a face
    for (int t = 0; t < ntris; t++) {
        if (!bad[group[t]])
            continue;
        const int v[3] = {tris[3 * t], tris[3 * t + 1], tris[3 * t + 2]};
        BRepBuilderAPI_MakeWire mw;
        for (int k = 0; k < 3; k++) {
            const TopoDS_Edge e = runEdge(v[k], v[(k + 1) % 3], std::max(v[k], v[(k + 1) % 3]));
            mw.Add(v[k] < v[(k + 1) % 3] ? e : TopoDS::Edge(e.Reversed()));
        }
        if (!mw.IsDone())
            return fail(11);
        BRepBuilderAPI_MakeFace f(gp_Pln(P(v[0]), gp_Dir(normal[t])), mw.Wire(), Standard_True);
        if (!f.IsDone())
            return fail(11);
        bb.Add(shell, f.Face());
    }
    for (auto &[g, edges] : outline) {
        if (bad[g])
            continue;
        // loops: from each vertex its edges out (two or more where the region touches itself at a vertex)
        std::unordered_map<int, std::vector<int>> out;
        for (size_t i = 0; i < edges.size(); i++)
            out[edges[i].from].push_back((int)i);
        // the group's plane, from its first triangle
        int t0 = -1;
        for (int t = 0; t < ntris && t0 < 0; t++)
            if (group[t] == g)
                t0 = t;
        const gp_Pln pln(P(tris[3 * t0]), gp_Dir(normal[t0]));
        Handle(Geom_Plane) plane = new Geom_Plane(pln);
        TopoDS_Face face;
        bb.MakeFace(face, plane, tolerance);
        std::vector<bool> used(edges.size(), false);
        for (size_t start = 0; start < edges.size(); start++) {
            if (used[start])
                continue;
            // the loop's vertices and, for each step, the group across it
            std::vector<int> loop, across;
            int i = (int)start;
            while (!used[i]) {
                used[i] = true;
                loop.push_back(edges[i].from);
                across.push_back(edges[i].other);
                auto next = out.find(edges[i].to);
                if (next == out.end())
                    return fail(6);
                // of several ways on, the one turning least clockwise from where it came from: the region's
                // own corner there, which keeps each loop on its side of the vertex
                int best = -1;
                double bestAngle = 1e9;
                const gp_Vec back(P(edges[i].to), P(edges[i].from));
                for (int j : next->second) {
                    if (used[j] && j != (int)start)
                        continue;
                    const gp_Vec on(P(edges[j].from), P(edges[j].to));
                    // the angle from `back` to `on`, clockwise round the plane's normal
                    double angle = -std::atan2(back.Crossed(on).Dot(normal[t0]), back.Dot(on));
                    if (angle <= 0)
                        angle += 2 * M_PI;
                    if (angle < bestAngle) {
                        bestAngle = angle;
                        best = j;
                    }
                }
                if (best < 0)
                    return fail(6);
                i = best;
            }
            if (loop.size() < 3 || i != (int)start)
                return fail(7);
            // its corners: where the group across changes, a third group meets, or the outline turns
            const size_t m = loop.size();
            std::vector<int> corners;
            for (size_t i = 0; i < m; i++) {
                const int prev = (int)((i + m - 1) % m);
                const int v = loop[i];
                const gp_Vec din(P(loop[prev]), P(v)), dout(P(v), P(loop[(i + 1) % m]));
                const bool straight = din.Crossed(dout).Magnitude() <= 1e-9 * din.Magnitude() * dout.Magnitude()
                    && din.Dot(dout) > 0;
                // (and where the region touches itself: the other loop passes there too)
                if (across[prev] != across[i] || around[v].size() != 2 || !straight || out[v].size() > 1 || nearBad[v])
                    corners.push_back((int)i);
            }
            if (corners.size() < 3)
                return fail(8);
            TopoDS_Wire wire;
            bb.MakeWire(wire);
            for (size_t c = 0; c < corners.size(); c++) {
                const int ca = corners[c], cb = corners[(c + 1) % corners.size()];
                const int a = loop[ca], b = loop[cb];
                // the run known by its lower end and the vertex next to that end along it: the face across finds
                // the same, and two runs between the same corners by different ways are two
                const int nearA = loop[(ca + 1) % m], nearB = loop[(cb + m - 1) % m];
                const TopoDS_Edge e = runEdge(a, b, a < b ? nearA : nearB);
                // its line on this face: the plane's parameters are lengths, so the line's are the edge's
                auto uv = [&](int i) {
                    double u, v;
                    ElSLib::Parameters(pln, P(i), u, v);
                    return gp_Pnt2d(u, v);
                };
                const gp_Pnt2d p0 = uv(std::min(a, b)), p1 = uv(std::max(a, b));
                if (p0.Distance(p1) < 1e-12)
                    return fail(9);
                bb.UpdateEdge(e, new Geom2d_Line(p0, gp_Dir2d(gp_Vec2d(p0, p1))), face, tolerance);
                bb.Add(wire, a < b ? e : TopoDS::Edge(e.Reversed()));
            }
            wire.Closed(Standard_True);
            bb.Add(face, wire);
        }
        // a face of several loops checked (and one whose region touches itself): not taken, its group is built
        // again as its triangles
        int nw = 0;
        for (TopoDS_Iterator w(face); w.More(); w.Next())
            nw++;
        // (any but a plain triangle or quad: as unified_valid checks them)
        int ne = 0;
        for (TopExp_Explorer e(face, TopAbs_EDGE); e.More() && ne <= 4; e.Next())
            ne++;
        // (on a pass after the first only those beside a group built as triangles: the rest are as they were)
        bool touches = !anyBad;
        for (auto &o : out)
            touches = touches || nearBad[o.first];
        if ((nw > 1 || ne > 4) && touches && !BRepCheck_Analyzer(face).IsValid()) {
            if (!newBad)
                return fail(10);
            newBad->push_back(g);
            continue;
        }
        bb.Add(shell, face);
    }
    if (newBad && !newBad->empty())
        return TopoDS_Shape();
    shell.Closed(Standard_True);
    return shell;
    };
    std::vector<bool> bad(ntris, false);
    for (int pass = 0; pass < 3; pass++) {
        std::vector<int> found;
        TopoDS_Shape shell = build(bad, &found);
        if (!shell.IsNull() || found.empty())
            return shell;
        if (getenv("HCAD_MESH_DEBUG"))
            fprintf(stderr, "mesh: %zu groups more built as their triangles\n", found.size());
        for (int g : found)
            bad[g] = true;
    }
    return fail(12);
}

hc_shape *hc_from_mesh(const float *verts, int nverts, const int *tris, int ntris, double tolerance)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        for (int t = 0; t < 3 * ntris; t++)
            if (tris[t] < 0 || tris[t] >= nverts) {
                set_error("triangle index out of range");
                return nullptr;
            }
        Laps laps;
        // the flat regions as faces at once; else a triangle at a time, merged after
        if (!getenv("HCAD_MESH_UNIFY")) {
            const TopoDS_Shape grouped = grouped_shell_from_mesh(verts, nverts, tris, ntris, tolerance);
            laps.lap("mesh: grouped shell");
            if (!grouped.IsNull()) {
                BRepBuilderAPI_MakeSolid mk(TopoDS::Shell(grouped));
                TopoDS_Shape solid = mk.Solid();
                double volume = 0;
                for (int t = 0; t < ntris; t++) {
                    const float *p = verts + 3 * tris[3 * t], *q = verts + 3 * tris[3 * t + 1], *r = verts + 3 * tris[3 * t + 2];
                    volume += (double)p[0] * ((double)q[1] * r[2] - (double)q[2] * r[1])
                            - (double)p[1] * ((double)q[0] * r[2] - (double)q[2] * r[0])
                            + (double)p[2] * ((double)q[0] * r[1] - (double)q[1] * r[0]);
                }
                if (volume < 0)
                    solid.Reverse();
                // its faces checked as they were made: the shell closed and turned one way, every edge in two faces,
                // once each way (BRepCheck_Shell takes seconds over thousands of faces)
                NCollection_DataMap<TopoDS_Shape, int, TopTools_ShapeMapHasher> uses;
                for (TopExp_Explorer f(solid, TopAbs_FACE); f.More(); f.Next())
                    for (TopExp_Explorer e(f.Current(), TopAbs_EDGE); e.More(); e.Next()) {
                        const int way = e.Current().Orientation() == TopAbs_FORWARD ? 1 : e.Current().Orientation() == TopAbs_REVERSED ? 16 : 256;
                        if (int *n = uses.ChangeSeek(e.Current()))
                            *n += way;
                        else
                            uses.Bind(e.Current(), way);
                    }
                bool ok = true;
                std::map<int, int> tally;
                for (NCollection_DataMap<TopoDS_Shape, int, TopTools_ShapeMapHasher>::Iterator it(uses); it.More(); it.Next()) {
                    ok = ok && it.Value() == 17;
                    tally[it.Value()]++;
                }
                if (getenv("HCAD_MESH_DEBUG"))
                    for (auto &[k, n] : tally)
                        fprintf(stderr, "mesh: edges used %d: %d\n", k, n);
                laps.lap("mesh: grouped checked");
                if (!ok && getenv("HCAD_MESH_DEBUG")) {
                    int bad = 0, faces = 0;
                    for (TopExp_Explorer f(solid, TopAbs_FACE); f.More(); f.Next(), faces++) {
                        BRepCheck_Analyzer an(f.Current());
                        if (!an.IsValid() && bad++ < 3) {
                            Handle(BRepCheck_Result) r = an.Result(f.Current());
                            fprintf(stderr, "mesh: face %d invalid:", faces);
                            if (!r.IsNull())
                                for (auto st : r->Status())
                                    fprintf(stderr, " %d", (int)st);
                            int wires = 0;
                            for (TopExp_Explorer w(f.Current(), TopAbs_WIRE); w.More(); w.Next())
                                wires++;
                            fprintf(stderr, " (%d wires)\n", wires);
                        }
                    }
                    for (TopExp_Explorer sh(solid, TopAbs_SHELL); sh.More(); sh.Next()) {
                        BRepCheck_Shell check(TopoDS::Shell(sh.Current()));
                        fprintf(stderr, "mesh: %d faces, %d bad; shell closed %d, oriented %d\n", faces, bad,
                                (int)check.Closed(), (int)check.Orientation());
                    }
                }
                if (ok)
                    return primitive(solid);
            }
        }
        TopoDS_Shape sewn = shell_from_mesh(verts, nverts, tris, ntris, tolerance);
        laps.lap("mesh: shell");
        const bool direct = !sewn.IsNull();
        if (!direct) {
            BRepBuilderAPI_Sewing sew(tolerance);
            auto pt = [&](int i) { return gp_Pnt(verts[3 * i], verts[3 * i + 1], verts[3 * i + 2]); };
            for (int t = 0; t < ntris; t++) {
                gp_Pnt pa = pt(tris[3 * t]), pb = pt(tris[3 * t + 1]), pc = pt(tris[3 * t + 2]);
                if (pa.Distance(pb) < tolerance || pb.Distance(pc) < tolerance || pa.Distance(pc) < tolerance)
                    continue; // degenerate
                BRepBuilderAPI_MakePolygon poly(pa, pb, pc, Standard_True);
                BRepBuilderAPI_MakeFace face(poly.Wire(), Standard_True);
                if (face.IsDone())
                    sew.Add(face.Face());
            }
            sew.Perform();
            sewn = sew.SewedShape();
        }

        // one solid per closed shell
        BRepBuilderAPI_MakeSolid mk;
        int shells = 0;
        for (TopExp_Explorer ex(sewn, TopAbs_SHELL); ex.More(); ex.Next(), shells++)
            mk.Add(TopoDS::Shell(ex.Current()));
        if (shells == 0) {
            set_error("the mesh is not a closed surface");
            return nullptr;
        }
        TopoDS_Shape solid;
        if (direct) {
            // consistently oriented already: only an inside-out mesh needs
            // turning over (the signed volume of the triangles tells)
            solid = mk.Solid();
            double volume = 0;
            for (int t = 0; t < ntris; t++) {
                const float *p = verts + 3 * tris[3 * t], *q = verts + 3 * tris[3 * t + 1], *r = verts + 3 * tris[3 * t + 2];
                volume += (double)p[0] * ((double)q[1] * r[2] - (double)q[2] * r[1])
                        - (double)p[1] * ((double)q[0] * r[2] - (double)q[2] * r[0])
                        + (double)p[2] * ((double)q[0] * r[1] - (double)q[1] * r[0]);
            }
            if (volume < 0)
                solid.Reverse();
        } else {
            ShapeFix_Solid fix(mk.Solid());
            fix.Perform();
            solid = fix.Solid();
        }

        // merge coplanar triangles into faces, so selectors see real faces; on
        // dense scanned or exported meshes this can break the solid, and then
        // the triangles are kept as they are
        laps.lap("mesh: solid");
        ShapeUpgrade_UnifySameDomain unify(solid, Standard_True, Standard_True, Standard_False);
        unify.Build();
        laps.lap("mesh: unified");
        // (a shell built directly from a clean mesh is valid by construction:
        // checking it costs seconds on large meshes)
        const bool unifiedValid = unified_valid(unify.Shape());
        laps.lap("mesh: unified checked");
        if (!unifiedValid && (direct || BRepCheck_Analyzer(solid).IsValid()))
            return primitive(solid);
        return primitive(unify.Shape());
    });
}

int hc_write_step(const hc_shape *const *shapes, const char *const *names, int n, const char *path,
                  const char *const *face_names, const char *system, const char *note)
{
    return guarded<>(-1, [&]() -> int {
        STEPControl_Writer w;
        Interface_Static::SetCVal("write.step.unit", "MM");

        // each part a product of its own: other CAD programs see separate
        // bodies, named like the parts
        for (int i = 0; i < n; i++)
            if (w.Transfer(shapes[i]->shape, STEPControl_AsIs) != IFSelect_RetDone) {
                set_error("STEP transfer failed");
                return -1;
            }
        int k = 0;
        Handle(StepData_StepModel) model = w.Model();
        for (int e = 1; e <= model->NbEntities() && k < n; e++) {
            Handle(StepBasic_Product) product = Handle(StepBasic_Product)::DownCast(model->Value(e));
            if (product.IsNull())
                continue;
            Handle(TCollection_HAsciiString) name = new TCollection_HAsciiString(names[k++]);
            product->SetId(name);
            product->SetName(name);
        }
        // the faces' names (their tags), on the faces' own entities: face_names holds, part after
        // part, one name per face of it (empty for none)
        if (face_names) {
            Handle(Transfer_FinderProcess) fp = w.WS()->TransferWriter()->FinderProcess();
            int at = 0;
            for (int i = 0; i < n; i++) {
                const auto &faces = map_of(shapes[i], TopAbs_FACE);
                for (int f = 1; f <= faces.Extent(); f++, at++) {
                    if (!face_names[at] || !*face_names[at])
                        continue;
                    Handle(TransferBRep_ShapeMapper) mapper = TransferBRep::ShapeMapper(fp, faces(f));
                    Handle(StepRepr_RepresentationItem) item =
                        Handle(StepRepr_RepresentationItem)::DownCast(fp->FindTransient(mapper));
                    if (!item.IsNull())
                        item->SetName(new TCollection_HAsciiString(face_names[at]));
                }
            }
        }
        // the program that made it, in the file's header (set last: the transfer writes its own)
        if (system && *system) {
            APIHeaderSection_MakeHeader header(Handle(StepData_StepModel)::DownCast(w.Model()));
            if (header.IsDone()) {
                header.SetName(new TCollection_HAsciiString(names[0]));
                header.SetOriginatingSystem(new TCollection_HAsciiString(system));
                header.SetPreprocessorVersion(new TCollection_HAsciiString(system));
                header.SetAuthorisation(new TCollection_HAsciiString(""));
                header.SetAuthorValue(1, new TCollection_HAsciiString(""));
                header.SetOrganizationValue(1, new TCollection_HAsciiString(""));
                if (note && *note)
                    header.SetDescriptionValue(1, new TCollection_HAsciiString(note));
            }
        }
        if (w.Write(path) != IFSelect_RetDone) {
            set_error("STEP write failed");
            return -1;
        }
        return 0;
    });
}

hc_shape *hc_read_step(const char *path)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        STEPControl_Reader r;
        if (r.ReadFile(path) != IFSelect_RetDone) {
            set_error("cannot read STEP file");
            return nullptr;
        }
        r.TransferRoots();
        const TopoDS_Shape shape = r.OneShape();
        history_new(shape);
        // the faces' names, from the faces' entities (what hc_write_step writes: their tags)
        TopTools_IndexedMapOfShape faces;
        TopExp::MapShapes(shape, TopAbs_FACE, faces);
        std::vector<std::string> names(faces.Extent());
        bool any = false;
        Handle(Transfer_TransientProcess) tp = r.WS()->TransferReader()->TransientProcess();
        Handle(Interface_InterfaceModel) model = r.Model();
        for (int e = 1; e <= model->NbEntities(); e++) {
            Handle(StepShape_Face) face = Handle(StepShape_Face)::DownCast(model->Value(e));
            if (face.IsNull() || face->Name().IsNull() || face->Name()->Length() == 0)
                continue;
            const std::string name = face->Name()->ToCString();
            if (name == "NONE")
                continue;
            const TopoDS_Shape f = TransferBRep::ShapeResult(tp, face);
            if (f.IsNull())
                continue;
            if (const int j = faces.FindIndex(f); j > 0) {
                names[j - 1] = name;
                any = true;
            }
        }
        hc_shape *h = wrap(shape);
        if (any)
            g_face_names = names;
        return h;
    });
}

int hc_face_names_size(void) { return (int)g_face_names.size(); }

const char *hc_face_name(int i) { return i >= 0 && i < (int)g_face_names.size() ? g_face_names[i].c_str() : ""; }

} // extern "C"

// ---------------------------------------------------------------- paths, sweep, loft, outlines

// Loops → planar profile faces: loops inside an odd number of others are holes.
// (defined below, where the outline's functions are, in C linkage)
extern "C" {
static bool loops_meet(const std::vector<TopoDS_Wire> &loops);
}

static TopoDS_Shape faces_from_loops(const std::vector<TopoDS_Wire> &loops)
{
    struct Loop {
        TopoDS_Face face;
        double area;
        gp_Pnt probe;
        Bnd_Box box;
    };
    std::vector<Loop> ls;
    for (auto &w : loops) {
        BRepBuilderAPI_MakeFace f(w, Standard_True);
        if (!f.IsDone())
            throw Standard_Failure("an outline loop is not planar");
        if (loops.size() == 1) { // one loop: no holes to sort out (a profile's rect, circle…)
            ShapeUpgrade_UnifySameDomain unify(upward(f.Face()), Standard_True, Standard_True, Standard_False);
            unify.Build();
            return unify.Shape();
        }
        GProp_GProps p;
        BRepGProp::SurfaceProperties(f.Face(), p);
        TopExp_Explorer v(w, TopAbs_VERTEX);
        ls.push_back({upward(f.Face()), std::abs(p.Mass()), BRep_Tool::Pnt(TopoDS::Vertex(v.Current())), Bnd_Box()});
        BRepBndLib::Add(w, ls.back().box);
    }
    std::sort(ls.begin(), ls.end(), [](const Loop &a, const Loop &b) { return a.area > b.area; });
    // a loop lies in those before it (larger) that hold its first point: none whose box is apart
    auto holds = [&](size_t j, size_t i) {
        return !ls[j].box.IsOut(ls[i].box) && BRepClass_FaceClassifier(ls[j].face, ls[i].probe, 1e-6).State() == TopAbs_IN;
    };
    if (ls.size() > 2 && !loops_meet(loops)) {
        // loops apart, nested or not: each area at an even depth less the loops right inside it, in one
        // cut each (one boolean a loop, on a face with more holes each time, took seconds for hundreds)
        std::vector<int> parent(ls.size(), -1), depth(ls.size(), 0);
        for (size_t i = 0; i < ls.size(); i++)
            for (size_t j = 0; j < i; j++)
                if (holds(j, i))
                    parent[i] = (int)j;   // later ones are smaller: the last is the nearest
        std::vector<TopoDS_Shape> regions;
        for (size_t i = 0; i < ls.size(); i++) {
            depth[i] = parent[i] < 0 ? 0 : depth[parent[i]] + 1;
            if (depth[i] % 2)
                continue;
            TopTools_ListOfShape children;
            for (size_t j = i + 1; j < ls.size(); j++)
                if (parent[j] == (int)i)
                    children.Append(ls[j].face);
            if (children.IsEmpty()) {
                regions.push_back(ls[i].face);
                continue;
            }
            TopTools_ListOfShape args;
            args.Append(ls[i].face);
            BRepAlgoAPI_Cut cut;
            cut.SetArguments(args);
            cut.SetTools(children);
            cut.Build();
            if (!cut.IsDone())
                throw Standard_Failure("cannot cut the holes out of the outline");
            regions.push_back(cut.Shape());
        }
        ShapeUpgrade_UnifySameDomain unify(compound_of(regions), Standard_True, Standard_True, Standard_False);
        unify.Build();
        return unify.Shape();
    }
    TopoDS_Shape result;
    for (size_t i = 0; i < ls.size(); i++) {
        int depth = 0;
        for (size_t j = 0; j < i; j++)
            depth += holds(j, i);
        if (result.IsNull())
            result = ls[i].face;
        else if (depth % 2 == 0)
            result = BRepAlgoAPI_Fuse(result, ls[i].face).Shape();
        else
            result = BRepAlgoAPI_Cut(result, ls[i].face).Shape();
    }
    ShapeUpgrade_UnifySameDomain unify(result, Standard_True, Standard_True, Standard_False);
    unify.Build();
    return unify.Shape();
}

static TopoDS_Wire single_wire(const TopoDS_Shape &s)
{
    TopExp_Explorer ex(s, TopAbs_WIRE);
    if (!ex.More())
        throw Standard_Failure("the path has no edges");
    TopoDS_Wire w = TopoDS::Wire(ex.Current());
    ex.Next();
    if (ex.More())
        throw Standard_Failure("the path is made of several disconnected pieces");
    return w;
}

// The outer wire and the holes of the (single) face of a profile.
struct ProfileLoops {
    TopoDS_Wire outer;
    std::vector<TopoDS_Wire> holes;
};

static ProfileLoops loops_of(const TopoDS_Shape &profile)
{
    auto faces = faces_of(profile);
    if (faces.size() != 1)
        throw Standard_Failure(faces.empty() ? "the profile is empty"
                                             : "the profile has several separate regions; sweep or loft them one at a time");
    ProfileLoops r;
    r.outer = BRepTools::OuterWire(faces[0]);
    for (TopExp_Explorer ex(faces[0], TopAbs_WIRE); ex.More(); ex.Next())
        if (!ex.Current().IsSame(r.outer))
            r.holes.push_back(TopoDS::Wire(ex.Current()));
    return r;
}

// Circles have their seam at angle 0; turn it towards the first vertex of a
// polygonal section, or the vertex matching can twist or fail.
static std::vector<TopoDS_Wire> align_seams(const std::vector<TopoDS_Wire> &sections)
{
    const TopoDS_Vertex *ref = nullptr;
    TopoDS_Vertex first;
    for (auto &w : sections) {
        TopTools_IndexedMapOfShape vs;
        TopExp::MapShapes(w, TopAbs_VERTEX, vs);
        if (vs.Extent() > 1) {
            first = TopoDS::Vertex(vs(1));
            ref = &first;
            break;
        }
    }
    if (!ref)
        return sections;
    gp_Pnt target = BRep_Tool::Pnt(*ref);
    std::vector<TopoDS_Wire> out;
    for (auto &w : sections) {
        TopTools_IndexedMapOfShape es;
        TopExp::MapShapes(w, TopAbs_EDGE, es);
        BRepAdaptor_Curve c(TopoDS::Edge(es(1)));
        if (es.Extent() != 1 || c.GetType() != GeomAbs_Circle) {
            out.push_back(w);
            continue;
        }
        gp_Circ circ = c.Circle();
        gp_Dir n = circ.Axis().Direction();
        gp_Vec toward(circ.Location(), target);
        toward -= gp_Vec(n) * toward.Dot(gp_Vec(n));
        if (toward.Magnitude() < 1e-9) {
            out.push_back(w);
            continue;
        }
        gp_Circ turned(gp_Ax2(circ.Location(), n, gp_Dir(toward)), circ.Radius());
        TopoDS_Edge e = BRepBuilderAPI_MakeEdge(turned).Edge();
        if (es(1).Orientation() == TopAbs_REVERSED)
            e.Reverse();
        out.push_back(BRepBuilderAPI_MakeWire(e).Wire());
    }
    return out;
}

// Sections start wherever an offset or a boolean left them, and turn either
// way: turn them all as the first one and start each at the vertex in the
// direction where the previous one starts, seen from its centre, or the loft
// twists through itself (the matching of vertices pairs them in order). The
// edges are only reordered, so arcs (an offset's corners) stay arcs.
static std::vector<TopoDS_Wire> align_starts(const std::vector<TopoDS_Wire> &sections)
{
    std::vector<TopoDS_Wire> out;
    bool have = false;
    gp_Vec prevStart, prevNormal;
    for (auto &w : sections) {
        std::vector<TopoDS_Edge> edges;
        std::vector<gp_Pnt> pts;   // the start of each edge, in order
        for (BRepTools_WireExplorer ex(w); ex.More(); ex.Next()) {
            edges.push_back(ex.Current());
            pts.push_back(BRep_Tool::Pnt(ex.CurrentVertex()));
        }
        const size_t n = edges.size();
        if (n < 2) {   // a circle: align_seams turns it
            out.push_back(w);
            continue;
        }
        gp_XYZ centre(0, 0, 0);
        gp_Vec normal(0, 0, 0);   // Newell's: its sign is the way the section turns
        for (size_t i = 0; i < n; i++) {
            const gp_Pnt &p = pts[i], &q = pts[(i + 1) % n];
            centre += p.XYZ();
            normal += gp_Vec((p.Y() - q.Y()) * (p.Z() + q.Z()), (p.Z() - q.Z()) * (p.X() + q.X()),
                             (p.X() - q.X()) * (p.Y() + q.Y()));
        }
        centre /= double(n);
        if (normal.Magnitude() < 1e-12) {
            out.push_back(w);
            continue;
        }
        const gp_Vec axis = normal.Normalized();
        if (have && normal.Dot(prevNormal) < 0) {
            // the other way round: the edges backwards, each reversed; the
            // start of each is now the end it had
            std::vector<TopoDS_Edge> back;
            std::vector<gp_Pnt> starts;
            for (size_t i = n; i-- > 0;) {
                back.push_back(TopoDS::Edge(edges[i].Reversed()));
                starts.push_back(pts[(i + 1) % n]);
            }
            edges = back;
            pts = starts;
            normal.Reverse();
        }
        auto across = [&](const gp_Pnt &p) {
            gp_Vec d(gp_Pnt(centre), p);
            d -= axis * d.Dot(axis);
            return d;
        };
        size_t start = 0;
        if (have) {
            double best = -2;
            for (size_t i = 0; i < n; i++) {
                gp_Vec d = across(pts[i]);
                if (d.Magnitude() < 1e-12)
                    continue;
                const double c = d.Normalized().Dot(prevStart);
                if (c > best) {
                    best = c;
                    start = i;
                }
            }
        }
        BRepBuilderAPI_MakeWire mk;
        for (size_t i = 0; i < n; i++)
            mk.Add(edges[(start + i) % n]);
        out.push_back(mk.IsDone() ? mk.Wire() : w);
        gp_Vec d = across(pts[start]);
        if (d.Magnitude() > 1e-12)
            prevStart = d.Normalized();
        prevNormal = normal;
        have = true;
    }
    return out;
}

// Sections with different numbers of edges (an offset's corners fall in
// different places at each height) cannot be paired edge to edge: then each
// becomes a polygon of the same number of points, evenly spaced along it from
// its (aligned) start.
static std::vector<TopoDS_Wire> same_edge_count(const std::vector<TopoDS_Wire> &sections)
{
    int most = 0, least = INT_MAX;
    for (auto &w : sections) {
        int n = 0;
        for (BRepTools_WireExplorer ex(w); ex.More(); ex.Next())
            n++;
        most = std::max(most, n);
        least = std::min(least, n);
    }
    if (most == least || least < 2)
        return sections;   // they pair already (or a circle is among them)
    const int points = std::clamp(2 * most, 16, 400);
    std::vector<TopoDS_Wire> out;
    for (auto &w : sections) {
        BRepAdaptor_CompCurve c(w);
        GCPnts_UniformAbscissa u(c, points + 1);   // + 1: the last point is the first again
        if (!u.IsDone() || u.NbPoints() < 3)
            return sections;
        BRepBuilderAPI_MakePolygon poly;
        for (int i = 1; i < u.NbPoints(); i++)
            poly.Add(c.Value(u.Parameter(i)));
        poly.Close();
        if (!poly.IsDone())
            return sections;
        out.push_back(poly.Wire());
    }
    return out;
}

static double diagonal(const TopoDS_Shape &s)
{
    Bnd_Box b;
    BRepBndLib::Add(s, b);
    return b.IsVoid() ? 0 : std::sqrt(b.SquareExtent());
}

static TopoDS_Shape solid_through(const std::vector<TopoDS_Wire> &given, bool ruled)
{
    std::vector<TopoDS_Wire> sections = align_seams(same_edge_count(align_starts(given)));
    // a loft stays near its sections: much larger, it twisted through itself
    // (sections that do not match), and every operation on it would crawl
    TopoDS_Compound all;
    BRep_Builder bb;
    bb.MakeCompound(all);
    for (auto &w : sections)
        bb.Add(all, w);
    const double span = diagonal(all);
    bool twisted = false, flat = false;
    // WORKAROUND (OpenCascade 7.9.3, BRepOffsetAPI_ThruSections): matching
    // the vertices of the sections first gives better results, but the
    // matching itself sometimes fails: then they are lofted as they are. No
    // case known today (no test or example reaches the second try): it
    // stays as a fallback
    for (bool check : {true, false}) {
        try {
            BRepOffsetAPI_ThruSections mk(Standard_True, ruled ? Standard_True : Standard_False);
            mk.CheckCompatibility(check ? Standard_True : Standard_False);
            for (auto &w : sections)
                mk.AddWire(w);
            mk.Build();
            if (mk.IsDone() && BRepCheck_Analyzer(mk.Shape()).IsValid()) {
                // profiles in one plane give a loft of no volume, which nothing after it can use
                if (solid_volume(mk.Shape()) < 1e-9 * span * span * span + 1e-12) {
                    flat = true;
                    continue;
                }
                if (diagonal(mk.Shape()) <= 1.5 * span + 1e-6)
                    return mk.Shape();
                twisted = true;
            }
        } catch (const Standard_Failure &) {
        }
    }
    if (flat)
        throw Standard_Failure("the profiles of the loft lie in one plane: move them apart (.move(z: 20.mm)) or "
                               "stand them up (across(X))");
    if (twisted)
        throw Standard_Failure("loft twisted through itself: its profiles do not match (different shapes, "
                               "or outlines that start in different places)");
    throw Standard_Failure("loft failed (are the profiles compatible?)");
}

extern "C" {

hc_shape *hc_polyline(const double *xyz, int n, int closed)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        BRepBuilderAPI_MakePolygon poly;
        for (int i = 0; i < n; i++)
            poly.Add(gp_Pnt(xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]));
        if (closed)
            poly.Close();
        if (!poly.IsDone()) {
            set_error("invalid path (repeated points?)");
            return nullptr;
        }
        return primitive(poly.Wire());
    });
}

hc_shape *hc_spline(const double *xyz, int n, int closed)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        Handle(TColgp_HArray1OfPnt) pts = new TColgp_HArray1OfPnt(1, n);
        for (int i = 0; i < n; i++)
            pts->SetValue(i + 1, gp_Pnt(xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]));
        GeomAPI_Interpolate interp(pts, closed ? Standard_True : Standard_False, 1e-7);
        interp.Perform();
        if (!interp.IsDone()) {
            set_error("cannot fit a spline through these points");
            return nullptr;
        }
        return primitive(BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(interp.Curve()).Edge()).Wire());
    });
}

hc_shape *hc_helix(double r, double pitch, double height, int left)
{
    return hc_helix_tapered(r, pitch, height, left, 0);
}

// The same on a cone: `taper` is the angle (radians) its side leans from
// the axis, outwards as it rises when positive; r is the radius at z = 0.
// One turn, the k-th, of the helix through (r, 0, z0) rising `lead` a turn,
// on a cylinder, or on a cone widening `slope` in radius a unit up.
static TopoDS_Edge helix_turn(double r, double z0, double lead, int k, double slope)
{
    Handle(Geom_Surface) surf;
    double vPerTurn = lead;
    if (std::abs(slope) < 1e-12)
        surf = new Geom_CylindricalSurface(gp_Ax3(gp_Pnt(0, 0, z0), gp_Dir(0, 0, 1)), r);
    else {
        const double a = std::atan(slope);
        surf = new Geom_ConicalSurface(gp_Ax3(gp_Pnt(0, 0, z0), gp_Dir(0, 0, 1)), a, r);
        vPerTurn = lead / std::cos(a);
    }
    Handle(Geom2d_Line) line = new Geom2d_Line(gp_Pnt2d(2 * M_PI * k, vPerTurn * k), gp_Dir2d(2 * M_PI, vPerTurn));
    TopoDS_Edge e = BRepBuilderAPI_MakeEdge(line, surf, 0, std::sqrt(4 * M_PI * M_PI + vPerTurn * vPerTurn)).Edge();
    BRepLib::BuildCurves3d(e, 1e-7, GeomAbs_C2, 9, 8);
    return e;
}

// A right-handed thread band, built from its boundary: `rz` the corners of
// the profile over one lead (r at z = 0, z rising, the last one followed by
// the first one a lead higher), each running along its own helix; between
// two corners' helices a ruled face, one a turn; a helicoid from the axis
// closing the bottom and the top, the profile's slice where it starts and
// ends. It runs from about two leads under z = 0 to two over `length`: cut it
// to length. A thread of several starts has its profile `starts` times in a
// lead; a tapered one, `slope` (radius per unit up), its helices on cones.
static TopoDS_Shape thread_band(const std::vector<std::pair<double, double>> &rz, double lead, double length,
                                double slope)
{
    const int n = (int)rz.size();
    if (n < 3)
        throw Standard_Failure("a thread profile needs 3 corners at least");
    const double z = -2 * lead;
    const int turns = (int)std::ceil(length / lead) + 4;
    auto radius = [&](int i, double zz) { return rz[i].first + slope * zz; };
    std::vector<std::vector<TopoDS_Edge>> e(n);
    for (int i = 0; i < n; i++) {
        const double z0 = z + rz[i].second;
        for (int k = 0; k <= turns; k++)
            e[i].push_back(helix_turn(radius(i, z0), z0, lead, k, slope));
    }
    BRepBuilderAPI_Sewing sew(1e-6);
    for (int k = 0; k < turns; k++)
        for (int i = 0; i < n; i++)
            sew.Add(i + 1 < n ? BRepFill::Face(e[i][k], e[i + 1][k]) : BRepFill::Face(e[i][k], e[0][k + 1]));
    const double z0 = z + rz[0].second;
    auto axis = [&](double from) { return BRepBuilderAPI_MakeEdge(gp_Pnt(0, 0, from), gp_Pnt(0, 0, from + lead)).Edge(); };
    sew.Add(BRepFill::Face(axis(z0), e[0][0]));
    sew.Add(BRepFill::Face(axis(z0 + lead * turns), e[0][turns]));
    for (int k : {0, turns}) {
        BRepBuilderAPI_MakePolygon poly;
        poly.Add(gp_Pnt(0, 0, z0 + lead * k));
        for (int i = 0; i < n; i++) {
            const double zz = z + rz[i].second + lead * k;
            poly.Add(gp_Pnt(radius(i, zz), 0, zz));
        }
        poly.Add(gp_Pnt(radius(0, z0 + lead * (k + 1)), 0, z0 + lead * (k + 1)));
        poly.Add(gp_Pnt(0, 0, z0 + lead * (k + 1)));
        poly.Close();
        sew.Add(BRepBuilderAPI_MakeFace(poly.Wire()).Face());
    }
    sew.Perform();
    if (sew.NbFreeEdges() > 0)
        throw Standard_Failure("the thread's faces do not close");
    BRepBuilderAPI_MakeSolid ms;
    for (TopExp_Explorer ex(sew.SewedShape(), TopAbs_SHELL); ex.More(); ex.Next())
        ms.Add(TopoDS::Shell(ex.Current()));
    ShapeFix_Solid fix(ms.Solid());
    fix.Perform();
    TopoDS_Shape band = fix.Solid();
    GProp_GProps g;
    BRepGProp::VolumeProperties(band, g, 1e-4);
    if (g.Mass() < 0)
        band.Reverse();
    return band;
}

// The band of a thread (see thread_band): `rz` holds n corners, r z each.
hc_shape *hc_thread_band(const double *rz, int n, double lead, double length, double slope)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<std::pair<double, double>> corners;
        for (int i = 0; i < n; i++)
            corners.push_back({rz[2 * i], rz[2 * i + 1]});
        return primitive(thread_band(corners, lead, length, slope));
    });
}

// A right-handed ISO metric thread (basic profile: a flat crest p/8 wide on
// the major diameter d, a flat root p/4 wide on the minor one, flanks at
// 30°) standing on z = 0, `length` tall, the ends cut flat or chamfered by
// `chamfer`: its band (see thread_band) cut to length, the one boolean
// (4-5 times quicker than sweeping the tooth and fusing it to a core, and
// exact).
hc_shape *hc_iso_thread(double d, double p, double length, double chamfer)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        const double h = 0.5413 * p, R = d / 2, r = R - h;
        TopoDS_Shape band = thread_band({{R, -p / 16}, {R, p / 16}, {r, 3 * p / 8}, {r, 5 * p / 8}}, p, length, 0);
        // the envelope: from the axis out past the crests, z 0 .. length, its ends chamfered at 45°
        const double out = R + 0.05, ch = std::max(0.0, std::min(chamfer, std::min(R / 2, length / 3)));
        BRepBuilderAPI_MakePolygon side;
        side.Add(gp_Pnt(0, 0, 0));
        side.Add(gp_Pnt(out - ch - 0.05, 0, 0));
        side.Add(gp_Pnt(out, 0, ch + 0.05));
        side.Add(gp_Pnt(out, 0, length - ch - 0.05));
        side.Add(gp_Pnt(out - ch - 0.05, 0, length));
        side.Add(gp_Pnt(0, 0, length));
        side.Close();
        TopoDS_Shape envelope = BRepPrimAPI_MakeRevol(BRepBuilderAPI_MakeFace(side.Wire()).Face(),
                                                      gp_Ax1(gp::Origin(), gp::DZ())).Shape();
        BRepAlgoAPI_Common cut(band, envelope);
        check_boolean(cut, band, envelope, HC_COMMON);
        return primitive(cut.Shape());
    });
}

hc_shape *hc_helix_tapered(double r, double pitch, double height, int left, double taper)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        // a straight line on the unrolled cylinder or cone: u is the angle, v the distance
        // along the side (the height, on a cylinder)
        Handle(Geom_Surface) surf;
        double vPerTurn = pitch;
        if (std::abs(taper) < 1e-9)
            surf = new Geom_CylindricalSurface(gp_Ax3(gp::XOY()), r);
        else {
            surf = new Geom_ConicalSurface(gp_Ax3(gp::XOY()), taper, r);
            vPerTurn = pitch / std::cos(taper);
        }
        gp_Dir2d dir(left ? -2 * M_PI : 2 * M_PI, vPerTurn);
        Handle(Geom2d_Line) line = new Geom2d_Line(gp_Pnt2d(0, 0), dir);
        double turns = height / pitch;
        double len = turns * std::sqrt(4 * M_PI * M_PI + vPerTurn * vPerTurn);
        TopoDS_Edge e = BRepBuilderAPI_MakeEdge(line, surf, 0, len).Edge();
        // WORKAROUND (OpenCascade 7.9.3, BRepLib::BuildCurves3d): with its
        // default arguments, the curve in space it builds for a long helix
        // strays from it (0.003 mm after 40 turns of an M8 thread's root,
        // 9.6 mm after 80) while the edge keeps a tolerance of 1e-5 mm, as if
        // it were exact: sweeps along it follow the wrong curve, or fail.
        // With 8 pieces per turn the curve stays within 1e-6 mm (with 4 its
        // tangent still wavered by 7e-4 over 30 turns: a sweep along it came
        // out 0.3 % thin, or failed). The
        // "known bugs" unittest in lang/tests.d builds it the default way
        // (HC_WORKAROUND_HELIX_PIECES) and fails once the curve is right;
        // then the plain BuildCurves3d(e) will do.
        if (workaround(HC_WORKAROUND_HELIX_PIECES)) {
            const int segments = std::max(30, (int)std::ceil(turns * 8));
            BRepLib::BuildCurves3d(e, 1e-6, GeomAbs_C2, 9, segments);
        } else
            BRepLib::BuildCurves3d(e);
        return primitive(BRepBuilderAPI_MakeWire(e).Wire());
    });
}

// Cubic Bézier pieces joined round on themselves (three poles each, then the
// first again) as one cubic B-spline: knots three deep where they meet, then
// taken out (the curve is smooth there to its second derivative), periodic.
static Handle(Geom_BSplineCurve) closed_bezier_curve(const std::vector<gp_Pnt> &poles)
{
    const int m = (int)poles.size(), pieces = (m - 1) / 3;
    TColgp_Array1OfPnt pp(1, m);
    for (int k = 0; k < m; k++)
        pp.SetValue(k + 1, poles[k]);
    TColStd_Array1OfReal knots(1, pieces + 1);
    TColStd_Array1OfInteger mults(1, pieces + 1);
    for (int k = 0; k <= pieces; k++) {
        knots.SetValue(k + 1, k);
        mults.SetValue(k + 1, k == 0 || k == pieces ? 4 : 3);
    }
    Handle(Geom_BSplineCurve) curve = new Geom_BSplineCurve(pp, knots, mults, 3);
    for (int k = pieces; k >= 2; k--)
        curve->RemoveKnot(k, 1, 1e-9);
    try {
        curve->SetPeriodic();
    } catch (Standard_Failure &) {
    }
    return curve;
}

// A closed path through cubic Bézier pieces in space (the poles x y z each,
// three a piece and then the first again): a closed spline as a sketch's.
hc_shape *hc_spline_poles(const double *xyz, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (n < 4 || (n - 1) % 3 != 0) {
            set_error("a closed spline has a wrong number of poles");
            return nullptr;
        }
        std::vector<gp_Pnt> poles;
        for (int i = 0; i < n; i++)
            poles.emplace_back(xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]);
        return primitive(BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(closed_bezier_curve(poles)).Edge()).Wire());
    });
}

// An area of an outline forced full or empty: the one holding (x, y).
struct OutlineFill {
    gp_Pnt at;
    bool full;
};

// The loops of an outline's records (see OutlineSeg), and its forced areas.
static void parse_outline(const double *data, int n, std::vector<TopoDS_Wire> &loops, std::vector<OutlineFill> &fills,
                          bool allowOpen = false)
{
    {
        BRepBuilderAPI_MakeWire wire;
        bool open = false;
        auto close = [&] {
            if (!open)
                return;
            if (!wire.IsDone())
                throw Standard_Failure("the outline segments do not connect");
            if (!allowOpen && !wire.Wire().Closed())
                throw Standard_Failure("an outline loop is not closed");
            loops.push_back(wire.Wire());
            wire = BRepBuilderAPI_MakeWire();
            open = false;
        };
        for (int i = 0; i < n; i++) {
            const double *d = data + 7 * i;
            gp_Pnt a(d[1], d[2], 0), b(d[3], d[4], 0);
            switch ((int)d[0]) {
            case 0: // line a → b
                wire.Add(BRepBuilderAPI_MakeEdge(a, b).Edge());
                open = true;
                break;
            case 1: // arc a → b through m
                wire.Add(BRepBuilderAPI_MakeEdge(GC_MakeArcOfCircle(a, gp_Pnt(d[5], d[6], 0), b).Value()).Edge());
                open = true;
                break;
            case 2: // end of loop
                close();
                break;
            case 6: // the area holding a full (d[3] != 0) or empty
                fills.push_back({a, d[3] != 0});
                break;
            case 3: { // a whole ellipse around a: radii d[3] along its x axis (d[5] radians from X) and d[4]
                double rx = d[3], ry = d[4], t = d[5];
                if (rx < ry) { // gp_Elips wants the major radius first: turn its axis a quarter
                    std::swap(rx, ry);
                    t += M_PI / 2;
                }
                gp_Ax2 ax(a, gp_Dir(0, 0, 1), gp_Dir(std::cos(t), std::sin(t), 0));
                if (rx - ry <= 1e-9 * rx) // as wide as tall: a circle
                    wire.Add(BRepBuilderAPI_MakeEdge(gp_Circ(ax, rx)).Edge());
                else
                    wire.Add(BRepBuilderAPI_MakeEdge(gp_Elips(ax, rx, ry)).Edge());
                open = true;
                break;
            }
            case 4: { // a smooth curve a → b: d[5] pole records follow (cubic Bézier pieces, three poles each, then b)
                const int m = (int)d[5];
                if (m < 4 || (m - 1) % 3 != 0 || i + m >= n)
                    throw Standard_Failure("a spline of the outline has a wrong number of poles");
                std::vector<gp_Pnt> poles;
                for (int k = 1; k <= m; k++) {
                    const double *q = data + 7 * (i + k);
                    poles.emplace_back(q[1], q[2], 0);
                }
                i += m;
                const int pieces = (m - 1) / 3;
                Handle(Geom_BSplineCurve) curve;
                if (poles.front().Distance(poles.back()) < Precision::Confusion()) {
                    curve = closed_bezier_curve(poles);
                } else {
                    // open: OpenCascade's own cubic through the pieces' ends, their steps as its parameters
                    // and the pieces' tangents at its two ends (a cubic through given points and end
                    // tangents is one curve: the pieces'), smooth from the start, with no approximation:
                    // fillets meeting other edges at its ends come out right
                    Handle(TColgp_HArray1OfPnt) through = new TColgp_HArray1OfPnt(1, pieces + 1);
                    Handle(TColStd_HArray1OfReal) params = new TColStd_HArray1OfReal(1, pieces + 1);
                    double t = 0;
                    for (int k = 0; k <= pieces; k++) {
                        if (k > 0)
                            t += poles[3 * k].Distance(poles[3 * (k - 1)]);
                        through->SetValue(k + 1, poles[3 * k]);
                        params->SetValue(k + 1, t);
                    }
                    GeomAPI_Interpolate interp(through, params, Standard_False, 1e-9);
                    const double h0 = poles[3].Distance(poles[0]), h1 = poles[m - 1].Distance(poles[m - 4]);
                    gp_Vec t0(poles[0], poles[1]), t1(poles[m - 2], poles[m - 1]);
                    interp.Load(t0 * (3 / h0), t1 * (3 / h1), Standard_False);
                    interp.Perform();
                    if (!interp.IsDone())
                        throw Standard_Failure("cannot make the spline of the outline");
                    curve = interp.Curve();
                }
                wire.Add(BRepBuilderAPI_MakeEdge(curve).Edge());
                open = true;
                break;
            }
            }
        }
        close();
    }
}

// A point well inside a flat face: the middle of the largest triangle of its mesh.
static gp_Pnt inside_point(const TopoDS_Face &f)
{
    Bnd_Box box;
    BRepBndLib::Add(f, box);
    const double size = std::sqrt(box.SquareExtent());
    BRepMesh_IncrementalMesh(f, std::max(1e-4, size * 0.01), Standard_False, 0.3);
    TopLoc_Location loc;
    Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(f, loc);
    if (tri.IsNull() || tri->NbTriangles() == 0)
        throw Standard_Failure("an area of the outline cannot be meshed");
    double best = -1;
    gp_Pnt at;
    for (int t = 1; t <= tri->NbTriangles(); t++) {
        int i1, i2, i3;
        tri->Triangle(t).Get(i1, i2, i3);
        const gp_Pnt a = tri->Node(i1).Transformed(loc), b = tri->Node(i2).Transformed(loc), c = tri->Node(i3).Transformed(loc);
        const double area = gp_Vec(a, b).Crossed(gp_Vec(a, c)).Magnitude();
        if (area > best) {
            best = area;
            at = gp_Pnt((a.X() + b.X() + c.X()) / 3, (a.Y() + b.Y() + c.Y()) / 3, (a.Z() + b.Z() + c.Z()) / 3);
        }
    }
    return at;
}

// The areas the loops of an outline cut the plane into, the smallest that no
// line crosses, each full or empty: full inside an odd number of loops (a loop
// in a loop is a hole, where two overlap the overlap is), unless a fill says
// otherwise (the last one in the area).
// Whether any two loops of an outline cross or touch (boxes apart are not measured).
static bool loops_meet(const std::vector<TopoDS_Wire> &loops)
{
    std::vector<Bnd_Box> boxes(loops.size());
    for (size_t i = 0; i < loops.size(); i++)
        BRepBndLib::Add(loops[i], boxes[i]);
    for (size_t i = 0; i < loops.size(); i++)
        for (size_t j = i + 1; j < loops.size(); j++) {
            if (boxes[i].IsOut(boxes[j]))
                continue;
            BRepExtrema_DistShapeShape d(loops[i], loops[j]);
            if (d.IsDone() && d.Value() < 1e-7)
                return true;
        }
    return false;
}

static std::vector<std::pair<TopoDS_Face, bool>> outline_regions(const std::vector<TopoDS_Wire> &loops,
                                                                 const std::vector<OutlineFill> &fills)
{
    if (fills.empty() && !loops_meet(loops)) {
        // apart: each loop's area less the loops right inside it, full at an odd depth
        struct Loop {
            TopoDS_Face face;
            double area;
            gp_Pnt probe;
            Bnd_Box box;
        };
        std::vector<Loop> ls;
        for (auto &w : loops) {
            BRepBuilderAPI_MakeFace f(w, Standard_True);
            if (!f.IsDone())
                throw Standard_Failure("an outline loop is not planar");
            GProp_GProps p;
            BRepGProp::SurfaceProperties(f.Face(), p);
            TopExp_Explorer v(w, TopAbs_VERTEX);
            Loop l{upward(f.Face()), std::abs(p.Mass()), BRep_Tool::Pnt(TopoDS::Vertex(v.Current())), Bnd_Box()};
            BRepBndLib::Add(w, l.box);
            ls.push_back(l);
        }
        std::sort(ls.begin(), ls.end(), [](const Loop &a, const Loop &b) { return a.area > b.area; });
        // the loop each lies in directly: the smallest holding it
        std::vector<int> parent(ls.size(), -1), depth(ls.size(), 0);
        for (size_t i = 0; i < ls.size(); i++)
            for (size_t j = 0; j < i; j++)
                if (!ls[j].box.IsOut(ls[i].box)
                    && BRepClass_FaceClassifier(ls[j].face, ls[i].probe, 1e-6).State() == TopAbs_IN)
                    parent[i] = (int)j;   // later ones are smaller: the last is the nearest
        for (size_t i = 0; i < ls.size(); i++)
            depth[i] = parent[i] < 0 ? 0 : depth[parent[i]] + 1;
        std::vector<std::pair<TopoDS_Face, bool>> r;
        for (size_t i = 0; i < ls.size(); i++) {
            TopTools_ListOfShape children;
            for (size_t j = i + 1; j < ls.size(); j++)
                if (parent[j] == (int)i)
                    children.Append(ls[j].face);
            TopoDS_Shape area = ls[i].face;
            if (!children.IsEmpty()) {
                TopTools_ListOfShape args;
                args.Append(ls[i].face);
                BRepAlgoAPI_Cut cut;
                cut.SetArguments(args);
                cut.SetTools(children);
                cut.Build();
                if (!cut.IsDone())
                    throw Standard_Failure("cannot split the outline into its areas");
                area = cut.Shape();
            }
            for (TopExp_Explorer f(area, TopAbs_FACE); f.More(); f.Next())
                r.push_back({TopoDS::Face(f.Current()), depth[i] % 2 == 0});
        }
        return r;
    }
    std::vector<TopoDS_Face> faces;
    BOPAlgo_Builder split;
    for (auto &w : loops) {
        BRepBuilderAPI_MakeFace f(w, Standard_True);
        if (!f.IsDone())
            throw Standard_Failure("an outline loop is not planar");
        faces.push_back(upward(f.Face()));
        split.AddArgument(faces.back());
    }
    TopTools_IndexedMapOfShape pieces;
    if (faces.size() == 1) // one loop: one area, nothing to split
        pieces.Add(faces[0]);
    else {
        split.Perform();
        if (split.HasErrors())
            throw Standard_Failure("cannot split the outline into its areas");
        TopExp::MapShapes(split.Shape(), TopAbs_FACE, pieces);
    }
    std::vector<std::pair<TopoDS_Face, bool>> r;
    for (int i = 1; i <= pieces.Extent(); i++) {
        const TopoDS_Face piece = TopoDS::Face(pieces(i));
        const gp_Pnt probe = inside_point(piece);
        int depth = 0;
        for (auto &f : faces)
            depth += BRepClass_FaceClassifier(f, probe, 1e-7).State() == TopAbs_IN;
        bool full = depth % 2 == 1;
        for (auto &fill : fills)
            if (BRepClass_FaceClassifier(piece, fill.at, 1e-7).State() == TopAbs_IN)
                full = fill.full;
        r.push_back({piece, full});
    }
    return r;
}

// The profile of an outline: its loops nested (faces_from_loops), or, when
// loops cross or touch or areas are forced, its full areas joined.
static TopoDS_Shape profile_from_loops(const std::vector<TopoDS_Wire> &loops, const std::vector<OutlineFill> &fills)
{
    if (fills.empty() && !loops_meet(loops))
        return faces_from_loops(loops);
    std::vector<TopoDS_Shape> full;
    for (auto &r : outline_regions(loops, fills))
        if (r.second)
            full.push_back(r.first);
    if (full.empty())
        throw Standard_Failure("every area of the outline is left empty");
    TopoDS_Shape joined = fused(full);
    ShapeUpgrade_UnifySameDomain unify(joined, Standard_True, Standard_True, Standard_False);
    unify.Build();
    return unify.Shape();
}

hc_shape *hc_outline(const double *data, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<TopoDS_Wire> loops;
        std::vector<OutlineFill> fills;
        parse_outline(data, n, loops, fills);
        if (loops.empty()) {
            set_error("the outline is empty");
            return nullptr;
        }
        return primitive(profile_from_loops(loops, fills));
    });
}

// One chain of outline records (open or closed, see hc_outline) as a path on XY.
hc_shape *hc_outline_path(const double *data, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<TopoDS_Wire> loops;
        std::vector<OutlineFill> fills;
        parse_outline(data, n, loops, fills, true);
        if (loops.size() != 1) {
            set_error("a path is one chain of lines and curves");
            return nullptr;
        }
        return primitive(loops[0]);
    });
}

// A path in space from records of 10 doubles: kind (0 line a → b, 1 arc a →
// b through m), a, b, m; each starting where the one before ends.
hc_shape *hc_wire3(const double *data, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        BRepBuilderAPI_MakeWire wire;
        for (int i = 0; i < n; i++) {
            const double *d = data + 10 * i;
            gp_Pnt a(d[1], d[2], d[3]), b(d[4], d[5], d[6]), m(d[7], d[8], d[9]);
            if (d[0] == 0)
                wire.Add(BRepBuilderAPI_MakeEdge(a, b).Edge());
            else
                wire.Add(BRepBuilderAPI_MakeEdge(GC_MakeArcOfCircle(a, m, b).Value()).Edge());
            if (!wire.IsDone()) {
                set_error("the pieces of the path do not join");
                return nullptr;
            }
        }
        return primitive(wire.Wire());
    });
}

// Joins the edges into wires, in order end to end.
static std::vector<TopoDS_Wire> joined_wires(const std::vector<TopoDS_Edge> &edges, double tolerance)
{
    Handle(TopTools_HSequenceOfShape) in = new TopTools_HSequenceOfShape, out;
    for (const auto &e : edges)
        in->Append(e);
    ShapeAnalysis_FreeBounds::ConnectEdgesToWires(in, tolerance, Standard_False, out);
    std::vector<TopoDS_Wire> r;
    for (int i = 1; i <= out->Length(); i++)
        r.push_back(TopoDS::Wire(out->Value(i)));
    return r;
}

// The edges `idx` of a shape (indices as hc_edge_info's) joined into one path.
hc_shape *hc_edges_path(const hc_shape *s, const int *idx, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        const auto &em = map_of(s, TopAbs_EDGE);
        std::vector<TopoDS_Edge> edges;
        for (int i = 0; i < n; i++) {
            if (idx[i] < 0 || idx[i] >= em.Extent()) {
                set_error("edge index out of range");
                return nullptr;
            }
            edges.push_back(TopoDS::Edge(em(idx[i] + 1)));
        }
        auto wires = joined_wires(edges, 1e-6);
        if (wires.size() != 1) {
            set_error(("the edges make " + std::to_string(wires.size()) +
                       " separate pieces: a path is one chain, end to end").c_str());
            return nullptr;
        }
        return primitive(wires[0]);
    });
}

// A smooth face closing a boundary (BRepOffsetAPI_MakeFilling, a "plate"):
// the edges of `path` (a closed path), or the edges `idx` of solid `s`; it
// passes through the n points `xyz` too. With `s`, the edges that lie on one
// of its faces `tangent` (indices) meet that face smoothly (G1), the others
// only touch it (G0).
hc_shape *hc_fill(const hc_shape *path, const hc_shape *s, const int *idx, int n, const int *tangent, int nt,
                  const double *xyz, int np)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        BRepOffsetAPI_MakeFilling fill;
        // WORKAROUND (OpenCascade 7.9.3, BRepOffsetAPI_MakeFilling): along curved edges the plate
        // strays far from its boundary (a saddle rim 4 mm deep filled by a bowl 8 mm deep, whatever
        // its degree, points and iterations), and follows straight ones exactly: the edges that
        // need no tangency are added as chords, short enough to stay within 0.05 mm of the curve.
        // The "known bugs" unittest in lang/tests.d turns this off (HC_WORKAROUND_FILL_CHORDS)
        auto addPieces = [&](const TopoDS_Edge &e) {
            BRepAdaptor_Curve c(e);
            if (!workaround(HC_WORKAROUND_FILL_CHORDS) || c.GetType() == GeomAbs_Line) {
                fill.Add(e, GeomAbs_C0);
                return;
            }
            // 0.05 mm: well within what prints; finer, the plate takes far longer (0.005 mm: 15 times)
            GCPnts_QuasiUniformDeflection pts(c, 0.05);
            if (!pts.IsDone() || pts.NbPoints() < 2) {
                fill.Add(e, GeomAbs_C0);
                return;
            }
            for (int k = 1; k < pts.NbPoints(); k++)
                if (pts.Value(k).Distance(pts.Value(k + 1)) > 1e-7)
                    fill.Add(BRepBuilderAPI_MakeEdge(pts.Value(k), pts.Value(k + 1)).Edge(), GeomAbs_C0);
        };
        std::vector<TopoDS_Edge> edges;
        if (path != nullptr) {
            const TopoDS_Wire w = single_wire(path->shape);
            if (!BRep_Tool::IsClosed(w))
                throw Standard_Failure("fill closes a loop: the path must end where it starts (closed: true)");
            for (TopExp_Explorer ex(w, TopAbs_EDGE); ex.More(); ex.Next())
                addPieces(TopoDS::Edge(ex.Current()));
        } else {
            const auto &em = map_of(s, TopAbs_EDGE);
            const auto &fm = map_of(s, TopAbs_FACE);
            TopTools_IndexedDataMapOfShapeListOfShape owners;
            TopExp::MapShapesAndAncestors(s->shape, TopAbs_EDGE, TopAbs_FACE, owners);
            for (int i = 0; i < n; i++) {
                if (idx[i] < 0 || idx[i] >= em.Extent())
                    throw Standard_Failure("edge index out of range");
                edges.push_back(TopoDS::Edge(em(idx[i] + 1)));
            }
            auto wires = joined_wires(edges, 1e-6);
            if (wires.size() != 1 || !BRep_Tool::IsClosed(wires[0]))
                throw Standard_Failure(wires.size() > 1
                    ? ("the edges make " + std::to_string(wires.size()) + " separate loops (an island in the opening?): "
                       "fill closes one; select the edges of that one").c_str()
                    : "the edges do not make a closed loop: fill closes a loop (edges.loop(face) gives a face's rim)");
            for (const TopoDS_Edge &e : edges) {
                TopoDS_Face along;
                if (owners.Contains(e))
                    for (const TopoDS_Shape &f : owners.FindFromKey(e))
                        for (int k = 0; k < nt; k++)
                            if (tangent[k] >= 0 && tangent[k] < fm.Extent() && f.IsSame(fm(tangent[k] + 1)))
                                along = TopoDS::Face(f);
                if (along.IsNull())
                    addPieces(e);
                else
                    fill.Add(e, along, GeomAbs_G1);
            }
        }
        for (int i = 0; i < np; i++)
            fill.Add(gp_Pnt(xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]));
        fill.Build();
        if (!fill.IsDone())
            throw Standard_Failure("the boundary could not be filled (is it one loop, not folded on itself?)");
        TopoDS_Shape r = fill.Shape();
        if (r.IsNull() || !TopExp_Explorer(r, TopAbs_FACE).More())
            throw Standard_Failure("the boundary could not be filled");
        return primitive(r);
    });
}

// PERFORMANCE TEST (not used by the language): a thread band cut to z = 0 ..
// length without a boolean. Each ruled face of the band rises linearly in its
// parameters (two helices of one lead, a straight ruling between them), so
// the planes z = 0 and z = length are straight lines across its rectangle of
// parameters: the rectangle is clipped as a polygon, the faces inside kept as
// they are, the ones across rebuilt from the clipped polygon, the two caps
// made from the new edges, all sewn.
static std::vector<std::array<double, 2>> clip_poly(const std::vector<std::array<double, 2>> &poly,
                                                    double a, double b, double c, double keepAbove)
{
    // keeps a + b u + c v >= keepAbove
    std::vector<std::array<double, 2>> out;
    const size_t m = poly.size();
    for (size_t i = 0; i < m; i++) {
        const auto &P = poly[i], &Q = poly[(i + 1) % m];
        const double fp = a + b * P[0] + c * P[1] - keepAbove, fq = a + b * Q[0] + c * Q[1] - keepAbove;
        if (fp >= 0)
            out.push_back(P);
        if ((fp >= 0) != (fq >= 0)) {
            const double t = fp / (fp - fq);
            out.push_back({P[0] + t * (Q[0] - P[0]), P[1] + t * (Q[1] - P[1])});
        }
    }
    return out;
}

hc_shape *hc_thread_direct(const double *rzIn, int n, double lead, double length, double chamfer, double rOut)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<std::pair<double, double>> rz;
        for (int i = 0; i < n; i++)
            rz.push_back({rzIn[2 * i], rzIn[2 * i + 1]});
        const double z = -2 * lead;
        const int turns = (int)std::ceil(length / lead) + 4;
        std::vector<std::vector<TopoDS_Edge>> e(n);
        for (int i = 0; i < n; i++)
            for (int k = 0; k <= turns; k++)
                e[i].push_back(helix_turn(rz[i].first, z + rz[i].second, lead, k, 0));
        // the chamfer: a 45° cone, rOut at z = length - chamfer, rOut - chamfer at the top; what lies
        // beyond it (r + z > K) is cut away
        const bool bevel = chamfer > 0;
        const double K = rOut + length - chamfer, rTop = rOut - chamfer;
        BRepBuilderAPI_Sewing sew(1e-5);
        std::vector<TopoDS_Edge> bottom, top, cone;
        const double eps = 1e-9, tol = 1e-7;
        for (int k = 0; k < turns; k++)
            for (int i = 0; i < n; i++) {
                const TopoDS_Edge &e1 = e[i][k], &e2 = i + 1 < n ? e[i + 1][k] : e[0][k + 1];
                double f1, l1, f2, l2;
                Handle(Geom_Curve) c1 = BRep_Tool::Curve(e1, f1, l1), c2 = BRep_Tool::Curve(e2, f2, l2);
                const double zlo = std::min(c1->Value(f1).Z(), c2->Value(f2).Z()),
                             zhi = std::max(c1->Value(l1).Z(), c2->Value(l2).Z());
                if (zhi <= 0 || zlo >= length)
                    continue;   // wholly outside
                const double rmax = std::max(rz[i].first, rz[(i + 1) % n].first);
                TopoDS_Face face = BRepFill::Face(e1, e2);
                if (zlo >= 0 && zhi <= length && (!bevel || rmax + zhi <= K)) {
                    sew.Add(face);   // wholly inside: as it is
                    continue;
                }
                Handle(Geom_Surface) S = BRep_Tool::Surface(face);
                double u0, u1, v0, v1;
                BRepTools::UVBounds(face, u0, u1, v0, v1);
                // z and r + z, both affine in u and v (two helices of one lead, a radial ruling)
                auto fit = [&](auto f, double &a, double &b, double &c) {
                    const double f00 = f(S->Value(u0, v0)), f10 = f(S->Value(u1, v0)), f01 = f(S->Value(u0, v1));
                    b = (f10 - f00) / (u1 - u0);
                    c = (f01 - f00) / (v1 - v0);
                    a = f00 - b * u0 - c * v0;
                };
                double za, zb, zc, ga, gb, gc;
                fit([](const gp_Pnt &q) { return q.Z(); }, za, zb, zc);
                fit([](const gp_Pnt &q) { return std::hypot(q.X(), q.Y()) + q.Z(); }, ga, gb, gc);
                std::vector<std::array<double, 2>> poly = {{u0, v0}, {u1, v0}, {u1, v1}, {u0, v1}};
                poly = clip_poly(poly, za, zb, zc, 0);
                poly = clip_poly(poly, -za, -zb, -zc, -length);
                if (bevel)
                    poly = clip_poly(poly, -ga, -gb, -gc, -K);
                if (poly.size() < 3)
                    continue;
                BRepBuilderAPI_MakeWire wire;
                for (size_t q = 0; q < poly.size(); q++) {
                    const auto &P = poly[q], &Q = poly[(q + 1) % poly.size()];
                    const gp_Pnt2d p2(P[0], P[1]), q2(Q[0], Q[1]);
                    if (p2.Distance(q2) < eps)
                        continue;
                    Handle(Geom2d_Line) l = new Geom2d_Line(p2, gp_Dir2d(Q[0] - P[0], Q[1] - P[1]));
                    TopoDS_Edge ed = BRepBuilderAPI_MakeEdge(l, S, 0, p2.Distance(q2)).Edge();
                    BRepLib::BuildCurves3d(ed, 1e-7);
                    wire.Add(ed);
                    // an edge on a cut: for that cap
                    auto zf = [&](const std::array<double, 2> &X) { return za + zb * X[0] + zc * X[1]; };
                    auto gf = [&](const std::array<double, 2> &X) { return ga + gb * X[0] + gc * X[1]; };
                    if (std::abs(zf(P)) < tol && std::abs(zf(Q)) < tol)
                        bottom.push_back(ed);
                    else if (std::abs(zf(P) - length) < tol && std::abs(zf(Q) - length) < tol)
                        top.push_back(ed);
                    else if (bevel && std::abs(gf(P) - K) < tol && std::abs(gf(Q) - K) < tol)
                        cone.push_back(ed);
                }
                BRepBuilderAPI_MakeFace mf(S, wire.Wire());
                if (!mf.IsDone())
                    throw Standard_Failure("a clipped face could not be made");
                ShapeFix_Face fix(mf.Face());
                fix.Perform();
                sew.Add(fix.Face());
            }
        // the bottom cap: the profile's loop at z = 0
        auto planeFace = [&](const std::vector<TopoDS_Edge> &edges) {
            auto wires = joined_wires(edges, 1e-5);
            if (wires.size() != 1)
                throw Standard_Failure(("a cap's edges make " + std::to_string(wires.size()) + " loops").c_str());
            BRepBuilderAPI_MakeFace mf(wires[0], Standard_True);
            if (!mf.IsDone())
                throw Standard_Failure("a cap could not be made");
            return mf.Face();
        };
        sew.Add(planeFace(bottom));
        if (!bevel || cone.empty())
            sew.Add(planeFace(top));
        else {
            // each run of the cone's edges goes from the top circle back to it, round a tooth's
            // crest the cone cut: closed by the circle's arc between its ends, a patch of the
            // cone; the same arcs close the top cap between the profile's runs
            Handle(Geom_ConicalSurface) coneSurf =
                new Geom_ConicalSurface(gp_Ax3(gp_Pnt(0, 0, length - chamfer), gp_Dir(0, 0, 1)), -M_PI / 4, rOut);
            std::vector<TopoDS_Edge> topLoop = top;
            for (const TopoDS_Wire &run : joined_wires(cone, 1e-5)) {
                TopoDS_Vertex va, vb;
                TopExp::Vertices(run, va, vb);
                const gp_Pnt pa = BRep_Tool::Pnt(va), pb = BRep_Tool::Pnt(vb);
                // the arc sweeps the same angle as the run does, from end to end: the run's points
                // sampled, their angles unwrapped and added up
                BRepAdaptor_CompCurve cc(run);
                double sweep = 0, prev = std::atan2(pa.Y(), pa.X());
                const gp_Pnt first = cc.Value(cc.FirstParameter());
                const bool fromA = first.Distance(pa) < first.Distance(pb);
                for (int q = 1; q <= 200; q++) {
                    const double t = cc.FirstParameter() + (cc.LastParameter() - cc.FirstParameter()) * q / 200;
                    const gp_Pnt pt = cc.Value(fromA ? t : cc.LastParameter() + cc.FirstParameter() - t);
                    const double ang = std::atan2(pt.Y(), pt.X());
                    double dAng = ang - prev;
                    while (dAng > M_PI) dAng -= 2 * M_PI;
                    while (dAng < -M_PI) dAng += 2 * M_PI;
                    sweep += dAng;
                    prev = ang;
                }
                const double mid = std::atan2(pa.Y(), pa.X()) + sweep / 2;
                const gp_Pnt arcMid(rTop * std::cos(mid), rTop * std::sin(mid), length);
                TopoDS_Edge arc = BRepBuilderAPI_MakeEdge(GC_MakeArcOfCircle(pa, arcMid, pb).Value()).Edge();
                topLoop.push_back(arc);
                BRepBuilderAPI_MakeWire w;
                w.Add(run);
                w.Add(arc);
                BRepBuilderAPI_MakeFace mf(coneSurf, w.Wire());
                if (!mf.IsDone())
                    throw Standard_Failure("a patch of the chamfer could not be made");
                ShapeFix_Face fix(mf.Face());
                fix.Perform();
                sew.Add(fix.Face());
            }
            sew.Add(planeFace(topLoop));
        }
        sew.Perform();
        if (sew.NbFreeEdges() > 0)
            throw Standard_Failure(("the direct thread's faces do not close: " + std::to_string(sew.NbFreeEdges()) + " edges open").c_str());
        BRepBuilderAPI_MakeSolid ms;
        for (TopExp_Explorer ex(sew.SewedShape(), TopAbs_SHELL); ex.More(); ex.Next())
            ms.Add(TopoDS::Shell(ex.Current()));
        TopoDS_Shape r = ms.Solid();
        GProp_GProps g;
        BRepGProp::VolumeProperties(r, g);
        if (g.Mass() < 0)
            r.Reverse();
        return primitive(r);
    });
}

// PERFORMANCE TEST: two solids that touch only where a flat face of `b` lies
// on a flat face of `a` (a thread standing on a shoulder, a boss on a plate)
// joined. glue: OpenCascade's fuse told so (BOPAlgo_GlueShift); else by
// hand: `a`'s face given a hole the shape of `b`'s, `b`'s face left out, the
// rest sewn. -1 when no such pair of faces is found.
// A sleeve threaded inside: outside a prism of `sides` flat faces round the axis, its corners `rPoly`
// from it; inside the room a screw takes (the thread hc_thread_direct builds, the same corners `rz`,
// cut to z = 0 .. length), with no boolean: the screw's faces turned inside out, the prism's sides,
// and its two ends, each a polygon holed by the screw's end. Its flat outside joins a part by hand.
hc_shape *hc_thread_sleeve(const double *rz, int n, double lead, double length, int sides, double rPoly)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (sides < 3)
            throw Standard_Failure("a sleeve needs 3 sides at least");
        hc_shape *screw = hc_thread_direct(rz, n, lead, length, 0, rPoly);
        if (!screw)
            throw Standard_Failure(g_error.c_str());
        const TopoDS_Shape room = screw->shape;
        delete screw;
        BRepBuilderAPI_Sewing sew(1e-5);
        std::vector<gp_Pnt> ring0, ring1;
        for (int i = 0; i < sides; i++) {
            const double a = 2 * M_PI * i / sides;
            ring0.push_back(gp_Pnt(rPoly * std::cos(a), rPoly * std::sin(a), 0));
            ring1.push_back(gp_Pnt(rPoly * std::cos(a), rPoly * std::sin(a), length));
        }
        // the screw's faces: its ends become the holes of the sleeve's ends, the rest its inside
        for (const TopoDS_Face &f : faces_of(room)) {
            BRepAdaptor_Surface sf(f);
            const bool flat = sf.GetType() == GeomAbs_Plane && std::abs(std::abs(sf.Plane().Axis().Direction().Z()) - 1) < 1e-9;
            if (!flat) {
                sew.Add(f.Reversed());
                continue;
            }
            const double zf = sf.Plane().Location().Z();
            BRepBuilderAPI_MakePolygon poly;
            for (auto &q : (zf > length / 2 ? ring1 : ring0))
                poly.Add(q);
            poly.Close();
            BRepBuilderAPI_MakeFace mf(gp_Pln(gp_Pnt(0, 0, zf), gp_Dir(0, 0, 1)), poly.Wire());
            // the screw's end, as its face has it, runs counter-clockwise round the face's outward
            // normal: a hole in a face looking up (+Z) runs the other way, so the end looking up is
            // reversed and the one looking down is not
            const bool up = sf.Plane().Axis().Direction().Z() * (f.Orientation() == TopAbs_REVERSED ? -1 : 1) > 0;
            const TopoDS_Wire end = BRepTools::OuterWire(f);
            mf.Add(up ? TopoDS::Wire(end.Reversed()) : end);
            ShapeFix_Face fix(mf.Face());
            fix.FixOrientationMode() = 1;
            fix.Perform();
            sew.Add(fix.Face());
        }
        for (int i = 0; i < sides; i++) {
            const int j = (i + 1) % sides;
            BRepBuilderAPI_MakePolygon q(ring0[i], ring0[j], ring1[j], ring1[i], Standard_True);
            sew.Add(BRepBuilderAPI_MakeFace(q.Wire(), Standard_True).Face());
        }
        sew.Perform();
        TopoDS_Shell shell;
        int shells = 0;
        for (TopExp_Explorer sh(sew.SewedShape(), TopAbs_SHELL); sh.More(); sh.Next(), shells++)
            shell = TopoDS::Shell(sh.Current());
        if (shells != 1)
            throw Standard_Failure("the sleeve's faces did not sew into one shell");
        ShapeFix_Shell orient(shell);
        orient.FixFaceOrientation(shell);
        shell = orient.Shell();
        TopoDS_Solid solid = BRepBuilderAPI_MakeSolid(shell).Solid();
        BRepLib::OrientClosedSolid(solid);
        if (solid_volume(solid) <= 0)
            throw Standard_Failure("the sleeve came out empty");
        return primitive(solid);
    });
}

// `a` and `b` joined by hand where they touch over whole flat faces lying on each other (a sleeve in a
// hole of its shape): those faces of both left out, a face of b lying within one of a's taken out of it
// (a short sleeve's end on its pocket's floor), the rest sewn into one solid. An error where they do not
// so touch, or the result is not sound.
hc_shape *hc_join_coincident(const hc_shape *a, const hc_shape *b)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        auto fa = faces_of(a->shape), fb = faces_of(b->shape);
        struct Info {
            bool flat;
            gp_Pnt c;
            double area;
            gp_Dir n;
        };
        // only the flat faces measured: a helical one costs a hundred times as much and is never a match
        auto info = [](const TopoDS_Face &f) {
            Info r{false, gp_Pnt(), 0, gp_Dir(0, 0, 1)};
            BRepAdaptor_Surface sf(f);
            if (sf.GetType() != GeomAbs_Plane)
                return r;
            GProp_GProps g;
            BRepGProp::SurfaceProperties(f, g);
            r.flat = true;
            r.area = g.Mass();
            r.c = g.CentreOfMass();
            r.n = sf.Plane().Axis().Direction();
            return r;
        };
        std::vector<Info> ia, ib;
        for (auto &f : fa)
            ia.push_back(info(f));
        for (auto &f : fb)
            ib.push_back(info(f));
        std::vector<bool> dropA(fa.size(), false), dropB(fb.size(), false);
        int pairs = 0;
        for (size_t i = 0; i < fa.size(); i++) {
            if (!ia[i].flat)
                continue;
            for (size_t j = 0; j < fb.size(); j++)
                if (!dropB[j] && ib[j].flat && std::abs(ia[i].area - ib[j].area) < 1e-6 * (1 + ia[i].area)
                    && ia[i].c.Distance(ib[j].c) < 1e-6 && std::abs(std::abs(ia[i].n.Dot(ib[j].n)) - 1) < 1e-9) {
                    dropA[i] = dropB[j] = true;
                    pairs++;
                    break;
                }
        }
        // a flat face of b lying within a's faces in its plane (a short sleeve's end on the floor of its
        // pocket, the round hole going on below; a blind hole's floor, which the pocket left in two): those
        // faces of a, one, less b's, b's left out
        std::vector<std::vector<TopoDS_Shape>> replaced(fa.size());
        for (size_t j = 0; j < fb.size(); j++) {
            if (dropB[j] || !ib[j].flat)
                continue;
            // points along b's edges, and the middle of its parameters if inside it
            std::vector<gp_Pnt> pts;
            for (TopExp_Explorer e(fb[j], TopAbs_EDGE); e.More(); e.Next()) {
                BRepAdaptor_Curve cv(TopoDS::Edge(e.Current()));
                for (int k = 0; k < 4; k++)
                    pts.push_back(cv.Value(cv.FirstParameter() + (cv.LastParameter() - cv.FirstParameter()) * (k + 0.5) / 4));
            }
            // a's faces in its plane that it lies over in part
            std::vector<size_t> under;
            for (size_t i = 0; i < fa.size(); i++) {
                if (dropA[i] || !ia[i].flat || std::abs(std::abs(ib[j].n.Dot(ia[i].n)) - 1) > 1e-9)
                    continue;
                const gp_Pln pa = BRepAdaptor_Surface(fa[i]).Plane();
                if (pa.Distance(ib[j].c) > 1e-6)
                    continue;
                BRepClass_FaceClassifier cls;
                bool over = false;
                for (auto &q : pts) {
                    cls.Perform(fa[i], q, 1e-6);
                    if (cls.State() == TopAbs_IN) {
                        over = true;
                        break;
                    }
                }
                if (over)
                    under.push_back(i);
            }
            if (under.empty())
                continue;
            // those faces as one
            TopoDS_Face target = fa[under[0]];
            if (under.size() > 1) {
                std::vector<TopoDS_Shape> parts;
                for (auto i : under)
                    parts.push_back(fa[i]);
                ShapeUpgrade_UnifySameDomain one(compound_of(parts), Standard_True, Standard_True, Standard_False);
                one.Build();
                std::vector<TopoDS_Face> merged = faces_of(one.Shape());
                if (merged.size() != 1)
                    continue;
                target = merged[0];
            }
            // b wholly within them
            bool within = true;
            BRepClass_FaceClassifier cls;
            for (auto &q : pts) {
                cls.Perform(target, q, 1e-6);
                if (cls.State() == TopAbs_OUT) {
                    within = false;
                    break;
                }
            }
            if (!within)
                continue;
            std::vector<TopoDS_Shape> rest;
            // the two outlines the same (a sleeve's end and the floor of its pocket): what is left is made of
            // b's own edges, those round its holes the outlines, and the holes of a's face within them holes
            // again; the edges b shares with its other faces so stay shared
            const gp_Pln pa = BRepAdaptor_Surface(target).Plane();
            const TopoDS_Wire outA = BRepTools::OuterWire(target), outB = BRepTools::OuterWire(fb[j]);
            GProp_GProps la, lb;
            BRepGProp::LinearProperties(outA, la);
            BRepGProp::LinearProperties(outB, lb);
            if (std::abs(la.Mass() - lb.Mass()) < 1e-6 * (1 + la.Mass()) && la.CentreOfMass().Distance(lb.CentreOfMass()) < 1e-6) {
                for (TopExp_Explorer w(fb[j], TopAbs_WIRE); w.More(); w.Next()) {
                    const TopoDS_Wire wb = TopoDS::Wire(w.Current());
                    if (wb.IsSame(outB))
                        continue;
                    BRepBuilderAPI_MakeFace mf(pa, wb, Standard_True);
                    if (!mf.IsDone())
                        break;
                    ShapeFix_Face around(mf.Face());
                    around.FixOrientation();
                    around.Perform();
                    const TopoDS_Face island = around.Face();
                    BRepClass_FaceClassifier inIsland;
                    for (TopExp_Explorer wa(target, TopAbs_WIRE); wa.More(); wa.Next()) {
                        if (wa.Current().IsSame(outA))
                            continue;
                        TopExp_Explorer v(wa.Current(), TopAbs_VERTEX);
                        if (!v.More())
                            continue;
                        inIsland.Perform(island, BRep_Tool::Pnt(TopoDS::Vertex(v.Current())), 1e-6);
                        if (inIsland.State() == TopAbs_IN)
                            mf.Add(TopoDS::Wire(wa.Current()));
                    }
                    ShapeFix_Face fixed(mf.Face());
                    fixed.FixOrientation();
                    fixed.Perform();
                    rest.push_back(fixed.Face());
                }
            }
            if (rest.empty()) {
                BRepAlgoAPI_Cut cut(target, fb[j]);
                if (!cut.IsDone())
                    continue;
                for (TopExp_Explorer f(cut.Shape(), TopAbs_FACE); f.More(); f.Next())
                    rest.push_back(f.Current());
            }
            for (auto i : under)
                dropA[i] = true;
            replaced[under[0]] = rest;
            dropB[j] = true;
        }
        BRepBuilderAPI_Sewing sew(1e-5);
        for (size_t i = 0; i < fa.size(); i++) {
            if (!dropA[i])
                sew.Add(fa[i]);
            for (auto &r : replaced[i])
                sew.Add(r);
        }
        for (size_t j = 0; j < fb.size(); j++)
            if (!dropB[j])
                sew.Add(fb[j]);
        sew.Perform();
        TopoDS_Shell shell;
        int shells = 0;
        for (TopExp_Explorer sh(sew.SewedShape(), TopAbs_SHELL); sh.More(); sh.Next(), shells++)
            shell = TopoDS::Shell(sh.Current());
        if (shells != 1)
            throw Standard_Failure("the faces left did not sew into one shell");
        ShapeFix_Shell orient(shell);
        orient.FixFaceOrientation(shell);
        shell = orient.Shell();
        TopoDS_Solid solid = BRepBuilderAPI_MakeSolid(shell).Solid();
        BRepLib::OrientClosedSolid(solid);
        // closed: every edge between two faces
        TopTools_IndexedDataMapOfShapeListOfShape ef;
        TopExp::MapShapesAndAncestors(solid, TopAbs_EDGE, TopAbs_FACE, ef);
        for (int i = 1; i <= ef.Extent(); i++)
            if (!BRep_Tool::Degenerated(TopoDS::Edge(ef.FindKey(i))) && ef(i).Extent() != 2)
                throw Standard_Failure("the joined solid is not closed");
        // where each face came from: a's faces (those replaced, the face they replace), then b's
        history_new(solid);
        {
            TopTools_IndexedMapOfShape res;
            TopExp::MapShapes(solid, TopAbs_FACE, res);
            auto record = [&](const TopoDS_Shape &f, Origin o) {
                const TopoDS_Shape g = sew.IsModified(f) ? sew.Modified(f) : f;
                for (TopExp_Explorer e(g, TopAbs_FACE); e.More(); e.Next())
                    if (const int j = res.FindIndex(e.Current()); j > 0)
                        history_from(j, o);
            };
            for (size_t i = 0; i < fa.size(); i++) {
                if (!dropA[i])
                    record(fa[i], Origin{0, (int)i});
                for (auto &r : replaced[i])
                    record(r, Origin{0, (int)i});
            }
            for (size_t j = 0; j < fb.size(); j++)
                if (!dropB[j])
                    record(fb[j], Origin{1, (int)j});
        }
        // the faces of the two lying in one plane side by side (a sleeve's end and the part's face round it)
        // merged into one, as a boolean leaves them: faces.top finds one face
        return wrap(unify_history(solid));
    });
}

hc_shape *hc_join_touching(const hc_shape *a, const hc_shape *b, int glue)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (glue) {
            BRepAlgoAPI_Fuse mk;
            TopTools_ListOfShape args, tools;
            args.Append(a->shape);
            tools.Append(b->shape);
            mk.SetArguments(args);
            mk.SetTools(tools);
            mk.SetRunParallel(Standard_True);
            mk.SetGlue(BOPAlgo_GlueShift);
            mk.Build();
            if (!mk.IsDone())
                throw Standard_Failure("the glued fuse failed");
            return primitive(mk.Shape());
        }
        // a's faces on one plane merged first (a cut leaves the circle a shaft stood in on the face round
        // it); each merged face remembers the first of a's it came from
        ShapeUpgrade_UnifySameDomain unify(a->shape, Standard_False, Standard_True, Standard_False);
        unify.Build();
        const TopoDS_Shape A = unify.Shape();
        TopTools_IndexedMapOfShape ma0;
        TopExp::MapShapes(a->shape, TopAbs_FACE, ma0);
        TopTools_DataMapOfShapeInteger fromA;
        for (int i = 1; i <= ma0.Extent(); i++) {
            const TopTools_ListOfShape &mods = unify.History()->Modified(ma0(i));
            if (mods.IsEmpty()) {
                if (!fromA.IsBound(ma0(i)))
                    fromA.Bind(ma0(i), i - 1);
            } else
                for (TopTools_ListOfShape::Iterator it(mods); it.More(); it.Next())
                    if (!fromA.IsBound(it.Value()))
                        fromA.Bind(it.Value(), i - 1);
        }
        // b's flat face lying on one of a's, facing it
        TopoDS_Face fa, fb;
        for (TopExp_Explorer eb(b->shape, TopAbs_FACE); eb.More() && fb.IsNull(); eb.Next()) {
            const TopoDS_Face &f = TopoDS::Face(eb.Current());
            BRepAdaptor_Surface sb(f);
            if (sb.GetType() != GeomAbs_Plane)
                continue;
            const gp_Pln pb = sb.Plane();
            for (TopExp_Explorer ea(A, TopAbs_FACE); ea.More(); ea.Next()) {
                const TopoDS_Face &g = TopoDS::Face(ea.Current());
                BRepAdaptor_Surface sa(g);
                if (sa.GetType() != GeomAbs_Plane)
                    continue;
                const gp_Pln pa = sa.Plane();
                if (!pa.Axis().IsParallel(pb.Axis(), 1e-9) || pa.Distance(pb.Location()) > 1e-7)
                    continue;
                // b's face inside a's: its points classified on a's face
                BRepTopAdaptor_FClass2d cls(g, 1e-7);
                bool inside = true;
                for (TopExp_Explorer v(f, TopAbs_VERTEX); v.More() && inside; v.Next()) {
                    gp_Pnt p = BRep_Tool::Pnt(TopoDS::Vertex(v.Current()));
                    double u, w;
                    ElSLib::Parameters(pa, p, u, w);
                    inside = cls.Perform(gp_Pnt2d(u, w)) == TopAbs_IN;
                }
                if (inside) {
                    fa = g;
                    fb = f;
                    break;
                }
            }
        }
        if (fa.IsNull())
            throw Standard_Failure("no flat face of the one lies on a flat face of the other");
        // a's face with a hole: its own wires, and b's face's outer wire, reversed
        BRepBuilderAPI_MakeFace mf(BRep_Tool::Surface(fa), BRepTools::OuterWire(fa));
        for (TopExp_Explorer w(fa, TopAbs_WIRE); w.More(); w.Next())
            if (!w.Current().IsSame(BRepTools::OuterWire(fa)))
                mf.Add(TopoDS::Wire(w.Current()));
        TopoDS_Wire hole = BRepTools::OuterWire(fb);
        mf.Add(TopoDS::Wire(fa.Orientation() == fb.Orientation() ? hole.Reversed() : hole));
        ShapeFix_Face fix(mf.Face());
        fix.Perform();
        BRepBuilderAPI_Sewing sew(1e-6);
        for (TopExp_Explorer ea(A, TopAbs_FACE); ea.More(); ea.Next())
            if (!ea.Current().IsSame(fa))
                sew.Add(ea.Current());
        sew.Add(fix.Face());
        for (TopExp_Explorer eb(b->shape, TopAbs_FACE); eb.More(); eb.Next())
            if (!eb.Current().IsSame(fb))
                sew.Add(eb.Current());
        sew.Perform();
        if (sew.NbFreeEdges() > 0)
            throw Standard_Failure(("the joined faces do not close: " + std::to_string(sew.NbFreeEdges()) + " edges open").c_str());
        BRepBuilderAPI_MakeSolid ms;
        for (TopExp_Explorer ex(sew.SewedShape(), TopAbs_SHELL); ex.More(); ex.Next())
            ms.Add(TopoDS::Shell(ex.Current()));
        TopoDS_Shape r = ms.Solid();
        GProp_GProps g;
        BRepGProp::VolumeProperties(r, g);
        if (g.Mass() < 0)
            r.Reverse();
        if (!BRepCheck_Analyzer(r).IsValid())
            throw Standard_Failure("the joined solid is not valid");
        // each face from the one it was: a's, b's, and the holed face from a's face
        history_new(r);
        TopTools_IndexedMapOfShape res, mb;
        TopExp::MapShapes(r, TopAbs_FACE, res);
        TopExp::MapShapes(b->shape, TopAbs_FACE, mb);
        auto mark = [&](const TopoDS_Shape &original, int input, int index) {
            const int j = res.FindIndex(sew.Modified(original));
            if (j > 0 && index >= 0)
                g_history[j - 1] = Origin{input, index};
        };
        for (TopExp_Explorer ea(A, TopAbs_FACE); ea.More(); ea.Next())
            if (!ea.Current().IsSame(fa))
                mark(ea.Current(), 0, fromA.IsBound(ea.Current()) ? fromA.Find(ea.Current()) : -1);
        mark(fix.Face(), 0, fromA.IsBound(fa) ? fromA.Find(fa) : -1);
        for (int i = 1; i <= mb.Extent(); i++)
            if (!mb(i).IsSame(fb))
                mark(mb(i), 1, i - 1);
        return checked(wrap(r));
    });
}

// The plane of a flat path: false when it is not flat (or a straight line).
static bool path_plane(const TopoDS_Shape &w, gp_Pln &pln)
{
    BRepBuilderAPI_FindPlane fp(w, 1e-6);
    if (!fp.Found())
        return false;
    pln = fp.Plane()->Pln();
    return true;
}

// The curve in space that, seen across the plane of flat path a, is a, and
// across b's, is b: where the two paths pushed across their planes meet.
// na, nb: the planes' normals, or zero to find them (a straight path needs one).
hc_shape *hc_projected_curve(const hc_shape *a, const hc_shape *b, const double na[3], const double nb[3])
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        Bnd_Box box;
        BRepBndLib::Add(a->shape, box);
        BRepBndLib::Add(b->shape, box);
        const double reach = std::sqrt(box.SquareExtent()) * 2 + 10;
        auto across = [&](const hc_shape *p, const double nv[3], const char *which) -> TopoDS_Shape {
            gp_Vec n(nv[0], nv[1], nv[2]);
            if (n.Magnitude() < 1e-12) {
                gp_Pln pln;
                if (!path_plane(p->shape, pln))
                    throw Standard_Failure((std::string("the ") + which +
                                            " path is not flat (or is straight): its plane cannot be found").c_str());
                n = gp_Vec(pln.Axis().Direction());
            }
            n.Normalize();
            gp_Trsf back;
            back.SetTranslation(n * -reach);
            TopoDS_Shape moved = BRepBuilderAPI_Transform(p->shape, back, Standard_True).Shape();
            return BRepPrimAPI_MakePrism(moved, n * (2 * reach)).Shape();
        };
        TopoDS_Shape sa = across(a, na, "first"), sb = across(b, nb, "second");
        BRepAlgoAPI_Section sec(sa, sb, Standard_False);
        sec.Approximation(Standard_True);
        sec.ComputePCurveOn1(Standard_False);
        sec.Build();
        if (!sec.IsDone())
            throw Standard_Failure("the two paths could not be crossed");
        std::vector<TopoDS_Edge> edges;
        for (TopExp_Explorer e(sec.Shape(), TopAbs_EDGE); e.More(); e.Next())
            edges.push_back(TopoDS::Edge(e.Current()));
        if (edges.empty())
            throw Standard_Failure("the two paths never meet: seen from each other's side, they do not overlap");
        auto wires = joined_wires(edges, 1e-5);
        if (wires.size() != 1)
            throw Standard_Failure(("the two paths meet in " + std::to_string(wires.size()) +
                                    " separate pieces: one view must not turn back on itself across the other").c_str());
        return primitive(wires[0]);
    });
}

hc_shape *hc_outline_regions(const double *data, int n, int *full_count)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<TopoDS_Wire> loops;
        std::vector<OutlineFill> fills;
        parse_outline(data, n, loops, fills);
        if (loops.empty()) {
            set_error("the outline is empty");
            return nullptr;
        }
        auto regions = outline_regions(loops, fills);
        BRep_Builder b;
        TopoDS_Compound c;
        b.MakeCompound(c);
        int count = 0;
        for (int pass = 0; pass < 2; pass++)
            for (auto &r : regions)
                if (r.second == (pass == 0)) {
                    b.Add(c, r.first);
                    count += pass == 0;
                }
        *full_count = count;
        return primitive(c);
    });
}

int hc_path_frame(const hc_shape *path, int at_end, double out[6])
{
    return guarded<>(0, [&]() -> int {
        BRepAdaptor_CompCurve c(single_wire(path->shape));
        double u = at_end ? c.LastParameter() : c.FirstParameter();
        gp_Pnt p;
        gp_Vec t;
        c.D1(u, p, t);
        double v[6] = {p.X(), p.Y(), p.Z(), t.X(), t.Y(), t.Z()};
        for (int i = 0; i < 6; i++)
            out[i] = v[i];
        return 1;
    });
}

// Triangles filling a closed polygon in a plane (ear clipping), wound
// counter-clockwise about `normal`: indices into `pts`.
static std::vector<std::array<int, 3>> fill_polygon(const std::vector<gp_Pnt> &pts, const gp_Dir &normal)
{
    const int n = (int)pts.size();
    gp_Dir x = std::abs(normal.Z()) < 0.9 ? gp_Dir(gp_Vec(0, 0, 1).Crossed(gp_Vec(normal))) : gp_Dir(gp_Vec(1, 0, 0).Crossed(gp_Vec(normal)));
    gp_Dir y = normal.Crossed(x);
    std::vector<double> u(n), v(n);
    for (int i = 0; i < n; i++) {
        gp_Vec d(pts[0], pts[i]);
        u[i] = d.Dot(gp_Vec(x));
        v[i] = d.Dot(gp_Vec(y));
    }
    std::vector<int> ring(n);
    double area = 0;
    for (int i = 0; i < n; i++) {
        ring[i] = i;
        int j = (i + 1) % n;
        area += u[i] * v[j] - u[j] * v[i];
    }
    if (area < 0)
        std::reverse(ring.begin(), ring.end());
    auto cross = [&](int a, int b, int c) { return (u[b] - u[a]) * (v[c] - v[a]) - (v[b] - v[a]) * (u[c] - u[a]); };
    std::vector<std::array<int, 3>> tris;
    int guard = 0;
    while (ring.size() > 3 && guard++ < 100000) {
        const int m = (int)ring.size();
        bool cut = false;
        for (int k = 0; k < m && !cut; k++) {
            int a = ring[(k + m - 1) % m], b = ring[k], c = ring[(k + 1) % m];
            if (cross(a, b, c) <= 1e-12)
                continue;   // a reflex corner, or none
            bool empty = true;
            for (int q : ring) {
                if (q == a || q == b || q == c)
                    continue;
                if (cross(a, b, q) >= 0 && cross(b, c, q) >= 0 && cross(c, a, q) >= 0) {
                    empty = false;
                    break;
                }
            }
            if (!empty)
                continue;
            tris.push_back({a, b, c});
            ring.erase(ring.begin() + k);
            cut = true;
        }
        if (!cut) {
            // nothing clean left (points in a line): a fan of what remains
            for (size_t k = 1; k + 1 < ring.size(); k++)
                tris.push_back({ring[0], ring[k], ring[k + 1]});
            ring.clear();
        }
    }
    if (ring.size() == 3)
        tris.push_back({ring[0], ring[1], ring[2]});
    return tris;
}

// ---- solids through rings of points (loft of Vec3[][]): one smooth
// B-spline surface through every point, periodic round the rings, built as
// a tensor product (a periodic curve through each ring, all with the same
// parameters so the same knots, then a curve through each column of their
// poles across the rings); no sections to match, as a loft through so many
// would. Each face comes with its own triangles, from the grid (see
// attach_mesh), so drawing and export do not wait on the mesher, which
// takes seconds on a surface of so many patches.

static Handle(Geom_BSplineSurface) grid_surface(const double *xyz, int rings, int per)
{
    auto P = [&](int r, int i) { const double *v = xyz + 3 * (r * per + i); return gp_Pnt(v[0], v[1], v[2]); };
    // round each ring: periodic, the same parameters 0 … per for all (a closed
    // curve takes one more, where it comes back to its first point)
    Handle(TColStd_HArray1OfReal) up = new TColStd_HArray1OfReal(1, per + 1);
    for (int i = 0; i <= per; i++)
        up->SetValue(i + 1, i);
    std::vector<Handle(Geom_BSplineCurve)> round(rings);
    for (int r = 0; r < rings; r++) {
        Handle(TColgp_HArray1OfPnt) pts = new TColgp_HArray1OfPnt(1, per);
        for (int i = 0; i < per; i++)
            pts->SetValue(i + 1, P(r, i));
        GeomAPI_Interpolate fit(pts, up, Standard_True, 1e-9);
        fit.Perform();
        if (!fit.IsDone()) {
            set_error("cannot fit a smooth ring through these points (repeated points?)");
            return nullptr;
        }
        round[r] = fit.Curve();
    }
    const int nu = round[0]->NbPoles();
    for (int r = 1; r < rings; r++)
        if (round[r]->NbPoles() != nu) {
            set_error("the rings do not match: give each the same number of points");
            return nullptr;
        }
    // across the rings: a curve through each column of poles, the same parameters for all
    Handle(TColStd_HArray1OfReal) vp = new TColStd_HArray1OfReal(1, rings);
    for (int r = 0; r < rings; r++)
        vp->SetValue(r + 1, r);
    std::vector<Handle(Geom_BSplineCurve)> across(nu);
    for (int j = 0; j < nu; j++) {
        Handle(TColgp_HArray1OfPnt) col = new TColgp_HArray1OfPnt(1, rings);
        for (int r = 0; r < rings; r++)
            col->SetValue(r + 1, round[r]->Pole(j + 1));
        if (rings == 2) {
            // two rings: straight across
            TColgp_Array1OfPnt poles(1, 2);
            poles(1) = col->Value(1);
            poles(2) = col->Value(2);
            TColStd_Array1OfReal knots(1, 2);
            knots(1) = 0;
            knots(2) = 1;
            TColStd_Array1OfInteger mults(1, 2);
            mults(1) = mults(2) = 2;
            across[j] = new Geom_BSplineCurve(poles, knots, mults, 1);
            continue;
        }
        GeomAPI_Interpolate fit(col, vp, Standard_False, 1e-9);
        fit.Perform();
        if (!fit.IsDone()) {
            set_error("cannot fit a smooth surface across these rings");
            return nullptr;
        }
        across[j] = fit.Curve();
    }
    const Handle(Geom_BSplineCurve) &c0 = round[0], &a0 = across[0];
    const int nv = a0->NbPoles();
    TColgp_Array2OfPnt poles(1, nu, 1, nv);
    for (int j = 0; j < nu; j++)
        for (int k = 0; k < nv; k++)
            poles(j + 1, k + 1) = across[j]->Pole(k + 1);
    TColStd_Array1OfReal uk(1, c0->NbKnots()), vk(1, a0->NbKnots());
    TColStd_Array1OfInteger um(1, c0->NbKnots()), vm(1, a0->NbKnots());
    c0->Knots(uk);
    c0->Multiplicities(um);
    a0->Knots(vk);
    a0->Multiplicities(vm);
    return new Geom_BSplineSurface(poles, uk, vk, um, vm, c0->Degree(), a0->Degree(), Standard_True, Standard_False);
}

// where a grid surface is sampled for its triangles: two samples a knot span
struct GridSamples {
    std::vector<double> us, vs;   // us round (no repeat of the first), vs across, ends included
    double period;
};

static GridSamples grid_samples(const Handle(Geom_BSplineSurface) &surf)
{
    GridSamples g;
    double u0, u1, v0, v1;
    surf->Bounds(u0, u1, v0, v1);
    g.period = u1 - u0;
    for (int i = 1; i < surf->NbUKnots(); i++) {
        double a = surf->UKnot(i), b = surf->UKnot(i + 1);
        g.us.push_back(a);
        g.us.push_back((a + b) / 2);
    }
    for (int i = 1; i < surf->NbVKnots(); i++) {
        double a = surf->VKnot(i), b = surf->VKnot(i + 1);
        g.vs.push_back(a);
        g.vs.push_back((a + b) / 2);
    }
    g.vs.push_back(surf->VKnot(surf->NbVKnots()));
    return g;
}

static std::vector<gp_Pnt> grid_ring(const Handle(Geom_BSplineSurface) &surf, const GridSamples &g, double v)
{
    std::vector<gp_Pnt> r;
    for (double u : g.us)
        r.push_back(surf->Value(u, v));
    return r;
}

// the side's triangles: nu + 1 columns, the last the first again (u + period), so the seam has its own nodes
static Handle(Poly_Triangulation) grid_side_mesh(const Handle(Geom_BSplineSurface) &surf, const GridSamples &g)
{
    const int nu = (int)g.us.size(), nv = (int)g.vs.size();
    Handle(Poly_Triangulation) side = new Poly_Triangulation((nu + 1) * nv, 2 * nu * (nv - 1), Standard_True);
    auto node = [&](int i, int j) { return j * (nu + 1) + i + 1; };
    for (int j = 0; j < nv; j++)
        for (int i = 0; i <= nu; i++) {
            side->SetNode(node(i, j), surf->Value(g.us[i % nu], g.vs[j]));
            side->SetUVNode(node(i, j), gp_Pnt2d(i < nu ? g.us[i] : g.us[0] + g.period, g.vs[j]));
        }
    int t = 1;
    for (int j = 0; j + 1 < nv; j++)
        for (int i = 0; i < nu; i++) {
            side->SetTriangle(t++, Poly_Triangle(node(i, j), node(i + 1, j), node(i + 1, j + 1)));
            side->SetTriangle(t++, Poly_Triangle(node(i, j), node(i + 1, j + 1), node(i, j + 1)));
        }
    side->Deflection(1e-7);
    return side;
}

// a flat end filled from its boundary points, wound about `normal`
static Handle(Poly_Triangulation) cap_mesh(const std::vector<gp_Pnt> &ring, const gp_Dir &normal)
{
    auto tris = fill_polygon(ring, normal);
    Handle(Poly_Triangulation) cap = new Poly_Triangulation((int)ring.size(), (int)tris.size(), Standard_False);
    for (size_t i = 0; i < ring.size(); i++)
        cap->SetNode((int)i + 1, ring[i]);
    for (size_t k = 0; k < tris.size(); k++)
        cap->SetTriangle((int)k + 1, Poly_Triangle(tris[k][0] + 1, tris[k][1] + 1, tris[k][2] + 1));
    cap->Deflection(1e-7);
    return cap;
}

// a flat ring between two rings of as many points (the rim of a hollow
// solid), each quad split in two, wound about `normal`
static Handle(Poly_Triangulation) rim_mesh(const std::vector<gp_Pnt> &outer, const std::vector<gp_Pnt> &inner, const gp_Dir &normal)
{
    const int n = (int)outer.size();
    Handle(Poly_Triangulation) rim = new Poly_Triangulation(2 * n, 2 * n, Standard_False);
    for (int i = 0; i < n; i++) {
        rim->SetNode(i + 1, outer[i]);
        rim->SetNode(n + i + 1, inner[i]);
    }
    // the way round the outer ring goes, seen down the normal
    gp_Vec turn(0, 0, 0);
    for (int i = 0; i < n; i++)
        turn += gp_Vec(outer[i].XYZ()).Crossed(gp_Vec(outer[(i + 1) % n].XYZ()));
    const bool ccw = turn.Dot(gp_Vec(normal)) > 0;
    int t = 1;
    for (int i = 0; i < n; i++) {
        int a = i + 1, b = (i + 1) % n + 1, c = n + (i + 1) % n + 1, d = n + i + 1;
        if (ccw) {
            rim->SetTriangle(t++, Poly_Triangle(a, b, c));
            rim->SetTriangle(t++, Poly_Triangle(a, c, d));
        } else {
            rim->SetTriangle(t++, Poly_Triangle(a, c, b));
            rim->SetTriangle(t++, Poly_Triangle(a, d, c));
        }
    }
    rim->Deflection(1e-7);
    return rim;
}

static TopoDS_Wire iso_wire(const Handle(Geom_BSplineSurface) &surf, double v)
{
    return BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(surf->VIso(v)).Edge()).Wire();
}

// faces sewn into one closed solid, facing out
static TopoDS_Shape close_solid(const std::vector<TopoDS_Face> &faces)
{
    BRepBuilderAPI_Sewing sew(1e-5);
    for (const TopoDS_Face &f : faces)
        sew.Add(f);
    sew.Perform();
    TopoDS_Shell shell;
    for (TopExp_Explorer e(sew.SewedShape(), TopAbs_SHELL); e.More(); e.Next()) {
        shell = TopoDS::Shell(e.Current());
        break;
    }
    if (shell.IsNull()) {
        set_error("the rings do not close into a solid");
        return TopoDS_Shape();
    }
    TopoDS_Solid solid = BRepBuilderAPI_MakeSolid(shell).Solid();
    BRepClass3d_SolidClassifier inside(solid);
    inside.PerformInfinitePoint(1e-7);
    if (inside.State() == TopAbs_IN)
        solid.Reverse();
    ShapeFix_Solid fix(solid);
    fix.Perform();
    return fix.Solid();
}

// Each face of `solid` gets its triangles: a grid side (by its surface), a
// flat face by what it is near: an end ring (filled), or the rim between the
// two top rings. Set on the faces only (not the edges: the check of the
// solid would hold their points against the sewn edges' own parameters),
// marked as fine as can be: hc_tessellate takes them as they are.
static void attach_mesh(const TopoDS_Shape &solid, const std::vector<Handle(Geom_BSplineSurface)> &sides,
    const std::vector<std::vector<gp_Pnt>> &ends, const std::vector<gp_Pnt> &rimOuter, const std::vector<gp_Pnt> &rimInner)
{
    BRep_Builder bb;
    for (TopExp_Explorer f(solid, TopAbs_FACE); f.More(); f.Next()) {
        const TopoDS_Face &face = TopoDS::Face(f.Current());
        TopLoc_Location loc;
        Handle(Geom_Surface) gs = BRep_Tool::Surface(face, loc);
        bool done = false;
        for (const auto &side : sides)
            if (gs == side) {
                bb.UpdateFace(face, grid_side_mesh(side, grid_samples(side)));
                done = true;
            }
        if (done)
            continue;
        Handle(Geom_Plane) plane = Handle(Geom_Plane)::DownCast(gs);
        if (plane.IsNull())
            continue;
        gp_Pln pl = plane->Pln();
        const gp_Dir n = pl.Axis().Direction();
        int wires = 0;
        for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next())
            wires++;
        if (wires == 2 && !rimOuter.empty()) {
            bb.UpdateFace(face, rim_mesh(rimOuter, rimInner, n));
            continue;
        }
        // the end ring lying in this plane
        const std::vector<gp_Pnt> *best = nullptr;
        double closest = 1e300;   // not "far": a macro in the Windows headers
        for (const auto &e : ends) {
            double d = 0;
            for (const gp_Pnt &p : e)
                d = std::max(d, pl.Distance(p));
            if (d < closest) {
                closest = d;
                best = &e;
            }
        }
        if (best)
            bb.UpdateFace(face, cap_mesh(*best, n));
    }
}

// A solid through rings of points: `rings` rings of `per` points each
// (x y z), every ring closed on itself; the first and the last ring, which
// must each lie in a plane, filled flat.
hc_shape *hc_grid_solid(const double *xyz, int rings, int per)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (rings < 2 || per < 3) {
            set_error("a solid through rings needs 2 rings of 3 points at least");
            return nullptr;
        }
        Handle(Geom_BSplineSurface) surf = grid_surface(xyz, rings, per);
        if (surf.IsNull())
            return nullptr;
        double u0, u1, v0, v1;
        surf->Bounds(u0, u1, v0, v1);
        BRepBuilderAPI_MakeFace bottom(iso_wire(surf, v0), Standard_True), top(iso_wire(surf, v1), Standard_True);
        if (!bottom.IsDone() || !top.IsDone()) {
            set_error("the first and the last ring must each lie in a plane, to be closed flat");
            return nullptr;
        }
        TopoDS_Shape result = close_solid({BRepBuilderAPI_MakeFace(surf, 1e-7).Face(), bottom.Face(), top.Face()});
        if (result.IsNull())
            return nullptr;
        auto g = grid_samples(surf);
        attach_mesh(result, {surf}, {grid_ring(surf, g, v0), grid_ring(surf, g, v1)}, {}, {});
        return primitive(result);
    });
}

// A hollow solid through two sets of rings, outer and inner, as many points
// in every ring: the walls through them, the outer first ring filled flat
// (the foot), the inner first ring filled flat (the floor inside), and the
// two last rings joined by a flat rim: the last rings must lie in one
// plane, open between them. A vase with its own walls, no offset nor
// boolean to compute.
hc_shape *hc_grid_hollow(const double *outer, int outerRings, const double *inner, int innerRings, int per)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (outerRings < 2 || innerRings < 2 || per < 3) {
            set_error("a hollow solid through rings needs 2 rings of 3 points at least, outside and inside");
            return nullptr;
        }
        Handle(Geom_BSplineSurface) out = grid_surface(outer, outerRings, per);
        if (out.IsNull())
            return nullptr;
        Handle(Geom_BSplineSurface) in = grid_surface(inner, innerRings, per);
        if (in.IsNull())
            return nullptr;
        double u0, u1, ov0, ov1, iv0, iv1;
        out->Bounds(u0, u1, ov0, ov1);
        in->Bounds(u0, u1, iv0, iv1);
        BRepBuilderAPI_MakeFace foot(iso_wire(out, ov0), Standard_True), floor(iso_wire(in, iv0), Standard_True);
        BRepBuilderAPI_MakeFace rim(iso_wire(out, ov1), Standard_True);
        if (!foot.IsDone() || !floor.IsDone() || !rim.IsDone()) {
            set_error("the first rings and the last ones must each lie in a plane");
            return nullptr;
        }
        TopoDS_Wire hole = iso_wire(in, iv1);
        hole.Reverse();
        rim.Add(hole);
        if (!rim.IsDone()) {
            set_error("the last outer and inner rings must lie in one plane, the inner one inside");
            return nullptr;
        }
        TopoDS_Shape result = close_solid({BRepBuilderAPI_MakeFace(out, 1e-7).Face(), BRepBuilderAPI_MakeFace(in, 1e-7).Face(),
            foot.Face(), floor.Face(), rim.Face()});
        if (result.IsNull())
            return nullptr;
        auto go = grid_samples(out), gi = grid_samples(in);
        attach_mesh(result, {out, in}, {grid_ring(out, go, ov0), grid_ring(in, gi, iv0)}, grid_ring(out, go, ov1),
            grid_ring(in, gi, iv1));
        return primitive(result);
    });
}

// `n` points evenly along a path by length, ends included, each with its
// unit tangent: out holds 6 doubles per point (x y z tx ty tz).
int hc_path_sample(const hc_shape *path, int n, double *out)
{
    return guarded<>(0, [&]() -> int {
        if (n < 2) {
            set_error("a path is sampled at 2 points at least");
            return 0;
        }
        BRepAdaptor_CompCurve c(single_wire(path->shape));
        GCPnts_UniformAbscissa even(c, n);
        if (!even.IsDone() || even.NbPoints() != n) {
            set_error("cannot space points evenly along this path");
            return 0;
        }
        for (int i = 0; i < n; i++) {
            gp_Pnt p;
            gp_Vec t;
            c.D1(even.Parameter(i + 1), p, t);
            if (t.Magnitude() > 1e-12)
                t.Normalize();
            double v[6] = {p.X(), p.Y(), p.Z(), t.X(), t.Y(), t.Z()};
            for (int k = 0; k < 6; k++)
                out[6 * i + k] = v[k];
        }
        return 1;
    });
}

// A guide for a sweep that turns the profile by `twist` radians from the start
// of `spine` to its end, evenly along its length: a curve winding around it,
// at `radius` at most, starting in direction `start` (normal to the spine
// there). The reference it turns from follows the spine without turning on
// its own. The sweep finds the guide where the plane normal to the spine
// cuts it.
// The roll at fraction f of the path, from `n` angles evenly along it.
static double roll_at(const double *angles, int n, double f)
{
    if (n < 2)
        return n == 1 ? angles[0] * f : 0;
    const double x = std::max(0.0, std::min(1.0, f)) * (n - 1);
    const int k = std::min(n - 2, (int)x);
    return angles[k] + (angles[k + 1] - angles[k]) * (x - k);
}

// The reference a roll is counted from, carried along the path one place to
// the next (t the unit tangent there): kept normal to the path without
// turning about it; or, along a helix (its `axis` given), at a fixed angle
// from the axis seen across the path, as a sweep along a helix keeps its
// profile. A null vector where it cannot be carried on.
struct RollReference {
    const gp_Vec *axis = nullptr;
    double angle = 0;
    bool started = false;
    gp_Vec next(gp_Vec ref, const gp_Vec &t)
    {
        if (axis == nullptr) {
            ref = ref - t * ref.Dot(t);
            return ref.Magnitude() < 1e-9 ? gp_Vec(0, 0, 0) : ref.Normalized();
        }
        gp_Vec y = *axis - t * axis->Dot(t);
        if (y.Magnitude() < 1e-9)
            return gp_Vec(0, 0, 0);
        y.Normalize();
        const gp_Vec x = y.Crossed(t);
        if (!started) {
            angle = std::atan2(ref.Dot(y), ref.Dot(x));
            started = true;
        }
        return x * std::cos(angle) + y * std::sin(angle);
    }
};

// The axis of a path that is a helix (its tangent at one angle to a fixed
// direction all along, not in a plane), or false.
static bool helix_axis(const TopoDS_Wire &spine, gp_Vec &axis)
{
    BRepAdaptor_CompCurve c(spine);
    GCPnts_UniformAbscissa ua(c, 97);
    if (!ua.IsDone() || ua.NbPoints() != 97)
        return false;
    std::vector<gp_Vec> ts;
    for (int i = 1; i <= ua.NbPoints(); i++) {
        gp_Pnt p;
        gp_Vec t;
        c.D1(ua.Parameter(i), p, t);
        if (t.Magnitude() < 1e-12)
            return false;
        ts.push_back(t.Normalized());
    }
    // the tangents lie on a cone round the axis: across any three in a row, all
    // of them summed (an approximated helix wavers a little)
    gp_Vec a(0, 0, 0);
    for (size_t i = 0; i + 2 < ts.size(); i++) {
        const gp_Vec n = (ts[i + 1] - ts[i]).Crossed(ts[i + 2] - ts[i + 1]);
        a += a.Dot(n) < 0 ? -n : n;
    }
    if (a.Magnitude() < 1e-12)
        return false;
    a.Normalize();
    const double slope = ts[0].Dot(a);
    if (std::abs(slope) < 1e-6)
        return false;   // in a plane: carried as any path is
    for (const auto &t : ts)
        if (std::abs(t.Dot(a) - slope) > 1e-6)
            return false;
    axis = a;
    return true;
}

// The roll along the path (n angles evenly along it, from 0) that keeps the
// profile's +Y towards `towards(fraction, point, tangent)`, from a profile
// placed with its +X along `start`: against the reference carried along the
// path (RollReference), as twist_guide carries it.
static std::vector<double> roll_towards(const TopoDS_Wire &spine, gp_Dir start, int n,
                                        const std::function<gp_Vec(double, const gp_Pnt &, const gp_Vec &)> &towards,
                                        const gp_Vec *axis = nullptr)
{
    RollReference carry{axis};
    BRepAdaptor_CompCurve c(spine);
    GCPnts_UniformAbscissa ua(c, n);
    if (!ua.IsDone() || ua.NbPoints() != n)
        throw Standard_Failure("the path is too short to sweep along");
    std::vector<double> r;
    gp_Vec ref(start);
    double last = 0;
    for (int i = 1; i <= n; i++) {
        gp_Pnt p;
        gp_Vec t;
        c.D1(ua.Parameter(i), p, t);
        if (t.Magnitude() < 1e-12)
            throw Standard_Failure("the path stops along the way");
        t.Normalize();
        ref = carry.next(ref, t);
        if (ref.Magnitude() < 1e-9)
            throw Standard_Failure("the path turns too sharply");
        const gp_Vec refY = t.Crossed(ref);
        gp_Vec d = towards((i - 1.0) / (n - 1.0), p, t);
        d = d - t * d.Dot(t);
        if (d.Magnitude() < 1e-9)
            throw Standard_Failure((std::string("at ") + std::to_string((int)std::lround(100.0 * (i - 1) / (n - 1))) +
                                    "% of its way").c_str());
        double a = std::atan2(refY.Crossed(d).Dot(t), refY.Dot(d));
        // no jumps of a whole turn from one place to the next
        while (a - last > M_PI)
            a -= 2 * M_PI;
        while (a - last < -M_PI)
            a += 2 * M_PI;
        r.push_back(a);
        last = a;
    }
    return r;
}

static TopoDS_Wire twist_guide(const TopoDS_Wire &spine, gp_Dir start, const double *angles, int nAngles, double radius,
                               const gp_Vec *axis = nullptr)
{
    RollReference carry{axis};
    BRepAdaptor_CompCurve c(spine);
    // how the path bends: the guide keeps well inside its tightest bend (a
    // plane normal to the path would cut it twice there), and gets more
    // points where the path turns more
    const int probes = 400;
    const double u0 = c.FirstParameter(), u1 = c.LastParameter();
    double tightest = Precision::Infinite(), turning = 0;
    for (int i = 0; i <= probes; i++) {
        gp_Pnt p;
        gp_Vec d1, d2;
        c.D2(u0 + (u1 - u0) * i / probes, p, d1, d2);
        const double speed = d1.Magnitude();
        if (speed < 1e-12)
            continue;
        const double k = d1.Crossed(d2).Magnitude() / (speed * speed * speed);
        if (k > 1e-12)
            tightest = std::min(tightest, 1 / k);
        if (i < probes)
            turning += k * speed * (u1 - u0) / probes;
    }
    radius = std::min(radius, 0.2 * tightest);
    // points close enough for an interpolation to follow the winding
    double winding = 0;   // how far the roll goes, back and forth
    for (int k = 1; k < nAngles; k++)
        winding += std::abs(angles[k] - angles[k - 1]);
    const double turns = (winding + turning) / (2 * M_PI);
    const int n = std::min(2000, std::max(24, (int)std::ceil(turns * 72) + 24));
    GCPnts_UniformAbscissa ua(c, n + 1);
    if (!ua.IsDone() || ua.NbPoints() < 3)
        throw Standard_Failure("the path is too short to twist along");
    // and well inside where the path passes near itself again (the next turn of a
    // helix): a plane across the path would cut the guide's other turns there too
    {
        std::vector<gp_Pnt> at;
        for (int i = 1; i <= ua.NbPoints(); i++)
            at.push_back(c.Value(ua.Parameter(i)));
        const double length = GCPnts_AbscissaPoint::Length(c), step = length / (at.size() - 1);
        const bool closed = at.front().Distance(at.back()) < 1e-7;
        double clearance = Precision::Infinite();
        for (size_t i = 0; i < at.size(); i++)
            for (size_t j = i + 2; j < at.size(); j++) {
                const double d = at[i].Distance(at[j]);
                // how far apart along the path (either way round a closed one)
                const double along = closed ? std::min((j - i) * step, length - (j - i) * step) : (j - i) * step;
                if (along > 2 * d)
                    clearance = std::min(clearance, d);
            }
        radius = std::min(radius, 0.25 * clearance);
    }
    Handle(TColgp_HArray1OfPnt) pts = new TColgp_HArray1OfPnt(1, ua.NbPoints());
    gp_Vec ref(start);
    for (int i = 1; i <= ua.NbPoints(); i++) {
        gp_Pnt p;
        gp_Vec t;
        c.D1(ua.Parameter(i), p, t);
        if (t.Magnitude() < 1e-12)
            throw Standard_Failure("the path stops along the way: it cannot be twisted along");
        t.Normalize();
        // the reference carried along, kept normal to the path
        ref = carry.next(ref, t);
        if (ref.Magnitude() < 1e-9)
            throw Standard_Failure("the path turns too sharply to twist along");
        const double f = (i - 1.0) / (ua.NbPoints() - 1.0);
        const gp_Vec turned = ref.Rotated(gp_Ax1(gp::Origin(), gp_Dir(t)), roll_at(angles, nAngles, f));
        pts->SetValue(i, p.Translated(turned * radius));
    }
    GeomAPI_Interpolate in(pts, Standard_False, 1e-9);
    in.Perform();
    if (!in.IsDone())
        throw Standard_Failure("could not build the twist along the path");
    return BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(in.Curve()).Edge()).Wire();
}

hc_shape *hc_sweep(const hc_shape *profile, const hc_shape *path, int frenet)
{
    return hc_sweep_twisted(profile, path, frenet, 0);
}

hc_shape *hc_sweep_twisted(const hc_shape *profile, const hc_shape *path, int frenet, double twist)
{
    const double angles[2] = {0, twist};
    const double none[3] = {0, 0, 0};
    return hc_sweep_ex(profile, path, frenet, angles, twist != 0 ? 2 : 0, none, nullptr);
}

// A path cut where it turns sharply (the mitred corners of a polyline): the
// smooth runs between the corners, each with where it lies along the path
// (fractions of its length) and its unit tangents at both ends.
struct PathRun {
    TopoDS_Wire wire;
    double from = 0, to = 1;
    gp_Pnt start, end;
    gp_Vec t0, t1;
};

static std::string point_text(const gp_Pnt &p)
{
    auto tidy = [](double v) { return std::abs(v) < 1e-9 ? 0.0 : v; };
    char b[128];
    std::snprintf(b, sizeof b, "(%g, %g, %g)", tidy(p.X()), tidy(p.Y()), tidy(p.Z()));
    return b;
}

// The runs of `spine`; `closingCorner` tells whether a closed path has a
// corner where it closes too. A path that turns right back on itself cannot
// be swept along: said here, with where.
static std::vector<PathRun> smooth_runs(const TopoDS_Wire &spine, bool &closingCorner)
{
    struct Piece {
        TopoDS_Edge e;
        gp_Pnt a, b;
        gp_Vec ta, tb;
        double len;
    };
    std::vector<Piece> ps;
    double total = 0;
    for (BRepTools_WireExplorer ex(spine); ex.More(); ex.Next()) {
        const TopoDS_Edge &e = ex.Current();
        if (BRep_Tool::Degenerated(e))
            continue;
        BRepAdaptor_Curve c(e);
        const double len = GCPnts_AbscissaPoint::Length(c);
        if (len < 1e-9)
            continue;
        Piece p{e, {}, {}, {}, {}, len};
        const double u0 = c.FirstParameter(), u1 = c.LastParameter(), du = (u1 - u0) * 1e-6;
        c.D1(u0, p.a, p.ta);
        c.D1(u1, p.b, p.tb);
        // a tangent that vanishes at an end: the way to a point just inside
        if (p.ta.Magnitude() < 1e-12)
            p.ta = gp_Vec(p.a, c.Value(u0 + du));
        if (p.tb.Magnitude() < 1e-12)
            p.tb = gp_Vec(c.Value(u1 - du), p.b);
        if (e.Orientation() == TopAbs_REVERSED) {
            std::swap(p.a, p.b);
            std::swap(p.ta, p.tb);
            p.ta.Reverse();
            p.tb.Reverse();
        }
        p.ta.Normalize();
        p.tb.Normalize();
        ps.push_back(p);
        total += len;
    }
    if (ps.empty())
        throw Standard_Failure("the path has no length");
    auto corner = [&](const gp_Vec &before, const gp_Vec &after, const gp_Pnt &at) {
        const double c = before.Dot(after);
        if (c < -1 + 1e-6)
            throw Standard_Failure(("the path turns right back on itself at " + point_text(at) +
                                    " mm: nothing can be swept along it there; let it turn aside instead").c_str());
        return c < std::cos(1e-3);
    };
    std::vector<PathRun> runs;
    BRepBuilderAPI_MakeWire mk;
    double done = 0;
    for (size_t i = 0; i < ps.size(); i++) {
        const bool turns = i > 0 && corner(ps[i - 1].tb, ps[i].ta, ps[i].a);
        if (turns) {
            runs.back().wire = mk.Wire();
            mk = BRepBuilderAPI_MakeWire();
        }
        if (i == 0 || turns) {
            PathRun r;
            r.from = done / total;
            r.start = ps[i].a;
            r.t0 = ps[i].ta;
            runs.push_back(r);
        }
        mk.Add(ps[i].e);
        done += ps[i].len;
        runs.back().to = done / total;
        runs.back().end = ps[i].b;
        runs.back().t1 = ps[i].tb;
    }
    runs.back().wire = mk.Wire();
    const bool closed = ps.front().a.Distance(ps.back().b) < 1e-7;
    closingCorner = closed && corner(ps.back().tb, ps.front().ta, ps.front().a);
    return runs;
}

// A run cut in two halves by length: a closed path swept with a roll (a
// winding guide does not close on itself; two halves of one do).
static std::vector<PathRun> halves(const PathRun &r)
{
    BRepAdaptor_CompCurve cc(r.wire);
    GCPnts_AbscissaPoint ap(cc, GCPnts_AbscissaPoint::Length(cc) / 2, cc.FirstParameter());
    if (!ap.IsDone())
        return {r};
    TopoDS_Edge at;
    double u;
    cc.Edge(ap.Parameter(), at, u);   // the edge cut, and where along its own curve
    BRepBuilderAPI_MakeWire a, b;
    bool past = false;
    for (BRepTools_WireExplorer ex(r.wire); ex.More(); ex.Next()) {
        const TopoDS_Edge &e = ex.Current();
        if (past || !e.IsSame(at)) {
            if (past)
                b.Add(e);
            else
                a.Add(e);
            continue;
        }
        past = true;
        double f, l;
        Handle(Geom_Curve) g = BRep_Tool::Curve(e, f, l);
        const double eps = 1e-9 * (l - f);
        if (g.IsNull() || u - f < eps || l - u < eps) {
            // cut at one of its ends: whole on the side it lies
            if ((e.Orientation() == TopAbs_REVERSED) == (u - f < eps))
                a.Add(e);
            else
                b.Add(e);
            continue;
        }
        TopoDS_Edge lo = BRepBuilderAPI_MakeEdge(g, f, u).Edge(), hi = BRepBuilderAPI_MakeEdge(g, u, l).Edge();
        if (e.Orientation() == TopAbs_REVERSED) {
            lo.Reverse();
            hi.Reverse();
            std::swap(lo, hi);
        }
        a.Add(lo);
        b.Add(hi);
    }
    if (!a.IsDone() || !b.IsDone())
        return {r};
    PathRun first = r, second = r;
    first.wire = a.Wire();
    second.wire = b.Wire();
    first.to = second.from = (r.from + r.to) / 2;
    gp_Pnt mid;
    gp_Vec t;
    cc.D1(ap.Parameter(), mid, t);
    if (t.Magnitude() < 1e-12)
        return {r};
    first.end = second.start = mid;
    first.t1 = second.t0 = t.Normalized();
    return {first, second};
}

// `ref`, normal to the path at the start of `run`, carried to its end
// without turning about the path (as twist_guide carries it).
static gp_Vec carry_along(const TopoDS_Wire &run, gp_Vec ref, const gp_Vec *axis)
{
    RollReference carry{axis};
    BRepAdaptor_CompCurve c(run);
    GCPnts_UniformAbscissa ua(c, 401);
    if (!ua.IsDone())
        throw Standard_Failure("the path is too short to sweep along");
    for (int i = 1; i <= ua.NbPoints(); i++) {
        gp_Pnt p;
        gp_Vec t;
        c.D1(ua.Parameter(i), p, t);
        if (t.Magnitude() < 1e-12)
            continue;
        t.Normalize();
        ref = carry.next(ref, t);
        if (ref.Magnitude() < 1e-9)
            throw Standard_Failure("the path turns too sharply");
    }
    return ref;
}

// How many whole turns a path makes (its curvature along its length, over 2 pi).
static double turns_of(const TopoDS_Wire &w)
{
    BRepAdaptor_CompCurve c(w);
    const int probes = 400;
    const double u0 = c.FirstParameter(), u1 = c.LastParameter();
    double turning = 0;
    for (int i = 0; i < probes; i++) {
        gp_Pnt p;
        gp_Vec d1, d2;
        c.D2(u0 + (u1 - u0) * (i + 0.5) / probes, p, d1, d2);
        const double speed = d1.Magnitude();
        if (speed > 1e-12)
            turning += d1.Crossed(d2).Magnitude() / (speed * speed) * (u1 - u0) / probes;
    }
    return turning / (2 * M_PI);
}

// The turn that carries a direction across a corner from `before` to
// `after`, about the corner itself: a mitre's (each side's section is the
// other's mirrored in the mitre plane).
static gp_Trsf across_corner(const gp_Pnt &at, const gp_Vec &before, const gp_Vec &after)
{
    gp_Trsf r;
    const gp_Vec axis = before.Crossed(after);
    if (axis.Magnitude() > 1e-12)
        r.SetRotation(gp_Ax1(at, gp_Dir(axis)), before.Angle(after));
    return r;
}

static TopoDS_Wire wire_in(const TopoDS_Shape &s)
{
    if (s.ShapeType() == TopAbs_WIRE)
        return TopoDS::Wire(s);
    if (s.ShapeType() == TopAbs_FACE)
        return BRepTools::OuterWire(TopoDS::Face(s));
    TopExp_Explorer ex(s, TopAbs_WIRE);
    if (!ex.More())
        throw Standard_Failure("the sweep has no end");
    return TopoDS::Wire(ex.Current());
}

// A solid swept along one run of a path with corners, made to meet its
// neighbours in the mitre planes of the corners: carried on straight past
// each corner (its end section pushed out) and cut back to the plane that
// halves the corner. `reach` is how far the profile gets from the path.
static TopoDS_Shape mitre_ends(TopoDS_Shape s, const TopoDS_Wire &first, const TopoDS_Wire &last, const PathRun &r,
                               const gp_Vec *before, const gp_Vec *after, double reach)
{
    auto cut_at = [&](const TopoDS_Wire &section, const gp_Pnt &c, const gp_Vec &out, const gp_Vec &other) {
        // out: the way past the corner, along this run; other: the next run's way from the corner
        const gp_Vec m = out + other;   // the mitre plane's normal, towards the side cut away
        if (m.Magnitude() < 1e-9)
            return;
        const double half = out.Angle(other) / 2;   // half the turn
        if (half < 1e-6)
            return;   // no corner: the runs meet across the path already
        const double ext = reach * std::tan(std::min(half, 1.55)) * 1.05 + 1e-3;
        const double w = 4 * (reach + ext) + 1;
        TopoDS_Face f = BRepBuilderAPI_MakeFace(section, Standard_True).Face();
        TopoDS_Shape prism = BRepPrimAPI_MakePrism(f, out.Normalized() * ext).Shape();
        s = BRepAlgoAPI_Fuse(s, prism).Shape();
        gp_Ax2 ax(c, gp_Dir(m));
        gp_Pnt o = c.Translated(-w * gp_Vec(ax.XDirection()) - w * gp_Vec(ax.YDirection()));
        TopoDS_Shape box = BRepPrimAPI_MakeBox(gp_Ax2(o, gp_Dir(m), ax.XDirection()), 2 * w, 2 * w, w).Shape();
        s = BRepAlgoAPI_Cut(s, box).Shape();
    };
    if (before != nullptr)
        cut_at(first, r.start, -r.t0, -*before);
    if (after != nullptr)
        cut_at(last, r.end, r.t1, *after);
    return s;
}

// The sweep, its roll about the path decided one way: frenet (the
// curvature), `angles` (n of them evenly along it, turned from where it
// would be), `up` (its +Y kept towards that direction) or `guide` (its +Y
// towards that curve); else it turns as little as it can.
hc_shape *hc_sweep_ex(const hc_shape *profile, const hc_shape *path, int frenet, const double *angles, int nAngles,
                      const double up_[3], const hc_shape *guide_)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        TopoDS_Wire spine = single_wire(path->shape);
        bool closingCorner = false;
        std::vector<PathRun> runs = smooth_runs(spine, closingCorner);
        BRepAdaptor_CompCurve c(spine);
        gp_Pnt p;
        gp_Vec t;
        c.D1(c.FirstParameter(), p, t);
        gp_Dir tz(runs.front().t0);
        const gp_Vec fixedUp(up_[0], up_[1], up_[2]);
        const bool upMode = fixedUp.Magnitude() > 1e-12;
        // the profile is drawn on XY around the origin: carry it to the start of
        // the path, normal to it, its +Y as close to world +Z as possible (or
        // to `up`, or towards the guide)
        gp_Vec up(0, 0, 1);
        if (std::abs(gp_Dir(up).Dot(tz)) > 0.999)
            up = gp_Vec(0, 1, 0);
        TopoDS_Wire userGuide;
        if (guide_ != nullptr)
            userGuide = single_wire(guide_->shape);
        BRepAdaptor_CompCurve g;
        if (!userGuide.IsNull())
            g.Initialize(userGuide, Standard_False);
        // the way +Y should point at fraction f of the path: up, or the guide's point as far along it
        auto towards = [&](double f, const gp_Pnt &q, const gp_Vec &) -> gp_Vec {
            if (upMode)
                return fixedUp;
            gp_Pnt on;
            GCPnts_AbscissaPoint ap(g, f * GCPnts_AbscissaPoint::Length(g), g.FirstParameter());
            on = g.Value(ap.Parameter());
            return gp_Vec(q, on);
        };
        if (upMode || guide_ != nullptr) {
            up = upMode ? fixedUp : towards(0, p, gp_Vec(tz));
            if ((up - gp_Vec(tz) * up.Dot(gp_Vec(tz))).Magnitude() < 1e-9)
                throw Standard_Failure(upMode ? "the path starts along up: there the profile's +Y cannot point up"
                                              : up.Magnitude() < 1e-9
                                                  ? "the guide starts on the path itself: it must run beside it, a "
                                                    "little away from it, where the profile's +Y should point"
                                                  : "the guide starts straight ahead of the path (or behind it): it "
                                                    "must run beside it, where the profile's +Y should point");
        }
        if (upMode) {
            // the path must never run along up (said here with where along the whole path; the
            // roll is worked out a stretch at a time)
            const gp_Dir u(fixedUp);
            GCPnts_UniformAbscissa ua(c, 257);
            for (int i = 1; ua.IsDone() && i <= ua.NbPoints(); i++) {
                gp_Pnt q;
                gp_Vec d;
                c.D1(ua.Parameter(i), q, d);
                if (d.Magnitude() > 1e-12 && d.Normalized().Crossed(gp_Vec(u)).Magnitude() < 1e-6)
                    throw Standard_Failure(("at " + std::to_string((int)std::lround(100.0 * (i - 1) / (ua.NbPoints() - 1))) +
                                            "% of its way the path runs along up: there the profile's +Y cannot point "
                                            "up; give a guide instead").c_str());
            }
            for (const auto &r : runs)
                if (r.t0.Crossed(gp_Vec(u)).Magnitude() < 1e-6 || r.t1.Crossed(gp_Vec(u)).Magnitude() < 1e-6)
                    throw Standard_Failure(("at " + point_text(r.t0.Crossed(gp_Vec(u)).Magnitude() < 1e-6 ? r.start
                                                                                                         : r.end) +
                                            " the path runs along up: there the profile's +Y cannot point up; give a "
                                            "guide instead").c_str());
        }
        gp_Dir y(up - gp_Vec(tz) * up.Dot(gp_Vec(tz)));
        gp_Dir x = y.Crossed(tz);
        gp_Trsf place;
        place.SetTransformation(gp_Ax3(runs.front().start, tz, x), gp_Ax3(gp::XOY()));
        TopoDS_Shape moved = BRepBuilderAPI_Transform(profile->shape, place, true).Shape();
        // a curve, not an area: swept, it makes a surface
        const bool open = faces_of(moved).empty();
        ProfileLoops loops;
        if (open)
            loops.outer = single_wire(moved);
        else
            loops = loops_of(moved);
        Bnd_Box bb;
        BRepBndLib::Add(moved, bb);
        const double radius = std::max(1.0, std::sqrt(bb.SquareExtent()));
        auto solid_of = [&](BRepOffsetAPI_MakePipeShell &mk) {
            mk.Build();
            if (!mk.IsDone())
                throw Standard_Failure("it could not be built along this path");
            if (open)
                return mk.Shape();
            mk.MakeSolid();
            TopoDS_Shape r = mk.Shape();
            GProp_GProps gp;
            BRepGProp::VolumeProperties(r, gp);
            if (gp.Mass() < 0)
                r.Reverse();
            return r;
        };
        // the roll given (twist) or towards the guide, along one run of the path from
        // `ref` (the reference carried along, not turned): made by a guide winding round it.
        // `already` is how far the profile has turned from ref where the run starts: the
        // roll goes from there to what is asked, along the run
        // along a helix the roll is counted from its axis (as a sweep without one keeps it)
        gp_Vec axis;
        const bool helical = runs.size() == 1 && !closingCorner && helix_axis(spine, axis);
        auto rolls_along = [&](const PathRun &r, const gp_Vec &ref, double already) {
            std::vector<double> rk;
            const int m = 257;
            if (upMode || guide_ != nullptr) {
                try {
                    rk = roll_towards(r.wire, gp_Dir(ref), m, [&](double f, const gp_Pnt &q, const gp_Vec &d) {
                        return towards(r.from + (r.to - r.from) * f, q, d);
                    }, helical ? &axis : nullptr);
                } catch (Standard_Failure &e) {
                    const std::string where = e.GetMessageString();
                    if (where.rfind("at ", 0) != 0)
                        throw;
                    throw Standard_Failure((upMode ? where + " the path runs along up: there the profile's +Y cannot "
                                                             "point up; give a guide instead"
                                                   : where + " the guide lies straight ahead of the path: it must run "
                                                             "beside it").c_str());
                }
            } else if (nAngles > 0)
                for (int j = 0; j < m; j++)
                    rk.push_back(roll_at(angles, nAngles, r.from + (r.to - r.from) * j / (m - 1.0)) - angles[0]);
            else
                rk.assign(m, 0.0);   // along a helix, no roll from its axis
            const double off = already - rk[0];
            for (int j = 0; j < m; j++)
                rk[j] += off * (1 - j / (m - 1.0));
            return rk;
        };
        // along a helix, even without a roll asked, the profile keeps to its axis: the least
        // turning (OpenCascade's) drifts from it over many turns, a circle comes out off size or fails
        const bool rolled = nAngles > 0 || guide_ != nullptr || upMode || (helical && !frenet);
        if (rolled) {
            // a closed path, and one turning many times (a long helix), swept a stretch at a
            // time: a winding guide does not close on itself, and one too long fails
            std::vector<PathRun> cut;
            std::function<void(const PathRun &, bool)> add = [&](const PathRun &r, bool loop) {
                if (loop || turns_of(r.wire) > 8) {
                    auto two = halves(r);
                    if (two.size() == 2) {
                        add(two[0], false);
                        add(two[1], false);
                        return;
                    }
                }
                cut.push_back(r);
            };
            for (const auto &r : runs)
                add(r, runs.size() == 1 && r.start.Distance(r.end) < 1e-7);
            runs = cut;
        }
        if (!rolled || (runs.size() == 1 && !closingCorner)) {
            TopoDS_Wire guide;
            if (rolled) {
                const auto rk = rolls_along(runs.front(), gp_Vec(x), 0);
                guide = twist_guide(spine, x, rk.data(), (int)rk.size(), radius, helical ? &axis : nullptr);
            }
            auto pipe = [&](const TopoDS_Wire &w) {
                BRepOffsetAPI_MakePipeShell mk(spine);
                // the roll's guide winds round the path, in the planes across it
                if (!guide.IsNull())
                    mk.SetMode(guide, Standard_False);
                else if (frenet)
                    mk.SetMode(Standard_True);
                mk.SetTransitionMode(BRepBuilderAPI_RightCorner);   // mitred corners on polylines
                mk.Add(w);
                return solid_of(mk);
            };
            TopoDS_Shape result = pipe(loops.outer);
            for (auto &h : loops.holes)
                result = BRepAlgoAPI_Cut(result, pipe(h)).Shape();
            return primitive(result);
        }
        // a roll along a path with sharp corners: a winding guide cannot turn a corner,
        // so each run between them is swept on its own, the profile carried across each
        // corner as a mitre does, and the runs joined in the mitre planes
        if (open)
            throw Standard_Failure("a curve cannot be swept with a roll along a path with sharp corners: round "
                                   "them (path(…, bend: 2.mm))");
        double reach = 0;
        if (!bb.IsVoid()) {
            double x0, y0, z0, x1, y1, z1;
            bb.Get(x0, y0, z0, x1, y1, z1);
            for (int i = 0; i < 8; i++)
                reach = std::max(reach, runs.front().start.Distance(
                                            gp_Pnt(i & 1 ? x1 : x0, i & 2 ? y1 : y0, i & 4 ? z1 : z0)));
        }
        std::vector<TopoDS_Wire> sections{loops.outer};
        for (auto &h : loops.holes)
            sections.push_back(h);
        gp_Vec ref(x);
        double already = 0;
        TopoDS_Shape result;
        for (size_t k = 0; k < runs.size(); k++) {
            const PathRun &r = runs[k];
            const auto rk = rolls_along(r, ref, already);
            const TopoDS_Wire guide =
                twist_guide(r.wire, gp_Dir(ref), rk.data(), (int)rk.size(), radius, helical ? &axis : nullptr);
            const gp_Vec *before = k > 0 ? &runs[k - 1].t1 : closingCorner ? &runs.back().t1 : nullptr;
            const gp_Vec *after = k + 1 < runs.size() ? &runs[k + 1].t0 : closingCorner ? &runs.front().t0 : nullptr;
            TopoDS_Shape body;
            std::vector<TopoDS_Wire> ends;
            for (size_t i = 0; i < sections.size(); i++) {
                BRepOffsetAPI_MakePipeShell mk(r.wire);
                mk.SetMode(guide, Standard_False);
                mk.Add(sections[i]);
                TopoDS_Shape s = solid_of(mk);
                const TopoDS_Wire last = wire_in(mk.LastShape());
                ends.push_back(last);
                s = mitre_ends(s, sections[i], last, r, before, after, reach);
                body = i == 0 ? s : BRepAlgoAPI_Cut(body, s).Shape();
            }
            result = result.IsNull() ? body : BRepAlgoAPI_Fuse(result, body).Shape();
            if (solid_volume(result) <= 0)
                throw Standard_Failure("its stretches could not be joined: does the sweep run into itself (turns "
                                       "of a helix touching, a profile wider than the pitch)?");
            if (k + 1 < runs.size()) {
                // the next run starts from this one's end sections, turned across the corner
                const gp_Trsf turn = across_corner(r.end, r.t1, runs[k + 1].t0);
                sections.clear();
                for (auto &e : ends)
                    sections.push_back(TopoDS::Wire(BRepBuilderAPI_Transform(e, turn, true).Shape()));
                ref = carry_along(r.wire, ref, helical ? &axis : nullptr).Transformed(turn);
                already = rk.back();
            }
        }
        ShapeUpgrade_UnifySameDomain unify(result, Standard_True, Standard_True, Standard_False);
        unify.Build();
        return primitive(unify.Shape());
    });
}

hc_shape *hc_loft(const hc_shape *const *profiles, int n, int ruled)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<ProfileLoops> ls;
        for (int i = 0; i < n; i++)
            ls.push_back(loops_of(profiles[i]->shape));
        std::vector<TopoDS_Wire> outer;
        for (auto &l : ls)
            outer.push_back(l.outer);
        TopoDS_Shape result = solid_through(outer, ruled);
        // holes are lofted too when every profile has the same number of them
        size_t holes = ls[0].holes.size();
        bool same = true;
        for (auto &l : ls)
            same = same && l.holes.size() == holes;
        if (holes && !same)
            throw Standard_Failure("every profile of a loft with holes needs the same number of holes");
        for (size_t h = 0; h < holes; h++) {
            std::vector<TopoDS_Wire> sec;
            for (auto &l : ls)
                sec.push_back(l.holes[h]);
            result = BRepAlgoAPI_Cut(result, solid_through(sec, ruled)).Shape();
        }
        return primitive(result);
    });
}

// A surface through open paths (or closed ones, not filled), in order.
hc_shape *hc_loft_open(const hc_shape *const *paths, int n, int ruled)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<TopoDS_Wire> wires;
        int closed = 0;
        for (int i = 0; i < n; i++) {
            wires.push_back(single_wire(paths[i]->shape));
            closed += BRep_Tool::IsClosed(wires.back()) ? 1 : 0;
        }
        if (closed != 0 && closed != n)
            throw Standard_Failure("a surface goes through open paths or through closed ones, not both");
        // closed paths matched as the profiles of a loft are (the same number of edges, starts and
        // seams lined up): a square and a circle otherwise give a twisted, partial surface
        if (closed)
            wires = align_seams(same_edge_count(align_starts(wires)));
        BRepOffsetAPI_ThruSections ts(Standard_False, ruled ? Standard_True : Standard_False);
        for (auto &w : wires)
            ts.AddWire(w);
        ts.CheckCompatibility(closed ? Standard_True : Standard_False);
        ts.Build();
        if (!ts.IsDone())
            throw Standard_Failure("the surface through these paths failed (do they run the same way?)");
        return primitive(ts.Shape());
    });
}

// A surface lofted through closed flat paths, made a wall `t` thick another way
// than thicken's: each path offset in its own plane (outwards for t > 0), the
// solid lofts through the two sets of paths, one less the other. The wall is
// t thick across the paths' planes (thinner where it leans). For sheets
// thicken cannot offset cleanly (sharp edges meeting smooth ones).
hc_shape *hc_thicken_loft(const hc_shape *const *paths, int n, int ruled, double t)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<TopoDS_Wire> given, moved;
        for (int i = 0; i < n; i++) {
            const TopoDS_Wire w = single_wire(paths[i]->shape);
            if (!BRep_Tool::IsClosed(w))
                throw Standard_Failure("the paths are not all closed");
            BRepBuilderAPI_MakeFace mf(w, Standard_True);
            if (!mf.IsDone())
                throw Standard_Failure("a path does not lie in one plane");
            const TopoDS_Face f = mf.Face();
            BRepOffsetAPI_MakeOffset off(f, GeomAbs_Intersection);
            off.Perform(t);
            if (!off.IsDone())
                throw Standard_Failure("a path could not be offset by the thickness");
            TopoDS_Wire ow;
            for (TopExp_Explorer ex(off.Shape(), TopAbs_WIRE); ex.More(); ex.Next()) {
                ow = TopoDS::Wire(ex.Current());
                break;
            }
            if (ow.IsNull())
                throw Standard_Failure("a path offset by the thickness vanished");
            // outwards for t > 0: the offset face must be larger
            GProp_GProps a0, a1;
            BRepGProp::SurfaceProperties(f, a0);
            BRepGProp::SurfaceProperties(BRepBuilderAPI_MakeFace(ow, Standard_True).Face(), a1);
            if ((a1.Mass() > a0.Mass()) != (t > 0)) {
                BRepOffsetAPI_MakeOffset back(f, GeomAbs_Intersection);
                back.Perform(-t);
                ow = TopoDS_Wire();
                for (TopExp_Explorer ex(back.Shape(), TopAbs_WIRE); ex.More(); ex.Next()) {
                    ow = TopoDS::Wire(ex.Current());
                    break;
                }
                if (ow.IsNull())
                    throw Standard_Failure("a path offset by the thickness vanished");
            }
            given.push_back(w);
            moved.push_back(ow);
        }
        // the two walls as open lofts, and a flat ring at each end between them, sewn into a
        // solid: no boolean between two lofts that share their end planes (OpenCascade gets those
        // wrong)
        auto open = [&](std::vector<TopoDS_Wire> ws) {
            ws = align_seams(same_edge_count(align_starts(ws)));
            BRepOffsetAPI_ThruSections ts(Standard_False, ruled ? Standard_True : Standard_False);
            for (auto &w : ws)
                ts.AddWire(w);
            ts.CheckCompatibility(Standard_True);
            ts.Build();
            if (!ts.IsDone())
                throw Standard_Failure("the wall from the paths could not be lofted");
            return std::make_pair(ts.Shape(), ws);
        };
        auto in = open(given), out = open(moved);
        BRepBuilderAPI_Sewing sew(1e-4);
        sew.Add(in.first);
        sew.Add(out.first);
        for (size_t end : {size_t(0), given.size() - 1}) {
            BRepBuilderAPI_MakeFace ring(t > 0 ? out.second[end] : in.second[end], Standard_True);
            const TopoDS_Wire hole = t > 0 ? in.second[end] : out.second[end];
            ring.Add(TopoDS::Wire(hole.Reversed()));
            if (!ring.IsDone())
                throw Standard_Failure("the wall's ends could not be closed");
            ShapeFix_Face fix(ring.Face());
            fix.FixOrientation();
            fix.Perform();
            sew.Add(fix.Face());
        }
        sew.Perform();
        if (sew.NbFreeEdges() > 0)
            throw Standard_Failure("the wall from the paths does not close");
        BRepBuilderAPI_MakeSolid ms;
        for (TopExp_Explorer ex(sew.SewedShape(), TopAbs_SHELL); ex.More(); ex.Next())
            ms.Add(TopoDS::Shell(ex.Current()));
        ShapeFix_Solid fs(ms.Solid());
        fs.Perform();
        TopoDS_Shape r = fs.Solid();
        GProp_GProps g;
        BRepGProp::VolumeProperties(r, g);
        if (g.Mass() < 0)
            r.Reverse();
        if (!BRepCheck_Analyzer(r).IsValid() || solid_volume(r) < 1e-9)
            throw Standard_Failure("the wall from the paths came out wrong");
        return primitive(r);
    });
}

// The solids of `s` cut by the surface (or solid) `tool`: every piece.
hc_shape *hc_split_by(const hc_shape *s, const hc_shape *tool)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        BRepAlgoAPI_Splitter sp;
        TopTools_ListOfShape args, tools;
        args.Append(s->shape);
        tools.Append(tool->shape);
        sp.SetArguments(args);
        sp.SetTools(tools);
        sp.Build();
        if (!sp.IsDone())
            throw Standard_Failure("the cut by the surface failed");
        BRep_Builder b;
        TopoDS_Compound c;
        b.MakeCompound(c);
        int count = 0;
        double pieces = 0;
        for (TopExp_Explorer ex(sp.Shape(), TopAbs_SOLID); ex.More(); ex.Next(), count++) {
            b.Add(c, ex.Current());
            pieces += solid_volume(ex.Current());
        }
        if (count == 0)
            throw Standard_Failure("the cut left no solid");
        // a tool that misses the solid, or ends inside it, leaves it whole: or, worse, drops the
        // part it half cut (OpenCascade gives no error for either)
        const double whole = solid_volume(s->shape);
        if (std::abs(pieces - whole) > 1e-6 * whole + 1e-9)
            throw Standard_Failure("the cut lost material: the surface ends inside the solid; it must reach across it, "
                                   "from one side out to the other");
        int before = 0;
        for (TopExp_Explorer ex(s->shape, TopAbs_SOLID); ex.More(); ex.Next())
            before++;
        if (count <= before)
            throw Standard_Failure("the surface does not cut the solid apart: it misses it, or ends inside it; "
                                   "it must reach across it, from one side out to the other");
        // each face from the one it was cut from: the solid's, or the surface's (faces.from(surface))
        history_record(sp, {&s->shape, &tool->shape}, c);
        return wrap(c);
    });
}

// The point of `s` nearest to p and the normal of the face there (as the
// face is oriented); 0 when there is no face.
int hc_normal_at(const hc_shape *s, const double p[3], double out[6])
{
    return guarded<>(0, [&]() -> int {
        // the nearest face (the nearest point may be on an edge: a face's side)
        const TopoDS_Vertex at = BRepBuilderAPI_MakeVertex(gp_Pnt(p[0], p[1], p[2])).Vertex();
        TopoDS_Face best;
        gp_Pnt near;
        double dist = Precision::Infinite();
        for (TopExp_Explorer ex(s->shape, TopAbs_FACE); ex.More(); ex.Next()) {
            BRepExtrema_DistShapeShape d(at, ex.Current());
            if (d.IsDone() && d.NbSolution() > 0 && d.Value() < dist) {
                dist = d.Value();
                best = TopoDS::Face(ex.Current());
                near = d.PointOnShape2(1);
            }
        }
        if (best.IsNull())
            return 0;
        Handle(Geom_Surface) surf = BRep_Tool::Surface(best);
        ShapeAnalysis_Surface sas(surf);
        const gp_Pnt2d uv = sas.ValueOfUV(near, 1e-7);
        gp_Pnt q;
        gp_Vec du, dv;
        surf->D1(uv.X(), uv.Y(), q, du, dv);
        gp_Vec n = du.Crossed(dv);
        if (n.Magnitude() < 1e-12)
            return 0;
        n.Normalize();
        if (best.Orientation() == TopAbs_REVERSED)
            n.Reverse();
        const double r[6] = {near.X(), near.Y(), near.Z(), n.X(), n.Y(), n.Z()};
        std::copy(r, r + 6, out);
        return 1;
    });
}

// A surface made a solid `t` thick, on the side its faces' normals point
// (t < 0: the other side).
hc_shape *hc_thicken(const hc_shape *s, double t)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        // faces meeting at a sharp edge (a square's sides) want their offsets joined by
        // intersecting them: the simple way offsets each on its own and leaves a broken solid
        // there, which then crashes the mesher; smooth sheets take the simple way, quicker
        TopoDS_Shape r;
        for (GeomAbs_JoinType join : {GeomAbs_Intersection, GeomAbs_Arc}) {
            try {
                BRepOffset_MakeOffset mo;
                mo.Initialize(s->shape, t, 1e-6, BRepOffset_Skin, Standard_False, Standard_False, join, Standard_True);
                mo.MakeOffsetShape();
                if (mo.IsDone() && BRepCheck_Analyzer(mo.Shape()).IsValid() && solid_volume(mo.Shape()) > 0) {
                    r = mo.Shape();
                    break;
                }
            } catch (const Standard_Failure &) {
            }
        }
        if (r.IsNull()) {
            BRepOffsetAPI_MakeThickSolid mk;
            mk.MakeThickSolidBySimple(s->shape, t);
            mk.Build();
            if (!mk.IsDone() || !BRepCheck_Analyzer(mk.Shape()).IsValid())
                throw Standard_Failure("could not thicken the surface (thicker than its tightest bend, or folding "
                                       "over a sharp edge?)");
            r = mk.Shape();
            // where the joined ways failed (sharp edges meeting smooth ones), offset face by face
            // the sheet leaves faces OpenCascade calls valid but meshes wrong, and its mesh
            // workaround can crash or hang on them: refused here
            Bnd_Box box;
            BRepBndLib::Add(r, box);
            BRepMesh_IncrementalMesh(r, 1e-3 * std::sqrt(box.SquareExtent()), false, 0.3, true);
            for (TopExp_Explorer ex(r, TopAbs_FACE); ex.More(); ex.Next())
                if (meshed_badly(TopoDS::Face(ex.Current())))
                    throw Standard_Failure("could not thicken the surface cleanly where its sharp edges meet smooth "
                                           "ones: loft or sweep through smoother paths (rounded corners), or "
                                           "make the solid first and shell it");
        }
        // it may come out inside out
        GProp_GProps g;
        BRepGProp::VolumeProperties(r, g);
        if (g.Mass() < 0)
            r.Reverse();
        return primitive(r);
    });
}

// Surfaces sewn along their shared edges into one solid; an error when they
// leave a gap (free_edges: how many edges have a side open).
hc_shape *hc_sew(const hc_shape *const *parts, int n, double tolerance, int *free_edges)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        BRepBuilderAPI_Sewing sew(tolerance);
        for (int i = 0; i < n; i++)
            sew.Add(parts[i]->shape);
        sew.Perform();
        TopoDS_Shape sewn = sew.SewedShape();
        *free_edges = sew.NbFreeEdges();
        if (sew.NbFreeEdges() > 0)
            throw Standard_Failure(("the surfaces do not close: " + std::to_string(sew.NbFreeEdges()) +
                                    " edges are open on one side").c_str());
        BRepBuilderAPI_MakeSolid ms;
        int shells = 0;
        for (TopExp_Explorer ex(sewn, TopAbs_SHELL); ex.More(); ex.Next(), shells++)
            ms.Add(TopoDS::Shell(ex.Current()));
        if (shells == 0)
            throw Standard_Failure("the surfaces sew into nothing");
        ShapeFix_Solid fix(ms.Solid());
        fix.Perform();
        TopoDS_Shape r = fix.Solid();
        GProp_GProps g;
        BRepGProp::VolumeProperties(r, g);
        if (g.Mass() < 0)
            r.Reverse();
        return primitive(r);
    });
}

} // extern "C"

// ---------------------------------------------------------------- drawings

#include <HLRBRep_Algo.hxx>
#include <HLRBRep_HLRToShape.hxx>
#include <HLRAlgo_Projector.hxx>
#include <GCPnts_QuasiUniformDeflection.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <cstdlib>

static void polyline_of(const TopoDS_Edge &e, double deflection, std::vector<gp_Pnt> &pts)
{
    BRepAdaptor_Curve c(e);
    GCPnts_QuasiUniformDeflection d(c, deflection);
    if (d.IsDone() && d.NbPoints() >= 2) {
        for (int i = 1; i <= d.NbPoints(); i++)
            pts.push_back(d.Value(i));
    } else {
        pts.push_back(c.Value(c.FirstParameter()));
        pts.push_back(c.Value(c.LastParameter()));
    }
}

static double *copy_out(const std::vector<double> &v)
{
    double *p = (double *)std::malloc(sizeof(double) * (v.size() ? v.size() : 1));
    for (size_t i = 0; i < v.size(); i++)
        p[i] = v[i];
    return p;
}

extern "C" {

void hc_free(void *p) { std::free(p); }

int hc_hlr(const hc_shape *s, double dx, double dy, double dz, double ux, double uy, double uz, double deflection,
           double **out)
{
    return guarded<>(-1, [&]() -> int {
        gp_Dir dir(dx, dy, dz), up(ux, uy, uz);
        gp_Dir xdir = up.Crossed(dir);
        HLRAlgo_Projector projector(gp_Ax2(gp_Pnt(0, 0, 0), dir, xdir));
        Handle(HLRBRep_Algo) algo = new HLRBRep_Algo();
        algo->Add(s->shape);
        algo->Projector(projector);
        algo->Update();
        algo->Hide();
        HLRBRep_HLRToShape ex(algo);
        std::vector<double> v;
        auto add = [&](const TopoDS_Shape &shape, int kind) {
            if (shape.IsNull())
                return;
            BRepLib::BuildCurves3d(shape);
            for (TopExp_Explorer e(shape, TopAbs_EDGE); e.More(); e.Next()) {
                std::vector<gp_Pnt> pts;
                polyline_of(TopoDS::Edge(e.Current()), deflection, pts);
                for (size_t i = 0; i + 1 < pts.size(); i++) {
                    double seg[5] = {pts[i].X(), pts[i].Y(), pts[i + 1].X(), pts[i + 1].Y(), (double)kind};
                    v.insert(v.end(), seg, seg + 5);
                }
            }
        };
        add(ex.VCompound(), 0);
        add(ex.Rg1LineVCompound(), 1);
        add(ex.OutLineVCompound(), 2);
        add(ex.HCompound(), 3);
        add(ex.OutLineHCompound(), 3);
        *out = copy_out(v);
        return (int)(v.size() / 5);
    });
}

int hc_face_loops(const hc_shape *s, int face, double deflection, double **out)
{
    return guarded<>(-1, [&]() -> int {
        TopTools_IndexedMapOfShape faces;
        TopExp::MapShapes(s->shape, TopAbs_FACE, faces);
        if (face < 0 || face >= faces.Extent()) {
            set_error("face index out of range");
            return -1;
        }
        const TopoDS_Face &f = TopoDS::Face(faces(face + 1));
        std::vector<double> v;
        int loops = 0;
        for (TopExp_Explorer w(f, TopAbs_WIRE); w.More(); w.Next()) {
            std::vector<gp_Pnt> pts;
            for (BRepTools_WireExplorer e(TopoDS::Wire(w.Current()), f); e.More(); e.Next()) {
                std::vector<gp_Pnt> ep;
                polyline_of(e.Current(), deflection, ep);
                if (e.Current().Orientation() == TopAbs_REVERSED)
                    std::reverse(ep.begin(), ep.end());
                for (size_t i = pts.empty() ? 0 : 1; i < ep.size(); i++)
                    pts.push_back(ep[i]);
            }
            v.push_back((double)pts.size());
            for (auto &p : pts) {
                v.push_back(p.X());
                v.push_back(p.Y());
                v.push_back(p.Z());
            }
            loops++;
        }
        *out = copy_out(v);
        return loops;
    });
}

} // extern "C"
