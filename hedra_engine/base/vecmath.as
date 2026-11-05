// Derived from glam (MIT OR Apache-2.0); see THIRD_PARTY_NOTICES.md
//
// f32 vector, quaternion and matrix math. The operation order of every
// function is fixed so results are reproducible bit for bit; do not
// "simplify" an expression, reorder a sum or fuse a multiply-add.
//
// Vec2, Vec3 and Mat3 use plain scalar arithmetic. Vec4, Quat and Mat4 follow
// a 4-lane SIMD evaluation order, which changes the last bit in a few places:
//   * dot4 / Vec4.dot / Quat.dot sum pairwise: (x*x' + y*y') + (z*z' + w*w').
//   * the 3-lane dot used by the Mat4 determinant, the lengths in
//     Mat4.toScaleRotationTranslation and Quat * Vec3 is the scalar
//     (x*x' + y*y') + z*z', not pairwise.
//     (A pairwise (x*x' + y*y') + (z*z' + 0.0) differs when every product
//     is -0.0: the determinant becomes +0.0, and toScaleRotationTranslation
//     then flips the sign of scale.x for flattened, rotated matrices.)
//   * Mat4.inverse's determinant is a pairwise dot4.
//   * Quat.slerp uses a polynomial sine (f32x4Sin), not libm.
//   * Quat * Quat and Quat * Vec3 follow the 4-lane arithmetic.
// No operation is fused, and WebAssembly has no FMA, so the arithmetic is
// exact to the recorded values. The transcendentals come from libm.as
// (Apple libsystem_m results), including the combined sine and cosine
// (sinCosf) the rotation constructors use. tests/core/base_vecmath_test.as
// checks all of it against recorded reference values.
//
// Value semantics: every type is a rasc `struct` (a value type, copied on
// assignment and never heap-allocated). So `let b = a; b.x = 1;` leaves `a`
// alone. Methods are `readonly` and return new values (the one exception is
// `set(i, s)`); there are no in-place variants because structs cost no
// allocation. Limits of rasc structs you must know:
//   * no static members on a struct: constants and constructors live in a
//     namespace of the same name (`VEC3_ZERO`, `Vec3.splat(1)`,
//     `Mat4.fromTranslation(t)`);
//   * one overload per operator and per method name: `a * s` is scalar
//     (Vec3 * f32) and component-wise products are `a.mul(b)`; `s * a`
//     (f32 on the left) does not exist, write `a * s` (same bits);
//   * structs cannot be nullable (an optional Vec3 needs a flag or a class)
//     and cannot be generic arguments (`Result<Vec3>` is rejected), but
//     `Array<Vec3>`, `StaticArray<Vec3>`, `Map<K, Vec3>` and struct fields in
//     classes work;
//   * multiple results come back as small structs (ScaleRotationTranslation,
//     AxisAngle, Vec3Pair); Euler angle triples are Vec3.
//
// Construct with `Vec3(x, y, z)` (or `vec3(x, y, z)`); the camera matrices
// live in the `camera` namespace (`camera.lookAtMat4Rh`).

import { roundF32, signumF32, f32ToI32, clampF32, panic } from "./util";
import {
    SinCos, appleSincosf, appleSinf, appleCosf, appleTanf, appleAsinf, appleAcosf, appleAtanf, appleAtan2f,
    applePowf, appleExpf, appleExp2f, appleLogf, appleLog2f,
} from "./libm";
import { displayF32, debugF32, fixedF32, displayF64, debugF64, fixedF64, debugTuple, debugStruct } from "./fmt";

// ---------------------------------------------------------------------------
// f32 scalar math

const F32_PI: f32 = 3.14159265358979323846;
const F32_FRAC_PI_2: f32 = 1.57079632679489661923;
const F32_TAU: f32 = 6.28318530717958647692;

// DirectXMath's XMScalarAcos polynomial, which is what Vec3.angleBetween,
// Quat.angleBetween and the slerps use.
export function acosApprox(v: f32): f32 {
    const nonnegative = v >= <f32>0.0;
    const x = Mathf.abs(v);
    let omx: f32 = <f32>1.0 - x;
    if (omx < <f32>0.0) omx = <f32>0.0;
    const root = Mathf.sqrt(omx);
    let result: f32 =
        ((((((<f32>-0.0012624911 * x + <f32>0.00667009) * x - <f32>0.017088126) * x + <f32>0.03089188) * x
            - <f32>0.050174303)
            * x
            + <f32>0.08897899)
            * x
            - <f32>0.2145988)
            * x
            + <f32>1.5707963;
    result *= root;
    if (nonnegative) return result;
    return F32_PI - result;
}

// One lane of a 4-lane polynomial sine (DirectXMath XMVectorSin, 11-degree
// minimax). Only Quat.slerp uses it.
function f32x4Sin(v: f32): f32 {
    // angles - round_even(angles / TAU) * TAU
    const q = nearest<f32>(v * <f32>0.15915494);
    let x: f32 = v - q * F32_TAU;
    const c = copysign<f32>(F32_PI, x);
    const absx = Mathf.abs(x);
    const rflx = c - x;
    if (!(absx <= F32_FRAC_PI_2)) x = rflx;
    const x2 = x * x;
    let result: f32 = <f32>2.7525562e-6 + x2 * <f32>-2.3889859e-8;
    result = <f32>-0.00019840874 + result * x2;
    result = <f32>0.008333331 + result * x2;
    result = <f32>-0.16666667 + result * x2;
    result = <f32>1.0 + result * x2;
    return result * x;
}

// ---------------------------------------------------------------------------
// f32 transcendentals. These return Apple libsystem_m's results (libm.as),
// which are not correctly rounded; see libm.as's header for when to use
// sinCosf. Use these for every sine, power, log etc.; `Mathf.*` and musl's
// f64 routines rounded to f32 differ on up to 40% of inputs, and those ulps
// reach the recorded values. (sqrt, floor, ceil, trunc, abs are exact
// everywhere: use Mathf.*.)

export function sinf(x: f32): f32 { return appleSinf(x); }
export function cosf(x: f32): f32 { return appleCosf(x); }
// Sine and cosine of the same angle computed together: `.s` is the sine,
// `.c` the cosine. Not always equal to (sinf(x), cosf(x)).
export function sinCosf(x: f32): SinCos { return appleSincosf(x); }
export function tanf(x: f32): f32 { return appleTanf(x); }
export function asinf(x: f32): f32 { return appleAsinf(x); }
export function acosf(x: f32): f32 { return appleAcosf(x); }
export function atanf(x: f32): f32 { return appleAtanf(x); }
// Angle of (x, y).
export function atan2f(y: f32, x: f32): f32 { return appleAtan2f(y, x); }
// Powers and logarithms. Write 2^x as exp2f(x), not powf(2, x): the two can
// differ in the last bit.
export function powf(x: f32, n: f32): f32 { return applePowf(x, n); }
export function expf(x: f32): f32 { return appleExpf(x); }
export function exp2f(x: f32): f32 { return appleExp2f(x); }
export function lnf(x: f32): f32 { return appleLogf(x); }
export function log2f(x: f32): f32 { return appleLog2f(x); }

// x^n for an integer n by square-and-multiply (the multiplication order is fixed).
export function powif(a: f32, n: i32): f32 {
    const recip = n < 0;
    let b = n;
    let x = a;
    let r: f32 = 1;
    while (true) {
        if ((b & 1) != 0) r *= x;
        b = b / 2;
        if (b == 0) break;
        x *= x;
    }
    return recip ? <f32>1.0 / r : r;
}

// Euclidean remainder (never negative) and quotient.
export function remEuclidF32(a: f32, b: f32): f32 {
    const r = a % b;
    return r < <f32>0.0 ? r + Mathf.abs(b) : r;
}
export function divEuclidF32(a: f32, b: f32): f32 {
    const q = Mathf.trunc(a / b);
    if (a % b < <f32>0.0) return b > <f32>0.0 ? q - <f32>1.0 : q + <f32>1.0;
    return q;
}

// a + (b - a) * t.
export function lerpF32(a: f32, b: f32, t: f32): f32 {
    return a + (b - a) * t;
}

// Degrees <-> radians (a single multiply by an f32 constant).
export const RADS_PER_DEG: f32 = <f32>(<f32>3.14159265358979323846 / <f32>180.0);
export const DEGS_PER_RAD: f32 = 57.2957795130823208767981548141051703;
export function toRadians(x: f32): f32 { return x * RADS_PER_DEG; }
export function toDegrees(x: f32): f32 { return x * DEGS_PER_RAD; }

// Pairwise sum (see the header).
function dot4Pairwise(a0: f32, a1: f32, a2: f32, a3: f32, b0: f32, b1: f32, b2: f32, b3: f32): f32 {
    return (a0 * b0 + a1 * b1) + (a2 * b2 + a3 * b3);
}
// 3-lane dot: plain scalar order (see the header).
function dot3A(a0: f32, a1: f32, a2: f32, b0: f32, b1: f32, b2: f32): f32 {
    return (a0 * b0 + a1 * b1) + a2 * b2;
}

// ---------------------------------------------------------------------------
// Text forms (fmt.as does the float digits).
//   v.toString() / `${v}`   "[1, 2.5, -0]"
//   v.display(3)            "[1.000, 2.500, -0.000]"
//   v.debug()               "Vec3(1.0, 2.5, -0.0)"

function displayList(xs: Array<f32>, prec: i32): string {
    const parts: Array<string> = [];
    for (let i = 0; i < xs.length; i++) parts.push(prec < 0 ? displayF32(xs[i]) : fixedF32(xs[i], prec));
    return "[" + parts.join(", ") + "]";
}
function debugList32(name: string, xs: Array<f32>): string {
    const parts: Array<string> = [];
    for (let i = 0; i < xs.length; i++) parts.push(debugF32(xs[i]));
    return debugTuple(name, parts);
}

// ---------------------------------------------------------------------------
// Vec2 (scalar arithmetic)

export struct Vec2 {
    x: f32 = 0;
    y: f32 = 0;

    constructor(x: f32, y: f32) {
        this.x = x;
        this.y = y;
    }

    operator+(a: Vec2, b: Vec2): Vec2 { return Vec2(a.x + b.x, a.y + b.y); }
    operator-(a: Vec2, b: Vec2): Vec2 { return Vec2(a.x - b.x, a.y - b.y); }
    operator*(a: Vec2, s: f32): Vec2 { return Vec2(a.x * s, a.y * s); }
    operator/(a: Vec2, s: f32): Vec2 { return Vec2(a.x / s, a.y / s); }
    operator-(a: Vec2): Vec2 { return Vec2(-a.x, -a.y); }
    operator==(a: Vec2, b: Vec2): bool { return a.x == b.x && a.y == b.y; }
    // hash() adds +0.0 first so -0.0 and 0.0 (which compare equal) hash alike.
    readonly hash(): u32 { return reinterpret<u32>(this.x + <f32>0.0) * 73856093 ^ reinterpret<u32>(this.y + <f32>0.0) * 19349663; }
    readonly toString(): string { return this.display(-1); }
    readonly display(prec: i32 = -1): string { return displayList([this.x, this.y], prec); }
    readonly debug(): string { return debugList32("Vec2", [this.x, this.y]); }

    // Component-wise Vec2 * Vec2 and Vec2 / Vec2.
    readonly mul(o: Vec2): Vec2 { return Vec2(this.x * o.x, this.y * o.y); }
    readonly div(o: Vec2): Vec2 { return Vec2(this.x / o.x, this.y / o.y); }
    readonly addScalar(s: f32): Vec2 { return Vec2(this.x + s, this.y + s); }
    readonly subScalar(s: f32): Vec2 { return Vec2(this.x - s, this.y - s); }

    readonly withX(x: f32): Vec2 { return Vec2(x, this.y); }
    readonly withY(y: f32): Vec2 { return Vec2(this.x, y); }
    readonly extend(z: f32): Vec3 { return Vec3(this.x, this.y, z); }
    readonly toArray(): Array<f32> { return [this.x, this.y]; }
    // Component i (panics on i > 1); set(i, s) mutates this place.
    readonly get(i: i32): f32 {
        if (i == 0) return this.x;
        if (i == 1) return this.y;
        panic("index out of bounds");
        return 0;
    }
    set(i: i32, s: f32): void {
        if (i == 0) this.x = s;
        else if (i == 1) this.y = s;
        else panic("index out of bounds");
    }
    readonly map(f: (v: f32) => f32): Vec2 { return Vec2(f(this.x), f(this.y)); }

    readonly dot(rhs: Vec2): f32 { return (this.x * rhs.x) + (this.y * rhs.y); }
    readonly perp(): Vec2 { return Vec2(-this.y, this.x); }
    readonly perpDot(rhs: Vec2): f32 { return (this.x * rhs.y) - (this.y * rhs.x); }
    readonly rotate(rhs: Vec2): Vec2 {
        return Vec2(this.x * rhs.x - this.y * rhs.y, this.y * rhs.x + this.x * rhs.y);
    }
    readonly toAngle(): f32 { return atan2f(this.y, this.x); }
    readonly angleTo(rhs: Vec2): f32 {
        const angle = acosApprox(this.dot(rhs) / Mathf.sqrt(this.lengthSquared() * rhs.lengthSquared()));
        return angle * signumF32(this.perpDot(rhs));
    }

