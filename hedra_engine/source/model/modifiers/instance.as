// The instance modifier, a copy of
// another object at every point of this one (PLAN §8/M9 stage 4, after
// Blender's Instance on Points node and its older dupliverts).
//
// **Instances are realized as they are evaluated.** The stack turns the
// points into real geometry every time it runs, and the scene file stores
// only the points and the modifier. They are *not* cheap at render time the
// way Blender's are: making them so means GPU instancing in the renderer and
// `EXT_mesh_gpu_instancing` on export, and PLAN §8 already chose to realize
// on export instead.
//
// The incoming geometry is replaced by the instances, as the node does. A
// cube with this modifier becomes eight copies of the target, not eight
// copies *and* a cube; put the modifier on a point cloud (`distribute on
// faces`) when that is what you meant.

import { Result } from "../../../base/util";
import { debugStruct, debugSome, debugStr, debugF32, DEBUG_NONE } from "../../../base/fmt";
import { Vec3, Quat, Mat4, EulerRot, QUAT_IDENTITY, VEC3_Z, VEC3_ONE, MAT4_IDENTITY, toRadians } from "../../../base/vecmath";
import { Mesh, ElemKind } from "../mesh/mod";
import { AttrValueKind } from "../mesh/attr";
import { pointsOf } from "../ops/distribute";
import { NO_OBJ } from "../armature/pose";
import { Scene } from "../scene";
import { evaluate, EvaluatedStack, ModifierEnv, assignMesh } from "./mod";

// How far a chain of instancing may go before it is refused. A cycle (A
// instances B instances A) would otherwise not terminate; a legitimate
// chain this deep is already a mistake.
export const MAX_DEPTH: u8 = 4;

// The instance modifier's settings.
export class InstanceOpts {
    // NO_OBJ = none.
    object: u32 = NO_OBJ;
    // Uniform scale applied to every copy.
    scale: f32 = 1;
    // A named attribute multiplying that scale, per point. A vector one
    // scales the axes separately.
    scaleAttr: string? = null;
    // Stand each copy up on the point's `surface_normal`, so a thing
    // scattered over a curved surface follows it.
    align: bool = false;
    // Euler XYZ radians, applied after the alignment.
    rotation: Vec3 = Vec3(0, 0, 0);
    // A named point attribute turning each copy on its own, Euler XYZ in
    // *degrees* (the spelling every rotation takes at the command
    // boundary), applied after `rotation`.
    rotationAttr: string? = null;

    constructor(object: u32, scale: f32, scaleAttr: string?, align: bool, rotation: Vec3, rotationAttr: string?) {
        this.object = object;
        this.scale = scale;
        this.scaleAttr = scaleAttr;
        this.align = align;
        this.rotation = rotation;
        this.rotationAttr = rotationAttr;
    }

    clone(): InstanceOpts {
        return new InstanceOpts(this.object, this.scale, this.scaleAttr, this.align, this.rotation, this.rotationAttr);
    }

    // Debug text, field by field.
    debug(): string {
        const sa = this.scaleAttr;
        const ra = this.rotationAttr;
        return debugStruct(
            "InstanceOpts",
            ["object", "scale", "scale_attr", "align", "rotation", "rotation_attr"],
            [
                this.object == NO_OBJ ? DEBUG_NONE : debugSome(this.object.toString()),
                debugF32(this.scale),
                sa != null ? debugSome(debugStr(sa)) : DEBUG_NONE,
                this.align ? "true" : "false",
                this.rotation.debug(),
                ra != null ? debugSome(debugStr(ra)) : DEBUG_NONE,
            ],
        );
    }
}

// Where one copy goes, in the instancing object's local space (a value).
export struct Placement {
    translation: Vec3 = Vec3(0, 0, 0);
    rotation: Quat = Quat(0, 0, 0, 1);
    scale: Vec3 = Vec3(1, 1, 1);

    constructor(translation: Vec3, rotation: Quat, scale: Vec3) {
        this.translation = translation;
        this.rotation = rotation;
        this.scale = scale;
    }

    operator==(a: Placement, b: Placement): bool {
        return a.translation == b.translation && a.rotation == b.rotation && a.scale == b.scale;
    }
    readonly hash(): u32 {
        return this.translation.hash() * 31 ^ this.rotation.hash() * 17 ^ this.scale.hash();
    }

    readonly matrix(): Mat4 {
        return Mat4.fromScaleRotationTranslation(this.scale, this.rotation, this.translation);
    }

    readonly debug(): string {
        return debugStruct(
            "Placement",
            ["translation", "rotation", "scale"],
            [this.translation.debug(), this.rotation.debug(), this.scale.debug()],
        );
    }
}

// The placements and the warnings.
export class Placements {
    placements: Array<Placement> = [];
    warnings: Array<string> = [];
}

// The named point attribute as a Vec3 (a number
// splatted), or `fallback` when there is no name or no value.
function perPoint(mesh: Mesh, name: string?, id: u32, fallback: Vec3): Vec3 {
    if (name == null) return fallback;
    const v = mesh.attrValue(name, ElemKind.Vert, id);
    if (v == null) return fallback;
    if (v.kind == AttrValueKind.Vec3) return v.v;
    return Vec3.splat(<f32>v.n);
}

