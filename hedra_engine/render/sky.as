// The sky and its light on the CPU (milestone 11): Godot's
// ProceduralSkyMaterial and PanoramaSkyMaterial as functions of a
// direction, the image-based light built from them once per environment
// (a cube map of radiance prefiltered by roughness, and the irradiance as
// nine spherical harmonics), its cache, and the sky block the shader reads
// (layouts.as `SkyUniform`). Pure: no GPU, so a Tests suite checks the
// numbers (editor/program/tests/render/sky_test.as), and the renderer
// uploads what `IblCache.get` returns (gpu/environment.as).
//
// Conventions every piece shares (surface.wgsl follows them too):
//
// - Sky space is Godot's: Y up, -Z forward. `SkyDesc.toSky` takes a frame
//   direction there, sky_rotation included.
// - Cube faces are in the order +X, -X, +Y, -Y, +Z, -Z, each `size` texels
//   square, row 0 at the top (v = 0), the layout every GPU API samples a
//   cube with: `cubeDir` and `cubeFaceUv` are each other's inverse.
// - A panorama is equirectangular as Godot reads it (sky.glsl's
//   SKY_COORDS): u = atan2(x, -z) / (2 pi) wrapped into 0..1 across, so
//   -Z is the image's left and right edge and +Z its middle, v = acos(y) /
//   pi down.
// - The radiance map has `radianceLevels(size)` mips, down to 4 texels;
//   mip m holds the sky prefiltered with GGX for perceptual roughness m /
//   (levels - 1), so the shader reads roughness r at lod r * (levels - 1).
//   Mip 0 is the sky itself.
// - The irradiance is kept as SKY_SH_COEFFS spherical harmonics already
//   convolved with the cosine lobe and divided by pi (`shIrradiance`): a
//   sky of constant radiance L gives L, so a Lambert surface of albedo a
//   under it shows a * L, as under a flat ambient colour L.
// - The map and the harmonics hold the sky without its sun discs: the
//   directional light already lights and highlights the scene, so a disc
//   in the map would count the sun twice (Godot's does), and without it
//   moving a light never rebuilds the map. background_energy_multiplier
//   and ambient_light_energy scale the light when it is read, not baked,
//   for the same reason.

import { clock } from "rive/os";
import { hexU64 } from "../base/fmt";
import { Vec2, Vec3, Vec4, acosf, atan2f, cosf, log2f, powf, sinf, toRadians } from "../base/vecmath";
import {
    EnvironmentDesc, FOG_DEPTH, REFLECT_BACKGROUND, REFLECT_DISABLED, REFLECT_SKY,
    RenderFrame, SHADE_LIT, SKY_NONE, SKY_PANORAMA, SKY_PROCEDURAL, SkyDesc,
} from "./frame";
import { prepareLights } from "./light_select";
import { FloatImage } from "./hdr";
import {
    SKY_AMBIENT_SKY, SKY_DRAW_PANORAMA, SKY_DRAW_PROCEDURAL, SKY_FOG, SKY_FOG_DEPTH, SKY_IBL, SKY_PANORAMA_FILTER,
    SKY_REFLECT_OFF, SKY_REFLECT_RADIANCE, SKY_SH_COEFFS, SKY_SUNS, SkySunUniform, SkyUniform, U32x4,
} from "./gpu/layouts";

const PI: f32 = 3.14159265358979323846;

// The reflection map's face size: Sky.radiance_size rounded down to a power
// of two within these bounds. The prefilter runs on the CPU once per
// environment, and 128 keeps it to about 0.25 s (Apple M5 Pro); roughness 0
// reflections read the 128 texels (the drawn background is sampled per
// pixel, at full resolution).
export const RADIANCE_MIN_SIZE: u32 = 32;
export const RADIANCE_MAX_SIZE: u32 = 128;
// The smallest mip of the map.
export const RADIANCE_SMALLEST: u32 = 4;
// GGX samples per texel of a prefiltered mip (filtered importance sampling
// reads a blurrier source mip where samples are sparse, so few are enough).
export const PREFILTER_SAMPLES: i32 = 32;
// The level the harmonics are projected from (or the base, if smaller).
export const SH_SOURCE_SIZE: u32 = 32;
// The widest panorama uploaded (halved until it fits this and the device).
export const PANORAMA_MAX_WIDTH: u32 = 4096;

// Sky.radiance_size (texels) as drawn: the largest power of two not above
// it, within RADIANCE_MIN_SIZE..RADIANCE_MAX_SIZE.
export function radianceSize(requested: u32): u32 {
    let s: u32 = RADIANCE_MIN_SIZE;
    while (s * 2 <= requested && s * 2 <= RADIANCE_MAX_SIZE) s *= 2;
    return s;
}

// The mips of a map of face `size`: size, size / 2, ... down to
// RADIANCE_SMALLEST (128: 6 levels; 32: 4).
export function radianceLevels(size: u32): u32 {
    let n: u32 = 1;
    let s = size;
    while (s > RADIANCE_SMALLEST) {
        s /= 2;
        n++;
    }
    return n;
}

// The unit direction through (u, v) of cube face `face` (0..5 as in the
// header; u, v in 0..1, v down). A texel (x, y) of a face of `size` is at
// u = (x + 0.5) / size, v = (y + 0.5) / size.
export function cubeDir(face: i32, u: f32, v: f32): Vec3 {
    const sc = u * 2 - 1;
    const tc = v * 2 - 1;
    let d: Vec3;
    switch (face) {
        case 0: d = Vec3(1, -tc, -sc); break;
        case 1: d = Vec3(-1, -tc, sc); break;
        case 2: d = Vec3(sc, 1, tc); break;
        case 3: d = Vec3(sc, -1, -tc); break;
        case 4: d = Vec3(sc, -tc, 1); break;
        default: d = Vec3(-sc, -tc, -1); break;
    }
    return d.normalize();
}

// Where direction `d` (any length but 0) lands on the cube: x the face
// (0..5, as an f32), y u and z v (0..1). The major axis picks the face; a
// tie goes to X, then Y, as the GPU's selection does for the exact
// diagonal (either face holds the same texel there).
export function cubeFaceUv(d: Vec3): Vec3 {
    const ax = Mathf.abs(d.x);
    const ay = Mathf.abs(d.y);
    const az = Mathf.abs(d.z);
    let face: i32;
    let ma: f32;
    let sc: f32;
    let tc: f32;
    if (ax >= ay && ax >= az) {
        ma = ax;
        if (d.x >= 0) {
            face = 0; sc = -d.z; tc = -d.y;
        } else {
            face = 1; sc = d.z; tc = -d.y;
        }
    } else if (ay >= az) {
        ma = ay;
        if (d.y >= 0) {
            face = 2; sc = d.x; tc = d.z;
        } else {
            face = 3; sc = d.x; tc = -d.z;
        }
    } else {
        ma = az;
        if (d.z >= 0) {
            face = 4; sc = d.x; tc = -d.y;
        } else {
            face = 5; sc = -d.x; tc = -d.y;
        }
    }
    return Vec3(<f32>face, (sc / ma + 1) * 0.5, (tc / ma + 1) * 0.5);
}

