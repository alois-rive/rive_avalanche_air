// Milestone 26, package WP3: the `.import` file beside each asset
// (`stone.png.import`), Godot's ConfigFile syntax and sections:
//
//   [remap]
//
//   importer="texture"
//   type="CompressedTexture2D"
//   metadata/srgb=true
//   metadata/normal_map=false
//
//   [deps]
//
//   source_file="stone.png"
//   source_hash="3f9a0c2e5d1b7a44"
//   dest_files=["build/cache/import/stone.png-1a2b3c4d5e6f7081.bc.ktx2", ...]
//
//   [params]
//
//   compress/mode=2
//   ...
//
// [remap] says which importer made it and what the detections resolved
// to (`metadata/<key>=<value>`, what detect settings became); [deps] the
// asset by its file name (relative to the .import's directory, never
// res://: the pair moves together), the FNV-1a 64 of its bytes (16 hex
// digits) and the processed files, relative to the same directory; and
// [params] every setting of the importer (params.as), in its order. The
// writer writes exactly this, with one blank line after each section
// header and between sections, and a final newline; the reader takes
// Godot's syntax more loosely (`;` comments, spaces around `=`, keys in any
// order, unknown keys kept and written back after the known ones) and
// fails, with the line, on anything else. docs/formats/IMPORT.md, "The
// .import file", is normative.
//
// Milestone 36: a sound's .import is the same file of its importer (wav,
// mp3, flac: params.as), whose [remap] metadata says what the loop
// resolved to (a WAV's metadata/loop_mode, loop_begin and loop_end: the
// reader at run time, which has no bytes to detect a smpl loop from,
// reads them) and whose dest_files name a WAV's left and right forms.

import { Result, toAsciiLowercase } from "../../base/util";
import {
    FLAC_IMPORTER, IMPORTERS, ImportParams, MODEL_IMPORTER, MP3_IMPORTER, TEXTURE_IMPORTER, WAV_IMPORTER, canonicalValue, findDef,
    paramDefsOf,
} from "./params";

export const IMPORT_EXTENSION = "import";

// The resource type [remap] names for each importer (Godot's).
export const TEXTURE_TYPE = "CompressedTexture2D";
export const MODEL_TYPE = "PackedScene";
// The sounds' (Godot's AudioStreamWAV and AudioStreamMP3; a FLAC is the
// AudioStream base, Godot having no class of its own for it).
export const WAV_TYPE = "AudioStreamWAV";
export const MP3_TYPE = "AudioStreamMP3";
export const FLAC_TYPE = "AudioStream";

// The .import file of an asset: its path with ".import" appended.
export function importPathOf(assetPath: string): string {
    return assetPath + "." + IMPORT_EXTENSION;
}

// Whether `path` is an .import file (any case).
export function isImportPath(path: string): bool {
    const n = path.length;
    return n > 7 && toAsciiLowercase(path.substring(n - 7)) == "." + IMPORT_EXTENSION;
}

// The type an importer's resources are (Godot's names), "" for an unknown
// importer.
export function importTypeOf(importer: string): string {
    if (importer == TEXTURE_IMPORTER) return TEXTURE_TYPE;
    if (importer == MODEL_IMPORTER) return MODEL_TYPE;
    if (importer == WAV_IMPORTER) return WAV_TYPE;
    if (importer == MP3_IMPORTER) return MP3_TYPE;
    if (importer == FLAC_IMPORTER) return FLAC_TYPE;
    return "";
}

// A key of [remap] or [deps] this version does not use (Godot's `uid`,
// `path`, `valid`, ...): kept as read, value and all, and written back at
// the end of its section, so another tool's keys survive a reimport.
export class ImportExtra {
    section: string;
    key: string;
    // The value's text as it stood after `=` (a string with its quotes).
    raw: string;

    constructor(section: string, key: string, raw: string) {
        this.section = section;
        this.key = key;
        this.raw = raw;
    }
}

export class ImportFile {
    // [remap]
    importer: string = "";
    type: string = "";
    metaKeys: Array<string> = [];
    metaValues: Array<string> = [];
    // [deps]
    sourceFile: string = "";
    sourceHash: string = "";
    destFiles: Array<string> = [];
    // [params]
    params: ImportParams;
    // Keys of [remap] and [deps] this version does not know, in the order
    // read.
    extras: Array<ImportExtra> = [];

