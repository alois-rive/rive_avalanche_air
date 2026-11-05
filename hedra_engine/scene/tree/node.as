// The nodes of a loaded scene (docs/formats/RSCN.md, "Nodes"). A SceneNode
// is what a node declaration becomes once its scene is instanced: always a
// new object (resources are shared, nodes never are), with a parent, its
// children in order, the root of the scene that declared it (`owner`), and
// its properties.
//
// A node's properties are applied in layers, one per declaration that
// names it: the declaration in its own file first, then each override from
// the scenes that instance it, outermost last. `propNames`/`propValues` hold
// the effective properties (the last value of each name, in the order they
// were first set), unknown ones included, so that a tool can show them; the
// typed fields (`visible`, a camera's `fov`, a mesh instance's `mesh`, ...)
// are re-read from them after each layer, with the defaults of
// ../classdb.as for what no layer set. Resource-valued properties are the
// exception: an ExtResource("1") means something only in the file that
// wrote it, so each is resolved against that file's resources when its
// layer is applied, and kept until a later layer sets it again.
//
// Every class but Node and WorldEnvironment is 3D: it has a local transform
// and a visibility, and its global transform is its parent's global
// transform times its own when the parent is 3D too (a plain Node breaks
// the chain, as in Godot). A node whose type this format version does not
// know is kept as a 3D node with `unknownType` set, so that a newer scene
// still loads and places its children.

import { Mat3, Mat4, Quat, Vec2, Vec3, Vec4, MAT4_IDENTITY } from "../../base/vecmath";
import { Result, f64ToI32 } from "../../base/util";
import { SceneryError } from "../error";
import { PropType, findProp, isA } from "../classdb";
import { Value, ValueKind } from "../value";
import { BindingDecl, Property } from "../rscn/doc";
import { BindingProblem, BindingSpec, parseBindingDecl } from "../binding/binding";
import { BindingPose } from "../binding/apply";
import { SceneAnimations } from "../anim/scene_anims";
import { SceneMachines } from "../sm/scene_machines";
import { resourceClassMessage, unusableHint } from "../rscn/validate";
import {
    ArrayMesh, ArtboardTexture, Environment, LightmapGIData, Mesh, ModelResource, MultiMesh, ReflectionProbeData, Resource,
    SceneViewModel, Script, Shape3D, Sky, StandardMaterial3D, Texture2D,
} from "../resource/types";
import { DocResources } from "../resource/build";
import { ResourceHolder } from "../resource/cache";
import { FogMaterial } from "../resource/fog_material";
import { CameraAttributesPractical } from "../resource/camera_attributes";
import { Occluder3D } from "../resource/occluders";
import { NavigationMesh } from "../resource/navigation_mesh";
import { NavAgentState, navAgentLogic } from "../navigation/agent_state";
import { NavigationMap } from "../navigation/api";
import {
    applyLayer, basisFromEulerYXZ, eulerYXZFromBasis, rotationOf, scaled, signedScale, withBasis,
} from "./xform";
import { isUniqueSegment, splitNodePath, uniqueName } from "./paths";
// Milestone 27: a node knows the live tree it is in and its script's
// instance (types only: tree.as and ../script.as import this module).
import { Connection, SceneTree } from "./tree";
import { NodeScript } from "../script";
// Milestone 31: the space a RayCast3D casts in (types; ../interaction/api.as
// imports this module).
import { PhysicsDirectSpaceState3D, PhysicsRayQueryParameters3D, World3D } from "../interaction/api";
// Milestone 48: a model's bones and skins (types), and the names of their
// properties.
import { BonePose, ModelBone, ModelSkin } from "../skeleton/model_skin";
import {
    BLEND_SHAPES_PREFIX, BONES_PREFIX, BONE_FIELD_POSITION, BONE_FIELD_QUATERNION, parseBoneProperty,
} from "../skeleton/names";
// Milestone 32: paths (../path/: the curve, its bake, a follower's place).
import { Curve3D, CurveListener } from "../path/curve3d";
import { DEFAULT_VIEWPORT_SIDE, MAX_VIEWPORT_SIDE, UPDATE_ONCE, UPDATE_WHEN_VISIBLE } from "../../render/viewport";
import { ROTATION_NONE, ROTATION_ORIENTED, ROTATION_XYZ, pathFollowLocal } from "../path/follow";
// Milestone 35: particles (../particles/: the state the simulation keeps
// on the node; the curves and gradients it reads).
import { MAX_EMISSION_POINTS, MAX_PARTICLE_AMOUNT, MIN_PARTICLE_LIFETIME, ParticleState } from "../particles/state";
import { Curve } from "../resource/curve";
import { Gradient } from "../resource/gradient";
import { AudioStream } from "../resource/audio_stream";
import { AUDIO_SILENT_DB, AudioPlayback, MAX_AUDIO_POLYPHONY } from "../audio/state";

// The shorthands a layer's `transform` resets (xform.as).
const SHORTHANDS: Array<string> = ["position", "rotation", "rotation_degrees", "scale"];

// The rotation of `angle` radians about `axis` normalised, boxed so that a
// zero axis (no rotation) can be told apart; null for a zero or non-finite
// axis.
class AxisRotation {
    m: Mat3;

    constructor(m: Mat3) {
        this.m = m;
    }
}

// Milestone 39: who hears of a node added at run time. The run time
// (../runtime/scene_runtime.as) watches the root of each instance's
// tree, so that a script adding a subtree (`this.node.addChild(crate)`,
// after PackedSceneRef.instantiate) has its scripts attached and the next
// frame drawn. SceneNode.addChild tells the listener of the tree it adds
// to (SceneTree.onAdded sets one); nothing is told while no tree is
// watched, which is every tool, so loading and editing are as before.
export abstract class NodeAddedListener {
    // `child` (and its subtree) was added under `parent`, a node of the
    // watched tree.
    abstract added(parent: SceneNode, child: SceneNode): void;

    // Milestone 27: `child` (and its subtree) is about to be removed from
    // `parent` (SceneNode.removeChild): still linked, so that the scripts'
    // _exitTree sees the node where it was, as Godot's does.
    removing(parent: SceneNode, child: SceneNode): void {}
}

// Milestone 27: bumped whenever a node gains or loses a child or a group
// anywhere, so that a live tree's group index (tree.as) knows it is stale
// without walking the tree each frame. Milestone 28: and when a node is
// renamed, so that the debug agent (host/src/play/remote/agent.as) sends
// the remote tree again and finds a watched node by its new path.
let structureEpoch: i32 = 0;

// The epoch now (tree.as).
export function treeStructureEpoch(): i32 {
    return structureEpoch;
}

// Milestone 31: the narrower epoch behind structureEpoch for a rename:
// namesEpoch moves only then (the interaction feature's paths, named again
// then without making the world again). What the interaction world is
// made of is followed per tree instead (SceneNode.shapesEpoch).
let namesEpoch: i32 = 0;

// The epoch of what the interaction world of the tree whose root is
// `root` is made of (SceneNode.shapesEpoch).
export function treeShapesEpoch(root: SceneNode): i32 {
    return root.shapesEpoch;
}

// Whether `n` or a node under it is a collision object, a collision shape
// or a ray: what the interaction world is made of. A walk without
// allocating, done once per child added or removed.
function holdsInteraction(n: SceneNode): bool {
    if (n instanceof CollisionObject3D || n instanceof CollisionShape3D || n instanceof RayCast3D) return true;
    const cs = n.children;
    for (let i = 0; i < cs.length; i++) if (holdsInteraction(unchecked(cs[i]))) return true;
    return false;
}

export function treeNamesEpoch(): i32 {
    return namesEpoch;
}

// Milestone 34: bumped whenever a SubViewport's own_world_3d changes (a
// key, a binding, a script, the Inspector), so that what is filtered by
// world once per tree (the reflection probes of the main world:
// ../render/probes.as) is filtered again.
let ownWorldsEpoch: i32 = 0;

export function treeOwnWorldsEpoch(): i32 {
    return ownWorldsEpoch;
}

// The watched roots and their listeners, by index (a run time has a
// handful of instances: a scan is enough).
const watchedRoots = new Array<SceneNode>();
const watchers = new Array<NodeAddedListener>();

// Tells `l` of every node added under the tree whose root is `root` (a
// second call for the root replaces its listener).
export function watchAdded(root: SceneNode, l: NodeAddedListener): void {
    for (let i = 0; i < watchedRoots.length; i++) {
        if (watchedRoots[i] === root) {
            watchers[i] = l;
            return;
        }
    }
    watchedRoots.push(root);
    watchers.push(l);
}

// Stops telling anyone about `root`'s tree.
export function unwatchAdded(root: SceneNode): void {
    for (let i = 0; i < watchedRoots.length; i++) {
        if (watchedRoots[i] === root) {
            watchedRoots.splice(i, 1);
            watchers.splice(i, 1);
            return;
        }
    }
}

// The listener of the tree whose root is `root`, or null.
export function addedListenerOf(root: SceneNode): NodeAddedListener? {
    for (let i = 0; i < watchedRoots.length; i++) if (watchedRoots[i] === root) return watchers[i];
    return null;
}

// Milestone 28: the node whose script is running now (null: none), set
// around each call into a script (the script runtime, signals, timers,
// tweens, callGroup), so that a pushError or pushWarning names its node and
// a click on the Debugger's Errors row selects it, as Godot's does. A plain
// global: the calls nest (a script's ready() adding a child that is
// readied), so each caller keeps what was there and puts it back.
let runningNode: SceneNode? = null;

// Marks `n`'s script as running; returns the node that was, for
// leaveScript.
export function enterScript(n: SceneNode?): SceneNode? {
    const was = runningNode;
    runningNode = n;
    return was;
}

// Puts back the node enterScript returned.
export function leaveScript(was: SceneNode?): void {
    runningNode = was;
}

// The node whose script is running, or null.
export function scriptNodeRunning(): SceneNode? {
    return runningNode;
}

function unitRotation(axis: Vec3, angle: f32): AxisRotation? {
    const len = axis.length();
    if (!(len > 0) || !isFinite(len)) return null;
    return new AxisRotation(Mat3.fromAxisAngle(axis / len, angle));
}

// Each node's `serial` (see SceneNode.serial).
let nextNodeSerial: i32 = 0;

export class SceneNode {
    // A number no other node of the program has, for the maps that keep
    // something per node from frame to frame (the timelines' rotation
    // states, the renderer's skins and blend shapes): a map keyed by the
    // node object itself finds nothing once a baked project's collector has
    // moved the node (a scene loaded in a frame is young, and moves at its
    // end), so those maps are keyed by this.
    readonly serial: i32 = nextNodeSerial++;
    // The name, behind `name` (a rename is a structure change: see
    // structureEpoch).
    private _name: string;
    // "Node3D", "Camera3D", ... or the name of a type this format version
    // does not know.
    className: string;
    parent: SceneNode? = null;
    children: Array<SceneNode> = [];
    // The root of the scene that declared it: null for the tree's root; an
    // instance root's owner is the root of the scene that instanced it.
    owner: SceneNode? = null;
    // The display path of the file that declared it; for an instance root,
    // the instanced file.
    sceneFile: string = "";
    // An instance root: the absolute path of the instanced PackedScene;
    // "" for every other node. When the instanced scene's root is itself an
    // instance (an inherited scene), this is the outermost one.
    instancePath: string = "";
    // Every scene this node is the root of an instance of, innermost first:
    // A instancing B, whose root instances C, gives [C, B]. What a
    // declaration of C lands on is found through it (instancePath names
    // only B).
    instancePaths: Array<string> = [];
    unknownType: bool = false;
    // unique_name_in_owner: reachable as %Name from the nodes of its scene.
    unique: bool = false;
    // Where the layer that last set unique_name_in_owner is (the
    // property's value), for the unique-duplicate error: file "" when it was
    // not set from a file.
    uniqueFile: string = "";
    uniqueLine: i32 = 0;
    uniqueCol: i32 = 0;
    // Groups in the order first declared (the union of every layer's).
    groups: Array<string> = [];
    script: Script? = null;
    // Effective properties (see the header).
    propNames: Array<string> = [];
    propValues: Array<Value> = [];
    // Milestone 49: the Values a binding or an animation wrote over the
    // effective properties (../binding/apply.as), each this node's own: a
    // later write of the same property sets it in place rather than making
    // another, so a machine or a timeline writing a light's energy every
    // frame allocates nothing once it has written it. A declaration's
    // Value is never one of them (the declarations are shared, and never
    // changed in place).
    writtenValues: Array<Value> = [];
    // Milestone 49: a count bumped by every change of the effective
    // properties (setProp, removeProp, and a write in place: writtenProp
    // is asked only by a write), so that a reader that kept what it saw
    // tells a change without comparing values; a Value's identity no longer
    // does, since a written one changes in place.
    propsVersion: i64 = 0;
    // Milestone 17: `view_model` (the root's counts: ../binding/binder.as),
    // and the bindings the node's layers gave it, one per property, in the
    // order first declared (an override's replaces the instanced scene's
    // for the same property, and one with an empty path removes it).
    viewModel: SceneViewModel? = null;
    bindings: Array<BindingSpec> = [];
    // The rotation and scale the bindings last wrote here (see BindingPose).
    // Kept on the node rather than in a SceneBindings so that every binder
    // over the same tree carries on from the last pull: the preview pulls
    // once to check --data and again when it installs its view model, and
    // a fresh pose would read the first pull's matrix back, folding X past
    // 90 degrees or a negative scale.
    bindingPose: BindingPose? = null;
    // Milestone 45: on the root of each instanced scene file that declares
    // animations or events (../anim/scene_anims.as attachSceneAnimations),
    // its timelines over this subtree; null on every other node.
    animations: SceneAnimations? = null;
    // Milestone 46: on the root of each instanced scene file that declares
    // state machines (../sm/scene_machines.as attachSceneMachines), its
    // machines over this subtree; null on every other node.
    machines: SceneMachines? = null;
    // 3D state (unused when is3d is false).
    is3d: bool = true;
    local: Mat4 = MAT4_IDENTITY;
    visible: bool = true;
    // Milestone 27, set by the script runtime (../player/runtime.as): the
    // live tree the node is in (null outside one, and always in the tools,
    // which run no script), its script's instance (kept when the node
    // leaves the tree, so that adding it again carries on with the same
    // object, as Godot keeps a removed node's script), and whether
    // queueFree asked for it to go (`queued`) and it went (`freed`).
    liveTree: SceneTree? = null;
    scriptObject: NodeScript? = null;
    queued: bool = false;
    freed: bool = false;
    // Milestone 67b: what the subtree this node is the root of holds in the
    // run time's cache, when a script instanced it (PackedSceneRef
    // .instantiate); let go of when it is freed (markFreed). Null
    // otherwise, and always in the tools.
    heldResources: ResourceHolder? = null;
    // The live tree the node was last in (set when it leaves one, and on a
    // subtree PackedSceneRef.instantiate made, whose connections joined
    // that tree before it was added): a node freed out of a live tree
    // still holds connections there, which that tree's end of frame drops.
    lastTree: SceneTree? = null;
    // Set while the script runtime takes the subtree out of the live tree
    // (its _exitTree calls): a removeChild of it then, such as a script
    // removing its own node in _exitTree, unlinks it without running the
    // exit again (it would recurse without end).
    exiting: bool = false;
    // Milestone 31, meaningful on a tree's root: bumped when a subtree that
    // holds a collision object, shape or ray joins or leaves the tree, so
    // that the tree's interaction world (interaction/world.as) is made
    // again then and only then. Per tree, and blind to other children: a
    // script spawning meshes, or a second Scene3D, would otherwise make
    // every world again each frame, allocating.
    shapesEpoch: i32 = 0;

    constructor(className: string, name: string, is3d: bool = true) {
        this.className = className;
        this._name = name;
        this.is3d = is3d;
    }

    get name(): string {
        return this._name;
    }

    set name(v: string) {
        if (v == this._name) return;
        this._name = v;
        structureEpoch++;
        namesEpoch++;
    }

    // The class whose properties and defaults apply: its own, or Node3D's
    // for a type this format version does not know.
    schemaClass(): string {
        return this.unknownType ? "Node3D" : this.className;
    }

    // --- properties ----------------------------------------------------------

    getProp(name: string): Value? {
        for (let i = 0; i < this.propNames.length; i++) if (this.propNames[i] == name) return this.propValues[i];
        return null;
    }

    // Sets an effective property: in place when it is already set, else
    // appended.
    setProp(name: string, v: Value): void {
        this.propsVersion++;
        for (let i = 0; i < this.propNames.length; i++) {
            if (this.propNames[i] == name) {
                this.propValues[i] = v;
                return;
            }
        }
        this.propNames.push(name);
        this.propValues.push(v);
    }

    // Milestone 49: the effective value of `name` when it is one of the
    // node's written Values of kind `kind` (writtenValues), to be set in
    // place by the caller, which only a write asks (propsVersion counts it
    // a change); else null. Allocates nothing.
    writtenProp(name: string, kind: ValueKind): Value? {
        const v = this.getProp(name);
        if (v == null || v.kind != kind) return null;
        const w = this.writtenValues;
        for (let i = 0; i < w.length; i++) {
            if (unchecked(w[i]) === v) {
                this.propsVersion++;
                return v;
            }
        }
        return null;
    }

    // Milestone 49: `v`, made for a write, becomes the effective value of
    // `name` and one of the node's written Values, in the place of one no
    // longer held (a written property set again from elsewhere), so the
    // list is as long as the properties written.
    setWrittenProp(name: string, v: Value): void {
        this.setProp(name, v);
        const w = this.writtenSlot();
        if (w >= 0) this.writtenValues[w] = v;
        else this.writtenValues.push(v);
    }

    // A slot of writtenValues whose Value is no longer an effective one,
    // or -1.
    private writtenSlot(): i32 {
        const w = this.writtenValues;
        const vs = this.propValues;
        for (let i = 0; i < w.length; i++) {
            const v = unchecked(w[i]);
            let held = false;
            for (let k = 0; k < vs.length && !held; k++) held = unchecked(vs[k]) === v;
            if (!held) return i;
        }
        return -1;
    }

    removeProp(name: string): bool {
        for (let i = 0; i < this.propNames.length; i++) {
            if (this.propNames[i] == name) {
                this.propNames.splice(i, 1);
                this.propValues.splice(i, 1);
                this.propsVersion++;
                return true;
            }
        }
        return false;
    }

    // The effective value of a property of the class, or its default when
    // no layer set it or a layer set a value of the wrong type (the
    // validator reported that). A property the class does not have: the
    // value set, or null.
    protected value(name: string): Value? {
        const info = findProp(this.schemaClass(), name);
        const v = this.getProp(name);
        if (info == null) return v;
        if (v != null && info.accepts(v)) return v;
        return info.def;
    }

    protected boolProp(name: string, fallback: bool): bool {
        const v = this.value(name);
        return v != null && v.kind == ValueKind.Bool ? v.b : fallback;
    }

    protected f32Prop(name: string, fallback: f32): f32 {
        const v = this.value(name);
        return v != null && v.isNumber() ? v.asF32() : fallback;
    }

    protected i32Prop(name: string, fallback: i32): i32 {
        const v = this.value(name);
        return v != null && v.isNumber() ? v.asI32() : fallback;
    }

    protected colorProp(name: string, fallback: Vec4): Vec4 {
        const v = this.value(name);
        return v != null && v.kind == ValueKind.Color ? v.vec4() : fallback;
    }

    // Re-reads the typed fields from the effective properties (subclasses
    // add theirs). Resource fields are set by setResource instead.
    readFields(): void {
        if (this.is3d) this.visible = this.boolProp("visible", true);
        this.unique = this.boolProp("unique_name_in_owner", false);
    }

    // Sets the field of a resource-valued property (already class-checked).
    setResource(name: string, r: Resource?): void {
        if (name == "script") {
            const isScript = r instanceof Script;
            this.script = isScript ? r as Script : null;
        } else if (name == "view_model") {
            const isViewModel = r instanceof SceneViewModel;
            this.viewModel = isViewModel ? r as SceneViewModel : null;
        }
    }

