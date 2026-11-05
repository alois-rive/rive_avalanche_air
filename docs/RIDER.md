# The rider: physics and controller

The rider is an arcade model, not a simulation: it decides the velocity,
and box3d-as (the engine's copy of Box3D's AnimaScript port, as the kart
sample uses it: `rive_modeler/samples/kart/docs/KINEMATICS.md`) finds the
snow, the obstacles and the sensors. The feel goals, in order: a new
player lands something in ten seconds; carving feels fast and committed;
air is generous and readable; a landing is judged fairly and visibly; a
crash costs points, never flow.

Every number here is a starting value for the controller lab (section
11), tuned there and recorded back here.

## 1. The tick

- 120 ticks a second, run inside `_process` by a `FixedClock` (frames
  clamped to 0.1 s, at most 6 ticks a frame), the drawn pose interpolated
  between the last two ticks (`DrawnPose`), as the kart does
  (`lib/kinematic.as`, copied from the kart sample with its tests).
- The Box3D world is stepped once a tick, serially, never in parallel;
  every number is f32 in a fixed order; randomness comes from `Pcg32`
  streams seeded per run (the grind's wobble, the tumble, the spray).
- The same seed and the same inputs give the same run, bit for bit,
  natively and on the web (TESTS.md, section 1). Replays, the ghost and
  the attract mode are input logs replayed.

## 2. The body

| Part | What | Numbers |
|---|---|---|
| state | position, velocity (3D), heading (the board's travel direction in the ground's plane), stance (regular or switch), on-ground / in-air / grinding / tumbling, crouch charge, tuck amount | |
| mover | a Box3D capsule (`b3Capsule`, radius 0.3 m, from 0.3 to 1.3 m above the board) moved by the model's velocity against layers 2 and 4 (obstacles, rails' bodies): `b3World_CollideMover`, `b3SolvePlanes`, `b3World_CastMover`, `b3ClipVector` (KINEMATICS.md, section 6.1) | |
| snow probes | four rays down (nose, tail, toe edge, heel edge), from 0.5 m above the board to 0.4 m below, against layer 1 (`probeDown` on the course's ground grid) | nose and tail 0.75 m apart, edges 0.25 m apart |
| proxy | a kinematic body following the mover (`b3Body_SetTargetTransform`), on layer 16, so the sensors (fall zones, the finish, music cues) see the rider | |

The ground's plane under the board is fitted to the probes that hit; the
board's pitch and roll follow it, eased at 20 /s so that bumps read as
bumps and the vertex snapping's jitter is not amplified.

## 3. On the snow

**Speed along the board.** With θ the slope, φ the angle between the
heading and the fall line, μ the surface's friction (COURSE.md, section 3)
and k the drag:

```
a = g sin θ cos φ  -  μ g cos θ  -  k v²  -  c |steer|
```

| Value | Standing | Tuck |
|---|---|---|
| k (drag, /m) | 0.0055 | 0.0028 |
| speed on a 15° groomed slope (terminal) | 20 m/s | 28 m/s, capped |
| speed cap | 27 m/s (97 km/h): above 25 m/s, k doubles | |
| c (the cost of carving) | 0.6 m/s² at full lock | |

g is 9.81 on the ground. Powder's μ is 0.09 and the rider sinks 0.15 m
(slower turns: section 3's yaw rate x 0.7); ice's μ is 0.015 with half the
grip.

**Steering.** The yaw rate is `steer x ω(v)`: 120°/s at 6 m/s or less,
falling linearly to 50°/s at 27 m/s; x 0.6 in a full tuck. The input is
eased at 8 /s (keyboard: 0 to 1 in 0.12 s). The drawn lean (edge angle)
is `atan(v ω / g)`, at most 55°.

**Grip.** The lateral velocity is pulled to zero at `10 x grip /s` (grip
1.0 groomed, 0.8 powder, 0.5 ice). Beyond 1.3 g of lateral demand the
excess slides: a skid, its friction 0.25 (it scrubs speed), its spray
twice as thick and its sound harsher (AUDIO.md, section 4).

**Stopping and climbing.** There is no brake: carving across or up the
slope slows the rider. Below 1 m/s the rider skates (1.5 m/s² along the
fall line, the heading eased downhill at 60°/s), so no one gets stuck.

**Tuck.** Stick down (below -0.5) or S: the tuck blends in over 0.25 s and
out over 0.15 s. Not while crouching.

**Riding switch.** Landing with the board's nose uphill swaps the stance:
the rider rides switch (the poses mirrored), and the next trick taken off
switch is named "SWITCH" (TRICKS.md, section 2). Turning the heading more
than 120° from the fall line on the snow does the same (a "revert").

## 4. Crouch and ollie

| Step | What |
|---|---|
| press (south / Space) | the crouch blends in over 0.15 s; the charge counts from 0 to 0.4 s |
| release | a pop along the ground's normal: `3.0 + 2.0 x min(charge / 0.4, 1)` m/s (a tap 3.0, full 5.0); 0.25 s before the next |
| pre-wind | a spin direction held while crouched starts the flight with a spin of 180°/s that way |
| on a lip | a release while the board is on a kicker's lip adds the pop to the launch; a release in the last 0.12 s before the board leaves the lip is a **perfect pop**: +1.0 m/s more and the next combo's value x 1.1 (TRICKS.md, section 5) |

Leaving a lip without an ollie launches the rider with the lip's
velocity: every jump works without one. Air with an ollie off a roller's
crest at 11 m/s: about 0.7 s, enough for a 180 or a grab (the first-10 s
goal).

## 5. In the air

**Flight.** Ballistic with the game's air gravity, **13 m/s²** (snappier
than 9.81; the course generator flies its jumps with the same value:
COURSE.md, section 4), and a light drag (k 0.0015, horizontal). The stick
does not steer the flight, except 0.5 m/s² of lateral drift for small
corrections.

The rider is airborne when no probe has found the snow for 2 ticks, or
when moving away from it faster than 1.5 m/s. Each tick the flight is
solved ahead to its landing (the trajectory against the course's height
field, 0.05 s steps): the landing point, the time to it and the ground's
normal there, for the camera, the landing assist and the grabs' release.

**Rotation**, about the rider's own axes, integrated as a quaternion:

| Input | Rate | Ramp |
|---|---|---|
| spin: stick X / Left, Right | up to 540°/s about the rider's up axis | to full in 0.15 s; back to 0 in 0.15 s after release (spins stop about 40° past the release: release early) |
| flip: stick Y / Up, Down | up to 420°/s about the rider's lateral axis (up: front flip, down: back flip) | the same |
| while grabbing | both rates x 0.85 | |

Spin and flip together give off-axis rotations naturally; the trick
detector names what was done (TRICKS.md, section 2).

| Jump | Air | What fits at full rate |
|---|---|---|
| a roller with an ollie | 0.7 s | a 180, a grab |
| the baby kicker | 1.0 s | a 360 |
| K1, K2 | 1.2 s | a 540 |
| K3, HK1 | 1.6 to 1.7 s | a 720, a flip |
| K5, HG | 2.0 to 2.2 s | a 900, a flip with a 360 |
| the mega-jump | 3.0 s | a 1080 with a flip and a grab, or a 1440 |

**Grabs.** A grab button pressed in the air blends its pose in over
0.12 s and holds it while the button is held; released, it blends out in
0.12 s. A grab is let go by itself 0.15 s before the solved landing, so
a held button never lands the rider in a grab pose.

## 6. Landing

The landing is judged the tick the probes find the snow again (or a
rail: section 7):

- **yaw error**: the angle between the board's long axis (either way:
  forward or switch) and the velocity along the ground;
