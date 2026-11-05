// Which fog volumes a frame draws from its camera, which each item is seen
// through, and what lights each (milestone 37; fog_volume.as says what a
// frame carries and how a pixel integrates them). The renderer calls
// prepareFogVolumes for each view, after planLightPool (an entry's lights
// are entries of the view's light pool) and before it writes the view's
// object uniforms and fog block; `inspect --fog` and `--stats` call it to
// count.
//
// The pool: nothing while RenderFrame.volumetricFog.enabled is off; else
// the Environment's own fog first (FOG_ENTRY_ENVIRONMENT, when its density
// is not within FOG_DENSITY_EPSILON of 0), then the frame's FogVolumes of
// the frame's world that are not empty and whose box meets the camera's
// frustum (a world shape always), in the scene's order; past
// MAX_FRAME_FOG_VOLUMES the world shapes, then the volumes nearest the eye
// (the distance to their box), ties in the scene's order, listed in the
// scene's order all the same. Those left out are counted (FogPlan.dropped)
// and named by the plan's warning (fogPoolWarning: adapter.as, and the
// editor's for its own camera, once per change of fogDroppedKey).
//
// Each item: the pool's entries whose box meets the box every ray from the
// camera to a point of the item's box lies in (the box around the eye and
// the item's; for an orthographic camera, whose rays start on the camera's
// plane, around the item's box and its shadow on that plane), world shapes
// always; the Environment's first, then the
// nearest, at most MAX_OBJECT_FOG_VOLUMES; an item without a box is seen
// through all of them (the first MAX_OBJECT_FOG_VOLUMES in that order). An
// item of another world, without a mesh or drawn into shadow maps only is
// seen through none. The sky: the pool's entries (each meets the
// frustum), in the same order. When more than MAX_OBJECT_FOG_VOLUMES meet
// an item (a wall behind a lit square holds every volume in front of it),
// its word also has FOG_LIST_ALL: each of its pixels then tests the whole
// pool and integrates the first MAX_OBJECT_FOG_VOLUMES volumes its own ray
// crosses, in the pool's order (surface.wgsl fog_integrate), so a volume
// is never cut off along an item's edge of the list; the sky's likewise
// past MAX_OBJECT_FOG_VOLUMES entries.
//
// Each entry's lights: milestone 59's choice for its box among the lights
// whose light_volumetric_fog_energy is above FOG_LIGHT_ENERGY_EPSILON
// (light_select.as assignBoxLights with `fog`: Godot's
// volumetric_fog_process.glsl skips the others, so they take no slot); a
// world shape's box, and the Environment's fog's, is the eye's within the
// fog's length cut to the frame's draw bounds, the eye kept in it (every
// ray starts there, so a lamp between the camera and the scene lights the
// fog in front of it).
//
// Only the items the view's main pass shades (`used`, cull.as
// CullResult.shaded: the renderer's) are given a list; the others' stay
// empty. inspect and the tests pass none: every item.
//
// fogChord and fogOpticalDepth are the CPU twin of the shader's chord and
// optical depth (surface.wgsl `fog_chord`, `fog_entry`): the same shapes,
// the same closed forms and Gauss-Legendre nodes, in f32 and in the same
// order, which the fog tests hold the shader's pictures to
// (tests/fog/gpu_test.as: the same bytes as `hedra render`'s); and
// fogCombineDepths is its step 5.
//
// Allocates nothing once warm (the scratch arrays grow to the most a frame
// held, the plan and the items are written in place).

import { Vec3 } from "../base/vecmath";
import { Bounds } from "./camera";
import { Frustum, frameViewProj } from "./cull";
import { CAST_SHADOW_SHADOWS_ONLY, DrawItem, RenderFrame } from "./frame";
import {
    FOG_DENSITY_EPSILON, FOG_ENTRY_ENVIRONMENT, FOG_SAMPLES, FOG_SHAPE_BOX, FOG_SHAPE_CONE, FOG_SHAPE_CYLINDER,
    FOG_SHAPE_ELLIPSOID, FOG_SHAPE_WORLD, FogPlan, FogVolumeDesc, MAX_FRAME_FOG_VOLUMES, MAX_OBJECT_FOG_VOLUMES,
    VolumetricFogDesc,
} from "./fog_volume";
import { assignBoxLights } from "./light_select";
import { Job, UnitCounts, jobs, unitCount } from "../base/jobs";

// Godot's threshold for a light's light_volumetric_fog_energy
// (light_select.as, where the choice leaves such a light out).
export { FOG_LIGHT_ENERGY_EPSILON } from "./light_select";

// The flag of an item's word (DrawItem.fogVolumes) and of the sky's list
// (FogPlan.sky) when more than MAX_OBJECT_FOG_VOLUMES pool entries meet
// it (see the header): the bytes below it still list the nearest
// MAX_OBJECT_FOG_VOLUMES (itemFogAt reads them without it).
export const FOG_LIST_ALL: u32 = 0x80000000;

