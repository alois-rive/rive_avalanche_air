"""The course's runtime data computed from the built geometry: the line
samples with their respawn flags, the rails' polylines, the features'
table, the trees and the obstacles, the fall zones, the sun's keys."""
import math

import course as C
from build import BLK, G, frame, line_of
from geom import DEG, lerp, section_of, smoothstep

SURF_GROOMED, SURF_POWDER, SURF_ICE, SURF_ROCK = 0, 1, 2, 3
FEAT_ROLLER, FEAT_KICKER, FEAT_DROP, FEAT_MEGA, FEAT_RAIL, FEAT_GAP = 1, 2, 3, 4, 5, 6
RAIL_RAIL, RAIL_BOX, RAIL_LOG = 1, 2, 3
RAIL_KINKED, RAIL_RAINBOW = 16, 32
ROCK_NY = 0.64


class Rng:
    """A small deterministic generator (xorshift32)."""

    def __init__(self, seed):
        self.s = (seed * 2654435761) & 0xFFFFFFFF or 1

    def next(self):
        s = self.s
        s ^= (s << 13) & 0xFFFFFFFF
        s ^= s >> 17
        s ^= (s << 5) & 0xFFFFFFFF
        self.s = s
        return s / 4294967296.0

    def range(self, a, b):
        return a + (b - a) * self.next()


def mapped_s(line_name, s):
    if line_name != "high":
        return s
    return C.SPLIT_S + (s - C.SPLIT_S) * (C.MERGE_S - C.SPLIT_S) / C.HIGH_LENGTH