- **tilt error**: the angle between the rider's up and the ground's
  normal;
- **impact**: the velocity's component into the ground.

| Quality | Yaw error | Tilt error | Then |
|---|---|---|---|
| perfect | ≤ 12° | ≤ 12° | the combo banked x 1.25; +2.5 m/s (up to the cap); a sparkle on the board, "PERFECT!" on the banner |
| clean | ≤ 30° | ≤ 25° | banked; speed x 0.97 |
| sketchy | ≤ 50° | ≤ 40° | banked x 0.5; speed x 0.7; a 0.5 s wobble pose |
| crash | beyond | beyond | the combo is lost (section 9) |

An impact above 9 m/s lowers the quality one step; above 13 m/s it is a
crash whatever the angles (the knuckle, a flat overshoot). The design
landings meet the flight at 3 to 6 m/s of impact (COURSE.md, section 4).
On landing, the velocity is projected onto the slope and onto the board's
axis: the sideways part is lost.

**The landing assist** (on by default, a setting): in the last 0.2 s
before the solved landing, a residual yaw within 25° of the nearest
half-turn is eased towards it at up to 60°/s, and a tilt within 20° of the
ground's normal likewise. It never changes the trick's name or score, only
the landing's chance. Off, the player lands what they rotated.

## 7. Grinds