// The volumes a pool warning names before it counts the rest (the lights
// pool's POOL_WARNING_NAMED).
export const FOG_WARNING_NAMED: i32 = 8;

// The FOG_SAMPLES-point Gauss-Legendre rule on [-1, 1] (surface.wgsl's
// FOG_GL_X0, FOG_GL_X1, FOG_GL_W0 and FOG_GL_W1: the nodes -X0, -X1, X1,
// X0, in this order).
export const FOG_GL_X: StaticArray<f32> = [-0.8611363, -0.339981, 0.339981, 0.8611363];
export const FOG_GL_W: StaticArray<f32> = [0.3478548, 0.6521452, 0.6521452, 0.3478548];

// ln 2 (the height falloff is a power of 2).
const LN2: f32 = 0.6931472;

const fogFrustum = new Frustum();
// The volumes in view (indices into RenderFrame.fogVolumes, the scene's
// order) and, past the pool's size, which were kept: grown to the most a
// frame held.
const candidates = new Array<i32>();
const kept = new Array<bool>();
// The box an entry's lights are chosen for (assignBoxLights).
const scratch = new DrawItem();
// No item marked (prepareFogVolumes without `used`).
const NO_MARKS = new Array<bool>(0);

// The pool alone of `f`'s fog for its camera into `out` (reset first: its
// entries, count, inView, dropped and droppedVolumes; see the header),
// touching no item: the plan's warning (adapter.as, fogPoolWarning) and
// the editor's, for its own camera, read it. Allocates nothing once warm.
export function planFogPool(f: RenderFrame, out: FogPlan): void {
    out.reset();
    out.droppedVolumes.length = 0;
    const fog = f.volumetricFog;
    if (!fog.enabled) return;
    const eye = f.camera.eye;
    fogFrustum.setFrom(frameViewProj(f));
    let n = 0;
    if (Mathf.abs(fog.density) >= FOG_DENSITY_EPSILON) {
        unchecked(out.entries[0] = FOG_ENTRY_ENVIRONMENT);
        unchecked(out.distances[0] = 0);
        n = 1;
    }
    const vols = f.fogVolumes;
    candidates.length = 0;
    for (let i = 0; i < vols.length; i++) {
        const v = unchecked(vols[i]);
        if (v.empty || v.scenario != f.scenario) continue;
        if (v.hasBounds && !fogFrustum.intersects(v.bounds)) continue;
        // (wholly past volumetric_fog_length: Godot's froxels end there,
        // and every chord does: fogChord)
        if (v.hasBounds && volumeDistance(v, eye) > fog.length) continue;
        candidates.push(i);
    }
    const inView = candidates.length;
    out.inView = inView;
    const room = MAX_FRAME_FOG_VOLUMES - n;
    if (inView > room) {
        // The `room` best by (world shape, distance, scene order): each
        // pass keeps the best of those left (16 passes at most).
        if (kept.length < inView) kept.length = inView;
        for (let c = 0; c < inView; c++) unchecked(kept[c] = false);
        for (let r = 0; r < room; r++) {
            let best = -1;
            let bestWorld = false;
            let bestD: f32 = 0;
            for (let c = 0; c < inView; c++) {
                if (unchecked(kept[c])) continue;
                const v = unchecked(vols[unchecked(candidates[c])]);
                const world = !v.hasBounds;
                const d = volumeDistance(v, eye);
                if (best < 0 || (world && !bestWorld) || (world == bestWorld && d < bestD)) {
                    best = c;
                    bestWorld = world;
                    bestD = d;
                }
            }
            unchecked(kept[best] = true);
        }
        out.dropped = inView - room;
    }
    for (let c = 0; c < inView; c++) {
        const i = unchecked(candidates[c]);
        if (inView > room && !unchecked(kept[c])) {
            out.droppedVolumes.push(i);
            continue;
        }
        unchecked(out.entries[n] = i);
        unchecked(out.distances[n] = volumeDistance(unchecked(vols[i]), eye));
        n++;
    }
    out.count = n;
}

