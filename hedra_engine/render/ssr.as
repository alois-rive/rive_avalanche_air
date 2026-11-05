// Screen-space reflections on the CPU: the reference of
// shaders/render/post_ssr.wgsl, step for step (gpu/ssr.as runs the shader;
// ./screen.as holds Godot's curves both use). The tests hold the shader's
// pixels to it; nothing in a frame calls it.
//
// The march (fs_ssr_trace) of one texel p of the trace target (tw x th:
// the render size, or half of it), reading the normal-depth pass's
// picture (w x h, the render size: view-space normals, positive view
// depths, 0 where nothing is drawn):
//
//   1. q, p's source pixel (floor((p + 0.5) * w / tw)); nothing drawn
//      there, or a roughness Godot fades out entirely (ssrRoughnessFade
//      0), is no reflection.
//   2. P, q's view position (the eye ray through q's centre at q's depth;
//      orthographic: straight along -z), V the view ray (orthographic
//      (0, 0, -1)), R = reflect(V, n); a ray leaving the surface at a
//      grazing angle (R . n < 0.001) is none (Godot's test).
//   3. Godot's ray: as long as the far distance, clipped to the near
//      plane; both ends projected, 1/w and z/w kept so that the depth
//      along the screen line is perspective-correct; the line clipped to
//      the target (at 0.99 of the way to an edge, as Godot's; Godot
//      multiplies two of the four clips, which shortens a ray leaving
//      through a corner: here the least of the four is taken).
//   4. Godot steps one pixel a step and stops after ssr_max_steps; here
//      the steps stride so that ssr_max_steps of them cross the clipped
//      line (`stride = max(1, pixels / steps)` texels), from 1 texel out,
//      each start moved by BAYER4[p] / 16 of a stride (a deterministic
//      dither that the next texel's start fills in). At each step the
//      ray's depth zr (positive) is tested against the picture's depth ds
//      at that texel's source pixel: nothing drawn (0) never hits; a
//      surface in front of the ray (ds < zr) facing it (R . n_s < 0.001,
//      Godot's test: a surface seen from behind is passed under) is a hit
//      when it lies within ssr_depth_tolerance of the ray's last stretch
//      (ds >= min(zr_from, zr_to) - tolerance, Godot's test in positive
//      depths) and short of 0.95 of the far distance, else the march stops
//      without one (the ray went behind something). A hit is refined by
//      SSR_REFINE_STEPS halvings between the last two positions (Godot
//      needs none at a pixel a step).
//   5. fade = ssrStepFade(steps taken, steps) * ssrMarginFade(hit) *
//      ssrRoughnessFade(roughness).
//
// The colour is the screen texture's at the hit (gpu/ssr.as and the
// shader; ssrLod and ssrTapCount below say where), and the texel the
// trace writes is (colour * w.rgb, w.w) with w = ssrMergeWeight(F0, n.v,
// fade). fs_ssr_merge then lays it over the picture: with a half-size
// trace, a joint bilateral upsample of the 2 x 2 nearest texels
// (ssrUpsampleCpu), premultiplied over (ssrMergeCpu).

import { Mat4, Vec2, Vec3, Vec4, cosf, log2f, sinf } from "../base/vecmath";
import { BAYER4 } from "./post";
import {
    SSR_REFINE_STEPS, SSR_ROUGHNESS_DISABLED, SSR_ROUGHNESS_LOW, SsrDesc, ssrMarginFade,
    ssrRoughnessFade, ssrStepFade, ssrSteps,
} from "./screen";

// Godot's grazing test: a ray (or a surface it meets) whose cosine with
// the normal is under this is no reflection (or not met from the front).
export const SSR_FACING: f32 = 0.001;
// Godot's far guard: a hit at 0.95 of the far distance or beyond is none
// (the far plane's own depth is no surface).
export const SSR_FAR_GUARD: f32 = 0.95;
// The screen texture's taps for a rough reflection by roughness quality
// (SSR_ROUGHNESS_*): disabled one at level 0, low one at the blur's level,
// medium 4 and high 8 around the hit at one level finer (a ring of taps
// half the blur out, turned by BAYER4 so that neighbours fill each other
// in).
export const SSR_TAPS: StaticArray<i32> = [1, 1, 4, 8];

// What ssrTraceCpu found for one texel.
export class SsrHit {
    // Whether the ray met a surface (the fade may still be 0).
    hit: bool = false;
    // The steps taken before the hit (Godot's steps_taken).
    steps: i32 = 0;
    // The hit in trace-target texels (0 to tw, y down: texel centres at
    // +0.5), and its distance from the start in source pixels.
    x: f32 = 0;
    y: f32 = 0;
    distance: f32 = 0;
    // Godot's three fades and their product.
    stepFade: f32 = 0;
    marginFade: f32 = 0;
    roughnessFade: f32 = 0;
    fade: f32 = 0;
    // The view ray and the normal at the start (for ssrMergeWeight's n.v).
    nv: f32 = 0;

