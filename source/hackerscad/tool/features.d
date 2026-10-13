/// `hcad features` and the hcad_features tool: what a mesh or a model is made
/// of (geom/meshfeatures), as a report and as JSON, to remodel a part
/// given as STL.
module hackerscad.tool.features;

import std.file : exists, read, readText;
import std.format : format;
import std.json;
import std.path : extension;
import std.string : toLower;

import hackerscad.geom.mesh;
import hackerscad.geom.meshfeatures;
import hackerscad.geom.vec;

/// The triangles of `file`: a mesh (.stl, .obj, .3mf), a STEP file, or a
/// model (.hcad: its part `part`, or all of them). Throws with a message
/// for the user.
Mesh meshOf(string file, string part = null)
{
    import hackerscad.io.meshread;
    if (!exists(file))
        throw new Exception("file not found: " ~ file);
    immutable ext = extension(file).toLower;
    switch (ext)
    {
    case ".stl": return readStl(cast(const(ubyte)[]) read(file));
    case ".obj": return readObj(readText(file));
    case ".3mf": return read3mf(cast(const(ubyte)[]) read(file));
    case ".step", ".stp":
        {
            import hackerscad.kernel.occt.backend : OcctKernel;
            auto k = new OcctKernel;
            return k.tessellate(k.readStep(file), 0.01, 0.1);
        }
    case ".hcad":
        {
            import hackerscad.tool.runner : evaluateModel, RunOptions;
            RunOptions o;
            o.path = file;
            auto run = evaluateModel(o);
            if (!run.ok)
                throw new Exception(run.renderedDiagnostics());
            Mesh all;
            foreach (i, p; run.result.parts)
            {
                if (part.length && p.name != part && p.label != part)
                    continue;
                auto m = run.kernel.tessellate(p.solid.brep, 0.01, 0.1);
                immutable base = cast(uint) all.vertexCount;
                all.verts ~= m.verts;
                foreach (t; m.tris)
                    all.tris ~= base + t;
            }
            if (all.triangleCount == 0)
                throw new Exception(part.length ? "no part named " ~ part : "the model has no parts");
            return all;
        }
    default:
        throw new Exception(format("cannot read '%s': use .stl, .obj, .3mf, .step or .hcad", ext));
    }
}

private JSONValue v3(Vec3 v) => JSONValue([plausible(v.x), plausible(v.y), plausible(v.z)]);

/// The analysis as JSON: the size, every surface (rounded values with the
/// measured diameter alongside), the patterns.
JSONValue featuresJson(const Analysis a)
{
    import std.math : PI;
    JSONValue j = ["size_mm": v3(a.hi - a.lo), "min_mm": v3(a.lo), "max_mm": v3(a.hi)];
    JSONValue[] fs;
    foreach (i, f; a.features)
    {
        JSONValue jf = ["index": JSONValue(i), "area_mm2": JSONValue(plausible(f.area)), "triangles": JSONValue(f.triangles)];
        final switch (f.kind)
        {
        case Surface.plane:
            jf["kind"] = "plane";
            jf["normal"] = v3(f.normal);
            jf["offset_mm"] = plausible(f.offset);
            break;
        case Surface.cylinder:
            jf["kind"] = f.full ? (f.hole ? "hole" : "shaft") : (f.hole ? "inner rounding" : "rounding");
            jf["diameter_mm"] = plausible(f.diameter);
            jf["measured_diameter_mm"] = f.diameter;
            jf["radius_mm"] = plausible(f.radius);
            jf["length_mm"] = plausible(f.to - f.from);
            jf["axis"] = v3(f.axis);
            jf["start_mm"] = v3(f.point);
            jf["degrees"] = plausible(f.span * 180 / PI);
            if (f.hole && f.full)
                if (auto hint = holeHint(plausible(f.diameter)))
                    jf["likely"] = hint;
            break;
        case Surface.cone:
            jf["kind"] = f.hole ? "cone hole" : "cone";
            jf["diameter_mm"] = plausible(f.diameter);
            jf["half_angle_deg"] = plausible(f.halfAngle * 180 / PI);
            jf["length_mm"] = plausible(f.to - f.from);
            jf["axis"] = v3(f.axis);
            jf["start_mm"] = v3(f.point);
            break;
        case Surface.sphere:
            jf["kind"] = f.hole ? "hollow sphere" : "sphere";
            jf["diameter_mm"] = plausible(f.diameter);
            jf["center_mm"] = v3(f.point);
            break;
        case Surface.curved:
            jf["kind"] = "freeform";
            break;
        }
        jf["bbox_min_mm"] = v3(f.lo);
        jf["bbox_max_mm"] = v3(f.hi);
        jf["fit_error_mm"] = f.error;
        fs ~= jf;
    }
    j["surfaces"] = fs;
    JSONValue[] ps;
    foreach (p; a.patterns)
    {
        JSONValue jp = ["surfaces": JSONValue(p.members), "count": JSONValue(p.members.length)];
        jp["diameter_mm"] = plausible(a.features[p.members[0]].diameter);
        if (p.circular)
        {
            jp["kind"] = "circle";
            jp["center_mm"] = v3(p.center);
            jp["axis"] = v3(p.axis);
            jp["circle_radius_mm"] = plausible(p.radius);
            jp["step_deg"] = plausible(p.step * 180 / PI);
        }
        else
        {
            jp["kind"] = "row";
            jp["direction"] = v3(p.direction);
            jp["step_mm"] = plausible(p.step);
        }
        ps ~= jp;
    }
    j["patterns"] = ps;
    return j;
}