// Chooses `f`'s fog for its camera into `out` (reset first) and returns
// it, setting every item's DrawItem.fogVolumes (with `used`, only those of
// the items it marks: the header). A frame whose volumetric fog is off
// leaves every item's list empty.
export function prepareFogVolumes(f: RenderFrame, out: FogPlan, used: Array<bool>? = null): FogPlan {
    clearFrameFog(f);
    planFogPool(f, out);
    const n = out.count;
    if (n == 0) return out;
    const eye = f.camera.eye;
    const ortho = f.camera.isOrtho();
    const forward = cameraForward(f);
    const vols = f.fogVolumes;

    // The order the items and the sky take the entries in: the
    // Environment's first (distance 0, entry 0), then the nearest, ties in
    // pool order (an insertion sort of at most 16, stable).
    const ranked = out.ranked;
    for (let k = 0; k < n; k++) {
        const d = unchecked(out.distances[k]);
        let j = k;
        while (j > 0 && unchecked(out.distances[unchecked(ranked[j - 1])]) > d) {
            unchecked(ranked[j] = unchecked(ranked[j - 1]));
            j--;
        }
        unchecked(ranked[j] = k);
    }

    // --- the sky ---------------------------------------------------------
    const skyCount = min<i32>(n, MAX_OBJECT_FOG_VOLUMES);
    let sky: u32 = 0;
    for (let k = 0; k < skyCount; k++) sky |= <u32>(unchecked(ranked[k]) + 1) << (<u32>k * 8);
    if (n > MAX_OBJECT_FOG_VOLUMES) sky |= FOG_LIST_ALL;
    out.sky = sky;
    out.skyCount = skyCount;

    // --- each item -------------------------------------------------------
    // (a job of FOG_GRAIN items a unit, jobs.as: each unit sets its items'
    // lists and counts in its own slots, added up after the run)
    let marks = NO_MARKS;
    if (used != null) marks = used;
    const job = fogJob;
    job.f = f;
    job.plan = out;
    job.eye = eye;
    job.ortho = ortho;
    job.forward = forward;
    job.every = used == null;
    job.marks = marks;
    const count = f.items.length;
    const units = unitCount(count, FOG_GRAIN);
    job.counts.prepare(units);
    const ex = jobs();
    // (each worker's scratch made before the run: a unit takes its own)
    while (job.boxes.length < ex.workers()) job.boxes.push(new RayBox());
    ex.run(job, count, FOG_GRAIN);
    out.items += <i32>job.counts.total(0);
    out.overBudget += <i32>job.counts.total(1);
    job.f = null;
    job.plan = null;
    job.marks = NO_MARKS;

    // --- each entry's lights ---------------------------------------------
    for (let k = 0; k < n; k++) entryLights(f, out, k);
    return out;
}

// The items a unit of prepareFogVolumes' job lists.
const FOG_GRAIN = 64;

// prepareFogVolumes' items as a job: what its units read, their counts
// (the items with a list, those past the budget), each worker's ray box.
class FogJob extends Job {
    f: RenderFrame? = null;
    plan: FogPlan? = null;
    eye: Vec3 = Vec3(0, 0, 0);
    ortho: bool = false;
    forward: Vec3 = Vec3(0, 0, -1);
    every: bool = true;
    marks: Array<bool> = NO_MARKS;
    counts: UnitCounts = new UnitCounts(2);
    boxes: Array<RayBox> = [];

    runUnit(unit: i32, begin: i32, end: i32, worker: i32): void {
        const box = unchecked(this.boxes[worker]);
        const f = this.f!;
        const out = this.plan!;
        const items = f.items;
        const vols = f.fogVolumes;
        const ranked = out.ranked;
        const n = out.count;
        const eye = this.eye;
        const ortho = this.ortho;
        const forward = this.forward;
        const marks = this.marks;
        const every = this.every;
        let listed = 0;
        let over = 0;
        for (let i = begin; i < end; i++) {
            const d = unchecked(items[i]);
            if (d.mesh == null || d.scenario != f.scenario || d.castShadow == CAST_SHADOW_SHADOWS_ONLY) continue;
            if (!every && !(i < marks.length && unchecked(marks[i]))) continue;
            if (d.hasBounds) rayBoxOf(d.bounds, eye, ortho, forward, box);
            // (the box in locals: read once an item, not once a volume)
            const lx = box.lx, ly = box.ly, lz = box.lz;
            const hx = box.hx, hy = box.hy, hz = box.hz;
            let word: u32 = 0;
            let m = 0;
            let meets = 0;
            for (let r = 0; r < n; r++) {
                const k = unchecked(ranked[r]);
                const e = unchecked(out.entries[k]);
                if (e != FOG_ENTRY_ENVIRONMENT) {
                    const v = unchecked(vols[e]);
                    if (v.hasBounds && d.hasBounds) {
                        // (rayBoxMeets, on the locals)
                        const a = v.bounds;
                        if (!(a.min.x <= hx && a.max.x >= lx && a.min.y <= hy && a.max.y >= ly && a.min.z <= hz
                            && a.max.z >= lz)) {
                            continue;
                        }
                    }
                }
                meets++;
                if (m == MAX_OBJECT_FOG_VOLUMES) {
                    word |= FOG_LIST_ALL;
                    break;
                }
                word |= <u32>(k + 1) << (<u32>m * 8);
                m++;
            }
            d.fogVolumes = word;
            if (m > 0) listed++;
            if (meets > MAX_OBJECT_FOG_VOLUMES) over++;
        }
        this.counts.add(unit, 0, <i64>listed);
        this.counts.add(unit, 1, <i64>over);
    }
}

const fogJob = new FogJob();

