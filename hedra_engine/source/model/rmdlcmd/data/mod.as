// The data form of a model (milestone 21): a scene written as data lines,
// one a datablock (Blender's `bpy.data`), that rebuild it exactly, so that
// `encode(replay(write(scene)))` is `encode(scene)` byte for byte. It is
// what the CLI's `convert x.rmdlcmd --data` writes into an .rmdlcmd, the one
// part of the language a program without the command kernel (a built
// project's player) replays (load.as), and what an .rmdl document holds,
// structured as XML (milestone 60: ../../rmdl/, whose writer splits these
// lines and whose reader builds these records for Replay.applySplit).
//
//   # rmdlcmd 1
//   # data form, written by Hedra 0.1.0 from bench.rmdlcmd
//   data scene --objects 5 --active 4 --render-size "512 512"
//   data material 0 Wood --base-color "0.55 0.34 0.18" --roughness 0.65
//   data object 0 Seat --type mesh --transform "0 -0.17 0.45 0 0 0 1.6 0.14 0.05"
//   data modifier 0 Array array --count 3 --relative-offset "0 1.15 0"
//   data mesh 0 --verts 8 --co "-0.5 -0.5 -0.5 ..." --edges 12 ...
//   ...
//
// The lines, their order, their flags and the value syntax are
// docs/formats/RMDLCMD.md's "The data form" (the spec of record for this
// module). In short: `data <record> <positionals> --flag value ...`; a
// number is decimal (an f32 written shortest, displayF32, and read back
// exactly, parseF32); an array is one double-quoted token of
// space-separated numbers; a bool field is a switch, present when true; a
// string is a token (lex.as quoteToken).
//
// Data lines come first in a file, `data scene` before any other, and may
// be followed by ordinary commands (doc.as checkDataPlacement).
//
// Reading does not go through lex.as tokenizeLine for an array: the
// numbers are read in place from the line, so a 50,000-vertex mesh costs
// its arrays and not a token per character (the stub runtime never frees).
//
// The parts: write.as (the writer), read.as (the replay), line.as (a line's
// words and flags), num.as (numbers, written and read in place), words.as
// (the records' forms, enum words and defaults).

import { Result } from "../../../../base/util";
import { Scene } from "../../scene";
import { headerLine } from "../format";
import { sceneLines } from "./write";
import { Replay, materialTexturePaths } from "./read";

// What the writer says about where the data came from, in the second
// comment line (`# data form, written by <by> from <source>`); empty
// strings leave the line out.
export class DataWriteOpts {
    by: string = "";
    source: string = "";
}

// The data lines of a scene, in the order RMDLCMD.md gives (no header, no line
// feeds): scene, materials, actions and their fcurves, objects each with
// their vertex groups, modifiers and mesh or armature records, pose clips,
// imports. Deterministic: the same scene writes the same lines.
export function writeDataLines(scene: Scene): Array<string> {
    return sceneLines(scene);
}

// A whole data-form file: the header, the `# data form, ...` comment when
// opts says something, the data lines; LF line endings, a final line feed.
export function writeDataForm(scene: Scene, opts: DataWriteOpts): string {
    const out: Array<string> = [headerLine(), "\n"];
    if (opts.by.length > 0 || opts.source.length > 0) {
        let c = "# data form";
        if (opts.by.length > 0) c += ", written by " + opts.by;
        if (opts.source.length > 0) c += (opts.by.length > 0 ? " from " : ", from ") + opts.source;
        out.push(c);
        out.push("\n");
    }
    const lines = sceneLines(scene);
    for (let i = 0; i < lines.length; i++) {
        out.push(lines[i]);
        out.push("\n");
    }
    return out.join("");
}

// Replays data lines into a scene. Feed every data line in file order to
// `apply` (the first must be `data scene`), then `finish` once: it checks
// what no single line can (every declared object slot filled, a mesh object
// given its mesh, an armature its armature, references in range) and runs
// the scene's afterLoad, as decoding a cache entry's scene does. Errors are RmdlError
// E_DATA (format.as) at the line given.
export class DataReplay {
    file: string;
    private replay: Replay;

    constructor(file: string) {
        this.file = file;
        this.replay = new Replay(file);
    }

    // One data line; `line` is its 1-based line number, for errors.
    apply(text: string, line: i32): Result<bool> {
        return this.replay.apply(text, line);
    }

    // The scene the lines built.
    finish(): Result<Scene> {
        return this.replay.finish();
    }
}

// The file paths a data line names ([] for every other line): a
// material's MaterialX file and textures, an empty's instanced model. What
// scan.as reports for a data-form file.
export function dataLineTextures(text: string): Array<string> {
    return materialTexturePaths(text);
}
