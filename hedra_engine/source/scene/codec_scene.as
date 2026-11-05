// A scene file's document whichever form it is in (milestone 39): the
// text .rscn (../rscn/parse.as) or the binary .rscnb (codec.as), chosen by
// the file's extension as the loader chooses. The tools that read a scene
// file's bytes themselves (the editor's prefetch and its watch, `format`,
// `inspect --xml`) go through here, so that an .rscnb is everywhere what
// its .rscn would be: the same document, the same canonical text.

import { Result } from "../../base/util";
import { RscnDoc } from "../../scene/rscn/doc";
import { parseRscn } from "../../scene/rscn/parse";
import { writeRscn } from "./rscn_write";
import { decodeRscnb } from "../../scene/rscnb/codec";
import { isRscnbPath } from "../../scene/rscnb/format";

export { isRscnbPath } from "../../scene/rscnb/format";

// Whether `path` names a scene file, text or binary (any case).
export function isSceneFilePath(path: string): bool {
    const n = path.length;
    if (n >= 5 && path.substring(n - 5).toLowerCase() == ".rscn") return true;
    return isRscnbPath(path);
}

// The document of a scene file's `bytes` (`path` says which form; `file`
// names it in errors).
export function readSceneDoc(bytes: Uint8Array, path: string, file: string): Result<RscnDoc> {
    return isRscnbPath(path) ? decodeRscnb(bytes, file) : parseRscn(bytes, file);
}

// The canonical text of a scene file's `bytes`: an .rscnb's decoded, an
// .rscn's as it parses; null when they do not read.
export function sceneCanonicalText(bytes: Uint8Array, path: string): string? {
    const r = readSceneDoc(bytes, path, path);
    return r.ok ? writeRscn(r.value) : null;
}

