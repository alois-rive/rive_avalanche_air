// Shadows on the CPU (milestone 10): which lights of a frame get a shadow,
// where each of their shadow maps sits in the atlas, the light-space
// matrices each map is drawn with, and the shadow block the surface shader
// reads (layouts.as ShadowUniform, group 0 binding 2). Pure: no GPU, so a
// Tests suite checks it (editor/program/tests/render/shadow_test.as), and
// the renderer (gpu/renderer.as) draws what `planShadows` says.
//
// The budget: one atlas of SHADOW_TILES tiles (layouts.as); a directional
// light takes one tile per cascade, a spot one, an omni six. Milestone 59:
// the lights of the view's pool (light_select.as planLightPool: the lights
// the lit mode draws) are served by their importance to the view, the
// directional lights first, then the omni and spot lights by range over
// distance to the eye (`shadowImportance`), so a camera among many shadowed
// lamps gives the tiles to the nearest and largest. A light whose tiles do
// not fit is drawn unshadowed, and the program says so
// (`allocateFrameShadows(...).dropped`, which Hedra's adapter turns into a
// warning at plan time, before any GPU is involved). The chosen lights then
// take their tiles, and their slots in the shadow block, in pool order (the
// scene's): when every shadowed light fits, the atlas is laid out exactly
// as it was when lights were served in the scene's order.
//
// Units of the biases (Godot's are in "texels" too, so a scene's numbers
// mean much the same in both): a receiver at world position p with normal n
// is looked up at p + n * normalBias * max(blur, 1) * T + l * bias * T,
// where l points to the light, blur is shadow_blur and T is the world size
// of one texel of its tile at p (ShadowTileUniform.texel). The normal offset
// grows with the filter's radius because a wider filter otherwise reaches
// into the surface's own depth at grazing angles (acne on the sample's floor
// at blur 2). The comparison is then an exact depth test.
//
// Everything is in the frame's world space (render space: Z up for
// Hedra's frames).

import { clampF32, maxF32, minF32 } from "../base/util";
import {
    Mat4, VEC3_Y, VEC3_Z, VEC3_ZERO, VEC4_ZERO, Vec3, Vec4, atanf, camera, tanf, toRadians,
} from "../base/vecmath";
import {
    CAST_SHADOW_SHADOWS_ONLY, LIGHT_BAKE_STATIC, LIGHT_DIRECTIONAL, LIGHT_OMNI, LightDesc, RenderFrame,
    SHADE_LIT, SHADOW_ORTHOGONAL, SHADOW_PARALLEL_2_SPLITS,
} from "./frame";
import { prepareLights } from "./light_select";
import {
    SHADOW_ATLAS_GRID, SHADOW_ATLAS_SIZE, SHADOW_TILES, ShadowLightUniform, ShadowTileUniform, ShadowUniform, U32x4,
} from "./gpu/layouts";

// The smallest atlas the renderer makes (a device holding less draws no
// shadow at all, which `shadowAtlasSize` says with 0).
export const MIN_SHADOW_ATLAS_SIZE: u32 = 512;

// The near plane of a spot or omni light's projection, in world units.
export const SHADOW_NEAR: f32 = 0.05;

// A spot cone wider than this (its half angle, degrees) is drawn with its
// shadow's projection clamped to it.
export const MAX_SPOT_SHADOW_HALF_ANGLE: f32 = 85;

// How many atlas tiles a light's shadow takes (0 when `shadow` is off).
export function shadowTileCount(l: LightDesc): i32 {
    if (!l.shadow) return 0;
    if (l.kind == LIGHT_OMNI) return 6;
    if (l.kind == LIGHT_DIRECTIONAL) {
        if (l.directionalShadowMode == SHADOW_ORTHOGONAL) return 1;
        if (l.directionalShadowMode == SHADOW_PARALLEL_2_SPLITS) return 2;
        return 4;
    }
    return 1;
}

