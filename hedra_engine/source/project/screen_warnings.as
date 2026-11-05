// The warnings of a scene's screen-space effects (milestone 62;
// docs/engine/SCREEN_EFFECTS.md, docs/formats/RSCN.md "Screen-space
// effects" and "Camera attributes"): what render, the editor's Output
// panel, `inspect --check`, `check` and `build` report about them, appended
// by ./warnings.as sceneDiagnostics. A scene that sets none of the effects'
// properties, in a project that sets none of their settings, has none. In
// this order:
//   - `ssr-max-steps-range`: an Environment whose ssr_max_steps is outside
//     Godot's range, 1 to 512: drawn clamped (render/screen.as ssrSteps),
//     at its <property>;
//   - `refraction-scale-without-screen`: a material the scene draws that
//     sets refraction_scale (off Godot's 0.05; not a ShaderMaterial, whose
//     own code draws it) while no Environment of the scene turns
//     screen_refraction_enabled on, binds it or keys it: the scale moves
//     only what screen-space refraction draws, so it changes nothing; at
//     its <property>;
//   - `camera-attributes-auto-exposure`: camera attributes with
//     auto_exposure_enabled, kept and not drawn (Hedra's exposure is the
//     Environment's tonemap_exposure times exposure_multiplier), at its
//     <property>;
//   - `dof-transition-zero`: camera attributes whose far or near blur is
//     on with a transition of 0, a hard step from sharp to the whole blur
//     at the distance (Godot draws it so too: said because it is rarely
//     meant), at the transition's <property>;
//   - `screen-quality-setting`: a value of one of the project's screen
//     quality settings (hedra.yaml) that is not one of its choices, left at
//     Godot's default, at its line of hedra.yaml; for a scene that asks
//     for an effect (screen_settings.as asksScreenEffects), where the
//     quality is drawn.
// Each resource is said once however many nodes name it, in tree order of
// the first that does (a Camera3D's attributes, a WorldEnvironment's
// Environment, then its camera_attributes).

import { Diagnostic, Diagnostics, Severity } from "../../scene/error";
import { displayF32 } from "../../base/fmt";
import { vfs } from "../../fs/vfs";
import { SSR_STEPS_MAX, SSR_STEPS_MIN, ScreenQuality, screenQualityFromSettings } from "../../render/screen";
import { CameraAttributesPractical } from "../../scene/resource/camera_attributes";
import { Environment, PackedScene, Resource, StandardMaterial3D } from "../../scene/resource/types";
import { ShaderMaterial } from "../../scene/resource/shader";
import { Camera3D, SceneNode, WorldEnvironment } from "../../scene/tree/node";
import { SceneTree } from "../../scene/tree/tree";
import { sceneAnimationsOf } from "../../scene/anim/scene_anims";
import { drawnMaterials } from "./shader_warnings";
import { asksScreenEffects, projectSettingsPath, settingLine } from "./screen_settings";

// Where the warnings point.
export const SCREEN_DOC = "docs/engine/SCREEN_EFFECTS.md";

export const SSR_MAX_STEPS_RANGE_CODE = "ssr-max-steps-range";
export const REFRACTION_SCALE_WITHOUT_SCREEN_CODE = "refraction-scale-without-screen";
export const CAMERA_ATTRIBUTES_AUTO_EXPOSURE_CODE = "camera-attributes-auto-exposure";
export const DOF_TRANSITION_ZERO_CODE = "dof-transition-zero";
export const SCREEN_QUALITY_SETTING_CODE = "screen-quality-setting";

// Godot's StandardMaterial3D refraction_scale.
export const REFRACTION_SCALE_DEFAULT: f32 = 0.05;

// The property a binding or a timeline turns the screen refraction on by.
const SCREEN_REFRACTION_TARGET = "environment:screen_refraction_enabled";

// Where a resource, or one of its properties, is declared.
class Place {
    file: string = "";
    line: i32 = 0;
    col: i32 = 0;
}

