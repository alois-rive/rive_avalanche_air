// Binary glTF: splitting a .glb into its JSON and BIN chunks, and writing
// one (`Glb::to_vec`).

import { Result, ErrorValue } from "../../../base/util";

// The message of a read that ends before the bytes it needs.
export const FAILED_TO_FILL_WHOLE_BUFFER = "failed to fill whole buffer";

// Why a .glb could not be split.
export enum GlbErrorKind {
    Io,
    Version,
    Magic,
    Length,
    ChunkLength,
    ChunkType,
    UnknownChunkType,
}

export enum ChunkType {
    Json,
    Bin,
}

export class GlbError extends ErrorValue {
    kind: GlbErrorKind;
    chunk: ChunkType = ChunkType.Json; // ChunkLength / ChunkType
    version: u32 = 0;
    ioText: string = ""; // Io: the io::Error's Display
    constructor(kind: GlbErrorKind) {
        super();
        this.kind = kind;
    }

    static io(text: string): GlbError {
        const e = new GlbError(GlbErrorKind.Io);
        e.ioText = text;
        return e;
    }

    static chunk(kind: GlbErrorKind, ty: ChunkType): GlbError {
        const e = new GlbError(kind);
        e.chunk = ty;
        return e;
    }

    // binary::Error's Display.
    toString(): string {
        switch (this.kind) {
            case GlbErrorKind.Io: return this.ioText;
            case GlbErrorKind.Version: return "unsupported version";
            case GlbErrorKind.Magic: return "not glTF magic";
            case GlbErrorKind.Length: return "could not completely read the object";
            case GlbErrorKind.ChunkLength:
                return this.chunk == ChunkType.Json
                    ? "JSON chunk length exceeds that of slice"
                    : "BIN\\0 chunk length exceeds that of slice";
            case GlbErrorKind.ChunkType:
                return this.chunk == ChunkType.Json ? "was not expecting JSON chunk" : "was not expecting BIN\\0 chunk";
            default: return "unknown chunk type";
        }
    }
}

// Glb: the JSON chunk and the optional BIN chunk.
export class Glb {
    version: u32 = 2;
    length: u32 = 0;
    json: Uint8Array = new Uint8Array(0);
    bin: Uint8Array? = null;
}

function u32le(b: Uint8Array, at: i32): u32 {
    return <u32>b[at] | (<u32>b[at + 1] << 8) | (<u32>b[at + 2] << 16) | (<u32>b[at + 3] << 24);
}

// ChunkHeader::from_reader at `at`: [length, type], or an error.
class ChunkHeader {
    length: u32 = 0;
    ty: ChunkType = ChunkType.Json;
}

function readChunkHeader(data: Uint8Array, at: i32): Result<ChunkHeader> {
    if (data.length - at < 8) return Result.failWith<ChunkHeader>(GlbError.io(FAILED_TO_FILL_WHOLE_BUFFER));
    const h = new ChunkHeader();
    h.length = u32le(data, at);
    const a = data[at + 4];
    const b = data[at + 5];
    const c = data[at + 6];
    const d = data[at + 7];
    if (a == 0x4A && b == 0x53 && c == 0x4F && d == 0x4E) h.ty = ChunkType.Json; // "JSON"
    else if (a == 0x42 && b == 0x49 && c == 0x4E && d == 0) h.ty = ChunkType.Bin; // "BIN\0"
    else return Result.failWith<ChunkHeader>(new GlbError(GlbErrorKind.UnknownChunkType));
    return Result.okv<ChunkHeader>(h);
}

// split_binary_gltf: the JSON chunk, then an optional BIN chunk (anything
// after the BIN chunk's declared length is ignored).
function splitBinaryGltf(data: Uint8Array, glb: Glb): Result<Glb> {
    const jh = readChunkHeader(data, 0);
    if (!jh.ok) return jh.forward<Glb>();
    const j = jh.value;
    if (j.ty != ChunkType.Json) return Result.failWith<Glb>(GlbError.chunk(GlbErrorKind.ChunkType, j.ty));
    let rest = data.length - 8;
    if (<u64>j.length > <u64>rest) return Result.failWith<Glb>(GlbError.chunk(GlbErrorKind.ChunkLength, j.ty));
    glb.json = data.slice(8, 8 + <i32>j.length);
    const at = 8 + <i32>j.length;
    rest = data.length - at;
    if (rest > 0) {
        const bh = readChunkHeader(data, at);
        if (!bh.ok) return bh.forward<Glb>();
        const bin = bh.value;
        if (bin.ty != ChunkType.Bin) return Result.failWith<Glb>(GlbError.chunk(GlbErrorKind.ChunkType, bin.ty));
        if (<u64>bin.length > <u64>(rest - 8)) {
            return Result.failWith<Glb>(GlbError.chunk(GlbErrorKind.ChunkLength, bin.ty));
        }
        glb.bin = data.slice(at + 8, at + 8 + <i32>bin.length);
    }
    return Result.okv<Glb>(glb);
}

