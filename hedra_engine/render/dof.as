// The depth of field on the CPU: the reference of
// shaders/render/post_dof.wgsl, pass for pass (gpu/dof.as runs the shader;
// ./screen.as holds Godot's circle of confusion, dofCoc). The tests hold
// the shader's pixels to it; nothing in a frame calls it.
//
//   fs_dof_coc      half the render size (DOF_FORMAT): rgb the 2 x 2
//                   block's mean colour, a the signed circle of confusion
//                   in half-size pixels, dofCoc at the block's nearest depth
//                   (nothing drawn: the camera's far distance) over 2
//                   (dofCocCpu).
//   fs_dof_gather   the same size: the centre and DOF_TAPS[quality] taps on
//                   rings of the bokeh's shape (dofTapOffsets), out to
//                   R = dofRadiusPx / 2. A tap at distance |o| (measured in
//                   the shape's own norm, so that a blurred point spreads
//                   into the shape: a square for the box, a hexagon, a
//                   disc) reaches the centre as far as dofTapReach says (the
//                   near field blurs over everything, the far field never
//                   over a sharper foreground) and weighs dofTapWeight; the
//                   centre weighs 1. rgb the weighted mean, a the near
//                   field's coverage, the most any near tap reaches over the
//                   centre (dofNearCover). With Godot's use_jitter each
//                   pixel's rings turn by BAYER4 / 16 of a tap (dofGatherCpu).
//   fs_dof_compose  the render size: the sharp colour mixed toward the
//                   gather (sampled bilinearly) by dofComposeBlend of the
//                   pixel's own circle at full size and the gather's
//                   coverage; the sharp alpha kept (dofComposeCpu).
//
// Where Godot differs (bokeh_dof_raster.glsl, bokeh_dof.cpp): Godot blurs
// the box and the hexagon in two or three separable passes (6 to 24 taps a
// direction by quality, half size at very low and low) and the circle on a
// golden-angle spiral; Hedra gathers every shape in one pass at half size,
// on rings, with as many taps as DOF_TAPS (8, 16, 32, 64), which runs on
// WebGL 2 without compute and costs one texture read a tap.

import { Vec2, Vec4, sinCosf } from "../base/vecmath";
import { BAYER4 } from "./post";
import { DOF_SHAPE_BOX, DOF_SHAPE_HEXAGON, DOF_TAPS, DofDesc, dofCoc } from "./screen";

// The rings of the gather by quality (DOF_QUALITY_*): 1 to 4.
export function dofRingCount(quality: u32): i32 {
    return <i32>min<u32>(quality, <u32>(DOF_TAPS.length - 1)) + 1;
}

// The taps of ring `ring` (1 to dofRingCount) at quality `quality`: the
// quality's DOF_TAPS shared in proportion to each ring's radius (ring k of
// n at k / n of R), rounded, the outermost taking what is left: 8; 5, 11;
// 5, 11, 16; 6, 13, 19, 26.
export function dofRingTaps(quality: u32, ring: i32): i32 {
    const n = dofRingCount(quality);
    const total = DOF_TAPS[n - 1];
    const tri = n * (n + 1) / 2;
    if (ring < n) return (2 * total * ring + tri) / (2 * tri);
    let used = 0;
    for (let k = 1; k < n; k++) used += (2 * total * k + tri) / (2 * tri);
    return total - used;
}

// The point of the shape's outline (radius 1 in its own norm) at `s` of
// the way round (0 to 1, from +x anticlockwise in the picture's x right, y
// down): the box's square of half side 1, the hexagon's corners at 0,
// 60, ..., 300 degrees, the circle.
export function dofShapePoint(shape: u32, s: f32): Vec2 {
    const u = s - Mathf.floor(s);
    if (shape == DOF_SHAPE_BOX) {
        const t = u * 8;
        if (t < 1) return Vec2(1, t);
        if (t < 3) return Vec2(<f32>2 - t, 1);
        if (t < 5) return Vec2(-1, <f32>4 - t);
        if (t < 7) return Vec2(t - <f32>6, -1);
        return Vec2(1, t - <f32>8);
    }
    if (shape == DOF_SHAPE_HEXAGON) {
        const t = u * 6;
        const m = Mathf.floor(t);
        const f = t - m;
        const third = <f32>Math.PI / <f32>3;
        const a = sinCosf(m * third);
        const b = sinCosf((m + 1) * third);
        return Vec2(a.c + (b.c - a.c) * f, a.s + (b.s - a.s) * f);
    }
    const c = sinCosf(<f32>2 * <f32>Math.PI * u);
    return Vec2(c.c, c.s);
}

