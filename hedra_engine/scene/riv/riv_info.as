// What Hedra reads of a Rive file (.riv, milestone 15): its artboards,
// each with its name, its size and its state machines, so that a
// RiveFile resource can say which artboards an ArtboardTexture may name,
// the tools can draw a placeholder in the artboard's aspect, and
// the CLI's `inspect --check` can tell a misspelt artboard or state machine.
// Milestone 17 adds its view models (their properties, instances and
// values, and the one each artboard binds), which a scene's bindings are
// resolved against (../binding/schema.as).
// Nothing here draws or runs an artboard: the Hedra program has no way to
// load another Rive file at run time (docs/formats/RSCN.md,
// "ArtboardTexture"), and only a project the CLI's `build` writes plays one.
//
// The binary format is the runtime's (host/shell/third_party/rive-runtime:
// runtime_header.hpp, core/binary_reader.cpp, file.cpp readRuntimeObject):
// the fingerprint "RIVE", the major and minor version and the file id as
// varuints; the table of contents (the property keys the file declares, a
// 0 ending them, then their field types two bits each in little-endian
// u32s, four keys to a u32: RuntimeHeader::read starts a new u32 every
// 8 bits, so the top 24 bits of each are unused); then the objects to the
// end of the file, each a varuint type key followed by (varuint property
// key, value) pairs ending with a 0 key. A value is read by its field type
// (riv_fields.as RIV_FIELD_*): a varuint (uint, id, int), a varuint length
// and that many bytes (string, bytes), a little-endian f32 (double), a
// little-endian u32 (colour) or one byte (bool).
//
// The field type of a key is the pinned runtime's (riv_fields.as,
// generated from its core registry by engine/tools/gen_riv_fields.py) and,
// for a key the runtime does not know, the table of contents': the order
// readRuntimeObject asks them in. The two agree on every key both type,
// except a bool, which the table can only call a varuint and which the
// runtime reads as one byte. So the reader skips every object and property
// it does not use, whatever runtime wrote the file, as long as its keys
// are typed one way or the other; one that is not leaves the rest of the
// file unreadable, as it does for the runtime ("malformed").
//
// What is kept: each Artboard (type key 1: name 4, width 7, height 8,
// defaultStateMachineId 236) in file order, and each StateMachine (type
// key 53: name 55) under the artboard before it, which is the one the
// runtime's importer adds it to; a StateMachine before any Artboard has
// no artboard to belong to and is ignored. defaultStateMachineId is an
// index into the artboard's state machines (Artboard::
// defaultStateMachineIndex): an index past the last one, and an absent
// property (kEmptyId, 0xFFFFFFFF), mean no default, and then an instance
// runs no state machine at all (ArtboardInstance::defaultStateMachine
// answers null; a scripted Artboard.instance() then plays nothing), even
// when the artboard has state machines.
//
// View models (milestone 17) are read as the runtime's importers attach
// them (file.cpp readRuntimeObject, backboard_importer.cpp, the viewmodel/
// importers). The CLI writes them after the Backboard and before the
// artboards, enums first: a DataEnumCustom (type key 438, name 572) and its
// DataEnumValues (445, key 578); then each ViewModel (435: name 557,
// viewModelType 981, 2 being global) followed by its ViewModelProperty*
// objects (name 557) and its ViewModelInstances (437: name 4, viewModelId
// 566), each followed by its values (ViewModelInstance*: viewModelPropertyId
// 554 and the value, number 575 an f32, boolean 593 a byte, color 555 a u32,
// string 561, enum 560, nested instance 577). So a property joins the latest
// ViewModel, an instance the view model its viewModelId indexes among those
// read so far, a value the latest instance; every id is an index: a
// property's viewModelReferenceId (565) and an artboard's viewModelId (583)
// into the file's view models, a value's property into its view model's
// properties, a nested value into the referenced view model's instances, an
// enum value into its enum's values, a custom enum property's enumId (574)
// into the file's enums (DataEnum and DataEnumCustom, in order). An index
// that names nothing is -1. The CLI leaves out a value that is the
// property's default (0, false, "", opaque black 0xFF000000 for a colour,
// index 0), keeping the value object; a property with no value object at
// all is unset (`rive --data-dump` prints null).
//
// The default instance is the first in file order: the runtime binds an
// artboard to its view model's instance 0 (File::
// createDefaultViewModelInstance, ViewModel::defaultInstance). RML's
// `defaultInstanceId` is editor-only: it is not in the .riv and changes
// nothing. tests/fixtures/riv/vm.riv's Room has instances Spare and Main
// with defaultInstanceId naming Main, and `rive <its source> --data-dump=-`
// binds Spare (open true, angle -12.5); with Main's <ViewModelInstance>
// moved first it binds Main (count 3), whatever defaultInstanceId says. So
// a build that wants another instance as the default puts it first.
//
// Cost: one pass over the bytes, no copy of a skipped value; a string is
// decoded only for the names kept, and an object that keeps nothing skips
// its properties without asking for each kept key. In a `rive --test` suite
// on an M-series Mac (1.2.0-uat.24), the binding sample's dial.riv (813
// bytes, 53 objects, one view model of 5 properties and 2 instances) reads
// in 64 to 66 microseconds, tests/fixtures/riv/vm.riv (735 bytes, 56
// objects, 3 view models) in 74, screen.riv (572 bytes, 48 objects, no view
// model) in 44 and scripted.riv (45,005 bytes, most of it one wasm script
// asset) in 25.

