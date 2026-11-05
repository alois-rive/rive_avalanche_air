# The plan

Ten milestones, A0 to A9, each leaving something that plays or can be
looked at, each ending in checks that are commands (TESTS.md) and, where
assets or sound are delivered, the person's approval. Efforts are working
days of one agent with the Hedra and Rive tools, tests and documents
included. The toolchain is the Hedra repository's pin (`rive_modeler/tools/pins.env`:
rive `dev-8d3a7cc3`, which box3d-as needs); the project's `rive.yaml`
follows the kart's (`scripting: wasm`, `wasmRuntime: frame`,
`wasmMaxPages: 65536`, the shader outputs, `exclude:` for the build, the
assets, the tools and `world/psx`).

| # | Milestone | Leaves | Depends on | Effort |
|---|---|---|---|---|
| A0 | The look lab and the concepts | the project skeleton; the PSX frame in it, checked; every asset's draft and PSX concept, gated; fonts chosen | `hedra`, the pinned rive, the image generator, a person (sitting 1) | 5 d |
| A1 | A rider on a slope | the controller lab: carving, tuck, ollie, air, landing, crashes, respawn, the chase camera, on keyboard and (through the workaround) pad | A0's skeleton | 7 d |
| A2 | Tricks and grinds | the trick detector, scoring, combos, grinds and balance, the poses and the `Rider` machine, the autopilot's trick script | A1 | 6 d |
| A3 | The course | Sunset Ridge generated: terrain, features, shaped kickers, rails, the split, the mega-jump, fall zones, respawn, the sun's schedule; the reference run timed and the scores calibrated | A2 | 8 d |
| A4 | The Rive shell | the title, the countdown, the HUD, pop-ups, the results' tally, grades, initials, the table, pause, restart, the wipe, captions, the grid layout | A3 | 7 d |
| A5 | Audio | the `Spu` processor: voices, the board, the music, the announcer and its gate, UI, the degraded tier, the render goldens | A4 (the phases and events exist); a person (sitting 4) | 9 d |
| A6 | The look, finished | every final asset, the dressing, the effects, the lake's reflections, the glow, the reference shots | A0's approved concepts; a person (sittings 2, 3) | 12 d |
| A7 | Every input and accessibility | the pad through the engine (E-PAD) or the workaround hardened, assists, reduced motion, contrast, captions, volumes, semantics | A4; E-PAD for the engine path | 3 d |
| A8 | Performance and the web | the budgets held, the bench, the threaded web build served cross-origin isolated, the threadless build with the degraded audio, the high score's storage | A6, A5; E-STORE for storage | 4 d |
| A9 | Attract, demo mode, ghost, playtests | the title's attract, the demo loop, the ghost, the playtests and the grade thresholds tuned | A8 | 5 d |

## Engine work this game asks for

The gaps are SPEC.md's, section 13 (psx-style's SKILL.md has the
rendering ones in detail). None blocks A0 to A6; E-PAD is wanted by A1
(gamepad-first) and has a workaround.

