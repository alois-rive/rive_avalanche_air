// The screen-space effects' quality a project sets (milestone 62;
// docs/engine/SCREEN_EFFECTS.md "Quality"): Godot's project settings,
// written in the project's hedra.yaml as Godot writes them in
// project.godot, one a line:
//
//   rendering/environment/screen_space_reflection/roughness_quality: low
//   rendering/environment/screen_space_reflection/half_size: true
//   rendering/environment/screen_space_reflection/quarter_size: true
//   rendering/camera/depth_of_field/depth_of_field_bokeh_shape: hexagon
//   rendering/camera/depth_of_field/depth_of_field_bokeh_quality: very_low
//   rendering/camera/depth_of_field/depth_of_field_use_jitter: false
//
// read by ../../render/screen.as screenQualityFromSettings (a choice by its
// name or Godot's number; a bad value a warning, the key left at Godot's
// default; half_size and quarter_size are Hedra's). The tools read the
// scene's project's file here (render, inspect, check, the editor's View ›
// Screen Quality: Project); `hedra build` writes the keys' lines into the
// generated hedra_project.as (screenSettingLines: the sixth argument of
// registerProject), which the run time parses once
// (../../scene/runtime/projects.as RegisteredProject.screenQuality), so
// that a built project draws with the quality the tools drew with. A
// project that sets none draws with Godot's defaults.
//
// The tools read the file only for a scene that asks for an effect
// (asksScreenEffects: an Environment that turns the reflections or the
// screen refraction on, or binds or keys them, or camera attributes in a
// camera's or a WorldEnvironment's slot), and `inspect --screen`: a scene
// without them reads the files it read before, so that a command on it
// takes the rounds it took (the session host fetches what a run reads
// that its prefetcher did not ask for, at the cost of another run).

import { vfs } from "../../fs/vfs";
import { SCREEN_SETTING_KEYS, ScreenQuality, screenQualityFromSettings } from "../../render/screen";
import { isRenderSettingKey } from "../../render/quality";
import { PROJECT_FILE, findProjectRoot } from "../../scene/resource/loader";
import { Camera3D, SceneNode, WorldEnvironment } from "../../scene/tree/node";
import { SceneTree } from "../../scene/tree/tree";
import { sceneAnimationsOf } from "../../scene/anim/scene_anims";

// The targets a binding or a timeline turns an Environment's effect on by.
const SSR_TARGET = "environment:ssr_enabled";
const SCREEN_REFRACTION_TARGET = "environment:screen_refraction_enabled";

// The hedra.yaml of the project the scene at `scenePath` (absolute) is in,
// or "" when there is none (findProjectRoot's: the nearest folder above
// the scene that holds one).
export function projectSettingsPath(scenePath: string): string {
    const root = findProjectRoot(scenePath);
    const path = root == "/" ? "/" + PROJECT_FILE : root + "/" + PROJECT_FILE;
    return vfs.isFile(path) ? path : "";
}

// `out` set to the quality the project of the scene at `scenePath`
// (absolute) sets, each key it does not set left as `out` holds it
// (Godot's defaults for a new ScreenQuality); a bad value adds its warning
// to `warnings` ("hedra.yaml: <key> is <v>, not one of ..."). A scene in no
// project, or whose hedra.yaml cannot be read, keeps `out`. Returns `out`.
export function projectScreenQuality(scenePath: string, out: ScreenQuality, warnings: Array<string>): ScreenQuality {
    const path = projectSettingsPath(scenePath);
    if (path.length == 0) return out;
    const text = vfs.readToString(path);
    if (!text.ok) return out;
    return screenQualityFromSettings(text.value, out, warnings);
}

