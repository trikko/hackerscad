/// 3D view: shaded parts with outlined edges, a ground grid, the navigation
/// of CAD programs (right drag rotates, middle drag pans, the wheel zooms
/// towards the pointer) and face picking.
module hackerscad.gui.viewport;

import hackerscad.geom.printability : PrintCheck, checkPrint;
import core.time : MonoTime, msecs;
import std.math : sin, cos, tan, atan, PI, abs, pow, sqrt;
import std.algorithm : clamp, min, max;
import std.string : toStringz;

import bindbc.opengl;

import gtk.glarea : GLArea;
import gtk.drawing_area : DrawingArea;
import gtk.gesture_drag : GestureDrag;
import gtk.event_controller_scroll : EventControllerScroll;
import gtk.event_controller_motion : EventControllerMotion;
import gtk.types : EventControllerScrollFlags;
import gdk.glcontext : GLContext;
import gdk.types : ModifierType;
import cairo.context : Context;

import hackerscad.geom.vec;
import hackerscad.geom.color : alphaOf;
import hackerscad.gui.evaluator : PartMesh;
import hackerscad.kernel.brep : Brep, EdgeInfo, EdgeKind;
import hackerscad.lang.sketchval : SketchView;

enum ViewPreset
{
    iso,
    front,
    top,
    right,
}

/// How the parts are drawn.
enum Shading
{
    edges,      /// shaded, with their edges outlined
    shaded,     /// shaded, without edges
    wireframe,  /// edges only, the hidden ones faint
}

/// How shiny the surfaces are.
enum Shine
{
    none,       /// matte, the light in parallel rays: each flat face one even tone
    normal,     /// a light from the viewer, a small highlight on curves
    high,       /// a shiny material (a matcap): soft highlights on every curve
}

/// What a click in the view picks: whole parts, faces, edges or vertices.
enum SelectMode
{
    part,
    face,
    edge,
    vertex,
}


/// Result of a pick: part and B-rep face under the pointer.
struct Hit
{
    int part = -1;
    int face = -1;
    int edge = -1;      /// B-rep edge near the pointer, if any
    int vertex = -1;    /// corner of the part (Viewport.vertices) picked, if any
    Vec3 point;
    Vec3 normal;            /// of the triangle hit
    double x = 0, y = 0;    /// window coordinates of the click
    bool shift;             /// Shift held: add to (or remove from) the selection
    double distance = double.infinity;
    int plane = -1;     /// a plane shown (Viewport.planes) under the pointer, nearer than any part
}

/// Whether the segment (ax, ay)–(bx, by) on screen meets the box from (lx, ly)
/// to (hx, hy): an end inside it, or crossing one of its sides.
bool boxMeetsSegment(double lx, double ly, double hx, double hy, double ax, double ay, double bx, double by)
{
    bool inside(double x, double y) => x >= lx && x <= hx && y >= ly && y <= hy;
    if (inside(ax, ay) || inside(bx, by))
        return true;
    static double side(double px, double py, double qx, double qy, double rx, double ry) =>
        (qx - px) * (ry - py) - (qy - py) * (rx - px);
    bool cross(double cx, double cy, double dx, double dy) =>
        side(ax, ay, bx, by, cx, cy) * side(ax, ay, bx, by, dx, dy) <= 0
        && side(cx, cy, dx, dy, ax, ay) * side(cx, cy, dx, dy, bx, by) <= 0;
    return cross(lx, ly, hx, ly) || cross(hx, ly, hx, hy) || cross(hx, hy, lx, hy) || cross(lx, hy, lx, ly);
}

unittest
{
    assert(boxMeetsSegment(0, 0, 10, 10, 5, 5, 20, 20));      // an end inside
    assert(boxMeetsSegment(0, 0, 10, 10, -5, 5, 15, 5));      // through it
    assert(!boxMeetsSegment(0, 0, 10, 10, -5, -1, 15, -1));   // under it
}

final class Viewport
{
    /// What to say in the view when the machine's OpenGL cannot draw it and
    /// the application knows why (set before the view is made).
    static string glHelp;
    /// Called, once the view has failed to get its OpenGL, with glHelp.
    void delegate(string help) onGlFailed;

    GLArea area;
    /// Over the view: the box of a left drag selecting what is inside it
    DrawingArea band;
    /// A left drag ended: the box from (x0, y0) to (x1, y1), view pixels; crossing (dragged right to left) takes
    /// what it touches, else only what is wholly inside
    void delegate(double x0, double y0, double x1, double y1, bool crossing) onBox;
    /// A left drag begins at (x, y): true when what is there is taken to move (then onGrabMove follows the
    /// pointer, onGrabEnd ends it), false for a box
    bool delegate(double x, double y) onGrab;
    void delegate(double x, double y) onGrabMove;
    void delegate(double x, double y) onGrabEnd;
    Shading shading = Shading.edges;
    /// Parallel projection: sizes do not shrink with the distance.
    bool orthographic;
    void delegate(Hit hit) onPick;    /// part -1 when clicking the background
    void delegate(double x, double y) onDoubleClick;   /// a second left click soon after the first, in the same place
    void delegate(double x, double y) onMotion;
    void delegate() onSketchShown;   /// a sketch began to be drawn, or none is any more        /// the pointer moved over the view (not dragging)
    /// A sketch being drawn with the sketch bar: its pieces so far and the one to the pointer, and its points (in
    /// the model's coordinates), drawn over everything
    Vec3[][] drawingLines;
    Vec3[] drawingPoints;
    Vec3[] drawingSnap;   /// the point the pointer would snap to (none: empty)
    int drawingSnapKind;  /// what it is: 0 a point, 1 a line's middle, 2 where two lines cross
    private long lastClickAt;          /// when the last left click was (hnsecs)
    private double lastClickX = -1e9, lastClickY = -1e9;
    void delegate(Hit hit, double x, double y) onContext;   /// right click without dragging
    void delegate() onFrame;          /// after every frame (to move overlay labels)

    private PartMesh[] parts;
    private bool[] hidden;
    private Gpu[] gpu;
    private bool glReady;
    private bool dirty;
    private Hit selected;        /// the latest item picked
    private Hit[] others;        /// more items picked with Shift (same part)
    private bool startShift;
    private bool fitPending;

    // rollback: the solid after one feature, the final parts as ghosts
    private bool rollback;
    private PartMesh rollbackMesh;
    private Gpu rollbackGpu;
    private bool rollbackDirty;
    private uint rollbackFeature;

    // inspect: what some lines of code made, the final parts as ghosts
    private bool inspecting;
    private PartMesh[] inspectItems;
    private Vec3[] inspectColors;   /// one per item, or none: all orange
    private Gpu[] inspectGpu;
    private bool inspectDirty;

    // sketches drawn over the model
    private SketchView[] sketches;
    private size_t[] shownSketches;      /// indices in sketches: the ones drawn
    private bool[size_t][] litEntities;  /// for each shown sketch, the entities that stand out
    private bool[] fadedSketches;        /// by index in sketches: drawn faint
    private uint sketchVao, sketchVbo;
    private uint sketchFillVao, sketchFillVbo;
    private int sketchFillCount;   /// vertices of the triangles of the areas the profiles shown fill
    private bool sketchDirty;
    /// lines, construction lines, highlighted lines, free points, fixed points, highlighted points (end indices)
    private int[9] sketchRanges;

    private uint program, gridVao, gridVbo;
    private int gridCount;
    private float gridExtent, gridZ;
    private int uMvp, uModel, uColor, uEye, uFlat, uAlpha, uClipOn, uClip, uPattern, uSurface, uRight, uUp, uEven, uForward;

    // the colours of the window's dark style: background, grid, sketches
    private bool darkStyle;

    /// Draws for the dark style (or the light one).
    void setDark(bool on)
    {
        darkStyle = on;
        redraw();
    }

    // section plane: what lies where dot(p, sectionNormal) > sectionOffset is hidden
    private bool section;
    private Vec3 sectionNormal = Vec3(0, 0, 1);
    private double sectionOffset = 0;
    // the handles at the corners of the section plane: one dragged moves the
    // plane along its normal; the window is told the new offset
    private int sectionHandle = -1, hoverHandle = -1;   /// 0…3 a corner, 4 the plane itself
    private Vec3 sectionGrab;                            /// where the plane itself was grabbed
    private double handleStartOffset;
    void delegate(double offset) onSectionDrag;
    // the X past a corner of the section plane: a click closes the section
    /// The round buttons drawn in the view: an X closes or cancels, a ✓
    /// accepts (the section's X; the split's ✓; Move and Rotate's X and ✓).
    enum ViewButton { none, sectionClose, sectionAccept, gizmoCancel, gizmoAccept }
    private ViewButton hoverButton, pressedButton;
    void delegate() onSectionClose, onSectionAccept, onGizmoCancel, onGizmoAccept;
    /// Split: the section plane covers this part only, and has a ✓ too.
    public int sectionPart = -1;

    // camera: orbit around target, Z up
    private Vec3 target;
    private double distance = 150, yaw = -PI / 3, pitch = PI / 6;
    private bool firstModel = true;   // the window's first model is seen from a little higher
    private double fitRoom = 1;       // the next fit this much farther (the first model's)
    /// Pixels at the left of the view a bar covers (the sketch bar): fit frames the model in the rest
    double leftInset = 0;
    private enum fovy = 30.0 * PI / 180;

    // pointer and drag state
    private double pointerX = 0, pointerY = 0;
    private bool dragging, dragPan, dragBox, dragGrab;
    private double boxX, boxY;   /// where a box being dragged has its other corner
    private uint dragButton;
    private double startYaw, startPitch, startX, startY;
    private Vec3 startTarget;
    // a rotation turns the view about this point: the part under the pointer
    // where the drag began, else the middle of what is drawn (never a target
    // that zooming has carried far off), with the view's axes as they were then
    private Vec3 orbitPivot, startRight, startUp, startForward;
    private double panScale = 1;   /// mm per pixel of a pan: at the depth of what was grabbed

    this()
    {
        area = new GLArea;
        area.setHasDepthBuffer(true);
        area.setHasStencilBuffer(true);   // section caps
        area.setRequiredVersion(3, 3);
        area.setHexpand(true);
        area.setVexpand(true);
        area.setFocusable(true);
        area.connectRealize(&realize);
        area.connectRender((GLContext c, GLArea a) => render());

        auto drag = new GestureDrag;
        drag.setButton(0);
        drag.connectDragBegin((double x, double y, GestureDrag g) {
            lockedDrag = locked;
            if (lockedDrag)
                return;
            startX = x;
            startY = y;
            immutable button = g.getCurrentButton();
            immutable mods = g.getCurrentEventState();
            immutable shift = (mods & ModifierType.ShiftMask) != 0, ctrl = (mods & ModifierType.ControlMask) != 0;
            // right rotates, middle (or ctrl + right) pans; left draws a box to select, with shift rotates,
            // with ctrl pans (a touchpad has no middle button)
            dragPan = button == 2 || ((button == 1 || button == 3) && ctrl);
            dragBox = button == 1 && !shift && !ctrl;
            dragButton = button;
            // a left drag on the frame, arrow or rings moving or turning a part
            gizmoGrab = button == 1 && gizmo != Gizmo.none && buttonAt(x, y) == ViewButton.none ? gizmoAt(x, y) : -1;
            if (gizmoGrab >= 0)
                grabGizmo(x, y);
            // a left drag from a handle of the section plane moves the plane;
            // a click on an X or a ✓ closes or accepts
            pressedButton = button == 1 && gizmoGrab < 0 ? buttonAt(x, y) : ViewButton.none;
            sectionHandle = button == 1 && pressedButton == ViewButton.none && gizmoGrab < 0 ? handleAt(x, y) : -1;
            handleStartOffset = sectionOffset;
            if (gizmoGrab >= 0 || pressedButton != ViewButton.none || sectionHandle >= 0 || placing)
                dragBox = false;
            // on something a sketch can move: it moves, no box
            dragGrab = dragBox && onGrab !is null && onGrab(x, y);
            if (dragGrab)
                dragBox = false;
            startShift = shift;
            startYaw = yaw;
            startPitch = pitch;
            startTarget = target;
            if (dragPan)
            {
                // what is under the pointer follows it: the part grabbed, or
                // the model's middle (not the target, which can lie a few mm
                // ahead after zooming in on nothing, and crawl)
                auto under = pick(x, y);
                Vec3 lo, hi;
                auto at = under.part >= 0 ? under.point : drawnBox(lo, hi) ? (lo + hi) * 0.5 : target;
                auto b = basis();
                if (!orthographic && (at - b.eye).dot(b.forward) < 1e-3)
                    at = target;
                panScale = mmPerPixelAt(at);
            }
            else
            {
                auto under = pick(x, y);
                Vec3 lo, hi;
                orbitPivot = under.part >= 0 ? under.point : drawnBox(lo, hi) ? (lo + hi) * 0.5 : target;
                auto b0 = basis();
                startRight = b0.right;
                startUp = b0.up;
                startForward = b0.forward;
            }
            area.grabFocus();
        });
        drag.connectDragUpdate((double dx, double dy, GestureDrag g) {
            if (lockedDrag)
                return;
            if (gizmoGrab >= 0)
            {
                dragging = true;
                dragGizmo(startX + dx, startY + dy, dx, dy, (g.getCurrentEventState() & ModifierType.ShiftMask) != 0);
                return;
            }
            if (pressedButton != ViewButton.none)
                return;
            if (sectionHandle >= 0)
            {
                dragging = true;
                dragHandle(dx, dy);
                return;
            }
            if (!dragging && abs(dx) + abs(dy) < 4)
                return;
            if (dragGrab)
            {
                dragging = true;
                if (onGrabMove !is null)
                    onGrabMove(startX + dx, startY + dy);
                return;
            }
            if (dragBox)
            {
                dragging = true;
                boxX = startX + dx;
                boxY = startY + dy;
                band.setVisible(true);
                band.queueDraw();
                return;
            }
            if (!dragging)
            {
                dragging = true;
                area.setCursorFromName(dragPan ? "move" : "grabbing");
            }
            if (dragPan)
            {
                auto c = basis();
                target = startTarget - c.right * (dx * panScale) + c.up * (dy * panScale);
            }
            else
            {
                yaw = startYaw - dx * 0.008;
                pitch = max(-PI / 2 + 0.01, min(PI / 2 - 0.01, startPitch + dy * 0.008));
                // the target goes round the pivot with the view: what was at
                // the pivot stays there on screen
                auto v = startTarget - orbitPivot;
                auto b1 = basis();
                target = orbitPivot + b1.right * v.dot(startRight) + b1.up * v.dot(startUp) + b1.forward * v.dot(startForward);
            }
            moved();
            redraw();
        });
        drag.connectDragEnd((double dx, double dy, GestureDrag g) {
            if (lockedDrag)
                return;
            if (gizmoGrab >= 0)
            {
                gizmoGrab = -1;
                dragging = false;
                updateHoverCursor();
                return;
            }
            if (pressedButton != ViewButton.none)
            {
                // still on the button when released: what it does
                immutable b = pressedButton;
                pressedButton = ViewButton.none;
                if (buttonAt(startX + dx, startY + dy) == b)
                {
                    auto run = b == ViewButton.sectionClose ? onSectionClose : b == ViewButton.sectionAccept
                        ? onSectionAccept : b == ViewButton.gizmoCancel ? onGizmoCancel : onGizmoAccept;
                    if (run !is null)
                        run();
                }
                updateHoverCursor();
                return;
            }
            if (sectionHandle >= 0)
            {
                sectionHandle = -1;
                dragging = false;
                updateHoverCursor();
                return;
            }
            // something of a sketch moved: put where it was let go (a click without moving picks it, below)
            if (dragGrab)
            {
                dragGrab = false;
                if (dragging)
                {
                    dragging = false;
                    if (onGrabEnd !is null)
                        onGrabEnd(startX + dx, startY + dy);
                    updateHoverCursor();
                    return;
                }
            }
            // a box dragged: what it takes joins the selection
            if (dragBox && dragging)
            {
                dragging = false;
                band.setVisible(planesOn);
                if (onBox !is null)
                    onBox(startX, startY, startX + dx, startY + dy, startX + dx < startX);
                updateHoverCursor();
                return;
            }
            // placing: a left click puts the anchor where the pointer is
            if (!dragging && dragButton == 1 && placing)
            {
                hoverPlace(startX, startY);
                choosePlace();
                dragging = false;
                updateHoverCursor();
                return;
            }
            // a left click without movement picks what is under the pointer
            if (!dragging && dragButton == 1 && onPick !is null)
            {
                auto h = pickSelect(startX, startY);
                h.shift = startShift;
                onPick(h);
                // a double click: the system's time between the two, a few pixels apart
                import core.time : MonoTime;
                import gtk.settings : Settings;
                immutable now = MonoTime.currTime.ticks;
                immutable ms = (now - lastClickAt) * 1000 / MonoTime.ticksPerSecond;
                int limit = 400;
                if (auto st = Settings.getDefault())
                    limit = st.gtkDoubleClickTime;
                if (ms <= limit && abs(startX - lastClickX) < 6 && abs(startY - lastClickY) < 6 && onDoubleClick !is null)
                {
                    lastClickAt = 0;
                    onDoubleClick(startX, startY);
                }
                else
                {
                    lastClickAt = now;
                    lastClickX = startX;
                    lastClickY = startY;
                }
            }
            // a right click without movement opens the context menu
            if (!dragging && dragButton == 3 && onContext !is null)
                onContext(pickSelect(startX, startY), startX, startY);
            dragging = false;
            updateHoverCursor();
        });
        area.addController(drag);

        band = new DrawingArea;
        band.setCanTarget(false);
        band.setHexpand(true);
        band.setVexpand(true);
        band.setVisible(false);
        band.setDrawFunc((DrawingArea, Context cr, int w, int h) {
            if (planesOn)
                labelPlanes(cr);
            if (!dragBox || !dragging)
                return;
            immutable x = min(startX, boxX), y = min(startY, boxY), bw = abs(boxX - startX), bh = abs(boxY - startY);
            // dragged to the left: dashed, it takes what it touches
            immutable crossing = boxX < startX;
            cr.setSourceRgba(0.2, 0.55, 0.95, crossing ? 0.08 : 0.12);
            cr.rectangle(x, y, bw, bh);
            cr.fill();
            cr.setSourceRgba(0.2, 0.55, 0.95, 0.9);
            cr.setLineWidth(1);
            if (crossing)
                cr.setDash([5.0, 3.0], 0);
            cr.rectangle(x + 0.5, y + 0.5, bw, bh);
            cr.stroke();
        });

        auto motion = new EventControllerMotion;
        motion.connectMotion((double x, double y, EventControllerMotion m) {
            pointerX = x;
            pointerY = y;
            if (!dragging)
            {
                if (planesOn)
                {
                    double d;
                    immutable at = planeAt(x, y, d);
                    immutable over = at >= 0 && d < pick(x, y).distance ? at : -1;
                    if (over != hoverPlane)
                    {
                        hoverPlane = over;
                        redraw();
                    }
                }
                updateHoverCursor();
                if (onMotion !is null)
                    onMotion(x, y);
            }
        });
        motion.connectLeave(() {
            hover = Hit.init;
            redraw();
        });
        area.addController(motion);

        auto scroll = new EventControllerScroll(EventControllerScrollFlags.Vertical);
        scroll.connectScroll((double dx, double dy, EventControllerScroll s) {
            // a wheel notch zooms by 10%; touchpads and smooth wheels report pixels: about 10% per 40 px
            import gdk.types : ScrollUnit;
            if (locked)
                return true;
            immutable steps = s.getUnit() == ScrollUnit.Wheel ? dy : dy / 40;
            moved();
            zoomAt(pointerX, pointerY, pow(1.1, max(-2.0, min(2.0, steps))));
            return true;
        });
        area.addController(scroll);
    }

    /// Replaces the displayed parts; `fitView` (a new model) puts the view
    /// back to the default one, framed on them.
    /// Grows at each setParts: whether the parts are still those of a moment ago.
    public uint partsVersion;

    void setParts(PartMesh[] p, bool fitView)
    {
        partsVersion++;
        vertexCache = null;
        // a part keeps its visibility by name, wherever it moves in the list
        bool[string] was;
        foreach (i, q; parts)
            if (i < hidden.length && hidden[i])
                was[q.name] = true;
        parts = p;
        // the parts the confirmed move or turn made: its preview is over
        if (keepPreview)
        {
            keepPreview = false;
            gizmoPart = -1;
            hingeAngle = 0;
            placeActive = false;
        }
        if (placing)
            stopPlace();
        hidden = new bool[parts.length];
        foreach (i, q; parts)
            hidden[i] = (q.name in was) !is null;
        dirty = true;
        if (selected.part >= cast(int) parts.length)
            selected = Hit.init;
        // a new model starts from the default view, framed; the first one a
        // window shows from a little higher than Iso, into Carlo's slot
        if (fitView && firstModel)
        {
            yaw = -PI / 3;
            pitch = PI / 4;
            fitRoom = 1.25;   // and with room around it
            fit();
        }
        else if (fitView)
            setView(ViewPreset.iso);
        if (parts.length)
            firstModel = false;
        redraw();
    }

    void select(Hit h)
    {
        selected = h;
        others = null;
        redraw();
    }

    static bool sameItem(Hit a, Hit b) => a.part == b.part && a.edge == b.edge && a.vertex == b.vertex
        && (a.edge >= 0 || a.vertex >= 0 || a.face == b.face);

    /// A click: adds the item to the selection, or removes it if already
    /// there; items of several parts can be selected together (to measure).
    void toggleSelect(Hit h)
    {
        if (selected.part < 0)
            return select(h);
        auto all = selection();
        Hit[] kept;
        bool removed;
        foreach (x; all)
        {
            if (sameItem(x, h))
                removed = true;
            else
                kept ~= x;
        }
        if (!removed)
            kept ~= h;
        if (kept.length == 0)
        {
            selected = Hit.init;
            others = null;
        }
        else
        {
            selected = kept[$ - 1];
            others = kept[0 .. $ - 1];
        }
        redraw();
    }

    /// What a click picks.
    public SelectMode selectMode = SelectMode.part;

    public void setSelectMode(SelectMode m)
    {
        selectMode = m;
        hover = Hit.init;
        redraw();
    }

    private Vec3[][] vertexCache;   /// per part, its corners (filled when first asked)

    /// The corners of part `i`: where its edges end, each once.
    Vec3[] vertices(size_t i)
    {
        if (i >= parts.length)
            return null;
        if (vertexCache.length != parts.length)
            vertexCache = new Vec3[][parts.length];
        if (vertexCache[i] is null)
        {
            Vec3[] r;
            void add(Vec3 v)
            {
                foreach (q; r)
                    if ((q - v).length < 1e-6)
                        return;
                r ~= v;
            }
            foreach (e; parts[i].edgeInfo)
            {
                add(e.start);
                add(e.end);
            }
            vertexCache[i] = r.length ? r : [parts[i].bbox.center];
        }
        return vertexCache[i];
    }

    /// Where vertex `v` of part `i` is drawn (a previewed part where it goes).
    Vec3 vertexAt(size_t i, int v)
    {
        auto vs = vertices(i);
        if (v < 0 || v >= vs.length)
            return Vec3(0, 0, 0);
        return previewing(i) ? placed(vs[v]) : vs[v];
    }

    /// The vertex of a part nearest to window point (x, y) within `within`
    /// pixels (`part` -1: of any part shown).
    Hit nearestVertex(int part, double x, double y, double within = 12)
    {
        Hit best;
        double bestD = within;
        foreach (i; 0 .. parts.length)
        {
            if ((part >= 0 && i != part) || isHidden(i))
                continue;
            foreach (k, v; vertices(i))
            {
                double px, py;
                if (!project(previewing(i) ? placed(v) : v, px, py))
                    continue;
                immutable d = sqrt((px - x) ^^ 2 + (py - y) ^^ 2);
                // a corner behind the part is not picked (in wireframe it shows, and is)
                if (d < bestD && (shading == Shading.wireframe || seen(previewing(i) ? placed(v) : v)))
                {
                    bestD = d;
                    best.part = cast(int) i;
                    best.vertex = cast(int) k;
                    best.point = previewing(i) ? placed(v) : v;
                }
            }
        }
        best.x = x;
        best.y = y;
        return best;
    }

