// The read side of a glTF document: accessor iteration, the mesh, animation
// and skin readers, the normalizing casts to f32 / u32 / u16, node
// transforms, and the few document accessors the importer uses.
//
// Readers return flat typed arrays (items of 3 floats become a Float32Array
// with 3 floats per item), or null when there is nothing to read. Buffer
// data are looked up by index (`buffers[b.index]`): a missing buffer makes
// the reader null.
//
// Byte arithmetic wraps: `count - 1` for an empty accessor leaves an empty
// (or no) slice instead of panicking.

import { panic, signumF32, maxF32, f32ToU8, f32ToU16 } from "../../../base/util";
import { JsonValue, JsonKind, JsonNumberKind } from "../../../base/json";
import {
    Root, Accessor, BufferView, Node, Primitive, KhrLight, Semantic, SemanticKind, ComponentType, AccessorType,
    Property, componentTypeSize, accessorTypeMultiplicity, unwrapChecked,
} from "./doc";

const UNWRAP_NONE = "called `Option::unwrap()` on a `None` value";

// Accessor `i`; panics when there is none.
function accessorAt(root: Root, i: i32): Accessor {
    if (i < 0 || i >= root.accessors.length) panic(UNWRAP_NONE);
    return root.accessors[i];
}

// Buffer view `i`; panics when there is none.
function viewAt(root: Root, i: i32): BufferView {
    if (i < 0 || i >= root.bufferViews.length) panic(UNWRAP_NONE);
    return root.bufferViews[i];
}

// ---------------------------------------------------------------------------
// Wrapper accessors

// Accessor::offset (byteOffset, 0 when absent).
export function accessorOffset(a: Accessor): u64 {
    return a.byteOffset >= 0 ? <u64>a.byteOffset : 0;
}

// An accessor's component type (panics on CHECKED_INVALID).
export function accessorDataType(a: Accessor): ComponentType {
    return <ComponentType>unwrapChecked(a.componentType);
}

// An accessor's element type (panics on CHECKED_INVALID).
export function accessorDimensions(a: Accessor): AccessorType {
    return <AccessorType>unwrapChecked(a.type_);
}

// Accessor::size: bytes per element.
export function accessorSize(a: Accessor): i32 {
    return componentTypeSize(accessorDataType(a)) * accessorTypeMultiplicity(accessorDimensions(a));
}

// View::offset
export function viewOffset(v: BufferView): u64 {
    return v.byteOffset >= 0 ? <u64>v.byteOffset : 0;
}

// A buffer view's byte stride, or -1 for None (0 counts as None).
export function viewStride(v: BufferView): i64 {
    return v.byteStride > 0 ? v.byteStride : -1;
}

// Document::default_scene: the scene index, or -1.
export function defaultScene(root: Root): i32 {
    const s = root.scene;
    if (s < 0) return -1;
    if (s >= root.scenes.length) panic(UNWRAP_NONE);
    return s;
}

// Document::lights: null when the document has no KHR_lights_punctual.
export function documentLights(root: Root): Array<KhrLight>? {
    const e = root.extensions;
    if (e == null) return null;
    const k = e.khrLightsPunctual;
    if (k == null) return null;
    return k.lights;
}

// Node::light: the light index, or -1.
export function nodeLight(root: Root, node: Node): i32 {
    const e = node.extensions;
    if (e == null) return -1;
    const k = e.khrLightsPunctual;
    if (k == null) return -1;
    const lights = documentLights(root);
    if (lights == null) panic(UNWRAP_NONE);
    if (k.light < 0 || k.light >= (lights as Array<KhrLight>).length) panic(UNWRAP_NONE);
    return k.light;
}

// Primitive::get: the accessor index for a semantic, or -1.
export function primitiveGet(root: Root, p: Primitive, s: Semantic): i32 {
    const i = p.attributes.get(s);
    if (i < 0) return -1;
    accessorAt(root, i);
    return i;
}

// A primitive's mode (panics on CHECKED_INVALID).
export function primitiveMode(p: Primitive): i32 {
    return unwrapChecked(p.mode);
}

// mesh::BoundingBox
export class BoundingBox {
    min: StaticArray<f32> = [0, 0, 0];
    max: StaticArray<f32> = [0, 0, 0];
}