    reset(): void {
        this.hit = false;
        this.steps = 0;
        this.x = 0;
        this.y = 0;
        this.distance = 0;
        this.stepFade = 0;
        this.marginFade = 0;
        this.roughnessFade = 0;
        this.fade = 0;
        this.nv = 0;
    }
}

// Whether `proj` (camera.as projectionMatrix) is orthographic: its w row
// is (0, 0, 0, 1) (a perspective's is (0, 0, -1, 0)).
export function projIsOrtho(proj: Mat4): bool {
    return proj.zAxis.w == 0;
}

// The near and far distances of `proj` (the DirectX-style right-handed
// projections of camera.as: clip z 0 at the near plane, 1 at the far).
export function projNear(proj: Mat4): f32 {
    return proj.wAxis.z / proj.zAxis.z;
}

export function projFar(proj: Mat4): f32 {
    if (projIsOrtho(proj)) return (proj.wAxis.z - 1) / proj.zAxis.z;
    return proj.wAxis.z / (proj.zAxis.z + 1);
}

// The view position at view depth `d` (positive) under the picture's UV
// (u right, v down, 0 to 1): on the eye ray through that point of the near
// plane, scaled to the depth (perspective) or straight along -z
// (orthographic). post_ssr.wgsl `view_at`.
export function ssrViewAt(invProj: Mat4, ortho: bool, u: f32, v: f32, d: f32): Vec3 {
    const a4 = invProj.mulVec4(Vec4(<f32>2 * u - 1, <f32>1 - <f32>2 * v, 0, 1));
    const a = Vec3(a4.x / a4.w, a4.y / a4.w, a4.z / a4.w);
    if (ortho) return Vec3(a.x, a.y, -d);
    return a * (d / -a.z);
}

// The point `p` (view space) on a target `tw` x `th`: xy in texels (y
// down), z 1/w. post_ssr.wgsl `to_target`.
export function ssrToTarget(proj: Mat4, p: Vec3, tw: f32, th: f32): Vec3 {
    const c = proj.mulVec4(Vec4(p.x, p.y, p.z, 1));
    const nx = c.x / c.w;
    const ny = c.y / c.w;
    return Vec3((nx * <f32>0.5 + <f32>0.5) * tw, (<f32>0.5 - ny * <f32>0.5) * th, <f32>1 / c.w);
}

// BAYER4 at texel (x, y) over 16: the march's start and the taps' turn.
export function ssrDither(x: i32, y: i32): f32 {
    return <f32>BAYER4[(y & 3) * 4 + (x & 3)] / <f32>16;
}

// The source pixel of trace position (tx, ty) (texels of tw x th) in a
// picture w x h, as an index.
function sourceIndex(tx: f32, ty: f32, tw: f32, th: f32, w: i32, h: i32): i32 {
    // (clamped as floats: a float to int cast traps out of range)
    const sx = <i32>min<f32>(max<f32>(Mathf.floor(tx * <f32>w / tw), 0), <f32>(w - 1));
    const sy = <i32>min<f32>(max<f32>(Mathf.floor(ty * <f32>h / th), 0), <f32>(h - 1));
    return sy * w + sx;
}