import { Result } from "../../base/util";
import { RIV_FIELD_BYTE, RIV_FIELD_BYTES, RIV_FIELD_F32, RIV_FIELD_U32, RIV_FIELD_VARUINT, rivFieldType } from "./riv_fields";

// One artboard of a Rive file.
export class RivArtboard {
    name: string = "";
    // Its size in points, as the file holds it (f32s).
    width: f32 = 0;
    height: f32 = 0;
    // Its state machines' names, in file order.
    stateMachines: Array<string> = [];
    // The index in `stateMachines` of the one an instance runs (Artboard's
    // defaultStateMachineId), or -1 when it has none.
    defaultStateMachine: i32 = -1;
    // Milestone 17: the index in RivInfo.viewModels of the view model the
    // artboard binds (Artboard's viewModelId), or -1 when it binds none.
    viewModel: i32 = -1;

    // The state machine an instance of the artboard runs: its default one,
    // "" when it has no state machine.
    defaultStateMachineName(): string {
        const i = this.defaultStateMachine;
        return i >= 0 && i < this.stateMachines.length ? this.stateMachines[i] : "";
    }

    hasStateMachine(name: string): bool {
        return this.stateMachines.includes(name);
    }
}

// Milestone 17: the kind of a view model property (the runtime's
// ViewModelProperty* classes; rive's docs/data.md "Property types").
// Bindings take Number, Boolean and Color (../binding/binding.as bindable);
// the others are read so that a message can say what a path names.
export enum VmKind {
    Number,
    String,
    Boolean,
    Color,
    // ViewModelPropertyEnumCustom and ViewModelPropertyEnumSystem.
    Enum,
    Trigger,
    // ViewModelPropertyViewModel: a nested view model (RivVmProperty.reference).
    ViewModel,
    List,
    // An image, artboard or any other kind this reader does not tell apart.
    Other,
}

export function vmKindName(k: VmKind): string {
    switch (k) {
        case VmKind.Number: return "number";
        case VmKind.String: return "string";
        case VmKind.Boolean: return "boolean";
        case VmKind.Color: return "color";
        case VmKind.Enum: return "enum";
        case VmKind.Trigger: return "trigger";
        case VmKind.ViewModel: return "view model";
        case VmKind.List: return "list";
        default: return "other";
    }
}

// One property of a view model.
export class RivVmProperty {
    name: string = "";
    kind: VmKind = VmKind.Other;
    // VmKind.ViewModel: the index in RivInfo.viewModels of the view model
    // it holds (viewModelReferenceId), -1 when unknown.
    reference: i32 = -1;
    // A custom enum (ViewModelPropertyEnumCustom): its values' keys, in
    // order, the order an instance's value indexes. Empty for a system enum,
    // whose values the runtime takes from its own tables, and other kinds.
    enumValues: Array<string> = [];
}