// Empties every item's list of `f` (a probe's capture draws no fog: the
// renderer clears the lists its items share with the main view).
export function clearFrameFog(f: RenderFrame): void {
    const items = f.items;
    for (let i = 0; i < items.length; i++) clearItemFog(unchecked(items[i]));
}

// The distance from `eye` to volume `v`'s box (0 inside it, and for a
// world shape).
function volumeDistance(v: FogVolumeDesc, eye: Vec3): f32 {
    if (!v.hasBounds) return 0;
    const b = v.bounds;
    const dx = eye.x < b.min.x ? b.min.x - eye.x : eye.x > b.max.x ? eye.x - b.max.x : <f32>0;
    const dy = eye.y < b.min.y ? b.min.y - eye.y : eye.y > b.max.y ? eye.y - b.max.y : <f32>0;
    const dz = eye.z < b.min.z ? b.min.z - eye.z : eye.z > b.max.z ? eye.z - b.max.z : <f32>0;
    return Mathf.sqrt(dx * dx + dy * dy + dz * dz);
}

// The box pool entry `k`'s lights are chosen for: its volume's, or for a
// world shape and the Environment's fog the eye's within the fog's length
// cut to the frame's draw bounds and grown to hold the eye again (every
// ray of the fog starts there; the eye's box alone when they do not meet).
export function fogEntryBox(f: RenderFrame, plan: FogPlan, k: i32): Bounds {
    const e = unchecked(plan.entries[k]);
    if (e != FOG_ENTRY_ENVIRONMENT && unchecked(f.fogVolumes[e]).hasBounds) return unchecked(f.fogVolumes[e]).bounds;
    const r = f.volumetricFog.length;
    const eye = f.camera.eye;
    let lo = eye - Vec3(r, r, r);
    let hi = eye + Vec3(r, r, r);
    if (f.hasDrawBounds) {
        const db = f.drawBounds;
        const cl = lo.max(db.min);
        const ch = hi.min(db.max);
        if (cl.x <= ch.x && cl.y <= ch.y && cl.z <= ch.z) {
            lo = cl.min(eye);
            hi = ch.max(eye);
        }
    }
    return Bounds(lo, hi);
}

// Pool entry `k`'s lights (see the header) into out.lights0, lights1 and
// lightCounts.
function entryLights(f: RenderFrame, out: FogPlan, k: i32): void {
    const box = scratch;
    box.hasBounds = true;
    box.bounds = fogEntryBox(f, out, k);
    assignBoxLights(f, f.lightPlan, box, true);
    unchecked(out.lights0[k] = box.lights0);
    unchecked(out.lights1[k] = box.lights1);
    unchecked(out.lightCounts[k] = box.lightCount);
}

// The light pool entry pool entry `k` of `plan` takes j-th (0 <= j <
// plan.lightCounts[k]).
export function fogEntryLightAt(plan: FogPlan, k: i32, j: i32): i32 {
    const word = j < 4 ? unchecked(plan.lights0[k]) : unchecked(plan.lights1[k]);
    return <i32>((word >> (<u32>(j & 3) * 8)) & 0xff);
}

// A key of `plan`'s dropped set (0 when none): the editor warns again
// only when it changes.
export function fogDroppedKey(plan: FogPlan): u64 {
    if (plan.dropped <= 0) return 0;
    let h: u64 = 1469598103934665603;
    const d = plan.droppedVolumes;
    for (let i = 0; i < d.length; i++) {
        h ^= <u64>(unchecked(d[i]) + 1);
        h *= 1099511628211;
    }
    return h == 0 ? 1 : h;
}

// The warning of a view whose frustum holds more fog volumes than the
// pool (MAX_FRAME_FOG_VOLUMES, the Environment's fog counted), or "" when
// `plan` dropped none: how many are in view, how many are not drawn, and
// the dropped volumes' node paths in the scene's order, the first
// FOG_WARNING_NAMED of them. Godot has no such cap (its froxels take any
// number); Hedra's fog block holds 16 (WebGL 2 has no storage buffers).
export function fogPoolWarning(f: RenderFrame, plan: FogPlan): string {
    const dropped = plan.dropped;
    if (dropped <= 0) return "";
    const names = new Array<string>();
    const d = plan.droppedVolumes;
    const shown = min<i32>(dropped, FOG_WARNING_NAMED);
    for (let k = 0; k < shown && k < d.length; k++) {
        const i = d[k];
        names.push(i >= 0 && i < f.fogVolumes.length ? f.fogVolumes[i].label : "fog volume " + i.toString());
    }
    let text = plan.inView.toString() + " fog volumes in view: " + dropped.toString() + (dropped == 1 ? " is" : " are")
        + " not drawn (at most " + MAX_FRAME_FOG_VOLUMES.toString() + " a frame): " + names.join(", ");
    if (dropped > shown) text += ", and " + (dropped - shown).toString() + " more";
    return text;
}

// No fog for item `d`.
export function clearItemFog(d: DrawItem): void {
    d.fogVolumes = 0;
}

