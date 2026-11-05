// Modifier stack evaluation (PLAN §4 Object
// mode > Modifiers, §5 Catmull-Clark). `Object.evaluatedMesh` runs the
// enabled modifiers in order on a copy of the base mesh; the renderer draws
// the result and the glTF exporter writes it when `--apply-modifiers` is on.
//
// Each modifier lives in its own file and works on the whole mesh in place.
// Evaluation is deterministic (element ids are allocated in id order) and
// the evaluated mesh carries no selection state of its own: it is derived
// data, never edited directly.
//
// Notes:
//   * To replace the caller's mesh wholesale, `assignMesh(mesh, work)`
//     moves every field of `work` into `mesh`, so the caller's reference
//     sees the new geometry. `work` must not be used afterwards (the two
//     share storage).
//   * A stack result is `EvaluatedStack { mesh, warnings }`.
//   * The install-once hooks (`ToolEvaluator`, `ExtModifiers`) are abstract
//     classes plus module-level globals; a second install is ignored.

import { Result, fnv1a64 } from "../../../base/util";
import { debugList } from "../../../base/fmt";
import { Mat4 } from "../../../base/vecmath";
import { Mesh } from "../mesh/mod";
import { NO_OBJ } from "../armature/pose";
import { flipSideName } from "../armature/names";
import {
    Scene, Object, Modifier, CowMesh, NO_VGROUP, ModifierKindTag, ModifierKindMirror, ModifierKindSubsurf,
    ModifierKindArray, ModifierKindSolidify, ModifierKindBevel, ModifierKindWeld, ModifierKindEdgeSplit,
    ModifierKindArmature, ModifierKindInstance, ModifierKindTool, ModifierKindExt,
} from "../scene";
import { mirror } from "./mirror";
import { subdivide } from "./subsurf";
import { array } from "./array";
import { solidify } from "./solidify";
import { bevel } from "./bevel";
import { triangulate } from "./triangulate";
import { weld } from "./weld";
import { edgeSplit } from "./edge_split";
import { skinBones, deform } from "./armature";
import { InstanceOpts, instance } from "./instance";

// Moves every field of `src` into `dst`, so everything
// holding `dst` sees the new mesh. `src` shares its storage with `dst`
// afterwards and must be dropped by the caller.
export function assignMesh(dst: Mesh, src: Mesh): void {
    if (dst == src) return; // identity (Mesh has no == operator)
    dst.verts = src.verts;
    dst.edges = src.edges;
    dst.faces = src.faces;
    dst.loops = src.loops;
    dst.uvLayers = src.uvLayers;
    dst.activeUv = src.activeUv;
    dst.selectionHistory = src.selectionHistory;
    dst.savedSelections = src.savedSelections;
    dst.shapeKeys = src.shapeKeys;
    dst.activeShapeKey = src.activeShapeKey;
    dst.attributes = src.attributes;
    dst.edgeLookup = src.edgeLookup;
    dst.vertEdgesMap = src.vertEdgesMap;
    dst.edgeFacesMap = src.edgeFacesMap;
    dst.revision = src.revision;
}

// The mesh and the warnings: what `evaluate` and a tool evaluator hand back.
export class EvaluatedStack {
    mesh: Mesh;
    warnings: Array<string>;
    constructor(mesh: Mesh, warnings: Array<string>) {
        this.mesh = mesh;
        this.warnings = warnings;
    }
}

// What a tool modifier is asked to do: run `tool` with `params` over `mesh`,
// which is the stack's state so far, and hand back what it made.
export class ToolRequest {
    tool: string;
    // Iterate with sortedKeys (shared/src/model/scene).
    params: Map<string, string>;
    // The tool file's content hash recorded when the modifier was added; the
    // evaluator warns when the file has changed since.
    hash: u64;
    mesh: Mesh;
    // The scene and object the stack belongs to, so the tool body sees the
    // object's vertex groups, material slots and the scene's materials.
    scene: Scene?;
    // NO_OBJ = none.
    object: u32;