    readonly min(rhs: Vec2): Vec2 {
        return Vec2(this.x < rhs.x ? this.x : rhs.x, this.y < rhs.y ? this.y : rhs.y);
    }
    readonly max(rhs: Vec2): Vec2 {
        return Vec2(this.x > rhs.x ? this.x : rhs.x, this.y > rhs.y ? this.y : rhs.y);
    }
    readonly clamp(lo: Vec2, hi: Vec2): Vec2 { return this.max(lo).min(hi); }
    readonly minElement(): f32 { return this.x < this.y ? this.x : this.y; }
    readonly maxElement(): f32 { return this.x > this.y ? this.x : this.y; }
    readonly elementSum(): f32 { return this.x + this.y; }
    readonly elementProduct(): f32 { return this.x * this.y; }

    readonly abs(): Vec2 { return Vec2(Mathf.abs(this.x), Mathf.abs(this.y)); }
    readonly signum(): Vec2 { return Vec2(signumF32(this.x), signumF32(this.y)); }
    readonly floor(): Vec2 { return Vec2(Mathf.floor(this.x), Mathf.floor(this.y)); }
    readonly ceil(): Vec2 { return Vec2(Mathf.ceil(this.x), Mathf.ceil(this.y)); }
    readonly round(): Vec2 { return Vec2(roundF32(this.x), roundF32(this.y)); }
    readonly trunc(): Vec2 { return Vec2(Mathf.trunc(this.x), Mathf.trunc(this.y)); }
    readonly fract(): Vec2 { return this - this.trunc(); }
    readonly recip(): Vec2 { return Vec2(<f32>1.0 / this.x, <f32>1.0 / this.y); }

    readonly isFinite(): bool { return isFinite<f32>(this.x) && isFinite<f32>(this.y); }
    readonly isNan(): bool { return isNaN<f32>(this.x) || isNaN<f32>(this.y); }

    readonly length(): f32 { return Mathf.sqrt(this.dot(this)); }
    readonly lengthSquared(): f32 { return this.dot(this); }
    readonly lengthRecip(): f32 { return <f32>1.0 / this.length(); }
    readonly distance(rhs: Vec2): f32 { return (this - rhs).length(); }
    readonly distanceSquared(rhs: Vec2): f32 { return (this - rhs).lengthSquared(); }
    readonly normalize(): Vec2 { return this * this.lengthRecip(); }
    readonly normalizeOr(fallback: Vec2): Vec2 {
        const rcp = this.lengthRecip();
        if (isFinite<f32>(rcp) && rcp > <f32>0.0) return this * rcp;
        return fallback;
    }
    readonly normalizeOrZero(): Vec2 { return this.normalizeOr(Vec2(0, 0)); }
    readonly isNormalized(): bool { return Mathf.abs(this.lengthSquared() - <f32>1.0) <= <f32>2e-4; }
    readonly lerp(rhs: Vec2, s: f32): Vec2 { return this * (<f32>1.0 - s) + rhs * s; }
    readonly midpoint(rhs: Vec2): Vec2 { return (this + rhs) * <f32>0.5; }
    readonly absDiffEq(rhs: Vec2, maxAbsDiff: f32): bool {
        const d = (this - rhs).abs();
        return d.x <= maxAbsDiff && d.y <= maxAbsDiff;
    }
}

export const VEC2_ZERO: Vec2 = Vec2(0, 0);
export const VEC2_ONE: Vec2 = Vec2(1, 1);
export const VEC2_NEG_ONE: Vec2 = Vec2(-1, -1);
export const VEC2_X: Vec2 = Vec2(1, 0);
export const VEC2_Y: Vec2 = Vec2(0, 1);
export const VEC2_NEG_X: Vec2 = Vec2(-1, 0);
export const VEC2_NEG_Y: Vec2 = Vec2(0, -1);
export const VEC2_MIN: Vec2 = Vec2(-f32.MAX_VALUE, -f32.MAX_VALUE);
export const VEC2_MAX: Vec2 = Vec2(f32.MAX_VALUE, f32.MAX_VALUE);
export const VEC2_NAN: Vec2 = Vec2(NaN, NaN);
export const VEC2_INFINITY: Vec2 = Vec2(Infinity, Infinity);
export const VEC2_NEG_INFINITY: Vec2 = Vec2(-Infinity, -Infinity);
export namespace Vec2 {
    export function splat(v: f32): Vec2 { return Vec2(v, v); }
    export function fromArray(a: Array<f32>, offset: i32 = 0): Vec2 { return Vec2(a[offset], a[offset + 1]); }
    export function fromF32Array(a: Float32Array, offset: i32 = 0): Vec2 { return Vec2(a[offset], a[offset + 1]); }
    export function fromAngle(angle: f32): Vec2 {
        const sc = appleSincosf(angle);
        return Vec2(sc.c, sc.s);
    }
    // Sum as a fold that starts at ZERO.
    export function sum(vs: Array<Vec2>): Vec2 {
        let acc = Vec2(0, 0);
        for (let i = 0; i < vs.length; i++) acc = acc + vs[i];
        return acc;
    }
}

export function vec2(x: f32, y: f32): Vec2 { return Vec2(x, y); }

// ---------------------------------------------------------------------------
// Vec3 (scalar arithmetic)

export struct Vec3 {
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;

    constructor(x: f32, y: f32, z: f32) {
        this.x = x;
        this.y = y;
        this.z = z;
    }

    operator+(a: Vec3, b: Vec3): Vec3 { return Vec3(a.x + b.x, a.y + b.y, a.z + b.z); }
    operator-(a: Vec3, b: Vec3): Vec3 { return Vec3(a.x - b.x, a.y - b.y, a.z - b.z); }
    operator*(a: Vec3, s: f32): Vec3 { return Vec3(a.x * s, a.y * s, a.z * s); }
    operator/(a: Vec3, s: f32): Vec3 { return Vec3(a.x / s, a.y / s, a.z / s); }
    operator-(a: Vec3): Vec3 { return Vec3(-a.x, -a.y, -a.z); }
    operator==(a: Vec3, b: Vec3): bool { return a.x == b.x && a.y == b.y && a.z == b.z; }
    readonly hash(): u32 {
        return reinterpret<u32>(this.x + <f32>0.0) * 73856093 ^ reinterpret<u32>(this.y + <f32>0.0) * 19349663 ^ reinterpret<u32>(this.z + <f32>0.0) * 83492791;
    }
    readonly toString(): string { return this.display(-1); }
    readonly display(prec: i32 = -1): string { return displayList([this.x, this.y, this.z], prec); }
    readonly debug(): string { return debugList32("Vec3", [this.x, this.y, this.z]); }

    // Component-wise Vec3 * Vec3 and Vec3 / Vec3.
    readonly mul(o: Vec3): Vec3 { return Vec3(this.x * o.x, this.y * o.y, this.z * o.z); }
    readonly div(o: Vec3): Vec3 { return Vec3(this.x / o.x, this.y / o.y, this.z / o.z); }
    readonly addScalar(s: f32): Vec3 { return Vec3(this.x + s, this.y + s, this.z + s); }
    readonly subScalar(s: f32): Vec3 { return Vec3(this.x - s, this.y - s, this.z - s); }
    // Component-wise fmod (the sign follows the dividend).
    readonly rem(o: Vec3): Vec3 { return Vec3(this.x % o.x, this.y % o.y, this.z % o.z); }

    readonly withX(x: f32): Vec3 { return Vec3(x, this.y, this.z); }
    readonly withY(y: f32): Vec3 { return Vec3(this.x, y, this.z); }
    readonly withZ(z: f32): Vec3 { return Vec3(this.x, this.y, z); }
    readonly extend(w: f32): Vec4 { return Vec4(this.x, this.y, this.z, w); }
    readonly truncate(): Vec2 { return Vec2(this.x, this.y); }
    readonly xy(): Vec2 { return Vec2(this.x, this.y); }
    readonly xz(): Vec2 { return Vec2(this.x, this.z); }
    readonly yz(): Vec2 { return Vec2(this.y, this.z); }
    readonly toArray(): Array<f32> { return [this.x, this.y, this.z]; }
    readonly writeToF32Array(a: Float32Array, offset: i32): void {
        a[offset] = this.x;
        a[offset + 1] = this.y;
        a[offset + 2] = this.z;
    }
    // Component i (panics on i > 2).
    readonly get(i: i32): f32 {
        if (i == 0) return this.x;
        if (i == 1) return this.y;
        if (i == 2) return this.z;
        panic("index out of bounds");
        return 0;
    }
    // Sets component i. Mutates the place it is called on:
    // `mesh.co.set(axis, 0)` writes the field, `let c = mesh.co; c.set(..)` a copy.
    // rasc rejects a mutating call on an array element (`arr[i].set(..)`):
    // write the field (`arr[i].x = s`) or copy, set and store back.
    set(i: i32, s: f32): void {
        if (i == 0) this.x = s;
        else if (i == 1) this.y = s;
        else if (i == 2) this.z = s;
        else panic("index out of bounds");
    }
    readonly map(f: (v: f32) => f32): Vec3 { return Vec3(f(this.x), f(this.y), f(this.z)); }
    readonly asIVec3(): IVec3 { return IVec3(f32ToI32(this.x), f32ToI32(this.y), f32ToI32(this.z)); }
    readonly asDVec3(): DVec3 { return DVec3(<f64>this.x, <f64>this.y, <f64>this.z); }

    readonly dot(rhs: Vec3): f32 { return (this.x * rhs.x) + (this.y * rhs.y) + (this.z * rhs.z); }
    readonly cross(rhs: Vec3): Vec3 {
        return Vec3(
            this.y * rhs.z - rhs.y * this.z,
            this.z * rhs.x - rhs.z * this.x,
            this.x * rhs.y - rhs.x * this.y,
        );
    }

    readonly min(rhs: Vec3): Vec3 {
        return Vec3(this.x < rhs.x ? this.x : rhs.x, this.y < rhs.y ? this.y : rhs.y, this.z < rhs.z ? this.z : rhs.z);
    }
    readonly max(rhs: Vec3): Vec3 {
        return Vec3(this.x > rhs.x ? this.x : rhs.x, this.y > rhs.y ? this.y : rhs.y, this.z > rhs.z ? this.z : rhs.z);
    }
    readonly clamp(lo: Vec3, hi: Vec3): Vec3 { return this.max(lo).min(hi); }
    readonly minElement(): f32 {
        const yz = this.y < this.z ? this.y : this.z;
        return this.x < yz ? this.x : yz;
    }
    readonly maxElement(): f32 {
        const yz = this.y > this.z ? this.y : this.z;
        return this.x > yz ? this.x : yz;
    }
    readonly minPosition(): i32 {
        let m = this.x;
        let index = 0;
        if (this.y < m) { m = this.y; index = 1; }
        if (this.z < m) index = 2;
        return index;
    }
    readonly maxPosition(): i32 {
        let m = this.x;
        let index = 0;
        if (this.y > m) { m = this.y; index = 1; }
        if (this.z > m) index = 2;
        return index;
    }
    readonly elementSum(): f32 { return this.x + this.y + this.z; }
    readonly elementProduct(): f32 { return this.x * this.y * this.z; }

    readonly abs(): Vec3 { return Vec3(Mathf.abs(this.x), Mathf.abs(this.y), Mathf.abs(this.z)); }
    readonly signum(): Vec3 { return Vec3(signumF32(this.x), signumF32(this.y), signumF32(this.z)); }
    readonly copysign(rhs: Vec3): Vec3 {
        return Vec3(copysign<f32>(this.x, rhs.x), copysign<f32>(this.y, rhs.y), copysign<f32>(this.z, rhs.z));
    }
    readonly floor(): Vec3 { return Vec3(Mathf.floor(this.x), Mathf.floor(this.y), Mathf.floor(this.z)); }
    readonly ceil(): Vec3 { return Vec3(Mathf.ceil(this.x), Mathf.ceil(this.y), Mathf.ceil(this.z)); }
    readonly round(): Vec3 { return Vec3(roundF32(this.x), roundF32(this.y), roundF32(this.z)); }
    readonly trunc(): Vec3 { return Vec3(Mathf.trunc(this.x), Mathf.trunc(this.y), Mathf.trunc(this.z)); }
    readonly fract(): Vec3 { return this - this.trunc(); }
    readonly fractGl(): Vec3 { return this - this.floor(); }
    readonly recip(): Vec3 { return Vec3(<f32>1.0 / this.x, <f32>1.0 / this.y, <f32>1.0 / this.z); }
    readonly sqrt(): Vec3 { return Vec3(Mathf.sqrt(this.x), Mathf.sqrt(this.y), Mathf.sqrt(this.z)); }
    readonly powf(n: f32): Vec3 {
        return Vec3(applePowf(this.x, n), applePowf(this.y, n), applePowf(this.z, n));
    }

