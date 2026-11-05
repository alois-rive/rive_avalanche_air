// Milestone 26, package WP2: mesh compression for a bundle (the import's
// meshes/force_disable_compression false, Godot's default): a mesh's
// vertices (render/gpu/layouts.as SurfaceVertex, 56 bytes each) and its
// second UV set stored quantised and then through the meshoptimizer
// vertex codec (engine/src/io/compress/meshopt), its indices through the
// meshoptimizer index codec, and decoded back into the renderer's layout
// at load. The GPU layout is unchanged: only the bundle is smaller.
//
// Quantisation (docs/formats/IMPORT.md, "Mesh compression"): positions 16
// bits an axis over the mesh's bounds (error at most 1/131070 of the
// extent), normals and tangents octahedral in 2 x 16 bits (tangent's w
// kept as its sign), UVs as f32 unchanged (an atlas's texel needs them),
// flags and weight unchanged. Deterministic.
//
// The quantised vertex, 32 bytes (the codec takes strides of 4):
//   0  u16 x, u16 y, u16 z      position over [lo, hi] (0 to 65535)
//   6  u16 tangent sign         0: w = +1, 1: w = -1, 2: w = 0
//   8  i16 nx, i16 ny           normal, octahedral (snorm16)
//   12 i16 tx, i16 ty           tangent's xyz, octahedral
//   16 f32 u, f32 v             UV set 0
//   24 u32 flags
//   28 f32 weight
// An octahedral pair of (-32768, -32768) is the zero vector (a vertex
// with no tangent); any other decodes to a unit vector.
//
// The bytes: u32 vertex count (checked against the count the reader
// expects: the codec itself would decode a stream of n vertices as n + 1),
// u32 length, that many bytes of the codec's stream of the quantised
// vertices; then, with a second UV set, u32 length and the codec's stream
// of count x (f32 u, f32 v).
//
// Indices go through the meshoptimizer index *sequence* codec (glTF's
// INDICES mode), not its triangle codec: the triangle codec may rotate a
// triangle's corners (winding kept), and a bundle's indices must come back
// exactly as the files' (the frame a bundle plans is the frame the files
// plan, bundle/frame_test). It costs bytes: on the courtyard's meshes the
// indices take 11,909 bytes against the triangle codec's 6,036 (47,208
// raw); on a sphere of 5,120 triangles and its four levels, 38,642
// against 34,669 (119,040 raw).
//
// Milestone 67b (docs/engine/RESOURCES.md, "Loading"): the codec's output
// (the quantised vertices, the second UV set, the indices as u32) is read
// out of scratch buffers (../base/scratch.as, meshopt decodeViewPooled)
// into the mesh's own arrays and given back, so that a load decodes its
// meshes with no temporary of its own; decodeIndicesPooled hands the
// indices over still in their buffer, for a reader that cuts them into
// several arrays (a mesh's levels of detail: ../scene/bundle/decode.as).

import { Result } from "../base/util";
import { Vec2, Vec3, Vec4 } from "../base/vecmath";
import { scratch } from "../base/scratch";
import { SurfaceVertex } from "../render/gpu/layouts";
import { Filter, Mode, decodeViewPooled } from "../io/compress/meshopt/mod";

export const QUANTISED_VERTEX_SIZE: i32 = 32;
export const UV_SIZE: i32 = 8;
export const ZERO_OCT: i32 = -32768;

export class DecodedVertices {
    verts: Array<SurfaceVertex> = [];
    // null when the mesh had no second UV set.
    uv1: Array<Vec2>? = null;
}

// --- quantisation ----------------------------------------------------------------

function octDecode(a: i32, b: i32): Vec3 {
    if (a == ZERO_OCT && b == ZERO_OCT) return Vec3(0, 0, 0);
    let x = <f32>max<i32>(a, -32767) / <f32>32767;
    let y = <f32>max<i32>(b, -32767) / <f32>32767;
    const z = <f32>1 - Mathf.abs(x) - Mathf.abs(y);
    if (z < 0) {
        const ox = x;
        x = (<f32>1 - Mathf.abs(y)) * (ox >= 0 ? <f32>1 : <f32>-1);
        y = (<f32>1 - Mathf.abs(ox)) * (y >= 0 ? <f32>1 : <f32>-1);
    }
    const len = Mathf.sqrt(x * x + y * y + z * z);
    if (!(len > 0)) return Vec3(0, 0, 1);
    return Vec3(x / len, y / len, z / len);
}

