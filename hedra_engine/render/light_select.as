// Which lights a frame draws from its camera, and which each item draws
// (milestone 59; light_pool.as says what a frame carries). The renderer
// calls planLightPool for each view before it plans that view's shadows,
// and assignItemLights right before it writes the view's object uniforms
// (another view of the same items, a probe's capture face or a viewport,
// may have run in between); `inspect --lights` and `--stats` call
// prepareLights to count.
//
// The pool (planLightPool): the frame's lights in the scene's order
// (RenderFrame.lights, the visible lights of the frame's world), less the
// omni and spot lights of no range and those whose sphere of reach has its
// box wholly outside the camera's frustum (they light no pixel the view
// draws). Past MAX_FRAME_LIGHTS the directional lights are kept, then the
// omni and spot lights nearest the eye by the distance to their reach
// (|position - eye| - range, 0 inside it), ties in the scene's order, and
// the pool lists the kept ones in the scene's order all the same. A
// probe's capture looks every way (planLightPoolAround): no frustum test,
// the distance from the probe's origin.
//
// Each item (assignItemLights): every pool entry that may light its box.
// A directional light reaches every item, and every light an item without
// a box; an omni light reaches a box its range meets (the squared distance
// from the light to the box against the range, widened by 1e-4 of it and
// 1e-4 m for f32 rounding); a spot light also needs its cone, its half
// angle widened by 1e-3 rad, to meet the box's bounding sphere (centre c,
// radius rho: half the box's diagonal), and a cone of 89.9 degrees or more
// (or under 0.08, which the shader's rim lights everywhere: coneEverywhere)
// meets every box. Conservative: a light it rejects gives exactly 0 to
// every fragment of the item (Godot's window, surface.wgsl
// omni_attenuation, is 0 from the range on; the spot factor is 0 outside
// the cone), so leaving it out changes no pixel. An item the main pass
// draws lightmapped (frame.as lightmapDrawKind BAKED) is reached by no
// static light (bakeMode LIGHT_BAKE_STATIC, directional ones too): its
// shading skips them (surface.wgsl's lightmap entry points; the lightmap
// holds their light), so they neither take its slots nor count towards its
// budget. 8 or fewer reaching: all of them, in pool order. More: every
// directional light (pool order, 8 at most), then the omni and spot lights
// of the largest score (ties in pool order) until 8, listed in pool order.
// An item without a mesh, or of another world than the frame's, draws
// none; an instanced item (a MultiMesh, particles) is one item, its box
// holding every instance.
//
// The pool's and each list's order is the scene's, so an item sums its
// lights in the order the shader summed the frame's before lights per
// object: a frame of 8 lights or fewer draws byte for byte as it did.
//
// The cone test is Bart Wronski's sphere against a cone: with v = c - p, a =
// v . dir (along the axis) and b = sqrt(|v|^2 - a^2) (off it), the sphere
// is outside when b cos(half) - a sin(half) > rho, which is |v| sin(angle
// - half), the angle between v and the axis exceeding the half angle by
// more than the sphere's angular radius asin(rho / |v|); or when a < -rho,
// the sphere wholly behind the light (the cone, narrower than 90 degrees,
// is wholly in front). It rejects only spheres the cone misses, keeps every
// sphere the light is inside, and costs one square root, no division and
// no inverse trigonometry (64 spot lights over 1,000 items is 64,000
// pairs).
//
// The score ranks the omni and spot lights reaching an item past its
// budget by their contribution at the box's nearest point, at distance d
// from the light to the box itself (0 inside it; not to the box's centre
// nor to its bounding sphere: a light level with a long wall ranks by how
// near it is to the wall, wherever along it; without a box, the distance
// to its transform's origin):
// |energy| x luminance(colour) x (1 - x^4)^2 x max(d, 0.1)^-attenuation
// with x = min(d / range, 1) (Godot's omni attenuation; the 0.1 m floor
// ranks the lights touching an item by their energy rather than by
// infinity). It is kept squared, from the reach test's squared distance:
// the square ranks the same and needs no root (x^2 = d^2 / range^2, and
// max(d, 0.1)^-2a = max(d^2, 0.01)^-a, without a pow for the attenuations
// of 0, 1 and 2). Equal scores rank in pool order. All arithmetic is f32 in
// a fixed order; lightReaches and lightScore run the same helpers on a
// LightDesc as assignItemLights on the plan's flat copy, so they agree bit
// for bit.
//
// The cost is in the pairs (64 lights over 1,000 items is 64,000), so an
// item scores no light until more than its slots reach it: the first ones
// are kept with their distance alone (an item within its budget draws them
// all, unscored), and only the one past the budget scores them and itself;
// from then on each reaching light is scored and replaces the one of the
// best kept so far that ranks last when it ranks before it (equal scores
// rank in pool order).
//
// Clusters cut the pairs. Once the pool has more than MAX_OBJECT_LIGHTS
// omni and spot lights (so that an item may have to choose), the frame
// CLUSTER_MIN_PAIRS pairs of them and its items, and CLUSTER_MIN_ITEMS
// items have a box, those items are put in the cells of
// a grid over their centres, about CLUSTER_ITEMS a cell (clusterItems; an
// item larger than a cell is matched alone, as are the items without a
// box). Each cluster tests every light once against its own box and the
// spheres of its items (clusterEntries): a light missing it misses every
// item in it; one whose range and cone hold all of it reaches every item
// without a test; and each light's score at any of its items is at most
// its score at the cluster's nearest point. An item then goes through the
// cluster's lights in the order of those bounds, best first, as matchItem
// would through all of them, and stops once its kept lights all score
// more than any light left could at it (matchInCluster): those are only
// counted, without a test when they reach every item. The best of a set
// does not depend on the order it is looked at in, so the lists, the
// counts and the pictures are the ones matchItem gives (a test checks it
// on random scenes); the worst case of 64 lights over 1,000 items scores
// about 15 lights an item rather than 64 (tests/lights/bench_test.as: 2.2
// ms a frame rather than 5.0 for omni lights, 2.7 rather than 6.6 for
// spots, on an Apple M5 Pro).

// Allocates nothing once warm: the plan's storage is made once (its
// Arrays' lengths are set, never their capacity shrunk), the items' fields
// set in place (the editor's and the demo's soaks hold every frame to 0
// bytes).

import { MAT4_IDENTITY, Mat4, Vec3, Vec4, cosf, powf, sinf, toRadians } from "../base/vecmath";
import { Bounds } from "./camera";
import { Frustum, frameViewProj } from "./cull";
import {
    DrawItem, LIGHTMAP_DRAW_BAKED, LIGHT_BAKE_STATIC, LIGHT_DIRECTIONAL, LIGHT_SPOT, LightDesc, RenderFrame,
    lightmapDrawKind,
} from "./frame";
import {
    ENTRY_WHOLE, LIGHT_TEST_FLOATS, LightPlan, MAX_FRAME_LIGHTS, MAX_OBJECT_LIGHTS, MAX_POOL_DIRECTIONAL,
} from "./light_pool";
import {
    LANE_LIGHTS, LANE_LIGHT_CLUSTERS, LaneJob, LaneResult, LaneResultWriter, UnitClaims, jobs, unitBegin, unitCount, unitEnd,
} from "../base/jobs";

// The widest cone tested (degrees): a spot of this half angle or more
// lights a whole half space, near enough, so every box is reached.
const SPOT_WIDEST: f32 = 89.9;
// The margins of the reach tests (the f32 rounding of the shader's own
// distances and angles): a range's relative and absolute widening (m), and
// a cone's (radians).
const RANGE_SLACK: f32 = 1e-4;
const RANGE_SLACK_M: f32 = 1e-4;
const CONE_SLACK: f32 = 1e-3;
// The square of the score's distance floor (0.1 m).
const SCORE_FLOOR2: f32 = 0.01;
// The cone cosine (LightPlan.tests) of an omni light, and of a cone every
// box meets.
const CONE_WIDE: f32 = -2;
// Clusters (the header): the items a cell holds, on average; the fewest
// items of a box for which the frame is clustered at all; the most cells
// along one axis of the grid; the widening of a cluster's score bounds
// (relative: the f32 rounding of rankAt, its pow) and the margin of its
// cone tests (relative to the distance, and in metres).
const CLUSTER_ITEMS = 16;
const CLUSTER_MIN_ITEMS = 32;
// The fewest pairs of an omni or spot light and an item for which the
// frame is clustered: below it the pairs are few and most are a miss at
// the first test (the lights sample's 40 lights over 125 items, 5,000
// pairs, are chosen in 0.1 ms either way, a little faster alone).
const CLUSTER_MIN_PAIRS = 8192;
const CLUSTER_AXIS_CELLS: f64 = 256;
const BOUND_SLACK: f32 = 1e-4;
const CLUSTER_MARGIN: f32 = 1e-4;
// The most a light's least score at a cluster's item can be, as a part of
// its bound (rankAt at the farthest point is at most at the nearest).
const LOW_OF_BEST: f32 = (<f32>1 - BOUND_SLACK) / (<f32>1 + BOUND_SLACK);
// MatchScratch.entries: the position in `order`, less ENTRY_WHOLE.
const ENTRY_POSITION = ENTRY_WHOLE - 1;

// LightPlan.tests, by light: where each number is.
const T_X = 0;
const T_Y = 1;
const T_Z = 2;
const T_REACH2 = 3;
const T_DIR_X = 4;
const T_DIR_Y = 5;
const T_DIR_Z = 6;
const T_COS = 7;
const T_SIN = 8;
const T_WEIGHT2 = 9;
const T_INV_RANGE2 = 10;
const T_ATTENUATION = 11;

// The camera's frustum, set by every planLightPool (kept: no allocation).
const lightFrustum = new Frustum();

// Chooses the pool of `f`'s lights for its camera into `out` (reset first)
// and returns it. `cullFrustum` false: planLightPoolAround the camera's
// eye. Leaves the items alone (assignItemLights sets their lists).
export function planLightPool(f: RenderFrame, out: LightPlan, cullFrustum: bool = true): LightPlan {
    if (!cullFrustum) return planLightPoolAround(f, f.camera.eye, out);
    lightFrustum.setFrom(frameViewProj(f));
    return planPool(f, f.camera.eye, true, out);
}

// The pool of `f`'s lights seen every way from `eye` (a reflection probe's
// capture, on the GPU and in the bake's trace, which look every way from
// the probe's origin): no frustum test, every light a candidate, the
// nearest to `eye` kept past MAX_FRAME_LIGHTS. `out.everyWay` is set.
export function planLightPoolAround(f: RenderFrame, eye: Vec3, out: LightPlan): LightPlan {
    planPool(f, eye, false, out);
    out.everyWay = true;
    return out;
}

