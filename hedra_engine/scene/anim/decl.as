// Rive's timelines in a scene, as the file writes them (milestone 45,
// docs/plans/RIVE_MODEL.md sections 3.2, 3.6 and 4; docs/formats/RSCN.md,
// "Animations"): the declarations the reader (../rscn/parse.as) fills, the
// validator (../rscn/validate.as) checks, the writer (engine/src/scene/
// rscn/write.as) prints, the binary scene carries (../rscnb/anim.as, the
// ANIM section) and the editor edits. The engine prepares them
// (./animation.as) and never reads them per frame.
//
// The elements are RML's and take RML's attribute names; they differ from
// RML only in their references (RIVE_MODEL.md section 4.1): a KeyedObject
// names its node by path (`target`, "." the scene's root, through
// instances: "Hero/Arm"), a KeyedProperty its property by its .rscn name
// with subnames ("rotation_degrees:y", "material_override:albedo_color"),
// and an animation or an event is named by `name`. RML's ids are absent.
//
//   <Event name="Creak">                               EventDecl
//     <CustomPropertyNumber name="volume" propertyValue="0.8"/>
//     <binding property="fire" path="sfx/creak"/>      (read and kept)
//   </Event>
//   <LinearAnimation name="Open" fps="60" duration="45" loopValue="oneShot">
//     <KeyedObject target="Hinge">                      KeyedObjectDecl
//       <KeyedProperty property="rotation_degrees:y">   KeyedPropertyDecl
//         <KeyFrameDouble frame="0" value="0" interpolationType="cubic">
//           <CubicEaseInterpolator x1="0.42" y1="0" x2="0.58" y2="1"/>
//         </KeyFrameDouble>
//         <KeyFrameDouble frame="45" value="-95"/>
//       </KeyedProperty>
//     </KeyedObject>
//     <KeyedObject target=".">
//       <KeyedProperty property="event:Creak">
//         <KeyFrameCallback frame="6"/>
//       </KeyedProperty>
//     </KeyedObject>
//   </LinearAnimation>
//
// Every field holds what the file says, defaults as Rive's (fps 60,
// duration 60, speed 1, oneShot, no work area, keys held). Numbers are kept
// as the f64 the text gave, so that text, binary and text again are the
// same bytes; the engine evaluates them as Rive's f32. Attributes and child
// elements this version does not know are kept in order (extraAttrs,
// extraChildren) and written back after the known ones.
//
// Plain data with no behaviour but lookups: everything that checks,
// evaluates or edits lives elsewhere.

import { XmlAttr, XmlNode, XmlPos } from "../../base/xml";
import { BindingDecl } from "../rscn/doc";

// Whether `v` stays a finite number once the engine prepares it to f32
// (a speed of 1e39, or a key of one, would be infinity there: a step of
// infinite time, a value written as infinity).
export function finiteAsF32(v: f64): bool {
    return isFinite(v) && Math.abs(v) <= <f64>f32.MAX_VALUE;
}

// The top-level element of an animation, and of an event.
export const ANIMATION_ELEMENT = "LinearAnimation";
export const EVENT_ELEMENT = "Event";
export const KEYED_OBJECT_ELEMENT = "KeyedObject";
export const KEYED_PROPERTY_ELEMENT = "KeyedProperty";

// A keyframe's type, by its element (KEYFRAME_ELEMENTS, the same order).
// The kind follows the property's (RIVE_MODEL.md section 3.1's table):
// Double for a Float (and a vector's component), Int for an Int that is
// not an enum (interpolated as a number, rounded), Uint for an enum (held),
// Bool, Color (ARGB), String (held), Id (a Resource, held: read, written
// and kept, not evaluated yet), Callback (no value: `event:<Name>` and
// `signal:<name>`), Quaternion (the `quaternion` property, slerped).
export enum KeyFrameKind {
    Double = 0,
    Color = 1,
    Bool = 2,
    Int = 3,
    Uint = 4,
    String = 5,
    Id = 6,
    Callback = 7,
    Quaternion = 8,
}

export const KEYFRAME_ELEMENTS: StaticArray<string> = [
    "KeyFrameDouble", "KeyFrameColor", "KeyFrameBool", "KeyFrameInt", "KeyFrameUint", "KeyFrameString", "KeyFrameId",
    "KeyFrameCallback", "KeyFrameQuaternion",
];

// The kind of a keyframe element, or -1 for a name that is none.
export function keyFrameKindOf(tag: string): i32 {
    for (let i = 0; i < KEYFRAME_ELEMENTS.length; i++) if (KEYFRAME_ELEMENTS[i] == tag) return i;
    return -1;
}

// How the segment leaving a key is interpolated (Rive's InterpolationType;
// INTERPOLATION_NAMES are RML's words, which the file writes). A keyframe
// without the attribute holds, Rive's default. Rive's `scripted` is refused
// by the reader.
export enum InterpolationType {
    Hold = 0,
    Linear = 1,
    Cubic = 2,
    CubicValue = 3,
    Elastic = 4,
}