Rails, logs and boxes are curves (COURSE.md, section 2), sampled every
0.25 m into `course_data.as` and found through a 4 m spatial hash.

**The catch**, checked every tick in the air or on the snow: the board
within 0.45 m sideways of the curve (0.6 m for boxes and logs), between
0.25 m below and 0.35 m above its top, not climbing faster than 0.5 m/s
(or on the snow with the crouch held, approaching its start), and its
velocity within 50° of the curve's direction (either way). Then the rider
locks on:

- the board on the curve's top; the speed the velocity along the curve,
  at least 4 m/s;
- the grind's kind from the board's yaw to the curve: within 30° a
  **50-50**, beyond 60° a **boardslide**, between, the nearer; on a log a
  **log slide** whatever the yaw;
- along it: `a = g (tangent · down) - μ g cos θ - k v²` with μ 0.06 boxes,
  0.08 rails, 0.12 logs.

**Balance.** A value b from -1 to 1, its rate pushed each tick by a seeded
random walk whose strength grows with the time on the rail (0.6 + 0.25 t),
an instability (1.2 b /s) and the stick (-2.2 x stick X /s). At |b| = 1 the
rider **bails**. The HUD's balance meter shows b (RIVE.md, section 5). The
grind assist halves the walk and the instability.

**Leaving.** At the curve's end, with its velocity and a 1.5 m/s pop
upwards (straight into the air: the combo goes on); with south / Space,
an ollie off (3.5 m/s along the up, spins and flips allowed); a bail
drops the rider off the side b fell to.

**A bail** loses the combo, plays a 0.6 s stumble on the snow and halves
the speed; there is no respawn.

## 8. Obstacles

The mover slides along whatever it meets. A contact with layer 2 or 4
faster than 6 m/s into it is a crash; slower, the rider glances off
(velocity along the surface kept, x 0.8). A rock surface met faster than
8 m/s is a crash.

## 9. Crashes, respawn and restart

**A crash** (a failed landing, an obstacle, a fall zone, a bail off a
cliff):

