// The reference trick script (docs/RIDER.md, section 10; TRICKS.md,
// section 9): what the autopilot does at each feature of Sunset Ridge,
// matched to the course's features (course_api feature(): 36 of them, s
// mapped to the main line's on the high line) by their s, within
// REF_MATCH metres, and their line. A feature with no row gets the
// autopilot's own choice (the biggest spin its air allows, and a grab); a
// rail with no row is not ridden (the rail garden's side lanes).
//
// Each row: s (the feature's lip or start), the line (0 the main or the
// low line, 1 the high line), the spin (degrees, signed: + left), the flip
// (degrees: + front, - back, 0 none), the grab (GRAB_*), and 1 to grind
// it. Keyed to tools/course's feature table (Sunset Ridge, COURSE.md
// section 2); the spins are cut to the solved flight at take-off, so a
// row asks for the most the jump is meant to give.

export const REF_MATCH: f32 = 3;

export const REF_S: StaticArray<f32> = [
    55, 85, 120, 160, 205, 250, 295,                 // warm-up: R1 .. R6, BK
    360.5, 420.3, 489.4, 555.3, 615,                 // kickers: K1 .. K5
    670, 730, 800, 850,                              // rail garden, centre lane: KR1 (passed: K5 lands too close), RR1, FD1, LR1
    930.2, 986.9, 1053, 1111.6, 1143.7, 1194.7,      // high line: HD1, HK1, HG, HR1, HD2, HK2
    930, 965, 1000, 1040, 1052, 1084.6, 1135.5,      // low line: LR1 .. LR4, LB1, LK1, LK2
    1330,                                            // the mega-jump
];
export const REF_HIGH: StaticArray<i32> = [
    0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0,
    0, 0, 0, 0,
    1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0,
    0,
];
export const REF_SPIN: StaticArray<i32> = [
    -180, 180, -360, 180, 360, -360, 360,
    540, -540, 720, 0, -900,
    0, 0, 0, 0,
    360, -720, 360, 0, -360, 720,
    180, -180, 180, -180, 0, 540, -720,
    -1080,
];
export const REF_FLIP: StaticArray<i32> = [
    0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, -360, 0,
    0, 0, 0, 0,
    0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0,
    -360,
];
// GRAB_*: 0 none, 1 Indy, 2 Melon, 3 Method, 4 Mute
export const REF_GRAB: StaticArray<i32> = [
    0, 1, 0, 2, 1, 0, 2,
    1, 2, 1, 3, 4,
    0, 0, 0, 0,
    0, 2, 1, 0, 3, 1,
    0, 1, 0, 2, 0, 1, 2,
    2,
];
export const REF_GRIND: StaticArray<i32> = [
    0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0,
    0, 1, 1, 1,
    0, 0, 0, 1, 0, 0,
    0, 0, 0, 0, 1, 0, 0,
    0,
];
