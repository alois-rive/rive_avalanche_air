// A scene's lights and environment as the lit mode draws them
// (hedra_engine/render/frame.as, LightDesc and EnvironmentDesc), decisions 4 to 6
// of milestone 4. The photometry is Godot 4's (frame.as says how the shader
// reads it), so a light's colour and energy mean what they mean in Godot;
// a scene without a light or an environment gets what Godot's editor shows
// then: the preview sun and the preview environment.
//
// Everything here is in render space (Hedra's Z up: SCENE_TO_MODEL of the
// scene's Y up, ../space.as); colours are turned linear, and the frame's
// clear colour, which is sRGB, is tone mapped as the surfaces are (or, with
// the glow on, left for the post pass to tone map: milestone 12).

import { Mat4, Vec3, Vec4, VEC3_NEG_Z, VEC3_ZERO } from "../../base/vecmath";
import { srgbToLinear } from "../../render/image";
import {
    AdjustmentDesc, EnvironmentDesc, FOG_DEPTH, FOG_EXPONENTIAL, FogDesc, GLOW_BLEND_ADDITIVE, GLOW_BLEND_MIX,
    GlowDesc, LIGHT_BAKE_DISABLED, LIGHT_BAKE_DYNAMIC, LIGHT_DIRECTIONAL, LIGHT_OMNI, LIGHT_SPOT, LightDesc,
    REFLECT_BACKGROUND, REFLECT_SKY, RenderFrame,
    SHADOW_ORTHOGONAL, SHADOW_PARALLEL_4_SPLITS, SKY_PANORAMA, SKY_PROCEDURAL, SkyDesc, SsaoDesc, TONEMAP_ACES,
    TONEMAP_AGX, TONEMAP_FILMIC, TONEMAP_LINEAR, TONEMAP_REINHARD,
} from "../../render/frame";
import { LightPlan, MAX_FRAME_LIGHTS } from "../../render/light_pool";
import { toneMap } from "../../render/post";
import { SsrDesc } from "../../render/screen";
import { linearToSrgb, linearToSrgbValue } from "../../base/color";
import { MODEL_TO_SCENE, SCENE_TO_MODEL } from "../space";
import { Environment, PanoramaSkyMaterial, ProceduralSkyMaterial, Resource, Sky } from "../resource/types";
import { resourceLabel } from "./materials";
import { Light3D } from "../tree/node";
import { basisFromEulerYXZ } from "../tree/xform";

// Godot's default clear colour (sRGB): what a scene whose environment clears
// to the clear colour shows.
export const CLEAR_COLOR: Vec4 = Vec4(0.3, 0.3, 0.3, 1);

// Environment.ambient_light_source (Godot's numbers).
export const AMBIENT_BACKGROUND: i32 = 0;
export const AMBIENT_DISABLED: i32 = 1;
export const AMBIENT_COLOR: i32 = 2;
export const AMBIENT_SKY: i32 = 3;

// The preview sun's rotation_degrees (Euler YXZ, as a node's), Godot's
// editor's: from above, behind the default view's right shoulder.
export const PREVIEW_SUN_DEGREES: Vec3 = Vec3(-60, 150, 0);

function linear(c: Vec4): Vec3 {
    return Vec3(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z));
}

// The direction a node's -Z points to in render space, unit length.
function aim(global: Mat4): Vec3 {
    return (SCENE_TO_MODEL * global).transformVector3(VEC3_NEG_Z).normalizeOrZero();
}

// A light node as a LightDesc: its kind, linear colour, energy, and its
// global origin and -Z in render space, with its range, cone and shadow.
export function lightDesc(l: Light3D): LightDesc {
    const d = new LightDesc();
    lightDescInto(d, l);
    return d;
}

