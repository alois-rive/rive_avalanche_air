// The .rscnb codec (milestone 39): an RscnDoc (../rscn/doc.as) to the
// binary scene format.as lays out, and back. The tools read and write
// .rscnb as they do .rscn (the loader reads either; `the CLI format
// --binary` and `--text` convert; the editor's Save As writes either), and
// Build stores every built scene this way, so
//
//   writeRscn(decodeRscnb(encodeRscnb(parseRscn(x)))) == writeRscn(parseRscn(x))
//
// byte for byte for every x that parses (the property the tests check),
// and encodeRscnb is deterministic (the same document gives the same
// bytes). With `fidelity` off (Build's choice) the comments, unknown
// elements and attributes, prolog and epilog are left out: the scene
// instances the same, and its canonical text lacks only those.
//
// The sections (docs/formats/RSCN.md, "Binary scenes: .rscnb", is the
// normative layout; every count is a u32 before its records, every index a
// u32, NONE (0xFFFFFFFF) where something may be absent):
//
//   STRS  the string table (bin.as StringTable)
//   VALS  the values table (values.as ValueTable)
//   EXTR  ext_resources:   { id, type, path, uid|NONE } strings
//   SUBR  sub_resources and a material document's <resource>:
//                          { id, type, firstItem, itemCount }
//   NODE  nodes in document order:
//                          { parent, name, type|NONE, instance value|NONE,
//                            firstItem, itemCount }
//         parent: NONE for none, the index of an earlier node (the latest
//         whose path is the parent's), else PARENT_STRING | a string (the
//         path of a node inside an instance, or one no node has)
//   ITEM  the bodies, SUBR's ranges then NODE's, back to back:
//                          { u8 BodyKind, u8 flags (bit 0: CDATA), u16 0,
//                            u32 a, u32 b }
//         Property a = name, b = value; Group a = name; Binding a = a BIND
//         record; Comment, Unknown a = a FIDL node (fidelity only)
//   BIND  bindings:        { property, path, mode, scale, offset, convert }
//   CONN  connections:     { signal, from, to, method, i32 flags }
//   EMBD  embedded files:  u32 count, u32 data bytes, records { path,
//         invalid ("" when the content decoded), xml (the element as read
//         when it did not, else NONE), u32 0, u32 offset, u32 length,
//         i64 size }, then the data, each file 8-aligned
//   ORDR  the document:    u32 uid|NONE, u32 count, then the entries in
//         source order, each EntryKind << 24 | its record's index (SUBR for
//         SubResource and Resource; a FIDL node for Comment and Unknown;
//         milestone 42: a scene converter of BNDS for Converter)
//   FIDL  (fidelity only)  u32 n, n XML texts (strings, one node each:
//         writeXmlNode); u32 n, the prolog's nodes; u32 n, the epilog's;
//         u32 n, attributes { owner kind, owner index, name, value } in
//         each owner's order; u32 n, children { owner kind, owner index,
//         node } (an ext_resource's or a connection's)
//
//   BNDS  (milestone 42, only when the document needs it: ./binds.as)
//         the bindings' once, global and converter, the scene's converters
//         (ORDR names each, EntryKind.Converter, its index there) and the
//         project's (RscnDoc.projectConverters); after SRCS, before ASST
//
//   ANIM  (milestone 45, only when the document has an Event or a
//         LinearAnimation: ./anim.as) the scene's timelines (ORDR names
//         each, EntryKind.Event and EntryKind.Animation, its index
//         there); after SRCS, before STMC and BNDS
//
//   STMC  (milestone 46, only when the document has a StateMachine:
//         ./sm.as) the scene's state machines (ORDR names each,
//         EntryKind.StateMachine, its index there); after ANIM, before BNDS
//
//   ASST  (milestone 40, a self-contained scene only: RSCNB_FLAG_ASSETS)
//         the last section, 16-aligned, running to the end of the file:
//         u32 n, u32 0, n records { u32 kind, u32 name, u64 offset, u64
//         size, u32 flags (0), u32 crc32 } sorted as a bundle's table
//         (../bundle/read.as compareEntries), then the assets, each at a
//         multiple of 16 of the file, identical bytes stored once. The
//         names are strings of STRS, interned after the document's own, so
//         that the document's sections are those of the same scene without
//         assets. decodeRscnb checks the table and skips the assets: the
//         document is the same either way (../bundle/scene_file.as reads
//         them, as a bundle of the one scene).
//
// Decoding never trusts the file: every index is checked against its
// table, every count against what is left, the CRC first; a record is used
// once (two declarations never share one object), and what does not hold
// is `rscnb-invalid` at the file, never a trap.

import { Result } from "../../base/util";
import { XmlAttr, XmlKind, XmlNode, XmlPos, parseXmlText } from "../../base/xml";
import { crc32 } from "../../render/png";
import { SceneryError } from "../error";
import { Value, ValueKind } from "../value";
import { BindingDecl, BodyItem, BodyKind, ConnectionDecl, Declaration, DocKind, EmbeddedDecl, Entry, EntryKind, ExtResourceDecl, FORMAT_VERSION, NodeDecl, Property, RscnDoc, SubResourceDecl } from "../rscn/doc";
import { DataConverterDecl } from "../data/model";
import { applyBindExtras, decodeBnds } from "./binds";
import { decodeAnim } from "./anim";
import { EventDecl, LinearAnimationDecl } from "../anim/decl";
import { decodeStmc, numberStateMachine } from "./sm";
import { StateMachineDecl } from "../sm/decl";
import { compareEntries } from "../bundle/read";
import { BinReader, NONE, StringTable, fourccText, stringAt } from "./bin";
import { readValueTable } from "./values";
import { RSCNB_FLAG_ASSETS, RSCNB_FLAG_FIDELITY, RSCNB_HEADER_BYTES, RSCNB_MAGIC, RSCNB_VERSION, RscnbKind, SCENE_ASSET_ALIGN, SECTION_ANIMATIONS, SECTION_ASSETS, SECTION_STATE_MACHINES, SECTION_BINDINGS, SECTION_BINDS, SECTION_CONNECTIONS, SECTION_EMBEDDED, SECTION_EXT, SECTION_FIDELITY, SECTION_ITEMS, SECTION_NODES, SECTION_ORDER, SECTION_STRINGS, SECTION_SUB, SECTION_VALUES, looksLikeRscnb } from "./format";
import { CLI } from "../../base/names";

// Milestone 41: a section the encoder writes as it is (RscnbOptions.extra),
// and what rscnbSection reads back.
export class RscnbSection {
    id: u32;
    data: Uint8Array;

    constructor(id: u32, data: Uint8Array) {
        this.id = id;
        this.data = data;
    }
}

// The length of an ASST record, and of the section's head (u32 n, u32 0).
export const ASSET_RECORD_BYTES: i32 = 32;
export const ASSET_HEAD_BYTES: i32 = 8;

// One asset of a self-contained scene's ASST section: its kind
// (../bundle/format.as AssetKind), its name (a bundle path), and where its
// bytes lie in the file. The encoder takes `data` and fills in the rest;
// the decoder (readRscnbAssets) fills in all but `data`, the bytes being a
// range of the file.
export class RscnbAsset {
    kind: u32;
    name: string;
    data: Uint8Array;
    offset: u64 = 0;
    size: u64 = 0;
    crc: u32 = 0;
    // (the encoder's) whether its bytes were stored already, for an asset
    // earlier in the table: the two share one range.
    shared: bool = false;