// One value of an instance: the property it sets (an index in its view
// model's `properties`) and the value, by the property's kind.
export class RivVmValue {
    property: i32 = -1;
    // The kind of the value object (its ViewModelInstance* class), which
    // the property's normally is too: a reader of `number` or `text` checks
    // that the two agree.
    kind: VmKind = VmKind.Other;
    // A Number's value (the file's f32); an Enum's index in its enum.
    number: f64 = 0;
    boolean: bool = false;
    // ARGB, as the file holds it (sRGB, straight alpha). A colour value
    // whose object leaves it out is opaque black (ViewModelInstanceColor's
    // default, 0xFF000000), which is why the CLI leaves that one out.
    color: u32 = 0;
    // String and Enum values (an enum's by its value's key when the file
    // says it; "" otherwise).
    text: string = "";
    // ViewModel: the index of the instance it holds, in the referenced view
    // model's `instances`; -1 when none.
    instance: i32 = -1;
}

// One instance of a view model.
export class RivVmInstance {
    name: string = "";
    values: Array<RivVmValue> = [];
}

// One view model of a Rive file.
export class RivViewModel {
    name: string = "";
    properties: Array<RivVmProperty> = [];
    instances: Array<RivVmInstance> = [];
    // The index in `instances` of the one an artboard binds when nothing
    // names another: 0, the first (the runtime's default, whatever RML's
    // defaultInstanceId said: the header), -1 when the view model has no
    // instance.
    defaultInstance: i32 = -1;
    // A global view model (viewModelType global): bound to no artboard.
    global: bool = false;

    property(name: string): RivVmProperty? {
        const i = this.propertyIndex(name);
        return i >= 0 ? this.properties[i] : null;
    }

    // The index of the property called `name` in `properties`, or -1.
    propertyIndex(name: string): i32 {
        for (let i = 0; i < this.properties.length; i++) if (this.properties[i].name == name) return i;
        return -1;
    }

    instance(name: string): RivVmInstance? {
        const i = this.instanceIndex(name);
        return i >= 0 ? this.instances[i] : null;
    }

    // The index of the instance called `name` in `instances` (the first,
    // when two share it), or -1.
    instanceIndex(name: string): i32 {
        for (let i = 0; i < this.instances.length; i++) if (this.instances[i].name == name) return i;
        return -1;
    }

    instanceNames(): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.instances.length; i++) out.push(this.instances[i].name);
        return out;
    }

    // The default instance's name, "" when the view model has none.
    defaultInstanceName(): string {
        const i = this.defaultInstance;
        return i >= 0 && i < this.instances.length ? this.instances[i].name : "";
    }
}

// What readRivInfo reads of a .riv.
export class RivInfo {
    // The header's version (7.3 for the pinned runtime's files).
    major: u32 = 0;
    minor: u32 = 0;
    artboards: Array<RivArtboard> = [];
    // Milestone 17: the file's view models, in file order.
    viewModels: Array<RivViewModel> = [];

    // The view model called `name`, or null.
    viewModel(name: string): RivViewModel? {
        for (let i = 0; i < this.viewModels.length; i++) if (this.viewModels[i].name == name) return this.viewModels[i];
        return null;
    }

    viewModelNames(): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.viewModels.length; i++) out.push(this.viewModels[i].name);
        return out;
    }

    // The artboard called `name` (the first, when two share it), or null.
    artboard(name: string): RivArtboard? {
        for (let i = 0; i < this.artboards.length; i++) if (this.artboards[i].name == name) return this.artboards[i];
        return null;
    }

    // The artboard names, in file order.
    artboardNames(): Array<string> {
        const out = new Array<string>();
        for (let i = 0; i < this.artboards.length; i++) out.push(this.artboards[i].name);
        return out;
    }
}

// The newest major version readRivInfo reads (the pinned runtime's).
export const RIV_MAJOR_VERSION: u32 = 7;

// The type and property keys kept (rive-runtime include/rive/generated:
// artboard_base.hpp, animation/state_machine_base.hpp).
const ARTBOARD_TYPE: u32 = 1;
const STATE_MACHINE_TYPE: u32 = 53;
const KEY_NAME: u32 = 4;
const KEY_WIDTH: u32 = 7;
const KEY_HEIGHT: u32 = 8;
const KEY_DEFAULT_STATE_MACHINE: u32 = 236;
const KEY_STATE_MACHINE_NAME: u32 = 55;
// Id's empty value (rive-runtime include/rive/core/id.hpp kEmptyId): what
// an artboard without defaultStateMachineId or viewModelId holds.
const EMPTY_ID: u64 = 0xFFFFFFFF;