    /// What a click at (x, y) picks in the current mode: a part, a face, an
    /// edge (the nearest, within reach even just off the part) or a vertex.
    Hit pickSelect(double x, double y)
    {
        auto h = pick(x, y);
        // a plane shown, in front of the part hit (or with none): the plane
        double planeDistance;
        immutable onPlane = planeAt(x, y, planeDistance);
        if (onPlane >= 0 && planeDistance < h.distance)
        {
            Hit p;
            p.plane = onPlane;
            p.distance = planeDistance;
            p.normal = planes[onPlane].normal;
            Vec3 eye, dir;
            ray(x, y, eye, dir);
            p.point = eye + dir * planeDistance;
            p.x = x;
            p.y = y;
            return p;
        }
        final switch (selectMode)
        {
        case SelectMode.part:
            h.face = h.edge = h.vertex = -1;
            return h;
        case SelectMode.face:
            h.edge = h.vertex = -1;
            return h;
        case SelectMode.edge:
            {
                // the part hit first, else any part's edge near the pointer
                int edge = h.part >= 0 ? nearestEdge(h.part, -1, x, y, 14, true) : -1;
                if (edge < 0)
                    foreach (i; 0 .. parts.length)
                        if (!isHidden(i) && (edge = nearestEdge(cast(int) i, -1, x, y, 14, true)) >= 0)
                        {
                            h.part = cast(int) i;
                            break;
                        }
                if (edge < 0)
                    return Hit(-1, -1, -1, -1, Vec3(0, 0, 0), Vec3(0, 0, 0), x, y);
                h.edge = edge;
                h.face = h.vertex = -1;
                return h;
            }
        case SelectMode.vertex:
            {
                auto v = nearestVertex(h.part, x, y);
                if (v.part < 0 && h.part >= 0)
                    v = nearestVertex(-1, x, y);
                else if (v.part < 0)
                    v = nearestVertex(-1, x, y);
                v.shift = h.shift;
                return v;
            }
        }
    }

    /// What a box from (x0, y0) to (x1, y1) in view pixels takes in the
    /// selection mode: wholly inside it, or (crossing) touching it; only what is
    /// in sight (in wireframe, everything drawn), of the parts shown.
    Hit[] boxItems(double x0, double y0, double x1, double y1, bool crossing)
    {
        immutable lx = min(x0, x1), hx = max(x0, x1), ly = min(y0, y1), hy = max(y0, y1);
        bool inside(double x, double y) => x >= lx && x <= hx && y >= ly && y <= hy;
        bool meets(double ax, double ay, double bx, double by) => boxMeetsSegment(lx, ly, hx, hy, ax, ay, bx, by);
        immutable all = shading == Shading.wireframe;
        // points (in the model) the box takes: all inside, or one touching; one at least in sight
        bool takes(Vec3[] pts, bool asLine, Vec3[] sight = null)
        {
            bool any, every = true, visible = all;
            int looks;   // a ray cast each: a few, spread along, are enough
            immutable stride = max(1, pts.length / 8);
            double px, py, qx = double.nan, qy;
            foreach (k, q; pts)
            {
                if (!project(q, px, py))
                {
                    every = false;
                    continue;
                }
                immutable inBox = inside(px, py);
                if (inBox || (asLine && k > 0 && qx == qx && meets(qx, qy, px, py)))
                    any = true;
                if (!inBox)
                    every = false;
                if (!visible && sight is null && inBox && k % stride == 0 && looks++ < 12 && seen(q))
                    visible = true;
                qx = px;
                qy = py;
            }
            // crossing on a line in sight through the box with no point inside it: its middle decides
            if (!visible && any && asLine)
                visible = seen(pts[$ / 2]);
            // a face: in sight where its middle points are (its corners can be on the rim of one in front)
            if (!visible && any && sight !is null)
            {
                immutable step = max(1, sight.length / 12);
                for (size_t k = 0; k < sight.length && !visible; k += step)
                    visible = seen(sight[k]);
            }
            return (crossing ? any : every) && visible;
        }
        Hit[] r;
        foreach (i; 0 .. parts.length)
        {
            if (isHidden(i))
                continue;
            auto part = parts[i];
            Vec3 at(Vec3 q) => previewing(i) ? placed(q) : q;
            Vec3 vertexOf(uint v) => at(Vec3(part.vertices[v * 6], part.vertices[v * 6 + 1], part.vertices[v * 6 + 2]));
            Hit h;
            h.part = cast(int) i;
            final switch (selectMode)
            {
            case SelectMode.part:
                {
                    Vec3[] pts;
                    foreach (v; 0 .. part.vertices.length / 6)
                        pts ~= vertexOf(cast(uint) v);
                    if (pts.length && takes(pts, false))
                    {
                        h.point = at(part.bbox.center);
                        r ~= h;
                    }
                    break;
                }
            case SelectMode.face:
                foreach (f; 0 .. part.faceStart.length ? part.faceStart.length - 1 : 0)
                {
                    Vec3[] pts, middles;
                    foreach (t; part.faceStart[f] .. part.faceStart[f + 1])
                    {
                        auto a = vertexOf(part.indices[3 * t]), b = vertexOf(part.indices[3 * t + 1]),
                            c = vertexOf(part.indices[3 * t + 2]);
                        pts ~= [a, b, c];
                        middles ~= (a + b + c) / 3;
                    }
                    if (pts.length && takes(pts, false, middles))
                    {
                        h.face = cast(int) f;
                        h.point = middles[0];
                        r ~= h;
                    }
                }
                h.face = -1;
                break;
            case SelectMode.edge:
                foreach (k, e; part.edgeInfo)
                {
                    Vec3[] pts;
                    foreach (q; edgePoints(cast(int) i, e))
                        pts ~= at(q);
                    if (pts.length && takes(pts, true))
                    {
                        h.edge = cast(int) k;
                        h.point = pts[$ / 2];
                        r ~= h;
                    }
                }
                h.edge = -1;
                break;
            case SelectMode.vertex:
                foreach (k, v; vertices(i))
                    if (takes([at(v)], false))
                    {
                        h.vertex = cast(int) k;
                        h.point = at(v);
                        r ~= h;
                    }
                break;
            }
        }
        return r;
    }

    /// Everything selected, in picking order (on one part or several).
    Hit[] selection() => selected.part >= 0 ? others ~ selected : null;

    /// Replaces the selection (the last item is the main one).
    void setSelection(Hit[] items)
    {
        selected = items.length ? items[$ - 1] : Hit.init;
        others = items.length ? items[0 .. $ - 1].dup : null;
        redraw();
    }

    void setHidden(size_t part, bool hide)
    {
        if (part < hidden.length)
            hidden[part] = hide;
        redraw();
    }

    bool isHidden(size_t part) => part < hidden.length && hidden[part];

    /// Shows every part again (another model was opened).
    void showAll()
    {
        hidden[] = false;
        redraw();
    }

    /// What a click at view coordinates (x, y) would pick, in the selection mode.
    Hit pickAt(double x, double y) => pickSelect(x, y);

    /// What is under view coordinates (x, y), whatever the selection mode: the part and face hit.
    Hit pickAny(double x, double y) => pick(x, y);

    /// Shows the solid left by a feature, with its new faces highlighted
    /// and the final parts as ghosts.
    void showRollback(PartMesh m, uint feature)
    {
        rollback = true;
        inspecting = false;   // one or the other
        inspectDirty = true;
        rollbackMesh = m;
        rollbackFeature = feature;
        rollbackDirty = true;
        redraw();
    }

    void clearRollback()
    {
        rollback = false;
        redraw();
    }

    bool inRollback() const => rollback;

    /// Shows solids, 2D profiles and paths (what a line of code made) in
    /// orange, the final parts as ghosts. Profiles are filled and outlined
    /// where they are in their own coordinates; paths are lines. The view
    /// moves to them when they are not all in sight, keeping its direction.
    /// Shows `items` in orange, or each in its colour from `colors` (then
    /// see-through, so that overlapping operands both show).
    void showInspect(PartMesh[] items, Vec3[] colors = null)
    {
        inspecting = true;
        rollback = false;
        inspectItems = null;
        inspectColors = null;
        foreach (i, m; items)
        {
            if (m.vertices.length == 0 && m.edgeInfo.length == 0)
                continue;
            if (colors.length)
                inspectColors ~= i < colors.length ? colors[i] : Vec3(1.0, 0.62, 0.1);
            // profiles and paths: the exact B-rep edges as their outline
            if (m.flat || m.path)
            {
                m.edges = null;
                foreach (e; m.edgeInfo)
                {
                    auto pts = edgePolyline(e);
                    foreach (k; 0 .. pts.length - 1)
                        foreach (q; [pts[k], pts[k + 1]])
                            m.edges ~= [cast(float) q.x, cast(float) q.y, cast(float) q.z];
                }
            }
            inspectItems ~= m;
        }
        inspectDirty = true;
        if (inspectItems.length)
            frameIfOutside(inspectItems);
        redraw();
    }

    void clearInspect()
    {
        inspecting = false;
        inspectItems = null;
        inspectColors = null;
        inspectDirty = true;
        redraw();
    }

    bool inInspect() const => inspecting;

    /// Centres the view on the items when a corner of their box is out of
    /// sight (or they are a speck), from the same direction.
    private void frameIfOutside(PartMesh[] items)
    {
        auto box = items[0].bbox;
        foreach (m; items[1 .. $])
            box = box.merged(m.bbox);
        immutable lo = box.min, hi = box.max;
        immutable w = area.getWidth(), h = area.getHeight();
        if (w <= 0 || h <= 0)
            return;
        double x0 = double.max, y0 = double.max, x1 = -double.max, y1 = -double.max;
        bool outside;
        foreach (k; 0 .. 8)
        {
            auto c = Vec3(k & 1 ? hi.x : lo.x, k & 2 ? hi.y : lo.y, k & 4 ? hi.z : lo.z);
            double x, y;
            if (!project(c, x, y))
            {
                outside = true;
                break;
            }
            x0 = min(x0, x);
            y0 = min(y0, y);
            x1 = max(x1, x);
            y1 = max(y1, y);
        }
        outside = outside || x0 < 0 || y0 < 0 || x1 > w || y1 > h;
        immutable speck = max(x1 - x0, y1 - y0) < 12;
        if (outside || speck)
            centerOn((lo + hi) / 2, max(1.0, (hi - lo).length * 1.3));
    }

    /// Cuts the view with the plane dot(p, normal) = offset, hiding what lies on the normal's side.
    void setSection(bool on, Vec3 normal, double offset)
    {
        section = on;
        sectionNormal = normal.normalized;
        sectionOffset = offset;
        redraw();
    }

    /// Where the parts start and end along a direction (for the section
    /// slider); `only`: that part alone (split).
    void extentAlong(Vec3 n, out double lo, out double hi, long only = -1)
    {
        lo = double.infinity;
        hi = -double.infinity;
        foreach (i, p; parts)
        {
            if (isHidden(i) || (only >= 0 && i != only))
                continue;
            foreach (cx; [p.bbox.min.x, p.bbox.max.x])
                foreach (cy; [p.bbox.min.y, p.bbox.max.y])
                    foreach (cz; [p.bbox.min.z, p.bbox.max.z])
                    {
                        immutable d = Vec3(cx, cy, cz).dot(n.normalized);
                        lo = min(lo, d);
                        hi = max(hi, d);
                    }
        }
        if (lo > hi)
            lo = hi = 0;
    }

    /// Normal of the picked face at the picked point (from its triangles), if any.
    bool selectedPlane(out Vec3 point, out Vec3 normal)
    {
        if (selected.part < 0 || selected.face < 0 || selected.part >= parts.length)
            return false;
        auto p = parts[selected.part];
        if (selected.face + 1 >= p.faceStart.length)
            return false;
        immutable t = p.faceStart[selected.face];
        Vec3 vtx(uint i) => Vec3(p.vertices[i * 6], p.vertices[i * 6 + 1], p.vertices[i * 6 + 2]);
        auto a = vtx(p.indices[t * 3]), b = vtx(p.indices[t * 3 + 1]), c = vtx(p.indices[t * 3 + 2]);
        normal = (b - a).cross(c - a).normalized;
        point = selected.point;
        return normal.length > 0.5;
    }

    /// Fills the cut: for each part, the pixels where the plane lies inside
    /// the solid (an odd number of its surfaces along the ray, counted in the
    /// stencil buffer) get a cap drawn on the plane.
    void capSection()
    {
        auto q = sectionQuad();
        float[] tri;
        foreach (k; [0, 1, 2, 0, 2, 3])
            tri ~= [cast(float) q[k].x, cast(float) q[k].y, cast(float) q[k].z];
        glEnable(GL_STENCIL_TEST);
        foreach (i, g; gpu)
        {
            if (isHidden(i))
                continue;
            glClear(GL_STENCIL_BUFFER_BIT);
            // count the clipped surfaces: no colour, no depth
            glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
            glDepthMask(GL_FALSE);
            glDisable(GL_DEPTH_TEST);
            glStencilFunc(GL_ALWAYS, 0, 0xFF);
            glStencilOp(GL_KEEP, GL_KEEP, GL_INVERT);
            glUniform1i(uClipOn, 1);
            glUniform1i(uFlat, 1);
            forPart(i);
            glBindVertexArray(g.vao);
            glDrawElements(GL_TRIANGLES, g.indexCount, GL_UNSIGNED_INT, null);
            forPart(-1);
            // the cap, where the count is odd
            glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
            glDepthMask(GL_TRUE);
            glEnable(GL_DEPTH_TEST);
            glStencilFunc(GL_NOTEQUAL, 0, 0xFF);
            glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
            glUniform1i(uClipOn, 0);
            glUniform1i(uFlat, 2);
            auto c = rgbOf(parts[i].rgb);
            glUniform3f(uColor, cast(float) c.x, cast(float) c.y, cast(float) c.z);
            uploadLines(tri);
            glDrawArrays(GL_TRIANGLES, 0, 6);
        }
        glDisable(GL_STENCIL_TEST);
        glUniform1i(uClipOn, 1);
        glUniform1i(uFlat, 0);
    }

    /// The box around everything drawn: the parts shown, the solid of a
    /// rollback, what Inspect shows. False when there is nothing.
    bool drawnBox(out Vec3 lo, out Vec3 hi)
    {
        bool any;
        BBox box;
        void add(BBox b)
        {
            box = any ? box.merged(b) : b;
            any = true;
            lo = box.min;
            hi = box.max;
        }
        foreach (i, p; parts)
            if (!isHidden(i))
                add(p.bbox);
        if (rollback)
            add(rollbackMesh.bbox);
        if (inspecting)
            foreach (m; inspectItems)
                add(m.bbox);
        return any;
    }

    /// Corners of a rectangle on the section plane covering everything drawn,
    /// with a margin: a tenth of its size, at least 5 mm, and at least 20 mm
    /// across.
    Vec3[4] sectionQuad()
    {
        auto n = sectionNormal;
        auto u = (abs(n.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)).cross(n).normalized;
        auto v = n.cross(u);
        Vec3 lo, hi;
        if (sectionPart >= 0 && sectionPart < parts.length)
        {
            // split: the part alone
            lo = parts[sectionPart].bbox.min;
            hi = parts[sectionPart].bbox.max;
        }
        else if (!drawnBox(lo, hi))
            lo = hi = Vec3(0, 0, 0);
        // the corners of the box, along u and v
        double u0 = double.max, u1 = -double.max, v0 = double.max, v1 = -double.max;
        foreach (k; 0 .. 8)
        {
            auto c = Vec3(k & 1 ? hi.x : lo.x, k & 2 ? hi.y : lo.y, k & 4 ? hi.z : lo.z);
            u0 = min(u0, c.dot(u));
            u1 = max(u1, c.dot(u));
            v0 = min(v0, c.dot(v));
            v1 = max(v1, c.dot(v));
        }
        immutable margin = max(5.0, 0.1 * max(u1 - u0, v1 - v0));
        immutable du = max(10.0, (u1 - u0) / 2 + margin), dv = max(10.0, (v1 - v0) / 2 + margin);
        // the middle, on the plane
        auto c = u * ((u0 + u1) / 2) + v * ((v0 + v1) / 2) + n * sectionOffset;
        return [c + u * du + v * dv, c - u * du + v * dv, c - u * du - v * dv, c + u * du - v * dv];
    }

    // ---- moving, turning and scaling a part by hand (Move…, Rotate… and
    // Scale… in the context menu): arrows along X, Y and Z from the middle of
    // the part and a frame under it, three rings round it with a knob each,
    // or a handle along each axis and one at the corner of its box. The part
    // is drawn where it goes; the window writes the code.

    enum Gizmo { none, move, rotate, hinge, scale }

    // ---- Place on…: a corner or the centre of a face onto one of another
    // face (or the ground), the faces against each other, then the hinge
    // ring to spin the part about the target's normal

    /// 1 choosing where the anchor goes, 0 none.
    public int placing;
    public int placePart = -1;
    public Vec3 placeFrom, placeFromN;            /// the anchor carried, and its face's outward normal
    public Vec3 placeTo, placeToN;                /// where it goes, and the normal out of what it lies on
    public Vec3 placeAxis = Vec3(0, 0, 1);        /// the turn that sets the faces against each other, about placeFrom
    public double placeAngle = 0;
    public bool placeActive;                      /// that turn and the move are in the preview
    private Hit placeHover;                       /// the anchor under the pointer (part -1: the ground)
    private Vec3[] placeHoverDots;                /// the anchors of the face under the pointer
    void delegate(Vec3 to, Vec3 toNormal) onPlaceTarget;

    /// The anchors of face `face` of part `i`: the corners of its edges, their
    /// middles, the centres of its round edges, and its middle; with its
    /// outward normal.
    Vec3[] faceAnchors(size_t i, int face, out Vec3 normal)
    {
        Vec3[] r;
        if (i >= parts.length || face < 0)
            return r;
        auto p = parts[i];
        void add(Vec3 v)
        {
            foreach (q; r)
                if ((q - v).length < 1e-6)
                    return;
            r ~= v;
        }
        foreach (k, e; p.edgeInfo)
            if (k < p.edgeFaces.length && (p.edgeFaces[k][0] == face || p.edgeFaces[k][1] == face))
            {
                add(e.start);
                add(e.end);
                add(e.kind == EdgeKind.line ? (e.start + e.end) * 0.5 : e.mid);
                if (e.kind == EdgeKind.circle)
                    add(e.center);
            }
        if (p.kernel !is null && p.brep !is null)
        {
            auto fs = p.kernel.faces(p.brep);
            if (face < fs.length)
            {
                add(fs[face].center);
                normal = fs[face].normal;
            }
        }
        return r;
    }

    /// The turn (axis, degrees) that sets a face of outward normal `fromN`
    /// against a surface of outward normal `toN`, the face's normal then
    /// pointing into it: the frame on the face (as body.frame gives it) onto
    /// the frame on the surface, X onto X, so that placeOn writes it as it is.
    static void faceTurn(Vec3 fromN, Vec3 toN, out Vec3 axis, out double angle)
    {
        import hackerscad.lang.builtins : axisAngle, faceXAxis;
        fromN = fromN.normalized;
        toN = toN.normalized;
        auto xf = faceXAxis(fromN), yf = fromN.cross(xf);
        auto xt = faceXAxis(toN), yt = toN.cross(xt) * -1, zt = toN * -1;
        Vec3 col(Vec3 e) => xt * xf.dot(e) + yt * yf.dot(e) + zt * fromN.dot(e);
        angle = axisAngle(col(Vec3(1, 0, 0)), col(Vec3(0, 1, 0)), col(Vec3(0, 0, 1)), axis) * 180 / PI;
        if (angle < 1e-9)
            axis = Vec3(0, 0, 1);
    }

    /// Starts Place on… for part `part`: `from` (an anchor of its face) and that face's normal.
    public void startPlace(int part, Vec3 from, Vec3 fromNormal)
    {
        stopGizmo();
        placing = 1;
        placePart = part;
        placeFrom = from;
        placeFromN = fromNormal.normalized;
        placeHover = Hit.init;
        placeHoverDots = null;
        redraw();
    }

    public void stopPlace()
    {
        placing = 0;
        placeHover = Hit.init;
        placeHoverDots = null;
        redraw();
    }

    /// The anchor nearest the pointer on the face under it, or the ground below it.
    private void hoverPlace(double x, double y)
    {
        auto h = pick(x, y);
        placeHover = Hit.init;
        placeHoverDots = null;
        if (h.part >= 0 && h.part != placePart && h.face >= 0)
        {
            Vec3 n;
            placeHoverDots = faceAnchors(h.part, h.face, n);
            double best = double.infinity;
            foreach (a; placeHoverDots)
            {
                double ax, ay;
                if (project(a, ax, ay) && (ax - x) ^^ 2 + (ay - y) ^^ 2 < best)
                {
                    best = (ax - x) ^^ 2 + (ay - y) ^^ 2;
                    placeHover = h;
                    placeHover.point = a;
                    placeHover.normal = n.length > 0.5 ? n : h.normal;
                }
            }
        }
        else if (h.part < 0)
        {
            // the ground: whole millimetres, the normal up
            Vec3 g;
            if (onFloor(x, y, 0, g))
            {
                import std.math : round;
                placeHover.part = -1;
                placeHover.face = -2;   // the ground
                placeHover.point = Vec3(round(g.x), round(g.y), 0);
                placeHover.normal = Vec3(0, 0, 1);
                // the origin takes the pointer when near it
                double ox, oy;
                if (project(Vec3(0, 0, 0), ox, oy) && (ox - x) ^^ 2 + (oy - y) ^^ 2 < 18 * 18)
                    placeHover.point = Vec3(0, 0, 0);
            }
        }
        redraw();
    }

    /// The anchors while placing: the one carried, those of the face under the pointer, the one it would go to.
    private void drawPlace()
    {
        if (placing == 0)
            return;
        immutable carried = Vec3(0.2, 0.75, 0.35), dot = Vec3(0.55, 0.57, 0.6), target = Vec3(1.0, 0.5, 0.0);
        drawKnob(placeFrom, carried, handlePixels - 1);
        drawKnob(Vec3(0, 0, 0), dot, handlePixels - 3);   // the origin, a place to go too
        foreach (a; placeHoverDots)
            drawKnob(a, dot, handlePixels - 3);
        if (placeHover.face >= 0 || placeHover.face == -2)
        {
            drawKnob(placeHover.point, target, handlePixels);
            drawPolyline([placeFrom, placeHover.point], target, 1.5);
        }
    }

    /// The anchor clicked: the turn that sets the faces against each other,
    /// the move, then the ring about the target's normal.
    private void choosePlace()
    {
        if (!(placeHover.face >= 0 || placeHover.face == -2) || onPlaceTarget is null)
            return;
        auto to = placeHover.point, toN = placeHover.normal.normalized;
        placing = 0;
        placeHoverDots = null;
        onPlaceTarget(to, toN);
    }

    /// The preview of a placing: `to` and `toN` chosen; the hinge ring about
    /// toN through to spins it further.
    public void previewPlace(Vec3 to, Vec3 toN)
    {
        placeTo = to;
        placeToN = toN;
        faceTurn(placeFromN, toN, placeAxis, placeAngle);
        placeActive = true;
        placing = 0;   // the anchors are no longer chosen: the ring is shown
        placeHoverDots = null;
        // the ring round the part where it now lies, not where it was: from
        // far away its box would make a huge ring, and the view zoom right out
        gizmo = Gizmo.hinge;
        gizmoPart = placePart;
        gizmoMove = Vec3(0, 0, 0);
        gizmoTurns = null;
        gizmoScale = Vec3(1, 1, 1);
        hingeAngle = 0;
        hingeOrigin = to;
        hingeDir = toN.normalized;
        keepPreview = false;
        gizmoGrab = gizmoHover = -1;
        auto turn = axisTurn(placeAxis, placeAngle, placeFrom);
        auto b = parts[placePart].bbox;
        Vec3 lo = Vec3(double.max, double.max, double.max), hi = Vec3(-double.max, -double.max, -double.max);
        foreach (k; 0 .. 8)
        {
            auto c = Vec3(k & 1 ? b.max.x : b.min.x, k & 2 ? b.max.y : b.min.y, k & 4 ? b.max.z : b.min.z);
            auto q = Vec3(turn[0] * c.x + turn[4] * c.y + turn[8] * c.z + turn[12],
                turn[1] * c.x + turn[5] * c.y + turn[9] * c.z + turn[13],
                turn[2] * c.x + turn[6] * c.y + turn[10] * c.z + turn[14]) + (to - placeFrom);
            foreach (i; 0 .. 3)
            {
                lo[i] = min(lo[i], q[i]);
                hi[i] = max(hi[i], q[i]);
            }
        }
        gizmoLo = lo;
        gizmoHi = hi;
        auto middle = (lo + hi) * 0.5;
        gizmoCentre = hingeOrigin + hingeDir * (middle - hingeOrigin).dot(hingeDir);
        makeRoom();
        redraw();
    }

