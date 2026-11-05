// Float math that returns exactly what the macOS arm64 libm (libsystem_m)
// returns: f32 sin/cos/tan/asin/acos/atan/atan2/pow/exp/exp2/log/log2 and
// f64 sin/cos/pow/log2 (the f64 routines are at the end). Results are
// bit-identical on every platform, since wasm has no platform libm.
//
// Why not correctly rounded results (musl's f64 routine rounded to f32)?
// Apple's f32 routines are not correctly rounded: depending on the function
// they return the other neighbour of the exact value on 0.01% to 40% of the
// inputs (asinf(±1) = ±0x3fc90fda, atan2f(±0, x < 0) = ±0x40490fda, both one
// ulp below the nearest f32), and those ulps reach the goldens through Euler
// angles, bone rolls, UVs and camera framing. vecmath.as's `sinf`, `cosf`,
// … are these functions, so the rest of the code calls vecmath.
//
// Which routine to use for a sine or cosine:
//   * a lone sine or cosine: appleSinf / appleCosf (vecmath's sinf / cosf);
//   * a sine and a cosine of the same angle computed together, as in
//     vecmath's rotation constructors (Quat.fromRotation*, fromAxisAngle,
//     fromEuler, Mat3/Mat4.fromRotation*, perspective*, Vec2.fromAngle) and
//     sinCosf: appleSincosf (libsystem_m's `__sincosf_stret`), whose results
//     differ from sinf's / cosf's on some inputs;
//   * a sine or cosine of a compile-time constant: sinfConst / cosfConst
//     (the f64 routine rounded to f32).
//
// Method: each routine was disassembled with lldb from libsystem_m and its
// constants and tables read from the library. The originals evaluate in f64
// with FMA, which wasm lacks. Where an unfused step was shown to give the
// same f32 result on every input it is written unfused; where it was not
// (expf, exp2f, logf, powf and the f64 routines), the step goes through
// `fmaF64`, a correctly rounded FMA emulation. Every routine was checked
// against the real library (all 2^32 inputs of each one-argument f32
// function, 3e8 random and special pairs for atan2f and powf, 2e8 inputs of
// each f64 function); tests/core/base_libm_test.as pins hashes of the results.

import { f64ToI64, roundF64 } from "./util";

// f64 constants are written as bit patterns so no decimal parsing is involved.
@inline function d(bits: u64): f64 {
    return reinterpret<f64>(bits);
}

// ---------------------------------------------------------------------------
// FMA emulation

// `fma(a, b, c)`: a * b + c rounded once (Boldo & Melquiond, "Emulation of
// FMA and correctly rounded sums: proved algorithms using rounding to odd",
// 2008). The product is split exactly (Dekker), the high part is added to c
// exactly (TwoSum), the two low parts are summed rounded to odd, and the
// final addition rounds to nearest. Correct while no step overflows or
// underflows (|a|, |b| < 2^995, and the product's low part is normal), which
// holds for every call below; checked against the hardware FMA on 2.5e8
// random and near-cancelling triples.
export function fmaF64(a: f64, b: f64, c: f64): f64 {
    const C = 134217729.0; // 2^27 + 1
    const p = a * b;
    let t = C * a;
    const ah = t - (t - a);
    const al = a - ah;
    t = C * b;
    const bh = t - (t - b);
    const bl = b - bh;
    const pl = ((ah * bh - p) + ah * bl + al * bh) + al * bl;
    const th = c + p;
    let bb = th - c;
    const tl = (c - (th - bb)) + (p - bb);
    let v = tl + pl;
    bb = v - tl;
    const e = (tl - (v - bb)) + (pl - bb);
    if (e != 0.0 && (reinterpret<u64>(v) & 1) == 0) {
        // Round to odd: step to the neighbour on the side of the exact sum.
        let u = reinterpret<u64>(v);
        if ((e > 0.0) == (v > 0.0)) u++;
        else u--;
        v = reinterpret<f64>(u);
    }
    return th + v;
}

// `x - k * p` rounded once, as `fma(-k, p, x)` (Dekker two-product of k*p,
// then a compensated subtraction). Not a general FMA, but it matched the
// real sinf / cosf on all 2^32 inputs where the plain unfused form did not
// (12 inputs of sinf, 2 of cosf).
function fmaReduce(x: f64, k: f64, p: f64): f64 {
    const C = 134217729.0; // 2^27 + 1
    let t = C * p;
    const ph = t - (t - p);
    const pl = p - ph;
    t = C * k;
    const kh = t - (t - k);
    const kl = k - kh;
    const pr = k * p;
    const err = ((kh * ph - pr) + kh * pl + kl * ph) + kl * pl;
    const s = x - pr;
    const bb = s - x;
    const e2 = (x - (s - bb)) + (-pr - bb);
    return s + (e2 - err);
}

// ---------------------------------------------------------------------------
// __sincosf_stret, sinf, cosf

// Sine and cosine of one angle (libsystem_m `__sincosf_stret`).
export struct SinCos {
    s: f32 = 0;
    c: f32 = 0;

    constructor(s: f32, c: f32) {
        this.s = s;
        this.c = c;
    }
}

// Large-argument reduction table of __sincosf_stret, sinf and cosf, indexed
// by (|x| bits >> 24) - 0x40: pairs (hi, lo) of 2/PI scaled for that
// exponent range (the first 12 rows are never used by sincosf).
const SC_TABLE: StaticArray<u64> = [
    0x3fd45f306e000000, 0xbdeb1bbead603d8b, 0x3fd45f306e000000, 0xbdeb1bbead603d8b,
    0x3fd45f306e000000, 0xbdeb1bbead603d8b, 0x3fd45f306e000000, 0xbdeb1bbead603d8b,
    0x3fd45f306e000000, 0xbdeb1bbead603d8b, 0x3fd45f306e000000, 0xbdeb1bbead603d8b,
    0x3fd45f306e000000, 0xbdeb1bbead603d8b, 0x3fd45f306e000000, 0xbdeb1bbead603d8b,
    0x3fd45f306e000000, 0xbdeb1bbead603d8b, 0x3fd45f306e000000, 0xbdeb1bbead603d8b,
    0x3fd45f306e000000, 0xbdeb1bbead603d8b, 0x3fd45f306e000000, 0xbdeb1bbead603d8b,
    0xbfc7419f24000000, 0xbdeb1bbead603d8b, 0xbfad067c92000000, 0x3dc391054a7f09d6,
    0x3f77cc1b72000000, 0x3d9c882a53f84eb0, 0xbf6067c91b000000, 0xbd6bbead603d8a83,
    0xbf09f246c7000000, 0x3d0054a7f09d5f48, 0xbf09f246c7000000, 0x3d0054a7f09d5f48,
    0xbf09f246c7000000, 0x3d0054a7f09d5f48, 0x3ee836e4e4000000, 0x3d0054a7f09d5f48,
    0xbecf246c6f000000, 0x3ca529fc2757d1f5, 0x3e7b727221000000, 0xbc95ac07b1505c16,
    0x3e7b727221000000, 0xbc95ac07b1505c16, 0xbe5236377d000000, 0xbc76b01ec5417056,
    0x3e4b939105000000, 0x3c629fc2757d1f53, 0xbe21b1bbeb000000, 0x3c34fe13abe8fa9a,
    0xbdeb1bbead000000, 0xbc080f62a0b82b2d, 0xbdeb1bbead000000, 0xbc080f62a0b82b2d,
    0x3dc391054a000000, 0x3befc2757d1f534e, 0x3d9c882a54000000, 0xbb7ec54170565912,
    0xbd6bbead60000000, 0xbb7ec54170565912, 0xbd6bbead60000000, 0xbb7ec54170565912,
    0x3d41054a7f000000, 0x3b33abe8fa9a6ee0, 0x3d0054a7f1000000, 0xbb28a82e0acb223f,
    0x3d0054a7f1000000, 0xbb28a82e0acb223f, 0x3ca529fc27000000, 0x3ac5f47d4d377037,
    0x3ca529fc27000000, 0x3ac5f47d4d377037, 0x3ca529fc27000000, 0x3ac5f47d4d377037,
    0x3c84a7f09d000000, 0x3aa7d1f534ddc0db, 0x3c629fc275000000, 0x3a8f47d4d377036e,
    0x3c34fe13ac000000, 0xba370565911f924f, 0xbc2603d8a8000000, 0xba370565911f924f,
    0xbc080f62a1000000, 0x3a21f534ddc0db63, 0x3befc2757d000000, 0x39ef534ddc0db629,
    0xbb7ec54170000000, 0xb99596447e493ad5, 0xbb7ec54170000000, 0xb99596447e493ad5,
    0xbb7ec54170000000, 0xb99596447e493ad5, 0x3b33abe8fb000000, 0xb9596447e493ad4d,
    0x3b33abe8fb000000, 0xb9596447e493ad4d, 0xbb28a82e0b000000, 0x393a6ee06db14acd,
    0x3b0d5f47d5000000, 0xb916447e493ad4ce, 0xbad505c159000000, 0xb8f911f924eb5336,
    0x3ac5f47d4d000000, 0x38dbb81b6c52b328, 0x3aa7d1f535000000, 0xb8b11f924eb53362,
    0x3a8f47d4d3000000, 0x38adc0db6295993c, 0xba37056591000000, 0xb83f924eb53361de,
    0xba37056591000000, 0xb83f924eb53361de, 0x3a21f534de000000, 0xb83f924eb53361de,
    0x39ef534ddc000000, 0x37db6c52b3278872, 0x39ef534ddc000000, 0x37db6c52b3278872,
    0xb99596447e000000, 0xb7b24eb53361de38, 0xb99596447e000000, 0xb7b24eb53361de38,
    0x3984d37703000000, 0x37ab6295993c4390, 0x39634ddc0e000000, 0xb78275a99b0ef1bf,
];

// Sine and cosine of one angle computed together: libsystem_m `__sincosf_stret(x)`.
// Unfused; matched the library on all 2^32 inputs.
export function appleSincosf(x: f32): SinCos {
    const w = reinterpret<u32>(x) & 0x7fffffff;
    let f: f64;
    let q: i64;
    if (w >= 0x42f00000) {
        // |x| >= 120, inf, NaN.
        if (w >= 0x7f800000) {
            const n = x - x;
            return SinCos(n, n);
        }
        const d0 = <f64>x + <f64>x;
        const idx = <i32>(w >> 24) - 0x40;
        const d4 = d0 * reinterpret<f64>(unchecked(SC_TABLE[2 * idx]));
        const d5 = d0 * reinterpret<f64>(unchecked(SC_TABLE[2 * idx + 1]));
        const r = nearest<f64>(d4);
        q = f64ToI64(r); // saturates, like arm64 fcvtns
        f = (d4 - r) + d5;
    } else if (w < 0x39800000) {
        // |x| < 2^-12: sin = fma32(x, 2^26, x) * 2^-26 (exact in f64: 51 bits),
        // cos = (2^26 - |x|) * 2^-26.
        const scale = reinterpret<f32>(<u32>0x32800000); // 2^-26
        const c = (reinterpret<f32>(<u32>0x4c800000) - Mathf.abs(x)) * scale;
        const s = <f32>(<f64>x * 67108865.0) * scale;
        return SinCos(s, c);
    } else {
        const t = <f64>x * d(0x3fe45f306dc9c883); // 2/PI
        const r = nearest<f64>(t);
        q = <i64>r; // |t| < 77
        f = t - r;
    }
    const f2 = f * f;
    const a0 = f2 + d(0xc02c3d3ee4f8713f);
    const a1 = f2 + d(0xc020bc0396540c13);
    const a2 = f2 + d(0xc02ef09ab49e3a5b);
    const a3 = f2 + d(0xc02d6f5ade6c8c37);
    const p50 = d(0x40444921a30f0d80) + f2 * a0;
    const p51 = d(0x401d78212789bc11) + f2 * a1;
    const p60 = d(0x406e97264e36bd93) + f2 * a2;
    const p61 = d(0x4062c6b9c7f88fa0) + f2 * a3;
    let s = <f32>(((f * d(0x3f24bc899499342c)) * p50) * p60);
    let c = <f32>((d(0x3f4d9c364e9721d5) * p51) * p61);
    if ((q & 2) != 0) {
        s = -s;
        c = -c;
    }
    if ((q & 1) != 0) return SinCos(c, -s);
    return SinCos(s, c);
}

// sin(r) for |r| <= PI/4 (sinf / cosf, table at __sincosf_stret + 380).
function sinPoly(r: f64): f64 {
    const r2 = r * r;
    const r3 = r * r2;
    const a17 = r2 * d(0xbf29943e0fc4818f) + d(0x3f811073afd145eb);
    const r5 = r2 * r3;
    const a18 = r3 * d(0xbfc555545268a02a) + r;
    return r5 * a17 + a18;
}

// cos(r) for |r| <= PI/4 (table at __sincosf_stret + 348). The last step,
// `r2 * c + 1`, is the one FMA that must stay fused for cosf (see appleCosf);
// sinf rounds it unfused (`fused` false), which is what matched sinf.
function cosPoly(r: f64, fused: bool): f64 {
    const r2 = r * r;
    let c3 = r2 * d(0x3ef99169fc938f4a) + d(0xbf56c07f16945df4);
    const c5 = r2 * d(0x3fa55553c7899699) + d(0xbfdffffffcb82e97);
    const r4 = r2 * r2;
    c3 = r4 * c3 + c5;
    if (fused) return fmaReduce(1.0, -r2, c3); // fma(r2, c3, 1)
    return r2 * c3 + 1.0;
}

// The |x| >= 120 path shared by sinf and cosf (`bump` is 0.5 for cosf: a
// quarter turn added to the reduced argument).
function sinCosLarge(v: f64, w: u32, bump: f64): f32 {
    const idx = <i32>(w >> 24) - 0x40;
    const a = v * reinterpret<f64>(unchecked(SC_TABLE[2 * idx])) + bump;
    const b = v * reinterpret<f64>(unchecked(SC_TABLE[2 * idx + 1]));
    const k = nearest<f64>(a);
    const n = <u64>f64ToI64(k); // fcvtns saturates like f64ToI64
    const f = (a - k) + b;
    const f3 = reinterpret<f64>(reinterpret<u64>(f) ^ (n << 63));
    const f2 = f * f;
    const p4 = f2 + d(0xc010a8b9fc97b22c);
    const p5 = f2 + d(0xc00d31f4a0a55230);
    let p6 = f2 * p4 + d(0x402ef88f0b1250c1);
    let p7 = f2 * p5 + d(0x400537b6744fa779);
    p6 = f3 * p6;
    p7 = d(0x3fb39502de83d49c) * p7;
    return <f32>(p6 * p7);
}

// f32 sine when no cosine of the same angle is computed with it:
// libsystem_m `sinf(x)`. The medium-range reduction `x - k * PI/2` is an FMA
// in the original (fmaReduce); the rest is unfused. Matched the library on
// all 2^32 inputs.
export function appleSinf(x: f32): f32 {
    const w = reinterpret<u32>(x) & 0x7fffffff;
    if (w >= 0x42f00000) {
        if (w >= 0x7f800000) return x - x;
        return sinCosLarge(<f64>x, w, 0.0);
    }
    if (w < 0x3f490fdb) {
        if (w < 0x39800000) {
            // |x| < 2^-12: fma32(x, 2^26, x) * 2^-26.
            const t = x * reinterpret<f32>(<u32>0x4c800000) + x;
            return t * reinterpret<f32>(<u32>0x32800000);
        }
        return <f32>sinPoly(<f64>x);
    }
    const v = <f64>x;
    const k = nearest<f64>(v * d(0x3fe45f306dc9c883));
    const n = <u64>f64ToI64(k); // fcvtns (|t| < 77)
    const r = fmaReduce(v, k, d(0x3ff921fb54442d18));
    let res = (n & 1) != 0 ? cosPoly(r, false) : sinPoly(r);
    res = reinterpret<f64>(reinterpret<u64>(res) ^ ((n >> 1) << 63));
    return <f32>res;
}

// f32 cosine when no sine of the same angle is computed with it:
// libsystem_m `cosf(x)`: sinf's code run on |x| with the quadrant bumped by
// one. The reductions (one or two steps) and the cosine polynomial's last
// step are rounded once (fmaReduce), the rest is unfused. Matched the
// library on all 2^32 inputs (the fully unfused polynomial differs on
// x = ±0x410dbc83).
export function appleCosf(x: f32): f32 {
    const w = reinterpret<u32>(x) & 0x7fffffff;
    const v = <f64>reinterpret<f32>(w); // |x|
    let r: f64;
    let n: u64;
    if (w >= 0x42f00000) {
        if (w >= 0x4c800000) {
            // |x| >= 2^26, inf, NaN.
            if (w >= 0x7f800000) return x - x;
            return sinCosLarge(v, w, 0.5);
        }
        // 120 <= |x| < 2^26: two-step reduction by PI/2 (hi, lo).
        const k = nearest<f64>(v * d(0x3fe45f306dc9c883));
        n = <u64>f64ToI64(k) + 1;
        r = fmaReduce(v, k, d(0x3ff921fb54442d18));
        r = fmaReduce(r, k, d(0x3c91a62633145c07));
    } else if (w < 0x3f490fdb) {
        // |x| < 2^-12: (2^26 - |x|) * 2^-26 in f32.
        if (w < 0x39800000) {
            return (reinterpret<f32>(<u32>0x4c800000) - reinterpret<f32>(w)) * reinterpret<f32>(<u32>0x32800000);
        }
        return <f32>cosPoly(v, true); // |x| < PI/4
    } else {
        // PI/4 <= |x| < 120
        const k = nearest<f64>(v * d(0x3fe45f306dc9c883));
        n = <u64>f64ToI64(k) + 1;
        r = fmaReduce(v, k, d(0x3ff921fb54442d18));
    }
    let res = (n & 1) != 0 ? cosPoly(r, true) : sinPoly(r);
    res = reinterpret<f64>(reinterpret<u64>(res) ^ ((n >> 1) << 63));
    return <f32>res;
}

