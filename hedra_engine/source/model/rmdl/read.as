// The .rmdl reader: an XML document of a model to the scene it holds,
// without the command kernel (any program reads one, a built project's
// player included). docs/formats/RMDL.md is the format.
//
// Three steps: the XML (base/xml.as, .rscn's reader), the elements
// (elements.as: the structure checked, names resolved, the model's data-form
// records built), and the data form's own replay (../rmdlcmd/data/read.as
// Replay.applySplit, record by record, then finish), which builds the scene
// exactly as it builds one from data lines. A problem is a SceneryError at
// file:line:column: the first structural one in source order, else the
// first the replay finds (rmdl-invalid, at the value of the property it is
// about, named as the document names it).

import { Result } from "../../../base/util";
import { XmlDocument, parseXml, parseXmlText, xmlErrorOf } from "../../../base/xml";
import { Diagnostic, Diagnostics, SceneryError } from "../../../scene/error";
import { Replay } from "../rmdlcmd/data/read";
import { rmdlErrorOf } from "../rmdlcmd/format";
import { Scene } from "../scene";
import { RmdlRead } from "./doc";
import { Elements, RecordAt, readElements } from "./elements";
import { E_RMDL_COMMAND_FILE, E_RMDL_INVALID } from "./format";
import { recordSpec } from "./schema";

export const RMDL_XML_HINT = "an .rmdl is XML: close every element, quote every attribute value, and write & < > in text as &amp; &lt; &gt;";
export const RMDL_COMMAND_FILE_HINT = "a command file is an .rmdlcmd whose first line is `# rmdlcmd 1`: rename it, then write its model with "
    + "`hedra model x.rmdlcmd --to x.rmdl`";

// Whether `text` starts like a command file (its first non-blank character
// is `#`, or it is not XML at all): what the reader says instead of an XML
// syntax error.
export function looksLikeCommandFile(text: string): bool {
    let i = 0;
    if (text.length > 0 && text.charCodeAt(0) == 0xFEFF) i = 1;
    while (i < text.length) {
        const c = text.charCodeAt(i);
        if (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) break;
        i++;
    }
    return i < text.length && text.charCodeAt(i) != 0x3C;
}

// Whether the bytes start like a command file (looksLikeCommandFile of
// their first non-blank character, without decoding them all).
function bytesLookLikeCommandFile(b: Uint8Array): bool {
    let i = 0;
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) i = 3;
    while (i < b.length) {
        const c = <i32>b[i];
        if (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) break;
        i++;
    }
    return i < b.length && b[i] != 0x3C;
}

// Reads a document. `file` is how errors name it (a path as the caller
// shows it: the loader's display path, the CLI's argument).
export function readRmdl(bytes: Uint8Array, file: string): Result<RmdlRead> {
    if (bytesLookLikeCommandFile(bytes)) return commandFile(file).fail<RmdlRead>();
    return fromXml(parseXml(bytes, file), file, bytes.length);
}

// readRmdl of a string.
export function readRmdlText(text: string, file: string): Result<RmdlRead> {
    if (looksLikeCommandFile(text)) return commandFile(file).fail<RmdlRead>();
    return fromXml(parseXmlText(text, file), file, text.length);
}

export function commandFile(file: string): SceneryError {
    return SceneryError.at(E_RMDL_COMMAND_FILE, file, 1, 1, "this .rmdl holds commands, not a model document", RMDL_COMMAND_FILE_HINT);
}

// The XML syntax error of a failed parse.
export function xmlSyntaxError<T>(r: Result<T>, file: string): SceneryError {
    const e = xmlErrorOf<T>(r);
    if (e != null) return SceneryError.at("xml-syntax", file, e.pos.line, e.pos.col, e.message, RMDL_XML_HINT);
    return SceneryError.at("xml-syntax", file, 0, 0, r.err, RMDL_XML_HINT);
}

function fromXml(r: Result<XmlDocument>, file: string, size: i32): Result<RmdlRead> {
    if (!r.ok) return xmlSyntaxError<XmlDocument>(r, file).fail<RmdlRead>();
    const els = readElements(r.value, file, size);
    if (els.errors.length > 0) return els.errors[0].toError().fail<RmdlRead>();
    const s = replayRecords(els, file);
    if (!s.ok) return Result.failWith<RmdlRead>(s.cause!);
    const warnings = new Diagnostics();
    for (let i = 0; i < els.warnings.length; i++) warnings.add(els.warnings[i]);
    const out = new RmdlRead(els.head, s.value, warnings);
    out.dropped = els.dropped;
    return Result.okv<RmdlRead>(out);
}

// The scene the records build, or the replay's first problem as
// rmdl-invalid where the document says what failed.
export function replayRecords(els: Elements, file: string): Result<Scene> {
    const replay = new Replay(file);
    replay.document = true;
    // Records are applied with their element's line; the finish's errors
    // name a line, mapped back to the record that has it.
    for (let i = 0; i < els.records.length; i++) {
        const rec = els.records[i];
        replay.names = recordSpec(rec.ri).names();
        const a = replay.applySplit(rec.ri, rec.d, rec.el.pos.line, rec.el.pos.col);
        if (!a.ok) return invalid<bool, Scene>(a, file, rec, replay.failedFlag);
    }
    const f = replay.finish();
    if (!f.ok) {
        const e = rmdlErrorOf<Scene>(f);
        let rec: RecordAt? = null;
        if (e != null) {
            for (let i = 0; i < els.records.length && rec == null; i++) {
                if (els.records[i].el.pos.line == e.line && e.line > 0) rec = els.records[i];
            }
        }
        if (rec == null && els.records.length > 0) rec = els.records[0];
        if (rec == null) return SceneryError.at(E_RMDL_INVALID, file, 1, 1, f.err).fail<Scene>();
        return invalid<Scene, Scene>(f, file, rec, replay.failedFlag);
    }
    return f;
}

function invalid<T, U>(r: Result<T>, file: string, rec: RecordAt, flag: string): Result<U> {
    const e = rmdlErrorOf<T>(r);
    const pos = rec.at(flag);
    const message = e != null ? e.message : r.err;
    const hint = e != null && e.hint.length > 0 ? e.hint : null;
    return SceneryError.at(E_RMDL_INVALID, file, pos.line, pos.col, message, hint).fail<U>();
}

// The diagnostic of a failed replay (validate.as lists it after the
// structural ones).
export function replayDiagnostic(r: Result<Scene>): Diagnostic? {
    if (r.ok) return null;
    const c = r.cause;
    if (c == null) return null;
    const isScenery = c instanceof SceneryError;
    if (!isScenery) return null;
    return (c as SceneryError).toDiagnostic();
}