    readonly isFinite(): bool { return isFinite<f32>(this.x) && isFinite<f32>(this.y) && isFinite<f32>(this.z); }
    readonly isNan(): bool { return isNaN<f32>(this.x) || isNaN<f32>(this.y) || isNaN<f32>(this.z); }

    readonly length(): f32 { return Mathf.sqrt(this.dot(this)); }
    readonly lengthSquared(): f32 { return this.dot(this); }
    readonly lengthRecip(): f32 { return <f32>1.0 / this.length(); }
    readonly distance(rhs: Vec3): f32 { return (this - rhs).length(); }
    readonly distanceSquared(rhs: Vec3): f32 { return (this - rhs).lengthSquared(); }

    readonly normalize(): Vec3 { return this * this.lengthRecip(); }
    readonly normalizeOr(fallback: Vec3): Vec3 {
        const rcp = this.lengthRecip();
        if (isFinite<f32>(rcp) && rcp > <f32>0.0) return this * rcp;
        return fallback;
    }
    readonly normalizeOrZero(): Vec3 { return this.normalizeOr(Vec3(0, 0, 0)); }
    // Whether the length is finite and non-zero, so normalize() is meaningful.
    readonly canNormalize(): bool {
        const rcp = this.lengthRecip();
        return isFinite<f32>(rcp) && rcp > <f32>0.0;
    }
    readonly isNormalized(): bool { return Mathf.abs(this.lengthSquared() - <f32>1.0) <= <f32>2e-4; }

    readonly projectOnto(rhs: Vec3): Vec3 {
        const otherLenSqRcp = <f32>1.0 / rhs.dot(rhs);
        return rhs * this.dot(rhs) * otherLenSqRcp;
    }
    readonly rejectFrom(rhs: Vec3): Vec3 { return this - this.projectOnto(rhs); }
    readonly projectOntoNormalized(rhs: Vec3): Vec3 { return rhs * this.dot(rhs); }
    readonly rejectFromNormalized(rhs: Vec3): Vec3 { return this - this.projectOntoNormalized(rhs); }
    // self - 2.0 * self.dot(normal) * normal
    readonly reflect(normal: Vec3): Vec3 { return this - normal * (<f32>2.0 * this.dot(normal)); }

    readonly lerp(rhs: Vec3, s: f32): Vec3 { return this * (<f32>1.0 - s) + rhs * s; }
    readonly midpoint(rhs: Vec3): Vec3 { return (this + rhs) * <f32>0.5; }
    readonly moveTowards(rhs: Vec3, d: f32): Vec3 {
        const a = rhs - this;
        const len = a.length();
        if (len <= d || len <= <f32>1e-4) return rhs;
        return this + a / len * d;
    }
    readonly absDiffEq(rhs: Vec3, maxAbsDiff: f32): bool {
        const d = (this - rhs).abs();
        return d.x <= maxAbsDiff && d.y <= maxAbsDiff && d.z <= maxAbsDiff;
    }

    readonly angleBetween(rhs: Vec3): f32 {
        return acosApprox(this.dot(rhs) / Mathf.sqrt(this.lengthSquared() * rhs.lengthSquared()));
    }
    readonly angleTo(rhs: Vec3, axis: Vec3): f32 {
        return atan2f(this.cross(rhs).dot(axis), this.dot(rhs));
    }
    readonly rotateX(angle: f32): Vec3 {
        const sc = appleSincosf(angle);
        const sina = sc.s;
        const cosa = sc.c;
        return Vec3(this.x, this.y * cosa - this.z * sina, this.y * sina + this.z * cosa);
    }
    readonly rotateY(angle: f32): Vec3 {
        const sc = appleSincosf(angle);
        const sina = sc.s;
        const cosa = sc.c;
        return Vec3(this.x * cosa + this.z * sina, this.y, this.x * -sina + this.z * cosa);
    }
    readonly rotateZ(angle: f32): Vec3 {
        const sc = appleSincosf(angle);
        const sina = sc.s;
        const cosa = sc.c;
        return Vec3(this.x * cosa - this.y * sina, this.x * sina + this.y * cosa, this.z);
    }
    readonly rotateAxis(axis: Vec3, angle: f32): Vec3 { return Quat.fromAxisAngle(axis, angle).mulVec3(this); }

    readonly anyOrthogonalVector(): Vec3 {
        if (Mathf.abs(this.x) > Mathf.abs(this.y)) return Vec3(-this.z, 0, this.x);
        return Vec3(0, this.z, -this.y);
    }
    // Pixar's branchless ONB; `this` must be normalized.
    readonly anyOrthonormalVector(): Vec3 {
        const sign = signumF32(this.z);
        const a = <f32>-1.0 / (sign + this.z);
        const b = this.x * this.y * a;
        return Vec3(b, sign + this.y * this.y * a, -this.y);
    }
    readonly anyOrthonormalPair(): Vec3Pair {
        const sign = signumF32(this.z);
        const a = <f32>-1.0 / (sign + this.z);
        const b = this.x * this.y * a;
        return Vec3Pair(
            Vec3(<f32>1.0 + sign * this.x * this.x * a, sign * b, -sign * this.x),
            Vec3(b, sign + this.y * this.y * a, -this.y),
        );
    }

    readonly slerp(rhs: Vec3, s: f32): Vec3 {
        const selfLength = this.length();
        const rhsLength = rhs.length();
        const dot = this.dot(rhs) / (selfLength * rhsLength);
        if (Mathf.abs(dot) < <f32>1.0 - <f32>3e-7) {
            const theta = acosApprox(dot);
            const sinTheta = sinf(theta);
            const t1 = sinf(theta * (<f32>1.0 - s));
            const t2 = sinf(theta * s);
            const resultLength = lerpF32(selfLength, rhsLength, s);
            return (this * (resultLength / selfLength) * t1 + rhs * (resultLength / rhsLength) * t2) * (<f32>1.0 / sinTheta);
        }
        if (dot < <f32>0.0) {
            const axis = this.anyOrthogonalVector().normalize();
            const rotation = Quat.fromAxisAngle(axis, F32_PI * s);
            const resultLength = lerpF32(selfLength, rhsLength, s);
            return rotation.mulVec3(this) * (resultLength / selfLength);
        }
        return this.lerp(rhs, s);
    }
}

export const VEC3_ZERO: Vec3 = Vec3(0, 0, 0);
export const VEC3_ONE: Vec3 = Vec3(1, 1, 1);
export const VEC3_NEG_ONE: Vec3 = Vec3(-1, -1, -1);
export const VEC3_X: Vec3 = Vec3(1, 0, 0);
export const VEC3_Y: Vec3 = Vec3(0, 1, 0);
export const VEC3_Z: Vec3 = Vec3(0, 0, 1);
export const VEC3_NEG_X: Vec3 = Vec3(-1, 0, 0);
export const VEC3_NEG_Y: Vec3 = Vec3(0, -1, 0);
export const VEC3_NEG_Z: Vec3 = Vec3(0, 0, -1);
// VEC3_MIN is the most negative finite value, not the smallest positive one.
export const VEC3_MIN: Vec3 = Vec3(-f32.MAX_VALUE, -f32.MAX_VALUE, -f32.MAX_VALUE);
export const VEC3_MAX: Vec3 = Vec3(f32.MAX_VALUE, f32.MAX_VALUE, f32.MAX_VALUE);
export const VEC3_NAN: Vec3 = Vec3(NaN, NaN, NaN);
export const VEC3_INFINITY: Vec3 = Vec3(Infinity, Infinity, Infinity);
export const VEC3_NEG_INFINITY: Vec3 = Vec3(-Infinity, -Infinity, -Infinity);
export namespace Vec3 {
    export function splat(v: f32): Vec3 { return Vec3(v, v, v); }
    export function fromArray(a: Array<f32>, offset: i32 = 0): Vec3 { return Vec3(a[offset], a[offset + 1], a[offset + 2]); }
    export function fromF32Array(a: Float32Array, offset: i32 = 0): Vec3 { return Vec3(a[offset], a[offset + 1], a[offset + 2]); }
    export function fromVec4(v: Vec4): Vec3 { return Vec3(v.x, v.y, v.z); }
    // Sum as a fold that starts at ZERO (so -0.0 sums to +0.0).
    export function sum(vs: Array<Vec3>): Vec3 {
        let acc = Vec3(0, 0, 0);
        for (let i = 0; i < vs.length; i++) acc = acc + vs[i];
        return acc;
    }
}

export function vec3(x: f32, y: f32, z: f32): Vec3 { return Vec3(x, y, z); }

// Two vectors, e.g. from anyOrthonormalPair.
export struct Vec3Pair {
    a: Vec3 = Vec3(0, 0, 0);
    b: Vec3 = Vec3(0, 0, 0);
    constructor(a: Vec3, b: Vec3) {
        this.a = a;
        this.b = b;
    }
}

// ---------------------------------------------------------------------------
// Vec4 (lane-wise ops are plain f32 ops; dot is pairwise)

export struct Vec4 {
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;
    w: f32 = 0;

    constructor(x: f32, y: f32, z: f32, w: f32) {
        this.x = x;
        this.y = y;
        this.z = z;
        this.w = w;
    }

    operator+(a: Vec4, b: Vec4): Vec4 { return Vec4(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w); }
    operator-(a: Vec4, b: Vec4): Vec4 { return Vec4(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w); }
    operator*(a: Vec4, s: f32): Vec4 { return Vec4(a.x * s, a.y * s, a.z * s, a.w * s); }
    operator/(a: Vec4, s: f32): Vec4 { return Vec4(a.x / s, a.y / s, a.z / s, a.w / s); }
    operator-(a: Vec4): Vec4 { return Vec4(-a.x, -a.y, -a.z, -a.w); }
    operator==(a: Vec4, b: Vec4): bool { return a.x == b.x && a.y == b.y && a.z == b.z && a.w == b.w; }
    readonly hash(): u32 {
        return reinterpret<u32>(this.x + <f32>0.0) * 73856093 ^ reinterpret<u32>(this.y + <f32>0.0) * 19349663
            ^ reinterpret<u32>(this.z + <f32>0.0) * 83492791 ^ reinterpret<u32>(this.w + <f32>0.0) * 2654435761;
    }
    readonly toString(): string { return this.display(-1); }
    readonly display(prec: i32 = -1): string { return displayList([this.x, this.y, this.z, this.w], prec); }
    readonly debug(): string { return debugList32("Vec4", [this.x, this.y, this.z, this.w]); }

    readonly mul(o: Vec4): Vec4 { return Vec4(this.x * o.x, this.y * o.y, this.z * o.z, this.w * o.w); }
    readonly div(o: Vec4): Vec4 { return Vec4(this.x / o.x, this.y / o.y, this.z / o.z, this.w / o.w); }

    readonly truncate(): Vec3 { return Vec3(this.x, this.y, this.z); }
    readonly xyz(): Vec3 { return Vec3(this.x, this.y, this.z); }
    readonly xy(): Vec2 { return Vec2(this.x, this.y); }
    readonly withW(w: f32): Vec4 { return Vec4(this.x, this.y, this.z, w); }
    readonly toArray(): Array<f32> { return [this.x, this.y, this.z, this.w]; }
    readonly get(i: i32): f32 {
        if (i == 0) return this.x;
        if (i == 1) return this.y;
        if (i == 2) return this.z;
        if (i == 3) return this.w;
        panic("index out of bounds");
        return 0;
    }
    set(i: i32, s: f32): void {
        if (i == 0) this.x = s;
        else if (i == 1) this.y = s;
        else if (i == 2) this.z = s;
        else if (i == 3) this.w = s;
        else panic("index out of bounds");
    }

    readonly dot(rhs: Vec4): f32 { return dot4Pairwise(this.x, this.y, this.z, this.w, rhs.x, rhs.y, rhs.z, rhs.w); }
    readonly min(rhs: Vec4): Vec4 {
        // NaN in either lane gives NaN.
        return Vec4(Mathf.min(this.x, rhs.x), Mathf.min(this.y, rhs.y), Mathf.min(this.z, rhs.z), Mathf.min(this.w, rhs.w));
    }
    readonly max(rhs: Vec4): Vec4 {
        return Vec4(Mathf.max(this.x, rhs.x), Mathf.max(this.y, rhs.y), Mathf.max(this.z, rhs.z), Mathf.max(this.w, rhs.w));
    }
    readonly abs(): Vec4 { return Vec4(Mathf.abs(this.x), Mathf.abs(this.y), Mathf.abs(this.z), Mathf.abs(this.w)); }
    readonly isFinite(): bool {
        return isFinite<f32>(this.x) && isFinite<f32>(this.y) && isFinite<f32>(this.z) && isFinite<f32>(this.w);
    }
    readonly isNan(): bool { return isNaN<f32>(this.x) || isNaN<f32>(this.y) || isNaN<f32>(this.z) || isNaN<f32>(this.w); }