// Where tap `j` of ring `ring` (of `count` taps) lies on the outline: the
// even rings staggered by half a tap, and turned by `turn` of a tap (the
// jitter's BAYER4 / 16, else 0).
export function dofTapPhase(j: i32, ring: i32, count: i32, turn: f32): f32 {
    const stagger: f32 = (ring & 1) == 1 ? 0 : <f32>0.5;
    return (<f32>j + stagger + turn) / <f32>count;
}

// `out` set to the taps of `shape` at `quality` (x, y pairs in units of
// R, ring by ring from the centre out; the centre not counted): DOF_TAPS
// [quality] pairs. Returns `out`.
export function dofTapOffsets(shape: u32, quality: u32, out: Array<f32>): Array<f32> {
    out.length = 0;
    const n = dofRingCount(quality);
    for (let k = 1; k <= n; k++) {
        const count = dofRingTaps(quality, k);
        const rr = <f32>k / <f32>n;
        for (let j = 0; j < count; j++) {
            const p = dofShapePoint(shape, dofTapPhase(j, k, count, 0));
            out.push(p.x * rr);
            out.push(p.y * rr);
        }
    }
    return out;
}

// How far a tap of circle `cocS` blurs over a centre of circle `cocC`
// (half-size pixels, near negative): a near tap by its own circle (the
// near field blurs over everything); over a near centre, a far tap by its
// own; else the lesser of the tap's and the centre's plus one (a far tap
// never blurs over a sharper surface in front of it).
export function dofTapReach(cocS: f32, cocC: f32): f32 {
    if (cocS < 0) return -cocS;
    if (cocC < 0) return cocS;
    return min<f32>(cocS, cocC + 1);
}

// The weight of a tap of circle `cocS` at distance `dist` (half-size
// pixels) from a centre of circle `cocC`: saturate(reach - dist + 1).
export function dofTapWeight(cocS: f32, cocC: f32, dist: f32): f32 {
    return sat(dofTapReach(cocS, cocC) - dist + 1);
}

// How much of a centre a near tap of circle `cocS` at `dist` covers: 0 for
// a tap that is not near.
export function dofNearCover(cocS: f32, dist: f32): f32 {
    if (cocS >= 0) return 0;
    return sat(-cocS - dist + 1);
}

// The composition's blend of the gather over the sharp colour for a pixel
// of circle `cocFull` (render-size pixels) under a gather whose near
// coverage is `nearCover`: none under 1 pixel, whole from 3, or the near
// field's coverage where that is more (a blurred foreground over a sharp
// background).
export function dofComposeBlend(cocFull: f32, nearCover: f32): f32 {
    return max<f32>(sat(Mathf.abs(cocFull) * <f32>0.5 - <f32>0.5), nearCover);
}

// fs_dof_coc's texel (x, y) of the half-size target, from `colour` (4
// floats a pixel) and `depth` (positive view depths, 0 nothing), both pw x
// ph: the 2 x 2 block's mean rgb and dofCoc at its nearest depth over 2
// (none: `far`), `radius` dofRadiusPx's.
export function dofCocCpu(
    colour: Float32Array, depth: Float32Array, pw: i32, ph: i32, d: DofDesc, radius: f32, far: f32, x: i32, y: i32,
): Vec4 {
    let r: f32 = 0;
    let g: f32 = 0;
    let b: f32 = 0;
    let zn: f32 = f32.MAX_VALUE;
    for (let j = 0; j < 4; j++) {
        const sx = min<i32>(x * 2 + (j & 1), pw - 1);
        const sy = min<i32>(y * 2 + (j >> 1), ph - 1);
        const i = sy * pw + sx;
        r += colour[i * 4];
        g += colour[i * 4 + 1];
        b += colour[i * 4 + 2];
        const z = depth[i];
        if (z > 0) zn = min<f32>(zn, z);
    }
    const z = zn < f32.MAX_VALUE ? zn : far;
    return Vec4(r * 0.25, g * 0.25, b * 0.25, dofCoc(d, z, radius) * 0.5);
}

