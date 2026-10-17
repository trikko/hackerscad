/// Screw thread standards: their names ("M8", "1/4-20 UNC", "Tr12x3",
/// "G1/2", "1/2 NPT", "1/2-10 ACME", "S20x4", "E27", "28-400", "PCO 1881",
/// "3/4 GHT"), sizes and the shape of their teeth. The tables are the
/// published nominal sizes of ISO 261 (metric), ASME B1.1 (unified inch),
/// ISO 2904 (trapezoidal), ISO 228-1 and ISO 7-1 (BSP parallel and
/// tapered), ASME B1.20.1 (NPT), ASME B1.5 (ACME), DIN 513 (buttress),
/// IEC 60061 / DIN 40400 / GOST 6042 (Edison lamp bases), the SPI/GPI
/// neck finishes of bottles and jars, ISBT's PCO 1881 and 1810 for PET
/// bottles, and ASME B1.20.7 (garden hose).
module hackerscad.lang.threading;

import std.algorithm : canFind, endsWith, startsWith;
import std.array : replace;
import std.conv : to, ConvException;
import std.format : format;
import std.algorithm : max;
import std.math : abs, atan, atan2, cos, PI, sin, sqrt, tan;
import std.string : indexOf, strip, toUpper;

/// The shape of the teeth.
enum ThreadForm
{
    iso60,       /// 60°, flat crests and roots: metric and unified inch
    trapezoid,   /// 30°, wide flat crests: lead screws
    whitworth,   /// 55°, round crests: BSP pipe threads
    npt,         /// 60°, nearly sharp: NPT pipe threads
    acme,        /// 29°, flat crests: inch lead screws
    buttress,    /// 3° and 30° flanks: DIN 513, a screw that pushes one way (vices, presses)
    edison,      /// round: two tangent arcs, lamp bases
    container,   /// 60°, flat crests, shallow: bottle and jar necks (SPI/GPI 400, 410, 415)
    bottle,      /// 30°, flat crests: PET bottle necks (PCO 1881, 1810)
}

/// A thread: its name, form, largest diameter and pitch (mm), and for a
/// tapered one the angle its side leans from the axis.
struct ThreadSpec
{
    string name;
    ThreadForm form;
    double major = 0, pitch = 0;
    double taper = 0;   /// radians; 0 parallel
    double toothDepth = 0;   /// the standard's own depth, where its table gives it (Edison, necks)

    /// How deep the teeth are, from the root to the crest.
    double depth() const
    {
        if (toothDepth > 0)
            return toothDepth;
        final switch (form)
        {
        case ThreadForm.iso60: return 0.5413 * pitch;
        case ThreadForm.trapezoid: return 0.5 * pitch;
        case ThreadForm.whitworth: return 0.6403 * pitch;
        case ThreadForm.npt: return 0.8 * pitch;
        case ThreadForm.acme: return 0.5 * pitch;
        case ThreadForm.buttress: return 0.86777 * pitch;
        case ThreadForm.edison, ThreadForm.container, ThreadForm.bottle: return 0.3 * pitch;   // their tables give it
        }
    }

    double minor() const => major - 2 * depth;

    /// The family, for menus: "ISO metric", "Unified inch"…
    string family() const
    {
        if (name.startsWith("M"))
            return "ISO metric";
        if (name.startsWith("Tr"))
            return "Trapezoidal";
        if (name.startsWith("G"))
            return "BSP parallel (G)";
        if (name.startsWith("R"))
            return "BSP tapered (R)";
        if (name.endsWith("NPT"))
            return "NPT tapered";
        if (name.endsWith("ACME"))
            return "ACME";
        if (name.startsWith("S"))
            return "Buttress (DIN 513)";
        if (name.startsWith("E"))
            return "Edison (lamps)";
        if (name.startsWith("PCO"))
            return "PET bottles";
        if (name.endsWith("GHT"))
            return "Garden hose (GHT)";
        if (form == ThreadForm.container)
            return "Bottle and jar necks";
        return "Unified inch";
    }

