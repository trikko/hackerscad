/// 3MF export: one object per part, with names and colours, so slicers see
/// separate bodies instead of a single merged mesh.
module hackerscad.io.threemf;

import std.algorithm : canFind;
import std.array : appender, join;
import std.format : formattedWrite;
import std.zip : ArchiveMember, ZipArchive, CompressionMethod;
import std.file : write;

import hackerscad.geom.mesh;
import hackerscad.geom.color : defaultPartColor, hexColor;

struct Part
{
    string name;
    Mesh mesh;   /// should be welded and closed
    uint rgb = defaultPartColor;   /// 0xTTRRGGBB, see hexColor
    string[] tags;         /// the part's own: the object's metadata
    string[][] faceTags;   /// per face of mesh.faceStart: its triangles a named set per tag
}

/// With `assembly` (a name), the parts are the pieces of one object of
/// that name, as slicers want them for prints in several colours or
/// materials; without, each is an object of its own.
ubyte[] to3mf(const Part[] parts, string assembly = null)
{
    auto zip = new ZipArchive;
    void add(string name, string content)
    {
        auto m = new ArchiveMember;
        m.name = name;
        m.expandedData = cast(ubyte[]) content.dup;
        m.compressionMethod = CompressionMethod.deflate;
        zip.addMember(m);
    }

    add("[Content_Types].xml", `<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
 <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
 <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
</Types>`);
    add("_rels/.rels", `<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>`);
    add("3D/3dmodel.model", modelXml(parts, assembly));
    return cast(ubyte[]) zip.build();
}

void write3mf(const Part[] parts, string path, string assembly = null)
{
    write(path, to3mf(parts, assembly));
}

private string modelXml(const Part[] parts, string assembly)
{
    auto o = appender!string;
    o ~= `<?xml version="1.0" encoding="UTF-8"?>` ~ "\n";
    import hackerscad.about : madeWith, appWebsite;
    // the triangle sets extension: the faces' tags as named sets of triangles
    o ~= `<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"`
        ~ ` xmlns:t="http://schemas.microsoft.com/3dmanufacturing/trianglesets/2021/07"`
        ~ ` xmlns:hackerscad="` ~ appWebsite ~ `">` ~ "\n";
    o ~= " <metadata name=\"Application\">" ~ xmlEscape(madeWith) ~ "</metadata>\n";
    o ~= " <resources>\n  <basematerials id=\"1\">\n";
    foreach (p; parts)
        o.formattedWrite("   <base name=\"%s\" displaycolor=\"%s\"/>\n", xmlEscape(p.name), hexColor(p.rgb));
    o ~= "  </basematerials>\n";
    foreach (i, p; parts)
    {
        o.formattedWrite("  <object id=\"%d\" name=\"%s\" type=\"model\" pid=\"1\" pindex=\"%d\">\n   <mesh>\n    <vertices>\n",
            i + 2, xmlEscape(p.name), i);
        foreach (v; 0 .. p.mesh.vertexCount)
            o.formattedWrite("     <vertex x=\"%.6g\" y=\"%.6g\" z=\"%.6g\"/>\n",
                p.mesh.verts[v * 3], p.mesh.verts[v * 3 + 1], p.mesh.verts[v * 3 + 2]);
        o ~= "    </vertices>\n    <triangles>\n";
        foreach (t; 0 .. p.mesh.triangleCount)
            o.formattedWrite("     <triangle v1=\"%d\" v2=\"%d\" v3=\"%d\"/>\n",
                p.mesh.tris[t * 3], p.mesh.tris[t * 3 + 1], p.mesh.tris[t * 3 + 2]);
        o ~= "    </triangles>\n";
        sets(o, p);
        o ~= "   </mesh>\n";
        if (p.tags.length)
            o.formattedWrite("   <metadatagroup>\n    <metadata name=\"hackerscad:tags\">%s</metadata>\n   </metadatagroup>\n",
                xmlEscape(p.tags.join("; ")));
        o ~= "  </object>\n";
    }
    if (assembly.length)
    {
        // one object made of the others, each a component in place
        immutable id = parts.length + 2;
        o.formattedWrite("  <object id=\"%d\" name=\"%s\" type=\"model\">\n   <components>\n", id, xmlEscape(assembly));
        foreach (i; 0 .. parts.length)
            o.formattedWrite("    <component objectid=\"%d\"/>\n", i + 2);
        o ~= "   </components>\n  </object>\n";
        o.formattedWrite(" </resources>\n <build>\n  <item objectid=\"%d\"/>\n", id);
    }
    else
    {
        o ~= " </resources>\n <build>\n";
        foreach (i; 0 .. parts.length)
            o.formattedWrite("  <item objectid=\"%d\"/>\n", i + 2);
    }
    o ~= " </build>\n</model>\n";
    return o[];
}

