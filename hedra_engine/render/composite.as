// CPU compositing, contact sheets, the axis
// gizmo and text labels.

import { f32ToI32, f64ToU32, partialCmpF32, totalCmpF32, cmpStr, roundF32, stableSort } from "../base/util";
import { Mat3, Vec3, Vec4, VEC3_X, VEC3_Y, VEC3_Z } from "../base/vecmath";
import { drawLabel, drawText, textHeight, textWidth } from "./font";
import { Image, Rgba, rgbaBytes } from "./image";
import { AXIS_X, AXIS_Y, AXIS_Z } from "./colors";

// A contact sheet's grid: columns, rows and the tile size in pixels.
export struct SheetLayout {
    cols: u32 = 0;
    rows: u32 = 0;
    tileW: u32 = 0;
    tileH: u32 = 0;

    constructor(cols: u32, rows: u32, tileW: u32, tileH: u32) {
        this.cols = cols;
        this.rows = rows;
        this.tileW = tileW;
        this.tileH = tileH;
    }

    operator==(a: SheetLayout, b: SheetLayout): bool {
        return a.cols == b.cols && a.rows == b.rows && a.tileW == b.tileW && a.tileH == b.tileH;
    }
    readonly hash(): u32 { return this.cols * 73856093 ^ this.rows * 19349663 ^ this.tileW * 83492791 ^ this.tileH; }

    // Debug text: `(cols, rows, tileW, tileH)`.
    readonly debug(): string { return `(${this.cols}, ${this.rows}, ${this.tileW}, ${this.tileH})`; }
}

// Grid layout for `n` tiles inside `size`: (cols, rows, tile_w, tile_h).
export function layout(n: i32, width: u32, height: u32): SheetLayout {
    const nn = <u32>max<i32>(n, 1);
    const cols = f64ToU32(Math.ceil(Math.sqrt(<f64>nn)));
    // u32::div_ceil
    const rows = nn / cols + (nn % cols > 0 ? 1 : 0);
    return SheetLayout(cols, rows, max<u32>(width / cols, 1), max<u32>(height / rows, 1));
}

// Label scale for a tile of this height: 2x above 300px, else 1x.
export function labelScale(height: u32): u32 {
    return height >= 300 ? 2 : 1;
}

export const LABEL_FG: Rgba = Rgba(235, 235, 235, 255);
export const LABEL_BG: Rgba = Rgba(0, 0, 0, 140);

// One `(String, Image)` tile of `sheet`.
export class SheetTile {
    label: string;
    image: Image;

    constructor(label: string, image: Image) {
        this.label = label;
        this.image = image;
    }
}

// Place labeled tiles on a sheet with thin separators.
export function sheet(tiles: Array<SheetTile>, width: u32, height: u32, background: Vec4): Image {
    const l = layout(tiles.length, width, height);
    const cols = l.cols;
    const tw = l.tileW;
    const th = l.tileH;
    const out = Image.new(width, height, rgbaBytes(background));
    const sep = Rgba(90, 90, 90, 255);
    for (let i = 0; i < tiles.length; i++) {
        const t = tiles[i];
        const x = <i32>((<u32>i % cols) * tw);
        const y = <i32>((<u32>i / cols) * th);
        out.blit(t.image, x, y);
        if (x > 0) {
            out.fillRect(x, y, 1, <i32>th, sep);
        }
        if (y > 0) {
            out.fillRect(x, y, <i32>tw, 1, sep);
        }
        const s = labelScale(th);
        drawLabel(out, x + 6 * <i32>s, y + 6 * <i32>s, t.label, s, LABEL_FG, LABEL_BG);
    }
    return out;
}

class GizmoAxis {
    axis: Vec3;
    color: Vec3;
    name: string;
    // `(view_rot * axis).z`, the sort key.
    z: f32;

    constructor(axis: Vec3, color: Vec3, name: string, z: f32) {
        this.axis = axis;
        this.color = color;
        this.name = name;
        this.z = z;
    }