    /// The tooth in the plane of the axis, as a polygon for a sweep along the
    /// helix at the minor radius: x towards the axis (0 at the minor radius,
    /// `overlap` inside the core so that they fuse), y along the axis.
    double[] tooth(double overlap) const
    {
        immutable p = pitch, h = depth;
        double[] xy;
        void flat(double halfRoot, double halfCrest, double flankAngle)
        {
            immutable w = halfRoot + overlap * tan(flankAngle);
            xy = [overlap, -w, -h, -halfCrest, -h, halfCrest, overlap, w];
        }
        // a flat crest `crest` wide, its flanks leaning `lower` (towards -y) and `upper` from square to the axis
        void leaning(double crest, double lower, double upper)
        {
            xy = [overlap, -crest / 2 - (h + overlap) * tan(lower), -h, -crest / 2, -h, crest / 2,
                overlap, crest / 2 + (h + overlap) * tan(upper)];
        }
        final switch (form)
        {
        case ThreadForm.iso60:
            flat(0.375 * p, p / 16, PI / 6);
            break;
        case ThreadForm.trapezoid:
            flat(0.317 * p, 0.183 * p, PI / 12);
            break;
        case ThreadForm.npt:
            flat(0.481 * p, 0.019 * p, PI / 6);
            break;
        case ThreadForm.acme:
            flat(0.5 * p - 0.1853 * p, 0.1853 * p, 14.5 * PI / 180);
            break;
        case ThreadForm.buttress:
            // DIN 513: the load flank 3° from square, the other 30°; the crest 0.264 p wide
            leaning(0.2638 * p, 30 * PI / 180, 3 * PI / 180);
            break;
        case ThreadForm.container:
            // flanks of 30°, the tooth half the pitch wide at its root (the tables give T, E and the pitch)
            leaning(max(0.05 * p, 0.5 * p - 2 * h * tan(PI / 6)), PI / 6, PI / 6);
            break;
        case ThreadForm.bottle:
            leaning(max(0.05 * p, 0.5 * p - 2 * h * tan(PI / 12)), PI / 12, PI / 12);
            break;
        case ThreadForm.edison:
            {
                // two tangent arcs of radius r: the crest's, centred h - r out from the root, and the
                // root's, centred r out, half a pitch along: r = ((p/2)² + h²) / 4h; from the middle
                // of a root (y = -p/2) round the crest to just before the next root's middle
                immutable r = (p * p / 4 + h * h) / (4 * h);
                // 5 points a quarter pitch: within 0.01 mm of the arcs (every point is a helix and a
                // face of the thread: 12 took three times as long)
                enum steps = 5;
                // the tangent point: half way between the two centres, a quarter pitch along
                immutable yt = p / 4;
                xy = [];
                // sample the profile: the crest arc where |y| <= p/4, the root arcs beyond
                foreach (i; 0 .. 4 * steps)
                {
                    immutable y = -p / 2 + p * i / (4 * steps);
                    immutable rho = abs(y) <= yt ? (h - r) + sqrt(r * r - y * y)
                        : r - sqrt(max(0.0, r * r - (p / 2 - abs(y)) ^^ 2));
                    xy ~= [-rho, y];
                }
                break;
            }
        case ThreadForm.whitworth:
            {
                // 55° flanks, the crest an arc of radius 0.1373 p tangent to both
                immutable half = 27.5 * PI / 180, r = 0.1373 * p, foot = 0.4167 * p + overlap * tan(half);
                immutable centre = 0.5030 * p;   // the arc's centre, out from the root
                xy = [overlap, -foot];
                // within 0.01 mm of the arc on a G1 (p 2.31), closer on finer pitches
                enum steps = 5;
                foreach (i; 0 .. steps + 1)
                {
                    immutable a = -(PI / 2 - half) + (PI - 2 * half) * i / steps;
                    xy ~= [-(centre + r * cos(a)), r * sin(a)];
                }
                xy ~= [overlap, foot];
                break;
            }
        }
        return xy;
    }
}

/// The tapers of pipe threads: 1 in 16 on the diameter.
enum pipeTaper = atan(1.0 / 32);

/// ISO metric coarse threads (ISO 261): nominal diameter and pitch, mm.
immutable double[2][] isoCoarse = [[1, 0.25], [1.2, 0.25], [1.4, 0.3], [1.6, 0.35], [2, 0.4], [2.5, 0.45], [3, 0.5],
    [3.5, 0.6], [4, 0.7], [5, 0.8], [6, 1], [7, 1], [8, 1.25], [10, 1.5], [12, 1.75], [14, 2], [16, 2], [18, 2.5],
    [20, 2.5], [22, 2.5], [24, 3], [27, 3], [30, 3.5], [33, 3.5], [36, 4]];

