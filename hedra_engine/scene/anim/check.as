// The validator's checks of a scene's timelines (docs/formats/RSCN.md,
// "Animations"; docs/plans/RIVE_MODEL.md sections 3.2 and 3.6): what one
// <Event> or <LinearAnimation> must satisfy beyond its syntax, found from
// the document alone. ../rscn/validate.as calls these for each such entry,
// in document order, and sorts each entry's problems by position.
//
// A keyed target is checked only as far as the file can tell: a path whose
// every segment is a node this file declares (none of them an instance or
// an override) must name one (keyed-target-unknown), and its property is
// checked against that node's class when the class is known. A path
// through an instanced scene, and the property of an instance's root or an
// override, are the instancer's to check (../anim/scene_anims.as: the load
// warnings keyed-node-missing and keyed-property-unknown), since only the
// instanced tree knows them.
//
// What a KeyedProperty may name, and the keyframe it takes (RSCN.md's
// keyframe table), comes from the binding targets (../binding/targets.as:
// a target's kind and its `animates` flag) and three families: `event:<Name>`
// on the root (a KeyFrameCallback firing the scene's Event), `signal:<name>`
// on any node (a KeyFrameCallback emitting the signal) and `quaternion` on
// any Node3D (KeyFrameQuaternion). Milestone 48 adds two: a Skeleton3D's
// `bones/<bone>:position:x` (y, z; and `:scale:...`), KeyFrameDouble, and
// `bones/<bone>:quaternion`, KeyFrameQuaternion; a MeshInstance3D's
// `blend_shapes/<name>`, KeyFrameDouble. Which bones and blend shapes there
// are only the instanced model tells: the instancer warns of an unknown one
// (bone-unknown, blend-shape-unknown). Milestone 61 adds a ShaderMaterial's
// parameters, `material_override:shader_parameter/<name>` (and through
// mesh:material: and next passes, a component by :x to :w): which kind a
// uniform is only its shader tells, which the validator never reads, so a
// KeyFrameDouble, KeyFrameColor or KeyFrameBool is accepted (the same one
// for every key of the property), and the instancer checks it against the
// uniform (keyed-property-unknown, keyed-property-mismatch).

import { XmlAttr, XmlKind, XmlNode, XmlPos } from "../../base/xml";
import { Diagnostic, Severity } from "../error";
import { PropType, classInfo, classNames, findProp, isA } from "../classdb";
import { BindingDecl, NodeDecl, RscnDoc } from "../rscn/doc";
import { BindKind, BindingTarget, findBindingTarget, signalTargetName } from "../binding/targets";
import { isUniqueSegment } from "../tree/paths";
import {
    CUSTOM_PROPERTY_ELEMENTS, EVENT_PROPERTY_PREFIX, EventDecl, INTERPOLATION_NAMES, INTERPOLATOR_ELEMENTS, InterpolationType, InterpolatorKind,
    KEYFRAME_ELEMENTS, finiteAsF32, KeyFrameKind, KeyedObjectDecl, KeyedPropertyDecl, LinearAnimationDecl, LoopMode,
    QUATERNION_PROPERTY, SIGNAL_PROPERTY_PREFIX,
} from "./decl";
import { BLEND_SHAPES_PREFIX, BONES_PREFIX, BONE_FIELD_QUATERNION, blendShapeOf, parseBoneProperty } from "../skeleton/names";
import { CLI } from "../../base/names";

const KEPT_HINT = "it is kept and written back unchanged, and otherwise ignored";
const FORMAT_FEATURE_HINT = "write format=\"2\" on <rscn> (" + CLI + " format writes the version a file needs)";
const TARGET_HINT = "a KeyedObject's target is a node path from the root: \".\" (the root), \"Hinge\", \"Arm/Hand\"";
const PROPERTY_HINT = "a KeyedProperty names an animatable property of its node's class (docs/formats/RSCN.md, \"Targets and flags\", "
    + "marks them animates), event:<Name> on the root, signal:<name>, quaternion on a Node3D, bones/<bone>:position:x (y, z), "
    + "bones/<bone>:quaternion or bones/<bone>:scale:x (y, z) on a Skeleton3D, blend_shapes/<name> on a MeshInstance3D, or a "
    + "ShaderMaterial's material_override:shader_parameter/<name>";
