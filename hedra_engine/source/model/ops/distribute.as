// `distribute on faces`: scatter points over a mesh's surface (PLAN §8/M9
// stage 4, after Blender's Distribute Points on Faces node).
//
// **A point cloud here is a mesh with no edges and no faces.** The kernel
// already stores loose vertices, `select`, the attribute layers and the
// renderer's vertex overlay all work on them, and glTF writes them as a
// POINTS primitive.
//
// Each point carries two attributes the instancer reads:
// - `surface_normal` (vec3): the normal of the face it landed on, so a
//   thing placed there can stand up on the surface.
// - `surface_id` (int): the face it came from.

import { Result, maxF32, roundF32, f32ToI64 } from "../../../base/util";
import { displayF32, debugF32, debugStr, debugStruct, debugSome, DEBUG_NONE } from "../../../base/fmt";
import { Vec3, VEC3_Z } from "../../../base/vecmath";
import { CoreError } from "../../../base/error";
import { OpReport, plural } from "../../../base/report";
import { Mesh, ElemKind, FaceId } from "../mesh/mod";
import { AttrType, AttrValue, Domain } from "../mesh/attr";
import { Scene, Object, ObjectData } from "../scene";
import { Rng } from "./mod";

export const SURFACE_NORMAL = "surface_normal";
export const SURFACE_ID = "surface_id";

// How points are placed. Both are seeded, so a replay lands them in the
// same places.
export enum Method {
    // Uniform by area: every point is independent, so they clump.
    Random,
    // Dart-throwing with a minimum distance.
    Poisson,
}

export namespace Method {
    // The variant named by `s`, or -1 when none matches.
    export function parse(s: string): i32 {
        if (s == "random") return Method.Random;
        if (s == "poisson" || s == "poisson-disk") return Method.Poisson;
        return -1;
    }

    export function name(m: Method): string {
        return m == Method.Random ? "random" : "poisson";
    }

    // Debug text: the variant name.
    export function debug(m: Method): string {
        return m == Method.Random ? "Random" : "Poisson";
    }
}

export class DistributeOpts {
    // Points to place in total, before any Poisson rejection.
    count: u32 = 100;
    // Points per square unit; used instead of `count` when set. `density` is
    // read only when `hasDensity` is true (use `setDensity`); NaN is a real
    // value (it asks for 0 points).
    density: f32 = NaN;
    hasDensity: bool = false;
    method: Method = Method.Random;
    // Poisson: no two points closer than this.
    minDistance: f32 = 0.1;
    seed: u64 = 0;
    // Scatter over the selected faces only.
    selectedOnly: bool = false;
    name: string? = null;

    // Sets `density`.
    setDensity(d: f32): DistributeOpts {
        this.density = d;
        this.hasDensity = true;
        return this;
    }

    clone(): DistributeOpts {
        const o = new DistributeOpts();
        o.count = this.count;
        o.density = this.density;
        o.hasDensity = this.hasDensity;
        o.method = this.method;
        o.minDistance = this.minDistance;
        o.seed = this.seed;
        o.selectedOnly = this.selectedOnly;
        o.name = this.name;
        return o;
    }

    // Debug text: `DistributeOpts { count: 100, density: None, method: Random, ... }`.
    debug(): string {
        const n = this.name;
        return debugStruct(
            "DistributeOpts",
            ["count", "density", "method", "min_distance", "seed", "selected_only", "name"],
            [
                this.count.toString(),
                this.hasDensity ? debugSome(debugF32(this.density)) : DEBUG_NONE,
                Method.debug(this.method),
                debugF32(this.minDistance),
                this.seed.toString(),
                this.selectedOnly ? "true" : "false",
                n != null ? debugSome(debugStr(n)) : DEBUG_NONE,
            ],
        );
    }
}

// One scattered point.
class Point {
    co: Vec3 = Vec3(0, 0, 0);
    normal: Vec3 = Vec3(0, 0, 0);
    face: FaceId = 0;
}

