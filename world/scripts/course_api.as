// The course as the gameplay sees it: the contract between the course
// (tools/course/, docs/COURSE.md) and the rider (docs/RIDER.md). See
// docs/IMPLEMENTATION.md, "Contracts".
//
// THE SIGNATURES BELOW ARE FIXED. The bodies read course_data.as, which
// tools/course/make_course.py generates from tools/course/course.py: the
// ground is the terrain's render grid itself (1.5 m cells, each split
// along the same diagonal as its two render triangles, heights to the
// centimetre), so ground() is the drawn surface exactly.
//
// Frame: metres, Y up; the line starts at the origin and runs down -Z;
// +X is to the rider's right going down. `s` is metres along the main line.
// Every query is allocation-free and cheap (ground() is called 4 times a
// tick at 120 ticks a second).
import {
    COURSE_LENGTH_DATA, FINISH_S_DATA, SPLIT_S_DATA, MERGE_S_DATA, MEGA_LIP_S_DATA, HIGH_LENGTH_DATA,
    GRID_STEP, GRID_X0, GRID_Z0, GRID_ROWS, ROW_C0, ROW_N, ROW_OFF, ROW_Y, GRID_H, PISTE,
    LINE_N, LINE_P, LINE_T, LINE_W, LINE_F, HIGH_N, HIGH_P, HIGH_T, HIGH_W, HIGH_F, HIGH_S,
    RAIL_N, RAIL_KIND, RAIL_FLAGS, RAIL_START, RAIL_COUNT, RAIL_S0, RAIL_AABB, RAIL_PTS,
    FEAT_N, FEAT_KIND, FEAT_S, FEAT_X, FEAT_HIGH, FEAT_LIPH, FEAT_LIPA, FEAT_V, FEAT_AIR, FEAT_RAILI,
    FOOT_N, FOOT_FEAT, FOOT, FOOT_MASK, ROOF, ROOF_FEAT, LAKE, FALL_N, FALL,
    OBS_N, OBS, OBS_ROCK, OBS_BLOCK, SUN_N, SUN_S, SUN_K,
} from "./course_data";

// ---- constants ---------------------------------------------------------------
export const COURSE_LENGTH: f32 = COURSE_LENGTH_DATA;  // the course's length for the progress (m): the finish
export const FINISH_S: f32 = FINISH_S_DATA;            // the finish arch
export const SPLIT_S: f32 = SPLIT_S_DATA;              // where the high line parts (-1: none)
export const MERGE_S: f32 = MERGE_S_DATA;              // where it rejoins
export const MEGA_LIP_S: f32 = MEGA_LIP_S_DATA;        // the mega-jump's lip (-1: none)
export const AIR_GRAVITY: f32 = 13;       // the game's air gravity (docs/RIDER.md, section 5)

const SURF_GROOMED: i32 = 0;              // game_state's SURF_* (not imported: no cycle)
const SURF_POWDER: i32 = 1;
const SURF_ICE: i32 = 2;
const SURF_ROCK: i32 = 3;
const ROCK_NY: f32 = 0.64;                // steeper than about 50 degrees: rock
const BLOCK_M: f32 = 6;                   // 4 grid rows

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

function offGround(out: GroundHit): bool {
    out.y = -1000;
    out.nx = 0;
    out.ny = 1;
    out.nz = 0;
    out.surface = SURF_POWDER;
    return false;
}