    constructor(importer: string) {
        this.importer = importer;
        this.type = importTypeOf(importer);
        this.params = ImportParams.defaults(importer);
    }

    meta(key: string): string? {
        for (let k = 0; k < this.metaKeys.length; k++) if (this.metaKeys[k] == key) return this.metaValues[k];
        return null;
    }

    setMeta(key: string, value: string): void {
        for (let k = 0; k < this.metaKeys.length; k++) {
            if (this.metaKeys[k] == key) {
                this.metaValues[k] = value;
                return;
            }
        }
        this.metaKeys.push(key);
        this.metaValues.push(value);
    }

    // A deep copy (the importer changes a copy, so a failed import leaves
    // the settings read as they were).
    clone(): ImportFile {
        const f = new ImportFile(this.importer);
        f.type = this.type;
        for (let k = 0; k < this.metaKeys.length; k++) {
            f.metaKeys.push(this.metaKeys[k]);
            f.metaValues.push(this.metaValues[k]);
        }
        f.sourceFile = this.sourceFile;
        f.sourceHash = this.sourceHash;
        for (let k = 0; k < this.destFiles.length; k++) f.destFiles.push(this.destFiles[k]);
        f.params = this.params.clone();
        for (let k = 0; k < this.extras.length; k++) {
            const e = this.extras[k];
            f.extras.push(new ImportExtra(e.section, e.key, e.raw));
        }
        return f;
    }
}

// ---------------------------------------------------------------------------
// Writing

// `s` as a ConfigFile string: quoted, `"` and `\` escaped (and the control
// characters a file name could hold, so the file stays one key a line).
export function quoteImportString(s: string): string {
    let out = "\"";
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c == 34) out += "\\\"";
        else if (c == 92) out += "\\\\";
        else if (c == 10) out += "\\n";
        else if (c == 9) out += "\\t";
        else if (c == 13) out += "\\r";
        else out += String.fromCharCode(c);
    }
    return out + "\"";
}

function writeExtras(f: ImportFile, section: string): string {
    let s = "";
    for (let k = 0; k < f.extras.length; k++) {
        const e = f.extras[k];
        if (e.section == section) s += e.key + "=" + e.raw + "\n";
    }
    return s;
}

// The canonical text of `f` (docs/formats/IMPORT.md, "The .import file"):
// [remap], [deps], [params], each header followed by one blank line, one
// blank line between sections, `key=value` without spaces, strings quoted,
// [params] in the importer's order (unknown keys last, as read), a final
// newline. The same file always gives the same bytes.
export function writeImportFile(f: ImportFile): string {
    let s = "[remap]\n\n";
    s += "importer=" + quoteImportString(f.importer) + "\n";
    s += "type=" + quoteImportString(f.type.length > 0 ? f.type : importTypeOf(f.importer)) + "\n";
    for (let k = 0; k < f.metaKeys.length; k++) s += "metadata/" + f.metaKeys[k] + "=" + f.metaValues[k] + "\n";
    s += writeExtras(f, "remap");
    s += "\n[deps]\n\n";
    s += "source_file=" + quoteImportString(f.sourceFile) + "\n";
    s += "source_hash=" + quoteImportString(f.sourceHash) + "\n";
    s += "dest_files=[";
    for (let k = 0; k < f.destFiles.length; k++) s += (k > 0 ? ", " : "") + quoteImportString(f.destFiles[k]);
    s += "]\n";
    s += writeExtras(f, "deps");
    s += "\n[params]\n\n";
    const p = f.params;
    // known keys in the definitions' order, whatever order they are held in
    const defs = paramDefsOf(f.importer);
    const done = new Set<string>();
    if (defs != null) {
        for (let d = 0; d < defs.length; d++) {
            const v = p.get(defs[d].key);
            if (v == null) continue;
            s += defs[d].key + "=" + v + "\n";
            done.add(defs[d].key);
        }
    }
    for (let k = 0; k < p.keys.length; k++) {
        if (done.has(p.keys[k])) continue;
        s += p.keys[k] + "=" + p.values[k] + "\n";
    }
    return s;
}