    /// Hinge: one ring about an axis through `hingeOrigin` along `hingeDir`
    /// (a face's normal, a hole's axis, an edge), turned by `hingeAngle`
    /// degrees, counter-clockwise looking down the direction.
    public Vec3 hingeOrigin, hingeDir = Vec3(0, 0, 1);
    public double hingeAngle = 0;

    /// A turn about one axis through the centre (0 X, 1 Y, 2 Z), in degrees.
    struct Turn
    {
        int axis;
        double angle = 0;
    }

    public Gizmo gizmo;
    public int gizmoPart = -1;
    public Vec3 gizmoMove = Vec3(0, 0, 0);   /// how far the part is moved (mm, whole)
    public Turn[] gizmoTurns;                /// the turns so far, in order (degrees, whole)
    public Vec3 gizmoCentre;                 /// what it turns about: the middle of its box
    public Vec3 gizmoScale = Vec3(1, 1, 1);  /// the factors along X, Y and Z (scale)
    public Vec3 gizmoAnchor;                 /// what stays where it is (scale): the middle of the bottom of its box
    private Vec3 gizmoLo, gizmoHi;
    // what is grabbed or under the pointer: move: 0 the frame, 1..3 the X, Y,
    // Z arrows; rotate: 1..3 the X, Y, Z rings; scale: 0 the corner, 1..3
    // the X, Y, Z handles
    private int gizmoGrab = -1, gizmoHover = -1;
    private Vec3 grabMove, grabPoint, grabScale;
    private double grabAngle, lastScreenAngle;
    private bool keepPreview;   // confirmed: the preview stays until the new parts come
    /// Told while the part moves or turns, with the pointer's window position.
    void delegate(double x, double y) onGizmo;

    static immutable Vec3[3] axes = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    static immutable Vec3[3] axisColours = [Vec3(0.85, 0.2, 0.2), Vec3(0.2, 0.65, 0.25), Vec3(0.2, 0.4, 0.9)];

    /// Shows the arrows and frame (move) or the rings (rotate) on part `part`.
    public void startGizmo(Gizmo g, int part)
    {
        gizmo = g;
        gizmoPart = part;
        gizmoMove = Vec3(0, 0, 0);
        gizmoTurns = null;
        gizmoScale = Vec3(1, 1, 1);
        hingeAngle = 0;
        auto b = parts[part].bbox;
        gizmoLo = b.min;
        gizmoHi = b.max;
        gizmoCentre = (b.min + b.max) * 0.5;
        gizmoAnchor = Vec3(gizmoCentre.x, gizmoCentre.y, b.min.z);
        keepPreview = false;
        gizmoGrab = gizmoHover = -1;
        makeRoom();
        redraw();
    }

    /// The scale gizmo's part previewed scaled by the factors `f`.
    public void previewScale(Vec3 f)
    {
        if (gizmo != Gizmo.scale)
            return;
        gizmoScale = f;
        makeRoom();
        redraw();
    }

    /// The matrix (column-major, for OpenGL) of a turn of `degrees` about the
    /// axis through `origin` along `dir`.
    static float[16] axisTurn(Vec3 dir, double degrees, Vec3 origin)
    {
        immutable a = degrees * PI / 180, c = cos(a), sn = sin(a), t = 1 - c;
        immutable x = dir.x, y = dir.y, z = dir.z;
        double[3][3] q = [[t * x * x + c, t * x * y - sn * z, t * x * z + sn * y],
            [t * x * y + sn * z, t * y * y + c, t * y * z - sn * x],
            [t * x * z - sn * y, t * y * z + sn * x, t * z * z + c]];
        float[16] r = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
        foreach (row; 0 .. 3)
            foreach (col; 0 .. 3)
                r[col * 4 + row] = cast(float) q[row][col];
        foreach (row; 0 .. 3)
        {
            double v = origin[row];
            foreach (col; 0 .. 3)
                v -= q[row][col] * origin[col];
            r[12 + row] = cast(float) v;
        }
        return r;
    }

    /// The hinge gizmo on part `part`: one ring about the axis through
    /// `origin` along `dir`, round the part, centred where the part's middle
    /// faces the axis.
    public void startHinge(int part, Vec3 origin, Vec3 dir)
    {
        hingeOrigin = origin;
        hingeDir = dir.normalized;
        startGizmo(Gizmo.hinge, part);
        gizmoCentre = hingeOrigin + hingeDir * (gizmoCentre - hingeOrigin).dot(hingeDir);
        makeRoom();
        redraw();
    }

    /// The hinge ring's radius: past the part's farthest corner from the axis.
    private double hingeRadius()
    {
        double r = 0;
        foreach (k; 0 .. 8)
        {
            auto c = Vec3(k & 1 ? gizmoHi.x : gizmoLo.x, k & 2 ? gizmoHi.y : gizmoLo.y, k & 4 ? gizmoHi.z : gizmoLo.z) - hingeOrigin;
            r = max(r, (c - hingeDir * c.dot(hingeDir)).length);
        }
        return max(8.0, r * 1.08 + 3);
    }

    /// The point of the hinge ring at angle a (degrees).
    private Vec3 hingePoint(double a)
    {
        auto u = (abs(hingeDir.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)).cross(hingeDir).normalized;
        auto v = hingeDir.cross(u);
        immutable r = a * PI / 180;
        return gizmoCentre + (u * cos(r) + v * sin(r)) * hingeRadius();
    }

    private Vec3[] hingeRing()
    {
        Vec3[] pts;
        foreach (n; 0 .. 97)
            pts ~= hingePoint(360.0 * n / 96);
        return pts;
    }

    /// The points that outline the gizmo shown, for the buttons and the zoom.
    private Vec3[] gizmoOutline()
    {
        Vec3[] pts;
        if (gizmo == Gizmo.move)
            pts = gizmoFrame()[] ~ [arrowTip(0), arrowTip(1), arrowTip(2)];
        else if (gizmo == Gizmo.scale)
            pts = scaledBox()[] ~ [scaleTip(0), scaleTip(1), scaleTip(2), scaleCorner()];
        else if (gizmo == Gizmo.rotate)
            foreach (k; 0 .. 3)
                foreach (n; 0 .. 24)
                    pts ~= ringPoint(k, 15.0 * n);
        else if (gizmo == Gizmo.hinge)
            foreach (n; 0 .. 24)
                pts ~= hingePoint(15.0 * n);
        return pts;
    }

    /// Zooms out, if needed, until the tool open (the frame or rings, the
    /// split's plane) and its buttons show whole, 30 pixels in from the
    /// sides: once, when the tool opens; never closer, never while dragging.
    public void makeRoom()
    {
        immutable w = area.getWidth(), h = area.getHeight();
        if (w <= 0 || h <= 0)
            return;
        Vec3[] shown()
        {
            auto pts = gizmoOutline();
            if (gizmo == Gizmo.none && section && sectionPart >= 0)
                pts = sectionQuad()[].dup;
            foreach (which; [ViewButton.sectionClose, ViewButton.sectionAccept, ViewButton.gizmoCancel,
                    ViewButton.gizmoAccept])
            {
                Vec3 spot;
                if (buttonSpot(which, spot))
                    pts ~= spot;
            }
            return pts;
        }
        enum margin = 30;
        bool zoomed;
        foreach (_; 0 .. 40)
        {
            bool fits = true;
            foreach (p; shown())
            {
                double x, y;
                if (!project(p, x, y) || x < margin || y < margin || x > w - margin || y > h - margin)
                {
                    fits = false;
                    break;
                }
            }
            if (fits)
                break;
            distance *= 1.12;
            zoomed = true;
        }
        if (zoomed)
        {
            moved();
            redraw();
        }
    }

    /// Takes them away; `keep` leaves the part drawn where it went until the
    /// model is evaluated again (the code was written).
    public void stopGizmo(bool keep = false)
    {
        gizmo = Gizmo.none;
        gizmoGrab = gizmoHover = -1;
        keepPreview = keep;
        if (!keep)
        {
            gizmoPart = -1;
            hingeAngle = 0;
            gizmoScale = Vec3(1, 1, 1);
            placeActive = false;
        }
        redraw();
    }

    /// How far the part is turned about each axis, all turns added.
    private double turnedAbout(int axis)
    {
        double a = 0;
        foreach (t; gizmoTurns)
            if (t.axis == axis)
                a += t.angle;
        return a;
    }

    /// Where the moved or turned part is drawn: the matrix that carries it
    /// (the turns in order about the centre, then the move).
    private float[16] partMatrix()
    {
        float[16] m = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
        // scaled about the anchor, which stays where it is
        foreach (i; 0 .. 3)
        {
            m[i * 4 + i] = cast(float) gizmoScale[i];
            m[12 + i] = cast(float)(gizmoAnchor[i] * (1 - gizmoScale[i]));
        }
        foreach (t; gizmoTurns)
        {
            if (t.angle == 0)
                continue;
            // translate(c) * rotate * translate(-c), applied after what came before
            immutable a = t.angle * PI / 180, c = cos(a), s = sin(a);
            immutable i = (t.axis + 1) % 3, j = (t.axis + 2) % 3;
            float[16] r = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
            r[i * 4 + i] = c;
            r[j * 4 + j] = c;
            r[i * 4 + j] = s;    // column i, row j
            r[j * 4 + i] = -s;
            immutable o = gizmoCentre;
            foreach (row; 0 .. 3)
            {
                double v = o[row];
                foreach (q; 0 .. 3)
                    v -= r[q * 4 + row] * o[q];
                r[12 + row] = cast(float) v;
            }
            m = multiply(r, m);
        }
        if (placeActive)
        {
            // the turn about the anchor, then the anchor onto its target
            m = multiply(axisTurn(placeAxis, placeAngle, placeFrom), m);
            auto to = placeTo - placeFrom;
            m[12] += to.x;
            m[13] += to.y;
            m[14] += to.z;
        }
        if (hingeAngle != 0)   // also after ✓, until the new parts come
        {
            // about the hinge's axis: Rodrigues' rotation, then back through its origin
            immutable a = hingeAngle * PI / 180, c = cos(a), sn = sin(a), t = 1 - c;
            immutable x = hingeDir.x, y = hingeDir.y, z = hingeDir.z;
            double[3][3] q = [[t * x * x + c, t * x * y - sn * z, t * x * z + sn * y],
                [t * x * y + sn * z, t * y * y + c, t * y * z - sn * x],
                [t * x * z - sn * y, t * y * z + sn * x, t * z * z + c]];
            float[16] r = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
            foreach (row; 0 .. 3)
                foreach (col; 0 .. 3)
                    r[col * 4 + row] = cast(float) q[row][col];
            immutable o = hingeOrigin;
            foreach (row; 0 .. 3)
            {
                double v = o[row];
                foreach (col; 0 .. 3)
                    v -= q[row][col] * o[col];
                r[12 + row] = cast(float) v;
            }
            m = multiply(r, m);
        }
        m[12] += gizmoMove.x;
        m[13] += gizmoMove.y;
        m[14] += gizmoMove.z;
        return m;
    }

    /// Where part i is drawn (none when i is -1): moved or turned in the preview.
    private void forPart(long i)
    {
        static immutable float[16] none = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
        if (previewing(i))
        {
            auto m = partMatrix();
            glUniformMatrix4fv(uModel, 1, GL_FALSE, m.ptr);
        }
        else
            glUniformMatrix4fv(uModel, 1, GL_FALSE, none.ptr);
    }

    /// Whether part i is drawn moved or turned (the preview).
    bool previewing(long i) => i >= 0 && i == gizmoPart && (gizmo != Gizmo.none || keepPreview);

