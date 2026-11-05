// Post-processing (milestone 12): SSAO, the glow and the final pass (tone
// map after the glow, the glow's blend, the adjustments). shared/src/render/
// post.as plans the passes, builds each one's PostU block (layouts.as
// `PostUniform`) and holds the CPU reference of every formula here (its
// header and the spec's rules); gpu/renderer.as runs them. Every entry is a
// full-screen triangle with the one group 0 below; a pass binds 1 x 1
// dummies where it reads nothing. In frame order:
//
//   fs_ssao         the normal-depth texture (surface.wgsl fs_normal_depth)
//                   into occlusion, AO_FORMAT at the render size (with
//                   POST_SSAO_HALF at half of it each side)
//   fs_ssao_blur    that occlusion blurred within a surface, at the render
//                   size; the main pass reads it (surface.wgsl t_ao)
//   fs_glow_bright  the resolved HDR colour box-filtered to glow level 1,
//                   exposed and thresholded
//   fs_glow_blur_h  one glow level: Godot's separable Gaussian, across (of
//   fs_glow_blur_v  the level above, halved, after level 1), then down
//   fs_post         the finished picture as sRGB values, the overlay layer
//                   (grid, edges, points, gizmos) laid over it, which the
//                   outline pass reads as already encoded

const POST_TONEMAP: u32 = 1u;     // layouts.as POST_*
const POST_GLOW: u32 = 2u;
const POST_ADJUST: u32 = 4u;
const POST_DOWNSAMPLE: u32 = 8u;
const POST_OVERLAY: u32 = 16u;
const POST_STRAIGHT: u32 = 32u;
const POST_SSAO_HALF: u32 = 64u;

const TONEMAP_LINEAR: u32 = 0u;   // frame.as TONEMAP_*
const TONEMAP_REINHARD: u32 = 1u;
const TONEMAP_FILMIC: u32 = 2u;
const TONEMAP_ACES: u32 = 3u;
const TONEMAP_AGX: u32 = 4u;

const GLOW_BLEND_ADDITIVE: u32 = 0u;   // frame.as GLOW_BLEND_*
const GLOW_BLEND_SCREEN: u32 = 1u;
const GLOW_BLEND_SOFTLIGHT: u32 = 2u;
const GLOW_BLEND_REPLACE: u32 = 3u;
const GLOW_BLEND_MIX: u32 = 4u;

// post.as SSAO_SAMPLES, SSAO_TURNS and SSAO_DETAIL_RADIUS: the taps of one
// estimate, the turns of their spiral, the detail estimate's radius as a
// fraction of ssao_radius.
const SSAO_SAMPLES: i32 = 12;
const SSAO_TURNS: f32 = 7.0;
const SSAO_DETAIL_RADIUS: f32 = 0.25;
// post.as SSAO_DEPTH_BIAS: a tap must rise above p's tangent plane by more
// than this fraction of p's depth to count (the half-float depth's
// rounding, twice: see ssao_estimate).
const SSAO_DEPTH_BIAS: f32 = 0.0009765625;

const PI: f32 = 3.14159265;

struct PostU {                    // 288 bytes (PostUniform)
    target_size: vec4<f32>,       // xy the target's size in texels, zw their inverses
    source_size: vec4<f32>,       // xy t_src's size in texels, zw their inverses
    flags: vec4<u32>,             // x POST_* bits, y tone map, z glow blend mode, w SSAA factor
    tone: vec4<f32>,              // x exposure, y white, z glow_mix, w glow_strength
    glow: vec4<f32>,              // x hdr threshold, y hdr scale, z luminance cap, w bloom
    levels_low: vec4<f32>,        // glow level weights 1-4
    levels_high: vec4<f32>,       // glow level weights 5-7, w unused
    bcs: vec4<f32>,               // x brightness, y contrast, z saturation, w unused
    ssao: vec4<f32>,              // x radius, y intensity, z power, w detail
    ssao2: vec4<f32>,             // x horizon, y sharpness, z pixels per unit at depth 1, w 1 if ortho
    inv_proj: mat4x4<f32>,        // clip to view
    proj: mat4x4<f32>,            // view to clip
};