    // Milestone 17: applies one layer's bindings (one declaration's, from
    // the file `file` as errors name it) over those of the layers before:
    // a binding replaces the earlier one of the same property where it was
    // (so the order stays the one first declared), one with an empty path
    // removes it (an override taking a binding off an instanced node), any
    // other is appended. Fails, leaving the node unchanged, on a binding
    // that does not read (the validator reports each of those first, as
    // binding-* errors).
    applyBindings(layer: Array<BindingDecl>, file: string): Result<bool> {
        const problem = new BindingProblem();
        const specs = new Array<BindingSpec>();
        for (let i = 0; i < layer.length; i++) {
            const d = layer[i];
            const spec = parseBindingDecl(d, file, problem);
            if (spec == null) {
                const at = problem.attr.length > 0 ? d.attrPos(problem.attr) : d.pos;
                return SceneryError.at(problem.code, file, at.line, at.col, problem.message,
                    problem.hint.length > 0 ? problem.hint : null).fail<bool>();
            }
            specs.push(spec);
        }
        for (let i = 0; i < specs.length; i++) {
            const spec = specs[i];
            let at = -1;
            for (let k = 0; k < this.bindings.length && at < 0; k++) if (this.bindings[k].property == spec.property) at = k;
            if (spec.path.length == 0) {
                if (at >= 0) this.bindings.splice(at, 1);
            } else if (at >= 0) {
                this.bindings[at] = spec;
            } else {
                this.bindings.push(spec);
            }
        }
        return Result.okv<bool>(true);
    }

    // Applies one layer: the properties of one declaration, from the file
    // `file` (as errors name it), whose resources are `res` (null: the
    // layer names none, as a model's objects). Fails, leaving the node
    // unchanged, when a resource value is of the wrong class.
    applyProperties(layer: Array<Property>, res: DocResources?, file: string): Result<bool> {
        const schema = this.schemaClass();
        const resNames = new Array<string>();
        const resValues = new Array<Resource?>();
        for (let i = 0; i < layer.length; i++) {
            const p = layer[i];
            const info = findProp(schema, p.name);
            if (info == null || info.type != PropType.Resource) continue;
            const r = res != null ? res.get(p.value) : null;
            if (r != null && !isA(r.className(), info.resourceClass)) {
                return SceneryError.at("property-resource-class", file, p.valuePos.line, p.valuePos.col,
                    resourceClassMessage(p.name, info.resourceClass, r.className(), p.value)).fail<bool>();
            }
            const declared = r == null && res != null ? res.declaredType(p.value) : "";
            if (declared.length > 0) {
                // A declared ext_resource that was not loaded: its type is
                // one this format version does not load, so it never
                // satisfies a resource property. The validator refuses it
                // on a typed node, but it does not know an override's
                // class, and setting the field to null would silently undo
                // what the instanced scene set. (An undeclared id the
                // validator always reports, as resource-undeclared.)
                return SceneryError.at("property-resource-class", file, p.valuePos.line, p.valuePos.col,
                    resourceClassMessage(p.name, info.resourceClass, declared, p.value),
                    unusableHint(info.resourceClass, declared, p.value)).fail<bool>();
            }
            resNames.push(p.name);
            resValues.push(r);
        }
        if (this.is3d) this.local = applyLayer(this.local, layer);
        let hasTransform = false;
        for (let i = 0; i < layer.length; i++) if (layer[i].name == "transform") hasTransform = true;
        if (hasTransform) for (let k = 0; k < SHORTHANDS.length; k++) this.removeProp(SHORTHANDS[k]);
        for (let i = 0; i < layer.length; i++) {
            const p = layer[i];
            this.setProp(p.name, p.value);
            if (p.name == "unique_name_in_owner") {
                this.uniqueFile = file;
                this.uniqueLine = p.valuePos.line;
                this.uniqueCol = p.valuePos.col;
            }
        }
        this.readFields();
        for (let i = 0; i < resNames.length; i++) this.setResource(resNames[i], resValues[i]);
        return Result.okv<bool>(true);
    }

    // Adds groups not already there, in order.
    addGroups(groups: Array<string>): void {
        for (let i = 0; i < groups.length; i++) if (!this.groups.includes(groups[i])) this.groups.push(groups[i]);
        structureEpoch++;
    }

    // --- Milestone 27: groups and signals from scripts (Godot's Node API).
    // The .rscn's <group>s are the same groups.

    // Adds the node to `group` (nothing when it is in it already).
    addToGroup(group: string): void {
        if (this.groups.includes(group)) return;
        this.groups.push(group);
        structureEpoch++;
    }

    // Takes the node out of `group` (nothing when it is not in it).
    removeFromGroup(group: string): void {
        const i = this.groups.indexOf(group);
        if (i < 0) return;
        this.groups.splice(i, 1);
        structureEpoch++;
    }

    isInGroup(group: string): bool {
        return this.groups.includes(group);
    }

    // Connects this node's `signal` to `method` of `target`'s script, as a
    // <connection> of the scene does (flags: Godot's, CONNECT_ONE_SHOT 4
    // disconnects it after the first call). The connection lives in the
    // live tree the node is in: false, connecting nothing, when the node
    // is in none, or when the same connection exists already (Godot
    // refuses a second one too).
    connect(signal: string, target: SceneNode, method: string, flags: i32 = 0): bool {
        const tree = this.liveTree;
        if (tree == null || this.connectionTo(signal, target, method) >= 0) return false;
        const c = new Connection(signal, this, target, method);
        c.flags = flags;
        tree.connections.push(c);
        return true;
    }

    // Removes the connection `connect` (or the scene) made; false when
    // there is none.
    disconnect(signal: string, target: SceneNode, method: string): bool {
        const at = this.connectionTo(signal, target, method);
        if (at < 0) return false;
        (this.liveTree as SceneTree).connections.splice(at, 1);
        return true;
    }

    isConnected(signal: string, target: SceneNode, method: string): bool {
        return this.connectionTo(signal, target, method) >= 0;
    }

    // The index of the connection from this node in its live tree, or -1.
    private connectionTo(signal: string, target: SceneNode, method: string): i32 {
        const tree = this.liveTree;
        if (tree == null) return -1;
        const cs = tree.connections;
        for (let i = 0; i < cs.length; i++) {
            const c = cs[i];
            if (c.from === this && c.to === target && c.signal == signal && c.method == method) return i;
        }
        return -1;
    }

    // --- the tree --------------------------------------------------------------

    // Milestone 39: when the tree this node is in is watched (watchAdded:
    // the run time's instances), its listener hears of `c`, so a
    // script's addChild attaches the subtree's scripts and redraws.
    addChild(c: SceneNode): void {
        c.parent = this;
        this.children.push(c);
        structureEpoch++;
        if (holdsInteraction(c)) this.treeRoot().shapesEpoch++;
        // Milestone 32: Godot's PathFollow3D places itself when it enters
        // the tree under a Path3D (NOTIFICATION_ENTER_TREE).
        const isFollower = c instanceof PathFollow3D;
        if (isFollower) (c as PathFollow3D).updateTransform();
        if (watchers.length > 0) {
            const l = addedListenerOf(this.treeRoot());
            if (l != null) l.added(this, c);
        }
    }

    // Milestone 27: removes the child `c` (false when it is not one). In a
    // watched tree its listener hears of it first, while `c` is still
    // linked: the script runtime calls _exitTree on its subtree, children
    // first, and drops their scripts' instances. The subtree is kept (add
    // it again, and its scripts carry on); queueFree frees one.
    removeChild(c: SceneNode): bool {
        const at = this.children.indexOf(c);
        if (at < 0) return false;
        if (watchers.length > 0 && !c.exiting) {
            const l = addedListenerOf(this.treeRoot());
            if (l != null) l.removing(this, c);
        }
        // (the listener's scripts may have moved it meanwhile)
        const now = this.children.indexOf(c);
        const root = this.treeRoot();
        if (now >= 0) this.children.splice(now, 1);
        if (c.parent === this) c.parent = null;
        if (!c.queued) keepHeldOf(this, c);
        structureEpoch++;
        if (holdsInteraction(c)) root.shapesEpoch++;
        return true;
    }

    // Whether this node or one of its ancestors is leaving the live tree
    // (`exiting`: their _exitTree calls are running). A child added under
    // it then never enters the tree (Godot refuses add_child there, "Parent
    // node is busy"): the subtree is on its way out, and one entered would
    // stay live outside it, processed and counted. Walks the ancestors;
    // allocates nothing.
    isLeavingTree(): bool {
        let n: SceneNode? = this;
        while (n != null) {
            if (n.exiting) return true;
            n = n.parent;
        }
        return false;
    }

    // The node's parent, or null for a root.
    getParent(): SceneNode? {
        return this.parent;
    }

    // Whether the node is in a live tree (a scene the script runtime plays).
    isInsideTree(): bool {
        return this.liveTree != null;
    }

    // Godot's queue_free: the node and its subtree leave the tree and are
    // freed at the end of the frame, after every script's _process (never
    // while the scripts are being called). Out of a live tree, at once.
    queueFree(): void {
        if (this.queued || this.freed) return;
        this.queued = true;
        const tree = this.liveTree;
        if (tree != null) {
            tree.queueFree(this);
            return;
        }
        const p = this.parent;
        if (p != null) p.removeChild(this);
        markFreed(this);
        // (the connections it made or took in the tree it was in go at that
        // tree's end of frame: removeChild then queueFree, or an instanced
        // subtree freed before it was added, left them there for good)
        const last = this.formerTree();
        if (last != null) last.queueFree(this);
    }

    // The live tree this node or its nearest ancestor was last in, or null.
    private formerTree(): SceneTree? {
        let n: SceneNode? = this;
        while (n != null) {
            const t = n.lastTree;
            if (t != null) return t;
            n = n.parent;
        }
        return null;
    }

    isQueuedForDeletion(): bool {
        return this.queued;
    }

    child(name: string): SceneNode? {
        for (let i = 0; i < this.children.length; i++) if (this.children[i].name == name) return this.children[i];
        return null;
    }

    // The root of the tree this node is in.
    treeRoot(): SceneNode {
        let n: SceneNode = this;
        while (true) {
            const p = n.parent;
            if (p == null) return n;
            n = p;
        }
        return n;
    }

    // Milestone 31: Godot's get_world_3d(): the world of the live tree the
    // node is in (its directSpaceState answers ray and point queries), or
    // null outside one.
    getWorld3D(): World3D? {
        const t = this.liveTree;
        return t != null ? t.world : null;
    }

    // Parent's global * local when the parent is 3D, else local.
    global(): Mat4 {
        const p = this.parent;
        if (p != null && p.is3d) return p.global() * this.local;
        return this.local;
    }

    // --- The script API (engine/src/scene/script.as): Godot's Node3D
    // methods on the local transform, which scripts change and the next
    // frame draws. They change `local` only: `propNames`/`propValues` keep
    // what the scene files said, as Godot's saved scene does while the game
    // runs. On a node that is not 3D (Node, WorldEnvironment) they change a
    // transform nothing reads, as `global` ignores it.
    //
    // Godot's semantics: rotate and rotateX/Y/Z turn the basis about the
    // parent's axes (Basis::rotate, R * basis) and keep the origin, as
    // Node3D.rotate_x does; rotateObjectLocal turns it about its own axes
    // (basis * R); translate moves along its own (scaled) axes, as
    // Node3D.translate; rotation is Euler YXZ in radians and scale the
    // signed scale, as the `rotation` and `scale` properties are (xform.as),
    // and setting either keeps the other.

    // The local origin: where the node is in its parent.
    get position(): Vec3 {
        return this.local.wAxis.truncate();
    }

    set position(p: Vec3) {
        this.setPosition(p);
    }

    // The setters as methods, as Godot's set_position: the pinned rive's
    // compiler refuses an assignment through an accessor of a value class
    // (`node.position = Vec3(...)` is error E3001, "value class accessors
    // are not supported yet"), so scripts call these.
    setPosition(p: Vec3): void {
        const m = this.local;
        this.local = Mat4(m.xAxis, m.yAxis, m.zAxis, p.extend(1));
    }

    // Euler angles in radians, order YXZ, of the basis with its scale
    // divided out (a mirrored node's rotation is a proper one: the sign
    // goes with the scale).
    get rotation(): Vec3 {
        return eulerYXZFromBasis(rotationOf(this.local));
    }

    set rotation(r: Vec3) {
        this.setRotation(r);
    }

    setRotation(r: Vec3): void {
        const m = this.local;
        this.local = withBasis(m, scaled(basisFromEulerYXZ(r), signedScale(m)));
    }

    // The lengths of the basis columns, all negated when the basis mirrors.
    get scale(): Vec3 {
        return signedScale(this.local);
    }

    set scale(s: Vec3) {
        this.setScale(s);
    }

    setScale(s: Vec3): void {
        const m = this.local;
        this.local = withBasis(m, scaled(rotationOf(m), s));
    }

    // The global transform's origin.
    get globalPosition(): Vec3 {
        return this.global().wAxis.truncate();
    }

    // Turns the node `angle` radians about `axis`, an axis of the parent's
    // space through the node's origin (counter-clockwise seen from the
    // axis's tip). Godot requires a unit axis; any length works here, and
    // a zero axis changes nothing.
    rotate(axis: Vec3, angle: f32): void {
        const r = unitRotation(axis, angle);
        if (r == null) return;
        this.local = withBasis(this.local, r.m * Mat3.fromMat4(this.local));
    }

    rotateX(angle: f32): void {
        this.local = withBasis(this.local, Mat3.fromRotationX(angle) * Mat3.fromMat4(this.local));
    }

    rotateY(angle: f32): void {
        this.local = withBasis(this.local, Mat3.fromRotationY(angle) * Mat3.fromMat4(this.local));
    }

    rotateZ(angle: f32): void {
        this.local = withBasis(this.local, Mat3.fromRotationZ(angle) * Mat3.fromMat4(this.local));
    }

    // Turns the node about `axis` in its own space (its basis's axes,
    // before scale): basis * R, as Node3D.rotate_object_local.
    rotateObjectLocal(axis: Vec3, angle: f32): void {
        const r = unitRotation(axis, angle);
        if (r == null) return;
        this.local = withBasis(this.local, Mat3.fromMat4(this.local) * r.m);
    }

    // Moves the node by `offset` along its own axes, scale included:
    // origin += basis * offset, as Node3D.translate.
    translate(offset: Vec3): void {
        const m = this.local;
        const o = m.wAxis.truncate() + Mat3.fromMat4(m).mulVec3(offset);
        this.local = Mat4(m.xAxis, m.yAxis, m.zAxis, o.extend(1));
    }

    // Visible, and so is every 3D ancestor up to the first node that is
    // not 3D (visibility, like the transform, does not cross a plain Node).
    visibleInTree(): bool {
        if (this.is3d && !this.visible) return false;
        const p = this.parent;
        if (p == null || !p.is3d) return true;
        return p.visibleInTree();
    }

    // The path from the tree's root: "." for the root, "A/B" below it.
    path(): string {
        return this.pathFrom(null);
    }

    // The path from an ancestor ("." for the ancestor itself); from the
    // tree's root when `ancestor` is null or not an ancestor.
    pathFrom(ancestor: SceneNode?): string {
        const names = new Array<string>();
        let n: SceneNode = this;
        while (n != ancestor) {
            const p = n.parent;
            if (p == null) break;
            names.unshift(n.name);
            n = p;
        }
        return names.length == 0 ? "." : names.join("/");
    }

    // The node of its scene (owned by this node) marked unique with that
    // name, in tree order; null when there is none.
    findUnique(name: string): SceneNode? {
        return this.findUniqueOwnedBy(name, this);
    }

    private findUniqueOwnedBy(name: string, scope: SceneNode): SceneNode? {
        for (let i = 0; i < this.children.length; i++) {
            const c = this.children[i];
            if (c.unique && c.name == name && c.owner == scope) return c;
            const d = c.findUniqueOwnedBy(name, scope);
            if (d != null) return d;
        }
        return null;
    }

    // The node a path names from this one (paths.as has the forms), or
    // null. A %Name segment, first or later, follows Godot 4: from the node
    // the path has reached so far, it looks first among the nodes that
    // node owns (so a scene's root, instanced or not, reaches its own
    // unique nodes, and "Inst/%Name" reaches into instance Inst), then
    // among those its owner owns (the scene it was declared in).
    getNode(path: string): SceneNode? {
        const parts = splitNodePath(path);
        if (parts == null) return null;
        const segs = parts.segments;
        let cur: SceneNode? = this;
        let i = 0;
        if (parts.absolute) {
            const root = this.treeRoot();
            if (segs[0] != root.name) return null;
            cur = root;
            i = 1;
        }
        for (; i < segs.length; i++) {
            const at = cur;
            if (at == null) return null;
            const s = segs[i];
            if (s == ".") continue;
            if (s == "..") cur = at.parent;
            else if (isUniqueSegment(s)) cur = at.uniqueFrom(uniqueName(s));
            else cur = at.child(s);
        }
        return cur;
    }

    // A %Name from this node: among the nodes it owns, else its owner's.
    private uniqueFrom(name: string): SceneNode? {
        const own = this.findUnique(name);
        if (own != null) return own;
        const o = this.owner;
        return o != null ? o.findUnique(name) : null;
    }
}

// The base of MeshInstance3D, ModelInstance3D and MultiMeshInstance3D, as
// Godot's: what they share is how they cast shadows and the distances they
// are drawn at (milestone 13).
export class GeometryInstance3D extends SceneNode {
    // cast_shadow: 0 off, 1 on, 2 double sided, 3 shadows only
    // (CAST_SHADOW_* of hedra_engine/render/frame.as, which the adapter clamps to).
    castShadow: i32 = 1;
    // visibility_range_*: the distances from the camera to the centre of the
    // node's box between which it is drawn (0: no limit), their margins,
    // and the fade mode (0 disabled, 1 self, 2 dependencies; RANGE_FADE_* of
    // hedra_engine/render/frame.as). hedra_engine/render/cull.as applies Godot's rule.
    rangeBegin: f32 = 0;
    rangeBeginMargin: f32 = 0;
    rangeEnd: f32 = 0;
    rangeEndMargin: f32 = 0;
    rangeFadeMode: i32 = 0;
    // Milestone 19: gi_mode (0 disabled, 1 static, 2 dynamic: GI_MODE_* of
    // hedra_engine/render/lightmap/data.as) and gi_lightmap_texel_scale.
    giMode: i32 = 1;
    giLightmapTexelScale: f32 = 1;
    // Milestone 20: Godot's VisualInstance3D.layers (bit k: layer k + 1),
    // which reflection probes capture and reflect by (DrawItem.layers).
    layers: i32 = 1;
    // Hedra's emerge (not Godot's): how far the geometry has come out of a
    // fog in `emergeColor` (sRGB, as the environment's fog_light_color),
    // 0 not at all (nothing drawn) to 1 wholly (drawn as before). In
    // between, surface.wgsl's `emerge_reveal` shows it pixel by pixel along
    // a noise fixed in world space, each pixel first in the fog's colour,
    // then clearing to its own; its shadow and SSAO follow the pixels
    // shown. Nothing moves: a game's reveal sets it from 0 to 1 over time.
    emerge: f32 = 1;
    emergeColor: Vec4 = Vec4(0, 0, 0, 1);
    // Hedra's fade (not Godot's): the geometry's shown colour (lit, as the
    // lit shading draws it, emission included) drawn `fade` of the way (0
    // to 1) toward `fadeColor` (sRGB, as the environment's
    // background_color, and shown as that background is: exposed and tone
    // mapped), so at 1 a piece is exactly a background of that colour. 0
    // draws it as before. A game's memory of a piece where it stands
    // (melting into the background), animated by setting `fade` every
    // frame: nothing is rebuilt and the frame is not planned again
    // (surface.wgsl's `item_fade`).
    fade: f32 = 0;
    fadeColor: Vec4 = Vec4(0, 0, 0, 1);

    constructor(className: string, name: string) {
        super(className, name);
    }

