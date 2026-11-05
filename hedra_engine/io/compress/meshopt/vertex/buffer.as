// Derived from meshopt-rs 0.1.2 (MIT); see THIRD_PARTY_NOTICES.md.
//
// Vertex buffer encoding and decoding (meshoptimizer bitstream, header
// 0xA0 | version; v0 only).
//
// The vertices are raw bytes plus an explicit `vertexCount` and `vertexSize`.

import { panic, Result } from "../../../../base/util";
import { scratch } from "../../../../base/scratch";
import { ByteReader, DecodeError, decodeFail, decodeOk } from "../util";

export const VERTEX_HEADER: u8 = 0xa0;

const VERTEX_BLOCK_SIZE_BYTES: i32 = 8192;
export const VERTEX_BLOCK_MAX_SIZE: i32 = 256;
export const BYTE_GROUP_SIZE: i32 = 16;
export const BYTE_GROUP_DECODE_LIMIT: i32 = 24;
export const TAIL_MAX_SIZE: i32 = 32;

// Internal "no error" code of the decoder helpers.
const DECODE_OK: i32 = -1;

// The "no size yet" maximum in encodeBytesGroupMeasure (only compared with `<`).
export const MEASURE_MAX: i32 = i32.MAX_VALUE;

export function getVertexBlockSize(vertexSize: i32): i32 {
    // make sure the entire block fits into the scratch buffer
    let result = VERTEX_BLOCK_SIZE_BYTES / vertexSize;

    // align to byte group size; we encode each byte as a byte group
    // if vertex block is misaligned, it results in wasted bytes, so just truncate the block size
    result &= ~(BYTE_GROUP_SIZE - 1);

    return min<i32>(result, VERTEX_BLOCK_MAX_SIZE);
}

function unzigzag8(v: u8): u8 {
    return <u8>(-(<i32>(v & 1))) ^ <u8>(v >> 1);
}

function decodeBytesGroup(data: ByteReader, out: Uint8Array, outOff: i32, bitslog2: i32): void {
    let o = outOff;

    switch (bitslog2) {
        case 0: {
            for (let j = 0; j < BYTE_GROUP_SIZE; j++) out[o + j] = 0;
            break;
        }
        case 1:
        case 2: {
            const bits: u8 = bitslog2 == 1 ? 2 : 4;
            const groups = bitslog2 == 1 ? 4 : 8;
            const perByte = bitslog2 == 1 ? 4 : 2;
            const sentinel: u8 = <u8>((1 << bits) - 1);

            let dataPos = data.pos;
            let dataVarPos = dataPos + groups;

            // 4 groups with 4 2-bit values in each byte, or 8 groups with 2 4-bit values
            for (let g = 0; g < groups; g++) {
                data.pos = dataPos;
                let byte = data.readByte();
                dataPos += 1;

                for (let n = 0; n < perByte; n++) {
                    const enc = <u8>(byte >> (8 - bits));
                    byte = <u8>(byte << bits);
                    data.pos = dataVarPos;
                    const encv = data.readByte();
                    out[o] = enc == sentinel ? encv : enc;
                    o++;
                    dataVarPos += enc == sentinel ? 1 : 0;
                }
            }

            data.pos = dataVarPos;
            break;
        }
        default: {
            // 3: a raw 16-byte group
            for (let j = 0; j < BYTE_GROUP_SIZE; j++) out[o + j] = data.readByte();
            break;
        }
    }
}

// Returns DECODE_OK or a DecodeError.
function decodeBytes(data: ByteReader, buffer: Uint8Array, bufferLen: i32): i32 {
    if (bufferLen % BYTE_GROUP_SIZE != 0) panic("assertion failed: buffer.len() % BYTE_GROUP_SIZE == 0");

    // round number of groups to 4 to get number of header bytes
    const headerSize = (bufferLen / BYTE_GROUP_SIZE + 3) / 4;

    if (data.remaining() < headerSize) {
        return <i32>DecodeError.UnexpectedEof;
    }

    const header = data.start + data.pos;

    data.pos = data.pos + headerSize;

    for (let i = 0; i < bufferLen; i += BYTE_GROUP_SIZE) {
        if (data.remaining() < BYTE_GROUP_DECODE_LIMIT) {
            return <i32>DecodeError.UnexpectedEof;
        }

        const headerOffset = i / BYTE_GROUP_SIZE;

        const bitslog2 = (<i32>data.buf[header + headerOffset / 4] >> ((headerOffset % 4) * 2)) & 3;

        decodeBytesGroup(data, buffer, i, bitslog2);
    }

    return DECODE_OK;
}