export const INTERPOLATION_NAMES: StaticArray<string> = ["hold", "linear", "cubic", "cubicValue", "elastic"];

// The interpolation named `name`, or -1.
export function interpolationOf(name: string): i32 {
    for (let i = 0; i < INTERPOLATION_NAMES.length; i++) if (INTERPOLATION_NAMES[i] == name) return i;
    return -1;
}

// A keyframe's interpolator child (INTERPOLATOR_ELEMENTS, the same order).
// As in Rive, the child decides the curve: a CubicValueInterpolator under
// interpolationType="cubic" interpolates through values (rive's
// easing.md); the validator warns when the two disagree.
export enum InterpolatorKind {
    CubicEase = 0,
    CubicValue = 1,
    Elastic = 2,
}

export const INTERPOLATOR_ELEMENTS: StaticArray<string> = ["CubicEaseInterpolator", "CubicValueInterpolator", "ElasticInterpolator"];

// The kind of an interpolator element, or -1.
export function interpolatorKindOf(tag: string): i32 {
    for (let i = 0; i < INTERPOLATOR_ELEMENTS.length; i++) if (INTERPOLATOR_ELEMENTS[i] == tag) return i;
    return -1;
}

// Rive's Loop (LOOP_NAMES are RML's loopValue words).
export enum LoopMode {
    OneShot = 0,
    Loop = 1,
    PingPong = 2,
}

export const LOOP_NAMES: StaticArray<string> = ["oneShot", "loop", "pingPong"];

// The loop mode named `name`, or -1.
export function loopOf(name: string): i32 {
    for (let i = 0; i < LOOP_NAMES.length; i++) if (LOOP_NAMES[i] == name) return i;
    return -1;
}

// Rive's ElasticInterpolator easingValue (Easing): 0 easeIn, 1 easeOut (the
// default), 2 easeInOut; RML writes the number.
export const ELASTIC_EASE_IN: i32 = 0;
export const ELASTIC_EASE_OUT: i32 = 1;
export const ELASTIC_EASE_IN_OUT: i32 = 2;

// The property families a KeyedProperty may name besides the classes'
// animatable properties (../binding/targets.as): `event:<Name>` (on the
// scene's root only: fires the scene's Event <Name>), `signal:<name>` (on
// any node: emits that signal) and `quaternion` (any Node3D: its whole
// rotation, KeyFrameQuaternion).
export const EVENT_PROPERTY_PREFIX = "event:";
export const SIGNAL_PROPERTY_PREFIX = "signal:";
export const QUATERNION_PROPERTY = "quaternion";

// `<CubicEaseInterpolator x1 y1 x2 y2/>`, `<CubicValueInterpolator x1 y1 x2
// y2/>` (y1 and y2 in the property's units) or `<ElasticInterpolator
// easingValue amplitude period/>`, Rive's defaults.
export class InterpolatorDecl {
    kind: InterpolatorKind = InterpolatorKind.CubicEase;
    x1: f64 = 0.42;
    y1: f64 = 0;
    x2: f64 = 0.58;
    y2: f64 = 1;
    easingValue: i32 = ELASTIC_EASE_OUT;
    amplitude: f64 = 1;
    period: f64 = 1;
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(kind: InterpolatorKind = InterpolatorKind.CubicEase) {
        this.kind = kind;
    }

    clone(): InterpolatorDecl {
        const c = new InterpolatorDecl(this.kind);
        c.x1 = this.x1;
        c.y1 = this.y1;
        c.x2 = this.x2;
        c.y2 = this.y2;
        c.easingValue = this.easingValue;
        c.amplitude = this.amplitude;
        c.period = this.period;
        c.extraAttrs = this.extraAttrs.slice(0);
        c.extraChildren = this.extraChildren.slice(0);
        return c;
    }
}

// One key: `<KeyFrame<Kind> frame value interpolationType>` and its
// interpolator. Which value field holds the value goes by `kind`:
//
//   Double, Int, Uint   number (Int and Uint whole numbers)
//   Bool                boolean
//   Color               color (ARGB, as RML's "FF57A5E0")
//   String              text
//   Id                  text: the reference as written, `SubResource("id")`
//                       or `ExtResource("id")`
//   Callback            none
//   Quaternion          qx, qy, qz, qw (`value="x, y, z, w"`)
export class KeyFrameDecl {
    kind: KeyFrameKind;
    // Rive's frames are whole numbers (at the animation's fps).
    frame: i32 = 0;
    number: f64 = 0;
    boolean: bool = false;
    color: u32 = 0;
    text: string = "";
    qx: f64 = 0;
    qy: f64 = 0;
    qz: f64 = 0;
    qw: f64 = 1;
    interpolation: InterpolationType = InterpolationType.Hold;
    // The interpolator child (null: none; a cubic or elastic key without
    // one interpolates linearly, as in Rive).
    interpolator: InterpolatorDecl? = null;
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(kind: KeyFrameKind, frame: i32 = 0) {
        this.kind = kind;
        this.frame = frame;
    }