// Three f32s from a JSON array; panics when `v` is not one.
function f32x3(v: JsonValue?): StaticArray<f32> {
    if (v == null) panic(UNWRAP_NONE);
    const x = v as JsonValue;
    const out = new StaticArray<f32>(3);
    const items = x.items;
    if (x.kind != JsonKind.Array || items == null || items.length != 3) {
        panic("called `Result::unwrap()` on an `Err` value");
        return out;
    }
    for (let i = 0; i < 3; i++) {
        const n = items[i];
        if (n.kind != JsonKind.Number) panic("called `Result::unwrap()` on an `Err` value");
        if (n.numKind == JsonNumberKind.PosInt) out[i] = <f32>n.u;
        else if (n.numKind == JsonNumberKind.NegInt) out[i] = <f32>n.i;
        else out[i] = <f32>n.f;
    }
    return out;
}

// Primitive::bounding_box: POSITION's min/max (panics when absent).
export function primitiveBoundingBox(root: Root, p: Primitive): BoundingBox {
    const i = p.attributes.get(Semantic.of(SemanticKind.Positions));
    if (i < 0) panic(UNWRAP_NONE);
    const a = accessorAt(root, i);
    const b = new BoundingBox();
    b.min = f32x3(a.min);
    b.max = f32x3(a.max);
    return b;
}

// ---------------------------------------------------------------------------
// accessor::Iter

// The bytes of `view` (`buffer_view_slice`), or null.
function viewSlice(root: Root, buffers: Array<Uint8Array>, view: BufferView): Uint8Array? {
    if (view.buffer < 0 || view.buffer >= root.buffers.length) panic(UNWRAP_NONE);
    if (view.buffer >= buffers.length) return null;
    const data = buffers[view.buffer];
    const start = viewOffset(view);
    const end = start + view.byteLength;
    if (end < start || end > <u64>data.length) return null;
    return data.subarray(<i32>start, <i32>end);
}

// `slice[start, end)` with `end = start + stride * (count - 1) + size` in
// wrapping u64 arithmetic, or null when out of range.
function subSlice(slice: Uint8Array, start: u64, stride: u64, count: u64, size: u64): Uint8Array? {
    const end = start + stride * (count - 1) + size;
    if (start > end || end > <u64>slice.length) return null;
    return slice.subarray(<i32>start, <i32>end);
}

// The element type `T` of an `Iter<T>`: `comps` components of `comp`.
class ItemType {
    comp: ComponentType;
    comps: i32;
    constructor(comp: ComponentType, comps: i32) {
        this.comp = comp;
        this.comps = comps;
    }
    get size(): i32 {
        return componentTypeSize(this.comp) * this.comps;
    }
}

// A component's raw bits: signed integers sign-extended to 32 bits, f32 as
// its bit pattern (so NaN payloads survive).
function readComponent(d: DataView, at: i32, c: ComponentType): u32 {
    switch (c) {
        case ComponentType.I8: return <u32><i32>d.getInt8(at);
        case ComponentType.U8: return <u32>d.getUint8(at);
        case ComponentType.I16: return <u32><i32>d.getInt16(at, true);
        case ComponentType.U16: return <u32>d.getUint16(at, true);
        default: return d.getUint32(at, true);
    }
}

// accessor::util::ItemIter over `data` with `stride`.
class ItemIter {
    data: Uint8Array;
    stride: i32;
    t: ItemType;
    pos: i32 = 0; // bytes consumed

    constructor(data: Uint8Array, stride: i32, t: ItemType) {
        this.data = data;
        this.stride = stride;
        this.t = t;
    }

    // ItemIter::size_hint / count
    count(): i32 {
        const len = this.data.length - this.pos;
        return len / this.stride + (len % this.stride >= this.t.size ? 1 : 0);
    }

    // next(): writes the item into out[at..at+comps]; false at the end.
    next(out: Uint32Array, at: i32): bool {
        const len = this.data.length - this.pos;
        let step = 0;
        if (len >= this.stride) step = this.stride;
        else if (len >= this.t.size) step = this.t.size;
        else return false;
        // T::from_slice asserts (or indexes past) a slice shorter than T.
        if (step < this.t.size) panic("assertion failed: slice.len() >= " + this.t.comps.toString() + " * mem::size_of::<T>()");
        const d = new DataView(this.data.buffer, this.data.byteOffset + this.pos, step);
        const cs = componentTypeSize(this.t.comp);
        for (let k = 0; k < this.t.comps; k++) out[at + k] = readComponent(d, k * cs, this.t.comp);
        this.pos += step;
        return true;
    }
}

