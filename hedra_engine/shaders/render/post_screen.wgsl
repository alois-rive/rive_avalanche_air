// The screen texture's passes (Godot's screen texture, the copy of the
// opaque picture that refracting glass and the screen-space reflections
// read; engine/src/render/gpu/screen_chain.as runs them inside the host's
// draw, between the two halves of the main pass, and
// docs/engine/SCREEN_EFFECTS.md says what they are for). One texture of
// SCREEN_FORMAT (rgba16float, HDR as the main pass keeps it) at the render
// size with up to SCREEN_LEVELS_MAX mips; every pass draws one full-screen
// triangle into one mip:
//
//   fs_screen_copy   level 0 from the main pass's resolved colour, texel for
//                    texel (the same size: an exact copy);
//   fs_screen_down   level m from level m - 1 (a view of that one mip), the
//                    mean of each 2 x 2 (the last row or column of an odd
//                    side read twice), as the glow's levels and the probes'
//                    are made.
//
// Rough glass reads a blurrier level (render/screen.as refractionLod), the
// reflections of rough surfaces likewise. No uniform block: the passes find
// everything from the fragment's position and the source's size.

@group(0) @binding(0) var t_src: texture_2d<f32>;

// One triangle over the target.
@vertex
fn vs_screen(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    var pts = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    return vec4<f32>(pts[vi], 0.0, 1.0);
}

@fragment
fn fs_screen_copy(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    return textureLoad(t_src, vec2<i32>(floor(pos.xy)), 0);
}

@fragment
fn fs_screen_down(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let last = vec2<i32>(textureDimensions(t_src, 0)) - vec2<i32>(1);
    let p = vec2<i32>(floor(pos.xy)) * 2;
    let a = textureLoad(t_src, min(p, last), 0);
    let b = textureLoad(t_src, min(p + vec2<i32>(1, 0), last), 0);
    let c = textureLoad(t_src, min(p + vec2<i32>(0, 1), last), 0);
    let d = textureLoad(t_src, min(p + vec2<i32>(1, 1), last), 0);
    return (a + b + c + d) * 0.25;
}