    // A copy (its interpolator copied too): copy and paste, the editor's
    // undo.
    clone(): KeyFrameDecl {
        const c = new KeyFrameDecl(this.kind, this.frame);
        c.number = this.number;
        c.boolean = this.boolean;
        c.color = this.color;
        c.text = this.text;
        c.qx = this.qx;
        c.qy = this.qy;
        c.qz = this.qz;
        c.qw = this.qw;
        c.interpolation = this.interpolation;
        const ip = this.interpolator;
        c.interpolator = ip != null ? ip.clone() : null;
        c.extraAttrs = this.extraAttrs.slice(0);
        c.extraChildren = this.extraChildren.slice(0);
        return c;
    }
}

// `<KeyedProperty property="...">` and its keys, in file order (the
// validator wants them in increasing frame, each frame once).
export class KeyedPropertyDecl {
    property: string;
    keys: Array<KeyFrameDecl> = [];
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(property: string) {
        this.property = property;
    }

    // The key at `frame`, or null.
    keyAt(frame: i32): KeyFrameDecl? {
        for (let i = 0; i < this.keys.length; i++) if (this.keys[i].frame == frame) return this.keys[i];
        return null;
    }
}

// `<KeyedObject target="...">` and its properties.
export class KeyedObjectDecl {
    // The node's path from the scene's root ("." the root itself).
    target: string;
    properties: Array<KeyedPropertyDecl> = [];
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(target: string) {
        this.target = target;
    }

    // The keyed property `property`, or null.
    property(property: string): KeyedPropertyDecl? {
        for (let i = 0; i < this.properties.length; i++) if (this.properties[i].property == property) return this.properties[i];
        return null;
    }
}

// `<LinearAnimation name fps duration speed loopValue workStart workEnd
// enableWorkArea quantize>`, Rive's fields with Rive's defaults (frames at
// `fps`; workStart and workEnd -1 when unset).
export class LinearAnimationDecl {
    name: string;
    fps: i32 = 60;
    duration: i32 = 60;
    speed: f64 = 1;
    loop: LoopMode = LoopMode.OneShot;
    workStart: i32 = -1;
    workEnd: i32 = -1;
    enableWorkArea: bool = false;
    quantize: bool = false;
    objects: Array<KeyedObjectDecl> = [];
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    extraChildren: Array<XmlNode> = [];

    constructor(name: string) {
        this.name = name;
    }

    // The keyed object of `target`, or null.
    object(target: string): KeyedObjectDecl? {
        for (let i = 0; i < this.objects.length; i++) if (this.objects[i].target == target) return this.objects[i];
        return null;
    }

    // The keyed property `property` of `target`, or null.
    keyed(target: string, property: string): KeyedPropertyDecl? {
        const o = this.object(target);
        return o != null ? o.property(property) : null;
    }
}

// An Event's custom property (RML's CustomPropertyNumber, String,
// Boolean), its value in `propertyValue` as RML writes it.
export enum CustomPropertyKind {
    Number = 0,
    String = 1,
    Boolean = 2,
}

export const CUSTOM_PROPERTY_ELEMENTS: StaticArray<string> = ["CustomPropertyNumber", "CustomPropertyString", "CustomPropertyBoolean"];

// The kind of a custom property element, or -1.
export function customPropertyKindOf(tag: string): i32 {
    for (let i = 0; i < CUSTOM_PROPERTY_ELEMENTS.length; i++) if (CUSTOM_PROPERTY_ELEMENTS[i] == tag) return i;
    return -1;
}

export class CustomPropertyDecl {
    kind: CustomPropertyKind;
    name: string;
    number: f64 = 0;
    text: string = "";
    boolean: bool = false;
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];

    constructor(kind: CustomPropertyKind, name: string) {
        this.kind = kind;
        this.name = name;
    }
}

// `<Event name="...">`: Rive's Event, its custom properties and its
// bindings (`<binding property="fire" path="..."/>`, a view model trigger
// the run time fires each time the event fires, which is how a scene's
// event reaches a Rive state machine).
export class EventDecl {
    name: string;
    properties: Array<CustomPropertyDecl> = [];
    bindings: Array<BindingDecl> = [];
    pos: XmlPos = new XmlPos();
    extraAttrs: Array<XmlAttr> = [];
    // Unknown child elements and comments, in order, after the properties
    // and bindings.
    extraChildren: Array<XmlNode> = [];

    constructor(name: string) {
        this.name = name;
    }

    // The custom property `name`, or null.
    property(name: string): CustomPropertyDecl? {
        for (let i = 0; i < this.properties.length; i++) if (this.properties[i].name == name) return this.properties[i];
        return null;
    }
}