// ---------------------------------------------------------------------------
// Reading

const SECTIONS: StaticArray<string> = ["remap", "deps", "params"];

enum ValueShape {
    // A quoted string: `text` its content, unescaped.
    Str,
    // A list of strings: `items`.
    List,
    // Anything else (true, 2, 0.5, an identifier): `text` the token.
    Bare,
    // A Godot dictionary ({...}) or a list that is not strings alone: kept
    // whole, unread, as `raw` (and `text`), so it is written back as it was.
    Opaque,
}

class ParsedValue {
    shape: ValueShape = ValueShape.Bare;
    text: string = "";
    items: Array<string> = [];
    // The value as it stood after `=`, trimmed.
    raw: string = "";
    // Why it does not parse; "" when it does.
    error: string = "";
}

function isSpace(c: i32): bool {
    return c == 32 || c == 9;
}

// A string starting at `s[at]` (a `"`): its content, and where it ends
// (just past the closing quote) in `end[0]`; null with `err[0]` set when it
// is not one.
function readString(s: string, at: i32, end: Array<i32>, err: Array<string>): string? {
    let out = "";
    let i = at + 1;
    while (i < s.length) {
        const c = s.charCodeAt(i);
        if (c == 34) {
            end[0] = i + 1;
            return out;
        }
        if (c == 92) {
            if (i + 1 >= s.length) break;
            const e = s.charCodeAt(i + 1);
            if (e == 34) out += "\"";
            else if (e == 92) out += "\\";
            else if (e == 110) out += "\n";
            else if (e == 116) out += "\t";
            else if (e == 114) out += "\r";
            else {
                err[0] = "unknown escape \\" + String.fromCharCode(e) + " in a string (strings escape \\\" and \\\\)";
                return null;
            }
            i += 2;
            continue;
        }
        out += String.fromCharCode(c);
        i++;
    }
    err[0] = "a string with no closing quote";
    return null;
}

function parseValue(raw: string): ParsedValue {
    const v = new ParsedValue();
    v.raw = raw;
    const end: Array<i32> = [0];
    const err: Array<string> = [""];
    if (raw.length == 0) {
        v.error = "a key with no value";
        return v;
    }
    const c0 = raw.charCodeAt(0);
    if (c0 == 34) {
        const s = readString(raw, 0, end, err);
        if (s == null) {
            v.error = err[0];
            return v;
        }
        if (end[0] != raw.length) {
            v.error = "text after a string: '" + raw.substring(end[0]) + "'";
            return v;
        }
        v.shape = ValueShape.Str;
        v.text = s;
        return v;
    }
    if (c0 == 91) {
        v.shape = ValueShape.List;
        let i = 1;
        let expectItem = true;
        while (true) {
            while (i < raw.length && isSpace(raw.charCodeAt(i))) i++;
            if (i >= raw.length) {
                v.error = "a list with no closing ]";
                return v;
            }
            const c = raw.charCodeAt(i);
            if (c == 93) {
                if (expectItem && v.items.length > 0) {
                    v.error = "a list ending with a comma";
                    return v;
                }
                i++;
                break;
            }
            if (expectItem) {
                if (c != 34) {
                    v.error = "a list holds strings (\"...\"), not '" + raw.substring(i) + "'";
                    return v;
                }
                const s = readString(raw, i, end, err);
                if (s == null) {
                    v.error = err[0];
                    return v;
                }
                v.items.push(s);
                i = end[0];
                expectItem = false;
            } else {
                if (c != 44) {
                    v.error = "list items are separated by commas";
                    return v;
                }
                i++;
                expectItem = true;
            }
        }
        if (i != raw.length) {
            v.error = "text after a list: '" + raw.substring(i) + "'";
            return v;
        }
        return v;
    }
    for (let i = 0; i < raw.length; i++) {
        const c = raw.charCodeAt(i);
        if (isSpace(c) || c == 34 || c == 91 || c == 93 || c == 59) {
            v.error = "'" + raw + "' is not a value (a string is quoted: \"...\")";
            return v;
        }
    }
    v.text = raw;
    return v;
}