    constructor(tool: string, params: Map<string, string>, hash: u64, mesh: Mesh, scene: Scene?, object: u32) {
        this.tool = tool;
        this.params = params;
        this.hash = hash;
        this.mesh = mesh;
        this.scene = scene;
        this.object = object;
    }
}

// Running a tool needs the command layer (the tokenizer, the registry and
// the parsed-command dispatcher), and that lives above shared/src/model, in
// engine/src/commands. So the binary installs an implementation at startup, and a build that has none (a
// library user, a test) skips tool modifiers with a warning, exactly as an
// armature modifier is skipped without a scene.
export abstract class ToolEvaluator {
    // The evaluated mesh, plus anything worth telling the caller (a tool file
    // that has changed since the modifier was added, geometry the body made
    // and could not keep). The request's mesh must not be changed.
    abstract evaluate(req: ToolRequest): Result<EvaluatedStack>;
}

let EVALUATOR: ToolEvaluator? = null;

// The modifiers implemented outside shared/src/model (in engine/src/commands/blender), behind one
// interface. Every method takes the type name (`ModifierKindExt.kind`) so
// one implementation can own a whole family.
export abstract class ExtModifiers {
    // Type names accepted by `modifier add`, in the order `help` lists them.
    abstract types(): Array<string>;
    // Blender's name for the type (`Boolean`), used to name a new modifier;
    // null for a type this extension does not own.
    abstract displayName(kind: string): string?;
    // Every property of the type at its Blender default (iterate with
    // sortedKeys); null for a type this extension does not own.
    abstract defaults(kind: string): Map<string, string>?;
    // The property names of the type, in display order.
    abstract propNames(kind: string): Array<string>;
    // Check `value` for `prop` and hand back the text to store, which may be
    // normalized, so what the scene holds is always something `evaluate`
    // accepts.
    abstract validate(kind: string, prop: string, value: string): Result<string>;
    // Run the modifier over `mesh` in place (use `assignMesh` to replace it
    // wholesale). Ok carries warnings.
    abstract evaluate(kind: string, props: Map<string, string>, mesh: Mesh, env: ModifierEnv): Result<Array<string>>;
}

let EXT: ExtModifiers? = null;

// Install the process's modifier extension. Call once, from main, before
// anything evaluates a stack; a second call is ignored.
export function installExtModifiers(ext: ExtModifiers): void {
    if (EXT == null) EXT = ext;
}

export function extModifiers(): ExtModifiers? {
    return EXT;
}

// The extension's own name for a stored type name; "ext" when no extension
// is installed or the type is not one it owns (a display fallback only).
export function extTypeName(kind: string): string {
    const e = EXT;
    if (e != null) {
        const ts = e.types();
        for (let i = 0; i < ts.length; i++) if (ts[i] == kind) return ts[i];
    }
    return "ext";
}

// Install the process's tool evaluator. Call once, before anything evaluates
// a modifier stack; a second call is ignored.
export function installToolEvaluator(evaluator: ToolEvaluator): void {
    if (EVALUATOR == null) EVALUATOR = evaluator;
}

export function toolEvaluator(): ToolEvaluator? {
    return EVALUATOR;
}

// Test support (the hooks install once otherwise): put back the evaluator
// and extension a suite found installed (or none), so a
// suite that installs its own does not leak it into the suites that run
// after it in the same process.
export function restoreHooksForTests(evaluator: ToolEvaluator?, ext: ExtModifiers?): void {
    EVALUATOR = evaluator;
    EXT = ext;
}

// What a modifier may read besides its mesh: the scene (armature poses) and
// the object owning the stack (vertex group names). Both optional so a bare
// mesh can still be evaluated. `new ModifierEnv()` has neither.
export class ModifierEnv {
    scene: Scene? = null;
    // NO_OBJ = none.
    object: u32 = NO_OBJ;
    // How many instance modifiers deep this evaluation already is. An object
    // instancing another that instances the first would otherwise not
    // terminate; see instance MAX_DEPTH.
    depth: u8 = 0;