// The highest rideable surface under (x, z): terrain, kickers, tables,
// roofs. False where there is none (a void past a cliff, out of bounds):
// the rider falls there. `y` is set even then, to the lowest ground below
// (or -1000).
export function ground(x: f32, z: f32, out: GroundHit): bool {
    out.feature = -1;
    out.lip = false;
    const fr = (GRID_Z0 - z) / GRID_STEP;
    const fc = (x - GRID_X0) / GRID_STEP;
    const r = <i32>Mathf.floor(fr);
    const c = <i32>Mathf.floor(fc);
    if (r < 0 || r >= GRID_ROWS - 1) return offGround(out);
    const ca = ROW_C0[r];
    const cb = ROW_C0[r + 1];
    if (c < ca || c + 1 >= ca + ROW_N[r] || c < cb || c + 1 >= cb + ROW_N[r + 1]) return offGround(out);
    const ia = ROW_OFF[r] + c - ca;
    const ib = ROW_OFF[r + 1] + c - cb;
    const ya = ROW_Y[r];
    const yb = ROW_Y[r + 1];
    const h00 = ya + <f32>GRID_H[ia] * 0.01;
    const h01 = ya + <f32>GRID_H[ia + 1] * 0.01;
    const h10 = yb + <f32>GRID_H[ib] * 0.01;
    const h11 = yb + <f32>GRID_H[ib + 1] * 0.01;
    const tx = fc - <f32>c;
    const ty = fr - <f32>r;
    let y: f32;
    let dc: f32;
    let dr: f32;
    if (tx >= ty) {
        y = h00 + (h01 - h00) * tx + (h11 - h01) * ty;
        dc = h01 - h00;
        dr = h11 - h01;
    } else {
        y = h00 + (h10 - h00) * ty + (h11 - h10) * tx;
        dr = h10 - h00;
        dc = h11 - h10;
    }
    const gx = dc / GRID_STEP;
    const gz = -dr / GRID_STEP;
    const inv = 1 / Mathf.sqrt(gx * gx + 1 + gz * gz);
    out.y = y;
    out.nx = -gx * inv;
    out.ny = inv;
    out.nz = -gz * inv;
    // the station's roof (HG's gap): flat, rideable
    let px = x - ROOF[0];
    let pz = z - ROOF[1];
    let u = px * ROOF[2] + pz * ROOF[3];
    let v = pz * ROOF[2] - px * ROOF[3];
    if (u >= ROOF[4] && u <= ROOF[5] && Mathf.abs(v) <= ROOF[6] && ROOF[7] > y) {
        out.y = ROOF[7];
        out.nx = 0;
        out.ny = 1;
        out.nz = 0;
        out.surface = SURF_GROOMED;
        out.feature = ROOF_FEAT;
        return true;
    }
    // the feature under it, and its lip
    let mask = FOOT_MASK[r >> 2];
    while (mask != 0) {
        const k = <i32>ctz<u32>(mask);
        mask &= mask - 1;
        const b = k * 9;
        px = x - FOOT[b];
        pz = z - FOOT[b + 1];
        u = px * FOOT[b + 2] + pz * FOOT[b + 3];
        v = pz * FOOT[b + 2] - px * FOOT[b + 3];
        if (u >= FOOT[b + 4] && u <= FOOT[b + 5] && Mathf.abs(v) <= FOOT[b + 6]) {
            out.feature = FOOT_FEAT[k];
            if (u >= FOOT[b + 7] && u <= FOOT[b + 8]) {
                out.lip = true;
                break;
            }
        }
    }
    // the surface
    px = x - LAKE[0];
    pz = z - LAKE[1];
    u = (px * LAKE[2] + pz * LAKE[3]) / LAKE[4];
    v = (pz * LAKE[2] - px * LAKE[3]) / LAKE[5];
    if (u * u + v * v <= 1) {
        out.surface = SURF_ICE;
    } else if (out.ny < ROCK_NY) {
        out.surface = SURF_ROCK;
    } else {
        let rr = <i32>Mathf.round(fr);
        if (rr >= GRID_ROWS) rr = GRID_ROWS - 1;
        const p = rr * 4;
        out.surface = (x >= PISTE[p] && x <= PISTE[p + 1]) || (x >= PISTE[p + 2] && x <= PISTE[p + 3])
            ? SURF_GROOMED : SURF_POWDER;
    }
    return true;
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

// The high line's sequence: the main line's samples to the split, the high
// line's from the split to the merge, the main line's after the merge.
const SPLIT_I: i32 = <i32>SPLIT_S_DATA;
const MERGE_I: i32 = <i32>MERGE_S_DATA;

// Samples are 1 m apart. `high` picks the high line (between SPLIT_S and
// MERGE_S); outside the split both give the main line.
export function lineCount(high: bool): i32 {
    return high ? SPLIT_I + HIGH_N + (LINE_N - MERGE_I - 1) : LINE_N;
}

// The array and index of sample i of a sequence: >= 0 the main line's
// index, < 0 the high line's (-1 - index).
function locate(i: i32, high: bool): i32 {
    if (!high || i < SPLIT_I) return i;
    if (i < SPLIT_I + HIGH_N) return -1 - (i - SPLIT_I);
    return i - SPLIT_I - HIGH_N + MERGE_I + 1;
}

function sampleX(i: i32, high: bool): f32 {
    const k = locate(i, high);
    return k >= 0 ? LINE_P[k * 3] : HIGH_P[(-1 - k) * 3];
}

function sampleZ(i: i32, high: bool): f32 {
    const k = locate(i, high);
    return k >= 0 ? LINE_P[k * 3 + 2] : HIGH_P[(-1 - k) * 3 + 2];
}

export function lineSample(i: i32, high: bool, out: LinePoint): void {
    const n = lineCount(high);
    if (i < 0) i = 0;
    if (i >= n) i = n - 1;
    const k = locate(i, high);
    let f: i32;
    if (k >= 0) {
        out.x = LINE_P[k * 3];
        out.y = LINE_P[k * 3 + 1];
        out.z = LINE_P[k * 3 + 2];
        out.tx = LINE_T[k * 3];
        out.ty = LINE_T[k * 3 + 1];
        out.tz = LINE_T[k * 3 + 2];
        out.width = LINE_W[k];
        out.s = <f32>k;
        out.high = false;
        f = LINE_F[k];
    } else {
        const h = -1 - k;
        out.x = HIGH_P[h * 3];
        out.y = HIGH_P[h * 3 + 1];
        out.z = HIGH_P[h * 3 + 2];
        out.tx = HIGH_T[h * 3];
        out.ty = HIGH_T[h * 3 + 1];
        out.tz = HIGH_T[h * 3 + 2];
        out.width = HIGH_W[h];
        out.s = HIGH_S[h];
        out.high = true;
        f = HIGH_F[h];
    }
    out.section = f & 7;
    out.safe = (f & 8) != 0;
}

// The first sample at or below z (the lines run down -Z): a binary search.
function indexAtZ(z: f32, high: bool): i32 {
    let lo = 0;
    let hi = lineCount(high) - 1;
    if (z >= sampleZ(lo, high)) return lo;
    if (z <= sampleZ(hi, high)) return hi;
    while (hi - lo > 1) {
        const mid = (lo + hi) >> 1;
        if (sampleZ(mid, high) >= z) lo = mid;
        else hi = mid;
    }
    return lo;
}

// The nearest sample to (x, z), searched within ±30 samples of `hint` (the
// last answer); -1 for a fresh search.
export function nearestSample(x: f32, z: f32, hint: i32, high: bool): i32 {
    const n = lineCount(high);
    const c = hint < 0 || hint >= n ? indexAtZ(z, high) : hint;
    let a = c - 30;
    let b = c + 30;
    if (a < 0) a = 0;
    if (b > n - 1) b = n - 1;
    let best = c;
    let bd: f32 = 3.4e38;
    for (let i = a; i <= b; i++) {
        const dx = sampleX(i, high) - x;
        const dz = sampleZ(i, high) - z;
        const d = dx * dx + dz * dz;
        if (d < bd) {
            bd = d;
            best = i;
        }
    }
    return best;
}

// Whether (x, z) is on the high line's side of the split (meaningful
// between SPLIT_S and MERGE_S only).
export function isHighSide(x: f32, z: f32, s: f32): bool {
    if (s < SPLIT_S || s > MERGE_S) return false;
    const il = nearestSample(x, z, indexAtZ(z, false), false);
    const ih = nearestSample(x, z, indexAtZ(z, true), true);
    const dlx = sampleX(il, false) - x;
    const dlz = sampleZ(il, false) - z;
    const dhx = sampleX(ih, true) - x;
    const dhz = sampleZ(ih, true) - z;
    return dhx * dhx + dhz * dhz < dlx * dlx + dlz * dlz;
}

// The first safe point at or after `s` (+5 m, docs/COURSE.md, section 5).
export function respawnAt(s: f32, high: bool, out: LinePoint): void {
    let i: i32;
    if (!high || s < SPLIT_S) {
        i = <i32>Mathf.ceil(s + 5);
        if (high && i >= SPLIT_I) i = SPLIT_I + (i - SPLIT_I) * HIGH_N / (MERGE_I - SPLIT_I + 1);
    } else if (s <= MERGE_S) {
        const sh = (s - SPLIT_S) * HIGH_LENGTH_DATA / (MERGE_S - SPLIT_S);
        i = SPLIT_I + <i32>Mathf.ceil(sh + 5);
    } else {
        i = <i32>Mathf.ceil(s + 5) - MERGE_I - 1 + SPLIT_I + HIGH_N;
    }
    const n = lineCount(high);
    if (i < 0) i = 0;
    for (; i < n - 1; i++) {
        lineSample(i, high, out);
        if (out.safe) return;
    }
    lineSample(n - 1, high, out);
}

// ---- rails, boxes, logs (polylines sampled every 0.25 m) -----------------------
export const RAIL_RAIL: i32 = 1;
export const RAIL_BOX: i32 = 2;
export const RAIL_LOG: i32 = 3;
export const RAIL_KINKED: i32 = 16;    // flags
export const RAIL_RAINBOW: i32 = 32;

export function railCount(): i32 {
    return RAIL_N;
}

export function railKind(r: i32): i32 {
    return RAIL_KIND[r];
}

export function railFlags(r: i32): i32 {
    return RAIL_FLAGS[r];
}

export function railPointCount(r: i32): i32 {
    return RAIL_COUNT[r];
}

// The rail's top at point i: writes x, y, z into out (a LinePoint's x, y, z;
// its tangent into tx, ty, tz).
export function railPoint(r: i32, i: i32, out: LinePoint): void {
    const n = RAIL_COUNT[r];
    if (i < 0) i = 0;
    if (i >= n) i = n - 1;
    const p = (RAIL_START[r] + i) * 3;
    out.x = RAIL_PTS[p];
    out.y = RAIL_PTS[p + 1];
    out.z = RAIL_PTS[p + 2];
    const a = (RAIL_START[r] + (i > 0 ? i - 1 : i)) * 3;
    const b = (RAIL_START[r] + (i < n - 1 ? i + 1 : i)) * 3;
    let tx = RAIL_PTS[b] - RAIL_PTS[a];
    let ty = RAIL_PTS[b + 1] - RAIL_PTS[a + 1];
    let tz = RAIL_PTS[b + 2] - RAIL_PTS[a + 2];
    const l = Mathf.sqrt(tx * tx + ty * ty + tz * tz);
    out.tx = tx / l;
    out.ty = ty / l;
    out.tz = tz / l;
    out.s = RAIL_S0[r] + <f32>i * 0.25;
    out.width = 0;
    out.section = 4;
    out.safe = false;
    out.high = false;
}

// The rails whose box comes within `radius` of (x, z): writes their indices
// into `out`, returns how many (at most out.length).
export function railsNear(x: f32, z: f32, radius: f32, out: StaticArray<i32>): i32 {
    let n = 0;
    for (let r = 0; r < RAIL_N && n < out.length; r++) {
        const b = r * 4;
        if (x >= RAIL_AABB[b] - radius && x <= RAIL_AABB[b + 1] + radius &&
            z >= RAIL_AABB[b + 2] - radius && z <= RAIL_AABB[b + 3] + radius) {
            out[n++] = r;
        }
    }
    return n;
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

export function obstacleCount(): i32 {
    return OBS_N;
}

export function obstacle(i: i32, out: Obstacle): void {
    const b = i * 5;
    out.x = OBS[b];
    out.z = OBS[b + 1];
    out.radius = OBS[b + 2];
    out.bottom = OBS[b + 3];
    out.top = OBS[b + 4];
    out.rock = OBS_ROCK[i] != 0;
}

const OBS_REACH: f32 = 2;   // the largest obstacle radius, rounded up

export function obstaclesNear(x: f32, z: f32, radius: f32, out: StaticArray<i32>): i32 {
    const rows = OBS_BLOCK.length - 1;
    let b0 = <i32>Mathf.floor((GRID_Z0 - (z + radius + OBS_REACH)) / BLOCK_M);
    let b1 = <i32>Mathf.floor((GRID_Z0 - (z - radius - OBS_REACH)) / BLOCK_M);
    if (b0 < 0) b0 = 0;
    if (b1 > rows - 1) b1 = rows - 1;
    if (b1 < b0) return 0;
    let n = 0;
    const end = OBS_BLOCK[b1 + 1];
    for (let i = OBS_BLOCK[b0]; i < end && n < out.length; i++) {
        const k = i * 5;
        const dx = OBS[k] - x;
        const dz = OBS[k + 1] - z;
        const reach = radius + OBS[k + 2];
        if (dx * dx + dz * dz < reach * reach) out[n++] = i;
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
    return FEAT_N;
}

export function feature(i: i32, out: Feature): void {
    out.kind = FEAT_KIND[i];
    out.s = FEAT_S[i];
    out.x = FEAT_X[i];
    out.high = FEAT_HIGH[i] != 0;
    out.lipHeight = FEAT_LIPH[i];
    out.lipAngle = FEAT_LIPA[i];
    out.designSpeed = FEAT_V[i];
    out.airTime = FEAT_AIR[i];
    out.rail = FEAT_RAILI[i];
}

// ---- zones -----------------------------------------------------------------
// Inside a fall zone (under a cliff, out of bounds): a crash with respawn.
export function inFallZone(x: f32, y: f32, z: f32): bool {
    // beyond the terrain's band: out of bounds
    const fr = (GRID_Z0 - z) / GRID_STEP;
    const r = <i32>Mathf.floor(fr);
    if (r < 0 || r >= GRID_ROWS) return true;
    const c = (x - GRID_X0) / GRID_STEP;
    if (c < <f32>(ROW_C0[r] + 2) || c > <f32>(ROW_C0[r] + ROW_N[r] - 3)) return true;
    for (let i = 0; i < FALL_N; i++) {
        const b = i * 7;
        const px = x - FALL[b];
        const pz = z - FALL[b + 1];
        const u = px * FALL[b + 2] + pz * FALL[b + 3];
        if (u >= FALL[b + 4] && u <= FALL[b + 5] && y < FALL[b + 6]) return true;
    }
    return false;
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

const SUN_STRIDE: i32 = 20;

function sunKey(a: i32, b: i32, t: f32, f: i32): f32 {
    const va = SUN_K[a * SUN_STRIDE + f];
    return va + (SUN_K[b * SUN_STRIDE + f] - va) * t;
}

export function sunAt(s: f32, out: Sun): void {
    let a = 0;
    while (a < SUN_N - 2 && s > SUN_S[a + 1]) a++;
    const b = a + 1;
    let t = (s - SUN_S[a]) / (SUN_S[b] - SUN_S[a]);
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    const dx = sunKey(a, b, t, 0);
    const dy = sunKey(a, b, t, 1);
    const dz = sunKey(a, b, t, 2);
    const l = Mathf.sqrt(dx * dx + dy * dy + dz * dz);
    out.dirX = dx / l;
    out.dirY = dy / l;
    out.dirZ = dz / l;
    out.sunR = sunKey(a, b, t, 3);
    out.sunG = sunKey(a, b, t, 4);
    out.sunB = sunKey(a, b, t, 5);
    out.zenithR = sunKey(a, b, t, 6);
    out.zenithG = sunKey(a, b, t, 7);
    out.zenithB = sunKey(a, b, t, 8);
    out.horizonR = sunKey(a, b, t, 9);
    out.horizonG = sunKey(a, b, t, 10);
    out.horizonB = sunKey(a, b, t, 11);
    out.skyAmbR = sunKey(a, b, t, 12);
    out.skyAmbG = sunKey(a, b, t, 13);
    out.skyAmbB = sunKey(a, b, t, 14);
    out.groundAmbR = sunKey(a, b, t, 15);
    out.groundAmbG = sunKey(a, b, t, 16);
    out.groundAmbB = sunKey(a, b, t, 17);
    out.fogBegin = sunKey(a, b, t, 18);
    out.fogEnd = sunKey(a, b, t, 19);
}
