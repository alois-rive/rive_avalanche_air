// The shadow pass's tile clear (engine/src/render/gpu/shadow_cache.as,
// docs/engine/PERFORMANCE.md "Shadows kept"): a shadow map whose light and
// casters are what they were when it was drawn keeps its tile of the atlas,
// as Godot's shadow atlas keeps a positional light's, so a pass that draws
// some tiles again loads the atlas rather than clearing it, and clears each
// tile it draws with this triangle first. It covers the tile's viewport
// (the pass's scissor holds it to the tile) at clip depth 1 (w 1): every
// texel written 1.0, the far plane, as the pass's clear value would, with
// the comparison `always` and no bias. No bindings, no vertex buffer, no
// fragment stage.

@vertex
fn vs_shadow_clear(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    var pts = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    return vec4<f32>(pts[vi], 1.0, 1.0);
}
