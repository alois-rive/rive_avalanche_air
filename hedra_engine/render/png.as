// Derived from image-rs png 0.18.1 and fdeflate 0.3.7 (MIT OR Apache-2.0); see THIRD_PARTY_NOTICES.md.
//
// PNG codec on bytes, behind `Image.decodePng` (the encoder: source/codec/png_write.as).
// Scripts have no file system, so the image module encodes to and decodes
// from byte arrays; the caller does the I/O.
//
// Decoding follows png's streaming `Decoder` reading a file through a
// buffered reader, normalized to 8-bit color (expand palette and low bit
// depths, strip 16-bit), inflating with fdeflate's decoder: every color type
// and bit depth, Adam7 interlacing, palette and tRNS expansion, 16-bit
// stripped to the high byte, and png's error texts ("Invalid PNG
// signature.", "CRC error: ...", "Corrupt deflate stream. <inflate error>")
// in the order the streaming decoder meets them (see the decode section).
//
// Encoding writes 8-bit RGBA, non-interlaced, adaptive filters and a
// fixed-Huffman LZ77 deflate stream. The bytes differ from other encoders'
// (another compressor); the decoded pixels are the same.
//
// Milestone 67b (docs/engine/RESOURCES.md, "Loading"): what a decode
// throws away comes from the scratch pool (../base/scratch.as) and goes
// back to it, so that a load of many textures does not allocate each one's
// temporaries again: the unfiltering window (PngReader.data, grown by
// doubling as before, each size a pooled buffer), the interlaced pass's
// row, and the inflater itself (its tables, about 19 KiB, kept free
// between streams: takeInflate, giveInflate). The pixels are the same
// bytes with and without the pool: every byte read back was written by
// the same stream first (the tables are rebuilt for every block, as they
// already are between the blocks of one stream).

import { Result, panic } from "../base/util";
// (the pool under another name: PngReader has a member `scratch`)
import { scratch as scratchPool } from "../base/scratch";

// ---------------------------------------------------------------------------
// CRC-32 (ISO 3309, as in PNG) and Adler-32.

const CRC_TABLE: StaticArray<u32> = buildCrcTable();

function buildCrcTable(): StaticArray<u32> {
    const t = new StaticArray<u32>(256);
    for (let n: u32 = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) {
            c = (c & 1) != 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        }
        t[n] = c;
    }
    return t;
}

// Running CRC update (start from 0xffffffff, finish with ~).
export function crcUpdate(crc: u32, b: Uint8Array, start: i32, end: i32): u32 {
    let c = crc;
    for (let i = start; i < end; i++) {
        c = unchecked(CRC_TABLE[(c ^ <u32>b[i]) & 0xff]) ^ (c >>> 8);
    }
    return c;
}

// CRC-32 of b[start..end].
export function crc32(b: Uint8Array, start: i32, end: i32): u32 {
    return ~crcUpdate(0xffffffff, b, start, end);
}

export function adler32(b: Uint8Array, start: i32, end: i32): u32 {
    let a: u32 = 1;
    let s: u32 = 0;
    let i = start;
    while (i < end) {
        const n = min<i32>(end - i, 5552);
        for (let k = 0; k < n; k++) {
            a += <u32>b[i + k];
            s += a;
        }
        a %= 65521;
        s %= 65521;
        i += n;
    }
    return (s << 16) | a;
}

// ---------------------------------------------------------------------------
// Growable byte buffer.

export class ByteBuf {
    data: Uint8Array;
    len: i32 = 0;

    constructor(cap: i32) {
        this.data = new Uint8Array(max<i32>(cap, 16));
    }

    reserve(extra: i32): void {
        const need = this.len + extra;
        if (need <= this.data.length) return;
        let cap = this.data.length;
        while (cap < need) cap = cap * 2;
        const d = new Uint8Array(cap);
        d.set(this.data.subarray(0, this.len), 0);
        this.data = d;
    }

    push(v: u8): void {
        if (this.len >= this.data.length) this.reserve(1);
        this.data[this.len] = v;
        this.len++;
    }

    pushU32Be(v: u32): void {
        this.push(<u8>(v >>> 24));
        this.push(<u8>(v >>> 16));
        this.push(<u8>(v >>> 8));
        this.push(<u8>v);
    }

    pushBytes(b: Uint8Array, start: i32, end: i32): void {
        const n = end - start;
        this.reserve(n);
        this.data.set(b.subarray(start, end), this.len);
        this.len += n;
    }

    pushStr(s: string): void {
        for (let i = 0; i < s.length; i++) this.push(<u8>s.charCodeAt(i));
    }

    finish(): Uint8Array {
        return this.data.slice(0, this.len);
    }
}

// ---------------------------------------------------------------------------
// Deflate code tables (RFC 1951), shared by the inflater and the deflater.

export const LEN_BASE: StaticArray<u16> = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
export const LEN_EXTRA: StaticArray<u8> = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
export const DIST_BASE: StaticArray<u16> = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
export const DIST_EXTRA: StaticArray<u8> = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
const CLCL_ORDER: StaticArray<u8> = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

// ---------------------------------------------------------------------------
// Inflate: fdeflate's `Decompressor`, the zlib decoder png uses. The error
// precedence (a corrupt stream against a bad row filter or a chunk CRC)
// depends on where the decoder stops for lack of input or output space and
// on which error it reports, so this keeps fdeflate's state machine, bit
// buffer and tables, table-building rules (complete codes
// only; symbols 286/287 of the fixed code end the block) and error names. Its
// fast decoding loop is left out: while at least 8 bytes of input and output
// remain it decodes the same symbols as the careful loop, with the same
// results. The Adler-32 is never checked (png sets `ignore_adler32`).

const LITERAL_ENTRY: u32 = 0x8000;
const EXCEPTIONAL_ENTRY: u32 = 0x4000;
const SECONDARY_TABLE_ENTRY: u32 = 0x2000;

enum FdState {
    ZlibHeader,
    BlockHeader,
    CodeLengthCodes,
    CodeLengths,
    CompressedData,
    UncompressedData,
    Checksum,
    Done,
}

// LITLEN_TABLE_ENTRIES: literals, length bases and extra
// bits; 256, 286 and 287 are EXCEPTIONAL_ENTRY (end of block).
function makeLitlenEntries(): StaticArray<u32> {
    const e = new StaticArray<u32>(288);
    for (let i = 0; i < 288; i++) e[i] = EXCEPTIONAL_ENTRY;
    for (let i = 0; i < 256; i++) e[i] = (<u32>i << 16) | LITERAL_ENTRY | (1 << 8);
    for (let i = 257; i < 286; i++) e[i] = (<u32>LEN_BASE[i - 257] << 16) | (<u32>LEN_EXTRA[i - 257] << 8);
    return e;
}

// DISTANCE_TABLE_ENTRIES (symbols 30 and 31 are 0: invalid).
function makeDistEntries(): StaticArray<u32> {
    const e = new StaticArray<u32>(32);
    for (let i = 0; i < 30; i++) e[i] = (<u32>DIST_BASE[i] << 16) | (<u32>DIST_EXTRA[i] << 8) | LITERAL_ENTRY;
    return e;
}

const LITLEN_TABLE_ENTRIES: StaticArray<u32> = makeLitlenEntries();
const DISTANCE_TABLE_ENTRIES: StaticArray<u32> = makeDistEntries();
const NO_ENTRIES: StaticArray<u32> = new StaticArray<u32>(0);

// The precomputed literal/length table of the fixed Huffman code.
const FIXED_LITLEN_TABLE: StaticArray<u32> = [
    16391, 5275912, 1081608, 7537672, 2032135, 7373064, 3178760, 12615945, 655367, 6324488, 2130184, 10518793,
    33032, 8421640, 4227336, 14713097, 393223, 5800200, 1605896, 9470217, 3867399, 7897352, 3703048, 13664521,
    1114375, 6848776, 2654472, 11567369, 557320, 8945928, 4751624, 15761673, 262151, 5538056, 1343752, 14877960,
    2818823, 7635208, 3440904, 13140233, 852231, 6586632, 2392328, 11043081, 295176, 8683784, 4489480, 15237385,
    524295, 6062344, 1868040, 9994505, 5440519, 8159496, 3965192, 14188809, 1507847, 7110920, 2916616, 12091657,
    819464, 9208072, 5013768, 16285961, 196615, 5406984, 1212680, 10683656, 2294535, 7504136, 3309832, 12878089,
    721159, 6455560, 2261256, 10780937, 164104, 8552712, 4358408, 14975241, 458759, 5931272, 1736968, 9732361,
    4391943, 8028424, 3834120, 13926665, 1245703, 6979848, 2785544, 11829513, 688392, 9077000, 4882696, 16023817,
    327687, 5669128, 1474824, 16392, 3343111, 7766280, 3571976, 13402377, 983303, 6717704, 2523400, 11305225,
    426248, 8814856, 4620552, 15499529, 589831, 6193416, 1999112, 10256649, 6489095, 8290568, 4096264, 14450953,
    1769991, 7241992, 3047688, 12353801, 950536, 9339144, 5144840, 16548105, 16391, 5341448, 1147144, 8586504,
    2032135, 7438600, 3244296, 12747017, 655367, 6390024, 2195720, 10649865, 98568, 8487176, 4292872, 14844169,
    393223, 5865736, 1671432, 9601289, 3867399, 7962888, 3768584, 13795593, 1114375, 6914312, 2720008, 11698441,
    622856, 9011464, 4817160, 15892745, 262151, 5603592, 1409288, 16908296, 2818823, 7700744, 3506440, 13271305,
    852231, 6652168, 2457864, 11174153, 360712, 8749320, 4555016, 15368457, 524295, 6127880, 1933576, 10125577,
    5440519, 8225032, 4030728, 14319881, 1507847, 7176456, 2982152, 12222729, 885000, 9273608, 5079304, 16417033,
    196615, 5472520, 1278216, 12780808, 2294535, 7569672, 3375368, 13009161, 721159, 6521096, 2326792, 10912009,
    229640, 8618248, 4423944, 15106313, 458759, 5996808, 1802504, 9863433, 4391943, 8093960, 3899656, 14057737,
    1245703, 7045384, 2851080, 11960585, 753928, 9142536, 4948232, 16154889, 327687, 5734664, 1540360, 16392,
    3343111, 7831816, 3637512, 13533449, 983303, 6783240, 2588936, 11436297, 491784, 8880392, 4686088, 15630601,
    589831, 6258952, 2064648, 10387721, 6489095, 8356104, 4161800, 14582025, 1769991, 7307528, 3113224, 12484873,
    1016072, 9404680, 5210376, 16679177, 16391, 5275912, 1081608, 7537672, 2032135, 7373064, 3178760, 12681481,
    655367, 6324488, 2130184, 10584329, 33032, 8421640, 4227336, 14778633, 393223, 5800200, 1605896, 9535753,
    3867399, 7897352, 3703048, 13730057, 1114375, 6848776, 2654472, 11632905, 557320, 8945928, 4751624, 15827209,
    262151, 5538056, 1343752, 14877960, 2818823, 7635208, 3440904, 13205769, 852231, 6586632, 2392328, 11108617,
    295176, 8683784, 4489480, 15302921, 524295, 6062344, 1868040, 10060041, 5440519, 8159496, 3965192, 14254345,
    1507847, 7110920, 2916616, 12157193, 819464, 9208072, 5013768, 16351497, 196615, 5406984, 1212680, 10683656,
    2294535, 7504136, 3309832, 12943625, 721159, 6455560, 2261256, 10846473, 164104, 8552712, 4358408, 15040777,
    458759, 5931272, 1736968, 9797897, 4391943, 8028424, 3834120, 13992201, 1245703, 6979848, 2785544, 11895049,
    688392, 9077000, 4882696, 16089353, 327687, 5669128, 1474824, 16392, 3343111, 7766280, 3571976, 13467913,
    983303, 6717704, 2523400, 11370761, 426248, 8814856, 4620552, 15565065, 589831, 6193416, 1999112, 10322185,
    6489095, 8290568, 4096264, 14516489, 1769991, 7241992, 3047688, 12419337, 950536, 9339144, 5144840, 16613641,
    16391, 5341448, 1147144, 8586504, 2032135, 7438600, 3244296, 12812553, 655367, 6390024, 2195720, 10715401,
    98568, 8487176, 4292872, 14909705, 393223, 5865736, 1671432, 9666825, 3867399, 7962888, 3768584, 13861129,
    1114375, 6914312, 2720008, 11763977, 622856, 9011464, 4817160, 15958281, 262151, 5603592, 1409288, 16908296,
    2818823, 7700744, 3506440, 13336841, 852231, 6652168, 2457864, 11239689, 360712, 8749320, 4555016, 15433993,
    524295, 6127880, 1933576, 10191113, 5440519, 8225032, 4030728, 14385417, 1507847, 7176456, 2982152, 12288265,
    885000, 9273608, 5079304, 16482569, 196615, 5472520, 1278216, 12780808, 2294535, 7569672, 3375368, 13074697,
    721159, 6521096, 2326792, 10977545, 229640, 8618248, 4423944, 15171849, 458759, 5996808, 1802504, 9928969,
    4391943, 8093960, 3899656, 14123273, 1245703, 7045384, 2851080, 12026121, 753928, 9142536, 4948232, 16220425,
    327687, 5734664, 1540360, 16392, 3343111, 7831816, 3637512, 13598985, 983303, 6783240, 2588936, 11501833,
    491784, 8880392, 4686088, 15696137, 589831, 6258952, 2064648, 10453257, 6489095, 8356104, 4161800, 14647561,
    1769991, 7307528, 3113224, 12550409, 1016072, 9404680, 5210376, 16744713,
];
// The precomputed distance table of the fixed Huffman code.
const FIXED_DIST_TABLE: StaticArray<u32> = [
    98309, 16877317, 1147653, 268536581, 360709, 67209477, 4293893, 1073843461, 229381, 33654789, 2196485, 536972293,
    623109, 134318597, 8488453, 5, 163845, 25265925, 1671941, 402754309, 491781, 100763909, 6391045, 1610714373,
    294917, 50432005, 3245061, 805407749, 885253, 201427461, 12682757, 5,
];

