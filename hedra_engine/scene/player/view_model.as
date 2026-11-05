// Milestone 17: a built project's view model (docs/formats/RSCN.md,
// "Bindings"): the instance the host bound to the scene's artboard
// (Context.viewModel(), rive/data), read and written by path for the
// scene's bindings (../binding/binder.as) through the ViewModelValues seam
// (../binding/values.as). A path walks nested view models
// (ViewModel.getViewModel(segment).value); each path's property handle is
// looked up once and kept, so a frame allocates nothing once every bound
// path has been read. A path that names nothing reads as absent (the
// binder warned about it from the data already).
//
// Milestone 42: strings and enums too (a global view model's values come
// through here as well: ../runtime/feature_bindings.as RiveGlobals). A
// string or an enum's key is read into a kept buffer and compared with the
// last read's bytes (rive/bindings rive_data_string_get and enum_get, as
// ../runtime/scene3d.as StringReader reads Scene3D's strings), so a new
// string is made only when the value changed; an enum's keys are read once,
// when its path is looked up (PropertyEnum.values), to give its index.
//
// Milestone 46: triggerCount counts a trigger's firings (one listener per
// path, added once), which a state machine's trigger conditions compare
// with the count they last saw (../sm/instance.as).

import { ViewModel, PropertyBoolean, PropertyColor, PropertyEnum, PropertyNumber, PropertyString, PropertyTrigger } from "rive/data";
import { abi } from "rive/bindings";
import { VmKind } from "../riv/riv_info";
import { BoundValue, ViewModelValues, enumIndex } from "../binding/values";

// One path, looked up: its kind and, for the kinds a binding takes, its
// property's handle.
class VmHandle {
    kind: VmKind = VmKind.Other;
    number: PropertyNumber? = null;
    boolean: PropertyBoolean? = null;
    color: PropertyColor? = null;
    // A string's or an enum's (PropertyEnum is a PropertyString).
    text: PropertyString? = null;
    // An enum's keys, in order.
    keys: Array<string> = [];
    // Milestone 46: a trigger's, and how many times it fired since its
    // listener was added (the first triggerCount of its path).
    trigger: PropertyTrigger? = null;
    fired: i32 = 0;
    listening: bool = false;
    // The last string read: its bytes (UTF-16 code units, as the runtime
    // hands a string or an enum key over since rive 1.5.1), how many, and
    // the string made of them (-1: none read yet).
    private bytes: Uint8Array = new Uint8Array(32);
    private last: Uint8Array = new Uint8Array(32);
    private lastLength: i32 = -1;
    private lastText: string = "";

    // The string (or the enum's key), made anew only when its bytes
    // changed since the last read.
    readText(): string {
        const p = this.text;
        if (p == null) return "";
        const enumValue = this.kind == VmKind.Enum;
        const h = p.handle;
        const n = <i32>(enumValue ? abi.rive_data_enum_get(h, 0, 0) : abi.rive_data_string_get(h, 0, 0));
        if (n <= 0) {
            if (this.lastLength != 0) {
                this.lastLength = 0;
                this.lastText = "";
            }
            return this.lastText;
        }
        if (this.bytes.length < n) {
            this.bytes = new Uint8Array(n);
            this.last = new Uint8Array(n);
        }
        fillUnsafe(h, this.bytes, n, enumValue);
        if (n == this.lastLength && same(this.bytes, this.last, n)) return this.lastText;
        for (let i = 0; i < n; i++) unchecked(this.last[i] = unchecked(this.bytes[i]));
        this.lastLength = n;
        this.lastText = String.UTF16.decode(this.bytes.buffer.slice(0, n));
        return this.lastText;
    }
}

unsafe function fillUnsafe(handle: u32, into: Uint8Array, n: i32, enumValue: bool): void {
    if (enumValue) abi.rive_data_enum_get(handle, into.dataStart, <u32>n);
    else abi.rive_data_string_get(handle, into.dataStart, <u32>n);
}

function same(a: Uint8Array, b: Uint8Array, n: i32): bool {
    for (let i = 0; i < n; i++) if (unchecked(a[i]) != unchecked(b[i])) return false;
    return true;
}

export class RiveViewModelValues extends ViewModelValues {
    vm: ViewModel;
    // By path, what it names (an absent path too, as kind Other, so that it
    // is not looked up again every frame).
    private handles: Map<string, VmHandle> = new Map<string, VmHandle>();

    constructor(vm: ViewModel) {
        super();
        this.vm = vm;
    }

    // The handle of `path`, looked up the first time it is asked for.
    private handle(path: string): VmHandle {
        if (this.handles.has(path)) return this.handles.get(path);
        const h = lookUp(this.vm, path);
        this.handles.set(path, h);
        return h;
    }

