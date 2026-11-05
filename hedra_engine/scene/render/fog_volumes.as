// A scene's fog volumes and volumetric fog on its frame (milestone 37;
// hedra_engine/render/fog_volume.as says what a frame carries and how it
// is drawn): buildSceneFrame (adapter.as) calls `applyFogVolumes` once
// every item is gathered, in the lit shading only, and refreshSceneFrame
// calls `refreshFogVolumes` on each refresh in place. It
//   - fills RenderFrame.volumetricFog from the frame's Environment
//     (`volumetricFogInto`: Godot's volumetric_fog_*, colours linear, the
//     emission times its energy, the anisotropy held to -0.9 .. 0.9);
//   - fills RenderFrame.fogVolumes with one FogVolumeDesc per visible
//     FogVolume of the tree (tree order, every world: viewports.as sets
//     each one's scenario), with `fogVolumeDescInto`, and records their
//     nodes in `nodes`, for the refresh.
// It returns how many volumes the frame carries. A scene without a
// FogVolume and without volumetric fog leaves both as they were (off and
// empty) and draws as before; the volumes are carried whether the
// volumetric fog is on or not (the tools list them), drawn only while it
// is on.
//
// `fogVolumeDescInto` (also the editor's gizmo and `inspect --fog`), in the
// frame's space (Z up: SCENE_TO_MODEL * the node's global transform, as
// every item's world): `world` that transform, `toLocal` its inverse
// (Godot's params.transform: the node's own space, its scale included),
// `size` the node's (each at least 0), `origin` the global origin,
// `bounds` the shape's box (its corners, -size/2 .. size/2, through
// `world`; none for the world shape), the FogMaterial's numbers with
// Godot's clamps (height_falloff and edge_fade at least 0) and its colours
// sRGB-decoded, Godot's default fog (density 1, white, no edge fade) for a
// FogVolume without a FogMaterial; `empty` for a size of 0 on an axis
// (not the world shape), a density within FOG_DENSITY_EPSILON of 0, or a
// transform that cannot be inverted.
//
// Planning the same tree again allocates what a plan allocates; every
// refresh allocates nothing (fogVolumeDescInto refills the descs in
// place).

import { MAT4_IDENTITY, Vec3, Vec4 } from "../../base/vecmath";
import { RenderFrame } from "../../render/frame";
import { Bounds } from "../../render/camera";
import { srgbToLinear } from "../../render/image";
import {
    FOG_DENSITY_EPSILON, FOG_SHAPE_BOX, FOG_SHAPE_WORLD, FogVolumeDesc, VolumetricFogDesc,
} from "../../render/fog_volume";
import { SCENE_TO_MODEL } from "../space";
import { FogVolume, SceneNode } from "../tree/node";
import { Environment } from "../resource/types";
import { FOG_DEFAULT_DENSITY, FOG_DEFAULT_EDGE_FADE } from "../resource/fog_material";

// Plans the fog of `walked` (the tree's walk, which buildSceneFrame has
// made already) and of `env` (the frame's world's Environment, or null) on
// `f` (see the header); returns how many volumes.
export function applyFogVolumes(
    walked: Array<SceneNode>, env: Environment?, f: RenderFrame, warnings: Array<string>, nodes: Array<FogVolume>,
): i32 {
    nodes.length = 0;
    volumetricFogInto(env, f.volumetricFog);
    for (let i = 0; i < walked.length; i++) {
        const w = walked[i];
        const isFog = w instanceof FogVolume;
        if (!isFog || !w.visibleInTree()) continue;
        const n = w as FogVolume;
        const d = new FogVolumeDesc();
        fogVolumeDescInto(n, d);
        d.label = n.path();
        d.order = nodes.length;
        f.fogVolumes.push(d);
        nodes.push(n);
    }
    return nodes.length;
}

// Refreshes `f`'s fog in place for a refresh of the frame (adapter.as
// refreshSceneFrame): false when the visible FogVolumes of `walked` are
// not `nodes`, in order (the frame must be planned again); else the
// volumetric fog read again from `env` and every desc refilled from its
// node, and true. Allocates nothing.
export function refreshFogVolumes(
    f: RenderFrame, env: Environment?, nodes: Array<FogVolume>, walked: Array<SceneNode>, warnings: Array<string>,
): bool {
    let k = 0;
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isFog = n instanceof FogVolume;
        if (!isFog || !n.visibleInTree()) continue;
        if (k >= nodes.length || nodes[k] !== (n as FogVolume)) return false;
        k++;
    }
    if (k != nodes.length || f.fogVolumes.length != nodes.length) return false;
    volumetricFogInto(env, f.volumetricFog);
    for (let i = 0; i < nodes.length; i++) fogVolumeDescInto(nodes[i], f.fogVolumes[i]);
    return true;
}

