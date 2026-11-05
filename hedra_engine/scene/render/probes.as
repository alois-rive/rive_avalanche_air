// A scene's reflection probes on its frame (milestone 20): buildSceneFrame
// (adapter.as) calls `applyReflectionProbes` once every item is gathered,
// the environment is on the frame and the lightmap (if any) applied, in the
// lit shading only. It
//   - gives the frame RenderFrame.probes (a ReflectionProbeSet) when the
//     tree has a visible ReflectionProbe (SceneTree.reflectionProbes), else
//     leaves it null, so a scene without one draws as before;
//   - makes one ReflectionProbeDesc per visible probe, the first MAX_PROBES
//     in tree order (the rest left out), with `probeDescInto`: key its
//     path from the root, scene the tree's scenePath, toWorld its global
//     transform with its scale taken out, in the frame's space
//     (SCENE_TO_MODEL * the rigid global, so probe space is the node's axes
//     in scene space), extents size / 2 (absolute values), every other
//     property as the node has it (ambient_color sRGB-decoded times
//     ambient_color_energy, the masks as u32), and `cube` its probe_data's
//     cube when the probe updates once and has one that probe/data.as
//     isProbeCube accepts (else null: captured live);
//   - sets ReflectionProbeSet.clear from the environment (lights.as
//     clearColorLinear: the colour the frame clears to behind the scene,
//     linear, before the tone map);
//   - gives every item DrawItem.layers (its GeometryInstance3D's `layers`,
//     1 for a node that has none) and DrawItem.captured (false for an
//     ArtboardSprite3D's items), in a frame that has probes only;
//   - warns "reflection probe <path> moved since its capture; drawn from
//     it: bake again" (reflection-probe-moved) when a probe drawn from its
//     bake captures, in the frame of the root of the scene that declares it
//     (`probeCaptureInScene`), from more than PROBE_MOVED_TOLERANCE away
//     from where the file says it was captured. probeDiagnostics says the
//     same of a probe the file itself moved; the frame's warning is for a
//     probe a binding or a script moves, and an answer that has both keeps
//     only the diagnostic's (../warnings.as addFrameWarnings).
// It returns how many probes the frame draws. A probe without a usable
// bake is not warned of here: ../warnings.as probeDiagnostics says so
// once, for every command (reflection-probe-no-data), as it does of too
// many probes (reflection-probe-too-many, at the first one not drawn).
//
// Planning the same tree again allocates nothing here: each probe's desc
// and the set are kept in the SceneRenderCache (cache.as ProbeSlot) and
// updated in place, and the warnings are made once.

import { MAT4_IDENTITY, Mat4, Vec3, Vec4 } from "../../base/vecmath";
import { srgbToLinear } from "../../render/image";
import { RenderFrame } from "../../render/frame";
import {
    MAX_PROBES, PROBE_AMBIENT_CONSTANT_COLOR, PROBE_AMBIENT_DISABLED, PROBE_AMBIENT_ENVIRONMENT, PROBE_UPDATE_ALWAYS,
    PROBE_UPDATE_ONCE, ReflectionProbeDesc, isProbeCube,
} from "../../render/probe/data";
import { MODEL_TO_SCENE, SCENE_TO_MODEL } from "../space";
import { SceneTree } from "../tree/tree";
import { inOwnWorld } from "../tree/viewports";
import { ArtboardSprite3D, GeometryInstance3D, ReflectionProbe, SceneNode, treeOwnWorldsEpoch } from "../tree/node";
import { SceneRenderCache } from "./cache";
import { clearColorLinear } from "./lights";

// How far (metres) a probe's capture point may be from where its bake was
// captured before the frame warns that it moved.
export const PROBE_MOVED_TOLERANCE: f32 = 0.001;