// The pool (the header's rule) for `eye`, with the frustum test against
// lightFrustum when `cull`, then the flat per-entry copy assignItemLights
// reads.
function planPool(f: RenderFrame, eye: Vec3, cull: bool, out: LightPlan): LightPlan {
    out.reset();
    const lights = f.lights;
    const n = lights.length;

    // 1. The candidates, in the scene's order, and their keys (-1 for a
    // directional light, so it is kept before any other).
    const cand = out.candidates;
    const keys = out.keys;
    cand.length = 0;
    keys.length = 0;
    for (let i = 0; i < n; i++) {
        const l = unchecked(lights[i]);
        if (l.kind == LIGHT_DIRECTIONAL) {
            cand.push(i);
            keys.push(-1);
            continue;
        }
        const r = l.range;
        if (!(r > 0)) continue;
        const p = l.position;
        if (cull && !lightFrustum.intersects(Bounds(p - Vec3(r, r, r), p + Vec3(r, r, r)))) continue;
        let key = p.distance(eye) - r;
        if (key < 0) key = 0;
        // A light at no number goes last (NaN would make the order depend
        // on where it falls).
        else if (!(key >= 0)) key = f32.POSITIVE_INFINITY;
        cand.push(i);
        keys.push(key);
    }
    const visible = cand.length;
    out.visible = visible;

    // 2. The pool: every candidate, or past MAX_FRAME_LIGHTS the smallest
    // keys (ties in the scene's order), listed in the scene's order.
    if (visible <= MAX_FRAME_LIGHTS) {
        for (let k = 0; k < visible; k++) unchecked(out.pool[k] = unchecked(cand[k]));
        out.count = visible;
    } else {
        // By insertion into a sorted list (a candidate equal to one already
        // there goes after it: the scene's order), then put back in the
        // scene's order (decal_select.as does the same).
        const best = out.nearest;
        let m = 0;
        for (let k = 0; k < visible; k++) {
            const dk = unchecked(keys[k]);
            if (m == MAX_FRAME_LIGHTS && dk >= unchecked(keys[unchecked(best[m - 1])])) continue;
            let at = m < MAX_FRAME_LIGHTS ? m : MAX_FRAME_LIGHTS - 1;
            while (at > 0 && unchecked(keys[unchecked(best[at - 1])]) > dk) {
                unchecked(best[at] = unchecked(best[at - 1]));
                at--;
            }
            unchecked(best[at] = k);
            if (m < MAX_FRAME_LIGHTS) m++;
        }
        for (let k = 1; k < m; k++) {
            const v = unchecked(best[k]);
            let at = k;
            while (at > 0 && unchecked(best[at - 1]) > v) {
                unchecked(best[at] = unchecked(best[at - 1]));
                at--;
            }
            unchecked(best[at] = v);
        }
        // The pool, and the candidates left out in the scene's order (best
        // is ascending now: one walk over both).
        let j = 0;
        for (let k = 0; k < visible; k++) {
            if (j < m && unchecked(best[j]) == k) {
                unchecked(out.pool[j] = unchecked(cand[k]));
                j++;
            } else {
                out.droppedLights.push(unchecked(cand[k]));
            }
        }
        out.count = m;
        out.dropped = visible - m;
    }

    // 3. Per entry: the directional list, the kind, the sphere and the
    // weights, and the bits; per omni or spot light, what the reach tests
    // and the score read (one run of numbers a light), those that are not
    // static first, then the static ones, each in pool order (an item drawn
    // lightmapped tests only the first `liveOthers`: no pair is spent on a
    // light its shading skips).
    const count = out.count;
    const sph = out.spheres;
    const wts = out.weights;
    let others = 0;
    let dirTotal = 0;
    let dirBits: u64 = 0, dirBitsKept: u64 = 0;
    let liveTotal = 0;
    let liveBits: u64 = 0, liveBitsKept: u64 = 0;
    let statics = false;
    for (let k = 0; k < count; k++) {
        const l = unchecked(lights[unchecked(out.pool[k])]);
        const kind = l.kind;
        const p = l.position;
        unchecked(out.kinds[k] = kind);
        const bit = (<u64>1) << <u64>k;
        const o = k * 8;
        unchecked(sph[o] = p.x);
        unchecked(sph[o + 1] = p.y);
        unchecked(sph[o + 2] = p.z);
        unchecked(sph[o + 3] = l.range);
        unchecked(wts[2 * k] = lightWeight(l));
        unchecked(wts[2 * k + 1] = l.attenuation);
        const isStatic = l.bakeMode == LIGHT_BAKE_STATIC;
        if (isStatic) statics = true;
        if (kind == LIGHT_SPOT) {
            const dir = spotDirection(l);
            unchecked(sph[o + 4] = dir.x);
            unchecked(sph[o + 5] = dir.y);
            unchecked(sph[o + 6] = dir.z);
            // (the angle's magnitude: the shader's cos(spot_angle) ignores
            // its sign, so a key or a binding taking it below 0 lights the
            // same cone)
            unchecked(sph[o + 7] = cosf(toRadians(min<f32>(Mathf.abs(l.spotAngle), SPOT_WIDEST))));
        } else {
            unchecked(sph[o + 4] = 0);
            unchecked(sph[o + 5] = 0);
            unchecked(sph[o + 6] = 0);
            unchecked(sph[o + 7] = -1);
        }
        if (kind == LIGHT_DIRECTIONAL) {
            if (out.dirCount < MAX_POOL_DIRECTIONAL) {
                unchecked(out.dirs[out.dirCount] = k);
                out.dirCount++;
            }
            if (dirTotal < MAX_OBJECT_LIGHTS) dirBitsKept |= bit;
            dirBits |= bit;
            dirTotal++;
            if (!isStatic) {
                if (liveTotal < MAX_OBJECT_LIGHTS) liveBitsKept |= bit;
                liveBits |= bit;
                liveTotal++;
            }
            continue;
        }
        if (!isStatic) {
            writeTests(out, others, l, k);
            others++;
        }
    }
    out.liveOthers = others;
    if (statics) {
        for (let k = 0; k < count; k++) {
            const l = unchecked(lights[unchecked(out.pool[k])]);
            if (l.kind == LIGHT_DIRECTIONAL || l.bakeMode != LIGHT_BAKE_STATIC) continue;
            writeTests(out, others, l, k);
            others++;
        }
    }
    out.others = others;
    out.dirTotal = dirTotal;
    out.dirBits = dirBits;
    out.dirBitsKept = dirBitsKept;
    out.liveDirTotal = liveTotal;
    out.liveDirBits = liveBits;
    out.liveDirBitsKept = liveBitsKept;
    out.statics = statics;
    return out;
}

// The reach tests' and the score's numbers of omni or spot light `l`, pool
// entry `k`, at position `j` of LightPlan.order.
function writeTests(out: LightPlan, j: i32, l: LightDesc, k: i32): void {
    const tests = out.tests;
    const p = l.position;
    const t = j * LIGHT_TEST_FLOATS;
    unchecked(tests[t + T_X] = p.x);
    unchecked(tests[t + T_Y] = p.y);
    unchecked(tests[t + T_Z] = p.z);
    unchecked(tests[t + T_REACH2] = reachSquared(l.range));
    if (l.kind == LIGHT_SPOT) {
        const dir = spotDirection(l);
        unchecked(tests[t + T_DIR_X] = dir.x);
        unchecked(tests[t + T_DIR_Y] = dir.y);
        unchecked(tests[t + T_DIR_Z] = dir.z);
        unchecked(tests[t + T_COS] = coneCos(l.spotAngle));
        unchecked(tests[t + T_SIN] = coneSin(l.spotAngle));
    } else {
        unchecked(tests[t + T_DIR_X] = 0);
        unchecked(tests[t + T_DIR_Y] = 0);
        unchecked(tests[t + T_DIR_Z] = 0);
        unchecked(tests[t + T_COS] = CONE_WIDE);
        unchecked(tests[t + T_SIN] = 0);
    }
    const weight = lightWeight(l);
    unchecked(tests[t + T_WEIGHT2] = weight * weight);
    unchecked(tests[t + T_INV_RANGE2] = invSquare(l.range));
    unchecked(tests[t + T_ATTENUATION] = l.attenuation);
    unchecked(out.order[j] = k);
}

// Sets every item's light list (DrawItem.lightCount, lights0, lights1,
// lightsReached) from the pool of `plan` (planned for `f`'s camera), and
// the plan's per-item counts. An item without a mesh, or of another world
// than the frame's, draws none. `bakedLight` false: the renderer draws the
// frame's lightmapped items in real-time light (a host that refused the
// lightmap's texture or pipelines), so the static lights reach them too.
// Past MAX_OBJECT_LIGHTS omni and spot lights in the pool, and
// CLUSTER_MIN_ITEMS items with a box, the items are matched by clusters
// (the header): the same lists, fewer pairs. With `used` (cull.as
// CullResult.shaded: the renderer's), only the items it marks are matched
// (the others' lists stay empty: no pass of the view reads them), and the
// plan counts those alone.
export function assignItemLights(
    f: RenderFrame, plan: LightPlan, bakedLight: bool = true, used: Array<bool>? = null,
): void {
    plan.items = 0;
    plan.assigned = 0;
    plan.overBudget = 0;
    plan.maxReached = 0;
    plan.clusters = 0;
    const items = f.items;
    for (let i = 0; i < items.length; i++) clearItemLights(unchecked(items[i]));
    if (plan.count == 0) return;
    // (only a frame with a lightmap draws an item lightmapped, and only a
    // pool with a static light tells such an item apart)
    const tellStatic = bakedLight && plan.statics && f.lightmap != null;
    const clustered = plan.others > MAX_OBJECT_LIGHTS && plan.others * items.length >= CLUSTER_MIN_PAIRS
        && clusterItems(f, plan);
    let marks = NO_MARKS;
    if (used != null) marks = used;
    // Two jobs (jobs.as): the items matched alone, ITEM_GRAIN a unit, then
    // the clusters, CLUSTER_GRAIN cells a unit; each unit matches into its
    // items' lists and counts in its own LightCounts, in its worker's
    // scratch, the counts added to the plan after each run in unit order.
    const job = assignJob;
    job.f = f;
    job.plan = plan;
    job.tellStatic = tellStatic;
    job.clustered = clustered;
    job.every = used == null;
    job.marks = marks;
    job.packed = 0;
    const ex = jobs();
    scratchFor(ex.workers());
    job.clusters = false;
    const units = unitCount(items.length, ITEM_GRAIN);
    job.prepare(units);
    ex.run(job, items.length, ITEM_GRAIN);
    job.addTo(plan, units);
    if (clustered) {
        const cells = plan.cellStart.length - 1;
        job.clusters = true;
        const cu = unitCount(cells, CLUSTER_GRAIN);
        job.prepare(cu);
        ex.run(job, cells, CLUSTER_GRAIN);
        job.addTo(plan, cu);
    }
    job.f = null;
    job.plan = null;
    job.marks = NO_MARKS;
}

