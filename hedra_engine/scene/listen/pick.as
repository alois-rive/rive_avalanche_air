// What a pointer hits, for state machine listeners (milestone 47;
// docs/plans/RIVE_MODEL.md section 3.5; docs/engine/STATE_MACHINES.md
// "Listeners"): the ray through the pointer, cast into what the last
// picture drew and into the collision objects listeners listen to, every
// hit along it nearest first, up to and including the first opaque one.
//
// What is hit:
//
//   - a drawn item (a SceneFrame item: a mesh, a model's part, a
//     MultiMesh's instance, an ArtboardSprite3D's quad) whose node is a
//     GeometryInstance3D with input_ray_pickable (true unless set false), by
//     its triangles as drawn: through a BVH per mesh kept here
//     (render/raycast.as TriBvh, built once with the surface-area split, in
//     the mesh's space, of every visible face, with a table from each face
//     to its first index for the texture coordinates and the material), a
//     skinned item at its posed vertices (the shader's skinning done here,
//     on the CPU, into a copy kept per mesh and palette, and that copy's
//     BVH refitted in place, never rebuilt: the triangles keep their order;
//     only when the palette's skinVersion or the mesh's vertsRevision
//     moved), a mesh with blend shapes at its blended copy (the copy's
//     vertsRevision: refitted the same way); whatever the picture does not
//     show is not hit (shadows only, outside its visibility range, a hidden
//     node: not in the frame; a one-sided sprite seen from behind), and a
//     CPUParticles3D's particles never are (milestone 35: Godot's physics
//     picking never hits them, and a burst must not hide the button that
//     set it off; their item's instances are the frame's only dynamic
//     ones, render/instances.as InstanceData.dynamic). Every
//     such item takes part, listened to or not, so that a wall in front of
//     a button hides it. An item drawn without the depth test (an
//     ArtboardSprite3D's no_depth_test) is in front of every other, as the
//     picture shows it and engine/src/authoring/render/pick.as picks it: its hits
//     come first, nearest first, then the others';
//   - a CollisionObject3D with input_ray_pickable that is a listener's
//     target or under one (`groups`), by its shapes (interaction/world.as,
//     as the last sync left them: the caller syncs). Collision objects
//     nobody listens to are invisible and hide nothing.
//
// Where an item is: as planned, moved by its node's motion since (the
// node's global transform now times its inverse at the plan,
// SceneFrame.itemGlobals): a headless host (`rive --data-dump`) may draw
// no frame after the first, and a door that opened since is hit where it
// is, not where the plan drew it. A moved item's box is the plan's no
// longer, so it is tested by its triangles alone. A skinned MeshInstance3D
// is where its skeleton's pose puts it now (the renderer's palette worked
// out again here, render/skinning.as SkinState: only when the pose or the
// skeleton moved; the mesh node's own transform does not place a skinned
// mesh, as in Godot), tested by its triangles alone when that palette is
// no longer the plan's. What the picture no longer shows is not hit either:
// a node hidden since the plan (it or a 3D node above it), taken out of
// the plan's tree, or freed; a collision object freed since the caller's
// last sync, or taken out of the world's tree.
//
// A hit is opaque unless its node, or a node above it, sets
// listener_pass_through. The hits are sorted by distance; those behind the
// first opaque hit are dropped (3D's occlusion: Rive's 2D draws its hits in
// draw order, the first opaque one hiding the rest). One hit per node (a
// model's parts, a MultiMesh's instances and a collision object's shapes
// are their node's: its nearest stands).
//
// Each hit says the node hit (an item's node: a model's part is its
// ModelInstance3D's; a collision object), the point and the normal in the
// scene's space (Y up, metres; the normal faces the ray), the texture
// coordinates (UV set 0 with Godot's top-left origin, interpolated over the
// triangle; none on a shape), and, when the surface shows an ArtboardTexture
// (its material's albedo texture, else its emission texture: the node's
// material_override first, then the surface's) or is an ArtboardSprite3D,
// with pointer_forward on: that texture and the point in the texture's
// pixels (u * width, v * height, through the material's uv1_scale and
// uv1_offset, wrapped into 0..1), which the run time divides by the
// texture's scale to reach the artboard's own coordinates, and how those
// pixels change across the triangle's plane (per metre, scene space), so
// that a pointer held down on the artboard and dragged off its surface
// still reaches it at the point of that plane it is over (out of the
// artboard's bounds, as Rive's nested artboard hears it).
//
// Memory: the hits are a pool made once (LISTENER_MAX_HITS); a pick
// allocates nothing once each mesh's BVH and each skinned item's posed
// copy exist (both made on the first pick that needs them). A mesh the
// picker has not seen (a LOD level shown for the first time, a scene a
// script instanced with meshes of its own) is built during the pointer
// event that first meets it, a one-off: the surface-area split costs
// about 29 ms for a 4,224-triangle sphere (tests/listen/budget_test.as
// measures it), where a warm pick of the listeners sample costs 9 us.
// What the picker keeps is by mesh (and by palette, by skinned node) and
// bounded: an entry no plan has drawn for LISTENER_KEEP_PLANS plans in a
// row is dropped (a level of detail that comes back within that is found
// again, not built again), so a scene whose meshes come and go does not
// keep every mesh it ever drew. A MultiMesh's instances are read straight
// from its bytes, with no view to make.
//
// Milestone 67b (docs/engine/RESOURCES.md, "CPU copies"): a run time lets
// go of a mesh's arrays once its buffers exist; the mesh keeps its visible
// triangles for the picker first (render/mesh.as GpuMesh.triangles, the
// same corners, positions and texture coordinates the arrays hold), and a
// mesh picked after its release is picked from them: the same BVH, the
// same hits. A deforming mesh (a skin, blend shapes) keeps its arrays.

import { Vec2, Vec3 } from "../../base/vecmath";
import { Camera } from "../../render/camera";
import { CAST_SHADOW_SHADOWS_ONLY, DrawItem, RenderFrame, SKIN_FLOATS_PER_JOINT } from "../../render/frame";
import { GpuMesh, MeshTriangles } from "../../render/mesh";
import { RayHit, TriBvh } from "../../render/raycast";
import { F_HIDDEN } from "../../render/gpu/layouts";
import { INSTANCE_STRIDE } from "../../render/instances";
import { isTopItem } from "../../render/top_pass";
import { inVisibilityRange } from "../../render/cull";
import { Ray, pixelRayInto } from "../../render/ray";
import { SCENE_TO_MODEL, modelToScene } from "../space";
import { ValueKind } from "../value";
import { ArtboardSprite3D, CollisionObject3D, MeshInstance3D, SceneNode } from "../tree/node";
import { SkinState } from "../render/skinning";
import { SceneFrame } from "../render/adapter";
import { InteractionWorld, WorldRayHit } from "../interaction/world";
import { ArtboardTexture, StandardMaterial3D, Texture2D } from "../resource/types";
import { noteCpuMiss } from "../resource/cpu_copy";
import { INPUT_RAY_PICKABLE_PROPERTY, LISTENER_PASS_THROUGH_PROPERTY, POINTER_FORWARD_PROPERTY } from "../sm/decl";
import {
    adX, adY, adZ, affine, affineOf, anX, anY, anZ, apX, apY, apZ, globalAffine, invertAffine, mulAffine, renderOfScene,
} from "./affine";