// Where a sky-space direction lands on an equirectangular panorama (see
// the header): u 0..1 across (wrapping), v 0..1 down.
export function panoramaUv(d: Vec3): Vec2 {
    const n = d.normalize();
    const a = atan2f(n.x, -n.z) / (2 * PI);
    const u = a - Mathf.floor(a);
    const v = acosf(Mathf.max(-1, Mathf.min(1, n.y))) / PI;
    return Vec2(u, v);
}

// The panorama's colour in direction `d`: bilinear between the four
// nearest texel centres (wrapping across, clamped at the poles) when
// `filter`, else the texel `d` falls in.
export function samplePanorama(img: FloatImage, d: Vec3, filter: bool): Vec3 {
    const w = <i32>img.width;
    const h = <i32>img.height;
    if (w == 0 || h == 0) return Vec3(0, 0, 0);
    const uv = panoramaUv(d);
    if (!filter) {
        const tx = wrapIndex(<i32>Mathf.floor(uv.x * <f32>w), w);
        const ty = clampIndex(<i32>Mathf.floor(uv.y * <f32>h), h);
        return img.get(<u32>tx, <u32>ty);
    }
    // Texel centres sit at half-texel offsets, so the four around (x, y)
    // start at floor(x) once the half is taken off.
    const x = uv.x * <f32>w - 0.5;
    const y = uv.y * <f32>h - 0.5;
    const fx0 = Mathf.floor(x);
    const fy0 = Mathf.floor(y);
    const tx = x - fx0;
    const ty = y - fy0;
    const x0 = wrapIndex(<i32>fx0, w);
    const x1 = wrapIndex(<i32>fx0 + 1, w);
    const y0 = clampIndex(<i32>fy0, h);
    const y1 = clampIndex(<i32>fy0 + 1, h);
    // Scalars and direct reads: the IBL bake calls this for every texel of
    // its base level.
    const data = img.data;
    const i00 = (y0 * w + x0) * 3;
    const i10 = (y0 * w + x1) * 3;
    const i01 = (y1 * w + x0) * 3;
    const i11 = (y1 * w + x1) * 3;
    const w11 = tx * ty;
    const w10 = tx - w11;
    const w01 = ty - w11;
    const w00 = 1 - w10 - w01 - w11;
    return Vec3(
        data[i00] * w00 + data[i10] * w10 + data[i01] * w01 + data[i11] * w11,
        data[i00 + 1] * w00 + data[i10 + 1] * w10 + data[i01 + 1] * w01 + data[i11 + 1] * w11,
        data[i00 + 2] * w00 + data[i10 + 2] * w10 + data[i01 + 2] * w01 + data[i11 + 2] * w11,
    );
}

// `i` modulo `n`, never negative: the panorama's columns wrap around.
function wrapIndex(i: i32, n: i32): i32 {
    const r = i % n;
    return r < 0 ? r + n : r;
}

// `i` within 0..n-1: the panorama's rows stop at the poles.
function clampIndex(i: i32, n: i32): i32 {
    return i < 0 ? 0 : i >= n ? n - 1 : i;
}

// A directional light as a procedural sky draws it (Godot's LIGHTn_*).
export class SkySun {
    // Sky space, unit, towards the light.
    direction: Vec3;
    // Linear colour times energy.
    color: Vec3;
    // The disc's angular size in radians (light_angular_distance).
    size: f32;

    constructor(direction: Vec3, color: Vec3, size: f32) {
        this.direction = direction;
        this.color = color;
        this.size = size;
    }
}

// The suns of frame `f`'s sky: the first SKY_SUNS directional lights of
// the pool the lit mode draws (light_select.as prepareLights, for the
// frame's camera; LightPlan.dirs), in pool order: the scene's.
export function skySuns(f: RenderFrame): Array<SkySun> {
    const out = new Array<SkySun>();
    const toSky = f.environment.skyDesc.toSky;
    const plan = prepareLights(f);
    const n = min<i32>(plan.dirCount, SKY_SUNS);
    for (let k = 0; k < n; k++) {
        const l = f.lights[plan.lightAt(unchecked(plan.dirs[k]))];
        // The light travels along `direction`; the sky shows it where it
        // comes from.
        const dir = toSky.transformVector3(-l.direction).normalizeOr(Vec3(0, 1, 0));
        const size = toRadians(l.angularDistance > 0 ? l.angularDistance : 0);
        out.push(new SkySun(dir, l.color * l.energy, size));
    }
    return out;
}

// Godot's ProceduralSkyMaterial in sky-space direction `d` (unit): the
// gradient with its curves and energies, each sun's disc and glow, times
// `s.energy` (the material's energy_multiplier). With no suns, what the
// radiance map bakes.
export function proceduralSky(s: SkyDesc, d: Vec3, suns: Array<SkySun>): Vec3 {
    const halfPi: f32 = PI * 0.5;
    const v = acosf(clampF(d.y, -1, 1));
    if (d.y < 0) {
        const c = (v - halfPi) / halfPi;
        const ground = s.groundHorizon.lerp(s.groundBottom, curveMix(c, s.groundCurve)) * s.groundEnergy;
        return ground * s.energy;
    }
    let sky = s.skyHorizon.lerp(s.skyTop, curveMix(1 - v / halfPi, s.skyCurve)) * s.skyEnergy;
    const glow = toRadians(s.sunAngleMax);
    for (let i = 0; i < suns.length; i++) {
        const sun = suns[i];
        const a = acosf(clampF(sun.direction.dot(d), -1, 1));
        if (a < sun.size) {
            sky = sun.color;
        } else if (a < glow) {
            const c2 = (a - sun.size) / (glow - sun.size);
            sky = sun.color.lerp(sky, curveMix(c2, s.sunCurve));
        }
    }
    return sky * s.energy;
}

// Godot's gradient weight: clamp(1 - pow(1 - c, 1 / curve), 0, 1), with the
// base and the curve kept off zero as the shader's pow needs.
function curveMix(c: f32, curve: f32): f32 {
    const base = 1 - c > <f32>1e-6 ? 1 - c : <f32>1e-6;
    const k = curve > <f32>1e-4 ? curve : <f32>1e-4;
    return clampF(1 - powf(base, 1 / k), 0, 1);
}

function clampF(x: f32, lo: f32, hi: f32): f32 {
    return x < lo ? lo : x > hi ? hi : x;
}

// The sky's radiance in direction `d` as the map bakes it: the procedural
// sky without suns, or the panorama (by its `filter`, black without one),
// times `s.energy`; black for SKY_NONE.
export function skyRadiance(s: SkyDesc, d: Vec3): Vec3 {
    if (s.kind == SKY_PROCEDURAL) return proceduralSky(s, d, []);
    if (s.kind == SKY_PANORAMA) {
        const p = s.panorama;
        if (p == null) return Vec3(0, 0, 0);
        return samplePanorama(p, d, s.filter) * s.energy;
    }
    return Vec3(0, 0, 0);
}

