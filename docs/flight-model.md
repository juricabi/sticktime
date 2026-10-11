# Flight model

StickTime's quad is a point mass with an attitude, integrated in 80 Hz substeps, with everything
expressed per unit mass in body axes (r right, u up, f forward). Each quad class was measured in a
detailed per-prop model (four blade-element props on rpm-governed motors, a Betaflight-style PID
loop and mixer, body drag and frame lift) and StickTime's reduced model was fitted to the same
measurements.

## Per substep

```
x   = max(0, (thr - dz)/(1 - dz))
T   = Tmax*(i0 + (1 - i0)*x^tn)               Tmax = power * g; lagged with tm
Ta  = max(0, T - vu*sqrt(T*Tmax)/(vp + vu*vk))   climbing loses thrust (vk: the loss bends,
                                               the prop unloads as the inflow grows)
Ta  = min(cq*T, T - vu*sqrt(T*Tmax)/vq)          descending gains it, ~2.5x as fast (a cushion)
Ta *= 1 - wl*w*min(1, (wv - sink)/(wv - 2))      Prop wash on, sinking faster than 0.6 m/s: w builds
                                               toward 1/(1 + edgewise speed) with a 0.2 s lag
Ta *= 1 + tl*fade*e2/(e2 + vt^2)                translational lift, e2 = vr^2 + vf^2: a hover-throttle
                                               effect, fade = min(1, (1/(twr*T/Tmax))^te)
Ta *= 1 + gg*min(1, (gl - d)/gw)/(1 + e2/80)   ground effect when d < gl; d = height above the
                                               surface along body-down (+3 cm, the frame's skids)
S   = (ks|vr| + ku|vu| + kf|vf|) * (1 + er*(1 - smoothstep(|v|/vd)))
a   = Ta*u - S*v                               drag along the flow (each face weighted by the flow
                                               through it), a little more at low speed
s   = vu/|v|                                   frame lift, strongest with the flow at 45 deg:
q   = lr*s*0.813*(2|s|sqrt(1-s^2))^0.6*S*|v|/sqrt(1-s^2)
a_u -= q*(1 - s^2);  a_r += q*s*vr/|v|;  a_f += q*s*vf/|v|
g   = 10.78                                    1.1 g: a heavier, more planted feel
```

Body rates follow the stick's Betaflight Actual rates through a first-order lag (`tr` roll and
pitch, `ty` yaw). Wind works as before.

Prop wash (setting): in the per-prop model it is a thrust loss, not a shake: all four props sink
into the same downwash, so the quad mushes and sinks faster (a 5" at the same throttle sinks at
3.2 m/s instead of 1 m/s). It needs a mostly vertical sink: 4 m/s of edgewise speed clears it.
StickTime adds its wobble on top (falling faster than 2 m/s with throttle on), scaled by the same
wash build-up. The setting "On" gives each class its own strength, measured the same way: the 3"
and both 5"s at prop wash 30 (the 5"s carry none by default; 30 is the standard non-zero choice),
the ducted whoop at its stock 10 - on the whoop it is a whisper, on a 5" a shallow-sink mush.
"Max" carries the full-strength set (`wl/wv/pw`), fitted the same way from the level-100
measurements. Both levels are the same physics; Stock is each class's own dose of it.

There is no rotor drag (in-plane H-force): the per-prop model has none, so quads keep their
momentum (a 5" slide halves in ~4 s). The fitted coefficients are the measured ones, with two
small trims the reduced shape can't avoid: `ku` ~10% down for the idle fall (the per-prop model mixes
the descent cushion with a windmilling prop), and `vp` ~10% for the full-throttle climb. The
translational-lift fade `te` is fitted to the measured top speed: at the racer's top-speed state
the real edgewise gain is +14% where a multiplicative model would give +47%.

## Classes

Parameters (`QP` in `src/sticktime.lua`, one string per class):

