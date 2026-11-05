// A model's clips in a scene (docs/plans/RIVE_MODEL.md section 3.7;
// docs/engine/ANIMATION.md, "Skeletons and imported clips"): each clip of
// a model the scene instances becomes a read-only LinearAnimation of the
// scene, named "<clip> (<source>)" (./names.as importedClipLabel), whose
// keyed objects are the model's nodes by path through the instancing node
// ("Hero/Armature" keyed "bones/Hips:quaternion"). The scene's
// SceneAnimations lists them after its own (../anim/scene_anims.as
// importedSources), so that everything that names an animation (render
// --animation, inspect, the Scene3D's `animation`, scripts'
// this.scene.animation(name), the editor's list and a state machine's
// states) reaches them by that name. Make Editable copies one into the
// scene as an ordinary animation (makeEditableDecl).

import { KeyFrameDecl, KeyedObjectDecl, KeyedPropertyDecl, LinearAnimationDecl, LoopMode } from "../anim/decl";
import { ModelResource } from "../resource/types";
import { modelNodeLayout } from "../tree/model_nodes";
import { importedClipLabel } from "./names";

// The imported clips of one scene document, made once and shared by every
// instance of it (../anim/scene_anims.as attachSceneAnimations; the
// instancer's and InstanceShare's `clips`): the declarations, the source of
// each, and what they were made from (the instancing paths, the models and
// their labels), so a document whose models differ (another loader's) makes
// them again. They are read-only: nothing edits an imported clip.
export class ImportedClipSet {
    paths: Array<string> = [];
    models: Array<ModelResource> = [];
    labels: Array<string> = [];
    decls: Array<LinearAnimationDecl> = [];
    sources: Array<string> = [];

    // Whether the set was made from these models at these paths.
    madeFrom(paths: Array<string>, models: Array<ModelResource>, labels: Array<string>): bool {
        if (paths.length != this.paths.length || models.length != this.models.length || labels.length != this.labels.length) return false;
        for (let i = 0; i < paths.length; i++) {
            if (paths[i] != this.paths[i] || models[i] !== this.models[i] || labels[i] != this.labels[i]) return false;
        }
        return true;
    }

    static make(paths: Array<string>, models: Array<ModelResource>, labels: Array<string>): ImportedClipSet {
        const set = new ImportedClipSet();
        set.paths = paths.slice(0);
        set.models = models.slice(0);
        set.labels = labels.slice(0);
        for (let m = 0; m < models.length; m++) {
            const clips = importedClipDecls(models[m], paths[m], labels[m]);
            for (let i = 0; i < clips.length; i++) {
                set.decls.push(clips[i]);
                set.sources.push(labels[m]);
            }
        }
        return set;
    }
}

// The read-only declarations of `model`'s clips as the scene that
// instances it at `instancePath` (the instancing node's path from the
// scene's root; "." when the model is the root) lists them, labelled with
// `source`, in the model's order. Targets are `instancePath` joined with
// modelNodePaths(model)[track.object]. A clip's tracks are grouped by
// object (one KeyedObject per node, in the order its first track comes);
// a track naming no object of the model is left out. The keys are copies:
// an edit of the scene never reaches the model's.
export function importedClipDecls(model: ModelResource, instancePath: string, source: string): Array<LinearAnimationDecl> {
    const out = new Array<LinearAnimationDecl>();
    const clips = model.clips;
    if (clips.length == 0) return out;
    const paths = modelNodePaths(model);
    for (let c = 0; c < clips.length; c++) {
        const clip = clips[c];
        const d = new LinearAnimationDecl(importedClipLabel(clip.name, source));
        d.fps = clip.fps;
        d.duration = clip.duration;
        d.loop = clip.loop ? LoopMode.Loop : LoopMode.OneShot;
        d.quantize = false;
        for (let t = 0; t < clip.tracks.length; t++) {
            const track = clip.tracks[t];
            if (track.object < 0 || track.object >= paths.length) continue;
            const target = joinPath(instancePath, paths[track.object]);
            let o = d.object(target);
            if (o == null) {
                o = new KeyedObjectDecl(target);
                d.objects.push(o);
            }
            o.properties.push(copyProperty(track.keys));
        }
        out.push(d);
    }
    return out;
}