/// The triangles of each tag of the part's faces, a set named by it (ranges of the faces' runs).
private void sets(ref typeof(appender!string()) o, const Part p)
{
    immutable n = p.faceTags.length;
    if (n == 0 || p.mesh.faceStart.length != n + 1)
        return;
    string[] tags;
    foreach (t; p.faceTags)
        foreach (x; t)
            if (!tags.canFind(x))
                tags ~= x;
    if (tags.length == 0)
        return;
    o ~= "    <t:trianglesets>\n";
    foreach (k, tag; tags)
    {
        o.formattedWrite("     <t:triangleset name=\"%s\" identifier=\"tag%d\">\n", xmlEscape(tag), k);
        foreach (f; 0 .. n)
            if (p.faceTags[f].canFind(tag) && p.mesh.faceStart[f + 1] > p.mesh.faceStart[f])
                o.formattedWrite("      <t:refrange startindex=\"%d\" endindex=\"%d\"/>\n", p.mesh.faceStart[f],
                    p.mesh.faceStart[f + 1] - 1);
        o ~= "     </t:triangleset>\n";
    }
    o ~= "    </t:trianglesets>\n";
}

private string xmlEscape(string s)
{
    import std.array : replace;
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace(`"`, "&quot;");
}

unittest
{
    import std.algorithm : canFind;

    Mesh m;
    m.verts = [0, 0, 0, 1, 0, 0, 0, 1, 0];
    m.tris = [0, 1, 2];
    auto zip = new ZipArchive(to3mf([Part("a<b", m, 0xFF8800)]));
    assert("3D/3dmodel.model" in zip.directory);
    auto model = cast(string) zip.expand(zip.directory["3D/3dmodel.model"]);
    assert(model.canFind(`name="a&lt;b"`));
    assert(model.canFind(`<metadata name="Application">hackerscad</metadata>`));

    // the faces' tags as named sets of their triangles, the part's own in its metadata
    Mesh two;
    two.verts = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1];
    two.tris = [0, 1, 2, 0, 1, 3, 0, 2, 3];
    two.faceStart = [0, 1, 3];
    auto tagged = cast(string) new ZipArchive(to3mf([Part("p", two, 0, ["body"], [["lid"], ["lid", "wall"]])]))
        .expand(new ZipArchive(to3mf([Part("p", two, 0, ["body"], [["lid"], ["lid", "wall"]])])).directory["3D/3dmodel.model"]);
    assert(tagged.canFind(`<t:triangleset name="lid" identifier="tag0">`) && tagged.canFind(`startindex="1" endindex="2"`));
    assert(tagged.canFind(`<t:triangleset name="wall"`) && tagged.canFind(`<metadata name="hackerscad:tags">body</metadata>`));
    assert(model.canFind(`displaycolor="#FF8800"`));

    // one object of two pieces: the build holds the assembly only
    auto one = cast(string) new ZipArchive(to3mf([Part("a", m), Part("b", m)], "clip"))
        .expand(new ZipArchive(to3mf([Part("a", m), Part("b", m)], "clip")).directory["3D/3dmodel.model"]);
    assert(one.canFind(`<object id="4" name="clip" type="model">`) && one.canFind(`<component objectid="3"/>`));
    assert(one.canFind(`<item objectid="4"/>`) && !one.canFind(`<item objectid="2"/>`));
}
