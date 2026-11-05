// The files a model names (milestone 21): what a prefetcher asks for before
// a model loads, so that a load runs once (host/CONTRACT.md §8.2). From the
// doc's lines, without replaying them:
//
// - an `import <path>` command's source (and, for a .gltf, nothing more:
//   the prefetcher asks for its buffers and images once it has its bytes);
// - a `material texture <material> <slot> <path>` command's image;
// - a `material file <material> <path>` command's MaterialX file;
// - an `add instance <path>` or `instance set <path>` command's model;
// - a data line's file paths (`data material ... --file <path>
//   --base-color-texture <path>`, `data object ... --instance <path>`,
//   data/mod.as);
//
// each as the line wrote it: relative to the model's directory, or
// absolute. Scenery's prefetcher (editor/program/src/app/host/prefetch.as),
// the editor's closure (editor/src/scene/closure.as) and Hedra's
// prefetcher take them; the cache directory (cache.as) is theirs to list.
//
// The two commands' shapes are Hedra's registry's (engine/src/commands/lang/registry/
// base.as `import`, alias `import_scene.gltf`; materials.as `material
// texture`), read here without Hedra's parser: every flag of `import`
// takes one value, and of `material texture`'s flags `--uv-layer` takes one
// and `--clear` none. A flag written `--name=value` is one token either way.
// A line that does not tokenize names nothing (its load fails at it).

import { DATA_WORD, RmdlDoc } from "./doc";
import { firstWord, tokenizeLine } from "./lex";
import { dataLineTextures } from "./data/mod";
import { recordOf } from "./data/line";

function isFlag(tok: string): bool {
    return tok.length > 2 && tok.startsWith("--");
}

// The `which`-th positional (0-based) of tokens[from..], skipping flags and
// the value of each flag that takes one (all but the `switches`); null when
// there are fewer.
function positional(tokens: Array<string>, from: i32, which: i32, switches: Array<string>, triples: Array<string> = NO_SWITCHES): string? {
    let seen = 0;
    let i = from;
    while (i < tokens.length) {
        const t = tokens[i];
        i++;
        if (isFlag(t)) {
            const body = t.substring(2);
            if (body.indexOf("=") < 0 && !switches.includes(body)) i += triples.includes(body) ? 3 : 1;
            continue;
        }
        if (seen == which) return t;
        seen++;
    }
    return null;
}

const NO_SWITCHES: Array<string> = [];
const TEXTURE_SWITCHES: Array<string> = ["clear"];
// `add instance`'s placement flags, which take three numbers.
const PLACEMENT_TRIPLES: Array<string> = ["location", "rotation"];

// Whether `material texture`'s tokens clear the slot (`--clear`, or
// `--clear=<v>` with a value Hedra's parser takes as true).
function clears(tokens: Array<string>): bool {
    for (let i = 2; i < tokens.length; i++) {
        const t = tokens[i];
        if (t == "--clear") return true;
        if (t.startsWith("--clear=")) {
            const v = t.substring(8);
            return v == "true" || v == "1" || v == "yes" || v == "on";
        }
    }
    return false;
}

// The path one command line names, or null.
function commandPath(line: string): string? {
    const word = firstWord(line);
    // (cheap first: only these commands name a file, and the word decides)
    if (word != "import" && word != "import_scene.gltf" && word != "material" && word != "add" && word != "instance"
        && word != "object.collection_instance_add") {
        return null;
    }
    const t = tokenizeLine(line);
    if (!t.ok) return null;
    const tokens = t.value;
    if (tokens.length == 0) return null;
    if (tokens[0] == "import" || tokens[0] == "import_scene.gltf") return positional(tokens, 1, 0, NO_SWITCHES);
    if (tokens[0] == "material" && tokens.length > 1 && tokens[1] == "texture") {
        // material, slot, path: `--clear` names no path
        if (clears(tokens)) return null;
        return positional(tokens, 2, 2, TEXTURE_SWITCHES);
    }
    if (tokens[0] == "material" && tokens.length > 1 && tokens[1] == "file") {
        // material, path: `--clear` names no path
        if (clears(tokens)) return null;
        return positional(tokens, 2, 1, TEXTURE_SWITCHES);
    }
    // An instanced model: `add instance <path>` (--location and --rotation
    // take three numbers, the others one), `instance set <path>`.
    if (tokens[0] == "object.collection_instance_add") return positional(tokens, 1, 0, NO_SWITCHES, PLACEMENT_TRIPLES);
    if (tokens.length > 1 && ((tokens[0] == "add" && tokens[1] == "instance") || (tokens[0] == "instance" && tokens[1] == "set"))) {
        return positional(tokens, 2, 0, NO_SWITCHES, PLACEMENT_TRIPLES);
    }
    return null;
}

// The paths, in the order the lines name them, each once.
export function referencedPaths(doc: RmdlDoc): Array<string> {
    const out: Array<string> = [];
    const once = new Set<string>();
    for (let i = 0; i < doc.entries.length; i++) {
        const c = doc.entries[i].commands;
        for (let k = 0; k < c.length; k++) {
            const line = c[k];
            if (firstWord(line) == DATA_WORD) {
                const ps = dataLineTextures(line);
                for (let m = 0; m < ps.length; m++) {
                    if (once.has(ps[m])) continue;
                    once.add(ps[m]);
                    out.push(ps[m]);
                }
                continue;
            }
            const p = commandPath(line);
            if (p == null) continue;
            const path: string = p;
            if (once.has(path)) continue;
            once.add(path);
            out.push(path);
        }
    }
    return out;
}

