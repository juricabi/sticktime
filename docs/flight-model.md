# Flight model 2

StickTime's quad is a point mass with an attitude, integrated in 80 Hz substeps, with everything
expressed per unit mass in body axes (r right, u up, f forward). This branch flies flight model 2:
an rpm-curve model with eleven presets. It is simple on purpose: thrust straight from the motors'
rpm, quadratic drag that grows with throttle, and attitude that follows the sticks almost at once.
It has no descent cushion, translational lift, ground effect or frame lift.

## Per substep

    rpm R (a fraction of full):  R -> max(stick, 0.0386) + boost, at up to 5.47 per second
                                 (170 000 of 31 080 rpm a second, both ways); 0.0386 is idle
    boost                        = (e_roll + e_pitch + e_yaw) / 3, e = min(1, rate error / 120 deg/s):
                                 a rate the quad has not reached yet pushes the motors up, so hard
                                 flips and snaps add thrust
    thrust  Ta = twr*g * R * curve(R)
            curve: 10 points (0.1 0.4 0.5 0.6 0.7 0.79 0.84 0.9 0.95 1) in 1% buckets (10 linear
            steps per segment), so thrust per rpm rises steeply at low rpm: quads hover at 17-36%
            stick
            climbing (air coming through the props, vu > 0): Ta *= 1 - 0.005*floor(100*vu/top)
            (half the thrust at `top`; it is not a speed limit)
    drag    S = (kx|vr| + ky|vu| + kz|vf|) * (1 + cd*R),  a = -S*v
            k = 0.5*0.38*1.225*area/mass per face; cd: more drag with throttle ("corner grip")
    air     v *= 1 - 0.1*dt; gravity 9.8; wind blows the air the drag is taken against
    rates   StickTime's rate settings; the body rates follow them with `tr` (roll/pitch) and `ty`
            (yaw) response times of a few milliseconds

Prop wash (setting, off by default, so the model above is all there is): Stock and Max add flight
model 1's prop wash on top, from the class of the same size (5", 3", whoop): sinking into your own
downwash costs thrust and the quad shakes by tenths of a degree at 20-45 Hz (not in the Lite).

The Lite flies the same model; it reads the preset in use from `StickTimeLite/q<n>.txt`.

## Presets

Parameters (`QP` in `src/sticktime.lua`, one string per preset): `twr` thrust/weight, `top` (m/s),
`kx ky kz` (1/m), `cd`, `tr ty` (s), `snd` the motor sound class, the optional prop wash (`pw wl wv`
at Max, `wls wvs pws` at Stock, `pf` Hz) and `tlo`-`thi`, the Power settings offered (Stock is
always there).

| Preset | weight | thrust | twr | top | kx / ky / kz (1/m) | cd | Power |
|---|---|---|---|---|---|---|---|
| 5" Freestyle | 680 g | 5.5 kg | 8.1 | 160 km/h | .0229 / .0219 / .0222 | .8 | 4-10:1 |
| 5" Light | 620 g | 5.2 kg | 8.4 | 160 km/h | .0252 / .0240 / .0244 | .8 | 4-10:1 |
| 5" Heavy | 740 g | 6.2 kg | 8.4 | 160 km/h | .0211 / .0201 / .0204 | .8 | 4-10:1 |
| 5" Chonker | 800 g | 6.2 kg | 7.75 | 160 km/h | .0195 / .0186 / .0189 | .8 | 4-10:1 |
| 5" Racer | 480 g | 6.0 kg | 12.5 | 200 km/h | .0310 / .0286 / .0305 | .8 | 5-12:1 |
| 5" Beginner | 680 g | 3.0 kg | 4.4 | 100 km/h | .0229 / .0219 / .0222 | .8 | 3-10:1 |
| 3.5" Quad | 290 g | 1.8 kg | 6.2 | 130 km/h | .0215 / .0180 / .0205 | .8 | 3-10:1 |
| 2.5" Analog | 83 g | 550 g | 6.6 | 80 km/h | .0292 / .0278 / .0283 | .8 | 3-10:1 |
| 2.5" HD | 95 g | 640 g | 6.7 | 90 km/h | .0255 / .0243 / .0247 | .8 | 3-10:1 |
| 85mm Whoop | 69 g | 400 g | 5.8 | 50 km/h | .0378 / .0398 / .0378 | .6 | 3-8:1 |
| 65mm Whoop | 28 g | 160 g | 5.7 | 40 km/h | .0648 / .0698 / .0648 | .6 | 3-8:1 |

What they give (`tools/tune_physics.py`; the same in the game, color and Lite): hover stick,
punch-out (vertical speed after 8 s of full throttle), flat fall (after 10 s at idle), top speed
(best pitch held, full throttle, not sinking) and the half-life of a 15 m/s sideways slide.

| Preset | hover | punch-out | flat fall | top speed | slide |
|---|---|---|---|---|---|
| 5" Freestyle | 0.24 | 113 km/h | 65 km/h | 115 km/h at 77.5 deg | 1.8 s |
| 5" Light | 0.23 | 111 km/h | 62 km/h | 113 km/h at 80 deg | 1.7 s |
| 5" Heavy | 0.23 | 118 km/h | 68 km/h | 120 km/h at 77.5 deg | 1.9 s |
| 5" Chonker | 0.25 | 117 km/h | 70 km/h | 120 km/h at 77.5 deg | 2.0 s |
| 5" Racer | 0.17 | 132 km/h | 57 km/h | 133 km/h at 82.5 deg | 1.5 s |
| 5" Beginner | 0.36 | 72 km/h | 66 km/h | 78 km/h at 70 deg | 1.7 s |
| 3.5" Quad | 0.29 | 100 km/h | 72 km/h | 103 km/h at 75 deg | 1.8 s |
| 2.5" Analog | 0.27 | 76 km/h | 59 km/h | 79 km/h at 72.5 deg | 1.5 s |
| 2.5" HD | 0.27 | 84 km/h | 63 km/h | 87 km/h at 72.5 deg | 1.6 s |
| 85mm Whoop | 0.30 | 59 km/h | 50 km/h | 64 km/h at 70 deg | 1.2 s |
| 65mm Whoop | 0.30 | 45 km/h | 39 km/h | 48 km/h at 70 deg | 0.8 s |

Compared with flight model 1 the quads stop much sooner (slides of 1-2 s instead of ~4 s), punch
out a little slower for their power, and hover lower on the stick.
