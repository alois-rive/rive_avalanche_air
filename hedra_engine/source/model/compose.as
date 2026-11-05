// A model with the files it names put in: what is drawn, exported and
// placed in a scene of a model whose materials are MaterialX files or
// whose empties instance other models (Material.file, Empty.instance in
// scene.as). The model itself holds only the names of those files, as an
// .rscn holds an ext_resource; this builds, from the model and the files,
// the scene the renderer, the glTF export and the scene loader take:
//
// - an empty's instance: the instanced model's objects (its own instances
//   put in first, to a depth of INSTANCE_DEPTH_MAX) appended to the scene,
//   its top-level objects parented to the empty, as Blender draws a
//   collection instance and Godot places an instanced scene's nodes under
//   the instancing node. Its materials and actions are appended too, the
//   object, material and action ids it holds renumbered, and every file
//   path it holds made absolute (a model names its files relative to
//   itself). The appended objects are selected and hidden when the empty
//   is (Blender outlines a selected instance's objects), never otherwise;
// - a material's file (with `materials`): the material read from it, as
//   the model's Material (../material/model_pbr.as modelMaterialFromPbr),
//   in its place. The scene loader keeps the file instead and builds the
//   whole material from it (../scene/resource/model.as), as an .rscn's
//   Material ext_resource is built.
//
// A file that cannot be had is a warning, and what named it is drawn
// without it: an empty as an empty, a material with its own settings, as
// a missing texture is drawn without its image. So is an instance cycle (a
// model that instances itself, directly or through others: the instance
// that closes it is left out) and an instance deeper than
// INSTANCE_DEPTH_MAX.
//
// A model that names no such file is given back as it is (Composed.same),
// so that nothing changes, nothing is copied and nothing is read for one.
//
// What the appended objects share with the instanced model: their meshes
// (read only: nothing here or in the renderer writes a base mesh), so a
// large instanced model costs its objects, not its geometry, each time
// it is put in.

import { Result } from "../../base/util";
import { SlotVec } from "../../base/slot";
import { MAT4_IDENTITY } from "../../base/vecmath";
import { isAbsolute, normalizeAbs, parent } from "../../fs/path";
import { PbrMaterial } from "../../material/pbr";
import { besideFile, modelMaterialFromPbr } from "../material/model_pbr";
import { Action, AnimData, ACTION_NONE } from "./anim/mod";
import { ConstraintKindIk, ConstraintKindTag } from "./armature/constraints";
import {
    Material, ModifierKindArmature, ModifierKindInstance, ModifierKindTag, NO_OBJ, Object, ObjectData, ObjectDataKind,
    Parent, Scene,
} from "./scene";

// How deep instances go (a model instancing one that instances one ...):
// Godot has no limit but the cycle check; one here keeps a chain of
// distinct files from building a scene without end.
export const INSTANCE_DEPTH_MAX: i32 = 16;

// A model file read for an instance: its scene, and for a glTF file the
// materials whole as its import reads them (aligned with scene.materials;
// null for a model file, whose Material is all it has).
export class ModelSource {
    scene: Scene;
    pbr: Array<PbrMaterial>?;

    constructor(scene: Scene, pbr: Array<PbrMaterial>? = null) {
        this.scene = scene;
        this.pbr = pbr;
    }
}

// What composing reads, by absolute path: a model file as a scene (an
// .rmdl read, an .rmdlcmd loaded, a glTF file imported), a MaterialX file
// as a material. The source tier's FileModelFiles (../scene/resource/
// model.as) reads them through the vfs; the result must not be changed by
// the caller (a reader may give the same scene twice).
export abstract class ModelFiles {
    abstract model(abs: string): Result<ModelSource>;
    abstract material(abs: string): Result<PbrMaterial>;
}

// The scene with its files put in.
export class Composed {
    scene: Scene;
    // The model's own slots: the objects with a smaller id are the model's
    // own (the same Object instances), the others an instance's.
    own: u32;
    // For each appended object (id - own), the model's own empty whose
    // instance it is part of (what a click on it selects).
    owners: Array<u32> = [];
    // Aligned with scene.materials: the material whole where a file gave
    // it (an instanced glTF file's, as its import read it), else null.
    pbr: Array<PbrMaterial?> = [];
    warnings: Array<string> = [];
    // The files read, absolute, in the order they were first read: what
    // a watcher of the model watches besides it.
    files: Array<string> = [];

