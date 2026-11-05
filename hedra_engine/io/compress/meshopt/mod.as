// `EXT_meshopt_compression`, the meshoptimizer vertex and index codecs.
//
// The extension is a *buffer view* transform. A compressed view names the
// codec (`mode`), how many elements it holds (`count`), how wide one is
// (`byteStride`) and an optional `filter` applied to the decoded bytes; the
// bytes themselves are lossless through the round trip, so unlike Draco
// this codec never changes a vertex.
//
// The codec takes the stride at run time. Only the strides the extension
// allows (a multiple of 4, up to 256) are accepted; any other stride is an
// error.
//
// Milestone 67b (docs/engine/RESOURCES.md, "Loading"): decodeViewPooled
// decodes into a buffer of the scratch pool (../../../base/scratch.as)
// for a reader that copies the bytes out into its own arrays and gives
// the buffer back (the prebuilt meshes' vertex codec,
// ../../../meshproc/vertex_codec.as); the vertex decoder's block buffers
// are pooled whichever way it is called. The bytes are decodeView's.

import { Result } from "../../../base/util";
import { scratch } from "../../../base/scratch";
import { DecodeError, decodeErrorDebug } from "./util";
import { decodeVertexBuffer, decodeVertexBufferEarlyError } from "./vertex/buffer";
import {
    decodeFilterExp, decodeFilterOct16, decodeFilterOct8, decodeFilterQuat,
} from "./vertex/filter";
import { decodeIndexBuffer } from "./index/buffer";
import { decodeIndexSequence } from "./index/sequence";

// Which codec a compressed buffer view uses.
export enum Mode {
    // Vertex attributes, `count` elements of `byteStride` bytes.
    Attributes,
    // Triangle indices, in a codec that exploits shared edges.
    Triangles,
    // Indices with no triangle structure (line strips, morph target ids).
    Indices,
}

// The Mode named `s`, or -1 when it names none.
export function modeParse(s: string): i32 {
    if (s == "ATTRIBUTES") return Mode.Attributes;
    if (s == "TRIANGLES") return Mode.Triangles;
    if (s == "INDICES") return Mode.Indices;
    return -1;
}

// The extension's name for a Mode.
export function modeName(m: Mode): string {
    switch (m) {
        case Mode.Attributes: return "ATTRIBUTES";
        case Mode.Triangles: return "TRIANGLES";
        default: return "INDICES";
    }
}

// The debug name of a Mode.
export function modeDebug(m: Mode): string {
    switch (m) {
        case Mode.Attributes: return "Attributes";
        case Mode.Triangles: return "Triangles";
        default: return "Indices";
    }
}

// A reversible transform applied to the decoded bytes. Only ever read:
// export writes `NONE`, because the upstream filters trade accuracy for
// size and choosing that trade for someone else's normals is not this
// exporter's call.
export enum Filter {
    None,
    Octahedral,
    Quaternion,
    Exponential,
}

// The Filter named `s`, or -1 when it names none.
export function filterParse(s: string): i32 {
    if (s == "NONE") return Filter.None;
    if (s == "OCTAHEDRAL") return Filter.Octahedral;
    if (s == "QUATERNION") return Filter.Quaternion;
    if (s == "EXPONENTIAL") return Filter.Exponential;
    return -1;
}

// The debug name of a Filter.
export function filterDebug(f: Filter): string {
    switch (f) {
        case Filter.None: return "None";
        case Filter.Octahedral: return "Octahedral";
        case Filter.Quaternion: return "Quaternion";
        default: return "Exponential";
    }
}

export function strideIsSupported(stride: i32): bool {
    return stride >= 4 && stride <= 256 && stride % 4 == 0;
}

export function strideError<T>(stride: u64): Result<T> {
    return Result.fail<T>("byteStride " + stride.toString() + " is not a multiple of 4 between 4 and 256");
}

export function indexStrideError<T>(stride: u64): Result<T> {
    return Result.fail<T>("index byteStride must be 2 or 4, not " + stride.toString());
}

function wholeTrianglesError<T>(count: u64): Result<T> {
    return Result.fail<T>(
        "TRIANGLES holds " + count.toString() + " indices, which is not a whole number of triangles",
    );
}

function vertexCorrupt<T>(e: i32): Result<T> {
    return Result.fail<T>("meshopt vertex stream is corrupt (" + decodeErrorDebug(<DecodeError>e) + ")");
}

function indexCorrupt<T>(e: i32): Result<T> {
    return Result.fail<T>("meshopt index stream is corrupt (" + decodeErrorDebug(<DecodeError>e) + ")");
}

