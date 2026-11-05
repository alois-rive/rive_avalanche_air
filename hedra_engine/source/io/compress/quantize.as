// `KHR_mesh_quantization`, mesh attributes stored in narrower types than the
// base specification allows.
//
// The extension does not encode anything -- it simply lifts the rule that
// `POSITION`, `NORMAL` and `TANGENT` are float32, and that texture
// coordinates, colours and weights are float32 or *unsigned* normalized bytes
// and shorts. A quantized file stores those as signed or unnormalized
// integers instead, and leans on the node's scale and translation -- already
// in the file, and already applied by the importer -- to put the numbers back
// where they belong.
//
// So this pass is a widening, not a decode: each quantized accessor is
// rewritten as float32, normalized integers divided down to their `[-1, 1]` or
// `[0, 1]` range on the way. Nothing else in the document changes, and
// afterwards the file is plain glTF that the importer reads without knowing
// the extension exists.
//
// It earns its place next to Draco and meshopt because the three answer the
// same question -- the file stores mesh data in a form the base specification
// cannot read -- and because the order they run in matters. Quantization sits
// between them: the data may arrive inside a meshopt-compressed view, and a
// Draco stream decodes to whatever component type its accessor declares, so
// both need the declaration already widened by the time they run.

import { cmpStr, maxF32, panic, stableSort } from "../../../base/util";
import { JsonValue } from "../../../base/json";
import { ByteVec } from "../draco/core/byte_vec";
import { AccessorType, BufferView, ComponentType, Root, CHECKED_INVALID } from "../gltf/doc";
import { accessorComponent, accessorType, componentWidth, padTo4, readScalars, typeComponents } from "../core/compress";

// One `(accessor index, semantic)` pair the pass looks at.
class Wanted {
    index: i32;
    semantic: string;

    constructor(index: i32, semantic: string) {
        this.index = index;
        this.semantic = semantic;
    }
}

// Orders by index, then by semantic.
function cmpWanted(a: Wanted, b: Wanted): i32 {
    if (a.index != b.index) return a.index < b.index ? -1 : 1;
    return cmpStr(a.semantic, b.semantic);
}

// A 64-bit element count as a typed-array length; a count no typed array can
// hold panics with "capacity overflow".
export function usizeLen(n: u64): i32 {
    if (n > <u64>i32.MAX_VALUE) panic("capacity overflow");
    return <i32>n;
}

// An unsigned 64-bit stride or offset as the i32 `readScalars` takes: anything past
// i32::MAX is past every byte slice this runtime holds, so it reads the same.
export function clampStride(s: u64): i32 {
    return s > <u64>i32.MAX_VALUE ? i32.MAX_VALUE : <i32>s;
}

