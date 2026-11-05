// The lit mode's uniform block (surface.wgsl's LitU at group 0, binding 1)
// from a frame's lights and environment. Pure: no GPU, so a Tests suite
// checks the bytes (editor/program/tests/render/lit_test.as), and the
// renderer writes `litUniformInto`'s for every view (its header and the
// view's pool of lights: gpu/layouts.as LitUniform.writeUsedAt). Milestone
// 59: the block holds the pool light_select.as chose for the view (up to
// 64 lights, in the scene's order), each item naming up to 8 of them.
//
// What the shader then does with it is Godot 4's photometry
// (frame.as `LightDesc`): the pi factor is folded into the colour here, so
// the shader's Lambert term (albedo / pi) shows a white surface square to a
// directional light of energy 1 at its albedo.

import { Vec3, Vec4, cosf, toRadians } from "../base/vecmath";
import { LIGHT_BAKE_STATIC, LIGHT_DIRECTIONAL, RenderFrame, TONEMAP_LINEAR, LightDesc } from "./frame";
import {
    ENV_AMBIENT_SKY, ENV_HDR, ENV_SCREEN_REFRACTION, ENV_SKY, ENV_SSAO, LIGHT_BAKED_STATIC, LIGHT_SHADOWED, LightUniform, LitUniform, U32x4,
} from "./gpu/layouts";
import { LightPlan } from "./light_pool";
import { prepareLights } from "./light_select";
import { PostPlan } from "./post";
import { ShadowPlan } from "./shadow";

const PI: f32 = 3.14159265358979323846;

// The shortest omni or spot range packed: `1 / range` must stay finite, and a
// light this small lights nothing anyway.
const MIN_RANGE: f32 = 1e-4;

// One light as the shader reads it (LightU). `slot`: the light samples its
// shadow from that slot of the shadow block (info.y = LIGHT_SHADOWED, info.w
// = the slot; shadow.as `planShadows` decides), or -1 (info.y and w 0).
// Milestone 19: info.z is LIGHT_BAKED_STATIC for a light whose bakeMode is
// LIGHT_BAKE_STATIC (its direct light is in the lightmap, so a lightmapped
// surface skips it), else 0; only the lightmap entry points read it, so
// every other draw is what it was.
export function lightUniform(l: LightDesc, slot: i32 = -1): LightUniform {
    const c = l.color * (l.energy * PI);
    const directional = l.kind == LIGHT_DIRECTIONAL;
    const invRange: f32 = directional ? 0 : <f32>1.0 / max<f32>(l.range, MIN_RANGE);
    const dir = l.direction.normalizeOr(Vec3(0, 0, -1));
    const shadowed = slot >= 0;
    return LightUniform(
        Vec4(c.x, c.y, c.z, 0),
        Vec4(l.position.x, l.position.y, l.position.z, invRange),
        Vec4(dir.x, dir.y, dir.z, l.attenuation),
        Vec4(cosf(toRadians(l.spotAngle)), l.spotAngleAttenuation, l.specular, 0),
        U32x4(l.kind, shadowed ? LIGHT_SHADOWED : 0, l.bakeMode == LIGHT_BAKE_STATIC ? LIGHT_BAKED_STATIC : 0,
            shadowed ? <u32>slot : 0),
    );
}

// The four pool entries `dirs[from..from + 3]` (the first `count`), a byte
// each, the first in the low byte (LitUniform.dirs' x and y).
function packEntries(dirs: StaticArray<i32>, from: i32, count: i32): u32 {
    let word: u32 = 0;
    for (let k = from; k < from + 4 && k < count; k++) {
        word |= <u32>(unchecked(dirs[k]) & 0xff) << (<u32>(k - from) * 8);
    }
    return word;
}