@group(0) @binding(0) var<uniform> U: PostU;
@group(0) @binding(1) var t_src: texture_2d<f32>;
@group(0) @binding(2) var t_aux: texture_2d<f32>;
// The glow levels: level k is mip k - 1 of one texture (renderer.as
// `postChain`), as Godot keeps them, so the group holds three textures
// however many levels are drawn (the host takes at most 8 per group).
@group(0) @binding(3) var t_glow: texture_2d<f32>;
@group(0) @binding(4) var s_linear: sampler;   // linear, linear, mip nearest, clamp to edge

@vertex
fn vs_full(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    var pts = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    return vec4<f32>(pts[vi], 0.0, 1.0);
}

fn sat3(c: vec3<f32>) -> vec3<f32> {
    return clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
}

// The exact sRGB curve (surface.wgsl's linear_to_srgb, post.as's).
fn linear_to_srgb(c: vec3<f32>) -> vec3<f32> {
    let lo = c * 12.92;
    let hi = 1.055 * pow(c, vec3<f32>(1.0 / 2.4)) - vec3<f32>(0.055);
    return select(hi, lo, c <= vec3<f32>(0.0031308));
}

// Its inverse (the overlay is blended in linear space, see fs_post).
fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c / 12.92;
    let hi = pow((c + vec3<f32>(0.055)) / 1.055, vec3<f32>(2.4));
    return select(hi, lo, c <= vec3<f32>(0.04045));
}

// ---------------------------------------------------------------- tone map

// Godot 4's tone curves, the same text as surface.wgsl's (the tone map runs
// there without glow, here with it).
// ---- BEGIN tone curves ----
fn filmic_curve(x: vec3<f32>) -> vec3<f32> {
    // Godot's tonemap_filmic: exposure bias 2 baked into A and B.
    let a = 0.22 * 4.0;
    let b = 0.30 * 2.0;
    let c = 0.10;
    let d = 0.20;
    let e = 0.01;
    let f = 0.30;
    return (x * (a * x + vec3<f32>(c * b)) + vec3<f32>(d * e)) / (x * (a * x + vec3<f32>(b)) + vec3<f32>(d * f))
        - vec3<f32>(e / f);
}

// Godot 4's tonemap_aces (Stephen Hill's fit of the ACES RRT and ODT, with
// an exposure bias of 1.8) of an exposed colour `c`, divided by the curve
// at `white` so that `white` maps to 1.
fn aces_curve(c: vec3<f32>, white: f32) -> vec3<f32> {
    let k = 1.8;
    let x = vec3<f32>(
        k * dot(vec3<f32>(0.59719, 0.35458, 0.04823), c),
        k * dot(vec3<f32>(0.07600, 0.90834, 0.01566), c),
        k * dot(vec3<f32>(0.02840, 0.13383, 0.83777), c));
    let t = (x * (x + vec3<f32>(0.0245786)) - vec3<f32>(0.000090537))
        / (x * (0.983729 * x + vec3<f32>(0.432951)) + vec3<f32>(0.238081));
    let o = vec3<f32>(
        dot(vec3<f32>(1.60475, -0.53108, -0.07367), t),
        dot(vec3<f32>(-0.10208, 1.10813, -0.00605), t),
        dot(vec3<f32>(-0.00327, -0.07276, 1.07602), t));
    let w = k * white;
    let wt = (w * (w + 0.0245786) - 0.000090537) / (w * (0.983729 * w + 0.432951) + 0.238081);
    return o / wt;
}

