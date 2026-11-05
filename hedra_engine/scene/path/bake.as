// Milestone 32: baking and sampling a Curve3D as Godot 4.4 does
// (scene/resources/curve.cpp: Curve3D::_bake, _find_interval,
// _sample_baked, _sample_posture, sample_baked_with_rotation, ...), in f32
// as Godot's real_t and in Godot's operation order (./math.as), so that a
// PathFollow3D stands where Godot's would (tests/path/godot_match_test.as
// checks against Godot's own answers, tests/fixtures/path/godot_curves.json).
//
// Every function but bakeCurve, samplePoint, samplef and the tessellations
// reads the bake, so takes a curve whose bake is current (Curve3D.bake()
// first, as the curve's methods do).
//
// Allocation: the bake writes into the curve's own arrays, emptied and
// filled again, so it allocates only when a curve bakes to more points than
// it ever had (the arrays keep their capacity); a sample, a closest point
// or a posture allocates nothing, which is what lets a PathFollow3D move
// every frame under the stub allocator that never frees. Godot keeps the
// midpoints of each segment in an ordered map before writing them out; the
// recursion here writes each midpoint as it is made, left half first, which
// is the map's order (a midpoint's parameter lies between its halves'), so
// no map is needed.
//
// Godot's error prints (a non-finite offset, "Zero length interval", too
// few points) are silent here: the values Godot returns with them are
// returned.

import { Mat3, Mat4, Vec3, cosf } from "../../base/vecmath";
import { CURVE_POINT_STRIDE, Curve3D } from "./curve3d";
import {
    FLT_EPSILON, UNIT_EPSILON, axisAngle, basisMul, basisSlerp, basisXform, bezierInterpolate, calculateTangent,
    cubicInterpolate, isEqualApprox, lengthOf, lengthSquared, lerpF, lerpV, lookingAt, normalized, orthonormalized,
    quatAngle, rotateToAlign, sign,
} from "./math";

const IDENTITY3: Mat3 = Mat3(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));

function vecAt(a: Array<f32>, i: i32): Vec3 {
    return Vec3(unchecked(a[i * 3]), unchecked(a[i * 3 + 1]), unchecked(a[i * 3 + 2]));
}

function setVecAt(a: Array<f32>, i: i32, v: Vec3): void {
    unchecked(a[i * 3] = v.x);
    unchecked(a[i * 3 + 1] = v.y);
    unchecked(a[i * 3 + 2] = v.z);
}

function pushVec(a: Array<f32>, v: Vec3): void {
    a.push(v.x);
    a.push(v.y);
    a.push(v.z);
}

// Control point i's position, in handle and out handle (the out handle and
// in handle relative to the position, as Godot keeps them).
function pointPos(c: Curve3D, i: i32): Vec3 {
    const b = i * CURVE_POINT_STRIDE + 6;
    const p = c.points;
    return Vec3(<f32>unchecked(p[b]), <f32>unchecked(p[b + 1]), <f32>unchecked(p[b + 2]));
}

function pointIn(c: Curve3D, i: i32): Vec3 {
    const b = i * CURVE_POINT_STRIDE;
    const p = c.points;
    return Vec3(<f32>unchecked(p[b]), <f32>unchecked(p[b + 1]), <f32>unchecked(p[b + 2]));
}

function pointOut(c: Curve3D, i: i32): Vec3 {
    const b = i * CURVE_POINT_STRIDE + 3;
    const p = c.points;
    return Vec3(<f32>unchecked(p[b]), <f32>unchecked(p[b + 1]), <f32>unchecked(p[b + 2]));
}

function pointTilt(c: Curve3D, i: i32): f32 {
    return i < c.tilts.length ? <f32>unchecked(c.tilts[i]) : 0;
}