const BONE_HINT = "a bone is keyed by the components of its position and scale (bones/Hips:position:y) and by its whole rotation "
    + "(bones/Hips:quaternion, KeyFrameQuaternion)";
const NOT_ANIMATABLE_HINT = "only the properties marked animates in docs/formats/RSCN.md, \"Targets and flags\", are keyed: "
    + "a vector by its components (position:x), never a transform, a resource or a bake's setting";
const TYPE_HINT = "the keyframe follows the property: KeyFrameDouble a number, KeyFrameInt a whole number, KeyFrameUint an enum, "
    + "KeyFrameBool, KeyFrameColor, KeyFrameString, KeyFrameId a resource, KeyFrameCallback an event or signal, "
    + "KeyFrameQuaternion the quaternion";
const ROTATION_HINT = "key a node's rotation either as rotation_degrees (or rotation) components or as quaternion in one animation; "
    + "two animations, one of each, may mix";
const INTERPOLATOR_HINT = "the interpolator child decides the curve (as in Rive): cubic takes a CubicEaseInterpolator, cubicValue a "
    + "CubicValueInterpolator, elastic an ElasticInterpolator, hold and linear none";
const ID_HINT = "a KeyFrameId is read, kept and written back, but resources are not animated yet: the key changes nothing";
const EVENT_BINDING_PROPERTY_HINT = "an Event's binding names the view model trigger it fires: <binding property=\"fire\" path=\"...\"/>";

const BINDING_ATTRS: Array<string> = ["property", "path", "mode", "once", "global", "converter", "scale", "offset", "convert"];

// " (first at line N)" when the earlier position is known, else "".
function firstAt(p: XmlPos): string {
    return p.line > 0 ? " (first at line " + p.line.toString() + ")" : "";
}

// Why a target path is malformed, or "" (validate.as's rule for node paths).
function pathProblem(path: string): string {
    if (path.length == 0) return "it is empty";
    if (path == ".") return "";
    if (path.startsWith("/")) return "it starts with \"/\" (paths are relative to the root)";
    if (path.endsWith("/")) return "it ends with \"/\"";
    const segs = path.split("/");
    for (let i = 0; i < segs.length; i++) {
        const s = segs[i];
        if (s.length == 0) return "it has an empty segment";
        if (s == "..") return "\"..\" is not allowed";
        if (s == ".") return "\".\" may only stand alone, for the root";
        if (s.includes(".")) return "segment \"" + s + "\" holds a \".\", which no name may";
    }
    return "";
}

// Whether `property` keys a rotation's Euler form (rotation_degrees,
// rotation, or a component of either).
function isEulerRotation(property: string): bool {
    return property == "rotation" || property == "rotation_degrees" || property.startsWith("rotation:")
        || property.startsWith("rotation_degrees:");
}

// The interpolator kind an interpolation type takes, or -1 for none (hold,
// linear).
function interpolatorOf(t: InterpolationType): i32 {
    if (t == InterpolationType.Cubic) return <i32>InterpolatorKind.CubicEase;
    if (t == InterpolationType.CubicValue) return <i32>InterpolatorKind.CubicValue;
    if (t == InterpolationType.Elastic) return <i32>InterpolatorKind.Elastic;
    return -1;
}

// The classes whose properties a target's last part may be one of (a
// node's own, a material's, an environment's, a built-in mesh's), for
// telling a whole-number target from a float one.
function propTypeOfTarget(cls: string, property: string): i32 {
    const segs = property.split(":");
    let name = segs[segs.length - 1];
    // A vector's component (`position:x`): the vector's numbers are floats.
    if (segs.length > 1 && (name == "x" || name == "y" || name == "z")) {
        const owner = findProp(cls, segs[segs.length - 2]);
        if (owner == null || owner.type == PropType.Vector3 || owner.type == PropType.Vector2) return <i32>PropType.Float;
    }
    let p = findProp(cls, name);
    if (p == null && segs.length > 1) p = findProp("StandardMaterial3D", name);
    if (p == null && segs.length > 1) p = findProp("Environment", name);
    if (p == null && segs.length > 1) {
        const names = classNames();
        for (let i = 0; i < names.length && p == null; i++) if (isA(names[i], "PrimitiveMesh")) p = findProp(names[i], name);
    }
    return p != null ? <i32>p.type : <i32>PropType.Float;
}

