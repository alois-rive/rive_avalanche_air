// Cameras and punctual lights, in both directions.
//
// Export and import share this module on purpose: every formula here is a
// unit conversion with an exact inverse, and keeping the pair side by side
// is what makes a round trip through Hedra land back on the numbers it
// started with.
//
// Neither glTF concept survives the trip completely:
//   * A glTF perspective camera stores a *vertical* field of view, while a
//     Hedra camera stores a focal length measured against the larger image
//     side (Blender's "auto" sensor fit). `cameraFromGltf` reads
//     `aspectRatio` when the file gives one and `cameraToGltf` writes none.
//   * A spot light's cone angles have nowhere to live: import keeps the kind
//     and reports the loss; export writes the glTF default cone.
//
// `tan`/`atan` are `appleTanf`/`appleAtanf` (engine/src/base/libm.as), which
// give Apple libm's results bit for bit, so the numbers are the same on every
// platform.
//
// The glTF side uses the document types of engine/src/source/io/gltf/doc.as. Import reads
// the JSON structs directly and panics when a camera's type or projection, or
// a light's spot parameters, are missing or invalid.

import { Vec3 } from "../../../base/vecmath";
import { appleAtanf, appleTanf } from "../../../base/libm";
import { maxF32, clampF32, panic } from "../../../base/util";
import {
    Camera, CameraKind, Light, LightKind,
} from "../../model/scene";
import {
    Camera as GltfCamera, CameraPerspective, CameraOrthographic, CameraType, KhrLight, KhrLightSpot, KhrLightType,
    CHECKED_INVALID,
} from "../gltf/doc";

// The sensor size a Hedra focal length is measured against, across the
// larger image side. Blender's default 36mm sensor.
export const SENSOR_MM: f32 = 36.0;

// The glTF default `outerConeAngle` (pi / 4 as an f32), written
// for a spot light because Hedra does not model cone angles.
export const DEFAULT_OUTER_CONE: f32 = <f32>(Math.PI / 4);

// Luminous efficacy used to turn radiometric watts into photometric lumens,
// the 683 lm/W of the 555nm peak.
export const LUMENS_PER_WATT: f32 = 683.0;

// pi as an f32.
const F32_PI: f32 = <f32>Math.PI;

// How a Hedra light's energy in watts becomes a glTF intensity (candela
// for point and spot lights, lux for directional ones). Blender's three
// modes, under Blender's names.
export enum LightingMode {
    // Watts through 683 lm/W, and for a point or spot light spread over the
    // 4*pi steradians of a sphere. Blender's default.
    Spec = 0,
    // The same geometry, but no watts-to-lumens step (Blender's "Unitless").
    Compat = 1,
    // No conversion at all.
    Raw = 2,
}

// LightingMode::parse: the mode, or -1 for None.
export function lightingModeParse(s: string): i32 {
    if (s == "spec" || s == "standard") return LightingMode.Spec;
    if (s == "compat" || s == "unitless") return LightingMode.Compat;
    if (s == "raw") return LightingMode.Raw;
    return -1;
}

// LightingMode::name.
export function lightingModeName(m: LightingMode): string {
    switch (m) {
        case LightingMode.Spec: return "spec";
        case LightingMode.Compat: return "compat";
        default: return "raw";
    }
}

// Derived Debug of LightingMode.
export function lightingModeDebug(m: LightingMode): string {
    switch (m) {
        case LightingMode.Spec: return "Spec";
        case LightingMode.Compat: return "Compat";
        default: return "Raw";
    }
}

// LightingMode::to_intensity: watts to glTF intensity. A sun's energy is
// already per-square-metre, so it is not spread over a sphere.
export function lightingModeToIntensity(mode: LightingMode, energy: f32, kind: LightKind): f32 {
    const sphere: f32 = kind == LightKind.Sun ? <f32>1.0 : <f32>4.0 * F32_PI;
    switch (mode) {
        case LightingMode.Spec: return energy * LUMENS_PER_WATT / sphere;
        case LightingMode.Compat: return energy / sphere;
        default: return energy;
    }
}

// LightingMode::to_energy: glTF intensity back to watts, the exact inverse.
export function lightingModeToEnergy(mode: LightingMode, intensity: f32, kind: LightKind): f32 {
    const sphere: f32 = kind == LightKind.Sun ? <f32>1.0 : <f32>4.0 * F32_PI;
    switch (mode) {
        case LightingMode.Spec: return intensity * sphere / LUMENS_PER_WATT;
        case LightingMode.Compat: return intensity * sphere;
        default: return intensity;
    }
}

// ---------------------------------------------------------------- cameras

// The glTF camera for a Hedra camera. `scale` is the export's uniform
// scale: the clip planes are distances in world units.
export function cameraToGltf(cam: Camera, name: string, scale: f32): GltfCamera {
    const znear = maxF32(cam.clipStart * scale, <f32>1e-6);
    const zfar = maxF32(cam.clipEnd * scale, znear + <f32>1e-6);
    const out = new GltfCamera();
    out.name = name;
    if (cam.kind == CameraKind.Perspective) {
        out.type_ = CameraType.Perspective;
        const p = new CameraPerspective();
        // No aspect ratio: Hedra's focal length is a statement about the
        // lens, not about a particular frame.
        p.aspectRatio = NaN;
        p.yfov = majorFov(cam.focalLengthMm);
        p.znear = znear;
        p.zfar = zfar;
        out.perspective = p;
        out.orthographic = null;
    } else {
        // glTF's xmag / ymag are half-extents: the view spans 2*xmag.
        const half = maxF32(cam.orthoScale * scale * <f32>0.5, <f32>1e-6);
        out.type_ = CameraType.Orthographic;
        const o = new CameraOrthographic();
        o.xmag = half;
        o.ymag = half;
        o.znear = znear;
        o.zfar = zfar;
        out.orthographic = o;
        out.perspective = null;
    }
    return out;
}