// No item marked (assignItemLights without `used`).
const NO_MARKS = new Array<bool>(0);

// The items a unit of assignItemLights' first job matches, and the cells
// a unit of its second.
const ITEM_GRAIN = 32;
const CLUSTER_GRAIN = 4;

// What matching counts (LightPlan.items, assigned, overBudget, maxReached
// and clusters), a unit's or a box's.
class LightCounts {
    items: i32 = 0;
    assigned: i32 = 0;
    overBudget: i32 = 0;
    maxReached: i32 = 0;
    clusters: i32 = 0;

    reset(): void {
        this.items = 0;
        this.assigned = 0;
        this.overBudget = 0;
        this.maxReached = 0;
        this.clusters = 0;
    }

    addTo(plan: LightPlan): void {
        plan.items += this.items;
        plan.assigned += this.assigned;
        plan.overBudget += this.overBudget;
        if (this.maxReached > plan.maxReached) plan.maxReached = this.maxReached;
        plan.clusters += this.clusters;
    }
}

// A worker's scratch for matching (jobs.as rule 3): what itemBudget sets
// for the item being matched (the omni and spot lights of `order` it tests,
// the first `budgetOthers`: for an item drawn lightmapped, none of the
// static ones; the directional lights that reach it, as bits by entry, the
// first MAX_OBJECT_LIGHTS of them, and how many; the slots they leave), the
// lights it keeps (positions in `order`, and their squared distances to it,
// or once more than its slots reach it their scores), and a cluster's
// lists (clusterEntries: the omni and spot lights that may reach it,
// ENTRY_WHOLE added when one reaches every item, and the largest score
// each can have at one of its items, those that may rank first, best
// first, then the rest (-1); the candidates before they are put in that
// order, and the rest's; the whole-reaching ones from each position on
// (those that are not static, and all); the others' positions in that
// list, and from each position on where they begin).
class MatchScratch {
    budgetOthers: i32 = 0;
    budgetDirTotal: i32 = 0;
    budgetDirBits: u64 = 0;
    budgetDirKept: u64 = 0;
    budgetSlots: i32 = 0;
    reached: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_LIGHTS);
    scores: StaticArray<f32> = new StaticArray<f32>(MAX_FRAME_LIGHTS);
    entries: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_LIGHTS);
    entryBounds: StaticArray<f32> = new StaticArray<f32>(MAX_FRAME_LIGHTS);
    candidateEntries: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_LIGHTS);
    candidateBounds: StaticArray<f32> = new StaticArray<f32>(MAX_FRAME_LIGHTS);
    unranked: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_LIGHTS);
    lows: StaticArray<f32> = new StaticArray<f32>(MAX_OBJECT_LIGHTS);
    wholeLiveFrom: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_LIGHTS + 1);
    wholeFrom: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_LIGHTS + 1);
    partial: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_LIGHTS);
    partialFrom: StaticArray<i32> = new StaticArray<i32>(MAX_FRAME_LIGHTS + 1);
    partialCount: i32 = 0;
}

// Each worker's MatchScratch, made before the first run it works in
// (worker 0's from the start: assignBoxLights').
const matchScratch: Array<MatchScratch> = [new MatchScratch()];

function scratchOf(worker: i32): MatchScratch {
    return unchecked(matchScratch[worker]);
}

// Scratch for `workers` workers (before a run: a unit takes its own).
function scratchFor(workers: i32): void {
    while (matchScratch.length < workers) matchScratch.push(new MatchScratch());
}

// assignItemLights' two jobs (`clusters`: the second): what their units
// read, and each unit's counts. On lanes (jobs.as LaneExecutor), which
// read neither the frame nor the plan: pack() writes what the matching
// reads (the plan's lights and each item's box, its flags and its cell)
// into one buffer of 32 bit words, once for both jobs, which goes to the
// lanes as a Blob; a lane (lightLaneUnits) makes a plan and the items it
// needs from it, matches the units it claims with the same code as
// runUnit, and gives back each item's list and each unit's counts, which
// mergeUnit puts in place.
class AssignJob extends LaneJob {
    f: RenderFrame? = null;
    plan: LightPlan? = null;
    tellStatic: bool = false;
    clustered: bool = false;
    every: bool = true;
    marks: Array<bool> = NO_MARKS;
    clusters: bool = false;
    counts: Array<LightCounts> = [];
    // The lanes' input for this call of assignItemLights (made by the
    // first run on lanes: its bytes, 0 before), kept from call to call.
    packed: i32 = 0;
    private words: ArrayBuffer = new ArrayBuffer(0);

    prepare(units: i32): void {
        while (this.counts.length < units) this.counts.push(new LightCounts());
        for (let u = 0; u < units; u++) unchecked(this.counts[u]).reset();
    }

    addTo(plan: LightPlan, units: i32): void {
        for (let u = 0; u < units; u++) unchecked(this.counts[u]).addTo(plan);
    }

    runUnit(unit: i32, begin: i32, end: i32, worker: i32): void {
        const f = this.f!;
        const plan = this.plan!;
        const m = scratchOf(worker);
        const c = unchecked(this.counts[unit]);
        if (this.clusters) {
            matchClusters(f, f.items, plan, this.tellStatic, this.every ? null : this.marks, begin, end, m, c, null);
            return;
        }
        const items = f.items;
        const scenario = f.scenario;
        const cells = plan.itemCell;
        const clustered = this.clustered;
        const every = this.every;
        const marks = this.marks;
        const tellStatic = this.tellStatic;
        for (let i = begin; i < end; i++) {
            const d = unchecked(items[i]);
            if (d.mesh == null || d.scenario != scenario) continue;
            if (clustered && unchecked(cells[i]) >= 0) continue;
            if (!every && !(i < marks.length && unchecked(marks[i]))) continue;
            matchItem(f, plan, d, tellStatic && lightmapDrawKind(f, d) == LIGHTMAP_DRAW_BAKED, false, m, c);
        }
    }

    laneKind(): i32 {
        return this.clusters ? LANE_LIGHT_CLUSTERS : LANE_LIGHTS;
    }

    worthLanes(count: i32, grain: i32): bool {
        return this.plan!.others * this.f!.items.length >= LIGHT_LANE_PAIRS;
    }

    packLanes(count: i32, grain: i32, units: i32): i32 {
        if (this.packed > 0) return this.packed;
        const words = packedLightWords(this.f!, this.plan!, this.clustered);
        if (this.words.byteLength < words * 4) this.words = new ArrayBuffer(words * 4);
        packLights(this.f!, this.plan!, this.tellStatic, this.clustered, this.every, this.marks, this.words);
        this.packed = words * 4;
        return this.packed;
    }

    laneWords(): ArrayBuffer {
        return this.words;
    }

    // A lane's unit: its counts (items, assigned, overBudget, maxReached,
    // clusters), how many items it listed, then each one's index and list
    // (lightCount, lights0, lights1, lightsReached), as ints.
    mergeLaneUnit(unit: i32, r: LaneResult, at: i32): void {
        const ints = r.ints;
        let i = unchecked(r.unitInts[at]);
        const c = unchecked(this.counts[unit]);
        c.items = unchecked(ints[i]);
        c.assigned = unchecked(ints[i + 1]);
        c.overBudget = unchecked(ints[i + 2]);
        c.maxReached = unchecked(ints[i + 3]);
        c.clusters = unchecked(ints[i + 4]);
        const n = unchecked(ints[i + 5]);
        i += 6;
        const items = this.f!.items;
        for (let e = 0; e < n; e++) {
            const d = unchecked(items[unchecked(ints[i])]);
            d.lightCount = <u32>unchecked(ints[i + 1]);
            d.lights0 = <u32>unchecked(ints[i + 2]);
            d.lights1 = <u32>unchecked(ints[i + 3]);
            d.lightsReached = <u32>unchecked(ints[i + 4]);
            i += 5;
        }
    }
}

// The fewest pairs of an omni or spot light and an item for which the
// items' lights are chosen on lanes: below it (the lights sample's 40
// lights over 125 items is 5,000 pairs, 0.1 ms) a lane's start and the
// copies cost more than the matching.
export const LIGHT_LANE_PAIRS: i32 = 16384;

// An item's flags in the lanes' input (packLights): matched alone (the
// first job's), its box, drawn lightmapped, marked (`used`).
const ITEM_ALONE: u8 = 1;
const ITEM_BOXED: u8 = 2;
const ITEM_BAKED: u8 = 4;
const ITEM_MARKED: u8 = 8;

// The lanes' input's words: a header (L_* below), the plan's tests and
// order, each item's (its flags, its box's six numbers and its origin's
// three), then each item's cell, the cells' starts and their items.
const L_COUNT = 0;
const L_OTHERS = 1;
const L_LIVE_OTHERS = 2;
const L_DIR_TOTAL = 3;
const L_LIVE_DIR_TOTAL = 4;
const L_DIR_BITS = 5; // 2 words each, low first
const L_DIR_KEPT = 7;
const L_LIVE_DIR_BITS = 9;
const L_LIVE_DIR_KEPT = 11;
const L_TELL_STATIC = 13;
const L_ITEMS = 14;
const L_CELLS = 15;
const L_PLACED = 16;
const L_EVERY = 17;
const L_HEADER = 20;
const L_ITEM_WORDS = 10;
const L_TESTS = MAX_FRAME_LIGHTS * LIGHT_TEST_FLOATS;

function packedLightWords(f: RenderFrame, plan: LightPlan, clustered: bool): i32 {
    const n = f.items.length;
    let words = L_HEADER + L_TESTS + MAX_FRAME_LIGHTS + n * L_ITEM_WORDS;
    if (clustered) words += n + plan.cellStart.length + plan.cellItems.length;
    return words;
}

