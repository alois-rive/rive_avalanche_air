#!/usr/bin/env python3
"""Builds the segmented rider (docs/LOOK.md, section 5; RIDER.md, section 12;
psx-style references/models.md, "Characters"): PLACEHOLDER art for the asset
pipeline (ASSETS.md), procedural and checked by psx_audit.py.

Writes, under world/rider/:
- parts/<Part>.gltf: 16 rigid low-poly parts (pelvis, torso, head, beanie,
  upper and lower arms, hands, upper and lower legs, boots) and the board,
  each a glTF of one mesh node `mesh`, in its joint's frame (a limb hangs
  from its joint along -Y), its UVs on the texture page;
- textures/rider_page.png: the 128 x 512 page: the three colour schemes'
  128 x 128 pages stacked (Hot Pink, Acid, Blaze: SPEC.md section 5, 16
  colours each on the 15-bit grid), then the board's base and top deck
  (64 x 128 each); a scheme is chosen by the material's uv_offset (0.25 a
  scheme: the scene's `Scheme` timeline);
- textures/puff.png (4 frames of 16 px) and textures/star.png: the spray's
  and the sparkle's sprites (psx_sprite);
- rider.rscn: the Body (the board's place, moved by run.as's RiderView)
  with the joints of tools/make_poses.py's rig, each part instanced under
  its joint with the psx_surface material, the blob shadow, the spray, the
  landing burst, the sparkle, and the timelines Door (the respawn's
  screen-door blink), Lift (the shadow's) and Scheme.

    python3 tools/make_rider.py
"""
import base64
import json
import os
import shutil
import struct
import subprocess
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_poses as rig  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RIDER = os.path.join(ROOT, "world", "rider")
PARTS = os.path.join(RIDER, "parts")
TEX = os.path.join(RIDER, "textures")

PAGE_W = 128
PAGE_H = 128
ATLAS_H = 512           # 3 scheme pages and the board's page
V_SCALE = PAGE_H / ATLAS_H

# ---- the palettes (15-bit grid: every channel a multiple of 8) -------------------


def hexc(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) & 0xF8 for i in (0, 2, 4))


def shade(c, k):
    return tuple(max(0, min(248, int(v * k))) & 0xF8 for v in c)


SCHEMES = [
    # name, jacket, trousers, beanie, zip/accent
    ("Hot Pink", "#f83890", "#283058", "#28c8f8", "#f8f830"),
    ("Acid", "#a8f830", "#383838", "#f83890", "#f88818"),
    ("Blaze", "#f88818", "#204878", "#f8f8f8", "#28c8f8"),
]


def palette(scheme):
    _, jacket, trousers, beanie, accent = scheme
    j = hexc(jacket)
    t = hexc(trousers)
    b = hexc(beanie)
    return {
        "ink": hexc("#101018"),
        "j0": shade(j, 0.62), "j1": j, "j2": shade(j, 1.18),
        "t0": shade(t, 0.66), "t1": t, "t2": shade(t, 1.35),
        "g0": hexc("#282830"), "g1": hexc("#505060"),
        "skin": hexc("#f8c8a0"), "skin0": hexc("#c89070"),
        "lens": hexc("#f8a828"), "white": hexc("#f0f0f8"),
        "b1": b, "acc": hexc(accent),
    }


# ---- the page's regions (pixels in a 128 x 128 scheme page) ----------------------
REG = {
    "torso": (0, 0, 64, 48),
    "upperarm": (64, 0, 128, 24),
    "lowerarm": (64, 24, 128, 48),
    "pelvis": (0, 48, 48, 64),
    "head": (48, 48, 96, 64),
    "beanie": (96, 48, 128, 64),
    "upperleg": (0, 64, 64, 96),
    "lowerleg": (64, 64, 128, 96),
    "hand": (0, 96, 32, 112),
    "boot": (32, 96, 96, 128),
    "cap_jacket": (0, 112, 8, 120),
    "cap_trousers": (8, 112, 16, 120),
    "cap_dark": (16, 112, 24, 120),
    "cap_skin": (24, 112, 32, 120),
}
# the board's page (pixels in the atlas): base on the left, top deck on the right
BOARD_BASE = (0, 384, 64, 512)
BOARD_TOP = (64, 384, 128, 512)


