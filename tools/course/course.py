"""Sunset Ridge, the course of docs/COURSE.md, as one table.

make_course.py reads this file and builds everything from it: the line and
the high line, the terrain, every feature, the rails, the fall zones, the
respawn flags, the obstacles, the dressing, the sun's schedule. Change a
number here, run `python3 tools/course/make_course.py`, and the course,
its collision data and its look follow.

Frame: metres, Y up, the start gate at the origin, the course down -Z, +X
to the rider's right going down. `s` is metres along the main line (its
base profile, before the features are added); `x` a lateral offset from a
line, + to the right going down.

Where this table departs from COURSE.md's numbers (the physics with the
game's air gravity, 13 m/s2, does not allow some of them together), the row
says so in a comment; make_course.py --check prints the derived numbers.
"""

SEED = 1998

AIR_GRAVITY = 13.0
GROUND_GRAVITY = 9.81

# ---- the line ---------------------------------------------------------------
# The main line runs to the end of the run-out; COURSE_LENGTH is where the
# course "ends" for the progress (the end of section 7).
LINE_END = 1560.0
COURSE_LENGTH = 1460.0
FINISH_S = 1460.0          # COURSE.md: 1,400. The mega-jump's gap and its
                           # landing (from 21 to 26 m/s) reach s = 1,425, so
                           # the arch stands where the run-out eases off.
SPLIT_S = 900.0
MERGE_S = 1240.0
MEGA_LIP_S = 1330.0

# Sections: (number, name, s0, s1, piste width, speed in, speed out, target time s)
SECTIONS = [
    (1, "Start gate", 0.0, 40.0, 12.0, 0.0, 10.0, 4.0),
    (2, "Warm-up slope", 40.0, 330.0, 30.0, 10.0, 17.0, 21.0),
    (3, "Kicker section", 330.0, 640.0, 34.0, 17.0, 19.0, 18.0),
    (4, "Rail garden", 640.0, 900.0, 40.0, 18.0, 15.0, 17.0),
    (5, "Split path", 900.0, 1240.0, 28.0, 15.0, 22.0, 20.0),
    (6, "Final mega-jump", 1240.0, 1375.0, 20.0, 22.0, 25.0, 7.0),
    (7, "Finish gate", 1375.0, 1460.0, 30.0, 24.0, 0.0, 5.0),
]

# The base profile of the main line (and the low line through the split):
# (s, slope in degrees) knots, the slope held from each knot to the next and
# blended over BLEND metres around each change.
PROFILE = [
    (0.0, 6.0),
    (15.0, 20.0),      # the start ramp
    (40.0, 14.0),
    (330.0, 17.0),
    (640.0, 11.0),
    (900.0, 17.0),     # the low line: the split's drop shared with the high line
    (1240.0, 26.0),    # the mega-jump's in-run, to the lip (MEGA: the gap
                       # and the landing hill follow it, then POST_MEGA)
]
# After the mega-jump's landing: the run-out eases to RUNOUT_DEG, then flat
# from FLAT_S to the line's end.
RUNOUT_DEG = 8.0
FLAT_S = 1470.0
PROFILE_BLEND = {15.0: 4.0}   # per knot; default BLEND
BLEND = 16.0

# The main line's lateral meander (plan): (s, x) knots, smoothed (cosine).
MEANDER = [
    (0.0, 0.0), (60.0, 0.0), (200.0, 7.0), (330.0, -5.0), (480.0, 4.0),
    (640.0, 0.0), (760.0, -3.0), (900.0, 0.0), (1240.0, 0.0), (1560.0, 0.0),
]

# The split: the low line (Line) bows right, the high line (HighLine) left;
# both start at SPLIT_S and end at MERGE_S on the main line. The high line
# is HIGH_LENGTH long (its own s from SPLIT_S); its bow is solved so that it
# ends where the low line does.
LOW_BOW = 26.0             # metres right at the low line's middle
HIGH_LENGTH = 360.0
HIGH_WIDTH = 11.0          # COURSE.md: 9 to 12 m
LOW_WIDTH = 28.0
# The high line's base slope: the generator scales it to drop what the low
# line drops (both end at the merge); HIGH_STEPS are its drops (overlays).

