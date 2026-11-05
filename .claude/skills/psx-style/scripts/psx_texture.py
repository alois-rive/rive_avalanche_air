#!/usr/bin/env python3
"""Fit an image (a generated base texture, a painted sprite) to a PlayStation
texture: a small power-of-two size, a colour look-up table of 16 or 256
colours on the 15-bit grid, 1-bit alpha, optionally tileable and pre-dithered.

    psx_texture.py generated/snow.v1.png final/textures/snow.png --size 64x64 --colors 16 --tileable
    psx_texture.py generated/pine.v1.png final/textures/pine.png --size 64x128 --colors 16 --key-bg
    psx_texture.py generated/banner.v1.png final/textures/banner.png --size 128x64 --colors 256 --dither ordered

The same input and flags give the same bytes. Prints what it did, and the
`hedra import` line the texture needs (lossless, no mipmaps: block
compression would smear a 16-colour palette, and the PlayStation had no
mipmaps). Needs Pillow and NumPy.
"""
import argparse
import json
import sys

try:
    import numpy as np
    from PIL import Image
except ImportError:  # pragma: no cover
    sys.exit("psx_texture.py needs Pillow and NumPy: pip install pillow numpy")

# The PlayStation GPU's 4 x 4 dither offsets, in 8-bit steps (psx-spx).
PSX_DITHER = np.array([[-4, 0, -3, 1], [2, -2, 3, -1], [-3, 1, -4, 0], [3, -1, 2, -2]], dtype=np.float32)


def parse_size(text):
    w, h = (int(v) for v in text.lower().split("x"))
    for v in (w, h):
        if v < 8 or v > 256 or v & (v - 1):
            sys.exit(f"--size {text}: each side a power of two from 8 to 256 (a texture page is 256 x 256)")
    return w, h