// The models the doc's lines instance (`add instance`, `instance set`, a
// data line's `--instance`), in the order the lines name them, each once:
// what an instance cycle is followed through.
export function instancedPaths(doc: RmdlDoc): Array<string> {
    const out: Array<string> = [];
    for (let i = 0; i < doc.entries.length; i++) {
        const c = doc.entries[i].commands;
        for (let k = 0; k < c.length; k++) {
            const line = c[k];
            const word = firstWord(line);
            let p: string? = null;
            if (word == DATA_WORD) {
                // (an object line names one path: its instance)
                if (recordOf(line) == "object") {
                    const ps = dataLineTextures(line);
                    if (ps.length == 1) p = ps[0];
                }
            } else if (word == "add" || word == "instance" || word == "object.collection_instance_add") {
                p = commandPath(line);
            }
            if (p == null || out.includes(p!)) continue;
            out.push(p!);
        }
    }
    return out;
}

// The sources of the doc's `import` commands alone (no texture), in the
// order the lines name them, each once: the files whose geometry the
// model is made from (milestone 26: the import system's source_hash of an
// .rmdlcmd mixes in theirs, so a changed glTF makes the model stale).
export function importedPaths(doc: RmdlDoc): Array<string> {
    const out: Array<string> = [];
    for (let i = 0; i < doc.entries.length; i++) {
        const c = doc.entries[i].commands;
        for (let k = 0; k < c.length; k++) {
            const line = c[k];
            const word = firstWord(line);
            if (word != "import" && word != "import_scene.gltf") continue;
            const p = commandPath(line);
            if (p == null || out.includes(p!)) continue;
            out.push(p!);
        }
    }
    return out;
}

// Whether a line of the file (its bytes) adds a tool modifier: a model
// whose scene a user tool shapes, which needs that tool to replay and, its
// stack evaluated, to convert (the tool files beside the model:
// engine/src/commands/tools.as ModelTools). Hedra writes a command line
// as it was typed and its parser takes several spellings of the one
// command, so the scan does not look for exact words: a line counts when
// its first word is `modifier`, `object.modifier_add` (the alias) or
// `data` followed by `modifier` (the data form, `data modifier <id> <name>
// tool --tool <name>`, which the CLI's `convert --data` writes), and a later
// word, its quotes stripped, is `tool`, case ignored. That covers a flag
// before the type (`modifier add --name G tool g`), a quoted or upper-case
// type, and the data form. Over-matching (a modifier named "tool") costs
// one directory listing; missing a line would lose the tool's work. Read
// from the bytes, word by word, allocating nothing, so a loader can ask it
// of every model it reads: a comment line, a tool block's `# <tool> ... {`
// among them, is not a command.
const WORD_MODIFIER = "modifier";
const WORD_ALIAS = "object.modifier_add";
const WORD_DATA = "data";
const WORD_TOOL = "tool";

export function namesToolModifier(bytes: Uint8Array): bool {
    const n = bytes.length;
    let i = 0;
    while (i < n) {
        // one line, word by word
        let word = 0;
        let ok = true;
        let isData = false;
        while (ok) {
            while (i < n && isBlank(bytes[i])) i++;
            if (i >= n || bytes[i] == 10 || bytes[i] == 13) break;
            if (word == 0 && bytes[i] == 35) break; // '#': a comment
            // the word's bounds, its quotes left out
            let from = i;
            let to = i;
            if (bytes[i] == 34) {
                from = i + 1;
                i++;
                // (to the closing quote, or the line's end when there is none;
                // a backslash escapes the byte after it)
                while (i < n && bytes[i] != 34 && bytes[i] != 10 && bytes[i] != 13) {
                    if (bytes[i] == 92 && i + 1 < n && bytes[i + 1] != 10 && bytes[i + 1] != 13) i++;
                    i++;
                }
                to = i;
                if (i < n && bytes[i] == 34) i++;
            } else {
                while (i < n && !isBlank(bytes[i]) && bytes[i] != 10 && bytes[i] != 13) i++;
                to = i;
            }
            if (word == 0) {
                isData = wordIs(bytes, from, to, WORD_DATA);
                ok = isData || wordIs(bytes, from, to, WORD_MODIFIER) || wordIs(bytes, from, to, WORD_ALIAS);
            } else if (word == 1 && isData) {
                ok = wordIs(bytes, from, to, WORD_MODIFIER);
            } else if (wordIs(bytes, from, to, WORD_TOOL)) {
                return true;
            }
            word++;
        }
        while (i < n && bytes[i] != 10) i++;
        i++;
    }
    return false;
}

// Whether bytes[from, to) spell `w` (lower case ASCII), case ignored.
function wordIs(bytes: Uint8Array, from: i32, to: i32, w: string): bool {
    if (to - from != w.length) return false;
    for (let k = 0; k < w.length; k++) {
        let b = <i32>bytes[from + k];
        if (b >= 65 && b <= 90) b += 32;
        if (b != w.charCodeAt(k)) return false;
    }
    return true;
}

function isBlank(b: u8): bool {
    return b == 32 || b == 9;
}
