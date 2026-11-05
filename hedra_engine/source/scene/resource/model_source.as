// The tools' ModelSource (milestone 40): a model read from a file (model.as)
// keeps the Hedra scene it was read into, so that the engine's renderer
// draws its meshes from the scene itself, through Hedra's mesh builder
// (engine/src/source/render/meshbuild.as), exactly as Hedra draws them. The
// engine (engine/src) knows a model only through the
// abstract ModelSource of its resource/types.as, so it carries neither the
// model kernel nor the builder; a built scene's model has no source, its meshes
// arriving prebuilt.
//
// Milestone 48: a skinned or morphed object's mesh is built from its plan
// (model_skeleton.as MeshPlan): the mesh at bind time, its armature
// modifier left out and its shape keys unmixed, each vertex one mesh
// vertex's (meshbuild.as buildVertices' `origins`), with GpuMesh.skinJoints,
// skinWeights and morphs read from that vertex. Every other object's is
// Hedra's, as before.

import { Vec3 } from "../../../base/vecmath";
import { GpuMesh, MeshUploader, MorphTarget } from "../../../render/mesh";
// (aliased: the methods of the same names below would shadow them, W1014)
import {
    MeshCache, MeshRequest, build, materialIndex as materialIndexOf, textureLayer as textureLayerOf, uv1LayerOf,
} from "../../render/meshbuild";
import { Mesh } from "../../model/mesh/mod";
import { SKIN_INFLUENCES } from "../../../scene/skeleton/model_skin";
import { MeshPlan } from "./model_skeleton";
import { Scene } from "../../model/scene";
import { ModelFormat, ModelMeshCache, ModelResource, ModelSource } from "../../../scene/resource/types";

export class KernelModelSource extends ModelSource {
    // The model as the shared model code holds it (Z up).
    scene: Scene;
    // How it was read: a glTF file's UV set 0 is its first layer, a
    // Hedra model's the layer its textures name (textureLayer).
    format: ModelFormat;
    // Milestone 48: the skinned and morphed objects' plans, by object id
    // (model.as fills them as it reads the model).
    plans: Map<u32, MeshPlan> = new Map<u32, MeshPlan>();

    constructor(scene: Scene, format: ModelFormat) {
        super();
        this.scene = scene;
        this.format = format;
    }

    objectName(id: u32): string? {
        const obj = this.scene.objects.get(id);
        return obj != null ? obj.name : null;
    }

    materialIndex(id: u32, slot: u16): i64 {
        const obj = this.scene.objects.get(id);
        if (obj == null) return -1;
        return materialIndexOf(this.scene, obj, slot);
    }

    // The UV layer set 0 is built from. A Hedra model keeps Hedra's
    // choice, the object's `textureLayer`, so it draws as Hedra draws it.
    // A glTF model's materials name their own set per texture (texCoord),
    // and `textureLayer` would be TEXCOORD_1 as soon as one texture (an
    // occlusion map, typically) uses it, which would draw every texCoord 0
    // slot with TEXCOORD_1 too; so set 0 is the first layer, TEXCOORD_0 by
    // the importer's layer order, and set 1 the second (uv1LayerOf).
    textureLayer(id: u32): string? {
        const obj = this.scene.objects.get(id);
        if (obj == null) return null;
        if (this.format != ModelFormat.Gltf) return textureLayerOf(this.scene, obj);
        const m = obj.mesh();
        if (m == null || m.uvLayers.length == 0) return null;
        return m.uvLayers[0].name;
    }

    meshCache(): ModelMeshCache {
        return new KernelMeshCache(this);
    }
}

// One meshbuild MeshCache over a KernelModelSource's scene, keyed by object
// id as Hedra's is.
export class KernelMeshCache extends ModelMeshCache {
    source: KernelModelSource;
    cache: MeshCache = new MeshCache();
    // The planned objects' meshes, built once (a model read for a scene is
    // never edited).
    planned: Map<u32, GpuMesh> = new Map<u32, GpuMesh>();

    constructor(source: KernelModelSource) {
        super();
        this.source = source;
    }

    mesh(id: u32, uploader: MeshUploader?): GpuMesh? {
        const scene = this.source.scene;
        const obj = scene.objects.get(id);
        if (obj == null) return null;
        if (this.source.plans.has(id)) return this.fromPlan(id, this.source.plans.get(id), uploader);
        const before = this.cache.builds;
        const g = this.cache.get(scene, id, obj, new MeshRequest(false, this.source.textureLayer(id), -1, true), uploader);
        this.builds += this.cache.builds - before;
        return g;
    }

