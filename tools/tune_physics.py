#!/usr/bin/env python3
"""Steady-state check of the quad classes in src/sticktime.lua (read from its QP strings).
Usage: tools/tune_physics.py [class number 1-5] [key=value ...]   e.g. tools/tune_physics.py 1 vp=60 grip=2

Model (mass-normalised, body axes r/u/f; the same steps as physics() in src/sticktime.lua):
  T   = Tmax*(i0 + (1-i0)*((1-tk)*x^tn + tk*x^8)),  x = max(0, (thr-dz)/(1-dz))   stick -> thrust, lagged with tm
  Ta  = max(0, T - vu*T*(Tmax/T)^vc/(vp + vu*vk))  climbing (vc: how the loss scales with thrust,
                                                  vk: the loss bends, the prop unloads);
       T*max(rf, 1 + (cq-1)*(1-ce*tf)*(2x - x^2)), x = sink/(sq*tf^se)  descending: a cushion that
                                                  peaks, then the blades stall (tf = T/Tmax)
  Ta *= 1 - wl*wash*fade  (Prop wash on: sinking into your own downwash, see src/sticktime.lua)
  Ta *= 1 + tl*fade*e2/(e2 + vt^2)   translational lift; fade = (1 + tb*T/Tmax)*(1 - te*(T/Tmax)^4)/(1 + vu/ta):
                                       it grows with throttle (tb), fades near full
                                       stick and with axial inflow
  S   = (ks|vr| + ku|vu| + kf|vf|)*(1 + er*(1 - smoothstep(|v|/vd)))     drag along the flow: a = -S*v
  frame lift: s = vu/|v|, q = lr*s*0.813*(2|s|sqrt(1-s^2))^0.6*S*|v|/sqrt(1-s^2)
              a_u -= q*(1-s^2), a_r += q*s*vr/|v|, a_f += q*s*vf/|v|
  gravity 10.78 (1.1 g)
  flips: the motors' rate follows the body rate no faster than am*(1 + MIX_K*(hover level - level)); while
  it spins up, the differential u (share of the motors' range) shifts the collective as an airmode mixer
  does, in command units c = sqrt((T/Tmax - i0)/(1 - i0)): c + u/2 <= 1, c >= u/2,
  T = Tmax*(i0 + (1-i0)*(c^2 + (u/2)^2))
The class values were fitted to a detailed per-prop model of each class; the targets they were
fitted to are in docs/flight-model.md.
"""
import math
import pathlib
import re
import sys

G = 10.78
ROOT = pathlib.Path(__file__).resolve().parents[1]


def classes():
    src = (ROOT / "src" / "sticktime.lua").read_text(encoding="utf-8")
    keys = re.search(r"local QK = \{([^}]*)\}", src).group(1)
    keys = re.findall(r'"(\w+)"', keys)
    block = re.search(r"local QP = \{(.*?)\n\}", src, re.S).group(1)
    out = []
    for line in block.splitlines():
        m = re.match(r'\s*"([^"]+)",?\s*--\s*(.*)', line)
        if m:
            p = dict(zip(keys, (float(x) for x in m.group(1).split())))
            p["name"] = m.group(2)
            out.append(p)
    return out


def curve(p, x):
    tk = p.get("tk", 0.0)
    return (1 - tk) * x ** p["tn"] + tk * x ** 8


def thrust(p, s):
    x = max(0.0, (s - p["dz"]) / (1 - p["dz"]))
    return p["twr"] * G * (p["i0"] + (1 - p["i0"]) * curve(p, x))


def hover_stick(p, load=1.0):
    r = (load / p["twr"] - p["i0"]) / (1 - p["i0"])
    lo, hi = 0.0, 1.0
    for _ in range(50):
        m = (lo + hi) / 2
        if curve(p, m) < r: lo = m
        else: hi = m
    return p["dz"] + (1 - p["dz"]) * hi


def accel(p, Tm, vu, vr, vf):
    """body-axis accelerations (u, r, f) from props, drag and frame lift"""
    Tmax = p["twr"] * G
    tf = Tm / Tmax
    if vu < 0:                                                 # the cushion rises, then the blades stall
        x = -vu / (p["sq"] * tf ** p["se"]) if tf > 0.001 else 9.0
        fl = min(1.0, p["rf"] + p.get("rq", 0.0) * tf)          # stalled floor: lower at idle
        Ta = Tm * max(fl, 1 + (p["cq"] - 1) * (1 - p["ce"] * tf) * (2 * x - x * x))
    else:
        den = max(0.3 * p["vp"], p["vp"] + vu * p["vk"])
        Ta = max(0.0, Tm - vu * Tm * (Tmax / Tm) ** p["vc"] / den) if Tm > 0 else 0.0
    e2 = vr * vr + vf * vf
    fa = max(0.0, 1 - p["te"] * tf ** 4) * (1 + p.get("tb", 0.0) * tf)   # translational lift: grows with throttle, fades near full stick
    if vu > 0:
        fa /= 1 + vu / p["ta"]                                 # and with axial inflow
    Ta *= 1 + p["tl"] * fa * e2 / (e2 + p["vt"] ** 2)
    au, ar, af = Ta, 0.0, 0.0
    v2 = vu * vu + e2
    if v2 > 1e-4:
        v = math.sqrt(v2)
        S = p["ks"] * abs(vr) + p["ku"] * abs(vu) + p["kf"] * abs(vf)
        xd = min(1.0, v / p["vd"])
        S *= 1 + p["er"] * (1 - xd * xd * (3 - 2 * xd))
        au, ar, af = Ta - S * vu, -S * vr, -S * vf
        sn = vu / v
        c2 = 1 - sn * sn
        if c2 > 1e-4:
            c = math.sqrt(c2)
            q = p["lr"] * sn * 0.813 * (2 * abs(sn) * c) ** 0.6 * S * v / c
            au -= q * c2
            ar += q * sn * vr / v
            af += q * sn * vf / v
    # rotor drag (the Grip setting, grip=0/1/2 on the command line: Low / Medium / High;
    # 0, the fitted model, unless given: the game's default is Medium)
    kh = p.get("kh", 0.0) * (0.0, 0.4, 1.0)[int(p.get("grip", 0))]
    if kh > 0:
        k = kh * math.sqrt(Tm * 0.0186 + 0.02)
        ar -= k * vr
        af -= k * vf
    return au, ar, af


