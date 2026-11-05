// Decompress a parsed glTF document in place.
//
// The result is a document that says nothing about compression: every
// accessor points at a real buffer view, every view at real bytes, and both
// extensions are gone from `extensionsUsed` / `extensionsRequired`. The
// importer proper then reads it as it would read any other file.
//
// Decoded bytes go into one buffer appended after the file's own, so the
// original buffers are never rewritten and the offsets already in the
// document stay valid for whatever was not compressed.

import { Result } from "../../../base/util";
import { JsonMap, JsonValue } from "../../../base/json";
import { ByteVec } from "../draco/core/byte_vec";
import { AccessorType, Buffer, BufferView, ComponentType, Root, CHECKED_INVALID } from "../gltf/doc";
import { IoError } from "../core/error";
import {
    CompressReport, DRACO_EXT, MESHOPT_EXT, QUANTIZATION_EXT, accessorComponent, accessorType,
    padTo4, typeComponents, undeclareExtension, writeScalars,
} from "../core/compress";
import { Filter, Mode, decodeViewU64, filterParse, modeParse } from "../../../io/compress/meshopt/mod";
import { channel as dracoChannel, decode as dracoDecode } from "./draco";
import { dequantize } from "./quantize";

// Decompress everything in `root`, appending decoded bytes to `buffers` as
// one new buffer. Returns what it did, for the import report. `path` is the
// file's path as the error messages show it.
export function decode(root: Root, buffers: Array<Uint8Array>, path: string): Result<CompressReport> {
    const report = new CompressReport();
    const out = new ByteVec();
    const outBuffer = <u32>buffers.length;

    // meshopt first: a Draco buffer view is allowed to be meshopt-compressed
    // itself, and this order means the Draco pass below always reads plain
    // bytes.
    const m = meshoptViews(root, buffers, out, outBuffer, report, path);
    if (!m.ok) return m.forward<CompressReport>();
    // Then quantization, which has to widen the accessor declarations before
    // Draco writes into them (see `quantize`). `buffers` does not yet include
    // `out`, so the pass is handed both.
    report.quantizedAccessors = dequantize(root, buffers, out, outBuffer, report.warnings);
    const d = dracoPrimitives(root, buffers, out, outBuffer, report, path);
    if (!d.ok) return d.forward<CompressReport>();

    if (out.length == 0) {
        return Result.okv<CompressReport>(report);
    }
    const b = new Buffer();
    b.byteLength = <u64>out.length;
    b.name = "hedra-decompressed";
    // No uri: the bytes are handed to the importer alongside the document,
    // exactly like a GLB's binary chunk.
    b.uri = null;
    b.extensions = null;
    b.extras = null;
    root.buffers.push(b);
    buffers.push(out.toBytes());
    if (report.dracoPrimitives > 0) {
        undeclareExtension(root, DRACO_EXT);
    }
    if (report.meshoptViews > 0) {
        undeclareExtension(root, MESHOPT_EXT);
    }
    // Struck off whenever it was declared, not only when something was
    // converted: the pass visits every mesh attribute, so once it has run
    // nothing in the document is quantized, and a file that declares the
    // extension without using it is still readable afterwards.
    undeclareExtension(root, QUANTIZATION_EXT);
    return Result.okv<CompressReport>(report);
}

// The bytes a buffer view stands for, or null when it points outside the
// buffers the file actually carries.
function viewBytes(view: BufferView, buffers: Array<Uint8Array>): Uint8Array? {
    if (view.buffer < 0 || view.buffer >= buffers.length) return null;
    const buffer = buffers[view.buffer];
    const start: u64 = view.byteOffset >= 0 ? <u64>view.byteOffset : 0;
    const end = start + view.byteLength;
    if (end < start) return null; // checked_add
    return getRange(buffer, start, end);
}

// `slice.get(start..end)` (a view).
function getRange(b: Uint8Array, start: u64, end: u64): Uint8Array? {
    if (start > end || end > <u64>b.length) return null;
    return b.subarray(<i32>start, <i32>end);
}

function parseError(path: string, message: string): IoError {
    return IoError.parse(path, message);
}

// ---------------------------------------------------------------- meshopt

