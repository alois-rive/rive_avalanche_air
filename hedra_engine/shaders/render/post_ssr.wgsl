// Screen-space reflections (Godot's Environment ssr_*): engine/src/render/
// ssr.as is the CPU reference of every step here and says why each is so;
// engine/src/render/screen.as holds Godot's curves; gpu/ssr.as runs the
// passes and fills the block (SsrUniform). Every entry draws a
// full-screen triangle with the one group 0 below; a pass binds a 1 x 1
// dummy where it reads nothing.
//
//   fs_ssr_nd_half at the trace size, when it is not the render size, into
//                  NORMAL_DEPTH_FORMAT: each texel the normal-depth pass's
//                  texel the trace reads for it (source_px), so that the
//                  march's many reads and the merge's upsample fall in a
//                  quarter of the bytes, or a sixteenth (the same values:
//                  the picture is the very one of a march over t_nd itself)
//   fs_ssr_trace   at the trace size (the render size, or half or a quarter
//                  of it: screen.as ssrQuarter) into
//                  SSR_FORMAT: each texel's mirror ray marched over the
//                  normal-depth pass's depth (t_nd: view normal, view depth,
//                  0 where nothing is drawn; marched over t_march, its
//                  trace-size copy or t_nd itself), faded by Godot's curves, its
//                  colour read from the screen texture (t_screen: the
//                  opaque picture and its mips) and weighed by the
//                  surface's Fresnel (t_surface: F0, roughness): rgb the
//                  reflection times its weights, a the weight the colour
//                  below loses (premultiplied over); 0 where it misses
//   fs_ssr_merge   inside the main pass's second half, at the render size:
//                  the trace (t_ssr) at each pixel, upsampled from half size
//                  by a joint bilateral filter on the depths, laid over the
//                  colour by the pipeline's blend (one, one minus source
//                  alpha; the alpha kept)

const SSR_REFINE_STEPS: i32 = 4;     // screen.as
const SSR_FACING: f32 = 0.001;       // ssr.as
const SSR_FAR_GUARD: f32 = 0.95;
const ROUGH_DISABLED: u32 = 0u;      // screen.as SSR_ROUGHNESS_*
const ROUGH_LOW: u32 = 1u;
const ROUGH_MEDIUM: u32 = 2u;
const PI: f32 = 3.14159265;

struct SsrU {                    // 192 bytes (gpu/ssr.as SsrUniform)
    size: vec4<f32>,             // xy the render size, zw the trace's
    cam: vec4<f32>,              // x near, y far, z 1 if orthographic, w ssr_depth_tolerance
    march: vec4<f32>,            // x steps, y ssr_fade_in, z ssr_fade_out, w the screen texture's levels
    flags: vec4<u32>,            // x roughness quality, y 1 if the trace is not the render size
    proj: mat4x4<f32>,           // view to clip
    inv_proj: mat4x4<f32>,       // clip to view
};

@group(0) @binding(0) var<uniform> U: SsrU;
@group(0) @binding(1) var t_nd: texture_2d<f32>;
@group(0) @binding(2) var t_surface: texture_2d<f32>;
@group(0) @binding(3) var t_screen: texture_2d<f32>;
@group(0) @binding(4) var s_linear: sampler;   // linear, linear, mip linear, clamp to edge
@group(0) @binding(5) var t_ssr: texture_2d<f32>;
@group(0) @binding(6) var t_march: texture_2d<f32>;

@vertex
fn vs_ssr(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    var pts = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    return vec4<f32>(pts[vi], 0.0, 1.0);
}

// ssr.as ssrDither: BAYER4 (post.as) at texel p, over 16.
fn dither(p: vec2<i32>) -> f32 {
    var bayer = array<u32, 16>(0u, 8u, 2u, 10u, 12u, 4u, 14u, 6u, 3u, 11u, 1u, 9u, 15u, 7u, 13u, 5u);
    return f32(bayer[(p.y & 3) * 4 + (p.x & 3)]) / 16.0;
}

// The render pixel under trace position `t` (texels of the trace).
fn source_px(t: vec2<f32>) -> vec2<i32> {
    let s = clamp(floor(t * U.size.xy / U.size.zw), vec2<f32>(0.0), U.size.xy - vec2<f32>(1.0));
    return vec2<i32>(s);
}

// The normal-depth texel the march reads at trace texel `t` (in the
// target): t_march's (fs_ssr_nd_half's copy, or t_nd at the render size),
// which is t_nd's at source_px(t + 0.5).
fn march_at(t: vec2<f32>) -> vec4<f32> {
    let c = clamp(t, vec2<f32>(0.0), U.size.zw - vec2<f32>(1.0));
    return textureLoad(t_march, vec2<i32>(c), 0);
}