    constructor(kind: u32, name: string, data: Uint8Array = new Uint8Array(0)) {
        this.kind = kind;
        this.name = name;
        this.data = data;
    }
}

// The error code of a file that is not a .rscnb this version reads (bad
// magic, a newer version, a damaged table, a CRC that does not match).
export const RSCNB_INVALID_CODE = "rscnb-invalid";

// The hint of every rscnb-invalid error.
export const RSCNB_INVALID_HINT = "a .rscnb is written by `" + CLI + " format --binary` or the editor's Save As: "
    + "write it again from its .rscn (a copy that changed line ends or was cut short does not read)";

// NODE's parent: a string (a path) rather than a node index.
export const PARENT_STRING: u32 = 0x80000000;

// ITEM's flags.
export const ITEM_CDATA: u32 = 1;

// FIDL's owners: what an extra attribute or child belongs to.
export enum FidelityOwner {
    Root = 0,
    Ext = 1,
    Sub = 2,
    Node = 3,
    Connection = 4,
    Embedded = 5,
    Item = 6,
}

// The sections every file has, in the order they are written (FIDL after
// them when the file keeps fidelity).
export const REQUIRED: StaticArray<u32> = [
    SECTION_STRINGS, SECTION_VALUES, SECTION_EXT, SECTION_SUB, SECTION_NODES, SECTION_ITEMS, SECTION_BINDINGS,
    SECTION_CONNECTIONS, SECTION_EMBEDDED, SECTION_ORDER,
];

export function alignUp(v: u64, n: i32): u64 {
    return (v + <u64>(n - 1)) & ~<u64>(n - 1);
}

// ---------------------------------------------------------------------------
// Encoding

// ---------------------------------------------------------------------------
// Decoding

// The header's facts, for a tool that must know them before decoding (the
// format command keeps a file's fidelity when it re-encodes one).
export class RscnbHeader {
    version: u32 = 0;
    format: u32 = 0;
    kind: u32 = 0;
    flags: u32 = 0;

    get fidelity(): bool {
        return (this.flags & RSCNB_FLAG_FIDELITY) != 0;
    }

    // Milestone 40: a self-contained scene (format.as RSCNB_FLAG_ASSETS).
    get assets(): bool {
        return (this.flags & RSCNB_FLAG_ASSETS) != 0;
    }
}

// The header of `bytes` when they start as a .rscnb does, else null (no
// other check: decodeRscnb checks the rest).
export function rscnbHeader(bytes: Uint8Array): RscnbHeader? {
    if (bytes.length < RSCNB_HEADER_BYTES || !looksLikeRscnb(bytes)) return null;
    const r = new BinReader(bytes, 8, RSCNB_HEADER_BYTES);
    const h = new RscnbHeader();
    h.version = r.u16();
    h.format = r.u16();
    h.kind = r.u8();
    h.flags = r.u8();
    return h;
}

const NO_POS = new XmlPos();

// Positions of nodes read back from FIDL are those of an element built in
// code (line 0): the wrapper they were parsed in is no file anyone wrote.
function clearPositions(n: XmlNode): void {
    const stack = new Array<XmlNode>();
    stack.push(n);
    while (stack.length > 0) {
        const x = stack.pop();
        x.pos = NO_POS;
        x.contentPos = NO_POS;
        x.endPos = NO_POS;
        for (let k = 0; k < x.attrs.length; k++) {
            x.attrs[k].pos = NO_POS;
            x.attrs[k].valuePos = NO_POS;
        }
        for (let k = 0; k < x.children.length; k++) stack.push(x.children[k]);
    }
}

// XML texts (one node each) as nodes, parsed together in one wrapper
// element; null when they are not that many well-formed nodes.
function parseXmlNodes(texts: Array<string>): Array<XmlNode>? {
    if (texts.length == 0) return [];
    const parsed = parseXmlText("<x>" + texts.join("") + "</x>", "rscnb");
    if (!parsed.ok) return null;
    const kids = parsed.value.root.children;
    if (kids.length != texts.length) return null;
    for (let k = 0; k < kids.length; k++) {
        const c = kids[k];
        if (c.kind == XmlKind.Text || c.kind == XmlKind.CData) return null;
        clearPositions(c);
    }
    return kids;
}

class SectionRef {
    offset: i32;
    size: i32;

    constructor(offset: i32, size: i32) {
        this.offset = offset;
        this.size = size;
    }
}

class Decoder {
    bytes: Uint8Array;
    file: string;
    why: string = "";
    strings: Array<string> = [];
    values: Array<Value> = [];
    // Whether a value has been handed out already: a second user gets a
    // copy, so that no two properties share one Value (an edit of one in
    // place would change the other).
    valueUsed: Uint8Array = new Uint8Array(0);
    fidelity: bool = false;
    xml: Array<XmlNode> = [];
    xmlUsed: Uint8Array = new Uint8Array(0);
    // Milestone 42: the binding declarations by BIND index (BNDS's extras
    // name them so).
    binds: Array<BindingDecl?> = [];

    constructor(bytes: Uint8Array, file: string) {
        this.bytes = bytes;
        this.file = file;
    }

    fail(why: string): bool {
        if (this.why.length == 0) this.why = why;
        return false;
    }

    reader(s: SectionRef): BinReader {
        return new BinReader(this.bytes, s.offset, s.offset + s.size);
    }

    // The reader's failure, named by its section.
    check(r: BinReader, name: string): bool {
        if (r.failed) return this.fail("section " + name + ": " + r.why);
        return true;
    }

    str(r: BinReader, i: u32): string {
        if (i >= <u32>this.strings.length) {
            r.fail("a string index (" + i.toString() + ") past the table (" + this.strings.length.toString() + ")");
            return "";
        }
        return this.strings[<i32>i];
    }

    optStr(r: BinReader, i: u32): string? {
        return i == NONE ? null : this.str(r, i);
    }

    value(r: BinReader, i: u32): Value {
        if (i >= <u32>this.values.length) {
            r.fail("a value index (" + i.toString() + ") past the table (" + this.values.length.toString() + ")");
            return Value.nil();
        }
        const v = this.values[<i32>i];
        // An Array's or a Dictionary's items are entries of the table too
        // (shared with whatever else names them): always a copy.
        if (v.kind == ValueKind.Array || v.kind == ValueKind.Dictionary) return v.clone();
        if (this.valueUsed[<i32>i] != 0) return v.clone();
        this.valueUsed[<i32>i] = 1;
        return v;
    }

    xmlAt(r: BinReader, i: u32): XmlNode {
        if (i >= <u32>this.xml.length) {
            r.fail("an XML node index (" + i.toString() + ") past FIDL's " + this.xml.length.toString());
            return XmlNode.comment("");
        }
        if (this.xmlUsed[<i32>i] != 0) {
            r.fail("XML node " + i.toString() + " is used twice");
            return XmlNode.comment("");
        }
        this.xmlUsed[<i32>i] = 1;
        return this.xml[<i32>i];
    }
}

