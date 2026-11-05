// The particles' draw (milestone 35): a CPUParticles3D's living particles
// packed into its state's InstanceData (render/instances.as's 64-byte
// layout: three transform rows, then the colour), in draw_order, with the
// box around them, for one instanced draw of the node's mesh
// (../render/adapter.as plans and refreshes it, ../render/particles.as
// gives it the camera, the renderer updates the dynamic buffer when
// `version` moves: render/gpu/instances.as).
//
// The transforms are packed in the node's space, as Godot's
// _update_particle_data_buffer packs them: without local_coords each
// particle's scene-space transform is taken there by the inverse of the
// node's global transform, so the item is placed by the node in both
// modes, as a MultiMeshInstance3D's is (its DrawItem.world the node's).
//
// Each particle's transform is translation x basis x scale (Godot's
// _particles_process ends so): the basis the identity of the node's space
// with local_coords, and without it the emitter's rotation when the
// particle was emitted (state.as qx..qw: Godot's emission_xform x
// p.transform, orthonormalised each frame, so a particle keeps the turn
// its emitter had); with particle_flag_align_y its Y along its velocity,
// Z = X x Y and X = Y x Z from that basis's X (Godot orthonormalises the
// particle's last basis instead, which for a particle that turns gradually
// gives the same Y and nearly the same X; with no basis kept per particle
// this one is worked out afresh each frame, the same in every tool); with
// particle_flag_rotate_y Basis(Y, angle) outright, as Godot sets it (the
// emission's rotation and align_y's left out); then each row times the
// particle's scale on that axis (Godot's Basis::scale, diag(S) x basis: a
// split scale runs along the axes of the space the basis is in).
//
// Billboards (the mesh's material's billboard_mode, Godot's
// BaseMaterial3D shader, turned here on the CPU because the surface shader
// has no billboard path): with the camera's right R, up U and back B (unit,
// scene space; the frame's camera, ../render/particles.as),
//   enabled    the basis (R, U, B);
//   particles  (R cos a - U sin a, R sin a + U cos a, B), a the particle's
//              angle (Godot's BILLBOARD_PARTICLES matrix);
//   fixed_y    (R, Y, normalize(R x Y)), Y the particle's Y column as
//              Godot's MODEL_MATRIX[1] has it (its basis and scale, in the
//              scene): turned about its own Y only;
// with billboard_keep_scale each column (fixed_y: X and Z; its Y always
// keeps its length, as Godot's shader does) times the length of that
// column of the particle's transform, which keeps its scale; without it
// the mesh's own size. That basis is the particle's in the scene, taken
// into the node's space by the inverse of the node's global transform as
// any particle's.
//
// draw_order (Godot's): index (the particles' own order), lifetime (the
// oldest first: Godot's SortLifetime), reverse_lifetime (the youngest
// first), view_depth (the farthest first along the camera's view: Godot's
// SortAxis on the camera's back axis). state.order holds every particle,
// the living first in that order, the dead after, from one pack to the
// next; each pack sorts it again in place by state.keys, ties by index (an
// insertion sort from the last order, nearly sorted already when the
// particles moved a frame's worth, a heapsort when that would cost more),
// so the order is the same on every host and nothing is allocated.
//
// The box: around each packed particle's copy of the mesh's box. A
// billboard's copy turns with the camera, so its box is the ball it turns
// in (the mesh's extent along each axis times its column's length, summed:
// a bound for any turn), so that the box holds from every camera and is
// known before the camera is chosen (`particleBounds`), as an
// ArtboardSprite3D billboard's is. Only the living are drawn (Godot draws
// every particle, the dead with a zero transform).
//
// A pack is skipped when neither the state's version nor anything else it
// reads moved (state.packedVersion, state.packedStamp: the node's global
// transform, the mesh's box, the billboard, the draw order and the flags,
// and the camera when the pack depends on it: a billboard or view_depth).
// Allocation-free once the state is made.

import { Mat4, Vec3, cosf, sinf } from "../../base/vecmath";
import { Bounds } from "../../render/camera";
import { INSTANCE_STRIDE } from "../../render/instances";
import { CPUParticles3D } from "../tree/node";
import {
    BILLBOARD_DISABLED, BILLBOARD_ENABLED, BILLBOARD_FIXED_Y, BILLBOARD_PARTICLES, DRAW_ORDER_INDEX,
    DRAW_ORDER_LIFETIME, DRAW_ORDER_REVERSE_LIFETIME, DRAW_ORDER_VIEW_DEPTH, ParticleState,
} from "./state";