// Milestone 17: view models (include/rive/generated/viewmodel/*_base.hpp,
// artboard_base.hpp).
const KEY_ARTBOARD_VIEW_MODEL: u32 = 583;
const VIEW_MODEL_TYPE: u32 = 435;
// ViewModelComponent's name, a view model's and a property's.
const KEY_VM_NAME: u32 = 557;
// ViewModelType: standard 0, textInput 1, global 2 (view_model_type.hpp).
const KEY_VM_TYPE: u32 = 981;
const VM_TYPE_GLOBAL: u64 = 2;
const KEY_VM_REFERENCE: u32 = 565;
const KEY_VM_ENUM: u32 = 574;
const VM_INSTANCE_TYPE: u32 = 437;
const KEY_VM_INSTANCE_VIEW_MODEL: u32 = 566;
const KEY_VM_VALUE_PROPERTY: u32 = 554;
const KEY_VM_NUMBER: u32 = 575;
const KEY_VM_BOOLEAN: u32 = 593;
const KEY_VM_COLOR: u32 = 555;
const KEY_VM_STRING: u32 = 561;
const KEY_VM_ENUM_VALUE: u32 = 560;
const KEY_VM_NESTED: u32 = 577;
// DataEnum and DataEnumCustom join the file's enums (File's m_Enums, which
// enumId indexes); a DataEnumValue joins the latest DataEnumCustom.
const DATA_ENUM_TYPE: u32 = 510;
const DATA_ENUM_CUSTOM_TYPE: u32 = 438;
const DATA_ENUM_VALUE_TYPE: u32 = 445;
const KEY_ENUM_VALUE_KEY: u32 = 578;
// ViewModelInstanceColor's default: what a colour value without its
// property holds.
const VM_COLOR_DEFAULT: u32 = 0xFF000000;

// What an object is to the reader.
const ROLE_OTHER: i32 = 0;
const ROLE_ARTBOARD: i32 = 1;
const ROLE_STATE_MACHINE: i32 = 2;
const ROLE_VIEW_MODEL: i32 = 3;
const ROLE_VM_PROPERTY: i32 = 4;
const ROLE_VM_INSTANCE: i32 = 5;
const ROLE_VM_VALUE: i32 = 6;
const ROLE_ENUM: i32 = 7;
const ROLE_ENUM_VALUE: i32 = 8;

// The kind of a ViewModelProperty* type key, or -1 for a type that is no
// view model property. The abstract bases (430 ViewModelProperty, 509
// ViewModelPropertyEnum, 584 ViewModelPropertyAsset, 563
// ViewModelPropertySymbol) are never written, but the runtime would read
// them as properties, so they are kinds too.
function vmPropertyKind(type: u32): i32 {
    switch (type) {
        case 431: return VmKind.Number;
        case 443: return VmKind.String;
        case 448: return VmKind.Boolean;
        case 440: return VmKind.Color;
        case 439: // EnumCustom
        case 511: // EnumSystem
        case 509: return VmKind.Enum;
        case 502: return VmKind.Trigger;
        case 436: return VmKind.ViewModel;
        case 434: return VmKind.List;
        case 430: // the base
        case 598: // artboard
        case 584: case 585: case 1034: case 1043: // assets: image, font, blob
        case 563: case 564: // symbols
            return VmKind.Other;
        default: return -1;
    }
}

// The kind of a ViewModelInstanceValue type key (the value objects an
// instance holds), or -1 for a type that is no value.
function vmValueKind(type: u32): i32 {
    switch (type) {
        case 442: return VmKind.Number;
        case 433: return VmKind.String;
        case 449: return VmKind.Boolean;
        case 426: return VmKind.Color;
        case 432: return VmKind.Enum;
        case 501: return VmKind.Trigger;
        case 444: return VmKind.ViewModel;
        case 441: return VmKind.List;
        case 428: // the base
        case 599: // artboard
        case 586: case 587: case 1035: case 1044: // assets
        case 565: case 566: // symbols
            return VmKind.Other;
        default: return -1;
    }
}

function roleOf(type: u32): i32 {
    if (type == ARTBOARD_TYPE) return ROLE_ARTBOARD;
    if (type == STATE_MACHINE_TYPE) return ROLE_STATE_MACHINE;
    if (type == VIEW_MODEL_TYPE) return ROLE_VIEW_MODEL;
    if (type == VM_INSTANCE_TYPE) return ROLE_VM_INSTANCE;
    if (type == DATA_ENUM_TYPE || type == DATA_ENUM_CUSTOM_TYPE) return ROLE_ENUM;
    if (type == DATA_ENUM_VALUE_TYPE) return ROLE_ENUM_VALUE;
    if (vmPropertyKind(type) >= 0) return ROLE_VM_PROPERTY;
    if (vmValueKind(type) >= 0) return ROLE_VM_VALUE;
    return ROLE_OTHER;
}

