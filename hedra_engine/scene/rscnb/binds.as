// The BNDS section of a binary scene (milestone 42, docs/plans/
// RIVE_MODEL.md section 4.6): what format 2 adds to a scene's bindings and
// does not fit BIND's records, and the converters it uses, so that a built
// scene binds and converts without reading any text. codec.as writes it
// exactly when the document has a binding with `once`, `global` or
// `converter`, a converter of its own, or project converters
// (RscnDoc.projectConverters, which a build fills from the Rive project's
// RML); a scene without any of it has no BNDS, so its .rscnb is byte for
// byte what it was before format 2. It comes after SRCS and before ASST
// (format.as OPTIONAL_SECTION_ORDER).
//
// Self-contained as SRCS is: its strings are its own (`str` is u32 n, then
// n bytes of UTF-8), not indices into STRS, so that the section reads
// alone.
//
//   u32 version = 1
//   u32 nExtras, nExtras x { u32 binding (its index in BIND), u8 once,
//                            str global, str converter }
//   u32 nScene,   nScene x converter     (the scene's own, in entry order)
//   u32 nProject, nProject x converter   (RscnDoc.projectConverters)
//   converter = { str type, str name, u32 nAttrs, nAttrs x (str name,
//                 str value), u32 nItems, nItems x str, u32 nChildren,
//                 nChildren x converter }
//
// The extras are in increasing binding order, each binding at most once;
// `once` is 0 or 1 (a `once` the validator refuses is not here: a file
// with fidelity keeps it as an attribute, in FIDL). ORDR names each scene
// converter once (EntryKind.Converter, its index here), so that
// `.rscn -> .rscnb -> .rscn` gives the canonical text back. A reader of
// this version reads these fields and ignores bytes after them, so a later
// version may append fields. docs/formats/RSCN.md, "Binary scenes", is
// normative.

import { BindingDecl, EntryKind, RscnDoc } from "../rscn/doc";
import { DataAttr, DataConverterDecl } from "../data/model";
import { BinReader } from "./bin";

// The section's own version (its first field).
export const BNDS_VERSION: u32 = 1;

// How deep converters may nest (a formula's tokens are one level): a
// deeper one is a damaged file, refused rather than recursed into.
export const BNDS_MAX_DEPTH: i32 = 16;

// One binding's format-2 attributes, by its index in BIND.
export class BindExtra {
    binding: u32 = 0;
    once: bool = false;
    global: string = "";
    converter: string = "";
}

// What a BNDS section holds.
export class BindsData {
    extras: Array<BindExtra> = [];
    scene: Array<DataConverterDecl> = [];
    project: Array<DataConverterDecl> = [];
}

// The extra of binding `b` (its index `index` in BIND), or null when it has
// none: once "true", a global or a converter.
export function bindExtraOf(b: BindingDecl, index: u32): BindExtra? {
    const once = b.once == "true";
    if (!once && b.global.length == 0 && b.converter.length == 0) return null;
    const x = new BindExtra();
    x.binding = index;
    x.once = once;
    x.global = b.global;
    x.converter = b.converter;
    return x;
}

// Whether `doc` needs a BNDS section: a binding with an extra, a converter
// entry, or project converters.
export function bindsNeeded(doc: RscnDoc): bool {
    if (doc.projectConverters.length > 0) return true;
    for (let i = 0; i < doc.entries.length; i++) {
        const e = doc.entries[i];
        if (e.kind == EntryKind.Converter && e.converter != null) return true;
        const n = e.node;
        if (n == null) continue;
        for (let k = 0; k < n.items.length; k++) {
            const b = n.items[k].binding;
            if (b != null && bindExtraOf(b, 0) != null) return true;
        }
    }
    return false;
}

function readStr(r: BinReader): string {
    const n = r.count(1);
    return r.utf8(n);
}

// A converter (`depth` deep), or null with `r` failed.
function readConverter(r: BinReader, depth: i32): DataConverterDecl? {
    if (depth > BNDS_MAX_DEPTH) {
        r.fail("converters nested deeper than " + BNDS_MAX_DEPTH.toString());
        return null;
    }
    const d = new DataConverterDecl();
    d.type = readStr(r);
    d.name = readStr(r);
    const nAttrs = r.count(8);
    for (let k = 0; k < nAttrs && !r.failed; k++) {
        const name = readStr(r);
        const value = readStr(r);
        d.attrs.push(new DataAttr(name, value));
    }
    const nItems = r.count(4);
    for (let k = 0; k < nItems && !r.failed; k++) d.items.push(readStr(r));
    const nChildren = r.count(4);
    for (let k = 0; k < nChildren && !r.failed; k++) {
        const c = readConverter(r, depth + 1);
        if (c == null) return null;
        d.children.push(c);
    }
    if (r.failed) return null;
    if (d.type.length == 0) {
        r.fail("a converter without a type");
        return null;
    }
    return d;
}

function readList(r: BinReader, into: Array<DataConverterDecl>): void {
    // (a converter is at least 20 bytes: its five counts and lengths)
    const n = r.count(20);
    for (let k = 0; k < n && !r.failed; k++) {
        const c = readConverter(r, 0);
        if (c == null) return;
        into.push(c);
    }
}

// The section's `bytes` read, or null with why not in `why[0]`: a newer
// version, a count past the end, extras out of order, a converter cut
// short. `nBindings` is BIND's count, which every extra's index must be
// under.
export function decodeBnds(bytes: Uint8Array, nBindings: i32, why: Array<string>): BindsData? {
    const r = new BinReader(bytes);
    const version = r.u32();
    if (!r.failed && version != BNDS_VERSION) {
        why.push("its version is " + version.toString() + ", this build reads " + BNDS_VERSION.toString());
        return null;
    }
    const out = new BindsData();
    // (an extra is at least 13 bytes)
    const nExtras = r.count(13);
    let last: i64 = -1;
    for (let k = 0; k < nExtras && !r.failed; k++) {
        const x = new BindExtra();
        x.binding = r.u32();
        const once = r.u8();
        x.global = readStr(r);
        x.converter = readStr(r);
        if (r.failed) break;
        if (once > 1) {
            r.fail("extra " + k.toString() + "'s once is " + once.toString() + ", not 0 or 1");
            break;
        }
        x.once = once == 1;
        if (<i64>x.binding <= last || x.binding >= <u32>nBindings) {
            r.fail("extra " + k.toString() + " names binding " + x.binding.toString() + ": out of order, or not one of BIND's "
                + nBindings.toString());
            break;
        }
        last = <i64>x.binding;
        out.extras.push(x);
    }
    if (!r.failed) readList(r, out.scene);
    if (!r.failed) readList(r, out.project);
    if (r.failed) {
        why.push(r.why);
        return null;
    }
    return out;
}

// Gives the bindings of `binds` (by BIND index) their extras.
export function applyBindExtras(data: BindsData, binds: Array<BindingDecl?>): void {
    for (let k = 0; k < data.extras.length; k++) {
        const x = data.extras[k];
        const b = binds[<i32>x.binding];
        if (b == null) continue;
        if (x.once) b.once = "true";
        b.global = x.global;
        b.converter = x.converter;
    }
}