// What a pack came to: the box around every packed particle's copy of the
// mesh's box, in the node's space (see above), `has` false when none is
// alive.
export class ParticleBox {
    box: Bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    has: bool = false;
}

// A cross product shorter than this is taken as no direction.
const DEGENERATE: f32 = 1e-6;

// Whether billboard mode `b` turns the particles to the camera.
export function isBillboard(b: i32): bool {
    return b == BILLBOARD_ENABLED || b == BILLBOARD_FIXED_Y || b == BILLBOARD_PARTICLES;
}

// Whether a pack of `node` with billboard mode `b` depends on the camera.
export function packNeedsCamera(node: CPUParticles3D, b: i32): bool {
    return isBillboard(b) || node.drawOrder == DRAW_ORDER_VIEW_DEPTH;
}

// The kept scratch of a pack (one: packing is not reentrant).
class Scratch {
    // A particle's basis columns (scale included), its space's.
    x: Vec3 = Vec3(1, 0, 0);
    y: Vec3 = Vec3(0, 1, 0);
    z: Vec3 = Vec3(0, 0, 1);
    // A billboard's: the lengths its columns keep (billboard_keep_scale:
    // those of the particle's own, in the scene; else 1), and its own Y in
    // the scene (fixed_y's).
    lx: f32 = 1;
    ly: f32 = 1;
    lz: f32 = 1;
    yw: Vec3 = Vec3(0, 1, 0);
    // The camera, scene space: right, up, back (unit).
    right: Vec3 = Vec3(1, 0, 0);
    up: Vec3 = Vec3(0, 1, 0);
    back: Vec3 = Vec3(0, 0, 1);
}
const scratch = new Scratch();

// The particle `i`'s basis (see the header) into scratch.x, .y, .z;
// `world` without local_coords (the particle's emission rotation its base).
function particleBasis(s: ParticleState, i: i32, alignY: bool, rotateY: bool, world: bool): void {
    let x = Vec3(1, 0, 0);
    let y = Vec3(0, 1, 0);
    let z = Vec3(0, 0, 1);
    if (rotateY) {
        // (Godot sets the basis to Basis(Y, angle) outright: the emission's
        // rotation and align_y's are dropped)
        const a = unchecked(s.angle[i]);
        const c = cosf(a);
        const sn = sinf(a);
        x = Vec3(c, 0, -sn);
        z = Vec3(sn, 0, c);
    } else {
        if (world) {
            // (the rotation's columns, from its unit quaternion)
            const qx = unchecked(s.qx[i]);
            const qy = unchecked(s.qy[i]);
            const qz = unchecked(s.qz[i]);
            const qw = unchecked(s.qw[i]);
            const xx = qx * qx;
            const yy = qy * qy;
            const zz = qz * qz;
            const xy = qx * qy;
            const xz = qx * qz;
            const yz = qy * qz;
            const wx = qw * qx;
            const wy = qw * qy;
            const wz = qw * qz;
            x = Vec3(1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy));
            y = Vec3(2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx));
            z = Vec3(2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy));
        }
        if (alignY) {
            const v = Vec3(unchecked(s.vx[i]), unchecked(s.vy[i]), unchecked(s.vz[i]));
            const len = v.length();
            if (len > 0) y = v / len;
            const zc = x.cross(y);
            if (zc.length() < DEGENERATE) {
                // (Y along X: Godot's other branch, from Z)
                x = y.cross(z).normalize();
                z = x.cross(y).normalize();
            } else {
                z = zc.normalize();
                x = y.cross(z).normalize();
            }
        }
    }
    // (Godot's Basis::scale: the rows times the scale, diag(S) x basis, so
    // a split scale runs along the axes of the space the basis is in, not
    // the particle's own; the same for a uniform scale)
    const sc = Vec3(unchecked(s.sx[i]), unchecked(s.sy[i]), unchecked(s.sz[i]));
    scratch.x = x.mul(sc);
    scratch.y = y.mul(sc);
    scratch.z = z.mul(sc);
}

