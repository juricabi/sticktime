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

## Looked at and left out

- **A yaw twitch on punch-outs.** The per-prop model has none: its four identical motors' torques
  cancel and the yaw rate stays at zero. Real quads twitch a little from small differences between
  motors and props, with nothing measured to size it by.
