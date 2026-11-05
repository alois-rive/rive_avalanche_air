// Affine transforms as 12 f64 numbers, for the listeners' picking and
// aligning (./pick.as, ../sm/listeners.as): the columns x, y and z of the
// 3 x 3 part, then the translation, three numbers each (the layout of the
// interaction world's sync, ../interaction/world.as, which this follows).
// Scalar arithmetic into arrays the caller keeps: a pointer event over a
// scene of hundreds of items works out hundreds of inverses, which as Mat4
// products would cost a microsecond each, and allocates nothing.

import { Mat4 } from "../../base/vecmath";
import { SceneNode } from "../tree/node";

// A new array of 12 numbers (made once by each user).
export function affine(): StaticArray<f64> {
    return new StaticArray<f64>(12);
}

// `m` (a Mat4's columns; its last row is taken as 0 0 0 1).
export function affineOf(m: Mat4, out: StaticArray<f64>): void {
    unchecked(out[0] = <f64>m.xAxis.x);
    unchecked(out[1] = <f64>m.xAxis.y);
    unchecked(out[2] = <f64>m.xAxis.z);
    unchecked(out[3] = <f64>m.yAxis.x);
    unchecked(out[4] = <f64>m.yAxis.y);
    unchecked(out[5] = <f64>m.yAxis.z);
    unchecked(out[6] = <f64>m.zAxis.x);
    unchecked(out[7] = <f64>m.zAxis.y);
    unchecked(out[8] = <f64>m.zAxis.z);
    unchecked(out[9] = <f64>m.wAxis.x);
    unchecked(out[10] = <f64>m.wAxis.y);
    unchecked(out[11] = <f64>m.wAxis.z);
}

// The node's global transform (its local, times each 3D parent's in turn,
// as SceneNode.global multiplies them).
export function globalAffine(n: SceneNode, out: StaticArray<f64>): void {
    const l = n.local;
    let x0 = <f64>l.xAxis.x, x1 = <f64>l.xAxis.y, x2 = <f64>l.xAxis.z;
    let y0 = <f64>l.yAxis.x, y1 = <f64>l.yAxis.y, y2 = <f64>l.yAxis.z;
    let z0 = <f64>l.zAxis.x, z1 = <f64>l.zAxis.y, z2 = <f64>l.zAxis.z;
    let t0 = <f64>l.wAxis.x, t1 = <f64>l.wAxis.y, t2 = <f64>l.wAxis.z;
    let cur = n;
    while (true) {
        const p = cur.parent;
        if (p == null || !p.is3d) break;
        const m = p.local;
        const m0 = <f64>m.xAxis.x, m1 = <f64>m.xAxis.y, m2 = <f64>m.xAxis.z;
        const m3 = <f64>m.yAxis.x, m4 = <f64>m.yAxis.y, m5 = <f64>m.yAxis.z;
        const m6 = <f64>m.zAxis.x, m7 = <f64>m.zAxis.y, m8 = <f64>m.zAxis.z;
        let a = x0, b = x1, c = x2;
        x0 = m0 * a + m3 * b + m6 * c;
        x1 = m1 * a + m4 * b + m7 * c;
        x2 = m2 * a + m5 * b + m8 * c;
        a = y0; b = y1; c = y2;
        y0 = m0 * a + m3 * b + m6 * c;
        y1 = m1 * a + m4 * b + m7 * c;
        y2 = m2 * a + m5 * b + m8 * c;
        a = z0; b = z1; c = z2;
        z0 = m0 * a + m3 * b + m6 * c;
        z1 = m1 * a + m4 * b + m7 * c;
        z2 = m2 * a + m5 * b + m8 * c;
        a = t0; b = t1; c = t2;
        t0 = m0 * a + m3 * b + m6 * c + <f64>m.wAxis.x;
        t1 = m1 * a + m4 * b + m7 * c + <f64>m.wAxis.y;
        t2 = m2 * a + m5 * b + m8 * c + <f64>m.wAxis.z;
        cur = p;
    }
    unchecked(out[0] = x0);
    unchecked(out[1] = x1);
    unchecked(out[2] = x2);
    unchecked(out[3] = y0);
    unchecked(out[4] = y1);
    unchecked(out[5] = y2);
    unchecked(out[6] = z0);
    unchecked(out[7] = z1);
    unchecked(out[8] = z2);
    unchecked(out[9] = t0);
    unchecked(out[10] = t1);
    unchecked(out[11] = t2);
}

// `out` = the inverse of `a`; false (and `out` all 0) when `a` is
// singular (a zero scale draws nothing and is hit nowhere). `out` must not
// be `a`.
export function invertAffine(a: StaticArray<f64>, out: StaticArray<f64>): bool {
    const a0 = unchecked(a[0]), a1 = unchecked(a[1]), a2 = unchecked(a[2]);
    const a3 = unchecked(a[3]), a4 = unchecked(a[4]), a5 = unchecked(a[5]);
    const a6 = unchecked(a[6]), a7 = unchecked(a[7]), a8 = unchecked(a[8]);
    const c0 = a4 * a8 - a7 * a5;
    const c1 = a7 * a2 - a1 * a8;
    const c2 = a1 * a5 - a4 * a2;
    const det = a0 * c0 + a3 * c1 + a6 * c2;
    if (det == 0 || !isFinite(det)) {
        for (let k = 0; k < 12; k++) unchecked(out[k] = 0);
        return false;
    }
    const r = 1 / det;
    const i0 = c0 * r, i1 = c1 * r, i2 = c2 * r;
    const i3 = (a6 * a5 - a3 * a8) * r;
    const i4 = (a0 * a8 - a6 * a2) * r;
    const i5 = (a3 * a2 - a0 * a5) * r;
    const i6 = (a3 * a7 - a6 * a4) * r;
    const i7 = (a6 * a1 - a0 * a7) * r;
    const i8 = (a0 * a4 - a3 * a1) * r;
    unchecked(out[0] = i0);
    unchecked(out[1] = i1);
    unchecked(out[2] = i2);
    unchecked(out[3] = i3);
    unchecked(out[4] = i4);
    unchecked(out[5] = i5);
    unchecked(out[6] = i6);
    unchecked(out[7] = i7);
    unchecked(out[8] = i8);
    const tx = unchecked(a[9]), ty = unchecked(a[10]), tz = unchecked(a[11]);
    unchecked(out[9] = -(i0 * tx + i3 * ty + i6 * tz));
    unchecked(out[10] = -(i1 * tx + i4 * ty + i7 * tz));
    unchecked(out[11] = -(i2 * tx + i5 * ty + i8 * tz));
    return true;
}