// Every item of an accessor: `comps`
// components per item, as raw bits (see readComponent), or null when the
// accessor cannot be read.
export function accessorItems(root: Root, buffers: Array<Uint8Array>, accessor: i32, comp: ComponentType, comps: i32): Uint32Array? {
    const a = accessorAt(root, accessor);
    const t = new ItemType(comp, comps);
    const size = <u64>t.size;
    const count = a.count;
    const sparse = a.sparse;
    if (sparse != null) {
        let base: ItemIter? = null;
        if (a.bufferView >= 0) {
            const view = viewAt(root, a.bufferView);
            const vs = viewStride(view);
            const stride: u64 = vs > 0 ? <u64>vs : size;
            const slice = viewSlice(root, buffers, view);
            if (slice == null) return null;
            const sub = subSlice(slice, accessorOffset(a), stride, count, size);
            if (sub == null) return null;
            base = new ItemIter(sub, <i32>stride, t);
        }
        // indices
        const iview = viewAt(root, sparse.indices.bufferView);
        const itype = <ComponentType>unwrapChecked(sparse.indices.componentType);
        const isize = <u64>componentTypeSize(itype);
        const ivs = viewStride(iview);
        const istride: u64 = ivs > 0 ? <u64>ivs : isize;
        const islice = viewSlice(root, buffers, iview);
        if (islice == null) return null;
        const isub = subSlice(islice, sparse.indices.byteOffset, istride, sparse.count, isize);
        if (isub == null) return null;
        const indices = new ItemIter(isub, <i32>istride, new ItemType(itype, 1));
        // values
        const vview = viewAt(root, sparse.values.bufferView);
        const vvs = viewStride(vview);
        const vstride: u64 = vvs > 0 ? <u64>vvs : size;
        const vslice = viewSlice(root, buffers, vview);
        if (vslice == null) return null;
        const vsub = subSlice(vslice, sparse.values.byteOffset, vstride, sparse.count, size);
        if (vsub == null) return null;
        const values = new ItemIter(vsub, <i32>vstride, t);
        // SparseIter
        const out: Array<u32> = [];
        const item = new Uint32Array(comps);
        const idx = new Uint32Array(1);
        let hasPeek = indices.next(idx, 0);
        let counter: u32 = 0;
        while (true) {
            if (base != null) {
                if (!base.next(item, 0)) break;
            } else if (<u64>counter < count) {
                for (let k = 0; k < comps; k++) item[k] = 0;
            } else {
                break;
            }
            if (hasPeek && idx[0] == counter) {
                hasPeek = indices.next(idx, 0);
                if (!values.next(item, 0)) panic(UNWRAP_NONE);
            }
            counter++;
            for (let k = 0; k < comps; k++) out.push(item[k]);
        }
        const r = new Uint32Array(out.length);
        for (let k = 0; k < out.length; k++) r[k] = out[k];
        return r;
    }
    if (a.bufferView < 0) return null;
    const view = viewAt(root, a.bufferView);
    const vs = viewStride(view);
    const stride: u64 = vs > 0 ? <u64>vs : size;
    const slice = viewSlice(root, buffers, view);
    if (slice == null) return null;
    const sub = subSlice(slice, accessorOffset(a), stride, count, size);
    if (sub == null) return null;
    const it = new ItemIter(sub, <i32>stride, t);
    const n = it.count();
    const r = new Uint32Array(n * comps);
    for (let i = 0; i < n; i++) it.next(r, i * comps);
    return r;
}

// f32 items from their bits.
function toF32(v: Uint32Array?): Float32Array? {
    if (v == null) return null;
    const out = new Float32Array(v.length);
    for (let i = 0; i < v.length; i++) out[i] = reinterpret<f32>(v[i]);
    return out;
}

// ---------------------------------------------------------------------------
// Normalize: integer components to f32

const RECIP_127: f32 = <f32>1.0 / <f32>127.0;
const RECIP_255: f32 = <f32>1.0 / <f32>255.0;
const RECIP_32767: f32 = <f32>1.0 / <f32>32767.0;
const RECIP_65535: f32 = <f32>1.0 / <f32>65535.0;

