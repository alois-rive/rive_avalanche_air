// The ArtboardTexture resource and the RiveFile it names (milestone 15):
// the one place their rules are written, so that the loader (RiveFile
// ext_resources), the sub_resource builder (build.as), the material files
// (material_file.as: an .mtlx slot with an artboard), the warnings, the
// player of built projects and the CLI's `build` agree. The format is
// docs/formats/RSCN.md's "ArtboardTexture"; MaterialX's form is
// MATERIALS.md's "Artboard textures".
//
// The rules:
// - A RiveFile is a .riv, read for its artboards (../riv/riv_info.as). A
//   file that is not a Rive file fails its ext_resource (code
//   riv-invalid), as a PNG that is not one does.
// - An ArtboardTexture's size is `size` when set (each side 1 to
//   MAX_ARTBOARD_TEXTURE_SIDE), else the artboard's own size rounded
//   (each side at least 1, at most MAX_ARTBOARD_TEXTURE_SIDE), else, with
//   no artboard to read it from, DEFAULT_ARTBOARD_TEXTURE_SIDE square.
// - Its `path` is artboardTexturePath(declaring file, id), and its `image`
//   the placeholder (../render/artboard_placeholder.as) titled with the
//   artboard's name, its detail the file's display path and the state
//   machine the texture runs.
// - Problems are warnings, never errors, so a scene with a misspelt
//   artboard still renders (its placeholder says what it names):
//   artboard-file-missing (no `file`), artboard-unknown (the file has no
//   such artboard; the hint lists the ones it has), state-machine-unknown
//   (the artboard has no such state machine; the hint lists them),
//   artboard-size (a `size` side outside 1 to 8192 other than 0 x 0).
// - The source of a .riv, which the CLI's `build` copies into the project
//   so that the built scene plays the artboard (a script cannot load
//   another Rive file): the Rive project directory beside it with the
//   file's stem, `<dir>/<stem>/rive.yaml` (riveSourceDir).

import { Result } from "../../base/util";
import { vfs } from "../../fs/vfs";
import { fileStem, join, parent } from "../../fs/path";
import { SceneryError } from "../error";
import { RivArtboard, RivInfo, readRivInfo } from "../riv/riv_info";
import { artboardPlaceholder } from "../render/artboard_placeholder";
import { ARTBOARD_TEXTURE_MARK, ArtboardTexture, Resource, RiveFile } from "./types";

// A size side's bounds (the CLI's `render --size`'s range) and the side of a
// texture whose artboard is unknown.
export const MAX_ARTBOARD_TEXTURE_SIDE: i32 = 8192;
export const DEFAULT_ARTBOARD_TEXTURE_SIDE: i32 = 512;

// Where every artboard problem's hint sends a reader.
export const ARTBOARD_DOC = "docs/formats/RSCN.md (ArtboardTexture)";

// The `path` of an ArtboardTexture declared in the file at `declaringAbs`
// (an absolute path) as `key` (its sub_resource id, or an .mtlx slot's
// property name).
export function artboardTexturePath(declaringAbs: string, key: string): string {
    return declaringAbs + ARTBOARD_TEXTURE_MARK + key;
}

// Whether a texture path is an ArtboardTexture's (artboardTexturePath).
export function isArtboardTexturePath(path: string): bool {
    return path.includes(ARTBOARD_TEXTURE_MARK);
}

// The key a built project names an artboard by: the RiveFile's display
// path ("res://ui/screen.riv") and the artboard's name, "#" between. The
// generated src/artboards.as lists these in the order of main.as's
// artboard inputs, and the player matches its textures to them.
export function artboardSourceKey(rivDisplayPath: string, artboard: string): string {
    return rivDisplayPath + "#" + artboard;
}

// The Rive project a .riv at `rivAbs` is baked from: `<dir>/<stem>`, which
// the CLI's `build` reads when it holds a rive.yaml.
export function riveSourceDir(rivAbs: string): string {
    const dir = parent(rivAbs);
    const stem = fileStem(rivAbs);
    return join(dir != null ? dir : "/", stem != null ? stem : "");
}

// The hint of riv-invalid: what a RiveFile ext_resource takes.
export const RIV_INVALID_HINT = "name a .riv the rive CLI or the Rive editor wrote; see " + ARTBOARD_DOC;

