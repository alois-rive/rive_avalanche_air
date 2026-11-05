// Fog volumes on the GPU (milestone 37; engine/src/render/fog_volume.as
// says how a frame carries them and how a pixel integrates them,
// fog_select.as which ones each view and item draws): the view's fog block
// (layouts.as FogUniform, the object group's FOG_BLOCK_BINDING), filled
// from the view's FogPlan (prepareFogVolumes, which the renderer runs for
// each view right after the items' lights), the frame's volumetric fog,
// its lights' light_volumetric_fog_energy and the ambient light the fog
// takes in, and the pool's warning.
//
// The ambient light (FogUniform.ambient) is what lit() gives a surface,
// averaged over every direction (Godot injects mix(ambient colour, sky,
// sky contribution) times ambient_inject into each froxel, isotropic): with
// a Sky resource whose ambient comes from it, the flat colour mixed
// towards the irradiance's c0 band (its mean over the sphere) times the
// ambient energy and the background energy by the sky contribution; under
// the built-in gradient, the mean of its sky and ground averages times the
// ambient energy; else the flat colour (energy applied).
//
// A view without volumetric fog (every view of a frame without it, every
// shading but lit, a probe's capture) has a pool of 0: the renderer writes
// the block's counts as zeros once and every item's word is 0, so the
// shader reads nothing of it and the view draws as before.
//
// Nothing here allocates per frame: the block and its bytes are made once.
// (The pool's warning is the plan's, adapter.as, and the editor's for its
// own camera: a warning the GPU pass raised would reach no one.)

import { MAT4_IDENTITY, Vec3, Vec4 } from "../../base/vecmath";
import { RenderFrame } from "../frame";
import { FOG_ENTRY_ENVIRONMENT, FOG_SHAPE_WORLD, FogPlan } from "../fog_volume";
import {
    FOG_UNIFORM_ENTRIES, FOG_UNIFORM_SIZE, FogUniform, LIT_UNIFORM_LIGHTS, SKY_AMBIENT_SKY, SKY_IBL, SkyUniform, U32x4,
} from "./layouts";

// The c0 band of the real spherical harmonics (Y00): the irradiance's mean
// over the sphere is its first coefficient times it (surface.wgsl
// sh_irradiance's first term).
const SH_C0: f32 = 0.282095;

// The isotropic ambient light the fog of `f` takes in (see the header);
// `sky` the view's sky block (null outside the lit shading).
export function fogAmbient(f: RenderFrame, sky: SkyUniform?): Vec3 {
    const e = f.environment;
    if (sky != null && (sky.flags.x & SKY_IBL) != 0) {
        const flat = Vec3(sky.ambient.x, sky.ambient.y, sky.ambient.z);
        if ((sky.flags.x & SKY_AMBIENT_SKY) == 0 || sky.sh.length == 0) return flat;
        const c0 = sky.sh[0];
        const s = SH_C0 * sky.ibl.x * sky.sun.w;
        const avg = Vec3(Mathf.max(c0.x * s, 0), Mathf.max(c0.y * s, 0), Mathf.max(c0.z * s, 0));
        const t = sky.ambient.w;
        return flat + (avg - flat) * t;
    }
    if (e.ambientFromSky) {
        const skyAvg = (e.skyTop + e.skyHorizon) * <f32>0.5;
        const groundAvg = (e.groundHorizon + e.groundBottom) * <f32>0.5;
        return (skyAvg + groundAvg) * (<f32>0.5 * e.ambientEnergy);
    }
    return e.ambient;
}

// Fills `u` from `plan` (prepareFogVolumes for `f`'s camera) and `f`: the
// counts (all 0 for an empty pool, which leaves the rest as it was: the
// shader reads none of it), the phase, ambient inject, sky affect and
// length, the ambient light, the up, each light pool entry's fog energy,
// and each pool entry (the Environment's own fog as a world shape of its
// density, albedo and emission). `sky` as for fogAmbient. Allocates
// nothing.
export function fillFogUniform(u: FogUniform, f: RenderFrame, plan: FogPlan, sky: SkyUniform?): void {
    const n = min<i32>(plan.count, FOG_UNIFORM_ENTRIES);
    if (n <= 0) {
        u.counts = U32x4(0, 0, 0, 0);
        return;
    }
    const fog = f.volumetricFog;
    u.counts = U32x4(<u32>n, plan.sky, <u32>plan.skyCount, 1);
    u.params = Vec4(fog.anisotropy, fog.ambientInject, fog.skyAffect, fog.length);
    const amb = fogAmbient(f, sky);
    u.ambient = Vec4(amb.x, amb.y, amb.z, 0);
    const up = f.environment.up.normalizeOr(Vec3(0, 0, 1));
    u.up = Vec4(up.x, up.y, up.z, 0);
    const lp = f.lightPlan;
    for (let k = 0; k < LIT_UNIFORM_LIGHTS; k++) {
        unchecked(u.lightFog[k] = k < lp.count ? unchecked(f.lights[lp.lightAt(k)]).fogEnergy : <f32>0);
    }
    for (let k = 0; k < n; k++) {
        const out = unchecked(u.entries[k]);
        const e = unchecked(plan.entries[k]);
        out.lights = U32x4(unchecked(plan.lights0[k]), unchecked(plan.lights1[k]), unchecked(plan.lightCounts[k]), 0);
        if (e == FOG_ENTRY_ENVIRONMENT) {
            out.toLocal = MAT4_IDENTITY;
            out.size = Vec4(0, 0, 0, 0);
            out.material = Vec4(fog.density, 0, 0, 0);
            out.albedo = Vec4(fog.albedo.x, fog.albedo.y, fog.albedo.z, <f32>FOG_SHAPE_WORLD);
            out.emission = Vec4(fog.emission.x, fog.emission.y, fog.emission.z, fog.length);
            continue;
        }
        const v = unchecked(f.fogVolumes[e]);
        const world = v.shape == FOG_SHAPE_WORLD;
        out.toLocal = world ? MAT4_IDENTITY : v.toLocal;
        const s = v.size;
        out.size = Vec4(s.x, s.y, s.z, Mathf.min(s.x, Mathf.min(s.y, s.z)));
        out.material = Vec4(v.density, v.heightFalloff, world ? <f32>0 : v.edgeFade, v.origin.dot(up));
        out.albedo = Vec4(v.albedo.x, v.albedo.y, v.albedo.z, <f32>v.shape);
        // (every entry's chord ends at the length: surface.wgsl fog_chord)
        out.emission = Vec4(v.emission.x, v.emission.y, v.emission.z, fog.length);
    }
}

// The bytes of the view's block (the renderer writes them into the view's
// slot, ViewBuffers.fog), its counts as zeros (what a view without fog
// writes once over a block that held some), and the uniform they are
// written from: made once.
export class GpuFog {
    uniform: FogUniform = new FogUniform();
    bytes: ArrayBuffer = new ArrayBuffer(<i32>FOG_UNIFORM_SIZE);
    bytesView: DataView;
    zero: ArrayBuffer = new ArrayBuffer(16);

    constructor() {
        this.bytesView = new DataView(this.bytes, 0, this.bytes.byteLength);
    }

    // Fills the block for `f`'s view (fillFogUniform) and writes it into
    // the bytes; returns how many to upload (0 for a view without fog).
    write(f: RenderFrame, sky: SkyUniform?): u32 {
        fillFogUniform(this.uniform, f, f.fogPlan, sky);
        if (this.uniform.counts.x == 0) return 0;
        return this.uniform.writeUsedAt(this.bytesView, 0);
    }
}
