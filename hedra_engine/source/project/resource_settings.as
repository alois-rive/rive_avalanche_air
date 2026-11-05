// The loading and memory settings a project sets (milestone 67b;
// docs/engine/RESOURCES.md, "Settings"): hedra.yaml's loading/*, memory/*,
// debug/print_resources and export/embed_sources lines (../../scene/runtime/resource_settings.as
// has the keys and the parser). `hedra build` writes their lines into the
// generated hedra_project.as after the navigation's (registerProject's
// sixth argument: resourceSettingLines), which the run time parses once
// (../../scene/runtime/projects.as RegisteredProject.resourceSettings); the
// build reads export/embed_sources itself (projectResourceSettings).

import { vfs } from "../../fs/vfs";
import { ResourceSettings, isResourceSettingKey, resourceSettingsFromText } from "../../scene/runtime/resource_settings";
import { projectSettingsPath } from "./screen_settings";

// The settings of the project of the scene at `scenePath` (absolute), over
// `out` (what the project does not set left as `out` holds it); a bad value
// appends a warning. A scene in no project, or whose hedra.yaml cannot be
// read, keeps `out`.
export function projectResourceSettings(scenePath: string, out: ResourceSettings, warnings: Array<string>): ResourceSettings {
    const path = projectSettingsPath(scenePath);
    if (path.length == 0) return out;
    const text = vfs.readToString(path);
    if (!text.ok) return out;
    return resourceSettingsFromText(text.value, out, warnings);
}

// The lines of the settings `text` (hedra.yaml's) that set a loading or
// memory key, each as `key: value` and a line feed, in the file's order:
// "" when it sets none, so that a project that sets none writes the
// hedra_project.as it wrote before. export/embed_sources is the build's
// and is left out.
export function resourceSettingLines(text: string): string {
    const lines = text.split("\n");
    let out = "";
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i];
        const hash = line.indexOf("#");
        if (hash >= 0) line = line.substring(0, hash);
        line = line.trim();
        const colon = line.indexOf(":");
        if (colon <= 0) continue;
        const key = line.substring(0, colon).trim();
        if (!isResourceSettingKey(key) || key == "export/embed_sources") continue;
        out += key + ": " + line.substring(colon + 1).trim() + "\n";
    }
    return out;
}