// A billboard particle's lengths and Y (Scratch's) from its own basis
// (particleBasis first), the pack's run begun.
function billboardLengths(mode: i32, keepScale: bool): void {
    let lx: f32 = 1;
    let ly: f32 = 1;
    let lz: f32 = 1;
    if (mode == BILLBOARD_FIXED_Y || keepScale) scratch.yw = run.sceneVector(scratch.y);
    if (keepScale) {
        lx = run.sceneVector(scratch.x).length();
        ly = scratch.yw.length();
        lz = run.sceneVector(scratch.z).length();
    }
    scratch.lx = lx;
    scratch.ly = ly;
    scratch.lz = lz;
}

// The billboard basis of particle `i` (scene space) into scratch.x, .y, .z,
// from its lengths (billboardLengths first) and the camera.
function billboardBasis(s: ParticleState, i: i32, mode: i32): void {
    const r = scratch.right;
    const u = scratch.up;
    const b = scratch.back;
    const lx = scratch.lx;
    const ly = scratch.ly;
    const lz = scratch.lz;
    if (mode == BILLBOARD_FIXED_Y) {
        const yw = scratch.yw;
        let z = r.cross(yw);
        z = z.length() < DEGENERATE ? b : z.normalize();
        scratch.x = r * lx;
        scratch.y = yw;
        scratch.z = z * lz;
        return;
    }
    if (mode == BILLBOARD_PARTICLES) {
        const a = unchecked(s.angle[i]);
        const c = cosf(a);
        const sn = sinf(a);
        scratch.x = (r * c - u * sn) * lx;
        scratch.y = (r * sn + u * c) * ly;
        scratch.z = b * lz;
        return;
    }
    scratch.x = r * lx;
    scratch.y = u * ly;
    scratch.z = b * lz;
}

// What one pack holds for every particle (kept: packing is not
// reentrant), and the box it gathers, in scalars: a plan of thousands of
// particles a frame spends nothing on boxes it does not need.
class PackRun {
    local: bool = false;
    mode: i32 = BILLBOARD_DISABLED;
    keepScale: bool = false;
    // `global`'s columns (the particle's space to the scene's, with
    // local_coords).
    gx: Vec3 = Vec3(1, 0, 0);
    gy: Vec3 = Vec3(0, 1, 0);
    gz: Vec3 = Vec3(0, 0, 1);
    gw: Vec3 = Vec3(0, 0, 0);
    // The inverse of `global`, by column (worked with in scalars: the hot
    // loop copies no matrix).
    ix: Vec3 = Vec3(1, 0, 0);
    iy: Vec3 = Vec3(0, 1, 0);
    iz: Vec3 = Vec3(0, 0, 1);
    iw: Vec3 = Vec3(0, 0, 0);
    // The mesh's box as a centre and half its size, and its extent along
    // each axis from its origin (a billboard's ball).
    centre: Vec3 = Vec3(0, 0, 0);
    half: Vec3 = Vec3(0, 0, 0);
    ext: Vec3 = Vec3(0, 0, 0);
    // The lengths of inv's rows (a ball of the scene in the node's space).
    rows: Vec3 = Vec3(1, 1, 1);
    // The particle's origin in the node's space.
    o: Vec3 = Vec3(0, 0, 0);
    // Some packed transform mirrors (InstanceData.anyMirrored).
    mirrored: bool = false;
    // The box so far.
    n: i32 = 0;
    minX: f32 = 0;
    minY: f32 = 0;
    minZ: f32 = 0;
    maxX: f32 = 0;
    maxY: f32 = 0;
    maxZ: f32 = 0;

    begin(node: CPUParticles3D, global: Mat4, meshLocal: Bounds, mode: i32, keepScale: bool): void {
        this.local = node.localCoords;
        this.mode = mode;
        this.keepScale = keepScale;
        this.gx = global.xAxis.xyz();
        this.gy = global.yAxis.xyz();
        this.gz = global.zAxis.xyz();
        this.gw = global.wAxis.xyz();
        const inv = global.inverse();
        this.ix = inv.xAxis.xyz();
        this.iy = inv.yAxis.xyz();
        this.iz = inv.zAxis.xyz();
        this.iw = inv.wAxis.xyz();
        const lo = meshLocal.min;
        const hi = meshLocal.max;
        this.centre = (lo + hi) * <f32>0.5;
        this.half = (hi - lo) * <f32>0.5;
        this.ext = Vec3(max<f32>(Mathf.abs(lo.x), Mathf.abs(hi.x)), max<f32>(Mathf.abs(lo.y), Mathf.abs(hi.y)),
            max<f32>(Mathf.abs(lo.z), Mathf.abs(hi.z)));
        this.rows = Vec3(Vec3(inv.xAxis.x, inv.yAxis.x, inv.zAxis.x).length(),
            Vec3(inv.xAxis.y, inv.yAxis.y, inv.zAxis.y).length(), Vec3(inv.xAxis.z, inv.yAxis.z, inv.zAxis.z).length());
        this.n = 0;
    }