// Which lights get tiles, by frame light index.
export class ShadowAllocation {
    // Per light of the frame (all of them, drawn or not): its first tile,
    // or -1 when it has no shadow (off, outside the pool, or no room).
    first: Array<i32> = [];
    // Per light: its tile count (0 without a shadow).
    count: Array<i32> = [];
    // Tiles given out, from 0.
    used: i32 = 0;
    // The lights of the pool with `shadow` on that found too few tiles
    // left, in the order they were served (importance): drawn without a
    // shadow. Lights outside the pool are not drawn at all, so not here.
    dropped: Array<i32> = [];
    // Milestone 59: by `dropped` entry, the tiles left in the atlas when
    // that light's turn came (the warning's "N of 16 left"); and per light
    // of the frame, its slot in the shadow block (ShadowUniform.lights, the
    // LightUniform's info.w), or -1 without a shadow.
    left: Array<i32> = [];
    slot: Array<i32> = [];
    // The serving order's scratch (pool entries, and their importance),
    // kept from frame to frame.
    order: Array<i32> = [];
    importance: Array<f32> = [];
}

// How much light `l`'s shadow matters to a view from `eye`: a directional
// light's is f32.MAX_VALUE (it is served first); an omni or spot light's,
// its range over its distance to the eye (the size its reach shows at in a
// perspective view, 1e-3 the nearest distance counted), or its range alone
// in an orthographic view (`ortho`), where distance changes no size.
export function shadowImportance(l: LightDesc, eye: Vec3, ortho: bool): f32 {
    if (l.kind == LIGHT_DIRECTIONAL) return f32.MAX_VALUE;
    if (ortho) return l.range;
    return l.range / maxF32(l.position.distance(eye), <f32>1e-3);
}

// Milestone 59: the shadows' allocation of frame `f` for its camera, over
// the pool its lightPlan holds (planned for that camera by the caller:
// light_select.as planLightPool): which lights get tiles, by frame light
// index, as ShadowAllocation says, and in what order they were served (the
// file's header). With `skipStatic` (milestone 19: a frame whose drawn
// items are all lightmapped, `staticShadowsUnused`), a light whose
// bakeMode is LIGHT_BAKE_STATIC asks for none, as nothing would read its
// shadow, and so is never dropped either.
export function allocateFrameShadows(f: RenderFrame, skipStatic: bool = false): ShadowAllocation {
    return allocateFrameShadowsInto(f, skipStatic, new ShadowAllocation());
}

// `allocateFrameShadows` into `a` (its arrays refilled, their storage
// kept), returned: what planShadowsInto runs every frame.
function allocateFrameShadowsInto(f: RenderFrame, skipStatic: bool, a: ShadowAllocation): ShadowAllocation {
    const lights = f.lights;
    const n = lights.length;
    a.first.length = n;
    a.count.length = n;
    a.slot.length = n;
    for (let i = 0; i < n; i++) {
        unchecked(a.first[i] = -1);
        unchecked(a.count[i] = 0);
        unchecked(a.slot[i] = -1);
    }
    a.dropped.length = 0;
    a.left.length = 0;
    a.used = 0;
    const plan = f.lightPlan;
    const eye = f.camera.eye;
    const ortho = f.camera.isOrtho();
    // The wanting lights by importance, descending, ties in pool order (an
    // insertion after every entry of the same importance or more: at most
    // MAX_FRAME_LIGHTS entries).
    const order = a.order;
    const imp = a.importance;
    order.length = 0;
    imp.length = 0;
    for (let k = 0; k < plan.count; k++) {
        const l = unchecked(lights[plan.lightAt(k)]);
        if (skipStatic && l.bakeMode == LIGHT_BAKE_STATIC) continue;
        if (shadowTileCount(l) == 0) continue;
        const v = shadowImportance(l, eye, ortho);
        let at = order.length;
        while (at > 0 && unchecked(imp[at - 1]) < v) at--;
        order.push(0);
        imp.push(0);
        for (let m = order.length - 1; m > at; m--) {
            unchecked(order[m] = order[m - 1]);
            unchecked(imp[m] = imp[m - 1]);
        }
        unchecked(order[at] = k);
        unchecked(imp[at] = v);
    }
    // Greedy, as before: a light that does not fit is dropped, and a
    // smaller one later may still fit. `count` marks the chosen.
    for (let m = 0; m < order.length; m++) {
        const i = plan.lightAt(unchecked(order[m]));
        const want = shadowTileCount(unchecked(lights[i]));
        if (a.used + want <= SHADOW_TILES) {
            unchecked(a.count[i] = want);
            a.used += want;
        } else {
            a.dropped.push(i);
            a.left.push(SHADOW_TILES - a.used);
        }
    }
    // The tiles and slots in pool order.
    let tile = 0;
    let slot = 0;
    for (let k = 0; k < plan.count; k++) {
        const i = plan.lightAt(k);
        const c = unchecked(a.count[i]);
        if (c == 0) continue;
        unchecked(a.first[i] = tile);
        unchecked(a.slot[i] = slot);
        tile += c;
        slot++;
    }
    return a;
}

