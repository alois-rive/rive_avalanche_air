// The warning label (milestone 41, docs/plans/BUILD.md section 7): one
// line in the scene canvas's top-right corner when Auto drew a scene from
// its text ("Not built: world/courtyard.rscn", "Out of date: ...",
// "Built for Hedra 2: ...", "Not built, no source readers: ..."), white
// capitals on a translucent dark rectangle, drawn after the scene by the
// instance's draw so a screenshot shows it and the scene's own pixels are
// unchanged outside its rectangle. The pinned rive has no text API for
// scripts, so the label draws its glyphs as stroked paths (rive/path,
// rive/paint) from a small font of its own: capitals, digits, space and
// `:/._-,`; lowercase letters are drawn as capitals and any other character
// as `-`.
//
// The geometry, in points (multiplied by the canvas's pixels per point):
//   each glyph advances LABEL_ADVANCE, its capitals LABEL_CAP high, stroked
//   LABEL_STROKE wide; the rectangle is LABEL_PAD around the text on every
//   side (so LABEL_CAP + 2 * LABEL_PAD high, n * LABEL_ADVANCE + 2 *
//   LABEL_PAD wide for n characters), its corners rounded by LABEL_RADIUS,
//   LABEL_MARGIN from the canvas's top and right edges. Text that would not
//   fit the canvas's width less two margins loses characters from the start
//   of its scene path, "..." standing for them; when even the first words
//   and "..." do not fit, no label is drawn. The rectangle is filled with
//   LABEL_FILL, the glyphs stroked with LABEL_INK.
//
// It costs nothing when not shown and allocates nothing per frame when
// shown: its paths are built once per text and size.
//
// The font: each glyph is a few strokes (polylines) in a box 5 units wide
// and 9 high (y down, 9 the baseline), one unit LABEL_CAP / 9 points, the
// glyph centred in its LABEL_ADVANCE cell; stroked LABEL_STROKE wide with
// round caps and joins, so a short stroke is a dot. Round letters are
// octagons: at 9 points high the corners read as curves.
//
// Drawn in the layout's points (the instance's draw presents its picture
// scaled to points too), so the rectangle in a screenshot is labelRect
// times the canvas's pixels per point.

import { Renderer as HostRenderer } from "rive/renderer";
import { Color } from "rive/color";
import { Paint, PaintStyle, StrokeCap, StrokeJoin } from "rive/paint";
import { Path } from "rive/path";
import { Vector } from "rive/vector";
import { REASON_NO_SOURCE_READERS, REASON_NOT_BUILT, REASON_OTHER_MAJOR, REASON_OUT_OF_DATE } from "./sources";

export const LABEL_ADVANCE: f64 = 7;
export const LABEL_CAP: f64 = 9;
export const LABEL_STROKE: f64 = 1.5;
export const LABEL_PAD: f64 = 5;
export const LABEL_RADIUS: f64 = 3;
export const LABEL_MARGIN: f64 = 8;
// 0xAARRGGBB
export const LABEL_FILL: u32 = 0xB3101418;
export const LABEL_INK: u32 = 0xFFFFFFFF;
export const LABEL_ELLIPSIS = "...";

// The label's text for Auto's `reason` and the scene's path in the Rive
// project, before it is fitted (labelFit).
export function labelText(reason: string, scenePath: string): string {
    if (reason == REASON_NOT_BUILT) return "Not built: " + scenePath;
    if (reason == REASON_OUT_OF_DATE) return "Out of date: " + scenePath;
    if (reason.startsWith(REASON_OTHER_MAJOR)) return "Built for Hedra " + reason.substring(REASON_OTHER_MAJOR.length) + ": " + scenePath;
    if (reason == REASON_NO_SOURCE_READERS) return "Not built, no source readers: " + scenePath;
    return reason + ": " + scenePath;
}

// `text` fitted to a canvas `width` points wide (see the header): itself,
// its head (up to and including ": ") then "..." then the end of its path,
// or "" when nothing fits.
export function labelFit(text: string, width: f64): string {
    const room = width - 2 * LABEL_MARGIN - 2 * LABEL_PAD;
    if (fitsIn(text.length, room)) return text;
    const colon = text.indexOf(": ");
    if (colon < 0) return "";
    const head = text.substring(0, colon + 2) + LABEL_ELLIPSIS;
    if (!fitsIn(head.length, room)) return "";
    const tail = text.substring(colon + 2);
    let drop = 1;
    while (drop < tail.length && !fitsIn(head.length + tail.length - drop, room)) drop++;
    return head + tail.substring(drop);
}