    constructor(scene: Scene? = null, object: u32 = NO_OBJ, depth: u8 = 0) {
        this.scene = scene;
        this.object = object;
        this.depth = depth;
    }

    // The owning object, when both the scene and the id are known.
    ownerObject(): Object? {
        const s = this.scene;
        if (s == null || this.object == NO_OBJ) return null;
        return s.objects.get(this.object);
    }
}

function named(modifier: Modifier, m: string): string {
    return "modifier '" + modifier.name + "': " + m;
}

// Run one modifier on `mesh` in place. Ok carries non-fatal warnings (the
// stack keeps going); Err is a message the caller reports as a warning too,
// and the mesh is left as it was before this modifier.
export function apply(modifier: Modifier, mesh: Mesh, env: ModifierEnv): Result<Array<string>> {
    let work = mesh.clone();
    let warnings: Array<string> = [];
    const kind = modifier.kind;
    switch (kind.tag) {
        case ModifierKindTag.Mirror: {
            const k = kind as ModifierKindMirror;
            // Blender's "Mirror Vertex Groups": `.L` groups become `.R` on the
            // copy and vice versa.
            const flip: Array<u32> = [];
            const o = env.ownerObject();
            if (o != null) {
                for (let i = 0; i < o.vertexGroups.length; i++) {
                    const other = flipSideName(o.vertexGroups[i].name);
                    const idx = o.vgroupIndex(other);
                    flip.push(idx == NO_VGROUP ? <u32>i : idx);
                }
            }
            mirror(work, k.axis, k.clipping, k.merge, k.mergeThreshold, flip);
            break;
        }
        case ModifierKindTag.Subsurf: {
            subdivide(work, (kind as ModifierKindSubsurf).levels);
            break;
        }
        case ModifierKindTag.Array: {
            const k = kind as ModifierKindArray;
            array(work, k.count, k.relativeOffset, k.constantOffset, k.merge, k.mergeThreshold);
            break;
        }
        case ModifierKindTag.Solidify: {
            const k = kind as ModifierKindSolidify;
            solidify(work, k.thickness, k.offset, k.even);
            break;
        }
        case ModifierKindTag.Bevel: {
            const k = kind as ModifierKindBevel;
            const r = bevel(work, k.width, k.segments, k.angleLimit);
            if (!r.ok) return Result.fail<Array<string>>(named(modifier, r.err));
            warnings = r.value;
            break;
        }
        case ModifierKindTag.Triangulate: {
            triangulate(work);
            break;
        }
        case ModifierKindTag.Weld: {
            weld(work, (kind as ModifierKindWeld).distance);
            break;
        }
        case ModifierKindTag.EdgeSplit: {
            edgeSplit(work, (kind as ModifierKindEdgeSplit).angle);
            break;
        }
        case ModifierKindTag.Armature: {
            const r = armatureDeform(modifier, kind as ModifierKindArmature, work, env);
            if (!r.ok) return r;
            warnings = r.value;
            break;
        }
        case ModifierKindTag.Instance: {
            const k = kind as ModifierKindInstance;
            const opts = new InstanceOpts(k.object, k.scale, k.scaleAttr, k.align, k.rotation, k.rotationAttr);
            const r = instance(work, env.scene, env.object, env.depth, opts);
            if (!r.ok) return Result.fail<Array<string>>(named(modifier, r.err));
            warnings = r.value;
            break;
        }
        case ModifierKindTag.Tool: {
            // `evaluate` turns an Err here into a warning and carries on with
            // the mesh as it was, so a project whose tool directory is missing
            // still opens, renders and exports, without the tool's
            // contribution, and saying so.
            const k = kind as ModifierKindTool;
            const evaluator = EVALUATOR;
            if (evaluator == null) {
                return Result.fail<Array<string>>(
                    named(modifier, "tool '" + k.tool + "' was skipped: this build has no tool evaluator"),
                );
            }
            const r = evaluator.evaluate(new ToolRequest(k.tool, k.params, k.hash, work, env.scene, env.object));
            if (!r.ok) return Result.fail<Array<string>>(named(modifier, r.err));
            work = r.value.mesh;
            warnings = r.value.warnings;
            break;
        }
        default: {
            // Ext. Like a tool modifier, a missing extension is a warning and
            // not a failure: the project still opens, renders and exports,
            // and says which modifier it left out.
            const k = kind as ModifierKindExt;
            const ext = EXT;
            if (ext == null) {
                return Result.fail<Array<string>>(
                    named(modifier, "'" + k.kind + "' was skipped: this build has no modifier extension installed"),
                );
            }
            const r = ext.evaluate(k.kind, k.props, work, env);
            if (!r.ok) return Result.fail<Array<string>>(named(modifier, r.err));
            warnings = r.value;
            break;
        }
    }
    assignMesh(mesh, work);
    const out: Array<string> = [];
    for (let i = 0; i < warnings.length; i++) out.push(named(modifier, warnings[i]));
    return Result.okv<Array<string>>(out);
}