function decodeVertexBlock(
    data: ByteReader,
    vertexData: Uint8Array,
    vdOffset: i32,
    vertexCount: i32,
    vertexSize: i32,
    lastVertex: Uint8Array,
    buffer: Uint8Array,
    transposed: Uint8Array,
): i32 {
    if (!(vertexCount > 0 && vertexCount <= VERTEX_BLOCK_MAX_SIZE)) {
        panic("assertion failed: vertex_count > 0 && vertex_count <= VERTEX_BLOCK_MAX_SIZE");
    }

    const vertexCountAligned = (vertexCount + BYTE_GROUP_SIZE - 1) & ~(BYTE_GROUP_SIZE - 1);

    for (let k = 0; k < vertexSize; k++) {
        const e = decodeBytes(data, buffer, vertexCountAligned);
        if (e != DECODE_OK) return e;

        let vertexOffset = k;

        let p: u8 = lastVertex[k];

        for (let i = 0; i < vertexCount; i++) {
            const v = <u8>(unzigzag8(buffer[i]) + p);

            transposed[vertexOffset] = v;
            p = v;

            vertexOffset += vertexSize;
        }
    }

    const n = vertexCount * vertexSize;
    for (let j = 0; j < n; j++) vertexData[vdOffset + j] = transposed[j];

    const offset = vertexSize * (vertexCount - 1);
    for (let j = 0; j < vertexSize; j++) lastVertex[j] = transposed[offset + j];

    return DECODE_OK;
}

// The group-header bytes one byte lane of a block of `blockCount` vertices
// takes (decode_bytes' `header_size` over the group-aligned count).
function blockHeaderSize(blockCount: i32): i32 {
    const aligned = (blockCount + BYTE_GROUP_SIZE - 1) & ~(BYTE_GROUP_SIZE - 1);
    return (aligned / BYTE_GROUP_SIZE + 3) / 4;
}

// Added to the upstream codec. The error decodeVertexBuffer returns for `buffer` and
// `vertexCount` vertices of `vertexSize` bytes when it is known before any
// block is decoded, or -1 when only decoding can tell. These are its three
// up-front checks, in order, then a buffer too short for `vertexCount`
// vertices however they were encoded: every byte lane of every block takes at
// least its group-header bytes and the tail must be left over, and when it is
// not, decode_bytes or the final tail check fails with UnexpectedEof. This lets a caller answer a
// stream that can only fail without allocating `vertexCount * vertexSize`
// bytes (a corrupt count).
export function decodeVertexBufferEarlyError(vertexCount: u64, vertexSize: i32, buffer: Uint8Array): i32 {
    if (!(vertexSize > 0 && vertexSize <= 256)) panic("assertion failed: vertex_size > 0 && vertex_size <= 256");
    if (vertexSize % 4 != 0) panic("assertion failed: vertex_size % 4 == 0");

    if (buffer.length < 1 + vertexSize) {
        return <i32>DecodeError.UnexpectedEof;
    }
    if ((buffer[0] & 0xf0) != VERTEX_HEADER) {
        return <i32>DecodeError.InvalidHeader;
    }
    if ((buffer[0] & 0x0f) > 0) {
        return <i32>DecodeError.UnsupportedVersion;
    }

    const blockSize = getVertexBlockSize(vertexSize);
    // Past 2^40 vertices the minimum is beyond any buffer; the clamp keeps the u64 math exact.
    const n = min<u64>(vertexCount, <u64>1 << 40);
    const fullBlocks = n / <u64>blockSize;
    const rest = <i32>(n % <u64>blockSize);
    let headers = fullBlocks * <u64>blockHeaderSize(blockSize);
    if (rest > 0) headers += <u64>blockHeaderSize(rest);
    const minLength = 1 + <u64>vertexSize * headers + <u64>max<i32>(vertexSize, TAIL_MAX_SIZE);

    if (<u64>buffer.length < minLength) {
        return <i32>DecodeError.UnexpectedEof;
    }
    return DECODE_OK;
}

