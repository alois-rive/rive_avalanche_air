#!/usr/bin/env python3
"""Hold an asset or a frame to the PSX rules (psx-style SKILL.md, "The gates").

    psx_audit.py texture final/textures/snow.png [--max-colors 16] [--max-size 256]
    psx_audit.py model final/rider.rmdl --max-tris 500 [--max-objects 16]
    psx_audit.py frame shots/run.png --low-res 320x240 [--min-blocks 0.98]

texture  a power of two from 8 to 256 a side, at most --max-colors colours
         (the CLUT, 16 by default), every channel on the 15-bit grid
         (multiples of 8), alpha only 0 or 255, and an .import beside it
         that keeps it lossless with no mipmaps.
model    `hedra model <file> inspect stats --json`: the whole model's
         triangles under --max-tris, no object over --max-object-tris,
         at most --max-objects objects.
frame    a screenshot of the running game at any size: the picture inside
         the pillarbox is made of whole low-resolution pixels (blocks of
         one colour), every channel on the 15-bit grid, and not blurred
         (no bilinear upscale). The test the brief calls "a screenshot is
         recognised as a PS1 game", measured.

Exit 0 when every check passes, 1 otherwise; --json prints the report.
Needs Pillow and NumPy (texture, frame); `hedra` on the PATH (model).
"""
import argparse
import json
import os
import subprocess
import sys


def need_imaging():
    try:
        import numpy as np  # noqa: F401
        from PIL import Image  # noqa: F401
    except ImportError:
        sys.exit("psx_audit.py texture/frame needs Pillow and NumPy: pip install pillow numpy")


def check(results, name, ok, detail):
    results.append({"check": name, "pass": bool(ok), "detail": detail})


def audit_texture(args):
    need_imaging()
    import numpy as np
    from PIL import Image

    results = []
    img = Image.open(args.path)
    w, h = img.size
    pow2 = all(v >= 8 and v <= args.max_size and not (v & (v - 1)) for v in (w, h))
    check(results, "size", pow2, f"{w}x{h} (powers of two, 8 to {args.max_size})")
    rgba = np.asarray(img.convert("RGBA")).astype(int)
    alpha = rgba[..., 3]
    opaque = alpha > 0
    colors = len(np.unique(rgba[opaque][:, :3], axis=0)) if opaque.any() else 0
    check(results, "colors", colors <= args.max_colors, f"{colors} colours (at most {args.max_colors})")
    off_grid = float(np.mean(rgba[opaque][:, :3] % 8 != 0)) if opaque.any() else 0.0
    check(results, "15-bit", off_grid == 0.0, f"{off_grid:.1%} of channel values off the 15-bit grid")
    partial = int(((alpha > 0) & (alpha < 255)).sum())
    check(results, "alpha", partial == 0, f"{partial} texels of partial alpha (1-bit only)")
    imp = args.path + ".import"
    if os.path.exists(imp):
        text = open(imp).read().replace(" ", "")
        lossless = "compress/mode=0" in text or "compress/mode=lossless" in text
        nomips = "mipmaps/generate=false" in text
        check(results, "import", lossless and nomips,
              f"{'lossless' if lossless else 'block-compressed'}, {'no mipmaps' if nomips else 'mipmaps'}")
    else:
        check(results, "import", False, "no .import yet: hedra import <png> --set compress/mode=lossless --set mipmaps/generate=false")
    return results