// The k-th pool entry item `d` is seen through, or -1 (k past its list;
// FOG_LIST_ALL aside: the list's nearest MAX_OBJECT_FOG_VOLUMES).
export function itemFogAt(d: DrawItem, k: i32): i32 {
    if (k < 0 || k > 3) return -1;
    const b = <i32>((d.fogVolumes >> (<u32>k * 8)) & 0x7f);
    return b - 1;
}

// Whether volume `v` may lie between the camera and a point of item `d`'s
// box (conservative: false only when no ray of the camera to the box can
// cross it): the rays from `eye`, or with `ortho` from the camera's plane
// (through `eye`, across unit `forward`) along `forward`. A world shape
// and an item without a box: always.
export function fogVolumeMeets(
    v: FogVolumeDesc, eye: Vec3, d: DrawItem, ortho: bool = false, forward: Vec3 = Vec3(0, 0, -1),
): bool {
    if (!v.hasBounds || !d.hasBounds) return true;
    rayBoxOf(d.bounds, eye, ortho, forward, ownRayBox);
    return rayBoxMeets(v.bounds, ownRayBox);
}

// The camera's unit forward in `f`'s world, as the shader takes it
// (surface.wgsl fog_volumes' ray origin: the view matrix's third row,
// turned).
export function cameraForward(f: RenderFrame): Vec3 {
    const v = f.camera.viewMatrix();
    const back = Vec3(v.xAxis.z, v.yAxis.z, v.zAxis.z);
    const len = back.length();
    return len > 0 ? back * (<f32>-1 / len) : Vec3(0, 0, -1);
}

// The box rayBoxOf makes (rayBoxMeets tests against it): a worker's own
// (jobs.as rule 3: the items' job), or `ownRayBox` for fogVolumeMeets.
class RayBox {
    lx: f32 = 0;
    ly: f32 = 0;
    lz: f32 = 0;
    hx: f32 = 0;
    hy: f32 = 0;
    hz: f32 = 0;
}

const ownRayBox = new RayBox();

// The box holding every ray of the camera to a point of box `b`: `b` and
// the eye; in an orthographic view `b` and its eight corners moved along
// `forward` onto the camera's plane (c - forward (c - eye) . forward:
// where the shader starts each pixel's ray), which hold the rays between.
function rayBoxOf(b: Bounds, eye: Vec3, ortho: bool, forward: Vec3, box: RayBox): void {
    let lx = b.min.x, ly = b.min.y, lz = b.min.z;
    let hx = b.max.x, hy = b.max.y, hz = b.max.z;
    if (!ortho) {
        lx = Mathf.min(lx, eye.x);
        ly = Mathf.min(ly, eye.y);
        lz = Mathf.min(lz, eye.z);
        hx = Mathf.max(hx, eye.x);
        hy = Mathf.max(hy, eye.y);
        hz = Mathf.max(hz, eye.z);
    } else {
        for (let k = 0; k < 8; k++) {
            const cx = (k & 1) != 0 ? b.max.x : b.min.x;
            const cy = (k & 2) != 0 ? b.max.y : b.min.y;
            const cz = (k & 4) != 0 ? b.max.z : b.min.z;
            const t = (cx - eye.x) * forward.x + (cy - eye.y) * forward.y + (cz - eye.z) * forward.z;
            const px = cx - forward.x * t, py = cy - forward.y * t, pz = cz - forward.z * t;
            lx = Mathf.min(lx, px);
            ly = Mathf.min(ly, py);
            lz = Mathf.min(lz, pz);
            hx = Mathf.max(hx, px);
            hy = Mathf.max(hy, py);
            hz = Mathf.max(hz, pz);
        }
    }
    box.lx = lx;
    box.ly = ly;
    box.lz = lz;
    box.hx = hx;
    box.hy = hy;
    box.hz = hz;
}

// Whether box `a` meets `box` (rayBoxOf's).
function rayBoxMeets(a: Bounds, box: RayBox): bool {
    return a.min.x <= box.hx && a.max.x >= box.lx && a.min.y <= box.hy && a.max.y >= box.ly && a.min.z <= box.hz
        && a.max.z >= box.lz;
}

