// A model instanced as a scene (an ext_resource of type PackedScene naming
// a .gltf, .glb or .modeler file): its objects become nodes, so that a
// scene can move, hide or retune one part of a model with an override, as
// Godot does with an imported glTF scene (docs/formats/RSCN.md, "Models").
//
// The root is a Node3D named after the file (its stem, sanitised); under it
// one node per ModelObject, in the model's order, each under the node of
// its parent object: the object's node class, its name made valid, its
// transform relative to its parent (recorded as the `transform` property,
// so that an override's shorthands edit it as they would a file's), its
// visibility, the node properties the object sets (a camera's fov, a
// light's colour), and for a mesh object its evaluated mesh. Every node is
// owned by the model's root, which makes it overridable from the scene that
// instances the model and from no one else.
//
// Milestone 48 (docs/plans/RIVE_MODEL.md section 3.7; RSCN.md,
// "Skeletons"): an object with a skeleton is a Skeleton3D holding its
// bones; a skinned mesh's MeshInstance3D gets the skin and, as its
// `skeleton` property, the path from it to that Skeleton3D; a mesh with
// blend shapes gets their names and weights; an object that follows a bone
// of its parent's skeleton is placed under a BoneAttachment3D named after
// the bone, under the skeleton (one per bone, made where the first object
// following it is), its transform kept relative to the bone. Where each
// node goes is worked out once (modelNodeLayout), so that the paths a
// model's clips key (../skeleton/clips.as modelNodePaths) are the ones
// made here, name for name.

import { Property } from "../rscn/doc";
import { Value } from "../value";
import { ModelResource } from "../resource/types";
import { Camera3D, MeshInstance3D, SceneNode, Skeleton3D, createNode } from "./node";

// A node name made valid: each of `. : @ / " %` (which a node path would
// read as syntax) becomes `_`; an empty name becomes `fallback`.
export function sanitiseNodeName(name: string, fallback: string): string {
    if (name.length == 0) return fallback;
    let out = "";
    for (let i = 0; i < name.length; i++) {
        const c = name.charCodeAt(i);
        out += c == 46 || c == 58 || c == 64 || c == 47 || c == 34 || c == 37 ? "_" : String.fromCharCode(c);
    }
    return out;
}

// The file name of an absolute path without its directory and its last
// extension ("/work/models/scene.glb" -> "scene").
export function fileStem(abs: string): string {
    const slash = abs.lastIndexOf("/");
    const base = abs.substring(slash + 1);
    const dot = base.lastIndexOf(".");
    return dot > 0 ? base.substring(0, dot) : base;
}

// The class of the attachment nodes a model's bone-following objects go
// under.
const ATTACHMENT_CLASS = "BoneAttachment3D";

// Where each node of a model goes, in the order modelToNodes makes them:
// the objects in the model's order, an attachment just before the first
// object that follows its bone.
export class ModelNodeLayout {
    // Per node: its parent (an index here; -1 the model's root), its name
    // (made valid, and unique among its siblings as freeName makes it), the
    // object it is (-1 for an attachment) and, for an attachment, the bone.
    parents: Array<i32> = [];
    names: Array<string> = [];
    objects: Array<i32> = [];
    bones: Array<string> = [];
    // Per object of the model, its node's index.
    nodeOf: Array<i32> = [];

    // Node `k`'s path from the model's root ("Armature/Body").
    path(k: i32): string {
        let p = this.names[k];
        let at = this.parents[k];
        while (at >= 0) {
            p = this.names[at] + "/" + p;
            at = this.parents[at];
        }
        return p;
    }

    // The path from node `from` to node `to` ("..", "../Armature"), as a
    // NodePath from `from` names it.
    relative(from: i32, to: i32): string {
        // (the ancestors of `from`, itself first; -1 the root)
        const up = new Array<i32>();
        let a = from;
        while (true) {
            up.push(a);
            if (a < 0) break;
            a = this.parents[a];
        }
        const down = new Array<string>();
        let b = to;
        while (!up.includes(b)) {
            down.unshift(this.names[b]);
            b = this.parents[b];
        }
        const parts = new Array<string>();
        for (let i = 0; i < up.indexOf(b); i++) parts.push("..");
        for (let i = 0; i < down.length; i++) parts.push(down[i]);
        return parts.length == 0 ? "." : parts.join("/");
    }
}

// `name`, or `name_2`, `name_3`, ... : the first `taken` does not hold.
function freeIn(taken: Set<string>, name: string): string {
    if (!taken.has(name)) return name;
    for (let k = 2; ; k++) {
        const candidate = name + "_" + k.toString();
        if (!taken.has(candidate)) return candidate;
    }
    return name;
}

