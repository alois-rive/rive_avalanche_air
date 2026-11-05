// A scene's decals on its frame (milestone 33; hedra_engine/render/decal.as
// says what a frame carries): buildSceneFrame (adapter.as) calls
// `applyDecals` once every item is gathered, in the lit shading only, and
// refreshSceneFrame calls `refreshDecals` on each refresh in place. It
//   - fills RenderFrame.decals with one DecalDesc per visible Decal
//     (tree order), with `decalDescInto`, and records
//     their nodes and textures (DECAL_TEXTURES a node) in `nodes` and
//     `textures`, for the refresh;
//   - gives every item DrawItem.layers (its GeometryInstance3D's `layers`,
//     1 for a node that has none), in a frame that has decals (the
//     renderer's choice of each item's decals reads it: decal_select.as);
//   - registers each texture with the frame's texture files as a material's
//     is (materials.as texturePath: a PNG's image, a bundle's processed
//     forms, an ArtboardTexture's placeholder under its path), an .hdr left
//     out with a warning.
// It returns how many decals the frame carries. A scene without a visible
// Decal leaves RenderFrame.decals empty and draws as before. A decal
// without any texture is carried all the same (the renderer leaves it out
// of its pool: it paints nothing), so that the refresh follows the tree's
// visible decals one for one.
//
// `decalDescInto` (also the editor's gizmo and `inspect --decals`), in the
// frame's space (Z up: SCENE_TO_MODEL * the node's global transform, as
// every item's world): the node's axes normalised (axisX, axisY, axisZ),
// the box's size along them, the node's scale applied (DecalDesc.size: x,
// y and z of `size` times the axes' lengths, as Godot's transform scales
// its decal), toLocal the inverse of global * scale(size / 2) * Godot's uv
// transform (x and z scaled by 2 and moved by -1), so that decal space's x
// and z run from 0 to 1 across the box and y from -1 at its bottom to 1 at
// its top; `bounds` the box's eight corners' bounds, `origin` the global
// origin; modulate sRGB-decoded (alpha straight), every number as the node
// has it, the cull mask as a u32.
//
// Planning the same tree again allocates what a plan allocates; every
// refresh allocates nothing (decalValuesInto refills the descs in place and
// registers nothing; decalItemLayers sets the items' layers again).
//
// Milestone 67b (docs/engine/RESOURCES.md, "CPU copies"): a decal's
// texture is pinned (scene/resource/cpu_copy.as) when a plan registers it,
// its image and its processed forms, so that a run time that releases CPU
// copies after upload keeps them: the atlas is drawn from the binder's
// uploads by a blit, but a host that refuses the blit composes its layers
// on the CPU from these pixels (render/gpu/decals.as). One released before
// its decal first showed (the same texture a material's, uploaded and
// released earlier) counts a miss.

import { MAT4_IDENTITY, Mat4, Vec3, Vec4 } from "../../base/vecmath";
import { RenderFrame } from "../../render/frame";
import { Bounds } from "../../render/camera";
import { srgbToLinear } from "../../render/image";
import { DECAL_TEXTURES, DecalDesc } from "../../render/decal";
import { SCENE_TO_MODEL } from "../space";
import { Decal, GeometryInstance3D, SceneNode } from "../tree/node";
import { Texture2D } from "../resource/types";
import { SceneRenderCache, SceneTextureFiles } from "./cache";
import { noteCpuMiss, pinForm, pinImage } from "../resource/cpu_copy";

// The properties of a decal's texture slots, by DECAL_TEXTURE_* (warnings
// name them).
export const DECAL_TEXTURE_PROPS: StaticArray<string> = [
    "texture_albedo", "texture_normal", "texture_orm", "texture_emission",
];