function putBits(w: Int32Array, at: i32, v: u64): void {
    unchecked(w[at] = <i32>(v & 0xffffffff));
    unchecked(w[at + 1] = <i32>(v >> 32));
}

function getBits(w: Int32Array, at: i32): u64 {
    return (<u64><u32>unchecked(w[at])) | ((<u64><u32>unchecked(w[at + 1])) << 32);
}

function packLights(f: RenderFrame, plan: LightPlan, tellStatic: bool, clustered: bool, every: bool, marks: Array<bool>,
    into: ArrayBuffer): void {
    const fw = Float32Array.wrap(into);
    const iw = Int32Array.wrap(into);
    const items = f.items;
    const n = items.length;
    unchecked(iw[L_COUNT] = plan.count);
    unchecked(iw[L_OTHERS] = plan.others);
    unchecked(iw[L_LIVE_OTHERS] = plan.liveOthers);
    unchecked(iw[L_DIR_TOTAL] = plan.dirTotal);
    unchecked(iw[L_LIVE_DIR_TOTAL] = plan.liveDirTotal);
    putBits(iw, L_DIR_BITS, plan.dirBits);
    putBits(iw, L_DIR_KEPT, plan.dirBitsKept);
    putBits(iw, L_LIVE_DIR_BITS, plan.liveDirBits);
    putBits(iw, L_LIVE_DIR_KEPT, plan.liveDirBitsKept);
    unchecked(iw[L_TELL_STATIC] = tellStatic ? 1 : 0);
    unchecked(iw[L_ITEMS] = n);
    unchecked(iw[L_CELLS] = clustered ? plan.cellStart.length : 0);
    unchecked(iw[L_PLACED] = clustered ? plan.cellItems.length : 0);
    unchecked(iw[L_EVERY] = every ? 1 : 0);
    let at = L_HEADER;
    const tests = plan.tests;
    for (let i = 0; i < L_TESTS; i++) unchecked(fw[at + i] = unchecked(tests[i]));
    at += L_TESTS;
    for (let i = 0; i < MAX_FRAME_LIGHTS; i++) unchecked(iw[at + i] = unchecked(plan.order[i]));
    at += MAX_FRAME_LIGHTS;
    const scenario = f.scenario;
    const cells = plan.itemCell;
    for (let i = 0; i < n; i++) {
        const d = unchecked(items[i]);
        const marked = every || (i < marks.length && unchecked(marks[i]));
        let flags: u8 = 0;
        if (d.mesh != null && d.scenario == scenario && !(clustered && unchecked(cells[i]) >= 0) && marked) flags |= ITEM_ALONE;
        if (d.hasBounds) flags |= ITEM_BOXED;
        if (tellStatic && d.mesh != null && lightmapDrawKind(f, d) == LIGHTMAP_DRAW_BAKED) flags |= ITEM_BAKED;
        if (marked) flags |= ITEM_MARKED;
        const w = at + i * L_ITEM_WORDS;
        unchecked(iw[w] = flags);
        const b = d.bounds;
        unchecked(fw[w + 1] = b.min.x);
        unchecked(fw[w + 2] = b.min.y);
        unchecked(fw[w + 3] = b.min.z);
        unchecked(fw[w + 4] = b.max.x);
        unchecked(fw[w + 5] = b.max.y);
        unchecked(fw[w + 6] = b.max.z);
        const o = d.world.wAxis;
        unchecked(fw[w + 7] = o.x);
        unchecked(fw[w + 8] = o.y);
        unchecked(fw[w + 9] = o.z);
    }
    at += n * L_ITEM_WORDS;
    if (!clustered) return;
    for (let i = 0; i < n; i++) unchecked(iw[at + i] = unchecked(cells[i]));
    at += n;
    const start = plan.cellStart;
    for (let i = 0; i < start.length; i++) unchecked(iw[at + i] = unchecked(start[i]));
    at += start.length;
    const list = plan.cellItems;
    for (let i = 0; i < list.length; i++) unchecked(iw[at + i] = unchecked(list[i]));
}

// The items' lights on a lane (AssignJob, render/lanes.as): from what
// packLights wrote (`words`), every unit it can claim of the run's `units`
// (`clusters`: of the second job, cells), matched as runUnit matches them
// on the main lane; each unit's numbers as mergeLaneUnit reads them.
export function lightLaneUnits(words: ArrayBuffer, claims: UnitClaims, count: i32, grain: i32, units: i32,
    clusters: bool): LaneResult {
    const fw = Float32Array.wrap(words);
    const iw = Int32Array.wrap(words);
    const plan = new LightPlan();
    plan.count = unchecked(iw[L_COUNT]);
    plan.others = unchecked(iw[L_OTHERS]);
    plan.liveOthers = unchecked(iw[L_LIVE_OTHERS]);
    plan.dirTotal = unchecked(iw[L_DIR_TOTAL]);
    plan.liveDirTotal = unchecked(iw[L_LIVE_DIR_TOTAL]);
    plan.dirBits = getBits(iw, L_DIR_BITS);
    plan.dirBitsKept = getBits(iw, L_DIR_KEPT);
    plan.liveDirBits = getBits(iw, L_LIVE_DIR_BITS);
    plan.liveDirBitsKept = getBits(iw, L_LIVE_DIR_KEPT);
    const tellStatic = unchecked(iw[L_TELL_STATIC]) != 0;
    const n = unchecked(iw[L_ITEMS]);
    const cellCount = unchecked(iw[L_CELLS]);
    const placed = unchecked(iw[L_PLACED]);
    const every = unchecked(iw[L_EVERY]) != 0;
    let at = L_HEADER;
    for (let i = 0; i < L_TESTS; i++) unchecked(plan.tests[i] = unchecked(fw[at + i]));
    at += L_TESTS;
    for (let i = 0; i < MAX_FRAME_LIGHTS; i++) unchecked(plan.order[i] = unchecked(iw[at + i]));
    at += MAX_FRAME_LIGHTS;
    const itemAt = at;
    at += n * L_ITEM_WORDS;
    const flags = new Uint8Array(n);
    for (let i = 0; i < n; i++) unchecked(flags[i] = <u8>unchecked(iw[itemAt + i * L_ITEM_WORDS]));
    if (cellCount > 0) {
        plan.itemCell.length = n;
        for (let i = 0; i < n; i++) unchecked(plan.itemCell[i] = unchecked(iw[at + i]));
        at += n;
        plan.cellStart.length = cellCount;
        for (let i = 0; i < cellCount; i++) unchecked(plan.cellStart[i] = unchecked(iw[at + i]));
        at += cellCount;
        plan.cellItems.length = placed;
        for (let i = 0; i < placed; i++) unchecked(plan.cellItems[i] = unchecked(iw[at + i]));
    }
    // The items: one an item this lane matches (the others the same one,
    // never read).
    const none = new DrawItem();
    const items = new Array<DrawItem>(n);
    for (let i = 0; i < n; i++) unchecked(items[i] = none);
    const used = new Array<bool>(every ? 0 : n);
    if (!every) for (let i = 0; i < n; i++) unchecked(used[i] = (unchecked(flags[i]) & ITEM_MARKED) != 0);
    const m = new MatchScratch();
    const c = new LightCounts();
    const out = new LaneResultWriter(units);
    while (true) {
        const u = claims.next();
        if (u < 0) break;
        const begin = unitBegin(u, grain);
        const end = unitEnd(u, count, grain);
        c.reset();
        // (the items of the unit: a range of them, or those of its cells)
        let from = begin, to = end;
        if (clusters) {
            from = unchecked(plan.cellStart[begin]);
            to = unchecked(plan.cellStart[end]);
        }
        for (let q = from; q < to; q++) {
            const i = clusters ? unchecked(plan.cellItems[q]) : q;
            if (!clusters && (unchecked(flags[i]) & ITEM_ALONE) == 0) continue;
            const d = new DrawItem();
            const w = itemAt + i * L_ITEM_WORDS;
            d.hasBounds = (unchecked(flags[i]) & ITEM_BOXED) != 0;
            d.bounds = Bounds(Vec3(unchecked(fw[w + 1]), unchecked(fw[w + 2]), unchecked(fw[w + 3])),
                Vec3(unchecked(fw[w + 4]), unchecked(fw[w + 5]), unchecked(fw[w + 6])));
            d.world = Mat4(MAT4_IDENTITY.xAxis, MAT4_IDENTITY.yAxis, MAT4_IDENTITY.zAxis,
                Vec4(unchecked(fw[w + 7]), unchecked(fw[w + 8]), unchecked(fw[w + 9]), 1));
            unchecked(items[i] = d);
        }
        if (clusters) {
            matchClusters(null, items, plan, tellStatic, every ? null : used, begin, end, m, c, flags);
        } else {
            for (let i = begin; i < end; i++) {
                if ((unchecked(flags[i]) & ITEM_ALONE) == 0) continue;
                matchItem(null, plan, unchecked(items[i]), (unchecked(flags[i]) & ITEM_BAKED) != 0, false, m, c);
            }
        }
        // (its counts, then each item it listed)
        out.begin(u);
        out.addInt(c.items);
        out.addInt(c.assigned);
        out.addInt(c.overBudget);
        out.addInt(c.maxReached);
        out.addInt(c.clusters);
        let listed = 0;
        for (let q = from; q < to; q++) {
            const i = clusters ? unchecked(plan.cellItems[q]) : q;
            if (unchecked(items[i]) !== none) listed++;
        }
        out.addInt(listed);
        for (let q = from; q < to; q++) {
            const i = clusters ? unchecked(plan.cellItems[q]) : q;
            const d = unchecked(items[i]);
            if (d === none) continue;
            out.addInt(i);
            out.addInt(<i32>d.lightCount);
            out.addInt(<i32>d.lights0);
            out.addInt(<i32>d.lights1);
            out.addInt(<i32>d.lightsReached);
            unchecked(items[i] = none);
        }
    }
    return out.result();
}

const assignJob = new AssignJob();


// Godot's threshold for a light's light_volumetric_fog_energy: at or below
// it the light gives the fog nothing (volumetric_fog_process.glsl's
// `volumetric_fog_energy > 0.001`), so assignBoxLights's fog choice leaves
// it out, and it takes none of a fog volume's slots.
export const FOG_LIGHT_ENERGY_EPSILON: f32 = 0.001;