// `Normalize<f32>` of a component of type `c` (its raw bits).
export function normalizeToF32(bits: u32, c: ComponentType): f32 {
    switch (c) {
        case ComponentType.I8:
        case ComponentType.I16: {
            const x = <f32><i32>bits;
            return maxF32(x * (c == ComponentType.I8 ? RECIP_127 : RECIP_32767), -1.0);
        }
        case ComponentType.U8: return <f32>bits * RECIP_255;
        case ComponentType.U16: return <f32>bits * RECIP_65535;
        case ComponentType.U32: return <f32>bits;
        default: return reinterpret<f32>(bits);
    }
}

// A reader over one of several component types (ReadTexCoords, ReadWeights,
// Rotations, MorphTargetWeights, ReadIndices, ReadJoints): the data type
// and the components' raw bits (see readComponent), `comps` per item.
export class TypedRead {
    dataType: ComponentType;
    comps: i32;
    raw: Uint32Array;
    constructor(dataType: ComponentType, comps: i32, raw: Uint32Array) {
        this.dataType = dataType;
        this.comps = comps;
        this.raw = raw;
    }

    // Number of items (ExactSizeIterator::len / count).
    get count(): i32 {
        return this.raw.length / this.comps;
    }

    // into_f32: every component normalized.
    intoF32(): Float32Array {
        const out = new Float32Array(this.raw.length);
        for (let i = 0; i < this.raw.length; i++) out[i] = normalizeToF32(this.raw[i], this.dataType);
        return out;
    }

    // ReadIndices::into_u32 (u8 / u16 / u32 widened).
    intoU32(): Uint32Array {
        const out = new Uint32Array(this.raw.length);
        for (let i = 0; i < this.raw.length; i++) out[i] = this.raw[i];
        return out;
    }

    // ReadJoints::into_u16 (`x as u16`).
    intoU16(): Uint16Array {
        const out = new Uint16Array(this.raw.length);
        for (let i = 0; i < this.raw.length; i++) out[i] = <u16>this.raw[i];
        return out;
    }
}

function typedRead(root: Root, buffers: Array<Uint8Array>, accessor: i32, allowed: Array<ComponentType>, comps: i32): TypedRead? {
    const dt = accessorDataType(accessorAt(root, accessor));
    if (!allowed.includes(dt)) panic("internal error: entered unreachable code");
    const raw = accessorItems(root, buffers, accessor, dt, comps);
    if (raw == null) return null;
    return new TypedRead(dt, comps, raw);
}

const TEX_TYPES: Array<ComponentType> = [ComponentType.U8, ComponentType.U16, ComponentType.F32];
const INDEX_TYPES: Array<ComponentType> = [ComponentType.U8, ComponentType.U16, ComponentType.U32];
const JOINT_TYPES: Array<ComponentType> = [ComponentType.U8, ComponentType.U16];
const ANIM_TYPES: Array<ComponentType> = [
    ComponentType.I8, ComponentType.U8, ComponentType.I16, ComponentType.U16, ComponentType.F32,
];

// ---------------------------------------------------------------------------
// mesh::util::colors: ReadColors and its casting iterators

// Normalize<u8> of a component (u8 / u16 / f32 bits).
function normalizeToU8(bits: u32, c: ComponentType): u8 {
    if (c == ComponentType.U8) return <u8>bits;
    if (c == ComponentType.U16) return <u8>(bits / 0x100);
    return f32ToU8(maxF32(reinterpret<f32>(bits), 0.0) * <f32>255.0);
}

// Normalize<u16> of a component.
function normalizeToU16(bits: u32, c: ComponentType): u16 {
    if (c == ComponentType.U8) return <u16>(bits * 0x100);
    if (c == ComponentType.U16) return <u16>bits;
    return f32ToU16(maxF32(reinterpret<f32>(bits), 0.0) * <f32>65535.0);
}

// ReadColors: RgbU8 / RgbU16 / RgbF32 (comps 3) or RgbaU8 / RgbaU16 /
// RgbaF32 (comps 4), the components' raw bits.
export class ColorsRead {
    dataType: ComponentType;
    comps: i32;
    raw: Uint32Array;
    constructor(dataType: ComponentType, comps: i32, raw: Uint32Array) {
        this.dataType = dataType;
        this.comps = comps;
        this.raw = raw;
    }

