/// 3D view: shaded parts with outlined edges, a ground grid, the navigation
/// of CAD programs (right drag rotates, middle drag pans, the wheel zooms
/// towards the pointer) and face picking.
module hackerscad.gui.viewport;

import std.math : sin, cos, tan, atan, PI, abs, pow, sqrt;
import std.algorithm : clamp, min, max;
import std.string : toStringz;

import bindbc.opengl;

import gtk.glarea : GLArea;
import gtk.gesture_drag : GestureDrag;
import gtk.event_controller_scroll : EventControllerScroll;
import gtk.event_controller_motion : EventControllerMotion;
import gtk.types : EventControllerScrollFlags;
import gdk.glcontext : GLContext;
import gdk.types : ModifierType;

import hackerscad.geom.vec;
import hackerscad.geom.color : alphaOf;
import hackerscad.gui.evaluator : PartMesh;
import hackerscad.kernel.brep : EdgeInfo, EdgeKind;
import hackerscad.lang.sketchval : SketchView;

enum ViewPreset
{
    iso,
    front,
    top,
    right,
}

/// What a left-button drag does (right always rotates, middle always pans).
enum DragMode
{
    rotate,
    pan,
}

/// Result of a pick: part and B-rep face under the pointer.
struct Hit
{
    int part = -1;
    int face = -1;
    int edge = -1;      /// B-rep edge near the pointer, if any
    Vec3 point;
    Vec3 normal;            /// of the triangle hit
    double x = 0, y = 0;    /// window coordinates of the click
    bool shift;             /// Shift held: add to (or remove from) the selection
    double distance = double.infinity;
}

final class Viewport
{
    /// What to say in the view when the machine's OpenGL cannot draw it and
    /// the application knows why (set before the view is made).
    static string glHelp;
    /// Called, once the view has failed to get its OpenGL, with glHelp.
    void delegate(string help) onGlFailed;

    GLArea area;
    DragMode leftMode = DragMode.rotate;
    void delegate(Hit hit) onPick;    /// part -1 when clicking the background
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

    // sketches drawn over the model
    private SketchView[] sketches;
    private bool sketchMode;
    private uint sketchVao, sketchVbo;
    private bool sketchDirty;
    private int[4] sketchRanges;   /// lines, construction lines, free points, fixed points (end indices)

    private uint program, gridVao, gridVbo;
    private int gridCount;
    private float gridExtent, gridZ;
    private int uMvp, uColor, uEye, uFlat, uAlpha, uClipOn, uClip;

    // section plane: what lies where dot(p, sectionNormal) > sectionOffset is hidden
    private bool section;
    private Vec3 sectionNormal = Vec3(0, 0, 1);
    private double sectionOffset = 0;

    // camera: orbit around target, Z up
    private Vec3 target;
    private double distance = 150, yaw = -PI / 3, pitch = PI / 6;
    private enum fovy = 30.0 * PI / 180;

