// Skinned meshes as the renderer draws them (docs/plans/RIVE_MODEL.md
// section 3.7; docs/engine/ANIMATION.md, "Skeletons and imported clips").
//
// A MeshInstance3D with a skin (MeshInstance3D.skin, a model's mesh) and a
// Skeleton3D its `skeleton` path finds is drawn by the GPU (shared/src/
// hedra_engine/shaders/render/surface.wgsl's skinning block): its mesh as stored
// (the bind pose), each vertex moved by four matrices of a palette. Palette
// slot k is
//
//   toRenderer * skeleton.global() * skeleton.getBoneGlobalPose(joints[k])
//     * inverseBinds[k]
//
// (toRenderer is ../space.as SCENE_TO_MODEL: the frame is drawn Z up), which
// takes a point of the mesh as its GpuMesh stores it straight into the
// frame's world space, so the item's own world matrix is the identity. The
// palette is written as the three rows of each 3 x 4 matrix
// (render/frame.as DrawItem.skin, SKIN_FLOATS_PER_JOINT numbers a joint).
//
// `SkinState` keeps a node's palette from frame to frame and works it out
// again only when the skeleton's pose (Skeleton3D.poseVersion), its global
// transform, the skin or the frame's space changed, moving its `version`
// then, so the renderer uploads it only then (gpu/renderer.as
// `uploadSkins`): an idle skeleton costs nothing and allocates nothing.
//
// A ModelInstance3D draws a whole model as one node, with no Skeleton3D:
// its skinned parts use the palette of the model's file pose, fixed
// (`filePosePalette`; no clip or key reaches them), placed by the node.
//
// The wire shadings draw a mesh's edges with the line shader, which does
// not skin: a skinned item in them is skinned here, on the CPU (`CpuSkin`),
// into a copy drawn as it is (the same palette, the same numbers).

import { MAT4_IDENTITY, Mat4, Vec3, Vec4 } from "../../base/vecmath";
import { Bounds } from "../../render/camera";
import { skinnedBounds } from "../../render/cull";
import { SKIN_FLOATS_PER_JOINT } from "../../render/frame";
import { GpuMesh, MeshUploader } from "../../render/mesh";
import { SurfaceVertex } from "../../render/gpu/layouts";
import { MAX_SKIN_JOINTS, ModelSkin } from "../skeleton/model_skin";
import { ModelResource } from "../resource/types";
import { MeshInstance3D, Skeleton3D } from "../tree/node";
import { DeformedMesh } from "./morph";
import { noteCpuMiss } from "../resource/cpu_copy";

// The Skeleton3D `mesh` follows (its `skeleton` path), or null. Godot's
// default path, "..", is the parent, found without building a path; any
// other goes through MeshInstance3D.resolvedSkeleton.
export function skeletonOf(mesh: MeshInstance3D): Skeleton3D? {
    const path = mesh.skeletonPath;
    if (path == "..") {
        const p = mesh.parent;
        if (p == null) return null;
        const isSkeleton = p instanceof Skeleton3D;
        return isSkeleton ? p as Skeleton3D : null;
    }
    // (the node itself is a MeshInstance3D, never a skeleton)
    if (path == "" || path == ".") return null;
    return mesh.resolvedSkeleton();
}

// Whether `g` holds a skin a palette can move: a palette slot word and four
// weights for every vertex (gpu/mesh_cache.as `hasSkin`'s rule, which this
// module, which never touches the device, repeats).
export function meshHasSkin(g: GpuMesh): bool {
    const j = g.skinJoints;
    const w = g.skinWeights;
    const n = g.verts.length;
    return j != null && w != null && n > 0 && j.length == n && w.length == n * 4;
}

// Writes `m` as palette slot `k` of `out`: its three rows.
export function writeJoint(out: Float32Array, k: i32, m: Mat4): void {
    const o = k * SKIN_FLOATS_PER_JOINT;
    unchecked(out[o] = m.xAxis.x);
    unchecked(out[o + 1] = m.yAxis.x);
    unchecked(out[o + 2] = m.zAxis.x);
    unchecked(out[o + 3] = m.wAxis.x);
    unchecked(out[o + 4] = m.xAxis.y);
    unchecked(out[o + 5] = m.yAxis.y);
    unchecked(out[o + 6] = m.zAxis.y);
    unchecked(out[o + 7] = m.wAxis.y);
    unchecked(out[o + 8] = m.xAxis.z);
    unchecked(out[o + 9] = m.yAxis.z);
    unchecked(out[o + 10] = m.zAxis.z);
    unchecked(out[o + 11] = m.wAxis.z);
}