// The most hits a pick keeps (nearest first; farther ones are dropped).
export const LISTENER_MAX_HITS: i32 = 32;

// How many plans in a row may leave a kept mesh (or palette, or skinned
// node) undrawn before the picker drops it (see the header): about ten
// seconds of a host planning every frame.
export const LISTENER_KEEP_PLANS: i32 = 600;

// How far a collision object is looked for along the pointer's ray
// (metres): the interaction world casts segments.
const SHAPE_REACH: f64 = 100000;

// One hit (see the header). Filled again by each pick.
export class ListenerHit {
    node: SceneNode? = null;
    // Along the pointer's ray, from its origin at the camera's near plane
    // (the ray is the picture's: rotations keep distances, so render and
    // scene space agree).
    t: f64 = Infinity;
    point: Vec3 = Vec3(0, 0, 0);
    normal: Vec3 = Vec3(0, 0, 0);
    u: f32 = 0;
    v: f32 = 0;
    hasUv: bool = false;
    opaque: bool = true;
    // The frame item hit (an index into SceneFrame.frame.items), -1 for a
    // collision object.
    item: i32 = -1;
    // The artboard the surface shows, pointer_forward on (null: none), and
    // the hit in its coordinates.
    artboard: ArtboardTexture? = null;
    artboardX: f32 = 0;
    artboardY: f32 = 0;
    // The change of artboardX and artboardY per metre along the hit
    // triangle's plane (scene space; see the header).
    artboardGradX: Vec3 = Vec3(0, 0, 0);
    artboardGradY: Vec3 = Vec3(0, 0, 0);
    // An item drawn without the depth test (in front of every other).
    top: bool = false;

    clear(): void {
        this.node = null;
        this.t = Infinity;
        this.point = Vec3(0, 0, 0);
        this.normal = Vec3(0, 0, 0);
        this.u = 0;
        this.v = 0;
        this.hasUv = false;
        this.opaque = true;
        this.item = -1;
        this.artboard = null;
        this.artboardX = 0;
        this.artboardY = 0;
        this.artboardGradX = Vec3(0, 0, 0);
        this.artboardGradY = Vec3(0, 0, 0);
        this.top = false;
    }
}

// A pick's answer: the hits nearest first (`count` of `hits`), and the
// pointer and its ray (scene space) they were found along.
export class ListenerHits {
    hits: Array<ListenerHit> = [];
    count: i32 = 0;
    // A ray was cast (false: no picture was planned yet, or the pointer is
    // outside it): then nothing is hit, and an exit is due.
    valid: bool = false;
    // The pointer in the picture's pixels, from its top-left corner.
    screenX: f32 = 0;
    screenY: f32 = 0;
    rayOrigin: Vec3 = Vec3(0, 0, 0);
    rayDir: Vec3 = Vec3(0, 0, 1);
    // The camera's view direction (scene space, unit): the normal of the
    // plane a ListenerAlignTarget without `surface` moves its node along.
    viewDir: Vec3 = Vec3(0, 0, -1);

    constructor() {
        for (let i = 0; i < LISTENER_MAX_HITS; i++) this.hits.push(new ListenerHit());
    }

    clear(): void {
        this.count = 0;
        this.valid = false;
    }

    // The index of the nearest hit on `group` or on a node under it, or -1.
    // Allocates nothing.
    hitUnder(group: SceneNode): i32 {
        for (let i = 0; i < this.count; i++) {
            let n = unchecked(this.hits[i]).node;
            while (n != null) {
                if (n === group) return i;
                n = n.parent;
            }
        }
        return -1;
    }
}

// A boolean property of `node` (`fallback` when unset or no boolean).
function boolProp(node: SceneNode, name: string, fallback: bool): bool {
    const v = node.getProp(name);
    return v != null && v.kind == ValueKind.Bool ? v.b : fallback;
}

// Whether a hit on `node` stops the pointer (no listener_pass_through on
// it or above it).
function opaqueAt(node: SceneNode): bool {
    let n: SceneNode? = node;
    while (n != null) {
        if (boolProp(n, LISTENER_PASS_THROUGH_PROPERTY, false)) return false;
        n = n.parent;
    }
    return true;
}

// x - floor(x): a texture coordinate wrapped into 0..1 (repeat).
function wrap01(x: f64): f64 {
    const f = x - Math.floor(x);
    return f >= 0 && f < 1 ? f : 0;
}

// A mesh as the picker hits it: its visible faces' BVH (in the mesh's
// space), the first index of each face (`corners`, by the BVH's input
// triangle), and the positions the tree was last fitted to (`posed`, the
// faces' corners in input order: what a refit rewrites).
class MeshPick {
    mesh: GpuMesh;
    // The plan that last drew it (ListenerPicker.plans), and its place in
    // the picker's list.
    seen: i32 = 0;
    slot: i32 = -1;
    bvh: TriBvh;
    corners: Int32Array;
    triCount: i32;
    indexCount: i32;
    revision: u32;
    posed: Float32Array;
    // Milestone 67b: the triangles the mesh kept when its arrays were
    // released (GpuMesh.triangles), which `posed` and `corners` are, and
    // which a hit reads its corners and texture coordinates from; null for
    // a mesh with its arrays (read from them, as before).
    kept: MeshTriangles? = null;

