/// Runs model evaluations on a worker thread. One evaluation at a time: a
/// new request cancels the running one, and only the latest result is
/// delivered, on the GTK main thread.
module hackerscad.gui.evaluator;

import core.atomic : atomicStore;
import core.thread : Thread;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.path : dirName, absolutePath;
import std.format : format;

import glib.global : idleAdd;
import glib.types : PRIORITY_DEFAULT;

import hackerscad.geom.mesh;
import hackerscad.geom.vec;
import hackerscad.kernel.brep;
import hackerscad.kernel.occt.backend;
import hackerscad.kernel.cache;
import hackerscad.lang.errors;
import hackerscad.lang.interp;
import hackerscad.render.raster : edgeSets, contourTriangles, smoothSeams;
import hackerscad.lang.sketchval : SketchView, sketchViews;
import hackerscad.lang.value : SolidVal;
import hackerscad.geom.color;

struct Request
{
    string source;
    string path;
    string[string] overrides;
    string preset;
    double tolerance = 0.02;
    ulong generation;
    bool tests;   /// run the model's unittests too
}

/// GPU-ready geometry of one part.
struct PartMesh
{
    string name;
    string fn;      /// the @part or @parts function it comes from (name, or for @parts its own)
    int piece = -1; /// @parts: which piece of what fn returns
    bool fromSolid; /// @parts: fn returns a Solid made into pieces (else a Solid[])
    string label;   /// the name in exported files: @part(name:), or `name`
    uint rgb;
    bool export_ = true;   /// false for reference parts
    float[] vertices;   /// x y z nx ny nz per vertex
    uint[] indices;
    uint[] faceStart;   /// B-rep face i owns triangles faceStart[i] .. faceStart[i + 1]
    uint[] creators;    /// per face: feature id (Outcome.features[id - 1])
    string[][] faceTags;   /// per face: its tags (empty: none has any)
    string[] tags;         /// the part's own tags
    float[] edges;      /// x y z pairs (feature edges)
    /// x y z pairs: where two faces meet without a corner (wireframe)
    float[] tangentEdges;
    /// the triangles of curved surfaces with a normal per corner (18 floats
    /// each, raster.contourTriangles): where the outline lies (wireframe)
    float[] contour;
    Mesh welded;        /// for picking and export
    Span span;
    BBox bbox;
    double volume;
    Brep brep;          /// exact solid, for STEP export
    BrepKernel kernel;
    EdgeInfo[] edgeInfo;    /// B-rep edges, for picking edges
    int[2][] edgeFaces;     /// the two faces of every edge
    bool flat;              /// a 2D profile (Inspect draws it filled, with its outline)
    bool path;              /// a curve: only edgeInfo and bbox are set
}

/// A @drawing of the model, laid out on its sheet (made on the worker: it projects the solids).
struct DrawingSheet
{
    import hackerscad.drawing.sheet : Sheet;
    string name;
    Sheet sheet;
    string error;   /// when it could not be laid out
}

struct Outcome
{
    ulong generation;
    bool ok;
    bool cancelled;
    PartMesh[] parts;
    ParamInfo[] params;
    string[] presets;
    FeatureInfo[] features;
    TraceEntry[] trace;       /// the geometry each call made (Inspect)
    FunctionInfo[] functions; /// of the model's file, for the feature tree (empty if it did not parse)
    SketchView[] sketches;
    PlaneMade[] planes;       /// planes the model's file made (plane(), offset, flip), to show
    PartMesh[] sketchBodies;  /// by sketch: the solid a sketch on a face is drawn on (empty for the others)
    LogLine[] log;
    Diagnostic[] diagnostics;
    DrawingSheet[] drawings;  /// the @drawing sheets, laid out (or why one could not be)
    string[string] sources;   /// module path → source, to render diagnostics
    long milliseconds;
    size_t cacheHits, cacheMisses;
    size_t unittests;          /// how many the model has
    bool unittestsRan;         /// whether they ran this time
    size_t unittestsFailed;
}

/// What the worker computes with: the kernel and its caches. A run that does
/// not stop when told keeps the one it has, and the runs after it get new ones.
private final class Engine
{
    CachingKernel kernel;
    PartMesh[Brep] prepared;
    PartMesh[Brep] inspected;   /// meshes made by prepareSolids
}

/// A run's stop sign, its own: a run left behind still finds it set.
private final class StopSign
{
    shared bool set;
}