function dequantise(q: i32, lo: f32, hi: f32): f32 {
    const ext = hi - lo;
    if (!(ext > 0)) return lo;
    return <f32>(<f64>lo + <f64>q / 65535.0 * <f64>ext);
}

// `count` vertices back from encodeVertices' bytes; fails, never traps, on
// bytes it did not write.
export function decodeVertices(bytes: Uint8Array, count: i32, hasUv1: bool, lo: Vec3, hi: Vec3, what: string): Result<DecodedVertices> {
    if (count < 0) return Result.fail<DecodedVertices>(what + ": " + count.toString() + " vertices");
    const n = bytes.length;
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (n < 8) return Result.fail<DecodedVertices>(what + ": compressed vertices: " + n.toString() + " bytes, too short for their header");
    const stored = dv.getUint32(0, true);
    if (<u64>stored != <u64>count) {
        return Result.fail<DecodedVertices>(what + ": compressed vertices: " + stored.toString() + " stored, " + count.toString() + " expected");
    }
    const mainLen = dv.getUint32(4, true);
    if (<u64>mainLen > <u64>(n - 8)) {
        return Result.fail<DecodedVertices>(what + ": compressed vertices: " + mainLen.toString() + " bytes do not fit in " + (n - 8).toString());
    }
    const main = decodeViewPooled(bytes.subarray(8, 8 + <i32>mainLen), count, QUANTISED_VERTEX_SIZE, Mode.Attributes, Filter.None);
    if (!main.ok) return Result.fail<DecodedVertices>(what + ": compressed vertices: " + main.err);
    const raw = main.value;
    const got = decodeVerticesFrom(bytes, dv, raw, count, hasUv1, lo, hi, what, mainLen);
    // (milestone 67b: the codec's output back to the pool, however it went)
    scratch().give(raw);
    return got;
}

// The rest of decodeVertices, `raw` the quantised vertices decoded.
function decodeVerticesFrom(bytes: Uint8Array, dv: DataView, raw: Uint8Array, count: i32, hasUv1: bool, lo: Vec3, hi: Vec3, what: string,
    mainLen: u32): Result<DecodedVertices> {
    const n = bytes.length;
    let o = 8 + <i32>mainLen;
    let uvRaw: Uint8Array? = null;
    if (hasUv1) {
        if (o + 4 > n) return Result.fail<DecodedVertices>(what + ": compressed UV set 1: the bytes end before its length");
        const ul = dv.getUint32(o, true);
        o += 4;
        if (<u64>ul > <u64>(n - o)) return Result.fail<DecodedVertices>(what + ": compressed UV set 1: " + ul.toString() + " bytes do not fit");
        const u = decodeViewPooled(bytes.subarray(o, o + <i32>ul), count, UV_SIZE, Mode.Attributes, Filter.None);
        if (!u.ok) return Result.fail<DecodedVertices>(what + ": compressed UV set 1: " + u.err);
        uvRaw = u.value;
        o += <i32>ul;
    }
    const got = decodeVerticesOut(raw, uvRaw, count, lo, hi, what, o, n);
    const ur = uvRaw;
    if (ur != null) scratch().give(ur);
    return got;
}