    constructor(mesh: GpuMesh) {
        this.mesh = mesh;
        if (mesh.cpuReleased) {
            let t = mesh.triangles;
            if (t == null) {
                // (released without them: nothing to hit there, said once
                // per mesh and picker)
                noteCpuMiss("pick: a mesh released without its triangles");
                const none = new MeshTriangles();
                none.indexCount = mesh.indexLength();
                t = none;
            }
            const kept = t as MeshTriangles;
            this.kept = kept;
            const n = kept.count;
            const pos = new Array<f32>(n * 9);
            const posed = new Float32Array(n * 9);
            const tris = kept.tris;
            const at = kept.positions;
            for (let k = 0; k < n * 3; k++) {
                const v = <i32>tris[k];
                for (let j = 0; j < 3; j++) {
                    const x = at[v * 3 + j];
                    pos[k * 3 + j] = x;
                    posed[k * 3 + j] = x;
                }
            }
            this.corners = kept.corners;
            this.triCount = n;
            this.indexCount = kept.indexCount;
            this.revision = mesh.vertsRevision;
            this.bvh = TriBvh.fromTrianglesSah(pos);
            // (a released mesh never deforms: never refitted)
            this.posed = posed;
            return;
        }
        const verts = mesh.verts;
        const idx = mesh.indices;
        let n = 0;
        for (let i = 0; i + 2 < idx.length; i += 3) if ((verts[<i32>idx[i]].flags & F_HIDDEN) == 0) n++;
        const corners = new Int32Array(n);
        const pos = new Array<f32>(n * 9);
        let k = 0;
        for (let i = 0; i + 2 < idx.length; i += 3) {
            if ((verts[<i32>idx[i]].flags & F_HIDDEN) != 0) continue;
            corners[k] = i;
            for (let c = 0; c < 3; c++) {
                const p = verts[<i32>idx[i + c]].pos;
                pos[k * 9 + c * 3] = p.x;
                pos[k * 9 + c * 3 + 1] = p.y;
                pos[k * 9 + c * 3 + 2] = p.z;
            }
            k++;
        }
        this.corners = corners;
        this.triCount = n;
        this.indexCount = idx.length;
        this.revision = mesh.vertsRevision;
        this.bvh = TriBvh.fromTrianglesSah(pos);
        const posed = new Float32Array(n * 9);
        for (let i = 0; i < n * 9; i++) posed[i] = pos[i];
        this.posed = posed;
    }

    // Milestone 67b: the mesh's arrays were released after this pick was
    // made from them: a hit reads the triangles the mesh kept (the same
    // corners, in the same order, so the tree stands), or, released
    // without them, its own positions and no texture coordinates (a miss).
    adopt(mesh: GpuMesh): void {
        const t = mesh.triangles;
        if (t != null && t.count == this.triCount) {
            this.kept = t;
            return;
        }
        noteCpuMiss("pick: a mesh released without its triangles");
        // (each triangle's corners its own vertices, at the posed
        // positions, with no texture coordinates)
        const k = new MeshTriangles();
        const n = this.triCount;
        k.count = n;
        k.indexCount = this.indexCount;
        k.corners = this.corners;
        const tris = new Uint32Array(n * 3);
        for (let i = 0; i < n * 3; i++) tris[i] = <u32>i;
        k.tris = tris;
        k.positions = this.posed;
        k.uvs = new Float32Array(n * 6);
        this.kept = k;
    }

    // The mesh's vertices were rewritten in place (a blended copy): the
    // tree follows them. Allocates nothing.
    follow(): void {
        const mesh = this.mesh;
        if (mesh.vertsRevision == this.revision || this.kept != null) return;
        this.revision = mesh.vertsRevision;
        const verts = mesh.verts;
        const idx = mesh.indices;
        const posed = this.posed;
        for (let t = 0; t < this.triCount; t++) {
            const first = unchecked(this.corners[t]);
            for (let c = 0; c < 3; c++) {
                const p = unchecked(verts[<i32>unchecked(idx[first + c])]).pos;
                const o = t * 9 + c * 3;
                unchecked(posed[o] = p.x);
                unchecked(posed[o + 1] = p.y);
                unchecked(posed[o + 2] = p.z);
            }
        }
        this.bvh.refit(posed);
    }
}

// A skinned item's posed triangles (see the header): kept per mesh and
// palette, its own BVH refitted to each new pose.
class SkinPick {
    base: MeshPick;
    seen: i32 = 0;
    slot: i32 = -1;
    // The next copy posed by the same palette (one palette can pose more
    // than one mesh: a skinned mesh's blend-shaped copy and its base
    // alternate as its weights go through 0).
    next: SkinPick? = null;
    skin: Float32Array;
    joints: i32;
    version: u32 = 0;
    revision: u32 = 0;
    fitted: bool = false;
    bvh: TriBvh;
    // Each vertex posed (3 numbers), and the faces' corners in input order.
    vertices: Float32Array;
    posed: Float32Array;

    constructor(base: MeshPick, skin: Float32Array, joints: i32) {
        this.base = base;
        this.skin = skin;
        this.joints = joints;
        const n = base.triCount;
        const pos = new Array<f32>(n * 9);
        for (let i = 0; i < n * 9; i++) pos[i] = base.posed[i];
        this.bvh = TriBvh.fromTrianglesSah(pos);
        this.vertices = new Float32Array(base.mesh.verts.length * 3);
        this.posed = new Float32Array(n * 9);
    }

    // Poses the mesh by the palette as the shader does (positions only)
    // when the palette or the mesh moved since. Allocates nothing.
    pose(version: u32): void {
        const mesh = this.base.mesh;
        if (this.fitted && version == this.version && mesh.vertsRevision == this.revision) return;
        this.fitted = true;
        this.version = version;
        this.revision = mesh.vertsRevision;
        const vs = mesh.verts;
        const js = mesh.skinJoints;
        const ws = mesh.skinWeights;
        const skin = this.skin;
        const count = this.joints;
        const out = this.vertices;
        const nv = min<i32>(vs.length, out.length / 3);
        for (let i = 0; i < nv; i++) {
            const p = unchecked(vs[i]).pos;
            let x: f32 = 0, y: f32 = 0, z: f32 = 0;
            const joints: u32 = js != null && i < js.length ? unchecked(js[i]) : 0;
            for (let s = 0; s < 4; s++) {
                const wi = i * 4 + s;
                const w: f32 = ws != null && wi < ws.length ? unchecked(ws[wi]) : 0;
                if (w == 0) continue;
                const j = <i32>((joints >> (<u32>s * 8)) & 0xff);
                if (j >= count) continue;
                const o = j * SKIN_FLOATS_PER_JOINT;
                if (o + 11 >= skin.length) continue;
                x += w * (unchecked(skin[o]) * p.x + unchecked(skin[o + 1]) * p.y + unchecked(skin[o + 2]) * p.z
                    + unchecked(skin[o + 3]));
                y += w * (unchecked(skin[o + 4]) * p.x + unchecked(skin[o + 5]) * p.y + unchecked(skin[o + 6]) * p.z
                    + unchecked(skin[o + 7]));
                z += w * (unchecked(skin[o + 8]) * p.x + unchecked(skin[o + 9]) * p.y + unchecked(skin[o + 10]) * p.z
                    + unchecked(skin[o + 11]));
            }
            unchecked(out[i * 3] = x);
            unchecked(out[i * 3 + 1] = y);
            unchecked(out[i * 3 + 2] = z);
        }
        const base = this.base;
        const idx = mesh.indices;
        const posed = this.posed;
        for (let t = 0; t < base.triCount; t++) {
            const first = unchecked(base.corners[t]);
            for (let c = 0; c < 3; c++) {
                const v = <i32>unchecked(idx[first + c]);
                const o = t * 9 + c * 3;
                if (v < nv) {
                    unchecked(posed[o] = out[v * 3]);
                    unchecked(posed[o + 1] = out[v * 3 + 1]);
                    unchecked(posed[o + 2] = out[v * 3 + 2]);
                }
            }
        }
        this.bvh.refit(posed);
    }
}

