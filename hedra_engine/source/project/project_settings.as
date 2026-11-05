// The project's settings in hedra.yaml (milestone 27), Godot's
// project.godot: until now an empty file marking the project's root
// (resource/loader.as PROJECT_FILE), it may hold one setting a line,
// `key: value`. The one this milestone reads is Godot's
// application/run/main_scene:
//
//   main_scene: res://game.rscn
//
// which Play (F5 in the scene editor, the CLI's `play <project dir>`) runs.
// Comments (`#` to the end of the line), blank lines and keys this version
// does not know are kept as they are when a setting is written, so a newer
// file survives an older tool, as an .rscn does. A value may be quoted
// ("..." or '...'); it is written unquoted when it needs no quotes.

// The key of the main scene.
export const MAIN_SCENE_KEY = "main_scene";

// The value of `key` in the settings `text`, or null when it is not set
// (or set to nothing).
export function projectSetting(text: string, key: string): string? {
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
        const v = valueOf(lines[i], key);
        if (v != null) return v.length > 0 ? v : null;
    }
    return null;
}

// The main scene the settings `text` name (a res:// path as written), or
// null.
export function mainSceneOf(text: string): string? {
    return projectSetting(text, MAIN_SCENE_KEY);
}

// `text` with `key` set to `value` (its first line replaced in place, else
// a line appended); every other line as it was. `value` null removes the
// setting's lines.
export function withProjectSetting(text: string, key: string, value: string?): string {
    const lines = text.split("\n");
    // (a file ending with a line feed splits into a last empty line)
    const trailing = lines.length > 0 && lines[lines.length - 1].length == 0;
    if (trailing) lines.pop();
    const out = new Array<string>();
    let done = false;
    for (let i = 0; i < lines.length; i++) {
        if (valueOf(lines[i], key) == null) {
            out.push(lines[i]);
            continue;
        }
        if (value == null || done) continue;
        out.push(key + ": " + quoted(value));
        done = true;
    }
    if (value != null && !done) out.push(key + ": " + quoted(value));
    return out.length == 0 ? "" : out.join("\n") + "\n";
}

// The value of `key` on `line`, or null when the line does not set it.
function valueOf(line: string, key: string): string? {
    const s = stripComment(line).trim();
    if (!s.startsWith(key)) return null;
    const rest = s.substring(key.length).trimStart();
    if (!rest.startsWith(":")) return null;
    return unquoted(rest.substring(1).trim());
}

// `line` up to a `#` that is not inside quotes (a `\"` inside double
// quotes does not end them).
function stripComment(line: string): string {
    let q = 0;
    for (let i = 0; i < line.length; i++) {
        const c = line.charCodeAt(i);
        if (q != 0) {
            if (q == 34 && c == 92) i++;
            else if (c == q) q = 0;
        } else if (c == 34 || c == 39) {
            q = c;
        } else if (c == 35) {
            return line.substring(0, i);
        }
    }
    return line;
}

// A scalar's value: YAML's quoting undone (`\"` and `\\` in double quotes,
// `''` in single quotes), so what `quoted` wrote reads back as it was.
function unquoted(v: string): string {
    if (v.length < 2) return v;
    const a = v.charCodeAt(0);
    if ((a != 34 && a != 39) || v.charCodeAt(v.length - 1) != a) return v;
    const body = v.substring(1, v.length - 1);
    if (a == 39) return body.replaceAll("''", "'");
    if (body.indexOf("\\") < 0) return body;
    let out = "";
    for (let i = 0; i < body.length; i++) {
        let c = body.charCodeAt(i);
        if (c == 92 && i + 1 < body.length) c = body.charCodeAt(++i);
        out += String.fromCharCode(c);
    }
    return out;
}

// `v` as a YAML scalar: as it is when plain, else in double quotes with
// `"` and `\` escaped.
function quoted(v: string): string {
    let plain = v.length > 0;
    for (let i = 0; i < v.length && plain; i++) {
        const c = v.charCodeAt(i);
        plain = c > 32 && c != 34 && c != 39 && c != 35 && c != 92 && c < 127;
    }
    return plain ? v : "\"" + v.replaceAll("\\", "\\\\").replaceAll("\"", "\\\"") + "\"";
}
