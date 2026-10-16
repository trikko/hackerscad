// OpenCascade implementation of shim.h. Keep this file thin: anything that
// is not a direct kernel call belongs on the D side.
#include "shim.h"

#include <string>
#include <exception>

#include <Standard_Failure.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <TopoDS.hxx>
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
#include <TCollection_HAsciiString.hxx>
#include <gp_Trsf.hxx>
#include <gp_Ax1.hxx>
#include <gp_Ax2.hxx>
#include <gp_Pln.hxx>
#include <map>
#include <mutex>
#include <vector>
#include <BRepTools_WireExplorer.hxx>
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
#include <cmath>
#include <LocOpe_DPrism.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <StdPrs_BRepFont.hxx>
#include <StdPrs_BRepTextBuilder.hxx>
#include <gp_Circ.hxx>
#include <TopoDS_Compound.hxx>
#include <BRep_Builder.hxx>
#include <cstring>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <ShapeFix_Solid.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <ShapeUpgrade_FaceDivideArea.hxx>
#include <ShapeBuild_ReShape.hxx>
#include <BRepTools_History.hxx>
#include <memory>
#include <TopoDS_Shell.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <Precision.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>

struct hc_shape {
    TopoDS_Shape shape;
    // sub-shape maps by kind, built on first use: indexed queries
    // (hc_face_info, hc_edge_info, …) would otherwise rebuild them per call
    mutable std::mutex lock;
    mutable std::map<int, TopTools_IndexedMapOfShape> maps;
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
static thread_local std::vector<Origin> g_history;

// Every face of `result` is new: primitives and unknown operations.
static void history_new(const TopoDS_Shape &result)
{
    TopTools_IndexedMapOfShape res;
    TopExp::MapShapes(result, TopAbs_FACE, res);
    g_history.assign(res.Extent(), Origin{-1, -1});
}

// Maps result faces back to the operand faces they were modified from (or
// kept unchanged); faces generated by the operation stay -1.
static void history_record(BRepBuilderAPI_MakeShape &mk, std::initializer_list<const TopoDS_Shape *> inputs,
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
                        g_history[j - 1] = Origin{k, i - 1};
                }
                continue;
            }
            for (TopTools_ListOfShape::Iterator it(mods); it.More(); it.Next()) {
                int j = res.FindIndex(it.Value());
                if (j > 0 && g_history[j - 1].input < 0)
                    g_history[j - 1] = Origin{k, i - 1};
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

static hc_shape *primitive(const TopoDS_Shape &s)
{
    history_new(s);
    return wrap(s);
}

extern "C" {

const char *hc_last_error(void) { return g_error.c_str(); }

// the WORKAROUNDs below that a test can turn off (hc_workaround)
static std::atomic<bool> g_workarounds[4] = {{true}, {true}, {true}, {true}};
static bool workaround(int which) { return g_workarounds[which].load(); }

void hc_workaround(int which, int on)
{
    if (which >= 0 && which < 4)
        g_workarounds[which] = on != 0;
}

int hc_history_size(void) { return (int)g_history.size(); }

void hc_history_get(int *input, int *index)
{
    for (size_t i = 0; i < g_history.size(); i++) {
        input[i] = g_history[i].input;
        index[i] = g_history[i].index;
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

// Profiles face +Z whatever the winding of their outline: faces pointing
// opposite ways do not merge in 2D booleans.
static TopoDS_Face upward(TopoDS_Face f)
{
    BRepAdaptor_Surface surf(f);
    if (surf.GetType() != GeomAbs_Plane)
        return f;
    gp_Dir n = surf.Plane().Axis().Direction();
    if (f.Orientation() == TopAbs_REVERSED)
        n.Reverse();
    if (n.Z() < 0)
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
hc_shape *hc_spline_profile(const double *xy, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (n < 3) {
            set_error("a smooth outline needs at least 3 points");
            return nullptr;
        }
        Handle(TColgp_HArray1OfPnt) pts = new TColgp_HArray1OfPnt(1, n);
        for (int i = 0; i < n; i++)
            pts->SetValue(i + 1, gp_Pnt(xy[2 * i], xy[2 * i + 1], 0));
        GeomAPI_Interpolate interp(pts, Standard_True, 1e-7);
        interp.Perform();
        if (!interp.IsDone()) {
            set_error("cannot fit a smooth outline through these points (repeated points?)");
            return nullptr;
        }
        BRepBuilderAPI_MakeWire wire(BRepBuilderAPI_MakeEdge(interp.Curve()).Edge());
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

hc_shape *hc_text(const char *utf8, double size, const char *font)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        // loading a font takes tens of ms, and it caches the outlines of its
        // glyphs: keep one per font and size (per thread: evaluations run on
        // more than one)
        thread_local std::map<std::pair<std::string, double>, Handle(StdPrs_BRepFont)> fonts;
        Handle(StdPrs_BRepFont) &f = fonts[std::make_pair(std::string(font), size)];
        if (f.IsNull()) {
            Handle(StdPrs_BRepFont) loaded = new StdPrs_BRepFont();
            bool ok = std::strchr(font, '/') ? loaded->Init(NCollection_String(font), size, 0)
                                             : loaded->FindAndInit(TCollection_AsciiString(font), Font_FontAspect_Regular, size);
            if (!ok) {
                set_error("font not found");
                return nullptr;
            }
            f = loaded;
        }
        StdPrs_BRepTextBuilder builder;
        TopoDS_Shape shape = builder.Perform(*f, NCollection_String(utf8));
        if (shape.IsNull() || faces_of(shape).empty()) {
            set_error("the text produced no outline");
            return nullptr;
        }
        return primitive(shape);
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
// Minkowski sum with a ball of radius d, exactly.
hc_shape *hc_offset_solid(const hc_shape *s, double d)
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
        BRepOffsetAPI_MakeOffsetShape off;
        off.PerformByJoin(unify.Shape(), d, 1e-6, BRepOffset_Skin, Standard_False, Standard_False, GeomAbs_Arc);
        if (!off.IsDone()) {
            set_error(d < 0 ? "the solid cannot shrink that much (would it vanish?)"
                            : "the kernel could not grow the solid by that much");
            return nullptr;
        }
        TopoDS_Shape r = off.Shape();
        if (!TopExp_Explorer(r, TopAbs_SOLID).More()) {
            BRepBuilderAPI_MakeSolid ms;
            for (TopExp_Explorer e(r, TopAbs_SHELL); e.More(); e.Next())
                ms.Add(TopoDS::Shell(e.Current()));
            r = ms.Solid();
        }
        GProp_GProps p;
        BRepGProp::VolumeProperties(r, p);
        // WORKAROUND (OpenCascade 7.9.3, BRepOffsetAPI_MakeOffsetShape): it
        // can return a broken solid instead of failing. No case known today
        // (no test or example reaches it): it stays as a guard
        if (r.IsNull() || p.Mass() <= 0 || !BRepCheck_Analyzer(r).IsValid()) {
            set_error("offset gave a broken solid: try a smaller distance");
            return nullptr;
        }
        history_new(r);
        return wrap(r);
    });
}

hc_shape *hc_profile_offset(const hc_shape *s, double d)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<TopoDS_Shape> out;
        for (const TopoDS_Face &face : faces_of(s->shape)) {
            BRepOffsetAPI_MakeOffset mk(face, GeomAbs_Arc);
            mk.Perform(d);
            if (!mk.IsDone()) {
                set_error("offset failed (the profile would vanish?)");
                return nullptr;
            }
            // the wires it gives: outlines, holes, and islands where a narrow
            // part of the face closed up, told apart by how they nest
            std::vector<TopoDS_Wire> loops;
            for (TopExp_Explorer ex(mk.Shape(), TopAbs_WIRE); ex.More(); ex.Next())
                if (BRepBuilderAPI_MakeFace(TopoDS::Wire(ex.Current()), Standard_True).IsDone())
                    loops.push_back(TopoDS::Wire(ex.Current()));
            if (loops.empty()) {
                set_error("offset left nothing");
                return nullptr;
            }
            out.push_back(faces_from_loops(loops));
        }
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

hc_shape *hc_extrude(const hc_shape *s, double height, double taper_rad)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        if (taper_rad == 0)
            return primitive(BRepPrimAPI_MakePrism(s->shape, gp_Vec(0, 0, height)).Shape());
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
            if (r.IsNull() && !curved && std::abs(height) > 2 * std::abs(cap)) {
                // a rounding that closes up at the very top (a profile
                // offset inwards, tapered back out as far): drafted to just
                // below, its top extruded straight the last micron
                TopoDS_Shape low = drafted(face, height - cap, taper_rad, curved);
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
            }
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
        return primitive(BRepPrimAPI_MakeRevol(s->shape, axis, angle_rad).Shape());
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
    return guarded<>((hc_shape *)nullptr, [&] {
        gp_Trsf t;
        t.SetMirror(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(nx, ny, nz)));
        return transformed(s, t);
    });
}

// The result of a boolean of solids with the faces lying on one surface
// merged (two boxes side by side make one top face, not two with a seam
// between them), each merged face keeping the origin of one of the faces it
// was made of: the first operand's, the body's face rather than the tool's.
static TopoDS_Shape unify_keeping_origins(BRepBuilderAPI_MakeShape &mk, const hc_shape *a, const hc_shape *b)
{
    const TopoDS_Shape r = mk.Shape();
    history_record(mk, {&a->shape, &b->shape}, r);
    std::vector<Origin> before = g_history;
    TopTools_IndexedMapOfShape faces;
    TopExp::MapShapes(r, TopAbs_FACE, faces);
    ShapeUpgrade_UnifySameDomain unify(r, Standard_True, Standard_True, Standard_False);
    // merging can fail on some geometry ("Courbes non jointives"): the
    // boolean's own result then, with its faces as they are, rather than none
    try {
        unify.Build();
    } catch (const Standard_Failure &) {
        g_history = before;
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
            auto set = [&](const TopoDS_Shape &g) {
                int j = merged.FindIndex(g);
                if (j > 0 && g_history[j - 1].input < 0)
                    g_history[j - 1] = o;
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
        if (!mk->IsDone()) {
            set_error("the boolean operation failed");
            return nullptr;
        }
        return wrap(unify_keeping_origins(*mk, a, b));
    });
}

hc_shape *hc_boolean(const hc_shape *a, const hc_shape *b, int op)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
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
        auto parallel = [&](BRepAlgoAPI_BooleanOperation &&mk) -> hc_shape * {
            TopTools_ListOfShape args, tools;
            args.Append(a->shape);
            tools.Append(b->shape);
            mk.SetArguments(args);
            mk.SetTools(tools);
            mk.SetRunParallel(Standard_True);
            mk.Build();
            return run(std::move(mk));
        };
        switch (op) {
        case HC_FUSE: return parallel(BRepAlgoAPI_Fuse());
        case HC_CUT: return parallel(BRepAlgoAPI_Cut());
        case HC_COMMON: return parallel(BRepAlgoAPI_Common());
        default: set_error("invalid boolean operation"); return nullptr;
        }
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
        if (n == 1)
            return wrap(shapes[0]->shape);
        TopTools_ListOfShape args, tools;
        args.Append(shapes[0]->shape);
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
        ShapeUpgrade_UnifySameDomain unify(fuse.Shape(), Standard_True, Standard_True, Standard_False);
        unify.Build();
        history_new(unify.Shape());
        return wrap(unify.Shape());
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

int hc_edge_info(const hc_shape *s, int index, double out[17])
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
        for (int i = 9; i < 17; i++)
            out[i] = 0;
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

int hc_face_info(const hc_shape *s, int index, double out[7])
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

        double vals[7] = {c.X(), c.Y(), c.Z(), n.X(), n.Y(), n.Z(), props.Mass()};
        for (int i = 0; i < 7; i++)
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
        return wrap(mk.Shape());
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
        return wrap(mk.Shape());
    });
}