// What a KeyedProperty names, once resolved: the keyframe kind it takes,
// or why it names nothing keyable.
export class Keyable {
    // The keyframe kind (KeyFrameKind), or -1 with `code` and `message`.
    kind: i32 = -1;
    // Milestone 61: a shader parameter, whose kind its uniform decides:
    // any of KeyFrameDouble, KeyFrameColor and KeyFrameBool (`kind` is
    // Double).
    deferred: bool = false;
    code: string = "";
    message: string = "";
    hint: string = "";
}

function keyable(kind: KeyFrameKind): Keyable {
    const k = new Keyable();
    k.kind = <i32>kind;
    return k;
}

function notKeyable(code: string, message: string, hint: string): Keyable {
    const k = new Keyable();
    k.code = code;
    k.message = message;
    k.hint = hint;
    return k;
}

// The keyframe a binding target takes (RSCN.md's keyframe table).
function kindOfTarget(cls: string, t: BindingTarget): KeyFrameKind {
    switch (t.kind) {
        case BindKind.Boolean: return KeyFrameKind.Bool;
        case BindKind.Color: return KeyFrameKind.Color;
        case BindKind.String: return KeyFrameKind.String;
        case BindKind.Enum: return KeyFrameKind.Uint;
        default:
            return propTypeOfTarget(cls, t.property) == <i32>PropType.Int ? KeyFrameKind.Int : KeyFrameKind.Double;
    }
}

// What `property` of a node of the known class `cls` takes. The event
// family is the caller's (it depends on the target, not the class).
export function keyableProperty(cls: string, property: string): Keyable {
    if (property.startsWith(SIGNAL_PROPERTY_PREFIX)) {
        if (signalTargetName(property).length == 0) {
            return notKeyable("keyed-property-unknown", "\"" + property + "\" names no signal: a signal's name is letters, digits and _",
                PROPERTY_HINT);
        }
        return keyable(KeyFrameKind.Callback);
    }
    if (property.startsWith(BONES_PREFIX) || property.startsWith(BLEND_SHAPES_PREFIX)) return keyableSkeletal(cls, property);
    if (property == QUATERNION_PROPERTY) {
        if (!isA(cls, "Node3D")) {
            return notKeyable("keyed-property-unknown", cls + " has no quaternion: only a Node3D's rotation is keyed so", PROPERTY_HINT);
        }
        return keyable(KeyFrameKind.Quaternion);
    }
    const t = findBindingTarget(cls, property);
    if (t != null) {
        if (t.output) {
            return notKeyable("keyed-property-not-animatable", property + " is an output: it is computed, never written",
                NOT_ANIMATABLE_HINT);
        }
        if (!t.animates) return notKeyable("keyed-property-not-animatable", cls + "'s " + property + " does not animate", NOT_ANIMATABLE_HINT);
        if (t.deferred) {
            const k = keyable(KeyFrameKind.Double);
            k.deferred = true;
            return k;
        }
        return keyable(kindOfTarget(cls, t));
    }
    // A property of the class that is no animatable target: a transform, a
    // whole vector, a bake's setting, a resource (KeyFrameId, kept).
    const colon = property.indexOf(":");
    const head = colon >= 0 ? property.substring(0, colon) : property;
    const p = findProp(cls, head);
    if (p == null) return notKeyable("keyed-property-unknown", cls + " has no animatable property \"" + property + "\"", PROPERTY_HINT);
    if (p.type == PropType.Resource) {
        if (colon < 0) return keyable(KeyFrameKind.Id);
        const rest = property.substring(colon + 1);
        const c2 = rest.indexOf(":");
        const sub = c2 >= 0 ? rest.substring(0, c2) : rest;
        if (classInfo(p.resourceClass) == null || findProp(p.resourceClass, sub) == null) {
            return notKeyable("keyed-property-unknown", cls + " has no animatable property \"" + property + "\"", PROPERTY_HINT);
        }
    }
    if (colon < 0 && (p.type == PropType.Vector3 || p.type == PropType.Vector2)) {
        return notKeyable("keyed-property-not-animatable", property + " is a vector: key its components (" + property + ":x, "
            + property + ":y" + (p.type == PropType.Vector3 ? ", " + property + ":z" : "") + ")", NOT_ANIMATABLE_HINT);
    }
    return notKeyable("keyed-property-not-animatable", cls + "'s " + property + " does not animate", NOT_ANIMATABLE_HINT);
}