// One mip of a cube map: six faces of `size` x `size` rgb texels (f32, rows
// top first).
export class CubeLevel {
    size: u32;
    faces: Array<Float32Array> = [];

    constructor(size: u32) {
        this.size = size;
        for (let i = 0; i < 6; i++) this.faces.push(new Float32Array(<i32>(size * size) * 3));
    }

    get(face: i32, x: u32, y: u32): Vec3 {
        const f = this.faces[face];
        const i = <i32>(y * this.size + x) * 3;
        return Vec3(f[i], f[i + 1], f[i + 2]);
    }

    put(face: i32, x: u32, y: u32, c: Vec3): void {
        const f = this.faces[face];
        const i = <i32>(y * this.size + x) * 3;
        f[i] = c.x;
        f[i + 1] = c.y;
        f[i + 2] = c.z;
    }

    // Bilinear within the face `d` lands on, clamped to that face's edge
    // texels (as a GPU without seamless cube filtering would).
    sample(d: Vec3): Vec3 {
        const fuv = cubeFaceUv(d);
        return this.sampleFace(<i32>fuv.x, fuv.y, fuv.z);
    }

    // Bilinear at (u, v) of face `face`, clamped to its texels: `sample`
    // once the face is known (RadianceMap reads two levels at one place).
    sampleFace(face: i32, u: f32, v: f32): Vec3 {
        const n = this.size;
        const top = <f32>(n - 1);
        const x = clampF(u * <f32>n - 0.5, 0, top);
        const y = clampF(v * <f32>n - 0.5, 0, top);
        const x0 = <u32>x;
        const y0 = <u32>y;
        const x1 = min<u32>(x0 + 1, n - 1);
        const y1 = min<u32>(y0 + 1, n - 1);
        const tx = x - <f32>x0;
        const ty = y - <f32>y0;
        const f = this.faces[face];
        const i00 = <i32>(y0 * n + x0) * 3;
        const i10 = <i32>(y0 * n + x1) * 3;
        const i01 = <i32>(y1 * n + x0) * 3;
        const i11 = <i32>(y1 * n + x1) * 3;
        const w00 = (1 - tx) * (1 - ty);
        const w10 = tx * (1 - ty);
        const w01 = (1 - tx) * ty;
        const w11 = tx * ty;
        return Vec3(
            f[i00] * w00 + f[i10] * w10 + f[i01] * w01 + f[i11] * w11,
            f[i00 + 1] * w00 + f[i10 + 1] * w10 + f[i01 + 1] * w01 + f[i11 + 1] * w11,
            f[i00 + 2] * w00 + f[i10 + 2] * w10 + f[i01 + 2] * w01 + f[i11 + 2] * w11,
        );
    }

    // The next smaller level of a source chain: each texel the mean of the
    // 2 x 2 it covers (the faces' sizes are powers of two).
    half(): CubeLevel {
        const out = new CubeLevel(this.size / 2);
        this.halfInto(out);
        return out;
    }

    // `half` into `out`, a level of half this one's size whose faces the
    // caller made (milestone 20: a probe capture borrows them from its
    // BakeBuffers, so a second capture allocates no level again).
    halfInto(out: CubeLevel): void {
        const n = this.size / 2;
        for (let face = 0; face < 6; face++) {
            for (let y: u32 = 0; y < n; y++) {
                for (let x: u32 = 0; x < n; x++) {
                    const c = this.get(face, x * 2, y * 2) + this.get(face, x * 2 + 1, y * 2)
                        + this.get(face, x * 2, y * 2 + 1) + this.get(face, x * 2 + 1, y * 2 + 1);
                    out.put(face, x, y, c * 0.25);
                }
            }
        }
    }
}

// A cube map with its mips, level 0 the largest.
export class RadianceMap {
    levels: Array<CubeLevel> = [];

    size(): u32 {
        return this.levels.length > 0 ? this.levels[0].size : 0;
    }

    // Trilinear: `lod` between two levels (clamped to the chain).
    sample(d: Vec3, lod: f32): Vec3 {
        const n = this.levels.length;
        if (n == 0) return Vec3(0, 0, 0);
        const l = clampF(lod, 0, <f32>(n - 1));
        const m0 = <i32>l;
        const t = l - <f32>m0;
        const fuv = cubeFaceUv(d);
        const face = <i32>fuv.x;
        const a = this.levels[m0].sampleFace(face, fuv.y, fuv.z);
        if (t <= 0 || m0 + 1 >= n) return a;
        const b = this.levels[m0 + 1].sampleFace(face, fuv.y, fuv.z);
        return a * (1 - t) + b * t;
    }
}

// What one environment's image-based light is: built once by `buildIbl`,
// kept by `IblCache` while the environment's `skyKey` stays the same, and
// uploaded by the renderer when it sees a new plan (by identity).
export class IblPlan {
    // skyKey of the environment it was built for.
    key: string = "";
    // The device's largest texture it was built for: a panorama is halved
    // to fit it, so a different device needs a new plan.
    maxTextureSize: u32 = 0;
    // radianceLevels(size) levels, prefiltered as the header says.
    radiance: RadianceMap = new RadianceMap();
    // SKY_SH_COEFFS convolved coefficients (shIrradiance).
    sh: Array<Vec3> = [];
    // The panorama as the renderer uploads it (halved until it fits
    // PANORAMA_MAX_WIDTH and the device), or null for a procedural sky.
    panorama: FloatImage? = null;
    // How long buildIbl took, for the preview's and the tests' budget.
    buildMillis: f64 = 0;
}

// A digest of an image's size and content (64-bit FNV-1a over its size and
// every texel's exact bits): what skyKey compares instead of the image, so
// a reloaded file with the same texels keeps its map and one with any
// texel changed gets a new one. Worked out once per image and kept on it
// (`FloatImage.digest`), so later frames only read the field.
export function floatImageDigest(img: FloatImage): string {
    if (img.digest.length > 0) return img.digest;
    let h: u64 = FNV64_OFFSET;
    h = fnvU32(h, img.width);
    h = fnvU32(h, img.height);
    const data = img.data;
    const n = data.length;
    for (let i = 0; i < n; i++) h = fnvU32(h, reinterpret<u32>(unchecked(data[i])));
    img.digest = img.width.toString() + "x" + img.height.toString() + ":" + hexU64(h, 16);
    return img.digest;
}

const FNV64_OFFSET: u64 = 0xcbf29ce484222325;
const FNV64_PRIME: u64 = 0x100000001b3;

