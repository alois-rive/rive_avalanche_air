// sRGB transfer functions. Scene colors are sRGB 0..1 (PLAN §3.3); the
// renderer and glTF's color factors are linear. `powf` is vecmath's, Apple's
// libsystem_m routine, so the results are reproducible bit for bit.

import { powf } from "./vecmath";
import { applePow } from "./libm";
import { displayF32 } from "./fmt";

// sRGB (0-1) to linear.
export function srgbToLinear(c: f32): f32 {
    if (c <= <f32>0.04045) {
        return c / <f32>12.92;
    } else {
        return powf((c + <f32>0.055) / <f32>1.055, <f32>2.4);
    }
}

// Linear to sRGB (0-1); the formula of `linear_to_srgb` in the shaders.
export function linearToSrgb(c: f32): f32 {
    if (c <= <f32>0.0031308) return c * <f32>12.92;
    return <f32>1.055 * powf(c, <f32>1.0 / <f32>2.4) - <f32>0.055;
}

// The same conversions for stored color values (glTF color factors on export
// and import), computed in f64 and rounded once.
export function srgbToLinearValue(c: f32): f32 {
    const x = <f64>c;
    if (x <= 0.04045) return <f32>(x / 12.92);
    return <f32>applePow((x + 0.055) / 1.055, 2.4);
}

// The inverse of srgbToLinearValue: of the rounded conversion and its f32
// neighbours, the ones srgbToLinearValue maps back to `c` exactly, so an
// exported color imports as the value it was written from. Where two sRGB
// values share one linear f32 (the conversion is not one to one), the one
// with the shortest decimal form wins: it is the one a person typed.
export function linearToSrgbValue(c: f32): f32 {
    const x = <f64>c;
    const toe = <f32>(x * 12.92);
    const curve = <f32>(1.055 * applePow(x, 1.0 / 2.4) - 0.055);
    const r = x <= 0.0031308 ? toe : curve;
    if (!isFinite(r)) return r;
    const exact = new ShortestExact(c);
    // Near the branch point the f32 rounding of the sRGB value decides which
    // segment srgbToLinearValue took, so both segments' results are tried.
    exact.around(toe);
    exact.around(curve);
    return exact.found ? exact.best : r;
}

// The shortest-printing f32 that srgbToLinearValue maps to `target`.
class ShortestExact {
    target: f32;
    found: bool = false;
    best: f32 = 0;
    bestLen: i32 = 0;

    constructor(target: f32) {
        this.target = target;
    }

    // `v` and its two f32 neighbours on each side.
    around(v: f32): void {
        if (!isFinite(v)) return;
        const bits = <i32>reinterpret<u32>(v);
        for (let d: i32 = -2; d <= 2; d++) {
            const n = reinterpret<f32>(<u32>(bits + d));
            if (srgbToLinearValue(n) != this.target) continue;
            const len = displayF32(n).length;
            if (!this.found || len < this.bestLen) {
                this.found = true;
                this.best = n;
                this.bestLen = len;
            }
        }
    }
}
