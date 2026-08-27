#!/usr/bin/env python3
"""Fit the phaser's topology and its level law to the measured response.

Every other input to the phaser rewrite came from a probe. This one cannot: no
measurement says what circuit produced a response, only what the response is. So
this fits candidate topologies to the measured magnitude curve and reports which
one survives, which is a design decision made against evidence rather than a
guess.

The curves come from the probe, one render each, at 16.4 Hz resolution across
the whole band:

    s1probe phasercomb <dll> --type 6 --ctl1 0 --ctl2 16 --level 127
        --seconds 4 --curve build/curve-t6.csv

ctl1 = 0 because the sweep has to be stopped: this fits a static response. The
curve agrees with a held-tone sweep of the same setting to within 0.2 dB at every
frequency the two share, which is two instruments with nothing in common but the
plugin.

    python tools/phaserfit.py sections build/curve-t6.csv 2 8
    python tools/phaserfit.py levels build/curve-L%d.csv 56.30,1417.23,5444.35

What the fitting settles, and why the resonance positions alone could not:

  * Positions leave the corner placement wildly underdetermined -- three quite
    different section layouts reproduced ph4's six resonances to within 5% of
    each other while giving different responses between them.
  * A pure feedback loop, x/(1 - g*A), cannot notch deeper than 1/(1+g), which is
    -6 dB even as g approaches one. The reference notches -12.15 dB at 262 Hz, so
    a dry path is summed with the wet one: `d*x + w*A(v)`, `v = x + g*A(v)`.
  * The response rises toward DC -- +6.04 dB at 16 Hz, still climbing, with the
    notch above it at -12.15 -- which is a resonance at zero frequency, and which
    tells positive feedback from the negative sign that would put a minimum there.
  * The level knob moves three things, not one. With the sections held fixed --
    the knob does not move frequencies -- the feedback is exactly zero below about
    level 87 and only engages over the top third of the travel, while the wet
    amount rises across the whole of it.

|A| is one at every frequency, so only the chain's phase matters. Caching that
per frequency is what makes this tractable in plain Python: perturbing d, w or g
then costs no arctangent at all.
"""

import csv
import math
import random
import sys


def load(path, lo=20.0, hi=16000.0, count=140):
    """A log-spaced subsample of one measured curve."""
    rows = [(float(r["hz"]), float(r["ref_db"])) for r in csv.DictReader(open(path))]
    rows = [p for p in rows if lo <= p[0] <= hi]
    if not rows:
        raise SystemExit("no usable points in %s" % path)
    out, seen = [], set()
    for i in range(count):
        target = lo * (hi / lo) ** (i / (count - 1))
        p = min(rows, key=lambda q: abs(math.log(q[0] / target)))
        if p[0] not in seen:
            seen.add(p[0])
            out.append(p)
    return out


def phases(freqs, corners):
    return [sum(-2.0 * math.atan(f / c) for c in corners) for f in freqs]


def error(meas, phi, g, d, w, want_max=False):
    if not 0.0 <= g < 0.9995:
        return 1e9
    total, worst = 0.0, 0.0
    for (_, m), p in zip(meas, phi):
        cp, sp = math.cos(p), math.sin(p)
        den = 1.0 - 2.0 * g * cp + g * g
        if den < 1e-12:
            return 1e9
        re = d + w * (cp - g) / den
        im = w * sp / den
        mag = re * re + im * im
        if mag <= 1e-30:
            return 1e9
        v = 10.0 * math.log10(mag) - m
        total += v * v
        worst = max(worst, abs(v))
    return worst if want_max else math.sqrt(total / len(meas))


def fit_sections(meas, n, seed, iterations=30000):
    rnd = random.Random(seed)
    freqs = [f for f, _ in meas]
    logc = sorted(rnd.uniform(math.log(20), math.log(12000)) for _ in range(n))
    phi = phases(freqs, [math.exp(v) for v in logc])
    g, d, w = 0.94, 0.9, 1.1
    best, step = error(meas, phi, g, d, w), 1.0
    for _ in range(iterations):
        i = rnd.randrange(n + 3)
        if i < n:
            old = logc[i]
            logc[i] += rnd.gauss(0, step)
            trial = phases(freqs, [math.exp(v) for v in logc])
            v = error(meas, trial, g, d, w)
            if v < best:
                best, phi = v, trial
            else:
                logc[i] = old
        else:
            og, od, ow = g, d, w
            if i == n:
                g = min(0.9994, max(0.0, g + rnd.gauss(0, step * 0.02)))
            elif i == n + 1:
                d += rnd.gauss(0, step * 0.02)
            else:
                w += rnd.gauss(0, step * 0.02)
            v = error(meas, phi, g, d, w)
            if v < best:
                best = v
            else:
                g, d, w = og, od, ow
        step *= 0.99985
    return best, sorted(math.exp(v) for v in logc), g, d, w


def fit_mix(meas, corners, seeds=6, iterations=30000):
    """d, w and g at one level, with the sections already known."""
    phi = phases([f for f, _ in meas], corners)
    best = None
    for seed in range(seeds):
        rnd = random.Random(seed)
        g = rnd.uniform(0.0, 0.95)
        d = rnd.uniform(0.4, 1.2)
        w = rnd.uniform(0.0, 1.4)
        cost, step = error(meas, phi, g, d, w), 0.6
        for _ in range(iterations):
            og, od, ow = g, d, w
            i = rnd.randrange(3)
            if i == 0:
                g = min(0.9994, max(0.0, g + rnd.gauss(0, step * 0.04)))
            elif i == 1:
                d += rnd.gauss(0, step * 0.04)
            else:
                w += rnd.gauss(0, step * 0.04)
            v = error(meas, phi, g, d, w)
            if v < cost:
                cost = v
            else:
                g, d, w = og, od, ow
            step *= 0.9998
        if best is None or cost < best[0]:
            best = (cost, g, d, w)
    return best + (error(meas, phi, best[1], best[2], best[3], True),)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1

    if argv[1] == "sections":
        meas = load(argv[2])
        lo = int(argv[3]) if len(argv) > 3 else 2
        hi = int(argv[4]) if len(argv) > 4 else 8
        best = None
        for n in range(lo, hi + 1):
            r = min((fit_sections(meas, n, s) for s in range(2)), key=lambda x: x[0])
            print("  %2d sections: rms %.2f dB  (g=%.4f d=%.3f w=%.3f)"
                  % (n, r[0], r[2], r[3], r[4]))
            if best is None or r[0] < best[0] - 0.03:
                best = (r[0],) + (n,) + r[1:]
        rms, n, corners, g, d, w = best
        worst = error(meas, phases([f for f, _ in meas], corners), g, d, w, True)
        print("\nbest: %d sections, rms %.2f dB, worst %.2f dB, g=%.4f d=%.4f w=%.4f"
              % (n, rms, worst, g, d, w))
        print("  corners: %s Hz" % " ".join("%.2f" % c for c in corners))
        return 0

    if argv[1] == "levels":
        pattern = argv[2]
        corners = [float(v) for v in argv[3].split(",")]
        levels = [0, 16, 32, 48, 64, 80, 96, 104, 112, 118, 122, 127]
        print("  sections held at %s Hz" % " ".join("%.1f" % c for c in corners))
        print("  level      g        d        w      rms   worst")
        for lv in levels:
            try:
                meas = load(pattern % lv)
            except OSError:
                continue
            rms, g, d, w, worst = fit_mix(meas, corners)
            print("   %4d   %7.4f  %7.4f  %7.4f   %5.2f   %5.2f"
                  % (lv, g, d, w, rms, worst))
        return 0

    print(__doc__)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