// FNV-1a over the four bytes of `v`, least significant first.
function fnvU32(h: u64, v: u32): u64 {
    let x = h;
    x = (x ^ <u64>(v & 0xff)) * FNV64_PRIME;
    x = (x ^ <u64>((v >> 8) & 0xff)) * FNV64_PRIME;
    x = (x ^ <u64>((v >> 16) & 0xff)) * FNV64_PRIME;
    x = (x ^ <u64>(v >> 24)) * FNV64_PRIME;
    return x;
}

// An f32's exact bits as text: two values give the same key only when
// they are the same number.
function bitsOf(x: f32): string {
    return hexU64(<u64>reinterpret<u32>(x), 8);
}

function bitsOf3(v: Vec3): string {
    return bitsOf(v.x) + "," + bitsOf(v.y) + "," + bitsOf(v.z);
}

// Everything the plan of `e` depends on, as text: "" without a Sky
// (SKY_NONE); otherwise the kind, radianceSize, the energy, the
// procedural colours, curves and energies (their exact bits), or the
// panorama's digest and `filter`. Not the suns, `toSky`,
// `backgroundEnergy` nor anything of the ambient or fog, which the shader
// applies when it reads the map.
export function skyKey(e: EnvironmentDesc): string {
    const s = e.skyDesc;
    if (s.kind == SKY_NONE) return "";
    const parts = new Array<string>();
    parts.push("sky" + s.kind.toString());
    parts.push(radianceSize(s.radianceSize).toString());
    parts.push(bitsOf(s.energy));
    if (s.kind == SKY_PROCEDURAL) {
        parts.push(bitsOf3(s.skyTop));
        parts.push(bitsOf3(s.skyHorizon));
        parts.push(bitsOf3(s.groundBottom));
        parts.push(bitsOf3(s.groundHorizon));
        parts.push(bitsOf(s.skyCurve));
        parts.push(bitsOf(s.groundCurve));
        parts.push(bitsOf(s.skyEnergy));
        parts.push(bitsOf(s.groundEnergy));
    } else {
        parts.push(s.filter ? "filter" : "nearest");
        const p = s.panorama;
        parts.push(p != null ? floatImageDigest(p) : "none");
    }
    return parts.join("|");
}

// A panorama made ready for one device: the image the renderer uploads
// (halved until it fits PANORAMA_MAX_WIDTH and the device) and its further
// halves, which the bake reads. Kept by IblCache while the panorama's
// digest and the device stay the same, so an edit of the energy, filter
// or radiance size rebuilds the cube without halving the panorama again or
// making the renderer upload it again (the stub allocator never frees, and
// a 4096-wide HDRI's halves come to about 100 MB).
export class PanoramaPrep {
    // floatImageDigest of the source panorama ("none" without one).
    digest: string = "";
    maxTextureSize: u32 = 0;
    // chain[0] is what the renderer uploads; chain[i + 1] is chain[i].half().
    chain: Array<FloatImage> = [];

    constructor(given: FloatImage?, maxTextureSize: u32) {
        this.digest = given != null ? floatImageDigest(given) : "none";
        this.maxTextureSize = maxTextureSize;
        let p: FloatImage = given != null ? given! : FloatImage.new(1, 1, Vec3(0, 0, 0));
        while ((p.width > PANORAMA_MAX_WIDTH || p.width > maxTextureSize || p.height > maxTextureSize)
            && (p.width > 1 || p.height > 1)) {
            p = p.half();
        }
        this.chain.push(p);
    }

    upload(): FloatImage {
        return this.chain[0];
    }

    // The widest image of the chain at most 4 * size wide (a cube texel
    // spans about 4 panorama columns at 4 * size wide, so point samples of
    // a wider source would skip texels and alias a small bright light in or
    // out of the map). Halves are made once and kept.
    bakeSource(size: u32): FloatImage {
        let i = 0;
        while (this.chain[i].width > 4 * size) {
            if (i + 1 >= this.chain.length) this.chain.push(this.chain[i].half());
            i++;
        }
        return this.chain[i];
    }
}

// The image-based light of sky `s` (the header's conventions), on a device
// whose textures are at most `maxTextureSize` texels wide. `prep` is the
// panorama already made ready for that device (IblCache passes the one it
// keeps); null makes it here.
export function buildIbl(s: SkyDesc, maxTextureSize: u32, prep: PanoramaPrep? = null): IblPlan {
    const start = clock();
    const plan = new IblPlan();
    const size = radianceSize(s.radianceSize);
    const levels = <i32>radianceLevels(size);

    // What the renderer uploads and fs_sky draws: the whole panorama, unless
    // the device (or PANORAMA_MAX_WIDTH) needs it smaller.
    let bakeFrom: FloatImage? = null;
    if (s.kind == SKY_PANORAMA) {
        const ready = prep != null ? prep : new PanoramaPrep(s.panorama, maxTextureSize);
        plan.panorama = ready.upload();
        bakeFrom = ready.bakeSource(size);
    }

    // Level 0: the sky itself at the texel centres.
    const base = new CubeLevel(size);
    const inv: f32 = <f32>1 / <f32>size;
    if (bakeFrom != null) {
        for (let face = 0; face < 6; face++) {
            for (let y: u32 = 0; y < size; y++) {
                for (let x: u32 = 0; x < size; x++) {
                    const d = cubeDir(face, (<f32>x + 0.5) * inv, (<f32>y + 0.5) * inv);
                    base.put(face, x, y, samplePanorama(bakeFrom, d, s.filter) * s.energy);
                }
            }
        }
    } else if (s.kind == SKY_PROCEDURAL) {
        bakeProcedural(s, base);
    }

    const source = new RadianceMap();
    plan.radiance = prefilterCube(base, source);

    let shLevel = base;
    for (let m = 0; m < levels; m++) {
        if (source.levels[m].size == SH_SOURCE_SIZE) shLevel = source.levels[m];
    }
    plan.sh = shConvolve(shProject(shLevel));
    plan.buildMillis = (clock() - start) * 1000;
    return plan;
}

// The radiance map whose level 0 is `base` (a power of two, at least
// RADIANCE_SMALLEST texels a face): `base` itself, then
// radianceLevels(base.size) - 1 levels each prefiltered with GGX as the
// header says, read from the box-filtered halves of `base`. Milestone 20:
// a reflection probe's capture (compiler/src/bake/probe/capture.as) is
// filtered by this, as a sky is, so materials take it through the same
// roughness-to-mip rule. `source`, when given, receives that chain of
// halves (buildIbl projects the irradiance from one of them).
export function prefilterCube(base: CubeLevel, source: RadianceMap? = null): RadianceMap {
    const size = base.size;
    const levels = <i32>radianceLevels(size);
    const chain = source != null ? source : new RadianceMap();
    chain.levels.length = 0;
    chain.levels.push(base);
    for (let m = 1; m < levels; m++) chain.levels.push(chain.levels[m - 1].half());
    const out = new RadianceMap();
    out.levels.push(base);
    for (let m = 1; m < levels; m++) out.levels.push(prefilter(chain, <u32>m, size));
    return out;
}