// The Armature modifier on `mesh`, in place. Everything that can fail is
// checked before the first vertex moves, so an Err leaves `mesh` as it was
// (what `apply` promises) and the stack needs no copy for it. Ok carries
// the pose's warnings, not yet named.
function armatureDeform(modifier: Modifier, k: ModifierKindArmature, mesh: Mesh, env: ModifierEnv): Result<Array<string>> {
    const armId = k.object;
    if (armId == NO_OBJ) {
        return Result.fail<Array<string>>(
            "modifier '" + modifier.name + "': no armature object set (`modifier set " + modifier.name + " object <name>`)",
        );
    }
    const scene = env.scene;
    const owner = env.object;
    if (scene == null || owner == NO_OBJ) {
        return Result.fail<Array<string>>(named(modifier, "armature deform needs the scene (evaluated without context)"));
    }
    const armObj = scene.objects.get(armId);
    const arm = armObj == null ? null : armObj.armature();
    if (arm == null) {
        return Result.fail<Array<string>>(named(modifier, "its armature object no longer exists"));
    }
    const ev = scene.poseEval(armId);
    if (ev == null) {
        return Result.fail<Array<string>>(named(modifier, "pose evaluation failed"));
    }
    const bones = skinBones(arm, ev, scene.objects.at(owner).vertexGroups);
    const toArm: Mat4 = scene.worldMatrix(armId).inverse() * scene.worldMatrix(owner);
    deform(mesh, bones, toArm, k.useVertexGroups, k.useEnvelopes, k.preserveVolume);
    return Result.okv<Array<string>>(ev.warnings.slice(0));
}

// One enabled modifier of a stack being evaluated on `mesh` (the stack's own
// copy): `apply`, except that an Armature modifier deforms `mesh` in place
// instead of a copy of it (the same result: its Err leaves `mesh` as it was).
// Its warnings, or its error, go to `warnings`.
function applyToStack(m: Modifier, mesh: Mesh, env: ModifierEnv, warnings: Array<string>): void {
    let r: Result<Array<string>>;
    if (m.kind.tag == ModifierKindTag.Armature) {
        r = armatureDeform(m, m.kind as ModifierKindArmature, mesh, env);
        if (r.ok) {
            const w = r.value;
            for (let j = 0; j < w.length; j++) warnings.push(named(m, w[j]));
            return;
        }
    } else {
        r = apply(m, mesh, env);
        if (r.ok) {
            const w = r.value;
            for (let j = 0; j < w.length; j++) warnings.push(w[j]);
            return;
        }
    }
    warnings.push(r.err);
}