    kindOf(path: string): VmKind {
        return this.handle(path).kind;
    }

    // Milestone 46: a trigger's firings, counted by one listener on its
    // PropertyTrigger, added the first time its path is asked (a state
    // machine's trigger condition asks when it resolves its path), so
    // counting allocates nothing afterwards.
    triggerCount(path: string): i32 {
        const h = this.handle(path);
        const t = h.trigger;
        if (t == null) return -1;
        if (!h.listening) {
            h.listening = true;
            t.addListenerWith<VmHandle>(h, onTriggerFired);
        }
        return h.fired;
    }

    enumKeys(path: string): Array<string>? {
        const h = this.handle(path);
        return h.kind == VmKind.Enum ? h.keys : null;
    }

    read(path: string, out: BoundValue): bool {
        const h = this.handle(path);
        const n = h.number;
        if (n != null) {
            out.setNumber(n.value);
            return true;
        }
        const b = h.boolean;
        if (b != null) {
            out.setBoolean(b.value);
            return true;
        }
        const c = h.color;
        if (c != null) {
            out.setColor(<u32>c.value);
            return true;
        }
        if (h.text == null) return false;
        const s = h.readText();
        if (h.kind == VmKind.Enum) out.setEnum(enumIndex(h.keys, s), s);
        else out.setString(s);
        return true;
    }

    write(path: string, v: BoundValue): bool {
        const h = this.handle(path);
        const n = h.number;
        if (n != null) {
            if (v.kind == VmKind.Number || v.kind == VmKind.Enum) n.value = v.number;
            else if (v.kind == VmKind.Boolean) n.value = v.boolean ? 1 : 0;
            else return false;
            return true;
        }
        const b = h.boolean;
        if (b != null) {
            if (v.kind == VmKind.Number) b.value = v.number != 0;
            else if (v.kind == VmKind.Boolean) b.value = v.boolean;
            else return false;
            return true;
        }
        const c = h.color;
        if (c != null) {
            if (v.kind != VmKind.Color) return false;
            c.value = v.color;
            return true;
        }
        const t = h.text;
        if (t == null) return false;
        if (h.kind == VmKind.String) {
            if (v.kind != VmKind.String && v.kind != VmKind.Enum) return false;
            t.value = v.text;
            return true;
        }
        // An enum: by its key, or a number as the index (a key it lacks
        // changes nothing).
        let i = -1;
        if (v.kind == VmKind.Enum || v.kind == VmKind.String) i = enumIndex(h.keys, v.text);
        else if (v.kind == VmKind.Number && v.number >= 0 && v.number == Math.floor(v.number)) i = <i32>v.number;
        if (i < 0 || i >= h.keys.length) return false;
        (t as PropertyEnum).value = h.keys[i];
        return true;
    }
}

// What `path` names in `vm`: each segment but the last a nested view model
// (getViewModel(segment).value), the last a property, tried kind by kind.
function lookUp(vm: ViewModel, path: string): VmHandle {
    const h = new VmHandle();
    if (path.length == 0) return h;
    const parts = path.split("/");
    let at = vm;
    for (let i = 0; i < parts.length - 1; i++) {
        if (parts[i].length == 0) return h;
        const nested = at.getViewModel(parts[i]);
        if (nested == null) return h;
        at = nested.value;
    }
    const name = parts[parts.length - 1];
    if (name.length == 0) return h;
    const n = at.getNumber(name);
    if (n != null) {
        h.kind = VmKind.Number;
        h.number = n;
        return h;
    }
    const b = at.getBoolean(name);
    if (b != null) {
        h.kind = VmKind.Boolean;
        h.boolean = b;
        return h;
    }
    const c = at.getColor(name);
    if (c != null) {
        h.kind = VmKind.Color;
        h.color = c;
        return h;
    }
    // (an enum before a string: PropertyEnum is a PropertyString)
    const e = at.getEnum(name);
    if (e != null) {
        h.kind = VmKind.Enum;
        h.text = e;
        h.keys = e.values();
        return h;
    }
    const s = at.getString(name);
    if (s != null) {
        h.kind = VmKind.String;
        h.text = s;
        return h;
    }
    // The kinds a binding does not take, told apart for kindOf alone (a
    // trigger kept: triggerCount counts its firings).
    const t = at.getTrigger(name);
    if (t != null) {
        h.kind = VmKind.Trigger;
        h.trigger = t;
    } else if (at.getViewModel(name) != null) h.kind = VmKind.ViewModel;
    else if (at.getList(name) != null) h.kind = VmKind.List;
    return h;
}

// A trigger's listener: one more firing.
function onTriggerFired(h: VmHandle): void {
    h.fired++;
}