// The procedural sky at every texel centre of `c`. Without suns it depends
// on the direction's height alone, and the cube's texel centres repeat
// their heights: the four side faces share one pattern (to the last bit,
// or one rounding of the length apart), mirror-symmetric left to right,
// and the top and bottom faces are symmetric both ways (a face's size is
// a power of two, so a mirrored coordinate is an exact negation). So each
// height is evaluated once, for a sixth of the texels, which the acos and
// pow of Godot's gradient make worth it (about 80 ms saved at 128).
function bakeProcedural(s: SkyDesc, c: CubeLevel): void {
    const n = c.size;
    const inv: f32 = <f32>1 / <f32>n;
    const none = new Array<SkySun>();
    const half = (n + 1) / 2;
    for (let y: u32 = 0; y < n; y++) {
        for (let x: u32 = 0; x < half; x++) {
            const u = (<f32>x + 0.5) * inv;
            const v = (<f32>y + 0.5) * inv;
            const side = proceduralSky(s, cubeDir(0, u, v), none);
            for (let f = 0; f < 6; f++) {
                if (f == 2 || f == 3) continue;
                c.put(f, x, y, side);
                c.put(f, n - 1 - x, y, side);
            }
            if (y < half) {
                const top = proceduralSky(s, cubeDir(2, u, v), none);
                const bottom = proceduralSky(s, cubeDir(3, u, v), none);
                c.put(2, x, y, top);
                c.put(2, n - 1 - x, y, top);
                c.put(2, x, n - 1 - y, top);
                c.put(2, n - 1 - x, n - 1 - y, top);
                c.put(3, x, y, bottom);
                c.put(3, n - 1 - x, y, bottom);
                c.put(3, x, n - 1 - y, bottom);
                c.put(3, n - 1 - x, n - 1 - y, bottom);
            }
        }
    }
}

// Van der Corput's radical inverse in base 2: the second coordinate of the
// Hammersley points, spread evenly however few are taken.
function radicalInverse(k: u32): f32 {
    let b = k;
    b = (b << 16) | (b >> 16);
    b = ((b & 0x55555555) << 1) | ((b & 0xaaaaaaaa) >> 1);
    b = ((b & 0x33333333) << 2) | ((b & 0xcccccccc) >> 2);
    b = ((b & 0x0f0f0f0f) << 4) | ((b & 0xf0f0f0f0) >> 4);
    b = ((b & 0x00ff00ff) << 8) | ((b & 0xff00ff00) >> 8);
    return <f32>(<f64>b * 2.3283064365386963e-10);
}

// Level `m` of the radiance map: the GGX lobe of roughness m / (levels - 1)
// around each texel's direction, with V = N (the split-sum's assumption).
// The samples' offsets from N, their weights and the source level each
// reads depend on the roughness alone, so they are worked out once here
// and only turned into each texel's frame below.
function prefilter(source: RadianceMap, m: u32, baseSize: u32): CubeLevel {
    const out = new CubeLevel(baseSize >> m);
    prefilterLevelInto(source, m, out);
    return out;
}