// The <sub_resource> that declared `r` (its <property> `property` when
// given and found), in a scene the tree's loader read; else the file that
// declared it, without a line.
function placeOf(tree: SceneTree, r: Resource, property: string): Place {
    const out = new Place();
    out.file = r.file.length > 0 ? r.file : tree.loader.displayPath(tree.scenePath);
    if (r.id.length == 0) return out;
    const scenes = tree.loader.loaded();
    for (let k = 0; k < scenes.length; k++) {
        const s = scenes[k];
        const isScene = s instanceof PackedScene;
        if (!isScene) continue;
        const doc = (s as PackedScene).doc;
        if (doc == null || doc.file != r.file) continue;
        const decl = doc.findSub(r.id);
        if (decl == null) continue;
        out.line = decl.pos.line;
        out.col = decl.pos.col;
        if (property.length > 0) {
            const props = decl.properties();
            for (let i = 0; i < props.length; i++) {
                if (props[i].name != property) continue;
                out.line = props[i].pos.line;
                out.col = props[i].pos.col;
                break;
            }
        }
        break;
    }
    return out;
}

function warn(out: Diagnostics, at: Place, code: string, message: string, hint: string): void {
    out.add(new Diagnostic(Severity.Warning, code, at.file, at.line, at.col, message, hint));
}

// A warning at the declaration of `r`'s `property` (its <sub_resource>
// when the property is not written; the compiler's budgets put theirs
// there too: hedra_compiler/check/screen.as).
export function resourceWarning(tree: SceneTree, r: Resource, property: string, code: string, message: string,
    hint: string): Diagnostic {
    const at = placeOf(tree, r, property);
    return new Diagnostic(Severity.Warning, code, at.file, at.line, at.col, message, hint);
}

// A warning at the line of hedra.yaml (`path`, absolute; its text `text`)
// that sets `key` (the file, without a line, when none does).
export function settingWarning(tree: SceneTree, path: string, text: string, key: string, code: string, message: string,
    hint: string): Diagnostic {
    const line = settingLine(text, key);
    return new Diagnostic(Severity.Warning, code, tree.loader.displayPath(path), line, line > 0 ? 1 : 0, message, hint);
}

// How a resource is named in a message: its class and id.
export function named(r: Resource): string {
    if (r.id.length > 0) return r.className() + " \"" + r.id + "\"";
    if (r.name.length > 0) return r.className() + " '" + r.name + "'";
    return "a " + r.className();
}

// The warnings of `tree`'s screen-space effects (see the header), added to
// `out`, which is returned.
export function screenDiagnostics(tree: SceneTree, out: Diagnostics): Diagnostics {
    const all = tree.walk();
    // The Environments and the camera attributes, each once, in tree order.
    const envs = new Array<Environment>();
    const attrs = new Array<CameraAttributesPractical>();
    let refracts = false;
    for (let i = 0; i < all.length; i++) {
        const n: SceneNode = all[i];
        const isCamera = n instanceof Camera3D;
        const isWorld = n instanceof WorldEnvironment;
        if (isCamera) {
            const a = (n as Camera3D).attributes;
            if (a != null && !attrs.includes(a)) attrs.push(a);
        } else if (isWorld) {
            const we = n as WorldEnvironment;
            const env = we.environment;
            if (env != null && !envs.includes(env)) envs.push(env);
            if (env != null && env.screenRefractionEnabled) refracts = true;
            for (let k = 0; k < we.bindings.length; k++) if (we.bindings[k].property == SCREEN_REFRACTION_TARGET) refracts = true;
            const a = we.cameraAttributes;
            if (a != null && !attrs.includes(a)) attrs.push(a);
        }
    }
    if (!refracts) refracts = keysScreenRefraction(tree);

    for (let i = 0; i < envs.length; i++) {
        const env = envs[i];
        const steps = env.ssrMaxSteps;
        if (steps >= SSR_STEPS_MIN && steps <= SSR_STEPS_MAX) continue;
        const drawn = steps < SSR_STEPS_MIN ? SSR_STEPS_MIN : SSR_STEPS_MAX;
        warn(out, placeOf(tree, env, "ssr_max_steps"), SSR_MAX_STEPS_RANGE_CODE,
            named(env) + "'s ssr_max_steps is " + steps.toString() + ", outside Godot's range of "
                + SSR_STEPS_MIN.toString() + " to " + SSR_STEPS_MAX.toString() + ": the reflections march "
                + drawn.toString() + " steps",
            "set ssr_max_steps from " + SSR_STEPS_MIN.toString() + " to " + SSR_STEPS_MAX.toString()
                + " (Godot's default is 64); see " + SCREEN_DOC);
    }

    if (!refracts) {
        const mats = drawnMaterials(tree);
        for (let i = 0; i < mats.length; i++) {
            const m: StandardMaterial3D = mats[i];
            const isShader = m instanceof ShaderMaterial;
            if (isShader || m.refractionScale == REFRACTION_SCALE_DEFAULT) continue;
            warn(out, placeOf(tree, m, "refraction_scale"), REFRACTION_SCALE_WITHOUT_SCREEN_CODE,
                named(m) + " sets refraction_scale to " + displayF32(m.refractionScale)
                    + ", which only screen-space refraction draws, and no Environment of the scene turns "
                    + "screen_refraction_enabled on: the glass refracts the environment, as before",
                "set the Environment's screen_refraction_enabled to true (or bind or key it) for glass that bends what "
                    + "lies behind it; see " + SCREEN_DOC);
        }
    }

    for (let i = 0; i < attrs.length; i++) {
        const a = attrs[i];
        if (!a.autoExposureEnabled) continue;
        warn(out, placeOf(tree, a, "auto_exposure_enabled"), CAMERA_ATTRIBUTES_AUTO_EXPOSURE_CODE,
            named(a) + " turns auto exposure on, which is kept and not drawn: the picture is exposed by the "
                + "Environment's tonemap_exposure times exposure_multiplier",
            "set auto_exposure_enabled to false, and change exposure_multiplier (keyed on a timeline or bound to a "
                + "view model) where the light changes; see " + SCREEN_DOC);
    }
    for (let i = 0; i < attrs.length; i++) {
        const a = attrs[i];
        if (a.dofBlurFarEnabled && a.dofBlurFarTransition == 0) transitionZero(out, tree, a, "far");
        if (a.dofBlurNearEnabled && a.dofBlurNearTransition == 0) transitionZero(out, tree, a, "near");
    }

    settingsDiagnostics(tree, out);
    return out;
}

