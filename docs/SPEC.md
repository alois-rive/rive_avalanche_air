# Avalanche Air: the specification

Avalanche Air is the [brief](BRIEF.md) built as a Rive project with a 3D
world, on Rive Hedra (`~/Documents/GitHub/rive_modeler`), the way Hedra's
samples are built ([the kart's spec](../../rive_modeler/samples/kart/docs/SPEC.md)
is the closest): a title, a HUD and a results screen made of Rive, a Hedra
project (`world/`) drawn by the hedra_engine library's `Scene3D`, one view
model shared between them, all baked into one `.riv`. It is not built yet;
these documents say what it will be.

| Document | What it fixes |
|---|---|
| [SPEC.md](SPEC.md) (this) | the experience, the run, controls, cameras, the features used, accessibility, engine gaps, done-when |
| [COURSE.md](COURSE.md) | Sunset Ridge: the mountain, its seven sections, every feature, how the course is generated |
| [RIDER.md](RIDER.md) | the board's physics and controller: carving, tuck, ollie, air, landing, grinds, crashes, respawn |
| [TRICKS.md](TRICKS.md) | the trick set, naming, scoring, combos, grades, the high score table |
| [LOOK.md](LOOK.md) | the PSX look of this game, with the `psx-style` skill: frame, palette, light, every surface, effects |
| [AUDIO.md](AUDIO.md) | all sound, synthesised by Rive's `AudioProcessor`: the SPU voice engine, the music, the board, the announcer, the UI |
| [RIVE.md](RIVE.md) | the Rive side: artboards, the view model, state machines, the HUD, the screens |
| [ASSETS.md](ASSETS.md) | every asset, its pipeline track, budgets and approvals |
| [PERF.md](PERF.md) | frame, memory, download and audio budgets per platform |
| [TESTS.md](TESTS.md) | determinism, sessions, goldens, the screenshot test |
| [PLAN.md](PLAN.md) | milestones A0 to A9, engine gaps scheduled |

The visual rules live in a project skill, [psx-style](../.claude/skills/psx-style/SKILL.md),
generic to any PSX-looking Hedra project: its shaders, frame template,
texture tools and gates are what LOOK.md applies.

## 1. The experience

**Who it is for.** Players who want one more run: a 90-second arcade score
attack, readable in ten seconds, loud and funny, with a high score to beat.
And developers deciding whether Hedra and Rive carry a complete, polished
game: physics in script, a stylised renderer, procedural audio, a Rive UI.

**What it shows.** A run down a mountain at golden hour that looks and
sounds like a 1998 PlayStation title: 320 x 240 hard pixels, dithered
15-bit colour, wobbling polygons and swimming textures, fog, chunky
riders; drum-and-bass at 170 BPM and an announcer who shouts every trick.
Underneath, modern: 60 frames a second, analogue input, deterministic
physics, reflections on a frozen lake, a glowing low sun, a thousand
snow sprites, instant restarts.

**The 30-second pitch.** The inflatable arch, the crowd, the announcer:
"THREE... TWO... ONE... GO!" Six seconds later you pop off the first
roller and spin a 360: "BACKSIDE THREE SIXTY! NICE!" The kickers throw you
higher, a 720 Indy, the music drops, a rail garden, a 50-50 into a
boardslide, the combo multiplier climbs to x5. Left fork for the high
line, between the pines, over the gondola station's roof. The sun sinks
as you descend; the final cliff gap launches you into a purple dusk for
three seconds of air: back flip, 1080, Melon, land it: "INSANE!" The
results tick up like a cash register, a chrome S slams onto the screen.
Press Start: you are at the top again in one second.

## 2. The run

| Phase | What happens | Lasts |
|---|---|---|
| title | the chrome 3D logo spins over an attract replay (the best recorded run, replayed from its inputs); "PRESS START" blinks; the music's filtered intro | until Start |
| countdown | the rider in the start gate; the grade targets on screen ("S RANK 50,000"); 3, 2, 1, GO with beeps and the announcer; the first run only | 3.0 s |
| quick start | after a restart: "READY... GO!" | 1.0 s |
| riding | the seven sections of [COURSE.md](COURSE.md); the HUD: score, combo multiplier, timer, trick banner | about 90 s |
| finish | the rider passes the finish arch; the camera swings round to face them, the crowd cheers | 2.0 s |
| results | the tally (tricks, best combo, air, grinds, perfect landings, time bonus), the total, the grade stamped; initials if the score enters the table | until Start or a choice |
| initials | three letters, entered with the stick or the keys | until confirmed |

**Instant restart** from anywhere but the initials entry: Start (pad) or R
(keyboard) during the run, the finish or the results puts the rider in the
start gate and runs the quick start: control is back within 1.0 s, under
the brief's 2 s, with no screen in between. The world is never reloaded:
the run's state is reset in place (RIDER.md, section 9).

**Pause** is Escape or the pad's Select/Back (Start is the restart, as the
brief asks): it stops the `Scene3D` (`playing` false) and shows Resume,
Restart, Volume (music, effects, voice), Controls (a picture of the
mapping) and Quit to title.

