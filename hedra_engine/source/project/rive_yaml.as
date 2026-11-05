// A Rive project's rive.yaml as Hedra's tools read it (rive's docs/
// project/rive-yaml.md), and the matching of its `exclude:` list as rive's
// own scan matches it (rive-cli's project_scan.cpp), so that what the tools
// take for the project's files is what `rive` compiles: Build's checks
// (editor/program/src/build/rive/locate.as, which re-exports these), the
// project's data (./project.as, every .rml rive compiles) and the scene
// editor's Build status (editor/src/scene/build_status.as, which
// counts and marks the scenes Build builds and no others).
//
// Only what the tools need is read: the name, `scripting`, `wasmRuntime`,
// `exclude:` and `output: dir:`. Anything else is left alone.

// What rive.yaml says that the tools read.
export class RiveYaml {
    name: string? = null;
    scripting: string? = null;
    wasmRuntime: string? = null;
    exclude: Array<string> = [];
    // `output: dir:`, where rive writes the .riv (rive excludes it from its
    // scan as though `exclude:` listed it); "build" when unset.
    outputDir: string = "build";
}

// A YAML scalar as written on one line: its comment dropped, its quotes
// removed.
function scalar(text: string): string {
    let s = text.trim();
    if (s.startsWith("#")) return "";
    const quoted = s.startsWith("\"") || s.startsWith("'");
    // (a quoted value may hold " #"; its comment follows the closing quote)
    const close = quoted ? s.indexOf(s.charAt(0), 1) : -1;
    const hash = s.indexOf(" #", close >= 0 ? close : 0);
    if (hash >= 0) s = s.substring(0, hash).trim();
    if (s.length >= 2 && (s.startsWith("\"") && s.endsWith("\"") || s.startsWith("'") && s.endsWith("'"))) {
        return s.substring(1, s.length - 1);
    }
    return s;
}

// The settings of rive.yaml's text that the tools read: top-level `key:
// value` lines, the items of a top-level `exclude:` list (block form,
// `- item` lines, or flow form `[a, b]`) and `dir:` under a top-level
// `output:`. Anything else is left alone.
export function parseRiveYaml(text: string): RiveYaml {
    const y = new RiveYaml();
    const lines = text.split("\n");
    let inExclude = false;
    let inOutput = false;
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i];
        if (line.endsWith("\r")) line = line.substring(0, line.length - 1);
        const t = line.trim();
        if (t.length == 0 || t.startsWith("#")) continue;
        const indented = line.charCodeAt(0) == 32 || line.charCodeAt(0) == 9;
        if (indented || t.startsWith("- ") || t == "-") {
            if (inExclude && t.startsWith("-")) {
                const item = scalar(t.substring(1));
                if (item.length > 0) y.exclude.push(item);
            } else if (inOutput && indented) {
                const colon = t.indexOf(":");
                if (colon > 0 && t.substring(0, colon).trim() == "dir") {
                    const dir = scalar(t.substring(colon + 1));
                    if (dir.length > 0) y.outputDir = dir;
                }
            }
            continue;
        }
        inExclude = false;
        inOutput = false;
        const colon = t.indexOf(":");
        if (colon <= 0) continue;
        const key = t.substring(0, colon).trim();
        const value = scalar(t.substring(colon + 1));
        if (key == "name") y.name = value;
        else if (key == "scripting") y.scripting = value;
        else if (key == "wasmRuntime") y.wasmRuntime = value;
        else if (key == "output") inOutput = value.length == 0;
        else if (key == "exclude") {
            if (value.startsWith("[")) {
                const inner = value.substring(1, value.endsWith("]") ? value.length - 1 : value.length);
                const items = inner.split(",");
                for (let k = 0; k < items.length; k++) {
                    const item = scalar(items[k]);
                    if (item.length > 0) y.exclude.push(item);
                }
            } else {
                inExclude = true;
            }
        }
    }
    return y;
}