// Sine / cosine of a constant f32 angle: Apple's f64 `sin` / `cos` rounded
// to f32, which is what the recorded values hold for constant angles. Use it
// only at call sites whose golden tests expect it.
export function sinfConst(x: f32): f32 { return <f32>appleSin(<f64>x); }
export function cosfConst(x: f32): f32 { return <f32>appleCos(<f64>x); }

// ---------------------------------------------------------------------------
// tanf

// Large-argument reduction table of tanf, indexed by (|x| bits >> 24) - 0x4b:
// pairs (hi, lo) of 2/PI scaled for that exponent range.
const TAN_TABLE: StaticArray<u64> = [
    0x3fe45f306e000000, 0xbdfb1bbead603d8b, 0x3fc17cc1b7000000, 0x3dd391054a7f09d6,
    0x3f87cc1b72000000, 0x3dac882a53f84eb0, 0x3f87cc1b72000000, 0x3dac882a53f84eb0,
    0x3f6f306dca000000, 0xbd7bbead603d8a83, 0xbf19f246c7000000, 0x3d1054a7f09d5f48,
    0xbf19f246c7000000, 0x3d1054a7f09d5f48, 0x3ef836e4e4000000, 0x3d1054a7f09d5f48,
    0xbedf246c6f000000, 0x3cb529fc2757d1f5, 0x3e8b727221000000, 0xbca5ac07b1505c16,
    0x3e8b727221000000, 0xbca5ac07b1505c16, 0x3e8b727221000000, 0xbca5ac07b1505c16,
    0xbe6236377d000000, 0xbc86b01ec5417056, 0xbe31b1bbeb000000, 0x3c44fe13abe8fa9a,
    0x3e2c9c882a000000, 0x3c44fe13abe8fa9a, 0xbdfb1bbead000000, 0xbc180f62a0b82b2d,
    0x3dd391054a000000, 0x3bffc2757d1f534e, 0xbdc8ddf56b000000, 0xbb8ec54170565912,
    0x3dac882a54000000, 0xbb8ec54170565912, 0xbd7bbead60000000, 0xbb8ec54170565912,
    0x3d51054a7f000000, 0x3b43abe8fa9a6ee0, 0xbd4df56b02000000, 0x3b43abe8fa9a6ee0,
    0x3d1054a7f1000000, 0xbb38a82e0acb223f, 0xbd0f56b01f000000, 0x3b1d5f47d4d37703,
    0x3cb529fc27000000, 0x3ad5f47d4d377037, 0x3cb529fc27000000, 0x3ad5f47d4d377037,
    0xbca5ac07b1000000, 0xbac4170565911f92, 0xbc86b01ec5000000, 0xbaa05c1596447e49,
    0xbc6ac07b15000000, 0xba470565911f924f, 0x3c44fe13ac000000, 0xba470565911f924f,
    0x3c23f84eb0000000, 0xba470565911f924f, 0x3bffc2757d000000, 0x39ff534ddc0db629,
    0xbb8ec54170000000, 0xb9a596447e493ad5, 0xbb8ec54170000000, 0xb9a596447e493ad5,
    0xbb8ec54170000000, 0xb9a596447e493ad5, 0xbb8ec54170000000, 0xb9a596447e493ad5,
    0x3b43abe8fb000000, 0xb9696447e493ad4d, 0x3b43abe8fb000000, 0xb9696447e493ad4d,
    0x3b1d5f47d5000000, 0xb926447e493ad4ce, 0xbae505c159000000, 0xb90911f924eb5336,
    0xbae505c159000000, 0xb90911f924eb5336, 0xbac4170566000000, 0x38ebb81b6c52b328,
    0xbaa05c1596000000, 0xb8c11f924eb53362, 0xba47056591000000, 0xb84f924eb53361de,
    0xba47056591000000, 0xb84f924eb53361de, 0xba47056591000000, 0xb84f924eb53361de,
    0xba2c159644000000, 0xb84f924eb53361de, 0x39ff534ddc000000, 0x37eb6c52b3278872,
    0xb9a596447e000000, 0xb7c24eb53361de38, 0xb9a596447e000000, 0xb7c24eb53361de38,
    0xb9a596447e000000, 0xb7c24eb53361de38, 0xb9865911f9000000, 0xb79275a99b0ef1bf,
    0xb9696447e5000000, 0x378b14acc9e21c82,
];

// f32 tangent: libsystem_m `tanf(x)`. Unfused; matched the library
// on all 2^32 inputs.
export function appleTanf(x: f32): f32 {
    const w = reinterpret<u32>(x) & 0x7fffffff;
    let r: f64;
    let n: u32;
    if (w >= 0x4c800000) {
        if (w >= 0x7f800000) return x - x; // inf or NaN
        // |x| >= 2^26: reduce with the table; n is the low word of the
        // rounded quotient (1.5 * 2^52 added).
        const v = <f64>x;
        const idx = <i32>(w >> 24) - 0x4b;
        let a = v * reinterpret<f64>(unchecked(TAN_TABLE[2 * idx]));
        const b = v * reinterpret<f64>(unchecked(TAN_TABLE[2 * idx + 1]));
        let t = a + d(0x4338000000000000);
        n = <u32>reinterpret<u64>(t);
        t = t - d(0x4338000000000000);
        a = a - t;
        r = a + b;
    } else if (w >= 0x3f490fdb) {
        // PI/4 <= |x| < 2^26: x * 2/PI minus the nearest integer (ties even).
        const v = <f64>x;
        let t = v * d(0x3fe45f306e000000);
        const k = nearest<f64>(t);
        n = <u32>f64ToI64(k); // fcvtns (|t| < 2^26)
        t = t - k;
        r = v * d(0xbdfb1bbead603d8b) + t;
    } else if (w >= 0x39800000) {
        // 2^-12 <= |x| < PI/4: x + x^3 * P(x^2).
        const v = <f64>x;
        const v2 = v * v;
        let a6 = v2 * d(0x3f51e9c887f6c8a1) + d(0x3f8487da95c9f173);
        const a16 = v2 * d(0x3f961eb51f86747c) + d(0x3faba586a7f44ae7);
        let a18 = v2 * d(0x3fc1110746e09b07) + d(0x3fd555555d8d8930);
        const v4 = v2 * v2;
        a6 = v4 * d(0x3f6fe5da804efbdc) + a6;
        a18 = v4 * a16 + a18;
        const v8 = v4 * v4;
        a18 = v8 * a6 + a18;
        const q = v2 * a18;
        return <f32>(v * q + v);
    } else {
        // |x| < 2^-12: fma32(x, 2^26, x) * 2^-26 (exact in f64).
        return <f32>(<f64>x * 67108865.0) * reinterpret<f32>(<u32>0x32800000);
    }
    // tan of the reduced argument r (in quarter turns), -1/tan for odd n.
    const r2 = r * r;
    let p5 = r2 * d(0x40151d4a014005d8) + d(0x400e91f74c2eeaab);
    const p6 = r2 + d(0xbfd609394a49adf1);
    const p7 = r2 + d(0xbff88f856cde0b64);
    const p16 = r2 + d(0x3fed3764811481d2);
    p5 = r * p5;
    const p17 = r2 * p6 + d(0x3fe81ba4203c502d);
    let p18 = r2 * p7 + d(0x3fedb0d5be6b368b);
    const p19 = r2 * p16 + d(0x3fe2d17a5cc6b70b);
    p5 = p5 * p17;
    p18 = p18 * p19;
    let res = p5 * p18;
    if ((n & 1) != 0) res = d(0xbff0000000000000) / res;
    return <f32>res;
}

// ---------------------------------------------------------------------------
// asinf, acosf

// asin(x) for |x| <= 0.5 as x + x * x^2 * P(x^2), in f64 (shared by asinf and
// acosf's middle range).
function asinPoly(dx: f64): f64 {
    const x2 = dx * dx;
    const p3 = d(0x3f9169f766637e01) + x2 * d(0x3fa15e1a450e8b98);
    let p5 = d(0x3fa6d55e6da5eec2) + x2 * d(0x3f9fe10bae9583ba);
    let p7 = d(0x3fc555554d58f2f9) + x2 * d(0x3fb3334481d0bc2f);
    const x4 = x2 * x2;
    p5 = p5 + x4 * p3;
    p7 = p7 + x4 * p5;
    const t = x2 * p7;
    return dx + dx * t;
}

// The factor q(w) of acos(1 - w) = q(w) * sqrt(w) (|x| > 0.5, w = 1 - |x|).
function acosSqrtPoly(w: f64): f64 {
    const p3 = d(0x3f6140186da86810) + w * d(0x3f5ee93cb2957053);
    let p5 = d(0x3f9b21ec14e82132) + w * d(0x3f807e5fa0a35d8b);
    let p7 = d(0x3ff6a09e64c7c6e1) + w * d(0x3fbe2b8cc3173f9e);
    const w2 = w * w;
    p5 = p5 + w2 * p3;
    p7 = p7 + w2 * p5;
    return p7;
}

// f32 arcsine: libsystem_m `asinf(x)`. Unfused; matched the
// library on all 2^32 inputs. asinf(±1) is ±0x3fc90fda (PI/2 rounded down),
// not the nearest f32.
export function appleAsinf(x: f32): f32 {
    const ax = Mathf.abs(x);
    const neg = (reinterpret<u32>(x) >> 31) != 0;
    if (!(ax < <f32>1.0)) {
        if (ax == <f32>1.0) {
            const r = <f32>d(0x3ff921fb44000000);
            return neg ? -r : r;
        }
        return isNaN(x) ? x + x : <f32>NaN; // NaN, or |x| > 1
    }
    if (ax > <f32>0.5) {
        const w = <f64>(<f32>1.0 - ax); // exact
        const r = <f32>(d(0x3ff921fb54442d18) - acosSqrtPoly(w) * Math.sqrt(w));
        return neg ? -r : r;
    }
    if (ax >= reinterpret<f32>(<u32>0x32000000)) {
        return <f32>asinPoly(<f64>x); // 2^-27 <= |x| <= 0.5
    }
    // |x| < 2^-27: fma32(x, 2^27, x) * 2^-27 (x * (2^27 + 1) is exact in f64).
    return <f32>(<f64>x * 134217729.0) * reinterpret<f32>(<u32>0x32000000);
}

// f32 arccosine: libsystem_m `acosf(x)`. It shares asinf's
// polynomials. Unfused; matched the library on all 2^32 inputs. acosf(-1) is
// 0x40490fda (PI rounded down), so `PI - acos(-1)` is 2.4e-7, not 0.
export function appleAcosf(x: f32): f32 {
    const ax = Mathf.abs(x);
    if (!(ax < <f32>1.0)) {
        if (ax == <f32>1.0) {
            return x > <f32>0.0 ? <f32>0.0 : <f32>d(0x400921fb44000000);
        }
        if (isNaN(x)) return x - x;
        return <f32>NaN; // |x| > 1: inf - inf
    }
    if (ax > <f32>0.5) {
        const w = <f64>(<f32>1.0 - ax); // exact
        const t = acosSqrtPoly(w) * Math.sqrt(w);
        if (x > <f32>0.0) return <f32>t;
        return <f32>(d(0x400921fb54442d18) - t);
    }
    if (ax >= reinterpret<f32>(<u32>0x3b000000)) {
        // 2^-9 <= |x| <= 0.5: PI/2 - asin(x).
        return <f32>(d(0x3ff921fb54442d18) - asinPoly(<f64>x));
    }
    // |x| < 2^-9
    return <f32>(d(0x3ff921fb54442d18) - <f64>x);
}

// ---------------------------------------------------------------------------
// atanf, atan2f

@inline function withSignOf(r: f32, x: f32): f32 {
    return reinterpret<f32>((reinterpret<u32>(r) & 0x7fffffff) | (reinterpret<u32>(x) & 0x80000000));
}

// atan(r) for |r| <= 1: C * r * product of four quadratics in r^2 (atanf's
// and atan2f's shared polynomial).
function atanPoly(r: f64): f64 {
    const r2 = r * r;
    const pa1 = d(0x40038f4c070b63c1) + (r2 + d(0x4002609372076e2c)) * r2;
    const pb1 = d(0x4015e43168d7c2b6) + (r2 + d(0xc00792d5bf17c0bc)) * r2;
    const pa3 = d(0x400e4fa479729042) + (r2 + d(0x3f953db49b9fcf6b)) * r2;
    const pb3 = d(0x401ae0fb08f2dc00) + (r2 + d(0xc013e370146726b3)) * r2;
    return ((pa1 * pa3) * d(0x3f680bc0fe23203d)) * ((pb1 * pb3) * r);
}

// f32 arctangent: libsystem_m `atanf(x)`. Unfused; matched the
// library on all 2^32 inputs.
export function appleAtanf(x: f32): f32 {
    const ax = Mathf.abs(x);
    if (ax >= reinterpret<f32>(<u32>0x4ae1e273)) {
        // PI/2 rounded down to f32 (0x3fc90fda), with x's sign.
        return withSignOf(<f32>d(0x3ff921fb44000000), x);
    }
    if (isNaN(x)) return x - x;
    if (ax > <f32>1.0) {
        // PI/2 - atan(1/|x|), as (1/|x|)^17 times a polynomial in x^2.
        let d1 = <f64>ax;
        let d0 = 1.0 / d1;
        d1 = d1 * d1;
        let d30 = d0 * d0;
        const d2 = d1 + d(0x3fed6b74d6295266);
        const d3 = d1 + d(0xbf75505d3cf68fb0);
        const d4 = d1 + d(0xbfe0dfcb5ed76ca4);
        const d5 = d1 + d(0xbfe70baa17f25493);
        d30 = d30 * d30;
        let d6 = d1 * d2 + d(0x3fd98dc25f02f8e9);
        const d7 = d1 * d3 + d(0x3fd022d8b8d718a9);
        let d16 = d1 * d4 + d(0x3fc626645186b1ce);
        const d17 = d1 * d5 + d(0x3fc207f5efa5231d);
        d6 = d6 * d7;
        d30 = d30 * d30;
        d16 = d16 * d17;
        d30 = d30 * d30;
        d6 = d6 * d16;
        d0 = d0 * d6;
        d0 = d(0x3ff921fb54442d18) - d0 * d30;
        return withSignOf(<f32>d0, x);
    }
    if (ax >= reinterpret<f32>(<u32>0x32000000)) {
        // 2^-27 <= |x| <= 1: x * C * product of four quadratics in x^2.
        let d0 = <f64>x;
        const d1 = d0 * d0;
        const d2 = d1 + d(0x4002609372076e2c);
        const d3 = d1 + d(0x3f953db49b9fcf6b);
        const d4 = d1 + d(0xc00792d5bf17c0bc);
        const d5 = d1 + d(0xc013e370146726b3);
        let d6 = d1 * d2 + d(0x40038f4c070b63c1);
        const d7 = d1 * d3 + d(0x400e4fa479729042);
        let d16 = d1 * d4 + d(0x4015e43168d7c2b6);
        const d17 = d1 * d5 + d(0x401ae0fb08f2dc00);
        d6 = d6 * d7;
        d16 = d16 * d17;
        d0 = d0 * d(0x3f680bc0fe23203d);
        d6 = d6 * d16;
        d0 = d0 * d6;
        return <f32>d0;
    }
    // |x| < 2^-27: fma32(x, 2^27, x) * 2^-27 (x * (2^27 + 1) is exact in f64).
    return <f32>(<f64>x * 134217729.0) * reinterpret<f32>(<u32>0x32000000);
}

// f32 two-argument arctangent: libsystem_m `atan2f(y, x)`. Unfused; matched the
// library on 3e8 random and special pairs. atan2f(±0, x < 0) and tiny
// |y/x| with x < 0 give ±0x40490fda (PI rounded down), not the nearest f32.
export function appleAtan2f(y: f32, x: f32): f32 {
    const PI_2 = d(0x3ff921fb54442d18);
    const PI_4 = d(0x3fe921fb54442d18);
    const PI_3_4 = d(0x4002d97c7f3321d2);
    // Just below PI as f32 (0x40490fda).
    const PI_LOW = d(0x400921fb40080000);
    if (y < x) {
        if (-x < y) return <f32>atanPoly(<f64>y / <f64>x); // x > |y|
        if (-x == y) return <f32>(-PI_4);
        return <f32>(-PI_2 - atanPoly(<f64>x / <f64>y)); // y < -|x|
    }
    if (y == x) {
        if (y < 0) return <f32>(-PI_3_4);
        if (y == 0) {
            if ((reinterpret<u32>(x) >> 31) == 0) return y; // atan2(±0, +0)
            return <f32>(reinterpret<i32>(y) < 0 ? -PI_LOW : PI_LOW);
        }
        return <f32>PI_4;
    }
    if (isNaN(y) || isNaN(x)) return y + x;
    // y > x
    if (-x < y) return <f32>(PI_2 - atanPoly(<f64>x / <f64>y)); // y > |x|
    if (-x == y) return <f32>PI_3_4;
    // x < -|y|
    const r = <f64>y / <f64>x;
    if (Math.abs(r) < d(0x3e90000000000000)) {
        // |y/x| < 2^-22
        return <f32>(reinterpret<i32>(y) < 0 ? -PI_LOW : PI_LOW);
    }
    const pi = d(0x400921fb54442d18);
    return <f32>(atanPoly(r) + ((reinterpret<u32>(y) >> 31) != 0 ? -pi : pi));
}