function filterStrideError<T>(f: Filter, stride: u64): Result<T> {
    return Result.fail<T>("filter " + filterDebug(f) + " does not go with byteStride " + stride.toString());
}

// The largest buffer this runtime can allocate: a typed array's backing
// buffer is capped just under 1 GiB (rasc std BLOCK_MAXSIZE). A view that
// would decode past it fails with tooLarge instead of trapping.
const MAX_VIEW_BYTES: u64 = (<u64>1 << 30) - 64;

function tooLarge<T>(count: u64, stride: u64): Result<T> {
    return Result.fail<T>(
        "meshopt view of " + count.toString() + " x " + stride.toString() + " bytes is too large to decode",
    );
}

// The shortest stream the index decoders accept for `count` indices (their
// first check: header, 1 byte per triangle and the 16-byte codeaux table, or
// header, 1 byte per index and the 4-byte tail). Checking this before
// allocating the `count` destination gives the decoder's error without the
// allocation.
function indexStreamTooShort(length: i32, count: u64, mode: Mode): bool {
    const len = <u64>length;
    if (mode == Mode.Triangles) return len < 1 + count / 3 + 16;
    return len < 5 || count > len - 5;
}

// Decode one compressed buffer view into the `count * stride` bytes it
// stands for. `count` and `stride` must be non-negative; decodeViewU64 takes the extension's values when they may not fit
// in an i32.
export function decodeView(
    compressed: Uint8Array,
    count: i32,
    stride: i32,
    mode: Mode,
    filter: Filter,
): Result<Uint8Array> {
    return decodeViewIn(compressed, count, stride, mode, filter, false);
}

// Milestone 67b: decodeView into a scratch buffer of exactly `count *
// stride` bytes, which the caller gives back (scratch().give) once it has
// read it (see the header); on a failure nothing is held.
export function decodeViewPooled(
    compressed: Uint8Array,
    count: i32,
    stride: i32,
    mode: Mode,
    filter: Filter,
): Result<Uint8Array> {
    return decodeViewIn(compressed, count, stride, mode, filter, true);
}

function decodeViewIn(compressed: Uint8Array, count: i32, stride: i32, mode: Mode, filter: Filter, pooled: bool): Result<Uint8Array> {
    let r: Result<Uint8Array>;
    switch (mode) {
        case Mode.Attributes: {
            r = decodeAttributes(compressed, count, stride, pooled);
            break;
        }
        default: {
            r = decodeIndices(compressed, count, stride, mode, pooled);
            break;
        }
    }
    if (!r.ok) return r;
    const out = r.value;
    const f = applyFilter(out, stride, filter);
    if (!f.ok) {
        if (pooled) scratch().give(out);
        return f.forward<Uint8Array>();
    }
    return Result.okv<Uint8Array>(out);
}

function decodeAttributes(compressed: Uint8Array, count: i32, stride: i32, pooled: bool = false): Result<Uint8Array> {
    if (count == 0) {
        return Result.okv<Uint8Array>(new Uint8Array(0));
    }
    if (!strideIsSupported(stride)) {
        return strideError<Uint8Array>(<u64>stride);
    }
    // A stream that can only fail is answered before allocating the
    // destination (same error), so a corrupt count cannot exhaust memory.
    const early = decodeVertexBufferEarlyError(<u64>count, stride, compressed);
    if (early >= 0) {
        return vertexCorrupt<Uint8Array>(early);
    }
    if (<u64>count * <u64>stride > MAX_VIEW_BYTES) {
        return tooLarge<Uint8Array>(<u64>count, <u64>stride);
    }
    // The destination is allocated as the bytes it will be read back as
    // (milestone 67b: or taken from the pool; the decoder writes every
    // byte of it).
    const out = pooled ? scratch().take(count * stride) : new Uint8Array(count * stride);
    const r = decodeVertexBuffer(out, count, stride, compressed);
    if (!r.ok) {
        if (pooled) scratch().give(out);
        return Result.fail<Uint8Array>("meshopt vertex stream is corrupt (" + r.err + ")");
    }
    return Result.okv<Uint8Array>(out);
}