// The loader's reader of a RiveFile ext_resource (loader.as calls it for
// type RiveFile): the file's bytes read and its artboards with them. A
// file that does not read as a Rive file fails (riv-invalid), as a PNG
// that is not one does (texture-decode): an ArtboardTexture of it could
// only ever be a placeholder, and the build could not tell which artboards
// it holds.
export function readRiveFile(abs: string, display: string): Result<Resource> {
    const bytes = vfs.read(abs);
    if (!bytes.ok) {
        return SceneryError.at("file-read", display, 0, 0, "cannot read " + display + ": " + bytes.err,
            "the path is relative to the file that names it, or res:// from the project root").fail<Resource>();
    }
    const info = readRivInfo(bytes.value);
    if (!info.ok) {
        return SceneryError.at("riv-invalid", display, 0, 0, display + " is not a Rive file: " + info.err, RIV_INVALID_HINT).fail<Resource>();
    }
    const f = new RiveFile();
    f.info = info.value;
    return Result.okv<Resource>(f);
}

// The artboard `t` names in its file, or null (no file, no info, no such
// artboard).
export function artboardOf(t: ArtboardTexture): RivArtboard? {
    const f = t.rive;
    if (f == null) return null;
    const info: RivInfo? = f.info;
    if (info == null) return null;
    return info.artboard(t.artboard);
}

// The state machine an instance of `t`'s artboard runs: `state_machine`
// when set and the artboard has it (or the artboard is unknown, so it
// cannot be told), else the artboard's default one, as the CLI's `build`
// plays it ("" when it has none or is unknown).
export function stateMachineOf(t: ArtboardTexture): string {
    const a = artboardOf(t);
    if (t.stateMachine.length > 0 && (a == null || a.hasStateMachine(t.stateMachine))) return t.stateMachine;
    return a != null ? a.defaultStateMachineName() : "";
}

// `t`'s size in pixels by the rules above: [width, height].
export function resolveArtboardTextureSize(t: ArtboardTexture): StaticArray<i32> {
    if (sizeInRange(t.sizeX, t.sizeY)) return [t.sizeX, t.sizeY];
    const a = artboardOf(t);
    if (a != null) return [side(a.width), side(a.height)];
    return [DEFAULT_ARTBOARD_TEXTURE_SIDE, DEFAULT_ARTBOARD_TEXTURE_SIDE];
}

function side(x: f32): i32 {
    if (!(x >= 1)) return 1;
    if (x > <f32>MAX_ARTBOARD_TEXTURE_SIDE) return MAX_ARTBOARD_TEXTURE_SIDE;
    return <i32>Mathf.round(x);
}

// The second line of `t`'s placeholder: the file's display path without
// "res://", then the state machine an instance runs when there is one
// ("ui/screen.riv, Main"); "" without a file.
export function placeholderDetail(t: ArtboardTexture): string {
    const f = t.rive;
    if (f == null) return "";
    let file = f.file;
    if (file.startsWith("res://")) file = file.substring(6);
    const sm = stateMachineOf(t);
    return sm.length > 0 ? file + ", " + sm : file;
}

// Finishes a texture whose fields are set (build.as after its properties,
// material_file.as for an .mtlx slot): its path, its size and its
// placeholder. `declaringAbs` and `key` as artboardTexturePath's.
export function finishArtboardTexture(t: ArtboardTexture, declaringAbs: string, key: string): void {
    t.path = artboardTexturePath(declaringAbs, key);
    const size = resolveArtboardTextureSize(t);
    t.width = size[0];
    t.height = size[1];
    t.image = artboardPlaceholder(t.artboard, placeholderDetail(t), size[0], size[1]);
}

// The key `t` was declared by (its sub_resource id, or its .mtlx slot's
// property name): what follows ARTBOARD_TEXTURE_MARK in its path; "" for a
// texture not finished.
export function artboardTextureKey(t: ArtboardTexture): string {
    const at = t.path.lastIndexOf(ARTBOARD_TEXTURE_MARK);
    return at < 0 ? "" : t.path.substring(at + ARTBOARD_TEXTURE_MARK.length);
}

// The absolute path of the file that declared `t` (artboardTexturePath's
// `declaringAbs`); "" for a texture not finished.
export function artboardTextureDeclarer(t: ArtboardTexture): string {
    const at = t.path.lastIndexOf(ARTBOARD_TEXTURE_MARK);
    return at < 0 ? "" : t.path.substring(0, at);
}