// The palette of `mesh` (see the header) written into `out`, which holds
// at least SKIN_FLOATS_PER_JOINT numbers a joint; the joints written, 0
// when it is not skinned: no skin, no skeleton, more joints than
// MAX_SKIN_JOINTS or than `out` holds. A joint that names no bone of the
// skeleton is the skeleton itself (its bone pose the identity), and a
// missing inverse bind the identity. Allocates nothing.
export function skinPalette(mesh: MeshInstance3D, toRenderer: Mat4, out: Float32Array): i32 {
    const skin = mesh.skin;
    if (skin == null) return 0;
    const skeleton = skeletonOf(mesh);
    if (skeleton == null) return 0;
    const n = skin.joints.length;
    if (n == 0 || n > MAX_SKIN_JOINTS || out.length < n * SKIN_FLOATS_PER_JOINT) return 0;
    const base = toRenderer * skeleton.global();
    const bones = skeleton.bones.length;
    const binds = skin.inverseBinds;
    for (let k = 0; k < n; k++) {
        const j = unchecked(skin.joints[k]);
        const pose = j >= 0 && j < bones ? skeleton.getBoneGlobalPose(j) : MAT4_IDENTITY;
        const ib = k < binds.length ? unchecked(binds[k]) : MAT4_IDENTITY;
        writeJointProduct(out, k, base, pose, ib);
    }
    return n;
}

// Writes the three rows of `a * b * c` as palette slot `k` of `out`: the
// same numbers as writeJoint(out, k, a * b * c), worked out on scalars.
// The palette is rebuilt for every skinned mesh whenever its skeleton
// moves, and the Mat4 operators (struct values through the VM) made it
// about nine times slower: 0.24 ms against 0.027 ms for 60 joints, a
// quarter of a 60-bone frame's budget (tests/skeleton/budget_test.as).
// Only the first three rows of a * b are needed, each against every row
// of c (its last row included, so the product is exact for any matrix).
function writeJointProduct(out: Float32Array, k: i32, a: Mat4, b: Mat4, c: Mat4): void {
    const a0 = a.xAxis, a1 = a.yAxis, a2 = a.zAxis, a3 = a.wAxis;
    const b0 = b.xAxis, b1 = b.yAxis, b2 = b.zAxis, b3 = b.wAxis;
    // P = a * b, rows 0..2 (pRC: row R, column C).
    const p00 = a0.x * b0.x + a1.x * b0.y + a2.x * b0.z + a3.x * b0.w;
    const p10 = a0.y * b0.x + a1.y * b0.y + a2.y * b0.z + a3.y * b0.w;
    const p20 = a0.z * b0.x + a1.z * b0.y + a2.z * b0.z + a3.z * b0.w;
    const p01 = a0.x * b1.x + a1.x * b1.y + a2.x * b1.z + a3.x * b1.w;
    const p11 = a0.y * b1.x + a1.y * b1.y + a2.y * b1.z + a3.y * b1.w;
    const p21 = a0.z * b1.x + a1.z * b1.y + a2.z * b1.z + a3.z * b1.w;
    const p02 = a0.x * b2.x + a1.x * b2.y + a2.x * b2.z + a3.x * b2.w;
    const p12 = a0.y * b2.x + a1.y * b2.y + a2.y * b2.z + a3.y * b2.w;
    const p22 = a0.z * b2.x + a1.z * b2.y + a2.z * b2.z + a3.z * b2.w;
    const p03 = a0.x * b3.x + a1.x * b3.y + a2.x * b3.z + a3.x * b3.w;
    const p13 = a0.y * b3.x + a1.y * b3.y + a2.y * b3.z + a3.y * b3.w;
    const p23 = a0.z * b3.x + a1.z * b3.y + a2.z * b3.z + a3.z * b3.w;
    const c0 = c.xAxis, c1 = c.yAxis, c2 = c.zAxis, c3 = c.wAxis;
    const o = k * SKIN_FLOATS_PER_JOINT;
    unchecked(out[o] = p00 * c0.x + p01 * c0.y + p02 * c0.z + p03 * c0.w);
    unchecked(out[o + 1] = p00 * c1.x + p01 * c1.y + p02 * c1.z + p03 * c1.w);
    unchecked(out[o + 2] = p00 * c2.x + p01 * c2.y + p02 * c2.z + p03 * c2.w);
    unchecked(out[o + 3] = p00 * c3.x + p01 * c3.y + p02 * c3.z + p03 * c3.w);
    unchecked(out[o + 4] = p10 * c0.x + p11 * c0.y + p12 * c0.z + p13 * c0.w);
    unchecked(out[o + 5] = p10 * c1.x + p11 * c1.y + p12 * c1.z + p13 * c1.w);
    unchecked(out[o + 6] = p10 * c2.x + p11 * c2.y + p12 * c2.z + p13 * c2.w);
    unchecked(out[o + 7] = p10 * c3.x + p11 * c3.y + p12 * c3.z + p13 * c3.w);
    unchecked(out[o + 8] = p20 * c0.x + p21 * c0.y + p22 * c0.z + p23 * c0.w);
    unchecked(out[o + 9] = p20 * c1.x + p21 * c1.y + p22 * c1.z + p23 * c1.w);
    unchecked(out[o + 10] = p20 * c2.x + p21 * c2.y + p22 * c2.z + p23 * c2.w);
    unchecked(out[o + 11] = p20 * c3.x + p21 * c3.y + p22 * c3.z + p23 * c3.w);
}