// lightDesc into `d`, allocating nothing (milestone 50: a frame refreshed
// in place, adapter.as refreshSceneFrame).
export function lightDescInto(d: LightDesc, l: Light3D): void {
    if (l.className == "OmniLight3D") d.kind = LIGHT_OMNI;
    else if (l.className == "SpotLight3D") d.kind = LIGHT_SPOT;
    else d.kind = LIGHT_DIRECTIONAL;
    d.color = linear(l.color);
    d.energy = l.energy;
    d.specular = l.specular;
    const g = l.global();
    d.position = (SCENE_TO_MODEL * g).transformPoint3(VEC3_ZERO);
    d.direction = aim(g);
    d.range = l.range;
    d.attenuation = l.attenuation;
    d.spotAngle = l.spotAngle;
    d.spotAngleAttenuation = l.spotAngleAttenuation;
    // The shadow (milestone 10). An enum out of range is drawn as the
    // nearest mode, as the renderer knows only these three.
    d.shadow = l.shadow;
    d.shadowBias = l.shadowBias;
    d.shadowNormalBias = l.shadowNormalBias;
    d.shadowBlur = l.shadowBlur;
    d.shadowOpacity = l.shadowOpacity;
    d.directionalShadowMode = <u32>min<i32>(max<i32>(l.directionalShadowMode, <i32>SHADOW_ORTHOGONAL),
        <i32>SHADOW_PARALLEL_4_SPLITS);
    d.shadowSplits = l.shadowSplits;
    d.shadowMaxDistance = l.shadowMaxDistance;
    d.shadowFadeStart = l.shadowFadeStart;
    // The sun disc a procedural sky draws (milestone 11; 0 for the others).
    d.angularDistance = l.angularDistance;
    // Milestone 19: what a bake does with it (an enum out of range is the
    // nearest mode); a negative size or energy is none.
    d.bakeMode = <u32>min<i32>(max<i32>(l.bakeMode, <i32>LIGHT_BAKE_DISABLED), <i32>LIGHT_BAKE_DYNAMIC);
    d.size = max<f32>(l.size, 0);
    d.indirectEnergy = max<f32>(l.indirectEnergy, 0);
    // (milestone 37: Godot does not clamp it; a negative one darkens fog)
    d.fogEnergy = l.fogEnergy;
}

// The lights a pool warning names before it counts the rest ("..., and 3
// more"): enough to find the far ones in the Scene dock, short enough for
// one line of the Output panel.
export const POOL_WARNING_NAMED: i32 = 8;

// The warning of a frame whose view holds more lights than its pool
// (light_pool.as MAX_FRAME_LIGHTS), or "" when `plan` (planned for the
// frame's camera) dropped none: how many are in view, how many are not
// drawn, and the dropped lights' node paths in the scene's order, the first
// POOL_WARNING_NAMED of them (`nodes` by frame light index: the frame's
// lights are its visible lights in tree order, as the adapter gathers
// them). Godot's Compatibility renderer caps a frame at its
// max_renderable_lights (32) without a word; Hedra's lit block holds 64
// (WebGL 2 has no storage buffers), keeps the nearest, and names the rest.
export function lightPoolWarning(plan: LightPlan, nodes: Array<Light3D>): string {
    const dropped = plan.dropped;
    if (dropped <= 0) return "";
    const names = new Array<string>();
    const shown = min<i32>(dropped, POOL_WARNING_NAMED);
    for (let k = 0; k < shown && k < plan.droppedLights.length; k++) {
        const i = plan.droppedLights[k];
        names.push(i >= 0 && i < nodes.length ? nodes[i].path() : "light " + i.toString());
    }
    let text = plan.visible.toString() + " lights in view: " + dropped.toString() + (dropped == 1 ? " is" : " are")
        + " not drawn (at most " + MAX_FRAME_LIGHTS.toString() + " a frame): " + names.join(", ");
    if (dropped > shown) text += ", and " + (dropped - shown).toString() + " more";
    return text;
}

// Godot's editor's preview sun: a white directional light of energy 1 at
// PREVIEW_SUN_DEGREES. It casts no shadow (Godot's editor sun does), so a
// scene without lights draws as it did before shadows existed.
export function previewSun(): LightDesc {
    const d = new LightDesc();
    d.kind = LIGHT_DIRECTIONAL;
    d.color = Vec3(1, 1, 1);
    d.energy = 1;
    // Converted in f64 as a node's rotation_degrees is (tree/xform.as), so
    // the sun matches a node written with the same angles.
    const deg: f64 = Math.PI / 180;
    const r = PREVIEW_SUN_DEGREES;
    const b = basisFromEulerYXZ(Vec3(<f32>(<f64>r.x * deg), <f32>(<f64>r.y * deg), <f32>(<f64>r.z * deg)));
    d.direction = aim(Mat4(b.xAxis.extend(0), b.yAxis.extend(0), b.zAxis.extend(0), Vec4(0, 0, 0, 1)));
    return d;
}

