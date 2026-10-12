#!/usr/bin/env python3
"""Steady-state check of the quad presets in src/sticktime.lua (read from its QP strings).
Usage: tools/tune_physics.py [preset number 1-11] [key=value ...]   e.g. tools/tune_physics.py 5 twr=10

Model (mass-normalised, body axes r/u/f; the same steps as physics() in src/sticktime.lua):
  rpm R (a fraction of full) follows the stick, not below idle (0.0386), at up to 5.47 per second
  T   = twr*g * R * curve(R)               curve: 10 points (0.1 0.4 0.5 0.6 0.7 0.79 0.84 0.9 0.95 1)
                                            in 1% buckets, so thrust per rpm rises steeply at low rpm
  T  *= 1 - 0.005*floor(100*vu/top)        climbing: less thrust as the air comes through the props
  S   = (kx|vr| + ky|vu| + kz|vf|) * (1 + cd*R)   drag along the flow, growing with rpm: a = -S*v
  v  *= 1 - 0.1*dt                          air damping; gravity 9.8
(Hard rotations also raise the rpm: a third of full per axis lagging its rate by 120 deg/s; not
part of the steady states below.) The presets and what they give are in docs/flight-model.md.
"""
import math
import pathlib
import re
import sys

G = 9.8
IDLE = 0.0386
RC = [0.1, 0.4, 0.5, 0.6, 0.7, 0.79, 0.84, 0.9, 0.95, 1.0]
ROOT = pathlib.Path(__file__).resolve().parents[1]


def presets():
    src = (ROOT / "src" / "sticktime.lua").read_text(encoding="utf-8")
    keys = re.findall(r'"(\w+)"', re.search(r"local QK = \{([^}]*)\}", src).group(1))
    block = re.search(r"local QP = \{(.*?)\n\}", src, re.S).group(1)
    out = []
    for line in block.splitlines():
        m = re.match(r'\s*"([^"]+)",?\s*--\s*(.*)', line)
        if m:
            p = dict(zip(keys, (float(x) for x in m.group(1).split())))
            p["name"] = m.group(2)
            out.append(p)
    return out


def curve(f):
    b = math.floor(f * 100)
    if b > 98:
        return 1.0
    b = max(b, 0)
    i, j = b // 11, b % 11
    return RC[i + 1] if j == 10 else RC[i] + (RC[i + 1] - RC[i]) * j * 0.1


def thrust_at(t):
    t = max(t, IDLE)
    return t * curve(t)


def stick_for(f):
    lo, hi = 0.0, 1.0
    for _ in range(20):
        m = (lo + hi) / 2
        lo, hi = (m, hi) if thrust_at(m) < f else (lo, m)
    return hi


def fly(p, thr, pitch_deg, v0=(0.0, 0.0), secs=8.0, h=0.01, hold_alt=False, until=None):
    """attitude held (nose down by pitch_deg); returns (vx forward, vy up, time) at the end or when
    until(vx, vy) holds. v0 = (forward, up) at the start; sideways flight is the same with kx."""
    c, s = math.cos(math.radians(pitch_deg)), math.sin(math.radians(pitch_deg))
    vx, vy = v0
    R = max(thr, IDLE)
    t = 0.0
    while t < secs:
        want = max(thr, IDLE)
        R += max(-5.47 * h, min(5.47 * h, want - R))
        # body axes: up (u) tilted forward by pitch; forward (f) along the nose
        vu = vx * s + vy * c
        vf = vx * c - vy * s
        Ta = p["twr"] * G * R * curve(R)
        if vu > 0:
            Ta *= 1 - 0.005 * min(99, math.floor(vu / p["top"] * 100))
        S = (p["kx"] * 0 + p["ky"] * abs(vu) + p["kz"] * abs(vf)) * (1 + p["cd"] * R)
        au, af = Ta - S * vu, -S * vf
        ax = au * s + af * c
        ay = au * c - af * s - G
        vx, vy = vx + ax * h, (0.0 if hold_alt else vy + ay * h)
        vx, vy = vx * (1 - 0.1 * h), vy * (1 - 0.1 * h)
        t += h
        if until and until(vx, vy):
            break
    return vx, vy, t


def slide(p, hover):
    """sideways from 15 m/s at the hover stick, altitude held: the time to halve"""
    v, R, t, h = 15.0, max(hover, IDLE), 0.0, 0.01
    while v > 7.5 and t < 20:
        S = p["kx"] * v * (1 + p["cd"] * R)
        v += -S * v * h
        v *= 1 - 0.1 * h
        t += h
    return t


def report(p):
    hover = stick_for(1 / p["twr"])
    climb = fly(p, 1.0, 0.0)[1]
    fall = -fly(p, 0.0, 0.0, secs=10.0)[1]
    best, best_a = 0.0, 0.0
    for k in range(13):
        a = 55 + 2.5 * k
        vx, vy, _ = fly(p, 1.0, a, v0=(20.0, 0.0))
        if vy > -0.3 and vx > best:
            best, best_a = vx, a
    print(f"{p['name']:58s} {p['twr']:.1f}:1  hover stick {hover:.2f}  punch-out {climb * 3.6:4.0f} km/h  "
          f"flat fall {fall * 3.6:3.0f} km/h  top {best * 3.6:4.0f} km/h at {best_a:.1f} deg  "
          f"slide half-life {slide(p, hover):.2f} s")


def main():
    args = sys.argv[1:]
    sel = int(args.pop(0)) if args and args[0].isdigit() else None
    ps = presets()
    for i, p in enumerate(ps, 1):
        if sel and i != sel:
            continue
        for a in args:
            k, v = a.split("=")
            p[k] = float(v)
        report(p)


if __name__ == "__main__":
    main()
