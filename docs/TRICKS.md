# Tricks, scoring and grades

Everything a player does in the air or on a rail is named, valued and
shouted. The scoring rewards three things, in this order: chaining
(combos multiply), variety (repeats decay), and clean landings (perfect
pays, a crash costs the combo). All of it is `world/scripts/tricks.as`,
fed by the rider's state each tick (RIDER.md), unit-tested by
`tricks_test.as`.

## 1. The trick set

| Family | Tricks | Done by |
|---|---|---|
| Spins | 180, 360, 540, 720, 900, 1080 (the brief), 1260 and 1440 (the mega-jump only) | stick X or Left / Right in the air |
| Flips | front flip, back flip; double flips (the mega-jump only) | stick Y or Up / Down in the air |
| Grabs | Indy, Melon, Method, Mute | X / J, B / K, Y / L, X + B / J + K, held in the air |
| Grinds | 50-50, boardslide (rails and boxes), log slide (logs) | landing on a rail, a box or a log (RIDER.md, section 7) |
| Air | big air | more than 1.0 s in the air |

## 2. Counting and naming

One **air** (from take-off to landing or catching a rail) is one trick,
named from what it held:

```
[SWITCH] [FRONTSIDE | BACKSIDE] [FRONT FLIP | BACKFLIP | DOUBLE FRONT FLIP | DOUBLE BACKFLIP] [180 ... 1440] [GRAB [TO GRAB]]
```

