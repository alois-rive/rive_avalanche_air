// Shrinkwrap (Blender: Deform > Shrinkwrap): pull every vertex onto the
// surface of another object.
//
// All three of Blender's modes are here. `nearest-surface-point` is the
// default and the one that behaves well on anything; `project` casts along
// an axis or the vertex normal, which is how a decal or a cloth panel is
// laid onto a body; `nearest-vertex` snaps to the target's points, which
// keeps a low-poly result on a low-poly target.

import { Vec3, VEC3_ZERO } from "../../../../base/vecmath";
import { Result, partialCmpF32 } from "../../../../base/util";
import { Mesh } from "../../mesh/mod";
import { ModifierEnv } from "../mod";
import { Scene, NO_OBJ } from "../../scene";
import { Bvh } from "./geom/bvh";
import { Tri } from "./geom/tri";
import { PropDef, PropKind, Props, prop } from "./props";
import { VERTEX_GROUP, INVERT_GROUP, weightField, weightAt } from "./common";

export const PROPS: Array<PropDef> = [
    prop(
        "target",
        PropKind.Name(),
        "none",
        "the mesh object to wrap onto",
    ),
    prop(
        "mode",
        PropKind.Choice(["nearest-surface-point", "project", "nearest-vertex"]),
        "nearest-surface-point",
        "how a vertex finds its place on the target",
    ),
    prop(
        "offset",
        PropKind.Float(),
        "0",
        "keep this distance above the surface, along its normal",
    ),
    prop(
        "axis",
        PropKind.Axes(),
        "none",
        "cast along these axes when projecting, or along the vertex normal when none is set",
    ),
    prop(
        "negative",
        PropKind.Bool(),
        "false",
        "when projecting, allow hits in the negative direction",
    ),
    prop(
        "positive",
        PropKind.Bool(),
        "true",
        "when projecting, allow hits in the positive direction",
    ),
    prop(
        "invert-face-cull",
        PropKind.Bool(),
        "false",
        "ignored when projecting, because both faces of the target are hit either way",
    ),
    VERTEX_GROUP,
    INVERT_GROUP,
];

// Where a vertex lands: the point and the surface
// normal there (ZERO when there is none).
export class Landed {
    point: Vec3;
    normal: Vec3;
    constructor(point: Vec3, normal: Vec3) {
        this.point = point;
        this.normal = normal;
    }
}

export function eval(mesh: Mesh, p: Props, env: ModifierEnv): Result<Array<string>> {
    const wf = weightField(mesh, p, env);
    const weights = wf.field;
    const invert = wf.invert;
    const warnings = weights.warnings.slice(0);
    const name = p.optStr("target");
    if (name == null) {
        return Result.fail<Array<string>>(
            "shrinkwrap needs a target (`modifier set <name> target <object>`)",
        );
    }
    const scene = env.scene;
    const ownerId = env.object;
    if (scene == null || ownerId == NO_OBJ) {
        return Result.fail<Array<string>>("shrinkwrap needs the scene (evaluated without context)");
    }
    const found = findTarget(scene, name, ownerId);
    if (!found.ok) return found.forward<Array<string>>();
    const targetId = found.value.id;
    const targetMesh = found.value.mesh;
    if (targetMesh.faces.isEmpty() && p.str("mode") != "nearest-vertex") {
        warnings.push("'" + name + "' has no faces; there is no surface to wrap onto");
        return Result.okv<Array<string>>(warnings);
    }

    // Both meshes are in their own object space; the target's geometry is
    // brought into this object's space once, rather than transforming every
    // query point back and forth.
    const toLocal = scene.worldMatrix(ownerId).inverse() * scene.worldMatrix(targetId);
    const index = targetMesh.verts.ids();
    const points: Array<Vec3> = [];
    for (let i = 0; i < index.length; i++) {
        points.push(toLocal.transformPoint3(targetMesh.verts.at(index[i]).co));
    }

    const tris: Array<Tri> = [];
    const fids = targetMesh.faces.ids();
    for (let i = 0; i < fids.length; i++) {
        const f = fids[i];
        const ts = targetMesh.triangulateFace(f);
        for (let j = 0; j < ts.length; j++) {
            const t = ts[j];
            const a = toLocal.transformPoint3(targetMesh.verts.at(targetMesh.loops.at(t[0]).vert).co);
            const b = toLocal.transformPoint3(targetMesh.verts.at(targetMesh.loops.at(t[1]).vert).co);
            const c = toLocal.transformPoint3(targetMesh.verts.at(targetMesh.loops.at(t[2]).vert).co);
            tris.push(Tri.new(a, b, c, f));
        }
    }
    const bvh = Bvh.build(tris);

    const offset = p.f32("offset");
    const mode = p.str("mode");
    const axes = p.axes("axis");
    const negative = p.bool("negative");
    const positive = p.bool("positive");
    if (p.bool("invert-face-cull")) {
        warnings.push("--invert-face-cull is ignored: projection hits the target from either side");
    }
    if (mode == "project" && !negative && !positive) {
        warnings.push(
            "projection has neither direction enabled, so nothing moves " +
                "(set --negative or --positive)",
        );
        return Result.okv<Array<string>>(warnings);
    }

    // Normals before anything moves, like every other deformer here.
    const ids = mesh.verts.ids();
    const normals: Array<Vec3> = [];
    for (let i = 0; i < ids.length; i++) normals.push(mesh.vertNormal(ids[i]));
    let missed = 0;
    for (let i = 0; i < ids.length; i++) {
        const v = ids[i];
        const normal = normals[i];
        const w = weightAt(weights, invert, v);
        if (w == <f32>0.0) continue;
        const co = mesh.verts.at(v).co;
        let landed: Landed? = null;
        if (mode == "nearest-vertex") {
            // Keeps the current best unless the next one is strictly
            // nearer; ties break on
            // the target's vertex id so the result does not depend on
            // iteration order.
            if (points.length > 0) {
                let best = 0;
                for (let k = 1; k < points.length; k++) {
                    const da = (points[best] - co).lengthSquared();
                    const db = (points[k] - co).lengthSquared();
                    let ord = partialCmpF32(da, db);
                    if (ord == 0) ord = index[best] < index[k] ? -1 : (index[best] > index[k] ? 1 : 0);
                    if (ord > 0) best = k;
                }
                landed = new Landed(points[best], VEC3_ZERO);
            }
        } else if (mode == "project") {
            landed = project(bvh, co, normal, axes, negative, positive);
        } else {
            const n = bvh.nearest(co);
            if (n != null) {
                const tri = bvh.tris()[n.tri];
                landed = new Landed(n.point, tri.normal().normalizeOrZero());
            }
        }
        if (landed == null) {
            missed += 1;
            continue;
        }
        const hit = landed as Landed;
        const point = hit.point;
        const surfaceNormal = hit.normal;
        // `offset` lifts off the surface along its normal; for a nearest-
        // vertex hit there is none, so it lifts along the way the vertex
        // came, which is what Blender does too.
        const lift = surfaceNormal == VEC3_ZERO ? (co - point).normalizeOrZero() : surfaceNormal;
        const target = point + lift * offset;
        mesh.verts.at(v).co = co.lerp(target, w);
    }
    if (missed > 0) {
        warnings.push(
            missed.toString() + " vertices found nothing to project onto and were left where they were",
        );
    }
    mesh.recalcNormals();
    mesh.touch();
    return Result.okv<Array<string>>(warnings);
}