/// ISO trapezoidal threads (ISO 2904), preferred pitches: diameter, pitch.
immutable double[2][] trapezoidal = [[8, 1.5], [10, 2], [12, 3], [14, 3], [16, 4], [18, 4], [20, 4], [22, 5], [24, 5],
    [26, 5], [28, 5], [30, 6], [32, 6], [36, 6], [40, 7], [44, 7], [48, 8], [50, 8]];

private struct Inch
{
    string size;
    double inches;
    double coarse, fine;   /// threads per inch, UNC and UNF (0: none)
}

/// Unified inch threads (ASME B1.1): size, diameter, UNC and UNF threads per inch.
private immutable Inch[] unified = [
    Inch("#0", 0.060, 0, 80), Inch("#1", 0.073, 64, 72), Inch("#2", 0.086, 56, 64), Inch("#3", 0.099, 48, 56),
    Inch("#4", 0.112, 40, 48), Inch("#5", 0.125, 40, 44), Inch("#6", 0.138, 32, 40), Inch("#8", 0.164, 32, 36),
    Inch("#10", 0.190, 24, 32), Inch("#12", 0.216, 24, 28), Inch("1/4", 0.25, 20, 28), Inch("5/16", 0.3125, 18, 24),
    Inch("3/8", 0.375, 16, 24), Inch("7/16", 0.4375, 14, 20), Inch("1/2", 0.5, 13, 20), Inch("9/16", 0.5625, 12, 18),
    Inch("5/8", 0.625, 11, 18), Inch("3/4", 0.75, 10, 16), Inch("7/8", 0.875, 9, 14), Inch("1", 1, 8, 12),
];

private struct Pipe
{
    string size;
    double major;   /// mm: BSP the thread's major diameter, NPT the pipe's outside
    double tpi;
}

/// BSP pipe threads (ISO 228-1 parallel, ISO 7-1 tapered).
private immutable Pipe[] bsp = [
    Pipe("1/16", 7.723, 28), Pipe("1/8", 9.728, 28), Pipe("1/4", 13.157, 19), Pipe("3/8", 16.662, 19),
    Pipe("1/2", 20.955, 14), Pipe("5/8", 22.911, 14), Pipe("3/4", 26.441, 14), Pipe("7/8", 30.201, 14),
    Pipe("1", 33.249, 11), Pipe("1-1/8", 37.897, 11), Pipe("1-1/4", 41.910, 11), Pipe("1-1/2", 47.803, 11),
    Pipe("1-3/4", 53.746, 11), Pipe("2", 59.614, 11),
];

/// NPT pipe threads (ASME B1.20.1): the pipe's outside diameter.
private immutable Pipe[] npt = [
    Pipe("1/16", 0.3125 * 25.4, 27), Pipe("1/8", 0.405 * 25.4, 27), Pipe("1/4", 0.540 * 25.4, 18),
    Pipe("3/8", 0.675 * 25.4, 18), Pipe("1/2", 0.840 * 25.4, 14), Pipe("3/4", 1.050 * 25.4, 14),
    Pipe("1", 1.315 * 25.4, 11.5), Pipe("1-1/4", 1.660 * 25.4, 11.5), Pipe("1-1/2", 1.900 * 25.4, 11.5),
    Pipe("2", 2.375 * 25.4, 11.5),
];

/// ACME general-purpose threads (ASME B1.5): size, diameter (in), threads per inch.
private immutable Inch[] acmeTable = [
    Inch("1/4", 0.25, 16), Inch("5/16", 0.3125, 14), Inch("3/8", 0.375, 12), Inch("7/16", 0.4375, 12),
    Inch("1/2", 0.5, 10), Inch("5/8", 0.625, 8), Inch("3/4", 0.75, 6), Inch("7/8", 0.875, 6), Inch("1", 1, 5),
    Inch("1-1/8", 1.125, 5), Inch("1-1/4", 1.25, 5), Inch("1-3/8", 1.375, 4), Inch("1-1/2", 1.5, 4),
    Inch("1-3/4", 1.75, 4), Inch("2", 2, 4),
];

/// Edison lamp bases (GOST 6042, as IEC 60061 / DIN 40400): name, the largest outer and inner
/// diameters (mm) and the pitch.
private struct Edison
{
    string name;
    double outer, inner, pitch;
}

