// Milestone 15: copies a Rive canvas's image (8-bit, sRGB-encoded colour,
// premultiplied alpha) into a live texture target the materials sample
// (engine/src/render/gpu/live_texture.as). One full-screen triangle;
// group 0: the source at binding 0, a linear clamp sampler at binding 1.
//
// The targets hold what the renderer's own textures hold (gpu/materials.as
// uploadTexture): a colour slot's linear colour, a data slot's values as
// they are, both with straight alpha, which is what the surface shader
// reads from a PNG. So both entry points first undo the premultiplication
// (a texel with no coverage stays 0), and fs_blit_srgb then decodes the
// exact sRGB curve, the one engine/src/base/color.as srgbToLinear and
// LiveTextureBlit's CPU mirror (blitSrgbReference) apply: not the
// approximate pow(x, 2.2), which is 0.5 % off in the darks.
//
// Milestone 34: fs_blit_srgb_straight and fs_blit_linear_straight copy a
// viewport's picture (the renderer's own result: 8-bit sRGB-encoded colour
// with straight alpha already) the same two ways without the division,
// which would brighten every texel a transparent background leaves partly
// covered.

@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var source_sampler: sampler;

struct BlitOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_blit(@builtin(vertex_index) i: u32) -> BlitOut {
    var corners = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    let p = corners[i];
    var out: BlitOut;
    out.position = vec4<f32>(p, 0.0, 1.0);
    // Row 0 of the source is its top, as the target's.
    out.uv = vec2<f32>((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
    return out;
}

// Premultiplied to straight alpha; where nothing covers the texel the
// colour is 0 (dividing would be 0 / 0).
fn unpremultiply(c: vec4<f32>) -> vec4<f32> {
    if (c.a > 0.0) {
        return vec4<f32>(min(c.rgb / c.a, vec3<f32>(1.0)), c.a);
    }
    return vec4<f32>(0.0, 0.0, 0.0, 0.0);
}

fn srgb_to_linear_channel(c: f32) -> f32 {
    if (c <= 0.04045) {
        return c / 12.92;
    }
    return pow((c + 0.055) / 1.055, 2.4);
}

@fragment
fn fs_blit_srgb(v: BlitOut) -> @location(0) vec4<f32> {
    let s = unpremultiply(textureSample(source, source_sampler, v.uv));
    return vec4<f32>(
        srgb_to_linear_channel(s.r), srgb_to_linear_channel(s.g), srgb_to_linear_channel(s.b), s.a);
}

@fragment
fn fs_blit_linear(v: BlitOut) -> @location(0) vec4<f32> {
    return unpremultiply(textureSample(source, source_sampler, v.uv));
}

// A straight-alpha source (a viewport's picture): the sRGB curve decoded,
// alpha as it is.
@fragment
fn fs_blit_srgb_straight(v: BlitOut) -> @location(0) vec4<f32> {
    let s = textureSample(source, source_sampler, v.uv);
    return vec4<f32>(
        srgb_to_linear_channel(s.r), srgb_to_linear_channel(s.g), srgb_to_linear_channel(s.b), s.a);
}

// A straight-alpha source as its bytes are.
@fragment
fn fs_blit_linear_straight(v: BlitOut) -> @location(0) vec4<f32> {
    return textureSample(source, source_sampler, v.uv);
}
