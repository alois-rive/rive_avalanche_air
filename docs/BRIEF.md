# Avalanche Air — Spec Brief

Nov 5, 2026 · @Alois

## Overview

Avalanche Air is a single-run, arcade snowboarding trick-attack demo that looks and sounds like a 1998 PlayStation title. One run lasts about 90 seconds: the player bombs down a mountain, chains tricks for points, and lands a final mega-jump. The goal is a "one more run" loop: fast restarts, a high score to beat, and loud, cheesy feedback on every trick.

| Attribute | Value |
| --- | --- |
| Genre | Arcade snowboarding, score attack |
| Inspirations | Cool Boarders 2, SSX, Tony Hawk's Pro Skater (combo logic) |
| Session length | \~90 s per run, 5–10 min per sitting |
| Players | 1, local |
| Input | Gamepad first, keyboard supported |
| Target platform | Desktop or web build; engine to be chosen |
| Tone | Extreme-sports cliché: attitude, neon, shouting announcer |

## Gameplay

The core loop is: build speed, launch, trick, land clean, bank points, repeat — and the run ends at the finish gate with a score and a grade.

### Controls

| Action | Gamepad | Keyboard |
| --- | --- | --- |
| Steer / carve | Left stick | A / D |
| Tuck (speed up) | Down on stick | S |
| Crouch, release to jump (ollie) | A (hold, release) | Space |
| Grabs | X / B / Y + direction | J / K / L |
| Spins and flips (in air) | Left stick | Arrow keys |
| Grind (on rail) | Land on rail, stick to balance | Same |
| Restart run | Start | R |

### Tricks and scoring

- **Spins:** 180 to 1080, more rotation = more points.
- **Flips:** front and back flips, combinable with spins.
- **Grabs:** 4 named grabs; holding a grab longer adds points.
- **Grinds:** rails and logs; balance meter, points per second.
- **Combo:** tricks chained without touching snow (or via a grind) multiply the score; a clean landing banks it, a crash loses it.
- **Landing quality:** board must be aligned with the slope; perfect landing gives a bonus and a speed boost.
- **Crash:** a short ragdoll tumble, then reset on the track within 1.5 s (punishing on score, never on flow).

### Run structure

1. **Start gate:** countdown, 3-2-1, announcer shout.
2. **Warm-up slope:** gentle rollers to learn ollies and spins.
3. **Kicker section:** a row of jumps for big air tricks.
4. **Rail garden:** rails, logs and boxes for grinds.
5. **Split path:** a risky high line (more air, more points) vs a safe low line.
6. **Final mega-jump:** a huge gap jump over a cliff for one last combo.
7. **Finish gate:** score breakdown and a letter grade (C to S).

### Session hooks

- Instant restart from anywhere, no menus in between.
- Local high score table with 3-letter initials.
- Grade targets shown at the start ("S rank: 50,000").
- Optional: a ghost of the best run.

## Visuals

The look should be instantly read as "PS1 game": low resolution, wobbly polygons, fog, and loud late-90s graphic design.

### Rendering traits

- **Low internal resolution:** render at 320×240, upscaled with nearest-neighbor filtering.
- **Vertex snapping:** vertices snapped to a coarse screen grid, so geometry jitters as the camera moves.
- **Affine texture mapping:** no perspective correction, so textures warp on large polygons.
- **No texture filtering:** 64×64 or 128×128 textures, nearest sampling, visible pixels.
- **Limited color:** 15-bit color look with ordered dithering.
- **Distance fog:** short draw distance hidden by colored fog (white-blue by day, purple at dusk).
- **Low poly counts:** rider around 300–500 triangles, chunky trees as crossed billboards.
- **Vertex lighting only:** flat or Gouraud shading, baked colors, no real-time shadows except a blob shadow under the rider.

### Art direction

- **Setting:** an alpine resort at golden hour, with pine trees, chalets, chairlifts, giant sponsor banners and inflatable arches.
- **Rider:** blocky snowboarder with baggy clothes, goggles and a neon jacket; 2–3 selectable color schemes.
- **Palette:** snow whites and icy blues against hot pink, acid green and orange accents.
- **Effects:** sprite-based snow spray, speed lines when tucking, a lens flare on the low sun.

### UI and HUD

- **Title screen:** chrome 3D logo spinning, "PRESS START" blinking, a short attract-mode replay.
- **HUD:** score top left, combo multiplier top right, run timer, and a trick name banner in the center.
- **Typography:** wide, italic, techno-style fonts with drop shadows and outlines.
- **Trick pop-ups:** names slam in with a scale bounce ("BACKSIDE 720 INDY!"), then a praise word ("SICK!", "RADICAL!", "INSANE!").
- **Results screen:** points tally ticking up, then a huge letter grade stamped onto the screen.

## Audio

Audio carries half of the cliché: fast music, crunchy sound effects, and an announcer who never stops shouting.

- **Music:** one looping drum-and-bass or big-beat track (around 170 BPM), with a filtered intro on the title screen.
- **Board SFX:** carving hiss that rises with speed, crunchy landings, a metallic scrape on rails.
- **Announcer:** short shouted lines for trick names, praise words, crashes ("OUCH!") and the final grade.
- **UI SFX:** sharp menu blips, a cash-register tally on the results screen.
- **Format feel:** slightly lo-fi samples (22 kHz) to match the era.

## Demo scope

The demo is one polished mountain run, not a full game.

| In scope | Out of scope |
| --- | --- |
| 1 course (\~90 s run) | Multiple mountains or a career mode |
| 1 rider, 2–3 color schemes | Character roster, unlockables |
| Full trick set (spins, flips, grabs, grinds) | Trick editor, custom controls |
| Title, run, results screens | Options menus beyond volume and controls |
| Local high scores | Online leaderboards, multiplayer |

**Success criteria**

- A new player lands a trick in their first 10 seconds.
- Restart from crash or finish to a new run takes under 2 seconds.
- Testers voluntarily play 3+ runs in a row.
- A screenshot is recognized as "a PS1 game" without explanation.