// The palette of the file's pose of object `objectIndex` of `model` (a
// skinned mesh object), relative to the node that draws the whole model (a
// ModelInstance3D): slot k is the skeleton object's place in the model (the
// product of its chain of objects' locals) * the bone's global pose, as the
// file poses it * inverseBinds[k]. The caller puts the node's own
// placement before each (SkinState.updateFixed). Null when the object has
// no skin, its skeleton object has no bones, or it uses more than
// MAX_SKIN_JOINTS. Allocates its answer: a ModelInstance3D's model does
// not change, so the scene render cache asks once per part.
export function filePosePalette(model: ModelResource, objectIndex: i32): Array<Mat4>? {
    const objs = model.objects;
    if (objectIndex < 0 || objectIndex >= objs.length) return null;
    const skin = objs[objectIndex].skin;
    if (skin == null) return null;
    const s = skin.skeleton;
    if (s < 0 || s >= objs.length) return null;
    const skeleton = objs[s].skeleton;
    if (skeleton == null) return null;
    const n = skin.joints.length;
    if (n == 0 || n > MAX_SKIN_JOINTS) return null;
    // The skeleton object's place in the model (parents come first).
    let place = objs[s].local;
    let p = objs[s].parent;
    while (p >= 0 && p < objs.length) {
        place = objs[p].local * place;
        p = objs[p].parent;
    }
    // The bones' global poses at the file's pose (parents first).
    const bones = skeleton.bones;
    const globals = new Array<Mat4>(bones.length);
    for (let i = 0; i < bones.length; i++) {
        const b = bones[i];
        const local = b.pose.matrix();
        globals[i] = b.parent >= 0 && b.parent < i ? globals[b.parent] * local : local;
    }
    const out = new Array<Mat4>(n);
    for (let k = 0; k < n; k++) {
        const j = skin.joints[k];
        const pose = j >= 0 && j < globals.length ? globals[j] : MAT4_IDENTITY;
        const ib = k < skin.inverseBinds.length ? skin.inverseBinds[k] : MAT4_IDENTITY;
        out[k] = place * pose * ib;
    }
    return out;
}

// The most vertices SkinState.bounds skins one by one for the exact box
// (a few tenths of a millisecond a frame at most); a larger mesh takes the
// conservative box (cull.as skinnedBounds).
export const EXACT_BOUNDS_VERTICES: i32 = 2048;