| Gap | What | Shared with | Effort (engine) | Unblocks |
|---|---|---|---|---|
| E-PAD | `Scene3D` forwards `GamepadEvent` to node scripts; `InputKind` gamepad kinds; `--gamepad` for tests | the kart (K-PAD), the platformer, every sample | 2 | the pad without a frame of latency; case 11 with `--gamepad` |
| E-VPTEX | a ViewportTexture named by a ShaderMaterial parameter makes its viewport's colour target | every SubViewport shader | 0.5 | removes the anchor quad |
| E-NEAREST | `scalingMode: "nearest"` on the Scene3D: present with the nearest sampler when the picture is smaller than the layout (`renderer.as`, `redraw`) | any pixel-art 3D | 1 | the frame without a SubViewport |
| E-POST | a post-process stage (a screen shader on the main view) | | 3 to 5 | the present pass in the engine |
| E-STORE | persistent storage for scripts (`rive/storage`, the weather sample's proposal) | weather, horror, mirror-puzzle | Rive's (3 for a host bridge) | the high score table across sessions |
| E-VM | node scripts reading and writing the view model | the kart (K-VM), every sample | 3 | removes the pins and the string scripts |
| E-LIST | scene bindings writing into a Rive list | the kart's results | 2 | the table as a list |
| E-AUDIOWEB | `AudioProcessor` on a threadless web page | every procedural audio | Rive's | removes the degraded tier |
| E-MULTI | script-written `MultiMesh` transforms | tower-defense, dataviz, mirror-puzzle | 3 | the board trail at 96 segments |
| E-VCOLOR | mesh vertex colours to the renderer | | 2 | baked vertex light |
| E-FLIP | particle flipbooks, particle age in shaders | | 2 | removes the `COLOR.a` age trick |
| E-DRAW | debug drawing of the Box3D world in Play | the kart (K-DRAW) | 3 | the lab's failures seen |

## A0. The look lab and the concepts (5 days)

**Scope.** The Rive project's skeleton: `rive.yaml`, `world/hedra.yaml`
(`export/embed_sources: false`, `rendering/anti_aliasing/quality/msaa_3d:
disabled`), `make_rml.py` with an empty `Main`, the
Scene3D, `hedra build`, the psx-style shaders copied into `world/psx/`.
The look lab: `world/lab_look.rscn`, the frame rig over a test slope with
a pine stand, a chalet blockout, a rail, a kicker, the frozen lake, the
sky; three questions answered there with pictures: SSR inside the
SubViewport on the lake's lit variant; a key on a material shared by many
meshes (the `Daylight` plan, LOOK.md, section 3); the HUD's grid scaling
over the frame. Then every asset's draft and PSX concept (ASSETS.md), the
three index sheets, the fonts chosen.

**Deliverables.** The skeleton baking; `lab_look.rscn` and its pictures;
every asset's draft and concept with their gates; the index sheets.

**Done when.** `rive . --unsigned-riv` bakes; `psx_audit.py frame` passes
on the lab's pictures; the three questions answered in this document's
"As built"; `asset.py status` shows every asset's concept awaiting
approval; sitting 1 held, its words recorded.

## A1. A rider on a slope (7 days)

**Scope.** `lib/kinematic.as` copied from the kart with its tests; the
controller lab (RIDER.md, section 11); the rider (RIDER.md, sections 1 to
6, 8, 9) on the lab's hill, in the blockout rider until its final is
approved (sitting 2, its final built here as the first of the 3D
finals); the chase camera with its air and rail offsets; the crash
camera; `input.as` with the keys and the pad workaround (`ui/pad.as`,
RIVE.md, section 4).

**Done when.** Case 3's golden recorded and passing; the units for
speeds, ollies, flights, the landing table and the respawn pass; the
person rides the lab with a pad and a keyboard and says the carving and
the air feel right (their words recorded).

## A2. Tricks and grinds (6 days)

**Scope.** `tricks.as` (TRICKS.md, sections 1 to 7), `grind.as` (RIDER.md,
section 7), the poses table and `tools/make_poses.py`, the `Rider` state
machine, the autopilot and the trick script on the lab, the debug HUD's
trick readout.

**Open question.** Grabs as one button each with a chord for the fourth
(SPEC.md, section 3), or a right-stick grab mode: decided with the person
after riding the lab.

**Done when.** The trick detector's units (counting, naming both stances,
values, decay, combos) pass; the lab's autopilot does every trick of
TRICKS.md, section 1, and its trace is a golden.

## A3. The course (8 days)

**Scope.** `make_course.py` and `course.py` (COURSE.md): the terrain and
its collision, every feature, the kickers shaped to their flights, the
rails, the split and its two lines, the mega-jump, the fall zones and
respawn flags, the sun's keyframes and the `Daylight` timeline, the
dressing with placeholder models where finals are not yet approved; the
reference trick script for the whole run; the score values calibrated
until the reference run holds TRICKS.md's budget.

