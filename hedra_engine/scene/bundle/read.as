// Reading the asset container (milestone 39; format.as lays it out), the
// one a built scene carries (scene_file.as): one pass
// over the header, the table of contents, the string table and the index,
// checked by their CRC, after which every asset is a view of the bytes,
// decoded only when a scene that uses it is instanced (provider.as).
//
// The reader trusts nothing (ENGINEERING.md pitfall 13): every field of the
// header must be the one value a writer of this version writes where it can
// only be one (the table right after the header, the strings right after
// the table, the data at the next aligned offset, the producer the first
// string after ""), so that any damaged byte of the header or of the table
// is an error rather than a different bundle; every entry must lie inside
// the file at an aligned offset, the table must be sorted with no name twice
// under one kind, and there must be one index. An asset's own CRC is
// checked when it is decoded (`verified`), so that loading reads only what
// is used.

import { Result } from "../../base/util";
import { crc32 } from "../../render/png";
import { SceneryError } from "../error";
import { BinReader, StringTable, stringAt } from "../rscnb/bin";
import {
    AssetKind, BUNDLE_ALIGN, BUNDLE_HEADER_BYTES, BUNDLE_MAGIC, BUNDLE_VERSION, TOC_ENTRY_BYTES, TocEntry, assetKindName,
    BUNDLE_ROOT, bundleAbs, sceneBundleName,
} from "./format";
import { PAYLOAD_VERSION, readStr } from "./payload";
import { CLI } from "../../base/names";

// The error code of a file that is not a bundle this version reads.
export const BUNDLE_INVALID_CODE = "bundle-invalid";

// The hint of every bundle-invalid error.
export const BUNDLE_INVALID_HINT = "build the scene again (`" + CLI + " build`): a built scene is read as written, "
    + "never edited; docs/formats/RSCN.md, \"Self-contained scenes\", is its format";

// A scene the bundle holds: its bundle path (".rscn" kept) and the bundle
// path of its project root, where its res:// paths start ("" for the
// bundle's root).
export class BundleScene {
    path: string;
    projectRoot: string;
    // Where its bundle is put in the run time's file system (format.as
    // bundleRootAt; Bundle.placeAt).
    root: string = BUNDLE_ROOT;

    constructor(path: string, projectRoot: string) {
        this.path = path;
        this.projectRoot = projectRoot;
    }

    // The scene's run-time absolute path (format.as BUNDLE_ROOT).
    abs(): string {
        return bundleAbs(this.path, this.root);
    }

    // Its project root's run-time absolute path.
    rootAbs(): string {
        return bundleAbs(this.projectRoot, this.root);
    }
}

// Two names compared as the table orders them: by their UTF-8 bytes, so
// that a reader in any language sorts them alike (UTF-16 code units would
// put a name above U+FFFF before one in U+E000..U+FFFF).
export function compareUtf8(a: string, b: string): i32 {
    const x = Uint8Array.wrap(String.UTF8.encode(a));
    const y = Uint8Array.wrap(String.UTF8.encode(b));
    const n = min<i32>(x.length, y.length);
    for (let i = 0; i < n; i++) {
        if (x[i] != y[i]) return <i32>x[i] - <i32>y[i];
    }
    return x.length - y.length;
}

// The table's order: by kind, then by name's bytes.
export function compareEntries(ak: u32, an: string, bk: u32, bn: string): i32 {
    if (ak != bk) return ak < bk ? -1 : 1;
    return compareUtf8(an, bn);
}

export class Bundle {
    // The file's bytes, which every asset is a view of.
    bytes: Uint8Array;
    // How errors name the file.
    file: string;
    // The index's: the container's name, "Hedra <version>", the features
    // its scenes use (../runtime/features.as FEATURE_*), the scenes in
    // bundle-path order, the scripts' bundle paths in that order.
    name: string = "";
    producer: string = "";
    features: u32 = 0;
    scenes: Array<BundleScene> = [];
    scripts: Array<string> = [];
    // Milestone 40: a self-contained scene's bundle path (scene_file.as
    // sceneFileBundle: the scene the file is, which `scenes` lists first);
    // "" for a container of several scenes.
    main: string = "";
    // Milestone 40: where the run time puts it in its file system
    // (format.as bundleRootAt): BUNDLE_ROOT unless its files would replace
    // another bundle's (provider.as BundleResources.mount).
    root: string = BUNDLE_ROOT;
    // The table of contents, in its order (kind, then name).
    entries: Array<TocEntry> = [];
    // By "<kind> <name>": the entry (find's lookup without a scan).
    private byKey: Map<string, TocEntry> = new Map<string, TocEntry>();
    // The entries whose CRC was checked (verified): offset to size. Two
    // entries sharing a range are checked once; the size is part of the
    // key because an empty entry takes the offset of the entry after it
    // (the writer aligns nothing past 0 bytes), and its check must not
    // stand for that entry's.
    private checked: Map<u64, u64> = new Map<u64, u64>();

