// What the CLI's `build`, the CLI's `inspect --check` and a loaded scene's
// warnings (warnings.as) need to know of a node script without compiling
// it: its class (the first `class <Name> extends NodeScript`, as the loader
// finds it: engine/src/scene/resource/loader.as scriptClassOf), the
// class's exported properties, and the files it imports.
//
// An exported property (engine/src/scene/script.as) is a public instance
// field of that class, declared at the top level of its body, one per line:
//
//   speed: f32 = 0.5;
//   public label: string = "";
//
// whose type is one of EXPORT_TYPES. `static`, `private`, `protected` and
// `readonly` fields, methods, accessors and fields of other types are not
// exported. Comments and string literals are skipped, so a brace or a
// declaration inside them counts for nothing.

// (Milestone 7 moved this module here from editor/program/src/build/
// script_scan.as, which re-exports it: the scene editor reports a scene's
// warnings as the CLI does.)

import { dirOf, scriptClassOf } from "../../scene/resource/loader";

// The types an exported property may have, as a script declares them.
export const EXPORT_TYPES: Array<string> = ["f32", "f64", "i32", "i64", "u32", "bool", "string", "Vec2", "Vec3", "Vec4"];

export class ScriptField {
    name: string;
    // One of EXPORT_TYPES.
    type: string;
    // 1-based, in the script's source.
    line: i32;

    constructor(name: string, type: string, line: i32) {
        this.name = name;
        this.type = type;
        this.line = line;
    }
}

export class ScriptScan {
    // The class that extends NodeScript, or null.
    className: string? = null;
    // Its exported properties, in declaration order.
    fields: Array<ScriptField> = [];
    // Every module the file imports or re-exports from, as written
    // ("hedra_engine/script", "./util"), in source order, each once.
    imports: Array<string> = [];

    // The exported property `name`, or null.
    field(name: string): ScriptField? {
        for (let i = 0; i < this.fields.length; i++) if (this.fields[i].name == name) return this.fields[i];
        return null;
    }
}

function isIdentStart(c: i32): bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36;
}

function isIdent(c: i32): bool {
    return isIdentStart(c) || (c >= 48 && c <= 57);
}

// `src` with every comment replaced by spaces and every string literal's
// contents by `x` (quotes kept, line ends kept), so positions and lines are
// unchanged and neither can open a brace or a declaration.
export function blankCommentsAndStrings(src: string): string {
    const out = new Array<string>();
    const n = src.length;
    let i = 0;
    while (i < n) {
        const c = src.charCodeAt(i);
        if (c == 47 && i + 1 < n && src.charCodeAt(i + 1) == 47) {
            while (i < n && src.charCodeAt(i) != 10) {
                out.push(" ");
                i++;
            }
        } else if (c == 47 && i + 1 < n && src.charCodeAt(i + 1) == 42) {
            out.push("  ");
            i += 2;
            while (i < n && !(src.charCodeAt(i) == 42 && i + 1 < n && src.charCodeAt(i + 1) == 47)) {
                out.push(src.charCodeAt(i) == 10 ? "\n" : " ");
                i++;
            }
            if (i < n) {
                out.push("  ");
                i += 2;
            }
        } else if (c == 34 || c == 39 || c == 96) {
            out.push(String.fromCharCode(c));
            i++;
            while (i < n && src.charCodeAt(i) != c) {
                const d = src.charCodeAt(i);
                if (d == 92 && i + 1 < n) {
                    out.push("xx");
                    i += 2;
                    continue;
                }
                if (d == 10 && c != 96) break;
                out.push(d == 10 ? "\n" : "x");
                i++;
            }
            if (i < n && src.charCodeAt(i) == c) {
                out.push(String.fromCharCode(c));
                i++;
            }
        } else {
            out.push(String.fromCharCode(c));
            i++;
        }
    }
    return out.join("");
}

// The import specifiers of `src` (`import ... from "X"`, `export ... from
// "X"`, `import "X"`), read from the original text at the positions the
// blanked text shows are code.
function importsOf(src: string, blank: string): Array<string> {
    const out = new Array<string>();
    let from = 0;
    while (true) {
        const a = blank.indexOf("import", from);
        const b = blank.indexOf("from", from);
        let at: i32;
        let kw: i32;
        if (a < 0 && b < 0) break;
        if (a >= 0 && (b < 0 || a < b)) {
            at = a;
            kw = 6;
        } else {
            at = b;
            kw = 4;
        }
        from = at + kw;
        if (at > 0 && isIdent(blank.charCodeAt(at - 1))) continue;
        if (at + kw < blank.length && isIdent(blank.charCodeAt(at + kw))) continue;
        let j = at + kw;
        while (j < blank.length && (blank.charCodeAt(j) == 32 || blank.charCodeAt(j) == 9 || blank.charCodeAt(j) == 10 || blank.charCodeAt(j) == 13)) j++;
        if (j >= blank.length) break;
        const q = blank.charCodeAt(j);
        if (q != 34 && q != 39) continue;
        const end = src.indexOf(String.fromCharCode(q), j + 1);
        if (end < 0) break;
        const spec = src.substring(j + 1, end);
        if (!out.includes(spec)) out.push(spec);
        from = end + 1;
    }
    return out;
}