// One problem of an ArtboardTexture (a warning): its code, message and
// hint, as the warnings and `inspect --check` report it.
export class ArtboardProblem {
    code: string;
    message: string;
    hint: string;

    constructor(code: string, message: string, hint: string) {
        this.code = code;
        this.message = message;
        this.hint = hint;
    }

    // Every problem is a warning: the name keeps the code on the line that
    // reports it, where cli/tests/scene/test_docs.py reads the codes.
    static warning(code: string, message: string, hint: string): ArtboardProblem {
        return new ArtboardProblem(code, message, hint);
    }
}

// `names` as "A, B and C" ("none" when empty).
function listed(names: Array<string>): string {
    if (names.length == 0) return "none";
    let s = "";
    for (let i = 0; i < names.length; i++) {
        if (i > 0) s += i == names.length - 1 ? " and " : ", ";
        s += names[i];
    }
    return s;
}

// The state machines of `a`, the default one marked: "Main (default),
// Pulse".
export function stateMachineList(a: RivArtboard): string {
    const out = new Array<string>();
    for (let i = 0; i < a.stateMachines.length; i++) {
        out.push(a.stateMachines[i] + (i == a.defaultStateMachine ? " (default)" : ""));
    }
    return out.join(", ");
}

// How a problem names `t`: `ArtboardTexture "Tex_screen"`.
function named(t: ArtboardTexture): string {
    const key = artboardTextureKey(t);
    return key.length > 0 ? "ArtboardTexture \"" + key + "\"" : "an ArtboardTexture";
}

// The problems of `t` by the rules above, in the order listed there. A file
// that did not read (no info: the loader reported it) has no artboard to
// check against, so only the file and the size are checked.
export function artboardTextureProblems(t: ArtboardTexture): Array<ArtboardProblem> {
    const out = new Array<ArtboardProblem>();
    const f = t.rive;
    if (f == null) {
        out.push(ArtboardProblem.warning("artboard-file-missing", named(t) + " names no Rive file: it draws as a placeholder",
            "set its file to ExtResource(\"<id>\") of a RiveFile ext_resource (a .riv); see " + ARTBOARD_DOC));
    } else {
        const info: RivInfo? = f.info;
        if (info != null) {
            const a = info.artboard(t.artboard);
            if (a == null) {
                const what = t.artboard.length > 0 ? ": " + f.file + " has no artboard \"" + t.artboard + "\"" : " names no artboard";
                out.push(ArtboardProblem.warning("artboard-unknown", named(t) + what + ": it draws as a placeholder",
                    "the artboards of " + f.file + " are " + listed(info.artboardNames()) + "; see " + ARTBOARD_DOC));
            } else if (t.stateMachine.length > 0 && !a.hasStateMachine(t.stateMachine)) {
                const machines = a.stateMachines.length > 0
                    ? "the state machines of " + a.name + " are " + stateMachineList(a)
                    : a.name + " has no state machine";
                out.push(ArtboardProblem.warning("state-machine-unknown",
                    named(t) + ": artboard " + a.name + " of " + f.file + " has no state machine \"" + t.stateMachine + "\"",
                    machines + "; leave state_machine empty for the default one; see " + ARTBOARD_DOC));
            }
        }
    }
    if (!(t.sizeX == 0 && t.sizeY == 0) && !sizeInRange(t.sizeX, t.sizeY)) {
        const size = resolveArtboardTextureSize(t);
        out.push(ArtboardProblem.warning("artboard-size",
            named(t) + ": size Vector2i(" + t.sizeX.toString() + ", " + t.sizeY.toString() + ") is out of range: each side is 1 to "
                + MAX_ARTBOARD_TEXTURE_SIDE.toString(),
            "it takes " + size[0].toString() + " x " + size[1].toString()
                + " instead; Vector2i(0, 0) is the artboard's own size; see " + ARTBOARD_DOC));
    }
    return out;
}

function sizeInRange(x: i32, y: i32): bool {
    return x >= 1 && y >= 1 && x <= MAX_ARTBOARD_TEXTURE_SIDE && y <= MAX_ARTBOARD_TEXTURE_SIDE;
}