const UNWRAP_NONE = "called `Option::unwrap()` on a `None` value";
const UNWRAP_INVALID = "attempted to unwrap an invalid item"; // a value the file spells wrong

// The Hedra camera for a glTF one. `scale` is the import's uniform scale,
// applied to the clip planes and to an orthographic extent.
export function cameraFromGltf(cam: GltfCamera, scale: f32): Camera {
    const d = new Camera();
    const out = new Camera();
    if (cam.type_ == CHECKED_INVALID) panic(UNWRAP_INVALID);
    if (cam.type_ == CameraType.Perspective) {
        const pp = cam.perspective;
        if (pp == null) {
            panic(UNWRAP_NONE);
            return out;
        }
        const p = pp as CameraPerspective;
        // `yfov` is vertical; a landscape `aspectRatio` makes the horizontal
        // one the number to keep.
        const a = p.aspectRatio; // NaN = None (and NaN fails both tests below)
        let fov: f32;
        if (!isNaN(a) && a > <f32>1.0 && isFinite(a)) {
            fov = <f32>2.0 * appleAtanf(appleTanf(p.yfov * <f32>0.5) * a);
        } else {
            fov = p.yfov;
        }
        out.kind = CameraKind.Perspective;
        out.focalLengthMm = focalFromFov(fov);
        out.orthoScale = d.orthoScale;
        out.clipStart = p.znear * scale;
        out.clipEnd = (isNaN(p.zfar) ? d.clipEnd : p.zfar) * scale;
    } else {
        const oo = cam.orthographic;
        if (oo == null) {
            panic(UNWRAP_NONE);
            return out;
        }
        const o = oo as CameraOrthographic;
        out.kind = CameraKind.Orthographic;
        out.focalLengthMm = d.focalLengthMm;
        // The larger side is the one `ortho_scale` spans.
        out.orthoScale = <f32>2.0 * maxF32(Mathf.abs(o.xmag), Mathf.abs(o.ymag)) * scale;
        out.clipStart = o.znear * scale;
        out.clipEnd = o.zfar * scale;
    }
    return out;
}

// Field of view across the larger image side, for a focal length on a
// SENSOR_MM sensor.
export function majorFov(focalLengthMm: f32): f32 {
    return <f32>2.0 * appleAtanf(SENSOR_MM / (<f32>2.0 * maxF32(focalLengthMm, <f32>1e-3)));
}

// The inverse of `majorFov`. A fov at or past 180 degrees has no focal
// length, so it is clamped to something a renderer can still project.
export function focalFromFov(fov: f32): f32 {
    const half = clampF32(fov * <f32>0.5, <f32>1e-4, <f32>1.5533); // 89 degrees
    return maxF32(SENSOR_MM / (<f32>2.0 * appleTanf(half)), <f32>1e-3);
}

// ----------------------------------------------------------------- lights

// `light_to_gltf`'s `(light, approximated)`.
export class LightToGltf {
    light: KhrLight;
    // The Hedra light had no glTF counterpart (an area light, written as a
    // point light); the caller warns.
    approximated: bool;

    constructor(light: KhrLight, approximated: bool) {
        this.light = light;
        this.approximated = approximated;
    }
}

// The glTF light for a Hedra light. An area light has no glTF counterpart
// and becomes a point light; the caller is told so it can warn.
export function lightToGltf(light: Light, name: string, mode: LightingMode): LightToGltf {
    const approximated = light.kind == LightKind.Area;
    let type_: KhrLightType;
    switch (light.kind) {
        case LightKind.Sun: type_ = KhrLightType.Directional; break;
        case LightKind.Spot: type_ = KhrLightType.Spot; break;
        // Area is the approximation; point is exact.
        default: type_ = KhrLightType.Point; break;
    }
    const out = new KhrLight();
    if (type_ == KhrLightType.Spot) {
        const spot = new KhrLightSpot();
        spot.innerConeAngle = 0.0;
        spot.outerConeAngle = DEFAULT_OUTER_CONE;
        out.spot = spot;
    } else {
        out.spot = null;
    }
    const c = light.color;
    out.color = [c.x, c.y, c.z];
    out.intensity = lightingModeToIntensity(mode, light.energy, light.kind);
    out.name = name;
    out.range = NaN;
    out.type_ = type_;
    return new LightToGltf(out, approximated);
}

// The Hedra light for a glTF one.
export function lightFromGltf(light: KhrLight, mode: LightingMode): Light {
    let kind: LightKind;
    switch (light.type_) {
        case KhrLightType.Directional: kind = LightKind.Sun; break;
        case KhrLightType.Point: kind = LightKind.Point; break;
        case KhrLightType.Spot:
            // A spot light must carry its spot parameters.
            if (light.spot == null) panic(UNWRAP_NONE);
            kind = LightKind.Spot;
            break;
        default:
            panic(UNWRAP_INVALID);
            kind = LightKind.Point;
            break;
    }
    const out = new Light();
    out.kind = kind;
    out.color = Vec3(light.color[0], light.color[1], light.color[2]);
    out.energy = lightingModeToEnergy(mode, light.intensity, kind);
    return out;
}