function invalid(file: string, why: string): Result<RscnDoc> {
    return invalidAs<RscnDoc>(file, why);
}

// The header and the section table of a file, checked (Layout's reader).
class Layout {
    format: u32 = 0;
    kind: u32 = 0;
    flags: u32 = 0;
    crc: u32 = 0;
    ids: Array<u32> = [];
    refs: Array<SectionRef> = [];
}

// Milestone 67b: the files whose whole-file CRC matched, by their memory
// (the same buffer, offset and length: a view of the same bytes) and
// their headers' CRC, so that the checks of one load take the CRC once. A
// built scene's load reads its header up to five times (the run time's
// check of SRCS and its staleness, the bundle's table, the check again
// before the tree, the scene's own document), and the chess sample's
// 12.9 MB file costs about 290 ms a CRC under rive's interpreter. Only
// while a run time's load asks (rememberVerifiedRscnb with its scope, from
// its built check to the end of the load: ../runtime/scene_runtime.as
// builtCheck, BuiltCheckMemo.clear), whose bytes are never written. Two
// loads may be under way at once (two Scene3Ds, each loading over
// frames), each with its own scope: one ending forgets nothing the other
// needs, and once no load is under way every file is let go of, so the
// module keeps no file alive past its load; everywhere else (the tools, a
// test that damages bytes in place) every read takes the CRC.
export class RscnbVerifyScope {}

class VerifiedFile {
    buffer: ArrayBuffer;
    offset: i32;
    length: i32;
    crc: u32;

    constructor(buffer: ArrayBuffer, offset: i32, length: i32, crc: u32) {
        this.buffer = buffer;
        this.offset = offset;
        this.length = length;
        this.crc = crc;
    }
}

// (a few at most: one built file a load in progress)
const VERIFIED_KEPT: i32 = 8;
let verifyScopes: Array<RscnbVerifyScope> = [];
let verifiedFiles: Array<VerifiedFile> = [];

function wasVerified(bytes: Uint8Array, crc: u32): bool {
    for (let i = 0; i < verifiedFiles.length; i++) {
        const v = unchecked(verifiedFiles[i]);
        if (v.buffer === bytes.buffer && v.offset == bytes.byteOffset && v.length == bytes.length && v.crc == crc) return true;
    }
    return false;
}

// Says that `bytes`' whole-file CRC is `crc`, its header's (readLayout, and
// a load that took the CRC over several frames: ../runtime/load_task.as).
export function noteRscnbVerified(bytes: Uint8Array, crc: u32): void {
    if (verifyScopes.length == 0 || wasVerified(bytes, crc)) return;
    if (verifiedFiles.length >= VERIFIED_KEPT) verifiedFiles.shift();
    verifiedFiles.push(new VerifiedFile(bytes.buffer, bytes.byteOffset, bytes.length, crc));
}

// From now until forgetVerifiedRscnb(scope), a file whose CRC matched is
// not checked again (see above).
export function rememberVerifiedRscnb(scope: RscnbVerifyScope): void {
    if (!verifyScopes.includes(scope)) verifyScopes.push(scope);
}

// `scope`'s load is over; once no load is under way, every file is let go.
export function forgetVerifiedRscnb(scope: RscnbVerifyScope): void {
    const at = verifyScopes.indexOf(scope);
    if (at >= 0) verifyScopes.splice(at, 1);
    if (verifyScopes.length == 0) verifiedFiles.length = 0;
}

// How many files are remembered as verified (tests).
export function verifiedRscnbCount(): i32 {
    return verifiedFiles.length;
}

// The header of `bytes` and its section table, every field checked, the
// CRC first among what the sections hold: what decodeRscnb and
// readRscnbAssets start from. A self-contained scene's ASST (format.as
// RSCNB_FLAG_ASSETS) is checked here as a section: present exactly when
// the flag is set, the table's last entry, at a multiple of
// SCENE_ASSET_ALIGN after every other section, running to the end of the
// file; its records are checked by assetTable.
function readLayout(bytes: Uint8Array, file: string): Result<Layout> {
    if (!looksLikeRscnb(bytes)) {
        return invalidAs<Layout>(file, bytes.length < RSCNB_MAGIC.length ? "it is " + bytes.length.toString() + " bytes long"
            : "it does not start with the .rscnb magic bytes");
    }
    if (bytes.length < RSCNB_HEADER_BYTES) {
        return invalidAs<Layout>(file, "its header is cut short (" + bytes.length.toString() + " bytes)");
    }
    const h = new BinReader(bytes, 8, RSCNB_HEADER_BYTES);
    const version = h.u16();
    const format = h.u16();
    const kind = h.u8();
    const flags = h.u8();
    const nSections = <i32>h.u16();
    const size = h.u32();
    const crc = h.u32();
    const reserved = h.u64();
    if (version > RSCNB_VERSION) {
        return invalidAs<Layout>(file, "it is version " + version.toString() + " of the encoding, newer than this build reads ("
            + RSCNB_VERSION.toString() + ")");
    }
    if (version == 0) return invalidAs<Layout>(file, "version 0 of the encoding does not exist");
    if (size != <u32>bytes.length) {
        return invalidAs<Layout>(file, "its header says " + size.toString() + " bytes, the file holds " + bytes.length.toString());
    }
    if (!wasVerified(bytes, crc)) {
        const actual = crc32(bytes, RSCNB_HEADER_BYTES, bytes.length);
        if (actual != crc) return invalidAs<Layout>(file, "its CRC-32 does not match (the file is damaged)");
        noteRscnbVerified(bytes, crc);
    }
    if (reserved != 0) return invalidAs<Layout>(file, "the header's reserved bytes are not 0");
    if (format < 1 || format > <u32>FORMAT_VERSION) {
        return invalidAs<Layout>(file, "it holds format " + format.toString() + " of the scene, this build reads 1 to "
            + FORMAT_VERSION.toString());
    }
    if (kind > <u32>RscnbKind.Material) return invalidAs<Layout>(file, "an unknown kind of document (" + kind.toString() + ")");
    if ((flags & ~(RSCNB_FLAG_FIDELITY | RSCNB_FLAG_ASSETS)) != 0) {
        return invalidAs<Layout>(file, "unknown flags (" + flags.toString() + ")");
    }

    // The section table.
    const t = new BinReader(bytes, RSCNB_HEADER_BYTES, bytes.length);
    const out = new Layout();
    out.format = format;
    out.kind = kind;
    out.flags = flags;
    out.crc = crc;
    const ids = out.ids;
    const refs = out.refs;
    if (nSections * 12 > t.remaining()) return invalidAs<Layout>(file, "its section table runs past the end");
    const tableEnd = RSCNB_HEADER_BYTES + nSections * 12;
    for (let k = 0; k < nSections; k++) {
        const id = t.u32();
        const offset = t.u32();
        const len = t.u32();
        if ((offset & 7) != 0) return invalidAs<Layout>(file, "section " + fourccText(id) + " is not 8-aligned");
        if (offset < <u32>tableEnd || <u64>offset + <u64>len > <u64>bytes.length) {
            return invalidAs<Layout>(file, "section " + fourccText(id) + " lies outside the file");
        }
        if (ids.includes(id)) return invalidAs<Layout>(file, "section " + fourccText(id) + " appears twice");
        ids.push(id);
        refs.push(new SectionRef(<i32>offset, <i32>len));
    }
    const fidelity = (flags & RSCNB_FLAG_FIDELITY) != 0;
    for (let k = 0; k < REQUIRED.length; k++) {
        if (!ids.includes(REQUIRED[k])) return invalidAs<Layout>(file, "it has no " + fourccText(REQUIRED[k]) + " section");
    }
    if (fidelity && !ids.includes(SECTION_FIDELITY)) {
        return invalidAs<Layout>(file, "it says it keeps fidelity but has no FIDL section");
    }
    // (and the other way round: a flag that changed is caught here, the
    // header being outside the CRC)
    if (!fidelity && ids.includes(SECTION_FIDELITY)) {
        return invalidAs<Layout>(file, "it has a FIDL section but does not say it keeps fidelity");
    }
    const assets = (flags & RSCNB_FLAG_ASSETS) != 0;
    const ai = ids.indexOf(SECTION_ASSETS);
    if (assets && ai < 0) return invalidAs<Layout>(file, "it says it carries its assets but has no ASST section");
    if (!assets && ai >= 0) return invalidAs<Layout>(file, "it has an ASST section but does not say it carries its assets");
    if (assets) {
        // (a built scene: never fidelity, and a scene)
        if (fidelity) return invalidAs<Layout>(file, "it says it both keeps fidelity and carries its assets");
        if (kind != <u32>RscnbKind.Scene) return invalidAs<Layout>(file, "a material document that carries assets");
        const a = refs[ai];
        if (ai != ids.length - 1) return invalidAs<Layout>(file, "its ASST section is not the last of its table");
        if ((a.offset & (SCENE_ASSET_ALIGN - 1)) != 0) {
            return invalidAs<Layout>(file, "its ASST section is not " + SCENE_ASSET_ALIGN.toString() + "-aligned");
        }
        if (a.offset + a.size != bytes.length) return invalidAs<Layout>(file, "its ASST section does not run to the end of the file");
        for (let k = 0; k < ai; k++) {
            if (<i64>refs[k].offset + <i64>refs[k].size > <i64>a.offset) {
                return invalidAs<Layout>(file, "section " + fourccText(ids[k]) + " runs into the ASST section");
            }
        }
    }
    return Result.okv<Layout>(out);
}