// A growable u16 array with the operations `buildTable` uses.
class U16Vec {
    data: Uint16Array = new Uint16Array(64);
    len: i32 = 0;

    clear(): void {
        this.len = 0;
    }

    private grow(n: i32): void {
        if (n <= this.data.length) return;
        let cap = this.data.length;
        while (cap < n) cap *= 2;
        const d = new Uint16Array(cap);
        d.set(this.data.subarray(0, this.len), 0);
        this.data = d;
    }

    // `resize(n, 0)`.
    resize(n: i32): void {
        this.grow(n);
        for (let i = this.len; i < n; i++) this.data[i] = 0;
        this.len = n;
    }

    // `extend_from_within(start..)`.
    extendFromWithin(start: i32): void {
        const n = this.len - start;
        this.grow(this.len + n);
        this.data.copyWithin(this.len, start, start + n);
        this.len += n;
    }

    get(i: i32): u32 {
        if (i >= this.len) panic("index out of bounds in fdeflate secondary table");
        return <u32>this.data[i];
    }
}

// The next codeword in bit-reversed order (codes are stored LSB first).
function nextCodeword(codeword: u32, tableSize: u32): u32 {
    if (codeword == tableSize - 1) return codeword;
    const lz16 = <u32>clz<u32>((codeword ^ (tableSize - 1)) & 0xffff) - 16;
    const adv = 15 - lz16;
    const bit: u32 = 1 << adv;
    return (codeword & (bit - 1)) | bit;
}

// Builds the decoding tables over lengths[off..off+n]. False when the
// lengths do not form a complete code (a distance code may also be empty or a
// single one-bit code).
function buildTable(
    lengths: Uint8Array, off: i32, n: i32, entries: StaticArray<u32>, codes: Uint16Array,
    primary: Uint32Array, primaryBits: i32, secondary: U16Vec, isDistance: bool, doubleLiteral: bool,
): bool {
    const histogram = new Int32Array(16);
    for (let s = 0; s < n; s++) histogram[lengths[off + s]] += 1;
    let maxLength = 15;
    while (maxLength > 1 && histogram[maxLength] == 0) maxLength--;
    if (isDistance) {
        if (maxLength == 0) {
            primary.fill(0);
            secondary.clear();
            return true;
        } else if (maxLength == 1 && histogram[1] == 1) {
            let symbol = 0;
            while (lengths[off + symbol] != 1) symbol++;
            codes[symbol] = 0;
            const entry = (symbol < entries.length ? entries[symbol] : <u32>symbol << 16) | 1;
            for (let k = 0; k + 1 < primary.length; k += 2) {
                primary[k] = entry;
                primary[k + 1] = 0;
            }
            return true;
        }
    }
    const offsets = new Int32Array(16);
    let codespaceUsed = 0;
    offsets[1] = histogram[0];
    for (let i = 1; i < maxLength; i++) {
        offsets[i + 1] = offsets[i] + histogram[i];
        codespaceUsed = (codespaceUsed << 1) + histogram[i];
    }
    codespaceUsed = (codespaceUsed << 1) + histogram[maxLength];
    if (codespaceUsed != (1 << maxLength)) return false;

    const nextIndex = new Int32Array(16);
    for (let i = 0; i < 16; i++) nextIndex[i] = offsets[i];
    const sorted = new Int32Array(288);
    for (let s = 0; s < n; s++) {
        const l = <i32>lengths[off + s];
        sorted[nextIndex[l]] = s;
        nextIndex[l] += 1;
    }

    let codeword: u32 = 0;
    let i = histogram[0];
    const primaryMask: u32 = (1 << primaryBits) - 1;
    for (let length = 1; length <= primaryBits; length++) {
        const tableEnd = 1 << length;
        for (let k = 0; k < histogram[length]; k++) {
            const symbol = sorted[i];
            i++;
            primary[<i32>codeword] = (symbol < entries.length ? entries[symbol] : <u32>symbol << 16) | <u32>length;
            codes[symbol] = <u16>codeword;
            codeword = nextCodeword(codeword, <u32>tableEnd);
        }
        if (doubleLiteral) {
            for (let len1 = 1; len1 < length - 1; len1++) {
                const len2 = length - len1;
                for (let s1 = offsets[len1]; s1 < nextIndex[len1]; s1++) {
                    for (let s2 = offsets[len2]; s2 < nextIndex[len2]; s2++) {
                        const sym1 = sorted[s1];
                        const sym2 = sorted[s2];
                        if (sym1 < 256 && sym2 < 256) {
                            const cw = (<u32>codes[sym1] | (<u32>codes[sym2] << <u32>len1)) & 0xffff;
                            const entry = (<u32>sym1 << 16) | (<u32>sym2 << 24) | LITERAL_ENTRY | (2 << 8);
                            primary[<i32>cw] = entry | <u32>length;
                        }
                    }
                }
            }
        }
        if (length < primaryBits) primary.copyWithin(tableEnd, 0, tableEnd);
    }

    secondary.clear();
    if (maxLength > primaryBits) {
        let subStart = 0;
        let subPrefix: u32 = 0xffff;
        for (let length = primaryBits + 1; length <= maxLength; length++) {
            const subSize = 1 << (length - primaryBits);
            for (let k = 0; k < histogram[length]; k++) {
                if ((codeword & primaryMask) != subPrefix) {
                    subPrefix = codeword & primaryMask;
                    subStart = secondary.len;
                    primary[<i32>subPrefix] = (<u32>subStart << 16) | EXCEPTIONAL_ENTRY | SECONDARY_TABLE_ENTRY | <u32>(subSize - 1);
                    secondary.resize(subStart + subSize);
                }
                const symbol = sorted[i];
                i++;
                codes[symbol] = <u16>codeword;
                secondary.data[subStart + <i32>(codeword >> <u32>primaryBits)] = <u16>((symbol << 4) | length);
                codeword = nextCodeword(codeword, <u32>(1 << length));
            }
            if (length < maxLength && (codeword & primaryMask) == subPrefix) {
                secondary.extendFromWithin(subStart);
                const size = secondary.len - subStart;
                primary[<i32>subPrefix] = (<u32>subStart << 16) | EXCEPTIONAL_ENTRY | SECONDARY_TABLE_ENTRY | <u32>(size - 1);
            }
        }
    }
    return true;
}

// 8 little-endian bytes of b at pos (the caller checks pos + 8 <= length).
unsafe function loadLe64(b: Uint8Array, pos: i32): u64 {
    return load<u64>(b.dataStart + <usize>pos);
}

// LZ77 copy of `n` bytes from `dist` back to out[at..]: the bytes a forward
// byte-by-byte copy gives (a run for dist 1, a memmove when the ranges do not
// overlap). The caller keeps at - dist >= 0 and at + n <= out.length.
function copyBackref(out: Uint8Array, at: i32, dist: i32, n: i32): void {
    if (n <= 0) return;
    if (dist == 1) {
        out.fill(out[at - 1], at, at + n);
    } else if (dist >= n) {
        out.copyWithin(at, at - dist, at - dist + n);
    } else {
        for (let k = 0; k < n; k++) unchecked(out[at + k] = unchecked(out[at + k - dist]));
    }
}

// The inflate state machine (read with end_of_input set, as png does). `err`
// holds the error name after a failed `read`.
class Inflate {
    litlenTable: Uint32Array = new Uint32Array(4096);
    secondaryTable: U16Vec = new U16Vec();
    distTable: Uint32Array = new Uint32Array(512);
    distSecondaryTable: U16Vec = new U16Vec();
    eofCode: u32 = 0;
    eofMask: u32 = 0;
    eofBits: i32 = 0;

