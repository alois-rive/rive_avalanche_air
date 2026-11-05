// Draws one texture into one level of one layer of the decal atlas
// (engine/src/render/gpu/decals.as): the atlas is a 2D array of
// rgba8unorm layers, DECAL_LAYER_SIZE (512) texels square with
// DECAL_LEVELS levels, colour layers (albedo, emission) holding
// sRGB-encoded colour, which surface.wgsl's apply_decals decodes, data
// layers (normal, orm) their values as they are. One full-screen triangle
// into a view of that one layer and level; group 0: the source at binding
// 0, a linear clamp sampler (mip linear) at binding 1, and the target's
// level at binding 2.
//
// The source is read at the level of its own chain that matches the
// target's: target level + log2(source side / 512), never under 0 (a
// source smaller than a layer is magnified from its level 0), the larger
// side of a non-square source, which is stretched to the square layer.
// A live source (an artboard's target, one level) is read at its level 0,
// as the renderer draws a live layer's level 0 alone. Live targets hold
// straight alpha already (the artboard blit undid Rive's premultiplication),
// as every uploaded texture does: nothing here unpremultiplies.
//
// fs_decal_copy writes the source as it is: a data texture, or a colour
// texture uploaded in a compressed form, which holds the file's
// sRGB-encoded bytes. fs_decal_encode writes linear colour (an uploaded
// colour texture is rgba16float holding decoded colour; a live colour
// target too) encoded with the exact sRGB curve, the inverse of
// srgb_to_linear (engine/src/base/color.as; GpuDecals' CPU mirror,
// decalEncodeReference, is what the tests check), so that the shader's
// decode gives back the colour to 8-bit rounding.

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var src_sampler: sampler;

struct DecalBlitU {
    level: vec4<f32>,               // x the target's level (0 to DECAL_LEVELS - 1), yzw unused
};
@group(0) @binding(2) var<uniform> Blit: DecalBlitU;

const DECAL_LAYER_SIDE: f32 = 512.0;

struct DecalBlitOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_decal_blit(@builtin(vertex_index) i: u32) -> DecalBlitOut {
    var corners = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    let p = corners[i];
    var out: DecalBlitOut;
    out.position = vec4<f32>(p, 0.0, 1.0);
    // Row 0 of the source is its top, as the layer's.
    out.uv = vec2<f32>((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
    return out;
}

// The source's texel for the target's level (see the header).
fn decal_source(uv: vec2<f32>) -> vec4<f32> {
    let dims = textureDimensions(src, 0);
    let side = f32(max(max(dims.x, dims.y), 1u));
    let lod = max(Blit.level.x + log2(side / DECAL_LAYER_SIDE), 0.0);
    return textureSampleLevel(src, src_sampler, uv, lod);
}

fn linear_to_srgb_channel(c_in: f32) -> f32 {
    let c = clamp(c_in, 0.0, 1.0);
    if (c <= 0.0031308) {
        return c * 12.92;
    }
    return 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

@fragment
fn fs_decal_copy(v: DecalBlitOut) -> @location(0) vec4<f32> {
    return decal_source(v.uv);
}

@fragment
fn fs_decal_encode(v: DecalBlitOut) -> @location(0) vec4<f32> {
    let c = decal_source(v.uv);
    return vec4<f32>(linear_to_srgb_channel(c.r), linear_to_srgb_channel(c.g), linear_to_srgb_channel(c.b),
        clamp(c.a, 0.0, 1.0));
}