// A node's palette, kept (see the header): `palette` holds `count` joints
// (0: not skinned), `version` moves whenever the numbers change.
export class SkinState {
    palette: Float32Array = new Float32Array(MAX_SKIN_JOINTS * SKIN_FLOATS_PER_JOINT);
    count: i32 = 0;
    version: u32 = 0;
    // How many times the palette was worked out (tests see an unchanged pose
    // do no work).
    recomputes: i32 = 0;
    // The scene render cache's epoch when a plan last used it.
    seen: u32 = 0;
    // What the numbers were worked out from (`known`: anything).
    private known: bool = false;
    private skeleton: Skeleton3D? = null;
    private skin: ModelSkin? = null;
    private poseVersion: u32 = 0;
    private skeletonGlobal: Mat4 = MAT4_IDENTITY;
    private toRenderer: Mat4 = MAT4_IDENTITY;
    private fixed: Array<Mat4>? = null;
    // The box `bounds` last gave, and what it was worked out for.
    private box: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    private boundsVersion: u32 = 0xFFFFFFFF;
    private boundsMesh: GpuMesh? = null;
    private boundsMeshVersion: u32 = 0;

    // The palette of `mesh` in the frame's space `toRenderer` (skinPalette),
    // worked out again only when its skeleton, skin, pose, the skeleton's
    // global transform or `toRenderer` changed; the joints (0: not skinned).
    // Allocates nothing.
    update(mesh: MeshInstance3D, toRenderer: Mat4): i32 {
        const skeleton = skeletonOf(mesh);
        const skin = mesh.skin;
        if (skeleton == null || skin == null) return this.clear();
        const g = skeleton.global();
        if (this.known && this.fixed == null && this.skeleton === skeleton && this.skin === skin
            && this.poseVersion == skeleton.poseVersion && this.skeletonGlobal == g && this.toRenderer == toRenderer) {
            return this.count;
        }
        this.count = skinPalette(mesh, toRenderer, this.palette);
        this.known = true;
        this.fixed = null;
        this.skeleton = skeleton;
        this.skin = skin;
        this.poseVersion = skeleton.poseVersion;
        this.skeletonGlobal = g;
        this.toRenderer = toRenderer;
        this.version++;
        this.recomputes++;
        return this.count;
    }

    // A fixed palette `rel` (filePosePalette's, relative to the node) placed
    // by `place` (the frame's space times the node's global transform):
    // slot k = place * rel[k], worked out again only when `rel` or `place`
    // changed. The joints.
    updateFixed(rel: Array<Mat4>, place: Mat4): i32 {
        if (this.known && this.fixed === rel && this.toRenderer == place) return this.count;
        const n = min<i32>(rel.length, MAX_SKIN_JOINTS);
        for (let k = 0; k < n; k++) writeJoint(this.palette, k, place * unchecked(rel[k]));
        this.count = n;
        this.known = true;
        this.fixed = rel;
        this.skeleton = null;
        this.skin = null;
        this.toRenderer = place;
        this.version++;
        this.recomputes++;
        return n;
    }