// The segment a recursion is cutting: its Bézier's four control points (in
// Godot's form: start, start + out, end + in, end), the end points' tilts,
// and where the midpoints go. Held in one object made once, since a
// recursion cannot capture.
class Segment {
    a: Vec3 = Vec3(0, 0, 0);
    c1: Vec3 = Vec3(0, 0, 0);
    c2: Vec3 = Vec3(0, 0, 0);
    b: Vec3 = Vec3(0, 0, 0);
    tiltA: f32 = 0;
    tiltB: f32 = 0;
    // The bake's limit: a piece longer than this is cut (even-length), or
    // the cosine of the tessellation's angle tolerance.
    limit: f32 = 0;
    maxDepth: i32 = 0;
    // The curve being baked (its arrays receive the midpoints), or null
    // for a tessellation into `out`.
    curve: Curve3D? = null;
    out: Array<f32> = [];
    count: i32 = 0;

    set(c: Curve3D, i: i32, j: i32): void {
        const a = pointPos(c, i);
        const b = pointPos(c, j);
        this.a = a;
        this.c1 = a + pointOut(c, i);
        this.c2 = b + pointIn(c, j);
        this.b = b;
        this.tiltA = pointTilt(c, i);
        this.tiltB = pointTilt(c, j);
    }
}

const SEG = new Segment();

// One midpoint of the bake at parameter t: its point, tangent and tilt.
function bakeMidpoint(c: Curve3D, t: f32, mid: Vec3): void {
    const s = SEG;
    pushVec(c.bakedPoints, mid);
    pushVec(c.bakedForwards, calculateTangent(s.a, s.c1, s.c2, s.b, t));
    c.bakedTilts.push(lerpF(s.tiltA, s.tiltB, t));
    s.count++;
}

// Curve3D::_bake_segment3d_even_length: halved while a piece's chord is
// longer than the bake interval, ten times at most.
function evenLength(begin: f32, end: f32, depth: i32): void {
    const s = SEG;
    const beg = bezierInterpolate(s.a, s.c1, s.c2, s.b, begin);
    const fin = bezierInterpolate(s.a, s.c1, s.c2, s.b, end);
    const length = lengthOf(fin - beg);
    if (length > s.limit && depth < s.maxDepth) {
        const mp: f32 = (begin + end) * <f32>0.5;
        const mid = bezierInterpolate(s.a, s.c1, s.c2, s.b, mp);
        evenLength(begin, mp, depth + 1);
        const c = s.curve;
        if (c != null) bakeMidpoint(c, mp, mid);
        else {
            pushVec(s.out, mid);
            s.count++;
        }
        evenLength(mp, end, depth + 1);
    }
}

// Curve3D::_bake_segment3d (tessellate): every level down to the deepest is
// visited; a midpoint is kept where the two halves turn by more than the
// tolerance.
function byAngle(begin: f32, end: f32, depth: i32): void {
    const s = SEG;
    const mp: f32 = begin + (end - begin) * <f32>0.5;
    const beg = bezierInterpolate(s.a, s.c1, s.c2, s.b, begin);
    const mid = bezierInterpolate(s.a, s.c1, s.c2, s.b, mp);
    const fin = bezierInterpolate(s.a, s.c1, s.c2, s.b, end);
    const na = normalized(mid - beg);
    const nb = normalized(fin - mid);
    const dp = na.dot(nb);
    if (depth < s.maxDepth) byAngle(begin, mp, depth + 1);
    if (dp < s.limit) {
        pushVec(s.out, mid);
        s.count++;
    }
    if (depth < s.maxDepth) byAngle(mp, end, depth + 1);
}