// An id property read as an index into a list of `count`: -1 when it names
// nothing (kEmptyId among them), as the runtime's bounds checks answer.
function indexOf(id: u64, count: i32): i32 {
    return id < <u64>count ? <i32>id : -1;
}

// A position in the bytes and the first failure. Each read checks the end
// of the file itself and leaves `err` set, so the parser tests `err` once
// a value instead of threading a Result through every varuint.
class RivCursor {
    bytes: Uint8Array;
    pos: i32 = 0;
    err: string = "";
    // The property being read (0 outside an object's properties), its
    // object's type key and where that object starts: only a failure's
    // message names them, so nothing is formatted for a value that reads.
    key: u32 = 0;
    type: u32 = 0;
    objectStart: i32 = 0;

    constructor(bytes: Uint8Array) {
        this.bytes = bytes;
    }

    get failed(): bool {
        return this.err.length > 0;
    }

    fail(msg: string): void {
        if (this.err.length == 0) this.err = msg;
    }

    truncated(at: i32, what: string): void {
        let whose = "";
        if (this.key != 0) {
            whose = " (property " + this.key.toString() + " of object type " + this.type.toString()
                + " from byte " + this.objectStart.toString() + ")";
        }
        this.fail("truncated at byte " + at.toString() + ": " + what + whose + " runs past the end of the "
            + this.bytes.length.toString() + "-byte file");
    }

    // A LEB128 varuint. Bits past 64 are dropped (the runtime's
    // decode_uint_leb shifts them out too); `bits32` fails a value that
    // does not fit a u32, as the runtime's readVarUintAs does for keys.
    varuint(what: string, bits32: bool): u64 {
        const start = this.pos;
        const n = this.bytes.length;
        let value: u64 = 0;
        let shift: u32 = 0;
        let wide = false;
        while (true) {
            if (this.pos >= n) {
                this.truncated(start, what);
                return 0;
            }
            const b = <u32>this.bytes[this.pos];
            this.pos++;
            const low = <u64>(b & 0x7F);
            if (shift < 64) {
                if (shift > 0 && (low >> (64 - <u64>shift)) != 0) wide = true;
                value |= low << <u64>shift;
            } else if (low != 0) {
                wide = true;
            }
            shift += 7;
            if ((b & 0x80) == 0) break;
        }
        if (bits32 && (wide || value > 0xFFFFFFFF)) {
            this.fail(what + " at byte " + start.toString() + " does not fit 32 bits");
            return 0;
        }
        return value;
    }

    // Moves past a varuint without decoding it.
    skipVaruint(what: string): void {
        const start = this.pos;
        const n = this.bytes.length;
        while (this.pos < n) {
            const b = this.bytes[this.pos];
            this.pos++;
            if ((b & 0x80) == 0) return;
        }
        this.truncated(start, what);
    }

    // Moves past `count` bytes; false (and `err`) when they are not there.
    skip(count: u64, start: i32, what: string): bool {
        if (count > <u64>(this.bytes.length - this.pos)) {
            this.truncated(start, what);
            return false;
        }
        this.pos += <i32>count;
        return true;
    }

    u32le(what: string): u32 {
        const start = this.pos;
        if (!this.skip(4, start, what)) return 0;
        const b = this.bytes;
        return <u32>b[start] | (<u32>b[start + 1] << 8) | (<u32>b[start + 2] << 16) | (<u32>b[start + 3] << 24);
    }

    // One byte (a bool): non-zero is true, as CoreBoolType reads it.
    byte(what: string): bool {
        const start = this.pos;
        if (!this.skip(1, start, what)) return false;
        return this.bytes[start] != 0;
    }

    f32le(what: string): f32 {
        return reinterpret<f32>(this.u32le(what));
    }

    // A varuint length and that many bytes, as UTF-8 text.
    str(what: string): string {
        const start = this.pos;
        const len = this.varuint(what, false);
        if (this.failed) return "";
        const at = this.pos;
        if (!this.skip(len, start, what)) return "";
        return String.UTF8.decodeUnsafe(this.bytes.dataStart + <usize>at, <usize>len);
    }

