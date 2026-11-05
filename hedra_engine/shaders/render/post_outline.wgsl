// The selection outline and the sRGB encode of one view, at the render
// target size (size * ssaa).
//
// The outline is a function of the resolved color and the object ids. rive
// has no readback, so this pass computes it on the GPU and writes the final
// sRGB bytes (src/render/gpu/view.as, pass P3):
//
// - `mark(p)` is set when (a) p's object is selected and some 4-neighbour id
//   differs (out of bounds counts as id 0), or (b) p's object is not
//   selected and the first 4-neighbour n (left, right, up, down) with a
//   selected object other than p's exists. Its color is ACTIVE when that
//   object is the active one, else SELECT.
// - Each mark paints a (2r+1)^2 square (r = ssaa / 2) in scan order, later
//   marks overwriting earlier ones, so pixel q takes the color of the mark
//   with the greatest (y, x) within Chebyshev distance r of q, and keeps the
//   encoded scene color when there is none.
//
// The CPU reference is `outline` in engine/src/authoring/model_view/scene_view.as.

struct OutlineU {
    // want_outline (0/1), r, encode (1: `color` holds linear values),
    // straight (1: a transparent background, see fs_outline).
    params: vec4<u32>,
    // `rgba_bytes(SELECT_COLOR, 1)` / 255 and `rgba_bytes(ACTIVE_COLOR, 1)` / 255.
    select_color: vec4<f32>,
    active_color: vec4<f32>,
};

@group(0) @binding(0) var<uniform> U: OutlineU;
// The resolved main pass (rgba16float linear, or rgba8unorm already encoded).
@group(0) @binding(1) var color: texture_2d<f32>;
// The id pass (rgba8unorm: 24-bit object index in rgb, selected/active bits in a).
@group(0) @binding(2) var ids: texture_2d<f32>;

@vertex
fn vs_full(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    var pts = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    return vec4<f32>(pts[vi], 0.0, 1.0);
}

fn to_bytes(v: vec4<f32>) -> vec4<u32> {
    return vec4<u32>(round(clamp(v, vec4<f32>(0.0), vec4<f32>(1.0)) * 255.0));
}

// The object index at p (0 outside the image or where nothing was drawn).
fn id_at(p: vec2<i32>, size: vec2<i32>) -> u32 {
    if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y) {
        return 0u;
    }
    let b = to_bytes(textureLoad(ids, p, 0));
    return b.x | (b.y << 8u) | (b.z << 16u);
}

// The selected (1) / active (2) bits of the object at p.
fn bits_at(p: vec2<i32>, size: vec2<i32>) -> u32 {
    if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y) {
        return 0u;
    }
    return to_bytes(textureLoad(ids, p, 0)).w;
}

// `sel(id)`: a drawn object that is a selected mesh.
fn sel(id: u32, bits: u32) -> bool {
    return id != 0u && (bits & 1u) != 0u;
}

// 0 = no mark at p, 1 = SELECT, 2 = ACTIVE.
fn mark(p: vec2<i32>, size: vec2<i32>) -> u32 {
    let id = id_at(p, size);
    let bits = bits_at(p, size);
    var nb = array<vec2<i32>, 4>(
        p + vec2<i32>(-1, 0), p + vec2<i32>(1, 0), p + vec2<i32>(0, -1), p + vec2<i32>(0, 1));
    if (sel(id, bits)) {
        for (var k = 0; k < 4; k++) {
            if (id_at(nb[k], size) != id) {
                return select(1u, 2u, (bits & 2u) != 0u);
            }
        }
        return 0u;
    }
    for (var k = 0; k < 4; k++) {
        let n = id_at(nb[k], size);
        let nbits = bits_at(nb[k], size);
        if (sel(n, nbits) && n != id) {
            return select(1u, 2u, (nbits & 2u) != 0u);
        }
    }
    return 0u;
}

fn linear_to_srgb(c: vec3<f32>) -> vec3<f32> {
    let lo = c * 12.92;
    let hi = 1.055 * pow(c, vec3<f32>(1.0 / 2.4)) - vec3<f32>(0.055);
    return select(hi, lo, c <= vec3<f32>(0.0031308));
}

@fragment
fn fs_outline(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let q = vec2<i32>(floor(pos.xy));
    let size = vec2<i32>(textureDimensions(color));
    if (U.params.x == 1u) {
        let r = i32(U.params.y);
        // Scan order is row-major, so the last mark to paint q is the one
        // with the greatest (y, x): search from the bottom-right corner.
        for (var dy = r; dy >= -r; dy--) {
            for (var dx = r; dx >= -r; dx--) {
                let p = q + vec2<i32>(dx, dy);
                if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y) {
                    continue;
                }
                let m = mark(p, size);
                if (m == 1u) {
                    return U.select_color;
                }
                if (m == 2u) {
                    return U.active_color;
                }
            }
        }
    }
    var c = clamp(textureLoad(color, q, 0), vec4<f32>(0.0), vec4<f32>(1.0));
    // Over a transparent clear the resolve leaves premultiplied colour (an
    // edge texel a quarter covered holds a quarter of its colour), and the
    // picture is used as straight alpha (a PNG, a ViewportTexture): divide
    // before the encode, or every edge comes out dark.
    if (U.params.w == 1u && c.a > 0.0 && c.a < 1.0) {
        c = vec4<f32>(min(c.rgb / max(c.a, 1e-6), vec3<f32>(1.0)), c.a);
    }
    if (U.params.z == 1u) {
        return vec4<f32>(linear_to_srgb(c.rgb), c.a);
    }
    return c;
}
