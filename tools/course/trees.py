"""The forest (COURSE.md, section 8): crossed-quad pines scattered outside
the pistes, cone-stack pines along the high line, and the obstacles the
rider crashes into (trunks within reach of a line, and what the dressing
adds)."""
import math

import course as C
from samples import Rng

TREE_SIZES = [(7.0, 3.6), (9.5, 4.6), (12.0, 5.6)]   # height, width


class Forest:
    def __init__(self, data):
        self.data = data
        self.trees = []        # (x, y, z, height, width, yaw, variant)
        self.cones = []        # (x, y, z, height, yaw)
        self.obstacles = []
        self.keep_out = []     # (x, z, radius): props' footprints, the lifts' corridors
        self.extra_obstacles = []

    def blocked(self, x, z):
        for kx, kz, kr in self.keep_out:
            if (x - kx) ** 2 + (z - kz) ** 2 < kr * kr:
                return True
        return False

    def ok(self, x, z, clear):
        d = self.data
        g = d.grid
        rows = d.base.line_rows(max(min(z, d.main.z[0]), d.main.z[-1]))
        if not rows:
            return False
        e = d.base.edge_dist(x, z, rows)
        if e < clear:
            return False
        gr = d.ground(x, z)
        if gr is None:
            return False
        y, n, surf = gr
        if n[1] < 0.8 or surf == 2:
            return False
        # off the band's outer edge, the lake's shore, the features, the ravine
        r = int((g.Z0 - z) / C.GRID)
        if r < 0 or r >= g.rows:
            return False
        if x < g.x_of(g.c0[r]) + 3 or x > g.x_of(g.c1[r]) - 3:
            return False
        lx, lz, lfx, lfz, lrx, lrz = g.lake_frame
        a, b = g.lake_ab
        u = (x - lx) * lfx + (z - lz) * lfz
        v = (x - lx) * lrx + (z - lz) * lrz
        if (u / (a + 6)) ** 2 + (v / (b + 6)) ** 2 < 1:
            return False
        if abs(d.overlay_at(x, z)) > 0.01:
            return False
        if d.in_fall_zone_xz(x, z):
            return False
        j = d.mega.j
        ox, oz, fx, fz, rx, rz = d.feats.mega_frame
        uu = (x - ox) * fx + (z - oz) * fz
        if -2.0 < uu < j.xk + 2.0:
            return False
        if self.blocked(x, z):
            return False
        return True

    def scatter(self):
        d = self.data
        g = d.grid
        rng = Rng(C.SEED + 11)
        P = C.TREES
        gap = P["min_gap"]
        cell = gap / math.sqrt(2)
        hashg = {}

        def near(x, z, r):
            cx = int(math.floor(x / cell))
            cz = int(math.floor(z / cell))
            k = int(math.ceil(r / cell))
            for i in range(cx - k, cx + k + 1):
                for j in range(cz - k, cz + k + 1):
                    for (tx, tz) in hashg.get((i, j), ()):
                        if (tx - x) ** 2 + (tz - z) ** 2 < r * r:
                            return True
            return False

        def add(x, z):
            hashg.setdefault((int(math.floor(x / cell)), int(math.floor(z / cell))), []).append((x, z))

        # the cone stacks first, along the high line's edges
        hi = d.high
        count = 0
        s = hi.s[0] + 12
        while s < hi.s[-1] - 12 and count < C.CONE_PINES["count"]:
            for side in (-1, 1):
                off = hi.value(hi.width, s) / 2 + rng.range(2.5, C.CONE_PINES["reach"])
                px, py, pz = hi.at(s)
                dx, dz = hi.plan_dir(s)
                x = px + (-dz) * off * side
                z = pz + dx * off * side
                if self.ok(x, z, 2.2) and not near(x, z, 3.0):
                    gr = d.ground(x, z)
                    self.cones.append((x, gr[0], z, rng.range(5.5, 8.0), rng.range(0, math.pi)))
                    add(x, z)
                    count += 1
            s += rng.range(5.0, 9.0)
        # the crossed quads: dart throwing over the band, denser near the edges
        target = P["count"]
        tries = 0
        z_top = g.Z0
        z_bot = g.z_of(g.rows - 1)
        while len(self.trees) < target and tries < target * 60:
            tries += 1
            z = rng.range(z_bot + 4, z_top - 4)
            r = int((g.Z0 - z) / C.GRID)
            x = rng.range(g.x_of(g.c0[r]), g.x_of(g.c1[r]))
            rows = d.base.line_rows(max(min(z, d.main.z[0]), d.main.z[-1]))
            if not rows:
                continue
            e = d.base.edge_dist(x, z, rows)
            # near the high line, and close to the pistes' edges, the forest is denser
            dens = 1.0 if e < 22 else 0.45 if e < 40 else 0.2
            hr = d.high.at_z(z)
            if hr is not None and abs(x - hr[0]) < 40:
                dens *= P["high_line_density"]
            if rng.next() > dens:
                continue
            if not self.ok(x, z, P["edge_clear"]):
                continue
            if near(x, z, gap):
                continue
            gr = d.ground(x, z)
            k = 0 if rng.next() < 0.3 else 1 if rng.next() < 0.7 else 2
            hgt, wid = TREE_SIZES[k]
            sc = rng.range(0.85, 1.25)
            self.trees.append((x, gr[0], z, hgt * sc, wid * sc, rng.range(0, math.pi), 0 if rng.next() < 0.55 else 1))
            add(x, z)

    def make_obstacles(self):
        d = self.data
        reach = C.TREES["obstacle_reach"]
        obs = []
        for x, y, z, h, w, yaw, var in self.trees:
            rows = d.base.line_rows(max(min(z, d.main.z[0]), d.main.z[-1]))
            if d.base.edge_dist(x, z, rows) < reach:
                obs.append(dict(x=x, z=z, r=0.35 + 0.05 * h / 10, bottom=y - 0.5, top=y + h * 0.75, kind="tree"))
        for x, y, z, h, yaw in self.cones:
            obs.append(dict(x=x, z=z, r=0.55, bottom=y - 0.5, top=y + h, kind="pine"))
        obs += self.extra_obstacles
        obs.sort(key=lambda o: (-o["z"], o["x"]))
        self.obstacles = obs