final class Evaluator
{
    void delegate(Outcome) onResult;
    /// What the running evaluation is doing ("part 3 of 12: gear"), on the GTK thread.
    void delegate(string) onProgress;

    private Request pending;
    private bool hasPending;
    /// worker tasks waiting for the kernel: computed on the worker, they give
    /// back what to run on the GTK thread
    private void delegate() delegate(Engine)[] jobs;
    private bool running;
    private bool runningJob;    /// what runs is a job, not an evaluation
    private ulong run;          /// the run on the worker; one finished after it was left behind counts no more
    private ulong generation;
    private StopSign sign;
    // only the worker thread touches it, one run at a time
    private Engine engine;

    /// An evaluation is running or queued.
    bool busy() const => running || hasPending;

    void request(Request r)
    {
        r.generation = ++generation;
        pending = r;
        hasPending = true;
        if (running && !runningJob)
            stopRun();
        else if (!running)
            startNext();
    }

    /// Abandons the running evaluation and any queued one.
    void cancel()
    {
        hasPending = false;
        if (running)
            stopRun();
    }

    /// Tells the run to stop, and gives it a second: the interpreter stops
    /// between its steps, but an OpenCascade operation (a fillet, a boolean,
    /// the mesher) runs to its end, for minutes or for ever, and the window
    /// waited for it: no evaluation after it, every right-click operation
    /// refused ("wait for the evaluation to finish") until a restart. Still
    /// running then, it is left to end on its own with its kernel, its result
    /// dropped, and the next run starts on a new kernel.
    private void stopRun()
    {
        import glib.global : timeoutAdd;
        if (sign !is null)
            atomicStore(sign.set, true);
        immutable stopped = run;
        timeoutAdd(PRIORITY_DEFAULT, 1000, () {
            if (running && run == stopped)
            {
                ++run;
                running = false;
                engine = new Engine;
                if (hasPending || jobs.length)
                    startNext();
            }
            return false;
        });
    }

    /// Tessellates the solid left by a feature (for rollback views) on the
    /// worker thread; `done` runs on the GTK thread.
    void prepareFeature(FeatureInfo f, string name, void delegate(PartMesh) done)
    {
        if (f.result is null || f.result.brep is null || f.result.path)
            return;
        prepareSolids([f.result], (PartMesh[] ms) {
            if (ms[0].vertices.length == 0)
                return;
            auto m = ms[0];
            m.name = m.fn = name;
            m.span = f.span;
            done(m);
        });
    }

    /// Tessellates solids and profiles, and outlines paths (for Inspect), on
    /// the worker thread; `done` gets one mesh per value, in order, on the GTK
    /// thread (empty when it could not be made).
    void prepareSolids(SolidVal[] vals, void delegate(PartMesh[]) done)
    {
        jobs ~= (Engine e) {
            auto ms = new PartMesh[vals.length];
            // a few hundred values are kept: Inspect goes back and forth on the same lines
            if (e.inspected.length > 400)
                e.inspected = null;
            foreach (i, v; vals)
            {
                if (v is null || v.brep is null)
                    continue;
                if (auto old = v.brep in e.inspected)
                {
                    ms[i] = *old;
                    continue;
                }
                PartResult p;
                p.solid = v;
                p.rgb = v.hasColor ? v.rgb : defaultPartColor;
                p.span = v.origin;
                try
                {
                    if (v.path)
                    {
                        ms[i].bbox = e.kernel.bbox(v.brep);
                        ms[i].edgeInfo = e.kernel.edges(v.brep);
                        ms[i].brep = v.brep;
                    }
                    else if (auto old = v.brep in e.prepared)
                        ms[i] = *old;
                    else
                        ms[i] = prepare(e.kernel, p, 0.02);
                    ms[i].flat = v.flat;
                    ms[i].path = v.path;
                    e.inspected[v.brep] = ms[i];
                }
                catch (Exception)
                {
                }
            }
            return () => done(ms);
        };
        if (!running)
            startNext();
    }