// Where the nodes of `model` go (see ModelNodeLayout).
export function modelNodeLayout(model: ModelResource): ModelNodeLayout {
    const out = new ModelNodeLayout();
    const objs = model.objects;
    // The names taken under each node (index + 1; 0 the root).
    const taken = new Array<Set<string>>();
    taken.push(new Set<string>());
    // The attachment made for "<skeleton node> <bone>".
    const attachments = new Map<string, i32>();
    for (let i = 0; i < objs.length; i++) {
        const o = objs[i];
        const owner = o.parent >= 0 && o.parent < i ? objs[o.parent] : null;
        let parent = owner != null ? out.nodeOf[o.parent] : -1;
        if (o.parentBone.length > 0 && owner != null && owner.skeleton != null) {
            const key = parent.toString() + " " + o.parentBone;
            if (attachments.has(key)) {
                parent = attachments.get(key);
            } else {
                const name = freeIn(taken[parent + 1], sanitiseNodeName(o.parentBone, ATTACHMENT_CLASS));
                taken[parent + 1].add(name);
                out.parents.push(parent);
                out.names.push(name);
                out.objects.push(-1);
                out.bones.push(o.parentBone);
                taken.push(new Set<string>());
                const made = out.names.length - 1;
                attachments.set(key, made);
                parent = made;
            }
        }
        const name = freeIn(taken[parent + 1], sanitiseNodeName(o.name, o.className));
        taken[parent + 1].add(name);
        out.parents.push(parent);
        out.names.push(name);
        out.objects.push(i);
        out.bones.push("");
        taken.push(new Set<string>());
        out.nodeOf.push(out.names.length - 1);
    }
    return out;
}

// The node class an object becomes: its own, or Skeleton3D for an
// armature (an object with bones).
function classOfObject(model: ModelResource, i: i32): string {
    const o = model.objects[i];
    return o.skeleton != null ? "Skeleton3D" : o.className;
}

// The nodes of a model (see the header). `path` is the model file's
// absolute path (its stem names the root), `display` how errors and dumps
// name it (each node's sceneFile). The root's owner is left null: the
// caller owns it.
export function modelToNodes(model: ModelResource, path: string, display: string): SceneNode {
    const root = createNode("Node3D", sanitiseNodeName(fileStem(path), "Node3D"));
    root.sceneFile = display;
    const layout = modelNodeLayout(model);
    const nodes = new Array<SceneNode>();
    const objs = model.objects;
    for (let k = 0; k < layout.names.length; k++) {
        const pi = layout.parents[k];
        const parent = pi >= 0 ? nodes[pi] : root;
        const oi = layout.objects[k];
        const layer = new Array<Property>();
        if (oi < 0) {
            // An attachment: at the bone (sync), by its name.
            const a = createNode(ATTACHMENT_CLASS, layout.names[k]);
            a.owner = root;
            a.sceneFile = display;
            parent.addChild(a);
            nodes.push(a);
            layer.push(new Property("bone_name", Value.stringName(layout.bones[k])));
            a.applyProperties(layer, null, display);
            continue;
        }
        const o = objs[oi];
        const n = createNode(classOfObject(model, oi), layout.names[k]);
        n.owner = root;
        n.sceneFile = display;
        parent.addChild(n);
        nodes.push(n);
        const skeleton = o.skeleton;
        const isSkeleton = n instanceof Skeleton3D;
        if (skeleton != null && isSkeleton) (n as Skeleton3D).setBones(skeleton.bones);
        const isMeshInstance = n instanceof MeshInstance3D;
        layer.push(new Property("transform", Value.transform(o.local)));
        if (!o.visible) layer.push(new Property("visible", Value.bool(false)));
        for (let p = 0; p < o.propNames.length; p++) layer.push(new Property(o.propNames[p], o.propValues[p]));
        if (isMeshInstance) {
            const mi = n as MeshInstance3D;
            const skin = o.skin;
            if (skin != null && skin.skeleton >= 0 && skin.skeleton < objs.length && objs[skin.skeleton].skeleton != null) {
                mi.skin = skin;
                layer.push(new Property("skeleton", Value.nodePath(layout.relative(k, layout.nodeOf[skin.skeleton]))));
            }
            if (o.blendShapes.length > 0) {
                const names = o.blendShapes.slice(0);
                const weights = new Array<f32>(names.length);
                for (let s = 0; s < names.length; s++) weights[s] = s < o.blendShapeWeights.length ? o.blendShapeWeights[s] : 0;
                mi.blendShapeNames = names;
                mi.blendShapeWeights = weights;
                mi.blendShapeRest = weights.slice(0);
            }
        }
        // A model's properties name no resource, so this cannot fail.
        n.applyProperties(layer, null, display);
        // Exactly the model's transform (Value.transform round-trips f32
        // through f64, which is exact, but say what is meant).
        n.local = o.local;
        const mesh = o.mesh;
        if (mesh != null && isMeshInstance) (n as MeshInstance3D).mesh = mesh;
        const isCamera = n instanceof Camera3D;
        if (isCamera) (n as Camera3D).majorAxis = true;
    }
    return root;
}