    constructor(scene: Scene, own: u32) {
        this.scene = scene;
        this.own = own;
    }

    // Nothing was put in: `scene` is the model's own scene.
    get same(): bool {
        return this.owners.length == 0 && this.files.length == 0;
    }

    // The model's own object a drawn object stands for: itself, or the
    // empty that instances it.
    ownerOf(id: u32): u32 {
        if (id < this.own) return id;
        const k = <i32>(id - this.own);
        return k < this.owners.length ? this.owners[k] : NO_OBJ;
    }
}

// Whether a model names a file this module puts in: a material's
// MaterialX file, an empty's instanced model.
// It allocates nothing (the model editor asks it of every full plan).
export function namesFiles(scene: Scene, materials: bool = true): bool {
    if (scene.composed) return false;
    if (materials) {
        for (let i = 0; i < scene.materials.length; i++) if (scene.materials[i].file != null) return true;
    }
    const bound = scene.objects.idBound();
    for (let id: u32 = 0; id < bound; id++) {
        const o = scene.objects.get(id);
        if (o != null && o.data.kind == ObjectDataKind.Empty && o.data.emptyData!.instance != null) return true;
    }
    return false;
}

// The slots of the empties that instance a model, in id order.
export function instancingEmpties(scene: Scene): Array<u32> {
    const out = new Array<u32>();
    const bound = scene.objects.idBound();
    for (let id: u32 = 0; id < bound; id++) {
        const o = scene.objects.get(id);
        if (o == null || o.data.kind != ObjectDataKind.Empty) continue;
        if (o.data.emptyData!.instance != null) out.push(id);
    }
    return out;
}

// A path a model at `dir` names, absolute.
export function modelPath(dir: string, path: string): string {
    return isAbsolute(path) ? normalizeAbs(path) : normalizeAbs(dir + "/" + path);
}

function dirOf(abs: string): string {
    const p = parent(abs);
    return p != null && p.length > 0 ? p : "/";
}

// The scene of `scene`, a model at the absolute directory `dir`, with its
// instances put in and, with `materials`, its MaterialX materials read in
// their place (the header). `files` reads them. `path` is the model's own
// file (absolute; "" for a model of no file), so that an empty instancing
// it is the cycle it is.
export function composeScene(scene: Scene, dir: string, files: ModelFiles, materials: bool = true, path: string = ""): Composed {
    const own = scene.objects.idBound();
    if (!namesFiles(scene, materials)) {
        const c = new Composed(scene, own);
        for (let i = 0; i < scene.materials.length; i++) c.pbr.push(null);
        return c;
    }
    const chain = new Array<string>();
    if (path.length > 0) chain.push(normalizeAbs(path));
    return composeAt(scene, dir, files, materials, chain);
}

function composeAt(scene: Scene, dir: string, files: ModelFiles, materials: bool, chain: Array<string>): Composed {
    const own = scene.objects.idBound();
    const out = shallowScene(scene);
    out.composed = true;
    const c = new Composed(out, own);
    // The materials: the model's own, or what their files hold.
    for (let i = 0; i < scene.materials.length; i++) {
        const m = scene.materials[i];
        const f = m.file;
        if (!materials || f == null) {
            out.materials.push(m);
            c.pbr.push(null);
            continue;
        }
        const abs = modelPath(dir, f);
        note(c, abs);
        const r = files.material(abs);
        if (!r.ok) {
            c.warnings.push("material '" + m.name + "': cannot read its MaterialX file " + f + " (" + r.err + "); it is drawn with "
                + "its own settings");
            out.materials.push(m);
            c.pbr.push(null);
            continue;
        }
        out.materials.push(modelMaterialFromPbr(r.value, m.name, dirOf(abs)));
        c.pbr.push(r.value);
    }
    const empties = instancingEmpties(scene);
    for (let k = 0; k < empties.length; k++) {
        const id = empties[k];
        const o = scene.objects.at(id);
        const path = o.data.emptyData!.instance!;
        const abs = modelPath(dir, path);
        if (chain.includes(abs) || chain.length >= INSTANCE_DEPTH_MAX) {
            const why = chain.includes(abs) ? "instance cycle: " + cycleText(chain, abs) : "instances go no deeper than "
                + INSTANCE_DEPTH_MAX.toString() + " models";
            c.warnings.push("empty '" + o.name + "': " + why + "; the instance is left out");
            continue;
        }
        note(c, abs);
        const src = files.model(abs);
        if (!src.ok) {
            c.warnings.push("empty '" + o.name + "': cannot instance " + path + " (" + src.err + "); it is drawn as an empty");
            continue;
        }
        // The instanced model with its own files put in first.
        chain.push(abs);
        const inner = composeAt(src.value.scene, dirOf(abs), files, materials, chain);
        chain.pop();
        for (let w = 0; w < inner.warnings.length; w++) c.warnings.push(path + ": " + inner.warnings[w]);
        for (let w = 0; w < inner.files.length; w++) note(c, inner.files[w]);
        // A glTF file's materials whole (its own come first in `inner`, in
        // their order; a glTF material is never a file).
        const pbr = src.value.pbr;
        if (pbr != null) {
            for (let i = 0; i < pbr.length && i < inner.pbr.length; i++) if (inner.pbr[i] == null) inner.pbr[i] = pbr[i];
        }
        append(c, inner, id, o, dirOf(abs));
    }
    return c;
}