// The block of frame `f`: the lights of its pool (light_select.as
// `prepareLights`, for the frame's camera; light_pool.as says how they are
// chosen), in pool order, its directional entries, the environment's ENV_*
// bits, colours and tone values, and the inverse of the view-projection the
// frame is drawn with (frameGlobals'), which the sky pass turns into view
// rays. `shadows` (null: none) is the frame's shadow plan (shadow.as
// `planShadows`): its `slots` mark the lights whose shadow the frame
// draws, and where; without one, the bytes are what they were before
// shadows existed. `post` is the frame's post-processing (post.as
// `planPost`; null or empty: the bytes are what they were before it
// existed): with `ssao`, ENV_SSAO and the SSAO's two light factors in
// tone.zw; with `toneInPost`, ENV_HDR and the tone map linear at exposure
// 1 and white 1, so lit() and the sky write HDR colour, unclamped
// (surface.wgsl `lit_output`), for the glow to threshold and the post pass
// to tone map. Milestone 62: with `refraction` (the main pass drawn in two,
// the screen texture made between them), ENV_SCREEN_REFRACTION and the
// texture's mips in dirs.w, so the glass samples the opaque picture.
export function litUniform(f: RenderFrame, shadows: ShadowPlan? = null, post: PostPlan? = null): LitUniform {
    prepareLights(f);
    return litUniformInto(f, shadows, post, new LitUniform());
}

// `litUniform` into `out`, returned (milestone 13; see shadow.as
// `planShadowsInto`), from the pool `f.lightPlan` holds (the renderer's
// planLightPool for the view, before it planned `shadows`): every field set
// again and the lights refilled in place, so the same frame from a moved
// camera allocates nothing. The same block exactly (`litUniform` fills a
// new one).
export function litUniformInto(f: RenderFrame, shadows: ShadowPlan?, post: PostPlan?, out: LitUniform): LitUniform {
    const u = out;
    u.lights.length = 0;
    const plan: LightPlan = f.lightPlan;
    const lights = f.lights;
    const n = plan.count;
    for (let k = 0; k < n; k++) {
        const i = plan.lightAt(k);
        let slot = -1;
        if (shadows != null) {
            const slots = shadows.slots;
            if (i < slots.length) slot = unchecked(slots[i]);
        }
        u.lights.push(lightUniform(unchecked(lights[i]), slot));
    }
    const dirCount = plan.dirCount;
    // (milestone 62: with the screen-space refraction, the screen texture's
    // mips in w, beside ENV_SCREEN_REFRACTION below; 0 otherwise)
    const levels: u32 = post != null && post.refraction ? <u32>max<i32>(post.screenLevels, 0) : 0;
    u.dirs = U32x4(packEntries(plan.dirs, 0, dirCount), packEntries(plan.dirs, 4, dirCount), <u32>dirCount, levels);
    const e = f.environment;
    let bits: u32 = 0;
    if (e.sky) bits |= ENV_SKY;
    if (e.ambientFromSky) bits |= ENV_AMBIENT_SKY;
    let tonemap = e.tonemap;
    let tone = Vec4(e.exposure, e.white, 0, 0);
    if (post != null) {
        if (post.ssao) {
            bits |= ENV_SSAO;
            tone = Vec4(tone.x, tone.y, e.ssao.lightAffect, e.ssao.aoChannelAffect);
        }
        if (post.toneInPost) {
            bits |= ENV_HDR;
            tonemap = TONEMAP_LINEAR;
            tone = Vec4(1, 1, tone.z, tone.w);
        }
        if (post.refraction) bits |= ENV_SCREEN_REFRACTION;
    }
    u.counts = U32x4(<u32>n, bits, tonemap, 0);
    u.ambient = Vec4(e.ambient.x, e.ambient.y, e.ambient.z, e.ambientEnergy);
    u.tone = tone;
    const up = e.up.normalizeOr(Vec3(0, 0, 1));
    u.up = Vec4(up.x, up.y, up.z, 0);
    u.skyTop = e.skyTop.extend(1);
    u.skyHorizon = e.skyHorizon.extend(1);
    u.groundHorizon = e.groundHorizon.extend(1);
    u.groundBottom = e.groundBottom.extend(1);
    // frameGlobals' view-projection, computed as it does (no Globals block
    // made for one matrix).
    const aspect = <f32>f.width / <f32>f.height;
    u.invViewProj = (f.camera.projectionMatrix(aspect) * f.camera.viewMatrix()).inverse();
    return u;
}