// ---------------------------------------------------------------------------
// expf, powf (shared exp2 step)

// 2^(i/128) with i << 45 subtracted from the bits (it is added back with the
// exponent): libsystem_m's table shared by expf and powf.
const EXP2_TABLE: StaticArray<u64> = [
    0x3ff0000000000000, 0x3feff63da9fb3335, 0x3fefec9a3e778061, 0x3fefe315e86e7f85,
    0x3fefd9b0d3158574, 0x3fefd06b29ddf6de, 0x3fefc74518759bc8, 0x3fefbe3ecac6f383,
    0x3fefb5586cf9890f, 0x3fefac922b7247f7, 0x3fefa3ec32d3d1a2, 0x3fef9b66affed31b,
    0x3fef9301d0125b51, 0x3fef8abdc06c31cc, 0x3fef829aaea92de0, 0x3fef7a98c8a58e51,
    0x3fef72b83c7d517b, 0x3fef6af9388c8dea, 0x3fef635beb6fcb75, 0x3fef5be084045cd4,
    0x3fef54873168b9aa, 0x3fef4d5022fcd91d, 0x3fef463b88628cd6, 0x3fef3f49917ddc96,
    0x3fef387a6e756238, 0x3fef31ce4fb2a63f, 0x3fef2b4565e27cdd, 0x3fef24dfe1f56381,
    0x3fef1e9df51fdee1, 0x3fef187fd0dad990, 0x3fef1285a6e4030b, 0x3fef0cafa93e2f56,
    0x3fef06fe0a31b715, 0x3fef0170fc4cd831, 0x3feefc08b26416ff, 0x3feef6c55f929ff1,
    0x3feef1a7373aa9cb, 0x3feeecae6d05d866, 0x3feee7db34e59ff7, 0x3feee32dc313a8e5,
    0x3feedea64c123422, 0x3feeda4504ac801c, 0x3feed60a21f72e2a, 0x3feed1f5d950a897,
    0x3feece086061892d, 0x3feeca41ed1d0057, 0x3feec6a2b5c13cd0, 0x3feec32af0d7d3de,
    0x3feebfdad5362a27, 0x3feebcb299fddd0d, 0x3feeb9b2769d2ca7, 0x3feeb6daa2cf6642,
    0x3feeb42b569d4f82, 0x3feeb1a4ca5d920f, 0x3feeaf4736b527da, 0x3feead12d497c7fd,
    0x3feeab07dd485429, 0x3feea9268a5946b7, 0x3feea76f15ad2148, 0x3feea5e1b976dc09,
    0x3feea47eb03a5585, 0x3feea34634ccc320, 0x3feea23882552225, 0x3feea155d44ca973,
    0x3feea09e667f3bcd, 0x3feea012750bdabf, 0x3fee9fb23c651a2f, 0x3fee9f7df9519484,
    0x3fee9f75e8ec5f74, 0x3fee9f9a48a58174, 0x3fee9feb564267c9, 0x3feea0694fde5d3f,
    0x3feea11473eb0187, 0x3feea1ed0130c132, 0x3feea2f336cf4e62, 0x3feea427543e1a12,
    0x3feea589994cce13, 0x3feea71a4623c7ad, 0x3feea8d99b4492ed, 0x3feeaac7d98a6699,
    0x3feeace5422aa0db, 0x3feeaf3216b5448c, 0x3feeb1ae99157736, 0x3feeb45b0b91ffc6,
    0x3feeb737b0cdc5e5, 0x3feeba44cbc8520f, 0x3feebd829fde4e50, 0x3feec0f170ca07ba,
    0x3feec49182a3f090, 0x3feec86319e32323, 0x3feecc667b5de565, 0x3feed09bec4a2d33,
    0x3feed503b23e255d, 0x3feed99e1330b358, 0x3feede6b5579fdbf, 0x3feee36bbfd3f37a,
    0x3feee89f995ad3ad, 0x3feeee07298db666, 0x3feef3a2b84f15fb, 0x3feef9728de5593a,
    0x3feeff76f2fb5e47, 0x3fef05b030a1064a, 0x3fef0c1e904bc1d2, 0x3fef12c25bd71e09,
    0x3fef199bdd85529c, 0x3fef20ab5fffd07a, 0x3fef27f12e57d14b, 0x3fef2f6d9406e7b5,
    0x3fef3720dcef9069, 0x3fef3f0b555dc3fa, 0x3fef472d4a07897c, 0x3fef4f87080d89f2,
    0x3fef5818dcfba487, 0x3fef60e316c98398, 0x3fef69e603db3285, 0x3fef7321f301b460,
    0x3fef7c97337b9b5f, 0x3fef864614f5a129, 0x3fef902ee78b3ff6, 0x3fef9a51fbc74c83,
    0x3fefa4afa2a490da, 0x3fefaf482d8e67f1, 0x3fefba1bee615a27, 0x3fefc52b376bba97,
    0x3fefd0765b6e4540, 0x3fefdbfdad9cbe14, 0x3fefe7c1819e90d8, 0x3feff3c22b8f71f1,
];

// s * (1 + r * (c1 + r * c0)) with s = 2^(k/128) built from the low bits of
// `ki` (the table index) and `ki << 45` (the exponent): expf and powf pass r
// in 1/128 units (c1 = ln 2 / 128), exp2f passes it unscaled (c1 = ln 2).
function exp2Table(ki: u64, r: f64, c0: f64, c1: f64): f64 {
    const s = reinterpret<f64>(unchecked(EXP2_TABLE[<i32>(ki & 127)]) + (ki << 45));
    let p = fmaF64(c0, r, c1);
    p = p * r;
    return fmaF64(p, s, s);
}

// 2^((k + r) / 128), |r| <= 1/2 (expf, powf).
function exp2Scaled(ki: u64, r: f64): f64 {
    return exp2Table(ki, r, d(0x3eeebfbdff30d656), d(0x3f762e4453e10dae));
}

// The |x| >= 128 (expf) or 256 (exp2f) path: overflow to inf, underflow to
// +0, NaN kept.
function expSpecial(x: f32, ix: u32): f32 {
    if (!(x < <f32>0.0)) return x * reinterpret<f32>(<u32>0x7f7fffff); // inf, NaN
    // -inf gives 0 * 0, anything else 2^-126 * 2^-126 (underflow to +0).
    const t = ix >= 0xff800000 ? <f32>0.0 : reinterpret<f32>(<u32>0x00800000);
    return t * t;
}

// f32 e^x: libsystem_m `expf(x)` (128-entry exp2 table and a
// degree-2 polynomial; the four FMAs are emulated). Matched the library on
// all 2^32 inputs.
export function appleExpf(x: f32): f32 {
    const ix = reinterpret<u32>(x);
    if (((ix >> 23) & 0xff) >= 0x86) return expSpecial(x, ix); // |x| >= 128, inf, NaN
    const xd = <f64>x;
    const INV_LN2_N = d(0x40671547652b82fe); // 128 / ln 2
    const SHIFT = d(0x4338000000000000); // 1.5 * 2^52
    const z = fmaF64(INV_LN2_N, xd, SHIFT);
    const ki = reinterpret<u64>(z);
    const kd = z - SHIFT;
    const r = fmaF64(INV_LN2_N, xd, -kd);
    return <f32>exp2Scaled(ki, r);
}

// f32 2^x, also used for pow(2, x) (anim/easing's expo and elastic
// curves): libsystem_m `exp2f(x)`, expf's
// table and polynomial on x rounded to 1/128. Matched the library on all
// 2^32 inputs.
export function appleExp2f(x: f32): f32 {
    const ix = reinterpret<u32>(x);
    if (((ix >> 23) & 0xff) >= 0x87) return expSpecial(x, ix); // |x| >= 256, inf, NaN
    const xd = <f64>x;
    const SHIFT = d(0x42c8000000000000); // 1.5 * 2^45: rounds to 1/128
    const kz = xd + SHIFT;
    const kd = kz - SHIFT;
    const r = xd - kd; // exact
    return <f32>exp2Table(reinterpret<u64>(kz), r, d(0x3fcebfbdff30d656), d(0x3fe62e4453e10dae));
}

// ---------------------------------------------------------------------------
// logf

// 129 pairs (1/c, ln c) for the mantissa split by `(m + 2^15) >> 16`; from
// index 64 on, ln c has ln 2 taken off (the exponent is bumped there).
const LOGF_TABLE: StaticArray<u64> = [
    0x3ff0000000000000, 0x0000000000000000, 0x3fefc07f01fc07f0, 0x3f7fe02a6b106789,
    0x3fef81f81f81f820, 0x3f8fc0a8b0fc03e4, 0x3fef44659e4a4271, 0x3f97b91b07d5b11b,
    0x3fef07c1f07c1f08, 0x3f9f829b0e783300, 0x3feecc07b301ecc0, 0x3fa39e87b9febd60,
    0x3fee9131abf0b767, 0x3fa77458f632dcfc, 0x3fee573ac901e574, 0x3fab42dd711971bf,
    0x3fee1e1e1e1e1e1e, 0x3faf0a30c01162a6, 0x3fede5d6e3f8868a, 0x3fb16536eea37ae1,
    0x3fedae6076b981db, 0x3fb341d7961bd1d1, 0x3fed77b654b82c34, 0x3fb51b073f06183f,
    0x3fed41d41d41d41d, 0x3fb6f0d28ae56b4c, 0x3fed0cb58f6ec074, 0x3fb8c345d6319b21,
    0x3fecd85689039b0b, 0x3fba926d3a4ad563, 0x3feca4b3055ee191, 0x3fbc5e548f5bc743,
    0x3fec71c71c71c71c, 0x3fbe27076e2af2e6, 0x3fec3f8f01c3f8f0, 0x3fbfec9131dbeabb,
    0x3fec0e070381c0e0, 0x3fc0d77e7cd08e59, 0x3febdd2b899406f7, 0x3fc1b72ad52f67a0,
    0x3febacf914c1bad0, 0x3fc29552f81ff523, 0x3feb7d6c3dda338b, 0x3fc371fc201e8f74,
    0x3feb4e81b4e81b4f, 0x3fc44d2b6ccb7d1e, 0x3feb2036406c80d9, 0x3fc526e5e3a1b438,
    0x3feaf286bca1af28, 0x3fc5ff3070a793d4, 0x3feac5701ac5701b, 0x3fc6d60fe719d21d,
    0x3fea98ef606a63be, 0x3fc7ab890210d909, 0x3fea6d01a6d01a6d, 0x3fc87fa06520c911,
    0x3fea41a41a41a41a, 0x3fc9525a9cf456b4, 0x3fea16d3f97a4b02, 0x3fca23bc1fe2b563,
    0x3fe9ec8e951033d9, 0x3fcaf3c94e80bff3, 0x3fe9c2d14ee4a102, 0x3fcbc286742d8cd6,
    0x3fe999999999999a, 0x3fcc8ff7c79a9a22, 0x3fe970e4f80cb872, 0x3fcd5c216b4fbb91,
    0x3fe948b0fcd6e9e0, 0x3fce27076e2af2e6, 0x3fe920fb49d0e229, 0x3fcef0adcbdc5936,
    0x3fe8f9c18f9c18fa, 0x3fcfb9186d5e3e2b, 0x3fe8d3018d3018d3, 0x3fd0402594b4d041,
    0x3fe8acb90f6bf3aa, 0x3fd0a324e27390e3, 0x3fe886e5f0abb04a, 0x3fd1058bf9ae4ad5,
    0x3fe8618618618618, 0x3fd1675cababa60e, 0x3fe83c977ab2bedd, 0x3fd1c898c16999fb,
    0x3fe8181818181818, 0x3fd22941fbcf7966, 0x3fe7f405fd017f40, 0x3fd2895a13de86a3,
    0x3fe7d05f417d05f4, 0x3fd2e8e2bae11d31, 0x3fe7ad2208e0ecc3, 0x3fd347dd9a987d55,
    0x3fe78a4c8178a4c8, 0x3fd3a64c556945ea, 0x3fe767dce434a9b1, 0x3fd404308686a7e4,
    0x3fe745d1745d1746, 0x3fd4618bc21c5ec2, 0x3fe724287f46debc, 0x3fd4be5f957778a1,
    0x3fe702e05c0b8170, 0x3fd51aad872df82d, 0x3fe6e1f76b4337c7, 0x3fd5767717455a6c,
    0x3fe6c16c16c16c17, 0x3fd5d1bdbf5809ca, 0x3fe6a13cd1537290, 0x3fd62c82f2b9c795,
    0x3fe6816816816817, 0x3fd686c81e9b14af, 0x3fe661ec6a5122f9, 0x3fd6e08eaa2ba1e4,
    0x3fe642c8590b2164, 0x3fd739d7f6bbd007, 0x3fe623fa77016240, 0x3fd792a55fdd47a2,
    0x3fe6058160581606, 0x3fd7eaf83b82afc3, 0x3fe5e75bb8d015e7, 0x3fd842d1da1e8b17,
    0x3fe5c9882b931057, 0x3fd89a3386c1425b, 0x3fe5ac056b015ac0, 0x3fd8f11e873662c7,
    0x3fe58ed2308158ed, 0x3fd947941c2116fb, 0x3fe571ed3c506b3a, 0x3fd99d958117e08b,
    0x3fe5555555555555, 0xbfd269621134db92, 0x3fe5390948f40feb, 0xbfd214456d0eb8d4,
    0x3fe51d07eae2f815, 0xbfd1bf99635a6b95, 0x3fe5015015015015, 0xbfd16b5ccbacfb73,
    0x3fe4e5e0a72f0539, 0xbfd1178e8227e47c, 0x3fe4cab88725af6e, 0xbfd0c42d676162e3,
    0x3fe4afd6a052bf5b, 0xbfd07138604d5862, 0x3fe49539e3b2d067, 0xbfd01eae5626c691,
    0x3fe47ae147ae147b, 0xbfcf991c6cb3b379, 0x3fe460cbc7f5cf9a, 0xbfcef5ade4dcffe6,
    0x3fe446f86562d9fb, 0xbfce530effe71012, 0x3fe42d6625d51f87, 0xbfcdb13db0d48940,
    0x3fe4141414141414, 0xbfcd1037f2655e7b, 0x3fe3fb013fb013fb, 0xbfcc6ffbc6f00f71,
    0x3fe3e22cbce4a902, 0xbfcbd087383bd8ad, 0x3fe3c995a47babe7, 0xbfcb31d8575bce3d,
    0x3fe3b13b13b13b14, 0xbfca93ed3c8ad9e3, 0x3fe3991c2c187f63, 0xbfc9f6c407089664,
    0x3fe3813813813814, 0xbfc95a5adcf7017f, 0x3fe3698df3de0748, 0xbfc8beafeb38fe8c,
    0x3fe3521cfb2b78c1, 0xbfc823c16551a3c2, 0x3fe33ae45b57bcb2, 0xbfc7898d85444c73,
    0x3fe323e34a2b10bf, 0xbfc6f0128b756abc, 0x3fe30d190130d190, 0xbfc6574ebe8c133a,
    0x3fe2f684bda12f68, 0xbfc5bf406b543db2, 0x3fe2e025c04b8097, 0xbfc527e5e4a1b58d,
    0x3fe2c9fb4d812ca0, 0xbfc4913d8333b561, 0x3fe2b404ad012b40, 0xbfc3fb45a59928cc,
    0x3fe29e4129e4129e, 0xbfc365fcb0159016, 0x3fe288b01288b013, 0xbfc2d1610c86813a,
    0x3fe27350b8812735, 0xbfc23d712a49c202, 0x3fe25e22708092f1, 0xbfc1aa2b7e23f72a,
    0x3fe2492492492492, 0xbfc1178e8227e47c, 0x3fe23456789abcdf, 0xbfc08598b59e3a07,
    0x3fe21fb78121fb78, 0xbfbfe89139dbd566, 0x3fe20b470c67c0d9, 0xbfbec739830a1120,
    0x3fe1f7047dc11f70, 0xbfbda727638446a2, 0x3fe1e2ef3b3fb874, 0xbfbc885801bc4b23,
    0x3fe1cf06ada2811d, 0xbfbb6ac88dad5b1c, 0x3fe1bb4a4046ed29, 0xbfba4e7640b1bc38,
    0x3fe1a7b9611a7b96, 0xbfb9335e5d594989, 0x3fe19453808ca29c, 0xbfb8197e2f40e3f0,
    0x3fe1811811811812, 0xbfb700d30aeac0e1, 0x3fe16e0689427379, 0xbfb5e95a4d9791cb,
    0x3fe15b1e5f75270d, 0xbfb4d3115d207eac, 0x3fe1485f0e0acd3b, 0xbfb3bdf5a7d1ee64,
    0x3fe135c81135c811, 0xbfb2aa04a44717a5, 0x3fe12358e75d3033, 0xbfb1973bd1465567,
    0x3fe1111111111111, 0xbfb08598b59e3a07, 0x3fe0fef010fef011, 0xbfaeea31c006b87c,
    0x3fe0ecf56be69c90, 0xbfaccb73cdddb2cc, 0x3fe0db20a88f4696, 0xbfaaaef2d0fb10fc,
    0x3fe0c9714fbcda3b, 0xbfa894aa149fb343, 0x3fe0b7e6ec259dc8, 0xbfa67c94f2d4bb58,
    0x3fe0a6810a6810a7, 0xbfa466aed42de3ea, 0x3fe0953f39010954, 0xbfa252f32f8d183f,
    0x3fe0842108421084, 0xbfa0415d89e74444, 0x3fe073260a47f7c6, 0xbf9c63d2ec14aaf2,
    0x3fe0624dd2f1a9fc, 0xbf98492528c8cabf, 0x3fe05197f7d73404, 0xbf9432a925980cc1,
    0x3fe0410410410410, 0xbf90205658935847, 0x3fe03091b51f5e1a, 0xbf882448a388a2aa,
    0x3fe0204081020408, 0xbf8010157588de71, 0x3fe0101010101010, 0xbf70080559588b35,
    0x3fe0000000000000, 0x0000000000000000,
];