// Godot's _bake: fills c.bakedPoints, bakedTilts, bakedDists,
// bakedForwards, bakedUps (empty without up_vector_enabled), pointsInCache
// and bakedMaxOfs, and clears c.bakedDirty.
export function bakeCurve(c: Curve3D): void {
    c.bakedDirty = false;
    c.bakedMaxOfs = 0;
    const pts = c.bakedPoints;
    const tilts = c.bakedTilts;
    const dists = c.bakedDists;
    const fwd = c.bakedForwards;
    const ups = c.bakedUps;
    pts.length = 0;
    tilts.length = 0;
    dists.length = 0;
    fwd.length = 0;
    ups.length = 0;
    c.pointsInCache.length = 0;
    const n = c.getPointCount();
    if (n == 0) return;
    if (n == 1) {
        c.pointsInCache.push(0);
        pushVec(pts, pointPos(c, 0));
        tilts.push(pointTilt(c, 0));
        dists.push(0);
        pushVec(fwd, Vec3(0, 0, 1));
        if (c.upVectorEnabled) pushVec(ups, Vec3(0, 1, 0));
        return;
    }

    // Step 1: the points, tangents and tilts, segment by segment.
    const closed = c.closed;
    const intervals = closed ? n : n - 1;
    const seg = SEG;
    seg.curve = c;
    seg.limit = c.bakeInterval;
    seg.maxDepth = 10;
    c.pointsInCache.push(0);
    pushVec(pts, pointPos(c, 0));
    pushVec(fwd, calculateTangent(pointPos(c, 0), pointPos(c, 0) + pointOut(c, 0), pointPos(c, 1) + pointIn(c, 1),
        pointPos(c, 1), 0));
    tilts.push(pointTilt(c, 0));
    let pc = 1;
    for (let i = 0; i < intervals; i++) {
        const j = !closed || i < intervals - 1 ? i + 1 : 0;
        seg.set(c, i, j);
        seg.count = 0;
        evenLength(0, 1, 0);
        pushVec(pts, seg.b);
        pushVec(fwd, calculateTangent(seg.a, seg.c1, seg.c2, seg.b, 1));
        tilts.push(seg.tiltB);
        pc += seg.count + 1;
        c.pointsInCache.push(pc - 1);
    }
    seg.curve = null;

    // The distances along the bake.
    dists.push(0);
    let d: f32 = 0;
    for (let i = 0; i < pc - 1; i++) {
        d = d + lengthOf(vecAt(pts, i + 1) - vecAt(pts, i));
        dists.push(d);
    }
    c.bakedMaxOfs = unchecked(dists[pc - 1]);

    if (!c.upVectorEnabled) return;

    // Step 2: the up vectors, a parallel transport frame (Godot cites
    // Dougan, "The parallel transport frame", Game Programming Gems 2): the
    // first frame looks along the first tangent with +y up (+x when the
    // tangent is within UNIT_EPSILON of vertical), and each next one is the
    // last turned by the least rotation onto the next tangent.
    ups.length = pc * 3;
    const forward0 = vecAt(fwd, 0);
    let prev = <f64>Mathf.abs(forward0.dot(Vec3(0, 1, 0))) > 1.0 - UNIT_EPSILON
        ? lookingAt(forward0, Vec3(1, 0, 0)) : lookingAt(forward0, Vec3(0, 1, 0));
    setVecAt(ups, 0, prev.yAxis);
    for (let idx = 1; idx < pc; idx++) {
        const forward = vecAt(fwd, idx);
        const frame = orthonormalized(rotateToAlign(prev, -prev.zAxis, forward));
        setVecAt(ups, idx, frame.yAxis);
        prev = frame;
    }

    // A loop (the ends meet, their tangents agree) is twisted along its
    // length so that its up vectors meet too.
    if (!isEqualApprox(vecAt(pts, 0), vecAt(pts, pc - 1))) return;
    const forwardEnd = vecAt(fwd, pc - 1);
    if (<f64>forward0.dot(forwardEnd) < 1.0 - UNIT_EPSILON) return;
    const upStart = vecAt(ups, 0);
    const upEnd = vecAt(ups, pc - 1);
    const sg = sign(upEnd.cross(upStart).dot(forward0));
    const fullAngle = quatAngle(upEnd, upStart);
    if (Mathf.abs(fullAngle) < <f32>0.00001) return;
    const maxOfs = c.bakedMaxOfs;
    for (let idx = 1; idx < pc; idx++) {
        const frac = unchecked(dists[idx]) / maxOfs;
        const angle = lerpF(0, fullAngle, frac);
        const twist = axisAngle(vecAt(fwd, idx) * sg, angle);
        setVecAt(ups, idx, basisXform(twist, vecAt(ups, idx)));
    }
}

