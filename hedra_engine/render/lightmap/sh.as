// Linear (L1) spherical harmonics of light, as a lightmap probe stores it
// and as the surface shader reads it for an item lit by probes
// (DrawItem.probeSh; surface.wgsl `probe_light`, which must say the same).
//
// A probe holds SH_L1_FLOATS numbers, four a colour channel (red, green,
// blue): c0 and the vector c1. They are not the raw coefficients of the
// radiance L but those of its cosine-weighted mean seen by a normal n,
//
//     B(n) = max(c0 + dot(c1, n), 0),
//
// which is what a lightmap texel holds (data.as): the light the shader
// multiplies by the diffuse colour. For radiance L(w) = a + dot(b, w) the
// cosine-weighted mean over n's hemisphere is a + (2/3) dot(b, n), and
// projecting L on the sphere gives a = mean(L) and b = 3 mean(L w), so
//
//     c0 = mean over the sphere of L,    c1 = 2 * mean over the sphere of L w.
//
// `shAddSample` accumulates that from directions spread evenly over the
// sphere (each sample's weight 1 / count); a uniform L gives c1 = 0 and
// B(n) = L for every n, as lit()'s flat ambient light gives L.
//
// Directions are in the space the numbers were made in: the frame's world
// in memory, scene space (Y up) in an .lmbake file (`shSceneToRender`).

import { MAT4_IDENTITY, Mat4, Vec3, Vec4 } from "../../base/vecmath";

export const SH_L1_FLOATS: i32 = 12;

// Zeroes the SH_L1_FLOATS numbers of `sh` at `at`.
export function shClear(sh: Float32Array, at: i32): void {
    for (let k = 0; k < SH_L1_FLOATS; k++) sh[at + k] = 0;
}

// Adds one sample of radiance `radiance` arriving from unit direction `d`
// with weight `w` (1 / the sample count, for samples spread evenly over
// the sphere) to the probe at `at` of `sh`.
export function shAddSample(sh: Float32Array, at: i32, d: Vec3, radiance: Vec3, w: f32): void {
    for (let c = 0; c < 3; c++) {
        const l: f32 = c == 0 ? radiance.x : c == 1 ? radiance.y : radiance.z;
        const o = at + c * 4;
        sh[o] += w * l;
        const l2 = w * <f32>2 * l;
        sh[o + 1] += l2 * d.x;
        sh[o + 2] += l2 * d.y;
        sh[o + 3] += l2 * d.z;
    }
}

// B(n) of the probe at `at` (see the header), never negative.
export function shEval(sh: Float32Array, at: i32, n: Vec3): Vec3 {
    const r = sh[at] + sh[at + 1] * n.x + sh[at + 2] * n.y + sh[at + 3] * n.z;
    const g = sh[at + 4] + sh[at + 5] * n.x + sh[at + 6] * n.y + sh[at + 7] * n.z;
    const b = sh[at + 8] + sh[at + 9] * n.x + sh[at + 10] * n.y + sh[at + 11] * n.z;
    return Vec3(max<f32>(r, 0), max<f32>(g, 0), max<f32>(b, 0));
}

// Adds `w` times the probe at `from` of `src` to the one at `at` of `dst`
// (interpolation: probes.as).
export function shAddScaled(dst: Float32Array, at: i32, src: Float32Array, from: i32, w: f32): void {
    for (let k = 0; k < SH_L1_FLOATS; k++) dst[at + k] += w * src[from + k];
}

// The probe at `at` turned from scene space (Y up) to the renderer's (Z
// up), in place: each c1 is a direction, (x, y, z) -> (x, -z, y), as
// engine/src/scene/space.as sceneToModel. Exact (a sign change).
export function shSceneToRender(sh: Float32Array, at: i32): void {
    for (let c = 0; c < 3; c++) {
        const o = at + c * 4;
        const y = sh[o + 2];
        const z = sh[o + 3];
        sh[o + 2] = -z;
        sh[o + 3] = y;
    }
}

// The inverse of shSceneToRender: (x, y, z) -> (x, z, -y).
export function shRenderToScene(sh: Float32Array, at: i32): void {
    for (let c = 0; c < 3; c++) {
        const o = at + c * 4;
        const y = sh[o + 2];
        const z = sh[o + 3];
        sh[o + 2] = z;
        sh[o + 3] = -y;
    }
}

// The rotation of `m` (its axes made unit length, no translation), for
// turning a probe's directions as `m` turns space: a scale has no say in a
// direction. A matrix with an axis of no length gives the identity.
export function rotationOf(m: Mat4): Mat4 {
    const x = m.xAxis.truncate(), y = m.yAxis.truncate(), z = m.zAxis.truncate();
    const lx = x.length(), ly = y.length(), lz = z.length();
    if (!(lx > 0) || !(ly > 0) || !(lz > 0)) return MAT4_IDENTITY;
    return Mat4((x / lx).extend(0), (y / ly).extend(0), (z / lz).extend(0), Vec4(0, 0, 0, 1));
}

// The probe at `at` with its directions (each channel's c1) turned by the
// rotation `r` (rotationOf), in place: light that came from d now comes
// from r d.
export function shTurn(sh: Float32Array, at: i32, r: Mat4): void {
    for (let c = 0; c < 3; c++) {
        const o = at + c * 4;
        const d = r.transformVector3(Vec3(sh[o + 1], sh[o + 2], sh[o + 3]));
        sh[o + 1] = d.x;
        sh[o + 2] = d.y;
        sh[o + 3] = d.z;
    }
}
