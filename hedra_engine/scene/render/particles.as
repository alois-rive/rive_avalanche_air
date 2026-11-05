// How the adapter (adapter.as) draws a CPUParticles3D (milestone 35;
// docs/engine/PARTICLES.md): as one instanced DrawItem of the node's mesh,
// its instances the particle state's own dynamic InstanceData
// (../particles/state.as, packed by ../particles/pack.as), its world the
// node's (SCENE_TO_MODEL x global, as a MultiMeshInstance3D's: the packed
// transforms are in the node's space), its materials the mesh's surfaces'
// (Godot 4's CPUParticles3D draws its mesh's materials), its shadow,
// visibility range and layers the node's as any GeometryInstance3D's.
//
// The item is drawn for every visible emitter whose mesh has triangles,
// even with no particle alive (InstanceData.count 0: the renderer draws it
// in no pass, render/cull.as), so a frame refreshes in place while the
// particles come and go; a node without a mesh, or hidden, has none
// (warnings.as says so of the first: particles-no-mesh).
//
// The camera: billboards (the mesh's first surface's material's
// billboard_mode) and view_depth depend on it, so the adapter gathers
// those emitters' boxes without packing (pack.as particleBounds: a
// billboard's box holds from every camera), and `orientParticles` packs
// them once the frame's camera is chosen, and again on every
// retargetSceneFrame (the preview's moving frames). The camera is the
// frame's (RenderFrame.camera, the view planned: a SubViewport's frame
// shares the main frame's items, so its billboards face the main view's
// camera, as an ArtboardSprite3D's), taken into each node's space by the
// inverse of its global transform. Every other emitter is packed as it is
// gathered. A pack that nothing moved does nothing (pack.as).
//
// Planning allocates a ParticleDraw per emitter; refreshing and orienting
// allocate nothing.

import { MAT4_IDENTITY, Mat4, Vec3 } from "../../base/vecmath";
import { Bounds } from "../../render/camera";
import { RenderFrame } from "../../render/frame";
import { modelToScene } from "../space";
import { Mesh, StandardMaterial3D } from "../resource/types";
import { CPUParticles3D } from "../tree/node";
import { BILLBOARD_DISABLED } from "../particles/state";
import { ParticleBox, packNeedsCamera, packParticles, particleBounds } from "../particles/pack";

// One emitter's item in a frame (SceneFrame.particleDraws, in item order).
export class ParticleDraw {
    node: CPUParticles3D;
    // Its index in frame.items.
    item: i32;
    // The material its billboard is read from (its mesh's first surface's;
    // null: none, no billboard), read at every pack so that a keyed or
    // bound billboard_mode acts at once.
    material: StandardMaterial3D?;
    // The node's global transform (scene space) and the mesh's box, as last
    // gathered.
    global: Mat4 = MAT4_IDENTITY;
    meshLocal: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    // The mesh resource it was planned with (refreshSceneParticles keeps
    // the item while the node holds the same).
    mesh: Mesh? = null;
    // The box last gathered without a pack (a billboard's, view_depth's),
    // and what it was gathered from, so that a frame in which nothing
    // moved works out nothing (gatherParticles).
    box: ParticleBox = new ParticleBox();
    boxVersion: u32 = 0xffffffff;
    boxGlobal: Mat4 = MAT4_IDENTITY;
    boxLocal: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    boxBillboard: i32 = -1;
    boxKeep: bool = false;
    boxCount: i32 = 0;

    constructor(node: CPUParticles3D, item: i32, material: StandardMaterial3D?) {
        this.node = node;
        this.item = item;
        this.material = material;
    }
}

function sameMat4(a: Mat4, b: Mat4): bool {
    return a.xAxis == b.xAxis && a.yAxis == b.yAxis && a.zAxis == b.zAxis && a.wAxis == b.wAxis;
}

// The kept box of orientParticles' packs.
const gathered = new ParticleBox();

// The billboard mode and keep_scale of `d`'s material.
function billboardOf(d: ParticleDraw): i32 {
    const m = d.material;
    return m != null ? m.billboardMode : BILLBOARD_DISABLED;
}

function keepScaleOf(d: ParticleDraw): bool {
    const m = d.material;
    return m != null && m.billboardKeepScale;
}

// `d`'s particles gathered (see the header): their box in the node's space
// into `out` (`has` false when none is alive: the caller boxes the item at
// its origin), packed already when the pack needs no camera; the number
// alive.
export function gatherParticles(d: ParticleDraw, out: ParticleBox): i32 {
    const node = d.node;
    const bb = billboardOf(d);
    const keep = keepScaleOf(d);
    if (packNeedsCamera(node, bb)) {
        const s = node.particles;
        if (s == null) {
            out.has = false;
            return 0;
        }
        // (the particles, the node, the mesh and the billboard as at the
        // last gather: the same box)
        if (d.boxVersion != s.version || d.boxBillboard != bb || d.boxKeep != keep || !sameMat4(d.boxGlobal, d.global)
            || !(d.boxLocal == d.meshLocal)) {
            d.boxCount = particleBounds(node, d.global, d.meshLocal, bb, keep, d.box);
            d.boxVersion = s.version;
            d.boxBillboard = bb;
            d.boxKeep = keep;
            d.boxGlobal = d.global;
            d.boxLocal = d.meshLocal;
        }
        out.box = d.box.box;
        out.has = d.box.has;
        return d.boxCount;
    }
    packParticles(node, d.global, d.meshLocal, bb, keep, Vec3(0, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0), out);
    const s = node.particles;
    return s != null ? <i32>s.instances.count : 0;
}

// Packs every emitter of `draws` whose pack depends on the camera, for
// `frame`'s camera (see the header); returns the particles the frame draws
// (every item's count: SceneFrame.particles). Allocates nothing.
export function orientParticles(frame: RenderFrame, draws: Array<ParticleDraw>): i32 {
    if (draws.length == 0) return 0;
    const c = frame.camera;
    // Render space is Z up; the particles are in the scene's Y up.
    const eye = modelToScene(c.eye);
    const view = modelToScene(c.target) - eye;
    const up = modelToScene(c.up);
    let drawn = 0;
    for (let i = 0; i < draws.length; i++) {
        const d = unchecked(draws[i]);
        const node = d.node;
        const s = node.particles;
        if (s == null) continue;
        const bb = billboardOf(d);
        if (packNeedsCamera(node, bb)) {
            const inv = d.global.inverse();
            packParticles(node, d.global, d.meshLocal, bb, keepScaleOf(d), inv.transformPoint3(eye),
                inv.transformVector3(view), inv.transformVector3(up), gathered);
        }
        drawn += <i32>s.instances.count;
    }
    return drawn;
}
