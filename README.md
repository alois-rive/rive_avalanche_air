# rive_avalanche_air

A retro snowboard game demo built with Rive: **Avalanche Air**, a 90-second
arcade trick-attack run that looks and sounds like a 1998 PlayStation
title, built on Rive Hedra (the 3D engine for Rive, `../rive_modeler`).

Not built yet: the documents in [docs/](docs/) specify it.

| Document | What |
|---|---|
| [docs/BRIEF.md](docs/BRIEF.md) | the brief |
| [docs/SPEC.md](docs/SPEC.md) | the specification, and the index of the others |
| [docs/COURSE.md](docs/COURSE.md), [RIDER.md](docs/RIDER.md), [TRICKS.md](docs/TRICKS.md) | the course, the rider's physics, tricks and scoring |
| [docs/LOOK.md](docs/LOOK.md), [AUDIO.md](docs/AUDIO.md), [RIVE.md](docs/RIVE.md) | the PSX look, the procedural audio (Rive's `AudioProcessor`), the Rive UI |
| [docs/ASSETS.md](docs/ASSETS.md), [PERF.md](docs/PERF.md), [TESTS.md](docs/TESTS.md), [PLAN.md](docs/PLAN.md) | assets, budgets, tests, milestones |

The PlayStation look is a project skill, generic to any Hedra project:
[.claude/skills/psx-style](.claude/skills/psx-style/SKILL.md) (tested WGSL
shaders, a frame template, texture and audit scripts, and the asset
pipeline's overrides for the style).