private immutable Edison[] edisonTable = [
    Edison("E5", 5.83, 4.77, 1.0), Edison("E10", 9.53, 8.51, 1.814), Edison("E14", 13.89, 12.29, 2.822),
    Edison("E16", 15.97, 14.47, 2.5), Edison("E18", 18.5, 16.8, 3.0), Edison("E21", 20.95, 19.45, 2.0),
    Edison("E27", 26.45, 24.26, 3.629), Edison("E33", 33.05, 30.45, 4.233), Edison("E40", 39.5, 35.9, 6.35),
];

/// SPI/GPI neck finishes of bottles and jars: size (mm), the thread's outer diameter T and the
/// diameter under it E (in, the middle of the tolerance), threads per inch; 400 is about one turn of
/// thread, 410 one and a half, 415 two.
private struct Neck
{
    int size;
    double t, e, tpi;
}

private immutable Neck[] necks = [
    Neck(13, 0.508, 0.448, 12), Neck(15, 0.575, 0.515, 12), Neck(18, 0.696, 0.612, 8), Neck(20, 0.775, 0.691, 8),
    Neck(22, 0.854, 0.770, 8), Neck(24, 0.932, 0.848, 8), Neck(28, 1.078, 0.984, 6), Neck(30, 1.117, 1.023, 6),
    Neck(33, 1.253, 1.159, 6), Neck(35, 1.352, 1.258, 6), Neck(38, 1.464, 1.370, 6), Neck(40, 1.565, 1.471, 6),
    Neck(43, 1.639, 1.545, 6), Neck(45, 1.725, 1.631, 6), Neck(48, 1.855, 1.761, 6), Neck(51, 1.9505, 1.8565, 6),
    Neck(53, 2.0495, 1.9555, 6), Neck(58, 2.2065, 2.1125, 6), Neck(60, 2.3245, 2.2305, 6), Neck(63, 2.4435, 2.3495, 6),
    Neck(66, 2.5615, 2.4675, 6), Neck(70, 2.7185, 2.6245, 6), Neck(75, 2.8955, 2.8015, 6), Neck(77, 3.0175, 2.9235, 6),
    Neck(83, 3.2505, 3.1305, 5), Neck(89, 3.4935, 3.3735, 5), Neck(100, 3.9195, 3.7995, 5), Neck(110, 4.3135, 4.1935, 5),
    Neck(120, 4.7065, 4.5865, 5),
];

/// PET bottle necks (ISBT): PCO 1881 (today's soft drinks and water) and PCO 1810 (older ones):
/// the thread's outer diameter 27.43 mm, 24.94 under it, one start.
private ThreadSpec pco(int which) => ThreadSpec(format("PCO %d", which), ThreadForm.bottle, 27.43,
    which == 1881 ? 2.7 : 3.18, 0, (27.43 - 24.94) / 2);