function decodeIndices(compressed: Uint8Array, count: i32, stride: i32, mode: Mode, pooled: bool = false): Result<Uint8Array> {
    if (!(stride == 2 || stride == 4)) {
        return indexStrideError<Uint8Array>(<u64>stride);
    }
    if (mode == Mode.Triangles && count % 3 != 0) {
        return wholeTrianglesError<Uint8Array>(<u64>count);
    }
    // The decoder's first check, made before allocating the `count` indices.
    if (indexStreamTooShort(compressed.length, <u64>count, mode)) {
        return indexCorrupt<Uint8Array>(<i32>DecodeError.UnexpectedEof);
    }
    if (<u64>count * 4 > MAX_VIEW_BYTES) {
        return tooLarge<Uint8Array>(<u64>count, <u64>stride);
    }
    // The codec only writes `u32`; a 2-byte view is narrowed afterwards.
    // (milestone 67b: pooled, a 4-byte view is the u32s' own bytes, which
    // wasm keeps little-endian: no second buffer)
    const indices = pooled ? scratch().takeU32(count) : new Uint32Array(count);
    const r = mode == Mode.Triangles
        ? decodeIndexBuffer(indices, compressed)
        : decodeIndexSequence(indices, compressed);
    if (!r.ok) {
        if (pooled) scratch().giveU32(indices);
        return Result.fail<Uint8Array>("meshopt index stream is corrupt (" + r.err + ")");
    }
    if (pooled && stride == 4) return Result.okv<Uint8Array>(Uint8Array.wrap(indices.buffer, 0, count * 4));
    const out = pooled ? scratch().take(count * stride) : new Uint8Array(count * stride);
    if (stride == 2) {
        for (let i = 0; i < count; i++) {
            const v = <u16>indices[i];
            out[i * 2] = <u8>v;
            out[i * 2 + 1] = <u8>(v >> 8);
        }
    } else {
        for (let i = 0; i < count; i++) {
            const v = indices[i];
            out[i * 4] = <u8>v;
            out[i * 4 + 1] = <u8>(v >> 8);
            out[i * 4 + 2] = <u8>(v >> 16);
            out[i * 4 + 3] = <u8>(v >> 24);
        }
    }
    if (pooled) scratch().giveU32(indices);
    return Result.okv<Uint8Array>(out);
}

// Undo the extension's `filter`, in place over the decoded bytes.
function applyFilter(data: Uint8Array, stride: i32, f: Filter): Result<bool> {
    if (f == Filter.None) {
        return Result.okv<bool>(true);
    }
    if (f == Filter.Octahedral && stride == 4) {
        decodeFilterOct8(data);
        return Result.okv<bool>(true);
    }
    if (f == Filter.Octahedral && stride == 8) {
        decodeFilterOct16(data);
        return Result.okv<bool>(true);
    }
    if (f == Filter.Quaternion && stride == 8) {
        decodeFilterQuat(data);
        return Result.okv<bool>(true);
    }
    if (f == Filter.Exponential && stride % 4 == 0) {
        decodeFilterExp(data);
        return Result.okv<bool>(true);
    }
    return filterStrideError<bool>(f, <u64>stride);
}

// decodeView for the extension's `count` and `byteStride` as parsed from JSON
// as unsigned 64-bit values, which need not fit in an i32. Values that fit
// go to decodeView. Larger ones still get the answers they would at full
// width: the argument errors, or the corrupt-stream error of a stream too short for
// `count` elements; the same errors come back here, in the same order,
// without allocating. A view that could really decode to that size fails with
// the "too large to decode" error (nothing that large fits in this runtime).
export function decodeViewU64(
    compressed: Uint8Array,
    count: u64,
    stride: u64,
    mode: Mode,
    filter: Filter,
): Result<Uint8Array> {
    const fits = <u64>i32.MAX_VALUE;
    if (count <= fits && stride <= fits) {
        return decodeView(compressed, <i32>count, <i32>stride, mode, filter);
    }
    if (mode == Mode.Attributes) {
        if (count == 0) {
            // Ok(empty), then apply_filter over no bytes: only the stride test
            // can fail, and no stride this large is 4 or 8.
            if (filter == Filter.None || (filter == Filter.Exponential && stride % 4 == 0)) {
                return Result.okv<Uint8Array>(new Uint8Array(0));
            }
            return filterStrideError<Uint8Array>(filter, stride);
        }
        if (!(stride >= 4 && stride <= 256 && stride % 4 == 0)) {
            return strideError<Uint8Array>(stride);
        }
        const early = decodeVertexBufferEarlyError(count, <i32>stride, compressed);
        if (early >= 0) {
            return vertexCorrupt<Uint8Array>(early);
        }
        return tooLarge<Uint8Array>(count, stride);
    }
    if (!(stride == 2 || stride == 4)) {
        return indexStrideError<Uint8Array>(stride);
    }
    if (mode == Mode.Triangles && count % 3 != 0) {
        return wholeTrianglesError<Uint8Array>(count);
    }
    if (indexStreamTooShort(compressed.length, count, mode)) {
        return indexCorrupt<Uint8Array>(<i32>DecodeError.UnexpectedEof);
    }
    return tooLarge<Uint8Array>(count, stride);
}
