// Which decals a frame draws from its camera, and which each item paints
// (milestone 33; decal.as says how a frame carries them): the renderer
// calls prepareDecals before it writes the items' uniforms, for the camera
// it draws from, as cull.as culls; `inspect --stats` calls it to count.
//
// The pool: the frame's decals in the scene's order (RenderFrame.decals),
// less those without a texture, those whose box has collapsed
// (DecalDesc.empty: a scale of 0), those whose box is wholly outside the
// camera's frustum and those faded out by their distance fade (Godot's:
// from the eye to the node's origin, faded by smoothstep(0, 1, 1 - (d -
// begin) / length) past begin, not drawn where that is 0). Past MAX_FRAME_DECALS, the nearest to the eye
// are kept (ties in the scene's order), still in the scene's order.
//
// Each item (DrawItem.decalCount, decals0, decals1): the pool's entries,
// in pool order, whose cullMask meets the item's layers and whose box
// meets the item's (an item without a box is reached by every decal its
// layers let in), the first MAX_OBJECT_DECALS of them; an item that draws
// no lit surface (no mesh) none. An instanced item (a MultiMesh) is one
// item: its box holds every instance.
//
// Worlds (milestone 34, viewport.as): only the decals of the frame's world
// (DecalDesc.scenario == RenderFrame.scenario) enter the pool, and only
// the items of that world paint any, so a decal never crosses from a
// SubViewport's own world into the main one or back. Every decal and item
// of a scene without such a SubViewport is in the frame's world.
//
// Allocates nothing: the plan's arrays are made once, the items' fields
// set in place (the editor's and the demo's soaks hold every frame to 0
// bytes).

import { DrawItem, RenderFrame } from "./frame";
import { Frustum, frameViewProj } from "./cull";
import { DecalDesc, DecalPlan, DECAL_TEXTURES, MAX_FRAME_DECALS, MAX_OBJECT_DECALS } from "./decal";

// The camera's frustum, set by every prepareDecals (kept: no allocation).
const decalFrustum = new Frustum();

