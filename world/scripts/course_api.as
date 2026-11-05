// The course as the gameplay sees it: the contract between the course
// (tools/course/, docs/COURSE.md) and the rider (docs/RIDER.md). See
// docs/IMPLEMENTATION.md, "Contracts".
//
// THE SIGNATURES BELOW ARE FIXED. The course's owner replaces the bodies
// (reading the generated course_data.as) and keeps every function, class
// and constant here with the same meaning. This first body is a
// placeholder: a straight 15-degree slope 400 m long with one kicker, one
// rail and a few trees, so the rider can be built before the course.
//
// Frame: metres, Y up; the line starts at the origin and runs down -Z;
// +X is to the rider's right going down. `s` is metres along the main line.
// Every query is allocation-free and cheap (ground() is called 4 times a
// tick at 120 ticks a second).

// ---- constants ---------------------------------------------------------------
export const COURSE_LENGTH: f32 = 400;    // the main line's length (m)
export const FINISH_S: f32 = 380;         // the finish arch
export const SPLIT_S: f32 = -1;           // where the high line parts (-1: none)
export const MERGE_S: f32 = -1;           // where it rejoins
export const MEGA_LIP_S: f32 = -1;        // the mega-jump's lip (-1: none)
export const AIR_GRAVITY: f32 = 13;       // the game's air gravity (docs/RIDER.md, section 5)

// ---- the ground -------------------------------------------------------------
export class GroundHit {
    y: f32 = 0;             // the surface's height under (x, z)
    nx: f32 = 0;            // its normal, unit
    ny: f32 = 1;
    nz: f32 = 0;
    surface: i32 = 0;       // game_state SURF_*
    feature: i32 = -1;      // the feature under it (featureCount()), -1 none
    lip: bool = false;      // on a kicker's lip (its last 1.5 m before the edge)
}

// The highest rideable surface under (x, z): terrain, kickers, tables,
// roofs. False where there is none (a void past a cliff, out of bounds):
// the rider falls there. `y` is set even then, to the lowest ground below
// (or -1000).
export function ground(x: f32, z: f32, out: GroundHit): bool {
    const slope: f32 = 0.2679;                 // tan 15°
    const s = -z;                              // z is negative going down
    let y = -s * slope;
    let dydz = slope;                          // the surface's rise per metre of z
    out.feature = -1;
    out.lip = false;
    // a kicker at s 60..64 on the line: a 1.8 m ramp, then the slope again
    if (s >= 60 && s < 64 && Mathf.abs(x) < 4) {
        const t = (s - 60) / 4;
        y += t * 1.8;
        dydz = slope - 0.45;
        out.feature = 0;
        out.lip = s > 62.5;
    }
    out.y = y;
    // the surface y - dydz z = const has the normal (0, 1, -dydz)
    const len = Mathf.sqrt(dydz * dydz + 1);
    out.nx = 0;
    out.ny = 1 / len;
    out.nz = -dydz / len;
    out.surface = Mathf.abs(x) < 15 ? 0 : 1;
    return Mathf.abs(x) < 60 && s > -20 && s < COURSE_LENGTH + 40;
}

// ---- the line -----------------------------------------------------------------
export class LinePoint {
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;
    tx: f32 = 0;            // unit tangent, downhill
    ty: f32 = 0;
    tz: f32 = -1;
    width: f32 = 30;        // the piste's width
    s: f32 = 0;             // metres along the main line (mapped, on the high line)
    section: i32 = 1;       // 1..7
    safe: bool = true;      // a safe respawn point
    high: bool = false;
}

// Samples are 1 m apart. `high` picks the high line (between SPLIT_S and
// MERGE_S); outside the split both give the main line.
export function lineCount(high: bool): i32 {
    return <i32>COURSE_LENGTH + 1;
}

export function lineSample(i: i32, high: bool, out: LinePoint): void {
    const s = <f32>i;
    out.x = 0;
    out.z = -s;
    out.y = -s * 0.2679;
    out.tx = 0;
    out.ty = -0.2588;
    out.tz = -0.9659;
    out.width = 30;
    out.s = s;
    out.section = s < 40 ? 1 : 2;
    out.safe = !(s >= 55 && s < 85);
    out.high = false;
}

// The nearest sample to (x, z), searched within ±30 samples of `hint` (the
// last answer); -1 for a fresh search.
export function nearestSample(x: f32, z: f32, hint: i32, high: bool): i32 {
    let i = <i32>Mathf.round(-z);
    if (i < 0) i = 0;
    const n = lineCount(high) - 1;
    if (i > n) i = n;
    return i;
}

// Whether (x, z) is on the high line's side of the split (meaningful
// between SPLIT_S and MERGE_S only).
export function isHighSide(x: f32, z: f32, s: f32): bool {
    return false;
}

// The first safe point at or after `s` (+5 m, docs/COURSE.md, section 5).
export function respawnAt(s: f32, high: bool, out: LinePoint): void {
    let i = <i32>Mathf.ceil(s + 5);
    const n = lineCount(high) - 1;
    for (; i < n; i++) {
        lineSample(i, high, out);
        if (out.safe) return;
    }
    lineSample(n, high, out);
}

// ---- rails, boxes, logs (polylines sampled every 0.25 m) -----------------------
export const RAIL_RAIL: i32 = 1;
export const RAIL_BOX: i32 = 2;
export const RAIL_LOG: i32 = 3;
export const RAIL_KINKED: i32 = 16;    // flags
export const RAIL_RAINBOW: i32 = 32;

