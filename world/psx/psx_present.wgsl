// psx_present.wgsl: puts the low-resolution picture on the screen the way a
// PlayStation's video DAC did. It is the material of one QuadMesh placed in
// front of the main camera (assets/scenes/psx_frame.rscn), whose texture
// is the ViewportTexture of the SubViewport the game is drawn in.
//
// - nearest upscale: each low-resolution pixel becomes a crisp block;
// - aspect kept: the picture is pillarboxed or letterboxed, optionally to an
//   integer multiple of its height (pixel-perfect blocks);
// - 15-bit colour: each channel truncated to `color_bits` bits after the
//   PlayStation's own 4 x 4 dither offsets (psx-spx, "GPU Dithering"),
//   applied in display (sRGB) space, on the low-resolution grid.
//
// Notes for Hedra (verified with hedra 0.1.0):
// - Hedra has no post-process shader and presents a scaled 3D picture
//   bilinearly; this quad is the post pass. Draw it in a world that holds
//   nothing else (the game is in the SubViewport's own world), with a
//   linear tone map (tonemap_mode 0) on both worlds' Environments, so the
//   colours reach it unchanged and are not tone mapped twice.
// - A ViewportTexture in a colour slot is sampled decoded from sRGB: the
//   values arrive linear, are quantised in sRGB, and leave linear.
shader_type spatial;
render_mode unshaded, fog_disabled, shadows_disabled, cull_disabled, depth_test_disabled, depth_draw_never, specular_disabled, ambient_light_disabled;

uniform screen: texture_2d<f32> : source_color, filter_nearest, repeat_disable, hint_default_black;
// The SubViewport's size in pixels (its `size`).
uniform low_res: vec2<f32> = vec2<f32>(320.0, 240.0);
// 5 is the PlayStation's 15-bit colour; 8 switches the quantisation off.
uniform color_bits: f32 : hint_range(1.0, 8.0, 1.0) = 5.0;
// 1 is the PlayStation's dither table; 0 truncates with no dither (banding).
uniform dither_strength: f32 : hint_range(0.0, 2.0, 0.05) = 1.0;
// 1 scales the picture by a whole number of its pixels when the screen
// allows it (each block the same size); 0 fills the height exactly.
uniform integer_scale: f32 : hint_range(0.0, 1.0, 1.0) = 0.0;

fn psx_encode_srgb(c: vec3<f32>) -> vec3<f32> {
    let lo = c * 12.92;
    let hi = 1.055 * pow(max(c, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.4)) - 0.055;
    return select(hi, lo, c <= vec3<f32>(0.0031308));
}

fn psx_decode_srgb(c: vec3<f32>) -> vec3<f32> {
    let lo = c / 12.92;
    let hi = pow((c + 0.055) / 1.055, vec3<f32>(2.4));
    return select(hi, lo, c <= vec3<f32>(0.04045));
}

fn vertex() {
    // A 1 x 1 QuadMesh, its corners at +-0.5, stretched over the screen
    // with the low-resolution picture's aspect.
    let target_aspect = low_res.x / low_res.y;
    let view_aspect = VIEWPORT_SIZE.x / max(VIEWPORT_SIZE.y, 1.0);
    var extent = vec2<f32>(1.0, 1.0);
    if (view_aspect > target_aspect) {
        extent.x = target_aspect / view_aspect;
    } else {
        extent.y = view_aspect / target_aspect;
    }
    if (integer_scale > 0.5) {
        let shown = extent.y * VIEWPORT_SIZE.y;
        let whole = floor(shown / low_res.y);
        if (whole >= 1.0) {
            extent = extent * (whole * low_res.y / shown);
        }
    }
    POSITION = vec4<f32>(VERTEX.xy * 2.0 * extent, 0.5, 1.0);
}

fn fragment() {
    let px = floor(UV * low_res);
    let c = texture(screen, (px + 0.5) / low_res).rgb;
    // The PlayStation's dither offsets, in 8-bit steps, for x % 4 and y % 4.
    var table = array<f32, 16>(
        -4.0, 0.0, -3.0, 1.0,
        2.0, -2.0, 3.0, -1.0,
        -3.0, 1.0, -4.0, 0.0,
        3.0, -1.0, 2.0, -2.0);
    let ix = u32(px.x) % 4u;
    let iy = u32(px.y) % 4u;
    let offset = table[iy * 4u + ix] * dither_strength;
    let step = exp2(8.0 - color_bits);
    let v8 = clamp(psx_encode_srgb(c) * 255.0 + offset, vec3<f32>(0.0), vec3<f32>(255.0));
    let q = floor(v8 / step) * step / 255.0;
    ALBEDO = psx_decode_srgb(q);
}