    // Moves past one value of field type `type`.
    skipValue(type: i32, what: string): void {
        if (type == RIV_FIELD_VARUINT) {
            this.skipVaruint(what);
        } else if (type == RIV_FIELD_BYTES) {
            const start = this.pos;
            const len = this.varuint(what, false);
            if (!this.failed) this.skip(len, start, what);
        } else if (type == RIV_FIELD_F32 || type == RIV_FIELD_U32) {
            this.skip(4, this.pos, what);
        } else if (type == RIV_FIELD_BYTE) {
            this.skip(1, this.pos, what);
        }
    }
}

// The field types the table of contents gives, for the keys the runtime
// does not know. A short list (16 keys in the screen sample), searched
// only for such keys.
class RivToc {
    keys: Array<u32> = [];
    types: Array<i32> = [];

    fieldType(key: u32): i32 {
        for (let i = 0; i < this.keys.length; i++) if (this.keys[i] == key) return this.types[i];
        return -1;
    }
}

function isRiveFingerprint(bytes: Uint8Array, n: i32): bool {
    // "RIVE"
    if (n > 0 && bytes[0] != 0x52) return false;
    if (n > 1 && bytes[1] != 0x49) return false;
    if (n > 2 && bytes[2] != 0x56) return false;
    if (n > 3 && bytes[3] != 0x45) return false;
    return true;
}

