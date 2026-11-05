// psx_blob_shadow.wgsl: the era's shadow, a dark disc under a character or a
// vehicle, on a PlaneMesh a few centimetres above the ground (a script
// places it on the ground under its owner and tilts it to the ground's
// normal). Multiplied over what is below it, in a few hard rings, its
// vertices snapped like everything else.
//
// Notes for Hedra: a Decal does not paint unshaded surfaces, and every
// psx_surface is unshaded, hence a mesh; `render_priority` 1 on the
// material keeps it after the opaque ground it darkens.
shader_type spatial;
render_mode skip_vertex_transform, blend_mul, unshaded, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled, specular_disabled;

uniform shadow_color: vec3<f32> : source_color = vec3<f32>(0.45, 0.48, 0.62);
// 0 when the owner is on the ground, towards 1 as it rises (a script or a
// binding writes it): the disc fades and shrinks.
uniform lift: f32 : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform rings: f32 : hint_range(1.0, 8.0, 1.0) = 3.0;
uniform snap_resolution: vec2<f32> = vec2<f32>(320.0, 240.0);

fn vertex() {
    let shrink = 1.0 - 0.5 * lift;
    var view_pos = MODELVIEW_MATRIX * vec4<f32>(VERTEX * shrink, 1.0);
    let clip = PROJECTION_MATRIX * view_pos;
    if (snap_resolution.x > 0.0 && clip.w > 0.0001) {
        let half_res = snap_resolution * 0.5;
        let snapped = round(clip.xy / clip.w * half_res) / half_res;
        let back = INV_PROJECTION_MATRIX * vec4<f32>(snapped * clip.w, clip.z, clip.w);
        view_pos = vec4<f32>(back.xyz / back.w, 1.0);
    }
    VERTEX = view_pos.xyz;
    NORMAL = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
}

fn fragment() {
    let r = length(UV - vec2<f32>(0.5)) * 2.0;
    let ring = floor(clamp(1.0 - r, 0.0, 1.0) * rings + 0.999) / rings;
    let strength = ring * (1.0 - lift);
    ALBEDO = mix(vec3<f32>(1.0), shadow_color, strength);
}
