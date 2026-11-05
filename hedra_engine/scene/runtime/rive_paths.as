// Where a loader's absolute paths are in the Rive project (milestone 67b,
// docs/engine/RESOURCES.md): the remaps (remap.as) and the resource cache
// (../resource/cache.as, keyed by these paths) name every resource by its
// path in the Rive project, whichever root a tree reads it under: the text
// source's (scene_runtime.as textRootOf: "/hedra/world/textures/oak.png")
// or a built file's bundle root ("/hedra-bundle~1000/textures/oak.png",
// its entries named by their paths in the Hedra project).

import { textRootOf } from "./scene_runtime";

// The path in the Rive project of `abs` (a vfs path), for the Hedra project
// `project` (its path in the Rive project, "" for the root) whose built
// file is mounted at `bundleRoot` ("" for none): "world/textures/oak.png";
// "" when `abs` is under neither root.
export function rivePathOfAbs(abs: string, project: string, bundleRoot: string): string {
    const text = textRootOf(project) + "/";
    let rel = "";
    if (abs.startsWith(text)) {
        rel = abs.substring(text.length);
    } else if (bundleRoot.length > 0) {
        const b = bundleRoot.endsWith("/") ? bundleRoot : bundleRoot + "/";
        if (!abs.startsWith(b)) return "";
        rel = abs.substring(b.length);
    } else {
        return "";
    }
    if (rel.length == 0) return "";
    return project.length > 0 ? project + "/" + rel : rel;
}
