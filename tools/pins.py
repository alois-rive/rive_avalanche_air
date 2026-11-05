"""The pins: the contract between the world (run.as) and the Rive side
(make_rml.py). docs/RIVE.md, section 4; docs/IMPLEMENTATION.md.

A node script cannot reach the view model (gap E-VM), so every number the
HUD shows is a hidden node under `Pins` whose `position:x` is bound to a
property of the Scene3D's `data` view model (`GameData`), and every
command the menus send comes back on a node under `Pins/In`. A boolean
rides the node's `visible`.

Each row: (name, kind, direction, meaning)
  name       the GameData property and, capitalised, the pin node's name
  kind       "number" or "bool"
  direction  "out" (world -> view model, to_source), "in" (view model -> world),
             or "output" (written by an engine output binding in make_run.py: no pin node)

tools/make_run.py writes the Pins subtree of world/run.rscn and
world/scripts/pins_data.as (one index constant per pin) from this table;
make_rml.py declares GameData from it. Add rows; never rename one without
updating both sides.
"""

PINS = [
    # --- world -> view model -------------------------------------------
    ("phase", "number", "out", "0 title, 1 countdown, 2 quick start, 3 riding, 4 crash, 5 finish, 6 results, 7 initials"),
    ("score", "number", "out", "banked score"),
    ("comboSum", "number", "out", "the combo in progress: its running sum"),
    ("comboMult", "number", "out", "its multiplier (number of tricks, up to 10)"),
    ("comboActive", "bool", "out", "a combo is in progress"),
    ("trickSpin", "number", "out", "the current or last trick: spin degrees 0..1440 (multiple of 180)"),
    ("trickDir", "number", "out", "0 none, 1 frontside, 2 backside"),
    ("trickFlip", "number", "out", "0 none, 1 front flip, 2 back flip, 3 double front, 4 double back"),
    ("trickGrab1", "number", "out", "0 none, 1 Indy, 2 Melon, 3 Method, 4 Mute"),
    ("trickGrab2", "number", "out", "a second grab in the same air, as trickGrab1"),
    ("trickSwitch", "bool", "out", "taken off switch"),
    ("trickGrind", "number", "out", "0 none, 1 50-50, 2 boardslide, 3 log slide; +10 kinked, +20 rainbow"),
    ("trickLive", "bool", "out", "the trick is still being done (the banner grows)"),
    ("trickPoints", "number", "out", "the value of the last banked trick or combo"),
    ("trickSeq", "number", "out", "+1 each time a trick (an air or a grind) completes inside a combo"),
    ("bankSeq", "number", "out", "+1 each time a combo banks"),
    ("perfectSeq", "number", "out", "+1 on a perfect landing"),
    ("crashSeq", "number", "out", "+1 on a crash"),
    ("bailSeq", "number", "out", "+1 on a bail"),
    ("praise", "number", "out", "0 none, 1 NICE, 2 SICK, 3 RADICAL, 4 INSANE, 5 UNREAL, 6 SKETCHY, 7 OUCH, 8 WIPEOUT, 9 BAIL"),
    ("time", "number", "out", "the run's seconds"),
    ("countdown", "number", "out", "3, 2, 1, 0 (GO), -1 hidden; 10 READY"),
    ("progress", "number", "out", "0..1 along the course"),
    ("section", "number", "out", "1..7"),
    ("speedKmh", "number", "out", "the rider's speed"),
    ("balance", "number", "out", "-1..1 on a rail"),
    ("grinding", "bool", "out", "on a rail"),
    ("lineHigh", "bool", "out", "on the high line"),
    ("resTricks", "number", "out", "results: tricks"),
    ("resGrinds", "number", "out", "results: grinds"),
    ("resComboBonus", "number", "out", "results: combo bonus"),
    ("resLandings", "number", "out", "results: landings"),
    ("resTimeBonus", "number", "out", "results: time bonus"),
    ("resTotal", "number", "out", "results: total"),
    ("resBestCombo", "number", "out", "results: best combo value"),
    ("resLongestAir", "number", "out", "results: longest air, seconds"),
    ("resPerfects", "number", "out", "results: perfect landings"),
    ("resCrashes", "number", "out", "results: crashes"),
    ("resStep", "number", "out", "results: how many tally lines are shown (0..7: the tally's progress)"),
    ("resGrade", "number", "out", "0 C, 1 B, 2 A, 3 S, -1 not yet stamped"),
    ("resRank", "number", "out", "the high score table's place 1..10, 0 when not in it"),
    ("initialsCode", "number", "out", "the initials being entered: 3 letters packed (see game_state.as packInitials)"),
    ("initialsCursor", "number", "out", "0..2"),
] + [
    (f"hs{i}Score", "number", "out", f"high score {i}: score") for i in range(1, 11)
] + [
    (f"hs{i}Tag", "number", "out", f"high score {i}: initials packed, grade, line (game_state.as packTag)") for i in range(1, 11)
] + [
    ("captionLine", "number", "out", "the announcer's current line id (audio), -1 none"),
    ("captionSeq", "number", "out", "+1 per spoken line"),
    ("beat", "number", "out", "the music's beat counter"),
    ("device", "number", "out", "0 keyboard, 1 pad: the last used"),
    ("ghostDelta", "number", "out", "seconds ahead (-) or behind (+) the ghost"),
    ("ollieCharge", "number", "out", "0..1 while crouched for an ollie: the HUD's pop meter"),
    # written by engine outputs on LowRes/RiderAnchor (screen_position), not by a pin node
    ("riderX", "number", "output", "the rider's screen position x (points of the Scene3D)"),
    ("riderY", "number", "output", "the rider's screen position y"),
    # --- view model -> world -------------------------------------------
    ("startSeq", "number", "in", "+1: start from the title"),
    ("restartSeq", "number", "in", "+1: restart the run"),
    ("quitSeq", "number", "in", "+1: quit to the title"),
    ("paused", "bool", "in", "the pause menu is open"),
    ("scheme", "number", "in", "0 Hot Pink, 1 Acid, 2 Blaze"),
    ("musicVolume", "number", "in", "0..1"),
    ("sfxVolume", "number", "in", "0..1"),
    ("voiceVolume", "number", "in", "0..1"),
    ("mute", "bool", "in", ""),
    ("reducedMotion", "bool", "in", ""),
    ("landingAssist", "bool", "in", "on by default"),
    ("grindAssist", "bool", "in", ""),
    ("ghost", "bool", "in", ""),
    ("padX", "number", "in", "left stick X, dead zone applied (ui/pad.as until E-PAD)"),
    ("padY", "number", "in", "left stick Y, up positive"),
    ("padButtons", "number", "in", "bitmask: 1 south, 2 east, 4 west, 8 north, 16 start, 32 select, 64 up, 128 down, 256 left, 512 right"),
    ("uiMoveSeq", "number", "in", "+1 per menu move (a blip)"),
    ("uiSelectSeq", "number", "in", "+1 per menu confirm"),
    ("uiBackSeq", "number", "in", "+1 per menu back"),
    ("initialsIn", "number", "in", "the initials entry's letters, packed, written by the Rive side"),
    ("initialsDoneSeq", "number", "in", "+1 when the initials are confirmed"),
    ("demo", "bool", "in", "demo mode: no UI, no input, silent"),
    ("autopilot", "number", "in", "0 off, 1 the low line, 2 the high line (tests, attract)"),
    ("seed", "number", "in", "the run's seed (0: 1)"),
]
