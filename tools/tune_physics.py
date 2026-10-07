#!/usr/bin/env python3
"""Steady-state check of the quad model used in src/fpvsim.lua.
Usage: tools/tune_physics.py [KH=0.18 VP=60 KQS=0.0072 KQU=0.024]

Model (mass-normalised, body axes r/u/f):
  T  = Tmax*(0.04 + 0.96*thr^1.6)       motor thrust, lagged with TAU_M
  Ta = T - vu*sqrt(T*Tmax)/VP            props lose thrust with axial airspeed (pitch speed ~ rpm)
  kh = KH*sqrt(T/Tmax + 0.02)            rotor drag in the prop plane
  a  = u*(Ta - KQU|vu|vu) + r*(-kh vr - KQS|vr|vr) + f*(-kh vf - KQS|vf|vf) - g
"""
import math
import sys

G = 9.81
# racer profile in src/fpvsim.lua (QP); freestyle: KH=0.18 VP=60 KQS=0.0072 KQU=0.024
P = dict(KQS=0.009, KQU=0.028, KH=0.22, VP=86.0)


def accel(v, th, thr, twr, p):
    """v: (vy, vz) world velocity, th: nose-down tilt (rad). returns world accel (ay, az)."""
    Tmax = twr * G
    T = Tmax * (0.04 + 0.96 * thr ** 1.6)
    # body axes in the y-z plane: u = (cos th, sin th), f = (-sin th, cos th)
    uy, uz, fy, fz = math.cos(th), math.sin(th), -math.sin(th), math.cos(th)
    vy, vz = v
    vu = vy * uy + vz * uz
    vf = vy * fy + vz * fz
    Ta = T - vu * math.sqrt(T * Tmax) / p["VP"]
    if vu < 0:
        Ta = min(Ta, T * 1.25)
    Ta = max(0.0, Ta)
    kh = p["KH"] * math.sqrt(T / Tmax + 0.02)
    au = Ta - p["KQU"] * abs(vu) * vu
    af = -kh * vf - p["KQS"] * abs(vf) * vf
    return uy * au + fy * af - G, uz * au + fz * af


def settle(th, thr, twr, p, secs=25.0, v0=(0.0, 0.0)):
    v = list(v0)
    h = 0.005
    for _ in range(int(secs / h)):
        ay, az = accel(v, th, thr, twr, p)
        v[0] += ay * h
        v[1] += az * h
    return v


def top_speed(twr, p):
    """best level speed at full throttle: find tilt where vertical speed ~ 0."""
    best = None
    for deg in range(30, 89):
        th = math.radians(deg)
        vy, vz = settle(th, 1.0, twr, p)
        if vy >= -0.05 and (best is None or vz > best[1]):
            best = (deg, vz, vy)
    return best


def main():
    p = dict(P)
    for a in sys.argv[1:]:
        k, v = a.split("=")
        p[k] = float(v)
    for twr in (3, 5, 8, 12):
        hover = ((1 / twr - 0.04) / 0.96) ** (1 / 1.6)
        climb = settle(0.0, 1.0, twr, p)[0]
        fall = settle(0.0, 0.0, twr, p)[0]
        deg, vz, vy = top_speed(twr, p)
        # braking: from top speed, flip to 60 deg nose-up full throttle; time to reach 5 m/s
        v = [0.0, vz]
        t, h = 0.0, 0.005
        while v[1] > 5 and t < 10:
            ay, az = accel(v, math.radians(-60), 1.0, twr, p)
            v[0] += ay * h; v[1] += az * h; t += h
        print(f"TWR {twr}: hover {hover*100:4.1f}%  top {vz*3.6:5.1f} km/h at {deg} deg  punch-out {climb*3.6:5.1f} km/h  "
              f"flat fall {-fall*3.6:5.1f} km/h  brake {vz*3.6:3.0f}->18 km/h in {t:.2f}s")


if __name__ == "__main__":
    main()
