// psx_sprite.wgsl: camera-facing sprites for CPUParticles3D (snow spray,
// powder puffs, sparks, confetti), turned in the vertex stage, with a
// flipbook and 1-bit alpha. The mesh is the emitter's QuadMesh (1 x 1);
// the particle's scale is its transform's.
//
// Notes for Hedra (verified with hedra 0.1.0):
// - A ShaderMaterial is not turned by billboard_mode (only a
//   StandardMaterial3D's is), so the quad is turned here: its corners are
//   laid out in view space around the particle's centre.
// - There is no flipbook (anim_speed / hframes are not in the format) and
//   no particle age in a shader. The age rides in COLOR.a: give the
//   emitter a color_ramp whose alpha falls from 1 at birth to 0 at death;
//   the frame is chosen from it and the sprite's own alpha is the
//   texture's (cut at 0.5).
shader_type spatial;
render_mode skip_vertex_transform, unshaded, cull_disabled, specular_disabled, shadows_disabled;

uniform sprite_sheet: texture_2d<f32> : source_color, filter_nearest, repeat_disable, hint_default_white;
// Frames in the sheet, left to right then top to bottom.
uniform frames_x: f32 = 4.0;
uniform frames_y: f32 = 1.0;
uniform tint: vec3<f32> : source_color = vec3<f32>(1.0, 1.0, 1.0);
uniform alpha_cut: f32 : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform snap_resolution: vec2<f32> = vec2<f32>(320.0, 240.0);

varying frame_uv: vec2<f32>;

fn vertex() {
    let scale = length(MODEL_MATRIX[0].xyz);
    var view_pos = MODELVIEW_MATRIX * vec4<f32>(0.0, 0.0, 0.0, 1.0);
    view_pos = vec4<f32>(view_pos.xyz + vec3<f32>(VERTEX.xy * scale, 0.0), 1.0);
    let clip = PROJECTION_MATRIX * view_pos;
    if (snap_resolution.x > 0.0 && clip.w > 0.0001) {
        let half_res = snap_resolution * 0.5;
        let snapped = round(clip.xy / clip.w * half_res) / half_res;
        let back = INV_PROJECTION_MATRIX * vec4<f32>(snapped * clip.w, clip.z, clip.w);
        view_pos = vec4<f32>(back.xyz / back.w, 1.0);
    }
    VERTEX = view_pos.xyz;
    NORMAL = vec3<f32>(0.0, 0.0, 1.0);
    let count = max(frames_x * frames_y, 1.0);
    let frame = min(floor((1.0 - clamp(COLOR.a, 0.0, 1.0)) * count), count - 1.0);
    let cell = vec2<f32>(frame % frames_x, floor(frame / frames_x));
    frame_uv = (cell + UV) / vec2<f32>(frames_x, frames_y);
}

fn fragment() {
    let texel = texture(sprite_sheet, frame_uv);
    ALBEDO = texel.rgb * tint * COLOR.rgb;
    ALPHA = texel.a;
    ALPHA_SCISSOR_THRESHOLD = alpha_cut;
}