def paint_page(img, oy, pal):
    """One scheme's 128 x 128 page at atlas row oy."""
    px = img.load()

    def rect(r, c, dy=0):
        x0, y0, x1, y1 = r
        for y in range(y0, y1):
            for x in range(x0, x1):
                px[x, y + oy + dy] = c

    def put(x, y, c):
        px[x, y + oy] = c

    # the jacket: mid, darker at the sides (the wrap's back), a zip and a chest stripe
    x0, y0, x1, y1 = REG["torso"]
    for y in range(y0, y1):
        for x in range(x0, x1):
            u = (x - x0) / (x1 - x0)
            c = pal["j1"]
            if u < 0.12 or u > 0.88:
                c = pal["j0"]
            elif 0.38 < u < 0.62 and y < y0 + 10:
                c = pal["j2"]
            put(x, y, c)
    # the zip down the front (the wrap's middle), the chest stripe, the hem
    for y in range(y0 + 4, y1):
        put((x0 + x1) // 2, y, pal["ink"])
    for x in range(x0 + 18, x1 - 18):
        for y in range(y0 + 18, y0 + 22):
            put(x, y, pal["acc"])
    for x in range(x0, x1):
        for y in range(y1 - 4, y1):
            put(x, y, pal["j0"])
    # the sleeves: shaded lengthwise, an accent band at the cuff
    for name in ("upperarm", "lowerarm"):
        x0, y0, x1, y1 = REG[name]
        for y in range(y0, y1):
            for x in range(x0, x1):
                u = (x - x0) / (x1 - x0)
                c = pal["j1"] if 0.2 < u < 0.8 else pal["j0"]
                if name == "upperarm" and y < y0 + 3:
                    c = pal["j2"]
                if name == "lowerarm" and y >= y1 - 4:
                    c = pal["acc"]
                put(x, y, c)
    # the trousers: baggy, seams down the sides, knee patches
    for name in ("pelvis", "upperleg", "lowerleg"):
        x0, y0, x1, y1 = REG[name]
        for y in range(y0, y1):
            for x in range(x0, x1):
                u = (x - x0) / (x1 - x0)
                c = pal["t1"]
                if u < 0.1 or u > 0.9:
                    c = pal["t0"]
                if abs(u - 0.25) < 0.02 or abs(u - 0.75) < 0.02:
                    c = pal["t0"]
                put(x, y, c)
        if name == "pelvis":
            for x in range(x0, x1):
                for y in range(y0, y0 + 3):
                    put(x, y, pal["ink"])          # the belt
        if name == "lowerleg":
            for y in range(y0 + 2, y0 + 10):
                for x in range(x0 + 24, x1 - 24):
                    put(x, y, pal["t2"])          # a knee patch
            for x in range(x0, x1):
                for y in range(y1 - 3, y1):
                    put(x, y, pal["t0"])
    # the head: skin, the face at the front (the middle of the wrap): goggle
    # strap round the head, eyes and a grin
    x0, y0, x1, y1 = REG["head"]
    for y in range(y0, y1):
        for x in range(x0, x1):
            u = (x - x0) / (x1 - x0)
            put(x, y, pal["skin"] if 0.2 < u < 0.8 else pal["skin0"])
    cx = (x0 + x1) // 2
    for x in range(cx - 4, cx + 4):
        put(x, y0 + 5, pal["ink"])                 # the eyes' line
    put(cx - 3, y0 + 6, pal["ink"])
    put(cx + 2, y0 + 6, pal["ink"])
    for x in range(cx - 3, cx + 3):
        put(x, y0 + 10, pal["ink"])                # the grin
    put(cx - 4, y0 + 9, pal["ink"])
    put(cx + 3, y0 + 9, pal["ink"])
    for y in range(y0, y0 + 2):
        for x in range(x0, x1):
            put(x, y, pal["skin0"])
    # the beanie: its colour, a white stripe, the goggles on its front
    x0, y0, x1, y1 = REG["beanie"]
    for y in range(y0, y1):
        for x in range(x0, x1):
            put(x, y, pal["b1"])
    for x in range(x0, x1):
        for y in range(y0 + 6, y0 + 8):
            put(x, y, pal["white"])
    for x in range(x0, x1):
        for y in range(y1 - 5, y1):
            put(x, y, pal["ink"])                  # the goggles' strap
    gx = (x0 + x1) // 2
    for x in range(gx - 7, gx + 7):
        for y in range(y1 - 6, y1):
            put(x, y, pal["white"])
    for x in range(gx - 6, gx + 6):
        for y in range(y1 - 5, y1 - 1):
            put(x, y, pal["lens"])
    put(gx, y1 - 5, pal["white"])
    # the gloves and boots
    rect(REG["hand"], pal["g0"])
    x0, y0, x1, y1 = REG["hand"]
    for x in range(x0, x1):
        for y in range(y0, y0 + 3):
            put(x, y, pal["acc"])
    x0, y0, x1, y1 = REG["boot"]
    for y in range(y0, y1):
        for x in range(x0, x1):
            u = (x - x0) / (x1 - x0)
            put(x, y, pal["g1"] if 0.25 < u < 0.75 else pal["g0"])
    for y in range(y0 + 4, y1 - 8, 4):
        for x in range((x0 + x1) // 2 - 4, (x0 + x1) // 2 + 4):
            put(x, y, pal["white"])               # the laces
    for x in range(x0, x1):
        for y in range(y1 - 4, y1):
            put(x, y, pal["ink"])                 # the sole
    rect(REG["cap_jacket"], pal["j0"])
    rect(REG["cap_trousers"], pal["t0"])
    rect(REG["cap_dark"], pal["g0"])
    rect(REG["cap_skin"], pal["skin0"])
    # the rest of the page: the jacket's colour (nothing samples it)
    for y in range(120, 128):
        for x in range(0, 32):
            put(x, y, pal["j1"])
    for y in range(112, 128):
        for x in range(96, 128):
            put(x, y, pal["j1"])


def paint_board(img):
    px = img.load()
    purple = hexc("#382868")
    pink = hexc("#f83890")
    orange = hexc("#f88818")
    white = hexc("#f8f8f8")
    ice = hexc("#a8b8e0")
    dark = hexc("#202028")
    grey = hexc("#606070")
    x0, y0, x1, y1 = BOARD_BASE
    for y in range(y0, y1):
        for x in range(x0, x1):
            u = (x - x0) / (x1 - x0)
            v = (y - y0) / (y1 - y0)
            c = purple
            d = v - u * 0.6
            if 0.18 < d < 0.32:
                c = pink
            elif 0.32 <= d < 0.40:
                c = orange
            elif 0.50 < d < 0.54:
                c = ice
            px[x, y] = c
    # "AA" in blocky letters on the base
    letters = [
        "0110", "1001", "1111", "1001", "1001",
    ]
    for k, ox in enumerate((14, 34)):
        for r, row in enumerate(letters):
            for c, bit in enumerate(row):
                if bit == "1":
                    for yy in range(3):
                        for xx in range(3):
                            px[x0 + ox + c * 3 + xx, y0 + 50 + r * 3 + yy] = white
    for x in range(x0, x1):
        px[x, y0] = dark
        px[x, y1 - 1] = dark
    # the top deck: dark grey, a lighter stomp pad between the bindings
    x0, y0, x1, y1 = BOARD_TOP
    for y in range(y0, y1):
        for x in range(x0, x1):
            v = (y - y0) / (y1 - y0)
            c = dark
            if 0.45 < v < 0.55 and (x - x0) % 8 < 4:
                c = grey
            if abs(v - 0.33) < 0.06 or abs(v - 0.67) < 0.06:
                c = pink
            px[x, y] = c


def paint_sprites():
    puff = Image.new("RGBA", (64, 16), (0, 0, 0, 0))
    p = puff.load()
    for f in range(4):
        r = 6.5 - f * 1.4
        for y in range(16):
            for x in range(16):
                dx = x - 7.5
                dy = y - 7.5
                if dx * dx + dy * dy <= r * r:
                    c = (248, 248, 248, 255) if dx + dy < 0 else (200, 216, 240, 255)
                    p[f * 16 + x, y] = c
    puff.save(os.path.join(TEX, "puff.png"))
    star = Image.new("RGBA", (32, 8), (0, 0, 0, 0))
    s = star.load()
    for f in range(4):
        for k in range(-3, 4):
            if abs(k) <= 3 - f // 2:
                s[f * 8 + 3 + k, 3] = (248, 248, 136, 255)
                s[f * 8 + 3, 3 + k] = (248, 248, 136, 255)
    star.save(os.path.join(TEX, "star.png"))


# ---- the meshes ----------------------------------------------------------------------


class Mesh:
    def __init__(self):
        self.pos = []
        self.nrm = []
        self.uv = []
        self.idx = []

    def vert(self, p, n, uv):
        self.pos.append(tuple(float(v) for v in p))
        self.nrm.append(tuple(float(v) for v in n))
        self.uv.append((float(uv[0]), float(uv[1])))
        return len(self.pos) - 1

    def tri(self, a, b, c):
        self.idx.extend([a, b, c])

    def tris(self):
        return len(self.idx) // 3


def norm3(v):
    l = (v[0] ** 2 + v[1] ** 2 + v[2] ** 2) ** 0.5
    return (v[0] / l, v[1] / l, v[2] / l) if l > 1e-9 else (0.0, 1.0, 0.0)


def page_uv(px, py, page_row=0):
    """A page pixel (x, y) to atlas UVs (scheme 0's page; others by uv_offset)."""
    return (px / PAGE_W, (py + page_row) / ATLAS_H)


def profile(n, hx, hz, front_bias=0.0):
    """A ring of n points round the limb (x front, z side), starting at the
    back (-X) and going round by the right (+Z), so the front is the wrap's middle."""
    import math
    pts = []
    for k in range(n):
        a = math.pi + 2 * math.pi * k / n          # from -X round
        x = math.cos(a) * hx
        z = -math.sin(a) * hz
        if x > 0:
            x *= 1 + front_bias
        pts.append((x, z))
    return pts


def loft(mesh, rings, n, region, cap_top=None, cap_bottom=None, page_row=0):
    """A faceted tube through rings (y, hx, hz, dx) of n sides: smooth
    normals round it, its sides wrapping the page region (u round, v down)."""
    import math
    x0, y0, x1, y1 = region
    prof = [profile(n, r[1], r[2]) for r in rings]
    ys = [r[0] for r in rings]
    dxs = [r[3] if len(r) > 3 else 0.0 for r in rings]
    span = max(ys) - min(ys)
    ytop = max(ys)
    grid = []
    for ri, ring in enumerate(prof):
        row = []
        for k in range(n + 1):
            px, pz = ring[k % n]
            a = math.pi + 2 * math.pi * (k % n) / n
            nx, nz = math.cos(a), -math.sin(a)
            u = x0 + (x1 - x0) * k / n
            v = y0 + (y1 - y0) * ((ytop - ys[ri]) / span if span > 0 else 0)
            v = min(max(v, y0 + 0.5), y1 - 0.5)
            u = min(max(u, x0 + 0.5), x1 - 0.5)
            row.append(mesh.vert((px + dxs[ri], ys[ri], pz), norm3((nx, 0.15 if ri == 0 else 0.0, nz)), page_uv(u, v, page_row)))
        grid.append(row)
    for ri in range(len(rings) - 1):
        for k in range(n):
            a, b = grid[ri][k], grid[ri][k + 1]
            c, d = grid[ri + 1][k + 1], grid[ri + 1][k]
            # outward, counter-clockwise from outside (y down the rings)
            mesh.tri(a, d, c)
            mesh.tri(a, c, b)

    def cap(ri, up, region_cap):
        cx0, cy0, cx1, cy1 = region_cap
        uv = page_uv((cx0 + cx1) / 2, (cy0 + cy1) / 2, page_row)
        ring = prof[ri]
        ids = [mesh.vert((p[0] + dxs[ri], ys[ri], p[1]), (0.0, 1.0 if up else -1.0, 0.0), uv) for p in ring]
        for k in range(1, n - 1):
            if up:
                mesh.tri(ids[0], ids[k + 1], ids[k])
            else:
                mesh.tri(ids[0], ids[k], ids[k + 1])

    if cap_top:
        cap(0, True, cap_top)
    if cap_bottom:
        cap(len(rings) - 1, False, cap_bottom)
    return mesh


def box(mesh, x0, x1, y0, y1, z0, z1, region, page_row=0, taper=1.0):
    """A box (its top `taper` times narrower in x and z), each face the region."""
    rx0, ry0, rx1, ry1 = region
    cxm = (x0 + x1) / 2
    czm = (z0 + z1) / 2

    def top(x, z):
        return (cxm + (x - cxm) * taper, czm + (z - czm) * taper)

    corners = {}
    for xi, x in enumerate((x0, x1)):
        for zi, z in enumerate((z0, z1)):
            tx, tz = top(x, z)
            corners[(xi, 0, zi)] = (x, y0, z)
            corners[(xi, 1, zi)] = (tx, y1, tz)
    faces = [
        ((1, 0, 0), [(1, 0, 0), (1, 0, 1), (1, 1, 1), (1, 1, 0)]),
        ((-1, 0, 0), [(0, 0, 1), (0, 0, 0), (0, 1, 0), (0, 1, 1)]),
        ((0, 1, 0), [(0, 1, 0), (1, 1, 0), (1, 1, 1), (0, 1, 1)]),
        ((0, -1, 0), [(0, 0, 1), (1, 0, 1), (1, 0, 0), (0, 0, 0)]),
        ((0, 0, 1), [(1, 0, 1), (0, 0, 1), (0, 1, 1), (1, 1, 1)]),
        ((0, 0, -1), [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)]),
    ]
    uvs = [(rx0 + 0.5, ry1 - 0.5), (rx1 - 0.5, ry1 - 0.5), (rx1 - 0.5, ry0 + 0.5), (rx0 + 0.5, ry0 + 0.5)]
    for n, quad in faces:
        ids = [mesh.vert(corners[c], n, page_uv(*uvs[i], page_row)) for i, c in enumerate(quad)]
        # counter-clockwise seen from outside
        mesh.tri(ids[0], ids[2], ids[1])
        mesh.tri(ids[0], ids[3], ids[2])
    return mesh


def board_mesh():
    """The board: a 1.55 x 0.28 m slab, its nose and tail rounded by a
    trapezoid each, 0.035 m thick; the base and the top deck on the board page."""
    m = Mesh()
    half_l = 0.775
    half_w = 0.14
    t = rig.BOARD_TOP
    # the outline (x across, z along), round from the nose
    outline = [(-0.10, -half_l), (0.10, -half_l), (half_w, -half_l + 0.12), (half_w, half_l - 0.12),
               (0.10, half_l), (-0.10, half_l), (-half_w, half_l - 0.12), (-half_w, -half_l + 0.12)]

    def base_uv(x, z, top):
        r = BOARD_TOP if top else BOARD_BASE
        rx0, ry0, rx1, ry1 = r
        u = rx0 + 0.5 + (x + half_w) / (2 * half_w) * (rx1 - rx0 - 1)
        v = ry0 + 0.5 + (z + half_l) / (2 * half_l) * (ry1 - ry0 - 1)
        return (u / PAGE_W, v / ATLAS_H)

    top = [m.vert((x, t, z), (0, 1, 0), base_uv(x, z, True)) for x, z in outline]
    bot = [m.vert((x, 0.0, z), (0, -1, 0), base_uv(x, z, False)) for x, z in outline]
    n = len(outline)
    for k in range(1, n - 1):
        m.tri(top[0], top[k + 1], top[k])
        m.tri(bot[0], bot[k], bot[k + 1])
    # the edges
    for k in range(n):
        a = outline[k]
        b = outline[(k + 1) % n]
        nx, nz = b[1] - a[1], -(b[0] - a[0])
        nn = norm3((nx, 0, nz))
        nn = (-nn[0], 0.0, -nn[2]) if nn[0] * (a[0] + b[0]) + nn[2] * (a[1] + b[1]) < 0 else nn
        uv = base_uv(0, 0, False)
        i0 = m.vert((a[0], 0.0, a[1]), nn, uv)
        i1 = m.vert((b[0], 0.0, b[1]), nn, uv)
        i2 = m.vert((b[0], t, b[1]), nn, uv)
        i3 = m.vert((a[0], t, a[1]), nn, uv)
        m.tri(i0, i2, i1)
        m.tri(i0, i3, i2)
    return m


def fix_winding(m):
    """Every triangle wound counter-clockwise seen from outside: its face's
    normal agreeing with its vertices' (the generators above disagree in places)."""
    for t in range(0, len(m.idx), 3):
        a, b, c = m.idx[t], m.idx[t + 1], m.idx[t + 2]
        pa, pb, pc = m.pos[a], m.pos[b], m.pos[c]
        e1 = (pb[0] - pa[0], pb[1] - pa[1], pb[2] - pa[2])
        e2 = (pc[0] - pa[0], pc[1] - pa[1], pc[2] - pa[2])
        fn = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
        vn = tuple(m.nrm[a][i] + m.nrm[b][i] + m.nrm[c][i] for i in range(3))
        if fn[0] * vn[0] + fn[1] * vn[1] + fn[2] * vn[2] < 0:
            m.idx[t + 1], m.idx[t + 2] = c, b
    return m


def parts():
    """name -> (Mesh, the joint it hangs under)."""
    out = {}
    # pelvis: under the Hips
    m = Mesh()
    loft(m, [(0.10, 0.12, 0.17), (-0.04, 0.13, 0.18), (-0.14, 0.11, 0.15)], 6, REG["pelvis"],
         cap_bottom=REG["cap_trousers"])
    out["Pelvis"] = (m, "Hips")
    # the torso: a baggy jacket from the waist to the shoulders
    m = Mesh()
    loft(m, [(0.56, 0.08, 0.10), (0.48, 0.14, 0.24), (0.26, 0.16, 0.22), (-0.02, 0.14, 0.19)], 8, REG["torso"],
         cap_top=REG["cap_jacket"], cap_bottom=REG["cap_jacket"])
    out["Torso"] = (m, "Hips/Chest")
    # the head on its neck, the face at the front (+X)
    m = Mesh()
    loft(m, [(0.30, 0.07, 0.07), (0.26, 0.10, 0.095), (0.10, 0.10, 0.09), (0.04, 0.05, 0.05), (-0.02, 0.05, 0.05)], 6,
         REG["head"], cap_top=REG["cap_skin"])
    out["Head"] = (m, "Hips/Chest/Neck")
    # the beanie with the goggles on its front, a pompom
    m = Mesh()
    loft(m, [(0.38, 0.03, 0.03), (0.35, 0.08, 0.075), (0.27, 0.115, 0.11), (0.19, 0.115, 0.11)], 6, REG["beanie"],
         cap_top=REG["cap_dark"], cap_bottom=REG["cap_dark"])
    box(m, -0.03, 0.03, 0.38, 0.43, -0.03, 0.03, REG["cap_jacket"], taper=0.6)
    out["Beanie"] = (m, "Hips/Chest/Neck")
    for side in ("L", "R"):
        m = Mesh()
        loft(m, [(0.03, 0.07, 0.07), (-0.14, 0.075, 0.075), (-0.28, 0.065, 0.065)], 6, REG["upperarm"])
        out["UpperArm" + side] = (m, f"Hips/Chest/Shoulder{side}")
        m = Mesh()
        loft(m, [(0.02, 0.06, 0.06), (-0.20, 0.065, 0.065), (-0.25, 0.07, 0.07)], 6, REG["lowerarm"],
             cap_bottom=REG["cap_jacket"])
        out["LowerArm" + side] = (m, f"Hips/Chest/Shoulder{side}/Elbow{side}")
        m = Mesh()
        box(m, -0.035, 0.05, -0.12, 0.0, -0.045, 0.045, REG["hand"], taper=1.1)
        out["Hand" + side] = (m, f"Hips/Chest/Shoulder{side}/Elbow{side}/Wrist{side}")
        m = Mesh()
        loft(m, [(0.04, 0.095, 0.095), (-0.20, 0.10, 0.095), (-0.41, 0.08, 0.08)], 6, REG["upperleg"])
        out["UpperLeg" + side] = (m, f"Hips/Hip{side}")
        m = Mesh()
        loft(m, [(0.02, 0.08, 0.08), (-0.30, 0.085, 0.085), (-0.38, 0.10, 0.095)], 6, REG["lowerleg"],
             cap_bottom=REG["cap_trousers"])
        out["LowerLeg" + side] = (m, f"Hips/Hip{side}/Knee{side}")
        m = Mesh()
        # the boot: from above the ankle to the board's top, its toe to +X
        box(m, -0.09, 0.15, -rig.ANKLE_UP, 0.06, -0.065, 0.065, REG["boot"], taper=0.8)
        out["Boot" + side] = (m, f"Hips/Hip{side}/Knee{side}/Ankle{side}")
    for name in out:
        fix_winding(out[name][0])
    board = fix_winding(board_mesh())
    return out, board


def write_gltf(path, mesh):
    n = len(mesh.pos)
    buf = b"".join(struct.pack("<3f", *p) for p in mesh.pos)
    buf += b"".join(struct.pack("<3f", *v) for v in mesh.nrm)
    buf += b"".join(struct.pack("<2f", *t) for t in mesh.uv)
    off = len(buf)
    ib = b"".join(struct.pack("<H", i) for i in mesh.idx)
    buf += ib
    while len(buf) % 4:
        buf += b"\0"
    mins = [min(p[i] for p in mesh.pos) for i in range(3)]
    maxs = [max(p[i] for p in mesh.pos) for i in range(3)]
    g = {
        "asset": {"version": "2.0", "generator": "tools/make_rider.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "mesh", "mesh": 0}],
        "meshes": [{"name": os.path.basename(path)[:-5],
                    "primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0}]}],
        "materials": [{"name": "rider", "pbrMetallicRoughness": {"metallicFactor": 0.0, "roughnessFactor": 1.0}}],
        "buffers": [{"byteLength": len(buf), "uri": "data:application/octet-stream;base64," + base64.b64encode(buf).decode()}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": n * 12},
            {"buffer": 0, "byteOffset": n * 12, "byteLength": n * 12},
            {"buffer": 0, "byteOffset": n * 24, "byteLength": n * 8},
            {"buffer": 0, "byteOffset": off, "byteLength": len(ib)},
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": n, "type": "VEC3", "min": mins, "max": maxs},
            {"bufferView": 1, "componentType": 5126, "count": n, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": n, "type": "VEC2"},
            {"bufferView": 3, "componentType": 5123, "count": len(mesh.idx), "type": "SCALAR"},
        ],
    }
    text = json.dumps(g, indent=None, separators=(",", ":")) + "\n"
    old = open(path).read() if os.path.exists(path) else None
    if old != text:
        with open(path, "w") as f:
            f.write(text)


# ---- the scene -----------------------------------------------------------------------

SUN = "Vector3(-0.45, 0.47, -0.76)"


def joint_rest(path):
    for i, (name, parent, off) in enumerate(rig.JOINTS):
        if rig.joint_path(i) == path:
            return off
    raise KeyError(path)


def rscn(part_meshes):
    out = []
    w = out.append
    w('<?xml version="1.0" encoding="UTF-8"?>')
    w("<!-- Generated by tools/make_rider.py: do not edit. The segmented rider (docs/LOOK.md")
    w("     section 5, RIDER.md section 12): PLACEHOLDER art for the asset pipeline. Body is")
    w("     the board's place (run.as's RiderView moves it and poses the joints from")
    w("     lib/poses_data.as); the shadow, the spray, the burst and the sparkle are placed")
    w("     by the same view; the timelines Door, Lift and Scheme are its setters of the")
    w("     materials' screen_door, the shadow's lift and the page's scheme. -->")
    w('<rscn format="2">')
    w('  <ext_resource id="1_surface" type="Shader" path="res://psx/psx_surface.wgsl"/>')
    w('  <ext_resource id="2_shadow" type="Shader" path="res://psx/psx_blob_shadow.wgsl"/>')
    w('  <ext_resource id="3_sprite" type="Shader" path="res://psx/psx_sprite.wgsl"/>')
    w('  <ext_resource id="4_page" type="Texture2D" path="res://rider/textures/rider_page.png"/>')
    w('  <ext_resource id="5_puff" type="Texture2D" path="res://rider/textures/puff.png"/>')
    w('  <ext_resource id="6_star" type="Texture2D" path="res://rider/textures/star.png"/>')
    names = list(part_meshes.keys()) + ["Board"]
    for k, name in enumerate(names):
        w(f'  <ext_resource id="p{k}_{name}" type="PackedScene" path="res://rider/parts/{name}.gltf"/>')
    w("")
    for mat, extra in (("Mat_rider", []), ("Mat_board", [])):
        w(f'  <sub_resource id="{mat}" type="ShaderMaterial">')
        w('    <property name="shader">ExtResource("1_surface")</property>')
        w('    <property name="shader_parameter/albedo_texture">ExtResource("4_page")</property>')
        w(f'    <property name="shader_parameter/sun_direction">{SUN}</property>')
        w('    <property name="shader_parameter/sky_ambient">Color(0.53, 0.6, 0.78, 1)</property>')
        w('    <property name="shader_parameter/ground_ambient">Color(0.62, 0.64, 0.74, 1)</property>')
        w('    <property name="shader_parameter/overbright">1.2</property>')
        w('    <property name="shader_parameter/affine_near">1.5</property>')
        w("  </sub_resource>")
    w('  <sub_resource id="Mat_shadow" type="ShaderMaterial">')
    w('    <property name="shader">ExtResource("2_shadow")</property>')
    w('    <property name="render_priority">1</property>')
    w('    <property name="shader_parameter/shadow_color">Color(0.53, 0.6, 0.78, 1)</property>')
    w("  </sub_resource>")
    w('  <sub_resource id="Mesh_shadow" type="PlaneMesh">')
    w('    <property name="size">Vector2(1.4, 1.4)</property>')
    w('    <property name="material">SubResource("Mat_shadow")</property>')
    w("  </sub_resource>")
    for sid, tex, fx in (("puff", "5_puff", 4), ("star", "6_star", 4)):
        w(f'  <sub_resource id="Mat_{sid}" type="ShaderMaterial">')
        w('    <property name="shader">ExtResource("3_sprite")</property>')
        w(f'    <property name="shader_parameter/sprite_sheet">ExtResource("{tex}")</property>')
        w(f'    <property name="shader_parameter/frames_x">{fx}.0</property>')
        w("  </sub_resource>")
        w(f'  <sub_resource id="Quad_{sid}" type="QuadMesh">')
        w(f'    <property name="material">SubResource("Mat_{sid}")</property>')
        w("  </sub_resource>")
    w('  <sub_resource id="Ramp_age" type="Gradient">')
    w('    <property name="offsets">PackedFloat32Array(0, 1)</property>')
    w('    <property name="colors">PackedColorArray(1, 1, 1, 1, 1, 1, 1, 0)</property>')
    w("  </sub_resource>")
    w("")
    w('  <node name="Rider" type="Node3D"/>')
    w('  <node name="Body" type="Node3D" parent="."/>')
    w('  <node name="Board" parent="Body" instance="ExtResource(&quot;p{}_Board&quot;)"/>'.format(len(names) - 1))
    w('  <node name="mesh" parent="Body/Board">')
    w('    <property name="material_override">SubResource("Mat_board")</property>')
    w("  </node>")
    # the joints, in rig order
    for i, (name, parent, off) in enumerate(rig.JOINTS):
        path = rig.joint_path(i)
        par = "Body" if parent < 0 else "Body/" + rig.joint_path(parent)
        w(f'  <node name="{name}" type="Node3D" parent="{par}">')
        w(f'    <property name="position">Vector3({off[0]}, {off[1]}, {off[2]})</property>')
        w("  </node>")
    for k, (name, (mesh, joint)) in enumerate(part_meshes.items()):
        w(f'  <node name="{name}" parent="Body/{joint}" instance="ExtResource(&quot;p{k}_{name}&quot;)"/>')
        w(f'  <node name="mesh" parent="Body/{joint}/{name}">')
        w('    <property name="material_override">SubResource("Mat_rider")</property>')
        w("  </node>")
    # the blob shadow
    w('  <node name="Shadow" type="MeshInstance3D" parent=".">')
    w('    <property name="mesh">SubResource("Mesh_shadow")</property>')
    w('    <property name="cast_shadow">0</property>')
    w("  </node>")
    # the spray from the board's edge, the landing's burst, the perfect's sparkle
    w('  <node name="Spray" type="CPUParticles3D" parent=".">')
    w('    <property name="emitting">false</property>')
    w('    <property name="amount">48</property>')
    w('    <property name="lifetime">0.6</property>')
    w('    <property name="mesh">SubResource("Quad_puff")</property>')
    w('    <property name="emission_shape">3</property>')
    w('    <property name="emission_box_extents">Vector3(0.2, 0.05, 0.3)</property>')
    w('    <property name="direction">Vector3(0, 1, 0)</property>')
    w('    <property name="spread">60</property>')
    w('    <property name="initial_velocity_min">1.5</property>')
    w('    <property name="initial_velocity_max">3.5</property>')
    w('    <property name="gravity">Vector3(0, -6, 0)</property>')
    w('    <property name="scale_amount_min">0.25</property>')
    w('    <property name="scale_amount_max">0.45</property>')
    w('    <property name="color_ramp">SubResource("Ramp_age")</property>')
    w("  </node>")
    w('  <node name="Burst" type="CPUParticles3D" parent=".">')
    w('    <property name="emitting">false</property>')
    w('    <property name="one_shot">true</property>')
    w('    <property name="explosiveness">0.9</property>')
    w('    <property name="amount">24</property>')
    w('    <property name="lifetime">0.7</property>')
    w('    <property name="mesh">SubResource("Quad_puff")</property>')
    w('    <property name="emission_shape">1</property>')
    w('    <property name="emission_sphere_radius">0.4</property>')
    w('    <property name="direction">Vector3(0, 1, 0)</property>')
    w('    <property name="spread">80</property>')
    w('    <property name="initial_velocity_min">2</property>')
    w('    <property name="initial_velocity_max">4.5</property>')
    w('    <property name="gravity">Vector3(0, -7, 0)</property>')
    w('    <property name="scale_amount_min">0.3</property>')
    w('    <property name="scale_amount_max">0.6</property>')
    w('    <property name="color_ramp">SubResource("Ramp_age")</property>')
    w("  </node>")
    w('  <node name="Sparkle" type="CPUParticles3D" parent=".">')
    w('    <property name="emitting">false</property>')
    w('    <property name="one_shot">true</property>')
    w('    <property name="explosiveness">0.8</property>')
    w('    <property name="amount">6</property>')
    w('    <property name="lifetime">0.4</property>')
    w('    <property name="mesh">SubResource("Quad_star")</property>')
    w('    <property name="emission_shape">1</property>')
    w('    <property name="emission_sphere_radius">0.5</property>')
    w('    <property name="direction">Vector3(0, 1, 0)</property>')
    w('    <property name="spread">90</property>')
    w('    <property name="initial_velocity_min">0.5</property>')
    w('    <property name="initial_velocity_max">1.5</property>')
    w('    <property name="gravity">Vector3(0, 0, 0)</property>')
    w('    <property name="scale_amount_min">0.25</property>')
    w('    <property name="scale_amount_max">0.35</property>')
    w('    <property name="color_ramp">SubResource("Ramp_age")</property>')
    w("  </node>")
    w("")
    # the setters: each timeline linear from 0 to 1 over a second (Scheme: 0.25 a frame)
    torso = "Body/Hips/Chest/Torso/mesh"
    w('  <LinearAnimation name="Door" fps="60" duration="60" loopValue="oneShot">')
    for target in (torso, "Body/Board/mesh"):
        w(f'    <KeyedObject target="{target}">')
        w('      <KeyedProperty property="material_override:shader_parameter/screen_door">')
        w('        <KeyFrameDouble frame="0" value="0" interpolationType="linear"/>')
        w('        <KeyFrameDouble frame="60" value="1"/>')
        w("      </KeyedProperty>")
        w("    </KeyedObject>")
    w("  </LinearAnimation>")
    w('  <LinearAnimation name="Lift" fps="60" duration="60" loopValue="oneShot">')
    w('    <KeyedObject target="Shadow">')
    w('      <KeyedProperty property="material_override:shader_parameter/lift">')
    w('        <KeyFrameDouble frame="0" value="0" interpolationType="linear"/>')
    w('        <KeyFrameDouble frame="60" value="1"/>')
    w("      </KeyedProperty>")
    w("    </KeyedObject>")
    w("  </LinearAnimation>")
    w('  <LinearAnimation name="Scheme" fps="60" duration="3" loopValue="oneShot">')
    w(f'    <KeyedObject target="{torso}">')
    w('      <KeyedProperty property="material_override:shader_parameter/uv_offset:y">')
    w('        <KeyFrameDouble frame="0" value="0" interpolationType="linear"/>')
    w('        <KeyFrameDouble frame="3" value="0.75"/>')
    w("      </KeyedProperty>")
    w("    </KeyedObject>")
    w("  </LinearAnimation>")
    w("</rscn>")
    return "\n".join(out) + "\n"


def write(path, text):
    old = open(path).read() if os.path.exists(path) else None
    if old != text:
        with open(path, "w") as f:
            f.write(text)
        print("wrote " + os.path.relpath(path, ROOT))


def main():
    os.makedirs(PARTS, exist_ok=True)
    os.makedirs(TEX, exist_ok=True)
    # the textures
    atlas = Image.new("RGB", (PAGE_W, ATLAS_H), (0, 0, 0))
    for k, scheme in enumerate(SCHEMES):
        paint_page(atlas, k * PAGE_H, palette(scheme))
    paint_board(atlas)
    atlas.save(os.path.join(TEX, "rider_page.png"))
    paint_sprites()
    # the meshes
    part_meshes, board = parts()
    total = board.tris()
    for name, (mesh, _) in part_meshes.items():
        write_gltf(os.path.join(PARTS, name + ".gltf"), mesh)
        total += mesh.tris()
    write_gltf(os.path.join(PARTS, "Board.gltf"), board)
    write(os.path.join(RIDER, "rider.rscn"), rscn(part_meshes))
    print(f"rider: {len(part_meshes)} parts and the board, {total} triangles (board {board.tris()})")
    # the textures imported as the PSX look needs them: every texel, no mipmaps
    hedra = shutil.which("hedra")
    if hedra:
        for name in ("rider_page.png", "puff.png", "star.png"):
            subprocess.run([hedra, "import", os.path.join(TEX, name), "--set", "compress/mode=lossless",
                            "--set", "mipmaps/generate=false"], cwd=ROOT, check=False, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()


def pose_sheet(path, poses=None, scheme=0):
    """A scene of the rider in each pose of tools/make_poses.py side by side,
    for `hedra render` (no script runs there): each joint's rotation set as
    the pose table's. Written under world/rider/build/ (not built)."""
    rows = []
    for name, p in rig.POSES:
        ang, off = rig.solve(p)
        rows.append((name, ang, off))
    if poses:
        rows = [r for r in rows if r[0] in poses]
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<rscn format="1">',
           '  <ext_resource id="1_rider" type="PackedScene" path="res://rider/rider.rscn"/>',
           '  <ext_resource id="2_surface" type="Shader" path="res://psx/psx_surface.wgsl"/>',
           '  <sub_resource id="Mat_snow" type="ShaderMaterial">',
           '    <property name="shader">ExtResource("2_surface")</property>',
           '    <property name="shader_parameter/albedo">Color(0.92, 0.94, 1.0, 1)</property>',
           '  </sub_resource>',
           '  <sub_resource id="Mesh_snow" type="PlaneMesh">',
           '    <property name="size">Vector2(40, 40)</property>',
           '    <property name="material">SubResource("Mat_snow")</property>',
           '  </sub_resource>',
           '  <sub_resource id="Env" type="Environment">',
           '    <property name="background_mode">1</property>',
           '    <property name="background_color">Color(0.6, 0.7, 0.9, 1)</property>',
           '  </sub_resource>',
           '  <node name="Sheet" type="Node3D"/>',
           '  <node name="Env" type="WorldEnvironment" parent=".">',
           '    <property name="environment">SubResource("Env")</property>',
           '  </node>',
           '  <node name="Snow" type="MeshInstance3D" parent=".">',
           '    <property name="mesh">SubResource("Mesh_snow")</property>',
           '  </node>']
    n = len(rows)
    for k, (name, ang, off) in enumerate(rows):
        x = (k - (n - 1) / 2) * 1.9
        out.append(f'  <node name="R{k}" parent="." instance="ExtResource(&quot;1_rider&quot;)">')
        out.append(f'    <property name="position">Vector3(0, 0, {x:.3f})</property>')
        out.append("  </node>")
        for j, (jn, parent, rest) in enumerate(rig.JOINTS):
            jp = rig.joint_path(j)
            par = f"R{k}/Body" + ("" if parent < 0 else "/" + rig.joint_path(parent))
            a = ang[j]
            out.append(f'  <node name="{jn}" parent="{par}">')
            out.append(f'    <property name="rotation">Vector3({a[0]:.5f}, {a[1]:.5f}, {a[2]:.5f})</property>')
            if j == 0:
                out.append(f'    <property name="position">Vector3({rest[0] + off[0]:.4f}, {rest[1] + off[1]:.4f}, {rest[2] + off[2]:.4f})</property>')
            out.append("  </node>")
    span = n * 1.9
    out.append('  <node name="Cam" type="Camera3D" parent=".">')
    out.append(f'    <property name="position">Vector3({max(3.0, span * 0.62):.2f}, 1.0, 0)</property>')
    out.append('    <property name="rotation_degrees">Vector3(-4, 90, 0)</property>')
    out.append('    <property name="fov">40</property>')
    out.append('    <property name="current">true</property>')
    out.append("  </node>")
    out.append("</rscn>")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


if "--sheet" in sys.argv:
    names = [a for a in sys.argv[sys.argv.index("--sheet") + 1:] if not a.startswith("-")]
    pose_sheet(os.path.join(RIDER, "build", "pose_sheet.rscn"), names or None)