    /// A point of the previewed part where it is drawn, and back.
    Vec3 placed(Vec3 p)
    {
        auto m = partMatrix();
        return Vec3(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12], m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
            m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14]);
    }

    /// A direction of the previewed part, from as drawn back to its own.
    Vec3 unplacedDir(Vec3 d) => inverseApplied(d, false);

    /// A face normal of the previewed part as drawn: by the inverse
    /// transpose, so that it stays square to the face when the part is
    /// scaled more along one axis (the hover mark round it stays round).
    Vec3 placedNormal(Vec3 n) => inverseApplied(n, true).normalized;

    /// The inverse of the part's 3 by 3 (turned and scaled), by its
    /// cofactors, applied to `d`; `transposed`: its transpose instead.
    private Vec3 inverseApplied(Vec3 d, bool transposed)
    {
        auto m = partMatrix();
        double a(int row, int col) => m[col * 4 + row];
        immutable det = a(0, 0) * (a(1, 1) * a(2, 2) - a(1, 2) * a(2, 1)) - a(0, 1) * (a(1, 0) * a(2, 2) - a(1, 2) * a(2, 0))
            + a(0, 2) * (a(1, 0) * a(2, 1) - a(1, 1) * a(2, 0));
        if (abs(det) < 1e-12)
            return d;
        double inv(int row, int col)
        {
            if (transposed)
            {
                immutable t = row;
                row = col;
                col = t;
            }
            immutable r0 = (col + 1) % 3, r1 = (col + 2) % 3, c0 = (row + 1) % 3, c1 = (row + 2) % 3;
            return (a(r0, c0) * a(r1, c1) - a(r0, c1) * a(r1, c0)) / det;
        }
        return Vec3(inv(0, 0) * d.x + inv(0, 1) * d.y + inv(0, 2) * d.z, inv(1, 0) * d.x + inv(1, 1) * d.y + inv(1, 2) * d.z,
            inv(2, 0) * d.x + inv(2, 1) * d.y + inv(2, 2) * d.z);
    }

    Vec3 unplaced(Vec3 p)
    {
        auto m = partMatrix();
        return unplacedDir(p - Vec3(m[12], m[13], m[14]));
    }

    /// The edge's points where part i draws it (moved or turned in the preview).
    Vec3[] edgePoints(long i, EdgeInfo e)
    {
        auto pts = edgePolyline(e);
        if (previewing(i))
            foreach (ref q; pts)
                q = placed(q);
        return pts;
    }

    /// The frame under the moved part.
    private Vec3[4] gizmoFrame()
    {
        immutable m = max(2.0, 0.1 * max(gizmoHi.x - gizmoLo.x, gizmoHi.y - gizmoLo.y));
        immutable z = gizmoLo.z + gizmoMove.z;
        immutable x0 = gizmoLo.x - m + gizmoMove.x, x1 = gizmoHi.x + m + gizmoMove.x;
        immutable y0 = gizmoLo.y - m + gizmoMove.y, y1 = gizmoHi.y + m + gizmoMove.y;
        return [Vec3(x0, y0, z), Vec3(x1, y0, z), Vec3(x1, y1, z), Vec3(x0, y1, z)];
    }

    /// Where the arrows start: the middle of the moved part.
    private Vec3 arrowFoot() => gizmoCentre + gizmoMove;

    /// The tip of the arrow along axis a: past the part's side.
    private Vec3 arrowTip(int a)
    {
        immutable half = (gizmoHi[a] - gizmoLo[a]) / 2;
        return arrowFoot() + axes[a] * (half + max(6.0, 0.25 * (gizmoHi - gizmoLo).length));
    }

    private double ringRadius() => max(8.0, 0.6 * (gizmoHi - gizmoLo).length);

    /// A point of the part's box (unscaled) where the scale puts it.
    private Vec3 scaledPoint(Vec3 p) => Vec3(gizmoAnchor.x + (p.x - gizmoAnchor.x) * gizmoScale.x,
        gizmoAnchor.y + (p.y - gizmoAnchor.y) * gizmoScale.y, gizmoAnchor.z + (p.z - gizmoAnchor.z) * gizmoScale.z);

    /// The corners of the scaled box: the bottom four, then the top four.
    private Vec3[8] scaledBox()
    {
        Vec3[8] r;
        foreach (k; 0 .. 8)
        {
            immutable c = k & 3;   // round the bottom, then the top
            r[k] = scaledPoint(Vec3(c == 1 || c == 2 ? gizmoHi.x : gizmoLo.x, c >= 2 ? gizmoHi.y : gizmoLo.y,
                k >= 4 ? gizmoHi.z : gizmoLo.z));
        }
        return r;
    }

    /// The middle of the scaled box.
    private Vec3 scaleFoot() => scaledPoint(gizmoCentre);

    /// How far past the box the handles reach (mm).
    private double scaleReach() => max(6.0, 0.25 * (gizmoHi - gizmoLo).length);

    /// The knob of the handle along axis a: past the scaled box's side, out
    /// from its middle; it follows the side as the part stretches.
    private Vec3 scaleTip(int a)
    {
        auto p = scaleFoot();
        p[a] = scaledPoint(gizmoHi)[a] + scaleReach();
        return p;
    }

    /// The uniform knob: past the scaled box's top corner, away from the anchor.
    private Vec3 scaleCorner()
    {
        auto c = scaledPoint(gizmoHi);
        auto d = c - gizmoAnchor;
        return d.length > 1e-9 ? c + d.normalized * (0.5 * scaleReach()) : c + Vec3(1, 1, 1) * scaleReach();
    }

    /// The point of ring k (about axis k, through the centre) at angle a (degrees).
    private Vec3 ringPoint(int k, double a)
    {
        auto u = axes[(k + 1) % 3], v = axes[(k + 2) % 3];
        immutable r = a * PI / 180;
        return gizmoCentre + (u * cos(r) + v * sin(r)) * ringRadius();
    }

    private Vec3[] gizmoRing(int k)
    {
        Vec3[] pts;
        foreach (n; 0 .. 97)
            pts ~= ringPoint(k, 360.0 * n / 96);
        return pts;
    }

    /// Where ring k's knob is: it goes round with the turns about its axis.
    private Vec3 ringKnob(int k) => ringPoint(k, 45 + turnedAbout(k));

    /// What is at window point (x, y): move: 1..3 an arrow (X, Y, Z), 0 the
    /// frame; rotate: 1..3 a ring. -1: nothing.
    int gizmoAt(double x, double y)
    {
        double near(Vec3[] pts)
        {
            double best = double.max;
            double ax, ay, bx, by;
            foreach (n; 0 .. pts.length - 1)
                if (project(pts[n], ax, ay) && project(pts[n + 1], bx, by))
                {
                    immutable dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
                    immutable t = l2 > 0 ? clamp(((x - ax) * dx + (y - ay) * dy) / l2, 0.0, 1.0) : 0;
                    best = min(best, sqrt((ax + t * dx - x) ^^ 2 + (ay + t * dy - y) ^^ 2));
                }
            return best;
        }
        bool onKnob(Vec3 p)
        {
            double px, py;
            return project(p, px, py) && abs(px - x) <= handlePixels + 2 && abs(py - y) <= handlePixels + 2;
        }
        if (gizmo == Gizmo.move)
        {
            // the knobs at the tips first, then the shafts, then the frame
            foreach (a; 0 .. 3)
                if (onKnob(arrowTip(a)))
                    return a + 1;
            int best = -1;
            double bestD = handlePixels;
            foreach (a; 0 .. 3)
            {
                immutable d = near([arrowFoot(), arrowTip(a)]);
                if (d <= bestD)
                {
                    bestD = d;
                    best = a + 1;
                }
            }
            if (best >= 0)
                return best;
            auto f = gizmoFrame();
            if (near([f[0], f[1], f[2], f[3], f[0]]) <= handlePixels)
                return 0;
            // inside the frame, as seen
            double[4] px, py;
            foreach (n; 0 .. 4)
                if (!project(f[n], px[n], py[n]))
                    return -1;
            bool inside;
            foreach (n; 0 .. 4)
            {
                immutable m = (n + 3) % 4;
                if ((py[n] > y) != (py[m] > y) && x < (px[m] - px[n]) * (y - py[n]) / (py[m] - py[n]) + px[n])
                    inside = !inside;
            }
            return inside ? 0 : -1;
        }
        if (gizmo == Gizmo.scale)
        {
            // the knobs first, the corner's before the axes', then the shafts
            if (onKnob(scaleCorner()))
                return 0;
            foreach (a; 0 .. 3)
                if (onKnob(scaleTip(a)))
                    return a + 1;
            int best = -1;
            double bestD = handlePixels;
            foreach (a; 0 .. 3)
            {
                immutable d = near([scaleFoot(), scaleTip(a)]);
                if (d <= bestD)
                {
                    bestD = d;
                    best = a + 1;
                }
            }
            if (best < 0 && near([gizmoAnchor, scaleCorner()]) <= handlePixels)
                best = 0;
            return best;
        }
        if (gizmo == Gizmo.hinge)
            return onKnob(hingePoint(45 + hingeAngle)) || near(hingeRing()) < handlePixels + 1 ? 1 : -1;
        if (gizmo == Gizmo.rotate)
        {
            foreach (k; 0 .. 3)
                if (onKnob(ringKnob(k)))
                    return k + 1;
            int best = -1;
            double bestD = handlePixels + 1;
            foreach (k; 0 .. 3)
            {
                immutable d = near(gizmoRing(k));
                if (d < bestD)
                {
                    bestD = d;
                    best = k + 1;
                }
            }
            return best;
        }
        return -1;
    }

    /// Where a window point's line of sight meets the plane z = h.
    private bool onFloor(double x, double y, double h, out Vec3 p)
    {
        Vec3 o, d;
        ray(x, y, o, d);
        if (abs(d.z) < 0.05)
            return false;
        immutable t = (h - o.z) / d.z;
        p = o + d * t;
        return t > 0;
    }

    /// The pointer's angle about the centre as seen (degrees, counter-clockwise).
    private double screenAngle(double x, double y)
    {
        import std.math : atan2;
        double cx, cy;
        project(gizmoCentre, cx, cy);
        return atan2(-(y - cy), x - cx) * 180 / PI;
    }

    private void grabGizmo(double x, double y)
    {
        grabMove = gizmoMove;
        grabScale = gizmoScale;
        if (gizmo == Gizmo.scale && gizmoGrab > 0)
            grabPoint = scaleTip(gizmoGrab - 1);   // where the drag is measured from: the knob as grabbed
        if (gizmo == Gizmo.move && gizmoGrab == 0)
            onFloor(x, y, gizmoLo.z + gizmoMove.z, grabPoint);
        if (gizmo == Gizmo.hinge)
        {
            grabAngle = hingeAngle;
            lastScreenAngle = screenAngle(x, y);
        }
        if (gizmo == Gizmo.rotate)
        {
            // another axis than the last turn's: a new turn after it
            immutable axis = gizmoGrab - 1;
            if (gizmoTurns.length == 0 || gizmoTurns[$ - 1].axis != axis)
                gizmoTurns ~= Turn(axis, 0);
            grabAngle = gizmoTurns[$ - 1].angle;
            lastScreenAngle = screenAngle(x, y);
        }
    }

    /// Whole millimetres (or degrees), and, unless Shift is held, the
    /// nearest multiple of `snap` when within `pull` of it.
    static double rounded(double v, double snap, double pull, bool free)
    {
        import std.math : round;
        immutable whole = round(v);
        if (free)
            return whole;
        immutable s = round(v / snap) * snap;
        return abs(v - s) <= pull ? s : whole;
    }

    /// A factor in steps of 0.05 (Shift: 0.01), never below one step.
    static double scaleStep(double f, bool free)
    {
        import std.math : round;
        immutable step = free ? 0.01 : 0.05;
        return max(step, round(f / step) * step);
    }

    /// How far (mm) the pointer went along direction `dir` from `foot`, as seen.
    private double alongOnScreen(Vec3 foot, Vec3 dir, double dx, double dy)
    {
        immutable step = 50 * mmPerPixelAt(foot);
        double ax, ay, bx, by;
        if (project(foot, ax, ay) && project(foot + dir * step, bx, by) && (bx - ax) ^^ 2 + (by - ay) ^^ 2 > 25)
            return (dx * (bx - ax) + dy * (by - ay)) / ((bx - ax) ^^ 2 + (by - ay) ^^ 2) * step;
        return -dy * mmPerPixelAt(foot);
    }

    private void dragGizmo(double x, double y, double dx, double dy, bool free)
    {
        if (gizmo == Gizmo.scale)
        {
            if (gizmoGrab == 0)
            {
                // the corner: all three alike, as far as it went along the
                // diagonal from the anchor, against how long that diagonal is
                auto d = Vec3((gizmoHi.x - gizmoAnchor.x) * grabScale.x, (gizmoHi.y - gizmoAnchor.y) * grabScale.y,
                    (gizmoHi.z - gizmoAnchor.z) * grabScale.z);
                if (d.length > 1e-9)
                {
                    immutable k = 1 + alongOnScreen(gizmoAnchor + d, d.normalized, dx, dy) / d.length;
                    if (grabScale.x == grabScale.y && grabScale.y == grabScale.z)
                        gizmoScale = Vec3(1, 1, 1) * scaleStep(grabScale.x * k, free);
                    else
                    {
                        immutable ks = scaleStep(k, free);
                        gizmoScale = grabScale * ks;
                    }
                }
            }
            else
            {
                // a handle: its side follows the pointer along the axis
                immutable a = gizmoGrab - 1;
                immutable half = gizmoHi[a] - gizmoAnchor[a];
                if (half > 1e-9)
                {
                    auto m = grabScale;
                    m[a] = scaleStep(grabScale[a] + alongOnScreen(grabPoint, axes[a], dx, dy) / half, free);
                    gizmoScale = m;
                }
            }
        }
        else if (gizmo == Gizmo.move && gizmoGrab == 0)
        {
            Vec3 p;
            Vec3 raw;
            if (onFloor(x, y, gizmoLo.z + grabMove.z, p) && grabPoint.length == grabPoint.length)
                raw = grabMove + Vec3(p.x - grabPoint.x, p.y - grabPoint.y, 0);
            else
            {
                // the floor seen edge on: along the screen, as a pan
                auto b = basis();
                immutable k = mmPerPixelAt(gizmoCentre);
                auto d = b.right * (dx * k) - b.up * (dy * k);
                raw = grabMove + Vec3(d.x, d.y, 0);
            }
            gizmoMove = Vec3(rounded(raw.x, 5, 1, free), rounded(raw.y, 5, 1, free), grabMove.z);
        }
        else if (gizmo == Gizmo.move)
        {
            // an arrow: along its axis, as far as the pointer went along it on screen
            immutable a = gizmoGrab - 1;
            auto foot = gizmoCentre + grabMove;
            immutable step = 50 * mmPerPixelAt(foot);
            double ax, ay, bx, by, moved;
            if (project(foot, ax, ay) && project(foot + axes[a] * step, bx, by)
                && (bx - ax) ^^ 2 + (by - ay) ^^ 2 > 25)
                moved = (dx * (bx - ax) + dy * (by - ay)) / ((bx - ax) ^^ 2 + (by - ay) ^^ 2) * step;
            else
                moved = -dy * mmPerPixelAt(foot);
            auto m = grabMove;
            m[a] = rounded(grabMove[a] + moved, 5, 1, free);
            gizmoMove = m;
        }
        else
        {
            // a turn: how far the pointer went round the centre, as seen;
            // positive counter-clockwise when the axis points at the viewer
            auto now = screenAngle(x, y);
            auto step = now - lastScreenAngle;
            while (step > 180)
                step -= 360;
            while (step < -180)
                step += 360;
            lastScreenAngle = now;
            if (gizmo == Gizmo.hinge)
            {
                immutable facing = hingeDir.dot(basis().eye - gizmoCentre) >= 0 ? 1 : -1;
                grabAngle += step * facing;
                hingeAngle = rounded(grabAngle, 15, 3, free);
            }
            else
            {
                auto turn = &gizmoTurns[$ - 1];
                immutable facing = axes[turn.axis].dot(basis().eye - gizmoCentre) >= 0 ? 1 : -1;
                grabAngle += step * facing;
                turn.angle = rounded(grabAngle, 15, 3, free);
            }
        }
        if (onGizmo !is null)
            onGizmo(x, y);
        redraw();
    }

    /// A knob: a filled square facing the viewer, `pixels` from its middle to its side.
    private void drawKnob(Vec3 p, Vec3 colour, double pixels)
    {
        auto b = basis();
        immutable r = pixels * mmPerPixelAt(p);
        auto ru = b.right * r, rv = b.up * r;
        Vec3[4] c = [p + ru + rv, p - ru + rv, p - ru - rv, p + ru - rv];
        float[] fill;
        foreach (i; [0, 1, 2, 0, 2, 3])
            fill ~= [cast(float) c[i].x, cast(float) c[i].y, cast(float) c[i].z];
        uploadLines(fill);
        glUniform1i(uFlat, 1);
        glUniform1f(uAlpha, 1);
        glUniform3f(uColor, cast(float) colour.x, cast(float) colour.y, cast(float) colour.z);
        glDisable(GL_DEPTH_TEST);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glEnable(GL_DEPTH_TEST);
        drawPolyline([c[0], c[1], c[2], c[3], c[0]], Vec3(1, 1, 1), 1.5);
    }

    /// The arrows and frame, or the three rings, over everything.
    private void drawGizmo()
    {
        if (gizmo == Gizmo.none)
            return;
        bool live(int k) => k == gizmoGrab || (gizmoGrab < 0 && k == gizmoHover);
        Vec3 lit(Vec3 c, bool on) => on ? c * 0.6 + Vec3(0.4, 0.4, 0.4) : c;
        if (gizmo == Gizmo.move)
        {
            immutable orange = gizmoPart >= 0 && gizmoPart < parts.length
                ? standOut(parts[gizmoPart].rgb, Vec3(0.95, 0.45, 0.1), Vec3(0.2, 0.4, 1.0), 0.32) : Vec3(0.95, 0.45, 0.1);
            auto f = gizmoFrame();
            drawPolyline([f[0], f[1], f[2], f[3], f[0]], lit(orange, live(0)), live(0) ? 4 : 2);
            foreach (a; 0 .. 3)
            {
                auto c = lit(axisColours[a], live(a + 1));
                drawPolyline([arrowFoot(), arrowTip(a)], c, live(a + 1) ? 4 : 2.5);
                drawKnob(arrowTip(a), c, live(a + 1) ? handlePixels + 2 : handlePixels);
            }
            return;
        }
        if (gizmo == Gizmo.scale)
        {
            // the scaled box, the handles out of its middle, the corner's
            // knob on the diagonal from the anchor: in a colour none of the
            // axes has, whichever stands out on the part
            immutable orange = gizmoPart >= 0 && gizmoPart < parts.length
                ? standOut(parts[gizmoPart].rgb, Vec3(0.8, 0.25, 0.85), Vec3(0.95, 0.7, 0.1), 0.32) : Vec3(0.8, 0.25, 0.85);
            auto b = scaledBox();
            drawPolyline([b[0], b[1], b[2], b[3], b[0]], orange, 1.5);
            drawPolyline([b[4], b[5], b[6], b[7], b[4]], orange, 1.5);
            foreach (k; 0 .. 4)
                drawPolyline([b[k], b[k + 4]], orange, 1.5);
            foreach (a; 0 .. 3)
            {
                auto c = lit(axisColours[a], live(a + 1));
                drawPolyline([scaleFoot(), scaleTip(a)], c, live(a + 1) ? 4 : 2.5);
                drawKnob(scaleTip(a), c, live(a + 1) ? handlePixels + 2 : handlePixels);
            }
            drawPolyline([scaledPoint(gizmoHi), scaleCorner()], lit(orange, live(0)), live(0) ? 4 : 2.5);
            drawKnob(scaleCorner(), lit(orange, live(0)), live(0) ? handlePixels + 3 : handlePixels + 1);
            drawKnob(gizmoAnchor, Vec3(0.55, 0.57, 0.6), handlePixels - 3);   // what stays where it is
            return;
        }
        if (gizmo == Gizmo.hinge)
        {
            // the axis through the ring, dashed by its two ends, then the ring and its knob
            immutable hc = gizmoPart >= 0 && gizmoPart < parts.length
                ? standOut(parts[gizmoPart].rgb, Vec3(0.95, 0.45, 0.1), Vec3(0.2, 0.4, 1.0), 0.32) : Vec3(0.95, 0.45, 0.1);
            immutable reach = hingeRadius() * 1.3;
            drawPolyline([gizmoCentre - hingeDir * reach, gizmoCentre + hingeDir * reach], hc, 1.5);
            drawPolyline(hingeRing(), lit(hc, live(1)), live(1) ? 4 : 2);
            drawKnob(hingePoint(45 + hingeAngle), lit(hc, live(1)), live(1) ? handlePixels + 2 : handlePixels);
            return;
        }
        foreach (k; 0 .. 3)
        {
            auto c = lit(axisColours[k], live(k + 1));
            drawPolyline(gizmoRing(k), c, live(k + 1) ? 4 : 2);
            drawKnob(ringKnob(k), c, live(k + 1) ? handlePixels + 2 : handlePixels);
        }
    }

    /// The handle of the section plane at window point (x, y), or -1.
    int handleAt(double x, double y)
    {
        if (!section)
            return -1;
        auto q = sectionQuad();
        foreach (k; 0 .. 4)
        {
            double hx, hy;
            if (project(q[k], hx, hy) && abs(hx - x) <= handlePixels && abs(hy - y) <= handlePixels)
                return k;
        }
        // anywhere on the plane, where no part is in front of it
        Vec3 o, d;
        ray(x, y, o, d);
        auto n = sectionNormal.normalized;
        immutable denom = d.dot(n);
        if (abs(denom) < 1e-9)
            return -1;
        immutable t = (q[0] - o).dot(n) / denom;
        if (t <= 0)
            return -1;
        auto at = o + d * t;
        foreach (k; 0 .. 4)
            if ((q[(k + 1) % 4] - q[k]).cross(at - q[k]).dot(n) * (q[1] - q[0]).cross(q[2] - q[1]).dot(n) < 0)
                return -1;
        auto under = pick(x, y);
        if (under.part >= 0 && (under.point - o).dot(d) < t - 1e-6)
            return -1;
        sectionGrab = at;
        return 4;
    }

    /// Where the X that closes the section is: past the plane's corner that
    /// is highest and rightmost on screen, `closeGap` pixels out along the
    /// diagonal as seen.
    Vec3 closeSpot()
    {
        auto q = sectionQuad();
        double[4] x, y;
        foreach (k; 0 .. 4)
            project(q[k], x[k], y[k]);
        int best = 0;
        foreach (k; 1 .. 4)
            if (x[k] - y[k] > x[best] - y[best])
                best = k;
        auto centre = (q[0] + q[2]) * 0.5;
        double cx, cy;
        project(centre, cx, cy);
        immutable dx = x[best] - cx, dy = y[best] - cy, len = max(1e-6, sqrt(dx * dx + dy * dy));
        auto b = basis();
        immutable k = closeGap * mmPerPixelAt(q[best]) / len;
        return q[best] + b.right * (dx * k) - b.up * (dy * k);
    }

    enum closeGap = 40;   // pixels from the corner: clear of the handles and arrows

    /// `spot` moved `pixels` along the screen's right (negative: left).
    private Vec3 besideOnScreen(Vec3 spot, double pixels) => spot + basis().right * (pixels * mmPerPixelAt(spot));

    /// Where button `which` is, if it is shown.
    bool buttonSpot(ViewButton which, out Vec3 spot)
    {
        enum step = 2 * handlePixels + 16;   // from one button to the next, pixels
        final switch (which)
        {
        case ViewButton.none:
            return false;
        // past the corner, out of the handle's way: the ✓ first, the X on its right
        case ViewButton.sectionClose:
            if (!section)
                return false;
            spot = sectionPart >= 0 ? besideOnScreen(closeSpot(), step) : closeSpot();
            return true;
        case ViewButton.sectionAccept:
            if (!section || sectionPart < 0)
                return false;
            spot = closeSpot();
            return true;
        case ViewButton.gizmoCancel, ViewButton.gizmoAccept:
            if (gizmo == Gizmo.none)
                return false;
            spot = gizmoCorner();
            if (which == ViewButton.gizmoCancel)
                spot = besideOnScreen(spot, step);
            return true;
        }
    }

    /// Past the top right of the frame and arrows (move) or the rings
    /// (rotate) as seen, `closeGap` pixels out: where their X goes.
    private Vec3 gizmoCorner()
    {
        auto pts = gizmoOutline();
        int best = -1;
        double bx = 0, by = 0, cx = 0, cy = 0;
        int seen;
        foreach (i, p; pts)
        {
            double x, y;
            if (!project(p, x, y))
                continue;
            cx += x;
            cy += y;
            seen++;
            if (best < 0 || x - y > bx - by)
            {
                best = cast(int) i;
                bx = x;
                by = y;
            }
        }
        if (best < 0)
            return gizmoCentre;
        cx /= seen;
        cy /= seen;
        immutable dx = bx - cx, dy = by - cy, len = max(1e-6, sqrt(dx * dx + dy * dy));
        auto b = basis();
        immutable k = closeGap * mmPerPixelAt(pts[best]) / len;
        return pts[best] + b.right * (dx * k) - b.up * (dy * k);
    }

    /// The button at window point (x, y), if any.
    ViewButton buttonAt(double x, double y)
    {
        foreach (which; [ViewButton.gizmoAccept, ViewButton.gizmoCancel, ViewButton.sectionAccept, ViewButton.sectionClose])
        {
            Vec3 spot;
            double cx, cy;
            if (buttonSpot(which, spot) && project(spot, cx, cy)
                && abs(cx - x) <= handlePixels + 4 && abs(cy - y) <= handlePixels + 4)
                return which;
        }
        return ViewButton.none;
    }

    /// Whether window point (x, y) is on the X that closes the section.
    bool closeAt(double x, double y) => buttonAt(x, y) == ViewButton.sectionClose;

    /// The buttons shown: a square facing the viewer, the same size at any
    /// zoom, with an X (red under the pointer) or a ✓ (green under it).
    void drawButtons()
    {
        auto b = basis();
        glDisable(GL_DEPTH_TEST);
        glUniform1i(uFlat, 1);
        glUniform1f(uAlpha, 1);
        foreach (which; [ViewButton.sectionClose, ViewButton.sectionAccept, ViewButton.gizmoCancel, ViewButton.gizmoAccept])
        {
            Vec3 spot;
            if (!buttonSpot(which, spot))
                continue;
            immutable accept = which == ViewButton.sectionAccept || which == ViewButton.gizmoAccept;
            immutable live = which == hoverButton;
            immutable r = (handlePixels + 4) * mmPerPixelAt(spot);
            auto ru = b.right * r, rv = b.up * r;
            Vec3[4] c = [spot + ru + rv, spot - ru + rv, spot - ru - rv, spot + ru - rv];
            float[] fill, mark;
            foreach (i; [0, 1, 2, 0, 2, 3])
                fill ~= [cast(float) c[i].x, cast(float) c[i].y, cast(float) c[i].z];
            Vec3[] strokes;
            if (accept)
            {
                // a tick: down to the bottom third, then up to the right; each
                // stroke runs a little past the corner, so thick lines meet without a notch
                auto start = spot - ru * 0.5 + rv * 0.05, corner = spot - ru * 0.1 - rv * 0.35, end = spot + ru * 0.55 + rv * 0.5;
                auto past = (corner - start).normalized * (0.12 * r), back = (corner - end).normalized * (0.12 * r);
                strokes = [start, corner + past, corner + back, end];
            }
            else
                strokes = [spot + (c[0] - spot) * 0.55, spot + (c[2] - spot) * 0.55, spot + (c[1] - spot) * 0.55,
                    spot + (c[3] - spot) * 0.55];
            foreach (e; strokes)
                mark ~= [cast(float) e.x, cast(float) e.y, cast(float) e.z];
            // on the dark style a dark square with brighter marks: a white one glares there
            immutable Vec3 colour = accept ? Vec3(0.2, 0.62, 0.3) : Vec3(0.85, 0.2, 0.15);
            immutable Vec3 ink = darkStyle ? (accept ? Vec3(0.45, 0.88, 0.5) : Vec3(1.0, 0.45, 0.4))
                : (accept ? Vec3(0.15, 0.55, 0.25) : Vec3(0.85, 0.25, 0.15));
            immutable Vec3 paper = darkStyle ? Vec3(0.17, 0.18, 0.2) : Vec3(1, 1, 1);
            uploadLines(fill);
            auto f = live ? colour : paper;
            glUniform3f(uColor, cast(float) f.x, cast(float) f.y, cast(float) f.z);
            glDrawArrays(GL_TRIANGLES, 0, 6);
            // a rim, so the square shows on any background
            drawPolyline([c[0], c[1], c[2], c[3], c[0]], live ? colour : darkStyle ? Vec3(0.55, 0.57, 0.6) : Vec3(0.7, 0.71, 0.73), 1.5);
            glDisable(GL_DEPTH_TEST);   // the rim turned it back on
            uploadLines(mark);
            glUniform1i(uFlat, 1);
            auto m = live ? Vec3(1, 1, 1) : ink;
            glUniform3f(uColor, cast(float) m.x, cast(float) m.y, cast(float) m.z);
            glLineWidth(3);
            glDrawArrays(GL_LINES, 0, 4);
            glLineWidth(1);
        }
        glEnable(GL_DEPTH_TEST);
    }

    /// How big a handle is on screen, from its centre to its side (pixels).
    enum handlePixels = 7;

    /// Millimetres per pixel at the depth of p.
    double mmPerPixelAt(Vec3 p)
    {
        auto b = basis();
        immutable z = orthographic ? distance : max(1e-6, (p - b.eye).dot(b.forward));
        return 2 * z * tan(fovy / 2) / max(1, area.getHeight());
    }

    /// Moves the section plane with the handle dragged by (dx, dy) pixels:
    /// along its normal as far as the pointer went along the normal on screen.
    void dragHandle(double dx, double dy)
    {
        auto corner = (sectionHandle == 4 ? sectionGrab : sectionQuad()[sectionHandle])
            + sectionNormal * (handleStartOffset - sectionOffset);
        immutable step = 50 * mmPerPixelAt(corner);
        double ax, ay, bx, by;
        double moved;
        if (project(corner, ax, ay) && project(corner + sectionNormal * step, bx, by)
            && (bx - ax) ^^ 2 + (by - ay) ^^ 2 > 25)
            moved = (dx * (bx - ax) + dy * (by - ay)) / ((bx - ax) ^^ 2 + (by - ay) ^^ 2) * step;
        else
            // the normal points at the viewer: up moves the plane towards it
            moved = -dy * mmPerPixelAt(corner);
        if (onSectionDrag !is null)
            onSectionDrag(handleStartOffset + moved);
    }

    /// The handles at the corners of the section plane: squares facing the
    /// viewer, the same size on screen at any zoom, never hidden by the parts.
    void drawSectionHandles(Vec3[4] q)
    {
        auto b = basis();
        glDisable(GL_DEPTH_TEST);
        foreach (k; 0 .. 4)
        {
            immutable live = k == sectionHandle || (sectionHandle < 0 && k == hoverHandle);
            immutable r = (live ? handlePixels + 2 : handlePixels) * mmPerPixelAt(q[k]);
            auto ru = b.right * r, rv = b.up * r;
            Vec3[4] c = [q[k] + ru + rv, q[k] - ru + rv, q[k] - ru - rv, q[k] + ru - rv];
            float[] fill, rim;
            foreach (i; [0, 1, 2, 0, 2, 3])
                fill ~= [cast(float) c[i].x, cast(float) c[i].y, cast(float) c[i].z];
            foreach (i; [0, 1, 1, 2, 2, 3, 3, 0])
                rim ~= [cast(float) c[i].x, cast(float) c[i].y, cast(float) c[i].z];
            uploadLines(fill);
            glUniform1f(uAlpha, 1);
            if (live)
                glUniform3f(uColor, 1.0f, 0.55f, 0.35f);
            else
                glUniform3f(uColor, 1.0f, 1.0f, 1.0f);
            glDrawArrays(GL_TRIANGLES, 0, 6);
            uploadLines(rim);
            glUniform3f(uColor, 0.9f, 0.35f, 0.2f);
            glLineWidth(2);
            glDrawArrays(GL_LINES, 0, 8);
            glLineWidth(1);
        }
        glEnable(GL_DEPTH_TEST);
    }

    void drawSectionOutline()
    {
        auto q = sectionQuad();
        // a translucent sheet with a border; parts in front of it hide it
        float[] tri;
        foreach (k; [0, 1, 2, 0, 2, 3])
            tri ~= [cast(float) q[k].x, cast(float) q[k].y, cast(float) q[k].z];
        uploadLines(tri);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDepthMask(GL_FALSE);
        glUniform1i(uFlat, 1);
        glUniform1f(uAlpha, 0.08);
        glUniform3f(uColor, 0.9f, 0.35f, 0.2f);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glUniform1f(uAlpha, 0.9);
        float[] border;
        foreach (k; [0, 1, 1, 2, 2, 3, 3, 0])
            border ~= [cast(float) q[k].x, cast(float) q[k].y, cast(float) q[k].z];
        uploadLines(border);
        glLineWidth(2);
        glDrawArrays(GL_LINES, 0, 8);
        glLineWidth(1);
        glUniform1f(uAlpha, 1);
        glDepthMask(GL_TRUE);
        glDisable(GL_BLEND);
        drawSectionHandles(q);
    }

    void uploadLines(const(float)[] v) => positionBuffer(lineVao, lineVbo, v);

    /// Points (x y z each, no normals: lines are drawn flat) into a buffer
    /// and its vertex array, made the first time; the array is left bound.
    static void positionBuffer(ref uint vao, ref uint vbo, const(float)[] v, uint usage = GL_DYNAMIC_DRAW)
    {
        if (vao == 0)
        {
            glGenVertexArrays(1, &vao);
            glGenBuffers(1, &vbo);
        }
        glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, v.length * float.sizeof, v.ptr, usage);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, null);
        glVertexAttrib3f(1, 0, 0, 1);
    }

    /// The sketches that can be drawn; `faded[i]`: sketch i is drawn faint
    /// (the last good one, shown while the code has an error).
    /// The solids sketches on faces are drawn on (SketchView.on), each
    /// shown faint under its sketch.
    void setSketchBodies(PartMesh[Brep] bodies)
    {
        sketchBodies = bodies;
        sketchBodiesDirty = true;
        redraw();
    }

    /// ditto, as given
    PartMesh[Brep] sketchBodies;
    private Gpu[Brep] sketchBodyGpu;
    private bool sketchBodiesDirty;

    void setSketches(SketchView[] s, bool[] faded = null)
    {
        sketches = s;
        fadedSketches = faded.dup;
        sketchDirty = true;
        redraw();
    }

    /// Draws the sketches `which` (indices in what setSketches gave) over the
    /// model, with their free points in blue; `highlight[k]` are entities of
    /// sketch which[k] drawn in orange (what an inspected line made or
    /// constrains). Nothing: no sketch drawn.
    void showSketches(size_t[] which, size_t[][] highlight = null)
    {
        immutable was = sketchShown;
        scope (exit)
            if (was != sketchShown && onSketchShown !is null)
                onSketchShown();
        shownSketches = null;
        litEntities = null;
        foreach (k, i; which)
        {
            if (i >= sketches.length)
                continue;
            shownSketches ~= i;
            bool[size_t] lit;
            if (k < highlight.length)
                foreach (e; highlight[k])
                    lit[e] = true;
            litEntities ~= lit;
        }
        sketchDirty = true;
        redraw();
    }

    // ---- planes: the main ones and the code's, shown on request to draw a sketch on

    /// A plane drawn in the view, as a square big enough for the model.
    struct ShownPlane
    {
        string name;
        Vec3 origin, normal;
        bool main;      /// XY, XZ or YZ
    }

    ShownPlane[] planes;        /// what Show planes draws
    bool planesOn;              /// Show planes on
    int hoverPlane = -1;        /// the plane under the pointer
    int pickedPlane = -1;       /// the plane clicked (picked: highlighted)

    /// Shows the planes (or hides them).
    void showPlanes(bool on)
    {
        planesOn = on;
        hoverPlane = -1;
        if (!on)
            pickedPlane = -1;
        band.setVisible(on);
        band.queueDraw();
        redraw();
    }

    /// The planes to show, the main ones first; the picked one stays picked
    /// when it is still there (by name).
    void setPlanes(ShownPlane[] ps)
    {
        immutable was = pickedPlane >= 0 && pickedPlane < planes.length ? planes[pickedPlane].name : null;
        planes = ps;
        pickedPlane = hoverPlane = -1;
        foreach (i, p; ps)
            if (was !is null && p.name == was)
                pickedPlane = cast(int) i;
        redraw();
    }

    /// Picks plane i (-1: none).
    void pickPlane(int i)
    {
        pickedPlane = i >= 0 && i < planes.length ? i : -1;
        redraw();
        band.queueDraw();
    }

    /// The axes along plane i's square, its centre and half its side: on
    /// the plane, nearest the middle of what is drawn, as big as that.
    void planeFrame(size_t i, out Vec3 c, out Vec3 u, out Vec3 v, out double half)
    {
        auto p = planes[i];
        auto n = p.normal.normalized;
        u = abs(n.z) < 0.9 ? Vec3(0, 0, 1).cross(n).normalized : Vec3(1, 0, 0);
        u = (u - n * u.dot(n)).normalized;
        v = n.cross(u);
        c = p.origin;
        half = 30;
        Vec3 lo, hi;
        if (drawnBox(lo, hi))
        {
            // round the model's shadow on it, a little wider
            auto m = (lo + hi) * 0.5;
            c = m - n * (m - p.origin).dot(n);
            double reach = 0;
            foreach (k; 0 .. 8)
            {
                auto q = Vec3(k & 1 ? hi.x : lo.x, k & 2 ? hi.y : lo.y, k & 4 ? hi.z : lo.z) - c;
                reach = max(reach, abs(q.dot(u)), abs(q.dot(v)));
            }
            half = max(10.0, reach * 1.2);
        }
    }

    Vec3[4] planeQuad(size_t i)
    {
        Vec3 c, u, v;
        double h;
        planeFrame(i, c, u, v, h);
        return [c + u * h + v * h, c - u * h + v * h, c - u * h - v * h, c + u * h - v * h];
    }

    /// The plane shown under window point (x, y), and how far along the
    /// pointer's ray; -1 when none.
    int planeAt(double x, double y, out double distance)
    {
        distance = double.infinity;
        if (!planesOn)
            return -1;
        Vec3 eye, dir;
        ray(x, y, eye, dir);
        int best = -1;
        foreach (i, p; planes)
        {
            auto n = p.normal.normalized;
            immutable den = dir.dot(n);
            if (abs(den) < 1e-9)
                continue;
            immutable t = (p.origin - eye).dot(n) / den;
            if (t <= 0 || t >= distance)
                continue;
            Vec3 c, u, v;
            double h;
            planeFrame(i, c, u, v, h);
            auto q = eye + dir * t - c;
            if (abs(q.dot(u)) <= h && abs(q.dot(v)) <= h)
            {
                distance = t;
                best = cast(int) i;
            }
        }
        return best;
    }

    /// The colour of plane i: the main ones as the axis across them (XY blue, XZ green, YZ red), the code's violet.
    Vec3 planeColour(size_t i)
    {
        auto n = planes[i].normal;
        if (!planes[i].main)
            return Vec3(0.6, 0.35, 0.9);
        if (abs(n.z) > 0.9)
            return Vec3(0.25, 0.45, 0.95);
        if (abs(n.y) > 0.9)
            return Vec3(0.3, 0.68, 0.35);
        return Vec3(0.9, 0.3, 0.3);
    }

    /// The planes, see-through over the model, their sides drawn; the one
    /// under the pointer or picked more strongly.
    private void renderPlanes()
    {
        if (!planesOn || planes.length == 0)
            return;
        forPart(-1);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDepthMask(GL_FALSE);
        // a plane lying on a face shows over it (the parts are drawn pushed back, it is pulled forward)
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(-1, -1);
        glUniform1i(uFlat, 1);
        foreach (i; 0 .. planes.length)
        {
            auto q = planeQuad(i);
            auto c = planeColour(i);
            immutable lit = i == hoverPlane || i == pickedPlane;
            float[] tri;
            foreach (k; [0, 1, 2, 0, 2, 3])
                tri ~= [cast(float) q[k].x, cast(float) q[k].y, cast(float) q[k].z];
            glUniform3f(uColor, cast(float) c.x, cast(float) c.y, cast(float) c.z);
            glUniform1f(uAlpha, i == pickedPlane ? 0.3f : lit ? 0.2f : 0.08f);
            uploadLines(tri);
            glDrawArrays(GL_TRIANGLES, 0, 6);
            float[] side;
            foreach (k; 0 .. 4)
                foreach (e; [q[k], q[(k + 1) % 4]])
                    side ~= [cast(float) e.x, cast(float) e.y, cast(float) e.z];
            glUniform1f(uAlpha, lit ? 1.0f : 0.6f);
            glLineWidth(i == pickedPlane ? 3 : lit ? 2 : 1);
            uploadLines(side);
            glDrawArrays(GL_LINES, 0, 8);
            glLineWidth(1);
        }
        glDisable(GL_POLYGON_OFFSET_FILL);
        glDepthMask(GL_TRUE);
        glDisable(GL_BLEND);
        glUniform1f(uAlpha, 1);
        band.queueDraw();
    }

    /// The planes' names, at the top left corner of each on screen.
    private void labelPlanes(Context cr)
    {
        cr.setFontSize(13);
        foreach (i; 0 .. planes.length)
        {
            // its top left corner, kept inside the view (a plane wider than the view: at its edge)
            double bx = double.infinity, by = 0;
            foreach (q; planeQuad(i))
            {
                double x, y;
                if (project(q, x, y) && x + y < bx + by)
                {
                    bx = x;
                    by = y;
                }
            }
            if (bx == double.infinity)
                continue;
            immutable w = area.getWidth(), h = area.getHeight();
            bx = max(4.0, min(bx, w - 60.0));
            by = max(40.0, min(by, h - 24.0));
            auto c = planeColour(i);
            immutable lit = i == hoverPlane || i == pickedPlane;
            cr.setSourceRgba(c.x * 0.8, c.y * 0.8, c.z * 0.8, lit ? 1 : 0.75);
            cr.moveTo(bx + 6, by + 16);
            cr.showText(planes[i].name);
        }
    }

    /// Whether a sketch is drawn.
    bool sketchShown() const => shownSketches.length > 0;

    /// Window coordinates of a model point; false when behind the camera.
    bool project(Vec3 p, out double x, out double y)
    {
        auto b = basis();
        auto d = p - b.eye;
        immutable z = d.dot(b.forward);
        if (z <= 1e-9)
            return false;
        immutable w = max(1, area.getWidth()), h = max(1, area.getHeight());
        // half the height of the view, in mm, at the depth of p
        immutable half = orthographic ? distance * tan(fovy / 2) : z * tan(fovy / 2);
        x = (d.dot(b.right) / (half * w / h) + 1) * w / 2;
        y = (1 - d.dot(b.up) / half) * h / 2;
        return true;
    }

    /// The edge of the part nearest to window point (x, y), among the edges
    /// of `face` (all edges when face is -1), if closer than `within` pixels.
    int nearestEdge(int part, int face, double x, double y, double within = 10, bool visibleOnly = false)
    {
        if (part < 0 || part >= parts.length)
            return -1;
        auto p = parts[part];
        // each edge's nearest point on screen, and where that is in space
        struct Near { double d; int edge; Vec3 at; }
        Near[] near;
        foreach (i, e; p.edgeInfo)
        {
            if (face >= 0 && i < p.edgeFaces.length && p.edgeFaces[i][0] != face && p.edgeFaces[i][1] != face)
                continue;
            auto pts = edgePoints(part, e);
            Near n = Near(within, -1);
            foreach (k; 0 .. pts.length - 1)
            {
                double ax, ay, bx, by;
                if (!project(pts[k], ax, ay) || !project(pts[k + 1], bx, by))
                    continue;
                immutable d = segmentDistance(x, y, ax, ay, bx, by);
                if (d < n.d)
                {
                    immutable dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
                    immutable t = l2 > 0 ? clamp(((x - ax) * dx + (y - ay) * dy) / l2, 0.0, 1.0) : 0;
                    n = Near(d, cast(int) i, pts[k] + (pts[k + 1] - pts[k]) * t);
                }
            }
            if (n.edge >= 0)
                near ~= n;
        }
        import std.algorithm : sort;
        near.sort!((a, b) => a.d < b.d);
        // the nearest that nothing hides (in wireframe the hidden ones show, and count)
        foreach (n; near)
            if (!visibleOnly || shading == Shading.wireframe || seen(previewing(part) ? placed(n.at) : n.at))
                return n.edge;
        return -1;
    }

    /// Whether point `p` (on a part's surface, an edge or a corner) is in
    /// sight: no surface between it and the viewer, a hair's breadth allowed.
    bool seen(Vec3 p)
    {
        double x, y;
        if (!project(p, x, y))
            return false;
        Vec3 o, d;
        ray(x, y, o, d);
        immutable along = (p - o).dot(d);
        auto h = pick(x, y);
        return h.part < 0 || h.distance >= along - max(0.05, along * 2e-3);
    }

    /// View size in logical pixels.
    int width() => area.getWidth();
    int height() => area.getHeight();

    /// Frames the parts; computed at the next frame, when the size is known.
    void fit()
    {
        if (locked)
            return;
        // framed now when the view has a size, so that a zoom or pan right
        // after it starts from the framed camera
        if (area.getWidth() > 0 && area.getHeight() > 0)
            applyFit(max(1.0, area.getWidth() - leftInset) / area.getHeight());
        else
            fitPending = true;
        redraw();
    }

    /// Looks at the model from direction `n` (pointing towards the viewer).
    void lookAlong(Vec3 n)
    {
        if (locked)
            return;
        import std.math : atan2, asin;
        n = n.normalized;
        // straight up or down: X to the right, as the top view has it (a sketch on a flat face reads so)
        yaw = abs(n.z) > 1 - 1e-6 ? -PI / 2 : atan2(n.y, n.x);
        pitch = max(-PI / 2 + 0.001, min(PI / 2 - 0.001, asin(n.z)));
        fit();
    }

    void setView(ViewPreset v)
    {
        if (locked)
            return;
        final switch (v)
        {
        case ViewPreset.iso: yaw = -PI / 3; pitch = PI / 6; break;
        case ViewPreset.front: yaw = -PI / 2; pitch = 0; break;
        case ViewPreset.top: yaw = -PI / 2; pitch = PI / 2 - 0.001; break;
        case ViewPreset.right: yaw = 0; pitch = 0; break;
        }
        fit();
    }

    /// Moves the camera away (factor > 1) or closer, keeping what it looks at.
    void zoom(double factor)
    {
        if (locked)
            return;
        distance = max(1e-3, distance * factor);
        redraw();
    }

    /// Turns the camera around what it looks at, like a drag: yaw around
    /// the vertical, pitch up or down (degrees).
    void orbit(double yawDeg, double pitchDeg)
    {
        if (locked)
            return;
        yaw -= yawDeg * PI / 180;
        pitch = max(-PI / 2 + 0.01, min(PI / 2 - 0.01, pitch + pitchDeg * PI / 180));
        redraw();
    }

    /// Moves the model on screen by fractions of the view's size, like a
    /// pan drag (x to the right, y down).
    void pan(double fx, double fy)
    {
        if (locked)
            return;
        auto c = basis();
        immutable h = max(1, area.getHeight());
        immutable k = mmPerPixel();
        target = target - c.right * (fx * area.getWidth() * k) + c.up * (fy * h * k);
        redraw();
    }

    /// Zooms like the mouse wheel at a point of the view (fractions of its
    /// size): what is under it stays still.
    void zoomAtFraction(double fx, double fy, double factor)
    {
        if (locked)
            return;
        zoomAt(fx * area.getWidth(), fy * area.getHeight(), factor);
    }

    /// Looks at model point `p` from the current direction; `size` (mm, if
    /// > 0) is how much of the model fits across the narrower side of the view.
    void centerOn(Vec3 p, double size)
    {
        if (locked)
            return;
        fitPending = false;
        target = p;
        if (size > 0)
        {
            immutable w = max(1, area.getWidth()), h = max(1, area.getHeight());
            immutable fov = min(fovy, 2 * atan(tan(fovy / 2) * w / h));
            distance = size / 2 / tan(fov / 2);
        }
        redraw();
    }

    /// Where model point `p` appears, as fractions of the view's size;
    /// `visible` is false when it is behind the camera or hidden by a surface.
    bool fractionOf(Vec3 p, out double fx, out double fy, out bool visible)
    {
        double x, y;
        if (!project(p, x, y))
            return false;
        fx = x / max(1, area.getWidth());
        fy = y / max(1, area.getHeight());
        auto h = pick(x, y);
        immutable tol = max(0.05, distance * 0.002);
        // nothing in front of it: no surface hit, or the hit is the point itself or behind it
        visible = h.part < 0 || (h.point - p).length < tol || (h.point - p).dot(basis().forward) > -tol;
        return true;
    }

    /// The camera: angles in degrees, distance and target in mm.
    struct Camera
    {
        double yaw, pitch, distance;
        Vec3 target;
        bool orthographic;
    }

    Camera camera() => Camera(yaw * 180 / PI, pitch * 180 / PI, distance, target, orthographic);

    // ---- the locked scene (Annotate): the camera cannot move, and the view
    // goes on showing what it showed when locked (the style, the hidden
    // parts, the section, the selection), whatever is changed meanwhile:
    // those changes show once it is unlocked; the camera never moves

    /// Whether the scene is locked.
    public bool locked;
    private bool lockedDrag;   /// a drag that began while locked: ignored to its end

    private struct Shown
    {
        Shading shading;
        bool showGrid, showAxes, printability, section;
        Shine shine;
        bool[] hidden;
        Vec3 sectionNormal;
        double sectionOffset;
        int sectionPart;
        Hit selected, hover;
        Hit[] others;
    }
    private Shown lockedShown;
    private Camera lockedCamera;

    private Shown shownNow()
    {
        Shown s = {shading, showGrid, showAxes, printability, section, shine, hidden.dup, sectionNormal, sectionOffset,
            sectionPart, selected, hover, others.dup};
        return s;
    }

    private void showAs(Shown s)
    {
        shading = s.shading;
        showGrid = s.showGrid;
        showAxes = s.showAxes;
        printability = s.printability;
        section = s.section;
        shine = s.shine;
        hidden = s.hidden;
        sectionNormal = s.sectionNormal;
        sectionOffset = s.sectionOffset;
        sectionPart = s.sectionPart;
        selected = s.selected;
        hover = s.hover;
        others = s.others;
    }

    /// Locks the scene as it is now (or unlocks it: the camera stays, what
    /// was changed meanwhile shows).
    void lock(bool on)
    {
        if (on == locked)
            return;
        if (on)
        {
            dragging = false;
            hover = Hit.init;
            fitPending = false;
            lockedCamera = camera();
            lockedShown = shownNow();
        }
        locked = on;
        redraw();
    }

    /// Runs `f` with the view as locked (the current state put back after).
    private T asLocked(T)(scope T delegate() f)
    {
        if (!locked)
            return f();
        auto now = shownNow();
        auto keepHidden = hidden;
        showAs(lockedShown);
        // the camera as locked: nothing could move it, but be sure
        yaw = lockedCamera.yaw * PI / 180;
        pitch = lockedCamera.pitch * PI / 180;
        distance = lockedCamera.distance;
        target = lockedCamera.target;
        orthographic = lockedCamera.orthographic;
        fitPending = false;
        scope (exit)
        {
            showAs(now);
            hidden = keepHidden;
        }
        return f();
    }

    /// What the locked view shows at window point (x, y): the part and face hit.
    Hit pickShown(double x, double y) => asLocked!Hit(() => pick(x, y));

    /// Where window point (x, y) lies on the plane through the point looked
    /// at, facing the viewer: a model point that the view shows at (x, y).
    Vec3 planePoint(double x, double y)
    {
        Vec3 o, d;
        ray(x, y, o, d);
        auto f = basis().forward;
        immutable den = d.dot(f);
        if (abs(den) < 1e-12)
            return target;
        return o + d * ((target - o).dot(f) / den);
    }

    /// Whether the view is drawn in the dark style.
    bool dark() const => darkStyle;

    /// The rectangle (view pixels: x0, y0, x1, y1) part i's box covers on
    /// screen; false when it is hidden or behind the camera.
    bool partRect(size_t i, out double[4] r)
    {
        if (i >= parts.length || isHidden(i))
            return false;
        auto p = parts[i];
        r = [double.infinity, double.infinity, -double.infinity, -double.infinity];
        foreach (cx; [p.bbox.min.x, p.bbox.max.x])
            foreach (cy; [p.bbox.min.y, p.bbox.max.y])
                foreach (cz; [p.bbox.min.z, p.bbox.max.z])
                {
                    double x, y;
                    if (!project(Vec3(cx, cy, cz), x, y))
                        continue;
                    r[0] = min(r[0], x);
                    r[1] = min(r[1], y);
                    r[2] = max(r[2], x);
                    r[3] = max(r[3], y);
                }
        return r[0] <= r[2];
    }

    /// Puts the camera back where camera() said it was.
    void setCamera(Camera c)
    {
        if (locked)
            return;
        fitPending = false;
        yaw = c.yaw * PI / 180;
        pitch = c.pitch * PI / 180;
        distance = c.distance;
        target = c.target;
        orthographic = c.orthographic;
        redraw();
    }

    /// Where the camera looks: from the eye towards the target.
    Vec3 viewDirection() => basis().forward;

    void setShading(Shading s)
    {
        shading = s;
        redraw();
    }

    /// The ground grid and the X and Y axes, each shown or not.
    bool showGrid = true, showAxes = true;

    void setGuides(bool grid, bool axes)
    {
        showGrid = grid;
        showAxes = axes;
        redraw();
    }

    /// Switches projection; what lies on the plane of the target keeps its size.
    void setOrthographic(bool on)
    {
        if (locked)
            return;
        orthographic = on;
        redraw();
    }

    /// The ray under view point (x, y): from the eye, through it.
    void rayAt(double x, double y, out Vec3 origin, out Vec3 dir) { ray(x, y, origin, dir); }

    /// Draws the view again (what is drawn over the model changed).
    void refresh() { redraw(); }

