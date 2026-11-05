// Milestone 37: Godot's FogMaterial, a FogVolume's look (../classdb.as has
// its properties; docs/formats/RSCN.md "Fog volumes", docs/engine/FOG.md
// what each does). The fields are the file's values, colours sRGB with
// straight alpha as the format writes them; what a frame draws of them,
// Godot's clamps included (height_falloff and edge_fade at least 0), is
// ../render/fog_volumes.as's. A binding, a timeline or a tween writes them
// in place (../binding/material_fields.as fogMaterialField), and every
// FogVolume naming the material changes with it, as a shared resource does
// in Godot.
//
// Godot's density_texture (a Texture3D) is not in the format: a file that
// sets it keeps it as an unknown property, and the warnings say it is not
// drawn.

import { Vec4 } from "../../base/vecmath";
import { Value } from "../value";
import { Resource } from "./types";

// The look of a FogVolume without a material: Godot's default fog shader
// (renderer_rd/environment/fog.cpp: DENSITY = 1.0, ALBEDO = vec3(1.0)), so
// no emission, no height falloff and no edge fade.
export const FOG_DEFAULT_DENSITY: f32 = 1;
export const FOG_DEFAULT_EDGE_FADE: f32 = 0;

export class FogMaterial extends Resource {
    density: f32 = 1;
    // sRGB, straight alpha (the alpha is not used, as in Godot).
    albedo: Vec4 = Vec4(1, 1, 1, 1);
    emission: Vec4 = Vec4(0, 0, 0, 1);
    heightFalloff: f32 = 0;
    edgeFade: f32 = 0.1;

    className(): string {
        return "FogMaterial";
    }
}

// Sets a FogMaterial's field from a property value of the right type (the
// caller checked it against ../classdb.as); whether `name` is one of its
// fields (the editor sets fields through it too).
export function setFogMaterialField(m: FogMaterial, name: string, v: Value): bool {
    if (name == "density") m.density = v.asF32();
    else if (name == "albedo") m.albedo = v.vec4();
    else if (name == "emission") m.emission = v.vec4();
    else if (name == "height_falloff") m.heightFalloff = v.asF32();
    else if (name == "edge_fade") m.edgeFade = v.asF32();
    else return false;
    return true;
}