// The ray (from `origin` along unit `dir`, frame world) inside volume `v`,
// clipped to [0, tEnd]: into `out` ([t0, t1] in out.t0, out.t1), false when
// it misses. Step 1 of fog_volume.as's integration (surface.wgsl
// `fog_chord`, the same arithmetic): the ray taken into the node's space
// (toLocal: `t` stays metres of the frame's world) against Godot's shape
// of half size h = size / 2: the box |p| <= h; the others solve a t^2 + 2 b
// t + c <= 0 within |y| <= h.y: the ellipsoid |p / h| <= 1, the cylinder
// x^2 + z^2 <= r^2 and the cone x^2 + z^2 <= (k (h.y - y))^2 (its apex at
// +h.y, its base of radius r at -h.y: k = r / (2 h.y)), r = min(h.x,
// h.z). Every chord ends at `length` (the Environment's
// volumetric_fog_length: as far as Godot's froxels reach, so that a volume
// past it shows no fog, as in Godot; none given, no end): a world shape's
// is [0, min(tEnd, length)].
export function fogChord(
    v: FogVolumeDesc, origin: Vec3, dir: Vec3, tEnd: f32, out: FogChord, length: f32 = f32.MAX_VALUE,
): bool {
    out.t0 = 0;
    out.t1 = 0;
    let t0: f32 = 0;
    let t1: f32 = Mathf.min(tEnd, length);
    if (v.shape == FOG_SHAPE_WORLD) {
        // ([0, min(tEnd, length)] as it is)
    } else {
        const o = v.toLocal.transformPoint3(origin);
        const d = v.toLocal.transformVector3(dir);
        const h = v.size * <f32>0.5;
        slab(o.y, d.y, h.y, t0, t1);
        t0 = slabLo;
        t1 = slabHi;
        let a: f32 = 0;
        let b: f32 = 0;
        let c: f32 = -1;
        if (v.shape == FOG_SHAPE_BOX) {
            slab(o.x, d.x, h.x, t0, t1);
            slab(o.z, d.z, h.z, slabLo, slabHi);
            t0 = slabLo;
            t1 = slabHi;
        } else if (v.shape == FOG_SHAPE_ELLIPSOID) {
            const qx = o.x / h.x, qy = o.y / h.y, qz = o.z / h.z;
            const ex = d.x / h.x, ey = d.y / h.y, ez = d.z / h.z;
            a = ex * ex + ey * ey + ez * ez;
            b = qx * ex + qy * ey + qz * ez;
            c = qx * qx + qy * qy + qz * qz - <f32>1;
        } else {
            const r = Mathf.min(h.x, h.z);
            const cone = v.shape == FOG_SHAPE_CONE;
            const k = cone ? r / (<f32>2 * h.y) : <f32>0;
            const w = h.y - o.y;
            a = d.x * d.x + d.z * d.z - k * k * d.y * d.y;
            b = o.x * d.x + o.z * d.z + k * k * w * d.y;
            c = o.x * o.x + o.z * o.z - (cone ? k * k * w * w : r * r);
        }
        const disc = b * b - a * c;
        if (Mathf.abs(a) < <f32>1e-12) {
            // (linear: 2 b t + c <= 0; the box's 0 t - 1 <= 0 everywhere)
            if (Mathf.abs(b) < <f32>1e-12) {
                if (c > 0) return false;
            } else if (b > 0) {
                t1 = Mathf.min(t1, -c / (<f32>2 * b));
            } else {
                t0 = Mathf.max(t0, -c / (<f32>2 * b));
            }
        } else if (disc < 0) {
            // (nowhere when a > 0, everywhere when a < 0)
            if (a > 0) return false;
        } else {
            const s = Mathf.sqrt(disc);
            const lo = Mathf.min((-b - s) / a, (-b + s) / a);
            const hi = Mathf.max((-b - s) / a, (-b + s) / a);
            if (a > 0) {
                t0 = Mathf.max(t0, lo);
                t1 = Mathf.min(t1, hi);
            } else if (t0 < Mathf.min(t1, lo)) {
                // ((-inf, lo] and [hi, inf): the slab holds one of them,
                // the cone's other nappe being above it)
                t1 = Mathf.min(t1, lo);
            } else {
                t0 = Mathf.max(t0, hi);
            }
        }
    }
    if (!(t1 > t0)) return false;
    out.t0 = t0;
    out.t1 = t1;
    return true;
}

let slabLo: f32 = 0;
let slabHi: f32 = 0;

// [lo, hi] cut to where |o + t d| <= h, into slabLo and slabHi (a d of 0
// as 1e-12: surface.wgsl fog_chord's slabs).
function slab(o: f32, d: f32, h: f32, lo: f32, hi: f32): void {
    const dd = Mathf.abs(d) < <f32>1e-12 ? <f32>1e-12 : d;
    const a = (-h - o) / dd;
    const b = (h - o) / dd;
    slabLo = Mathf.max(lo, Mathf.min(a, b));
    slabHi = Mathf.min(hi, Mathf.max(a, b));
}