    get count(): i32 {
        return this.raw.length / this.comps;
    }

    // into_rgb_u8: the first three channels, normalized.
    intoRgbU8(): Uint8Array {
        const n = this.count;
        const out = new Uint8Array(n * 3);
        for (let i = 0; i < n; i++) {
            for (let k = 0; k < 3; k++) out[i * 3 + k] = normalizeToU8(this.raw[i * this.comps + k], this.dataType);
        }
        return out;
    }

    intoRgbU16(): Uint16Array {
        const n = this.count;
        const out = new Uint16Array(n * 3);
        for (let i = 0; i < n; i++) {
            for (let k = 0; k < 3; k++) out[i * 3 + k] = normalizeToU16(this.raw[i * this.comps + k], this.dataType);
        }
        return out;
    }

    intoRgbF32(): Float32Array {
        const n = this.count;
        const out = new Float32Array(n * 3);
        for (let i = 0; i < n; i++) {
            for (let k = 0; k < 3; k++) out[i * 3 + k] = normalizeToF32(this.raw[i * this.comps + k], this.dataType);
        }
        return out;
    }

    // into_rgba_u8: normalized, then an RGB item gets alpha u8::MAX.
    intoRgbaU8(): Uint8Array {
        const n = this.count;
        const out = new Uint8Array(n * 4);
        for (let i = 0; i < n; i++) {
            for (let k = 0; k < 4; k++) {
                out[i * 4 + k] = k < this.comps ? normalizeToU8(this.raw[i * this.comps + k], this.dataType) : 255;
            }
        }
        return out;
    }

    intoRgbaU16(): Uint16Array {
        const n = this.count;
        const out = new Uint16Array(n * 4);
        for (let i = 0; i < n; i++) {
            for (let k = 0; k < 4; k++) {
                out[i * 4 + k] = k < this.comps ? normalizeToU16(this.raw[i * this.comps + k], this.dataType) : 65535;
            }
        }
        return out;
    }

    intoRgbaF32(): Float32Array {
        const n = this.count;
        const out = new Float32Array(n * 4);
        for (let i = 0; i < n; i++) {
            for (let k = 0; k < 4; k++) {
                out[i * 4 + k] = k < this.comps ? normalizeToF32(this.raw[i * this.comps + k], this.dataType) : <f32>1.0;
            }
        }
        return out;
    }
}

// ---------------------------------------------------------------------------
// mesh::Reader

// One morph target's readers (ReadMorphTargets item).
export class MorphTargetRead {
    positions: Float32Array? = null;
    normals: Float32Array? = null;
    tangents: Float32Array? = null; // [f32; 3] displacements
}

export class PrimitiveReader {
    root: Root;
    buffers: Array<Uint8Array>;
    prim: Primitive;

    constructor(root: Root, prim: Primitive, buffers: Array<Uint8Array>) {
        this.root = root;
        this.prim = prim;
        this.buffers = buffers;
    }

    private f32Attr(s: Semantic, comps: i32): Float32Array? {
        const i = primitiveGet(this.root, this.prim, s);
        if (i < 0) return null;
        return toF32(accessorItems(this.root, this.buffers, i, ComponentType.F32, comps));
    }

    // Iter<[f32; 3]>, whatever the accessor's component type.
    readPositions(): Float32Array? {
        return this.f32Attr(Semantic.of(SemanticKind.Positions), 3);
    }

    readNormals(): Float32Array? {
        return this.f32Attr(Semantic.of(SemanticKind.Normals), 3);
    }

    // Iter<[f32; 4]>.
    readTangents(): Float32Array? {
        return this.f32Attr(Semantic.of(SemanticKind.Tangents), 4);
    }

    // ReadIndices (U8 / U16 / U32): `.intoU32()`.
    readIndices(): TypedRead? {
        const i = this.prim.indices;
        if (i < 0) return null;
        accessorAt(this.root, i);
        return typedRead(this.root, this.buffers, i, INDEX_TYPES, 1);
    }

    // ReadJoints (U8 / U16, [_; 4]): `.intoU16()`.
    readJoints(set: u32): TypedRead? {
        const i = primitiveGet(this.root, this.prim, Semantic.joints(set));
        if (i < 0) return null;
        return typedRead(this.root, this.buffers, i, JOINT_TYPES, 4);
    }