// The whole stack on a copy of `base`. Disabled modifiers are skipped; a
// failing modifier is reported and skipped.
export function evaluate(base: Mesh, stack: Array<Modifier>, env: ModifierEnv): EvaluatedStack {
    const mesh = base.clone();
    const warnings: Array<string> = [];
    for (let i = 0; i < stack.length; i++) {
        const m = stack[i];
        if (!m.enabled) continue;
        applyToStack(m, mesh, env, warnings);
    }
    mesh.touch();
    return new EvaluatedStack(mesh, warnings);
}

// True when the stack only moves vertices: at least one modifier is enabled
// and every enabled one is an Armature. Its result has the base mesh's
// elements, ids and attributes; only vertex positions and face normals
// differ, so `reevaluateDeform` can redo it in place.
export function stackIsDeformOnly(stack: Array<Modifier>): bool {
    let any = false;
    for (let i = 0; i < stack.length; i++) {
        const m = stack[i];
        if (!m.enabled) continue;
        if (m.kind.tag != ModifierKindTag.Armature) return false;
        any = true;
    }
    return any;
}

// `evaluate(base, stack, env)` into `mesh`, a result of that same call for an
// earlier pose (the base unchanged since, the stack deform-only): the vertex
// positions and face normals go back to the base's, then the stack deforms
// them again. The outcome equals a fresh `evaluate`, but nothing the size of
// the mesh is allocated: a skinned mesh re-evaluated for every frame of an
// animation stays in the same memory.
export function reevaluateDeform(mesh: Mesh, base: Mesh, stack: Array<Modifier>, env: ModifierEnv): Array<string> {
    const vb = base.verts.idBound();
    for (let id: u32 = 0; id < vb; id++) {
        const v = base.verts.get(id);
        if (v != null) mesh.verts.at(id).co = v.co;
    }
    const fb = base.faces.idBound();
    for (let id: u32 = 0; id < fb; id++) {
        const f = base.faces.get(id);
        if (f != null) mesh.faces.at(id).normal = f.normal;
    }
    const warnings: Array<string> = [];
    for (let i = 0; i < stack.length; i++) {
        const m = stack[i];
        if (!m.enabled) continue;
        applyToStack(m, mesh, env, warnings);
    }
    mesh.touch();
    return warnings;
}

// ------------------------------------------------------------ Object methods
// Object's `evaluatedMesh` / `hasActiveModifiers` / `modifierFingerprint`
// (engine/src/source/model/scene.as) delegate here.

// Object::evaluated_mesh: the mesh after its modifier stack, or the base mesh
// itself (borrowed) when nothing would run; null for non-mesh objects.
// Evaluated without scene context: an armature modifier is skipped with a
// warning; prefer Scene.evaluatedMesh.
export function objectEvaluatedMesh(obj: Object): CowMesh? {
    const base = obj.mesh();
    if (base == null) return null;
    if (!objectHasActiveModifiers(obj)) return CowMesh.borrowed(base);
    return CowMesh.ownedOf(evaluate(base, obj.modifiers, new ModifierEnv()).mesh);
}

// Object::has_active_modifiers: true when at least one enabled modifier
// would run.
export function objectHasActiveModifiers(obj: Object): bool {
    for (let i = 0; i < obj.modifiers.length; i++) if (obj.modifiers[i].enabled) return true;
    return false;
}

// A stable fingerprint of the stack, for render caches keyed on (mesh
// revision, stack); 0 when nothing would run. An in-process cache key only:
// FNV-1a of the stack's debug text.

export function objectModifierFingerprint(obj: Object): u64 {
    if (!objectHasActiveModifiers(obj)) return 0;
    const parts: Array<string> = [];
    for (let i = 0; i < obj.modifiers.length; i++) parts.push(obj.modifiers[i].debug());
    const h = fnv1a64(debugList(parts));
    return h > 1 ? h : 1;
}