// Milestone 48: what a bone or blend shape property takes (`cls` "": a
// class the file cannot tell, which the instancer checks).
export function keyableSkeletal(cls: string, property: string): Keyable {
    if (property.startsWith(BLEND_SHAPES_PREFIX)) {
        if (blendShapeOf(property) == null) {
            return notKeyable("keyed-property-unknown", "\"" + property + "\" names no blend shape: blend_shapes/<name>", PROPERTY_HINT);
        }
        if (cls.length > 0 && !isA(cls, "MeshInstance3D")) {
            return notKeyable("keyed-property-unknown", cls + " has no blend shapes: a MeshInstance3D of a model's mesh has", PROPERTY_HINT);
        }
        return keyable(KeyFrameKind.Double);
    }
    const bp = parseBoneProperty(property);
    if (bp == null) return notKeyable("keyed-property-unknown", "\"" + property + "\" is no bone property", BONE_HINT);
    if (cls.length > 0 && !isA(cls, "Skeleton3D")) {
        return notKeyable("keyed-property-unknown", cls + " has no bones: a Skeleton3D (a model's armature) has", PROPERTY_HINT);
    }
    if (bp.field == BONE_FIELD_QUATERNION) return keyable(KeyFrameKind.Quaternion);
    if (bp.axis < 0) {
        return notKeyable("keyed-property-not-animatable", property + " is a vector: key its components (" + property + ":x, "
            + property + ":y, " + property + ":z)", BONE_HINT);
    }
    return keyable(KeyFrameKind.Double);
}

// The checks of a document's timelines. One per validation: `begin` once,
// then `event` and `animation` for each entry in document order, each
// adding its problems to `out` (the validator sorts and flushes them).
export class AnimChecker {
    doc: RscnDoc;
    file: string;
    out: Array<Diagnostic>;
    nodes: Array<NodeDecl> = [];
    byPath: Map<string, i32> = new Map<string, i32>();
    events: Map<string, XmlPos> = new Map<string, XmlPos>();
    animations: Map<string, XmlPos> = new Map<string, XmlPos>();
    // The scene's Event names (all of them: a key may come before its
    // event in no order, the sections being fixed).
    eventNames: Set<string> = new Set<string>();

    constructor(doc: RscnDoc, out: Array<Diagnostic>) {
        this.doc = doc;
        this.file = doc.file;
        this.out = out;
        const nodes = doc.nodes();
        for (let i = 0; i < nodes.length; i++) {
            const n = nodes[i];
            this.nodes.push(n);
            if (i > 0 && n.parent == null) continue;
            const path = i == 0 ? "." : n.path();
            if (!this.byPath.has(path)) this.byPath.set(path, i);
        }
        const events = doc.events();
        for (let i = 0; i < events.length; i++) this.eventNames.add(events[i].name);
    }

    error(p: XmlPos, code: string, message: string, hint: string? = null): void {
        this.out.push(new Diagnostic(Severity.Error, code, this.file, p.line, p.col, message, hint));
    }

    warning(p: XmlPos, code: string, message: string, hint: string? = null): void {
        this.out.push(new Diagnostic(Severity.Warning, code, this.file, p.line, p.col, message, hint));
    }

    formatFeature(p: XmlPos, what: string): void {
        if (this.doc.format >= 2) return;
        this.error(p, "format-feature", what + " needs format 2: this file is format " + this.doc.format.toString(), FORMAT_FEATURE_HINT);
    }