// Sets `frame.environment` and `frame.background` from an Environment
// (decision 5 of milestone 4, milestone 11's sky and fog, and milestone
// 12's tone curves and post-processing); null gives the preview
// environment. Every tone map mode is drawn, so none warns any more.
//
// An environment without a Sky (or whose Sky has no material) keeps
// milestone 4's gradient and ambient, computed as before, so such a scene
// draws the same bytes; background_energy_multiplier scales its clear or
// background colour (exact at the default 1). With a Sky, the frame gets a
// SkyDesc and the renderer lights the scene from it (frame.as says how the
// sources are read).
//
// Milestone 62: the Environment's screen-space reflections (its five
// ssr_*, as written: the renderer clamps them) and screen refraction go to
// EnvironmentDesc.ssr and .screenRefraction; `exposureMultiplier` (the
// frame's camera attributes' exposure_multiplier, ./screen.as) multiplies
// tonemap_exposure, the clear colour's tone map included (1, the default,
// changes no byte); and every environment without a sky keeps its clear
// colour before the tone map (`postBackground`), which the renderer reads
// only when the final pass tone maps (the glow or a screen-space effect
// drawn: post.as PostPlan.toneInPost), so that a frame whose effects
// depend on its camera (the depth of field) or its materials (the
// refraction) finds it whatever they come to.
export function environmentDesc(env: Environment?, frame: RenderFrame, warnings: Array<string>, exposureMultiplier: f32 = 1): void {
    if (env == null) {
        previewEnvironment(frame, exposureMultiplier);
        return;
    }
    const e = new EnvironmentDesc();
    const sky = env.backgroundMode == 2;
    e.sky = sky;
    e.skyTop = linear(env.skyTopColor);
    e.skyHorizon = linear(env.skyHorizonColor);
    e.groundHorizon = linear(env.groundHorizonColor);
    e.groundBottom = linear(env.groundBottomColor);
    // The ambient light by ambient_light_source, as Godot's: background
    // (the default) is the sky times ambient_light_energy under a sky, and
    // over a colour that colour times background_energy_multiplier; color
    // is ambient_light_color times ambient_light_energy; sky is the sky's,
    // whatever the background; disabled is none.
    const bg = env.backgroundColor;
    const clear = env.backgroundMode == 1 ? Vec4(bg.x, bg.y, bg.z, 1) : CLEAR_COLOR;
    const bgEnergy = env.backgroundEnergy;
    const source = env.ambientLightSource;
    const material = skyMaterialOf(env, warnings);
    e.ambientEnergy = env.ambientLightEnergy;
    if (source == AMBIENT_SKY || (source == AMBIENT_BACKGROUND && sky)) {
        e.ambientFromSky = true;
        // With a Sky the flat colour is what ambient_light_sky_contribution
        // mixes the sky's irradiance with (Godot's); milestone 4's gradient
        // ambient reads nothing of it.
        if (material != null) e.ambient = linear(env.ambientLightColor) * env.ambientLightEnergy;
    } else if (source == AMBIENT_BACKGROUND) {
        e.ambient = linear(clear) * bgEnergy;
    } else if (source == AMBIENT_COLOR) {
        e.ambient = linear(env.ambientLightColor) * env.ambientLightEnergy;
    }
    // Render space is Z up (EnvironmentDesc's default up says so too).
    e.up = Vec3(0, 0, 1);
    const tm = env.tonemapMode;
    e.tonemap = tm >= 0 && tm <= <i32>TONEMAP_AGX ? <u32>tm : TONEMAP_LINEAR;
    e.exposure = env.tonemapExposure * exposureMultiplier;
    // Godot's inspector keeps tonemap_white to 1..16; at 0 the curves
    // divide by 0 and draw the whole picture white.
    e.white = min<f32>(max<f32>(env.tonemapWhite, 1), 16);
    // Read by the renderer only with a Sky (frame.as); set either way so the
    // description says what the file says.
    e.backgroundEnergy = bgEnergy;
    e.ambientSkyContribution = env.ambientLightSkyContribution;
    e.reflectedSource = <u32>min<i32>(max<i32>(env.reflectedLightSource, <i32>REFLECT_BACKGROUND), <i32>REFLECT_SKY);
    if (material != null) e.skyDesc = skyDesc(env, material, warnings);
    e.fog = fogDesc(env);
    e.glow = glowDesc(env);
    e.ssao = ssaoDesc(env);
    e.adjustment = adjustmentDesc(env);
    ssrInto(env, e.ssr);
    e.screenRefraction.enabled = env.screenRefractionEnabled;
    frame.environment = e;
    // What shows where nothing is drawn: the clear colour or the colour,
    // exposed and tone mapped as Godot draws its HDR buffer; or (under the
    // sky, and should the sky pass not run, which tone maps its own) the
    // horizon: the gradient's, a procedural sky's, or a panorama's black.
    // The picture is opaque whatever alpha the colour has. With the glow
    // drawn the main pass keeps HDR colour and the post pass exposes and
    // tone maps it (post.as), so the clear colour the renderer uses then
    // (`e.postBackground`) is only scaled by its energy. It is carried as
    // sRGB values but not clipped: the renderer turns it back to linear
    // and clears the half-float target (the only one the post passes run
    // on) to those floats, so one brighter than 1 reaches the tone map and
    // the glow's threshold as it is. `frame.background` stays tone mapped
    // for a renderer that cannot run the post passes.
    if (sky) {
        let hz = env.skyHorizonColor;
        if (material != null && material.className() == "ProceduralSkyMaterial") {
            hz = (material as ProceduralSkyMaterial).skyHorizonColor;
        }
        else if (material != null) hz = Vec4(0, 0, 0, 1);
        frame.background = Vec4(hz.x, hz.y, hz.z, 1);
    } else {
        const l = linear(clear) * bgEnergy;
        const t = toneMapped(l, e);
        frame.background = Vec4(linearToSrgbValue(t.x), linearToSrgbValue(t.y), linearToSrgbValue(t.z), 1);
        // (milestone 62: set for every environment without a sky, not only
        // with the glow; read only when the final pass tone maps)
        e.hasPostBackground = true;
        e.postBackground = Vec4(linearToSrgbValue(l.x), linearToSrgbValue(l.y), linearToSrgbValue(l.z), 1);
    }
}

