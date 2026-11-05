// Godot's Gradient (milestone 35; docs/formats/RSCN.md "Particles"):
// colours over 0 to 1, which a CPUParticles3D reads over each particle's
// life (color_ramp) and at a random point per particle
// (color_initial_ramp). Stops sorted by offset, as Godot keeps them; a
// stop past the shorter of `offsets` and `colors` is left out (the
// validator's gradient-stops says so).
//
// `sample(offset)` is Godot's get_color_at_offset: the stop at or before
// the offset and the one after, blended by interpolation_mode (linear,
// constant: the earlier stop's, cubic: Godot's cubic_interpolate through
// the stops around them) in interpolation_color_space (srgb: the numbers
// as written, linear_srgb: decoded, blended and encoded again, oklab:
// through Oklab); before the first stop the first's colour, after the
// last the last's, none at all black. Allocates nothing. The colour
// arithmetic is f32 (Godot's Color), and the powers are the software powf
// of base/vecmath, so a ramp gives the same numbers on every host.

import { Vec4, powf } from "../../base/vecmath";
import { Resource } from "./types";

// Godot's Gradient.InterpolationMode and ColorSpace.
export const GRADIENT_LINEAR: i32 = 0;
export const GRADIENT_CONSTANT: i32 = 1;
export const GRADIENT_CUBIC: i32 = 2;
export const GRADIENT_SPACE_SRGB: i32 = 0;
export const GRADIENT_SPACE_LINEAR_SRGB: i32 = 1;
export const GRADIENT_SPACE_OKLAB: i32 = 2;

export class Gradient extends Resource {
    // The stops, by offset: offset, and its colour (sRGB, straight alpha).
    offsets: Array<f32> = [0, 1];
    colors: Array<Vec4> = [Vec4(0, 0, 0, 1), Vec4(1, 1, 1, 1)];
    interpolationMode: i32 = GRADIENT_LINEAR;
    colorSpace: i32 = GRADIENT_SPACE_SRGB;
    // What the file wrote, kept until both are read (setStops pairs them).
    rawOffsets: Array<f64> = [0, 1];
    rawColors: Array<f64> = [0, 0, 0, 1, 1, 1, 1, 1];

    className(): string {
        return "Gradient";
    }

    // Pairs rawOffsets with rawColors into the stops, sorted by offset (a
    // stable sort: stops of the same offset keep their order). Called
    // after each of `offsets` and `colors` is set.
    setStops(): void {
        const n = min<i32>(this.rawOffsets.length, this.rawColors.length / 4);
        const offs = new Array<f32>();
        const cols = new Array<Vec4>();
        for (let i = 0; i < n; i++) {
            const x = <f32>this.rawOffsets[i];
            const c = Vec4(<f32>this.rawColors[i * 4], <f32>this.rawColors[i * 4 + 1], <f32>this.rawColors[i * 4 + 2],
                <f32>this.rawColors[i * 4 + 3]);
            offs.push(x);
            cols.push(c);
            let at = offs.length - 1;
            while (at > 0 && offs[at - 1] > x) {
                offs[at] = offs[at - 1];
                cols[at] = cols[at - 1];
                at--;
            }
            offs[at] = x;
            cols[at] = c;
        }
        this.offsets = offs;
        this.colors = cols;
    }

    // Godot's get_color_at_offset (see the header). Allocates nothing.
    sample(offset: f32): Vec4 {
        const n = this.offsets.length;
        if (n == 0) return Vec4(0, 0, 0, 1);
        // Godot's binary search: a stop at the offset is its colour.
        let low = 0;
        let high = n - 1;
        let middle = 0;
        while (low <= high) {
            middle = (low + high) / 2;
            const at = unchecked(this.offsets[middle]);
            if (at > offset) high = middle - 1;
            else if (at < offset) low = middle + 1;
            else return unchecked(this.colors[middle]);
        }
        if (unchecked(this.offsets[middle]) > offset) middle--;
        const first = middle;
        const second = middle + 1;
        if (second >= n) return unchecked(this.colors[n - 1]);
        if (first < 0) return unchecked(this.colors[0]);
        const o1 = unchecked(this.offsets[first]);
        const weight = (offset - o1) / (unchecked(this.offsets[second]) - o1);
        const mode = this.interpolationMode;
        if (mode == GRADIENT_CONSTANT) return unchecked(this.colors[first]);
        const space = this.colorSpace;
        if (space == GRADIENT_SPACE_SRGB && mode != GRADIENT_CUBIC) {
            // (the common ramp, blended as written: a particle reads one
            // each step, so without the space's round trip)
            const a = unchecked(this.colors[first]);
            const b = unchecked(this.colors[second]);
            return Vec4(a.x + (b.x - a.x) * weight, a.y + (b.y - a.y) * weight, a.z + (b.z - a.z) * weight,
                a.w + (b.w - a.w) * weight);
        }
        const c1 = toSpace(unchecked(this.colors[first]), space);
        const c2 = toSpace(unchecked(this.colors[second]), space);
        if (mode != GRADIENT_CUBIC) {
            // (linear, and Godot's fallback for a mode it does not know)
            return fromSpace(c1 + (c2 - c1) * weight, space);
        }
        const c0 = toSpace(unchecked(this.colors[first > 0 ? first - 1 : first]), space);
        const c3 = toSpace(unchecked(this.colors[second + 1 < n ? second + 1 : second]), space);
        return fromSpace(Vec4(
            cubic(c1.x, c2.x, c0.x, c3.x, weight),
            cubic(c1.y, c2.y, c0.y, c3.y, weight),
            cubic(c1.z, c2.z, c0.z, c3.z, weight),
            cubic(c1.w, c2.w, c0.w, c3.w, weight),
        ), space);
    }
}