def audit_model(args):
    results = []
    try:
        out = subprocess.run(["hedra", "model", args.path, "inspect", "stats", "--json"],
                             capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        sys.exit(f"hedra model {args.path} inspect stats failed: {e}")
    stats = json.loads(out)["stats"]
    tris = stats.get("tris", 0)
    check(results, "triangles", tris <= args.max_tris, f"{tris} triangles (at most {args.max_tris})")
    objects = stats.get("objects", [])
    meshes = [o for o in objects if o.get("type") == "mesh"]
    check(results, "objects", len(meshes) <= args.max_objects, f"{len(meshes)} mesh objects (at most {args.max_objects})")
    worst = max(meshes, key=lambda o: o.get("tris", 0)) if meshes else None
    if worst is not None and args.max_object_tris:
        check(results, "object triangles", worst["tris"] <= args.max_object_tris,
              f"largest {worst['name']}: {worst['tris']} (at most {args.max_object_tris})")
    return results


def audit_frame(args):
    need_imaging()
    import numpy as np
    from PIL import Image

    results = []
    lw, lh = (int(v) for v in args.low_res.lower().split("x"))
    a = np.asarray(Image.open(args.path).convert("RGB")).astype(int)
    H, W = a.shape[:2]
    # The picture inside the bars: columns and rows that are not all black.
    lit_cols = np.where(a.max(axis=(0, 2)) > 0)[0]
    lit_rows = np.where(a.max(axis=(1, 2)) > 0)[0]
    if len(lit_cols) == 0:
        check(results, "picture", False, "the frame is black")
        return results
    x0, x1 = lit_cols[0], lit_cols[-1] + 1
    y0, y1 = lit_rows[0], lit_rows[-1] + 1
    pic = a[y0:y1, x0:x1]
    ph, pw = pic.shape[:2]
    aspect = (pw / ph) / (lw / lh)
    check(results, "aspect", abs(aspect - 1) < 0.03, f"picture {pw}x{ph}, aspect {aspect:.3f} of {lw}:{lh}")
    # Sample every low-resolution pixel's block, away from its edges: one colour each.
    bx, by = pw / lw, ph / lh
    bad = 0
    total = 0
    for j in range(lh):
        for i in range(lw):
            xa, xb = int(x0 + i * bx + bx * 0.25), int(x0 + (i + 1) * bx - bx * 0.25)
            ya, yb = int(y0 + j * by + by * 0.25), int(y0 + (j + 1) * by - by * 0.25)
            if xb <= xa or yb <= ya:
                continue
            block = a[ya:yb, xa:xb].reshape(-1, 3)
            total += 1
            if (block.max(0) - block.min(0)).max() > 2:
                bad += 1
    blocks = 1 - bad / max(total, 1) if bx >= 1 and by >= 1 and total > 0 else 0.0
    check(results, "blocks", blocks >= args.min_blocks,
          f"{blocks:.1%} of {lw}x{lh} pixels are solid blocks of {bx:.2f}x{by:.2f} (at least {args.min_blocks:.0%})")
    off_grid = float(np.mean(pic % 8 != 0))
    check(results, "15-bit", off_grid <= args.max_off_grid, f"{off_grid:.1%} of channel values off the 15-bit grid")
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="kind", required=True)
    t = sub.add_parser("texture")
    t.add_argument("path")
    t.add_argument("--max-colors", type=int, default=16)
    t.add_argument("--max-size", type=int, default=256)
    m = sub.add_parser("model")
    m.add_argument("path")
    m.add_argument("--max-tris", type=int, required=True)
    m.add_argument("--max-objects", type=int, default=32)
    m.add_argument("--max-object-tris", type=int, default=0)
    f = sub.add_parser("frame")
    f.add_argument("path")
    f.add_argument("--low-res", default="320x240")
    f.add_argument("--min-blocks", type=float, default=0.98)
    f.add_argument("--max-off-grid", type=float, default=0.0,
                   help="share of channel values allowed off the 15-bit grid (a HUD over the picture adds some)")
    for p in (t, m, f):
        p.add_argument("--json", action="store_true")
    args = ap.parse_args()

    results = {"texture": audit_texture, "model": audit_model, "frame": audit_frame}[args.kind](args)
    ok = all(r["pass"] for r in results)
    if args.json:
        print(json.dumps({"path": args.path, "kind": args.kind, "pass": ok, "checks": results}, indent=2))
    else:
        for r in results:
            print(f"{'pass' if r['pass'] else 'FAIL'}  {r['check']:<16} {r['detail']}")
        print(f"psx {args.kind} audit: {'pass' if ok else 'fail'} ({args.path})")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