/// Reads a thread's name: "M8", "M8x1", "Tr12x3", "Tr12", "1/4-20 UNC",
/// "1/4 UNF", "#10-32", "G1/2", "R1/2", "1/2 NPT". False when it is none of them.
bool parseThread(string text, out ThreadSpec spec)
{
    auto s = text.strip.toUpper.replace(" ", "");
    double num(string t) => t.to!double;
    try
    {
        // bottle and jar necks: "28-400", "SPI 28-410", "GPI 38-400"
        {
            auto t = s;
            foreach (prefix; ["SPI", "GPI"])
                if (t.startsWith(prefix))
                    t = t[prefix.length .. $];
            auto dash = t.indexOf('-');
            if (dash < 0)
                dash = t.indexOf('/');
            if (dash > 0 && ["400", "410", "415"].canFind(t[dash + 1 .. $]))
            {
                immutable size = t[0 .. dash].to!int;
                foreach (n; necks)
                    if (n.size == size)
                    {
                        spec = ThreadSpec(format("%d-%s", size, t[dash + 1 .. $]), ThreadForm.container, n.t * 25.4,
                            25.4 / n.tpi, 0, (n.t - n.e) / 2 * 25.4);
                        return true;
                    }
                return false;
            }
        }
        // PET bottles
        if (s == "PCO1881" || s == "PCO1810")
        {
            spec = pco(s[3 .. $].to!int);
            return true;
        }
        // Edison lamp bases
        foreach (e; edisonTable)
            if (s == e.name)
            {
                spec = ThreadSpec(e.name, ThreadForm.edison, e.outer, e.pitch, 0, (e.outer - e.inner) / 2);
                return true;
            }
        // garden hose (ASME B1.20.7): 3/4-11.5 NH, a 60° thread 1.0625 inch across
        if (s.endsWith("GHT") || s.endsWith("NH"))
        {
            spec = ThreadSpec("3/4 GHT", ThreadForm.iso60, 1.0625 * 25.4, 25.4 / 11.5);
            return s.startsWith("3/4");
        }
        // ACME: "1/2-10 ACME", "1/2 ACME"
        if (s.endsWith("ACME"))
        {
            auto t = s[0 .. $ - 4];
            auto d2 = t.lastIndexOf2('-');
            double tpi = 0;
            if (d2 > 0 && !t[d2 + 1 .. $].canFind('/'))
            {
                tpi = num(t[d2 + 1 .. $]);
                t = t[0 .. d2];
            }
            foreach (row; acmeTable)
                if (row.size == t)
                {
                    if (tpi == 0)
                        tpi = row.coarse;
                    spec = ThreadSpec(format("%s-%g ACME", row.size, tpi), ThreadForm.acme, row.inches * 25.4, 25.4 / tpi);
                    return true;
                }
            return false;
        }
        // buttress (DIN 513): "S20x4", or "S20" with the preferred pitch
        if (s.startsWith("S") && s.length > 1 && s[1] >= '0' && s[1] <= '9')
        {
            auto t = s[1 .. $];
            auto x = t.indexOf('X');
            immutable d = num(x < 0 ? t : t[0 .. x]);
            double p = 0;
            if (x >= 0)
                p = num(t[x + 1 .. $]);
            else
                foreach (row; trapezoidal)
                    if (abs(row[0] - d) < 1e-9)
                        p = row[1];
            if (!(d > 0 && p > 0))
                return false;
            spec = ThreadSpec(format("S%gx%g", d, p), ThreadForm.buttress, d, p);
            return true;
        }
        // trapezoidal
        if (s.startsWith("TR"))
        {
            auto t = s[2 .. $];
            auto x = t.indexOf('X');
            immutable d = num(x < 0 ? t : t[0 .. x]);
            double p = 0;
            if (x >= 0)
                p = num(t[x + 1 .. $]);
            else
                foreach (row; trapezoidal)
                    if (abs(row[0] - d) < 1e-9)
                        p = row[1];
            if (!(d > 0 && p > 0))
                return false;
            spec = ThreadSpec(format("Tr%gx%g", d, p), ThreadForm.trapezoid, d, p);
            return true;
        }
        // metric
        if (s.startsWith("M"))
        {
            auto t = s[1 .. $];
            auto x = t.indexOf('X');
            immutable d = num(x < 0 ? t : t[0 .. x]);
            double p = 0;
            if (x >= 0)
                p = num(t[x + 1 .. $]);
            else
                foreach (row; isoCoarse)
                    if (abs(row[0] - d) < 1e-9)
                        p = row[1];
            if (!(d > 0 && p > 0))
                return false;
            spec = ThreadSpec(x < 0 ? format("M%g", d) : format("M%gx%g", d, p), ThreadForm.iso60, d, p);
            return true;
        }
        // pipes: G and R (BSP), NPT
        bool pipe(string size, const Pipe[] table, string name, ThreadForm form, double taper)
        {
            foreach (row; table)
                if (row.size == size)
                {
                    spec = ThreadSpec(name, form, row.major, 25.4 / row.tpi, taper);
                    return true;
                }
            return false;
        }
        if (s.startsWith("G"))
            return pipe(s[1 .. $], bsp, "G" ~ s[1 .. $], ThreadForm.whitworth, 0);
        if (s.startsWith("BSPT"))
            return pipe(s[4 .. $], bsp, "R" ~ s[4 .. $], ThreadForm.whitworth, pipeTaper);
        if (s.startsWith("RC") || s.startsWith("RP"))
            return pipe(s[2 .. $], bsp, "R" ~ s[2 .. $], ThreadForm.whitworth, pipeTaper);
        if (s.startsWith("R"))
            return pipe(s[1 .. $], bsp, "R" ~ s[1 .. $], ThreadForm.whitworth, pipeTaper);
        if (s.startsWith("NPT") || s.endsWith("NPT"))
        {
            auto t = s.startsWith("NPT") ? s[3 .. $] : s[0 .. $ - 3];
            auto dash = t.lastIndexOf2('-');
            // "1/2-14 NPT": the threads per inch are the standard's anyway
            if (dash > 0 && t[0 .. dash].canFind('/') && !t[dash + 1 .. $].canFind('/'))
                t = t[0 .. dash];
            return pipe(t, npt, t ~ " NPT", ThreadForm.npt, pipeTaper);
        }
        // unified inch: "1/4-20", "1/4-20UNC", "1/4UNF", "#10-32"
        string series;
        foreach (suffix; ["UNC", "UNF"])
            if (s.endsWith(suffix))
            {
                series = suffix;
                s = s[0 .. $ - 3];
            }
        auto dash = s.lastIndexOf2('-');
        string size = s;
        double tpi = 0;
        if (dash > 0 && !s[dash + 1 .. $].canFind('/'))
        {
            size = s[0 .. dash];
            tpi = num(s[dash + 1 .. $]);
        }
        foreach (row; unified)
            if (row.size == size)
            {
                if (tpi == 0)
                    tpi = series == "UNF" ? row.fine : row.coarse;
                if (!(tpi > 0))
                    return false;
                immutable label = series.length ? series : tpi == row.coarse ? "UNC" : tpi == row.fine ? "UNF" : "UN";
                spec = ThreadSpec(format("%s-%g %s", size, tpi, label), ThreadForm.iso60, row.inches * 25.4, 25.4 / tpi);
                return true;
            }
        return false;
    }
    catch (ConvException)
        return false;
}