// Milestone 19: whether a static light's shadow would be read by nothing
// in frame `f`: it has a lightmap, and every item it draws (with a mesh,
// and not shadows-only) is lightmapped, so the lightmap pipelines skip the
// static lights on all of them (surface.wgsl `lit_with`). Such a light
// then gets no tile. One item drawn in real time (dynamic geometry, a
// MultiMesh, a sprite) reads every light's shadow, so the rule is off.
export function staticShadowsUnused(f: RenderFrame): bool {
    if (f.lightmap == null) return false;
    const items = f.items;
    for (let i = 0; i < items.length; i++) {
        const d = items[i];
        if (d.mesh == null || d.castShadow == CAST_SHADOW_SHADOWS_ONLY) continue;
        if (d.lightmapLayer < 0) return false;
    }
    return true;
}

// The atlas's side for a device whose largest texture is `maxTextureSize`
// texels: SHADOW_ATLAS_SIZE, or the largest power of two the device holds,
// or 0 (no shadows) below MIN_SHADOW_ATLAS_SIZE.
export function shadowAtlasSize(maxTextureSize: u32): u32 {
    let s = SHADOW_ATLAS_SIZE;
    while (s > maxTextureSize && s >= MIN_SHADOW_ATLAS_SIZE) s >>= 1;
    return s >= MIN_SHADOW_ATLAS_SIZE ? s : 0;
}

// One shadow map: a tile of the atlas and how it is drawn.
export class ShadowTile {
    // Its index in the atlas (and in ShadowUniform.tiles).
    index: i32 = 0;
    // The frame light it belongs to.
    light: i32 = 0;
    // The cascade (directional), the cube face (omni: 0..5 = +X -X +Y -Y
    // +Z -Z), 0 for a spot.
    part: i32 = 0;
    // Where it is in the atlas, in texels (the shadow pass's viewport).
    x: u32 = 0;
    y: u32 = 0;
    size: u32 = 0;
    // World to the tile's clip space (depth 0..1): what the shadow pass
    // draws the casters with, and what the shader projects receivers by.
    viewProj: Mat4 = Mat4(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1));
    // ShadowTileUniform.texel.
    texel: Vec4 = Vec4(0, 0, 0, 0);
}

// What one view's shadows are: the tiles to draw, the lights that sample
// them, and the block the shader reads.
export class ShadowPlan {
    // The atlas's side and a tile's, in texels (0 when no shadow is drawn).
    atlasSize: u32 = 0;
    tileSize: u32 = 0;
    // In tile order.
    tiles: Array<ShadowTile> = [];
    // Milestone 59: by frame light index (every light of the frame): the
    // light's slot in the shadow block (ShadowUniform.lights; litUniform
    // writes it into the light's info.w and marks it LIGHT_SHADOWED), or -1
    // when it draws no shadow. Slots go to the shadowed lights in pool
    // order, from 0.
    slots: Array<i32> = [];
    // As `allocateFrameShadows` found them.
    dropped: Array<i32> = [];
    uniform: ShadowUniform = new ShadowUniform();
    // Every tile object this plan has held (`tiles` is the first ones):
    // planShadowsInto takes them again rather than making new ones.
    private pool: Array<ShadowTile> = [];

    // Tile `i` of the pool, made on first use.
    takeTile(i: i32): ShadowTile {
        while (this.pool.length <= i) this.pool.push(new ShadowTile());
        return this.pool[i];
    }

    // Whether the frame draws any shadow: without one the renderer runs no
    // shadow pass and binds its dummy map, and the picture is what it was
    // before shadows existed.
    any(): bool {
        return this.tiles.length > 0;
    }
}

// Where tile `index` sits in an atlas of `atlasSize` texels, in texels.
export function tileOrigin(index: i32, atlasSize: u32): Vec4 {
    const tile = atlasSize / SHADOW_ATLAS_GRID;
    const col = <u32>index % SHADOW_ATLAS_GRID;
    const row = <u32>index / SHADOW_ATLAS_GRID;
    return Vec4(<f32>(col * tile), <f32>(row * tile), <f32>tile, <f32>tile);
}

// The up vector of a light looking along `dir`: world up (Z), unless the
// light points (almost) straight up or down, where Z is no longer a usable
// up and +Y is taken instead.
function lightUp(dir: Vec3): Vec3 {
    return Mathf.abs(dir.dot(VEC3_Z)) > <f32>0.99 ? VEC3_Y : VEC3_Z;
}