// A skinned MeshInstance3D's palette as its pose is now (see the header),
// and whether it is the palette the plan drew it with: the plan's array,
// version and joints it was compared with, and the answer.
class LiveSkin {
    state: SkinState = new SkinState();
    seen: i32 = 0;
    slot: i32 = -1;
    serial: i32;
    planSkin: Float32Array? = null;
    planVersion: u32 = 0;
    liveVersion: u32 = 0;
    joints: i32 = 0;
    same: bool = false;

    constructor(serial: i32) {
        this.serial = serial;
    }

    // Whether the palette now (its `joints`) is the plan's `skin` (its
    // version `version`): compared again only when either moved.
    matches(skin: Float32Array, version: u32, joints: i32): bool {
        const st = this.state;
        if (this.planSkin === skin && this.planVersion == version && this.liveVersion == st.version && this.joints == joints) {
            return this.same;
        }
        this.planSkin = skin;
        this.planVersion = version;
        this.liveVersion = st.version;
        this.joints = joints;
        let same = true;
        const n = joints * SKIN_FLOATS_PER_JOINT;
        const live = st.palette;
        if (n > skin.length || n > live.length) {
            same = false;
        } else {
            for (let i = 0; i < n; i++) {
                if (unchecked(live[i]) != unchecked(skin[i])) {
                    same = false;
                    break;
                }
            }
        }
        this.same = same;
        return same;
    }
}

// Casts the pointer's ray (see the header). One per runner (the run time's,
// the tools', the editor's): it keeps the meshes' BVHs, the posed copies
// of skinned items and its scratch from one pick to the next.
export class ListenerPicker {
    // What is kept (see the header): each by its key and in a list (its
    // `slot`), for the sweep.
    private meshes: Map<GpuMesh, MeshPick> = new Map<GpuMesh, MeshPick>();
    private meshList: Array<MeshPick> = [];
    private skins: Map<Float32Array, SkinPick> = new Map<Float32Array, SkinPick>();
    private skinList: Array<SkinPick> = [];
    private lives: Map<i32, LiveSkin> = new Map<i32, LiveSkin>();
    private liveList: Array<LiveSkin> = [];
    // The plans counted (one more each new SceneFrame a pick is given) and
    // the last one.
    private plans: i32 = 0;
    private planSeen: SceneFrame? = null;
    private ray: Ray = new Ray(Vec3(0, 0, 0), Vec3(0, 0, 1));
    private rayHit: RayHit = new RayHit();
    private worldHit: WorldRayHit = new WorldRayHit();
    // Scratch transforms (render space unless named): the item's world
    // now, an inverse, the plan's node global and its inverse, the node's
    // global now, the motion since the plan (scene, render), an instance's
    // transform and its placement, and the placement of the best hit.
    private world: StaticArray<f64> = affine();
    private inv: StaticArray<f64> = affine();
    private planned: StaticArray<f64> = affine();
    private planInv: StaticArray<f64> = affine();
    private now: StaticArray<f64> = affine();
    private sceneDelta: StaticArray<f64> = affine();
    private renderDelta: StaticArray<f64> = affine();
    private inst: StaticArray<f64> = affine();
    private placed: StaticArray<f64> = affine();
    private bestPlaced: StaticArray<f64> = affine();
    // The ray in render space.
    private ox: f64 = 0;
    private oy: f64 = 0;
    private oz: f64 = 0;
    private dx: f64 = 0;
    private dy: f64 = 0;
    private dz: f64 = 0;
    // The best hit of the item under test.
    private bestT: f64 = Infinity;
    private bestTri: i32 = -1;
    private bestU: f64 = 0;
    private bestV: f64 = 0;
    private bestMesh: MeshPick? = null;
    private bestSkin: SkinPick? = null;

    // How many meshes are kept (tests see the sweep drop one).
    get keptMeshes(): i32 {
        return this.meshList.length;
    }

    // How many skinned copies are kept.
    get keptSkins(): i32 {
        return this.skinList.length;
    }

    // Fills `out` with what the point (x, y) of the picture `sf` (its
    // pixels) hits: the drawn items, and the collision objects of `world`
    // that are in `groups` or under one of them; false (out.valid false,
    // no hits) when there is no picture or the point is outside it. The ray
    // is `camera`'s (the picture's own when null: a run time following a
    // camera that moved since the plan passes the camera now). Allocates
    // nothing once warm (see the header).
    pick(sf: SceneFrame?, x: f32, y: f32, world: InteractionWorld?, groups: Array<SceneNode>,
        out: ListenerHits, camera: Camera? = null): bool {
        out.clear();
        out.screenX = x;
        out.screenY = y;
        if (sf == null) return false;
        const frame = sf.frame;
        if (!(x >= 0 && y >= 0 && x < <f32>frame.width && y < <f32>frame.height)) return false;
        const cam = camera != null ? camera : frame.camera;
        const ray = this.ray;
        pixelRayInto(cam, frame.width, frame.height, x, y, ray);
        this.ox = <f64>ray.origin.x;
        this.oy = <f64>ray.origin.y;
        this.oz = <f64>ray.origin.z;
        this.dx = <f64>ray.dir.x;
        this.dy = <f64>ray.dir.y;
        this.dz = <f64>ray.dir.z;
        out.valid = true;
        out.rayOrigin = modelToScene(ray.origin);
        out.rayDir = modelToScene(ray.dir);
        out.viewDir = modelToScene(cam.forward());
        this.notePlan(sf);
        const items = frame.items;
        for (let i = 0; i < items.length; i++) this.pickItem(sf, frame, i, unchecked(items[i]), out);
        if (world != null && groups.length > 0) this.pickShapes(world, groups, out);
        // (the first opaque hit hides the rest)
        for (let i = 0; i < out.count; i++) {
            if (unchecked(out.hits[i]).opaque) {
                out.count = i + 1;
                break;
            }
        }
        return true;
    }

    // --- items ---------------------------------------------------------