export function railCount(): i32 {
    return 1;
}

export function railKind(r: i32): i32 {
    return RAIL_RAIL;
}

export function railFlags(r: i32): i32 {
    return 0;
}

export function railPointCount(r: i32): i32 {
    return 41;                     // 10 m
}

// The rail's top at point i: writes x, y, z into out (a LinePoint's x, y, z;
// its tangent into tx, ty, tz).
export function railPoint(r: i32, i: i32, out: LinePoint): void {
    const s: f32 = 120 + <f32>i * 0.25;
    out.x = 4;
    out.z = -s;
    out.y = -s * 0.2679 + 0.6;
    out.tx = 0;
    out.ty = -0.2588;
    out.tz = -0.9659;
    out.s = s;
}

// The rails whose box comes within `radius` of (x, z): writes their indices
// into `out`, returns how many (at most out.length).
export function railsNear(x: f32, z: f32, radius: f32, out: StaticArray<i32>): i32 {
    if (Mathf.abs(z + 125) < 5 + radius && Mathf.abs(x - 4) < radius + 1) {
        out[0] = 0;
        return 1;
    }
    return 0;
}

// ---- obstacles (vertical cylinders: tree trunks, posts, buildings as boxes of circles) --
export class Obstacle {
    x: f32 = 0;
    z: f32 = 0;
    radius: f32 = 0.3;
    bottom: f32 = 0;
    top: f32 = 5;
    rock: bool = false;     // a crash above 8 m/s rather than 6
}

const TREES_X: StaticArray<f32> = [-12, 14, -18, 20, -9];
const TREES_Z: StaticArray<f32> = [-30, -45, -90, -150, -200];

export function obstacleCount(): i32 {
    return TREES_X.length;
}

export function obstacle(i: i32, out: Obstacle): void {
    out.x = TREES_X[i];
    out.z = TREES_Z[i];
    out.radius = 0.35;
    out.bottom = out.z * 0.2679;
    out.top = out.bottom + 6;
    out.rock = false;
}

export function obstaclesNear(x: f32, z: f32, radius: f32, out: StaticArray<i32>): i32 {
    let n = 0;
    for (let i = 0; i < TREES_X.length && n < out.length; i++) {
        const dx = TREES_X[i] - x;
        const dz = TREES_Z[i] - z;
        if (dx * dx + dz * dz < (radius + 1) * (radius + 1)) out[n++] = i;
    }
    return n;
}

// ---- features (kickers, rollers, drops: for the autopilot, cameras, music) ------
export const FEAT_ROLLER: i32 = 1;
export const FEAT_KICKER: i32 = 2;
export const FEAT_DROP: i32 = 3;
export const FEAT_MEGA: i32 = 4;
export const FEAT_RAIL: i32 = 5;        // a rail, box or log (its index in `rail`)
export const FEAT_GAP: i32 = 6;

export class Feature {
    kind: i32 = FEAT_KICKER;
    s: f32 = 0;             // the lip's (or the start's) s
    x: f32 = 0;             // lateral offset from the line
    high: bool = false;     // on the high line
    lipHeight: f32 = 0;
    lipAngle: f32 = 0;      // degrees
    designSpeed: f32 = 0;   // m/s
    airTime: f32 = 0;       // s, at the design speed
    rail: i32 = -1;
}

export function featureCount(): i32 {
    return 2;
}

export function feature(i: i32, out: Feature): void {
    if (i == 0) {
        out.kind = FEAT_KICKER;
        out.s = 64;
        out.x = 0;
        out.high = false;
        out.lipHeight = 1.8;
        out.lipAngle = 24;
        out.designSpeed = 16;
        out.airTime = 1.2;
        out.rail = -1;
    } else {
        out.kind = FEAT_RAIL;
        out.s = 120;
        out.x = 4;
        out.high = false;
        out.lipHeight = 0.6;
        out.lipAngle = 0;
        out.designSpeed = 12;
        out.airTime = 0;
        out.rail = 0;
    }
}

// ---- zones -----------------------------------------------------------------
// Inside a fall zone (under a cliff, out of bounds): a crash with respawn.
export function inFallZone(x: f32, y: f32, z: f32): bool {
    return Mathf.abs(x) > 60;
}

// ---- the sun's schedule (docs/COURSE.md, section 7) -----------------------------
export class Sun {
    dirX: f32 = -0.45;      // towards the sun, Y up (unit)
    dirY: f32 = 0.47;
    dirZ: f32 = -0.76;
    sunR: f32 = 0.97;       // colours, linear 0..1
    sunG: f32 = 0.88;
    sunB: f32 = 0.66;
    zenithR: f32 = 0.28;
    zenithG: f32 = 0.44;
    zenithB: f32 = 0.78;
    horizonR: f32 = 0.78;   // = the fog's colour
    horizonG: f32 = 0.85;
    horizonB: f32 = 0.94;
    skyAmbR: f32 = 0.53;
    skyAmbG: f32 = 0.60;
    skyAmbB: f32 = 0.78;
    groundAmbR: f32 = 0.69;
    groundAmbG: f32 = 0.72;
    groundAmbB: f32 = 0.82;
    fogBegin: f32 = 35;
    fogEnd: f32 = 140;
}

export function sunAt(s: f32, out: Sun): void {
    // placeholder: one afternoon all the way down
}