// Godot's signed distance of `shape` (half size `h`) at node-space point
// `p` (volumetric_fog.glsl; surface.wgsl `fog_density`); -1 for the world.
export function fogSdf(shape: i32, p: Vec3, h: Vec3): f32 {
    if (shape == FOG_SHAPE_ELLIPSOID) {
        const ax = p.x / h.x, ay = p.y / h.y, az = p.z / h.z;
        const bx = ax / h.x, by = ay / h.y, bz = az / h.z;
        const k0 = Mathf.sqrt(ax * ax + ay * ay + az * az);
        return k0 * (k0 - <f32>1) / Mathf.max(Mathf.sqrt(bx * bx + by * by + bz * bz), <f32>1e-12);
    }
    if (shape == FOG_SHAPE_BOX) {
        const qx = Mathf.abs(p.x) - h.x, qy = Mathf.abs(p.y) - h.y, qz = Mathf.abs(p.z) - h.z;
        const ox = Mathf.max(qx, <f32>0), oy = Mathf.max(qy, <f32>0), oz = Mathf.max(qz, <f32>0);
        return Mathf.sqrt(ox * ox + oy * oy + oz * oz) + Mathf.min(Mathf.max(qx, Mathf.max(qy, qz)), <f32>0);
    }
    const r = Mathf.min(h.x, h.z);
    if (shape == FOG_SHAPE_CYLINDER) {
        const dx = Mathf.sqrt(p.x * p.x + p.z * p.z) - r;
        const dy = Mathf.abs(p.y) - h.y;
        const ox = Mathf.max(dx, <f32>0), oy = Mathf.max(dy, <f32>0);
        return Mathf.min(Mathf.max(dx, dy), <f32>0) + Mathf.sqrt(ox * ox + oy * oy);
    }
    if (shape == FOG_SHAPE_CONE) {
        const nx = <f32>1 / Mathf.max(<f32>0.001, r * <f32>0.5);
        const ny = <f32>1 / Mathf.max(<f32>0.001, h.y);
        const len = Mathf.sqrt(nx * nx + ny * ny);
        const q = Mathf.sqrt(p.x * p.x + p.z * p.z);
        return Mathf.max((nx / len) * q + (ny / len) * (p.y - h.y), -h.y - p.y);
    }
    return -1;
}

// Godot's FogMaterial density of `v` at frame-world point `p` (node-space
// `lp`), `up` the frame's up: step 2 of fog_volume.as's integration
// (surface.wgsl `fog_density`), the height falloff's exp2 as a power of 2.
export function fogDensityAt(v: FogVolumeDesc, p: Vec3, lp: Vec3, up: Vec3): f32 {
    let rho = v.density * Mathf.min(Mathf.pow(<f32>2, -v.heightFalloff * (p.dot(up) - v.origin.dot(up))), <f32>1);
    if (v.shape != FOG_SHAPE_WORLD && v.edgeFade > 0) {
        const m = Mathf.min(v.size.x, Mathf.min(v.size.y, v.size.z));
        let x = <f32>-2 * fogSdf(v.shape, lp, v.size * <f32>0.5) / m;
        x = x < 0 ? <f32>0 : x > 1 ? <f32>1 : x;
        rho *= Mathf.pow(x, v.edgeFade);
    }
    return rho;
}

// (1 - e^-x) / x for x >= 0, without the cancellation of a small x (its
// series below 0.01, good to 1e-10 there).
export function fogExpRatio(x: f32): f32 {
    if (x < <f32>0.01) return <f32>1 - x * (<f32>0.5 - x * (<f32>1 / <f32>6 - x / <f32>24));
    return (<f32>1 - Mathf.exp(-x)) / x;
}

// The integral over [t0, t1] of density `rho` times clamp(2^(-hf u(t)), 0,
// 1), u(t) = a + b t the height above the node's origin: step 3's closed
// form (no edge fade; surface.wgsl fog_falloff_depth). The material's
// density below u = 0, 2^(-hf u) of it above, that part anchored at its
// densest end so that nothing overflows and a nearly level ray loses
// nothing to cancellation: rho 2^(-hf u_min) L (1 - e^-x) / x with x = hf
// |b| L ln 2.
export function fogFalloffDepth(rho: f32, hf: f32, a: f32, b: f32, t0: f32, t1: f32): f32 {
    if (hf * b == 0) return rho * (t1 - t0) * Mathf.min(Mathf.pow(<f32>2, -hf * a), <f32>1);
    let s = -a / b;
    s = s < t0 ? t0 : s > t1 ? t1 : s;
    const lo = b > 0 ? s : t0;
    const hi = b > 0 ? t1 : s;
    const g = fogExpRatio(hf * Mathf.abs(b) * (hi - lo) * LN2);
    const top = Mathf.min(Mathf.pow(<f32>2, -hf * Mathf.max(a + b * (b > 0 ? lo : hi), <f32>0)), <f32>1);
    return rho * ((t1 - t0) - (hi - lo) + top * (hi - lo) * g);
}