// screenDiagnostics as a list (./warnings.as sceneDiagnostics appends it).
export function screenProblems(tree: SceneTree): Array<Diagnostic> {
    return screenDiagnostics(tree, new Diagnostics()).items;
}

function transitionZero(out: Diagnostics, tree: SceneTree, a: CameraAttributesPractical, side: string): void {
    const property = "dof_blur_" + side + "_transition";
    warn(out, placeOf(tree, a, property), DOF_TRANSITION_ZERO_CODE,
        named(a) + "'s " + property + " is 0: the " + side + " blur starts whole at dof_blur_" + side
            + "_distance, a hard step from sharp to blurred",
        "give " + property + " a length in metres for a gradual blur, or -1 for Godot's physically based scaling; see "
            + SCREEN_DOC);
}

// Whether a timeline of the tree keys a WorldEnvironment's
// environment:screen_refraction_enabled.
function keysScreenRefraction(tree: SceneTree): bool {
    const scenes = sceneAnimationsOf(tree);
    for (let s = 0; s < scenes.length; s++) {
        const decls = scenes[s].decls;
        for (let d = 0; d < decls.length; d++) {
            const objects = decls[d].objects;
            for (let o = 0; o < objects.length; o++) {
                const props = objects[o].properties;
                for (let p = 0; p < props.length; p++) if (props[p].property == SCREEN_REFRACTION_TARGET) return true;
            }
        }
    }
    return false;
}

// The project's settings' warnings (screen-quality-setting), at their lines
// of its hedra.yaml.
function settingsDiagnostics(tree: SceneTree, out: Diagnostics): void {
    // (only where the quality is drawn: a scene without the effects reads
    // no hedra.yaml it did not read before, screen_settings.as says why)
    if (!asksScreenEffects(tree)) return;
    const path = projectSettingsPath(tree.scenePath);
    if (path.length == 0) return;
    const text = vfs.readToString(path);
    if (!text.ok) return;
    const said = new Array<string>();
    screenQualityFromSettings(text.value, new ScreenQuality(), said);
    const prefix = "hedra.yaml: ";
    for (let i = 0; i < said.length; i++) {
        const w = said[i].startsWith(prefix) ? said[i].substring(prefix.length) : said[i];
        const key = w.substring(0, max<i32>(w.indexOf(" is "), 0));
        out.add(settingWarning(tree, path, text.value, key, SCREEN_QUALITY_SETTING_CODE, w + ": the setting keeps Godot's default",
            "write one of the choices (or Godot's number for it); see " + SCREEN_DOC + " \"Quality\""));
    }
}