    // Grows the box by the one from (x0, y0, z0) to (x1, y1, z1).
    grow(x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32): void {
        if (this.n == 0) {
            this.minX = x0;
            this.minY = y0;
            this.minZ = z0;
            this.maxX = x1;
            this.maxY = y1;
            this.maxZ = z1;
        } else {
            this.minX = min<f32>(this.minX, x0);
            this.minY = min<f32>(this.minY, y0);
            this.minZ = min<f32>(this.minZ, z0);
            this.maxX = max<f32>(this.maxX, x1);
            this.maxY = max<f32>(this.maxY, y1);
            this.maxZ = max<f32>(this.maxZ, z1);
        }
        this.n++;
    }

    box(): Bounds {
        return Bounds(Vec3(this.minX, this.minY, this.minZ), Vec3(this.maxX, this.maxY, this.maxZ));
    }

    // `v` (a direction of the particle's space) in the scene.
    sceneVector(v: Vec3): Vec3 {
        if (!this.local) return v;
        const a = this.gx;
        const b = this.gy;
        const c = this.gz;
        return Vec3(a.x * v.x + b.x * v.y + c.x * v.z, a.y * v.x + b.y * v.y + c.y * v.z,
            a.z * v.x + b.z * v.y + c.z * v.z);
    }

    // A particle's position in the scene.
    scenePoint(p: Vec3): Vec3 {
        return this.local ? this.sceneVector(p) + this.gw : p;
    }

    // `v` (a direction of the scene) in the node's space.
    nodeVector(v: Vec3): Vec3 {
        const a = this.ix;
        const b = this.iy;
        const c = this.iz;
        return Vec3(a.x * v.x + b.x * v.y + c.x * v.z, a.y * v.x + b.y * v.y + c.y * v.z,
            a.z * v.x + b.z * v.y + c.z * v.z);
    }

    // Particle `i`'s origin in the node's space (into `o`).
    place(s: ParticleState, i: i32): void {
        const p = Vec3(unchecked(s.px[i]), unchecked(s.py[i]), unchecked(s.pz[i]));
        this.o = this.local ? p : this.nodeVector(p) + this.iw;
    }

    // Scratch's basis (the particle's space's, or with `billboard` a
    // billboard's in the scene) taken into the node's space.
    toNode(billboard: bool): void {
        if (!billboard && this.local) return;
        scratch.x = this.nodeVector(scratch.x);
        scratch.y = this.nodeVector(scratch.y);
        scratch.z = this.nodeVector(scratch.z);
    }

    // The box of the mesh placed by scratch's node-space basis at `o`.
    growMesh(): void {
        const x = scratch.x;
        const y = scratch.y;
        const z = scratch.z;
        const c = this.centre;
        const h = this.half;
        const o = this.o;
        const cx = o.x + x.x * c.x + y.x * c.y + z.x * c.z;
        const cy = o.y + x.y * c.x + y.y * c.y + z.y * c.z;
        const cz = o.z + x.z * c.x + y.z * c.y + z.z * c.z;
        const hx = Mathf.abs(x.x) * h.x + Mathf.abs(y.x) * h.y + Mathf.abs(z.x) * h.z;
        const hy = Mathf.abs(x.y) * h.x + Mathf.abs(y.y) * h.y + Mathf.abs(z.y) * h.z;
        const hz = Mathf.abs(x.z) * h.x + Mathf.abs(y.z) * h.y + Mathf.abs(z.z) * h.z;
        this.grow(cx - hx, cy - hy, cz - hz, cx + hx, cy + hy, cz + hz);
    }