def make_tileable(rgb):
    """Cross-fade with a half-shifted copy, weighted to hide the wrap seam."""
    h, w = rgb.shape[:2]
    shifted = np.roll(np.roll(rgb, h // 2, axis=0), w // 2, axis=1)
    y = np.abs(np.linspace(-1, 1, h))[:, None]
    x = np.abs(np.linspace(-1, 1, w))[None, :]
    edge = np.clip(np.maximum(x, y) * 1.6 - 0.6, 0, 1)[..., None]
    return rgb * (1 - edge) + shifted * edge


def key_alpha(rgba, bg, tolerance):
    """1-bit alpha: the background colour joined to the border is cut out."""
    from collections import deque

    h, w = rgba.shape[:2]
    rgb = rgba[..., :3].astype(np.float32)
    near = np.linalg.norm(rgb - np.array(bg, dtype=np.float32), axis=-1) <= tolerance
    cut = np.zeros((h, w), dtype=bool)
    queue = deque()
    for x in range(w):
        for y in (0, h - 1):
            if near[y, x] and not cut[y, x]:
                cut[y, x] = True
                queue.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if near[y, x] and not cut[y, x]:
                cut[y, x] = True
                queue.append((y, x))
    while queue:
        y, x = queue.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and near[ny, nx] and not cut[ny, nx]:
                cut[ny, nx] = True
                queue.append((ny, nx))
    alpha = rgba[..., 3].copy() if rgba.shape[-1] == 4 else np.full((h, w), 255, np.uint8)
    alpha[cut] = 0
    return alpha


def snap15(rgb):
    """Each channel onto the 15-bit grid: 5 bits, 0 to 248 in steps of 8."""
    return (np.clip(np.floor(rgb / 8.0 + 0.5), 0, 31) * 8).astype(np.uint8)


def quantize(rgb, alpha, colors, dither):
    """A CLUT of `colors` entries on the 15-bit grid (one kept for transparency)."""
    h, w = rgb.shape[:2]
    work = rgb.astype(np.float32)
    if dither == "ordered":
        tile = np.tile(PSX_DITHER, (h // 4 + 1, w // 4 + 1))[:h, :w]
        work = np.clip(work + tile[..., None] * 2.0, 0, 255)
    opaque = alpha >= 128
    usable = colors - (0 if opaque.all() else 1)
    # The palette is made from the opaque texels only: the transparent
    # entry is index 0 of the CLUT, not a colour.
    samples = snap15(work)[opaque] if opaque.any() else snap15(work).reshape(-1, 3)
    img = Image.fromarray(samples.reshape(1, -1, 3).astype(np.uint8), "RGB")
    pal_img = img.quantize(colors=max(usable, 2), method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    count = len(pal_img.getcolors(maxcolors=4096) or []) or max(usable, 2)
    palette = np.array(pal_img.getpalette()[: 3 * count], dtype=np.float32).reshape(-1, 3)
    palette = np.unique(snap15(palette), axis=0).astype(np.float32)
    flat = work.reshape(-1, 3)
    if dither == "floyd":
        out = np.zeros_like(flat)
        buf = work.copy()
        for y in range(h):
            for x in range(w):
                old = buf[y, x]
                idx = int(np.argmin(((palette - old) ** 2).sum(-1)))
                new = palette[idx]
                out[y * w + x] = new
                err = old - new
                if x + 1 < w:
                    buf[y, x + 1] += err * 7 / 16
                if y + 1 < h:
                    if x > 0:
                        buf[y + 1, x - 1] += err * 3 / 16
                    buf[y + 1, x] += err * 5 / 16
                    if x + 1 < w:
                        buf[y + 1, x + 1] += err * 1 / 16
        result = out.reshape(h, w, 3)
    else:
        d = ((flat[:, None, :] - palette[None, :, :]) ** 2).sum(-1)
        result = palette[np.argmin(d, axis=1)].reshape(h, w, 3)
    return result.astype(np.uint8), palette


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--size", required=True, help="WxH, powers of two from 8 to 256: 64x64, 128x128, 64x128")
    ap.add_argument("--colors", type=int, default=16, choices=(4, 8, 16, 32, 64, 128, 256),
                    help="CLUT entries: 16 (4-bit, the usual), 256 (8-bit, faces and signage)")
    ap.add_argument("--dither", choices=("none", "ordered", "floyd"), default="none",
                    help="pre-dither the texture into its palette (gradients: ordered; painted art: none)")
    ap.add_argument("--mode", choices=("cover", "contain", "stretch"), default="cover")
    ap.add_argument("--resample", choices=("box", "lanczos", "nearest"), default="box",
                    help="downscale filter: box keeps the colours honest; nearest keeps hard pixel art")
    ap.add_argument("--tileable", action="store_true", help="hide the wrap seam before downscaling")
    ap.add_argument("--key-bg", action="store_true", help="cut the flat background joined to the border to alpha 0")
    ap.add_argument("--bg", default=None, help="the background colour to key, as #rrggbb (default: the corners')")
    ap.add_argument("--tolerance", type=float, default=40.0, help="RGB distance counted as background")
    ap.add_argument("--json", action="store_true", help="print the report as JSON")
    args = ap.parse_args()

    w, h = parse_size(args.size)
    src = Image.open(args.src).convert("RGBA")
    rgba = np.asarray(src).copy()

    alpha_full = None
    if args.key_bg:
        if args.bg:
            bg = tuple(int(args.bg.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
        else:
            corners = [rgba[0, 0, :3], rgba[0, -1, :3], rgba[-1, 0, :3], rgba[-1, -1, :3]]
            bg = tuple(int(v) for v in np.median(np.array(corners), axis=0))
        alpha_full = key_alpha(rgba, bg, args.tolerance)
        rgba[..., 3] = alpha_full

    rgb = rgba[..., :3].astype(np.float32)
    if args.tileable:
        rgb = make_tileable(rgb)
    rgba = np.dstack([np.clip(rgb, 0, 255).astype(np.uint8), rgba[..., 3]])
    img = Image.fromarray(rgba, "RGBA")

    sw, sh = img.size
    if args.mode == "cover":
        scale = max(w / sw, h / sh)
        cw, ch = round(w / scale), round(h / scale)
        left, top = (sw - cw) // 2, (sh - ch) // 2
        img = img.crop((left, top, left + cw, top + ch))
    elif args.mode == "contain":
        scale = min(w / sw, h / sh)
        canvas = Image.new("RGBA", (round(w / scale), round(h / scale)), (0, 0, 0, 0))
        canvas.paste(img, ((canvas.width - sw) // 2, (canvas.height - sh) // 2))
        img = canvas
    resample = {"box": Image.Resampling.BOX, "lanczos": Image.Resampling.LANCZOS, "nearest": Image.Resampling.NEAREST}[args.resample]
    # Premultiply so a cut-out's background does not bleed into its edge.
    arr = np.asarray(img).astype(np.float32)
    a = arr[..., 3:4] / 255.0
    pre = Image.fromarray(np.dstack([arr[..., :3] * a, arr[..., 3]]).astype(np.uint8), "RGBA").resize((w, h), resample)
    small = np.asarray(pre).astype(np.float32)
    alpha = small[..., 3]
    rgb = np.where(alpha[..., None] > 0, small[..., :3] / np.maximum(alpha[..., None] / 255.0, 1e-6), 0)
    alpha_bit = np.where(alpha >= 128, 255, 0).astype(np.uint8)

    out_rgb, palette = quantize(np.clip(rgb, 0, 255), alpha_bit, args.colors, args.dither)
    out_rgb[alpha_bit == 0] = 0
    has_alpha = bool((alpha_bit == 0).any())
    out = Image.fromarray(np.dstack([out_rgb, alpha_bit]) if has_alpha else out_rgb, "RGBA" if has_alpha else "RGB")
    out.save(args.out, optimize=False)

    used = np.unique(out_rgb[alpha_bit > 0].reshape(-1, 3), axis=0)
    report = {
        "out": args.out,
        "size": [w, h],
        "colors": int(len(used)) + (1 if has_alpha else 0),
        "clut": args.colors,
        "alpha": "1-bit" if has_alpha else "none",
        "fifteen_bit": bool((out_rgb % 8 == 0).all()),
        "import": f"hedra import {args.out} --set compress/mode=lossless --set mipmaps/generate=false",
    }
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"{args.out}: {w}x{h}, {report['colors']} colours of a {args.colors}-entry CLUT, "
              f"alpha {report['alpha']}, 15-bit {'yes' if report['fifteen_bit'] else 'no'}")
        print(f"  then: {report['import']}")


if __name__ == "__main__":
    main()