// The march of texel (x, y) of a tw x th trace target (0: the picture's
// size) over the picture `depth` (w * h positive view depths, 0 nothing)
// and `normals` (3 a pixel, view space), projected by `proj`, with
// `desc`'s steps, fades and tolerance and, when given, `roughness` (one a
// pixel; none: 0). Writes and returns `out` (see the header).
export function ssrTraceCpu(
    depth: Float32Array, normals: Float32Array, w: i32, h: i32, proj: Mat4, desc: SsrDesc, x: i32, y: i32,
    out: SsrHit, tw: i32 = 0, th: i32 = 0, roughness: Float32Array? = null,
): SsrHit {
    out.reset();
    const tW: f32 = <f32>(tw > 0 ? tw : w);
    const tH: f32 = <f32>(th > 0 ? th : h);
    const qi = sourceIndex(<f32>x + 0.5, <f32>y + 0.5, tW, tH, w, h);
    const d0 = depth[qi];
    if (d0 <= 0) return out;
    const r0: f32 = roughness != null ? roughness[qi] : 0;
    const rf = ssrRoughnessFade(r0);
    out.roughnessFade = rf;
    if (rf <= 0) return out;
    const ortho = projIsOrtho(proj);
    const near = projNear(proj);
    const far = projFar(proj);
    const invProj = proj.inverse();
    const n = Vec3(normals[qi * 3], normals[qi * 3 + 1], normals[qi * 3 + 2]).normalize();
    const qx = qi % w;
    const qy = qi / w;
    const pv = ssrViewAt(invProj, ortho, (<f32>qx + 0.5) / <f32>w, (<f32>qy + 0.5) / <f32>h, d0);
    const v = ortho ? Vec3(0, 0, -1) : pv.normalize();
    out.nv = min<f32>(max<f32>(n.dot(-v), 0), 1);
    const r = v.reflect(n).normalize();
    if (r.dot(n) < SSR_FACING) return out;
    let len = far;
    if (pv.z + r.z * far > -near) len = (-near - pv.z) / r.z;
    const pe = pv + r * len;
    const b = ssrToTarget(proj, pv, tW, tH);
    const e = ssrToTarget(proj, pe, tW, tH);
    const zb = pv.z * b.z;
    const ze = pe.z * e.z;
    const vbx = b.x / tW;
    const vby = b.y / tH;
    const vdx = (e.x - b.x) / tW;
    const vdy = (e.y - b.y) / tH;
    const clip = min<f32>(
        min<f32>(min<f32>(1, <f32>0.99 * (1 - vbx) / max<f32>(1e-5, vdx)), <f32>0.99 * (1 - vby) / max<f32>(1e-5, vdy)),
        min<f32>(<f32>0.99 * vbx / max<f32>(1e-5, -vdx), <f32>0.99 * vby / max<f32>(1e-5, -vdy)),
    );
    const lx = (e.x - b.x) * clip;
    const ly = (e.y - b.y) * clip;
    const dz = (ze - zb) * clip;
    const dw = (e.z - b.z) * clip;
    const pixels = max<f32>(Mathf.abs(lx), Mathf.abs(ly));
    if (pixels < 1) return out;
    const steps = ssrSteps(desc);
    const stride = max<f32>(1, pixels / <f32>steps);
    const jit = ssrDither(x, y);
    const tol = max<f32>(desc.depthTolerance, 0);
    let tPrev: f32 = 0;
    let zrFrom = -pv.z;
    let tHit: f32 = -1;
    let taken = 0;
    for (let i = 0; i < steps; i++) {
        const t = <f32>1 + stride * (<f32>i + jit);
        if (t > pixels) break;
        const k = t / pixels;
        const px = b.x + lx * k;
        const py = b.y + ly * k;
        const zrTo = -(zb + dz * k) / (b.z + dw * k);
        const si = sourceIndex(Mathf.floor(px) + 0.5, Mathf.floor(py) + 0.5, tW, tH, w, h);
        const ds = depth[si];
        if (ds > 0 && ds < zrTo) {
            const sn = Vec3(normals[si * 3], normals[si * 3 + 1], normals[si * 3 + 2]);
            if (r.dot(sn) < SSR_FACING) {
                if (ds >= min<f32>(zrFrom, zrTo) - tol && ds < SSR_FAR_GUARD * far) {
                    tHit = t;
                    taken = i;
                }
                break;
            }
        }
        zrFrom = zrTo;
        tPrev = t;
    }
    if (tHit < 0) return out;
    let lo = tPrev;
    let hi = tHit;
    for (let k = 0; k < SSR_REFINE_STEPS; k++) {
        const mid = (lo + hi) * 0.5;
        const km = mid / pixels;
        const zr = -(zb + dz * km) / (b.z + dw * km);
        const mi = sourceIndex(Mathf.floor(b.x + lx * km) + 0.5, Mathf.floor(b.y + ly * km) + 0.5, tW, tH, w, h);
        const dm = depth[mi];
        if (dm > 0 && dm < zr) hi = mid;
        else lo = mid;
    }
    const kh = hi / pixels;
    out.hit = true;
    out.steps = taken;
    out.x = b.x + lx * kh;
    out.y = b.y + ly * kh;
    out.distance = Vec2(out.x - b.x, out.y - b.y).length() * <f32>w / tW;
    out.stepFade = ssrStepFade(<f32>taken, steps, desc.fadeIn, desc.fadeOut);
    out.marginFade = ssrMarginFade(out.x, out.y, tW, tH);
    out.fade = out.stepFade * out.marginFade * rf;
    return out;
}