function invalidAs<T>(file: string, why: string): Result<T> {
    return SceneryError.at(RSCNB_INVALID_CODE, file, 0, 0, file + " is not a binary scene this version reads: " + why,
        RSCNB_INVALID_HINT).fail<T>();
}

// The records of the ASST section `a` (format.as SECTION_ASSETS), their
// names from `strings`, into `out`; "" when they hold, else why not: the
// head's reserved field 0, every record's flags 0, its name a string of
// STRS, its bytes at a multiple of SCENE_ASSET_ALIGN of the file after
// the records and inside the file, the records sorted by kind then name
// with no name twice under one kind (a bundle's table: ../bundle/read.as).
// The records' CRCs are checked where an asset is used (Bundle.verified),
// the header's CRC already covering them.
function assetTable(bytes: Uint8Array, a: SectionRef, strings: Array<string>, out: Array<RscnbAsset>): string {
    const r = new BinReader(bytes, a.offset, a.offset + a.size);
    const n = r.u32();
    const reserved = r.u32();
    if (r.failed) return "section ASST: " + r.why;
    if (reserved != 0) return "section ASST: its reserved field is not 0";
    if (<u64>n * <u64>ASSET_RECORD_BYTES > <u64>r.remaining()) return "section ASST: its count (" + n.toString() + ") runs past the end";
    const dataAt = alignUp(<u64>a.offset + <u64>ASSET_HEAD_BYTES + <u64>n * <u64>ASSET_RECORD_BYTES, SCENE_ASSET_ALIGN);
    const end = <u64>bytes.length;
    for (let k: u32 = 0; k < n; k++) {
        const kind = r.u32();
        const name = stringAt(r, strings, r.u32());
        const offset = r.u64();
        const size = r.u64();
        const flags = r.u32();
        const crc = r.u32();
        if (r.failed) return "section ASST: record " + k.toString() + ": " + r.why;
        const what = "asset " + k.toString() + " (" + name + ")";
        if (flags != 0) return "section ASST: " + what + " has flags this version does not know";
        if ((offset & <u64>(SCENE_ASSET_ALIGN - 1)) != 0) return "section ASST: " + what + " is not 16-aligned";
        if (offset < dataAt || offset + size < offset || offset + size > end) return "section ASST: " + what + " lies outside its data";
        if (k > 0) {
            const prev = out[out.length - 1];
            if (compareEntries(prev.kind, prev.name, kind, name) >= 0) {
                return "section ASST: its records are not sorted, or name " + what + " twice";
            }
        }
        const e = new RscnbAsset(kind, name);
        e.offset = offset;
        e.size = size;
        e.crc = crc;
        out.push(e);
    }
    return "";
}

// The assets a self-contained scene carries (its ASST section), checked
// as decodeRscnb checks the file (the header, the CRC, the table) without
// decoding its document; rscnb-invalid when `bytes` are not a .rscnb this
// version reads or carry no assets. ../bundle/scene_file.as reads a scene
// file through it.
export class RscnbAssets {
    // The header's (format.as RscnbKind, RSCNB_FLAG_*).
    kind: u32 = 0;
    flags: u32 = 0;
    assets: Array<RscnbAsset> = [];
}

export function readRscnbAssets(bytes: Uint8Array, file: string): Result<RscnbAssets> {
    const l = readLayout(bytes, file);
    if (!l.ok) return l.forward<RscnbAssets>();
    const layout = l.value;
    if ((layout.flags & RSCNB_FLAG_ASSETS) == 0) {
        return invalidAs<RscnbAssets>(file, "it is a binary scene without its assets (a self-contained scene is written by "
            + "`" + CLI + " build`, docs/cli/BUILD.md)");
    }
    const sr = sectionOf(layout.ids, layout.refs, SECTION_STRINGS);
    const sreader = new BinReader(bytes, sr.offset, sr.offset + sr.size);
    const strings = StringTable.read(sreader);
    if (strings == null) return invalidAs<RscnbAssets>(file, "section STRS: " + sreader.why);
    const out = new RscnbAssets();
    out.kind = layout.kind;
    out.flags = layout.flags;
    const why = assetTable(bytes, sectionOf(layout.ids, layout.refs, SECTION_ASSETS), strings, out.assets);
    if (why.length > 0) return invalidAs<RscnbAssets>(file, why);
    return Result.okv<RscnbAssets>(out);
}

// The document `bytes` hold, named `file` in errors (code RSCNB_INVALID_CODE,
// line 0). Positions are those of an element built in code (line 0). The
// document is not validated: the loader validates it as it does a parsed
// .rscn. A self-contained scene (milestone 40) gives the document of the
// same scene without assets: its ASST table is checked, its assets are
// not read.
export function decodeRscnb(bytes: Uint8Array, file: string): Result<RscnDoc> {
    const l = readLayout(bytes, file);
    if (!l.ok) return l.forward<RscnDoc>();
    const layout = l.value;
    const ids = layout.ids;
    const refs = layout.refs;
    const d = new Decoder(bytes, file);
    d.fidelity = (layout.flags & RSCNB_FLAG_FIDELITY) != 0;
    const doc = new RscnDoc(file, layout.kind == <u32>RscnbKind.Material ? DocKind.Material : DocKind.Scene);
    doc.format = <i32>layout.format;
    if (!decodeInto(d, doc, ids, refs)) return invalid(file, d.why);
    if ((layout.flags & RSCNB_FLAG_ASSETS) != 0) {
        const why = assetTable(bytes, sectionOf(ids, refs, SECTION_ASSETS), d.strings, []);
        if (why.length > 0) return invalid(file, why);
    }
    numberElements(doc);
    return Result.okv<RscnDoc>(doc);
}

