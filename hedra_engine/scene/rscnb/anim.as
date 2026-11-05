// The ANIM section of a binary scene (milestone 45, docs/plans/
// RIVE_MODEL.md section 4.6): a scene's timelines, its Events and
// LinearAnimations (../anim/decl.as), so that a built scene plays them
// without reading any text. codec.as writes it exactly when the document
// has an Event or a LinearAnimation; a scene without any has no ANIM, so
// its .rscnb is byte for byte what it was before. It comes after SRCS and
// before STMC and BNDS (format.as OPTIONAL_SECTION_ORDER).
//
// Self-contained as BNDS is: its strings are its own (`str` is u32 n, then
// n bytes of UTF-8), not indices into STRS. Numbers are the f64 the text
// gave, so that text, binary and text again are the same bytes (the
// engine compiles them to f32: ../anim/animation.as); node paths and
// property names stay strings, resolved when the scene is instanced as the
// text's are (a path through an instanced scene names nothing known when
// the scene is built).
//
//   u32 version = 1
//   u32 nEvents, nEvents x event
//     event = str name,
//             u32 nProps x (u8 kind, str name, f64 number | str text | u8 boolean, attrs),
//             u32 nBindings x (str property, str path, str mode, str once, str global,
//                              str converter, attrs),
//             extras
//   u32 nAnimations, nAnimations x animation
//     animation = str name, u32 fps, u32 duration, f64 speed, u8 loop, i32 workStart,
//                 i32 workEnd, u8 enableWorkArea, u8 quantize, extras,
//                 u32 nObjects x (str target, extras, u32 nProps x property),
//                 u32 nInterpolators x (u8 kind, f64 a, f64 b, f64 c, f64 d, extras)
//     property  = str property, extras, u8 keyKind, u32 nKeys,
//                 (keyKind 255 only: nKeys x u8 kind),
//                 nKeys x u32 frame,
//                 the values, key by key, by the key's kind: Double, Int, Uint an f64;
//                   Bool a u8; Color a u32 (ARGB); String, Id a str; Quaternion 4 f64;
//                   Callback nothing,
//                 nKeys x u8 interpolationType,
//                 nKeys x i32 interpolator (an index into the animation's table, -1 none),
//                 nKeys x extras
//     an interpolator's a b c d: CubicEase and CubicValue x1 y1 x2 y2; Elastic
//     easingValue (as an f64), amplitude, period, 0
//   attrs  = u32 n x (str name, str value)
//   extras = attrs, u32 nChildren x str xml
//
// `attrs` are the attributes the writer does not write itself (unknown
// ones; a binding's scale, offset and convert too, which have no field
// here), and `extras` the element's kept children too, each as its XML
// text (read back with the codec's XML reader); the unknown attributes and
// the children only with RSCNB_FLAG_FIDELITY, as FIDL keeps them for the
// other sections. A property whose keys are all of one kind (every one a
// valid file has) writes that kind as keyKind; one with mixed kinds (the
// validator's keyframe-type error, kept as written) writes 255 and each
// key's kind. A reader of this version reads these fields and ignores
// bytes after them, so a later version may append fields. docs/scene/
// RSCN.md, "Binary scenes", is normative.

import { XmlAttr, XmlNode } from "../../base/xml";
import { BindingDecl, EntryKind, RscnDoc } from "../rscn/doc";
import {
    CustomPropertyDecl, CustomPropertyKind, ELASTIC_EASE_IN_OUT, EventDecl, InterpolationType, InterpolatorDecl, InterpolatorKind,
    KeyFrameDecl, KeyFrameKind, KeyedObjectDecl, KeyedPropertyDecl, LinearAnimationDecl, LoopMode, finiteAsF32,
} from "../anim/decl";
import { BinReader } from "./bin";

// The section's own version (its first field).
export const ANIM_VERSION: u32 = 1;

// A property's keyKind when its keys are of more than one kind.
export const ANIM_MIXED_KINDS: u32 = 255;

// The binding attributes the record holds in fields of its own (the rest
// go in its attrs).
export const BINDING_FIELDS: Array<string> = ["property", "path", "mode", "once", "global", "converter"];
// A binding's known attributes that have no field here: written always.
export const BINDING_KEPT: Array<string> = ["scale", "offset", "convert"];

// A reader of the codec's: XML texts (one node each) to nodes, or null
// when they are not that many well-formed nodes (codec.as parseXmlNodes).
export type XmlNodesReader = (texts: Array<string>) => Array<XmlNode>?;

// What an ANIM section holds: the document's events and animations in
// document order (ORDR names each by its index here).
export class AnimData {
    events: Array<EventDecl> = [];
    animations: Array<LinearAnimationDecl> = [];
}