    readonly length(): f32 { return Mathf.sqrt(this.dot(this)); }
    readonly lengthSquared(): f32 { return this.dot(this); }
    readonly lengthRecip(): f32 { return <f32>1.0 / this.length(); }
    readonly distance(rhs: Vec4): f32 { return (this - rhs).length(); }
    readonly normalize(): Vec4 { return this * this.lengthRecip(); }
    readonly normalizeOr(fallback: Vec4): Vec4 {
        const rcp = this.lengthRecip();
        if (isFinite<f32>(rcp) && rcp > <f32>0.0) return this * rcp;
        return fallback;
    }
    readonly normalizeOrZero(): Vec4 { return this.normalizeOr(Vec4(0, 0, 0, 0)); }
    readonly isNormalized(): bool { return Mathf.abs(this.lengthSquared() - <f32>1.0) <= <f32>2e-4; }
    readonly lerp(rhs: Vec4, s: f32): Vec4 { return this * (<f32>1.0 - s) + rhs * s; }
    readonly absDiffEq(rhs: Vec4, maxAbsDiff: f32): bool {
        const d = (this - rhs).abs();
        return d.x <= maxAbsDiff && d.y <= maxAbsDiff && d.z <= maxAbsDiff && d.w <= maxAbsDiff;
    }
}

export const VEC4_ZERO: Vec4 = Vec4(0, 0, 0, 0);
export const VEC4_ONE: Vec4 = Vec4(1, 1, 1, 1);
export const VEC4_X: Vec4 = Vec4(1, 0, 0, 0);
export const VEC4_Y: Vec4 = Vec4(0, 1, 0, 0);
export const VEC4_Z: Vec4 = Vec4(0, 0, 1, 0);
export const VEC4_W: Vec4 = Vec4(0, 0, 0, 1);
export const VEC4_NEG_X: Vec4 = Vec4(-1, 0, 0, 0);
export const VEC4_NEG_Y: Vec4 = Vec4(0, -1, 0, 0);
export const VEC4_NEG_Z: Vec4 = Vec4(0, 0, -1, 0);
export const VEC4_NEG_W: Vec4 = Vec4(0, 0, 0, -1);
export const VEC4_NAN: Vec4 = Vec4(NaN, NaN, NaN, NaN);
export namespace Vec4 {
    export function splat(v: f32): Vec4 { return Vec4(v, v, v, v); }
    export function fromArray(a: Array<f32>, offset: i32 = 0): Vec4 {
        return Vec4(a[offset], a[offset + 1], a[offset + 2], a[offset + 3]);
    }
    export function fromF32Array(a: Float32Array, offset: i32 = 0): Vec4 {
        return Vec4(a[offset], a[offset + 1], a[offset + 2], a[offset + 3]);
    }
}

export function vec4(x: f32, y: f32, z: f32, w: f32): Vec4 { return Vec4(x, y, z, w); }

// ---------------------------------------------------------------------------
// IVec3 (i32; remesh voxel coordinates and Map keys)

export struct IVec3 {
    x: i32 = 0;
    y: i32 = 0;
    z: i32 = 0;

    constructor(x: i32, y: i32, z: i32) {
        this.x = x;
        this.y = y;
        this.z = z;
    }

    operator+(a: IVec3, b: IVec3): IVec3 { return IVec3(a.x + b.x, a.y + b.y, a.z + b.z); }
    operator-(a: IVec3, b: IVec3): IVec3 { return IVec3(a.x - b.x, a.y - b.y, a.z - b.z); }
    operator*(a: IVec3, s: i32): IVec3 { return IVec3(a.x * s, a.y * s, a.z * s); }
    operator-(a: IVec3): IVec3 { return IVec3(-a.x, -a.y, -a.z); }
    operator==(a: IVec3, b: IVec3): bool { return a.x == b.x && a.y == b.y && a.z == b.z; }
    readonly hash(): u32 { return <u32>this.x * 73856093 ^ <u32>this.y * 19349663 ^ <u32>this.z * 83492791; }
    readonly toString(): string { return `[${this.x}, ${this.y}, ${this.z}]`; }
    readonly debug(): string { return `IVec3(${this.x}, ${this.y}, ${this.z})`; }

    readonly min(rhs: IVec3): IVec3 { return IVec3(min(this.x, rhs.x), min(this.y, rhs.y), min(this.z, rhs.z)); }
    readonly max(rhs: IVec3): IVec3 { return IVec3(max(this.x, rhs.x), max(this.y, rhs.y), max(this.z, rhs.z)); }
    readonly asVec3(): Vec3 { return Vec3(<f32>this.x, <f32>this.y, <f32>this.z); }
}

export const IVEC3_ZERO: IVec3 = IVec3(0, 0, 0);
export const IVEC3_ONE: IVec3 = IVec3(1, 1, 1);
export namespace IVec3 {
    export function splat(v: i32): IVec3 { return IVec3(v, v, v); }
}

// ---------------------------------------------------------------------------
// DVec3 (f64, the subset the skin weights solver uses)

export struct DVec3 {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;

    constructor(x: f64, y: f64, z: f64) {
        this.x = x;
        this.y = y;
        this.z = z;
    }

    operator+(a: DVec3, b: DVec3): DVec3 { return DVec3(a.x + b.x, a.y + b.y, a.z + b.z); }
    operator-(a: DVec3, b: DVec3): DVec3 { return DVec3(a.x - b.x, a.y - b.y, a.z - b.z); }
    operator*(a: DVec3, s: f64): DVec3 { return DVec3(a.x * s, a.y * s, a.z * s); }
    operator/(a: DVec3, s: f64): DVec3 { return DVec3(a.x / s, a.y / s, a.z / s); }
    operator-(a: DVec3): DVec3 { return DVec3(-a.x, -a.y, -a.z); }
    operator==(a: DVec3, b: DVec3): bool { return a.x == b.x && a.y == b.y && a.z == b.z; }
    readonly hash(): u32 {
        return <u32>(reinterpret<u64>(this.x) ^ reinterpret<u64>(this.y) * 31 ^ reinterpret<u64>(this.z) * 131);
    }
    readonly toString(): string { return this.display(-1); }
    readonly display(prec: i32 = -1): string {
        const xs: Array<f64> = [this.x, this.y, this.z];
        const parts: Array<string> = [];
        for (let i = 0; i < 3; i++) parts.push(prec < 0 ? displayF64(xs[i]) : fixedF64(xs[i], prec));
        return "[" + parts.join(", ") + "]";
    }
    readonly debug(): string { return debugTuple("DVec3", [debugF64(this.x), debugF64(this.y), debugF64(this.z)]); }

    readonly dot(rhs: DVec3): f64 { return (this.x * rhs.x) + (this.y * rhs.y) + (this.z * rhs.z); }
    readonly cross(rhs: DVec3): DVec3 {
        return DVec3(
            this.y * rhs.z - rhs.y * this.z,
            this.z * rhs.x - rhs.z * this.x,
            this.x * rhs.y - rhs.x * this.y,
        );
    }
    readonly length(): f64 { return Math.sqrt(this.dot(this)); }
    readonly lengthSquared(): f64 { return this.dot(this); }
    readonly normalize(): DVec3 { return this * (1.0 / this.length()); }
    readonly asVec3(): Vec3 { return Vec3(<f32>this.x, <f32>this.y, <f32>this.z); }
}

export const DVEC3_ZERO: DVec3 = DVec3(0, 0, 0);
export namespace DVec3 {
    export function splat(v: f64): DVec3 { return DVec3(v, v, v); }
}

// ---------------------------------------------------------------------------
// EulerRot (Ken Shoemake's conversions).

export enum EulerRot {
    ZYX, ZXY, YXZ, YZX, XYZ, XZY, ZYZ, ZXZ, YXY, YZY, XYX, XZX,
    ZYXEx, ZXYEx, YXZEx, YZXEx, XYZEx, XZYEx, ZYZEx, ZXZEx, YXYEx, YZYEx, XYXEx, XZXEx,
}

class EulerOrder {
    initialAxis: i32 = 0;
    parityEven: bool = false;
    initialRepeated: bool = false;
    frameStatic: bool = false;
    i: i32 = 0;
    j: i32 = 0;
    k: i32 = 0;
}

function eulerOrder(euler: EulerRot): EulerOrder {
    // (initial axis, parity even, repeated, frame static) per order.
    let axis = 0;
    let even = false;
    let rep = false;
    let stat = true;
    switch (euler) {
        case EulerRot.XYZ: { axis = 0; even = true; rep = false; break; }
        case EulerRot.XYX: { axis = 0; even = true; rep = true; break; }
        case EulerRot.XZY: { axis = 0; even = false; rep = false; break; }
        case EulerRot.XZX: { axis = 0; even = false; rep = true; break; }
        case EulerRot.YZX: { axis = 1; even = true; rep = false; break; }
        case EulerRot.YZY: { axis = 1; even = true; rep = true; break; }
        case EulerRot.YXZ: { axis = 1; even = false; rep = false; break; }
        case EulerRot.YXY: { axis = 1; even = false; rep = true; break; }
        case EulerRot.ZXY: { axis = 2; even = true; rep = false; break; }
        case EulerRot.ZXZ: { axis = 2; even = true; rep = true; break; }
        case EulerRot.ZYX: { axis = 2; even = false; rep = false; break; }
        case EulerRot.ZYZ: { axis = 2; even = false; rep = true; break; }
        case EulerRot.ZYXEx: { axis = 0; even = true; rep = false; stat = false; break; }
        case EulerRot.XYXEx: { axis = 0; even = true; rep = true; stat = false; break; }
        case EulerRot.YZXEx: { axis = 0; even = false; rep = false; stat = false; break; }
        case EulerRot.XZXEx: { axis = 0; even = false; rep = true; stat = false; break; }
        case EulerRot.XZYEx: { axis = 1; even = true; rep = false; stat = false; break; }
        case EulerRot.YZYEx: { axis = 1; even = true; rep = true; stat = false; break; }
        case EulerRot.ZXYEx: { axis = 1; even = false; rep = false; stat = false; break; }
        case EulerRot.YXYEx: { axis = 1; even = false; rep = true; stat = false; break; }
        case EulerRot.YXZEx: { axis = 2; even = true; rep = false; stat = false; break; }
        case EulerRot.ZXZEx: { axis = 2; even = true; rep = true; stat = false; break; }
        case EulerRot.XYZEx: { axis = 2; even = false; rep = false; stat = false; break; }
        default: { axis = 2; even = false; rep = true; stat = false; break; } // ZYZEx
    }
    const o = new EulerOrder();
    o.initialAxis = axis;
    o.parityEven = even;
    o.initialRepeated = rep;
    o.frameStatic = stat;
    const next = (axis + 1) % 3;
    const prev = axis > 0 ? axis - 1 : 2;
    o.i = axis;
    o.j = even ? next : prev;
    o.k = even ? prev : next;
    return o;
}

// m[col][row] storage used by the Euler conversions.
function mat3Get(m: Mat3, col: i32, row: i32): f32 {
    return m.col(col).get(row);
}

export function mat3FromEulerAngles(euler: EulerRot, x: f32, y: f32, z: f32): Mat3 {
    const order = eulerOrder(euler);
    const i = order.i;
    const j = order.j;
    const k = order.k;
    let angles = order.frameStatic ? Vec3(x, y, z) : Vec3(z, y, x);
    if (order.parityEven) angles = -angles;
    const scI = appleSincosf(angles.x);
    const scJ = appleSincosf(angles.y);
    const scH = appleSincosf(angles.z);
    const si = scI.s;
    const ci = scI.c;
    const sj = scJ.s;
    const cj = scJ.c;
    const sh = scH.s;
    const ch = scH.c;
    const cc = ci * ch;
    const cs = ci * sh;
    const sc = si * ch;
    const ss = si * sh;
    const m = new StaticArray<f32>(9); // m[col * 3 + row]
    if (order.initialRepeated) {
        m[i * 3 + i] = cj;
        m[i * 3 + j] = sj * si;
        m[i * 3 + k] = sj * ci;
        m[j * 3 + i] = sj * sh;
        m[j * 3 + j] = -cj * ss + cc;
        m[j * 3 + k] = -cj * cs - sc;
        m[k * 3 + i] = -sj * ch;
        m[k * 3 + j] = cj * sc + cs;
        m[k * 3 + k] = cj * cc - ss;
    } else {
        m[i * 3 + i] = cj * ch;
        m[i * 3 + j] = sj * sc - cs;
        m[i * 3 + k] = sj * cc + ss;
        m[j * 3 + i] = cj * sh;
        m[j * 3 + j] = sj * ss + cc;
        m[j * 3 + k] = sj * cs - sc;
        m[k * 3 + i] = -sj;
        m[k * 3 + j] = cj * si;
        m[k * 3 + k] = cj * ci;
    }
    return Mat3(Vec3(m[0], m[1], m[2]), Vec3(m[3], m[4], m[5]), Vec3(m[6], m[7], m[8]));
}