// Whether `n` characters fit `room` points.
function fitsIn(n: i32, room: f64): bool {
    return <f64>n * LABEL_ADVANCE <= room;
}

// The rectangle of the label of `text` (already fitted) on a canvas
// `width` points wide: [x, y, w, h] in points; [0, 0, 0, 0] for "".
export function labelRect(text: string, width: f64): StaticArray<f64> {
    const r = new StaticArray<f64>(4);
    if (text.length == 0) return r;
    const w = <f64>text.length * LABEL_ADVANCE + 2 * LABEL_PAD;
    const h = LABEL_CAP + 2 * LABEL_PAD;
    r[0] = width - LABEL_MARGIN - w;
    r[1] = LABEL_MARGIN;
    r[2] = w;
    r[3] = h;
    return r;
}

// The glyphs the font has, in the order of GLYPHS below.
export const LABEL_GLYPHS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :/._-,";

// Each glyph's strokes: points "x,y" apart by spaces, strokes apart by "|"
// (see the header for the box).
const GLYPHS: StaticArray<string> = [
    "0,9 0,2 1.5,0 3.5,0 5,2 5,9 | 0,5.5 5,5.5",
    "0,9 0,0 4,0 5,1 5,3.5 4,4.5 0,4.5 | 4,4.5 5,5.5 5,8 4,9 0,9",
    "5,1 4,0 1,0 0,1 0,8 1,9 4,9 5,8",
    "0,0 3,0 5,2 5,7 3,9 0,9 0,0",
    "5,0 0,0 0,9 5,9 | 0,4.5 4,4.5",
    "5,0 0,0 0,9 | 0,4.5 4,4.5",
    "5,1 4,0 1,0 0,1 0,8 1,9 4,9 5,8 5,5 3,5",
    "0,0 0,9 | 5,0 5,9 | 0,4.5 5,4.5",
    "1,0 4,0 | 2.5,0 2.5,9 | 1,9 4,9",
    "2,0 5,0 | 4,0 4,8 3,9 1,9 0,8 0,7",
    "0,0 0,9 | 5,0 0,5.5 | 2,3.5 5,9",
    "0,0 0,9 5,9",
    "0,9 0,0 2.5,5 5,0 5,9",
    "0,9 0,0 5,9 5,0",
    "1,0 4,0 5,1 5,8 4,9 1,9 0,8 0,1 1,0",
    "0,9 0,0 4,0 5,1 5,4 4,5 0,5",
    "1,0 4,0 5,1 5,8 4,9 1,9 0,8 0,1 1,0 | 3,6.5 5,9",
    "0,9 0,0 4,0 5,1 5,4 4,5 0,5 | 2.5,5 5,9",
    "5,1 4,0 1,0 0,1 0,3.5 1,4.5 4,4.5 5,5.5 5,8 4,9 1,9 0,8",
    "0,0 5,0 | 2.5,0 2.5,9",
    "0,0 0,8 1,9 4,9 5,8 5,0",
    "0,0 2.5,9 5,0",
    "0,0 1,9 2.5,4 4,9 5,0",
    "0,0 5,9 | 5,0 0,9",
    "0,0 2.5,4.5 5,0 | 2.5,4.5 2.5,9",
    "0,0 5,0 0,9 5,9",
    "1,0 4,0 5,1 5,8 4,9 1,9 0,8 0,1 1,0 | 4.5,1 0.5,8",
    "1,2 3,0 3,9 | 1,9 5,9",
    "0,1 1,0 4,0 5,1 5,3.5 0,9 5,9",
    "0,1 1,0 4,0 5,1 5,3.5 4,4.5 1.5,4.5 | 4,4.5 5,5.5 5,8 4,9 1,9 0,8",
    "4,9 4,0 0,6 5,6",
    "5,0 0,0 0,4 4,4 5,5 5,8 4,9 1,9 0,8",
    "4,0 1,0 0,1 0,8 1,9 4,9 5,8 5,5.5 4,4.5 0,4.5",
    "0,0 5,0 1.5,9",
    "1,0 4,0 5,1 5,3.5 4,4.5 1,4.5 0,3.5 0,1 1,0 | 1,4.5 0,5.5 0,8 1,9 4,9 5,8 5,5.5 4,4.5",
    "5,4.5 1,4.5 0,3.5 0,1 1,0 4,0 5,1 5,8 4,9 1,9",
    "",
    "2.5,2.5 2.5,2.6 | 2.5,6.9 2.5,7",
    "4.5,0 0.5,9",
    "2.5,8.9 2.5,9",
    "0,9 5,9",
    "1,4.5 4,4.5",
    // (the comma: a dot with a tail to the baseline, inside the box)
    "3,7.2 3,8 1.8,9",
];