// `out` = a * b (b applied first). `out` must be neither.
export function mulAffine(a: StaticArray<f64>, b: StaticArray<f64>, out: StaticArray<f64>): void {
    for (let c = 0; c < 4; c++) {
        const x = unchecked(b[c * 3]), y = unchecked(b[c * 3 + 1]), z = unchecked(b[c * 3 + 2]);
        const w: f64 = c == 3 ? 1 : 0;
        for (let r = 0; r < 3; r++) {
            unchecked(out[c * 3 + r] = unchecked(a[r]) * x + unchecked(a[3 + r]) * y + unchecked(a[6 + r]) * z
                + unchecked(a[9 + r]) * w);
        }
    }
}

// Whether two transforms are the same, number for number.
export function sameAffine(a: StaticArray<f64>, b: StaticArray<f64>): bool {
    for (let k = 0; k < 12; k++) if (unchecked(a[k]) != unchecked(b[k])) return false;
    return true;
}

// The point (x, y, z) through `a`, coordinate by coordinate.
export function apX(a: StaticArray<f64>, x: f64, y: f64, z: f64): f64 {
    return unchecked(a[0]) * x + unchecked(a[3]) * y + unchecked(a[6]) * z + unchecked(a[9]);
}

export function apY(a: StaticArray<f64>, x: f64, y: f64, z: f64): f64 {
    return unchecked(a[1]) * x + unchecked(a[4]) * y + unchecked(a[7]) * z + unchecked(a[10]);
}

export function apZ(a: StaticArray<f64>, x: f64, y: f64, z: f64): f64 {
    return unchecked(a[2]) * x + unchecked(a[5]) * y + unchecked(a[8]) * z + unchecked(a[11]);
}

// The direction (x, y, z) through `a`'s 3 x 3 part.
export function adX(a: StaticArray<f64>, x: f64, y: f64, z: f64): f64 {
    return unchecked(a[0]) * x + unchecked(a[3]) * y + unchecked(a[6]) * z;
}

export function adY(a: StaticArray<f64>, x: f64, y: f64, z: f64): f64 {
    return unchecked(a[1]) * x + unchecked(a[4]) * y + unchecked(a[7]) * z;
}

export function adZ(a: StaticArray<f64>, x: f64, y: f64, z: f64): f64 {
    return unchecked(a[2]) * x + unchecked(a[5]) * y + unchecked(a[8]) * z;
}

// A normal (x, y, z) through the inverse `inv` of a transform: inv's 3 x 3
// part transposed (unit length is the caller's).
export function anX(inv: StaticArray<f64>, x: f64, y: f64, z: f64): f64 {
    return unchecked(inv[0]) * x + unchecked(inv[1]) * y + unchecked(inv[2]) * z;
}

export function anY(inv: StaticArray<f64>, x: f64, y: f64, z: f64): f64 {
    return unchecked(inv[3]) * x + unchecked(inv[4]) * y + unchecked(inv[5]) * z;
}

export function anZ(inv: StaticArray<f64>, x: f64, y: f64, z: f64): f64 {
    return unchecked(inv[6]) * x + unchecked(inv[7]) * y + unchecked(inv[8]) * z;
}

// A scene-space transform `s` as the frame's render space sees it
// (../space.as: render = SCENE_TO_MODEL * scene, a permutation with one
// sign): out = C s C^-1, exact.
export function renderOfScene(s: StaticArray<f64>, out: StaticArray<f64>): void {
    // C (x, y, z) = (x, -z, y); C^-1 (x, y, z) = (x, z, -y). Column j of
    // C s C^-1 is C (s (C^-1 e_j)).
    // C^-1 e_x = e_x, C^-1 e_y = -e_z, C^-1 e_z = e_y.
    const sxx = unchecked(s[0]), sxy = unchecked(s[1]), sxz = unchecked(s[2]);
    const syx = unchecked(s[3]), syy = unchecked(s[4]), syz = unchecked(s[5]);
    const szx = unchecked(s[6]), szy = unchecked(s[7]), szz = unchecked(s[8]);
    const tx = unchecked(s[9]), ty = unchecked(s[10]), tz = unchecked(s[11]);
    // column x: C (s e_x) = (sxx, -sxz, sxy)
    unchecked(out[0] = sxx);
    unchecked(out[1] = -sxz);
    unchecked(out[2] = sxy);
    // column y: C (-s e_z) = (-szx, szz, -szy)
    unchecked(out[3] = -szx);
    unchecked(out[4] = szz);
    unchecked(out[5] = -szy);
    // column z: C (s e_y) = (syx, -syz, syy)
    unchecked(out[6] = syx);
    unchecked(out[7] = -syz);
    unchecked(out[8] = syy);
    // the origin: C t
    unchecked(out[9] = tx);
    unchecked(out[10] = -tz);
    unchecked(out[11] = ty);
}