    // The ball a billboard's mesh turns in at `o` (see the header), from
    // the particle's own basis (particleBasis, then billboardLengths),
    // whatever the camera.
    growBall(): void {
        billboardLengths(this.mode, this.keepScale);
        const lx = scratch.lx;
        const ly = this.mode == BILLBOARD_FIXED_Y ? scratch.yw.length() : scratch.ly;
        const lz = scratch.lz;
        const e = this.ext;
        const rad = e.x * lx + e.y * ly + e.z * lz;
        // A ball of radius `rad` in the scene, taken into the node's space:
        // along node axis j at most rad times the length of inv's row j.
        const r = this.rows;
        const o = this.o;
        this.grow(o.x - rad * r.x, o.y - rad * r.y, o.z - rad * r.z, o.x + rad * r.x, o.y + rad * r.y, o.z + rad * r.z);
    }
}
const run = new PackRun();

// How many particles the state's arrays and its draw's bytes both hold.
function livingCap(s: ParticleState): i32 {
    const rows = s.instances.bytes.byteLength / <i32>INSTANCE_STRIDE;
    return min<i32>(min<i32>(s.capacity, s.active.length), rows);
}

// The box packParticles would give `node`'s particles (see the header: a
// billboard's does not depend on the camera), into `out`, without packing:
// the plan's box while the camera is not chosen yet. Returns how many
// live. Allocates nothing.
export function particleBounds(
    node: CPUParticles3D, global: Mat4, meshLocal: Bounds, billboard: i32, keepScale: bool, out: ParticleBox,
): i32 {
    out.has = false;
    const s = node.particles;
    if (s == null) return 0;
    const mode = isBillboard(billboard) ? billboard : BILLBOARD_DISABLED;
    run.begin(node, global, meshLocal, mode, keepScale);
    const cap = livingCap(s);
    const alignY = node.flagAlignY;
    const rotateY = node.flagRotateY;
    for (let i = 0; i < cap; i++) {
        if (unchecked(s.active[i]) == 0) continue;
        particleBasis(s, i, alignY, rotateY, !run.local);
        run.place(s, i);
        if (mode != BILLBOARD_DISABLED) {
            run.growBall();
        } else {
            run.toNode(false);
            run.growMesh();
        }
    }
    const n = run.n;
    out.box = n > 0 ? run.box() : Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    out.has = n > 0;
    return n;
}

// FNV-1a, 64 bits, over a number's bits.
const FNV_OFFSET: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

function mixF(h: u64, x: f32): u64 {
    return (h ^ <u64>reinterpret<u32>(x)) * FNV_PRIME;
}

function mixV(h: u64, v: Vec3): u64 {
    return mixF(mixF(mixF(h, v.x), v.y), v.z);
}

// What a pack reads besides the state (see the header), as one number.
function packStamp(
    node: CPUParticles3D, global: Mat4, meshLocal: Bounds, billboard: i32, keepScale: bool, camera: bool, eye: Vec3,
    forward: Vec3, up: Vec3,
): u64 {
    let h = FNV_OFFSET;
    h = mixV(h, global.xAxis.xyz());
    h = mixV(h, global.yAxis.xyz());
    h = mixV(h, global.zAxis.xyz());
    h = mixV(h, global.wAxis.xyz());
    h = mixV(h, meshLocal.min);
    h = mixV(h, meshLocal.max);
    let flags: u32 = <u32>billboard & 0xff;
    flags |= (<u32>node.drawOrder & 0xff) << 8;
    if (keepScale) flags |= 1 << 16;
    if (node.localCoords) flags |= 1 << 17;
    if (node.flagAlignY) flags |= 1 << 18;
    if (node.flagRotateY) flags |= 1 << 19;
    h = (h ^ <u64>flags) * FNV_PRIME;
    if (camera) {
        h = mixV(h, eye);
        h = mixV(h, forward);
        h = mixV(h, up);
    }
    // (0 is no pack's: a state's first)
    return h == 0 ? 1 : h;
}

// Whether particle `a` sorts before particle `b`: by key, then by index.
@inline
function before(keys: StaticArray<f32>, a: i32, b: i32): bool {
    const ka = unchecked(keys[a]);
    const kb = unchecked(keys[b]);
    return ka < kb || (ka == kb && a < b);
}

