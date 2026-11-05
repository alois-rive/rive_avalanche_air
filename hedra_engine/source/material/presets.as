// The material presets a new material starts from (the CLI's `new
// --preset`): five StandardMaterial3D settings and their canonical
// MaterialX text. Plain data and the MaterialX writer, with no command,
// host or renderer, so that every tool (and, later, the engine's source
// tier) makes a new material the same way.

import { Vec4 } from "../../base/vecmath";
import { writeMaterialFile } from "../scene/resource/material_file";
import { materialDocOfPbr } from "../scene/resource/mtlx_doc";
import { pbrFromStandard } from "../../scene/resource/pbr_map";
import { StandardMaterial3D } from "../../scene/resource/types";

// The presets `new --preset` writes, the default first.
export const MATERIAL_PRESETS: StaticArray<string> = ["default", "metal", "plastic", "glass", "emissive"];

export function materialPresetOf(name: string): i32 {
    for (let i = 0; i < MATERIAL_PRESETS.length; i++) if (MATERIAL_PRESETS[i] == name) return i;
    return -1;
}

// The material preset `preset` (MATERIAL_PRESETS) makes, named `name`:
// - default: Godot's StandardMaterial3D as it comes (white, metallic 0,
//   roughness 1), which MaterialX writes as gltf_pbr's own defaults but
//   for the roughness;
// - metal: a light grey (0.8) metal, metallic 1, roughness 0.3;
// - plastic: a light grey (0.8) dielectric, roughness 0.4;
// - glass: white, roughness 0, transmission 1 (refraction on), ior 1.5;
// - emissive: white, emission on, white, energy 2.
export function presetMaterial(name: string, preset: i32): StandardMaterial3D {
    const m = new StandardMaterial3D();
    m.name = name;
    if (preset == 1) {
        m.albedoColor = Vec4(0.8, 0.8, 0.8, 1);
        m.metallic = 1;
        m.roughness = 0.3;
    } else if (preset == 2) {
        m.albedoColor = Vec4(0.8, 0.8, 0.8, 1);
        m.roughness = 0.4;
    } else if (preset == 3) {
        m.roughness = 0;
        m.refractionEnabled = true;
        m.transmission = 1;
        m.ior = 1.5;
    } else if (preset == 4) {
        m.emissionEnabled = true;
        m.emission = Vec4(1, 1, 1, 1);
        m.emissionEnergy = 2;
    }
    return m;
}

// The canonical MaterialX text of a new material: preset `preset` named
// `name`, as the file `file` (how a reader's errors would name it).
export function newMaterialText(name: string, preset: i32, file: string): string {
    return writeMaterialFile(materialDocOfPbr(pbrFromStandard(presetMaterial(name, preset)), file));
}