// Where the body of `class <name>` starts (the index after its `{`), or -1.
function classBody(blank: string, name: string): i32 {
    let from = 0;
    while (true) {
        const at = blank.indexOf("class", from);
        if (at < 0) return -1;
        from = at + 5;
        if (at > 0 && isIdent(blank.charCodeAt(at - 1))) continue;
        let j = at + 5;
        while (j < blank.length && (blank.charCodeAt(j) == 32 || blank.charCodeAt(j) == 9)) j++;
        if (!blank.startsWith(name, j)) continue;
        const e = j + name.length;
        if (e < blank.length && isIdent(blank.charCodeAt(e))) continue;
        const brace = blank.indexOf("{", e);
        return brace < 0 ? -1 : brace + 1;
    }
}

// A top-level field declaration at the start of `line` (leading blanks
// allowed): [public] <name>: <type> followed by `=`, `;` or the line's end.
// Returns [name, type] or null.
function fieldOf(line: string): Array<string>? {
    let i = 0;
    const n = line.length;
    while (i < n && (line.charCodeAt(i) == 32 || line.charCodeAt(i) == 9)) i++;
    if (line.startsWith("public", i) && i + 6 < n && !isIdent(line.charCodeAt(i + 6))) {
        i += 6;
        while (i < n && (line.charCodeAt(i) == 32 || line.charCodeAt(i) == 9)) i++;
    }
    if (i >= n || !isIdentStart(line.charCodeAt(i))) return null;
    const ns = i;
    while (i < n && isIdent(line.charCodeAt(i))) i++;
    const name = line.substring(ns, i);
    if (name == "static" || name == "private" || name == "protected" || name == "readonly" || name == "get"
        || name == "set" || name == "constructor" || name == "override" || name == "public") return null;
    while (i < n && (line.charCodeAt(i) == 32 || line.charCodeAt(i) == 9)) i++;
    if (i >= n || line.charCodeAt(i) != 58) return null;
    i++;
    while (i < n && (line.charCodeAt(i) == 32 || line.charCodeAt(i) == 9)) i++;
    const ts = i;
    while (i < n && isIdent(line.charCodeAt(i))) i++;
    if (i == ts) return null;
    const type = line.substring(ts, i);
    while (i < n && (line.charCodeAt(i) == 32 || line.charCodeAt(i) == 9 || line.charCodeAt(i) == 13)) i++;
    if (i < n && line.charCodeAt(i) != 61 && line.charCodeAt(i) != 59) return null;
    return [name, type];
}

// Scans a script's source (see the header).
export function scanScript(src: string): ScriptScan {
    const s = new ScriptScan();
    const blank = blankCommentsAndStrings(src);
    s.imports = importsOf(src, blank);
    const name = scriptClassOf(blank);
    s.className = name;
    if (name == null) return s;
    const start = classBody(blank, name);
    if (start < 0) return s;
    // Walk the body line by line at depth 1 (the class's own braces) and
    // outside parentheses: a method's parameters split over several lines
    // (`turn(\n angle: f32,\n scale: f32\n): void {`) read like fields
    // otherwise, and the last one, with no comma, would be exported.
    let line = 1;
    for (let k = 0; k < start; k++) if (blank.charCodeAt(k) == 10) line++;
    let depth = 1;
    let i = start;
    let lineStart = start;
    let lineDepth = 1;
    let paren = 0;
    let lineParen = 0;
    while (i <= blank.length && depth > 0) {
        const c = i < blank.length ? blank.charCodeAt(i) : 10;
        if (c == 10) {
            if (lineDepth == 1 && lineParen == 0) {
                const f = fieldOf(blank.substring(lineStart, i));
                if (f != null && EXPORT_TYPES.includes(f[1]) && s.field(f[0]) == null) {
                    s.fields.push(new ScriptField(f[0], f[1], line));
                }
            }
            line++;
            lineStart = i + 1;
            lineDepth = depth;
            lineParen = paren;
        } else if (c == 40) {
            paren++;
        } else if (c == 41) {
            if (paren > 0) paren--;
        } else if (c == 123) {
            depth++;
        } else if (c == 125) {
            depth--;
        }
        i++;
    }
    return s;
}

// The absolute path a relative import names from the file `fromAbs` ("./a",
// "../lib/b.as": `.as` added when missing), or "" when it climbs above "/":
// editor/program/src/build/pack.as importPath's rule, which the bundle
// writer follows to find the scenes a script's helpers load.
export function relativeImportPath(fromAbs: string, spec: string): string {
    const parts = new Array<string>();
    const base = dirOf(fromAbs).split("/");
    for (let i = 0; i < base.length; i++) if (base[i].length > 0) parts.push(base[i]);
    const rel = spec.split("/");
    for (let i = 0; i < rel.length; i++) {
        const p = rel[i];
        if (p.length == 0 || p == ".") continue;
        if (p == "..") {
            if (parts.length == 0) return "";
            parts.pop();
            continue;
        }
        parts.push(p);
    }
    const abs = "/" + parts.join("/");
    return abs.endsWith(".as") ? abs : abs + ".as";
}
