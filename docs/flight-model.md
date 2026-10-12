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
tf  = T/Tmax
Ta  = max(0, T - vu*T*(Tmax/T)^vc/(vp + vu*vk))  climbing loses thrust: how the loss scales with
                                               thrust (vc) and bends as the inflow grows (vk)
Ta  = T*max(rf, 1 + (cq-1)*(1-ce*tf)*(2x - x^2)) descending, x = sink/(sq*tf^se): a cushion that
                                               peaks at cq, then the blades stall in a fast drop
Ta *= 1 - wl*w*min(1, (wv - sink)/(wv - 2))      Prop wash on, sinking faster than 0.6 m/s: w builds
                                               toward 1/(1 + edgewise speed) with a 0.2 s lag
Ta *= 1 + tl*fade*e2/(e2 + vt^2)                translational lift, e2 = vr^2 + vf^2; it fades near
                                               full stick and with axial inflow:
                                               fade = (1 - te*tf^4)/(1 + max(0, vu)/ta)
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
StickTime adds the shake a real quad has, sized from real Betaflight blackbox logs (a 6S 5"
freestyler and a 4S quad, gyro against setpoint in the 12-110 Hz band, integrated to an angle):
after a throttle chop the frame jitters by tenths of a degree (peaks of 0.1-0.25 deg, the worst
~0.6 deg, up to 2 deg falling through the wash at idle) at 20-31 Hz on the 5", 35-45 Hz on the
smaller quad. So `pws` is the jitter's rms in degrees at full wash with the throttle chopped (0.19
on the 5"s, 0.23 on the 3", 0.27 on the whoop, scaled from an Air65's tracking error), about half
that with throttle on, each wash its own severity (most catches mild, a few nasty), and `pf` its
frequency (26, 24, 35, 45 Hz); past what the frame rate can show it shakes as fast as the screen
can. It starts at a 0.5 m/s sink, dies away over ~0.2 s once the sink stops and is cleared by
edgewise speed through the same wash build-up. On a radio screen it is barely visible, as in real
life: what you feel is the mush, and in the browser emulator the motors' chatter. The Lite leaves
it out: under a pixel on its screens, and its radios have no memory to spare. The setting "Stock"
gives each class its own strength, measured the same way: the 3" and both 5"s at prop wash 30 (the
5"s carry none by default; 30 is the standard non-zero choice), the ducted whoop at its stock 10 -
on the whoop it is a whisper, on a 5" a shallow-sink mush. "Max" carries the full-strength set
(`wl/wv/pw`), fitted the same way from the level-100 measurements, its shake scaled like the wash.
Both levels are the same physics; Stock is each class's own dose of it.

There is no rotor drag (in-plane H-force): the per-prop model has none, so quads keep their
momentum (a 5" slide halves in ~4 s). Drag is the measured coefficient of each face, untrimmed.
The thrust shape (`vp vk vc tl vt te ta`) is fitted jointly to the per-prop model's thrust map
over each class's own flight envelope (axial inflow up to its climb rate, edgewise flow up to its
top speed) and to its steady flight at 0-65 deg pitch and half to full stick; the descent cushion
(`sq cq ce se rf`) to its thrust map while sinking at idle to full stick. Over those steady flight
states StickTime is within 0.4-0.9 m/s of the per-prop model on average, with no vertical bias.
The **Grip** setting adds it: props moving edgewise are pushed back, harder the faster they spin,
so `a = -kh * sqrt(Tm/5g + 0.02) * v` in the prop plane (the 1.6.4 form). Sim leaves it out, as
the reference does (pilots rate that momentum as the closest to a real racer); High is set per
class so that the sideways slide half-life halves (a racer: 4 s to 2 s, where quads with rotor
drag modelled sit), Medium is 0.4 of High (~3 s).

## Classes

Parameters (`QP` in `src/sticktime.lua`, one string per class):

| | Racer 5" | Freestyle 5" | 3" toothpick | Whoop 65mm | Whoop 75mm |
|---|---|---|---|---|---|
| stock power `twr`, Power settings offered `tlo`-`thi` | 7.67, 5-12:1 | 6.88, 4-10:1 | 5.35, 3-10:1 | 2.58, 3-8:1 | 3.54, 3-8:1 |
| idle `i0`, curve `tn`, dead zone `dz` | .031, 2.16, 0 | .026, 1.52, .08 | .022, 1.72, .03 | .0059, .9, .11 | .02, .84, .11 |
| climbing: prop pitch speed `vp` (m/s), throttle exponent `vc`, bend `vk` | 77.4, .58, .1 | 75.5, .52, -.28 | 67.6, .68, -.77 | 72.9, .89, -1 | 74.5, .83, -1 |
| descending cushion: peak `cq` at sink `sq`*tf^`se` (m/s), full-stick fade `ce`, stalled `rf` | 1.35 at 15.5*tf^.58, .54, .76 | 1.39 at 13.5*tf^.5, .72, .72 | 1.61 at 15.5*tf^.52, .21, .88 | 1.37 at 9.08*tf^.56, .17, .9 | 1.12 at 14.1*tf^.47, -1, .45 |
| translational lift `tl`, `vt` (m/s), fades: full stick `te`, axial inflow `ta` (m/s) | .85, 8.6, .4, 35.1 | .69, 9.14, .51, 90.5 | 1, 9.33, 0, 12.2 | 1.1, 9.97, .019, 23.6 | 1.1, 9.17, 0, 29 |
| drag side/front/top `ks kf ku` (1/m) | .0152 .00819 .0287 | .011 .00635 .0184 | .0176 .0167 .0417 | .0741 .07 .0875 | .0962 .0822 .0288 |
| low-speed drag `er`, `vd` (m/s) | .36, 15 | .36, 15 | .5, 15 | .29, 7 | .56, 15 |
| frame lift `lr` | .229 | .257 | .1 | 0 | .4 |
| ground effect `gg`, `gl`, `gw` (m) | .24, .25, .113 | .26, .25, .113 | .44, .15, .135 | .17, .0625, .0344 | .19, .08, .036 |
| prop wash loss / fade-out (m/s) / shake rms (deg), stock | .12, 3.8, .19 | .13, 4.6, .19 | .1, 5.2, .23 | .024, 2.5, .27 | .095, 3.6, .25 |
| prop wash loss / fade-out (m/s) / shake rms (deg), max | .33, 6, .35 | .35, 7, .35 | .29, 7, .42 | .24, 5.6, .85 | .28, 5.6, .46 |
| prop wash shake frequency `pf` (Hz) | 26 | 24 | 35 | 45 | 40 |
| rotor drag for Grip High `kh` (1/s, times sqrt(thrust/5g + 0.02): ~0.47 at hover; Medium 0.4 of it) | .36 | .26 | .43 | 1.6 | 2.4 |
| response `tm`, `tr`, `ty` (s) | .006 .009 .02 | .006 .008 .02 | .006 .009 .02 | .006 .02 .02 | .006 .016 .02 |

Each class is the most common configuration of its kind in the reference set (for the whoop: the
current ducted 65 mm 1S generation, with its acro tune). What they were fitted to (per-prop model,
stock power, attitude held) and what StickTime gives (`tools/tune_physics.py`):

| | Racer 5" | Freestyle 5" | 3" toothpick | Whoop 65mm | Whoop 75mm |
|---|---|---|---|---|---|
| mass (kg) | 0.487 | 0.661 | 0.108 | 0.024 | 0.0468 |
| hover stick, target / StickTime | 0.33 / 0.35 | 0.30 / 0.31 | 0.38 / 0.37 | 0.43 / 0.42 | 0.30 / 0.30 |
| full-throttle climb (m/s) | 34.2 / 35.3 | 35.0 / 35.5 | 22.9 / 22.5 | 11.6 / 11.6 | 21.6 / 20.9 |
| idle fall (m/s) | 17.5 / 17.5 | 22.8 / 22.6 | 15.5 / 15.2 | 11.1 / 11.0 | 19.3 / 19.0 |
| top speed (m/s) at pitch (deg) | 38.9 @ 67.5 / 40.3 @ 70 | 41.4 @ 62.5 / 41.5 @ 62.5 | 26.5 @ 67.5 / 26.4 @ 67.5 | 14.4 @ 65 / 14.7 @ 65 | 21.4 @ 57.5 / 21.4 @ 57.5 |
| sideways slide half-life from 15 m/s (s) | 4.03 / 4.03 | 5.57 / 5.57 | 3.39 / 3.38 | 0.90 / 0.90 | 0.61 / 0.61 |
| edgewise thrust gain at 6 / 15 m/s | +27% / +48% | +26% / +43% | +26% / +68% | +29% / +73% | +30% / +67% |
| thrust at 2 / 6 m/s sink, wash off / on | 1.21 / 1.31, 0.82 / 1.27 | 1.20 / 1.34, 0.79 / 1.17 | 1.29 / 1.61, 0.93 / 1.43 | 1.23 / 1.33, 0.95 / 1.32 | 1.24 / 1.29, 0.90 / 1.30 |
| thrust response, 63% (hover to full) | 6 ms | 6 ms | 6 ms | 6 ms | 6 ms |
| roll rate step, 63% time (half / full stick) | 6 / 12 ms | 6 / 10 ms | 8 / 10 ms | 10 / 30 ms | 10 / 22 ms |

## What the per-prop model has that this one leaves out

- Four props, each with its own airflow: rotating the quad changes each prop's inflow, which damps
  roll and pitch. Whoop props stall in fast vertical drops (they lose thrust beyond 4 m/s).
- The PID loop itself: rate steps overshoot by 35-70% before they settle (strong feedforward on a
  filtered gyro), motors saturate on full-stick flips, yaw is limited to 10000 deg/s^2.
- Battery sag and capacity (rarely on in other sims either), prop deformation at full power,
  bent props after crashes.
- Spec classes and bigger quads.