    hlit: i32 = 0;
    hdist: i32 = 0;
    hclen: i32 = 0;
    numLengthsRead: i32 = 0;
    headerTable: Uint32Array = new Uint32Array(128);
    codeLengths: Uint8Array = new Uint8Array(320);

    uncompressedBytesLeft: i32 = 0;
    buffer: u64 = 0;
    nbits: i32 = 0;

    hasQueuedRle: bool = false;
    queuedRleByte: u8 = 0;
    queuedRleLen: i32 = 0;
    hasQueuedBackref: bool = false;
    queuedDist: i32 = 0;
    queuedLen: i32 = 0;

    lastBlock: bool = false;
    fixedTable: bool = false;
    state: FdState = FdState.ZlibHeader;

    // The input of the current `read`: inp[inPos..inEnd].
    inp: Uint8Array = new Uint8Array(0);
    inPos: i32 = 0;
    inEnd: i32 = 0;

    err: string = "";
    consumed: i32 = 0;
    produced: i32 = 0;

    // Milestone 67b: back to a new decompressor's state for the next
    // stream (the tables are left as they are: every block writes its own
    // before it reads them, see the header).
    reset(): void {
        this.secondaryTable.clear();
        this.distSecondaryTable.clear();
        this.eofCode = 0;
        this.eofMask = 0;
        this.eofBits = 0;
        this.hlit = 0;
        this.hdist = 0;
        this.hclen = 0;
        this.numLengthsRead = 0;
        this.uncompressedBytesLeft = 0;
        this.buffer = 0;
        this.nbits = 0;
        this.hasQueuedRle = false;
        this.queuedRleByte = 0;
        this.queuedRleLen = 0;
        this.hasQueuedBackref = false;
        this.queuedDist = 0;
        this.queuedLen = 0;
        this.lastBlock = false;
        this.fixedTable = false;
        this.state = FdState.ZlibHeader;
        this.inp = NO_INPUT;
        this.inPos = 0;
        this.inEnd = 0;
        this.err = "";
        this.consumed = 0;
        this.produced = 0;
    }

    isDone(): bool {
        return this.state == FdState.Done;
    }

    private fillBuffer(): void {
        const rem = this.inEnd - this.inPos;
        if (rem >= 8) {
            // The next 8 input bytes as a little-endian u64; wasm loads are little-endian.
            const v = loadLe64(this.inp, this.inPos);
            this.buffer |= v << <u64>this.nbits;
            this.inPos += (63 - this.nbits) >> 3;
            this.nbits |= 56;
        } else {
            const nbytes = min<i32>(rem, (63 - this.nbits) >> 3);
            let v: u64 = 0;
            for (let k = nbytes - 1; k >= 0; k--) v = (v << 8) | <u64>this.inp[this.inPos + k];
            this.buffer |= v << <u64>this.nbits;
            this.nbits += nbytes * 8;
            this.inPos += nbytes;
        }
    }

    private peakBits(n: i32): u64 {
        return this.buffer & ((<u64>1 << <u64>n) - 1);
    }

    private consumeBits(n: i32): void {
        this.buffer >>= <u64>n;
        this.nbits -= n;
    }

    private fail(name: string): bool {
        this.err = name;
        return false;
    }

    private afterBlock(): FdState {
        return this.lastBlock ? FdState.Checksum : FdState.BlockHeader;
    }

    private readBlockHeader(): bool {
        while (true) {
            this.fillBuffer();
            if (this.nbits < 10) return true;
            const start = <u32>this.peakBits(3);
            this.lastBlock = (start & 1) != 0;
            const type = start >> 1;
            if (type == 0) {
                const alignBits = (this.nbits - 3) % 8;
                const headerBits = 3 + 32 + alignBits;
                if (this.nbits < headerBits) return true;
                const len = <u32>(this.peakBits(alignBits + 19) >> <u64>(alignBits + 3)) & 0xffff;
                const nlen = <u32>(this.peakBits(headerBits) >> <u64>(alignBits + 19)) & 0xffff;
                if (nlen != (~len & 0xffff)) return this.fail("InvalidUncompressedBlockLength");
                this.state = FdState.UncompressedData;
                this.uncompressedBytesLeft = <i32>len;
                this.consumeBits(headerBits);
                return true;
            } else if (type == 1) {
                this.consumeBits(3);
                // An empty fixed block (its end-of-block code is 7 zero bits).
                if (this.peakBits(7) == 0) {
                    this.consumeBits(7);
                    if (this.lastBlock) {
                        this.state = FdState.Checksum;
                        return true;
                    }
                    while (this.nbits >= 10 && this.peakBits(10) == 0b010) {
                        this.consumeBits(10);
                        this.fillBuffer();
                    }
                    continue; // Read the next block header.
                }
                if (!this.fixedTable) {
                    this.fixedTable = true;
                    for (let k = 0; k < 4096; k += 512) {
                        for (let j = 0; j < 512; j++) this.litlenTable[k + j] = FIXED_LITLEN_TABLE[j];
                    }
                    for (let k = 0; k < 512; k += 32) {
                        for (let j = 0; j < 32; j++) this.distTable[k + j] = FIXED_DIST_TABLE[j];
                    }
                    this.eofBits = 7;
                    this.eofCode = 0;
                    this.eofMask = 0x7f;
                }
                this.state = FdState.CompressedData;
                return true;
            } else if (type == 2) {
                if (this.nbits < 17) return true;
                this.hlit = <i32>(this.peakBits(8) >> 3) + 257;
                this.hdist = <i32>(this.peakBits(13) >> 8) + 1;
                this.hclen = <i32>(this.peakBits(17) >> 13) + 4;
                if (this.hlit > 286) return this.fail("InvalidHlit");
                if (this.hdist > 30) return this.fail("InvalidHdist");
                this.consumeBits(17);
                this.state = FdState.CodeLengthCodes;
                this.fixedTable = false;
                return true;
            } else {
                return this.fail("InvalidBlockType");
            }
        }
        return true;
    }

    private readCodeLengthCodes(): bool {
        this.fillBuffer();
        if (this.nbits + (this.inEnd - this.inPos) * 8 < 3 * this.hclen) return true;
        const cll = new Uint8Array(19);
        for (let i = 0; i < this.hclen; i++) {
            cll[CLCL_ORDER[i]] = <u8>this.peakBits(3);
            this.consumeBits(3);
            if (i == 17) this.fillBuffer();
        }
        const codes = new Uint16Array(19);
        if (!buildTable(cll, 0, 19, NO_ENTRIES, codes, this.headerTable, 7, new U16Vec(), false, false)) {
            return this.fail("BadCodeLengthHuffmanTree");
        }
        this.state = FdState.CodeLengths;
        this.numLengthsRead = 0;
        return true;
    }

    private readCodeLengths(): bool {
        const total = this.hlit + this.hdist;
        const cl = this.codeLengths;
        while (this.numLengthsRead < total) {
            this.fillBuffer();
            if (this.nbits < 7) return true;
            const entry = this.headerTable[<i32>this.peakBits(7)];
            const length = <i32>(entry & 7);
            const symbol = <i32>((entry >> 16) & 0xff);
            if (symbol <= 15) {
                cl[this.numLengthsRead] = <u8>symbol;
                this.numLengthsRead++;
                this.consumeBits(length);
            } else {
                const baseRepeat = symbol == 18 ? 11 : 3;
                const extraBits = symbol == 16 ? 2 : (symbol == 17 ? 3 : 7);
                if (this.nbits < length + extraBits) return true;
                let value: u8 = 0;
                if (symbol == 16) {
                    if (this.numLengthsRead == 0) return this.fail("InvalidCodeLengthRepeat");
                    value = cl[this.numLengthsRead - 1];
                }
                const repeat = <i32>(this.peakBits(length + extraBits) >> <u64>length) + baseRepeat;
                if (this.numLengthsRead + repeat > total) return this.fail("InvalidCodeLengthRepeat");
                for (let k = 0; k < repeat; k++) cl[this.numLengthsRead + k] = value;
                this.numLengthsRead += repeat;
                this.consumeBits(length + extraBits);
            }
        }
        cl.copyWithin(288, this.hlit, total);
        for (let k = this.hlit; k < 288; k++) cl[k] = 0;
        for (let k = 288 + this.hdist; k < 320; k++) cl[k] = 0;
        if (!this.buildTables()) return false;
        this.state = FdState.CompressedData;
        return true;
    }

    private buildTables(): bool {
        const cl = this.codeLengths;
        if (cl[256] == 0) return this.fail("BadLiteralLengthHuffmanTree");
        const codes = new Uint16Array(288);
        this.secondaryTable.clear();
        if (!buildTable(cl, 0, this.hlit, LITLEN_TABLE_ENTRIES, codes, this.litlenTable, 12, this.secondaryTable, false, true)) {
            return this.fail("BadCodeLengthHuffmanTree");
        }
        this.eofCode = <u32>codes[256];
        this.eofMask = (<u32>1 << <u32>cl[256]) - 1;
        this.eofBits = <i32>cl[256];
        let allZero = true;
        for (let k = 288; k < 320; k++) if (cl[k] != 0) allZero = false;
        if (allZero) {
            this.distTable.fill(0);
        } else {
            const distCodes = new Uint16Array(32);
            if (!buildTable(cl, 288, 32, DISTANCE_TABLE_ENTRIES, distCodes, this.distTable, 9, this.distSecondaryTable, true, false)) {
                return this.fail("BadDistanceHuffmanTree");
            }
        }
        return true;
    }

