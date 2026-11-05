// The warnings of a scene's fog volumes and volumetric fog (milestone 37;
// docs/formats/RSCN.md "Fog volumes", docs/engine/FOG.md): what render, the
// editor's Output panel, `inspect --check` and `build` report about them,
// each at the declaration of the node it is about (./warnings.as
// nodeWarning), appended by ./warnings.as sceneDiagnostics. A scene without
// a FogVolume has none. In tree order, a FogVolume's in this order:
//   - `fog-volume-no-volumetric-fog`: a visible FogVolume whose world's
//     Environment (its SubViewport's own world's, or the main one's: the
//     first WorldEnvironment of that world) has volumetric fog off:
//     Godot's configuration warning, its own sentence (Godot's FogVolume
//     draws only while volumetric_fog_enabled is on, and so does Hedra's).
//     A world without an Environment says nothing, as in Godot: a scene
//     made to be instanced (a demo room) takes its fog from the scene it
//     goes into, and would otherwise warn whenever it is opened alone;
//   - `fog-volume-material`: a material that is neither null nor a
//     FogMaterial (a StandardMaterial3D, say): drawn as Godot's default fog
//     (density 1, white), as Godot draws a fog volume whose material is not
//     a fog shader;
//   - `fog-volume-empty`: a FogVolume that draws nothing: a size of 0 on an
//     axis (not the world shape, which ignores its size), or a density
//     within FOG_DENSITY_EPSILON of 0 (Godot's "act like 0").
// The last two for hidden FogVolumes too (a hidden one is shown by a key or
// a binding, as the sample's Pillar is). A FogMaterial's density_texture
// (a Texture3D: not in the format) is the loader's property-unknown, which
// says it is not drawn.

import { Diagnostic } from "../../scene/error";
import { displayF32 } from "../../base/fmt";
import { FOG_DENSITY_EPSILON, FOG_SHAPE_WORLD } from "../../render/fog_volume";
import { FOG_DEFAULT_DENSITY } from "../../scene/resource/fog_material";
import { Environment } from "../../scene/resource/types";
import { FogVolume, SceneNode, SubViewport, WorldEnvironment } from "../../scene/tree/node";
import { SceneTree } from "../../scene/tree/tree";
import { worldViewportOf } from "../../scene/tree/viewports";
import { nodeWarning } from "./warnings";

// Where the fog's warnings point.
export const FOG_DOC = "docs/formats/RSCN.md \"Fog volumes\"";

// Godot's FogVolume configuration warning (fog_volume.cpp), word for word.
export const FOG_NO_VOLUMETRIC_FOG_MESSAGE =
    "Fog Volumes need volumetric fog to be enabled in the scene's Environment in order to be visible.";

// The warnings of `tree`'s fog (see the header), in tree order.
export function fogDiagnostics(tree: SceneTree): Array<Diagnostic> {
    const out = new Array<Diagnostic>();
    const all = tree.walk();
    for (let i = 0; i < all.length; i++) {
        const w = all[i];
        const isFog = w instanceof FogVolume;
        if (!isFog) continue;
        const n = w as FogVolume;
        if (n.visibleInTree()) {
            const env = environmentOf(all, worldViewportOf(n));
            if (env != null && !env.volumetricFogEnabled) {
                out.push(nodeWarning(tree, n, "fog-volume-no-volumetric-fog", FOG_NO_VOLUMETRIC_FOG_MESSAGE,
                    "set the environment's volumetric_fog_enabled to true, and volumetric_fog_density to 0 for "
                    + "the volumes' fog alone; see " + FOG_DOC));
            }
        }
        const m = n.material;
        const fm = n.fogMaterial();
        if (m != null && fm == null) {
            out.push(nodeWarning(tree, n, "fog-volume-material", "FogVolume " + n.path() + "'s material is a "
                + m.className() + ": only a FogMaterial is drawn, so it is drawn as Godot's default fog",
                "set its material to a FogMaterial sub_resource; see " + FOG_DOC));
        }
        const why = emptyReason(n, fm != null ? fm.density : FOG_DEFAULT_DENSITY);
        if (why.length > 0) {
            out.push(nodeWarning(tree, n, "fog-volume-empty", "FogVolume " + n.path() + " draws nothing: " + why,
                "give it a size above 0 on every axis and a density beyond -0.001 .. 0.001; see " + FOG_DOC));
        }
    }
    return out;
}

// The Environment of the first WorldEnvironment of `world`'s world (null:
// the main one) among `all`, or null.
function environmentOf(all: Array<SceneNode>, world: SubViewport?): Environment? {
    for (let i = 0; i < all.length; i++) {
        const n = all[i];
        const isEnv = n instanceof WorldEnvironment;
        if (isEnv && worldViewportOf(n) === world) return (n as WorldEnvironment).environment;
    }
    return null;
}

// Why FogVolume `n` (of density `density`) draws nothing, or "".
function emptyReason(n: FogVolume, density: f32): string {
    if (n.shape != FOG_SHAPE_WORLD) {
        const s = n.size;
        const axes = new Array<string>();
        if (!(s.x > 0)) axes.push("x");
        if (!(s.y > 0)) axes.push("y");
        if (!(s.z > 0)) axes.push("z");
        if (axes.length > 0) return "its size is 0 along " + axes.join(" and ");
    }
    if (Mathf.abs(density) < FOG_DENSITY_EPSILON) return "its density is " + displayF32(density);
    return "";
}