**Timer.** The run's clock starts at GO and stops at the finish arch. It
is shown, scored as a time bonus (TRICKS.md, section 7) and never ends the
run: a run cannot time out.

## 3. Controls

The brief's mapping, resolved where it was open (marked *).

| Action | Gamepad (W3C standard mapping) | Keyboard |
|---|---|---|
| Steer, carve | left stick X | A / D |
| Tuck (speed up) | left stick down (below -0.5) | S |
| Crouch, release to ollie | south (A), hold then release | Space |
| Grabs (in the air) | west (X) Indy, east (B) Melon, north (Y) Method, west + east together Mute * | J Indy, K Melon, L Method, J + K Mute * |
| Spins (in the air) | left stick X | Left / Right arrows |
| Flips (in the air) | left stick Y: up front flip, down back flip | Up / Down arrows |
| Grind balance | left stick X | A / D or Left / Right |
| Jump off a rail | south (A) | Space |
| Restart run | Start | R |
| Pause * | Select / Back | Escape |
| Menus | d-pad or left stick, south to confirm, east to go back | arrows, Enter, Escape |

\* **Grabs.** The brief gives grabs as "X / B / Y + direction" and spins
and flips to the same left stick in the air. A direction read at the
grab's press would also start a spin or a flip, so the fourth grab is a
chord instead (west + east, J + K), and every grab is one button: a
direction held while grabbing spins or flips the grab, which is the
combination the scoring wants (a "BACKSIDE 720 INDY"). The right stick is
left free; if testers miss directional grabs, a right-stick grab mode is
the alternative (PLAN.md, A2's open question).

\* **Pause.** Start is the restart (the brief), so pause moves to Select.

Analogue input: the stick's dead zone is 0.15 (radial), its response
squared beyond it for fine carving; keyboard steering eases from 0 to 1 in
0.12 s. Keyboard and pad work at once; the HUD's button glyphs follow the
last device used.

Input reaches the world as in the kart sample: keys through the `Scene3D`,
which holds focus during the run. **Gamepads do not reach node scripts in
Hedra today** (gap E-PAD, section 13): until the engine forwards them, a
2D Rive script on the run's artboard reads `gamepadEvent` and writes the
pad's state into the view model, which the world reads through its inbound
pins (RIVE.md, section 4).

## 4. The course

Sunset Ridge at the Neon Peak resort: 1,420 m of run, about 420 m of vertical,
seven sections (start gate, warm-up slope, kicker section, rail garden,
split path, final mega-jump, finish gate), the sun going down as you
descend; [COURSE.md](COURSE.md) has everything.

## 5. The rider

An arcade board model ticked at 120 Hz over box3d-as (the engine's copy of
Box3D, as the kart uses it): a character mover for contacts, rays for the
snow, a scripted ballistic flight, rails as curves, a scripted tumble for
crashes. Top speed 27 m/s (97 km/h) in a tuck; [RIDER.md](RIDER.md) has
every number.

**The figure.** A blocky snowboarder of 15 rigid parts (about 480
triangles), baggy jacket and trousers, goggles on a beanie, one 128 x 128
texture page; three colour schemes chosen on the title (left and right):
**Hot Pink** (jacket #f83890, trousers #283058), **Acid** (jacket #a8f830,
trousers #383838), **Blaze** (jacket #f88818, trousers #204878). The board
carries the Avalanche Air graphic.

## 6. Tricks and scoring

Spins 180 to 1440, front and back flips, four grabs, grinds on rails, logs
and boxes, combos multiplied by their trick count, landing quality, a
grade from C to S; [TRICKS.md](TRICKS.md) has everything.

## 7. Cameras

| Camera | Where | How |
|---|---|---|
| `Chase` | 4.2 m behind, 1.6 m above the rider, looking 3 m ahead of them | a critically damped spring (0.15 s) on the direction it looks from and its height, so it does not trail at speed; its field of view 66° vertical (4:3), widening to 74° in a full tuck; a ray (Box3D) from the rider to the camera pulls it in front of trees and walls |
| `Chase` in the air | 6 m behind, 2.5 m up | blends there over 0.3 s after take-off, and turns towards the predicted landing point (the flight solved ahead, RIDER.md, section 5) so the landing is seen before it comes |
| `Chase` on a rail | 3.5 m behind, 1.2 m up, 15° to the rail's outside | blends in 0.2 s |
| `Crash` | where the chase was at the crash | holds its place and looks at the tumbling rider until the respawn, then cuts back to the chase |
| `Cliff` | on the cliff's side at the mega-jump, 25 m from the line | at the take-off the view cuts to it for the climb of the flight, then back to an aerial chase 0.8 s before the landing (the player still controls the tricks; the HUD stays); off with reduced motion |
| `Finish` | 12 m past the arch, low | swings round to face the rider as they pass the arch |
| `Gate`, `Attract1` to `Attract6` | fixed and rail cameras along the course | the title's attract mode cuts between them (RIVE.md, section 8) |

The chase camera's field of view is vertical (`keep_aspect` 1, keep
height) so the 4:3 picture and the widescreen option show the same
height of slope.

## 8. Art direction

The brief's alpine resort at golden hour in PlayStation terms:

- **The frame**: 320 x 240, nearest-upscaled, pillarboxed to 4:3 (426 x 240
  as a widescreen option), 15-bit colour with the PlayStation's dither:
  the psx-style frame (LOOK.md, section 1).
- **Light**: one sun that sinks as the run descends (afternoon gold at the
  top, a purple dusk at the mega-jump), a hemisphere ambient, Gouraud
  vertex light, no real-time shadows, a blob shadow under the rider.
- **Palette**: snow whites and icy blues (#f8f8f8, #d8e0f8, #a8b8e0,
  #7888c0) against hot pink #f83890, acid green #a8f830 and orange
  #f88818; the fog white-blue (#c8d8f0) by day, purple (#7858a0) at dusk.
- **Setting**: pine forests of crossed quads, chalets, two chairlifts and
  a gondola, giant sponsor banners, inflatable arches at the start, the
  split and the finish, snow fences, flags, a frozen lake below the rail
  garden that reflects the sky.
- **Effects**: sprite snow spray from the board's edge, powder bursts on
  landings, speed lines when tucking, a flat-disc lens flare on the low
  sun, glowing neon on the finish arch.
- **The HUD and screens**: chrome, wide italic techno type with hard drop
  shadows and outlines, hot accents on black; trick names that slam in
  with a scale bounce.

[LOOK.md](LOOK.md) has every surface, colour and effect.

## 9. The engine features it shows

| Feature | Where | Why it matters |
|---|---|---|
| Custom shaders (WGSL) | every surface: the psx-style set (vertex snap, affine UVs, Gouraud, nearest) | a complete stylised renderer on Hedra's shader composer |
| SubViewport and ViewportTexture | the 320 x 240 frame and its present pass | a post-process made from engine parts |
| Environment: depth fog, glow, SSR | the fog wall, the glowing sun and neon, the frozen lake | modern effects drawn inside the old frame |
| CPU particles | snow spray, powder bursts, speed lines, confetti at the finish | many short emitters, flipbook sprites |
| box3d-as | the rider's mover, the snow's rays, the obstacles, the tumble's body | deterministic arcade physics, bit for bit native and web |
| Paths (`Curve3D`, `Path3D`) | the course's line (progress, respawn, the autopilot), every rail, the attract cameras' rails | the course and its rails are curves; the AI and the rules read them |
| State machines and timelines in 3D | the rider's poses and grabs, the gates, the arches, the cameras | the rider's animation is data, not code |
| Data binding and outputs | score, combo, timer, trick names, the rider's screen position for the pop-ups | the HUD is Rive's, the numbers the world's |
| Rive `AudioProcessor` (`rive/audio`) | every sound: music, board, voice, UI, synthesised on the audio thread | procedural audio, deterministic, rendered offline for tests (`--render-audio`) |
| Rive UI (RML, view models, state machines) | title, HUD, pop-ups, results, initials, pause | a game's whole 2D in Rive |

## 10. Rive

The Rive file holds the main artboard (a `Solo` of the screens), the
title, the run (the `Scene3D` and the HUD over it), the results, the
initials entry, the pause overlay and components (the trick banner, the
praise word, the combo meter, the balance meter, the grade stamp, a score
row), all bound to one view model, `Game`, shared with the world.
[RIVE.md](RIVE.md) has the artboards, the view model and the machines.

## 11. Audio

Every sound is synthesised at run time by Rive's `AudioProcessor` (Rive's
procedural audio engine, `rive/audio`): one processor, `Spu`, renders a
24-voice PlayStation-style sound chip (lo-fi voices at 11 to 22 kHz, the
SPU's reverb), a sequencer playing the 170 BPM drum-and-bass track, the
board's carving, wind, landings and rail scrapes as continuous synthesis
driven by the rider's state, the announcer as a formant voice synthesiser,
and the UI's blips and the results' cash register. No sound file ships
except, as a fallback, the announcer's voice bank (AUDIO.md, section 7).
[AUDIO.md](AUDIO.md) has everything.

A processor plays in real time natively and, on the web, only in a build
with threads (served cross-origin isolated); a threadless web page plays a
degraded tier rendered by the same code offline (AUDIO.md, section 10).

## 12. Accessibility

| Need | What the game does |
|---|---|
| reduced motion | a setting (on by default when the host says so): no camera shake, no field-of-view change in a tuck, no cliff camera cut, no screen flash on perfect landings, pop-ups fade instead of slamming |
| photosensitivity | no full-screen flash; the perfect-landing flash is a 120 ms border at 30 % |
| contrast | the HUD's numbers white with a 1-pixel black outline and a hard shadow on a dark plate; a high-contrast option thickens the outlines and darkens the plates |
| hearing | captions for the announcer (the trick line and praise word are already on screen as the banner; "OUCH!", the countdown and the grade get their own caption line); every sound cue has a visual one |
| input | keyboard alone or pad alone completes every screen; no input must be held longer than 1 s; the grind balance has an assist (the drift slowed by half) |
| difficulty | a landing assist (on by default) and the grind assist; neither changes the score |
| volume | music, effects and voice volumes, and a mute |

## 13. Engine and library gaps

What the game needs that Hedra or Rive does not do today, each with the
way the plan works round it. PLAN.md schedules them.

| Gap | What | Priority | Without it |
|---|---|---|---|
| E-PAD | gamepad events reaching node scripts (the `Scene3D` forwarding Rive's `GamepadEvent`; `InputKind` gamepad kinds); the kart's K-PAD | must (the brief is gamepad-first) | a 2D Rive script reads `gamepadEvent` and writes the pad into the view model, the world reads it through inbound pins (one frame of latency) |
| E-STORE | persistent storage for scripts (the local high score table) | should | the table kept for the session; on the web, the page's script keeps it in `localStorage` through the web runtime's view model API (the horror sample's pattern) |
| E-VM | node scripts reading and writing the view model (`this.scene.viewModel()`); the kart's K-VM | nice | hidden pin nodes bound to the view model (RIVE.md, section 4) |
| E-LIST | scene bindings writing into a Rive list | nice | fixed slots (`hs1` to `hs10`) |
| E-NEAREST | `scalingMode: "nearest"` on the Scene3D (the 3D picture shown with hard pixels when smaller than the layout) | should | the psx-style SubViewport rig |
| E-POST | a post-process stage (a screen shader) | nice | the present quad |
| E-VPTEX | a ViewportTexture named only by a ShaderMaterial parameter samples black | should (small fix) | the anchor quad in the frame rig |
| E-VCOLOR | mesh vertex colours reaching the renderer | nice | tints per material, light in the textures |
| E-AUDIOWEB | `AudioProcessor` on a threadless web page (Rive) | should | a threaded web build served cross-origin isolated, or the degraded tier (AUDIO.md, section 10) |
| E-FLIP | particle flipbooks and age in shaders | nice | the age carried in `COLOR.a` (psx-style's `psx_sprite`) |
| E-MULTI | a `MultiMesh` whose instance transforms a script writes (today its buffers are immutable) | nice | the board trail as 24 `MeshInstance3D`s moved by script (PERF.md, section 5) |
| E-DRAW | debug drawing of the Box3D world in Play; the kart's K-DRAW | should | printed states, `--shapes` |

## 14. Done when

Measurable, each checked by TESTS.md or PERF.md:

1. `hedra build .` then `rive . --unsigned-riv` bake with no error, twice
   to the same bytes.
2. The autopilot run (seed 1, the high line, the reference trick script)
   finishes in 85 to 95 s of run time with a score between 52,000 and
   62,000, and the view model's sequence equals its golden every 30 frames.
3. A scripted new-player session (keyboard: hold nothing, press Space on
   the first roller, hold Right) lands a trick in the first 10 s of the
   run (the brief's first success criterion).
4. Restart from a crash, from the finish and from the results gives
   control back within 2 s of the press (measured: frames from the key to
   the rider's first tick with input, at most 120).
5. `psx_audit.py frame` passes on the eight reference screenshots (gate,
   warm-up, kicker air, rail garden, high line, mega-jump, finish,
   results), and each equals its golden within the demo's tolerance.
6. `rive . --render-audio` of the reference session equals its golden
   within -60 dB of difference energy, and its loudness is -16 LUFS ±2.
7. The same seed and session give the same view model sequence natively
   with script threads, natively with one (`--job-threads=1`) and on the
   web runtime.
8. PERF.md's budgets hold on its platforms; the heap is flat between a
   1-run and a 10-run session (`soak_runs`).
9. Keyboard alone, and once E-PAD exists `--gamepad` alone, start a run,
   finish it, enter initials and restart.
10. A blind check: five people shown the gate and kicker screenshots
    without context say "PlayStation" or "PS1" unprompted (the brief's
    fourth criterion; recorded in TESTS.md's playtest log), and testers
    play three runs or more in a row (the third), at least 4 of 5.

## 15. Demo mode

The website-style hero loop the Hedra samples share (the shared rules are
`rive_modeler/docs/plans/SHOWCASE.md`'s, "Demo mode"): `Game/demo` true
(`--data=data/demo=true`) plays a 30 s loop with no UI, no input and no
sound: the kicker section and the rail garden ridden by the reference
run's recording (its inputs replayed from the same seed, so the loop is
exact), seen by the attract cameras, its last frame equal to its first
(the recording's 30 s cut at two matching moments in the air, the snow
emitters restarted at the cut). RIVE.md, section 8 has the shots.
