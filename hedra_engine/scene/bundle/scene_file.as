// A self-contained scene (milestone 40): an .rscnb whose ASST section
// carries every asset the scene uses (../rscnb/format.as SECTION_ASSETS,
// RSCNB_FLAG_ASSETS), read as a bundle of that one scene, so that the
// run time (../runtime/scene_runtime.as SceneRuntime.loadSceneFile), the
// bundle's provider and every loader read it as they read any asset
// container (format.as): the file's assets are its entries, each a view of the
// file's bytes, and the scene itself is the entry of kind Scene named by
// its bundle path (`Bundle.main`), the whole file.
//
// The file is checked as decodeRscnb checks any .rscnb (the header, its
// CRC over the whole file, the section table, ASST's records: the codec's
// readRscnbAssets), then as a bundle's table is (Bundle.readIndex: one
// index naming scenes the file holds). Each asset's own CRC is checked
// when it is first used (Bundle.verified), as a bundle's; the scene's own
// entry is trusted, the header's CRC having covered it.
//
// docs/formats/RSCN.md, "Self-contained scenes", is normative; the writer
// is the tools' (compiler/src/bundle/scene_write.as).

import { Result } from "../../base/util";
import { crc32 } from "../../render/png";
import { SceneryError } from "../error";
import { BinReader } from "../rscnb/bin";
import { RscnbAsset, readRscnbAssets } from "../rscnb/codec";
import { RSCNB_FLAG_ASSETS, RSCNB_HEADER_BYTES, RscnbKind, looksLikeRscnb } from "../rscnb/format";
import { AssetKind, TocEntry, assetKindName } from "./format";
import { PAYLOAD_VERSION, readStr } from "./payload";
import { BUNDLE_INVALID_CODE, BUNDLE_INVALID_HINT, Bundle, compareEntries } from "./read";
import { CLI } from "../../base/names";

// The extension of a self-contained scene is .rscnb's: what tells one from
// a scene without assets is its RSCNB_FLAG_ASSETS flag (header byte 13).
// Nothing else is checked: sceneFileBundle checks the rest.
export function isSceneFile(bytes: Uint8Array): bool {
    if (bytes.length < RSCNB_HEADER_BYTES || !looksLikeRscnb(bytes)) return false;
    return (<u32>bytes[13] & RSCNB_FLAG_ASSETS) != 0;
}

function invalid<T>(file: string, why: string): Result<T> {
    return SceneryError.at(BUNDLE_INVALID_CODE, file, 0, 0, file + " is not a self-contained scene this version reads: "
        + why, BUNDLE_INVALID_HINT).fail<T>();
}

// The first scene the index entry `data` names (its payload: payload.as,
// compiler/src/bundle/encode.as encodeIndex), or null with `r`
// failed.
function firstScene(r: BinReader): string? {
    const v = r.u32();
    if (!r.failed && v != PAYLOAD_VERSION) {
        r.fail("its index is version " + v.toString());
        return null;
    }
    readStr(r);
    r.u32();
    const scenes = r.count(8);
    if (r.failed) return null;
    if (scenes == 0) {
        r.fail("its index names no scene");
        return null;
    }
    const path = readStr(r);
    return r.failed ? null : path;
}

// The bundle of the self-contained scene `bytes` (named `file` in errors):
// Bundle.main its bundle path, Bundle.scenes that scene first, then the
// scenes it carries (sub-scenes, scenes its scripts load), the index's
// features and scripts; code BUNDLE_INVALID_CODE (or the codec's
// rscnb-invalid) when the file is not a self-contained scene this version
// reads.
export function sceneFileBundle(bytes: Uint8Array, file: string): Result<Bundle> {
    if (looksLikeRscnb(bytes) && bytes.length >= RSCNB_HEADER_BYTES && !isSceneFile(bytes)) {
        return invalid<Bundle>(file, "it is a binary scene without its assets: build it with `" + CLI + " build` "
            + "(a built scene carries every asset it uses)");
    }
    const a = readRscnbAssets(bytes, file);
    if (!a.ok) return a.forward<Bundle>();
    if (a.value.kind != <u32>RscnbKind.Scene) return invalid<Bundle>(file, "it is a material document, not a scene");
    const records = a.value.assets;

    // The scene's own name: the index's first scene (read here, before the
    // table is whole: readIndex wants that scene in it).
    let index: RscnbAsset? = null;
    for (let i = 0; i < records.length && index == null; i++) {
        if (records[i].kind == <u32>AssetKind.Index && records[i].name.length == 0) index = records[i];
    }
    if (index == null) return invalid<Bundle>(file, "it has no index");
    const ix = index!;
    if (crc32(bytes, <i32>ix.offset, <i32>(ix.offset + ix.size)) != ix.crc) {
        return invalid<Bundle>(file, "its index is damaged (CRC)");
    }
    const ir = new BinReader(bytes, <i32>ix.offset, <i32>(ix.offset + ix.size));
    const main = firstScene(ir);
    if (main == null) return invalid<Bundle>(file, ir.why);

    // The table: the records, and the scene itself in its place (kind,
    // then name), the whole file.
    const b = new Bundle(bytes, file);
    const own = new TocEntry(<u32>AssetKind.Scene, main, 0, <u64>bytes.length);
    let added = false;
    for (let i = 0; i < records.length; i++) {
        const r = records[i];
        const order = compareEntries(own.kind, own.name, r.kind, r.name);
        if (order == 0) {
            return invalid<Bundle>(file, "it carries its own scene (" + assetKindName(r.kind) + " " + r.name + ") as an asset");
        }
        if (!added && order < 0) {
            b.addEntry(own);
            added = true;
        }
        const e = new TocEntry(r.kind, r.name, r.offset, r.size);
        e.crc = r.crc;
        b.addEntry(e);
    }
    if (!added) b.addEntry(own);
    b.trust(own);
    const ok = b.readIndex();
    if (!ok.ok) return ok.forward<Bundle>();
    b.main = main;
    return Result.okv<Bundle>(b);
}
