# Ideas for later

Not planned for a release yet. The numbers are from the detailed per-prop model the flight model is
fitted to (see [flight-model.md](flight-model.md)), measured the same way as everything else there.

## Motor saturation in flips (airmode)

**Today:** body rates follow the stick through a short lag, the same at any throttle, and the thrust does
not change during a flip. A full-stick snap starts at about 74,000 deg/s².

**The per-prop model, on a full-stick flip:**

| | 5" and 3" | Whoop 65mm |
|---|---|---|
| At full throttle | the thrust dips to about 50% for 26-30 ms while airmode makes room for the roll; the roll reaches 63% of its rate in 28-30 ms | 50% for 62 ms; 46 ms |
| At hover throttle | the thrust rises 37-58% over the first 100 ms: the low side's motors bottom out at idle while the high side pushes, so the quad pops up | +13% |
| Strongest roll acceleration | 33,000-37,000 deg/s² at hover throttle, about 24,000 at full throttle | about 15,000 |
| Roll rate 63% | 14-16 ms at half stick, 20-30 ms at full stick | 20 ms, 42-46 ms |

**Idea:** a small mixer on thrust fractions in each physics substep. The rate change the stick asks for
needs a differential between the motors on top of the collective thrust:

- the high side would go past full power: the collective drops (the dip at full throttle);
- the low side would go below idle: the collective rises (the pop in flips at low throttle);
- the differential needs more than the motors' whole range: the rotation is limited.

One new number per class, `am` (the strongest angular acceleration), fitted to the per-prop model at
idle, hover and full throttle. A choice to make: all of it (full-stick snaps then take 20-30 ms to 63%
instead of about 9 ms, as in the model), or only the thrust dip and pop (today's snap stays). About 40
lines in each edition, a few hundred bytes of memory on the Lite; `tools/tune_physics.py` would get a
flip test, the headless tests checks of the dip and the pop.

## Scraping obstacles instead of crashing

**Today:** any touch of a gate frame, pole, tree, wall or structure is a crash; a landing has to be
gentle and upright.

**The per-prop model:** contacts don't bounce (no restitution) and nothing breaks. The quad stops
into the obstacle, scrapes along it with friction (0.1 on the props, 0.3-0.6 on the frame) and tumbles
from the off-centre hit, and the flight controller rights it. Damage (bent props, motors cut for a
second or two) happens only in some race modes, from 19-25 m/s.

**Idea:** a contact response instead of the crash:

- the velocity into the obstacle goes (no bounce), the sliding part slows with friction (about 0.3),
  the quad is pushed back out, and its attitude is knocked away from the hit, more for a harder hit
  (about 2 degrees per m/s, at most about 45); a short thud and a buzz;
- which way is out: a gate frame or ring along the gate's own facing, poles, trees and gate legs
  straight out from the pole, structures through the nearest face, the ground and roofs up;
- still a crash: a hit faster than a threshold (about 12 m/s into the obstacle), lying upside down
  on the ground for a second (or a turtle mode later), leaving the world;
- game rules: a scrape is never a gate pass (gate detection stays as it is), the crash count counts
  only crashes, a scrape ends a freestyle chain; the AI pilots don't change;
- maybe a **Crashes** setting: Touch (today) or Hard hits only.

About 80-120 lines in the color and B&W game and 60-80 in the Lite, whose memory test has about
1.5 KB to spare on its tightest heap, so all 13 heaps get checked. Tests: a scrape along a wall at 5 m/s
keeps flying, a hit at 20 m/s crashes, a clipped gate frame keeps flying, an upside-down landing
respawns.

## Looked at and left out

- **A yaw twitch on punch-outs.** The per-prop model has none: its four identical motors' torques
  cancel and the yaw rate stays at zero. Real quads twitch a little from small differences between
  motors and props, with nothing measured to size it by.