    readFields(): void {
        super.readFields();
        this.emerge = this.f32Prop("emerge", 1);
        this.emergeColor = this.colorProp("emerge_color", Vec4(0, 0, 0, 1));
        this.fade = this.f32Prop("fade", 0);
        this.fadeColor = this.colorProp("fade_color", Vec4(0, 0, 0, 1));
        this.giMode = this.i32Prop("gi_mode", 1);
        this.giLightmapTexelScale = this.f32Prop("gi_lightmap_texel_scale", 1);
        this.layers = this.i32Prop("layers", 1);
        this.castShadow = this.i32Prop("cast_shadow", 1);
        this.rangeBegin = this.f32Prop("visibility_range_begin", 0);
        this.rangeBeginMargin = this.f32Prop("visibility_range_begin_margin", 0);
        this.rangeEnd = this.f32Prop("visibility_range_end", 0);
        this.rangeEndMargin = this.f32Prop("visibility_range_end_margin", 0);
        this.rangeFadeMode = this.i32Prop("visibility_range_fade_mode", 0);
    }
}

export class MeshInstance3D extends GeometryInstance3D {
    mesh: Mesh? = null;
    materialOverride: StandardMaterial3D? = null;
    // Milestone 48 (docs/engine/ANIMATION.md, "Skeletons and imported
    // clips"). The skin of a model's mesh (null: not skinned), and
    // `skeleton`, the path from this node to the Skeleton3D it follows
    // (Godot's default "..": the parent). A skinned mesh whose path finds no
    // Skeleton3D is drawn as its mesh stores it (at bind time).
    skin: ModelSkin? = null;
    skeletonPath: string = "..";
    // Its blend shapes (`blend_shapes/<name>`, ../skeleton/names.as): the
    // names its mesh's morphs carry, in order, and their weights now;
    // `blendVersion` moves whenever a weight changes, so the renderer
    // blends the mesh again only then.
    blendShapeNames: Array<string> = [];
    blendShapeWeights: Array<f32> = [];
    blendVersion: u32 = 0;
    // The weights the model gives (what a `blend_shapes/<name>` property
    // taken away leaves; 0 for a shape it gives none).
    blendShapeRest: Array<f32> = [];
    // Per blend shape, the `blend_shapes/<name>` value readFields applied
    // last (null: none), so that it applies a value only when it is new:
    // readFields runs whenever any property of the node is written (a
    // binding's `visible` each frame), and must not undo the weights a
    // timeline left since.
    private blendApplied: Array<Value?> = [];

    readFields(): void {
        super.readFields();
        const sk = this.value("skeleton");
        this.skeletonPath = sk != null && sk.kind == ValueKind.NodePath ? sk.s : "..";
        this.applyBlendShapeProps();
    }

    // The index of the blend shape property `name` names
    // ("blend_shapes/<shape>"), -1 for none (compared in place: nothing
    // allocated).
    private shapeOfProperty(name: string): i32 {
        const names = this.blendShapeNames;
        const n = BLEND_SHAPES_PREFIX.length;
        for (let k = 0; k < names.length; k++) {
            const shape = unchecked(names[k]);
            if (name.length == n + shape.length && name.endsWith(shape)) return k;
        }
        return -1;
    }

    // Whether `v` is still one of the effective values (by identity).
    private holds(v: Value): bool {
        const vs = this.propValues;
        for (let i = 0; i < vs.length; i++) if (unchecked(vs[i]) === v) return true;
        return false;
    }

    // Applies the `blend_shapes/<name>` properties set since the last call
    // onto the weights, and puts a shape whose property went back to the
    // model's weight. A property naming no blend shape is kept and ignored
    // (the instancer warned: blend-shape-unknown).
    private applyBlendShapeProps(): void {
        const names = this.blendShapeNames;
        if (names.length == 0) return;
        let applied = this.blendApplied;
        if (applied.length != names.length) {
            applied = new Array<Value?>(names.length);
            for (let k = 0; k < names.length; k++) applied[k] = null;
            this.blendApplied = applied;
        }
        const pn = this.propNames;
        const pv = this.propValues;
        for (let i = 0; i < pn.length; i++) {
            const name = unchecked(pn[i]);
            if (!name.startsWith(BLEND_SHAPES_PREFIX)) continue;
            const k = this.shapeOfProperty(name);
            if (k < 0) continue;
            const v = unchecked(pv[i]);
            if (unchecked(applied[k]) === v || !v.isNumber()) continue;
            this.setBlendShapeValue(k, v.asF32());
            applied[k] = v;
        }
        for (let k = 0; k < applied.length; k++) {
            const a = unchecked(applied[k]);
            if (a == null || this.holds(a)) continue;
            applied[k] = null;
            this.setBlendShapeValue(k, k < this.blendShapeRest.length ? this.blendShapeRest[k] : 0);
        }
    }

    // The Skeleton3D `skeletonPath` names from here, or null.
    resolvedSkeleton(): Skeleton3D? {
        const n = this.getNode(this.skeletonPath);
        if (n == null) return null;
        const isSkeleton = n instanceof Skeleton3D;
        return isSkeleton ? n as Skeleton3D : null;
    }

    // Godot's MeshInstance3D blend shape API (for scripts too).
    getBlendShapeCount(): i32 {
        return this.blendShapeNames.length;
    }

    // The index of blend shape `name`, -1 for none.
    findBlendShapeByName(name: string): i32 {
        return this.blendShapeNames.indexOf(name);
    }

    // Blend shape `index`'s weight (0 for an index out of range).
    getBlendShapeValue(index: i32): f32 {
        return index >= 0 && index < this.blendShapeWeights.length ? this.blendShapeWeights[index] : 0;
    }

    // Sets blend shape `index`'s weight (moving blendVersion only when it
    // changes); false for an index out of range.
    setBlendShapeValue(index: i32, weight: f32): bool {
        if (index < 0 || index >= this.blendShapeWeights.length) return false;
        if (this.blendShapeWeights[index] != weight) {
            this.blendShapeWeights[index] = weight;
            this.blendVersion++;
        }
        return true;
    }

    constructor(name: string) {
        super("MeshInstance3D", name);
    }

    setResource(name: string, r: Resource?): void {
        if (name == "mesh") {
            const isMesh = r instanceof Mesh;
            this.mesh = isMesh ? r as Mesh : null;
        } else if (name == "material_override") {
            const isMaterial = r instanceof StandardMaterial3D;
            this.materialOverride = isMaterial ? r as StandardMaterial3D : null;
        } else {
            super.setResource(name, r);
        }
    }
}

// One mesh of a model as a ModelInstance3D draws it: placed relative to
// the node by the product of the transforms up its object chain.
export class ModelPart {
    local: Mat4;
    mesh: ArrayMesh;
    // Every object on the chain is visible in the model.
    visible: bool;

    constructor(local: Mat4, mesh: ArrayMesh, visible: bool) {
        this.local = local;
        this.mesh = mesh;
        this.visible = visible;
    }
}

export class ModelInstance3D extends GeometryInstance3D {
    model: ModelResource? = null;

    constructor(name: string) {
        super("ModelInstance3D", name);
    }

    setResource(name: string, r: Resource?): void {
        if (name == "model") {
            const isModel = r instanceof ModelResource;
            this.model = isModel ? r as ModelResource : null;
        } else {
            super.setResource(name, r);
        }
    }

    // Every mesh object of the model, in the model's order (parents come
    // before their children in ModelResource.objects, so one pass builds
    // each chain from its parent's).
    parts(): Array<ModelPart> {
        const out = new Array<ModelPart>();
        const m = this.model;
        if (m == null) return out;
        const objs = m.objects;
        const chain = new Array<Mat4>();
        const shown = new Array<bool>();
        for (let i = 0; i < objs.length; i++) {
            const o = objs[i];
            const p = o.parent;
            if (p >= 0 && p < i) {
                chain.push(chain[p] * o.local);
                shown.push(shown[p] && o.visible);
            } else {
                chain.push(o.local);
                shown.push(o.visible);
            }
            const mesh = o.mesh;
            if (mesh != null) out.push(new ModelPart(chain[i], mesh, shown[i]));
        }
        return out;
    }

    // Milestone 50: `parts`, into lists the node keeps (the same parts
    // made again in place): allocates nothing once they have grown. For a
    // frame refreshed every frame (../render/adapter.as refreshSceneFrame);
    // the answer is the node's own, read before the next call.
    private keptParts: Array<ModelPart> = [];
    private keptChain: Array<Mat4> = [];
    private keptShown: Array<bool> = [];

    partsKept(): Array<ModelPart> {
        const out = this.keptParts;
        const m = this.model;
        if (m == null) {
            out.length = 0;
            return out;
        }
        const objs = m.objects;
        const chain = this.keptChain;
        const shown = this.keptShown;
        chain.length = 0;
        shown.length = 0;
        let n = 0;
        for (let i = 0; i < objs.length; i++) {
            const o = objs[i];
            const p = o.parent;
            if (p >= 0 && p < i) {
                chain.push(chain[p] * o.local);
                shown.push(shown[p] && o.visible);
            } else {
                chain.push(o.local);
                shown.push(o.visible);
            }
            const mesh = o.mesh;
            if (mesh == null) continue;
            if (n < out.length) {
                const part = out[n];
                part.local = chain[i];
                part.mesh = mesh;
                part.visible = shown[i];
            } else {
                out.push(new ModelPart(chain[i], mesh, shown[i]));
            }
            n++;
        }
        out.length = n;
        return out;
    }
}

// Draws its MultiMesh's mesh once per instance, placed by the instance's
// transform relative to the node (milestone 13; GPU instancing).
export class MultiMeshInstance3D extends GeometryInstance3D {
    multimesh: MultiMesh? = null;

    constructor(name: string) {
        super("MultiMeshInstance3D", name);
    }

    setResource(name: string, r: Resource?): void {
        if (name == "multimesh") {
            this.multimesh = r != null && r.className() == "MultiMesh" ? r as MultiMesh : null;
        } else {
            super.setResource(name, r);
        }
    }
}

export class Camera3D extends SceneNode {
    current: bool = false;
    // Degrees, along the axis keepAspect names.
    fov: f32 = 75;
    near: f32 = 0.05;
    far: f32 = 4000;
    // 0 perspective, 1 orthogonal.
    projection: i32 = 0;
    size: f32 = 1;
    // 0 keep_width, 1 keep_height.
    keepAspect: i32 = 1;
    // A model's camera (model_nodes.as sets it; it is no property): fov and
    // size measure the longer side of the picture, as Hedra draws the
    // camera, whatever keepAspect says. keep_aspect 0, the model's value,
    // is the same for a landscape picture only.
    majorAxis: bool = false;
    // Milestone 62: Godot's attributes (depth of field and exposure; null:
    // the WorldEnvironment's camera_attributes).
    attributes: CameraAttributesPractical? = null;

    constructor(name: string) {
        super("Camera3D", name);
    }

    setResource(name: string, r: Resource?): void {
        if (name == "attributes") {
            const isAttributes = r instanceof CameraAttributesPractical;
            this.attributes = isAttributes ? r as CameraAttributesPractical : null;
        } else {
            super.setResource(name, r);
        }
    }

    readFields(): void {
        super.readFields();
        this.current = this.boolProp("current", false);
        this.fov = this.f32Prop("fov", 75);
        this.near = this.f32Prop("near", 0.05);
        this.far = this.f32Prop("far", 4000);
        this.projection = this.i32Prop("projection", 0);
        this.size = this.f32Prop("size", 1);
        this.keepAspect = this.i32Prop("keep_aspect", 1);
    }
}

// DirectionalLight3D, OmniLight3D and SpotLight3D (className tells them
// apart). `range` and `attenuation` are omni_* or spot_*; a directional
// light has neither, nor the spot angles, and keeps the defaults below.
export class Light3D extends SceneNode {
    // sRGB, straight alpha.
    color: Vec4 = Vec4(1, 1, 1, 1);
    energy: f32 = 1;
    // Scales the light's specular highlights (Godot's light_specular).
    specular: f32 = 0.5;
    shadow: bool = false;
    range: f32 = 5;
    attenuation: f32 = 1;
    // Degrees: the cone's half angle.
    spotAngle: f32 = 45;
    spotAngleAttenuation: f32 = 1;
    // The shadow (shadow_*; directional_shadow_* for a directional light,
    // which the others keep at these defaults). The field defaults are
    // Godot's Light3D's; readFields reads each class's own biases (classdb
    // declares them per light class, as Godot's defaults differ).
    shadowBias: f32 = 0.1;
    shadowNormalBias: f32 = 1;
    shadowBlur: f32 = 1;
    shadowOpacity: f32 = 1;
    // 0 orthogonal, 1 two splits, 2 four splits.
    directionalShadowMode: i32 = 2;
    // directional_shadow_split_1, _2, _3: fractions of shadowMaxDistance.
    shadowSplits: Vec3 = Vec3(0.1, 0.2, 0.5);
    shadowFadeStart: f32 = 0.8;
    shadowMaxDistance: f32 = 100;
    // Directional only: the sun disc's size in degrees as a procedural sky
    // draws it (light_angular_distance; 0 for the other lights).
    angularDistance: f32 = 0;
    // Milestone 19: light_bake_mode (0 disabled, 1 static, 2 dynamic:
    // LIGHT_BAKE_* of hedra_engine/render/frame.as), light_size (metres) and
    // light_indirect_energy.
    bakeMode: i32 = 2;
    size: f32 = 0;
    indirectEnergy: f32 = 1;
    // Milestone 37: light_volumetric_fog_energy (what it gives fog volumes
    // and the volumetric fog).
    fogEnergy: f32 = 1;

    constructor(className: string, name: string) {
        super(className, name);
    }

    readFields(): void {
        super.readFields();
        this.bakeMode = this.i32Prop("light_bake_mode", 2);
        this.size = this.f32Prop("light_size", 0);
        this.indirectEnergy = this.f32Prop("light_indirect_energy", 1);
        this.fogEnergy = this.f32Prop("light_volumetric_fog_energy", 1);
        this.color = this.colorProp("light_color", Vec4(1, 1, 1, 1));
        this.energy = this.f32Prop("light_energy", 1);
        this.specular = this.f32Prop("light_specular", 0.5);
        this.shadow = this.boolProp("shadow_enabled", false);
        this.shadowBlur = this.f32Prop("shadow_blur", 1);
        this.shadowOpacity = this.f32Prop("shadow_opacity", 1);
        // (value() falls back to the class's own default: the fallbacks
        // here are never used by the three light classes.)
        this.shadowBias = this.f32Prop("shadow_bias", 0.1);
        this.shadowNormalBias = this.f32Prop("shadow_normal_bias", 1);
        if (this.className == "DirectionalLight3D") {
            this.angularDistance = this.f32Prop("light_angular_distance", 0);
            this.directionalShadowMode = this.i32Prop("directional_shadow_mode", 2);
            this.shadowSplits = Vec3(
                this.f32Prop("directional_shadow_split_1", 0.1),
                this.f32Prop("directional_shadow_split_2", 0.2),
                this.f32Prop("directional_shadow_split_3", 0.5),
            );
            this.shadowFadeStart = this.f32Prop("directional_shadow_fade_start", 0.8);
            this.shadowMaxDistance = this.f32Prop("directional_shadow_max_distance", 100);
        }
        if (this.className == "OmniLight3D") {
            this.range = this.f32Prop("omni_range", 5);
            this.attenuation = this.f32Prop("omni_attenuation", 1);
        } else if (this.className == "SpotLight3D") {
            this.range = this.f32Prop("spot_range", 5);
            this.attenuation = this.f32Prop("spot_attenuation", 1);
            this.spotAngle = this.f32Prop("spot_angle", 45);
            this.spotAngleAttenuation = this.f32Prop("spot_angle_attenuation", 1);
        }
    }
}

export class WorldEnvironment extends SceneNode {
    environment: Environment? = null;
    // Milestone 62: Godot's camera_attributes (the cameras' without their
    // own).
    cameraAttributes: CameraAttributesPractical? = null;

    constructor(name: string) {
        super("WorldEnvironment", name, false);
    }

    setResource(name: string, r: Resource?): void {
        if (name == "environment") {
            const isEnvironment = r instanceof Environment;
            this.environment = isEnvironment ? r as Environment : null;
        } else if (name == "camera_attributes") {
            const isAttributes = r instanceof CameraAttributesPractical;
            this.cameraAttributes = isAttributes ? r as CameraAttributesPractical : null;
        } else {
            super.setResource(name, r);
        }
    }
}

export class Marker3D extends SceneNode {
    gizmoExtents: f32 = 0.25;

    constructor(name: string) {
        super("Marker3D", name);
    }

    readFields(): void {
        super.readFields();
        this.gizmoExtents = this.f32Prop("gizmo_extents", 0.25);
    }
}

// Milestone 19: a LightmapGI (docs/formats/RSCN.md, "LightmapGI"): the
// bake's settings, which the CLI's `bake` reads (../bake/bake.as), and its
// bake, `light_data`, which the adapter draws (../render/lightmap.as).
// Colours are as written (sRGB, straight alpha).
export class LightmapGI extends SceneNode {
    quality: i32 = 1;
    bounces: i32 = 3;
    bounceIndirectEnergy: f32 = 1;
    directional: bool = false;
    useTextureForBounces: bool = true;
    interior: bool = false;
    useDenoiser: bool = true;
    denoiserStrength: f32 = 0.1;
    denoiserRange: i32 = 10;
    bias: f32 = 0.0005;
    texelScale: f32 = 1;
    maxTextureSize: i32 = 16384;
    lightmapTexelSize: f32 = 0.2;
    environmentMode: i32 = 1;
    environmentCustomSky: Sky? = null;
    environmentCustomColor: Vec4 = Vec4(1, 1, 1, 1);
    environmentCustomEnergy: f32 = 1;
    generateProbesSubdiv: i32 = 2;
    lightData: LightmapGIData? = null;

    constructor(name: string) {
        super("LightmapGI", name);
    }

    readFields(): void {
        super.readFields();
        this.quality = this.i32Prop("quality", 1);
        this.bounces = this.i32Prop("bounces", 3);
        this.bounceIndirectEnergy = this.f32Prop("bounce_indirect_energy", 1);
        this.directional = this.boolProp("directional", false);
        this.useTextureForBounces = this.boolProp("use_texture_for_bounces", true);
        this.interior = this.boolProp("interior", false);
        this.useDenoiser = this.boolProp("use_denoiser", true);
        this.denoiserStrength = this.f32Prop("denoiser_strength", 0.1);
        this.denoiserRange = this.i32Prop("denoiser_range", 10);
        this.bias = this.f32Prop("bias", 0.0005);
        this.texelScale = this.f32Prop("texel_scale", 1);
        this.maxTextureSize = this.i32Prop("max_texture_size", 16384);
        this.lightmapTexelSize = this.f32Prop("lightmap_texel_size", 0.2);
        this.environmentMode = this.i32Prop("environment_mode", 1);
        this.environmentCustomColor = this.colorProp("environment_custom_color", Vec4(1, 1, 1, 1));
        this.environmentCustomEnergy = this.f32Prop("environment_custom_energy", 1);
        this.generateProbesSubdiv = this.i32Prop("generate_probes_subdiv", 2);
    }

    setResource(name: string, r: Resource?): void {
        if (name == "light_data") {
            const isData = r instanceof LightmapGIData;
            this.lightData = isData ? r as LightmapGIData : null;
        } else if (name == "environment_custom_sky") {
            const isSky = r instanceof Sky;
            this.environmentCustomSky = isSky ? r as Sky : null;
        } else {
            super.setResource(name, r);
        }
    }
}

// Milestone 19: a LightmapProbe, a point where the bake measures light for
// what is not lightmapped. Its place is all it has.
export class LightmapProbe extends SceneNode {
    constructor(name: string) {
        super("LightmapProbe", name);
    }
}

// Milestone 20: a ReflectionProbe (docs/formats/RSCN.md,
// "ReflectionProbe"): Godot's properties, which the adapter puts on the
// frame (../render/probes.as) and the CLI's `bake` captures by
// (../bake/probes.as), and its capture, `probe_data`. Colours are as written
// (sRGB, straight alpha); sizes in metres along the node's axes.
export class ReflectionProbe extends SceneNode {
    // 0 once, 1 always (PROBE_UPDATE_* of hedra_engine/render/probe/data.as).
    updateMode: i32 = 0;
    intensity: f32 = 1;
    blendDistance: f32 = 1;
    maxDistance: f32 = 0;
    size: Vec3 = Vec3(20, 20, 20);
    originOffset: Vec3 = Vec3(0, 0, 0);
    boxProjection: bool = false;
    interior: bool = false;
    enableShadows: bool = false;
    cullMask: i32 = 1048575;
    reflectionMask: i32 = 1048575;
    // 0 disabled, 1 environment, 2 constant_color (PROBE_AMBIENT_*).
    ambientMode: i32 = 1;
    ambientColor: Vec4 = Vec4(0, 0, 0, 1);
    ambientColorEnergy: f32 = 1;
    probeData: ReflectionProbeData? = null;