private:

    struct Gpu
    {
        uint vao, vbo, ebo, edgeVao, edgeVbo;
        int indexCount, edgeCount;
        int tangentCount;   /// after the edges in their buffer: drawn in wireframe
        uint outlineVao, outlineVbo;   /// the outline of curved surfaces (wireframe), from the latest frame
        int outlineCount;
        Vec3 outlineEye, outlineForward;   /// where the outline was seen from
        bool outlineOrthographic, outlineValid;
        /// the part's vertices it was made from: unchanged parts keep their
        /// buffers (held here, so the memory is not reused for another part)
        const(float)[] source;
        /// total edge length and the two largest sizes (mm): how crowded the
        /// edges get on screen at a given zoom
        double edgeLength = 0, spanA = 1, spanB = 1;
        /// the printability marks: the overhanging triangles' indices,
        /// then the thin walls', for the limits they were found with
        uint printVao, printEbo;
        int overhangCount, thinCount;
        bool printValid;
        PrintCheck print;
    }

    struct Basis
    {
        Vec3 eye, forward, right, up;
    }

    Basis basis()
    {
        Basis b;
        b.eye = target + Vec3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch)) * eyeDistance();
        b.forward = (target - b.eye).normalized;
        b.right = b.forward.cross(Vec3(0, 0, 1)).normalized;
        b.up = b.right.cross(b.forward);
        return b;
    }

    /// How far the eye is from the target: the camera distance in
    /// perspective; in orthographic, where zooming does not move the eye,
    /// out of everything at any zoom.
    double eyeDistance()
    {
        if (!orthographic)
            return distance;
        double r = 50;
        foreach (p; parts)
            r = max(r, p.bbox.min.length, p.bbox.max.length);
        // the grid reaches 1.3 times the parts, and more around the origin
        return distance + 2 * (target.length + 2 * (r * 1.3 + 50));
    }

    /// Millimetres per pixel on the plane through the target facing the camera.
    double mmPerPixel() => 2 * distance * tan(fovy / 2) / max(1, area.getHeight());

    /// The ray through window point (x, y): from the eye in perspective,
    /// from that point of the near side in orthographic, where all go straight ahead.
    void ray(double x, double y, out Vec3 origin, out Vec3 dir)
    {
        auto b = basis();
        immutable w = max(1, area.getWidth()), h = max(1, area.getHeight());
        immutable t = tan(fovy / 2);
        immutable nx = 2 * x / w - 1, ny = 1 - 2 * y / h;
        origin = b.eye;
        if (orthographic)
        {
            origin = b.eye + b.right * (nx * distance * t * w / h) + b.up * (ny * distance * t);
            dir = b.forward;
        }
        else
            dir = (b.forward + b.right * (nx * t * w / h) + b.up * (ny * t)).normalized;
    }

    /// Zooms by `factor` keeping the point under the pointer still: the
    /// model point hit by the ray, or the point on the plane through the
    /// target facing the camera.
    void zoomAt(double x, double y, double factor)
    {
        if (locked)
            return;
        auto b = basis();
        auto hit = pick(x, y);
        Vec3 p, lo, hi;
        if (hit.part >= 0)
            p = hit.point;
        else
        {
            // over nothing: the point under the pointer at the depth of the
            // model's middle (of the target when there is none in front), in
            // and out alike: what is under the pointer stays there. At the
            // target's depth the view closed in on empty space a few mm away
            Vec3 o, d;
            ray(x, y, o, d);
            auto depthOf = target;
            if (drawnBox(lo, hi) && ((lo + hi) * 0.5 - b.eye).dot(b.forward) > 1e-3)
                depthOf = (lo + hi) * 0.5;
            immutable denom = d.dot(b.forward);
            p = abs(denom) > 1e-9 ? o + d * ((depthOf - o).dot(b.forward) / denom) : target;
        }
        // scaling the camera about p keeps p at the same place on screen
        target = p + (target - p) * factor;
        distance = max(1e-3, distance * factor);
        redraw();
    }

    void updateHoverCursor()
    {
        // over a handle of the section plane: it can be dragged; over an X or
        // a ✓, a click closes or accepts (before the gizmo, which lies near)
        immutable onButton = buttonAt(pointerX, pointerY);
        if (onButton != ViewButton.none && gizmoHover != -1)
            gizmoHover = -1;
        if (gizmo != Gizmo.none && onButton == ViewButton.none)
        {
            immutable g = gizmoAt(pointerX, pointerY);
            if (g != gizmoHover)
            {
                gizmoHover = g;
                redraw();
            }
            if (g >= 0)
            {
                area.setCursorFromName("grab");
                return;
            }
        }
        immutable handle = onButton != ViewButton.none ? -1 : handleAt(pointerX, pointerY);
        if (handle != hoverHandle || onButton != hoverButton)
        {
            hoverHandle = handle;
            hoverButton = onButton;
            redraw();
        }
        if (onButton != ViewButton.none)
        {
            area.setCursorFromName("pointer");
            return;
        }
        if (handle >= 0)
        {
            area.setCursorFromName("grab");
            return;
        }
        if (placing)
        {
            area.setCursorFromName("crosshair");
            hoverPlace(pointerX, pointerY);
            return;
        }
        // edges and vertices light up under the pointer: what a click would pick
        auto h = selectMode == SelectMode.edge || selectMode == SelectMode.vertex ? pickSelect(pointerX, pointerY)
            : pick(pointerX, pointerY);
        area.setCursorFromName(null);   // the ring on the surface shows what is under the pointer
        // the point under the pointer is marked on the surface
        if (h.part >= 0 || hover.part >= 0)
        {
            hover = h;
            redraw();
        }
    }

    Hit hover;

    /// A small ring lying on the surface under the pointer, the same size on screen at any zoom.
    void drawHoverMark()
    {
        if (hover.part < 0 || dragging || hover.part >= parts.length)
            return;
        // orange under the pointer (picked ones are yellow)
        immutable mark = standOut(parts[hover.part].rgb, Vec3(1.0, 0.5, 0.0), Vec3(0.3, 0.5, 1.0), 0.32);
        if (hover.edge >= 0 && hover.edge < parts[hover.part].edgeInfo.length)
        {
            forPart(hover.part);
            drawPolyline(edgePoints(hover.part, parts[hover.part].edgeInfo[hover.edge]), mark, 3);
            forPart(-1);
            return;
        }
        if (hover.vertex >= 0)
        {
            drawKnob(vertexAt(hover.part, hover.vertex), mark, handlePixels - 2);
            return;
        }
        auto n = hover.normal;
        if (n.length < 0.5)
            return;
        // face the viewer
        if (n.dot(basis().forward) > 0)
            n = n * -1;
        auto u = (abs(n.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)).cross(n).normalized;
        auto v = n.cross(u);
        auto b = basis();
        immutable depth = orthographic ? distance : (hover.point - b.eye).dot(b.forward);
        immutable r = depth * tan(fovy / 2) * 2 * 7 / max(1, area.getHeight());
        Vec3[] ring;
        foreach (k; 0 .. 25)
        {
            immutable t = 2 * PI * k / 24;
            ring ~= hover.point + n * (r * 0.05) + (u * cos(t) + v * sin(t)) * r;
        }
        // orange on a dark outline: visible on any part colour
        auto cross1 = [hover.point - u * (r * 0.3), hover.point + u * (r * 0.3)];
        auto cross2 = [hover.point - v * (r * 0.3), hover.point + v * (r * 0.3)];
        foreach (pass; 0 .. 2)
        {
            auto c = pass == 0 ? Vec3(0.08, 0.08, 0.1)
                : standOut(parts[hover.part].rgb, Vec3(1.0, 0.6, 0.05), Vec3(0.3, 0.5, 1.0), 0.32);
            immutable w = pass == 0 ? 4.5f : 2f;
            drawPolyline(ring, c, w);
            drawPolyline(cross1, c, w);
            drawPolyline(cross2, c, w);
        }
    }

    void applyFit(double aspect)
    {
        fitPending = false;
        bool any;
        BBox box;
        foreach (i, p; parts)
            if (!isHidden(i))
            {
                box = any ? box.merged(p.bbox) : p.bbox;
                any = true;
            }
        if (!any)
            return;
        immutable lo = box.min, hi = box.max;
        target = (lo + hi) / 2;
        if (orthographic)
        {
            // the box of the parts as it looks from here: no perspective, so
            // its corners on the screen plane tell how much has to fit
            auto b = basis();
            double w = 1, h = 1;
            foreach (k; 0 .. 8)
            {
                auto c = Vec3(k & 1 ? hi.x : lo.x, k & 2 ? hi.y : lo.y, k & 4 ? hi.z : lo.z) - target;
                w = max(w, abs(c.dot(b.right)));
                h = max(h, abs(c.dot(b.up)));
            }
            distance = max(h, w / aspect) / tan(fovy / 2) * 1.08 * fitRoom;
            fitRoom = 1;
            besideInset();
            return;
        }
        immutable radius = max(1.0, (hi - lo).length / 2);
        // the sphere around the parts in the narrower of the vertical and
        // horizontal fields of view
        immutable fov = min(fovy, 2 * atan(tan(fovy / 2) * aspect));
        distance = radius / sin(fov / 2) * 1.02 * fitRoom;
        fitRoom = 1;
        besideInset();
    }

    /// The framed model moved right by half what a bar at the left covers: in the middle of the rest.
    private void besideInset()
    {
        if (leftInset <= 0 || area.getHeight() <= 0)
            return;
        // millimetres per pixel at the depth of what is looked at
        immutable perPixel = 2 * distance * tan(fovy / 2) / area.getHeight();
        target = target - basis().right * (leftInset / 2 * perPixel);
    }

    void realize()
    {
        import std.stdio : stderr;
        area.makeCurrent();
        if (auto e = glError())
        {
            stderr.writeln("3D view: no OpenGL context: ", e);
            explain();
            return;
        }
        auto support = loadOpenGL();
        if (support == GLSupport.noLibrary || support == GLSupport.badLibrary || support < GLSupport.gl33)
        {
            stderr.writeln("3D view: OpenGL 3.3 is needed, found ", support,
                support == GLSupport.noLibrary ? " (no libGL)" : "",
                support == GLSupport.noContext ? " (on X11, try GDK_DEBUG=gl-glx)" : "");
            explain();
            return;
        }
        {
            import std.string : fromStringz;
            string text(uint name)
            {
                auto p = glGetString(name);
                return p is null ? "" : (cast(const(char)*) p).fromStringz.idup;
            }
            glRenderer = text(GL_RENDERER);
            glVersion = text(GL_VERSION);
            glVendor = text(GL_VENDOR);
        }
        program = buildProgram();
        uMvp = glGetUniformLocation(program, "uMvp");
        uModel = glGetUniformLocation(program, "uModel");
        uSurface = glGetUniformLocation(program, "uSurface");
        uEven = glGetUniformLocation(program, "uEven");
        uForward = glGetUniformLocation(program, "uForward");
        uRight = glGetUniformLocation(program, "uRight");
        uUp = glGetUniformLocation(program, "uUp");
        uColor = glGetUniformLocation(program, "uColor");
        uEye = glGetUniformLocation(program, "uEye");
        uFlat = glGetUniformLocation(program, "uFlat");
        uPattern = glGetUniformLocation(program, "uPattern");
        uAlpha = glGetUniformLocation(program, "uAlpha");
        uClipOn = glGetUniformLocation(program, "uClipOn");
        uClip = glGetUniformLocation(program, "uClip");
        glGenQueries(cast(int) timerQueries.length, timerQueries.ptr);
        glReady = true;
    }

    /// The GLArea's error, if any.
    // WORKAROUND (gid 0.9.13, GLArea.getError): its wrapper frees the error
    // it does not own, and GTK frees it again when the view goes, corrupting
    // the heap; so the C function is called directly. The "known bugs"
    // unittest in lang/tests.d fails when gid's version changes: then read
    // getError in gid's gtk/gl_area.d, and if it no longer frees the error,
    // area.getError() will do.
    string glError()
    {
        import gtk.c.functions : gtk_gl_area_get_error;
        import gtk.c.types : GtkGLArea;
        import std.string : fromStringz;
        auto e = gtk_gl_area_get_error(cast(GtkGLArea*) area._cPtr);
        return e is null ? null : (e.message ? e.message.fromStringz.idup : "unknown error");
    }

    /// Hands glHelp, when known, to whoever shows it: later, outside the
    /// realize signal (the view itself is left to GTK, which shows its error).
    void explain()
    {
        import glib.global : idleAdd;
        import glib.types : PRIORITY_DEFAULT_IDLE;
        if (glHelp.length && onGlFailed !is null)
            idleAdd(PRIORITY_DEFAULT_IDLE, () { onGlFailed(glHelp); return false; });
    }

    /// A part with a colour like "#RRGGBBAA" or alpha: below 1.
    bool transparent(size_t i) => i < parts.length && alphaOf(parts[i].rgb) < 0.999;

    private void drawShaded(size_t i)
    {
        forPart(i);
        auto c = rgbOf(parts[i].rgb);
        // the whole part picked: tinted and dotted (picked faces are striped)
        immutable whole = i == selected.part && selected.face < 0 && selected.edge < 0 && selected.vertex < 0;
        if (whole)
        {
            c = c * 0.6 + standOut(parts[i].rgb, Vec3(1, 0.85, 0.2), Vec3(0.3, 0.5, 1.0)) * 0.4;
            glUniform1i(uPattern, 4);
        }
        glUniform3f(uColor, cast(float) c.x, cast(float) c.y, cast(float) c.z);
        glBindVertexArray(gpu[i].vao);
        glDrawElements(GL_TRIANGLES, gpu[i].indexCount, GL_UNSIGNED_INT, null);
        if (whole)
            glUniform1i(uPattern, 0);
    }

    /// See-through parts, after the opaque ones: blended, without writing
    /// depth, inner side first so the near side lies over it.
    private void renderTransparent()
    {
        bool any;
        foreach (i; 0 .. gpu.length)
            any = any || (!isHidden(i) && transparent(i));
        if (!any)
            return;
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDepthMask(GL_FALSE);
        glEnable(GL_CULL_FACE);
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1, 1);
        foreach (face; [GL_FRONT, GL_BACK])
        {
            glCullFace(face);
            foreach (i; 0 .. gpu.length)
                if (!isHidden(i) && transparent(i))
                {
                    glUniform1f(uAlpha, cast(float) alphaOf(parts[i].rgb));
                    drawShaded(i);
                }
        }
        glDisable(GL_POLYGON_OFFSET_FILL);
        glDisable(GL_CULL_FACE);
        glDepthMask(GL_TRUE);
        glDisable(GL_BLEND);
        glUniform1f(uAlpha, 1);
    }

    private bool offscreen;
    private double offscreenAspect = 1;

    /// The view as an image (RGB, rows from the top), w × h pixels, drawn
    /// by OpenGL off screen with 4× multisampling: what the window shows,
    /// without the selection and the pointer mark. null without OpenGL.
    public ubyte[] renderImage(int w, int h)
    {
        if (!glReady)
            return null;
        area.makeCurrent();
        if (glError() !is null)
            return null;
        int previous;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous);
        int[4] port;
        glGetIntegerv(GL_VIEWPORT, port.ptr);
        uint[2] fbo;
        uint[3] rb;
        glGenFramebuffers(2, fbo.ptr);
        glGenRenderbuffers(3, rb.ptr);
        scope (exit)
        {
            glBindFramebuffer(GL_FRAMEBUFFER, previous);
            glViewport(port[0], port[1], port[2], port[3]);
            glDeleteFramebuffers(2, fbo.ptr);
            glDeleteRenderbuffers(3, rb.ptr);
            redraw();
        }
        // drawn multisampled, then resolved into a plain buffer to read back
        glBindRenderbuffer(GL_RENDERBUFFER, rb[0]);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, 4, GL_RGBA8, w, h);
        glBindRenderbuffer(GL_RENDERBUFFER, rb[1]);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, 4, GL_DEPTH24_STENCIL8, w, h);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo[0]);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb[0]);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, rb[1]);
        glBindRenderbuffer(GL_RENDERBUFFER, rb[2]);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, w, h);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo[1]);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb[2]);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
            return null;

        glBindFramebuffer(GL_FRAMEBUFFER, fbo[0]);
        glViewport(0, 0, w, h);
        {
            auto keepSelected = selected, keepOthers = others, keepHover = hover, keepFrame = onFrame;
            selected = Hit.init;
            others = null;
            hover = Hit.init;
            onFrame = null;
            offscreen = true;
            offscreenAspect = cast(double) w / h;
            scope (exit)
            {
                selected = keepSelected;
                others = keepOthers;
                hover = keepHover;
                onFrame = keepFrame;
                offscreen = false;
            }
            render();
        }
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo[0]);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo[1]);
        glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo[1]);
        auto rgba = new ubyte[w * h * 4];
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, rgba.ptr);
        // OpenGL rows go from the bottom
        auto rgb = new ubyte[w * h * 3];
        foreach (y; 0 .. h)
            foreach (x; 0 .. w)
                rgb[(y * w + x) * 3 .. (y * w + x) * 3 + 3] = rgba[((h - 1 - y) * w + x) * 4 .. ((h - 1 - y) * w + x) * 4 + 3];
        return rgb;
    }

    /// How strong a part's edges are drawn: 1 while they are sparse on
    /// screen, down to a faint hatching where they would cover the part. The
    /// estimate (edge length over the part's two largest sizes) runs higher
    /// than the PNG renderer's per-pixel coverage: plain parts stay under 1,
    /// threads seen from afar go past 2.
    double edgeFade(ref const Gpu g)
    {
        immutable pxPerMm = max(1, area.getHeight()) / (2 * distance * tan(fovy / 2));
        immutable covered = g.edgeLength / (pxPerMm * g.spanA * g.spanB * max(1, area.getScaleFactor()));
        return clamp(1 - (covered - 1.5) / 3, 0.3, 1.0);
    }

    // ---- for diagnosis: what draws the view, and how fast

    /// The OpenGL the view draws with, as the driver names it.
    public string glRenderer, glVersion, glVendor;

    /// Whether the processor does the drawing (Mesa's llvmpipe or softpipe,
    /// Windows' GDI or basic display driver): every frame then costs CPU.
    public bool softwareGl() const
    {
        import std.algorithm : canFind;
        import std.uni : toLower;
        auto r = glRenderer.toLower;
        return ["llvmpipe", "softpipe", "gdi generic", "microsoft basic render", "swrast", "software"]
            .canFind!(w => r.canFind(w));
    }

    /// How fast the view draws, over the last frames drawn while the user
    /// moved it (turning, panning, zooming): for diagnosis, in About and the
    /// agents' state. Times in ms; 16.7 is 60 frames a second.
    public struct FrameStats
    {
        int frames;                      /// how many frames the figures are over
        double drawMs = 0, drawMaxMs = 0;   /// processor: issuing the commands, antialiasing included
        double gpuMs = -1, gpuMaxMs = -1;   /// graphics card (-1: not known yet, or it cannot tell)
        double waitMs = 0, waitMaxMs = 0;   /// from asking for a frame to starting it
        double intervalMs = 0, intervalMaxMs = 0;   /// from one frame to the next
        // the wait is what the user sees as jerks: the time apart also grows
        // when the movements come slowly (an agent's), with nothing wrong
        int slow;                        /// frames waited for more than 33 ms (under 30 a second)
    }

    private enum statFrames = 120;
    private double[statFrames] cpuTimes, waitTimes, gapTimes, gpuTimes;
    private int statCount, statNext, gpuCount, gpuNext;
    private MonoTime lastFrame, requestedAt, lastInput;
    private bool lastFrameMoving;
    // GPU time: a few timer queries in turn, read back frames later, never waited for
    private uint[4] timerQueries;
    private bool[4] timerPending, timerMoving;
    private int timerNext;

    /// The figures, over the last frames drawn while moving.
    public FrameStats frameStats() const
    {
        import std.algorithm : maxElement, sum;
        FrameStats f;
        f.frames = statCount;
        if (statCount)
        {
            auto c = cpuTimes[0 .. statCount], w = waitTimes[0 .. statCount], g = gapTimes[0 .. statCount];
            f.drawMs = c.sum / statCount;
            f.drawMaxMs = c.maxElement;
            f.waitMs = w.sum / statCount;
            f.waitMaxMs = w.maxElement;
            int gaps;
            double total = 0;
            foreach (i; 0 .. statCount)
            {
                if (g[i] > 0)
                {
                    gaps++;
                    total += g[i];
                    f.intervalMaxMs = max(f.intervalMaxMs, g[i]);
                }
                if (w[i] > 33.4)
                    f.slow++;
            }
            f.intervalMs = gaps ? total / gaps : 0;
        }
        if (gpuCount)
        {
            f.gpuMs = gpuTimes[0 .. gpuCount].sum / gpuCount;
            f.gpuMaxMs = gpuTimes[0 .. gpuCount].maxElement;
        }
        return f;
    }

    /// Asks GTK for a frame, noting when: the wait until it starts is part
    /// of the figures.
    private void redraw()
    {
        if (requestedAt == MonoTime.init)
            requestedAt = MonoTime.currTime;
        area.queueRender();
    }

    /// The user (or an agent, as the user would) moved the view: frames
    /// drawn soon after count in the figures.
    public void moved()
    {
        lastInput = MonoTime.currTime;
    }

    /// Reads the timer queries that have finished, without waiting.
    private void collectGpuTimes()
    {
        foreach (i, q; timerQueries)
        {
            if (!timerPending[i])
                continue;
            int available;
            glGetQueryObjectiv(q, GL_QUERY_RESULT_AVAILABLE, &available);
            if (!available)
                continue;
            ulong ns;
            glGetQueryObjectui64v(q, GL_QUERY_RESULT, &ns);
            timerPending[i] = false;
            if (!timerMoving[i])
                continue;
            gpuTimes[gpuNext] = ns / 1e6;
            gpuNext = (gpuNext + 1) % statFrames;
            gpuCount = min(gpuCount + 1, statFrames);
        }
    }

    /// Notes a frame drawn on screen: started at `started`, issued in `cpu`
    /// ms. Only frames drawn while the user moves the view count.
    private void noteFrame(MonoTime started, double cpu, bool moving)
    {
        immutable wait = requestedAt == MonoTime.init ? 0 : (started - requestedAt).total!"usecs" / 1000.0;
        requestedAt = MonoTime.init;
        // a pause between two movements is not a slow frame
        immutable gap = lastFrameMoving && moving ? (started - lastFrame).total!"usecs" / 1000.0 : 0;
        lastFrame = started;
        lastFrameMoving = moving;
        if (!moving)
            return;
        cpuTimes[statNext] = cpu;
        waitTimes[statNext] = wait;
        gapTimes[statNext] = gap < 1000 ? gap : 0;
        statNext = (statNext + 1) % statFrames;
        statCount = min(statCount + 1, statFrames);
    }

    // ---- antialiasing on screen: GtkGLArea has no multisampling, so the
    // view is drawn into a multisampled buffer of its own, then resolved
    // into GTK's (not with the processor drawing: it would slow it further)

    private uint msaaFbo;
    private uint[2] msaaBuffers;
    private int msaaW, msaaH;
    private bool msaaBroken;
    private bool antialiasWanted = true;

    /// Antialiasing on or off (the user's choice; off anyway when the
    /// processor draws or the buffer could not be made).
    public void setAntialias(bool on)
    {
        antialiasWanted = on;
        redraw();
    }

    /// Whether the view is drawn antialiased now.
    public bool antialiasing() const => antialiasWanted && !msaaBroken && !softwareGl();

    /// Binds the multisampled buffer, made or resized for the view; returns
    /// the framebuffer to resolve it into at the end, or -1 without one.
    private int beginMultisample()
    {
        if (offscreen || !antialiasing())
            return -1;
        int target;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &target);
        int[4] port;
        glGetIntegerv(GL_VIEWPORT, port.ptr);
        immutable w = port[0] + port[2], h = port[1] + port[3];
        if (w <= 0 || h <= 0)
            return -1;
        if (msaaFbo == 0 || w != msaaW || h != msaaH)
        {
            if (msaaFbo == 0)
            {
                glGenFramebuffers(1, &msaaFbo);
                glGenRenderbuffers(2, msaaBuffers.ptr);
            }
            int most;
            glGetIntegerv(GL_MAX_SAMPLES, &most);
            immutable samples = min(4, max(1, most));
            glBindRenderbuffer(GL_RENDERBUFFER, msaaBuffers[0]);
            glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_RGBA8, w, h);
            glBindRenderbuffer(GL_RENDERBUFFER, msaaBuffers[1]);
            glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_DEPTH24_STENCIL8, w, h);
            glBindFramebuffer(GL_FRAMEBUFFER, msaaFbo);
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, msaaBuffers[0]);
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, msaaBuffers[1]);
            if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
            {
                // drawn without, from now on
                msaaBroken = true;
                glBindFramebuffer(GL_FRAMEBUFFER, target);
                return -1;
            }
            msaaW = w;
            msaaH = h;
        }
        glBindFramebuffer(GL_FRAMEBUFFER, msaaFbo);
        return target;
    }

    private void endMultisample(int target)
    {
        if (target < 0)
            return;
        glBindFramebuffer(GL_READ_FRAMEBUFFER, msaaFbo);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target);
        glBlitFramebuffer(0, 0, msaaW, msaaH, 0, 0, msaaW, msaaH, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        glBindFramebuffer(GL_FRAMEBUFFER, target);
    }

    bool render()
    {
        if (!glReady)
            return false;
        if (locked)
            return asLocked!bool(() => renderNow());
        return renderNow();
    }

    private bool renderNow()
    {
        // the figures: the scope(exit)s run in reverse, so the timings take
        // in the antialiasing resolved at the end
        immutable started = MonoTime.currTime;
        immutable moving = !offscreen && (dragging || started - lastInput < 300.msecs);
        scope (exit)
            if (!offscreen)
                noteFrame(started, (MonoTime.currTime - started).total!"usecs" / 1000.0, moving);
        immutable timer = timerQueries[0] && !offscreen && !timerPending[timerNext] ? timerNext : -1;
        if (timerQueries[0] && !offscreen)
            collectGpuTimes();
        if (timer >= 0)
        {
            glBeginQuery(GL_TIME_ELAPSED, timerQueries[timer]);
            timerPending[timer] = true;
            timerMoving[timer] = moving;
            timerNext = (timerNext + 1) % cast(int) timerQueries.length;
        }
        scope (exit)
            if (timer >= 0)
                glEndQuery(GL_TIME_ELAPSED);
        immutable resolveInto = beginMultisample();
        scope (exit)
            endMultisample(resolveInto);
        if (dirty)
            upload();

        if (darkStyle)
            glClearColor(0.17f, 0.175f, 0.19f, 1);
        else
            glClearColor(0.925f, 0.93f, 0.945f, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
        glEnable(GL_DEPTH_TEST);
        glDepthFunc(GL_LEQUAL);

        immutable aspect = offscreen ? offscreenAspect : cast(double) max(1, area.getWidth()) / max(1, area.getHeight());
        if (fitPending)
            applyFit(aspect);
        auto b = basis();
        immutable eyeDist = eyeDistance();
        immutable halfH = distance * tan(fovy / 2);
        auto proj = orthographic ? orthographicMatrix(halfH * aspect, halfH, eyeDist * 0.01, eyeDist * 2)
            : perspective(fovy, aspect, distance * 0.01, distance * 100);
        auto view = lookAt(b.eye, target, Vec3(0, 0, 1));
        auto mvp = multiply(proj, view);

        glUseProgram(program);
        glUniformMatrix4fv(uMvp, 1, GL_FALSE, mvp.ptr);
        forPart(-1);
        // how the surfaces look, and the lights that go with the viewer
        glUniform1i(uSurface, shine == Shine.high ? 1 : 0);
        glUniform1i(uEven, shine == Shine.none ? 1 : 0);
        glUniform3f(uForward, cast(float) b.forward.x, cast(float) b.forward.y, cast(float) b.forward.z);
        {
            glUniform3f(uRight, cast(float) b.right.x, cast(float) b.right.y, cast(float) b.right.z);
            glUniform3f(uUp, cast(float) b.up.x, cast(float) b.up.y, cast(float) b.up.z);
        }
        glUniform3f(uEye, cast(float) b.eye.x, cast(float) b.eye.y, cast(float) b.eye.z);
        glUniform1f(uAlpha, 1);

        // grid and axes, behind everything: they write no depth, so the
        // edges of a part standing on the grid are never cut by its lines
        updateGrid();
        glDepthMask(GL_FALSE);
        glUniform1i(uFlat, 1);
        glBindVertexArray(gridVao);
        if (darkStyle)
            glUniform3f(uColor, 0.27f, 0.28f, 0.30f);
        else
            glUniform3f(uColor, 0.80f, 0.81f, 0.84f);
        if (showGrid)
            glDrawArrays(GL_LINES, 4, gridCount - 4);
        if (showAxes)
        {
            glLineWidth(2);
            glUniform3f(uColor, 0.85f, 0.25f, 0.25f);
            glDrawArrays(GL_LINES, 0, 2);
            glUniform3f(uColor, 0.25f, 0.65f, 0.3f);
            glDrawArrays(GL_LINES, 2, 2);
            glLineWidth(1);
        }
        glDepthMask(GL_TRUE);

        // the section plane cuts the parts, not the grid
        glUniform1i(uClipOn, section ? 1 : 0);
        glUniform4f(uClip, cast(float) sectionNormal.x, cast(float) sectionNormal.y, cast(float) sectionNormal.z,
            cast(float) sectionOffset);

        if (inspectDirty && !inspecting)
        {
            // Inspect was closed: its meshes leave the GPU
            foreach (ref g; inspectGpu)
                freeGpu(g);
            inspectGpu = null;
            inspectDirty = false;
        }
        if (rollback || inspecting)
        {
            if (rollback)
                renderRollback();
            else
                renderInspect();
            renderSketches();
            renderDrawing();
            glBindVertexArray(0);
            if (onFrame !is null)
                onFrame();
            return true;
        }

        // with a sketch shown the parts are see-through so the sketch shows
        immutable ghost = sketchShown;
        if (ghost)
        {
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glDepthMask(GL_FALSE);
            glUniform1f(uAlpha, 0.25);
        }

        // shaded parts, pushed back so their edges and the picked face draw
        // on top; in wireframe only their depth, which tells the hidden edges
        immutable wire = shading == Shading.wireframe;
        glEnable(GL_POLYGON_OFFSET_FILL);
        // in wireframe further back: the outline of a concave surface lies on
        // a visible part of it, and would come and go with the depth
        if (wire)
            glPolygonOffset(4, 16);
        else
            glPolygonOffset(1, 1);
        glUniform1i(uFlat, 0);
        if (wire)
            glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
        foreach (i, g; gpu)
            if (!isHidden(i) && (ghost || wire || !transparent(i)))
                drawShaded(i);
        if (wire)
            glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glDisable(GL_POLYGON_OFFSET_FILL);
        // the cut, hatched, in wireframe too: it is the one surface there,
        // and what lies behind it turns into hidden edges
        if (section)
            capSection();
        if (!ghost && !wire)
            renderTransparent();

        if (printability)
            drawPrintability(wire);

        // the picked faces, in highlight colour (an item near an edge is the edge)
        foreach (h; selection())
        {
            if (h.edge >= 0 || h.face < 0 || isHidden(h.part) || h.part >= gpu.length)
                continue;
            auto fs = parts[h.part].faceStart;
            if (h.face + 1 < fs.length)
            {
                forPart(h.part);
                auto c = standOut(parts[h.part].rgb, Vec3(1.0, 0.78, 0.15), Vec3(0.3, 0.5, 1.0));
                glUniform3f(uColor, cast(float) c.x, cast(float) c.y, cast(float) c.z);
                // striped: several picked faces never look like one coloured part
                glUniform1i(uPattern, 3);
                glBindVertexArray(gpu[h.part].vao);
                glDrawElements(GL_TRIANGLES, cast(int)((fs[h.face + 1] - fs[h.face]) * 3), GL_UNSIGNED_INT,
                    cast(void*)(fs[h.face] * 3 * uint.sizeof));
                glUniform1i(uPattern, 0);
            }
        }

        glUniform1i(uFlat, 1);
        if (wire)
        {
            foreach (i, ref g; gpu)
                if (!isHidden(i))
                    uploadOutline(i, g);
            // every edge faint, then the visible ones over them
            glDisable(GL_DEPTH_TEST);
            glDepthMask(GL_FALSE);
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glUniform1f(uAlpha, 0.85);
            // blue: not to be taken for the grid; lighter on the dark background
            if (darkStyle)
                glUniform3f(uColor, 0.38f, 0.6f, 1.0f);
            else
                glUniform3f(uColor, 0.2f, 0.42f, 0.9f);
            foreach (i, g; gpu)
                if (!isHidden(i))
                {
                    forPart(i);
                    glBindVertexArray(g.edgeVao);
                    glDrawArrays(GL_LINES, 0, g.edgeCount + g.tangentCount);
                    glBindVertexArray(g.outlineVao);
                    glDrawArrays(GL_LINES, 0, g.outlineCount);
                }
            glDisable(GL_BLEND);
            glUniform1f(uAlpha, 1);
            if (!ghost)
                glDepthMask(GL_TRUE);
            glEnable(GL_DEPTH_TEST);
        }
        foreach (i, g; gpu)
        {
            if (isHidden(i) || shading == Shading.shaded)
                continue;
            forPart(i);
            // the outline of a part picked whole (picked faces and edges show themselves);
            // in wireframe, where no surface shows the pick, thick and yellow
            immutable whole = i == selected.part && selected.face < 0 && selected.edge < 0 && selected.vertex < 0;
            if (whole && wire)
            {
                auto c = standOut(parts[i].rgb, Vec3(1.0, 0.86, 0.0), Vec3(0.15, 0.35, 0.95), 0.32);
                glUniform3f(uColor, cast(float) c.x, cast(float) c.y, cast(float) c.z);
                glLineWidth(2.5);
            }
            else if (whole)
            {
                auto c = standOut(parts[i].rgb, Vec3(0.75, 0.45, 0.0), Vec3(0.12, 0.3, 0.85), 0.32);
                glUniform3f(uColor, cast(float) c.x, cast(float) c.y, cast(float) c.z);
            }
            else if (wire && darkStyle)   // over the background, not over a surface
                glUniform3f(uColor, 0.88f, 0.9f, 0.93f);
            else
                glUniform3f(uColor, 0.13f, 0.14f, 0.16f);
            // the edges of a see-through part fade with it; crowded edges (a
            // thread seen from afar) fade too, or the part turns black
            immutable crowd = edgeFade(g);
            immutable faded = !ghost && (transparent(i) || crowd < 1);
            if (faded)
            {
                glEnable(GL_BLEND);
                glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                glUniform1f(uAlpha, cast(float)(transparent(i) ? min(1.0, alphaOf(parts[i].rgb) + 0.25) * crowd : crowd));
            }
            glBindVertexArray(g.edgeVao);
            glDrawArrays(GL_LINES, 0, wire ? g.edgeCount + g.tangentCount : g.edgeCount);
            if (wire)
            {
                glBindVertexArray(g.outlineVao);
                glDrawArrays(GL_LINES, 0, g.outlineCount);
            }
            glLineWidth(1);
            if (faded)
            {
                glDisable(GL_BLEND);
                glUniform1f(uAlpha, 1);
            }
        }
        if (ghost)
        {
            glDisable(GL_BLEND);
            glDepthMask(GL_TRUE);
            glUniform1f(uAlpha, 1);
        }

        forPart(-1);
        // the picked vertices, as dots
        foreach (h; selection())
            if (h.vertex >= 0 && h.part >= 0 && h.part < parts.length)
                drawKnob(vertexAt(h.part, h.vertex),
                    standOut(parts[h.part].rgb, Vec3(1.0, 0.86, 0.0), Vec3(0.15, 0.35, 0.95), 0.32), handlePixels - 1);
        // the picked edges, thick
        foreach (h; selection())
            if (h.edge >= 0 && h.part < parts.length && h.edge < parts[h.part].edgeInfo.length)
                drawPolyline(edgePoints(h.part, parts[h.part].edgeInfo[h.edge]),
                    standOut(parts[h.part].rgb, Vec3(1.0, 0.86, 0.0), Vec3(0.15, 0.35, 0.95), 0.32), 4);

        renderPlanes();
        renderSketches();
        renderDrawing();
        drawGizmo();
        if (placing)
            drawPlace();
        else
            drawHoverMark();
        drawButtons();
        glBindVertexArray(0);
        if (onFrame !is null)
            onFrame();
        return true;
    }

    void renderRollback()
    {
        if (rollbackDirty)
        {
            freeGpu(rollbackGpu);
            rollbackGpu = uploadMesh(rollbackMesh);
            rollbackDirty = false;
        }
        // the solid at this step, its new faces highlighted
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1, 1);
        glUniform1i(uFlat, 0);
        auto c = rgbOf(rollbackMesh.rgb);
        glUniform3f(uColor, cast(float) c.x, cast(float) c.y, cast(float) c.z);
        glBindVertexArray(rollbackGpu.vao);
        glDrawElements(GL_TRIANGLES, rollbackGpu.indexCount, GL_UNSIGNED_INT, null);
        glDisable(GL_POLYGON_OFFSET_FILL);
        auto fs = rollbackMesh.faceStart;
        auto nc = standOut(rollbackMesh.rgb, Vec3(1.0, 0.62, 0.1), Vec3(0.3, 0.5, 1.0));
        glUniform3f(uColor, cast(float) nc.x, cast(float) nc.y, cast(float) nc.z);
        foreach (f, id; rollbackMesh.creators)
            if (id == rollbackFeature && f + 1 < fs.length)
                glDrawElements(GL_TRIANGLES, cast(int)((fs[f + 1] - fs[f]) * 3), GL_UNSIGNED_INT,
                    cast(void*)(fs[f] * 3 * uint.sizeof));
        glUniform1i(uFlat, 1);
        glUniform3f(uColor, 0.13f, 0.14f, 0.16f);
        glBindVertexArray(rollbackGpu.edgeVao);
        glDrawArrays(GL_LINES, 0, rollbackGpu.edgeCount);
        renderGhosts();
    }

    /// What Inspect shows: solids in orange with their edges, profiles
    /// filled see-through with a strong outline, paths as lines.
    /// A sketch being drawn: what is clicked so far, on to the pointer, and where it would snap.
    void renderDrawing()
    {
        immutable drawing = Vec3(0.95, 0.45, 0.05);
        foreach (l; drawingLines)
            if (l.length > 1)
                drawPolyline(l, drawing, 2);
        foreach (q; drawingPoints)
            drawKnob(q, drawing, handlePixels - 3);
        foreach (q; drawingSnap)
        {
            // where the pointer snaps, in violet, all of one size: a square round a point of the sketch (the point
            // left as it is), a triangle round a line's middle, a cross where lines cross
            auto b = basis();
            immutable r = (handlePixels - 1) * mmPerPixelAt(q);
            auto u = b.right * r, v = b.up * r;
            immutable violet = Vec3(0.62, 0.2, 0.85);
            if (drawingSnapKind == 0)
                drawPolyline([q + u + v, q - u + v, q - u - v, q + u - v, q + u + v], violet, 3);
            else if (drawingSnapKind == 1)
                drawPolyline([q + v, q - u * 0.87 - v * 0.5, q + u * 0.87 - v * 0.5, q + v], violet, 3);
            else
            {
                drawPolyline([q - u - v, q + u + v], violet, 3);
                drawPolyline([q - u + v, q + u - v], violet, 3);
            }
        }
    }

    void renderInspect()
    {
        if (inspectDirty)
        {
            foreach (ref g; inspectGpu)
                freeGpu(g);
            inspectGpu = null;
            foreach (m; inspectItems)
                inspectGpu ~= uploadMesh(m);
            inspectDirty = false;
        }
        immutable orange = Vec3(1.0, 0.62, 0.1), outline = Vec3(0.8, 0.33, 0.0);
        immutable coloured = inspectColors.length == inspectItems.length && inspectItems.length;
        void color(Vec3 c) => glUniform3f(uColor, cast(float) c.x, cast(float) c.y, cast(float) c.z);
        Vec3 fill(size_t i) => coloured ? inspectColors[i] : orange;
        Vec3 line(size_t i) => coloured ? inspectColors[i] * 0.7 : outline;

        // solids, pushed back so their edges draw on top; in colours they are
        // see-through, so that one operand inside the other shows
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1, 1);
        glUniform1i(uFlat, 0);
        if (coloured)
        {
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glDepthMask(GL_FALSE);
            glUniform1f(uAlpha, 0.45);
        }
        foreach (i, m; inspectItems)
            if (!m.flat && !m.path)
            {
                color(fill(i));
                glBindVertexArray(inspectGpu[i].vao);
                glDrawElements(GL_TRIANGLES, inspectGpu[i].indexCount, GL_UNSIGNED_INT, null);
            }
        if (coloured)
        {
            glDisable(GL_BLEND);
            glDepthMask(GL_TRUE);
            glUniform1f(uAlpha, 1);
        }
        glDisable(GL_POLYGON_OFFSET_FILL);
        glUniform1i(uFlat, 1);
        glUniform3f(uColor, 0.13f, 0.14f, 0.16f);
        foreach (i, m; inspectItems)
            if (!m.flat && !m.path)
            {
                glBindVertexArray(inspectGpu[i].edgeVao);
                glDrawArrays(GL_LINES, 0, inspectGpu[i].edgeCount);
            }

        // profiles: see-through, lifted over faces they lie on
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDepthMask(GL_FALSE);
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(-2, -2);
        glUniform1f(uAlpha, 0.45);
        foreach (i, m; inspectItems)
            if (m.flat)
            {
                color(fill(i));
                glBindVertexArray(inspectGpu[i].vao);
                glDrawElements(GL_TRIANGLES, inspectGpu[i].indexCount, GL_UNSIGNED_INT, null);
            }
        glDisable(GL_POLYGON_OFFSET_FILL);
        glDepthMask(GL_TRUE);
        glDisable(GL_BLEND);
        glUniform1f(uAlpha, 1);

        // outlines of profiles and paths, over everything
        glDisable(GL_DEPTH_TEST);
        glLineWidth(3);
        foreach (i, m; inspectItems)
            if (m.flat || m.path)
            {
                color(line(i));
                glBindVertexArray(inspectGpu[i].edgeVao);
                glDrawArrays(GL_LINES, 0, inspectGpu[i].edgeCount);
            }
        glLineWidth(1);
        glEnable(GL_DEPTH_TEST);
        renderGhosts();
    }

    /// The final parts as faint ghosts (rollback and Inspect).
    void renderGhosts()
    {
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDepthMask(GL_FALSE);
        glUniform1f(uAlpha, 0.12);
        glUniform1i(uFlat, 0);
        foreach (i, g; gpu)
        {
            if (isHidden(i))
                continue;
            auto pc = rgbOf(parts[i].rgb);
            glUniform3f(uColor, cast(float) pc.x, cast(float) pc.y, cast(float) pc.z);
            glBindVertexArray(g.vao);
            glDrawElements(GL_TRIANGLES, g.indexCount, GL_UNSIGNED_INT, null);
        }
        glDisable(GL_BLEND);
        glDepthMask(GL_TRUE);
        glUniform1f(uAlpha, 1);
    }

    void renderSketches()
    {
        glUniform1i(uClipOn, 0);
        if (section)
            drawSectionOutline();
        if (!sketchShown)
            return;
        if (sketchDirty)
            uploadSketches();
        if (sketchBodiesDirty)
        {
            foreach (ref g; sketchBodyGpu)
                freeGpu(g);
            sketchBodyGpu = null;
            foreach (b, m; sketchBodies)
                sketchBodyGpu[b] = uploadMesh(m);
            sketchBodiesDirty = false;
        }
        // a sketch on a face: the solid it is drawn on, faint, as it was then
        {
            bool[Brep] drawn;
            foreach (i; shownSketches)
                if (i < sketches.length && sketches[i].body !is null && (sketches[i].body in drawn) is null)
                    if (auto g = sketches[i].body in sketchBodyGpu)
                    {
                        drawn[sketches[i].body] = true;
                        glEnable(GL_BLEND);
                        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                        glDepthMask(GL_FALSE);
                        glUniform1i(uFlat, 0);
                        glUniform1f(uAlpha, 0.22);
                        glUniform3f(uColor, 0.06f, 0.76f, 0.95f);   // the parts' colour (Sky Pop)
                        glBindVertexArray(g.vao);
                        glDrawElements(GL_TRIANGLES, g.indexCount, GL_UNSIGNED_INT, null);
                        // its edges, so that its shape reads
                        glUniform1i(uFlat, 1);
                        glUniform1f(uAlpha, 0.6);
                        glUniform3f(uColor, 0.10f, 0.30f, 0.40f);
                        glBindVertexArray(g.edgeVao);
                        glDrawArrays(GL_LINES, 0, g.edgeCount);
                        glUniform1f(uAlpha, 1);
                        glDepthMask(GL_TRUE);
                        glDisable(GL_BLEND);
                    }
        }
        glDisable(GL_DEPTH_TEST);
        // what the profile will fill, tinted and lightly striped, under the lines
        if (sketchFillCount)
        {
            glDepthMask(GL_FALSE);
            glBindVertexArray(sketchFillVao);
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glUniform1i(uFlat, 3);
            glUniform1f(uAlpha, darkStyle ? 0.22 : 0.18);
            glUniform3f(uColor, 0.06f, 0.76f, 0.95f);   // the parts' colour (Sky Pop)
            glDrawArrays(GL_TRIANGLES, 0, sketchFillCount);
            glDisable(GL_BLEND);
            glDepthMask(GL_TRUE);
            glUniform1f(uAlpha, 1);
        }
        glUniform1i(uFlat, 1);
        // the last good sketch, while the code has an error: faint
        bool faded;
        foreach (i; shownSketches)
            faded = faded || (i < fadedSketches.length && fadedSketches[i]);
        if (faded)
        {
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glUniform1f(uAlpha, 0.4);
        }
        glBindVertexArray(sketchVao);
        // a face's edges and what was projected onto the sketch: references, in violet, under the rest
        glLineWidth(2);
        if (darkStyle)
            glUniform3f(uColor, 0.78f, 0.55f, 1.0f);
        else
            glUniform3f(uColor, 0.55f, 0.20f, 0.75f);
        glDrawArrays(GL_LINES, sketchRanges[5], sketchRanges[6] - sketchRanges[5]);
        glPointSize(4);
        glDrawArrays(GL_POINTS, sketchRanges[6], sketchRanges[7] - sketchRanges[6]);
        glPointSize(1);
        glLineWidth(2);
        if (darkStyle)
            glUniform3f(uColor, 0.45f, 0.65f, 1.0f);
        else
            glUniform3f(uColor, 0.10f, 0.25f, 0.65f);
        glDrawArrays(GL_LINES, 0, sketchRanges[0]);
        glLineWidth(1);
        glUniform3f(uColor, 0.55f, 0.6f, 0.7f);
        glDrawArrays(GL_LINES, sketchRanges[0], sketchRanges[1] - sketchRanges[0]);
        // what the inspected line made or constrains, in Inspect's orange
        glLineWidth(4);
        glUniform3f(uColor, 1.0f, 0.55f, 0.05f);
        glDrawArrays(GL_LINES, sketchRanges[1], sketchRanges[2] - sketchRanges[1]);
        glLineWidth(1);
        glPointSize(8);
        // blue points can still move, black ones are fully constrained
        glUniform3f(uColor, 0.15f, 0.45f, 0.95f);
        glDrawArrays(GL_POINTS, sketchRanges[2], sketchRanges[3] - sketchRanges[2]);
        if (darkStyle)
            glUniform3f(uColor, 0.92f, 0.92f, 0.95f);
        else
            glUniform3f(uColor, 0.05f, 0.05f, 0.08f);
        glDrawArrays(GL_POINTS, sketchRanges[3], sketchRanges[4] - sketchRanges[3]);
        // the points of fills (s.fill): the areas' colour, deeper, a little larger: they mark an area, not a corner
        glPointSize(10);
        glUniform3f(uColor, 0.0f, 0.62f, 0.78f);
        glDrawArrays(GL_POINTS, sketchRanges[7], sketchRanges[8] - sketchRanges[7]);
        glPointSize(11);
        glUniform3f(uColor, 1.0f, 0.55f, 0.05f);
        glDrawArrays(GL_POINTS, sketchRanges[4], sketchRanges[5] - sketchRanges[4]);
        glPointSize(1);
        if (faded)
        {
            glUniform1f(uAlpha, 1);
            glDisable(GL_BLEND);
        }
        glEnable(GL_DEPTH_TEST);
    }

    /// Whether the sketch drawn is faint (the last good one, while the code has an error).
    bool sketchFaded() const
    {
        foreach (i; shownSketches)
            if (i < fadedSketches.length && fadedSketches[i])
                return true;
        return false;
    }

    void uploadSketches()
    {
        float[] lines, construction, litLines, freePts, fixedPts, litPts, refLines, refPts, fillPts, fill;

        // a sketch on a face is drawn where it lies
        SketchView placing;
        void add(ref float[] a, Vec3 v)
        {
            v = placing.world(v);
            a ~= [cast(float) v.x, cast(float) v.y, cast(float) v.z];
        }

        foreach (s, index; shownSketches)
        {
            if (index >= sketches.length)
                continue;
            auto sk = sketches[index];
            placing = sk;
            auto lit = litEntities[s];
            // the dashes of construction lines: from the sketch's size
            double dash = 1;
            {
                Vec3 lo = Vec3(double.max, double.max, 0), hi = Vec3(-double.max, -double.max, 0);
                foreach (p; sk.points)
                {
                    lo = Vec3(min(lo.x, p.pos.x), min(lo.y, p.pos.y), 0);
                    hi = Vec3(max(hi.x, p.pos.x), max(hi.y, p.pos.y), 0);
                }
                if (sk.points.length)
                    dash = max(0.2, (hi - lo).length / 150);
            }
            foreach (g; sk.segments)
            {
                Vec3[] pts;
                if (g.kind == 0)
                    pts = [g.a, g.b];
                else if (g.kind == 4)
                {
                    import hackerscad.geom.spline : sampleSpline;
                    pts = sampleSpline(g.poles);
                }
                else
                {
                    import std.math : atan2;
                    double a0 = 0, a1 = 2 * PI;
                    if (g.kind == 1)
                    {
                        a0 = atan2(g.a.y - g.c.y, g.a.x - g.c.x);
                        a1 = atan2(g.b.y - g.c.y, g.b.x - g.c.x);
                        while (a1 <= a0 + 1e-9)
                            a1 += 2 * PI;
                    }
                    immutable n = 48;
                    // an ellipse: r along its own x axis, turned by g.angle, r2 across
                    immutable r2 = g.kind == 3 ? g.r2 : g.r;
                    immutable ux = Vec3(cos(g.angle), sin(g.angle), 0), uy = Vec3(-sin(g.angle), cos(g.angle), 0);
                    foreach (k; 0 .. n + 1)
                    {
                        immutable t = a0 + (a1 - a0) * k / n;
                        pts ~= g.c + ux * (g.r * cos(t)) + uy * (r2 * sin(t));
                    }
                }
                // a fillet's arc stands out with its corner point
                immutable on = (g.entity >= 0 && (cast(size_t) g.entity in lit) !is null)
                    || (g.corner >= 0 && (cast(size_t) g.corner in lit) !is null);
                if (g.construction && !g.reference)
                {
                    // construction: dashed, a fixed share of the sketch's size each dash and gap
                    double gone = 0;
                    foreach (j; 0 .. pts.length - 1)
                    {
                        immutable len = (pts[j + 1] - pts[j]).length;
                        double t = 0;
                        while (t < len)
                        {
                            immutable phase = (gone + t) % (2 * dash);
                            immutable step = min(len - t, phase < dash ? dash - phase : 2 * dash - phase);
                            if (phase < dash)
                            {
                                // selected: orange, dashed still
                                add(on ? litLines : construction, pts[j] + (pts[j + 1] - pts[j]) * (t / len));
                                add(on ? litLines : construction, pts[j] + (pts[j + 1] - pts[j]) * ((t + step) / len));
                            }
                            t += max(step, 1e-9);
                        }
                        gone += len;
                    }
                    continue;
                }
                foreach (j; 0 .. pts.length - 1)
                {
                    add(on ? litLines : g.reference ? refLines : g.construction ? construction : lines, pts[j]);
                    add(on ? litLines : g.reference ? refLines : g.construction ? construction : lines, pts[j + 1]);
                }
            }
            foreach (p; sk.points)
                add((p.entity in lit) !is null ? litPts : p.reference ? refPts : p.fill ? fillPts : p.free ? freePts
                    : fixedPts, p.pos);
            // the areas the profile fills: their triangles
            foreach (r; sk.regions)
                if (r.full)
                    foreach (q; r.triangles)
                        add(fill, q);
        }
        positionBuffer(sketchFillVao, sketchFillVbo, fill);
        sketchFillCount = cast(int)(fill.length / 3);
        auto all = lines ~ construction ~ litLines ~ freePts ~ fixedPts ~ litPts ~ refLines ~ refPts ~ fillPts;
        int end = 0;
        foreach (i, part; [lines, construction, litLines, freePts, fixedPts, litPts, refLines, refPts, fillPts])
        {
            end += cast(int)(part.length / 3);
            sketchRanges[i] = end;
        }
        positionBuffer(sketchVao, sketchVbo, all);
        glBindVertexArray(0);
        sketchDirty = false;
    }

    uint lineVao, lineVbo;

    void drawPolyline(Vec3[] pts, Vec3 color, float width)
    {
        float[] v;
        foreach (k; 0 .. pts.length - 1)
            foreach (q; [pts[k], pts[k + 1]])
                v ~= [cast(float) q.x, cast(float) q.y, cast(float) q.z];
        uploadLines(v);
        glUniform1i(uFlat, 1);
        glUniform3f(uColor, cast(float) color.x, cast(float) color.y, cast(float) color.z);
        glLineWidth(width);
        glDisable(GL_DEPTH_TEST);
        glDrawArrays(GL_LINES, 0, cast(int)(v.length / 3));
        glEnable(GL_DEPTH_TEST);
        glLineWidth(1);
    }

    void freeGpu(ref Gpu g)
    {
        if (g.vao == 0)
            return;
        if (g.printVao)
        {
            glDeleteVertexArrays(1, &g.printVao);
            glDeleteBuffers(1, &g.printEbo);
        }
        glDeleteVertexArrays(1, &g.vao);
        glDeleteVertexArrays(1, &g.edgeVao);
        glDeleteBuffers(1, &g.vbo);
        glDeleteBuffers(1, &g.ebo);
        glDeleteBuffers(1, &g.edgeVbo);
        if (g.outlineVao)
        {
            glDeleteVertexArrays(1, &g.outlineVao);
            glDeleteBuffers(1, &g.outlineVbo);
        }
        g = Gpu.init;
    }

    void upload()
    {
        // a part whose mesh did not change (the evaluator keeps it) keeps
        // its buffers: an edit re-uploads only what it changed
        Gpu[] next;
        auto used = new bool[gpu.length];
        foreach (p; parts)
        {
            ptrdiff_t old = -1;
            foreach (j, g; gpu)
                if (!used[j] && g.source is p.vertices && p.vertices.length)
                {
                    old = j;
                    break;
                }
            if (old >= 0)
            {
                used[old] = true;
                next ~= gpu[old];
            }
            else
                next ~= uploadMesh(p);
        }
        foreach (j, ref g; gpu)
            if (!used[j])
                freeGpu(g);
        gpu = next;
        glBindVertexArray(0);
        dirty = false;
        gridExtent = 0; // force a grid rebuild sized on the new parts
    }

    Gpu uploadMesh(PartMesh p)
    {
        {
            Gpu g;
            glGenVertexArrays(1, &g.vao);
            glBindVertexArray(g.vao);
            glGenBuffers(1, &g.vbo);
            glBindBuffer(GL_ARRAY_BUFFER, g.vbo);
            glBufferData(GL_ARRAY_BUFFER, p.vertices.length * float.sizeof, p.vertices.ptr, GL_STATIC_DRAW);
            glGenBuffers(1, &g.ebo);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, g.ebo);
            glBufferData(GL_ELEMENT_ARRAY_BUFFER, p.indices.length * uint.sizeof, p.indices.ptr, GL_STATIC_DRAW);
            glEnableVertexAttribArray(0);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * float.sizeof, null);
            glEnableVertexAttribArray(1);
            glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * float.sizeof, cast(void*)(3 * float.sizeof));
            g.indexCount = cast(int) p.indices.length;
            g.source = p.vertices;

            positionBuffer(g.edgeVao, g.edgeVbo, p.edges ~ p.tangentEdges, GL_STATIC_DRAW);
            g.edgeCount = cast(int)(p.edges.length / 3);
            g.tangentCount = cast(int)(p.tangentEdges.length / 3);
            {
                double lo0 = double.max, lo1 = double.max, lo2 = double.max;
                double hi0 = -double.max, hi1 = -double.max, hi2 = -double.max;
                for (size_t j = 0; j + 5 < p.edges.length; j += 6)
                {
                    g.edgeLength += sqrt((p.edges[j + 3] - p.edges[j]) ^^ 2 + (p.edges[j + 4] - p.edges[j + 1]) ^^ 2
                        + (p.edges[j + 5] - p.edges[j + 2]) ^^ 2);
                    foreach (o; [0, 3])
                    {
                        lo0 = min(lo0, p.edges[j + o]); hi0 = max(hi0, p.edges[j + o]);
                        lo1 = min(lo1, p.edges[j + o + 1]); hi1 = max(hi1, p.edges[j + o + 1]);
                        lo2 = min(lo2, p.edges[j + o + 2]); hi2 = max(hi2, p.edges[j + o + 2]);
                    }
                }
                double[3] d = [max(hi0 - lo0, 0.1), max(hi1 - lo1, 0.1), max(hi2 - lo2, 0.1)];
                import std.algorithm : sort;
                d[].sort!"a > b";
                g.spanA = d[0];
                g.spanB = d[1];
            }
            glBindVertexArray(0);
            return g;
        }
    }

    /// Overhangs steeper than this from a wall (radians), and walls thinner
    /// than this (mm), for the printability marks.
    public double overhangAngle = PI / 4, minWall = 0.8;

    /// Draws part `i` in colour `rgb` (0xRRGGBB; its transparency stays) until
    /// the parts are replaced: the colour wheel's preview.
    public void previewColour(size_t i, uint rgb)
    {
        if (i >= parts.length)
            return;
        parts[i].rgb = (parts[i].rgb & 0xFF000000) | (rgb & 0xFFFFFF);
        redraw();
    }

    /// How shiny the shaded surfaces are.
    public Shine shine = Shine.normal;

    public void setShine(Shine s)
    {
        shine = s;
        redraw();
    }

    /// Whether the overhangs (red) and thin walls (violet) are marked, over
    /// any style.
    public bool printability;

    /// Marks the overhangs and thin walls, or not.
    public void setPrintability(bool on)
    {
        printability = on;
        redraw();
    }

    /// Sets the printability marks' limits.
    public void setPrintLimits(double angle, double wall)
    {
        overhangAngle = angle;
        minWall = wall;
        foreach (ref g; gpu)
            g.printValid = false;
        redraw();
    }

    /// What the printability marks find in part i (computed if needed: it
    /// takes a moment on large meshes).
    public PrintCheck printCheckOf(size_t i)
    {
        if (i >= parts.length)
            return PrintCheck.init;
        // a part not drawn yet (its buffers are another's): no cache
        if (i >= gpu.length || gpu[i].source !is parts[i].vertices)
            return checkPrint(parts[i].vertices, 6, parts[i].indices, overhangAngle, minWall);
        if (!gpu[i].printValid)
        {
            gpu[i].print = checkPrint(parts[i].vertices, 6, parts[i].indices, overhangAngle, minWall);
            gpu[i].printValid = true;
            gpu[i].overhangCount = -1;   // the buffers to make, on the drawing thread
        }
        return gpu[i].print;
    }

    /// The overhanging triangles in red and those over thin walls in violet,
    /// over the shaded parts (pushed back like for the picked faces); in
    /// wireframe, where the surfaces are not drawn, see-through.
    private void drawPrintability(bool wire)
    {
        if (wire)
        {
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glUniform1f(uAlpha, 0.55);
        }
        scope (exit)
            if (wire)
            {
                glDisable(GL_BLEND);
                glUniform1f(uAlpha, 1);
            }
        foreach (i, ref g; gpu)
        {
            if (isHidden(i) || i >= parts.length)
                continue;
            forPart(i);
            auto pc = printCheckOf(i);
            if (g.overhangCount < 0)
            {
                uint[] over, thin;
                auto idx = parts[i].indices;
                foreach (t; 0 .. idx.length / 3)
                {
                    if (pc.isThin(t))
                        thin ~= idx[t * 3 .. t * 3 + 3];
                    else if (pc.overhang[t])
                        over ~= idx[t * 3 .. t * 3 + 3];
                }
                if (!g.printVao)
                {
                    glGenVertexArrays(1, &g.printVao);
                    glBindVertexArray(g.printVao);
                    glBindBuffer(GL_ARRAY_BUFFER, g.vbo);
                    glEnableVertexAttribArray(0);
                    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * float.sizeof, null);
                    glEnableVertexAttribArray(1);
                    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * float.sizeof, cast(void*)(3 * float.sizeof));
                    glGenBuffers(1, &g.printEbo);
                }
                glBindVertexArray(g.printVao);
                glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, g.printEbo);
                auto all = over ~ thin;
                glBufferData(GL_ELEMENT_ARRAY_BUFFER, all.length * uint.sizeof, all.ptr, GL_STATIC_DRAW);
                g.overhangCount = cast(int) over.length;
                g.thinCount = cast(int) thin.length;
            }
            glBindVertexArray(g.printVao);
            // red with white stripes, violet cross-hatched; darker on a part of
            // a near colour (a red part), so the marks keep their meaning
            if (g.overhangCount > 0)
            {
                auto c = standOut(parts[i].rgb, Vec3(0.90, 0.25, 0.20), Vec3(0.55, 0.05, 0.08), 0.2);
                glUniform3f(uColor, cast(float) c.x, cast(float) c.y, cast(float) c.z);
                glUniform1i(uPattern, 1);
                glDrawElements(GL_TRIANGLES, g.overhangCount, GL_UNSIGNED_INT, null);
            }
            if (g.thinCount > 0)
            {
                auto c = standOut(parts[i].rgb, Vec3(0.58, 0.36, 0.88), Vec3(0.32, 0.12, 0.6), 0.2);
                glUniform3f(uColor, cast(float) c.x, cast(float) c.y, cast(float) c.z);
                glUniform1i(uPattern, 2);
                glDrawElements(GL_TRIANGLES, g.thinCount, GL_UNSIGNED_INT, cast(void*)(g.overhangCount * uint.sizeof));
            }
        }
        glUniform1i(uPattern, 0);
        glBindVertexArray(0);
        forPart(-1);
    }

    private float[] outlineScratch;

    /// The outline of part i's curved surfaces as seen now: in each of
    /// their triangles, where the normal (interpolated between its corners)
    /// is square to the line of sight.
    void uploadOutline(size_t i, ref Gpu g)
    {
        auto b = basis();
        // the same eye sees the same outline: hovering redraws, it does not move
        if (g.outlineValid && g.outlineEye == b.eye && g.outlineForward == b.forward
            && g.outlineOrthographic == orthographic)
            return;
        g.outlineEye = b.eye;
        g.outlineForward = b.forward;
        g.outlineOrthographic = orthographic;
        g.outlineValid = true;
        auto c = parts[i].contour;
        outlineScratch.length = 0;
        outlineScratch.assumeSafeAppend();
        for (size_t j = 0; j + 17 < c.length; j += 18)
        {
            Vec3[3] p;
            double[3] f;   // > 0: facing the eye
            foreach (k; 0 .. 3)
            {
                p[k] = Vec3(c[j + k * 3], c[j + k * 3 + 1], c[j + k * 3 + 2]);
                auto n = Vec3(c[j + 9 + k * 3], c[j + 10 + k * 3], c[j + 11 + k * 3]);
                f[k] = n.dot(orthographic ? b.forward * -1 : b.eye - p[k]);
            }
            foreach (k; 0 .. 3)
            {
                immutable l = (k + 1) % 3;
                if ((f[k] > 0) == (f[l] > 0))
                    continue;
                auto q = p[k] + (p[l] - p[k]) * (f[k] / (f[k] - f[l]));
                outlineScratch ~= [cast(float) q.x, cast(float) q.y, cast(float) q.z];
            }
        }
        positionBuffer(g.outlineVao, g.outlineVbo, outlineScratch, GL_STREAM_DRAW);
        g.outlineCount = cast(int)(outlineScratch.length / 3);
    }

    void updateGrid()
    {
        double extent = 50, floor = 0;
        foreach (p; parts)
        {
            extent = max(extent, abs(p.bbox.min.x), abs(p.bbox.max.x), abs(p.bbox.min.y), abs(p.bbox.max.y));
            floor = min(floor, p.bbox.min.z); // keep the grid under models that go below z = 0
        }
        immutable z = cast(float) floor;
        immutable step = extent > 400 ? 50.0 : extent > 100 ? 10.0 : 5.0;
        extent = (cast(int)(extent * 1.3 / step) + 1) * step;
        if (extent == gridExtent && z == gridZ)
            return;
        gridExtent = cast(float) extent;
        gridZ = z;

        float[] v = [0, 0, z, cast(float) extent, 0, z, 0, 0, z, 0, cast(float) extent, z]; // X and Y axes
        for (double t = -extent; t <= extent + 1e-9; t += step)
        {
            v ~= [cast(float) t, cast(float) -extent, z, cast(float) t, cast(float) extent, z];
            v ~= [cast(float) -extent, cast(float) t, z, cast(float) extent, cast(float) t, z];
        }
        positionBuffer(gridVao, gridVbo, v, GL_STATIC_DRAW);
        gridCount = cast(int)(v.length / 3);
        glBindVertexArray(0);
    }

    /// Part and face under window point (x, y) (ray cast on the CPU).
    Hit pick(double x, double y)
    {
        Vec3 eye, dir;
        ray(x, y, eye, dir);
        Hit best;
        foreach (pi, p; parts)
        {
            if (isHidden(pi))
                continue;
            // the previewed part is hit where it is drawn: the ray carried
            // into its own place (the move and turn keep lengths, so the
            // distances along it are the same)
            immutable moved = previewing(pi);
            auto from = moved ? unplaced(eye) : eye, along = moved ? unplacedDir(dir) : dir;
            // a part whose box the ray misses, or reaches behind what it
            // already hit, has no triangle to test (hovering picks often)
            immutable entry = rayBox(from, along, p.bbox);
            if (!(entry < best.distance))
                continue;
            Vec3 vtx(uint i) => Vec3(p.vertices[i * 6], p.vertices[i * 6 + 1], p.vertices[i * 6 + 2]);
            foreach (t; 0 .. p.indices.length / 3)
            {
                immutable d = intersect(from, along, vtx(p.indices[t * 3]), vtx(p.indices[t * 3 + 1]), vtx(p.indices[t * 3 + 2]));
                if (section && d > 0 && (eye + dir * d).dot(sectionNormal) > sectionOffset)
                    continue;
                if (d > 0 && d < best.distance)
                {
                    best.distance = d;
                    best.part = cast(int) pi;
                    best.face = faceOf(p.faceStart, t);
                    auto a = vtx(p.indices[t * 3]), b = vtx(p.indices[t * 3 + 1]), c = vtx(p.indices[t * 3 + 2]);
                    best.normal = (b - a).cross(c - a).normalized;
                    if (moved)
                        best.normal = placedNormal(best.normal);
                }
            }
        }
        if (best.part >= 0)
            best.point = eye + dir * best.distance;
        best.x = x;
        best.y = y;
        return best;
    }
}