// Curve3D::_find_interval: the baked piece holding `offset` (a binary
// search on the distances) and how far along it. Answers in these two
// (one sample at a time: nothing is allocated); the index is -1 when the
// offset lies outside the bake (Godot's "Offset out of range").
let intervalIdx: i32 = -1;
let intervalFrac: f32 = 0;

function findInterval(c: Curve3D, offset: f32): void {
    intervalIdx = -1;
    intervalFrac = 0;
    const dists = c.bakedDists;
    const pc = dists.length;
    if (pc < 2) return;
    let start = 0;
    let end = pc;
    let idx = (end + start) / 2;
    while (start < idx) {
        if (offset <= unchecked(dists[idx])) end = idx;
        else start = idx;
        idx = (end + start) / 2;
    }
    if (idx + 1 >= pc) return;
    const begin = unchecked(dists[idx]);
    const fin = unchecked(dists[idx + 1]);
    const span = fin - begin;
    if (offset < begin || offset > fin) return;
    intervalIdx = idx;
    if (span < FLT_EPSILON) {
        // (Godot's "Zero length interval": the middle of it)
        intervalFrac = 0.5;
        return;
    }
    intervalFrac = (offset - begin) / span;
}

// Curve3D::_sample_baked on the interval found.
function sampleInterval(c: Curve3D, cubic: bool): Vec3 {
    const idx = intervalIdx;
    if (idx < 0) return Vec3(0, 0, 0);
    const frac = intervalFrac;
    const r = c.bakedPoints;
    const pc = r.length / 3;
    if (cubic) {
        const pre = idx > 0 ? vecAt(r, idx - 1) : vecAt(r, idx);
        const post = idx < pc - 2 ? vecAt(r, idx + 2) : vecAt(r, idx + 1);
        return cubicInterpolate(vecAt(r, idx), vecAt(r, idx + 1), pre, post, frac);
    }
    return lerpV(vecAt(r, idx), vecAt(r, idx + 1), frac);
}

// Curve3D::_sample_baked_tilt on the interval found.
function tiltInterval(c: Curve3D): f32 {
    const idx = intervalIdx;
    if (idx < 0) return 0;
    return lerpF(unchecked(c.bakedTilts[idx]), unchecked(c.bakedTilts[idx + 1]), intervalFrac);
}

// Curve3D::_compose_posture: the frame at baked point i, looking along its
// tangent with its up vector (+y without up vectors).
function composePosture(c: Curve3D, i: i32): Mat3 {
    const forward = vecAt(c.bakedForwards, i);
    const up = c.upVectorEnabled ? vecAt(c.bakedUps, i) : Vec3(0, 1, 0);
    return lookingAt(forward, up);
}

// Curve3D::_sample_posture on the interval found: the frames at its two
// ends slerped, then turned by the tilt about the tangent.
function postureInterval(c: Curve3D, applyTilt: bool): Mat3 {
    const idx = intervalIdx;
    if (idx < 0) return IDENTITY3;
    const frame = orthonormalized(basisSlerp(composePosture(c, idx), composePosture(c, idx + 1), intervalFrac));
    if (!applyTilt) return frame;
    const tilt = tiltInterval(c);
    const tangent = -frame.zAxis;
    return basisMul(axisAngle(tangent, tilt), frame);
}

// The offset held to the bake (Godot's CLAMP(offset, 0, length)).
function clampOffset(c: Curve3D, offset: f32): f32 {
    const max = c.bakedMaxOfs;
    return offset < 0 ? <f32>0 : (offset > max ? max : offset);
}

// Godot's sample_baked: the point `offset` metres along the bake (held to
// 0 ... the baked length), linearly or cubically between baked points.
export function sampleBaked(c: Curve3D, offset: f32, cubic: bool): Vec3 {
    if (!isFinite(offset)) return Vec3(0, 0, 0);
    const pc = c.bakedPoints.length / 3;
    if (pc == 0) return Vec3(0, 0, 0);
    if (pc == 1) return vecAt(c.bakedPoints, 0);
    findInterval(c, clampOffset(c, offset));
    return sampleInterval(c, cubic);
}