    private void startNext()
    {
        if (engine is null)
            engine = new Engine;
        auto e = engine;
        immutable mine = ++run;
        running = true;
        if (!hasPending && jobs.length)
        {
            auto job = jobs[0];
            jobs = jobs[1 .. $];
            runningJob = true;
            auto t = new Thread({
                if (e.kernel is null)
                    e.kernel = new CachingKernel(new OcctKernel);
                auto deliver = job(e);
                idleAdd(PRIORITY_DEFAULT, () {
                    if (run == mine)
                    {
                        deliver();
                        ended();
                    }
                    return false;
                });
            });
            t.isDaemon = true;
            t.start();
            return;
        }
        auto req = pending;
        hasPending = false;
        runningJob = false;
        auto s = sign = new StopSign;
        void progress(string what)
        {
            idleAdd(PRIORITY_DEFAULT, () {
                if (running && run == mine && onProgress !is null)
                    onProgress(what);
                return false;
            });
        }

        auto t = new Thread({
            if (e.kernel is null)
                e.kernel = new CachingKernel(new OcctKernel);
            auto o = evaluate(req, &s.set, e.kernel, e.prepared, &progress);
            idleAdd(PRIORITY_DEFAULT, () {
                // left behind (it did not stop in time): another run took its place
                if (run == mine)
                    finished(o);
                return false;
            });
        });
        t.isDaemon = true;
        t.start();
    }

    private void finished(Outcome o)
    {
        running = false;
        if (!o.cancelled && o.generation == generation && onResult !is null)
            onResult(o);
        if (hasPending || jobs.length)
            startNext();
    }

    /// The run on the worker is over: the next, if any.
    private void ended()
    {
        running = false;
        if (hasPending || jobs.length)
            startNext();
    }
}

/// Evaluates on a kernel cache shared with previous evaluations: only what
/// the edit changed is computed again. `prepared` keeps the GPU meshes of
/// solids that did not change.
Outcome evaluate(Request req, shared(bool)* cancel, CachingKernel kernel, ref PartMesh[Brep] prepared,
    void delegate(string) stage = null)
{
    Outcome o;
    o.generation = req.generation;
    auto sw = StopWatch(AutoStart.yes);
    kernel.beginRun();
    scope (exit)
        kernel.endRun();
    auto it = new Interp(kernel);
    it.root = dirName(absolutePath(req.path));
    it.overrides = req.overrides;
    it.preset = req.preset;
    it.cancel = cancel;
    it.onStage = stage;
    it.recordTrace = true;
    it.runUnittests = req.tests;
    try
    {
        auto r = it.runSource(req.source, absolutePath(req.path));
        PartMesh[Brep] still;
        foreach (i, p; r.parts)
        {
            // an unchanged solid keeps its mesh; name, colour and provenance may differ
            PartMesh m;
            if (auto old = p.solid.brep in prepared)
            {
                m = *old;
                m.name = p.name;
                m.fn = p.fn;
                m.piece = p.piece;
                m.fromSolid = p.fromSolid;
                m.label = p.label;
                m.rgb = p.rgb;
                m.export_ = p.export_;
                m.span = p.span;
                m.creators = p.solid.creators;
                m.faceTags = p.solid.faceTags;
                m.tags = p.solid.tags;
            }
            else
            {
                if (stage !is null)
                    stage(format("meshing %d of %d: %s", i + 1, r.parts.length, p.name));
                m = prepare(kernel, p, req.tolerance);
            }
            still[p.solid.brep] = m;
            o.parts ~= m;
        }
        prepared = still;
        o.params = r.params;
        o.presets = r.presets;
        o.unittests = r.unittests;
        o.unittestsRan = r.unittestsRan;
        o.unittestsFailed = r.unittestsFailed;
        o.features = r.features;
        o.trace = r.trace;
        o.log = r.log;
        o.diagnostics = r.diagnostics;
        // the drawings' sheets: their views projected here, on the worker, with its kernel
        foreach (d; r.drawings)
        {
            import hackerscad.lang.drawingval : DrawingVal;
            if (stage !is null)
                stage("drawing " ~ d.name);
            DrawingSheet ds;
            ds.name = d.name;
            try
                ds.sheet = (cast(DrawingVal) d.drawing).render();
            catch (Exception e)
                ds.error = e.msg;
            o.drawings ~= ds;
        }
        o.ok = true;
    }
    catch (HcadError e)
    {
        if (e.msg == "evaluation cancelled")
            o.cancelled = true;
        o.diagnostics = [e.diag];
        o.params = it.params;
        o.presets = it.presetNames;
        o.log = it.log;
        // what ran before the error, to inspect where it went wrong
        it.finishTrace();
        o.trace = it.trace;
    }
    catch (KernelException e)
        o.diagnostics = [Diagnostic(Severity.error, Code.kernel, e.msg, Span(req.path))];
    o.functions = it.functionsOf(absolutePath(req.path));
    // sketches are shown even when the evaluation failed (conflicting
    // constraints, an error after them): then marked partial
    o.sketches = sketchViews(it, absolutePath(req.path), !o.ok);
    // the planes kept in variables of the module nothing used yet: shown too
    if (o.ok)
        it.touchPlaneGlobals(absolutePath(req.path));
    foreach (p; it.planes)
        if (p.span.file == absolutePath(req.path))
            o.planes ~= p;
    // the solids sketches on faces are drawn on, to show under them (once each)
    {
        PartMesh[Brep] made;
        o.sketchBodies = new PartMesh[o.sketches.length];
        foreach (i, sk; o.sketches)
            if (sk.body !is null)
            {
                if (auto had = sk.body in made)
                {
                    o.sketchBodies[i] = *had;
                    continue;
                }
                try
                {
                    PartResult pr;
                    pr.name = "sketch body";
                    pr.solid = new SolidVal(sk.body, sk.span);
                    o.sketchBodies[i] = made[sk.body] = prepare(kernel, pr, req.tolerance);
                }
                catch (Exception)
                {
                    // not shown under the sketch
                }
            }
    }
    foreach (path, m; it.modules)
        o.sources[path] = m.source;
    o.milliseconds = sw.peek.total!"msecs";
    o.cacheHits = kernel.hits;
    o.cacheMisses = kernel.misses;
    return o;
}