// Godot 4.4's tonemap_agx (an approximation of EaryChow's AgX, Blender's):
// the colour kept at 2e-10 at least (so the log below is finite), the
// combined sRGB to Rec. 2020 and AgX inset matrix, a log2 encoding between
// -12.4739311883324 and 4.02606881166759 stops (middle grey 0.18 at
// -10 .. +6.5 stops), the 6th-order fit of the AgX sigmoid, back to linear
// with a 2.4 power, then the combined outset and Rec. 2020 to sRGB matrix.
// It takes no white point, and may return negatives (clamped before the
// encode, as Godot's are). The matrices are Godot's GLSL mat3 literals, by
// columns in WGSL as in GLSL. pow of 0 is undefined in WGSL, so its base is
// kept at 1e-10 at least (1e-24 after the power: 0 in any target).
fn agx_curve(c: vec3<f32>) -> vec3<f32> {
    let inset = mat3x3<f32>(
        0.54490813676363087053, 0.14044005884001287035, 0.088827411851915368603,
        0.37377945959812267119, 0.75410959864013760045, 0.17887712465043811023,
        0.081384976686407536266, 0.10543358536857773485, 0.73224999956948382528);
    let outset = mat3x3<f32>(
        1.9645509602733325934, -0.29932243390911083839, -0.16436833806080403409,
        -0.85585845117807513559, 1.3264510741502356555, -0.23822464068860595117,
        -0.10886710826831608324, -0.027084020983874825605, 1.402665347143271889);
    let min_ev = -12.4739311883324;
    let max_ev = 4.02606881166759;
    var v = inset * max(c, vec3<f32>(2e-10));
    v = (clamp(log2(v), vec3<f32>(min_ev), vec3<f32>(max_ev)) - vec3<f32>(min_ev)) / (max_ev - min_ev);
    let x2 = v * v;
    let x4 = x2 * x2;
    let p = 0.021 * v + 4.0111 * x2 - 25.682 * x2 * v + 70.359 * x4 - 74.778 * x4 * v + 27.069 * x4 * x2;
    return outset * pow(max(p, vec3<f32>(1e-10)), vec3<f32>(2.4));
}
// ---- END tone curves ----

// post.as `toneCurve`: tone curve `mode` of an exposed colour whose
// negatives are already 0 (surface.wgsl `tonemap`'s arithmetic).
fn tone_curve(c: vec3<f32>, mode: u32, white: f32) -> vec3<f32> {
    if (mode == TONEMAP_REINHARD) {
        return (white * c + c) / (c * white + vec3<f32>(white));
    }
    if (mode == TONEMAP_FILMIC) {
        return filmic_curve(c) / filmic_curve(vec3<f32>(white));
    }
    if (mode == TONEMAP_ACES) {
        return aces_curve(c, white);
    }
    if (mode == TONEMAP_AGX) {
        return agx_curve(c);
    }
    return c;
}

// ---------------------------------------------------------------- SSAO

// post.as `ssaoAngle`: the angle pixel `q` turns its spiral by, from the
// 4 x 4 Bayer matrix (BAYER4), so 16 neighbours sample 16 rotations and
// the blur over one period averages them.
fn ssao_angle(q: vec2<i32>) -> f32 {
    var bayer = array<u32, 16>(0u, 8u, 2u, 10u, 12u, 4u, 14u, 6u, 3u, 11u, 1u, 9u, 15u, 7u, 13u, 5u);
    let i = (q.y & 3) * 4 + (q.x & 3);
    return 2.0 * PI * f32(bayer[i]) / 16.0;
}

// The near plane (clip depth 0) in view space as a function of NDC xy:
// `a0 + x ax + y ay`. It is affine because the inverse projection's w
// does not depend on NDC xy at a fixed depth, for the camera's
// perspective and orthographic projections alike (camera.as
// `projectionMatrix`); so three products of the inverse projection per
// fragment stand for two per tap.
struct Near {
    a0: vec3<f32>,
    ax: vec3<f32>,
    ay: vec3<f32>,
};

