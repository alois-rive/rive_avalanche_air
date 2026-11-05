// The live capture's passes of a reflection probe (milestone 20,
// Godot's ReflectionProbe): gpu/probes.as runs them inside the host's draw,
// after the renderer has drawn the probe's six views
// (engine/src/render/probe/data.as `probeFaceCamera`), each into an
// N x N picture (N = PROBE_FACE_SIZE). Every pass draws one full-screen
// triangle into one mip of one texture, through a viewport (and scissor)
// to the rectangle it writes, loading what is around it:
//
//   fs_probe_place   picture of face f -> face f of level 0 of the scratch
//                    chain (6N x N, PROBE_LEVELS mips), mirrored left to
//                    right (a camera sees a cube face from inside);
//   fs_probe_down    scratch level m from level m - 1, the mean of each
//                    2 x 2 (sky.as CubeLevel.half; the faces' sizes are
//                    powers of two, so a 2 x 2 never straddles two faces);
//   fs_probe_copy    a level of the same size into the atlas row (scratch
//                    level 0 into level 0, or a baked cube's level from
//                    its upload texture);
//   fs_probe_filter  atlas row level m >= 1 from the scratch chain: sky.as
//                    `prefilter` ported, the GGX lobe of roughness
//                    m / (levels - 1) around each texel's direction with
//                    the same 32 Hammersley samples, weights, source levels
//                    (filtered importance sampling) and tangent frame,
//                    worked out on the CPU into FilterU, each tap bilinear
//                    inside its face and clamped to it.
//
// A face's texel (x, y) of level m in a texture of six faces across is at
// (f * n + x, y) with n = N >> m; in the atlas, row r adds r * n to y. So
// the passes find the face and texel from the fragment's position alone.

struct FilterU {                    // 1040 bytes (layouts.as ProbeFilterUniform)
    info: vec4<f32>,                // x 1 / weight sum (0: none), y samples used, z level drawn, w levels
    samples: array<vec4<f32>, 64>,  // 2i: offset from N (N +z) and first level; 2i + 1: its two weights
};

@group(0) @binding(0) var<uniform> U: FilterU;
@group(0) @binding(1) var t_src: texture_2d<f32>;

// One triangle over the viewport.
@vertex
fn vs_probe(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    var pts = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    return vec4<f32>(pts[vi], 0.0, 1.0);
}

// The picture of one face (N x N) into that face of scratch level 0, its
// column x from the picture's column N - 1 - x (data.as probeFaceCamera).
@fragment
fn fs_probe_place(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let n = textureDimensions(t_src).y;
    let p = vec2<u32>(pos.xy);
    let x = p.x % n;
    return vec4<f32>(textureLoad(t_src, vec2<u32>(n - 1u - x, p.y % n), 0).rgb, 1.0);
}

// A level from the one twice its size (t_src: that level's view alone).
@fragment
fn fs_probe_down(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let p = vec2<u32>(pos.xy) * 2u;
    let c = textureLoad(t_src, p, 0).rgb + textureLoad(t_src, p + vec2<u32>(1u, 0u), 0).rgb
        + textureLoad(t_src, p + vec2<u32>(0u, 1u), 0).rgb + textureLoad(t_src, p + vec2<u32>(1u, 1u), 0).rgb;
    return vec4<f32>(c * 0.25, 1.0);
}

// A level of six faces across (t_src: that level's view alone) into the
// same level of an atlas row.
@fragment
fn fs_probe_copy(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let n = textureDimensions(t_src).y;
    let p = vec2<u32>(pos.xy);
    return vec4<f32>(textureLoad(t_src, vec2<u32>(p.x, p.y % n), 0).rgb, 1.0);
}

// sky.as cubeDir: the unit direction through (u, v) of face `face`.
fn cube_dir(face: u32, u: f32, v: f32) -> vec3<f32> {
    let sc = u * 2.0 - 1.0;
    let tc = v * 2.0 - 1.0;
    var d: vec3<f32>;
    switch (face) {
        case 0u: { d = vec3<f32>(1.0, -tc, -sc); }
        case 1u: { d = vec3<f32>(-1.0, -tc, sc); }
        case 2u: { d = vec3<f32>(sc, 1.0, tc); }
        case 3u: { d = vec3<f32>(sc, -1.0, -tc); }
        case 4u: { d = vec3<f32>(sc, -tc, 1.0); }
        default: { d = vec3<f32>(-sc, -tc, -1.0); }
    }
    return normalize(d);
}