// Gives every element of a decoded document a position of its own: line
// 0 (a binary file has no lines; whereText prints the file alone) and, as
// the column, its ordinal in document order (1, 2, ...). The library tells
// a document's elements apart by their positions (a warning names the
// property it is about by where that is: warnings.as exportedProperty;
// two warnings at one place are one), so that positions which were all
// 0:0 would make every property of the file the same one.
function numberElements(doc: RscnDoc): void {
    let n = 0;
    for (let k = 0; k < doc.entries.length; k++) {
        const e = doc.entries[k];
        const ext = e.ext;
        if (ext != null) ext.pos = new XmlPos(0, ++n);
        const sub = e.sub != null ? e.sub : e.res;
        if (sub != null) {
            sub.pos = new XmlPos(0, ++n);
            n = numberItems(sub, n);
        }
        const node = e.node;
        if (node != null) {
            node.pos = new XmlPos(0, ++n);
            n = numberItems(node, n);
        }
        const c = e.connection;
        if (c != null) c.pos = new XmlPos(0, ++n);
        const em = e.embedded;
        if (em != null) {
            em.pos = new XmlPos(0, ++n);
            em.contentPos = em.pos;
        }
        const conv = e.converter;
        if (conv != null) {
            conv.where.file = doc.file;
            conv.where.line = 0;
            conv.where.col = ++n;
        }
        const ev = e.event;
        if (ev != null) {
            ev.pos = new XmlPos(0, ++n);
            for (let i = 0; i < ev.properties.length; i++) ev.properties[i].pos = new XmlPos(0, ++n);
            for (let i = 0; i < ev.bindings.length; i++) ev.bindings[i].pos = new XmlPos(0, ++n);
        }
        const an = e.animation;
        if (an != null) n = numberAnimation(an, n);
        const sm = e.stateMachine;
        if (sm != null) n = numberStateMachine(sm, n);
    }
}

// Milestone 45: an animation's elements, in document order.
function numberAnimation(a: LinearAnimationDecl, from: i32): i32 {
    let n = from;
    a.pos = new XmlPos(0, ++n);
    for (let i = 0; i < a.objects.length; i++) {
        const o = a.objects[i];
        o.pos = new XmlPos(0, ++n);
        for (let j = 0; j < o.properties.length; j++) {
            const p = o.properties[j];
            p.pos = new XmlPos(0, ++n);
            for (let k = 0; k < p.keys.length; k++) {
                const key = p.keys[k];
                key.pos = new XmlPos(0, ++n);
                const ip = key.interpolator;
                if (ip != null) ip.pos = new XmlPos(0, ++n);
            }
        }
    }
    return n;
}

function numberItems(d: Declaration, from: i32): i32 {
    let n = from;
    for (let k = 0; k < d.items.length; k++) {
        const b = d.items[k];
        const p = b.property;
        if (p != null) {
            p.pos = new XmlPos(0, ++n);
            p.valuePos = p.pos;
        } else if (b.kind == BodyKind.Group) {
            b.groupPos = new XmlPos(0, ++n);
        } else {
            const bd = b.binding;
            if (bd != null) bd.pos = new XmlPos(0, ++n);
        }
    }
    return n;
}

// Milestone 41: the bytes of section `id` of the .rscnb `bytes` (named
// `file` in errors; a view of `bytes`, no copy), or null when the file has
// no such section; fails as decodeRscnb does when the file's header,
// CRC or section table is not one this version reads. A section's bytes
// may end in up to 7 bytes of zeros (its padding to the next section's
// 8-byte boundary is not counted in its size, but a reader of a fixed
// layout reads only what it knows).
export function rscnbSection(bytes: Uint8Array, file: string, id: u32): Result<Uint8Array?> {
    const l = readLayout(bytes, file);
    if (!l.ok) return l.forward<Uint8Array?>();
    const k = l.value.ids.indexOf(id);
    if (k < 0) return Result.okv<Uint8Array?>(null);
    const ref = l.value.refs[k];
    return Result.okv<Uint8Array?>(bytes.subarray(ref.offset, ref.offset + ref.size));
}

function sectionOf(ids: Array<u32>, refs: Array<SectionRef>, id: u32): SectionRef {
    return refs[ids.indexOf(id)];
}

// A whole section read: its reader must be at its end (padding aside).
function finished(d: Decoder, r: BinReader, name: string): bool {
    if (!d.check(r, name)) return false;
    if (r.remaining() >= 8 || (r.remaining() > 0 && !zeros(r))) return d.fail("section " + name + " has bytes past its records");
    return true;
}

function zeros(r: BinReader): bool {
    while (r.remaining() > 0) if (r.u8() != 0) return false;
    return true;
}

class ItemRange {
    first: u32;
    count: u32;

    constructor(first: u32, count: u32) {
        this.first = first;
        this.count = count;
    }
}