// A light's unit direction; a zero one (which no node gives) points down,
// as LightDesc's default does, rather than making every matrix NaN.
function lightDir(l: LightDesc): Vec3 {
    const d = l.direction.normalizeOrZero();
    return d.isFinite() && d != VEC3_ZERO ? d : Vec3(0, 0, -1);
}

// `v` rounded up to a multiple of 1/16. The cascade radius is rounded so
// that float noise in the frustum's corners cannot change it from frame to
// frame (a changed radius changes the texel size, and the shadow's edges
// would crawl).
function ceil16(v: f32): f32 {
    return Mathf.ceil(v * <f32>16) / <f32>16;
}

// Scratch the planner reuses from frame to frame (milestone 13: planning a
// moving camera's frame allocates nothing): a cascade's slice corners, a
// light's cascade distances, and the tile allocation (with its serving
// order).
const sliceScratch = new Array<Vec3>();
const farsScratch = new Array<f32>();
const allocScratch = new ShadowAllocation();

// The 8 world corners of the camera's view volume between view distances
// `d0` and `d1` (along its forward): the frustum slice a cascade covers,
// written into `out` (emptied first).
function sliceCorners(f: RenderFrame, d0: f32, d1: f32, out: Array<Vec3>): Array<Vec3> {
    const cam = f.camera;
    const aspect: f32 = f.width > 0 && f.height > 0 ? <f32>f.width / <f32>f.height : <f32>1;
    const toWorld = cam.viewMatrix().inverse();
    out.length = 0;
    for (let k = 0; k < 2; k++) {
        const d = k == 0 ? d0 : d1;
        // Half the slice's height at distance d: it grows with d in a
        // perspective view and is the box's in an orthographic one.
        const hh = cam.isOrtho() ? cam.projection.value : d * tanf(toRadians(cam.projection.value) * <f32>0.5);
        const hw = hh * aspect;
        for (let c = 0; c < 4; c++) {
            const x = (c & 1) != 0 ? hw : -hw;
            const y = (c & 2) != 0 ? hh : -hh;
            // View space looks down -Z.
            out.push(toWorld.transformPoint3(Vec3(x, y, -d)));
        }
    }
    return out;
}

// The view depth a directional light's max distance and cascades are
// measured from: the eye's (0) in a perspective view. An orthographic
// view's eye sits wherever the camera put it (Camera.frame moves it back as
// the picture narrows), so there they start at the nearest depth of what is
// drawn (`f.drawBounds`), and at the near plane when nothing is: the same
// scene then keeps its shadows at any picture size.
function shadowOrigin(f: RenderFrame): f32 {
    const cam = f.camera;
    if (!cam.isOrtho()) return 0;
    let origin = cam.near;
    if (f.hasDrawBounds) {
        const view = cam.viewMatrix();
        const bb = f.drawBounds;
        let nearest = f32.MAX_VALUE;
        // View space looks down -Z, so a corner's depth is -z.
        for (let i = 0; i < 8; i++) nearest = minF32(nearest, -view.transformPoint3(bb.corner(i)).z);
        origin = maxF32(origin, nearest);
    }
    return origin;
}

// The far view distances of a directional light's cascades, `maxDistance`
// past `origin` (shadowOrigin), written into `out` (emptied first).
function cascadeFars(l: LightDesc, origin: f32, maxDistance: f32, out: Array<f32>): Array<f32> {
    out.length = 0;
    if (l.directionalShadowMode == SHADOW_PARALLEL_2_SPLITS) {
        out.push(origin + l.shadowSplits.x * maxDistance);
    } else if (l.directionalShadowMode != SHADOW_ORTHOGONAL) {
        out.push(origin + l.shadowSplits.x * maxDistance);
        out.push(origin + l.shadowSplits.y * maxDistance);
        out.push(origin + l.shadowSplits.z * maxDistance);
    }
    out.push(origin + maxDistance);
    return out;
}