    // The careful decoding loop of `read_compressed`; the new output index, or
    // -1 on an error.
    private readCompressed(out: Uint8Array, base: i32, outLen: i32, oi0: i32): i32 {
        let oi = oi0;
        while (this.state == FdState.CompressedData) {
            this.fillBuffer();
            if (oi == outLen) break;
            let bits = this.buffer;
            const litlenEntry = this.litlenTable[<i32>(bits & 0xfff)];
            const entryBits = <i32>(litlenEntry & 0xff);
            if ((litlenEntry & LITERAL_ENTRY) != 0) {
                const advance = <i32>((litlenEntry & 0xf00) >> 8);
                if (this.nbits < entryBits) {
                    break;
                } else if (oi + 1 < outLen) {
                    out[base + oi] = <u8>(litlenEntry >> 16);
                    out[base + oi + 1] = <u8>(litlenEntry >> 24);
                    oi += advance;
                    this.consumeBits(entryBits);
                    continue;
                } else if (oi + advance == outLen) {
                    out[base + oi] = <u8>(litlenEntry >> 16);
                    oi += 1;
                    this.consumeBits(entryBits);
                    break;
                } else {
                    out[base + oi] = <u8>(litlenEntry >> 16);
                    this.hasQueuedRle = true;
                    this.queuedRleByte = <u8>(litlenEntry >> 24);
                    this.queuedRleLen = 1;
                    oi += 1;
                    this.consumeBits(entryBits);
                    break;
                }
            }
            let lengthBase = 0;
            let lengthExtraBits = 0;
            let litlenCodeBits = 0;
            if ((litlenEntry & EXCEPTIONAL_ENTRY) == 0) {
                lengthBase = <i32>(litlenEntry >> 16);
                lengthExtraBits = <i32>((litlenEntry >> 8) & 0xff);
                litlenCodeBits = entryBits;
            } else if ((litlenEntry & SECONDARY_TABLE_ENTRY) != 0) {
                const se = this.secondaryTable.get(<i32>((litlenEntry >> 16) + (<u32>(bits >> 12) & (litlenEntry & 0xff))));
                const symbol = <i32>(se >> 4);
                const codeBits = <i32>(se & 0xf);
                if (this.nbits < codeBits) {
                    break;
                } else if (symbol < 256) {
                    this.consumeBits(codeBits);
                    out[base + oi] = <u8>symbol;
                    oi += 1;
                    continue;
                } else if (symbol == 256) {
                    this.consumeBits(codeBits);
                    this.state = this.afterBlock();
                    break;
                }
                lengthBase = <i32>LEN_BASE[symbol - 257];
                lengthExtraBits = <i32>LEN_EXTRA[symbol - 257];
                litlenCodeBits = codeBits;
            } else if (entryBits == 0) {
                this.err = "InvalidLiteralLengthCode";
                return -1;
            } else {
                if (this.nbits < entryBits) break;
                this.consumeBits(entryBits);
                this.state = this.afterBlock();
                break;
            }
            bits >>= <u64>litlenCodeBits;
            const length = lengthBase + <i32>(bits & ((<u64>1 << <u64>lengthExtraBits) - 1));
            bits >>= <u64>lengthExtraBits;

            const distEntry = this.distTable[<i32>(bits & 0x1ff)];
            let distBase = 0;
            let distExtraBits = 0;
            let distCodeBits = 0;
            if ((distEntry & LITERAL_ENTRY) != 0) {
                distBase = <i32>((distEntry >> 16) & 0xffff);
                distExtraBits = <i32>((distEntry >> 8) & 0xf);
                distCodeBits = <i32>(distEntry & 0xff);
            } else if (this.nbits > litlenCodeBits + lengthExtraBits + 9) {
                if ((distEntry >> 8) == 0) {
                    this.err = "InvalidDistanceCode";
                    return -1;
                }
                const se = this.distSecondaryTable.get(<i32>((distEntry >> 16) + (<u32>(bits >> 9) & (distEntry & 0xff))));
                const distSymbol = <i32>(se >> 4);
                if (distSymbol >= 30) {
                    this.err = "InvalidDistanceCode";
                    return -1;
                }
                distBase = <i32>DIST_BASE[distSymbol];
                distExtraBits = <i32>DIST_EXTRA[distSymbol];
                distCodeBits = <i32>(se & 0xf);
            } else {
                break;
            }
            bits >>= <u64>distCodeBits;
            const dist = distBase + <i32>(bits & ((<u64>1 << <u64>distExtraBits) - 1));
            const totalBits = litlenCodeBits + lengthExtraBits + distCodeBits + distExtraBits;
            if (this.nbits < totalBits) {
                break;
            } else if (dist > oi) {
                this.err = "DistanceTooFarBack";
                return -1;
            }
            this.consumeBits(totalBits);

            // Byte-by-byte forward copy: the bytes fdeflate's chunked copies
            // leave in [oi, oi + copyLength).
            const copyLength = min<i32>(length, outLen - oi);
            copyBackref(out, base + oi, dist, copyLength);
            if (copyLength < length) {
                if (dist == 1) {
                    this.hasQueuedRle = true;
                    this.queuedRleByte = out[base + oi - 1];
                    this.queuedRleLen = length - copyLength;
                } else {
                    this.hasQueuedBackref = true;
                    this.queuedDist = dist;
                    this.queuedLen = length - copyLength;
                }
                oi = outLen;
                break;
            }
            oi += copyLength;
        }

        if (this.state == FdState.CompressedData && !this.hasQueuedBackref && !this.hasQueuedRle
            && this.nbits >= 15 && ((<u32>this.peakBits(15) & this.eofMask) == this.eofCode)) {
            this.consumeBits(this.eofBits);
            this.state = this.afterBlock();
        }
        return oi;
    }

    // Inflates `inp[inStart..inEnd]` into `out[base..end]` from `outPos`:
    // false on an error (see `err`); otherwise `consumed` input bytes and
    // `produced` output bytes.
    read(inp: Uint8Array, inStart: i32, inEnd: i32, out: Uint8Array, base: i32, end: i32, outPos: i32, endOfInput: bool): bool {
        this.inp = inp;
        this.inPos = inStart;
        this.inEnd = inEnd;
        this.consumed = 0;
        this.produced = 0;
        if (this.state == FdState.Done) return true;
        const outLen = end - base;
        let oi = outPos;

        if (this.hasQueuedRle) {
            this.hasQueuedRle = false;
            const len = this.queuedRleLen;
            const n = min<i32>(len, outLen - oi);
            out.fill(this.queuedRleByte, base + oi, base + oi + n);
            oi += n;
            if (n < len) {
                this.hasQueuedRle = true;
                this.queuedRleLen = len - n;
                this.produced = n;
                return true;
            }
        }
        if (this.hasQueuedBackref) {
            this.hasQueuedBackref = false;
            const dist = this.queuedDist;
            const len = this.queuedLen;
            const n = min<i32>(len, outLen - oi);
            copyBackref(out, base + oi, dist, n);
            oi += n;
            if (n < len) {
                this.hasQueuedBackref = true;
                this.queuedLen = len - n;
                this.produced = n;
                return true;
            }
        }

        let lastState: i32 = -1;
        while (lastState != <i32>this.state) {
            lastState = <i32>this.state;
            const st = this.state;
            if (st == FdState.ZlibHeader) {
                this.fillBuffer();
                if (this.nbits < 16) break;
                const input0 = <u32>this.peakBits(8);
                const input1 = <u32>(this.peakBits(16) >> 8) & 0xff;
                if ((input0 & 0x0f) != 0x08 || (input0 & 0xf0) > 0x70 || (input1 & 0x20) != 0 || ((input0 << 8) | input1) % 31 != 0) {
                    return this.fail("BadZlibHeader");
                }
                this.consumeBits(16);
                this.state = FdState.BlockHeader;
            } else if (st == FdState.BlockHeader) {
                if (!this.readBlockHeader()) return false;
            } else if (st == FdState.CodeLengthCodes) {
                if (!this.readCodeLengthCodes()) return false;
            } else if (st == FdState.CodeLengths) {
                if (!this.readCodeLengths()) return false;
            } else if (st == FdState.CompressedData) {
                oi = this.readCompressed(out, base, outLen, oi);
                if (oi < 0) return false;
            } else if (st == FdState.UncompressedData) {
                while (this.nbits > 0 && this.uncompressedBytesLeft > 0 && oi < outLen) {
                    out[base + oi] = <u8>this.peakBits(8);
                    this.consumeBits(8);
                    oi++;
                    this.uncompressedBytesLeft--;
                }
                if (this.nbits == 0) this.buffer = 0;
                const copy = min<i32>(min<i32>(this.uncompressedBytesLeft, this.inEnd - this.inPos), outLen - oi);
                for (let k = 0; k < copy; k++) out[base + oi + k] = this.inp[this.inPos + k];
                this.inPos += copy;
                oi += copy;
                this.uncompressedBytesLeft -= copy;
                if (this.uncompressedBytesLeft == 0) this.state = this.afterBlock();
            } else if (st == FdState.Checksum) {
                this.fillBuffer();
                const alignBits = this.nbits % 8;
                if (this.nbits >= 32 + alignBits) {
                    if (alignBits != 0) this.consumeBits(alignBits);
                    this.state = FdState.Done;
                    this.consumeBits(32);
                    break;
                }
            } else {
                break;
            }
        }

        if (this.state == FdState.Done || !endOfInput || oi == outLen) {
            this.consumed = this.inPos - inStart;
            this.produced = oi - outPos;
            return true;
        }
        return this.fail("InsufficientInput");
    }
}

// A whole zlib stream inflated into `size` bytes, its length known
// beforehand (Hedra's engine bundle: compiler/tools/gen_engine_bundle.sh).
// The output is one buffer, which is also the decoder's window, so the
// stream inflates in place with no copy. An error names the decoder's
// (fdeflate's) error, a stream that ends early or that holds more than
// `size` bytes. The Adler-32 is not checked, as png does not.
// Milestone 67b: the inflater is a pooled one (takeInflate), and `into`,
// when given, is the output (exactly `size` bytes: a KTX2 level's own
// buffer, or scratch), so that nothing else is allocated.
export function zlibDecompress(data: Uint8Array, size: i32, into: Uint8Array? = null): Result<Uint8Array> {
    const given = into;
    const out = given != null && given.length == size ? given : new Uint8Array(size);
    const z = takeInflate();
    const r = inflateWhole(z, data, out, size);
    giveInflate(z);
    return r;
}

function inflateWhole(z: Inflate, data: Uint8Array, out: Uint8Array, size: i32): Result<Uint8Array> {
    let inPos = 0;
    let outPos = 0;
    while (!z.isDone()) {
        if (!z.read(data, inPos, data.length, out, 0, size, outPos, true)) return Result.fail<Uint8Array>(z.err);
        inPos += z.consumed;
        outPos += z.produced;
        if (z.consumed == 0 && z.produced == 0 && !z.isDone()) {
            return Result.fail<Uint8Array>(outPos == size ? "the stream holds more than " + size.toString() + " bytes"
                : "InsufficientInput");
        }
    }
    if (outPos != size) {
        return Result.fail<Uint8Array>("the stream holds " + outPos.toString() + " bytes, not " + size.toString());
    }
    return Result.okv<Uint8Array>(out);
}

// Milestone 67b: the free inflaters (see the header): one serves a whole
// load, decoding one stream at a time; a few are kept for decoders that
// nest (none today).
const NO_INPUT: Uint8Array = new Uint8Array(0);
const INFLATERS_KEPT: i32 = 4;
const freeInflaters: Array<Inflate> = [];
// How many inflaters were made and how many streams a free one served
// (tests, the load bench).
let inflatersMade: i64 = 0;
let inflatersReused: i64 = 0;

function takeInflate(): Inflate {
    if (freeInflaters.length > 0) {
        inflatersReused++;
        return freeInflaters.pop();
    }
    inflatersMade++;
    return new Inflate();
}

function giveInflate(z: Inflate): void {
    z.reset();
    if (freeInflaters.length >= INFLATERS_KEPT) return;
    for (let i = 0; i < freeInflaters.length; i++) if (unchecked(freeInflaters[i]) === z) return;
    freeInflaters.push(z);
}

// [made, reused] (tests, the load bench).
export function inflaterCounts(): StaticArray<i64> {
    const c = new StaticArray<i64>(2);
    c[0] = inflatersMade;
    c[1] = inflatersReused;
    return c;
}

// The free inflaters let go, the counts back to 0 (tests).
export function resetInflaters(): void {
    freeInflaters.length = 0;
    inflatersMade = 0;
    inflatersReused = 0;
}

