// High dynamic range images (milestone 11): `FloatImage`, linear RGB in
// f32, and the Radiance HDR (.hdr, RGBE) codec a PanoramaSkyMaterial's
// panorama is read with. A panorama may also be a PNG, which
// `FloatImage.fromImage` decodes from sRGB, so the sky code reads one kind
// of image whatever the file was.
//
// The codec reads what Radiance, Blender, Photoshop and the HDRI sites
// write: a `#?RADIANCE` (or `#?RGBE`) header whose FORMAT is
// 32-bit_rle_rgbe, the standard orientation `-Y <height> +X <width>`, and
// scanlines either flat or run-length encoded the "new" way (each of the
// four channels on its own, a scanline starting 2, 2). Old-style runs
// (1, 1, 1, n) are read as plain texels, as stb_image (and so Godot) reads
// them; xyze colours and other orientations are errors that say so.
// EXPOSURE and other header lines are ignored, as Godot's importer ignores
// them. A texel's value is stb_image's: (byte) * 2^(e - 136), 0 when e is
// 0. Error messages number scanlines from 0, the top row.

import { Result } from "../base/util";
import { Vec3 } from "../base/vecmath";
import { Image, srgbToLinear } from "./image";
import { extension } from "../fs/path";
import { toAsciiLowercase } from "../base/util";

// Linear RGB, three f32 per texel, rows top first.
export class FloatImage {
    width: u32;
    height: u32;
    data: Float32Array;
    // sky.as `floatImageDigest`'s answer, kept once worked out ("" until
    // then): hashing every texel of a 2048 x 1024 panorama is too slow to
    // repeat each frame, and a reloaded file is a new FloatImage, so the
    // memo never outlives the texels it hashed. `put` clears it; code that
    // writes `data` directly after asking for the digest must too.
    digest: string = "";

    constructor(width: u32, height: u32, data: Float32Array) {
        this.width = width;
        this.height = height;
        this.data = data;
    }

    // Every texel `fill`.
    static new(width: u32, height: u32, fill: Vec3): FloatImage {
        const n = <i32>(width * height);
        const d = new Float32Array(n * 3);
        for (let i = 0; i < n; i++) {
            d[i * 3] = fill.x;
            d[i * 3 + 1] = fill.y;
            d[i * 3 + 2] = fill.z;
        }
        return new FloatImage(width, height, d);
    }

    // An 8-bit image's colour, sRGB-decoded when `srgb` (a PNG panorama);
    // alpha is dropped, as a sky has none.
    static fromImage(img: Image, srgb: bool): FloatImage {
        const n = <i32>(img.width * img.height);
        const d = new Float32Array(n * 3);
        const s = img.data;
        for (let i = 0; i < n; i++) {
            for (let c = 0; c < 3; c++) {
                const v = <f32>s[i * 4 + c] / <f32>255.0;
                d[i * 3 + c] = srgb ? srgbToLinear(v) : v;
            }
        }
        return new FloatImage(img.width, img.height, d);
    }

    get(x: u32, y: u32): Vec3 {
        const i = <i32>(y * this.width + x) * 3;
        return Vec3(this.data[i], this.data[i + 1], this.data[i + 2]);
    }

    put(x: u32, y: u32, c: Vec3): void {
        this.digest = "";
        const i = <i32>(y * this.width + x) * 3;
        this.data[i] = c.x;
        this.data[i + 1] = c.y;
        this.data[i + 2] = c.z;
    }

    // The next smaller level: a 2 x 2 box filter, half the size (at least
    // 1), the last row or column repeated for an odd size.
    half(): FloatImage {
        const w = this.width > 1 ? this.width / 2 : 1;
        const h = this.height > 1 ? this.height / 2 : 1;
        const out = new FloatImage(w, h, new Float32Array(<i32>(w * h) * 3));
        for (let y: u32 = 0; y < h; y++) {
            for (let x: u32 = 0; x < w; x++) {
                const x0 = min<u32>(x * 2, this.width - 1);
                const x1 = min<u32>(x * 2 + 1, this.width - 1);
                const y0 = min<u32>(y * 2, this.height - 1);
                const y1 = min<u32>(y * 2 + 1, this.height - 1);
                const c = (this.get(x0, y0) + this.get(x1, y0) + this.get(x0, y1) + this.get(x1, y1)) * 0.25;
                out.put(x, y, c);
            }
        }
        return out;
    }
}