// Cast along each enabled axis (or the vertex normal when none is) and
// keep the nearest hit.
export function project(
    bvh: Bvh,
    co: Vec3,
    normal: Vec3,
    axes: Array<bool>,
    negative: bool,
    positive: bool,
): Landed? {
    const dirs: Array<Vec3> = [];
    for (let i = 0; i < 3; i++) {
        if (axes[i]) {
            let d = VEC3_ZERO;
            d.set(i, 1.0);
            dirs.push(d);
        }
    }
    if (dirs.length == 0) {
        if (normal == VEC3_ZERO) return null;
        dirs.push(normal);
    }
    let have = false;
    let bestDist: f32 = 0.0;
    let bestPoint = VEC3_ZERO;
    let bestNormal = VEC3_ZERO;
    const signs: Array<f32> = [1.0, -1.0];
    for (let k = 0; k < dirs.length; k++) {
        const d = dirs[k];
        for (let s = 0; s < 2; s++) {
            const sign = signs[s];
            const enabled = s == 0 ? positive : negative;
            if (!enabled) continue;
            const hit = bvh.raycast(co, d * sign);
            if (hit == null) continue;
            const dist = hit.dist;
            if (!have || dist < bestDist) {
                const t = bvh.tris()[hit.tri];
                have = true;
                bestDist = dist;
                bestPoint = co + d * sign * dist;
                bestNormal = t.normal().normalizeOrZero();
            }
        }
    }
    return have ? new Landed(bestPoint, bestNormal) : null;
}

// The target object found by `findTarget`: its id and mesh.
export class TargetRef {
    id: u32;
    mesh: Mesh;
    constructor(id: u32, mesh: Mesh) {
        this.id = id;
        this.mesh = mesh;
    }
}

export function findTarget(scene: Scene, name: string, ownerId: u32): Result<TargetRef> {
    const ids = scene.objects.ids();
    for (let i = 0; i < ids.length; i++) {
        const id = ids[i];
        const obj = scene.objects.at(id);
        if (obj.name != name) continue;
        if (id == ownerId) {
            return Result.fail<TargetRef>("an object cannot shrinkwrap onto itself");
        }
        const mesh = obj.mesh();
        if (mesh == null) {
            return Result.fail<TargetRef>("'" + name + "' is a " + obj.typeName() + ", not a mesh");
        }
        return Result.okv<TargetRef>(new TargetRef(id, mesh));
    }
    return Result.fail<TargetRef>("no object named '" + name + "'");
}