    constructor(name: string) {
        super("ReflectionProbe", name);
    }

    readFields(): void {
        super.readFields();
        this.updateMode = this.i32Prop("update_mode", 0);
        this.intensity = this.f32Prop("intensity", 1);
        this.blendDistance = this.f32Prop("blend_distance", 1);
        this.maxDistance = this.f32Prop("max_distance", 0);
        const sz = this.value("size");
        this.size = sz != null && sz.kind == ValueKind.Vector3 ? sz.vec3() : Vec3(20, 20, 20);
        const off = this.value("origin_offset");
        this.originOffset = off != null && off.kind == ValueKind.Vector3 ? off.vec3() : Vec3(0, 0, 0);
        this.boxProjection = this.boolProp("box_projection", false);
        this.interior = this.boolProp("interior", false);
        this.enableShadows = this.boolProp("enable_shadows", false);
        this.cullMask = this.i32Prop("cull_mask", 1048575);
        this.reflectionMask = this.i32Prop("reflection_mask", 1048575);
        this.ambientMode = this.i32Prop("ambient_mode", 1);
        this.ambientColor = this.colorProp("ambient_color", Vec4(0, 0, 0, 1));
        this.ambientColorEnergy = this.f32Prop("ambient_color_energy", 1);
    }

    setResource(name: string, r: Resource?): void {
        if (name == "probe_data") {
            const isData = r instanceof ReflectionProbeData;
            this.probeData = isData ? r as ReflectionProbeData : null;
        } else {
            super.setResource(name, r);
        }
    }
}

// Milestone 16: an ArtboardSprite3D (docs/formats/RSCN.md, "ArtboardSprite3D";
// ../classdb.as has Godot's SpriteBase3D properties it takes). The quad it
// draws, its billboard turn and its material are the adapter's
// (../render/sprites.as, ../render/billboard.as); here are the fields.
export class ArtboardSprite3D extends GeometryInstance3D {
    texture: ArtboardTexture? = null;
    centered: bool = true;
    // Texture pixels, x right, y up.
    offset: Vec2 = Vec2(0, 0);
    flipH: bool = false;
    flipV: bool = false;
    // sRGB, straight alpha.
    modulate: Vec4 = Vec4(1, 1, 1, 1);
    pixelSize: f32 = 0.01;
    // 0 x, 1 y, 2 z (billboard.as SPRITE_AXIS_*).
    axis: i32 = 2;
    // 0 disabled, 1 enabled, 2 fixed_y (billboard.as BILLBOARD_*).
    billboard: i32 = 0;
    transparent: bool = true;
    shaded: bool = false;
    doubleSided: bool = true;
    noDepthTest: bool = false;
    // 0 disabled, 1 discard, 2 opaque_prepass, 3 alpha_hash.
    alphaCut: i32 = 0;
    alphaScissorThreshold: f32 = 0.5;

    constructor(name: string) {
        super("ArtboardSprite3D", name);
    }

    readFields(): void {
        super.readFields();
        this.centered = this.boolProp("centered", true);
        const o = this.value("offset");
        this.offset = o != null && o.kind == ValueKind.Vector2 ? o.vec2() : Vec2(0, 0);
        this.flipH = this.boolProp("flip_h", false);
        this.flipV = this.boolProp("flip_v", false);
        this.modulate = this.colorProp("modulate", Vec4(1, 1, 1, 1));
        this.pixelSize = this.f32Prop("pixel_size", 0.01);
        this.axis = this.i32Prop("axis", 2);
        this.billboard = this.i32Prop("billboard", 0);
        this.transparent = this.boolProp("transparent", true);
        this.shaded = this.boolProp("shaded", false);
        this.doubleSided = this.boolProp("double_sided", true);
        this.noDepthTest = this.boolProp("no_depth_test", false);
        this.alphaCut = this.i32Prop("alpha_cut", 0);
        this.alphaScissorThreshold = this.f32Prop("alpha_scissor_threshold", 0.5);
    }

    setResource(name: string, r: Resource?): void {
        if (name == "texture") {
            const isArtboard = r instanceof ArtboardTexture;
            this.texture = isArtboard ? r as ArtboardTexture : null;
        } else {
            super.setResource(name, r);
        }
    }
}

// Milestone 27: Godot's Timer (docs/formats/RSCN.md, "Timer"), a node
// that is not 3D: it counts `waitTime` seconds down while the scene plays
// and emits `timeout` (the script runtime ticks it: ../script/timer.as).
// The fields are the properties as the scene set them, then whatever a
// script sets.
export class TimerNode extends SceneNode {
    waitTime: f64 = 1;
    oneShot: bool = false;
    autostart: bool = false;
    paused: bool = false;
    // The seconds left until the next timeout (0 when stopped).
    timeLeft: f64 = 0;
    // Whether it was made ready (an autostart timer starts then, once).
    readied: bool = false;
    private running: bool = false;

    constructor(name: string) {
        super("Timer", name, false);
    }

    readFields(): void {
        super.readFields();
        const w = this.value("wait_time");
        this.waitTime = w != null && w.isNumber() ? w.asF64() : 1;
        this.oneShot = this.boolProp("one_shot", false);
        this.autostart = this.boolProp("autostart", false);
        this.paused = this.boolProp("paused", false);
    }

    // Starts (or restarts) the count from `seconds` when it is more than 0,
    // which becomes the wait time, else from the wait time. A wait time
    // that is not more than 0 starts nothing (false), as Godot refuses it.
    start(seconds: f64 = -1): bool {
        if (seconds > 0) this.waitTime = seconds;
        if (!(this.waitTime > 0)) return false;
        this.timeLeft = this.waitTime;
        this.running = true;
        return true;
    }

    stop(): void {
        this.running = false;
        this.timeLeft = 0;
    }

    isStopped(): bool {
        return !this.running;
    }
}

// Milestone 31: interaction (docs/formats/RSCN.md, "Interaction"): Godot's
// collision objects, their shapes and rays, without a physics simulation.
// The fields are the properties as the scene set them, then whatever a
// script sets; what overlaps, what the pointer is over and what a ray hits
// are written by the run time's interaction world
// (../interaction/world.as, ../runtime/feature_interaction.as) while the
// scene plays, and read by scripts through Godot's methods. A tool's tree
// (render, inspect, the editor) has no world playing: its areas overlap
// nothing and its rays hit nothing until something casts them.

// A layer number from 1 to 32 as its bit (0 outside the range).
function layerBit(layer: i32): u32 {
    return layer >= 1 && layer <= 32 ? <u32>1 << <u32>(layer - 1) : 0;
}

// A 32-bit layer mask as the scene writes it (an int: 1, 4294967295).
function maskOf(v: Value?, fallback: u32): u32 {
    return v != null && v.kind == ValueKind.Int ? <u32>v.i : fallback;
}

// Godot's CollisionObject3D: the base of Area3D and StaticBody3D. Its
// shapes are its CollisionShape3D children, in child order: a shape's
// index there is Godot's shape index (`shape_idx`).
export class CollisionObject3D extends SceneNode {
    collisionLayer: u32 = 1;
    collisionMask: u32 = 1;
    inputRayPickable: bool = true;
    inputCaptureOnDrag: bool = false;
    // Its index in the objects of the interaction world that last rebuilt
    // over it (../interaction/world.as checks it: a node may be in two
    // worlds, the editor's and a played tree's), so that an area's shapes
    // are found without a scan. -1: none yet.
    worldIndex: i32 = -1;

    constructor(className: string, name: string) {
        super(className, name);
    }

    readFields(): void {
        super.readFields();
        this.collisionLayer = maskOf(this.value("collision_layer"), 1);
        this.collisionMask = maskOf(this.value("collision_mask"), 1);
        this.inputRayPickable = this.boolProp("input_ray_pickable", true);
        this.inputCaptureOnDrag = this.boolProp("input_capture_on_drag", false);
    }

    // Godot's set_collision_layer_value: layer 1 to 32 on or off.
    setCollisionLayerValue(layer: i32, on: bool): void {
        const b = layerBit(layer);
        this.collisionLayer = on ? this.collisionLayer | b : this.collisionLayer & ~b;
    }

    getCollisionLayerValue(layer: i32): bool {
        return (this.collisionLayer & layerBit(layer)) != 0;
    }

    setCollisionMaskValue(layer: i32, on: bool): void {
        const b = layerBit(layer);
        this.collisionMask = on ? this.collisionMask | b : this.collisionMask & ~b;
    }

    getCollisionMaskValue(layer: i32): bool {
        return (this.collisionMask & layerBit(layer)) != 0;
    }

    // Its CollisionShape3D children in child order (Godot's shape owners;
    // a new array: not for every frame).
    shapeNodes(): Array<CollisionShape3D> {
        const out = new Array<CollisionShape3D>();
        for (let i = 0; i < this.children.length; i++) {
            const c = this.children[i];
            const isShape = c instanceof CollisionShape3D;
            if (isShape) out.push(c as CollisionShape3D);
        }
        return out;
    }
}

// Godot's StaticBody3D: a body that moves only when something moves it.
export class StaticBody3D extends CollisionObject3D {
    constructor(name: string) {
        super("StaticBody3D", name);
    }
}

// Godot's Area3D. The overlap lists are the interaction world's, in the
// order the bodies and areas entered, kept and changed in place (so read
// them, do not keep or change them): Godot's get_overlapping_bodies()
// answers a new array each call, which here would allocate every frame.
export class Area3D extends CollisionObject3D {
    monitoring: bool = true;
    monitorable: bool = true;
    overlappingBodies: Array<SceneNode> = [];
    overlappingAreas: Array<Area3D> = [];

    constructor(name: string) {
        super("Area3D", name);
    }

    readFields(): void {
        super.readFields();
        this.monitoring = this.boolProp("monitoring", true);
        this.monitorable = this.boolProp("monitorable", true);
    }

    // Godot's set_monitoring: off, the next frame empties the lists and
    // emits body_exited and area_exited for what was in them, as Godot's.
    setMonitoring(on: bool): void {
        this.monitoring = on;
    }

    setMonitorable(on: bool): void {
        this.monitorable = on;
    }

    getOverlappingBodies(): Array<SceneNode> {
        return this.overlappingBodies;
    }

    getOverlappingAreas(): Array<Area3D> {
        return this.overlappingAreas;
    }

    hasOverlappingBodies(): bool {
        return this.overlappingBodies.length > 0;
    }

    hasOverlappingAreas(): bool {
        return this.overlappingAreas.length > 0;
    }

    overlapsBody(n: SceneNode): bool {
        for (let i = 0; i < this.overlappingBodies.length; i++) if (this.overlappingBodies[i] === n) return true;
        return false;
    }

    overlapsArea(n: SceneNode): bool {
        for (let i = 0; i < this.overlappingAreas.length; i++) if (<SceneNode>this.overlappingAreas[i] === n) return true;
        return false;
    }
}

// Godot's CollisionShape3D: its parent's shape, placed by its transform.
export class CollisionShape3D extends SceneNode {
    shape: Shape3D? = null;
    disabled: bool = false;

    constructor(name: string) {
        super("CollisionShape3D", name);
    }

    readFields(): void {
        super.readFields();
        this.disabled = this.boolProp("disabled", false);
    }

    setResource(name: string, r: Resource?): void {
        if (name == "shape") {
            const isShape = r instanceof Shape3D;
            this.shape = isShape ? r as Shape3D : null;
        } else {
            super.setResource(name, r);
        }
    }

    // Godot's set_disabled.
    setDisabled(on: bool): void {
        this.disabled = on;
    }

    // The CollisionObject3D it gives its shape to (its parent), or null.
    owner3d(): CollisionObject3D? {
        const p = this.parent;
        if (p == null) return null;
        const isObject = p instanceof CollisionObject3D;
        return isObject ? p as CollisionObject3D : null;
    }

    // Its index among its parent's shapes (Godot's shape index), -1 when
    // its parent is no CollisionObject3D.
    shapeIndex(): i32 {
        const p = this.parent;
        if (p == null) return -1;
        const isObject = p instanceof CollisionObject3D;
        if (!isObject) return -1;
        let k = 0;
        for (let i = 0; i < p.children.length; i++) {
            const c = p.children[i];
            if (c === this) return k;
            const isShape = c instanceof CollisionShape3D;
            if (isShape) k++;
        }
        return -1;
    }
}

// Godot's RayCast3D: a ray from the node's origin to target_position (its
// own space), cast every frame while the scene plays (the interaction
// feature calls forceRaycastUpdate each frame), and on demand. Colours
// are as written (sRGB, straight alpha).
export class RayCast3D extends SceneNode {
    enabled: bool = true;
    excludeParent: bool = true;
    targetPosition: Vec3 = Vec3(0, -1, 0);
    collisionMask: u32 = 1;
    hitFromInside: bool = false;
    hitBackFaces: bool = true;
    collideWithAreas: bool = false;
    collideWithBodies: bool = true;
    debugColor: Vec4 = Vec4(0, 0, 0, 1);
    debugThickness: i32 = 2;
    // The last cast's answer (Godot's is_colliding, get_collider, ...).
    colliding: bool = false;
    collider: SceneNode? = null;
    colliderShape: i32 = -1;
    collisionPoint: Vec3 = Vec3(0, 0, 0);
    collisionNormal: Vec3 = Vec3(0, 0, 0);
    collisionFaceIndex: i32 = -1;
    // Godot's add_exception: objects never hit.
    exceptions: Array<SceneNode> = [];
    // The query it casts with, kept: casting allocates nothing.
    private query: PhysicsRayQueryParameters3D? = null;

    constructor(name: string) {
        super("RayCast3D", name);
    }

    readFields(): void {
        super.readFields();
        this.enabled = this.boolProp("enabled", true);
        this.excludeParent = this.boolProp("exclude_parent", true);
        const t = this.value("target_position");
        this.targetPosition = t != null && t.kind == ValueKind.Vector3 ? t.vec3() : Vec3(0, -1, 0);
        this.collisionMask = maskOf(this.value("collision_mask"), 1);
        this.hitFromInside = this.boolProp("hit_from_inside", false);
        this.hitBackFaces = this.boolProp("hit_back_faces", true);
        this.collideWithAreas = this.boolProp("collide_with_areas", false);
        this.collideWithBodies = this.boolProp("collide_with_bodies", true);
        this.debugColor = this.colorProp("debug_shape_custom_color", Vec4(0, 0, 0, 1));
        this.debugThickness = this.i32Prop("debug_shape_thickness", 2);
    }

    // Godot's set_enabled: turning a ray off forgets its last hit, so a
    // disabled ray answers isColliding() false rather than a stale hit.
    setEnabled(on: bool): void {
        this.enabled = on;
        if (!on) this.clearHit();
    }

    // The answer of a cast that hit nothing.
    clearHit(): void {
        this.colliding = false;
        this.collider = null;
        this.colliderShape = -1;
        this.collisionFaceIndex = -1;
    }

    setTargetPosition(p: Vec3): void {
        this.targetPosition = p;
    }

    isColliding(): bool {
        return this.colliding;
    }

    getCollider(): SceneNode? {
        return this.collider;
    }

    getColliderShape(): i32 {
        return this.colliderShape;
    }

    getCollisionPoint(): Vec3 {
        return this.collisionPoint;
    }

    getCollisionNormal(): Vec3 {
        return this.collisionNormal;
    }

    getCollisionFaceIndex(): i32 {
        return this.collisionFaceIndex;
    }

    addException(n: SceneNode): void {
        if (!this.exceptions.includes(n)) this.exceptions.push(n);
    }

    removeException(n: SceneNode): void {
        const i = this.exceptions.indexOf(n);
        if (i >= 0) this.exceptions.splice(i, 1);
    }

    clearExceptions(): void {
        this.exceptions.length = 0;
    }

    // Godot's force_raycast_update: casts now, from where the node is, in
    // its live tree's space (outside one, or while not enabled, nothing is
    // hit). Allocates nothing once its query has grown to its exceptions.
    // `space`: the space to cast in instead (the run time's interaction
    // feature gives its world, which serves a tree whose nodes no script
    // runtime made live).
    forceRaycastUpdate(space: PhysicsDirectSpaceState3D? = null): void {
        this.clearHit();
        if (!this.enabled) return;
        let sp = space;
        if (sp == null) {
            const w = this.getWorld3D();
            if (w == null) return;
            sp = w.directSpaceState;
        }
        let q = this.query;
        if (q == null) {
            q = new PhysicsRayQueryParameters3D();
            this.query = q;
        }
        const g = this.global();
        q.from = g.wAxis.truncate();
        q.to = g.transformPoint3(this.targetPosition);
        q.collisionMask = this.collisionMask;
        q.collideWithAreas = this.collideWithAreas;
        q.collideWithBodies = this.collideWithBodies;
        q.hitFromInside = this.hitFromInside;
        q.hitBackFaces = this.hitBackFaces;
        const ex = q.exclude;
        ex.length = 0;
        for (let i = 0; i < this.exceptions.length; i++) ex.push(this.exceptions[i]);
        const p = this.parent;
        if (this.excludeParent && p != null) {
            const isObject = p instanceof CollisionObject3D;
            if (isObject) ex.push(p);
        }
        const hit = sp.intersectRay(q);
        if (hit == null) return;
        this.colliding = true;
        this.collider = hit.collider;
        this.colliderShape = hit.shape;
        this.collisionPoint = hit.position;
        this.collisionNormal = hit.normal;
        this.collisionFaceIndex = hit.faceIndex;
    }
}

// Milestone 32: paths (docs/formats/RSCN.md, "Paths"), Godot's Path3D and
// PathFollow3D. A Path3D holds a Curve3D and hears its changes (Godot
// connects the curve's `changed`), placing its PathFollow3D children again;
// a PathFollow3D's local transform is written by updateTransform from its
// progress along its parent's curve (../path/follow.as), whenever its
// fields or the curve change and when it is added under a Path3D, as
// Godot's update_transform. Its transform as the scene declared it is
// overwritten then, its scale kept, as Godot does.
//
// Ported to Rive's model: a PathFollow3D's fields are its properties. Each
// setter (a script's, and through ../binding/apply.as every binding,
// timeline, state machine and tween) writes the property's Value too, the
// node's own (SceneNode.setWrittenProp: made once, then set in place), so
// that readFields, which any later write of another of its properties
// runs, reads back where the follower is rather than where the file put
// it. `progress_ratio` is not stored (classdb's `derived`): it is
// progress / the curve's baked length, read and written through progress.

// The argument curve_changed is emitted with (none).
const NO_SIGNAL_VALUE: Value = Value.nil();

// What a Path3D hears its curve through (a node cannot extend
// CurveListener).
class PathCurveLink extends CurveListener {
    path: Path3D;

    constructor(path: Path3D) {
        super();
        this.path = path;
    }

    curveChanged(c: Curve3D): void {
        this.path.curveChanged();
    }
}

export class Path3D extends SceneNode {
    curve: Curve3D? = null;
    private link: PathCurveLink? = null;

    constructor(name: string) {
        super("Path3D", name);
    }

    setResource(name: string, r: Resource?): void {
        super.setResource(name, r);
        if (name != "curve") return;
        const isCurve = r instanceof Curve3D;
        this.setCurve(isCurve ? r as Curve3D : null);
    }

    getCurve(): Curve3D? {
        return this.curve;
    }

    // Godot's set_curve: the old curve is no longer heard, the new one is,
    // and the followers are placed on it.
    setCurve(c: Curve3D?): void {
        const old = this.curve;
        let link = this.link;
        if (link == null) {
            link = new PathCurveLink(this);
            this.link = link;
        }
        if (old != null && old !== c) old.removeListener(link);
        this.curve = c;
        if (c != null) c.addListener(link);
        this.curveChanged();
    }