// The glyph box's width and height in units.
export const GLYPH_UNITS_WIDE: f64 = 5;
export const GLYPH_UNITS_HIGH: f64 = 9;

// The index in LABEL_GLYPHS of the glyph that draws character code `c`:
// lowercase letters draw as capitals, a character the font lacks as "-".
export function labelGlyph(c: i32): i32 {
    if (c >= 0x61 && c <= 0x7a) c -= 0x20;
    if (c >= 0x41 && c <= 0x5a) return c - 0x41;
    if (c >= 0x30 && c <= 0x39) return 26 + c - 0x30;
    if (c == 0x20) return 36;
    if (c == 0x3a) return 37;
    if (c == 0x2f) return 38;
    if (c == 0x2e) return 39;
    if (c == 0x5f) return 40;
    if (c == 0x2c) return 42;
    return 41;
}

// The glyphs' strokes as numbers, parsed once: x, y pairs, NaN between
// strokes.
let glyphPoints: Array<StaticArray<f32>>? = null;

// The points of glyph `g` (labelGlyph): x, y pairs in units, a NaN pair
// between strokes.
export function glyphStrokes(g: i32): StaticArray<f32> {
    let all = glyphPoints;
    if (all == null) {
        all = new Array<StaticArray<f32>>();
        for (let i = 0; i < GLYPHS.length; i++) all.push(parseGlyph(GLYPHS[i]));
        glyphPoints = all;
    }
    return all[g];
}

function parseGlyph(text: string): StaticArray<f32> {
    const out = new Array<f32>();
    const strokes = text.split("|");
    for (let s = 0; s < strokes.length; s++) {
        const pts = strokes[s].trim().split(" ");
        if (out.length > 0) {
            out.push(NaN);
            out.push(NaN);
        }
        for (let p = 0; p < pts.length; p++) {
            const pt = pts[p].trim();
            if (pt.length == 0) continue;
            const comma = pt.indexOf(",");
            out.push(<f32>parseFloat(pt.substring(0, comma)));
            out.push(<f32>parseFloat(pt.substring(comma + 1)));
        }
    }
    return StaticArray.fromArray<f32>(out);
}

// 0xAARRGGBB as a Color.
function colorOf(argb: u32): Color {
    return Color.rgba(<i32>((argb >> 16) & 0xff), <i32>((argb >> 8) & 0xff), <i32>(argb & 0xff), <i32>(argb >> 24));
}

// One instance's label: its text (set when Auto falls back; "" hides it)
// and the paths drawn for it, made once per text and size.
export class UnbuiltLabel {
    text: string = "";
    // What the paths show: the text fitted to the width (labelFit; "" when
    // nothing fits), and its rectangle in points (labelRect).
    fitted: string = "";
    rect: StaticArray<f64> = new StaticArray<f64>(4);
    // How many times the paths were built (tests: once per text and size).
    builds: i32 = 0;
    // What they were built for.
    private builtText: string = "";
    private builtWidth: f64 = -1;
    private builtScale: f64 = -1;
    private fill: Path? = null;
    private ink: Path? = null;
    private fillPaint: Paint? = null;
    private inkPaint: Paint? = null;

    setText(text: string): void {
        this.text = text;
    }

    // Builds the paths for a canvas `width` points wide at `scale` pixels
    // per point when they were built for something else; whether there is
    // anything to draw. Allocates nothing when nothing changed.
    prepare(width: f64, height: f64, scale: f64): bool {
        if (this.text.length == 0) return false;
        if (this.text == this.builtText && width == this.builtWidth && scale == this.builtScale) return this.fitted.length > 0;
        this.builtText = this.text;
        this.builtWidth = width;
        this.builtScale = scale;
        this.builds++;
        this.fitted = labelFit(this.text, width);
        const r = labelRect(this.fitted, width);
        for (let i = 0; i < 4; i++) this.rect[i] = r[i];
        if (this.fitted.length == 0) return false;
        this.build();
        return true;
    }