    private pickItem(sf: SceneFrame, frame: RenderFrame, i: i32, item: DrawItem, out: ListenerHits): void {
        const mesh = item.mesh;
        // (milestone 34: another world's item is not in the picture)
        if (mesh == null || item.castShadow == CAST_SHADOW_SHADOWS_ONLY || item.scenario != frame.scenario) return;
        if (i >= sf.itemNodes.length) return;
        const node = unchecked(sf.itemNodes[i]);
        if (!shownIn(sf.root, node)) return;
        if (!boolProp(node, INPUT_RAY_PICKABLE_PROPERTY, true)) return;
        if (!this.inRange(frame, i, item)) return;
        const inst = item.instances;
        // (the wire shading draws no instanced item: what is not drawn is
        // not hit, as pickItem's rule; milestone 35: a CPUParticles3D's
        // particles, the only dynamic instances, are never hit, as Godot's
        // physics picking never hits them)
        if (inst != null && (!frame.drawSurfaces || inst.count == 0 || inst.dynamic)) return;
        const skin = item.skin;
        const skinned = skin != null && item.skinJointCount > 0 && mesh.skinJoints != null && mesh.skinWeights != null
            && inst == null;
        // A skinned MeshInstance3D: its palette now (null: the plan's).
        let live: LiveSkin? = null;
        if (skinned && node instanceof MeshInstance3D) {
            const l = this.liveOf(node);
            if (l.state.update(node as MeshInstance3D, SCENE_TO_MODEL) > 0) live = l;
        }
        if (live != null) {
            // (placed by its palette alone: tested by its box only while
            // that is the plan's)
            affineOf(item.world, this.world);
            if (item.hasBounds && live.matches(skin as Float32Array, item.skinVersion, live.state.count)
                && !this.rayMeetsBounds(item)) return;
        } else {
            // Where it is now: the plan's world, moved by its node's motion.
            const moved = this.placeItem(sf, i, item, node);
            if (!moved && item.hasBounds && !this.rayMeetsBounds(item)) return;
        }
        let mp = this.meshes.has(mesh) ? this.meshes.get(mesh) : null;
        if (mp == null || mp.indexCount != mesh.indexLength()) {
            // (made the first time; again when the faces themselves changed)
            const fresh = new MeshPick(mesh);
            if (mp != null) {
                fresh.slot = mp.slot;
                unchecked(this.meshList[mp.slot] = fresh);
            } else {
                fresh.slot = this.meshList.length;
                this.meshList.push(fresh);
            }
            this.meshes.set(mesh, fresh);
            mp = fresh;
        } else {
            // (milestone 67b: made before the mesh's arrays were released)
            if (mp.kept == null && mesh.cpuReleased) mp.adopt(mesh);
            mp.follow();
        }
        mp.seen = this.plans;
        this.bestT = Infinity;
        this.bestTri = -1;
        this.bestMesh = mp;
        this.bestSkin = null;
        if (skinned) {
            const sp = live != null ? this.skinOf(mp, live.state.palette, live.state.count)
                : this.skinOf(mp, skin as Float32Array, item.skinJointCount);
            sp.pose(live != null ? live.state.version : item.skinVersion);
            this.bestSkin = sp;
            this.castBvh(sp.bvh, this.world);
        } else if (inst == null) {
            this.castBvh(mp.bvh, this.world);
        } else {
            const bytes = inst.bytes;
            const count = min<i32>(<i32>inst.count, bytes.byteLength / <i32>INSTANCE_STRIDE);
            for (let k = 0; k < count; k++) {
                instanceAffine(bytes, k, this.inst);
                mulAffine(this.world, this.inst, this.placed);
                this.castBvh(mp.bvh, this.placed);
            }
        }
        if (this.bestTri < 0) return;
        this.addMeshHit(sf, i, item, node, isTopItem(item), out);
    }

    // Sets `world` to item i's world now (render space); whether its node
    // moved since the plan.
    private placeItem(sf: SceneFrame, i: i32, item: DrawItem, node: SceneNode): bool {
        affineOf(item.world, this.world);
        const g = sf.itemGlobals;
        if ((i + 1) * 12 > g.length) return false;
        const now = this.now;
        globalAffine(node, now);
        let same = true;
        for (let k = 0; k < 12; k++) {
            if (unchecked(g[i * 12 + k]) != unchecked(now[k])) {
                same = false;
                break;
            }
        }
        if (same) return false;
        // delta = now * plan^-1 (scene space), carried into render space
        // and applied after the planned world
        const planned = this.planned;
        for (let k = 0; k < 12; k++) unchecked(planned[k] = g[i * 12 + k]);
        if (!invertAffine(planned, this.planInv)) return false;
        mulAffine(now, this.planInv, this.sceneDelta);
        renderOfScene(this.sceneDelta, this.renderDelta);
        // (`planned` is free again: the world as planned goes there)
        for (let k = 0; k < 12; k++) unchecked(planned[k] = this.world[k]);
        mulAffine(this.renderDelta, planned, this.world);
        return true;
    }

    // Item i's visibility range, as its last picture had it (pick.as's rule).
    private inRange(frame: RenderFrame, i: i32, d: DrawItem): bool {
        if (!(d.rangeBegin > 0) && !(d.rangeEnd > 0)) return true;
        if (i < frame.rangeState.length) return frame.rangeState[i];
        return inVisibilityRange(d, frame.camera.eye, false);
    }

    // Whether the ray meets the item's box (render space, as planned).
    private rayMeetsBounds(item: DrawItem): bool {
        const b = item.bounds;
        let t0: f64 = 0;
        let t1: f64 = Infinity;
        for (let k = 0; k < 3; k++) {
            const o: f64 = k == 0 ? this.ox : k == 1 ? this.oy : this.oz;
            const d: f64 = k == 0 ? this.dx : k == 1 ? this.dy : this.dz;
            const lo: f64 = k == 0 ? <f64>b.min.x : k == 1 ? <f64>b.min.y : <f64>b.min.z;
            const hi: f64 = k == 0 ? <f64>b.max.x : k == 1 ? <f64>b.max.y : <f64>b.max.z;
            const inv = 1.0 / d;
            let s = (lo - o) * inv;
            let e = (hi - o) * inv;
            if (s > e) {
                const q = s;
                s = e;
                e = q;
            }
            if (s > t0) t0 = s;
            if (e < t1) t1 = e;
        }
        return !(t0 > t1);
    }