    // Godot's _curve_changed: every PathFollow3D child placed again, and
    // curve_changed emitted while the scene plays.
    curveChanged(): void {
        for (let i = 0; i < this.children.length; i++) {
            const ch = unchecked(this.children[i]);
            const isFollower = ch instanceof PathFollow3D;
            if (isFollower) (ch as PathFollow3D).updateTransform();
        }
        const tree = this.liveTree;
        if (tree != null) tree.emitSignal(this, "curve_changed", NO_SIGNAL_VALUE);
    }
}

export class PathFollow3D extends SceneNode {
    progress: f64 = 0;
    hOffset: f64 = 0;
    vOffset: f64 = 0;
    rotationMode: i32 = ROTATION_XYZ;
    useModelFront: bool = false;
    cubic: bool = true;
    loop: bool = true;
    tiltEnabled: bool = true;

    constructor(name: string) {
        super("PathFollow3D", name);
    }

    // The fields as the scene set them. `progress` is kept as written, not
    // wrapped: Godot sets it before the node enters the tree, where there
    // is no path to wrap it by (only sampling holds it to the curve).
    readFields(): void {
        super.readFields();
        this.progress = this.f64Prop("progress", 0);
        this.hOffset = this.f64Prop("h_offset", 0);
        this.vOffset = this.f64Prop("v_offset", 0);
        this.rotationMode = this.i32Prop("rotation_mode", ROTATION_XYZ);
        this.useModelFront = this.boolProp("use_model_front", false);
        this.cubic = this.boolProp("cubic_interp", true);
        this.loop = this.boolProp("loop", true);
        this.tiltEnabled = this.boolProp("tilt_enabled", true);
        this.updateTransform();
    }

    private f64Prop(name: string, fallback: f64): f64 {
        const v = this.value(name);
        return v != null && v.isNumber() ? v.asF64() : fallback;
    }

    // Its parent when that is a Path3D (Godot's `path`), else null.
    pathNode(): Path3D? {
        const p = this.parent;
        const isPath = p instanceof Path3D;
        return isPath ? p as Path3D : null;
    }

    // The curve it follows, when its parent is a Path3D with one.
    curve(): Curve3D? {
        const p = this.pathNode();
        return p != null ? p.curve : null;
    }

    // Godot's update_transform: placed on the curve, when it has a parent
    // Path3D whose curve has a baked length; left where it is otherwise.
    updateTransform(): void {
        const c = this.curve();
        if (c == null) return;
        if (c.getBakedLength() == 0) return;
        this.local = pathFollowLocal(c, this.progress, this.hOffset, this.vOffset, this.rotationMode, this.cubic,
            this.tiltEnabled, this.useModelFront, signedScale(this.local));
    }

    // Godot's set_progress: under a Path3D with a curve, wrapped round the
    // baked length with loop (a progress that is not 0 but wraps to 0 is
    // the length: the end, not the start), held to 0 ... length without.
    setProgress(p: f64): void {
        if (!isFinite(p) || this.progress == p) return;
        let at = p;
        const c = this.curve();
        if (c != null) {
            const length = <f64>c.getBakedLength();
            if (this.loop && length != 0) {
                let m = p % length;
                if (m < 0) m += length;
                if (!isZeroApprox(p) && isZeroApprox(m)) m = length;
                at = m;
            } else {
                at = p < 0 ? 0 : (p > length ? length : p);
            }
        }
        this.progress = at;
        this.keepNumber("progress", at);
        this.updateTransform();
    }

    // The node's own Value of property `name` set to `x` (made the first
    // time; see the header).
    private keepNumber(name: string, x: f64): void {
        const own = this.writtenProp(name, ValueKind.Float);
        if (own != null) own.f = x;
        else this.setWrittenProp(name, Value.float(x));
    }

    private keepBool(name: string, b: bool): void {
        const own = this.writtenProp(name, ValueKind.Bool);
        if (own != null) own.b = b;
        else this.setWrittenProp(name, Value.bool(b));
    }

    private keepInt(name: string, i: i32): void {
        const own = this.writtenProp(name, ValueKind.Int);
        if (own != null) own.i = <i64>i;
        else this.setWrittenProp(name, Value.int(<i64>i));
    }

    getProgress(): f64 {
        return this.progress;
    }

    // Godot's set_progress_ratio: progress as a share of the baked length
    // (nothing without a parent Path3D with a curve of some length: Godot
    // refuses it with an error).
    setProgressRatio(r: f64): void {
        const c = this.curve();
        if (c == null) return;
        const length = <f64>c.getBakedLength();
        if (length == 0) return;
        this.setProgress(r * length);
    }

    getProgressRatio(): f64 {
        const c = this.curve();
        if (c == null) return 0;
        const length = <f64>c.getBakedLength();
        return length != 0 ? this.progress / length : 0;
    }

    setHOffset(v: f64): void {
        if (!isFinite(v) || this.hOffset == v) return;
        this.hOffset = v;
        this.keepNumber("h_offset", v);
        this.updateTransform();
    }

    getHOffset(): f64 {
        return this.hOffset;
    }

    setVOffset(v: f64): void {
        if (!isFinite(v) || this.vOffset == v) return;
        this.vOffset = v;
        this.keepNumber("v_offset", v);
        this.updateTransform();
    }

    getVOffset(): f64 {
        return this.vOffset;
    }

    setRotationMode(mode: i32): void {
        if (this.rotationMode == mode || mode < ROTATION_NONE || mode > ROTATION_ORIENTED) return;
        this.rotationMode = mode;
        this.keepInt("rotation_mode", mode);
        this.updateTransform();
    }

    getRotationMode(): i32 {
        return this.rotationMode;
    }

    setUseModelFront(on: bool): void {
        if (this.useModelFront == on) return;
        this.useModelFront = on;
        this.keepBool("use_model_front", on);
        this.updateTransform();
    }

    isUsingModelFront(): bool {
        return this.useModelFront;
    }

    // Godot's set_cubic_interpolation, which (as Godot's) does not place
    // the node again: the next change does.
    setCubicInterpolation(on: bool): void {
        if (this.cubic == on) return;
        this.cubic = on;
        this.keepBool("cubic_interp", on);
    }

    getCubicInterpolation(): bool {
        return this.cubic;
    }

    setLoop(on: bool): void {
        if (this.loop == on) return;
        this.loop = on;
        this.keepBool("loop", on);
        this.updateTransform();
    }

    hasLoop(): bool {
        return this.loop;
    }

    setTiltEnabled(on: bool): void {
        if (this.tiltEnabled == on) return;
        this.tiltEnabled = on;
        this.keepBool("tilt_enabled", on);
        this.updateTransform();
    }

    isTiltEnabled(): bool {
        return this.tiltEnabled;
    }
}

// Godot's Math::is_zero_approx for real_t (float): |x| < CMP_EPSILON.
function isZeroApprox(x: f64): bool {
    return Math.abs(x) < 0.00001;
}

// Milestone 67b: `c`, just taken out from under `from`, keeps what the
// subtrees a script instanced around it hold (each ancestor's
// heldResources, from `from` up): it may be added elsewhere and outlive
// them (Godot's instantiate, remove_child, add_child elsewhere, then
// queue_free of the rest), and Godot's nodes each hold their own Ref, so
// what it draws must not be freed with the rest. It takes a reference of
// its own to each (a holder of its own, closed when it is freed), which
// holds a little more than it draws, but frees all of it once both are
// gone. A node being freed (queued) takes nothing, and nothing is made
// when no ancestor holds anything: the tools and most trees.
// The holder is the instance's too (ResourceLoader.adopt, through the
// tree `from` is or was last in), so that it goes with the instance if
// the node is never freed.
function keepHeldOf(from: SceneNode, c: SceneNode): void {
    let n: SceneNode? = from;
    let tree: SceneTree? = null;
    while (n != null) {
        if (tree == null) tree = n.liveTree != null ? n.liveTree : n.lastTree;
        const h = n.heldResources;
        if (h != null && !h.closed && h.count > 0) {
            let own = c.heldResources;
            if (own == null) {
                own = new ResourceHolder(h.cache);
                c.heldResources = own;
                if (tree != null) tree.loader.adopt(own);
            }
            own.holdAllOf(h);
        }
        n = n.parent;
    }
}

// Marks `n` and its subtree freed (queueFree): they never enter a tree
// again.
//
// Milestone 67b: a subtree a script instanced lets go of what it held
// (PackedSceneRef.instantiate, docs/engine/RESOURCES.md "Lifetimes"):
// freed from the run time's cache once nothing else holds it.
export function markFreed(n: SceneNode): void {
    n.freed = true;
    n.queued = true;
    const h = n.heldResources;
    if (h != null) {
        n.heldResources = null;
        h.close();
    }
    for (let i = 0; i < n.children.length; i++) markFreed(n.children[i]);
}

// Milestone 48: one bone of a Skeleton3D as it runs: its name and parent
// (as the model gave them), its rest and its pose now (local: relative to
// the parent bone, or to the skeleton for a root bone, scene space), and
// its pose in the skeleton's space, worked out on demand
// (Skeleton3D.getBoneGlobalPose).
export class Bone3D {
    name: string;
    parent: i32;
    rest: BonePose;
    pose: BonePose;
    global: Mat4 = MAT4_IDENTITY;
    // The pose the model gives (a copy of `pose` when made): what a
    // `bones/<name>:...` property taken away leaves.
    base: BonePose;

    constructor(name: string, parent: i32, rest: BonePose, pose: BonePose) {
        this.name = name;
        this.parent = parent;
        this.rest = rest;
        this.pose = pose;
        this.base = pose.clone();
    }
}

// The pose fields a Skeleton3D's properties set (Skeleton3D.poseSlots:
// bone * 3 + field).
const POSE_POSITION: i32 = 0;
const POSE_ROTATION: i32 = 1;
const POSE_SCALE: i32 = 2;

// Milestone 48: Godot's Skeleton3D (docs/engine/ANIMATION.md, "Skeletons
// and imported clips"): a model's armature with its bones. A bone's pose is
// set by its properties (`bones/<name>:position`, `:quaternion`, `:scale`,
// ../skeleton/names.as), by a timeline's keys and by scripts; the skinned
// meshes that name it and its BoneAttachment3Ds follow. `poseVersion`
// moves whenever a pose changes, so the bones' global poses are worked out
// again, and the skins' palettes uploaded again, only then.
export class Skeleton3D extends SceneNode {
    bones: Array<Bone3D> = [];
    poseVersion: u32 = 0;
    // The poseVersion the bones' global poses were worked out at (-1 never).
    private globalsAt: i64 = -1;
    // The `bones/<bone>:...` properties readFields applied, by name, with
    // the value applied and the pose field it went to (bone * 3 + POSE_*),
    // so that it applies a value only when it is new: readFields runs
    // whenever any property of the node is written (a binding's `visible`
    // each frame), and must not undo the pose a timeline left since.
    private poseNames: Array<string> = [];
    private poseValues: Array<Value> = [];
    private poseSlots: Array<i32> = [];
    // The `bones/...` properties readFields could not apply (no bone
    // property, no such bone, a value of the wrong kind), with the value
    // last refused, so that it is not parsed again on every call while it
    // stays the same (parsing allocates).
    private refusedNames: Array<string> = [];
    private refusedValues: Array<Value> = [];
    // Set by the timelines while a frame's bone keys are written and not
    // yet followed by the attachments (../anim/scene_anims.as
    // flushQuaternions).
    animPending: bool = false;

    constructor(name: string) {
        super("Skeleton3D", name);
    }

    // Replaces the bones with a model's (each bone at the model's pose),
    // then lays the node's `bones/...` properties over them.
    setBones(bones: Array<ModelBone>): void {
        this.bones = [];
        for (let i = 0; i < bones.length; i++) {
            const b = bones[i];
            this.bones.push(new Bone3D(b.name, b.parent, b.rest.clone(), b.pose.clone()));
        }
        this.poseNames = [];
        this.poseValues = [];
        this.poseSlots = [];
        this.refusedNames = [];
        this.refusedValues = [];
        this.poseVersion++;
        this.applyPoseProps();
        this.syncAttachments();
    }

    readFields(): void {
        super.readFields();
        this.applyPoseProps();
    }

    // Applies the `bones/<bone>:position`, `:quaternion` and `:scale`
    // properties set since the last call onto the bones' poses, and puts a
    // field whose property was taken away back to the model's pose. A name
    // that is no bone property, names no bone (the instancer warned:
    // bone-unknown) or holds a value of the wrong kind (property-type) is
    // kept and ignored. Allocates nothing while no property changed.
    private applyPoseProps(): void {
        if (this.bones.length == 0) return;
        let changed = false;
        const pn = this.propNames;
        const pv = this.propValues;
        for (let i = 0; i < pn.length; i++) {
            const name = unchecked(pn[i]);
            if (!name.startsWith(BONES_PREFIX)) continue;
            const v = unchecked(pv[i]);
            const j = this.poseNames.indexOf(name);
            if (j >= 0 && unchecked(this.poseValues[j]) === v) continue;
            const r = this.refusedNames.indexOf(name);
            if (r >= 0 && unchecked(this.refusedValues[r]) === v) continue;
            const bp = parseBoneProperty(name);
            const b = bp == null || bp.axis >= 0 ? -1 : this.findBone(bp.bone);
            const field = b < 0 ? -1
                : bp!.field == BONE_FIELD_POSITION ? POSE_POSITION : bp!.field == BONE_FIELD_QUATERNION ? POSE_ROTATION : POSE_SCALE;
            if (b < 0 || !this.applyPoseValue(b, field, v)) {
                if (r >= 0) this.refusedValues[r] = v;
                else {
                    this.refusedNames.push(name);
                    this.refusedValues.push(v);
                }
                continue;
            }
            if (r >= 0) {
                this.refusedNames.splice(r, 1);
                this.refusedValues.splice(r, 1);
            }
            changed = true;
            if (j >= 0) {
                this.poseValues[j] = v;
                this.poseSlots[j] = b * 3 + field;
            } else {
                this.poseNames.push(name);
                this.poseValues.push(v);
                this.poseSlots.push(b * 3 + field);
            }
        }
        for (let j = this.poseNames.length - 1; j >= 0; j--) {
            const v = unchecked(this.poseValues[j]);
            let held = false;
            for (let i = 0; i < pv.length && !held; i++) if (unchecked(pv[i]) === v) held = true;
            if (held) continue;
            const slot = unchecked(this.poseSlots[j]);
            const b = slot / 3;
            const base = this.bones[b].base;
            const field = slot % 3;
            if (field == POSE_POSITION) this.setBonePosePosition(b, base.position, false);
            else if (field == POSE_ROTATION) this.setBonePoseRotation(b, base.rotation, false);
            else this.setBonePoseScale(b, base.scale, false);
            this.poseNames.splice(j, 1);
            this.poseValues.splice(j, 1);
            this.poseSlots.splice(j, 1);
            changed = true;
        }
        if (changed) this.syncAttachments();
    }

    // Sets pose field `field` of bone `b` from a property's value; false
    // when the value is not of the field's kind (a Vector3, or a Quaternion
    // for the rotation, normalised; a zero one is the identity).
    private applyPoseValue(b: i32, field: i32, v: Value): bool {
        const n = v.n;
        if (field == POSE_ROTATION) {
            if (v.kind != ValueKind.Quaternion || n.length < 4) return false;
            const len = Math.sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2] + n[3] * n[3]);
            const q = len > 0 ? Quat(<f32>(n[0] / len), <f32>(n[1] / len), <f32>(n[2] / len), <f32>(n[3] / len)) : Quat(0, 0, 0, 1);
            this.setBonePoseRotation(b, q, false);
            return true;
        }
        if (v.kind != ValueKind.Vector3 || n.length < 3) return false;
        const p = Vec3(<f32>n[0], <f32>n[1], <f32>n[2]);
        if (field == POSE_POSITION) this.setBonePosePosition(b, p, false);
        else this.setBonePoseScale(b, p, false);
        return true;
    }

    // Brings every BoneAttachment3D child to its bone's pose now (the
    // renderer and the interaction world read their `local`).
    syncAttachments(): void {
        const cs = this.children;
        for (let i = 0; i < cs.length; i++) {
            const c = unchecked(cs[i]);
            const isAttachment = c instanceof BoneAttachment3D;
            if (isAttachment) (c as BoneAttachment3D).sync();
        }
    }

    // Godot's Skeleton3D API, by bone index (for scripts too).
    getBoneCount(): i32 {
        return this.bones.length;
    }

    // The index of the bone named `name`, -1 for none.
    findBone(name: string): i32 {
        for (let i = 0; i < this.bones.length; i++) if (this.bones[i].name == name) return i;
        return -1;
    }

    // Whether `i` is a bone's index. Every method taking one checks it, as
    // the blend shape methods do: a script's findBone of a name the model
    // does not have gives -1, and must not stop the run time. Getters of
    // no bone give the identity (an empty name, parent -1); setters do
    // nothing.
    hasBone(i: i32): bool {
        return i >= 0 && i < this.bones.length;
    }

    getBoneName(i: i32): string {
        return this.hasBone(i) ? this.bones[i].name : "";
    }

    // -1 for a root bone.
    getBoneParent(i: i32): i32 {
        return this.hasBone(i) ? this.bones[i].parent : -1;
    }

    getBonePosePosition(i: i32): Vec3 {
        return this.hasBone(i) ? this.bones[i].pose.position : Vec3(0, 0, 0);
    }

    getBonePoseRotation(i: i32): Quat {
        return this.hasBone(i) ? this.bones[i].pose.rotation : Quat(0, 0, 0, 1);
    }

    getBonePoseScale(i: i32): Vec3 {
        return this.hasBone(i) ? this.bones[i].pose.scale : Vec3(1, 1, 1);
    }

    // The setters move poseVersion only when the value changes. With
    // `follow` (a script's call), the BoneAttachment3Ds follow at once; the
    // timelines pass false and bring them along once a frame's keys are all
    // written (syncAttachments).
    setBonePosePosition(i: i32, p: Vec3, follow: bool = true): void {
        if (!this.hasBone(i)) return;
        const b = this.bones[i];
        if (b.pose.position == p) return;
        b.pose.position = p;
        this.poseVersion++;
        if (follow) this.syncAttachments();
    }

    setBonePoseRotation(i: i32, q: Quat, follow: bool = true): void {
        if (!this.hasBone(i)) return;
        const b = this.bones[i];
        if (b.pose.rotation == q) return;
        b.pose.rotation = q;
        this.poseVersion++;
        if (follow) this.syncAttachments();
    }

    setBonePoseScale(i: i32, s: Vec3, follow: bool = true): void {
        if (!this.hasBone(i)) return;
        const b = this.bones[i];
        if (b.pose.scale == s) return;
        b.pose.scale = s;
        this.poseVersion++;
        if (follow) this.syncAttachments();
    }

    // Bone `i`'s rest, local (T * R * S).
    getBoneRest(i: i32): Mat4 {
        return this.hasBone(i) ? this.bones[i].rest.matrix() : MAT4_IDENTITY;
    }

    // Bone `i`'s pose now, local (T * R * S).
    getBonePose(i: i32): Mat4 {
        return this.hasBone(i) ? this.bones[i].pose.matrix() : MAT4_IDENTITY;
    }

    // Every bone back to its rest (poseVersion moves only when one was
    // elsewhere: an unchanged pose keeps the palettes).
    resetBonePoses(): void {
        let changed = false;
        for (let i = 0; i < this.bones.length; i++) {
            const b = this.bones[i];
            if (b.pose.position == b.rest.position && b.pose.rotation == b.rest.rotation && b.pose.scale == b.rest.scale) continue;
            b.pose = b.rest.clone();
            changed = true;
        }
        if (!changed) return;
        this.poseVersion++;
        this.syncAttachments();
    }

    // Bone `i`'s pose in the skeleton's space: its parents' poses times its
    // own (all of them worked out once per poseVersion; bones come parents
    // first).
    getBoneGlobalPose(i: i32): Mat4 {
        if (!this.hasBone(i)) return MAT4_IDENTITY;
        if (this.globalsAt != <i64>this.poseVersion) {
            for (let k = 0; k < this.bones.length; k++) {
                const b = this.bones[k];
                b.global = b.parent >= 0 && b.parent < k ? boneGlobal(this.bones[b.parent].global, b.pose) : b.pose.matrix();
            }
            this.globalsAt = <i64>this.poseVersion;
        }
        return this.bones[i].global;
    }
}