// Whether `doc` needs an ANIM section: an Event or a LinearAnimation.
export function animNeeded(doc: RscnDoc): bool {
    for (let i = 0; i < doc.entries.length; i++) {
        const e = doc.entries[i];
        if (e.kind == EntryKind.Event && e.event != null) return true;
        if (e.kind == EntryKind.Animation && e.animation != null) return true;
    }
    return false;
}

// --- encoding

// --- decoding

// (each count is checked against the bytes left at the least a record
// can take: an event 20 bytes, a custom property 10, a binding 28, an
// animation 47, an object 16, a property 17, a key 17, an interpolator 41)

class AnimReader {
    r: BinReader;
    fidelity: bool;
    // The kept children's XML texts, and the list each goes into once
    // parsed (in one go, at the end).
    texts: Array<string> = [];
    owners: Array<Array<XmlNode>> = [];

    constructor(r: BinReader, fidelity: bool) {
        this.r = r;
        this.fidelity = fidelity;
    }

    str(): string {
        const n = this.r.count(1);
        return this.r.utf8(n);
    }

    attrs(into: Array<XmlAttr>, what: string): void {
        const r = this.r;
        const n = r.count(8);
        for (let k = 0; k < n && !r.failed; k++) {
            const name = this.str();
            const value = this.str();
            into.push(new XmlAttr(name, value));
        }
        if (!r.failed && n > 0 && !this.fidelity) r.fail(what + " has unknown attributes in a file without fidelity");
    }

    extras(attrs: Array<XmlAttr>, children: Array<XmlNode>, what: string): void {
        this.attrs(attrs, what);
        const r = this.r;
        const n = r.count(4);
        if (!r.failed && n > 0 && !this.fidelity) {
            r.fail(what + " keeps children in a file without fidelity");
            return;
        }
        for (let k = 0; k < n && !r.failed; k++) {
            this.texts.push(this.str());
            this.owners.push(children);
        }
    }

    // A u8 that must be at most `max`.
    small(max: u32, what: string): u32 {
        const v = this.r.u8();
        if (!this.r.failed && v > max) this.r.fail(what + " is " + v.toString() + ", not 0 to " + max.toString());
        return v;
    }

    // A u32 that must fit in an i32 and be at least `min`.
    whole(min: i32, what: string): i32 {
        const v = this.r.u32();
        if (!this.r.failed && (v > <u32>i32.MAX_VALUE || <i32>v < min)) this.r.fail(what + " is " + v.toString());
        return <i32>v;
    }

    event(index: i32): EventDecl {
        const r = this.r;
        const d = new EventDecl(this.str());
        const what = "event " + index.toString();
        const nProps = r.count(10);
        for (let k = 0; k < nProps && !r.failed; k++) {
            const kind = this.small(<u32>CustomPropertyKind.Boolean, what + "'s property " + k.toString() + "'s kind");
            const p = new CustomPropertyDecl(<CustomPropertyKind>kind, this.str());
            if (kind == <u32>CustomPropertyKind.Number) p.number = r.f64();
            else if (kind == <u32>CustomPropertyKind.Boolean) p.boolean = this.small(1, what + "'s boolean") == 1;
            else p.text = this.str();
            this.attrs(p.extraAttrs, what + "'s property " + k.toString());
            d.properties.push(p);
        }
        const nBindings = r.count(28);
        for (let k = 0; k < nBindings && !r.failed; k++) {
            const b = new BindingDecl(this.str(), this.str());
            b.mode = this.str();
            b.once = this.str();
            b.global = this.str();
            b.converter = this.str();
            const n = r.count(8);
            for (let j = 0; j < n && !r.failed; j++) {
                const a = new XmlAttr(this.str(), this.str());
                if (a.name == "scale") b.scale = a.value;
                else if (a.name == "offset") b.offset = a.value;
                else if (a.name == "convert") b.convert = a.value;
                else if (!this.fidelity) r.fail(what + "'s binding has unknown attributes in a file without fidelity");
                b.attrs.push(a);
            }
            d.bindings.push(b);
        }
        this.extras(d.extraAttrs, d.extraChildren, what);
        return d;
    }