    constructor(bytes: Uint8Array, file: string) {
        this.bytes = bytes;
        this.file = file;
    }

    // A bundle-invalid error at the file.
    invalid<T>(why: string): Result<T> {
        return SceneryError.at(BUNDLE_INVALID_CODE, this.file, 0, 0, this.file + " is not a bundle this version reads: " + why,
            BUNDLE_INVALID_HINT).fail<T>();
    }

    // Reads the header, the table, the strings and the index (code
    // BUNDLE_INVALID_CODE when the file is not a bundle this version reads:
    // bad magic, a newer version, a damaged table, an entry past the end,
    // a CRC that does not match).
    static parse(bytes: Uint8Array, file: string): Result<Bundle> {
        const b = new Bundle(bytes, file);
        const n = bytes.length;
        if (n < BUNDLE_HEADER_BYTES) return b.invalid<Bundle>("it is " + n.toString() + " bytes, shorter than a header");
        for (let i = 0; i < BUNDLE_MAGIC.length; i++) {
            if (bytes[i] != BUNDLE_MAGIC[i]) return b.invalid<Bundle>("its first bytes are not a bundle's");
        }
        const h = new BinReader(bytes, 0, BUNDLE_HEADER_BYTES);
        h.seek(BUNDLE_MAGIC.length);
        const version = h.u16();
        const flags = h.u16();
        const count = h.u32();
        const size = h.u64();
        const toc = h.u32();
        const tocBytes = h.u32();
        const strings = h.u32();
        const strBytes = h.u32();
        const crc = h.u32();
        const data = h.u32();
        const align = h.u32();
        const producer = h.u32();
        const reserved = h.u64();
        if (version != BUNDLE_VERSION) {
            return b.invalid<Bundle>(version > BUNDLE_VERSION
                ? "it is version " + version.toString() + ", newer than this reader's " + BUNDLE_VERSION.toString()
                : "its version (" + version.toString() + ") is not one a writer made");
        }
        if (flags != 0 || reserved != 0) return b.invalid<Bundle>("its header's reserved fields are not zero");
        if (size != <u64>n) return b.invalid<Bundle>("its header says " + size.toString() + " bytes and it has " + n.toString());
        if (align != <u32>BUNDLE_ALIGN) return b.invalid<Bundle>("its alignment is " + align.toString() + ", not " + BUNDLE_ALIGN.toString());
        if (toc != <u32>BUNDLE_HEADER_BYTES || <u64>tocBytes != <u64>count * <u64>TOC_ENTRY_BYTES) {
            return b.invalid<Bundle>("its table of contents is not where its header says");
        }
        if (<u64>strings != <u64>toc + <u64>tocBytes || <u64>strings + <u64>strBytes > <u64>n) {
            return b.invalid<Bundle>("its string table is not where its header says");
        }
        const dataAt = (<u64>strings + <u64>strBytes + <u64>(BUNDLE_ALIGN - 1)) & ~<u64>(BUNDLE_ALIGN - 1);
        if (<u64>data != dataAt || <u64>data > <u64>n) return b.invalid<Bundle>("its data does not start where its header says");
        if (crc32(bytes, BUNDLE_HEADER_BYTES, <i32>data) != crc) {
            return b.invalid<Bundle>("its table of contents or string table is damaged (CRC)");
        }
        const sr = new BinReader(bytes, <i32>strings, <i32>(strings + strBytes));
        const table = StringTable.read(sr);
        if (table == null) return b.invalid<Bundle>("its string table is damaged: " + sr.why);
        if (sr.pos != sr.size) return b.invalid<Bundle>("its string table does not fill its " + strBytes.toString() + " bytes");
        // The writer interns the producer first.
        if (producer != 1 || table.length < 2) return b.invalid<Bundle>("its producer is not its first string");
        b.producer = table[1];

        const tr = new BinReader(bytes, <i32>toc, <i32>(toc + tocBytes));
        let prevKind: u32 = 0;
        let prevName = "";
        for (let i: u32 = 0; i < count; i++) {
            const kind = tr.u32();
            const name = stringAt(tr, table, tr.u32());
            const offset = tr.u64();
            const len = tr.u64();
            const eflags = tr.u32();
            const ecrc = tr.u32();
            if (tr.failed) return b.invalid<Bundle>("its table of contents is damaged: " + tr.why);
            const what = assetKindName(kind) + " " + name;
            if (eflags != 0) return b.invalid<Bundle>("entry " + what + " has flags this version does not know");
            if (offset < <u64>data || (offset & <u64>(BUNDLE_ALIGN - 1)) != 0 || offset + len > <u64>n || offset + len < offset) {
                return b.invalid<Bundle>("entry " + what + " lies outside the data");
            }
            if (i > 0 && compareEntries(prevKind, prevName, kind, name) >= 0) {
                return b.invalid<Bundle>("its table of contents is not sorted, or names " + what + " twice");
            }
            prevKind = kind;
            prevName = name;
            const e = new TocEntry(kind, name, offset, len);
            e.crc = ecrc;
            b.addEntry(e);
        }
        const ok = b.readIndex();
        if (!ok.ok) return ok.forward<Bundle>();
        return Result.okv<Bundle>(b);
    }