    set(axis: Vec3, color: Vec3, name: string, z: f32): void {
        this.axis = axis;
        this.color = color;
        this.name = name;
        this.z = z;
    }
}

// axisGizmo's three axes, made once.
let keptAxes: Array<GizmoAxis>? = null;

function gizmoAxes(): Array<GizmoAxis> {
    let a = keptAxes;
    if (a == null) {
        a = new Array<GizmoAxis>();
        for (let i = 0; i < 3; i++) a.push(new GizmoAxis(VEC3_X, AXIS_X, "X", 0));
        keptAxes = a;
    }
    return a;
}

// Blender-style navigation gizmo: the world axes seen from the camera, drawn
// in the top-right corner.
export function axisGizmo(img: Image, viewRot: Mat3, scale: u32): void {
    const sf = <f32>scale;
    const r: f32 = <f32>22.0 * sf;
    const cx = <f32>img.width - r - <f32>14.0 * sf;
    const cy = r + <f32>14.0 * sf;
    // (three kept axes, set again in X, Y, Z order each call: a moving
    // view draws the gizmo every frame, and the allocator never frees)
    const axes = gizmoAxes();
    axes[0].set(VEC3_X, AXIS_X, "X", viewRot.mulVec3(VEC3_X).z);
    axes[1].set(VEC3_Y, AXIS_Y, "Y", viewRot.mulVec3(VEC3_Y).z);
    axes[2].set(VEC3_Z, AXIS_Z, "Z", viewRot.mulVec3(VEC3_Z).z);
    // Far axes first so the near ones draw on top: a stable insertion sort
    // in place (stableSort's, without its comparator, a closure the runtime
    // allocates at every call).
    for (let i = 1; i < axes.length; i++) {
        const v = axes[i];
        let j = i - 1;
        while (j >= 0 && partialCmpF32(axes[j].z, v.z) > 0) {
            axes[j + 1] = axes[j];
            j--;
        }
        axes[j + 1] = v;
    }
    img.fillRect(
        f32ToI32(cx - r - <f32>12.0 * sf),
        f32ToI32(cy - r - <f32>12.0 * sf),
        f32ToI32((r + <f32>12.0 * sf) * <f32>2.0),
        f32ToI32((r + <f32>12.0 * sf) * <f32>2.0),
        Rgba(0, 0, 0, 60),
    );
    for (let i = 0; i < axes.length; i++) {
        const a = axes[i];
        const v = viewRot.mulVec3(a.axis);
        const ex = cx + v.x * r;
        const ey = cy - v.y * r;
        const c = rgbaBytes(Vec4(a.color.x, a.color.y, a.color.z, 1.0));
        img.line(cx, cy, ex, ey, 2 * <i32>scale, c);
        const tw = <f32>textWidth(a.name, scale);
        const lx = cx + v.x * (r + <f32>8.0 * sf) - tw * <f32>0.5;
        const ly = cy - v.y * (r + <f32>8.0 * sf) - <f32>3.5 * sf;
        drawText(img, f32ToI32(lx), f32ToI32(ly), a.name, scale, c);
    }
}

// Hard ceiling on labels drawn in one view. The occupancy grid normally stops
// far short of it; it only guards the pathological case of a huge mesh with
// `--label-density 0`, where suppression is off.
export const MAX_LABELS: i32 = 20_000;

// One projected label competing for screen space in `placeLabels`.
export class LabelPlacement {
    // Center in output pixels.
    x: f32;
    y: f32;
    // Higher wins a contested cell (see scene_view.as `elemPriority`).
    priority: u8;
    // Projected depth; between equal priorities the nearer label wins.
    depth: f32;
    text: string;

    constructor(x: f32, y: f32, priority: u8, depth: f32, text: string) {
        this.x = x;
        this.y = y;
        this.priority = priority;
        this.depth = depth;
        this.text = text;
    }