    animation(index: i32): LinearAnimationDecl? {
        const r = this.r;
        const d = new LinearAnimationDecl(this.str());
        const what = "animation " + index.toString();
        d.fps = this.whole(1, what + "'s fps");
        d.duration = this.whole(0, what + "'s duration");
        d.speed = r.f64();
        // (as the check refuses it: a speed past f32's range is an infinite
        // step to the engine)
        if (!r.failed && !finiteAsF32(d.speed)) r.fail(what + "'s speed is " + d.speed.toString() + ", beyond a 32-bit float");
        d.loop = <LoopMode>this.small(<u32>LoopMode.PingPong, what + "'s loop");
        d.workStart = r.i32();
        d.workEnd = r.i32();
        if (!r.failed && (d.workStart < -1 || d.workEnd < -1)) r.fail(what + "'s work area starts or ends below -1");
        d.enableWorkArea = this.small(1, what + "'s enableWorkArea") == 1;
        // (as the check refuses them: a range of no frames, or a reversed
        // one, would make a loop's time NaN or a pingPong bounce forever)
        if (!r.failed && d.enableWorkArea && (d.workStart < 0 || d.workEnd <= d.workStart)) {
            r.fail(what + "'s work area is enabled but does not run forward from frame 0 or later");
        }
        if (!r.failed && !d.enableWorkArea && d.duration == 0 && d.loop != LoopMode.OneShot) r.fail(what + " loops over no frames");
        d.quantize = this.small(1, what + "'s quantize") == 1;
        this.extras(d.extraAttrs, d.extraChildren, what);
        // The keys' interpolator indices, resolved once the table is read.
        const keys = new Array<KeyFrameDecl>();
        const indices = new Array<i32>();
        const nObjects = r.count(16);
        for (let k = 0; k < nObjects && !r.failed; k++) {
            const o = new KeyedObjectDecl(this.str());
            this.extras(o.extraAttrs, o.extraChildren, what + "'s object " + k.toString());
            const nProps = r.count(17);
            for (let j = 0; j < nProps && !r.failed; j++) {
                const p = this.keyedProperty(what + "'s object " + k.toString() + " property " + j.toString(), keys, indices);
                if (p != null) o.properties.push(p);
            }
            d.objects.push(o);
        }
        if (!this.interpolators(keys, indices, what)) return null;
        return d;
    }

    // The interpolator table, and each key of `keys` given the entry its
    // index (`indices`, parallel) names; false when it cannot be read.
    interpolators(keys: Array<KeyFrameDecl>, indices: Array<i32>, what: string): bool {
        const r = this.r;
        const nTable = r.count(41);
        const table = new Array<InterpolatorDecl>();
        for (let k = 0; k < nTable && !r.failed; k++) {
            const kind = this.small(<u32>InterpolatorKind.Elastic, what + "'s interpolator " + k.toString() + "'s kind");
            const ip = new InterpolatorDecl(<InterpolatorKind>kind);
            const a = r.f64();
            const b = r.f64();
            const c = r.f64();
            const e = r.f64();
            // (as the check: the engine reads them as f32s)
            if (!r.failed && !(finiteAsF32(a) && finiteAsF32(b) && finiteAsF32(c) && finiteAsF32(e))) {
                r.fail(what + "'s interpolator " + k.toString() + " has a number beyond a 32-bit float");
            }
            if (kind == <u32>InterpolatorKind.Elastic) {
                if (!r.failed && !(a >= 0 && a <= <f64>ELASTIC_EASE_IN_OUT && a == Math.floor(a))) {
                    r.fail(what + "'s interpolator " + k.toString() + "'s easingValue is not 0, 1 or 2");
                }
                ip.easingValue = <i32>a;
                ip.amplitude = b;
                ip.period = c;
            } else {
                ip.x1 = a;
                ip.y1 = b;
                ip.x2 = c;
                ip.y2 = e;
            }
            this.extras(ip.extraAttrs, ip.extraChildren, what + "'s interpolator " + k.toString());
            table.push(ip);
        }
        if (r.failed) return false;
        // Each key its own interpolator (a table entry named twice is
        // copied: two keys never share one, which an edit would change).
        const used = new Uint8Array(table.length);
        for (let k = 0; k < keys.length; k++) {
            const i = indices[k];
            if (i < 0) continue;
            if (i >= table.length) {
                r.fail(what + " names interpolator " + i.toString() + " of " + table.length.toString());
                return false;
            }
            keys[k].interpolator = used[i] != 0 ? table[i].clone() : table[i];
            used[i] = 1;
        }
        return true;
    }

