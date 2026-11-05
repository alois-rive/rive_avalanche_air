// What the compression passes share. The three
// ways a glTF file stores mesh data more compactly than the base
// specification can read (`KHR_draco_mesh_compression`,
// `EXT_meshopt_compression`, `KHR_mesh_quantization`), the export option
// types, the pass report, and the accessor layout helpers. The passes
// themselves (decode / encode / quantize / draco) live in shared/src/io/compress/.
//
// Byte outputs are `ByteVec` (engine/src/source/io/draco/core/byte_vec.as); float results
// are `Float32Array`.

import { f32ToI32, f32ToU32, roundF32, clampF32 } from "../../../base/util";
import { ByteVec } from "../draco/core/byte_vec";
import { Accessor, AccessorType, ComponentType, Root, CHECKED_INVALID } from "../gltf/doc";

export const DRACO_EXT = "KHR_draco_mesh_compression";
export const MESHOPT_EXT = "EXT_meshopt_compression";
export const QUANTIZATION_EXT = "KHR_mesh_quantization";

// What `export --compression` was asked for.
export enum Compression {
    // Plain glTF. The default, because both of the others go into
    // `extensionsRequired`: a viewer that does not implement the extension
    // cannot fall back to reading the mesh, it simply cannot open the file.
    None = 0,
    // `KHR_draco_mesh_compression`. Quantizes and re-encodes the geometry, so
    // it is lossy and by far the smaller of the two.
    Draco = 1,
    // `EXT_meshopt_compression`. Keeps every byte it is given and packs the
    // stream; lossless, faster to decode, less compact than Draco.
    Meshopt = 2,
}

// Compression::parse: the Compression, or -1 for None.
export function compressionParse(s: string): i32 {
    if (s == "none" || s == "off") return Compression.None;
    if (s == "draco") return Compression.Draco;
    if (s == "meshopt") return Compression.Meshopt;
    return -1;
}

// Compression::name.
export function compressionName(c: Compression): string {
    switch (c) {
        case Compression.None: return "none";
        case Compression.Draco: return "draco";
        default: return "meshopt";
    }
}

// Derived Debug of Compression.
export function compressionDebug(c: Compression): string {
    switch (c) {
        case Compression.None: return "None";
        case Compression.Draco: return "Draco";
        default: return "Meshopt";
    }
}

// Draco quantization, in bits per component, and the encoder's speed / size
// trade-off. The defaults (`new DracoOpts()`) are Blender's exporter's.
export class DracoOpts {
    // 0 leaves an attribute unquantized.
    positionBits: u32 = 14;
    normalBits: u32 = 10;
    uvBits: u32 = 12;
    // 0..=10; higher is smaller and slower at both ends.
    level: u32 = 7;

    clone(): DracoOpts {
        const o = new DracoOpts();
        o.positionBits = this.positionBits;
        o.normalBits = this.normalBits;
        o.uvBits = this.uvBits;
        o.level = this.level;
        return o;
    }
}

// How many compressed things a pass dealt with, for the command's report.
export class CompressReport {
    // Primitives compressed or decompressed with Draco.
    dracoPrimitives: i32 = 0;
    // Buffer views compressed or decompressed with meshopt.
    meshoptViews: i32 = 0;
    // Accessors widened back to float32 from `KHR_mesh_quantization`.
    // Import only: nothing here quantizes on the way out.
    quantizedAccessors: i32 = 0;
    warnings: Array<string> = [];

    // Whether the pass changed anything at all.
    touched(): bool {
        return this.dracoPrimitives > 0 || this.meshoptViews > 0 || this.quantizedAccessors > 0;
    }

    clone(): CompressReport {
        const r = new CompressReport();
        r.dracoPrimitives = this.dracoPrimitives;
        r.meshoptViews = this.meshoptViews;
        r.quantizedAccessors = this.quantizedAccessors;
        r.warnings = this.warnings.slice(0);
        return r;
    }
}

// ------------------------------------------------------- accessor layout

// How many scalars make one element of an accessor type.
export function typeComponents(t: AccessorType): i32 {
    switch (t) {
        case AccessorType.Scalar: return 1;
        case AccessorType.Vec2: return 2;
        case AccessorType.Vec3: return 3;
        case AccessorType.Vec4: return 4;
        case AccessorType.Mat2: return 4;
        case AccessorType.Mat3: return 9;
        default: return 16; // Mat4
    }
}

// Byte width of one scalar.
export function componentWidth(c: ComponentType): i32 {
    switch (c) {
        case ComponentType.I8:
        case ComponentType.U8: return 1;
        case ComponentType.I16:
        case ComponentType.U16: return 2;
        default: return 4; // U32 | F32
    }
}

// One element of an accessor, in bytes: the stride of a tightly packed
// buffer view over it. -1 (None) when either enum is Invalid.
export function elementSize(a: Accessor): i32 {
    const t = accessorType(a);
    if (t == CHECKED_INVALID) return -1;
    const c = accessorComponent(a);
    if (c == CHECKED_INVALID) return -1;
    return typeComponents(<AccessorType>t) * componentWidth(<ComponentType>c);
}