fn near_plane() -> Near {
    let c = U.inv_proj * vec4<f32>(0.0, 0.0, 0.0, 1.0);
    let x = U.inv_proj * vec4<f32>(1.0, 0.0, 0.0, 1.0);
    let y = U.inv_proj * vec4<f32>(0.0, 1.0, 0.0, 1.0);
    var n: Near;
    n.a0 = c.xyz / c.w;
    n.ax = x.xyz / x.w - n.a0;
    n.ay = y.xyz / y.w - n.a0;
    return n;
}

// The view-space point at view depth `d` under target position `p` (in
// texels, y down): on the eye ray through p's point `a` of the near plane,
// which starts at the eye in a perspective view (so the point is `a`
// scaled to depth d) and runs straight along -z in an orthographic one.
fn view_pos(np: Near, p: vec2<f32>, d: f32) -> vec3<f32> {
    let ndc = vec2<f32>(2.0 * p.x * U.target_size.z - 1.0, 1.0 - 2.0 * p.y * U.target_size.w);
    let a = np.a0 + ndc.x * np.ax + ndc.y * np.ay;
    if (U.ssao2.w > 0.5) {
        return vec3<f32>(a.xy, -d);
    }
    return a * (d / -a.z);
}

// One scalable ambient obscurance estimate (McGuire, Mara and Luebke 2012)
// at the texel centred on `pc`, whose view position is `p`, normal `n` and
// depth `depth`, over a world radius `radius`: SSAO_SAMPLES taps along a
// spiral of SSAO_TURNS turns out to the radius in pixels, turned by
// `angle`. A tap counts when it lies above the tangent plane by more than
// ssao_horizon (the cosine of its elevation, as a fraction), fading out
// with its squared distance up to the radius; a tap outside the picture
// or on the background counts nothing, and so does the height the depths'
// rounding can make up (SSAO_DEPTH_BIAS). 1 unoccluded. A radius under a
// pixel is none.
fn ssao_estimate(np: Near, pc: vec2<f32>, p: vec3<f32>, n: vec3<f32>, depth: f32, radius: f32, angle: f32) -> f32 {
    let r_px = radius * U.ssao2.z / select(depth, 1.0, U.ssao2.w > 0.5);
    if (r_px < 1.0) {
        return 1.0;
    }
    let size = vec2<i32>(U.target_size.xy);
    let count = f32(SSAO_SAMPLES);
    let r2 = radius * radius;
    // The depths are half floats (NORMAL_DEPTH_FORMAT), each within
    // depth / 2048 of the true one: a tap on p's own plane can then seem up
    // to depth / 1024 above it, which near p is more than ssao_horizon and
    // would draw the rounding steps on every flat surface. That height is
    // not counted.
    let bias = depth * SSAO_DEPTH_BIAS;
    var sum = 0.0;
    for (var i = 0; i < SSAO_SAMPLES; i++) {
        let alpha = (f32(i) + 0.5) / count;
        let theta = 2.0 * PI * alpha * SSAO_TURNS + angle;
        let s = pc + r_px * alpha * vec2<f32>(cos(theta), sin(theta));
        let si = vec2<i32>(floor(s));
        if (si.x < 0 || si.y < 0 || si.x >= size.x || si.y >= size.y) {
            continue;
        }
        let d = textureLoad(t_src, si, 0).a;
        if (d <= 0.0) {
            continue;
        }
        // The tap's depth is its texel's, so its position is that texel
        // centre's.
        let v = view_pos(np, vec2<f32>(si) + vec2<f32>(0.5), d) - p;
        let vv = dot(v, v);
        sum += max(1.0 - vv / r2, 0.0) * max((dot(v, n) - bias) / sqrt(vv + 1e-4) - U.ssao2.x, 0.0);
    }
    // pow of 0 is undefined in WGSL: the base is kept at 1e-6 at least.
    return pow(max(clamp(1.0 - U.ssao.y * sum / count, 0.0, 1.0), 1e-6), U.ssao.z);
}