export function mat3ToEulerAngles(self: Mat3, euler: EulerRot): Vec3 {
    const order = eulerOrder(euler);
    const i = order.i;
    const j = order.j;
    const k = order.k;
    let ea = Vec3(0, 0, 0);
    if (order.initialRepeated) {
        const sy = Mathf.sqrt(mat3Get(self, i, j) * mat3Get(self, i, j) + mat3Get(self, i, k) * mat3Get(self, i, k));
        if (sy > <f32>16.0 * f32.EPSILON) {
            ea.x = atan2f(mat3Get(self, i, j), mat3Get(self, i, k));
            ea.y = atan2f(sy, mat3Get(self, i, i));
            ea.z = atan2f(mat3Get(self, j, i), -mat3Get(self, k, i));
        } else {
            ea.x = atan2f(-mat3Get(self, j, k), mat3Get(self, j, j));
            ea.y = atan2f(sy, mat3Get(self, i, i));
        }
    } else {
        const cy = Mathf.sqrt(mat3Get(self, i, i) * mat3Get(self, i, i) + mat3Get(self, j, i) * mat3Get(self, j, i));
        if (cy > <f32>16.0 * f32.EPSILON) {
            ea.x = atan2f(mat3Get(self, k, j), mat3Get(self, k, k));
            ea.y = atan2f(-mat3Get(self, k, i), cy);
            ea.z = atan2f(mat3Get(self, j, i), mat3Get(self, i, i));
        } else {
            ea.x = atan2f(-mat3Get(self, j, k), mat3Get(self, j, j));
            ea.y = atan2f(-mat3Get(self, k, i), cy);
        }
    }
    if (order.parityEven) ea = -ea;
    if (!order.frameStatic) ea = Vec3(ea.z, ea.y, ea.x);
    return ea;
}

export function quatFromEulerAngles(euler: EulerRot, x: f32, y: f32, z: f32): Quat {
    const order = eulerOrder(euler);
    const i = order.i;
    const j = order.j;
    const k = order.k;
    let angles = order.frameStatic ? Vec3(x, y, z) : Vec3(z, y, x);
    if (order.parityEven) angles.y = -angles.y;
    const ti = angles.x * <f32>0.5;
    const tj = angles.y * <f32>0.5;
    const th = angles.z * <f32>0.5;
    const scI = appleSincosf(ti);
    const scJ = appleSincosf(tj);
    const scH = appleSincosf(th);
    const si = scI.s;
    const ci = scI.c;
    const sj = scJ.s;
    const cj = scJ.c;
    const sh = scH.s;
    const ch = scH.c;
    const cc = ci * ch;
    const cs = ci * sh;
    const sc = si * ch;
    const ss = si * sh;
    const parity: f32 = !order.parityEven ? <f32>1.0 : <f32>-1.0;
    const a = new StaticArray<f32>(4);
    if (order.initialRepeated) {
        a[i] = cj * (cs + sc);
        a[j] = sj * (cc + ss) * parity;
        a[k] = sj * (cs - sc);
        a[3] = cj * (cc - ss);
    } else {
        a[i] = cj * sc - sj * cs;
        a[j] = (cj * ss + sj * cc) * parity;
        a[k] = cj * cs - sj * sc;
        a[3] = cj * cc + sj * ss;
    }
    return Quat(a[0], a[1], a[2], a[3]);
}

// ---------------------------------------------------------------------------
// Quat (4-lane evaluation order)

export struct Quat {
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;
    w: f32 = 1;

    constructor(x: f32, y: f32, z: f32, w: f32) {
        this.x = x;
        this.y = y;
        this.z = z;
        this.w = w;
    }

    // Quat * Quat (Hamilton product, 4-lane evaluation order).
    operator*(a: Quat, b: Quat): Quat { return a.mulQuat(b); }
    operator+(a: Quat, b: Quat): Quat { return Quat(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w); }
    operator-(a: Quat, b: Quat): Quat { return Quat(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w); }
    // self * -1.0
    operator-(a: Quat): Quat { return Quat(a.x * <f32>-1.0, a.y * <f32>-1.0, a.z * <f32>-1.0, a.w * <f32>-1.0); }
    operator==(a: Quat, b: Quat): bool { return a.x == b.x && a.y == b.y && a.z == b.z && a.w == b.w; }
    readonly hash(): u32 {
        return reinterpret<u32>(this.x + <f32>0.0) * 73856093 ^ reinterpret<u32>(this.y + <f32>0.0) * 19349663
            ^ reinterpret<u32>(this.z + <f32>0.0) * 83492791 ^ reinterpret<u32>(this.w + <f32>0.0) * 2654435761;
    }
    readonly toString(): string { return this.display(-1); }
    readonly display(prec: i32 = -1): string { return displayList([this.x, this.y, this.z, this.w], prec); }
    readonly debug(): string { return debugList32("Quat", [this.x, this.y, this.z, this.w]); }

    // Quat * f32 and Quat / f32 (not normalized).
    readonly mulScalar(s: f32): Quat { return Quat(this.x * s, this.y * s, this.z * s, this.w * s); }
    readonly divScalar(s: f32): Quat { return Quat(this.x / s, this.y / s, this.z / s, this.w / s); }

    readonly toArray(): Array<f32> { return [this.x, this.y, this.z, this.w]; }
    readonly xyz(): Vec3 { return Vec3(this.x, this.y, this.z); }
    readonly toVec4(): Vec4 { return Vec4(this.x, this.y, this.z, this.w); }

    readonly toAxisAngle(): AxisAngle {
        const v = Vec3(this.x, this.y, this.z);
        const length = v.length();
        if (length >= <f32>1.0e-8) {
            const angle = <f32>2.0 * atan2f(length, this.w);
            return AxisAngle(v / length, angle);
        }
        return AxisAngle(Vec3(1, 0, 0), 0);
    }
    readonly toScaledAxis(): Vec3 {
        const aa = this.toAxisAngle();
        return aa.axis * aa.angle;
    }
    // The three angles of `order`, as Vec3(a, b, c).
    readonly toEuler(order: EulerRot): Vec3 { return mat3ToEulerAngles(Mat3.fromQuat(this), order); }

    readonly conjugate(): Quat { return Quat(this.x * <f32>-1.0, this.y * <f32>-1.0, this.z * <f32>-1.0, this.w * <f32>1.0); }
    readonly inverse(): Quat { return this.conjugate(); }
    readonly dot(rhs: Quat): f32 { return dot4Pairwise(this.x, this.y, this.z, this.w, rhs.x, rhs.y, rhs.z, rhs.w); }
    readonly length(): f32 { return Mathf.sqrt(this.dot(this)); }
    readonly lengthSquared(): f32 { return this.dot(this); }
    readonly lengthRecip(): f32 { return <f32>1.0 / this.length(); }
    readonly normalize(): Quat { return this.mulScalar(this.lengthRecip()); }
    readonly isFinite(): bool {
        return isFinite<f32>(this.x) && isFinite<f32>(this.y) && isFinite<f32>(this.z) && isFinite<f32>(this.w);
    }
    readonly isNan(): bool { return isNaN<f32>(this.x) || isNaN<f32>(this.y) || isNaN<f32>(this.z) || isNaN<f32>(this.w); }
    readonly isNormalized(): bool { return Mathf.abs(this.lengthSquared() - <f32>1.0) <= <f32>2e-4; }
    readonly isNearIdentity(): bool { return Mathf.abs(this.w) > <f32>1.0 - <f32>1e-6; }
    readonly angleBetween(rhs: Quat): f32 { return acosApprox(Mathf.abs(this.dot(rhs))) * <f32>2.0; }
    readonly absDiffEq(rhs: Quat, maxAbsDiff: f32): bool {
        return Mathf.abs(this.x - rhs.x) <= maxAbsDiff && Mathf.abs(this.y - rhs.y) <= maxAbsDiff
            && Mathf.abs(this.z - rhs.z) <= maxAbsDiff && Mathf.abs(this.w - rhs.w) <= maxAbsDiff;
    }

    private readonly lerpImpl(end: Quat, s: f32): Quat {
        return (this.mulScalar(<f32>1.0 - s) + end.mulScalar(s)).normalize();
    }
    readonly lerp(end: Quat, s: f32): Quat {
        // Flip `end` by the sign bit of the dot (also for -0.0).
        const dot = this.dot(end);
        const bias = reinterpret<u32>(dot) & 0x80000000;
        const e = Quat(
            reinterpret<f32>(reinterpret<u32>(end.x) ^ bias),
            reinterpret<f32>(reinterpret<u32>(end.y) ^ bias),
            reinterpret<f32>(reinterpret<u32>(end.z) ^ bias),
            reinterpret<f32>(reinterpret<u32>(end.w) ^ bias),
        );
        return this.lerpImpl(e, s);
    }
    private readonly slerpImpl(end: Quat, dot: f32, s: f32): Quat {
        const theta = acosApprox(dot);
        const scale1 = f32x4Sin(theta * (<f32>1.0 - s));
        const scale2 = f32x4Sin(theta * s);
        const thetaSin = f32x4Sin(theta * <f32>1.0);
        return Quat(
            (this.x * scale1 + end.x * scale2) / thetaSin,
            (this.y * scale1 + end.y * scale2) / thetaSin,
            (this.z * scale1 + end.z * scale2) / thetaSin,
            (this.w * scale1 + end.w * scale2) / thetaSin,
        );
    }
    readonly slerp(end: Quat, s: f32): Quat {
        let e = end;
        let dot = this.dot(e);
        if (dot < <f32>0.0) {
            e = -e;
            dot = -dot;
        }
        if (dot > <f32>1.0 - f32.EPSILON) return this.lerpImpl(e, s);
        return this.slerpImpl(e, dot, s);
    }
    readonly slerpLong(end: Quat, s: f32): Quat {
        const dot = this.dot(end);
        if (Mathf.abs(dot) > <f32>1.0 - f32.EPSILON) return this.lerpImpl(end, s);
        return this.slerpImpl(end, dot, s);
    }
    readonly rotateTowards(rhs: Quat, maxAngle: f32): Quat {
        const angle = this.angleBetween(rhs);
        if (angle <= <f32>1e-4) return rhs;
        const s = clampF32(maxAngle / angle, -1.0, 1.0);
        return this.slerp(rhs, s);
    }

    // Rotates a vector (4-lane evaluation order).
    readonly mulVec3(rhs: Vec3): Vec3 {
        const w = this.w;
        const bx = this.x;
        const by = this.y;
        const bz = this.z;
        const b2 = dot3A(bx, by, bz, bx, by, bz);
        const d = dot3A(rhs.x, rhs.y, rhs.z, bx, by, bz);
        const k1 = (w * w) - b2;
        const k2 = d * <f32>2.0;
        const k3 = w * <f32>2.0;
        // b.cross(rhs)
        const cx = by * rhs.z - bz * rhs.y;
        const cy = bz * rhs.x - bx * rhs.z;
        const cz = bx * rhs.y - by * rhs.x;
        return Vec3(
            (rhs.x * k1 + bx * k2) + cx * k3,
            (rhs.y * k1 + by * k2) + cy * k3,
            (rhs.z * k1 + bz * k2) + cz * k3,
        );
    }

    // Hamilton product in 4-lane evaluation order.
    readonly mulQuat(rhs: Quat): Quat {
        const ax = this.x;
        const ay = this.y;
        const az = this.z;
        const aw = this.w;
        const bx = rhs.x;
        const by = rhs.y;
        const bz = rhs.z;
        const bw = rhs.w;
        // result0 = aw*b + ax*(bw, -bz, by, -bx); result1 = ay*(bz, bw, -bx, -by) + az*(-by, bx, bw, -bz)
        const r0x = aw * bx + ax * bw;
        const r0y = aw * by + -(ax * bz);
        const r0z = aw * bz + ax * by;
        const r0w = aw * bw + -(ax * bx);
        const r1x = ay * bz + -(az * by);
        const r1y = ay * bw + az * bx;
        const r1z = -(ay * bx) + az * bw;
        const r1w = -(ay * by) + -(az * bz);
        return Quat(r0x + r1x, r0y + r1y, r0z + r1z, r0w + r1w);
    }
}