// Replace every `EXT_meshopt_compression` buffer view with its decoded bytes.
function meshoptViews(
    root: Root,
    buffers: Array<Uint8Array>,
    out: ByteVec,
    outBuffer: u32,
    report: CompressReport,
    path: string,
): Result<bool> {
    for (let index = 0; index < root.bufferViews.length; index++) {
        const object = meshoptObject(root.bufferViews[index]);
        if (object == null) continue;
        const parsed = parseMeshopt(object);
        if (!parsed.ok) {
            return parseError(
                path, "buffer view " + index.toString() + ": " + MESHOPT_EXT + " " + parsed.err,
            ).fail<bool>();
        }
        const ext = parsed.value;
        // The extension names its own slice of its own buffer; the view's
        // `buffer` / `byteOffset` point at the *fallback*, which holds nothing
        // useful.
        let compressed: Uint8Array? = null;
        if (ext.buffer < <u64>buffers.length) {
            const end = ext.byteOffset + ext.byteLength;
            if (end >= ext.byteOffset) {
                compressed = getRange(buffers[<i32>ext.buffer], ext.byteOffset, end);
            }
        }
        if (compressed == null) {
            return parseError(
                path,
                "buffer view " + index.toString() + ": " + MESHOPT_EXT + " points outside buffer "
                + ext.buffer.toString(),
            ).fail<bool>();
        }
        const decoded = decodeViewU64(compressed, ext.count, ext.byteStride, ext.mode, ext.filter);
        if (!decoded.ok) {
            return parseError(path, "buffer view " + index.toString() + ": " + decoded.err).fail<bool>();
        }
        const bytes = decoded.value;

        padTo4(out);
        const offset = out.length;
        out.extend(bytes);

        const view = root.bufferViews[index];
        view.buffer = <i32>outBuffer;
        view.byteOffset = <i64>offset;
        view.byteLength = <u64>bytes.length;
        // An index view must not declare a stride, and glTF caps a vertex
        // stride at 252 where meshopt allows 256. Outside that range the data
        // is still tightly packed, which is what a lone accessor over the
        // view reads anyway.
        view.byteStride = ext.mode == Mode.Attributes
            && ext.byteStride >= 4 && ext.byteStride <= 252
            && ext.byteStride % 4 == 0
            ? <i64>ext.byteStride
            : -1;
        const e = view.extensions;
        if (e != null) {
            e.others.remove(MESHOPT_EXT);
        }
        report.meshoptViews += 1;
    }
    return Result.okv<bool>(true);
}

// The fields of one `EXT_meshopt_compression` object (unsigned, 64-bit).
export class MeshoptExt {
    buffer: u64 = 0;
    byteOffset: u64 = 0;
    byteLength: u64 = 0;
    byteStride: u64 = 0;
    count: u64 = 0;
    mode: Mode = Mode.Attributes;
    filter: Filter = Filter.None;
}

// The view's `EXT_meshopt_compression` object, or null when the view is not
// compressed (the parse is separate).
function meshoptObject(view: BufferView): JsonValue? {
    const e = view.extensions;
    if (e == null) return null;
    return e.others.get(MESHOPT_EXT);
}

// `object[key]` as an unsigned integer, or null.
class U64Field {
    some: bool = false;
    v: u64 = 0;
}

function u64Field(object: JsonValue, key: string): U64Field {
    const f = new U64Field();
    const v = object.get(key);
    if (v != null && v.isU64()) {
        f.some = true;
        f.v = v.asU64();
    }
    return f;
}

function requireU64(object: JsonValue, key: string, into: U64Field): string? {
    const f = u64Field(object, key);
    if (!f.some) return "has no numeric '" + key + "'";
    into.v = f.v;
    return null;
}