function startsWithGltf(b: Uint8Array): bool {
    return b.length >= 4 && b[0] == 0x67 && b[1] == 0x6C && b[2] == 0x54 && b[3] == 0x46;
}

// `slice.starts_with(b"glTF")`.
export function isGlb(bytes: Uint8Array): bool {
    return startsWithGltf(bytes);
}

// Glb::from_slice. The header's length must fit in the slice; its version
// is checked after that. A header length below 12 is a Length error.
export function glbFromSlice(data: Uint8Array): Result<Glb> {
    if (data.length < 4) return Result.failWith<Glb>(GlbError.io(FAILED_TO_FILL_WHOLE_BUFFER));
    if (!startsWithGltf(data)) return Result.failWith<Glb>(new GlbError(GlbErrorKind.Magic));
    if (data.length < 12) return Result.failWith<Glb>(GlbError.io(FAILED_TO_FILL_WHOLE_BUFFER));
    const glb = new Glb();
    glb.version = u32le(data, 4);
    glb.length = u32le(data, 8);
    const rest = data.length - 12;
    if (glb.length < 12 || <u64>(glb.length - 12) > <u64>rest) {
        return Result.failWith<Glb>(new GlbError(GlbErrorKind.Length));
    }
    if (glb.version != 2) {
        const e = new GlbError(GlbErrorKind.Version);
        e.version = glb.version;
        return Result.failWith<Glb>(e);
    }
    return splitBinaryGltf(data.subarray(12), glb);
}

// Glb::from_reader over a whole file's bytes: the header, then exactly
// `length - 12` bytes (u32 wrapping, as in release), anything after them
// unread.
export function glbFromReader(data: Uint8Array): Result<Glb> {
    if (data.length < 4) return Result.failWith<Glb>(GlbError.io(FAILED_TO_FILL_WHOLE_BUFFER));
    if (!startsWithGltf(data)) return Result.failWith<Glb>(new GlbError(GlbErrorKind.Magic));
    if (data.length < 12) return Result.failWith<Glb>(GlbError.io(FAILED_TO_FILL_WHOLE_BUFFER));
    const glb = new Glb();
    glb.version = u32le(data, 4);
    glb.length = u32le(data, 8);
    if (glb.version != 2) {
        const e = new GlbError(GlbErrorKind.Version);
        e.version = glb.version;
        return Result.failWith<Glb>(e);
    }
    const glbLen = glb.length - 12; // u32 wrapping
    if (<u64>glbLen > <u64>(data.length - 12)) return Result.failWith<Glb>(GlbError.io(FAILED_TO_FILL_WHOLE_BUFFER));
    return splitBinaryGltf(data.subarray(12, 12 + <i32>glbLen), glb);
}

function align4(n: i32): i32 {
    return (n + 3) & ~3;
}

function putU32(out: Uint8Array, at: i32, v: u32): void {
    out[at] = <u8>v;
    out[at + 1] = <u8>(v >> 8);
    out[at + 2] = <u8>(v >> 16);
    out[at + 3] = <u8>(v >> 24);
}

// Glb::to_vec: header, the JSON chunk padded with spaces, then the BIN
// chunk (when there is one) padded with zeros; both lengths 4-aligned.
export function glbToVec(json: Uint8Array, bin: Uint8Array?): Uint8Array {
    let length = align4(12 + 8 + json.length);
    if (bin != null) length = align4(length + 8 + bin.length);
    const out = new Uint8Array(length);
    out[0] = 0x67; out[1] = 0x6C; out[2] = 0x54; out[3] = 0x46; // glTF
    putU32(out, 4, 2);
    putU32(out, 8, <u32>length);
    const jl = align4(json.length);
    putU32(out, 12, <u32>jl);
    out[16] = 0x4A; out[17] = 0x53; out[18] = 0x4F; out[19] = 0x4E; // JSON
    out.set(json, 20);
    for (let i = 20 + json.length; i < 20 + jl; i++) out[i] = 0x20;
    if (bin != null) {
        const at = 20 + jl;
        const bl = align4(bin.length);
        putU32(out, at, <u32>bl);
        out[at + 4] = 0x42; out[at + 5] = 0x49; out[at + 6] = 0x4E; out[at + 7] = 0; // BIN\0
        out.set(bin, at + 8);
    }
    return out;
}