function note(c: Composed, abs: string): void {
    if (!c.files.includes(abs)) c.files.push(abs);
}

// "a.rmdl -> b.rmdl -> a.rmdl": the chain from where `abs` first stands.
function cycleText(chain: Array<string>, abs: string): string {
    const from = chain.indexOf(abs);
    const parts = new Array<string>();
    for (let i = from >= 0 ? from : 0; i < chain.length; i++) parts.push(chain[i]);
    parts.push(abs);
    return parts.join(" -> ");
}

// A scene holding `s`'s own objects, actions and settings (the same
// instances: nothing is copied), and no material yet.
function shallowScene(s: Scene): Scene {
    const out = new Scene();
    const slots = new Array<Object?>();
    const os = s.objects.slots;
    for (let i = 0; i < os.length; i++) slots.push(os[i]);
    out.objects = SlotVec.fromSlots<Object>(slots, s.objects.live);
    out.active = s.active;
    out.mode = s.mode;
    out.selectMode = s.selectMode;
    out.cursor = s.cursor;
    out.pivot = s.pivot;
    out.orientation = s.orientation;
    out.frame = s.frame;
    out.frameRange = s.frameRange;
    out.fps = s.fps;
    out.frameStep = s.frameStep;
    const acts = new Array<Action?>();
    const as_ = s.actions.slots;
    for (let i = 0; i < as_.length; i++) acts.push(as_[i]);
    out.actions = SlotVec.fromSlots<Action>(acts, s.actions.live);
    out.renderDefaults = s.renderDefaults;
    out.poseClipboard = s.poseClipboard;
    out.imports = s.imports;
    return out;
}

// Appends the composed instanced model `inner` (read from a file in
// `dir`) under the empty `owner` (`emptyObj`) of `c`.
function append(c: Composed, inner: Composed, owner: u32, emptyObj: Object, dir: string): void {
    const out = c.scene;
    const src = inner.scene;
    // Materials and actions first: the objects name them.
    const matBase = <u32>out.materials.length;
    for (let i = 0; i < src.materials.length; i++) {
        out.materials.push(absoluteMaterial(src.materials[i], dir));
        c.pbr.push(i < inner.pbr.length ? inner.pbr[i] : null);
    }
    const actionIds = new Map<u32, u32>();
    const abound = src.actions.idBound();
    for (let id: u32 = 0; id < abound; id++) {
        const a = src.actions.get(id);
        if (a != null) actionIds.set(id, out.actions.push(a));
    }
    // The objects, in id order: each one's new id first, so that parents
    // and references can be renumbered whatever their order.
    const ids = new Map<u32, u32>();
    const bound = src.objects.idBound();
    let next = out.objects.idBound();
    for (let id: u32 = 0; id < bound; id++) {
        if (src.objects.get(id) == null) continue;
        ids.set(id, next);
        next++;
    }
    const hide = emptyObj.hide;
    const hideRender = emptyObj.hideRender;
    for (let id: u32 = 0; id < bound; id++) {
        const o = src.objects.get(id);
        if (o == null) continue;
        const n = instancedObject(o, ids, matBase, actionIds, owner);
        n.select = emptyObj.select;
        n.hide = n.hide || hide;
        n.hideRender = n.hideRender || hideRender;
        out.objects.push(n);
        // The owner of an object of a nested instance is this model's empty.
        c.owners.push(owner);
    }
}