// One cascade of a directional light: an orthographic view that holds the
// camera's slice `corners` (and, towards the light, every caster that can
// shade it), snapped to whole texels.
function cascadeTile(f: RenderFrame, dir: Vec3, corners: Array<Vec3>, tileSize: u32, t: ShadowTile): void {
    let c = VEC3_ZERO;
    for (let i = 0; i < corners.length; i++) c = c + corners[i];
    c = c * (<f32>1 / <f32>corners.length);
    let far: f32 = 0;
    for (let i = 0; i < corners.length; i++) far = maxF32(far, corners[i].distance(c));
    // A sphere around the slice rather than a tight box, so that turning
    // the camera does not change the radius (nor the texel size). The
    // margin of 2 texels keeps the slice inside the box once the snap below
    // has moved it by up to half a texel's diagonal.
    const r = maxF32(ceil16(far * (<f32>1 + <f32>2 / <f32>tileSize)), <f32>1 / <f32>16);
    const texel = <f32>2 * r / <f32>tileSize;
    // Casters between the light and the slice shade it though they are
    // outside the sphere: the eye moves back to hold them.
    let pull: f32 = 0;
    if (f.hasCasters) {
        const cb = f.casterBounds;
        for (let i = 0; i < 8; i++) pull = maxF32(pull, (cb.corner(i) - c).dot(-dir) - r);
    }
    const up = lightUp(dir);
    // Snap in a light space anchored at the world's origin, so the texel
    // grid is fixed in the world and a moving camera does not make the
    // shadow's edges shimmer: the centre's x and y there go to whole texels.
    const rot = camera.lookToMat4Rh(VEC3_ZERO, dir, up);
    const lc = rot.transformPoint3(c);
    const sx = Mathf.round(lc.x / texel) * texel;
    const sy = Mathf.round(lc.y / texel) * texel;
    const snapped = rot.inverse().transformPoint3(Vec3(sx, sy, lc.z));
    const eye = snapped - dir * (r + pull);
    const view = camera.lookToMat4Rh(eye, dir, up);
    const proj = camera.orthographicRhDirectx(-r, r, -r, r, 0, <f32>2 * r + pull);
    t.viewProj = proj * view;
    t.texel = Vec4(texel, 0, 0, 0);
}

// A perspective tile from `eye` along `dir`: a spot's cone or an omni's
// cube face. `fov` is in radians.
function perspectiveTile(eye: Vec3, dir: Vec3, up: Vec3, fov: f32, range: f32, tileSize: u32, t: ShadowTile): void {
    const view = camera.lookToMat4Rh(eye, dir, up);
    // The far plane stays past the near one for a light of no range.
    const proj = camera.perspectiveRhDirectx(fov, 1, SHADOW_NEAR, maxF32(range, SHADOW_NEAR + <f32>0.01));
    t.viewProj = proj * view;
    t.texel = Vec4(0, <f32>2 * tanf(fov * <f32>0.5) / <f32>tileSize, 0, 0);
}

// The world direction of an omni light's cube face `part` (+X -X +Y -Y +Z
// -Z), and its up vector.
function omniFaceDir(part: i32): Vec3 {
    switch (part) {
        case 0: return Vec3(1, 0, 0);
        case 1: return Vec3(-1, 0, 0);
        case 2: return Vec3(0, 1, 0);
        case 3: return Vec3(0, -1, 0);
        case 4: return Vec3(0, 0, 1);
        default: return Vec3(0, 0, -1);
    }
}

function omniFaceUp(part: i32): Vec3 {
    return part < 4 ? VEC3_Z : VEC3_Y;
}

// The shadows of frame `f` in an atlas of `atlasSize` texels (from
// `shadowAtlasSize`; 0: none). Pure. The tiles, matrices and uniform
// follow this file's header (and docs/formats/RSCN.md, "Shadows").
//
// Only the lit mode shades by lights, so any other frame plans nothing
// (not even `dropped`: nothing is missing from its picture). Plans the
// frame's lights for its camera first (light_select.as prepareLights), as
// a frame no renderer drew has no pool yet.
export function planShadows(f: RenderFrame, atlasSize: u32 = SHADOW_ATLAS_SIZE): ShadowPlan {
    prepareLights(f);
    return planShadowsInto(f, atlasSize, new ShadowPlan());
}