// Milestone 62: Godot's ssr_* of `env` into `out`, as written.
function ssrInto(env: Environment, out: SsrDesc): void {
    out.enabled = env.ssrEnabled;
    out.maxSteps = env.ssrMaxSteps;
    out.fadeIn = env.ssrFadeIn;
    out.fadeOut = env.ssrFadeOut;
    out.depthTolerance = env.ssrDepthTolerance;
}

// Milestone 62: `frame`'s environment, made by environmentDesc from `env`
// (null: the preview environment), exposed again for the camera
// attributes' `exposureMultiplier` in place: its exposure, and the clear
// colour tone mapped with it when it draws no sky (opaque: a caller that
// draws transparent_bg clears to alpha 0 itself), as environmentDesc
// would set them. A refresh in place calls it when a binding, a timeline
// or a tween moved the multiplier; allocates nothing.
export function exposeEnvironmentInto(env: Environment?, frame: RenderFrame, exposureMultiplier: f32): void {
    const e = frame.environment;
    if (env == null) {
        // (the preview environment: Environment's default exposure, 1,
        // under a sky, whose clear colour is its horizon)
        e.exposure = exposureMultiplier;
        return;
    }
    e.exposure = env.tonemapExposure * exposureMultiplier;
    if (env.backgroundMode == 2) return;
    const bg = env.backgroundColor;
    const clear = env.backgroundMode == 1 ? Vec4(bg.x, bg.y, bg.z, 1) : CLEAR_COLOR;
    const l = linear(clear) * env.backgroundEnergy;
    const t = toneMapped(l, e);
    // (linearToSrgb, not environmentDesc's linearToSrgbValue, which looks
    // for the shortest decimal and allocates doing it: the colour is the
    // same to within a step of an f32, and a refresh allocates nothing)
    frame.background = Vec4(linearToSrgb(t.x), linearToSrgb(t.y), linearToSrgb(t.z), 1);
}

// Milestone 20: the colour the main view clears to behind the scene when
// its environment draws no sky, linear, before exposure and the tone map
// (what environmentDesc tone maps into frame.background, and keeps as
// EnvironmentDesc.postBackground with the glow): background_color times
// background_energy_multiplier for the colour background, Godot's clear
// colour times it for every other mode, and the clear colour itself for
// the preview environment (no Environment). A reflection probe's capture
// sees it where it sees neither a surface nor a sky
// (ReflectionProbeSet.clear, probes.as).
export function clearColorLinear(env: Environment?): Vec3 {
    if (env == null) return linear(CLEAR_COLOR);
    const bg = env.backgroundColor;
    const clear = env.backgroundMode == 1 ? Vec4(bg.x, bg.y, bg.z, 1) : CLEAR_COLOR;
    return linear(clear) * env.backgroundEnergy;
}