// f32 natural log: libsystem_m `logf(x)` (129-entry table and a
// degree-3 polynomial; the five FMAs are emulated). Matched the library on
// all 2^32 inputs (unfused, it differs on one).
export function appleLogf(x: f32): f32 {
    let ix = reinterpret<u32>(x);
    if (ix - 0x800000 >= 0x7f000000) {
        // Zero, subnormal, negative, inf or NaN.
        if (isNaN(x)) return x;
        if (x == <f32>0.0) return <f32>-Infinity;
        if (x < <f32>0.0) return reinterpret<f32>(<u32>0x7fc00000); // inf - inf on arm64
        if (<i32>(ix - 0x800000) >= 0) return x; // +inf
        // Subnormal: scale by 2^126 exactly (1 + m - 1), then take 126 off
        // the exponent field (it may wrap below zero; the shift below is signed).
        const s = reinterpret<f32>(ix | 0x3f800000) - <f32>1.0;
        ix = reinterpret<u32>(s) - 0x3f000000;
    }
    const i = <i32>(((ix & 0x7fffff) + 0x8000) >> 16);
    const z = reinterpret<f64>((<u64>ix | 0x1ff800000) << 29); // 1.m in [1, 2)
    const invc = reinterpret<f64>(unchecked(LOGF_TABLE[2 * i]));
    const logc = reinterpret<f64>(unchecked(LOGF_TABLE[2 * i + 1]));
    const r = fmaF64(z, invc, -1.0);
    const e = <f64>(<i32>(ix - 0x3f3f8000) >> 23);
    const r2 = r * r;
    let y = fmaF64(e, d(0x3fe62e42fefa39ef), logc); // e * ln 2 + ln c
    const p = fmaF64(r, d(0x3fd55561555ccbad), d(0xbfe00006000349d2));
    y = fmaF64(r, d(0x3fefffffffff6666), y);
    y = fmaF64(r2, p, y);
    return <f32>y;
}

// ---------------------------------------------------------------------------
// log2f

// 65 pairs (c, l) for m in [1, 2) split into 64 intervals by
// `(mantissa + 2^16) >> 17`: c ~ 1 / (1 + i/64) and l = -log2(c), minus 1
// from index 32 on (where the exponent is bumped so that m*c stays near 1).
// Read from libsystem_m right after the code (log2f+256).
const LOG2F_TABLE: StaticArray<u64> = [
    0x3ff0000000000000, 0x0000000000000000, 0x3fef81f81f8271f1, 0x3f96e79685ac8265,
    0x3fef07c1f07d1862, 0x3fa6bad37577cdd3, 0x3fee9131abf02f18, 0x3fb0eb389fa90e92,
    0x3fee1e1e1e1ea60d, 0x3fb663f6fac29027, 0x3fedae6076b9258d, 0x3fbbc84240b2284b,
    0x3fed41d41d412575, 0x3fc08c588cdec84a, 0x3fecd8568902a484, 0x3fc32ae9e27ed85b,
    0x3fec71c71c70f96e, 0x3fc5c01a3a010dd7, 0x3fec0e070382101d, 0x3fc84c2bd02cfa24,
    0x3febacf914c254af, 0x3fcacf5e2db0e9de, 0x3feb4e81b4e7482e, 0x3fcd49ee4c37ed36,
    0x3feaf286bca1e09f, 0x3fcfbc16b9011514, 0x3fea98ef606a9dbf, 0x3fd11307dad24218,
    0x3fea41a41a41297d, 0x3fd24407ab0fb668, 0x3fe9ec8e95105eca, 0x3fd37124cea434fc,
    0x3fe999999998b16f, 0x3fd49a784bd060e8, 0x3fe948b0fcd65c4a, 0x3fd5c01a39fddb95,
    0x3fe8f9c18f9c4c0f, 0x3fd6e221cd9c5005, 0x3fe8acb90f6c0b26, 0x3fd800a56315c472,
    0x3fe861861860d371, 0x3fd91bba8921bb9c, 0x3fe81818181771e6, 0x3fda33760a81dd34,
    0x3fe7d05f417dd809, 0x3fdb47ebf7355417, 0x3fe78a4c81793167, 0x3fdc592fad2733c7,
    0x3fe745d1745df36f, 0x3fdd6753e02f8097, 0x3fe702e05c0a9328, 0x3fde726aa1eb10ed,
    0x3fe6c16c16c19bf9, 0x3fdf7a8568ca4484, 0x3fe68168168170b4, 0x3fe03fda8b9787d3,
    0x3fe642c8590c06b4, 0x3fe0c10500d45f16, 0x3fe6058160586486, 0x3fe140c9faa140b1,
    0x3fe5c9882b93331f, 0x3fe1bf311e95865b, 0x3fe58ed23081846a, 0x3fe23c41d426caa7,
    0x3fe55555555565b2, 0xbfda8ff97181512f, 0x3fe51d07eae25f1e, 0xbfd99b072a9429c1,
    0x3fe4e5e0a72eb123, 0xbfd8a8980abe49ad, 0x3fe4afd6a052aff3, 0xbfd7b89f02cee5ec,
    0x3fe47ae147ae2fd2, 0xbfd6cb0f6866442d, 0x3fe446f865628c84, 0xbfd5dfdcf1ed4d52,
    0x3fe414141413acbe, 0xbfd4f6fbb2ccea65, 0x3fe3e22cbce4861e, 0xbfd4106017c34a9b,
    0x3fe3b13b13b1ac72, 0xbfd32bfee37301f7, 0x3fe381381380a51e, 0xbfd249cd2b1115be,
    0x3fe3521cfb2c1f3a, 0xbfd169c053670ce7, 0x3fe323e34a2bfc50, 0xbfd08bce0d9a6a96,
    0x3fe2f684bda0ad76, 0xbfcf5fd8a9014cc3, 0x3fe2c9fb4d803821, 0xbfcdac22d3daded7,
    0x3fe29e4129e3a3ef, 0xbfcbfc67a7fbaaf8, 0x3fe27350b88209ac, 0xbfca5094b55602c6,
    0x3fe249249249dbc3, 0xbfc8a8980ac6f736, 0x3fe21fb781227c5a, 0xbfc7046031ccc0b5,
    0x3fe1f7047dc01f7d, 0xbfc563dc29f565bb, 0x3fe1cf06ada36398, 0xbfc3c6fb65160ac7,
    0x3fe1a7b9611b19bc, 0xbfc22dadc2b1aabf, 0x3fe181181180a9e7, 0xbfc097e38ce17c11,
    0x3fe15b1e5f74bdc8, 0xbfbe0b1ae8ea3d3a, 0x3fe135c811359e80, 0xbfbaed391ab2eb45,
    0x3fe111111110e212, 0xbfb7d60496cbc247, 0x3fe0ecf56be648da, 0xbfb4c560fe618ce8,
    0x3fe0c9714fbbf1a4, 0xbfb1bb32a5ec5767, 0x3fe0a6810a681e3a, 0xbfad6ebd1f224645,
    0x3fe0842108426a0d, 0xbfa77394c9e8fd24, 0x3fe0624dd2f26f2d, 0xbfa184b8e4e82535,
    0x3fe0410410417bc2, 0xbf9743ee8649b454, 0x3fe0204081026480, 0xbf872c7ba2547e55,
    0x3fe0000000000000, 0x0000000000000000,
];

// f32 log2: libsystem_m `log2f(x)`. Apple's result is not the
// correctly rounded one on 604 of the 2^32 inputs. The original evaluates
// `m*c - 1` and the polynomial with FMA; this unfused version matched the
// library on all 2^32 inputs.
export function appleLog2f(x: f32): f32 {
    let w0 = reinterpret<u32>(x);
    const w2 = w0 - 0x800000;
    if (w2 >= 0x7f000000) {
        // Zero, subnormal, negative, inf or NaN.
        if (isNaN(x)) return x;
        if (x == <f32>0.0) return <f32>-Infinity;
        if (x < <f32>0.0) return reinterpret<f32>(<u32>0x7fc00000); // inf - inf on arm64
        if (<i32>w2 >= 0) return x; // +inf
        // Subnormal: scale by 2^126 exactly (1 + m - 1), then take 126 off the
        // exponent field (it may wrap below zero; the shift below is signed).
        const s = reinterpret<f32>(w0 | 0x3f800000) - <f32>1.0;
        w0 = reinterpret<u32>(s) + 0xc1000000;
    }
    const e = (<i32>(<u32>0xc0c10000 + w0)) >> 23;
    const mant = w0 & 0x7fffff;
    const idx = <i32>((mant + 0x10000) >> 17);
    const m = <f64>reinterpret<f32>(mant | 0x3f800000);
    const c = reinterpret<f64>(unchecked(LOG2F_TABLE[2 * idx]));
    const l = reinterpret<f64>(unchecked(LOG2F_TABLE[2 * idx + 1]));
    const r = m * c - 1.0;
    let p = r * d(0xbfd715a3c1d1bbdd) + d(0x3fdec753bab7b7ce);
    p = r * p + d(0xbfe7154764eded82);
    p = r * p + d(0x3ff7154765224725);
    p = r * p + l;
    return <f32>(<f64>e + p);
}

// ---------------------------------------------------------------------------
// powf

// (1/c, 128 * log2 c) pairs for powf's log2 step, indexed by 7 mantissa bits
// of x relative to 0x3f338000.
const POWF_LOG2_TABLE: StaticArray<u64> = [
    0x3ff6c16c16c16c17, 0xc05042bd4b9a7c99, 0x3ff6a13cd1537290, 0xc050014332be0033,
    0x3ff6816816816817, 0xc04f804ae8d0cd02, 0x3ff661ec6a5122f9, 0xc04efec61b011f85,
    0x3ff642c8590b2164, 0xc04e7df5fe538ab3, 0x3ff623fa77016240, 0xc04dfdd89d586e2b,
    0x3ff6058160581606, 0xc04d7e6c0abc3579, 0x3ff5e75bb8d015e7, 0xc04cffae611ad12b,
    0x3ff5c9882b931057, 0xc04c819dc2d45fe4, 0x3ff5ac056b015ac0, 0xc04c043859e2fdb3,
    0x3ff58ed2308158ed, 0xc04b877c57b1b070, 0x3ff571ed3c506b3a, 0xc04b0b67f4f46810,
    0x3ff5555555555555, 0xc04a8ff971810a5e, 0x3ff5390948f40feb, 0xc04a152f142981b4,
    0x3ff51d07eae2f815, 0xc0499b072a96c6b2, 0x3ff5015015015015, 0xc04921800924dd3b,
    0x3ff4e5e0a72f0539, 0xc048a8980abfbd32, 0x3ff4cab88725af6e, 0xc048304d90c11fd3,
    0x3ff4afd6a052bf5b, 0xc047b89f02cf2aad, 0x3ff49539e3b2d067, 0xc047418acebbf18f,
    0x3ff47ae147ae147b, 0xc046cb0f6865c8ea, 0x3ff460cbc7f5cf9a, 0xc046552b49986277,
    0x3ff446f86562d9fb, 0xc045dfdcf1eeae0e, 0x3ff42d6625d51f87, 0xc0456b22e6b578e5,
    0x3ff4141414141414, 0xc044f6fbb2cec598, 0x3ff3fb013fb013fb, 0xc0448365e695d797,
    0x3ff3e22cbce4a902, 0xc044106017c3eca3, 0x3ff3c995a47babe7, 0xc0439de8e1559f6f,
    0x3ff3b13b13b13b14, 0xc0432bfee370ee68, 0x3ff3991c2c187f63, 0xc042baa0c34be1ec,
    0x3ff3813813813814, 0xc04249cd2b13cd6c, 0x3ff3698df3de0748, 0xc041d982c9d52708,
    0x3ff3521cfb2b78c1, 0xc04169c05363f158, 0x3ff33ae45b57bcb2, 0xc040fa848044b351,
    0x3ff323e34a2b10bf, 0xc0408bce0d95fa38, 0x3ff30d190130d190, 0xc0401d9bbcfa61d4,
    0x3ff2f684bda12f68, 0xc03f5fd8a9063e35, 0x3ff2e025c04b8097, 0xc03e857d3d361368,
    0x3ff2c9fb4d812ca0, 0xc03dac22d3e441d3, 0x3ff2b404ad012b40, 0xc03cd3c712d31109,
    0x3ff29e4129e4129e, 0xc03bfc67a7fff4cc, 0x3ff288b01288b013, 0xc03b2602497d5346,
    0x3ff27350b8812735, 0xc03a5094b54d2828, 0x3ff25e22708092f1, 0xc0397c1cb13c7ec1,
    0x3ff2492492492492, 0xc038a8980abfbd32, 0x3ff23456789abcdf, 0xc037d60496cfbb4c,
    0x3ff21fb78121fb78, 0xc037046031c79f85, 0x3ff20b470c67c0d9, 0xc03633a8bf437ce1,
    0x3ff1f7047dc11f70, 0xc03563dc29ffacb2, 0x3ff1e2ef3b3fb874, 0xc03494f863b8df35,
    0x3ff1cf06ada2811d, 0xc033c6fb650cde51, 0x3ff1bb4a4046ed29, 0xc032f9e32d5bfdd1,
    0x3ff1a7b9611a7b96, 0xc0322dadc2ab3497, 0x3ff19453808ca29c, 0xc03162593186da70,
    0x3ff1811811811812, 0xc03097e38ce60649, 0x3ff16e0689427379, 0xc02f9c95dc1d1165,
    0x3ff15b1e5f75270d, 0xc02e0b1ae8f2fd56, 0x3ff1485f0e0acd3b, 0xc02c7b528b70f1c5,
    0x3ff135c81135c811, 0xc02aed391ab6674e, 0x3ff12358e75d3033, 0xc02960caf9abb7ca,
    0x3ff1111111111111, 0xc027d60496cfbb4c, 0x3ff0fef010fef011, 0xc0264ce26c067157,
    0x3ff0ecf56be69c90, 0xc024c560fe68af88, 0x3ff0db20a88f4696, 0xc0233f7cde14cf5a,
    0x3ff0c9714fbcda3b, 0xc021bb32a600549d, 0x3ff0b7e6ec259dc8, 0xc020387efbca869e,
    0x3ff0a6810a6810a7, 0xc01d6ebd1f1febfe, 0x3ff0953f39010954, 0xc01a6f9c377dd31b,
    0x3ff0842108421084, 0xc0177394c9d958d5, 0x3ff073260a47f7c6, 0xc0147aa07357704f,
    0x3ff0624dd2f1a9fc, 0xc01184b8e4c56af8, 0x3ff05197f7d73404, 0xc00d23afc49139f9,
    0x3ff0410410410410, 0xc00743ee861f3556, 0x3ff03091b51f5e1a, 0xc0016a21e20a0a45,
    0x3ff0204081020408, 0xbff72c7ba20f7327, 0x3ff0101010101010, 0xbfe720d9c06a835f,
    0x3ff0000000000000, 0x0000000000000000, 0x3fefc07f01fc07f0, 0x3ff6fe50b6ef0851,
    0x3fef81f81f81f820, 0x4006e79685c2d22a, 0x3fef44659e4a4271, 0x40111cd1d5133413,
    0x3fef07c1f07c1f08, 0x4016bad3758efd87, 0x3feecc07b301ecc0, 0x401c4dfab90aab5f,
    0x3fee9131abf0b767, 0x4020eb389fa29f9b, 0x3fee573ac901e574, 0x4023aa2fdd27f1c3,
    0x3fee1e1e1e1e1e1e, 0x402663f6fac91316, 0x3fede5d6e3f8868a, 0x402918a16e46335b,
    0x3fedae6076b981db, 0x402bc84240adabba, 0x3fed77b654b82c34, 0x402e72ec117fa5b2,
    0x3fed41d41d41d41d, 0x40308c588cda79e4, 0x3fed0cb58f6ec074, 0x4031dcd197552b7b,
    0x3fecd85689039b0b, 0x40332ae9e278ae1a, 0x3feca4b3055ee191, 0x403476a9f983f74d,
    0x3fec71c71c71c71c, 0x4035c01a39fbd688, 0x3fec3f8f01c3f8f0, 0x40370742d4ef027f,
    0x3fec0e070381c0e0, 0x40384c2bd02f03b3, 0x3febdd2b899406f7, 0x40398edd077e70df,
    0x3febacf914c1bad0, 0x403acf5e2db4ec94, 0x3feb7d6c3dda338b, 0x403c0db6cdd94dee,
    0x3feb4e81b4e81b4f, 0x403d49ee4c325970, 0x3feb2036406c80d9, 0x403e840be74e6a4d,
    0x3feaf286bca1af28, 0x403fbc16b902680a, 0x3feac5701ac5701b, 0x4040790adbb03009,
    0x3fea98ef606a63be, 0x40411307dad30b76, 0x3fea6d01a6d01a6d, 0x4041ac05b291f070,
    0x3fea41a41a41a41a, 0x40424407ab0e073a, 0x3fea16d3f97a4b02, 0x4042db10fc4d9aaf,
    0x3fe9ec8e951033d9, 0x40437124cea4cded, 0x3fe9c2d14ee4a102, 0x404406463b1b0449,
    0x3fe999999999999a, 0x40449a784bcd1b8b, 0x3fe970e4f80cb872, 0x40452dbdfc4c96b3,
    0x3fe948b0fcd6e9e0, 0x4045c01a39fbd688, 0x3fe920fb49d0e229, 0x4046518fe4677ba7,
    0x3fe8f9c18f9c18fa, 0x4046e221cd9d0cde, 0x3fe8d3018d3018d3, 0x404771d2ba7efb3c,
    0x3fe8acb90f6bf3aa, 0x404800a563161c54, 0x3fe886e5f0abb04a, 0x40488e9c72e0b226,
    0x3fe8618618618618, 0x40491bba891f1709, 0x3fe83c977ab2bedd, 0x4049a802391e232f,
    0x3fe8181818181818, 0x404a33760a7f6051, 0x3fe7f405fd017f40, 0x404abe18797f1f49,
    0x3fe7d05f417d05f4, 0x404b47ebf73882a1, 0x3fe7ad2208e0ecc3, 0x404bd0f2e9e79031,
    0x3fe78a4c8178a4c8, 0x404c592fad295b56, 0x3fe767dce434a9b1, 0x404ce0a4923a587d,
    0x3fe745d1745d1746, 0x404d6753e032ea0f, 0x3fe724287f46debc, 0x404ded3fd442364c,
    0x3fe702e05c0b8170, 0x404e726aa1e754d2, 0x3fe6e1f76b4337c7, 0x404ef6d67328e220,
];

