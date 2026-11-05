// A CPU RGBA8 image, compositing helpers for sheets
// and labels, PNG in (on bytes; see png.as; out: source/codec/png_write.as) and the tolerance compare used
// by golden tests.

import { f32ToI32, f32ToU8, clampF32, maxF32, roundF32, Result } from "../base/util";
import { Vec4 } from "../base/vecmath";
import { srgbToLinear as baseSrgbToLinear } from "../base/color";
import { RenderError } from "./errors";
import { decodePngPooled, releasePngPixels, PngDecoded, PngColor } from "./png";

// sRGB-encoded color with alpha, 0-255. A value type (copied on
// assignment).
export struct Rgba {
    r: u8 = 0;
    g: u8 = 0;
    b: u8 = 0;
    a: u8 = 0;

    constructor(r: u8, g: u8, b: u8, a: u8) {
        this.r = r;
        this.g = g;
        this.b = b;
        this.a = a;
    }

    operator==(x: Rgba, y: Rgba): bool { return x.r == y.r && x.g == y.g && x.b == y.b && x.a == y.a; }
    readonly hash(): u32 { return (<u32>this.r << 24) | (<u32>this.g << 16) | (<u32>this.b << 8) | <u32>this.a; }

    // `c[k]`.
    readonly get(k: i32): u8 {
        if (k == 0) return this.r;
        if (k == 1) return this.g;
        if (k == 2) return this.b;
        return this.a;
    }

    // Debug text: "[1, 2, 3, 4]".
    readonly debug(): string { return `[${this.r}, ${this.g}, ${this.b}, ${this.a}]`; }
    readonly toString(): string { return this.debug(); }
}

// `[v; 4]`.
export function rgbaSplat(v: u8): Rgba { return Rgba(v, v, v, v); }

// Milestone 67b: the one empty array a released image's `data` becomes
// (Image.releasePixels), shared, so a release allocates nothing.
const NO_PIXELS: Uint8Array = new Uint8Array(0);

export class Image {
    width: u32;
    height: u32;
    // Straight-alpha RGBA, row-major, top row first.
    data: Uint8Array;
    // Milestone 67b (docs/engine/RESOURCES.md, "CPU copies"): the pixels
    // were let go of once the image was on the GPU (releasePixels): `data`
    // is empty, `width` and `height` are kept, and the object is still the
    // key the renderers' texture shares find its upload by.
    released: bool = false;
    // Milestone 67b: released, then its texture freed (the run time's
    // cache: ../scene/runtime/runtime_resources.as freed), so that its
    // upload went too: it has neither pixels nor a GPU texture and is
    // never drawn again, as Godot's freed texture is gone with its RID. A
    // tree that still names it draws its path read again from its source
    // (../scene/render/cache.as SceneTextureFiles takes it in no more).
    freed: bool = false;
    // Kept on the CPU after its upload: something reads the pixels later
    // (../scene/resource/cpu_copy.as pinImage). A flag on the image, not a
    // set of images, so a pin keeps nothing alive.
    pinned: bool = false;

    constructor(width: u32, height: u32, data: Uint8Array) {
        this.width = width;
        this.height = height;
        this.data = data;
    }

    // A `width` x `height` image filled with `fill`.
    static new(width: u32, height: u32, fill: Rgba): Image {
        const n = width * height;
        const data = new Uint8Array(<i32>(n * 4));
        for (let i: u32 = 0; i < n; i++) {
            const o = <i32>(i * 4);
            data[o] = fill.r;
            data[o + 1] = fill.g;
            data[o + 2] = fill.b;
            data[o + 3] = fill.a;
        }
        return new Image(width, height, data);
    }

    // An image over `data` (RGBA8, row-major; not copied).
    static fromRgba(width: u32, height: u32, data: Uint8Array): Image {
        return new Image(width, height, data);
    }

    // A deep copy.
    clone(): Image {
        return new Image(this.width, this.height, this.data.slice(0));
    }