export const QUAT_IDENTITY: Quat = Quat(0, 0, 0, 1);
export const QUAT_NAN: Quat = Quat(NaN, NaN, NaN, NaN);
export namespace Quat {
    export function fromXyzw(x: f32, y: f32, z: f32, w: f32): Quat { return Quat(x, y, z, w); }
    export function fromArray(a: Array<f32>, offset: i32 = 0): Quat {
        return Quat(a[offset], a[offset + 1], a[offset + 2], a[offset + 3]);
    }
    export function fromF32Array(a: Float32Array, offset: i32 = 0): Quat {
        return Quat(a[offset], a[offset + 1], a[offset + 2], a[offset + 3]);
    }
    export function fromVec4(v: Vec4): Quat { return Quat(v.x, v.y, v.z, v.w); }
    export function fromAxisAngle(axis: Vec3, angle: f32): Quat {
        const sc = appleSincosf(angle * <f32>0.5);
        const v = axis * sc.s;
        return Quat(v.x, v.y, v.z, sc.c);
    }
    export function fromScaledAxis(v: Vec3): Quat {
        const length = v.length();
        if (length == <f32>0.0) return Quat(0, 0, 0, 1);
        return fromAxisAngle(v / length, length);
    }
    export function fromRotationX(angle: f32): Quat {
        const sc = appleSincosf(angle * <f32>0.5);
        return Quat(sc.s, 0, 0, sc.c);
    }
    export function fromRotationY(angle: f32): Quat {
        const sc = appleSincosf(angle * <f32>0.5);
        return Quat(0, sc.s, 0, sc.c);
    }
    export function fromRotationZ(angle: f32): Quat {
        const sc = appleSincosf(angle * <f32>0.5);
        return Quat(0, 0, sc.s, sc.c);
    }
    export function fromEuler(order: EulerRot, a: f32, b: f32, c: f32): Quat {
        return quatFromEulerAngles(order, a, b, c);
    }
    // DirectXMath XMQuaternionRotationMatrix.
    export function fromRotationAxes(xAxis: Vec3, yAxis: Vec3, zAxis: Vec3): Quat {
        const m00 = xAxis.x;
        const m01 = xAxis.y;
        const m02 = xAxis.z;
        const m10 = yAxis.x;
        const m11 = yAxis.y;
        const m12 = yAxis.z;
        const m20 = zAxis.x;
        const m21 = zAxis.y;
        const m22 = zAxis.z;
        if (m22 <= <f32>0.0) {
            const dif10 = m11 - m00;
            const omm22 = <f32>1.0 - m22;
            if (dif10 <= <f32>0.0) {
                const fourXsq = omm22 - dif10;
                const inv4x = <f32>0.5 / Mathf.sqrt(fourXsq);
                return Quat(fourXsq * inv4x, (m01 + m10) * inv4x, (m02 + m20) * inv4x, (m12 - m21) * inv4x);
            }
            const fourYsq = omm22 + dif10;
            const inv4y = <f32>0.5 / Mathf.sqrt(fourYsq);
            return Quat((m01 + m10) * inv4y, fourYsq * inv4y, (m12 + m21) * inv4y, (m20 - m02) * inv4y);
        }
        const sum10 = m11 + m00;
        const opm22 = <f32>1.0 + m22;
        if (sum10 <= <f32>0.0) {
            const fourZsq = opm22 - sum10;
            const inv4z = <f32>0.5 / Mathf.sqrt(fourZsq);
            return Quat((m02 + m20) * inv4z, (m12 + m21) * inv4z, fourZsq * inv4z, (m01 - m10) * inv4z);
        }
        const fourWsq = opm22 + sum10;
        const inv4w = <f32>0.5 / Mathf.sqrt(fourWsq);
        return Quat((m12 - m21) * inv4w, (m20 - m02) * inv4w, (m01 - m10) * inv4w, fourWsq * inv4w);
    }
    export function fromMat3(m: Mat3): Quat { return fromRotationAxes(m.xAxis, m.yAxis, m.zAxis); }
    export function fromMat4(m: Mat4): Quat {
        return fromRotationAxes(m.xAxis.truncate(), m.yAxis.truncate(), m.zAxis.truncate());
    }
    export function fromRotationArc(from: Vec3, to: Vec3): Quat {
        const ONE_MINUS_EPS: f32 = <f32>1.0 - <f32>2.0 * f32.EPSILON;
        const dot = from.dot(to);
        if (dot > ONE_MINUS_EPS) return Quat(0, 0, 0, 1);
        if (dot < -ONE_MINUS_EPS) return fromAxisAngle(from.anyOrthonormalVector(), F32_PI);
        const c = from.cross(to);
        return Quat(c.x, c.y, c.z, <f32>1.0 + dot).normalize();
    }
    export function fromRotationArcColinear(from: Vec3, to: Vec3): Quat {
        if (from.dot(to) < <f32>0.0) return fromRotationArc(from, -to);
        return fromRotationArc(from, to);
    }
}

export function quat(x: f32, y: f32, z: f32, w: f32): Quat { return Quat(x, y, z, w); }

// What Quat.toAxisAngle returns.
export struct AxisAngle {
    axis: Vec3 = Vec3(1, 0, 0);
    angle: f32 = 0;
    constructor(axis: Vec3, angle: f32) {
        this.axis = axis;
        this.angle = angle;
    }
}

// ---------------------------------------------------------------------------
// Mat3 (scalar arithmetic; column-major, xAxis is column 0)

export struct Mat3 {
    xAxis: Vec3 = Vec3(1, 0, 0);
    yAxis: Vec3 = Vec3(0, 1, 0);
    zAxis: Vec3 = Vec3(0, 0, 1);

    constructor(xAxis: Vec3, yAxis: Vec3, zAxis: Vec3) {
        this.xAxis = xAxis;
        this.yAxis = yAxis;
        this.zAxis = zAxis;
    }

    operator*(a: Mat3, b: Mat3): Mat3 { return Mat3(a.mulVec3(b.xAxis), a.mulVec3(b.yAxis), a.mulVec3(b.zAxis)); }
    operator+(a: Mat3, b: Mat3): Mat3 { return Mat3(a.xAxis + b.xAxis, a.yAxis + b.yAxis, a.zAxis + b.zAxis); }
    operator-(a: Mat3, b: Mat3): Mat3 { return Mat3(a.xAxis - b.xAxis, a.yAxis - b.yAxis, a.zAxis - b.zAxis); }
    operator-(a: Mat3): Mat3 { return Mat3(-a.xAxis, -a.yAxis, -a.zAxis); }
    operator==(a: Mat3, b: Mat3): bool { return a.xAxis == b.xAxis && a.yAxis == b.yAxis && a.zAxis == b.zAxis; }
    readonly hash(): u32 { return this.xAxis.hash() * 31 ^ this.yAxis.hash() * 17 ^ this.zAxis.hash(); }
    readonly toString(): string { return this.display(-1); }
    readonly display(prec: i32 = -1): string {
        return "[" + this.xAxis.display(prec) + ", " + this.yAxis.display(prec) + ", " + this.zAxis.display(prec) + "]";
    }
    readonly debug(): string {
        return debugStruct("Mat3", ["x_axis", "y_axis", "z_axis"], [this.xAxis.debug(), this.yAxis.debug(), this.zAxis.debug()]);
    }

    readonly col(index: i32): Vec3 {
        if (index == 0) return this.xAxis;
        if (index == 1) return this.yAxis;
        if (index == 2) return this.zAxis;
        panic("index out of bounds");
        return this.xAxis;
    }
    readonly row(index: i32): Vec3 {
        if (index == 0) return Vec3(this.xAxis.x, this.yAxis.x, this.zAxis.x);
        if (index == 1) return Vec3(this.xAxis.y, this.yAxis.y, this.zAxis.y);
        if (index == 2) return Vec3(this.xAxis.z, this.yAxis.z, this.zAxis.z);
        panic("index out of bounds");
        return this.xAxis;
    }
    readonly toColsArray(): Array<f32> {
        return [
            this.xAxis.x, this.xAxis.y, this.xAxis.z,
            this.yAxis.x, this.yAxis.y, this.yAxis.z,
            this.zAxis.x, this.zAxis.y, this.zAxis.z,
        ];
    }
    readonly toColsArray2d(): Array<Array<f32>> {
        return [this.xAxis.toArray(), this.yAxis.toArray(), this.zAxis.toArray()];
    }
    readonly diagonal(): Vec3 { return Vec3(this.xAxis.x, this.yAxis.y, this.zAxis.z); }
    readonly isFinite(): bool { return this.xAxis.isFinite() && this.yAxis.isFinite() && this.zAxis.isFinite(); }
    readonly isNan(): bool { return this.xAxis.isNan() || this.yAxis.isNan() || this.zAxis.isNan(); }
    readonly transpose(): Mat3 {
        return Mat3(
            Vec3(this.xAxis.x, this.yAxis.x, this.zAxis.x),
            Vec3(this.xAxis.y, this.yAxis.y, this.zAxis.y),
            Vec3(this.xAxis.z, this.yAxis.z, this.zAxis.z),
        );
    }
    readonly determinant(): f32 { return this.zAxis.dot(this.xAxis.cross(this.yAxis)); }
    readonly inverse(): Mat3 {
        const tmp0 = this.yAxis.cross(this.zAxis);
        const tmp1 = this.zAxis.cross(this.xAxis);
        const tmp2 = this.xAxis.cross(this.yAxis);
        const det = this.zAxis.dot(tmp2);
        const invDet = <f32>1.0 / det;
        return Mat3(tmp0 * invDet, tmp1 * invDet, tmp2 * invDet).transpose();
    }
    // ZERO when determinant() == 0, else inverse().
    readonly inverseOrZero(): Mat3 {
        const det = this.zAxis.dot(this.xAxis.cross(this.yAxis));
        if (det == <f32>0.0) return Mat3(Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0));
        return this.inverse();
    }
    readonly mulVec3(rhs: Vec3): Vec3 {
        let res = this.xAxis * rhs.x;
        res = res + this.yAxis * rhs.y;
        res = res + this.zAxis * rhs.z;
        return res;
    }
    readonly mulTransposeVec3(rhs: Vec3): Vec3 {
        return Vec3(this.xAxis.dot(rhs), this.yAxis.dot(rhs), this.zAxis.dot(rhs));
    }
    readonly mulMat3(rhs: Mat3): Mat3 { return this * rhs; }
    readonly mulScalar(s: f32): Mat3 { return Mat3(this.xAxis * s, this.yAxis * s, this.zAxis * s); }
    readonly divScalar(s: f32): Mat3 { return Mat3(this.xAxis / s, this.yAxis / s, this.zAxis / s); }
    readonly abs(): Mat3 { return Mat3(this.xAxis.abs(), this.yAxis.abs(), this.zAxis.abs()); }
    readonly absDiffEq(rhs: Mat3, maxAbsDiff: f32): bool {
        return this.xAxis.absDiffEq(rhs.xAxis, maxAbsDiff) && this.yAxis.absDiffEq(rhs.yAxis, maxAbsDiff)
            && this.zAxis.absDiffEq(rhs.zAxis, maxAbsDiff);
    }
    // The three angles of `order`, as Vec3(a, b, c).
    readonly toEuler(order: EulerRot): Vec3 { return mat3ToEulerAngles(this, order); }
}

export const MAT3_ZERO: Mat3 = Mat3(Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0));
export const MAT3_IDENTITY: Mat3 = Mat3(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));
export const MAT3_NAN: Mat3 = Mat3(Vec3(NaN, NaN, NaN), Vec3(NaN, NaN, NaN), Vec3(NaN, NaN, NaN));
export namespace Mat3 {
    export function fromCols(xAxis: Vec3, yAxis: Vec3, zAxis: Vec3): Mat3 { return Mat3(xAxis, yAxis, zAxis); }
    export function fromColsArray(m: Array<f32>): Mat3 {
        return Mat3(Vec3(m[0], m[1], m[2]), Vec3(m[3], m[4], m[5]), Vec3(m[6], m[7], m[8]));
    }
    export function fromColsArray2d(m: Array<Array<f32>>): Mat3 {
        return Mat3(Vec3.fromArray(m[0]), Vec3.fromArray(m[1]), Vec3.fromArray(m[2]));
    }
    export function fromDiagonal(d: Vec3): Mat3 { return Mat3(Vec3(d.x, 0, 0), Vec3(0, d.y, 0), Vec3(0, 0, d.z)); }
    export function fromMat4(m: Mat4): Mat3 { return Mat3(m.xAxis.truncate(), m.yAxis.truncate(), m.zAxis.truncate()); }
    export function fromQuat(rotation: Quat): Mat3 {
        const x2 = rotation.x + rotation.x;
        const y2 = rotation.y + rotation.y;
        const z2 = rotation.z + rotation.z;
        const xx = rotation.x * x2;
        const xy = rotation.x * y2;
        const xz = rotation.x * z2;
        const yy = rotation.y * y2;
        const yz = rotation.y * z2;
        const zz = rotation.z * z2;
        const wx = rotation.w * x2;
        const wy = rotation.w * y2;
        const wz = rotation.w * z2;
        return Mat3(
            Vec3(<f32>1.0 - (yy + zz), xy + wz, xz - wy),
            Vec3(xy - wz, <f32>1.0 - (xx + zz), yz + wx),
            Vec3(xz + wy, yz - wx, <f32>1.0 - (xx + yy)),
        );
    }
    export function fromAxisAngle(axis: Vec3, angle: f32): Mat3 {
        const sc = appleSincosf(angle);
        const sin = sc.s;
        const cos = sc.c;
        const s = axis * sin;
        const sq = axis.mul(axis);
        const omc = <f32>1.0 - cos;
        const xyomc = axis.x * axis.y * omc;
        const xzomc = axis.x * axis.z * omc;
        const yzomc = axis.y * axis.z * omc;
        return Mat3(
            Vec3(sq.x * omc + cos, xyomc + s.z, xzomc - s.y),
            Vec3(xyomc - s.z, sq.y * omc + cos, yzomc + s.x),
            Vec3(xzomc + s.y, yzomc - s.x, sq.z * omc + cos),
        );
    }
    export function fromEuler(order: EulerRot, a: f32, b: f32, c: f32): Mat3 {
        return mat3FromEulerAngles(order, a, b, c);
    }
    export function fromRotationX(angle: f32): Mat3 {
        const sc = appleSincosf(angle);
        const sina = sc.s;
        const cosa = sc.c;
        return Mat3(Vec3(1, 0, 0), Vec3(0, cosa, sina), Vec3(0, -sina, cosa));
    }
    export function fromRotationY(angle: f32): Mat3 {
        const sc = appleSincosf(angle);
        const sina = sc.s;
        const cosa = sc.c;
        return Mat3(Vec3(cosa, 0, -sina), Vec3(0, 1, 0), Vec3(sina, 0, cosa));
    }
    export function fromRotationZ(angle: f32): Mat3 {
        const sc = appleSincosf(angle);
        const sina = sc.s;
        const cosa = sc.c;
        return Mat3(Vec3(cosa, sina, 0), Vec3(-sina, cosa, 0), Vec3(0, 0, 1));
    }
}