// For |y| >= 1: 0 when y is not an integer, 1 when it is odd, 2 when even
// (|y| >= 2^24 counts as even, as in the original).
function powfYKind(iy: u32): i32 {
    let a = iy & 0x7fffffff;
    if (a < 0x3f800000) return 0;
    if (a > 0x4b800000) a = 0x4b800000;
    const f = reinterpret<f32>(a);
    if (Mathf.trunc(f) != f) return 0;
    return (<i32>f & 1) != 0 ? 1 : 2;
}

// f32 x^y: libsystem_m `powf(x, y)`: log2(x) through a
// 128-entry table and a degree-4 polynomial (scaled by 128), times y, then
// exp2 through expf's table. The FMAs are emulated. Matched the library on
// 3e8 random pairs (every exponent, negative bases with integer powers,
// fractional powers of small bases) and a grid of special values.
export function applePowf(x: f32, y: f32): f32 {
    if (x == <f32>1.0) return x; // even for y = NaN
    if (y == <f32>1.0) return x * <f32>1.0;
    let ix = reinterpret<u32>(x);
    const iy = reinterpret<u32>(y);
    let sign: u32 = 0;
    if ((iy & 0x7fffffff) - 1 >= 0x7f7fffff) {
        // y is ±0, ±inf or NaN.
        const ay = iy & 0x7fffffff;
        if (ay > 0x7f800000) return y * <f32>1.0; // NaN
        if (ay == 0) return 1.0; // x^0 = 1, even for x = NaN
        const ax = ix & 0x7fffffff;
        if (ax == 0) return (iy >> 31) != 0 ? <f32>1.0 / Mathf.abs(x) : Mathf.abs(x); // ±0^±inf
        if (ax > 0x7f800000) return x * <f32>1.0; // NaN^±inf
        if (ax == 0x3f800000) return 1.0; // (-1)^±inf
        // |x| > 1 with +inf or |x| < 1 with -inf gives inf, else 0.
        const m = <u32>(<i32>((ax - 0x3f800000) ^ iy) >> 31);
        return reinterpret<f32>(reinterpret<u32>(Mathf.abs(y)) & ~m);
    }
    if (ix - 0x800000 >= 0x7f000000) {
        // x is ±0, subnormal, negative, ±inf or NaN.
        const ax = ix & 0x7fffffff;
        if (ax - 1 >= 0x7f7fffff) {
            // x is ±0, ±inf or NaN.
            if (ax > 0x7f800000) return x * <f32>1.0;
            let r = x;
            if (powfYKind(iy) != 1) r = Mathf.abs(r);
            if ((iy >> 31) != 0) r = <f32>1.0 / r;
            return r;
        }
        if ((ix >> 31) != 0) {
            // x < 0: only integer powers are defined, odd ones are negative.
            const k = powfYKind(iy);
            if (k == 0) return reinterpret<f32>(<u32>0x7fc00000); // inf - inf on arm64
            if (k == 1) sign = 0x80000000;
            ix = ax;
        }
        if (ix < 0x800000) {
            // Subnormal: normalize as logf does.
            const s = reinterpret<f32>(ix | 0x3f800000) - <f32>1.0;
            ix = reinterpret<u32>(s) - 0x3f000000;
        }
    }
    const tmp = ix - 0x3f338000;
    const i = <i32>((tmp >> 16) & 0x7f);
    const top = tmp & 0xff800000;
    const iz = ix - top;
    const k = <f64>(<i32>top >> 16);
    const invc = reinterpret<f64>(unchecked(POWF_LOG2_TABLE[2 * i]));
    const logc = reinterpret<f64>(unchecked(POWF_LOG2_TABLE[2 * i + 1]));
    const z = <f64>reinterpret<f32>(iz);
    const r = fmaF64(z, invc, -1.0);
    const y0 = logc + k;
    const r2 = r * r;
    let p = fmaF64(r, d(0xc0471559dca827eb), d(0x404ec71c53b3b1e8));
    const q = fmaF64(r, d(0xc05715476529654c), d(0x40671547652aef42));
    p = fmaF64(p, r2, q);
    const l = fmaF64(p, r, y0); // 128 * log2(x)
    let ylogx = <f64>y * l;
    // Clamped to [-32768, 32768] (under / overflow of the f32 result).
    if (ylogx > d(0x40e0000000000000)) ylogx = d(0x40e0000000000000);
    if (ylogx < d(0xc0e0000000000000)) ylogx = d(0xc0e0000000000000);
    const kd = roundF64(ylogx); // frinta: ties away from zero
    const ki = <u64>f64ToI64(kd);
    const res = <f32>exp2Scaled(ki, ylogx - kd);
    return reinterpret<f32>(reinterpret<u32>(res) ^ sign);
}

// ===========================================================================
// f64 routines: sin, cos, pow (the expression language's builtins) and log2
// (the Draco encoder's entropy estimates). Apple's f64 routines are not
// correctly rounded either: musl's (`Math.*`) differ from them on about 4% of
// sin/cos inputs, 0.2% of pow and 0.02% of log2 inputs. Disassembled and
// reproduced like the f32 routines above; every FMA goes through fmaF64. They
// matched the library on 2e8 random inputs of each (every exponent, both
// signs, the argument-reduction boundaries, subnormals, inf, NaN) and on grids
// of special pairs for pow.

// The high 64 bits of the 128-bit product a * b (arm64 `umulh`).
function umulh(a: u64, b: u64): u64 {
    const al = a & 0xffffffff;
    const ah = a >> 32;
    const bl = b & 0xffffffff;
    const bh = b >> 32;
    const p0 = al * bl;
    const p1 = al * bh;
    const p2 = ah * bl;
    const p3 = ah * bh;
    const mid = (p0 >> 32) + (p1 & 0xffffffff) + (p2 & 0xffffffff);
    return p3 + (p1 >> 32) + (p2 >> 32) + (mid >> 32);
}

// arm64 `sub d, d, d` on bit patterns: takes `e` off the exponent field.
@inline function subExp(x: f64, e: u64): f64 {
    return reinterpret<f64>(reinterpret<u64>(x) - e);
}

// ---------------------------------------------------------------------------
// sin, cos

// 2/PI as a string of 64-bit words for the large-argument reduction, in
// memory order (the code indexes down from the end by exponent).
const TWO_OVER_PI_BITS: StaticArray<u64> = [
    0x35fdafd88fc6ae84, 0x9e839cfbc5294975, 0xba93dd63f5f2f8bd, 0xa7a31fb34f2ff516,
    0xb69b3f6793e584db, 0xf79788c5ad05368f, 0x8ffc4bffef02cc07, 0x4e422fc5defc941d,
    0x9cc8eb1cc1a99cfa, 0x74ce38135a2fbf20, 0x74411afa975da242, 0x7f0ef58e5894d39f,
    0x0324977504e8c90e, 0xdb92371d2126e970, 0xff28b1d5ef5de2b0, 0x6db14acc9e21c820,
    0xfe13abe8fa9a6ee0, 0x517cc1b727220a94, 0x0000000000000000,
];
// sin(r) = r + r^3 * P(r^2) and cos(r) = 1 + r^2 * Q(r^2), coefficients
// highest degree first.
const SIN_POLY: StaticArray<u64> = [
    0x3de5d8fd1fd19ccd, 0xbe5ae5e5a9291f5d, 0x3ec71de3567d48a1, 0xbf2a01a019bfdf03,
    0x3f8111111110f7d0, 0xbfc5555555555548,
];
const COS_POLY: StaticArray<u64> = [
    0xbda8fa49a0861a9b, 0x3e21ee9d7b4e3f05, 0xbe927e4f7eac4bc6, 0x3efa01a019c844f5,
    0xbf56c16c16c14f91, 0x3fa555555555554b, 0xbfe0000000000000,
];
// PI/4 as a 64-bit fraction.
const PI_4_FIXED: u64 = 0xc90fdaa22168c235;
const SIGN64: u64 = 0x8000000000000000;

// sin of the reduced argument r = hi + lo (r0 is hi + lo rounded), sign
// flipped by `sign`.
function sinKernel(r0: f64, hi: f64, lo: f64, sign: u64): f64 {
    const r2 = r0 * r0;
    let p = fmaF64(r2, d(unchecked(SIN_POLY[0])), d(unchecked(SIN_POLY[1])));
    p = fmaF64(r2, p, d(unchecked(SIN_POLY[2])));
    p = fmaF64(r2, p, d(unchecked(SIN_POLY[3])));
    p = fmaF64(r2, p, d(unchecked(SIN_POLY[4])));
    p = fmaF64(r2, p, d(unchecked(SIN_POLY[5])));
    const t = r2 * p;
    const s = fmaF64(r0, t, lo) + hi;
    return reinterpret<f64>(reinterpret<u64>(s) ^ sign);
}

// cos from r^2; `sign` is added to the result's bits (0 or the sign bit).
function cosKernel(r2: f64, sign: u64): f64 {
    let p = fmaF64(r2, d(unchecked(COS_POLY[0])), d(unchecked(COS_POLY[1])));
    p = fmaF64(r2, p, d(unchecked(COS_POLY[2])));
    p = fmaF64(r2, p, d(unchecked(COS_POLY[3])));
    p = fmaF64(r2, p, d(unchecked(COS_POLY[4])));
    p = fmaF64(r2, p, d(unchecked(COS_POLY[5])));
    p = fmaF64(r2, p, d(unchecked(COS_POLY[6])));
    return reinterpret<f64>(reinterpret<u64>(fmaF64(r2, p, 1.0)) + sign);
}

// cos(hi + lo): r^2 as hi^2 + 2 hi lo.
function cosOfPair(hi: f64, lo: f64, sign: u64): f64 {
    let t = hi * lo;
    t = t + t;
    return cosKernel(fmaF64(hi, hi, t), sign);
}

// The reduced argument of the large path as a 64-bit fraction `frac`
// (leading bit set) and its leading-zero count `lz`, and the raw top word
// `raw` (quadrant bits): 2/PI times the mantissa of |x| in fixed point.
class LargeReduction {
    frac: u64 = 0;
    lz: u64 = 0;
    raw: u64 = 0;
}
// Reused by every call (no allocation per call under the stub runtime).
const LARGE = new LargeReduction();

function reduceLarge(bits: u64, out: LargeReduction): void {
    const e = ((bits & ~SIGN64) >> 52) - 0x3ff;
    const m = SIGN64 | (bits << 11);
    const idx = 15 - <i32>(e >> 6);
    const s = e & 0x3f;
    let w4: u64;
    let w5: u64;
    let w6: u64;
    if (s == 0) {
        w4 = unchecked(TWO_OVER_PI_BITS[idx + 1]);
        w5 = unchecked(TWO_OVER_PI_BITS[idx + 2]);
        w6 = unchecked(TWO_OVER_PI_BITS[idx + 3]);
    } else {
        const a = unchecked(TWO_OVER_PI_BITS[idx]);
        const b = unchecked(TWO_OVER_PI_BITS[idx + 1]);
        const c = unchecked(TWO_OVER_PI_BITS[idx + 2]);
        const dd = unchecked(TWO_OVER_PI_BITS[idx + 3]);
        const r = 64 - s;
        w6 = (dd << s) | (c >> r);
        w5 = (c << s) | (b >> r);
        w4 = (b << s) | (a >> r);
    }
    const lo0 = umulh(w4, m);
    let a0 = lo0 + w5 * m;
    const carry: u64 = a0 < lo0 ? 1 : 0;
    let a1 = umulh(w5, m) + w6 * m + carry;
    out.raw = a1;
    // Round to the nearest quadrant: past half a quadrant, negate.
    const mask = <u64>(<i64>(a1 << 2) >> 63);
    a1 = (a1 ^ mask) & 0x1fffffffffffffff;
    a0 = a0 ^ mask;
    const lz = clz<u64>(a1);
    out.frac = (a1 << lz) | (a0 >> (64 - lz));
    out.lz = lz;
}

// sin of the large path's fraction.
function sinLarge(frac: u64, lz: u64, sign: u64): f64 {
    const r = umulh(PI_4_FIXED, frac);
    const e = lz << 52;
    const r0 = subExp(<f64>r * d(0x3c20000000000000), e); // r * 2^-61
    const hi = subExp(<f64>(r & 0xffff000000000000) * d(0x3c20000000000000), e);
    const lo = subExp(<f64>(r & 0x0000ffffffffffff) * d(0x3c20000000000000), e);
    return sinKernel(r0, hi, lo, sign);
}

// cos of the large path's fraction.
function cosLarge(frac: u64, lz: u64, sign: u64): f64 {
    let r = umulh(PI_4_FIXED, frac);
    r = umulh(r, r);
    const r2 = subExp(<f64>r * d(0x3c50000000000000), (lz + lz) << 52); // r * 2^-58
    return cosKernel(r2, sign);
}

// x - k * PI/2 as hi + lo for |x| < 2^19 + ..., k = round(x * 2/PI).
class MediumReduction {
    k: i64 = 0;
    hi: f64 = 0;
    lo: f64 = 0;
}
const MEDIUM = new MediumReduction();

function reduceMedium(x: f64, out: MediumReduction): void {
    const k = nearest<f64>(x * d(0x3fe45f306dc9c883));
    out.k = <i64>k;
    const p1 = k * d(0x3ff921fb54440000);
    const p2 = k * d(0x3d868c234c4c0000);
    const p3 = k * d(0x3b298a2e03707345);
    const t = x - p1;
    const hi = t - p2;
    out.hi = hi;
    out.lo = ((t - hi) - p2) - p3;
}

// f64 sine: libsystem_m `sin(x)`.
export function appleSin(x: f64): f64 {
    if (x == 0.0) return x;
    const ax = Math.abs(x);
    if (!(ax > d(0x3fe921fb54442d18))) return sinKernel(x, 0.0, x, 0); // |x| <= PI/4, NaN
    if (ax < d(0x412000013be57a40)) {
        const mr = MEDIUM;
        reduceMedium(x, mr);
        const sign = SIGN64 & (<u64>mr.k << 62);
        if ((mr.k & 1) != 0) return cosOfPair(mr.hi, mr.lo, sign);
        return sinKernel(mr.hi + mr.lo, mr.hi, mr.lo, sign);
    }
    const bits = reinterpret<u64>(x);
    if (((bits & ~SIGN64) >> 52) == 0x7ff) return x - x; // inf, NaN
    const lr = LARGE;
    reduceLarge(bits, lr);
    const sign = ((bits & SIGN64) ^ lr.raw) & SIGN64;
    if (<i64>((lr.raw << 2) ^ (lr.raw << 1)) < 0) return cosLarge(lr.frac, lr.lz, sign);
    return sinLarge(lr.frac, lr.lz, sign);
}

// f64 cosine: libsystem_m `cos(x)`.
export function appleCos(x: f64): f64 {
    const ax = Math.abs(x);
    if (!(ax > d(0x3fe921fb54442d18))) return cosOfPair(ax, 0.0, 0); // |x| <= PI/4, NaN
    if (ax < d(0x412000013be57a40)) {
        const mr = MEDIUM;
        reduceMedium(ax, mr);
        const sign = <u64>(mr.k ^ (mr.k >> 1)) << 63;
        if ((mr.k & 1) == 0) return cosOfPair(mr.hi, mr.lo, sign);
        return sinKernel(mr.hi + mr.lo, mr.hi, mr.lo, sign);
    }
    const bits = reinterpret<u64>(ax);
    if ((bits >> 52) == 0x7ff) return ax - ax; // inf, NaN
    const lr = LARGE;
    reduceLarge(bits, lr);
    const sign = (lr.raw ^ (lr.raw << 1)) & SIGN64;
    if (<i64>((lr.raw << 2) ^ (lr.raw << 1)) >= 0) return cosLarge(lr.frac, lr.lz, sign);
    return sinLarge(lr.frac, lr.lz, sign);
}

// ---------------------------------------------------------------------------
// pow