// The accessor's element type, or CHECKED_INVALID (None) when the file named
// one glTF does not define.
export function accessorType(a: Accessor): i32 {
    return a.type_;
}

// The accessor's component type, likewise.
export function accessorComponent(a: Accessor): i32 {
    return a.componentType;
}

// NaN is 0, otherwise round half away from zero and clamp.
function saturate(v: f32, lo: f32, hi: f32): f32 {
    if (isNaN(v)) return 0;
    return clampF32(roundF32(v), lo, hi);
}

function pushU16(out: ByteVec, v: u32): void {
    out.push(<u8>v);
    out.push(<u8>(v >> 8));
}

function pushU32(out: ByteVec, v: u32): void {
    out.push(<u8>v);
    out.push(<u8>(v >> 8));
    out.push(<u8>(v >> 16));
    out.push(<u8>(v >> 24));
}

// Write `values` (one f32 per scalar, in element order) as `component`,
// little-endian. Integer component types round to nearest and saturate,
// which is what a joint index or a normalized weight needs.
export function writeScalars(out: ByteVec, values: Float32Array, component: ComponentType): void {
    const n = values.length;
    out.reserve(n * componentWidth(component));
    for (let i = 0; i < n; i++) {
        const v = values[i];
        switch (component) {
            case ComponentType.F32:
                pushU32(out, reinterpret<u32>(v));
                break;
            case ComponentType.U8:
                out.push(<u8>f32ToU32(saturate(v, 0.0, <f32>255)));
                break;
            case ComponentType.I8:
                out.push(<u8>f32ToI32(saturate(v, <f32>-128, <f32>127)));
                break;
            case ComponentType.U16:
                pushU16(out, f32ToU32(saturate(v, 0.0, <f32>65535)));
                break;
            case ComponentType.I16:
                pushU16(out, <u32>f32ToI32(saturate(v, <f32>-32768, <f32>32767)));
                break;
            default: // U32
                // u32::MAX as f32 is 4294967296.0; the u32 cast saturates it.
                pushU32(out, f32ToU32(saturate(v, 0.0, <f32>4294967295.0)));
                break;
        }
    }
}

// Read `count * components` scalars out of a tightly packed slice as f32, the
// inverse of `writeScalars`. Scalars past the end of `bytes` stay 0.
export function readScalars(
    bytes: Uint8Array,
    count: i32,
    components: i32,
    component: ComponentType,
    stride: i32,
): Float32Array {
    const width = componentWidth(component);
    const out = new Float32Array(count * components);
    const len = <i64>bytes.length;
    for (let element = 0; element < count; element++) {
        for (let c = 0; c < components; c++) {
            const at = <i64>element * <i64>stride + <i64>(c * width);
            if (at + <i64>width > len) continue;
            const p = <i32>at;
            let v: f32;
            switch (component) {
                case ComponentType.F32:
                    v = reinterpret<f32>(<u32>bytes[p] | (<u32>bytes[p + 1] << 8)
                        | (<u32>bytes[p + 2] << 16) | (<u32>bytes[p + 3] << 24));
                    break;
                case ComponentType.U8:
                    v = <f32>bytes[p];
                    break;
                case ComponentType.I8:
                    v = <f32><i8>bytes[p];
                    break;
                case ComponentType.U16:
                    v = <f32>(<u16>(<u32>bytes[p] | (<u32>bytes[p + 1] << 8)));
                    break;
                case ComponentType.I16:
                    v = <f32>(<i16>(<u32>bytes[p] | (<u32>bytes[p + 1] << 8)));
                    break;
                default: // U32
                    v = <f32>(<u32>bytes[p] | (<u32>bytes[p + 1] << 8)
                        | (<u32>bytes[p + 2] << 16) | (<u32>bytes[p + 3] << 24));
                    break;
            }
            out[element * components + c] = v;
        }
    }
    return out;
}

// Pad a buffer to the 4-byte alignment glTF wants of every view offset.
export function padTo4(buf: ByteVec): void {
    while ((buf.length & 3) != 0) buf.push(0);
}

// Drop `name` from `extensionsUsed` and `extensionsRequired`. Called once a
// decode pass has made the extension untrue of the document.
export function undeclareExtension(root: Root, name: string): void {
    retainNot(root.extensionsUsed, name);
    retainNot(root.extensionsRequired, name);
}

// `v.retain(|e| e != name)`, in place.
function retainNot(v: Array<string>, name: string): void {
    let k = 0;
    for (let i = 0; i < v.length; i++) {
        const e = v[i];
        if (e != name) {
            v[k] = e;
            k++;
        }
    }
    v.length = k;
}

// Add `name` to both `extensionsUsed` and `extensionsRequired`. Compression
// is the one thing the exporter writes that a viewer cannot skip and still
// read the mesh, which is exactly what `extensionsRequired` means.
export function requireExtension(root: Root, name: string): void {
    if (!containsStr(root.extensionsUsed, name)) root.extensionsUsed.push(name);
    if (!containsStr(root.extensionsRequired, name)) root.extensionsRequired.push(name);
}

function containsStr(v: Array<string>, name: string): bool {
    for (let i = 0; i < v.length; i++) {
        if (v[i] == name) return true;
    }
    return false;
}
