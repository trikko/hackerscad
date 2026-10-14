/// 3MF export: one object per part, with names and colours, so slicers see
/// separate bodies instead of a single merged mesh.
module hackerscad.io.threemf;

import std.array : appender;
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
    o ~= `<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">` ~ "\n";
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
        o ~= "    </triangles>\n   </mesh>\n  </object>\n";
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
    assert(model.canFind(`displaycolor="#FF8800"`));

    // one object of two pieces: the build holds the assembly only
    auto one = cast(string) new ZipArchive(to3mf([Part("a", m), Part("b", m)], "clip"))
        .expand(new ZipArchive(to3mf([Part("a", m), Part("b", m)], "clip")).directory["3D/3dmodel.model"]);
    assert(one.canFind(`<object id="4" name="clip" type="model">`) && one.canFind(`<component objectid="3"/>`));
    assert(one.canFind(`<item objectid="4"/>`) && !one.canFind(`<item objectid="2"/>`));
}