// ssr.as ssrViewAt: the view position at depth d under UV `uv` (y down).
fn view_at(uv: vec2<f32>, d: f32) -> vec3<f32> {
    let a4 = U.inv_proj * vec4<f32>(2.0 * uv.x - 1.0, 1.0 - 2.0 * uv.y, 0.0, 1.0);
    let a = a4.xyz / a4.w;
    if (U.cam.z > 0.5) {
        return vec3<f32>(a.xy, -d);
    }
    return a * (d / -a.z);
}

// ssr.as ssrToTarget: xy in trace texels (y down), z 1/w.
fn to_target(p: vec3<f32>) -> vec3<f32> {
    let c = U.proj * vec4<f32>(p, 1.0);
    let n = c.xy / c.w;
    return vec3<f32>((n.x * 0.5 + 0.5) * U.size.z, (0.5 - n.y * 0.5) * U.size.w, 1.0 / c.w);
}

// screen.as ssrStepFade. pow of 0 is undefined in WGSL: the base is kept
// at 1e-6 at least.
fn step_fade(taken: f32) -> f32 {
    let grad = clamp((taken + 1.0) / max(U.march.x, 1.0), 0.0, 1.0);
    var initial = 1.0;
    if (U.march.y > 0.0) {
        initial = pow(grad, U.march.y);
    }
    let fade = pow(max(1.0 - grad, 1e-6), max(U.march.z, 0.0)) * initial;
    return select(fade, 1.0, fade > 0.999);
}

// screen.as ssrMarginFade.
fn margin_fade(p: vec2<f32>, s: vec2<f32>) -> f32 {
    if (p.x < 0.0 || p.y < 0.0 || p.x > s.x || p.y > s.y) {
        return 0.0;
    }
    let m = (s.x + s.y) * 0.05;
    let g = select(s - p, p, p < s * 0.5);
    return smoothstep(0.0, m * m, g.x * g.y);
}

// screen.as ssrMergeWeight.
fn merge_weight(f0: vec3<f32>, nv: f32, fade: f32) -> vec4<f32> {
    let m = clamp(1.0 - nv, 0.0, 1.0);
    let m5 = m * m * m * m * m;
    let f = f0 + (vec3<f32>(1.0) - f0) * m5;
    let a = clamp(fade, 0.0, 1.0);
    return vec4<f32>(f * a, max(max(f.x, f.y), f.z) * a);
}

// The ray's positive view depth at `k` of the clipped line (z/w and 1/w
// interpolated along the screen: perspective-correct).
fn ray_depth(zb: f32, dz: f32, wb: f32, dw: f32, k: f32) -> f32 {
    return -(zb + dz * k) / (wb + dw * k);
}

// The reflection's colour at UV `uv` of a hit `dist` render pixels away on
// a surface of roughness `rough` (ssr.as ssrLod, ssrTapCount and
// ssrTapOffset), turned by `turn`.
fn ssr_colour(uv: vec2<f32>, dist: f32, rough: f32, turn: f32) -> vec3<f32> {
    let q = U.flags.x;
    let levels = U.march.w;
    if (q == ROUGH_DISABLED || levels <= 1.0) {
        return textureSampleLevel(t_screen, s_linear, uv, 0.0).rgb;
    }
    let blur = dist * rough * rough;
    let lod = clamp(log2(max(1.0, blur)), 0.0, levels - 1.0);
    if (q == ROUGH_LOW) {
        return textureSampleLevel(t_screen, s_linear, uv, lod).rgb;
    }
    let count = select(8, 4, q == ROUGH_MEDIUM);
    let level = max(lod - 1.0, 0.0);
    let reach = vec2<f32>(0.5 * blur) / U.size.xy;
    var sum = vec3<f32>(0.0);
    for (var i = 0; i < count; i++) {
        let a = 2.0 * PI * (f32(i) + turn) / f32(count);
        sum += textureSampleLevel(t_screen, s_linear, uv + vec2<f32>(cos(a), sin(a)) * reach, level).rgb;
    }
    return sum / f32(count);
}

@fragment
fn fs_ssr_nd_half(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    return textureLoad(t_nd, source_px(floor(frag.xy) + vec2<f32>(0.5)), 0);
}