// fs_dof_gather's texel (x, y) of the half-size `coc` (4 floats a texel,
// w x h: fs_dof_coc's), for `shape` at `quality`, R `radius` (half-size
// pixels), turned by BAYER4 when `jitter` (see the header).
export function dofGatherCpu(
    coc: Float32Array, w: i32, h: i32, shape: u32, quality: u32, radius: f32, jitter: bool, x: i32, y: i32,
): Vec4 {
    const c = (y * w + x) * 4;
    const cc = coc[c + 3];
    let r = coc[c];
    let g = coc[c + 1];
    let b = coc[c + 2];
    let ws: f32 = 1;
    let cover: f32 = 0;
    const turn: f32 = jitter ? <f32>BAYER4[(y & 3) * 4 + (x & 3)] / <f32>16 : 0;
    const n = dofRingCount(quality);
    const pcx = <f32>x + 0.5;
    const pcy = <f32>y + 0.5;
    for (let k = 1; k <= n; k++) {
        const count = dofRingTaps(quality, k);
        const dist = <f32>k / <f32>n * radius;
        for (let j = 0; j < count; j++) {
            const p = dofShapePoint(shape, dofTapPhase(j, k, count, turn));
            const tx = <i32>min<f32>(max<f32>(Mathf.floor(pcx + p.x * dist), 0), <f32>(w - 1));
            const ty = <i32>min<f32>(max<f32>(Mathf.floor(pcy + p.y * dist), 0), <f32>(h - 1));
            const t = (ty * w + tx) * 4;
            const cs = coc[t + 3];
            const wt = dofTapWeight(cs, cc, dist);
            r += coc[t] * wt;
            g += coc[t + 1] * wt;
            b += coc[t + 2] * wt;
            ws += wt;
            cover = max<f32>(cover, dofNearCover(cs, dist));
        }
    }
    return Vec4(r / ws, g / ws, b / ws, cover);
}

// fs_dof_compose's pixel (x, y) of a pw x ph picture: `colour` (4 floats a
// pixel, the sharp picture), `depth`, and the gather `gather` (4 floats a
// texel, gw x gh) sampled bilinearly at the pixel's centre.
export function dofComposeCpu(
    colour: Float32Array, depth: Float32Array, pw: i32, ph: i32, gather: Float32Array, gw: i32, gh: i32, d: DofDesc,
    radius: f32, far: f32, x: i32, y: i32,
): Vec4 {
    const i = y * pw + x;
    const z0 = depth[i];
    const coc = dofCoc(d, z0 > 0 ? z0 : far, radius);
    const g = bilinear(gather, gw, gh, (<f32>x + 0.5) / <f32>pw, (<f32>y + 0.5) / <f32>ph);
    const t = dofComposeBlend(coc, g.w);
    const s = i * 4;
    return Vec4(
        colour[s] + (g.x - colour[s]) * t,
        colour[s + 1] + (g.y - colour[s + 1]) * t,
        colour[s + 2] + (g.z - colour[s + 2]) * t,
        colour[s + 3],
    );
}

function sat(x: f32): f32 {
    return min<f32>(max<f32>(x, 0), 1);
}

// A linear, clamp-to-edge sample of `img` (4 floats a texel, w x h) at UV
// (u, v): the sampler fs_dof_compose reads the gather with.
function bilinear(img: Float32Array, w: i32, h: i32, u: f32, v: f32): Vec4 {
    const sx = u * <f32>w - 0.5;
    const sy = v * <f32>h - 0.5;
    const bx = Mathf.floor(sx);
    const by = Mathf.floor(sy);
    const fx = sx - bx;
    const fy = sy - by;
    let r: f32 = 0;
    let g: f32 = 0;
    let b: f32 = 0;
    let a: f32 = 0;
    for (let j = 0; j < 4; j++) {
        const ox = j & 1;
        const oy = j >> 1;
        const tx = <i32>min<f32>(max<f32>(bx + <f32>ox, 0), <f32>(w - 1));
        const ty = <i32>min<f32>(max<f32>(by + <f32>oy, 0), <f32>(h - 1));
        const wt = (ox == 1 ? fx : <f32>1 - fx) * (oy == 1 ? fy : <f32>1 - fy);
        const o = (ty * w + tx) * 4;
        r += img[o] * wt;
        g += img[o + 1] * wt;
        b += img[o + 2] * wt;
        a += img[o + 3] * wt;
    }
    return Vec4(r, g, b, a);
}