// The flat face `face` swept by the vector v: the solid a push or pull of
// the face adds or removes.
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
        history_new(prism.Shape());
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
        return wrap(mk.Shape());
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

// Whether a face is freeform (a B-spline, a curve swept along a line…),
// where the integration of volumes can go wrong.
static bool freeform(const TopoDS_Face &f)
{
    switch (BRepAdaptor_Surface(f, Standard_False).GetType()) {
    case GeomAbs_BSplineSurface: case GeomAbs_BezierSurface: case GeomAbs_SurfaceOfExtrusion:
    case GeomAbs_OffsetSurface: case GeomAbs_OtherSurface:
        return true;
    default:
        return false;
    }
}

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
    return guarded<>(-1.0, [&] {
        double volume, area;
        if (triangle_properties(s, volume, area))
            return volume;
        GProp_GProps p;
        BRepGProp::VolumeProperties(s->shape, p, mass_accuracy);
        // WORKAROUND (OCCT 7.9, BRepGProp): on freeform faces swept from a
        // smooth outline the adaptive integration can be far off (a hook
        // made of a smooth polygon extruded: 18300 mm³ for 10500, a smooth C:
        // +6%); the volume of the mesh is then the truer one. lang/tests.d
        // turns this off (HC_WORKAROUND_MESH_VOLUME) and fails once it is right
        bool any = false;
        for (TopExp_Explorer ex(s->shape, TopAbs_FACE); ex.More() && !any; ex.Next())
            any = freeform(TopoDS::Face(ex.Current()));
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
        for (TopExp_Explorer f(s->shape, TopAbs_FACE); f.More(); f.Next())
        {
            const TopoDS_Face &face = TopoDS::Face(f.Current());
            if (BRepAdaptor_Surface(face, false).GetType() == GeomAbs_Torus)
                slow.push_back(face);
            else
                BRepBndLib::AddOptimal(face, b, false, false);
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
        return 0;
    });
}

