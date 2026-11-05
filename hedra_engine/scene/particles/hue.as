// A particle's hue variation (milestone 35; docs/engine/PARTICLES.md):
// Godot's hue rotation matrix from CPUParticles3D::_particles_process, the
// sum of three fixed matrices weighted by 1, the cosine and the sine of
// the angle, applied as Godot applies it, with Basis::xform_inv (the
// matrix's transpose times the colour, which is what the GLSL of Godot's
// ParticleProcessMaterial computes from the same rows). The transpose is
// Godot's, so a turned colour is Godot's colour; it keeps neither a grey
// grey nor the luminance (the matrix applied the other way keeps both
// within 0.004), and at an angle of 0 it is the identity within 0.001
// (white becomes 0.999, 0.999, 1), as in Godot. The angle's cosine and
// sine come from base/vecmath (software: the same bits on every host).
// Allocates nothing.

import { Vec3, cosf, sinf } from "../../base/vecmath";

// Godot's rows: mat1 (the luminance weights), mat2 (times the cosine) and
// mat3 (times the sine), row by row.
const M1R: f32 = 0.299;
const M1G: f32 = 0.587;
const M1B: f32 = 0.114;

// `rgb` turned by `angle` radians about the hue circle, as Godot turns a
// particle's colour (its alpha is not touched).
export function hueRotate(rgb: Vec3, angle: f32): Vec3 {
    const c = angle == 0 ? <f32>1 : cosf(angle);
    const s = angle == 0 ? <f32>0 : sinf(angle);
    return hueRotateBy(rgb, c, s);
}

// The same, from the angle's cosine `c` and sine `s` (the simulation keeps
// them per particle while they do not change).
export function hueRotateBy(rgb: Vec3, c: f32, s: f32): Vec3 {
    // Row j of the matrix: mat1[j] + mat2[j] c + mat3[j] s.
    const r0x = M1R + <f32>0.701 * c + <f32>0.168 * s;
    const r0y = M1G - <f32>0.587 * c + <f32>0.330 * s;
    const r0z = M1B - <f32>0.114 * c - <f32>0.497 * s;
    const r1x = M1R - <f32>0.299 * c - <f32>0.328 * s;
    const r1y = M1G + <f32>0.413 * c + <f32>0.035 * s;
    const r1z = M1B - <f32>0.114 * c + <f32>0.292 * s;
    const r2x = M1R - <f32>0.300 * c + <f32>1.250 * s;
    const r2y = M1G - <f32>0.588 * c - <f32>1.050 * s;
    const r2z = M1B + <f32>0.886 * c - <f32>0.203 * s;
    // xform_inv: each output channel is a column of the rows dotted with
    // the colour.
    return Vec3(
        r0x * rgb.x + r1x * rgb.y + r2x * rgb.z,
        r0y * rgb.x + r1y * rgb.y + r2y * rgb.z,
        r0z * rgb.x + r1z * rgb.y + r2z * rgb.z,
    );
}