    // Same size and same bytes. A released image (releasePixels) equals
    // only itself: its bytes are gone, so another image's cannot be
    // compared with them (a texture file registered again then counts as
    // changed and is uploaded again: SceneTextureFiles.add).
    equals(o: Image): bool {
        if (this === o) return true;
        if (this.released || o.released) return false;
        if (this.width != o.width || this.height != o.height) return false;
        const a = this.data;
        const b = o.data;
        if (a.length != b.length) return false;
        for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    // Milestone 67b: lets go of the pixels (see `released`); the bytes it
    // held, 0 when it held none or was released already. Allocates
    // nothing.
    releasePixels(): i64 {
        if (this.released) return 0;
        const n = <i64>this.data.length;
        this.data = NO_PIXELS;
        this.released = true;
        return n;
    }

    get(x: u32, y: u32): Rgba {
        const i = <i32>((y * this.width + x) * 4);
        const d = this.data;
        return Rgba(d[i], d[i + 1], d[i + 2], d[i + 3]);
    }

    put(x: i32, y: i32, c: Rgba): void {
        if (x < 0 || y < 0 || x >= <i32>this.width || y >= <i32>this.height) {
            return;
        }
        const i = <i32>((<u32>y * this.width + <u32>x) * 4);
        const d = this.data;
        d[i] = c.r;
        d[i + 1] = c.g;
        d[i + 2] = c.b;
        d[i + 3] = c.a;
    }

    // Alpha-blend `c` over the pixel (straight alpha, in sRGB space, which is
    // what UI-style overlays want).
    blend(x: i32, y: i32, c: Rgba): void {
        if (x < 0 || y < 0 || x >= <i32>this.width || y >= <i32>this.height) {
            return;
        }
        const i = <i32>((<u32>y * this.width + <u32>x) * 4);
        const d = this.data;
        const a = <u32>c.a;
        if (a == 0) {
            return;
        }
        if (a == 255) {
            d[i] = c.r;
            d[i + 1] = c.g;
            d[i + 2] = c.b;
            d[i + 3] = c.a;
            return;
        }
        const ia = 255 - a;
        const da = <u32>d[i + 3];
        const outA = max<u32>(a + da * ia / 255, 1);
        for (let k = 0; k < 3; k++) {
            const src = <u32>c.get(k);
            const dv = <u32>d[i + k];
            const v = (src * a + dv * da * ia / 255) / outA;
            d[i + k] = <u8>min<u32>(v, 255);
        }
        d[i + 3] = <u8>min<u32>(outA, 255);
    }

    fillRect(x: i32, y: i32, w: i32, h: i32, c: Rgba): void {
        const y1 = min<i32>(y + h, <i32>this.height);
        const x1 = min<i32>(x + w, <i32>this.width);
        for (let yy = max<i32>(y, 0); yy < y1; yy++) {
            for (let xx = max<i32>(x, 0); xx < x1; xx++) {
                this.blend(xx, yy, c);
            }
        }
    }

    // Copy `src` at `(x, y)`, clipped.
    blit(src: Image, x: i32, y: i32): void {
        const d = this.data;
        const s = src.data;
        for (let sy = 0; sy < <i32>src.height; sy++) {
            const dy = y + sy;
            if (dy < 0 || dy >= <i32>this.height) {
                continue;
            }
            for (let sx = 0; sx < <i32>src.width; sx++) {
                const dx = x + sx;
                if (dx < 0 || dx >= <i32>this.width) {
                    continue;
                }
                const si = <i32>((<u32>sy * src.width + <u32>sx) * 4);
                const di = <i32>((<u32>dy * this.width + <u32>dx) * 4);
                d[di] = s[si];
                d[di + 1] = s[si + 1];
                d[di + 2] = s[si + 2];
                d[di + 3] = s[si + 3];
            }
        }
    }

    // A `thickness`-pixel line between two points (DDA, no anti-aliasing;
    // used for UI marks such as the axis gizmo, not for geometry).
    line(x0: f32, y0: f32, x1: f32, y1: f32, thickness: i32, c: Rgba): void {
        const dx = x1 - x0;
        const dy = y1 - y0;
        const steps = f32ToI32(maxF32(Mathf.ceil(maxF32(Mathf.abs(dx), Mathf.abs(dy))), 1.0));
        const half = thickness / 2;
        // `thickness % 2` keeps the sign of `thickness` (truncating remainder).
        const hi = half - (1 - thickness % 2);
        // i64 counter: `0..=steps` ends even when steps saturated to i32::MAX.
        for (let s: i64 = 0; s <= <i64>steps; s++) {
            const t = <f32>s / <f32>steps;
            const x = f32ToI32(roundF32(x0 + dx * t));
            const y = f32ToI32(roundF32(y0 + dy * t));
            for (let oy = -half; oy <= hi; oy++) {
                for (let ox = -half; ox <= hi; ox++) {
                    this.blend(x + ox, y + oy, c);
                }
            }
        }
    }

    // Box-filter downsample by an integer factor (SSAA resolve).
    // `weighted` (a transparent frame's straight alpha) averages colour by
    // alpha, so a partly covered texel keeps its colour beside empty ones;
    // alpha is the plain average either way (post_compose.wgsl's `weighted`).
    downsample(factor: u32, weighted: bool = false): Image {
        if (factor <= 1) {
            return this.clone();
        }
        const w = this.width / factor;
        const h = this.height / factor;
        const out = new Uint8Array(<i32>(w * h * 4));
        const n = factor * factor;
        const d = this.data;
        for (let y: u32 = 0; y < h; y++) {
            for (let x: u32 = 0; x < w; x++) {
                let a0: u32 = 0, a1: u32 = 0, a2: u32 = 0, a3: u32 = 0;
                for (let sy: u32 = 0; sy < factor; sy++) {
                    for (let sx: u32 = 0; sx < factor; sx++) {
                        const i = <i32>(((y * factor + sy) * this.width + x * factor + sx) * 4);
                        const a = <u32>d[i + 3];
                        const m: u32 = weighted ? a : 1;
                        a0 += <u32>d[i] * m;
                        a1 += <u32>d[i + 1] * m;
                        a2 += <u32>d[i + 2] * m;
                        a3 += a;
                    }
                }
                const o = <i32>((y * w + x) * 4);
                // (weighted: by the summed alpha, 0 where nothing covers)
                const q: u32 = weighted ? a3 : n;
                if (q != 0) {
                    out[o] = <u8>((a0 + q / 2) / q);
                    out[o + 1] = <u8>((a1 + q / 2) / q);
                    out[o + 2] = <u8>((a2 + q / 2) / q);
                }
                out[o + 3] = <u8>((a3 + n / 2) / n);
            }
        }
        return Image.fromRgba(w, h, out);
    }

    // Decodes PNG bytes (no file is read), normalized to 8 bits per channel
    // (palette and low bit depths expanded, 16-bit stripped), then widened
    // to RGBA. Errors are `RenderError.encode` with the decoder's message.
    static decodePng(bytes: Uint8Array): Result<Image> {
        // (milestone 67b: the pixels of a PNG that is not RGBA are widened
        // from a scratch buffer, given back once `data` is made; an RGBA
        // PNG's pixels are the image's own)
        const r = decodePngPooled(bytes);
        if (!r.ok) return RenderError.encode(r.err).fail<Image>();
        const p: PngDecoded = r.value;
        const px = p.pixels;
        const n = <i32>(p.width * p.height);
        let data: Uint8Array;
        switch (p.color) {
            case PngColor.Rgba: {
                data = px;
                break;
            }
            case PngColor.Rgb: {
                data = new Uint8Array(n * 4);
                for (let i = 0; i < n; i++) {
                    data[i * 4] = px[i * 3];
                    data[i * 4 + 1] = px[i * 3 + 1];
                    data[i * 4 + 2] = px[i * 3 + 2];
                    data[i * 4 + 3] = 255;
                }
                break;
            }
            case PngColor.Grayscale: {
                data = new Uint8Array(n * 4);
                for (let i = 0; i < n; i++) {
                    const g = px[i];
                    data[i * 4] = g;
                    data[i * 4 + 1] = g;
                    data[i * 4 + 2] = g;
                    data[i * 4 + 3] = 255;
                }
                break;
            }
            default: { // GrayscaleAlpha
                data = new Uint8Array(n * 4);
                for (let i = 0; i < n; i++) {
                    const g = px[i * 2];
                    data[i * 4] = g;
                    data[i * 4 + 1] = g;
                    data[i * 4 + 2] = g;
                    data[i * 4 + 3] = px[i * 2 + 1];
                }
                break;
            }
        }
        releasePngPixels(p);
        return Result.okv<Image>(Image.fromRgba(p.width, p.height, data));
    }
}

// Result of a perceptual compare (see `compare`).
export class Comparison {
    // Largest per-channel difference over all pixels.
    maxChannelDiff: u8 = 0;
    // Fraction of pixels where some channel differs by more than the epsilon.
    differingFraction: f64 = 0;
    sizeMatches: bool = false;