// Level `m` of the radiance map read from `source` (the chain of box-
// filtered halves prefilterCube makes: its level 0 the base, every level
// down to RADIANCE_SMALLEST), into `out`, whose size is the base's >> m and
// whose faces the caller made: `prefilter` without allocating the level
// (milestone 20: a probe capture prefilters into borrowed faces, one level
// a step, ../probe/capture.as). The same numbers as prefilterCube's.
export unsafe function prefilterLevelInto(source: RadianceMap, m: u32, out: CubeLevel): void {
    const levels = source.levels.length;
    const baseSize = source.levels[0].size;
    const k = PREFILTER_SAMPLES;
    const r = <f32>m / <f32>(levels - 1);
    const alpha = r * r;
    const a2 = alpha * alpha;
    // One source texel's solid angle, on average.
    const omegaP = <f32>4 * PI / (<f32>6 * <f32>baseSize * <f32>baseSize);
    const lx = new Float32Array(k);
    const ly = new Float32Array(k);
    const lz = new Float32Array(k);
    const lod = new Float32Array(k);
    let used = 0;
    for (let i = 0; i < k; i++) {
        const u = <f32>i / <f32>k;
        const v = radicalInverse(<u32>i);
        const phi = 2 * PI * u;
        const cosT = Mathf.sqrt((1 - v) / (1 + (a2 - 1) * v));
        const sinT = Mathf.sqrt(Mathf.max(0, 1 - cosT * cosT));
        // L = 2 (N.H) H - N in the frame where N is +z and N.H = cos t.
        const nl = 2 * cosT * cosT - 1;
        if (nl <= 0) continue;
        const dd = cosT * cosT * (a2 - 1) + 1;
        const dist = a2 / (PI * dd * dd);
        const pdf = dist / 4;
        const omegaS = <f32>1 / (<f32>k * pdf);
        // Filtered importance sampling: a sample that stands for a larger
        // solid angle reads a blurrier level, so 32 samples do not alias.
        lod[used] = clampF(0.5 * log2f(omegaS / omegaP) + 1, 0, <f32>(levels - 1));
        lx[used] = 2 * cosT * sinT * cosf(phi);
        ly[used] = 2 * cosT * sinT * sinf(phi);
        lz[used] = nl;
        used++;
    }

    // Per sample, packed for the loop below: the offset from N (3), the
    // chain level it reads first (as its first face's index in facePtr),
    // and the weights (n.l) of that level and the next. The weights' sum is
    // the same for every texel.
    const smp = new Float32Array(used * 6);
    let weight: f32 = 0;
    for (let i = 0; i < used; i++) {
        let lo = <i32>lod[i];
        let fr = lod[i] - <f32>lo;
        if (lo >= levels - 1) {
            lo = levels - 1;
            fr = 0;
        }
        smp[i * 6] = lx[i];
        smp[i * 6 + 1] = ly[i];
        smp[i * 6 + 2] = lz[i];
        smp[i * 6 + 3] = <f32>(lo * 6);
        smp[i * 6 + 4] = lz[i] * (1 - fr);
        smp[i * 6 + 5] = lz[i] * fr;
        weight += lz[i];
    }
    // Where each face of each level of the chain starts, and its size.
    const facePtr = new StaticArray<usize>(levels * 6);
    const faceSize = new StaticArray<u32>(levels);
    for (let l = 0; l < levels; l++) {
        const lvl = source.levels[l];
        faceSize[l] = lvl.size;
        for (let f = 0; f < 6; f++) facePtr[l * 6 + f] = lvl.faces[f].dataStart;
    }

    // About a million taps for a 128 map: the loop below keeps to scalars
    // and raw loads (source.sample's arithmetic, inlined), which a build
    // without inlining would otherwise spend most of its time calling.
    const n = baseSize >> m;
    const inv: f32 = <f32>1 / <f32>n;
    const sp = smp.dataStart;
    for (let face = 0; face < 6; face++) {
        const dst = out.faces[face];
        for (let y: u32 = 0; y < n; y++) {
            for (let x: u32 = 0; x < n; x++) {
                const nd = cubeDir(face, (<f32>x + 0.5) * inv, (<f32>y + 0.5) * inv);
                const up = Mathf.abs(nd.z) > 0.999 ? Vec3(1, 0, 0) : Vec3(0, 0, 1);
                const t = up.cross(nd).normalize();
                const b = nd.cross(t);
                const tx = t.x;
                const ty = t.y;
                const tz = t.z;
                const bx = b.x;
                const by = b.y;
                const bz = b.z;
                const nx = nd.x;
                const ny = nd.y;
                const nz = nd.z;
                let sumR: f32 = 0;
                let sumG: f32 = 0;
                let sumB: f32 = 0;
                for (let i = 0; i < used; i++) {
                    const q = sp + (<usize>(i * 6) << 2);
                    const sx = load<f32>(q);
                    const sy = load<f32>(q, 4);
                    const sz = load<f32>(q, 8);
                    const first = <i32>load<f32>(q, 12);
                    const w0 = load<f32>(q, 16);
                    const w1 = load<f32>(q, 20);
                    const dx = tx * sx + bx * sy + nx * sz;
                    const dy = ty * sx + by * sy + ny * sz;
                    const dz = tz * sx + bz * sy + nz * sz;
                    // cubeFaceUv, inlined.
                    const ax = Mathf.abs(dx);
                    const ay = Mathf.abs(dy);
                    const az = Mathf.abs(dz);
                    let f: i32;
                    let ma: f32;
                    let sc: f32;
                    let tc: f32;
                    if (ax >= ay && ax >= az) {
                        ma = ax;
                        if (dx >= 0) {
                            f = 0; sc = -dz; tc = -dy;
                        } else {
                            f = 1; sc = dz; tc = -dy;
                        }
                    } else if (ay >= az) {
                        ma = ay;
                        if (dy >= 0) {
                            f = 2; sc = dx; tc = dz;
                        } else {
                            f = 3; sc = dx; tc = -dz;
                        }
                    } else {
                        ma = az;
                        if (dz >= 0) {
                            f = 4; sc = dx; tc = -dy;
                        } else {
                            f = 5; sc = -dx; tc = -dy;
                        }
                    }
                    const half = <f32>0.5 / ma;
                    const u = sc * half + 0.5;
                    const v = tc * half + 0.5;
                    // Bilinear in level l, then (when the lod is between
                    // two) level l + 1: CubeLevel.sampleFace, accumulated.
                    const taps = w1 > 0 ? 2 : 1;
                    for (let j = 0; j < taps; j++) {
                        const face0 = unchecked(facePtr[first + j * 6 + f]);
                        const size = unchecked(faceSize[first / 6 + j]);
                        const wt = j == 0 ? w0 : w1;
                        const top = <f32>(size - 1);
                        let px = u * <f32>size - 0.5;
                        let py = v * <f32>size - 0.5;
                        px = px < 0 ? 0 : px > top ? top : px;
                        py = py < 0 ? 0 : py > top ? top : py;
                        const x0 = <u32>px;
                        const y0 = <u32>py;
                        const stepX: usize = x0 + 1 < size ? 12 : 0;
                        const stepY: usize = y0 + 1 < size ? <usize>size * 12 : 0;
                        const fx = px - <f32>x0;
                        const fy = py - <f32>y0;
                        const w11 = wt * fx * fy;
                        const w10 = wt * fx - w11;
                        const w01 = wt * fy - w11;
                        const w00 = wt - w10 - w01 - w11;
                        const p00 = face0 + <usize>(y0 * size + x0) * 12;
                        const p10 = p00 + stepX;
                        const p01 = p00 + stepY;
                        const p11 = p01 + stepX;
                        sumR += load<f32>(p00) * w00 + load<f32>(p10) * w10 + load<f32>(p01) * w01 + load<f32>(p11) * w11;
                        sumG += load<f32>(p00, 4) * w00 + load<f32>(p10, 4) * w10
                            + load<f32>(p01, 4) * w01 + load<f32>(p11, 4) * w11;
                        sumB += load<f32>(p00, 8) * w00 + load<f32>(p10, 8) * w10
                            + load<f32>(p01, 8) * w01 + load<f32>(p11, 8) * w11;
                    }
                }
                const at = <i32>(y * n + x) * 3;
                if (weight > 0) {
                    const k1 = <f32>1 / weight;
                    dst[at] = sumR * k1;
                    dst[at + 1] = sumG * k1;
                    dst[at + 2] = sumB * k1;
                } else {
                    const c = source.sample(nd, 0);
                    dst[at] = c.x;
                    dst[at + 1] = c.y;
                    dst[at + 2] = c.z;
                }
            }
        }
    }
}

// The solid angle of the part of a cube face (at distance 1) between its
// centre and the corner (x, y): the texel's is four of these.
function areaElement(x: f64, y: f64): f64 {
    return Math.atan2(x * y, Math.sqrt(x * x + y * y + 1));
}

// The spherical-harmonic projection of the radiance of cube level `c`
// (each texel weighted by its solid angle), bands 0 to 2, in the basis
// `shBasis` evaluates.
export function shProject(c: CubeLevel): Array<Vec3> {
    // Sums in f64: 6 x 32 x 32 small terms would lose digits in f32.
    const acc = new Float64Array(SKY_SH_COEFFS * 3);
    const n = c.size;
    const inv: f64 = 1.0 / <f64>n;
    for (let face = 0; face < 6; face++) {
        for (let y: u32 = 0; y < n; y++) {
            const y0 = <f64>y * 2 * inv - 1;
            const y1 = <f64>(y + 1) * 2 * inv - 1;
            for (let x: u32 = 0; x < n; x++) {
                const x0 = <f64>x * 2 * inv - 1;
                const x1 = <f64>(x + 1) * 2 * inv - 1;
                const w = areaElement(x0, y0) - areaElement(x0, y1) - areaElement(x1, y0) + areaElement(x1, y1);
                const d = cubeDir(face, <f32>((<f64>x + 0.5) * inv), <f32>((<f64>y + 0.5) * inv));
                const b = shBasis(d);
                const col = c.get(face, x, y);
                for (let i = 0; i < SKY_SH_COEFFS; i++) {
                    const k = w * <f64>b[i];
                    acc[i * 3] += k * <f64>col.x;
                    acc[i * 3 + 1] += k * <f64>col.y;
                    acc[i * 3 + 2] += k * <f64>col.z;
                }
            }
        }
    }
    const out = new Array<Vec3>();
    for (let i = 0; i < SKY_SH_COEFFS; i++) {
        out.push(Vec3(<f32>acc[i * 3], <f32>acc[i * 3 + 1], <f32>acc[i * 3 + 2]));
    }
    return out;
}

