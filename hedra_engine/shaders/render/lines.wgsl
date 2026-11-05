// The line shader of the renderer (src/render/**).
//
// The module is `common.wgsl` followed by the line code. rive-cli
// compiles each .wgsl file on its own (no includes, no runtime WGSL), so the
// common block below is inlined into both shaders/render/surface.wgsl and
// shaders/render/lines.wgsl. THE TWO COPIES MUST STAY IDENTICAL (between the
// BEGIN/END common markers).

// ---- BEGIN common.wgsl ----
// Shared uniforms and helpers, prepended to every shader.

struct Globals {
    view: mat4x4<f32>,
    proj: mat4x4<f32>,
    view_proj: mat4x4<f32>,
    camera_pos: vec4<f32>,   // xyz eye, w = 1 for orthographic
    viewport: vec4<f32>,     // width, height, 1/width, 1/height
    wire_color: vec4<f32>,
    select_color: vec4<f32>,
    active_color: vec4<f32>,
    grid: vec4<f32>,         // xyz fade center, w = fade extent
    params: vec4<u32>,       // shading mode, overlay flags, edit mode, matcap id
    fparams: vec4<f32>,      // depth pull, checker cells per UV unit, pixel scale (ssaa), w: 1 on the
                             // fallback target (target_color); a custom shader's globals hold TIME
                             // there instead, their fallback flag in params.z's bit 1 (gpu/custom.as)
};

struct ObjectU {
    model: mat4x4<f32>,
    normal: mat4x4<f32>,
    color: vec4<f32>,        // linear base color (material / random)
    params: vec4<u32>,       // selected, active, id (1-based), is edit object
    extra: vec4<u32>,        // OBJ_* bits, lightmap layer (surface.wgsl's OBJ_LIGHTMAP), layers with probes (its Probe), unused
    gi: array<vec4<f32>, 3>, // probe light, L1 SH: r, g, b, each c0 then c1 (surface.wgsl's OBJ_PROBE_GI)
    decals: vec4<u32>,       // the item's decals: indices into surface.wgsl's Decal pool, a byte each (x the first four, y the next), z how many, w its fog volumes (surface.wgsl's Fog pool entries + 1, a byte each)
    lights: vec4<u32>,       // the item's lights: entries of surface.wgsl's Lit pool, a byte each (x the first four, y the next), z how many, w how many reach it in all
};

const OBJ_HAS_WEIGHTS: u32 = 1u;
const OBJ_MIRRORED: u32 = 2u;       // a mirroring world matrix: the winding is reversed

@group(0) @binding(0) var<uniform> G: Globals;
@group(1) @binding(0) var<uniform> O: ObjectU;

const SHADE_SOLID: u32 = 0u;
const SHADE_MATCAP: u32 = 1u;
const SHADE_NORMALS: u32 = 2u;
const SHADE_FACE_ORIENT: u32 = 3u;
const SHADE_RANDOM: u32 = 4u;
const SHADE_MATERIAL: u32 = 5u;
const SHADE_UV_CHECKER: u32 = 6u;
const SHADE_WEIGHTS: u32 = 7u;
// The lit mode (surface.wgsl's `lit`): material mode's PBR under the frame's
// own lights and environment (the LitU block, surface.wgsl only).
const SHADE_LIT: u32 = 8u;
// Milestone 19: the baked light alone (frame.as SHADE_LIGHTMAP).
const SHADE_LIGHTMAP: u32 = 9u;
// Milestone 59: each surface in the colour of the lights reaching its item
// (frame.as SHADE_LIGHT_COUNT; ObjectU.lights.w).
const SHADE_LIGHT_COUNT: u32 = 10u;

const OV_SELECTION: u32 = 1u;
const OV_SEAMS: u32 = 2u;
const OV_SHARP: u32 = 4u;

