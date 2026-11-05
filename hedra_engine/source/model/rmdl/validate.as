// Every problem of an .rmdl, for `hedra check` and the editors: the
// structural checks collected in source order (as .rscn's validator
// collects them: elements.as), then the model's own (the first value that
// does not fit the model stops the build of the scene, as a load does:
// rmdl-invalid), then the warnings of the read, each comment and
// processing instruction among them (W_RMDL_DROPPED: the model holds
// none, so a rewrite drops it, and `hedra format` refuses to without
// --force). With `dir`, it also looks at the files the document names:
// each texture, MaterialX file and instanced model must be a file there (a
// missing one is `file-read`, as a missing ext_resource of an .rscn is,
// since the model's renders and every scene placing it read it), an
// instance must not lead back to the document (`instance-cycle`, .rscn's
// code, followed through the instanced .rmdl and .rmdlcmd files), and each
// import's source must still hash as recorded (W_RMDL_IMPORT_CHANGED).

import { XmlDocument, XmlKind, XmlNode, parseXml } from "../../../base/xml";
import { Diagnostic, Diagnostics, Severity } from "../../../scene/error";
import { ExtResourceDecl } from "../../../scene/rscn/doc";
import { extensionAccepted, isAbsolutePath, resourcePathProblem, MODEL_PATHS } from "../../../scene/textdoc/check";
import { fileName, join, normalizeAbs, parent } from "../../../fs/path";
import { vfs } from "../../../fs/vfs";
import { ImportRecord } from "../scene";
import { INSTANCE_DEPTH_MAX, modelPath } from "../compose";
import { ModelFileKind, modelFileKind } from "../formats";
import { RmdlDoc } from "../rmdlcmd/doc";
import { instancedPaths } from "../rmdlcmd/scan";
import { RecordAt, readElements, sortByPosition } from "./elements";
import { W_RMDL_DROPPED, W_RMDL_IMPORT_CHANGED } from "./format";
import { rmdlInstancedPaths } from "./scan";
import { extExtensions } from "./schema";
import { commandFile, replayDiagnostic, replayRecords, xmlSyntaxError } from "./read";
import { R_IMPORT } from "./schema";

// `file` names the document in the diagnostics; `dir` is the model's
// directory as the vfs resolves it ("" to read no other file).
export function checkRmdl(bytes: Uint8Array, file: string, dir: string = ""): Diagnostics {
    const out = new Diagnostics();
    let i = 0;
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) i = 3;
    while (i < bytes.length && (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D)) i++;
    if (i < bytes.length && bytes[i] != 0x3C) {
        out.add(commandFile(file).toDiagnostic());
        return out;
    }
    const x = parseXml(bytes, file);
    if (!x.ok) {
        out.add(xmlSyntaxError(x, file).toDiagnostic());
        return out;
    }
    const els = readElements(x.value, file, bytes.length);
    for (let k = 0; k < els.errors.length; k++) out.add(els.errors[k]);
    if (els.errors.length == 0) {
        const d = replayDiagnostic(replayRecords(els, file));
        if (d != null) out.add(d);
    }
    if (dir.length > 0) checkFiles(els.exts, file, dir, out);
    if (dir.length > 0) checkCycles(els.exts, file, dir, out);
    const warnings = els.warnings.slice(0);
    droppedNodes(x.value, file, warnings);
    sortByPosition(warnings);
    for (let k = 0; k < warnings.length; k++) out.add(warnings[k]);
    if (dir.length > 0 && els.errors.length == 0) checkImports(els.records, file, dir, out);
    return out;
}

// What the ext_resource types a load reads are, as a message names them.
function fileWhat(type: string): string {
    if (type == "Material") return "the material file";
    if (type == "PackedScene") return "the instanced model";
    if (type == "Shader") return "the shader";
    return "the texture";
}

// Each file a load reads (a Texture2D's, a Material's, a PackedScene's),
// which must be there (a stat: the file is not read). A path the reader
// refused already has its error.
function checkFiles(exts: Array<ExtResourceDecl>, file: string, dir: string, out: Diagnostics): void {
    for (let k = 0; k < exts.length; k++) {
        const d = exts[k];
        // (milestone 61: a Material's shader too)
        if (d.type != "Texture2D" && d.type != "Material" && d.type != "PackedScene" && d.type != "Shader") continue;
        if (resourcePathProblem(d.path, MODEL_PATHS).length > 0) continue;
        // (a file of the wrong kind has its error already)
        const exts = extExtensions(d.type);
        if (exts.length > 0 && !extensionAccepted(exts, d.path)) continue;
        const abs = isAbsolutePath(d.path) ? d.path : join(dir, d.path);
        const m = vfs.metadata(abs);
        let why = "";
        if (!m.ok) why = m.err;
        else if (!m.value.isFile()) why = "it is not a file";
        if (why.length == 0) continue;
        const pos = d.attrPos("path");
        out.error("file-read", file, pos.line, pos.col, "cannot read " + fileWhat(d.type) + " \"" + d.path + "\": " + why,
            "check that the file exists, relative to the .rmdl's directory");
    }
}