    // The box of `g` (the mesh drawn, skinned on the GPU by this palette;
    // `local` its own box at the bind pose, `meshVersion` moving whenever
    // its vertices were rewritten: a blended copy's weights) as the GPU
    // places it, worked out again only when the palette or the mesh
    // changed, so that the default camera frames, and culling keeps, what
    // is drawn, whatever the pose. A mesh of up to EXACT_BOUNDS_VERTICES
    // vertices is skinned vertex by vertex as the shader does (the exact
    // box); a larger one takes cull.as skinnedBounds, the bind box through
    // every joint (a box the GPU's vertices never leave, larger, but
    // worked out per joint rather than per vertex every frame a clip
    // plays). Allocates nothing.
    bounds(g: GpuMesh, local: Bounds, meshVersion: u32 = 0): Bounds {
        if (this.boundsVersion == this.version && this.boundsMesh === g && this.boundsMeshVersion == meshVersion) {
            return this.box;
        }
        this.boundsVersion = this.version;
        this.boundsMesh = g;
        this.boundsMeshVersion = meshVersion;
        const js = g.skinJoints;
        const ws = g.skinWeights;
        const vs = g.verts;
        if (js == null || ws == null || vs.length == 0) {
            this.box = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
            return this.box;
        }
        if (vs.length > EXACT_BOUNDS_VERTICES) {
            this.box = skinnedBounds(this.palette, this.count, local);
            return this.box;
        }
        const pal = this.palette;
        const count = this.count;
        let lx = f32.MAX_VALUE, ly = f32.MAX_VALUE, lz = f32.MAX_VALUE;
        let hx = -f32.MAX_VALUE, hy = -f32.MAX_VALUE, hz = -f32.MAX_VALUE;
        for (let i = 0; i < vs.length; i++) {
            const v = unchecked(vs[i]).pos;
            const joints = unchecked(js[i]);
            let p = Vec3(0, 0, 0);
            for (let s = 0; s < 4; s++) {
                const w = unchecked(ws[i * 4 + s]);
                if (w == 0) continue;
                const k = <i32>((joints >> (<u32>s * 8)) & 0xff);
                if (k >= count) continue;
                p = p + rowsPoint(pal, k, v.x, v.y, v.z, w);
            }
            if (p.x < lx) lx = p.x;
            if (p.y < ly) ly = p.y;
            if (p.z < lz) lz = p.z;
            if (p.x > hx) hx = p.x;
            if (p.y > hy) hy = p.y;
            if (p.z > hz) hz = p.z;
        }
        this.box = Bounds(Vec3(lx, ly, lz), Vec3(hx, hy, hz));
        return this.box;
    }

    // Not skinned (any more): 0 joints, the version moved if it had some.
    private clear(): i32 {
        if (this.count != 0 || this.known) {
            this.count = 0;
            this.known = false;
            this.fixed = null;
            this.skeleton = null;
            this.skin = null;
            this.version++;
        }
        return 0;
    }
}

// `p` through palette slot `k`'s rows (the shader's skin_row sum, one
// slot).
function rowsPoint(pal: Float32Array, k: i32, x: f32, y: f32, z: f32, w: f32): Vec3 {
    const o = k * SKIN_FLOATS_PER_JOINT;
    return Vec3(
        (unchecked(pal[o]) * x + unchecked(pal[o + 1]) * y + unchecked(pal[o + 2]) * z + unchecked(pal[o + 3])) * w,
        (unchecked(pal[o + 4]) * x + unchecked(pal[o + 5]) * y + unchecked(pal[o + 6]) * z + unchecked(pal[o + 7])) * w,
        (unchecked(pal[o + 8]) * x + unchecked(pal[o + 9]) * y + unchecked(pal[o + 10]) * z + unchecked(pal[o + 11])) * w,
    );
}

// The 3 x 3 of vertex `i`'s blended matrix applied to direction `d`.
function rowsDir(pal: Float32Array, joints: u32, wt: Array<f32>, i: i32, count: i32, d: Vec3): Vec3 {
    let x: f32 = 0, y: f32 = 0, z: f32 = 0;
    for (let s = 0; s < 4; s++) {
        const w = unchecked(wt[i * 4 + s]);
        if (w == 0) continue;
        const k = <i32>((joints >> (<u32>s * 8)) & 0xff);
        if (k >= count) continue;
        const o = k * SKIN_FLOATS_PER_JOINT;
        x += w * (unchecked(pal[o]) * d.x + unchecked(pal[o + 1]) * d.y + unchecked(pal[o + 2]) * d.z);
        y += w * (unchecked(pal[o + 4]) * d.x + unchecked(pal[o + 5]) * d.y + unchecked(pal[o + 6]) * d.z);
        z += w * (unchecked(pal[o + 8]) * d.x + unchecked(pal[o + 9]) * d.y + unchecked(pal[o + 10]) * d.z);
    }
    return Vec3(x, y, z);
}