// ---------------------------------------------------------------------------
// Deflate: greedy LZ77 (hash chains over a 32 KiB window) coded with the
// fixed Huffman table, as one final block.

// ---------------------------------------------------------------------------
// PNG encode (8-bit RGBA).

export const SIGNATURE: StaticArray<u8> = [137, 80, 78, 71, 13, 10, 26, 10];

export function paeth(a: i32, b: i32, c: i32): i32 {
    const p = a + b - c;
    const pa = abs<i32>(p - a);
    const pb = abs<i32>(p - b);
    const pc = abs<i32>(p - c);
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// ---------------------------------------------------------------------------
// PNG decode: a streaming decoder over a buffered reader, normalized to 8-bit
// color, reading the header, then one frame.
//
// Which error a damaged file reports depends on the order the decoder does
// things in, so this fixes that order:
// - the file is read through 8 KiB buffered-reader windows;
// - the chunk state machine (StreamingDecoder) checks a chunk's CRC after its
//   data, and IDAT data is inflated while it streams in, before its CRC;
// - each inflate call gets at most one window of the chunk and 8 KiB of
//   output room (UnfilteringBuffer::GROWTH_BYTES), capped at the frame size
//   png computes (for Adam7 it counts a filter byte per row of empty passes);
// - rows are unfiltered only once they are 32 KiB behind the inflate front,
//   or the stream or frame is complete (the lookback window), so a bad filter
//   byte loses to a stream error found within that distance;
// - a chunk other than IDAT ending the data with the frame incomplete flushes
//   the inflater: "InsufficientInput" unless the stream had ended, then
//   "... does not have enough data for image.";
// - reading stops at the type of the first chunk after the image data.
// The palette is required only when the first row is converted.

const GROWTH_BYTES = 8192;
const LOOKBACK_SIZE = 32768;
const BUF_READER_CAPACITY = 8192;
const CHUNK_BUFFER_SIZE: i64 = 128;
const DEFAULT_LIMIT_BYTES: i64 = 64 * 1024 * 1024;

// The output color type after normalize_to_color8.
export enum PngColor {
    Grayscale,
    Rgb,
    GrayscaleAlpha,
    Rgba,
}

export class PngDecoded {
    width: u32 = 0;
    height: u32 = 0;
    color: PngColor = PngColor.Rgba;
    // 8-bit samples, rows top first, no padding.
    pixels: Uint8Array = new Uint8Array(0);
    // Milestone 67b: `pixels` is a scratch buffer (decodePngPooled, a PNG
    // that is not RGBA): its reader gives it back (releasePngPixels) once
    // it has widened it.
    pooled: bool = false;
}

function readU32Be(b: Uint8Array, i: i32): u32 {
    return (<u32>b[i] << 24) | (<u32>b[i + 1] << 16) | (<u32>b[i + 2] << 8) | <u32>b[i + 3];
}

function hexLower(v: u32): string {
    const digits = "0123456789abcdef";
    const parts: Array<string> = [];
    let n = v;
    do {
        parts.push(digits.charAt(<i32>(n & 15)));
        n = n >>> 4;
    } while (n != 0);
    parts.reverse();
    return parts.join("");
}

// The debug escape of a byte taken as a Latin-1 char (as error texts show
// chunk types).
function escapeDebugByte(c: u8): string {
    if (c == 0) return "\\0";
    if (c == 9) return "\\t";
    if (c == 10) return "\\n";
    if (c == 13) return "\\r";
    if (c == 0x5c) return "\\\\";
    if (c == 0x27) return "\\'";
    if (c == 0x22) return "\\\"";
    const printable = (c >= 0x20 && c <= 0x7e) || (c >= 0xa0 && c != 0xad);
    if (printable) return String.fromCharCode(c);
    return "\\u{" + hexLower(c) + "}";
}

// The debug text of a chunk type, as png's error messages print it (the
// type as a big-endian u32).
function chunkDebug(t: u32): string {
    const b0 = <u8>(t >>> 24);
    const b1 = <u8>(t >>> 16);
    const b2 = <u8>(t >>> 8);
    const b3 = <u8>t;
    const s = escapeDebugByte(b0) + escapeDebugByte(b1) + escapeDebugByte(b2) + escapeDebugByte(b3);
    const critical = (b0 & 32) == 0;
    const priv = (b1 & 32) != 0;
    const reserved = (b2 & 32) != 0;
    const safecopy = (b3 & 32) != 0;
    return `ChunkType { type: ${s}, critical: ${critical}, private: ${priv}, reserved: ${reserved}, safecopy: ${safecopy} }`;
}

// ColorType / BitDepth `{:?}` names.
function colorTypeName(c: u8): string {
    if (c == 0) return "Grayscale";
    if (c == 2) return "Rgb";
    if (c == 3) return "Indexed";
    if (c == 4) return "GrayscaleAlpha";
    return "Rgba";
}

function bitDepthName(d: u8): string {
    if (d == 1) return "One";
    if (d == 2) return "Two";
    if (d == 4) return "Four";
    if (d == 8) return "Eight";
    return "Sixteen";
}

function samplesOf(colorType: u8): i32 {
    if (colorType == 2) return 3;
    if (colorType == 4) return 2;
    if (colorType == 6) return 4;
    return 1; // gray, indexed
}

// The I/O error text a short file is reported with.
const EOF_TEXT = "unexpected end of file";

// Chunk types as big-endian u32.
const T_IHDR: u32 = 0x49484452;
const T_PLTE: u32 = 0x504c5445;
const T_IDAT: u32 = 0x49444154;
const T_IEND: u32 = 0x49454e44;
const T_FDAT: u32 = 0x66644154; // fdAT
const T_SBIT: u32 = 0x73424954; // sBIT
const T_TRNS: u32 = 0x74524e53; // tRNS
const T_PHYS: u32 = 0x70485973; // pHYs
const T_GAMA: u32 = 0x67414d41; // gAMA
const T_ACTL: u32 = 0x6163544c; // acTL
const T_FCTL: u32 = 0x6663544c; // fcTL
const T_CHRM: u32 = 0x6348524d; // cHRM
const T_SRGB: u32 = 0x73524742; // sRGB
const T_CICP: u32 = 0x63494350; // cICP
const T_MDCV: u32 = 0x6d444356; // mDCV
const T_CLLI: u32 = 0x634c4c49; // cLLI
const T_BKGD: u32 = 0x624b4744; // bKGD
const T_EXIF: u32 = 0x65584966; // eXIf
const T_ICCP: u32 = 0x69434350; // iCCP
const T_TEXT: u32 = 0x74455874; // tEXt
const T_ZTXT: u32 = 0x7a545874; // zTXt
const T_ITXT: u32 = 0x69545874; // iTXt

function isCritical(t: u32): bool {
    return ((t >>> 24) & 32) == 0;
}

// The IHDR fields plus the chunks read before the image data.
class Header {
    width: u32 = 0;
    height: u32 = 0;
    bitDepth: u8 = 0;
    colorType: u8 = 0;
    interlaced: bool = false;
    palette: Uint8Array? = null;
    trns: Uint8Array? = null;
    // fcTL before IDAT (the default image's frame): its size replaces IHDR's.
    hasFrameControl: bool = false;
    fcWidth: u32 = 0;
    fcHeight: u32 = 0;
}

// Adam7 pass origins and steps.
const A7_X0: StaticArray<i32> = [0, 4, 0, 2, 0, 1, 0];
const A7_Y0: StaticArray<i32> = [0, 0, 4, 0, 2, 0, 1];
const A7_DX: StaticArray<i32> = [8, 8, 4, 4, 2, 2, 1];
const A7_DY: StaticArray<i32> = [8, 8, 8, 4, 4, 2, 2];

// Samples (or lines) an Adam7 pass covers along one axis.
function a7Count(size: u32, offset: i32, step: i32): u32 {
    const o = <u32>offset;
    if (size <= o) return 0;
    return (size - o + <u32>step - 1) / <u32>step;
}

// Raw row length: filter byte plus packed samples.
function rawRowLength(h: Header, width: u32): u64 {
    const samples = <u64>width * <u64>samplesOf(h.colorType);
    const bd = <u64>h.bitDepth;
    if (bd == 16) return 1 + samples * 2;
    if (bd == 8) return 1 + samples;
    const perByte = 8 / bd;
    return 1 + samples / perByte + (samples % perByte > 0 ? 1 : 0);
}

// Chunk state machine states, u32 kinds, chunk actions and decode events.
const ST_U32 = 0;
const ST_READ_CHUNK_DATA = 1;
const ST_IMAGE_DATA = 2;
const ST_NONE = 3;
const U_SIGNATURE1 = 0;
const U_SIGNATURE2 = 1;
const U_LENGTH = 2;
const U_TYPE = 3;
const U_CRC = 4;
const ACTION_PROCESS = 0;
const ACTION_SKIP = 1;
const ACTION_REJECT = 2;
const EV_ERROR = -1;
const EV_NOTHING = 0;
const EV_CHUNK_BEGIN = 1;
const EV_CHUNK_COMPLETE = 2;
const EV_IMAGE_DATA = 3;
const EV_IMAGE_DATA_FLUSHED = 4;
const EV_OTHER = 5;
const PREV_NONE = 0;
const PREV_IN_PLACE = 1;
const PREV_SCRATCH = 2;

class PngReader {
    b: Uint8Array;
    n: i32;
    // Buffered-reader window [pos, end).
    pos: i32 = 0;
    end: i32 = 0;
    err: string = "";
    errIsEof: bool = false;

    // Chunk state machine.
    state: i32 = ST_U32;
    kind: i32 = U_SIGNATURE1;
    u32Bytes: Uint8Array = new Uint8Array(4);
    u32Count: i32 = 0;
    u32Taken: i32 = 0;
    pendingLength: u32 = 0;
    chunkType: u32 = 0;
    crc: u32 = 0xffffffff;
    remaining: u32 = 0;
    action: i32 = ACTION_PROCESS;
    raw: ByteBuf = new ByteBuf(128);
    rawCapacity: i64 = CHUNK_BUFFER_SIZE;
    limitBytes: i64 = DEFAULT_LIMIT_BYTES;
    hdr: Header? = null;
    haveIdat: bool = false;
    readyForIdat: bool = true;
    readyForFdat: bool = false;
    seqNo: i64 = -1;
    evType: u32 = 0;

    // ZlibStream (milestone 67b: a pooled inflater, given back by
    // `release`).
    inflate: Inflate = takeInflate();
    zStarted: bool = false;
    // Milestone 67b: whether `data` is a scratch buffer, and whether the
    // pixels of an image that is not RGBA go to one (decodePngPooled).
    dataPooled: bool = false;
    poolPixels: bool = false;

    // UnfilteringBuffer (`len` is the Vec length; `data` may be longer).
    data: Uint8Array = new Uint8Array(0);
    len: i32 = 0;
    filled: i32 = 0;
    available: i32 = 0;
    currentStart: i32 = 0;
    prevKind: i32 = PREV_NONE;
    prevStart: i32 = 0;
    scratch: Uint8Array = new Uint8Array(0);
    shiftBackLimit: i64 = 0;
    remainingBytes: i64 = 0;
    consumedAndFlushed: bool = false;

    constructor(b: Uint8Array) {
        this.b = b;
        this.n = b.length;
    }

    private fail(msg: string): i32 {
        this.err = msg;
        return EV_ERROR;
    }

    private failFormat(msg: string): bool {
        this.err = msg;
        return false;
    }

    // The next decode event: one buffered-reader window through `update`.
    decodeNext(withImage: bool): i32 {
        this.errIsEof = false;
        if (this.pos == this.end) this.end = min<i32>(this.pos + BUF_READER_CAPACITY, this.n);
        if (this.pos >= this.end) {
            this.errIsEof = true;
            return this.fail(EOF_TEXT);
        }
        if (this.state == ST_NONE) return this.fail("A fatal decoding error has been encounted earlier");
        while (this.pos < this.end) {
            const ev = this.nextState(withImage);
            if (ev != EV_NOTHING) return ev;
        }
        return EV_NOTHING;
    }

    private crcUpdateSpan(start: i32, end: i32): void {
        this.crc = crcUpdate(this.crc, this.b, start, end);
    }

    private nextState(withImage: bool): i32 {
        const st = this.state;
        if (st == ST_U32) {
            const take = min<i32>(4 - this.u32Count, this.end - this.pos);
            for (let k = 0; k < take; k++) this.u32Bytes[this.u32Count + k] = this.b[this.pos + k];
            this.pos += take;
            this.u32Count += take;
            this.u32Taken = take;
            if (this.u32Count < 4) return EV_NOTHING;
            this.u32Count = 0;
            return this.parseU32(withImage);
        }
        if (st == ST_READ_CHUNK_DATA) {
            if (this.remaining == 0) {
                this.startU32(U_CRC);
                return EV_NOTHING;
            }
            const bufAvail = this.rawCapacity - <i64>this.raw.len;
            const bytesAvail = min<i64>(<i64>(this.end - this.pos), bufAvail);
            const k = <i32>min<i64>(<i64>this.remaining, bytesAvail);
            this.crcUpdateSpan(this.pos, this.pos + k);
            if (this.action == ACTION_PROCESS) {
                if (<i64>this.raw.len == this.rawCapacity) {
                    if (this.limitBytes == 0) return this.fail("limits are exceeded");
                    const reserve = min<i64>(this.rawCapacity, this.limitBytes);
                    this.limitBytes -= reserve;
                    this.rawCapacity += reserve;
                }
                this.raw.pushBytes(this.b, this.pos, this.pos + k);
            }
            this.pos += k;
            this.remaining -= <u32>k;
            if (this.remaining == 0) this.startU32(U_CRC);
            return EV_NOTHING;
        }
        // ST_IMAGE_DATA
        const k = <i32>min<i64>(<i64>(this.end - this.pos), <i64>this.remaining);
        let consumed = k;
        if (withImage) {
            consumed = this.inflaterDecompress(this.pos, this.pos + k);
            if (consumed < 0) return EV_ERROR;
        }
        this.crcUpdateSpan(this.pos, this.pos + consumed);
        this.pos += consumed;
        this.remaining -= <u32>consumed;
        if (this.remaining == 0) this.startU32(U_CRC);
        return EV_IMAGE_DATA;
    }

    private startU32(kind: i32): void {
        this.state = ST_U32;
        this.kind = kind;
        this.u32Count = 0;
    }

    private parseU32(withImage: bool): i32 {
        const bb = this.u32Bytes;
        const val = (<u32>bb[0] << 24) | (<u32>bb[1] << 16) | (<u32>bb[2] << 8) | <u32>bb[3];
        const kind = this.kind;
        if (kind == U_SIGNATURE1) {
            if (val != 0x89504e47) return this.fail("Invalid PNG signature.");
            this.startU32(U_SIGNATURE2);
            return EV_NOTHING;
        }
        if (kind == U_SIGNATURE2) {
            if (val != 0x0d0a1a0a) return this.fail("Invalid PNG signature.");
            this.startU32(U_LENGTH);
            return EV_NOTHING;
        }
        if (kind == U_LENGTH) {
            this.pendingLength = val;
            this.startU32(U_TYPE);
            return EV_NOTHING;
        }
        if (kind == U_TYPE) {
            const t = val;
            const length = this.pendingLength;
            if (this.hdr == null && t != T_IHDR) {
                return this.fail(`${chunkDebug(t)} chunk appeared before IHDR chunk`);
            }
            if (t != this.chunkType && (this.chunkType == T_IDAT || this.chunkType == T_FDAT)) {
                let finished = true;
                if (withImage) {
                    const f = this.inflaterFinish();
                    if (f < 0) return EV_ERROR;
                    finished = f == 1;
                }
                // Rewind to before this type field.
                this.pos -= this.u32Taken;
                this.u32Count = 4 - this.u32Taken;
                this.state = ST_U32;
                this.kind = U_TYPE;
                if (finished) {
                    this.chunkType = t;
                    this.readyForIdat = false;
                    this.readyForFdat = false;
                    return EV_IMAGE_DATA_FLUSHED;
                }
                return EV_IMAGE_DATA;
            }
            this.chunkType = t;
            this.crc = crcUpdate(0xffffffff, bb, 0, 4);
            this.remaining = length;
            this.raw.len = 0;
            if (t == T_FDAT) {
                if (!this.readyForFdat) return this.fail(`Unexpected restart of ${chunkDebug(T_FDAT)} chunk sequence`);
                if (length < 4) return this.fail("fdAT chunk shorter than 4 bytes");
                // Unreachable: fcTL only allows fdAT after IDAT, where reading stops.
                return this.fail("fcTL chunk missing before fdAT chunk.");
            }
            if (t == T_IDAT) {
                if (!this.readyForIdat) return this.fail(`Unexpected restart of ${chunkDebug(T_IDAT)} chunk sequence`);
                this.haveIdat = true;
                this.action = ACTION_PROCESS;
                this.state = ST_IMAGE_DATA;
            } else if (!this.startChunk(t, length)) {
                return EV_ERROR;
            }
            this.evType = t;
            return EV_CHUNK_BEGIN;
        }
        // U_CRC
        const t = this.chunkType;
        const sum = ~this.crc;
        if (val == sum) {
            const action = this.action;
            if (action == ACTION_PROCESS) {
                if (!this.parseChunk(t)) return EV_ERROR;
                if (t != T_IEND) this.startU32(U_LENGTH);
                else this.state = ST_NONE;
                this.evType = t;
                return EV_CHUNK_COMPLETE;
            }
            this.startU32(U_LENGTH);
            return EV_OTHER;
        }
        if (!isCritical(t)) {
            this.startU32(U_LENGTH);
            return EV_OTHER;
        }
        return this.fail(`CRC error: expected 0x${hexLower(val)} have 0x${hexLower(sum)} while decoding ${chunkDebug(t)} chunk.`);
    }

    // Decides what to do with a chunk when its header is read: process it,
    // reject it (bad length, ancillary), skip it (unknown, ancillary) or fail
    // (unknown critical chunk, or a critical chunk of the wrong length).
    private startChunk(t: u32, length: u32): bool {
        let lo: u32 = 0;
        let hi: u32 = 0x7fffffff;
        if (t == T_IHDR) { lo = 13; hi = 13; }
        else if (t == T_PLTE) { lo = 3; hi = 768; }
        else if (t == T_IEND) { lo = 0; hi = 0; }
        else if (t == T_SBIT) { lo = 1; hi = 4; }
        else if (t == T_TRNS) { lo = 1; hi = 256; }
        else if (t == T_PHYS) { lo = 9; hi = 9; }
        else if (t == T_GAMA) { lo = 4; hi = 4; }
        else if (t == T_ACTL) { lo = 8; hi = 8; }
        else if (t == T_FCTL) { lo = 26; hi = 26; }
        else if (t == T_CHRM) { lo = 32; hi = 32; }
        else if (t == T_SRGB) { lo = 1; hi = 1; }
        else if (t == T_CICP) { lo = 4; hi = 4; }
        else if (t == T_MDCV) { lo = 24; hi = 24; }
        else if (t == T_CLLI) { lo = 8; hi = 8; }
        else if (t == T_BKGD) { lo = 1; hi = 6; }
        else if (t == T_EXIF || t == T_ICCP || t == T_TEXT || t == T_ZTXT || t == T_ITXT) { lo = 0; hi = 0x7fffffff; }
        else if (isCritical(t)) {
            return this.failFormat(`Unrecognized critical chunk: ${chunkDebug(t)}`);
        } else {
            this.action = ACTION_SKIP;
            this.state = ST_READ_CHUNK_DATA;
            return true;
        }
        if (length < lo || length > hi) {
            if (t == T_IHDR || t == T_PLTE || t == T_IEND || t == T_FCTL) {
                return this.failFormat(`Chunk length wrong: ${chunkDebug(t)}`);
            }
            this.action = ACTION_REJECT;
        } else {
            this.action = ACTION_PROCESS;
        }
        this.state = ST_READ_CHUNK_DATA;
        return true;
    }

    // Parses a complete chunk, for the chunks that matter here; format
    // errors in ancillary chunks (except fcTL) only drop the chunk.
    private parseChunk(t: u32): bool {
        const d = this.raw.data;
        const len = this.raw.len;
        if (t == T_IHDR) return this.parseIhdr();
        if (t == T_PLTE) {
            const h = this.hdr as Header;
            if (h.palette != null) return this.failFormat(`Chunk ${chunkDebug(T_PLTE)} must appear at most once.`);
            h.palette = d.slice(0, len);
            return true;
        }
        if (t == T_TRNS) {
            this.parseTrns();
            return true;
        }
        if (t == T_FCTL) return this.parseFctl();
        if (t == T_TEXT || t == T_ZTXT || t == T_ITXT) {
            // `limits.reserve_bytes(buf.len())?` comes first and is fatal.
            if (<i64>len > this.limitBytes) return this.failFormat("limits are exceeded");
            this.limitBytes -= <i64>len;
        }
        return true;
    }

    private parseIhdr(): bool {
        if (this.hdr != null) return this.failFormat(`Chunk ${chunkDebug(T_IHDR)} must appear at most once.`);
        const d = this.raw.data;
        const width = readU32Be(d, 0);
        const height = readU32Be(d, 4);
        if (width == 0 || height == 0) return this.failFormat("Invalid image dimensions");
        const bd = d[8];
        if (!(bd == 1 || bd == 2 || bd == 4 || bd == 8 || bd == 16)) return this.failFormat(`Invalid bit depth ${bd}.`);
        const ct = d[9];
        if (!(ct == 0 || ct == 2 || ct == 3 || ct == 4 || ct == 6)) return this.failFormat(`Invalid color type ${ct}.`);
        let invalid = false;
        if (ct == 2 || ct == 4 || ct == 6) invalid = bd != 8 && bd != 16;
        else if (ct == 3) invalid = bd == 16;
        if (invalid) {
            return this.failFormat(`Invalid color/depth combination in header: ${colorTypeName(ct)}/${bitDepthName(bd)}`);
        }
        if (d[10] != 0) return this.failFormat(`Unknown compression method ${d[10]}.`);
        if (d[11] != 0) return this.failFormat(`Unknown filter method ${d[11]}.`);
        if (d[12] > 1) return this.failFormat(`Unknown interlace method ${d[12]}.`);
        const h = new Header();
        h.width = width;
        h.height = height;
        h.bitDepth = bd;
        h.colorType = ct;
        h.interlaced = d[12] == 1;
        this.hdr = h;
        return true;
    }

    // `parse_trns`: every failure is a format error, which drops the chunk.
    private parseTrns(): void {
        const h = this.hdr as Header;
        if (h.trns != null) return;
        const v = this.raw.data.slice(0, this.raw.len);
        const len = v.length;
        if (h.colorType == 0) {
            if (len < 2) return;
            if (h.bitDepth < 16) {
                const t = new Uint8Array(1);
                t[0] = v[1];
                h.trns = t;
            } else {
                h.trns = v;
            }
        } else if (h.colorType == 2) {
            if (len < 6) return;
            if (h.bitDepth < 16) {
                const t = new Uint8Array(3);
                t[0] = v[1];
                t[1] = v[3];
                t[2] = v[5];
                h.trns = t;
            } else {
                h.trns = v;
            }
        } else if (h.colorType == 3) {
            if (h.palette == null || this.haveIdat) return;
            h.trns = v;
        }
    }

    // `parse_fctl` (its errors are fatal, unlike other ancillary chunks').
    private parseFctl(): bool {
        const d = this.raw.data;
        const h = this.hdr as Header;
        const seq = readU32Be(d, 0);
        if (this.seqNo >= 0) {
            const expected = <u32>this.seqNo + 1;
            if (seq != expected) return this.failFormat(`Sequence is not in order, expected #${expected} got #${seq}.`);
        } else if (seq != 0) {
            return this.failFormat(`Sequence is not in order, expected #0 got #${seq}.`);
        }
        this.seqNo = <i64>seq;
        this.inflate = new Inflate();
        this.zStarted = false;
        this.readyForFdat = this.haveIdat;
        const width = readU32Be(d, 4);
        const height = readU32Be(d, 8);
        const x = readU32Be(d, 12);
        const y = readU32Be(d, 16);
        const dispose = d[24];
        if (dispose > 2) return this.failFormat(`Invalid dispose op ${dispose}.`);
        const blend = d[25];
        if (blend > 1) return this.failFormat(`Invalid blend op ${blend}.`);
        if (width == 0 || height == 0) return this.failFormat("Invalid image dimensions");
        const inX = x <= h.width && width <= h.width - x;
        const inY = y <= h.height && height <= h.height - y;
        if (!inX || !inY) return this.failFormat("Sub frame is out-of-bounds.");
        if (!this.haveIdat && (x != 0 || y != 0 || width != h.width || height != h.height)) {
            return this.failFormat("Sub frame is out-of-bounds.");
        }
        h.hasFrameControl = true;
        h.fcWidth = width;
        h.fcHeight = height;
        return true;
    }

    // Inflates into the unfiltering buffer; bytes consumed, or -1.
    private inflaterDecompress(start: i32, end: i32): i32 {
        const z = this.inflate;
        if (z.isDone()) return end - start;
        const outLimit = min<i32>(this.filled + GROWTH_BYTES, this.len);
        if (!z.read(this.b, start, end, this.data, this.available, outLimit, this.filled - this.available, false)) {
            this.err = "Corrupt deflate stream. " + z.err;
            return -1;
        }
        this.filled += z.produced;
        if (z.isDone()) {
            this.available = this.filled;
        } else if (this.filled >= LOOKBACK_SIZE && this.filled - LOOKBACK_SIZE > this.available) {
            this.available = this.filled - LOOKBACK_SIZE;
        }
        this.zStarted = true;
        return z.consumed;
    }

    // Flushes the inflater: 1 finished, 0 more output possible, -1 error.
    private inflaterFinish(): i32 {
        const z = this.inflate;
        if (!this.zStarted || z.isDone()) return 1;
        if (this.filled == this.len) return 1;
        if (!z.read(this.b, 0, 0, this.data, this.available, this.len, this.filled - this.available, false)) {
            this.err = "Corrupt deflate stream. " + z.err;
            return -1;
        }
        this.filled += z.produced;
        if (z.isDone()) {
            this.available = this.filled;
            return 1;
        }
        if (this.filled == this.len) {
            this.available = max<i32>(this.available, max<i32>(this.filled - LOOKBACK_SIZE, 0));
            return 0;
        }
        this.err = "Corrupt deflate stream. InsufficientInput";
        return -1;
    }

    private setLen(n: i32): void {
        if (n > this.data.length) {
            let cap = max<i32>(this.data.length, 1024);
            while (cap < n) cap *= 2;
            // (milestone 67b: each size a scratch buffer, the smaller one
            // given back; the bytes past `len` are never read before the
            // inflater writes them)
            const d = scratchPool().take(cap);
            d.set(this.data.subarray(0, this.len), 0);
            if (this.dataPooled) scratchPool().give(this.data);
            this.data = d;
            this.dataPooled = true;
        }
        this.len = n;
    }

    // Milestone 67b: the inflater and the unfiltering window back to their
    // pools (once the decode is over, whatever its result).
    release(): void {
        giveInflate(this.inflate);
        if (this.dataPooled) scratchPool().give(this.data);
        this.dataPooled = false;
        this.data = NO_INPUT;
        this.len = 0;
    }

    // One step of image-data decoding into the unfiltering buffer (compacting
    // it first when enough of it is consumed).
    private decodeImageDataStep(): i32 {
        const discard = min<i32>(this.available, this.prevKind == PREV_IN_PLACE ? this.prevStart : this.currentStart);
        if (<i64>discard >= this.shiftBackLimit && this.filled >= this.len / 2) {
            this.data.copyWithin(0, discard, this.len - this.filled >= 16 ? this.filled : this.len);
            this.currentStart -= discard;
            this.available -= discard;
            this.filled -= discard;
            if (this.prevKind == PREV_IN_PLACE) this.prevStart -= discard;
        }
        if (this.filled + GROWTH_BYTES > this.len) this.setLen(this.filled + GROWTH_BYTES);
        if (<i64>this.filled + this.remainingBytes < <i64>this.len) this.setLen(<i32>(<i64>this.filled + this.remainingBytes));
        const oldFilled = this.filled;
        const ev = this.decodeNext(true);
        this.remainingBytes -= <i64>(this.filled - oldFilled);
        if (this.remainingBytes == 0) this.available = this.filled;
        return ev;
    }

    // The previous unfiltered row (empty for the first row of a pass).
    private prevRow(): Uint8Array {
        if (this.prevKind == PREV_IN_PLACE) return this.data.subarray(this.prevStart, this.currentStart);
        if (this.prevKind == PREV_SCRATCH) return this.scratch;
        return new Uint8Array(0);
    }

    // The next unfiltered row, or null.
    nextRawRow(rowlen: i32, bpp: i32): Uint8Array? {
        while (max<i32>(this.available - this.currentStart, 0) < rowlen) {
            if (this.consumedAndFlushed) {
                this.err = "IDAT or fDAT chunk does not have enough data for image.";
                return null;
            }
            const ev = this.decodeImageDataStep();
            if (ev == EV_ERROR) {
                if (this.errIsEof && this.filled - this.currentStart >= rowlen) {
                    return this.unfilterRow(rowlen, bpp, false);
                }
                return null;
            }
            if (ev == EV_IMAGE_DATA_FLUSHED) this.consumedAndFlushed = true;
        }
        return this.unfilterRow(rowlen, bpp, true);
    }

    private unfilterRow(rowlen: i32, bpp: i32, inPlace: bool): Uint8Array? {
        const f = this.data[this.currentStart];
        if (f > 4) {
            this.errIsEof = false;
            this.err = `Unknown filter method ${f}.`;
            return null;
        }
        const prev = this.prevRow();
        let row: Uint8Array;
        if (inPlace) {
            row = this.data.subarray(this.currentStart + 1, this.currentStart + rowlen);
        } else {
            row = this.data.slice(this.currentStart + 1, this.currentStart + rowlen);
        }
        unfilter(f, bpp, prev, row);
        if (inPlace) {
            this.prevKind = PREV_IN_PLACE;
            this.prevStart = this.currentStart + 1;
        } else {
            this.prevKind = PREV_SCRATCH;
            this.scratch = row;
        }
        this.currentStart += rowlen;
        return row;
    }

    run(): Result<PngDecoded> {
        // read_header_info
        while (this.hdr == null) {
            if (this.decodeNext(false) == EV_ERROR) return Result.fail<PngDecoded>(this.err);
        }
        // After the header: the output buffer size must fit in i64 range
        // (no tRNS known yet).
        {
            const h0 = this.hdr as Header;
            const ch0: u64 = h0.colorType == 6 ? 4 : (h0.colorType == 4 ? 2 : (h0.colorType == 0 ? 1 : 3));
            const line0 = <u64>h0.width * ch0;
            const rows0 = <u64>h0.height;
            if (line0 > <u64>i64.MAX_VALUE / rows0) return Result.fail<PngDecoded>("limits are exceeded");
        }
        // read_until_image_data
        while (true) {
            const ev = this.decodeNext(false);
            if (ev == EV_ERROR) return Result.fail<PngDecoded>(this.err);
            if (ev == EV_CHUNK_BEGIN && (this.evType == T_IDAT || this.evType == T_FDAT)) break;
            if (ev == EV_CHUNK_COMPLETE && this.evType == T_IEND) return Result.fail<PngDecoded>("IDAT or fdAT chunk is missing.");
        }
        const h = this.hdr as Header;
        const W = h.hasFrameControl ? h.fcWidth : h.width;
        const H = h.hasFrameControl ? h.fcHeight : h.height;
        const hasTrns = h.trns != null;
        const ct = h.colorType;
        let outColor = PngColor.Rgba;
        let outCh = 4;
        if (ct == 3 || ct == 2) {
            outColor = hasTrns ? PngColor.Rgba : PngColor.Rgb;
            outCh = hasTrns ? 4 : 3;
        } else if (ct == 0) {
            outColor = hasTrns ? PngColor.GrayscaleAlpha : PngColor.Grayscale;
            outCh = hasTrns ? 2 : 1;
        } else if (ct == 4) {
            outColor = PngColor.GrayscaleAlpha;
            outCh = 2;
        }
        // Frame bytes as png counts them (Adam7: one filter byte per row even
        // for passes without samples).
        let frameBytes: u64 = 0;
        if (h.interlaced) {
            for (let p = 0; p < 7; p++) {
                frameBytes += rawRowLength(h, a7Count(W, A7_X0[p], A7_DX[p])) * <u64>a7Count(H, A7_Y0[p], A7_DY[p]);
            }
        } else {
            frameBytes = rawRowLength(h, W) * <u64>H;
        }
        this.remainingBytes = <i64>frameBytes;
        this.shiftBackLimit = max<i64>(<i64>((rawRowLength(h, h.width) * 4 + 63) / 64 * 64), 128 * 1024);
        // `reserve_bytes` for one output row.
        const lineBytes = <u64>W * <u64>outCh;
        if (<i64>lineBytes > this.limitBytes) return Result.fail<PngDecoded>("limits are exceeded");
        // The whole output must fit in wasm32 memory.
        const outSize = <u64>W * <u64>H * <u64>outCh;
        if (outSize > 0x7fff0000) return Result.fail<PngDecoded>("limits are exceeded");

        // (milestone 67b: a scratch buffer when its reader widens it to RGBA
        // and gives it back: decodePngPooled)
        const pooledOut = this.poolPixels && outColor != PngColor.Rgba;
        const out = pooledOut ? scratchPool().take(<i32>outSize) : new Uint8Array(<i32>outSize);
        const bpp = max<i32>(1, samplesOf(ct) * <i32>h.bitDepth / 8);
        let conv: RowConverter? = null;
        if (!h.interlaced) {
            const rowlen = <i32>rawRowLength(h, W);
            for (let y = 0; y < <i32>H; y++) {
                const row = this.nextRawRow(rowlen, bpp);
                if (row == null) {
                    if (pooledOut) scratchPool().give(out);
                    return Result.fail<PngDecoded>(this.err);
                }
                if (conv == null) {
                    if (ct == 3 && h.palette == null) {
                        if (pooledOut) scratchPool().give(out);
                        return Result.fail<PngDecoded>("Missing palette of indexed image.");
                    }
                    conv = new RowConverter(h, outCh);
                }
                conv.convert(row, 0, <i32>W, out, y * <i32>W * outCh);
            }
        } else {
            const tmp = scratchPool().take(<i32>W * outCh);
            for (let p = 0; p < 7; p++) {
                const pw = <i32>a7Count(W, A7_X0[p], A7_DX[p]);
                const ph = <i32>a7Count(H, A7_Y0[p], A7_DY[p]);
                if (pw == 0 || ph == 0) continue;
                this.prevKind = PREV_NONE;
                const rowlen = <i32>rawRowLength(h, <u32>pw);
                for (let py = 0; py < ph; py++) {
                    const row = this.nextRawRow(rowlen, bpp);
                    if (row == null) {
                        scratchPool().give(tmp);
                        if (pooledOut) scratchPool().give(out);
                        return Result.fail<PngDecoded>(this.err);
                    }
                    if (conv == null) {
                        if (ct == 3 && h.palette == null) {
                            scratchPool().give(tmp);
                            if (pooledOut) scratchPool().give(out);
                            return Result.fail<PngDecoded>("Missing palette of indexed image.");
                        }
                        conv = new RowConverter(h, outCh);
                    }
                    conv.convert(row, 0, pw, tmp, 0);
                    const yy = A7_Y0[p] + py * A7_DY[p];
                    for (let px = 0; px < pw; px++) {
                        const o = (yy * <i32>W + A7_X0[p] + px * A7_DX[p]) * outCh;
                        for (let k = 0; k < outCh; k++) out[o + k] = tmp[px * outCh + k];
                    }
                }
            }
            scratchPool().give(tmp);
        }
        // finish_decoding: skip the rest of the image data, up to the next chunk type.
        if (!this.consumedAndFlushed) {
            while (true) {
                const ev = this.decodeNext(false);
                if (ev == EV_ERROR) {
                    if (pooledOut) scratchPool().give(out);
                    return Result.fail<PngDecoded>(this.err);
                }
                if (ev == EV_IMAGE_DATA_FLUSHED) break;
            }
            this.consumedAndFlushed = true;
        }
        const d = new PngDecoded();
        d.width = W;
        d.height = H;
        d.color = outColor;
        d.pixels = out;
        d.pooled = pooledOut;
        return Result.okv<PngDecoded>(d);
    }
}

// Reverses the PNG row filter on `row` (filter byte already removed), with `prev`
// the unfiltered previous row or empty (then Paeth is Sub and Up is None).
// Indices stay inside `row` / `prev` (same length), hence `unchecked`.
function unfilter(filter: u8, bpp: i32, prev: Uint8Array, row: Uint8Array): void {
    const n = row.length;
    const hasPrev = prev.length > 0;
    let f = filter;
    if (!hasPrev) {
        if (f == 4) f = 1;
        else if (f == 2) f = 0;
    }
    if (f == 1) {
        for (let x = bpp; x < n; x++) unchecked(row[x] = unchecked(row[x]) + unchecked(row[x - bpp]));
    } else if (f == 2) {
        for (let x = 0; x < n; x++) unchecked(row[x] = unchecked(row[x]) + unchecked(prev[x]));
    } else if (f == 3) {
        if (hasPrev) {
            for (let x = 0; x < bpp && x < n; x++) {
                unchecked(row[x] = <u8>(<i32>unchecked(row[x]) + (<i32>unchecked(prev[x]) >> 1)));
            }
            for (let x = bpp; x < n; x++) {
                const a = <i32>unchecked(row[x - bpp]);
                const b = <i32>unchecked(prev[x]);
                unchecked(row[x] = <u8>(<i32>unchecked(row[x]) + ((a + b) >> 1)));
            }
        } else {
            for (let x = bpp; x < n; x++) {
                unchecked(row[x] = <u8>(<i32>unchecked(row[x]) + (<i32>unchecked(row[x - bpp]) >> 1)));
            }
        }
    } else if (f == 4) {
        // prev is non-empty here; x < bpp has a = c = 0, so paeth is b.
        for (let x = 0; x < bpp && x < n; x++) {
            unchecked(row[x] = unchecked(row[x]) + unchecked(prev[x]));
        }
        for (let x = bpp; x < n; x++) {
            const a = <i32>unchecked(row[x - bpp]);
            const b = <i32>unchecked(prev[x]);
            const c = <i32>unchecked(prev[x - bpp]);
            const p = a + b - c;
            const pa = abs<i32>(p - a);
            const pb = abs<i32>(p - b);
            const pc = abs<i32>(p - c);
            const pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c);
            unchecked(row[x] = <u8>(<i32>unchecked(row[x]) + pred));
        }
    }
}