// The vertices (and second UV set) read out of the codec's bytes.
function decodeVerticesOut(raw: Uint8Array, uvRaw: Uint8Array?, count: i32, lo: Vec3, hi: Vec3, what: string, o: i32, n: i32)
    : Result<DecodedVertices> {
    if (o != n) return Result.fail<DecodedVertices>(what + ": compressed vertices: " + (n - o).toString() + " bytes left over");
    if (raw.length != count * QUANTISED_VERTEX_SIZE) return Result.fail<DecodedVertices>(what + ": compressed vertices: wrong decoded size");
    const r = new DecodedVertices();
    const rd = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
    for (let i = 0; i < count; i++) {
        const b = i * QUANTISED_VERTEX_SIZE;
        const pos = Vec3(dequantise(rd.getUint16(b, true), lo.x, hi.x), dequantise(rd.getUint16(b + 2, true), lo.y, hi.y),
            dequantise(rd.getUint16(b + 4, true), lo.z, hi.z));
        const sign = rd.getUint16(b + 6, true);
        const normal = octDecode(rd.getInt16(b + 8, true), rd.getInt16(b + 10, true));
        const t = octDecode(rd.getInt16(b + 12, true), rd.getInt16(b + 14, true));
        const w: f32 = sign == 0 ? 1 : sign == 1 ? -1 : 0;
        const uv = Vec2(rd.getFloat32(b + 16, true), rd.getFloat32(b + 20, true));
        r.verts.push(SurfaceVertex(pos, normal, uv, rd.getUint32(b + 24, true), Vec4(t.x, t.y, t.z, w), rd.getFloat32(b + 28, true)));
    }
    const ur = uvRaw;
    if (ur != null) {
        const ud = new DataView(ur.buffer, ur.byteOffset, ur.byteLength);
        const uv1 = new Array<Vec2>();
        for (let i = 0; i < count; i++) uv1.push(Vec2(ud.getFloat32(i * UV_SIZE, true), ud.getFloat32(i * UV_SIZE + 4, true)));
        r.uv1 = uv1;
    }
    return Result.okv<DecodedVertices>(r);
}

// `count` indices back from encodeIndices' bytes; fails, never traps, on
// bytes it did not write, a count that is not whole triangles, or an
// index past `vertexCount`.
export function decodeIndices(bytes: Uint8Array, count: i32, vertexCount: i32, what: string): Result<Array<u32>> {
    const r = decodeIndicesPooled(bytes, count, vertexCount, what);
    if (!r.ok) return r.forward<Array<u32>>();
    const raw = r.value;
    const out = new Array<u32>(count);
    for (let i = 0; i < count; i++) unchecked(out[i] = unchecked(raw[i]));
    releaseIndices(raw);
    return Result.okv<Array<u32>>(out);
}

// Milestone 67b: decodeIndices with the indices left in a scratch buffer
// (exactly `count` of them, every one checked against `vertexCount`), for
// a reader that copies them out and then calls releaseIndices; on a
// failure nothing is held.
export function decodeIndicesPooled(bytes: Uint8Array, count: i32, vertexCount: i32, what: string): Result<Uint32Array> {
    if (count < 0 || count % 3 != 0) return Result.fail<Uint32Array>(what + ": " + count.toString() + " indices are not whole triangles");
    if (count == 0) {
        if (bytes.length != 0) return Result.fail<Uint32Array>(what + ": compressed indices: bytes for no index");
        return Result.okv<Uint32Array>(new Uint32Array(0));
    }
    const r = decodeViewPooled(bytes, count, 4, Mode.Indices, Filter.None);
    if (!r.ok) return Result.fail<Uint32Array>(what + ": compressed indices: " + r.err);
    const raw = r.value;
    // (the codec's u32s, little-endian as wasm keeps them: read in place)
    const idx = Uint32Array.wrap(raw.buffer, raw.byteOffset, count);
    for (let i = 0; i < count; i++) {
        const v = unchecked(idx[i]);
        if (<u64>v >= <u64>vertexCount) {
            scratch().give(raw);
            return Result.fail<Uint32Array>(what + ": compressed indices: index " + v.toString() + " is past the mesh's " + vertexCount.toString() + " vertices");
        }
    }
    return Result.okv<Uint32Array>(idx);
}

// A decodeIndicesPooled result back to the pool.
export function releaseIndices(idx: Uint32Array): void {
    if (idx.length == 0) return;
    scratch().giveBuffer(idx.buffer);
}