export function mat3(xAxis: Vec3, yAxis: Vec3, zAxis: Vec3): Mat3 { return Mat3(xAxis, yAxis, zAxis); }

// ---------------------------------------------------------------------------
// Mat4 (4-lane evaluation order; column-major, xAxis is column 0)

export struct Mat4 {
    xAxis: Vec4 = Vec4(1, 0, 0, 0);
    yAxis: Vec4 = Vec4(0, 1, 0, 0);
    zAxis: Vec4 = Vec4(0, 0, 1, 0);
    wAxis: Vec4 = Vec4(0, 0, 0, 1);

    constructor(xAxis: Vec4, yAxis: Vec4, zAxis: Vec4, wAxis: Vec4) {
        this.xAxis = xAxis;
        this.yAxis = yAxis;
        this.zAxis = zAxis;
        this.wAxis = wAxis;
    }

    operator*(a: Mat4, b: Mat4): Mat4 {
        return Mat4(a.mulVec4(b.xAxis), a.mulVec4(b.yAxis), a.mulVec4(b.zAxis), a.mulVec4(b.wAxis));
    }
    operator+(a: Mat4, b: Mat4): Mat4 {
        return Mat4(a.xAxis + b.xAxis, a.yAxis + b.yAxis, a.zAxis + b.zAxis, a.wAxis + b.wAxis);
    }
    operator-(a: Mat4, b: Mat4): Mat4 {
        return Mat4(a.xAxis - b.xAxis, a.yAxis - b.yAxis, a.zAxis - b.zAxis, a.wAxis - b.wAxis);
    }
    operator-(a: Mat4): Mat4 { return Mat4(-a.xAxis, -a.yAxis, -a.zAxis, -a.wAxis); }
    operator==(a: Mat4, b: Mat4): bool {
        return a.xAxis == b.xAxis && a.yAxis == b.yAxis && a.zAxis == b.zAxis && a.wAxis == b.wAxis;
    }
    readonly hash(): u32 {
        return this.xAxis.hash() * 31 ^ this.yAxis.hash() * 17 ^ this.zAxis.hash() * 7 ^ this.wAxis.hash();
    }
    readonly toString(): string { return this.display(-1); }
    readonly display(prec: i32 = -1): string {
        return "[" + this.xAxis.display(prec) + ", " + this.yAxis.display(prec) + ", " + this.zAxis.display(prec)
            + ", " + this.wAxis.display(prec) + "]";
    }
    readonly debug(): string {
        return debugStruct(
            "Mat4",
            ["x_axis", "y_axis", "z_axis", "w_axis"],
            [this.xAxis.debug(), this.yAxis.debug(), this.zAxis.debug(), this.wAxis.debug()],
        );
    }

    readonly col(index: i32): Vec4 {
        if (index == 0) return this.xAxis;
        if (index == 1) return this.yAxis;
        if (index == 2) return this.zAxis;
        if (index == 3) return this.wAxis;
        panic("index out of bounds");
        return this.xAxis;
    }
    readonly row(index: i32): Vec4 {
        if (index == 0) return Vec4(this.xAxis.x, this.yAxis.x, this.zAxis.x, this.wAxis.x);
        if (index == 1) return Vec4(this.xAxis.y, this.yAxis.y, this.zAxis.y, this.wAxis.y);
        if (index == 2) return Vec4(this.xAxis.z, this.yAxis.z, this.zAxis.z, this.wAxis.z);
        if (index == 3) return Vec4(this.xAxis.w, this.yAxis.w, this.zAxis.w, this.wAxis.w);
        panic("index out of bounds");
        return this.xAxis;
    }
    readonly toColsArray(): Array<f32> {
        return [
            this.xAxis.x, this.xAxis.y, this.xAxis.z, this.xAxis.w,
            this.yAxis.x, this.yAxis.y, this.yAxis.z, this.yAxis.w,
            this.zAxis.x, this.zAxis.y, this.zAxis.z, this.zAxis.w,
            this.wAxis.x, this.wAxis.y, this.wAxis.z, this.wAxis.w,
        ];
    }
    readonly toColsArray2d(): Array<Array<f32>> {
        return [this.xAxis.toArray(), this.yAxis.toArray(), this.zAxis.toArray(), this.wAxis.toArray()];
    }
    readonly writeColsToF32Array(a: Float32Array, offset: i32): void {
        const m = this.toColsArray();
        for (let i = 0; i < 16; i++) a[offset + i] = m[i];
    }
    readonly diagonal(): Vec4 { return Vec4(this.xAxis.x, this.yAxis.y, this.zAxis.z, this.wAxis.w); }
    readonly isFinite(): bool {
        return this.xAxis.isFinite() && this.yAxis.isFinite() && this.zAxis.isFinite() && this.wAxis.isFinite();
    }
    readonly isNan(): bool { return this.xAxis.isNan() || this.yAxis.isNan() || this.zAxis.isNan() || this.wAxis.isNan(); }
    readonly transpose(): Mat4 {
        return Mat4(
            Vec4(this.xAxis.x, this.yAxis.x, this.zAxis.x, this.wAxis.x),
            Vec4(this.xAxis.y, this.yAxis.y, this.zAxis.y, this.wAxis.y),
            Vec4(this.xAxis.z, this.yAxis.z, this.zAxis.z, this.wAxis.z),
            Vec4(this.xAxis.w, this.yAxis.w, this.zAxis.w, this.wAxis.w),
        );
    }
    readonly determinant(): f32 {
        const m00 = this.xAxis.x;
        const m01 = this.xAxis.y;
        const m02 = this.xAxis.z;
        const m03 = this.xAxis.w;
        const m10 = this.yAxis.x;
        const m11 = this.yAxis.y;
        const m12 = this.yAxis.z;
        const m13 = this.yAxis.w;
        const m20 = this.zAxis.x;
        const m21 = this.zAxis.y;
        const m22 = this.zAxis.z;
        const m23 = this.zAxis.w;
        const m30 = this.wAxis.x;
        const m31 = this.wAxis.y;
        const m32 = this.wAxis.z;
        const m33 = this.wAxis.w;
        const a2323 = m22 * m33 - m23 * m32;
        const a1323 = m21 * m33 - m23 * m31;
        const a1223 = m21 * m32 - m22 * m31;
        const a0323 = m20 * m33 - m23 * m30;
        const a0223 = m20 * m32 - m22 * m30;
        const a0123 = m20 * m31 - m21 * m30;
        return m00 * (m11 * a2323 - m12 * a1323 + m13 * a1223)
            - m01 * (m10 * a2323 - m12 * a0323 + m13 * a0223)
            + m02 * (m10 * a1323 - m11 * a0323 + m13 * a0123)
            - m03 * (m10 * a1223 - m11 * a0223 + m12 * a0123);
    }

    // GLM's inverse algorithm, written as scalar coefficient formulas; the
    // determinant is a pairwise dot4. Returns ZERO when the determinant is 0
    // only through inverseOrZero(); inverse() divides by it without checking.
    private readonly inverseChecked(checked: bool): Mat4 {
        const m00 = this.xAxis.x;
        const m01 = this.xAxis.y;
        const m02 = this.xAxis.z;
        const m03 = this.xAxis.w;
        const m10 = this.yAxis.x;
        const m11 = this.yAxis.y;
        const m12 = this.yAxis.z;
        const m13 = this.yAxis.w;
        const m20 = this.zAxis.x;
        const m21 = this.zAxis.y;
        const m22 = this.zAxis.z;
        const m23 = this.zAxis.w;
        const m30 = this.wAxis.x;
        const m31 = this.wAxis.y;
        const m32 = this.wAxis.z;
        const m33 = this.wAxis.w;

        const coef00 = m22 * m33 - m32 * m23;
        const coef02 = m12 * m33 - m32 * m13;
        const coef03 = m12 * m23 - m22 * m13;
        const coef04 = m21 * m33 - m31 * m23;
        const coef06 = m11 * m33 - m31 * m13;
        const coef07 = m11 * m23 - m21 * m13;
        const coef08 = m21 * m32 - m31 * m22;
        const coef10 = m11 * m32 - m31 * m12;
        const coef11 = m11 * m22 - m21 * m12;
        const coef12 = m20 * m33 - m30 * m23;
        const coef14 = m10 * m33 - m30 * m13;
        const coef15 = m10 * m23 - m20 * m13;
        const coef16 = m20 * m32 - m30 * m22;
        const coef18 = m10 * m32 - m30 * m12;
        const coef19 = m10 * m22 - m20 * m12;
        const coef20 = m20 * m31 - m30 * m21;
        const coef22 = m10 * m31 - m30 * m11;
        const coef23 = m10 * m21 - m20 * m11;

        const fac0 = Vec4(coef00, coef00, coef02, coef03);
        const fac1 = Vec4(coef04, coef04, coef06, coef07);
        const fac2 = Vec4(coef08, coef08, coef10, coef11);
        const fac3 = Vec4(coef12, coef12, coef14, coef15);
        const fac4 = Vec4(coef16, coef16, coef18, coef19);
        const fac5 = Vec4(coef20, coef20, coef22, coef23);

        const vec0 = Vec4(m10, m00, m00, m00);
        const vec1 = Vec4(m11, m01, m01, m01);
        const vec2 = Vec4(m12, m02, m02, m02);
        const vec3 = Vec4(m13, m03, m03, m03);

        const signA = Vec4(1, -1, 1, -1);
        const signB = Vec4(-1, 1, -1, 1);
        const inv0 = (vec1.mul(fac0) - vec2.mul(fac1) + vec3.mul(fac2)).mul(signA);
        const inv1 = (vec0.mul(fac0) - vec2.mul(fac3) + vec3.mul(fac4)).mul(signB);
        const inv2 = (vec0.mul(fac1) - vec1.mul(fac3) + vec3.mul(fac5)).mul(signA);
        const inv3 = (vec0.mul(fac2) - vec1.mul(fac4) + vec2.mul(fac5)).mul(signB);

        const dot0 = dot4Pairwise(m00, m01, m02, m03, inv0.x, inv1.x, inv2.x, inv3.x);
        if (checked && dot0 == <f32>0.0) {
            return Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));
        }
        const rcp0 = <f32>1.0 / dot0;
        return Mat4(inv0 * rcp0, inv1 * rcp0, inv2 * rcp0, inv3 * rcp0);
    }
    readonly inverse(): Mat4 { return this.inverseChecked(false); }
    // ZERO when the (pairwise) determinant is exactly 0, else inverse().
    readonly inverseOrZero(): Mat4 { return this.inverseChecked(true); }

    readonly mulVec4(rhs: Vec4): Vec4 {
        let res = this.xAxis * rhs.x;
        res = res + this.yAxis * rhs.y;
        res = res + this.zAxis * rhs.z;
        res = res + this.wAxis * rhs.w;
        return res;
    }
    readonly mulTransposeVec4(rhs: Vec4): Vec4 {
        return Vec4(this.xAxis.dot(rhs), this.yAxis.dot(rhs), this.zAxis.dot(rhs), this.wAxis.dot(rhs));
    }
    readonly mulMat4(rhs: Mat4): Mat4 { return this * rhs; }
    readonly mulScalar(s: f32): Mat4 { return Mat4(this.xAxis * s, this.yAxis * s, this.zAxis * s, this.wAxis * s); }
    readonly divScalar(s: f32): Mat4 { return Mat4(this.xAxis / s, this.yAxis / s, this.zAxis / s, this.wAxis / s); }
    readonly addMat4(rhs: Mat4): Mat4 { return this + rhs; }
    readonly subMat4(rhs: Mat4): Mat4 { return this - rhs; }
    readonly abs(): Mat4 { return Mat4(this.xAxis.abs(), this.yAxis.abs(), this.zAxis.abs(), this.wAxis.abs()); }
    readonly absDiffEq(rhs: Mat4, maxAbsDiff: f32): bool {
        return this.xAxis.absDiffEq(rhs.xAxis, maxAbsDiff) && this.yAxis.absDiffEq(rhs.yAxis, maxAbsDiff)
            && this.zAxis.absDiffEq(rhs.zAxis, maxAbsDiff) && this.wAxis.absDiffEq(rhs.wAxis, maxAbsDiff);
    }

    // res = x*p.x; res = y*p.y + res; res = z*p.z + res; res = w + res
    readonly transformPoint3(rhs: Vec3): Vec3 {
        let res = this.xAxis * rhs.x;
        res = this.yAxis * rhs.y + res;
        res = this.zAxis * rhs.z + res;
        res = this.wAxis + res;
        return res.truncate();
    }
    readonly transformVector3(rhs: Vec3): Vec3 {
        let res = this.xAxis * rhs.x;
        res = this.yAxis * rhs.y + res;
        res = this.zAxis * rhs.z + res;
        return res.truncate();
    }
    readonly projectPoint3(rhs: Vec3): Vec3 {
        let res = this.xAxis * rhs.x;
        res = this.yAxis * rhs.y + res;
        res = this.zAxis * rhs.z + res;
        res = this.wAxis + res;
        res = res / res.w;
        return res.truncate();
    }

    readonly toScaleRotationTranslation(): ScaleRotationTranslation {
        // The upper 3x3; the scalar 3-lane dot for the determinant and lengths.
        const rx = this.xAxis.truncate();
        const ry = this.yAxis.truncate();
        const rz = this.zAxis.truncate();
        const c = rx.cross(ry);
        const det = dot3A(rz.x, rz.y, rz.z, c.x, c.y, c.z);
        const scale = Vec3(
            Mathf.sqrt(dot3A(rx.x, rx.y, rx.z, rx.x, rx.y, rx.z)) * signumF32(det),
            Mathf.sqrt(dot3A(ry.x, ry.y, ry.z, ry.x, ry.y, ry.z)),
            Mathf.sqrt(dot3A(rz.x, rz.y, rz.z, rz.x, rz.y, rz.z)),
        );
        const invScale = scale.recip();
        const rotation = Quat.fromRotationAxes(rx * invScale.x, ry * invScale.y, rz * invScale.z);
        const translation = this.wAxis.truncate();
        return ScaleRotationTranslation(scale, rotation, translation);
    }
    // The three angles of `order`, as Vec3(a, b, c).
    readonly toEuler(order: EulerRot): Vec3 { return mat3ToEulerAngles(Mat3.fromMat4(this), order); }
}