// Sorts order[0..n) by `keys` (by particle index), in place: a heapsort,
// so nothing is allocated and the order does not depend on the host.
function sortOrder(order: StaticArray<i32>, keys: StaticArray<f32>, n: i32): void {
    for (let start = (n >> 1) - 1; start >= 0; start--) siftDown(order, keys, start, n);
    for (let end = n - 1; end > 0; end--) {
        const t = unchecked(order[0]);
        unchecked(order[0] = order[end]);
        unchecked(order[end] = t);
        siftDown(order, keys, 0, end);
    }
}

function siftDown(order: StaticArray<i32>, keys: StaticArray<f32>, start: i32, n: i32): void {
    let root = start;
    while (true) {
        let child = root * 2 + 1;
        if (child >= n) return;
        if (child + 1 < n && before(keys, unchecked(order[child]), unchecked(order[child + 1]))) child++;
        if (!before(keys, unchecked(order[root]), unchecked(order[child]))) return;
        const t = unchecked(order[root]);
        unchecked(order[root] = order[child]);
        unchecked(order[child] = t);
        root = child;
    }
}

// The camera (node space: a view and an up direction) taken to the scene
// through `global`, as unit right, up and back, into scratch; a view of no
// length is the scene's -Z, an up along it gives the right +X.
function cameraIn(global: Mat4, forward: Vec3, up: Vec3): void {
    let f = global.transformVector3(forward);
    f = f.length() < DEGENERATE ? Vec3(0, 0, -1) : f.normalize();
    let u = global.transformVector3(up);
    let r = f.cross(u);
    r = r.length() < DEGENERATE ? Vec3(1, 0, 0) : r.normalize();
    u = r.cross(f);
    scratch.right = r;
    scratch.up = u;
    scratch.back = -f;
}

// Where `b`'s bytes start.
unsafe function bytesAt(b: ArrayBuffer): usize {
    return changetype<usize>(b);
}

// One instance at `at` from scratch's node-space basis and `o`
// (render/instances.as's layout: the rows (x, y, z) of each axis's
// component r, then the origin's r; then the colour).
unsafe function writeInstance(at: usize, o: Vec3, r: f32, g: f32, b: f32, a: f32): void {
    const x = scratch.x;
    const y = scratch.y;
    const z = scratch.z;
    store<f32>(at, x.x, 0);
    store<f32>(at, y.x, 4);
    store<f32>(at, z.x, 8);
    store<f32>(at, o.x, 12);
    store<f32>(at, x.y, 16);
    store<f32>(at, y.y, 20);
    store<f32>(at, z.y, 24);
    store<f32>(at, o.y, 28);
    store<f32>(at, x.z, 32);
    store<f32>(at, y.z, 36);
    store<f32>(at, z.z, 40);
    store<f32>(at, o.z, 44);
    store<f32>(at, r, 48);
    store<f32>(at, g, 52);
    store<f32>(at, b, 56);
    store<f32>(at, a, 60);
}

// Particle `i` packed as row `k` (see the header), its box grown into the
// run; the run's camera in scratch (cameraIn) for a billboard.
function packOne(s: ParticleState, i: i32, k: i32, base: usize, mode: i32, alignY: bool, rotateY: bool): void {
    particleBasis(s, i, alignY, rotateY, !run.local);
    run.place(s, i);
    if (mode != BILLBOARD_DISABLED) {
        run.growBall();
        billboardBasis(s, i, mode);
        run.toNode(true);
    } else {
        run.toNode(false);
        run.growMesh();
    }
    const x = scratch.x;
    const y = scratch.y;
    const z = scratch.z;
    const det = x.x * (y.y * z.z - y.z * z.y) - y.x * (x.y * z.z - x.z * z.y) + z.x * (x.y * y.z - x.z * y.y);
    if (det < 0) run.mirrored = true;
    writeInstance(base + <usize>(k * <i32>INSTANCE_STRIDE), run.o, unchecked(s.r[i]), unchecked(s.g[i]),
        unchecked(s.b[i]), unchecked(s.a[i]));
}