    // The ray carried into the space `placed` puts the BVH in (affine maps
    // keep the ray's parameter), cast: a hit nearer than the item's best is
    // kept, with its placement.
    private castBvh(bvh: TriBvh, placed: StaticArray<f64>): void {
        const inv = this.inv;
        if (!invertAffine(placed, inv)) return;
        const ox = this.ox, oy = this.oy, oz = this.oz;
        const dx = this.dx, dy = this.dy, dz = this.dz;
        const h = this.rayHit;
        if (!bvh.nearestHit(apX(inv, ox, oy, oz), apY(inv, ox, oy, oz), apZ(inv, ox, oy, oz), adX(inv, dx, dy, dz),
            adY(inv, dx, dy, dz), adZ(inv, dx, dy, dz), 0, this.bestT, h)) return;
        this.bestT = h.t;
        this.bestTri = h.tri;
        this.bestU = h.u;
        this.bestV = h.v;
        const bp = this.bestPlaced;
        for (let k = 0; k < 12; k++) unchecked(bp[k] = placed[k]);
    }

    // The item's best hit into `out` (see the header for what it says).
    private addMeshHit(sf: SceneFrame, i: i32, item: DrawItem, node: SceneNode, top: bool, out: ListenerHits): void {
        const mp = this.bestMesh as MeshPick;
        const mesh = mp.mesh;
        const tri = this.bestTri;
        const t = this.bestT;
        const h = this.place(out, node, t, top);
        if (h == null) return;
        h.item = i;
        h.opaque = opaqueAt(node);
        // The point (render space, along the ray by its own parameter).
        h.point = modelToScene(Vec3(<f32>(this.ox + this.dx * t), <f32>(this.oy + this.dy * t), <f32>(this.oz + this.dz * t)));
        // The triangle's corners, in the space it was hit in, for its normal.
        const first = unchecked(mp.corners[tri]);
        // (milestone 67b: a released mesh's from the triangles it kept, the
        // same numbers)
        const kept = mp.kept;
        let i0 = 0, i1 = 0, i2 = 0;
        if (kept == null) {
            const idx = mesh.indices;
            i0 = <i32>unchecked(idx[first]);
            i1 = <i32>unchecked(idx[first + 1]);
            i2 = <i32>unchecked(idx[first + 2]);
        }
        const sk = this.bestSkin;
        let ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64, cx: f64, cy: f64, cz: f64;
        if (kept != null) {
            // (the triangle's corners as the tree was built from them)
            const kp = mp.posed;
            const o = tri * 9;
            ax = <f64>kp[o]; ay = <f64>kp[o + 1]; az = <f64>kp[o + 2];
            bx = <f64>kp[o + 3]; by = <f64>kp[o + 4]; bz = <f64>kp[o + 5];
            cx = <f64>kp[o + 6]; cy = <f64>kp[o + 7]; cz = <f64>kp[o + 8];
        } else if (sk != null) {
            const vp = sk.vertices;
            ax = <f64>vp[i0 * 3]; ay = <f64>vp[i0 * 3 + 1]; az = <f64>vp[i0 * 3 + 2];
            bx = <f64>vp[i1 * 3]; by = <f64>vp[i1 * 3 + 1]; bz = <f64>vp[i1 * 3 + 2];
            cx = <f64>vp[i2 * 3]; cy = <f64>vp[i2 * 3 + 1]; cz = <f64>vp[i2 * 3 + 2];
        } else {
            const vs = mesh.verts;
            const a = unchecked(vs[i0]).pos, b = unchecked(vs[i1]).pos, c = unchecked(vs[i2]).pos;
            ax = <f64>a.x; ay = <f64>a.y; az = <f64>a.z;
            bx = <f64>b.x; by = <f64>b.y; bz = <f64>b.z;
            cx = <f64>c.x; cy = <f64>c.y; cz = <f64>c.z;
        }
        const e1x = bx - ax, e1y = by - ay, e1z = bz - az;
        const e2x = cx - ax, e2y = cy - ay, e2z = cz - az;
        const lnx = e1y * e2z - e1z * e2y, lny = e1z * e2x - e1x * e2z, lnz = e1x * e2y - e1y * e2x;
        const inv = this.inv;
        invertAffine(this.bestPlaced, inv);
        let nx = anX(inv, lnx, lny, lnz), ny = anY(inv, lnx, lny, lnz), nz = anZ(inv, lnx, lny, lnz);
        const l = Math.sqrt(nx * nx + ny * ny + nz * nz);
        if (l > 0) {
            nx /= l;
            ny /= l;
            nz /= l;
        }
        // (towards the pointer)
        if (nx * this.dx + ny * this.dy + nz * this.dz > 0) {
            nx = -nx;
            ny = -ny;
            nz = -nz;
        }
        h.normal = modelToScene(Vec3(<f32>nx, <f32>ny, <f32>nz));
        // The texture coordinates: the renderer's run bottom-up, Godot's
        // (and an artboard's) top-down.
        const w0 = 1 - this.bestU - this.bestV;
        let uv0: Vec2, uv1: Vec2, uv2: Vec2;
        if (kept != null) {
            const ku = kept.uvs;
            const kt = kept.tris;
            const a = <i32>kt[tri * 3] * 2, b = <i32>kt[tri * 3 + 1] * 2, c = <i32>kt[tri * 3 + 2] * 2;
            uv0 = Vec2(ku[a], ku[a + 1]);
            uv1 = Vec2(ku[b], ku[b + 1]);
            uv2 = Vec2(ku[c], ku[c + 1]);
        } else {
            const vs = mesh.verts;
            uv0 = unchecked(vs[i0]).uv;
            uv1 = unchecked(vs[i1]).uv;
            uv2 = unchecked(vs[i2]).uv;
        }
        const u = w0 * <f64>uv0.x + this.bestU * <f64>uv1.x + this.bestV * <f64>uv2.x;
        const v = 1 - (w0 * <f64>uv0.y + this.bestU * <f64>uv1.y + this.bestV * <f64>uv2.y);
        h.u = <f32>u;
        h.v = <f32>v;
        h.hasUv = true;
        if (!boolProp(node, POINTER_FORWARD_PROPERTY, true)) return;
        // The artboard the surface shows.
        if (node instanceof ArtboardSprite3D) {
            const tex = (node as ArtboardSprite3D).texture;
            if (tex == null) return;
            artboardAt(h, tex, u, v, 1, 1, 0, 0);
            this.artboardGradients(h, tex, ax, ay, az, bx, by, bz, cx, cy, cz, uv0, uv1, uv2, 1, 1);
            return;
        }
        const range = rangeOf(mesh, first);
        if (range < 0 || range >= item.materials.length) return;
        const key = <i32>unchecked(item.materials[range]);
        const mats = sf.materialResources;
        if (key < 0 || key >= mats.length) return;
        const m: StandardMaterial3D = unchecked(mats[key]);
        let tex: Texture2D? = m.albedoTexture;
        if (!(tex instanceof ArtboardTexture)) tex = m.emissionTexture;
        if (!(tex instanceof ArtboardTexture)) return;
        const s = m.uv1Scale;
        const o = m.uv1Offset;
        artboardAt(h, tex as ArtboardTexture, u, v, <f64>s.x, <f64>s.y, <f64>o.x, <f64>o.y);
        this.artboardGradients(h, tex as ArtboardTexture, ax, ay, az, bx, by, bz, cx, cy, cz, uv0, uv1, uv2, <f64>s.x,
            <f64>s.y);
    }

