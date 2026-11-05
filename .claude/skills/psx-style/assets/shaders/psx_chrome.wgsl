// psx_chrome.wgsl: the era's chrome and metal, a reflection map looked up
// per VERTEX from the view-space normal (a sphere map, the PlayStation's
// "environment mapping" of title logos, cars and sunglasses), so it swims
// across large faces as the original did. Pair it with a matcap texture: a
// sky band above, a dark horizon line, warm ground below, a hot highlight.
//
// Notes for Hedra: see psx_surface.wgsl (view-space snapping under
// skip_vertex_transform; no noperspective varying, hence uv * w).
shader_type spatial;
render_mode skip_vertex_transform, unshaded, cull_back, specular_disabled, shadows_disabled;

uniform matcap: texture_2d<f32> : source_color, filter_nearest, repeat_disable, hint_default_white;
uniform tint: vec3<f32> : source_color = vec3<f32>(1.0, 1.0, 1.0);
// The base texture under the reflection (paint under clear coat, letters).
uniform albedo_texture: texture_2d<f32> : source_color, filter_nearest, repeat_enable, hint_default_white;
uniform reflectivity: f32 : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform snap_resolution: vec2<f32> = vec2<f32>(320.0, 240.0);

varying env_uv: vec4<f32>;
varying base_uv: vec3<f32>;

fn vertex() {
    var view_pos = MODELVIEW_MATRIX * vec4<f32>(VERTEX, 1.0);
    let clip = PROJECTION_MATRIX * view_pos;
    if (snap_resolution.x > 0.0 && clip.w > 0.0001) {
        let half_res = snap_resolution * 0.5;
        let snapped = round(clip.xy / clip.w * half_res) / half_res;
        let back = INV_PROJECTION_MATRIX * vec4<f32>(snapped * clip.w, clip.z, clip.w);
        view_pos = vec4<f32>(back.xyz / back.w, 1.0);
    }
    VERTEX = view_pos.xyz;
    NORMAL = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
    let w = max((PROJECTION_MATRIX * view_pos).w, 0.0001);
    let m = NORMAL.xy * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5);
    env_uv = vec4<f32>(m * w, w, 0.0);
    base_uv = vec3<f32>(UV * w, w);
}

fn fragment() {
    let env = texture(matcap, env_uv.xy / env_uv.z).rgb * tint;
    let base = texture(albedo_texture, base_uv.xy / base_uv.z).rgb;
    ALBEDO = mix(base, env, reflectivity);
}