// An instanced model's material with its files' paths absolute.
function absoluteMaterial(m: Material, dir: string): Material {
    const f = m.file;
    const hasRelative = (f != null && !isAbsolute(f)) || m.textures.iter().length > 0;
    if (!hasRelative) return m;
    const n = m.clone();
    if (f != null) n.file = besideFile(dir, f);
    const ts = n.textures.iter();
    for (let i = 0; i < ts.length; i++) ts[i].tex.path = besideFile(dir, ts[i].tex.path);
    return n;
}

// Object `o` of an instanced model, as an object of the composed scene: its
// ids renumbered (`ids`, `matBase`, `actionIds`), a top-level object
// parented to the empty `owner` (its transform then measured from the
// empty's). Its mesh is the instanced model's own (shared);
// an armature is copied when a constraint names an object, an empty when
// it names a file.
function instancedObject(o: Object, ids: Map<u32, u32>, matBase: u32, actionIds: Map<u32, u32>, owner: u32): Object {
    let data: ObjectData;
    if (o.data.kind == ObjectDataKind.Mesh) {
        data = ObjectData.fromMesh(o.data.meshData!);
    } else if (o.data.kind == ObjectDataKind.Armature) {
        data = o.data.clone();
        renumberConstraints(data, ids);
    } else {
        data = o.data.clone();
    }
    const n = new Object(o.name, data);
    n.transform = o.transform;
    const p = o.parent;
    if (p != null && ids.has(p.id)) {
        n.parent = new Parent(ids.get(p.id), p.kind.clone());
        n.parentInverse = o.parentInverse;
    } else {
        n.parent = new Parent(owner);
        n.parentInverse = MAT4_IDENTITY;
    }
    n.select = false;
    n.hide = o.hide;
    n.hideRender = o.hideRender;
    const slots = new Array<u32>();
    for (let i = 0; i < o.materialSlots.length; i++) {
        const k = o.materialSlots[i];
        slots.push(k == u32.MAX_VALUE ? k : k + matBase);
    }
    n.materialSlots = slots;
    for (let i = 0; i < o.modifiers.length; i++) {
        const m = o.modifiers[i].clone();
        if (m.kind.tag == ModifierKindTag.Armature) {
            const a = m.kind as ModifierKindArmature;
            a.object = renumbered(ids, a.object);
        } else if (m.kind.tag == ModifierKindTag.Instance) {
            const x = m.kind as ModifierKindInstance;
            x.object = renumbered(ids, x.object);
        }
        n.modifiers.push(m);
    }
    n.vertexGroups = o.vertexGroups;
    n.activeVgroup = o.activeVgroup;
    const anim = o.animation;
    if (anim != null) {
        const act = anim.action;
        n.animation = new AnimData(act != ACTION_NONE && actionIds.has(act) ? actionIds.get(act) : ACTION_NONE);
    }
    // An instance inside the instanced model was put in already (its
    // composed scene holds its objects): the empty keeps no file.
    if (data.kind == ObjectDataKind.Empty) data.emptyData!.instance = null;
    return n;
}

function renumbered(ids: Map<u32, u32>, id: u32): u32 {
    if (id == NO_OBJ) return NO_OBJ;
    return ids.has(id) ? ids.get(id) : NO_OBJ;
}

// An armature's constraints' targets and poles renumbered.
function renumberConstraints(data: ObjectData, ids: Map<u32, u32>): void {
    const arm = data.armatureData;
    if (arm == null) return;
    for (let bid: u32 = 0; bid < arm.bones.idBound(); bid++) {
        const b = arm.bones.get(bid);
        if (b == null) continue;
        const cs = b.pose.constraints;
        for (let ci = 0; ci < cs.length; ci++) {
            const t = cs[ci].kind.getTarget();
            if (t != null) t.object = renumbered(ids, t.object);
            if (cs[ci].kind.tag == ConstraintKindTag.Ik) {
                const ik = cs[ci].kind as ConstraintKindIk;
                const pole = ik.pole;
                if (pole != null) pole.object = renumbered(ids, pole.object);
            }
        }
    }
}