// `parent * pose.matrix()` (T * R * S), the same numbers worked out on
// scalars: every bone's global pose is made again each frame a skeleton
// moves, and the Mat4 operators (struct values through the VM) cost about
// 3 microseconds a bone, 0.18 ms of a 60-bone frame
// (tests/skeleton/budget_test.as). A bone's matrices are affine (their
// last row 0 0 0 1), so only the first three rows are multiplied out.
function boneGlobal(parent: Mat4, pose: BonePose): Mat4 {
    const q = pose.rotation;
    const x = q.x, y = q.y, z = q.z, w = q.w;
    const x2 = x + x, y2 = y + y, z2 = z + z;
    const xx = x * x2, xy = x * y2, xz = x * z2, yy = y * y2, yz = y * z2, zz = z * z2;
    const wx = w * x2, wy = w * y2, wz = w * z2;
    const sx = pose.scale.x, sy = pose.scale.y, sz = pose.scale.z;
    // The local matrix's columns (rotation times scale) and translation.
    const l00 = (<f32>1.0 - (yy + zz)) * sx, l10 = (xy + wz) * sx, l20 = (xz - wy) * sx;
    const l01 = (xy - wz) * sy, l11 = (<f32>1.0 - (xx + zz)) * sy, l21 = (yz + wx) * sy;
    const l02 = (xz + wy) * sz, l12 = (yz - wx) * sz, l22 = (<f32>1.0 - (xx + yy)) * sz;
    const t = pose.position;
    const a0 = parent.xAxis, a1 = parent.yAxis, a2 = parent.zAxis, a3 = parent.wAxis;
    return Mat4(
        Vec4(a0.x * l00 + a1.x * l10 + a2.x * l20, a0.y * l00 + a1.y * l10 + a2.y * l20, a0.z * l00 + a1.z * l10 + a2.z * l20, 0),
        Vec4(a0.x * l01 + a1.x * l11 + a2.x * l21, a0.y * l01 + a1.y * l11 + a2.y * l21, a0.z * l01 + a1.z * l11 + a2.z * l21, 0),
        Vec4(a0.x * l02 + a1.x * l12 + a2.x * l22, a0.y * l02 + a1.y * l12 + a2.y * l22, a0.z * l02 + a1.z * l12 + a2.z * l22, 0),
        Vec4(a0.x * t.x + a1.x * t.y + a2.x * t.z + a3.x, a0.y * t.x + a1.y * t.y + a2.y * t.z + a3.y,
            a0.z * t.x + a1.z * t.y + a2.z * t.z + a3.z, 1),
    );
}

// Milestone 48: Godot's BoneAttachment3D: a node that follows a bone of
// the Skeleton3D it is a child of (`bone_name`; `bone_idx` once found), so
// that a prop in a hand moves with the hand. Its own transform is the
// bone's pose in the skeleton's space, kept up to date whenever its
// global transform is read.
//
// It follows by holding the bone's pose in the skeleton's space as its
// `local` (so its global transform is the skeleton's global transform
// times that pose, and everything that walks `local`s up the tree, the
// renderer and the interaction world among them, sees it there): brought
// up to date by sync(), which the skeleton calls when its pose changes
// (a script's setter, a frame of timelines, its properties) and global()
// calls first. Without a Skeleton3D parent, or a bone of that name, it
// stays where its own transform puts it.
export class BoneAttachment3D extends SceneNode {
    boneName: string = "";
    boneIdx: i32 = -1;
    // bone_idx as its property says (-1 unset): the bone followed when
    // bone_name is empty.
    private idxProperty: i32 = -1;
    // What the last sync followed: the skeleton, its poseVersion, the
    // bones array (setBones replaces it) and the bone's index (-1 none).
    private syncedSkeleton: Skeleton3D? = null;
    private syncedAt: i64 = -1;
    private syncedBones: Array<Bone3D>? = null;

    constructor(name: string) {
        super("BoneAttachment3D", name);
    }

    readFields(): void {
        super.readFields();
        const n = this.value("bone_name");
        this.boneName = n != null && (n.kind == ValueKind.StringName || n.kind == ValueKind.String) ? n.s : "";
        this.idxProperty = this.i32Prop("bone_idx", -1);
        this.boneIdx = this.idxProperty;
        // (followed again from the new names, and over the transform this
        // layer may have set)
        this.syncedAt = -1;
        this.sync();
    }

    // The Skeleton3D it follows (its parent), or null.
    skeleton(): Skeleton3D? {
        const p = this.parent;
        if (p == null) return null;
        const isSkeleton = p instanceof Skeleton3D;
        return isSkeleton ? p as Skeleton3D : null;
    }

    // The index of the bone it follows in `sk`: bone_name's, else bone_idx
    // when in range; -1 for none.
    boneIn(sk: Skeleton3D): i32 {
        if (this.boneName.length > 0) {
            // (the bone found last, checked first: no search a frame)
            const had = this.boneIdx;
            if (had >= 0 && had < sk.bones.length && unchecked(sk.bones[had]).name == this.boneName) return had;
            return sk.findBone(this.boneName);
        }
        const i = this.idxProperty;
        return i >= 0 && i < sk.bones.length ? i : -1;
    }

    // Brings `local` to the bone's pose in the skeleton's space when the
    // skeleton's pose moved since; nothing without a skeleton or a bone.
    // Allocates nothing.
    sync(): void {
        const sk = this.skeleton();
        if (sk == null) return;
        if (sk === this.syncedSkeleton && this.syncedAt == <i64>sk.poseVersion && this.syncedBones === sk.bones) return;
        this.syncedSkeleton = sk;
        this.syncedAt = <i64>sk.poseVersion;
        this.syncedBones = sk.bones;
        const i = this.boneIn(sk);
        if (i < 0) return;
        this.boneIdx = i;
        this.local = sk.getBoneGlobalPose(i);
    }

    // The skeleton's global transform times the bone's pose (synced
    // first), or the node's own when it follows no bone.
    global(): Mat4 {
        this.sync();
        return super.global();
    }
}

// Milestone 33: Godot's Decal (docs/formats/RSCN.md, "Decals"; ../classdb.as
// has its properties). The fields are the properties as the scene set
// them, then whatever a binding, a timeline or a script writes; what a
// frame draws of it is the adapter's (../render/decals.as decalDescInto)
// and the renderer's (hedra_engine/render/decal.as). `size` is held to
// DECAL_MIN_SIZE on each axis, as Godot's set_size holds it.
export class Decal extends SceneNode {
    size: Vec3 = Vec3(2, 2, 2);
    // Each a Texture2D (a PNG, or an ArtboardTexture), or null.
    textureAlbedo: Texture2D? = null;
    textureNormal: Texture2D? = null;
    textureOrm: Texture2D? = null;
    textureEmission: Texture2D? = null;
    emissionEnergy: f32 = 1;
    // sRGB, straight alpha.
    modulate: Vec4 = Vec4(1, 1, 1, 1);
    albedoMix: f32 = 1;
    normalFade: f32 = 0;
    upperFade: f32 = 0.3;
    lowerFade: f32 = 0.3;
    distanceFadeEnabled: bool = false;
    distanceFadeBegin: f32 = 40;
    distanceFadeLength: f32 = 10;
    cullMask: i32 = 1048575;

    constructor(name: string) {
        super("Decal", name);
    }

    readFields(): void {
        super.readFields();
        const sz = this.value("size");
        const s = sz != null && sz.kind == ValueKind.Vector3 ? sz.vec3() : Vec3(2, 2, 2);
        this.size = Vec3(
            s.x > DECAL_MIN_SIZE ? s.x : DECAL_MIN_SIZE, s.y > DECAL_MIN_SIZE ? s.y : DECAL_MIN_SIZE,
            s.z > DECAL_MIN_SIZE ? s.z : DECAL_MIN_SIZE);
        this.emissionEnergy = this.f32Prop("emission_energy", 1);
        this.modulate = this.colorProp("modulate", Vec4(1, 1, 1, 1));
        this.albedoMix = this.f32Prop("albedo_mix", 1);
        this.normalFade = this.f32Prop("normal_fade", 0);
        this.upperFade = this.f32Prop("upper_fade", 0.3);
        this.lowerFade = this.f32Prop("lower_fade", 0.3);
        this.distanceFadeEnabled = this.boolProp("distance_fade_enabled", false);
        this.distanceFadeBegin = this.f32Prop("distance_fade_begin", 40);
        this.distanceFadeLength = this.f32Prop("distance_fade_length", 10);
        this.cullMask = this.i32Prop("cull_mask", 1048575);
    }

    setResource(name: string, r: Resource?): void {
        const isTexture = r instanceof Texture2D;
        const t = isTexture ? r as Texture2D : null;
        if (name == "texture_albedo") this.textureAlbedo = t;
        else if (name == "texture_normal") this.textureNormal = t;
        else if (name == "texture_orm") this.textureOrm = t;
        else if (name == "texture_emission") this.textureEmission = t;
        else super.setResource(name, r);
    }

    // The texture of slot `slot` (DECAL_TEXTURE_ALBEDO .. _EMISSION of
    // hedra_engine/render/decal.as: albedo, normal, orm, emission), or null.
    textureAt(slot: i32): Texture2D? {
        if (slot == 0) return this.textureAlbedo;
        if (slot == 1) return this.textureNormal;
        if (slot == 2) return this.textureOrm;
        if (slot == 3) return this.textureEmission;
        return null;
    }
}

// Milestone 34: Godot's SubViewport (a Viewport, which is a Node: no
// transform and no `visible`), the classdb's properties as fields
// (../classdb.as; docs/formats/RSCN.md "Viewports"). `sizeX` and `sizeY`
// are the file's; `width` and `height` the size drawn, each held to 1 ..
// MAX_VIEWPORT_SIDE (the warnings say so: viewport-size). What it draws is
// the scene's side's (../render/viewports.as) and the renderer's
// (hedra_engine/render/viewport.as).
export class SubViewport extends SceneNode {
    // own_world_3d, behind `ownWorld3d`, whose setter says a change to
    // what follows the worlds: the interaction world (the tree root's
    // shapesEpoch, when collision objects or rays are under it: they take
    // part in physics only in the main world) and the probes' filter
    // (ownWorldsEpoch). Allocates nothing.
    private ownWorldNow: bool = false;
    transparentBg: bool = false;
    sizeX: i32 = DEFAULT_VIEWPORT_SIDE;
    sizeY: i32 = DEFAULT_VIEWPORT_SIDE;
    width: i32 = DEFAULT_VIEWPORT_SIDE;
    height: i32 = DEFAULT_VIEWPORT_SIDE;
    // UPDATE_* (hedra_engine/render/viewport.as), Godot's numbers, behind
    // `updateMode`, whose setter counts every write of UPDATE_ONCE into
    // `onceWrites`: Godot takes a new picture at each one, even over
    // `once`, so a script that writes it at each press gets a picture each
    // time (the schedule re-arms `once` on a new count). The file's value
    // (a key, a binding, the Inspector: readFields) counts only when it
    // changes, as those write only a change.
    private modeNow: i32 = UPDATE_WHEN_VISIBLE;
    onceWrites: i32 = 0;

    constructor(name: string) {
        super("SubViewport", name, false);
    }

    get ownWorld3d(): bool {
        return this.ownWorldNow;
    }

    set ownWorld3d(on: bool) {
        if (on == this.ownWorldNow) return;
        this.ownWorldNow = on;
        ownWorldsEpoch++;
        if (holdsInteraction(this)) this.treeRoot().shapesEpoch++;
    }

    get updateMode(): i32 {
        return this.modeNow;
    }

    set updateMode(m: i32) {
        if (m == UPDATE_ONCE) this.onceWrites++;
        this.modeNow = m;
    }

    readFields(): void {
        super.readFields();
        this.ownWorld3d = this.boolProp("own_world_3d", false);
        this.transparentBg = this.boolProp("transparent_bg", false);
        const v = this.value("size");
        const ok = v != null && v.kind == ValueKind.Vector2i && v.n.length >= 2;
        this.sizeX = ok ? f64ToI32(v!.n[0]) : DEFAULT_VIEWPORT_SIDE;
        this.sizeY = ok ? f64ToI32(v!.n[1]) : DEFAULT_VIEWPORT_SIDE;
        this.width = min<i32>(max<i32>(this.sizeX, 1), MAX_VIEWPORT_SIDE);
        this.height = min<i32>(max<i32>(this.sizeY, 1), MAX_VIEWPORT_SIDE);
        const mode = this.i32Prop("render_target_update_mode", UPDATE_WHEN_VISIBLE);
        if (mode != this.modeNow) this.updateMode = mode;
    }
}

// Milestone 35: Godot's CPUParticles3D (../classdb.as; docs/formats/RSCN.md
// "Particles", docs/engine/PARTICLES.md), its properties as fields, read
// again at every write (a key, a binding, a script, the Inspector) without
// allocating: the packed arrays are the effective values' own, never
// copied. What it emits is the simulation's (../particles/sim.as), kept in
// `particles`, made at its first step; what it draws the scene's plan's
// (../render/adapter.as, ../particles/pack.as).
export class CPUParticles3D extends GeometryInstance3D {
    emitting: bool = true;
    // The file's amount, and the amount simulated (clamped to 1 ..
    // MAX_PARTICLE_AMOUNT: the warnings say so, particles-amount).
    amountSet: i32 = 8;
    amount: i32 = 8;
    lifetime: f32 = 1;
    oneShot: bool = false;
    preprocess: f32 = 0;
    speedScale: f32 = 1;
    explosiveness: f32 = 0;
    randomness: f32 = 0;
    lifetimeRandomness: f32 = 0;
    useFixedSeed: bool = false;
    seed: i64 = 0;
    fixedFps: i32 = 0;
    fractDelta: bool = true;
    localCoords: bool = false;
    // DRAW_ORDER_* (../particles/state.as).
    drawOrder: i32 = 0;
    mesh: Mesh? = null;
    // EMISSION_* (../particles/state.as).
    emissionShape: i32 = 0;
    emissionSphereRadius: f32 = 1;
    emissionBoxExtents: Vec3 = Vec3(1, 1, 1);
    // Three numbers a point; four a colour (the values' own arrays).
    emissionPoints: Array<f64> = [];
    emissionNormals: Array<f64> = [];
    emissionColors: Array<f64> = [];
    emissionRingAxis: Vec3 = Vec3(0, 0, 1);
    emissionRingHeight: f32 = 1;
    emissionRingRadius: f32 = 1;
    emissionRingInnerRadius: f32 = 0;
    emissionRingConeAngle: f32 = 90;
    emissionPointsFrom: string = "";
    emissionPointsCount: i32 = 512;
    // particle_flag_align_y and particle_flag_rotate_y.
    flagAlignY: bool = false;
    flagRotateY: bool = false;
    direction: Vec3 = Vec3(1, 0, 0);
    spread: f32 = 45;
    flatness: f32 = 0;
    gravity: Vec3 = Vec3(0, -9.8, 0);
    initialVelocityMin: f32 = 0;
    initialVelocityMax: f32 = 0;
    angularVelocityMin: f32 = 0;
    angularVelocityMax: f32 = 0;
    angularVelocityCurve: Curve? = null;
    dampingMin: f32 = 0;
    dampingMax: f32 = 0;
    dampingCurve: Curve? = null;
    angleMin: f32 = 0;
    angleMax: f32 = 0;
    angleCurve: Curve? = null;
    scaleAmountMin: f32 = 1;
    scaleAmountMax: f32 = 1;
    scaleAmountCurve: Curve? = null;
    splitScale: bool = false;
    scaleCurveX: Curve? = null;
    scaleCurveY: Curve? = null;
    scaleCurveZ: Curve? = null;
    // sRGB, straight alpha.
    color: Vec4 = Vec4(1, 1, 1, 1);
    colorRamp: Gradient? = null;
    colorInitialRamp: Gradient? = null;
    hueVariationMin: f32 = 0;
    hueVariationMax: f32 = 0;
    hueVariationCurve: Curve? = null;
    // The simulation's state (null until its first step).
    particles: ParticleState? = null;
    // restart() calls not yet taken by the simulation (Godot's restart()
    // is at once; the next step takes them, before it moves anything).
    restartRequests: i32 = 0;
    // Of those, the ones that keep the seed (restart(true)).
    restartsKeepingSeed: i32 = 0;
    // The particles' own writes of `emitting` (a one_shot cycle's end,
    // restart()) since the tools' clock last started: the Value effective
    // before the first of them (null: none, the default) and its boolean
    // then (a write in place changes it), and the Value the last one left
    // effective. The tools' clock puts the first back (restoreEmitting),
    // so a second run on the same tree starts from the scene the first
    // started from. References only: nothing is allocated.
    emittingSaved: bool = false;
    emittingPrior: Value? = null;
    emittingPriorBool: bool = true;
    emittingWritten: Value? = null;

    constructor(name: string) {
        super("CPUParticles3D", name);
    }

    // Before the particles write `emitting`: what it was, the first time.
    saveEmitting(): void {
        if (this.emittingSaved) return;
        this.emittingSaved = true;
        this.emittingPrior = this.getProp("emitting");
        this.emittingPriorBool = this.emitting;
    }

    // After the particles wrote it: the Value they left effective.
    wroteEmitting(): void {
        this.emittingWritten = this.getProp("emitting");
    }

    // `emitting` as it was before the particles' first write since the
    // last call, unless something else (a key, a binding, an edit) wrote
    // it since, which is then kept.
    restoreEmitting(): void {
        if (!this.emittingSaved) return;
        this.emittingSaved = false;
        const now = this.getProp("emitting");
        const wrote = this.emittingWritten;
        const prior = this.emittingPrior;
        this.emittingWritten = null;
        this.emittingPrior = null;
        if (now !== wrote) return;
        if (prior == null) this.removeProp("emitting");
        else if (prior !== now) this.setProp("emitting", prior);
        else if (prior.kind == ValueKind.Bool) {
            // (written in place: a key's or a binding's own Value)
            prior.b = this.emittingPriorBool;
            this.propsVersion++;
        }
        this.emitting = this.emittingPriorBool;
    }

    // Godot 4.4's restart(keep_seed = false): every particle gone, the
    // emission from its start (preprocess again), emitting on; with
    // use_fixed_seed off the seed is made again (deterministically, from
    // the restarts so far: ../particles/sim.as) unless `keepSeed`. Taken by
    // the next step.
    restart(keepSeed: bool = false): void {
        this.restartRequests++;
        if (keepSeed) this.restartsKeepingSeed++;
        if (!this.emitting) {
            // Written in place once the node holds a written Value (a
            // one_shot cycle's end left one): a script setting off a burst
            // with restart() each time allocates nothing after the first.
            this.saveEmitting();
            const v = this.writtenProp("emitting", ValueKind.Bool);
            if (v != null) v.b = true;
            else this.setWrittenProp("emitting", Value.bool(true));
            this.wroteEmitting();
        }
        this.emitting = true;
    }