// Element flags shared by surface vertices, edge and point instances.
const F_SELECTED: u32 = 1u;
const F_HIDDEN: u32 = 2u;
const F_SEAM: u32 = 4u;
const F_SHARP: u32 = 8u;
const F_MESH: u32 = 16u;      // color is resolved from flags + uniforms
const F_FADE: u32 = 32u;      // fade with distance from the grid center
const F_NO_PULL: u32 = 64u;   // do not pull towards the camera

fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c / 12.92;
    let hi = pow((c + vec3<f32>(0.055)) / 1.055, vec3<f32>(2.4));
    return select(hi, lo, c <= vec3<f32>(0.04045));
}

// Color of a mesh edge or vertex from its flags and the current mode.
fn element_color(flags: u32, fallback: vec4<f32>) -> vec4<f32> {
    if ((flags & F_MESH) == 0u) {
        return fallback;
    }
    let overlays = G.params.y;
    let edit_object = O.params.w == 1u;
    if ((flags & F_SEAM) != 0u && (overlays & OV_SEAMS) != 0u) {
        return vec4<f32>(srgb_to_linear(vec3<f32>(0.86, 0.0, 0.0)), 1.0);
    }
    if ((flags & F_SHARP) != 0u && (overlays & OV_SHARP) != 0u) {
        return vec4<f32>(srgb_to_linear(vec3<f32>(0.0, 0.85, 0.9)), 1.0);
    }
    if ((overlays & OV_SELECTION) != 0u) {
        if (edit_object) {
            if ((flags & F_SELECTED) != 0u) {
                return G.select_color;
            }
            return G.wire_color;
        }
        if (O.params.x == 1u) {
            return select(G.select_color, G.active_color, O.params.y == 1u);
        }
    }
    return G.wire_color;
}

// View-space position, optionally pulled towards the eye so lines and
// points sit on top of the surfaces they belong to.
fn to_view(p: vec3<f32>, pull: f32) -> vec4<f32> {
    var v = G.view * O.model * vec4<f32>(p, 1.0);
    v.z = v.z * (1.0 - pull);
    return v;
}

// The main pass renders into rgba16float but must behave like an 8-bit sRGB
// target, which clamps every fragment output to [0, 1] before blending and
// resolve; clamp the same way. On the rgba8unorm fallback target
// (`fparams.w == 1`, no half-float render targets) the sRGB encode an sRGB
// target would do in hardware happens here instead, so blending runs in
// sRGB space there.
fn linear_to_srgb(c: vec3<f32>) -> vec3<f32> {
    let lo = c * 12.92;
    let hi = 1.055 * pow(c, vec3<f32>(1.0 / 2.4)) - vec3<f32>(0.055);
    return select(hi, lo, c <= vec3<f32>(0.0031308));
}

fn target_color(c: vec4<f32>) -> vec4<f32> {
    let k = clamp(c, vec4<f32>(0.0), vec4<f32>(1.0));
    if (G.fparams.w > 0.5) {
        return vec4<f32>(linear_to_srgb(k.rgb), k.a);
    }
    return k;
}
// ---- END common.wgsl ----

// Lines and points as screen-space quads, so widths are in pixels on every
// backend. Six vertices per instance; the instance carries the geometry.

struct LineIn {
    @builtin(vertex_index) vi: u32,
    @location(0) a: vec3<f32>,
    @location(1) b: vec3<f32>,
    @location(2) color: vec4<f32>,
    @location(3) width: f32,
    @location(4) flags: u32,
};

struct LineOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) @interpolate(flat) color: vec4<f32>,
    @location(1) world: vec3<f32>,
    @location(2) @interpolate(flat) flags: u32,
};

const NEAR_W: f32 = 1e-4;