    unknownAttrs(attrs: Array<XmlAttr>, element: string, known: Array<string>? = null): void {
        for (let i = 0; i < attrs.length; i++) {
            const a = attrs[i];
            if (known != null && known.includes(a.name)) continue;
            this.warning(a.pos.isKnown() ? a.pos : a.valuePos, "attribute-unknown", "unknown attribute \"" + a.name + "\" on <" + element + ">",
                KEPT_HINT);
        }
    }

    unknownChildren(children: Array<XmlNode>, where: string): void {
        for (let i = 0; i < children.length; i++) {
            const n = children[i];
            if (n.kind == XmlKind.Element) {
                this.warning(n.pos, "element-unknown", "unknown element <" + n.name + "> in <" + where + ">", KEPT_HINT);
            } else if (n.kind == XmlKind.Pi) {
                this.warning(n.pos, "element-unknown", "unknown processing instruction <?" + n.name + "?> in <" + where + ">", KEPT_HINT);
            }
        }
    }

    // --- <Event>

    event(d: EventDecl): void {
        this.formatFeature(d.pos, "the event <Event name=\"" + d.name + "\">");
        if (this.events.has(d.name)) {
            this.error(d.pos, "event-name-duplicate", "event \"" + d.name + "\" is declared twice" + firstAt(this.events.get(d.name)),
                "a scene's events are named, and a key names one by its name: give each its own");
        } else {
            this.events.set(d.name, d.pos);
        }
        this.unknownAttrs(d.extraAttrs, "Event");
        for (let i = 0; i < d.properties.length; i++) {
            const p = d.properties[i];
            this.unknownAttrs(p.extraAttrs, CUSTOM_PROPERTY_ELEMENTS[<i32>p.kind]);
        }
        for (let i = 0; i < d.bindings.length; i++) this.eventBinding(d, d.bindings[i]);
        this.unknownChildren(d.extraChildren, "Event");
    }

    eventBinding(d: EventDecl, b: BindingDecl): void {
        for (let i = 0; i < b.attrs.length; i++) {
            const a = b.attrs[i];
            if (BINDING_ATTRS.includes(a.name)) continue;
            this.warning(a.pos.isKnown() ? a.pos : a.valuePos, "attribute-unknown", "unknown attribute \"" + a.name + "\" on <binding>",
                KEPT_HINT);
        }
        if (b.property != "fire") {
            this.error(b.attrPos("property"), "binding-property", "an event's binding is property=\"fire\", found \"" + b.property + "\"",
                EVENT_BINDING_PROPERTY_HINT);
        }
        // (milestone 47: the binding fires its trigger; its path is the
        // data's, checked when the scene is bound: event-binding-path-unknown)
    }

    // --- <LinearAnimation>

    animation(d: LinearAnimationDecl): void {
        this.formatFeature(d.pos, "the animation <LinearAnimation name=\"" + d.name + "\">");
        if (this.animations.has(d.name)) {
            this.error(d.pos, "animation-name-duplicate", "animation \"" + d.name + "\" is declared twice"
                + firstAt(this.animations.get(d.name)), "a scene's animations are named, and a state or a script names one by its name: "
                + "give each its own");
        } else {
            this.animations.set(d.name, d.pos);
        }
        this.unknownAttrs(d.extraAttrs, "LinearAnimation");
        this.unknownChildren(d.extraChildren, "LinearAnimation");
        this.range(d);
        if (!finiteAsF32(d.speed)) {
            this.error(d.pos, "attribute-invalid", "animation \"" + d.name + "\"'s speed " + d.speed.toString()
                + " is beyond what a 32-bit float holds", "give it a speed between -3.4e38 and 3.4e38 (1 plays at its own pace)");
        }
        const targets = new Map<string, XmlPos>();
        // Per target, where its rotation was keyed each way (for
        // animation-rotation-mixed: reported once per target).
        const euler = new Map<string, XmlPos>();
        const quaternion = new Map<string, XmlPos>();
        const mixed = new Set<string>();
        for (let i = 0; i < d.objects.length; i++) {
            const o = d.objects[i];
            if (targets.has(o.target)) {
                this.error(o.pos, "keyed-object-duplicate", "animation \"" + d.name + "\" keys \"" + o.target + "\" twice"
                    + firstAt(targets.get(o.target)), "one KeyedObject per node: put every keyed property of \"" + o.target + "\" in it");
            } else {
                targets.set(o.target, o.pos);
            }
            this.keyedObject(d, o);
            for (let k = 0; k < o.properties.length; k++) {
                const p = o.properties[k];
                const isQ = p.property == QUATERNION_PROPERTY;
                if (!isQ && !isEulerRotation(p.property)) continue;
                const mine = isQ ? quaternion : euler;
                const other = isQ ? euler : quaternion;
                if (!mine.has(o.target)) mine.set(o.target, p.pos);
                if (other.has(o.target) && !mixed.has(o.target)) {
                    mixed.add(o.target);
                    this.error(p.pos, "animation-rotation-mixed", "animation \"" + d.name + "\" keys \"" + o.target
                        + "\"'s rotation both as Euler components and as quaternion" + firstAt(other.get(o.target)), ROTATION_HINT);
                }
            }
        }
    }

