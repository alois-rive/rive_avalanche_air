// Split out of engine/src/render/png.as
// (HEDRA.md section 3.4): writing a built form is the compiler's; the
// engine keeps the reader.

import { Result } from "../../base/util";
import { RenderError } from "../../render/errors";
import { Image } from "../../render/image";
import { crcUpdate, adler32, ByteBuf, LEN_BASE, LEN_EXTRA, DIST_BASE, DIST_EXTRA, SIGNATURE, paeth } from "../../render/png";

class BitWriter {
    out: ByteBuf;
    acc: u64 = 0;
    n: i32 = 0;

    constructor(cap: i32) {
        this.out = new ByteBuf(cap);
    }

    // `v`'s low `bits` bits, LSB first.
    bits(v: u32, bits: i32): void {
        this.acc |= (<u64>v) << <u64>this.n;
        this.n += bits;
        while (this.n >= 8) {
            this.out.push(<u8>this.acc);
            this.acc >>= 8;
            this.n -= 8;
        }
    }

    // A Huffman code of `len` bits, MSB first.
    code(c: u32, len: i32): void {
        let r: u32 = 0;
        for (let k = 0; k < len; k++) r |= ((c >> <u32>k) & 1) << <u32>(len - 1 - k);
        this.bits(r, len);
    }

    flush(): void {
        if (this.n > 0) this.bits(0, 8 - this.n);
    }
}

function fixedLit(w: BitWriter, sym: i32): void {
    if (sym < 144) w.code(<u32>(0x30 + sym), 8);
    else if (sym < 256) w.code(<u32>(0x190 + sym - 144), 9);
    else if (sym < 280) w.code(<u32>(sym - 256), 7);
    else w.code(<u32>(0xc0 + sym - 280), 8);
}

function lengthSymbol(len: i32): i32 {
    for (let i = 28; i >= 0; i--) {
        if (len >= <i32>LEN_BASE[i]) return i;
    }
    return 0;
}

function distSymbol(d: i32): i32 {
    for (let i = 29; i >= 0; i--) {
        if (d >= <i32>DIST_BASE[i]) return i;
    }
    return 0;
}

const HASH_BITS = 15;

const WINDOW = 32768;

const MAX_CHAIN = 64;

// zlib stream (header, one fixed-Huffman block, Adler-32) of b[0..n].
export function zlibCompress(b: Uint8Array, n: i32): Uint8Array {
    const z = new ZlibStream(b, n);
    z.step(n);
    return z.finish();
}

// zlibCompress in parts, for work spread over frames (the import job
// deflates a KTX2 level a slice of input at a time: a 512 x 512 BC7 level
// is 256 KiB, tens of milliseconds): `step` deflates the input up to
// `bytes` further on (a match may run past that point), `finish` ends the
// stream. Each choice depends only on the position and the bytes, so the
// parts give zlibCompress's bytes however they are cut.
export class ZlibStream {
    private b: Uint8Array;
    private n: i32;
    private w: BitWriter;
    private head: Int32Array;
    private prev: Int32Array;
    private i: i32 = 0;

    constructor(b: Uint8Array, n: i32) {
        this.b = b;
        this.n = n;
        const w = new BitWriter(n / 4 + 64);
        w.out.push(0x78);
        w.out.push(0x9c);
        w.bits(1, 1); // BFINAL
        w.bits(1, 2); // BTYPE = fixed
        this.w = w;
        this.head = new Int32Array(1 << HASH_BITS);
        this.head.fill(-1);
        this.prev = new Int32Array(WINDOW);
    }

    get done(): bool {
        return this.i >= this.n;
    }

    // Deflates from where the last step stopped to at least `bytes` further
    // on (or the end); true when the input is all deflated.
    step(bytes: i32): bool {
        const b = this.b;
        const n = this.n;
        const w = this.w;
        const head = this.head;
        const prev = this.prev;
        let i = this.i;
        const stop = <i32>min<i64>(<i64>n, <i64>i + <i64>max<i32>(bytes, 1));
        while (i < stop) {
            let bestLen = 0;
            let bestDist = 0;
            if (i + 2 < n) {
                const h = ((<i32>b[i] << 10) ^ (<i32>b[i + 1] << 5) ^ <i32>b[i + 2]) & ((1 << HASH_BITS) - 1);
                let cand = head[h];
                let chain = 0;
                const maxLen = min<i32>(258, n - i);
                while (cand >= 0 && i - cand <= WINDOW && chain < MAX_CHAIN) {
                    if (b[cand + bestLen] == b[i + bestLen] || bestLen == 0) {
                        let l = 0;
                        while (l < maxLen && b[cand + l] == b[i + l]) l++;
                        if (l > bestLen) {
                            bestLen = l;
                            bestDist = i - cand;
                            if (l == maxLen) break;
                        }
                    }
                    const p = prev[cand & (WINDOW - 1)];
                    if (p >= cand) break;
                    cand = p;
                    chain++;
                }
                prev[i & (WINDOW - 1)] = head[h];
                head[h] = i;
            }
            if (bestLen >= 3) {
                const ls = lengthSymbol(bestLen);
                fixedLit(w, 257 + ls);
                const le = <i32>LEN_EXTRA[ls];
                if (le > 0) w.bits(<u32>(bestLen - <i32>LEN_BASE[ls]), le);
                const ds = distSymbol(bestDist);
                w.code(<u32>ds, 5);
                const de = <i32>DIST_EXTRA[ds];
                if (de > 0) w.bits(<u32>(bestDist - <i32>DIST_BASE[ds]), de);
                // Index the skipped positions too.
                for (let k = 1; k < bestLen; k++) {
                    const j = i + k;
                    if (j + 2 < n) {
                        const h2 = ((<i32>b[j] << 10) ^ (<i32>b[j + 1] << 5) ^ <i32>b[j + 2]) & ((1 << HASH_BITS) - 1);
                        prev[j & (WINDOW - 1)] = head[h2];
                        head[h2] = j;
                    }
                }
                i += bestLen;
            } else {
                fixedLit(w, <i32>b[i]);
                i++;
            }
        }
        this.i = i;
        return i >= n;
    }