// The Environment's volumetric fog as a frame draws it (see the header),
// into `out`, in place; off without an environment. Allocates nothing.
export function volumetricFogInto(env: Environment?, out: VolumetricFogDesc): void {
    if (env == null) {
        out.enabled = false;
        return;
    }
    out.enabled = env.volumetricFogEnabled;
    out.density = env.volumetricFogDensity;
    out.albedo = linear3(env.volumetricFogAlbedo);
    const e = env.volumetricFogEmissionEnergy;
    const em = linear3(env.volumetricFogEmission);
    out.emission = Vec3(em.x * e, em.y * e, em.z * e);
    const g = env.volumetricFogAnisotropy;
    out.anisotropy = g < <f32>-0.9 ? <f32>-0.9 : g > <f32>0.9 ? <f32>0.9 : g;
    out.length = env.volumetricFogLength > 0 ? env.volumetricFogLength : 0;
    out.ambientInject = env.volumetricFogAmbientInject > 0 ? env.volumetricFogAmbientInject : 0;
    const s = env.volumetricFogSkyAffect;
    out.skyAffect = s < 0 ? <f32>0 : s > 1 ? <f32>1 : s;
}

// `n`'s desc as a frame draws it (see the header), into `out`, in place,
// but its label and order (the plan's). Allocates nothing.
export function fogVolumeDescInto(n: FogVolume, out: FogVolumeDesc): void {
    const g = SCENE_TO_MODEL * n.global();
    out.world = g;
    out.shape = n.shape >= 0 && n.shape <= FOG_SHAPE_WORLD ? n.shape : FOG_SHAPE_BOX;
    const s = n.size;
    out.size = s;
    out.origin = g.wAxis.truncate();
    const inv = g.inverse();
    const finite = inv.xAxis.isFinite() && inv.yAxis.isFinite() && inv.zAxis.isFinite() && inv.wAxis.isFinite();
    out.toLocal = finite ? inv : MAT4_IDENTITY;
    const world = out.shape == FOG_SHAPE_WORLD;
    out.hasBounds = !world;
    if (!world) {
        const ax = g.xAxis.truncate();
        const ay = g.yAxis.truncate();
        const az = g.zAxis.truncate();
        const hx = s.x * <f32>0.5;
        const hy = s.y * <f32>0.5;
        const hz = s.z * <f32>0.5;
        const ex = Vec3(Mathf.abs(ax.x) * hx + Mathf.abs(ay.x) * hy + Mathf.abs(az.x) * hz,
            Mathf.abs(ax.y) * hx + Mathf.abs(ay.y) * hy + Mathf.abs(az.y) * hz,
            Mathf.abs(ax.z) * hx + Mathf.abs(ay.z) * hy + Mathf.abs(az.z) * hz);
        out.bounds = Bounds(out.origin - ex, out.origin + ex);
    } else {
        out.bounds = Bounds(Vec3(0, 0, 0), Vec3(0, 0, 0));
    }
    const m = n.fogMaterial();
    if (m != null) {
        out.density = m.density;
        out.albedo = linear3(m.albedo);
        out.emission = linear3(m.emission);
        out.heightFalloff = m.heightFalloff > 0 ? m.heightFalloff : 0;
        out.edgeFade = m.edgeFade > 0 ? m.edgeFade : 0;
    } else {
        out.density = FOG_DEFAULT_DENSITY;
        out.albedo = Vec3(1, 1, 1);
        out.emission = Vec3(0, 0, 0);
        out.heightFalloff = 0;
        out.edgeFade = FOG_DEFAULT_EDGE_FADE;
    }
    const flat = !world && !(s.x > 0 && s.y > 0 && s.z > 0);
    out.empty = flat || !finite || Mathf.abs(out.density) < FOG_DENSITY_EPSILON;
}

function linear3(c: Vec4): Vec3 {
    return Vec3(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z));
}
