#!/usr/bin/env python3
"""The course's PSX textures, drawn procedurally as pixel art (docs/LOOK.md,
section 4; docs/ASSETS.md, section 3): 64 x 64 to 256 x 256, 16 colours
(256 for the signage), every colour on the 15-bit grid, 1-bit alpha. They
are PLACEHOLDERS for the asset pipeline's generated and fitted textures
(ASSETS.md): the same names, sizes and palettes, so a final replaces a
file and nothing else.

Each texture is a grid of palette indices painted by a function here, then
written as an RGBA PNG (standard library only) into world/textures/, and
imported lossless without mipmaps (`hedra import ... --set
compress/mode=lossless --set mipmaps/generate=false`), as psx-style asks.

    python3 tools/make_textures.py            # write the PNGs and their .import files
    python3 tools/make_textures.py --check    # exit 1 when a PNG would change
    python3 .claude/skills/psx-style/scripts/psx_audit.py texture world/textures/<name>.png --max-colors 16
"""
import math
import os
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "world", "textures")
sys.path.insert(0, os.path.join(HERE, "course"))
sys.dont_write_bytecode = True

import pages  # noqa: E402


def rgb(h):
    h = h.lstrip("#")
    c = tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
    return tuple(min(248, (v // 8) * 8) for v in c)


class Tex:
    """A page of palette indices; index 0 may be transparent."""

    def __init__(self, w, h, palette, transparent=False, fill=0):
        self.w = w
        self.h = h
        self.pal = [rgb(c) for c in palette]
        self.transparent = transparent
        self.px = [fill] * (w * h)

    def set(self, x, y, i):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y * self.w + x] = i

    def get(self, x, y):
        return self.px[(y % self.h) * self.w + (x % self.w)]

    def rect(self, x0, y0, w, h, i):
        for y in range(y0, y0 + h):
            for x in range(x0, x0 + w):
                self.set(x, y, i)

    def png(self):
        raw = bytearray()
        for y in range(self.h):
            raw.append(0)
            for x in range(self.w):
                i = self.px[y * self.w + x]
                r, g, b = self.pal[i]
                a = 0 if (self.transparent and i == 0) else 255
                if a == 0:
                    r = g = b = 0
                raw += bytes((r, g, b, a))

        def chunk(tag, data):
            c = struct.pack(">I", len(data)) + tag + data
            return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


# ---- noise (periodic, so the tiles wrap) ---------------------------------------

def _h(ix, iy, seed):
    v = (ix * 374761393 + iy * 668265263 + seed * 1442695041) & 0xFFFFFFFF
    v = ((v ^ (v >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((v ^ (v >> 16)) & 0xFFFF) / 65535.0


def pnoise(x, y, cells, period, seed):
    """Value noise of `cells` cells across a period of `period` pixels."""
    fx = x * cells / period
    fy = y * cells / period
    ix = int(math.floor(fx))
    iy = int(math.floor(fy))
    tx = fx - ix
    ty = fy - iy
    tx = tx * tx * (3 - 2 * tx)
    ty = ty * ty * (3 - 2 * ty)
    a = _h(ix % cells, iy % cells, seed)
    b = _h((ix + 1) % cells, iy % cells, seed)
    c = _h(ix % cells, (iy + 1) % cells, seed)
    d = _h((ix + 1) % cells, (iy + 1) % cells, seed)
    return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty


def rnd(x, y, seed):
    return _h(x, y, seed)


# ---- a 5 x 7 font for the signage ------------------------------------------------
FONT = {
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01111", "10000", "10000", "10011", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "11011", "10001"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
    "!": ["00100", "00100", "00100", "00100", "00100", "00000", "00100"],
    "<": ["00010", "00100", "01000", "11111", "01000", "00100", "00010"],
    ">": ["01000", "00100", "00010", "11111", "00010", "00100", "01000"],
    " ": ["00000"] * 7,
}


def text_width(s, scale=1, gap=1):
    return len(s) * (5 + gap) * scale - gap * scale


def draw_text(t, s, x0, y0, ink, shadow=None, scale=1, gap=1, italic=0):
    """Blocky italic letters (each row shifted right by `italic` px every 2
    rows from the bottom) with a hard drop shadow."""
    for pass_ in (0, 1):
        if pass_ == 0 and shadow is None:
            continue
        x = x0
        for ch in s:
            g = FONT.get(ch, FONT[" "])
            for row in range(7):
                sh = italic * (6 - row) // 2
                for col in range(5):
                    if g[row][col] == "1":
                        for dy in range(scale):
                            for dx in range(scale):
                                px = x + col * scale + dx + sh
                                py = y0 + row * scale + dy
                                if pass_ == 0:
                                    t.set(px + scale, py + scale, shadow)
                                else:
                                    t.set(px, py, ink)
            x += (5 + gap) * scale


# ---- the textures -------------------------------------------------------------------

SNOW = ["#f8f8f8", "#e8f0f8", "#e0e8f8", "#d0d8f0", "#c8d0f0", "#b8c4e8", "#a8b8e0", "#98a8d8"]


def snow_groomed():
    t = Tex(64, 64, SNOW)
    for y in range(64):
        for x in range(64):
            # corduroy: straight ridges along the fall line every 4 texels (a
            # lit edge, a shaded groove), over broad soft patches
            ridge = x % 4
            n = pnoise(x, y, 4, 64, 3)
            base = 1 if n > 0.55 else 2
            v = base if ridge in (1, 2) else base - 1 if ridge == 0 else base + 1
            if rnd(x, y, 5) > 0.99:
                v = 0
            t.set(x, y, max(0, v))
    return t


def snow_powder():
    t = Tex(64, 64, SNOW)
    for y in range(64):
        for x in range(64):
            n = 0.6 * pnoise(x, y, 4, 64, 21) + 0.4 * pnoise(x, y, 8, 64, 22)
            # sastrugi: wind-carved drifts, banded
            n += 0.08 * math.sin((x * 0.6 + y * 0.25 + n * 9) * 2 * math.pi / 16)
            v = 0 if n > 0.68 else 1 if n > 0.56 else 2 if n > 0.45 else 3 if n > 0.36 else 4
            if rnd(x, y, 6) > 0.99:
                v = 0
            t.set(x, y, v)
    return t


def snow_packed():
    t = Tex(64, 64, SNOW)
    for y in range(64):
        for x in range(64):
            n = pnoise(x, y, 4, 64, 31)
            v = 1 if n > 0.6 else 2 if n > 0.4 else 3
            # board tracks down the kicker
            if (x + y // 8) % 16 in (3, 4) or (x - y // 6) % 21 == 7:
                v = min(5, v + 2)
            t.set(x, y, v)
    return t


def rock():
    pal = ["#383040", "#484058", "#585068", "#706070", "#807080", "#988898", "#c8d0f0", "#e8f0f8"]
    t = Tex(64, 64, pal)
    for y in range(64):
        for x in range(64):
            n = 0.55 * pnoise(x, y, 4, 64, 41) + 0.45 * pnoise(x, y, 8, 64, 42)
            v = 2 if n < 0.4 else 3 if n < 0.55 else 4 if n < 0.68 else 5
            # strata: dark cracks every ~11 rows, bent
            if (y + int(pnoise(x, y, 4, 64, 43) * 6)) % 11 == 0:
                v = 1
            if (x * 3 + y) % 23 == 0 and n < 0.5:
                v = 0
            # snow caught on the ledges
            if (y + int(pnoise(x, y, 4, 64, 43) * 6)) % 11 in (1,) and n > 0.5:
                v = 6 if rnd(x, y, 44) > 0.3 else 7
            t.set(x, y, v)
    return t


def ice():
    pal = ["#f8f8f8", "#d0e8f8", "#b8d8f0", "#a0c8e8", "#88b0d8", "#7098c8", "#5880b0", "#c8f0f8"]
    t = Tex(64, 64, pal)
    for y in range(64):
        for x in range(64):
            n = pnoise(x, y, 4, 64, 51)
            v = 2 if n > 0.6 else 3 if n > 0.4 else 4
            if abs(math.sin((x + y * 0.3) * 0.21 + n * 4)) < 0.05 or abs(math.sin((x * 0.4 - y) * 0.17)) < 0.03:
                v = 0 if rnd(x, y, 52) > 0.5 else 1
            if rnd(x, y, 53) > 0.992:
                v = 7
            t.set(x, y, v)
    return t


PINE = ["#000000", "#102820", "#183830", "#285040", "#387050", "#509060", "#a8b8e0", "#e0e8f8", "#f8f8f8", "#584038", "#786050"]


def pine(variant):
    t = Tex(64, 128, PINE, transparent=True)
    seed = 61 + variant
    # the trunk
    t.rect(29, 104, 6, 24, 9)
    t.rect(29, 104, 2, 24, 10)
    tiers = [(8, 30, 9), (28, 54, 15), (50, 80, 22), (74, 108, 29)]
    for k, (y0, y1, half) in enumerate(tiers):
        for y in range(y0, y1):
            f = (y - y0) / (y1 - y0)
            w = int(2 + half * f)
            for x in range(32 - w, 32 + w):
                edge = abs(x - 32) / max(w, 1)
                ragged = rnd(x, y, seed) * 3
                if edge > 0.92 and ragged > 1.6:
                    continue
                # light from the upper left; snow on top of each tier
                shade = 4 if x < 30 else 3 if x < 36 else 2
                if f > 0.8:
                    shade = 2 if x < 32 else 1
                if rnd(x // 3, y // 2, seed + 3) > 0.8:
                    shade = max(1, shade - 1)
                snow_line = y0 + (y1 - y0) * (0.35 if variant else 0.2)
                if y < snow_line + abs(x - 32) * 0.4 and rnd(x, y, seed + 5) > (0.25 if variant else 0.45):
                    shade = 7 if x < 33 else 6
                if variant and f > 0.7 and (x + y) % 7 == 0:
                    shade = 8
                t.set(x, y, shade)
        # a drooping snow lip under each tier
        for x in range(32 - half, 32 + half):
            if rnd(x, k, seed + 9) > 0.55:
                t.set(x, y1 - 1, 6)
    return t


def pine_cone():
    t = Tex(64, 64, PINE)
    for y in range(64):
        for x in range(64):
            n = pnoise(x, y, 8, 64, 71)
            v = 2 if n < 0.4 else 3 if n < 0.6 else 4
            if (x + (y // 4)) % 6 == 0:
                v = 1
            if y < 10 + int(n * 8) and rnd(x, y, 72) > 0.35:
                v = 7 if x % 3 else 6
            t.set(x, y, v)
    return t


def bark():
    pal = ["#382820", "#584038", "#705040", "#886848", "#a07850", "#c09868", "#d8b080", "#e0e8f8"]
    t = Tex(64, 64, pal)
    for y in range(32):
        for x in range(64):
            n = pnoise(x, y, 8, 64, 81)
            v = 2 if n < 0.45 else 3
            if (x + int(n * 5)) % 7 == 0:
                v = 0
            elif (x + int(n * 5)) % 7 == 1:
                v = 1
            if rnd(x, y, 82) > 0.97:
                v = 4
            t.set(x, y, v)
            t.set(x, y + 32 if y < 32 else y, v)
    # the lower half: a sawn end (rings) for the logs' supports and ends
    for y in range(32, 64):
        for x in range(64):
            d = math.hypot(x - 32, (y - 48) * 2)
            v = 5 if int(d) % 5 < 3 else 4
            if d > 28:
                v = 1
            t.set(x, y, v)
    return t


def box():
    pal = ["#101010", "#282830", "#404048", "#686870", "#f88818", "#c86010", "#f8f8f8", "#f83890"]
    t = Tex(64, 64, pal)
    # the top (rows 0 to 47): a slick dark slide surface, orange edges, scuffs
    for y in range(48):
        for x in range(64):
            v = 1 if (y // 4) % 2 else 2
            if x < 4 or x > 59:
                v = 4
            if rnd(x, y, 91) > 0.97:
                v = 3
            t.set(x, y, v)
    # the sides (48 to 63): orange with a black band and white stripes
    for y in range(48, 64):
        for x in range(64):
            v = 4 if y < 52 or y > 59 else 0
            if v == 0 and (x // 6) % 3 == 0:
                v = 6
            if y == 48:
                v = 5
            t.set(x, y, v)
    return t


def chrome_matcap():
    # sky band, a dark horizon, a warm ground, one hot highlight (psx-style)
    pal = ["#202038", "#384068", "#5870a8", "#88a8e0", "#b8d0f0", "#e0f0f8", "#f8f8f8", "#583848",
           "#885060", "#b87868", "#d8a088", "#f8d0b0", "#101020", "#f83890", "#f8a0c8"]
    t = Tex(64, 64, pal)
    for y in range(64):
        for x in range(64):
            dx = (x - 31.5) / 32
            dy = (y - 31.5) / 32
            r = math.hypot(dx, dy)
            if r > 1.0:
                t.set(x, y, 0)
                continue
            if dy < -0.05:
                k = (-dy) * (1 - r * 0.3)
                v = 5 if k > 0.7 else 4 if k > 0.5 else 3 if k > 0.3 else 2
            elif dy < 0.07:
                v = 12
            else:
                k = dy
                v = 8 if k > 0.6 else 9 if k > 0.35 else 10 if k > 0.18 else 11
            if r > 0.9:
                v = 1 if dy < 0 else 7
            if math.hypot(dx + 0.35, dy + 0.45) < 0.13:
                v = 6
            elif math.hypot(dx + 0.35, dy + 0.45) < 0.2:
                v = 5
            t.set(x, y, v)
    return t


def building():
    pal = ["#201818", "#483028", "#604030", "#785038", "#906048", "#a87858", "#c09068", "#f8d070", "#f8a040",
           "#e0e8f8", "#f8f8f8", "#a8b8e0", "#707888", "#909aa8", "#585060", "#f83890"]
    t = Tex(128, 128, pal)
    R = pages.BUILDING["regions"]

    def planks(x0, y0, w, h):
        for y in range(h):
            for x in range(w):
                v = 3 if (y // 8) % 2 else 4
                if y % 8 == 7:
                    v = 1
                elif y % 8 == 0:
                    v = 5
                if (x + (y // 8) * 13) % 31 == 0:
                    v = 2
                if rnd(x0 + x, y0 + y, 101) > 0.96:
                    v = 2
                t.set(x0 + x, y0 + y, v)
    x, y, w, h = R["planks"]
    planks(x, y, w, h)
    x, y, w, h = R["window"]
    planks(x, y, w, h)
    # a window with a warm light and a frame, snow on its sill
    t.rect(x + 16, y + 14, 32, 30, 1)
    t.rect(x + 18, y + 16, 28, 26, 7)
    t.rect(x + 18, y + 16, 28, 4, 8)
    t.rect(x + 31, y + 16, 2, 26, 1)
    t.rect(x + 18, y + 28, 28, 2, 1)
    t.rect(x + 14, y + 44, 36, 3, 10)
    x, y, w, h = R["roof"]
    for yy in range(h):
        for xx in range(w):
            v = 10 if yy < 20 else 9
            if yy >= 20 and rnd(xx, yy, 103) > 0.5:
                v = 11
            if yy > 26:
                v = 1 if (xx % 5) else 9   # the eave and its icicles
            t.set(x + xx, y + yy, v)
    x, y, w, h = R["door"]
    planks(x, y, w, h)
    t.rect(x + 6, y + 24, 20, 40, 1)
    t.rect(x + 8, y + 26, 16, 38, 2)
    t.rect(x + 20, y + 44, 2, 3, 7)
    t.rect(x + 2, y + 6, 28, 12, 15)
    x, y, w, h = R["metal"]
    for yy in range(h):
        for xx in range(w):
            t.set(x + xx, y + yy, 13 if (yy // 8) % 2 else 12)
            if xx % 8 == 3 and yy % 8 == 3:
                t.set(x + xx, y + yy, 10)
    x, y, w, h = R["concrete"]
    for yy in range(h):
        for xx in range(w):
            v = 13 if rnd(xx // 2, yy // 2, 104) > 0.4 else 12
            if yy % 16 == 15:
                v = 14
            t.set(x + xx, y + yy, v)
    x, y, w, h = R["timber"]
    for yy in range(h):
        for xx in range(w):
            v = 2 if (xx // 4) % 2 else 1
            t.set(x + xx, y + yy, v)
    return t


def lift():
    pal = ["#101018", "#303848", "#485868", "#607080", "#8898a8", "#b0c0d0", "#f8f8f8", "#c82020",
           "#f83838", "#f8d020", "#202020", "#a8d8f0", "#5888b0", "#f88818", "#3858a8", "#e0e8f8"]
    t = Tex(128, 128, pal)
    R = pages.LIFT["regions"]
    x, y, w, h = R["steel"]
    for yy in range(h):
        for xx in range(w):
            v = 3 if xx % 16 < 10 else 2
            if xx % 16 == 0:
                v = 5
            if yy % 16 == 0:
                v = 1
            t.set(x + xx, y + yy, v)
    x, y, w, h = R["seat"]
    for yy in range(h):
        for xx in range(w):
            t.set(x + xx, y + yy, 8 if yy < 20 else 7)
            if yy % 8 == 0:
                t.set(x + xx, y + yy, 7)
    x, y, w, h = R["cabin"]
    for yy in range(h):
        for xx in range(w):
            v = 8
            if 12 <= yy < 34 and xx % 16 not in (0, 1):
                v = 11 if yy < 20 else 12
            if yy >= 56:
                v = 7
            t.set(x + xx, y + yy, v)
    x, y, w, h = R["cable"]
    t.rect(x, y, w, h, 10)
    x, y, w, h = R["yellow"]
    for yy in range(h):
        for xx in range(w):
            t.set(x + xx, y + yy, 9 if ((xx + yy) // 6) % 2 else 10)
    x, y, w, h = R["station"]
    t.rect(x, y, w, h, 14)
    draw_text(t, "NEON PEAK", x + 4, y + 9, 6, shadow=0, scale=2, italic=2)
    return t


SIGN = ["#000000", "#101848", "#f8f8f8", "#f83890", "#a8f830", "#f88818", "#30d8f8", "#f8f058", "#f850b0",
        "#50f0f8", "#202020", "#c0c8d8", "#283890", "#8818a8", "#e0e8f8", "#58c020"]


def banners():
    t = Tex(256, 256, SIGN)
    R = pages.BANNERS["regions"]
    designs = {
        "frostbyte": (6, 2, 1, ["FROSTBYTE", "WAX"]),
        "neonpeak": (1, 8, 9, ["NEON PEAK", "RESORT"]),
        "avalanche": (3, 2, 0, ["AVALANCHE", "AIR"]),
        "chillwave": (9, 1, 3, ["CHILLWAVE", "SODA"]),
        "pow": (7, 0, 3, ["POW!", "GOGGLES"]),
        "radical": (4, 0, 5, ["RADICAL", "ENERGY"]),
        "highline": (5, 2, 0, ["< HIGH", "LINE"]),
        "lowline": (6, 2, 0, ["LOW >", "LINE"]),
    }
    for name, (bg, ink, accent, lines) in designs.items():
        x, y, w, h = R[name]
        t.rect(x, y, w, h, bg)
        # slanted accent bars, a dark border
        for yy in range(h):
            for xx in range(w):
                if (xx + yy) % 32 < 4 and (xx < 18 or xx > w - 18):
                    t.set(x + xx, y + yy, accent)
        for xx in range(w):
            t.set(x + xx, y, 0)
            t.set(x + xx, y + h - 1, 0)
            t.set(x + xx, y + 1, accent)
            t.set(x + xx, y + h - 2, accent)
        for yy in range(h):
            t.set(x, y + yy, 0)
            t.set(x + w - 1, y + yy, 0)
        big, small = lines
        sc = 2 if text_width(big, 2) <= w - 12 else 1
        tw = text_width(big, sc) + 4
        draw_text(t, big, x + (w - tw) // 2, y + 10, ink, shadow=0 if bg != 0 else 1, scale=sc, italic=2)
        tw2 = text_width(small, 2) + 4
        draw_text(t, small, x + (w - tw2) // 2, y + 36, ink if bg != 4 else 0, shadow=0 if bg != 0 else 1, scale=2, italic=2)
    return t


def arches():
    t = Tex(256, 256, SIGN)
    R = pages.ARCHES["regions"]
    designs = {
        "start": (3, 2, 6, ["START"]),
        "split": (12, 2, 4, ["< HIGH", "LOW >"]),
        "finish": (1, 7, 3, ["FINISH"]),
        "mega": (0, 8, 9, ["AVALANCHE", "AIR"]),
    }
    for name, (bg, ink, stripe, words) in designs.items():
        x, y, w, h = R[name]
        # the top half: the words on the band
        t.rect(x, y, w, h // 2, bg)
        for xx in range(w):
            t.set(x + xx, y, stripe)
            t.set(x + xx, y + 1, stripe)
            t.set(x + xx, y + h // 2 - 1, stripe)
            t.set(x + xx, y + h // 2 - 2, stripe)
        if len(words) == 1:
            sc = 3 if text_width(words[0], 3) <= w - 8 else 2
            tw = text_width(words[0], sc)
            draw_text(t, words[0], x + (w - tw) // 2 - 2, y + 32 - 7 * sc // 2, ink, shadow=0 if bg else 1, scale=sc, italic=2)
        else:
            for k, wd in enumerate(words):
                sc = 2
                tw = text_width(wd, sc)
                draw_text(t, wd, x + (w - tw) // 2 - 2, y + 8 + k * 26, ink, shadow=0 if bg else 1, scale=sc, italic=2)
        # the bottom half: the inflatable's stripes, lit from above
        for yy in range(h // 2, h):
            for xx in range(w):
                band = ((xx + yy) // 10) % 3
                v = (3, 2, stripe)[band] if name != "mega" else (8, 0, 9)[band]
                if yy > h - 8:
                    v = 10 if v == 2 else 1
                t.set(x + xx, y + yy, v)
    return t


def fence():
    pal = ["#000000", "#f88818", "#c86010", "#583828", "#785040"]
    t = Tex(64, 32, pal, transparent=True)
    for y in range(4, 30):
        for x in range(64):
            # the orange mesh: diamonds with holes
            u = (x + y) % 8
            v = (x - y) % 8
            if u in (0, 1) or v in (0, 1):
                t.set(x, y, 1 if y < 20 else 2)
    for y in range(4, 6):
        for x in range(64):
            t.set(x, y, 1)
    for y in range(0, 32):
        for x in (0, 1, 2):
            t.set(x, y, 3 if x < 2 else 4)
    return t


def crowd():
    pal = ["#000000", "#f8c8a0", "#c89070", "#202020", "#f83890", "#30d8f8", "#a8f830", "#f88818", "#384890",
           "#f8f8f8", "#583828", "#f8f058", "#707888"]
    t = Tex(128, 64, pal, transparent=True)
    jackets = [(4, 8), (5, 3), (6, 8), (7, 12)]
    hats = [11, 4, 5, 9]
    for k in range(4):
        x0 = k * 32
        jacket, pants = jackets[k]
        # a figure, arms up on the left two
        t.rect(x0 + 12, 6, 8, 4, hats[k])          # beanie
        t.rect(x0 + 12, 10, 8, 8, 1)               # face
        t.rect(x0 + 13, 12, 6, 2, 3)               # goggles
        t.rect(x0 + 10, 18, 12, 18, jacket)        # jacket
        t.rect(x0 + 11, 36, 10, 22, pants)         # trousers
        t.rect(x0 + 10, 58, 5, 6, 3)
        t.rect(x0 + 17, 58, 5, 6, 3)
        if k % 2 == 0:
            t.rect(x0 + 6, 4, 4, 16, jacket)       # arms up
            t.rect(x0 + 22, 4, 4, 16, jacket)
            t.rect(x0 + 6, 2, 4, 3, 1)
            t.rect(x0 + 22, 2, 4, 3, 1)
        else:
            t.rect(x0 + 6, 18, 4, 14, jacket)
            t.rect(x0 + 22, 18, 4, 14, jacket)
    return t


def mountains():
    pal = ["#000000", "#58608c", "#6870a0", "#7880b0", "#9098c0", "#b0b8d8", "#d0d8f0", "#f0f0f8"]
    t = Tex(256, 64, pal, transparent=True)
    for x in range(256):
        hgt = (0.45 * pnoise(x, 0, 4, 256, 121) + 0.35 * pnoise(x, 0, 9, 256, 122) + 0.2 * pnoise(x, 0, 23, 256, 123))
        top = int(64 - (10 + hgt * 50))
        snowline = top + 6 + int(pnoise(x, 1, 13, 256, 124) * 10)
        for y in range(top, 64):
            # light from the left of each ridge
            slope = (pnoise(x + 1, 0, 9, 256, 122) - pnoise(x - 1, 0, 9, 256, 122))
            if y < snowline:
                v = 7 if slope > 0 else 6
            else:
                v = 4 if slope > 0 else 3
                if y > 52:
                    v = 2
            t.set(x, y, v)
    return t


def fx_flake():
    """Two frames of a snow flake (8 x 8 each): psx_sprite's flipbook."""
    t = Tex(16, 8, ["#000000", "#f8f8f8", "#c8d0f0"], transparent=True)
    for (x, y, i) in ((3, 2, 1), (4, 2, 1), (3, 3, 1), (4, 3, 1), (2, 3, 2), (5, 4, 2), (3, 4, 1), (4, 4, 2)):
        t.set(x, y, i)
    for (x, y, i) in ((11, 3, 1), (12, 3, 1), (11, 4, 1), (12, 4, 2), (13, 2, 2)):
        t.set(x, y, i)
    return t


def fx_confetti():
    """Two frames of a confetti scrap (white: the emitter tints it): flat, then edge-on."""
    t = Tex(16, 8, ["#000000", "#f8f8f8", "#c0c8d8"], transparent=True)
    t.rect(2, 2, 4, 3, 1)
    t.rect(2, 4, 4, 1, 2)
    t.rect(11, 3, 3, 1, 1)
    return t


def fx_flare():
    """Four flat shapes for the lens flare (16 x 16 each, on black: drawn
    on psx_cutout's 1-bit alpha): the sun's star, a ring, a hexagon, a dot."""
    t = Tex(64, 16, ["#000000", "#f8f0c8", "#f8c878", "#f87850", "#a84878", "#683870"], transparent=True)
    for y in range(16):
        for x in range(16):
            d = math.hypot(x - 7.5, y - 7.5)
            if d < 3:
                t.set(x, y, 1)
            elif d < 5:
                t.set(x, y, 2)
            elif (abs(x - 7.5) < 1 or abs(y - 7.5) < 1) and d < 8:
                t.set(x, y, 3)
            if 5 <= d < 7.5 and t.get(x, y) == 0:
                t.set(x, y, 5)
            # the ring
            if 5.5 <= d < 7.5:
                t.set(16 + x, y, 4)
            # the hexagon
            ax = abs(x - 7.5)
            ay = abs(y - 7.5)
            if ay < 6.5 and ax < 7.5 - ay * 0.55:
                t.set(32 + x, y, 4 if ax < 6 - ay * 0.55 else 3)
            if d < 3.2:
                t.set(48 + x, y, 2 if d < 2 else 3)
    return t


TEXTURES = {
    "fx_flake": (fx_flake, 16), "fx_confetti": (fx_confetti, 16), "fx_flare": (fx_flare, 16),
    "snow_groomed": (snow_groomed, 16), "snow_powder": (snow_powder, 16), "snow_packed": (snow_packed, 16),
    "rock": (rock, 16), "ice": (ice, 16), "pine_a": (lambda: pine(0), 16), "pine_b": (lambda: pine(1), 16),
    "pine_cone": (pine_cone, 16), "bark": (bark, 16), "box": (box, 16), "chrome_matcap": (chrome_matcap, 32),
    "building": (building, 16), "lift": (lift, 16), "banners": (banners, 256), "arches": (arches, 256),
    "fence": (fence, 16), "crowd": (crowd, 16), "mountains": (mountains, 16),
}


def main():
    check = "--check" in sys.argv
    os.makedirs(OUT, exist_ok=True)
    changed = []
    for name in sorted(TEXTURES):
        fn, colors = TEXTURES[name]
        t = fn()
        used = len(set(t.pal[i] for i in t.px if not (t.transparent and i == 0)))
        if used > colors:
            sys.exit("%s: %d colours, at most %d" % (name, used, colors))
        data = t.png()
        path = os.path.join(OUT, name + ".png")
        old = open(path, "rb").read() if os.path.exists(path) else None
        if old != data:
            changed.append(path)
            if not check:
                with open(path, "wb") as f:
                    f.write(data)
    if not check:
        pngs = [os.path.join(OUT, n + ".png") for n in sorted(TEXTURES)]
        need = [p for p in pngs if p in changed or not os.path.exists(p + ".import")]
        for p in need:
            subprocess.run(["hedra", "import", os.path.relpath(p, ROOT), "--set", "compress/mode=lossless",
                            "--set", "mipmaps/generate=false", "--text"], check=True, stdout=subprocess.DEVNULL, cwd=ROOT)
    for p in changed:
        print(("would change " if check else "wrote ") + os.path.relpath(p, ROOT))
    sys.exit(1 if check and changed else 0)


if __name__ == "__main__":
    main()