private:

/// Where the ray enters the box (0 when it starts inside), or infinity
/// when it misses it. The box is grown a little: a ray along a face hits.
double rayBox(Vec3 origin, Vec3 dir, BBox box)
{
    enum grow = 1e-3;
    double near = 0, far = double.infinity;
    foreach (k; 0 .. 3)
    {
        immutable o = [origin.x, origin.y, origin.z][k], d = [dir.x, dir.y, dir.z][k];
        immutable lo = [box.min.x, box.min.y, box.min.z][k] - grow, hi = [box.max.x, box.max.y, box.max.z][k] + grow;
        if (abs(d) < 1e-15)
        {
            if (o < lo || o > hi)
                return double.infinity;
            continue;
        }
        double t0 = (lo - o) / d, t1 = (hi - o) / d;
        if (t0 > t1)
        {
            immutable t = t0;
            t0 = t1;
            t1 = t;
        }
        near = max(near, t0);
        far = min(far, t1);
        if (near > far)
            return double.infinity;
    }
    return near;
}

unittest
{
    auto box = BBox(Vec3(0, 0, 0), Vec3(10, 10, 10));
    assert(rayBox(Vec3(5, 5, -10), Vec3(0, 0, 1), box) > 9.9);
    assert(rayBox(Vec3(5, 5, -10), Vec3(1, 0, 0), box) == double.infinity);
    assert(rayBox(Vec3(5, 5, 5), Vec3(0, 0, 1), box) == 0);
}