// Where every copy goes, one per point of `mesh`, in id order.
//
// Split out of `instance` because the glTF exporter needs the same answer:
// `EXT_mesh_gpu_instancing` is a list of exactly these, so writing it must
// not be a second implementation of where the copies are.
export function placements(mesh: Mesh, opts: InstanceOpts): Placements {
    const res = new Placements();
    const warnings = res.warnings;
    for (let k = 0; k < 2; k++) {
        const what = k == 0 ? "scale 1" : "no turn";
        const name = k == 0 ? opts.scaleAttr : opts.rotationAttr;
        if (name != null && mesh.attr(name) == null) {
            warnings.push("no attribute '" + name + "' on the points; every copy gets " + what);
        }
    }
    const extra = Quat.fromEuler(EulerRot.XYZ, opts.rotation.x, opts.rotation.y, opts.rotation.z);
    const points = pointsOf(mesh);
    for (let i = 0; i < points.length; i++) {
        const pt = points[i];
        const align = opts.align ? Quat.fromRotationArc(VEC3_Z, pt.normal) : QUAT_IDENTITY;
        // Alignment first, then the modifier's own turn, then the point's:
        // the per-point one is the most specific, so it is applied last and
        // reads as a nudge on top of the other two.
        const turn = perPoint(mesh, opts.rotationAttr, pt.id, Vec3(0, 0, 0));
        const own = Quat.fromEuler(EulerRot.XYZ, toRadians(turn.x), toRadians(turn.y), toRadians(turn.z));
        res.placements.push(Placement(
            pt.co,
            align * extra * own,
            perPoint(mesh, opts.scaleAttr, pt.id, VEC3_ONE) * opts.scale,
        ));
    }
    return res;
}

// The geometry each copy is of: `target`'s own stack evaluated, brought
// into the instancing object's local space (`owner` NO_OBJ = none). Split
// out for the same reason `placements` is. Ok holds the mesh and its warnings.
export function prototype(scene: Scene, owner: u32, target: u32, depth: u8): Result<EvaluatedStack> {
    // Never true without an owner, even for a target id equal to the NO_OBJ
    // sentinel.
    if (owner != NO_OBJ && target == owner) {
        return Result.fail<EvaluatedStack>("an object cannot instance itself");
    }
    if (depth >= MAX_DEPTH) {
        return Result.fail<EvaluatedStack>(
            "instancing is more than " + MAX_DEPTH.toString() + " deep; a cycle of objects instancing each other has no end",
        );
    }
    const obj = scene.objects.get(target);
    if (obj == null) {
        return Result.fail<EvaluatedStack>("the object to instance is gone");
    }
    const base = obj.mesh();
    if (base == null) {
        return Result.fail<EvaluatedStack>("'" + obj.name + "' is not a mesh");
    }
    // The target's own stack runs first, at one more level of depth, so
    // instancing a greebled panel instances the greebles too.
    const env = new ModifierEnv(scene, target, depth + 1);
    const ev = evaluate(base, obj.modifiers, env);
    const source = ev.mesh;
    if (source.verts.isEmpty()) {
        return Result.fail<EvaluatedStack>("'" + obj.name + "' has no geometry to instance");
    }
    // Copies arrive in the instancing object's local space.
    const toLocal: Mat4 = owner != NO_OBJ
        ? scene.worldMatrix(owner).inverse() * scene.worldMatrix(target)
        : scene.worldMatrix(target);
    if (!(toLocal == MAT4_IDENTITY)) {
        source.transform(toLocal);
    }
    return Result.okv<EvaluatedStack>(new EvaluatedStack(source, ev.warnings));
}

// Replace `mesh`'s points with copies of `opts.object`'s evaluated geometry
// (in place: `mesh` is replaced wholesale). Returns the warnings the stack should

// report.
export function instance(mesh: Mesh, scene: Scene?, owner: u32, depth: u8, opts: InstanceOpts): Result<Array<string>> {
    const target = opts.object;
    if (target == NO_OBJ) {
        return Result.fail<Array<string>>("no object to instance (`modifier set <name> object <object>`)");
    }
    if (scene == null) {
        return Result.fail<Array<string>>("instancing needs the scene, and this mesh was evaluated without it");
    }
    const pr = prototype(scene, owner, target, depth);
    if (!pr.ok) return pr.forward<Array<string>>();
    const source = pr.value.mesh;
    const warnings = pr.value.warnings;
    const pl = placements(mesh, opts);
    for (let i = 0; i < pl.warnings.length; i++) warnings.push(pl.warnings[i]);

    const out = new Mesh();
    // The points' own attributes go no further: they described where to put
    // a copy, and the copy carries the target's attributes instead.
    const ps = pl.placements;
    for (let i = 0; i < ps.length; i++) {
        const copy = source.clone();
        copy.transform(ps[i].matrix());
        out.append(copy, 0);
    }
    if (ps.length == 0) {
        warnings.push("the geometry has no points to instance on");
    }
    assignMesh(mesh, out);
    mesh.recalcNormals();
    return Result.okv<Array<string>>(warnings);
}