// How deep `s` leaves its {...} and [...] nesting, skipping over quoted
// strings (and their escapes): 0 when they balance. `depth` carries the
// depth from the lines before; a negative result means a stray closer.
function bracketDepth(s: string, depth: i32): i32 {
    let inString = false;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (inString) {
            if (c == 92) i++;
            else if (c == 34) inString = false;
            continue;
        }
        if (c == 34) inString = true;
        else if (c == 123 || c == 91) depth++;
        else if (c == 125 || c == 93) {
            depth--;
            if (depth < 0) return depth;
        }
    }
    return depth;
}

// A value that opens with { or [ and balances: Godot's dictionaries
// (`metadata={...}`, often spread over lines) and its non-string lists.
function opaqueValue(raw: string): ParsedValue? {
    if (raw.length < 2) return null;
    const c0 = raw.charCodeAt(0);
    const cl = raw.charCodeAt(raw.length - 1);
    if (!((c0 == 123 && cl == 125) || (c0 == 91 && cl == 93))) return null;
    if (bracketDepth(raw, 0) != 0) return null;
    const v = new ParsedValue();
    v.shape = ValueShape.Opaque;
    v.raw = raw;
    v.text = raw;
    return v;
}

class PendingParam {
    key: string;
    value: ParsedValue;
    line: i32;

    constructor(key: string, value: ParsedValue, line: i32) {
        this.key = key;
        this.value = value;
        this.line = line;
    }
}

// The importers quoted, "\"texture\", \"scene\", ... and \"flac\"" with `last`
// before the last.
function importerList(last: string): string {
    let s = "";
    for (let k = 0; k < IMPORTERS.length; k++) {
        if (k > 0) s += k == IMPORTERS.length - 1 ? last : ", ";
        s += "\"" + IMPORTERS[k] + "\"";
    }
    return s;
}

function lineError(what: string, line: i32, message: string): Result<ImportFile> {
    return Result.fail<ImportFile>(what + ":" + line.toString() + ": " + message);
}

