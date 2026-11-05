# Tests

Everything that can be a command is one, and runs headless: the bake,
the physics, the scoring, the course, the pictures, the sound. The game is
deterministic (RIDER.md, section 1; AUDIO.md, section 9), so a session of
inputs is a test, and its view model, its pictures and its audio are
goldens. What only people can judge (fun, readability, "is it a PS1
game?") has its own protocol (section 8).

## 1. Determinism first

- One `Pcg32` stream per purpose (the grind's wobble, the tumble, the
  spray, the announcer's choices, each audio voice), seeded from the
  run's seed; no `Math.random`, no wall clock in the simulation.
- The Box3D world stepped serially; f32 in a fixed order.
- The view model dumped every 30 frames (`--data-dump-every=30
  --data-dump-filter=data/*`) is the run's trace; the same seed and inputs
  give the same trace natively with script threads, natively with one
  (`--job-threads=1`) and on the web runtime.
- `--data` is set only before the first frame (a known rive crash when it
  is set between two `--advance`s with `--data-dump-every`: the kart's
  TESTS.md, section 5).

## 2. The cases

Suite `rive_avalanche` (`tests/run.py`, tiers `default`, `full`, `deep`,
as the Hedra repository's suites), its goldens in `tests/expected/`.

| # | Case | How | Passes when |
|---|---|---|---|
| 1 | The bake | `hedra build .` then `rive . --unsigned-riv`, twice | no error; the same bytes twice |
| 2 | The reference run | `--data=data/autopilot=1 --data=data/seed=1 --data=data/line=1` (the high line), `--advance` to the results | run time 85 to 95 s; score 52,000 to 62,000; the trace equals `expected/reference_run.txt` |
| 3 | The controller lab | `hedra play world/lab.rscn --input tests/lab.jsonl --dump-frames shots/lab --capture 600` | the dumped states equal `expected/lab/` |
| 4 | Units | `rive . --test` | every `*_test.as`: the slope's terminal speeds, the ollie's heights, a kicker's flight against its shaped landing, the landing table, the catch, the balance, the respawn rules, the trick detector (spins counted, named, directions for both stances), the values and decay, combos and multipliers, praise thresholds, the table's ordering, the course data's sanity |
| 5 | Restart latency | sessions pressing R at 1 s, at a crash, at the finish and on the results (`--key=r:down`) | the rider's first tick with control within 60 frames of the press (at most 120) |
| 6 | The first 10 seconds | the new-player session (Space on the first roller, Right in the air) | a trick banked before the run's 10th second |
| 7 | The reference pictures | the eight views (gate, warm-up, kicker air, rail garden, high line, mega-jump, finish, results) as `rive --screenshot --viewport=1280x960 --advance=N` | each equals its golden within the demo's tolerance; `psx_audit.py frame` passes on each (`--max-off-grid 0.02` with the HUD) |
| 8 | The course | `python3 world/course/make_course.py --check` | the generated files unchanged; collision within 2 cm of render; every kicker's landing meets its flight from design - 3 to + 3 m/s; the autopilot's section times within 15 % |
| 9 | The sound | `rive . --render-audio=shots/run.wav --advance=96s` with case 2's data; and the unit renders (`audio_test.as`) | the render's difference from `expected/run.wav` at least 60 dB under the signal; loudness -16 LUFS ±2, peaks under -1 dBFS; each unit render's length, peak, centroid, no NaN, no click |
| 10 | Lanes and the web | case 2 with `--job-threads=1`, and on the web runtime in a headless browser | the same trace |
| 11 | Inputs | a keyboard-only session (start, ride, finish, initials, restart); once E-PAD exists, the same with `--gamepad=...` alone; meanwhile the pad script's writes checked with `--gamepad` on the 2D side | each reaches the second run's countdown |
| 12 | Reduced motion | case 2 with `settings/reducedMotion` | the dumps of the chase camera's `fov` (a `to_source` binding) never change; no `Cliff` cut; no wipe |
| 13 | The heap | ten runs in a row (`soak_runs`) | wasm pages after run 10 equal those after run 1 |
| 14 | The bench | `rive . --bench=600 --data=data/demo=true`, alone | PERF.md's budgets |
| 15 | Demo mode | `--data=data/demo=true --advance=1800` | frame 1,800 equals frame 0; the same twice and on one job thread |
| 16 | Semantics | `rive . --semantics` on the HUD and the results | every number labelled |
| 17 | The assets | `asset.py status` for every asset; `psx_audit.py texture` on every texture and `model` on every model with its budget (ASSETS.md) | all pass |

## 3. Goldens and how they are recorded

A golden is recorded once, looked at by the person (a picture, a render
listened to, a trace's numbers sanity-checked), committed, and changed
only by a commit that says why. `tests/run.py --record <case>` writes
them; a recording is never part of a normal run.

## 4. What the tests read

The view model (the pins: RIVE.md, section 4) is the game's state from
outside: the phase, the score, the combo, the trick's parts, the time,
the progress, the section, the balance, the camera's `fov`, the results.
The world's script state is not read directly.

## 5. The screenshot test

The brief's "a screenshot is recognised as a PS1 game without
explanation", in two halves: the measurable one is `psx_audit.py frame`
(whole low-resolution pixels, 15-bit colour, 4:3) on every reference
picture (case 7); the human one is the blind check (section 8).

## 6. What CI checks

The `default` tier on every change (cases 1, 4, 8, a short case 2 to the
end of the kicker section, 6, 7, 17); the `full` tier before a milestone
closes; `deep` (10, 13, 15 at length) and the bench (14) on a quiet
machine before a release.

## 7. Tools

`tests/run.py` (the runner), `tests/sessions/*.txt` (key sessions as rive
flags), `tests/expected/` (goldens), the psx-style scripts
(`.claude/skills/psx-style/scripts/`), Python 3 with Pillow and NumPy,
`ffmpeg` for the loudness (`loudnorm` measurement) or a NumPy
implementation of BS.1770 in `tests/loudness.py`.

## 8. Playtests

People, at A9 and before any release; recorded in `docs/playtests.md`
(date, testers, results, decisions).

| Check | Protocol | Target (the brief's success criteria) |
|---|---|---|
| First trick | 5 new players, no instructions, the pad; the time from GO to the first banked trick | 4 of 5 within 10 s |
| One more run | the same players, told "play as long as you like" | 4 of 5 play 3 runs or more in a row |
| Restart | observed; and case 5 | no one waits for a restart |
| PS1 recognition | 5 people shown the gate and kicker screenshots, "what is this from?" | 4 of 5 say PlayStation / PS1 / 90s console unprompted |
| The announcer | 10 listeners, 20 lines, no captions (AUDIO.md, section 7) | 80 % understood |
| Grades | the scores of the 5 players' runs 1 to 5 | run 1 mostly C, run 3 to 5 reaching B; S reachable by a practised player (the A and B thresholds tuned on this: TRICKS.md, section 8) |