// Milestone 37: the lights of the pool `plan` (planned for `f`'s camera)
// that reach box `d` (a DrawItem standing for something that is not drawn
// as one: a fog volume, its `bounds` the volume's box, `hasBounds` false
// for one that reaches everywhere), chosen as an item's are (matchItem:
// every directional light, then the omni and spot lights that reach it,
// the 8 that matter most), into its lights0, lights1, lightCount and
// lightsReached. No static light is told apart (a fog volume is not
// lightmapped). With `fog`, the choice is among the lights that light fog
// (light_volumetric_fog_energy above FOG_LIGHT_ENERGY_EPSILON) alone: the
// others take no slot, as Godot's fog skips them. Allocates nothing.
export function assignBoxLights(f: RenderFrame, plan: LightPlan, d: DrawItem, fog: bool = false): void {
    clearItemLights(d);
    if (plan.count == 0) return;
    const c = boxCounts;
    c.reset();
    matchItem(f, plan, d, false, fog, scratchOf(0), c);
    c.addTo(plan);
}

// assignBoxLights' counts (added to the plan's, as an item's are).
const boxCounts = new LightCounts();

// Whether pool entry `k` of `plan` lights fog (assignBoxLights's `fog`).
function lightsFog(f: RenderFrame, plan: LightPlan, k: i32): bool {
    return unchecked(f.lights[plan.lightAt(k)]).fogEnergy > FOG_LIGHT_ENERGY_EPSILON;
}

// What item `d` may be reached by, into `m` (MatchScratch's budget*).
// `baked`: the item is drawn lightmapped (its shading skips the static
// lights). `f` is read only with `fog` (null on a lane, which has no frame).
function itemBudget(f: RenderFrame?, plan: LightPlan, baked: bool, fog: bool, m: MatchScratch): void {
    if (baked) {
        m.budgetOthers = plan.liveOthers;
        m.budgetDirTotal = plan.liveDirTotal;
        m.budgetDirBits = plan.liveDirBits;
        m.budgetDirKept = plan.liveDirBitsKept;
    } else {
        m.budgetOthers = plan.others;
        m.budgetDirTotal = plan.dirTotal;
        m.budgetDirBits = plan.dirBits;
        m.budgetDirKept = plan.dirBitsKept;
    }
    if (fog) {
        // (the directional lights that light fog, in pool order, and the
        // first MAX_OBJECT_LIGHTS of them)
        let bits: u64 = 0;
        let kept: u64 = 0;
        let total = 0;
        let rest = m.budgetDirBits;
        while (rest != 0) {
            const k = <i32>ctz<u64>(rest);
            rest &= rest - 1;
            if (!lightsFog(f!, plan, k)) continue;
            const bit = (<u64>1) << <u64>k;
            if (total < MAX_OBJECT_LIGHTS) kept |= bit;
            bits |= bit;
            total++;
        }
        m.budgetDirTotal = total;
        m.budgetDirBits = bits;
        m.budgetDirKept = kept;
    }
    m.budgetSlots = MAX_OBJECT_LIGHTS - min<i32>(m.budgetDirTotal, MAX_OBJECT_LIGHTS);
}

// Item `d` matched alone against every omni and spot light of the pool
// (with `fog`, those that light fog: assignBoxLights).
function matchItem(f: RenderFrame?, plan: LightPlan, d: DrawItem, baked: bool, fog: bool, m: MatchScratch,
    counts: LightCounts): void {
    const tests = plan.tests;
    const order = plan.order;
    const kept = m.reached;
    const keptScores = m.scores;
    // The lights it may be reached by: every directional light reaches
    // every item, the omni and spot lights are tested; for an item drawn
    // lightmapped, none of the static ones.
    itemBudget(f, plan, baked, fog, m);
    const n = m.budgetOthers;
    const slots = m.budgetSlots;

    // The omni and spot lights that reach it, `r` of them, in `order`'s
    // order. The first `slots` go into `kept` with their squared
    // distance, unscored (an item within its budget draws them all);
    // the next one scores those (scoreKept) and itself, and from then on
    // `kept` holds the best `slots` so far, `worstAt` the one that ranks
    // last (the one a better light replaces).
    let r = 0;
    let worstAt = 0;
    if (d.hasBounds) {
        const b = d.bounds;
        const x0 = b.min.x, y0 = b.min.y, z0 = b.min.z;
        const x1 = b.max.x, y1 = b.max.y, z1 = b.max.z;
        const cx = (x0 + x1) * <f32>0.5, cy = (y0 + y1) * <f32>0.5, cz = (z0 + z1) * <f32>0.5;
        const rho = halfDiagonal(x0, y0, z0, x1, y1, z1);
        for (let j = 0; j < n; j++) {
            const t = j * LIGHT_TEST_FLOATS;
            if (fog && !lightsFog(f!, plan, unchecked(order[j]))) continue;
            // boxDistanceSquared, a term at a time: a partial sum past
            // the reach is already a miss (the terms are not negative
            // and the sum is formed in the same order, so the outcome
            // is the same; a NaN reaches: conservative, as the frustum
            // keeps such a box).
            const r2 = unchecked(tests[t + T_REACH2]);
            const px = unchecked(tests[t + T_X]);
            let e: f32 = 0;
            if (px < x0) e = x0 - px;
            else if (px > x1) e = px - x1;
            let d2 = e * e;
            if (d2 > r2) continue;
            const py = unchecked(tests[t + T_Y]);
            e = 0;
            if (py < y0) e = y0 - py;
            else if (py > y1) e = py - y1;
            d2 = d2 + e * e;
            if (d2 > r2) continue;
            const pz = unchecked(tests[t + T_Z]);
            e = 0;
            if (pz < z0) e = z0 - pz;
            else if (pz > z1) e = pz - z1;
            d2 = d2 + e * e;
            if (d2 > r2) continue;
            const ch = unchecked(tests[t + T_COS]);
            if (ch != CONE_WIDE && !coneMeets(px, py, pz, unchecked(tests[t + T_DIR_X]),
                unchecked(tests[t + T_DIR_Y]), unchecked(tests[t + T_DIR_Z]), ch, unchecked(tests[t + T_SIN]),
                cx, cy, cz, rho)) {
                continue;
            }
            r++;
            if (r <= slots) {
                unchecked(kept[r - 1] = j);
                unchecked(keptScores[r - 1] = d2);
                continue;
            }
            if (slots == 0) continue;
            if (r == slots + 1) worstAt = scoreKept(tests, order, kept, keptScores, slots);
            const s = rankAt(unchecked(tests[t + T_WEIGHT2]), unchecked(tests[t + T_INV_RANGE2]),
                unchecked(tests[t + T_ATTENUATION]), d2);
            const w = unchecked(keptScores[worstAt]);
            // (an equal score keeps the light earlier in pool order)
            if (s < w || (s == w && unchecked(order[j]) > unchecked(order[unchecked(kept[worstAt])]))) continue;
            unchecked(kept[worstAt] = j);
            unchecked(keptScores[worstAt] = s);
            worstAt = worstKept(kept, keptScores, order, slots);
        }
    } else {
        // No box: every light, ranked from its transform's origin.
        const o = d.world.wAxis;
        for (let j = 0; j < n; j++) {
            const t = j * LIGHT_TEST_FLOATS;
            if (fog && !lightsFog(f!, plan, unchecked(order[j]))) continue;
            const d2 = pointDistanceSquared(unchecked(tests[t + T_X]), unchecked(tests[t + T_Y]),
                unchecked(tests[t + T_Z]), o.x, o.y, o.z);
            r++;
            if (r <= slots) {
                unchecked(kept[r - 1] = j);
                unchecked(keptScores[r - 1] = d2);
                continue;
            }
            if (slots == 0) continue;
            if (r == slots + 1) worstAt = scoreKept(tests, order, kept, keptScores, slots);
            const s = rankAt(unchecked(tests[t + T_WEIGHT2]), unchecked(tests[t + T_INV_RANGE2]),
                unchecked(tests[t + T_ATTENUATION]), d2);
            const w = unchecked(keptScores[worstAt]);
            // (an equal score keeps the light earlier in pool order)
            if (s < w || (s == w && unchecked(order[j]) > unchecked(order[unchecked(kept[worstAt])]))) continue;
            unchecked(kept[worstAt] = j);
            unchecked(keptScores[worstAt] = s);
            worstAt = worstKept(kept, keptScores, order, slots);
        }
    }
    listItem(plan, d, r, 0, m, counts);
}

// Item `d`'s list, in pool order, and `counts` (a unit's): `r` omni and spot
// lights reached it of which MatchScratch.reached holds the best (the first
// min(r, m.budgetSlots)), `more` reached it too and are not among them
// (matchInCluster: those it did not need to rank), and the directional
// lights of itemBudget. Every light that reaches it, or past the budget
// the first MAX_OBJECT_LIGHTS directional lights and the best omni and
// spot lights (a pool entry is below 64: one bit each).
function listItem(plan: LightPlan, d: DrawItem, r: i32, more: i32, m: MatchScratch, counts: LightCounts): void {
    const reached = r + more + m.budgetDirTotal;
    d.lightsReached = <u32>reached;
    if (reached == 0) return;
    counts.items++;
    if (reached > counts.maxReached) counts.maxReached = reached;
    let chosen: u64 = m.budgetDirBits;
    if (reached > MAX_OBJECT_LIGHTS) {
        counts.overBudget++;
        chosen = m.budgetDirKept;
    }
    const order = plan.order;
    const kept = m.reached;
    const best = min<i32>(r, m.budgetSlots);
    for (let q = 0; q < best; q++) chosen |= (<u64>1) << <u64>unchecked(order[unchecked(kept[q])]);
    while (chosen != 0) {
        addItemLight(d, <i32>ctz<u64>(chosen));
        chosen &= chosen - 1;
    }
    counts.assigned += <i32>d.lightCount;
}