    readFields(): void {
        super.readFields();
        this.emitting = this.boolProp("emitting", true);
        this.amountSet = this.i32Prop("amount", 8);
        this.amount = min<i32>(max<i32>(this.amountSet, 1), MAX_PARTICLE_AMOUNT);
        const life = this.f32Prop("lifetime", 1);
        this.lifetime = life > MIN_PARTICLE_LIFETIME ? life : MIN_PARTICLE_LIFETIME;
        this.oneShot = this.boolProp("one_shot", false);
        this.preprocess = this.f32Prop("preprocess", 0);
        this.speedScale = this.f32Prop("speed_scale", 1);
        this.explosiveness = this.f32Prop("explosiveness", 0);
        this.randomness = this.f32Prop("randomness", 0);
        this.lifetimeRandomness = this.f32Prop("lifetime_randomness", 0);
        this.useFixedSeed = this.boolProp("use_fixed_seed", false);
        const sv = this.value("seed");
        this.seed = sv != null && sv.kind == ValueKind.Int ? sv.i : 0;
        this.fixedFps = this.i32Prop("fixed_fps", 0);
        this.fractDelta = this.boolProp("fract_delta", true);
        this.localCoords = this.boolProp("local_coords", false);
        this.drawOrder = this.i32Prop("draw_order", 0);
        this.emissionShape = this.i32Prop("emission_shape", 0);
        this.emissionSphereRadius = this.f32Prop("emission_sphere_radius", 1);
        this.emissionBoxExtents = this.vec3Prop("emission_box_extents", Vec3(1, 1, 1));
        this.emissionPoints = this.numbersProp("emission_points");
        this.emissionNormals = this.numbersProp("emission_normals");
        this.emissionColors = this.numbersProp("emission_colors");
        this.emissionRingAxis = this.vec3Prop("emission_ring_axis", Vec3(0, 0, 1));
        this.emissionRingHeight = this.f32Prop("emission_ring_height", 1);
        this.emissionRingRadius = this.f32Prop("emission_ring_radius", 1);
        this.emissionRingInnerRadius = this.f32Prop("emission_ring_inner_radius", 0);
        this.emissionRingConeAngle = this.f32Prop("emission_ring_cone_angle", 90);
        const from = this.value("emission_points_from");
        this.emissionPointsFrom = from != null && from.kind == ValueKind.NodePath ? from.s : "";
        this.emissionPointsCount = min<i32>(max<i32>(this.i32Prop("emission_points_count", 512), 1), MAX_EMISSION_POINTS);
        this.flagAlignY = this.boolProp("particle_flag_align_y", false);
        this.flagRotateY = this.boolProp("particle_flag_rotate_y", false);
        this.direction = this.vec3Prop("direction", Vec3(1, 0, 0));
        this.spread = this.f32Prop("spread", 45);
        this.flatness = this.f32Prop("flatness", 0);
        this.gravity = this.vec3Prop("gravity", Vec3(0, -9.8, 0));
        this.initialVelocityMin = this.f32Prop("initial_velocity_min", 0);
        this.initialVelocityMax = this.f32Prop("initial_velocity_max", 0);
        this.angularVelocityMin = this.f32Prop("angular_velocity_min", 0);
        this.angularVelocityMax = this.f32Prop("angular_velocity_max", 0);
        this.dampingMin = this.f32Prop("damping_min", 0);
        this.dampingMax = this.f32Prop("damping_max", 0);
        this.angleMin = this.f32Prop("angle_min", 0);
        this.angleMax = this.f32Prop("angle_max", 0);
        this.scaleAmountMin = this.f32Prop("scale_amount_min", 1);
        this.scaleAmountMax = this.f32Prop("scale_amount_max", 1);
        this.splitScale = this.boolProp("split_scale", false);
        this.color = this.colorProp("color", Vec4(1, 1, 1, 1));
        this.hueVariationMin = this.f32Prop("hue_variation_min", 0);
        this.hueVariationMax = this.f32Prop("hue_variation_max", 0);
    }

    setResource(name: string, r: Resource?): void {
        const isCurve = r instanceof Curve;
        const c = isCurve ? r as Curve : null;
        const isGradient = r instanceof Gradient;
        const g = isGradient ? r as Gradient : null;
        if (name == "mesh") {
            const isMesh = r instanceof Mesh;
            this.mesh = isMesh ? r as Mesh : null;
        } else if (name == "angular_velocity_curve") this.angularVelocityCurve = c;
        else if (name == "damping_curve") this.dampingCurve = c;
        else if (name == "angle_curve") this.angleCurve = c;
        else if (name == "scale_amount_curve") this.scaleAmountCurve = c;
        else if (name == "scale_curve_x") this.scaleCurveX = c;
        else if (name == "scale_curve_y") this.scaleCurveY = c;
        else if (name == "scale_curve_z") this.scaleCurveZ = c;
        else if (name == "hue_variation_curve") this.hueVariationCurve = c;
        else if (name == "color_ramp") this.colorRamp = g;
        else if (name == "color_initial_ramp") this.colorInitialRamp = g;
        else super.setResource(name, r);
    }

    private vec3Prop(name: string, fallback: Vec3): Vec3 {
        const v = this.value(name);
        return v != null && v.kind == ValueKind.Vector3 ? v.vec3() : fallback;
    }

    // A packed property's numbers (the value's own array; empty when unset).
    private numbersProp(name: string): Array<f64> {
        const v = this.value(name);
        return v != null && (v.kind == ValueKind.PackedVector3Array || v.kind == ValueKind.PackedColorArray) ? v.n : NO_PACKED;
    }
}

// Milestone 36: Godot 4.4's AudioStreamPlayer3D (../classdb.as;
// docs/formats/RSCN.md "Audio", docs/engine/AUDIO.md), its properties as
// fields, read again at every write (a key, a binding, a script, the
// Inspector) without allocating. Its playbacks are `audio`
// (../audio/state.as), made at the first play; the clock moves them
// (../audio/clock.as), the feature plays them through the runtime's audio
// (../runtime/feature_audio.as) and sets the two outputs.
//
// `playing` is Godot's: written true (by a key, a binding, a script, the
// Inspector, or the file) it plays from the start, written false it stops;
// a change of the property's value is what counts (playingProp is the
// value last read), so a binding or a key that writes the same value again
// does nothing. When the last playback ends the node writes it false
// itself, in place (Godot's `playing` reads false then), and a key or a
// binding that writes it true again plays again, as in Godot.
export class AudioStreamPlayer3D extends SceneNode {
    stream: AudioStream? = null;
    // ATTENUATION_* (../audio/attenuation.as), Godot's numbers.
    attenuationModel: i32 = 0;
    volumeDb: f32 = 0;
    unitSize: f32 = 10;
    maxDb: f32 = 3;
    pitchScale: f32 = 1;
    playing: bool = false;
    autoplay: bool = false;
    streamPaused: bool = false;
    maxDistance: f32 = 0;
    // The file's max_polyphony, and the one played (1 to
    // MAX_AUDIO_POLYPHONY: audio-polyphony says so).
    maxPolyphonySet: i32 = 1;
    maxPolyphony: i32 = 1;
    panningStrength: f32 = 1;
    bus: string = "Master";
    areaMask: i32 = 1;
    playbackType: i32 = 0;
    emissionAngleEnabled: bool = false;
    emissionAngleDegrees: f32 = 45;
    emissionAngleFilterAttenuationDb: f32 = -12;
    attenuationFilterCutoffHz: f32 = 5000;
    attenuationFilterDb: f32 = -24;
    dopplerTracking: i32 = 0;
    // The outputs (listener_volume_db, listener_pan): what the listener
    // heard of it at the last advance, the feature's (or the tools'
    // clock's) to set.
    listenerVolumeDb: f32 = AUDIO_SILENT_DB;
    listenerPan: f32 = 0;
    // Its playbacks (null until the first play).
    audio: AudioPlayback? = null;
    // The value of the `playing` property readFields last saw (see the
    // header), and whether the property was ever read (a file's true plays
    // at the start, as autoplay: the clock's first advance).
    playingProp: bool = false;
    // Plays the clock owes from the property and autoplay at its next
    // advance before anything moves (play() itself is at once).
    startRequested: bool = false;

    constructor(name: string) {
        super("AudioStreamPlayer3D", name);
    }

    // Godot's play(from_position = 0.0): a new playback from `from`
    // seconds (the oldest stopped past max_polyphony); `playing` reads true.
    // Without a stream it does nothing, as Godot's (no playback is made).
    play(from: f64 = 0): void {
        if (this.stream == null) return;
        let a = this.audio;
        if (a == null) {
            a = new AudioPlayback();
            this.audio = a;
        }
        a.play(from, this.maxPolyphony);
        this.showPlaying(true);
    }

    // Godot's stop(): every playback ends, without `finished`.
    stop(): void {
        const a = this.audio;
        if (a != null) a.stopAll();
        this.startRequested = false;
        this.showPlaying(false);
    }

    // Godot's seek(to_position): while anything plays, stop() then
    // play(to), so one playback is left, from `to` (every playback moved
    // there would sound as many copies in phase). `playing` stays true and
    // no `finished` is emitted.
    seek(to: f64): void {
        const a = this.audio;
        if (a == null || a.activeCount() == 0) return;
        a.stopAll();
        a.play(to, this.maxPolyphony);
    }

    // Godot's get_playback_position(): the newest playback's, in seconds.
    getPlaybackPosition(): f64 {
        const a = this.audio;
        return a != null ? a.position() : 0;
    }

    // Godot's has_stream_playback(): whether anything plays.
    hasStreamPlayback(): bool {
        const a = this.audio;
        return a != null && a.activeCount() > 0;
    }

    // The clock, when the last playback ended: `playing` reads false.
    endedAll(): void {
        this.showPlaying(false);
    }

    // `playing` written to `on` by the node itself (no edge: playingProp
    // follows), in place once the node holds a written Value.
    private showPlaying(on: bool): void {
        this.playing = on;
        this.playingProp = on;
        if (this.boolProp("playing", false) == on) return;
        const own = this.writtenProp("playing", ValueKind.Bool);
        if (own != null) own.b = on;
        else this.setWrittenProp("playing", Value.bool(on));
    }

    readFields(): void {
        super.readFields();
        this.attenuationModel = this.i32Prop("attenuation_model", 0);
        this.volumeDb = this.f32Prop("volume_db", 0);
        this.unitSize = this.f32Prop("unit_size", 10);
        this.maxDb = this.f32Prop("max_db", 3);
        this.pitchScale = this.f32Prop("pitch_scale", 1);
        this.autoplay = this.boolProp("autoplay", false);
        this.streamPaused = this.boolProp("stream_paused", false);
        this.maxDistance = this.f32Prop("max_distance", 0);
        this.maxPolyphonySet = this.i32Prop("max_polyphony", 1);
        this.maxPolyphony = min<i32>(max<i32>(this.maxPolyphonySet, 1), MAX_AUDIO_POLYPHONY);
        this.panningStrength = this.f32Prop("panning_strength", 1);
        const bus = this.value("bus");
        this.bus = bus != null && (bus.kind == ValueKind.String || bus.kind == ValueKind.StringName) ? bus.s : "Master";
        this.areaMask = this.i32Prop("area_mask", 1);
        this.playbackType = this.i32Prop("playback_type", 0);
        this.emissionAngleEnabled = this.boolProp("emission_angle_enabled", false);
        this.emissionAngleDegrees = this.f32Prop("emission_angle_degrees", 45);
        this.emissionAngleFilterAttenuationDb = this.f32Prop("emission_angle_filter_attenuation_db", -12);
        this.attenuationFilterCutoffHz = this.f32Prop("attenuation_filter_cutoff_hz", 5000);
        this.attenuationFilterDb = this.f32Prop("attenuation_filter_db", -24);
        this.dopplerTracking = this.i32Prop("doppler_tracking", 0);
        // (last: the edge of `playing`, see the header)
        const on = this.boolProp("playing", false);
        if (on != this.playingProp) {
            this.playingProp = on;
            if (on) this.startRequested = true;
            else this.stop();
        }
        this.playing = on || this.hasStreamPlayback();
    }

    setResource(name: string, r: Resource?): void {
        if (name == "stream") {
            const isStream = r instanceof AudioStream;
            const s = isStream ? r as AudioStream : null;
            // (Godot's set_stream stops what plays: a new stream starts
            // with a play)
            if (s !== this.stream && this.hasStreamPlayback()) this.stop();
            this.stream = s;
        } else super.setResource(name, r);
    }
}

// Milestone 36: Godot's AudioListener3D: the players are heard from the
// listener its viewport has (../audio/listener.as), chosen as Godot's
// ENTER_WORLD chooses it when a scene loads (each listener entering with
// `current` on, or the first one to enter, is made current in turn): the
// last listener in tree order whose `current` is on, else the first one,
// else the viewport's camera. A SubViewport's listeners are its own.
// Godot's make_current() and clear_current() write `current`:
// make_current() takes the place of its viewport's other current
// listeners (they read `current` false after); clear_current() on the one
// heard makes the viewport's next listener current (Godot's
// _audio_listener_3d_make_next_current: the first other one in tree
// order), or, with none, leaves the viewport to its camera (`heldOff`).
export class AudioListener3D extends SceneNode {
    current: bool = false;
    // Cleared while it was heard: not taken as the first listener when
    // none is current, as Godot's viewport, left without a listener then,
    // hears from its camera. A make_current() clears it.
    heldOff: bool = false;

    constructor(name: string) {
        super("AudioListener3D", name);
    }

    makeCurrent(): void {
        clearListeners(listenerViewport(this), this, true);
        this.heldOff = false;
        this.writeCurrent(true);
    }

    clearCurrent(): void {
        const top = listenerViewport(this);
        const heard = heardListener(top) === this;
        this.writeCurrent(false);
        if (!heard) return;
        this.heldOff = true;
        const next = nextListener(top, this);
        if (next != null) next.makeCurrent();
    }

    // Godot's is_current(): whether its viewport hears from it (the first
    // listener of a scene with none current is, `current` off or not).
    isCurrent(): bool {
        return heardListener(listenerViewport(this)) === this;
    }

    // `current` written off, nothing else changed (make_current() on
    // another listener of its viewport).
    writeCurrentOff(): void {
        this.writeCurrent(false);
    }

    private writeCurrent(on: bool): void {
        this.current = on;
        if (this.boolProp("current", false) == on) return;
        const own = this.writtenProp("current", ValueKind.Bool);
        if (own != null) own.b = on;
        else this.setWrittenProp("current", Value.bool(on));
    }

    readFields(): void {
        super.readFields();
        this.current = this.boolProp("current", false);
    }
}

// The node whose listeners `n`'s viewport has: the nearest SubViewport
// above it, else the tree's root.
export function listenerViewport(n: SceneNode): SceneNode {
    let top: SceneNode = n;
    let up = n.parent;
    while (up != null) {
        top = up;
        const isViewport = up instanceof SubViewport;
        if (isViewport) return up;
        up = up.parent;
    }
    return top;
}

// The listener the viewport of `top` (a tree's root or a SubViewport)
// hears from (see AudioListener3D): the last AudioListener3D under it in
// tree order with `current` on, else the first not held off, else null
// (its camera hears). A SubViewport below `top` is a viewport of its own:
// its listeners are left out. Allocates nothing.
export function heardListener(top: SceneNode): AudioListener3D? {
    heardLast = null;
    heardFirst = null;
    gatherListeners(top, top);
    const last = heardLast;
    return last != null ? last : heardFirst;
}

let heardLast: AudioListener3D? = null;
let heardFirst: AudioListener3D? = null;

function gatherListeners(n: SceneNode, top: SceneNode): void {
    const isViewport = n instanceof SubViewport;
    if (isViewport && n !== top) return;
    const isListener = n instanceof AudioListener3D;
    if (isListener) {
        const l = n as AudioListener3D;
        if (l.current) heardLast = l;
        else if (heardFirst == null && !l.heldOff) heardFirst = l;
    }
    for (let i = 0; i < n.children.length; i++) gatherListeners(unchecked(n.children[i]), top);
}

// The first AudioListener3D of `top`'s viewport in tree order but `not`,
// or null. Allocates nothing.
function nextListener(top: SceneNode, not: AudioListener3D): AudioListener3D? {
    heardFirst = null;
    firstListenerBut(top, top, not);
    return heardFirst;
}

function firstListenerBut(n: SceneNode, top: SceneNode, not: AudioListener3D): void {
    if (heardFirst != null) return;
    const isViewport = n instanceof SubViewport;
    if (isViewport && n !== top) return;
    const isListener = n instanceof AudioListener3D;
    if (isListener && n !== not) {
        heardFirst = n as AudioListener3D;
        return;
    }
    for (let i = 0; i < n.children.length; i++) firstListenerBut(unchecked(n.children[i]), top, not);
}

// Every current AudioListener3D of `n`'s viewport (`n` itself included)
// but `keep` cleared (AudioListener3D.makeCurrent; a SubViewport below
// `n` is left alone). Allocates nothing.
function clearListeners(n: SceneNode, keep: AudioListener3D, top: bool): void {
    const isViewport = n instanceof SubViewport;
    if (isViewport && !top) return;
    const isListener = n instanceof AudioListener3D;
    if (isListener && n !== keep && (n as AudioListener3D).current) (n as AudioListener3D).writeCurrentOff();
    for (let i = 0; i < n.children.length; i++) clearListeners(unchecked(n.children[i]), keep, false);
}

// Milestone 37: Godot's FogVolume (../classdb.as; docs/formats/RSCN.md
// "Fog volumes", docs/engine/FOG.md). The fields are the properties as the
// scene set them, then whatever a binding, a timeline or a script writes;
// `size` is held to 0 or more on each axis, as Godot's set_size holds it.
// What a frame draws of it is the adapter's (../render/fog_volumes.as) and
// the renderer's (hedra_engine/render/fog_volume.as).
export class FogVolume extends SceneNode {
    size: Vec3 = Vec3(2, 2, 2);
    // FOG_SHAPE_* of hedra_engine/render/fog_volume.as (Godot's
    // RenderingServer.FogVolumeShape): 0 ellipsoid, 1 cone, 2 cylinder, 3
    // box, 4 world.
    shape: i32 = 3;
    // A FogMaterial, or another material (drawn as none, warned), or null
    // (Godot's default fog: FOG_DEFAULT_* of ../resource/fog_material.as).
    material: Resource? = null;

    constructor(name: string) {
        super("FogVolume", name);
    }

    readFields(): void {
        super.readFields();
        const sz = this.value("size");
        const s = sz != null && sz.kind == ValueKind.Vector3 ? sz.vec3() : Vec3(2, 2, 2);
        this.size = Vec3(s.x > 0 ? s.x : 0, s.y > 0 ? s.y : 0, s.z > 0 ? s.z : 0);
        this.shape = this.i32Prop("shape", 3);
    }

    setResource(name: string, r: Resource?): void {
        if (name == "material") this.material = r;
        else super.setResource(name, r);
    }

    // Its material when it is a FogMaterial (null otherwise).
    fogMaterial(): FogMaterial? {
        const m = this.material;
        const isFog = m instanceof FogMaterial;
        return isFog ? m as FogMaterial : null;
    }
}

// Milestone 37: Godot's OccluderInstance3D (../classdb.as;
// docs/formats/RSCN.md "Occlusion culling", docs/engine/OCCLUSION.md). Its
// occluder's triangles are the culling's (hedra_engine/render/occlusion.as,
// through ../render/occluders.as); hidden (visible off, in the tree), it
// occludes nothing.
export class OccluderInstance3D extends SceneNode {
    occluder: Occluder3D? = null;
    // Godot's u32 mask, kept in an i64 (the file's 4294967295).
    bakeMask: i64 = 4294967295;
    bakeSimplificationDistance: f32 = 0.1;

    constructor(name: string) {
        super("OccluderInstance3D", name);
    }

    readFields(): void {
        super.readFields();
        const m = this.value("bake_mask");
        this.bakeMask = m != null && m.isNumber() ? m.asI64() & 0xffffffff : 4294967295;
        const d = this.f32Prop("bake_simplification_distance", 0.1);
        this.bakeSimplificationDistance = d > 0 ? d : 0;
    }

    setResource(name: string, r: Resource?): void {
        if (name == "occluder") {
            const isOccluder = r instanceof Occluder3D;
            this.occluder = isOccluder ? r as Occluder3D : null;
        } else super.setResource(name, r);
    }
}

// Milestone 63: Godot 4.4's navigation nodes (../classdb.as;
// docs/formats/RSCN.md "Navigation", docs/engine/NAVIGATION.md). The fields
// are the properties as the scene set them, then whatever a binding, a
// timeline or a script writes. The map they make is ../navigation/map.as's
// (joined again when a region, a link or a transform changes: each sync
// compares the fields and the global transforms it kept); an agent's path
// following and avoidance are ../navigation/agent.as's and
// avoidance.as's, run by the run time's navigation feature and the tools'
// clock.

// A position property, or `fallback` (a Vector3 only).
function vec3Of(v: Value?, fallback: Vec3): Vec3 {
    return v != null && v.kind == ValueKind.Vector3 ? v.vec3() : fallback;
}

