// A model's blend shapes, read for a scene (docs/formats/IMPORT.md,
// "Skins, blend shapes and animations"): a mesh's shape keys (an .rmdl's,
// and a glTF file's morph targets, which the importer reads into shape keys
// named by the mesh's `extras.targetNames`, else `Key_<i>`, valued by the
// mesh's then the node's `weights`) as ModelObject.blendShapes and
// .blendShapeWeights, and each one's offsets per vertex of the mesh at bind
// time for the mesh cache (MorphPlan; GpuMesh.morphs, model_source.as).
//
// A key is relative (the kernel's only mode): at weight w it adds w * (key -
// the key it is relative to) to the basis, before the modifiers. An offset
// is therefore taken after them: the stack (the armature's left out when
// the mesh is skinned, as for its bind mesh) is evaluated with the key at
// weight 1 and with every key at 0, and the difference per vertex is the
// offset. That is exact for the modifiers that move vertices linearly
// (mirror, subdivision, array, the armature's skinning on the GPU after
// it) and the nearest one offset can come otherwise. A key whose stack
// gives another mesh (a weld that merges differently) is left out, with a
// warning.
//
// Normals move only when the file gives a target's normals (glTF's NORMAL
// targets): their offsets are the normals of the mesh at weight 1, built as
// the mesh's own are (smooth or flat per face), less the bind mesh's.

import { Vec3, VEC3_ZERO } from "../../../base/vecmath";
import { Mesh } from "../../model/mesh/mod";
import { Modifier, Scene } from "../../model/scene";
import { ModifierEnv, evaluate as evaluateStack } from "../../model/modifiers/mod";
import { ModelResource } from "../../../scene/resource/types";
import { GltfImportMap } from "../../io/gltf_to_model/gltf_import";

// The mesh `mods` make of `base` but for the modifier at `skip` (-1:
// none), with the scene as `id`'s stack is evaluated; a copy.
export function evaluateWithout(scene: Scene, id: u32, base: Mesh, mods: Array<Modifier>, skip: i32): Mesh {
    const stack = new Array<Modifier>();
    for (let i = 0; i < mods.length; i++) if (i != skip) stack.push(mods[i]);
    return evaluateStack(base, stack, new ModifierEnv(scene, id, 0)).mesh;
}

// A mesh's blend shapes: names and weights as the file sets them (a muted
// key weighs 0), and per shape its offset per vertex id of the bind mesh
// (model space), and the bind mesh at weight 1 when its normals move too
// (else null).
export class MorphPlan {
    names: Array<string> = [];
    weights: Array<f32> = [];
    offsets: Array<Array<Vec3>> = [];
    shaped: Array<Mesh?> = [];
}

// `base` with each vertex at basis + (key `k` - the key it is relative to).
function withKeyAtOne(base: Mesh, k: i32): Mesh {
    const out = base.clone();
    const keys = base.shapeKeys;
    const key = keys[k];
    const last = keys.length - 1;
    const rel = <i32>key.relativeTo <= last ? <i32>key.relativeTo : last;
    const bound = out.verts.idBound();
    for (let v: u32 = 0; v < bound; v++) {
        const vert = out.verts.get(v);
        if (vert == null) continue;
        const basis = <i32>v < keys[0].positions.length ? keys[0].positions[<i32>v] : vert.co;
        const at = <i32>v < key.positions.length ? key.positions[<i32>v] : vert.co;
        const from = rel != k && <i32>v < keys[rel].positions.length ? keys[rel].positions[<i32>v] : (rel == k ? at : vert.co);
        vert.co = basis + (at - from);
    }
    out.recalcNormals();
    out.touch();
    return out;
}

// Whether `a` and `b` have the same live vertex ids.
function sameVertices(a: Mesh, b: Mesh): bool {
    const n = a.verts.idBound();
    if (b.verts.idBound() != n) return false;
    for (let v: u32 = 0; v < n; v++) if ((a.verts.get(v) == null) != (b.verts.get(v) == null)) return false;
    return true;
}

// Whether the glTF mesh of scene object `id` gives normals for its
// targets.
function gltfTargetNormals(map: GltfImportMap, id: u32): bool {
    const nodes = map.objOfNode.keys();
    for (let i = 0; i < nodes.length; i++) {
        if (map.objOfNode.get(nodes[i]) != id) continue;
        const node = map.document.nodes[nodes[i]];
        if (node.mesh < 0) continue;
        const prims = map.document.meshes[node.mesh].primitives;
        for (let p = 0; p < prims.length; p++) {
            const ts = prims[p].targets;
            if (ts == null) continue;
            for (let t = 0; t < ts.length; t++) if (ts[t].normals >= 0) return true;
        }
    }
    return false;
}

// The blend shapes of scene object `id` (whose base mesh `base` has shape
// keys beyond its basis), against `bind` (its bind mesh, the modifier at
// `skip` left out of its stack, -1 none); `gltf` the document of a glTF
// model, for its targets' normals; null when none is left. Warnings go to
// `m`.
export function readMorphs(scene: Scene, gltf: GltfImportMap?, m: ModelResource, id: u32, base: Mesh, mods: Array<Modifier>,
    skip: i32, bind: Mesh): MorphPlan? {
    const keys = base.shapeKeys;
    const name = scene.objects.at(id).name;
    const normals = gltf != null && gltfTargetNormals(gltf, id);
    const plan = new MorphPlan();
    const bound = bind.verts.idBound();
    for (let k = 1; k < keys.length; k++) {
        const key = keys[k];
        const shaped = evaluateWithout(scene, id, withKeyAtOne(base, k), mods, skip);
        if (!sameVertices(shaped, bind)) {
            m.warnings.push("mesh '" + name + "': blend shape '" + key.name + "' changes the mesh its modifiers make; it is left out");
            continue;
        }
        const offsets = new Array<Vec3>(<i32>bound);
        for (let v: u32 = 0; v < bound; v++) {
            const a = shaped.verts.get(v);
            const b = bind.verts.get(v);
            offsets[<i32>v] = a != null && b != null ? a.co - b.co : VEC3_ZERO;
        }
        plan.names.push(key.name);
        plan.weights.push(key.mute ? <f32>0 : key.clampedValue());
        plan.offsets.push(offsets);
        plan.shaped.push(normals ? shaped : null);
    }
    return plan.names.length > 0 ? plan : null;
}
