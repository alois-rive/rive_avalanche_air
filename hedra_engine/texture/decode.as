// Milestone 26: the decoders behind one call. Every program and the
// run time use it: a device that takes none of a texture's
// forms draws it decoded here (render/material.as MaterialBinder), and
// the tools decode to compare (the CLI's `import`'s PSNR, the tests).

import { Result } from "../base/util";
import { Image } from "../render/image";
import { BlockFormat, CompressedImage, blockFormatName, levelBytes } from "./format";
import { decodeBc1, decodeBc3, decodeBc7 } from "./bc_decode";
import { decodeEtc2Rgb, decodeEtc2Rgba } from "./etc_decode";
import { decodeAstc } from "./astc_decode";

// One level of `format`, w x h texels, from `data` (exactly levelBytes of
// it, else a failure naming the sizes).
export function decodeLevel(format: BlockFormat, data: Uint8Array, w: u32, h: u32): Result<Image> {
    const need = levelBytes(format, w, h);
    if (<u32>data.length != need) {
        return Result.fail<Image>("a " + w.toString() + " x " + h.toString() + " " + blockFormatName(format)
            + " level takes " + need.toString() + " bytes, not " + data.length.toString());
    }
    switch (format) {
        case BlockFormat.Rgba8: return Result.okv<Image>(new Image(w, h, data.slice(0)));
        case BlockFormat.Bc1: return Result.okv<Image>(decodeBc1(data, w, h));
        case BlockFormat.Bc3: return Result.okv<Image>(decodeBc3(data, w, h));
        case BlockFormat.Bc7: return Result.okv<Image>(decodeBc7(data, w, h));
        case BlockFormat.Etc2Rgb: return Result.okv<Image>(decodeEtc2Rgb(data, w, h));
        case BlockFormat.Etc2Rgba: return Result.okv<Image>(decodeEtc2Rgba(data, w, h));
        case BlockFormat.Astc4x4: return Result.okv<Image>(decodeAstc(data, w, h, 4, 4));
        case BlockFormat.Astc6x6: return Result.okv<Image>(decodeAstc(data, w, h, 6, 6));
        case BlockFormat.Astc8x8: return Result.okv<Image>(decodeAstc(data, w, h, 8, 8));
        default: return Result.fail<Image>("unknown block format " + (<i32>format).toString());
    }
}

// Every level, decoded.
export function decompress(ci: CompressedImage): Result<Array<Image>> {
    const out = new Array<Image>();
    for (let i = 0; i < ci.levels.length; i++) {
        const l = ci.levels[i];
        const r = decodeLevel(ci.format, l.data, l.width, l.height);
        if (!r.ok) return r.forward<Array<Image>>();
        out.push(r.value);
    }
    return Result.okv<Array<Image>>(out);
}