    // The mesh of planned object `id`: its bind mesh built as Hedra builds
    // a mesh (the UV sets the object's own), each vertex one mesh vertex's,
    // then its skin and blend shapes read from that vertex.
    private fromPlan(id: u32, plan: MeshPlan, uploader: MeshUploader?): GpuMesh {
        if (this.planned.has(id)) {
            const had = this.planned.get(id);
            if (uploader != null && had.gpu == null) uploader.upload(had);
            return had;
        }
        const mesh = plan.bind;
        const li = mesh.uvLayerIndex(this.source.textureLayer(id));
        const layer = li >= 0 ? li : <i32>mesh.activeUv;
        const origins = new Array<u32>();
        // (no uploader yet: the skin and the blend shapes go up with it)
        const g = build(mesh, mesh, layer, -1, null, null, uv1LayerOf(layer, mesh.uvLayers.length), origins);
        fillFromPlan(g, plan, origins);
        this.builds++;
        this.planned.set(id, g);
        if (uploader != null) uploader.upload(g);
        return g;
    }
}

// `g`'s skin and blend shapes from `plan`, vertex `i` of `g` being the
// mesh vertex of loop `origins[i]` of the plan's bind mesh.
export function fillFromPlan(g: GpuMesh, plan: MeshPlan, origins: Array<u32>): void {
    const mesh = plan.bind;
    const n = g.verts.length;
    const vids = new Array<u32>(n);
    for (let i = 0; i < n; i++) vids[i] = mesh.loops.at(origins[i]).vert;
    const pj = plan.joints;
    const pw = plan.weights;
    if (pj != null && pw != null) {
        const joints = new Array<u32>(n);
        const weights = new Array<f32>(n * SKIN_INFLUENCES);
        for (let i = 0; i < n; i++) {
            const v = <i32>vids[i];
            joints[i] = pj[v];
            for (let q = 0; q < SKIN_INFLUENCES; q++) weights[i * SKIN_INFLUENCES + q] = pw[v * SKIN_INFLUENCES + q];
        }
        g.skinJoints = joints;
        g.skinWeights = weights;
    }
    const mp = plan.morphs;
    if (mp == null) return;
    const targets = new Array<MorphTarget>();
    for (let k = 0; k < mp.names.length; k++) {
        const offsets = mp.offsets[k];
        const positions = new Array<f32>(n * 3);
        for (let i = 0; i < n; i++) {
            const d = offsets[<i32>vids[i]];
            positions[i * 3] = d.x;
            positions[i * 3 + 1] = d.y;
            positions[i * 3 + 2] = d.z;
        }
        let normals: Array<f32>? = null;
        const shaped = mp.shaped[k];
        if (shaped != null) {
            const ns = loopNormals(shaped, origins);
            const out = new Array<f32>(n * 3);
            for (let i = 0; i < n; i++) {
                const d = ns[i] - g.verts[i].normal;
                out[i * 3] = d.x;
                out[i * 3 + 1] = d.y;
                out[i * 3 + 2] = d.z;
            }
            normals = out;
        }
        targets.push(new MorphTarget(mp.names[k], positions, normals));
    }
    g.morphs = targets;
}

// The normal meshbuild gives the corner of each loop of `loops` in `mesh`:
// a smooth face's corner the sum of the smooth faces around its vertex,
// normalised, a flat face's corner the face's normal.
function loopNormals(mesh: Mesh, loops: Array<u32>): Array<Vec3> {
    mesh.recalcNormals();
    const vb = <i32>mesh.verts.idBound();
    const sums = new Array<Vec3>(vb);
    const has = new Array<bool>(vb);
    for (let v = 0; v < vb; v++) {
        sums[v] = Vec3(0, 0, 0);
        has[v] = false;
    }
    const fb = mesh.faces.idBound();
    for (let f: u32 = 0; f < fb; f++) {
        const face = mesh.faces.get(f);
        if (face == null || !face.smooth) continue;
        for (let l = face.loopStart; l < face.loopStart + face.loopLen; l++) {
            const v = <i32>mesh.loops.at(l).vert;
            sums[v] = sums[v] + face.normal;
            has[v] = true;
        }
    }
    const out = new Array<Vec3>(loops.length);
    for (let i = 0; i < loops.length; i++) {
        const lp = mesh.loops.at(loops[i]);
        const face = mesh.faces.at(lp.face);
        out[i] = face.smooth && has[<i32>lp.vert] ? sums[<i32>lp.vert].normalizeOrZero() : face.normal;
    }
    return out;
}

// The Hedra scene `m` was read into; null for a model with no kernel
// behind it (a built scene's, or one the engine's readers made).
export function kernelScene(m: ModelResource): Scene? {
    const s = m.source;
    return s != null ? sourceScene(s) : null;
}

// The Hedra scene behind `s`; null when it is no KernelModelSource.
export function sourceScene(s: ModelSource): Scene? {
    if (!(s instanceof KernelModelSource)) return null;
    return (s as KernelModelSource).scene;
}