// Reads the artboards and view models of a .riv file's bytes. Fails, with a message that
// reads after "<file> is not a Rive file: ", on a missing fingerprint, a
// major version other than RIV_MAJOR_VERSION, a truncated file, or a
// property key whose field type neither the table of contents nor
// riv_fields.as gives.
export function readRivInfo(bytes: Uint8Array): Result<RivInfo> {
    const n = bytes.length;
    if (n == 0) return Result.fail<RivInfo>("the file is empty");
    if (!isRiveFingerprint(bytes, n < 4 ? n : 4)) return Result.fail<RivInfo>("no RIVE fingerprint");
    const c = new RivCursor(bytes);
    if (n < 4) {
        c.truncated(0, "the fingerprint");
        return Result.fail<RivInfo>(c.err);
    }
    c.pos = 4;
    const info = new RivInfo();
    const major = c.varuint("the major version", true);
    if (c.failed) return Result.fail<RivInfo>(c.err);
    if (major != <u64>RIV_MAJOR_VERSION) {
        return Result.fail<RivInfo>("major version " + major.toString() + "; Hedra reads " + RIV_MAJOR_VERSION.toString());
    }
    info.major = <u32>major;
    info.minor = <u32>c.varuint("the minor version", true);
    c.skipVaruint("the file id");
    if (c.failed) return Result.fail<RivInfo>(c.err);

    const toc = new RivToc();
    while (true) {
        const key = <u32>c.varuint("a table of contents key", true);
        if (c.failed) return Result.fail<RivInfo>(c.err);
        if (key == 0) break;
        toc.keys.push(key);
    }
    let packed: u32 = 0;
    let bit: u32 = 8;
    for (let i = 0; i < toc.keys.length; i++) {
        if (bit == 8) {
            packed = c.u32le("the table of contents' field types");
            if (c.failed) return Result.fail<RivInfo>(c.err);
            bit = 0;
        }
        toc.types.push(<i32>((packed >> bit) & 3));
        bit += 2;
    }

    // The default state machine and view model ids, resolved once each
    // artboard's state machines, and every view model, are read.
    const defaults = new Array<u64>();
    const boardViewModels = new Array<u64>();
    // Nested properties' viewModelReferenceIds, resolved at the end too: a
    // view model may hold one declared after it.
    const refProps = new Array<RivVmProperty>();
    const refIds = new Array<u64>();
    // The file's enums' keys (File's m_Enums), and the latest custom one,
    // which a DataEnumValue joins.
    const enums = new Array<Array<string>>();
    let customEnum: Array<string>? = null;
    let current: RivArtboard? = null;
    // The latest view model, which a property joins, and the latest
    // instance, which a value joins: the runtime's import stack.
    let vm: RivViewModel? = null;
    let instance: RivVmInstance? = null;
    while (c.pos < n) {
        const typeStart = c.pos;
        c.key = 0;
        const type = <u32>c.varuint("an object's type key", true);
        if (c.failed) return Result.fail<RivInfo>(c.err);
        let role = roleOf(type);
        if (role == ROLE_STATE_MACHINE && current == null) role = ROLE_OTHER;
        if (role == ROLE_VM_PROPERTY && vm == null) role = ROLE_OTHER;
        if (role == ROLE_VM_VALUE && instance == null) role = ROLE_OTHER;
        if (role == ROLE_ENUM_VALUE && customEnum == null) role = ROLE_OTHER;
        let board: RivArtboard? = null;
        if (role == ROLE_ARTBOARD) {
            board = new RivArtboard();
            info.artboards.push(board);
            defaults.push(EMPTY_ID);
            boardViewModels.push(EMPTY_ID);
            current = board;
        }
        // The object being read, by its role; each kept only once read.
        let model: RivViewModel? = null;
        let property: RivVmProperty? = null;
        let inst: RivVmInstance? = null;
        let value: RivVmValue? = null;
        let reference: u64 = 0;
        let enumId: u64 = EMPTY_ID;
        let instanceOf: u64 = 0;
        let enumKey = "";
        if (role == ROLE_VIEW_MODEL) {
            model = new RivViewModel();
        } else if (role == ROLE_VM_PROPERTY) {
            property = new RivVmProperty();
            property.kind = <VmKind>vmPropertyKind(type);
        } else if (role == ROLE_VM_INSTANCE) {
            inst = new RivVmInstance();
        } else if (role == ROLE_VM_VALUE) {
            value = new RivVmValue();
            value.kind = <VmKind>vmValueKind(type);
            // The defaults of an Id property (0) and of a colour: what an
            // object that leaves them out holds.
            value.property = 0;
            if (value.kind == VmKind.Color) value.color = VM_COLOR_DEFAULT;
            if (value.kind == VmKind.ViewModel) value.instance = 0;
        }
        let machine = "";
        while (true) {
            const keyStart = c.pos;
            c.key = 0;
            const key = <u32>c.varuint("a property key", true);
            if (c.failed) return Result.fail<RivInfo>(c.err + " (object type " + type.toString() + " from byte " + typeStart.toString() + ")");
            if (key == 0) break;
            let field = rivFieldType(key);
            if (field < 0) field = toc.fieldType(key);
            if (field < 0) {
                return Result.fail<RivInfo>("property key " + key.toString() + " of object type " + type.toString()
                    + " has no known field type (byte " + keyStart.toString() + ")");
            }
            c.key = key;
            c.type = type;
            c.objectStart = typeStart;
            const what = field == RIV_FIELD_BYTES ? "a string" : "a value";
            // Most objects keep nothing: skipped without asking each kept
            // key in turn.
            if (role == ROLE_OTHER) {
                c.skipValue(field, what);
                if (c.failed) return Result.fail<RivInfo>(c.err);
                continue;
            }
            const isVaruint = field == RIV_FIELD_VARUINT;
            if (board != null && key == KEY_NAME && field == RIV_FIELD_BYTES) {
                board.name = c.str(what);
            } else if (board != null && (key == KEY_WIDTH || key == KEY_HEIGHT) && field == RIV_FIELD_F32) {
                const v = c.f32le(what);
                if (key == KEY_WIDTH) board.width = v;
                else board.height = v;
            } else if (board != null && key == KEY_DEFAULT_STATE_MACHINE && isVaruint) {
                defaults[defaults.length - 1] = c.varuint(what, false);
            } else if (board != null && key == KEY_ARTBOARD_VIEW_MODEL && isVaruint) {
                boardViewModels[boardViewModels.length - 1] = c.varuint(what, false);
            } else if (role == ROLE_STATE_MACHINE && key == KEY_STATE_MACHINE_NAME && field == RIV_FIELD_BYTES) {
                machine = c.str(what);
            } else if (model != null && key == KEY_VM_NAME && field == RIV_FIELD_BYTES) {
                model.name = c.str(what);
            } else if (model != null && key == KEY_VM_TYPE && isVaruint) {
                model.global = c.varuint(what, false) == VM_TYPE_GLOBAL;
            } else if (property != null && key == KEY_VM_NAME && field == RIV_FIELD_BYTES) {
                property.name = c.str(what);
            } else if (property != null && key == KEY_VM_REFERENCE && isVaruint) {
                reference = c.varuint(what, false);
            } else if (property != null && key == KEY_VM_ENUM && isVaruint) {
                enumId = c.varuint(what, false);
            } else if (inst != null && key == KEY_NAME && field == RIV_FIELD_BYTES) {
                inst.name = c.str(what);
            } else if (inst != null && key == KEY_VM_INSTANCE_VIEW_MODEL && isVaruint) {
                instanceOf = c.varuint(what, false);
            } else if (value != null && key == KEY_VM_VALUE_PROPERTY && isVaruint) {
                value.property = indexOf(c.varuint(what, false), i32.MAX_VALUE);
            } else if (value != null && key == KEY_VM_NUMBER && field == RIV_FIELD_F32) {
                value.number = <f64>c.f32le(what);
            } else if (value != null && key == KEY_VM_BOOLEAN && field == RIV_FIELD_BYTE) {
                value.boolean = c.byte(what);
            } else if (value != null && key == KEY_VM_COLOR && field == RIV_FIELD_U32) {
                value.color = c.u32le(what);
            } else if (value != null && key == KEY_VM_STRING && field == RIV_FIELD_BYTES) {
                value.text = c.str(what);
            } else if (value != null && key == KEY_VM_ENUM_VALUE && isVaruint) {
                value.number = <f64>c.varuint(what, false);
            } else if (value != null && key == KEY_VM_NESTED && isVaruint) {
                value.instance = indexOf(c.varuint(what, false), i32.MAX_VALUE);
            } else if (role == ROLE_ENUM_VALUE && key == KEY_ENUM_VALUE_KEY && field == RIV_FIELD_BYTES) {
                enumKey = c.str(what);
            } else {
                c.skipValue(field, what);
            }
            if (c.failed) return Result.fail<RivInfo>(c.err);
        }
        // Each object joins what it belongs to once read whole, as the
        // runtime's importers add it.
        if (role == ROLE_STATE_MACHINE && current != null) {
            current.stateMachines.push(machine);
        } else if (model != null) {
            info.viewModels.push(model);
            vm = model;
        } else if (property != null && vm != null) {
            if (property.kind == VmKind.ViewModel) {
                refProps.push(property);
                refIds.push(reference);
            }
            // Only a custom enum property resolves its enum (File::
            // readRuntimeObject), against the enums read so far.
            if (type == 439) {
                const e = indexOf(enumId, enums.length);
                if (e >= 0) property.enumValues = enums[e];
            }
            vm.properties.push(property);
        } else if (inst != null) {
            // An instance joins the view model its viewModelId indexes among
            // those read so far (BackboardImporter::addViewModelInstance);
            // one that indexes none still takes the values that follow.
            const owner = indexOf(instanceOf, info.viewModels.length);
            if (owner >= 0) info.viewModels[owner].instances.push(inst);
            instance = inst;
        } else if (value != null && instance != null) {
            instance.values.push(value);
        } else if (role == ROLE_ENUM) {
            const keys = new Array<string>();
            enums.push(keys);
            if (type == DATA_ENUM_CUSTOM_TYPE) customEnum = keys;
        } else if (role == ROLE_ENUM_VALUE && customEnum != null) {
            customEnum.push(enumKey);
        }
    }

    for (let i = 0; i < info.artboards.length; i++) {
        const a = info.artboards[i];
        const id = defaults[i];
        a.defaultStateMachine = id < <u64>a.stateMachines.length ? <i32>id : -1;
        a.viewModel = indexOf(boardViewModels[i], info.viewModels.length);
    }
    for (let i = 0; i < refProps.length; i++) refProps[i].reference = indexOf(refIds[i], info.viewModels.length);
    for (let i = 0; i < info.viewModels.length; i++) {
        const m = info.viewModels[i];
        m.defaultInstance = m.instances.length > 0 ? 0 : -1;
        // An enum value's key, now that its view model's properties are all
        // known.
        for (let j = 0; j < m.instances.length; j++) {
            const values = m.instances[j].values;
            for (let k = 0; k < values.length; k++) {
                const v = values[k];
                if (v.kind != VmKind.Enum || v.property < 0 || v.property >= m.properties.length) continue;
                const keys = m.properties[v.property].enumValues;
                const e = indexOf(<u64>v.number, keys.length);
                if (e >= 0) v.text = keys[e];
            }
        }
    }
    return Result.okv<RivInfo>(info);
}