int faceOf(const(uint)[] faceStart, size_t triangle)
{
    // faceStart is sorted: binary search for the face owning the triangle
    if (faceStart.length < 2)
        return -1;
    size_t lo = 0, hi = faceStart.length - 1;
    while (hi - lo > 1)
    {
        immutable mid = (lo + hi) / 2;
        if (faceStart[mid] <= triangle)
            lo = mid;
        else
            hi = mid;
    }
    return cast(int) lo;
}

/// Möller–Trumbore ray/triangle intersection; returns the distance or -1.
/// The edges count a hair beyond the triangle: a ray along the edge two
/// triangles share would otherwise miss both, by rounding, and go through.
double intersect(Vec3 o, Vec3 d, Vec3 a, Vec3 b, Vec3 c)
{
    enum eps = 1e-7;
    auto e1 = b - a, e2 = c - a;
    auto p = d.cross(e2);
    immutable det = e1.dot(p);
    if (abs(det) < 1e-12)
        return -1;
    immutable inv = 1 / det;
    auto s = o - a;
    immutable u = s.dot(p) * inv;
    if (u < -eps || u > 1 + eps)
        return -1;
    auto q = s.cross(e1);
    immutable v = d.dot(q) * inv;
    if (v < -eps || u + v > 1 + eps)
        return -1;
    return e2.dot(q) * inv;
}