    clone(): LabelPlacement {
        return new LabelPlacement(this.x, this.y, this.priority, this.depth, this.text);
    }
}

function cellKey(cx: i32, cy: i32): u64 {
    return (<u64><u32>cx << 32) | <u64><u32>cy;
}

// Which labels survive screen-space collision.
//
// Labels are walked best-first and each keeps the occupancy-grid cells its
// text box covers; a label whose box lands on a cell an earlier (higher
// priority) label already took is dropped. The cell pitch is one glyph row
// (`textHeight`) and the reserved box is the drawn label's box scaled by
// `density`, so `--label-density 2` leaves labels twice as far apart on each
// axis. `density <= 0` disables suppression and keeps everything (up to
// `MAX_LABELS`).
//
// The walk order is total and depends only on the input (priority
// descending, then depth ascending, then text, then input index), so the same
// labels always yield the same survivors. Returns the kept indices in
// ascending input order.
export function placeLabels(labels: Array<LabelPlacement>, scale: u32, density: f32): Array<i32> {
    const order: Array<i32> = [];
    for (let i = 0; i < labels.length; i++) order.push(i);
    stableSort<i32>(order, (a: i32, b: i32): i32 => {
        const la = labels[a];
        const lb = labels[b];
        if (lb.priority != la.priority) return lb.priority < la.priority ? -1 : 1;
        const d = totalCmpF32(la.depth, lb.depth);
        if (d != 0) return d;
        const t = cmpStr(la.text, lb.text);
        if (t != 0) return t;
        return a < b ? -1 : (a > b ? 1 : 0);
    });
    let kept: Array<i32> = [];
    if (density <= 0.0) {
        if (order.length > MAX_LABELS) order.length = MAX_LABELS;
        kept = order;
    } else {
        const cell = Mathf.max(<f32>textHeight(scale), 1.0);
        const pad = <f32>scale;
        const taken = new Set<u64>();
        const cells: Array<u64> = [];
        for (let oi = 0; oi < order.length; oi++) {
            const i = order[oi];
            const l = labels[i];
            const w = (<f32>textWidth(l.text, scale) + <f32>2.0 * pad) * density;
            const h = (<f32>textHeight(scale) + <f32>2.0 * pad) * density;
            const x0 = f32ToI32(Mathf.floor((l.x - w * <f32>0.5) / cell));
            const x1 = f32ToI32(Mathf.floor((l.x + w * <f32>0.5) / cell));
            const y0 = f32ToI32(Mathf.floor((l.y - h * <f32>0.5) / cell));
            const y1 = f32ToI32(Mathf.floor((l.y + h * <f32>0.5) / cell));
            cells.length = 0;
            let free = true;
            // 'scan: the first taken cell ends both loops.
            for (let cy = y0; free && cy <= y1; cy++) {
                for (let cx = x0; cx <= x1; cx++) {
                    const k = cellKey(cx, cy);
                    if (taken.has(k)) {
                        free = false;
                        break;
                    }
                    cells.push(k);
                    if (cx == i32.MAX_VALUE) break;
                }
                if (cy == i32.MAX_VALUE) break;
            }
            if (!free) {
                continue;
            }
            for (let k = 0; k < cells.length; k++) taken.add(cells[k]);
            kept.push(i);
            if (kept.length >= MAX_LABELS) {
                break;
            }
        }
    }
    kept.sort((a: i32, b: i32): i32 => a - b);
    return kept;
}

// A label centered on a pixel position.
export function centeredLabel(img: Image, x: f32, y: f32, text: string, scale: u32, fg: Rgba): void {
    const w = <f32>textWidth(text, scale);
    const h = <f32>textHeight(scale);
    drawLabel(
        img,
        f32ToI32(roundF32(x - w * <f32>0.5)),
        f32ToI32(roundF32(y - h * <f32>0.5)),
        text,
        scale,
        fg,
        LABEL_BG,
    );
}