    // The end of the block and the Adler-32: the stream (after every step).
    finish(): Uint8Array {
        const w = this.w;
        fixedLit(w, 256);
        w.flush();
        w.out.pushU32Be(adler32(this.b, 0, this.n));
        return w.out.finish();
    }
}

function writeChunk(out: ByteBuf, type: string, data: Uint8Array, start: i32, end: i32): void {
    out.pushU32Be(<u32>(end - start));
    const at = out.len;
    out.pushStr(type);
    out.pushBytes(data, start, end);
    out.pushU32Be(~crcUpdate(0xffffffff, out.data, at, out.len));
}

// PNG bytes of an 8-bit RGBA image; errors are png's EncodingError texts.
export function encodePng(width: u32, height: u32, rgba: Uint8Array): Result<Uint8Array> {
    if (width == 0) return Result.fail<Uint8Array>("Zero width not allowed");
    if (height == 0) return Result.fail<Uint8Array>("Zero height not allowed");
    const expected = <u64>width * <u64>height * 4;
    if (<u64>rgba.length != expected) {
        return Result.fail<Uint8Array>(`wrong data size, expected ${expected} got ${rgba.length}`);
    }
    const stride = <i32>width * 4;
    const h = <i32>height;
    const raw = new Uint8Array((stride + 1) * h);
    const cand = new Uint8Array(stride * 5);
    for (let y = 0; y < h; y++) {
        const row = y * stride;
        const up = row - stride;
        // Try every filter; keep the one with the smallest sum of |signed byte|.
        let best = 0;
        let bestSum: i64 = i64.MAX_VALUE;
        for (let f = 0; f < 5; f++) {
            let sum: i64 = 0;
            const o = f * stride;
            for (let x = 0; x < stride; x++) {
                const v = <i32>rgba[row + x];
                const a = x >= 4 ? <i32>rgba[row + x - 4] : 0;
                const b = y > 0 ? <i32>rgba[up + x] : 0;
                const c = x >= 4 && y > 0 ? <i32>rgba[up + x - 4] : 0;
                let r = 0;
                if (f == 0) r = v;
                else if (f == 1) r = v - a;
                else if (f == 2) r = v - b;
                else if (f == 3) r = v - ((a + b) >> 1);
                else r = v - paeth(a, b, c);
                const byte = <u8>r;
                cand[o + x] = byte;
                const s = <i32>(<i8>byte);
                sum += <i64>abs<i32>(s);
            }
            if (sum < bestSum) {
                bestSum = sum;
                best = f;
            }
        }
        const dst = y * (stride + 1);
        raw[dst] = <u8>best;
        raw.set(cand.subarray(best * stride, best * stride + stride), dst + 1);
    }
    const z = zlibCompress(raw, raw.length);
    const out = new ByteBuf(z.length + 64);
    for (let i = 0; i < 8; i++) out.push(SIGNATURE[i]);
    const ihdr = new Uint8Array(13);
    ihdr[0] = <u8>(width >>> 24);
    ihdr[1] = <u8>(width >>> 16);
    ihdr[2] = <u8>(width >>> 8);
    ihdr[3] = <u8>width;
    ihdr[4] = <u8>(height >>> 24);
    ihdr[5] = <u8>(height >>> 16);
    ihdr[6] = <u8>(height >>> 8);
    ihdr[7] = <u8>height;
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    writeChunk(out, "IHDR", ihdr, 0, 13);
    // IDAT in chunks of at most 1 MiB.
    let p = 0;
    while (p < z.length) {
        const e = min<i32>(p + (1 << 20), z.length);
        writeChunk(out, "IDAT", z, p, e);
        p = e;
    }
    writeChunk(out, "IEND", new Uint8Array(0), 0, 0);
    return Result.okv<Uint8Array>(out.finish());
}

// The PNG bytes of `img` (8-bit RGBA); no file is written (was
// Image.encodePng). The caller writes them (and maps its I/O failure to
// `RenderError.io(path, e)`). Encoding errors are `RenderError.encode`
// ("PNG error: ...").
export function encodeImagePng(img: Image): Result<Uint8Array> {
    const r = encodePng(img.width, img.height, img.data);
    if (!r.ok) return RenderError.encode(r.err).fail<Uint8Array>();
    return r;
}