// An instance that leads back to this document, through the models it
// instances (each followed as far as INSTANCE_DEPTH_MAX): instance-cycle,
// at the PackedScene's path, as an .rscn that instances itself.
function checkCycles(exts: Array<ExtResourceDecl>, file: string, dir: string, out: Diagnostics): void {
    const self = normalizeAbs(join(dir, fileOrName(file)));
    for (let k = 0; k < exts.length; k++) {
        const d = exts[k];
        if (d.type != "PackedScene" || resourcePathProblem(d.path, MODEL_PATHS).length > 0) continue;
        if (!extensionAccepted(extExtensions(d.type), d.path)) continue;
        const abs = modelPath(dir, d.path);
        const chain: Array<string> = [self];
        if (!leadsTo(abs, self, chain)) continue;
        const shown = new Array<string>();
        for (let i = 0; i < chain.length; i++) shown.push(i == 0 ? fileOrName(file) : chain[i]);
        shown.push(fileOrName(file));
        const pos = d.attrPos("path");
        out.error("instance-cycle", file, pos.line, pos.col, "instance cycle: " + shown.join(" -> "),
            "a model cannot instance itself, directly or through the models it instances");
    }
}

// Whether the model at `abs` (absolute) instances `target`, directly or
// through others; `chain` holds the way there when it does.
function leadsTo(abs: string, target: string, chain: Array<string>): bool {
    if (abs == target) return true;
    if (chain.includes(abs) || chain.length > INSTANCE_DEPTH_MAX) return false;
    chain.push(abs);
    const next = instancesOf(abs);
    const d = parentDir(abs);
    for (let i = 0; i < next.length; i++) {
        if (leadsTo(modelPath(d, next[i]), target, chain)) return true;
    }
    chain.pop();
    return false;
}

// The models the model file at `abs` instances, as written ([] for a
// file that does not read, and for a glTF file, which instances nothing).
function instancesOf(abs: string): Array<string> {
    const kind = modelFileKind(abs);
    if (kind != ModelFileKind.Snapshot && kind != ModelFileKind.Commands) return [];
    const t = vfs.readToString(abs);
    if (!t.ok) return [];
    if (kind == ModelFileKind.Snapshot) return rmdlInstancedPaths(t.value);
    const d = RmdlDoc.parse(t.value, abs);
    return d.ok ? instancedPaths(d.value) : [];
}

function parentDir(abs: string): string {
    const p = parent(abs);
    return p != null && p.length > 0 ? p : "/";
}

function fileOrName(path: string): string {
    const n = fileName(path);
    return n != null ? n : path;
}

// Each comment and processing instruction of the document, a warning at
// its place: the model holds none, so a rewrite drops it.
function droppedNodes(x: XmlDocument, file: string, out: Array<Diagnostic>): void {
    for (let i = 0; i < x.prolog.length; i++) droppedNode(x.prolog[i], file, out);
    droppedTree(x.root, file, out);
    for (let i = 0; i < x.epilog.length; i++) droppedNode(x.epilog[i], file, out);
}

function droppedTree(n: XmlNode, file: string, out: Array<Diagnostic>): void {
    droppedNode(n, file, out);
    for (let i = 0; i < n.children.length; i++) droppedTree(n.children[i], file, out);
}

function droppedNode(n: XmlNode, file: string, out: Array<Diagnostic>): void {
    if (n.kind != XmlKind.Comment && n.kind != XmlKind.Pi) return;
    const what = n.kind == XmlKind.Comment ? "a comment" : "a processing instruction";
    out.push(new Diagnostic(Severity.Warning, W_RMDL_DROPPED, file, n.pos.line, n.pos.col,
        what + ": the model does not hold it, so a rewrite (`hedra format`, a command, a save) drops it",
        "keep a note the document keeps as <meta name=\"note\" value=\"...\"/>"));
}

// Each import's source, read and hashed against the hash it recorded.
function checkImports(records: Array<RecordAt>, file: string, dir: string, out: Diagnostics): void {
    for (let k = 0; k < records.length; k++) {
        const r = records[k];
        if (r.ri != R_IMPORT) continue;
        const path = r.d.positionals[0].text();
        const h = r.d.value("hash");
        if (path.length == 0 || h == null) continue;
        const pos = r.at("hash");
        const abs = isAbsolutePath(path) ? path : join(dir, path);
        const b = vfs.read(abs);
        if (!b.ok) {
            out.warning(W_RMDL_IMPORT_CHANGED, file, pos.line, pos.col, "the import's source \"" + path + "\" cannot be read: " + b.err,
                "the geometry it copied is in the document; import the file again to update it");
            continue;
        }
        const now = ImportRecord.hashBytes(b.value);
        if (now != h.text()) {
            out.warning(W_RMDL_IMPORT_CHANGED, file, pos.line, pos.col, "the import's source \"" + path + "\" has changed since it was "
                + "imported (hash " + now + ", recorded " + h.text() + ")",
                "the document keeps the geometry it copied then; import the file again to take the new one");
        }
    }
}