/// Points along a B-rep edge, for drawing, picking and measuring it.
public Vec3[] edgePolyline(EdgeInfo e)
{
    if (e.kind == EdgeKind.line)
        return [e.start, e.end];
    if (e.kind != EdgeKind.circle || e.radius <= 0)
        return [e.start, e.mid, e.end];
    import std.math : atan2;
    // angles in the circle's plane, from start through mid to end
    auto n = e.axis.normalized;
    auto u = (e.start - e.center).normalized;
    auto v = n.cross(u);
    double ang(Vec3 p)
    {
        auto d = p - e.center;
        double a = atan2(d.dot(v), d.dot(u));
        return a < 0 ? a + 2 * PI : a;
    }
    immutable am = ang(e.mid);
    double ae = ang(e.end);
    if ((e.end - e.start).length < 1e-9)
        ae = 2 * PI;
    immutable sweep = am <= ae ? ae : -(2 * PI - ae);   // go the way that passes through mid
    Vec3[] r;
    immutable steps = 32;
    foreach (k; 0 .. steps + 1)
    {
        immutable t = sweep * k / steps;
        r ~= e.center + (u * cos(t) + v * sin(t)) * e.radius;
    }
    return r;
}

double segmentDistance(double px, double py, double ax, double ay, double bx, double by)
{
    immutable dx = bx - ax, dy = by - ay;
    immutable l2 = dx * dx + dy * dy;
    double t = l2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0;
    t = max(0.0, min(1.0, t));
    immutable qx = ax + t * dx - px, qy = ay + t * dy - py;
    return sqrt(qx * qx + qy * qy);
}

/// `usual`, or `reserve` when `usual` would hardly show on a part of colour
/// `rgb` (a yellow face picked on a yellow part): for what is drawn on a part.
/// `near`: how different they must look (OKLab); striped marks want more,
/// thin lines more still (an orange edge on a yellow face hardly shows).
Vec3 standOut(uint rgb, Vec3 usual, Vec3 reserve, double near = 0.15)
{
    import std.math : lround;
    import hackerscad.geom.color : colourDistance;
    uint packed(Vec3 c) => cast(uint)(lround(c.x * 255) << 16 | lround(c.y * 255) << 8 | lround(c.z * 255));
    return colourDistance(rgb & 0xFFFFFF, packed(usual)) < near ? reserve : usual;
}

Vec3 rgbOf(uint rgb)
{
    return Vec3(((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0, (rgb & 0xFF) / 255.0);
}

float[16] perspective(double fov, double aspect, double near, double far)
{
    immutable f = 1 / tan(fov / 2);
    float[16] m = 0;
    m[0] = cast(float)(f / aspect);
    m[5] = cast(float) f;
    m[10] = cast(float)((far + near) / (near - far));
    m[11] = -1;
    m[14] = cast(float)(2 * far * near / (near - far));
    return m;
}

float[16] orthographicMatrix(double halfW, double halfH, double near, double far)
{
    float[16] m = 0;
    m[0] = cast(float)(1 / halfW);
    m[5] = cast(float)(1 / halfH);
    m[10] = cast(float)(-2 / (far - near));
    m[14] = cast(float)(-(far + near) / (far - near));
    m[15] = 1;
    return m;
}

float[16] lookAt(Vec3 eye, Vec3 center, Vec3 upHint)
{
    auto f = (center - eye).normalized;
    auto s = f.cross(upHint).normalized;
    auto u = s.cross(f);
    float[16] m = 0;
    m[0] = cast(float) s.x; m[4] = cast(float) s.y; m[8] = cast(float) s.z;
    m[1] = cast(float) u.x; m[5] = cast(float) u.y; m[9] = cast(float) u.z;
    m[2] = cast(float) -f.x; m[6] = cast(float) -f.y; m[10] = cast(float) -f.z;
    m[12] = cast(float) -s.dot(eye);
    m[13] = cast(float) -u.dot(eye);
    m[14] = cast(float) f.dot(eye);
    m[15] = 1;
    return m;
}

float[16] multiply(float[16] a, float[16] b)
{
    float[16] r = 0;
    foreach (col; 0 .. 4)
        foreach (row; 0 .. 4)
            foreach (k; 0 .. 4)
                r[col * 4 + row] += a[k * 4 + row] * b[col * 4 + k];
    return r;
}

enum vertexShader = `#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNrm;
uniform mat4 uMvp;
uniform mat4 uModel;   // where the part is: moved or turned while previewed, else none
out vec3 vNrm;
out vec3 vPos;
void main()
{
    // in the world, so that the section, the light and the eye see it where it is drawn
    vNrm = mat3(uModel) * aNrm;
    vPos = (uModel * vec4(aPos, 1.0)).xyz;
    gl_Position = uMvp * vec4(vPos, 1.0);
}
`;

enum fragmentShader = `#version 330 core
in vec3 vNrm;
in vec3 vPos;
uniform vec3 uColor;
uniform vec3 uEye;
uniform int uFlat;
uniform int uPattern;   // 1 diagonal stripes, 2 a cross-hatch: marks that no part colour can be mistaken for;
                        // 3 thin dark stripes (picked faces), 4 light dots (a picked part)
uniform float uAlpha;
uniform int uClipOn;
uniform vec4 uClip;   // keeps dot(p, xyz) <= w
uniform int uSurface;   // 0 standard, 1 glossy (a matcap)
uniform int uEven;      // 1: matte light in parallel rays, a fixed line of sight: each flat face one even tone
uniform vec3 uForward;  // the line of sight, for that
uniform vec3 uRight;    // for glossy: the viewer's right and up, to see normals as on the screen
uniform vec3 uUp;
out vec4 frag;
void main()
{
    if (uClipOn == 1 && dot(vPos, uClip.xyz) > uClip.w)
        discard;
    if (uFlat == 1)
    {
        frag = vec4(uColor, uAlpha);
        return;
    }
    if (uFlat == 3)
    {
        // a sketch's area the profile fills: tinted, with faint stripes
        float stripe = mod(gl_FragCoord.x + gl_FragCoord.y, 12.0) < 1.5 ? 1.0 : 0.0;
        frag = vec4(uColor, uAlpha + 0.22 * stripe);
        return;
    }
    if (uFlat == 2)
    {
        // section cap: the solid's material, darker and hatched
        vec3 base = mix(uColor, vec3(0.95, 0.93, 0.88), 0.35);
        float line = mod(gl_FragCoord.x - gl_FragCoord.y, 9.0) < 2.2 ? 1.0 : 0.0;
        frag = vec4(mix(base, uColor * 0.35, line), 1.0);
        return;
    }
    vec3 n = normalize(vNrm);
    vec3 v = normalize(uEye - vPos);
    if (uClipOn == 1 && dot(n, v) < 0.0)
    {
        // the inside of a cut solid: hatched, like the cut face of a section
        float stripe = mod(gl_FragCoord.x + gl_FragCoord.y, 9.0) < 2.5 ? 0.45 : 0.75;
        frag = vec4(uColor * stripe, 1.0);
        return;
    }
    if (dot(n, v) < 0.0)
        n = -n;
    // light from the eye: the line to it changes over a face, which shades a
    // little; even light comes in parallel rays and is seen along one line,
    // so that a flat face takes one tone, highlight and all
    if (uEven == 1)
        v = -uForward;
    vec3 l = normalize(v + vec3(0.0, 0.0, 0.6));
    float diffuse = max(dot(n, l), 0.0);
    vec3 lit;
    if (uSurface == 1)
    {
        // glossy, as a matcap: the colour of a point from where its normal
        // points on the screen, as if photographed on a glossy sphere: a soft
        // highlight up and left, the body darker towards the outline, a faint
        // second highlight down and right; in linear light, then gamma
        vec3 base = pow(uColor, vec3(2.2));
        vec3 s = vec3(dot(n, uRight), dot(n, uUp), dot(n, v));
        float facing = clamp(s.z, 0.0, 1.0);
        vec3 spot = normalize(vec3(-0.35, 0.45, 0.82));
        float near = max(dot(s, spot), 0.0);
        float highlight = 1.1 * pow(near, 28.0) + 0.25 * pow(near, 5.0);
        float body = 0.18 + 0.82 * pow(facing, 0.8) * (0.9 + 0.1 * s.y);
        float bounce = 0.35 * pow(max(dot(s, normalize(vec3(0.5, -0.6, 0.62))), 0.0), 12.0);
        vec3 linear = base * body + vec3(highlight) + base * bounce;
        lit = pow(linear, vec3(1.0 / 2.2));
    }
    else
    {
        // even light is matte: a highlight on a surface curved both ways is a
        // round spot, whatever the light; without it, only the tone turns
        vec3 h = normalize(l + v);
        float specular = uEven == 1 ? 0.0 : pow(max(dot(n, h), 0.0), 48.0) * 0.22;
        lit = uColor * (0.34 + 0.66 * diffuse) + vec3(specular);
    }
    if (uPattern == 3)
        lit = mix(lit, lit * 0.62, mod(gl_FragCoord.x - gl_FragCoord.y, 24.0) < 4.0 ? 1.0 : 0.0);
    else if (uPattern == 4)
        lit = mix(lit, vec3(1.0), mod(gl_FragCoord.x, 22.0) < 5.0 && mod(gl_FragCoord.y, 22.0) < 5.0 ? 0.45 : 0.0);
    else if (uPattern > 0)
    {
        float a = mod(gl_FragCoord.x + gl_FragCoord.y, 10.0) < 4.0 ? 1.0 : 0.0;
        float b = uPattern == 2 && mod(gl_FragCoord.x - gl_FragCoord.y, 10.0) < 4.0 ? 1.0 : 0.0;
        lit = mix(lit, vec3(1.0), 0.6 * max(a, b));
    }
    frag = vec4(lit, uAlpha);
}
`;

uint buildProgram()
{
    uint compile(uint kind, string src)
    {
        auto s = glCreateShader(kind);
        auto p = src.toStringz;
        glShaderSource(s, 1, &p, null);
        glCompileShader(s);
        int ok;
        glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
        if (!ok)
        {
            char[1024] log;
            int n;
            glGetShaderInfoLog(s, log.length, &n, log.ptr);
            throw new Exception("shader: " ~ log[0 .. n].idup);
        }
        return s;
    }

    auto prog = glCreateProgram();
    glAttachShader(prog, compile(GL_VERTEX_SHADER, vertexShader));
    glAttachShader(prog, compile(GL_FRAGMENT_SHADER, fragmentShader));
    glLinkProgram(prog);
    return prog;
}