    // The hit's artboardGradX and artboardGradY: the triangle (a, b, c in
    // the space it was hit in, placed by the best hit's placement) carried
    // into scene space, the gradients of its barycentric weights along its
    // plane (the dual basis of its edges) times its corners' texture
    // coordinates, times the texture's scale and size.
    private artboardGradients(h: ListenerHit, tex: ArtboardTexture, ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64,
        cx: f64, cy: f64, cz: f64, uv0: Vec2, uv1: Vec2, uv2: Vec2, sx: f64, sy: f64): void {
        const bp = this.bestPlaced;
        const a = modelToScene(Vec3(<f32>apX(bp, ax, ay, az), <f32>apY(bp, ax, ay, az), <f32>apZ(bp, ax, ay, az)));
        const b = modelToScene(Vec3(<f32>apX(bp, bx, by, bz), <f32>apY(bp, bx, by, bz), <f32>apZ(bp, bx, by, bz)));
        const c = modelToScene(Vec3(<f32>apX(bp, cx, cy, cz), <f32>apY(bp, cx, cy, cz), <f32>apZ(bp, cx, cy, cz)));
        const e1x = <f64>b.x - <f64>a.x, e1y = <f64>b.y - <f64>a.y, e1z = <f64>b.z - <f64>a.z;
        const e2x = <f64>c.x - <f64>a.x, e2y = <f64>c.y - <f64>a.y, e2z = <f64>c.z - <f64>a.z;
        const nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x;
        const nn = nx * nx + ny * ny + nz * nz;
        if (!(nn > 0)) return;
        // (gb = (e2 x n) / |n|^2, gc = (n x e1) / |n|^2)
        const gbx = (e2y * nz - e2z * ny) / nn, gby = (e2z * nx - e2x * nz) / nn, gbz = (e2x * ny - e2y * nx) / nn;
        const gcx = (ny * e1z - nz * e1y) / nn, gcy = (nz * e1x - nx * e1z) / nn, gcz = (nx * e1y - ny * e1x) / nn;
        const du1 = <f64>uv1.x - <f64>uv0.x, du2 = <f64>uv2.x - <f64>uv0.x;
        // (v runs top-down: 1 minus the renderer's)
        const dv1 = <f64>uv0.y - <f64>uv1.y, dv2 = <f64>uv0.y - <f64>uv2.y;
        const kx = sx * <f64>tex.width;
        const ky = sy * <f64>tex.height;
        h.artboardGradX = Vec3(<f32>((du1 * gbx + du2 * gcx) * kx), <f32>((du1 * gby + du2 * gcy) * kx),
            <f32>((du1 * gbz + du2 * gcz) * kx));
        h.artboardGradY = Vec3(<f32>((dv1 * gbx + dv2 * gcx) * ky), <f32>((dv1 * gby + dv2 * gcy) * ky),
            <f32>((dv1 * gbz + dv2 * gcz) * ky));
    }

    // The skinned copy of `mp` posed by `skin` (made the first time). The
    // copies are kept by palette, each palette's in a chain, so that a
    // palette posing two meshes in turn keeps both.
    private skinOf(mp: MeshPick, skin: Float32Array, joints: i32): SkinPick {
        const head = this.skins.has(skin) ? this.skins.get(skin) : null;
        let at = head;
        while (at != null) {
            if (at.base === mp && at.joints == joints) {
                at.seen = this.plans;
                return at;
            }
            at = at.next;
        }
        const s = new SkinPick(mp, skin, joints);
        s.seen = this.plans;
        s.next = head;
        s.slot = this.skinList.length;
        this.skinList.push(s);
        this.skins.set(skin, s);
        return s;
    }

    // Marks every copy `skin` poses as drawn in plan `now`.
    private markSkins(skin: Float32Array, now: i32): void {
        if (!this.skins.has(skin)) return;
        let at: SkinPick? = this.skins.get(skin);
        while (at != null) {
            at.seen = now;
            at = at.next;
        }
    }

    // Takes `k` out of its palette's chain.
    private unlinkSkin(k: SkinPick): void {
        const head = this.skins.get(k.skin);
        if (head === k) {
            const next = k.next;
            if (next != null) this.skins.set(k.skin, next);
            else this.skins.delete(k.skin);
            return;
        }
        let at: SkinPick? = head;
        while (at != null) {
            if (at.next === k) {
                at.next = k.next;
                return;
            }
            at = at.next;
        }
    }

    // The palette now of the skinned MeshInstance3D `node` (made the first
    // time).
    private liveOf(node: SceneNode): LiveSkin {
        const key = node.serial;
        if (this.lives.has(key)) {
            const l = this.lives.get(key);
            l.seen = this.plans;
            return l;
        }
        const l = new LiveSkin(key);
        l.seen = this.plans;
        l.slot = this.liveList.length;
        this.liveList.push(l);
        this.lives.set(key, l);
        return l;
    }

    // A pick in a plan not seen before counts it, marks what it draws as
    // drawn, and drops what no plan has drawn for LISTENER_KEEP_PLANS plans
    // (see the header). Allocates nothing.
    private notePlan(sf: SceneFrame): void {
        if (sf === this.planSeen) return;
        this.planSeen = sf;
        const now = ++this.plans;
        const items = sf.frame.items;
        const nodes = sf.itemNodes;
        for (let i = 0; i < items.length; i++) {
            const item = unchecked(items[i]);
            const mesh = item.mesh;
            if (mesh != null && this.meshes.has(mesh)) this.meshes.get(mesh).seen = now;
            const skin = item.skin;
            if (skin == null || i >= nodes.length) continue;
            this.markSkins(skin, now);
            const key = unchecked(nodes[i]).serial;
            if (!this.lives.has(key)) continue;
            const l = this.lives.get(key);
            l.seen = now;
            const palette = l.state.palette;
            this.markSkins(palette, now);
        }
        const old = now - LISTENER_KEEP_PLANS;
        const ms = this.meshList;
        for (let i = ms.length - 1; i >= 0; i--) {
            const m = unchecked(ms[i]);
            if (m.seen >= old) continue;
            this.meshes.delete(m.mesh);
            const last = ms.pop();
            if (last !== m) {
                last.slot = i;
                unchecked(ms[i] = last);
            }
        }
        const ss = this.skinList;
        for (let i = ss.length - 1; i >= 0; i--) {
            const k = unchecked(ss[i]);
            if (k.seen >= old) continue;
            this.unlinkSkin(k);
            const last = ss.pop();
            if (last !== k) {
                last.slot = i;
                unchecked(ss[i] = last);
            }
        }
        const ls = this.liveList;
        for (let i = ls.length - 1; i >= 0; i--) {
            const l = unchecked(ls[i]);
            if (l.seen >= old) continue;
            this.lives.delete(l.serial);
            const last = ls.pop();
            if (last !== l) {
                last.slot = i;
                unchecked(ls[i] = last);
            }
        }
    }

