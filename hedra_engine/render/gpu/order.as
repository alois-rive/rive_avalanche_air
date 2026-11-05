// The opaque surfaces' draw order of the main pass (docs/engine/
// PERFORMANCE.md, "Overdraw"; Godot's RenderForwardClustered opaque list,
// `sort_by_key`). The renderer (./renderer.as drawSurfaces) gathers the
// opaque and masked ranges a view draws, each with the pipeline it binds,
// its material and the view depth of its item's box, into a kept
// OpaqueOrder, and draws them in the order of their keys:
//
//   without a depth prepass   a coarse front-to-back layer (the top
//                             ORDER_LAYER_BITS bits of the depth), then the
//                             pipeline, the material and the fine depth:
//                             near surfaces first, so that the depth test
//                             rejects what they hide before it is shaded,
//                             with few pipeline and material changes inside
//                             a layer;
//   with one                  the pipeline, the material, then the depth:
//                             the prepass already gave every pixel its
//                             nearest depth, so the main pass only saves
//                             state changes (Godot sorts the same way).
//
// The depth is the item's box centre along the camera's forward axis,
// relative to the nearest and farthest the view gathers, quantised to
// ORDER_FINE_BITS bits (an item without a box sorts at the front). The low
// ORDER_SEQ_BITS bits of every key are the range's place in the gathering
// (item order, then range order), so no two keys are equal and any sort
// gives the one stable order: ties stay in today's order.
//
// Exactness. The main pass tests lessEqual, so the order changes a pixel
// only where two opaque fragments have the same depth: there the one drawn
// last wins. Sorting never changes what is drawn, only the order among the
// opaque ranges; the blended ranges, the ranges that refract, a next pass
// (which must follow its owner) and the top pass keep their own order.
// `rendering/shading/sort_opaque: false` draws today's order.
//
// Allocation: the lists keep their storage from view to view (only their
// length is set), and the sort is a heap sort in place: a view drawn again
// allocates nothing once its lists have held as many ranges.

// The key's fields, from the top bit down.
export const ORDER_LAYER_BITS: u32 = 4;
export const ORDER_PIPELINE_BITS: u32 = 8;
export const ORDER_MATERIAL_BITS: u32 = 16;
export const ORDER_FINE_BITS: u32 = 16;
export const ORDER_SEQ_BITS: u32 = 20;
// The pipeline class of a range that keeps its place after every other,
// in the order it was gathered (a next pass, which draws its owner's
// surface again and must follow it): its key's layer and pipeline fields
// are all ones, the rest its place.
export const ORDER_PINNED: u32 = 255;

// The most ranges one order holds: the rest of a view's opaque ranges are
// drawn after them, in item order (a million ranges is far past any frame).
export const ORDER_MAX_RANGES: i32 = (1 << 20) - 1;

const FINE_SHIFT: u64 = <u64>ORDER_SEQ_BITS;
const MATERIAL_SHIFT: u64 = FINE_SHIFT + <u64>ORDER_FINE_BITS;
const PIPELINE_SHIFT: u64 = MATERIAL_SHIFT + <u64>ORDER_MATERIAL_BITS;
const LAYER_SHIFT: u64 = PIPELINE_SHIFT + <u64>ORDER_PIPELINE_BITS;
const FINE_MAX: u32 = (<u32>1 << ORDER_FINE_BITS) - 1;
const PIPELINE_MASK: u32 = (<u32>1 << ORDER_PIPELINE_BITS) - 1;
const MATERIAL_MASK: u32 = (<u32>1 << ORDER_MATERIAL_BITS) - 1;
const LAYER_MASK: u32 = (<u32>1 << ORDER_LAYER_BITS) - 1;

// The sort key of one range: `depth01` its depth from 0 (the nearest of
// the view's ranges) to 1 (the farthest), `pipeline` the class of the
// pipeline it binds (ORDER_PIPELINE_BITS bits: see renderer.as
// opaquePipelineClass), `material` the frame's material index (-1, the
// default material, sorts first), `seq` its place in the gathering, and
// `prepass` whether the view draws a depth prepass (then no layer: the
// pipeline leads). A pinned range (ORDER_PINNED) sorts after every other,
// by its place.
export function opaqueKey(prepass: bool, depth01: f32, pipeline: u32, material: i64, seq: u32): u64 {
    if (pipeline == ORDER_PINNED) {
        return (<u64>LAYER_MASK << LAYER_SHIFT) | (<u64>PIPELINE_MASK << PIPELINE_SHIFT) | <u64>(seq & <u32>ORDER_MAX_RANGES);
    }
    const fine = quantiseDepth(depth01);
    const layer: u64 = prepass ? 0 : <u64>(fine >> (ORDER_FINE_BITS - ORDER_LAYER_BITS));
    const mat: u64 = material < 0 ? 0 : <u64>min<i64>(material + 1, <i64>MATERIAL_MASK);
    return (layer << LAYER_SHIFT)
        | (<u64>(pipeline & PIPELINE_MASK) << PIPELINE_SHIFT)
        | (mat << MATERIAL_SHIFT)
        | (<u64>fine << FINE_SHIFT)
        | <u64>(seq & <u32>ORDER_MAX_RANGES);
}