MIX_K = -1.0       # flip authority: am*(1 + MIX_K*(hover level - level)), more toward full throttle (fitted)


def level(p, T):
    """the motors' command level (0..1) for a thrust: thrust ~ command^2 above idle"""
    return math.sqrt(max(0.0, (T / (p["twr"] * G) - p["i0"]) / (1 - p["i0"])))


def authority(p, T):
    """how fast the motors can spin the quad up at this thrust (rad/s^2)"""
    return p.get("am", 0.0) * max(0.3, 1 + MIX_K * (level(p, G) - level(p, T)))


def mix(p, Tm, u):
    """the collective thrust with a motor differential u (share of the motors' range) on top, as an
    airmode mixer: the high side can't pass full power (the collective drops), the low side can't go
    below idle (it rises)"""
    c, d = level(p, Tm), min(u, 1.0) / 2
    if c + d > 1:
        c = 1 - d
    if c < d:
        c = d
    return p["twr"] * G * (p["i0"] + (1 - p["i0"]) * (c * c + d * d))


def flip(p, thr, rate=667.0, after=0.3, h=0.01):
    """a full-stick roll (`rate` deg/s) from a still, level quad until it has turned 360 deg, then the
    stick centred for `after` s: height change (m) and vertical speed (m/s). The body rate follows the
    stick through the tr lag; the motors' own rate follows it no faster than authority() (as in
    physics() in src/sticktime.lua, 80 Hz substeps)"""
    Tm = thrust(p, thr)
    A = authority(p, Tm)
    a = w = wm = vx = vy = y = t = ang = 0.0
    target, done = math.radians(rate), None
    while done is None or t < done + after:
        w += ((target if done is None else 0.0) - w) * h / (p["tr"] + h)
        a += w * h
        ang += abs(w) * h
        T = Tm
        if A > 0:
            dm = max(-A * h, min(A * h, w - wm))
            wm += dm
            T = mix(p, Tm, abs(dm) / (A * h))
        uy, ux = math.cos(a), math.sin(a)
        vu, vr = vx * ux + vy * uy, vx * uy - vy * ux
        au, ar, _ = accel(p, T, vu, vr, 0.0)
        vx += (ux * au + uy * ar) * h
        vy += (uy * au - ux * ar - G) * h
        y += vy * h
        t += h
        if done is None and ang >= 2 * math.pi:
            done = t
    return y, vy


def fly(p, thr, pitch_deg, v0=(0.0, 0.0), secs=14.0, h=0.0125, hold_alt=False, until=None):
    """attitude held at pitch_deg nose down (yaw 0, wings level); returns (t, vy, vz) world"""
    a = math.radians(pitch_deg)
    uy, uz, fy, fz = math.cos(a), math.sin(a), -math.sin(a), math.cos(a)
    vy, vz = v0
    Tm = thrust(p, thr)
    t = 0.0
    while t < secs:
        vu, vf = vy * uy + vz * uz, vy * fy + vz * fz
        au, _, af = accel(p, Tm, vu, 0.0, vf)
        vy = 0.0 if hold_alt else vy + (uy * au + fy * af - G) * h
        vz += (uz * au + fz * af) * h
        t += h
        if until and until(vy, vz):
            break
    return t, vy, vz


def report(p):
    hover = hover_stick(p)
    _, climb, _ = fly(p, 1.0, 0.0, secs=8)
    _, fall, _ = fly(p, 0.0, 0.0, secs=10)
    best = None
    for deg in [x * 2.5 for x in range(8, 35)]:
        _, vy, vz = fly(p, 1.0, deg, v0=(0.0, 25.0))
        if vy > -0.3 and (best is None or vz > best[1]):
            best = (deg, vz)
    # sideways slide at hover throttle, altitude held: seconds until half of 15 m/s is left
    Tm, v, t, h = thrust(p, hover), 15.0, 0.0, 0.0125
    while v > 7.5 and t < 30:
        _, ar, _ = accel(p, Tm, 0.0, v, 0.0)
        v += ar * h
        t += h
    fh, ff = flip(p, hover)[0], flip(p, 1.0)[0]
    print(f"{p['name']:44s} stock {p['twr']:.1f}:1  hover stick {hover:.2f}  punch-out {climb * 3.6:4.0f} km/h  "
          f"flat fall {-fall * 3.6:3.0f} km/h  top {best[1] * 3.6:4.0f} km/h at {best[0]:.1f} deg  slide half-life {t:.1f} s  "
          f"flip at hover / full throttle {fh:+.1f} / {ff:+.1f} m")


def main():
    cls = classes()
    pick = [a for a in sys.argv[1:] if "=" not in a]
    sel = [cls[int(i) - 1] for i in pick] if pick else cls
    for p in sel:
        for a in sys.argv[1:]:
            if "=" in a:
                k, v = a.split("=")
                p[k] = float(v)
        report(p)


if __name__ == "__main__":
    main()