// Sorts order[0..n) by `keys` in place, from the order it is in: an
// insertion sort, which costs about n for an order that was sorted a frame
// ago, given up for the heapsort (sortOrder) once it has moved more than
// 16 n entries (a burst of particles all born at once), so that no frame
// costs more than n log n. Allocates nothing.
function sortCoherent(order: StaticArray<i32>, keys: StaticArray<f32>, n: i32): void {
    let budget = n * 16 + 64;
    for (let k = 1; k < n; k++) {
        const v = unchecked(order[k]);
        let j = k - 1;
        while (j >= 0 && before(keys, v, unchecked(order[j]))) {
            unchecked(order[j + 1] = order[j]);
            j--;
            budget--;
            if (budget < 0) {
                unchecked(order[j + 1] = v);
                sortOrder(order, keys, n);
                return;
            }
        }
        unchecked(order[j + 1] = v);
    }
}

// Packs `node`'s particles (node.particles, made: sim.as ensureParticles)
// into node.particles.instances, the node's global transform (scene space)
// being `global`, for a mesh whose box is `meshLocal`, with
// `billboard` (BILLBOARD_* of state.as) and `keepScale` from its material,
// facing a camera at `eye` looking along `forward` with `up` (in the node's
// space: a point and two directions taken there by the inverse of
// `global`); `out` gets the box. Returns whether the bytes changed
// (InstanceData.version moved); packs nothing when neither the state's
// version nor anything else it reads moved since the last pack (the header).
export function packParticles(
    node: CPUParticles3D, global: Mat4, meshLocal: Bounds, billboard: i32, keepScale: bool, eye: Vec3, forward: Vec3,
    up: Vec3, out: ParticleBox,
): bool {
    const s = node.particles;
    out.has = false;
    if (s == null) return false;
    const inst = s.instances;
    const mode = isBillboard(billboard) ? billboard : BILLBOARD_DISABLED;
    const order = node.drawOrder;
    const camera = packNeedsCamera(node, mode);
    const stamp = packStamp(node, global, meshLocal, mode, keepScale, camera, eye, forward, up);
    if (s.packedVersion == s.version && s.packedStamp == stamp) {
        out.box = inst.local;
        out.has = inst.hasLocal;
        return false;
    }
    run.begin(node, global, meshLocal, mode, keepScale);
    if (camera) cameraIn(global, forward, up);
    const cap = livingCap(s);
    const base = bytesAt(inst.bytes);
    run.mirrored = false;
    let n = 0;
    if (order == DRAW_ORDER_INDEX) {
        for (let i = 0; i < cap; i++) {
            if (unchecked(s.active[i]) == 0) continue;
            packOne(s, i, n, base, mode, node.flagAlignY, node.flagRotateY);
            n++;
        }
    } else {
        // Every particle by its key (the dead last), sorted from the last
        // pack's order: particles move little from frame to frame, so the
        // order is nearly sorted already (see sortCoherent). The state makes
        // it every index (state.as resize), so the order is right whatever
        // order packed before, index included (which never reads it).
        const ord = s.order;
        const keys = s.keys;
        const fwd = -scratch.back;
        for (let i = 0; i < cap; i++) {
            let k: f32 = Infinity;
            if (unchecked(s.active[i]) != 0) {
                if (order == DRAW_ORDER_LIFETIME) {
                    k = -unchecked(s.time[i]);
                } else if (order == DRAW_ORDER_REVERSE_LIFETIME) {
                    k = unchecked(s.time[i]);
                } else {
                    const p = Vec3(unchecked(s.px[i]), unchecked(s.py[i]), unchecked(s.pz[i]));
                    // (farthest first: the most distance along the view
                    // sorts first)
                    k = -run.scenePoint(p).dot(fwd);
                }
                // (a NaN sorts first, and nothing living after the dead)
                k = isNaN<f32>(k) ? -f32.MAX_VALUE : min<f32>(k, f32.MAX_VALUE);
            }
            unchecked(keys[i] = k);
        }
        sortCoherent(ord, keys, cap);
        for (let k = 0; k < cap; k++) {
            const i = unchecked(ord[k]);
            if (unchecked(s.active[i]) == 0) break;
            packOne(s, i, n, base, mode, node.flagAlignY, node.flagRotateY);
            n++;
        }
    }
    const mirrored = run.mirrored;
    const box = n > 0 ? run.box() : Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    inst.count = <u32>n;
    inst.hasColors = true;
    inst.anyMirrored = mirrored;
    inst.local = box;
    inst.hasLocal = n > 0;
    inst.version++;
    s.packedVersion = s.version;
    s.packedStamp = stamp;
    out.box = box;
    out.has = n > 0;
    return true;
}