    // --- collision objects -----------------------------------------------

    private pickShapes(world: InteractionWorld, groups: Array<SceneNode>, out: ListenerHits): void {
        const from = out.rayOrigin;
        const d = out.rayDir;
        const to = Vec3(<f32>(<f64>from.x + <f64>d.x * SHAPE_REACH), <f32>(<f64>from.y + <f64>d.y * SHAPE_REACH),
            <f32>(<f64>from.z + <f64>d.z * SHAPE_REACH));
        const es = world.entries;
        const wh = this.worldHit;
        for (let i = 0; i < es.length; i++) {
            const o: CollisionObject3D = unchecked(es[i]).object;
            if (!o.inputRayPickable || !underGroup(o, groups)) continue;
            // (freed or taken out since the world's last sync)
            if (!inTree(o, world.tree.root)) continue;
            if (!world.castRayEntry(i, from, to, wh)) continue;
            const h = this.place(out, o, wh.distance, false);
            if (h == null) continue;
            h.item = -1;
            h.point = wh.position;
            let n = wh.normal;
            if (<f64>n.x * <f64>d.x + <f64>n.y * <f64>d.y + <f64>n.z * <f64>d.z > 0) n = Vec3(-n.x, -n.y, -n.z);
            h.normal = n;
            h.hasUv = false;
            h.opaque = opaqueAt(o);
        }
    }

    // --- the pool -----------------------------------------------------

    // The slot a hit on `node` at `t` goes into, in order (cleared, its
    // node, t and top set), or null when it is not kept: a hit of the node
    // that comes first stands already, or the pool is full of hits that
    // come first. A later hit of the node is taken out.
    private place(out: ListenerHits, node: SceneNode, t: f64, top: bool): ListenerHit? {
        const hits = out.hits;
        for (let i = 0; i < out.count; i++) {
            const e = unchecked(hits[i]);
            if (e.node !== node) continue;
            if (!before(top, t, e.top, e.t)) return null;
            // (taken out: the later ones move up, its slot to the end)
            for (let k = i; k < out.count - 1; k++) unchecked(hits[k] = hits[k + 1]);
            unchecked(hits[out.count - 1] = e);
            out.count--;
            break;
        }
        const n = out.count;
        const cap = hits.length;
        if (n == cap && !before(top, t, unchecked(hits[n - 1]).top, unchecked(hits[n - 1]).t)) return null;
        const at = n < cap ? n : cap - 1;
        const slot = unchecked(hits[at]);
        let i = at;
        while (i > 0 && before(top, t, unchecked(hits[i - 1]).top, unchecked(hits[i - 1]).t)) {
            unchecked(hits[i] = hits[i - 1]);
            i--;
        }
        unchecked(hits[i] = slot);
        if (n < cap) out.count = n + 1;
        slot.clear();
        slot.node = node;
        slot.t = t;
        slot.top = top;
        return slot;
    }
}

// The hit's point in the artboard texture `tex` (see the header).
function artboardAt(h: ListenerHit, tex: ArtboardTexture, u: f64, v: f64, sx: f64, sy: f64, ox: f64, oy: f64): void {
    h.artboard = tex;
    h.artboardX = <f32>(wrap01(u * sx + ox) * <f64>tex.width);
    h.artboardY = <f32>(wrap01(v * sy + oy) * <f64>tex.height);
}

// Whether a hit (top, t) comes before another: a top item's before any
// other, then the nearer.
function before(top: bool, t: f64, otherTop: bool, otherT: f64): bool {
    if (top != otherTop) return top;
    return t < otherT;
}

// Whether `n` is one of `groups` or under one.
function underGroup(n: SceneNode, groups: Array<SceneNode>): bool {
    let at: SceneNode? = n;
    while (at != null) {
        for (let i = 0; i < groups.length; i++) if (unchecked(groups[i]) === at) return true;
        at = at.parent;
    }
    return false;
}

// The index of the material range holding index `first` of `mesh`, -1
// none.
function rangeOf(mesh: GpuMesh, first: i32): i32 {
    const rs = mesh.ranges;
    for (let k = 0; k < rs.length; k++) {
        const r = unchecked(rs[k]);
        if (<u32>first >= r.first && <u32>first < r.first + r.count) return k;
    }
    return -1;
}

// Instance `k`'s transform (item space) from a MultiMesh's bytes
// (render/instances.as: three rows of four f32 each, little-endian as
// WebAssembly's memory; the caller keeps `k` within the bytes), read in
// place: no view to make.
unsafe function instanceAffine(bytes: ArrayBuffer, k: i32, out: StaticArray<f64>): void {
    const at = changetype<usize>(bytes) + <usize>(k * <i32>INSTANCE_STRIDE);
    for (let c = 0; c < 4; c++) {
        const o = <usize>(c * 4);
        unchecked(out[c * 3] = <f64>load<f32>(at + o));
        unchecked(out[c * 3 + 1] = <f64>load<f32>(at + o + 16));
        unchecked(out[c * 3 + 2] = <f64>load<f32>(at + o + 32));
    }
}

// Whether `node` is still shown as a plan rooted at `root` drew it (null:
// no root known): not freed, not hidden (it or a 3D node above it, up to
// the first that is not 3D, as SceneNode.visibleInTree), and still under
// `root`. Allocates nothing.
function shownIn(root: SceneNode?, node: SceneNode): bool {
    let n: SceneNode? = node;
    let top: SceneNode = node;
    let lit = true;
    while (n != null) {
        if (n.freed) return false;
        if (lit) {
            if (!n.is3d) lit = false;
            else if (!n.visible) return false;
        }
        top = n;
        n = n.parent;
    }
    return root == null || top === root;
}

// Whether `node` is under `root` (or is it), none of the way freed.
function inTree(node: SceneNode, root: SceneNode): bool {
    let n: SceneNode? = node;
    let top: SceneNode = node;
    while (n != null) {
        if (n.freed) return false;
        top = n;
        n = n.parent;
    }
    return top === root;
}