    // ReadTexCoords (U8 / U16 / F32, [_; 2]): `.intoF32()`.
    readTexCoords(set: u32): TypedRead? {
        const i = primitiveGet(this.root, this.prim, Semantic.texCoords(set));
        if (i < 0) return null;
        return typedRead(this.root, this.buffers, i, TEX_TYPES, 2);
    }

    // ReadWeights (U8 / U16 / F32, [_; 4]): `.intoF32()`.
    readWeights(set: u32): TypedRead? {
        const i = primitiveGet(this.root, this.prim, Semantic.weights(set));
        if (i < 0) return null;
        return typedRead(this.root, this.buffers, i, TEX_TYPES, 4);
    }

    // ReadColors (U8 / U16 / F32 × VEC3 / VEC4): `.intoRgbF32()` etc.
    readColors(set: u32): ColorsRead? {
        const i = primitiveGet(this.root, this.prim, Semantic.colors(set));
        if (i < 0) return null;
        const a = this.root.accessors[i];
        // `match (accessor.data_type(), accessor.dimensions())`
        const dt = accessorDataType(a);
        const dim = accessorDimensions(a);
        const okType = dt == ComponentType.U8 || dt == ComponentType.U16 || dt == ComponentType.F32;
        const okDim = dim == AccessorType.Vec3 || dim == AccessorType.Vec4;
        if (!okType || !okDim) panic("internal error: entered unreachable code");
        const comps = dim == AccessorType.Vec3 ? 3 : 4;
        const raw = accessorItems(this.root, this.buffers, i, dt, comps);
        if (raw == null) return null;
        return new ColorsRead(dt, comps, raw);
    }

    // ReadMorphTargets collected: one entry per target.
    readMorphTargets(): Array<MorphTargetRead> {
        const out: Array<MorphTargetRead> = [];
        const ts = this.prim.targets;
        if (ts == null) return out;
        for (let k = 0; k < ts.length; k++) {
            const t = ts[k];
            const r = new MorphTargetRead();
            if (t.positions >= 0) {
                accessorAt(this.root, t.positions);
                r.positions = toF32(accessorItems(this.root, this.buffers, t.positions, ComponentType.F32, 3));
            }
            if (t.normals >= 0) {
                accessorAt(this.root, t.normals);
                r.normals = toF32(accessorItems(this.root, this.buffers, t.normals, ComponentType.F32, 3));
            }
            if (t.tangents >= 0) {
                accessorAt(this.root, t.tangents);
                r.tangents = toF32(accessorItems(this.root, this.buffers, t.tangents, ComponentType.F32, 3));
            }
            out.push(r);
        }
        return out;
    }
}

// ---------------------------------------------------------------------------
// animation::util::Reader

// ReadOutputs: the channel's property and its values (`comps` per item:
// 3 for translations and scales, 4 for rotations, 1 for weights).
export class ReadOutputs {
    property: Property;
    read: TypedRead;
    constructor(property: Property, read: TypedRead) {
        this.property = property;
        this.read = read;
    }
    // Translations / Scales: the f32 values as read.
    // Rotations / MorphTargetWeights: `into_f32()`.
    intoF32(): Float32Array {
        return this.read.intoF32();
    }
}

export class ChannelReader {
    root: Root;
    buffers: Array<Uint8Array>;
    animation: i32;
    channel: i32;

    constructor(root: Root, animation: i32, channel: i32, buffers: Array<Uint8Array>) {
        this.root = root;
        this.animation = animation;
        this.channel = channel;
        this.buffers = buffers;
    }

    private samplerIndex(): i32 {
        const a = this.root.animations[this.animation];
        const c = a.channels[this.channel];
        if (c.sampler < 0 || c.sampler >= a.samplers.length) panic(UNWRAP_NONE);
        return c.sampler;
    }

    // Iter<f32> over the sampler's input.
    readInputs(): Float32Array? {
        const s = this.root.animations[this.animation].samplers[this.samplerIndex()];
        return toF32(accessorItems(this.root, this.buffers, s.input, ComponentType.F32, 1));
    }