export function quatToAxes(rotation: Quat): Mat3 {
    const x = rotation.x;
    const y = rotation.y;
    const z = rotation.z;
    const w = rotation.w;
    const x2 = x + x;
    const y2 = y + y;
    const z2 = z + z;
    const xx = x * x2;
    const xy = x * y2;
    const xz = x * z2;
    const yy = y * y2;
    const yz = y * z2;
    const zz = z * z2;
    const wx = w * x2;
    const wy = w * y2;
    const wz = w * z2;
    return Mat3(
        Vec3(<f32>1.0 - (yy + zz), xy + wz, xz - wy),
        Vec3(xy - wz, <f32>1.0 - (xx + zz), yz + wx),
        Vec3(xz + wy, yz - wx, <f32>1.0 - (xx + yy)),
    );
}

export const MAT4_ZERO: Mat4 = Mat4(Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0), Vec4(0, 0, 0, 0));
export const MAT4_IDENTITY: Mat4 = Mat4(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1));
export const MAT4_NAN: Mat4 = Mat4(Vec4(NaN, NaN, NaN, NaN), Vec4(NaN, NaN, NaN, NaN), Vec4(NaN, NaN, NaN, NaN), Vec4(NaN, NaN, NaN, NaN));
export namespace Mat4 {
    export function fromCols(xAxis: Vec4, yAxis: Vec4, zAxis: Vec4, wAxis: Vec4): Mat4 {
        return Mat4(xAxis, yAxis, zAxis, wAxis);
    }
    export function fromColsArray(m: Array<f32>): Mat4 {
        return Mat4(
            Vec4(m[0], m[1], m[2], m[3]),
            Vec4(m[4], m[5], m[6], m[7]),
            Vec4(m[8], m[9], m[10], m[11]),
            Vec4(m[12], m[13], m[14], m[15]),
        );
    }
    export function fromColsArray2d(m: Array<Array<f32>>): Mat4 {
        return Mat4(Vec4.fromArray(m[0]), Vec4.fromArray(m[1]), Vec4.fromArray(m[2]), Vec4.fromArray(m[3]));
    }
    export function fromF32Array(a: Float32Array, offset: i32 = 0): Mat4 {
        return Mat4(
            Vec4.fromF32Array(a, offset),
            Vec4.fromF32Array(a, offset + 4),
            Vec4.fromF32Array(a, offset + 8),
            Vec4.fromF32Array(a, offset + 12),
        );
    }
    export function fromDiagonal(d: Vec4): Mat4 {
        return Mat4(Vec4(d.x, 0, 0, 0), Vec4(0, d.y, 0, 0), Vec4(0, 0, d.z, 0), Vec4(0, 0, 0, d.w));
    }
    export function fromScaleRotationTranslation(scale: Vec3, rotation: Quat, translation: Vec3): Mat4 {
        const axes = quatToAxes(rotation);
        return Mat4(
            axes.xAxis.extend(0) * scale.x,
            axes.yAxis.extend(0) * scale.y,
            axes.zAxis.extend(0) * scale.z,
            translation.extend(1),
        );
    }
    export function fromRotationTranslation(rotation: Quat, translation: Vec3): Mat4 {
        const axes = quatToAxes(rotation);
        return Mat4(axes.xAxis.extend(0), axes.yAxis.extend(0), axes.zAxis.extend(0), translation.extend(1));
    }
    export function fromQuat(rotation: Quat): Mat4 {
        const axes = quatToAxes(rotation);
        return Mat4(axes.xAxis.extend(0), axes.yAxis.extend(0), axes.zAxis.extend(0), Vec4(0, 0, 0, 1));
    }
    export function fromMat3(m: Mat3): Mat4 {
        return Mat4(m.xAxis.extend(0), m.yAxis.extend(0), m.zAxis.extend(0), Vec4(0, 0, 0, 1));
    }
    export function fromMat3Translation(m: Mat3, translation: Vec3): Mat4 {
        return Mat4(m.xAxis.extend(0), m.yAxis.extend(0), m.zAxis.extend(0), translation.extend(1));
    }
    export function fromTranslation(t: Vec3): Mat4 {
        return Mat4(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(t.x, t.y, t.z, 1));
    }
    export function fromScale(s: Vec3): Mat4 {
        return Mat4(Vec4(s.x, 0, 0, 0), Vec4(0, s.y, 0, 0), Vec4(0, 0, s.z, 0), Vec4(0, 0, 0, 1));
    }
    export function fromAxisAngle(axis: Vec3, angle: f32): Mat4 {
        const sc = appleSincosf(angle);
        const sin = sc.s;
        const cos = sc.c;
        const axisSin = axis * sin;
        const axisSq = axis.mul(axis);
        const omc = <f32>1.0 - cos;
        const xyomc = axis.x * axis.y * omc;
        const xzomc = axis.x * axis.z * omc;
        const yzomc = axis.y * axis.z * omc;
        return Mat4(
            Vec4(axisSq.x * omc + cos, xyomc + axisSin.z, xzomc - axisSin.y, 0),
            Vec4(xyomc - axisSin.z, axisSq.y * omc + cos, yzomc + axisSin.x, 0),
            Vec4(xzomc + axisSin.y, yzomc - axisSin.x, axisSq.z * omc + cos, 0),
            Vec4(0, 0, 0, 1),
        );
    }
    export function fromEuler(order: EulerRot, a: f32, b: f32, c: f32): Mat4 {
        return fromMat3(mat3FromEulerAngles(order, a, b, c));
    }
    export function fromRotationX(angle: f32): Mat4 {
        const sc = appleSincosf(angle);
        const sina = sc.s;
        const cosa = sc.c;
        return Mat4(Vec4(1, 0, 0, 0), Vec4(0, cosa, sina, 0), Vec4(0, -sina, cosa, 0), Vec4(0, 0, 0, 1));
    }
    export function fromRotationY(angle: f32): Mat4 {
        const sc = appleSincosf(angle);
        const sina = sc.s;
        const cosa = sc.c;
        return Mat4(Vec4(cosa, 0, -sina, 0), Vec4(0, 1, 0, 0), Vec4(sina, 0, cosa, 0), Vec4(0, 0, 0, 1));
    }
    export function fromRotationZ(angle: f32): Mat4 {
        const sc = appleSincosf(angle);
        const sina = sc.s;
        const cosa = sc.c;
        return Mat4(Vec4(cosa, sina, 0, 0), Vec4(-sina, cosa, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1));
    }
    // Same as camera.lookToMat4Rh / camera.lookAtMat4Rh.
    export function lookToRh(eye: Vec3, dir: Vec3, up: Vec3): Mat4 { return camera.lookToMat4Rh(eye, dir, up); }
    export function lookAtRh(eye: Vec3, center: Vec3, up: Vec3): Mat4 { return camera.lookAtMat4Rh(eye, center, up); }
}

export function mat4(xAxis: Vec4, yAxis: Vec4, zAxis: Vec4, wAxis: Vec4): Mat4 { return Mat4(xAxis, yAxis, zAxis, wAxis); }

// What Mat4.toScaleRotationTranslation returns.
export struct ScaleRotationTranslation {
    scale: Vec3 = Vec3(1, 1, 1);
    rotation: Quat = Quat(0, 0, 0, 1);
    translation: Vec3 = Vec3(0, 0, 0);
    constructor(scale: Vec3, rotation: Quat, translation: Vec3) {
        this.scale = scale;
        this.rotation = rotation;
        this.translation = translation;
    }
}

// ---------------------------------------------------------------------------
// Camera matrices, right-handed only:
//   camera.lookAtMat4Rh / lookToMat4Rh      view matrices
//   camera.perspectiveRhDirectx             perspective projection, depth in [0, 1]
//   camera.orthographicRhDirectx            orthographic projection, depth in [0, 1]
// (rasc resolves at most two namespace levels across modules, so the names
// are flat.)

export namespace camera {
    export function lookToMat4Rh(eye: Vec3, dir: Vec3, up: Vec3): Mat4 {
        const f = dir;
        const s = f.cross(up).normalize();
        const u = s.cross(f);
        return Mat4(
            Vec4(s.x, u.x, -f.x, 0),
            Vec4(s.y, u.y, -f.y, 0),
            Vec4(s.z, u.z, -f.z, 0),
            Vec4(-eye.dot(s), -eye.dot(u), eye.dot(f), 1),
        );
    }
    export function lookAtMat4Rh(eye: Vec3, center: Vec3, up: Vec3): Mat4 {
        return lookToMat4Rh(eye, (center - eye).normalize(), up);
    }
    // DirectX / WebGPU clip space: depth 0..1, y up.
    export function perspectiveRhDirectx(verticalFov: f32, aspectRatio: f32, near: f32, far: f32): Mat4 {
        const sc = appleSincosf(<f32>0.5 * verticalFov);
        const sinFov = sc.s;
        const cosFov = sc.c;
        const h = cosFov / sinFov;
        const xx = h / aspectRatio;
        const yy = h;
        const zRangeInv = <f32>1.0 / (far - near);
        const zz = -far * zRangeInv;
        const tz = -near * far * zRangeInv;
        return Mat4(Vec4(xx, 0, 0, 0), Vec4(0, yy, 0, 0), Vec4(0, 0, zz, -1), Vec4(0, 0, tz, 0));
    }
    export function orthographicRhDirectx(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32): Mat4 {
        const widthInv = <f32>1.0 / (right - left);
        const heightInv = <f32>1.0 / (top - bottom);
        const depthInv = <f32>1.0 / (far - near);
        const xx = widthInv + widthInv;
        const yy = heightInv + heightInv;
        const zz = -depthInv;
        const tx = -(left + right) * widthInv;
        const ty = -(top + bottom) * heightInv;
        const tz = -near * depthInv;
        return Mat4(Vec4(xx, 0, 0, 0), Vec4(0, yy, 0, 0), Vec4(0, 0, zz, 0), Vec4(tx, ty, tz, 1));
    }
}