// Godot's sample_baked_with_rotation, as a Mat4 (columns x, y, z, origin):
// one point gives the identity at it, none the identity.
export function sampleBakedWithRotation(c: Curve3D, offset: f32, cubic: bool, applyTilt: bool): Mat4 {
    const pc = c.bakedPoints.length / 3;
    if (!isFinite(offset) || pc == 0) return toMat4(IDENTITY3, Vec3(0, 0, 0));
    if (pc == 1) return toMat4(IDENTITY3, vecAt(c.bakedPoints, 0));
    findInterval(c, clampOffset(c, offset));
    const pos = sampleInterval(c, cubic);
    return toMat4(postureInterval(c, applyTilt), pos);
}

function toMat4(m: Mat3, origin: Vec3): Mat4 {
    return Mat4(m.xAxis.extend(0), m.yAxis.extend(0), m.zAxis.extend(0), origin.extend(1));
}

// Godot's sample_baked_tilt (not script-visible in Godot 4.4, used by
// PathFollow3D).
export function sampleBakedTilt(c: Curve3D, offset: f32): f32 {
    if (!isFinite(offset)) return 0;
    const pc = c.bakedTilts.length;
    if (pc == 0) return 0;
    if (pc == 1) return unchecked(c.bakedTilts[0]);
    findInterval(c, clampOffset(c, offset));
    return tiltInterval(c);
}

// Godot's sample_baked_up_vector: +y without up vectors.
export function sampleBakedUpVector(c: Curve3D, offset: f32, applyTilt: bool): Vec3 {
    if (!isFinite(offset) || !c.upVectorEnabled) return Vec3(0, 1, 0);
    const count = c.bakedUps.length / 3;
    if (count == 1) return vecAt(c.bakedUps, 0);
    findInterval(c, clampOffset(c, offset));
    return postureInterval(c, applyTilt).yAxis;
}

// Godot's get_closest_offset and get_closest_point: each baked piece's
// nearest point to `to`, the nearest of them (the first on a tie).
export function closestOffset(c: Curve3D, to: Vec3): f32 {
    const pc = c.bakedPoints.length / 3;
    if (pc <= 1) return 0;
    const r = c.bakedPoints;
    let nearest: f32 = 0;
    let nearestDist: f32 = -1;
    for (let i = 0; i < pc - 1; i++) {
        const offset = unchecked(c.bakedDists[i]);
        const interval = unchecked(c.bakedDists[i + 1]) - offset;
        const origin = vecAt(r, i);
        const direction = (vecAt(r, i + 1) - origin) / interval;
        const d = clampF((to - origin).dot(direction), 0, interval);
        const proj = origin + direction * d;
        const dist = lengthSquared(to - proj);
        if (nearestDist < 0 || dist < nearestDist) {
            nearest = offset + d;
            nearestDist = dist;
        }
    }
    return nearest;
}

export function closestPoint(c: Curve3D, to: Vec3): Vec3 {
    const pc = c.bakedPoints.length / 3;
    if (pc == 0) return Vec3(0, 0, 0);
    if (pc == 1) return vecAt(c.bakedPoints, 0);
    const r = c.bakedPoints;
    let nearest = Vec3(0, 0, 0);
    let nearestDist: f32 = -1;
    for (let i = 0; i < pc - 1; i++) {
        const interval = unchecked(c.bakedDists[i + 1]) - unchecked(c.bakedDists[i]);
        const origin = vecAt(r, i);
        const direction = (vecAt(r, i + 1) - origin) / interval;
        const d = clampF((to - origin).dot(direction), 0, interval);
        const proj = origin + direction * d;
        const dist = lengthSquared(to - proj);
        if (nearestDist < 0 || dist < nearestDist) {
            nearest = proj;
            nearestDist = dist;
        }
    }
    return nearest;
}

