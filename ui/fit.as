// The 320 x 240 grid for the window (docs/RIVE.md, section 7): the overlays
// are 320 x 240 artboards drawn scaled by the largest whole number that fits
// the window, centred, the rest the 3D's black bars (LOOK.md, section 1).
// This layout fills Main (the window) and hears its size; it writes
// Game/ui/scale, gx and gy, which the Grid node's scale and position are
// bound to. A window smaller than the grid scales it down to fit.
//
// It writes only when the size changes and draws nothing.

import { Layout, Context } from "rive/host";
import { NumberProp, bindUi, num, ui } from "./ui_state";

const GRID_W: f64 = 320;
const GRID_H: f64 = 240;

export class Fit extends Layout {
    scale: NumberProp = new NumberProp();
    gx: NumberProp = new NumberProp();
    gy: NumberProp = new NumberProp();
    w: f64 = 0;
    h: f64 = 0;

    override init(context: Context): bool {
        bindUi(context.viewModel());
        this.scale = num(ui.view, "scale");
        this.gx = num(ui.view, "gx");
        this.gy = num(ui.view, "gy");
        if (this.w > 0) this.place();
        return true;
    }

    override resize(width: f64, height: f64, scale: f64): void {
        this.w = width;
        this.h = height;
        this.place();
    }

    place(): void {
        const fit = Math.min(this.w / GRID_W, this.h / GRID_H);
        let s = Math.floor(fit);
        if (s < 1) s = fit;
        if (s <= 0) return;
        this.scale.set(s);
        this.gx.set(Math.floor((this.w - GRID_W * s) / 2));
        this.gy.set(Math.floor((this.h - GRID_H * s) / 2));
    }
}