**Done when.** Cases 2 (its golden recorded), 6 and 8 pass; the course
map is reviewed by the person.

## A4. The Rive shell (7 days)

**Scope.** RIVE.md whole: the overlays, the view model, the pins and the
string scripts, the HUD, the countdown and quick start, the trick
banner's slams, the results' tally, grades, initials and the table
(session storage), pause, restart, the wipe, captions, the grid layout.

**Done when.** Cases 5, 11 (keyboard), 16 pass; screenshots of every
screen at 1280 x 960 and 1920 x 1080 reviewed.

## A5. Audio (9 days)

**Scope.** AUDIO.md whole. First step: confirm a world script can start a
processor (else `sound.as` moves to the 2D side, AUDIO.md, section 1).
Then the voices and the SPU chain, the board's layers, the sequencer and
"Ice Breaker", the announcer (formant voice, lexicon, scheduler), its
intelligibility gate (and the voice bank if it fails), the UI and the
crowd, the degraded tier's bank render, the unit renders and the session
golden.

**Done when.** Case 9 passes; the processor's block time under its
budget with `--release`; the announcer's gate passed (or the voice bank
in, approved); sitting 4 held.

## A6. The look, finished (12 days)

**Scope.** Every final asset through the pipeline with psx-style's
overrides (ASSETS.md), synced into the world; the textures; the dressing;
the effects (LOOK.md, section 6); the lake's reflections, the glow, the
fog volume; the eight reference shots.

**Done when.** Cases 7 (goldens recorded after sitting 3) and 17 pass;
PERF.md's counts hold at the eight views; sitting 3 held.

## A7. Every input and accessibility (3 days)

**Scope.** The pad through the engine if E-PAD has landed (else the
workaround measured and its latency recorded), the assists, reduced
motion, high contrast, captions, the three volumes, semantics.

**Done when.** Cases 11 (with `--gamepad` if E-PAD) and 12 pass.

## A8. Performance and the web (4 days)

**Scope.** The budgets (PERF.md) measured and held; the threaded web
build (`--publish=web` or the website's runtime build with threads),
served with COOP and COEP; the threadless build with the degraded audio;
the high score table kept (E-STORE, or the page's `localStorage` bridge).

**Done when.** Cases 10, 13, 14 pass; the web builds play a full run at
60 fps on the reference laptop.

## A9. Attract, demo mode, ghost, playtests (5 days)

**Scope.** The title's attract mode and its cameras; the demo loop
(RIVE.md, section 8); the ghost (TRICKS.md, section 11); the playtests
(TESTS.md, section 8) and the A and B thresholds set from them.

**Done when.** Case 15 passes; the playtest log shows the brief's four
success criteria met, or the changes they asked for are planned.

## Order and total

A0 → A1 → A2 → A3 → A4 → A5, with A6's finals built from A1 onwards as
concepts are approved (sitting 2 for the rider at A1); then A7, A8, A9.
**66 days** of agent work, plus the person's four sittings and the
playtests. The engine gaps run beside it; E-PAD and E-VPTEX first (small,
and they remove workarounds on the critical path).

## Decisions taken in these documents, to confirm

| Decision | Where | Alternative |
|---|---|---|
| Grabs: one button each, the fourth a chord (X + B, J + K) | SPEC.md, section 3 | a right-stick grab mode |
| Pause on Select / Escape, since Start restarts | SPEC.md, section 3 | Start pauses, restart in the pause menu (slower than the brief asks) |
| The 4:3 frame by default, widescreen optional | LOOK.md, section 1 | widescreen by default |
| A formant voice for the announcer, a recorded bank only if it fails its gate | AUDIO.md, sections 6 and 7 | a recorded bank from the start |
| The sunset follows the progress, not the clock | COURSE.md, section 7 | a fixed golden hour |
| The cliff camera cut at the mega-jump | SPEC.md, section 7 | the chase camera throughout |
| Segmented (rigid) rider rather than skinned | LOOK.md, section 5 | a skinned rider of the same budget |
