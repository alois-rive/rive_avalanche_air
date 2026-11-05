// What the loader and the model readers share of a model load (milestone
// 39: apart from model.as, so that the loader names them without
// importing the readers, which the run time does not carry:
// loader.as FileReaders): the texture source a model reads its textures
// from, and the codes and hints of the load errors.

import { StandardMaterial3D, Texture2D } from "./types";
import { CLI, RETIRED_MODEL_PROGRAM } from "../../base/names";

// Where a model's textures come from: the loader implements it over its
// cache (and over the images a glTF file embeds, which never touch the
// disk).
export abstract class TextureSource {
    // Why the last `texture` returned null.
    why: string = "";
    // The texture at an absolute path (or an embedded image's key), or null
    // with the reason in `why`.
    abstract texture(path: string): Texture2D?;

    // How a warning names the texture at `path`, which the model wrote as
    // `written`: as written, so no machine-specific absolute path shows.
    shown(path: string, written: string): string {
        return written;
    }

    // The material of the MaterialX file at an absolute path (a model's
    // material that is one), or null with the reason in `why`. A source
    // that reads no material file says so.
    material(path: string): StandardMaterial3D? {
        this.why = "no material file is read here";
        return null;
    }
}

// The hints of the load errors every command reports (every error has
// one): a file that could not be read, and one named by an ext_resource
// (inspect --check words its own the same way), a model that did not load,
// a texture that is no PNG.
export const FILE_READ_HINT = "check that the file exists and can be read";
export const MODEL_LOAD_HINT = "a model must be an .rmdl, .rmdlcmd, .modeler, .gltf or .glb file, whole and in the format its extension says";

// The warning a .modeler model gets (milestone 21): the format is retired.
// What replaced it is a model document (.rmdl), written from the model's
// commands (.rmdlcmd), which the retired program's `convert` writes.
// Read-only commands never convert (they write no model), so they say how.
export const MODEL_RETIRED_CODE = "model-format-retired";
export const MODEL_RETIRED_HINT = "an .rmdl is the model format (docs/formats/RMDL.md); `" + CLI + " model x.rmdlcmd --to x.rmdl` "
    + "writes one from the model's commands";

// `models/bench.modeler is a .modeler, a retired format: ...`, `display`
// being how the loader names the file (its res:// path: the command and
// the path name it from the project's root, without the scheme).
export function retiredModelMessage(display: string): string {
    const p = display.startsWith("res://") ? display.substring(6) : display;
    const stem = stemPathOf(p);
    return p + " is a .modeler, a retired format: `" + RETIRED_MODEL_PROGRAM + " convert " + p + "` writes its commands, and, "
        + "saved as " + stem + ".rmdlcmd, `" + CLI + " model " + stem + ".rmdlcmd --to " + stem + ".rmdl` writes the model; "
        + "point the scene at " + stem + ".rmdl";
}

// `lamp.modeler` -> `lamp`: the path without its extension
// (engine/src/source/model/formats.as withModelExtension's rule, copied
// because the engine's runtime imports nothing of the source tier).
function stemPathOf(path: string): string {
    const dot = path.lastIndexOf(".");
    const slash = max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
    return dot > slash + 1 ? path.substring(0, dot) : path;
}

export const TEXTURE_DECODE_HINT = "a texture must be a PNG";

export function extPathHint(extPath: string): string {
    return "check the path: " + (extPath.startsWith("res://") ? "res:// starts at the project root" : "a relative path starts at this file's directory");
}