// The lines of the settings `text` (hedra.yaml's) that set a screen
// quality key or (milestone 67) a render quality key (../../render/
// quality.as RENDER_SETTING_KEYS, and their `.web` forms), each as `key:
// value` (comments and the spaces around them dropped, the value as
// written) and a line feed, in the file's order: "" when it sets none.
// `hedra build` passes them to registerProject, which
// screenQualityFromSettings and renderQualityFromSettings read back as the
// file reads (each passing over the other's lines, and the navigation
// parser over both). A project that sets no render key passes the lines it
// passed before.
export function screenSettingLines(text: string): string {
    return settingLinesOf(text, true);
}

// The lines of `text` that set a screen quality key alone (whether the
// project sets the screen quality: `inspect --screen`'s source).
export function screenQualityLines(text: string): string {
    return settingLinesOf(text, false);
}

function settingLinesOf(text: string, render: bool): string {
    const lines = text.split("\n");
    let out = "";
    for (let i = 0; i < lines.length; i++) {
        const line = withoutComment(lines[i]).trim();
        const colon = line.indexOf(":");
        if (colon <= 0) continue;
        const key = line.substring(0, colon).trim();
        if (!isScreenSettingKey(key) && !(render && isRenderSettingKey(key))) continue;
        out += key + ": " + line.substring(colon + 1).trim() + "\n";
    }
    return out;
}

// The line (1-based) of `text` that sets `key` first, or 0.
export function settingLine(text: string, key: string): i32 {
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
        const line = withoutComment(lines[i]).trim();
        const colon = line.indexOf(":");
        if (colon > 0 && line.substring(0, colon).trim() == key) return i + 1;
    }
    return 0;
}

// Whether `key` is one of the screen quality settings' keys.
export function isScreenSettingKey(key: string): bool {
    for (let i = 0; i < SCREEN_SETTING_KEYS.length; i++) if (SCREEN_SETTING_KEYS[i] == key) return true;
    return false;
}

// `line` up to a `#` outside quotes (screenQualityFromSettings reads it so).
function withoutComment(line: string): string {
    let q = 0;
    for (let i = 0; i < line.length; i++) {
        const c = line.charCodeAt(i);
        if (q != 0) {
            if (c == q) q = 0;
        } else if (c == 34 || c == 39) {
            q = c;
        } else if (c == 35) {
            return line.substring(0, i);
        }
    }
    return line;
}

// Whether `tree` asks for a screen-space effect, so that its project's
// quality matters (see the header): an Environment of a WorldEnvironment
// with ssr_enabled or screen_refraction_enabled, a node binding either, a
// timeline keying either, or a CameraAttributesPractical in a Camera3D's
// `attributes` or a WorldEnvironment's `camera_attributes` (whose depth of
// field a binding, a timeline or the file turns on). A scene that asks for
// none draws none whatever the quality.
export function asksScreenEffects(tree: SceneTree): bool {
    const walked = tree.walk();
    for (let i = 0; i < walked.length; i++) {
        const n: SceneNode = walked[i];
        const isCamera = n instanceof Camera3D;
        const isWorld = n instanceof WorldEnvironment;
        if (isCamera && (n as Camera3D).attributes != null) return true;
        if (isWorld) {
            const we = n as WorldEnvironment;
            if (we.cameraAttributes != null) return true;
            const env = we.environment;
            if (env != null && (env.ssrEnabled || env.screenRefractionEnabled)) return true;
        }
        for (let k = 0; k < n.bindings.length; k++) if (isScreenTarget(n.bindings[k].property)) return true;
    }
    const scenes = sceneAnimationsOf(tree);
    for (let s = 0; s < scenes.length; s++) {
        const decls = scenes[s].decls;
        for (let d = 0; d < decls.length; d++) {
            const objects = decls[d].objects;
            for (let o = 0; o < objects.length; o++) {
                const props = objects[o].properties;
                for (let p = 0; p < props.length; p++) if (isScreenTarget(props[p].property)) return true;
            }
        }
    }
    return false;
}

function isScreenTarget(property: string): bool {
    return property == SSR_TARGET || property == SCREEN_REFRACTION_TARGET;
}