// The material of the environment's Sky, or null when there is no Sky or
// it has none (then the environment draws as one without a Sky, with a
// warning).
function skyMaterialOf(env: Environment, warnings: Array<string>): Resource? {
    const sky = env.sky;
    if (sky == null) return null;
    const m = sky.skyMaterial;
    if (m == null) {
        warnings.push("environment: sky " + resourceLabel(sky) + " has no sky_material; the environment's own sky colours are drawn");
        return null;
    }
    return m;
}

// The Sky's material as the renderer's SkyDesc (linear colours), with the
// direction from render space to sky space.
function skyDesc(env: Environment, material: Resource, warnings: Array<string>): SkyDesc {
    return skyDescOf(env.sky as Sky, material, env.skyRotation, warnings);
}

// `sky` with its material `material` as the renderer's SkyDesc, turned by
// `rotation` (Euler degrees, YXZ, as Environment.sky_rotation): the scene's
// sky above, and milestone 19's LightmapGI environment_custom_sky (not
// turned), which the bake reads (compiler/src/bake/bake.as).
export function skyDescOf(sky: Sky, material: Resource, rotation: Vec3, warnings: Array<string>): SkyDesc {
    const d = new SkyDesc();
    // Render space to scene space (Y up), then the sky turned by
    // sky_rotation: a direction of the sky is seen in the scene at R d, so
    // the scene's direction is looked up at R^-1 (a rotation: its
    // transpose, exact).
    const r = basisFromEulerYXZ(rotation).transpose();
    d.toSky = Mat4(r.xAxis.extend(0), r.yAxis.extend(0), r.zAxis.extend(0), Vec4(0, 0, 0, 1)) * MODEL_TO_SCENE;
    d.radianceSize = <u32>32 << <u32>min<i32>(max<i32>(sky.radianceSize, 0), 6);
    // By class name, not `instanceof`: with `instanceof` here, this function
    // trapped (an out-of-bounds memory access) in sky_adapter_test.as, though
    // the same test in a small function did not. The name is as exact: the
    // two sky materials are the only SkyMaterial classes.
    if (material.className() == "ProceduralSkyMaterial") {
        const m = material as ProceduralSkyMaterial;
        d.kind = SKY_PROCEDURAL;
        d.skyTop = linear(m.skyTopColor);
        d.skyHorizon = linear(m.skyHorizonColor);
        d.skyCurve = m.skyCurve;
        d.skyEnergy = m.skyEnergy;
        d.groundBottom = linear(m.groundBottomColor);
        d.groundHorizon = linear(m.groundHorizonColor);
        d.groundCurve = m.groundCurve;
        d.groundEnergy = m.groundEnergy;
        d.sunAngleMax = m.sunAngleMax;
        d.sunCurve = m.sunCurve;
        d.energy = m.energy;
    } else {
        const m = material as PanoramaSkyMaterial;
        d.kind = SKY_PANORAMA;
        d.filter = m.filter;
        d.energy = m.energy;
        const t = m.panorama;
        d.panorama = t != null ? t.linear() : null;
        if (d.panorama == null) {
            warnings.push("sky material " + resourceLabel(m) + ": it has no panorama; the sky is black");
        }
    }
    return d;
}

// Godot's fog_* properties as the renderer's FogDesc (a linear colour
// times its energy; an unknown mode drawn as the nearest).
function fogDesc(env: Environment): FogDesc {
    const g = new FogDesc();
    g.enabled = env.fogEnabled;
    g.mode = <u32>min<i32>(max<i32>(env.fogMode, <i32>FOG_EXPONENTIAL), <i32>FOG_DEPTH);
    g.color = linear(env.fogLightColor) * env.fogLightEnergy;
    g.sunScatter = env.fogSunScatter;
    g.density = env.fogDensity;
    g.aerialPerspective = env.fogAerialPerspective;
    g.skyAffect = env.fogSkyAffect;
    g.height = env.fogHeight;
    g.heightDensity = env.fogHeightDensity;
    g.depthCurve = env.fogDepthCurve;
    g.depthBegin = env.fogDepthBegin;
    g.depthEnd = env.fogDepthEnd;
    return g;
}

