// The depth of field (Godot's CameraAttributesPractical dof_blur_*):
// engine/src/render/dof.as is the CPU reference of the three passes here
// and says why each is so; engine/src/render/screen.as holds Godot's
// circle of confusion (dofCoc); gpu/dof.as runs them and fills the block
// (DofUniform). Every entry draws a full-screen triangle with the one
// group 0 below; a pass binds a 1 x 1 dummy where it reads nothing.
//
//   fs_dof_coc      half the render size, DOF_FORMAT: rgb the 2 x 2 block's
//                   mean colour of t_colour (the main pass's resolved HDR
//                   picture), a the signed circle of confusion in half-size
//                   pixels at the block's nearest depth (t_nd)
//   fs_dof_gather   the same size: the bokeh-shaped gather of t_half (the
//                   circles above), rgb the blurred colour, a the near
//                   field's coverage
//   fs_dof_compose  the render size, DOF_FORMAT: t_colour mixed toward the
//                   gather (t_half, sampled bilinearly) by the pixel's own
//                   circle and the coverage; its alpha kept

const SHAPE_BOX: u32 = 0u;       // screen.as DOF_SHAPE_*
const SHAPE_HEXAGON: u32 = 1u;
const PI: f32 = 3.14159265;

struct DofU {                    // 80 bytes (gpu/dof.as DofUniform)
    size: vec4<f32>,             // xy the render size, zw the half size
    far: vec4<f32>,              // x 1 if dof_blur_far_enabled, y its distance, z its transition, w the radius (render pixels)
    near: vec4<f32>,             // x 1 if dof_blur_near_enabled, y its distance, z its transition, w the camera's far distance
    shape: vec4<u32>,            // x the bokeh shape, y the rings, z 1 with jitter, w the taps
    rings: vec4<u32>,            // the taps of rings 1 to 4
};

@group(0) @binding(0) var<uniform> U: DofU;
@group(0) @binding(1) var t_colour: texture_2d<f32>;
@group(0) @binding(2) var t_nd: texture_2d<f32>;
@group(0) @binding(3) var t_half: texture_2d<f32>;
@group(0) @binding(4) var s_linear: sampler;   // linear, linear, clamp to edge

@vertex
fn vs_dof(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    var pts = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    return vec4<f32>(pts[vi], 0.0, 1.0);
}

// BAYER4 (post.as) at texel p, over 16.
fn dither(p: vec2<i32>) -> f32 {
    var bayer = array<u32, 16>(0u, 8u, 2u, 10u, 12u, 4u, 14u, 6u, 3u, 11u, 1u, 9u, 15u, 7u, 13u, 5u);
    return f32(bayer[(p.y & 3) * 4 + (p.x & 3)]) / 16.0;
}