// `planShadows` into `out`, returned, for a renderer that plans every frame
// (milestone 13): every field of `out` is set again, its arrays refilled in
// place and its tile objects reused, so planning the same frame again (a
// moved camera) allocates nothing. Its values are `planShadows`'s exactly
// (that is the same code: `planShadows` fills a new plan), from the pool
// `f.lightPlan` holds (the renderer plans it for the view first).
export function planShadowsInto(f: RenderFrame, atlasSize: u32, out: ShadowPlan): ShadowPlan {
    const plan = out;
    plan.atlasSize = 0;
    plan.tileSize = 0;
    plan.tiles.length = 0;
    plan.dropped.length = 0;
    plan.uniform.atlas = VEC4_ZERO;
    plan.uniform.lights.length = 0;
    plan.uniform.tiles.length = 0;
    const n = f.lights.length;
    const slots = plan.slots;
    slots.length = n;
    for (let i = 0; i < n; i++) unchecked(slots[i] = -1);
    if (f.shading != SHADE_LIT) return plan;
    const a = allocateFrameShadowsInto(f, staticShadowsUnused(f), allocScratch);
    for (let i = 0; i < a.dropped.length; i++) plan.dropped.push(a.dropped[i]);
    if (atlasSize == 0 || a.used == 0) return plan;

    const tileSize = atlasSize / SHADOW_ATLAS_GRID;
    const atlas = <f32>atlasSize;
    plan.atlasSize = atlasSize;
    plan.tileSize = tileSize;
    plan.uniform.atlas = Vec4(<f32>1 / atlas, atlas, <f32>a.used, 0);
    // Omni faces are a little wider than 90 degrees: 1.5 texels past each
    // edge, so a PCF tap near a face's edge still reads its own face.
    const omniFov = <f32>2 * atanf(<f32>1 + <f32>3 / <f32>tileSize);

    // The chosen lights in pool order: their tiles follow one another from
    // tile 0, and their shadow-block entries are their slots (0, 1, ...).
    const pool = f.lightPlan;
    for (let k = 0; k < pool.count; k++) {
        const i = pool.lightAt(k);
        const l = f.lights[i];
        const count = a.count[i];
        if (count == 0) continue;
        const first = a.first[i];
        let splits = VEC4_ZERO;
        let fade = VEC4_ZERO;
        const fars = farsScratch;
        fars.length = 0;
        let origin: f32 = 0;
        if (l.kind == LIGHT_DIRECTIONAL) {
            // The shader compares view depths with these as they are, so
            // the origin is folded into the splits and the fade.
            origin = shadowOrigin(f);
            const maxDistance = minF32(l.shadowMaxDistance, f.camera.far - origin);
            cascadeFars(l, origin, maxDistance, fars);
            const last = fars[fars.length - 1];
            splits = Vec4(
                fars[0], fars.length > 1 ? fars[1] : last, fars.length > 2 ? fars[2] : last, last,
            );
            fade = Vec4(origin + l.shadowFadeStart * maxDistance, origin + maxDistance, 0, 0);
        }
        for (let part = 0; part < count; part++) {
            const t = plan.takeTile(plan.tiles.length);
            t.index = first + part;
            t.light = i;
            t.part = part;
            const o = tileOrigin(t.index, atlasSize);
            t.x = <u32>o.x;
            t.y = <u32>o.y;
            t.size = tileSize;
            if (l.kind == LIGHT_DIRECTIONAL) {
                // Cascade 0 starts at the camera's near plane (at the origin
                // in an orthographic view), each next one where the last
                // ended.
                const d0 = part == 0 ? maxF32(f.camera.near, origin) : fars[part - 1];
                const d1 = maxF32(fars[part], d0);
                cascadeTile(f, lightDir(l), sliceCorners(f, d0, d1, sliceScratch), tileSize, t);
            } else if (l.kind == LIGHT_OMNI) {
                perspectiveTile(l.position, omniFaceDir(part), omniFaceUp(part), omniFov, l.range, tileSize, t);
            } else {
                const dir = lightDir(l);
                const fov = <f32>2 * toRadians(minF32(l.spotAngle, MAX_SPOT_SHADOW_HALF_ANGLE));
                perspectiveTile(l.position, dir, lightUp(dir), fov, l.range, tileSize, t);
            }
            plan.tiles.push(t);
            plan.uniform.tiles.push(ShadowTileUniform(
                t.viewProj, Vec4(o.x / atlas, o.y / atlas, o.z / atlas, o.w / atlas), t.texel));
        }
        plan.uniform.lights.push(ShadowLightUniform(
            Vec4(l.shadowBias, l.shadowNormalBias, maxF32(l.shadowBlur, 0), clampF32(l.shadowOpacity, 0, 1)),
            splits, fade, U32x4(<u32>first, <u32>count, l.kind, 0)));
        unchecked(slots[i] = a.slot[i]);
    }
    return plan;
}