// `depth01` (clamped to 0..1; NaN: 0) as ORDER_FINE_BITS bits.
export function quantiseDepth(depth01: f32): u32 {
    if (!(depth01 > 0)) return 0;
    if (depth01 >= 1) return FINE_MAX;
    return <u32>Mathf.floor(depth01 * <f32>FINE_MAX + <f32>0.5);
}

// The coarse layer of a key (0 with a prepass), its pipeline class, its
// material field (the material index + 1) and its place in the gathering.
export function keyLayer(key: u64): u32 {
    return <u32>(key >> LAYER_SHIFT);
}

export function keyPipeline(key: u64): u32 {
    return <u32>(key >> PIPELINE_SHIFT) & PIPELINE_MASK;
}

export function keyMaterial(key: u64): u32 {
    return <u32>(key >> MATERIAL_SHIFT) & MATERIAL_MASK;
}

export function keySeq(key: u64): i32 {
    return <i32>(key & <u64>ORDER_MAX_RANGES);
}

// One view's opaque ranges and their order (see the header).
export class OpaqueOrder {
    // By place in the gathering: the item and range drawn, the view depth
    // of the item's box centre (NaN: unknown), the pipeline class and the
    // material.
    items: Array<i32> = [];
    ranges: Array<i32> = [];
    depths: Array<f32> = [];
    pipelines: Array<u32> = [];
    materials: Array<i64> = [];
    // The keys, sorted by `sort`: keys[n]'s keySeq is the place of the n-th
    // range drawn.
    keys: Array<u64> = [];
    count: i32 = 0;

    // Empties the order, keeping the lists' storage.
    clear(): void {
        this.count = 0;
    }

    // Adds range `range` of item `item`: false when the order is full (the
    // caller draws it after, in item order).
    add(item: i32, range: i32, depth: f32, pipeline: u32, material: i64): bool {
        const n = this.count;
        if (n >= ORDER_MAX_RANGES) return false;
        if (n == this.items.length) {
            this.items.push(item);
            this.ranges.push(range);
            this.depths.push(depth);
            this.pipelines.push(pipeline);
            this.materials.push(material);
            this.keys.push(0);
        } else {
            unchecked(this.items[n] = item);
            unchecked(this.ranges[n] = range);
            unchecked(this.depths[n] = depth);
            unchecked(this.pipelines[n] = pipeline);
            unchecked(this.materials[n] = material);
        }
        this.count = n + 1;
        return true;
    }

    // The keys of the ranges added (`prepass`: the view draws a depth
    // prepass), sorted; with `sorted` false, the keys are the places alone,
    // so the ranges are drawn as they were gathered (today's order).
    // Allocates nothing.
    sort(prepass: bool, sorted: bool = true): void {
        const n0 = this.count;
        if (!sorted) {
            for (let i = 0; i < n0; i++) unchecked(this.keys[i] = <u64>i);
            return;
        }
        const n = this.count;
        let near: f32 = Infinity;
        let far: f32 = -Infinity;
        for (let i = 0; i < n; i++) {
            const d = unchecked(this.depths[i]);
            if (!isFinite(d)) continue;
            if (d < near) near = d;
            if (d > far) far = d;
        }
        const span = far - near;
        for (let i = 0; i < n; i++) {
            const d = unchecked(this.depths[i]);
            // (an item without a box, or a view whose ranges are all at one
            // depth: the front)
            const t: f32 = isFinite(d) && span > 0 ? (d - near) / span : 0;
            unchecked(this.keys[i] = opaqueKey(prepass, t, unchecked(this.pipelines[i]), unchecked(this.materials[i]), <u32>i));
        }
        heapSort(this.keys, n);
    }

    // The item and range drawn n-th (after `sort`).
    itemAt(n: i32): i32 {
        return unchecked(this.items[keySeq(unchecked(this.keys[n]))]);
    }

    rangeAt(n: i32): i32 {
        return unchecked(this.ranges[keySeq(unchecked(this.keys[n]))]);
    }
}

// The first `n` keys of `a` in increasing order, in place (a heap sort: no
// allocation, n log n; the keys are distinct, so the order is the one order).
export function heapSort(a: Array<u64>, n: i32): void {
    if (n < 2) return;
    for (let start = (n >> 1) - 1; start >= 0; start--) siftDown(a, start, n);
    for (let end = n - 1; end > 0; end--) {
        const t = unchecked(a[0]);
        unchecked(a[0] = a[end]);
        unchecked(a[end] = t);
        siftDown(a, 0, end);
    }
}

function siftDown(a: Array<u64>, start: i32, end: i32): void {
    let root = start;
    while (true) {
        let child = 2 * root + 1;
        if (child >= end) return;
        if (child + 1 < end && unchecked(a[child]) < unchecked(a[child + 1])) child++;
        if (unchecked(a[root]) >= unchecked(a[child])) return;
        const t = unchecked(a[root]);
        unchecked(a[root] = a[child]);
        unchecked(a[child] = t);
        root = child;
    }
}