    keyedProperty(what: string, keys: Array<KeyFrameDecl>, indices: Array<i32>): KeyedPropertyDecl? {
        const r = this.r;
        const p = new KeyedPropertyDecl(this.str());
        this.extras(p.extraAttrs, p.extraChildren, what);
        const kind = r.u8();
        if (!r.failed && kind > <u32>KeyFrameKind.Quaternion && kind != ANIM_MIXED_KINDS) r.fail(what + "'s key kind is " + kind.toString());
        const n = r.count(17);
        if (r.failed) return null;
        const kinds = new Array<KeyFrameKind>(n);
        for (let k = 0; k < n; k++) {
            kinds[k] = kind == ANIM_MIXED_KINDS ? <KeyFrameKind>this.small(<u32>KeyFrameKind.Quaternion, what + "'s key kind")
                : <KeyFrameKind>kind;
        }
        for (let k = 0; k < n; k++) p.keys.push(new KeyFrameDecl(kinds[k], this.whole(0, what + "'s frame")));
        for (let k = 0; k < n && !r.failed; k++) this.value(p.keys[k], what);
        for (let k = 0; k < n; k++) {
            p.keys[k].interpolation = <InterpolationType>this.small(<u32>InterpolationType.Elastic, what + "'s interpolation");
        }
        for (let k = 0; k < n; k++) {
            const i = r.i32();
            if (!r.failed && i < -1) r.fail(what + "'s interpolator index is " + i.toString());
            keys.push(p.keys[k]);
            indices.push(i);
        }
        for (let k = 0; k < n && !r.failed; k++) this.extras(p.keys[k].extraAttrs, p.keys[k].extraChildren, what + "'s key " + k.toString());
        return r.failed ? null : p;
    }

    value(k: KeyFrameDecl, what: string): void {
        const r = this.r;
        switch (k.kind) {
            case KeyFrameKind.Double:
            case KeyFrameKind.Int:
            case KeyFrameKind.Uint:
                k.number = r.f64();
                if (!r.failed && !finiteAsF32(k.number)) r.fail(what + "'s value is beyond a 32-bit float");
                return;
            case KeyFrameKind.Bool:
                k.boolean = this.small(1, what + "'s boolean") == 1;
                return;
            case KeyFrameKind.Color:
                k.color = r.u32();
                return;
            case KeyFrameKind.String:
            case KeyFrameKind.Id:
                k.text = this.str();
                return;
            case KeyFrameKind.Quaternion:
                k.qx = r.f64();
                k.qy = r.f64();
                k.qz = r.f64();
                k.qw = r.f64();
                if (!r.failed && !(finiteAsF32(k.qx) && finiteAsF32(k.qy) && finiteAsF32(k.qz) && finiteAsF32(k.qw))) {
                    r.fail(what + "'s value is beyond a 32-bit float");
                }
                return;
            default:
                return;
        }
    }
}

// The section's `bytes` read, its kept children parsed with `xml`; null
// with why not in `why[0]`: a newer version, a count past the end, a kind
// or a flag out of range, an interpolator index past the table, children
// that are not XML (or kept in a file without `fidelity`).
export function decodeAnim(bytes: Uint8Array, fidelity: bool, xml: XmlNodesReader, why: Array<string>): AnimData? {
    const r = new BinReader(bytes);
    const version = r.u32();
    if (!r.failed && version != ANIM_VERSION) {
        why.push("its version is " + version.toString() + ", this build reads " + ANIM_VERSION.toString());
        return null;
    }
    const a = new AnimReader(r, fidelity);
    const out = new AnimData();
    const nEvents = r.count(20);
    for (let k = 0; k < nEvents && !r.failed; k++) out.events.push(a.event(k));
    const nAnimations = r.count(47);
    for (let k = 0; k < nAnimations && !r.failed; k++) {
        const d = a.animation(k);
        if (d != null) out.animations.push(d);
    }
    if (r.failed) {
        why.push(r.why);
        return null;
    }
    if (a.texts.length > 0) {
        const nodes = xml(a.texts);
        if (nodes == null) {
            why.push("its kept children are not " + a.texts.length.toString() + " well-formed XML nodes");
            return null;
        }
        for (let k = 0; k < nodes.length; k++) a.owners[k].push(nodes[k]);
    }
    return out;
}

// --- keyed properties alone (milestone 48)

// What writeKeyedProperties wrote, read from `r` (`what` names it in the
// reason); null when it cannot be read (`r.why` says why).
export function readKeyedProperties(r: BinReader, what: string): Array<KeyedPropertyDecl>? {
    const a = new AnimReader(r, false);
    const keys = new Array<KeyFrameDecl>();
    const indices = new Array<i32>();
    const out = new Array<KeyedPropertyDecl>();
    const n = r.count(17);
    for (let k = 0; k < n && !r.failed; k++) {
        const p = a.keyedProperty(what + "'s track " + k.toString(), keys, indices);
        if (p != null) out.push(p);
    }
    if (r.failed || !a.interpolators(keys, indices, what)) return null;
    return out;
}