function decodeInto(d: Decoder, doc: RscnDoc, ids: Array<u32>, refs: Array<SectionRef>): bool {
    // STRS, VALS.
    const rs = d.reader(sectionOf(ids, refs, SECTION_STRINGS));
    const strings = StringTable.read(rs);
    if (strings == null || !finished(d, rs, "STRS")) return d.fail("section STRS: " + (rs.failed ? rs.why : "damaged"));
    d.strings = strings;
    const rv = d.reader(sectionOf(ids, refs, SECTION_VALUES));
    const values = readValueTable(rv, strings);
    if (values == null || !finished(d, rv, "VALS")) return d.fail("section VALS: " + (rv.failed ? rv.why : "damaged"));
    d.values = values;
    d.valueUsed = new Uint8Array(values.length);

    // FIDL's nodes first: items and entries name them.
    let prolog = new Array<u32>();
    let epilog = new Array<u32>();
    let rf: BinReader? = null;
    if (d.fidelity) {
        const f = d.reader(sectionOf(ids, refs, SECTION_FIDELITY));
        const n = f.count(4);
        const texts = new Array<string>();
        for (let k = 0; k < n; k++) texts.push(d.str(f, f.u32()));
        prolog = u32ListOf(f);
        epilog = u32ListOf(f);
        if (!d.check(f, "FIDL")) return false;
        const nodes = parseXmlNodes(texts);
        if (nodes == null) return d.fail("section FIDL: its XML texts are not " + n.toString() + " well-formed nodes");
        d.xml = nodes;
        d.xmlUsed = new Uint8Array(nodes.length);
        rf = f;
    }

    // ITEM: read whole, then handed out by range.
    const ri = d.reader(sectionOf(ids, refs, SECTION_ITEMS));
    const nItems = ri.count(12);
    const itemKind = new Uint8Array(nItems);
    const itemFlags = new Uint8Array(nItems);
    const itemA = new Uint32Array(nItems);
    const itemB = new Uint32Array(nItems);
    for (let k = 0; k < nItems; k++) {
        itemKind[k] = <u8>ri.u8();
        itemFlags[k] = <u8>ri.u8();
        if (ri.u16() != 0) ri.fail("item " + k.toString() + "'s reserved bytes are not 0");
        itemA[k] = ri.u32();
        itemB[k] = ri.u32();
    }
    if (!finished(d, ri, "ITEM")) return false;

    // BIND: records, made into declarations as items name them.
    const rb = d.reader(sectionOf(ids, refs, SECTION_BINDINGS));
    const nBind = rb.count(24);
    const bindAt = rb.pos;
    rb.seek(rb.pos + nBind * 24);
    if (!finished(d, rb, "BIND")) return false;
    const bindUsed = new Uint8Array(nBind);
    d.binds = new Array<BindingDecl?>(nBind);

    // The items each SUBR and NODE record names, back to back from 0.
    const items = new Array<BodyItem>(nItems);

    // SUBR.
    const rsub = d.reader(sectionOf(ids, refs, SECTION_SUB));
    const nSub = rsub.count(16);
    const subs = new Array<SubResourceDecl>();
    const subRanges = new Array<ItemRange>();
    let nextItem: u32 = 0;
    for (let k = 0; k < nSub && !rsub.failed; k++) {
        const id = d.str(rsub, rsub.u32());
        const type = d.str(rsub, rsub.u32());
        const first = rsub.u32();
        const count = rsub.u32();
        if (rsub.failed) break;
        if (first != nextItem || <u64>first + <u64>count > <u64>nItems) {
            rsub.fail("sub_resource " + k.toString() + "'s items (" + first.toString() + ", " + count.toString()
                + ") are not the next " + count.toString() + " of " + nItems.toString());
            break;
        }
        nextItem = first + count;
        subs.push(new SubResourceDecl(id, type));
        subRanges.push(new ItemRange(first, count));
    }
    if (!finished(d, rsub, "SUBR")) return false;

    // NODE.
    const rn = d.reader(sectionOf(ids, refs, SECTION_NODES));
    const nNodes = rn.count(24);
    const nodes = new Array<NodeDecl>();
    const nodeRanges = new Array<ItemRange>();
    for (let k = 0; k < nNodes && !rn.failed; k++) {
        const parent = rn.u32();
        const name = d.str(rn, rn.u32());
        const type = d.optStr(rn, rn.u32());
        const inst = rn.u32();
        const first = rn.u32();
        const count = rn.u32();
        if (rn.failed) break;
        const n = new NodeDecl(name);
        n.type = type;
        if (parent == NONE) n.parent = null;
        else if ((parent & PARENT_STRING) != 0) n.parent = d.str(rn, parent & ~PARENT_STRING);
        else if (parent >= <u32>k) {
            rn.fail("node " + k.toString() + "'s parent (" + parent.toString() + ") is not an earlier node");
            break;
        } else n.parent = nodes[<i32>parent].path();
        if (inst != NONE) {
            const v = d.value(rn, inst);
            if (!rn.failed && v.kind != ValueKind.ExtResource) {
                rn.fail("node " + k.toString() + "'s instance is a " + v.kindName() + ", not an ExtResource");
                break;
            }
            n.instance = v;
        }
        if (first != nextItem || <u64>first + <u64>count > <u64>nItems) {
            rn.fail("node " + k.toString() + "'s items (" + first.toString() + ", " + count.toString()
                + ") are not the next " + count.toString() + " of " + nItems.toString());
            break;
        }
        nextItem = first + count;
        nodes.push(n);
        nodeRanges.push(new ItemRange(first, count));
    }
    if (!finished(d, rn, "NODE")) return false;
    if (nextItem != <u32>nItems) return d.fail("section ITEM: " + (<u32>nItems - nextItem).toString() + " items belong to nothing");

    // The bodies.
    for (let k = 0; k < subs.length; k++) {
        if (!makeBody(d, rb, bindAt, bindUsed, subs[k], subRanges[k], itemKind, itemFlags, itemA, itemB, items)) return false;
    }
    for (let k = 0; k < nodes.length; k++) {
        if (!makeBody(d, rb, bindAt, bindUsed, nodes[k], nodeRanges[k], itemKind, itemFlags, itemA, itemB, items)) return false;
    }

    // EXTR.
    const re = d.reader(sectionOf(ids, refs, SECTION_EXT));
    const nExt = re.count(16);
    const exts = new Array<ExtResourceDecl>();
    for (let k = 0; k < nExt && !re.failed; k++) {
        const id = d.str(re, re.u32());
        const type = d.str(re, re.u32());
        const path = d.str(re, re.u32());
        const ext = new ExtResourceDecl(id, type, path);
        ext.uid = d.optStr(re, re.u32());
        exts.push(ext);
    }
    if (!finished(d, re, "EXTR")) return false;

    // CONN.
    const rc = d.reader(sectionOf(ids, refs, SECTION_CONNECTIONS));
    const nConn = rc.count(20);
    const conns = new Array<ConnectionDecl>();
    for (let k = 0; k < nConn && !rc.failed; k++) {
        const signal = d.str(rc, rc.u32());
        const from = d.str(rc, rc.u32());
        const to = d.str(rc, rc.u32());
        const method = d.str(rc, rc.u32());
        const c = new ConnectionDecl(signal, from, to, method);
        c.flags = rc.i32();
        conns.push(c);
    }
    if (!finished(d, rc, "CONN")) return false;

    // EMBD.
    const rm = d.reader(sectionOf(ids, refs, SECTION_EMBEDDED));
    const nEmb = rm.count(32);
    const dataSize = rm.u32();
    const recordsAt = rm.pos;
    rm.seek(recordsAt + nEmb * 32);
    rm.align(8);
    const dataAt = rm.pos;
    if (!rm.failed && <u64>dataAt + <u64>dataSize > <u64>rm.size) rm.fail("its data (" + dataSize.toString() + " bytes) runs past the end");
    const embs = new Array<EmbeddedDecl>();
    const rawTexts = new Array<string>();
    const rawOf = new Array<i32>();
    if (!rm.failed) rm.seek(recordsAt);
    for (let k = 0; k < nEmb && !rm.failed; k++) {
        const path = d.str(rm, rm.u32());
        const why = d.str(rm, rm.u32());
        const xml = rm.u32();
        if (rm.u32() != 0) rm.fail("embedded file " + k.toString() + "'s reserved bytes are not 0");
        const offset = rm.u32();
        const len = rm.u32();
        const size = rm.i64();
        if (rm.failed) break;
        if (<u64>offset + <u64>len > <u64>dataSize) {
            rm.fail("embedded file " + k.toString() + " lies outside the data");
            break;
        }
        const data = new Uint8Array(<i32>len);
        if (len > 0) data.set(d.bytes.subarray(rm.start + dataAt + <i32>offset, rm.start + dataAt + <i32>offset + <i32>len), 0);
        const em = new EmbeddedDecl(path, data);
        em.size = size;
        em.invalid = why;
        if (xml != NONE) {
            rawTexts.push(d.str(rm, xml));
            rawOf.push(k);
        }
        embs.push(em);
    }
    if (!rm.failed) rm.seek(min<i32>(rm.size, dataAt + <i32>dataSize));
    if (!finished(d, rm, "EMBD")) return false;
    if (rawTexts.length > 0) {
        // Content that did not decode: the element as read, for the writer
        // to print back and the validator to report.
        const raws = parseXmlNodes(rawTexts);
        if (raws == null) return d.fail("section EMBD: an embedded file's element is not well-formed XML");
        for (let k = 0; k < raws.length; k++) {
            if (raws[k].kind != XmlKind.Element) return d.fail("section EMBD: an embedded file's element is not an element");
            embs[rawOf[k]].xml = raws[k];
        }
    }

    // FIDL's attributes and children, onto their owners.
    if (rf != null) {
        const f = rf;
        const nAttrs = f.count(16);
        for (let k = 0; k < nAttrs && !f.failed; k++) {
            const owner = f.u32();
            const index = f.u32();
            const a = new XmlAttr(d.str(f, f.u32()), d.str(f, f.u32()));
            if (f.failed) break;
            const target = attrsOf(f, owner, index, doc, exts, subs, nodes, conns, embs, items);
            if (target != null) target.push(a);
        }
        const nChildren = f.count(12);
        for (let k = 0; k < nChildren && !f.failed; k++) {
            const owner = f.u32();
            const index = f.u32();
            const node = d.xmlAt(f, f.u32());
            if (f.failed) break;
            if (owner == <u32>FidelityOwner.Ext && index < <u32>exts.length) exts[<i32>index].extraChildren.push(node);
            else if (owner == <u32>FidelityOwner.Connection && index < <u32>conns.length) conns[<i32>index].extraChildren.push(node);
            else f.fail("a child of owner " + owner.toString() + "/" + index.toString() + ", which cannot have one");
        }
        for (let k = 0; k < prolog.length && !f.failed; k++) doc.prolog.push(d.xmlAt(f, prolog[k]));
        for (let k = 0; k < epilog.length && !f.failed; k++) doc.epilog.push(d.xmlAt(f, epilog[k]));
        if (!finished(d, f, "FIDL")) return false;
    }

    // A once kept as an attribute (one the validator refuses: FIDL holds
    // it) is the binding's once again.
    for (let k = 0; k < d.binds.length; k++) {
        const b = d.binds[k];
        if (b == null) continue;
        for (let j = 0; j < b.attrs.length; j++) if (b.attrs[j].name == "once") b.once = b.attrs[j].value;
    }

    // BNDS (milestone 42): the bindings' extras, the scene's converters
    // (ORDR places them) and the project's.
    let sceneConverters = new Array<DataConverterDecl>();
    if (ids.includes(SECTION_BINDS)) {
        const ref = sectionOf(ids, refs, SECTION_BINDS);
        const why = new Array<string>();
        const data = decodeBnds(d.bytes.subarray(ref.offset, ref.offset + ref.size), nBind, why);
        if (data == null) return d.fail("section BNDS: " + why[0]);
        applyBindExtras(data, d.binds);
        sceneConverters = data.scene;
        for (let k = 0; k < data.project.length; k++) doc.projectConverters.push(data.project[k]);
    }

    // ANIM (milestone 45): the scene's events and animations (ORDR places
    // them).
    let events = new Array<EventDecl>();
    let animations = new Array<LinearAnimationDecl>();
    if (ids.includes(SECTION_ANIMATIONS)) {
        const ref = sectionOf(ids, refs, SECTION_ANIMATIONS);
        const why = new Array<string>();
        const data = decodeAnim(d.bytes.subarray(ref.offset, ref.offset + ref.size), d.fidelity, parseXmlNodes, why);
        if (data == null) return d.fail("section ANIM: " + why[0]);
        events = data.events;
        animations = data.animations;
    }

    // STMC (milestone 46): the scene's state machines (ORDR places them).
    let machines = new Array<StateMachineDecl>();
    if (ids.includes(SECTION_STATE_MACHINES)) {
        const ref = sectionOf(ids, refs, SECTION_STATE_MACHINES);
        const why = new Array<string>();
        const data = decodeStmc(d.bytes.subarray(ref.offset, ref.offset + ref.size), d.fidelity, parseXmlNodes, why);
        if (data == null) return d.fail("section STMC: " + why[0]);
        machines = data;
    }

    // ORDR: the document.
    const ro = d.reader(sectionOf(ids, refs, SECTION_ORDER));
    doc.uid = d.optStr(ro, ro.u32());
    const nOrder = ro.count(4);
    const extUsed = new Uint8Array(exts.length);
    const subUsed = new Uint8Array(subs.length);
    const nodeUsed = new Uint8Array(nodes.length);
    const connUsed = new Uint8Array(conns.length);
    const embUsed = new Uint8Array(embs.length);
    const convUsed = new Uint8Array(sceneConverters.length);
    const eventUsed = new Uint8Array(events.length);
    const animUsed = new Uint8Array(animations.length);
    const machineUsed = new Uint8Array(machines.length);
    for (let k = 0; k < nOrder && !ro.failed; k++) {
        const v = ro.u32();
        const kind = v >> 24;
        const index = <i32>(v & 0xFFFFFF);
        if (kind > <u32>EntryKind.StateMachine) {
            ro.fail("entry " + k.toString() + " is of an unknown kind (" + kind.toString() + ")");
            break;
        }
        const e = new Entry(<EntryKind>kind);
        if (kind == <u32>EntryKind.ExtResource) {
            if (!once(ro, extUsed, index, "ext_resource")) break;
            e.ext = exts[index];
        } else if (kind == <u32>EntryKind.SubResource || kind == <u32>EntryKind.Resource) {
            if (!once(ro, subUsed, index, "sub_resource")) break;
            if (kind == <u32>EntryKind.SubResource) e.sub = subs[index];
            else e.res = subs[index];
        } else if (kind == <u32>EntryKind.Node) {
            if (!once(ro, nodeUsed, index, "node")) break;
            e.node = nodes[index];
        } else if (kind == <u32>EntryKind.Connection) {
            if (!once(ro, connUsed, index, "connection")) break;
            e.connection = conns[index];
        } else if (kind == <u32>EntryKind.Embedded) {
            if (!once(ro, embUsed, index, "embedded file")) break;
            e.embedded = embs[index];
        } else if (kind == <u32>EntryKind.Converter) {
            if (!once(ro, convUsed, index, "converter")) break;
            e.converter = sceneConverters[index];
        } else if (kind == <u32>EntryKind.Event) {
            if (!once(ro, eventUsed, index, "event")) break;
            e.event = events[index];
        } else if (kind == <u32>EntryKind.Animation) {
            if (!once(ro, animUsed, index, "animation")) break;
            e.animation = animations[index];
        } else if (kind == <u32>EntryKind.StateMachine) {
            if (!once(ro, machineUsed, index, "state machine")) break;
            e.stateMachine = machines[index];
        } else {
            // Comment, Unknown: FIDL's.
            if (!d.fidelity) {
                ro.fail("a comment or unknown element in a file without fidelity");
                break;
            }
            e.xml = d.xmlAt(ro, <u32>index);
            if (kind == <u32>EntryKind.Comment && !ro.failed && e.xml!.kind != XmlKind.Comment) {
                ro.fail("entry " + k.toString() + " is a comment that is not one");
                break;
            }
        }
        doc.entries.push(e);
    }
    if (!finished(d, ro, "ORDR")) return false;
    // The kind in the header (outside the CRC) must be what the entries
    // are: a material document holds ext_resources, sub_resources (its
    // artboard textures) and its <resource>, a scene never a <resource>.
    const material = doc.kind == DocKind.Material;
    for (let k = 0; k < doc.entries.length; k++) {
        const kind = doc.entries[k].kind;
        if (material && (kind == EntryKind.Node || kind == EntryKind.Connection || kind == EntryKind.Embedded
            || kind == EntryKind.Converter || kind == EntryKind.Event || kind == EntryKind.Animation || kind == EntryKind.StateMachine)) {
            return d.fail("section ORDR: a material document holding a " + (kind == EntryKind.Node ? "node" : "scene's entry"));
        }
        if (!material && kind == EntryKind.Resource) return d.fail("section ORDR: a scene holding a material's <resource>");
    }
    if (!allUsed(d, extUsed, "ext_resource") || !allUsed(d, subUsed, "sub_resource") || !allUsed(d, nodeUsed, "node")
        || !allUsed(d, connUsed, "connection") || !allUsed(d, embUsed, "embedded file") || !allUsed(d, convUsed, "converter")
        || !allUsed(d, eventUsed, "event") || !allUsed(d, animUsed, "animation") || !allUsed(d, machineUsed, "state machine")) {
        return false;
    }
    if (d.fidelity) {
        for (let k = 0; k < d.xmlUsed.length; k++) {
            if (d.xmlUsed[k] == 0) return d.fail("section FIDL: XML node " + k.toString() + " belongs to nothing");
        }
    }
    for (let k = 0; k < bindUsed.length; k++) {
        if (bindUsed[k] == 0) return d.fail("section BIND: binding " + k.toString() + " belongs to no node");
    }
    return true;
}

