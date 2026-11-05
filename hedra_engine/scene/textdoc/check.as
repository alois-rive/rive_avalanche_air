// What the validators of Hedra's XML documents share (the .rscn validator,
// ../rscn/validate.as, and the .rmdl reader, engine/src/source/model/rmdl/
// elements.as): the rule for resource ids, the rules for an ext_resource's
// path (each format says which forms it accepts: PathRules), and a file
// extension against a type's list. The messages are the .rscn validator's,
// word for word, so that one problem reads the same in either file.

import { toAsciiLowercase } from "../../base/util";

// How an id is written, for the hint of id-invalid.
export const ID_HINT = "an id is letters, digits, _ and -, such as \"1_lamp\"";

// Letters, digits, `_` and `-`: an id survives every attribute and literal
// unescaped, and reads the same in any tool.
export function isValidId(id: string): bool {
    if (id.length == 0) return false;
    for (let i = 0; i < id.length; i++) {
        const c = id.charCodeAt(i);
        const ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 45;
        if (!ok) return false;
    }
    return true;
}

// Why `id` is not an id (id-invalid's message; `kind` names the element:
// "ext_resource", "sub_resource"), or "" when it is one.
export function idProblem(id: string, kind: string): string {
    if (id.length == 0) return "the " + kind + "'s id is empty";
    if (!isValidId(id)) return "id \"" + id + "\" is not valid";
    return "";
}

// Which spellings of a path a format accepts in an ext_resource:
// `res://<path>` from the project's root (a scene's), a path relative to
// the file (both formats'), an absolute path (a model's, which names files
// on the machine that made it: a warning there, path-absolute).
export class PathRules {
    allowRes: bool = true;
    allowAbsolute: bool = false;
    allowRelative: bool = true;

    static of(allowRes: bool, allowAbsolute: bool, allowRelative: bool): PathRules {
        const r = new PathRules();
        r.allowRes = allowRes;
        r.allowAbsolute = allowAbsolute;
        r.allowRelative = allowRelative;
        return r;
    }
}

// A scene's rules: res:// or relative.
export const SCENE_PATHS: PathRules = PathRules.of(true, false, true);
// A model's rules: relative to the model's directory, or absolute.
export const MODEL_PATHS: PathRules = PathRules.of(false, true, true);

// Whether `path` is absolute: `/...`, or a drive (`C:...`).
export function isAbsolutePath(path: string): bool {
    return path.startsWith("/") || (path.length >= 2 && path.charCodeAt(1) == 58);
}

// Why an ext_resource path can never name a file under `rules`, or ""
// (whether it exists is the loader's to find). The wording is the scene
// loader's (../resource/loader.as, resolve).
export function resourcePathProblem(ref: string, rules: PathRules): string {
    if (ref.length == 0) return "the path is empty";
    if (ref.includes("\\")) return "\"" + ref + "\" has a backslash";
    let rel = ref;
    if (ref.startsWith("res://")) {
        if (!rules.allowRes) return "\"" + ref + "\" is a res:// path";
        rel = ref.substring(6);
    } else if (ref.includes("://")) {
        return "\"" + ref + "\" is not " + pathForms(rules);
    } else if (isAbsolutePath(ref)) {
        if (!rules.allowAbsolute) return "\"" + ref + "\" is not " + pathForms(rules);
    } else if (!rules.allowRelative) {
        return "\"" + ref + "\" is not " + pathForms(rules);
    }
    if (rel.length == 0 || rel.endsWith("/")) return "\"" + ref + "\" names a directory";
    return "";
}

// "a res:// or relative path", "a relative or absolute path".
function pathForms(rules: PathRules): string {
    const forms: Array<string> = [];
    if (rules.allowRes) forms.push("res://");
    if (rules.allowRelative) forms.push("relative");
    if (rules.allowAbsolute) forms.push("absolute");
    if (forms.length == 0) return "a path this format reads";
    if (forms.length == 1) return "a " + forms[0] + " path";
    return "a " + forms.slice(0, forms.length - 1).join(", ") + " or " + forms[forms.length - 1] + " path";
}

// The file extension of a path (without the dot, as written), "" when its
// last segment has none.
export function pathExtensionOf(path: string): string {
    const slash = path.lastIndexOf("/");
    const base = slash >= 0 ? path.substring(slash + 1) : path;
    const dot = base.lastIndexOf(".");
    return dot > 0 ? base.substring(dot + 1) : "";
}

// Whether the extension of `path` is one of `exts` (lowercase, without
// the dot), in any case.
export function extensionAccepted(exts: Array<string>, path: string): bool {
    return exts.includes(toAsciiLowercase(pathExtensionOf(path)));
}