int hc_is_valid(const hc_shape *s)
{
    // the faces checked on every core: a solid made from a mesh has a face per
    // triangle (the phone stand example's phone: 7 s on one core)
    return guarded<>(0, [&] { return BRepCheck_Analyzer(s->shape, Standard_True, Standard_True).IsValid() ? 1 : 0; });
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

hc_shape *hc_from_mesh(const float *verts, int nverts, const int *tris, int ntris, double tolerance)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        for (int t = 0; t < 3 * ntris; t++)
            if (tris[t] < 0 || tris[t] >= nverts) {
                set_error("triangle index out of range");
                return nullptr;
            }
        TopoDS_Shape sewn = shell_from_mesh(verts, nverts, tris, ntris, tolerance);
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
        ShapeUpgrade_UnifySameDomain unify(solid, Standard_True, Standard_True, Standard_False);
        unify.Build();
        // (a shell built directly from a clean mesh is valid by construction:
        // checking it costs seconds on large meshes)
        if (!unified_valid(unify.Shape()) && (direct || BRepCheck_Analyzer(solid).IsValid()))
            return primitive(solid);
        return primitive(unify.Shape());
    });
}

int hc_write_step(const hc_shape *const *shapes, const char *const *names, int n, const char *path)
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
        history_new(r.OneShape());
        return wrap(r.OneShape());
    });
}

} // extern "C"