// Convert every quantized mesh attribute in the document to float32,
// appending the widened data to `out`. Returns how many accessors were
// rewritten, and pushes a warning for any that could not be.
export function dequantize(
    root: Root,
    buffers: Array<Uint8Array>,
    out: ByteVec,
    outBuffer: u32,
    warnings: Array<string>,
): i32 {
    // Attribute accessors of every primitive, and of every morph target on
    // one: a target's POSITION deltas are quantized by the same tools that
    // quantize the base mesh.
    const wanted: Array<Wanted> = [];
    for (let m = 0; m < root.meshes.length; m++) {
        const mesh = root.meshes[m];
        for (let p = 0; p < mesh.primitives.length; p++) {
            const primitive = mesh.primitives[p];
            const attrs = primitive.attributes;
            for (let i = 0; i < attrs.keys.length; i++) {
                wanted.push(new Wanted(attrs.values[i], attrs.keys[i].toString()));
            }
            const targets = primitive.targets;
            if (targets != null) {
                for (let t = 0; t < targets.length; t++) {
                    const target = targets[t];
                    if (target.positions >= 0) wanted.push(new Wanted(target.positions, "POSITION"));
                    if (target.normals >= 0) wanted.push(new Wanted(target.normals, "NORMAL"));
                    if (target.tangents >= 0) wanted.push(new Wanted(target.tangents, "TANGENT"));
                }
            }
        }
    }
    // An accessor shared by two primitives is converted once.
    stableSort<Wanted>(wanted, cmpWanted);
    {
        let k = 0;
        for (let i = 0; i < wanted.length; i++) {
            if (k > 0 && cmpWanted(wanted[k - 1], wanted[i]) == 0) continue;
            wanted[k] = wanted[i];
            k++;
        }
        wanted.length = k;
    }

    let converted = 0;
    for (let w = 0; w < wanted.length; w++) {
        const index = wanted[w].index;
        const semantic = wanted[w].semantic;
        if (index < 0 || index >= root.accessors.length) continue;
        const accessor = root.accessors[index];
        const componentChecked = accessorComponent(accessor);
        if (componentChecked == CHECKED_INVALID) continue;
        const component = <ComponentType>componentChecked;
        if (!needsWidening(semantic, component, accessor.normalized)) continue;
        if (accessor.sparse != null) {
            warnings.push(
                "accessor " + index.toString() + " (" + semantic + ") is both quantized and sparse, "
                + "which is not supported; its data was left as it is",
            );
            continue;
        }
        const divisor: f32 = accessor.normalized ? normalizedDivisor(component) : 1.0;

        // An accessor with no buffer view is fed by a Draco stream that has
        // not been decoded yet. Only its declaration is widened here; the
        // Draco pass then writes float32 into it, which is the point of
        // running before that pass rather than after.
        const viewIndex = accessor.bufferView;
        if (viewIndex >= 0) {
            if (viewIndex >= root.bufferViews.length) continue;
            const view = root.bufferViews[viewIndex];
            const t = accessorType(accessor);
            if (t == CHECKED_INVALID) continue;
            const components = typeComponents(<AccessorType>t);
            const width = componentWidth(component);
            const stride: u64 = view.byteStride >= 0 ? <u64>view.byteStride : <u64>(components * width);
            const viewStart: u64 = view.byteOffset >= 0 ? <u64>view.byteOffset : 0;
            const start: u64 = viewStart + (accessor.byteOffset >= 0 ? <u64>accessor.byteOffset : 0);
            const end: u64 = viewStart + view.byteLength;
            // The view may live in the file's own buffers, or in `out` when
            // the meshopt pass has already rewritten it -- `out` is not in
            // `buffers` until the caller pushes it at the end. Copied out
            // rather than borrowed because the widened data is appended to
            // `out` immediately afterwards.
            let source: Uint8Array? = null;
            if (<u32>view.buffer == outBuffer) {
                source = sliceCopy(out.data(), start, end);
            } else if (view.buffer >= 0 && view.buffer < buffers.length) {
                source = sliceCopy(buffers[view.buffer], start, end);
            }
            if (source == null) {
                warnings.push(
                    "accessor " + index.toString() + " (" + semantic + ") points outside its buffer; "
                    + "its data was left as it is",
                );
                continue;
            }
            const count = usizeLen(accessor.count);
            const raw = readScalars(source, count, components, component, clampStride(stride));

            padTo4(out);
            const offset = out.length;
            out.reserve(raw.length * 4);
            for (let i = 0; i < raw.length; i++) {
                const bits = reinterpret<u32>(widen(raw[i], divisor));
                out.push(<u8>bits);
                out.push(<u8>(bits >> 8));
                out.push(<u8>(bits >> 16));
                out.push(<u8>(bits >> 24));
            }
            const length = out.length - offset;
            const nv = new BufferView();
            nv.buffer = <i32>outBuffer;
            nv.byteLength = <u64>length;
            nv.byteOffset = <i64>offset;
            // Tightly packed now, whatever the source interleaving was.
            nv.byteStride = -1;
            nv.name = null;
            nv.target = root.bufferViews[viewIndex].target;
            nv.extensions = null;
            nv.extras = null;
            root.bufferViews.push(nv);
            const newView = root.bufferViews.length - 1;
            accessor.bufferView = newView;
            accessor.byteOffset = 0;
        }

        accessor.componentType = ComponentType.F32;
        accessor.normalized = false;
        // `min` and `max` are stored in the accessor's own units, so they
        // move with the data. A POSITION accessor is required to carry them,
        // and a viewer that culls on them would otherwise cull against the
        // quantized range.
        widenBound(accessor.min, divisor);
        widenBound(accessor.max, divisor);
        converted += 1;
    }
    return converted;
}

// When `bound` is an array, replaces every number `n` in it with
// `widen(<f32>n, divisor)`.
function widenBound(bound: JsonValue?, divisor: f32): void {
    if (bound == null) return;
    const values = bound.asArray();
    if (values == null) return;
    for (let i = 0; i < values.length; i++) {
        const v = values[i];
        if (!v.isNumber()) continue;
        const n = v.asF64();
        values[i] = JsonValue.fromF32(widen(<f32>n, divisor));
    }
}

// `slice.get(start..end.min(slice.len())).map(to_vec)`.
function sliceCopy(b: Uint8Array, start: u64, end: u64): Uint8Array? {
    const len = <u64>b.length;
    const e = end < len ? end : len;
    if (start > e) return null;
    return b.slice(<i32>start, <i32>e);
}

// Whether an accessor holding `semantic` has to be widened for the base
// specification to be able to read it.
//
// Deliberately narrow: an unsigned normalized byte or short texture
// coordinate is ordinary glTF that the importer already reads, so a file that
// is not quantized at all passes through this module untouched.
export function needsWidening(semantic: string, component: ComponentType, normalized: bool): bool {
    if (component == ComponentType.F32) return false;
    // Joint indices are integers by definition, and the base specification
    // already stores them as bytes or shorts. Widening them would be wrong,
    // not merely unnecessary.
    if (semantic.startsWith("JOINTS_")) return false;
    // These three are float32 and nothing else without the extension.
    if (semantic == "POSITION" || semantic == "NORMAL" || semantic == "TANGENT") return true;
    // The rest already allow unsigned normalized bytes and shorts; only the
    // forms the extension adds -- signed, or unnormalized -- need widening.
    return !(normalized && (component == ComponentType.U8 || component == ComponentType.U16));
}

// What a normalized integer of this type divides by to reach its `[0, 1]` or
// `[-1, 1]` range, per the glTF specification's conversion table.
export function normalizedDivisor(component: ComponentType): f32 {
    switch (component) {
        case ComponentType.I8: return 127.0;
        case ComponentType.U8: return 255.0;
        case ComponentType.I16: return 32767.0;
        case ComponentType.U16: return 65535.0;
        case ComponentType.U32: return <f32>4294967295.0;
        default: return 1.0; // F32
    }
}

// One value, widened. The clamp is the specification's: a signed normalized
// type has one more negative code than positive, and the spare one saturates
// rather than reaching past -1.
export function widen(raw: f32, divisor: f32): f32 {
    if (divisor == 1.0) return raw;
    return maxF32(raw / divisor, -1.0);
}
