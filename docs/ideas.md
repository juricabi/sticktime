# Ideas for later

Not planned for a release yet. The numbers are from the detailed per-prop model the flight model is
fitted to (see [flight-model.md](flight-model.md)), measured the same way as everything else there.

## Motor saturation in flips: slowing the snap too

The thrust side of it is in the flight model since 1.6.7 (the airmode mixer in
[flight-model.md](flight-model.md)): a full-stick flip dips the thrust at full throttle and lifts it
near hover. The body rate is left as it was, so a full-stick snap still reaches 63% of its rate in
about 9 ms. In the per-prop model the motors also limit how fast the quad spins up: on average 55,000
deg/s² at hover throttle and 47,000 at full on a 5" racer, 17,000-18,000 on a 65 mm whoop, and its PID
loop overshoots the rate by about 30% for the first 50 ms. The idea would be a physical spin-up limit
on the body rate (the mixer's `am` is fitted to the thrust, not to that), as an option, since quick,
clean snaps help with the sim's own latency.

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
