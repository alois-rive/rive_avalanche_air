// What an ArtboardTexture draws as where its artboard cannot be drawn
// (milestone 15): in the CLI's `render`, the preview and the editor, whose
// host has no way to load another Rive file or to draw an artboard into a
// texture (docs/formats/RSCN.md, "ArtboardTexture"), and in a built
// project until the artboard's first frame is drawn. A checker of two
// greys in the texture's aspect, so the surface's UVs read, with the
// artboard's name and a second line (the file and the state machine) in
// the middle, so a picture says what will play there.
//
// Pure and deterministic: the same arguments give the same pixels, so the
// render goldens that show one hold.

import { Image, Rgba } from "../../render/image";
import { drawLabel, textHeight, textWidth } from "../../render/font";
import { LABEL_BG, LABEL_FG, labelScale } from "../../render/composite";

// The placeholder's longest side, in pixels: enough for its labels, small
// enough that a scene of many artboard textures uploads little. A texture
// smaller than this keeps its own size.
export const PLACEHOLDER_MAX_SIDE: u32 = 512;

// The checker's two greys (sRGB) and its cell, in pixels of the
// placeholder.
export const PLACEHOLDER_DARK: Rgba = Rgba(88, 92, 102, 255);
export const PLACEHOLDER_LIGHT: Rgba = Rgba(122, 128, 140, 255);
export const PLACEHOLDER_CELL: u32 = 32;

// The placeholder's size for a texture of `width` x `height` pixels (each
// at least 1): the same aspect, its longest side PLACEHOLDER_MAX_SIDE at
// most, each side at least 1. [width, height].
export function placeholderSize(width: i32, height: i32): StaticArray<u32> {
    const w = max<i32>(width, 1);
    const h = max<i32>(height, 1);
    const longest = max<i32>(w, h);
    if (longest <= <i32>PLACEHOLDER_MAX_SIDE) return [<u32>w, <u32>h];
    const s = <f64>PLACEHOLDER_MAX_SIDE / <f64>longest;
    return [max<u32>(<u32>Math.round(<f64>w * s), 1), max<u32>(<u32>Math.round(<f64>h * s), 1)];
}

// What the title says when the texture names no artboard.
export const NO_ARTBOARD_TITLE = "(no artboard)";

// The scale the title and the detail start from, for a placeholder `height`
// pixels high: labelScale's (the render sheets' labels), raised so that the
// labels stay readable once the texture is shrunk onto a surface: the
// title's glyphs about a ninth of the height (7 rows at height / 64), the
// detail's about a twelfth (height / 80), each lowered until its label
// fits the width (fittedScale).
export function titleScale(height: u32): u32 {
    return max<u32>(labelScale(height), height / 64);
}

export function detailScale(height: u32): u32 {
    return max<u32>(labelScale(height), height / 80);
}

// The largest scale from `start` down to 1 at which `text`'s label (its box
// one scale wider on each side, and one more of margin) fits `width`.
function fittedScale(text: string, start: u32, width: u32): u32 {
    let s = max<u32>(start, 1);
    while (s > 1 && textWidth(text, s) + 4 * s > width) s--;
    return s;
}

// `text` cut to fit `width` at scale 1, "..." ending what is cut; "" when
// not even that fits. (fillRect clips a label wider than the image, but a
// label centred on a narrow image would lose both ends.)
export function fittedText(text: string, width: u32): string {
    if (textWidth(text, 1) + 4 <= width) return text;
    let t = text;
    while (t.length > 0) {
        // One code point off the end (two units for a surrogate pair).
        const last = t.charCodeAt(t.length - 1);
        const cut = last >= 0xdc00 && last <= 0xdfff && t.length >= 2 ? 2 : 1;
        t = t.substring(0, t.length - cut);
        if (textWidth(t + "...", 1) + 4 <= width) return t + "...";
    }
    return textWidth("...", 1) + 4 <= width ? "..." : "";
}

// The placeholder of a texture of `width` x `height` pixels: the checker
// (the cell at the top-left dark), `title` (the artboard's name, or
// NO_ARTBOARD_TITLE when "") centred just above the middle and `detail`
// (e.g. "ui/screen.riv, Main"; none when "") centred just below it, each on
// the translucent box of the render sheets' labels.
export function artboardPlaceholder(title: string, detail: string, width: i32, height: i32): Image {
    const size = placeholderSize(width, height);
    const w = size[0];
    const h = size[1];
    const img = Image.new(w, h, PLACEHOLDER_DARK);
    const cell = <i32>PLACEHOLDER_CELL;
    for (let y = 0; y < <i32>h; y += cell) {
        for (let x = 0; x < <i32>w; x += cell) {
            if (((x / cell) + (y / cell)) % 2 == 1) img.fillRect(x, y, cell, cell, PLACEHOLDER_LIGHT);
        }
    }
    let top = title.length > 0 ? title : NO_ARTBOARD_TITLE;
    const ts = fittedScale(top, titleScale(h), w);
    if (ts == 1) top = fittedText(top, w);
    let bottom = detail;
    const ds = fittedScale(bottom, detailScale(h), w);
    if (ds == 1) bottom = fittedText(bottom, w);
    // The boxes are one scale wider than their text on every side; a gap of
    // the larger scale between them, centred on the middle row.
    const mid = <i32>h / 2;
    const gap = <i32>max<u32>(ts, ds);
    if (top.length > 0) {
        const y = mid - gap / 2 - <i32>ts - <i32>textHeight(ts);
        drawLabel(img, (<i32>w - <i32>textWidth(top, ts)) / 2, y, top, ts, LABEL_FG, LABEL_BG);
    }
    if (bottom.length > 0) {
        const y = mid + (gap - gap / 2) + <i32>ds;
        drawLabel(img, (<i32>w - <i32>textWidth(bottom, ds)) / 2, y, bottom, ds, LABEL_FG, LABEL_BG);
    }
    return img;
}