// The first index whose value is not below `pick`, over a non-decreasing
// array (binary search).
function partitionPoint(xs: Array<f32>, pick: f32): i32 {
    let lo = 0;
    let hi = xs.length;
    while (lo < hi) {
        const mid = lo + ((hi - lo) >> 1);
        if (xs[mid] < pick) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

class Scattered {
    points: Array<Point> = [];
    err: string? = null;
}

// Scatter over `mesh`, in face-id order so the result is reproducible.
function scatter(mesh: Mesh, opts: DistributeOpts): Scattered {
    const res = new Scattered();
    const faces: Array<FaceId> = [];
    const fb = mesh.faces.idBound();
    for (let id: u32 = 0; id < fb; id++) {
        const f = mesh.faces.get(id);
        if (f == null) continue;
        if (!opts.selectedOnly || f.select) faces.push(id);
    }
    if (faces.length == 0) {
        res.err = opts.selectedOnly ? "no faces are selected" : "the mesh has no faces to scatter over";
        return res;
    }

    // A cumulative area table, so a point lands on a face with probability
    // proportional to its area rather than one point per face.
    const cumulative: Array<f32> = [];
    let total: f32 = 0.0;
    for (let i = 0; i < faces.length; i++) {
        total += maxF32(mesh.faceArea(faces[i]), 0);
        cumulative.push(total);
    }
    if (total <= <f32>0.0) {
        res.err = "those faces have no area";
        return res;
    }
    let wanted: i64;
    if (opts.hasDensity) {
        const r = f32ToI64(roundF32(opts.density * total));
        wanted = r < 0 ? 0 : (r > 1000000 ? 1000000 : r);
    } else {
        wanted = <i64>opts.count;
    }
    if (wanted == 0) {
        return res;
    }

    const rng = new Rng(opts.seed);
    const out = res.points;
    // Dart-throwing gives up rather than looping forever when the surface
    // cannot hold that many points at that spacing.
    const attempts: i64 = opts.method == Method.Random ? wanted : wanted * 30;
    const minSq = opts.minDistance * opts.minDistance;
    for (let a: i64 = 0; a < attempts; a++) {
        if (<i64>out.length >= wanted) {
            break;
        }
        const pick = rng.nextF32() * total;
        let i = partitionPoint(cumulative, pick);
        if (i > faces.length - 1) i = faces.length - 1;
        const face = faces[i];
        const p = pointInFace(mesh, face, rng);
        if (p == null) {
            continue;
        }
        if (opts.method == Method.Poisson) {
            let near = false;
            for (let k = 0; k < out.length; k++) {
                if (out[k].co.distanceSquared(p.v) < minSq) {
                    near = true;
                    break;
                }
            }
            if (near) continue;
        }
        const pt = new Point();
        pt.co = p.v;
        pt.normal = mesh.faces.at(face).normal;
        pt.face = face;
        out.push(pt);
    }
    return res;
}

// A present Vec3 (null stands for none).
class SomeVec3 {
    v: Vec3;
    constructor(v: Vec3) {
        this.v = v;
    }
}

// The position of a loop's vertex, or null.
function corner(mesh: Mesh, l: u32): SomeVec3? {
    const lp = mesh.loops.get(l);
    if (lp == null) return null;
    const v = mesh.verts.get(lp.vert);
    if (v == null) return null;
    return new SomeVec3(v.co);
}

// A uniform point inside one face: pick a triangle of its fan by area,
// then a barycentric point in it.
function pointInFace(mesh: Mesh, face: FaceId, rng: Rng): SomeVec3? {
    const tris = mesh.triangulateFace(face);
    if (tris.length == 0) {
        return null;
    }
    const areas: Array<f32> = [];
    let total: f32 = 0.0;
    for (let i = 0; i < tris.length; i++) {
        const t = tris[i];
        const a = corner(mesh, t[0]);
        if (a == null) return null;
        const b = corner(mesh, t[1]);
        if (b == null) return null;
        const c = corner(mesh, t[2]);
        if (c == null) return null;
        total += (b.v - a.v).cross(c.v - a.v).length() * <f32>0.5;
        areas.push(total);
    }
    if (total <= <f32>0.0) {
        return null;
    }
    const pick = rng.nextF32() * total;
    let i = partitionPoint(areas, pick);
    if (i > tris.length - 1) i = tris.length - 1;
    const t = tris[i];
    const a = corner(mesh, t[0]);
    if (a == null) return null;
    const b = corner(mesh, t[1]);
    if (b == null) return null;
    const c = corner(mesh, t[2]);
    if (c == null) return null;
    // Uniform barycentric coordinates by folding the unit square.
    let u = rng.nextF32();
    let v = rng.nextF32();
    if (u + v > <f32>1.0) {
        u = <f32>1.0 - u;
        v = <f32>1.0 - v;
    }
    return new SomeVec3(a.v + (b.v - a.v) * u + (c.v - a.v) * v);
}

// `distribute on faces`: a new object of loose points over the active
// mesh, placed in the same world space (it copies the source transform).
export function distribute(scene: Scene, opts: DistributeOpts): Result<OpReport> {
    const rid = scene.requireActive();
    if (!rid.ok) return rid.forward<OpReport>();
    const id = rid.value;
    if (scene.objects.at(id).mesh() == null) {
        return Result.failWith<OpReport>(CoreError.invalidArgument("`distribute on faces` needs a mesh object"));
    }
    // The *evaluated* surface, so points land on what the stack produced.
    const mesh = scene.evaluatedMesh(id);
    if (mesh == null) {
        return Result.failWith<OpReport>(CoreError.invalidArgument("`distribute on faces` needs a mesh object"));
    }
    const sc = scatter(mesh.mesh, opts);
    const err = sc.err;
    if (err != null) return Result.failWith<OpReport>(CoreError.invalidArgument(err));
    const points = sc.points;
    const source = scene.objects.at(id);
    const transform = source.transform;
    const sourceName = source.name;

    const cloud = new Mesh();
    cloud.addAttr(SURFACE_NORMAL, Domain.Point, AttrType.Vec3);
    cloud.addAttr(SURFACE_ID, Domain.Point, AttrType.Int);
    for (let i = 0; i < points.length; i++) {
        const p = points[i];
        const v = cloud.addVert(p.co);
        const an = cloud.attrMut(SURFACE_NORMAL);
        if (an != null) an.set(v, AttrValue.vec3(p.normal));
        const ai = cloud.attrMut(SURFACE_ID);
        if (ai != null) ai.set(v, AttrValue.num(<f64>p.face));
    }

    const n = points.length;
    const optName = opts.name;
    const base = optName != null ? optName : sourceName + " Points";
    const name = scene.uniqueName(base);
    const obj = new Object(name, ObjectData.fromMesh(cloud));
    obj.transform = transform;
    obj.select = true;
    const ob = scene.objects.idBound();
    for (let k: u32 = 0; k < ob; k++) {
        const o = scene.objects.get(k);
        if (o != null) o.select = false;
    }
    const newId = scene.addObject(obj);
    scene.active = newId;

    let report = OpReport.new(
        "Distributed " + plural(<i64>n, "point") + " on '" + sourceName + "' (" + Method.name(opts.method) + ") into '" + name + "'",
    ).withObjects([name]);
    const wanted: i64 = opts.hasDensity ? <i64>n : <i64>opts.count;
    if (opts.method == Method.Poisson && <i64>n < wanted) {
        report = report.warn(
            "only " + n.toString() + " of " + wanted.toString() + " points fit at a minimum distance of "
                + displayF32(opts.minDistance) + "; lower --min-distance or ask for fewer",
        );
    }
    return Result.okv<OpReport>(report);
}

// One point of a cloud: id, position and normal.
export class CloudPoint {
    id: u32 = 0;
    co: Vec3 = Vec3(0, 0, 0);
    normal: Vec3 = Vec3(0, 0, 0);
}

// The points of a cloud, with the normal each one recorded. Used by the
// instance modifier; a mesh without the attribute gives `+Z`, which places
// everything upright rather than failing.
export function pointsOf(mesh: Mesh): Array<CloudPoint> {
    const out: Array<CloudPoint> = [];
    const vb = mesh.verts.idBound();
    for (let id: u32 = 0; id < vb; id++) {
        const v = mesh.verts.get(id);
        if (v == null) continue;
        let n = VEC3_Z;
        const a = mesh.attrValue(SURFACE_NORMAL, ElemKind.Vert, id);
        if (a != null) {
            const nv = a.asVec3();
            if (!(nv == Vec3(0, 0, 0))) n = nv;
        }
        const p = new CloudPoint();
        p.id = id;
        p.co = v.co;
        p.normal = n.normalizeOrZero();
        out.push(p);
    }
    return out;
}
