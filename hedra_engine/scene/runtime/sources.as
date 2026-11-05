// The three sources of a scene drawn in a Rive project (milestone 41,
// docs/plans/BUILD.md section 6): the types of `hedra_engine/scene`'s loading
// API, which SceneRuntime.load, loadText, loadBuilt and builtState
// (scene_runtime.as) take and give.
//
//   Text   the .rscn and its original assets, read at run time through the
//          `hedra:<path>` blobs the project's hedra_engine.rml declares, by the
//          source readers hedra_engine/source/ installs (the slowest: parsed,
//          models replayed, textures decoded); milestone 42: with the data
//          its bindings name from the Rive project's .rml files, read
//          through the same blobs (project_data.as)
//   Built  the scene's .rscnb under build/hedra/, through its declared
//          blob `hedra:build/hedra/<path>b`: one decode, prebuilt meshes
//          and compressed textures
//   Auto   Built when builtState says Current, else Text, with the reason
//          (and, when SceneOptions.unbuiltLabel is on, the warning label in
//          the canvas's top-right corner: label.as)
//
// A scene's path is its path in the Rive project ("world/courtyard.rscn"),
// or a res:// path of the named project ("res://courtyard.rscn" with
// SceneOptions.project "world").

import { Context } from "rive/host";
import { SceneInstance } from "./scene_runtime";

export enum SceneSource {
    Auto = 0,
    Text = 1,
    Built = 2,
}

// The built form's state against the declared source (SceneRuntime.builtState).
export enum BuiltState {
    // Declared, loads, built for this library's major, and (when the text
    // is declared too) built from that very text (SRCS's SHA-256).
    Current = 0,
    // No built form is declared (or its blob is empty).
    Missing = 1,
    // Built from another text of the scene than the one declared.
    Stale = 2,
    // Built for another major of the library.
    OtherMajor = 3,
    // Declared but not a built scene this version reads.
    Invalid = 4,
}

// The reasons Auto gives for using the text (SceneLoad.reason), and the
// label's first words (label.as): the status's "unbuilt" value.
export const REASON_NOT_BUILT = "not built";
export const REASON_OUT_OF_DATE = "out of date";
// (followed by the major: "built for Hedra 2")
export const REASON_OTHER_MAJOR = "built for Hedra ";
export const REASON_INVALID = "built file unreadable";
// (the text could not be read either: only the label is drawn)
export const REASON_NO_SOURCE_READERS = "no source readers";

// The source name a Scene3D view model's `source` gives (auto, text, built):
// its SceneSource, Auto for anything else.
export function sceneSourceNamed(name: string): SceneSource {
    if (name == "text") return SceneSource.Text;
    if (name == "built") return SceneSource.Built;
    return SceneSource.Auto;
}

export function sceneSourceName(s: SceneSource): string {
    if (s == SceneSource.Text) return "text";
    if (s == SceneSource.Built) return "built";
    return "auto";
}

export class SceneOptions {
    source: SceneSource = SceneSource.Auto;
    // The label (label.as) when Auto falls back to the text. The Scene3D
    // component turns it on by default; the editor, Play and the CLI's
    // render never load through here.
    unbuiltLabel: bool = false;
    // The Hedra project the path is in, as hedra_project.as registered
    // it ("world"); "" takes the project whose name is the path's first
    // directories, else the only one registered.
    project: string = "";
}

export class SceneLoad {
    // The instance, or null when nothing could be drawn.
    instance: SceneInstance? = null;
    // What was used: Text or Built (Auto never).
    source: SceneSource = SceneSource.Text;
    // Why Auto used the text (one of the REASON_* values; "" when it did
    // not fall back).
    reason: string = "";
    errors: Array<string> = [];
    // The scene's path in the Rive project ("" when it could not be told),
    // and the label's text when one is to be shown (labelText: Auto fell
    // back to the text with SceneOptions.unbuiltLabel on; "" otherwise),
    // which a host draws alone when there is no instance (the Scene3D
    // component does).
    scenePath: string = "";
    label: string = "";
}

// What the text source reads through: the declared blobs in a Rive project
// (BlobFiles, reading ctx.blob("hedra:" + path)), a host's files in the
// tools and tests. `path` is a path in the Rive project ("world/courtyard.rscn").
export abstract class FileSource {
    abstract read(path: string): Uint8Array?;

    // Milestone 36: whether the Rive project declares `path` as an audio
    // asset (an AudioAsset named "hedra:" + path), whose bytes `read` does
    // not hand over. None but a Rive project's.
    hasAudio(path: string): bool {
        return false;
    }

    // Whether `other` reads the same files (the run time keeps the read
    // fallback of a project over the same files rather than reading them
    // again).
    sameAs(other: FileSource): bool {
        return this === other;
    }
}

// The FileSource of a Rive project: its `hedra:` blobs (scenes, their
// assets, the built scenes, and the .rml files of the project's data).
export class BlobFiles extends FileSource {
    ctx: Context;

    constructor(ctx: Context) {
        super();
        this.ctx = ctx;
    }

    read(path: string): Uint8Array? {
        const b = this.ctx.blob(blobNameOf(path));
        return b != null ? Uint8Array.wrap(b) : null;
    }

    hasAudio(path: string): bool {
        const a = this.ctx.audio(blobNameOf(path));
        if (a == null) return false;
        a.release();
        return true;
    }

    // (one Rive file's blobs, whichever BlobFiles reads them)
    sameAs(other: FileSource): bool {
        const me: FileSource = this;
        if (me === other) return true;
        // (tested apart: the compiler narrows only a flag's `as`)
        const blobs = other instanceof BlobFiles;
        if (!blobs) return false;
        return (other as BlobFiles).ctx === this.ctx;
    }
}

// The blob name of a file of the Rive project (docs/plans/BUILD.md section
// 5.3): "hedra:" and its path ("hedra:world/courtyard.rscn",
// "hedra:build/hedra/world/courtyard.rscnb"). The build's declarations
// (editor/program/src/build/rive/paths.as) name every blob so.
export const BLOB_PREFIX = "hedra:";

export function blobNameOf(path: string): string {
    return BLOB_PREFIX + path;
}

// Where the CLI's `build` writes the built form of the scene at `path` in the
// Rive project ("world/courtyard.rscn" -> "build/hedra/world/courtyard.rscnb").
export const BUILT_DIR = "build/hedra/";

export function builtPathOf(path: string): string {
    return BUILT_DIR + path + "b";
}