// The occlusion (r, g and b; 1 unoccluded) of the normal-depth texture in
// t_src: the estimate at ssao_radius times, mixed in by ssao_detail, a
// second one at SSAO_DETAIL_RADIUS of it for the small creases.
//
// With POST_SSAO_HALF (milestone 67, Godot's ssao/half_size) the target is
// half the render size each side: texel h estimates at render texel 2h,
// the top left of the four it stands for, its spiral turned by h's place
// in the Bayer period (so that the blur's 4 x 4 texels still average one);
// everything else is the full size's, in render texels (k is 1 there, and
// the arithmetic the same).
@fragment
fn fs_ssao(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let h = vec2<i32>(floor(pos.xy));
    let k = select(1, 2, (U.flags.x & POST_SSAO_HALF) != 0u);
    let q = h * k;
    let nd = textureLoad(t_src, q, 0);
    if (nd.a <= 0.0) {
        return vec4<f32>(1.0);
    }
    let pc = vec2<f32>(q) + vec2<f32>(0.5);
    let np = near_plane();
    let p = view_pos(np, pc, nd.a);
    let n = normalize(nd.xyz);
    let angle = ssao_angle(h);
    var ao = ssao_estimate(np, pc, p, n, nd.a, U.ssao.x, angle);
    if (U.ssao.w != 0.0) {
        ao *= mix(1.0, ssao_estimate(np, pc, p, n, nd.a, U.ssao.x * SSAO_DETAIL_RADIUS, angle), U.ssao.w);
    }
    return vec4<f32>(ao, ao, ao, 1.0);
}

// t_src's occlusion blurred within a surface (t_aux: the normal-depth
// texture): the 4 x 4 texels from -2 to +1 around q (one Bayer period, so
// the spiral's rotations average out), each weighted by how closely its
// normal matches q's (to the 4th power) and by its distance from q's
// tangent plane, relative to q's depth, against a tolerance that
// ssao_sharpness narrows: an edge between surfaces leaves each side's
// occlusion its own. The background stays 1.
//
// With POST_SSAO_HALF the occlusion is half the render size (fs_ssao):
// render texel q blurs the 4 x 4 half-size texels from -2 to +1 around
// its own (q / 2), each standing at the render texel it was estimated at
// (twice its place), against q's normal and plane: a joint bilateral
// upscale, as Godot brings its half-size SSAO back up along the edges.
@fragment
fn fs_ssao_blur(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let q = vec2<i32>(floor(pos.xy));
    let nd = textureLoad(t_aux, q, 0);
    if (nd.a <= 0.0) {
        return vec4<f32>(1.0);
    }
    let n = normalize(nd.xyz);
    let np = near_plane();
    let p = view_pos(np, vec2<f32>(q) + vec2<f32>(0.5), nd.a);
    let tol = (0.1 * (1.0 - U.ssao2.y) + 0.002) * nd.a;
    let k = select(1, 2, (U.flags.x & POST_SSAO_HALF) != 0u);
    let size = (vec2<i32>(U.target_size.xy) + vec2<i32>(k - 1)) / k;
    let h = q / k;
    var sum = 0.0;
    var weights = 0.0;
    for (var dy = -2; dy <= 1; dy++) {
        for (var dx = -2; dx <= 1; dx++) {
            let t = h + vec2<i32>(dx, dy);
            if (t.x < 0 || t.y < 0 || t.x >= size.x || t.y >= size.y) {
                continue;
            }
            let m = textureLoad(t_aux, t * k, 0);
            if (m.a <= 0.0) {
                continue;
            }
            let c = max(dot(n, normalize(m.xyz)), 0.0);
            let c2 = c * c;
            let plane = abs(dot(n, view_pos(np, vec2<f32>(t * k) + vec2<f32>(0.5), m.a) - p));
            let w = c2 * c2 * max(0.0, 1.0 - plane / tol);
            sum += w * textureLoad(t_src, t, 0).r;
            weights += w;
        }
    }
    var ao = textureLoad(t_src, h, 0).r;
    if (weights >= 1e-4) {
        ao = sum / weights;
    }
    return vec4<f32>(ao, ao, ao, 1.0);
}