    readOutputs(): ReadOutputs? {
        const a = this.root.animations[this.animation];
        const s = a.samplers[this.samplerIndex()];
        const out = s.output;
        // The output accessor is checked before the target property.
        accessorAt(this.root, out);
        const prop = <Property>unwrapChecked(a.channels[this.channel].target.path);
        if (prop == Property.Translation || prop == Property.Scale) {
            const raw = accessorItems(this.root, this.buffers, out, ComponentType.F32, 3);
            if (raw == null) return null;
            return new ReadOutputs(prop, new TypedRead(ComponentType.F32, 3, raw));
        }
        const r = typedRead(this.root, this.buffers, out, ANIM_TYPES, prop == Property.Rotation ? 4 : 1);
        if (r == null) return null;
        return new ReadOutputs(prop, r);
    }
}

// ---------------------------------------------------------------------------
// skin::util::Reader

// Iter<[[f32; 4]; 4]> over the inverse bind matrices: 16 floats per matrix,
// column major.
export function readInverseBindMatrices(root: Root, skin: i32, buffers: Array<Uint8Array>): Float32Array? {
    const s = root.skins[skin];
    if (s.inverseBindMatrices < 0) return null;
    accessorAt(root, s.inverseBindMatrices);
    return toF32(accessorItems(root, buffers, s.inverseBindMatrices, ComponentType.F32, 16));
}

// ---------------------------------------------------------------------------
// scene::Transform (matrix and TRS math, f32 throughout)

// A Matrix4 as 16 floats, column major (`[[f32; 4]; 4]`).
function m4(): StaticArray<f32> {
    return new StaticArray<f32>(16);
}

// Matrix4 * Matrix4: column j = a*r.j.x + b*r.j.y + c*r.j.z + d*r.j.w.
function mul4(a: StaticArray<f32>, r: StaticArray<f32>): StaticArray<f32> {
    const out = m4();
    for (let j = 0; j < 4; j++) {
        const x = r[j * 4];
        const y = r[j * 4 + 1];
        const z = r[j * 4 + 2];
        const w = r[j * 4 + 3];
        for (let row = 0; row < 4; row++) {
            out[j * 4 + row] = a[row] * x + a[4 + row] * y + a[8 + row] * z + a[12 + row] * w;
        }
    }
    return out;
}

// Decomposed TRS.
export class Decomposed {
    translation: StaticArray<f32> = [0, 0, 0];
    rotation: StaticArray<f32> = [0, 0, 0, 1]; // [x, y, z, w]
    scale: StaticArray<f32> = [1, 1, 1];
}

// A node's transform: a matrix, or translation / rotation / scale.
export class NodeTransform {
    isMatrix: bool = false;
    m: StaticArray<f32> = m4(); // Matrix
    translation: StaticArray<f32> = [0, 0, 0];
    rotation: StaticArray<f32> = [0, 0, 0, 1];
    scale: StaticArray<f32> = [1, 1, 1];

    // Transform::matrix: the matrix, or translation * rotation * scale.
    matrix(): StaticArray<f32> {
        if (this.isMatrix) {
            const out = m4();
            for (let i = 0; i < 16; i++) out[i] = this.m[i];
            return out;
        }
        const t = this.translation;
        const r = this.rotation;
        const s = this.scale;
        // Matrix4::from_translation
        const tm = m4();
        tm[0] = 1; tm[5] = 1; tm[10] = 1; tm[15] = 1;
        tm[12] = t[0]; tm[13] = t[1]; tm[14] = t[2];
        // The rotation matrix of the quaternion (x, y, z, w).
        const qx = r[0];
        const qy = r[1];
        const qz = r[2];
        const qs = r[3];
        const x2 = qx + qx;
        const y2 = qy + qy;
        const z2 = qz + qz;
        const xx2 = x2 * qx;
        const xy2 = x2 * qy;
        const xz2 = x2 * qz;
        const yy2 = y2 * qy;
        const yz2 = y2 * qz;
        const zz2 = z2 * qz;
        const sy2 = y2 * qs;
        const sz2 = z2 * qs;
        const sx2 = x2 * qs;
        const rm = m4();
        rm[0] = <f32>1.0 - yy2 - zz2; rm[1] = xy2 + sz2; rm[2] = xz2 - sy2; rm[3] = 0;
        rm[4] = xy2 - sz2; rm[5] = <f32>1.0 - xx2 - zz2; rm[6] = yz2 + sx2; rm[7] = 0;
        rm[8] = xz2 + sy2; rm[9] = yz2 - sx2; rm[10] = <f32>1.0 - xx2 - yy2; rm[11] = 0;
        rm[12] = 0; rm[13] = 0; rm[14] = 0; rm[15] = 1;
        // Matrix4::from_nonuniform_scale
        const sm = m4();
        sm[0] = s[0]; sm[5] = s[1]; sm[10] = s[2]; sm[15] = 1;
        return mul4(mul4(tm, rm), sm);
    }

