// The render quality a project sets (docs/engine/PERFORMANCE.md, "The
// knobs"; ../../render/quality.as): its hedra.yaml's lines of
// RENDER_SETTING_KEYS, read for the tools (render, inspect, check, the
// editor) as screen_settings.as reads the screen-space effects' quality.
// `hedra build` passes the same lines to the run time with the screen
// quality's (screen_settings.as screenSettingLines: registerProject's sixth
// argument), which ../../scene/runtime/projects.as parses once, so that a
// built project draws with the quality the tools drew with.
//
// Unlike the screen quality, the file is read for every scene in a project
// (the quality applies to every picture): the tools' session host reads
// the nearest hedra.yaml with the scene before the first run already (it
// decides the project root), so the read costs a command no other round.
// A project that sets none of the keys,
// and a scene in no project, draw with the defaults: every picture of
// before.

import { vfs } from "../../fs/vfs";
import { RenderQuality, renderQualityFromSettings } from "../../render/quality";
import { projectSettingsPath } from "./screen_settings";

// `out` set to the quality the project of the scene at `scenePath`
// (absolute) sets, each key it does not set left as `out` holds it; a bad
// value adds its warning to `warnings`. A scene in no project keeps `out`.
// `web`: the `.web` feature tag's overrides apply (Godot's
// `<key>.web: <value>` lines: the website's WebGL 2 runtime). Returns `out`.
export function projectRenderQuality(scenePath: string, out: RenderQuality, warnings: Array<string>, web: bool = false): RenderQuality {
    const path = projectSettingsPath(scenePath);
    if (path.length == 0) return out;
    const text = vfs.readToString(path);
    if (!text.ok) return out;
    return renderQualityFromSettings(text.value, out, warnings, web);
}