// Puts the frame's items of a box into the cells of a grid over their
// centres (LightPlan.itemCell, cellStart, cellItems), about CLUSTER_ITEMS
// a cell; an item larger than a cell, of no finite box, without a mesh or
// of another world is left out (-1: matched alone). False (no cluster)
// below CLUSTER_MIN_ITEMS such items.
function clusterItems(f: RenderFrame, plan: LightPlan): bool {
    const items = f.items;
    const n = items.length;
    const cell = plan.itemCell;
    cell.length = n;
    const scenario = f.scenario;
    let lx: f64 = Infinity, ly: f64 = Infinity, lz: f64 = Infinity;
    let hx: f64 = -Infinity, hy: f64 = -Infinity, hz: f64 = -Infinity;
    let boxed = 0;
    for (let i = 0; i < n; i++) {
        const d = unchecked(items[i]);
        unchecked(cell[i] = -1);
        if (d.mesh == null || d.scenario != scenario || !d.hasBounds) continue;
        const b = d.bounds;
        const cx = (<f64>b.min.x + <f64>b.max.x) * 0.5;
        const cy = (<f64>b.min.y + <f64>b.max.y) * 0.5;
        const cz = (<f64>b.min.z + <f64>b.max.z) * 0.5;
        const ex = <f64>b.max.x - <f64>b.min.x, ey = <f64>b.max.y - <f64>b.min.y, ez = <f64>b.max.z - <f64>b.min.z;
        if (!isFinite(cx + cy + cz + ex + ey + ez)) continue;
        // (marked a candidate; the size test below needs the cell)
        unchecked(cell[i] = 0);
        boxed++;
        if (cx < lx) lx = cx;
        if (cx > hx) hx = cx;
        if (cy < ly) ly = cy;
        if (cy > hy) hy = cy;
        if (cz < lz) lz = cz;
        if (cz > hz) hz = cz;
    }
    if (boxed < CLUSTER_MIN_ITEMS) return false;
    // The cell's edge: about boxed / CLUSTER_ITEMS cells over the centres'
    // box, cubes in as many of its dimensions as it spans (a market's
    // floor is flat: squares over it, not cubes as thin as it is).
    const want = <f64>boxed / <f64>CLUSTER_ITEMS;
    const ex = hx - lx, ey = hy - ly, ez = hz - lz;
    let e1 = ex, e2 = ey, e3 = ez;
    if (e1 < e2) { const t = e1; e1 = e2; e2 = t; }
    if (e2 < e3) { const t = e2; e2 = e3; e3 = t; }
    if (e1 < e2) { const t = e1; e1 = e2; e2 = t; }
    let edge = e1 / want;
    if (edge < e2) {
        edge = Math.sqrt(e1 * e2 / want);
        if (edge < e3) edge = Math.cbrt(e1 * e2 * e3 / want);
    }
    if (!(edge > 0)) return false;
    const nx = <i32>Math.min(Math.floor(ex / edge) + 1, CLUSTER_AXIS_CELLS);
    const ny = <i32>Math.min(Math.floor(ey / edge) + 1, CLUSTER_AXIS_CELLS);
    const nz = <i32>Math.min(Math.floor(ez / edge) + 1, CLUSTER_AXIS_CELLS);
    const cells = nx * ny * nz;
    const start = plan.cellStart;
    start.length = cells + 1;
    for (let c = 0; c <= cells; c++) unchecked(start[c] = 0);
    // Each item's cell (one larger than a cell's edge is matched alone: it
    // would widen its cluster's box for every item in it), and the cells'
    // counts.
    let placed = 0;
    for (let i = 0; i < n; i++) {
        if (unchecked(cell[i]) < 0) continue;
        const b = unchecked(items[i]).bounds;
        const sx = <f64>b.max.x - <f64>b.min.x, sy = <f64>b.max.y - <f64>b.min.y, sz = <f64>b.max.z - <f64>b.min.z;
        if (Math.sqrt(sx * sx + sy * sy + sz * sz) * 0.5 > edge) {
            unchecked(cell[i] = -1);
            continue;
        }
        const ix = axisCell(((<f64>b.min.x + <f64>b.max.x) * 0.5 - lx) / edge, nx);
        const iy = axisCell(((<f64>b.min.y + <f64>b.max.y) * 0.5 - ly) / edge, ny);
        const iz = axisCell(((<f64>b.min.z + <f64>b.max.z) * 0.5 - lz) / edge, nz);
        const c = ix + nx * (iy + ny * iz);
        unchecked(cell[i] = c);
        unchecked(start[c + 1] = unchecked(start[c + 1]) + 1);
        placed++;
    }
    if (placed == 0) return false;
    // Where each cell's run begins; the items in place, in index order
    // within a cell (`start[c]` walks to the run's end and is put back).
    for (let c = 0; c < cells; c++) unchecked(start[c + 1] = unchecked(start[c + 1]) + unchecked(start[c]));
    const list = plan.cellItems;
    list.length = placed;
    for (let i = 0; i < n; i++) {
        const c = unchecked(cell[i]);
        if (c < 0) continue;
        const at = unchecked(start[c]);
        unchecked(list[at] = i);
        unchecked(start[c] = at + 1);
    }
    for (let c = cells; c > 0; c--) unchecked(start[c] = unchecked(start[c - 1]));
    unchecked(start[0] = 0);
    return true;
}

// The cell of a coordinate `u` cells from the grid's low side, of `count`.
@inline
function axisCell(u: f64, count: i32): i32 {
    const k = <i32>Math.floor(u);
    return k < 0 ? 0 : k >= count ? count - 1 : k;
}

// Every cluster of clusterItems: its box (the union of its items'), the
// lights that may reach it ranked by the largest score each can have at
// one of its items (clusterEntries), then each item (matchInCluster).
// `items`: the frame's (on a lane, its own of them); whether each is drawn
// lightmapped from `f` (with `tellStatic`) or, on a lane, from `baked` (by
// item: ITEM_BAKED).
function matchClusters(f: RenderFrame?, items: Array<DrawItem>, plan: LightPlan, tellStatic: bool, used: Array<bool>?,
    from: i32, to: i32, m: MatchScratch, counts: LightCounts, baked: Uint8Array?): void {
    const start = plan.cellStart;
    const list = plan.cellItems;
    for (let c = from; c < to; c++) {
        const a = unchecked(start[c]);
        const z = unchecked(start[c + 1]);
        if (a == z) continue;
        counts.clusters++;
        let x0 = f32.POSITIVE_INFINITY, y0 = f32.POSITIVE_INFINITY, z0 = f32.POSITIVE_INFINITY;
        let x1 = f32.NEGATIVE_INFINITY, y1 = f32.NEGATIVE_INFINITY, z1 = f32.NEGATIVE_INFINITY;
        for (let k = a; k < z; k++) {
            const b = unchecked(items[unchecked(list[k])]).bounds;
            x0 = min<f32>(x0, b.min.x);
            y0 = min<f32>(y0, b.min.y);
            z0 = min<f32>(z0, b.min.z);
            x1 = max<f32>(x1, b.max.x);
            y1 = max<f32>(y1, b.max.y);
            z1 = max<f32>(z1, b.max.z);
        }
        // Its centre; the radius of a sphere round it holding every item's
        // sphere (an item's centre `off` from it, its sphere's radius rho:
        // the most of off + rho), and the least of rho - off (`slack`: how
        // far inside a cone's side the centre must be for every item's
        // sphere to meet the cone).
        const cx = (x0 + x1) * <f32>0.5, cy = (y0 + y1) * <f32>0.5, cz = (z0 + z1) * <f32>0.5;
        let slack = f32.POSITIVE_INFINITY;
        let radius: f32 = 0;
        for (let k = a; k < z; k++) {
            const b = unchecked(items[unchecked(list[k])]).bounds;
            const dx = (b.min.x + b.max.x) * <f32>0.5 - cx;
            const dy = (b.min.y + b.max.y) * <f32>0.5 - cy;
            const dz = (b.min.z + b.max.z) * <f32>0.5 - cz;
            const off = Mathf.sqrt(dx * dx + dy * dy + dz * dz);
            const rho = halfDiagonal(b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z);
            slack = min<f32>(slack, rho - off);
            radius = max<f32>(radius, off + rho);
        }
        const count = clusterEntries(plan, m, tellStatic, x0, y0, z0, x1, y1, z1, cx, cy, cz, slack, radius);
        for (let k = a; k < z; k++) {
            const i = unchecked(list[k]);
            if (used != null && !(i < used.length && unchecked(used[i]))) continue;
            const d = unchecked(items[i]);
            const isBaked = baked != null ? (unchecked(baked[i]) & ITEM_BAKED) != 0
                : tellStatic && lightmapDrawKind(f!, d) == LIGHTMAP_DRAW_BAKED;
            matchInCluster(plan, d, isBaked, count, m, counts);
        }
    }
}