- **Spin**: the rotation about the rider's up axis since take-off,
  counted to the nearest half-turn when within 45° of it ("a 690 is a
  720"), else to the half-turn below. Under 135°: no spin.
- **Direction**: for a regular rider (left foot forward), a spin to the
  left (counter-clockwise from above) is **frontside**, to the right
  **backside**; mirrored for a goofy stance or riding switch. Named with
  every spin, as the brief's "BACKSIDE 720 INDY".
- **Flip**: a rotation about the lateral axis of 300° or more counts one
  flip, 660° or more two.
- **Grab**: held at least 0.2 s. Two grabs in one air: "INDY TO MELON".
- **Switch**: the take-off was riding switch.
- **Grinds**: named by kind, "50-50", "BOARDSLIDE", "LOG SLIDE", with
  "KINKED" or "RAINBOW" for those rails.

Examples: "BACKSIDE 720 INDY", "SWITCH FRONTSIDE 540", "BACKFLIP MELON",
"FRONTSIDE BACKFLIP 1080 METHOD TO MUTE", "KINKED 50-50".

The banner shows the name growing as it is done (the spin's count
ticking up in half-turns), then the final name with its points on the
landing (RIVE.md, section 5).

## 3. Values

| Trick | Points |
|---|---|
| 180 | 150 |
| 360 | 375 |
| 540 | 675 |
| 720 | 1,050 |
| 900 | 1,500 |
| 1080 | 2,100 |
| 1260 | 2,850 |
| 1440 | 3,750 |
| a flip | 900 |
| a double flip | 2,250 |
| a grab | 200 at 0.2 s held, then 75 a tenth of a second, up to 2.0 s held (1,550) |
| big air | 200 for each 0.5 s of air beyond 1.0 s |
| a grind | 150 on the catch, then 300 a second (boardslide x 1.25; a kinked or rainbow rail x 1.5) |

An air's value is the sum of its spin, flips, grabs and big air. A spin
and a flip together are worth both: the mega-jump's "BACKFLIP 1080 MELON"
held 1.0 s with 3.0 s of air is 2,100 + 900 + 800 + 800 = 4,600.

## 4. Variety

Each air trick's value decays with the times its exact name has already
scored this run: x 1.0, 0.75, 0.5, then 0.25 for the fourth and later.
Grinds do not decay (every rail is a different rail). The banner shows
the decayed value.

## 5. Combos

A **combo** is the tricks done without touching the snow: airs and
grinds chained by leaving a rail into the air, catching a rail from the
air, or ollieing off a rail. The first touch of the snow ends it:

```
combo = (sum of its tricks' values) x multiplier x landing x pop
multiplier = number of tricks in the combo, up to x 10
```

- A single air is a combo of one (x 1).
- **Landing** (RIDER.md, section 6): perfect x 1.25, clean x 1.0,
  sketchy x 0.5, a crash or a bail: the combo is lost, nothing banked.
- **Pop**: a perfect pop at the combo's first take-off x 1.1.

The HUD shows the combo's running sum and multiplier as it builds ("2,450
x 3"), and banks it with the praise word on the landing. The rail garden
is laid out so a rider can ollie from the end of one feature onto the
next in the same lane (COURSE.md, section 2): the garden is one combo for
a good rider.

## 6. Praise words

Shouted by the announcer and slammed onto the screen when a combo banks,
by its banked value:

| Banked | Word |
|---|---|
| under 1,000 | none (the trick name alone) |
| 1,000 | "NICE!" |
| 3,000 | "SICK!" |
| 6,000 | "RADICAL!" |
| 12,000 | "INSANE!" |
| 20,000 | "UNREAL!" |

A perfect landing adds "PERFECT!" before the word; a sketchy one says
"SKETCHY..." instead of any word. A crash: "OUCH!" or "WIPEOUT!"; a bail:
"BAIL!".

## 7. The run's score

```
score = banked combos + time bonus
time bonus = 200 x (100 - run time in seconds), when the run is under 100 s
```

Crashes cost only the combos they lose (the brief: "punishing on score,
never on flow"). The results screen tallies the score by category, each
ticking up in turn (RIVE.md, section 6):

| Line | What |
|---|---|
| Tricks | the banked value of every air |
| Grinds | the banked value of every grind |
| Combo bonus | what the multipliers added |
| Landings | what perfect landings added (and sketchy ones took) |
| Time bonus | |
| **Total** | |

with the best combo (its name list and value), the longest air, the
perfect landings, the crashes and the line taken (high or low).

## 8. Grades

| Grade | Score |
|---|---|
| S | 50,000 (the brief's) |
| A | 35,000 |
| B | 20,000 |
| C | below 20,000 |

The targets are shown before the countdown ("S RANK 50,000 · A 35,000 ·
B 20,000") and stamped on the results. The A and B thresholds are
provisional, set by the autopilot's runs and the playtests (PLAN.md, A3
and A9); S is the brief's.

## 9. The planned score budget

What the reference script (RIDER.md, section 10) is planned to score,
section by section; the autopilot measures it at A3 and the values of
section 3 are tuned until it holds.

| Section | High line | Low line |
|---|---|---|
| Warm-up (six rollers, the baby kicker) | 4,500 | 4,500 |
| Kickers (K1 to K5) | 12,500 | 12,500 |
| Rail garden (one lane as one combo) | 18,000 | 18,000 |
| Split path | 13,000 | 5,000 |
| Mega-jump | 5,700 | 5,700 |
| Time bonus (about 90 s) | 2,000 | 2,000 |
| **Total** | **about 56,000 (S)** | **about 48,000 (A)** |

A new player's first run is planned at 8,000 to 15,000 (C), a second or
third at 20,000 (B): the grade climbs with every run, which is the "one
more run" loop.

## 10. The high score table

Ten entries, each three characters (A to Z, 0 to 9, space, "!"), the
score, the grade and the line (H or L). Seeded on first launch with ten
fake riders from 45,000 down to 9,000 ("AVA", "RAD", "ZAP", "SKY",
"MAX", "JET", "NEO", "ICE", "OLY", "BOB"), so the first runs beat
someone.

- A score that enters the table opens the initials entry on the results
  (RIVE.md, section 6): the letter under the cursor changed with up and
  down, moved with left and right, confirmed with south / Enter; typing
  letters works too. The last initials are remembered for the session.
- Kept for the session today; kept across sessions once scripts have
  storage (E-STORE, SPEC.md, section 13); on the web meanwhile, the page
  keeps it in `localStorage` through the web runtime's view model API.
- The view model holds the table in fixed slots (`hs1` to `hs10`: E-LIST).

## 11. The ghost (optional)

The best run of the session is kept as its input log (a few KB) and,
when the ghost is on (the pause menu), replayed by a second rider
simulated alongside, drawn with the 1-bit screen-door transparency at
50 %, colliding with nothing and scoring nothing. Its position on the line
gives the HUD's "+1.2 s" against it. PLAN.md, A9.
