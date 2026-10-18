/// A performance test, run only with HC_PERF set: a thread cut to length by
/// a boolean (as thread() does) against the same cut made directly from its
/// faces (hc_thread_direct). Not part of the program.
module hackerscad.kernel.occt.perftest;

unittest
{
    import std.process : environment;
    if (environment.get("HC_PERF") is null)
        return;
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.stdio : writefln;
    import std.math : abs;
    import hackerscad.kernel.brep;
    import hackerscad.kernel.occt.backend : OcctKernel;
    import hackerscad.kernel.occt.c;
    import hackerscad.geom.vec;
    auto k = new OcctKernel;
    foreach (spec; [[20.0, 2.5, 40.0], [8.0, 1.25, 25.0], [8.0, 1.25, 60.0], [24.0, 3.0, 70.0]])
    {
        immutable d = spec[0], p = spec[1], len = spec[2];
        immutable h = 0.5413 * p, R = d / 2, r = R - h;
        double[] rz = [R, -p / 16, R, p / 16, r, 3 * p / 8, r, 5 * p / 8];
        foreach (chamfer; [false, true])
        {
            double tb, tc, td;
            Brep viaBoolean, direct;
            foreach (round; 0 .. 2)   // the second round counted: the first warms up
            {
                auto sw = StopWatch(AutoStart.yes);
                auto band = k.threadBand(rz, p, len, 0);
                tb = sw.peek.total!"usecs" / 1000.0;
                sw.reset();
                // the envelope thread() cuts with: past the crests, the tip bevelled a tooth high
                auto keep = k.cylinder(R + 0.01, len);
                if (chamfer)
                {
                    int[] topEdges;
                    foreach (i, e; k.edges(keep))
                        if (e.kind == EdgeKind.circle && e.center.z > len - 1e-6)
                            topEdges ~= cast(int) i;
                    keep = k.chamfer(keep, topEdges, h);
                }
                viaBoolean = k.boolean(band, keep, BoolOp.common);
                tc = sw.peek.total!"usecs" / 1000.0;
                sw.reset();
                direct = k.threadDirect(rz, p, len, chamfer ? h : 0, R + 0.01);
                td = sw.peek.total!"usecs" / 1000.0;
            }
            immutable va = k.volume(viaBoolean), vb = k.volume(direct);
            writefln("M%g x %g%s: band %.1f ms + boolean %.1f ms = %.1f ms; direct %.1f ms (%.1fx); volumes %.3f / %.3f "
                ~ "(%.4f%%), valid %s / %s, faces %s / %s", d, len, chamfer ? " chamfered" : "", tb, tc, tb + tc, td,
                (tb + tc) / td, va, vb, 100 * abs(va - vb) / va, k.isValid(viaBoolean), k.isValid(direct),
                k.faceCount(viaBoolean), k.faceCount(direct));
        }
    }
}