// The path of each object of `model` from the root modelToNodes makes for
// it (../tree/model_nodes.as: the names made valid and unique as it makes
// them; an object following a bone sits under its BoneAttachment3D).
export function modelNodePaths(model: ModelResource): Array<string> {
    const out = new Array<string>();
    if (model.objects.length == 0) return out;
    const layout = modelNodeLayout(model);
    for (let i = 0; i < layout.nodeOf.length; i++) out.push(layout.path(layout.nodeOf[i]));
    return out;
}

// An imported clip's declaration copied into the scene as its own
// animation named `name`, re-timed to `fps` (each key on the nearest whole
// frame; two keys landing on one frame keep the later), every attribute
// and interpolator kept: what the editor's Make Editable adds to the file.
// The duration and a work area's frames are re-timed the same way.
export function makeEditableDecl(imported: LinearAnimationDecl, name: string, fps: i32): LinearAnimationDecl {
    const out = new LinearAnimationDecl(name);
    const from = imported.fps >= 1 ? imported.fps : 1;
    const to = fps >= 1 ? fps : 1;
    out.fps = to;
    out.duration = retime(imported.duration, from, to);
    out.speed = imported.speed;
    out.loop = imported.loop;
    out.enableWorkArea = imported.enableWorkArea;
    out.workStart = imported.workStart >= 0 ? retime(imported.workStart, from, to) : imported.workStart;
    out.workEnd = imported.workEnd >= 0 ? retime(imported.workEnd, from, to) : imported.workEnd;
    out.quantize = imported.quantize;
    out.extraAttrs = imported.extraAttrs.slice(0);
    out.extraChildren = imported.extraChildren.slice(0);
    for (let o = 0; o < imported.objects.length; o++) {
        const od = imported.objects[o];
        const oc = new KeyedObjectDecl(od.target);
        oc.extraAttrs = od.extraAttrs.slice(0);
        oc.extraChildren = od.extraChildren.slice(0);
        for (let p = 0; p < od.properties.length; p++) {
            const pd = od.properties[p];
            const pc = new KeyedPropertyDecl(pd.property);
            pc.extraAttrs = pd.extraAttrs.slice(0);
            pc.extraChildren = pd.extraChildren.slice(0);
            const keys = byFrame(pd.keys);
            for (let k = 0; k < keys.length; k++) {
                const key = keys[k].clone();
                key.frame = retime(key.frame, from, to);
                const n = pc.keys.length;
                // (keys come in frame order: a collision is with the last)
                if (n > 0 && pc.keys[n - 1].frame == key.frame) pc.keys[n - 1] = key;
                else pc.keys.push(key);
            }
            oc.properties.push(pc);
        }
        out.objects.push(oc);
    }
    return out;
}

// Frame `frame` of a `from` fps timeline on a `to` fps one: the nearest
// whole frame (a half rounds up; frames are never negative here).
function retime(frame: i32, from: i32, to: i32): i32 {
    if (from == to) return frame;
    return <i32>Math.round(<f64>frame * <f64>to / <f64>from);
}

// `keys` in increasing frame (stable).
function byFrame(keys: Array<KeyFrameDecl>): Array<KeyFrameDecl> {
    const out = keys.slice(0);
    for (let i = 1; i < out.length; i++) {
        const k = out[i];
        let j = i - 1;
        while (j >= 0 && out[j].frame > k.frame) {
            out[j + 1] = out[j];
            j--;
        }
        out[j + 1] = k;
    }
    return out;
}

// `base` joined with a path below it ("." collapsing: the root's own).
function joinPath(base: string, rest: string): string {
    if (base.length == 0 || base == ".") return rest.length > 0 ? rest : ".";
    if (rest.length == 0 || rest == ".") return base;
    return base + "/" + rest;
}

// A copy of a keyed property and its keys.
function copyProperty(p: KeyedPropertyDecl): KeyedPropertyDecl {
    const c = new KeyedPropertyDecl(p.property);
    for (let k = 0; k < p.keys.length; k++) c.keys.push(p.keys[k].clone());
    c.extraAttrs = p.extraAttrs.slice(0);
    c.extraChildren = p.extraChildren.slice(0);
    return c;
}