    // The frames an animation plays over must be a range: a loop over no
    // frames wraps to NaN and a pingPong over none (or a reversed one)
    // bounces forever, so a scene that passed the check could freeze a
    // Rive project. A one-shot over no frames is fine: it simply ends.
    range(d: LinearAnimationDecl): void {
        if (d.enableWorkArea) {
            if (d.workStart < 0 || d.workEnd <= d.workStart) {
                this.error(d.pos, "attribute-invalid", "animation \"" + d.name + "\"'s work area runs from frame " + d.workStart.toString()
                    + " to frame " + d.workEnd.toString() + ": it must start at frame 0 or later and end after it starts",
                    "set workStart and workEnd (workStart < workEnd), or write enableWorkArea=\"false\"");
            }
        } else if (d.duration == 0 && d.loop != LoopMode.OneShot) {
            this.error(d.pos, "attribute-invalid", "animation \"" + d.name + "\" loops over no frames (its duration is 0)",
                "give it a duration of 1 frame or more, or make it loopValue=\"oneShot\"");
        }
    }

    // Where `path` leads in this file: the node's index when every segment
    // is a node the file declares, -1 when it goes through an instance or
    // an override (the instancer's to check), -2 when it names no node.
    resolve(path: string): i32 {
        if (this.nodes.length == 0) return -2;
        if (path == ".") return 0;
        const segs = path.split("/");
        for (let i = 0; i < segs.length; i++) if (isUniqueSegment(segs[i])) return -1;
        if (this.byPath.has(path)) return this.byPath.get(path);
        for (let k = segs.length - 1; k >= 1; k--) {
            const prefix = segs.slice(0, k).join("/");
            if (this.byPath.has(prefix)) return this.defers(this.byPath.get(prefix)) ? -1 : -2;
        }
        return this.defers(0) ? -1 : -2;
    }

    // Whether node `i` has children this file does not declare: an
    // instance, or an override of a node inside one.
    defers(i: i32): bool {
        const n = this.nodes[i];
        if (n.instance != null) return true;
        return i > 0 && n.type == null && n.parent != null;
    }

    keyedObject(a: LinearAnimationDecl, o: KeyedObjectDecl): void {
        this.unknownAttrs(o.extraAttrs, "KeyedObject");
        this.unknownChildren(o.extraChildren, "KeyedObject");
        // The class whose properties are checked ("" when the file cannot
        // tell: the instancer checks them).
        let cls = "";
        const problem = pathProblem(o.target);
        if (problem.length > 0) {
            this.error(o.pos, "keyed-target-unknown", "target \"" + o.target + "\" is not a node path: " + problem, TARGET_HINT);
        } else {
            const at = this.resolve(o.target);
            if (at == -2) {
                this.error(o.pos, "keyed-target-unknown", "animation \"" + a.name + "\" keys \"" + o.target + "\", which is no node of this file",
                    this.targetHint(o.target));
            } else if (at >= 0) {
                const n = this.nodes[at];
                const type = n.type;
                if (type != null && n.instance == null) {
                    const info = classInfo(type);
                    if (info != null && info.isNode) cls = type;
                }
            }
        }
        const seen = new Map<string, XmlPos>();
        for (let i = 0; i < o.properties.length; i++) {
            const p = o.properties[i];
            if (seen.has(p.property)) {
                this.error(p.pos, "keyed-property-duplicate", "\"" + o.target + "\" keys " + p.property + " twice" + firstAt(seen.get(p.property)),
                    "one KeyedProperty per property: put every key of " + p.property + " in it");
            } else {
                seen.set(p.property, p.pos);
            }
            this.keyedProperty(a, o, p, cls);
        }
    }