// Radiance coefficients to the ones shIrradiance reads: band l times the
// cosine lobe's A_l / pi (1, 2/3, 1/4).
export function shConvolve(sh: Array<Vec3>): Array<Vec3> {
    const out = new Array<Vec3>();
    for (let i = 0; i < sh.length; i++) {
        const k: f32 = i == 0 ? 1 : i < 4 ? <f32>2.0 / 3.0 : 0.25;
        out.push(sh[i] * k);
    }
    return out;
}

// The nine real SH basis functions at unit `n` (sky space), in the order
// the block holds them: Y00; Y1-1 (y), Y10 (z), Y11 (x); Y2-2 (xy), Y2-1
// (yz), Y20 (3z^2 - 1), Y21 (xz), Y22 (x^2 - y^2). surface.wgsl's
// sh_irradiance evaluates the same.
export function shBasis(n: Vec3): Array<f32> {
    const x = n.x;
    const y = n.y;
    const z = n.z;
    const out = new Array<f32>();
    out.push(0.282095);
    out.push(0.488603 * y);
    out.push(0.488603 * z);
    out.push(0.488603 * x);
    out.push(1.092548 * x * y);
    out.push(1.092548 * y * z);
    out.push(0.315392 * (3 * z * z - 1));
    out.push(1.092548 * x * z);
    out.push(0.546274 * (x * x - y * y));
    return out;
}

// The irradiance divided by pi at unit sky-space normal `n`, from
// convolved coefficients (the header).
export function shIrradiance(sh: Array<Vec3>, n: Vec3): Vec3 {
    const b = shBasis(n);
    let c = Vec3(0, 0, 0);
    for (let i = 0; i < SKY_SH_COEFFS && i < sh.length; i++) c = c + sh[i] * b[i];
    return c;
}

// Godot's (Karis's) analytic environment BRDF: the scale (x) and bias (y)
// of F0 for image-based specular light at `roughness` (perceptual) and
// n.v. The shader's specular ambient is radiance * (f0 * x + y *
// clamp(50 * f0.g, metallic, 1)).
export function envBrdfApprox(roughness: f32, nv: f32): Vec2 {
    const r = Vec4(-1, -0.0275, -0.572, 0.022) * roughness + Vec4(1, 0.0425, 1.04, -0.04);
    const a004 = Mathf.min(r.x * r.x, Mathf.pow(2, -9.28 * nv)) * r.x + r.y;
    return Vec2(-1.04 * a004 + r.z, 1.04 * a004 + r.w);
}

// The numbers of a Sky that its skyKey spells out (all of them but the
// panorama, which the key names by digest), as bits in a fixed order: two
// skies with the same numbers and the same panorama object have the same
// key.
const SKY_NUMBERS: i32 = 20;
const skyNumbersScratch = new StaticArray<u32>(SKY_NUMBERS);

function skyNumbers(s: SkyDesc, out: StaticArray<u32>): StaticArray<u32> {
    out[0] = s.kind;
    out[1] = s.radianceSize;
    out[2] = reinterpret<u32>(s.energy);
    out[3] = reinterpret<u32>(s.skyTop.x);
    out[4] = reinterpret<u32>(s.skyTop.y);
    out[5] = reinterpret<u32>(s.skyTop.z);
    out[6] = reinterpret<u32>(s.skyHorizon.x);
    out[7] = reinterpret<u32>(s.skyHorizon.y);
    out[8] = reinterpret<u32>(s.skyHorizon.z);
    out[9] = reinterpret<u32>(s.groundBottom.x);
    out[10] = reinterpret<u32>(s.groundBottom.y);
    out[11] = reinterpret<u32>(s.groundBottom.z);
    out[12] = reinterpret<u32>(s.groundHorizon.x);
    out[13] = reinterpret<u32>(s.groundHorizon.y);
    out[14] = reinterpret<u32>(s.groundHorizon.z);
    out[15] = reinterpret<u32>(s.skyCurve);
    out[16] = reinterpret<u32>(s.groundCurve);
    out[17] = reinterpret<u32>(s.skyEnergy);
    out[18] = reinterpret<u32>(s.groundEnergy);
    out[19] = s.filter ? 1 : 0;
    return out;
}

function sameNumbers(a: StaticArray<u32>, b: StaticArray<u32>): bool {
    for (let i = 0; i < SKY_NUMBERS; i++) if (unchecked(a[i]) != unchecked(b[i])) return false;
    return true;
}

// Milestone 34: whether environments `a` and `b` light with the same sky
// (the same skyKey: the same numbers and the same panorama object), so a
// viewport whose world has the main frame's sky shares its image-based
// light (gpu/viewports.as) rather than building it again. Allocates
// nothing.
const sameSkyA = new StaticArray<u32>(SKY_NUMBERS);
const sameSkyB = new StaticArray<u32>(SKY_NUMBERS);

export function sameSky(a: EnvironmentDesc, b: EnvironmentDesc): bool {
    if (a === b) return true;
    const sa = a.skyDesc;
    const sb = b.skyDesc;
    if (sa.kind == SKY_NONE || sb.kind == SKY_NONE) return sa.kind == sb.kind;
    if (sa.panorama !== sb.panorama) return false;
    return sameNumbers(skyNumbers(sa, sameSkyA), skyNumbers(sb, sameSkyB));
}

// The plan of the frame's environment, rebuilt only when its skyKey
// changes (the preview and the editor draw many frames of one sky).
export class IblCache {
    plan: IblPlan? = null;
    // How many plans were built: a test proves an unchanged sky builds once.
    builds: i32 = 0;
    // The panorama made ready for the device, reused while its digest and
    // the device stay the same: the plans built from it share its upload
    // image, which the renderer then keeps on the GPU.
    prep: PanoramaPrep? = null;

    // What `plan` was last asked for, as numbers (skyNumbers) and the
    // panorama object: an environment with the same numbers and the same
    // panorama has the same skyKey, so `get` answers it without building
    // the key's text (milestone 13: the preview asks every frame, and the
    // stub allocator never frees).
    private seen: StaticArray<u32> = new StaticArray<u32>(SKY_NUMBERS);
    private seenPanorama: FloatImage? = null;
    private hasSeen: bool = false;

    // The plan for `e`, or null without a Sky. Allocates nothing when `e`
    // asks for the plan the last call answered with.
    get(e: EnvironmentDesc, maxTextureSize: u32): IblPlan? {
        if (e.skyDesc.kind == SKY_NONE) return null;
        const numbers = skyNumbers(e.skyDesc, skyNumbersScratch);
        const held = this.plan;
        if (held != null && this.hasSeen && held.maxTextureSize == maxTextureSize
            && this.seenPanorama === e.skyDesc.panorama && sameNumbers(numbers, this.seen)) {
            return held;
        }
        const plan = this.getByKey(e, maxTextureSize);
        if (plan != null) {
            for (let i = 0; i < SKY_NUMBERS; i++) unchecked(this.seen[i] = numbers[i]);
            this.seenPanorama = e.skyDesc.panorama;
            this.hasSeen = true;
        }
        return plan;
    }

