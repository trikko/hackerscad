/// Part colours with transparency.
module hackerscad.geom.color;

/// The colour of parts that do not choose one: a bright sky blue, the logo's.
enum uint defaultPartColor = 0x0FC3F2;

/// Colours are 0xTTRRGGBB: the top byte is the transparency, so plain
/// 0xRRGGBB values are opaque.
double alphaOf(uint c) => 1 - (c >> 24) / 255.0;
/// ditto
uint rgbPart(uint c) => c & 0xFFFFFF;
/// ditto
uint withAlpha(uint c, double alpha)
{
    import std.math : lround;
    immutable a = alpha < 0 ? 0 : alpha > 1 ? 1 : alpha;
    return rgbPart(c) | (cast(uint) lround((1 - a) * 255) << 24);
}
/// "#RRGGBB", or "#RRGGBBAA" when the colour is transparent.
string hexColor(uint c)
{
    import std.format : format;
    return c >> 24 ? format("#%06X%02X", rgbPart(c), 255 - (c >> 24)) : format("#%06X", c);
}
