// Light probes (milestone 19, Godot's LightmapProbe and LightmapGI's
// automatic probes): where a bake places them, and the light an item that
// is not lightmapped takes from them at draw time.
//
// Placement and baking are the baker's (baker.as, its `probes` phase): the
// LightmapProbe nodes, then a grid over the static geometry's box with
// LIGHTMAP_PROBE_SUBDIV[settings.generateProbesSubdiv] cells along its
// longest side (and as many along the others as cells of that size take to
// cover them, at least one), a probe at each corner, those inside geometry
// (more than half of their rays reaching a back face) left out. The grid
// is clipped to the box: its corners span the box less a tenth of a cell
// at each face, so that no probe lies under a floor, outside the outer
// faces of the walls or on a face itself. `probeGrid` lists the
// grid's points; the baker filters and bakes them.
//
// At draw time an item takes `probeShAt` at the centre of its box: the
// probes weighted by the inverse square of their distance (plus 1e-4, so a
// probe at the very point does not divide by zero), the PROBE_NEIGHBOURS
// nearest only, nearer first and the lower index first between equals, so
// the answer is the same whatever the probes' order in memory.

import { Vec3 } from "../../base/vecmath";
import { Bounds } from "../camera";
import { LightmapProbeSet } from "./data";
import { SH_L1_FLOATS, shAddScaled, shClear } from "./sh";

// How many of the nearest probes an item's light is interpolated from.
export const PROBE_NEIGHBOURS: i32 = 8;

// The corners of the automatic grid over `box` (the static geometry's,
// frame world space) with `cells` cells along its longest side: x fastest,
// then y, then z. Empty for `cells` 0. A side takes as many cells of the
// longest side / `cells` as cover it (at least one; none when it is flat),
// and its corners are spread evenly over the side less PROBE_INSET of a
// cell at each end (a quarter of the side at most): a room 8 x 3 x 6.5 m
// at 8 cells has 8 x 3 x 7 cells, so 9 x 4 x 8 corners, x from 0.1 to 7.9
// m, every one inside the box.
export function probeGrid(box: Bounds, cells: i32): Array<Vec3> {
    const out = new Array<Vec3>();
    if (cells <= 0) return out;
    const ex = <f64>box.max.x - <f64>box.min.x;
    const ey = <f64>box.max.y - <f64>box.min.y;
    const ez = <f64>box.max.z - <f64>box.min.z;
    const longest = Math.max(ex, Math.max(ey, ez));
    if (!(longest > 0)) {
        const cx = (<f64>box.max.x + <f64>box.min.x) * 0.5;
        const cy = (<f64>box.max.y + <f64>box.min.y) * 0.5;
        const cz = (<f64>box.max.z + <f64>box.min.z) * 0.5;
        out.push(Vec3(<f32>cx, <f32>cy, <f32>cz));
        return out;
    }
    const size = longest / <f64>cells;
    const nx = cellsAlong(ex, longest, size), ny = cellsAlong(ey, longest, size), nz = cellsAlong(ez, longest, size);
    for (let k = 0; k <= nz; k++) {
        const z = cornerAt(<f64>box.min.z, ez, nz, k, size);
        for (let j = 0; j <= ny; j++) {
            const y = cornerAt(<f64>box.min.y, ey, ny, j, size);
            for (let i = 0; i <= nx; i++) {
                out.push(Vec3(<f32>cornerAt(<f64>box.min.x, ex, nx, i, size), <f32>y, <f32>z));
            }
        }
    }
    return out;
}

// How far inside the box's faces the grid's outer corners lie, in cells.
export const PROBE_INSET: f64 = 0.1;

// The cells of `size` that cover `extent` (at least one; a side within a
// millionth of a whole number of cells takes that number), none for a
// side flat against the longest (`longest`).
function cellsAlong(extent: f64, longest: f64, size: f64): i32 {
    if (!(extent > longest * 1e-6)) return 0;
    return max<i32>(<i32>Math.ceil(extent / size - 1e-6), 1);
}

// Corner `i` of `n` along a side from `lo` of `extent` (its middle when
// the side has no cell).
function cornerAt(lo: f64, extent: f64, n: i32, i: i32, size: f64): f64 {
    if (n == 0) return lo + extent * 0.5;
    const inset = Math.min(PROBE_INSET * size, extent * 0.25);
    return lo + inset + (extent - 2 * inset) * <f64>i / <f64>n;
}

// Kept between calls: the stub allocator never frees, and the adapter
// asks once per unlit item of every planned frame.
const nearIndex = new Int32Array(PROBE_NEIGHBOURS);
const nearDist = new Float64Array(PROBE_NEIGHBOURS);

// The light at `p` (frame world space) interpolated from `set` into `out`
// at `at` (SH_L1_FLOATS numbers: sh.as). False, `out` zeroed, when the set
// has no probe. Allocates nothing.
export function probeShAt(set: LightmapProbeSet, p: Vec3, out: Float32Array, at: i32 = 0): bool {
    shClear(out, at);
    const n = set.count;
    if (n == 0) return false;
    let found = 0;
    for (let i = 0; i < n; i++) {
        const q = set.positions[i];
        const dx = <f64>q.x - <f64>p.x, dy = <f64>q.y - <f64>p.y, dz = <f64>q.z - <f64>p.z;
        const d = dx * dx + dy * dy + dz * dz;
        // Insertion into the sorted list of the nearest; an equal distance
        // keeps the earlier probe first.
        let k = found;
        while (k > 0 && nearDist[k - 1] > d) k--;
        if (k >= PROBE_NEIGHBOURS) continue;
        const last = found < PROBE_NEIGHBOURS ? found : PROBE_NEIGHBOURS - 1;
        for (let j = last; j > k; j--) {
            nearDist[j] = nearDist[j - 1];
            nearIndex[j] = nearIndex[j - 1];
        }
        nearDist[k] = d;
        nearIndex[k] = i;
        if (found < PROBE_NEIGHBOURS) found++;
    }
    let total: f64 = 0;
    for (let k = 0; k < found; k++) total += 1.0 / (nearDist[k] + 1e-4);
    for (let k = 0; k < found; k++) {
        const w = <f32>((1.0 / (nearDist[k] + 1e-4)) / total);
        shAddScaled(out, at, set.sh, nearIndex[k] * SH_L1_FLOATS, w);
    }
    return true;
}