function u32ListOf(r: BinReader): Array<u32> {
    const n = r.count(4);
    const out = new Array<u32>();
    for (let k = 0; k < n; k++) out.push(r.u32());
    return out;
}

function once(r: BinReader, used: Uint8Array, index: i32, what: string): bool {
    if (index >= used.length) {
        r.fail("a " + what + " index (" + index.toString() + ") past its " + used.length.toString());
        return false;
    }
    if (used[index] != 0) {
        r.fail(what + " " + index.toString() + " appears twice in the document");
        return false;
    }
    used[index] = 1;
    return true;
}

function allUsed(d: Decoder, used: Uint8Array, what: string): bool {
    for (let k = 0; k < used.length; k++) {
        if (used[k] == 0) return d.fail("section ORDR: " + what + " " + k.toString() + " is not in the document");
    }
    return true;
}

// The attribute list FIDL's owner names (null, with `r` failed, when there
// is no such owner).
function attrsOf(
    r: BinReader, owner: u32, index: u32, doc: RscnDoc, exts: Array<ExtResourceDecl>, subs: Array<SubResourceDecl>,
    nodes: Array<NodeDecl>, conns: Array<ConnectionDecl>, embs: Array<EmbeddedDecl>, items: Array<BodyItem>,
): Array<XmlAttr>? {
    const i = <i32>index;
    if (owner == <u32>FidelityOwner.Root && index == 0) return doc.rootAttrs;
    if (owner == <u32>FidelityOwner.Ext && index < <u32>exts.length) return exts[i].attrs;
    if (owner == <u32>FidelityOwner.Sub && index < <u32>subs.length) return subs[i].attrs;
    if (owner == <u32>FidelityOwner.Node && index < <u32>nodes.length) return nodes[i].attrs;
    if (owner == <u32>FidelityOwner.Connection && index < <u32>conns.length) return conns[i].attrs;
    if (owner == <u32>FidelityOwner.Embedded && index < <u32>embs.length) return embs[i].attrs;
    if (owner == <u32>FidelityOwner.Item && index < <u32>items.length) {
        const b = items[i];
        const p = b.property;
        if (p != null) return p.extraAttrs;
        if (b.kind == BodyKind.Group) return b.groupExtraAttrs;
        const bd = b.binding;
        if (bd != null) return bd.attrs;
    }
    r.fail("an attribute of owner " + owner.toString() + "/" + index.toString() + ", which has none");
    return null;
}