// Whether `pattern` (git's glob: `*` any run of characters but `/`, `**`
// any run at all, `?` one character but `/`) matches the whole of `path`.
// The .gitignore lines are matched so (Build); rive.yaml's exclude: is not
// (riveGlobMatch).
export function globMatch(pattern: string, path: string): bool {
    return globAt(pattern, 0, path, 0);
}

function globAt(p: string, i: i32, s: string, j: i32): bool {
    while (i < p.length) {
        const c = p.charCodeAt(i);
        if (c == 42) {
            const double = i + 1 < p.length && p.charCodeAt(i + 1) == 42;
            let next = i + (double ? 2 : 1);
            // ("**/" also matches no folder at all)
            if (double && next < p.length && p.charCodeAt(next) == 47 && globAt(p, next + 1, s, j)) return true;
            for (let k = j; k <= s.length; k++) {
                if (globAt(p, next, s, k)) return true;
                if (k < s.length && !double && s.charCodeAt(k) == 47) return false;
            }
            return false;
        }
        if (j >= s.length) return false;
        const d = s.charCodeAt(j);
        if (c == 63) {
            if (d == 47) return false;
        } else if (c != d) {
            return false;
        }
        i++;
        j++;
    }
    return j == s.length;
}

// Whether `pattern` matches the whole of `text` as rive matches an
// exclude: item (rive-cli's rml/src/glob.cpp globMatch): `*` any run of
// characters, `/` included, `?` any one character, nothing else special.
export function riveGlobMatch(pattern: string, text: string): bool {
    let p = 0;
    let t = 0;
    let star = -1;
    let mark = 0;
    while (t < text.length) {
        if (p < pattern.length && (pattern.charCodeAt(p) == 63 || pattern.charCodeAt(p) == text.charCodeAt(t))) {
            p++;
            t++;
        } else if (p < pattern.length && pattern.charCodeAt(p) == 42) {
            star = p++;
            mark = t;
        } else if (star >= 0) {
            // (the last `*` swallows one more character)
            p = star + 1;
            t = ++mark;
        } else {
            return false;
        }
    }
    while (p < pattern.length && pattern.charCodeAt(p) == 42) p++;
    return p == pattern.length;
}

// Whether every file under the folder `rivePath` is excluded (isExcluded
// of each would answer true), so that a search of the project's files
// need not walk it: the folder excluded whole, or an item ending in `*`
// that matches "<folder>/", whose last `*` then takes any rest of a path
// under it. "*/build/*" so leaves out world/build/ and everything below it
// (rive walks such a folder and excludes each of its files: the same files
// found). Milestone 67: the tools' compiles write folders under a Hedra
// project's build/, and a scene drawn after them walked each one a run.
export function excludesAllUnder(rivePath: string, exclude: Array<string>): bool {
    if (isExcluded(rivePath, exclude, true)) return true;
    const dir = rivePath + "/";
    for (let i = 0; i < exclude.length; i++) {
        const p = exclude[i];
        if (p.length > 0 && p.charCodeAt(p.length - 1) == 42 && riveGlobMatch(p, dir)) return true;
    }
    return false;
}

// Whether `rivePath` (a path in the Rive project; `dir`: a folder's) is
// excluded, as rive's scan decides it (rive-cli's project_scan.cpp
// isExcludedPath): an item is taken as written (no "./" or "/" dropped); it
// excludes the path it equals and every path under it; a folder is left out
// whole only when the item is exactly "<folder>/*", while any other glob is
// tried on each file's path. So "*/build/*" leaves out every file under a
// nested build/ (its folders are walked, their files excluded), and
// "*/build" leaves out nothing below one.
export function isExcluded(rivePath: string, exclude: Array<string>, dir: bool = false): bool {
    for (let i = 0; i < exclude.length; i++) {
        const p = exclude[i];
        if (p.length == 0) continue;
        if (p == rivePath) return true;
        if (rivePath.length > p.length && rivePath.charCodeAt(p.length) == 47 && rivePath.startsWith(p)) return true;
        if (dir) {
            if (p == rivePath + "/*") return true;
        } else if (riveGlobMatch(p, rivePath)) {
            return true;
        }
    }
    return false;
}