export function applyReflectionProbes(
    tree: SceneTree, f: RenderFrame, itemNodes: Array<SceneNode>, cache: SceneRenderCache, warnings: Array<string>,
): i32 {
    // The tree's probes and environment, looked for once per tree (and
    // again after a SubViewport's own_world_3d changed).
    const worlds = treeOwnWorldsEpoch();
    if (cache.probeTree !== tree || cache.probeWorlds != worlds) {
        cache.probeTree = tree;
        cache.probeWorlds = worlds;
        // (a probe in a SubViewport's own world lights that world only,
        // whose frames draw no probe: the main frame leaves it out)
        const probes = tree.reflectionProbes();
        const kept: Array<ReflectionProbe> = [];
        for (let i = 0; i < probes.length; i++) if (!inOwnWorld(probes[i])) kept.push(probes[i]);
        cache.probeNodes = kept;
        cache.probeEnvironment = tree.environment();
    }
    const all = cache.probeNodes;
    let visible = 0;
    for (let i = 0; i < all.length; i++) {
        const node = unchecked(all[i]);
        if (!node.visibleInTree()) continue;
        if (visible < MAX_PROBES) {
            const slot = cache.probeSlot(visible);
            if (slot.node !== node) {
                slot.node = node;
                slot.key = node.path();
                slot.moved = "";
            }
            probeDescInto(node, slot.key, slot.desc);
            slot.desc.scene = tree.scenePath;
            if (slot.desc.cube != null && probeMoved(node)) {
                if (slot.moved.length == 0) {
                    slot.moved = "reflection probe " + slot.key + " moved since its capture; drawn from it: bake again";
                }
                if (!warnings.includes(slot.moved)) warnings.push(slot.moved);
            }
        }
        visible++;
    }
    if (visible == 0) {
        f.probes = null;
        return 0;
    }
    const drawn = min<i32>(visible, MAX_PROBES);
    const set = cache.probeSet;
    const list = set.list;
    while (list.length > drawn) list.pop();
    for (let i = 0; i < drawn; i++) {
        const desc = cache.probeSlot(i).desc;
        if (i < list.length) {
            if (unchecked(list[i]) !== desc) unchecked(list[i] = desc);
        } else {
            list.push(desc);
        }
    }
    const we = cache.probeEnvironment;
    set.clear = clearColorLinear(we != null ? we.environment : null);
    f.probes = set;
    // The items' layers, which the probes' masks select, and whether a
    // capture draws them (a sprite faces the main camera, not a probe's).
    const items = f.items;
    const n = min<i32>(items.length, itemNodes.length);
    for (let i = 0; i < n; i++) {
        const node = unchecked(itemNodes[i]);
        const item = unchecked(items[i]);
        const isGeometry = node instanceof GeometryInstance3D;
        const isSprite = node instanceof ArtboardSprite3D;
        item.layers = isGeometry ? <u32>(node as GeometryInstance3D).layers : 1;
        item.captured = !isSprite;
    }
    return drawn;
}

// The desc of probe `node` as applyReflectionProbes makes it (the header's
// rules, `cube` included), written into `out` (nothing allocated), keyed
// `key`. Exported for the bake (a probe past MAX_PROBES is still captured)
// and the editor's gizmo (the box: toWorld and extents).
export function probeDescInto(node: ReflectionProbe, key: string, out: ReflectionProbeDesc): void {
    out.key = key;
    const r = rigidOf(node.global());
    out.toWorld = SCENE_TO_MODEL * r;
    out.toLocal = rigidInverse(r) * MODEL_TO_SCENE;
    const s = node.size;
    out.extents = Vec3(Mathf.abs(s.x) * 0.5, Mathf.abs(s.y) * 0.5, Mathf.abs(s.z) * 0.5);
    out.originOffset = node.originOffset;
    out.updateMode = node.updateMode == PROBE_UPDATE_ALWAYS ? PROBE_UPDATE_ALWAYS : PROBE_UPDATE_ONCE;
    out.intensity = node.intensity;
    out.blendDistance = node.blendDistance;
    out.maxDistance = node.maxDistance;
    out.boxProjection = node.boxProjection;
    out.interior = node.interior;
    out.enableShadows = node.enableShadows;
    const mode = node.ambientMode;
    out.ambientMode = mode >= PROBE_AMBIENT_DISABLED && mode <= PROBE_AMBIENT_CONSTANT_COLOR ? mode : PROBE_AMBIENT_ENVIRONMENT;
    const c = node.ambientColor;
    out.ambientColor = Vec3(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z)) * node.ambientColorEnergy;
    out.cullMask = <u32>node.cullMask;
    out.reflectionMask = <u32>node.reflectionMask;
    // (an `always` probe is captured every frame: a bake it names is not
    // read, as Godot has none for it)
    const data = node.probeData;
    const cube = data != null ? data.cube : null;
    out.cube = out.updateMode == PROBE_UPDATE_ONCE && cube != null && isProbeCube(cube) ? cube : null;
}

