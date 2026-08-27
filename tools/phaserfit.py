#!/usr/bin/env python3
"""Fit the phaser's topology to its measured response.

Every other input to the phaser rewrite came from a probe. This one cannot: no
measurement says what circuit produced a response, only what the response is. So
this fits candidate topologies to the measured magnitude curve and reports which
one survives, which is a design decision made against evidence rather than a
guess.

The measured curves come from `s1probe phaserband` at ctl1 = 0, where the sweep
is stopped and the response is static:

    s1probe phaserband <dll> --type 6 --ctl1 0 --ctl2 80 --level 127 \
        --seconds 3 --notes 12,15,18,21,24,27,30,33,36,42,48

Run with a type name to fit it:  python tools/phaserfit.py ph1

What the fit settles, and why the peaks alone could not:

  * Resonance *positions* leave the corner placement wildly underdetermined --
    three different section layouts reproduced ph4's six resonances to within
    5% while giving quite different responses between them. The magnitude curve
    constrains it.
  * A pure feedback loop, out = x/(1 - g*A), cannot notch deeper than 1/(1+g),
    which is -6 dB even as g approaches one. The reference notches -12.15 dB at
    262 Hz, so there has to be a dry path summed with the wet one, and the
    fitted form is `d*x + w*A(v)` with `v = x + g*A(v)`.
  * The response rises toward DC -- +6.04 dB at 16 Hz and still climbing -- which
    is a resonance at zero, and which is what tells the feedback apart from the
    negative sign that would put a minimum there instead.
"""

import math
import random
import sys

# Measured at ctl1 = 0, level 127: the unit on over the unit off, in dB.
CURVES = {
    "ph1": [
        (16, 6.04), (19, 4.56), (23, 3.10), (28, 1.62), (33, 0.15), (39, -1.29),
        (46, -2.72), (55, -4.11), (65, -5.48), (92, -8.00), (131, -10.11),
        (185, -11.56), (262, -12.15), (523, -10.05), (1047, -4.54),
        (1480, -0.07), (2093, 7.52), (2489, 15.79), (2794, 25.85),
        (2960, 19.69), (3136, 15.10), (3520, 9.90), (4186, 5.63), (5920, 1.37),
        (8372, -0.71),
    ],
}


def response_db(f, log_corners, g, d, w):
    """d*x + w*A(v) with v = x + g*A(v), A a chain of first-order allpasses."""
    a = 1.0 + 0j
    for lc in log_corners:
        s = 1j * f / math.exp(lc)
        a *= (1 - s) / (1 + s)
    return 20.0 * math.log10(abs(d + w * a / (1.0 - g * a)))


def worst_error(params, n, curve):
    g, d, w = params[n], params[n + 1], params[n + 2]
    if not 0.0 <= g < 0.999:
        return 1e9
    try:
        return max(abs(response_db(f, params[:n], g, d, w) - m) for f, m in curve)
    except (ValueError, ZeroDivisionError):
        return 1e9


def fit(curve, n, seed, iterations=60000):
    rnd = random.Random(seed)
    p = sorted(rnd.uniform(math.log(2), math.log(12000)) for _ in range(n))
    p += [0.9491, 0.90, 1.13]
    cost = worst_error(p, n, curve)
    step = 1.0
    for _ in range(iterations):
        i = rnd.randrange(n + 3)
        scale = step if i < n else step * 0.05
        delta = rnd.gauss(0, scale)
        p[i] += delta
        c2 = worst_error(p, n, curve)
        if c2 < cost:
            cost = c2
        else:
            p[i] -= delta
        step *= 0.99992
    return cost, p


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "ph1"
    curve = CURVES.get(name)
    if curve is None:
        print("no measured curve for %s; the ones here are %s"
              % (name, ", ".join(sorted(CURVES))))
        return 1

    best = None
    for n in range(2, 8):
        r = min((fit(curve, n, s) for s in range(3)), key=lambda x: x[0])
        print("  %2d sections: worst %.2f dB  (g=%.4f d=%.3f w=%.3f)"
              % (n, r[0], r[1][n], r[1][n + 1], r[1][n + 2]))
        if best is None or r[0] < best[0]:
            best = (r[0], n, r[1])

    err, n, p = best
    corners = sorted(p[:n])
    g, d, w = p[n], p[n + 1], p[n + 2]
    print("\nbest: %d sections, worst %.2f dB, g=%.4f d=%.4f w=%.4f" % (n, err, g, d, w))
    print("  corners: %s Hz" % " ".join("%.2f" % math.exp(v) for v in corners))
    print("\n      Hz   measured     model     error")
    for f, m in curve:
        v = response_db(f, corners, g, d, w)
        print("  %6d   %+7.2f   %+7.2f   %+6.2f" % (f, m, v, v - m))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