// Godot's CLAMP macro (a NaN goes through, as in Godot).
function clampF(v: f32, lo: f32, hi: f32): f32 {
    return v < lo ? lo : (v > hi ? hi : v);
}

// Godot's get_point_baked_posture (the editor's tilt handles): the frame
// at control point `index`'s baked point; the identity for an index the
// bake does not have.
export function pointBakedPosture(c: Curve3D, index: i32, applyTilt: bool): Mat3 {
    if (index < 0 || index >= c.pointsInCache.length) return IDENTITY3;
    const frame = composePosture(c, unchecked(c.pointsInCache[index]));
    if (!applyTilt) return frame;
    const tilt = pointTilt(c, index);
    return basisMul(axisAngle(-frame.zAxis, tilt), frame);
}

// Godot's sample(index, t): on the Bézier segment from point `index`; an
// index past the last segment gives the last point on an open curve and
// the closing segment on a closed one, a negative index the first point.
export function samplePoint(c: Curve3D, index: i32, t: f32): Vec3 {
    const pc = c.getPointCount();
    if (pc == 0) return Vec3(0, 0, 0);
    if (index >= pc - 1) {
        if (!c.closed) return pointPos(c, pc - 1);
        index = pc - 1;
    } else if (index < 0) {
        return pointPos(c, 0);
    }
    const j = !c.closed || index < pc - 1 ? index + 1 : 0;
    const p0 = pointPos(c, index);
    const p1 = p0 + pointOut(c, index);
    const p3 = pointPos(c, j);
    const p2 = p3 + pointIn(c, j);
    return bezierInterpolate(p0, p1, p2, p3, t);
}

// Godot's samplef: the integer part picks the segment, the fraction the t.
export function samplef(c: Curve3D, findex: f32): Vec3 {
    const n = <f32>c.getPointCount();
    if (findex < 0) findex = 0;
    else if (findex >= n) findex = n;
    return samplePoint(c, <i32>findex, findex % <f32>1);
}

// Godot's tessellate and tessellate_even_length: xyz numbers into `out`
// (cleared first); returns the number of points.
export function tessellateInto(c: Curve3D, maxStages: i32, toleranceDegrees: f32, out: Array<f32>): i32 {
    out.length = 0;
    const n = c.getPointCount();
    if (n == 0) return 0;
    const seg = SEG;
    seg.curve = null;
    seg.out = out;
    seg.maxDepth = maxStages;
    // Math::cos(Math::deg_to_rad(tolerance)), deg_to_rad in float.
    seg.limit = cosf(toleranceDegrees * <f32>(Math.PI / 180.0));
    seg.count = 1;
    pushVec(out, pointPos(c, 0));
    const intervals = c.closed ? n : n - 1;
    for (let i = 0; i < intervals; i++) {
        const j = !c.closed || i < intervals - 1 ? i + 1 : 0;
        seg.set(c, i, j);
        byAngle(0, 1, 0);
        pushVec(out, seg.b);
        seg.count++;
    }
    const count = seg.count;
    seg.out = EMPTY;
    return count;
}

export function tessellateEvenLengthInto(c: Curve3D, maxStages: i32, length: f32, out: Array<f32>): i32 {
    out.length = 0;
    const n = c.getPointCount();
    if (n < 2) return 0;
    const seg = SEG;
    seg.curve = null;
    seg.out = out;
    seg.maxDepth = maxStages;
    seg.limit = length;
    seg.count = 1;
    pushVec(out, pointPos(c, 0));
    const intervals = c.closed ? n : n - 1;
    for (let i = 0; i < intervals; i++) {
        const j = !c.closed || i < intervals - 1 ? i + 1 : 0;
        seg.set(c, i, j);
        evenLength(0, 1, 0);
        pushVec(out, seg.b);
        seg.count++;
    }
    const count = seg.count;
    seg.out = EMPTY;
    return count;
}

// What the segment holds between tessellations (not the caller's array).
const EMPTY: Array<f32> = [];
