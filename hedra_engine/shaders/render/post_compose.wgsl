// Integer image compositing on the GPU.
//
// Every view is finished with byte arithmetic: the SSAA box downsample
// (`Image.downsample`), then labels and the axis gizmo blended onto it
// (`Image.blend`), then contact sheets (`composite.sheet`). rive has no
// readback, so that arithmetic runs here, bit for bit
// (src/render/gpu/view.as, passes P4 and the sheet / present blits):
//
//   out(p) = blend(down(src, factor, p - rect.xy), overlay(p - rect.xy))
//
// for p inside `rect` (other fragments are discarded). `down` is
// `(acc + n / 2) / n` over the factor x factor source texels (n = factor^2),
// and `blend` is `Image.blend` with the overlay texel as the source color,
// both in u32 integer math on the byte values, exactly as the CPU code.
// `present` sets `premultiply` for the host canvas (see fs_compose).
// A transparent frame's downsample sets `weighted` (see fs_compose).

struct ComposeU {
    // Destination rect: x, y, width, height in target pixels.
    rect: vec4<i32>,
    // factor (>= 1), has_overlay (0/1), premultiply (0/1), weighted (0/1).
    params: vec4<u32>,
};

@group(0) @binding(0) var<uniform> U: ComposeU;
// Straight-alpha sRGB bytes (rgba8unorm), `factor` times the rect size.
@group(0) @binding(1) var src: texture_2d<f32>;
// Straight-alpha sRGB bytes (rgba8unorm) at the rect size; a 1x1 dummy when unused.
@group(0) @binding(2) var overlay: texture_2d<f32>;

@vertex
fn vs_full(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    var pts = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    return vec4<f32>(pts[vi], 0.0, 1.0);
}

fn to_bytes(v: vec4<f32>) -> vec4<u32> {
    return vec4<u32>(round(clamp(v, vec4<f32>(0.0), vec4<f32>(1.0)) * 255.0));
}

@fragment
fn fs_compose(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let q = vec2<i32>(floor(pos.xy));
    let local = q - U.rect.xy;
    if (local.x < 0 || local.y < 0 || local.x >= U.rect.z || local.y >= U.rect.w) {
        discard;
    }
    // `Image.downsample` (a plain copy when factor is 1).
    let f = i32(max(U.params.x, 1u));
    let n = u32(f * f);
    // `weighted`: colour averaged by alpha, (sum(c * a) + A / 2) / A with
    // A = sum(a), 0 where A is 0 (`Image.downsample(factor, true)`).
    let w = U.params.w == 1u;
    var acc = vec4<u32>(0u);
    for (var sy = 0; sy < f; sy++) {
        for (var sx = 0; sx < f; sx++) {
            let t = to_bytes(textureLoad(src, local * f + vec2<i32>(sx, sy), 0));
            acc += vec4<u32>(t.xyz * select(1u, t.w, w), t.w);
        }
    }
    let div = max(select(n, acc.w, w), 1u);
    var d = vec4<u32>((acc.xyz + vec3<u32>(div / 2u)) / div, (acc.w + n / 2u) / n);
    // `Image.blend(x, y, overlay texel)`.
    if (U.params.y == 1u) {
        let c = to_bytes(textureLoad(overlay, local, 0));
        let a = c.w;
        if (a == 255u) {
            d = c;
        } else if (a != 0u) {
            let ia = 255u - a;
            let da = d.w;
            let out_a = max(a + da * ia / 255u, 1u);
            let v = (c.xyz * a + d.xyz * da * ia / 255u) / out_a;
            d = vec4<u32>(min(v, vec3<u32>(255u)), min(out_a, 255u));
        }
    }
    let o = vec4<f32>(d) / 255.0;
    // `present` only: the host draws a canvas image as premultiplied alpha,
    // and the images here are straight alpha (like `Image`).
    if (U.params.z == 1u) {
        return vec4<f32>(o.rgb * o.a, o.a);
    }
    return o;
}