// Decodes PNG bytes normalized to 8-bit color (see the section comment for
// the order of checks it follows).
export function decodePng(b: Uint8Array): Result<PngDecoded> {
    const r = new PngReader(b);
    const got = r.run();
    r.release();
    return got;
}

// Milestone 67b: decodePng, the pixels of an image that is not RGBA in a
// scratch buffer (PngDecoded.pooled), for a reader that widens them into
// an RGBA image of its own and then gives them back with
// releasePngPixels (render/image.as Image.decodePng). The same bytes as
// decodePng's.
export function decodePngPooled(b: Uint8Array): Result<PngDecoded> {
    const r = new PngReader(b);
    r.poolPixels = true;
    const got = r.run();
    r.release();
    return got;
}

// The pixels of a decodePngPooled image back to the pool (nothing for one
// that is not pooled); `d.pixels` is empty afterwards.
export function releasePngPixels(d: PngDecoded): void {
    if (!d.pooled) return;
    scratchPool().give(d.pixels);
    d.pixels = NO_INPUT;
    d.pooled = false;
}

// One unfiltered row to normalized 8-bit output samples.
class RowConverter {
    ct: u8;
    bd: i32;
    outCh: i32;
    trns: Uint8Array?;
    // Indexed: 256 RGBA entries (create_rgba_palette).
    pal: Uint8Array = new Uint8Array(0);

