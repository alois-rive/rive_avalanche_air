// The reference trick script (docs/RIDER.md, section 10; TRICKS.md,
// section 9): what the autopilot does at each feature of Sunset Ridge,
// matched to the course's features by their s (within REF_MATCH metres)
// and line. A feature with no row gets the autopilot's own choice (the
// biggest spin its air allows, and a grab).
//
// Each row: s (the feature's lip or start, COURSE.md section 2), the line
// (0 both or low, 1 high), the spin (degrees, signed: + left), the flip
// (FLIP_* of game_state as degrees: + front, - back, 0 none), the grab
// (GRAB_*), and 1 to grind it (rails, boxes, logs).
//
// Tuned on the placeholder slope; to be re-tuned on the real course after
// the merge (its score is planned at 52,000 to 62,000 on the high line).

export const REF_MATCH: f32 = 8;

export const REF_S: StaticArray<f32> = [
    55, 85, 120, 160, 205, 250, 295,             // warm-up: R1 .. R6, BK
    360, 420, 490, 555, 615,                     // kickers: K1 .. K5
    670, 730, 800, 850,                          // rail garden, centre lane: KR1, RR1, FD1, LR1
    945, 995, 1060, 1110, 1165, 1210,            // high line: HD1, HK1, HG, HR1, HD2, HK2
    930, 965, 1000, 1040, 1080, 1120, 1180,      // low line: LR1 .. LR4, LB1, LK1, LK2
    1330,                                        // the mega-jump
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
    0, 0, -360, 0, 0, 0,
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
    1, 1, 1, 1,
    0, 0, 0, 1, 0, 0,
    0, 0, 0, 0, 1, 0, 0,
    0,
];