// The screen texture's level a reflection of a surface of roughness
// `rough`, hit `distance` source pixels away, reads at by roughness
// quality `quality` (SSR_ROUGHNESS_*), the texture holding `levels`
// levels: 0 when disabled, else log2 of the blur's width (distance *
// rough^2, at least 1), held to the levels; medium and high read one level
// finer (their taps spread the blur instead).
export function ssrLod(distance: f32, rough: f32, levels: i32, quality: u32): f32 {
    if (quality == SSR_ROUGHNESS_DISABLED || levels <= 1) return 0;
    const lod = min<f32>(max<f32>(log2f(max<f32>(1, distance * rough * rough)), 0), <f32>(levels - 1));
    if (quality == SSR_ROUGHNESS_LOW) return lod;
    return max<f32>(lod - 1, 0);
}

// The taps of a reflection's colour by roughness quality (SSR_TAPS).
export function ssrTapCount(quality: u32): i32 {
    return SSR_TAPS[<i32>min<u32>(quality, 3)];
}

// Tap `i` of `count` around the hit, in source pixels, for a blur
// `blur` (distance * rough^2) and a turn `turn` (ssrDither, 0 to 1): on a
// ring of half the blur (none with one tap).
export function ssrTapOffset(i: i32, count: i32, blur: f32, turn: f32): Vec2 {
    if (count <= 1) return Vec2(0, 0);
    const a = <f32>2 * <f32>Math.PI * (<f32>i + turn) / <f32>count;
    const rad = <f32>0.5 * blur;
    return Vec2(cosf(a) * rad, sinf(a) * rad);
}

// The merge of a reflection over the colour below it (premultiplied over:
// the reflection texel holds reflection * w.rgb and w.w): colour (1 - w.w)
// + reflection * w.rgb. `reflection` is the screen's colour at the hit,
// `weight` ssrMergeWeight's.
export function ssrMergeCpu(colour: Vec3, reflection: Vec3, weight: Vec4): Vec3 {
    const k = <f32>1 - weight.w;
    return Vec3(
        colour.x * k + reflection.x * weight.x,
        colour.y * k + reflection.y * weight.y,
        colour.z * k + reflection.z * weight.z,
    );
}

// The joint bilateral weight of one of the 2 x 2 trace texels around a
// pixel: its bilinear weight over 1e-3 plus the relative difference of
// its depth `zi` from the pixel's `z`; a texel where nothing is drawn
// (zi 0) weighs nothing.
export function ssrBilateralWeight(bilinear: f32, zi: f32, z: f32): f32 {
    if (zi <= 0 || z <= 0) return 0;
    return bilinear / (<f32>1e-3 + Mathf.abs(zi - z) / z);
}

// fs_ssr_merge's texel for pixel (x, y) of a picture pw x ph: the trace
// target `ssr` (4 floats a texel, sw x sh) read at the pixel when it is
// the picture's size, else upsampled from the 2 x 2 nearest texels by
// ssrBilateralWeight with the depths of `depth` (pw x ph); 0 where nothing
// is drawn.
export function ssrUpsampleCpu(
    ssr: Float32Array, sw: i32, sh: i32, depth: Float32Array, pw: i32, ph: i32, x: i32, y: i32,
): Vec4 {
    const z = depth[y * pw + x];
    if (z <= 0) return Vec4(0, 0, 0, 0);
    if (sw == pw && sh == ph) {
        const o = (y * sw + x) * 4;
        return Vec4(ssr[o], ssr[o + 1], ssr[o + 2], ssr[o + 3]);
    }
    const sx = (<f32>x + 0.5) * <f32>sw / <f32>pw - 0.5;
    const sy = (<f32>y + 0.5) * <f32>sh / <f32>ph - 0.5;
    const bx = Mathf.floor(sx);
    const by = Mathf.floor(sy);
    const fx = sx - bx;
    const fy = sy - by;
    let r: f32 = 0;
    let g: f32 = 0;
    let b: f32 = 0;
    let a: f32 = 0;
    let ws: f32 = 0;
    for (let j = 0; j < 4; j++) {
        const ox = j & 1;
        const oy = j >> 1;
        const tx = min<i32>(max<i32>(<i32>bx + ox, 0), sw - 1);
        const ty = min<i32>(max<i32>(<i32>by + oy, 0), sh - 1);
        const bil = (ox == 1 ? fx : <f32>1 - fx) * (oy == 1 ? fy : <f32>1 - fy);
        const si = sourceIndex(<f32>tx + 0.5, <f32>ty + 0.5, <f32>sw, <f32>sh, pw, ph);
        const wgt = ssrBilateralWeight(bil, depth[si], z);
        if (wgt <= 0) continue;
        const o = (ty * sw + tx) * 4;
        r += ssr[o] * wgt;
        g += ssr[o + 1] * wgt;
        b += ssr[o + 2] * wgt;
        a += ssr[o + 3] * wgt;
        ws += wgt;
    }
    if (ws <= 1e-8) return Vec4(0, 0, 0, 0);
    return Vec4(r / ws, g / ws, b / ws, a / ws);
}
