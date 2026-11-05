// The model files Hedra reads, told apart by their extension: the one place
// that says which is which, so that the loader, the closure, the build, the
// CLI and the editors agree (milestone 60).
//
//   .rmdl      the model as a document of what it is at a moment: XML,
//              written like an .rscn (docs/formats/RMDL.md; ./rmdl/), the
//              default form of a model's source
//   .rmdlcmd   the model as the commands that build it, one per line
//              (docs/formats/RMDLCMD.md; ./rmdlcmd/), a script and a
//              history that replays into a model
//   .gltf .glb glTF 2.0, read through the importer
//
// The retired binary `.modeler` (base/names.as RETIRED_MODEL_EXTENSION) is
// no model file here: the loader names it only to say how it was replaced.

import { toAsciiLowercase } from "../../base/util";

// The extensions, without the dot.
export const RMDL_EXTENSION = "rmdl";
export const RMDLCMD_EXTENSION = "rmdlcmd";

// Every extension a model file may have, in the order messages list them.
export const MODEL_FILE_EXTENSIONS: StaticArray<string> = ["rmdl", "rmdlcmd", "gltf", "glb"];

export enum ModelFileKind {
    // No model file (another extension, or none).
    None = 0,
    // An .rmdl: the XML document of the model.
    Snapshot = 1,
    // An .rmdlcmd: the commands that build it.
    Commands = 2,
    // A .gltf or .glb.
    Gltf = 3,
}

// The extension of the last segment of `path`, lowercased, without the dot
// ("" when it has none; a leading dot is a name, not an extension).
export function lowerExtensionOf(path: string): string {
    const dot = path.lastIndexOf(".");
    const slash = max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
    if (dot <= slash + 1) return "";
    return toAsciiLowercase(path.substring(dot + 1));
}

// What kind of model file `path` names, by its extension (any case).
export function modelFileKind(path: string): ModelFileKind {
    const ext = lowerExtensionOf(path);
    if (ext == RMDL_EXTENSION) return ModelFileKind.Snapshot;
    if (ext == RMDLCMD_EXTENSION) return ModelFileKind.Commands;
    if (ext == "gltf" || ext == "glb") return ModelFileKind.Gltf;
    return ModelFileKind.None;
}

// An .rmdl (the XML document).
export function isRmdlPath(path: string): bool {
    return modelFileKind(path) == ModelFileKind.Snapshot;
}

// An .rmdlcmd (the commands).
export function isRmdlcmdPath(path: string): bool {
    return modelFileKind(path) == ModelFileKind.Commands;
}

// An .rmdl or an .rmdlcmd: a model file the model kernel edits.
export function isModelSourcePath(path: string): bool {
    const k = modelFileKind(path);
    return k == ModelFileKind.Snapshot || k == ModelFileKind.Commands;
}

// Any model file: .rmdl, .rmdlcmd, .gltf or .glb.
export function isModelFilePath(path: string): bool {
    return modelFileKind(path) != ModelFileKind.None;
}

// `path` with its extension, if it has one, replaced by `ext` (without the
// dot): `lamp.glb` -> `lamp.rmdl`.
export function withModelExtension(path: string, ext: string): string {
    const dot = path.lastIndexOf(".");
    const slash = max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
    const stem = dot > slash + 1 ? path.substring(0, dot) : path;
    return stem + "." + ext;
}

// `lamp.rmdlcmd` -> `lamp.rmdl`.
export function rmdlPathFor(path: string): string {
    return withModelExtension(path, RMDL_EXTENSION);
}

// `lamp.rmdl` -> `lamp.rmdlcmd`.
export function rmdlcmdPathFor(path: string): string {
    return withModelExtension(path, RMDLCMD_EXTENSION);
}