// The omni and spot lights of `plan` that may reach a cluster (its box x0
// to z1, its centre c, every item's sphere within `radius` of it, and
// `slack` the least of an item's sphere's radius less its centre's
// distance from c), into `m` (MatchScratch.entries): those reaching
// none of its items left out, and each marked ENTRY_WHOLE when it reaches
// every one of them. A light that may rank among an item's `ranked` best
// (the most slots any of its items has: those the directional lights
// leave, for an item drawn lightmapped the live ones; tellStatic) comes
// first, by the largest score it can have at one of them (entryBounds),
// best first; then the others, which `ranked` lights reaching every item
// outscore at every item, in pool order (-1). Then the counts and the
// list matchInCluster reads after its last ranked light. Returns how many.
//
// Each test is one an item's would pass or fail with it (f32 rounding
// aside, which the margins hold): an item's box lies in the cluster's, so
// its squared distance to a light is at least the cluster's nearest and at
// most its farthest (both formed as the item's is, so in f32 too), and its
// score between the scores there (rankAt falls with the distance for an
// attenuation of 0 or more; a negative one has no bound); the cone's test
// of the header moves by at most a point's own move (it is the distance to
// the cone's side, and the depth along its axis), so a cone missing the
// cluster's sphere by more than its radius misses every item's, and one
// whose side the centre is `-slack` inside of (or less) meets every
// item's sphere.
function clusterEntries(
    plan: LightPlan, m: MatchScratch, tellStatic: bool, x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32, cx: f32, cy: f32,
    cz: f32, slack: f32, radius: f32,
): i32 {
    const tests = plan.tests;
    const cand = m.candidateEntries;
    const candBounds = m.candidateBounds;
    const lows = m.lows;
    const others = plan.others;
    const live = plan.liveOthers;
    const ranked = MAX_OBJECT_LIGHTS - min<i32>(tellStatic ? plan.liveDirTotal : plan.dirTotal, MAX_OBJECT_LIGHTS);
    // 1. The candidates in pool order, their bounds, and the `ranked`
    // largest of the least scores the live whole-reaching ones have at an
    // item (`lows`, best first).
    let count = 0;
    let lowCount = 0;
    for (let j = 0; j < others; j++) {
        const t = j * LIGHT_TEST_FLOATS;
        const px = unchecked(tests[t + T_X]), py = unchecked(tests[t + T_Y]), pz = unchecked(tests[t + T_Z]);
        const r2 = unchecked(tests[t + T_REACH2]);
        // The squared distance to the box's nearest point, a term at a time
        // (formed as boxDistanceSquared forms it: a partial sum past the
        // reach is already a miss), then to its farthest corner.
        const lx = px - x0, hx = x1 - px;
        let e: f32 = lx < 0 ? -lx : hx < 0 ? -hx : 0;
        let near2 = e * e;
        if (near2 > r2) continue;
        const ly = py - y0, hy = y1 - py;
        e = ly < 0 ? -ly : hy < 0 ? -hy : 0;
        near2 = near2 + e * e;
        if (near2 > r2) continue;
        const lz = pz - z0, hz = z1 - pz;
        e = lz < 0 ? -lz : hz < 0 ? -hz : 0;
        near2 = near2 + e * e;
        if (near2 > r2) continue;
        const gx = max<f32>(Mathf.abs(lx), Mathf.abs(hx));
        const gy = max<f32>(Mathf.abs(ly), Mathf.abs(hy));
        const gz = max<f32>(Mathf.abs(lz), Mathf.abs(hz));
        const far2 = gx * gx + gy * gy + gz * gz;
        let all = far2 <= r2;
        const ch = unchecked(tests[t + T_COS]);
        if (ch != CONE_WIDE) {
            const vx = cx - px, vy = cy - py, vz = cz - pz;
            const a = vx * unchecked(tests[t + T_DIR_X]) + vy * unchecked(tests[t + T_DIR_Y])
                + vz * unchecked(tests[t + T_DIR_Z]);
            const vv = vx * vx + vy * vy + vz * vz;
            let b2 = vv - a * a;
            if (b2 < 0) b2 = 0;
            const side = Mathf.sqrt(b2) * ch - a * unchecked(tests[t + T_SIN]);
            const margin = (Mathf.sqrt(vv) + radius) * CLUSTER_MARGIN + CLUSTER_MARGIN;
            if (side > radius + margin || a < -radius - margin) continue;
            if (!(side <= slack - margin && a >= margin - slack)) all = false;
        }
        const att = unchecked(tests[t + T_ATTENUATION]);
        let best = f32.POSITIVE_INFINITY;
        if (att >= 0) {
            const w2 = unchecked(tests[t + T_WEIGHT2]);
            const inv2 = unchecked(tests[t + T_INV_RANGE2]);
            best = rankAt(w2, inv2, att, near2) * (<f32>1 + BOUND_SLACK);
            // (its least score is at most its best's: no need to work it out
            // when that is not among the `ranked` largest)
            if (all && j < live && ranked > 0
                && (lowCount < ranked || best * LOW_OF_BEST > unchecked(lows[ranked - 1]))) {
                const low = rankAt(w2, inv2, att, far2) * (<f32>1 - BOUND_SLACK);
                if (lowCount < ranked || low > unchecked(lows[ranked - 1])) {
                    let at = lowCount < ranked ? lowCount++ : ranked - 1;
                    while (at > 0 && unchecked(lows[at - 1]) < low) {
                        unchecked(lows[at] = unchecked(lows[at - 1]));
                        at--;
                    }
                    unchecked(lows[at] = low);
                }
            }
        }
        unchecked(cand[count] = all ? j | ENTRY_WHOLE : j);
        unchecked(candBounds[count] = best);
        count++;
    }
    // 2. Those that may rank (a bound of at least the `ranked`-th low; all
    // of them while fewer lights hold one) by their bounds, best first
    // (equal ones in pool order), then the rest in pool order.
    const floor = lowCount == ranked && ranked > 0 ? unchecked(lows[ranked - 1]) : f32.NEGATIVE_INFINITY;
    const ents = m.entries;
    const bounds = m.entryBounds;
    const rest = m.unranked;
    let first = 0;
    let after = 0;
    for (let c = 0; c < count; c++) {
        const e = unchecked(cand[c]);
        const best = unchecked(candBounds[c]);
        if (best < floor) {
            unchecked(rest[after++] = e);
            continue;
        }
        let at = first++;
        while (at > 0 && unchecked(bounds[at - 1]) < best) {
            unchecked(ents[at] = unchecked(ents[at - 1]));
            unchecked(bounds[at] = unchecked(bounds[at - 1]));
            at--;
        }
        unchecked(ents[at] = e);
        unchecked(bounds[at] = best);
    }
    for (let k = 0; k < after; k++) {
        unchecked(ents[first + k] = unchecked(rest[k]));
        unchecked(bounds[first + k] = -1);
    }
    // 3. From each position on: the whole-reaching lights (those that are
    // not static, and all), and where the others' run of `partial` begins.
    const wholeLive = m.wholeLiveFrom;
    const wholeAll = m.wholeFrom;
    const partial = m.partial;
    const partialFrom = m.partialFrom;
    let parts = 0;
    for (let q = 0; q < count; q++) if ((unchecked(ents[q]) & ENTRY_WHOLE) == 0) unchecked(partial[parts++] = q);
    unchecked(wholeLive[count] = 0);
    unchecked(wholeAll[count] = 0);
    unchecked(partialFrom[count] = parts);
    let p = parts;
    for (let q = count - 1; q >= 0; q--) {
        let l = unchecked(wholeLive[q + 1]);
        let w = unchecked(wholeAll[q + 1]);
        const e = unchecked(ents[q]);
        if ((e & ENTRY_WHOLE) != 0) {
            w++;
            if ((e & ENTRY_POSITION) < live) l++;
        } else {
            p--;
        }
        unchecked(wholeLive[q] = l);
        unchecked(wholeAll[q] = w);
        unchecked(partialFrom[q] = p);
    }
    m.partialCount = parts;
    return count;
}

// Item `d` of a cluster whose `count` lights clusterEntries listed: as
// matchItem, over those lights best first, until the kept ones are all
// better than any light left can be at the item; the rest are only
// counted (those reaching every item of the cluster), or tested and
// counted. The same list as matchItem's: only lights that cannot rank
// among the best are not ranked, and the best of a set does not depend on
// the order it is looked at in (equal scores rank in pool order).
function matchInCluster(plan: LightPlan, d: DrawItem, baked: bool, count: i32, m: MatchScratch, counts: LightCounts): void {
    const tests = plan.tests;
    const order = plan.order;
    const kept = m.reached;
    const keptScores = m.scores;
    const ents = m.entries;
    const bounds = m.entryBounds;
    itemBudget(null, plan, baked, false, m);
    const n = m.budgetOthers;
    const slots = m.budgetSlots;
    const b = d.bounds;
    const x0 = b.min.x, y0 = b.min.y, z0 = b.min.z;
    const x1 = b.max.x, y1 = b.max.y, z1 = b.max.z;
    const cx = (x0 + x1) * <f32>0.5, cy = (y0 + y1) * <f32>0.5, cz = (z0 + z1) * <f32>0.5;
    const rho = halfDiagonal(x0, y0, z0, x1, y1, z1);
    let r = 0;
    let worstAt = 0;
    // (no slot for an omni or spot light: they are only counted)
    let rest = slots == 0 ? 0 : count;
    for (let q = 0; q < rest; q++) {
        const e = unchecked(ents[q]);
        const j = e & ENTRY_POSITION;
        if (j >= n) continue;
        if (r > slots && unchecked(bounds[q]) < unchecked(keptScores[worstAt])) {
            rest = q;
            break;
        }
        const t = j * LIGHT_TEST_FLOATS;
        const px = unchecked(tests[t + T_X]), py = unchecked(tests[t + T_Y]), pz = unchecked(tests[t + T_Z]);
        let d2: f32;
        if ((e & ENTRY_WHOLE) != 0) {
            // (it reaches every item of the cluster: no test)
            d2 = boxDistanceSquared(px, py, pz, x0, y0, z0, x1, y1, z1);
        } else {
            d2 = boxDistanceSquared(px, py, pz, x0, y0, z0, x1, y1, z1);
            if (d2 > unchecked(tests[t + T_REACH2])) continue;
            const ch = unchecked(tests[t + T_COS]);
            if (ch != CONE_WIDE && !coneMeets(px, py, pz, unchecked(tests[t + T_DIR_X]),
                unchecked(tests[t + T_DIR_Y]), unchecked(tests[t + T_DIR_Z]), ch, unchecked(tests[t + T_SIN]),
                cx, cy, cz, rho)) {
                continue;
            }
        }
        r++;
        if (r <= slots) {
            unchecked(kept[r - 1] = j);
            unchecked(keptScores[r - 1] = d2);
            continue;
        }
        if (r == slots + 1) worstAt = scoreKept(tests, order, kept, keptScores, slots);
        const s = rankAt(unchecked(tests[t + T_WEIGHT2]), unchecked(tests[t + T_INV_RANGE2]),
            unchecked(tests[t + T_ATTENUATION]), d2);
        const w = unchecked(keptScores[worstAt]);
        // (an equal score keeps the light earlier in pool order)
        if (s < w || (s == w && unchecked(order[j]) > unchecked(order[unchecked(kept[worstAt])]))) continue;
        unchecked(kept[worstAt] = j);
        unchecked(keptScores[worstAt] = s);
        worstAt = worstKept(kept, keptScores, order, slots);
    }
    // The lights from `rest` on, not ranked: those reaching every item
    // counted, the others tested.
    let more = n < plan.others ? unchecked(m.wholeLiveFrom[rest]) : unchecked(m.wholeFrom[rest]);
    const partial = m.partial;
    for (let u = unchecked(m.partialFrom[rest]); u < m.partialCount; u++) {
        const j = unchecked(ents[unchecked(partial[u])]) & ENTRY_POSITION;
        if (j >= n) continue;
        const t = j * LIGHT_TEST_FLOATS;
        const px = unchecked(tests[t + T_X]), py = unchecked(tests[t + T_Y]), pz = unchecked(tests[t + T_Z]);
        if (boxDistanceSquared(px, py, pz, x0, y0, z0, x1, y1, z1) > unchecked(tests[t + T_REACH2])) continue;
        const ch = unchecked(tests[t + T_COS]);
        if (ch != CONE_WIDE && !coneMeets(px, py, pz, unchecked(tests[t + T_DIR_X]),
            unchecked(tests[t + T_DIR_Y]), unchecked(tests[t + T_DIR_Z]), ch, unchecked(tests[t + T_SIN]),
            cx, cy, cz, rho)) {
            continue;
        }
        more++;
    }
    listItem(plan, d, r, more, m, counts);
}