private ptrdiff_t lastIndexOf2(string s, char c)
{
    foreach_reverse (i, ch; s)
        if (ch == c)
            return i;
    return -1;
}

/// Every thread in the tables (coarse metric, UNC and UNF, preferred
/// trapezoidal, BSP and NPT), for menus.
ThreadSpec[] allThreads()
{
    ThreadSpec[] r;
    foreach (row; isoCoarse)
        r ~= ThreadSpec(format("M%g", row[0]), ThreadForm.iso60, row[0], row[1]);
    foreach (row; unified)
    {
        if (row.coarse > 0)
            r ~= ThreadSpec(format("%s-%g UNC", row.size, row.coarse), ThreadForm.iso60, row.inches * 25.4, 25.4 / row.coarse);
        if (row.fine > 0)
            r ~= ThreadSpec(format("%s-%g UNF", row.size, row.fine), ThreadForm.iso60, row.inches * 25.4, 25.4 / row.fine);
    }
    foreach (row; trapezoidal)
        r ~= ThreadSpec(format("Tr%gx%g", row[0], row[1]), ThreadForm.trapezoid, row[0], row[1]);
    foreach (row; bsp)
    {
        r ~= ThreadSpec("G" ~ row.size, ThreadForm.whitworth, row.major, 25.4 / row.tpi);
        r ~= ThreadSpec("R" ~ row.size, ThreadForm.whitworth, row.major, 25.4 / row.tpi, pipeTaper);
    }
    foreach (row; npt)
        r ~= ThreadSpec(row.size ~ " NPT", ThreadForm.npt, row.major, 25.4 / row.tpi, pipeTaper);
    foreach (row; acmeTable)
        r ~= ThreadSpec(format("%s-%g ACME", row.size, row.coarse), ThreadForm.acme, row.inches * 25.4, 25.4 / row.coarse);
    foreach (row; trapezoidal)
        r ~= ThreadSpec(format("S%gx%g", row[0], row[1]), ThreadForm.buttress, row[0], row[1]);
    foreach (e; edisonTable)
        r ~= ThreadSpec(e.name, ThreadForm.edison, e.outer, e.pitch, 0, (e.outer - e.inner) / 2);
    foreach (n; necks)
        r ~= ThreadSpec(format("%d-400", n.size), ThreadForm.container, n.t * 25.4, 25.4 / n.tpi, 0, (n.t - n.e) / 2 * 25.4);
    r ~= [pco(1881), pco(1810)];
    r ~= ThreadSpec("3/4 GHT", ThreadForm.iso60, 1.0625 * 25.4, 25.4 / 11.5);
    return r;
}