// Plans the decals of `walked` (the tree's walk, which buildSceneFrame has
// made already: a plan of a scene without decals makes no array of its
// own) on `f` (see the header); returns how many.
export function applyDecals(
    walked: Array<SceneNode>, f: RenderFrame, itemNodes: Array<SceneNode>, cache: SceneRenderCache,
    warnings: Array<string>, nodes: Array<Decal>, textures: Array<Texture2D?>,
): i32 {
    nodes.length = 0;
    textures.length = 0;
    for (let i = 0; i < walked.length; i++) {
        const w = walked[i];
        const isDecal = w instanceof Decal;
        if (!isDecal || !w.visibleInTree()) continue;
        const n = w as Decal;
        const d = new DecalDesc();
        decalDescInto(n, d, cache, warnings);
        f.decals.push(d);
        nodes.push(n);
        for (let k = 0; k < DECAL_TEXTURES; k++) textures.push(n.textureAt(k));
    }
    if (nodes.length == 0) return 0;
    decalItemLayers(f, itemNodes);
    return nodes.length;
}

// Every item's DrawItem.layers from its node (`itemNodes`, by item): its
// GeometryInstance3D's `layers`, 1 for a node that has none. A plan sets
// them (applyDecals), and so does every refresh of a frame with decals
// (adapter.as refreshSceneFrame), since a script may move a mesh to other
// layers. Allocates nothing.
export function decalItemLayers(f: RenderFrame, itemNodes: Array<SceneNode>): void {
    const items = f.items;
    const n = min<i32>(items.length, itemNodes.length);
    for (let i = 0; i < n; i++) {
        const node = unchecked(itemNodes[i]);
        const isGeometry = node instanceof GeometryInstance3D;
        unchecked(items[i]).layers = isGeometry ? <u32>(node as GeometryInstance3D).layers : 1;
    }
}

// `n`'s desc as a frame draws it (see the header), into `out`, its
// textures' paths registered with `cache`'s texture files and what cannot
// be drawn said in `warnings`.
export function decalDescInto(n: Decal, out: DecalDesc, cache: SceneRenderCache, warnings: Array<string>): void {
    decalValuesInto(n, out);
    out.label = n.path();
    for (let k = 0; k < DECAL_TEXTURES; k++) {
        out.textures[k] = decalTexturePath(n.textureAt(k), DECAL_TEXTURE_PROPS[k], out.label, cache.textures, warnings);
    }
}

// Everything of `n`'s desc but its textures and label, in place: what a
// refresh writes each frame. Allocates nothing.
export function decalValuesInto(n: Decal, out: DecalDesc): void {
    const g = SCENE_TO_MODEL * n.global();
    const ax = g.xAxis.truncate();
    const ay = g.yAxis.truncate();
    const az = g.zAxis.truncate();
    const lx = ax.length();
    const ly = ay.length();
    const lz = az.length();
    out.axisX = lx > 0 ? ax * (<f32>1 / lx) : Vec3(1, 0, 0);
    out.axisY = ly > 0 ? ay * (<f32>1 / ly) : Vec3(0, 1, 0);
    out.axisZ = lz > 0 ? az * (<f32>1 / lz) : Vec3(0, 0, 1);
    const s = n.size;
    out.size = Vec3(s.x * lx, s.y * ly, s.z * lz);
    out.origin = g.wAxis.truncate();
    const hx = s.x * <f32>0.5;
    const hy = s.y * <f32>0.5;
    const hz = s.z * <f32>0.5;
    // Godot's decal space to the node's: x and z from 0..1 to -h..h, y from
    // -1..1 to -h..h (scale(size / 2) * uv_xform).
    const box = Mat4(Vec4(2 * hx, 0, 0, 0), Vec4(0, hy, 0, 0), Vec4(0, 0, 2 * hz, 0), Vec4(-hx, 0, -hz, 1));
    const inv = (g * box).inverse();
    // A collapsed box (an axis scaled to 0, or a singular transform): its
    // inverse is not finite. The desc is marked empty and keeps the
    // identity, so nothing downstream reads a NaN; inverseOrZero would not
    // do, since a zero matrix puts every point inside the box.
    const empty = !(lx > 0 && ly > 0 && lz > 0)
        || !(inv.xAxis.isFinite() && inv.yAxis.isFinite() && inv.zAxis.isFinite() && inv.wAxis.isFinite());
    out.empty = empty;
    out.toLocal = empty ? MAT4_IDENTITY : inv;
    // The box's eight corners' bounds: its centre (the origin) give or
    // take, on each frame axis, the sum of the half extents' reach along it
    // (|g| times the half size: the corners' exact bounds, in a ninth of
    // their transforms).
    const ex = Vec3(Mathf.abs(ax.x) * hx + Mathf.abs(ay.x) * hy + Mathf.abs(az.x) * hz,
        Mathf.abs(ax.y) * hx + Mathf.abs(ay.y) * hy + Mathf.abs(az.y) * hz,
        Mathf.abs(ax.z) * hx + Mathf.abs(ay.z) * hy + Mathf.abs(az.z) * hz);
    out.bounds = Bounds(out.origin - ex, out.origin + ex);
    const m = n.modulate;
    out.modulate = Vec4(srgbToLinear(m.x), srgbToLinear(m.y), srgbToLinear(m.z), m.w);
    out.emissionEnergy = n.emissionEnergy;
    out.albedoMix = n.albedoMix;
    out.normalFade = n.normalFade;
    out.upperFade = n.upperFade;
    out.lowerFade = n.lowerFade;
    out.distanceFade = n.distanceFadeEnabled;
    out.fadeBegin = n.distanceFadeBegin;
    out.fadeLength = n.distanceFadeLength;
    out.cullMask = <u32>n.cullMask;
}