// Godot's glow_* properties as the renderer's GlowDesc: copied as written
// (post.as `glowWeights` reads the levels, intensity and normalized), with
// an unknown blend mode drawn as the nearest.
function glowDesc(env: Environment): GlowDesc {
    const g = new GlowDesc();
    g.enabled = env.glowEnabled;
    const levels = new Array<f32>(env.glowLevels.length);
    for (let i = 0; i < levels.length; i++) levels[i] = env.glowLevels[i];
    g.levels = levels;
    g.normalized = env.glowNormalized;
    g.intensity = env.glowIntensity;
    g.strength = env.glowStrength;
    g.mix = env.glowMix;
    g.bloom = env.glowBloom;
    g.blendMode = <u32>min<i32>(max<i32>(env.glowBlendMode, <i32>GLOW_BLEND_ADDITIVE), <i32>GLOW_BLEND_MIX);
    g.hdrThreshold = env.glowHdrThreshold;
    g.hdrScale = env.glowHdrScale;
    g.hdrLuminanceCap = env.glowHdrLuminanceCap;
    return g;
}

// Godot's ssao_* properties as the renderer's SsaoDesc (the radius in the
// scene's units, which render space keeps).
function ssaoDesc(env: Environment): SsaoDesc {
    const d = new SsaoDesc();
    d.enabled = env.ssaoEnabled;
    d.radius = env.ssaoRadius;
    d.intensity = env.ssaoIntensity;
    d.power = env.ssaoPower;
    d.detail = env.ssaoDetail;
    d.horizon = env.ssaoHorizon;
    d.sharpness = env.ssaoSharpness;
    d.lightAffect = env.ssaoLightAffect;
    d.aoChannelAffect = env.ssaoAoChannelAffect;
    return d;
}

// Godot's adjustment_* properties as the renderer's AdjustmentDesc.
function adjustmentDesc(env: Environment): AdjustmentDesc {
    const a = new AdjustmentDesc();
    a.enabled = env.adjustmentEnabled;
    a.brightness = env.adjustmentBrightness;
    a.contrast = env.adjustmentContrast;
    a.saturation = env.adjustmentSaturation;
    return a;
}

// Godot's filmic curve (surface.wgsl filmic_curve, exposure bias 2 baked
// into A and B).
function filmicCurve(x: f32): f32 {
    const a: f32 = 0.22 * 4.0;
    const b: f32 = 0.30 * 2.0;
    const c: f32 = 0.10;
    const d: f32 = 0.20;
    const e: f32 = 0.01;
    const f: f32 = 0.30;
    return (x * (a * x + c * b) + d * e) / (x * (a * x + b) + d * f) - e / f;
}

function toneMappedValue(x: f32, e: EnvironmentDesc): f32 {
    const c = max<f32>(x * e.exposure, 0);
    const w = e.white;
    if (e.tonemap == TONEMAP_REINHARD) return (w * c + c) / (c * w + w);
    if (e.tonemap == TONEMAP_FILMIC) return filmicCurve(c) / filmicCurve(w);
    return c;
}

// A linear colour exposed and tone mapped as the lit mode's surfaces are
// (surface.wgsl tonemap), clamped to what a picture holds. Linear,
// Reinhard and filmic are computed per channel as before milestone 12 (so
// their bytes stay); ACES and AgX, which mix the channels, are post.as's
// `toneMap`, the shaders' reference.
export function toneMapped(c: Vec3, e: EnvironmentDesc): Vec3 {
    if (e.tonemap == TONEMAP_ACES || e.tonemap == TONEMAP_AGX) {
        const t = toneMap(c, e);
        return Vec3(
            min<f32>(max<f32>(t.x, 0), 1),
            min<f32>(max<f32>(t.y, 0), 1),
            min<f32>(max<f32>(t.z, 0), 1),
        );
    }
    return Vec3(
        min<f32>(toneMappedValue(c.x, e), 1),
        min<f32>(toneMappedValue(c.y, e), 1),
        min<f32>(toneMappedValue(c.z, e), 1),
    );
}

// Godot's editor's preview environment: Environment's defaults under the
// procedural sky, ambient light from the sky at energy 1, filmic tone
// mapping.
// (milestone 62: exposed by the camera attributes' `exposureMultiplier`)
export function previewEnvironment(frame: RenderFrame, exposureMultiplier: f32 = 1): void {
    const env = new Environment();
    env.backgroundMode = 2;
    env.ambientLightEnergy = 1;
    env.tonemapMode = <i32>TONEMAP_FILMIC;
    environmentDesc(env, frame, [], exposureMultiplier);
}