    // pointer and drag state
    private double pointerX = 0, pointerY = 0;
    private bool dragging, dragPan;
    private uint dragButton;
    private double startYaw, startPitch, startX, startY;
    private Vec3 startTarget;

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
            startX = x;
            startY = y;
            immutable button = g.getCurrentButton();
            immutable mods = g.getCurrentEventState();
            immutable shift = (mods & ModifierType.ShiftMask) != 0, ctrl = (mods & ModifierType.ControlMask) != 0;
            // right rotates, middle (or ctrl + right) pans; left follows the chosen mode
            if (button == 2)
                dragPan = true;
            else if (button == 3)
                dragPan = ctrl;
            else
                dragPan = (leftMode == DragMode.pan) != shift;
            dragButton = button;
            startShift = shift;
            startYaw = yaw;
            startPitch = pitch;
            startTarget = target;
            area.grabFocus();
        });
        drag.connectDragUpdate((double dx, double dy, GestureDrag g) {
            if (!dragging && abs(dx) + abs(dy) < 4)
                return;
            if (!dragging)
            {
                dragging = true;
                area.setCursorFromName(dragPan ? "move" : "grabbing");
            }
            if (dragPan)
            {
                auto c = basis();
                immutable k = 2 * distance * tan(fovy / 2) / max(1, area.getHeight());
                target = startTarget - c.right * (dx * k) + c.up * (dy * k);
            }
            else
            {
                yaw = startYaw - dx * 0.008;
                pitch = max(-PI / 2 + 0.01, min(PI / 2 - 0.01, startPitch + dy * 0.008));
            }
            area.queueRender();
        });
        drag.connectDragEnd((double dx, double dy, GestureDrag g) {
            // a left click without movement picks what is under the pointer
            if (!dragging && dragButton == 1 && onPick !is null)
            {
                auto h = pick(startX, startY);
                h.shift = startShift;
                onPick(h);
            }
            // a right click without movement opens the context menu
            if (!dragging && dragButton == 3 && onContext !is null)
                onContext(pick(startX, startY), startX, startY);
            dragging = false;
            updateHoverCursor();
        });
        area.addController(drag);

        auto motion = new EventControllerMotion;
        motion.connectMotion((double x, double y, EventControllerMotion m) {
            pointerX = x;
            pointerY = y;
            if (!dragging)
                updateHoverCursor();
        });
        motion.connectLeave(() {
            hover = Hit.init;
            area.queueRender();
        });
        area.addController(motion);

        auto scroll = new EventControllerScroll(EventControllerScrollFlags.Vertical);
        scroll.connectScroll((double dx, double dy, EventControllerScroll s) {
            // a wheel notch zooms by 10%; touchpads and smooth wheels report pixels: about 10% per 40 px
            import gdk.types : ScrollUnit;
            immutable steps = s.getUnit() == ScrollUnit.Wheel ? dy : dy / 40;
            zoomAt(pointerX, pointerY, pow(1.1, max(-2.0, min(2.0, steps))));
            return true;
        });
        area.addController(scroll);
    }

    /// Replaces the displayed parts; `fitView` frames them.
    void setParts(PartMesh[] p, bool fitView)
    {
        parts = p;
        hidden.length = parts.length;
        dirty = true;
        if (selected.part >= cast(int) parts.length)
            selected = Hit.init;
        if (fitView)
            fit();
        area.queueRender();
    }

    void select(Hit h)
    {
        selected = h;
        others = null;
        area.queueRender();
    }

    static bool sameItem(Hit a, Hit b) => a.part == b.part && a.edge == b.edge && (a.edge >= 0 || a.face == b.face);

    /// Shift+click: adds the item to the selection, or removes it if already there.
    void toggleSelect(Hit h)
    {
        if (selected.part < 0 || h.part != selected.part)
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
        area.queueRender();
    }

    /// Everything selected, in picking order (all on one part).
    Hit[] selection() => selected.part >= 0 ? others ~ selected : null;

    void setHidden(size_t part, bool hide)
    {
        if (part < hidden.length)
            hidden[part] = hide;
        area.queueRender();
    }

    bool isHidden(size_t part) => part < hidden.length && hidden[part];

    /// What a click at view coordinates (x, y) would pick.
    Hit pickAt(double x, double y) => pick(x, y);

    /// Shows the solid left by a feature, with its new faces highlighted
    /// and the final parts as ghosts.
    void showRollback(PartMesh m, uint feature)
    {
        rollback = true;
        rollbackMesh = m;
        rollbackFeature = feature;
        rollbackDirty = true;
        area.queueRender();
    }

    void clearRollback()
    {
        rollback = false;
        area.queueRender();
    }

    bool inRollback() const => rollback;

    /// Cuts the view with the plane dot(p, normal) = offset, hiding what lies on the normal's side.
    void setSection(bool on, Vec3 normal, double offset)
    {
        section = on;
        sectionNormal = normal.normalized;
        sectionOffset = offset;
        area.queueRender();
    }

    /// Where the parts start and end along a direction (for the section slider).
    void extentAlong(Vec3 n, out double lo, out double hi)
    {
        lo = double.infinity;
        hi = -double.infinity;
        foreach (i, p; parts)
        {
            if (isHidden(i))
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
            glBindVertexArray(g.vao);
            glDrawElements(GL_TRIANGLES, g.indexCount, GL_UNSIGNED_INT, null);
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

    /// Corners of a square on the section plane, a bit larger than the parts.
    Vec3[4] sectionQuad()
    {
        auto n = sectionNormal;
        auto u = (abs(n.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)).cross(n).normalized;
        auto v = n.cross(u);
        double size = 10;
        Vec3 c;
        size_t count;
        foreach (i, p; parts)
            if (!isHidden(i))
            {
                size = max(size, (p.bbox.max - p.bbox.min).length * 0.6);
                c = c + (p.bbox.min + p.bbox.max) * 0.5;
                count++;
            }
        if (count)
            c = c * (1.0 / count);
        c = c - n * (c.dot(n) - sectionOffset);
        return [c + u * size + v * size, c - u * size + v * size, c - u * size - v * size, c + u * size - v * size];
    }

    void drawSectionOutline()
    {
        // a rectangle on the plane, a bit larger than the parts
        auto n = sectionNormal;
        auto u = (abs(n.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)).cross(n).normalized;
        auto v = n.cross(u);
        double size = 10;
        Vec3 c;
        size_t count;
        foreach (i, p; parts)
            if (!isHidden(i))
            {
                size = max(size, (p.bbox.max - p.bbox.min).length * 0.6);
                c = c + (p.bbox.min + p.bbox.max) * 0.5;
                count++;
            }
        if (count)
            c = c * (1.0 / count);
        c = c - n * (c.dot(n) - sectionOffset);
        auto q = [c + u * size + v * size, c - u * size + v * size, c - u * size - v * size, c + u * size - v * size];
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
    }

    void uploadLines(float[] v)
    {
        if (lineVao == 0)
        {
            glGenVertexArrays(1, &lineVao);
            glGenBuffers(1, &lineVbo);
        }
        glBindVertexArray(lineVao);
        glBindBuffer(GL_ARRAY_BUFFER, lineVbo);
        glBufferData(GL_ARRAY_BUFFER, v.length * float.sizeof, v.ptr, GL_DYNAMIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, null);
        glVertexAttrib3f(1, 0, 0, 1);
    }

    void setSketches(SketchView[] s)
    {
        sketches = s;
        sketchDirty = true;
        area.queueRender();
    }

    void setSketchMode(bool on)
    {
        sketchMode = on;
        area.queueRender();
    }

    /// Window coordinates of a model point; false when behind the camera.
    bool project(Vec3 p, out double x, out double y)
    {
        auto b = basis();
        auto d = p - b.eye;
        immutable z = d.dot(b.forward);
        if (z <= 1e-9)
            return false;
        immutable w = max(1, area.getWidth()), h = max(1, area.getHeight());
        immutable t = tan(fovy / 2);
        x = (d.dot(b.right) / (z * t * w / h) + 1) * w / 2;
        y = (1 - d.dot(b.up) / (z * t)) * h / 2;
        return true;
    }

    /// The edge of the part nearest to window point (x, y), among the edges
    /// of `face` (all edges when face is -1), if closer than `within` pixels.
    int nearestEdge(int part, int face, double x, double y, double within = 10)
    {
        if (part < 0 || part >= parts.length)
            return -1;
        auto p = parts[part];
        int best = -1;
        double bestD = within;
        foreach (i, e; p.edgeInfo)
        {
            if (face >= 0 && i < p.edgeFaces.length && p.edgeFaces[i][0] != face && p.edgeFaces[i][1] != face)
                continue;
            auto pts = edgePolyline(e);
            foreach (k; 0 .. pts.length - 1)
            {
                double ax, ay, bx, by;
                if (!project(pts[k], ax, ay) || !project(pts[k + 1], bx, by))
                    continue;
                immutable d = segmentDistance(x, y, ax, ay, bx, by);
                if (d < bestD)
                {
                    bestD = d;
                    best = cast(int) i;
                }
            }
        }
        return best;
    }

    /// View size in logical pixels.
    int width() => area.getWidth();
    int height() => area.getHeight();

    /// Frames the parts; computed at the next frame, when the size is known.
    void fit()
    {
        fitPending = true;
        area.queueRender();
    }

    /// Looks at the model from direction `n` (pointing towards the viewer).
    void lookAlong(Vec3 n)
    {
        import std.math : atan2, asin;
        n = n.normalized;
        yaw = atan2(n.y, n.x);
        pitch = max(-PI / 2 + 0.001, min(PI / 2 - 0.001, asin(n.z)));
        fit();
    }

    void setView(ViewPreset v)
    {
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
        distance *= factor;
        area.queueRender();
    }

private:

    struct Gpu
    {
        uint vao, vbo, ebo, edgeVao, edgeVbo;
        int indexCount, edgeCount;
        /// total edge length and the two largest sizes (mm): how crowded the
        /// edges get on screen at a given zoom
        double edgeLength = 0, spanA = 1, spanB = 1;
    }

    struct Basis
    {
        Vec3 eye, forward, right, up;
    }

    Basis basis()
    {
        Basis b;
        b.eye = target + Vec3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch)) * distance;
        b.forward = (target - b.eye).normalized;
        b.right = b.forward.cross(Vec3(0, 0, 1)).normalized;
        b.up = b.right.cross(b.forward);
        return b;
    }

    /// Direction of the ray through window point (x, y).
    Vec3 ray(double x, double y)
    {
        auto b = basis();
        immutable w = max(1, area.getWidth()), h = max(1, area.getHeight());
        immutable t = tan(fovy / 2);
        immutable nx = 2 * x / w - 1, ny = 1 - 2 * y / h;
        return (b.forward + b.right * (nx * t * w / h) + b.up * (ny * t)).normalized;
    }

    /// Zooms by `factor` keeping the point under the pointer still: the
    /// model point hit by the ray, or the point on the plane through the
    /// target facing the camera.
    void zoomAt(double x, double y, double factor)
    {
        auto b = basis();
        auto hit = pick(x, y);
        Vec3 p;
        if (hit.part >= 0)
            p = hit.point;
        else
        {
            auto d = ray(x, y);
            immutable denom = d.dot(b.forward);
            p = abs(denom) > 1e-9 ? b.eye + d * ((target - b.eye).dot(b.forward) / denom) : target;
        }
        // scaling the camera about p keeps p at the same place on screen
        target = p + (target - p) * factor;
        distance = max(1e-3, distance * factor);
        area.queueRender();
    }

    void updateHoverCursor()
    {
        auto h = pick(pointerX, pointerY);
        area.setCursorFromName(null);   // the ring on the surface shows what is under the pointer
        // the point under the pointer is marked on the surface
        if (h.part >= 0 || hover.part >= 0)
        {
            hover = h;
            area.queueRender();
        }
    }

    Hit hover;

    /// A small ring lying on the surface under the pointer, the same size on screen at any zoom.
    void drawHoverMark()
    {
        if (hover.part < 0 || dragging)
            return;
        auto n = hover.normal;
        if (n.length < 0.5)
            return;
        // face the viewer
        if (n.dot(basis().eye - hover.point) < 0)
            n = n * -1;
        auto u = (abs(n.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)).cross(n).normalized;
        auto v = n.cross(u);
        immutable r = (basis().eye - hover.point).length * tan(fovy / 2) * 2 * 7 / max(1, area.getHeight());
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
            auto c = pass == 0 ? Vec3(0.08, 0.08, 0.1) : Vec3(1.0, 0.6, 0.05);
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
        Vec3 lo, hi;
        foreach (i, p; parts)
        {
            if (isHidden(i))
                continue;
            if (!any)
            {
                lo = p.bbox.min;
                hi = p.bbox.max;
                any = true;
                continue;
            }
            lo = Vec3(min(lo.x, p.bbox.min.x), min(lo.y, p.bbox.min.y), min(lo.z, p.bbox.min.z));
            hi = Vec3(max(hi.x, p.bbox.max.x), max(hi.y, p.bbox.max.y), max(hi.z, p.bbox.max.z));
        }
        if (!any)
            return;
        target = (lo + hi) / 2;
        immutable radius = max(1.0, (hi - lo).length / 2);
        // the narrower of the vertical and horizontal fields of view
        immutable fov = min(fovy, 2 * atan(tan(fovy / 2) * aspect));
        distance = radius / sin(fov / 2) * 1.02;
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
        program = buildProgram();
        uMvp = glGetUniformLocation(program, "uMvp");
        uColor = glGetUniformLocation(program, "uColor");
        uEye = glGetUniformLocation(program, "uEye");
        uFlat = glGetUniformLocation(program, "uFlat");
        uAlpha = glGetUniformLocation(program, "uAlpha");
        uClipOn = glGetUniformLocation(program, "uClipOn");
        uClip = glGetUniformLocation(program, "uClip");
        glGenVertexArrays(1, &gridVao);
        glGenBuffers(1, &gridVbo);
        glReady = true;
    }

    /// The GLArea's error, if any. Not through gid's area.getError(): its
    /// wrapper frees the error it does not own (gid 0.9.13), and GTK frees it
    /// again when the view goes, corrupting the heap.
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
        auto c = rgbOf(parts[i].rgb);
        if (i == selected.part && selected.face < 0)
            c = c * 0.6 + Vec3(1, 0.85, 0.2) * 0.4;
        glUniform3f(uColor, cast(float) c.x, cast(float) c.y, cast(float) c.z);
        glBindVertexArray(gpu[i].vao);
        glDrawElements(GL_TRIANGLES, gpu[i].indexCount, GL_UNSIGNED_INT, null);
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
            area.queueRender();
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

    bool render()
    {
        if (!glReady)
            return false;
        if (dirty)
            upload();

        glClearColor(0.925f, 0.93f, 0.945f, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
        glEnable(GL_DEPTH_TEST);
        glDepthFunc(GL_LEQUAL);

        immutable aspect = offscreen ? offscreenAspect : cast(double) max(1, area.getWidth()) / max(1, area.getHeight());
        if (fitPending)
            applyFit(aspect);
        auto b = basis();
        auto proj = perspective(fovy, aspect, distance * 0.01, distance * 100);
        auto view = lookAt(b.eye, target, Vec3(0, 0, 1));
        auto mvp = multiply(proj, view);

        glUseProgram(program);
        glUniformMatrix4fv(uMvp, 1, GL_FALSE, mvp.ptr);
        glUniform3f(uEye, cast(float) b.eye.x, cast(float) b.eye.y, cast(float) b.eye.z);
        glUniform1f(uAlpha, 1);

        // grid and axes
        updateGrid();
        glUniform1i(uFlat, 1);
        glBindVertexArray(gridVao);
        glUniform3f(uColor, 0.80f, 0.81f, 0.84f);
        glDrawArrays(GL_LINES, 4, gridCount - 4);
        glLineWidth(2);
        glUniform3f(uColor, 0.85f, 0.25f, 0.25f);
        glDrawArrays(GL_LINES, 0, 2);
        glUniform3f(uColor, 0.25f, 0.65f, 0.3f);
        glDrawArrays(GL_LINES, 2, 2);
        glLineWidth(1);

        // the section plane cuts the parts, not the grid
        glUniform1i(uClipOn, section ? 1 : 0);
        glUniform4f(uClip, cast(float) sectionNormal.x, cast(float) sectionNormal.y, cast(float) sectionNormal.z,
            cast(float) sectionOffset);

        if (rollback)
        {
            renderRollback();
            renderSketches();
            glBindVertexArray(0);
            if (onFrame !is null)
                onFrame();
            return true;
        }

        // in sketch mode the parts are see-through so the sketch shows
        immutable ghost = sketchMode && sketches.length;
        if (ghost)
        {
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glDepthMask(GL_FALSE);
            glUniform1f(uAlpha, 0.25);
        }

        // shaded parts, pushed back so their edges and the picked face draw on top
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1, 1);
        glUniform1i(uFlat, 0);
        foreach (i, g; gpu)
            if (!isHidden(i) && (ghost || !transparent(i)))
                drawShaded(i);
        glDisable(GL_POLYGON_OFFSET_FILL);
        if (section)
            capSection();
        if (!ghost)
            renderTransparent();

        // the picked faces, in highlight colour (an item near an edge is the edge)
        foreach (h; selection())
        {
            if (h.edge >= 0 || h.face < 0 || isHidden(h.part) || h.part >= gpu.length)
                continue;
            auto fs = parts[h.part].faceStart;
            if (h.face + 1 < fs.length)
            {
                glUniform3f(uColor, 1.0f, 0.78f, 0.15f);
                glBindVertexArray(gpu[h.part].vao);
                glDrawElements(GL_TRIANGLES, cast(int)((fs[h.face + 1] - fs[h.face]) * 3), GL_UNSIGNED_INT,
                    cast(void*)(fs[h.face] * 3 * uint.sizeof));
            }
        }

        glUniform1i(uFlat, 1);
        foreach (i, g; gpu)
        {
            if (isHidden(i))
                continue;
            if (i == selected.part)
                glUniform3f(uColor, 0.75f, 0.45f, 0.0f);
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
            glDrawArrays(GL_LINES, 0, g.edgeCount);
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

        // the picked edges, thick
        foreach (h; selection())
            if (h.edge >= 0 && h.part < parts.length && h.edge < parts[h.part].edgeInfo.length)
                drawPolyline(edgePolyline(parts[h.part].edgeInfo[h.edge]), Vec3(0.95, 0.45, 0.05), 4);

        renderSketches();
        drawHoverMark();
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
        glUniform3f(uColor, 1.0f, 0.62f, 0.1f);
        foreach (f, id; rollbackMesh.creators)
            if (id == rollbackFeature && f + 1 < fs.length)
                glDrawElements(GL_TRIANGLES, cast(int)((fs[f + 1] - fs[f]) * 3), GL_UNSIGNED_INT,
                    cast(void*)(fs[f] * 3 * uint.sizeof));
        glUniform1i(uFlat, 1);
        glUniform3f(uColor, 0.13f, 0.14f, 0.16f);
        glBindVertexArray(rollbackGpu.edgeVao);
        glDrawArrays(GL_LINES, 0, rollbackGpu.edgeCount);

        // the final parts as faint ghosts
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
        if (!sketchMode || sketches.length == 0)
            return;
        if (sketchDirty)
            uploadSketches();
        glDisable(GL_DEPTH_TEST);
        glUniform1i(uFlat, 1);
        glBindVertexArray(sketchVao);
        glLineWidth(2);
        glUniform3f(uColor, 0.10f, 0.25f, 0.65f);
        glDrawArrays(GL_LINES, 0, sketchRanges[0]);
        glLineWidth(1);
        glUniform3f(uColor, 0.55f, 0.6f, 0.7f);
        glDrawArrays(GL_LINES, sketchRanges[0], sketchRanges[1] - sketchRanges[0]);
        glPointSize(8);
        // blue points can still move, black ones are fully constrained
        glUniform3f(uColor, 0.15f, 0.45f, 0.95f);
        glDrawArrays(GL_POINTS, sketchRanges[1], sketchRanges[2] - sketchRanges[1]);
        glUniform3f(uColor, 0.05f, 0.05f, 0.08f);
        glDrawArrays(GL_POINTS, sketchRanges[2], sketchRanges[3] - sketchRanges[2]);
        glPointSize(1);
        glEnable(GL_DEPTH_TEST);
    }

    void uploadSketches()
    {
        float[] lines, construction, freePts, fixedPts;
        void add(ref float[] a, Vec3 v)
        {
            a ~= [cast(float) v.x, cast(float) v.y, cast(float) v.z];
        }

        foreach (sk; sketches)
        {
            foreach (g; sk.segments)
            {
                Vec3[] pts;
                if (g.kind == 0)
                    pts = [g.a, g.b];
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
                    foreach (k; 0 .. n + 1)
                    {
                        immutable t = a0 + (a1 - a0) * k / n;
                        pts ~= g.c + Vec3(g.r * cos(t), g.r * sin(t), 0);
                    }
                }
                foreach (k; 0 .. pts.length - 1)
                {
                    add(g.construction ? construction : lines, pts[k]);
                    add(g.construction ? construction : lines, pts[k + 1]);
                }
            }
            foreach (p; sk.points)
                add(p.free ? freePts : fixedPts, p.pos);
        }
        auto all = lines ~ construction ~ freePts ~ fixedPts;
        sketchRanges = [cast(int)(lines.length / 3), cast(int)((lines.length + construction.length) / 3),
            cast(int)((lines.length + construction.length + freePts.length) / 3), cast(int)(all.length / 3)];
        if (sketchVao == 0)
        {
            glGenVertexArrays(1, &sketchVao);
            glGenBuffers(1, &sketchVbo);
        }
        glBindVertexArray(sketchVao);
        glBindBuffer(GL_ARRAY_BUFFER, sketchVbo);
        glBufferData(GL_ARRAY_BUFFER, all.length * float.sizeof, all.ptr, GL_DYNAMIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, null);
        glVertexAttrib3f(1, 0, 0, 1);
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
        if (lineVao == 0)
        {
            glGenVertexArrays(1, &lineVao);
            glGenBuffers(1, &lineVbo);
        }
        glBindVertexArray(lineVao);
        glBindBuffer(GL_ARRAY_BUFFER, lineVbo);
        glBufferData(GL_ARRAY_BUFFER, v.length * float.sizeof, v.ptr, GL_DYNAMIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, null);
        glVertexAttrib3f(1, 0, 0, 1);
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
        glDeleteVertexArrays(1, &g.vao);
        glDeleteVertexArrays(1, &g.edgeVao);
        glDeleteBuffers(1, &g.vbo);
        glDeleteBuffers(1, &g.ebo);
        glDeleteBuffers(1, &g.edgeVbo);
        g = Gpu.init;
    }

    void upload()
    {
        foreach (ref g; gpu)
            freeGpu(g);
        gpu = null;
        foreach (p; parts)
            gpu ~= uploadMesh(p);
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

            glGenVertexArrays(1, &g.edgeVao);
            glBindVertexArray(g.edgeVao);
            glGenBuffers(1, &g.edgeVbo);
            glBindBuffer(GL_ARRAY_BUFFER, g.edgeVbo);
            glBufferData(GL_ARRAY_BUFFER, p.edges.length * float.sizeof, p.edges.ptr, GL_STATIC_DRAW);
            glEnableVertexAttribArray(0);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, null);
            glVertexAttrib3f(1, 0, 0, 1);
            g.edgeCount = cast(int)(p.edges.length / 3);
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
        glBindVertexArray(gridVao);
        glBindBuffer(GL_ARRAY_BUFFER, gridVbo);
        glBufferData(GL_ARRAY_BUFFER, v.length * float.sizeof, v.ptr, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, null);
        glVertexAttrib3f(1, 0, 0, 1);
        gridCount = cast(int)(v.length / 3);
        glBindVertexArray(0);
    }

    /// Part and face under window point (x, y) (ray cast on the CPU).
    Hit pick(double x, double y)
    {
        auto eye = basis().eye;
        auto dir = ray(x, y);
        Hit best;
        foreach (pi, p; parts)
        {
            if (isHidden(pi))
                continue;
            Vec3 vtx(uint i) => Vec3(p.vertices[i * 6], p.vertices[i * 6 + 1], p.vertices[i * 6 + 2]);
            foreach (t; 0 .. p.indices.length / 3)
            {
                immutable d = intersect(eye, dir, vtx(p.indices[t * 3]), vtx(p.indices[t * 3 + 1]), vtx(p.indices[t * 3 + 2]));
                if (section && d > 0 && (eye + dir * d).dot(sectionNormal) > sectionOffset)
                    continue;
                if (d > 0 && d < best.distance)
                {
                    best.distance = d;
                    best.part = cast(int) pi;
                    best.face = faceOf(p.faceStart, t);
                    auto a = vtx(p.indices[t * 3]), b = vtx(p.indices[t * 3 + 1]), c = vtx(p.indices[t * 3 + 2]);
                    best.normal = (b - a).cross(c - a).normalized;
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
double intersect(Vec3 o, Vec3 d, Vec3 a, Vec3 b, Vec3 c)
{
    auto e1 = b - a, e2 = c - a;
    auto p = d.cross(e2);
    immutable det = e1.dot(p);
    if (abs(det) < 1e-12)
        return -1;
    immutable inv = 1 / det;
    auto s = o - a;
    immutable u = s.dot(p) * inv;
    if (u < 0 || u > 1)
        return -1;
    auto q = s.cross(e1);
    immutable v = d.dot(q) * inv;
    if (v < 0 || u + v > 1)
        return -1;
    return e2.dot(q) * inv;
}

/// Points along a B-rep edge, for drawing and picking it.
Vec3[] edgePolyline(EdgeInfo e)
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

Vec3 rgbOf(uint rgb) => Vec3(((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0, (rgb & 0xFF) / 255.0);

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
out vec3 vNrm;
out vec3 vPos;
void main()
{
    vNrm = aNrm;
    vPos = aPos;
    gl_Position = uMvp * vec4(aPos, 1.0);
}
`;

enum fragmentShader = `#version 330 core
in vec3 vNrm;
in vec3 vPos;
uniform vec3 uColor;
uniform vec3 uEye;
uniform int uFlat;
uniform float uAlpha;
uniform int uClipOn;
uniform vec4 uClip;   // keeps dot(p, xyz) <= w
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
    vec3 l = normalize(v + vec3(0.0, 0.0, 0.6));
    float diffuse = max(dot(n, l), 0.0);
    vec3 h = normalize(l + v);
    float specular = pow(max(dot(n, h), 0.0), 48.0) * 0.22;
    frag = vec4(uColor * (0.34 + 0.66 * diffuse) + vec3(specular), uAlpha);
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
