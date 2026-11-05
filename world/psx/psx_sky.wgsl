// psx_sky.wgsl: a PlayStation sky, the material of a large inverted sphere
// (or a SphereMesh with flip_faces) centred on the camera each frame. A
// vertical gradient in a few hard bands, a sun disc with a halo, and an
// optional horizon strip (mountains, a skyline) sampled by azimuth with
// nearest texels and 1-bit alpha, as the era's skies were: a painted
// backdrop, not a physical sky.
//
// Notes for Hedra (verified with hedra 0.1.0):
// - world_vertex_coords puts VERTEX in the shader's world frame, which is
//   Z up (scene (x, y, z) is (x, -z, y) here); `sun_direction` is given in
//   the scene's Y-up frame and turned by scene_to_frame.
// - Draw it unshaded, unfogged, without depth writes: the Environment's
//   depth fog colour should equal `horizon` so far geometry melts into it.
shader_type spatial;
render_mode world_vertex_coords, unshaded, cull_front, depth_draw_never, fog_disabled, shadows_disabled, specular_disabled;

group_uniforms Gradient;
uniform zenith: vec3<f32> : source_color = vec3<f32>(0.24, 0.40, 0.78);
uniform horizon: vec3<f32> : source_color = vec3<f32>(0.80, 0.86, 0.96);
uniform below: vec3<f32> : source_color = vec3<f32>(0.80, 0.86, 0.96);
// The gradient in this many flat bands (0: smooth; the present pass
// dithers it either way).
uniform bands: f32 : hint_range(0.0, 32.0, 1.0) = 12.0;
// Bends the gradient towards the horizon (1 linear, above 1 a thinner haze).
uniform curve: f32 : hint_range(0.2, 4.0, 0.05) = 1.6;

group_uniforms Sun;
uniform sun_direction: vec3<f32> = vec3<f32>(0.4, 0.25, 0.5);
uniform sun_color: vec3<f32> : source_color = vec3<f32>(1.0, 0.92, 0.70);
// Angular radius of the disc and of the halo, in degrees.
uniform sun_size: f32 : hint_range(0.1, 10.0, 0.1) = 2.2;
uniform halo_size: f32 : hint_range(0.0, 60.0, 0.5) = 18.0;
uniform halo_strength: f32 : hint_range(0.0, 2.0, 0.05) = 0.6;

group_uniforms Horizon;
// A strip wrapped round the horizon (u: azimuth, v: up), alpha cut out.
uniform horizon_texture: texture_2d<f32> : source_color, filter_nearest, repeat_enable, hint_default_transparent;
// How many times the strip wraps round, and the band of elevation it
// covers, in degrees (bottom, top).
uniform horizon_repeat: f32 = 2.0;
uniform horizon_band: vec2<f32> = vec2<f32>(-2.0, 14.0);
uniform horizon_tint: vec3<f32> : source_color = vec3<f32>(1.0, 1.0, 1.0);

varying dir: vec3<f32>;

fn scene_to_frame(v: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(v.x, -v.z, v.y);
}

fn vertex() {
    dir = VERTEX - NODE_POSITION_WORLD;
}

fn fragment() {
    let d = normalize(dir);
    let up = d.z;
    var t = pow(clamp(up, 0.0, 1.0), 1.0 / curve);
    if (bands >= 2.0) {
        t = floor(t * bands) / bands;
    }
    var col = mix(horizon, zenith, t);
    if (up < 0.0) {
        col = mix(horizon, below, clamp(-up * 8.0, 0.0, 1.0));
    }
    let sun = normalize(scene_to_frame(sun_direction));
    let angle = degrees(acos(clamp(dot(d, sun), -1.0, 1.0)));
    let halo = halo_strength * pow(clamp(1.0 - angle / max(halo_size, 0.001), 0.0, 1.0), 2.0);
    col = col + sun_color * halo;
    if (angle < sun_size) {
        col = sun_color * 1.4;
    }
    let elevation = degrees(asin(clamp(up, -1.0, 1.0)));
    let v = (elevation - horizon_band.x) / max(horizon_band.y - horizon_band.x, 0.001);
    let u = (atan2(d.y, d.x) / TAU + 0.5) * horizon_repeat;
    let strip = texture(horizon_texture, vec2<f32>(u, 1.0 - clamp(v, 0.0, 1.0)));
    if (v >= 0.0 && v <= 1.0 && strip.a >= 0.5) {
        col = strip.rgb * horizon_tint;
    }
    ALBEDO = col;
}
