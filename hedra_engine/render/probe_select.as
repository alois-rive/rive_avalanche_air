// The reflection probes each item is lit by (Godot's Mobile renderer keeps
// a list of probes per instance; Forward+ a cluster's: docs/engine/
// SHADING.md, "Specialised shaders"): bit r of an item's probe mask is the
// frame's probe of atlas row r (ReflectionProbeSet.list[r], r below
// MAX_PROBES), set when the probe's box meets the item's box and its
// reflection mask meets the item's layers. ObjectUniform.extra.z carries it
// (frame.as itemUniformInto), and surface.wgsl's probe_reflection and
// probe_ambient weigh only the probes it names, in the frame's order, so
// that a pixel weighs the one or two probes around its item rather than
// every probe of the frame.
//
// Exact: a probe left out has a weight of 0 at every point of the item
// (data.as probeWeight: 0 outside its box), or does not reflect in it, so
// the sums the shader makes are the ones it made weighing every probe. The
// box test is conservative: the probe's box (oriented, probe space) is
// taken as the world box around it, grown by a margin past any rounding of
// the shader's own test (a point on a face weighs 1 without a blend
// distance), and an item without a box meets every probe.
//
// Allocates nothing.

import { Vec3 } from "../base/vecmath";
import { Bounds } from "./camera";
import { MAX_PROBES, ReflectionProbeDesc, ReflectionProbeSet } from "./probe/data";

// How much the probe's world box grows past its faces: a thousandth of its
// size and a millimetre (the shader's test is in f32 in probe space, the
// box here in f32 in world space).
const PROBE_BOX_MARGIN: f32 = 1e-3;
const PROBE_BOX_MARGIN_ABS: f32 = 1e-3;

// Whether probe `p`'s box, as a world box grown by the margin, meets the
// world box `lo` .. `hi`.
export function probeBoxMeets(p: ReflectionProbeDesc, lo: Vec3, hi: Vec3): bool {
    const m = p.toWorld;
    const e = p.extents;
    const c = m.wAxis;
    // (the world half size of the box's three axes, each a column of the
    // rigid transform times its half extent)
    const x = m.xAxis;
    const y = m.yAxis;
    const z = m.zAxis;
    const hx = Mathf.abs(x.x) * e.x + Mathf.abs(y.x) * e.y + Mathf.abs(z.x) * e.z;
    const hy = Mathf.abs(x.y) * e.x + Mathf.abs(y.y) * e.y + Mathf.abs(z.y) * e.z;
    const hz = Mathf.abs(x.z) * e.x + Mathf.abs(y.z) * e.y + Mathf.abs(z.z) * e.z;
    const grow = PROBE_BOX_MARGIN * (hx + hy + hz) + PROBE_BOX_MARGIN_ABS;
    const ex = hx + grow;
    const ey = hy + grow;
    const ez = hz + grow;
    // (written so that a NaN anywhere meets: every comparison with NaN is
    // false, and a box that cannot be told apart keeps its probe)
    if (c.x - ex > hi.x || c.x + ex < lo.x) return false;
    if (c.y - ey > hi.y || c.y + ey < lo.y) return false;
    if (c.z - ez > hi.z || c.z + ez < lo.z) return false;
    return true;
}

// The probe mask of an item of visual layers `layers` and world box
// `bounds` (`hasBounds` false: none, every probe meets it) in a frame whose
// probes are `set` (null: none, the mask 0).
export function itemProbeMask(set: ReflectionProbeSet?, layers: u32, hasBounds: bool, bounds: Bounds): u32 {
    if (set == null) return 0;
    const list = set.list;
    const n = min<i32>(list.length, MAX_PROBES);
    let mask: u32 = 0;
    for (let r = 0; r < n; r++) {
        const p = unchecked(list[r]);
        if ((layers & p.reflectionMask) == 0) continue;
        if (hasBounds && !probeBoxMeets(p, bounds.min, bounds.max)) continue;
        mask |= <u32>1 << <u32>r;
    }
    return mask;
}