    constructor(h: Header, outCh: i32) {
        this.ct = h.colorType;
        this.bd = <i32>h.bitDepth;
        this.outCh = outCh;
        this.trns = h.trns;
        if (h.colorType == 3) {
            const pal = new Uint8Array(256 * 4);
            for (let i = 0; i < 256; i++) pal[i * 4 + 3] = 0xff;
            const p = h.palette as Uint8Array;
            const entries = p.length / 3;
            for (let i = 0; i < entries && i < 256; i++) {
                pal[i * 4] = p[i * 3];
                pal[i * 4 + 1] = p[i * 3 + 1];
                pal[i * 4 + 2] = p[i * 3 + 2];
            }
            const t = h.trns;
            if (t != null && t.length <= entries) {
                for (let i = 0; i < t.length; i++) pal[i * 4 + 3] = t[i];
            }
            this.pal = pal;
        }
    }

    // Sample `i` (a bd-bit value) of the packed row starting at `at`.
    packed(raw: Uint8Array, at: i32, i: i32): u8 {
        const bd = this.bd;
        if (bd == 8) return raw[at + i];
        const perByte = 8 / bd;
        const byte = raw[at + i / perByte];
        const shift = 8 - bd - (i % perByte) * bd;
        return <u8>((<i32>byte >> shift) & ((1 << bd) - 1));
    }

