# Sunset Ridge: the course

One run down the Neon Peak resort's Sunset Ridge: 1,420 m along the line,
about 420 m of vertical, seven sections, about 90 s for a good rider. The
sun is high-gold at the top and sets as the run descends: the mega-jump is
taken against a purple dusk. Everything here is made by one generator from
one table, so the course is changed by its numbers.

## 1. The line and its sections

The course's spine is **the line**, a `Curve3D` (`Course/Line`) down the
fall line of the run: the progress of the rider, the respawn points, the
autopilot, the section boundaries, the sun's schedule and every feature's
place are measured along it, as `s` metres from the start gate. The split
path is two lines from s = 900 to their merge, `Line` (the low line)
and `HighLine`, each with its own `s` mapped back to the main line's at
both ends (section 6).

| # | Section | s (m) | Length | Mean slope | Piste width | Speed in → out (m/s) | Target time | What it teaches |
|---|---|---|---|---|---|---|---|---|
| 1 | Start gate | 0 – 40 | 40 | 6°, then a 20° start ramp from s = 15 | 12 | 0 → 10 | 4 s | push off, steer |
| 2 | Warm-up slope | 40 – 330 | 290 | 14° | 30 | 10 → 17 | 21 s | ollies, small spins, landing |
| 3 | Kicker section | 330 – 640 | 310 | 17° (tables flatter) | 34 | 17 → 19 | 18 s | big air, grabs, flips |
| 4 | Rail garden | 640 – 900 | 260 | 11° | 40 | 18 → 15 | 17 s | grinds, combos through grinds |
| 5 | Split path | 900 – 1,240 | high 360, low 340 | high 21° in steps, low 15° | high 9 – 12, low 28 | 15 → 22 | 20 s | risk against reward |
| 6 | Final mega-jump | 1,240 – 1,375 | 135 | in-run 26°, then the gap | 20 | 22 → 25 at the lip | 7 s (3 s of air) | one last combo |
| 7 | Finish gate | 1,375 – 1,420 | 45, then 60 m of run-out | 8°, then flat | 30 | 24 → stop | 3 s to the arch at s = 1,400 | the cheer |

Target times are for the reference rider (the autopilot of RIDER.md,
section 10, on the high line, doing the reference tricks); the generator's
`--check` rides the course with it and fails when a section's time is off
by more than 15 % or the whole run is outside 85 to 95 s (TESTS.md, case 2).

## 2. The features

Every feature is a row of the generator's table (`world/course/course.py`),
placed at `s` with a lateral offset `x` from the line (metres, + to the
right going down). Kickers are shaped by the generator to the flight their
design speed gives (section 4): a landing that meets the flight tangent at
the design speed, a knuckle before it and a run-out after.

### Section 2: the warm-up slope

| Id | Feature | s | x | Size | Notes |
|---|---|---|---|---|---|
| R1 | roller | 55 | 0 | 1.0 m high, 14 m long | the first trick: reached about 5 s after GO at about 11 m/s; an ollie off its crest gives 0.7 s of air, enough for a 180 or a grab |
| R2 | roller | 85 | -4 | 1.0 m | |
| R3 | roller | 120 | +5 | 1.2 m | |
| R4 | roller | 160 | 0 | 1.2 m | |
| R5 | roller | 205 | -6 | 1.4 m | a 360 with an ollie |
| R6 | roller | 250 | +4 | 1.4 m | |
| BK | baby kicker | 295 | 0 | lip 1.2 m at 20°, table 6 m, landing 24° | design speed 15 m/s, air 1.0 s: the first jump |

