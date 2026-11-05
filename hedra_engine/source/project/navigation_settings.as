// The navigation settings a project sets (milestone 63; docs/engine/
// NAVIGATION.md "The map"): Godot's navigation/3d/* project settings,
// written in the project's hedra.yaml (../../scene/navigation/settings.as
// has the keys and the parser). The tools read the scene's project's file
// here (render, inspect, check, bake, the editor); `hedra build` writes the
// keys' lines into the generated hedra_project.as after the screen
// quality's (registerProject's sixth argument: navigationSettingLines),
// which the run time parses once (../../scene/runtime/projects.as
// RegisteredProject.navigationSettings), so a built project's map is the
// tools'.
//
// The file is read only for a scene that has a navigation node, so that a
// command on any other scene reads the files it read before (the session
// host's rounds: ./screen_settings.as says why).

import { vfs } from "../../fs/vfs";
import { NavigationSettings, isNavigationSetting, navigationSettingsFromText } from "../../scene/navigation/settings";
import {
    NavigationAgent3D, NavigationLink3D, NavigationObstacle3D, NavigationRegion3D, SceneNode,
} from "../../scene/tree/node";
import { SceneTree } from "../../scene/tree/tree";
import { projectSettingsPath } from "./screen_settings";

// The settings of the project of the scene at `scenePath` (absolute), into
// `out` (each key the project does not set left as `out` holds it: Godot's
// defaults for a new NavigationSettings); a bad value appends a warning
// ("hedra.yaml: <key> is <v>, not a number above 0"). A scene in no
// project, or whose hedra.yaml cannot be read, keeps `out`. Returns `out`.
export function projectNavigationSettings(scenePath: string, out: NavigationSettings,
    warnings: Array<string>): NavigationSettings {
    const path = projectSettingsPath(scenePath);
    if (path.length == 0) return out;
    const text = vfs.readToString(path);
    if (!text.ok) return out;
    return navigationSettingsFromText(text.value, out, warnings);
}

// Whether `n` is one of the four navigation nodes.
export function isNavigationNode(n: SceneNode): bool {
    const isRegion = n instanceof NavigationRegion3D;
    const isAgent = n instanceof NavigationAgent3D;
    const isObstacle = n instanceof NavigationObstacle3D;
    const isLink = n instanceof NavigationLink3D;
    return isRegion || isAgent || isObstacle || isLink;
}

// Whether `tree` has a navigation node (a region, agent, obstacle or link):
// only such a scene's hedra.yaml is read for these settings.
export function hasNavigation(tree: SceneTree): bool {
    const walked = tree.walk();
    for (let i = 0; i < walked.length; i++) if (isNavigationNode(walked[i])) return true;
    return false;
}

// The settings `tree`'s project sets, read only when it has a navigation
// node (Godot's defaults otherwise, and for a scene in no project).
export function treeNavigationSettings(tree: SceneTree, warnings: Array<string>): NavigationSettings {
    const out = new NavigationSettings();
    if (tree.scenePath.length == 0 || !hasNavigation(tree)) return out;
    return projectNavigationSettings(tree.scenePath, out, warnings);
}

// Whether the project of the scene at `scenePath` (absolute) sets a
// navigation key (`inspect --navmesh` says where its map's settings come
// from: "hedra.yaml" or "defaults").
export function projectSetsNavigation(scenePath: string): bool {
    const path = projectSettingsPath(scenePath);
    if (path.length == 0) return false;
    const text = vfs.readToString(path);
    if (!text.ok) return false;
    return navigationSettingLines(text.value).length > 0;
}

// The lines of the settings `text` (hedra.yaml's) that set a navigation
// key, each as `key: value` (a comment and the spaces round it dropped,
// the value as written) and a line feed, in the file's order: "" when it
// sets none. `hedra build` passes them to registerProject after the screen
// quality's, which navigationSettingsFromText reads back as the file reads.
export function navigationSettingLines(text: string): string {
    const lines = text.split("\n");
    let out = "";
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i];
        // (cut at the first `#`, as navigationSettingsFromText reads it:
        // the values are numbers and booleans, never text holding one)
        const hash = line.indexOf("#");
        if (hash >= 0) line = line.substring(0, hash);
        line = line.trim();
        const colon = line.indexOf(":");
        if (colon <= 0) continue;
        const key = line.substring(0, colon).trim();
        if (!isNavigationSetting(key)) continue;
        out += key + ": " + line.substring(colon + 1).trim() + "\n";
    }
    return out;
}