// pow: log2 polynomial coefficients (A0..A4, then the three (hi, lo) steps
// B0..B5), read from libsystem_m just before the table below.
const POW_LOG_POLY: StaticArray<u64> = [
    0xbfc714b312ffc98e, 0x3fca619f928980a6, 0xbfcec709dd391af8, 0x3fd2776c50e28d61,
    0xbfd71547652b82c7, 0x3fdec709dc3a0400, 0x3c5746f307c00c8e, 0xbfe71547652b82fe,
    0xbc677aa5cbc36d0f, 0x3ff71547652b82fe, 0x3c7777cbae0ed1aa,
];
// pow: 256 entries of two words: the low half of word 0 is the high half of
// 1/c (a short double), its high half the high half of a small log2 c
// correction; word 1 is log2 c.
const POW_LOG_TABLE: StaticArray<u64> = [
    0x000000003ff00000, 0x0000000000000000, 0xbc0ebef93fefc068, 0x3f8706adaf949f49,
    0x3bab0b5d3fef81a8, 0x3f96f6435f8f3269, 0x3c2ec7643fef445d, 0x3fa11d9d6edefdb8,
    0x3bbbc33d3fef0871, 0x3fa6aa8c69f82995, 0x3b8261bf3feecc32, 0x3fac4a04287d6529,
    0xbb6669b23fee920f, 0x3fb0e0c68e424ace, 0xbc0ca7313fee56ee, 0x3fb3add69167a803,
    0xbc20d8513fee1e52, 0x3fb6617ac26d3c85, 0xbbc630d63fede50f, 0x3fb92246d1c79540,
    0x3b74d1953fedad92, 0x3fbbd24b77dbb164, 0x3c043bb83fed7712, 0x3fbe7af7c8933e03,
    0x3c6e54c13fed411b, 0x3fc090e9025eddd4, 0x3c1ef8a03fed0cfe, 0x3fc1db051c140737,
    0xbc117e843fecd75d, 0x3fc33127811d49f6, 0xbc15ffe33feca3c2, 0x3fc47cbbf2792a04,
    0x3bf265a13fec72bb, 0x3fc5b9eaf8e6028b, 0x3c423d8f3fec404b, 0x3fc70275f1837cd6,
    0x3c438f233fec0df8, 0x3fc84c8ea3631e5b, 0x3bca3acf3febdc79, 0x3fc9937c528da973,
    0xbb9531f63febac9a, 0x3fcad1d89ecd0361, 0x3c6563203feb7d57, 0x3fcc0e457f1a4606,
    0xbc0c163d3feb4e23, 0x3fcd4c6ec7f0fa9b, 0xbbba40e13feb2043, 0x3fce83b51de1e130,
    0xbbc7e2273feaf2f4, 0x3fcfb929fcb47417, 0xbc1c14b63feac4f8, 0x3fd07aa91b2ca230,
    0x3bd5ff933fea985d, 0x3fd1150405368efc, 0x3c1cf38b3fea6c72, 0x3fd1adfba4172d24,
    0x3c054efc3fea41fc, 0x3fd242d294235c3a, 0xbba4d3ba3fea1613, 0x3fd2ddbbfb7f3c85,
    0xbc5100723fe9ec65, 0x3fd371b8e9222827, 0xbc7cd2013fe9c1f1, 0x3fd4096a3fa76078,
    0x3bdf75713fe999e1, 0x3fd49976c7cfb747, 0xbc041a1c3fe971c7, 0x3fd52a89b6126155,
    0xbbd3ca043fe9495a, 0x3fd5bdb10e1494ce, 0x3c039bdd3fe92122, 0x3fd65101a7359962,
    0x3b93fcad3fe8fa0a, 0x3fd6e11602431b0e, 0x3c3c1b243fe8d2f8, 0x3fd771f64145b29f,
    0x3c2f706a3fe8ada3, 0x3fd7fd3a0cd1729b, 0x3bd918b83fe887a8, 0x3fd88bc1f2b8fde1,
    0xbc2608613fe861f5, 0x3fd91a168bad4093, 0xbbfe1d823fe83bac, 0x3fd9ab83601c2e99,
    0xbc2aee253fe81812, 0x3fda338d65098fbf, 0x3c1a69003fe7f4e7, 0x3fdabab52f19a9cb,
    0xbc0f037e3fe7d08a, 0x3fdb47463d06a5f0, 0x3c2340b73fe7adab, 0x3fdbcedccd4da020,
    0xbbed72fc3fe78ac8, 0x3fdc574b4f99ab6d, 0xbc2e1aae3fe7674e, 0x3fdce2d8491411da,
    0xbc5131033fe74516, 0x3fdd6a3ba17a98be, 0xbc118bbe3fe7237e, 0x3fddefe824a6fe07,
    0x3c2e68a13fe701f8, 0x3fde760f0bc2be8b, 0x3c3ea09e3fe6e2c1, 0x3fdef3a91e17bbc9,
    0xbc6f56bb3fe6c240, 0x3fdf77299fcad5de, 0x3c4a86963fe6a196, 0x3fdffc0dbd620500,
    0xbc25c2883fe6810c, 0x3fe04097743d5c6f, 0x3c7fac703fe66156, 0x3fe081d335d14e25,
    0x3c33a9f83fe6421b, 0x3fe0c26c86b500df, 0x3c6397df3fe6239f, 0x3fe101d26a8d3ec4,
    0x3c4eed683fe6057d, 0x3fe140d32757ef1b, 0xbbdc85393fe5e6c8, 0x3fe181602d908fc1,
    0x3c257ab03fe5c88f, 0x3fe1c1412597d32d, 0x3bc639043fe5ac59, 0x3fe1fd31c7e401e5,
    0x3c5c090a3fe58e2f, 0x3fe23d9f51b99eb2, 0x3c167a3e3fe572b0, 0x3fe278a8c472c40f,
    0xbbf2e2123fe5552c, 0xbfda8f468bea6bab, 0x3c50b09f3fe538c4, 0xbfda1401a35e2207,
    0x3c3d724e3fe51da3, 0xbfd99dad548d5854, 0x3bdb2df33fe5014f, 0xbfd9217b478247c6,
    0x3c7dc05c3fe4e5f6, 0xbfd8a8f65b8148dc, 0xbc6280263fe4cb44, 0xbfd832b8e69895b4,
    0xbc42ec4d3fe4af97, 0xbfd7b78304d09278, 0x3be07f8f3fe494df, 0xbfd73ff3131de57a,
    0x3c5aa8043fe47a6e, 0xbfd6c907a7936f76, 0xbc23a9d13fe46037, 0xbfd6528920cd0775,
    0x3c157e153fe44758, 0xbfd5e190433aef0e, 0xbc1c5e8c3fe42d10, 0xbfd56998ac049478,
    0xbc26d1ef3fe414a2, 0xbfd4f9884d6cfb2f, 0x3c57b5cf3fe3faa2, 0xbfd481adba3bc479,
    0x3c4c44373fe3e1a4, 0xbfd40de517e6879c, 0xbc702b7b3fe3c990, 0xbfd39dce8d0c6f05,
    0x3c7803ce3fe3b1bb, 0xbfd32e56a8c00a1e, 0xbc76ff603fe398b0, 0xbfd2b8a31c011109,
    0x3bd74b4a3fe380a5, 0xbfd24714e481adf7, 0x3bd6010c3fe36a2c, 0xbfd1dc7279db548f,
    0x3c48b8973fe351dc, 0xbfd16889c7153834, 0xbc2a84b23fe339e9, 0xbfd0f5cd7fa7752c,
    0xbbd88c373fe323ac, 0xbfd08ac35435c943, 0xbbc6fbf93fe30c53, 0xbfd019dc059d0e54,
    0x3bf111ca3fe2f6db, 0xbfcf6320a3e9eb20, 0xbbfb7cc43fe2e05b, 0xbfce87862d120f6b,
    0xbbc4f1023fe2ca3a, 0xbfcdae8b05ec1659, 0x3c056e0a3fe2b461, 0xbfccd75698d83d8e,
    0x3bf96f3e3fe29f22, 0xbfcc051d7f25d8c7, 0xbbec0f453fe28808, 0xbfcb1f77901c26d4,
    0xbbf3bc703fe27389, 0xbfca52c7fa334e41, 0xbbbf1f003fe25d32, 0xbfc972ab200ae538,
    0xbc6a2c6d3fe249c6, 0xbfc8aef62d76aa72, 0x3c41beab3fe233c6, 0xbfc7d04afe225801,
    0xbc54f6153fe21f57, 0xbfc70088de1f5b2d, 0x3c290e853fe20b41, 0xbfc6336ad8a92825,
    0xbba6ad5e3fe1f655, 0xbfc55cd01eaa9487, 0x3bc5753a3fe1e203, 0xbfc48b713902f7fe,
    0xbbdbbf393fe1ce6e, 0xbfc3c0cc1d1b1692, 0xbb8ae1d33fe1bb6e, 0xbfc2fb577a193876,
    0xbbd4d76f3fe1a8ac, 0xbfc2379731e9df8f, 0x3c0bb1b03fe194f0, 0xbfc168c50866af19,
    0x3c3a48a53fe18154, 0xbfc09a5bcb833e9e, 0x3ba5a0983fe16ed7, 0xbfbfadd6b7f005b1,
    0x3c0b41903fe15b12, 0xbfbe0a139ddec9d0, 0xbc4080e43fe14803, 0xbfbc73a3428818bc,
    0x3bc9b8cb3fe1358a, 0xbfbae8051978c11b, 0xbc2d8b833fe12303, 0xbfb9598fa7feff2b,
    0xbba7a1293fe11141, 0xbfb7da11dd576bbe, 0xbbe388f73fe0fe07, 0xbfb63919388d8212,
    0x3bedc80c3fe0ed3a, 0xbfb4cb396209a15a, 0x3c597adf3fe0da57, 0xbfb32e39f0a97dd1,
    0x3bfa2e1c3fe0ca09, 0xbfb1c83bbb91b133, 0x3b44b8943fe0b80b, 0xbfb03b9bf822af8e,
    0x3bc4ae6c3fe0a76c, 0xbfad977378a15b0c, 0xbc473d493fe095dd, 0xbfaa8b0f9d7eed2f,
    0x3bfc4c603fe084a8, 0xbfa78b28a5f18eb0, 0xbbc08d1e3fe07294, 0xbfa461023c6c2b3f,
    0x3b9e5abc3fe062fa, 0xbfa1a30ab127d27f, 0xbbf9605e3fe05187, 0xbf9d1dafa56778af,
    0x3bcf176c3fe04027, 0xbf96f5700660f22d, 0x3c1200bd3fe02fe4, 0xbf912c35b1e2912e,
    0xbc1b6a1c3fe01f94, 0xbf86b1027d8347ea, 0x3b806a723fe00f11, 0xbf75b2440dc383d5,
    0x000000003fe00000, 0x0000000000000000, 0x0000000000000000, 0x3d25e52272171bcd,
    0x3dc3b2a8abdac87b, 0x3e5c6b08d783107a, 0x3eeebfbdff82bda7, 0x3f762e42fefa39ef,
    0x3ff0000000000000, 0x0000000000000000, 0x3ff0163da9fb3335, 0xbd13a4bc88ab6f0b,
    0x3ff02c9a3e778061, 0x3ce91137d36a5dac, 0x3ff04315e86e7f85, 0x3d079d9482b6e550,
    0x3ff059b0d3158574, 0xbd04ca556a1b2fa8, 0x3ff0706b29ddf6de, 0x3d040ee9a808de1d,
    0x3ff0874518759bc8, 0xbcd87a10f84f53b7, 0x3ff09e3ecac6f383, 0xbd0801b99f4f5b18,
    0x3ff0b5586cf9890f, 0xbd1106d9ba253401, 0x3ff0cc922b7247f7, 0xbd06269675ff4e35,
    0x3ff0e3ec32d3d1a2, 0xbcb62d2d983e6844, 0x3ff0fb66affed31b, 0x3ce2c399e6b423b5,
    0x3ff11301d0125b51, 0x3d0ec8769e7386f7, 0x3ff12abdc06c31cc, 0x3cc7cf4b389b60d3,
    0x3ff1429aaea92de0, 0x3d09a8cab70c1007, 0x3ff15a98c8a58e51, 0xbcf846f8d141b1d0,
    0x3ff172b83c7d517b, 0x3cf73c5aec1a0547, 0x3ff18af9388c8dea, 0x3d0673a724b46d55,
    0x3ff1a35beb6fcb75, 0xbd03dd2c819e0908, 0x3ff1bbe084045cd4, 0x3d107b9a3e9b6a86,
    0x3ff1d4873168b9aa, 0xbd136c3949dfc34e, 0x3ff1ed5022fcd91d, 0x3d07039d1ea652dc,
    0x3ff2063b88628cd6, 0xbd03118ae698d206, 0x3ff21f49917ddc96, 0xbcf7c551db68456f,
    0x3ff2387a6e756238, 0xbd1045c6a6d3eecb, 0x3ff251ce4fb2a63f, 0xbd00db2bd14acf32,
    0x3ff26b4565e27cdd, 0xbcf77bf4b6a48214, 0x3ff284dfe1f56381, 0x3d1063b457a17edb,
    0x3ff29e9df51fdee1, 0xbcfb5d8e0885ab1b, 0x3ff2b87fd0dad990, 0x3cb5038687737bee,
    0x3ff2d285a6e4030b, 0xbd03a1fee8c9225c, 0x3ff2ecafa93e2f56, 0xbce5b2c9eff60911,
    0x3ff306fe0a31b715, 0xbcfbd9046b69ea24, 0x3ff32170fc4cd831, 0xbd000e3e54fb7d75,
    0x3ff33c08b26416ff, 0xbd06fc3180aac683, 0x3ff356c55f929ff1, 0x3d005491f94cc017,
    0x3ff371a7373aa9cb, 0x3d0a6409cdf25d3a, 0x3ff38cae6d05d866, 0x3d120e5f6745f2e3,
    0x3ff3a7db34e59ff7, 0x3ce9b570deeb4717, 0x3ff3c32dc313a8e5, 0x3d121abaf1248342,
    0x3ff3dea64c123422, 0xbcff31b9fb32e2e4, 0x3ff3fa4504ac801c, 0x3d0b83c7e85e695f,
    0x3ff4160a21f72e2a, 0x3cd1c8d3f3908470, 0x3ff431f5d950a897, 0x3cf452cbd4449600,
    0x3ff44e086061892d, 0xbcbbf96ee8afb9fb, 0x3ff46a41ed1d0057, 0xbd10283b91b051a3,
    0x3ff486a2b5c13cd0, 0xbce637bd8150db7d, 0x3ff4a32af0d7d3de, 0xbd0cd9f521d33a36,
    0x3ff4bfdad5362a27, 0xbcf04715f70da237, 0x3ff4dcb299fddd0d, 0xbd0b942d586961a7,
    0x3ff4f9b2769d2ca7, 0x3d06c785171c0daa, 0x3ff516daa2cf6642, 0x3d013802b6c9135a,
    0x3ff5342b569d4f82, 0x3cf1f0a88738ea6a, 0x3ff551a4ca5d920f, 0x3cffd7a06db1d675,
    0x3ff56f4736b527da, 0xbd0bb5c29f573dd8, 0x3ff58d12d497c7fd, 0xbcf3e81d7478cc39,
    0x3ff5ab07dd485429, 0xbd07a560f05eeddb, 0x3ff5c9268a5946b7, 0xbcadfa723ae1bf17,
    0x3ff5e76f15ad2148, 0xbd0d2407ce0f6433, 0x3ff605e1b976dc09, 0x3d04d74bbcd33652,
    0x3ff6247eb03a5585, 0x3d0457f6a88ab15f, 0x3ff6434634ccc320, 0x3cfd5305865039df,
    0x3ff6623882552225, 0x3d0c93b642e08a78, 0x3ff68155d44ca973, 0xbcd0a350f225390e,
    0x3ff6a09e667f3bcd, 0x3d0c6cdcb8cfcc24, 0x3ff6c012750bdabf, 0x3ce2cec326ee0b73,
    0x3ff6dfb23c651a2f, 0x3cdbff379bac560e, 0x3ff6ff7df9519484, 0x3cf85304766e7062,
    0x3ff71f75e8ec5f74, 0x3cf1669aa6aea2d3, 0x3ff73f9a48a58174, 0x3d008a8544a7c319,
    0x3ff75feb564267c9, 0x3cffe19bb8ecd7c4, 0x3ff780694fde5d3f, 0xbd07f77c42eaf147,
    0x3ff7a11473eb0187, 0x3cf39ea4b4e0a91d, 0x3ff7c1ed0130c132, 0xbd0e308095c8fab2,
    0x3ff7e2f336cf4e62, 0xbcdfa03bd08bcda3, 0x3ff80427543e1a12, 0x3d01c4a6d87e2162,
    0x3ff82589994cce13, 0x3d0c01c85abda967, 0x3ff8471a4623c7ad, 0x3cf79da32bfd8963,
    0x3ff868d99b4492ed, 0x3d0e0ce7d31c17b4, 0x3ff88ac7d98a6699, 0xbd080f72957b0484,
    0x3ff8ace5422aa0db, 0xbd056f6cd720fba3, 0x3ff8cf3216b5448c, 0x3cdf530b22c146b2,
    0x3ff8f1ae99157736, 0xbcf42bc69235780f, 0x3ff9145b0b91ffc6, 0x3d0b766e6aa0a1df,
    0x3ff93737b0cdc5e5, 0x3cd565b633aaadee, 0x3ff95a44cbc8520f, 0x3ce44c91b60b1f8d,
    0x3ff97d829fde4e50, 0x3d0a58fa485235a1, 0x3ff9a0f170ca07ba, 0x3cff6ff7608a3078,
    0x3ff9c49182a3f090, 0xbce984806660caa6, 0x3ff9e86319e32323, 0xbce582eb35cac3f3,
    0x3ffa0c667b5de565, 0x3d0125694bb46c7e, 0x3ffa309bec4a2d33, 0xbd038e88295250ef,
    0x3ffa5503b23e255d, 0x3d099593455a26b5, 0x3ffa799e1330b358, 0xbd083bde4707301a,
    0x3ffa9e6b5579fdbf, 0xbcfd72d3f1e40a93, 0x3ffac36bbfd3f37a, 0x3cfb3ad1802c5436,
    0x3ffae89f995ad3ad, 0xbd0445b6038d7018, 0x3ffb0e07298db666, 0x3d07c789b4248453,
    0x3ffb33a2b84f15fb, 0x3ccf667a98d32ac1, 0x3ffb59728de5593a, 0x3d0801f60c88f9bd,
    0x3ffb7f76f2fb5e47, 0x3ce1eb0404780ad1, 0x3ffba5b030a1064a, 0x3d09df3f08eda153,
    0x3ffbcc1e904bc1d2, 0xbcee4bb29d39c3a3, 0x3ffbf2c25bd71e09, 0x3d0998b2be294a3f,
    0x3ffc199bdd85529c, 0xbcec08f260a0042a, 0x3ffc40ab5fffd07a, 0xbd0647d6355e9b74,
    0x3ffc67f12e57d14b, 0xbcfe1e92a1c04f0d, 0x3ffc8f6d9406e7b5, 0xbcdc920234dbf34d,
    0x3ffcb720dcef9069, 0xbce0e49a8304ef1f, 0x3ffcdf0b555dc3fa, 0x3cf7dc824b04c033,
    0x3ffd072d4a07897c, 0x3d06d9ab77ff22ef, 0x3ffd2f87080d89f2, 0x3d072904080a5c48,
    0x3ffd5818dcfba487, 0xbcedc682d68358e2, 0x3ffd80e316c98398, 0x3cfaca05497de9c9,
    0x3ffda9e603db3285, 0xbd05e51917091778, 0x3ffdd321f301b460, 0xbcfd2ec7bfc90fd9,
    0x3ffdfc97337b9b5f, 0x3cfb2b6b3f445f87, 0x3ffe264614f5a129, 0x3d02277152860520,
    0x3ffe502ee78b3ff6, 0xbcede1319abb2ae2, 0x3ffe7a51fbc74c83, 0xbcfc86cfb6cd46e4,
    0x3ffea4afa2a490da, 0x3d070ed6ccceec4b, 0x3ffecf482d8e67f1, 0x3d05693ab0188765,
    0x3ffefa1bee615a27, 0xbd063124664aaf80, 0x3fff252b376bba97, 0xbcfd19790d732ab4,
];
// pow: exp2 polynomial coefficients.
const POW_EXP_POLY: StaticArray<u64> = [
    0x3d25e52272171bcd, 0x3dc3b2a8abdac87b, 0x3e5c6b08d783107a, 0x3eeebfbdff82bda7,
    0x3f762e42fefa39ef,
];
// pow: 128 entries (bits of 2^(i/128) with the exponent taken off, a low
// correction).
const POW_EXP_TABLE: StaticArray<u64> = [
    0x3ff0000000000000, 0x0000000000000000, 0x3ff0163da9fb3335, 0xbd13a4bc88ab6f0b,
    0x3ff02c9a3e778061, 0x3ce91137d36a5dac, 0x3ff04315e86e7f85, 0x3d079d9482b6e550,
    0x3ff059b0d3158574, 0xbd04ca556a1b2fa8, 0x3ff0706b29ddf6de, 0x3d040ee9a808de1d,
    0x3ff0874518759bc8, 0xbcd87a10f84f53b7, 0x3ff09e3ecac6f383, 0xbd0801b99f4f5b18,
    0x3ff0b5586cf9890f, 0xbd1106d9ba253401, 0x3ff0cc922b7247f7, 0xbd06269675ff4e35,
    0x3ff0e3ec32d3d1a2, 0xbcb62d2d983e6844, 0x3ff0fb66affed31b, 0x3ce2c399e6b423b5,
    0x3ff11301d0125b51, 0x3d0ec8769e7386f7, 0x3ff12abdc06c31cc, 0x3cc7cf4b389b60d3,
    0x3ff1429aaea92de0, 0x3d09a8cab70c1007, 0x3ff15a98c8a58e51, 0xbcf846f8d141b1d0,
    0x3ff172b83c7d517b, 0x3cf73c5aec1a0547, 0x3ff18af9388c8dea, 0x3d0673a724b46d55,
    0x3ff1a35beb6fcb75, 0xbd03dd2c819e0908, 0x3ff1bbe084045cd4, 0x3d107b9a3e9b6a86,
    0x3ff1d4873168b9aa, 0xbd136c3949dfc34e, 0x3ff1ed5022fcd91d, 0x3d07039d1ea652dc,
    0x3ff2063b88628cd6, 0xbd03118ae698d206, 0x3ff21f49917ddc96, 0xbcf7c551db68456f,
    0x3ff2387a6e756238, 0xbd1045c6a6d3eecb, 0x3ff251ce4fb2a63f, 0xbd00db2bd14acf32,
    0x3ff26b4565e27cdd, 0xbcf77bf4b6a48214, 0x3ff284dfe1f56381, 0x3d1063b457a17edb,
    0x3ff29e9df51fdee1, 0xbcfb5d8e0885ab1b, 0x3ff2b87fd0dad990, 0x3cb5038687737bee,
    0x3ff2d285a6e4030b, 0xbd03a1fee8c9225c, 0x3ff2ecafa93e2f56, 0xbce5b2c9eff60911,
    0x3ff306fe0a31b715, 0xbcfbd9046b69ea24, 0x3ff32170fc4cd831, 0xbd000e3e54fb7d75,
    0x3ff33c08b26416ff, 0xbd06fc3180aac683, 0x3ff356c55f929ff1, 0x3d005491f94cc017,
    0x3ff371a7373aa9cb, 0x3d0a6409cdf25d3a, 0x3ff38cae6d05d866, 0x3d120e5f6745f2e3,
    0x3ff3a7db34e59ff7, 0x3ce9b570deeb4717, 0x3ff3c32dc313a8e5, 0x3d121abaf1248342,
    0x3ff3dea64c123422, 0xbcff31b9fb32e2e4, 0x3ff3fa4504ac801c, 0x3d0b83c7e85e695f,
    0x3ff4160a21f72e2a, 0x3cd1c8d3f3908470, 0x3ff431f5d950a897, 0x3cf452cbd4449600,
    0x3ff44e086061892d, 0xbcbbf96ee8afb9fb, 0x3ff46a41ed1d0057, 0xbd10283b91b051a3,
    0x3ff486a2b5c13cd0, 0xbce637bd8150db7d, 0x3ff4a32af0d7d3de, 0xbd0cd9f521d33a36,
    0x3ff4bfdad5362a27, 0xbcf04715f70da237, 0x3ff4dcb299fddd0d, 0xbd0b942d586961a7,
    0x3ff4f9b2769d2ca7, 0x3d06c785171c0daa, 0x3ff516daa2cf6642, 0x3d013802b6c9135a,
    0x3ff5342b569d4f82, 0x3cf1f0a88738ea6a, 0x3ff551a4ca5d920f, 0x3cffd7a06db1d675,
    0x3ff56f4736b527da, 0xbd0bb5c29f573dd8, 0x3ff58d12d497c7fd, 0xbcf3e81d7478cc39,
    0x3ff5ab07dd485429, 0xbd07a560f05eeddb, 0x3ff5c9268a5946b7, 0xbcadfa723ae1bf17,
    0x3ff5e76f15ad2148, 0xbd0d2407ce0f6433, 0x3ff605e1b976dc09, 0x3d04d74bbcd33652,
    0x3ff6247eb03a5585, 0x3d0457f6a88ab15f, 0x3ff6434634ccc320, 0x3cfd5305865039df,
    0x3ff6623882552225, 0x3d0c93b642e08a78, 0x3ff68155d44ca973, 0xbcd0a350f225390e,
    0x3ff6a09e667f3bcd, 0x3d0c6cdcb8cfcc24, 0x3ff6c012750bdabf, 0x3ce2cec326ee0b73,
    0x3ff6dfb23c651a2f, 0x3cdbff379bac560e, 0x3ff6ff7df9519484, 0x3cf85304766e7062,
    0x3ff71f75e8ec5f74, 0x3cf1669aa6aea2d3, 0x3ff73f9a48a58174, 0x3d008a8544a7c319,
    0x3ff75feb564267c9, 0x3cffe19bb8ecd7c4, 0x3ff780694fde5d3f, 0xbd07f77c42eaf147,
    0x3ff7a11473eb0187, 0x3cf39ea4b4e0a91d, 0x3ff7c1ed0130c132, 0xbd0e308095c8fab2,
    0x3ff7e2f336cf4e62, 0xbcdfa03bd08bcda3, 0x3ff80427543e1a12, 0x3d01c4a6d87e2162,
    0x3ff82589994cce13, 0x3d0c01c85abda967, 0x3ff8471a4623c7ad, 0x3cf79da32bfd8963,
    0x3ff868d99b4492ed, 0x3d0e0ce7d31c17b4, 0x3ff88ac7d98a6699, 0xbd080f72957b0484,
    0x3ff8ace5422aa0db, 0xbd056f6cd720fba3, 0x3ff8cf3216b5448c, 0x3cdf530b22c146b2,
    0x3ff8f1ae99157736, 0xbcf42bc69235780f, 0x3ff9145b0b91ffc6, 0x3d0b766e6aa0a1df,
    0x3ff93737b0cdc5e5, 0x3cd565b633aaadee, 0x3ff95a44cbc8520f, 0x3ce44c91b60b1f8d,
    0x3ff97d829fde4e50, 0x3d0a58fa485235a1, 0x3ff9a0f170ca07ba, 0x3cff6ff7608a3078,
    0x3ff9c49182a3f090, 0xbce984806660caa6, 0x3ff9e86319e32323, 0xbce582eb35cac3f3,
    0x3ffa0c667b5de565, 0x3d0125694bb46c7e, 0x3ffa309bec4a2d33, 0xbd038e88295250ef,
    0x3ffa5503b23e255d, 0x3d099593455a26b5, 0x3ffa799e1330b358, 0xbd083bde4707301a,
    0x3ffa9e6b5579fdbf, 0xbcfd72d3f1e40a93, 0x3ffac36bbfd3f37a, 0x3cfb3ad1802c5436,
    0x3ffae89f995ad3ad, 0xbd0445b6038d7018, 0x3ffb0e07298db666, 0x3d07c789b4248453,
    0x3ffb33a2b84f15fb, 0x3ccf667a98d32ac1, 0x3ffb59728de5593a, 0x3d0801f60c88f9bd,
    0x3ffb7f76f2fb5e47, 0x3ce1eb0404780ad1, 0x3ffba5b030a1064a, 0x3d09df3f08eda153,
    0x3ffbcc1e904bc1d2, 0xbcee4bb29d39c3a3, 0x3ffbf2c25bd71e09, 0x3d0998b2be294a3f,
    0x3ffc199bdd85529c, 0xbcec08f260a0042a, 0x3ffc40ab5fffd07a, 0xbd0647d6355e9b74,
    0x3ffc67f12e57d14b, 0xbcfe1e92a1c04f0d, 0x3ffc8f6d9406e7b5, 0xbcdc920234dbf34d,
    0x3ffcb720dcef9069, 0xbce0e49a8304ef1f, 0x3ffcdf0b555dc3fa, 0x3cf7dc824b04c033,
    0x3ffd072d4a07897c, 0x3d06d9ab77ff22ef, 0x3ffd2f87080d89f2, 0x3d072904080a5c48,
    0x3ffd5818dcfba487, 0xbcedc682d68358e2, 0x3ffd80e316c98398, 0x3cfaca05497de9c9,
    0x3ffda9e603db3285, 0xbd05e51917091778, 0x3ffdd321f301b460, 0xbcfd2ec7bfc90fd9,
    0x3ffdfc97337b9b5f, 0x3cfb2b6b3f445f87, 0x3ffe264614f5a129, 0x3d02277152860520,
    0x3ffe502ee78b3ff6, 0xbcede1319abb2ae2, 0x3ffe7a51fbc74c83, 0xbcfc86cfb6cd46e4,
    0x3ffea4afa2a490da, 0x3d070ed6ccceec4b, 0x3ffecf482d8e67f1, 0x3d05693ab0188765,
    0x3ffefa1bee615a27, 0xbd063124664aaf80, 0x3fff252b376bba97, 0xbcfd19790d732ab4,
    0x3fff50765b6e4540, 0xbd0309e68da0499f, 0x3fff7bfdad9cbe14, 0x3d05cc2651e079fb,
    0x3fffa7c1819e90d8, 0xbcf0fa4931906b80, 0x3fffd3c22b8f71f1, 0xbccb71923d729650,
];
// 2^(t/128) for t = th + tl (|tl| tiny), the sign bit or-ed in from `sign`
// (negative base, odd power). Under/overflow saturate through a product so
// the result is ±0 / ±inf.
function powExp(th: f64, tl: f64, sign: u64): f64 {
    if (th > d(0x4100040000000000)) return d(0x7fe0000000000001) * reinterpret<f64>(sign | 0x7fe0000000000001);
    if (th < d(0xc100cc0000000000)) return d(0x0010000000000001) * reinterpret<f64>(sign | 0x0010000000000001);
    const fl = Math.floor(th);
    const k = <i64>fl;
    const f = th - fl;
    const i = <i32>(k & 0x7f);
    const tb = unchecked(POW_EXP_TABLE[2 * i]);
    const tc = reinterpret<f64>(unchecked(POW_EXP_TABLE[2 * i + 1]));
    const f2 = (tl - tc) + f;
    let p = fmaF64(f, d(unchecked(POW_EXP_POLY[0])), d(unchecked(POW_EXP_POLY[1])));
    p = fmaF64(f, p, d(unchecked(POW_EXP_POLY[2])));
    p = fmaF64(f2, p, d(unchecked(POW_EXP_POLY[3])));
    p = fmaF64(f2, p, d(unchecked(POW_EXP_POLY[4])));
    p = f2 * p;
    // The exponent goes in two halves, so neither factor overflows.
    const e1 = (<u64>k << 44) & 0xfff0000000000000;
    const e2 = ((<u64>k << 45) & 0xfff0000000000000) - e1;
    let s = reinterpret<f64>((e1 ^ sign) + tb);
    s = fmaF64(s, p, s);
    return s * reinterpret<f64>(e2 + 0x3ff0000000000000);
}