// The root of the scene that declares probe `node`: the node its capture
// point is measured from, written into its .rprobe (RprobeContent.capture)
// and compared when drawn. A node declared by a scene's file has that
// scene's root as its `owner`; an instance root that is itself a probe is
// its own scene's root.
export function probeRoot(node: SceneNode): SceneNode {
    if (node.instancePath.length > 0) return node;
    const o = node.owner;
    return o != null ? o : node;
}

// Where probe `node` captures from, in the scene space (Y up, metres) of
// the root of the scene that declares it (`probeRoot`): its origin_offset
// through its rigid global transform, taken into that root's frame
// (exactly its scene-space position for a probe of a tree whose root is
// unmoved).
export function probeCaptureInScene(node: ReflectionProbe): Vec3 {
    const p = rigidOf(node.global()).transformPoint3(node.originOffset);
    const root = probeRoot(node);
    if (root.parent == null && root.local == MAT4_IDENTITY) return p;
    return root.global().inverse().transformPoint3(p);
}

// Whether `node`'s capture point is more than PROBE_MOVED_TOLERANCE from
// where its probe_data says it was captured.
function probeMoved(node: ReflectionProbe): bool {
    const data = node.probeData;
    if (data == null) return false;
    return probeCaptureInScene(node).distance(data.capture) > PROBE_MOVED_TOLERANCE;
}

// `m` (scene space) with its scale and shear taken out: its basis columns
// normalised, then made orthonormal in the order Y, Z (Gram-Schmidt), and X
// their cross product, so the result is a rotation even for a mirrored or
// sheared node; its origin kept. A column of length 0 (a scale of 0) is
// replaced by the axis it would be.
export function rigidOf(m: Mat4): Mat4 {
    const cx = m.xAxis.truncate();
    const cy = m.yAxis.truncate();
    const cz = m.zAxis.truncate();
    let y = cy.normalizeOr(Vec3(0, 0, 0));
    if (y == Vec3(0, 0, 0)) {
        // (no Y column: the one Z and X imply, else the axis)
        y = cz.cross(cx).normalizeOr(Vec3(0, 1, 0));
    }
    let z = (cz - y * y.dot(cz)).normalizeOr(Vec3(0, 0, 0));
    if (z == Vec3(0, 0, 0)) {
        z = cx.cross(y).normalizeOr(Vec3(0, 0, 0));
        if (z == Vec3(0, 0, 0)) z = anyPerpendicular(y);
    }
    const x = y.cross(z);
    const t = m.wAxis.truncate();
    return Mat4(x.extend(0), y.extend(0), z.extend(0), Vec4(t.x, t.y, t.z, 1));
}

// A unit vector perpendicular to unit `v`.
function anyPerpendicular(v: Vec3): Vec3 {
    const a = Mathf.abs(v.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
    return (a - v * v.dot(a)).normalize();
}

// The inverse of rigid `r` (rigidOf's): its rotation transposed, its
// origin taken back, with none of a general inverse's rounding.
function rigidInverse(r: Mat4): Mat4 {
    const x = r.xAxis.truncate();
    const y = r.yAxis.truncate();
    const z = r.zAxis.truncate();
    const t = r.wAxis.truncate();
    return Mat4(
        Vec4(x.x, y.x, z.x, 0),
        Vec4(x.y, y.y, z.y, 0),
        Vec4(x.z, y.z, z.z, 0),
        Vec4(-x.dot(t), -y.dot(t), -z.dot(t), 1),
    );
}