@fragment
fn fs_ssr_trace(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let p = vec2<i32>(floor(frag.xy));
    let ts = U.size.zw;
    let q = source_px(vec2<f32>(p) + vec2<f32>(0.5));
    let nd = textureLoad(t_nd, q, 0);
    if (nd.w <= 0.0) {
        return vec4<f32>(0.0);
    }
    let surf = textureLoad(t_surface, q, 0);
    let rf = smoothstep(0.4, 0.7, 1.0 - surf.a);
    if (rf <= 0.0) {
        return vec4<f32>(0.0);
    }
    let n = normalize(nd.xyz);
    let pv = view_at((vec2<f32>(q) + vec2<f32>(0.5)) / U.size.xy, nd.w);
    var v = vec3<f32>(0.0, 0.0, -1.0);
    if (U.cam.z <= 0.5) {
        v = normalize(pv);
    }
    let r = normalize(reflect(v, n));
    if (dot(r, n) < SSR_FACING) {
        return vec4<f32>(0.0);
    }
    // Godot's ray: the far distance long, clipped to the near plane.
    let z_near = U.cam.x;
    let z_far = U.cam.y;
    var len = z_far;
    if (pv.z + r.z * z_far > -z_near) {
        len = (-z_near - pv.z) / r.z;
    }
    let pe = pv + r * len;
    let b = to_target(pv);
    let e = to_target(pe);
    let zb = pv.z * b.z;
    let ze = pe.z * e.z;
    // The line clipped to the trace target (0.99 of the way to an edge).
    let vb = b.xy / ts;
    let vd = (e.xy - b.xy) / ts;
    let clip_k = min(
        min(min(1.0, 0.99 * (1.0 - vb.x) / max(1e-5, vd.x)), 0.99 * (1.0 - vb.y) / max(1e-5, vd.y)),
        min(0.99 * vb.x / max(1e-5, -vd.x), 0.99 * vb.y / max(1e-5, -vd.y)));
    let seg = (e.xy - b.xy) * clip_k;
    let dz = (ze - zb) * clip_k;
    let dw = (e.z - b.z) * clip_k;
    let pixels = max(abs(seg.x), abs(seg.y));
    if (pixels < 1.0) {
        return vec4<f32>(0.0);
    }
    let steps = i32(U.march.x);
    let stride = max(1.0, pixels / f32(steps));
    let jit = dither(p);
    var t_prev = 0.0;
    var zr_from = -pv.z;
    var t_hit = -1.0;
    var taken = 0;
    for (var i = 0; i < steps; i++) {
        let t = 1.0 + stride * (f32(i) + jit);
        if (t > pixels) {
            break;
        }
        let k = t / pixels;
        let pos = b.xy + seg * k;
        let zr_to = ray_depth(zb, dz, b.z, dw, k);
        let s = march_at(floor(pos));
        if (s.w > 0.0 && s.w < zr_to) {
            // (a surface seen from behind is passed under, as Godot's)
            if (dot(r, s.xyz) < SSR_FACING) {
                if (s.w >= min(zr_from, zr_to) - U.cam.w && s.w < SSR_FAR_GUARD * z_far) {
                    t_hit = t;
                    taken = i;
                }
                break;
            }
        }
        zr_from = zr_to;
        t_prev = t;
    }
    if (t_hit < 0.0) {
        return vec4<f32>(0.0);
    }
    var lo = t_prev;
    var hi = t_hit;
    for (var k = 0; k < SSR_REFINE_STEPS; k++) {
        let mid = (lo + hi) * 0.5;
        let km = mid / pixels;
        let zr = ray_depth(zb, dz, b.z, dw, km);
        let dm = march_at(floor(b.xy + seg * km)).w;
        if (dm > 0.0 && dm < zr) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    let hit = b.xy + seg * (hi / pixels);
    let fade = step_fade(f32(taken)) * margin_fade(hit, ts) * rf;
    if (fade <= 0.0) {
        return vec4<f32>(0.0);
    }
    let dist = length(hit - b.xy) * U.size.x / ts.x;
    let c = ssr_colour(hit / ts, dist, surf.a, jit);
    let w = merge_weight(surf.rgb, clamp(dot(n, -v), 0.0, 1.0), fade);
    return vec4<f32>(c * w.rgb, w.w);
}

// ssr.as ssrUpsampleCpu: the trace at pixel q, or (from half or quarter
// size) its 2 x 2 nearest texels weighed by their bilinear weights over
// 1e-3 plus their depths' difference from q's, relative to q's
// (ssrBilateralWeight), each texel's depth the one the trace started from
// (t_march: the copy holds it); 0 where nothing is drawn.
@fragment
fn fs_ssr_merge(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let q = vec2<i32>(floor(frag.xy));
    let z = textureLoad(t_nd, q, 0).w;
    if (z <= 0.0) {
        return vec4<f32>(0.0);
    }
    if (U.flags.y == 0u) {
        return textureLoad(t_ssr, q, 0);
    }
    let ts = U.size.zw;
    let s = (vec2<f32>(q) + vec2<f32>(0.5)) * ts / U.size.xy - vec2<f32>(0.5);
    let base = floor(s);
    let f = s - base;
    let top = ts - vec2<f32>(1.0);
    var sum = vec4<f32>(0.0);
    var weights = 0.0;
    for (var j = 0; j < 4; j++) {
        let o = vec2<f32>(f32(j & 1), f32(j >> 1u));
        let t = clamp(base + o, vec2<f32>(0.0), top);
        let bil = select(1.0 - f.x, f.x, o.x > 0.5) * select(1.0 - f.y, f.y, o.y > 0.5);
        let zi = march_at(t).w;
        if (zi <= 0.0) {
            continue;
        }
        let w = bil / (1e-3 + abs(zi - z) / z);
        sum += textureLoad(t_ssr, vec2<i32>(t), 0) * w;
        weights += w;
    }
    if (weights <= 1e-8) {
        return vec4<f32>(0.0);
    }
    return sum / weights;
}