// Scores the `slots` lights `kept` holds (positions in LightPlan.order,
// their squared distances to the item in `keptScores`, replaced by their
// scores): an item's lights once one more than its slots reaches it.
// Returns the one that ranks last (worstKept).
function scoreKept(
    tests: StaticArray<f32>, order: StaticArray<i32>, kept: StaticArray<i32>, keptScores: StaticArray<f32>, slots: i32,
): i32 {
    for (let q = 0; q < slots; q++) {
        const t = unchecked(kept[q]) * LIGHT_TEST_FLOATS;
        unchecked(keptScores[q] = rankAt(unchecked(tests[t + T_WEIGHT2]), unchecked(tests[t + T_INV_RANGE2]),
            unchecked(tests[t + T_ATTENUATION]), unchecked(keptScores[q])));
    }
    return worstKept(kept, keptScores, order, slots);
}

// The one of the `slots` lights `kept` holds (positions in LightPlan.order,
// their scores in `keptScores`) that ranks last: the least score, and of
// equal ones the latest in pool order.
@inline
function worstKept(kept: StaticArray<i32>, keptScores: StaticArray<f32>, order: StaticArray<i32>, slots: i32): i32 {
    let at = 0;
    let w = unchecked(keptScores[0]);
    for (let q = 1; q < slots; q++) {
        const s = unchecked(keptScores[q]);
        if (s > w) continue;
        if (s == w && unchecked(order[unchecked(kept[q])]) < unchecked(order[unchecked(kept[at])])) continue;
        at = q;
        w = s;
    }
    return at;
}

// planLightPool then assignItemLights for `f`'s camera, into `f.lightPlan`,
// returned: what the tools call to count (and the pure helpers that build a
// block from a frame no renderer has drawn: lit.as litUniform, shadow.as
// planShadows, sky.as skySuns).
export function prepareLights(f: RenderFrame, cullFrustum: bool = true): LightPlan {
    const plan = planLightPool(f, f.lightPlan, cullFrustum);
    assignItemLights(f, plan);
    return plan;
}

// Whether light `l` may light item `d` (a directional light always; an
// omni light when its range reaches the item's box; a spot light when its
// cone does too; an item without a box: always), and, given the frame `f`
// the item is drawn in, never a static light of an item the frame draws
// lightmapped. Conservative: a light it says does not reach lights no
// point of the box. assignItemLights' test, bit for bit.
export function lightReaches(l: LightDesc, d: DrawItem, f: RenderFrame? = null): bool {
    if (f != null && l.bakeMode == LIGHT_BAKE_STATIC) {
        const frame = f!;
        if (frame.lightmap != null && lightmapDrawKind(frame, d) == LIGHTMAP_DRAW_BAKED) return false;
    }
    if (l.kind == LIGHT_DIRECTIONAL || !d.hasBounds) return true;
    const p = l.position;
    const b = d.bounds;
    const x0 = b.min.x, y0 = b.min.y, z0 = b.min.z;
    const x1 = b.max.x, y1 = b.max.y, z1 = b.max.z;
    if (boxDistanceSquared(p.x, p.y, p.z, x0, y0, z0, x1, y1, z1) > reachSquared(l.range)) return false;
    if (l.kind != LIGHT_SPOT) return true;
    const dir = spotDirection(l);
    return coneMeets(p.x, p.y, p.z, dir.x, dir.y, dir.z, coneCos(l.spotAngle), coneSin(l.spotAngle),
        (x0 + x1) * <f32>0.5, (y0 + y1) * <f32>0.5, (z0 + z1) * <f32>0.5, halfDiagonal(x0, y0, z0, x1, y1, z1));
}

// How much light `l` brings to item `d`, the rank among the omni and spot
// lights that reach it (larger first): the square of its contribution at
// the item's box (the header has the formula; without a box, at its
// transform's origin). A directional light's is f32.MAX_VALUE.
// assignItemLights' score, bit for bit.
export function lightScore(l: LightDesc, d: DrawItem): f32 {
    if (l.kind == LIGHT_DIRECTIONAL) return f32.MAX_VALUE;
    const p = l.position;
    let d2: f32;
    if (d.hasBounds) {
        const b = d.bounds;
        d2 = boxDistanceSquared(p.x, p.y, p.z, b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z);
    } else {
        const t = d.world.wAxis;
        d2 = pointDistanceSquared(p.x, p.y, p.z, t.x, t.y, t.z);
    }
    const weight = lightWeight(l);
    return rankAt(weight * weight, invSquare(l.range), l.attenuation, d2);
}

// Empties item `d`'s list.
export function clearItemLights(d: DrawItem): void {
    d.lightCount = 0;
    d.lights0 = 0;
    d.lights1 = 0;
    d.lightsReached = 0;
}

// Appends pool entry `entry` (0 to 255) to item `d`'s list; false (and
// nothing changed) when it holds MAX_OBJECT_LIGHTS already. Entries are
// appended in pool order (the order the shader sums them in).
export function addItemLight(d: DrawItem, entry: i32): bool {
    const k = <i32>d.lightCount;
    if (k >= MAX_OBJECT_LIGHTS) return false;
    const byte = <u32>(entry & 0xff) << (<u32>(k & 3) * 8);
    if (k < 4) d.lights0 |= byte;
    else d.lights1 |= byte;
    d.lightCount = <u32>(k + 1);
    return true;
}

// The pool entry item `d` draws k-th (0 <= k < d.lightCount).
export function itemLightAt(d: DrawItem, k: i32): i32 {
    const word = k < 4 ? d.lights0 : d.lights1;
    return <i32>((word >> (<u32>(k & 3) * 8)) & 0xff);
}

// The tests both paths share (the plan's flat copy and a LightDesc).

// A spot's unit direction (lit.as packs the same; (0, 0, -1) without one).
function spotDirection(l: LightDesc): Vec3 {
    return l.direction.normalizeOr(Vec3(0, 0, -1));
}

// The square of the distance from a light within which a box is reached.
@inline
function reachSquared(range: f32): f32 {
    const r = range * (<f32>1 + RANGE_SLACK) + RANGE_SLACK_M;
    return r * r;
}

// 1 / range^2 (infinite for a range of 0: the score is then 0).
@inline
function invSquare(range: f32): f32 {
    return <f32>1 / (range * range);
}

// The cosine and the sine of a cone's widened half angle (`angle` in
// degrees, of either sign: the shader's cone is cos(spot_angle), which
// ignores it, so -30 lights the cone 30 does); CONE_WIDE and 0 for one
// every box meets (coneEverywhere; a NaN angle too: conservative).
function coneCos(angle: f32): f32 {
    const a = Mathf.abs(angle);
    if (coneEverywhere(a)) return CONE_WIDE;
    return cosf(toRadians(a) + CONE_SLACK);
}

function coneSin(angle: f32): f32 {
    const a = Mathf.abs(angle);
    if (coneEverywhere(a)) return 0;
    return sinf(toRadians(a) + CONE_SLACK);
}

// Whether a cone of half angle `a` (degrees, not negative) is taken to
// meet every box: SPOT_WIDEST or more (a half space, near enough), a NaN,
// or a cone so narrow that the shader lights its whole sphere of range.
// surface.wgsl's rim is (1 - scos) / max(1 - cone, 1e-6), scos clamped to
// the cone: outside the cone it is (1 - cone) / 1e-6, below 1 (lit) once
// 1 - cone < 1e-6, under about 0.08 degrees (lit.as packs cos(spot_angle)
// as here).
function coneEverywhere(a: f32): bool {
    if (!(a < SPOT_WIDEST)) return true;
    return <f32>1 - cosf(toRadians(a)) < <f32>1e-6;
}

// |energy| times the linear colour's luminance (Rec. 709's weights).
function lightWeight(l: LightDesc): f32 {
    const c = l.color;
    return Mathf.abs(l.energy) * (<f32>0.2126 * c.x + <f32>0.7152 * c.y + <f32>0.0722 * c.z);
}

// Half the diagonal of a box: the radius of its bounding sphere.
@inline
function halfDiagonal(x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32): f32 {
    const ex = x1 - x0, ey = y1 - y0, ez = z1 - z0;
    return Mathf.sqrt(ex * ex + ey * ey + ez * ez) * <f32>0.5;
}

// The squared distance from p to the box's nearest point (0 inside it).
@inline
function boxDistanceSquared(px: f32, py: f32, pz: f32, x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32): f32 {
    let dx: f32 = 0, dy: f32 = 0, dz: f32 = 0;
    if (px < x0) dx = x0 - px;
    else if (px > x1) dx = px - x1;
    if (py < y0) dy = y0 - py;
    else if (py > y1) dy = py - y1;
    if (pz < z0) dz = z0 - pz;
    else if (pz > z1) dz = pz - z1;
    return dx * dx + dy * dy + dz * dz;
}

@inline
function pointDistanceSquared(px: f32, py: f32, pz: f32, x: f32, y: f32, z: f32): f32 {
    const dx = px - x, dy = py - y, dz = pz - z;
    return dx * dx + dy * dy + dz * dz;
}

// Whether a spot at p along `dir` (unit), its cone's widened half angle's
// cosine and sine `ch` and `sh`, meets the sphere (c, rho) (the header
// says how). A NaN anywhere meets it.
@inline
function coneMeets(
    px: f32, py: f32, pz: f32, dx: f32, dy: f32, dz: f32, ch: f32, sh: f32, cx: f32, cy: f32, cz: f32, rho: f32,
): bool {
    if (ch == CONE_WIDE) return true;
    const vx = cx - px, vy = cy - py, vz = cz - pz;
    const a = vx * dx + vy * dy + vz * dz;
    if (a < -rho) return false;
    let b2 = (vx * vx + vy * vy + vz * vz) - a * a;
    if (b2 < 0) b2 = 0;
    return !(Mathf.sqrt(b2) * ch - a * sh > rho);
}

// The score of an omni or spot light (the square of its weight, 1 /
// range^2, its attenuation) at squared distance `d2` from an item: the
// square of its contribution there (the header). A NaN or a negative is 0
// (ranked last, deterministically).
@inline
function rankAt(weight2: f32, invRange2: f32, att: f32, d2: f32): f32 {
    const x2 = d2 * invRange2;
    if (!(x2 < 1)) return 0;
    const w = <f32>1 - x2 * x2;
    const w2 = w * w;
    const m2 = d2 > SCORE_FLOOR2 ? d2 : SCORE_FLOOR2;
    let fall: f32;
    if (att == 1) fall = <f32>1 / m2;
    else if (att == 2) fall = <f32>1 / (m2 * m2);
    else if (att == 0) fall = 1;
    else fall = powf(m2, -att);
    const s = weight2 * (w2 * w2) * fall;
    return s > 0 ? s : 0;
}
