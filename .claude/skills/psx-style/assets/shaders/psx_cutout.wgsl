// psx_cutout.wgsl: psx_surface with 1-bit transparency, the PlayStation's
// "texel colour 0 is transparent" rule, for crossed-quad trees, fences,
// railings, banner fringes and anything whose holes are in the texture.
// Everything else is psx_surface's (read its notes first).
//
// What it reproduces, each as a knob (psx-style SKILL.md, "The signature"):
// - vertex snapping: every vertex lands on a grid of `snap_resolution`
//   screen pixels (the GTE had no sub-pixel precision), so the geometry
//   jitters as the camera moves;
// - affine texture mapping: the UV is interpolated in screen space, not in
//   perspective, so textures swim on large polygons near the camera;
// - nearest texels: no filtering, no mipmaps (import the texture with
//   compress/mode=lossless and mipmaps/generate=false);
// - Gouraud shading: the light is worked out per vertex, from one sun, a
//   hemisphere ambient and an optional baked tint, and interpolated.
//
// Notes for Hedra (verified with hedra 0.1.0):
// - `skip_vertex_transform`: VERTEX arrives in MODEL space and must be left
//   in VIEW space; NORMAL likewise. Snapping in view space (project, snap,
//   unproject) keeps the shadow, depth and SSR passes consistent, which
//   writing POSITION would not.
// - The shader's world frame is Z up: a scene vector (x, y, z) is
//   (x, -z, y) here. `sun_direction` is given in the scene's Y-up frame and
//   turned by `scene_to_frame` below.
// - There is no `noperspective` varying: the affine UV is carried as
//   (uv * w, w) and divided in fragment(), which undoes the perspective
//   correction the rasteriser applies; its 4th lane is the affine weight,
//   faded out near the camera (`affine_near`).
// - `unshaded` takes no Decal: a blob shadow is a mesh (psx_blob_shadow).
//   The engine's depth fog still applies (fog_disabled is not set).
shader_type spatial;
render_mode skip_vertex_transform, unshaded, cull_disabled, specular_disabled, shadows_disabled;

group_uniforms Texture;
uniform albedo_texture: texture_2d<f32> : source_color, filter_nearest, repeat_enable, hint_default_white;
uniform albedo: vec4<f32> : source_color = vec4<f32>(1.0, 1.0, 1.0, 1.0);
uniform uv_scale: vec2<f32> = vec2<f32>(1.0, 1.0);
uniform uv_offset: vec2<f32> = vec2<f32>(0.0, 0.0);
// UV scroll in UV units a second (conveyor belts, flags, water).
uniform uv_scroll: vec2<f32> = vec2<f32>(0.0, 0.0);
// Texels below this alpha are not drawn; there is no partial alpha.
uniform alpha_cut: f32 : hint_range(0.0, 1.0, 0.01) = 0.5;

group_uniforms Geometry;
// The grid vertices snap to, in screen pixels: the internal resolution for
// the authentic jitter, half of it for an exaggerated one, 0 to switch off.
uniform snap_resolution: vec2<f32> = vec2<f32>(320.0, 240.0);
// 1 is the PlayStation's screen-linear UV, 0 perspective-correct. Keep 1
// and subdivide large polygons near the camera instead (references/models.md).
uniform affine_strength: f32 : hint_range(0.0, 1.0, 0.05) = 1.0;
// Vertices nearer the camera than this (metres) fade to perspective-correct
// UVs: a triangle crossing the camera's plane has no meaningful affine UV
// (the PlayStation culled or subdivided those).
uniform affine_near: f32 : hint_range(0.0, 10.0, 0.1) = 1.0;

group_uniforms Light;
// Towards the sun, in the scene's Y-up frame (normalised here).
uniform sun_direction: vec3<f32> = vec3<f32>(0.4, 0.6, 0.5);
uniform sun_color: vec3<f32> : source_color = vec3<f32>(1.0, 0.86, 0.66);
// Hemisphere ambient: the sky's colour on faces turned up, the ground's
// bounce on faces turned down (on snow the bounce is bright).
uniform sky_ambient: vec3<f32> : source_color = vec3<f32>(0.42, 0.50, 0.66);
uniform ground_ambient: vec3<f32> : source_color = vec3<f32>(0.30, 0.30, 0.34);
// 0: smooth Gouraud. 2 to 8: the light in that many flat bands.
uniform light_bands: f32 : hint_range(0.0, 8.0, 1.0) = 0.0;
// Light added regardless of the sun (lit windows, neon, signs).
uniform emission: vec3<f32> : source_color = vec3<f32>(0.0, 0.0, 0.0);
// 1 lets the colour pass 1.0, as the PlayStation's 2x colour modulation did
// (a texel at 128 was "white"): bright highlights for the glow to catch.
uniform overbright: f32 : hint_range(1.0, 2.0, 0.05) = 1.0;

varying affine_uv: vec4<f32>;
varying gouraud: vec3<f32>;

fn scene_to_frame(v: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(v.x, -v.z, v.y);
}

fn snap_view(view_pos: vec4<f32>) -> vec4<f32> {
    if (snap_resolution.x <= 0.0) {
        return view_pos;
    }
    let clip = PROJECTION_MATRIX * view_pos;
    if (clip.w <= 0.0001) {
        return view_pos;
    }
    let half_res = snap_resolution * 0.5;
    let ndc = clip.xy / clip.w;
    let snapped = round(ndc * half_res) / half_res;
    let back = INV_PROJECTION_MATRIX * vec4<f32>(snapped * clip.w, clip.z, clip.w);
    return vec4<f32>(back.xyz / back.w, 1.0);
}

fn vertex() {
    // Gouraud, in the shader's world frame, from the model's normal.
    let n = normalize(MODEL_NORMAL_MATRIX * NORMAL);
    let sun = normalize(scene_to_frame(sun_direction));
    var diffuse = max(dot(n, sun), 0.0);
    if (light_bands >= 2.0) {
        diffuse = floor(diffuse * light_bands + 0.5) / light_bands;
    }
    let ambient = mix(ground_ambient, sky_ambient, n.z * 0.5 + 0.5);
    gouraud = (ambient + sun_color * diffuse) * COLOR.rgb * overbright + emission;

    // Snap in view space, then hand the view-space position back.
    let view_pos = snap_view(MODELVIEW_MATRIX * vec4<f32>(VERTEX, 1.0));
    VERTEX = view_pos.xyz;
    NORMAL = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);

    let uv = UV * uv_scale + uv_offset + uv_scroll * TIME;
    UV = uv;
    let w = (PROJECTION_MATRIX * view_pos).w;
    let weight = affine_strength * clamp((w - 0.25) / max(affine_near, 0.001), 0.0, 1.0);
    affine_uv = vec4<f32>(uv * w, w, weight);
}

fn fragment() {
    let affine = affine_uv.xy / max(affine_uv.z, 0.0001);
    let uv = mix(UV, affine, clamp(affine_uv.w, 0.0, 1.0));
    let texel = texture(albedo_texture, uv);
    ALBEDO = texel.rgb * albedo.rgb * gouraud;
    ALPHA = texel.a * albedo.a;
    ALPHA_SCISSOR_THRESHOLD = alpha_cut;
}