export function parseMeshopt(object: JsonValue): Result<MeshoptExt> {
    const modeValue = object.get("mode");
    const modeName = modeValue != null ? modeValue.asStr() : null;
    if (modeName == null) {
        return Result.fail<MeshoptExt>("has no 'mode'");
    }
    const mode = modeParse(modeName);
    if (mode < 0) {
        return Result.fail<MeshoptExt>("names an unknown mode '" + modeName + "'");
    }
    let filter = Filter.None;
    const filterValue = object.get("filter");
    const filterName = filterValue != null ? filterValue.asStr() : null;
    if (filterName != null) {
        const f = filterParse(filterName);
        if (f < 0) {
            return Result.fail<MeshoptExt>("names an unknown filter '" + filterName + "'");
        }
        filter = <Filter>f;
    }
    const ext = new MeshoptExt();
    ext.mode = <Mode>mode;
    ext.filter = filter;
    const tmp = new U64Field();
    let e = requireU64(object, "buffer", tmp);
    if (e != null) return Result.fail<MeshoptExt>(e);
    ext.buffer = tmp.v;
    const off = u64Field(object, "byteOffset");
    ext.byteOffset = off.some ? off.v : 0;
    e = requireU64(object, "byteLength", tmp);
    if (e != null) return Result.fail<MeshoptExt>(e);
    ext.byteLength = tmp.v;
    e = requireU64(object, "byteStride", tmp);
    if (e != null) return Result.fail<MeshoptExt>(e);
    ext.byteStride = tmp.v;
    e = requireU64(object, "count", tmp);
    if (e != null) return Result.fail<MeshoptExt>(e);
    ext.count = tmp.v;
    return Result.okv<MeshoptExt>(ext);
}

// ------------------------------------------------------------------ Draco

// Decode every `KHR_draco_mesh_compression` primitive, pointing its accessors
// at the decoded attributes.
//
// Each primitive decodes to vertices of its own, so an accessor that two
// Draco primitives name (a file may share one declaration between them) is
// repointed for the first and copied for the next: pointing it at the second
// one's vertices would hand the first primitive's indices another vertex
// list.
function dracoPrimitives(
    root: Root,
    buffers: Array<Uint8Array>,
    out: ByteVec,
    outBuffer: u32,
    report: CompressReport,
    path: string,
): Result<bool> {
    // Accessors already pointed at a decoded primitive's data.
    const decodedInto = new Set<i32>();
    for (let mesh = 0; mesh < root.meshes.length; mesh++) {
        for (let prim = 0; prim < root.meshes[mesh].primitives.length; prim++) {
            const primitive = root.meshes[mesh].primitives[prim];
            const exts = primitive.extensions;
            if (exts == null) continue;
            const object = exts.others.get(DRACO_EXT);
            if (object == null) continue;
            const where_ = "mesh " + mesh.toString() + " primitive " + prim.toString();
            const parsed = parseDraco(object);
            if (!parsed.ok) {
                return parseError(path, where_ + ": " + DRACO_EXT + " " + parsed.err).fail<bool>();
            }
            const viewIndex = parsed.value.view;
            const attributeIds = parsed.value.ids;
            let compressed: Uint8Array? = null;
            if (viewIndex < <u64>root.bufferViews.length) {
                compressed = viewBytes(root.bufferViews[<i32>viewIndex], buffers);
            }
            if (compressed == null) {
                return parseError(
                    path,
                    where_ + ": " + DRACO_EXT + " names buffer view " + viewIndex.toString()
                    + ", which is not readable",
                ).fail<bool>();
            }

            // The buffers are never written here, so a view of the compressed
            // bytes will do; no copy is needed.
            const dr = dracoDecode(compressed);
            if (!dr.ok) {
                return parseError(path, where_ + ": " + dr.err).fail<bool>();
            }
            const meshData = dr.value.mesh;
            const decoded = dr.value.decoded;

            // Attributes: each named accessor is repointed at the values
            // Draco gave back for the unique id the extension paired it with.
            // The accessor keeps its own type and component type, so the
            // file's own idea of how the data is stored is preserved.
            const attributes = primitive.attributes.clone();
            for (let a = 0; a < attributes.keys.length; a++) {
                const name = attributes.keys[a].toString();
                const accessorIndex = attributes.values[a];
                if (!attributeIds.has(name)) {
                    report.warnings.push(where_ + ": " + name + " is not in the Draco stream and was dropped");
                    continue;
                }
                const uniqueId = attributeIds.get(name);
                if (accessorIndex < 0 || accessorIndex >= root.accessors.length) continue;
                const own = ownAccessor(root, decodedInto, accessorIndex);
                primitive.attributes.values[a] = own;
                const accessor = root.accessors[own];
                const t = accessorType(accessor);
                if (t == CHECKED_INVALID) continue;
                const component = accessorComponent(accessor);
                if (component == CHECKED_INVALID) continue;
                const components = typeComponents(<AccessorType>t);
                const ch = dracoChannel(meshData, uniqueId, components);
                if (ch == null) {
                    report.warnings.push(
                        where_ + ": the Draco stream has no attribute " + uniqueId.toString() + " for " + name,
                    );
                    continue;
                }
                const view = pushValues(root, out, outBuffer, ch.values, <ComponentType>component);
                accessor.bufferView = view;
                accessor.byteOffset = 0;
                // Draco decides the vertex count, not the JSON that described
                // the compressed form.
                accessor.count = <u64>decoded.vertices;
                accessor.sparse = null;
            }

            // Indices.
            const shared = root.meshes[mesh].primitives[prim].indices;
            if (shared >= 0 && shared < root.accessors.length) {
                const indices = ownAccessor(root, decodedInto, shared);
                root.meshes[mesh].primitives[prim].indices = indices;
                const accessor = root.accessors[indices];
                const component = accessorComponent(accessor);
                if (component != CHECKED_INVALID) {
                    const n = decoded.indices.length;
                    const values = new Float32Array(n);
                    for (let i = 0; i < n; i++) values[i] = <f32>decoded.indices[i];
                    const view = pushValues(root, out, outBuffer, values, <ComponentType>component);
                    accessor.bufferView = view;
                    accessor.byteOffset = 0;
                    accessor.count = <u64>n;
                    accessor.sparse = null;
                }
            }

            const e = root.meshes[mesh].primitives[prim].extensions;
            if (e != null) {
                e.others.remove(DRACO_EXT);
            }
            report.dracoPrimitives += 1;
        }
    }
    return Result.okv<bool>(true);
}