    // A path that starts with the root's own name is a common slip: say so.
    targetHint(path: string): string {
        if (this.nodes.length > 0) {
            const rootName = this.nodes[0].name;
            if (rootName.length > 0 && (path == rootName || path.startsWith(rootName + "/"))) {
                const rest = path == rootName ? "." : path.substring(rootName.length + 1);
                return "paths start below the root: write \"" + rest + "\" rather than \"" + path + "\"";
            }
        }
        return TARGET_HINT;
    }

    keyedProperty(a: LinearAnimationDecl, o: KeyedObjectDecl, p: KeyedPropertyDecl, cls: string): void {
        this.unknownAttrs(p.extraAttrs, "KeyedProperty");
        this.unknownChildren(p.extraChildren, "KeyedProperty");
        // The keyframe kind the property takes, or -1 when unknown here.
        let want: i32 = -1;
        // (milestone 61: a shader parameter takes any of three, the first
        // key's for all)
        let deferred = false;
        if (p.property.startsWith(EVENT_PROPERTY_PREFIX)) {
            const name = p.property.substring(EVENT_PROPERTY_PREFIX.length);
            if (o.target != ".") {
                this.error(p.pos, "keyed-event-target", "event:" + name + " is keyed on \"" + o.target + "\": events are keyed on the root",
                    "key an event on <KeyedObject target=\".\">, the scene's root, as Rive keys an artboard's event");
            } else if (!this.eventNames.has(name)) {
                const names = this.doc.events();
                const list = new Array<string>();
                for (let i = 0; i < names.length; i++) list.push(names[i].name);
                this.error(p.pos, "keyed-event-unknown", "\"" + p.property + "\" names no event of this scene",
                    list.length > 0 ? "the scene's events are " + list.join(", ") : "declare it: <Event name=\"" + name + "\"/>");
            }
            want = <i32>KeyFrameKind.Callback;
        } else if (cls.length > 0) {
            const k = keyableProperty(cls, p.property);
            if (k.kind < 0) this.error(p.pos, k.code, k.message, k.hint);
            want = k.kind;
            deferred = k.deferred;
        } else if (p.property.startsWith(SIGNAL_PROPERTY_PREFIX)) {
            // (any node has signals: told without its class)
            const k = keyableProperty("Node", p.property);
            if (k.kind < 0) this.error(p.pos, k.code, k.message, k.hint);
            want = k.kind;
        } else if (p.property == QUATERNION_PROPERTY) {
            want = <i32>KeyFrameKind.Quaternion;
        } else if (p.property.startsWith(BONES_PREFIX) || p.property.startsWith(BLEND_SHAPES_PREFIX)) {
            // (told without the class: no other property starts so)
            const k = keyableSkeletal("", p.property);
            if (k.kind < 0) this.error(p.pos, k.code, k.message, k.hint);
            want = k.kind;
        }
        let last: i32 = i32.MIN_VALUE;
        let ordered = true;
        const frames = new Map<i32, XmlPos>();
        if (deferred && p.keys.length > 0) {
            const first = p.keys[0].kind;
            want = -1;
            if (first == KeyFrameKind.Double || first == KeyFrameKind.Color || first == KeyFrameKind.Bool) want = <i32>first;
            else {
                this.error(p.keys[0].pos, "keyframe-type", "<" + KEYFRAME_ELEMENTS[<i32>first] + "> on " + p.property
                    + ", a shader parameter, which takes <KeyFrameDouble>, <KeyFrameColor> or <KeyFrameBool> (by its uniform's type)",
                    TYPE_HINT);
            }
        }
        for (let i = 0; i < p.keys.length; i++) {
            const k = p.keys[i];
            if (want >= 0 && <i32>k.kind != want) {
                this.error(k.pos, "keyframe-type", "<" + KEYFRAME_ELEMENTS[<i32>k.kind] + "> on " + p.property + ", which takes <"
                    + KEYFRAME_ELEMENTS[want] + ">", TYPE_HINT);
            }
            if (frames.has(k.frame)) {
                this.error(k.pos, "keyframe-frame-duplicate", p.property + " of \"" + o.target + "\" has two keys at frame " + k.frame.toString()
                    + firstAt(frames.get(k.frame)), "a property has one key a frame: remove one of them");
            } else {
                frames.set(k.frame, k.pos);
                if (ordered && k.frame < last) {
                    ordered = false;
                    this.warning(k.pos, "keyframe-order", p.property + " of \"" + o.target + "\": the key at frame " + k.frame.toString()
                        + " comes after the one at frame " + last.toString(),
                        "keys are evaluated in frame order whatever their order in the file: write them so (the editor does)");
                }
                if (k.frame > last) last = k.frame;
            }
            if (k.frame > a.duration) {
                this.warning(k.pos, "keyframe-frame-range", "the key at frame " + k.frame.toString() + " of " + p.property + " is past \""
                    + a.name + "\"'s duration (" + a.duration.toString() + " frames)",
                    "playing never reaches it (only setting the time does, as in Rive): lengthen the animation or move the key");
            }
            if (!finiteAsF32(k.number) || !finiteAsF32(k.qx) || !finiteAsF32(k.qy) || !finiteAsF32(k.qz) || !finiteAsF32(k.qw)) {
                this.error(k.pos, "attribute-invalid", "the key at frame " + k.frame.toString() + " of " + p.property
                    + " has a value beyond what a 32-bit float holds", "keep a key's numbers between -3.4e38 and 3.4e38");
            }
            if (k.kind == KeyFrameKind.Id) {
                this.warning(k.pos, "keyframe-id-unsupported", "the KeyFrameId of " + p.property + " at frame " + k.frame.toString()
                    + " is not evaluated", ID_HINT);
            }
            const ip = k.interpolator;
            if (ip != null && <i32>ip.kind != interpolatorOf(k.interpolation)) {
                this.warning(ip.pos, "keyframe-interpolator-mismatch", "a " + INTERPOLATOR_ELEMENTS[<i32>ip.kind] + " under interpolationType=\""
                    + INTERPOLATION_NAMES[<i32>k.interpolation] + "\"", INTERPOLATOR_HINT);
            }
            this.unknownAttrs(k.extraAttrs, KEYFRAME_ELEMENTS[<i32>k.kind]);
            this.unknownChildren(k.extraChildren, KEYFRAME_ELEMENTS[<i32>k.kind]);
            if (ip != null) {
                // (the curve's numbers are f32s in the engine: y1="1e39"
                // would write infinity, then NaN, to the node)
                if (!(finiteAsF32(ip.x1) && finiteAsF32(ip.y1) && finiteAsF32(ip.x2) && finiteAsF32(ip.y2)
                    && finiteAsF32(ip.amplitude) && finiteAsF32(ip.period))) {
                    this.error(ip.pos, "attribute-invalid", "the " + INTERPOLATOR_ELEMENTS[<i32>ip.kind] + " of " + p.property
                        + "'s key at frame " + k.frame.toString() + " has a number beyond what a 32-bit float holds",
                        "keep an interpolator's numbers between -3.4e38 and 3.4e38");
                }
                this.unknownAttrs(ip.extraAttrs, INTERPOLATOR_ELEMENTS[<i32>ip.kind]);
                this.unknownChildren(ip.extraChildren, INTERPOLATOR_ELEMENTS[<i32>ip.kind]);
            }
        }
    }
}
