module hackerscad.render.png;

import std.bitmanip : nativeToBigEndian, littleEndianToNative;
import std.digest.crc : crc32Of;
import std.zlib : compress;

/// Encodes 8-bit RGB pixels (row-major, 3 bytes per pixel) as PNG.
ubyte[] encodePng(const(ubyte)[] rgb, uint width, uint height)
{
    assert(rgb.length == cast(size_t) width * height * 3);

    ubyte[] chunk(string type, const(ubyte)[] data)
    {
        auto body = cast(const(ubyte)[]) type ~ data;
        immutable crc = littleEndianToNative!uint(crc32Of(body));
        return nativeToBigEndian(cast(uint) data.length)[] ~ body ~ nativeToBigEndian(crc)[];
    }

    ubyte[] ihdr = nativeToBigEndian(width)[] ~ nativeToBigEndian(height)[] ~ cast(ubyte[])[8, 2, 0, 0, 0];

    auto raw = new ubyte[(width * 3 + 1) * height];
    foreach (y; 0 .. height)
    {
        immutable o = y * (width * 3 + 1);
        raw[o] = 0; // filter: none
        raw[o + 1 .. o + 1 + width * 3] = rgb[y * width * 3 .. (y + 1) * width * 3];
    }

    return cast(ubyte[])[0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n']
        ~ chunk("IHDR", ihdr) ~ chunk("IDAT", cast(ubyte[]) compress(raw, 9)) ~ chunk("IEND", null);
}

unittest
{
    auto png = encodePng(new ubyte[2 * 2 * 3], 2, 2);
    assert(png[1 .. 4] == "PNG");
    // the IEND chunk always ends with the same CRC
    assert(png[$ - 4 .. $] == [0xAE, 0x42, 0x60, 0x82]);
}