// Vertex `i` of `g` (a mesh with a skin) skinned by the first `count`
// joints of `pal`: its position (the shader's sum of the four slots'
// points, weighted) and its normal and tangent, as surface.wgsl's
// skinned_vertex makes them (the normal through the blended 3 x 3's
// cofactor, negated when it mirrors), normalised. A slot past `count`
// adds nothing.
export function skinVertex(g: GpuMesh, pal: Float32Array, count: i32, i: i32, v: SurfaceVertex): SurfaceVertex {
    const js = g.skinJoints;
    const ws = g.skinWeights;
    if (js == null || ws == null) return v;
    const joints = unchecked(js[i]);
    let p = Vec3(0, 0, 0);
    for (let s = 0; s < 4; s++) {
        const w = unchecked(ws[i * 4 + s]);
        if (w == 0) continue;
        const k = <i32>((joints >> (<u32>s * 8)) & 0xff);
        if (k >= count) continue;
        p = p + rowsPoint(pal, k, v.pos.x, v.pos.y, v.pos.z, w);
    }
    const bx = rowsDir(pal, joints, ws, i, count, Vec3(1, 0, 0));
    const by = rowsDir(pal, joints, ws, i, count, Vec3(0, 1, 0));
    const bz = rowsDir(pal, joints, ws, i, count, Vec3(0, 0, 1));
    const det = bx.dot(by.cross(bz));
    const sign: f32 = det < 0 ? -1 : 1;
    const nIn = v.normal;
    const n = (by.cross(bz) * nIn.x + bz.cross(bx) * nIn.y + bx.cross(by) * nIn.z) * sign;
    const t = bx * v.tangent.x + by * v.tangent.y + bz * v.tangent.z;
    const nl = n.length();
    const tl = t.length();
    return SurfaceVertex(p, nl > 0 ? n * (<f32>1 / nl) : n, v.uv, v.flags,
        Vec4(tl > 0 ? t.x / tl : t.x, tl > 0 ? t.y / tl : t.y, tl > 0 ? t.z / tl : t.z, v.tangent.w * sign), v.weight);
}

// A skinned item of a wire shading (see the header): `g` skinned on the
// CPU into a copy drawn with the identity, done again only when the palette
// (`version`, SkinState's) or the mesh (`meshVersion`: a blended copy's
// weights) changed. The copy carries no skin, so the renderer draws it as
// it is. Allocates nothing once its copy exists.
export class CpuSkin {
    private mesh: DeformedMesh? = null;
    private version: u32 = 0;
    private meshVersion: u32 = 0;
    private known: bool = false;
    seen: u32 = 0;

    skinned(
        g: GpuMesh, pal: Float32Array, count: i32, version: u32, meshVersion: u32, uploader: MeshUploader?,
        replaced: Array<GpuMesh>,
    ): GpuMesh {
        let d = this.mesh;
        if (d != null && d.base !== g && d.fits(g)) {
            // (a blended copy and its base, switched as a weight crosses 0:
            // the same vertices and edges, so the copy is kept)
            d.base = g;
            this.known = false;
        }
        if (d == null || d.base !== g) {
            // (a new mesh: the old copy's buffers are released)
            if (d != null) d.retire(replaced);
            d = new DeformedMesh(g);
            // (drawn as it is: the copy's vertices are already in place)
            d.out.skinJoints = null;
            d.out.skinWeights = null;
            this.mesh = d;
            this.known = false;
        }
        if (this.known && this.version == version && this.meshVersion == meshVersion) {
            if (d.stale || d.out.gpu == null) d.flush(uploader, replaced);
            return d.out;
        }
        // (milestone 67b: a skinned mesh keeps its vertices in a run time
        // that releases CPU copies, scene/resource/cpu_copy.as)
        if (g.cpuReleased) noteCpuMiss("skin: a released mesh");
        const vs = g.verts;
        const out = d.out.verts;
        for (let i = 0; i < vs.length && i < out.length; i++) {
            unchecked(out[i] = skinVertex(g, pal, count, i, unchecked(vs[i])));
        }
        d.finish(uploader, replaced);
        this.version = version;
        this.meshVersion = meshVersion;
        this.known = true;
        return d.out;
    }

    // The box of the copy as last skinned.
    get local(): Bounds {
        const d = this.mesh;
        return d != null ? d.local : Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    }

    // The copy (null before the first `skinned`).
    copy(): GpuMesh? {
        const d = this.mesh;
        return d != null ? d.out : null;
    }

    // Hands the copy to `uploader` when it changed without one.
    flush(uploader: MeshUploader, replaced: Array<GpuMesh>): void {
        const d = this.mesh;
        if (d != null && (d.stale || d.out.gpu == null)) d.flush(uploader, replaced);
    }
}