# ---- the features (COURSE.md, section 2) -------------------------------------
# kind: roller | kicker | drop | gap | mega
# Rollers: (id, "roller", s, x, height, length, width)
# Kickers: (id, "kicker", s_lip, x, lip height, lip angle, landing angle,
#           design speed, air time, width, yaw)  -- the table is derived:
#           COURSE.md's table lengths do not fit its air times at 13 m/s2,
#           so the knuckle is put where the design flight's landing line
#           meets the lip's height, and --check prints the table.
# Drops:   (id, "drop", s_edge, x, step height, landing angle, design speed, width)
#           the landing angle is solved for a 3.5 m/s impact at the design speed
# line: "main" or "high" (s along that line)
ROLLERS = [
    ("R1", "main", 55.0, 0.0, 1.0, 14.0, 16.0),
    ("R2", "main", 85.0, -4.0, 1.0, 12.0, 12.0),
    ("R3", "main", 120.0, 5.0, 1.2, 13.0, 12.0),
    ("R4", "main", 160.0, 0.0, 1.2, 13.0, 14.0),
    ("R5", "main", 205.0, -6.0, 1.4, 14.0, 12.0),
    ("R6", "main", 250.0, 4.0, 1.4, 14.0, 12.0),
    ("LR1", "main", 930.0, 4.0, 1.2, 14.0, 16.0),
    ("LR2", "main", 965.0, -3.0, 1.2, 14.0, 16.0),
    ("LR3", "main", 1000.0, 4.0, 1.2, 14.0, 16.0),
    ("LR4", "main", 1040.0, -2.0, 1.2, 14.0, 16.0),
]

KICKERS = [
    # id, line, s_lip, x, lip h, lip deg, landing deg, design v, air s, width, yaw deg
    ("BK", "main", 295.0, 0.0, 1.2, 20.0, 24.0, 15.0, 1.0, 9.0, 0.0),
    ("K1", "main", 360.0, 0.0, 1.8, 24.0, 27.0, 16.0, 1.2, 10.0, 0.0),
    ("K2", "main", 420.0, -6.0, 1.8, 24.0, 27.0, 17.0, 1.2, 10.0, 0.0),
    ("K3", "main", 490.0, 0.0, 2.6, 27.0, 30.0, 18.0, 1.7, 12.0, 0.0),
    ("K4", "main", 555.0, -10.0, 2.0, 22.0, 28.0, 17.0, 1.4, 10.0, -30.0),  # hip: kicks 30 deg right (COURSE.md x +5: from -10 its landing stays on the piste)
    ("K5", "main", 615.0, 0.0, 3.0, 29.0, 31.0, 19.0, 2.0, 14.0, 0.0),
    # the split's features are fitted into its 360 and 340 m: each kicker,
    # its table and landing take 50 to 70 m, so the high line's are a little
    # smaller and closer than COURSE.md's, and each landing ends before the
    # next one's ramp (the high line ends 1 m beside the low line at the merge)
    ("HK1", "high", 992.0, 0.0, 2.3, 27.0, 30.0, 19.0, 1.5, 9.0, 0.0),
    ("HK2", "high", 1212.0, 0.0, 1.6, 24.0, 28.0, 18.0, 1.1, 9.0, 0.0),
    ("LK1", "main", 1085.0, 0.0, 1.8, 24.0, 27.0, 17.0, 1.2, 12.0, 0.0),
    ("LK2", "main", 1135.0, 0.0, 2.0, 25.0, 28.0, 18.0, 1.3, 10.0, 0.0),
]

DROPS = [
    # id, line, s_edge, x, step, landing deg, design v, width
    ("HD1", "high", 932.0, 0.0, 4.0, 32.0, 17.0, 14.0),
    ("HD2", "high", 1158.0, 0.0, 6.0, 34.0, 20.0, 14.0),
]

# The gondola station gap (HG): a kicker over the station's roof. The gap's
# floor is the base terrain, the station on it; the landing a mound past it.
HG = dict(id="HG", line="high", s=1062.0, x=0.0, lip_h=3.0, lip_deg=28.0, land_deg=30.0,
          v=21.0, knuckle=26.0, knuckle_y=-1.0, width=10.0,
          station=dict(u0=4.0, u1=20.0, half_width=7.0, height=5.0))

# The mega-jump (section 6). COURSE.md: lip 3.5 m at 30 deg, 45 m gap, the
# landing 24 m below, 32 deg, 3.0 s of air. With 13 m/s2 a 30 deg lip lands
# 50 deg steep at 3 s: impacts of 13 m/s (a crash) on a 34 deg landing. So
# the lip is 20 deg and the landing 38 deg (the steepest of the run): 2.8 s
# of air at 24 m/s, 5 to 12 m/s of impact from 21 to 26 m/s.
MEGA = dict(id="MJ", s=MEGA_LIP_S, x=0.0, lip_h=3.5, lip_deg=20.0, land_deg=38.0, v=24.0,
            knuckle=45.0, knuckle_y=-14.0, width=20.0, ravine_depth=34.0)