// screen.as smoothstepF: equal edges are a step (WGSL's smoothstep of
// equal edges is undefined).
fn smooth_edge(e0: f32, e1: f32, x: f32) -> f32 {
    if (e1 == e0) {
        return select(1.0, 0.0, x < e0);
    }
    let t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// screen.as dofCoc: Godot's circle of confusion at view depth z, in render
// pixels of the radius `radius`, near negative.
fn dof_coc(z: f32, radius: f32) -> f32 {
    if (U.near.x > 0.5 && z < U.near.y) {
        if (U.near.z < 0.0) {
            return -min((U.near.y - z) / max(z, 1e-4), 1.0) * radius;
        }
        return -(1.0 - smooth_edge(U.near.y - U.near.z, U.near.y, z)) * radius;
    }
    if (U.far.x > 0.5 && z > U.far.y) {
        if (U.far.z < 0.0) {
            return min((z - U.far.y) / max(z, 1e-4), 1.0) * radius;
        }
        return smooth_edge(U.far.y, U.far.y + U.far.z, z) * radius;
    }
    return 0.0;
}

// dof.as dofShapePoint: the outline's point (radius 1 in the shape's own
// norm) at `s` of the way round.
fn shape_point(shape: u32, s: f32) -> vec2<f32> {
    let u = fract(s);
    if (shape == SHAPE_BOX) {
        let t = u * 8.0;
        if (t < 1.0) {
            return vec2<f32>(1.0, t);
        }
        if (t < 3.0) {
            return vec2<f32>(2.0 - t, 1.0);
        }
        if (t < 5.0) {
            return vec2<f32>(-1.0, 4.0 - t);
        }
        if (t < 7.0) {
            return vec2<f32>(t - 6.0, -1.0);
        }
        return vec2<f32>(1.0, t - 8.0);
    }
    if (shape == SHAPE_HEXAGON) {
        let t = u * 6.0;
        let m = floor(t);
        let f = t - m;
        let a0 = m * (PI / 3.0);
        let a1 = a0 + PI / 3.0;
        return mix(vec2<f32>(cos(a0), sin(a0)), vec2<f32>(cos(a1), sin(a1)), f);
    }
    let a = 2.0 * PI * u;
    return vec2<f32>(cos(a), sin(a));
}

// dof.as dofCocCpu.
@fragment
fn fs_dof_coc(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let p = vec2<i32>(floor(frag.xy));
    let top = vec2<i32>(U.size.xy) - vec2<i32>(1);
    var c = vec3<f32>(0.0);
    var zn = 3.0e38;
    for (var j = 0; j < 4; j++) {
        let s = min(p * 2 + vec2<i32>(j & 1, j >> 1u), top);
        c += textureLoad(t_colour, s, 0).rgb;
        let z = textureLoad(t_nd, s, 0).w;
        if (z > 0.0) {
            zn = min(zn, z);
        }
    }
    let z = select(U.near.w, zn, zn < 3.0e38);
    return vec4<f32>(c * 0.25, dof_coc(z, U.far.w) * 0.5);
}

// dof.as dofGatherCpu: the centre (weight 1) and the rings' taps, each by
// dofTapWeight at its ring's distance; a the near field's coverage.
@fragment
fn fs_dof_gather(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let p = vec2<i32>(floor(frag.xy));
    let top = vec2<f32>(U.size.zw) - vec2<f32>(1.0);
    let centre = textureLoad(t_half, p, 0);
    let cc = centre.a;
    let radius = U.far.w * 0.5;
    var sum = centre.rgb;
    var weights = 1.0;
    var cover = 0.0;
    var turn = 0.0;
    if (U.shape.z != 0u) {
        turn = dither(p);
    }
    let pc = vec2<f32>(p) + vec2<f32>(0.5);
    let n = U.shape.y;
    for (var k = 1u; k <= n; k++) {
        let count = U.rings[k - 1u];
        let dist = f32(k) / f32(n) * radius;
        let stagger = select(0.5, 0.0, (k & 1u) == 1u);
        for (var j = 0u; j < count; j++) {
            let o = shape_point(U.shape.x, (f32(j) + stagger + turn) / f32(count)) * dist;
            let t = clamp(floor(pc + o), vec2<f32>(0.0), top);
            let tap = textureLoad(t_half, vec2<i32>(t), 0);
            let cs = tap.a;
            var reach = min(cs, cc + 1.0);
            if (cs < 0.0) {
                reach = -cs;
            } else if (cc < 0.0) {
                reach = cs;
            }
            let w = clamp(reach - dist + 1.0, 0.0, 1.0);
            sum += tap.rgb * w;
            weights += w;
            if (cs < 0.0) {
                cover = max(cover, clamp(-cs - dist + 1.0, 0.0, 1.0));
            }
        }
    }
    return vec4<f32>(sum / weights, cover);
}

// dof.as dofComposeCpu and dofComposeBlend.
@fragment
fn fs_dof_compose(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let q = vec2<i32>(floor(frag.xy));
    let sharp = textureLoad(t_colour, q, 0);
    var z = textureLoad(t_nd, q, 0).w;
    if (z <= 0.0) {
        z = U.near.w;
    }
    let coc = dof_coc(z, U.far.w);
    let g = textureSampleLevel(t_half, s_linear, (vec2<f32>(q) + vec2<f32>(0.5)) / U.size.xy, 0.0);
    let blend = max(clamp(abs(coc) * 0.5 - 0.5, 0.0, 1.0), g.a);
    return vec4<f32>(mix(sharp.rgb, g.rgb, blend), sharp.a);
}