// Whether a path names a Radiance HDR file (by its extension, any case).
export function isHdrPath(path: string): bool {
    const e = extension(path);
    return e != null && toAsciiLowercase(e) == "hdr";
}

// Decodes a Radiance HDR file (see the header). The error is a sentence
// for a warning or a `texture-decode` error ("not a Radiance HDR file: no
// #?RADIANCE header").
export function decodeHdr(bytes: Uint8Array): Result<FloatImage> {
    const r = new HdrReader(bytes);
    const magic = r.line();
    if (magic == null || !(magic.startsWith("#?RADIANCE") || magic.startsWith("#?RGBE"))) {
        return Result.fail<FloatImage>("not a Radiance HDR file (no #?RADIANCE header)");
    }
    // Header lines up to the blank one; only FORMAT matters.
    while (true) {
        const l = r.line();
        if (l == null) return Result.fail<FloatImage>(orientationError(""));
        if (l.length == 0) break;
        if (l.startsWith("FORMAT=")) {
            const f = l.substring(7).trim();
            if (f != "32-bit_rle_rgbe") {
                return Result.fail<FloatImage>("unsupported FORMAT " + f + " (only 32-bit_rle_rgbe)");
            }
        }
    }
    const res = r.line();
    if (res == null) return Result.fail<FloatImage>(orientationError(""));
    const parts = res.trim().split(" ");
    const words = new Array<string>();
    for (let i = 0; i < parts.length; i++) if (parts[i].length > 0) words.push(parts[i]);
    if (words.length != 4 || words[0] != "-Y" || words[2] != "+X") {
        return Result.fail<FloatImage>(orientationError(res));
    }
    const h = parseDimension(words[1]);
    const w = parseDimension(words[3]);
    if (h <= 0 || w <= 0) return Result.fail<FloatImage>(orientationError(res));
    if (h * w > HDR_MAX_TEXELS) {
        return Result.fail<FloatImage>("image too large (" + w.toString() + " x " + h.toString()
            + "; at most " + HDR_MAX_TEXELS.toString() + " texels)");
    }
    const width = <i32>w;
    const height = <i32>h;
    const out = new FloatImage(<u32>width, <u32>height, new Float32Array(width * height * 3));
    const scale = rgbeScales();
    const line = new Uint8Array(width * 4);
    const src = bytes;
    // Once a scanline turns out not to be run-length encoded, the rest of
    // the file is read flat, as stb_image does.
    let flat = width < 8 || width > 32767;
    for (let y = 0; y < height; y++) {
        if (!flat) {
            if (r.at + 4 > src.length) return Result.fail<FloatImage>(endsInside(y));
            const b0 = src[r.at];
            const b1 = src[r.at + 1];
            const b2 = src[r.at + 2];
            if (b0 != 2 || b1 != 2 || (b2 & 0x80) != 0) {
                flat = true;
            } else {
                const len = (<i32>b2 << 8) | <i32>src[r.at + 3];
                if (len != width) return Result.fail<FloatImage>(badRuns(y));
                r.at += 4;
                for (let c = 0; c < 4; c++) {
                    let x = 0;
                    while (x < width) {
                        if (r.at >= src.length) return Result.fail<FloatImage>(endsInside(y));
                        let count = <i32>src[r.at++];
                        if (count > 128) {
                            count -= 128;
                            if (x + count > width) return Result.fail<FloatImage>(badRuns(y));
                            if (r.at >= src.length) return Result.fail<FloatImage>(endsInside(y));
                            const v = src[r.at++];
                            for (let i = 0; i < count; i++) line[(x + i) * 4 + c] = v;
                        } else {
                            if (count == 0 || x + count > width) return Result.fail<FloatImage>(badRuns(y));
                            if (r.at + count > src.length) return Result.fail<FloatImage>(endsInside(y));
                            for (let i = 0; i < count; i++) line[(x + i) * 4 + c] = src[r.at + i];
                            r.at += count;
                        }
                        x += count;
                    }
                }
            }
        }
        if (flat) {
            if (r.at + width * 4 > src.length) return Result.fail<FloatImage>(endsInside(y));
            for (let i = 0; i < width * 4; i++) line[i] = src[r.at + i];
            r.at += width * 4;
        }
        const d = out.data;
        const row = y * width * 3;
        for (let x = 0; x < width; x++) {
            const f = scale[line[x * 4 + 3]];
            d[row + x * 3] = <f32>line[x * 4] * f;
            d[row + x * 3 + 1] = <f32>line[x * 4 + 1] * f;
            d[row + x * 3 + 2] = <f32>line[x * 4 + 2] * f;
        }
    }
    return Result.okv<FloatImage>(out);
}