// ---------------------------------------------------------------- paths, sweep, loft, outlines

// Loops → planar profile faces: loops inside an odd number of others are holes.
static TopoDS_Shape faces_from_loops(const std::vector<TopoDS_Wire> &loops)
{
    struct Loop {
        TopoDS_Face face;
        double area;
        gp_Pnt probe;
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
        ls.push_back({upward(f.Face()), std::abs(p.Mass()), BRep_Tool::Pnt(TopoDS::Vertex(v.Current()))});
    }
    std::sort(ls.begin(), ls.end(), [](const Loop &a, const Loop &b) { return a.area > b.area; });
    TopoDS_Shape result;
    for (size_t i = 0; i < ls.size(); i++) {
        int depth = 0;
        for (size_t j = 0; j < i; j++) {
            BRepClass_FaceClassifier c(ls[j].face, ls[i].probe, 1e-6);
            depth += c.State() == TopAbs_IN;
        }
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
    bool twisted = false;
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
                if (diagonal(mk.Shape()) <= 1.5 * span + 1e-6)
                    return mk.Shape();
                twisted = true;
            }
        } catch (const Standard_Failure &) {
        }
    }
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
        // With a few pieces per turn the curve stays within 1e-6 mm. The
        // "known bugs" unittest in lang/tests.d builds it the default way
        // (HC_WORKAROUND_HELIX_PIECES) and fails once the curve is right;
        // then the plain BuildCurves3d(e) will do.
        if (workaround(HC_WORKAROUND_HELIX_PIECES)) {
            const int segments = std::max(30, (int)std::ceil(turns * 4));
            BRepLib::BuildCurves3d(e, 1e-6, GeomAbs_C2, 9, segments);
        } else
            BRepLib::BuildCurves3d(e);
        return primitive(BRepBuilderAPI_MakeWire(e).Wire());
    });
}