// The items of `decl` (its range of ITEM), made into BodyItems.
function makeBody(
    d: Decoder, rb: BinReader, bindAt: i32, bindUsed: Uint8Array, decl: Declaration, range: ItemRange,
    kinds: Uint8Array, flags: Uint8Array, a: Uint32Array, b: Uint32Array, items: Array<BodyItem>,
): bool {
    const r = new BinReader(d.bytes, 0, 0);
    for (let k = <i32>range.first; k < <i32>(range.first + range.count); k++) {
        const kind = <u32>kinds[k];
        if ((<u32>flags[k] & ~ITEM_CDATA) != 0 || (flags[k] != 0 && kind != <u32>BodyKind.Property)) {
            return d.fail("section ITEM: item " + k.toString() + " has unknown flags");
        }
        let item: BodyItem;
        if (kind == <u32>BodyKind.Property) {
            const p = new Property(d.str(r, a[k]), d.value(r, b[k]));
            p.cdata = flags[k] != 0;
            item = BodyItem.ofProperty(p);
        } else if (kind == <u32>BodyKind.Group) {
            item = BodyItem.ofGroup(d.str(r, a[k]));
        } else if (kind == <u32>BodyKind.Binding) {
            const i = <i32>a[k];
            if (a[k] >= <u32>bindUsed.length || bindUsed[i] != 0) {
                return d.fail("section ITEM: item " + k.toString() + " names binding " + a[k].toString()
                    + ", which is not there or is named twice");
            }
            bindUsed[i] = 1;
            rb.seek(bindAt + i * 24);
            const bd = new BindingDecl(d.str(rb, rb.u32()), d.str(rb, rb.u32()));
            bd.mode = d.str(rb, rb.u32());
            bd.scale = d.str(rb, rb.u32());
            bd.offset = d.str(rb, rb.u32());
            bd.convert = d.str(rb, rb.u32());
            if (!d.check(rb, "BIND")) return false;
            d.binds[i] = bd;
            item = BodyItem.ofBinding(bd);
        } else if (kind == <u32>BodyKind.Comment || kind == <u32>BodyKind.Unknown) {
            if (!d.fidelity) return d.fail("section ITEM: a comment or unknown element in a file without fidelity");
            const x = d.xmlAt(r, a[k]);
            if (kind == <u32>BodyKind.Comment && !r.failed && x.kind != XmlKind.Comment) {
                return d.fail("section ITEM: item " + k.toString() + " is a comment that is not one");
            }
            item = BodyItem.ofXml(<BodyKind>kind, x);
        } else {
            return d.fail("section ITEM: item " + k.toString() + " is of an unknown kind (" + kind.toString() + ")");
        }
        if (r.failed) return d.fail("section ITEM: item " + k.toString() + ": " + r.why);
        items[k] = item;
        decl.items.push(item);
    }
    return true;
}