// The optical depth of volume `v` along the ray (from `origin` along unit
// `dir`, frame world) up to `tEnd`, with `up` the frame's up (the height
// falloff's): steps 1 to 3 of fog_volume.as's integration, the shader's
// arithmetic in f32 (surface.wgsl fog_entry: the CPU twin the tests hold
// the shader to, and what `inspect --fog` reports). Without an edge fade
// the closed form (fogFalloffDepth); with one, FOG_SAMPLES-point
// Gauss-Legendre over the chord's two halves, split where the height
// crosses the origin's (the falloff's kink) or in the middle (a symmetric
// shape's). The chord ends at `length` (the Environment's
// volumetric_fog_length; fogChord).
export function fogOpticalDepth(
    v: FogVolumeDesc, origin: Vec3, dir: Vec3, tEnd: f32, up: Vec3, length: f32 = f32.MAX_VALUE,
): f32 {
    const ch = chordScratch;
    if (!fogChord(v, origin, dir, tEnd, ch, length)) return 0;
    const t0 = ch.t0;
    const t1 = ch.t1;
    const a = origin.dot(up) - v.origin.dot(up);
    const b = dir.dot(up);
    if (v.shape == FOG_SHAPE_WORLD || !(v.edgeFade > 0)) return fogFalloffDepth(v.density, v.heightFalloff, a, b, t0, t1);
    let split = (t0 + t1) * <f32>0.5;
    if (v.heightFalloff > 0 && -a / b > t0 && -a / b < t1) split = -a / b;
    let tau: f32 = 0;
    for (let k = 0; k < 2; k++) {
        const s0 = k == 0 ? t0 : split;
        const s1 = k == 0 ? split : t1;
        const half = (s1 - s0) * <f32>0.5;
        for (let i = 0; i < FOG_SAMPLES; i++) {
            const t = (s0 + s1) * <f32>0.5 + half * unchecked(FOG_GL_X[i]);
            const p = origin + dir * t;
            tau += unchecked(FOG_GL_W[i]) * half * fogDensityAt(v, p, v.toLocal.transformPoint3(p), up);
        }
    }
    return tau;
}

// Step 5's taking away (surface.wgsl fog_integrate, the same arithmetic
// in the same order), for the `n` (at most MAX_OBJECT_FOG_VOLUMES) volumes
// a ray crosses: their optical depths `tau` (fogOpticalDepth's) and chords
// [t0, t1]. Each volume of negative depth takes away from the positive
// ones only where its chord overlaps theirs, each one's depth taken as
// spread evenly along its chord (at most all of it there: Godot clamps a
// froxel's summed density at 0), in proportion; their light is scaled as
// their depth (`scale`, 1 when nothing was taken). `tau` is updated in
// place; returns the sum of the positive depths after.
export function fogCombineDepths(
    tau: StaticArray<f32>, t0: StaticArray<f32>, t1: StaticArray<f32>, scale: StaticArray<f32>, n: i32,
): f32 {
    for (let k = 0; k < n; k++) unchecked(scale[k] = 1);
    for (let j = 0; j < n; j++) {
        if (!(unchecked(tau[j]) < 0)) continue;
        let avail: f32 = 0;
        for (let i = 0; i < n; i++) avail += Mathf.max(unchecked(tau[i]), <f32>0) * overlapShare(i, j, t0, t1);
        const f = Mathf.min(-unchecked(tau[j]) / Mathf.max(avail, <f32>1e-12), <f32>1);
        for (let i = 0; i < n; i++) {
            if (!(unchecked(tau[i]) > 0)) continue;
            const keep = <f32>1 - overlapShare(i, j, t0, t1) * f;
            unchecked(tau[i] = unchecked(tau[i]) * keep);
            unchecked(scale[i] = unchecked(scale[i]) * keep);
        }
    }
    let sum: f32 = 0;
    for (let k = 0; k < n; k++) if (unchecked(tau[k]) > 0) sum += unchecked(tau[k]);
    return sum;
}

// The share of chord `a` that chord `b` overlaps (surface.wgsl
// fog_integrate's share).
function overlapShare(a: i32, b: i32, t0: StaticArray<f32>, t1: StaticArray<f32>): f32 {
    const o = Mathf.max(Mathf.min(unchecked(t1[a]), unchecked(t1[b])) - Mathf.max(unchecked(t0[a]), unchecked(t0[b])), <f32>0);
    return o / Mathf.max(unchecked(t1[a]) - unchecked(t0[a]), <f32>1e-6);
}

// The Environment's fog's optical depth along a ray of length `tEnd`
// (its density times the chord within its length).
export function environmentOpticalDepth(fog: VolumetricFogDesc, tEnd: f32): f32 {
    if (!fog.enabled) return 0;
    const t = Mathf.min(tEnd, fog.length);
    return t > 0 ? fog.density * t : 0;
}

// A chord: where a ray enters and leaves a volume, in metres from its
// start.
export class FogChord {
    t0: f32 = 0;
    t1: f32 = 0;
}

const chordScratch = new FogChord();

// Godot's Henyey-Greenstein phase (volumetric_fog_process.glsl):
// (1 - g^2) / (4 pi (1 + g^2 - 2 g cos)^1.5).
export function henyeyGreenstein(cosTheta: f32, g: f32): f32 {
    const g2 = g * g;
    const d = <f32>1 + g2 - <f32>2 * g * cosTheta;
    return (<f32>1 - g2) / (<f32>(4 * Math.PI) * d * Mathf.sqrt(d));
}