// Godot's Math::cubic_interpolate (Catmull-Rom through pre, from, to,
// post).
function cubic(from: f32, to: f32, pre: f32, post: f32, w: f32): f32 {
    return <f32>0.5 * ((from * 2) + (-pre + to) * w + (pre * 2 - from * 5 + to * 4 - post) * (w * w)
        + (-pre + from * 3 - to * 3 + post) * (w * w * w));
}

// Godot's Color.srgb_to_linear and linear_to_srgb, one channel.
function srgbToLinear(c: f32): f32 {
    return c < <f32>0.04045 ? c * <f32>(1.0 / 12.92) : powf((c + <f32>0.055) * <f32>(1.0 / 1.055), 2.4);
}

function linearToSrgb(c: f32): f32 {
    return c < <f32>0.0031308 ? c * <f32>12.92 : <f32>1.055 * powf(c, <f32>(1.0 / 2.4)) - <f32>0.055;
}

// cbrtf, through the software powf (the same bits on every host).
function cbrt(x: f32): f32 {
    if (x == 0) return 0;
    return x < 0 ? -powf(-x, <f32>(1.0 / 3.0)) : powf(x, <f32>(1.0 / 3.0));
}

// Godot's transform_color_space: a stop's colour in the space it is
// blended in (srgb: as written; linear_srgb: decoded; oklab: Oklab's L, a
// and b in the first three, through Godot's ok_color matrices); alpha as
// it is.
function toSpace(c: Vec4, space: i32): Vec4 {
    if (space == GRADIENT_SPACE_SRGB) return c;
    const r = srgbToLinear(c.x);
    const g = srgbToLinear(c.y);
    const b = srgbToLinear(c.z);
    if (space != GRADIENT_SPACE_OKLAB) return Vec4(r, g, b, c.w);
    const l = cbrt(<f32>0.4122214708 * r + <f32>0.5363325363 * g + <f32>0.0514459929 * b);
    const m = cbrt(<f32>0.2119034982 * r + <f32>0.6806995451 * g + <f32>0.1073969566 * b);
    const s = cbrt(<f32>0.0883024619 * r + <f32>0.2817188376 * g + <f32>0.6299787005 * b);
    return Vec4(
        <f32>0.2104542553 * l + <f32>0.7936177850 * m - <f32>0.0040720468 * s,
        <f32>1.9779984951 * l - <f32>2.4285922050 * m + <f32>0.4505937099 * s,
        <f32>0.0259040371 * l + <f32>0.7827717662 * m - <f32>0.8086757660 * s,
        c.w,
    );
}

// Godot's inv_transform_color_space: back to sRGB numbers.
function fromSpace(c: Vec4, space: i32): Vec4 {
    if (space == GRADIENT_SPACE_SRGB) return c;
    let r = c.x;
    let g = c.y;
    let b = c.z;
    if (space == GRADIENT_SPACE_OKLAB) {
        const l0 = c.x + <f32>0.3963377774 * c.y + <f32>0.2158037573 * c.z;
        const m0 = c.x - <f32>0.1055613458 * c.y - <f32>0.0638541728 * c.z;
        const s0 = c.x - <f32>0.0894841775 * c.y - <f32>1.2914855480 * c.z;
        const l = l0 * l0 * l0;
        const m = m0 * m0 * m0;
        const s = s0 * s0 * s0;
        r = <f32>4.0767416621 * l - <f32>3.3077115913 * m + <f32>0.2309699292 * s;
        g = <f32>-1.2684380046 * l + <f32>2.6097574011 * m - <f32>0.3413193965 * s;
        b = <f32>-0.0041960863 * l - <f32>0.7034186147 * m + <f32>1.7076147010 * s;
    }
    return Vec4(linearToSrgb(r), linearToSrgb(g), linearToSrgb(b), c.w);
}