// Chooses the pool and every item's decals for `f`'s camera into `out` and
// the items (see the header); returns `out`. A frame without decals leaves
// every item's list empty.
export function prepareDecals(f: RenderFrame, out: DecalPlan): DecalPlan {
    out.reset();
    const items = f.items;
    for (let i = 0; i < items.length; i++) clearItemDecals(unchecked(items[i]));
    const decals = f.decals;
    const n = decals.length;
    if (n == 0) return out;

    // 1. The candidates, in the scene's order: a texture, in the frustum,
    // not faded out. (The scratch arrays keep their storage: their length
    // is set, never their capacity shrunk.)
    decalFrustum.setFrom(frameViewProj(f));
    const eye = f.camera.eye;
    const cand = out.candidates;
    const dist = out.distances;
    const fades = out.fades;
    cand.length = 0;
    dist.length = 0;
    fades.length = 0;
    const scenario = f.scenario;
    for (let i = 0; i < n; i++) {
        const c = unchecked(decals[i]);
        if (c.scenario != scenario || c.empty || !decalHasTexture(c) || !decalFrustum.intersects(c.bounds)) continue;
        const d = eye.distance(c.origin);
        const fade = decalDistanceFade(c, d);
        if (fade <= 0) continue;
        cand.push(i);
        dist.push(d);
        fades.push(fade);
    }
    const visible = cand.length;
    out.visible = visible;

    // 2. The pool: every candidate, or past MAX_FRAME_DECALS the nearest
    // (ties in the scene's order), listed in the scene's order all the same.
    if (visible <= MAX_FRAME_DECALS) {
        for (let k = 0; k < visible; k++) {
            unchecked(out.pool[k] = unchecked(cand[k]));
            unchecked(out.fade[k] = unchecked(fades[k]));
        }
        out.count = visible;
    } else {
        // The nearest MAX_FRAME_DECALS by insertion into a sorted list (a
        // candidate equal to one already there goes after it: the scene's
        // order), then put back in the scene's order.
        const best = out.nearest;
        let m = 0;
        for (let k = 0; k < visible; k++) {
            const dk = unchecked(dist[k]);
            if (m == MAX_FRAME_DECALS && dk >= unchecked(dist[unchecked(best[m - 1])])) continue;
            let at = m < MAX_FRAME_DECALS ? m : MAX_FRAME_DECALS - 1;
            while (at > 0 && unchecked(dist[unchecked(best[at - 1])]) > dk) {
                unchecked(best[at] = unchecked(best[at - 1]));
                at--;
            }
            unchecked(best[at] = k);
            if (m < MAX_FRAME_DECALS) m++;
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
        for (let k = 0; k < m; k++) {
            const j = unchecked(best[k]);
            unchecked(out.pool[k] = unchecked(cand[j]));
            unchecked(out.fade[k] = unchecked(fades[j]));
        }
        out.count = m;
        out.dropped = visible - m;
    }

    // 3. Each item with a mesh: the pool's entries that reach it, in pool
    // order, the first MAX_OBJECT_DECALS.
    const count = out.count;
    if (count == 0) return out;
    // The entries' boxes and masks flat (decalReaches' test, without a
    // struct read per pair: 64 decals over 1,000 items is 64,000 pairs);
    // an item whose layers no entry paints is passed over at once.
    const boxes = out.boxes;
    const ms = out.masks;
    let masks: u32 = 0;
    for (let k = 0; k < count; k++) {
        const c = unchecked(decals[unchecked(out.pool[k])]);
        const b = c.bounds;
        const o = k * 6;
        unchecked(boxes[o] = b.min.x);
        unchecked(boxes[o + 1] = b.min.y);
        unchecked(boxes[o + 2] = b.min.z);
        unchecked(boxes[o + 3] = b.max.x);
        unchecked(boxes[o + 4] = b.max.y);
        unchecked(boxes[o + 5] = b.max.z);
        unchecked(ms[k] = c.cullMask);
        masks |= c.cullMask;
    }
    for (let i = 0; i < items.length; i++) {
        const d = unchecked(items[i]);
        const layers = d.layers;
        if (d.mesh == null || (layers & masks) == 0 || d.scenario != scenario) continue;
        const bounded = d.hasBounds;
        const ib = d.bounds;
        const x0 = ib.min.x, y0 = ib.min.y, z0 = ib.min.z;
        const x1 = ib.max.x, y1 = ib.max.y, z1 = ib.max.z;
        let reached = 0;
        for (let k = 0; k < count; k++) {
            if ((unchecked(ms[k]) & layers) == 0) continue;
            if (bounded) {
                const o = k * 6;
                if (unchecked(boxes[o]) > x1 || unchecked(boxes[o + 3]) < x0 || unchecked(boxes[o + 1]) > y1
                    || unchecked(boxes[o + 4]) < y0 || unchecked(boxes[o + 2]) > z1 || unchecked(boxes[o + 5]) < z0) {
                    continue;
                }
            }
            reached++;
            if (reached <= MAX_OBJECT_DECALS) addItemDecal(d, k);
        }
        if (reached > 0) out.items++;
        if (reached > MAX_OBJECT_DECALS) out.overBudget++;
    }
    return out;
}

// Whether `c` names a texture in any slot (one without paints nothing:
// Godot draws it as nothing too, and the editor warns).
export function decalHasTexture(c: DecalDesc): bool {
    const t = c.textures;
    for (let s = 0; s < DECAL_TEXTURES && s < t.length; s++) if (unchecked(t[s]) != null) return true;
    return false;
}

// Godot's distance fade of `c` at distance `d` from the eye to its origin
// (RendererSceneRenderRD's decal setup): 1 without one or before its
// begin; past it smoothstep(0, 1, 1 - (d - begin) / length), 0 for a
// length of 0 or less.
export function decalDistanceFade(c: DecalDesc, d: f32): f32 {
    if (!c.distanceFade || d <= c.fadeBegin) return 1;
    if (c.fadeLength <= 0) return 0;
    let x = <f32>1 - (d - c.fadeBegin) / c.fadeLength;
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    return x * x * (<f32>3 - <f32>2 * x);
}

// Empties item `d`'s list.
export function clearItemDecals(d: DrawItem): void {
    d.decalCount = 0;
    d.decals0 = 0;
    d.decals1 = 0;
}

// Appends pool entry `entry` (0 to 255) to item `d`'s list; false (and
// nothing changed) when it holds MAX_OBJECT_DECALS already.
export function addItemDecal(d: DrawItem, entry: i32): bool {
    const k = <i32>d.decalCount;
    if (k >= MAX_OBJECT_DECALS) return false;
    const byte = <u32>(entry & 0xff) << (<u32>(k & 3) * 8);
    if (k < 4) d.decals0 |= byte;
    else d.decals1 |= byte;
    d.decalCount = <u32>(k + 1);
    return true;
}

// The pool entry item `d` paints k-th (0 <= k < d.decalCount).
export function itemDecalAt(d: DrawItem, k: i32): i32 {
    const word = k < 4 ? d.decals0 : d.decals1;
    return <i32>((word >> (<u32>(k & 3) * 8)) & 0xff);
}

// Whether decal `c` may paint item `d`: its mask meets the item's layers,
// and its box the item's (an item without a box: always).
export function decalReaches(c: DecalDesc, d: DrawItem): bool {
    if ((c.cullMask & d.layers) == 0) return false;
    if (!d.hasBounds) return true;
    const a = c.bounds;
    const b = d.bounds;
    return a.min.x <= b.max.x && a.max.x >= b.min.x && a.min.y <= b.max.y && a.max.y >= b.min.y
        && a.min.z <= b.max.z && a.max.z >= b.min.z;
}