// pow for a positive normal x (bits `ix`) and y in the main range.
function powMain(ix: u64, y: f64, sign: u64): f64 {
    const m = ix & 0xfffffffffffff;
    if (m == 0) {
        // x a power of two: 128 * log2(x) is exact.
        const ex = <i64>(ix - 0x3ff0000000000000);
        if (ex == 0) return reinterpret<f64>(sign | 0x3ff0000000000000);
        const l = <f64>ex * d(0x3d20000000000000); // * 2^-45
        const th = l * y;
        return powExp(th, fmaF64(l, y, -th), sign);
    }
    const i = <i32>(((m + 0x100000000000) & 0x1fe00000000000) >> 45);
    const e = <i64>(ix + 0xc018100000000000) >> 52;
    const w0 = unchecked(POW_LOG_TABLE[2 * i]);
    const w1 = unchecked(POW_LOG_TABLE[2 * i + 1]);
    const c = reinterpret<f64>((w0 & 0xffffffff) << 32); // 1/c
    const zb = m | 0x3ff0000000000000;
    const z = reinterpret<f64>(zb);
    // r = z/c - 1 as rh + rl.
    let rh = c * z;
    const zh = reinterpret<f64>(zb & 0xffffffffffe00000);
    const zl = z - zh;
    const err = fmaF64(c, zh, -rh);
    rh = rh - 1.0;
    const rl = fmaF64(c, zl, err);
    let q = fmaF64(rh, d(unchecked(POW_LOG_POLY[0])), d(unchecked(POW_LOG_POLY[1])));
    q = fmaF64(rh, q, d(unchecked(POW_LOG_POLY[2])));
    q = fmaF64(rh, q, d(unchecked(POW_LOG_POLY[3])));
    q = fmaF64(rh, q, d(unchecked(POW_LOG_POLY[4])));
    let r4 = rh * rh;
    r4 = r4 * r4;
    q = r4 * q;
    const b0 = d(unchecked(POW_LOG_POLY[5]));
    const b1 = d(unchecked(POW_LOG_POLY[6]));
    const b2 = d(unchecked(POW_LOG_POLY[7]));
    const b3 = d(unchecked(POW_LOG_POLY[8]));
    const b4 = d(unchecked(POW_LOG_POLY[9]));
    const b5 = d(unchecked(POW_LOG_POLY[10]));
    // Three compensated Horner steps (hi, lo).
    const h1 = fmaF64(b0, rh, b2);
    let l1 = fmaF64(b1, rh, b3);
    let t = h1 - b2;
    t = fmaF64(b0, rh, -t);
    l1 = fmaF64(b0, rl, l1);
    l1 = t + l1;
    const h2 = fmaF64(h1, rh, b4);
    let l2 = fmaF64(l1, rh, b5);
    t = h2 - b4;
    t = fmaF64(h1, rh, -t);
    l2 = fmaF64(h1, rl, l2);
    l2 = t + l2;
    const h3 = h2 * rh;
    let l3 = l2 * rh;
    t = fmaF64(h2, rh, -h3);
    l3 = fmaF64(h2, rl, l3);
    t = t + l3;
    // log2(x) = hi + lo.
    const ed = <f64>e;
    const lc = reinterpret<f64>(w1);
    let hi = ((ed + lc) + h3) + q;
    hi = reinterpret<f64>(reinterpret<u64>(hi) & 0xfffffffffffffffe);
    let lo = (((ed - hi) + lc) + h3) + q;
    lo = (reinterpret<f64>(w0 & 0xffffffff00000000) + lo) + t;
    const y128 = y * 128.0;
    const th = y128 * hi;
    let tl = fmaF64(y128, hi, -th);
    tl = fmaF64(y128, lo, tl);
    return powExp(th, tl, sign);
}

