// AMD FidelityFX Super Resolution 1.0 (FSR 1), the spatial upscale of
// Godot's Viewport scaling_3d_mode FSR, and the tools' bilinear stretch
// (engine/src/render/gpu/fsr.as runs them; docs/engine/PERFORMANCE.md,
// "Render scale"). Ported from AMD's ffx_fsr1.h (MIT licence: Copyright (c)
// 2021 Advanced Micro Devices, Inc.; THIRD_PARTY_NOTICES.md), its 32-bit
// paths FsrEasuF and FsrRcasF, as fragment passes (WebGL 2 has no compute):
//
//   fs_easu     edge adaptive spatial upsampling: each output pixel from
//               the 12 input texels around it (the 2 x 2 quad it falls in
//               and the 8 around the quad), weighted by a lanczos-2-like
//               kernel stretched along the local edge, then clamped to the
//               quad's minimum and maximum (no ringing)
//   fs_rcas     robust contrast adaptive sharpening: each pixel pushed
//               away from its 4 neighbours by a lobe the neighbourhood's
//               own range limits, so that nothing clips; U.rcas.x is
//               exp2(-sharpness) (Godot's fsr_sharpness: 0 the sharpest,
//               2 the softest)
//   fs_stretch  the bilinear stretch (Godot's scaling_3d_mode bilinear in
//               the tools, which have no image filter to stretch with)
//
// Every entry draws the full-screen triangle with group 0 below. The
// pictures are the renderer's finished ones (POST_FORMAT: straight-alpha
// sRGB bytes), which is the perceptual space FSR 1 is made for (Godot runs
// it after the tone map too). Alpha is not upscaled by the kernel: EASU
// interpolates it bilinearly, RCAS keeps the pixel's own.
//
// Where ffx_fsr1.h uses its bit-trick approximations of a reciprocal and a
// reciprocal square root (APrxLoRcpF1, APrxLoRsqF1, APrxMedRcpF1), this
// port divides exactly (a zero denominator, whose numerator is 0 there too,
// gives 0): the pictures differ from AMD's by the approximations' error at
// most, and are the same on every backend.

struct FsrU {                    // 48 bytes (gpu/fsr.as FSR_UNIFORM_SIZE)
    // xy input pixels an output pixel (ffx's con0.xy), zw the offset of an
    // output pixel's centre in input pixels (con0.zw: 0.5 * xy - 0.5).
    con0: vec4<f32>,
    // xy the input size, zw the output size, in pixels.
    size: vec4<f32>,
    // x RCAS's sharpness, exp2(-fsr_sharpness); yzw 0.
    rcas: vec4<f32>,
};

@group(0) @binding(0) var<uniform> U: FsrU;
@group(0) @binding(1) var t_src: texture_2d<f32>;
@group(0) @binding(2) var s_linear: sampler;   // linear, linear, clamp to edge

@vertex
fn vs_fsr(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    var pts = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    return vec4<f32>(pts[vi], 0.0, 1.0);
}

// The source's texel at `p`, clamped to its `size` (ffx samples with clamp
// to edge): EASU's source is the input (U.size.xy), RCAS's EASU's output
// (U.size.zw).
fn texel(p: vec2<i32>, size: vec2<f32>) -> vec4<f32> {
    let hi = vec2<i32>(size) - vec2<i32>(1, 1);
    return textureLoad(t_src, clamp(p, vec2<i32>(0, 0), hi), 0);
}

// ffx's luma times 2 (b * 0.5 + (r * 0.5 + g)).
fn luma2(c: vec3<f32>) -> f32 {
    return c.b * 0.5 + (c.r * 0.5 + c.g);
}

// 1 / x, 0 for x = 0 (see the header).
fn rcp_or_zero(x: f32) -> f32 {
    return select(0.0, 1.0 / x, x != 0.0);
}

// --- EASU --------------------------------------------------------------------

// ffx's FsrEasuSetF: the direction and length of one of the 2 x 2 quad's
// texels (`c`, with `a` above it, `b` left, `d` right, `e` below), weighted
// by its bilinear weight `w`, added to `dl` (xy the direction, z the length).
fn easu_set(dl: vec3<f32>, w: f32, la: f32, lb: f32, lc: f32, ld: f32, le: f32) -> vec3<f32> {
    let dc = ld - lc;
    let cb = lc - lb;
    var lenX = rcp_or_zero(max(abs(dc), abs(cb)));
    let dirX = ld - lb;
    lenX = clamp(abs(dirX) * lenX, 0.0, 1.0);
    lenX *= lenX;
    let ec = le - lc;
    let ca = lc - la;
    var lenY = rcp_or_zero(max(abs(ec), abs(ca)));
    let dirY = le - la;
    lenY = clamp(abs(dirY) * lenY, 0.0, 1.0);
    lenY *= lenY;
    return dl + vec3<f32>(dirX * w, dirY * w, lenX * w + lenY * w);
}