// The most texels decodeHdr accepts (4096 x 4096): a bound on what a
// corrupt header can make it allocate, above any panorama worth drawing
// (FloatImage halves them to PANORAMA_MAX_WIDTH anyway).
const HDR_MAX_TEXELS: i64 = 16777216;

function orientationError(line: string): string {
    return "unsupported orientation \"" + line + "\" (only -Y <height> +X <width>)";
}

function endsInside(y: i32): string {
    return "the file ends inside scanline " + y.toString();
}

function badRuns(y: i32): string {
    return "bad run-length data in scanline " + y.toString();
}

// A resolution's number: decimal digits only, else -1.
function parseDimension(s: string): i64 {
    if (s.length == 0 || s.length > 9) return -1;
    let v: i64 = 0;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c < 48 || c > 57) return -1;
        v = v * 10 + <i64>(c - 48);
    }
    return v;
}

// 2^(e - 136) for each exponent byte, 0 for 0: the factor a mantissa byte
// is multiplied by.
function rgbeScales(): Float32Array {
    const t = new Float32Array(256);
    for (let e = 1; e < 256; e++) t[e] = <f32>Math.pow(2, <f64>(e - 136));
    return t;
}

// Reads the header's lines, then leaves `at` on the first scanline byte.
class HdrReader {
    bytes: Uint8Array;
    at: i32 = 0;

    constructor(bytes: Uint8Array) {
        this.bytes = bytes;
    }

    // The next line without its newline (and a carriage return before it),
    // or null at the end of the bytes. A header is ASCII; a line longer
    // than 4096 bytes is not a header's, so it ends there.
    line(): string? {
        const b = this.bytes;
        if (this.at >= b.length) return null;
        let s = "";
        let n = 0;
        while (this.at < b.length && n < 4096) {
            const c = b[this.at++];
            if (c == 10) break;
            s += String.fromCharCode(c);
            n++;
        }
        if (s.endsWith("\r")) s = s.substring(0, s.length - 1);
        return s;
    }
}

// The texel at `bytes[at]` (4 bytes, RGBE) as decodeHdr reads one:
// stb_image's (byte) * 2^(e - 136), 0 when e is 0. Decoding then encoding
// gives the same bytes back for any texel rgbeEncode wrote.
export function rgbeDecode(bytes: Uint8Array, at: i32): Vec3 {
    let t = decodeScales;
    if (t == null) {
        t = rgbeScales();
        decodeScales = t;
    }
    const f = t![bytes[at + 3]];
    return Vec3(<f32>bytes[at] * f, <f32>bytes[at + 1] * f, <f32>bytes[at + 2] * f);
}

// rgbeDecode's table, made on its first call (a program that never decodes
// a texel alone never allocates it).
let decodeScales: Float32Array? = null;