// ---------------------------------------------------------------- glow

// Glow level 1's source (Godot's glow first pass, post.as `glowBright`):
// the mean of t_src's (the resolved HDR colour's) 2 SSAA x 2 SSAA texels
// under texel q, clipped to the source, exposed; then kept by how far its
// brightest channel is above glow_hdr_threshold (a smoothstep over
// glow_hdr_scale), at least glow_bloom of it, capped at
// glow_hdr_luminance_cap.
@fragment
fn fs_glow_bright(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let q = vec2<i32>(floor(pos.xy));
    let b = 2 * i32(max(U.flags.w, 1u));
    let lo = q * b;
    let hi = min(lo + vec2<i32>(b), vec2<i32>(U.source_size.xy));
    var sum = vec3<f32>(0.0);
    for (var y = lo.y; y < hi.y; y++) {
        for (var x = lo.x; x < hi.x; x++) {
            sum += textureLoad(t_src, vec2<i32>(x, y), 0).rgb;
        }
    }
    let count = f32(max((hi.x - lo.x) * (hi.y - lo.y), 1));
    var c = sum / count * U.tone.x;
    let l = max(c.r, max(c.g, c.b));
    let keep = max(smoothstep(U.glow.x, U.glow.x + U.glow.y, l), U.glow.w);
    c = min(c * keep, vec3<f32>(U.glow.z));
    return vec4<f32>(c, 1.0);
}

// Godot's glow blur weights (post.as GLOW_WEIGHTS_H, GLOW_WEIGHTS_V): the
// taps at 0, 1, 2 and 3 texels across, 0, 1 and 2 down.
fn glow_weight_h(k: i32) -> f32 {
    var w = array<f32, 4>(0.174938, 0.165569, 0.140367, 0.106595);
    return w[k];
}

fn glow_weight_v(k: i32) -> f32 {
    var w = array<f32, 3>(0.288713, 0.233062, 0.122581);
    return w[k];
}

// One level across: 7 bilinear taps half a destination texel apart, times
// glow_strength. Godot's horizontal pass reads a source twice the size and
// spaces its taps one source texel apart; were they a destination texel
// apart, each level would blur twice as far across as Godot's (a spread
// of 1.84 texels against 0.92; 1.20 down in both) and a lamp's halo would
// be wider than it is tall. After level 1 the source is the level above,
// twice as large (POST_DOWNSAMPLE), so the taps are one of its texels
// apart and the centre tap is the 2 x 2 box of the source texels under a
// destination texel: halving and blurring in one draw. Level 1 reads the
// bright pass, already at its size, at the spacing Godot's first pass
// uses on the full picture.
@fragment
fn fs_glow_blur_h(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = pos.xy * U.target_size.zw;
    var c = textureSampleLevel(t_src, s_linear, uv, 0.0).rgb * glow_weight_h(0);
    for (var k = 1; k <= 3; k++) {
        let o = vec2<f32>(f32(k) * 0.5 * U.target_size.z, 0.0);
        c += (textureSampleLevel(t_src, s_linear, uv + o, 0.0).rgb
            + textureSampleLevel(t_src, s_linear, uv - o, 0.0).rgb) * glow_weight_h(k);
    }
    return vec4<f32>(c * U.tone.w, 1.0);
}

// The same level down: 5 taps a texel apart.
@fragment
fn fs_glow_blur_v(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = pos.xy * U.target_size.zw;
    var c = textureSampleLevel(t_src, s_linear, uv, 0.0).rgb * glow_weight_v(0);
    for (var k = 1; k <= 2; k++) {
        let o = vec2<f32>(0.0, f32(k) * U.target_size.w);
        c += (textureSampleLevel(t_src, s_linear, uv + o, 0.0).rgb
            + textureSampleLevel(t_src, s_linear, uv - o, 0.0).rgb) * glow_weight_v(k);
    }
    return vec4<f32>(c, 1.0);
}