class Data:
    def __init__(self, main, high, mega, base, feats, grid):
        self.main = main
        self.high = high
        self.mega = mega
        self.base = base
        self.feats = feats
        self.grid = grid
        self.piste = grid.piste_rows()
        self.jump_ovs = [o for o in feats.overlays if o.kind in ("kicker", "drop", "gap", "mega", "ramp")]
        self.rails = self.make_rails()
        self.features = self.make_features()
        self.main_samples = self.make_samples(main, "main", 0.0, C.LINE_END)
        self.high_samples = self.make_samples(high, "high", C.SPLIT_S, C.SPLIT_S + C.HIGH_LENGTH)
        self.fall = self.make_fall()
        self.sun = self.make_sun()

    # --- the surface ------------------------------------------------------
    def in_piste(self, x, z):
        r = int(round((self.grid.Z0 - z) / G))
        r = max(0, min(self.grid.rows - 1, r))
        for a, b in self.piste[r]:
            if a <= x <= b:
                return True
        return False

    def roof_at(self, x, z):
        rf = self.feats.roof
        ox, oz, fx, fz, rx, rz = rf["frame"]
        u = (x - ox) * fx + (z - oz) * fz
        v = (x - ox) * rx + (z - oz) * rz
        return rf["u0"] <= u <= rf["u1"] and abs(v) <= rf["half_w"]

    def ground(self, x, z):
        """(y, normal, surface) as course_api.as answers, or None."""
        g = self.grid.ground(x, z)
        if g is None:
            return None
        y, n = g
        if self.roof_at(x, z) and self.feats.roof["top"] > y:
            return self.feats.roof["top"], (0.0, 1.0, 0.0), SURF_GROOMED
        return y, n, self.surface(x, z, n)

    def surface(self, x, z, n):
        if self.grid.in_lake(x, z):
            return SURF_ICE
        if n[1] < ROCK_NY:
            return SURF_ROCK
        if self.in_piste(x, z):
            return SURF_GROOMED
        return SURF_POWDER

    def overlay_at(self, x, z):
        pos = 0.0
        neg = 0.0
        for o in self.feats.overlays:
            if o.kind != "ravine":
                v = o.value(x, z)
                pos = max(pos, v)
                neg = min(neg, v)
        return pos + neg

    # --- the lines' samples ---------------------------------------------------
    def make_samples(self, line, name, s0, s1):
        out = []
        jumps = [j for j in self.feats.jumps if j.line == name]
        gaps = []
        for j in jumps:
            if j.kind in ("mega", "gap"):
                fr = self.feats.mega_frame if j.kind == "mega" else self.feats.hg_frame
                gaps.append((j, fr))
        lips = [j.s for j in jumps]
        n = int(round(s1 - s0))
        rail_spans = []
        for rl in self.rails:
            if rl["line"] == name or (name == "main" and rl["line"] == "main"):
                rail_spans.append(rl)
        air_until = {}
        for i in range(n + 1):
            s = s0 + i
            x, yb, z = line.at(s)
            g = self.ground(x, z)
            y = g[0] if g else yb
            surf = g[2] if g else SURF_POWDER
            air = False
            for j, fr in gaps:
                ox, oz, fx, fz, rx, rz = fr
                u = (x - ox) * fx + (z - oz) * fz
                if 0.0 < u < j.xe:
                    vx = j.v * math.cos(j.theta)
                    t = u / vx
                    yf = j.y0 + j.v * math.sin(j.theta) * t - 0.5 * C.AIR_GRAVITY * t * t
                    if yf > y + 0.05 and not air_until.get(j.id):
                        y = yf
                        air = True
                    elif u > j.xk:
                        air_until[j.id] = True
            t3 = line.tangent(s)
            safe = not air and surf in (SURF_GROOMED, SURF_POWDER)
            if safe and (abs(self.overlay_at(x, z)) > 0.3 or (g and g[1][1] < 0.86)):
                safe = False
            if safe:
                for ls in lips:
                    if ls - 8.0 <= s <= ls + 1.0:
                        safe = False
            if safe:
                for j, fr in gaps:
                    ox, oz, fx, fz, rx, rz = fr
                    u = (x - ox) * fx + (z - oz) * fz
                    if -8.0 < u < j.xe + 4.0:
                        safe = False
            if safe:
                for rl in rail_spans:
                    if self.near_rail(rl, x, z, 2.5):
                        safe = False
            if safe and self.in_fall_zone_xz(x, z):
                safe = False
            ms = mapped_s(name, s)
            sec = section_of(ms)[0]
            out.append(dict(s=ms, own_s=s, x=x, y=y, z=z, t=t3, width=line.value(line.width, s), section=sec,
                            safe=safe, surface=surf, air=air))
        return out

    def near_rail(self, rl, x, z, d):
        pts = rl["pts"]
        for k in range(0, len(pts), 4):
            px, py, pz = pts[k]
            if (px - x) ** 2 + (pz - z) ** 2 < d * d:
                return True
        px, py, pz = pts[-1]
        return (px - x) ** 2 + (pz - z) ** 2 < d * d

    def in_fall_zone_xz(self, x, z):
        j = self.mega.j
        ox, oz, fx, fz, rx, rz = self.feats.mega_frame
        u = (x - ox) * fx + (z - oz) * fz
        return 0.6 < u < j.xk - 0.5

    # --- rails ------------------------------------------------------------------
    def make_rails(self):
        out = []
        for fid, ln, s, x, kind, segs, h0, w in C.RAILS:
            line = line_of(ln, self.main, self.high)
            ox, oz, fx, fz, rx, rz = frame(line, s, x)
            total = sum(L for L, _ in segs)
            n = int(round(total / C.RAIL_STEP))
            pts = []
            rel = h0
            flags = 0
            seg_i = 0
            seg_start = 0.0
            seg_y0 = None
            for k in range(n + 1):
                q = k * C.RAIL_STEP
                while seg_i < len(segs) - 1 and q > seg_start + segs[seg_i][0] + 1e-9:
                    seg_start += segs[seg_i][0]
                    seg_i += 1
                    seg_y0 = None
                L, shape = segs[seg_i]
                px = ox + fx * q
                pz = oz + fz * q
                snow = self.grid.ground(px, pz)[0]
                if shape == "flat":
                    y = snow + rel
                elif shape[0] == "down":
                    if seg_y0 is None:
                        seg_y0 = (pts[-1][1] if pts else snow + rel, q)
                    y = seg_y0[0] - math.tan(shape[1] * DEG) * (q - seg_y0[1])
                    flags |= RAIL_KINKED if len(segs) > 1 else 0
                elif shape[0] == "arc":
                    t = (q - seg_start) / L
                    y = snow + rel + shape[1] * math.sin(math.pi * t)
                    flags |= RAIL_RAINBOW
                rel_now = y - snow
                if shape != "flat" and shape[0] == "down":
                    rel = rel_now
                pts.append((px, y, pz))
            if len(segs) > 1:
                flags |= RAIL_KINKED
            kcode = {"rail": RAIL_RAIL, "box": RAIL_BOX, "log": RAIL_LOG}[kind]
            out.append(dict(id=fid, line=ln, s=mapped_s(ln, s), x=x, kind=kcode, kind_name=kind, flags=flags, pts=pts,
                            width=w, h0=h0, frame=(ox, oz, fx, fz, rx, rz)))
        return out

    # --- features ----------------------------------------------------------------
    def make_features(self):
        out = []
        for o in self.feats.overlays:
            if o.kind == "roller":
                out.append(dict(id=o.id, kind=FEAT_ROLLER, s=mapped_s(o.line, o.s), x=o.x, high=o.line == "high",
                                lip_h=o.h, lip_a=0.0, v=0.0, air=0.0, rail=-1, overlay=o))
        for j in self.feats.jumps:
            o = next(ov for ov in self.feats.overlays if ov.id == j.id)
            kind = {"kicker": FEAT_KICKER, "drop": FEAT_DROP, "gap": FEAT_GAP, "mega": FEAT_MEGA}[j.kind]
            out.append(dict(id=j.id, kind=kind, s=mapped_s(j.line, j.s), x=j.x, high=j.line == "high",
                            lip_h=j.h if j.kind != "drop" else -j.yk, lip_a=j.theta / DEG, v=j.v, air=j.air,
                            rail=-1, overlay=o))
        for i, rl in enumerate(self.rails):
            out.append(dict(id=rl["id"], kind=FEAT_RAIL, s=rl["s"], x=rl["x"], high=rl["line"] == "high",
                            lip_h=rl["h0"], lip_a=0.0, v=12.0, air=0.0, rail=i, overlay=None))
        out.sort(key=lambda f: (f["s"], f["id"]))
        return out

    # --- fall zones ---------------------------------------------------------------
    def make_fall(self):
        j = self.mega.j
        ox, oz, fx, fz, rx, rz = self.feats.mega_frame
        return [dict(id="ravine", frame=(ox, oz, fx, fz), u0=0.6, u1=j.xk - 0.5, ytop=j.y0 + j.yk - 1.0)]

    # --- the sun --------------------------------------------------------------------
    def make_sun(self):
        def col(h):
            h = h.lstrip("#")
            return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
        out = []
        az = C.SUN_AZIMUTH * DEG
        for s, elev, sun, zen, hor, amb, bounce, fb, fe in C.SUN:
            e = elev * DEG
            d = (-math.cos(e) * math.sin(az), math.sin(e), -math.cos(e) * math.cos(az))
            out.append(dict(s=s, elev=elev, dir=d, sun=col(sun), zenith=col(zen), horizon=col(hor),
                            sky_amb=col(amb), ground_amb=col(bounce), fog_begin=fb, fog_end=fe))
        return out