| Time | What |
|---|---|
| 0 | the combo is lost; the rider becomes a tumble body: a Box3D dynamic box (0.5 x 1.6 x 0.4 m, 75 kg) with 0.8 of the velocity and a spin from the impact, colliding with layers 1 and 2; the parts play `Flail` (two variants, seeded); snow bursts; the announcer: "OUCH!" or "WIPEOUT!" |
| 0 to 1.0 s | the `Crash` camera holds and watches the tumble |
| 1.0 s | a snow wipe (a white diagonal wipe in Rive, 0.15 s in, 0.15 s out; a cut with reduced motion) covers the reset |
| 1.15 s | the rider stands at the respawn point (COURSE.md, section 5: the first safe metre at or after the crash's progress, plus 5 m), facing down the line, at the larger of 8 m/s and half the speed before the crash |
| 1.25 s | control is back; the rider blinks (1-bit screen-door transparency) for 1.0 s and passes through obstacles meanwhile |

Under the brief's 1.5 s. The score keeps what was banked; only the combo
in progress is lost (and the crash is counted for the results).

**A restart** (Start or R, anywhere but the initials) resets in place,
with nothing reloaded: the rider at the start gate, the run's score,
combo, timer, counters and trick history cleared, the particles and the
board trail cleared, the sun back to the top's, the cameras snapped, the
music back to its run start (AUDIO.md, section 5); then the quick start
(1.0 s). The frame of the press to the first tick with control: at most
120 frames (2 s at 60 fps), budgeted at 60 (1.0 s): TESTS.md, case 5.

## 10. The autopilot

For the tests, the attract mode and the demo: a rider driven by a script
instead of a player, through the same input path (it writes the same
`Input` a frame that the keys and the pad do).

- **Steering**: pure pursuit of a point on the line 12 m ahead (6 m in
  the rail garden), on the high or the low line by choice.
- **Speed**: tucks where the next feature's design speed asks for it,
  carves wider where it is too fast.
- **Tricks**: a trick script, a list of (feature id, the trick to do:
  spin, flip, grab, grind), the inputs timed from the solved flight
  (release early enough to stop the rotation at a half-turn). The
  reference script (`world/scripts/reference_run.as`) scores 52,000 to
  62,000 on the high line (SPEC.md, section 14).
- **The new player**: a session that presses Space on the first roller
  and holds Right in the air: the first-10 s check.

## 11. The controller lab

`world/lab.rscn`: a test hill with one of each thing (a roller, three
kickers of the course's sizes, a flat rail, a kinked rail, a log, a box,
a wall of trees, a fall zone), the rider, the chase camera and a readout
of the state (speed, heading, slope, the probes' hits, the solved
landing, b) drawn in the HUD's debug layer. `hedra play world/lab.rscn`
plays it; recorded inputs (`lab.jsonl`) replay it with
`hedra play --input lab.jsonl --dump-frames shots/lab --capture 600`,
whose dumped states are the lab's golden (TESTS.md, case 3).

## 12. The animation

The rider is 15 rigid parts under joint nodes (LOOK.md, section 5). The
script sets the root's transform (the board's place and the rider's
rotation); the poses are timelines on the joints, played by the world's
state machine `Rider`, whose inputs the script writes directly
(`this.scene.stateMachine("Rider")`, as the platformer's controller
spec does):

| Layer | States | Driven by |
|---|---|---|
| Base | a 1D blend on the lean (-1 heel carve, 0 flat, +1 toe carve), mixed with `Tuck` and `Crouch` by their amounts | lean, tuck, crouch |
| Air | `AirNeutral`, `Indy`, `Melon`, `Method`, `Mute`, `FlipTuck` (knees in while flipping) | grab, flipping |
| Grind | a 1D blend on b (-1 to 1) | b |
| Land | `Absorb` (one-shot, by impact), `Wobble` (sketchy) | landed, quality |
| Crash | `FlailA`, `FlailB` | crash, a seeded choice |
| Finish | `Celebrate` (a fist pump, then the board raised) | finished |

Switch stance mirrors the poses (the joints' rotations mirrored by a
`Stance` input). The poses are data: `tools/make_poses.py` writes the
timelines from a table of joint angles per pose, so a pose is changed by
its numbers and rebuilt.

## 13. Files

| File | What |
|---|---|
| `world/scripts/run.as` | the driver: phases, the clock, the order of the ticks, the pins to the view model |
| `world/scripts/rider.as` | sections 2 to 6 and 8 |
| `world/scripts/grind.as` | section 7 |
| `world/scripts/tumble.as` | section 9's tumble body |
| `world/scripts/tricks.as` | the trick detector and the scoring (TRICKS.md) |
| `world/scripts/camera.as` | the cameras (SPEC.md, section 7) |
| `world/scripts/input.as` | keys, the pad (through the view model until E-PAD), the autopilot: one `Input` a frame |
| `world/scripts/autopilot.as`, `reference_run.as` | section 10 |
| `world/scripts/course_data.as` | generated (COURSE.md, section 10) |
| `world/scripts/lib/kinematic.as` | the kart's motion layer, copied with its tests |
| `world/scripts/*_test.as` | `rive --test` units: the slope's terminal speeds, the ollie heights, a kicker's flight, the landing table, the catch, the balance, the respawn rules |