// The accessor a decoded primitive's data goes into: `index` the first time,
// a copy of its declaration after that (see `dracoPrimitives`).
function ownAccessor(root: Root, decodedInto: Set<i32>, index: i32): i32 {
    if (!decodedInto.has(index)) {
        decodedInto.add(index);
        return index;
    }
    root.accessors.push(root.accessors[index].clone());
    const own = root.accessors.length - 1;
    decodedInto.add(own);
    return own;
}

// Append `values` as `component` and return the index of a new buffer view
// over exactly those bytes.
function pushValues(
    root: Root,
    out: ByteVec,
    outBuffer: u32,
    values: Float32Array,
    component: ComponentType,
): i32 {
    padTo4(out);
    const offset = out.length;
    writeScalars(out, values, component);
    const length = out.length - offset;
    const v = new BufferView();
    v.buffer = <i32>outBuffer;
    v.byteLength = <u64>length;
    v.byteOffset = <i64>offset;
    v.byteStride = -1;
    v.name = null;
    v.target = 0; // None
    v.extensions = null;
    v.extras = null;
    root.bufferViews.push(v);
    return root.bufferViews.length - 1;
}

// The buffer view index and the semantic-to-unique-id map of one
// `KHR_draco_mesh_compression` object (the map is only looked up by key).
export class DracoExt {
    view: u64 = 0;
    ids: Map<string, u32> = new Map<string, u32>();
}

export function parseDraco(object: JsonValue): Result<DracoExt> {
    const v = object.get("bufferView");
    if (v == null || !v.isU64()) {
        return Result.fail<DracoExt>("has no numeric 'bufferView'");
    }
    const view = v.asU64();
    const a = object.get("attributes");
    const attributes: JsonMap? = a != null ? a.asObject() : null;
    if (attributes == null) {
        return Result.fail<DracoExt>("has no 'attributes' object");
    }
    const ext = new DracoExt();
    ext.view = view;
    for (let i = 0; i < attributes.length; i++) {
        const value = attributes.valueAt(i);
        if (!value.isU64()) continue;
        ext.ids.set(attributes.keyAt(i), <u32>value.asU64());
    }
    return Result.okv<DracoExt>(ext);
}