@vertex
fn vs_line(in: LineIn) -> LineOut {
    var out: LineOut;
    out.flags = in.flags;
    out.color = element_color(in.flags, in.color);
    let pull = select(G.fparams.x, 0.0, (in.flags & F_NO_PULL) != 0u);
    var ca = G.proj * to_view(in.a, pull);
    var cb = G.proj * to_view(in.b, pull);
    if (ca.w < NEAR_W && cb.w < NEAR_W) {
        out.clip = vec4<f32>(0.0, 0.0, 2.0, 1.0); // fully behind: clipped away
        return out;
    }
    if (ca.w < NEAR_W) {
        ca = mix(ca, cb, (NEAR_W - ca.w) / (cb.w - ca.w));
    } else if (cb.w < NEAR_W) {
        cb = mix(cb, ca, (NEAR_W - cb.w) / (ca.w - cb.w));
    }
    let half_vp = 0.5 * G.viewport.xy;
    let sa = ca.xy / ca.w * half_vp;
    let sb = cb.xy / cb.w * half_vp;
    var dir = sb - sa;
    let len = length(dir);
    if (len < 1e-5) {
        dir = vec2<f32>(1.0, 0.0);
    } else {
        dir = dir / len;
    }
    let nrm = vec2<f32>(-dir.y, dir.x);
    let hw = max(in.width, 0.6) * 0.5 * G.fparams.z;
    var table = array<u32, 6>(0u, 1u, 2u, 2u, 1u, 3u);
    let idx = table[in.vi];
    let at_b = (idx & 2u) != 0u;
    let side = select(-1.0, 1.0, (idx & 1u) != 0u);
    let base = select(sa, sb, at_b);
    let cap = select(-dir, dir, at_b) * hw;
    let px = base + cap + nrm * side * hw;
    let c = select(ca, cb, at_b);
    out.clip = vec4<f32>(px / half_vp * c.w, c.z, c.w);
    let p = select(in.a, in.b, at_b);
    out.world = (O.model * vec4<f32>(p, 1.0)).xyz;
    return out;
}

@fragment
fn fs_line(in: LineOut) -> @location(0) vec4<f32> {
    if ((in.flags & F_HIDDEN) != 0u) {
        discard;
    }
    var c = in.color;
    if ((in.flags & F_FADE) != 0u) {
        let d = length(in.world.xy - G.grid.xy);
        c.a = c.a * (1.0 - smoothstep(G.grid.w * 0.45, G.grid.w, d));
    }
    return target_color(c);
}

struct PointIn {
    @builtin(vertex_index) vi: u32,
    @location(0) pos: vec3<f32>,
    @location(1) size: f32,
    @location(2) color: vec4<f32>,
    @location(3) flags: u32,
};

struct PointOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) @interpolate(flat) color: vec4<f32>,
    @location(1) local: vec2<f32>,
    @location(2) @interpolate(flat) flags: u32,
};

@vertex
fn vs_point(in: PointIn) -> PointOut {
    var out: PointOut;
    out.flags = in.flags;
    out.color = element_color(in.flags, in.color);
    let pull = select(G.fparams.x, 0.0, (in.flags & F_NO_PULL) != 0u);
    let c = G.proj * to_view(in.pos, pull);
    if (c.w < NEAR_W) {
        out.clip = vec4<f32>(0.0, 0.0, 2.0, 1.0);
        out.local = vec2<f32>(0.0);
        return out;
    }
    var table = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(-1.0, 1.0),
        vec2<f32>(-1.0, 1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0));
    let corner = table[in.vi];
    let half_vp = 0.5 * G.viewport.xy;
    let r = max(in.size, 1.0) * 0.5 * G.fparams.z + 0.5;
    let px = c.xy / c.w * half_vp + corner * r;
    out.clip = vec4<f32>(px / half_vp * c.w, c.z, c.w);
    out.local = corner;
    return out;
}

@fragment
fn fs_point(in: PointOut) -> @location(0) vec4<f32> {
    if ((in.flags & F_HIDDEN) != 0u) {
        discard;
    }
    let d = length(in.local);
    if (d > 1.0) {
        discard;
    }
    var c = in.color;
    c.a = c.a * (1.0 - smoothstep(0.75, 1.0, d));
    return target_color(c);
}