    // `get` by the environment's skyKey: the plan held when the key and the
    // device are the same, else a new one.
    private getByKey(e: EnvironmentDesc, maxTextureSize: u32): IblPlan? {
        const key = skyKey(e);
        if (key.length == 0) return null;
        const held = this.plan;
        if (held != null && held.key == key && held.maxTextureSize == maxTextureSize) return held;
        let prep: PanoramaPrep? = null;
        if (e.skyDesc.kind == SKY_PANORAMA) {
            const p = e.skyDesc.panorama;
            const digest = p != null ? floatImageDigest(p) : "none";
            const kept = this.prep;
            if (kept != null && kept.digest == digest && kept.maxTextureSize == maxTextureSize) {
                prep = kept;
            } else {
                prep = new PanoramaPrep(p, maxTextureSize);
                this.prep = prep;
            }
        }
        const plan = buildIbl(e.skyDesc, maxTextureSize, prep);
        plan.key = key;
        plan.maxTextureSize = maxTextureSize;
        this.plan = plan;
        this.builds++;
        return plan;
    }
}

// The sky block of frame `f` with the plan `ibl` built for its environment
// (null without a Sky). A frame that is not lit, or whose environment has
// no Sky and no fog, gets flags 0: the shader then reads nothing of it.
// Plans the frame's lights for its camera first (light_select.as
// prepareLights: the suns are the pool's), as a frame no renderer drew has
// no pool yet.
export function skyUniform(f: RenderFrame, ibl: IblPlan?): SkyUniform {
    prepareLights(f);
    return skyUniformInto(f, ibl, new SkyUniform());
}

const FRESH_SKY = new SkyUniform();

// `skyUniform` into `out`, returned (milestone 13; see shadow.as
// `planShadowsInto`): every field set again and the suns and irradiance
// refilled in place, so the same frame from a moved camera allocates
// nothing. The same block exactly (`skyUniform` fills a new one).
export function skyUniformInto(f: RenderFrame, ibl: IblPlan?, out: SkyUniform): SkyUniform {
    const u = out;
    u.suns.length = 0;
    u.sh.length = 0;
    if (f.shading != SHADE_LIT) {
        // A new block's values.
        const z = FRESH_SKY;
        u.flags = z.flags;
        u.toSky = z.toSky;
        u.skyTop = z.skyTop;
        u.skyHorizon = z.skyHorizon;
        u.groundBottom = z.groundBottom;
        u.groundHorizon = z.groundHorizon;
        u.sun = z.sun;
        u.ambient = z.ambient;
        u.ibl = z.ibl;
        u.fogColor = z.fogColor;
        u.fog = z.fog;
        u.fogDepth = z.fogDepth;
        u.fogOrigin = z.fogOrigin;
        return u;
    }
    const e = f.environment;
    const s = e.skyDesc;
    const fog = e.fog;

    let bits: u32 = 0;
    const drawProcedural = e.sky && s.kind == SKY_PROCEDURAL;
    if (drawProcedural) bits |= SKY_DRAW_PROCEDURAL;
    if (e.sky && s.kind == SKY_PANORAMA) {
        bits |= SKY_DRAW_PANORAMA;
        if (s.filter) bits |= SKY_PANORAMA_FILTER;
    }
    if (s.kind != SKY_NONE && ibl != null) {
        bits |= SKY_IBL;
        if (e.ambientFromSky) bits |= SKY_AMBIENT_SKY;
        if (e.reflectedSource == REFLECT_SKY || (e.reflectedSource == REFLECT_BACKGROUND && e.sky)) {
            bits |= SKY_REFLECT_RADIANCE;
        }
        if (e.reflectedSource == REFLECT_DISABLED) bits |= SKY_REFLECT_OFF;
    }
    if (fog.enabled) {
        bits |= SKY_FOG;
        if (fog.mode == FOG_DEPTH) bits |= SKY_FOG_DEPTH;
    }
    // Only a drawn procedural sky shows suns (skySuns', written straight
    // into the block, from the pool `f.lightPlan` holds: the renderer plans
    // it for the view first); a panorama has its own.
    if (drawProcedural) {
        const toSky = s.toSky;
        const plan = f.lightPlan;
        const n = min<i32>(plan.dirCount, SKY_SUNS);
        for (let k = 0; k < n; k++) {
            const l = f.lights[plan.lightAt(unchecked(plan.dirs[k]))];
            const dir = toSky.transformVector3(-l.direction).normalizeOr(Vec3(0, 1, 0));
            const size = toRadians(l.angularDistance > 0 ? l.angularDistance : 0);
            u.suns.push(SkySunUniform(dir.extend(size), (l.color * l.energy).extend(0)));
        }
    }
    const levels: u32 = ibl != null ? <u32>ibl.radiance.levels.length : 0;
    u.flags = U32x4(bits, levels, <u32>u.suns.length, 0);

    u.toSky = s.toSky;
    u.skyTop = s.skyTop.extend(Mathf.max(s.skyCurve, 1e-4));
    u.skyHorizon = s.skyHorizon.extend(s.skyEnergy);
    u.groundBottom = s.groundBottom.extend(Mathf.max(s.groundCurve, 1e-4));
    u.groundHorizon = s.groundHorizon.extend(s.groundEnergy);
    u.sun = Vec4(toRadians(clampF(s.sunAngleMax, 0, 180)), Mathf.max(s.sunCurve, 1e-4), s.energy, e.backgroundEnergy);
    u.ambient = e.ambient.extend(clampF(e.ambientSkyContribution, 0, 1));
    u.ibl = Vec4(e.ambientEnergy, 0, 0, 0);

    u.fogColor = fog.color.extend(fog.sunScatter);
    u.fog = Vec4(fog.density, clampF(fog.skyAffect, 0, 1), fog.height, fog.heightDensity);
    u.fogDepth = Vec4(fog.depthBegin, fog.depthEnd, Mathf.max(fog.depthCurve, 1e-4), clampF(fog.aerialPerspective, 0, 1));
    const cam = f.camera;
    if (cam.isOrtho()) {
        // An orthographic eye sits wherever framing put it, as far back as
        // the picture is wide: measuring the fog from the nearest thing
        // drawn keeps it the same whatever the picture's size.
        let origin = cam.near;
        if (f.hasDrawBounds) {
            const view = cam.viewMatrix();
            const b = f.drawBounds;
            origin = f32.MAX_VALUE;
            // View space looks down -Z, so a corner's depth is -z.
            for (let i = 0; i < 8; i++) origin = Mathf.min(origin, -view.transformPoint3(b.corner(i)).z);
        }
        u.fogOrigin = Vec4(origin, cam.near, cam.far, 1);
    } else {
        u.fogOrigin = Vec4(0, cam.near, cam.far, 0);
    }

    if (ibl != null) {
        for (let i = 0; i < SKY_SH_COEFFS && i < ibl.sh.length; i++) u.sh.push(ibl.sh[i].extend(0));
    }
    return u;
}