    convert(raw: Uint8Array, at: i32, w: i32, out: Uint8Array, o: i32): void {
        const ct = this.ct;
        const bd = this.bd;
        const outCh = this.outCh;
        if (ct == 3) {
            const pal = this.pal;
            for (let x = 0; x < w; x++) {
                const idx = <i32>this.packed(raw, at, x);
                for (let k = 0; k < outCh; k++) out[o + x * outCh + k] = pal[idx * 4 + k];
            }
            return;
        }
        const t = this.trns;
        if (ct == 0 && bd < 8) {
            const scale = <u8>(255 / ((1 << bd) - 1));
            for (let x = 0; x < w; x++) {
                const v = this.packed(raw, at, x);
                out[o + x * outCh] = <u8>(v * scale);
                if (outCh == 2) out[o + x * 2 + 1] = t != null && v == t[0] ? 0 : 0xff;
            }
            return;
        }
        const samples = samplesOf(ct);
        if (t == null && bd == 8) {
            // `copy_row`: the samples are already 8-bit and outCh == samples.
            out.set(raw.subarray(at, at + w * samples), o);
            return;
        }
        const inBytes = bd == 16 ? 2 : 1;
        const chunk = samples * inBytes;
        for (let x = 0; x < w; x++) {
            const src = at + x * chunk;
            const dst = o + x * outCh;
            for (let k = 0; k < samples; k++) out[dst + k] = raw[src + k * inBytes];
            if (t != null && (ct == 0 || ct == 2)) {
                // Transparent when the whole pixel (at its bit depth) equals tRNS.
                let eq = t.length == chunk;
                if (eq) {
                    for (let k = 0; k < chunk; k++) {
                        if (raw[src + k] != t[k]) { eq = false; break; }
                    }
                }
                out[dst + samples] = eq ? 0 : 0xff;
            }
        }
    }
}