// sky.as cubeFaceUv (surface.wgsl's probe_face_uv): x the face, y u, z v.
fn face_uv(d: vec3<f32>) -> vec3<f32> {
    let a = abs(d);
    var face: f32;
    var ma: f32;
    var sc: f32;
    var tc: f32;
    if (a.x >= a.y && a.x >= a.z) {
        ma = a.x;
        if (d.x >= 0.0) {
            face = 0.0; sc = -d.z; tc = -d.y;
        } else {
            face = 1.0; sc = d.z; tc = -d.y;
        }
    } else if (a.y >= a.z) {
        ma = a.y;
        if (d.y >= 0.0) {
            face = 2.0; sc = d.x; tc = d.z;
        } else {
            face = 3.0; sc = d.x; tc = -d.z;
        }
    } else {
        ma = a.z;
        if (d.z >= 0.0) {
            face = 4.0; sc = d.x; tc = -d.y;
        } else {
            face = 5.0; sc = -d.x; tc = -d.y;
        }
    }
    return vec3<f32>(face, (sc / ma + 1.0) * 0.5, (tc / ma + 1.0) * 0.5);
}

// Level `level` of the scratch chain at `fuv`: bilinear within the face,
// clamped to its texels (sky.as CubeLevel.sampleFace), `base` the chain's
// face size at level 0.
fn tap(level: u32, fuv: vec3<f32>, base: u32) -> vec3<f32> {
    let size = max(base >> level, 1u);
    let top = f32(size - 1u);
    let px = clamp(fuv.y * f32(size) - 0.5, 0.0, top);
    let py = clamp(fuv.z * f32(size) - 0.5, 0.0, top);
    let x0 = u32(px);
    let y0 = u32(py);
    let x1 = min(x0 + 1u, size - 1u);
    let y1 = min(y0 + 1u, size - 1u);
    let fx = px - f32(x0);
    let fy = py - f32(y0);
    let off = u32(fuv.x) * size;
    let c00 = textureLoad(t_src, vec2<u32>(off + x0, y0), level).rgb;
    let c10 = textureLoad(t_src, vec2<u32>(off + x1, y0), level).rgb;
    let c01 = textureLoad(t_src, vec2<u32>(off + x0, y1), level).rgb;
    let c11 = textureLoad(t_src, vec2<u32>(off + x1, y1), level).rgb;
    return c00 * ((1.0 - fx) * (1.0 - fy)) + c10 * (fx * (1.0 - fy)) + c01 * ((1.0 - fx) * fy) + c11 * (fx * fy);
}

// Level U.info.z of an atlas row from the scratch chain (t_src: every
// level): sky.as prefilter for that level, sample for sample.
@fragment
fn fs_probe_filter(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let base = textureDimensions(t_src, 0).y;
    let m = u32(U.info.z);
    let n = max(base >> m, 1u);
    let p = vec2<u32>(pos.xy);
    let face = p.x / n;
    let x = p.x % n;
    let y = p.y % n;
    let inv = 1.0 / f32(n);
    let nd = cube_dir(face, (f32(x) + 0.5) * inv, (f32(y) + 0.5) * inv);
    var up = vec3<f32>(0.0, 0.0, 1.0);
    if (abs(nd.z) > 0.999) {
        up = vec3<f32>(1.0, 0.0, 0.0);
    }
    let t = normalize(cross(up, nd));
    let b = cross(nd, t);
    if (!(U.info.x > 0.0)) {
        return vec4<f32>(tap(0u, face_uv(nd), base), 1.0);
    }
    var sum = vec3<f32>(0.0);
    let used = u32(U.info.y);
    for (var i = 0u; i < used; i++) {
        let s = U.samples[i * 2u];
        let w = U.samples[i * 2u + 1u];
        let fuv = face_uv(t * s.x + b * s.y + nd * s.z);
        let first = u32(s.w);
        sum += tap(first, fuv, base) * w.x;
        if (w.y > 0.0) {
            sum += tap(first + 1u, fuv, base) * w.y;
        }
    }
    return vec4<f32>(sum * U.info.x, 1.0);
}