/// Tessellates a part: smooth normals inside each B-rep face (the kernel
/// emits separate vertices per face), sharp edges between faces.
PartMesh prepare(BrepKernel k, PartResult p, double tolerance)
{
    PartMesh m;
    m.name = p.name;
    m.fn = p.fn;
    m.piece = p.piece;
    m.fromSolid = p.fromSolid;
    m.label = p.label;
    m.rgb = p.rgb;
    m.export_ = p.export_;
    m.span = p.span;
    m.bbox = k.bbox(p.solid.brep);
    try
        m.volume = k.volume(p.solid.brep);
    catch (KernelException)
        m.volume = double.nan;   // an invalid solid may have none
    m.brep = p.solid.brep;
    // exports run on the GTK thread: give them the uncached kernel
    auto cached = cast(CachingKernel) k;
    m.kernel = cached ? cached.inner : k;

    auto raw = k.tessellate(p.solid.brep, tolerance, 0.25);
    auto normals = new Vec3[raw.vertexCount];
    foreach (t; 0 .. raw.triangleCount)
    {
        auto ia = raw.tris[t * 3], ib = raw.tris[t * 3 + 1], ic = raw.tris[t * 3 + 2];
        auto a = raw.vertex(ia), b = raw.vertex(ib), c = raw.vertex(ic);
        auto n = (b - a).cross(c - a); // area weighted
        normals[ia] = normals[ia] + n;
        normals[ib] = normals[ib] + n;
        normals[ic] = normals[ic] + n;
    }
    smoothSeams(raw, normals);
    m.vertices = new float[raw.vertexCount * 6];
    foreach (i; 0 .. raw.vertexCount)
    {
        auto n = normals[i].normalized;
        m.vertices[i * 6 .. i * 6 + 6] = [raw.verts[i * 3], raw.verts[i * 3 + 1], raw.verts[i * 3 + 2],
            cast(float) n.x, cast(float) n.y, cast(float) n.z];
    }
    m.indices = raw.tris;
    m.faceStart = raw.faceStart;
    m.creators = p.solid.creators;
    m.faceTags = p.solid.faceTags;
    m.tags = p.solid.tags;

    m.edgeInfo = k.edges(p.solid.brep);
    m.edgeFaces = k.edgeFaces(p.solid.brep);

    m.welded = raw.welded;
    uint[2][] sharp, tangent;
    edgeSets(m.welded, 25, sharp, tangent);
    foreach (e; sharp)
        foreach (v; e)
            m.edges ~= m.welded.verts[v * 3 .. v * 3 + 3];
    foreach (e; tangent)
        foreach (v; e)
            m.tangentEdges ~= m.welded.verts[v * 3 .. v * 3 + 3];
    m.contour = contourTriangles(m.welded, 25);
    return m;
}