// Decodes vertex data from an array of bytes generated by encodeVertexBuffer
// into `destination` (`vertexCount * vertexSize` bytes).
//
// Ok(true) on success; otherwise the error's debug name is in `r.err` and its
// kind in `decodeErrorOf(r)`. Safe for untrusted input, but it may produce
// garbage data.
export function decodeVertexBuffer(
    destination: Uint8Array,
    vertexCount: i32,
    vertexSize: i32,
    buffer: Uint8Array,
): Result<bool> {
    if (!(vertexSize > 0 && vertexSize <= 256)) panic("assertion failed: vertex_size > 0 && vertex_size <= 256");
    if (vertexSize % 4 != 0) panic("assertion failed: vertex_size % 4 == 0");

    const vertexData = destination;

    if (buffer.length < 1 + vertexSize) {
        return decodeFail(DecodeError.UnexpectedEof);
    }

    const data = new ByteReader(buffer, 0, buffer.length);

    const dataHeader = data.readByte();

    if ((dataHeader & 0xf0) != VERTEX_HEADER) {
        return decodeFail(DecodeError.InvalidHeader);
    }

    const version = dataHeader & 0x0f;
    if (version > 0) {
        return decodeFail(DecodeError.UnsupportedVersion);
    }

    // (milestone 67b: the three block buffers from the scratch pool,
    // ../../../../base/scratch.as, given back however the decode ends;
    // lastVertex is zeroed past the tail as a new one is)
    const pool = scratch();
    const lastVertex = pool.take(256);
    const tailStart = buffer.length - vertexSize;
    for (let j = 0; j < vertexSize; j++) lastVertex[j] = buffer[tailStart + j];
    for (let j = vertexSize; j < 256; j++) lastVertex[j] = 0;

    // decodeVertexBlock never reads a byte it
    // has not written in the same block, so one scratch pair serves every block.
    const blockScratch = pool.take(VERTEX_BLOCK_MAX_SIZE);
    const transposed = pool.take(VERTEX_BLOCK_SIZE_BYTES);
    const r = decodeVertexBlocks(data, vertexData, vertexCount, vertexSize, buffer, lastVertex, blockScratch, transposed);
    pool.give(transposed);
    pool.give(blockScratch);
    pool.give(lastVertex);
    return r;
}

// The blocks and the tail check of decodeVertexBuffer, over its buffers.
function decodeVertexBlocks(
    data: ByteReader,
    vertexData: Uint8Array,
    vertexCount: i32,
    vertexSize: i32,
    buffer: Uint8Array,
    lastVertex: Uint8Array,
    blockScratch: Uint8Array,
    transposed: Uint8Array,
): Result<bool> {
    const vertexBlockSize = getVertexBlockSize(vertexSize);

    let vertexOffset = 0;

    while (vertexOffset < vertexCount) {
        const blockSize = vertexOffset + vertexBlockSize < vertexCount
            ? vertexBlockSize
            : vertexCount - vertexOffset;

        const e = decodeVertexBlock(
            data,
            vertexData,
            vertexOffset * vertexSize,
            blockSize,
            vertexSize,
            lastVertex,
            blockScratch,
            transposed,
        );
        if (e != DECODE_OK) return decodeFail(<DecodeError>e);

        vertexOffset += blockSize;
    }

    const tailSize = max<i32>(vertexSize, TAIL_MAX_SIZE);

    if (buffer.length - data.pos != tailSize) {
        return decodeFail(DecodeError.UnexpectedEof);
    }

    return decodeOk();
}