// ---------------------------------------------------------------- final

// Godot's apply_glow for the blend modes other than mix (post.as
// `glowBlend`): `c` the picture's and `g` the glow's sRGB values.
fn glow_blend(c: vec3<f32>, g: vec3<f32>, mode: u32) -> vec3<f32> {
    if (mode == GLOW_BLEND_ADDITIVE) {
        return c + g;
    }
    if (mode == GLOW_BLEND_SCREEN) {
        let a = sat3(c);
        let b = sat3(g);
        return max(a + b - a * b, vec3<f32>(0.0));
    }
    if (mode == GLOW_BLEND_SOFTLIGHT) {
        let b = sat3(c);
        let h = g * 0.5 + vec3<f32>(0.5);
        let dark = b - (vec3<f32>(1.0) - 2.0 * h) * b * (vec3<f32>(1.0) - b);
        let low = b + (2.0 * h - vec3<f32>(1.0)) * (4.0 * b * (4.0 * b + vec3<f32>(1.0)) * (b - vec3<f32>(1.0)) + 7.0 * b);
        let high = b + (2.0 * h - vec3<f32>(1.0)) * (sqrt(b) - b);
        return select(select(high, low, b <= vec3<f32>(0.25)), dark, h <= vec3<f32>(0.5));
    }
    if (mode == GLOW_BLEND_REPLACE) {
        return g;
    }
    return c;
}

// Godot's apply_bcs on an sRGB colour (post.as `applyBcs`).
fn apply_bcs(c_in: vec3<f32>) -> vec3<f32> {
    var c = mix(vec3<f32>(0.0), c_in, U.bcs.x);
    c = mix(vec3<f32>(0.5), c, U.bcs.y);
    c = mix(vec3<f32>(dot(c, vec3<f32>(1.0)) / 3.0), c, U.bcs.z);
    return c;
}

// Godot's texture2D_bicubic (its tonemap shader's glow upscale on desktop):
// the cubic B-spline over 4 x 4 texels of glow level `lod + 1`, as four
// bilinear reads at offsets that fold the spline's weights into the
// hardware's filter. A coarse level read bilinearly would show its texels
// (32 pixels and more at level 5) as a halo with rounded-square edges.
fn bspline_weights(a: f32) -> vec4<f32> {
    let w0 = (1.0 / 6.0) * (a * (a * (-a + 3.0) - 3.0) + 1.0);
    let w1 = (1.0 / 6.0) * (a * a * (3.0 * a - 6.0) + 4.0);
    let w2 = (1.0 / 6.0) * (a * (a * (-3.0 * a + 3.0) + 3.0) + 1.0);
    let w3 = (1.0 / 6.0) * (a * a * a);
    // g0, g1 (the two reads' weights), h0, h1 (their offsets in texels)
    return vec4<f32>(w0 + w1, w2 + w3, -1.0 + w1 / (w0 + w1), 1.0 + w3 / (w2 + w3));
}

fn glow_bicubic(uv: vec2<f32>, lod: i32) -> vec3<f32> {
    let size = vec2<f32>(textureDimensions(t_glow, lod));
    let texel = vec2<f32>(1.0) / size;
    let st = uv * size + vec2<f32>(0.5);
    let i = floor(st);
    let f = st - i;
    let wx = bspline_weights(f.x);
    let wy = bspline_weights(f.y);
    let l = f32(lod);
    let p0 = (vec2<f32>(i.x + wx.z, i.y + wy.z) - vec2<f32>(0.5)) * texel;
    let p1 = (vec2<f32>(i.x + wx.w, i.y + wy.z) - vec2<f32>(0.5)) * texel;
    let p2 = (vec2<f32>(i.x + wx.z, i.y + wy.w) - vec2<f32>(0.5)) * texel;
    let p3 = (vec2<f32>(i.x + wx.w, i.y + wy.w) - vec2<f32>(0.5)) * texel;
    return wy.x * (wx.x * textureSampleLevel(t_glow, s_linear, p0, l).rgb
            + wx.y * textureSampleLevel(t_glow, s_linear, p1, l).rgb)
        + wy.y * (wx.x * textureSampleLevel(t_glow, s_linear, p2, l).rgb
            + wx.y * textureSampleLevel(t_glow, s_linear, p3, l).rgb);
}

