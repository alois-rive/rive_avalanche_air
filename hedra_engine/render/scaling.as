// The 3D picture's size under a render scale (docs/engine/PERFORMANCE.md,
// "Render scale"): Godot's Viewport.scaling_3d_scale and scaling_3d_mode,
// and Hedra's two caps, the 3D picture's density (pixels a point) and its
// pixel count. A Scene3D laid out at `width` x `height` points on a
// display of `density` pixels a point draws its 3D at
//
//   d   = min(density, maxDensity)            (maxDensity 0: no cap)
//   s   = scaling3dScale                       (0.25 to 2, Godot's range)
//   W   = round(width * d * s), H likewise
//   and, when W * H > maxPixels (0: no cap), W and H scaled down by the
//   same factor until W * H <= maxPixels
//
// pixels, each side at least 1; the picture is then drawn over the
// layout's points, stretched by Rive's image filter (bilinear) or, in the
// FSR mode with a picture smaller than the layout's pixels, upscaled by
// FSR 1.0 to them first (gpu/fsr.as). Scripts, the listeners' picking and
// the bindings' screen outputs keep the layout's own pixels (width *
// density, as Godot's input events keep the viewport's 2D size): the
// scene instance turns those into the picture's by `pickScale`.
//
// With a scale of 1 and the picture inside the caps (any picture up to
// 2560 x 1440 pixels at a density up to 2, the defaults), the picture is
// the layout's pixels to the pixel and is presented exactly as before (at
// 1 / density, the nearest filter). Above the caps (a 4K display at density
// 1: 3840 x 2160 drawn at 2560 x 1440; a density-3 phone drawn at density
// 2) the picture is smaller than the layout's pixels and stretched: the
// default policy's deliberate change, so that a Retina or 4K window does
// not draw 2.25 to 4 times the pixels of a 1440p one (Godot draws at the
// window's pixels whatever their count; its Viewport's scaling_3d_scale is
// the only knob, which Hedra keeps over the caps). Set max_density and
// max_pixels to 0 for Godot's behaviour.
//
// The level-of-detail threshold (lodThreshold, Godot's
// mesh_lod_threshold) stays in the layout's pixels, as Godot measures it
// against the viewport's size and not its scaled 3D buffer
// (renderer_viewport.cpp, _draw_3d): the plan is given it scaled with the
// picture it is tested in (scene_runtime.as applyLod), so the same meshes
// are drawn at any scale.

import { RenderQuality, SCALING_3D_FSR, SCALING_3D_SCALE_MAX, SCALING_3D_SCALE_MIN } from "./quality";

// A picture's largest side (scene_runtime.as MAX_PICTURE_SIDE's value: the
// render tier does not import the scene tier).
export const MAX_PICTURE_SIDE_3D: u32 = 8192;

// A size in pixels: rounded, 1 to MAX_PICTURE_SIDE_3D (scene_runtime.as
// `pixels`, the same rule, so that a scale of 1 and no cap give the
// picture of before to the pixel).
export function picturePixels(x: f64): u32 {
    if (!(x >= 1)) return 1;
    if (x > <f64>MAX_PICTURE_SIDE_3D) return MAX_PICTURE_SIDE_3D;
    return <u32>Math.round(x);
}

export class PictureSize {
    // The 3D picture's pixels.
    width: u32 = 1;
    height: u32 = 1;
    // The layout's own pixels (width * density, height * density: what
    // scripts and the picking see).
    viewWidth: u32 = 1;
    viewHeight: u32 = 1;
    // Points a picture pixel (the present's scale; across, and down:
    // the two differ by the rounding of a scaled picture), and picture
    // pixels a layout pixel (the picking's: width / viewWidth, height /
    // viewHeight).
    presentScale: f32 = 1;
    presentScaleY: f32 = 1;
    pickScale: f32 = 1;
    pickScaleY: f32 = 1;
    // Whether the picture is upscaled by FSR before it is presented.
    fsr: bool = false;

    // Whether the picture is the layout's pixels (drawn and presented as
    // before any render scale).
    native(): bool {
        return this.width == this.viewWidth && this.height == this.viewHeight;
    }

    copyFrom(o: PictureSize): void {
        this.width = o.width;
        this.height = o.height;
        this.viewWidth = o.viewWidth;
        this.viewHeight = o.viewHeight;
        this.presentScale = o.presentScale;
        this.presentScaleY = o.presentScaleY;
        this.pickScale = o.pickScale;
        this.pickScaleY = o.pickScaleY;
        this.fsr = o.fsr;
    }

    equals(o: PictureSize): bool {
        return this.width == o.width && this.height == o.height && this.viewWidth == o.viewWidth
            && this.viewHeight == o.viewHeight && this.presentScale == o.presentScale
            && this.presentScaleY == o.presentScaleY && this.fsr == o.fsr;
    }
}

// `out` set for a layout of `width` x `height` points at `density` pixels
// a point under `q` (see the header); allocates nothing. Returns `out`.
export function pictureSizeInto(width: f64, height: f64, density: f64, q: RenderQuality, out: PictureSize): PictureSize {
    const dens = density > 0 && isFinite(density) ? density : 1;
    const cap = <f64>q.maxDensity;
    const d = cap > 0 && isFinite(cap) ? Math.min(dens, cap) : dens;
    const sc = <f64>q.scaling3dScale;
    const s = isFinite(sc) ? Math.min(Math.max(sc, <f64>SCALING_3D_SCALE_MIN), <f64>SCALING_3D_SCALE_MAX) : 1.0;
    const vw = picturePixels(width * dens);
    const vh = picturePixels(height * dens);
    let w = picturePixels(width * d * s);
    let h = picturePixels(height * d * s);
    const most = <u64>max<i32>(q.maxPixels, 0);
    if (most > 0 && <u64>w * <u64>h > most) {
        const k = Math.sqrt(<f64>most / (<f64>w * <f64>h));
        const fw = <f64>w * k;
        const fh = <f64>h * k;
        w = picturePixels(fw);
        h = picturePixels(fh);
        // (rounded up past the cap: rounded down instead, which is under it)
        if (<u64>w * <u64>h > most) {
            w = max<u32>(<u32>Math.floor(fw), 1);
            h = max<u32>(<u32>Math.floor(fh), 1);
        }
    }
    out.width = w;
    out.height = h;
    out.viewWidth = vw;
    out.viewHeight = vh;
    if (w == vw && h == vh) {
        // (the picture of before, presented as before)
        out.presentScale = <f32>(1 / dens);
        out.presentScaleY = out.presentScale;
        out.pickScale = 1;
        out.pickScaleY = 1;
        out.fsr = false;
        return out;
    }
    out.presentScale = width > 0 ? <f32>(width / <f64>w) : <f32>(1 / dens);
    out.presentScaleY = height > 0 ? <f32>(height / <f64>h) : <f32>(1 / dens);
    out.pickScale = <f32>(<f64>w / <f64>vw);
    out.pickScaleY = <f32>(<f64>h / <f64>vh);
    out.fsr = q.scaling3dMode == SCALING_3D_FSR && (w < vw || h < vh);
    return out;
}