    // Transform::decomposed: TRS as given, or extracted from the matrix.
    decomposed(): Decomposed {
        const d = new Decomposed();
        if (!this.isMatrix) {
            for (let i = 0; i < 3; i++) d.translation[i] = this.translation[i];
            for (let i = 0; i < 4; i++) d.rotation[i] = this.rotation[i];
            for (let i = 0; i < 3; i++) d.scale[i] = this.scale[i];
            return d;
        }
        const m = this.m;
        d.translation[0] = m[12];
        d.translation[1] = m[13];
        d.translation[2] = m[14];
        // Matrix3 columns x, y, z.
        let xx = m[0], xy = m[1], xz = m[2];
        let yx = m[4], yy = m[5], yz = m[6];
        let zx = m[8], zy = m[9], zz = m[10];
        const sx = Mathf.sqrt(xx * xx + xy * xy + xz * xz);
        const sy = Mathf.sqrt(yx * yx + yy * yy + yz * yz);
        const det = xx * (yy * zz - zy * yz) - yx * (xy * zz - zy * xz) + zx * (xy * yz - yy * xz);
        const sz = signumF32(det) * Mathf.sqrt(zx * zx + zy * zy + zz * zz);
        d.scale[0] = sx;
        d.scale[1] = sy;
        d.scale[2] = sz;
        const ix = <f32>1.0 / sx;
        xx *= ix; xy *= ix; xz *= ix;
        const iy = <f32>1.0 / sy;
        yx *= iy; yy *= iy; yz *= iy;
        const iz = <f32>1.0 / sz;
        zx *= iz; zy *= iz; zz *= iz;
        // Quaternion::from_matrix
        const trace = xx + yy + zz;
        let w: f32, x: f32, y: f32, z: f32;
        if (trace >= 0) {
            const s = Mathf.sqrt(<f32>1.0 + trace);
            w = <f32>0.5 * s;
            const h = <f32>0.5 / s;
            x = (yz - zy) * h;
            y = (zx - xz) * h;
            z = (xy - yx) * h;
        } else if (xx > yy && xx > zz) {
            const s = Mathf.sqrt((xx - yy - zz) + <f32>1.0);
            x = <f32>0.5 * s;
            const h = <f32>0.5 / s;
            y = (yx + xy) * h;
            z = (xz + zx) * h;
            w = (yz - zy) * h;
        } else if (yy > zz) {
            const s = Mathf.sqrt((yy - xx - zz) + <f32>1.0);
            y = <f32>0.5 * s;
            const h = <f32>0.5 / s;
            z = (zy + yz) * h;
            x = (yx + xy) * h;
            w = (zx - xz) * h;
        } else {
            const s = Mathf.sqrt((zz - xx - yy) + <f32>1.0);
            z = <f32>0.5 * s;
            const h = <f32>0.5 / s;
            x = (xz + zx) * h;
            y = (zy + yz) * h;
            w = (xy - yx) * h;
        }
        d.rotation[0] = x;
        d.rotation[1] = y;
        d.rotation[2] = z;
        d.rotation[3] = w;
        return d;
    }
}

// Node::transform: the matrix when there is one, else TRS with defaults.
export function nodeTransform(node: Node): NodeTransform {
    const t = new NodeTransform();
    const m = node.matrix;
    if (m != null) {
        t.isMatrix = true;
        for (let i = 0; i < 16; i++) t.m[i] = m[i];
        return t;
    }
    const tr = node.translation;
    if (tr != null) for (let i = 0; i < 3; i++) t.translation[i] = tr[i];
    const r = node.rotation;
    if (r != null) for (let i = 0; i < 4; i++) t.rotation[i] = r[i];
    const s = node.scale;
    if (s != null) for (let i = 0; i < 3; i++) t.scale[i] = s[i];
    return t;
}