/// Whether a cylinder of diameter `dia` takes the thread: a shaft about its
/// major diameter, a hole about its minor one (the tap drill, a little more
/// for the tooth's crest, a little less for printed parts).
bool fits(const ThreadSpec t, double dia, bool outside)
{
    if (outside)
        return abs(dia - t.major) <= 0.25 * t.pitch + 0.1;
    return dia <= t.major - 0.5 * t.depth && dia >= t.minor - 0.3 * t.pitch;
}

unittest
{
    ThreadSpec t;
    assert(parseThread("M8", t) && t.major == 8 && t.pitch == 1.25 && t.name == "M8");
    assert(parseThread("m8x1", t) && t.pitch == 1 && t.name == "M8x1");
    assert(parseThread("Tr12x3", t) && t.form == ThreadForm.trapezoid && t.pitch == 3);
    assert(parseThread("Tr 16", t) && t.pitch == 4);
    assert(parseThread("1/4-20 UNC", t) && abs(t.major - 6.35) < 1e-9 && abs(t.pitch - 1.27) < 1e-9 && t.name == "1/4-20 UNC");
    assert(parseThread("1/4 UNF", t) && abs(t.pitch - 25.4 / 28) < 1e-9);
    assert(parseThread("#10-32", t) && t.name == "#10-32 UNF");
    assert(parseThread("G1/2", t) && t.form == ThreadForm.whitworth && t.taper == 0 && abs(t.pitch - 25.4 / 14) < 1e-9);
    assert(parseThread("R1/2", t) && t.taper > 0);
    assert(parseThread("1/2 NPT", t) && abs(t.major - 21.336) < 1e-9 && t.taper > 0);
    assert(parseThread("1/2-14 NPT", t) && t.name == "1/2 NPT");
    assert(!parseThread("X12", t) && !parseThread("M", t) && !parseThread("G9/9", t));
    assert(parseThread("1/2-10 ACME", t) && t.form == ThreadForm.acme && abs(t.pitch - 2.54) < 1e-9 && abs(t.major - 12.7) < 1e-9);
    assert(parseThread("1/2 acme", t) && t.name == "1/2-10 ACME");
    assert(parseThread("S20x4", t) && t.form == ThreadForm.buttress && abs(t.depth - 0.86777 * 4) < 1e-9);
    assert(parseThread("S20", t) && t.pitch == 4);
    assert(parseThread("E27", t) && t.form == ThreadForm.edison && abs(t.pitch - 3.629) < 1e-9
        && abs(t.depth - (26.45 - 24.26) / 2) < 1e-9);
    assert(parseThread("28-400", t) && t.form == ThreadForm.container && abs(t.major - 1.078 * 25.4) < 1e-9
        && abs(t.pitch - 25.4 / 6) < 1e-9);
    assert(parseThread("SPI 38-410", t) && t.name == "38-410" && parseThread("GPI 24/415", t));
    assert(!parseThread("27-400", t));
    assert(parseThread("PCO 1881", t) && t.pitch == 2.7 && abs(t.major - 27.43) < 1e-9);
    assert(parseThread("pco1810", t) && t.pitch == 3.18);
    assert(parseThread("3/4 GHT", t) && abs(t.pitch - 25.4 / 11.5) < 1e-9);
    // the Edison profile: two tangent arcs, the radius of GOST 6042's table (E14 0.822, E27 1.025)
    foreach (pair; [["E14", "0.822"], ["E27", "1.025"]])
    {
        assert(parseThread(pair[0], t));
        immutable h = t.depth, r = (t.pitch ^^ 2 / 4 + h * h) / (4 * h);
        assert(abs(r - pair[1].to!double) < 0.002, pair[0]);
    }
    // every tooth is a closed outline between the root and the crest
    foreach (s; allThreads())
    {
        auto xy = s.tooth(0.1 * s.pitch);
        assert(xy.length >= 8 && xy.length % 2 == 0, s.name);
        foreach (i; 0 .. xy.length / 2)
            assert(xy[2 * i] <= 0.1 * s.pitch + 1e-9 && xy[2 * i] >= -s.depth - 1e-9, s.name);
    }
    assert(fits(ThreadSpec("M8", ThreadForm.iso60, 8, 1.25), 8, true) && fits(ThreadSpec("M8", ThreadForm.iso60, 8, 1.25), 6.8, false));
}