    passes(maxFraction: f64): bool {
        return this.sizeMatches && this.differingFraction <= maxFraction;
    }
}

// Compare two images the way golden tests do: a pixel "differs" when any
// channel is off by more than `epsilon`; the caller then bounds the fraction
// of differing pixels. This tolerates rasterization differences between GPUs
// (edge coverage, MSAA sample positions) while catching missing geometry,
// wrong colors or flipped images.
export function compare(a: Image, b: Image, epsilon: u8): Comparison {
    const c = new Comparison();
    if (a.width != b.width || a.height != b.height) {
        c.maxChannelDiff = 255;
        c.differingFraction = 1.0;
        c.sizeMatches = false;
        return c;
    }
    let mx: u8 = 0;
    let differing: u64 = 0;
    const da = a.data;
    const db = b.data;
    // `chunks(4).zip(..)`: the shorter data decides, a trailing partial chunk
    // is compared on the channels it has.
    const len = min<i32>(da.length, db.length);
    for (let p = 0; p < len; p += 4) {
        let d: u8 = 0;
        for (let k = 0; k < 4 && p + k < len; k++) {
            const x = da[p + k];
            const y = db[p + k];
            const diff: u8 = x > y ? x - y : y - x;
            if (diff > d) d = diff;
        }
        if (d > mx) mx = d;
        if (d > epsilon) {
            differing += 1;
        }
    }
    const total = <f64>max<u32>(a.width * a.height, 1);
    c.maxChannelDiff = mx;
    c.differingFraction = <f64>differing / total;
    c.sizeMatches = true;
    return c;
}

// sRGB (0-1) to linear.
export function srgbToLinear(c: f32): f32 {
    return baseSrgbToLinear(c);
}

function q(v: f32): u8 {
    return f32ToU8(clampF32(v, 0.0, 1.0) * <f32>255.0 + <f32>0.5);
}

// 0-1 sRGB floats to bytes.
export function rgbaBytes(c: Vec4): Rgba {
    return Rgba(q(c.x), q(c.y), q(c.z), q(c.w));
}