// Godot's NavigationRegion3D: its NavigationMesh's polygons, placed by its
// global transform, are a part of its world's navigation map.
export class NavigationRegion3D extends SceneNode {
    navigationMesh: NavigationMesh? = null;
    enabled: bool = true;
    useEdgeConnections: bool = true;
    navigationLayers: u32 = 1;
    enterCost: f32 = 0;
    travelCost: f32 = 1;
    // The value of `navigation_layers` readFields last saw.
    private layersProp: u32 = 1;
    private fieldsRead: bool = false;

    constructor(name: string) {
        super("NavigationRegion3D", name);
    }

    readFields(): void {
        super.readFields();
        this.enabled = this.boolProp("enabled", true);
        this.useEdgeConnections = this.boolProp("use_edge_connections", true);
        // (taken only when the property changed, so that a write of
        // another property does not undo a script's
        // setNavigationLayerValue)
        const layers = maskOf(this.value("navigation_layers"), 1);
        if (!this.fieldsRead || layers != this.layersProp) {
            this.layersProp = layers;
            this.navigationLayers = layers;
        }
        this.fieldsRead = true;
        const e = this.f32Prop("enter_cost", 0);
        this.enterCost = e > 0 ? e : 0;
        const t = this.f32Prop("travel_cost", 1);
        this.travelCost = t > 0 ? t : 0;
    }

    setResource(name: string, r: Resource?): void {
        if (name == "navigation_mesh") {
            const isMesh = r instanceof NavigationMesh;
            this.navigationMesh = isMesh ? r as NavigationMesh : null;
        } else super.setResource(name, r);
    }

    // Godot's get_navigation_layer_value(layer) and its setter (layer 1 to
    // 32).
    getNavigationLayerValue(layer: i32): bool {
        return (this.navigationLayers & layerBit(layer)) != 0;
    }

    setNavigationLayerValue(layer: i32, on: bool): void {
        const b = layerBit(layer);
        this.navigationLayers = on ? this.navigationLayers | b : this.navigationLayers & ~b;
    }
}

// The map of a node's tree (an empty one outside a live tree, or when no
// navigation serves it), for the nodes' getNavigationMap().
const NO_MAP = new NavigationMap();

function mapOf(n: SceneNode): NavigationMap {
    const t = n.liveTree;
    return t != null ? t.world.navigationMap : NO_MAP;
}

// Godot's NavigationAgent3D: a Node (not a Node3D) that steers its parent
// Node3D over the navigation map (see ../navigation/agent_state.as for
// what it keeps and how its methods are answered).
export class NavigationAgent3D extends SceneNode {
    targetPosition: Vec3 = Vec3(0, 0, 0);
    pathDesiredDistance: f32 = 1;
    targetDesiredDistance: f32 = 1;
    pathHeightOffset: f32 = 0;
    pathMaxDistance: f32 = 5;
    navigationLayers: u32 = 1;
    pathfindingAlgorithm: i32 = 0;
    pathPostprocessing: i32 = 0;
    pathMetadataFlags: i32 = 7;
    simplifyPath: bool = false;
    simplifyEpsilon: f32 = 0;
    avoidanceEnabled: bool = false;
    velocity: Vec3 = Vec3(0, 0, 0);
    height: f32 = 1;
    radius: f32 = 0.5;
    neighborDistance: f32 = 50;
    maxNeighbors: i32 = 10;
    timeHorizonAgents: f32 = 1;
    timeHorizonObstacles: f32 = 0;
    maxSpeed: f32 = 10;
    use3dAvoidance: bool = false;
    keepYVelocity: bool = true;
    avoidanceLayers: u32 = 1;
    avoidanceMask: u32 = 1;
    avoidancePriority: f32 = 1;
    debugEnabled: bool = false;
    debugUseCustom: bool = false;
    debugPathCustomColor: Vec4 = Vec4(1, 1, 1, 1);
    debugPathCustomPointSize: f32 = 4;
    driveParent: bool = false;
    driveTurnSpeed: f32 = 720;
    // The output current_speed, the navigation's to set (the others are
    // the state's: distance_to_target, is_target_reached and
    // is_navigation_finished).
    currentSpeed: f32 = 0;
    // What it keeps between frames.
    nav: NavAgentState = new NavAgentState();
    // The value of `velocity` readFields last saw: a write of the property
    // (a binding, a key) submits it, as Godot's set_velocity does.
    private velocityProp: Vec3 = Vec3(0, 0, 0);
    // The values of `target_position` and `navigation_layers` readFields
    // last saw, for the same reason.
    private targetProp: Vec3 = Vec3(0, 0, 0);
    private layersProp: u32 = 1;
    // Whether readFields ran once (the file's target_position submits the
    // target, as Godot's setter does when the scene is loaded).
    private fieldsRead: bool = false;

    constructor(name: string) {
        super("NavigationAgent3D", name, false);
    }

    readFields(): void {
        super.readFields();
        // (Godot's set_target_position and set_navigation_layers ask for a
        // new path; a write that leaves the value as it was, a binding
        // pushing the same number each frame, asks for none: Hedra's, so
        // that a bound target does not search every frame. The two are
        // taken only when the property itself changed: a write of another
        // property, a bound max_speed, runs this too, and must not undo a
        // target or layers a script set with setTargetPosition or
        // setNavigationLayerValue.)
        const target = vec3Of(this.value("target_position"), Vec3(0, 0, 0));
        const layers = maskOf(this.value("navigation_layers"), 1);
        const first = !this.fieldsRead;
        this.fieldsRead = true;
        const tp = this.targetProp;
        const targetMoved = first || target.x != tp.x || target.y != tp.y || target.z != tp.z;
        const layersMoved = first || layers != this.layersProp;
        if (first ? this.getProp("target_position") != null
            : (targetMoved && (target.x != this.targetPosition.x || target.y != this.targetPosition.y
                || target.z != this.targetPosition.z))
                || (layersMoved && layers != this.navigationLayers)) {
            this.nav.requestRepath();
        }
        if (targetMoved) {
            this.targetProp = target;
            this.targetPosition = target;
        }
        this.pathDesiredDistance = this.f32Prop("path_desired_distance", 1);
        this.targetDesiredDistance = this.f32Prop("target_desired_distance", 1);
        this.pathHeightOffset = this.f32Prop("path_height_offset", 0);
        this.pathMaxDistance = this.f32Prop("path_max_distance", 5);
        if (layersMoved) {
            this.layersProp = layers;
            this.navigationLayers = layers;
        }
        this.pathfindingAlgorithm = this.i32Prop("pathfinding_algorithm", 0);
        this.pathPostprocessing = this.i32Prop("path_postprocessing", 0);
        this.pathMetadataFlags = this.i32Prop("path_metadata_flags", 7);
        this.simplifyPath = this.boolProp("simplify_path", false);
        this.simplifyEpsilon = this.f32Prop("simplify_epsilon", 0);
        this.avoidanceEnabled = this.boolProp("avoidance_enabled", false);
        const v = vec3Of(this.value("velocity"), Vec3(0, 0, 0));
        if (v.x != this.velocityProp.x || v.y != this.velocityProp.y || v.z != this.velocityProp.z) {
            this.velocityProp = v;
            this.setVelocity(v);
        }
        this.height = this.f32Prop("height", 1);
        this.radius = this.f32Prop("radius", 0.5);
        this.neighborDistance = this.f32Prop("neighbor_distance", 50);
        this.maxNeighbors = this.i32Prop("max_neighbors", 10);
        this.timeHorizonAgents = this.f32Prop("time_horizon_agents", 1);
        this.timeHorizonObstacles = this.f32Prop("time_horizon_obstacles", 0);
        this.maxSpeed = this.f32Prop("max_speed", 10);
        this.use3dAvoidance = this.boolProp("use_3d_avoidance", false);
        this.keepYVelocity = this.boolProp("keep_y_velocity", true);
        this.avoidanceLayers = maskOf(this.value("avoidance_layers"), 1);
        this.avoidanceMask = maskOf(this.value("avoidance_mask"), 1);
        this.avoidancePriority = this.f32Prop("avoidance_priority", 1);
        this.debugEnabled = this.boolProp("debug_enabled", false);
        this.debugUseCustom = this.boolProp("debug_use_custom", false);
        this.debugPathCustomColor = this.colorProp("debug_path_custom_color", Vec4(1, 1, 1, 1));
        this.debugPathCustomPointSize = this.f32Prop("debug_path_custom_point_size", 4);
        this.driveParent = this.boolProp("drive_parent", false);
        this.driveTurnSpeed = this.f32Prop("drive_turn_speed", 720);
    }

    // Every field from its properties, the target and the layers too, as
    // when the scene was loaded (the tools' clock starts each run so: a
    // target a hook or a script set in the last run is not the file's).
    readFieldsAsLoaded(): void {
        this.fieldsRead = false;
        // (the velocity as a new node's, so that the file's or a binding's
        // `velocity` is submitted again, as at load: the state's restart
        // dropped the one submitted last run)
        this.velocityProp = Vec3(0, 0, 0);
        this.velocity = Vec3(0, 0, 0);
        this.readFields();
    }

    // The Node3D it steers: its parent, when that is a 3D node (Godot's
    // agent works only under one: navigation-agent-parent says so).
    actor(): SceneNode? {
        const p = this.parent;
        return p != null && p.is3d ? p : null;
    }

    // Its parent's global position (zero without a 3D parent).
    actorPosition(): Vec3 {
        const a = this.actor();
        return a != null ? a.globalPosition : Vec3(0, 0, 0);
    }

    // Godot's set_target_position (the property's setter: the next update
    // asks for a new path, even to the same point, as Godot's does).
    setTargetPosition(p: Vec3): void {
        this.targetPosition = p;
        this.nav.requestRepath();
    }

    // Godot's set_velocity: the velocity it wants this frame, which the
    // avoidance answers with velocity_computed (at once, the same velocity,
    // without avoidance).
    setVelocity(v: Vec3): void {
        this.velocity = v;
        this.nav.desiredVelocity = v;
        this.nav.velocitySubmitted = true;
    }

    // Godot's set_velocity_forced: replaces the avoidance's own velocity
    // (the one its next step starts from: a teleport, a knock-back), on the
    // ground plane; the velocity the agent wants is left as it was, as
    // Godot's.
    setVelocityForced(v: Vec3): void {
        this.nav.avoidanceVelocity = Vec3(v.x, 0, v.z);
    }

    // Godot's get_next_path_position(): the point to head for now, after
    // the navigation was brought up to date; its parent's position when it
    // has no path.
    getNextPathPosition(): Vec3 {
        const l = navAgentLogic();
        if (l == null) return this.actorPosition();
        l.update(this, this.nav);
        return this.nav.nextPosition;
    }

    // Godot's distance_to_target(): from its parent to target_position (0
    // without a 3D parent, as Godot's answer after its error).
    distanceToTarget(): f32 {
        if (this.actor() == null) return 0;
        const a = this.actorPosition();
        const t = this.targetPosition;
        const dx = t.x - a.x;
        const dy = t.y - a.y;
        const dz = t.z - a.z;
        return <f32>Math.sqrt(<f64>(dx * dx + dy * dy + dz * dz));
    }

    // Godot's is_target_reached().
    isTargetReached(): bool {
        return this.nav.targetReached;
    }

    // Godot's is_target_reachable().
    isTargetReachable(): bool {
        const l = navAgentLogic();
        return l != null ? l.targetReachable(this, this.nav) : false;
    }

    // Godot's is_navigation_finished(): in a live tree after an update, as
    // Godot's (a script asking before getNextPathPosition() gets this
    // frame's answer); elsewhere (the tools' trees, which no script runs
    // in) as the last step or update left it.
    isNavigationFinished(): bool {
        const l = navAgentLogic();
        if (l != null && this.liveTree != null) l.update(this, this.nav);
        return this.nav.navigationFinished;
    }

    // Godot's get_final_position(): the end of its path.
    getFinalPosition(): Vec3 {
        const l = navAgentLogic();
        if (l != null) l.update(this, this.nav);
        return this.nav.finalPosition;
    }

    // Godot's get_current_navigation_path() (the agent's own array: copy
    // what you keep) and its index.
    getCurrentNavigationPath(): Array<Vec3> {
        return this.nav.path;
    }

    getCurrentNavigationPathIndex(): i32 {
        return this.nav.pathIndex;
    }

    // Godot's get_navigation_map(): its tree's map.
    getNavigationMap(): NavigationMap {
        return mapOf(this);
    }

    getNavigationLayerValue(layer: i32): bool {
        return (this.navigationLayers & layerBit(layer)) != 0;
    }

    // (Godot's set_navigation_layers asks for a new path)
    setNavigationLayerValue(layer: i32, on: bool): void {
        const b = layerBit(layer);
        const was = this.navigationLayers;
        this.navigationLayers = on ? this.navigationLayers | b : this.navigationLayers & ~b;
        if (this.navigationLayers != was) this.nav.requestRepath();
    }

    getAvoidanceLayerValue(layer: i32): bool {
        return (this.avoidanceLayers & layerBit(layer)) != 0;
    }

    getAvoidanceMaskValue(layer: i32): bool {
        return (this.avoidanceMask & layerBit(layer)) != 0;
    }
}

// Godot's NavigationObstacle3D: a circle of radius (moving with velocity)
// or the outline of vertices, which the agents of a mask holding one of its
// avoidance_layers avoid.
export class NavigationObstacle3D extends SceneNode {
    radius: f32 = 0;
    height: f32 = 1;
    // x, y, z a point, in the node's space (y ignored: the outline is on
    // the ground plane through the node's origin).
    vertices: Float32Array = new Float32Array(0);
    affectNavigationMesh: bool = false;
    carveNavigationMesh: bool = false;
    avoidanceEnabled: bool = true;
    velocity: Vec3 = Vec3(0, 0, 0);
    avoidanceLayers: u32 = 1;
    use3dAvoidance: bool = false;
    // Moves when `vertices` is set (the avoidance makes its outline's
    // segments again).
    verticesVersion: u32 = 0;

    constructor(name: string) {
        super("NavigationObstacle3D", name);
    }

    readFields(): void {
        super.readFields();
        const r = this.f32Prop("radius", 0);
        this.radius = r > 0 ? r : 0;
        const h = this.f32Prop("height", 1);
        this.height = h > 0 ? h : 0;
        const v = this.value("vertices");
        const n = v != null && v.kind == ValueKind.PackedVector3Array ? v.n : NO_PACKED;
        if (n.length != this.vertices.length || !sameNumbers(n, this.vertices)) {
            const f = new Float32Array(n.length);
            for (let i = 0; i < n.length; i++) f[i] = <f32>n[i];
            this.vertices = f;
            this.verticesVersion++;
        }
        this.affectNavigationMesh = this.boolProp("affect_navigation_mesh", false);
        this.carveNavigationMesh = this.boolProp("carve_navigation_mesh", false);
        this.avoidanceEnabled = this.boolProp("avoidance_enabled", true);
        this.velocity = vec3Of(this.value("velocity"), Vec3(0, 0, 0));
        this.avoidanceLayers = maskOf(this.value("avoidance_layers"), 1);
        this.use3dAvoidance = this.boolProp("use_3d_avoidance", false);
    }

    getAvoidanceLayerValue(layer: i32): bool {
        return (this.avoidanceLayers & layerBit(layer)) != 0;
    }
}

// Whether `n` holds the numbers of `f` (as f32), for a packed property read
// again without allocating when it did not change.
function sameNumbers(n: Array<f64>, f: Float32Array): bool {
    for (let i = 0; i < n.length; i++) if (<f32>n[i] != f[i]) return false;
    return true;
}

// Godot's NavigationLink3D: a way from start_position to end_position (in
// the node's space) that paths take like a polygon.
export class NavigationLink3D extends SceneNode {
    enabled: bool = true;
    bidirectional: bool = true;
    navigationLayers: u32 = 1;
    startPosition: Vec3 = Vec3(0, 0, 0);
    endPosition: Vec3 = Vec3(0, 0, 0);
    enterCost: f32 = 0;
    travelCost: f32 = 1;

    constructor(name: string) {
        super("NavigationLink3D", name);
    }

    readFields(): void {
        super.readFields();
        this.enabled = this.boolProp("enabled", true);
        this.bidirectional = this.boolProp("bidirectional", true);
        this.navigationLayers = maskOf(this.value("navigation_layers"), 1);
        this.startPosition = vec3Of(this.value("start_position"), Vec3(0, 0, 0));
        this.endPosition = vec3Of(this.value("end_position"), Vec3(0, 0, 0));
        const e = this.f32Prop("enter_cost", 0);
        this.enterCost = e > 0 ? e : 0;
        const t = this.f32Prop("travel_cost", 1);
        this.travelCost = t > 0 ? t : 0;
    }

    // Godot's get_global_start_position() and get_global_end_position().
    getGlobalStartPosition(): Vec3 {
        return this.global().transformPoint3(this.startPosition);
    }

    getGlobalEndPosition(): Vec3 {
        return this.global().transformPoint3(this.endPosition);
    }

    getNavigationLayerValue(layer: i32): bool {
        return (this.navigationLayers & layerBit(layer)) != 0;
    }
}

const NO_PACKED: Array<f64> = [];

// The least a Decal's size is on each axis (Godot's set_size: maxf(0.001)).
export const DECAL_MIN_SIZE: f32 = 0.001;

// A new node of a class, with every field at its default. A type this
// format version does not know (or one that is not a node class) gives a
// 3D SceneNode with unknownType set.
export function createNode(className: string, name: string): SceneNode {
    if (className == "Node") return new SceneNode("Node", name, false);
    if (className == "Node3D") return new SceneNode("Node3D", name);
    if (className == "MeshInstance3D") return new MeshInstance3D(name);
    if (className == "ModelInstance3D") return new ModelInstance3D(name);
    if (className == "MultiMeshInstance3D") return new MultiMeshInstance3D(name);
    if (className == "Camera3D") return new Camera3D(name);
    if (className == "DirectionalLight3D" || className == "OmniLight3D" || className == "SpotLight3D") {
        return new Light3D(className, name);
    }
    if (className == "WorldEnvironment") return new WorldEnvironment(name);
    if (className == "Marker3D") return new Marker3D(name);
    if (className == "ArtboardSprite3D") return new ArtboardSprite3D(name);
    if (className == "LightmapGI") return new LightmapGI(name);
    if (className == "LightmapProbe") return new LightmapProbe(name);
    if (className == "ReflectionProbe") return new ReflectionProbe(name);
    if (className == "Timer") return new TimerNode(name);
    // Milestone 31.
    if (className == "Area3D") return new Area3D(name);
    if (className == "StaticBody3D") return new StaticBody3D(name);
    if (className == "CollisionShape3D") return new CollisionShape3D(name);
    if (className == "RayCast3D") return new RayCast3D(name);
    // Milestone 48.
    if (className == "Skeleton3D") return new Skeleton3D(name);
    if (className == "BoneAttachment3D") return new BoneAttachment3D(name);
    // Milestone 32.
    if (className == "Path3D") return new Path3D(name);
    if (className == "PathFollow3D") return new PathFollow3D(name);
    // Milestone 33.
    if (className == "Decal") return new Decal(name);
    // Milestone 34.
    if (className == "SubViewport") return new SubViewport(name);
    // Milestone 35.
    if (className == "CPUParticles3D") return new CPUParticles3D(name);
    // Milestone 36.
    if (className == "AudioStreamPlayer3D") return new AudioStreamPlayer3D(name);
    if (className == "AudioListener3D") return new AudioListener3D(name);
    // Milestone 37.
    if (className == "FogVolume") return new FogVolume(name);
    if (className == "OccluderInstance3D") return new OccluderInstance3D(name);
    // Milestone 63.
    if (className == "NavigationRegion3D") return new NavigationRegion3D(name);
    if (className == "NavigationAgent3D") return new NavigationAgent3D(name);
    if (className == "NavigationObstacle3D") return new NavigationObstacle3D(name);
    if (className == "NavigationLink3D") return new NavigationLink3D(name);
    // Also an abstract node class (Light3D) or a resource class, which the
    // validator refuses: kept like a newer type rather than failing here.
    const n = new SceneNode(className, name);
    n.unknownType = true;
    return n;
}