// For |y| >= 1 (bits without sign): 0 when y is not an integer, 1 when odd,
// 2 when even (|y| >= 2^53 counts as even).
function powYKind(ay: u64): i32 {
    if (ay < 0x3ff0000000000000) return 0;
    const v = reinterpret<f64>(ay > 0x4340000000000000 ? 0x4340000000000000 : ay);
    if (Math.trunc(v) != v) return 0;
    return (<i64>v & 1) != 0 ? 1 : 2;
}

// f64 x^y: libsystem_m `pow(x, y)`.
export function applePow(x: f64, y: f64): f64 {
    let ix = reinterpret<u64>(x);
    const iy = reinterpret<u64>(y);
    // Positive normal x and 2^-65 <= y <= 2^65: straight to the main path.
    if (ix - 0x0010000000000000 < 0x7fe0000000000000 && iy - 0x3be0000000000000 <= 0x0810000000000000) {
        return powMain(ix, y, 0);
    }
    const ONE: u64 = 0x3ff0000000000000;
    const INF: u64 = 0x7ff0000000000000;
    if (ix == ONE) return x; // 1^y = 1, even for y = NaN
    if (iy == ONE) return isNaN(x) ? x + x : x;
    const ax = ix & ~SIGN64;
    const ay = iy & ~SIGN64;
    if (ay == 0) return 1.0; // x^0 = 1, even for x = NaN
    if (ay >= INF) {
        if (ay > INF) return y + y; // NaN
        // y = ±inf
        if (ax == 0) return powZeroInf(x, ax, iy, ay);
        if (ax > INF) return x + x;
        if (ax == ONE) return 1.0;
        return reinterpret<f64>(INF & ~<u64>(<i64>((ax - ONE) ^ iy) >> 63));
    }
    if (ax == 0) return powZeroInf(x, ax, iy, ay);
    if (ax >= INF) {
        if (ax > INF) return x + x;
        return powZeroInf(x, ax, iy, ay);
    }
    let sign: u64 = 0;
    if ((ix >> 63) != 0) {
        // x < 0: only integer powers are defined, odd ones are negative.
        const k = powYKind(ay);
        if (k == 0) return reinterpret<f64>(INF) - reinterpret<f64>(INF);
        if (k == 1) sign = SIGN64;
        ix = ax;
    }
    const axv = reinterpret<f64>(ax);
    const ayv = reinterpret<f64>(ay);
    if (ayv > d(0x43f0000000000000)) {
        // |y| > 2^64: the result is ±1, ±0 or ±inf.
        if (axv == 1.0) return reinterpret<f64>(sign | ONE);
        const big = (axv > 1.0) != (y < 0.0);
        if (big) return d(0x7fe0000000000001) * reinterpret<f64>(sign | 0x7fe0000000000001);
        return d(0x0010000000000001) * reinterpret<f64>(sign | 0x0010000000000001);
    }
    if (ayv < d(0x3be0000000000000)) {
        // |y| < 2^-65: ±(1 ± 2^-65), rounded.
        if (axv == 1.0) return reinterpret<f64>(sign | ONE);
        const one = reinterpret<f64>(sign | ONE);
        const t = reinterpret<f64>(sign | 0x3be0000000000000);
        const up = (axv > 1.0) != (y < 0.0);
        return up ? one + t : one - t;
    }
    if (ix < 0x0010000000000000) {
        // Subnormal: scale by 2^52 exactly (1 + m - 1), then take 1022 off
        // the exponent field.
        const s = reinterpret<f64>(ix | ONE) - 1.0;
        ix = reinterpret<u64>(s) + 0xc020000000000000;
    }
    return powMain(ix, y, sign);
}

// x = ±0 or ±inf: |x| (x itself for odd integer y) to the sign of y.
function powZeroInf(x: f64, ax: u64, iy: u64, ay: u64): f64 {
    let r = powYKind(ay) == 1 ? x : reinterpret<f64>(ax);
    if ((iy >> 63) != 0) r = 1.0 / r;
    return r;
}

// ---------------------------------------------------------------------------
// log2

// log2: polynomial coefficients.
const LOG2_POLY: StaticArray<u64> = [
    0xbfd1197c976768fa, 0x3fca61a454f2c198, 0x3ff9de61616cdf2b, 0x3ff609d14c7ee9be,
    0x3ffab7d4f0547db7, 0xbff3f6ab6ec10818,
];
// log2: 129 entries (1/c, log2 c).
const LOG2_TABLE: StaticArray<u64> = [
    0x3ff0000000000000, 0x0000000000000000, 0x3fefc07f01fbf2f8, 0x3f86fe50b6f6a796,
    0x3fef81f81f8271f1, 0x3f96e79685ac8265, 0x3fef44659e4b066a, 0x3fa11cd1d5011e6c,
    0x3fef07c1f07d1862, 0x3fa6bad37577cdd3, 0x3feecc07b30242be, 0x3fac4dfab9029ce9,
    0x3fee9131abf02f18, 0x3fb0eb389fa90e92, 0x3fee573ac901370e, 0x3fb3aa2fdd303ca7,
    0x3fee1e1e1e1ea60d, 0x3fb663f6fac29027, 0x3fede5d6e3f7d1fc, 0x3fb918a16e4ee9c6,
    0x3fedae6076b9258d, 0x3fbbc84240b2284b, 0x3fed77b654b875b4, 0x3fbe72ec117c0c78,
    0x3fed41d41d412575, 0x3fc08c588cdec84a, 0x3fed0cb58f6fa9f7, 0x3fc1dcd1974f5f15,
    0x3fecd8568902a484, 0x3fc32ae9e27ed85b, 0x3feca4b3055e00a5, 0x3fc476a9f989a162,
    0x3fec71c71c70f96e, 0x3fc5c01a3a010dd7, 0x3fec3f8f01c4f8e7, 0x3fc70742d4e87934,
    0x3fec0e070382101d, 0x3fc84c2bd02cfa24, 0x3febdd2b8994ad73, 0x3fc98edd077a2186,
    0x3febacf914c254af, 0x3fcacf5e2db0e9de, 0x3feb7d6c3dda7372, 0x3fcc0db6cdd7a0ab,
    0x3feb4e81b4e7482e, 0x3fcd49ee4c37ed36, 0x3feb2036406d4a9f, 0x3fce840be7490caf,
    0x3feaf286bca1e09f, 0x3fcfbc16b9011514, 0x3feac5701ac624ff, 0x3fd0790adbadc027,
    0x3fea98ef606a9dbf, 0x3fd11307dad24218, 0x3fea6d01a6d0cf5b, 0x3fd1ac05b28f7844,
    0x3fea41a41a41297d, 0x3fd24407ab0fb668, 0x3fea16d3f97978e2, 0x3fd2db10fc508256,
    0x3fe9ec8e95105eca, 0x3fd37124cea434fc, 0x3fe9c2d14ee3ab1e, 0x3fd406463b1e759a,
    0x3fe999999998b16f, 0x3fd49a784bd060e8, 0x3fe970e4f80d8959, 0x3fd52dbdfc49a08b,
    0x3fe948b0fcd65c4a, 0x3fd5c01a39fddb95, 0x3fe920fb49d11a21, 0x3fd6518fe466ae00,
    0x3fe8f9c18f9c4c0f, 0x3fd6e221cd9c5005, 0x3fe8d3018d30b20a, 0x3fd771d2ba7cc15c,
    0x3fe8acb90f6c0b26, 0x3fd800a56315c472, 0x3fe886e5f0abc008, 0x3fd88e9c72e076e1,
    0x3fe861861860d371, 0x3fd91bba8921bb9c, 0x3fe83c977ab21aaf, 0x3fd9a802392094a6,
    0x3fe81818181771e6, 0x3fda33760a81dd34, 0x3fe7f405fd01bdcd, 0x3fdabe18797e2e2d,
    0x3fe7d05f417dd809, 0x3fdb47ebf7355417, 0x3fe7ad2208e1241d, 0x3fdbd0f2e9e6b856,
    0x3fe78a4c81793167, 0x3fdc592fad2733c7, 0x3fe767dce4349bad, 0x3fdce0a4923a8fc7,
    0x3fe745d1745df36f, 0x3fdd6753e02f8097, 0x3fe724287f47a28b, 0x3fdded3fd43f2908,
    0x3fe702e05c0a9328, 0x3fde726aa1eb10ed, 0x3fe6e1f76b42a623, 0x3fdef6d6732b2dca,
    0x3fe6c16c16c19bf9, 0x3fdf7a8568ca4484, 0x3fe6a13cd1531cf1, 0x3fdffd799a855cf4,
    0x3fe68168168170b4, 0x3fe03fda8b9787d3, 0x3fe661ec6a506afc, 0x3fe0809cf280ebbc,
    0x3fe642c8590c06b4, 0x3fe0c10500d45f16, 0x3fe623fa77016a2d, 0x3fe10113b153b863,
    0x3fe6058160586486, 0x3fe140c9faa140b1, 0x3fe5e75bb8cf19b1, 0x3fe18028cf74ab00,
    0x3fe5c9882b93331f, 0x3fe1bf311e95865b, 0x3fe5ac056b011752, 0x3fe1fde3d30f10cb,
    0x3fe58ed23081846a, 0x3fe23c41d426caa7, 0x3fe571ed3c5098cc, 0x3fe27a4c058569dd,
    0x3fe55555555565b2, 0xbfda8ff97181512f, 0x3fe5390948f399d4, 0xbfda152f14277ff1,
    0x3fe51d07eae25f1e, 0xbfd99b072a9429c1, 0x3fe501501501d17e, 0xbfd9218009271615,
    0x3fe4e5e0a72eb123, 0xbfd8a8980abe49ad, 0x3fe4cab8872698d7, 0xbfd8304d90c52c58,
    0x3fe4afd6a052aff3, 0xbfd7b89f02cee5ec, 0x3fe49539e3b34f8c, 0xbfd7418acebe2bea,
    0x3fe47ae147ae2fd2, 0xbfd6cb0f6866442d, 0x3fe460cbc7f5ccd6, 0xbfd6552b499855ef,
    0x3fe446f865628c84, 0xbfd5dfdcf1ed4d52, 0x3fe42d6625d4b75d, 0xbfd56b22e6b39c3c,
    0x3fe414141413acbe, 0xbfd4f6fbb2ccea65, 0x3fe3fb013fb10bf6, 0xbfd48365e69a518a,
    0x3fe3e22cbce4861e, 0xbfd4106017c34a9b, 0x3fe3c995a47bf67d, 0xbfd39de8e156fb77,
    0x3fe3b13b13b1ac72, 0xbfd32bfee37301f7, 0x3fe3991c2c18b343, 0xbfd2baa0c34cd651,
    0x3fe381381380a51e, 0xbfd249cd2b1115be, 0x3fe3698df3ddab8d, 0xbfd1d982c9d372bc,
    0x3fe3521cfb2c1f3a, 0xbfd169c053670ce7, 0x3fe33ae45b5824da, 0xbfd0fa848046a76c,
    0x3fe323e34a2bfc50, 0xbfd08bce0d9a6a96, 0x3fe30d1901305e86, 0xbfd01d9bbcf83449,
    0x3fe2f684bda0ad76, 0xbfcf5fd8a9014cc3, 0x3fe2e025c04be197, 0xbfce857d3d39c862,
    0x3fe2c9fb4d803821, 0xbfcdac22d3daded7, 0x3fe2b404ad012844, 0xbfccd3c712d2f38f,
    0x3fe29e4129e3a3ef, 0xbfcbfc67a7fbaaf8, 0x3fe288b012885e4b, 0xbfcb2602497a2474,
    0x3fe27350b88209ac, 0xbfca5094b55602c6, 0x3fe25e22707fdd29, 0xbfc97c1cb1355b29,
    0x3fe249249249dbc3, 0xbfc8a8980ac6f736, 0x3fe23456789b7d34, 0xbfc7d60496d75a4e,
    0x3fe21fb781227c5a, 0xbfc7046031ccc0b5, 0x3fe20b470c6767e7, 0xbfc633a8bf3fee9f,
    0x3fe1f7047dc01f7d, 0xbfc563dc29f565bb, 0x3fe1e2ef3b3ee1df, 0xbfc494f863b037ca,
    0x3fe1cf06ada36398, 0xbfc3c6fb65160ac7, 0x3fe1bb4a4046540e, 0xbfc2f9e32d55c34e,
    0x3fe1a7b9611b19bc, 0xbfc22dadc2b1aabf, 0x3fe19453808bda4b, 0xbfc16259317ea230,
    0x3fe181181180a9e7, 0xbfc097e38ce17c11, 0x3fe16e068941d23b, 0xbfbf9c95dc0fb8bf,
    0x3fe15b1e5f74bdc8, 0xbfbe0b1ae8ea3d3a, 0x3fe1485f0e0a8a1f, 0xbfbc7b528b6b579d,
    0x3fe135c811359e80, 0xbfbaed391ab2eb45, 0x3fe12358e75c730e, 0xbfb960caf99bcba4,
    0x3fe111111110e212, 0xbfb7d60496cbc247, 0x3fe0fef010ffe27b, 0xbfb64ce26c1b0524,
    0x3fe0ecf56be648da, 0xbfb4c560fe618ce8, 0x3fe0db20a8902fef, 0xbfb33f7cde28c840,
    0x3fe0c9714fbbf1a4, 0xbfb1bb32a5ec5767, 0x3fe0b7e6ec24fe5a, 0xbfb0387efbbcc4a6,
    0x3fe0a6810a681e3a, 0xbfad6ebd1f224645, 0x3fe0953f3901f778, 0xbfaa6f9c37a742a9,
    0x3fe0842108426a0d, 0xbfa77394c9e8fd24, 0x3fe073260a483935, 0xbfa47aa07362ea75,
    0x3fe0624dd2f26f2d, 0xbfa184b8e4e82535, 0x3fe05197f7d7f0be, 0xbf9d23afc4d3f731,
    0x3fe0410410417bc2, 0xbf9743ee8649b454, 0x3fe03091b51fd99c, 0xbf916a21e236104e,
    0x3fe0204081026480, 0xbf872c7ba2547e55, 0x3fe01010100f7d9f, 0xbf7720d9bf98115b,
    0x3fe0000000000000, 0x0000000000000000,
];

// f64 log2: libsystem_m `log2(x)`.

export function appleLog2(x: f64): f64 {
    let ix = reinterpret<u64>(x);
    if (ix - 0x0010000000000000 >= 0x7fe0000000000000) {
        // Zero, subnormal, negative, inf or NaN.
        if (isNaN(x)) return x;
        if (x == 0.0) return -Infinity;
        if (x < 0.0) return reinterpret<f64>(<u64>0x7ff0000000000000) - reinterpret<f64>(<u64>0x7ff0000000000000);
        if (<i64>(ix - 0x0010000000000000) >= 0) return x; // +inf
        // Subnormal: scale by 2^52 exactly, then take 1022 off the exponent.
        const s = reinterpret<f64>(ix | 0x3ff0000000000000) - 1.0;
        ix = reinterpret<u64>(s) + 0xc020000000000000;
    }
    const e = <i64>(ix + 0xc018100000000000) >> 52;
    const m = ix & 0xfffffffffffff;
    const i = <i32>((m + 0x100000000000) >> 45);
    const z = reinterpret<f64>(m | 0x3ff0000000000000);
    const c = reinterpret<f64>(unchecked(LOG2_TABLE[2 * i]));
    const lc = reinterpret<f64>(unchecked(LOG2_TABLE[2 * i + 1]));
    const r = fmaF64(z, c, -1.0);
    const a = fmaF64(r, d(unchecked(LOG2_POLY[1])), d(unchecked(LOG2_POLY[0])));
    const b = fmaF64(r, r + d(unchecked(LOG2_POLY[3])), d(unchecked(LOG2_POLY[2])));
    const cc = fmaF64(r, r + d(unchecked(LOG2_POLY[5])), d(unchecked(LOG2_POLY[4])));
    let p = r * r;
    p = p * a;
    p = p * b;
    p = p * cc;
    const INV_LN2_HI = d(0x3ff7154760000000);
    if (e != 0) {
        const hi = reinterpret<f64>(reinterpret<u64>(lc) & 0xfffffffff8000000);
        let lo = (lc - hi) + p;
        lo = fmaF64(r, d(0x3ff71547652b82fe), lo); // r / ln 2
        return (<f64>e + hi) + lo;
    }
    // x near 1: r in extra precision.
    let t = c * z;
    const rh0 = t - 1.0;
    t = fmaF64(c, z, -t);
    let res = r * d(0x3e54ae0bf85ddf44); // r * (1/ln 2)_lo
    const rh = reinterpret<f64>(reinterpret<u64>(r) & 0xfffffffff8000000);
    const rl = t + (rh0 - rh);
    const rhs = rh * INV_LN2_HI;
    const s = lc + rhs;
    const serr = rhs - (s - lc);
    res = fmaF64(rl, INV_LN2_HI, res);
    res = res + serr;
    res = res + p;
    return res + s;
}
