// The files an .rmdl names, without building its scene: what the
// prefetchers ask the host for ahead of a load, the closure of a project,
// and a pack's dependencies. A document names files only through its
// ext_resources, which come before everything but its metadata; each path
// is as written: relative to the model's directory, or absolute.
//
// Like the .rscn's head (../../../scene/rscn/parse.as parseRscnHead), only
// the text up to the first element after the ext_resources is read: the
// meshes after them, megabytes of numbers, are not even decoded as XML.

import { XmlDocument, XmlKind, parseXmlHead } from "../../../base/xml";
import { RMDL_ROOT } from "./format";

// The ext_resource types a load reads (schema.as EXT_TYPES but Model).
const LOADED_TYPES: Array<string> = ["Texture2D", "Material", "PackedScene", "Shader"];

// The elements the head reads, and those that end it.
const HEAD: Array<string> = ["meta", "ext_resource"];
const AFTER_HEAD: Array<string> = ["sub_resource", "scene", "object", "pose_clip", "import"];

// The index of the first `<name` (a name of AFTER_HEAD, then a character
// no name holds) in `text`, or -1.
function headEnd(text: string): i32 {
    let from = 0;
    while (true) {
        const k = text.indexOf("<", from);
        if (k < 0) return -1;
        for (let j = 0; j < AFTER_HEAD.length; j++) {
            const name = AFTER_HEAD[j];
            const e = k + 1 + name.length;
            if (e >= text.length) continue;
            if (text.substr(k + 1, name.length) != name) continue;
            const c = text.charCodeAt(e);
            if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x2F || c == 0x3E) return k;
        }
        from = k + 1;
    }
}

function bytesOf(s: string): Uint8Array {
    return Uint8Array.wrap(String.UTF8.encode(s));
}

// The document's head, or null when the text is no document this build
// reads (a command file, not XML, another root).
function head(text: string): XmlDocument? {
    // Only the text up to (and just into) the first element after the head
    // is encoded and read; should that cut fall inside a comment, say, the
    // whole text is read.
    const end = headEnd(text);
    let r = parseXmlHead(bytesOf(end >= 0 ? text.substring(0, min(text.length, end + 16)) : text), "rmdl", HEAD, AFTER_HEAD);
    if (!r.ok && end >= 0) r = parseXmlHead(bytesOf(text), "rmdl", HEAD, AFTER_HEAD);
    if (!r.ok || r.value.root.name != RMDL_ROOT) return null;
    return r.value;
}

// The ext_resources' paths, those a load reads only (`loadedOnly`: every
// type but Model) or of one type (`only`), or all, in file order, each
// once.
function paths(text: string, loadedOnly: bool, only: string = ""): Array<string> {
    const out: Array<string> = [];
    const x = head(text);
    if (x == null) return out;
    const cs = x.root.children;
    for (let i = 0; i < cs.length; i++) {
        const c = cs[i];
        if (c.kind != XmlKind.Element || c.name != "ext_resource") continue;
        const p = c.attr("path");
        const t = c.attr("type");
        if (p == null || p.length == 0) continue;
        if (loadedOnly && (t == null || !LOADED_TYPES.includes(t))) continue;
        if (only.length > 0 && (t == null || t != only)) continue;
        if (!out.includes(p)) out.push(p);
    }
    return out;
}

// Every ext_resource path of the document, in file order, each once; []
// when the text is no document this build reads.
export function rmdlReferencedPaths(text: string): Array<string> {
    return paths(text, false);
}

// The ext_resource paths a load reads: the textures, the MaterialX files
// and the instanced models (not an import's source, which only records
// where geometry came from).
export function rmdlLoadedPaths(text: string): Array<string> {
    return paths(text, true);
}

// The models the document's empties instance (its PackedScene
// ext_resources), as written.
export function rmdlInstancedPaths(text: string): Array<string> {
    return paths(text, false, "PackedScene");
}