hc_shape *hc_outline(const double *data, int n)
{
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        std::vector<TopoDS_Wire> loops;
        BRepBuilderAPI_MakeWire wire;
        bool open = false;
        auto close = [&] {
            if (!open)
                return;
            if (!wire.IsDone())
                throw Standard_Failure("the outline segments do not connect");
            if (!wire.Wire().Closed())
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
            }
        }
        close();
        if (loops.empty()) {
            set_error("the outline is empty");
            return nullptr;
        }
        return primitive(faces_from_loops(loops));
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
static TopoDS_Wire twist_guide(const TopoDS_Wire &spine, gp_Dir start, double twist, double radius)
{
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
    const double turns = (std::abs(twist) + turning) / (2 * M_PI);
    const int n = std::min(2000, std::max(24, (int)std::ceil(turns * 72) + 24));
    GCPnts_UniformAbscissa ua(c, n + 1);
    if (!ua.IsDone() || ua.NbPoints() < 3)
        throw Standard_Failure("the path is too short to twist along");
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
        ref = ref - t * ref.Dot(t);
        if (ref.Magnitude() < 1e-9)
            throw Standard_Failure("the path turns too sharply to twist along");
        ref.Normalize();
        const double f = (i - 1.0) / (ua.NbPoints() - 1.0);
        const gp_Vec turned = ref.Rotated(gp_Ax1(gp::Origin(), gp_Dir(t)), twist * f);
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
    return guarded<>((hc_shape *)nullptr, [&]() -> hc_shape * {
        TopoDS_Wire spine = single_wire(path->shape);
        // the profile is drawn on XY around the origin: carry it to the start of
        // the path, normal to it, keeping its +Y as close to world +Z as possible
        BRepAdaptor_CompCurve c(spine);
        gp_Pnt p;
        gp_Vec t;
        c.D1(c.FirstParameter(), p, t);
        gp_Dir tz(t);
        gp_Vec up(0, 0, 1);
        if (std::abs(gp_Dir(up).Dot(tz)) > 0.999)
            up = gp_Vec(0, 1, 0);
        gp_Dir y(up - gp_Vec(tz) * up.Dot(gp_Vec(tz)));
        gp_Dir x = y.Crossed(tz);
        gp_Trsf place;
        place.SetTransformation(gp_Ax3(p, tz, x), gp_Ax3(gp::XOY()));
        TopoDS_Shape moved = BRepBuilderAPI_Transform(profile->shape, place, true).Shape();
        ProfileLoops loops = loops_of(moved);
        // a twist: a guide winding around the path turns the profile
        TopoDS_Wire guide;
        if (twist != 0) {
            Bnd_Box bb;
            BRepBndLib::Add(moved, bb);
            const double radius = std::max(1.0, std::sqrt(bb.SquareExtent()));
            guide = twist_guide(spine, x, twist, radius);
        }
        auto pipe = [&](const TopoDS_Wire &w) {
            BRepOffsetAPI_MakePipeShell mk(spine);
            if (twist != 0)
                mk.SetMode(guide, Standard_False);
            else if (frenet)
                mk.SetMode(Standard_True);
            mk.SetTransitionMode(BRepBuilderAPI_RightCorner);   // mitred corners on polylines
            mk.Add(w);
            mk.Build();
            if (!mk.IsDone())
                throw Standard_Failure("sweep failed (does the path bend tighter than the profile?)");
            mk.MakeSolid();
            TopoDS_Shape r = mk.Shape();
            GProp_GProps g;
            BRepGProp::VolumeProperties(r, g);
            if (g.Mass() < 0)
                r.Reverse();
            return r;
        };
        TopoDS_Shape result = pipe(loops.outer);
        for (auto &h : loops.holes)
            result = BRepAlgoAPI_Cut(result, pipe(h)).Shape();
        return primitive(result);
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