// The glow levels' weighted sum at `uv`, each level read bicubically (a
// level of weight 0 is not read: it is not drawn, and its mip is clamped
// to the chain's last, or the 1 x 1 dummy's).
fn glow_sum(uv: vec2<f32>) -> vec3<f32> {
    var w = array<f32, 7>(U.levels_low.x, U.levels_low.y, U.levels_low.z, U.levels_low.w,
        U.levels_high.x, U.levels_high.y, U.levels_high.z);
    var g = vec3<f32>(0.0);
    for (var k = 0; k < 7; k++) {
        if (w[k] != 0.0) {
            g += glow_bicubic(uv, k) * w[k];
        }
    }
    return g;
}

// The finished picture as sRGB values, per render-size texel (post.as
// `postPixel`): with POST_TONEMAP t_src holds HDR colour, exposed here and
// tone mapped after the glow (mix blends it in before the curve, the other
// modes after the encode, as Godot's tonemap shader does); without it, the
// main pass's tone-mapped colour. Then the adjustments, in sRGB. Last,
// with POST_OVERLAY, the overlay layer (t_aux: the grid, edges, points and
// gizmos, drawn by their own pass as premultiplied linear colour, already
// final) over the result in linear space, as the main pass would have
// blended them: no post effect touches them, so turning glow on or
// adjustments on changes no line of the editor.
@fragment
fn fs_post(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let q = vec2<i32>(floor(pos.xy));
    let uv = pos.xy * U.target_size.zw;
    let src = textureLoad(t_src, q, 0);
    let bits = U.flags.x;
    let mode = U.flags.y;
    let blend = U.flags.z;
    let white = U.tone.y;
    var c = src.rgb;
    // A transparent background: the resolve left premultiplied colour,
    // and the picture is used as straight alpha (post_outline.wgsl).
    if ((bits & POST_STRAIGHT) != 0u && src.a > 0.0 && src.a < 1.0) {
        c = c / max(src.a, 1e-6);
    }
    if ((bits & POST_TONEMAP) != 0u) {
        c = max(c * U.tone.x, vec3<f32>(0.0));
    }
    var g = vec3<f32>(0.0);
    if ((bits & POST_GLOW) != 0u) {
        g = glow_sum(uv);
        if (blend == GLOW_BLEND_MIX) {
            c = mix(c, g, U.tone.z);
        }
    }
    if ((bits & POST_TONEMAP) != 0u) {
        c = tone_curve(c, mode, white);
    }
    c = linear_to_srgb(sat3(c));
    if ((bits & POST_GLOW) != 0u && blend != GLOW_BLEND_MIX) {
        let gs = linear_to_srgb(sat3(tone_curve(g, mode, white)));
        c = glow_blend(c, gs, blend);
    }
    if ((bits & POST_ADJUST) != 0u) {
        c = apply_bcs(c);
    }
    c = sat3(c);
    var a = src.a;
    if ((bits & POST_OVERLAY) != 0u) {
        let o = textureLoad(t_aux, q, 0);
        let lin = srgb_to_linear(c) * (1.0 - o.a) + o.rgb;
        c = linear_to_srgb(sat3(lin));
        a = o.a + a * (1.0 - o.a);
    }
    return vec4<f32>(c, a);
}