| | Racer 5" | Freestyle 5" | 3" toothpick | Whoop 65mm |
|---|---|---|---|---|
| stock power `twr` | 7.67 | 7.88 | 5.35 | 2.58 |
| idle `i0`, curve `tn`, dead zone `dz` | .031, 2.16, 0 | .026, 1.52, .08 | .022, 1.72, .03 | .0059, .9, .11 |
| climbing: prop pitch speed `vp` (m/s), bend `vk` | 60.4, 0 | 59.2, 0 | 49.5, 0 | 57.3, 0 |
| descending: `vq` (m/s), cushion `cq` | 26.3, 1.32 | 26.9, 1.33 | 15.8, 1.61 | 14.1, 1.33 |
| translational lift `tl`, `vt` (m/s), throttle fade `te` | .54, 6, .28 | .48, 5.4, .42 | .96, 9.8, .98 | 1, 9.4, .8 |
| drag side/front/top `ks kf ku` (1/m) | .0152 .00819 .0245 | .0126 .00728 .0181 | .0176 .0167 .0384 | .0741 .07 .0858 |
| low-speed drag `er`, `vd` (m/s) | .36, 15 | .36, 15 | .5, 15 | .29, 7 |
| frame lift `lr` | .229 | .257 | .1 | 0 |
| ground effect `gg`, `gl`, `gw` (m) | .24, .25, .113 | .27, .25, .113 | .44, .15, .135 | .17, .0625, .0344 |
| prop wash loss / fade-out / wobble, stock | .12, 3.8, .27 | .13, 4.3, .55 | .1, 5.2, .55 | .024, 2.5, .32 |
| prop wash loss / fade-out / wobble, max | .33, 6, .5 | .35, 6.5, 1 | .29, 7, 1 | .24, 5.6, 1 |
| response `tm`, `tr`, `ty` (s) | .006 .009 .02 | .006 .007 .02 | .006 .009 .02 | .006 .02 .02 |

Each class is the most common configuration of its kind in the reference set (for the whoop: the
current ducted 65 mm 1S generation, with its acro tune). What they were fitted to (per-prop model,
stock power, attitude held) and what StickTime gives (`tools/tune_physics.py`):

| | Racer 5" | Freestyle 5" | 3" toothpick | Whoop 65mm |
|---|---|---|---|---|
| mass (kg) | 0.487 | 0.577 | 0.108 | 0.024 |
| hover stick, target / StickTime | 0.33 / 0.35 | 0.28 / 0.29 | 0.38 / 0.37 | 0.43 / 0.42 |
| full-throttle climb (m/s) | 34.2 / 33.0 | 35.7 / 35.7 | 22.9 / 22.9 | 11.6 / 11.6 |
| idle fall (m/s) | 17.5 / 17.5 | 21.0 / 21.0 | 15.5 / 15.5 | 11.1 / 11.1 |
| top speed (m/s) at pitch (deg) | 38.9 @ 67.5 / 38.9 @ 67.5 | 41.3 @ 65 / 41.3 @ 62.5 | 26.5 @ 67.5 / 26.4 @ 65 | 14.4 @ 65 / 14.4 @ 65 |
| sideways slide half-life from 15 m/s (s) | 4.03 / 4.03 | 4.86 / 4.86 | 3.39 / 3.38 | 0.90 / 0.90 |
| edgewise thrust gain at 6 / 15 m/s | +27% / +48% | +26% / +43% | +26% / +68% | +29% / +73% |
| thrust at 2 / 6 m/s sink, wash off / on | 1.21 / 1.31, 0.82 / 1.27 | 1.21 / 1.33, 0.80 / 1.22 | 1.29 / 1.61, 0.93 / 1.43 | 1.23 / 1.33, 0.95 / 1.32 |
| thrust response, 63% (hover to full) | 6 ms | 6 ms | 6 ms | 6 ms |
| roll rate step, 63% time (half / full stick) | 6 / 12 ms | 4 / 10 ms | 8 / 10 ms | 10 / 30 ms |

## What the per-prop model has that this one leaves out

- Four props, each with its own airflow: rotating the quad changes each prop's inflow, which damps
  roll and pitch. Whoop props stall in fast vertical drops (they lose thrust beyond 4 m/s).
- The PID loop itself: rate steps overshoot by 35-70% before they settle (strong feedforward on a
  filtered gyro), motors saturate on full-stick flips, yaw is limited to 10000 deg/s^2.
- Battery sag and capacity (rarely on in other sims either), prop deformation at full power,
  bent props after crashes.
- Spec classes and bigger quads.