Snow fences (orange, #f88818) line both edges; the first sponsor banner
spans the piste at s = 140.

### Section 3: the kicker section

| Id | Feature | s | x | Lip | Table | Landing | Design speed | Air |
|---|---|---|---|---|---|---|---|---|
| K1 | kicker | 360 | 0 | 1.8 m, 24° | 8 m | 27° | 16 m/s | 1.2 s |
| K2 | kicker | 420 | -6 | 1.8 m, 24° | 8 m | 27° | 17 m/s | 1.2 s |
| K3 | kicker | 490 | 0 | 2.6 m, 27° | 14 m | 30° | 18 m/s | 1.7 s |
| K4 | hip jump | 555 | +5 | 2.0 m, 22°, kicking 30° to the right | 10 m | 28°, angled right | 17 m/s | 1.4 s |
| K5 | kicker | 615 | 0 | 3.0 m, 29° | 18 m | 31° | 19 m/s | 2.0 s |

Banners on the knuckles of K3 and K5; a chairlift (Lift 1) runs up the
left side of sections 2 and 3, its chairs moving (a timeline), its cable a
line of quads; spectators (crossed-quad crowd sprites) at K5.

### Section 4: the rail garden

Three lanes, left (x = -12), centre (0) and right (+12), each a sequence
of features close enough that a good rider chains them (a combo kept
through grinds, TRICKS.md, section 5).

| Id | Feature | s | Lane | Length | Shape | Notes |
|---|---|---|---|---|---|---|
| FB1 | flat box | 660 | left | 8 m | flat, 0.5 m high | the easy entry: wide (0.6 m), forgiving |
| LG1 | log slide | 700 | left | 10 m | flat, 0.6 m | a pine log, bark bumps (sound, a little wobble) |
| DR1 | down rail | 760 | left | 12 m | -15° | |
| KR1 | kinked rail | 670 | centre | 4 + 6 + 4 m | flat, down 20°, flat | x1.5 grind value |
| RR1 | rainbow rail | 730 | centre | 10 m | an arc 1.2 m high | |
| FD1 | flat-down box | 800 | centre | 10 m | 4 m flat, 6 m at -18° | |
| LR1 | long rail | 850 | centre | 16 m | flat | the combo-keeper before the split |
| LG2 | log slide | 665 | right | 12 m | flat | |
| FR1 | flat rail | 720 | right | 10 m | flat | |
| DB1 | down box | 790 | right | 12 m | -15° | |

Each rail is a `Path3D` (its `Curve3D`, the grind's path, RIDER.md,
section 7) with its mesh (rails: a 6-sided tube in `psx_chrome`; boxes:
painted boxes; logs: an 8-sided log in bark), and approach ramps of
packed snow where the feature is higher than 0.4 m. Below the garden, to
the left, the frozen lake (60 x 40 m, reflective: LOOK.md, section 6);
Lift 2 crosses over the garden, its cable 12 m up.

### Section 5: the split path

An inflatable arch at s = 890 reads HIGH LINE ← and LOW LINE → (arrows
in the texture). The lines part at s = 900 and merge at s = 1,240.

**The high line** (left; narrow, between pines; more air, more points,
more ways to crash):

| Id | Feature | s (high) | Notes |
|---|---|---|---|
| HD1 | drop | 945 | a 4 m step down off a rock band: air with no ollie |
| HK1 | kicker | 995 | lip 2.5 m, 27°, design 19 m/s, air 1.6 s |
| HG | the gondola station gap | 1,060 | a kicker (lip 3.0 m, 28°) over the gondola station's roof: a 20 m gap, design 21 m/s, air 2.2 s; too slow lands on the roof (rideable, a flat landing) |
| HR1 | handrail | 1,110 | 14 m down the station's stairs, -25° |
| HD2 | drop | 1,165 | a 6 m cliff into a steep landing |
| HK2 | kicker | 1,210 | lip 2.2 m, 25°, design 20 m/s, air 1.4 s |

Trees within 6 m of the high line's edge: the tightest steering of the
run. Missing the line off a drop ends in a fall zone (section 5).

**The low line** (right; wide groomed; safer, fewer points):

| Id | Feature | s (low) | Notes |
|---|---|---|---|
| LR1 – LR4 | rollers | 930, 965, 1,000, 1,040 | 1.2 m |
| LB1 | box | 1,080 | 10 m flat |
| LK1 | kicker | 1,120 | lip 1.8 m, design 17 m/s, air 1.2 s |
| LK2 | kicker | 1,180 | lip 2.2 m, design 19 m/s, air 1.4 s |

The reference rider scores about 40 % more on the high line (TRICKS.md,
section 9) and takes about the same time.

### Section 6: the final mega-jump

| Part | Numbers |
|---|---|
| in-run | s = 1,240 to the lip at s = 1,330: 26°, 20 m wide, banners both sides, a neon arch over the lip ("AVALANCHE AIR", glowing) |
| lip | 3.5 m high, 30°; design speed 24 m/s (the in-run brings the reference rider there in a tuck; a rider who carves loses up to 3 m/s and still clears) |
| gap | over the ridge's cliff: a 45 m gap, the landing 24 m below the lip |
| landing | shaped by the generator to meet the flight from 21 to 26 m/s, 32° at the sweet spot |
| air | 3.0 s ± 0.2 at the design speed: a 1080 with a flip and a grab, or a 1440 |

The music's riser starts at s = 1,240 and the drop lands with the landing
(AUDIO.md, section 5). The `Cliff` camera stands on the ridge's side
(SPEC.md, section 7).

### Section 7: the finish

The finish arch (inflatable, neon, the brief's "inflatable arches") at
s = 1,400, a crowd behind fences, a lodge, confetti cannons fired when the
rider passes (particles), the run-out flat for 60 m to a stop.

## 3. The ground

- **Terrain**: a height field over the whole run, 120 m wide around the
  line (more at the split), from a profile along the line (the slopes of
  section 1) plus the features' shapes and gentle noise (1 to 3 m, seeded)
  off the piste. Rendered as tiles 40 m long, triangles of 1.5 m within
  the piste and its edges (the affine warp: psx-style models.md), 6 m
  outside, 20 m on the far mountainsides; collided with as a Box3D height
  field (`b3CreateHeightField`), 0.75 m cells within the piste.
- **Surfaces**: each triangle of the collision is tagged groomed piste
  (μ 0.035), powder off-piste (μ 0.09, deeper: the rider sinks 0.15 m and
  turns slower), ice (the lake, μ 0.015, little grip), rock (a crash above
  8 m/s). The render uses the matching texture (LOOK.md, section 4).
- **Edges**: off the piste is rideable powder up to the trees and the
  fall zones; it is slow, so leaving the line is its own penalty.
- **Fall zones**: Box3D sensors under every cliff and beyond the course's
  outer edges; entering one is a crash with respawn (RIDER.md, section 9).

## 4. Shaping a jump

A kicker's numbers are its lip (height, angle), its table (the flat top
between lip and knuckle) and its design speed. The generator flies the
rider's ballistic path from the lip at the design speed with the game's
air gravity (13 m/s², RIDER.md, section 5) and shapes the landing:

1. the knuckle at the table's end, rounded over 2 m;
2. the landing slope tangent to the flight at the sweet spot, the point
   the design speed lands on, its angle the flight's there (within the
   section's maximum, 34°);
3. a landing long enough to meet the flight from the design speed - 3 m/s
   to + 3 m/s (shorter lands on the knuckle: a hard, flatter landing;
   longer lands in the run-out's transition);
4. a run-out back to the section's slope.

So the design speed lands sweetly; too slow lands on the table or the
knuckle (flatter, the landing quality suffers: RIDER.md, section 6), too
fast overshoots into the flat (a hard landing, a crash beyond 9 m/s into
the slope's normal).

## 5. Respawn points

The line is sampled every metre into `course_data.as`: position, tangent,
the piste's width, the section, the surface, and whether that metre is a
**safe respawn** (on the snow, not on a feature, not in the air of a jump,
not within 8 m before a lip). A crash respawns at the first safe metre at
or after the crash's progress, plus 5 m, facing down the line
(RIDER.md, section 9). On the split, the respawn stays on the line the
rider was on.

## 6. Progress

The rider's progress is the nearest line sample, searched in a window of
±30 samples around the last one (the kart's method: its TRACK.md,
section 5), on the line the rider is on. On the split, each line's `s` is
mapped to the main line's by its share of the way between the split
(s = 900) and the merge (s = 1,240), so the HUD's progress and the
section's music cues stay continuous. The finish is the arch's sensor;
the run cannot be finished any other way.

## 7. The sun's schedule

The time of day follows the progress (not the clock), so every run's
mega-jump is at dusk. The generator writes the keyframes; `run.as` writes
the interpolated values into every PSX material, the sky and the
Environment each frame (LOOK.md, section 3).

| s | Sun elevation | Sun colour | Sky zenith | Horizon and fog | Sky ambient | Snow bounce |
|---|---|---|---|---|---|---|
| 0 | 28° | #f8e0a8 | #4870c8 | #c8d8f0 | #8898c8 | #b0b8d0 |
| 640 | 18° | #f8c880 | #4060b8 | #d8d0e8 | #8890c0 | #b8b0c8 |
| 1,000 | 10° | #f8a060 | #384898 | #e0b8c8 | #8878b0 | #b0a0b8 |
| 1,330 | 3° | #f87850 | #282868 | #7858a0 | #605890 | #8878a0 |
| 1,420 | 1° | #e86048 | #202058 | #6850a0 | #585088 | #807098 |

The sun's azimuth stays ahead-left of the descent (about 35° left of the
fall line), so it is in view on the kickers (the lens flare) and behind
the arch at the mega-jump.

## 8. Dressing

| What | Where | Count | How |
|---|---|---|---|
| Pines (crossed quads, 3 sizes, 2 snow variants) | Poisson-disc scattered outside the piste's edges, denser on the high line; none within 2 m of a fall zone's edge | about 900 | two `MultiMesh` of `QuadMesh` (one per plane of the cross), `psx_cutout`, yaw and scale per instance |
| Pines near the line (cone stacks) | within 6 m of the high line | about 60 | one model, instanced |
| Chalets | the start (3), the finish (2, with the lodge) | 5 | models (ASSETS.md) |
| Lift 1 (chairlift) | up the left of sections 2 and 3 | 9 pylons, 40 chairs | pylons a model, chairs a `MultiMesh`, moved by a timeline |
| Lift 2 (chairlift) | across the rail garden | 4 pylons, 16 chairs | the same |
| Gondola | over the high line, the station at HG | 3 pylons, 6 cabins | models |
| Sponsor banners | spanning the piste at s = 140, 490, 615, 1,300; on posts along the edges | 4 spans, 14 posts | quads in `psx_surface`, 256-colour textures |
| Inflatable arches | start, split, finish | 3 | one model, three textures |
| Snow fences, flags, start hut, crowd fences, crowd sprites | along the edges, the start and the finish | | instanced quads and models |
| Mountains | the far horizon | 1 | the sky's horizon strip (psx_sky) and 3 far ridges of low-poly terrain |

## 9. Collision layers (Box3D filters, and Hedra's layers for the tools)

| Bit | Layer | What |
|---|---|---|
| 1 | ground | the terrain's height field, the features' surfaces (kickers, tables, roofs) |
| 2 | obstacles | tree trunks within 25 m of a line (capsules), chalets, pylons, posts, the station |
| 4 | rails | each rail's and box's body (for side hits; the grind itself follows the curve) |
| 8 | sensors | fall zones, the finish, section boundaries, music cues |
| 16 | rider | the rider's mover and its kinematic proxy |
| 32 | camera | what the chase camera's ray stops at (obstacles and steep ground) |

## 10. The generator

`world/course/make_course.py` reads `course.py` (the table above, in
Python) and writes:

- `world/course/course.rscn`: the terrain tiles (`.rmdlcmd` data meshes,
  UVs one unit a metre), the features (their meshes, materials and
  `Path3D`s), the dressing, the sensors' `Area3D`s for the tools, the
  `Line` and `HighLine` curves;
- `world/scripts/course_data.as`: the line's samples, the rails' polylines
  (every 0.25 m), the kickers' table, the sun's keyframes, the respawn
  flags, the collision data (the height field's samples, the obstacles'
  shapes, the features' meshes) for the Box3D world;
- `shots/course_map.png`: the course from above with every feature
  labelled, for review;
- `--check`: everything above unchanged, every collision triangle within
  2 cm of its render triangle, every kicker's landing meeting its flight,
  and the autopilot ride's times (section 1).

The same table and seed give the same bytes.