// Reads an .import file (`what` names it in a failure: "<what>:<line>:
// <why>"). Godot's ConfigFile syntax, loosely: `;` comments and blank
// lines anywhere, spaces around `=` and at the ends of a line, sections and
// keys in any order (a section may come twice; a key may not), CRLF line
// ends. [remap] must name a known importer; [params] values are checked
// against that importer's settings (params.as) and canonicalised; keys
// this version does not know are kept. Anything else fails with its line.
export function parseImportFile(text: string, what: string): Result<ImportFile> {
    const lines = text.split("\n");
    let section = "";
    let remapLine = 0;
    let importer: string? = null;
    let importerLine = 0;
    let type: string? = null;
    const metaKeys = new Array<string>();
    const metaValues = new Array<string>();
    let sourceFile = "";
    let sourceHash = "";
    const destFiles = new Array<string>();
    const extras = new Array<ImportExtra>();
    const params = new Array<PendingParam>();
    const seen = new Set<string>();
    for (let n = 0; n < lines.length; n++) {
        const line = n + 1;
        let l = lines[n];
        if (l.endsWith("\r")) l = l.substring(0, l.length - 1);
        l = l.trim();
        if (l.length == 0 || l.startsWith(";")) continue;
        if (l.startsWith("[")) {
            if (!l.endsWith("]")) return lineError(what, line, "a section header is [name], not '" + l + "'");
            const name = l.substring(1, l.length - 1).trim();
            if (!SECTIONS.includes(name)) {
                return lineError(what, line, "unknown section [" + name + "] (an .import file has [remap], [deps] and [params])");
            }
            section = name;
            if (name == "remap" && remapLine == 0) remapLine = line;
            continue;
        }
        const eq = l.indexOf("=");
        if (eq < 0) return lineError(what, line, "'" + l + "' is not a key=value line, a [section] or a ; comment");
        const key = l.substring(0, eq).trim();
        if (key.length == 0) return lineError(what, line, "a value with no key: '" + l + "'");
        for (let i = 0; i < key.length; i++) {
            if (isSpace(key.charCodeAt(i))) return lineError(what, line, "a key has no spaces: '" + key + "'");
        }
        if (section.length == 0) return lineError(what, line, "'" + key + "' comes before any section ([remap], [deps], [params])");
        const full = section + "/" + key;
        if (seen.has(full)) return lineError(what, line, key + " is set twice in [" + section + "]");
        seen.add(full);
        let rest = l.substring(eq + 1).trim();
        // Godot spreads a dictionary over lines (`metadata={` ... `}`): a
        // value that opens a bracket it does not close takes the lines up
        // to the one that closes it, newlines kept. A dictionary left open
        // to the end of the file fails at its first line; a list is read as
        // the single line, and fails there.
        if (rest.startsWith("{") || rest.startsWith("[")) {
            let depth = bracketDepth(rest, 0);
            if (depth > 0) {
                let joined = rest;
                let m = n + 1;
                for (; m < lines.length && depth > 0; m++) {
                    let next = lines[m];
                    if (next.endsWith("\r")) next = next.substring(0, next.length - 1);
                    joined += "\n" + next;
                    depth = bracketDepth(next, depth);
                }
                if (depth == 0) {
                    rest = joined.trimEnd();
                    n = m - 1;
                } else if (rest.startsWith("{")) {
                    return lineError(what, line, key + ": a dictionary ({...}) with no closing }");
                }
            }
        }
        let v = parseValue(rest);
        // A dictionary, or a balanced list that is not strings alone, is
        // kept whole; dest_files is read, so its own errors stand.
        if (v.error.length > 0 && !(section == "deps" && key == "dest_files")) {
            const o = opaqueValue(rest);
            if (o != null) v = o;
        }
        if (v.error.length > 0) return lineError(what, line, key + ": " + v.error);
        if (section == "remap") {
            if (key == "importer" || key == "type") {
                if (v.shape != ValueShape.Str) return lineError(what, line, key + " is a string (\"...\"), not " + v.raw);
                if (key == "importer") {
                    importer = v.text;
                    importerLine = line;
                } else {
                    type = v.text;
                }
            } else if (key.startsWith("metadata/") && key.length > 9) {
                metaKeys.push(key.substring(9));
                metaValues.push(v.raw);
            } else {
                extras.push(new ImportExtra(section, key, v.raw));
            }
        } else if (section == "deps") {
            if (key == "source_file" || key == "source_hash") {
                if (v.shape != ValueShape.Str) return lineError(what, line, key + " is a string (\"...\"), not " + v.raw);
                if (key == "source_file") sourceFile = v.text;
                else sourceHash = v.text;
            } else if (key == "dest_files") {
                if (v.shape != ValueShape.List) {
                    return lineError(what, line, "dest_files is a list of strings ([\"build/cache/import/...\", ...]), not " + v.raw);
                }
                for (let i = 0; i < v.items.length; i++) destFiles.push(v.items[i]);
            } else {
                extras.push(new ImportExtra(section, key, v.raw));
            }
        } else {
            params.push(new PendingParam(key, v, line));
        }
    }
    if (importer == null) {
        return lineError(what, remapLine > 0 ? remapLine : 1, "no importer: [remap] names it (importer=" + importerList(" or ") + ")");
    }
    const imp = importer!;
    const defs = paramDefsOf(imp);
    if (defs == null) {
        return lineError(what, importerLine, "unknown importer '" + imp + "' (Hedra's are " + importerList(" and ") + ")");
    }
    const f = new ImportFile(imp);
    if (type != null) f.type = type!;
    f.metaKeys = metaKeys;
    f.metaValues = metaValues;
    f.sourceFile = sourceFile;
    f.sourceHash = sourceHash;
    f.destFiles = destFiles;
    f.extras = extras;
    for (let k = 0; k < params.length; k++) {
        const pp = params[k];
        const d = findDef(defs, pp.key);
        if (d == null) {
            // kept as read, written back after the known ones
            f.params.keys.push(pp.key);
            f.params.values.push(pp.value.raw);
            continue;
        }
        if (pp.value.shape == ValueShape.List || pp.value.shape == ValueShape.Opaque) {
            return lineError(what, pp.line, pp.key + " is not a list or a dictionary");
        }
        const c = canonicalValue(d, pp.value.text);
        if (!c.ok) return lineError(what, pp.line, c.err);
        const r = f.params.set(pp.key, c.value);
        if (!r.ok) return lineError(what, pp.line, r.err);
    }
    return Result.okv<ImportFile>(f);
}