# ---- rails, boxes, logs (section 4 and the split) ----------------------------
# (id, line, s_start, x, kind, segments, start height, width)
# segments: list of (plan length m, shape) with shape "flat" (parallel to the
# snow), ("down", deg) absolute pitch, ("arc", rise) a rainbow over that segment.
RAILS = [
    ("FB1", "main", 660.0, -12.0, "box", [(8.0, "flat")], 0.5, 0.6),
    ("LG1", "main", 700.0, -12.0, "log", [(10.0, "flat")], 0.6, 0.45),
    ("DR1", "main", 760.0, -12.0, "rail", [(12.0, ("down", 15.0))], 1.3, 0.08),
    ("KR1", "main", 670.0, 0.0, "rail", [(4.0, "flat"), (6.0, ("down", 20.0)), (4.0, "flat")], 1.5, 0.08),
    ("RR1", "main", 730.0, 0.0, "rail", [(10.0, ("arc", 1.2))], 0.5, 0.08),
    ("FD1", "main", 800.0, 0.0, "box", [(4.0, "flat"), (6.0, ("down", 18.0))], 1.2, 0.6),
    ("LR1", "main", 850.0, 0.0, "rail", [(16.0, "flat")], 0.6, 0.08),
    ("LG2", "main", 665.0, 12.0, "log", [(12.0, "flat")], 0.6, 0.45),
    ("FR1", "main", 720.0, 12.0, "rail", [(10.0, "flat")], 0.6, 0.08),
    ("DB1", "main", 790.0, 12.0, "box", [(12.0, ("down", 15.0))], 1.3, 0.6),
    ("HR1", "high", 1124.0, -5.5, "rail", [(14.0, ("down", 25.0))], 1.6, 0.08),
    ("LB1", "main", 1052.0, -5.0, "box", [(10.0, "flat")], 0.5, 0.6),
]
RAIL_STEP = 0.25

# ---- surfaces -----------------------------------------------------------------
LAKE = dict(s=780.0, x=-52.0, length=40.0, width=60.0)   # ice, flat (COURSE.md: 60 x 40 m)

# ---- the terrain ---------------------------------------------------------------
GRID = 1.5                 # the fine grid (m): the render's piste triangles and ground()
BLOCK = 4                  # cells a coarse block side (6 m)
TILE_BLOCKS = 6            # block rows a render tile (36 m)
BAND = 48.0                # terrain on each side of a line beyond its piste edge (m)
FINE_MARGIN = 1.5          # fine cells beyond the piste edges
Z_BEFORE = 30.0            # terrain behind the start gate
NOISE = (2.2, 38.0)        # off-piste noise: amplitude (m), wavelength (m)
SIDE_RISE = 0.22           # the sides rise this much a metre beyond the piste (a gentle trough)
FAR_STEP = 24.0            # the far mountainsides' triangles
FAR_WIDTH = 192.0          # how far they reach beyond the band

# ---- the sun (COURSE.md, section 7) --------------------------------------------
# (s, elevation deg, sun, zenith, horizon and fog, sky ambient, snow bounce, fog begin, fog end)
SUN = [
    (0.0, 28.0, "#f8e0a8", "#4870c8", "#c8d8f0", "#8898c8", "#b0b8d0", 35.0, 140.0),
    (640.0, 18.0, "#f8c880", "#4060b8", "#d8d0e8", "#8890c0", "#b8b0c8", 33.0, 132.0),
    (1000.0, 10.0, "#f8a060", "#384898", "#e0b8c8", "#8878b0", "#b0a0b8", 30.0, 124.0),
    (1330.0, 3.0, "#f87850", "#282868", "#7858a0", "#605890", "#8878a0", 26.0, 112.0),
    (1460.0, 1.0, "#e86048", "#202058", "#6850a0", "#585088", "#807098", 25.0, 110.0),
]
SUN_AZIMUTH = 35.0         # degrees left of the fall line (-Z towards -X)

# ---- the dressing (section 8) --------------------------------------------------
TREES = dict(count=900, min_gap=4.2, edge_clear=3.0, high_line_density=1.8, obstacle_reach=25.0)
CONE_PINES = dict(count=60, reach=6.0)
SPANS = [140.0, 490.0, 615.0, 1300.0]       # sponsor banners across the piste
ARCHES = [("start", 4.0), ("split", 890.0), ("finish", FINISH_S)]
LIFT1 = dict(s0=40.0, s1=640.0, x=-30.0, pylons=9, chairs=40)
LIFT2 = dict(s0=700.0, s1=840.0, x0=-70.0, x1=70.0, pylons=4, chairs=16, height=12.0)
GONDOLA = dict(pylons=3, cabins=6)