    // Draws the label (nothing when its text is ""), over what was drawn,
    // on a canvas `width` x `height` points at `scale` pixels per point.
    draw(renderer: HostRenderer, width: f64, height: f64, scale: f64): void {
        if (!this.prepare(width, height, scale)) return;
        const fill = this.fill;
        const ink = this.ink;
        const fp = this.fillPaint;
        const ip = this.inkPaint;
        if (fill == null || ink == null || fp == null || ip == null) return;
        renderer.drawPath(fill, fp);
        renderer.drawPath(ink, ip);
    }

    // The rectangle and the glyphs' strokes, from the fitted text.
    private build(): void {
        let fill = this.fill;
        let ink = this.ink;
        if (fill == null || ink == null) {
            fill = new Path();
            ink = new Path();
            this.fill = fill;
            this.ink = ink;
            const fp = new Paint();
            fp.style = PaintStyle.fill;
            fp.color = colorOf(LABEL_FILL);
            this.fillPaint = fp;
            const ip = new Paint();
            ip.style = PaintStyle.stroke;
            ip.thickness = <f32>LABEL_STROKE;
            ip.cap = StrokeCap.round;
            ip.join = StrokeJoin.round;
            ip.color = colorOf(LABEL_INK);
            this.inkPaint = ip;
        }
        fill.reset();
        ink.reset();
        const x = this.rect[0];
        const y = this.rect[1];
        roundedRect(fill, x, y, this.rect[2], this.rect[3], LABEL_RADIUS);
        const unit = LABEL_CAP / GLYPH_UNITS_HIGH;
        const inset = (LABEL_ADVANCE - GLYPH_UNITS_WIDE * unit) / 2;
        const t = this.fitted;
        for (let i = 0; i < t.length; i++) {
            const pts = glyphStrokes(labelGlyph(t.charCodeAt(i)));
            const gx = x + LABEL_PAD + <f64>i * LABEL_ADVANCE + inset;
            const gy = y + LABEL_PAD;
            let start = true;
            for (let k = 0; k + 1 < pts.length; k += 2) {
                const px = pts[k];
                if (isNaN(px)) {
                    start = true;
                    continue;
                }
                const v = Vector(<f32>(gx + <f64>px * unit), <f32>(gy + <f64>pts[k + 1] * unit));
                if (start) ink.moveTo(v);
                else ink.lineTo(v);
                start = false;
            }
        }
    }
}

const KAPPA: f64 = 0.5522847498;

// A rounded rectangle's contour, added to `path`.
function roundedRect(path: Path, x: f64, y: f64, w: f64, h: f64, radius: f64): void {
    const r = Math.min(radius, Math.min(w / 2, h / 2));
    const k = r * KAPPA;
    path.moveTo(Vector(<f32>(x + r), <f32>y));
    path.lineTo(Vector(<f32>(x + w - r), <f32>y));
    path.cubicTo(Vector(<f32>(x + w - r + k), <f32>y), Vector(<f32>(x + w), <f32>(y + r - k)), Vector(<f32>(x + w), <f32>(y + r)));
    path.lineTo(Vector(<f32>(x + w), <f32>(y + h - r)));
    path.cubicTo(Vector(<f32>(x + w), <f32>(y + h - r + k)), Vector(<f32>(x + w - r + k), <f32>(y + h)), Vector(<f32>(x + w - r), <f32>(y + h)));
    path.lineTo(Vector(<f32>(x + r), <f32>(y + h)));
    path.cubicTo(Vector(<f32>(x + r - k), <f32>(y + h)), Vector(<f32>x, <f32>(y + h - r + k)), Vector(<f32>x, <f32>(y + h - r)));
    path.lineTo(Vector(<f32>x, <f32>(y + r)));
    path.cubicTo(Vector(<f32>x, <f32>(y + r - k)), Vector(<f32>(x + r - k), <f32>y), Vector(<f32>(x + r), <f32>y));
    path.close();
}