// The path the binder reads a decal's texture by (materials.as
// texturePath's rule), with its image or processed forms registered in
// `textures`; null for none, or for a Radiance HDR image (left out with a
// warning: decal textures are PNG only, as a material's).
function decalTexturePath(t: Texture2D?, slot: string, label: string, textures: SceneTextureFiles,
    warnings: Array<string>): string? {
    if (t == null || t.path.length == 0) return null;
    const forms = t.compressed;
    if (forms != null && forms.length > 0) {
        for (let i = 0; i < forms.length; i++) {
            const f = forms[i];
            if (!f.pinned && f.released) noteCpuMiss("decal: a released texture form");
            pinForm(f);
        }
        textures.addCompressed(t.path, forms);
    }
    const img = t.image;
    if (img != null) {
        if (!img.pinned && img.released) noteCpuMiss("decal: a released texture");
        pinImage(img);
    }
    if (img == null && t.hdr != null) {
        const shown = t.file.length > 0 ? t.file : t.path;
        warnings.push("decal '" + label + "': " + slot + " " + shown
            + " is a Radiance HDR image; decal textures are PNG only, so it is not drawn");
        return null;
    }
    if (img != null) textures.add(t.path, img);
    return t.path;
}

// Refreshes `f`'s decals in place for a refresh of the frame (adapter.as
// refreshSceneFrame): false when the visible Decals of `walked` (the tree's
// walk) are not `nodes`, in order, or one's textures are not the ones in
// `textures` (the frame must be planned again); else every desc refilled
// from its node (decalValuesInto) and true. Allocates nothing.
export function refreshDecals(
    f: RenderFrame, nodes: Array<Decal>, textures: Array<Texture2D?>, walked: Array<SceneNode>, cache: SceneRenderCache,
    warnings: Array<string>,
): bool {
    let k = 0;
    for (let i = 0; i < walked.length; i++) {
        const n = walked[i];
        const isDecal = n instanceof Decal;
        if (!isDecal || !n.visibleInTree()) continue;
        if (k >= nodes.length || nodes[k] !== (n as Decal)) return false;
        k++;
    }
    if (k != nodes.length || f.decals.length != nodes.length) return false;
    for (let i = 0; i < nodes.length; i++) {
        const n = nodes[i];
        for (let s = 0; s < DECAL_TEXTURES; s++) if (n.textureAt(s) !== textures[i * DECAL_TEXTURES + s]) return false;
        decalValuesInto(n, f.decals[i]);
    }
    return true;
}
