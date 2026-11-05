"""shots/course_map.png: the course from above (north up the course), one
pixel every 1.5 m: the terrain shaded, the pistes, the lines, the
features with their ids, the rails, the trees, the obstacles."""
import math
import struct
import zlib

import course as C
from build import G
from samples import ROCK_NY

FONT = {
    "A": "010101111101101", "B": "110101110101110", "C": "011100100100011", "D": "110101101101110",
    "E": "111100110100111", "F": "111100110100100", "G": "011100101101011", "H": "101101111101101",
    "I": "111010010010111", "J": "001001001101010", "K": "101101110101101", "L": "100100100100111",
    "M": "101111111101101", "N": "110101101101101", "O": "010101101101010", "P": "110101110100100",
    "R": "110101110101101", "S": "011100010001110", "T": "111010010010010", "U": "101101101101111",
    "V": "101101101101010", "W": "101101111111101", "X": "101101010101101", "Y": "101101010010010",
    "Z": "111001010100111", "0": "111101101101111", "1": "010110010010111", "2": "110001010100111",
    "3": "110001010001110", "4": "101101111001001", "5": "111100110001110", "6": "011100111101111",
    "7": "111001010010010", "8": "111101111101111", "9": "111101111001110", "_": "000000000000111",
}


def write_png(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def png(course):
    d = course.data
    g = d.grid
    cmin = min(g.c0)
    cmax = max(g.c1)
    W = cmax - cmin + 1
    H = g.rows
    img = bytearray(W * H * 3)

    def put(x, y, c):
        if 0 <= x < W and 0 <= y < H:
            i = (y * W + x) * 3
            img[i:i + 3] = bytes(c)

    def to_px(x, z):
        return int(round((x - g.X0) / G)) - cmin, int(round((g.Z0 - z) / G))

    for r in range(g.rows):
        for c in range(g.c0[r], g.c1[r]):
            if r + 1 >= g.rows or not (g.c0[r + 1] <= c <= g.c1[r + 1] - 1):
                continue
            h0 = g.node(r, c)
            hx = g.node(r, c + 1)
            hz = g.node(r + 1, c)
            gx = (hx - h0) / G
            gz = (hz - h0) / G
            ny = 1 / math.sqrt(1 + gx * gx + gz * gz)
            shade = max(0.35, min(1.0, 0.75 + 0.5 * (-gx * 0.5 + gz * 0.6)))
            x = g.x_of(c)
            z = g.z_of(r)
            if ny < ROCK_NY:
                col = (110, 96, 112)
            elif g.in_lake(x, z):
                col = (150, 200, 230)
            elif d.in_piste(x, z):
                col = (236, 240, 248)
            else:
                col = (190, 200, 222)
            put(c - cmin, r, tuple(int(v * shade) for v in col))
    for x, y, z, h, w, yaw, var in course.forest.trees:
        px, py = to_px(x, z)
        put(px, py, (40, 90, 64))
    for x, y, z, h, yaw in course.forest.cones:
        px, py = to_px(x, z)
        for dx in (-1, 0, 1):
            put(px + dx, py, (24, 70, 48))
    for o in course.forest.obstacles:
        if o["kind"] == "prop":
            px, py = to_px(o["x"], o["z"])
            put(px, py, (200, 120, 40))
    for smp, col in ((d.main_samples, (248, 56, 144)), (d.high_samples, (48, 216, 248))):
        for s in smp:
            px, py = to_px(s["x"], s["z"])
            put(px, py, col if not s["safe"] else (col[0] // 2, col[1] // 2, col[2] // 2))
    for rl in d.rails:
        for p in rl["pts"]:
            px, py = to_px(p[0], p[2])
            put(px, py, (248, 136, 24))

    def label(text, px, py, col):
        x = px
        for ch in text:
            bits = FONT.get(ch.upper())
            if bits:
                for i, b in enumerate(bits):
                    if b == "1":
                        put(x + i % 3, py + i // 3, col)
            x += 4
    for f in d.features:
        o = f["overlay"]
        if o is not None:
            ox, oz = o.frame[0], o.frame[1]
        else:
            p = d.rails[f["rail"]]["pts"][0]
            ox, oz = p[0], p[2]
        px, py = to_px(ox, oz)
        for k in range(-2, 3):
            put(px + k, py, (168, 248, 48))
            put(px, py + k, (168, 248, 48))
        label(f["id"], px + 4, py - 2, (16, 24, 72))
    return write_png(W, H, img)