// ffx's FsrEasuTapF: one texel's weight at offset `off` from the output
// pixel (input pixels), the kernel rotated to `dir`, stretched by `len`,
// its negative lobe at `lob`, its window clipped at `clp`.
fn easu_weight(off: vec2<f32>, dir: vec2<f32>, len: vec2<f32>, lob: f32, clp: f32) -> f32 {
    var v = vec2<f32>(off.x * dir.x + off.y * dir.y, off.x * (-dir.y) + off.y * dir.x);
    v *= len;
    let d2 = min(v.x * v.x + v.y * v.y, clp);
    var wB = (2.0 / 5.0) * d2 - 1.0;
    var wA = lob * d2 - 1.0;
    wB *= wB;
    wA *= wA;
    wB = (25.0 / 16.0) * wB - (25.0 / 16.0 - 1.0);
    return wB * wA;
}

@fragment
fn fs_easu(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    // The output pixel's centre in input pixels (ffx: ip * con0.xy +
    // con0.zw, ip the pixel's integer position), its quad's top-left texel
    // f and the fraction past it.
    let ip = floor(pos.xy);
    var pp = ip * U.con0.xy + U.con0.zw;
    let fp = floor(pp);
    pp -= fp;
    let o = vec2<i32>(fp);
    //    b c
    //  e f g h
    //  i j k l
    //    n o
    let b = texel(o + vec2<i32>(0, -1), U.size.xy);
    let c = texel(o + vec2<i32>(1, -1), U.size.xy);
    let e = texel(o + vec2<i32>(-1, 0), U.size.xy);
    let f = texel(o, U.size.xy);
    let g = texel(o + vec2<i32>(1, 0), U.size.xy);
    let h = texel(o + vec2<i32>(2, 0), U.size.xy);
    let i = texel(o + vec2<i32>(-1, 1), U.size.xy);
    let j = texel(o + vec2<i32>(0, 1), U.size.xy);
    let k = texel(o + vec2<i32>(1, 1), U.size.xy);
    let l = texel(o + vec2<i32>(2, 1), U.size.xy);
    let n = texel(o + vec2<i32>(0, 2), U.size.xy);
    let oo = texel(o + vec2<i32>(1, 2), U.size.xy);
    let bL = luma2(b.rgb);
    let cL = luma2(c.rgb);
    let eL = luma2(e.rgb);
    let fL = luma2(f.rgb);
    let gL = luma2(g.rgb);
    let hL = luma2(h.rgb);
    let iL = luma2(i.rgb);
    let jL = luma2(j.rgb);
    let kL = luma2(k.rgb);
    let lL = luma2(l.rgb);
    let nL = luma2(n.rgb);
    let oL = luma2(oo.rgb);
    // The direction and length, by the quad's bilinear weights:
    //  s t     (f g)
    //  u v     (j k)
    var dl = vec3<f32>(0.0);
    dl = easu_set(dl, (1.0 - pp.x) * (1.0 - pp.y), bL, eL, fL, gL, jL);
    dl = easu_set(dl, pp.x * (1.0 - pp.y), cL, fL, gL, hL, kL);
    dl = easu_set(dl, (1.0 - pp.x) * pp.y, fL, iL, jL, kL, nL);
    dl = easu_set(dl, pp.x * pp.y, gL, jL, kL, lL, oL);
    var dir = dl.xy;
    var len = dl.z;
    // Normalised, and cleaned up close to 0.
    let dir2 = dir * dir;
    var dirR = dir2.x + dir2.y;
    let zro = dirR < (1.0 / 32768.0);
    dirR = select(inverseSqrt(dirR), 1.0, zro);
    dir.x = select(dir.x, 1.0, zro);
    dir *= dirR;
    // From 0..2 to 0..1, shaped by a square.
    len = len * 0.5;
    len *= len;
    // The kernel stretched from 1 (across or along) to sqrt(2) (diagonal).
    let stretch = (dir.x * dir.x + dir.y * dir.y) / max(abs(dir.x), abs(dir.y));
    let len2 = vec2<f32>(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
    // The window, from sqrt(2) to a little past 2 with the edge.
    let lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
    let clp = 1.0 / lob;
    // The 12 taps, in ffx's order.
    var aC = vec3<f32>(0.0);
    var aW = 0.0;
    var w = easu_weight(vec2<f32>(0.0, -1.0) - pp, dir, len2, lob, clp);
    aC += b.rgb * w;
    aW += w;
    w = easu_weight(vec2<f32>(1.0, -1.0) - pp, dir, len2, lob, clp);
    aC += c.rgb * w;
    aW += w;
    w = easu_weight(vec2<f32>(-1.0, 1.0) - pp, dir, len2, lob, clp);
    aC += i.rgb * w;
    aW += w;
    w = easu_weight(vec2<f32>(0.0, 1.0) - pp, dir, len2, lob, clp);
    aC += j.rgb * w;
    aW += w;
    w = easu_weight(vec2<f32>(0.0, 0.0) - pp, dir, len2, lob, clp);
    aC += f.rgb * w;
    aW += w;
    w = easu_weight(vec2<f32>(-1.0, 0.0) - pp, dir, len2, lob, clp);
    aC += e.rgb * w;
    aW += w;
    w = easu_weight(vec2<f32>(1.0, 1.0) - pp, dir, len2, lob, clp);
    aC += k.rgb * w;
    aW += w;
    w = easu_weight(vec2<f32>(2.0, 1.0) - pp, dir, len2, lob, clp);
    aC += l.rgb * w;
    aW += w;
    w = easu_weight(vec2<f32>(2.0, 0.0) - pp, dir, len2, lob, clp);
    aC += h.rgb * w;
    aW += w;
    w = easu_weight(vec2<f32>(1.0, 0.0) - pp, dir, len2, lob, clp);
    aC += g.rgb * w;
    aW += w;
    w = easu_weight(vec2<f32>(1.0, 2.0) - pp, dir, len2, lob, clp);
    aC += oo.rgb * w;
    aW += w;
    w = easu_weight(vec2<f32>(0.0, 2.0) - pp, dir, len2, lob, clp);
    aC += n.rgb * w;
    aW += w;
    // Normalised and de-rung by the quad's range.
    let min4 = min(min(f.rgb, g.rgb), min(j.rgb, k.rgb));
    let max4 = max(max(f.rgb, g.rgb), max(j.rgb, k.rgb));
    let rgb = min(max4, max(min4, aC * rcp_or_zero(aW)));
    let a = mix(mix(f.a, g.a, pp.x), mix(j.a, k.a, pp.x), pp.y);
    return vec4<f32>(rgb, a);
}

// --- RCAS --------------------------------------------------------------------

// ffx's FSR_RCAS_LIMIT: the lobe's limit, so that sharpening never clips.
const RCAS_LIMIT: f32 = 0.25 - (1.0 / 16.0);

@fragment
fn fs_rcas(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    //    b
    //  d e f
    //    h
    let p = vec2<i32>(floor(pos.xy));
    let b = texel(p + vec2<i32>(0, -1), U.size.zw).rgb;
    let d = texel(p + vec2<i32>(-1, 0), U.size.zw).rgb;
    let ee = texel(p, U.size.zw);
    let e = ee.rgb;
    let f = texel(p + vec2<i32>(1, 0), U.size.zw).rgb;
    let h = texel(p + vec2<i32>(0, 1), U.size.zw).rgb;
    // The ring's minimum and maximum.
    let mn4 = min(min(min(b, d), f), h);
    let mx4 = max(max(max(b, d), f), h);
    // The limiters (ffx's peak range: 1 and -4).
    let hitMin = min(mn4, e) * vec3<f32>(rcp_or_zero(4.0 * mx4.r), rcp_or_zero(4.0 * mx4.g), rcp_or_zero(4.0 * mx4.b));
    let dn = 4.0 * mn4 - vec3<f32>(4.0);
    let hitMax = (vec3<f32>(1.0) - max(mx4, e)) * vec3<f32>(rcp_or_zero(dn.r), rcp_or_zero(dn.g), rcp_or_zero(dn.b));
    let lobeRGB = max(-hitMin, hitMax);
    let lobe = max(-RCAS_LIMIT, min(max(max(lobeRGB.r, lobeRGB.g), lobeRGB.b), 0.0)) * U.rcas.x;
    // The resolve.
    let rcpL = 1.0 / (4.0 * lobe + 1.0);
    let rgb = (lobe * b + lobe * d + lobe * h + lobe * f + e) * rcpL;
    return vec4<f32>(rgb, ee.a);
}

// --- the bilinear stretch ----------------------------------------------------

@fragment
fn fs_stretch(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    // The output pixel's centre over the output size, the same place on the
    // input (texel centres at half-integers, as the image filter has them).
    let uv = pos.xy / U.size.zw;
    return textureSampleLevel(t_src, s_linear, uv, 0.0);
}