    // Adds `e` to the table (its reader's order: kind, then name), for a
    // reader that builds a bundle from another container (milestone 40:
    // scene_file.as, a self-contained scene's ASST section).
    addEntry(e: TocEntry): void {
        this.entries.push(e);
        this.byKey.set(e.kind.toString() + " " + e.name, e);
    }

    // Records `e`'s bytes as checked, so that `verified` does not compute
    // its CRC (milestone 40: a self-contained scene's own entry, the whole
    // file, whose header's CRC the codec checks).
    trust(e: TocEntry): void {
        if (e.size > 0) this.checked.set(e.offset, e.size);
    }

    // Reads the index entry (AssetKind.Index, named ""): the name, the
    // features, the scenes and their roots, the scripts; bundle-invalid
    // when it is missing or damaged, or names a scene the table does not
    // hold.
    readIndex(): Result<bool> {
        const b = this;
        const index = b.find(AssetKind.Index, "");
        if (index == null) return b.invalid<bool>("it has no index");
        const ok = b.verified(index);
        if (!ok.ok) return ok.forward<bool>();
        const ir = new BinReader(b.data(index));
        const iv = ir.u32();
        if (!ir.failed && iv != PAYLOAD_VERSION) return b.invalid<bool>("its index is version " + iv.toString());
        b.name = readStr(ir);
        b.features = ir.u32();
        const scenes = ir.count(8);
        for (let i = 0; i < scenes && !ir.failed; i++) {
            const path = readStr(ir);
            const root = readStr(ir);
            b.scenes.push(new BundleScene(path, root));
        }
        const scripts = ir.count(4);
        for (let i = 0; i < scripts && !ir.failed; i++) b.scripts.push(readStr(ir));
        if (ir.failed) return b.invalid<bool>("its index is damaged: " + ir.why);
        if (ir.pos != ir.size) return b.invalid<bool>("its index has bytes after its end");
        for (let i = 0; i < b.scenes.length; i++) {
            if (b.find(AssetKind.Scene, b.scenes[i].path) == null) {
                return b.invalid<bool>("its index names the scene " + b.scenes[i].path + ", which it does not hold");
            }
        }
        return Result.okv<bool>(true);
    }

    // The entry of `kind` named `name`, or null.
    find(kind: AssetKind, name: string): TocEntry? {
        const k = (<u32>kind).toString() + " " + name;
        return this.byKey.has(k) ? this.byKey.get(k) : null;
    }

    // The bytes of `e`: a view of the file, no copy.
    data(e: TocEntry): Uint8Array {
        return this.bytes.subarray(<i32>e.offset, <i32>(e.offset + e.size));
    }

    // `e`'s bytes, their CRC checked the first time (bundle-invalid when it
    // does not match: a damaged asset fails the load that uses it).
    verified(e: TocEntry): Result<Uint8Array> {
        const d = this.data(e);
        if (!this.checked.has(e.offset) || this.checked.get(e.offset) != e.size) {
            if (crc32(this.bytes, <i32>e.offset, <i32>(e.offset + e.size)) != e.crc) {
                return this.invalid<Uint8Array>("its " + assetKindName(e.kind) + " " + e.name + " is damaged (CRC)");
            }
            // (an empty range is not recorded: checking it costs nothing)
            if (e.size > 0) this.checked.set(e.offset, e.size);
        }
        return Result.okv<Uint8Array>(d);
    }

    // Puts the bundle and its scenes at `root` (format.as bundleRootAt).
    placeAt(root: string): void {
        this.root = root;
        for (let i = 0; i < this.scenes.length; i++) this.scenes[i].root = root;
    }

    // The scene at bundle path `path` (".rscnb" or ".rscn": format.as
    // sceneBundleName), or null.
    scene(path: string): BundleScene? {
        const name = sceneBundleName(path);
        for (let i = 0; i < this.scenes.length; i++) if (this.scenes[i].path == name) return this.scenes[i];
        return null;
    }
}
