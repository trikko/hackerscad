/// Part colours with transparency.
module hackerscad.geom.color;

/// hackerscad's own colours: bright, and alike in brightness under the
/// view's light. Their names have a space, unlike the web's ("Pink Pop" is
/// not "pink"), so `@part("Pink Pop")` and the right-click menu's Colour
/// give the same pink.
struct PaletteColour
{
    string name;
    uint rgb;
}

/// ditto
immutable PaletteColour[] partPalette = [
    PaletteColour("Sky Pop", 0x0FC3F2), PaletteColour("Blue Pop", 0x6BB7FE), PaletteColour("Cyan Pop", 0x10CACA),
    PaletteColour("Violet Pop", 0xC597FE), PaletteColour("Pink Pop", 0xF587C2), PaletteColour("Rose Pop", 0xFF869E),
    PaletteColour("Red Pop", 0xFF8A82), PaletteColour("Orange Pop", 0xEE9D30), PaletteColour("Yellow Pop", 0xF4E55E),
    PaletteColour("White Pop", 0xFFFFFF), PaletteColour("Gray Pop", 0xD3D7DC),
];

/// The colour of parts that do not choose one: Sky Pop, the logo's.
enum uint defaultPartColor = 0x0FC3F2;

/// The palette colour named `name` (any case), or -1.
long paletteColour(string name)
{
    import std.uni : sicmp;
    foreach (c; partPalette)
        if (sicmp(c.name, name) == 0)
            return c.rgb;
    return -1;
}

unittest
{
    assert(partPalette[0].rgb == defaultPartColor);
    assert(paletteColour("pink pop") == 0xF587C2 && paletteColour("Pink") == -1);
}

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

/// The colour of OKLCH lightness `l` (0…1), chroma `c` (about 0…0.37) and
/// hue `h` (degrees), as 0xRRGGBB. OKLCH is a perceptual space: colours of one
/// lightness look equally bright whatever the hue, so a ring of hues at one
/// lightness and chroma is a calibrated colour wheel (the palette's colours
/// are near l 0.76, c 0.15). Out of sRGB, the chroma is lowered until it fits.
uint oklchColour(double l, double c, double h)
{
    import std.math : PI, cos, sin, lround;
    double[3] rgb(double chroma)
    {
        immutable a = chroma * cos(h * PI / 180), b = chroma * sin(h * PI / 180);
        immutable l_ = l + 0.3963377774 * a + 0.2158037573 * b;
        immutable m_ = l - 0.1055613458 * a - 0.0638541728 * b;
        immutable s_ = l - 0.0894841775 * a - 1.2914855480 * b;
        immutable L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_;
        return [4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
            -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
            -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S];
    }
    bool fits(double[3] v)
    {
        foreach (x; v)
            if (x < -1e-6 || x > 1 + 1e-6)
                return false;
        return true;
    }
    double lo = 0, hi = c;
    if (!fits(rgb(hi)))
        foreach (_; 0 .. 30)
        {
            immutable mid = (lo + hi) / 2;
            if (fits(rgb(mid)))
                lo = mid;
            else
                hi = mid;
        }
    else
        lo = c;
    uint channel(double x)
    {
        import std.math : pow;
        x = x < 0 ? 0 : x > 1 ? 1 : x;
        immutable g = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055;
        return cast(uint) lround(g * 255);
    }
    auto v = rgb(lo);
    return channel(v[0]) << 16 | channel(v[1]) << 8 | channel(v[2]);
}

/// The OKLab lightness, a and b of 0xRRGGBB `rgb`: a perceptual space, where
/// the distance between two colours is how different they look.
double[3] colourOklab(uint rgb)
{
    import std.math : cbrt, pow;
    double linear(uint v)
    {
        immutable x = v / 255.0;
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
    }
    immutable r = linear(rgb >> 16 & 0xFF), g = linear(rgb >> 8 & 0xFF), b = linear(rgb & 0xFF);
    immutable l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    immutable m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    immutable s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    immutable L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    immutable A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    immutable B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;
    return [L, A, B];
}

/// How different 0xRRGGBB colours `a` and `b` look: about 0.02 is barely
/// seen, 0.15 a colour of the same family, 0.3 a different one.
double colourDistance(uint a, uint b)
{
    import std.math : sqrt;
    auto p = colourOklab(a), q = colourOklab(b);
    return sqrt((p[0] - q[0]) ^^ 2 + (p[1] - q[1]) ^^ 2 + (p[2] - q[2]) ^^ 2);
}

/// The OKLCH lightness, chroma and hue (degrees, 0…360) of 0xRRGGBB `rgb`.
double[3] colourOklch(uint rgb)
{
    import std.math : PI, atan2, sqrt;
    auto lab = colourOklab(rgb);
    immutable L = lab[0], A = lab[1], B = lab[2];
    auto h = atan2(B, A) * 180 / PI;
    if (h < 0)
        h += 360;
    return [L, sqrt(A * A + B * B), h];
}

unittest
{
    import std.math : abs;
    // there and back, within a step of 255
    foreach (rgb; [0x0FC3F2u, 0xF587C2, 0xEE9D30, 0x123ABC, 0x808080])
    {
        auto o = colourOklch(rgb);
        immutable back = oklchColour(o[0], o[1], o[2]);
        foreach (shift; [16, 8, 0])
            assert(abs(cast(int)(back >> shift & 0xFF) - cast(int)(rgb >> shift & 0xFF)) <= 1);
    }
    // white and black; a chroma too high for sRGB is lowered, not clipped per channel
    assert(oklchColour(1, 0, 0) == 0xFFFFFF && oklchColour(0, 0, 0) == 0x000000);
    auto vivid = colourOklch(oklchColour(0.76, 0.37, 250));
    assert(abs(vivid[0] - 0.76) < 0.01 && abs(vivid[2] - 250) < 2);
    // Sky Pop sits on the palette's ring
    auto sky = colourOklch(0x0FC3F2);
    assert(abs(sky[0] - 0.76) < 0.03 && abs(sky[1] - 0.14) < 0.03);
    // yellow on the view's yellow highlight is near, sky far
    assert(colourDistance(0xF4E55E, 0xFFC726) < 0.1 && colourDistance(0x0FC3F2, 0xFFC726) > 0.25);
}
